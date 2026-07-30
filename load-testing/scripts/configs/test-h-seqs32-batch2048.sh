#!/usr/bin/env bash

# Test H
#
# Intent:
# Most aggressive profile in this test suite.
#
# Hypothesis:
# Highest throughput potential,
# but increased saturation risk.

export TEST_ID="H"

export PROFILE_NAME="seqs_32_batch_2048"

export MAX_NUM_SEQS="32"
export MAX_NUM_BATCHED_TOKENS="2048"