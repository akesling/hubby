#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
cargo run --locked -- verify examples/jarl/project.json --out artifacts/jarl
cargo run --locked -- verify examples/assertions/project.json --out artifacts/assertions
cargo test --locked --test lean -- --ignored
cargo run --locked -- verify-methods examples/jarl-methods/project.json --out artifacts/jarl-methods
cargo test --locked --test methods -- --ignored
cargo run --locked -- verify examples/jarl-election/project.json --out artifacts/jarl-election
cargo test --locked --test scalar_methods -- --ignored
cargo run --locked -- verify-methods examples/jarl-membership/project.json --out artifacts/jarl-membership
cargo test --locked --test arrays -- --ignored
