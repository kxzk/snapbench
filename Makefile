.PHONY: sim drone bench test check profile verify replay clean help

.DEFAULT_GOAL := help

help:
	@echo ""
	@echo "  \033[1;34mSnapBench\033[0m"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "    \033[1;37m%-19s\033[0m \033[90m░ %s\033[0m\n", $$1, $$2}'
	@echo ""
	@echo "  \033[90musage: \033[1;34mmake \033[1;37m<command>\033[0m"
	@echo ""

sim: ## build and run the simulation
	zig build run -Doptimize=ReleaseFast -- $(SEED)

profile: ## profile 1200 uncapped flight frames after warmup (SEED=42 by default)
	zig build run -Doptimize=ReleaseFast -- $(or $(SEED),42) --fps 0 --profile 1200 --tour

verify: ## verify a running simulation with a full photography flight; no API calls
	uv run bench/sim_check.py

replay: ## replay a recorded flight against the running simulation (REPLAY=path)
	uv run bench/sim_check.py --replay $(or $(REPLAY),.snapbench/verification.jsonl) --record .snapbench/replayed.jsonl

test: ## run simulation, controller, and benchmark regression tests
	zig build test
	cargo test --manifest-path llm_drone/Cargo.toml
	uv run --python 3.13 --with rich python -m unittest discover -s bench -p 'test_*.py'

check: ## check formatting, lints, and Python types
	zig fmt --check build.zig build.zig.zon src
	cargo fmt --manifest-path llm_drone/Cargo.toml --check
	cargo clippy --manifest-path llm_drone/Cargo.toml --all-targets -- -D warnings
	uvx ruff check bench
	uvx ruff format --check bench
	uv run --python 3.13 --with rich --with mypy python -m mypy --strict bench

drone: ## build and run the LLM-driven drone controller
	cargo run --release --manifest-path llm_drone/Cargo.toml -- --model google/gemini-3-flash-preview

bench: ## run LLM benchmark across all configured models
	uv run bench/bench_runner.py

clean: ## remove build artifacts
	rm -rf zig-out .zig-cache drone_control llm_drone/target
