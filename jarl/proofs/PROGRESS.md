# Correctness proof implementation progress

This records implemented evidence against [CORRECTNESS_PLAN.md](CORRECTNESS_PLAN.md).
It is not a completion certificate. No full-correctness milestone is closed yet.

Execution rule: a checked commit is a checkpoint, not the stopping condition.
Continue with the next open source-linked obligation under the existing toolchain,
dependency, no_std/sans-I/O and approval constraints. Only the full specification's
verified completion can close this work; a green component suite cannot.

Immediate frontier: preserve restored log-ID ordering and commitment bounds
across storage mutations, then compose complete protocol callers and durable
histories. Successful recovery ordering and its scalar validity are checked below. Buffer-shape induction alone
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
