#!/usr/bin/env bash
set -euo pipefail
export RUST_TEST_THREADS=1
cd "$(dirname "${BASH_SOURCE[0]}")/.."
cargo run --locked -- verify examples/assertions/project.json --out artifacts/assertions
cargo test --locked --test lean -- --ignored
cargo test --locked --test methods -- --ignored
cargo test --locked --test loans -- --ignored
cargo test --locked --test array_moves -- --ignored
cargo test --locked --test getters -- --ignored
cargo test --locked --lib methods::getters::tests -- --ignored
cargo test --locked --lib methods::source::tests -- --ignored
cargo test --locked --lib methods::constructor_source::tests -- --ignored
cargo test --locked --test cargo_capture -- --ignored
cargo test --locked --test queries -- --ignored
cargo test --locked --test constructors -- --ignored
cargo test --locked --test buffers -- --ignored
cargo test --locked --test relocations -- --ignored
cargo test --locked --test selectors -- --ignored
cargo test --locked --test lookups -- --ignored
cargo test --locked --test records -- --ignored
cargo test --locked --test iterations -- --ignored
cargo test --locked --test projections -- --ignored
cargo test --locked --test rebuilds -- --ignored
cargo test --locked --test merges -- --ignored
cargo test --locked --test predicate_runs -- --ignored
cargo test --locked --test order_statistics -- --ignored
cargo test --locked --test predicate_folds -- --ignored
cargo test --locked --test numeric_folds -- --ignored
cargo test --locked --test numeric_buffers -- --ignored
cargo test --locked --test upserts -- --ignored
cargo test --locked --test slot_batches -- --ignored
cargo test --locked --test truncations -- --ignored
cargo test --locked --test installations -- --ignored
cargo test --locked --test restorations -- --ignored
cargo test --locked --test suite -- --ignored

cargo test --locked --test enum_projections -- --ignored
cargo test --locked --test validators -- --ignored

cargo test --locked --test views -- --ignored
