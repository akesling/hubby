# Fixed-engine safety (M3)

Provium's typed backend translates the fixed-membership `Node` engine
(`node.rs`, `state.rs`, `membership.rs`, `ready.rs`) to ordinary Lean
definitions (`Generated.lean`, produced at verification time). The modules
under `Engine/` prove Raft's safety properties about those definitions for
every reachable cluster.

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

## Assumptions and limits

- The translation is trusted as described in
  [`provium/docs/typed-backend.md`](../../../provium/docs/typed-backend.md):
  the `syn` front end's name resolution and type inference, and the
  interpretation of each `Rust.lean` operation. The differential scenario
  (`differential.rs`) compares the translation with native Jarl.
- Application `Clone` returns an equal value without panicking, and a panic
  ends the node's execution (see above).
- Persistence writes the whole state at once (`Cluster.persist`); a host
  writing only the `Write` delta is covered by the storage-view contracts, not
  here.
- Snapshot application values are not tracked: snapshot safety is about the
  boundary identity, not the snapshot's application state.
- Only the fixed engine; the dynamic `Cluster` engine (M4) is out of scope.
