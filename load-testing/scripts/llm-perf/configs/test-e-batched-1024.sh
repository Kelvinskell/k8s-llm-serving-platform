#!/usr/bin/env bash
# Test E intent:
# - Keep max-num-seqs at baseline and set medium batch token ceiling.
# - Primary hypothesis: better batching and higher throughput than 512.
# - Often a balance candidate between throughput and latency.
export TEST_ID="E"
export PROFILE_NAME="seqs_16_batched_1024"
export MAX_NUM_SEQS="16"
export MAX_NUM_BATCHED_TOKENS="1024"
