#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
cargo clippy --manifest-path Cargo.toml --locked --all-targets -- -D warnings
RUSTDOCFLAGS="${RUSTDOCFLAGS:-} -D warnings" cargo doc --manifest-path Cargo.toml --locked --no-deps
