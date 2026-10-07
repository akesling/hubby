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

-- A returned reference retains the caller's active shared receiver loan. Mere
-- read permission is insufficient: an exclusive active frame could still write.
namespace Borrowed
structure Reference where
  owner : Nat
  ticket : Nat
  path : Path
  deriving DecidableEq

def Live (world : Loans.World) (reference : Reference) : Prop :=
  match world reference.owner with
  | none => False
  | some loan => reference.ticket = loan.stack.ticket ∧
      loan.active.mode = .shared ∧ loan.active.path <+: reference.path

instance (world : Loans.World) (reference : Reference) : Decidable (Live world reference) := by
  unfold Live
  cases world reference.owner <;> infer_instance

theorem live_allowed (live : Live world reference) :
    Loans.Allowed world reference.owner reference.ticket ⟨reference.path, .shared⟩ := by
  cases found : world reference.owner with
  | none => simp [Live, found] at live
  | some loan =>
    have h := live
    simp only [Live, found] at h
    exact (show Loans.Allowed world reference.owner reference.ticket ⟨reference.path, .shared⟩ from
      by simp only [Loans.Allowed, found]; exact ⟨h.1, h.2.2, Or.inr rfl⟩)

theorem same_owner_cannot_write (live : Live world reference) :
    ¬ Loans.Allowed world reference.owner ticket ⟨path, .exclusive⟩ := by
  cases found : world reference.owner with
  | none => simp [Live, found] at live
  | some loan =>
    simp only [Live, found] at live
    simp only [Loans.Allowed, found, Loans.Nested]
    intro write
    rcases write.2.2 with exclusive | impossible
    · cases live.2.1.symm.trans exclusive
    · cases impossible

theorem other_owner_cannot_overlap (valid : Loans.Valid world)
    (live : Live world reference) (different : owner ≠ reference.owner)
    (write : Loans.Allowed world owner ticket ⟨path, .exclusive⟩) :
    ¬ Loans.Overlap path reference.path :=
  Loans.exclusive_excludes valid different write (live_allowed live)

def select (reference : Reference) : Cell α → Except Initialized.Fault (Option Reference)
  | .absent => .ok none
  | .other _ => .ok (some reference)
  | .boolean _ => .error .wrongType

def read (world : Loans.World) (reference : Reference)
    (layout : Initialized.Layout) (heap : Initialized.Heap α) :
    Except (Loans.Fault ⊕ Initialized.Fault) (Option Reference) :=
  if Live world reference then
    ((readMemory ⟨reference.path, .optional⟩ layout heap).bind (select reference)).mapError Sum.inr
  else .error (.inl .denied)

theorem read_returns_live (success : read world reference layout heap = .ok (some returned)) :
    returned = reference ∧ Live world returned := by
  unfold read at success
  split at success
  next live =>
    cases found : readMemory ⟨reference.path, .optional⟩ layout heap with
    | error fault => simp [found, Except.bind, Except.mapError] at success
    | ok cell =>
      cases cell <;> simp_all [select, Except.bind, Except.mapError]
  next denied => cases success

def dereference (world : Loans.World) (reference : Reference)
    (layout : Initialized.Layout) (heap : Initialized.Heap α) :
    Except (Loans.Fault ⊕ Initialized.Fault) α :=
  if Live world reference then
    ((readMemory ⟨reference.path, .optional⟩ layout heap).bind fun cell =>
      match cell with
      | .other value => .ok value
      | _ => .error .wrongType).mapError Sum.inr
  else .error (.inl .denied)

theorem read_refines (related : Initialized.Relates layout heap state)
    (declared : layout reference.path = some .optional) (live : Live world reference) :
    read world reference layout heap = (select reference (state reference.path)).mapError Sum.inr := by
  simp [read, live, memory_refines (program := ⟨reference.path, .optional⟩) related declared, readValue, Except.bind]

theorem dereference_present {payload : α} (related : Initialized.Relates layout heap state)
    (declared : layout reference.path = some .optional) (live : Live world reference)
    (present : state reference.path = .other payload) :
    dereference world reference layout heap = .ok payload := by
  simp [dereference, live, memory_refines (program := ⟨reference.path, .optional⟩) related declared, readValue, present, Except.bind, Except.mapError]

theorem ended_denied (ended : world reference.owner = none) :
    dereference world reference layout heap = .error (.inl .denied) := by
  simp [dereference, Live, ended]

/-- `Live` alone cannot tell lifetimes apart, because every root ticket is 0.
    Under the Arena discipline, owner IDs are never reused: once a lifetime
    ends, a reference into it stays dead even after a later reservation. -/
theorem ended_not_revived (arena after : Loans.Arena) (reference : Reference) (ticket : Nat)
    (ended : arena.endLifetime reference.owner ticket = .ok after)
    (issued : reference.owner < arena.nextOwner) (frame : Loans.Frame) (separate) :
    ¬ Live after.world reference ∧ ¬ Live (after.reserve frame separate).world reference := by
  have invalidated : after = arena.invalidate reference.owner := by
    unfold Loans.Arena.endLifetime at ended
    cases found : arena.world reference.owner with
    | none => simp [found] at ended
    | some loan =>
      by_cases root : ticket = loan.stack.ticket ∧ loan.stack.isRoot = true
      · simp [found, root] at ended; exact ended.symm
      · simp [found, root] at ended
  subst invalidated
  have dead : (arena.invalidate reference.owner).world reference.owner = none := by
    simp [Loans.Arena.invalidate, Loans.set]
  have still := Loans.Arena.retired_not_revived arena reference.owner issued frame separate
  exact ⟨by simp [Live, dead], by simp [Live, still]⟩

-- A valid reference can be reused for reads without consuming its shared loan.
-- Preservation across caller execution requires the caller to obey these loan
-- checks; Rust lifetime and physical payload adequacy remain separate obligations.
end Borrowed

end Provium.State.FieldReads
