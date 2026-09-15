# Jarl's proof contracts

Jarl owns these contracts and asserts them using **Provium as a dev-dependency**.
The entry point is [`tests/proofs.rs`](../tests/proofs.rs).
The runtime remains `no_std` and sans-I/O; Provium is not a runtime dependency.

[CORRECTNESS_PLAN.md](CORRECTNESS_PLAN.md) specifies the complete source-level
correctness goal, outstanding obligations, assumptions, milestones, and release
gates. It is a plan, not evidence that those obligations have been proved.
See [PROGRESS.md](PROGRESS.md) for implemented evidence and the remaining dependency frontier.

`coverage.json` records a reviewed syntactic inventory of every item in the
production module tree. Ordinary tests reject source changes until that review is
updated. Calls remain unresolved in this inventory; it is not a closure proof.
`jarl/scripts/verify-complete.sh` deliberately fails while source correspondence
and composed safety/progress certificates are unavailable. The existing
`verify.sh` checks the supported component contracts.

```rust
#[test]
fn invariants() {
    provium::assert_proofs!("proofs");
}
```

From the repository root:

```sh
cargo test -p jarl --test proofs --locked
jarl/scripts/verify.sh
```

The first command asserts the checked contracts and runs native comparisons.
The script additionally runs slow source-mutation and 32-bit checks. Missing Lean
fails verification; install elan and the version required by Provium first.
CI runs both ordinary tests and the full proof gate.

| Project | Contracts and scope |
| --- | --- |
| [consensus](consensus/Proofs.lean) | Source-expression slices: strict majority, actual shared-voter intersection, stable/joint boundary overlap, quorum-position bounds, joint/follower minima, commit-prefix monotonicity, and current-term checks |
| [persistence](persistence/Proofs.lean) | Complete `Ready::persisted` field effects: clear flags, preserve other leaves, algebraic idempotence |
| [election](election/Proofs.lean) | Complete `Node::reset_election` successful-state projections: exact wrapping seed advance, zero elapsed time, and deadline in `[ticks, 2*ticks)` |
| [membership](membership/Proofs.lean) | Complete `Membership::finalized` and `is_joint`: arbitrary capacity, correct retention/removal, cleared old flags, surviving identities/fields preserved, no longer joint |
| [input-gating](input-gating/Proofs.lean) | Complete `Node::available` and `idle`: exact Result, dirty-state/reply/outbox rejection, and clean/drained admission over arbitrary outbox lengths |
| [capacity](capacity/Proofs.lean) | Complete `State::full`: exact equality against the original const-generic capacity; non-full implies room under the separate `len ≤ CAP` representation invariant |
| [log-boundary](log-boundary/Proofs.lean) | Complete `State::base`, `get`, `id_at`, `entries` and `last`: snapshot boundary, checked borrowed lookup, ordered prefix iteration, and exact boundary/final-entry records |
| [storage](storage/Proofs.lean) | Complete `State::push`, `new`, `grow` and `truncate`: no-drop append/growth, occupied-prefix/capacity and metadata preservation, explicit destruction boundaries, and induction over histories with changing capacity |
| [initialization](initialization/Proofs.lean) | Complete `State::new`: initial hard-state fields, absent snapshot, all slots empty for arbitrary capacity, and initial `len ≤ CAP` |

Each directory's `project.json` binds production Rust to explicit theorem
obligations. Generated Lean, snapshots, hashes, and certificates are written to
`jarl/artifacts/provium/proofs/<project>/`. Proof-specific regression tests live in
`jarl/tests/proof_cases/`; Provium's tests use independent compiler fixtures.

These are component contracts, **not a full Raft correctness proof**. The scalar
consensus slices exclude surrounding method effects. Their count/list assumptions
must still be connected to reachable protocol state. The commit trace covers a
guarded assignment prefix, not all of `commit_to` and `refresh_membership`.

The timer contracts assume valid u64 inputs and `0 < ticks ≤ 2^63`; connecting
that assumption to reachable configurations remains a separate obligation.
Successful-state projections execute every statement, including late faults, but
do not describe partially mutated stores after a panic. The persistence contract
does not authorize acknowledging an undurable save or reusing a consumed token.
Membership finalization contracts do not establish that finalization was
protocol-authorized or its log entry committed.

Input-gating contracts use typed query stores for bool, Option and optional-array
fields. They prove the complete gate and its inlined wrapper, not that every
protocol caller invokes the gate or that storage acknowledgment was truthful.
Source-to-store representation and frontend preservation remain trusted.
The project also composes the generated `Ready::persisted` effect with the gate:
acknowledgment clears dirty state but does not bypass pending output. Its explicit
view relation does not claim to prove Rust alias/layout correspondence. The full
gate checks this project against both the host and installed 32-bit target.

Initialization derives the initial length bound from the generated constructor.
Storage now composes it with append preservation. Neither project proves
preservation through restore/install or
authorize resetting an existing voter. Builtin Default and array-construction
semantics, source interpretation and Rust layout remain in the trusted boundary.

Array proofs quantify over arbitrary lengths, including empty arrays. Native
comparisons additionally cover every optional-record combination at capacities
0–3. Source mutations must fail in the invariant proof, not just the parser or
Rust compiler. Consensus and timer verification also exercise an installed
32-bit no_std target.

Provium's frontend, Rust subset semantics, field/borrow/layout refinement, and
Lean implementation remain trusted. Axiom audits reject admits and custom axioms;
they cannot establish specification adequacy. Global Raft safety/liveness,
crash-recovery assumptions, and compiler correctness remain open proof work.

The storage backend retains the entire bounded append body and its original
capacity helper. A valid shape requires occupied slots below `len`, empty slots
above it, and a capacity-sized array. Under that invariant and available room,
Lean proves append returns without destruction or arithmetic/bounds failure,
preserves earlier payloads, and advances length by one. An inductive theorem
covers any finite sequence of successful appends from the generated constructor.
This does not cover all reachable Raft storage histories or prove log-ID ordering.

Rejected owned inputs and overwritten payloads have explicit drop suspensions.
Their continuations apply only if destruction returns normally. Destructor panic,
unwinding and external side effects are not erased into a successful transition.
The native compiler tests compare slots, length, destructor order and late panic
states; source mutations and wasm32 checks exercise Jarl's actual method.

Growth translates the original consuming `State::grow` body, including its const
assertion, generic substitution, all metadata transfers, and indexed Option::take
callback. The proof covers arbitrary nondecreasing capacities and preserves every
live payload, length and metadata without invoking Drop. The storage-history
induction allows repeated appends, growth and normally completed truncations; it is not fixed to one capacity.
Native tests cover copied and moved metadata and disposal of out-of-prefix
payloads in malformed states. Partial-record ownership during a failed
construction, panic hooks, and destructor unwinding are outside the current
relocation model; the verified valid-state path encounters none of those effects.

Snapshot-boundary selection includes its eager derived Default computation and
complete shared Option projection. Its generated program retains both receiver
and payload field paths; an independent provider mutation selecting another
same-typed record must fail the proof. Storage contracts also bind their
projected arrays, lengths and capacity parameters to the original source names.
These bindings guard source drift; they are not Rust memory-layout proofs.

Lookup translates all of `State::get` and its original `base` helper. Its result
is a borrowed array place, retaining both the source field path and offset.
The contracts cover every offset after a valid base, including usize conversion
failure, out-of-bounds access and empty slots; indices at/before the boundary
return None. Native tests compare pointer identity, and provider/Jarl mutations
alter the offset or selected base field. The result's physical borrow validity
and correspondence between each entry's LogId and its slot still need proof.

`State::id_at` now composes both complete helpers with the original equality
branch and entry-record projection. It returns the full base record at the
boundary (including genesis), the selected entry's full `id` record on a hit,
and None on an off-boundary miss. The proof does not assume that an arbitrary
stored entry's id.index equals the requested index; contiguous log-ID invariants
remain work for restore, append callers, truncation and snapshot installation.

`State::entries` retains the complete prefix-slice check and builtin double-ended
iterator construction. Its list is a denotation of borrowed locations, not a
claim that Rust eagerly traverses or allocates. `State::last` includes the complete
iterator and eager base helper: an empty retained prefix returns the base, and a
final present retained slot returns that entry's id even with holes earlier in
the prefix. Native tests alternate both iterator ends and check that entry
Drop is never invoked during those reads. Invalid-prefix panic hooks/unwinding
and Rust lifetime/layout correspondence remain outside the current model.

Truncation translates the entire original loop and its complete last-record,
iterator and snapshot-boundary helpers. The proof preserves shape and every
retained payload, exposes each destructor after decrementing length, and proves
the internal interpreter fuel cannot run out. Native tests compare sparse and
malformed buffers, bounds-panic state, removal boundaries and destructor order.
Following a drop continuation requires normal destructor return; metadata-view
refinement, panic/unwinding and committed-prefix preservation remain open.
