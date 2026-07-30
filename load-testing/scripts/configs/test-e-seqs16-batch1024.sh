#!/usr/bin/env bash

# Test E
#
# Intent:
# Mid-point batching profile.
#
# Hypothesis:
# Balance latency and throughput.

export TEST_ID="E"

export PROFILE_NAME="seqs_16_batch_1024"

export MAX_NUM_SEQS="16"
export MAX_NUM_BATCHED_TOKENS="1024"