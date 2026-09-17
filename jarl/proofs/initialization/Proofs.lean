import Generated
open Provium.State
namespace Initialization

theorem fresh_fields (sizes : String → Nat) :
    JarlInitial.state_State_new sizes ["hard", "term"] = .unsigned "u64" 0 ∧
    JarlInitial.state_State_new sizes ["hard", "voted_for"] = .absent ∧
    JarlInitial.state_State_new sizes ["hard", "commit"] = .unsigned "u64" 0 ∧
    JarlInitial.state_State_new sizes ["snapshot"] = .absent ∧
    JarlInitial.state_State_new sizes ["entries"] = .slots (List.replicate (sizes "CAP") none) ∧
    JarlInitial.state_State_new sizes ["len"] = .unsigned "usize" 0 := by
  simp [JarlInitial.state_State_new, JarlInitial.state_State_new_ir,
    initializeFields, initialCell]

theorem initial_length_within_capacity (sizes : String → Nat) :
    ∃ len, JarlInitial.state_State_new sizes ["len"] = .unsigned "usize" len ∧
      len ≤ sizes "CAP" := by
  exact ⟨0, (fresh_fields sizes).2.2.2.2.2, Nat.zero_le _⟩

theorem all_slots_empty (sizes : String → Nat) (entries : List (Option Unit))
    (h : JarlInitial.state_State_new sizes ["entries"] = .slots entries) :
    entries.length = sizes "CAP" ∧ ∀ slot ∈ entries, slot = none := by
  rw [(fresh_fields sizes).2.2.2.2.1] at h
  cases h
  simp

-- Constructor syntax, derived defaults and capacity substitution are checked
-- independently of the flattened field IR. Rust resolution and physical
-- initialization remain explicit source-correspondence obligations.
theorem source_fresh_fields (sizes : String → Nat) :
    ∃ result,
      JarlInitial.state_State_new_source_run sizes = .ok result ∧
      result = JarlInitial.state_State_new sizes ∧
      result ["hard", "term"] = .unsigned "u64" 0 ∧
      result ["hard", "voted_for"] = .absent ∧
      result ["hard", "commit"] = .unsigned "u64" 0 ∧
      result ["snapshot"] = .absent ∧
      result ["entries"] = .slots (List.replicate (sizes "CAP") none) ∧
      result ["len"] = .unsigned "usize" 0 := by
  exact ⟨JarlInitial.state_State_new sizes, JarlInitial.state_State_new_source_refinement sizes,
    rfl, fresh_fields sizes⟩

end Initialization
