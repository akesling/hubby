# Typed proofs of Jarl

Provium's typed backend translates Jarl's engines (`node.rs`, `state.rs`,
`membership.rs`, `ready.rs`, `cluster.rs`) to ordinary Lean definitions
(`Generated.lean`, produced at verification time). This project holds every
Rust correspondence claim about Jarl:

- `Engine/`: Raft safety of the fixed-membership `Node` engine (M3), below.
- `Contracts/`: the component contracts (storage, membership, validation,
  timers, gating and the rest), listed in [the proofs README](../README.md).

Both are checked against the host build and a wasm32 build, and
`differential.rs` compares the translation with native Jarl.

```text
cargo test -p jarl --locked --test proofs engine -- --include-ignored
```

## Claim

`Engine/Main.lean`, for every cluster reachable from `Node::new` on empty
states under `Assumptions` (a non-empty, duplicate-free membership `ids` shared
by every node, node `k` having identity `ids[k]`):

| Theorem | Statement |
| --- | --- |
| `election_safety` | Two nodes that are leader in the same term are the same node. |
| `raft_state_machine_safety` | Two entries exposed as committed at the same index (by any nodes, at any two points of one execution) are equal. |
| `raft_snapshot_safety` | A snapshot exposed by a node agrees, at its boundary, with every entry and snapshot exposed later at that index. |

A node exposes an entry when it is clean (nothing pending persistence) and the
entry is retained at or below its commit index, which is exactly what
`Node::committed` yields; it exposes a snapshot when it is clean and holds it.

### Hosts that persist deltas

`Engine/Host`: a real host keeps a durable record (hard state, snapshot,
entries), applies each `Ready::write` delta to it as `ready.rs` documents, and
recovers with `State::restore` and `Node::new`. `host_refinement` shows every
such host execution is an execution of the model above whose durable states
restore exactly from the host's records, and `host_election_safety`,
`host_state_machine_safety` and `host_snapshot_safety` restate the three
theorems for it. The core is `DeltaOk`: Jarl's dirty tracking (`log_from`,
`snapshot_changed`) always describes exactly how the live state diverged from
what was last saved, so applying the write reproduces the live state
(`host_write_exact`).

### Snapshot application state

`Engine/App`: with the application given as `init : S` and
`apply : S → Option V → S`, and a host that compacts honestly (the snapshot
value is the current snapshot's state with the retained entries up to the
index applied), `raft_snapshot_application_safety` shows every exposed
snapshot's value is the application state of the committed history through
its boundary, and `raft_snapshot_value_agreement` that two exposed snapshots
at the same index hold the same value.

## Execution model

`Engine/Cluster.lean`: a cluster is the live `Node` of each member, its
durable state, and every envelope ever sent. `Act` steps any node through the
generated code:

- `Node::tick`, `Node::step` of any envelope ever sent (so the network drops,
  duplicates, delays and reorders arbitrarily);
- `Node::propose`, `Node::propose_batch` and `Node::compact` with arbitrary
  arguments;
- `Node::ready` followed by `Ready::persisted`, which writes the node's state
  to its durable state;
- `Node::next_message`, which adds the envelope to the network, or which
  drops it;
- restart: `Node::new` from the durable state.

An operation that panics or diverges has no transition, which is equivalent to
the node crashing and restarting.

## Proof structure

| Module | Content |
| --- | --- |
| `Log`, `Fixed`, `NodeOps` | Log representation (`Layout`, `Contig`, full-log index), the fixed configuration and the helper operations |
| `Append`, `Replicated`, `NextMessage`, `Host`, `Step`, `Tick`, `Api` | One relational specification per public operation and message kind, proved from the generated bodies |
| `Ghost` | Ghost history: leader logs per term, elections with their election logs, acknowledgments and ballots; log matching, majority intersection, leader completeness and committed-prefix compatibility |
| `Invariant`, `Frame`, `LogFacts`, `Init` | The inductive invariant `Inv`, its framing over single-node updates, full-log facts and its initial establishment |
| `Preserve/*` | `preserve`: every `Act` preserves `Inv`, extending the ghost history |
| `Safety`, `Main` | Induction over executions and the theorems above |
| `Host/*` | Delta-persisting hosts: `DeltaOk`, per-operation agreement, refinement to the model, host theorems |
| `App/*` | Honest compaction, the snapshot-value invariant and the application-state theorems |

## Assumptions and limits

- The translation is trusted as described in
  [`provium/docs/typed-backend.md`](../../../provium/docs/typed-backend.md):
  the `syn` front end's name resolution and type inference, and the
  interpretation of each `Rust.lean` operation. The differential scenario
  (`differential.rs`) compares the translation with native Jarl.
- The application's `Clone` for `V` and `S` is arbitrary (it may panic or
  diverge, which is no transition), but the theorems assume it is lawful:
  when a clone returns, it returns an equal value (`Rust.LawfulClone`).
  Without that, a follower could append a different entry than the leader
  sent. A panic ends the node's execution (see above).
- The host persists each write atomically before acknowledging it
  (`Ready::persisted`), and compacts with the application state it actually
  reached (the honest-compaction premise of `Engine/App`).
- Only the fixed engine. The dynamic `Cluster` engine (M4) is translated
  (it is in the project's roots and the differential scenario drives it through
  learner addition, joint consensus and finalization), but its safety is not
  yet proved.
