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

namespace Inclusion
open Provium.State JarlMembership

theorem capacity_preserved [DecidableEq α] (entries : ArrayStore α) (key : Cell α) (tag : Nat) :
    (membership_Membership_include entries key tag).1.length = entries.length :=
  runUpsert_length membership_Membership_include_ir entries key tag

theorem selected_slot [DecidableEq α] (entries : ArrayStore α) (key : Cell α) (tag index : Nat)
    (selected : upsertIndex membership_Membership_include_ir entries key = some index) :
    ∃ entry, entries[index]? = some entry ∧
      membership_Membership_include entries key tag =
        (entries.set index (some (upsertRecord membership_Membership_include_ir key tag entry)), none) :=
  runUpsert_selected membership_Membership_include_ir entries key tag index selected

theorem full_error [DecidableEq α] (entries : ArrayStore α) (key : Cell α) (tag : Nat) :
    (membership_Membership_include entries key tag).2 = some "Config" ↔
      upsertIndex membership_Membership_include_ir entries key = none :=
  runUpsert_error membership_Membership_include_ir entries key tag

theorem full_exact [DecidableEq α] (entries : ArrayStore α) (key : Cell α) (tag : Nat) :
    (membership_Membership_include entries key tag).2 = some "Config" ↔
      (∀ state, some state ∈ entries → state ["id"] ≠ key) ∧ none ∉ entries := by
  rw [full_error]
  exact upsertIndex_none membership_Membership_include_ir entries key

theorem other_slots_unchanged [DecidableEq α] (entries : ArrayStore α) (key : Cell α)
    (tag index other : Nat) (selected : upsertIndex membership_Membership_include_ir entries key = some index)
    (different : other ≠ index) : (membership_Membership_include entries key tag).1[other]? = entries[other]? :=
  runUpsert_frame membership_Membership_include_ir entries key tag index other selected different

def selectedFlag (tag : Nat) : Path :=
  if tag = 0 then ["voter"] else if tag = 1 then ["learner"] else ["old"]

theorem existing_record (state : Store α) (key : Cell α) (tag : Nat) :
    upsertRecord membership_Membership_include_ir key tag (some state) =
      put state (selectedFlag tag) (.boolean true) := by
  by_cases zero : tag = 0
  · subst tag; rfl
  · by_cases one : tag = 1
    · subst tag; rfl
    · simp [upsertRecord, upsertWrite, membership_Membership_include_ir, selectedFlag,
        zero, one, run, value, beq_iff_eq, Ne.symm zero, Ne.symm one]

theorem new_identity (key : Cell α) (tag : Nat) :
    upsertRecord membership_Membership_include_ir key tag none ["id"] = key := by
  by_cases zero : tag = 0
  · subst tag; simp [upsertRecord, upsertWrite, membership_Membership_include_ir, run, put]
  · by_cases one : tag = 1
    · subst tag; simp [upsertRecord, upsertWrite, membership_Membership_include_ir, run, put]
    · simp [upsertRecord, upsertWrite, membership_Membership_include_ir, run, put,
        beq_iff_eq, Ne.symm zero, Ne.symm one]

theorem selected_flag_set (entry : Option (Store α)) (key : Cell α) (tag : Nat) :
    upsertRecord membership_Membership_include_ir key tag entry (selectedFlag tag) = .boolean true := by
  by_cases zero : tag = 0
  · subst tag; simp [upsertRecord, upsertWrite, membership_Membership_include_ir, selectedFlag, run, value, put]
  · by_cases one : tag = 1
    · subst tag; simp [upsertRecord, upsertWrite, membership_Membership_include_ir, selectedFlag, run, value, put]
    · simp [upsertRecord, upsertWrite, membership_Membership_include_ir, selectedFlag, run, value, put,
        zero, one, beq_iff_eq, Ne.symm zero, Ne.symm one]

def emptyRecord (key : Cell α) : Store α :=
  put (run [⟨["voter"], .boolean false⟩, ⟨["old"], .boolean false⟩,
    ⟨["learner"], .boolean false⟩] (fun _ => .absent)) ["id"] key

theorem new_record (key : Cell α) (tag : Nat) :
    upsertRecord membership_Membership_include_ir key tag none =
      put (emptyRecord key) (selectedFlag tag) (.boolean true) := by
  by_cases zero : tag = 0
  · subst tag; rfl
  · by_cases one : tag = 1
    · subst tag; rfl
    · simp [upsertRecord, upsertWrite, membership_Membership_include_ir, selectedFlag,
        emptyRecord, zero, one, run, value, beq_iff_eq, Ne.symm zero, Ne.symm one]

theorem selected_identity [DecidableEq α] (entries : ArrayStore α) (key : Cell α)
    (tag index : Nat) (selected : upsertIndex membership_Membership_include_ir entries key = some index) :
    ∃ state, (membership_Membership_include entries key tag).1[index]? = some (some state) ∧
      state ["id"] = key := by
  obtain ⟨entry, found, eligible⟩ := upsertIndex_selected membership_Membership_include_ir entries key index selected
  have result : membership_Membership_include entries key tag =
      (entries.set index (some (upsertRecord membership_Membership_include_ir key tag entry)), none) := by
    simp [membership_Membership_include, runUpsert, selected, found]
  refine ⟨upsertRecord membership_Membership_include_ir key tag entry, ?_, ?_⟩
  · have bound : index < entries.length := List.getElem?_eq_some_iff.mp found |>.1
    simp [result, bound]
  · cases entry with
    | none => exact new_identity key tag
    | some state =>
      have identity : state ["id"] = key := by
        rcases eligible with equal | impossible
        · exact of_decide_eq_true equal
        · cases impossible
      rw [existing_record]
      by_cases zero : tag = 0
      · simp [put, selectedFlag, identity, zero]
      · by_cases one : tag = 1 <;> simp [put, selectedFlag, identity, zero, one]

theorem selected_effect [DecidableEq α] (entries : ArrayStore α) (key : Cell α)
    (tag index : Nat) (selected : upsertIndex membership_Membership_include_ir entries key = some index) :
    ∃ entry, entries[index]? = some entry ∧
      membership_Membership_include entries key tag =
        (entries.set index (some (put (entry.getD (emptyRecord key)) (selectedFlag tag) (.boolean true))), none) := by
  obtain ⟨entry, found, result⟩ := selected_slot entries key tag index selected
  refine ⟨entry, found, ?_⟩
  cases entry with
  | none => simpa only [new_record, Option.getD_none] using result
  | some state => simpa only [existing_record, Option.getD_some] using result

theorem full_unchanged [DecidableEq α] (entries : ArrayStore α) (key : Cell α) (tag : Nat)
    (full : (membership_Membership_include entries key tag).2 = some "Config") :
    (membership_Membership_include entries key tag).1 = entries := by
  have missing := (full_error entries key tag).mp full
  simp [membership_Membership_include, runUpsert, missing]

-- The constructor must establish this invariant; include preserves it without
-- assuming that the requested identity is new or that an empty slot exists.
def UniqueIdentities (entries : ArrayStore α) : Prop :=
  ∀ (i j : Nat) (left right : Store α), entries[i]? = some (some left) → entries[j]? = some (some right) →
    left ["id"] = right ["id"] → i = j

theorem preserves_unique [DecidableEq α] (entries : ArrayStore α) (key : Cell α) (tag : Nat)
    (unique : UniqueIdentities entries) : UniqueIdentities (membership_Membership_include entries key tag).1 := by
  cases selected : upsertIndex membership_Membership_include_ir entries key with
  | none => simpa [membership_Membership_include, runUpsert, selected] using unique
  | some index =>
    obtain ⟨before, beforeAt, eligible⟩ := upsertIndex_selected membership_Membership_include_ir entries key index selected
    obtain ⟨after, afterAt, afterKey⟩ := selected_identity entries key tag index selected
    have only : ∀ j state, (membership_Membership_include entries key tag).1[j]? = some (some state) →
        state ["id"] = key → j = index := by
      intro j state atJ keyJ
      by_cases same : j = index
      · exact same
      · have original : entries[j]? = some (some state) := by
          rw [other_slots_unchanged entries key tag index j selected same] at atJ
          exact atJ
        cases before with
        | none =>
          have missing := upsertIndex_empty_no_match membership_Membership_include_ir entries key index selected beforeAt
          have absent := (firstSlot_none _ _).mp missing (some state)
          have member : some state ∈ entries := by
            obtain ⟨bound, value⟩ := List.getElem?_eq_some_iff.mp original
            exact List.mem_of_getElem value
          have impossible := absent member
          simp [keySlot, membership_Membership_include_ir, keyJ] at impossible
        | some previous =>
          have previousKey : previous ["id"] = key := by
            rcases eligible with equality | impossible
            · exact of_decide_eq_true equality
            · cases impossible
          exact unique j index state previous original beforeAt (keyJ.trans previousKey.symm)
    intro i j left right leftAt rightAt equal
    by_cases leftSelected : i = index
    · subst i
      have leftEq : left = after := by rw [afterAt] at leftAt; simpa using leftAt.symm
      subst left
      exact (only j right rightAt (equal.symm.trans afterKey)).symm
    · by_cases rightSelected : j = index
      · subst j
        have rightEq : right = after := by rw [afterAt] at rightAt; simpa using rightAt.symm
        subst right
        exact only i left leftAt (equal.trans afterKey)
      · rw [other_slots_unchanged entries key tag index i selected leftSelected] at leftAt
        rw [other_slots_unchanged entries key tag index j selected rightSelected] at rightAt
        exact unique i j left right leftAt rightAt equal

end Inclusion

namespace Restoration
open Provium.State JarlMembership

theorem capacity_preserved [DecidableEq α] (capacity : Nat) (voters old learners : List (Cell α))
    (result : ArrayStore α) (success : membership_Membership_restore capacity voters old learners = .ok result) :
    result.length = capacity := runSlotBatch_length membership_Membership_restore_ir capacity [voters, old, learners] result success

theorem unique_identities [DecidableEq α] (capacity : Nat) (voters old learners : List (Cell α))
    (result : ArrayStore α) (success : membership_Membership_restore capacity voters old learners = .ok result) :
    Inclusion.UniqueIdentities result := by
  apply runSlotBatch_preserves membership_Membership_restore_ir Inclusion.UniqueIdentities _ capacity [voters, old, learners] result _ success
  · intro entries key tag unique _
    exact Inclusion.preserves_unique entries key tag unique
  · intro i j left right leftAt _ _
    have member : some left ∈ List.replicate capacity (none : Option (Store α)) :=
      List.mem_of_getElem (List.getElem?_eq_some_iff.mp leftAt).2
    simp at member

theorem empty_voters [DecidableEq α] (capacity : Nat) (old learners : List (Cell α)) :
    membership_Membership_restore capacity [] old learners = .error "Config" := by
  simp [membership_Membership_restore, runSlotBatch, membership_Membership_restore_ir]

theorem single_voter [DecidableEq α] (key : Cell α) :
    membership_Membership_restore 1 [key] [] [] =
      .ok [some (put (Inclusion.emptyRecord key) ["voter"] (.boolean true))] := by
  simp [membership_Membership_restore, runSlotBatch, membership_Membership_restore_ir,
    runSlotBatchPasses, runSlotBatchPass, runUpsert, upsertIndex, firstSlot, keySlot,
    upsertRecord, upsertWrite, membership_Membership_restore_insert_ir, Inclusion.emptyRecord, run, value]

theorem duplicate_voter [DecidableEq α] (key : Cell α) :
    membership_Membership_restore 2 [key, key] [] [] = .error "Config" := by
  simp [membership_Membership_restore, runSlotBatch, membership_Membership_restore_ir,
    runSlotBatchPasses, runSlotBatchPass, runUpsert, upsertIndex, firstSlot, keySlot,
    membership_Membership_restore_insert_ir]

theorem learner_overlap [DecidableEq α] (key : Cell α) :
    membership_Membership_restore 2 [key] [] [key] = .error "Config" := by
  simp [membership_Membership_restore, runSlotBatch, membership_Membership_restore_ir,
    runSlotBatchPasses, runSlotBatchPass, runUpsert, upsertIndex, firstSlot, keySlot,
    membership_Membership_restore_insert_ir]
theorem nonempty_voters [DecidableEq α] (capacity : Nat) (voters old learners : List (Cell α))
    (result : ArrayStore α) (success : membership_Membership_restore capacity voters old learners = .ok result) : voters ≠ [] := by
  have valid := (runSlotBatch_valid membership_Membership_restore_ir capacity [voters, old, learners] result success).1
  simpa [membership_Membership_restore_ir] using valid

theorem distinct_inputs [DecidableEq α] (capacity : Nat) (voters old learners : List (Cell α))
    (result : ArrayStore α) (success : membership_Membership_restore capacity voters old learners = .ok result) :
    voters.Nodup ∧ old.Nodup ∧ learners.Nodup := by
  have valid := (runSlotBatch_valid membership_Membership_restore_ir capacity [voters, old, learners] result success).2
  have votersValid := (valid (0, 0) (by simp [membership_Membership_restore_ir])).1
  have oldValid := (valid (1, 2) (by simp [membership_Membership_restore_ir])).1
  have learnersValid := (valid (2, 1) (by simp [membership_Membership_restore_ir])).1
  exact ⟨by simpa using votersValid, by simpa using oldValid, by simpa using learnersValid⟩

theorem learners_disjoint [DecidableEq α] (capacity : Nat) (voters old learners : List (Cell α))
    (result : ArrayStore α) (success : membership_Membership_restore capacity voters old learners = .ok result) :
    ∀ key ∈ learners, key ∉ voters := by
  have valid := (runSlotBatch_valid membership_Membership_restore_ir capacity [voters, old, learners] result success).2
  have learnersValid := (valid (2, 1) (by simp [membership_Membership_restore_ir])).2 (by rfl)
  simpa [membership_Membership_restore_ir] using learnersValid

end Restoration

namespace StableConstruction
open Provium.State JarlMembership

theorem delegates_to_restore [DecidableEq α] (capacity : Nat) (voters learners : List (Cell α)) :
    membership_Membership_new capacity voters learners = membership_Membership_restore capacity voters [] learners := rfl

theorem capacity_preserved [DecidableEq α] (capacity : Nat) (voters learners : List (Cell α))
    (result : ArrayStore α) (success : membership_Membership_new capacity voters learners = .ok result) :
    result.length = capacity := Restoration.capacity_preserved capacity voters [] learners result success

theorem unique_identities [DecidableEq α] (capacity : Nat) (voters learners : List (Cell α))
    (result : ArrayStore α) (success : membership_Membership_new capacity voters learners = .ok result) :
    Inclusion.UniqueIdentities result := Restoration.unique_identities capacity voters [] learners result success

theorem valid_inputs [DecidableEq α] (capacity : Nat) (voters learners : List (Cell α))
    (result : ArrayStore α) (success : membership_Membership_new capacity voters learners = .ok result) :
    voters ≠ [] ∧ voters.Nodup ∧ learners.Nodup ∧ ∀ key ∈ learners, key ∉ voters := by
  have distinct := Restoration.distinct_inputs capacity voters [] learners result success
  exact ⟨Restoration.nonempty_voters capacity voters [] learners result success,
    distinct.1, distinct.2.2, Restoration.learners_disjoint capacity voters [] learners result success⟩
end StableConstruction

namespace SetInterpretation
open Provium.State JarlMembership Inclusion

def SlotFlag (flag : Path) (key : Cell α) : Option (Store α) → Prop
  | none => False
  | some state => state ["id"] = key ∧ state flag = .boolean true

def FlagMember (flag : Path) (entries : ArrayStore α) (key : Cell α) : Prop :=
  ∃ slot ∈ entries, SlotFlag flag key slot

def ValidFlag (flag : Path) : Prop := flag = ["voter"] ∨ flag = ["learner"] ∨ flag = ["old"]

theorem selectedFlag_ne_id (tag : Nat) : selectedFlag tag ≠ ["id"] := by
  by_cases zero : tag = 0
  · simp [selectedFlag, zero]
  · by_cases one : tag = 1 <;> simp [selectedFlag, zero, one]

theorem emptyRecord_flag (flag : Path) (valid : ValidFlag flag) (key : Cell α) :
    emptyRecord key flag = .boolean false := by
  rcases valid with rfl | rfl | rfl <;> rfl

theorem slot_flag_effect [DecidableEq α] (flag : Path) (valid : ValidFlag flag)
    (query key : Cell α) (tag : Nat) (entry : Option (Store α))
    (eligible : keySlot ["id"] key entry = true ∨ entry = none) :
    SlotFlag flag query (some (put (entry.getD (emptyRecord key)) (selectedFlag tag) (.boolean true))) ↔
      SlotFlag flag query entry ∨ (key = query ∧ flag = selectedFlag tag) := by
  have noId := Ne.symm (selectedFlag_ne_id tag)
  cases entry with
  | none =>
    have initial := emptyRecord_flag flag valid key
    by_cases hit : flag = selectedFlag tag
    · simp only [SlotFlag, Option.getD_none, put, if_neg noId, if_pos hit]
      simp [hit, emptyRecord, put]
    · simp only [SlotFlag, Option.getD_none, put, if_neg noId, if_neg hit, initial]
      simp [hit]
  | some state =>
    have identity : state ["id"] = key := by
      rcases eligible with same | impossible
      · exact of_decide_eq_true same
      · cases impossible
    by_cases hit : flag = selectedFlag tag
    · simp only [SlotFlag, Option.getD_some, put, if_neg noId, if_pos hit, identity]
      simp [hit]
      intro equal _
      exact equal
    · simp only [SlotFlag, Option.getD_some, put, if_neg noId, if_neg hit, identity]
      simp [hit]

theorem include_flag [DecidableEq α] (flag : Path) (valid : ValidFlag flag)
    (entries : ArrayStore α) (query key : Cell α) (tag : Nat)
    (success : (membership_Membership_include entries key tag).2 = none) :
    FlagMember flag (membership_Membership_include entries key tag).1 query ↔
      FlagMember flag entries query ∨ (key = query ∧ flag = selectedFlag tag) := by
  cases selected : upsertIndex membership_Membership_include_ir entries key with
  | none => simp [membership_Membership_include, runUpsert, selected] at success
  | some index =>
    obtain ⟨before, atBefore, eligible⟩ := upsertIndex_selected membership_Membership_include_ir entries key index selected
    have result : membership_Membership_include entries key tag =
        (entries.set index (some (put (before.getD (emptyRecord key)) (selectedFlag tag) (.boolean true))), none) := by
      obtain ⟨entry, atEntry, result⟩ := selected_effect entries key tag index selected
      rw [atBefore] at atEntry
      cases atEntry
      exact result
    rw [result]
    exact exists_set_observation entries index before _ (SlotFlag flag query) _ atBefore
      (slot_flag_effect flag valid query key tag before eligible)
theorem flag_member_iff (flag : Path) (entries : ArrayStore α) (query : Cell α) :
    FlagMember flag entries query ↔
      ∃ state, some state ∈ entries ∧ state flag = .boolean true ∧ state ["id"] = query := by
  constructor
  · rintro ⟨entry, member, flag⟩
    cases entry with
    | none => cases flag
    | some state => exact ⟨state, member, flag.2, flag.1⟩
  · rintro ⟨state, member, flag, identity⟩
    exact ⟨some state, member, identity, flag⟩

theorem restore_flags [DecidableEq α] (flag : Path) (valid : ValidFlag flag)
    (capacity : Nat) (voters old learners : List (Cell α)) (result : ArrayStore α)
    (success : membership_Membership_restore capacity voters old learners = .ok result) (query : Cell α) :
    FlagMember flag result query ↔
      (query ∈ voters ∧ flag = ["voter"]) ∨ (query ∈ learners ∧ flag = ["learner"]) ∨
      (query ∈ old ∧ flag = ["old"]) := by
  have initial : ¬FlagMember flag (List.replicate capacity (none : Option (Store α))) query := by
    rintro ⟨entry, member, observed⟩
    cases entry with
    | none => exact observed
    | some state => simp at member
  have step : ∀ entries key tag, (runUpsert membership_Membership_restore_ir.insert entries key tag).2 = none →
      (FlagMember flag (runUpsert membership_Membership_restore_ir.insert entries key tag).1 query ↔
        FlagMember flag entries query ∨ (key = query ∧ flag = selectedFlag tag)) := by
    intro entries key tag succeeded
    exact include_flag flag valid entries query key tag succeeded
  have relation := runSlotBatch_observes membership_Membership_restore_ir
    (fun entries => FlagMember flag entries query) (fun key tag => key = query ∧ flag = selectedFlag tag)
    step capacity [voters, old, learners] result success
  simpa [membership_Membership_restore_ir, selectedFlag, initial, and_left_comm, and_assoc] using relation

theorem voters_exact [DecidableEq α] (capacity : Nat) (voters old learners : List (Cell α))
    (result : ArrayStore α) (success : membership_Membership_restore capacity voters old learners = .ok result)
    (query : Cell α) : query ∈ membership_Membership_voters result ↔ query ∈ voters := by
  rw [MembershipProjection.voters_member, ← flag_member_iff]
  simpa using restore_flags ["voter"] (Or.inl rfl) capacity voters old learners result success query

theorem old_voters_exact [DecidableEq α] (capacity : Nat) (voters old learners : List (Cell α))
    (result : ArrayStore α) (success : membership_Membership_restore capacity voters old learners = .ok result)
    (query : Cell α) : query ∈ membership_Membership_old_voters result ↔ query ∈ old := by
  rw [MembershipProjection.old_voters_member, ← flag_member_iff]
  simpa using restore_flags ["old"] (Or.inr (Or.inr rfl)) capacity voters old learners result success query

theorem learners_exact [DecidableEq α] (capacity : Nat) (voters old learners : List (Cell α))
    (result : ArrayStore α) (success : membership_Membership_restore capacity voters old learners = .ok result)
    (query : Cell α) : query ∈ membership_Membership_learners result ↔ query ∈ learners := by
  rw [MembershipProjection.learners_member, ← flag_member_iff]
  simpa using restore_flags ["learner"] (Or.inr (Or.inl rfl)) capacity voters old learners result success query

theorem stable_voters_exact [DecidableEq α] (capacity : Nat) (voters learners : List (Cell α))
    (result : ArrayStore α) (success : membership_Membership_new capacity voters learners = .ok result)
    (query : Cell α) : query ∈ membership_Membership_voters result ↔ query ∈ voters :=
  voters_exact capacity voters [] learners result success query

theorem stable_learners_exact [DecidableEq α] (capacity : Nat) (voters learners : List (Cell α))
    (result : ArrayStore α) (success : membership_Membership_new capacity voters learners = .ok result)
    (query : Cell α) : query ∈ membership_Membership_learners result ↔ query ∈ learners :=
  learners_exact capacity voters [] learners result success query

theorem stable_old_empty [DecidableEq α] (capacity : Nat) (voters learners : List (Cell α))
    (result : ArrayStore α) (success : membership_Membership_new capacity voters learners = .ok result) :
    membership_Membership_old_voters result = [] := by
  cases old : membership_Membership_old_voters result with
  | nil => rfl
  | cons key rest =>
    have present : key ∈ membership_Membership_old_voters result := by simp [old]
    have impossible := (old_voters_exact capacity voters [] learners result success key).mp present
    cases impossible

def SlotKey (query : Cell α) : Option (Store α) → Prop
  | none => False
  | some state => state ["id"] = query

def HasIdentity (entries : ArrayStore α) (query : Cell α) : Prop :=
  ∃ entry ∈ entries, SlotKey query entry

theorem include_identity [DecidableEq α] (entries : ArrayStore α) (query key : Cell α) (tag : Nat)
    (success : (membership_Membership_include entries key tag).2 = none) :
    HasIdentity (membership_Membership_include entries key tag).1 query ↔ HasIdentity entries query ∨ key = query := by
  cases selected : upsertIndex membership_Membership_include_ir entries key with
  | none => simp [membership_Membership_include, runUpsert, selected] at success
  | some index =>
    obtain ⟨before, atBefore, eligible⟩ := upsertIndex_selected membership_Membership_include_ir entries key index selected
    have result : membership_Membership_include entries key tag =
        (entries.set index (some (put (before.getD (emptyRecord key)) (selectedFlag tag) (.boolean true))), none) := by
      obtain ⟨entry, atEntry, result⟩ := selected_effect entries key tag index selected
      rw [atBefore] at atEntry
      cases atEntry
      exact result
    have noId := Ne.symm (selectedFlag_ne_id tag)
    have effect : SlotKey query (some (put (before.getD (emptyRecord key)) (selectedFlag tag) (.boolean true))) ↔
        SlotKey query before ∨ key = query := by
      cases before with
      | none => simp [SlotKey, put, noId, emptyRecord]
      | some state =>
        have identity : state ["id"] = key := by
          rcases eligible with equal | impossible
          · exact of_decide_eq_true equal
          · cases impossible
        simp [SlotKey, put, noId, identity]
    rw [result]
    exact exists_set_observation entries index before _ (SlotKey query) _ atBefore effect

theorem has_identity_iff (entries : ArrayStore α) (query : Cell α) :
    HasIdentity entries query ↔ ∃ state, some state ∈ entries ∧ state ["id"] = query := by
  constructor
  · rintro ⟨entry, member, identity⟩
    cases entry with
    | none => cases identity
    | some state => exact ⟨state, member, identity⟩
  · rintro ⟨state, member, identity⟩
    exact ⟨some state, member, identity⟩

theorem restore_identities [DecidableEq α] (capacity : Nat) (voters old learners : List (Cell α))
    (result : ArrayStore α) (success : membership_Membership_restore capacity voters old learners = .ok result)
    (query : Cell α) : HasIdentity result query ↔ query ∈ voters ∨ query ∈ learners ∨ query ∈ old := by
  have initial : ¬HasIdentity (List.replicate capacity (none : Option (Store α))) query := by
    rintro ⟨entry, member, observed⟩
    cases entry with
    | none => exact observed
    | some state => simp at member
  have step : ∀ entries key tag, (runUpsert membership_Membership_restore_ir.insert entries key tag).2 = none →
      (HasIdentity (runUpsert membership_Membership_restore_ir.insert entries key tag).1 query ↔
        HasIdentity entries query ∨ key = query) := by
    intro entries key tag succeeded
    exact include_identity entries query key tag succeeded
  have relation := runSlotBatch_observes membership_Membership_restore_ir
    (fun entries => HasIdentity entries query) (fun key _ => key = query)
    step capacity [voters, old, learners] result success
  simpa [membership_Membership_restore_ir, initial] using relation

theorem restored_contains_exact [DecidableEq α] (capacity : Nat) (voters old learners : List (Cell α))
    (result : ArrayStore α) (success : membership_Membership_restore capacity voters old learners = .ok result)
    (query : Cell α) : membership_Membership_contains result query = true ↔ query ∈ voters ∨ query ∈ learners ∨ query ∈ old := by
  rw [IdentityQuery.contains_exact, ← has_identity_iff]
  exact restore_identities capacity voters old learners result success query

theorem joint_iff_old_nonempty (entries : ArrayStore α) :
    membership_Membership_is_joint entries = true ↔ membership_Membership_old_voters entries ≠ [] := by
  constructor
  · intro joint empty
    obtain ⟨entry, member, marked⟩ := List.any_eq_true.mp joint
    cases entry with
    | none => cases marked
    | some state =>
      have oldFlag := (evalCondition_field_true state ["old"]).mp marked
      have present := (MembershipProjection.old_voters_member entries (state ["id"])).mpr ⟨state, member, oldFlag, rfl⟩
      rw [empty] at present
      cases present
  · intro nonempty
    cases old : membership_Membership_old_voters entries with
    | nil => exact False.elim (nonempty old)
    | cons query rest =>
      have present : query ∈ membership_Membership_old_voters entries := by simp [old]
      obtain ⟨state, member, marked, _⟩ := (MembershipProjection.old_voters_member entries query).mp present
      exact List.any_eq_true.mpr ⟨some state, member, (evalCondition_field_true state ["old"]).mpr marked⟩

theorem stable_not_joint [DecidableEq α] (capacity : Nat) (voters learners : List (Cell α))
    (result : ArrayStore α) (success : membership_Membership_new capacity voters learners = .ok result) :
    membership_Membership_is_joint result = false := by
  cases joint : membership_Membership_is_joint result with
  | false => rfl
  | true => exact False.elim ((joint_iff_old_nonempty result).mp joint (stable_old_empty capacity voters learners result success))

theorem voter_count_bounds [DecidableEq α] (capacity : Nat) (voters old learners : List (Cell α))
    (result : ArrayStore α) (success : membership_Membership_restore capacity voters old learners = .ok result) :
    0 < (membership_Membership_voters result).length ∧ (membership_Membership_voters result).length ≤ capacity := by
  constructor
  · have nonempty := Restoration.nonempty_voters capacity voters old learners result success
    cases voters with
    | nil => exact False.elim (nonempty rfl)
    | cons key rest =>
      have member := (voters_exact capacity (key :: rest) old learners result success key).mpr (by simp)
      exact List.length_pos_of_mem member
  · have bounded := projectArray_length membership_Membership_voters_ir result
    change (projectArray membership_Membership_voters_ir result).length ≤ capacity
    rw [← Restoration.capacity_preserved capacity voters old learners result success]
    exact bounded

end SetInterpretation

namespace CapacityAcceptance
open Provium.State JarlMembership Inclusion SetInterpretation

def Keys (entries : ArrayStore α) : List (Cell α) :=
  projectArray ⟨.boolean true, ["id"]⟩ entries

theorem keys_member (entries : ArrayStore α) (query : Cell α) : query ∈ Keys entries ↔ HasIdentity entries query := by
  rw [Keys, projectArray_member, has_identity_iff]
  simp [evalCondition]

theorem keys_nodup (entries : ArrayStore α) (unique : UniqueIdentities entries) : (Keys entries).Nodup := by
  induction entries with
  | nil => simp [Keys, projectArray]
  | cons entry rest ih =>
    have tailUnique : UniqueIdentities rest := by
      intro i j left right leftAt rightAt equal
      have same := unique (i + 1) (j + 1) left right (by simpa using leftAt) (by simpa using rightAt) equal
      omega
    cases entry with
    | none => exact ih tailUnique
    | some state =>
      change (state ["id"] :: Keys rest).Nodup
      apply List.nodup_cons.mpr
      refine ⟨?_, ih tailUnique⟩
      intro present
      obtain ⟨other, member, same⟩ := (has_identity_iff rest (state ["id"])).mp ((keys_member rest _).mp present)
      obtain ⟨index, atIndex⟩ := List.mem_iff_getElem?.mp member
      have impossible := unique 0 (index + 1) state other rfl (by simpa using atIndex) same.symm
      omega

theorem keys_length_full (entries : ArrayStore α) (full : none ∉ entries) : (Keys entries).length = entries.length := by
  induction entries with
  | nil => rfl
  | cons entry rest ih =>
    have tailFull : none ∉ rest := fun member => full (List.mem_cons_of_mem _ member)
    cases entry with
    | none => exact False.elim (full (by simp))
    | some state =>
      change (Keys rest).length + 1 = rest.length + 1
      rw [ih tailFull]

-- A finite cover expresses that the union of requested identities fits. The
-- cover may be chosen as the duplicate-free union; insertion does not require
-- that old and target voter sets be disjoint.
def Fits (capacity : Nat) (voters old learners : List (Cell α)) : Prop :=
  ∃ domainKeys : List (Cell α), domainKeys.length ≤ capacity ∧
    ∀ key, key ∈ voters ∨ key ∈ learners ∨ key ∈ old → key ∈ domainKeys

def Covered (capacity : Nat) (domainKeys : List (Cell α)) (entries : ArrayStore α) : Prop :=
  UniqueIdentities entries ∧ entries.length = capacity ∧ ∀ key, HasIdentity entries key → key ∈ domainKeys

theorem include_available [DecidableEq α] (capacity : Nat) (domainKeys : List (Cell α))
    (fits : domainKeys.length ≤ capacity) (entries : ArrayStore α) (covered : Covered capacity domainKeys entries)
    (key : Cell α) (admitted : key ∈ domainKeys) (tag : Nat) :
    ∃ result, membership_Membership_include entries key tag = (result, none) := by
  cases selected : upsertIndex membership_Membership_include_ir entries key with
  | some index =>
    obtain ⟨entry, _, execution⟩ := selected_slot entries key tag index selected
    exact ⟨_, execution⟩
  | none =>
    obtain ⟨absent, full⟩ := (upsertIndex_none membership_Membership_include_ir entries key).mp selected
    have missing : key ∉ Keys entries := by
      intro member
      obtain ⟨state, member, equal⟩ := (has_identity_iff entries key).mp ((keys_member entries key).mp member)
      exact absent state member equal
    have distinct : (key :: Keys entries).Nodup := List.nodup_cons.mpr ⟨missing, keys_nodup entries covered.1⟩
    have subset : key :: Keys entries ⊆ domainKeys := by
      intro query member
      rcases List.mem_cons.mp member with same | member
      · simpa [same] using admitted
      · exact covered.2.2 query ((keys_member entries query).mp member)
    have bound := distinct.length_le_of_subset subset
    have length := (keys_length_full entries full).trans covered.2.1
    simp only [List.length_cons, length] at bound
    omega

theorem include_covered [DecidableEq α] (capacity : Nat) (domainKeys : List (Cell α))
    (entries : ArrayStore α) (covered : Covered capacity domainKeys entries) (key : Cell α)
    (admitted : key ∈ domainKeys) (tag : Nat) (success : (membership_Membership_include entries key tag).2 = none) :
    Covered capacity domainKeys (membership_Membership_include entries key tag).1 := by
  refine ⟨preserves_unique entries key tag covered.1,
    (Inclusion.capacity_preserved entries key tag).trans covered.2.1, ?_⟩
  intro query present
  rcases (include_identity entries query key tag success).mp present with prior | same
  · exact covered.2.2 query prior
  · simpa [same] using admitted

def ValidInputs (voters old learners : List (Cell α)) : Prop :=
  voters ≠ [] ∧ voters.Nodup ∧ old.Nodup ∧ learners.Nodup ∧ ∀ key ∈ learners, key ∉ voters

theorem restore_accepts [DecidableEq α] (capacity : Nat) (voters old learners : List (Cell α))
    (valid : ValidInputs voters old learners) (fits : Fits capacity voters old learners) :
    ∃ result, membership_Membership_restore capacity voters old learners = .ok result := by
  obtain ⟨domainKeys, bound, covers⟩ := fits
  have initial : Covered capacity domainKeys (List.replicate capacity none) := by
    refine ⟨?_, by simp, ?_⟩
    · intro i j left right leftAt _ _
      have member := List.mem_of_getElem? leftAt
      simp at member
    · intro key present
      obtain ⟨state, member, _⟩ := (has_identity_iff _ key).mp present
      simp at member
  have step : ∀ entries key tag, Covered capacity domainKeys entries → key ∈ domainKeys →
      ∃ next, runUpsert membership_Membership_restore_ir.insert entries key tag = (next, none) ∧ Covered capacity domainKeys next := by
    intro entries key tag covered admitted
    obtain ⟨next, execution⟩ := include_available capacity domainKeys bound entries covered key admitted tag
    refine ⟨next, execution, ?_⟩
    have preserved := include_covered capacity domainKeys entries covered key admitted tag (by simp [execution])
    simpa only [execution] using preserved
  have passes : ∀ pass ∈ membership_Membership_restore_ir.passes,
      ([voters, old, learners][pass.1]?.getD []).Nodup ∧
      (pass.2 = membership_Membership_restore_ir.exclusionTag → ∀ key ∈ [voters, old, learners][pass.1]?.getD [],
        key ∉ [voters, old, learners][membership_Membership_restore_ir.exclusionInput]?.getD []) ∧
      ∀ key ∈ [voters, old, learners][pass.1]?.getD [], key ∈ domainKeys := by
    intro pass member
    simp only [membership_Membership_restore_ir, List.mem_cons, List.not_mem_nil, or_false] at member
    rcases member with rfl | rfl | rfl
    · exact ⟨valid.2.1, by simp [membership_Membership_restore_ir], fun key member => covers key (Or.inl member)⟩
    · exact ⟨valid.2.2.2.1, fun _ => valid.2.2.2.2, fun key member => covers key (Or.inr (Or.inl member))⟩
    · exact ⟨valid.2.2.1, by simp [membership_Membership_restore_ir], fun key member => covers key (Or.inr (Or.inr member))⟩
  obtain ⟨result, success, _⟩ := runSlotBatch_accepts membership_Membership_restore_ir (Covered capacity domainKeys)
    (fun key => key ∈ domainKeys) step capacity [voters, old, learners] initial valid.1 passes
  exact ⟨result, success⟩

theorem restore_accepts_iff [DecidableEq α] (capacity : Nat) (voters old learners : List (Cell α)) :
    (∃ result, membership_Membership_restore capacity voters old learners = .ok result) ↔
      ValidInputs voters old learners ∧ Fits capacity voters old learners := by
  constructor
  · rintro ⟨result, success⟩
    have distinct := Restoration.distinct_inputs capacity voters old learners result success
    refine ⟨⟨Restoration.nonempty_voters capacity voters old learners result success, distinct.1, distinct.2.1,
      distinct.2.2, Restoration.learners_disjoint capacity voters old learners result success⟩, ?_⟩
    refine ⟨Keys result, ?_, ?_⟩
    · exact Nat.le_trans (projectArray_length ⟨.boolean true, ["id"]⟩ result) (Nat.le_of_eq (Restoration.capacity_preserved capacity voters old learners result success))
    · intro key member
      exact (keys_member result key).mpr ((restore_identities capacity voters old learners result success key).mpr member)
  · rintro ⟨valid, fits⟩
    exact restore_accepts capacity voters old learners valid fits

theorem stable_accepts_iff [DecidableEq α] (capacity : Nat) (voters learners : List (Cell α)) :
    (∃ result, membership_Membership_new capacity voters learners = .ok result) ↔
      ValidInputs voters [] learners ∧ Fits capacity voters [] learners :=
  restore_accepts_iff capacity voters [] learners
-- Specification-only enumeration of the identity union. The implementation
-- transition above is still generated from Rust; this defines its size criterion.
def uniqueKeys [DecidableEq α] : List α → List α
  | [] => []
  | key :: rest => if key ∈ uniqueKeys rest then uniqueKeys rest else key :: uniqueKeys rest

theorem uniqueKeys_member [DecidableEq α] (keys : List α) (query : α) :
    query ∈ uniqueKeys keys ↔ query ∈ keys := by
  induction keys with
  | nil => rfl
  | cons key rest ih =>
    by_cases present : key ∈ uniqueKeys rest
    · rw [uniqueKeys, if_pos present, ih]
      constructor
      · exact List.mem_cons_of_mem _
      · intro member
        rcases List.mem_cons.mp member with same | member
        · subst query
          exact (by simpa only [ih] using present)
        · exact member
    · simp only [uniqueKeys, if_neg present, List.mem_cons, ih]

theorem uniqueKeys_nodup [DecidableEq α] (keys : List α) : (uniqueKeys keys).Nodup := by
  induction keys with
  | nil => simp [uniqueKeys]
  | cons key rest ih =>
    by_cases present : key ∈ uniqueKeys rest
    · simpa only [uniqueKeys, if_pos present] using ih
    · exact (by simpa only [uniqueKeys, if_neg present, List.nodup_cons] using And.intro present ih)

theorem fits_iff_count [DecidableEq α] (capacity : Nat) (voters old learners : List (Cell α)) :
    Fits capacity voters old learners ↔ (uniqueKeys (voters ++ learners ++ old)).length ≤ capacity := by
  constructor
  · rintro ⟨domainKeys, bound, covers⟩
    have subset : uniqueKeys (voters ++ learners ++ old) ⊆ domainKeys := by
      intro query member
      have original := (uniqueKeys_member _ query).mp member
      exact covers query (by simpa [List.mem_append, or_assoc] using original)
    exact Nat.le_trans ((uniqueKeys_nodup _).length_le_of_subset subset) bound
  · intro bound
    refine ⟨uniqueKeys (voters ++ learners ++ old), bound, ?_⟩
    intro query member
    exact (uniqueKeys_member _ query).mpr (by simpa [List.mem_append, or_assoc] using member)

theorem restore_accepts_by_count [DecidableEq α] (capacity : Nat) (voters old learners : List (Cell α)) :
    (∃ result, membership_Membership_restore capacity voters old learners = .ok result) ↔
      ValidInputs voters old learners ∧ (uniqueKeys (voters ++ learners ++ old)).length ≤ capacity := by
  rw [restore_accepts_iff, fits_iff_count]

theorem stable_accepts_by_count [DecidableEq α] (capacity : Nat) (voters learners : List (Cell α)) :
    (∃ result, membership_Membership_new capacity voters learners = .ok result) ↔
      ValidInputs voters [] learners ∧ (uniqueKeys (voters ++ learners)).length ≤ capacity := by
  simp only [StableConstruction.delegates_to_restore]
  simpa only [List.append_nil] using restore_accepts_by_count capacity voters [] learners

theorem stored_identity_count [DecidableEq α] (capacity : Nat) (voters old learners : List (Cell α))
    (result : ArrayStore α) (success : membership_Membership_restore capacity voters old learners = .ok result) :
    (Keys result).length = (uniqueKeys (voters ++ learners ++ old)).length := by
  have membership : ∀ query, query ∈ Keys result ↔ query ∈ uniqueKeys (voters ++ learners ++ old) := by
    intro query
    rw [keys_member, restore_identities capacity voters old learners result success query, uniqueKeys_member]
    simp [List.mem_append]
  apply Nat.le_antisymm
  · exact (keys_nodup result (Restoration.unique_identities capacity voters old learners result success)).length_le_of_subset
      (fun query member => (membership query).mp member)
  · exact (uniqueKeys_nodup _).length_le_of_subset (fun query member => (membership query).mpr member)

theorem restore_error_code [DecidableEq α] (capacity : Nat) (voters old learners : List (Cell α))
    (error : String) (failure : membership_Membership_restore capacity voters old learners = .error error) :
    error = "Config" := by
  have allowed := runSlotBatch_error_codes membership_Membership_restore_ir capacity [voters, old, learners] error failure
  simpa [membership_Membership_restore_ir, membership_Membership_restore_insert_ir] using allowed

theorem restore_rejects_iff [DecidableEq α] (capacity : Nat) (voters old learners : List (Cell α)) :
    membership_Membership_restore capacity voters old learners = .error "Config" ↔
      ¬(ValidInputs voters old learners ∧ (uniqueKeys (voters ++ learners ++ old)).length ≤ capacity) := by
  constructor
  · intro failure valid
    obtain ⟨result, success⟩ := (restore_accepts_by_count capacity voters old learners).mpr valid
    rw [failure] at success
    cases success
  · intro invalid
    cases outcome : membership_Membership_restore capacity voters old learners with
    | ok result => exact False.elim (invalid ((restore_accepts_by_count capacity voters old learners).mp ⟨result, outcome⟩))
    | error error => simp [restore_error_code capacity voters old learners error outcome]

theorem stable_rejects_iff [DecidableEq α] (capacity : Nat) (voters learners : List (Cell α)) :
    membership_Membership_new capacity voters learners = .error "Config" ↔
      ¬(ValidInputs voters [] learners ∧ (uniqueKeys (voters ++ learners)).length ≤ capacity) := by
  simp only [StableConstruction.delegates_to_restore]
  simpa only [List.append_nil] using restore_rejects_iff capacity voters [] learners

end CapacityAcceptance


namespace Peers
open JarlMembership SetInterpretation

theorem capacity_preserved (entries : ArrayStore α) :
    (membership_Membership_peers entries).length = entries.length :=
  mapArrayField_length membership_Membership_peers_ir entries

theorem slot_identity (entries : ArrayStore α) (index : Nat) :
    (membership_Membership_peers entries)[index]? =
      entries[index]?.map (fun slot => slot.map (fun state => state ["id"])) :=
  mapArrayField_at membership_Membership_peers_ir entries index

theorem member_iff (entries : ArrayStore α) (query : Cell α) :
    some query ∈ membership_Membership_peers entries ↔ HasIdentity entries query := by
  rw [has_identity_iff]
  exact mapArrayField_member membership_Membership_peers_ir entries query

theorem restored_members [DecidableEq α] (capacity : Nat) (voters old learners : List (Cell α))
    (result : ArrayStore α) (success : membership_Membership_restore capacity voters old learners = .ok result)
    (query : Cell α) :
    some query ∈ membership_Membership_peers result ↔ query ∈ voters ∨ query ∈ learners ∨ query ∈ old := by
  rw [member_iff]
  exact restore_identities capacity voters old learners result success query

theorem stable_members [DecidableEq α] (capacity : Nat) (voters learners : List (Cell α))
    (result : ArrayStore α) (success : membership_Membership_new capacity voters learners = .ok result)
    (query : Cell α) :
    some query ∈ membership_Membership_peers result ↔ query ∈ voters ∨ query ∈ learners := by
  simpa using restored_members capacity voters [] learners result success query

end Peers

namespace LearnerReplacement
open JarlMembership Inclusion SetInterpretation

theorem capacity_preserved [DecidableEq α] (capacity : Nat) (original result : ArrayStore α)
    (learners : List (Cell α)) (success : membership_Membership_with_learners capacity original learners = .ok result) :
    result.length = capacity := by
  apply runRebuild_preserves membership_Membership_with_learners_ir (fun entries => entries.length = capacity) _ capacity original learners result (by simp) success
  intro entries key tag initial _
  simpa only [runUpsert_length] using initial

theorem unique_identities [DecidableEq α] (capacity : Nat) (original result : ArrayStore α)
    (learners : List (Cell α)) (success : membership_Membership_with_learners capacity original learners = .ok result) :
    UniqueIdentities result := by
  apply runRebuild_preserves membership_Membership_with_learners_ir UniqueIdentities _ capacity original learners result _ success
  · intro entries key tag initial _
    exact Inclusion.preserves_unique entries key tag initial
  · intro i j left right leftAt _ _
    have member : some left ∈ List.replicate capacity (none : Option (Store α)) :=
      List.mem_of_getElem (List.getElem?_eq_some_iff.mp leftAt).2
    simp at member

theorem flags [DecidableEq α] (flag : Path) (valid : ValidFlag flag) (capacity : Nat)
    (original result : ArrayStore α) (learners : List (Cell α))
    (success : membership_Membership_with_learners capacity original learners = .ok result) (query : Cell α) :
    FlagMember flag result query ↔
      (query ∈ membership_Membership_voters original ∧ flag = ["voter"]) ∨
      (query ∈ learners ∧ flag = ["learner"]) := by
  have initial : ¬FlagMember flag (List.replicate capacity (none : Option (Store α))) query := by
    rintro ⟨entry, member, observed⟩
    cases entry with
    | none => exact observed
    | some state => simp at member
  have step : ∀ entries key tag, (runUpsert membership_Membership_with_learners_ir.insert entries key tag).2 = none →
      (FlagMember flag (runUpsert membership_Membership_with_learners_ir.insert entries key tag).1 query ↔
        FlagMember flag entries query ∨ (key = query ∧ flag = selectedFlag tag)) := by
    intro entries key tag succeeded
    exact include_flag flag valid entries query key tag succeeded
  have relation := runRebuild_observes membership_Membership_with_learners_ir
    (fun entries => FlagMember flag entries query) (fun key tag => key = query ∧ flag = selectedFlag tag)
    step capacity original learners result success
  simpa [membership_Membership_with_learners_ir, membership_Membership_voters,
    membership_Membership_with_learners_projection_ir, membership_Membership_voters_ir,
    selectedFlag, initial, and_left_comm, and_assoc] using relation

theorem voters_exact [DecidableEq α] (capacity : Nat) (original result : ArrayStore α)
    (learners : List (Cell α)) (success : membership_Membership_with_learners capacity original learners = .ok result)
    (query : Cell α) : query ∈ membership_Membership_voters result ↔ query ∈ membership_Membership_voters original := by
  rw [MembershipProjection.voters_member, ← flag_member_iff]
  simpa using flags ["voter"] (Or.inl rfl) capacity original result learners success query

theorem learners_exact [DecidableEq α] (capacity : Nat) (original result : ArrayStore α)
    (learners : List (Cell α)) (success : membership_Membership_with_learners capacity original learners = .ok result)
    (query : Cell α) : query ∈ membership_Membership_learners result ↔ query ∈ learners := by
  rw [MembershipProjection.learners_member, ← flag_member_iff]
  simpa using flags ["learner"] (Or.inr (Or.inl rfl)) capacity original result learners success query

theorem old_empty [DecidableEq α] (capacity : Nat) (original result : ArrayStore α)
    (learners : List (Cell α)) (success : membership_Membership_with_learners capacity original learners = .ok result) :
    membership_Membership_old_voters result = [] := by
  cases old : membership_Membership_old_voters result with
  | nil => rfl
  | cons key rest =>
    have present : key ∈ membership_Membership_old_voters result := by simp [old]
    have marked := (flag_member_iff ["old"] result key).mpr ((MembershipProjection.old_voters_member result key).mp present)
    have impossible := (flags ["old"] (Or.inr (Or.inr rfl)) capacity original result learners success key).mp marked
    simp at impossible

theorem valid_inputs [DecidableEq α] (capacity : Nat) (original result : ArrayStore α)
    (learners : List (Cell α)) (success : membership_Membership_with_learners capacity original learners = .ok result) :
    learners.Nodup ∧ ∀ key ∈ learners, membership_Membership_is_voter original key = false := by
  exact runRebuild_valid membership_Membership_with_learners_ir capacity original learners result success

theorem identities [DecidableEq α] (capacity : Nat) (original result : ArrayStore α)
    (learners : List (Cell α)) (success : membership_Membership_with_learners capacity original learners = .ok result)
    (query : Cell α) : HasIdentity result query ↔ query ∈ membership_Membership_voters original ∨ query ∈ learners := by
  have initial : ¬HasIdentity (List.replicate capacity (none : Option (Store α))) query := by
    rintro ⟨entry, member, observed⟩
    cases entry with
    | none => exact observed
    | some state => simp at member
  have step : ∀ entries key tag, (runUpsert membership_Membership_with_learners_ir.insert entries key tag).2 = none →
      (HasIdentity (runUpsert membership_Membership_with_learners_ir.insert entries key tag).1 query ↔
        HasIdentity entries query ∨ key = query) := by
    intro entries key tag succeeded
    exact include_identity entries query key tag succeeded
  have relation := runRebuild_observes membership_Membership_with_learners_ir
    (fun entries => HasIdentity entries query) (fun key _ => key = query)
    step capacity original learners result success
  simpa [membership_Membership_with_learners_ir, membership_Membership_voters,
    membership_Membership_with_learners_projection_ir, membership_Membership_voters_ir, initial] using relation

open CapacityAcceptance

def ValidLearners [DecidableEq α] (original : ArrayStore α) (learners : List (Cell α)) : Prop :=
  learners.Nodup ∧ ∀ key ∈ learners, membership_Membership_is_voter original key = false

theorem accepts [DecidableEq α] (capacity : Nat) (original : ArrayStore α) (learners : List (Cell α))
    (valid : ValidLearners original learners) (fits : Fits capacity (membership_Membership_voters original) [] learners) :
    ∃ result, membership_Membership_with_learners capacity original learners = .ok result := by
  obtain ⟨domainKeys, bound, covers⟩ := fits
  have initial : Covered capacity domainKeys (List.replicate capacity none) := by
    refine ⟨?_, by simp, ?_⟩
    · intro i j left right leftAt _ _
      have member := List.mem_of_getElem? leftAt
      simp at member
    · intro key present
      obtain ⟨state, member, _⟩ := (has_identity_iff _ key).mp present
      simp at member
  have step : ∀ entries key tag, Covered capacity domainKeys entries → key ∈ domainKeys →
      ∃ next, runUpsert membership_Membership_with_learners_ir.insert entries key tag = (next, none) ∧ Covered capacity domainKeys next := by
    intro entries key tag covered admitted
    obtain ⟨next, execution⟩ := include_available capacity domainKeys bound entries covered key admitted tag
    refine ⟨next, execution, ?_⟩
    have preserved := include_covered capacity domainKeys entries covered key admitted tag (by simp [execution])
    simpa only [execution] using preserved
  have projected : ∀ key ∈ projectArray membership_Membership_with_learners_ir.projection original, key ∈ domainKeys := by
    intro key member
    exact covers key (Or.inl member)
  obtain ⟨result, success, _⟩ := runRebuild_accepts membership_Membership_with_learners_ir
    (Covered capacity domainKeys) (fun key => key ∈ domainKeys) step capacity original learners initial projected valid.1 valid.2
    (fun key member => covers key (Or.inr (Or.inl member)))
  exact ⟨result, success⟩

theorem accepts_iff [DecidableEq α] (capacity : Nat) (original : ArrayStore α) (learners : List (Cell α)) :
    (∃ result, membership_Membership_with_learners capacity original learners = .ok result) ↔
      ValidLearners original learners ∧ Fits capacity (membership_Membership_voters original) [] learners := by
  constructor
  · rintro ⟨result, success⟩
    refine ⟨valid_inputs capacity original result learners success, Keys result, ?_, ?_⟩
    · exact Nat.le_trans (projectArray_length ⟨.boolean true, ["id"]⟩ result)
        (Nat.le_of_eq (capacity_preserved capacity original result learners success))
    · intro key member
      have member : key ∈ membership_Membership_voters original ∨ key ∈ learners := by simpa using member
      exact (keys_member result key).mpr ((identities capacity original result learners success key).mpr member)
  · rintro ⟨valid, fits⟩
    exact accepts capacity original learners valid fits

theorem accepts_by_count [DecidableEq α] (capacity : Nat) (original : ArrayStore α) (learners : List (Cell α)) :
    (∃ result, membership_Membership_with_learners capacity original learners = .ok result) ↔
      ValidLearners original learners ∧
        (uniqueKeys (membership_Membership_voters original ++ learners)).length ≤ capacity := by
  rw [accepts_iff, fits_iff_count]
  simp only [List.append_nil]

theorem error_code [DecidableEq α] (capacity : Nat) (original : ArrayStore α) (learners : List (Cell α))
    (error : String) (failure : membership_Membership_with_learners capacity original learners = .error error) :
    error = "Config" := by
  have codes := runRebuild_error_codes membership_Membership_with_learners_ir capacity original learners error failure
  simpa [membership_Membership_with_learners_ir, membership_Membership_with_learners_insert_ir] using codes

theorem rejects_iff [DecidableEq α] (capacity : Nat) (original : ArrayStore α) (learners : List (Cell α)) :
    membership_Membership_with_learners capacity original learners = .error "Config" ↔
      ¬(ValidLearners original learners ∧ (uniqueKeys (membership_Membership_voters original ++ learners)).length ≤ capacity) := by
  constructor
  · intro failure valid
    obtain ⟨result, success⟩ := (accepts_by_count capacity original learners).mpr valid
    rw [failure] at success
    cases success
  · intro invalid
    cases outcome : membership_Membership_with_learners capacity original learners with
    | ok result => exact False.elim (invalid ((accepts_by_count capacity original learners).mp ⟨result, outcome⟩))
    | error error => simp [error_code capacity original learners error outcome]

theorem not_joint [DecidableEq α] (capacity : Nat) (original result : ArrayStore α)
    (learners : List (Cell α)) (success : membership_Membership_with_learners capacity original learners = .ok result) :
    membership_Membership_is_joint result = false := by
  cases joint : membership_Membership_is_joint result with
  | false => rfl
  | true => exact False.elim ((joint_iff_old_nonempty result).mp joint (old_empty capacity original result learners success))

end LearnerReplacement

namespace JointConstruction
open JarlMembership Inclusion SetInterpretation CapacityAcceptance

theorem success_shape [DecidableEq α] (source target result : ArrayStore α) :
    membership_Membership_joint source target = .ok result ↔
      membership_Membership_is_joint source = false ∧ membership_Membership_is_joint target = false ∧
      runInsertPass membership_Membership_include_ir 2 (membership_Membership_voters source) target = .ok result :=
  runArrayMerge_success membership_Membership_joint_ir source target result

theorem capacity_preserved [DecidableEq α] (source target result : ArrayStore α)
    (success : membership_Membership_joint source target = .ok result) : result.length = target.length := by
  have pass := (success_shape source target result).mp success
  apply runInsertPass_preserves membership_Membership_include_ir 2 (fun entries => entries.length = target.length)
    _ (membership_Membership_voters source) target result rfl pass.2.2
  intro entries key initial _
  simpa only [runUpsert_length] using initial

theorem unique_identities [DecidableEq α] (source target result : ArrayStore α)
    (unique : UniqueIdentities target) (success : membership_Membership_joint source target = .ok result) :
    UniqueIdentities result := by
  have pass := (success_shape source target result).mp success
  apply runInsertPass_preserves membership_Membership_include_ir 2 UniqueIdentities
    _ (membership_Membership_voters source) target result unique pass.2.2
  intro entries key initial _
  exact Inclusion.preserves_unique entries key 2 initial

theorem flags [DecidableEq α] (flag : Path) (valid : ValidFlag flag) (source target result : ArrayStore α)
    (success : membership_Membership_joint source target = .ok result) (query : Cell α) :
    FlagMember flag result query ↔ FlagMember flag target query ∨
      (query ∈ membership_Membership_voters source ∧ flag = ["old"]) := by
  have pass := (success_shape source target result).mp success
  have step : ∀ entries key, (runUpsert membership_Membership_include_ir entries key 2).2 = none →
      (FlagMember flag (runUpsert membership_Membership_include_ir entries key 2).1 query ↔
        FlagMember flag entries query ∨ (key = query ∧ flag = ["old"])) := by
    intro entries key succeeded
    exact include_flag flag valid entries query key 2 succeeded
  have relation := runInsertPass_observes membership_Membership_include_ir 2 (fun entries => FlagMember flag entries query)
    (fun key => key = query ∧ flag = ["old"]) step (membership_Membership_voters source) target result pass.2.2
  simpa [and_left_comm, and_assoc] using relation

theorem voters_exact [DecidableEq α] (source target result : ArrayStore α)
    (success : membership_Membership_joint source target = .ok result) (query : Cell α) :
    query ∈ membership_Membership_voters result ↔ query ∈ membership_Membership_voters target := by
  rw [MembershipProjection.voters_member, MembershipProjection.voters_member, ← flag_member_iff, ← flag_member_iff]
  simpa using flags ["voter"] (Or.inl rfl) source target result success query

theorem learners_exact [DecidableEq α] (source target result : ArrayStore α)
    (success : membership_Membership_joint source target = .ok result) (query : Cell α) :
    query ∈ membership_Membership_learners result ↔ query ∈ membership_Membership_learners target := by
  rw [MembershipProjection.learners_member, MembershipProjection.learners_member, ← flag_member_iff, ← flag_member_iff]
  simpa using flags ["learner"] (Or.inr (Or.inl rfl)) source target result success query

theorem old_voters_exact [DecidableEq α] (source target result : ArrayStore α)
    (success : membership_Membership_joint source target = .ok result) (query : Cell α) :
    query ∈ membership_Membership_old_voters result ↔ query ∈ membership_Membership_voters source := by
  have stable := ((success_shape source target result).mp success).2.1
  have absent : ¬FlagMember ["old"] target query := by
    intro marked
    have present := (MembershipProjection.old_voters_member target query).mpr ((flag_member_iff ["old"] target query).mp marked)
    have nonempty : membership_Membership_old_voters target ≠ [] := by
      intro empty
      rw [empty] at present
      cases present
    have active := (joint_iff_old_nonempty target).mpr nonempty
    rw [stable] at active
    cases active
  rw [MembershipProjection.old_voters_member, ← flag_member_iff]
  simpa [absent] using flags ["old"] (Or.inr (Or.inr rfl)) source target result success query

theorem identities [DecidableEq α] (source target result : ArrayStore α)
    (success : membership_Membership_joint source target = .ok result) (query : Cell α) :
    HasIdentity result query ↔ HasIdentity target query ∨ query ∈ membership_Membership_voters source := by
  have pass := (success_shape source target result).mp success
  have step : ∀ entries key, (runUpsert membership_Membership_include_ir entries key 2).2 = none →
      (HasIdentity (runUpsert membership_Membership_include_ir entries key 2).1 query ↔ HasIdentity entries query ∨ key = query) := by
    intro entries key succeeded
    exact include_identity entries query key 2 succeeded
  have relation := runInsertPass_observes membership_Membership_include_ir 2 (fun entries => HasIdentity entries query)
    (fun key => key = query) step (membership_Membership_voters source) target result pass.2.2
  simpa using relation

def FitsMerge (source target : ArrayStore α) : Prop :=
  ∃ domainKeys : List (Cell α), domainKeys.length ≤ target.length ∧
    ∀ key, HasIdentity target key ∨ key ∈ membership_Membership_voters source → key ∈ domainKeys

theorem accepts [DecidableEq α] (source target : ArrayStore α) (unique : UniqueIdentities target)
    (source_stable : membership_Membership_is_joint source = false)
    (target_stable : membership_Membership_is_joint target = false) (fits : FitsMerge source target) :
    ∃ result, membership_Membership_joint source target = .ok result := by
  obtain ⟨domainKeys, bound, covers⟩ := fits
  have initial : Covered target.length domainKeys target := ⟨unique, rfl, fun key member => covers key (Or.inl member)⟩
  have step : ∀ entries key, Covered target.length domainKeys entries → key ∈ domainKeys →
      ∃ next, runUpsert membership_Membership_include_ir entries key 2 = (next, none) ∧ Covered target.length domainKeys next := by
    intro entries key covered admitted
    obtain ⟨next, execution⟩ := include_available target.length domainKeys bound entries covered key admitted 2
    refine ⟨next, execution, ?_⟩
    have preserved := include_covered target.length domainKeys entries covered key admitted 2 (by simp [execution])
    simpa only [execution] using preserved
  obtain ⟨result, pass, _⟩ := runInsertPass_accepts membership_Membership_include_ir 2 (Covered target.length domainKeys)
    (fun key => key ∈ domainKeys) step (membership_Membership_voters source) target initial (fun key member => covers key (Or.inr member))
  exact ⟨result, (success_shape source target result).mpr ⟨source_stable, target_stable, pass⟩⟩

theorem accepts_iff [DecidableEq α] (source target : ArrayStore α) (unique : UniqueIdentities target) :
    (∃ result, membership_Membership_joint source target = .ok result) ↔
      membership_Membership_is_joint source = false ∧ membership_Membership_is_joint target = false ∧ FitsMerge source target := by
  constructor
  · rintro ⟨result, success⟩
    have shape := (success_shape source target result).mp success
    refine ⟨shape.1, shape.2.1, Keys result, ?_, ?_⟩
    · exact Nat.le_trans (projectArray_length ⟨.boolean true, ["id"]⟩ result) (Nat.le_of_eq (capacity_preserved source target result success))
    · intro key member
      exact (keys_member result key).mpr ((identities source target result success key).mpr member)
  · rintro ⟨source_stable, target_stable, fits⟩
    exact accepts source target unique source_stable target_stable fits

theorem fits_by_count [DecidableEq α] (source target : ArrayStore α) :
    FitsMerge source target ↔ (uniqueKeys (Keys target ++ membership_Membership_voters source)).length ≤ target.length := by
  have equivalent : FitsMerge source target ↔ Fits target.length (Keys target) [] (membership_Membership_voters source) := by
    unfold FitsMerge Fits
    simp only [keys_member, List.not_mem_nil, or_false]
  rw [equivalent, fits_iff_count]
  simp only [List.append_nil]

theorem accepts_by_count [DecidableEq α] (source target : ArrayStore α) (unique : UniqueIdentities target) :
    (∃ result, membership_Membership_joint source target = .ok result) ↔
      membership_Membership_is_joint source = false ∧ membership_Membership_is_joint target = false ∧
        (uniqueKeys (Keys target ++ membership_Membership_voters source)).length ≤ target.length := by
  rw [accepts_iff source target unique, fits_by_count]

theorem guard_error_iff [DecidableEq α] (source target : ArrayStore α) :
    membership_Membership_joint source target = .error "Reconfiguring" ↔
      membership_Membership_is_joint source = true ∨ membership_Membership_is_joint target = true :=
  runArrayMerge_guard_error membership_Membership_joint_ir (by decide) source target

theorem error_codes [DecidableEq α] (source target : ArrayStore α) (error : String)
    (failure : membership_Membership_joint source target = .error error) :
    error = "Reconfiguring" ∨ error = "Full" :=
  runArrayMerge_error_codes membership_Membership_joint_ir source target error failure

theorem full_iff [DecidableEq α] (source target : ArrayStore α) (unique : UniqueIdentities target) :
    membership_Membership_joint source target = .error "Full" ↔
      membership_Membership_is_joint source = false ∧ membership_Membership_is_joint target = false ∧ ¬FitsMerge source target := by
  constructor
  · intro failure
    have inactive : ¬(membership_Membership_is_joint source = true ∨ membership_Membership_is_joint target = true) := by
      intro active
      have denied := (guard_error_iff source target).mpr active
      rw [failure] at denied
      simp at denied
    have stable : membership_Membership_is_joint source = false ∧ membership_Membership_is_joint target = false := by
      simpa using inactive
    refine ⟨stable.1, stable.2, ?_⟩
    intro fits
    obtain ⟨result, success⟩ := accepts source target unique stable.1 stable.2 fits
    rw [failure] at success
    cases success
  · rintro ⟨source_stable, target_stable, notFits⟩
    cases outcome : membership_Membership_joint source target with
    | ok result =>
      exact False.elim (notFits (((accepts_iff source target unique).mp ⟨result, outcome⟩).2.2))
    | error error =>
      rcases error_codes source target error outcome with guarded | full
      · subst error
        have active := (guard_error_iff source target).mp outcome
        simp [source_stable, target_stable] at active
      · simp [full]

theorem full_by_count [DecidableEq α] (source target : ArrayStore α) (unique : UniqueIdentities target) :
    membership_Membership_joint source target = .error "Full" ↔
      membership_Membership_is_joint source = false ∧ membership_Membership_is_joint target = false ∧
        target.length < (uniqueKeys (Keys target ++ membership_Membership_voters source)).length := by
  rw [full_iff source target unique, fits_by_count]
  simp only [Nat.not_le]

theorem joint_iff_source_voters [DecidableEq α] (source target result : ArrayStore α)
    (success : membership_Membership_joint source target = .ok result) :
    membership_Membership_is_joint result = true ↔ membership_Membership_voters source ≠ [] := by
  rw [joint_iff_old_nonempty]
  constructor
  · intro nonempty empty
    cases old : membership_Membership_old_voters result with
    | nil => exact nonempty old
    | cons key rest =>
      have present := (old_voters_exact source target result success key).mp (by simp [old])
      rw [empty] at present
      cases present
  · intro nonempty empty
    cases voters : membership_Membership_voters source with
    | nil => exact nonempty voters
    | cons key rest =>
      have present := (old_voters_exact source target result success key).mpr (by simp [voters])
      rw [empty] at present
      cases present

end JointConstruction

namespace Quorum
open JarlMembership

-- The callback is stateful: the old configuration receives the handle left by
-- the current pass, and overlapping identities are visited again.
theorem execution (entries : ArrayStore α) (callback : σ) :
    membership_Membership_quorum entries callback =
      countPredicates (membership_Membership_voters entries) callback 0 (fun count advanced =>
        if decide (count > (membership_Membership_voters entries).length / 2) then
          if membership_Membership_is_joint entries then
            countPredicates (membership_Membership_old_voters entries) advanced 0 (fun count advanced =>
              finishPredicate advanced (.value (decide (count > (membership_Membership_old_voters entries).length / 2))))
          else finishPredicate advanced (.value true)
        else finishPredicate advanced (.value false)) := rfl

theorem stable_execution (entries : ArrayStore α) (callback : σ)
    (stable : membership_Membership_is_joint entries = false) :
    membership_Membership_quorum entries callback =
      countPredicates (membership_Membership_voters entries) callback 0 (fun count advanced =>
        finishPredicate advanced (.value (decide (count > (membership_Membership_voters entries).length / 2)))) := by
  rw [execution]
  simp only [stable, Bool.false_eq_true, ↓reduceIte]
  congr 1
  funext count advanced
  cases decide (count > (membership_Membership_voters entries).length / 2) <;> rfl

theorem empty_current (entries : ArrayStore α) (callback : σ)
    (empty : membership_Membership_voters entries = []) :
    membership_Membership_quorum entries callback = finishPredicate callback (.value false) := by
  rw [execution, empty]
  rfl

-- The budget counts completed responses, not wall time or callback termination.
theorem response_budget (entries : ArrayStore α) (callback : σ) :
    predicateBudget ((membership_Membership_voters entries).length +
      (membership_Membership_old_voters entries).length + 2)
      (membership_Membership_quorum entries callback) :=
  predicate_fold_budget membership_Membership_quorum_ir entries callback

theorem observation_complete (entries : ArrayStore α) (callback : σ)
    (call : Cell α → σ → PredicateReply σ) (drop : σ → PredicateDropReply) :
    ∃ outcome, observePredicate ((membership_Membership_voters entries).length +
      (membership_Membership_old_voters entries).length + 2) call drop
      (membership_Membership_quorum entries callback) = some outcome :=
  predicate_observation_complete _ _ (response_budget entries callback) call drop

end Quorum

namespace QuorumIndex
open JarlMembership

-- The first rank must complete before the gate is queried. Both passes retain
-- callback state; even a zero first rank does not skip the old configuration.
theorem execution (entries : ArrayStore α) (callback : σ) (abortOnPanic : Bool) :
    membership_Membership_quorum_index entries callback abortOnPanic =
      collectCallbacks (membership_Membership_voters entries) callback (fun values advanced =>
        match numericRank values 2 with
        | none => finishNumericPanic advanced abortOnPanic
        | some first =>
          if membership_Membership_is_joint entries then
            collectCallbacks (membership_Membership_old_voters entries) advanced (fun values advanced =>
              match numericRank values 2 with
              | none => finishNumericPanic advanced abortOnPanic
              | some second => finishCallback advanced (.value (min first second)))
          else finishCallback advanced (.value first)) := runNumericFold_refines _ entries callback abortOnPanic

theorem stable_execution (entries : ArrayStore α) (callback : σ) (abortOnPanic : Bool)
    (stable : membership_Membership_is_joint entries = false) :
    membership_Membership_quorum_index entries callback abortOnPanic =
      collectCallbacks (membership_Membership_voters entries) callback (fun values advanced =>
        match numericRank values 2 with
        | none => finishNumericPanic advanced abortOnPanic
        | some first => finishCallback advanced (.value first)) := by
  rw [execution]
  simp only [stable, Bool.false_eq_true, ↓reduceIte]

theorem empty_current (entries : ArrayStore α) (callback : σ) (abortOnPanic : Bool)
    (empty : membership_Membership_voters entries = []) :
    membership_Membership_quorum_index entries callback abortOnPanic =
      finishNumericPanic callback abortOnPanic := by
  rw [execution, empty]
  rfl

theorem word_execution (entries : ArrayStore α) (callback : σ) (bits : Nat)
    (checked abortOnPanic : Bool) (width : Provium.validWidth bits = true)
    (capacity : entries.length < 2^bits) :
    runNumericWords membership_Membership_quorum_index_ir entries callback bits checked abortOnPanic =
      membership_Membership_quorum_index entries callback abortOnPanic := by
  have divisor_fits : 2 < 2^bits := by
    simp only [Provium.validWidth, Bool.or_eq_true, beq_iff_eq] at width
    rcases width with ((rfl | rfl) | rfl) | rfl <;> decide
  exact runNumericWords_refines _ entries callback bits checked abortOnPanic width capacity divisor_fits

theorem target_word_execution (entries : ArrayStore α) (callback : σ)
    (checked abortOnPanic : Bool) (capacity : entries.length < 2^target_usize_bits) :
    membership_Membership_quorum_index_target_words entries callback checked abortOnPanic =
      membership_Membership_quorum_index entries callback abortOnPanic := by
  exact membership_Membership_quorum_index_target_refinement entries callback checked abortOnPanic
    capacity (by decide)

theorem build_word_execution (entries : ArrayStore α) (callback : σ)
    (capacity : entries.length < 2^target_usize_bits) :
    membership_Membership_quorum_index_build_words entries callback =
      membership_Membership_quorum_index entries callback target_panic_abort := by
  exact membership_Membership_quorum_index_build_refinement entries callback capacity (by decide)

theorem build_empty_current (entries : ArrayStore α) (callback : σ)
    (capacity : entries.length < 2^target_usize_bits)
    (empty : membership_Membership_voters entries = []) :
    membership_Membership_quorum_index_build_words entries callback =
      membership_Membership_quorum_index entries callback target_panic_abort ∧
    membership_Membership_quorum_index_build_words entries callback =
      finishNumericPanic callback target_panic_abort := by
  refine ⟨build_word_execution entries callback capacity, ?_⟩
  rw [build_word_execution entries callback capacity]
  exact empty_current entries callback target_panic_abort empty

theorem response_budget (entries : ArrayStore α) (callback : σ) (abortOnPanic : Bool) :
    callbackBudget ((membership_Membership_voters entries).length + (membership_Membership_old_voters entries).length + 2)
      (membership_Membership_quorum_index entries callback abortOnPanic) :=
  numeric_fold_budget _ entries callback abortOnPanic

theorem observation_complete (entries : ArrayStore α) (callback : σ) (abortOnPanic : Bool)
    (call : Cell α → σ → CallbackReply UInt64 σ) (drop : σ → PredicateDropReply) :
    ∃ outcome, observeCallback
      ((membership_Membership_voters entries).length + (membership_Membership_old_voters entries).length + 2)
      call drop (membership_Membership_quorum_index entries callback abortOnPanic) = some outcome :=
  callback_observation_complete _ _ (response_budget entries callback abortOnPanic) call drop

end QuorumIndex
