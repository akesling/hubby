# Typed proofs of Jarl

Provium's typed backend translates Jarl's engines (`node.rs`, `state.rs`,
`membership.rs`, `ready.rs`, `cluster.rs`) to ordinary Lean definitions
(`Generated.lean`, produced at verification time). This project holds every
Rust correspondence claim about Jarl:

- `Engine/`: Raft safety of the fixed-membership `Node` engine (M3), below.
- `Engine/Dyn/`: Raft safety of the dynamic-membership `Cluster` engine (M4),
  under [The dynamic engine](#the-dynamic-engine).
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

A save may also become durable without being acknowledged: a cancelled
`persist_async` whose storage finished the write, or a save that reported an
error after writing (`HAct.save`). Such a node is still dirty, so every
operation except acknowledging and restarting leaves it unchanged, and the
refinement matches the save with the model's `persist` while the model waits
(`Unacked`); repeating the write is idempotent.

### The host adapters

`Engine/Host/Adapters.lean`: the storage is consumer code, so `host.rs`'s
contract is an assumption stated against a durable view of it (`StorageOk`,
`AsyncStorageOk`): a successful save has made the whole transaction durable; a
failed save, or a dropped asynchronous one, applied it in full or not at all
and never later. From the generated bodies, every run of `persist`, and of
`persist_async` completed or dropped after any number of awaits, is
acknowledged with the write durable, or unacknowledged with the write applied
in full or not at all (`persist_outcome`, `persist_async_outcome`). These are
exactly the host steps above (`persist_step`, `persist_async_step` in
`Engine/Host/Adapted.lean`), so the host theorems cover hosts that persist
through either adapter, synchronously or asynchronously, with failed and
cancelled saves.

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

## The dynamic engine

`Engine/Dyn/Safety.lean`: for every world reachable by `DAct` from empty
checkpoints, under `Assumptions` (distinct node identities `ids`, a genesis
configuration `g` with distinct identities and a voter, capacities that fit
the pointer width):

| Theorem | Statement |
| --- | --- |
| `Dyn.election_safety` | Two nodes that are leader in the same term are the same node. |
| `Dyn.state_machine_safety` | Two entries exposed as committed at the same index (by any nodes, at any two points of one execution) are equal. Configuration records are entries, so every node agrees on the committed configuration history. |
| `Dyn.snapshot_safety` | A snapshot exposed by a node agrees, at its boundary, with every entry and snapshot exposed later at that index. |

### Execution model

`Engine/Dyn/World.lean`: `K` nodes with distinct identities run the generated
`Cluster` operations. Every node starts from `ClusterState::new` with the shared
genesis configuration; one whose identity is outside a configuration is
passive until a configuration adds it. `DAct` steps any node through
`Cluster::tick`, `step` (any envelope ever sent), `propose`, `propose_batch`,
`compact`, `set_learners`, `reconfigure` (to any valid `Membership`),
`finish_reconfiguration`, `ready` and `persisted`, `next_message` (send or drop), and
restart through `ClusterState::restore` and `Cluster::new`, with any arguments
at any time. Configurations need not intersect: learners join, voters are
replaced through joint configurations, removed leaders step down, and peer
slots are reused.

### Why it holds

Quorums of two arbitrary configurations need not intersect, so the argument
rests on how configurations follow each other in leader logs (`Ghost.lean`,
`Chain`):

- each configuration record is one `Step` from the configuration before it,
  and every configuration one step from `C` keeps `C`'s voters as its voters or
  as its old voters (`Config.lean`, `near_inter`);
- a configuration record is only followed by another once it is committed
  (`change_available` and `finish_reconfiguration` require it).

From these, every committed prefix has a commitment whose configuration is
at most one step from the configuration before its last entry (`Wf.good`,
kept by `good_preserve`). Leader completeness (`leader_complete`) then
follows: where a candidate's log diverges from a committed log, both the
candidate's configuration and that commitment's configuration are near the
configuration at the divergence point, so some voter acknowledged the
committed entry. The same argument shows that election quorums of one term
intersect (`tk_inter`).

A node that wins at once with its own vote, a configuration whose quorum is
itself, becomes leader before saving its term. That win is recorded in the
ghost only when the term is saved (`PendingWin`, `winOwnD`), so a crash in
between leaves no trace. A leader removed from its configuration can step down
with unsaved entries and keep replicating them (`Leading` holds of any
role).

### Hosts, errors and growth

- `Dyn/Host`: the delta-persisting host refinement for the dynamic engine, with
  unacknowledged saves and both adapters: `dhost_refinement`,
  `dhost_write_exact`, and `dhost_election_safety`,
  `dhost_state_machine_safety`, `dhost_snapshot_safety` over reachable host
  clusters; `persist_dstep`, `persist_async_dstep`.
- `Dyn/Errors`: what every public `Cluster` operation's errors mean. Every error
  of `propose`, `propose_batch`, `compact`, `set_learners`, `reconfigure`,
  `finish_reconfiguration` and `step` leaves the cluster unchanged, with the
  exact condition for each error variant; `Busy` is returned exactly when a save
  or message is pending; `tick`'s `Exhausted` (the term cannot be incremented)
  changes only the elapsed time and leader age; `ClusterState::restore` and
  `Cluster::new` fail exactly on a joint genesis and on invalid capacity or
  timers. Successful proposals and membership changes append exactly their
  record at the returned identity (`errs_*_ok`).
- `Dyn/Grow`: `Cluster::grow` keeps every field except capacity, and the
  invariant holds of a cluster whose nodes and checkpoints are all grown
  (`inv_of_grow`), so growth composes with every theorem above.

### Proof structure

| Module | Content |
| --- | --- |
| `Dyn/Config`, `Dyn/Ghost`, `Dyn/GhostFacts` | Configurations of logs, quorums, configuration steps; the ghost's well-formedness and leader completeness |
| `Dyn/Node`, `Dyn/Refresh`, `Dyn/Ops` | Node facts (`DynOk`); `membership_at`, `refresh_membership` (slot reconciliation keeps progress with its identity), and the internal helpers |
| `Dyn/Spec`, `Dyn/Op*` | One relation per public operation, proved from the generated bodies |
| `Dyn/World`, `Dyn/Frame`, `Dyn/Common` | The cluster model, the invariant `Inv`, framing |
| `Dyn/P/*`, `Dyn/Preserve` | Every step preserves `Inv` |
| `Dyn/Safety` | The theorems above |

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
- Application state (`Engine/App`) is proved for the fixed engine only.
- Storage meets the adapter contract above: atomic, durable before success,
  and after a failure or cancellation either fully applied or not at all, with
  no older write applied after a later one.
- Panics and divergence are crashes; an unwinding panic caught by the host is not
  modelled (the shared limitation of the typed backend).