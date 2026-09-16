#!/usr/bin/env bash
set -euo pipefail
export RUST_TEST_THREADS=1
export PROVIUM_LEAN_MEMORY_MB="${PROVIUM_LEAN_MEMORY_MB:-16384}"
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
cargo test -p jarl --locked --offline --test proofs source_coverage_review_is_current
cargo test -p jarl --locked --offline --test proofs m0_
cargo test -p jarl --locked --offline --test proofs specification_witnesses_are_kernel_checked
cargo test -p jarl --locked --offline --test host --test dynamic_host --test async_host
