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
