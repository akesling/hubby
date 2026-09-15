# Correctness proof implementation progress

This records implemented evidence against [CORRECTNESS_PLAN.md](CORRECTNESS_PLAN.md).
It is not a completion certificate. No full-correctness milestone is closed yet.

Execution rule: a checked commit is a checkpoint, not the stopping condition.
Continue with the next open source-linked obligation under the existing toolchain,
dependency, no_std/sans-I/O and approval constraints. Only the full specification's
verified completion can close this work; a green component suite cannot.

Immediate frontier: translate `State::truncate` with explicit payload-drop
suspensions and complete `last` calls, then close restore/install preservation before
claiming the storage invariant for every reachable state.

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
- Preservation of `len ≤ CAP` through restore and mutation is still open; this
  predicate proof does not assume those callers are correct.

## Fresh-state initialization (M1, C02/R02)

- The complete original `State::new` constructor now lowers with its derived
  hard-state Default and empty Option-array callback. Hidden/default initializer
  effects and namespace shadowing are rejected.
- Lean checks initial term/vote/commit, absent snapshot, zero length, arbitrary
  empty-array capacity, and the initial length bound. This supplies the fresh-state
  case; restore and other mutating transitions remain separate obligations.
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
- Restore, truncate, install, log-ID ordering, destructor unwinding and
  source/layout/borrow refinement remain separate obligations. The append-only
  history is not a claim about all reachable Raft storage states.

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
  growth with capacity as a changing history index. Restore, truncation and
  snapshot installation still need preservation lemmas before this covers every
  reachable Jarl storage history.
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
- Actual reference lifetimes/layout, entry LogId consistency,
  restore, truncation and installation still require source-linked contracts.

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
- Panic hooks, iterator lifetime/layout refinement and full storage/log-content
  preservation through restore/truncate/install remain open.

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
