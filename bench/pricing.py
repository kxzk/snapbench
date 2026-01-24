# Cost per 1M tokens: (input, output)
PRICING: dict[str, tuple[float, float]] = {
    "google/gemini-3-flash-preview": (0.50, 3.00),
    "openai/gpt-5.2-codex": (1.75, 14.00),
}


def calculate_cost(model: str, input_tokens: int, output_tokens: int) -> float:
    if model not in PRICING:
        return 0.0
    input_rate, output_rate = PRICING[model]
    return (input_tokens * input_rate + output_tokens * output_rate) / 1_000_000
