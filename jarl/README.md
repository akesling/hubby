# Jarl

Allocation-free, `no_std`, sans-I/O Raft with runtime membership. The consumer
owns time, authenticated transport, durable storage, and the application state
machine. There are no dependencies, runtime requirements, or unsafe code.
Synchronous and asynchronous hosts use the same protocol API.

`Cluster<V, S, MAX, CAP>` supports a variable set of voters and learners within
`MAX` simultaneous peers and `CAP` retained log entries. Identities can be added
and removed throughout the cluster's lifetime. `MAX` must also accommodate the
union of old voters, new voters, and learners during reconfiguration; it is not a
fixed voter count. Application values and snapshots require only `Clone`.
Their clone implementations may allocate; Jarl does not. Payloads must remain
logically immutable after submission.

This is an experimental implementation with executable correctness evidence.
Independent protocol review and deployment experience remain release gates;
the tests are not an unbounded proof. See [AUDIT.md](AUDIT.md).

## Start a node

A single-voter example; the checkpoint copy below stands in for atomic durable
storage. Persist a unique cluster namespace, identity, and genesis membership in
an immutable storage header before starting a fresh voter.

```rust
use jarl::{Cluster, ClusterState, Id, Membership, Record, Role, Settings, State};

let genesis = Membership::<8>::new(&[Id(10)], &[])?;
let mut disk = State::new();
let saved = ClusterState::restore(Id(10), genesis, disk.clone())?;
let mut node = Cluster::<u64, u64, 8, 32>::new(
    Settings { seed: 123, ..Settings::default() }, saved,
)?;
while node.role() != Role::Leader {
    node.tick()?;
    if let Some(ready) = node.ready() {
        disk = ready.state().clone(); // Replace with an atomic durable save.
        ready.persisted();
    }
}
let batch = node.propose_batch(&[40, 2])?;
let ready = node.ready().unwrap();
disk = ready.state().clone();
ready.persisted();
assert!(node.committed().any(|e| e.id == batch.last));
let total: u64 = node.committed().filter_map(|e| match &e.value {
    Some(Record::Command(value)) => Some(*value),
    _ => None,
}).sum();
assert_eq!(total, 42);
let restarted = Cluster::<u64, u64, 8, 32>::new(
    Settings { seed: 456, ..Settings::default() },
    ClusterState::restore(Id(10), genesis, disk)?,
)?;
assert!(restarted.committed().any(|e| e.id == batch.last));
# Ok::<(), jarl::Error>(())
```

For a cluster, drive every node with `tick()`, `step(&envelope)`, and proposals.
After each operation:

1. Save `ready.write()` atomically and durably, then consume `ready.persisted()`.
   `ready.state()` is available for whole-checkpoint storage. Dropping a token
   leaves that exact write pending.
2. Drain `next_message()`. Encode its borrowed payloads immediately, or call
   `.cloned()` for a bounded owned queue. Actual network delivery may be async;
   dropping a network message is safe because Raft retries.
3. Install any newer durable `snapshot()`, then apply `committed()` in index order.

Pending persistence gates messages and application output. Pending persistence
or an undrained outbox causes `Error::Busy`; borrowed inputs remain available for
retry. `status()` exposes scheduling and capacity pressure. `progress()` exposes
leader replication positions for voters and learners. Diagnostic state can
include unpersisted changes and never establishes a read lease.

## Runtime membership

Use the following sequence on the leader:

1. `set_learners(&ids)` replaces the learner set without changing voters. Start
   each fresh joiner with its unique, never-used identity and the original
   genesis configuration. A joiner remains passive until its log promotes it.
2. Wait for that configuration to commit and for each prospective voter to catch
   up through `state().last().index`. `matched(id)` exposes its acknowledgment.
3. `reconfigure(Membership::new(&voters, &learners)?)` appends a joint configuration.
   New voters must already be caught-up learners. Elections and commitment now
   require separate majorities of the old and new voter sets.
4. Once the joint entry commits, call `finish_reconfiguration()`. Persist and
   replicate the final configuration, and confirm its returned `LogId` is
   durably committed before acknowledging the administrative operation.

A host must resume step 4 on a new leader after interruption. Only one change may
be outstanding. Membership becomes effective on append, before commitment, and
is reconstructed from the snapshot and log on restart. `compact()` attaches the
configuration at the snapshot's exact boundary. A removed leader continues the
transition and steps down when the final configuration commits.

Learners do not campaign or count toward the leader's voting quorum. They can
answer election requests: a candidate may already have their promotion in its
log while they still have an older configuration. Likewise, a stale node must
accept authenticated requests from a legitimate cluster peer it has not yet
learned about. Authenticate cluster namespace and identity in the host; do not
use the receiving node's possibly stale membership as the sole transport ACL.
Jarl reserves one extra response descriptor for such requests.

Pre-vote probes avoid increasing durable terms in isolation. Recent leader
contact suppresses disruptive vote requests. Leaders step down after an election
interval without responses satisfying their current quorum. These mechanisms
improve availability; neither peer progress nor leadership authorizes a lease.

## Sync and async storage

`host::Storage` and `host::persist` adapt synchronous backends.
`host::AsyncStorage` and `host::persist_async` adapt asynchronous backends without
requiring an executor, `Send`, threads, or allocation. Implement the trait for
your backend, or manage `Ready` directly.

The exclusive `Ready` token can be held across `.await`. It prevents another node
operation or acknowledgment while that transaction is being saved. Other nodes
and host tasks can run independently. Dropping the future leaves the write
pending. A backend must prevent canceled background writes from overtaking later
transactions; pause or reopen it after ambiguous failures. Never acknowledge a
failed save. Wrapping blocking I/O in an async function is insufficient: use
native asynchronous I/O or an ordered worker.

Examples, on Unix:

```sh
# Three voters become four; rerunning recovers membership and advances all totals.
cargo run -p jarl --example membership -- /tmp/jarl-membership
cargo run -p jarl --example membership -- /tmp/jarl-membership
# Actual file writes on a bounded worker; the consumer awaits durability.
cargo run -p jarl --example async_storage -- /tmp/jarl-async
cargo run -p jarl --example async_storage -- /tmp/jarl-async
```

The journals demonstrate incremental transactions, namespace/identity binding,
exclusive ownership, corruption detection, and incomplete-tail recovery. They
are example storage formats and do not reclaim disk space. The multi-node
example uses a bounded in-memory transport, not a production network server.

## Application and resource contracts

`committed()` repeats the retained committed suffix. Track the last applied index
and advance it for **every** entry: `Record::Configuration` and `None` barriers
are protocol records; only `Record::Command` changes application state. Rebuild
from `snapshot().value.application` and the committed suffix after recovery.
Snapshots and application transitions must be deterministic.

A successful proposal returns identities, not a commit acknowledgment. Confirm
commitment and application before replying to a client. Retry deduplication
belongs in the replicated application state, including its snapshots. Coordinate
external effects separately if replay must not repeat them. Ordered reads can
be represented as replicated commands. `role()` and `leader()` are hints.

`propose_batch()` admits a nonempty batch atomically or admits nothing. Dynamic
clusters replicate up to `MAX_APPEND_ENTRIES` (16) entries in one message and one
follower storage transaction. Outgoing payloads borrow the retained log. There is
one snapshot per node; snapshots transfer whole and the host owns encoding and
transport size limits.

Application admission leaves three slots for protocol progress. This reserve is
**not** an unconditional liveness guarantee: repeated interrupted elections can
still fill a bounded log with uncommitted entries. Compact an applied committed
prefix proactively. If no prefix is eligible, `grow::<NEW_CAP>()` moves the live
node into a larger log without cloning payloads, restarting, or losing pending
work. The Rust type changes; an embedding host must plan that recovery path or
provision sufficient fixed capacity. Availability requires the relevant voting
majorities, eventual timely communication/persistence, and sufficient storage.

A process replacement must retain the voter's identity and durable state. If
that state is permanently lost, use a new identity, catch it up as a learner,
and reconfigure using the surviving quorum. Permanent quorum loss is outside
ordinary Raft recovery: restore consistent backups or create a new, separately
namespaced cluster under an explicit disaster-recovery procedure. Never reset
existing voter state or run two processes with the same voter identity.

## Verification and performance

```sh
cargo test -p jarl --locked --offline
cargo test -p jarl --release --locked --offline
cargo clippy -p jarl --all-targets --locked --offline -- -D warnings
cargo fmt -p jarl -- --check
python3 jarl/tools/mutations.py
cargo check -p jarl --target wasm32-unknown-unknown --locked --offline
# Use a NEW directory. Real durable writes; in-memory transport.
cargo run -p jarl --release --example benchmark -- /tmp/jarl-benchmark 100
```

[PERFORMANCE.md](PERFORMANCE.md) records the measured local baseline and its limits.
[AUDIT.md](AUDIT.md) records model, exploration, fault-schedule, and host evidence.
CI also checks a bare-metal target with no standard library.

`Node<V, S, N, CAP>` remains available for the fixed-membership API; it shares the
log, storage, and quorum machinery, but retains its original election behavior
and single-entry sending policy. Use `Cluster` for runtime membership, pre-vote,
and bounded replication batching. Version 0.3 adds message variants and a new
membership-bearing application envelope; hosts must version their wire/storage
formats. Existing 0.2 application checkpoints require an explicit migration and
must never be silently reinterpreted.

Protocol reference: [Raft, sections 5–8](https://raft.github.io/raft.pdf).
