import Provium.Loans

/- Initialized optional-array slots for source-ordered Option::take traversals.
   The outer Option tracks initialization; an initialized None is distinct from
   moved-out storage. The loan reserves the complete logical array region.
   Physical array layout, source ownership and cleanup remain separate proofs. -/
namespace Provium.State.ArrayMoves

abbrev Slots (α : Type) := List (Option (Option α))

inductive Result (α : Type) where
  | done (moved : List (Option α)) (remaining : Slots α)
  | bounds (index : Nat) (moved : List (Option α)) (remaining : Slots α)
  | uninitialized (index : Nat) (moved : List (Option α)) (remaining : Slots α)

def prepend (entry : Option α) : Result α → Result α
  | .done moved remaining => .done (entry :: moved) (some none :: remaining)
  | .bounds index moved remaining => .bounds index (entry :: moved) (some none :: remaining)
  | .uninitialized index moved remaining => .uninitialized index (entry :: moved) (some none :: remaining)

def run (inclusive : Bool) (length : Nat) : Nat → Nat → Slots α → Result α
  | _, 0, source => .done [] source
  | index, count + 1, source =>
    if (if inclusive then index ≤ length else index < length) then
      match source with
      | [] => .bounds index [] []
      | none :: rest => .uninitialized index [] (none :: rest)
      | some entry :: rest => prepend entry (run inclusive length (index + 1) count rest)
    else .done (List.replicate (count + 1) none) source

def initializedSlots (source : List (Option α)) : Slots α := source.map some

def lift : SlotMoves α → Result α
  | .done moved remaining => .done moved (initializedSlots remaining)
  | .bounds index moved remaining => .bounds index moved (initializedSlots remaining)

theorem run_refines (inclusive : Bool) (length start count : Nat) (source : List (Option α)) :
    run inclusive length start count (initializedSlots source) =
      lift (moveSlots inclusive length start count source) := by
  induction count generalizing start source with
  | zero => rfl
  | succ count ih =>
    by_cases hit : (if inclusive then start ≤ length else start < length)
    · cases source with
      | nil => simp [run, moveSlots, initializedSlots, hit, lift]
      | cons entry rest =>
        simp only [initializedSlots, List.map_cons, run, moveSlots, hit, ↓reduceIte]
        rw [show List.map some rest = initializedSlots rest from rfl, ih]
        cases moveSlots inclusive length (start + 1) count rest <;> rfl
    · simp only [run, moveSlots, hit, ↓reduceIte, lift]

def move (world : Loans.World) (owner ticket : Nat) (path : Path)
    (inclusive : Bool) (length start count : Nat) (source : Slots α) :
    Except Loans.Fault (Result α) :=
  if Loans.Allowed world owner ticket ⟨path, .exclusive⟩ then
    .ok (run inclusive length start count source)
  else .error .denied

theorem move_refines
    (allowed : Loans.Allowed world owner ticket ⟨path, .exclusive⟩) :
    move world owner ticket path inclusive length start count (initializedSlots source) =
      .ok (lift (moveSlots inclusive length start count source)) := by
  simp only [move, allowed, ↓reduceIte, run_refines]

-- An exclusive array traversal cannot coexist with an independently admitted
-- alias into that array, including a shared alias to any nested subregion.
theorem excludes_other_access (valid : Loans.Valid world) (different : owner ≠ otherOwner)
    (allowed : Loans.Allowed world owner ticket ⟨path, .exclusive⟩)
    (other : Loans.Allowed world otherOwner otherTicket ⟨otherPath, mode⟩) :
    ¬ (path <+: otherPath ∨ otherPath <+: path) :=
  Loans.exclusive_excludes valid different allowed other

end Provium.State.ArrayMoves
