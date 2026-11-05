import Generated

/-!
`state::State::new`: initial hard-state fields, absent snapshot, all slots empty
for arbitrary capacity, and initial `len ≤ CAP`.
-/

namespace Jarl.Contracts.Initialization

theorem fresh_fields {V S : Type} {CAP : Nat} :
    (State.new : State V S CAP).hard.term = 0 ∧
    (State.new : State V S CAP).hard.voted_for = none ∧
    (State.new : State V S CAP).hard.commit = 0 ∧
    (State.new : State V S CAP).snapshot = none ∧
    (State.new : State V S CAP).entries = Vector.replicate CAP none ∧
    (State.new : State V S CAP).len = 0 := by
  refine ⟨rfl, rfl, rfl, rfl, ?_, rfl⟩
  apply Vector.ext
  intro i hi
  simp [State.new, Rust.Slice.from_fn]

theorem initial_length_within_capacity {V S : Type} {CAP : Nat} :
    (State.new : State V S CAP).len.val ≤ CAP := by
  rw [fresh_fields.2.2.2.2.2]
  exact Nat.zero_le _

theorem all_slots_empty {V S : Type} {CAP : Nat} :
    (State.new : State V S CAP).entries.toList.length = CAP ∧
    ∀ slot ∈ (State.new : State V S CAP).entries.toList, slot = none := by
  rw [fresh_fields.2.2.2.2.1]
  simp

/-- The whole constructed record. In the typed backend the translated definition
    is the source constructor itself, so this is the source-level claim. -/
theorem source_fresh_fields {V S : Type} {CAP : Nat} :
    (State.new : State V S CAP) =
      { hard := { term := 0, voted_for := none, commit := 0 }, snapshot := none,
        entries := Vector.replicate CAP none, len := 0 } := by
  obtain ⟨_, _, _, _, he, _⟩ := (fresh_fields : (State.new : State V S CAP).hard.term = 0 ∧ _)
  rw [← he]
  rfl

end Jarl.Contracts.Initialization
