.PHONY: build-sim clean build-drone help

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

build-sim: ## build the simulation
	zig build

clean: ## remove build artifacts
	rm -rf zig-out .zig-cache drone_control

build-drone: ## build rust drone controller
	rustc -O drone_control.rs -o drone_control
