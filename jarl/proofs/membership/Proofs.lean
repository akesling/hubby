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

namespace MembershipProjection

theorem voters_exact (entries : ArrayStore α) :
    JarlMembership.membership_Membership_voters entries = entries.filterMap (fun entry =>
      match entry with
      | none => none
      | some state => if evalCondition (.field ["voter"]) state then some (state ["id"]) else none) := rfl

theorem voters_member (entries : ArrayStore α) (identity : Cell α) :
    identity ∈ JarlMembership.membership_Membership_voters entries ↔
      ∃ state, some state ∈ entries ∧ state ["voter"] = .boolean true ∧ state ["id"] = identity := by
  simpa [JarlMembership.membership_Membership_voters,
    JarlMembership.membership_Membership_voters_ir, evalCondition_field_true] using
      projectArray_member JarlMembership.membership_Membership_voters_ir entries identity

theorem old_voters_exact (entries : ArrayStore α) :
    JarlMembership.membership_Membership_old_voters entries = entries.filterMap (fun entry =>
      match entry with
      | none => none
      | some state => if evalCondition (.field ["old"]) state then some (state ["id"]) else none) := rfl

theorem old_voters_member (entries : ArrayStore α) (identity : Cell α) :
    identity ∈ JarlMembership.membership_Membership_old_voters entries ↔
      ∃ state, some state ∈ entries ∧ state ["old"] = .boolean true ∧ state ["id"] = identity := by
  simpa [JarlMembership.membership_Membership_old_voters,
    JarlMembership.membership_Membership_old_voters_ir, evalCondition_field_true] using
      projectArray_member JarlMembership.membership_Membership_old_voters_ir entries identity

theorem learners_exact (entries : ArrayStore α) :
    JarlMembership.membership_Membership_learners entries = entries.filterMap (fun entry =>
      match entry with
      | none => none
      | some state => if evalCondition (.field ["learner"]) state then some (state ["id"]) else none) := rfl

theorem learners_member (entries : ArrayStore α) (identity : Cell α) :
    identity ∈ JarlMembership.membership_Membership_learners entries ↔
      ∃ state, some state ∈ entries ∧ state ["learner"] = .boolean true ∧ state ["id"] = identity := by
  simpa [JarlMembership.membership_Membership_learners,
    JarlMembership.membership_Membership_learners_ir, evalCondition_field_true] using
      projectArray_member JarlMembership.membership_Membership_learners_ir entries identity

private theorem voters_slot (entry : Option (Store α)) :
    projectSlot JarlMembership.membership_Membership_voters_ir
      (mapSlot JarlMembership.membership_Membership_finalized_slot entry) =
    projectSlot JarlMembership.membership_Membership_voters_ir entry := by
  cases entry with
  | none => rfl
  | some state =>
    cases hv : evalCondition (.field ["voter"]) state <;>
      cases hl : evalCondition (.field ["learner"]) state <;>
      simp only [evalCondition] at hv hl <;>
      simp [projectSlot, JarlMembership.membership_Membership_voters_ir,
        JarlMembership.membership_Membership_finalized_slot, mapSlot, evalCondition, put, hv, hl]

theorem finalization_preserves_voters (entries : ArrayStore α) :
    JarlMembership.membership_Membership_voters
      (JarlMembership.membership_Membership_finalized entries) =
    JarlMembership.membership_Membership_voters entries := by
  change (entries.map (mapSlot JarlMembership.membership_Membership_finalized_slot)).filterMap
    (projectSlot JarlMembership.membership_Membership_voters_ir) =
    entries.filterMap (projectSlot JarlMembership.membership_Membership_voters_ir)
  rw [List.filterMap_map]
  apply congrArg (fun f => entries.filterMap f)
  funext entry
  exact voters_slot entry

private theorem learners_slot (entry : Option (Store α)) :
    projectSlot JarlMembership.membership_Membership_learners_ir
      (mapSlot JarlMembership.membership_Membership_finalized_slot entry) =
    projectSlot JarlMembership.membership_Membership_learners_ir entry := by
  cases entry with
  | none => rfl
  | some state =>
    cases hv : evalCondition (.field ["voter"]) state <;>
      cases hl : evalCondition (.field ["learner"]) state <;>
      simp only [evalCondition] at hv hl <;>
      simp [projectSlot, JarlMembership.membership_Membership_learners_ir,
        JarlMembership.membership_Membership_finalized_slot, mapSlot, evalCondition, put, hv, hl]

theorem finalization_preserves_learners (entries : ArrayStore α) :
    JarlMembership.membership_Membership_learners
      (JarlMembership.membership_Membership_finalized entries) =
    JarlMembership.membership_Membership_learners entries := by
  change (entries.map (mapSlot JarlMembership.membership_Membership_finalized_slot)).filterMap
    (projectSlot JarlMembership.membership_Membership_learners_ir) =
    entries.filterMap (projectSlot JarlMembership.membership_Membership_learners_ir)
  rw [List.filterMap_map]
  apply congrArg (fun f => entries.filterMap f)
  funext entry
  exact learners_slot entry

theorem finalization_has_no_old_voters (entries : ArrayStore α) :
    JarlMembership.membership_Membership_old_voters
      (JarlMembership.membership_Membership_finalized entries) = [] := by
  apply List.filterMap_eq_nil_iff.mpr
  intro entry member
  cases entry with
  | none => rfl
  | some state =>
    have cleared := Finalization.all_old_flags_cleared entries state member
    simp [projectSlot, JarlMembership.membership_Membership_old_voters_ir, evalCondition, cleared]
end MembershipProjection

namespace IdentityQuery
open Provium.State JarlMembership

theorem contains_exact [DecidableEq α] (entries : ArrayStore α) (key : Cell α) :
    membership_Membership_contains entries key = true ↔
      ∃ state, some state ∈ entries ∧ state ["id"] = key := by
  rw [membership_Membership_contains, queryKey_member, projectArray_member]
  simp [membership_Membership_contains_ir, evalCondition]

theorem is_voter_exact [DecidableEq α] (entries : ArrayStore α) (key : Cell α) :
    membership_Membership_is_voter entries key = true ↔
      key ∈ membership_Membership_voters entries ∨
      key ∈ membership_Membership_old_voters entries := by
  rw [membership_Membership_is_voter, queryKey_member, projectArray_member,
    MembershipProjection.voters_member, MembershipProjection.old_voters_member]
  simp only [membership_Membership_is_voter_ir, evalCondition, Bool.or_eq_true]
  constructor
  · rintro ⟨state, member, flag, value⟩
    rcases flag with voter | old
    · exact Or.inl ⟨state, member, (evalCondition_field_true state ["voter"]).mp voter, value⟩
    · exact Or.inr ⟨state, member, (evalCondition_field_true state ["old"]).mp old, value⟩
  · rintro (⟨state, member, flag, value⟩ | ⟨state, member, flag, value⟩)
    · exact ⟨state, member, Or.inl ((evalCondition_field_true state ["voter"]).mpr flag), value⟩
    · exact ⟨state, member, Or.inr ((evalCondition_field_true state ["old"]).mpr flag), value⟩

theorem voter_participates [DecidableEq α] (entries : ArrayStore α) (key : Cell α)
    (voter : membership_Membership_is_voter entries key = true) :
    membership_Membership_contains entries key = true := by
  rw [contains_exact]
  rw [is_voter_exact] at voter
  rcases voter with current | old
  · obtain ⟨state, member, _, value⟩ := (MembershipProjection.voters_member entries key).mp current
    exact ⟨state, member, value⟩
  · obtain ⟨state, member, _, value⟩ := (MembershipProjection.old_voters_member entries key).mp old
    exact ⟨state, member, value⟩
end IdentityQuery
