#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/../../.. && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/configs"
RESULTS_DIR="${ROOT_DIR}/load-testing/results"

THROUGHPUT_FILE="${RESULTS_DIR}/throughput-vs-concurrency.csv"
TTFT_FILE="${RESULTS_DIR}/ttft-vs-concurrency.csv"
LATENCY_FILE="${RESULTS_DIR}/latency-vs-concurrency.csv"

NAMESPACE="${NAMESPACE:-llm-serving}"
INFERENCE_SERVICE="${INFERENCE_SERVICE:-phi-chat-2}"
PROM_URL="${PROM_URL:-http://127.0.0.1:9090}"
INFER_URL="${INFER_URL:-http://127.0.0.1:8000/v1/completions}"

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

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

require_tools() {
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
	2) local port-forward to predictor service on 8000
	3) local port-forward to Prometheus on 9090
EOF
}

init_results_files() {
	mkdir -p "${RESULTS_DIR}"

	if [[ ! -s "${THROUGHPUT_FILE}" ]]; then
		echo "timestamp,test_id,profile,max_num_seqs,max_num_batched_tokens,concurrency,tokens_per_sec,requests_running_max,requests_waiting_max,kv_cache_pct_max,tensor_active_avg,dram_active_avg,success_count,error_count" > "${THROUGHPUT_FILE}"
	fi

	if [[ ! -s "${TTFT_FILE}" ]]; then
		echo "timestamp,test_id,profile,max_num_seqs,max_num_batched_tokens,concurrency,ttft_p95_s,e2e_p95_s,decode_p95_s" > "${TTFT_FILE}"
	fi

	if [[ ! -s "${LATENCY_FILE}" ]]; then
		echo "timestamp,test_id,profile,max_num_seqs,max_num_batched_tokens,concurrency,ttft_p95_s,e2e_p95_s,decode_p95_s,notes" > "${LATENCY_FILE}"
	fi
}

prom_query_scalar() {
	local query="$1"
	curl -sG "${PROM_URL}/api/v1/query" --data-urlencode "query=${query}" \
		| jq -r '.data.result[0].value[1] // "NaN"'
}

patch_isvc_profile() {
	local seqs="$1"
	local batched="$2"

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

	kubectl -n "${NAMESPACE}" patch inferenceservice "${INFERENCE_SERVICE}" --type merge -p "$(cat <<EOF
{
	"spec": {
		"predictor": {
			"containers": [
				{
					"name": "kserve-container",
					"args": ${args_json}
				}
			]
		}
	}
}
EOF
)"

	kubectl -n "${NAMESPACE}" wait --for=condition=Ready "inferenceservice/${INFERENCE_SERVICE}" --timeout=900s
}

worker_loop() {
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
	local concurrency="$1"
	local warmup="$2"
	local duration="$3"

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

	for _ in $(seq 1 "${concurrency}"); do
		worker_loop "${run_end}" "${success_file}" "${error_file}" &
	done
	wait

	local success_count error_count
	success_count="$(wc -l < "${success_file}" | tr -d ' ')"
	error_count="$(wc -l < "${error_file}" | tr -d ' ')"

	rm -f "${success_file}" "${error_file}"

	echo "${success_count},${error_count}"
}

collect_metrics() {
	local test_id="$1"
	local profile="$2"
	local seqs="$3"
	local batched="$4"
	local concurrency="$5"
	local success_count="$6"
	local error_count="$7"

	local q_tokens q_ttft q_e2e q_decode q_running q_waiting q_kv q_tensor q_dram
	q_tokens="sum(rate(vllm:generation_tokens_total{namespace=\"${NAMESPACE}\",pod=~\"${POD_REGEX}\"}[1m]))"
	q_ttft="histogram_quantile(0.95, sum by (le) (rate(vllm:time_to_first_token_seconds_bucket{namespace=\"${NAMESPACE}\",pod=~\"${POD_REGEX}\"}[5m])))"
	q_e2e="histogram_quantile(0.95, sum by (le) (rate(vllm:request_inference_time_seconds_bucket{namespace=\"${NAMESPACE}\",pod=~\"${POD_REGEX}\"}[5m])))"
	q_decode="histogram_quantile(0.95, sum by (le) (rate(vllm:request_decode_time_seconds_bucket{namespace=\"${NAMESPACE}\",pod=~\"${POD_REGEX}\"}[5m])))"
	q_running="max(vllm:num_requests_running{namespace=\"${NAMESPACE}\",pod=~\"${POD_REGEX}\"})"
	q_waiting="max(vllm:num_requests_waiting{namespace=\"${NAMESPACE}\",pod=~\"${POD_REGEX}\"})"
	q_kv="max(vllm:kv_cache_usage_perc{namespace=\"${NAMESPACE}\",pod=~\"${POD_REGEX}\"})"
	q_tensor="avg_over_time(DCGM_FI_PROF_PIPE_TENSOR_ACTIVE[5m])"
	q_dram="avg_over_time(DCGM_FI_PROF_DRAM_ACTIVE[5m])"

	local tokens ttft e2e decode running waiting kv tensor dram
	tokens="$(prom_query_scalar "${q_tokens}")"
	ttft="$(prom_query_scalar "${q_ttft}")"
	e2e="$(prom_query_scalar "${q_e2e}")"
	decode="$(prom_query_scalar "${q_decode}")"
	running="$(prom_query_scalar "${q_running}")"
	waiting="$(prom_query_scalar "${q_waiting}")"
	kv="$(prom_query_scalar "${q_kv}")"
	tensor="$(prom_query_scalar "${q_tensor}")"
	dram="$(prom_query_scalar "${q_dram}")"

	echo "${TS},${test_id},${profile},${seqs},${batched},${concurrency},${tokens},${running},${waiting},${kv},${tensor},${dram},${success_count},${error_count}" >> "${THROUGHPUT_FILE}"
	echo "${TS},${test_id},${profile},${seqs},${batched},${concurrency},${ttft},${e2e},${decode}" >> "${TTFT_FILE}"
	echo "${TS},${test_id},${profile},${seqs},${batched},${concurrency},${ttft},${e2e},${decode},phase7_llm_perf_sweep" >> "${LATENCY_FILE}"
}

run_one_test() {
	local cfg_file="$1"

	source "${cfg_file}"

	echo "Applying profile ${PROFILE_NAME}: seqs=${MAX_NUM_SEQS}, batched=${MAX_NUM_BATCHED_TOKENS}"
	patch_isvc_profile "${MAX_NUM_SEQS}" "${MAX_NUM_BATCHED_TOKENS}"

	for c in ${CONCURRENCY_LEVELS}; do
		echo "Running ${TEST_ID} at concurrency ${c}"
		IFS=',' read -r success_count error_count < <(run_load "${c}" "${WARMUP_SECONDS}" "${DURATION_SECONDS}")
		collect_metrics "${TEST_ID}" "${PROFILE_NAME}" "${MAX_NUM_SEQS}" "${MAX_NUM_BATCHED_TOKENS}" "${c}" "${success_count}" "${error_count}"
	done
}

main() {
	require_tools
	init_results_files

	local action="${1:-all}"

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
		for t in "${all_tests[@]}"; do
			run_one_test "${CONFIG_DIR}/${t}"
		done

		echo "Re-running baseline B for drift check"
		run_one_test "${CONFIG_DIR}/test-b-seqs-16.sh"
	else
		run_one_test "${CONFIG_DIR}/${action}.sh"
	fi

	echo "Benchmark run complete."
	echo "Results:"
	echo "  ${THROUGHPUT_FILE}"
	echo "  ${TTFT_FILE}"
	echo "  ${LATENCY_FILE}"
}

main "$@"
