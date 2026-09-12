# Code-quality review — September 12, 2026

Reviewed the working codebase directly, including the existing uncommitted
modernization changes, simulation, render/resource ownership, UDP protocols,
controller, and benchmark persistence. Existing work was preserved before edits.

### Findings

- **[P2, fixed] `src/simulation.zig:94` — Completion had two mutable owners.**
  `GameState.creatures_found` duplicated the world's live creature count. Both
  identification functions had to update those objects together, while the text
  protocol repeated scenario selection. Deleted the separate game-state counter
  and derived completion from the world. Both protocols now use
  `Simulation.identify`, keeping scenario rules in one place.

- **[P2, fixed] `src/agent_api.zig:25` — Pending work relied on unrelated flags.**
  An optional request, remaining ticks, a capture flag, reply length, and an
  API-wide accumulator implicitly described the lifecycle. Replaced those with
  explicit action, capture, and encoding states. Action timing belongs to the
  action; encoded replies carry their captured state. Capture failures now use
  the same delivery/cache path, so retries retain the original failure instead
  of unexpectedly turning into `stale_id`.

- **[P2, fixed] `llm_drone/src/protocol.rs:62` — Successful replies could invent state.**
  Serde defaults accepted incomplete success replies, including treating a
  missing remaining count as zero and reporting completion. Success decoding now
  requires all state fields and validates counts, finite poses, and supported
  scenarios. Rejections are decoded separately so their actual reason survives.
  Typed actions and request variants replace strings plus optional commands.
  Replay resets retain the actual scenario instead of always recording island.

- **[P2, fixed] `bench/results.py:85` — Persistence trusted unchecked data and
  exposed partial updates.** Controller JSON was cast to a partial dictionary;
  non-timeout failures discarded recoverable metrics. Forced reruns deleted old
  results before compilation, and checkpoints were overwritten in place. Added
  strict metrics decoding into a concrete dataclass, shared error/timeout
  recovery, atomic checkpoint publication, and atomic replacement of individual
  model/seed results. CSV ownership is now in the results module. Startup errors
  are returned as benchmark failures instead of escaping before cleanup.

### Open Questions

None blocking this review. Live paid-model behavior was not exercised; protocol,
accounting recovery, and local simulation behavior were tested without API calls.

### Approval Bar

**Approved after fixes.** The duplicate state and command dispatch are removed;
asynchronous state and external-data contracts are explicit; persistence has a
single owner and atomic publication. No implementation file approaches the
1,000-line threshold. Additional code primarily enforces the boundaries and
tests failure cases rather than introducing new operating modes.

Validation:

- `make test`: 25 Zig, 8 Rust, and 7 Python tests.
- `make check`: Zig/Rust formatting, Clippy with warnings denied, Ruff formatting
  and lints, and strict mypy.
- `git diff --check` and a ReleaseSafe simulation build.
- Before/after replay of a 47-request flight: identical ticks, state hashes,
  outcomes, remaining counts, and all five PNG hashes.
- The same record also passed with natural action timing at 30 render FPS,
  exercising the action accumulator independently of accelerated agent mode.
- Fresh live verification: all three photographs, duplicate/conflicting/stale
  IDs, completed observations, and PNG dimensions; 6,124 simulation ticks.
- New regressions cover capture failures before/after submission, captured-pose
  retention, ownership transfer, incomplete success replies, stale replies,
  actual replay scenarios, invalid metrics, interrupted writes, and recovery.

The before-edit snapshot and live records are in the local temporary directory
`/tmp/snapbench-review.vbeC2s/`; these are diagnostic artifacts, not benchmark data.
