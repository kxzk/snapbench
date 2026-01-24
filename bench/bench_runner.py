#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# ///
import csv
import json
import os
import signal
import subprocess
import time
from pathlib import Path
from subprocess import DEVNULL, PIPE, TimeoutExpired

from pricing import calculate_cost, load_models

BENCH_DIR = Path(__file__).parent
ROOT_DIR = BENCH_DIR.parent
DATA_DIR = ROOT_DIR / "data"

DEFAULT_SEED = 24
DEFAULT_MAX_ITERATIONS = 50
DEFAULT_TIMEOUT = 300  # 5 minutes

CSV_COLUMNS = [
    "run_id",
    "seed",
    "model",
    "status",
    "iterations",
    "movements",
    "input_tokens",
    "output_tokens",
    "creatures_found",
    "time_to_creature_1_ms",
    "time_to_creature_2_ms",
    "time_to_creature_3_ms",
    "total_ms",
    "failed_identifies",
    "stuck_events",
    "avg_api_latency_ms",
    "commands_per_creature",
    "cost_usd",
]


def get_next_run_id() -> int:
    path = DATA_DIR / "run_id.txt"
    current = int(path.read_text().strip()) if path.exists() else -1
    next_id = current + 1
    path.write_text(str(next_id))
    return next_id


def kill_process_group(proc: subprocess.Popen) -> None:
    def send_signal(sig: int) -> None:
        try:
            os.killpg(os.getpgid(proc.pid), sig)
        except (ProcessLookupError, OSError):
            pass

    send_signal(signal.SIGTERM)
    try:
        proc.wait(timeout=5)
    except TimeoutExpired:
        send_signal(signal.SIGKILL)


def run_benchmark(model: str, seed: int, max_iterations: int) -> dict:
    sim = subprocess.Popen(
        ["zig", "build", "run", "-Doptimize=ReleaseFast", "--", str(seed)],
        cwd=ROOT_DIR,
        stdout=DEVNULL,
        stderr=DEVNULL,
        start_new_session=True,
    )
    time.sleep(2)

    try:
        drone = subprocess.Popen(
            [
                "cargo",
                "run",
                "--release",
                "--manifest-path",
                "llm_drone/Cargo.toml",
                "--",
                "--benchmark",
                "--model",
                model,
                "--max-iterations",
                str(max_iterations),
            ],
            cwd=ROOT_DIR,
            stdout=PIPE,
            stderr=PIPE,
        )

        try:
            stdout, stderr = drone.communicate(timeout=DEFAULT_TIMEOUT)
        except TimeoutExpired:
            drone.kill()
            return {"model": model, "status": "timeout"}

        output = stdout.decode().strip()
        stderr_text = stderr.decode().strip()

        # Find JSON output (skip cargo build messages)
        json_lines = [line for line in output.split("\n") if line.startswith("{")]
        if json_lines:
            return json.loads(json_lines[0])

        return {
            "model": model,
            "status": "error",
            "error": f"No JSON. stdout: {output[:200]}, stderr: {stderr_text[:200]}",
        }

    finally:
        kill_process_group(sim)


def result_to_row(result: dict, run_id: int, seed: int) -> dict:
    row = {
        "run_id": run_id,
        "seed": seed,
        "model": result.get("model", ""),
        "status": result.get("status", "error"),
        "iterations": result.get("iterations", 0),
        "movements": result.get("movements", 0),
        "input_tokens": result.get("input_tokens", 0),
        "output_tokens": result.get("output_tokens", 0),
        "creatures_found": result.get("creatures_found", 0),
        "total_ms": result.get("total_ms", 0),
        "failed_identifies": result.get("failed_identifies", 0),
        "stuck_events": result.get("stuck_events", 0),
    }

    # Creature discovery times
    times = result.get("creature_times_ms", [])
    row["time_to_creature_1_ms"] = times[0] if len(times) > 0 else ""
    row["time_to_creature_2_ms"] = times[1] if len(times) > 1 else ""
    row["time_to_creature_3_ms"] = times[2] if len(times) > 2 else ""

    # Average API latency
    latencies = result.get("api_latencies_ms", [])
    row["avg_api_latency_ms"] = (
        round(sum(latencies) / len(latencies), 2) if latencies else 0
    )

    # Efficiency metrics
    creatures = row["creatures_found"]
    row["commands_per_creature"] = (
        round(row["movements"] / creatures, 2) if creatures > 0 else ""
    )

    # Cost calculation
    row["cost_usd"] = round(
        calculate_cost(row["model"], row["input_tokens"], row["output_tokens"]), 6
    )

    return row


def main() -> None:
    DATA_DIR.mkdir(exist_ok=True)

    run_id = get_next_run_id()
    models = load_models()
    seed = DEFAULT_SEED

    print(f"=== Benchmark Run {run_id} ===")
    print(f"Seed: {seed}")
    print(f"Models: {models}")
    print()

    results: list[dict] = []

    for model in models:
        print(f"Running: {model}...")
        result = run_benchmark(model, seed, DEFAULT_MAX_ITERATIONS)
        row = result_to_row(result, run_id, seed)
        results.append(row)

        status = row["status"]
        creatures = row["creatures_found"]
        cost = row["cost_usd"]
        print(f"  Status: {status}, Creatures: {creatures}/3, Cost: ${cost:.6f}")
        if "error" in result:
            print(f"  Error: {result['error']}")
        print()

    csv_path = DATA_DIR / f"run_{run_id}.csv"
    with csv_path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=CSV_COLUMNS)
        writer.writeheader()
        writer.writerows(results)

    print(f"Results written to: {csv_path}")


if __name__ == "__main__":
    main()
