.PHONY: test test-rust test-lua build

build:
	cargo build --release

# Rust unit + CLI integration tests
test-rust:
	cargo test

# Neovim plugin tests (headless, no plugin dependencies)
test-lua:
	nvim --headless -u NONE -l tests/lua/runner.lua

test: test-rust test-lua
