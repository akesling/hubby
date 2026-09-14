#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
cargo run --locked -- verify examples/jarl/project.json --out target/jarl
cargo run --locked -- verify examples/assertions/project.json --out target/assertions
cargo test --locked --test lean -- --ignored
