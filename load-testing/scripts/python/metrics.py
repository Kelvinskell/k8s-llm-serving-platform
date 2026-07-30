#!/usr/bin/env python3

"""
metrics.py

Collect Prometheus metrics for the EXACT benchmark window.

The benchmark window is produced by loadgen.py:

    run_start
    run_end

Unlike the original Bash implementation, this script does NOT use
rolling windows such as:

    rate(...[1m])
    max_over_time(...[5m])

Those approaches can blend multiple benchmark runs together.

Instead:

    1. Query Prometheus for the exact test window.
    2. Retrieve raw samples.
    3. Calculate statistics ourselves.

Outputs:
    - token throughput
    - scheduler activity
    - queue activity
    - KV cache utilization
    - GPU activity
"""

import argparse
import json
import statistics

import requests


class PrometheusClient:
    """
    Minimal Prometheus wrapper.

    Supports:
        - query_range
        - query (instant)
    """

    def __init__(self, prom_url):
        self.prom_url = prom_url.rstrip("/")

    def query_range(
        self,
        query,
        start,
        end,
        step="15s",
    ):
        """
        Fetch all samples for a metric during the benchmark window.
        """

        response = requests.get(
            f"{self.prom_url}/api/v1/query_range",
            params={
                "query": query,
                "start": start,
                "end": end,
                "step": step,
            },
            timeout=60,
        )

        response.raise_for_status()

        payload = response.json()

        result = (
            payload
            .get("data", {})
            .get("result", [])
        )

        values = []

        for series in result:
            for _, value in series.get("values", []):

                try:
                    values.append(float(value))
                except Exception:
                    pass

        return values

    def query_instant(
        self,
        query,
        timestamp,
    ):
        """
        Execute an instant query at a specific timestamp.
        """

        response = requests.get(
            f"{self.prom_url}/api/v1/query",
            params={
                "query": query,
                "time": timestamp,
            },
            timeout=60,
        )

        response.raise_for_status()

        payload = response.json()

        result = (
            payload
            .get("data", {})
            .get("result", [])
        )

        if not result:
            return None

        try:
            return float(
                result[0]["value"][1]
            )
        except Exception:
            return None


def safe_avg(values):
    """
    Average with empty-list protection.
    """

    return (
        round(statistics.mean(values), 3)
        if values else 0
    )


def safe_max(values):
    """
    Maximum with empty-list protection.
    """

    return round(max(values), 3) if values else 0


def build_selector(
    namespace,
    pod_regex,
):
    """
    Common Prometheus label selector.
    """

    return (
        f'namespace="{namespace}",'
        f'pod=~"{pod_regex}"'
    )


def main():

    parser = argparse.ArgumentParser(
        description=(
            "Collect benchmark metrics "
            "from Prometheus."
        )
    )

    parser.add_argument(
        "--prom-url",
        required=True,
    )

    parser.add_argument(
        "--namespace",
        required=True,
    )

    parser.add_argument(
        "--pod-regex",
        required=True,
    )

    parser.add_argument(
        "--start",
        required=True,
        type=int,
    )

    parser.add_argument(
        "--end",
        required=True,
        type=int,
    )

    args = parser.parse_args()

    prom = PrometheusClient(
        args.prom_url
    )

    benchmark_duration_seconds = (
        args.end - args.start
    )

    if benchmark_duration_seconds <= 0:
        raise ValueError(
            "Benchmark end time must be greater "
            "than benchmark start time."
        )

    selector = build_selector(
        args.namespace,
        args.pod_regex,
    )

    #
    # vLLM scheduler metrics.
    #
    running_query = (
        f'vllm:num_requests_running'
        f'{{{selector}}}'
    )

    waiting_query = (
        f'vllm:num_requests_waiting'
        f'{{{selector}}}'
    )

    kv_cache_query = (
        f'100 * '
        f'vllm:kv_cache_usage_perc'
        f'{{{selector}}}'
    )

    running_samples = prom.query_range(
        running_query,
        args.start,
        args.end,
    )

    waiting_samples = prom.query_range(
        waiting_query,
        args.start,
        args.end,
    )

    kv_cache_samples = prom.query_range(
        kv_cache_query,
        args.start,
        args.end,
    )

    #
    # GPU metrics.
    #
    tensor_query = (
        "DCGM_FI_PROF_PIPE_TENSOR_ACTIVE"
    )

    dram_query = (
        "DCGM_FI_PROF_DRAM_ACTIVE"
    )

    tensor_samples = prom.query_range(
        tensor_query,
        args.start,
        args.end,
    )

    dram_samples = prom.query_range(
        dram_query,
        args.start,
        args.end,
    )

    #
    # Token throughput.
    #
    # Query the cumulative counter at:
    #
    #   benchmark start
    #   benchmark end
    #
    # Then compute:
    #
    #   tokens_total =
    #       end - start
    #
    token_counter_query = (
        f'sum('
        f'vllm:generation_tokens_total'
        f'{{{selector}}}'
        f')'
    )

    tokens_start = prom.query_instant(
        token_counter_query,
        args.start,
    )

    tokens_end = prom.query_instant(
        token_counter_query,
        args.end,
    )

    tokens_total = 0

    if (
        tokens_start is not None
        and tokens_end is not None
    ):
        tokens_total = max(
            tokens_end - tokens_start,
            0,
        )

    tokens_per_sec = (
        tokens_total /
        benchmark_duration_seconds
    )

    metrics = {

        #
        # Benchmark window.
        #
        "benchmark_duration_seconds":
            benchmark_duration_seconds,

        #
        # Token generation.
        #
        "tokens_total":
            round(tokens_total, 3),

        "tokens_per_sec":
            round(tokens_per_sec, 3),

        #
        # Running requests.
        #
        "requests_running_avg":
            safe_avg(running_samples),

        "requests_running_max":
            safe_max(running_samples),

        #
        # Waiting requests.
        #
        "requests_waiting_avg":
            safe_avg(waiting_samples),

        "requests_waiting_max":
            safe_max(waiting_samples),

        #
        # KV cache utilisation.
        #
        "kv_cache_pct_avg":
            safe_avg(kv_cache_samples),

        "kv_cache_pct_max":
            safe_max(kv_cache_samples),

        #
        # Tensor activity.
        #
        "tensor_active_avg":
            safe_avg(tensor_samples),

        "tensor_active_max":
            safe_max(tensor_samples),

        #
        # DRAM activity.
        #
        "dram_active_avg":
            safe_avg(dram_samples),

        "dram_active_max":
            safe_max(dram_samples),
    }

    print(
        json.dumps(
            metrics,
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
