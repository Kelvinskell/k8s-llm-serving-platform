#!/usr/bin/env python3

"""
loadgen.py

Async load generator for vLLM / KServe benchmarking.

Goals
-----
- Maintain true target concurrency.
- Separate warmup from measurement.
- Persist request-level results.
- Persist benchmark summary JSON.
- Provide live benchmark progress.

This script intentionally contains:
- NO Prometheus logic
- NO CSV writing
- NO Kubernetes logic

Those responsibilities belong elsewhere.
"""

import argparse
import asyncio
import itertools
import json
import signal
import statistics as statistics_lib
import time
from pathlib import Path

import aiohttp


STOP_REQUESTED = False


def handle_signal(signum, frame):
    """Gracefully stop on SIGINT/SIGTERM."""
    global STOP_REQUESTED
    STOP_REQUESTED = True


signal.signal(signal.SIGINT, handle_signal)
signal.signal(signal.SIGTERM, handle_signal)


class BenchmarkState:
    """
    Shared benchmark state.

    Tracks:
    - Request counts
    - Success/failure counts
    - Active requests
    - Latency distribution
    """

    def __init__(self):
        self.started = 0
        self.completed = 0
        self.successes = 0
        self.errors = 0
        self.active_requests = 0
        self.latencies_ms = []


def percentile(values, pct):
    """
    Calculate percentile using linear interpolation.
    """

    if not values:
        return 0.0

    values = sorted(values)

    if len(values) == 1:
        return float(values[0])

    k = (len(values) - 1) * (pct / 100.0)

    f = int(k)
    c = min(f + 1, len(values) - 1)

    if f == c:
        return float(values[f])

    return float(
        values[f] + (values[c] - values[f]) * (k - f)
    )


async def single_request(
    session,
    url,
    payload,
    timeout_seconds,
):
    """
    Execute a single inference request.
    """

    start = time.perf_counter()

    try:
        async with session.post(
            url,
            json=payload,
            timeout=aiohttp.ClientTimeout(
                total=timeout_seconds
            ),
        ) as response:

            await response.read()

            latency_ms = (
                time.perf_counter() - start
            ) * 1000

            return {
                "status": response.status,
                "success": response.status == 200,
                "latency_ms": round(latency_ms, 3),
                "error": None,
            }

    except Exception as exc:

        latency_ms = (
            time.perf_counter() - start
        ) * 1000

        return {
            "status": 0,
            "success": False,
            "latency_ms": round(latency_ms, 3),
            "error": str(exc),
        }


async def run_phase(
    *,
    phase_name,
    duration_seconds,
    concurrency,
    url,
    payload,
    timeout_seconds,
    state,
    request_file=None,
):
    """
    Maintain the requested concurrency level.

    As soon as one request completes,
    another request is immediately started
    until the phase duration expires.
    """

    print(
        f"\n[{phase_name.upper()}] "
        f"starting "
        f"(duration={duration_seconds}s, "
        f"concurrency={concurrency})",
        flush=True,
    )

    phase_end = time.time() + duration_seconds

    request_counter = itertools.count(1)

    connector = aiohttp.TCPConnector(
        limit=0,
        ttl_dns_cache=300,
    )

    async with aiohttp.ClientSession(
        connector=connector
    ) as session:

        async def worker():

            while (
                not STOP_REQUESTED
                and time.time() < phase_end
            ):
                request_id = next(request_counter)

                state.active_requests += 1
                state.started += 1

                result = await single_request(
                    session=session,
                    url=url,
                    payload=payload,
                    timeout_seconds=timeout_seconds,
                )

                state.active_requests -= 1
                state.completed += 1

                if result["success"]:
                    state.successes += 1
                else:
                    state.errors += 1

                state.latencies_ms.append(
                    result["latency_ms"]
                )

                #
                # Persist request-level artifacts
                # during measurement phase only.
                #
                if request_file is not None:

                    record = {
                        "request_id": request_id,
                        "timestamp": int(time.time()),
                        **result,
                    }

                    request_file.write(
                        json.dumps(record) + "\n"
                    )

        tasks = [
            asyncio.create_task(worker())
            for _ in range(concurrency)
        ]

        while (
            time.time() < phase_end
            and not STOP_REQUESTED
        ):
            await asyncio.sleep(5)

            recent_latencies = (
                state.latencies_ms[-500:]
            )

            avg_latency = (
                statistics_lib.mean(recent_latencies)
                if recent_latencies
                else 0
            )

            print(
                f"""
--------------------------------------------------
Phase              : {phase_name}
Active Requests    : {state.active_requests}
Started Requests   : {state.started}
Completed Requests : {state.completed}
Successes          : {state.successes}
Errors             : {state.errors}
Avg Latency (ms)   : {avg_latency:.2f}
--------------------------------------------------
""",
                flush=True,
            )

        await asyncio.gather(*tasks)


def build_summary(
    *,
    run_start,
    run_end,
    concurrency,
    state,
):
    """
    Build machine-readable summary for downstream
    metrics collection and CSV reporting.
    """

    elapsed = max(
        run_end - run_start,
        1,
    )

    return {
        "run_start": int(run_start),
        "run_end": int(run_end),

        "concurrency": concurrency,

        "requests_started": state.started,
        "requests_completed": state.completed,

        "successes": state.successes,
        "errors": state.errors,

        "rps": round(
            state.completed / elapsed,
            3,
        ),

        "latency_p50_ms": round(
            percentile(
                state.latencies_ms,
                50,
            ),
            3,
        ),

        "latency_p95_ms": round(
            percentile(
                state.latencies_ms,
                95,
            ),
            3,
        ),

        "latency_p99_ms": round(
            percentile(
                state.latencies_ms,
                99,
            ),
            3,
        ),
    }


async def main():

    parser = argparse.ArgumentParser()

    parser.add_argument(
        "--url",
        required=True,
    )

    parser.add_argument(
        "--model",
        required=True,
    )

    parser.add_argument(
        "--prompt",
        required=True,
    )

    parser.add_argument(
        "--concurrency",
        type=int,
        required=True,
    )

    parser.add_argument(
        "--warmup",
        type=int,
        default=120,
    )

    parser.add_argument(
        "--duration",
        type=int,
        default=480,
    )

    parser.add_argument(
        "--timeout",
        type=int,
        default=120,
    )

    parser.add_argument(
        "--max-tokens",
        type=int,
        default=128,
    )

    parser.add_argument(
        "--temperature",
        type=float,
        default=0.2,
    )

    parser.add_argument(
        "--output",
        required=True,
        help="Request-level JSONL output file",
    )

    parser.add_argument(
        "--summary-file",
        required=True,
        help="Benchmark summary JSON output file",
    )

    args = parser.parse_args()

    payload = {
        "model": args.model,
        "prompt": args.prompt,
        "max_tokens": args.max_tokens,
        "temperature": args.temperature,
    }

    output_path = Path(args.output)
    summary_path = Path(args.summary_file)

    output_path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    summary_path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    print(
        "\nBenchmark Configuration\n"
        "=======================\n"
        f"URL          : {args.url}\n"
        f"Model        : {args.model}\n"
        f"Concurrency  : {args.concurrency}\n"
        f"Warmup       : {args.warmup}s\n"
        f"Duration     : {args.duration}s\n"
        f"Output       : {output_path}\n"
        f"Summary File : {summary_path}\n",
        flush=True,
    )

    #
    # Warmup phase.
    #
    warmup_state = BenchmarkState()

    await run_phase(
        phase_name="warmup",
        duration_seconds=args.warmup,
        concurrency=args.concurrency,
        url=args.url,
        payload=payload,
        timeout_seconds=args.timeout,
        state=warmup_state,
        request_file=None,
    )

    print(
        "\nWarmup completed.\n"
        "Beginning measurement phase.\n",
        flush=True,
    )

    #
    # Measurement phase.
    #
    measurement_state = BenchmarkState()

    run_start = time.time()

    with output_path.open(
        "w",
        encoding="utf-8",
    ) as request_file:

        await run_phase(
            phase_name="measurement",
            duration_seconds=args.duration,
            concurrency=args.concurrency,
            url=args.url,
            payload=payload,
            timeout_seconds=args.timeout,
            state=measurement_state,
            request_file=request_file,
        )

    run_end = time.time()

    summary = build_summary(
        run_start=run_start,
        run_end=run_end,
        concurrency=args.concurrency,
        state=measurement_state,
    )

    #
    # Persist benchmark summary.
    #
    with summary_path.open(
        "w",
        encoding="utf-8",
    ) as summary_file:

        json.dump(
            summary,
            summary_file,
            indent=2,
        )

    print(
        "\nBenchmark summary written to:\n"
        f"{summary_path}\n",
        flush=True,
    )


if __name__ == "__main__":
    asyncio.run(main())
