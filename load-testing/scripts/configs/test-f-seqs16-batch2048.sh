#!/usr/bin/env bash

# Test F
#
# Intent:
# Baseline repeat run.
#
# Purpose:
# Detect benchmark drift and run-to-run variance.

export TEST_ID="F"

export PROFILE_NAME="seqs_16_batch_2048_repeat"

export MAX_NUM_SEQS="16"
export MAX_NUM_BATCHED_TOKENS="2048"