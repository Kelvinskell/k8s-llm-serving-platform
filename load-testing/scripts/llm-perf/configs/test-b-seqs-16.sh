#!/usr/bin/env bash
# Test B intent:
# - Baseline profile for comparison and drift checks.
# - Keeps max-num-seqs at current reference and batching default.
export TEST_ID="B"
export PROFILE_NAME="seqs_16_baseline_batching"
export MAX_NUM_SEQS="16"
export MAX_NUM_BATCHED_TOKENS="default"
