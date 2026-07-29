#!/usr/bin/env bash
# Test A intent:
# - Sweep lower scheduler concurrency with default batching behavior.
# - Primary hypothesis: lower TTFT and queue depth, but lower throughput.
# Potential benefits:
# - TTFT p95 down
# - requests_waiting down
# - E2E p95 down
# Potential tradeoffs:
# - tokens/sec down
# - lower GPU work efficiency possible
export TEST_ID="A"
export PROFILE_NAME="seqs_8_baseline_batching"
export MAX_NUM_SEQS="8"
export MAX_NUM_BATCHED_TOKENS="default"
