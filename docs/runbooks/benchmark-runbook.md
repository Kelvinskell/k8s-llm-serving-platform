# Runbook: Benchmarking the KServe vLLM service

## Purpose
This runbook documents the benchmark workflow for the KServe phi-chat-2 service. It covers the shell orchestrator, the Python helper scripts, the profile config files, and the generated benchmark artifacts.

## What has changed
The benchmark flow is not just a shell-only script. It  uses:
- [load-testing/scripts/run-benchmark.sh](load-testing/scripts/run-benchmark.sh) as the main orchestrator
- [load-testing/scripts/python/loadgen.py](load-testing/scripts/python/loadgen.py) to generate requests
- [load-testing/scripts/python/statistic.py](load-testing/scripts/python/statistic.py) to summarize request statistics
- [load-testing/scripts/python/metrics.py](load-testing/scripts/python/metrics.py) to query Prometheus for runtime and GPU metrics
- [load-testing/scripts/configs](load-testing/scripts/configs) for per-profile benchmark settings

## Preconditions
Before running a benchmark, verify that:
1. The KServe InferenceService is deployed and Ready in the `llm-serving` namespace.
2. The predictor endpoint is reachable.
3. Prometheus is reachable on port `9090`.
4. The local tools are installed: `kubectl`, `jq`, `curl`, and `python3`.

## Quick validation
Run these checks before benchmarking:

```bash
kubectl -n llm-serving get inferenceservice phi-chat-2
kubectl -n llm-serving get pods -o wide
kubectl -n llm-serving get svc | grep phi-chat-2-predictor
```

## Port-forwarding
A Prometheus port-forward is still required for local runs:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```

The benchmark runner can also recover the local predictor endpoint automatically when `AUTO_PORT_FORWARD_INFER=true` and the target URL is local. If you prefer to manage it manually, this is the equivalent forward:

```bash
kubectl -n llm-serving port-forward svc/phi-chat-2-predictor 8000:80
```

## Repository layout
The benchmark assets are organized like this:
- [load-testing/scripts/run-benchmark.sh](load-testing/scripts/run-benchmark.sh): main entry point
- [load-testing/scripts/python](load-testing/scripts/python): Python helpers for load generation, statistics, and Prometheus metrics
- [load-testing/scripts/configs](load-testing/scripts/configs): profile definition files such as [load-testing/scripts/configs/test-a-seqs8-batch2048.sh](load-testing/scripts/configs/test-a-seqs8-batch2048.sh)
- [load-testing/results](load-testing/results): generated CSVs, request-level JSONL files, and the benchmark log

## How to run a benchmark
From the repository root:

```bash
cd load-testing/scripts
./run-benchmark.sh help
```

### Run a single profile
```bash
cd load-testing/scripts
./run-benchmark.sh test-a-seqs8-batch2048
```

### Run the full sweep
```bash
cd load-testing/scripts
./run-benchmark.sh all
```

### macOS-friendly long run
If you want to prevent sleep while the benchmark is running:

```bash
cd load-testing/scripts
caffeinate -dimsu ./run-benchmark.sh all
```

## Execution flow
The orchestrator runs the benchmark in this order:
1. Load a profile definition from [load-testing/scripts/configs](load-testing/scripts/configs).
2. Patch the InferenceService arguments to the requested `max-num-seqs` and `max-num-batched-tokens` values.
3. Scale the predictor deployment down and back up.
4. Wait for the InferenceService to become Ready.
5. Ensure the inference endpoint is reachable.
6. Run a warmup phase and a measurement phase at each concurrency level.
7. Persist request-level results, summary JSON, and CSV rows.

Profiles are executed sequentially, not in parallel.

## Output files
The runner writes benchmark artifacts into [load-testing/results](load-testing/results):
- [load-testing/results/benchmark-summary.csv](load-testing/results/benchmark-summary.csv): high-level request success and RPS summary
- [load-testing/results/latency-vs-concurrency.csv](load-testing/results/latency-vs-concurrency.csv): latency percentiles per concurrency
- [load-testing/results/throughput-vs-concurrency.csv](load-testing/results/throughput-vs-concurrency.csv): throughput, queueing, and GPU-related metrics
- [load-testing/results/request-level](load-testing/results/request-level): per-run request JSONL and summary JSON files
- [load-testing/results/benchmark.log](load-testing/results/benchmark.log): runtime log for the full benchmark run

## What the scripts do
- [load-testing/scripts/python/loadgen.py](load-testing/scripts/python/loadgen.py): sends repeated prompt-based requests to the model endpoint with a configurable concurrency and duration.
- [load-testing/scripts/python/statistic.py](load-testing/scripts/python/statistic.py): computes request totals, success/error rates, RPS, and latency percentiles from the request-level output.
- [load-testing/scripts/python/metrics.py](load-testing/scripts/python/metrics.py): queries Prometheus for vLLM runtime metrics and GPU metrics over the measurement window.

## Profile definitions
Each profile file contains a small shell snippet that sets:
- `TEST_ID`
- `PROFILE_NAME`
- `MAX_NUM_SEQS`
- `MAX_NUM_BATCHED_TOKENS`

Examples:
- [load-testing/scripts/configs/test-a-seqs8-batch2048.sh](load-testing/scripts/configs/test-a-seqs8-batch2048.sh)
- [load-testing/scripts/configs/test-b-seqs16-batch2048.sh](load-testing/scripts/configs/test-b-seqs16-batch2048.sh)
- [load-testing/scripts/configs/test-h-seqs32-batch2048.sh](load-testing/scripts/configs/test-h-seqs32-batch2048.sh)

## Validation checks
Before trusting the results, confirm that:
- the benchmark completed without fatal errors
- the summary CSV contains rows for all expected concurrency levels
- the request-level JSONL files were written
- Prometheus metrics were returned for the run window

A lightweight syntax check can be run before a benchmark:

```bash
cd load-testing/scripts
bash -n run-benchmark.sh
python3 -m py_compile python/loadgen.py python/statistic.py python/metrics.py
```

## Troubleshooting
### InferenceService does not become Ready
```bash
kubectl -n llm-serving describe inferenceservice phi-chat-2
kubectl -n llm-serving get events --sort-by=.lastTimestamp | tail -n 40
kubectl -n llm-serving get pods -o wide
```

### Prometheus returns no data
1. Confirm the port-forward is still active on `9090`.
2. Check that the Prometheus targets for the vLLM metrics are `UP`.
3. Verify that the metrics endpoint is actually exporting the expected series.

### Requests fail or time out
1. Check the predictor pod logs.
2. Reduce the concurrency level for a smoke test.
3. Confirm the model name and endpoint remain correct.
4. Verify that the predictor port-forward is healthy if you are running locally.

### Predictor port-forward drops during rollout
This can happen while the predictor pod is being restarted between profiles. The benchmark runner attempts to recover the local inference endpoint automatically when the local URL is in use.

