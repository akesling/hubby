#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
cargo fmt --manifest-path Cargo.toml -- "$@"
rustfmt --edition 2021 tests/fixtures/*.rs examples/assertions/source.rs "$@"
