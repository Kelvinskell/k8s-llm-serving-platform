# Runbook: Phase 7 Benchmarking with llm-perf (KServe phi-chat-2)

## Purpose
This runbook explains how to execute the benchmark run (A-H) for the KServe phi-chat-2 service and collect benchmark outputs automatically.

## Scope
This runbook covers:
- Pre-run checks
- Required port-forwards
- Running a single profile and the full A-H sweep
- Result files produced by the benchmark runner
- What to capture manually in addition to CSV output
- Common troubleshooting

## Preconditions
1. Kubernetes pipeline has completed successfully and phi-chat-2 is running.
2. InferenceService is Ready in namespace `llm-serving`.
3. Prometheus is reachable.
4. Local tools are installed: kubectl, curl, jq, bash.

## Quick Validation
Run these checks before benchmarking:

```bash
kubectl -n llm-serving get inferenceservice phi-chat-2
kubectl -n llm-serving get pods -o wide
kubectl -n llm-serving get svc | grep phi-chat-2-predictor
```

## Required Port-Forwards
Use two terminals and keep both running during benchmark execution.

Terminal 1:

```bash
kubectl -n llm-serving port-forward svc/phi-chat-2-predictor 8000:80
```

Terminal 2:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```

## Run Benchmark
Open a third terminal:

```bash
cd load-testing/scripts/llm-perf
```

### Option A: Smoke Test (recommended first)
Run baseline profile only:

```bash
./run-benchmark.sh test-b-seqs-16
```

### Option B: Full Sweep
Run A through H, then baseline B drift re-check:

```bash
./run-benchmark.sh all
```

## Execution Behavior
1. The runner loads one test profile.
2. It patches phi-chat-2 args in KServe.
3. It waits for InferenceService Ready.
4. It executes load at each concurrency level.
5. It queries Prometheus for benchmark metrics.
6. It appends rows to CSV files.
7. It moves to the next profile.

**Important:** profiles are executed sequentially, not in parallel.

## Output Files
Benchmark data is written automatically to:
- [load-testing/results/throughput-vs-concurrency.csv](load-testing/results/throughput-vs-concurrency.csv)
- [load-testing/results/ttft-vs-concurrency.csv](load-testing/results/ttft-vs-concurrency.csv)
- [load-testing/results/latency-vs-concurrency.csv](load-testing/results/latency-vs-concurrency.csv)

## Metrics Captured by Runner
- tokens/sec
- TTFT p95
- E2E p95
- decode p95
- requests running
- requests waiting
- KV cache percentage
- tensor active
- DRAM active
- success count
- error count

## Test Profile Intent
Each profile includes a header comment describing intent and likely tradeoffs. See:
- [load-testing/scripts/llm-perf/configs/test-a-seqs-8.sh](load-testing/scripts/llm-perf/configs/test-a-seqs-8.sh)
- [load-testing/scripts/llm-perf/configs/test-b-seqs-16.sh](load-testing/scripts/llm-perf/configs/test-b-seqs-16.sh)
- [load-testing/scripts/llm-perf/configs/test-c-seqs-32.sh](load-testing/scripts/llm-perf/configs/test-c-seqs-32.sh)
- [load-testing/scripts/llm-perf/configs/test-d-batched-512.sh](load-testing/scripts/llm-perf/configs/test-d-batched-512.sh)
- [load-testing/scripts/llm-perf/configs/test-e-batched-1024.sh](load-testing/scripts/llm-perf/configs/test-e-batched-1024.sh)
- [load-testing/scripts/llm-perf/configs/test-f-batched-2048.sh](load-testing/scripts/llm-perf/configs/test-f-batched-2048.sh)
- [load-testing/scripts/llm-perf/configs/test-g-seqs32-batch1024.sh](load-testing/scripts/llm-perf/configs/test-g-seqs32-batch1024.sh)
- [load-testing/scripts/llm-perf/configs/test-h-seqs32-batch2048.sh](load-testing/scripts/llm-perf/configs/test-h-seqs32-batch2048.sh)

## Troubleshooting
### InferenceService does not become Ready after profile patch
```bash
kubectl -n llm-serving describe inferenceservice phi-chat-2
kubectl -n llm-serving get events --sort-by=.lastTimestamp | tail -n 40
kubectl -n llm-serving get pods -o wide
```

### Prometheus query returns no data
1. Confirm port-forward is still active on 9090.
2. Confirm scrape targets are UP in Prometheus Status -> Targets.
3. Recheck ServiceMonitor setup and vLLM metrics availability.

### Request failures increase rapidly
1. Check predictor pod logs.
2. Reduce concurrency for a sanity pass.
3. Confirm model name in requests remains phi-2.

