# Provium

Provium translates a restricted Rust language into executable Lean 4 definitions,
then checks invariants over those generated definitions. It is an initial
source-linked verification tool, **not a verified Rust compiler or a proof of
whole-Jarl correctness**.

Jarl stays unchanged: no proof helper functions, annotations, dependencies, or
runtime hooks. Its `no_std`, sans-I/O, sync/async host boundary is unaffected.
Provium runs separately as a development tool and uses `std`.

Rust dependencies must be published on crates.io and build with the existing
Rust toolchain. Git-only backends, vendored third-party checkouts, and automatic
Rust toolchain installation are outside this project's dependency policy.
Lean remains the explicitly required external proof checker, invoked through elan.
Cargo exclusively owns `target/`; Provium writes proof output and test workspaces
to the ignored `artifacts/` directory.

## Run it

From the repository root, with Rust, rustfmt, Clippy, and elan installed:

```sh
elan toolchain install leanprover/lean4:v4.33.1
rustup target add wasm32-unknown-unknown
provium/scripts/check.sh
```

The scripts work from any current directory:

| Script | Purpose |
| --- | --- |
| `scripts/format.sh` | Format Rust, including example/fixture sources |
| `scripts/format.sh --check` | Check formatting without edits |
| `scripts/lint.sh` | Clippy on all targets and rustdoc; warnings are errors |
| `scripts/test.sh` | Fast Rust differential, extraction, and rejection tests |
| `scripts/test.sh --release` | Run those tests with optimized checked arithmetic |
| `scripts/verify.sh` | Check the examples, 32-bit Jarl proofs, and negative controls in Lean |
| `scripts/check.sh` | Run all the above gates, excluding the optional release test |

Lean tests are explicitly ignored by ordinary `cargo test`; `verify.sh` runs them
and fails if Lean or the required Rust target is unavailable. Cargo dependencies
are locked in this standalone workspace's `Cargo.lock`. After fetching them,
`CARGO_NET_OFFLINE=true provium/scripts/check.sh` works offline.

Generate or verify one project directly:

```sh
cargo run --manifest-path provium/Cargo.toml --locked -- \
  compile provium/examples/jarl/project.json --out provium/artifacts/jarl
cargo run --manifest-path provium/Cargo.toml --locked -- \
  verify provium/examples/jarl/project.json --out provium/artifacts/jarl
```

`compile` makes no proof-success claim. `verify` regenerates everything, invokes
pinned Lean with `--trust=0 -DwarningAsError=true`, audits theorem dependencies, and
writes `verified.json` only after success. A failed recompile invalidates the old
success marker. Use a dedicated output directory outside the inputs and give it
exclusive ownership during a run. Proof files are executable Lean metaprograms;
verification is not a sandbox for hostile code.

## What is connected to what?

```text
Rust source bytes + project configuration
  → syn AST
  → optional structural extraction and explicit scalar abstraction
  → typed scalar IR
  → Lean IR term + executable Lean function
  → kernel-checked backend correspondence + user invariants
```

For every translated function, Lean checks a theorem of this form for **all**
environments, including invalid inputs:

```lean
theorem f_correspondence (env : Provium.Env) :
    Provium.run parameterTypes f_ir env = f env := by rfl
```

The invariant statements reference `f`, which is generated from Rust on each run.
There is no separately maintained Lean implementation of the Jarl rules. Changes
to their Rust expressions change the generated definitions, or make extraction
fail if the structural selection no longer applies.

This certificate establishes **backend agreement with the IR**. It does not prove
that `syn`, name/type handling, extraction, or AST-to-IR lowering correctly models
Rust. Those components, the scalar operational semantics, Rust/Lean toolchains,
and any declared slice bindings remain trusted. Native Rust differential tests
and negative controls exercise that boundary; tests and hashes are not a proof of
frontend correctness.

`manifest.json` records original file paths and SHA-256 hashes, complete source
snapshots, extraction selectors, original method/selection line locations,
selected Rust tokens, binding assumptions, translated Rust, typed IR, compiler
executable hash, rustc version/target configuration, and hashes of generated Lean,
semantics, audit code, proof file, and project configuration. `verified.json`
identifies the manifest and reports checked declarations and transitive axioms.
For slices, the top-level `source_sha256` hashes generated `Source.rs`; the
`sources` and `extraction` entries identify the **original** Rust files.

Only `propext`, `Quot.sound`, and `Classical.choice` are allowed in audited theorem
dependencies. `sorryAx`, user axioms, and native-evaluation trust axioms are
rejected. An obligation must name a theorem whose statement mentions the selected
generated function. This avoids accidentally checking an unrelated `True`, but
cannot judge specification quality: a tautology or an impossible precondition can
still be a valid, useless theorem. Review the statements and assumptions.

## Translate closed functions

A scalar project chooses exactly one input: `source`, `slices`, or `scalar_method`:

```json
{
  "source": "source.rs",
  "namespace": "Assertions",
  "usize_bits": 64,
  "proofs": "Proofs.lean",
  "obligations": [
    {"theorem": "Contracts.increment_safe", "function": "increment"}
  ]
}
```

Paths resolve relative to the project file. Omit `proofs` and `obligations` for
translation and backend certificates only. `usize_bits` must match rustc's target;
set `"rust_target": "wasm32-unknown-unknown"` for a 32-bit target. The source snapshot
is type-checked by rustc in a `#![no_std]` wrapper with checked overflow. The input
must be a closed file of functions; compiling its containing Cargo crate is not
part of this mode.

Supported today:

- `bool`, `u8`, `u16`, `u32`, `u64`, and explicitly sized `usize`.
- Scalar parameters and returns, literals, local bindings, shadowing, and local
  assignments at the outer function block.
- Tail expressions, expression-valued `if/else`, lazy `&&`/`||`, boolean `!`,
  comparisons, `+`, `-`, `*`, `/`, and `%`.
- Unsigned `min`, `max`, `saturating_add/sub`, and `wrapping_add/sub/mul`.
- Unsigned bitwise `&`, `|`, `^`, same-type `<<`/`>>`, and local `^=`.
  Shift counts outside the operand width fault; valid left shifts discard high
  bits, matching Rust even when checked arithmetic is enabled.
- `assert!(condition)` without formatting arguments.
- Direct, acyclic calls within the same file, with eager left-to-right arguments.

Everything else fails closed: imports, modules, aggregates, references, traits,
generics, signed/floating types, casts, loops, recursion, explicit `return`,
closures in translated bodies, external calls, arbitrary macros, non-doc
attributes, and nested-block assignments. Some valid Rust requires explicit type
annotations because this frontend deliberately implements limited inference.

Lean values carry a word width and bounded natural payload. Arithmetic returns
explicit overflow/division-by-zero faults; assertions return an assertion fault.
The semantics models termination with a value or fault, not unwinding details,
allocation, I/O, timing, or concurrency. Ordinary arithmetic uses **checked**
overflow even if a consumer's release build wraps. A proved successful contract
must rule out those overflow cases; otherwise do not transfer that claim to a
wrapping build. Explicit wrapping/saturating methods retain their own semantics.

## State constraints and invariants

See [the assertions example](examples/assertions/Proofs.lean). It proves that
`increment` returns `x + 1` without assertion/overflow failure under `x < 255`,
that `x = 255` fails the Rust assertion, and that guarded division short-circuits
on a zero divisor. `Provium.Ensures` provides the reusable contract shape:

```lean
-- Every input satisfying pre succeeds and satisfies post.
def Ensures (program : Env → Result) (pre : Env → Prop)
    (post : Env → Value → Prop) : Prop :=
  ∀ env, pre env → ∃ value, program env = .ok value ∧ post env value
```

Assertions are translated from Rust, not assumed true. A safety contract must
prove they cannot fail under its preconditions. Invariants may also be stated
directly over generated functions or inductive traces using those functions.

## Verify existing code without distorting it

[The Jarl project](examples/jarl/project.json) selects expressions from the
existing `Membership` and `Node` implementations. A slice names an inherent
`Type::method`, follows structural AST selectors, and declares the free scalar
locations and types to abstract as parameters. These declared types and their
relationship to the original context are assumptions; rustc checks the resulting
closed abstraction, **not their provenance in the host method**. The original
host crate should still be built/tested separately, as CI does for Jarl.

For example, `let:majority / closure / tail` selects the body expression of the
local majority closure, rather than matching a copied `count > total / 2` string.
`let:new:old / index` covers both quorum-position calculations.
`calls:commit_to:0:2` selects the first argument at exactly two call sites; their
extracted expressions must agree. The manifest preserves all selected sites.

Selectors currently supported: `tail`, `let:name[:name...]`, `stmt:index`,
`closure`, `index`, `condition`, `right`, `arg:index`, and
`calls:method:argument_index:expected_count`. Indices are zero-based. Ambiguous
methods, missing sites, changed shapes/counts, attributed methods, and differing
multi-site expressions fail. Bindings can replace variables or field paths;
selected expressions cannot introduce binders or macros.

`guarded_assignment_prefix` translates the first assignment inside an `if` without
an `else` into its scalar value transition, using the old target value when the
condition is false. The condition, assignment target, and assigned expression all
come from the source AST. **Its proof ends at that assignment point.** Later
statements, effects of calls, and whole-method equivalence remain outside scope.

Jarl's ten scalar-rule obligations establish:

| Selected rule | Proven property |
| --- | --- |
| Majority predicate | Strict majority, count overlap, and a shared voter for two majorities of any finite voter list; stable/joint boundary overlap through each shared configuration |
| Both quorum-position calculations | Index is in bounds for every positive, representable cluster size |
| Joint commit minimum | Result is bounded by both supplied quorum indices |
| Both follower commit minima | Result is bounded by the supplied leader and matched indices |
| Guarded commit assignment | Commit value does not decrease, including across arbitrary traces of this extracted assignment |
| Current-term predicate | Acceptance requires equal supplied terms |

The proofs quantify over counts, not a fixed cluster size, and run at both 32-bit
and 64-bit `usize`. The intersection theorems assume that the supplied counts are filters of the
same voter list; the joint theorem requires a majority in both configurations.
They do **not** prove that Jarl computes those voter lists/counts correctly,
that order statistics correspond
to acknowledged voters, membership-transition safety, log matching, persistence
ordering, or complete Raft safety/liveness. In particular, the commit trace is a
trace of the extracted assignment prefix, not full `Node` execution.

## Complete method bodies

`verify-methods` is a separate, deliberately restricted method backend. It loads
an actual crate module tree, resolves written fields from its struct declarations,
and type-checks the original crate with the installed rustc. It does not accept
manual field-type bindings or expression selectors. All explicit statements in
each selected method must translate; an unknown call or statement rejects it.

```sh
cargo run --manifest-path provium/Cargo.toml --locked -- \
  verify-methods provium/examples/jarl-methods/project.json \
  --out provium/artifacts/jarl-methods
```

The supported body language includes literal assignments to `bool` and
`Option<u64>` fields, `if`/`else if`/`else`, boolean field reads, `!`, `&&`, and `||`,
rooted at a receiver with exclusive access. Branches read the current store,
including preceding writes. Direct receiver-local helper calls without arguments
are resolved to inherent methods and inlined; their receivers must be `&mut self`.
Recursion, unresolved calls, and expansion beyond the depth/node limits fail
closed. Every branch and callee must translate, even when it appears unreachable.
Methods must return unit and have no ordinary arguments. A consumed receiver is
accepted only if every field is a mutable reference; custom receiver destructors
are rejected. This avoids pretending implicit drops have no effects. Generic
field traversal, import aliases, item macros, conditional production definitions,
and unsupported attributes are rejected. The input crate currently must compile
without external dependencies using Rust 2021.

[The Jarl method project](examples/jarl-methods/project.json) translates the entire
explicit body of `Ready::persisted`. Lean proves that its three persistence flags
are cleared, that all other modeled leaf locations retain their values, and that
the effect is algebraically idempotent. No statement after an assignment is
excluded. This is not permission to reuse a consumed token or acknowledge a save
that did not happen.

The generated function and instruction tree share a generic field-store
semantics in `lean/Provium/State.lean`; their correspondence is checked for every
initial store. Stores map **leaf locations**, not overlapping aggregate values,
to cells with arbitrary opaque payloads. Rust-to-store representation, exclusive
borrowing, field resolution, and frontend translation remain trusted. The frame
theorem does not assert that a containing aggregate is unchanged when one of its
fields changes. A kernel-checked structural frame theorem covers all branches
and sequential effects. Non-boolean cells have a total extension when read as a
condition; Rust refinement requires boolean source fields to contain boolean
cells. The storage backend's durability contract remains an assumption.

The method manifest includes all loaded production Rust files, the complete
selected bodies, source-resolved written types, and the remaining unproved
**inherent methods**. That list is not a complete obligation inventory: free
functions, trait implementations, standard-library semantics, and global protocol
invariants also require proofs. `verified.json` explicitly records
`whole_raft_proved: false`. The new proofs are component evidence, not a complete
Raft proof. Both literal-mutation controls and a mutation of Jarl's actual
acknowledgment code must fail in Lean, not merely in the parser or compiler.
Conditional/helper-call tests compare compiled Rust outcomes with Lean, prove
state-update ordering and framing for arbitrary stores, and require a changed
branch to break the proof.

## Complete optional-record array methods

The [membership project](examples/jarl-membership/project.json) translates both
`Membership::finalized` and `Membership::is_joint` from their complete production
bodies. Array traversal supports a single receiver array of optional records,
exclusive iteration, a `Some` binding, typed boolean field updates/branches, and
slot deletion. The consumed receiver and records must derive builtin `Copy`,
which rustc checks, so deletion cannot hide destructors. Read-only queries support
`iter().flatten().any(...)` with a pure boolean record predicate. Custom trait
methods that could shadow the modeled iterator operations cause rejection.

Arrays are modeled as lists with their empty slots preserved. Proofs quantify
over arbitrary lengths, including zero, rather than an enumerated cluster size.
They establish preserved capacity; retention exactly for target voters or
learners; cleared old-voter flags; unchanged retained fields and identities; and
that the generated `is_joint` returns false after generated `finalized`.

The reserved `$present` cell records slot deletion inside Provium and cannot name
a Rust field. It is excluded from record-field frame claims. The same trusted
frontend and Rust representation/borrow boundary applies as for other method
proofs. These contracts do not establish that a reachable Raft leader is
*authorized* to finalize a configuration, or that its entry has been committed.
The tests compare the actual method bodies with interpreted generated effects
for every optional-record combination at capacities 0–3, and require mutations of
retention, old-voter clearing, and the joint query to fail in Lean.

## Complete scalar-method projections

The [election project](examples/jarl-election/project.json) uses:

```json
{
  "scalar_method": {
    "crate_root": "../../../jarl/src/lib.rs",
    "method": "node::Node::reset_election"
  },
  "namespace": "JarlElection",
  "usize_bits": 64
}
```

This mode resolves all accessed field types from the original production crate,
checks that crate with rustc, and generates a scalar function for every written
field. Each function executes **every statement** before returning its field:
a later division fault also faults an earlier field's projection. The manifest
records the original complete method, all source files, field paths/types,
parameter order, and generated projection names. No hand-written field bindings
or expression selectors are accepted. Currently it admits `&mut self`, no
ordinary parameters, a unit return, builtin `u64` fields, and bodies accepted by
the closed scalar frontend after field resolution. Unsupported syntax fails
closed; generated identifiers cannot collide with source locals.

These are successful-state projections. A fault does **not** describe the Rust
store after partial mutation; proving a successful result is required before
using a final-field contract. Borrow/layout refinement and frontend translation
remain trusted. This does not establish a whole-Raft proof or election liveness.

For the unchanged `Node::reset_election`, the contracts require a positive tick
interval at most `2^63` and valid `u64` inputs. They state successful execution of
every projection, elapsed time reset to zero, the exact wrapping seed advance,
and a deadline in `[ticks, 2*ticks)` within `u64`. The tick-range assumption must
still be connected to reachable Jarl configurations. Native Rust comparisons and
source mutations exercise these projections through the normal verification
scripts.

## Validation and next boundary

The tests compare actual compiled Rust with IR evaluation for every byte pair on
the guarded-division and arithmetic fixtures, plus boundary/failure cases for
other operations, local updates, and nested calls. Lean checks concrete native
boundary results too. Negative controls mutate original Jarl source in temporary
copies: non-strict majorities, joint/follower `max` instead of `min`, inverted term
equality, and a regressing commit assignment must fail **in the invariant proof**;
a parser or selector error does not count as detecting those mutations.

The next substantial step is a typed, resolved Rust frontend (for example, a
pinned MIR exporter) with semantics for structures, borrowing, loops, and calls,
followed by whole-method/state-transition proofs. That would remove manually
declared slice types and enlarge the proved behavior without rearranging Jarl.
An end-to-end equivalence claim additionally needs a justified or verified
frontend translation; generating more Lean alone does not close that gap.

Background: [Lean proof validation](https://lean-lang.org/doc/reference/latest/ValidatingProofs/),
[Lean axioms](https://lean-lang.org/doc/reference/latest/Axioms/), and
[Rust operator semantics](https://doc.rust-lang.org/reference/expressions/operator-expr.html).
