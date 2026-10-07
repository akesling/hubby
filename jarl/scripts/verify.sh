#!/usr/bin/env bash
set -euo pipefail
export RUST_TEST_THREADS=1
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
cargo test -p jarl --locked --offline --test proofs -- --include-ignored
cargo test -p jarl --locked --offline --lib node::machine -- --include-ignored
