# Specification for proving Jarl correctness through Provium

Status: implementation and proof specification, not a completed proof.
Baseline: Jarl 0.3.0 and Provium 0.1.0 at commit `66229c2`.
Owner: Jarl owns the protocol specification and assertions; Provium owns reusable
Rust semantics, translation, checking, and evidence tooling.

This document defines the work required to justify a source-level correctness
claim for both public Jarl engines. Checked milestone evidence is recorded in
[M0.md](M0.md) and [PROGRESS.md](PROGRESS.md); M0 accounts for the claim and
inventory, while M1–M8 remain open. A written obligation is not a discharged
obligation. M0 completion is not a source-level correctness claim. Proposed files, commands, manifest fields, and
theorem names below are design requirements, not claims that those APIs exist.

## 1. Claim and non-negotiable boundaries

The target claim is:

> For every supported Jarl build, every valid initial deployment, every permitted
> sequence of API operations, and every network/crash execution satisfying the
> stated environment contracts, Jarl's Rust execution refines a specified
> replicated-log system and preserves its safety properties. Under separately
> stated progress assumptions, admitted work eventually commits and becomes
> available for application. Provium checks the connection to the original Rust.

This includes `Node<V,S,N,CAP>` and `Cluster<V,S,MAX,CAP>`. The latter includes
learners, pre-vote, quorum checks, batching, and changing membership. A proof for
one engine cannot silently stand in for the other. Feature completeness means
coverage of Jarl's advertised API and protocol behavior, not every optional Raft
extension ever proposed. Client deduplication, leases, ReadIndex, transport,
storage engines, and application execution are not implemented by the core.

The following constraints apply throughout the project:

1. Keep Jarl readable, `no_std`, allocation-free internally, sans-I/O, and free of
   unsafe code. Preserve both synchronous and asynchronous consumer workflows.
2. Put compiler accommodations and proof instrumentation in Provium or Jarl's
   proof directory. Do not rewrite readable Rust solely into a proof DSL.
3. Fix actual protocol bugs in Jarl when a counterexample identifies one; add a
   focused regression and corresponding proof obligation for each fix.
4. Quantify over arbitrary valid capacities and runtime memberships. `MAX` bounds
   simultaneous peer slots; it does not fix the voter set for the cluster lifetime.
   Capacity growth currently changes `CAP`, not `MAX`; do not claim otherwise.
5. Use only crates.io-buildable third-party Rust dependencies. No Git-only proof
   backends, vendored third-party checkouts, or new Rust toolchain installations.
   Support the installed stable toolchain, with explicit supported-version checks.
6. Only Cargo writes Cargo artifacts under `target/`. Provium evidence belongs
   under the consumer's `artifacts/provium/`; no source checkouts go under target.
7. Jarl uses Provium as a dev-dependency. Provium must package, test, and evolve
   independently of Jarl. No Jarl paths or protocol-specific rules in its compiler.

## 2. Baseline and proof levels

The current executable inventory is described in [README.md](README.md), with
additional test evidence in [../AUDIT.md](../AUDIT.md).

| Area | Existing evidence | Missing connection |
| --- | --- | --- |
| Consensus | Source-slice contracts for quorum arithmetic/intersections, minima, guarded commitment prefix, and term checks | Complete callers, reachable-state assumptions, protocol history |
| Persistence | Complete `Ready::persisted` field-effect contracts | Actual storage transaction semantics, output ordering, crash/restart and adapters |
| Election | Complete successful-state projections for `reset_election` | Complete election transitions, proven input invariants, crash-aware uniqueness |
| Membership | `finalized` and `is_joint` contracts for arbitrary-length optional-record arrays | Authorization, log lifecycle, elections/commitment during configuration changes |
| Translation | Restricted frontend, typed IR, generated correspondence with IR, source hashes, axiom checks | Rust-to-IR semantic preservation and complete Jarl language coverage |
| Execution | Native comparisons, bounded exploration, fault schedules, mutation tests | Unbounded inductive and temporal theorems |
| Consumer API | `assert_proofs!("proofs")`, consumer-owned projects, ordinary tests, CI | Complete coverage enforcement, composed root theorems, independently replayable release evidence |

Use distinct completion labels:

- **Component-checked:** the present level; selected generated definitions have contracts.
- **Protocol safety with trusted translation:** complete Rust-derived transitions
  satisfy global safety, but frontend correspondence is still an explicit assumption.
- **Source-level safety:** complete transitions and Rust-to-Lean preservation are
  proved relative to a documented Rust semantics and trusted boundary.
- **Conditional total correctness:** source-level safety plus termination of
  applicable local operations and temporal progress under explicit assumptions.

The final goal requires the last level for the scoped APIs. It does not assert
machine-code correctness independently of rustc, LLVM, the runtime, and hardware.
Any future binary-level claim requires a separate compilation/refinement project.

## 3. Exact subject and coverage inventory

Create a machine-readable Jarl-owned coverage ledger, initially
`jarl/proofs/coverage.json`. Assign stable requirement IDs from this document.
Record each production item, source span/hash, root API, transitive calls, build
configuration, translation status, contract, theorem, dependencies, assumptions,
and evidence path. Status values must distinguish planned, translated,
component-proved, composed, excluded, and blocked with a concrete reason.

Provium must compute the subject closure and reject uncovered reachable items.
A manually maintained list alone cannot establish completeness. Newly added API
methods, message variants, branches, fields, callbacks, or dependencies must
invalidate a complete-coverage claim until classified and checked.

The starting inventory is:

| ID | Production surface | Required coverage |
| --- | --- | --- |
| C01 | `lib.rs`: IDs, terms, entries, snapshots, messages, envelopes, errors, diagnostics | Representations, all variants, equality/payload abstraction, message cloning, documented observations |
| C02 | `state.rs`: construction, restore, get/id_at, push/truncate/install, write/grow, iterators | Durable log representation, delta transactions, bounds, compaction and recovery |
| C03 | `membership.rs`: constructors, iteration, membership queries, learner/joint/final operations, quorum functions | Identity uniqueness, set interpretation, quorum arithmetic and all array cases |
| C04 | `node.rs`: new/build, tick/step, campaign/follow/become_leader, election helpers | Complete fixed and dynamic election control flow |
| C05 | `node.rs`: valid/append/replicated, advance_commit/commit_to, barrier | Complete validation, replication, reply handling and commitment |
| C06 | `node.rs`: propose/propose_many/propose_batch, compact/compact_with, grow | Admission, callbacks, rollback, storage pressure, snapshots, ownership transfer |
| C07 | `node.rs`: send/reply/broadcast/replicate/next_message, available/idle, ready, committed/snapshot | Descriptor materialization, persistence gates, borrowed output and backpressure |
| C08 | `node.rs`: membership_at/refresh_membership, hooks, peer reconciliation | Configuration history, callback resolution, progress/vote slot identity |
| C09 | `cluster.rs`: ClusterState, Settings, Cluster constructors and every wrapper | Dynamic initialization, validation and wrapper refinement |
| C10 | `cluster.rs`: change_available/set_learners/reconfigure/finish_reconfiguration/compact | Entire membership lifecycle and snapshot boundary configuration |
| C11 | `ready.rs`: Write/Ready and `host.rs`: Storage/AsyncStorage adapters | Token ownership, transaction view, success/error/Pending/cancellation/drop |
| C12 | All getters/iterators, derives, closures, trait calls, Drop/rollback guards and core operations reachable above | Observation/frame contracts and exact external-function semantics |

Inventory test-only explorers separately. Example journals and application hosts
are evidence and candidate separately verified adapters, not implicit parts of
the core theorem. If an end-to-end example deployment is claimed verified, its
encoding, filesystem ordering, corruption handling, locks and application logic
must receive their own ledger and proofs.

Record the exact target triple, integer widths, edition, enabled cfg/features,
overflow profile, panic strategy, rustc version, dependency lock and source tree.
Support the current host, installed 32-bit no_std target, and CI bare-metal target
as explicit configurations. A parameterized width proof must still be connected
to every advertised build; one host proof cannot certify arbitrary targets.

## 4. Environment and admissibility contracts

Separate assumptions about external behavior from invariants Jarl must establish.
Never assume election safety, quorum overlap across arbitrary configurations,
leader completeness, or valid generated outputs in order to prove those facts.

| ID | Contract | Required treatment |
| --- | --- | --- |
| A01 | One cluster namespace, consistent genesis, unique lifetime identities, one live owner per identity | Model bootstrap and provisioning. State loss requires a new identity; reusing peer slots does not reuse identity. |
| A02 | Authenticated, uncorrupted protocol messages from non-Byzantine participants in that namespace | Network may lose, delay, reorder, duplicate and replay actually emitted messages. Authentication alone does not prove honest contents. Test malformed messages separately without treating forged successes as admissible Raft messages. |
| A03 | Atomic durable writes of the exact `Write`, ordered per voter | Success means durable; crash during save recovers an allowed whole transaction state. Model failure after durability but before acknowledgment. Torn-write handling is the backend's refinement obligation. |
| A04 | Recovery uses that identity's permitted durable history | Structural `restore` validation is not evidence that an arbitrary checkpoint arose from the protocol. Prove recovery from generated durable states; separately prove structural rejection behavior. |
| A05 | Host acknowledges only successful saves and consumes output according to API rules | Prove what borrowing/tokens enforce. List obligations they cannot enforce, especially truthfulness of storage success. |
| A06 | Payloads and snapshots have stable logical values; Clone preserves those values | Model callbacks, possible side effects, panic and Drop. No blanket assumption that user Clone is pure, terminating or panic-free without an explicit theorem restriction. |
| A07 | Application transitions are deterministic and snapshots represent exactly their declared applied prefix | Core guarantees ordered durable exposure; application correctness, deduplication and external-effect handling require consumer contracts. |
| A08 | Async backend cancellation cannot reorder abandoned writes after later transactions | Model quiescing/reopening on ambiguous completion; the core token alone cannot enforce backend ordering. |
| A09 | Progress has eventual timely scheduling, communication and persistence for requisite voters | Not a safety premise. Define timing/fairness and stable-leadership opportunities precisely in section 10. |
| A10 | Progress has sufficient capacity and counter headroom | Not a safety premise. Failed growth, full logs, term/index exhaustion and permanently missing quorums may stop progress safely. |

Provide at least one concrete executable host satisfying these contracts and a
formal model witness that admissible initial states and progress schedules exist.
Keep deployment obligations visible in public docs and proof reports.

## 5. Semantic model and theorem architecture

Define reusable Rust execution semantics in Provium and Jarl-specific protocol
semantics in Jarl. Handwritten specifications may describe desired behavior;
implementation transitions must come from original Rust, with checked refinement.

The global state must include a finite map of live/failed identities, each node's
volatile state, durable checkpoint, pending transaction and acknowledgment state,
outbox descriptors, materialized network messages, application delivery history,
and effective/committed membership. Add ghost election certificates, historical
log prefixes, configuration lineage and emission provenance as needed. Ghost
state must be erasable and must not constrain execution by assuming the result.

Represent an arbitrary finite population and arbitrary finite histories by
inductive types, not a fixed three-node universe. At each state occupied slots
are bounded by the relevant capacity; quantify over arbitrarily many legal
reconfigurations up to available finite identity/counter space. Model `grow` as a
capacity-changing transition preserving abstract contents and pending work.

Distinguish events for input, local execution, begin-save, durable completion,
acknowledgment, output materialization, network delivery/drop/duplicate, crash,
restart, snapshot/application exposure, actual host application, and async poll
or cancellation. A durable completion is not the same event as acknowledging it.

A crash can occur during an operation. Establish which Rust internal steps are
unobservable and collapse to a crash before/after the operation; model observable
callback effects, publication and storage boundaries explicitly. Do not simply
declare all public methods atomic. On unwind, include rollback and destructors;
on abort, relate recovery to durable state. Catch-and-continue claims need their
own invariant-preservation proof.

The required proof chain, with schematic names, is:

```text
original Rust + exact build inputs
  -- checked source interpretation and lowering --> typed implementation IR
  -- semantic preservation --> Lean implementation transitions
  -- representation relation R --> Jarl abstract protocol transitions
  -- initialization + preservation --> reachable-state invariant Inv
  -- consequences --> global safety
  -- progress-preserving refinement + temporal assumptions --> liveness
```

Required theorem interfaces include:

```text
InitRust(r) implies exists a, InitAbstract(a) and R(r, a)
R(r, a) and RustStep(r, event, r') implies
  exists a', AbstractSteps(a, mapped(event), a') and R(r', a')
InitAbstract(a) implies Inv(a)
Inv(a) and AbstractStep(a, event, a') implies Inv(a')
Reachable(a) implies Safety(a)
AdmissibleInfiniteTrace(trace) and ProgressAssumptions(trace) implies Progress(trace)
```

Include return values, errors, panic outcomes and observable outputs in `R`.
Finite stuttering is allowed for internal execution. Liveness additionally needs
a well-founded progress argument excluding infinite concrete stuttering; a
safety simulation alone is insufficient. Model any simultaneously emitted output
sequence in order. Prove local termination for nonblocking core operations under
terminating callback contracts; async waiting is conditional on the backend.

## 6. Provium implementation work

| ID | Deliverable | Acceptance criterion |
| --- | --- | --- |
| P01 | Cargo-aware subject discovery and build identity | Resolve complete module/call/type closure for the selected API/build; reject ambiguity and uncovered cfg, expansions or dependencies. Stable Rust, registry dependencies only. |
| P02 | Adequate typed IR | Represent structs, enums, generics/const generics, arrays/slices, references, moves, calls, patterns, loops, returns, errors and outcome state without silently dropping behavior. |
| P03 | Complete Jarl syntax support | Inventory and implement actual operations: Option/Result, `?`, matches, iterator chains, closures, hooks/function pointers, array construction/fill/sort, comparisons, conversions and derived implementations. Unsupported constructs fail with source spans. |
| P04 | Memory/ownership semantics | Typed places, disjoint fields, aliasing/reborrows, consumed values, initialized slots, immutable payload abstraction and lifetimes; establish the representation relation currently trusted by leaf stores. |
| P05 | Calls and library contracts | Resolve inherent vs trait methods and concrete callback targets; prove core-operation summaries or interpret them. Every opaque call has an explicit discharged or external contract. No assumed name-based equivalence. |
| P06 | Control flow and arithmetic | Complete body/callee effects, loop invariants and termination, checked/wrapping/saturating operations, bounds, shifts, casts and division. Distinguish debug/release behavior and 32/64-bit usize. |
| P07 | Panic and destruction | Model partial state, unwind rollback guards, Clone/Drop behavior and abort-to-crash. Cover every reachable panic, including assertions and unreachable branches. No successful-state-only root theorem. |
| P08 | Async semantics | Derive `persist_async` behavior from its body, including suspend/resume, pending future ownership, cancellation/destruction and success/error; prove observable refinement to ordered storage events. |
| P09 | Compositional contracts | Preconditions, postconditions, frame conditions, outcomes and ghost histories with caller discharge; link them into root theorems. Detect cyclic assumptions; support legitimate mutual induction explicitly. |
| P10 | Source-to-IR preservation | Formalize the supported Rust semantics and check each translation against it; discharge frontend/refinement assumptions rather than relying on generated IR agreement. See the trust design below. |
| P11 | Complete certificate | Bind original sources, transitive dependencies, compiler/options, frontend/semantics versions, all generated artifacts, obligations, root theorems and transitive axioms. Fresh deterministic rebuild and independent replay must agree. |
| P12 | Coverage and failure behavior | Missing obligations, unsupported changes, changed inputs during verification, stale artifacts, missing Lean, incomplete root dependencies or forbidden axioms fail closed. Publish success atomically only after all gates pass. |
| P13 | Reusable consumer workflow | Preserve `assert_proofs!("proofs")`; add actionable source-linked diagnostics, assumption/coverage reports, selective development checks and a mandatory complete release gate. Package tests run without Jarl. |

### Translation trust design

Use proof-producing translation validation as the preferred route: the Rust tool
emits structured source/build evidence, IR and derivations; Lean checks the
derivations against independently specified rules. An alternative verified
frontend is acceptable if it supplies the same preservation theorem.

The acceptance boundary must be explicit. A checker proving facts about an AST
supplied by the same unverified parser does not by itself prove facts about the
source bytes. Either check parsing/name/type resolution from authenticated source
inputs, or leave those components listed as trusted and use the weaker completion
label. Hashes bind bytes; they do not prove their interpretation. rustc accepting
the source establishes neither translation equivalence nor contract correctness.

Develop semantics construct by construct with progress/preservation or appropriate
execution-refinement lemmas. Prove the generated Lean semantics agrees with those
rules, not just with a second copy of the same unchecked output. Differential
tests and mutations are supporting checks. They cannot replace P10.

The declared residual trusted base may include Lean's kernel and its execution
platform, explicitly allowed logical axioms, the adequacy of the formal Rust
semantics, rustc/LLVM's implementation of Rust, standard-library contracts not
independently refined, and hardware. Keep any remaining frontend trust separate
from this list; do not claim it was removed unless the source connection is checked.
No checker is accepted solely because it is small or produces a certificate.

Continue Lean kernel checking with `--trust=0`, warnings as errors, and transitive
axiom audit. Only `propext`, `Quot.sound` and `Classical.choice` are currently
allowed. Reject `sorry`, custom axioms and native-evaluation trust axioms in root
dependencies. Audit theorem hypotheses as well as axioms: a safety assumption
hidden in a parameter is still an assumption.

## 7. Local representation and API obligations

For each ID, prove initialization, preservation by every writing operation,
observation consistency, and any error/panic behavior. Track dependencies in the
ledger rather than counting helper lemmas as independently complete features.

| ID | Obligation |
| --- | --- |
| R01 | Valid configurations have nonempty voter sets, unique IDs, representable unions, legal timers, appropriate local identity and positive usable log capacity. Invalid constructors fail as documented. |
| R02 | Retained logs form a contiguous bounded suffix after a well-formed snapshot boundary. Indices/terms and commit bounds satisfy the chosen representation invariant. `get`, `id_at`, iterators and `last` agree with it. |
| R03 | Push, truncate, snapshot installation and growth preserve logical history under their preconditions. Derive these preconditions from every caller. Deleted compacted data has a ghost historical interpretation. |
| R04 | Hard-state term and vote changes, dirty flags, earliest changed log position and snapshot flag describe exactly the pending transaction. Multiple mutations and partial batch acceptance combine correctly. |
| R05 | Applying `Write` to the previous durable checkpoint equals saving the intended whole checkpoint, including suffix deletion and snapshot replacement. Repeated/retried saves and acknowledgment loss have defined outcomes. |
| R06 | Effective and committed membership are derived from the correct snapshot/log positions; truncation restores prior configuration. Peer reconciliation preserves progress only by identity and clears reused slots correctly. |
| R07 | All outbox descriptors refer to valid peers/payloads at materialization. Reserved unknown-peer reply capacity is safe. Coalescing/overwriting descriptors preserves safety; needed retransmissions are accounted for in progress proofs. |
| R08 | No message, committed suffix or snapshot is publicly exposed before its required durability. Getters that expose provisional diagnostics are explicitly outside commit/read acknowledgment semantics. |
| R09 | Ready owns the exclusive pending transaction; dropping it does not acknowledge. Sync failure, async Pending/error/cancellation, and save-success-before-crash preserve the appropriate pending/durable relation. |
| R10 | Proposal batches are admitted atomically or rejected without partial admission; clone panic rollback is proved where promised. Follower replication batches may accept a prefix and acknowledge only that prefix. |
| R11 | Every Error variant has a precise postcondition. Do not require all errors to leave all state unchanged: derive actual permitted effects, including timer changes before exhaustion. Busy and malformed-input guarantees match docs. |
| R12 | `grow` preserves role, membership, terms, votes, logs, snapshots, descriptors, pending writes and externally observable continuation without payload clones. Invalid capacity requests have an explicit compile-time/runtime contract. |
| R13 | Core work and storage are bounded by capacities and message size; prove local termination and bounds for loops/helpers. Payload-owned allocation/time is an explicit callback boundary. |
| R14 | Arithmetic overflow never manufactures a term, index, quorum or capacity. Prove checked errors, saturation and intentional jitter wrapping separately. Safety holds even when resources are exhausted. |
| R15 | Sync and async adapters produce the same durable protocol observations for equivalent successful save schedules, modulo waiting. Cancellation permits specified extra failure/recovery traces rather than pretending every run completes. |

## 8. Global safety obligations

Build an inductive strengthening sufficient to prove the following over all
admissible finite histories, including messages surviving sender crashes and
restarts. State election uniqueness historically, not just for currently live
nodes. Relate compacted prefixes to ghost history rather than requiring deleted
entries to remain physically present.

| ID | Required theorem and implementation connection |
| --- | --- |
| S01 | Durable terms never decrease and each identity casts at most one durable vote per term across restarts. Bind granted responses to durable vote evidence and self-votes to campaign persistence. |
| S02 | Election safety: at most one distinct identity becomes leader in a term for a cluster history. Prove both engines, distinct vote counting, active campaign correlation and dynamic configuration lineage. |
| S03 | Leader append-only: while leading in a term, a node never replaces established logical entries. Local compaction/growth changes representation, not history. |
| S04 | Log matching: equal index and term imply equal logical entry and prefix for protocol-generated entries, including snapshot-covered prefixes. Include duplicate append, conflict repair, batches and snapshot install. |
| S05 | Replication acknowledgments carry sound evidence of a durable matching prefix. Derive match-index monotonicity/correlation, stale reply handling, forward hints, Full replies and current-term filtering. |
| S06 | Leader completeness: every later leader contains the previously committed logical prefix, represented by log or snapshot. Include barriers, prior-term entries and configuration transitions. |
| S07 | Commitment soundness: current-term quorum evidence justifies leader commitment; follower commitment is bounded by established matching history. `commit_to` and `refresh_membership` are covered completely. |
| S08 | Committed history is immutable and globally prefix-compatible across all nodes, crashes, snapshots and reconfigurations. Distinguish locally calculated commit from durable/publicly exposed commitment. |
| S09 | State-machine safety: two valid application deliveries at the same index agree; deliveries are ordered and backed by durable committed history. Repeated `committed()` iteration is not exactly-once execution. |
| S10 | Snapshot safety: install/compact/recover preserves the included log identity, historical prefix, application interpretation and membership at exactly the boundary; reject conflicting committed replacements. |
| S11 | Reconfiguration safety: only authorized stable-to-joint-to-final histories occur. Joint elections/commit require both majorities; finalization requires committed joint state. Prove across nonidentical local views and arbitrarily many sequential changes. |
| S12 | Learner and identity safety: learners cannot campaign or count outside the relevant voter set; promotion requires the implemented catch-up evidence. Stale learners may answer authorized requests without violating election safety. Old slot acknowledgments never count for new identities. |
| S13 | Removed leaders and stale nodes cannot establish conflicting histories. Prove final-configuration commitment, step-down, stale unknown-peer requests and delayed old-configuration messages together. |
| S14 | Pre-vote and quorum-check extensions preserve safety. Prospective terms do not become durable votes; replies bind to the campaign; activity evidence is never interpreted as a read lease. |
| S15 | Recovery refines a legal continuation of the durable history, for crashes at every modeled boundary. Unpersisted proposals/votes/commit calculations cannot escape through outputs after recovery. |
| S16 | A conforming client host obtains linearizable completed command operations when it waits for durable commitment/application and implements deterministic application and retry semantics. Prove this composition separately from the core log theorem. |

Do not assume all quorums from all configurations intersect. The dynamic proof
must derive the necessary intersection or history propagation from committed
configuration lineage and election restrictions. Local quorum arithmetic is only
one lemma in that argument. Similarly, membership validation establishes set
shape, not legitimacy of a configuration's place in the protocol history.

Separate proofs may be mutually dependent through a strengthened invariant.
Resolve those dependencies using induction on execution/history or term with
explicit well-founded measures; do not import one desired conclusion as an axiom
to prove another and then reverse the dependency.

## 9. Refinement and feature-completeness obligations

Define the abstract replicated-log interface independently of helper expressions
and implementation flags. Specify command admission, durable commitment,
configuration changes, snapshots, recovery and observations. Establish a trace
refinement from generated code for every C01–C12 entry.

For each public operation, record accepted inputs, permitted rejection, mutations,
return values, output sequence, resource effects, and recovery behavior. Prove
expected enabled behavior as well as preservation: an implementation that always
rejects proposals can satisfy safety vacuously but is not a complete Raft engine.

Prove batching refines ordered single-entry replication with the documented
partial-capacity behavior; dynamic wrappers refine their intended protocol
records; growth and compaction preserve abstract state; fixed and dynamic modes
share only lemmas whose hypotheses actually hold in both.

Prove payload abstraction parametricity: logically equal immutable payloads are
replicated unchanged regardless of representation. For application composition,
give a deterministic transition function and snapshot interpretation relation.
Snapshot contents are an external correctness obligation, not validated by an
index/term match. Exactly-once client effects require separately modeled IDs and
deduplication, including recovery and snapshots. Diagnostic reads have no
linearizability guarantee; ordered reads need the documented replicated-command
host protocol and its proof.

## 10. Conditional liveness specification

Safety must not require timely clocks, fair delivery or successful storage.
Liveness must state more than eventual delivery and must not assume its own
conclusion, such as an eventual correct leader, without a separate election theorem.

Define a time/scheduling model and an admissible suffix in which:

- An appropriate voting quorum remains alive with ordered successful storage.
  Joint configurations need both relevant majorities; a live old majority alone
  is insufficient. Membership churn eventually permits a stable progress interval.
- Retried requests and replies receive sufficiently timely delivery, hosts tick,
  poll saves, drain outboxes, and apply exposed entries according to stated bounds
  or fairness predicates. Relate those bounds to heartbeat/election thresholds.
- Election scheduling eventually affords an eligible, sufficiently up-to-date
  candidate an uncontested opportunity. Derive success from that external timing
  condition. Jarl's deterministic jitter does not justify an independent-random
  timeout assumption or probability-one termination without additional proof.
- Required nodes have log space, or the host eventually compacts an applied prefix
  or supplies successful growth. Repeated failed elections can consume bounded
  capacity; the reserved slots are not an unconditional progress proof.
- The selected operation has sufficient term/index/identity headroom and its
  application callbacks terminate. No u64 implementation supports infinitely many
  increasing log entries/terms without exhaustion. Quantify finite operations or
  traces with the explicit remaining-resource condition.
- The client retries when required; the administrator resumes an interrupted
  `finish_reconfiguration` on a suitable leader. A proposed entry that never commits
  may be overwritten; do not promise that every returned proposal ID will commit.

| ID | Progress obligation |
| --- | --- |
| L01 | Eventual successful election from the specified external scheduling opportunity, including pre-vote and recent-leader suppression. |
| L02 | Leader stability while the quorum/timing conditions continue; quorum checks and descriptor handling do not cause perpetual avoidable disruption. |
| L03 | Replication converges for a reachable follower through conflict repair, batching and snapshot transfer, with a well-founded measure for retries. |
| L04 | A retried command eventually gains durable commitment and becomes available for application under a sufficiently stable leader and resources. |
| L05 | A permitted learner addition/promotion and joint/final transition eventually finishes when both quorums, catch-up resources and administrative scheduling are supplied. |
| L06 | Recovery and sync/async host scheduling do not introduce permanent blocking once their success/fairness premises hold. |
| L07 | Concrete execution preserves abstract progress, including finite internal stuttering, callback termination and modeled cancellation behavior. |

Provide witnesses satisfying the premises, counterexamples when each essential
premise is removed, and a clear list of unavailable guarantees: permanent quorum
loss, infinite adversarial churn/cancellation, arbitrary Byzantine senders,
unbounded counter consumption, and infinitely frequent resource failure.

## 11. Consumer layout and evidence workflow

Keep the existing `jarl/tests/proofs.rs` integration entry point. Extend the
consumer-owned proof tree with modules for specification, invariants, refinement,
recovery, host composition, liveness and a final root theorem. Organize these as
normal Lean modules/projects with explicit dependencies; Provium must support
composition without consumers copying generated implementation definitions.

Each project declares source roots, build configuration, contracts, allowed
environment assumptions, required theorem interfaces and scope. Provider tooling
discovers implementation dependencies and checks them against declarations.
Any new schema must be versioned with migration errors; ordinary proof files
must remain readable and reviewers must see their assumptions.

The final certificate must include:

1. An exact build/source identity and digest of every transitive semantic input.
2. Coverage of every public root and its reachable production closure.
3. The names and full types of checked root theorems, including parameters.
4. Their transitive proof dependencies, external contracts and logical axioms.
5. Translation/refinement status for each source item; no unmarked trusted stubs.
6. A safety/progress/target/host scope summary and all residual trust assumptions.
7. A reproducible verification command, supported installed tool versions and
   source/evidence bundle that a consumer can rebuild without Jarl-specific tooling.

The release check must regenerate evidence from current sources. Cache keys cover
the full dependency graph; stale certificates cannot survive a failed complete
run as current success. Distinguish per-project successes from aggregate success.
Reject concurrent writers to the same output or isolate runs and atomically
publish the complete result. Source changes during checking invalidate that run.
Hash agreement is necessary provenance evidence, never a semantic theorem.

Selective checks are a development convenience. The complete gate must fail if
only selected components ran, if a source API is newly uncovered, or if an expected
root theorem is absent. No production proof tests may silently skip missing Lean.

## 12. Validation, review and release gates

| ID | Gate |
| --- | --- |
| V01 | Existing format, Clippy, rustdoc, unit/integration, release and no_std target checks remain passing. Do not install Rust toolchains to make a local gate pass. |
| V02 | Provium tests every newly supported semantic construct and rejects near-miss unsupported constructs; native differential tests cover boundary values, paths, widths, panic and error outcomes. |
| V03 | Translation negative controls alter source interpretation, omit a late effect, change a branch/callee or forge coverage; the appropriate checker rejects them. |
| V04 | Protocol negative controls cover each S01–S16 family and core resource/host invariants, with expected semantic failure distinguished from parser/compiler failure. Existing 13 native mutants remain covered. |
| V05 | Axiom and hypothesis audits reject admits, opaque safety assumptions and missing composition links. Evaluate precondition satisfiability and witness normal elections, proposals, snapshots and reconfigurations. |
| V06 | Bounded explorers and fault schedules remain independent supporting evidence; add counterexample replay from failed proofs/models. Never convert their finite bounds into an unbounded claim. |
| V07 | Every supported build has checked source coverage and either its own theorem instantiation or a proved parameterization. Unsupported target/cfg changes fail explicitly. |
| V08 | A clean source/evidence rebuild verifies all roots, reproduces provenance, and fails after deliberate stale-input/certificate tampering. Missing tools are errors, never successes. |
| V09 | Provium packages/builds against registry dependencies without Jarl; an independent consumer uses the documented dev-dependency/test workflow. Jarl retains no runtime dependency on Provium or an async executor. |
| V10 | Independent protocol and formal-methods review checks specification adequacy, dynamic configuration arguments, refinement, liveness premises and the trusted boundary. Record findings and resolutions; self-review is not independent review. |

Preserve the discoverable `provium/scripts/{format,lint,test,verify,check}.sh` and
`jarl/scripts/verify.sh` workflows. Add coverage/certificate checks to these or
clearly named new scripts when implemented. CI must run the complete required
proof gate and publish evidence; a passing cargo test alone is insufficient if
it omits any required proof profile or negative control.

The coverage review must explicitly inspect these boundary families. Finite tests
exercise representatives; the associated proofs quantify over all permitted
values and combinations, rather than treating this matrix as exhaustive testing.

| Family | Required cases |
| --- | --- |
| Membership size | Invalid empty voter sets; singleton; even/odd counts; MAX at capacity; old/new overlap and disjoint replacement; union too large; absent/removed local identity |
| Lifetime changes | Repeated changes; interrupted joint/final append, save and commit; different configurations at different nodes; evicted peer slots; newly provisioned identities; exhausted identity space |
| Terms and clocks | Genesis; same/lower/higher terms; maximum term; saturating elapsed time; boundary election settings; equal seeds; delayed/replayed probe and vote replies |
| Log capacity | Empty/minimal/full buffers; protocol reserve exhausted; committed vs uncommitted suffix; batch sizes zero, one, maximum and excessive; growth with dirty state/outbox |
| Log history | Duplicate append; mismatched predecessor; competing uncommitted suffixes; committed conflicts; current/prior-term commitment; maximum index; delayed successes and rejections |
| Snapshot history | Before/at/after local commit and base; matching/conflicting boundary; suffix retention/replacement; snapshot older than latest configuration; snapshot-only recovery |
| Input provenance | Wrong recipient/self-sender; malformed variant fields; unknown legitimate stale-view peer; messages from before crash/removal; stale response to a reused slot |
| Storage boundaries | Crash before/during/after save; success before acknowledgment; ambiguous error; duplicate retry; dropped token; suffix truncation plus snapshot in one write |
| Async boundaries | Never-polled future; Pending; Ready success/error; cancellation at each suspension; abandoned background save; backend quiescence/reopen; equivalent synchronous schedule |
| Application behavior | Nontrivial immutable Clone values; panic during each clone position; Drop/unwind/abort; repeated committed iteration; recovery replay; snapshot/application mismatch as contract violation |
| Execution profiles | Both public engines; debug/release overflow behavior; supported integer widths; no_std targets; supported panic profiles; cfg-derived code differences |
| Progress failures | Partition or permanent quorum loss; repeated elections filling storage; perpetual reconfiguration; message starvation; outbox starvation; exhausted counters; perpetual save failure/cancellation |

Every discovered counterexample gets a minimal replay, an obligation or contract
correction, and a regression check. If the stated theorem is false of Jarl, record
the failed claim and fix the implementation or explicitly revise the advertised
contract. Never silently narrow the admissible histories to discard the failure.

## 13. Dependency-ordered implementation milestones

Each milestone ends with checked artifacts and an updated ledger. No calendar or
completion percentage is justified until the semantic coverage inventory exists.
Proof failures may reveal specification or implementation errors; resolve those
with explicit revisions instead of weakening an invariant without review.

| Milestone | Work | Exit criterion |
| --- | --- | --- |
| M0: Claim and inventory | C01–C12, A01–A10, coverage schema, exact build profiles, abstract event model | Every public root and current limitation accounted for; admissible genesis/host witnesses; reviewed theorem statements |
| M1: Semantic foundation | P01–P07, start P10, R01–R05 | Complete state/membership/storage primitives translated; outcome/ownership semantics; source-preservation checks for those constructs |
| M2: First global proof | Complete fixed-node election transitions, R08/R09, S01/S02 with crash/restart | Historical election uniqueness from initialization over arbitrary executions, linked to full Rust bodies; any remaining translation trust labeled |
| M3: Fixed-engine safety | C05–C07, S03–S10/S15, relevant representation and API obligations | Fixed `Node` global safety including batching received, snapshots, full logs, errors and recovery; no sliced caller gaps |
| M4: Dynamic-engine safety | C08–C10, R06, S11–S14, arbitrary membership histories | `Cluster` global safety with learners, joint/final transitions, stale views, removal, slot reuse and snapshots |
| M5: Host and complete API refinement | P08/P09, all R obligations, S16, C11/C12, section 9 | Sync/async composition, cancellation, all observable API/error/panic outcomes and wrapper/capacity refinement |
| M6: Source correspondence closure | Finish P10–P12 for all M1–M5 constructs | No unchecked source-to-IR or borrow/layout step hidden in the source-level claim; complete safety root and provenance |
| M7: Conditional progress | L01–L07, temporal semantics and progress-preserving refinement | Election, replication, command and reconfiguration progress under noncircular, satisfiable timing/resource/host premises |
| M8: Release proof package | P13, V01–V10, final assumption register and docs | Independently reproducible, reviewed source-level safety and conditional total-correctness certificates for both engines |

M6 work starts in M1 and proceeds with each construct; it must not be postponed
until an incompatible trusted frontend has translated the whole engine. M4
requires M3's invariant architecture but must extend it for configuration lineage.
M7 can develop after M0, but closes only after complete safety and host refinement.
M8 depends on every preceding exit criterion, not merely a count of proved lemmas.

For each work item, maintain: requirement ID, owner component, prerequisites,
specific source roots, precise statement, proposed proof method, assumptions,
counterexample/negative control, artifact path, and completion evidence. If proof
engineering forces additional requirements, assign IDs and update this plan.

## 14. Definition of done and permitted public claim

The full scoped proof is complete only when all of the following hold:

- Every C, P, R, S, L and V requirement is discharged or explicitly classified
  as an external contract with a checked use-site; implementation obligations
  cannot be reclassified as host assumptions merely to close the ledger.
- A kernel-checked composed root establishes safety for every admissible finite
  execution of each supported engine/build, including arbitrary legal capacities,
  changing membership, message schedules, crashes, snapshots and recovery.
- The source-interpretation and translation-preservation chain reaches original
  Rust; the report clearly names any residual semantic/compiler/platform trust.
- Conditional progress roots cover the specified operations and their premises
  have constructive witnesses and no assumed protocol conclusions.
- All public operations and advertised guarantees have contracts, including
  permitted failures, termination conditions and observable output ordering.
- Consumer-host and application obligations are documented with verified
  composition interfaces. No claim implies verification of an arbitrary backend.
- Clean replay, all required CI profiles, negative controls, packaging and
  independent review pass with no unresolved correctness findings.

The resulting public statement should name the exact version, build profiles,
verified properties, host/resource/timing premises and remaining trusted base.
Until then, report the strongest completed level from section 2 and link the open
ledger. Neither this document, a green test suite, nor a set of component Lean
theorems constitutes full Raft correctness.

## 15. Protocol reference

The reference baseline is the extended
[Raft paper](https://raft.github.io/raft.pdf), especially Figure 3 and sections
5–8: election and log safety, joint consensus, snapshots and client interaction.
This project must prove Jarl's actual extensions and API behavior against its
own explicit specification; citing the reference algorithm's arguments does not
establish implementation refinement.
