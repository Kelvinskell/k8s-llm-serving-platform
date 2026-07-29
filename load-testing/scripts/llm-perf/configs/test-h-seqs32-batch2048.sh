#!/usr/bin/env bash
# Test H intent:
# - Combination profile: high concurrency with high batching.
# - Goal: maximize throughput for stress characterization.
# Expected profile:
# - highest tokens/sec candidate
# - highest TTFT and E2E latency risk
# - strongest queueing and memory-pressure behavior under load
export TEST_ID="H"
export PROFILE_NAME="seqs_32_batched_2048"
export MAX_NUM_SEQS="32"
export MAX_NUM_BATCHED_TOKENS="2048"
