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
end Provium.State
