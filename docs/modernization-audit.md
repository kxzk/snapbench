# Modernization audit

Verified on September 11, 2026, on an Apple M2, macOS, at 1280×720.

## Toolchain and build

- Migrated from Zig 0.15.2 APIs to **Zig 0.16.0**, the current stable release.
- Pinned **raylib 6.0** by archive URL and Zig package hash.
- Updated module linking, process initialization, arguments, random seed generation,
  formatting, and UDP to `std.Io.net`.
- Removed the empty library module/test target, macOS-only OpenGL header, generated
  manifest commentary, unnecessary raylib aliases, and unused audio dependency.
- Included runtime assets in the Zig package and set the build runner's working directory.

Upstream references: [Zig downloads](https://ziglang.org/download/),
[Zig 0.16 release notes](https://ziglang.org/download/0.16.0/release-notes.html),
[raylib 6.0](https://github.com/raysan5/raylib/releases/tag/6.0).

## Performance measurements

These are local wall-clock frame measurements, including presentation. They are
not isolated GPU timings or a guarantee for other machines. Each profile discards
120 warmup frames. No screenshot/computer-use capture was taken during the final
seven stationary, uncapped profiles.

| Seed 42, uncapped | Baseline renderer | Final renderer |
| --- | ---: | ---: |
| Sampled frames | 600 | 600 |
| Average FPS | 81.7 | 286.2 |
| Frame time p50 | 11.366 ms | 2.959 ms |
| Frame time p95 | 17.062 ms | 6.634 ms |
| Frame time p99 | 17.904 ms | 8.340 ms |
| Maximum frame time | 18.768 ms | 12.256 ms |
| CPU work p95, excluding presentation | 10.965 ms | 0.184 ms |
| Frames exceeding 16.67 ms | 50 | 0 |

The baseline already had the minimal Zig/raylib migration and profiling
instrumentation, but retained the original renderer and movement implementation.
The final renderer averaged **274.7–322.9 FPS** across seeds 7, 23, 24, 29, 61, 42,
and 72 (600 measured frames each). All 4,200 frames stayed below 16.67 ms.

A separate **ReleaseSafe** run used default vsync while flying, rotating,
identifying all three creatures, and requesting screenshots. Over 3,600 frames it
averaged **118.8 FPS**: p95 **10.847 ms**, p99 **12.028 ms**, maximum **24.071 ms**.
Eleven frames exceeded 16.67 ms. PNG acknowledgements took approximately
215–233 ms while rendering continued. GPU readback and system scheduling can
still produce occasional long frames; PNG encoding is asynchronous.

Changes responsible for the improvement:

- Persistent GPU instance buffers replace allocation, matrix conversion, upload,
  and deletion on every draw.
- Instance data stores position and uniform scale in 16 bytes instead of a 64-byte
  matrix. Seed 42 uses **81,728 bytes** of GPU instance data.
- The old fixed CPU transform arrays reserved **13 MiB**. Temporary instance lists
  now exist only during startup and are then freed.
- Enclosed blocks are omitted; models load only when used by the generated world.
- Discovery updates only the affected creature buffers and releases unused models.
- Shader normals no longer require a matrix inverse per vertex. The constant glow
  replaces the previous time uniform.
- Default pacing uses vsync alone. Combining vsync with the old sleep-based cap
  measured approximately 58 FPS; vsync alone follows this display near 120 FPS.

Reproduce a stationary profile with `make profile SEED=42`. For display-paced
measurements, use `zig build run -Doptimize=ReleaseFast -- 42 --profile 1200`.

## Correctness and code cleanup

- Position smoothing is exponential and cannot overshoot after a slow frame.
  Yaw takes the shortest path across the 0°/360° boundary.
- Forward and strafe axes are perpendicular at every heading; diagonal keyboard
  movement is normalized. Short key taps are preserved between frames.
- Swept collision prevents tunneling, allows wall sliding, considers the drone's
  footprint, and respects decoration height during descent.
- Creature identification uses the existing compact creature index and preserves
  the original grid-order tie break. Distance queries perform one square root.
- Game-over status is derived from the remaining count. Creature removal is
  idempotent. Generation has a deterministic fallback if spawn attempts run out.
- Seed compatibility is checked against original cell/creature hashes for all
  seven measured seeds. Catalog enum IDs and source assets are retained.
- UDP processing is bounded per frame, truncated datagrams are rejected, and
  receive failures are surfaced. The socket binds to loopback before window startup.
- Replies describe the actual pose and its corresponding distance. `state` and
  screenshot requests continue to work after game over.
- Screenshot capture happens after drawing; PNG encoding uses a joined worker
  with explicit ownership. Acknowledgements wait for the file to be ready.
- Model textures are released once even when shared by several materials; raylib's
  `UnloadModel` does not free them. Shaders no longer live in mutable globals.
- Main-loop responsibilities are separated into motion, protocol, HUD, renderer,
  screenshot, and profiling modules. Dead terrain helpers, duplicate response
  formatting, unused seed storage, and obsolete transform helpers were removed.

The Rust controller now separates API calls, state, metrics, and prompt text.
It detects completion on the final identification response, validates command
arrays without fallback movement or malformed-slice panics, preserves token usage
for invalid command output, includes response-body latency, and uses asynchronous
UDP with timeouts. Its runtime enables only the Tokio features it uses. Navigation
coordinates now match the simulation, and iteration limits no longer overcount.

The Python runner builds once, probes actual readiness, rejects an occupied
simulation port, scopes process cleanup, and clears stale checkpoints. Result and
CSV structures are typed, price data is cached, and the results path is documented
correctly. Existing benchmark CSV data and historical result images were preserved.

## Validation

- `make test`: 16 Zig tests, 4 Rust tests, and 2 Python tests passed.
- Zig tests also passed in ReleaseSafe. Debug, ReleaseSafe, and ReleaseFast builds passed.
- `make check`: Zig/Rust formatting, Clippy with warnings denied, Ruff, and strict
  mypy checks passed.
- Native computer use verified rendering and keyboard movement, yaw, and altitude,
  with the HUD around 118 FPS.
- A local UDP flight completed all three seed-42 identifications, rejected invalid
  and oversized commands, validated all three 1280×720 PNG files, and queried the
  completed game. The final screenshot shows `ALL CREATURES FOUND` and `3/3`.
- All seven benchmark seeds launched and completed their profiles successfully.

Paid VLM/API benchmarks were not run. Historical scores should not be directly
compared with new runs: world placement is preserved, but controls, collision,
state reporting, command validation, metrics, and navigation coordinates changed.
Only macOS on Apple Silicon was tested at runtime.
