<h3 align="center">SnapBench</h3>

> Inspired by [Pokémon Snap](https://en.wikipedia.org/wiki/Pok%C3%A9mon_Snap) (1999). VLM pilots a drone through 3D world to locate and identify creatures.

<p><img src="https://img.shields.io/badge/zig-black?style=flat-square&logo=zig" alt="zig"> <img src="https://img.shields.io/badge/rust-%23CE422B?style=flat-square&logo=rust" alt="rust"> <img src="https://img.shields.io/badge/python-%23FFD43B?style=flat-square&logo=python&logoColor=3776AB" alt="python"></p>

### Architecture

```
                                                           ┌─────────────────┐
                                       screenshot + prompt │       VLM       │
                                         ┌───────────────► │   (OpenRouter)  │
                ┌─────────────────┐      │                 └─────────────────┘
                │   Controller    ├──────┤
                │     (Rust)      │      │                 ┌─────────────────┐
                └─────────────────┘      │  cmds + state   │   Simulation    │
                                         └───────────────► │  (Zig/raylib)   │
                                              UDP:9999     └─────────────────┘
```

### Overview

The simulation generates procedural terrain and spawns creatures (cat, dog, pig, sheep) for the drone to discover. It handles drone physics and collision detection, accepting 8 movement commands plus `identify` and `screenshot`. The Rust controller captures frames from the simulation, constructs prompts enriched with position and state data, then parses VLM responses into executable command sequences. The objective: locate and successfully identify 3 creatures, where `identify` succeeds when the drone is within 5 units of a target.

<br>
