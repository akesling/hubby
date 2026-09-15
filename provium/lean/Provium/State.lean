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
  let count := state.lengths program.lengthPath + (if program.inclusive then 1 else 0)
  if count ≤ slots.length then .ok (presentPlaces program.slotsPath 0 (slots.take count))
  else .error .bounds
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

end Provium.State
