#!/usr/bin/env bash
set -euo pipefail

# Resolve script-relative paths so execution works from any current directory.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/../../.. && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/configs"
RESULTS_DIR="${ROOT_DIR}/load-testing/results"

# CSV output files (append-only) for benchmark artifacts.
THROUGHPUT_FILE="${RESULTS_DIR}/throughput-vs-concurrency.csv"
TTFT_FILE="${RESULTS_DIR}/ttft-vs-concurrency.csv"
LATENCY_FILE="${RESULTS_DIR}/latency-vs-concurrency.csv"

# Runtime endpoints and Kubernetes target.
NAMESPACE="${NAMESPACE:-llm-serving}"
INFERENCE_SERVICE="${INFERENCE_SERVICE:-phi-chat-2}"
PROM_URL="${PROM_URL:-http://127.0.0.1:9090}"
INFER_URL="${INFER_URL:-http://127.0.0.1:8000/v1/completions}"
AUTO_PORT_FORWARD_INFER="${AUTO_PORT_FORWARD_INFER:-true}"
VERBOSE_LOGGING="${VERBOSE_LOGGING:-true}"
INFER_ENDPOINT_WAIT_SECONDS="${INFER_ENDPOINT_WAIT_SECONDS:-300}"

# Default vLLM serving arguments used when building each test profile patch.
MODEL_PATH="${MODEL_PATH:-/models/microsoft/phi-2/main}"
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-phi-2}"
GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.85}"
POD_REGEX="${POD_REGEX:-phi-chat-2.*}"

# Load generation controls.
CONCURRENCY_LEVELS="${CONCURRENCY_LEVELS:-1 5 10 20 40}"
WARMUP_SECONDS="${WARMUP_SECONDS:-120}"
DURATION_SECONDS="${DURATION_SECONDS:-480}"
REQUEST_TIMEOUT_SECONDS="${REQUEST_TIMEOUT_SECONDS:-120}"

# Request payload defaults.
MAX_TOKENS="${MAX_TOKENS:-128}"
TEMPERATURE="${TEMPERATURE:-0.2}"
PROMPT_TEXT="${PROMPT_TEXT:-You are a concise assistant. Summarize Kubernetes autoscaling in one short paragraph.}"

# One timestamp marker per script invocation to correlate rows across files.
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Best-effort local port-forward process tracking.
PF_INFER_PID=""
PF_INFER_LOG=""

log() {
	local level="$1"
	shift
	printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${level}" "$*"
}

vlog() {
	if [[ "${VERBOSE_LOGGING}" == "true" ]]; then
		log "DEBUG" "$*"
	fi
}

require_tools() {
	# Fail fast if required CLI tools are unavailable.
	command -v curl >/dev/null 2>&1 || { echo "Missing curl"; exit 1; }
	command -v jq >/dev/null 2>&1 || { echo "Missing jq"; exit 1; }
	command -v kubectl >/dev/null 2>&1 || { echo "Missing kubectl"; exit 1; }
}

usage() {
	cat <<EOF
Usage:
	./run-benchmark.sh all
	./run-benchmark.sh test-a-seqs-8
	./run-benchmark.sh test-b-seqs-16
	./run-benchmark.sh test-c-seqs-32
	./run-benchmark.sh test-d-batched-512
	./run-benchmark.sh test-e-batched-1024
	./run-benchmark.sh test-f-batched-2048
	./run-benchmark.sh test-g-seqs32-batch1024
	./run-benchmark.sh test-h-seqs32-batch2048

Required setup before running:
	1) phi-chat-2 running and ready
	2) local port-forward to predictor service on 8000 (optional when AUTO_PORT_FORWARD_INFER=true and INFER_URL is localhost)
	3) local port-forward to Prometheus on 9090
EOF
}

cleanup_port_forward() {
	# Stop background port-forward if this script started it.
	if [[ -n "${PF_INFER_PID}" ]]; then
		vlog "Stopping managed inference port-forward pid=${PF_INFER_PID}"
		kill "${PF_INFER_PID}" >/dev/null 2>&1 || true
	fi
}

is_local_infer_url() {
	# Detect local URL usage where port-forward is required.
	[[ "${INFER_URL}" =~ ^http://(127\.0\.0\.1|localhost):[0-9]+/ ]]
}

get_infer_local_port() {
	# Parse local port from INFER_URL (http://host:PORT/path).
	local without_scheme host_port
	without_scheme="${INFER_URL#http://}"
	host_port="${without_scheme%%/*}"
	echo "${host_port##*:}"
}

ensure_infer_endpoint() {
	# Re-establish local service port-forward if rollout invalidated the tunnel.
	if [[ "${AUTO_PORT_FORWARD_INFER}" != "true" ]]; then
		vlog "AUTO_PORT_FORWARD_INFER=false, skipping inference endpoint management"
		return 0
	fi

	if ! is_local_infer_url; then
		vlog "INFER_URL is not localhost, skipping local port-forward management"
		return 0
	fi

	local health_url code
	health_url="${INFER_URL%/v1/completions}/health"
	code="$(curl -s --max-time 2 -o /dev/null -w "%{http_code}" "${health_url}" || true)"
	if [[ "${code}" == "200" ]]; then
		vlog "Inference endpoint is healthy: ${health_url}"
		return 0
	fi
	vlog "Inference endpoint probe returned code=${code}; starting/restarting port-forward"

	local local_port svc_name deadline attempt attempt_deadline
	local_port="$(get_infer_local_port)"
	svc_name="${INFERENCE_SERVICE}-predictor"
	deadline="$(( $(date +%s) + INFER_ENDPOINT_WAIT_SECONDS ))"
	attempt=0
	while [[ "$(date +%s)" -lt "${deadline}" ]]; do
		attempt="$(( attempt + 1 ))"

		if [[ -n "${PF_INFER_PID}" ]]; then
			vlog "Stopping stale managed inference port-forward pid=${PF_INFER_PID}"
			kill "${PF_INFER_PID}" >/dev/null 2>&1 || true
			PF_INFER_PID=""
		fi

		PF_INFER_LOG="$(mktemp)"
		log "INFO" "[attempt ${attempt}] Starting inference port-forward: svc/${svc_name} ${local_port}:80"
		kubectl -n "${NAMESPACE}" port-forward "svc/${svc_name}" "${local_port}:80" >"${PF_INFER_LOG}" 2>&1 &
		PF_INFER_PID="$!"

		attempt_deadline="$(( $(date +%s) + 20 ))"
		while [[ "$(date +%s)" -lt "${attempt_deadline}" && "$(date +%s)" -lt "${deadline}" ]]; do
			if ! kill -0 "${PF_INFER_PID}" >/dev/null 2>&1; then
				vlog "Port-forward process exited during attempt ${attempt}; retrying"
				break
			fi

			code="$(curl -s --max-time 2 -o /dev/null -w "%{http_code}" "${health_url}" || true)"
			if [[ "${code}" == "200" ]]; then
				log "INFO" "Inference endpoint recovered via managed port-forward"
				return 0
			fi

			vlog "Waiting for inference endpoint health; attempt=${attempt} last_code=${code}"
			sleep 2
		done

		if [[ -n "${PF_INFER_PID}" ]]; then
			kill "${PF_INFER_PID}" >/dev/null 2>&1 || true
			PF_INFER_PID=""
		fi
		sleep 2
	done

	log "ERROR" "Failed to establish inference endpoint within ${INFER_ENDPOINT_WAIT_SECONDS}s for ${svc_name}"
	if [[ -n "${PF_INFER_LOG}" && -f "${PF_INFER_LOG}" ]]; then
		log "ERROR" "Recent port-forward log tail:"
		tail -n 20 "${PF_INFER_LOG}" || true
	fi
	return 1
}

init_results_files() {
	# Initialize CSV headers if files do not exist yet.
	mkdir -p "${RESULTS_DIR}"

	if [[ ! -s "${THROUGHPUT_FILE}" ]]; then
		echo "timestamp,test_id,profile,max_num_seqs,max_num_batched_tokens,concurrency,tokens_per_sec,requests_running_max,requests_waiting_max,kv_cache_pct_max,tensor_active_avg,dram_active_avg,success_count,error_count" > "${THROUGHPUT_FILE}"
	fi

	if [[ ! -s "${TTFT_FILE}" ]]; then
		echo "timestamp,test_id,profile,max_num_seqs,max_num_batched_tokens,concurrency,ttft_p95_s,e2e_p95_s,decode_p95_s" > "${TTFT_FILE}"
	fi

	if [[ ! -s "${LATENCY_FILE}" ]]; then
		echo "timestamp,test_id,profile,max_num_seqs,max_num_batched_tokens,concurrency,ttft_p95_s,e2e_p95_s,decode_p95_s" > "${LATENCY_FILE}"
	fi
}

prom_query_scalar() {
	# Execute a Prometheus instant query and return the first scalar value.
	local query="$1"
	vlog "Prometheus query: ${query}" >&2
	curl -sG "${PROM_URL}/api/v1/query" --data-urlencode "query=${query}" \
		| jq -r '.data.result[0].value[1] // "NaN"'
}

patch_isvc_profile() {
	# Patch phi-chat-2 predictor args for the active profile and wait for readiness.
	local seqs="$1"
	local batched="$2"
	local deploy_name="${INFERENCE_SERVICE}-predictor"

	local args_json
	if [[ "${batched}" == "default" ]]; then
		args_json=$(cat <<EOF
[
	"${MODEL_PATH}",
	"--served-model-name", "${SERVED_MODEL_NAME}",
	"--host", "0.0.0.0",
	"--port", "8000",
	"--gpu-memory-utilization", "${GPU_MEMORY_UTILIZATION}",
	"--max-num-seqs", "${seqs}"
]
EOF
)
	else
		args_json=$(cat <<EOF
[
	"${MODEL_PATH}",
	"--served-model-name", "${SERVED_MODEL_NAME}",
	"--host", "0.0.0.0",
	"--port", "8000",
	"--gpu-memory-utilization", "${GPU_MEMORY_UTILIZATION}",
	"--max-num-seqs", "${seqs}",
	"--max-num-batched-tokens", "${batched}"
]
EOF
)
	fi

	# Update only .args for the named container on the live object,
	# preserving image, resources, probes, and other fields.
	# On single-GPU nodes, avoid rollout overlap by draining old predictor pods first.
	if kubectl -n "${NAMESPACE}" get deploy "${deploy_name}" >/dev/null 2>&1; then
		log "INFO" "Scaling ${deploy_name} to 0 to free GPU before profile patch"
		kubectl -n "${NAMESPACE}" scale deploy "${deploy_name}" --replicas=0

		local drain_deadline now pod_count
		drain_deadline="$(( $(date +%s) + 300 ))"
		while true; do
			now="$(date +%s)"
			if [[ "${now}" -ge "${drain_deadline}" ]]; then
				log "ERROR" "Timed out waiting for predictor pods to terminate"
				return 1
			fi

			pod_count="$(kubectl -n "${NAMESPACE}" get pods -l "serving.kserve.io/inferenceservice=${INFERENCE_SERVICE}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
			if [[ "${pod_count}" == "0" ]]; then
				vlog "All predictor pods drained"
				break
			fi
			vlog "Waiting for predictor pods to drain; remaining=${pod_count}"

			sleep 5
		done
	fi

	log "INFO" "Patching InferenceService ${INFERENCE_SERVICE} args (seqs=${seqs}, batched=${batched})"
	kubectl -n "${NAMESPACE}" get inferenceservice "${INFERENCE_SERVICE}" -o json \
		| jq --argjson args "${args_json}" '
			.spec.predictor.containers |= map(
				if .name == "kserve-container" then
					. + {args: $args}
				else
					.
				end
			)
		' \
		| kubectl apply -f -

	# Ensure predictor scales back up after profile patch.
	if kubectl -n "${NAMESPACE}" get deploy "${deploy_name}" >/dev/null 2>&1; then
		log "INFO" "Scaling ${deploy_name} back to 1 replica"
		kubectl -n "${NAMESPACE}" scale deploy "${deploy_name}" --replicas=1
	fi

	log "INFO" "Waiting for InferenceService/${INFERENCE_SERVICE} Ready"
	kubectl -n "${NAMESPACE}" wait --for=condition=Ready "inferenceservice/${INFERENCE_SERVICE}" --timeout=900s
	log "INFO" "InferenceService/${INFERENCE_SERVICE} is Ready"
}

worker_loop() {
	# One worker process sending requests until the configured epoch cutoff.
	local end_epoch="$1"
	local success_file="$2"
	local error_file="$3"

	while [[ "$(date +%s)" -lt "${end_epoch}" ]]; do
		local payload
		payload=$(cat <<EOF
{
	"model": "${SERVED_MODEL_NAME}",
	"prompt": "${PROMPT_TEXT}",
	"max_tokens": ${MAX_TOKENS},
	"temperature": ${TEMPERATURE}
}
EOF
)

		local code
		code="$(curl -s -o /dev/null -w "%{http_code}" --max-time "${REQUEST_TIMEOUT_SECONDS}" \
			-H "Content-Type: application/json" \
			-d "${payload}" \
			"${INFER_URL}" || true)"

		if [[ "${code}" == "200" ]]; then
			echo "1" >> "${success_file}"
		else
			echo "1" >> "${error_file}"
		fi
	done
}

run_load() {
	# Run warmup first, then measured load window for a single concurrency level.
	local concurrency="$1"
	local warmup="$2"
	local duration="$3"
	log "INFO" "Starting load phase: concurrency=${concurrency} warmup=${warmup}s measured=${duration}s" >&2

	local success_file error_file
	success_file="$(mktemp)"
	error_file="$(mktemp)"

	local warmup_end run_end
	warmup_end="$(( $(date +%s) + warmup ))"
	run_end="$(( warmup_end + duration ))"

	for _ in $(seq 1 "${concurrency}"); do
		worker_loop "${warmup_end}" "${success_file}" "${error_file}" &
	done
	wait
	vlog "Warmup phase completed for concurrency=${concurrency}" >&2

	for _ in $(seq 1 "${concurrency}"); do
		worker_loop "${run_end}" "${success_file}" "${error_file}" &
	done
	wait
	vlog "Measured phase completed for concurrency=${concurrency}" >&2

	local success_count error_count
	# Count request outcomes for this concurrency point.
	success_count="$(wc -l < "${success_file}" | tr -d ' ')"
	error_count="$(wc -l < "${error_file}" | tr -d ' ')"
	log "INFO" "Load result: concurrency=${concurrency} success_count=${success_count} error_count=${error_count}" >&2

	rm -f "${success_file}" "${error_file}"

	echo "${success_count},${error_count}"
}

collect_metrics() {
	# Query KPI set from Prometheus and append one row to each result CSV.
	local test_id="$1"
	local profile="$2"
	local seqs="$3"
	local batched="$4"
	local concurrency="$5"
	local success_count="$6"
	local error_count="$7"

	local q_tokens q_ttft q_e2e q_decode q_running q_waiting q_kv q_tensor q_dram
	# Throughput: generated output tokens per second across scoped phi-chat-2 pods.
	q_tokens="sum(rate(vllm:generation_tokens_total{namespace=\"${NAMESPACE}\",pod=~\"${POD_REGEX}\"}[1m]))"
	# TTFT p95: user-perceived first-token latency tail (95th percentile).
	q_ttft="histogram_quantile(0.95, sum by (le) (rate(vllm:time_to_first_token_seconds_bucket{namespace=\"${NAMESPACE}\",pod=~\"${POD_REGEX}\"}[5m])))"
	# E2E p95: full request inference latency tail (95th percentile).
	q_e2e="histogram_quantile(0.95, sum by (le) (rate(vllm:request_inference_time_seconds_bucket{namespace=\"${NAMESPACE}\",pod=~\"${POD_REGEX}\"}[5m])))"
	# Decode p95: generation/decode-stage latency tail (95th percentile).
	q_decode="histogram_quantile(0.95, sum by (le) (rate(vllm:request_decode_time_seconds_bucket{namespace=\"${NAMESPACE}\",pod=~\"${POD_REGEX}\"}[5m])))"
	# Running requests: peak in-flight requests over the last 5 minutes.
	q_running="max(max_over_time(vllm:num_requests_running{namespace=\"${NAMESPACE}\",pod=~\"${POD_REGEX}\"}[5m]))"
	# Waiting requests: peak queued requests over the last 5 minutes.
	q_waiting="max(max_over_time(vllm:num_requests_waiting{namespace=\"${NAMESPACE}\",pod=~\"${POD_REGEX}\"}[5m]))"
	# KV cache usage: peak KV usage percentage over the last 5 minutes.
	q_kv="100 * max(max_over_time(vllm:kv_cache_usage_perc{namespace=\"${NAMESPACE}\",pod=~\"${POD_REGEX}\"}[5m]))"
	# Tensor active: 5-minute average Tensor Core activity (cluster-level DCGM signal).
	q_tensor="avg_over_time(DCGM_FI_PROF_PIPE_TENSOR_ACTIVE[5m])"
	# DRAM active: 5-minute average GPU DRAM activity (cluster-level DCGM signal).
	q_dram="avg_over_time(DCGM_FI_PROF_DRAM_ACTIVE[5m])"

	local tokens ttft e2e decode running waiting kv tensor dram
	log "INFO" "Collecting Prometheus metrics for test=${test_id} concurrency=${concurrency}"
	tokens="$(prom_query_scalar "${q_tokens}")"
	ttft="$(prom_query_scalar "${q_ttft}")"
	e2e="$(prom_query_scalar "${q_e2e}")"
	decode="$(prom_query_scalar "${q_decode}")"
	running="$(prom_query_scalar "${q_running}")"
	waiting="$(prom_query_scalar "${q_waiting}")"
	kv="$(prom_query_scalar "${q_kv}")"
	tensor="$(prom_query_scalar "${q_tensor}")"
	dram="$(prom_query_scalar "${q_dram}")"
	log "INFO" "Metrics: tokens=${tokens} ttft_p95=${ttft} e2e_p95=${e2e} decode_p95=${decode} running_max=${running} waiting_max=${waiting} kv_max=${kv}"

	echo "${TS},${test_id},${profile},${seqs},${batched},${concurrency},${tokens},${running},${waiting},${kv},${tensor},${dram},${success_count},${error_count}" >> "${THROUGHPUT_FILE}"
	echo "${TS},${test_id},${profile},${seqs},${batched},${concurrency},${ttft},${e2e},${decode}" >> "${TTFT_FILE}"
	echo "${TS},${test_id},${profile},${seqs},${batched},${concurrency},${ttft},${e2e},${decode}" >> "${LATENCY_FILE}"
}

run_one_test() {
	# Execute one profile end-to-end across all configured concurrency levels.
	local cfg_file="$1"

	source "${cfg_file}"

	log "INFO" "Applying profile ${PROFILE_NAME}: seqs=${MAX_NUM_SEQS}, batched=${MAX_NUM_BATCHED_TOKENS}"
	patch_isvc_profile "${MAX_NUM_SEQS}" "${MAX_NUM_BATCHED_TOKENS}"
	ensure_infer_endpoint

	for c in ${CONCURRENCY_LEVELS}; do
		ensure_infer_endpoint
		log "INFO" "Running ${TEST_ID} at concurrency ${c}"
		IFS=',' read -r success_count error_count < <(run_load "${c}" "${WARMUP_SECONDS}" "${DURATION_SECONDS}")
		collect_metrics "${TEST_ID}" "${PROFILE_NAME}" "${MAX_NUM_SEQS}" "${MAX_NUM_BATCHED_TOKENS}" "${c}" "${success_count}" "${error_count}"
	done
}

main() {
	# Entry point: initialize, choose all tests or a single profile, run sequentially.
	trap cleanup_port_forward EXIT
	require_tools
	init_results_files

	local action="${1:-all}"
	log "INFO" "Benchmark runner started: action=${action} namespace=${NAMESPACE} isvc=${INFERENCE_SERVICE}"

	if [[ "${action}" == "help" || "${action}" == "-h" || "${action}" == "--help" ]]; then
		usage
		exit 0
	fi

	local all_tests=(
		"test-a-seqs-8.sh"
		"test-b-seqs-16.sh"
		"test-c-seqs-32.sh"
		"test-d-batched-512.sh"
		"test-e-batched-1024.sh"
		"test-f-batched-2048.sh"
		"test-g-seqs32-batch1024.sh"
		"test-h-seqs32-batch2048.sh"
	)

	if [[ "${action}" == "all" ]]; then
		# Full sweep A-H, then re-run baseline B to detect drift.
		log "INFO" "Running full A-H sweep with baseline B drift re-check"
		for t in "${all_tests[@]}"; do
			vlog "Starting profile config file=${t}"
			run_one_test "${CONFIG_DIR}/${t}"
		done

		log "INFO" "Re-running baseline B for drift check"
		run_one_test "${CONFIG_DIR}/test-b-seqs-16.sh"
	else
		vlog "Running single profile action=${action}"
		run_one_test "${CONFIG_DIR}/${action}.sh"
	fi

	log "INFO" "Benchmark run complete"
	log "INFO" "Results:"
	log "INFO" "  ${THROUGHPUT_FILE}"
	log "INFO" "  ${TTFT_FILE}"
	log "INFO" "  ${LATENCY_FILE}"
}

main "$@"
