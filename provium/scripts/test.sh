#!/usr/bin/env bash
set -euo pipefail
export RUST_TEST_THREADS=1
cd "$(dirname "${BASH_SOURCE[0]}")/.."
cargo test --manifest-path Cargo.toml --locked "$@"
