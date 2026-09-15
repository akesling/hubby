#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
cargo run --locked -- verify examples/assertions/project.json --out artifacts/assertions
cargo test --locked --test lean -- --ignored
cargo test --locked --test methods -- --ignored
cargo test --locked --test queries -- --ignored
cargo test --locked --test constructors -- --ignored
cargo test --locked --test buffers -- --ignored
cargo test --locked --test relocations -- --ignored
cargo test --locked --test suite -- --ignored
