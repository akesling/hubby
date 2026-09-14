# Jarl's correctness boundary

Jarl 0.3 adds allocation-free runtime membership to the existing Raft engine.
This document records design reasoning and executable evidence. It is not an
independent review, formal refinement proof, or production certification.

## Invariants

| Property | Enforcement | Evidence |
| --- | --- | --- |
| Terms do not decrease; at most one durable vote per term. | Term adoption and vote updates precede published responses. Pre-vote never adopts the prospective term. | Independent follower model, restart regressions, isolated-follower test, election exploration. |
| Joint elections and commits require both voting majorities. | Distinct-identity membership with separate election counts and majority replication positions; latest configuration is effective before commitment. | Old-only and new-only partition tests, dynamic exploration, quorum mutation controls. |
| A new voter is caught up before promotion. | Leaders require a committed prior configuration, established current-term leadership, learner status, and acknowledgment through their last entry. | Learner admission tests and interrupted-promotion recovery. |
| A learner cannot start an election. | Campaign eligibility requires local voter membership. Learners may grant votes to support a candidate whose log already promotes them. | Passive-learner test and restart after a durable but unreplicated joint record. |
| Membership changes serialize. | A stable committed configuration is required to start a change; the joint record must commit before finalization. | Four persistence-boundary restart cases and premature-finalization mutation. |
| Removed leaders finish safely. | The final configuration uses the new quorum immediately; a removed leader steps down upon its commitment. | Disjoint replacement, leader-removal recovery, seeded schedules. |
| Commitment of earlier-term entries requires a current-term entry. | A current-term majority position advances commitment; leaders append barriers. | Independent model, prior-term regression, commit exploration and mutation. |
| Log repair cannot overwrite a committed entry. | Predecessor validation and committed-suffix checks before replacement. | Follower models, malformed messages, full-buffer and conflicting-snapshot tests. |
| A batch commits only the prefix it establishes. | Validate the whole message before mutation; apply contiguous entries and cap follower commitment at each matched position. A partial full-buffer acceptance acknowledges only its accepted prefix. | 660 independent batch cases, malformed-batch tests, delta reconstruction. |
| Reordered replies do not undo acknowledged replication. | Monotonic match positions and rejection correlation to the current retry position. | Delayed-response regressions and fault schedules. |
| No protocol/application output precedes its durable transaction. | Exclusive `Ready`; dirty state gates outgoing messages, committed entries, and snapshots. | Compile-fail test, async Pending/cancellation/error tests, crash exploration and mutation. |
| Incremental storage equals a whole checkpoint. | Suffix transactions retain the earliest changed index, including batched repairs. | Every simulated save reconstructs through public `State::restore`; real journals are recovered after interruption. |
| Snapshots include the membership at their exact boundary. | `compact` looks up membership through the included index; install/restart reconstruct effective membership from snapshot plus suffix. | Snapshot behind an uncommitted joint record, stale-joiner recovery, torn joint journal frame and mutation. |
| Peer slots can serve new lifetime identities. | Runtime slot reconciliation preserves progress by identity; evicted slots reset votes and replication positions. | Replacement with identity 99 in a three-slot cluster. |
| Async operation has no runtime dependency. | Consumer-defined future types; borrowed tokens; core-only host traits. | Matching sync/async histories, genuinely pending futures, cancellation, and a real file-worker example. |
| Resource bounds are explicit. | `MAX` simultaneous peers, `CAP` log entries, 16 entries per replication batch, bounded descriptors, one snapshot. | Payload clone counters, layout bound, capacity growth, admission, and rollback after a panicking application clone. |

## Configuration and reply reasoning

The latest membership record in the log is effective even when uncommitted.
Stable-to-joint transitions require separate old and new majorities; final
configuration records are admitted only after the joint record is committed.
Snapshots retain the configuration at their included position. Truncating an
uncommitted configuration restores the preceding configuration automatically.

A receiving node may have older membership than a legitimate candidate or
leader. Runtime nodes therefore accept authenticated requests from identities
not yet in their local configuration and reserve one extra reply descriptor.
The host must authenticate the cluster namespace and sender, not merely consult
a stale membership list. Responses only contribute through locally tracked peer
identities and the candidate/leader's effective quorum. A learner may answer a
vote request, but cannot campaign or contribute to a quorum that excludes it.

Pre-vote replies carry both the responder's actual term and the prospective
campaign term. Probes do not advance durable terms; replies contribute only to
that pending campaign. Recent leader contact suppresses disruptive vote requests.
Leaders periodically require responses from their effective quorum. Replayed
responses can affect this availability heuristic, so it is not a lease mechanism.

Replication replies identify a matched index, not a transport request ID. A
leader's log is append-only within its term, so an older successful response
still proves that prefix. Rejections affect only the current retry position and
never retreat behind an acknowledged prefix. Forward hints from compacted peers
establish no match until another request succeeds. Partial batch acceptance
reports its matched prefix and preserves one atomic suffix transaction.

## Executable bounds

- Independent quorum oracle: all 49 pairs of nonempty three-peer voter sets,
  27 replication-position combinations, and four acknowledgment thresholds.
  Election counts and commitment positions must both match literal majorities.
- Independent vector follower model: **70,770** append/vote transitions, plus
  **660** batch transitions including partial capacity and committed conflicts.
  It does not reuse the implementation's log helpers or quorum predicate.
- Fixed-cluster schedule explorer: depth six, three voters, four log slots, terms
  through two; **39,313 election states** and **3,020 commit/crash states**.
- Reconfiguration explorer: depth five, four peers, eight log slots, terms through
  three, starting at an unpersisted joint or final record; **5,350 joint states**
  and **26,091 final states**. Actions include delivery, loss, duplication, saves,
  crashes, timeouts, finalization, and compaction. Oracles check election safety,
  leader completeness, committed-history agreement, and persistence gating.
- Fixed-cluster simulator: 64 seeds across three- and five-voter clusters, 2,000
  events each, plus healthy recovery intervals.
- Runtime-membership simulator: 64 seeds, six peers, 32 log slots, 2,000 events per
  seed, followed by healthy recovery. Seeds begin at each of the four joint/final
  persistence boundaries. The schedules admit 64 joint transitions and 20 final
  records before final recovery. They include asymmetric partitions, queue loss,
  duplication/reordering, delayed saves, restart, compaction, and proposals.
  Oracles compare committed records and snapshot application state, track one
  leader per term, check retained leader completeness, and require recovery.
- File hosts: incremental journals; complete repeated cluster restart; namespace
  and voter binding; exclusive ownership; corruption; truncation at every byte
  of a final transaction, including a joint membership record.
- Async host: sync and genuinely pending async saves produce identical durable
  histories; failure/cancellation leave the exact transaction pending; a bounded
  worker performs real filesystem writes away from the executor thread.
- Mutation controls must compile and then fail a selected test. CI checks 13 deliberate faults across quorum,
  term, commitment, snapshot, configuration, batching, and publication faults.

These are bounded checks with explicit starting conditions. They are not an
exhaustive exploration of arbitrary membership histories or a proof of liveness.

## Host obligations and remaining limits

Persist a unique cluster namespace, genesis, and local identity before first use.
Never reset a voter after losing its state or run duplicate instances of it.
Atomic saves must complete before acknowledgment. Canceled async storage must
preserve transaction order; pause/reopen after ambiguous failures. The `Ready`
token enforces ordering, not the truth of an external durability claim.

The host drives every node's local monotonic ticks, drains output, resumes joint
finalization after leader changes, tracks application progress, handles retry
sessions, and constructs deterministic snapshots. Hosts should coalesce delayed
timer wakeups sensibly; replaying an unbounded backlog of ticks while starving
network input can induce unnecessary elections. A pending durable transaction
blocks that node's input; other nodes/tasks remain runnable.

Three reserved log slots reduce capacity pressure but cannot guarantee progress
through arbitrarily many interrupted elections. Proactively compact committed
application state; provision growth or a sufficient fixed bound. Permanent quorum
loss cannot be repaired by ordinary reconfiguration. Replaced voters need their
original durable state or a new identity introduced through a surviving quorum.

The core has no transport authentication implementation, standard wire format,
chunked snapshots, concurrent persistence pipeline, client deduplication engine,
or exactly-once external effects. The example journals do not reclaim disk space.
The maximum simultaneous peer count is a compile-time resource bound, while the
active membership and identities vary at runtime. The fixed `Node` API retains
its older election and single-entry sending policy; runtime features use `Cluster`.

Before a production-readiness claim: obtain an independent protocol/API review,
exercise real bounded network integrations with slow or failed storage, measure
representative payloads and snapshot transfers, and collect sustained deployment
and recovery evidence. [PERFORMANCE.md](PERFORMANCE.md) deliberately reports only
the local benchmark that was actually run.

Reference: [Raft, Figure 2 and sections 5–8](https://raft.github.io/raft.pdf).
