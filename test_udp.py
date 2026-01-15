#!/usr/bin/env python3
import socket
import time
from dataclasses import dataclass

ADDR = ("127.0.0.1", 9999)
TIMEOUT = 1.0


@dataclass
class DroneState:
    x: float = 0.0
    y: float = 0.0
    z: float = 0.0
    yaw: float = 0.0

    @classmethod
    def from_response(cls, response: str) -> "DroneState":
        state = cls()
        for part in response.split():
            if "=" in part:
                key, val = part.split("=", 1)
                if hasattr(state, key):
                    setattr(state, key, float(val))
        return state


def send_command(sock: socket.socket, cmd: str) -> str:
    sock.sendto(f"{cmd}\n".encode(), ADDR)
    try:
        data, _ = sock.recvfrom(256)
        return data.decode().strip()
    except TimeoutError:
        return "TIMEOUT"


def main() -> None:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(TIMEOUT)

    commands = [
        "forward",
        "forward",
        "forward",
        "right",
        "right",
        "up",
        "rotate_right",
        "rotate_right",
        "backward",
        "identify",
    ]

    print("Testing UDP drone control\n")
    print(f"{'Command':<15} {'Response':<60}")
    print("-" * 75)

    for cmd in commands:
        response = send_command(sock, cmd)
        print(f"{cmd:<15} {response:<60}")

        if response.startswith("OK"):
            state = DroneState.from_response(response)
            print(
                f"{'':>15} → pos=({state.x:.1f}, {state.y:.1f}, {state.z:.1f}) yaw={state.yaw:.1f}°"
            )

        time.sleep(1.0)

    print("\n" + "-" * 75)
    print("Testing invalid command...")
    response = send_command(sock, "invalid_cmd")
    print(f"{'invalid_cmd':<15} {response:<60}")

    sock.close()


if __name__ == "__main__":
    main()
