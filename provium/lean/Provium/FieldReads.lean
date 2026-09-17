import Provium.Loans
import Provium.ScalarSource

/- Copied fields, including opaque Copy record values. Source place selection,
   Copy/type resolution and physical representation remain frontend obligations.
   References embedded in opaque Copy values still need representation and
   lifetime refinement; this interpreter does not dereference them. -/
namespace Provium.State.FieldReads

structure Program where
  path : Path
  kind : Initialized.Kind

def readValue (program : Program) (state : Store α) : Cell α := state program.path

def fits : Initialized.Kind → Cell α → Bool
  | .boolean, .boolean _ => true
  | .optional, .absent => true
  | .optional, .other _ => true
  | .payload, .other _ => true
  | _, _ => false

theorem fits_of_typed (typed : Initialized.Fits kind cell) : fits kind cell = true := by
  cases kind <;> cases cell <;> simp_all [Initialized.Fits, fits]

def readMemory (program : Program) (layout : Initialized.Layout) (heap : Initialized.Heap α) :
    Except Initialized.Fault (Cell α) := do
  match layout program.path with
  | none => throw .invalidPlace
  | some kind => if kind = program.kind then pure () else throw .wrongType
  let value ← Initialized.read layout heap program.path
  if fits program.kind value then pure value else throw .wrongType

theorem memory_refines (related : Initialized.Relates layout heap state)
    (declared : layout program.path = some program.kind) :
    readMemory program layout heap = .ok (readValue program state) := by
  obtain ⟨live, typed⟩ := related program.path program.kind declared
  simp [readMemory, declared, Initialized.read, live, readValue]
  change (if fits program.kind (state program.path) then Except.ok (state program.path)
    else Except.error Initialized.Fault.wrongType) = _
  rw [fits_of_typed typed]
  rfl

-- The source interpreter projects one named field at a time, before reading
-- the receiver of the resulting view. Its input is walked separately in Rust.
def view : Provium.ScalarSource.Place → (Path → β) → Path → β
  | .receiver, state => state
  | .field base name, state => fun path => view base state (name :: path)

theorem view_path (place : Provium.ScalarSource.Place) (state : Path → β) (path : Path) :
    view place state path = state (place.path ++ path) := by
  induction place generalizing path with
  | receiver => rfl
  | field base name ih => simp [view, Provium.ScalarSource.Place.path, ih, List.append_assoc]

def readSourceMemory (kind : Initialized.Kind) (place : Provium.ScalarSource.Place)
    (layout : Initialized.Layout) (heap : Initialized.Heap α) : Except Initialized.Fault (Cell α) :=
  readMemory ⟨[], kind⟩ (view place layout) (view place heap)

theorem source_memory_refines (kind : Initialized.Kind) (place : Provium.ScalarSource.Place)
    (layout : Initialized.Layout) (heap : Initialized.Heap α) :
    readSourceMemory kind place layout heap = readMemory ⟨place.path, kind⟩ layout heap := by
  simp [readSourceMemory, readMemory, Initialized.read, view_path]

def readLoan (world : Loans.World) (owner ticket : Nat) (program : Program)
    (layout : Initialized.Layout) (heap : Initialized.Heap α) :
    Except (Loans.Fault ⊕ Initialized.Fault) (Cell α) :=
  if Loans.Allowed world owner ticket ⟨program.path, .shared⟩ then
    (readMemory program layout heap).mapError Sum.inr
  else .error (.inl .denied)

theorem loan_refines (related : Initialized.Relates layout heap state)
    (declared : layout program.path = some program.kind)
    (allowed : Loans.Allowed world owner ticket ⟨program.path, .shared⟩) :
    readLoan world owner ticket program layout heap = .ok (readValue program state) := by
  simp [readLoan, allowed, memory_refines related declared, Except.mapError]

end Provium.State.FieldReads
