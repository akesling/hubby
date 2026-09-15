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
It does not yet prove preservation through restore/push/truncate/install or
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
