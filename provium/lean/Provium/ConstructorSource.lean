import Provium.State

/- Source-language interpretation for pure record constructors. Derived-default
   declarations and const substitutions are explicit inputs. Their connection
   to Rust trait/const resolution and physical allocation remains to be proved. -/
namespace Provium.ConstructorSource
open Provium.State

inductive Atom where
  | boolean (value : Bool)
  | unsigned (rustType : String) (value : Nat)
  | absent
  deriving Repr

def lowerAtom : Atom → Initial
  | .boolean value => .boolean value
  | .unsigned ty value => .unsigned ty value
  | .absent => .absent

def atomValue : Atom → InitCell
  | .boolean value => .boolean value
  | .unsigned ty value => .unsigned ty value
  | .absent => .absent

inductive Expression where
  | atom (value : Atom)
  | emptyArray (capacity : InitCapacity)
  | emptyRecord
  | field (name : String) (value rest : Expression)
  | derivedDefault (name : String)

inductive DefaultType where
  | boolean
  | unsigned (rustType : String)
  | optional

def defaultAtom : DefaultType → Atom
  | .boolean => .boolean false
  | .unsigned rustType => .unsigned rustType 0
  | .optional => .absent

def defaultExpression (fields : List (String × DefaultType)) : Expression :=
  fields.foldr (fun field rest => .field field.1 (.atom (defaultAtom field.2)) rest) .emptyRecord

abbrev Defaults := String → Option (List (String × DefaultType))
abbrev Constants := String → Option InitCapacity

def substitute (constants : Constants) : InitCapacity → Option InitCapacity
  | .fixed value => some (.fixed value)
  | .parameter name => constants name

def lower : Nat → Defaults → Constants → Path → Expression → Option (List InitField)
  | 0, _, _, _, _ => none
  | fuel + 1, defaults, constants, basePath, expression =>
    match expression with
    | .atom value => some [⟨basePath, lowerAtom value⟩]
    | .emptyArray capacity => do
      let capacity ← substitute constants capacity
      some [⟨basePath, .emptySlots capacity⟩]
    | .emptyRecord => some []
    | .field name value rest => do
      let value ← lower fuel defaults constants (basePath ++ [name]) value
      let rest ← lower fuel defaults constants basePath rest
      some (value ++ rest)
    | .derivedDefault name => do
      let declaration ← defaults name
      lower fuel defaults constants basePath (defaultExpression declaration)

inductive Fault where
  | exhausted
  | unresolvedDefault
  | unboundCapacity
  deriving DecidableEq

def put (heap : InitStore) (path : Path) (value : InitCell) : InitStore :=
  fun key => if key = path then value else heap key

def capacityValue (sizes : String → Nat) : InitCapacity → Nat
  | .fixed size => size
  | .parameter name => sizes name

def run : Nat → Defaults → Constants → (String → Nat) → Path → Expression → InitStore →
    Except Fault InitStore
  | 0, _, _, _, _, _, _ => .error .exhausted
  | fuel + 1, defaults, constants, sizes, basePath, expression, heap =>
    match expression with
    | .atom value => .ok (put heap basePath (atomValue value))
    | .emptyArray capacity =>
      match substitute constants capacity with
      | none => .error .unboundCapacity
      | some capacity => .ok (put heap basePath (.slots (List.replicate (capacityValue sizes capacity) none)))
    | .emptyRecord => .ok heap
    | .field name value rest => do
      let middle ← run fuel defaults constants sizes (basePath ++ [name]) value heap
      run fuel defaults constants sizes basePath rest middle
    | .derivedDefault name =>
      match defaults name with
      | none => .error .unresolvedDefault
      | some declaration => run fuel defaults constants sizes basePath (defaultExpression declaration) heap

def applyFields (fields : List InitField) (sizes : String → Nat) (heap : InitStore) : InitStore :=
  fields.foldl (fun state field => put state field.path (initialCell sizes field.value)) heap

theorem applyFields_append :
    applyFields (first ++ rest) sizes heap = applyFields rest sizes (applyFields first sizes heap) := by
  simp [applyFields, List.foldl_append]

theorem lower_correct (fuel : Nat)
    (compiled : lower fuel defaults constants basePath expression = some fields) :
    run fuel defaults constants sizes basePath expression heap = .ok (applyFields fields sizes heap) := by
  induction fuel generalizing basePath expression fields heap with
  | zero => simp [lower] at compiled
  | succ fuel ih =>
    cases expression with
    | atom value =>
      simp only [lower, Option.some.injEq] at compiled
      subst fields
      cases value <;> rfl
    | emptyArray capacity =>
      cases bound : substitute constants capacity with
      | none => simp [lower, bound] at compiled
      | some actual =>
        simp [lower, bound] at compiled
        subst fields
        simp only [run, bound]
        cases actual <;> rfl
    | emptyRecord =>
      simp only [lower, Option.some.injEq] at compiled
      subst fields
      rfl
    | field name value rest =>
      cases hValue : lower fuel defaults constants (basePath ++ [name]) value with
      | none => simp [lower, hValue] at compiled
      | some valueFields =>
        cases hRest : lower fuel defaults constants basePath rest with
        | none => simp [lower, hValue, hRest] at compiled
        | some restFields =>
          simp [lower, hValue, hRest] at compiled
          subst fields
          simp only [run, ih hValue, applyFields_append]
          exact ih hRest
    | derivedDefault name =>
      cases found : defaults name with
      | none => simp [lower, found] at compiled
      | some body =>
        simp only [lower, found] at compiled
        simp only [run, found]
        exact ih compiled

theorem constructor_refinement
    (compiled : lower fuel defaults constants [] expression = some fields) :
    run fuel defaults constants sizes [] expression (fun _ => .absent) =
      .ok (initializeFields fields sizes) := by
  exact lower_correct fuel compiled

end Provium.ConstructorSource
