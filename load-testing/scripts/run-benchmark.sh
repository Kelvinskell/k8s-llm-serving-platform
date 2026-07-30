#!/usr/bin/env bash

set -Eeuo pipefail

###############################################################################
# Benchmark Orchestrator
#
# Responsibilities
#   - Load benchmark profiles
#   - Patch KServe configuration
#   - Recycle predictor workload on a single T4
#   - Wait for service readiness
#   - Maintain local inference endpoint access
#   - Execute loadgen.py
#   - Execute statistics.py
#   - Execute metrics.py
#   - Persist benchmark CSVs
#
# Non-Responsibilities
#   - Load generation
#   - Prometheus querying
#   - Latency calculations
#
# Those concerns live in:
#
#   python/loadgen.py
#   python/statistics.py
#   python/metrics.py
###############################################################################

###############################################################################
# Paths
###############################################################################

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/../.. && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG_DIR="${SCRIPT_DIR}/configs"
PYTHON_DIR="${SCRIPT_DIR}/python"

RESULTS_DIR="${ROOT_DIR}/load-testing/results"
REQUEST_RESULTS_DIR="${RESULTS_DIR}/request-level"

THROUGHPUT_FILE="${RESULTS_DIR}/throughput-vs-concurrency.csv"
LATENCY_FILE="${RESULTS_DIR}/latency-vs-concurrency.csv"
SUMMARY_FILE="${RESULTS_DIR}/benchmark-summary.csv"
LOG_FILE="${RESULTS_DIR}/benchmark.log"

mkdir -p "${RESULTS_DIR}"
mkdir -p "${REQUEST_RESULTS_DIR}"

###############################################################################
# Logging
###############################################################################

exec > >(tee -a "${LOG_FILE}")
exec 2>&1

log() {
	printf '%s [INFO] %s\n' \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		"$*"
}

warn() {
	printf '%s [WARN] %s\n' \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		"$*"
}

fatal() {
	printf '%s [ERROR] %s\n' \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		"$*" >&2
	exit 1
}

###############################################################################
# Runtime Configuration
###############################################################################

NAMESPACE="${NAMESPACE:-llm-serving}"
INFERENCE_SERVICE="${INFERENCE_SERVICE:-phi-chat-2}"

PROM_URL="${PROM_URL:-http://127.0.0.1:9090}"
INFER_URL="${INFER_URL:-http://127.0.0.1:8000/v1/completions}"

AUTO_PORT_FORWARD_INFER="${AUTO_PORT_FORWARD_INFER:-true}"

MODEL_PATH="${MODEL_PATH:-/models/microsoft/phi-2/main}"
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-phi-2}"
GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.85}"

POD_REGEX="${POD_REGEX:-phi-chat-2.*}"

CONCURRENCY_LEVELS="${CONCURRENCY_LEVELS:-1 5 10 20 40}"

WARMUP_SECONDS="${WARMUP_SECONDS:-120}"
DURATION_SECONDS="${DURATION_SECONDS:-480}"

REQUEST_TIMEOUT_SECONDS="${REQUEST_TIMEOUT_SECONDS:-120}"

MAX_TOKENS="${MAX_TOKENS:-128}"
TEMPERATURE="${TEMPERATURE:-0.2}"

PROMPT_TEXT="${PROMPT_TEXT:-You are a concise assistant. Summarize Kubernetes autoscaling in one short paragraph.}"

READY_TIMEOUT_SECONDS="${READY_TIMEOUT_SECONDS:-3}"
READY_WAIT_TIMEOUT_SECONDS="${READY_WAIT_TIMEOUT_SECONDS:-180}"
POST_READY_SETTLE_SECONDS="${POST_READY_SETTLE_SECONDS:-240}"

PF_INFER_PID=""

###############################################################################
# Cleanup
###############################################################################

cleanup() {

	if [[ -n "${PF_INFER_PID}" ]]; then
		kill "${PF_INFER_PID}" >/dev/null 2>&1 || true
	fi
}

trap cleanup EXIT INT TERM

###############################################################################
# Validation
###############################################################################

require_tools() {

	command -v kubectl >/dev/null || fatal "kubectl not found"
	command -v jq >/dev/null || fatal "jq not found"
	command -v curl >/dev/null || fatal "curl not found"
	command -v python3 >/dev/null || fatal "python3 not found"
}

usage() {

	cat <<EOF
Usage:

  ./run-benchmark.sh all

  ./run-benchmark.sh test-a-seqs8-batch2048
  ./run-benchmark.sh test-b-seqs16-batch2048
  ./run-benchmark.sh test-c-seqs32-batch2048
  ./run-benchmark.sh test-d-seqs16-batch512
  ./run-benchmark.sh test-e-seqs16-batch1024
  ./run-benchmark.sh test-f-seqs16-batch2048
  ./run-benchmark.sh test-g-seqs32-batch1024
  ./run-benchmark.sh test-h-seqs32-batch2048
EOF
}

###############################################################################
# CSV Initialisation
###############################################################################

init_results_files() {

	if [[ ! -f "${THROUGHPUT_FILE}" ]]; then
		echo "timestamp,test_id,profile,max_num_seqs,max_num_batched_tokens,concurrency,tokens_total,tokens_per_sec,requests_running_avg,requests_running_max,requests_waiting_avg,requests_waiting_max,kv_cache_pct_avg,kv_cache_pct_max,tensor_active_avg,tensor_active_max,dram_active_avg,dram_active_max" \
			> "${THROUGHPUT_FILE}"
	fi

	if [[ ! -f "${LATENCY_FILE}" ]]; then
		echo "timestamp,test_id,profile,max_num_seqs,max_num_batched_tokens,concurrency,latency_avg_ms,latency_min_ms,latency_max_ms,latency_p50_ms,latency_p90_ms,latency_p95_ms,latency_p99_ms" \
			> "${LATENCY_FILE}"
	fi

	if [[ ! -f "${SUMMARY_FILE}" ]]; then
		echo "timestamp,test_id,profile,max_num_seqs,max_num_batched_tokens,concurrency,requests_total,successes,errors,success_rate_pct,error_rate_pct,rps" \
			> "${SUMMARY_FILE}"
	fi
}

###############################################################################
# Endpoint Management
###############################################################################

is_local_infer_url() {
	[[ "${INFER_URL}" =~ ^http://(127\.0\.0\.1|localhost): ]]
}

infer_health_url() {
	echo "${INFER_URL%/v1/completions}/health"
}

ensure_infer_endpoint() {

	if [[ "${AUTO_PORT_FORWARD_INFER}" != "true" ]]; then
		return 0
	fi

	if ! is_local_infer_url; then
		return 0
	fi

	local health_url
	health_url="$(infer_health_url)"

	if curl \
		-s \
		--max-time 3 \
		-f \
		"${health_url}" >/dev/null 2>&1; then
		return 0
	fi

	log "Recovering inference endpoint"

	[[ -n "${PF_INFER_PID}" ]] && \
		kill "${PF_INFER_PID}" >/dev/null 2>&1 || true

	local svc_name
	svc_name="${INFERENCE_SERVICE}-predictor"

	kubectl -n "${NAMESPACE}" \
		port-forward "svc/${svc_name}" 8000:80 \
		>/tmp/benchmark-portforward.log 2>&1 &

	PF_INFER_PID="$!"

	sleep 10

	curl \
		-s \
		--max-time 5 \
		-f \
		"${health_url}" >/dev/null \
		|| fatal "Unable to recover inference endpoint"
}

###############################################################################
# ISVC Lifecycle
###############################################################################

wait_for_isvc_ready() {

	if kubectl \
		-n "${NAMESPACE}" \
		get \
		"inferenceservice/${INFERENCE_SERVICE}" \
		-o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null \
		| grep -q 'True'; then
		log "InferenceService already Ready"
	else
		log "Waiting for InferenceService readiness"

		kubectl \
			-n "${NAMESPACE}" \
			wait \
			--for=condition=Ready \
			"inferenceservice/${INFERENCE_SERVICE}" \
			--timeout="${READY_WAIT_TIMEOUT_SECONDS}s" \
			|| fatal "InferenceService did not become Ready within ${READY_WAIT_TIMEOUT_SECONDS}s"

		log "InferenceService ready"
	fi

	log "Allowing service to stabilise"

	sleep "${POST_READY_SETTLE_SECONDS}"
}

patch_isvc_profile() {

	local seqs="$1"
	local batched="$2"

	local deploy_name
	deploy_name="${INFERENCE_SERVICE}-predictor"

	log "Scaling predictor deployment to zero"

	kubectl \
		-n "${NAMESPACE}" \
		scale deployment "${deploy_name}" \
		--replicas=0

	sleep 15

	log "Waiting for predictor pods to terminate"

	while kubectl \
		-n "${NAMESPACE}" \
		get pods \
		-l "serving.kserve.io/inferenceservice=${INFERENCE_SERVICE}" \
		--no-headers 2>/dev/null | grep -q .; do
		sleep 5
	done

	log "Applying profile seqs=${seqs} batched=${batched}"

	local args_json

	args_json=$(
		cat <<EOF
[
 "${MODEL_PATH}",
 "--served-model-name","${SERVED_MODEL_NAME}",
 "--host","0.0.0.0",
 "--port","8000",
 "--gpu-memory-utilization","${GPU_MEMORY_UTILIZATION}",
 "--max-num-seqs","${seqs}",
 "--max-num-batched-tokens","${batched}"
]
EOF
	)

	kubectl \
		-n "${NAMESPACE}" \
		get inferenceservice "${INFERENCE_SERVICE}" \
		-o json |
	jq \
		--argjson args "${args_json}" '
		.spec.predictor.containers |= map(
			if .name == "kserve-container"
			then . + {args: $args}
			else .
			end
		)
	' |
	kubectl apply -f -

	log "Scaling predictor deployment back to one"

	kubectl \
		-n "${NAMESPACE}" \
		scale deployment "${deploy_name}" \
		--replicas=1

	wait_for_isvc_ready
}

###############################################################################
# Benchmark Execution
###############################################################################

run_concurrency_test() {

	local test_id="$1"
	local profile="$2"
	local seqs="$3"
	local batched="$4"
	local concurrency="$5"

	local ts
	ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

	local request_file
	local profile_summary_file

	request_file="${REQUEST_RESULTS_DIR}/${test_id}-c${concurrency}.jsonl"
	profile_summary_file="${REQUEST_RESULTS_DIR}/${test_id}-c${concurrency}-summary.json"

	log "Running test=${test_id} concurrency=${concurrency}"

	export PYTHON_DIR="${PYTHON_DIR:-${SCRIPT_DIR}/python}"
	export INFER_URL
	export SERVED_MODEL_NAME
	export PROMPT_TEXT
	export CONCURRENCY="${concurrency}"
	export WARMUP_SECONDS
	export DURATION_SECONDS
	export REQUEST_TIMEOUT_SECONDS
	export MAX_TOKENS
	export TEMPERATURE
	export REQUEST_FILE="${request_file}"
	export PROFILE_SUMMARY_FILE="${profile_summary_file}"

	python3 - <<'PY'
import os
import signal
import subprocess
import sys

cmd = [
    "python3",
    os.path.join(os.environ["PYTHON_DIR"], "loadgen.py"),
    "--url", os.environ["INFER_URL"],
    "--model", os.environ["SERVED_MODEL_NAME"],
    "--prompt", os.environ["PROMPT_TEXT"],
    "--concurrency", os.environ["CONCURRENCY"],
    "--warmup", os.environ["WARMUP_SECONDS"],
    "--duration", os.environ["DURATION_SECONDS"],
    "--timeout", os.environ["REQUEST_TIMEOUT_SECONDS"],
    "--max-tokens", os.environ["MAX_TOKENS"],
    "--temperature", os.environ["TEMPERATURE"],
    "--output", os.environ["REQUEST_FILE"],
    "--summary-file", os.environ["PROFILE_SUMMARY_FILE"],
]

proc = subprocess.Popen(cmd)
try:
    proc.wait(timeout=1800)
except subprocess.TimeoutExpired:
    proc.send_signal(signal.SIGTERM)
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
    sys.exit(124)

sys.exit(proc.returncode)
PY

	local run_start
	local run_end

	run_start="$(jq -r '.run_start' "${profile_summary_file}")"
	run_end="$(jq -r '.run_end' "${profile_summary_file}")"

	local stats_json
	local metrics_json

	stats_json="$(
		python3 "${PYTHON_DIR}/statistic.py" \
			--input "${request_file}" \
			--summary-file "${profile_summary_file}"
	)"

	metrics_json="$(
		python3 "${PYTHON_DIR}/metrics.py" \
			--prom-url "${PROM_URL}" \
			--namespace "${NAMESPACE}" \
			--pod-regex "${POD_REGEX}" \
			--start "${run_start}" \
			--end "${run_end}"
	)"

	echo "${ts},${test_id},${profile},${seqs},${batched},${concurrency},$(echo "${metrics_json}" | jq -r '[.tokens_total,.tokens_per_sec,.requests_running_avg,.requests_running_max,.requests_waiting_avg,.requests_waiting_max,.kv_cache_pct_avg,.kv_cache_pct_max,.tensor_active_avg,.tensor_active_max,.dram_active_avg,.dram_active_max] | @csv' | tr -d '"')" \
		>> "${THROUGHPUT_FILE}"

	echo "${ts},${test_id},${profile},${seqs},${batched},${concurrency},$(echo "${stats_json}" | jq -r '[.latency_avg_ms,.latency_min_ms,.latency_max_ms,.latency_p50_ms,.latency_p90_ms,.latency_p95_ms,.latency_p99_ms] | @csv' | tr -d '"')" \
		>> "${LATENCY_FILE}"

	echo "${ts},${test_id},${profile},${seqs},${batched},${concurrency},$(echo "${stats_json}" | jq -r '[.requests_total,.successes,.errors,.success_rate_pct,.error_rate_pct,.rps] | @csv' | tr -d '"')" \
		>> "${SUMMARY_FILE}"
}

run_profile() {

	local cfg_file="$1"

	source "${cfg_file}"

	log "Executing profile ${PROFILE_NAME}"

	patch_isvc_profile \
		"${MAX_NUM_SEQS}" \
		"${MAX_NUM_BATCHED_TOKENS}"

	ensure_infer_endpoint

	for concurrency in ${CONCURRENCY_LEVELS}; do

		ensure_infer_endpoint

		run_concurrency_test \
			"${TEST_ID}" \
			"${PROFILE_NAME}" \
			"${MAX_NUM_SEQS}" \
			"${MAX_NUM_BATCHED_TOKENS}" \
			"${concurrency}"
	done
}

###############################################################################
# Main
###############################################################################

main() {

	require_tools
	init_results_files

	local action="${1:-all}"

	if [[ "${action}" == "help" || "${action}" == "-h" || "${action}" == "--help" ]]; then
		usage
		exit 0
	fi

	if [[ "${action}" == "all" ]]; then

		for profile in \
			test-a-seqs8-batch2048.sh \
			test-b-seqs16-batch2048.sh \
			test-c-seqs32-batch2048.sh \
			test-d-seqs16-batch512.sh \
			test-e-seqs16-batch1024.sh \
			test-f-seqs16-batch2048.sh \
			test-g-seqs32-batch1024.sh \
			test-h-seqs32-batch2048.sh
		do
			run_profile "${CONFIG_DIR}/${profile}"
		done

	else
		run_profile "${CONFIG_DIR}/${action}.sh"
	fi

	log "Benchmark complete"
}

main "$@"