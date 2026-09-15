# Provium

Provium is a development dependency for crates that own their Rust-to-Lean
proof contracts. It translates a restricted Rust language into executable Lean
and checks obligations over the generated definitions. It is **not a verified
Rust compiler or a proof of whole-program correctness**.

## Use from your crate

Once published, add Provium as a dev-dependency:

```toml
[dev-dependencies]
provium = "0.1"
```

During development in this repository, use the same version with a local path.
Provium uses `std` for verification and does not enter the consumer's runtime
dependency graph. A consumer can remain `no_std` and sans-I/O.

Own the proof projects alongside your Rust:

```text
my-crate/
  src/
  tests/proofs.rs
  proofs/
    counter/project.json
    counter/Proofs.lean
```

In `tests/proofs.rs`:

```rust
#[test]
fn invariants() {
    provium::assert_proofs!("proofs");
}
```

Run `cargo test --test proofs`. This is a real assertion: missing Lean, empty
suites, unsupported Rust, failed obligations, and forbidden axioms fail the test.
It does not silently skip proofs or install toolchains. Install elan and the
supported Lean toolchain first; failure messages provide the exact command.
The current pin is in [lean-toolchain](lean-toolchain).

The macro resolves paths from the **calling crate**, independent of the working
directory. It discovers `project.json` files beneath the selected directory,
selects their verification backend, and writes each project's generated Lean,
source snapshots, manifests, and certificates beneath the consumer's
`artifacts/provium/<crate-relative project directory>/`. Ignore that directory in version control. Cargo exclusively
owns `target/`; Provium refuses proof-output paths beneath it.

For custom runners, `verify_suite(crate_root, proof_directory)` and
`verify_project(project_json, output_directory)` return reports or contextual
errors. A suite invalidates all selected previous certificates before it starts.
Keep suites and output directories separate; do not run concurrent verification
against the same output directory. Symlink traversal and empty suites are rejected.

[Jarl](../jarl/proofs/README.md) is a consumer of this API. Its contracts and
protocol-specific regression tests belong to Jarl, not this crate's examples.

## Describe a proof project

A scalar project selects exactly one of `source`, `slices`, or `scalar_method`:

```json
{
  "source": "../../src/counter.rs",
  "namespace": "Counter",
  "usize_bits": 64,
  "proofs": "Proofs.lean",
  "obligations": [
    { "theorem": "Contracts.increment_safe", "function": "increment" }
  ]
}
```

Paths are relative to that project file. See the independent
[assertion example](examples/assertions) for runnable Rust and Lean contracts.
`source` must contain closed scalar functions; it is type-checked in a `no_std`
wrapper. `usize_bits` must match rustc's target; `rust_target` can select an
already-installed target. No Rust toolchains are installed by Provium.

`scalar_method` instead names an original `crate_root` and a qualified `method`.
It type-checks that production crate and infers accessed field types. Every
written field receives a successful-state projection that executes **all** body
statements before returning the field, including statements after its assignment.
It currently supports `&mut self`, no ordinary arguments, unit returns, builtin
`u64` fields, and bodies accepted by the scalar frontend after field resolution.
A fault does not describe the partially mutated Rust store.

A state-method project uses `crate_root`, `namespace`, `methods`, `proofs`, and
`obligations`. It resolves original field declarations and translates complete
supported method bodies. Consumers use the same assertion API for either schema.
It currently requires a Rust 2021 crate buildable without external dependencies
by its rustc invocation. This restriction applies to the *subject translation*,
not to whether a consumer can depend on Provium through Cargo.

For expression slices, `slices` explicitly records the source method, structural
selectors, free-location bindings and types, and result type. Selectors include
`tail`, `let:names`, `stmt:index`, `closure`, `condition`, `right`, `arg:index`,
`index`, and `calls:method:arg:count`. All expected repeated occurrences must
match. `guarded_assignment_prefix` covers only a guard and its first assignment;
later statements and calls are outside that slice's proof. Bindings are explicit
abstraction assumptions, not inferred whole-program types.

## Supported semantics and limits

The scalar backend supports unsigned `u8/u16/u32/u64/usize`, `bool`, local
bindings/shadowing and outer-block assignments, expression-valued conditionals,
lazy boolean operators, comparisons, arithmetic, unsigned min/max,
saturating add/sub, wrapping add/sub/mul, bitwise operations, same-type shifts,
local `^=`, builtin `assert!` without formatting, and acyclic source-local calls.
Unsupported syntax fails closed, including signed/floating types, arbitrary
macros, casts, references, aggregates, loops, early returns, and nested-block
mutations. Inference is deliberately limited; some code needs annotations.

Ordinary arithmetic has checked-overflow semantics even if a consumer's release
build wraps. A successful contract must rule out overflow to apply to both builds.
Explicit wrapping/saturating operations retain their own semantics. Out-of-range
shift counts fault; valid left shifts discard high bits, as in checked Rust.

State methods support typed literal writes to `bool` and `Option<u64>` fields,
boolean conditions, ordered branches, and source-resolved receiver-local helper
calls without arguments. Recursion and expansion beyond the limits fail closed.
Consumed wrappers must consist entirely of mutable references; custom receiver
destructors are rejected. Generic field traversal, import aliases, item macros,
conditional production definitions, and unsupported attributes are rejected.

Optional-record array methods support a complete exclusive traversal with a
`Some` binding, boolean field updates/branches, and slot deletion. Consumed
receivers and records must derive builtin `Copy`; rustc checks that deletion
cannot hide destructors. Shared array queries support pure boolean
`iter().flatten().any(...)` predicates. Custom traits that could shadow these
operations are rejected. Arrays are modeled as lists preserving empty slots and
length. A reserved `$present` cell records deletion and cannot name a Rust field.
It is excluded from record-field frame claims.

Stores model nonoverlapping leaf locations with opaque values for untouched
payloads. Boolean reads have a total extension on malformed stores; Rust
refinement requires the corresponding leaves to contain booleans. Frame theorems
do not say an enclosing aggregate is unchanged when one of its fields changes.
Borrow/layout refinement and frontend translation remain trusted.

## What verification establishes

The manifest records source/config/compiler hashes, original source snapshots,
translation evidence, typed IR, generated Lean, semantics, proof hashes, target
configuration, and checked obligations. Verification rechecks inputs/artifacts
before writing `verified.json`; failed recompilation invalidates prior success.
A generated correspondence theorem proves backend agreement with the IR.
It does **not** prove the frontend's Rust-to-IR translation correct.

Pinned Lean runs with `--trust=0` and warnings as errors. Audited theorems may use
only `propext`, `Quot.sound`, and `Classical.choice`; sorry, custom axioms, and
native-evaluation trust axioms are rejected. Each obligation must mention its
selected generated function. That check cannot judge specification adequacy:
tautologies and impossible preconditions still need human review. Lean proof
files contain executable metaprograms; this verifier is not a sandbox for hostile
proof code. Allocation, I/O, crash durability, concurrency, and liveness require
additional semantics/contracts. Certificates do not assert whole-program proof.

## Develop Provium

All third-party Rust dependencies must build directly from crates.io. No Git-only
backends, vendored third-party checkouts, or automatic Rust toolchain installation.

| Script | Purpose |
| --- | --- |
| `scripts/format.sh [--check]` | Format/check Rust and standalone fixtures |
| `scripts/lint.sh` | Clippy and rustdoc with warnings as errors |
| `scripts/test.sh [--release]` | Compiler/API regression tests |
| `scripts/verify.sh` | Generic Lean examples, API checks, and negative controls |
| `scripts/check.sh` | All provider quality gates |

Slow compiler tests are ignored by ordinary `cargo test`; `verify.sh` explicitly
runs them and requires Lean. Consumer tests control their own verification policy;
the `assert_proofs!` macro never skips verification. Jarl's CI owns Jarl's proof
assertions and mutation checks.

The low-level CLI remains available:

```sh
cargo run --locked -- compile examples/assertions/project.json --out artifacts/assertions
cargo run --locked -- verify examples/assertions/project.json --out artifacts/assertions
```

`compile` generates evidence without asserting a proved obligation.
