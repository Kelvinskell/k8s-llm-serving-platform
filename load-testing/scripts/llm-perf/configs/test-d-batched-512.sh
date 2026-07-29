#!/usr/bin/env bash
# Test D intent:
# - Keep max-num-seqs at baseline and reduce batch token ceiling.
# - Primary hypothesis: lower throughput, potentially lower tail latency.
# Watch closely:
# - tokens/sec
# - TTFT p95
# - requests_waiting
export TEST_ID="D"
export PROFILE_NAME="seqs_16_batched_512"
export MAX_NUM_SEQS="16"
export MAX_NUM_BATCHED_TOKENS="512"
