# /// script
# requires-python = ">=3.11"
# dependencies = ["rich"]
# ///
import argparse
import os
import signal
import socket
import subprocess
import time
from pathlib import Path
from subprocess import DEVNULL, PIPE, TimeoutExpired

from pricing import load_models
from results import (
    BenchResult,
    ResultRow,
    load_existing_results,
    parse_result,
    result_to_row,
    save_result,
)
from rich.align import Align
from rich.console import Console
from rich.panel import Panel
from rich.progress import (
    BarColumn,
    Progress,
    SpinnerColumn,
    TextColumn,
    TimeElapsedColumn,
)
from rich.table import Table
from rich.text import Text

console = Console()

BENCH_DIR = Path(__file__).parent
ROOT_DIR = BENCH_DIR.parent
DATA_DIR = ROOT_DIR / "data"

DEFAULT_MAX_ITERATIONS = 50
DEFAULT_TIMEOUT = 300  # 5 minutes

SEEDS = [7, 23, 24, 29, 61]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="SnapBench runner")
    parser.add_argument("--model", help="Run single model (default: all models)")
    parser.add_argument(
        "--force", action="store_true", help="Re-run existing model+seed combos"
    )
    return parser.parse_args()


def kill_process_group(proc: subprocess.Popen[bytes]) -> None:
    def send_signal(sig: int) -> None:
        try:
            os.killpg(proc.pid, sig)
        except OSError:
            pass

    send_signal(signal.SIGTERM)
    try:
        proc.wait(timeout=5)
    except TimeoutExpired:
        send_signal(signal.SIGKILL)
        proc.wait()


def wait_for_simulation(sim: subprocess.Popen[bytes], timeout: float = 15) -> None:
    deadline = time.monotonic() + timeout
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
        probe.settimeout(0.1)
        while time.monotonic() < deadline:
            if sim.poll() is not None:
                raise RuntimeError(f"Simulation exited with code {sim.returncode}")
            probe.sendto(b"state", ("127.0.0.1", 9999))
            try:
                response, _ = probe.recvfrom(256)
                if response.startswith(b"OK "):
                    return
            except (TimeoutError, ConnectionRefusedError):
                continue
    raise TimeoutError("Simulation did not become ready")


def recover_result(
    checkpoint: Path, model: str, status: str, error: str = ""
) -> BenchResult:
    try:
        result = parse_result(checkpoint.read_text(), model)
    except (ValueError, OSError):
        result = BenchResult(model=model, status=status)
    result.status = status
    result.error = error
    return result


def run_benchmark(model: str, seed: int, max_iterations: int) -> BenchResult:
    # Avoid sending commands to a manually running simulation or deleting another
    # run's checkpoint when the shared port is already occupied.
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as reservation:
            reservation.bind(("127.0.0.1", 9999))
    except OSError as error:
        return BenchResult(
            model=model, status="error", error=f"Simulation port unavailable: {error}"
        )
    checkpoint = ROOT_DIR / "bench_checkpoint.json"
    checkpoint.unlink(missing_ok=True)
    sim: subprocess.Popen[bytes] | None = None
    try:
        sim = subprocess.Popen(
            [str(ROOT_DIR / "zig-out/bin/snapbench"), str(seed), "--fast-agent"],
            cwd=ROOT_DIR,
            stdout=DEVNULL,
            stderr=DEVNULL,
            start_new_session=True,
        )
        wait_for_simulation(sim)
        with subprocess.Popen(
            [
                str(ROOT_DIR / "llm_drone/target/release/llm_drone"),
                "--benchmark",
                "--model",
                model,
                "--max-iterations",
                str(max_iterations),
            ],
            cwd=ROOT_DIR,
            stdout=PIPE,
            stderr=PIPE,
            start_new_session=True,
        ) as drone:
            try:
                stdout, stderr = drone.communicate(timeout=DEFAULT_TIMEOUT)
            except TimeoutExpired:
                kill_process_group(drone)
                return recover_result(checkpoint, model, "timeout")
            finally:
                if drone.poll() is None:
                    kill_process_group(drone)

        output = stdout.decode().strip()
        if drone.returncode == 0:
            result = parse_result(output, model)
            if result.status == "in_progress":
                raise ValueError("Controller exited without final metrics")
            return result
        return recover_result(checkpoint, model, "error", stderr.decode().strip()[:400])
    except (OSError, RuntimeError, ValueError) as error:
        return recover_result(checkpoint, model, "error", str(error))
    finally:
        if sim is not None:
            kill_process_group(sim)
        checkpoint.unlink(missing_ok=True)
        checkpoint.with_suffix(".json.tmp").unlink(missing_ok=True)


def format_status(status: str) -> Text:
    colors = {
        "complete": "green",
        "timeout": "yellow",
        "max_iterations": "cyan",
        "error": "red",
    }
    return Text(status, style=colors.get(status, "white"))


def format_creatures(found: int) -> Text:
    if found == 3:
        return Text("3/3", style="bold green")
    elif found > 0:
        return Text(f"{found}/3", style="yellow")
    return Text("0/3", style="red")


def build_results_table(results: list[ResultRow]) -> Table:
    table = Table(title="Benchmark Results", show_header=True, header_style="bold cyan")
    table.add_column("Model", style="white", no_wrap=True)
    table.add_column("Status", justify="center")
    table.add_column("Creatures", justify="center")
    table.add_column("Iterations", justify="right")
    table.add_column("Time (s)", justify="right")
    table.add_column("Tokens (in/out)", justify="right")
    table.add_column("Cost", justify="right", style="green")

    for row in results:
        time_s = f"{row['total_ms'] / 1000:.1f}" if row["total_ms"] else "-"
        tokens = f"{row['input_tokens']:,}/{row['output_tokens']:,}"
        table.add_row(
            row["model"],
            format_status(row["status"]),
            format_creatures(row["creatures_found"]),
            str(row["iterations"]),
            time_s,
            tokens,
            f"${row['cost_usd']:.4f}",
        )

    return table


def main() -> None:
    DATA_DIR.mkdir(exist_ok=True)
    args = parse_args()

    models = [args.model] if args.model else load_models()

    result_path = DATA_DIR / "results-v2.csv"
    existing = set() if args.force else load_existing_results(result_path)

    work = [(m, s) for m in models for s in SEEDS if (m, s) not in existing]

    header = Panel(
        Align.center(
            f"[bold]Models:[/] {len(models)}  │  [bold]Seeds:[/] {len(SEEDS)}  │  [bold]Pending:[/] {len(work)}"
        ),
        title="[bold cyan]SnapBench[/]",
        border_style="cyan",
        expand=True,
    )
    console.print(header)
    console.print()

    if not work:
        console.print("[green]All benchmarks complete.[/]")
        return

    # Build once so startup timing does not depend on compiler/cache state.
    subprocess.run(["zig", "build", "-Doptimize=ReleaseFast"], cwd=ROOT_DIR, check=True)
    subprocess.run(
        ["cargo", "build", "--release", "--manifest-path", "llm_drone/Cargo.toml"],
        cwd=ROOT_DIR,
        check=True,
    )
    results: list[ResultRow] = []

    progress = Progress(
        SpinnerColumn(),
        TextColumn("[progress.description]{task.description}"),
        BarColumn(bar_width=None),
        TextColumn("[progress.percentage]{task.percentage:>3.0f}%"),
        TimeElapsedColumn(),
        console=console,
    )

    with progress:
        task = progress.add_task("Running benchmarks...", total=len(work))

        for model, seed in work:
            progress.update(task, description=f"[cyan]{model}[/] seed={seed}")
            result = run_benchmark(model, seed, DEFAULT_MAX_ITERATIONS)
            row = result_to_row(result, seed)
            results.append(row)
            save_result(result_path, row)

            if result.error:
                console.print(f"  [red]Error:[/] {result.error}")

            progress.advance(task)

    console.print()
    console.print(build_results_table(results))
    console.print()

    console.print(f"[dim]Results saved to:[/] [bold]{DATA_DIR / 'results-v2.csv'}[/]")


if __name__ == "__main__":
    main()
