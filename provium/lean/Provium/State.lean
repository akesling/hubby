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
end Provium.State
