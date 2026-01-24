.PHONY: sim drone bench clean help

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
	zig build run -Doptimize=ReleaseFast -- 24

drone: ## build and run the LLM-driven drone controller
	cargo run --release --manifest-path llm_drone/Cargo.toml

bench: ## run LLM benchmark across all configured models
	uv run bench/bench_runner.py

clean: ## remove build artifacts
	rm -rf zig-out .zig-cache drone_control llm_drone/target
