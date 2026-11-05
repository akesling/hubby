# Jarl's proof contracts

Jarl owns these contracts and asserts them using **Provium as a dev-dependency**.
The entry point is [`tests/proofs.rs`](../tests/proofs.rs).
The runtime remains `no_std` and sans-I/O; Provium is not a runtime dependency.

[CORRECTNESS_PLAN.md](CORRECTNESS_PLAN.md) specifies the complete source-level
correctness goal, outstanding obligations, assumptions, milestones, and release
gates. It is a plan, not evidence that those obligations have been proved.
See [M0.md](M0.md) for the completed claim/inventory audit and
[PROGRESS.md](PROGRESS.md) for implemented evidence and the remaining dependency frontier.

`coverage.json` records a reviewed syntactic inventory of every item in the
production module tree, and binds items with component evidence to obligations
of the proof project below. Ordinary tests reject source changes until that
review is updated. `jarl/scripts/verify-complete.sh` deliberately fails while
source correspondence and composed safety/progress certificates are
unavailable.

From the repository root:

```sh
cargo test -p jarl --test proofs --locked
jarl/scripts/verify.sh
jarl/scripts/verify-m0.sh
```

The first command verifies every project below (`provium::assert_proofs!`). The
script additionally runs the slow checks: the proof project against a 32-bit
(wasm32) build and the source-mutation negative controls. Missing Lean fails
verification; install elan and the version required by Provium first. Set
`PROVIUM_LEAN_MEMORY_MB=8192` as CI does.

## Projects

| Project | Contracts and scope |
| --- | --- |
| [engine](engine/README.md) | Provium's typed translation of Jarl (`Node`, `State`, `Membership`, `Ready`, and the dynamic `Cluster` engine) with Raft safety for the fixed engine (election, state-machine and snapshot safety for every reachable cluster under message loss, duplication and reordering, crashes and restarts) and every component contract below; 537 obligations, checked on the host and on wasm32, plus a differential scenario against native Jarl |
| [specification](specification/Model.lean) | M0 handwritten specification: genesis, host transaction/crash/cancellation, network provenance and external scheduling witnesses; no Rust correspondence claim |
| [election-safety](election-safety/Model.lean) | M2 handwritten model of elections in both engines over a fixed voter set, with historical at-most-one-leader-per-term by induction; no Rust correspondence claim |

### Component contracts (`engine/Contracts/`)

Each module restates, over the typed translation, the contracts of a former
deep-embedding project, at least as strongly: interpreter-level projections
became exact results, and fuel, loan and IR-path premises disappeared with the
deep embedding.

| Module | Rust | Contracts |
| --- | --- | --- |
| `Capacity` | `State::full` | Exact result; non-full implies room under `len ≤ CAP` |
| `Initialization` | `State::new` | The exact initial record: zero hard state, no snapshot, every slot empty |
| `InputGating` | `Node::available`, `idle`, `Ready::persisted` | Exact gate (dirty, pending reply, pending outbox); acknowledgment clears dirty state but not pending output |
| `LogBoundary` | `State::base`, `get`, `id_at`, `entries`, `last` | Snapshot boundary, exact lookup for every offset (including offsets a 32-bit `usize` cannot address), ordered prefix iteration, exact final id |
| `MessageDispatch` | `Message::term` | Every variant reads its durable term (`PreVoted` its term, not its campaign) |
| `Persistence` | `Ready::persisted` | The exact resulting node; idempotence |
| `NodeElection`, `Election` | `Node::reset_election`, `follow` | Exact resulting records: SplitMix64 seed advance, deadline in `[ticks, 2·ticks)`, zero elapsed time |
| `MessageValidation` | `Node::valid` | `valid m = decide (Accepts m)` for every message: an exact per-variant acceptance condition, including ordered batches |
| `Storage` | `State::push`, `truncate`, `install`, `restore`, `grow`, `hard`, `snapshot`, `new` | Exact effects, buffer shape, ordered-log representation, committed-prefix preservation, restore soundness and completeness, and a storage-history induction over every operation |
| `StorageView` | `State::write`, `Write::entries` | The exact persistence view and payload suffix; checkpoint equivalence and retry idempotence of the host transaction |
| `Replication` | `Node::valid`, `State::id_at`, `truncate`, `push` | Validated appends supply the storage successor condition; replacement preserves the ordered log and committed slots |
| `Membership*` | `Membership::*` | Finalization, projections, identity queries, inclusion, restoration, stable/learner/joint construction, peers; `quorum` and `quorum_index` over arbitrary callbacks, with quorum intersection |
| `Consensus` | `quorum`, `quorum_index`, `joint`, `Node::append`, `commit_to`, `advance_commit` | Strict majorities and their intersection (including across joint transitions), quorum positions, joint commit requiring both majorities, followers never overcommitting, commit monotonicity, current-term commitment |

## Evidence and limits

- **Kernel checking.** Generated code and every proof module are checked by the
  pinned Lean with `--trust=0`; each obligation's theorem must refer to its
  generated function and use only `propext`, `Quot.sound` and
  `Classical.choice`.
- **Targets.** The project verifies against the host build and a wasm32 build
  (`builds-wasm32.json`), where `usize` is 32 bits; statements use
  `Rust.usizeBits` where the width matters.
- **Negative controls.** `tests/proof_cases/engine_mutations.rs` applies source
  mutations (every one ported from the former projects, plus seeded Raft bugs)
  and requires each to be rejected by a named proof module, not by the front
  end, Cargo or the generated code.
- **Differential testing.** `engine/differential.rs` drives the fixed engine
  and the dynamic engine (learner addition, joint consensus, finalization)
  natively and in Lean and requires identical results.
- **Trusted.** Provium's typed front end (name resolution and type inference
  with `syn`) and the interpretation of each operation in its `Rust.lean`;
  see [`provium/docs/typed-backend.md`](../../provium/docs/typed-backend.md).
  Panics are terminal (unwinding is not modelled), and the application's
  `Clone` is assumed lawful where the engine theorems need it.
- **Open.** Dynamic-engine safety (M4), host and API refinement (M5), source
  correspondence closure (M6), liveness (M7).

`tests/proof_cases/quorum_callbacks.rs` keeps native regression tests of the
original quorum callbacks' call order, short-circuiting and cleanup.
