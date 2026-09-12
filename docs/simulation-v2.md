# Island photography simulation

`island-photo-v2` changes world composition, observations, action timing, and
success rules. Its scores belong in a separate result set: the runner writes
`data/results-v2.csv`, preserving historical data and images.

## Play

Run `zig build run -Doptimize=ReleaseFast -- 42`. Add `--scenario legacy` for
original seeded layouts and proximity identification. Both scenarios use the
modern renderer and corrected controls; legacy mode does not reproduce old bugs.

| Control | Action |
| --- | --- |
| WASD / arrows | Move relative to heading |
| Space / left Shift | Ascend / descend |
| Q / E | Turn |
| I / K | Tilt the photography camera |
| Tab | Switch chase / photography view |
| P | Record a framed subject using the photography camera |
| F3 | Toggle frame rate, visible chunks, pose, seed, and tick |
| R | Reset the seed and return to keyboard control |
| Escape | Close |

The drone banks with movement and its rotors spin. Idle animations and wind use
simulation time. The chase camera retracts at obstacles and eases back out.
Trees collide primarily at their trunks; their opaque crowns also obstruct camera
sweeps and photography rays. Solid decorations use smaller cylinders rather than
occupying entire terrain cells. These are simplified colliders, not triangle-level
rigid-body physics. The three habitat centers are fixed landmarks; seeds vary
terrain, decoration placement, and species.

## Photography

The sensor is a first-person 1280×720 camera with a 60° vertical field of view.
Its image contains neither HUD hints nor the drone body. Pose and orientation are
returned separately. Exact target positions, nearest-target distance, and the
human framing indicator are not supplied to the v2 controller.

An animal must be within 40 units, have its approximate body bounds inside the
central 95% of the image, and project at least 24 pixels in height. At least two
of three body-height visibility rays must reach it. Visibility uses terrain and
simplified opaque-object bounds. The closest eligible animal is recorded and
removed. `remaining=0` completes the study. Animated bodies are normalized to the
catalogue's species dimensions.

## JSON API

UDP binds only `127.0.0.1:9999`. Send UTF-8 JSON, one outstanding request at a time.
IDs are positive, monotonically increasing integers up to 2^53−1. A new client
starts with `reset`, taking ownership and pausing time between explicit actions.
A reset from another client transfers control.

```json
{"id":1,"op":"reset","seed":42,"scenario":"island"}
{"id":2,"op":"act","command":"forward","ticks":30}
{"id":3,"op":"observe"}
{"id":4,"op":"state"}
```

Actions: `forward`, `backward`, `left`, `right`, `up`, `down`, `rotate_left`,
`rotate_right`, `look_up`, `look_down`, `wait`, `identify`.

Actions run for 1–2400 ticks at 120 ticks/second, defaulting to 30. `identify`
evaluates the final pose. Horizontal target speed is 18 units/s, vertical target
speed is 12 units/s, yaw is 90°/s, and camera tilt is 45°/s. Movement smoothing
continues during `wait`.

Visible actions run at natural speed. `--fast-agent` processes up to 32 ticks per
rendered frame for faster experiments, with the same final simulation state. The
batch runner enables it. Keyboard flight uses interpolation between fixed steps;
catch-up after a long stall is bounded.

An observation response resembles this illustrative example:

```json
{"version":2,"id":3,"scenario":"island-photo-v2","seed":42,"tick":30,
 "state_hash":"...","status":"ok","x":0,"y":20,"z":-2.5,
 "yaw":0,"pitch":-12,"remaining":3,
 "image":".snapbench/observations/session-episode-id.png",
 "sensor":{"width":1280,"height":720,"fov_y":60},"tick_rate":120}
```

Actual filenames have a process-session prefix, episode number, and request ID.
`observe` replies only after its PNG is complete. Pose, tick, and animation time
refer to that image. Simulation time stays paused during GPU readback, encoding,
and model inference. Consumers may remove completed PNGs after reading. The Rust
controller removes consumed images and records requests/responses under
`.snapbench/replays/`, without API keys or prompts.

Retry identical bytes with the same ID. The server caches the last 32 replies,
so duplicates do not repeat actions. Reusing an ID with different bytes returns
`id_conflict`; an evicted old ID returns `stale_id`. Unknown fields, oversized
packets, and invalid actions are rejected. In real-time mode, allow an action's
duration plus three seconds for a response. `no_subject` is a failed photograph,
not a transport failure.
Completed capture failures are cached too: retrying the same ID returns
`capture_failed`; use a new observation request to try another capture.

Plain text commands remain for diagnostics. Exact nearest-creature distance is
available only in the explicitly selected legacy scenario. Legacy mode uses the
old proximity rules; the updated VLM controller requires the island scenario.

## Verification

With a simulator running from the repository root:

```sh
make test
make check
make verify
make replay REPLAY=.snapbench/verification.jsonl
```

Verification resets seed 42, checks framing failure and duplicate protection,
flies to all three test-fixture habitats, photographs each animal, and validates
PNG sizes. Fixture coordinates never enter the VLM prompt. The resulting JSONL
record includes image hashes. Replay compares ticks, state hashes, outcomes,
remaining counts, and any recorded image hashes. VLM controller logs can also be
replayed; they contain state evidence without PNG hashes.

For a simulator launched from another working directory, pass
`--root /path/to/that/directory` to `uv run bench/sim_check.py`. Replay determinism
is verified on the same graphics stack. Cross-GPU pixels and cross-architecture
floating-point bit identity are not promised.

```sh
make profile SEED=42
zig build run -Doptimize=ReleaseFast -- 42 --profile 8400 --debug
# During the longer run, in another terminal:
make verify
```

Profiles discard 120 warmup frames, then report average FPS, frame percentiles,
maximum frame time, and frames exceeding 16.67 ms. `--tour` flies a continuous
survey. CPU work time excludes presentation and is not a GPU timer. Final timing
runs are separate from computer-use screenshots, which can disturb measurements.

## Rendering

Instances use 32 bytes for position, scale, yaw, tint, wind, and phase in persistent
GPU buffers, grouped into 64 visibility chunks. A 2048×2048 depth map provides
sunlight shadows with a 3×3 PCF filter. Shadows update at 30 Hz from simulation time
and refresh for observations. Hemisphere ambient light, restrained texture colors,
and world-space fog unify terrain, vegetation, and water. The window requests 4×
MSAA; observations use a fixed offscreen target.

Readback uses a persistent pixel buffer and nonblocking fence polling. After the
GPU signals completion, pixels are copied to an owned image and flipped/encoded
on a joined worker. Submission, copying, drivers, and scheduling can still cause
long frames. The code uses raylib's already loaded GLAD procedures: raylib 6's
generic procedure loader trips a function-pointer sanitizer trap in Zig
ReleaseSafe on the tested macOS platform.

References: [raylib shadow mapping](https://github.com/raysan5/raylib/blob/6.0/examples/shaders/shaders_shadowmap_rendering.c),
[fixed steps and interpolation](https://gafferongames.com/post/fix_your_timestep/).

## Measured verification — September 12, 2026

Apple M2, macOS, 1280×720. No paid model/API calls were made.

- A ReleaseSafe run covering 8,400 measured frames averaged **119.9 FPS** with
  default vsync. The flight executed 6,124 simulation ticks, photographed all three
  species, and saved five observations. Frame time: p95 **13.199 ms**, p99
  **13.621 ms**, maximum **16.762 ms**. Ten frames exceeded 16.67 ms. CPU work p95
  was **0.914 ms**. Log: `.snapbench/flight-profile.log`.
- The complete 47-request record replayed at **30 FPS and 144 FPS** with identical
  ticks, state hashes, outcomes, and all five PNG hashes. Replay also passed on
  the original display-paced run.
- Seven short ReleaseFast uncapped tour samples each covered 600 frames after
  warmup. All 4,200 frames stayed below 16.67 ms. These are throughput samples,
  not a claim that the physical display presents hundreds of frames per second.

| Seed | Uncapped FPS | p99 frame time | Maximum |
| --- | ---: | ---: | ---: |
| 7 | 801.0 | 4.194 ms | 5.143 ms |
| 23 | 817.4 | 4.314 ms | 5.583 ms |
| 24 | 813.8 | 5.043 ms | 5.919 ms |
| 29 | 810.5 | 4.273 ms | 5.165 ms |
| 61 | 827.8 | 4.393 ms | 5.339 ms |
| 42 | 810.6 | 4.053 ms | 5.393 ms |
| 72 | 824.0 | 4.273 ms | 5.957 ms |

The island has fewer instances than the historical full-square world, so these
numbers are not an isolated renderer speedup comparison. The longer, paced flight
is the primary smoothness check. Occasional scheduling spikes remain, and results
on other hardware require measurement.

After the [code-quality review](code-quality-review.md), `make test` passes
25 Zig tests, 8 Rust tests, and 7 Python tests. `make check`
passes Zig/Rust formatting, Clippy with warnings denied, Ruff, and strict mypy.
Native computer use verified the scene, completed three-species study, movement,
yaw, altitude, camera tilt, first-person/chase switching, photograph feedback,
reset, and the diagnostic overlay. Quick UI key taps are consumed from the event
queue so they register even when press and release arrive between frames. The
original seed-hash tests still cover all seven legacy benchmark seeds.
