#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
cargo run --manifest-path provium/Cargo.toml --locked --offline -- verify-complete jarl
