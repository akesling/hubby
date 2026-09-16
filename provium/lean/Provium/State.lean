import Lean

/- Field-store semantics for the initial whole-method assignment backend.
   The source frontend must resolve each field and prove it is a non-dropping
   scalar before admitting a write. Borrow/layout refinement remains trusted. -/
namespace Provium.State
abbrev Path := List String
inductive Cell (α : Type) where
  | boolean (value : Bool)
  | absent
  | other (value : α)
  deriving DecidableEq
abbrev Store (α : Type) := Path → Cell α
inductive Literal where
  | boolean (value : Bool)
  | absent
  deriving Repr
structure Write where
  path : Path
  value : Literal
  deriving Repr

def value (literal : Literal) : Cell α :=
  match literal with
  | .boolean b => .boolean b
  | .absent => .absent

def put (state : Store α) (path : Path) (cell : Cell α) : Store α :=
  fun key => if key = path then cell else state key

def run : List Write → Store α → Store α
  | [], state => state
  | write :: rest, state => run rest (put state write.path (value write.value))

theorem frame (writes : List Write) (state : Store α) (key : Path)
    (untouched : ∀ write ∈ writes, key ≠ write.path) :
    run writes state key = state key := by
  induction writes generalizing state with
  | nil => rfl
  | cons write rest ih =>
    simp only [run]
    rw [ih _ (by intro w hw; exact untouched w (List.mem_cons_of_mem _ hw))]
    exact if_neg (untouched write (by simp))
-- Ill-typed stores have a total extension (non-boolean cells read as false).
-- Rust refinement only relates stores whose accessed leaves have their source type.
inductive Condition where
  | boolean (value : Bool)
  | field (path : Path)
  | not (condition : Condition)
  | and (left right : Condition)
  | or (left right : Condition)
  deriving Repr

def evalCondition : Condition → Store α → Bool
  | .boolean b, _ => b
  | .field p, state => match state p with | .boolean b => b | _ => false
  | .not c, state => !(evalCondition c state)
  | .and a b, state => evalCondition a state && evalCondition b state
  | .or a b, state => evalCondition a state || evalCondition b state

inductive Program where
  | done
  | write (effect : Write)
  | seq (first rest : Program)
  | branch (condition : Condition) (yes no : Program)
  deriving Repr

def execute : Program → Store α → Store α
  | .done, state => state
  | .write w, state => put state w.path (value w.value)
  | .seq first rest, state => execute rest (execute first state)
  | .branch c yes no, state =>
    if evalCondition c state then execute yes state else execute no state

def writes : Program → List Path
  | .done => []
  | .write w => [w.path]
  | .seq a b => writes a ++ writes b
  | .branch _ a b => writes a ++ writes b

theorem execute_frame (program : Program) (state : Store α) (key : Path)
    (untouched : key ∉ writes program) :
    execute program state key = state key := by
  induction program generalizing state with
  | done => rfl
  | write w =>
    exact if_neg (by simpa [writes] using untouched)
  | seq first rest ihfirst ihrest =>
    simp only [writes, List.mem_append, not_or] at untouched
    exact (ihrest _ untouched.2).trans (ihfirst _ untouched.1)
  | branch c yes no ihyes ihno =>
    simp only [writes, List.mem_append, not_or] at untouched
    simp only [execute]
    split
    · exact ihyes _ untouched.1
    · exact ihno _ untouched.2
-- Initialized-slot refinement for the non-dropping scalar assignment backend.
-- `none` here means moved-out/uninitialized storage; `some .absent` is a live
-- Rust Option::None. Paths still require source/layout and loan validation.
-- This does not model dropping assignments, pointer aliasing, or reborrows.
namespace Initialized
inductive Kind where
  | boolean
  | optional
  | payload
  deriving DecidableEq

def Fits : Kind → Cell α → Prop
  | .boolean, .boolean _ => True
  | .optional, .absent => True
  | .optional, .other _ => True
  | .payload, .other _ => True
  | _, _ => False

abbrev Layout := Path → Option Kind
abbrev Heap (α : Type) := Path → Option (Cell α)

def Valid (layout : Layout) (heap : Heap α) : Prop :=
  ∀ p cell, heap p = some cell → ∃ kind, layout p = some kind ∧ Fits kind cell

def set (heap : Heap α) (path : Path) (slot : Option (Cell α)) : Heap α :=
  fun key => if key = path then slot else heap key

inductive Fault where
  | invalidPlace
  | uninitialized
  | wrongType
  deriving DecidableEq

def read (layout : Layout) (heap : Heap α) (path : Path) : Except Fault (Cell α) :=
  match layout path with
  | none => .error .invalidPlace
  | some _ => match heap path with
    | none => .error .uninitialized
    | some cell => .ok cell

-- Move transfers a value to the result and invalidates the source slot.
-- This primitive is admissible only after exclusive access is established.
def move (layout : Layout) (heap : Heap α) (path : Path) :
    Except Fault (Cell α × Heap α) := do
  let cell ← read layout heap path
  pure (cell, set heap path none)

def literalKind : Literal → Kind
  | .boolean _ => .boolean
  | .absent => .optional

-- Assignment may reinitialize moved-out storage. Payload destruction is not
-- implicit: this rule applies to the frontend's non-dropping assignment subset.
def assign (layout : Layout) (heap : Heap α) (write : Write) : Except Fault (Heap α) :=
  match layout write.path with
  | none => .error .invalidPlace
  | some kind =>
    if kind = literalKind write.value then
      .ok (set heap write.path (some (value write.value)))
    else .error .wrongType

def run : List Write → Layout → Heap α → Except Fault (Heap α)
  | [], _, heap => .ok heap
  | w :: rest, layout, heap => do
    let next ← assign layout heap w
    run rest layout next

-- Related heaps contain all declared fields, with their proper scalar types.
-- No constraint is imposed by the total leaf store on undeclared paths.
def Relates (layout : Layout) (heap : Heap α) (store : Store α) : Prop :=
  ∀ p kind, layout p = some kind → heap p = some (store p) ∧ Fits kind (store p)

theorem literal_fits (literal : Literal) : Fits (literalKind literal) (value (α := α) literal) := by
  cases literal <;> trivial

theorem set_valid (valid : Valid layout heap)
    (typed : ∀ cell, slot = some cell → ∃ kind, layout path = some kind ∧ Fits kind cell) :
    Valid layout (set heap path slot) := by
  intro p cell found
  by_cases same : p = path
  · subst p
    exact typed cell (by simpa [set] using found)
  · exact valid p cell (by simpa [set, same] using found)

theorem move_invalidates (declared : layout path = some kind)
    (live : heap path = some cell) :
    move layout heap path = .ok (cell, set heap path none) ∧
    read layout (set heap path none) path = .error .uninitialized := by
  simp [move, read, declared, live, set]
  rfl

theorem move_preserves_validity (valid : Valid layout heap) :
    Valid layout (set heap path none) := by
  exact set_valid valid (by intro cell impossible; cases impossible)

theorem set_frame (different : key ≠ path) :
    set heap path slot key = heap key := by simp [set, different]

theorem assign_refines (related : Relates layout heap store)
    (typed : layout write.path = some (literalKind write.value)) :
    assign layout heap write = .ok (set heap write.path (some (value write.value))) ∧
    Relates layout (set heap write.path (some (value write.value)))
      (put store write.path (value write.value)) := by
  constructor
  · simp [assign, typed]
  · intro p kind declared
    by_cases same : p = write.path
    · subst p
      have kinds : kind = literalKind write.value := Option.some.inj (declared.symm.trans typed)
      subst kind
      simp only [set, put]
      exact ⟨rfl, literal_fits write.value⟩
    · simpa [set, put, same] using related p kind declared

-- This is a refinement of the existing generated assignment semantics, not a
-- second independently written algorithm: both sides consume the same writes.
theorem run_refines (effects : List Write) (related : Relates layout heap store)
    (typed : ∀ w ∈ effects, layout w.path = some (literalKind w.value)) :
    ∃ result, run effects layout heap = .ok result ∧
      Relates layout result (Provium.State.run effects store) := by
  induction effects generalizing heap store with
  | nil => exact ⟨heap, rfl, related⟩
  | cons w rest ih =>
    obtain ⟨assigned, nextRelated⟩ := assign_refines related (typed w (by simp))
    obtain ⟨result, completed, finalRelated⟩ := ih nextRelated
      (by intro v hv; exact typed v (List.mem_cons_of_mem _ hv))
    refine ⟨result, ?_, finalRelated⟩
    simp only [run, assigned]
    exact completed
def ConditionTyped (layout : Layout) : Condition → Prop
  | .boolean _ => True
  | .field p => layout p = some .boolean
  | .not c => ConditionTyped layout c
  | .and a b | .or a b => ConditionTyped layout a ∧ ConditionTyped layout b

def ProgramTyped (layout : Layout) : Program → Prop
  | .done => True
  | .write w => layout w.path = some (literalKind w.value)
  | .seq a b => ProgramTyped layout a ∧ ProgramTyped layout b
  | .branch c a b => ConditionTyped layout c ∧ ProgramTyped layout a ∧ ProgramTyped layout b

def condition (layout : Layout) (heap : Heap α) : Condition → Except Fault Bool
  | .boolean b => .ok b
  | .field p => do
    let cell ← read layout heap p
    match cell with
    | .boolean b => .ok b
    | _ => .error .wrongType
  | .not c => do return !(← condition layout heap c)
  | .and a b => do
    if ← condition layout heap a then condition layout heap b else pure false
  | .or a b => do
    if ← condition layout heap a then pure true else condition layout heap b

def execute (layout : Layout) : Program → Heap α → Except Fault (Heap α)
  | .done, heap => .ok heap
  | .write w, heap => assign layout heap w
  | .seq a b, heap => do execute layout b (← execute layout a heap)
  | .branch c a b, heap => do
    if ← condition layout heap c then execute layout a heap else execute layout b heap

theorem condition_refines (c : Condition) (related : Relates layout heap store)
    (typed : ConditionTyped layout c) :
    condition layout heap c = .ok (evalCondition c store) := by
  induction c with
  | boolean b => rfl
  | field p =>
    change layout p = some .boolean at typed
    obtain ⟨live, fits⟩ := related p .boolean typed
    cases found : store p with
    | boolean b => simp [condition, read, typed, live, found, evalCondition]; rfl
    | absent => simp [found, Fits] at fits
    | other v => simp [found, Fits] at fits
  | not c ih =>
    simp only [condition, ih typed, evalCondition]
    rfl
  | and a b iha ihb =>
    simp only [condition, iha typed.1, evalCondition]
    cases evalCondition a store <;> simp [ihb typed.2] <;> rfl
  | or a b iha ihb =>
    simp only [condition, iha typed.1, evalCondition]
    cases evalCondition a store <;> simp [ihb typed.2] <;> rfl

theorem execute_refines (program : Program) (related : Relates layout heap store)
    (typed : ProgramTyped layout program) :
    ∃ result, execute layout program heap = .ok result ∧
      Relates layout result (Provium.State.execute program store) := by
  induction program generalizing heap store with
  | done => exact ⟨heap, rfl, related⟩
  | write w =>
    obtain ⟨assigned, nextRelated⟩ := assign_refines related typed
    exact ⟨_, assigned, nextRelated⟩
  | seq a b iha ihb =>
    obtain ⟨middle, first, midRelated⟩ := iha related typed.1
    obtain ⟨result, second, finalRelated⟩ := ihb midRelated typed.2
    refine ⟨result, ?_, finalRelated⟩
    simp only [execute, first]
    exact second
  | branch c a b iha ihb =>
    have checked := condition_refines c related typed.1
    cases choice : evalCondition c store with
    | false =>
      obtain ⟨result, completed, finalRelated⟩ := ihb related typed.2.2
      refine ⟨result, ?_, ?_⟩
      · simp only [execute, checked, choice]
        exact completed
      · simpa [Provium.State.execute, choice] using finalRelated
    | true =>
      obtain ⟨result, completed, finalRelated⟩ := iha related typed.2.1
      refine ⟨result, ?_, ?_⟩
      · simp only [execute, checked, choice]
        exact completed
      · simpa [Provium.State.execute, choice] using finalRelated

end Initialized

-- Option-array representation preserves empty slots and capacity. The reserved
-- presence leaf records slot deletion and is not a Rust record field.
abbrev ArrayStore (α : Type) := List (Option (Store α))
def mapSlot (effect : Store α → Store α) : Option (Store α) → Option (Store α)
  | none => none
  | some state =>
    let result := effect (put state ["$present"] (.boolean true))
    if evalCondition (.field ["$present"]) result then some result else none

def executeArray (program : Program) (entries : ArrayStore α) : ArrayStore α :=
  entries.map (mapSlot (execute program))

theorem executeArray_length (program : Program) (entries : ArrayStore α) :
    (executeArray program entries).length = entries.length := by
  simp [executeArray]
def queryArray (predicate : Condition) (entries : ArrayStore α) : Bool :=
  entries.any (fun entry => match entry with
    | none => false
    | some state => evalCondition predicate state)

theorem evalCondition_field_true (state : Store α) (path : Path) :
    evalCondition (.field path) state = true ↔ state path = .boolean true := by
  cases h : state path <;> simp [evalCondition, h]

-- Copied-field projections of pure optional-record iterators. The list denotes
-- the lazy output sequence; Rust neither allocates it nor clones payloads.
structure RecordProjection where
  predicate : Condition
  field : Path

def projectSlot (program : RecordProjection) : Option (Store α) → Option (Cell α)
  | none => none
  | some state => if evalCondition program.predicate state then some (state program.field) else none

def projectArray (program : RecordProjection) (entries : ArrayStore α) : List (Cell α) :=
  entries.filterMap (projectSlot program)

theorem projectArray_member (program : RecordProjection) (entries : ArrayStore α) (value : Cell α) :
    value ∈ projectArray program entries ↔
      ∃ state, some state ∈ entries ∧ evalCondition program.predicate state = true ∧
        state program.field = value := by
  simp only [projectArray, List.mem_filterMap]
  constructor
  · rintro ⟨entry, member, selected⟩
    cases entry with
    | none => simp [projectSlot] at selected
    | some state =>
      simp only [projectSlot] at selected
      split at selected
      · cases selected
        exact ⟨state, member, by assumption, rfl⟩
      · cases selected
  · rintro ⟨state, member, selected, valueEq⟩
    refine ⟨some state, member, ?_⟩
    simp [projectSlot, selected, valueEq]

-- Equality is structural for the accepted scalar/derived-record key types.
-- The relation between Rust key values and Cell equality remains a refinement
-- obligation; DecidableEq supplies executable equality on the logical domain.
def queryKey [DecidableEq α] (program : RecordProjection) (entries : ArrayStore α)
    (key : Cell α) : Bool :=
  entries.any (fun entry => match entry with
    | none => false
    | some state => decide (state program.field = key) && evalCondition program.predicate state)

theorem queryKey_member [DecidableEq α] (program : RecordProjection)
    (entries : ArrayStore α) (key : Cell α) :
    queryKey program entries key = true ↔ key ∈ projectArray program entries := by
  rw [projectArray_member]
  simp only [queryKey, List.any_eq_true]
  constructor
  · rintro ⟨entry, member, selected⟩
    cases entry with
    | none => contradiction
    | some state =>
      simp only [Bool.and_eq_true, decide_eq_true_eq] at selected
      exact ⟨state, member, selected.2, selected.1⟩
  · rintro ⟨state, member, predicate, value⟩
    exact ⟨some state, member, by simp [value, predicate]⟩

theorem projectArray_length (program : RecordProjection) (entries : ArrayStore α) :
    (projectArray program entries).length ≤ entries.length :=
  List.length_filterMap_le _ _

-- Existing identities take priority over empty slots, even earlier empty slots.
structure Upsert where
  key : Path
  initial : List Write
  cases : List (Nat × Write)
  fallback : Write
  error : String

def firstSlot (predicate : Option (Store α) → Bool) : ArrayStore α → Option Nat
  | [] => none
  | entry :: rest => if predicate entry then some 0 else (firstSlot predicate rest).map Nat.succ

def keySlot [DecidableEq α] (path : Path) (key : Cell α) : Option (Store α) → Bool
  | none => false
  | some state => decide (state path = key)

def upsertIndex [DecidableEq α] (program : Upsert) (entries : ArrayStore α) (key : Cell α) : Option Nat :=
  (firstSlot (keySlot program.key key) entries).orElse (fun _ => firstSlot Option.isNone entries)

def upsertWrite (program : Upsert) (tag : Nat) : Write :=
  ((program.cases.find? (fun c => c.1 == tag)).map Prod.snd).getD program.fallback

def upsertRecord (program : Upsert) (key : Cell α) (tag : Nat) (entry : Option (Store α)) : Store α :=
  let initial := put (run program.initial (fun _ => .absent)) program.key key
  let selected := entry.getD initial
  run [upsertWrite program tag] selected

def runUpsert [DecidableEq α] (program : Upsert) (entries : ArrayStore α) (key : Cell α)
    (tag : Nat) : ArrayStore α × Option String :=
  match upsertIndex program entries key with
  | none => (entries, some program.error)
  | some index => match entries[index]? with
    | none => (entries, some "$bounds")
    | some entry => (entries.set index (some (upsertRecord program key tag entry)), none)

theorem firstSlot_selected (predicate : Option (Store α) → Bool) (entries : ArrayStore α)
    (index : Nat) (selected : firstSlot predicate entries = some index) :
    ∃ entry, entries[index]? = some entry ∧ predicate entry = true := by
  induction entries generalizing index with
  | nil => simp [firstSlot] at selected
  | cons entry rest ih =>
    cases hp : predicate entry
    · cases hs : firstSlot predicate rest with
      | none => simp [firstSlot, hp, hs] at selected
      | some j =>
        simp only [firstSlot, hp, Bool.false_eq_true, ↓reduceIte, hs, Option.map_some,
          Option.some.injEq] at selected
        subst index
        obtain ⟨value, found, passes⟩ := ih j hs
        exact ⟨value, by simpa using found, passes⟩
    · simp only [firstSlot, hp, ↓reduceIte, Option.some.injEq] at selected
      subst index
      exact ⟨entry, rfl, hp⟩

theorem upsertIndex_selected [DecidableEq α] (program : Upsert) (entries : ArrayStore α)
    (key : Cell α) (index : Nat) (selected : upsertIndex program entries key = some index) :
    ∃ entry, entries[index]? = some entry ∧ (keySlot program.key key entry = true ∨ entry = none) := by
  cases hk : firstSlot (keySlot program.key key) entries with
  | some j =>
    simp only [upsertIndex, hk, Option.orElse_some, Option.some.injEq] at selected
    subst index
    obtain ⟨entry, found, passes⟩ := firstSlot_selected _ _ j hk
    exact ⟨entry, found, Or.inl passes⟩
  | none =>
    simp only [upsertIndex, hk, Option.orElse_none] at selected
    obtain ⟨entry, found, empty⟩ := firstSlot_selected _ _ index selected
    exact ⟨entry, found, Or.inr (by simpa using empty)⟩

theorem firstSlot_none (predicate : Option (Store α) → Bool) (entries : ArrayStore α) :
    firstSlot predicate entries = none ↔ ∀ entry ∈ entries, predicate entry = false := by
  induction entries with
  | nil => simp [firstSlot]
  | cons entry rest ih =>
    cases hp : predicate entry <;> simp [firstSlot, hp, ih]

theorem upsertIndex_none [DecidableEq α] (program : Upsert) (entries : ArrayStore α) (key : Cell α) :
    upsertIndex program entries key = none ↔
      (∀ state, some state ∈ entries → state program.key ≠ key) ∧ none ∉ entries := by
  have split : upsertIndex program entries key = none ↔
      firstSlot (keySlot program.key key) entries = none ∧ firstSlot Option.isNone entries = none := by
    cases h : firstSlot (keySlot program.key key) entries <;> simp [upsertIndex, h]
  rw [split, firstSlot_none, firstSlot_none]
  constructor
  · rintro ⟨keys, slots⟩
    constructor
    · intro state member
      simpa [keySlot] using keys (some state) member
    · intro member
      simpa using slots none member
  · rintro ⟨keys, slots⟩
    constructor
    · intro entry member
      cases entry with
      | none => rfl
      | some state => simpa [keySlot] using keys state member
    · intro entry member
      cases entry with
      | none => exact False.elim (slots member)
      | some state => rfl

theorem upsertIndex_empty_no_match [DecidableEq α] (program : Upsert) (entries : ArrayStore α)
    (key : Cell α) (index : Nat) (selected : upsertIndex program entries key = some index)
    (empty : entries[index]? = some none) : firstSlot (keySlot program.key key) entries = none := by
  cases found : firstSlot (keySlot program.key key) entries with
  | none => rfl
  | some j =>
    have same : j = index := by simpa [upsertIndex, found] using selected
    subst j
    obtain ⟨entry, present, passes⟩ := firstSlot_selected _ _ index found
    rw [empty] at present
    cases present
    contradiction

theorem runUpsert_selected [DecidableEq α] (program : Upsert) (entries : ArrayStore α)
    (key : Cell α) (tag index : Nat) (selected : upsertIndex program entries key = some index) :
    ∃ entry, entries[index]? = some entry ∧
      runUpsert program entries key tag =
        (entries.set index (some (upsertRecord program key tag entry)), none) := by
  obtain ⟨entry, found, _⟩ := upsertIndex_selected program entries key index selected
  exact ⟨entry, found, by simp [runUpsert, selected, found]⟩

theorem runUpsert_length [DecidableEq α] (program : Upsert) (entries : ArrayStore α)
    (key : Cell α) (tag : Nat) : (runUpsert program entries key tag).1.length = entries.length := by
  cases hi : upsertIndex program entries key with
  | none => simp [runUpsert, hi]
  | some index =>
    obtain ⟨entry, _, result⟩ := runUpsert_selected program entries key tag index hi
    simp [result]

theorem runUpsert_error [DecidableEq α] (program : Upsert) (entries : ArrayStore α)
    (key : Cell α) (tag : Nat) :
    (runUpsert program entries key tag).2 = some program.error ↔ upsertIndex program entries key = none := by
  cases hi : upsertIndex program entries key with
  | none => simp [runUpsert, hi]
  | some index =>
    obtain ⟨entry, _, result⟩ := runUpsert_selected program entries key tag index hi
    simp [result]

theorem runUpsert_frame [DecidableEq α] (program : Upsert) (entries : ArrayStore α)
    (key : Cell α) (tag index other : Nat) (selected : upsertIndex program entries key = some index)
    (different : other ≠ index) : (runUpsert program entries key tag).1[other]? = entries[other]? := by
  obtain ⟨entry, _, result⟩ := runUpsert_selected program entries key tag index selected
  simp [result, Ne.symm different]

-- Checked nested slice batches. Lists denote source slices and their traversed
-- prefixes; the Rust constructor does not allocate these logical lists.
structure SlotBatch where
  insert : Upsert
  required : Nat
  passes : List (Nat × Nat)
  exclusionTag : Nat
  exclusionInput : Nat
  error : String

def runSlotBatchPass [DecidableEq α] (program : SlotBatch) (excluded : List (Cell α))
    (tag : Nat) : List (Cell α) → List (Cell α) → ArrayStore α → Except String (ArrayStore α)
  | [], _, entries => .ok entries
  | key :: rest, seen, entries =>
    if key ∈ seen ∨ (tag = program.exclusionTag ∧ key ∈ excluded) then .error program.error
    else
      let result := runUpsert program.insert entries key tag
      match result.2 with
      | some error => .error error
      | none => runSlotBatchPass program excluded tag rest (seen ++ [key]) result.1

def runSlotBatchPasses [DecidableEq α] (program : SlotBatch) (inputs : List (List (Cell α))) :
    List (Nat × Nat) → ArrayStore α → Except String (ArrayStore α)
  | [], entries => .ok entries
  | (input, tag) :: rest, entries =>
    match runSlotBatchPass program (inputs[program.exclusionInput]?.getD []) tag (inputs[input]?.getD []) [] entries with
    | .error error => .error error
    | .ok next => runSlotBatchPasses program inputs rest next

def runSlotBatch [DecidableEq α] (program : SlotBatch) (capacity : Nat)
    (inputs : List (List (Cell α))) : Except String (ArrayStore α) :=
  if (inputs[program.required]?.getD []).isEmpty then .error program.error
  else runSlotBatchPasses program inputs program.passes (List.replicate capacity none)

theorem runSlotBatchPass_preserves [DecidableEq α] (program : SlotBatch)
    (invariant : ArrayStore α → Prop)
    (step : ∀ entries key tag, invariant entries →
      (runUpsert program.insert entries key tag).2 = none →
      invariant (runUpsert program.insert entries key tag).1)
    (excluded keys seen : List (Cell α)) (tag : Nat) (entries result : ArrayStore α)
    (initial : invariant entries)
    (success : runSlotBatchPass program excluded tag keys seen entries = .ok result) : invariant result := by
  induction keys generalizing seen entries with
  | nil => cases success; exact initial
  | cons key rest ih =>
    simp only [runSlotBatchPass] at success
    split at success
    · cases success
    · cases failure : (runUpsert program.insert entries key tag).2 with
      | some error => simp [failure] at success
      | none =>
        simp only [failure] at success
        exact ih (seen ++ [key]) _ (step entries key tag initial failure) success

theorem runSlotBatchPasses_preserves [DecidableEq α] (program : SlotBatch)
    (invariant : ArrayStore α → Prop)
    (step : ∀ entries key tag, invariant entries →
      (runUpsert program.insert entries key tag).2 = none →
      invariant (runUpsert program.insert entries key tag).1)
    (inputs : List (List (Cell α))) (passes : List (Nat × Nat)) (entries result : ArrayStore α)
    (initial : invariant entries)
    (success : runSlotBatchPasses program inputs passes entries = .ok result) : invariant result := by
  induction passes generalizing entries with
  | nil => cases success; exact initial
  | cons pass rest ih =>
    obtain ⟨input, tag⟩ := pass
    simp only [runSlotBatchPasses] at success
    cases next : runSlotBatchPass program (inputs[program.exclusionInput]?.getD []) tag (inputs[input]?.getD []) [] entries with
    | error error => simp [next] at success
    | ok after =>
      simp only [next] at success
      exact ih after (runSlotBatchPass_preserves program invariant step _ _ [] tag entries after initial next) success

theorem runSlotBatch_preserves [DecidableEq α] (program : SlotBatch)
    (invariant : ArrayStore α → Prop)
    (step : ∀ entries key tag, invariant entries →
      (runUpsert program.insert entries key tag).2 = none →
      invariant (runUpsert program.insert entries key tag).1)
    (capacity : Nat) (inputs : List (List (Cell α))) (result : ArrayStore α)
    (initial : invariant (List.replicate capacity none))
    (success : runSlotBatch program capacity inputs = .ok result) : invariant result := by
  simp only [runSlotBatch] at success
  split at success
  · cases success
  · exact runSlotBatchPasses_preserves program invariant step inputs program.passes _ result initial success

theorem runSlotBatch_length [DecidableEq α] (program : SlotBatch) (capacity : Nat)
    (inputs : List (List (Cell α))) (result : ArrayStore α)
    (success : runSlotBatch program capacity inputs = .ok result) : result.length = capacity := by
  apply runSlotBatch_preserves program (fun entries => entries.length = capacity) _ capacity inputs result _ success
  · intro entries key tag initial _
    simpa only [runUpsert_length] using initial
  · simp

theorem runSlotBatchPass_valid [DecidableEq α] (program : SlotBatch)
    (excluded keys seen : List (Cell α)) (tag : Nat) (entries result : ArrayStore α)
    (success : runSlotBatchPass program excluded tag keys seen entries = .ok result) :
    keys.Nodup ∧ ∀ key ∈ keys, key ∉ seen ∧ (tag = program.exclusionTag → key ∉ excluded) := by
  induction keys generalizing seen entries with
  | nil => simp
  | cons key rest ih =>
    simp only [runSlotBatchPass] at success
    split at success
    · cases success
    · rename_i allowed
      have tail : rest.Nodup ∧ ∀ next ∈ rest, next ∉ seen ++ [key] ∧
          (tag = program.exclusionTag → next ∉ excluded) := by
        cases failure : (runUpsert program.insert entries key tag).2 with
        | some error => simp [failure] at success
        | none =>
          simp only [failure] at success
          exact ih (seen ++ [key]) _ success
      constructor
      · apply List.nodup_cons.mpr
        refine ⟨?_, tail.1⟩
        intro member
        exact (tail.2 key member).1 (by simp)
      · intro next member
        rcases List.mem_cons.mp member with same | member
        · subst next
          exact ⟨fun present => allowed (Or.inl present), fun same present => allowed (Or.inr ⟨same, present⟩)⟩
        · obtain ⟨fresh, excluded⟩ := tail.2 next member
          exact ⟨fun present => fresh (List.mem_append_left _ present), excluded⟩

theorem runSlotBatchPasses_valid [DecidableEq α] (program : SlotBatch)
    (inputs : List (List (Cell α))) (passes : List (Nat × Nat)) (entries result : ArrayStore α)
    (success : runSlotBatchPasses program inputs passes entries = .ok result) :
    ∀ pass ∈ passes, (inputs[pass.1]?.getD []).Nodup ∧
      (pass.2 = program.exclusionTag → ∀ key ∈ inputs[pass.1]?.getD [], key ∉ inputs[program.exclusionInput]?.getD []) := by
  induction passes generalizing entries with
  | nil => simp
  | cons pass rest ih =>
    obtain ⟨input, tag⟩ := pass
    simp only [runSlotBatchPasses] at success
    cases next : runSlotBatchPass program (inputs[program.exclusionInput]?.getD []) tag (inputs[input]?.getD []) [] entries with
    | error error => simp [next] at success
    | ok after =>
      simp only [next] at success
      have valid := runSlotBatchPass_valid program _ _ [] tag entries after next
      intro pass member
      rcases List.mem_cons.mp member with same | member
      · subst pass
        exact ⟨valid.1, fun same key member => (valid.2 key member).2 same⟩
      · exact ih after success pass member

theorem runSlotBatch_valid [DecidableEq α] (program : SlotBatch) (capacity : Nat)
    (inputs : List (List (Cell α))) (result : ArrayStore α)
    (success : runSlotBatch program capacity inputs = .ok result) :
    (inputs[program.required]?.getD []) ≠ [] ∧
    ∀ pass ∈ program.passes, (inputs[pass.1]?.getD []).Nodup ∧
      (pass.2 = program.exclusionTag → ∀ key ∈ inputs[pass.1]?.getD [], key ∉ inputs[program.exclusionInput]?.getD []) := by
  simp only [runSlotBatch] at success
  split at success
  · cases success
  · rename_i nonempty
    exact ⟨by simpa using nonempty, runSlotBatchPasses_valid program inputs program.passes _ result success⟩

-- Shared Result queries do not modify the store. The frontend checks the types
-- of every accessed place. As above, malformed stores have a total extension;
-- field-layout/source correspondence remains an explicit refinement obligation.
inductive QueryCell (α : Type) where
  | boolean (value : Bool)
  | optional (value : Option α)
  | slots (value : List (Option α))
abbrev QueryStore (α : Type) := Path → QueryCell α
inductive QueryTest where
  | boolean (value : Bool)
  | field (path : Path)
  | present (path : Path)
  | anyPresent (path : Path)
  | not (test : QueryTest)
  | and (left right : QueryTest)
  | or (left right : QueryTest)
def evalQueryTest : QueryTest → QueryStore α → Bool
  | .boolean b, _ => b
  | .field p, s => match s p with | .boolean b => b | _ => false
  | .present p, s => match s p with | .optional o => o.isSome | _ => false
  | .anyPresent p, s => match s p with | .slots xs => xs.any Option.isSome | _ => false
  | .not t, s => !(evalQueryTest t s)
  | .and a b, s => evalQueryTest a s && evalQueryTest b s
  | .or a b, s => evalQueryTest a s || evalQueryTest b s
inductive Query where
  | success
  | failure (error : String)
  | branch (test : QueryTest) (yes no : Query)
def runQuery : Query → QueryStore α → Except String Unit
  | .success, _ => .ok ()
  | .failure e, _ => .error e
  | .branch t yes no, s => if evalQueryTest t s then runQuery yes s else runQuery no s

inductive InitCapacity where
  | fixed (size : Nat)
  | parameter (name : String)
inductive Initial where
  | boolean (value : Bool)
  | unsigned (rustType : String) (value : Nat)
  | absent
  | emptySlots (capacity : InitCapacity)
inductive InitCell where
  | boolean (value : Bool)
  | unsigned (rustType : String) (value : Nat)
  | absent
  | slots (entries : List (Option Unit))
structure InitField where
  path : Path
  value : Initial
abbrev InitStore := Path → InitCell
def initialCell (sizes : String → Nat) : Initial → InitCell
  | .boolean b => .boolean b
  | .unsigned ty n => .unsigned ty n
  | .absent => .absent
  | .emptySlots c => .slots (List.replicate (match c with
      | .fixed n => n | .parameter p => sizes p) none)
def initializeFields (fields : List InitField) (sizes : String → Nat) : InitStore :=
  fields.foldl (fun s field key =>
    if key = field.path then initialCell sizes field.value else s key) (fun _ => .absent)
-- A drop node is an external interaction, not a claim that destruction is pure,
-- total, or safe to unwind. The continuation is valid only after normal return.
structure BufferState (α : Type) where
  slots : List (Option α)
  len : Nat
  deriving DecidableEq
inductive BufferFault where
  | bounds
  | overflow
  deriving DecidableEq
inductive BufferRun (α : Type) where
  | returned (result : Except String Unit) (state : BufferState α)
  | fault (reason : BufferFault) (state : BufferState α)
  | drop (payload : α) (before : BufferState α) (continuation : BufferRun α)
structure BufferAppend where
  slotsPath : Path
  lengthPath : Path
  capacityName : String
  equal : Bool
  increment : Nat
  error : String

def appendBuffer (program : BufferAppend) (bits capacity : Nat)
    (state : BufferState α) (input : α) : BufferRun α :=
  if (decide (state.len = capacity)) == program.equal then
    .drop input state (.returned (.error program.error) state)
  else
    match state.slots[state.len]? with
    | none => .drop input state (.fault .bounds state)
    | some previous =>
      let stored := {state with slots := state.slots.set state.len (some input)}
      let next := if state.len + program.increment < 2^bits then
          BufferRun.returned (.ok ()) {stored with len := state.len + program.increment}
        else .fault .overflow stored
      match previous with
      | none => next
      | some old => .drop old state next

-- Only complete, normally returning drop continuations are followed. No theorem
-- about this projection licenses a consumer to assume its Drop cannot panic.
def resumeDrops : BufferRun α → BufferRun α
  | .drop _ _ next => resumeDrops next
  | result => result
structure Relocation where
  slotsPath : Path
  lengthPath : Path
  oldCapacityName : String
  newCapacityName : String
  ascending : Bool
  inclusive : Bool
inductive SlotMoves (α : Type) where
  | done (moved remaining : List (Option α))
  | bounds (index : Nat) (moved remaining : List (Option α))
-- Indices advance in source callback order. Each successful take leaves None.
def moveSlots (inclusive : Bool) (length : Nat) :
    Nat → Nat → List (Option α) → SlotMoves α
  | _, 0, source => .done [] source
  | index, count + 1, source =>
    if (if inclusive then index ≤ length else index < length) then
      match source with
      | [] => .bounds index [] []
      | entry :: rest =>
        match moveSlots inclusive length (index + 1) count rest with
        | .done moved remaining => .done (entry :: moved) (none :: remaining)
        | .bounds failed moved remaining => .bounds failed (entry :: moved) (none :: remaining)
    else .done (List.replicate (count + 1) none) source
inductive RelocationRun (α β : Type) where
  | returned (state : BufferState α) (metadata : β)
  | invalidInstantiation
  | bounds (index : Nat) (moved remaining : List (Option α)) (metadata : β)
  | drop (payload : α) (continuation : RelocationRun α β)
def disposeSlots (slots : List (Option α)) (next : RelocationRun α β) : RelocationRun α β :=
  match slots with
  | [] => next
  | none :: rest => disposeSlots rest next
  | some value :: rest => .drop value (disposeSlots rest next)
def relocate (program : Relocation) (oldCapacity newCapacity : Nat)
    (state : BufferState α) (metadata : β) : RelocationRun α β :=
  if (if program.ascending then newCapacity ≥ oldCapacity else newCapacity ≤ oldCapacity) then
    match moveSlots program.inclusive state.len 0 newCapacity state.slots with
    | .done moved remaining => disposeSlots remaining (.returned ⟨moved, state.len⟩ metadata)
    | .bounds index moved remaining => .bounds index moved remaining metadata
  else .invalidInstantiation
abbrev SelectionStore := Path → Option (Path → InitStore)
structure RecordSelection where
  optional : Path
  recordField : Path
  fallback : List InitField

def selectRecord (program : RecordSelection) (state : SelectionStore) : InitStore :=
  match state program.optional with
  | none => initializeFields program.fallback (fun _ => 0)
  | some payload => payload program.recordField
-- Target-width suffix offsets and borrowed slices. These primitives retain
-- checked conversion failure separately from saturation. SlicePlace denotes a
-- shared range of locations, never an eager Rust allocation or payload copy.
structure SuffixOffsetProgram where
  base : RecordSelection
  baseField : Path
  bias : Nat
  lengthPath : Path

structure SuffixViewStore where
  records : SelectionStore
  lengths : Path → Nat

def suffixOffsetValue (bits length base bias index : Nat) : Nat :=
  let relative := index - base - bias
  min (if relative < 2^bits then relative else length) length

theorem suffixOffsetValue_bounded (bits length base bias index : Nat) :
    suffixOffsetValue bits length base bias index ≤ length := by
  exact Nat.min_le_right _ _

theorem suffixOffsetValue_conversion_failure (tooLarge : 2^bits ≤ index - base - bias) :
    suffixOffsetValue bits length base bias index = length := by
  simp [suffixOffsetValue, Nat.not_lt.mpr tooLarge]

theorem suffixOffsetValue_normalize (word : length < 2^bits) :
    suffixOffsetValue bits length base bias index = min (index - base - bias) length := by
  dsimp only [suffixOffsetValue]
  split
  · rfl
  · have bound : length ≤ index - base - bias := by omega
    rw [Nat.min_self, Nat.min_eq_right bound]

inductive ViewFault where
  | input
  | bounds
  deriving DecidableEq

def suffixOffset (program : SuffixOffsetProgram) (bits : Nat)
    (state : SuffixViewStore) (first : Option Nat) : Except ViewFault Nat :=
  let length := state.lengths program.lengthPath
  if length ≥ 2^bits then .error .input
  else match first with
  | none => .ok length
  | some index =>
    match selectRecord program.base state.records program.baseField with
    | .unsigned rustType base =>
      if rustType ≠ "u64" ∨ index ≥ 2^64 ∨ base ≥ 2^64 ∨ program.bias ≥ 2^64 then
        .error .input
      else .ok (suffixOffsetValue bits length base program.bias index)
    | _ => .error .input

theorem suffixOffset_bounded (success : suffixOffset program bits state first = .ok offset) :
    offset ≤ state.lengths program.lengthPath := by
  dsimp only [suffixOffset] at success
  split at success
  · cases success
  · split at success
    · cases success
      exact Nat.le_refl _
    · split at success
      · split at success
        · cases success
        · cases success
          exact suffixOffsetValue_bounded _ _ _ _ _
      · cases success

theorem suffixOffset_none (program : SuffixOffsetProgram) (bits : Nat)
    (state : SuffixViewStore) (word : state.lengths program.lengthPath < 2^bits) :
    suffixOffset program bits state none = .ok (state.lengths program.lengthPath) := by
  simp [suffixOffset, Nat.not_le.mpr word]

theorem suffixOffset_some (program : SuffixOffsetProgram) (bits : Nat)
    (state : SuffixViewStore) (index base : Nat)
    (word : state.lengths program.lengthPath < 2^bits)
    (selected : selectRecord program.base state.records program.baseField = .unsigned "u64" base)
    (indexBound : index < 2^64) (baseBound : base < 2^64) (biasBound : program.bias < 2^64) :
    suffixOffset program bits state (some index) =
      .ok (min (index - base - program.bias) (state.lengths program.lengthPath)) := by
  simp [suffixOffset, Nat.not_le.mpr word, selected, Nat.not_le.mpr indexBound,
    Nat.not_le.mpr baseBound, Nat.not_le.mpr biasBound, suffixOffsetValue_normalize word]

structure SlicePlace where
  path : Path
  start : Nat
  stop : Nat
  deriving DecidableEq

def borrowSlice (path : Path) (capacity start stop : Nat) : Except ViewFault SlicePlace :=
  if start ≤ stop ∧ stop ≤ capacity then .ok ⟨path, start, stop⟩ else .error .bounds

theorem borrowSlice_bounds (success : borrowSlice path capacity start stop = .ok place) :
    place.path = path ∧ place.start = start ∧ place.stop = stop ∧
      start ≤ stop ∧ stop ≤ capacity := by
  unfold borrowSlice at success
  split at success
  · cases success
    exact ⟨rfl, rfl, rfl, by assumption⟩
  · cases success

theorem suffix_borrow_success
    (offsetOk : suffixOffset program bits state first = .ok offset)
    (lengthOk : state.lengths program.lengthPath ≤ capacity) :
    borrowSlice path capacity offset (state.lengths program.lengthPath) =
      .ok ⟨path, offset, state.lengths program.lengthPath⟩ := by
  simp [borrowSlice, suffixOffset_bounded offsetOk, lengthOk]

structure SharedSuffixProgram where
  offset : SuffixOffsetProgram
  copiedPath : Path
  optionalPath : Path
  slotsPath : Path
  outputFields : List String

structure SharedSuffixStore (α : Type) where
  view : SuffixViewStore
  copied : Path → α
  capacities : Path → Nat

structure SharedSuffixResult (α : Type) where
  copied : α
  optional : Option Path
  first : Option Nat
  slice : SlicePlace
  outputFields : List String

def sharedSuffix (program : SharedSuffixProgram) (bits : Nat)
    (state : SharedSuffixStore α) (first : Option Nat) (changed : Bool) :
    Except ViewFault (SharedSuffixResult α) := do
  let start ← suffixOffset program.offset bits state.view first
  let slice ← borrowSlice program.slotsPath (state.capacities program.slotsPath)
    start (state.view.lengths program.offset.lengthPath)
  pure ⟨state.copied program.copiedPath,
    if changed && (state.view.records program.optionalPath).isSome then
      some program.optionalPath else none,
    first, slice, program.outputFields⟩

theorem sharedSuffix_success
    (offsetOk : suffixOffset program.offset bits state.view first = .ok start)
    (capacityOk : state.view.lengths program.offset.lengthPath ≤ state.capacities program.slotsPath) :
    sharedSuffix program bits state first changed = .ok
      ⟨state.copied program.copiedPath,
       if changed && (state.view.records program.optionalPath).isSome then some program.optionalPath else none,
       first, ⟨program.slotsPath, start, state.view.lengths program.offset.lengthPath⟩, program.outputFields⟩ := by
  simp only [sharedSuffix, offsetOk]
  change (do
    let slice ← borrowSlice program.slotsPath (state.capacities program.slotsPath)
      start (state.view.lengths program.offset.lengthPath)
    pure _) = _
  rw [suffix_borrow_success offsetOk capacityOk]
  rfl

structure RecordLookup where
  slotsPath : Path
  base : RecordSelection
  baseField : Path
  bias : Nat
structure LookupStore (α : Type) where
  records : SelectionStore
  slots : Path → List (Option α)
structure ReadPlace where
  path : Path
  index : Nat
  deriving DecidableEq
inductive LookupFault where
  | input
  deriving DecidableEq

def lookupRecord (program : RecordLookup) (bits : Nat) (state : LookupStore α) (index : Nat) :
    Except LookupFault (Option ReadPlace) :=
  match selectRecord program.base state.records program.baseField with
  | .unsigned rustType base =>
    if rustType ≠ "u64" ∨ index ≥ 2^64 ∨ base ≥ 2^64 ∨ program.bias ≥ 2^64 then .error .input
    else if index < base then .ok none
    else if index - base < program.bias then .ok none
    else
      let offset := index - base - program.bias
      if offset ≥ 2^bits then .ok none
      else match (state.slots program.slotsPath)[offset]? with
        | some (some _) => .ok (some ⟨program.slotsPath, offset⟩)
        | _ => .ok none
  | _ => .error .input
structure RecordAt where
  lookup : RecordLookup
  guardField : Path
  equal : Bool
  recordField : Path

def recordAt (program : RecordAt) (bits : Nat) (state : LookupStore (Path → InitStore)) (index : Nat) :
    Except LookupFault (Option InitStore) :=
  let boundary := selectRecord program.lookup.base state.records
  match boundary program.guardField with
  | .unsigned rustType base =>
    if rustType ≠ "u64" ∨ index ≥ 2^64 ∨ base ≥ 2^64 then .error .input
    else if (decide (index = base)) == program.equal then .ok (some boundary)
    else match lookupRecord program.lookup bits state index with
      | .error error => .error error
      | .ok none => .ok none
      | .ok (some place) =>
        match (state.slots place.path)[place.index]? with
        | some (some entry) => .ok (some (entry program.recordField))
        | _ => .error .input
  | _ => .error .input
structure Iteration where
  slotsPath : Path
  lengthPath : Path
  inclusive : Bool
  whole : Bool
structure TraversalStore (α : Type) where
  lookups : LookupStore α
  lengths : Path → Nat
inductive TraversalFault where
  | bounds
  | input
  deriving DecidableEq

def presentPlaces (path : Path) : Nat → List (Option α) → List ReadPlace
  | _, [] => []
  | index, none :: rest => presentPlaces path (index + 1) rest
  | index, some _ :: rest => ⟨path, index⟩ :: presentPlaces path (index + 1) rest

def iterateRecords (program : Iteration) (state : TraversalStore α) :
    Except TraversalFault (List ReadPlace) :=
  let slots := state.lookups.slots program.slotsPath
  let count := if program.whole then slots.length
    else state.lengths program.lengthPath + (if program.inclusive then 1 else 0)
  if count ≤ slots.length then .ok (presentPlaces program.slotsPath 0 (slots.take count))
  else .error .bounds
-- A borrowed slice has local iterator coordinates. Relating those coordinates
-- to its originating array preserves holes and payload identity without copying
-- payloads in Rust. Physical reference/lifetime refinement is still separate.
def sliceContents (place : SlicePlace) (slots : List (Option α)) : List (Option α) :=
  (slots.drop place.start).take (place.stop - place.start)

def sliceTraversal (field : Path) (place : SlicePlace) (slots : List (Option α)) :
    TraversalStore α :=
  ⟨⟨fun _ => none, fun key => if key = field then sliceContents place slots else []⟩,
    fun _ => 0⟩

def rebasePlace (origin : SlicePlace) (relative : ReadPlace) : ReadPlace :=
  ⟨origin.path, origin.start + relative.index⟩

theorem sliceContents_length (lower : place.start ≤ place.stop)
    (upper : place.stop ≤ slots.length) :
    (sliceContents place slots).length = place.stop - place.start := by
  simp only [sliceContents, List.length_take, List.length_drop]
  omega

theorem presentPlaces_rebase (origin : SlicePlace) (field : Path)
    (slots : List (Option α)) (index : Nat) :
    (presentPlaces field index slots).map (rebasePlace origin) =
      presentPlaces origin.path (origin.start + index) slots := by
  induction slots generalizing index with
  | nil => rfl
  | cons head tail ih =>
    cases head <;> simp [presentPlaces, rebasePlace, ih, Nat.add_assoc]

theorem iterateWholeSlice (field : Path) (place : SlicePlace) (slots : List (Option α)) :
    iterateRecords ⟨field, [], false, true⟩ (sliceTraversal field place slots) =
      .ok (presentPlaces field 0 (sliceContents place slots)) := by
  simp [iterateRecords, sliceTraversal]

theorem iterateWholeSlice_rebased (field : Path) (place : SlicePlace)
    (slots : List (Option α)) :
    (iterateRecords ⟨field, [], false, true⟩ (sliceTraversal field place slots)).map
      (List.map (rebasePlace place)) =
      .ok (presentPlaces place.path place.start (sliceContents place slots)) := by
  rw [iterateWholeSlice]
  change Except.ok ((presentPlaces field 0 (sliceContents place slots)).map (rebasePlace place)) = _
  rw [presentPlaces_rebase]
  simp

def loadPlaces (load : ReadPlace → Option α) : List ReadPlace → Option (List α)
  | [] => some []
  | head :: tail => do
    let value ← load head
    let rest ← loadPlaces load tail
    pure (value :: rest)

-- Reading a sequence of valid borrowed locations yields exactly the original
-- occupied payloads, in order; a bad location fails instead of disappearing.
theorem load_presentPlaces (path : Path) (slots : List (Option α)) (start : Nat)
    (load : ReadPlace → Option α)
    (valid : ∀ i, i < slots.length → load ⟨path, start + i⟩ = slots[i]?.join) :
    loadPlaces load (presentPlaces path start slots) = some (slots.filterMap id) := by
  induction slots generalizing start with
  | nil => rfl
  | cons head tail ih =>
    have restValid : ∀ i, i < tail.length → load ⟨path, start + 1 + i⟩ = tail[i]?.join := by
      intro i bound
      have h := valid (i + 1) (by simp; omega)
      simpa [Nat.add_assoc, Nat.add_comm, Nat.add_left_comm] using h
    cases head with
    | none =>
      simpa [presentPlaces] using ih (start + 1) restValid
    | some value =>
      have first := valid 0 (by simp)
      simp at first
      simp only [presentPlaces, loadPlaces, first]
      change (do let rest ← loadPlaces load (presentPlaces path (start + 1) tail)
                 pure (value :: rest)) = _
      rw [ih (start + 1) restValid]
      rfl

def loadFrom (path : Path) (slots : List (Option α)) (place : ReadPlace) : Option α :=
  if place.path = path then slots[place.index]?.join else none

theorem load_sliceContents (place : SlicePlace) (slots : List (Option α)) :
    loadPlaces (loadFrom place.path slots)
      (presentPlaces place.path place.start (sliceContents place slots)) =
      some ((sliceContents place slots).filterMap id) := by
  apply load_presentPlaces
  intro i bound
  have below : i < place.stop - place.start := by
    simp only [sliceContents, List.length_take, List.length_drop] at bound
    omega
  simp only [loadFrom, sliceContents]
  rw [List.getElem?_take_of_lt below, List.getElem?_drop]
  simp

structure LastRecord where
  iteration : Iteration
  base : RecordSelection
  recordField : Path
  fromBack : Bool

def lastRecord (program : LastRecord) (state : TraversalStore (Path → InitStore)) :
    Except TraversalFault InitStore :=
  match iterateRecords program.iteration state with
  | .error error => .error error
  | .ok places =>
    let fallback := selectRecord program.base state.lookups.records
    match (if program.fromBack then places.getLast? else places.head?) with
    | none => .ok fallback
    | some place => match (state.lookups.slots place.path)[place.index]? with
      | some (some entry) => .ok (entry program.recordField)
      | _ => .error .input
-- A record view reads metadata without consuming, copying or identifying the
-- opaque application payload. Correspondence of this view with Rust memory is
-- an explicit remaining frontend obligation.
structure Truncation where
  slotsPath : Path
  lengthPath : Path
  last : LastRecord
  indexField : Path
  inclusive : Bool
inductive TruncationFault where
  | read (reason : TraversalFault)
  | input
  | bounds
  | exhausted
  deriving DecidableEq
inductive TruncationRun (α : Type) where
  | returned (state : BufferState α)
  | fault (reason : TruncationFault) (state : BufferState α)
  | drop (payload : α) (before : BufferState α) (continuation : TruncationRun α)

def truncationView (view : α → Path → InitStore) (records : SelectionStore)
    (state : BufferState α) : TraversalStore (Path → InitStore) :=
  ⟨⟨records, fun _ => state.slots.map (Option.map view)⟩, fun _ => state.len⟩
-- Fuel is internal, bounded by the initial length plus the final condition
-- read. Every body execution decreases length by one. Exhaustion is exposed,
-- not silently reported as a successful return.
def truncationCompare (inclusive : Bool) (index boundary : Nat) : Prop :=
  if inclusive then index ≥ boundary else index > boundary
instance (inclusive : Bool) (index boundary : Nat) : Decidable (truncationCompare inclusive index boundary) := by
  unfold truncationCompare
  infer_instance

def truncateSteps (program : Truncation) (view : α → Path → InitStore)
    (records : SelectionStore) (boundary : Nat) : Nat → BufferState α → TruncationRun α
  | 0, state => .fault .exhausted state
  | fuel + 1, state =>
    match lastRecord program.last (truncationView view records state) with
    | .error reason => .fault (.read reason) state
    | .ok record => match record program.indexField with
      | .unsigned rustType index =>
        if rustType ≠ "u64" ∨ index ≥ 2^64 ∨ boundary ≥ 2^64 then .fault .input state
        else if truncationCompare program.inclusive index boundary ∧ state.len > 0 then
          let decreased := {state with len := state.len - 1}
          match state.slots[decreased.len]? with
          | none => .fault .bounds decreased
          | some previous =>
            let cleared := {decreased with slots := state.slots.set decreased.len none}
            let next := truncateSteps program view records boundary fuel cleared
            match previous with
            | none => next
            | some payload => .drop payload decreased next
        else .returned state
      | _ => .fault .input state

def truncateBuffer (program : Truncation) (view : α → Path → InitStore)
    (records : SelectionStore) (state : BufferState α) (boundary : Nat) : TruncationRun α :=
  truncateSteps program view records boundary (state.len + 1) state

def resumeTruncation : TruncationRun α → TruncationRun α
  | .drop _ _ next => resumeTruncation next
  | result => result

structure Installation where
  slotsPath : Path
  lengthPath : Path
  snapshotPath : Path
  commitPath : Path
  recordAt : RecordAt
  recordField : Path
  indexField : Path
  baseIndexField : Path
  commitIndexField : Path
  equalityFields : List Path
  equal : Bool
  rotateLeft : Bool
  maximum : Bool
structure InstallationState (α β : Type) where
  buffer : BufferState α
  commit : Nat
  snapshot : Option β
inductive InstallationFault where
  | input
  | lookup
  | subtraction
  | bounds
  deriving DecidableEq
-- Faults stop before unwinding and retain ownership of the pending input.
-- Drop continuations are conditional on normal consumer destructor return.
inductive InstallationRun (α β : Type) where
  | returned (state : InstallationState α β)
  | fault (reason : InstallationFault) (state : InstallationState α β) (input : β)
  | dropEntry (payload : α) (before : InstallationState α β) (input : β) (next : InstallationRun α β)
  | dropSnapshot (payload : β) (before : InstallationState α β) (input : β) (next : InstallationRun α β)

def recordWord (record : InitStore) (field : Path) : Option Nat :=
  match record field with
  | .unsigned ty value => if ty = "u64" ∧ value < 2^64 then some value else none
  | _ => none

def recordWords (record : InitStore) : List Path → Option (List Nat)
  | [] => some []
  | field :: rest => do
    let value ← recordWord record field
    let tail ← recordWords record rest
    pure (value :: tail)

def recordEquality (found : Option InitStore) (record : InitStore) (fields : List Path) : Option Bool :=
  match found with
  | none => some false
  | some existing => do
    let left ← recordWords existing fields
    let right ← recordWords record fields
    pure (left == right)

def installationView (view : α → Path → InitStore) (snapshotView : β → Path → InitStore)
    (state : InstallationState α β) : LookupStore (Path → InitStore) :=
  ⟨fun _ => state.snapshot.map snapshotView,fun _ => state.buffer.slots.map (Option.map view)⟩

def finishInstallation (program : Installation) (snapshotView : β → Path → InitStore)
    (state : InstallationState α β) (input : β) : InstallationRun α β :=
  match recordWord (snapshotView input program.recordField) program.commitIndexField with
  | none => .fault .input state input
  | some index =>
    if state.commit ≥ 2^64 then .fault .input state input else
    let committed := {state with commit := if program.maximum then max state.commit index else min state.commit index}
    let next := InstallationRun.returned {committed with snapshot := some input}
    match state.snapshot with
    | none => next
    | some previous => .dropSnapshot previous committed input next

def clearInstallation (program : Installation) (snapshotView : β → Path → InitStore)
    (resetLength : Bool) (input : β) : Nat → Nat → InstallationState α β → InstallationRun α β
  | _, 0, state =>
    finishInstallation program snapshotView
      (if resetLength then {state with buffer.len := 0} else state) input
  | index, count + 1, state =>
    match state.buffer.slots[index]? with
    | none => .fault .bounds state input
    | some previous =>
      let cleared := {state with buffer.slots := state.buffer.slots.set index none}
      let next := clearInstallation program snapshotView resetLength input (index + 1) count cleared
      match previous with
      | none => next
      | some payload => .dropEntry payload state input next

def installSnapshot (program : Installation) (bits : Nat)
    (view : α → Path → InitStore) (snapshotView : β → Path → InitStore)
    (state : InstallationState α β) (input : β) : InstallationRun α β :=
  let record := snapshotView input program.recordField
  let projected := installationView view snapshotView state
  match recordWord record program.indexField with
  | none => .fault .input state input
  | some index => match recordAt program.recordAt bits projected index with
    | .error _ => .fault .lookup state input
    | .ok found =>
      let equality := recordEquality found record program.equalityFields
      match equality with
      | none => .fault .input state input
      | some equal => if equal == program.equal then
          match recordWord (selectRecord program.recordAt.lookup.base projected.records) program.baseIndexField with
          | none => .fault .input state input
          | some base =>
            if index < base then .fault .subtraction state input else
            let remove := (index - base) % 2^bits
            if state.buffer.len > state.buffer.slots.length ∨ remove > state.buffer.len then
              .fault .bounds state input
            else
              let retained := state.buffer.slots.take state.buffer.len
              let amount := if program.rotateLeft then remove else state.buffer.len - remove
              let rotated := retained.drop amount ++ retained.take amount ++ state.buffer.slots.drop state.buffer.len
              let shifted := {state with buffer := ⟨rotated,state.buffer.len - remove⟩}
              clearInstallation program snapshotView false input shifted.buffer.len
                (rotated.length - shifted.buffer.len) shifted
        else
          if state.buffer.len > state.buffer.slots.length then .fault .bounds state input
          else clearInstallation program snapshotView true input 0 state.buffer.len state

def resumeInstallation : InstallationRun α β → InstallationRun α β
  | .dropEntry _ _ _ next => resumeInstallation next
  | .dropSnapshot _ _ _ next => resumeInstallation next
  | result => result

inductive RecoveryValue where
  | constant (value : Nat)
  | hard (path : Path)
  | base (path : Path)
  | last (path : Path)
  | entry (path : Path)
  | callLast (path : Path)
inductive RecoveryPredicate where
  | boolean (value : Bool)
  | and (left right : RecoveryPredicate)
  | or (left right : RecoveryPredicate)
  | compare (operation : String) (left right : RecoveryValue)
  | checkedCompare (equal : Bool) (left : RecoveryValue) (increment : Nat) (right : RecoveryValue)
  | snapshotPresent
  | hardPresent (path : Path)
structure Restoration where
  constructorFields : List InitField
  append : BufferAppend
  last : LastRecord
  hardPath : Path
  snapshotPath : Path
  initialGuard : RecoveryPredicate
  entryGuard : RecoveryPredicate
  finalGuard : RecoveryPredicate
  error : String
  snapshotFirst : Bool
structure RecoveryState (α β δ : Type) where
  buffer : BufferState α
  hard : δ
  snapshot : Option β
structure RecoveryContext (α β δ : Type) where
  state : RecoveryState α β δ
  base : InitStore
  last : InitStore
  entry : InitStore
inductive RecoveryReadFault where
  | input
  | read (reason : TraversalFault)
inductive RecoveryFault where
  | evaluation (reason : RecoveryReadFault)
  | append (reason : BufferFault)
  | exhausted

def recoveryRecords (snapshotView : β → Path → InitStore) (state : RecoveryState α β δ) : SelectionStore :=
  fun _ => state.snapshot.map snapshotView

def recoveryLast (program : Restoration) (view : α → Path → InitStore)
    (snapshotView : β → Path → InitStore) (state : RecoveryState α β δ) : Except RecoveryReadFault InitStore :=
  match lastRecord program.last (truncationView view (recoveryRecords snapshotView state) state.buffer) with
  | .ok record => .ok record
  | .error reason => .error (.read reason)

def recoveryValue (program : Restoration) (view : α → Path → InitStore)
    (snapshotView : β → Path → InitStore) (hardView : δ → InitStore)
    (context : RecoveryContext α β δ) (value : RecoveryValue) : Except RecoveryReadFault Nat := do
  let selected ← match value with
    | .constant n => if n < 2^64 then .ok (some n) else .error .input
    | .hard path => .ok (recordWord (hardView context.state.hard) path)
    | .base path => .ok (recordWord context.base path)
    | .last path => .ok (recordWord context.last path)
    | .entry path => .ok (recordWord context.entry path)
    | .callLast path => do
      let record ← recoveryLast program view snapshotView context.state
      pure (recordWord record path)
  match selected with
  | some n => .ok n
  | none => .error .input

def recoveryPredicate (program : Restoration) (view : α → Path → InitStore)
    (snapshotView : β → Path → InitStore) (hardView : δ → InitStore) (hardPresence : δ → Path → Bool)
    (context : RecoveryContext α β δ) : RecoveryPredicate → Except RecoveryReadFault Bool
  | .boolean b => .ok b
  | .and first second => do
    let left ← recoveryPredicate program view snapshotView hardView hardPresence context first
    if left then recoveryPredicate program view snapshotView hardView hardPresence context second else .ok false
  | .or first second => do
    let left ← recoveryPredicate program view snapshotView hardView hardPresence context first
    if left then .ok true else recoveryPredicate program view snapshotView hardView hardPresence context second
  | .snapshotPresent => .ok context.state.snapshot.isSome
  | .hardPresent path => .ok (hardPresence context.state.hard path)
  | .compare operation first second => do
    let left ← recoveryValue program view snapshotView hardView context first
    let right ← recoveryValue program view snapshotView hardView context second
    match operation with
    | "eq" => .ok (decide (left = right))
    | "ne" => .ok (decide (left ≠ right))
    | "lt" => .ok (decide (left < right))
    | "le" => .ok (decide (left ≤ right))
    | "gt" => .ok (decide (left > right))
    | "ge" => .ok (decide (left ≥ right))
    | _ => .error .input
  | .checkedCompare equal first increment second => do
    let left ← recoveryValue program view snapshotView hardView context first
    if increment ≥ 2^64 then .error .input else
    let right ← recoveryValue program view snapshotView hardView context second
    let sum := if left + increment < 2^64 then some (left + increment) else none
    .ok ((sum == some right) == equal)

-- Opaque source and iterator handles have separate ownership. Each callback may
-- fail to return; following its continuation is an explicit environment action.
inductive RecoveryRun (α β δ σ ι : Type) where
  | returned (result : Except String (RecoveryState α β δ))
  | invalidRepresentation (hard : δ) (snapshot : Option β) (source : σ)
  | fault (reason : RecoveryFault) (state : RecoveryState α β δ)
      (entry : Option α) (source : Option σ) (iterator : Option ι)
  | intoIterator (source : σ) (state : RecoveryState α β δ) (next : ι → RecoveryRun α β δ σ ι)
  | next (iterator : ι) (state : RecoveryState α β δ) (resume : Option α → ι → RecoveryRun α β δ σ ι)
  | dropEntry (payload : α) (next : RecoveryRun α β δ σ ι)
  | dropSnapshot (payload : β) (next : RecoveryRun α β δ σ ι)
  | dropSource (source : σ) (next : RecoveryRun α β δ σ ι)
  | dropIterator (iterator : ι) (next : RecoveryRun α β δ σ ι)

def dropRecoveryEntries (entries : List (Option α)) (next : RecoveryRun α β δ σ ι) : RecoveryRun α β δ σ ι :=
  match entries with
  | [] => next
  | none :: rest => dropRecoveryEntries rest next
  | some payload :: rest => .dropEntry payload (dropRecoveryEntries rest next)

def dropRecoverySnapshot (snapshot : Option β) (next : RecoveryRun α β δ σ ι) : RecoveryRun α β δ σ ι :=
  match snapshot with
  | none => next
  | some payload => .dropSnapshot payload next

def dropRecoveryState (program : Restoration) (state : RecoveryState α β δ)
    (next : RecoveryRun α β δ σ ι) : RecoveryRun α β δ σ ι :=
  if program.snapshotFirst then
    dropRecoverySnapshot state.snapshot (dropRecoveryEntries state.buffer.slots next)
  else dropRecoveryEntries state.buffer.slots (dropRecoverySnapshot state.snapshot next)

def recoveryFinish (program : Restoration) (view : α → Path → InitStore)
    (snapshotView : β → Path → InitStore) (hardView : δ → InitStore) (hardPresence : δ → Path → Bool)
    (state : RecoveryState α β δ) (base : InitStore) : RecoveryRun α β δ σ ι :=
  match recoveryPredicate program view snapshotView hardView hardPresence
      ⟨state,base,(fun _ => .absent),(fun _ => .absent)⟩ program.finalGuard with
  | .error reason => .fault (.evaluation reason) state none none none
  | .ok true => dropRecoveryState program state (.returned (.error program.error))
  | .ok false => .returned (.ok state)

def recoveryAppend (program : Restoration) (state : RecoveryState α β δ) (iterator : ι)
    (resume : RecoveryState α β δ → RecoveryRun α β δ σ ι) : BufferRun α → RecoveryRun α β δ σ ι
  | .returned (.ok ()) next => resume {state with buffer := next}
  | .returned (.error error) next =>
    .dropIterator iterator (dropRecoveryState program {state with buffer := next} (.returned (.error error)))
  | .fault reason next => .fault (.append reason) {state with buffer := next} none none (some iterator)
  | .drop payload _ next => .dropEntry payload (recoveryAppend program state iterator resume next)

def recoveryLoop (program : Restoration) (bits capacity : Nat) (view : α → Path → InitStore)
    (snapshotView : β → Path → InitStore) (hardView : δ → InitStore) (hardPresence : δ → Path → Bool)
    (base : InitStore) : Nat → RecoveryState α β δ → ι → RecoveryRun α β δ σ ι
  | 0, state, iterator => .fault .exhausted state none none (some iterator)
  | fuel + 1, state, iterator => .next iterator state fun response iterator =>
    match response with
    | none => .dropIterator iterator (recoveryFinish program view snapshotView hardView hardPresence state base)
    | some entry => match recoveryLast program view snapshotView state with
      | .error reason => .fault (.evaluation reason) state (some entry) none (some iterator)
      | .ok last =>
        match recoveryPredicate program view snapshotView hardView hardPresence
            ⟨state,base,last,view entry program.last.recordField⟩ program.entryGuard with
        | .error reason => .fault (.evaluation reason) state (some entry) none (some iterator)
        | .ok true => .dropEntry entry (.dropIterator iterator
            (dropRecoveryState program state (.returned (.error program.error))))
        | .ok false => recoveryAppend program state iterator
            (fun next => recoveryLoop program bits capacity view snapshotView hardView hardPresence base fuel next iterator)
            (appendBuffer program.append bits capacity state.buffer entry)

def restoreState (program : Restoration) (bits : Nat) (sizes : String → Nat)
    (view : α → Path → InitStore) (snapshotView : β → Path → InitStore)
    (hardView : δ → InitStore) (hardPresence : δ → Path → Bool)
    (hard : δ) (snapshot : Option β) (source : σ) : RecoveryRun α β δ σ ι :=
  let initial := initializeFields program.constructorFields sizes
  match initial program.append.slotsPath,initial program.append.lengthPath with
  | .slots slots,.unsigned ty length =>
    if ty ≠ "usize" ∨ length ≥ 2^bits ∨ ¬ slots.all Option.isNone then
      .invalidRepresentation hard snapshot source
    else
      let state : RecoveryState α β δ := ⟨⟨slots.map (fun _ => none),length⟩,hard,snapshot⟩
      let base := selectRecord program.last.base (recoveryRecords snapshotView state)
      match recoveryPredicate program view snapshotView hardView hardPresence
          ⟨state,base,(fun _ => .absent),(fun _ => .absent)⟩ program.initialGuard with
      | .error reason => .fault (.evaluation reason) state none (some source) none
      | .ok true => dropRecoveryState program state (.dropSource source (.returned (.error program.error)))
      | .ok false => .intoIterator source state fun iterator =>
        recoveryLoop program bits (sizes program.append.capacityName) view snapshotView hardView hardPresence base
          (sizes program.append.capacityName + 1) state iterator
  | _,_ => .invalidRepresentation hard snapshot source

-- A finite execution in which the invoked consumer callbacks return normally.
-- The response values remain arbitrary; no particular iterator implementation,
-- ordered input, finite source collection or infallible callback is assumed.
inductive RecoveryReturns : RecoveryRun α β δ σ ι → Except String (RecoveryState α β δ) → Prop where
  | returned (result) : RecoveryReturns (.returned result) result
  | intoIterator (source state next iterator result) :
      RecoveryReturns (next iterator) result → RecoveryReturns (.intoIterator source state next) result
  | next (iterator state resume entry advanced result) :
      RecoveryReturns (resume entry advanced) result → RecoveryReturns (.next iterator state resume) result
  | dropEntry (payload next result) : RecoveryReturns next result → RecoveryReturns (.dropEntry payload next) result
  | dropSnapshot (payload next result) : RecoveryReturns next result → RecoveryReturns (.dropSnapshot payload next) result
  | dropSource (source next result) : RecoveryReturns next result → RecoveryReturns (.dropSource source next) result
  | dropIterator (iterator next result) : RecoveryReturns next result → RecoveryReturns (.dropIterator iterator next) result

@[simp] theorem recovery_returns_returned (a b : Except String (RecoveryState α β δ)) :
    RecoveryReturns (RecoveryRun.returned a : RecoveryRun α β δ σ ι) b ↔ a = b := by
  constructor
  · intro execution
    cases execution
    rfl
  · intro equal
    cases equal
    exact .returned _
@[simp] theorem recovery_returns_fault (reason : RecoveryFault) (state : RecoveryState α β δ)
    (entry : Option α) (source : Option σ) (iterator : Option ι) (result) :
    ¬ RecoveryReturns (.fault reason state entry source iterator) result := by
  intro execution
  cases execution
@[simp] theorem recovery_returns_invalid (hard : δ) (snapshot : Option β) (source : σ) (result) :
    ¬ RecoveryReturns (RecoveryRun.invalidRepresentation hard snapshot source : RecoveryRun α β δ σ ι) result := by
  intro execution
  cases execution
@[simp] theorem recovery_returns_dropEntry (payload : α) (next : RecoveryRun α β δ σ ι) (result) :
    RecoveryReturns (.dropEntry payload next) result ↔ RecoveryReturns next result := by
  constructor
  · intro execution
    cases execution
    assumption
  · exact .dropEntry payload next result
@[simp] theorem recovery_returns_dropSnapshot (payload : β) (next : RecoveryRun α β δ σ ι) (result) :
    RecoveryReturns (.dropSnapshot payload next) result ↔ RecoveryReturns next result := by
  constructor
  · intro execution
    cases execution
    assumption
  · exact .dropSnapshot payload next result
@[simp] theorem recovery_returns_dropSource (source : σ) (next : RecoveryRun α β δ σ ι) (result) :
    RecoveryReturns (.dropSource source next) result ↔ RecoveryReturns next result := by
  constructor
  · intro execution
    cases execution
    assumption
  · exact .dropSource source next result
@[simp] theorem recovery_returns_dropIterator (iterator : ι) (next : RecoveryRun α β δ σ ι) (result) :
    RecoveryReturns (.dropIterator iterator next) result ↔ RecoveryReturns next result := by
  constructor
  · intro execution
    cases execution
    assumption
  · exact .dropIterator iterator next result
@[simp] theorem recovery_returns_dropEntries (entries : List (Option α)) (next : RecoveryRun α β δ σ ι) (result) :
    RecoveryReturns (dropRecoveryEntries entries next) result ↔ RecoveryReturns next result := by
  induction entries with
  | nil => rfl
  | cons entry rest ih => cases entry <;> simp [dropRecoveryEntries,ih]
@[simp] theorem recovery_returns_dropSaved (snapshot : Option β) (next : RecoveryRun α β δ σ ι) (result) :
    RecoveryReturns (dropRecoverySnapshot snapshot next) result ↔ RecoveryReturns next result := by
  cases snapshot <;> simp [dropRecoverySnapshot]
@[simp] theorem recovery_returns_dropState (program : Restoration) (state : RecoveryState α β δ)
    (next : RecoveryRun α β δ σ ι) (result) :
    RecoveryReturns (dropRecoveryState program state next) result ↔ RecoveryReturns next result := by
  unfold dropRecoveryState
  split <;> simp
@[simp] theorem recovery_returns_intoIterator (source : σ) (state : RecoveryState α β δ)
    (next : ι → RecoveryRun α β δ σ ι) (result) :
    RecoveryReturns (.intoIterator source state next) result ↔ ∃ iterator, RecoveryReturns (next iterator) result := by
  constructor
  · intro execution
    cases execution
    rename_i iterator execution
    exact ⟨iterator,execution⟩
  · rintro ⟨iterator,execution⟩
    exact .intoIterator source state next iterator result execution
@[simp] theorem recovery_returns_next (iterator : ι) (state : RecoveryState α β δ)
    (resume : Option α → ι → RecoveryRun α β δ σ ι) (result) :
    RecoveryReturns (.next iterator state resume) result ↔
      ∃ entry advanced, RecoveryReturns (resume entry advanced) result := by
  constructor
  · intro execution
    cases execution
    rename_i entry advanced execution
    exact ⟨entry,advanced,execution⟩
  · rintro ⟨entry,advanced,execution⟩
    exact .next iterator state resume entry advanced result execution

theorem recovery_append_success (program : Restoration) (state output : RecoveryState α β δ) (iterator : ι)
    (resume : RecoveryState α β δ → RecoveryRun α β δ σ ι) (run : BufferRun α)
    (execution : RecoveryReturns (recoveryAppend program state iterator resume run) (.ok output)) :
    ∃ buffer, resumeDrops run = .returned (.ok ()) buffer ∧
      RecoveryReturns (resume {state with buffer := buffer}) (.ok output) := by
  induction run with
  | returned result buffer =>
    cases result with
    | ok value => cases value; exact ⟨buffer,rfl,execution⟩
    | error error => simp [recoveryAppend] at execution
  | fault reason buffer => simp [recoveryAppend] at execution
  | drop payload before next ih =>
    simp only [recoveryAppend,recovery_returns_dropEntry] at execution
    obtain ⟨buffer,returned,continued⟩ := ih execution
    exact ⟨buffer,returned,continued⟩

theorem recovery_finish_success (program : Restoration) (view : α → Path → InitStore)
    (snapshotView : β → Path → InitStore) (hardView : δ → InitStore) (hardPresence : δ → Path → Bool)
    (state output : RecoveryState α β δ) (base : InitStore)
    (execution : RecoveryReturns (recoveryFinish program view snapshotView hardView hardPresence state base : RecoveryRun α β δ σ ι) (.ok output)) :
    state = output ∧ recoveryPredicate program view snapshotView hardView hardPresence
      ⟨state,base,(fun _ => .absent),(fun _ => .absent)⟩ program.finalGuard = .ok false := by
  cases decision : recoveryPredicate program view snapshotView hardView hardPresence
      ⟨state,base,(fun _ => .absent),(fun _ => .absent)⟩ program.finalGuard with
  | error reason => simp [recoveryFinish,decision] at execution
  | ok rejected =>
    cases rejected
    · simp only [recoveryFinish,decision,recovery_returns_returned,Except.ok.injEq] at execution
      exact ⟨execution,rfl⟩
    · simp [recoveryFinish,decision] at execution

-- No interpreter-fuel exhaustion on any branch, including every possible normal
-- callback response. Other faults are deliberately not conflated with exhaustion.
def recoveryFuelSafe : RecoveryRun α β δ σ ι → Prop
  | .returned _ => True
  | .invalidRepresentation _ _ _ => True
  | .fault reason _ _ _ _ => match reason with | .exhausted => False | _ => True
  | .intoIterator _ _ next => ∀ iterator, recoveryFuelSafe (next iterator)
  | .next _ _ resume => ∀ entry advanced, recoveryFuelSafe (resume entry advanced)
  | .dropEntry _ next => recoveryFuelSafe next
  | .dropSnapshot _ next => recoveryFuelSafe next
  | .dropSource _ next => recoveryFuelSafe next
  | .dropIterator _ next => recoveryFuelSafe next
@[simp] theorem recovery_fuel_drop_entries (entries : List (Option α)) (next : RecoveryRun α β δ σ ι) :
    recoveryFuelSafe (dropRecoveryEntries entries next) ↔ recoveryFuelSafe next := by
  induction entries with
  | nil => rfl
  | cons entry rest ih => cases entry <;> simp [dropRecoveryEntries,recoveryFuelSafe,ih]
@[simp] theorem recovery_fuel_drop_saved (snapshot : Option β) (next : RecoveryRun α β δ σ ι) :
    recoveryFuelSafe (dropRecoverySnapshot snapshot next) ↔ recoveryFuelSafe next := by
  cases snapshot <;> simp [dropRecoverySnapshot,recoveryFuelSafe]
@[simp] theorem recovery_fuel_drop_state (program : Restoration) (state : RecoveryState α β δ)
    (next : RecoveryRun α β δ σ ι) :
    recoveryFuelSafe (dropRecoveryState program state next) ↔ recoveryFuelSafe next := by
  unfold dropRecoveryState
  split <;> simp

theorem recovery_finish_fuel_safe (program : Restoration) (view : α → Path → InitStore)
    (snapshotView : β → Path → InitStore) (hardView : δ → InitStore) (hardPresence : δ → Path → Bool)
    (state : RecoveryState α β δ) (base : InitStore) :
    recoveryFuelSafe (recoveryFinish program view snapshotView hardView hardPresence state base : RecoveryRun α β δ σ ι) := by
  unfold recoveryFinish
  split <;> simp [recoveryFuelSafe]

theorem recovery_loop_final_guard (program : Restoration) (bits capacity fuel : Nat)
    (view : α → Path → InitStore) (snapshotView : β → Path → InitStore)
    (hardView : δ → InitStore) (hardPresence : δ → Path → Bool) (base : InitStore)
    (state output : RecoveryState α β δ) (iterator : ι)
    (execution : RecoveryReturns (recoveryLoop program bits capacity view snapshotView hardView hardPresence base fuel state iterator : RecoveryRun α β δ σ ι) (.ok output)) :
    recoveryPredicate program view snapshotView hardView hardPresence
      ⟨output,base,(fun _ => .absent),(fun _ => .absent)⟩ program.finalGuard = .ok false := by
  induction fuel generalizing state iterator with
  | zero => simp [recoveryLoop] at execution
  | succ fuel ih =>
    simp only [recoveryLoop,recovery_returns_next] at execution
    obtain ⟨entry,advanced,execution⟩ := execution
    cases entry with
    | none =>
      simp only [recovery_returns_dropIterator] at execution
      obtain ⟨same,decision⟩ := recovery_finish_success program view snapshotView hardView hardPresence state output base execution
      cases same
      exact decision
    | some entry =>
      dsimp only at execution
      split at execution
      · simp at execution
      · split at execution
        · simp at execution
        · simp at execution
        · obtain ⟨buffer,_,continued⟩ := recovery_append_success program state output advanced _ _ execution
          exact ih {state with buffer := buffer} advanced continued

theorem recovery_or_false (program : Restoration) (view : α → Path → InitStore)
    (snapshotView : β → Path → InitStore) (hardView : δ → InitStore) (hardPresence : δ → Path → Bool)
    (context : RecoveryContext α β δ) (first second : RecoveryPredicate)
    (execution : recoveryPredicate program view snapshotView hardView hardPresence context (.or first second) = .ok false) :
    recoveryPredicate program view snapshotView hardView hardPresence context first = .ok false ∧
    recoveryPredicate program view snapshotView hardView hardPresence context second = .ok false := by
  cases left : recoveryPredicate program view snapshotView hardView hardPresence context first with
  | error reason => simp [bind, Except.bind, recoveryPredicate,left] at execution
  | ok rejected =>
    cases rejected
    · exact ⟨rfl,by simpa [bind, Except.bind, recoveryPredicate,left] using execution⟩
    · simp [bind, Except.bind, recoveryPredicate,left] at execution

theorem recovery_less_false (program : Restoration) (view : α → Path → InitStore)
    (snapshotView : β → Path → InitStore) (hardView : δ → InitStore) (hardPresence : δ → Path → Bool)
    (context : RecoveryContext α β δ) (first second : RecoveryValue)
    (execution : recoveryPredicate program view snapshotView hardView hardPresence context (.compare "lt" first second) = .ok false) :
    ∃ left right, recoveryValue program view snapshotView hardView context first = .ok left ∧
      recoveryValue program view snapshotView hardView context second = .ok right ∧ right ≤ left := by
  cases left : recoveryValue program view snapshotView hardView context first with
  | error reason => simp [bind, Except.bind, recoveryPredicate,left] at execution
  | ok firstValue =>
    cases right : recoveryValue program view snapshotView hardView context second with
    | error reason => simp [bind, Except.bind, recoveryPredicate,left,right] at execution
    | ok secondValue =>
      refine ⟨firstValue,secondValue,rfl,rfl,?_⟩
      simpa [bind, Except.bind, recoveryPredicate,left,right] using execution

theorem recovery_greater_false (program : Restoration) (view : α → Path → InitStore)
    (snapshotView : β → Path → InitStore) (hardView : δ → InitStore) (hardPresence : δ → Path → Bool)
    (context : RecoveryContext α β δ) (first second : RecoveryValue)
    (execution : recoveryPredicate program view snapshotView hardView hardPresence context (.compare "gt" first second) = .ok false) :
    ∃ left right, recoveryValue program view snapshotView hardView context first = .ok left ∧
      recoveryValue program view snapshotView hardView context second = .ok right ∧ left ≤ right := by
  cases left : recoveryValue program view snapshotView hardView context first with
  | error reason => simp [bind, Except.bind, recoveryPredicate,left] at execution
  | ok firstValue =>
    cases right : recoveryValue program view snapshotView hardView context second with
    | error reason => simp [bind, Except.bind, recoveryPredicate,left,right] at execution
    | ok secondValue =>
      refine ⟨firstValue,secondValue,rfl,rfl,?_⟩
      simpa [bind, Except.bind, recoveryPredicate,left,right] using execution

theorem recovery_hard_value (program : Restoration) (view : α → Path → InitStore)
    (snapshotView : β → Path → InitStore) (hardView : δ → InitStore) (context : RecoveryContext α β δ)
    (path : Path) (value : Nat) :
    recoveryValue program view snapshotView hardView context (.hard path) = .ok value ↔
      recordWord (hardView context.state.hard) path = some value := by
  cases word : recordWord (hardView context.state.hard) path <;> simp [bind, Except.bind, recoveryValue,word]

theorem recovery_base_value (program : Restoration) (view : α → Path → InitStore)
    (snapshotView : β → Path → InitStore) (hardView : δ → InitStore) (context : RecoveryContext α β δ)
    (path : Path) (value : Nat) :
    recoveryValue program view snapshotView hardView context (.base path) = .ok value ↔
      recordWord context.base path = some value := by
  cases word : recordWord context.base path <;> simp [bind, Except.bind, recoveryValue,word]

theorem recovery_last_value (program : Restoration) (view : α → Path → InitStore)
    (snapshotView : β → Path → InitStore) (hardView : δ → InitStore) (context : RecoveryContext α β δ)
    (path : Path) (value : Nat) :
    recoveryValue program view snapshotView hardView context (.callLast path) = .ok value ↔
      ∃ record, recoveryLast program view snapshotView context.state = .ok record ∧ recordWord record path = some value := by
  cases last : recoveryLast program view snapshotView context.state with
  | error reason => simp [bind, Except.bind, recoveryValue,last]
  | ok record =>
    cases word : recordWord record path <;> simp [bind, pure, Except.bind, Except.pure, recoveryValue,last,word]

theorem recovery_and_true (program : Restoration) (view : α → Path → InitStore)
    (snapshotView : β → Path → InitStore) (hardView : δ → InitStore) (hardPresence : δ → Path → Bool)
    (context : RecoveryContext α β δ) (first second : RecoveryPredicate)
    (left : recoveryPredicate program view snapshotView hardView hardPresence context first = .ok true)
    (execution : recoveryPredicate program view snapshotView hardView hardPresence context (.and first second) = .ok false) :
    recoveryPredicate program view snapshotView hardView hardPresence context second = .ok false := by
  simpa [recoveryPredicate,left,bind,Except.bind] using execution

theorem recovery_equal_false (program : Restoration) (view : α → Path → InitStore)
    (snapshotView : β → Path → InitStore) (hardView : δ → InitStore) (hardPresence : δ → Path → Bool)
    (context : RecoveryContext α β δ) (first second : RecoveryValue)
    (execution : recoveryPredicate program view snapshotView hardView hardPresence context (.compare "eq" first second) = .ok false) :
    ∃ left right, recoveryValue program view snapshotView hardView context first = .ok left ∧
      recoveryValue program view snapshotView hardView context second = .ok right ∧ left ≠ right := by
  cases left : recoveryValue program view snapshotView hardView context first with
  | error reason => simp [bind,Except.bind,recoveryPredicate,left] at execution
  | ok firstValue =>
    cases right : recoveryValue program view snapshotView hardView context second with
    | error reason => simp [bind,Except.bind,recoveryPredicate,left,right] at execution
    | ok secondValue =>
      refine ⟨firstValue,secondValue,rfl,rfl,?_⟩
      simpa [bind,Except.bind,recoveryPredicate,left,right] using execution

theorem recovery_checked_ne_false (program : Restoration) (view : α → Path → InitStore)
    (snapshotView : β → Path → InitStore) (hardView : δ → InitStore) (hardPresence : δ → Path → Bool)
    (context : RecoveryContext α β δ) (first second : RecoveryValue) (increment : Nat)
    (execution : recoveryPredicate program view snapshotView hardView hardPresence context (.checkedCompare false first increment second) = .ok false) :
    ∃ left right, recoveryValue program view snapshotView hardView context first = .ok left ∧
      recoveryValue program view snapshotView hardView context second = .ok right ∧
      left + increment = right ∧ right < 2^64 := by
  cases left : recoveryValue program view snapshotView hardView context first with
  | error reason => simp [bind,Except.bind,recoveryPredicate,left] at execution
  | ok firstValue =>
    by_cases invalid : increment ≥ 2^64
    · simp [bind,Except.bind,recoveryPredicate,left,invalid] at execution
    · cases right : recoveryValue program view snapshotView hardView context second with
      | error reason => simp [bind,Except.bind,recoveryPredicate,left,invalid,right] at execution
      | ok secondValue =>
        by_cases fits : firstValue + increment < 2^64
        · have same : firstValue + increment = secondValue := by
            simpa [bind,Except.bind,recoveryPredicate,left,invalid,right,fits] using execution
          exact ⟨firstValue,secondValue,rfl,rfl,same,by omega⟩
        · simp [bind,Except.bind,recoveryPredicate,left,invalid,right,fits] at execution

theorem recovery_entry_value (program : Restoration) (view : α → Path → InitStore)
    (snapshotView : β → Path → InitStore) (hardView : δ → InitStore) (context : RecoveryContext α β δ)
    (path : Path) (value : Nat) :
    recoveryValue program view snapshotView hardView context (.entry path) = .ok value ↔
      recordWord context.entry path = some value := by
  cases word : recordWord context.entry path <;> simp [bind,Except.bind,recoveryValue,word]

theorem recovery_cached_last_value (program : Restoration) (view : α → Path → InitStore)
    (snapshotView : β → Path → InitStore) (hardView : δ → InitStore) (context : RecoveryContext α β δ)
    (path : Path) (value : Nat) :
    recoveryValue program view snapshotView hardView context (.last path) = .ok value ↔
      recordWord context.last path = some value := by
  cases word : recordWord context.last path <;> simp [bind,Except.bind,recoveryValue,word]

-- The step premise is discharged by the consumer's source-linked append proof.
-- Iterator responses are universally quantified by the induction, not assumed
-- to satisfy the guard or to be a prevalidated sequence.
theorem recovery_loop_invariant (program : Restoration) (bits capacity fuel : Nat)
    (view : α → Path → InitStore) (snapshotView : β → Path → InitStore)
    (hardView : δ → InitStore) (hardPresence : δ → Path → Bool) (base : InitStore)
    (invariant : RecoveryState α β δ → Prop)
    (step : ∀ state entry record buffer, invariant state →
      recoveryLast program view snapshotView state = .ok record →
      recoveryPredicate program view snapshotView hardView hardPresence
        ⟨state,base,record,view entry program.last.recordField⟩ program.entryGuard = .ok false →
      resumeDrops (appendBuffer program.append bits capacity state.buffer entry) = .returned (.ok ()) buffer →
      invariant {state with buffer := buffer})
    (state output : RecoveryState α β δ) (iterator : ι) (valid : invariant state)
    (execution : RecoveryReturns (recoveryLoop program bits capacity view snapshotView hardView hardPresence base fuel state iterator : RecoveryRun α β δ σ ι) (.ok output)) :
    invariant output := by
  induction fuel generalizing state iterator with
  | zero => simp [recoveryLoop] at execution
  | succ fuel ih =>
    simp only [recoveryLoop,recovery_returns_next] at execution
    obtain ⟨entry,advanced,execution⟩ := execution
    cases entry with
    | none =>
      simp only [recovery_returns_dropIterator] at execution
      obtain ⟨same,_⟩ := recovery_finish_success program view snapshotView hardView hardPresence state output base execution
      cases same
      exact valid
    | some entry =>
      dsimp only at execution
      split at execution
      · simp at execution
      · rename_i record fetched
        split at execution
        · simp at execution
        · simp at execution
        · rename_i accepted
          obtain ⟨buffer,appended,continued⟩ := recovery_append_success program state output advanced _ _ execution
          exact ih {state with buffer := buffer} advanced (step state entry record buffer valid fetched accepted appended) continued

-- A borrowed enum view; unknown tags and malformed primitive fields have no
-- value. Physical enum layout and the source-to-view relation remain separate.
structure EnumStore where
  variant : String
  fields : InitStore

def enumProjection (branches : List (String × Path)) (state : EnumStore) : Option Nat := do
  let branch ← branches.find? (fun branch => branch.1 == state.variant)
  recordWord state.fields branch.2

-- A restricted source match retains arm grouping and ordered alternatives.
-- Field-binding resolution is still a checked but unverified frontend step.
def enumMatch : List (List (String × Path)) → EnumStore → Option Nat
  | [], _ => none
  | arm :: rest, state =>
    match arm.find? (fun branch => branch.1 == state.variant) with
    | none => enumMatch rest state
    | some branch => recordWord state.fields branch.2

theorem enum_match_flatten (arms : List (List (String × Path))) (state : EnumStore) :
    enumMatch arms state = enumProjection arms.flatten state := by
  induction arms with
  | nil => rfl
  | cons arm rest ih =>
    simp only [enumMatch,List.flatten_cons,enumProjection,List.find?_append]
    cases found : arm.find? (fun branch => branch.1 == state.variant) with
    | none => simpa [found,enumProjection,bind,Option.bind] using ih
    | some branch => simp [bind,Option.bind]


/- A deliberately restricted, pure Rust expression machine. Borrowed inputs are
   structural views, not claims about Rust memory. Fuel exhaustion and malformed
   views are observable faults, never successful validations. -/
inductive PureValue where
  | unit | boolean (value : Bool) | number (kind : String) (value : Nat)
  | record (name : String) (fields : List (String × PureValue))
  | variant (name tag : String) (fields : List (String × PureValue))
  | absent | present (value : PureValue) | array (values : List PureValue)
  deriving Repr
inductive PurePattern where
  | any | bind (slot : Nat)
  | variant (name tag : String) (fields : List (String × PurePattern))
  | present (value : PurePattern)
  | alternatives (patterns : List PurePattern)
  deriving Repr
inductive PureExpr where
  | literal (value : PureValue) | read (slot : Nat)
  | field (value : PureExpr) (name : String)
  | copy (value : PureExpr) | present (value : PureExpr)
  | binary (op : String) (left right : PureExpr)
  | negate (value : PureExpr)
  | sequence (first second : PureExpr)
  | write (slot : Nat) (value : PureExpr)
  | branch (condition yes no : PureExpr)
  | choose (value : PureExpr) (arms : List (PurePattern × PureExpr))
  | each (value : PureExpr) (slot : Nat) (body : PureExpr)
  | ret (value : PureExpr)
  deriving Repr
abbrev PureEnv := Nat → Option PureValue
inductive PureFault where
  | exhausted | representation | overflow
  deriving Repr, DecidableEq
inductive PureExit where
  | returned (value : PureValue)
  | fault (reason : PureFault)
  deriving Repr
abbrev PureResult := Except PureExit (PureValue × PureEnv)
def pureSet (env : PureEnv) (slot : Nat) (value : PureValue) : PureEnv :=
  fun key => if key = slot then some value else env key

def pureFields : PureValue → Option (List (String × PureValue))
  | .record _ fields | .variant _ _ fields => some fields
  | _ => none

def pureField (value : PureValue) (name : String) : Option PureValue := do
  let fields ← pureFields value
  return (← fields.find? (fun pair => pair.1 == name)).2

-- Pattern traversal is independently bounded. Missing fields cannot bind;
-- the consumer must still establish that the overall input view is well formed.
def pureMatch : Nat → PurePattern → PureValue → PureEnv → Option PureEnv
  | 0, _, _, _ => none
  | fuel+1, pattern, value, env => match pattern with
    | .any => some env
    | .bind slot => some (pureSet env slot value)
    | .present pattern => match value with
      | .present value => pureMatch fuel pattern value env
      | _ => none
    | .variant owner tag patterns => match value with
      | .variant actual variant fields =>
        if actual != owner || variant != tag then none else
        patterns.foldlM (fun env pair => do
          let field ← fields.find? (fun field => field.1 == pair.1)
          pureMatch fuel pair.2 field.2 env) env
      | _ => none
    | .alternatives patterns => patterns.findSome? (fun p => pureMatch fuel p value env)

def pureBound (kind : String) : Nat :=
  if kind = "u64" then 2^64 else if kind = "i32" then 2^31 else 0

def pureEqual (left right : PureValue) : Option Bool :=
  match left, right with
  | .boolean a, .boolean b => some (a == b)
  | .absent, .absent => some true
  | .absent, .present (.number kind n) | .present (.number kind n), .absent =>
    if n < pureBound kind then some false else none
  | .present (.number kind a), .present (.number other b) =>
    if kind = other ∧ a < pureBound kind ∧ b < pureBound kind then some (a == b) else none
  | _, _ => none

def pureBinary (op : String) (left right : PureValue) : Except PureExit PureValue :=
  match left, right with
  | .number kind a, .number other b =>
    if kind != other || a ≥ pureBound kind || b ≥ pureBound kind then
      .error (.fault .representation)
    else if op = "checked_add" then
      .ok (if a+b < pureBound kind then .present (.number kind (a+b)) else .absent)
    else if op = "checked_sub" then
      .ok (if b ≤ a then .present (.number kind (a-b)) else .absent)
    else if op = "saturating_add" then .ok (.number kind (min (a+b) (pureBound kind - 1)))
    else if op = "saturating_sub" then .ok (.number kind (a-b))
    else if op = "min" then .ok (.number kind (min a b))
    else if op = "max" then .ok (.number kind (max a b))
    else if op = "+" then
      if a+b < pureBound kind then .ok (.number kind (a+b)) else .error (.fault .overflow)
    else if op = "==" then .ok (.boolean (a == b))
    else if op = "!=" then .ok (.boolean (a != b))
    else if op = ">" then .ok (.boolean (a > b))
    else if op = "<" then .ok (.boolean (a < b))
    else if op = ">=" then .ok (.boolean (a ≥ b))
    else if op = "<=" then .ok (.boolean (a ≤ b))
    else .error (.fault .representation)
  | _, _ =>
    match pureEqual left right with
    | some value =>
      if op = "==" then .ok (.boolean value)
      else if op = "!=" then .ok (.boolean (!value))
      else .error (.fault .representation)
    | none => .error (.fault .representation)

-- Reusable primitive contracts. These describe the expression semantics;
-- source parsing, resolution and Rust memory refinement remain separate.
theorem pure_u64_bounded_arithmetic (a b : Nat) (aBound : a < 2^64) (bBound : b < 2^64) :
    pureBinary "saturating_add" (.number "u64" a) (.number "u64" b) =
      .ok (.number "u64" (min (a+b) (2^64-1))) ∧
    pureBinary "saturating_sub" (.number "u64" a) (.number "u64" b) = .ok (.number "u64" (a-b)) ∧
    pureBinary "min" (.number "u64" a) (.number "u64" b) = .ok (.number "u64" (min a b)) ∧
    pureBinary "max" (.number "u64" a) (.number "u64" b) = .ok (.number "u64" (max a b)) ∧
    pureBinary "checked_sub" (.number "u64" a) (.number "u64" b) =
      .ok (if b ≤ a then .present (.number "u64" (a-b)) else .absent) := by
  have ha : ¬18446744073709551616 ≤ a := Nat.not_le_of_gt aBound
  have hb : ¬18446744073709551616 ≤ b := Nat.not_le_of_gt bBound
  simp [pureBinary,pureBound,ha,hb]

theorem pure_u64_saturation_bounds (a b : Nat) (aBound : a < 2^64) (bBound : b < 2^64) :
    min (a+b) (2^64-1) < 2^64 ∧ a ≤ min (a+b) (2^64-1) ∧ b ≤ min (a+b) (2^64-1) ∧
    a-b < 2^64 ∧ min a b < 2^64 ∧ max a b < 2^64 := by omega

theorem pure_u64_saturation_exact (a b : Nat) (fits : a+b < 2^64) :
    min (a+b) (2^64-1) = a+b := by omega

def pureEval : Nat → PureExpr → PureEnv → PureResult
  | 0, _, _ => .error (.fault .exhausted)
  | fuel+1, expression, env => match expression with
    | .literal value => .ok (value, env)
    | .read slot => match env slot with
      | some value => .ok (value, env)
      | none => .error (.fault .representation)
    | .copy value => pureEval fuel value env
    | .present value => do
      let (value, env) ← pureEval fuel value env
      return (.present value, env)
    | .field value name => do
      let (value, env) ← pureEval fuel value env
      match pureField value name with
      | some value => return (value, env)
      | none => .error (.fault .representation)
    | .negate value => do
      let (.boolean value, env) ← pureEval fuel value env
        | .error (.fault .representation)
      return (.boolean (!value), env)
    | .binary op left right => do
      let (left, env) ← pureEval fuel left env
      if op = "&&" || op = "||" then
        let .boolean value := left | .error (.fault .representation)
        if (op = "&&" && !value) || (op = "||" && value) then
          return (.boolean value, env)
        else
          let (.boolean value, env) ← pureEval fuel right env
            | .error (.fault .representation)
          return (.boolean value, env)
      else
        let (right, env) ← pureEval fuel right env
        let value ← pureBinary op left right
        return (value, env)
    | .sequence first second => do
      let (_, env) ← pureEval fuel first env
      pureEval fuel second env
    | .write slot value => do
      let (value, env) ← pureEval fuel value env
      return (.unit, pureSet env slot value)
    | .branch condition yes no => do
      let (.boolean condition, env) ← pureEval fuel condition env
        | .error (.fault .representation)
      pureEval fuel (if condition then yes else no) env
    | .choose value arms => do
      let (value, env) ← pureEval fuel value env
      match arms.findSome? (fun arm =>
        (pureMatch fuel arm.1 value env).map (fun env => (arm.2,env))) with
      | some (body, env) => pureEval fuel body env
      | none => .error (.fault .representation)
    | .each value slot body => do
      let (.array values, env) ← pureEval fuel value env
        | .error (.fault .representation)
      values.foldlM (fun (_, env) value =>
        pureEval fuel body (pureSet env slot value)) (.unit, env)
    | .ret value => do
      let (value, _) ← pureEval fuel value env
      .error (.returned value)

def pureValidate (fuel : Nat) (body : PureExpr) (input : PureValue) : Except PureFault Bool :=
  match pureEval fuel body (pureSet (fun _ => none) 0 input) with
  | .ok (.boolean value, _) | .error (.returned (.boolean value)) => .ok value
  | .error (.fault reason) => .error reason
  | _ => .error .representation


/- Compositional rules for consumer proofs. These quantify over arbitrary array
   lengths and environments; a consumer must establish the body premise from
   the generated expression rather than assume its desired postcondition. -/
theorem pure_sequence_error (fuel : Nat) (first second : PureExpr)
    (env : PureEnv) (reason : PureExit)
    (failed : pureEval fuel first env = .error reason) :
    pureEval (fuel+1) (.sequence first second) env = .error reason := by
  simp [pureEval,failed,bind,Except.bind]

theorem pure_binary_left_error (fuel : Nat) (op : String) (left right : PureExpr)
    (env : PureEnv) (reason : PureExit)
    (failed : pureEval fuel left env = .error reason) :
    pureEval (fuel+1) (.binary op left right) env = .error reason := by
  simp [pureEval,failed,bind,Except.bind]

theorem pure_fold_invariant (fuel slot : Nat) (body : PureExpr)
    (invariant : PureEnv → Prop)
    (step : ∀ (value result : PureValue) (before after : PureEnv),
      invariant before →
      pureEval fuel body (pureSet before slot value) = .ok (result,after) →
      invariant after)
    (values : List PureValue) (initialResult result : PureValue) (before after : PureEnv)
    (initial : invariant before)
    (returned : values.foldlM (fun (_,env) value =>
      pureEval fuel body (pureSet env slot value)) (initialResult,before) = .ok (result,after)) :
    invariant after := by
  induction values generalizing initialResult before with
  | nil =>
    have equal : (initialResult,before) = (result,after) := Except.ok.inj returned
    cases equal
    exact initial
  | cons value rest ih =>
    simp only [List.foldlM] at returned
    cases evaluated : pureEval fuel body (pureSet before slot value) with
    | error reason => simp [evaluated,bind,Except.bind] at returned
    | ok pair =>
      rcases pair with ⟨nextResult,nextEnv⟩
      have next := step value nextResult before nextEnv initial evaluated
      apply ih nextResult nextEnv next
      simpa [evaluated,bind,Except.bind] using returned

theorem pure_each_invariant (fuel slot : Nat) (source body : PureExpr)
    (invariant : PureEnv → Prop)
    (step : ∀ (value result : PureValue) (before after : PureEnv),
      invariant before →
      pureEval fuel body (pureSet before slot value) = .ok (result,after) →
      invariant after)
    (values : List PureValue) (result : PureValue) (input before after : PureEnv)
    (read : pureEval fuel source input = .ok (.array values,before))
    (initial : invariant before)
    (returned : pureEval (fuel+1) (.each source slot body) input = .ok (result,after)) :
    invariant after := by
  apply pure_fold_invariant fuel slot body invariant step values .unit result before after initial
  simpa [pureEval,read,bind,Except.bind] using returned


theorem pure_fold_history (fuel slot : Nat) (body : PureExpr)
    (invariant : List PureValue → PureEnv → Prop)
    (step : ∀ (seen : List PureValue) (value result : PureValue) (before after : PureEnv),
      invariant seen before →
      pureEval fuel body (pureSet before slot value) = .ok (result,after) →
      invariant (seen ++ [value]) after)
    (values seen : List PureValue) (initialResult result : PureValue) (before after : PureEnv)
    (initial : invariant seen before)
    (returned : values.foldlM (fun (_,env) value =>
      pureEval fuel body (pureSet env slot value)) (initialResult,before) = .ok (result,after)) :
    invariant (seen ++ values) after := by
  induction values generalizing seen initialResult before with
  | nil =>
    have equal : (initialResult,before) = (result,after) := Except.ok.inj returned
    cases equal
    simpa using initial
  | cons value rest ih =>
    simp only [List.foldlM] at returned
    cases evaluated : pureEval fuel body (pureSet before slot value) with
    | error reason => simp [evaluated,bind,Except.bind] at returned
    | ok pair =>
      rcases pair with ⟨nextResult,nextEnv⟩
      have next := step seen value nextResult before nextEnv initial evaluated
      have tail := ih (seen ++ [value]) nextResult nextEnv next
        (by simpa [evaluated,bind,Except.bind] using returned)
      simpa [List.append_assoc] using tail


def pureIsLoop : PureExpr → Bool
  | .each .. => true
  | _ => false

/-- Unfold one non-loop step, retaining loops as proof boundaries. This prevents
    symbolic simplification from expanding the body under an unknown array fold.
    The identity loop case adds no execution assumption. -/
theorem pure_eval_step (fuel : Nat) (expression : PureExpr) (env : PureEnv)
    (nonzero : (fuel == 0) = false)
    (_notLoop : pureIsLoop expression = false) :
    pureEval fuel expression env = (match expression with

    | .literal value => .ok (value, env)
    | .read slot => match env slot with
      | some value => .ok (value, env)
      | none => .error (.fault .representation)
    | .copy value => pureEval (fuel-1) value env
    | .present value => do
      let (value, env) ← pureEval (fuel-1) value env
      return (.present value, env)
    | .field value name => do
      let (value, env) ← pureEval (fuel-1) value env
      match pureField value name with
      | some value => return (value, env)
      | none => .error (.fault .representation)
    | .negate value => do
      let (.boolean value, env) ← pureEval (fuel-1) value env
        | .error (.fault .representation)
      return (.boolean (!value), env)
    | .binary op left right => do
      let (left, env) ← pureEval (fuel-1) left env
      if op = "&&" || op = "||" then
        let .boolean value := left | .error (.fault .representation)
        if (op = "&&" && !value) || (op = "||" && value) then
          return (.boolean value, env)
        else
          let (.boolean value, env) ← pureEval (fuel-1) right env
            | .error (.fault .representation)
          return (.boolean value, env)
      else
        let (right, env) ← pureEval (fuel-1) right env
        let value ← pureBinary op left right
        return (value, env)
    | .sequence first second => do
      let (_, env) ← pureEval (fuel-1) first env
      pureEval (fuel-1) second env
    | .write slot value => do
      let (value, env) ← pureEval (fuel-1) value env
      return (.unit, pureSet env slot value)
    | .branch condition yes no => do
      let (.boolean condition, env) ← pureEval (fuel-1) condition env
        | .error (.fault .representation)
      pureEval (fuel-1) (if condition then yes else no) env
    | .choose value arms => do
      let (value, env) ← pureEval (fuel-1) value env
      match arms.findSome? (fun arm =>
        (pureMatch (fuel-1) arm.1 value env).map (fun env => (arm.2,env))) with
      | some (body, env) => pureEval (fuel-1) body env
      | none => .error (.fault .representation)
    | .each value slot body => pureEval fuel (.each value slot body) env
    | .ret value => do
      let (value, _) ← pureEval (fuel-1) value env
      .error (.returned value)
) := by
  cases fuel with
  | zero => simp at nonzero
  | succ fuel => cases expression <;> rfl

/- Symbolic proofs use an opaque, certified copy of the evaluator to prevent
   kernel conversion from repeatedly expanding the recursive interpreter.
   The package stores the original evaluator and its equality proof; opacity
   changes proof reduction only. Axiom auditing traverses its stored value. -/
private structure PureEvalPackage where
  run : Nat → PureExpr → PureEnv → PureResult
  correct : run = pureEval
private opaque pureEvalPackage : PureEvalPackage := ⟨pureEval,rfl⟩
def pureEvalSymbolic : Nat → PureExpr → PureEnv → PureResult := pureEvalPackage.run
theorem pureEvalSymbolic_eq (fuel : Nat) (expression : PureExpr) (env : PureEnv) :
    pureEvalSymbolic fuel expression env = pureEval fuel expression env :=
  congrFun (congrFun (congrFun pureEvalPackage.correct fuel) expression) env

theorem pure_eval_symbolic_step (fuel : Nat) (expression : PureExpr) (env : PureEnv)
    (nonzero : (fuel == 0) = false) (notLoop : pureIsLoop expression = false) :
    pureEvalSymbolic fuel expression env = (match expression with

    | .literal value => .ok (value, env)
    | .read slot => match env slot with
      | some value => .ok (value, env)
      | none => .error (.fault .representation)
    | .copy value => pureEvalSymbolic (fuel-1) value env
    | .present value => do
      let (value, env) ← pureEvalSymbolic (fuel-1) value env
      return (.present value, env)
    | .field value name => do
      let (value, env) ← pureEvalSymbolic (fuel-1) value env
      match pureField value name with
      | some value => return (value, env)
      | none => .error (.fault .representation)
    | .negate value => do
      let (.boolean value, env) ← pureEvalSymbolic (fuel-1) value env
        | .error (.fault .representation)
      return (.boolean (!value), env)
    | .binary op left right => do
      let (left, env) ← pureEvalSymbolic (fuel-1) left env
      if op = "&&" || op = "||" then
        let .boolean value := left | .error (.fault .representation)
        if (op = "&&" && !value) || (op = "||" && value) then
          return (.boolean value, env)
        else
          let (.boolean value, env) ← pureEvalSymbolic (fuel-1) right env
            | .error (.fault .representation)
          return (.boolean value, env)
      else
        let (right, env) ← pureEvalSymbolic (fuel-1) right env
        let value ← pureBinary op left right
        return (value, env)
    | .sequence first second => do
      let (_, env) ← pureEvalSymbolic (fuel-1) first env
      pureEvalSymbolic (fuel-1) second env
    | .write slot value => do
      let (value, env) ← pureEvalSymbolic (fuel-1) value env
      return (.unit, pureSet env slot value)
    | .branch condition yes no => do
      let (.boolean condition, env) ← pureEvalSymbolic (fuel-1) condition env
        | .error (.fault .representation)
      pureEvalSymbolic (fuel-1) (if condition then yes else no) env
    | .choose value arms => do
      let (value, env) ← pureEvalSymbolic (fuel-1) value env
      match arms.findSome? (fun arm =>
        (pureMatch (fuel-1) arm.1 value env).map (fun env => (arm.2,env))) with
      | some (body, env) => pureEvalSymbolic (fuel-1) body env
      | none => .error (.fault .representation)
    | .each value slot body => pureEvalSymbolic fuel (.each value slot body) env
    | .ret value => do
      let (value, _) ← pureEvalSymbolic (fuel-1) value env
      .error (.returned value)
) := by
  unfold pureEvalSymbolic
  rw [pureEvalPackage.correct]
  exact pure_eval_step fuel expression env nonzero notLoop

def pureValidateSymbolic (fuel : Nat) (body : PureExpr) (input : PureValue) : Except PureFault Bool :=
  match pureEvalSymbolic fuel body (pureSet (fun _ => none) 0 input) with
  | .ok (.boolean value, _) | .error (.returned (.boolean value)) => .ok value
  | .error (.fault reason) => .error reason
  | _ => .error .representation

theorem pureValidateSymbolic_eq (fuel : Nat) (body : PureExpr) (input : PureValue) :
    pureValidateSymbolic fuel body input = pureValidate fuel body input := by
  simp only [pureValidateSymbolic,pureValidate,pureEvalSymbolic_eq]


theorem pure_match_any (fuel : Nat) (value : PureValue) (env : PureEnv)
    (nonzero : (fuel == 0) = false) :
    pureMatch fuel .any value env = some env := by
  cases fuel with
  | zero => simp at nonzero
  | succ fuel => rfl

theorem pure_match_bind (fuel slot : Nat) (value : PureValue) (env : PureEnv)
    (nonzero : (fuel == 0) = false) :
    pureMatch fuel (.bind slot) value env = some (pureSet env slot value) := by
  cases fuel with
  | zero => simp at nonzero
  | succ fuel => rfl

theorem pure_match_present (fuel : Nat) (pattern : PurePattern) (value : PureValue) (env : PureEnv)
    (nonzero : (fuel == 0) = false) :
    pureMatch fuel (.present pattern) value env = (match value with
      | .present value => pureMatch (fuel-1) pattern value env
      | _ => none) := by
  cases fuel with
  | zero => simp at nonzero
  | succ fuel => rfl

theorem pure_match_variant (fuel : Nat) (owner tag : String) (patterns : List (String × PurePattern))
    (value : PureValue) (env : PureEnv) (nonzero : (fuel == 0) = false) :
    pureMatch fuel (.variant owner tag patterns) value env = (match value with
      | .variant actual variant fields =>
        if actual != owner || variant != tag then none else
        patterns.foldlM (fun env pair => do
          let field ← fields.find? (fun field => field.1 == pair.1)
          pureMatch (fuel-1) pair.2 field.2 env) env
      | _ => none) := by
  cases fuel with
  | zero => simp at nonzero
  | succ fuel => rfl

end Provium.State
