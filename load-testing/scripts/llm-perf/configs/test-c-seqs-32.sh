#!/usr/bin/env bash
# Test C intent:
# - Sweep higher scheduler concurrency with default batching behavior.
# - Primary hypothesis: throughput up, but latency and queueing risk up.
# Potential benefits:
# - tokens/sec up
# - requests_running up
# Potential tradeoffs:
# - TTFT p95 up
# - E2E p95 up
# - possible diminishing returns at saturation
export TEST_ID="C"
export PROFILE_NAME="seqs_32_baseline_batching"
export MAX_NUM_SEQS="32"
export MAX_NUM_BATCHED_TOKENS="default"
