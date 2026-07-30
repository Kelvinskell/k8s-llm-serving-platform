#!/usr/bin/env bash

# Test C
#
# Intent:
# Higher scheduler concurrency.
#
# Hypothesis:
# - Higher throughput
# - Higher scheduler pressure

export TEST_ID="C"

export PROFILE_NAME="seqs_32_batch_2048"

export MAX_NUM_SEQS="32"
export MAX_NUM_BATCHED_TOKENS="2048"