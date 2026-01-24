from pathlib import Path

import tomllib

_MODELS_FILE = Path(__file__).parent / "models.toml"


def _load_config() -> list[dict]:
    with _MODELS_FILE.open("rb") as f:
        return tomllib.load(f)["models"]


def load_models() -> list[str]:
    return [m["id"] for m in _load_config()]


def calculate_cost(model: str, input_tokens: int, output_tokens: int) -> float:
    for m in _load_config():
        if m["id"] == model:
            return (
                input_tokens * m["input_cost"] + output_tokens * m["output_cost"]
            ) / 1_000_000
    return 0.0
