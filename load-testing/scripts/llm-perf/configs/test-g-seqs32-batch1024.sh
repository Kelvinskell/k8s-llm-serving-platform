#!/usr/bin/env bash
# Test G intent:
# - Combination profile: high concurrency with medium batching.
# - Goal: best balance between throughput and latency.
# Expected profile:
# - higher tokens/sec than baseline
# - lower latency risk than the most aggressive batch setting
export TEST_ID="G"
export PROFILE_NAME="seqs_32_batched_1024"
export MAX_NUM_SEQS="32"
export MAX_NUM_BATCHED_TOKENS="1024"
