#!/usr/bin/env bash

# Test D
#
# Intent:
# Reduce batch token ceiling.
#
# Hypothesis:
# - Lower throughput
# - Potentially lower latency

export TEST_ID="D"

export PROFILE_NAME="seqs_16_batch_512"

export MAX_NUM_SEQS="16"
export MAX_NUM_BATCHED_TOKENS="512"