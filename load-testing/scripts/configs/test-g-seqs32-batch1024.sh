#!/usr/bin/env bash

# Test G
#
# Intent:
# Higher scheduler concurrency with medium batching.
#
# Hypothesis:
# Potential throughput/latency sweet spot.

export TEST_ID="G"

export PROFILE_NAME="seqs_32_batch_1024"

export MAX_NUM_SEQS="32"
export MAX_NUM_BATCHED_TOKENS="1024"