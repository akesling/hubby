# Jarl's proof contracts

Jarl owns these contracts and asserts them using **Provium as a dev-dependency**.
The entry point is [`tests/proofs.rs`](../tests/proofs.rs).
The runtime remains `no_std` and sans-I/O; Provium is not a runtime dependency.

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

Array proofs quantify over arbitrary lengths, including empty arrays. Native
comparisons additionally cover every optional-record combination at capacities
0–3. Source mutations must fail in the invariant proof, not just the parser or
Rust compiler. Consensus and timer verification also exercise an installed
32-bit no_std target.

Provium's frontend, Rust subset semantics, field/borrow/layout refinement, and
Lean implementation remain trusted. Axiom audits reject admits and custom axioms;
they cannot establish specification adequacy. Global Raft safety/liveness,
crash-recovery assumptions, and compiler correctness remain open proof work.
