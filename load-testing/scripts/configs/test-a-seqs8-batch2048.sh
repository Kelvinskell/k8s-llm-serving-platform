#!/usr/bin/env bash

# Test A
#
# Intent:
# Lower scheduler concurrency than baseline.
#
# Hypothesis:
# - Lower TTFT
# - Lower queueing
# - Lower throughput

export TEST_ID="A"

export PROFILE_NAME="seqs_8_batch_2048"

export MAX_NUM_SEQS="8"
export MAX_NUM_BATCHED_TOKENS="2048"