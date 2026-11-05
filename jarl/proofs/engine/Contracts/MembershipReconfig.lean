import Contracts.MembershipBuild

/-!
# Membership contracts: `with_learners` and `joint`
-/

namespace Jarl.Contracts.Membership
open Jarl

variable {MAX : Nat}

/-! ## Learner replacement -/

namespace LearnerReplacement
open MembershipProjection SetInterpretation

theorem with_learners_ok (m : Jarl.Membership MAX) (learners : Array Id) (hMAX : MAX < 2 ^ 64)
    (hl : learners.size < 2 ^ 64) (r : Jarl.Membership MAX)
    (success : m.with_learners learners = pure (.Ok r)) :
    ∃ a, pass false (fun _ => false) 0 [] m.voters (empty MAX) = .ok a ∧
      pass true (fun x => m.is_voter x) 1 [] learners.toList a = .ok r := by
  rw [with_learners_eq m learners hMAX hl] at success
  have h := Rust.pure_inj success
  unfold withLearnersSpec at h
  split at h
  · cases h
  rename_i a h1
  split at h
  · cases h
  rename_i b h2
  cases h
  exact ⟨a, h1, h2⟩

theorem with_learners_err (m : Jarl.Membership MAX) (learners : Array Id) (hMAX : MAX < 2 ^ 64)
    (hl : learners.size < 2 ^ 64) :
    (∃ r, m.with_learners learners = pure (.Ok r)) ∨ m.with_learners learners = pure (.Err .Config) := by
  rw [with_learners_eq m learners hMAX hl]
  unfold withLearnersSpec
  split
  · exact Or.inr rfl
  · split
    · exact Or.inr rfl
    · exact Or.inl ⟨_, rfl⟩

theorem capacity_preserved (m : Jarl.Membership MAX) (learners : Array Id) (r : Jarl.Membership MAX)
    (_success : m.with_learners learners = pure (.Ok r)) : r.members.toList.length = MAX := by simp

theorem unique_identities (m : Jarl.Membership MAX) (learners : Array Id) (hMAX : MAX < 2 ^ 64)
    (hl : learners.size < 2 ^ 64) (r : Jarl.Membership MAX)
    (success : m.with_learners learners = pure (.Ok r)) : UniqueIdentities r := by
  obtain ⟨a, h1, h2⟩ := with_learners_ok m learners hMAX hl r success
  exact pass_unique _ _ _ _ _ _ _ h2 (pass_unique _ _ _ _ _ _ _ h1 empty_unique)

theorem flags (F : Flag) (m : Jarl.Membership MAX) (learners : Array Id) (hMAX : MAX < 2 ^ 64)
    (hl : learners.size < 2 ^ 64) (r : Jarl.Membership MAX)
    (success : m.with_learners learners = pure (.Ok r)) (q : Id) :
    FlagMember F r q ↔ (q ∈ m.voters ∧ F = .voter) ∨ (q ∈ learners.toList ∧ F = .learner) := by
  obtain ⟨a, h1, h2⟩ := with_learners_ok m learners hMAX hl r success
  rw [pass_flags F _ _ _ _ _ _ _ h2, pass_flags F _ _ _ _ _ _ _ h1, ofKind_zero, ofKind_one]
  have := empty_no_flag (MAX := MAX) F q
  constructor
  · rintro ((h | h) | h)
    · exact absurd h this
    · exact Or.inl h
    · exact Or.inr h
  · rintro (h | h)
    · exact Or.inl (Or.inr h)
    · exact Or.inr h

theorem voters_exact (m : Jarl.Membership MAX) (learners : Array Id) (hMAX : MAX < 2 ^ 64)
    (hl : learners.size < 2 ^ 64) (r : Jarl.Membership MAX)
    (success : m.with_learners learners = pure (.Ok r)) (q : Id) : q ∈ r.voters ↔ q ∈ m.voters := by
  rw [voters_flag, flags .voter m learners hMAX hl r success q]; simp

theorem learners_exact (m : Jarl.Membership MAX) (learners : Array Id) (hMAX : MAX < 2 ^ 64)
    (hl : learners.size < 2 ^ 64) (r : Jarl.Membership MAX)
    (success : m.with_learners learners = pure (.Ok r)) (q : Id) : q ∈ r.learners ↔ q ∈ learners.toList := by
  rw [learners_flag, flags .learner m learners hMAX hl r success q]; simp

theorem old_empty (m : Jarl.Membership MAX) (learners : Array Id) (hMAX : MAX < 2 ^ 64)
    (hl : learners.size < 2 ^ 64) (r : Jarl.Membership MAX)
    (success : m.with_learners learners = pure (.Ok r)) : r.old_voters = [] := by
  apply List.eq_nil_iff_forall_not_mem.mpr
  intro q hq
  have := (flags .old m learners hMAX hl r success q).mp ((old_voters_flag r q).mp hq)
  simp at this

theorem valid_inputs (m : Jarl.Membership MAX) (learners : Array Id) (hMAX : MAX < 2 ^ 64)
    (hl : learners.size < 2 ^ 64) (r : Jarl.Membership MAX)
    (success : m.with_learners learners = pure (.Ok r)) :
    learners.toList.Nodup ∧ ∀ key ∈ learners.toList, m.is_voter key = false := by
  obtain ⟨a, _, h2⟩ := with_learners_ok m learners hMAX hl r success
  have v := (valid_iff _ _ _ _).mp (pass_valid _ _ _ _ _ _ _ h2)
  exact ⟨(v.1 rfl).1, v.2⟩

theorem identities (m : Jarl.Membership MAX) (learners : Array Id) (hMAX : MAX < 2 ^ 64)
    (hl : learners.size < 2 ^ 64) (r : Jarl.Membership MAX)
    (success : m.with_learners learners = pure (.Ok r)) (q : Id) :
    HasIdentity r q ↔ q ∈ m.voters ∨ q ∈ learners.toList := by
  obtain ⟨a, h1, h2⟩ := with_learners_ok m learners hMAX hl r success
  rw [pass_identities _ _ _ _ _ _ _ h2, pass_identities _ _ _ _ _ _ _ h1]
  have := empty_no_identity (MAX := MAX) q
  constructor
  · rintro ((h | h) | h)
    · exact absurd h this
    · exact Or.inl h
    · exact Or.inr h
  · rintro (h | h)
    · exact Or.inl (Or.inr h)
    · exact Or.inr h

def ValidLearners (m : Jarl.Membership MAX) (learners : List Id) : Prop :=
  learners.Nodup ∧ ∀ key ∈ learners, m.is_voter key = false

theorem accepts (m : Jarl.Membership MAX) (learners : Array Id) (hMAX : MAX < 2 ^ 64)
    (hl : learners.size < 2 ^ 64) (valid : ValidLearners m learners.toList)
    (fits : Fits MAX (m.voters ++ learners.toList)) :
    ∃ r, m.with_learners learners = pure (.Ok r) := by
  obtain ⟨D, bound, covers⟩ := fits
  rw [with_learners_eq m learners hMAX hl]
  unfold withLearnersSpec
  obtain ⟨a, h1⟩ := pass_accepts (MAX := MAX) false (fun _ => false) 0 D bound [] m.voters
    ((valid_iff _ _ _ _).mpr ⟨by simp, by simp⟩)
    (fun x hx => covers x (by simp [hx])) (empty MAX) empty_unique (fun q hq => absurd hq (empty_no_identity q))
  have ua := pass_unique _ _ _ _ _ _ _ h1 empty_unique
  have ca : ∀ q, HasIdentity a q → q ∈ D := by
    intro q hq
    rcases (pass_identities _ _ _ _ _ _ _ h1 q).mp hq with h | h
    · exact absurd h (empty_no_identity q)
    · exact covers q (by simp [h])
  obtain ⟨b, h2⟩ := pass_accepts true (fun x => m.is_voter x) 1 D bound [] learners.toList
    ((valid_iff _ _ _ _).mpr ⟨fun _ => ⟨valid.1, by simp⟩, valid.2⟩)
    (fun x hx => covers x (by simp [hx])) a ua ca
  exact ⟨b, by simp only [h1, h2]⟩

theorem accepts_iff (m : Jarl.Membership MAX) (learners : Array Id) (hMAX : MAX < 2 ^ 64)
    (hl : learners.size < 2 ^ 64) :
    (∃ r, m.with_learners learners = pure (.Ok r)) ↔
      ValidLearners m learners.toList ∧ Fits MAX (m.voters ++ learners.toList) := by
  constructor
  · rintro ⟨r, success⟩
    refine ⟨valid_inputs m learners hMAX hl r success, keys_fit r _ ?_⟩
    intro q hq
    exact (identities m learners hMAX hl r success q).mpr (by simpa using hq)
  · rintro ⟨valid, fits⟩
    exact accepts m learners hMAX hl valid fits

theorem accepts_by_count (m : Jarl.Membership MAX) (learners : Array Id) (hMAX : MAX < 2 ^ 64)
    (hl : learners.size < 2 ^ 64) :
    (∃ r, m.with_learners learners = pure (.Ok r)) ↔
      ValidLearners m learners.toList ∧ (uniqueKeys (m.voters ++ learners.toList)).length ≤ MAX := by
  rw [accepts_iff m learners hMAX hl, fits_iff_count]

theorem error_code (m : Jarl.Membership MAX) (learners : Array Id) (hMAX : MAX < 2 ^ 64)
    (hl : learners.size < 2 ^ 64) (e : Error) (failure : m.with_learners learners = pure (.Err e)) :
    e = .Config := by
  rcases with_learners_err m learners hMAX hl with ⟨r, h⟩ | h
  · rw [h] at failure; have := Rust.pure_inj failure; cases this
  · rw [h] at failure; have := Rust.pure_inj failure; cases this; rfl

theorem rejects_iff (m : Jarl.Membership MAX) (learners : Array Id) (hMAX : MAX < 2 ^ 64)
    (hl : learners.size < 2 ^ 64) :
    m.with_learners learners = pure (.Err .Config) ↔
      ¬(ValidLearners m learners.toList ∧ (uniqueKeys (m.voters ++ learners.toList)).length ≤ MAX) := by
  rw [← accepts_by_count m learners hMAX hl]
  constructor
  · rintro failure ⟨r, success⟩
    rw [failure] at success; have := Rust.pure_inj success; cases this
  · intro rejected
    rcases with_learners_err m learners hMAX hl with h | h
    · exact absurd h rejected
    · exact h

theorem not_joint (m : Jarl.Membership MAX) (learners : Array Id) (hMAX : MAX < 2 ^ 64)
    (hl : learners.size < 2 ^ 64) (r : Jarl.Membership MAX)
    (success : m.with_learners learners = pure (.Ok r)) : r.is_joint = false := by
  cases h : r.is_joint with
  | false => rfl
  | true => exact absurd (old_empty m learners hMAX hl r success) ((joint_iff_old_nonempty r).mp h)

end LearnerReplacement

/-! ## Joint construction -/

namespace JointConstruction
open MembershipProjection SetInterpretation

theorem success_shape (source target r : Jarl.Membership MAX) (hMAX : MAX < 2 ^ 64) :
    source.joint target = pure (.Ok r) ↔
      source.is_joint = false ∧ target.is_joint = false ∧
        pass false (fun _ => false) 2 [] source.voters target = .ok r := by
  rw [joint_eq source target hMAX]
  unfold jointSpec
  constructor
  · intro h
    have h := Rust.pure_inj h
    split at h
    · cases h
    rename_i g
    simp only [Bool.or_eq_true, not_or, Bool.not_eq_true] at g
    split at h
    · cases h
    rename_i c hc
    cases h
    exact ⟨g.1, g.2, hc⟩
  · rintro ⟨hs, ht, hp⟩
    simp [hs, ht, hp]

theorem capacity_preserved (source target r : Jarl.Membership MAX)
    (_success : source.joint target = pure (.Ok r)) : r.members.toList.length = target.members.toList.length := by
  simp

theorem unique_identities (source target r : Jarl.Membership MAX) (hMAX : MAX < 2 ^ 64)
    (unique : UniqueIdentities target) (success : source.joint target = pure (.Ok r)) : UniqueIdentities r :=
  pass_unique _ _ _ _ _ _ _ ((success_shape source target r hMAX).mp success).2.2 unique

theorem flags (F : Flag) (source target r : Jarl.Membership MAX) (hMAX : MAX < 2 ^ 64)
    (success : source.joint target = pure (.Ok r)) (q : Id) :
    FlagMember F r q ↔ FlagMember F target q ∨ (q ∈ source.voters ∧ F = .old) := by
  rw [pass_flags F _ _ _ _ _ _ _ ((success_shape source target r hMAX).mp success).2.2, ofKind_two]

theorem voters_exact (source target r : Jarl.Membership MAX) (hMAX : MAX < 2 ^ 64)
    (success : source.joint target = pure (.Ok r)) (q : Id) : q ∈ r.voters ↔ q ∈ target.voters := by
  rw [voters_flag, voters_flag, flags .voter source target r hMAX success q]; simp

theorem learners_exact (source target r : Jarl.Membership MAX) (hMAX : MAX < 2 ^ 64)
    (success : source.joint target = pure (.Ok r)) (q : Id) : q ∈ r.learners ↔ q ∈ target.learners := by
  rw [learners_flag, learners_flag, flags .learner source target r hMAX success q]; simp

theorem old_voters_exact (source target r : Jarl.Membership MAX) (hMAX : MAX < 2 ^ 64)
    (success : source.joint target = pure (.Ok r)) (q : Id) : q ∈ r.old_voters ↔ q ∈ source.voters := by
  have stable := ((success_shape source target r hMAX).mp success).2.1
  have absent : ¬FlagMember .old target q := by
    intro marked
    have present := (old_voters_flag target q).mpr marked
    have := (joint_iff_old_nonempty target).mpr (List.ne_nil_of_mem present)
    rw [stable] at this; cases this
  rw [old_voters_flag, flags .old source target r hMAX success q]
  simp [absent]

theorem identities (source target r : Jarl.Membership MAX) (hMAX : MAX < 2 ^ 64)
    (success : source.joint target = pure (.Ok r)) (q : Id) :
    HasIdentity r q ↔ HasIdentity target q ∨ q ∈ source.voters :=
  pass_identities _ _ _ _ _ _ _ ((success_shape source target r hMAX).mp success).2.2 q

/-- The union of the target's identities and the source voters fits in `MAX` slots. -/
def FitsMerge (source target : Jarl.Membership MAX) : Prop :=
  ∃ D : List Id, D.length ≤ MAX ∧ ∀ key, HasIdentity target key ∨ key ∈ source.voters → key ∈ D

theorem accepts (source target : Jarl.Membership MAX) (hMAX : MAX < 2 ^ 64) (unique : UniqueIdentities target)
    (source_stable : source.is_joint = false) (target_stable : target.is_joint = false)
    (fits : FitsMerge source target) : ∃ r, source.joint target = pure (.Ok r) := by
  obtain ⟨D, bound, covers⟩ := fits
  obtain ⟨r, h⟩ := pass_accepts false (fun _ => false) 2 D bound [] source.voters
    ((valid_iff _ _ _ _).mpr ⟨by simp, by simp⟩) (fun x hx => covers x (Or.inr hx)) target unique
    (fun q hq => covers q (Or.inl hq))
  exact ⟨r, (success_shape source target r hMAX).mpr ⟨source_stable, target_stable, h⟩⟩

theorem accepts_iff (source target : Jarl.Membership MAX) (hMAX : MAX < 2 ^ 64) (unique : UniqueIdentities target) :
    (∃ r, source.joint target = pure (.Ok r)) ↔
      source.is_joint = false ∧ target.is_joint = false ∧ FitsMerge source target := by
  constructor
  · rintro ⟨r, success⟩
    have shape := (success_shape source target r hMAX).mp success
    refine ⟨shape.1, shape.2.1, Keys r, keys_length r, fun key hk => ?_⟩
    exact (keys_member r key).mpr ((identities source target r hMAX success key).mpr hk)
  · rintro ⟨hs, ht, fits⟩
    exact accepts source target hMAX unique hs ht fits

theorem fits_by_count (source target : Jarl.Membership MAX) :
    FitsMerge source target ↔ (uniqueKeys (Keys target ++ source.voters)).length ≤ MAX := by
  rw [← fits_iff_count]
  unfold FitsMerge Fits
  simp only [List.mem_append, keys_member]

theorem accepts_by_count (source target : Jarl.Membership MAX) (hMAX : MAX < 2 ^ 64)
    (unique : UniqueIdentities target) :
    (∃ r, source.joint target = pure (.Ok r)) ↔
      source.is_joint = false ∧ target.is_joint = false ∧
        (uniqueKeys (Keys target ++ source.voters)).length ≤ MAX := by
  rw [accepts_iff source target hMAX unique, fits_by_count]

theorem guard_error_iff (source target : Jarl.Membership MAX) (hMAX : MAX < 2 ^ 64) :
    source.joint target = pure (.Err .Reconfiguring) ↔ source.is_joint = true ∨ target.is_joint = true := by
  rw [joint_eq source target hMAX]
  unfold jointSpec
  by_cases g : (source.is_joint || target.is_joint) = true
  · have g' : source.is_joint = true ∨ target.is_joint = true := by simpa using g
    simp only [g, if_true]
    exact ⟨fun _ => g', fun _ => trivial⟩
  · simp only [g, Bool.false_eq_true, if_false]
    simp only [Bool.or_eq_true] at g
    refine ⟨fun h => ?_, fun h => absurd h g⟩
    have h := Rust.pure_inj h
    split at h <;> cases h

theorem error_codes (source target : Jarl.Membership MAX) (hMAX : MAX < 2 ^ 64) (e : Error)
    (failure : source.joint target = pure (.Err e)) : e = .Reconfiguring ∨ e = .Full := by
  rw [joint_eq source target hMAX] at failure
  have h := Rust.pure_inj failure
  unfold jointSpec at h
  split at h
  · cases h; exact Or.inl rfl
  · split at h
    · cases h; exact Or.inr rfl
    · cases h

theorem full_iff (source target : Jarl.Membership MAX) (hMAX : MAX < 2 ^ 64) (unique : UniqueIdentities target) :
    source.joint target = pure (.Err .Full) ↔
      source.is_joint = false ∧ target.is_joint = false ∧ ¬FitsMerge source target := by
  constructor
  · intro failure
    have inactive : ¬(source.is_joint = true ∨ target.is_joint = true) := by
      intro active
      have := (guard_error_iff source target hMAX).mpr active
      rw [failure] at this; have := Rust.pure_inj this; cases this
    simp only [not_or, Bool.not_eq_true] at inactive
    refine ⟨inactive.1, inactive.2, fun fits => ?_⟩
    obtain ⟨r, success⟩ := accepts source target hMAX unique inactive.1 inactive.2 fits
    rw [failure] at success; have := Rust.pure_inj success; cases this
  · rintro ⟨hs, ht, notFits⟩
    rw [joint_eq source target hMAX]
    unfold jointSpec
    simp only [hs, ht, Bool.or_self, Bool.false_eq_true, if_false]
    split
    · rfl
    · rename_i r hr
      exact absurd ((accepts_iff source target hMAX unique).mp
        ⟨r, (success_shape source target r hMAX).mpr ⟨hs, ht, hr⟩⟩).2.2 notFits

theorem full_by_count (source target : Jarl.Membership MAX) (hMAX : MAX < 2 ^ 64) (unique : UniqueIdentities target) :
    source.joint target = pure (.Err .Full) ↔
      source.is_joint = false ∧ target.is_joint = false ∧ MAX < (uniqueKeys (Keys target ++ source.voters)).length := by
  rw [full_iff source target hMAX unique, fits_by_count, Nat.not_le]

theorem joint_iff_source_voters (source target r : Jarl.Membership MAX) (hMAX : MAX < 2 ^ 64)
    (success : source.joint target = pure (.Ok r)) : r.is_joint = true ↔ source.voters ≠ [] := by
  rw [joint_iff_old_nonempty]
  constructor
  · intro ne empty
    obtain ⟨key, hk⟩ := List.exists_mem_of_ne_nil _ ne
    have := (old_voters_exact source target r hMAX success key).mp hk
    rw [empty] at this; cases this
  · intro ne empty
    obtain ⟨key, hk⟩ := List.exists_mem_of_ne_nil _ ne
    have := (old_voters_exact source target r hMAX success key).mpr hk
    rw [empty] at this; cases this

end JointConstruction

end Jarl.Contracts.Membership
