<h3 align="center">SnapBench</h3>

> Inspired by [Pokémon Snap](https://en.wikipedia.org/wiki/Pok%C3%A9mon_Snap) (1999). VLM pilots a drone through 3D world to locate and identify creatures.

<p><img src="https://img.shields.io/badge/zig-black?style=flat-square&logo=zig" alt="zig"> <img src="https://img.shields.io/badge/rust-%23CE422B?style=flat-square&logo=rust" alt="rust"> <img src="https://img.shields.io/badge/python-%233776AB?style=flat-square&logo=python&logoColor=FFD43B" alt="python"></p>

### Architecture

```mermaid
%%{init: {'theme': 'base', 'themeVariables': { 'background': '#ffffff', 'primaryColor': '#ffffff'}}}%%
flowchart LR
    subgraph Controller["**Controller** (Rust)"]
        C[Orchestration]
    end

    subgraph VLM["**VLM** (OpenRouter)"]
        V[Vision-Language Model]
    end

    subgraph Simulation["**Simulation** (Zig/raylib)"]
        S[Game State]
    end

    C -->|"screenshot + prompt"| V
    C <-->|"cmds + state<br>**UDP:9999**"| S

    style Controller fill:#8B5A2B,stroke:#5C3A1A,color:#fff
    style VLM fill:#87CEEB,stroke:#5BA3C6,color:#1a1a1a
    style Simulation fill:#4A7C23,stroke:#2D5A10,color:#fff
    style C fill:#B8864A,stroke:#8B5A2B,color:#fff
    style V fill:#B5E0F7,stroke:#87CEEB,color:#1a1a1a
    style S fill:#6BA33A,stroke:#4A7C23,color:#fff
```

### Overview

The simulation generates procedural terrain and spawns creatures (cat, dog, pig, sheep) for the drone to discover. It handles drone physics and collision detection, accepting 8 movement commands plus `identify` and `screenshot`. The Rust controller captures frames from the simulation, constructs prompts enriched with position and state data, then parses VLM responses into executable command sequences. The objective: locate and successfully identify 3 creatures, where `identify` succeeds when the drone is within 5 units of a target.

<br>

## Gotta catch 'em all?

I gave 7 frontier LLMs a simple task: pilot a drone through a 3D voxel world and find 3 creatures.

Only one could do it.

![Benchmark Results](images/benchmark_results.png)

Is this a rigorous benchmark? No. However, it's a reasonably fair comparison - same prompt, same seeds, same iteration limits. I'm sure with enough refinement you could coax better results out of each model. But that's kind of the point: out of the box, with zero hand-holding, only one model figured out how to actually *fly*.

## Why can't Claude look down?

The core differentiator wasn't intelligence - it was **altitude control**. Creatures sit on the ground. To identify them, you need to descend.

- **Gemini Flash**: Actively adjusts altitude, descends to creature level, identifies
- **GPT-5.2-chat**: Gets close horizontally but never lowers
- **Claude Opus**: Attempts identification 160+ times, never succeeds - approaching at wrong angles
- **Others**: Wander randomly or get stuck

This left me puzzled. Claude Opus is arguably the most capable model in the lineup. It *knows* it needs to identify creatures. It tries - aggressively. But it never adjusts its approach angle.

## The two-creature anomaly

Run 13 (seed 72) was the only run where any model found 2 creatures. Why? They happened to spawn near each other. Gemini Flash found one, turned around, and spotted the second.

![Seed 72](images/seed-72.png)

In most other runs, Flash found one creature quickly but ran out of iterations searching for the others. The world is big. 50 iterations isn't a lot of time.

## Bigger ≠ better

This was the most surprising finding. I expected:
- Claude Opus 4.5 (most expensive) to dominate
- Gemini 3 Pro to outperform Gemini 3 Flash (same family, more capability)

Instead, the cheapest model beat models costing 10x more.

What's going on here? A few theories:

1. **Spatial reasoning doesn't scale with model size** - at least not yet
2. **Flash was trained differently** - maybe more robotics data, more embodied scenarios?
3. **Smaller models follow instructions more literally** - "go down" means go down, not "consider the optimal trajectory"

I genuinely don't know. But if you're building an LLM-powered agent that needs to navigate physical or virtual space, the most expensive model might not be your best choice.

## Color theory, maybe

Anecdotally, creatures with higher contrast (gray sheep, pink pigs) seemed easier to spot than brown-ish creatures that blended into the terrain. A future version might normalize creature visibility. Or maybe that's the point - real-world object detection isn't normalized either.

## Prior work

Before this, I tried having LLMs pilot a [real DJI Tello drone](https://github.com/kxzk/tello-bench).

Results: it flew straight up, hit the ceiling, and did donuts until I caught it. (I was using Haiku 4.5, which in hindsight explains a lot.)

The Tello is now broken. I've ordered a BetaFPV and might get another Tello since they're so easy to program. Now that I know Gemini Flash can actually navigate, a real-world follow-up might be worth revisiting.

## Rough edges

This is half-serious research, half "let's see what happens."

- The simulation has rough edges (it's a side project, not a polished benchmark suite)
- One blanket prompt is used for all models - model-specific tuning would likely improve results
- The feedback loop is basic (position, screenshot, recent commands) - there's room to get creative with what information gets passed back
- Iteration limits (50) may artificially cap models that are slower but would eventually succeed

## Try it yourself

### Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Zig | ≥0.15.2 | [ziglang.org/download](https://ziglang.org/download/) |
| Rust | stable (2024 edition) | [rust-lang.org/tools/install](https://rust-lang.org/tools/install/) |
| Python | ≥3.11 | [python.org](https://www.python.org/) |
| uv | latest | [docs.astral.sh/uv](https://docs.astral.sh/uv/getting-started/installation/) |

You'll also need an [OpenRouter](https://openrouter.ai/) API key.

### Setup

```bash
gh repo clone kxzk/snapbench
cd snapbench

# set your API key
export OPENROUTER_API_KEY="sk-or-..."
```

### Running the simulation manually

```bash
# terminal 1: start the simulation (with optional seed)
zig build run -Doptimize=ReleaseFast -- 42
# or
make sim

# terminal 2: start the drone controller
cargo run --release --manifest-path llm_drone/Cargo.toml -- --model google/gemini-3-flash-preview
# or
make drone
```

### Running the benchmark suite

```bash
# runs all models defined in bench/models.toml
uv run bench/bench_runner.py
# or
make bench
```

Results get saved to `data/run_<id>.csv`.

## Where this could go

- **Model-specific prompts**: Tune instructions to each model's strengths
- **Richer feedback**: Pass more spatial context (distance readings, compass, minimap?)
- **Multi-agent runs**: What if you gave each model a drone and made them compete?
- **Extended iterations**: Let slow models run longer to isolate reasoning from speed
- **Real drone benchmark**: Gemini Flash vs. the BetaFPV
- **Pokémon assets**: Found [low-poly Pokémon models](https://poly.pizza/l/Bm4vionqpU) on Poly Pizza—leaning into the Pokémon Snap inspiration
- **World improvements**: Larger terrain, better visuals, performance optimizations

<br>

## Attribution

- Drone by NateGazzard [CC-BY](https://creativecommons.org/licenses/by/3.0/) via [Poly Pizza](https://poly.pizza/m/DNbUoMtG3H)
- Cube World Kit by Quaternius via [Poly Pizza](https://poly.pizza/bundle/Cube-World-Kit-DwDr8493Fw)

*Donated to [Poly Pizza](https://poly.pizza) to support the platform.*

<br>
