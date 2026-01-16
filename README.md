<h3 align="center">SnapBench</h3>

> A VLM pilots a drone through a 3D world to locate and identify creatures.
>
> Inspired by [Pokémon Snap](https://en.wikipedia.org/wiki/Pok%C3%A9mon_Snap) (1999).

<p><img src="https://img.shields.io/badge/zig-black?style=for-the-badge&logo=zig" alt="zig"> <img src="https://img.shields.io/badge/rust-%23CE422B?style=for-the-badge&logo=rust" alt="rust"></p>


![preview](./images/preview.png)

### Architecture

```mermaid
graph LR
    VLM["VLM<br/><sub>OpenRouter</sub>"]
    SIM["Simulation<br/><sub>Zig/raylib</sub>"]
    CTL["Controller<br/><sub>Rust</sub>"]
    VLM <-->|"screenshot + prompt"| CTL
    SIM <-->|"cmds + state<br/>UDP:9999"| CTL
```

### Overview

The simulation generates procedural terrain and spawns creatures (cat, dog, pig, sheep) for the drone to discover. It handles drone physics and collision detection, accepting 8 movement commands plus `identify` and `screenshot`. The Rust controller captures frames from the simulation, constructs prompts enriched with position and state data, then parses VLM responses into executable command sequences. The objective: locate and successfully identify 3 creatures, where `identify` succeeds when the drone is within 5 units of a target.

<br>
