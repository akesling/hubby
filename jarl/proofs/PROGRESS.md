# Correctness proof implementation progress

This records implemented evidence against [CORRECTNESS_PLAN.md](CORRECTNESS_PLAN.md).
It is not a full-correctness certificate. M0 claim/inventory is complete under
the exit-criterion audit in `M0.md`; M1–M8 remain open.

Execution rule: a checked commit is a checkpoint, not the stopping condition.
Continue with the next open source-linked obligation under the existing toolchain,
dependency, no_std/sans-I/O and approval constraints. Only the full specification's
verified completion can close this work; a green component suite cannot.

M0 has been audited against `CORRECTNESS_PLAN.md`; its reviewed inputs and
reproducible gate are recorded in `M0.md` and `m0-review.json`.

Protocol frontier: discharge append/truncation/installation preconditions in
complete protocol callers and durable histories, including snapshot provenance
and hard-state transitions. Branch contracts for installation are checked below. Recovery, growth and truncation preserve the
logical log representation under the contracts below. Buffer-shape induction alone
is not a source-level Raft correctness proof.

## Source accounting (M0, C01–C12, P12)

- `coverage.json` reviews 184 syntactic items in Jarl's production module tree.
- Provium independently regenerates file/item hashes and unresolved call spellings.
  Jarl's ordinary tests reject stale sources or missing classifications.
- New fields, variants, methods and late effects invalidate the review. Exact
  `cfg(test)` modules are recorded but not traversed; other cfg is conservatively
  inventoried. Calls, trait resolution, macro expansion and Cargo closure remain open.
- Component-evidence labels do not constitute verification. The complete gate
  cannot pass by editing labels and currently rejects every full-proof claim.
- `builds.json` selects the host profile for offline Cargo accounting. An ordinary
  integration test records normal/build dependencies, manifest/lock hashes,
  features, target declarations and rustc/cfg identity, and ensures proof tools
  remain outside Jarl's dependency-free runtime graph. Expanded source,
  effective compiler commands and ambient Cargo configuration remain open.

## Complete input-gating queries (M1/M5, C07, R08/R11)

- Provium now translates complete shared Result queries with bool, Option and
  optional-array reads, source-resolved unit error variants, and inlined shared
  helper calls. It rejects hidden effects, unresolved constructors, recursion,
  shadowed types and excessive expansion.
- Jarl's `Node::available` and `Node::idle` have exact-result, blocking and
  clean-admission contracts over arbitrary outbox lengths.
- A composed contract links generated `Ready::persisted` effects to the generated
  input gate: acknowledgment clears dirty state but preserves output backpressure.
- These checks run for the host and installed wasm32 target. Method manifests now
  record verbose rustc identity, target cfg and exact direct type-check arguments.
- Three independent source mutations remove the gate conditions individually;
  each must fail in Lean's invariant proof after successful Rust translation.
- An independent provider fixture compares the IR to native Rust across every
  dirty/reply/optional-array combination at capacities zero through four, and has
  its own kernel-checked contract and negative control.

## Capacity predicates (M1, C02/R02)

- Shared scalar methods now retain original impl const parameters and builtin
  field types, including target-sized usize. Their complete bodies retain scalar
  faults and local computation.
- `State::full` is translated directly from Jarl and proved equal to the capacity
  comparison. Given the separate `len ≤ CAP` invariant, non-full implies space.
- The contract passes for 64-bit and installed wasm32 targets. Changing the
  original equality to inequality must fail the Lean contract, not the parser.
- Shape preservation through translated restore/mutation is composed below;
  physical and protocol reachability remain open.

## Fresh-state initialization (M1, C02/R02)

- The complete original `State::new` constructor now lowers with its derived
  hard-state Default and empty Option-array callback. Hidden/default initializer
  effects and namespace shadowing are rejected.
- Lean checks initial term/vote/commit, absent snapshot, zero length, arbitrary
  empty-array capacity, and the initial length bound. This supplies the fresh-state
  case for the buffer-history composition below; metadata/log reachability is separate.
- Provider native comparisons cover const-parameter substitution and initial
  fields. Independent provider and Jarl source mutations change the initial length
  and must fail in Lean. Jarl additionally checks the installed 32-bit target.

## Bounded append preservation (M1, C02/R02/R03)

- Provium translates the complete indexed append idiom and its source-resolved
  const-capacity guard, retaining original field paths, payload type, increment,
  error variant and helper source. Hidden effects and substitutions it cannot
  resolve are rejected. No production Jarl source was changed.
- Its outcome semantics retain bounds and overflow faults and partial stores.
  Payload destruction is a suspension with a normal-return continuation, not an
  assumption that custom Drop is pure, infallible or safe to unwind.
- Jarl's `proofs/storage` proves exact append success without drops under the
  occupied-prefix invariant, shape/length preservation, earlier-payload
  preservation, and the rejected-input destruction boundary when full.
- An explicit constructor/store view preserves slot presence. Induction over
  successful generated append transitions proves shape for arbitrary capacity
  and arbitrarily long finite append histories from fresh initialization.
- Provider comparisons cover native slot contents, lengths, drop ordering and
  late overflow states. Independent provider and original Jarl source mutations
  alter the increment and guard and must fail the Lean proof. The Jarl contract
  also type-checks for the installed wasm32 target.
- The append-only theorem excludes other operations; their shape composition is
  recorded below. Log-ID ordering, destructor unwinding and source/layout/borrow
  refinement remain open, so this is not global Raft reachability.

## Capacity growth and changing-capacity histories (M1, C02/R02/R03)

- Provium translates the complete consuming record-growth body: static capacity
  assertion, original generic substitution, transfer/take of every metadata
  field, and the entire indexed Option::take callback. Custom receiver Drop,
  hidden effects, and unresolved substitutions are rejected.
- Slot-move semantics retain the source traversal order, cleared old slots,
  a bounds-failure boundary, and disposal suspensions for residual old payloads.
  Partial-record ownership during failed construction, panic hooks and destructor
  unwinding remain outside the model; no full Rust outcome refinement is claimed.
- Jarl's storage proof establishes exact payload/metadata/length preservation for
  arbitrary nondecreasing capacities. The occupied-prefix invariant ensures the
  old slots are all empty, so valid growth needs no destructor callback.
- Induction now covers fresh initialization, successful appends and repeated
  growth with capacity as a changing history index. The later composition adds
  restore, truncation and installation. Protocol/durable-history reachability
  still needs separate invariants.
- Provider native comparisons include copied and moved owned metadata, payload
  identity, and old-tail disposal order. Both provider and Jarl negative controls
  mutate the static relation and loop boundary and must fail the Lean contract.
  Jarl's storage project also runs against installed wasm32.

## Snapshot boundary and source-place bindings (M1, C02/R03)

- Provium translates the entire shared Option record selector, including its
  eager builtin-derived Default. Source-resolved record types and both accessed
  field paths remain in the generated program; unsupported effects and generic
  name shadowing are rejected.
- Jarl's `State::base` now proves exact zero index/term without a snapshot and
  exact preservation of the snapshot's `last` record when present. The contract
  also runs against installed wasm32. Caller composition and log-ID consistency remain open.
- Provider native checks exercise both same-typed projected records; changing
  which source field is selected must fail the independent Lean contract.
- Append/growth IR now also retain source array/length paths and capacity names.
  Explicit Jarl obligations bind the abstract buffer to those original places;
  provider source-renaming mutations cannot pass merely because the abstract
  arithmetic is unchanged. Physical layout and borrow refinement remain open.

## Checked log lookup (M1, C02/R03)

- Provium retains both checked subtractions, original bias, source-resolved base
  selector/field, usize::try_from, bounds-checked array access and Option borrow
  from the complete `State::get` body. Potentially overriding standard traits
  and hidden effects are rejected rather than treated as pure builtins.
- Jarl proves the exact borrowed source place for each present slot, None at or
  before the snapshot boundary, and all post-boundary outcomes including target
  conversion failure, bounds rejection and empty slots. Logical target width is
  explicit; the project also type-checks original Rust for installed wasm32.
- Native provider tests compare actual pointer locations across sparse arrays,
  present/absent snapshots and integer boundaries. Provider mutations alter bias,
  base field and array path; original Jarl mutations alter bias and base field.
- Actual reference lifetimes/layout and entry LogId consistency remain open.
  The complete mutating methods and their shape contracts are recorded below.

## Boundary/entry record composition (M1, C02/R03)

- Provium translates the complete `State::id_at` branch, reusing the complete
  original `base` and `get` helpers. It retains the boundary comparison, guard
  field, copied entry-record field, helper sources and all lookup outcomes.
- Jarl proves the exact whole base record at the boundary, the exact whole entry
  id at a successful borrowed location, and None on an off-boundary lookup miss.
  Genesis and snapshots follow the same original branch; no synthetic rule is
  substituted for either case.
- Provider native comparisons cover both same-typed entry projections. Branch,
  projection and helper-bias mutations fail its kernel contract. Jarl additionally
  mutates its original equality branch and checks the full project on wasm32.
- These are record-selection contracts, not a proof that every entry's id.index
  matches its array position. That requires log-content invariants through all
  storage constructors/mutators and their protocol callers.

## Borrowed iteration and final-record selection (M1, C02/R02/R03)

- Provium translates the full checked prefix slice, builtin iter/flatten chain,
  and double-ended borrowed Item type. Its sequence is an iterator denotation,
  not an eager allocation attributed to Rust. Canonical core/std trait imports
  are accepted; shadowed traits and hidden adapter effects are rejected.
- `State::last` includes the complete iterator and eager base helper, with the
  selected iterator end and copied entry-record path kept in the IR.
- Jarl proves exact prefix-location enumeration, invalid-length rejection,
  fallback to the base on an empty prefix, and the final present retained slot's
  exact id, independently of holes earlier in that prefix.
- Native tests alternate next/next_back, compare actual pointer locations and
  check custom entry Drop counts, including bounds panic. Provider controls
  mutate the slice boundary, iterator end, record projection and array name;
  Jarl mutates its original slice and iterator-end expressions on wasm32.
- Panic hooks, iterator lifetime/layout refinement and log-content invariants
  remain open. The buffer-shape composition below covers the mutating methods.

## Outstanding dependency frontier

The source inventory is not a resolved call closure or Cargo build proof. Query
and assignment stores still require Rust type/layout/borrow refinement. The
gate-view relation is explicit proof specification, not a verified Rust memory
model. No current contract proves all gate callers correct or that a host's save
was durable. Global election safety, log matching, leader completeness,
configuration-history safety, recovery composition and conditional liveness
remain open. Existing component proofs and bounded tests do not close them.

The next implementation work is P01–P07/P10: resolve complete source/type/call
dependencies and extend outcome semantics through state, election and persistence
transitions. M2 requires an inductive historical election theorem over those
complete generated transitions, including durable votes and restart.

## Complete suffix truncation (partial R/S evidence)

- The original `State::truncate` loop is translated with complete last/iterator/base
  helpers, ordered short-circuit reads, decrement-before-clear and opaque payload
  destructor suspensions. No payload Clone is added to Jarl.
- Kernel proofs cover successful storage shape, every retained payload, descending
  last-slot drop with the exact continuation, empty return, and sufficient internal
  fuel for every input state. Interpreter exhaustion cannot masquerade as success.
- Storage histories now admit normally completed truncations alongside append and
  arbitrary nondecreasing capacity growth; the later composition adds restore and
  installation. This is still not the protocol reachable-state invariant.
- Native checks cover capacities 0/1/3, all occupancy masks and invalid lengths,
  missing/present snapshot bases, comparison boundaries and destructor order.
  Independent and original-Jarl mutations exercise comparison and helper drift.
- Record views preserve opaque payload identity but do not prove physical Rust
  layout/borrow correspondence. Destructor panic/unwinding, consumer side effects,
  log-ID ordering and the protocol's committed-prefix callers remain open.

## Complete snapshot installation (partial R/S evidence)

- The complete original `State::install` body now translates, including its full
  record-at/lookup/base helper chain, derived equality over every u64 record field,
  checked subtraction, target-word cast, rotation and both clearing loops.
- Kernel obligations prove capacity preservation, nonincreasing retained length,
  nondecreasing commit and replacement with the exact owned input snapshot. Given
  the original lookup/equality decision, arbitrary matching prefixes retain their
  exact suffix; mismatches clear the entire retained prefix. Source-place contracts
  bind slots, length, snapshot and commit fields.
- Entry drops follow source order; old snapshot destruction follows the commit
  update and precedes assignment. Faults retain the owned incoming snapshot at the
  pre-unwind boundary. Following drop continuations requires normal return.
- Native tests cover all occupancy masks at capacities 0/1/3, invalid lengths,
  snapshot bases, term mismatches, boundary indices, commit extrema, ownership and
  destructor order. Original-source mutations and installed wasm32 verification
  are required by the Jarl gate.
- General storage-shape/history composition, protocol authorization, log ordering,
  committed-prefix preservation and physical view/unwinding refinement remain open.

## Installation storage-history composition (partial R02/R03 evidence)

- Successful `State::install` now preserves the full `Shape` predicate for every
  shape-valid input buffer, across all lookup/equality decisions and every capacity.
  The proof composes rotation and clearing lemmas without assuming a matching or
  mismatching outcome. Normal destructor return is explicit in `resumeInstallation`.
- Storage-history induction now includes fresh initialization, append, arbitrary
  nondecreasing growth, truncation and installation. Each installation also retains
  its capacity and nondecreasing commit postconditions.
- These are buffer histories, not complete persistent/protocol histories: metadata
  reachability and source memory refinement remain open. The later composition
  includes restore. Log-ID ordering, committed-prefix preservation and network
  safety are not consequences of the shape invariant alone.

## Complete restoration and buffer-history closure (partial R02/R03 evidence)

- Provium translates the complete original `State::restore`, its constructor,
  append, last-record, iterator and base helpers. Guards preserve short-circuit
  order, checked addition and original scalar field paths. Final `last()` remains
  a lazy guard read, rather than an eager read inserted before the condition.
- IntoIterator and next are external interactions with arbitrary response values.
  Source, iterator, entry and snapshot destruction are separate conditional
  continuations. Declaration order controls state-field destruction. No Clone is
  added to Jarl's payloads, and no finite/infallible input list is assumed.
- Successful recovery preserves Shape and the exact supplied hard state/snapshot.
  Kernel proofs establish sufficient internal fuel on every iterator-response
  branch and the final validation guard. Source-place contracts bind all fields.
- Buffer histories now include fresh initialization, restoration, append, arbitrary
  nondecreasing growth, truncation and installation. These histories deliberately
  permit arbitrary metadata; protocol/durable-history admissibility is still open.
- The kernel reproduces 48 native result/cleanup traces for an independent Rust
  consumer, including invalid checkpoints, bad ordering/terms, full buffers,
  commit bounds and u64 exhaustion. Mutations change validation or declaration
  cleanup order and must invalidate those original-source contracts.
- General log-ID/term ordering, physical field-view
  and ownership refinement, callback/unwind behavior and protocol reachability
  remain open. No full-correctness milestone or complete certificate is closed.

## Recovery commit bounds (partial R02/R03 evidence)

- Successful original-source restoration implies snapshot boundary ≤ commit ≤
  last log index. The proof decodes actual short-circuit guard evaluation and
  typed u64 reads, retaining the complete original last/iterator/base helpers.
- Removing either bound check from Jarl must fail its own Lean contracts on the
  installed 32-bit target. These bounds do not prove durable provenance or Raft
  committed-prefix safety.

## Recovery log ordering and scalar validity (partial R02/R03 evidence)

- Successful recovery has a nonzero snapshot index/term when present, a snapshot
  term no greater than the hard term, and no vote in term zero.
- An induction through the complete translated recovery loop establishes an
  OrderedEntries chain for every returned payload. Each index is the checked
  successor of its predecessor; terms are positive, nondecreasing and bounded
  by the hard term. Arbitrary iterator responses are validated inside the proof.
- Exact-index corollaries bind each live slot to base.index + position + 1 and
  the complete last() result to base.index + len. This is no longer merely a
  conditional local guard statement or an occupied-prefix invariant.
- The original-source suite rejects altered checked addition and missing initial,
  term-order and upper-term guards. Both 32-bit and host proof projects pass.
- Persistence provenance, mutator/caller preservation, global consensus and
  Rust-to-IR semantic preservation remain open; full certification still rejects.

## Logical representation across growth and truncation (partial R02/R03)

- LogRep connects occupied slots to an OrderedEntries chain with the actual
  metadata/base views. Successful recovery establishes it.
- Arbitrary nondecreasing capacity growth preserves LogRep and exact length.
  Successful truncation preserves LogRep by retaining an exact ordered prefix.
- These contracts retain term and index order, not merely slot presence. They
  do not authorize truncating committed entries; that requires caller conditions
  and a separate committed-prefix contract.

## Append and truncation commitment boundaries (partial R02/R03 evidence)

- Append preserves the ordered log when its caller supplies a checked successor
  LogId with positive, nondecreasing term bounded by the hard term. Original push
  remains unchanged; the proof records its caller obligation explicitly.
- Truncation has an exact normal-resumption result of
  min(old_len, boundary - (base_index + 1)). Valid logs and a u64 boundary cannot
  produce an internal traversal, bounds, input or fuel fault when all destructors
  return normally. Every retained payload is unchanged.
- When commit lies in the original log and commit < boundary, truncation preserves
  all committed entries and leaves the commit index in range. Append preserves
  committed entries and their range as well.
- Actual protocol caller authorization and persistence remain to be proved; these
  local contracts do not establish global Raft committed-prefix safety.

## Snapshot installation log branches (partial R02/R03 evidence)

- The matching branch uses actual generated record lookup and Rust derived
  equality on index/term, rather than assuming whole abstract record identity.
  The proof splits the original ordered chain at the looked-up boundary and
  reestablishes the retained chain from the incoming snapshot LogId.
- Exact source execution preserves every retained payload at its shifted offset,
  preserves LogRep and keeps commit between the new base and retained last index
  when the old commit was in range.
- A mismatching snapshot yields an empty LogRep with commit equal to its index
  when the snapshot covers the old commit. This is a caller obligation, not an
  assumption that the opaque snapshot represents correct application state.
- Branch selection, snapshot provenance/validity and caller authorization still
  need composition with the complete protocol and persistence implementation.

## Message term dispatch (partial C02/R04 evidence)

- Provium lowers complete exhaustive borrowed enum matches, retaining every
  variant and primitive field projection. Unsupported guards, effects, field
  types, attributes and overlapping/incomplete alternatives are rejected.
- Jarl owns the Message::term contracts for all eight variants and exact source
  field coverage. Using PreVoted campaign as durable term must fail on 32-bit.
- An independent generic enum fixture has 18 native results checked directly by
  Lean plus a universal field-read contract. This does not prove physical enum
  layout or the complete Node::valid / Node::step dispatch yet.

## Enum normalization validation (partial P10 evidence)

- Generated enum certificates retain source arm groups and the flattened table
  separately. Lean proves first-match selection is preserved by flattening,
  including missing tags and malformed primitive views.
- The generated correspondence theorem now uses that normalization proof; an
  injected table-only field corruption must fail it. This is one verified IR
  transformation, not a proof of source-byte parsing or Rust memory refinement.

## Next complete-body target

Translate Node::valid with the now-complete Message::term helper, then use its
postconditions in Node::append and Node::step. Preserve the early PreVoted
campaign check, eager derived LogId default, valid_id closure capture, optional
entry validation, checked successor arithmetic, batch occupied-prefix scan and
its inferred integer counter type, snapshot index check, and nested rejection
pattern. Do not replace the complete match/loop with slices or assumed predicates.
The storage contracts above expose the exact caller obligations this must feed.

## Complete validation body (partial C04–C08 evidence)

- Provium now lowers the complete original Node::valid without modifying Jarl.
  The generic backend retains scoped local bindings, immutable closure captures,
  early returns, short-circuit expressions, nested enum/Option patterns and
  borrowed array iteration. The original complete Message::term is included.
- Primitive u64 arithmetic and the inferred i32 batch counter are distinct.
  Derived record equality evaluates both operands once, then compares declared
  primitive fields. Unsupported calls, ownership operations and shadowed
  primitives/default constructors fail closed.
- Jarl owns 39 obligations: universal zero-term rejection for all seven ordinary
  variants; zero/one campaign cases for every durable term; append payload
  independence; concrete checks for each branch, holes, full 16-entry batches,
  predecessor/entry term errors, snapshot boundaries and successor overflow.
- Three source mutations must fail against the 32-bit Rust build. A separate
  provider fixture compares 42 native results with Lean kernel computation and
  rejects a removed hole check. These finite checks are not universal proofs.
- Structural borrowed views, frontend preservation and interpreter fuel adequacy
  remain open. The generated correspondence theorem for this backend is only
  an interpreter-definition identity, not an independently checked compiler pass.

## Current proof frontier

The complete validation body is available. Next establish a reusable symbolic
execution / loop rule for the pure expression machine, prove fuel adequacy and
well-formed-view preservation, and derive general validation postconditions
(especially every batch entry's successor, term and occupied-prefix properties).
Feed these into the complete Node::append and Node::step translations; retain
snapshot/caller provenance obligations from the storage contracts. No M0–M8
milestone or whole-Raft correctness claim is closed by these component checks.

The provider now also supplies five kernel-audited error/loop rules, including
`pure_fold_history`, which tracks the scanned prefix for arbitrary array
lengths. Applying that rule to the generated batch body remains the next step.
Validation: provider format/lint/test/kernel gates pass; all 19 Jarl proof tests
pass (the coverage status spelling was corrected and that check rerun); all four
runtime exploration tests pass. Jarl runtime source is unchanged.

## General validation postconditions (partial C04–C08 evidence)

- The message-validation project now has 56 obligations. General theorems
  characterize every non-batch branch for all bounded scalar inputs: campaign
  positivity independent of durable term, Vote/PreVote log validity, heartbeat
  predecessor validity, snapshot index/term validity and replication replies.
- The accepted-append theorem establishes the exact successor index and a
  positive entry term bounded below by its predecessor and above by the message
  term, for arbitrary unread payloads. These are premises for the storage
  preservation contracts; caller/state-term composition is still required.
- Source-linked batch-body lemmas cover arbitrary iterator lengths and
  environments. Complete-function theorems reject all-empty arrays of every
  length and leading holes followed by any entry and any remaining suffix.
- Provium's kernel-checked symbolic step rule leaves loops as proof boundaries.
  The source body is still compiled in full; helper extraction identities are
  checked by the kernel, not asserted as equivalence axioms.
- The complete batch theorem relates the actual generated loop to a logical
  scan for arbitrary typed slot lists shorter than the i32 counter bound. Its
  accepted-batch corollary establishes nonemptiness, an occupied prefix,
  consecutive indices, and positive, nondecreasing terms bounded by the message
  term. The scan simulation proves the counter cannot overflow under that bound.
  The declarative ordered-slots property is derived from the scan, not assumed.
- The declarative ordered-slot contract is necessary and sufficient for batch
  acceptance under the typed bounds and valid header. The unified totality and
  no-fault theorems cover all canonical validation views at fuel 256, including
  invalid protocol values. These views are not a Rust heap/borrow relation.
- Five 32-bit mutations check campaign, snapshot, hole and successor guards plus
  the batch counter increment. Provium regression checks also preserve lexical
  closure captures and reject accessed opaque generic fields rather than resolve
  them to same-named nominal records.
- Complete validation-to-append/step composition remains next. The frontend, Rust
  memory/borrows, whole-program transition system, durability and safety/liveness
  milestones remain open.


## Validation/storage composition (partial P09 evidence)

- Provium method projects accept ordered, consumer-owned proof modules. All
  module sources are hashed, checked for changes, and included in transitive
  root axiom audits. Every verification uses a fresh Lean import directory;
  stale artifacts cannot satisfy an omitted library import. Generic regressions
  cover dependency order, reserved/duplicate names, output/input separation,
  stale imports and forbidden axioms hidden in library dependencies.
- Jarl's replication-contract project reuses the complete validation and storage
  proof files. Their generated namespace is now consistently `Jarl`; no source
  methods or proof logic were rewritten for reuse.
- `validation_supplies_successor` discharges the storage successor/term predicate
  from accepted append validation and explicit view/advanced-term premises.
  `validated_append_preserves_log` composes it with generated `State::push`,
  preserving the log representation and every existing slot. The root is audited
  against both generated methods, so neither component can be omitted silently.
- The complete Node append/step bodies must still establish representation,
  actual-predecessor, term and space premises, plus clone/drop, truncation,
  membership and commitment behavior. No whole-program milestone is complete.

Validation: all provider format/lint/test/kernel gates pass, including library
freshness and transitive-axiom regressions. All 20 Jarl proof tests pass, including
the new composed contract on 32-bit; the final host composition also passes with
the fresh-build checker. Coverage, formatting and Clippy pass. Jarl production
Rust and runtime dependencies remain unchanged.


## Replacement storage and predecessor discharge (partial P09/R02/R03/R05)

- The storage project now has 44 obligations. New full-operation theorems prove
  that truncation retains either the actual predecessor entry record or the
  compacted base record. The proof uses the generated traversal and mutation,
  exact retained length, and preservation of earlier slots; it does not assume
  the desired post-truncation lookup.
- The replication project now selects eight original methods and audits 16
  obligations. It includes the complete generated `State::id_at` and proves that
  a successful lookup identifies a predecessor in the old occupied prefix or
  at the snapshot boundary. Composing this with truncation preserves the entire
  returned record, including its term.
- The exact post-truncation capacity theorem proves that space is equivalent to
  passing the scalar full-log admission condition, for cuts above the base.
  The replacement contract derives space instead of assuming it, including
  replacement in a full log and arbitrary capacity/word-size parameters.
- `matched_replacement_preserves_log` composes lookup, truncation and push using
  only pre-replacement conditions. Normal destruction continuations are explicit;
  the result preserves the ordered log, committed prefix and commit bound and
  gives the exact resulting length. Validation's earlier theorem supplies its
  successor/term condition once the input field relation is established.
- Node::append and Node::step still need complete translation and caller
  discharge: generated record equality, advanced term, guard selection, Clone
  and exceptional Drop, membership refresh, dirty markers and commit updates.
  These scalar guard premises are not yet proofs that the complete Node body
  checks them. Global safety/liveness and Rust refinement remain open.

Validation: the complete host proof suite passes. The expanded composed contract
passes on 32-bit and rejects changed lookup offsets and truncation inclusivity;
the storage 32-bit proof/mutation suite also passes with all 44 obligations.
Formatting, Clippy and diff checks pass. Jarl production Rust, runtime dependency
graph, toolchains and Provium implementation are unchanged in this checkpoint.

## General expression support for the append frontier (partial M1)

- Provium now lowers builtin `u64` minimum/maximum, checked subtraction and
  saturating arithmetic in complete supported pure functions. Its generic
  arithmetic contracts establish exact results and saturation bounds for all
  bounded operands; a translated source fixture also has an all-input addition
  theorem and 162 native Rust comparisons, including overflow boundaries.
- Optional records with derived primitive-field equality now lower through
  source field declarations. Both operands execute once in order, including
  absent-left cases. Custom equality and unresolved ordering remain rejected.
  These capabilities and their regression fixtures live in Provium; no Raft
  definitions were added to the provider.
- These are compiler prerequisites for the comparisons and arithmetic in the
  original Node::append. Its complete body is still outside the translated
  subset. Mutation/call composition, Clone/Drop, membership and commitment,
  source refinement, and global safety/liveness remain open. No full-correctness
  milestone is closed by this checkpoint, and Jarl production Rust is unchanged.

Resource correction: overlapping symbolic optional-record experiments exhausted
host memory. Those runs were stopped and the expensive experiment was removed
from the verification gate; that attempt established no universal claim. At
that checkpoint the optional-record evidence was the 50-case native comparison
and changed-operand rejection. Provium now defaults to a configurable 2 GiB Lean
memory limit, one Lean worker thread, and a per-process execution lock. Both
projects' proof scripts run tests serially.
Do not run separate proof gates concurrently: their memory budgets are separate.

The authorized working budget is 16 GB total. Current verification uses
`PROVIUM_LEAN_MEMORY_MB=16384`, as explicitly requested, with one Lean job at a
time and no overlapping proof gates. This is Lean's built-in allocation limit,
not an operating-system limit on total resident memory.

Validation: Provium's full format/lint/test/kernel gate and all 20 Jarl proof
tests passed with serial execution and an 8 GiB limit before the working budget
was raised to 16 GiB. The additional resource regression
verifies a small program successfully, reruns it with a 1 MiB budget, and checks
that failure removes its previous success certificate. The State library also
checks under the 2 GiB default. No Jarl runtime code or dependencies changed.

Symbolic optional-record follow-up: Provium now provides an opaque evaluator
packaged with a kernel-checked equality to the existing pure interpreter. Its
explicit step equations avoid the repeated interpreter expansion that exhausted
memory in the earlier attempt. This support is general and lives in Provium.
The source-generated comparison regression proves equality for every pair of
present two-u64 records with bounded fields, both mixed Some/None cases, and
None/None. A changed Rust operand must reject the proof and remove the previous
certificate. These claims concern the generated pure semantics; they do not
establish compiler correctness or Rust memory refinement. Jarl's complete
append/step translation and global Raft safety/liveness remain open.

Validation of this follow-up: all six validator kernel tests passed (four in the
initial run and the three affected record tests after correcting proof lint and
an audit reference). The seven new generic rules passed the axiom audit. Runs
used the requested 16 GiB limit, serially. Format, Clippy, documentation, and
ordinary Rust tests also passed. The unchanged Jarl proof projects were not
rerun for this additive Provium proof-library change.


## M0 specification and accounting foundation

M0 completion is tracked in `M0.md` with a requirement-by-requirement audit. Coverage
schema 2 accounts for the same 184 source items with source ranges, known public
roots, shared build/assumption scope, explicit unresolved limits and references
to declared component obligations. These are review associations, not resolved
Rust call edges or promoted proof claims.

`specification/Model.lean` supplies eighteen kernel-checked specification obligations:
admissible genesis for either engine, exact owner enumeration, nonvacuous
initialization, successful/pending saves, crash after durability, cancellation
and retry, acknowledgment's durability premise, crash preservation, initial owner
uniqueness, network emission provenance, and bounded external service scheduling. Its
population/capacity/timer parameters are not fixed to the concrete witness.
Fixed capacity 1 remains in scope; dynamic initialization requires capacity 4.
The generic Provium specification project explicitly reports no source
correspondence. Production Jarl Rust is unchanged.

`build-matrix.json` declares eight host/32-bit/bare-metal debug/release and
panic profiles; reports capture the installed rustc identity, target cfg,
requested flags, Cargo metadata/lock and edition. No target is installed. This
is requested-build accounting, not a captured effective Cargo invocation or
proof that the CI bare-metal library is locally installed.

`jarl/scripts/verify-m0.sh` checks source/build accounting, model witnesses and
the existing fixed/dynamic/sync/async executable host witnesses, serially with
the authorized 16 GiB Lean limit. M0 closes claim/inventory accounting and
specification/host witness existence. Effective compiler invocation and expanded
call closure are P01 work in M1, not established by requested-build accounting.
Later milestones and full protocol correctness remain open.

## M1 actual compiler capture (partial P01)

The active goal is M1 followed by M2; neither is complete. `M1_M2.md` records the
original exit criteria and current gaps. Provium now captures real Cargo/rustc
invocations, including argument boundaries, compiler working directories and
observed executable/version identity, together with original root source
snapshots. Actual root compilation must be present; version/capability probes
alone cannot count. Failed builds, changed source, and unsupported configuration
cannot leave a successful capture report. A provider build-script mutation checks
source-change rejection, independently of Jarl.

Jarl's actual host and installed wasm32 release builds were captured without new
toolchains, dependencies or runtime changes. The ordinary Jarl proof test checks
that host build capture binds to its current source inventory. These are build
identity facts only; source preservation, resolved closure, primitive ownership
and exceptional semantics, and the M2 global election induction remain open.

## Initialized scalar slots (partial P04/P10 foundation)

Provium's non-dropping scalar assignment backend now emits a method footprint,
a kernel-checked `ProgramTyped` theorem, and an audited
`*_initialized_refinement` theorem. The latter connects the generated method to
an interpreter over typed, possibly uninitialized slots. A live Rust `None`
(`some .absent`) is distinct from moved-out storage (`none`). Reads reject
uninitialized/undeclared slots, assignments check the layout and can reinitialize
storage, and conditions preserve short-circuit evaluation. The generic refinement
covers sequences, both branches, and inlined calls in this backend. Move
invalidation, validity preservation, and disjoint-slot frame lemmas are checked
in Provium's shared semantics.

This closes neither P04 nor P10. The footprint is a scalar access footprint, not
an established Rust object layout. The theorem requires a related initialized
input heap; source place resolution, reference identity, alias exclusion,
reborrows, lifetimes, consumed receiver destruction, and the mapping from Rust
execution remain open. Other method backends do not acquire an initialized-slot
refinement from this change. Jarl production code is unchanged.

Validation: all 12 Provium method tests (including normally ignored Lean tests),
formatting, Clippy, and rustdoc passed. Rechecking the original
`proofs/persistence/project.json` produced the new audited
`JarlMethods.ready_Ready_persisted_initialized_refinement` plus the existing
correspondence and three persistence obligations. Evidence is in
`artifacts/provium/m1-initialized-persistence/`; the certificate retains
`whole_program_proved=false`. Lean ran sequentially with a 16384 MiB limit.

## Complete shared storage view (partial P02/P03/R05)

Provium now lowers the complete original `State::write` body and its `base`
helper. The reusable shared-view backend retains the `Option::map_or` closure,
two saturating subtractions, checked target-width conversion, fallback/clamp,
metadata copy, conditional optional borrow, original truncation argument, and
half-open borrowed slice. Source-local additions or altered field expressions
are rejected. A shared slice denotes locations in the original array; it does
not allocate or copy the payloads. Invalid slice bounds remain an explicit
fault. Scalar representation errors are separated from bounds faults.

`proofs/storage-view` states the Jarl-specific returned-field contracts,
metadata-only empty suffix, and exact replacement suffix. The offset-normalizing
lemma is quantified over target word width and valid `usize` lengths; an
out-of-range conversion uses the source's fallback rather than truncating the
integer. Provider tests compare actual compiled Rust on boundary cases and
compare complete returned borrowed locations, including the optional snapshot
and bounds panic. Jarl's ordinary consumer test lowers its original method and
checks the field-role mapping.

The remaining R05 work is not discharged: connect these borrowed places to the
logical entry sequence, translate `Write::entries`, prove applying the delta to
the prior durable checkpoint yields the intended checkpoint, and establish
caller dirty/truncation/snapshot coherence, retries and lost acknowledgments.
Rust-to-IR preservation, physical reference/layout/lifetime refinement and
panic-hook/abort behavior remain open. M1 and M2 remain incomplete.

Validation: all six shared-view tests passed, including Lean and native Rust;
the output-field rename mutation rejects the old theorem and removes stale
success. The provider's ordinary regression suite, formatting, Clippy and rustdoc
passed. Jarl's new correspondence and all three view obligations passed for the
host and installed wasm32 target. The source-coverage and M0 review-binding tests
passed after reviewing the single coverage-entry change and refreshing its hash;
M0's claim/scope and requirement set were unchanged. Lean ran sequentially with
a 16384 MiB limit. No production Jarl source or dependency changed.

## Borrowed entry iteration and storage suffix composition (partial R05)

`Write::entries` now lowers from its complete original body through Provium's
whole-slice iterator support. The generic iterator semantics also accept whole
arrays, retaining the existing checked-prefix variant. Empty slots and arbitrary
slice lengths are preserved; the sequence denotes lazy borrowed locations,
not a Rust allocation. Generic Lean lemmas rebase slice-local coordinates to
their originating array and prove that loading the resulting valid locations
returns exactly the original occupied payload sequence. Invalid locations fail
instead of silently disappearing.

`proofs/storage-view` now checks both original bodies, their correspondences,
and seven Jarl-owned obligations. The composed theorems connect the result of
`State::write` to the actual `Write::entries` iterator and loaded suffix. Appending
that suffix to the correct retained prefix reconstructs the active logical log.
The retained-prefix premise is explicit: callers must still prove that the
specified snapshot discard and truncation leave exactly this prefix. This is
not yet whole durable-checkpoint equivalence. Snapshot and hard-state coherence,
dirty-index histories, retries/lost acknowledgments, source-to-IR preservation,
and physical borrowing/layout/lifetime refinement remain open. M1/M2 remain open.

Validation: all six iterator tests passed, including kernel checks, source
mutations, borrowed-address comparisons, mixed-end consumption of whole arrays
and slices, and non-Copy payload drop counters. Provider ordinary regressions,
formatting, Clippy and rustdoc passed. Jarl's seven storage-view obligations
passed for host and installed wasm32 builds; all twelve existing log-boundary
obligations also passed. The ordinary source-lowering/coverage tests and M0
review-binding test passed. The reviewed coverage changes classify the new
iterator evidence under existing R05 without changing the correctness goal.
Lean ran sequentially with a 16384 MiB limit. Production Jarl code is unchanged.

## Source-linked checkpoint application and retry (partial R04/R05)

`storage-view/Delta.lean` specifies Jarl's required atomic host transaction:
replace a supplied snapshot and discard through its boundary, truncate the
requested suffix, append the returned entries, then replace hard state. It is a
consumer-owned host contract, not a proof of an arbitrary storage adapter.
Provium hashes, rebuilds and audits this proof module with the generated methods.

`StorageView.source_checkpoint` now connects the complete original `State::write`
and `Write::entries` bodies to that contract. The copied hard state, named
borrowed snapshot and loaded payload suffix produce the intended checkpoint.
It does not assume checkpoint equality: premises classify an old-log split into
discarded/retained/discarded segments by their indices and describe snapshot
tracking. Materialization rejects missing snapshot referents or wrong field/path
mappings. The snapshot parameter supplies the logical value at the borrowed
source field; physical heap/reference interpretation is still a refinement gap.

`source_retry_some` derives that returned suffix entries are removed by the next
identical truncation from the positional log invariant and the generated offset.
`source_retry_none` derives an empty suffix from the original absent-index branch.
Both prove idempotence of repeating the same atomic host transaction, including
save-success-before-acknowledgment retry. A concrete generated-method witness
exercises snapshot discard, prefix retention, suffix replacement and hard-state
replacement together. It is not a reachability proof from engine initialization.

Still open: derive and preserve the old-log segment classifications, snapshot
tracking and positional log relation through every writing caller, including
multiple mutations and panic/rollback paths. Source-to-IR preservation, physical
borrowing/layout/lifetime refinement, actual host-adapter refinement and the
complete crash/acknowledgment execution relation also remain open. R05 and M1/M2
are not marked complete.

Validation: both source bodies and all twelve storage-view obligations passed
for the host and installed wasm32 target. Seven deliberate Rust/host-contract
mutations were rejected and stale success invalidated. Concrete checkpoint,
retained-segment, invalid-reference and non-idempotent-untruncated-append witnesses
were kernel-checked. Clippy across Jarl targets, formatting, source coverage and
M0 review binding passed. Only the reviewed coverage metadata hash changed in
M0's input binding; its scope is unchanged. Lean ran sequentially with a 16384 MiB
limit. Production Rust and the reusable Provium implementation are unchanged.

## M1: membership projection and finalization composition

Provium now translates complete pure optional-record
`iter().flatten().filter(...).map(...)` methods. The reusable IR retains the
predicate and copied field path, with ordered lazy sequence semantics, output
origin and length bounds. It accepts concrete Copy fields without requiring the
borrowed slot record itself to be Copy. Arbitrary callbacks, cloning, extra body
effects, trait shadows and unresolved generic Copy bounds are rejected.

Jarl owns nine new obligations for its original `voters`, `old_voters` and
`learners` bodies: exact ordered output, selected-record origin, and composition
with `finalized`. Finalization preserves the voter and learner sequences exactly
and leaves no old voters, for arbitrary slot counts and holes. No production
Jarl Rust was changed.

Validation: the membership project checked five complete methods and 15
obligations on the host and installed wasm32 target. All ordinary provider tests,
six iterator regressions and three projection tests passed; projection native
comparisons cover 4096 slot/flag patterns and track payload Drop. Provider
predicate/field mutations and six Jarl membership mutations invalidate their
contracts and stale certificates. Clippy, rustdoc, format and coverage/review
binding checks passed. Lean runs were serialized with a 16384 MiB ceiling.

This advances P02/P03 and C03 in CORRECTNESS_PLAN.md. The coverage ledger records
component evidence only. Membership construction, identity validation, lifecycle,
quorum helpers and reachable callers remain open, as do P04/P10 ownership and
Rust semantic preservation. M1 and M2 remain incomplete.

## M1: membership identity queries

Provium translates complete optional-record `any` bodies with a typed equality
against a value argument and optional boolean flag predicate. The reusable
contract accepts builtin scalars and Copy records deriving structural PartialEq
on builtin scalar fields. Custom equality, mismatched types, generic equality
bounds, shadowed iterator methods and additional predicate effects are rejected.
The Lean query retains equality before flag evaluation and is connected to
membership in its corresponding projection sequence.

Jarl's original `contains` and `is_voter` are now translated. Three new obligations
establish exact identity presence, equivalence between `is_voter` and the union
of current/old voter sequences, and participation of every voter. These results
allow repeated identities and arbitrary capacities; they do not assume or prove
constructor identity uniqueness. Jarl production Rust remains unchanged.

The project checked seven complete methods and 18 obligations on host and wasm32.
Provider tests cover rejected equality variants, kernel rejection of changed
fields/flags and 12,288 native query comparisons over repeated keys and holes.
All ordinary provider tests, iterator/projection kernel regressions, Clippy,
rustdoc and coverage/review checks passed. Rust value equality, source lowering
preservation and ownership/layout refinement remain explicit open obligations.
This advances C03 and P02/P03/P05 component coverage; M1/M2 remain open.

The Jarl native comparison and all eight source mutation checks also passed,
including overly restrictive voter flags and identity presence limited to voters.
Each rejected mutation invalidates the stale proof certificate.

## M1: membership insertion and identity uniqueness

Provium lowers the complete existing-key-first optional-record insertion used by
`Membership::include`: key search, empty-slot fallback, eager unit error, indexed
get_or_insert, all initializers and u8-tag flag dispatch. Copy records and
non-dropping unit error variants exclude hidden eager destruction effects.
Receiver captures in record closures are rejected instead of being confused with
the closure's record parameter.

Jarl owns nine new source-linked obligations: capacity, selected-index bounds and
effect, exact full error and unchanged failure state, other-slot preservation,
selected identity, and preservation of identity uniqueness. The uniqueness proof
covers both existing and new identities and does not assume that capacity is
available. The source-derived search establishes that a selected empty slot is
used only when the identity was absent throughout the original array.

The membership project checked eight complete methods and 27 obligations on host
and installed wasm32. Provider ordinary tests, Clippy/rustdoc, 629,760 native
insertion cases over capacities 0–3 and all 256 tags, and iterator/projection/upsert
kernel regressions passed. Changed flag assignments, initial flags and error
variants invalidate the provider proofs. Coverage/review and formatting checks
passed. Lean runs were serialized with a 16384 MiB ceiling.

The Jarl native comparison and all ten original-source membership mutations also
passed, including changed insertion flag assignments and initial old-voter flags.
Each rejected mutation removes the stale certificate.

The constructor loops and their duplicate/learner-overlap/capacity rejection
contracts remain open. So do Rust search/index/equality/ownership/layout refinement
and source semantic preservation. This advances C03/P02/P03/P05 and R01 component
evidence under CORRECTNESS_PLAN.md; M1 and M2 remain incomplete.

## M1: configuration constructor loops and stable forwarding

Provium now translates the complete checked slice-batch construction used by
`Membership::restore`, including its original pass order, enumerated-prefix
duplicate checks, tag-dependent exclusion, early errors and complete `include`
callee. Generic induction lemmas preserve state invariants and derive necessary
input conditions from successful execution. `Membership::new` retains its exact
forwarding call and borrowed empty old-voter slice; the full constructor and
insertion bodies remain in its lowering evidence.

Jarl owns 13 new obligations. Successful constructors preserve capacity and
establish identity uniqueness from empty slots. Success requires nonempty target
voters, distinct identities within each supplied set, and target learners disjoint
from target voters. The stable constructor inherits these results through its
source-derived delegation equality. Single-voter and rejection witnesses check
concrete outcomes without claiming those witnesses prove the general contracts.

The membership project checked ten complete methods and 40 obligations on host
and installed wasm32. Provider ordinary tests and all 19 iterator, projection,
insertion and batch regressions passed, including kernel mutation rejection.
Native comparison covers 256,000 constructor cases across capacities 0, 1, 3 and
5, plus 6,400 stable-forwarding comparisons and explicit early-error ordering.
Provider Clippy/rustdoc, Jarl Clippy, formatting and coverage/review checks passed.
Lean runs remain serialized with a 16384 MiB ceiling.

The Jarl native comparison and all 13 original-source membership mutations passed,
including changed constructor guards, exclusion tags and stable-forwarding inputs.
Rejected source changes invalidate their stale certificates.

At this stage, exact output-set correspondence and proof that every valid
configuration whose union fits capacity is accepted remained open (discharged
as component contracts below). Membership transformations/quorum helpers,
reachable callers, and Rust source, ownership, index and equality refinement
remain open. This is C03/P02/P03/P05/R01 component progress under
CORRECTNESS_PLAN.md; M1 and M2 remain incomplete.

## M1: exact constructor sets and capacity acceptance

The membership project now has 65 checked obligations over ten complete generated
method bodies, on the host and installed wasm32 target. The 25 additional
obligations establish exact voter, old-voter and learner sets, the exact identity
union, and sufficient as well as necessary constructor acceptance. Acceptance
holds iff voters are nonempty, each input list has distinct identities, target
learners are disjoint from target voters, and the number of distinct identities
across all inputs is at most capacity. All other inputs return Config. Successful
stable construction has no old voters and is not joint; successful restoration
has a positive voter count bounded by capacity and stores exactly the number of
distinct input identities. The count specification permits overlap between old
and new configurations and between old voters and target learners.

Provium supplies reusable list-update observations, batch observation and
acceptance inductions, and error-code preservation. Jarl supplies flag/set
interpretation, unique-identity capacity arguments and constructor contracts.
The distinct-key list is a Jarl specification, with checked membership and
uniqueness lemmas; it does not replace the generated constructor implementation.
Jarl production Rust is unchanged.

This discharges constructor output-set and acceptance component work under
C03/P02/P03/P05/R01. It does not close R01 or M1: remaining membership
transformations and quorum helpers, reachable callers, and Rust source,
ownership, indexing and equality refinement remain open. M2's full election
transitions and global crash-aware historical uniqueness are still unproved.

Validation: the host and wasm32 project checks passed with the axiom audit;
Provium's four batch tests passed including kernel negative controls and native
constructor comparisons; Jarl's native array comparisons and all 13 original
membership mutations passed against the expanded project. Coverage/review and
the discoverable format check passed. Lean checks used one process at a time
with a 16384 MiB ceiling. A previously unformatted provider batch fixture was
formatted as part of the format gate.

## M1: peer array projection

Provium translates Copy array mapping composed with Option mapping, retaining
empty slots and exact positions. The frontend checks the complete expression,
source/output capacities, concrete Copy record and projected value types, closure
bindings, and standard-operation resolution. Unsupported effects, captures and
unresolved generic output types are rejected. This shares field/type checking
with lazy record projections while using a separate semantics that retains holes.

Jarl's original `Membership::peers` now has five obligations: capacity, every slot's
identity, exact identity membership, and composition with successful restore/new.
These are C03/P02/P03/P05/R01 component contracts; source ownership/layout
refinement, peer reconciliation and stale-response identity binding remain open.
Jarl production Rust is unchanged. Remaining M1 membership work includes
`with_learners`, `joint`, quorum helpers and reachable caller obligations; M1's
semantic preservation/ownership requirements and M2's global election proof are
not closed by this projection.

Validation: the membership project checked 11 complete methods and 70 obligations
on host and installed wasm32. All nine provider projection tests passed,
including kernel field-mutation rejection and native slot/source preservation
across capacities 0, 1, 5 and 8. The additional generic-output rejection case
passed. The full ordinary provider suite, provider Clippy/rustdoc, Jarl Clippy,
format checks and coverage/review check passed. Jarl's expanded native comparison
and all 13 original-source membership mutations passed. Lean checks remained
serialized with a 16384 MiB ceiling.

## M1: complete learner replacement

Provium now translates two-pass optional-record rebuilds. It retains the original
source projection, exclusion query and insertion helper bodies, both loops,
initialization, prefix validation, insertion tags, error propagation and return.
The first loop merges duplicate projected identities without adding validation;
the second tests the original receiver and rejects duplicate input identities.
Reusable Lean inductions establish preservation, exact observations, necessary
and sufficient acceptance, and possible error codes. This is reusable provider
support; Jarl production Rust is unchanged.

Jarl's `with_learners` adds 14 obligations, bringing the membership project to
12 complete methods and 84 obligations. Successful replacement preserves the
source voter set, replaces learners exactly, establishes unique identities,
preserves capacity, and produces no old voters or joint state. Acceptance holds
exactly when learners are distinct, none votes in either source voter set, and
the distinct union of retained voters and requested learners fits capacity.
Otherwise the result is Config. The identity union and validation conditions are
derived from complete source-generated execution, not assumed as helper results.

The private method has no nonempty/stable-source guard. Those properties and
configuration authorization remain caller obligations, including composition
with `Cluster::change_available`/`set_learners` and the configuration log history.
`joint`, quorum helpers, reachable callers and Rust source/ownership/index/equality
refinement remain open under C03/P02/P03/P05/R01. M1 and M2 remain incomplete.

Validation: host and installed wasm32 checks passed for all 84 obligations with
axiom auditing. The three independent provider rebuild tests passed, including
kernel source mutations and native source-preservation/ordered-result cases at
capacities 0, 1 and 3. Original-Jarl learner-replacement native comparisons passed
at the same capacities. All 16 original-source membership mutations failed their
Lean contracts and invalidated stale certificates. Provider ordinary tests,
provider and Jarl Clippy, provider rustdoc, formatting, and coverage/review checks
passed. Lean runs were serialized with a 16384 MiB ceiling.

## M1: complete joint-configuration construction

Provium now translates guarded by-value Copy-array merges, retaining both input
queries, the source projection, insertion body, loop and constant error mapper.
The implementation semantics maps errors at each insertion; a checked generic
correspondence relates this to the existing pass semantics for composition.
Both guards precede insertion, including when capacity is exhausted.

Jarl's original `Membership::joint` adds 16 obligations. The membership project
now covers 13 complete methods and 100 obligations. Successful construction
preserves target voters and learners, makes source voters exactly the old voter
set, preserves target capacity, and preserves target identity uniqueness when
it holds initially. The output identity union is exact. For unique targets,
acceptance requires both inputs to be non-joint and the distinct union of stored
target identities and source voters to fit target capacity. Either joint input
returns Reconfiguring; otherwise exceeding that capacity returns Full. The result
is joint exactly when the source voter set is nonempty. No nonempty-input guard
is invented for this private method.

This advances C03/P02/P03/P05/R01 structural component coverage. Valid/nonempty
input membership, authorization, committed configuration lineage and reachable
caller discharge remain open, as do the quorum helpers and Rust source,
ownership, equality and layout refinement. These contracts do not establish
cross-configuration safety. M1 and M2 remain incomplete.

Validation: host and installed wasm32 checked all 100 obligations with axiom
auditing. The three independent provider merge tests passed, including kernel
guard/tag/error-map mutations and native union/error-priority cases. Original
Jarl joint construction matched independent native results at capacities 0, 1
and 2. All 18 original-source membership mutations failed Lean contracts and
invalidated stale certificates. Provider ordinary tests, provider/Jarl Clippy,
provider rustdoc, formatting and coverage/review checks passed. Lean checks
remained serialized with a 16384 MiB ceiling.


## M1: quorum callback and destruction foundation

The next untranslated membership primitives, `quorum` and `quorum_index`, accept
FnMut callbacks. A model that memoizes answers by identity or ignores ownership
would miss actual behavior. Native tests of the original `quorum` body confirm
that identities shared between configurations are called again, later answers
may differ, the old pass is skipped after a failed first majority, and stable
membership runs only the first pass. The owned callback drops before return.
Callback panic unwinds through that drop; a drop panic can prevent normal return.

Provium now has a reusable predicate-fold interaction protocol with explicit
callback handles, updated handles in replies, ordered call events and owned
callback-drop events. It distinguishes normal values, unwind and abort, including
abort on a second panic during cleanup. Kernel-checked examples cover those
branches, and general induction bounds internal response steps by the two pass
lengths plus drop and return. Completed responses are a premise; actual callback
termination, source-level unwind behavior and Rust ownership are not inferred.
An insufficient observation budget returns no result instead of fabricating one.
The divisor is positive by construction.

This is P04/P07 semantic groundwork, not a source-linked Jarl quorum theorem.
The frontend must still derive the complete original closure, iterator clone/count,
callback invocation and short-circuit structure, establish usize representation
bounds, and connect callback ownership/drop behavior to Rust. The coverage entry
for `Membership::quorum` remains planned. M1 and M2 remain incomplete.

Validation: the provider kernel test passed audited trace, cleanup and response-
bound theorems, and rejected an intentionally incorrect skipped-drop result.
Original-Rust native scenarios passed for stateful answers, short circuit,
stable and empty memberships, callback panic and drop panic. Existing membership
proofs replayed on host and installed wasm32 with 100 obligations; their count
has not increased because quorum lowering is still absent. Provider/Jarl Clippy,
provider rustdoc, formatting and coverage/review checks passed. Lean checks ran
one process at a time with a 16384 MiB ceiling.

## M1: source-derived quorum interaction contracts

Provium now lowers the original `Membership::quorum` body, retaining the local
closure, cloned iterator count, stateful FnMut calls, strict majority comparison,
and source-local joint-state query. Five Jarl-owned obligations connect the
complete generated interaction to existing current/old voter projections, prove
stable-member short circuit and empty-current cleanup, and bound completed
response steps for arbitrary membership lengths and callback handles. The
membership project now contains 14 complete method translations and 105 checked
obligations. Jarl production Rust is unchanged.

The response budget requires completed external responses; it is not a proof
that arbitrary Rust callbacks terminate. Source-to-IR preservation, ownership,
unwind and usize representation remain open, as do caller validity and historical
configuration safety. `quorum_index` still needs numeric callbacks, sorting,
rank selection and empty-input outcomes. M1 and M2 remain incomplete.

The provider's independent fixture checks source-derived callback traces and
rejects threshold/selection mutations. Jarl's original-source mutation suite now
rejects 21 mutants through Lean contract failure, including three quorum changes,
and invalidates stale certificates. Original-Rust callback tests, Jarl Clippy,
formatting and coverage/review checks pass.
Host and installed wasm32 verification each checked all 105 obligations with
axiom auditing. Lean checks ran one process at a time with a 16384 MiB ceiling.

## M1: numeric callback behavior and typed protocol

Original `Membership::quorum_index` now has an independent native threshold
oracle over every optional-slot/flag combination at capacities 0 through 4.
It checks stateful callback order (including repeated shared identities), tied
and maximum u64 values, empty-current panic, callback panic at each position,
and callback-drop panic in both overflow-check profiles. The oracle uses the
largest value supported by a strict majority rather than copying the sort/rank
implementation. These finite tests specify regression expectations, not an
unbounded theorem or a source-preservation proof.

Provium's existing Boolean interaction now specializes a generic typed callback
protocol. Callback and enclosing return types may differ. Ordered collection
retains advanced callback handles and normal/unwind/abort cleanup behavior.
Kernel checks cover repeated-key numeric replies, order, empty collection,
unwind and abort; existing Boolean protocol checks remain in place.

`quorum_index` remains planned: source-derived numeric loops, array writes and
bounds, sorting/rank selection, profile-dependent empty-input steps and caller
invariants still need translation and refinement. M1 and M2 remain incomplete.

Validation: typed and Boolean kernel callback checks, original numeric native
checks, provider ordinary tests, provider/Jarl Clippy, formatting and provider
rustdoc passed. All 105 existing membership obligations replayed on host and
installed wasm32 after the typed-protocol change. Lean remained serialized with
a 16384 MiB ceiling. No numeric source-linked obligation is counted yet.

## M1: unbounded numeric rank contracts

Provium now provides `Provium.OrderStatistics` in method proof bundles, with its
source included in artifact hashes. General Lean contracts prove sorted length,
permutation and order; existence and input membership of the selected rank;
exact support-count equivalence and maximality; scalar-bound preservation; and
invariance under input permutation. The rank expression uses an explicit divisor
greater than one. A count-based oracle determines its answer without computing
the sort. All statements quantify over arbitrary lists and preserve ties.

Nonempty-prefix arithmetic proves the quotient increment fits whenever count
fits, and the selected offset is within count. Empty-prefix wrapping subtraction
produces the maximum word and an out-of-bounds index for every representable
buffer capacity. These are arithmetic contracts, not a completed Rust array or
panic refinement.

This advances the reusable P05/P06 foundation for `quorum_index`. Its source
loops, buffer updates, sort_unstable contract, callback composition and caller
invariants remain open. No Jarl numeric source obligation has been discharged;
M1 and M2 remain incomplete.

Validation: the order-statistic kernel test audited 21 contracts/examples and
rejected changed rank offsets, reversed sorting and a fabricated empty result.
Provider ordinary tests, Clippy, formatting and rustdoc passed. The existing
105 membership obligations replayed on host and installed wasm32 with the new
bundled module. Lean checks remained serialized with a 16384 MiB ceiling.

## M1: complete numeric quorum body lowering

Provium now checks both original callback loops, zero-filled buffer and count,
one write/increment per iteration, initialized-prefix sorting, both rank formulas,
count reset, source-local early return and final minimum. Both projections and
the gate retain their source bodies. The runtime uses bounded UInt64 replies,
shared typed callback observations, and checked natural-rank conversion. Caller
callbacks may change answers across repeated identities; a zero first rank does
not skip the old pass.

Three Jarl-owned interaction contracts cover `quorum_index`: complete two-round
execution, stable execution and empty-current panic. The membership project now
has 15 complete structural method translations and 108 obligations. This closes
the remaining membership-body translation inventory, not its refinement or
reachable-state obligations. Jarl production source remains unchanged.

The initialized prefix is still represented by a logical list. Source-to-IR,
Rust array/buffer/usize/sort_unstable/ownership refinement, source panic detail
and build-to-panic-policy binding remain open. Numeric callback termination and
caller membership/history assumptions also remain open. M1 and M2 are incomplete.

Validation: the independent numeric fixture rejects hidden effects and changed
loop/range/binding structure, checks normal and empty-panic source-derived traces,
and rejects divisor/projection/gate mutations through Lean contract failure.
All 23 original-Jarl membership mutants failed their Lean contracts and removed
stale certificates. Shared Boolean/typed callback kernel regressions, native
quorum tests, provider ordinary tests, provider/Jarl Clippy, formatting, rustdoc
and coverage review passed. All 108 membership obligations replayed on host and
installed wasm32. Lean checks remained serialized with a 16384 MiB ceiling.

## M1: indexed numeric buffer refinement

The numeric runtime now carries an explicit fixed-length buffer and count through
both callback passes. Each normal reply writes the current index and increments
count; index checking follows callback evaluation. A structural proof relates
that execution to ordered collection for every callback response and handle.
Supporting theorems establish buffer length, exact written contents, the
initialized prefix and preserved unused slots. Continuation equivalence is
restricted to reachable reply-list lengths, rather than assuming equality for
unreachable lists of arbitrary length.

The full numeric-fold refinement derives both passes' capacity from the source
projections. It carries the first buffer into the second pass, resets the count,
and proves the same observable callback/cleanup interaction as the earlier list
model. Jarl's `QuorumIndex.execution` now invokes that theorem. The 108-obligation
count is unchanged; its numeric execution evidence is stronger.

This discharges the logical indexed-write-to-collection step. It does not prove
Rust memory/ownership or usize representation, sort_unstable refinement, panic
policy/detail binding, parsing/lowering preservation, or caller invariants.
M1 and M2 remain incomplete.

Validation: the buffer kernel test audited ten contracts/examples, including
callback-before-bounds behavior, abort, indexed replacement and buffer reuse.
Four corrupted write/count implementations failed kernel checking. Numeric
source fixtures and their divisor/projection/gate mutants passed their expected
checks. All 108 membership obligations replayed on host and installed wasm32.
Provider ordinary tests, Clippy, formatting, rustdoc and Jarl coverage review
passed. Lean checks remained serialized with a 16384 MiB ceiling.

## M1: prefix sorting and indexed rank refinement

The numeric execution model now sorts each initialized buffer prefix, reads the
computed rank index from that buffer, and carries the first sorted buffer into
the second callback pass. General contracts prove constant buffer length,
permutation of the original contents, and unchanged unused suffix. Indexed
selection after canonical sorting refines the existing numeric rank function.
The complete two-pass refinement consequently includes both prefix sorts and
index reads, preserving the existing Jarl execution theorem and all callbacks.

The provider sort is a canonical logical operation over bounded numeric values.
This does not verify Rust's sort_unstable implementation, Rust memory/ownership,
integer-width/profile binding, panic detail or original-source preservation.
Those and caller invariants remain M1 work. M1 and M2 are incomplete; the
membership obligation count remains 108.

Validation: 15 buffer contracts/examples passed axiom auditing. Seven corrupted
runtime definitions failed kernel checking, including suffix truncation, an
incorrect rank index and a changed empty-prefix guard. The numeric source fixture
and its three semantic mutations passed their expected checks. All 108 Jarl
membership obligations replayed on host and installed wasm32. Provider ordinary
tests, Clippy, formatting, rustdoc and coverage review passed. Lean checks stayed
serialized with a 16384 MiB ceiling.
