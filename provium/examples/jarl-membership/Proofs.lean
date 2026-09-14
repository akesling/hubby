import Generated
open Provium.State
namespace Finalization

theorem capacity_preserved (entries : ArrayStore α) :
    (JarlMembership.membership_Membership_finalized entries).length = entries.length := by
  rw [← JarlMembership.membership_Membership_finalized_correspondence]
  exact executeArray_length _ _

-- All four voter/learner combinations, for any identity and other Copy fields.
-- The returned slot keeps its identity exactly when it remains a voter/learner.
theorem slot_effect (state : Store α) (voter learner : Bool)
    (hv : state ["voter"] = .boolean voter)
    (hl : state ["learner"] = .boolean learner) :
    JarlMembership.membership_Membership_finalized [some state] =
      [if voter || learner then some (put (put state ["$present"] (.boolean true)) ["old"] (.boolean false)) else none] := by
  cases voter <;> cases learner <;>
    simp [JarlMembership.membership_Membership_finalized,
      JarlMembership.membership_Membership_finalized_slot, mapSlot, evalCondition, put, hv, hl]

theorem retained_fields (state result : Store α)
    (retained : JarlMembership.membership_Membership_finalized [some state] = [some result]) :
    result ["old"] = .boolean false ∧
      (∀ key, key ≠ ["old"] → key ≠ ["$present"] → result key = state key) := by
  simp only [JarlMembership.membership_Membership_finalized, List.map_cons, List.map_nil] at retained
  simp only [mapSlot, JarlMembership.membership_Membership_finalized_slot] at retained
  split at retained
  · simp [evalCondition, put] at retained
  · simp only [evalCondition, put] at retained
    simp at retained
    subst result
    constructor
    · simp [put]
    · intro key ho hp
      simp [put, ho, hp]
theorem all_old_flags_cleared (entries : ArrayStore α) (result : Store α)
    (member : some result ∈ JarlMembership.membership_Membership_finalized entries) :
    result ["old"] = .boolean false := by
  simp only [JarlMembership.membership_Membership_finalized, List.mem_map] at member
  obtain ⟨entry, _, effect⟩ := member
  cases entry with
  | none => simp [mapSlot] at effect
  | some state =>
    have retained : JarlMembership.membership_Membership_finalized [some state] = [some result] := by
      simpa [JarlMembership.membership_Membership_finalized] using congrArg (fun x => [x]) effect
    exact (retained_fields state result retained).1

theorem identity_origin (entries : ArrayStore α) (result : Store α)
    (member : some result ∈ JarlMembership.membership_Membership_finalized entries) :
    ∃ before, some before ∈ entries ∧ result ["id"] = before ["id"] := by
  simp only [JarlMembership.membership_Membership_finalized, List.mem_map] at member
  obtain ⟨entry, source, effect⟩ := member
  cases entry with
  | none => simp [mapSlot] at effect
  | some before =>
    have retained : JarlMembership.membership_Membership_finalized [some before] = [some result] := by
      simpa [JarlMembership.membership_Membership_finalized] using congrArg (fun x => [x]) effect
    exact ⟨before, source, (retained_fields before result retained).2 _ (by decide) (by decide)⟩

-- Both sides are translations of entire production Rust methods. No fixed
-- population size is assumed, and empty slots are preserved.
theorem no_longer_joint (entries : ArrayStore α) :
    JarlMembership.membership_Membership_is_joint
      (JarlMembership.membership_Membership_finalized entries) = false := by
  simp only [JarlMembership.membership_Membership_is_joint, List.any_eq_false]
  intro entry member
  cases entry with
  | none => simp
  | some state =>
    have cleared := all_old_flags_cleared entries state member
    simp [evalCondition, cleared]
end Finalization
