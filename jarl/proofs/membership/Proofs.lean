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
