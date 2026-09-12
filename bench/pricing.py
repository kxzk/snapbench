import tomllib
from dataclasses import dataclass
from functools import cache
from pathlib import Path

_MODELS_FILE = Path(__file__).parent / "models.toml"


@dataclass(frozen=True)
class ModelPrice:
    id: str
    input_cost: float
    output_cost: float


@cache
def _load_config() -> tuple[ModelPrice, ...]:
    with _MODELS_FILE.open("rb") as config_file:
        models = tomllib.load(config_file)["models"]
    return tuple(
        ModelPrice(
            str(model["id"]), float(model["input_cost"]), float(model["output_cost"])
        )
        for model in models
    )


def load_models() -> list[str]:
    return [model.id for model in _load_config()]


def calculate_cost(model: str, input_tokens: int, output_tokens: int) -> float:
    for price in _load_config():
        if price.id == model:
            return (
                input_tokens * price.input_cost + output_tokens * price.output_cost
            ) / 1_000_000
    return 0.0
