# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
import argparse
import hashlib
import json
import socket
import struct
import time
from pathlib import Path
from typing import TypedDict, cast


class Request(TypedDict, total=False):
    id: int
    op: str
    seed: int
    scenario: str
    command: str
    ticks: int


class Response(TypedDict):
    id: int
    version: int
    status: str
    seed: int
    scenario: str
    tick: int
    state_hash: str
    x: float
    y: float
    z: float
    yaw: float
    pitch: float
    remaining: int
    image: str | None


class Record(TypedDict, total=False):
    request: Request
    response: Response
    image_sha256: str


class Client:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.socket.connect(("127.0.0.1", 9999))
        self.socket.settimeout(3)
        self.next_id = 1
        self.records: list[Record] = []
        self.latencies_ms: list[float] = []

    def close(self) -> None:
        self.socket.close()

    def exchange(self, request: Request) -> Response:
        data = json.dumps(request, separators=(",", ":")).encode()
        start = time.perf_counter()
        timeout = max(3.0, request.get("ticks", 0) / 120 + 3)
        for _ in range(3):
            self.socket.send(data)
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                self.socket.settimeout(max(0.01, deadline - time.monotonic()))
                try:
                    response = cast(Response, json.loads(self.socket.recv(4096)))
                except TimeoutError:
                    break
                if response["id"] == request["id"]:
                    self.latencies_ms.append((time.perf_counter() - start) * 1000)
                    return response
        raise TimeoutError(f"No response for {request}")

    def request(self, op: str, **fields: str | int) -> Response:
        request = cast(Request, {"id": self.next_id, "op": op, **fields})
        self.next_id += 1
        response = self.exchange(request)
        if response["status"] not in {"ok", "identified", "no_subject"}:
            raise AssertionError(response)
        record: Record = {"request": request, "response": response}
        if response.get("image"):
            image = self.root / cast(str, response["image"])
            pixels = image.read_bytes()
            assert pixels[:8] == b"\x89PNG\r\n\x1a\n"
            assert struct.unpack_from(">II", pixels, 16) == (1280, 720)
            record["image_sha256"] = hashlib.sha256(pixels).hexdigest()
        self.records.append(record)
        return response

    def act(self, command: str, ticks: int = 30) -> Response:
        return self.request("act", command=command, ticks=ticks)


def move_axis(client: Client, axis: str, destination: float) -> Response:
    state = client.act("wait", 180)
    commands = {
        "x": ("left", "right", 0.15),
        "y": ("down", "up", 0.1),
        "z": ("forward", "backward", 0.15),
    }
    negative, positive, per_tick = commands[axis]
    delta = destination - {"x": state["x"], "y": state["y"], "z": state["z"]}[axis]
    ticks = round(abs(delta) / per_tick)
    if ticks:
        client.act(positive if delta > 0 else negative, min(ticks, 2400))
    state = client.act("wait", 180)
    assert (
        abs({"x": state["x"], "y": state["y"], "z": state["z"]}[axis] - destination)
        < 0.2
    ), (axis, destination, state)
    return state


def verify(client: Client) -> None:
    initial = client.request("reset", seed=42, scenario="island")
    assert initial["tick"] == 0 and initial["remaining"] == 3
    image = client.request("observe")
    assert image["tick"] == 0
    assert client.exchange(client.records[-1]["request"]) == image
    assert "min_dist" not in image
    failed = client.act("identify", 1)
    assert failed["status"] == "no_subject"
    duplicate_request = client.records[-1]["request"]
    assert client.exchange(duplicate_request) == failed
    conflict = cast(Request, {**duplicate_request, "command": "forward"})
    assert client.exchange(conflict)["status"] == "id_conflict"
    assert client.request("state")["tick"] == 1
    client.act("look_down", 30)
    # These are explicit test-fixture habitat coordinates, never given to the VLM.
    for index, (x, z) in enumerate(((-27, -21), (27, -13), (5, 29)), 1):
        move_axis(client, "y", 20)
        move_axis(client, "x", x)
        move_axis(client, "z", z + 6)
        move_axis(client, "y", 7)
        before = client.request("observe")
        assert before["remaining"] == 4 - index
        identified = client.act("identify", 1)
        assert identified["status"] == "identified", identified
        assert identified["remaining"] == 3 - index
        print(f"Photographed {index}/3 at tick {identified['tick']}", flush=True)
    completed = client.request("observe")
    assert completed["remaining"] == 0
    # Old requests outside the reply cache are rejected instead of applied again.
    assert client.exchange(duplicate_request)["status"] == "stale_id"
    print(
        f"Verified {len(client.records)} requests, duplicate protection, all 3 photographs and completed observations."
    )


def replay(client: Client, path: Path) -> None:
    records: list[Record] = [
        json.loads(line) for line in path.read_text().splitlines() if line.strip()
    ]
    for entry in records:
        request = cast(dict[str, str | int], dict(entry["request"]))
        request.pop("id", None)
        op = cast(str, request.pop("op"))
        expected = entry["response"]
        if op == "reset":
            request.setdefault("seed", expected["seed"])
            request.setdefault(
                "scenario",
                "island" if expected["scenario"] == "island-photo-v2" else "legacy",
            )
        actual = client.request(op, **request)
        for key in ("tick", "state_hash", "status", "remaining"):
            assert actual[key] == expected[key], (key, expected, actual)
        if "image_sha256" in entry:
            assert client.records[-1]["image_sha256"] == entry["image_sha256"], (
                f"Image differs at tick {actual['tick']}"
            )
    print(
        f"Replayed {len(records)} requests with identical states and recorded image hashes."
    )


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Exercise or replay a running simulation without paid API calls"
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="Simulator working directory",
    )
    parser.add_argument("--replay", type=Path)
    parser.add_argument(
        "--record", type=Path, default=Path(".snapbench/verification.jsonl")
    )
    args = parser.parse_args()
    client = Client(args.root)
    try:
        if args.replay:
            replay(client, args.replay)
        else:
            verify(client)
        args.record.parent.mkdir(parents=True, exist_ok=True)
        args.record.write_text(
            "".join(
                json.dumps(record, separators=(",", ":")) + "\n"
                for record in client.records
            )
        )
        print(f"Replay saved to {args.record}")
    finally:
        client.close()


if __name__ == "__main__":
    main()
