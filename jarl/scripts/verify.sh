#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
cargo test -p jarl --locked --offline --test proofs -- --include-ignored
