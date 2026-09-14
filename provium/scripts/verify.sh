#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
cargo run --locked -- verify examples/jarl/project.json --out artifacts/jarl
cargo run --locked -- verify examples/assertions/project.json --out artifacts/assertions
cargo test --locked --test lean -- --ignored
