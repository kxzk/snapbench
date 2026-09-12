import csv
import json
import unittest
from dataclasses import asdict
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

from bench_runner import build_results_table, recover_result, run_benchmark
from results import CSV_COLUMNS, BenchResult, parse_result, result_to_row, save_result


class ResultTests(unittest.TestCase):
    def test_timeout_without_metrics_fills_every_csv_column(self) -> None:
        row = result_to_row(BenchResult(model="test", status="timeout"), 42)
        self.assertEqual(set(row), set(CSV_COLUMNS))
        self.assertEqual(row["creatures_found"], 0)
        self.assertEqual(row["commands_per_creature"], "")
        self.assertNotIn("min_distance_to_creature", row)
        self.assertEqual(row["scenario"], "island-photo-v2")
        self.assertEqual(build_results_table([row]).row_count, 1)

    def test_discovery_times_and_efficiency_are_preserved(self) -> None:
        row = result_to_row(
            BenchResult(
                model="test",
                status="complete",
                creatures_found=3,
                movements=12,
                creature_times_ms=[100, 200, 300],
                api_latencies_ms=[10, 20],
            ),
            42,
        )
        self.assertEqual(row["time_to_creature_3_ms"], 300)
        self.assertEqual(row["commands_per_creature"], 4)
        self.assertEqual(row["avg_api_latency_ms"], 15)

    def test_controller_metrics_are_validated_before_use(self) -> None:
        result = BenchResult(model="test", status="in_progress", input_tokens=120)
        payload = asdict(result)
        self.assertEqual(parse_result(json.dumps(payload), "test"), result)
        invalid: list[object] = [None, [], "text", {}, {**payload, "model": "other"}]
        for key, value in (
            ("input_tokens", -1),
            ("input_tokens", True),
            ("movements", "12"),
            ("creatures_found", 4),
            ("api_latencies_ms", ["slow"]),
            ("creature_times_ms", None),
            ("status", "complete"),
            ("scenario", "legacy-proximity-v1"),
        ):
            invalid.append({**payload, key: value})
        for invalid_payload in invalid:
            with self.subTest(payload=invalid_payload), self.assertRaises(ValueError):
                parse_result(json.dumps(invalid_payload), "test")

    def test_recovery_preserves_metrics_for_timeouts_and_controller_errors(
        self,
    ) -> None:
        with TemporaryDirectory() as directory:
            checkpoint = Path(directory) / "checkpoint.json"
            checkpoint.write_text(
                json.dumps(
                    asdict(
                        BenchResult(
                            model="test",
                            status="in_progress",
                            input_tokens=123,
                            creatures_found=1,
                        )
                    )
                )
            )
            for status in ("timeout", "error"):
                result = recover_result(checkpoint, "test", status, "interrupted")
                self.assertEqual(result.input_tokens, 123)
                self.assertEqual(result.creatures_found, 1)
                self.assertEqual(result.status, status)
                self.assertEqual(result.error, "interrupted")
            self.assertEqual(
                recover_result(checkpoint, "other", "timeout").input_tokens, 0
            )
            checkpoint.write_text("[]")
            self.assertEqual(
                recover_result(checkpoint, "test", "timeout").input_tokens, 0
            )

    def test_rerun_replaces_only_its_seed_and_failed_write_preserves_results(
        self,
    ) -> None:
        with TemporaryDirectory() as directory:
            path = Path(directory) / "results.csv"
            result = BenchResult(model="test", status="max_iterations")
            save_result(path, result_to_row(result, 7))
            save_result(path, result_to_row(result, 42))
            original = path.read_bytes()
            result.creatures_found = 2
            with patch.object(Path, "replace", side_effect=OSError("disk error")):
                with self.assertRaises(OSError):
                    save_result(path, result_to_row(result, 42))
            self.assertEqual(path.read_bytes(), original)
            self.assertEqual(list(path.parent.iterdir()), [path])
            save_result(path, result_to_row(result, 42))
            with path.open() as result_file:
                rows = list(csv.DictReader(result_file))
            self.assertEqual(len(rows), 2)
            self.assertEqual([row["creatures_found"] for row in rows], ["0", "2"])

    def test_simulator_startup_error_becomes_a_result(self) -> None:
        with (
            TemporaryDirectory() as directory,
            patch("bench_runner.ROOT_DIR", Path(directory)),
            patch("bench_runner.socket.socket"),
            patch(
                "bench_runner.subprocess.Popen", side_effect=OSError("missing binary")
            ),
        ):
            result = run_benchmark("test", 42, 1)
        self.assertEqual(result.status, "error")
        self.assertIn("missing binary", result.error)
