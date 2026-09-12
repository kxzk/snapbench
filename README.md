# SnapBench

A vision-language-model benchmark inspired by Pokémon Snap. A model pilots a
drone around Mariner Island, finds three animals, and photographs them through
a first-person camera.

![Aerial view of Mariner Island showing coastal woodland, meadows, and animals along the paths](images/island-photo-preview.png)

The simulation pairs each image with the drone's pose and pauses while the model
decides what to do. Successful photographs require framing, visibility, and
sufficient image size. Zig/raylib runs the world, a Rust controller calls models
through OpenRouter, and Python runs the benchmark suite.

## Results

Results coming soon.

## Run the simulation

Requires **Zig 0.16.0**, **Rust with the 2024 edition**, **Python 3.11+**, and **uv**.
The renderer requires OpenGL 3.3 or newer; the tested platform is macOS on Apple
Silicon. Run commands from the repository root so assets can be found.

```sh
git clone https://github.com/kxzk/snapbench.git
cd snapbench
make sim SEED=42
```

You can fly manually without an API key. Change `SEED` to explore another layout.

| Control | Action |
| --- | --- |
| WASD / arrow keys | Fly relative to heading |
| Space / left Shift | Ascend / descend |
| Q / E | Turn |
| I / K | Tilt the camera |
| Tab | Switch chase / photography camera |
| P | Photograph a framed animal |
| R | Reset and return to manual control |
| F3 | Toggle diagnostics |
| Escape | Close |

## Let a model fly

Leave the simulation open. In a second terminal, from the repository root:

```sh
export OPENROUTER_API_KEY="your-openrouter-api-key"
make drone
```

The default controller uses Gemini 3 Flash Preview. To choose a model and limit
the run to 50 decisions:

```sh
cargo run --release --manifest-path llm_drone/Cargo.toml -- \
  --model openai/gpt-5.6-luna --max-iterations 50
```

## Run benchmarks

Close any manually running simulation first. Set `OPENROUTER_API_KEY` in the
terminal running the benchmark. The runner builds the simulator and controller,
then starts a simulation for each model/seed pair.

```sh
# All configured models; skip model/seed pairs with existing results
make bench

# One model
uv run bench/bench_runner.py --model google/gemini-3.8-flash

# Rerun that model, replacing its existing results as each run finishes
uv run bench/bench_runner.py --model google/gemini-3.8-flash --force
```

Models and token prices are configured in [bench/models.toml](bench/models.toml).
New results go to `data/results-v2.csv`; controller replay records go to
`.snapbench/replays/`. Historical data remains in `data/results.csv`.

## Development

```sh
make test   # Zig, Rust, and Python regression tests
make check  # Formatting, lints, and Python types

# With a simulation running: verify a full flight and replay it
make verify
make replay REPLAY=.snapbench/verification.jsonl
```

These checks require no model API calls. See the [simulation guide](docs/simulation-v2.md)
for the agent API, photography rules, deterministic replay, and profiling.
The [archived README](docs/archive/README-2026-09-12.md) preserves the previous
write-up and historical results.

## Credits

- Drone by NateGazzard, [CC BY](https://creativecommons.org/licenses/by/3.0/),
  via [Poly Pizza](https://poly.pizza/m/DNbUoMtG3H).
- Cube World Kit by Quaternius, via
  [Poly Pizza](https://poly.pizza/bundle/Cube-World-Kit-DwDr8493Fw).
- Manrope by the Manrope Project Authors, [SIL Open Font License](assets/fonts/OFL.txt).
  The bundled font is a static weight-550 instance of the
  [Google Fonts source](https://github.com/google/fonts/tree/main/ofl/manrope).
