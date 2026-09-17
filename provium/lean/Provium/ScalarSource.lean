import Provium.State

/- Operational interpretation of a small, explicit source-term language.
   The Rust parser and name/place resolution still need independent validation.
   This language retains nested source places and named calls; it is not the
   generated field-store IR. Lowering correctness includes all admitted outcomes. -/
namespace Provium.ScalarSource
open Provium.State

inductive Place where
  | receiver
  | field (base : Place) (name : String)
  deriving Repr

def Place.path : Place → Path
  | .receiver => []
  | .field base name => base.path ++ [name]

inductive Boolean where
  | literal (value : Bool)
  | load (place : Place)
  | not (value : Boolean)
  | and (left right : Boolean)
  | or (left right : Boolean)
  deriving Repr

def lowerBoolean : Boolean → Condition
  | .literal value => .boolean value
  | .load place => .field place.path
  | .not value => .not (lowerBoolean value)
  | .and left right => .and (lowerBoolean left) (lowerBoolean right)
  | .or left right => .or (lowerBoolean left) (lowerBoolean right)

def readBoolean (layout : Initialized.Layout) (heap : Initialized.Heap α) :
    Boolean → Except Initialized.Fault Bool
  | .literal value => .ok value
  | .load place => do
    let value ← Initialized.read layout heap place.path
    match value with
    | .boolean value => .ok value
    | _ => .error .wrongType
  | .not value => do return !(← readBoolean layout heap value)
  | .and left right => do
    if ← readBoolean layout heap left then readBoolean layout heap right else pure false
  | .or left right => do
    if ← readBoolean layout heap left then pure true else readBoolean layout heap right

theorem boolean_correct (term : Boolean) :
    readBoolean layout heap term = Initialized.condition layout heap (lowerBoolean term) := by
  induction term with
  | literal | load => rfl
  | not value ih => simp only [readBoolean, lowerBoolean, Initialized.condition, ih]
  | and left right ihLeft ihRight =>
    simp only [readBoolean, lowerBoolean, Initialized.condition, ihLeft, ihRight]
  | or left right ihLeft ihRight =>
    simp only [readBoolean, lowerBoolean, Initialized.condition, ihLeft, ihRight]

inductive Statement where
  | empty
  | assignment (place : Place) (value : Literal)
  | sequence (first rest : Statement)
  | conditional (condition : Boolean) (yes no : Statement)
  | call (name : String)
  deriving Repr

abbrev Environment := String → Option Statement

-- Fuel bounds structural descent and call unfolding. Exhausted or unresolved
-- source programs are rejected by lowering, including unselected branches.
def lower : Nat → Environment → Statement → Option Program
  | 0, _, _ => none
  | fuel + 1, environment, term =>
    match term with
    | .empty => some .done
    | .assignment place value => some (.write ⟨place.path, value⟩)
    | .sequence first rest => do
      let first ← lower fuel environment first
      let rest ← lower fuel environment rest
      some (.seq first rest)
    | .conditional condition yes no => do
      let yes ← lower fuel environment yes
      let no ← lower fuel environment no
      some (.branch (lowerBoolean condition) yes no)
    | .call name => do
      let body ← environment name
      lower fuel environment body

inductive Fault where
  | exhausted
  | unresolved
  | memory (fault : Initialized.Fault)
  deriving DecidableEq

def run : Nat → Environment → Initialized.Layout → Statement → Initialized.Heap α →
    Except Fault (Initialized.Heap α)
  | 0, _, _, _, _ => .error .exhausted
  | fuel + 1, environment, layout, term, heap =>
    match term with
    | .empty => .ok heap
    | .assignment place value =>
      (Initialized.assign layout heap ⟨place.path, value⟩).mapError Fault.memory
    | .sequence first rest => do
      let middle ← run fuel environment layout first heap
      run fuel environment layout rest middle
    | .conditional condition yes no => do
      if ← (readBoolean layout heap condition).mapError Fault.memory then
        run fuel environment layout yes heap
      else run fuel environment layout no heap
    | .call name =>
      match environment name with
      | none => .error .unresolved
      | some body => run fuel environment layout body heap

theorem lower_correct (fuel : Nat)
    (compiled : lower fuel environment term = some program) :
    run fuel environment layout term heap =
      (Initialized.execute layout program heap).mapError Fault.memory := by
  induction fuel generalizing term program heap with
  | zero => simp [lower] at compiled
  | succ fuel ih =>
    cases term with
    | empty =>
      simp only [lower, Option.some.injEq] at compiled
      subst program
      rfl
    | assignment place value =>
      simp only [lower, Option.some.injEq] at compiled
      subst program
      rfl
    | sequence first rest =>
      cases hFirst : lower fuel environment first with
      | none => simp [lower, hFirst] at compiled
      | some firstProgram =>
        cases hRest : lower fuel environment rest with
        | none => simp [lower, hFirst, hRest] at compiled
        | some restProgram =>
          simp [lower, hFirst, hRest] at compiled
          subst program
          simp only [run, ih hFirst, Initialized.execute]
          cases executed : Initialized.execute layout firstProgram heap with
          | error fault => rfl
          | ok middle =>
            simp only [Except.mapError]
            exact ih hRest
    | conditional condition yes no =>
      cases hYes : lower fuel environment yes with
      | none => simp [lower, hYes] at compiled
      | some yesProgram =>
        cases hNo : lower fuel environment no with
        | none => simp [lower, hYes, hNo] at compiled
        | some noProgram =>
          simp [lower, hYes, hNo] at compiled
          subst program
          simp only [run, boolean_correct, Initialized.execute]
          cases tested : Initialized.condition layout heap (lowerBoolean condition) with
          | error fault => rfl
          | ok choice =>
            cases choice <;> simp only [Except.mapError] <;> apply ih <;> assumption
    | call name =>
      cases found : environment name with
      | none => simp [lower, found] at compiled
      | some body =>
        simp only [lower, found] at compiled
        simp only [run, found]
        exact ih compiled

-- This corollary connects the independently interpreted term to the existing
-- initialized-heap refinement, rather than assuming the source program's effect.
theorem initialized_refinement
    (compiled : lower fuel environment term = some program)
    (related : Initialized.Relates layout heap state)
    (typed : Initialized.ProgramTyped layout program) :
    ∃ result, run fuel environment layout term heap = .ok result ∧
      Initialized.Relates layout result (Provium.State.execute program state) := by
  obtain ⟨result, completed, related'⟩ := Initialized.execute_refines program related typed
  exact ⟨result, by rw [lower_correct fuel compiled, completed]; rfl, related'⟩

end Provium.ScalarSource
