#!/usr/bin/env bash
# Test F intent:
# - Keep max-num-seqs at baseline and set high batch token ceiling.
# - Primary hypothesis: highest throughput and efficiency, with latency risk.
# Potential benefits:
# - tokens/sec up
# - tensor activity may improve
# Potential tradeoffs:
# - TTFT p95 up
# - E2E p95 up
# - requests_waiting up under pressure
export TEST_ID="F"
export PROFILE_NAME="seqs_16_batched_2048"
export MAX_NUM_SEQS="16"
export MAX_NUM_BATCHED_TOKENS="2048"
