<h3 align="center">SnapBench</h3>

> A VLM pilots a drone through a 3D world to locate and identify creatures.
> Inspired by [Pokémon Snap](https://en.wikipedia.org/wiki/Pok%C3%A9mon_Snap) (1999).

<img src="https://img.shields.io/badge/zig-black?style=flat-square&logo=zig" alt="zig">
<img src="https://img.shields.io/badge/rust-%23CE422B?style=flat-square&logo=rust" alt="rust">


![preview](./images/preview.png)

### Architecture

```mermaid
graph TD
    VLM[VLM<br><sub>OpenRouter</sub>]
    SIM[Simulation<br><sub>Zig/raylib</sub>]
    CTL[Controller<br><sub>Rust</sub>]

    VLM <-->|screenshot + prompt| CTL
    SIM <-->|cmds + state<br>UDP:9999| CTL
```

**Simulation** — Procedural terrain, spawned animals (cat/dog/pig/sheep), drone physics, collision detection. Accepts 8 movement commands + `identify` + `screenshot`.

**Controller** — Captures frames, builds prompts with position/state, parses VLM responses into command sequences.

**Task** — Find and identify 3 creatures. `identify` succeeds within 5 units of a creature.

