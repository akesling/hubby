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

Shared receiver-only methods returning builtin scalars can also use
`scalar_method`. Their full bodies are translated with typed field inputs and
explicit original impl const parameters; local computation and failure paths are
retained. This supports const-generic capacity queries without rewriting the
consumer's Rust. It does not prove callers' representation invariants.

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
payloads. Shared queries returning `Result<(), Enum>` support complete conditional
returns and receiver-local shared helper calls. Query conditions read builtin
bool and Option fields or `array.iter().any(Option::is_some)`; error variants are
resolved from original enum declarations. Query stores model optional values and
optional-array contents explicitly and quantify over arbitrary lengths. The
frontend rejects omitted statements, unresolved calls and unsupported effects.
These query contracts retain the same trusted source/layout boundary.
Method projects accept an optional `rust_target` for an already-installed target;
their manifests record verbose rustc identity, target cfg and the actual
type-check arguments. This describes the direct rustc check, not a Cargo build
closure. Component certificates use `whole_program_proved: false`.

Argument-free `Self` constructors support explicit named-field initialization
from builtin literals, `None`, scalar/Option fields of builtin-derived Default
records, and `core::array::from_fn(|_| None)`. Original const arguments are
substituted into array capacities. Constructors reject hidden initializer effects,
custom/inherent defaults, shadowed standard namespaces and omitted fields. Their
logical initialization stores do not establish Rust memory/layout refinement or
physical resource availability; standard-operation semantics remain trusted.

Assignment stores model nonoverlapping leaf locations with opaque values for untouched
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

`inventory <crate-directory> --out <directory>` records a conservative syntax
inventory of `src/lib.rs` and its modules. `audit-coverage <crate-directory>`
checks a consumer-owned `proofs/coverage.json` against current source.
The library API accepts other source roots. This pass does not resolve calls,
traits, derives, macros or Cargo build configurations; its report explicitly
retains those limitations. A successful accounting check is not a proof.
`verify-complete <crate-directory>` currently rejects all full-proof claims;
editing ledger labels cannot bypass missing semantic preservation/root proofs.

`inspect-cargo <build.json> --out <directory>` records an offline, locked Cargo
normal/build dependency graph, manifests, workspace/lock hashes, features, target
declarations, rustc identity and target cfg. Its input has `manifest` (relative
to that JSON file), `target` (a triple or `host`), `features` and
`no_default_features`. Dev-only edges are excluded. Git/alternate-registry
dependencies are rejected; build scripts and proc macros remain explicitly
unverified. This accounting does not establish compiler invocations, expanded
source, semantic call closure or complete Cargo environment provenance.

```sh
cargo run --locked -- compile examples/assertions/project.json --out artifacts/assertions
cargo run --locked -- verify examples/assertions/project.json --out artifacts/assertions
```

`compile` generates evidence without asserting a proved obligation.

The whole-method backend also accepts a closed bounded-buffer append idiom:
source-resolved capacity guard, indexed `Some(input)` assignment, usize length
increment, and Result return. Its manifest records the entire method and guard.
Unsupported syntax is rejected; no Jarl method names are built into the compiler.
The buffer IR exposes drop suspensions and retains bounds/overflow failure stores.
A drop continuation only applies after normal destructor return; it does not
model destructor unwinding or prove Rust memory/layout correspondence. Consumers
can prove no-drop success by establishing an empty destination slot. Independent
native tests include destructor traces and partially changed state after panic.

Consuming record growth is supported through its full const assertion and
indexed `Option::take` callback. Every metadata field must be transferred once
or taken from an Option, and custom receiver Drop is rejected. The generated
slot-move semantics expose residual payload disposal and preserve metadata as an
opaque value. They do not model metadata ownership during failed construction,
panic hooks or unwinding; source/layout/ownership refinement remains open.

Shared optional-record selectors retain their receiver and payload field paths
in Lean and check eager default computation. Storage IR also records source
array/length paths and capacity names so consumer obligations can bind projected
stores to specific source places. These source-place checks are complementary to,
and do not replace, the still-open Rust layout and borrow refinement proof.

The checked lookup backend retains a shared record-base helper, two checked
subtractions, target usize conversion, optional-array bounds access and the
returned borrowed place. It rejects source traits that could override the
accepted standard operations. Native tests compare reference locations; the
current place model does not prove Rust lifetimes or physical layout.

Optional record lookup can compose a copied boundary record with the complete
checked borrowed lookup and an entry-record projection. Source comparison and
projection fields remain explicit, and both helpers are translated in full.
This supports proofs of whole returned records without assuming their content
already satisfies a protocol's log invariants.

Builtin borrowed double-ended iteration is represented by its ordered location
sequence, retaining prefix bounds checks without attributing eager allocation to
Rust. Final-record selection composes the complete iterator and base helpers.
Native checks mix both iterator ends and track payload Drop; panic hooks and
physical iterator/lifetime refinement remain outside the model.

Complete suffix-removal loops can compose the borrowed iterator and last-record
backends. Their denotation retains condition order, partial length updates and
explicit destructor suspensions with normally returning continuations. Opaque
payloads are separate from immutable record views; no payload Clone is imposed on
the subject. Native tests compare boundaries, sparse storage and drop order.
Physical record-view refinement and destructor panic/unwinding are still open.

Snapshot replacement additionally composes complete optional-record lookup,
derived equality over all scalar record fields, target-word casts and prefix
rotation. Source-ordered clearing and replacement expose both entry and snapshot
destructor boundaries. Fault outcomes retain the incoming owned snapshot before
unwinding. Native comparisons include malformed buffers, term mismatches and
commit extrema; this backend does not establish protocol caller invariants.

Recovery from consumer-owned iterators uses an interaction tree: IntoIterator,
next, and source/iterator/payload destruction are explicit boundaries. Complete
source guards retain short-circuit evaluation and checked addition. Successful
outcome relations require normal callback return; a separate property checks
internal interpreter-fuel sufficiency for every callback response. Independent
native result and cleanup traces are reproduced by kernel computation. This does
not equate an arbitrary iterator with an infallible list or prove unwinding.

Complete borrowed enum matches can project builtin u64 fields. Every source
variant must be explicit, and the compiler retains each selected variant/field
pair. Unknown view tags and malformed primitive fields have no value. This
backend does not assume a Rust enum memory layout or accept opaque arm effects.

Enum projection certificates retain the source arm grouping separately from the
flattened dispatch table. A Lean theorem proves that flattening preserves ordered
selection, including malformed field views. Generated correspondence uses that
theorem, and tests reject a corrupted compiled table. Parsing, binding resolution
and the connection from Rust memory to this source representation remain trusted.

Pure borrowed validators support complete boolean bodies with typed locals,
short-circuit operators, early returns, nested enum/Option patterns, borrowed
array loops, immutable captured closures, derived primitive-record defaults and
equality, and checked integer addition. Enum field helpers are translated from
their complete source bodies. The compiler resolves each accessed declaration,
rejects opaque calls and overloaded operations, and keeps inferred `i32` counters
separate from `u64` protocol fields. Record equality evaluates each operand once
in source order. No consumer-specific protocol names occur in this backend.

The generated function takes explicit fuel and a structural `PureValue` input.
Its correspondence theorem currently identifies the generated interpreter call;
it is **not** a source-to-IR preservation proof. Input memory representation,
well-formed views (including array lengths), compiler preservation and sufficient
fuel need separate contracts. Detected representation faults and exhaustion are
explicit outcomes; this is not a general input-view well-formedness checker. The independent
fixture checks 42 native executions by kernel reduction and requires a removed
batch-hole guard to fail verification. Finite comparisons do not replace
universal correctness theorems.

The pure machine supplies kernel-proved error-propagation and array-loop rules.
`pure_fold_history` lets a consumer track the entire scanned prefix, for any
array length, provided it proves preservation for the actual generated body.
All five rules are audited for transitive axioms. A separate universal check
ensures derived record equality evaluates effectful operands exactly once.
