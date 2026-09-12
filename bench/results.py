import csv
import json
import os
import tempfile
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import TypedDict

from pricing import calculate_cost


@dataclass
class BenchResult:
    model: str
    status: str
    scenario: str = "island-photo-v2"
    simulation_ticks: int = 0
    replay_path: str = ""
    iterations: int = 0
    movements: int = 0
    input_tokens: int = 0
    output_tokens: int = 0
    creatures_found: int = 0
    total_ms: int = 0
    failed_identifies: int = 0
    stuck_events: int = 0
    api_errors: int = 0
    creature_times_ms: list[int] = field(default_factory=list)
    api_latencies_ms: list[int] = field(default_factory=list)
    error: str = ""


class ResultRow(TypedDict):
    model: str
    scenario: str
    simulation_ticks: int
    replay_path: str
    status: str
    iterations: int
    movements: int
    input_tokens: int
    output_tokens: int
    creatures_found: int
    total_ms: int
    failed_identifies: int
    stuck_events: int
    api_errors: int
    timestamp: str
    seed: int
    time_to_creature_1_ms: int | str
    time_to_creature_2_ms: int | str
    time_to_creature_3_ms: int | str
    avg_api_latency_ms: float
    commands_per_creature: float | str
    cost_usd: float


CSV_COLUMNS = [
    "timestamp",
    "seed",
    "model",
    "scenario",
    "simulation_ticks",
    "replay_path",
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
    "api_errors",
    "avg_api_latency_ms",
    "commands_per_creature",
    "cost_usd",
]


def parse_result(text: str, expected_model: str) -> BenchResult:
    payload: object = json.loads(text)
    if not isinstance(payload, dict):
        raise ValueError("Controller metrics must be an object")

    def string(key: str) -> str:
        value: object = payload.get(key)
        if not isinstance(value, str):
            raise ValueError(f"Invalid metric: {key}")
        return value

    def counter(key: str) -> int:
        value: object = payload.get(key)
        if not isinstance(value, int) or isinstance(value, bool) or value < 0:
            raise ValueError(f"Invalid counter: {key}")
        return value

    def counters(key: str) -> list[int]:
        values: object = payload.get(key)
        if not isinstance(values, list):
            raise ValueError(f"Invalid metric list: {key}")
        result: list[int] = []
        for value in values:
            if not isinstance(value, int) or isinstance(value, bool) or value < 0:
                raise ValueError(f"Invalid counter in {key}")
            result.append(value)
        return result

    model = string("model")
    status = string("status")
    scenario = string("scenario")
    creatures_found = counter("creatures_found")
    if model != expected_model:
        raise ValueError("Controller metrics belong to another model")
    if status not in {"in_progress", "max_iterations", "complete"}:
        raise ValueError(f"Invalid controller status: {status}")
    if scenario != "island-photo-v2" or creatures_found > 3:
        raise ValueError("Invalid photography result")
    if status == "complete" and creatures_found != 3:
        raise ValueError("Completed metrics must contain three photographs")
    return BenchResult(
        model=model,
        status=status,
        scenario=scenario,
        simulation_ticks=counter("simulation_ticks"),
        replay_path=string("replay_path"),
        iterations=counter("iterations"),
        movements=counter("movements"),
        input_tokens=counter("input_tokens"),
        output_tokens=counter("output_tokens"),
        creatures_found=creatures_found,
        total_ms=counter("total_ms"),
        failed_identifies=counter("failed_identifies"),
        stuck_events=counter("stuck_events"),
        api_errors=counter("api_errors"),
        creature_times_ms=counters("creature_times_ms"),
        api_latencies_ms=counters("api_latencies_ms"),
    )


def load_existing_results(path: Path) -> set[tuple[str, int]]:
    if not path.exists():
        return set()
    with path.open(newline="") as result_file:
        return {(row["model"], int(row["seed"])) for row in csv.DictReader(result_file)}


def save_result(path: Path, row: ResultRow) -> None:
    rows: list[dict[str, str]] = []
    if path.exists():
        with path.open(newline="") as result_file:
            rows = [
                existing
                for existing in csv.DictReader(result_file)
                if (existing["model"], int(existing["seed"]))
                != (row["model"], row["seed"])
            ]
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", newline="", dir=path.parent, delete=False
        ) as result_file:
            temporary = Path(result_file.name)
            writer = csv.DictWriter(result_file, fieldnames=CSV_COLUMNS)
            writer.writeheader()
            writer.writerows(rows)
            writer.writerow(row)
            result_file.flush()
            os.fsync(result_file.fileno())
        temporary.replace(path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def result_to_row(result: BenchResult, seed: int) -> ResultRow:
    times = result.creature_times_ms
    latencies = result.api_latencies_ms
    creatures = result.creatures_found
    movements = result.movements
    return {
        "timestamp": datetime.now(UTC).isoformat(),
        "seed": seed,
        "model": result.model,
        "scenario": result.scenario,
        "simulation_ticks": result.simulation_ticks,
        "replay_path": result.replay_path,
        "status": result.status,
        "iterations": result.iterations,
        "movements": movements,
        "input_tokens": result.input_tokens,
        "output_tokens": result.output_tokens,
        "creatures_found": creatures,
        "total_ms": result.total_ms,
        "failed_identifies": result.failed_identifies,
        "stuck_events": result.stuck_events,
        "api_errors": result.api_errors,
        "time_to_creature_1_ms": times[0] if len(times) > 0 else "",
        "time_to_creature_2_ms": times[1] if len(times) > 1 else "",
        "time_to_creature_3_ms": times[2] if len(times) > 2 else "",
        "avg_api_latency_ms": round(sum(latencies) / len(latencies), 2)
        if latencies
        else 0,
        "commands_per_creature": round(movements / creatures, 2) if creatures else "",
        "cost_usd": round(
            calculate_cost(result.model, result.input_tokens, result.output_tokens), 6
        ),
    }
