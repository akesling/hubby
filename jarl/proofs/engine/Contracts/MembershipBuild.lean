import Contracts.MembershipSpec

/-!
# Membership contracts: `restore`, `new`, `with_learners`, `joint`, `peers`

All statements are about the translated functions. Inputs are Rust slices, so
their lengths and `MAX` are below `2^64` (`usize`); those bounds appear as
explicit hypotheses because Lean arrays are unbounded.
-/

namespace Jarl.Contracts.Membership
open Jarl

variable {MAX : Nat}

theorem ofKind_zero : Flag.ofKind 0 = .voter := rfl
theorem ofKind_one : Flag.ofKind 1 = .learner := rfl
theorem ofKind_two : Flag.ofKind 2 = .old := rfl

theorem include_ok_spec (m m' : Jarl.Membership MAX) (id : Id) (k : Rust.u8) (hMAX : MAX < 2 ^ 64)
    (h : m.include id k = pure (.Ok (), m')) : incSpec m id k = some m' := by
  rw [include_eq m id k hMAX] at h
  cases hs : incSpec m id k with
  | none => simp only [hs] at h; have := Rust.pure_inj h; simp at this
  | some m'' => simp only [hs] at h; have := Rust.pure_inj h; simp at this; rw [this]

/-! ## Restoration -/

/-- The checks `restore` performs on its inputs. -/
def ValidInputs (voters old learners : List Id) : Prop :=
  voters ≠ [] ∧ voters.Nodup ∧ old.Nodup ∧ learners.Nodup ∧ ∀ key ∈ learners, key ∉ voters

theorem restore_ok (voters old learners : Array Id) (hMAX : MAX < 2 ^ 64) (hv : voters.size < 2 ^ 64)
    (ho : old.size < 2 ^ 64) (hl : learners.size < 2 ^ 64) (r : Jarl.Membership MAX)
    (success : Jarl.Membership.restore voters old learners = pure (.Ok r)) :
    voters.toList ≠ [] ∧ ∃ a b,
      pass true (fun _ => false) 0 [] voters.toList (empty MAX) = .ok a ∧
      pass true (fun x => voters.toList.contains x) 1 [] learners.toList a = .ok b ∧
      pass true (fun _ => false) 2 [] old.toList b = .ok r := by
  rw [restore_eq voters old learners hMAX hv ho hl] at success
  have h := Rust.pure_inj success
  unfold restoreSpec at h
  split at h
  · cases h
  rename_i he
  refine ⟨by simpa using he, ?_⟩
  split at h
  · cases h
  rename_i a h1
  split at h
  · cases h
  rename_i b h2
  split at h
  · cases h
  rename_i c h3
  cases h
  exact ⟨a, b, h1, h2, h3⟩

theorem restore_err (voters old learners : Array Id) (hMAX : MAX < 2 ^ 64) (hv : voters.size < 2 ^ 64)
    (ho : old.size < 2 ^ 64) (hl : learners.size < 2 ^ 64) :
    (∃ r, Jarl.Membership.restore (MAX := MAX) voters old learners = pure (.Ok r)) ∨
      Jarl.Membership.restore (MAX := MAX) voters old learners = pure (.Err .Config) := by
  rw [restore_eq voters old learners hMAX hv ho hl]
  unfold restoreSpec
  split
  · exact Or.inr rfl
  · split
    · exact Or.inr rfl
    · split
      · exact Or.inr rfl
      · split
        · exact Or.inr rfl
        · exact Or.inl ⟨_, rfl⟩

namespace Restoration

theorem capacity_preserved (voters old learners : Array Id) (r : Jarl.Membership MAX)
    (_success : Jarl.Membership.restore voters old learners = pure (.Ok r)) :
    r.members.toList.length = MAX := by simp

theorem unique_identities (voters old learners : Array Id) (hMAX : MAX < 2 ^ 64) (hv : voters.size < 2 ^ 64)
    (ho : old.size < 2 ^ 64) (hl : learners.size < 2 ^ 64) (r : Jarl.Membership MAX)
    (success : Jarl.Membership.restore voters old learners = pure (.Ok r)) : UniqueIdentities r := by
  obtain ⟨_, a, b, h1, h2, h3⟩ := restore_ok voters old learners hMAX hv ho hl r success
  exact pass_unique _ _ _ _ _ _ _ h3 (pass_unique _ _ _ _ _ _ _ h2 (pass_unique _ _ _ _ _ _ _ h1 empty_unique))

theorem empty_voters (old learners : Array Id) :
    Jarl.Membership.restore (MAX := MAX) #[] old learners = pure (.Err .Config) := by
  unfold Jarl.Membership.restore; simp

theorem single_voter (key : Id) :
    Jarl.Membership.restore (MAX := 1) #[key] #[] #[] =
      pure (.Ok ⟨#v[some { id := key, voter := true, old := false, learner := false }]⟩) := by
  rw [restore_eq _ _ _ (by decide) (by simp) (by simp) (by simp)]
  simp [restoreSpec, pass, stepOk, incSpec, findSlot, empty, setFlag, blank, List.findIdx?_cons]

theorem duplicate_voter (key : Id) :
    Jarl.Membership.restore (MAX := 2) #[key, key] #[] #[] = pure (.Err .Config) := by
  rw [restore_eq _ _ _ (by decide) (by simp) (by simp) (by simp)]
  simp [restoreSpec, pass, stepOk, incSpec, findSlot, empty, setFlag, blank, List.findIdx?_cons]

theorem learner_overlap (key : Id) :
    Jarl.Membership.restore (MAX := 2) #[key] #[] #[key] = pure (.Err .Config) := by
  rw [restore_eq _ _ _ (by decide) (by simp) (by simp) (by simp)]
  simp [restoreSpec, pass, stepOk, incSpec, findSlot, empty, setFlag, blank, List.findIdx?_cons]

theorem nonempty_voters (voters old learners : Array Id) (hMAX : MAX < 2 ^ 64) (hv : voters.size < 2 ^ 64)
    (ho : old.size < 2 ^ 64) (hl : learners.size < 2 ^ 64) (r : Jarl.Membership MAX)
    (success : Jarl.Membership.restore voters old learners = pure (.Ok r)) : voters.toList ≠ [] :=
  (restore_ok voters old learners hMAX hv ho hl r success).1

theorem distinct_inputs (voters old learners : Array Id) (hMAX : MAX < 2 ^ 64) (hv : voters.size < 2 ^ 64)
    (ho : old.size < 2 ^ 64) (hl : learners.size < 2 ^ 64) (r : Jarl.Membership MAX)
    (success : Jarl.Membership.restore voters old learners = pure (.Ok r)) :
    voters.toList.Nodup ∧ old.toList.Nodup ∧ learners.toList.Nodup := by
  obtain ⟨_, a, b, h1, h2, h3⟩ := restore_ok voters old learners hMAX hv ho hl r success
  have v1 := (valid_iff _ _ _ _).mp (pass_valid _ _ _ _ _ _ _ h1)
  have v2 := (valid_iff _ _ _ _).mp (pass_valid _ _ _ _ _ _ _ h2)
  have v3 := (valid_iff _ _ _ _).mp (pass_valid _ _ _ _ _ _ _ h3)
  exact ⟨(v1.1 rfl).1, (v3.1 rfl).1, (v2.1 rfl).1⟩

theorem learners_disjoint (voters old learners : Array Id) (hMAX : MAX < 2 ^ 64) (hv : voters.size < 2 ^ 64)
    (ho : old.size < 2 ^ 64) (hl : learners.size < 2 ^ 64) (r : Jarl.Membership MAX)
    (success : Jarl.Membership.restore voters old learners = pure (.Ok r)) :
    ∀ key ∈ learners.toList, key ∉ voters.toList := by
  obtain ⟨_, a, b, _, h2, _⟩ := restore_ok voters old learners hMAX hv ho hl r success
  have v2 := (valid_iff _ _ _ _).mp (pass_valid _ _ _ _ _ _ _ h2)
  intro key hk hkv
  have := v2.2 key hk
  simp [hkv] at this

theorem valid (voters old learners : Array Id) (hMAX : MAX < 2 ^ 64) (hv : voters.size < 2 ^ 64)
    (ho : old.size < 2 ^ 64) (hl : learners.size < 2 ^ 64) (r : Jarl.Membership MAX)
    (success : Jarl.Membership.restore voters old learners = pure (.Ok r)) :
    ValidInputs voters.toList old.toList learners.toList := by
  have d := distinct_inputs voters old learners hMAX hv ho hl r success
  exact ⟨nonempty_voters voters old learners hMAX hv ho hl r success, d.1, d.2.1, d.2.2,
    learners_disjoint voters old learners hMAX hv ho hl r success⟩

end Restoration

namespace StableConstruction

theorem delegates_to_restore (voters learners : Array Id) :
    Jarl.Membership.new (MAX := MAX) voters learners = Jarl.Membership.restore voters #[] learners :=
  new_eq voters learners

theorem capacity_preserved (voters learners : Array Id) (r : Jarl.Membership MAX)
    (_success : Jarl.Membership.new voters learners = pure (.Ok r)) : r.members.toList.length = MAX := by simp

theorem unique_identities (voters learners : Array Id) (hMAX : MAX < 2 ^ 64) (hv : voters.size < 2 ^ 64)
    (hl : learners.size < 2 ^ 64) (r : Jarl.Membership MAX)
    (success : Jarl.Membership.new voters learners = pure (.Ok r)) : UniqueIdentities r := by
  rw [new_eq] at success
  exact Restoration.unique_identities voters #[] learners hMAX hv (by simp) hl r success

theorem valid_inputs (voters learners : Array Id) (hMAX : MAX < 2 ^ 64) (hv : voters.size < 2 ^ 64)
    (hl : learners.size < 2 ^ 64) (r : Jarl.Membership MAX)
    (success : Jarl.Membership.new voters learners = pure (.Ok r)) :
    voters.toList ≠ [] ∧ voters.toList.Nodup ∧ learners.toList.Nodup ∧ ∀ key ∈ learners.toList, key ∉ voters.toList := by
  rw [new_eq] at success
  have v := Restoration.valid voters #[] learners hMAX hv (by simp) hl r success
  exact ⟨v.1, v.2.1, v.2.2.2.1, v.2.2.2.2⟩

end StableConstruction

/-! ## Set interpretation -/

namespace SetInterpretation
open MembershipProjection

theorem include_flag (F : Flag) (m m' : Jarl.Membership MAX) (q id : Id) (k : Rust.u8) (hMAX : MAX < 2 ^ 64)
    (success : m.include id k = pure (.Ok (), m')) :
    FlagMember F m' q ↔ FlagMember F m q ∨ (id = q ∧ F = Flag.ofKind k) :=
  Membership.include_flag F m m' q id k (include_ok_spec m m' id k hMAX success)

theorem restore_flags (F : Flag) (voters old learners : Array Id) (hMAX : MAX < 2 ^ 64)
    (hv : voters.size < 2 ^ 64) (ho : old.size < 2 ^ 64) (hl : learners.size < 2 ^ 64) (r : Jarl.Membership MAX)
    (success : Jarl.Membership.restore voters old learners = pure (.Ok r)) (q : Id) :
    FlagMember F r q ↔ (q ∈ voters.toList ∧ F = .voter) ∨ (q ∈ learners.toList ∧ F = .learner) ∨
      (q ∈ old.toList ∧ F = .old) := by
  obtain ⟨_, a, b, h1, h2, h3⟩ := restore_ok voters old learners hMAX hv ho hl r success
  rw [pass_flags F _ _ _ _ _ _ _ h3, pass_flags F _ _ _ _ _ _ _ h2, pass_flags F _ _ _ _ _ _ _ h1,
    ofKind_zero, ofKind_one, ofKind_two]
  have := empty_no_flag (MAX := MAX) F q
  constructor
  · rintro (((h | h) | h) | h)
    · exact absurd h this
    · exact Or.inl h
    · exact Or.inr (Or.inl h)
    · exact Or.inr (Or.inr h)
  · rintro (h | h | h)
    · exact Or.inl (Or.inl (Or.inr h))
    · exact Or.inl (Or.inr h)
    · exact Or.inr h

theorem voters_exact (voters old learners : Array Id) (hMAX : MAX < 2 ^ 64)
    (hv : voters.size < 2 ^ 64) (ho : old.size < 2 ^ 64) (hl : learners.size < 2 ^ 64) (r : Jarl.Membership MAX)
    (success : Jarl.Membership.restore voters old learners = pure (.Ok r)) (q : Id) :
    q ∈ r.voters ↔ q ∈ voters.toList := by
  rw [voters_flag, restore_flags .voter voters old learners hMAX hv ho hl r success q]; simp

theorem old_voters_exact (voters old learners : Array Id) (hMAX : MAX < 2 ^ 64)
    (hv : voters.size < 2 ^ 64) (ho : old.size < 2 ^ 64) (hl : learners.size < 2 ^ 64) (r : Jarl.Membership MAX)
    (success : Jarl.Membership.restore voters old learners = pure (.Ok r)) (q : Id) :
    q ∈ r.old_voters ↔ q ∈ old.toList := by
  rw [old_voters_flag, restore_flags .old voters old learners hMAX hv ho hl r success q]; simp

theorem learners_exact (voters old learners : Array Id) (hMAX : MAX < 2 ^ 64)
    (hv : voters.size < 2 ^ 64) (ho : old.size < 2 ^ 64) (hl : learners.size < 2 ^ 64) (r : Jarl.Membership MAX)
    (success : Jarl.Membership.restore voters old learners = pure (.Ok r)) (q : Id) :
    q ∈ r.learners ↔ q ∈ learners.toList := by
  rw [learners_flag, restore_flags .learner voters old learners hMAX hv ho hl r success q]; simp

theorem stable_voters_exact (voters learners : Array Id) (hMAX : MAX < 2 ^ 64)
    (hv : voters.size < 2 ^ 64) (hl : learners.size < 2 ^ 64) (r : Jarl.Membership MAX)
    (success : Jarl.Membership.new voters learners = pure (.Ok r)) (q : Id) :
    q ∈ r.voters ↔ q ∈ voters.toList := by
  rw [new_eq] at success
  exact voters_exact voters #[] learners hMAX hv (by simp) hl r success q

theorem stable_learners_exact (voters learners : Array Id) (hMAX : MAX < 2 ^ 64)
    (hv : voters.size < 2 ^ 64) (hl : learners.size < 2 ^ 64) (r : Jarl.Membership MAX)
    (success : Jarl.Membership.new voters learners = pure (.Ok r)) (q : Id) :
    q ∈ r.learners ↔ q ∈ learners.toList := by
  rw [new_eq] at success
  exact learners_exact voters #[] learners hMAX hv (by simp) hl r success q

theorem stable_old_empty (voters learners : Array Id) (hMAX : MAX < 2 ^ 64)
    (hv : voters.size < 2 ^ 64) (hl : learners.size < 2 ^ 64) (r : Jarl.Membership MAX)
    (success : Jarl.Membership.new voters learners = pure (.Ok r)) : r.old_voters = [] := by
  rw [new_eq] at success
  apply List.eq_nil_iff_forall_not_mem.mpr
  intro q hq
  have := (old_voters_exact voters #[] learners hMAX hv (by simp) hl r success q).mp hq
  simp at this

theorem include_identity (m m' : Jarl.Membership MAX) (q id : Id) (k : Rust.u8) (hMAX : MAX < 2 ^ 64)
    (success : m.include id k = pure (.Ok (), m')) :
    HasIdentity m' q ↔ HasIdentity m q ∨ id = q :=
  Membership.include_identity m m' q id k (include_ok_spec m m' id k hMAX success)

theorem restore_identities (voters old learners : Array Id) (hMAX : MAX < 2 ^ 64)
    (hv : voters.size < 2 ^ 64) (ho : old.size < 2 ^ 64) (hl : learners.size < 2 ^ 64) (r : Jarl.Membership MAX)
    (success : Jarl.Membership.restore voters old learners = pure (.Ok r)) (q : Id) :
    HasIdentity r q ↔ q ∈ voters.toList ∨ q ∈ learners.toList ∨ q ∈ old.toList := by
  obtain ⟨_, a, b, h1, h2, h3⟩ := restore_ok voters old learners hMAX hv ho hl r success
  rw [pass_identities _ _ _ _ _ _ _ h3, pass_identities _ _ _ _ _ _ _ h2, pass_identities _ _ _ _ _ _ _ h1]
  have := empty_no_identity (MAX := MAX) q
  constructor
  · rintro (((h | h) | h) | h)
    · exact absurd h this
    · exact Or.inl h
    · exact Or.inr (Or.inl h)
    · exact Or.inr (Or.inr h)
  · rintro (h | h | h)
    · exact Or.inl (Or.inl (Or.inr h))
    · exact Or.inl (Or.inr h)
    · exact Or.inr h

theorem restored_contains_exact (voters old learners : Array Id) (hMAX : MAX < 2 ^ 64)
    (hv : voters.size < 2 ^ 64) (ho : old.size < 2 ^ 64) (hl : learners.size < 2 ^ 64) (r : Jarl.Membership MAX)
    (success : Jarl.Membership.restore voters old learners = pure (.Ok r)) (q : Id) :
    r.contains q = true ↔ q ∈ voters.toList ∨ q ∈ learners.toList ∨ q ∈ old.toList := by
  rw [IdentityQuery.contains_iff_has]
  exact restore_identities voters old learners hMAX hv ho hl r success q

theorem joint_iff_old_nonempty (m : Jarl.Membership MAX) : m.is_joint = true ↔ m.old_voters ≠ [] := by
  simp [Jarl.Membership.is_joint, Jarl.Membership.old_voters, List.filter_eq_nil_iff]

theorem stable_not_joint (voters learners : Array Id) (hMAX : MAX < 2 ^ 64)
    (hv : voters.size < 2 ^ 64) (hl : learners.size < 2 ^ 64) (r : Jarl.Membership MAX)
    (success : Jarl.Membership.new voters learners = pure (.Ok r)) : r.is_joint = false := by
  cases h : r.is_joint with
  | false => rfl
  | true => exact absurd (stable_old_empty voters learners hMAX hv hl r success) ((joint_iff_old_nonempty r).mp h)

theorem voters_length_le (m : Jarl.Membership MAX) : m.voters.length ≤ MAX := by
  have h1 : m.voters.length ≤ (occ m).length := by
    simp only [Jarl.Membership.voters, List.length_map]; exact List.length_filter_le _ _
  have h2 := keys_length m
  simp only [Keys, List.length_map] at h2
  exact Nat.le_trans h1 (by simpa [occ] using h2)

theorem voter_count_bounds (voters old learners : Array Id) (hMAX : MAX < 2 ^ 64)
    (hv : voters.size < 2 ^ 64) (ho : old.size < 2 ^ 64) (hl : learners.size < 2 ^ 64) (r : Jarl.Membership MAX)
    (success : Jarl.Membership.restore voters old learners = pure (.Ok r)) :
    0 < r.voters.length ∧ r.voters.length ≤ MAX := by
  refine ⟨?_, voters_length_le r⟩
  have ne := Restoration.nonempty_voters voters old learners hMAX hv ho hl r success
  obtain ⟨key, hk⟩ := List.exists_mem_of_ne_nil _ ne
  exact List.length_pos_of_mem ((voters_exact voters old learners hMAX hv ho hl r success key).mpr hk)

end SetInterpretation

/-! ## Capacity acceptance -/

namespace CapacityAcceptance
open SetInterpretation

/-- A cover of size `capacity` for every stored identity. -/
def Covered (capacity : Nat) (D : List Id) (m : Jarl.Membership MAX) : Prop :=
  UniqueIdentities m ∧ MAX = capacity ∧ ∀ key, HasIdentity m key → key ∈ D

theorem include_available (m : Jarl.Membership MAX) (D : List Id) (hMAX : MAX < 2 ^ 64) (fits : D.length ≤ MAX)
    (covered : Covered MAX D m) (key : Id) (admitted : key ∈ D) (k : Rust.u8) :
    ∃ m', m.include key k = pure (.Ok (), m') := by
  obtain ⟨m', h⟩ := Membership.include_available m D fits covered.1 covered.2.2 key admitted k
  exact ⟨m', by rw [include_eq m key k hMAX, h]⟩

theorem include_covered (m m' : Jarl.Membership MAX) (D : List Id) (hMAX : MAX < 2 ^ 64)
    (covered : Covered MAX D m) (key : Id) (admitted : key ∈ D) (k : Rust.u8)
    (success : m.include key k = pure (.Ok (), m')) : Covered MAX D m' := by
  have hs := include_ok_spec m m' key k hMAX success
  refine ⟨include_unique m m' key k hs covered.1, rfl, fun q hq => ?_⟩
  rcases (Membership.include_identity m m' q key k hs).mp hq with h | rfl
  · exact covered.2.2 q h
  · exact admitted

theorem restore_accepts (voters old learners : Array Id) (hMAX : MAX < 2 ^ 64)
    (hv : voters.size < 2 ^ 64) (ho : old.size < 2 ^ 64) (hl : learners.size < 2 ^ 64)
    (valid : ValidInputs voters.toList old.toList learners.toList)
    (fits : Fits MAX (voters.toList ++ learners.toList ++ old.toList)) :
    ∃ r, Jarl.Membership.restore (MAX := MAX) voters old learners = pure (.Ok r) := by
  obtain ⟨ne, nv, no, nl, disj⟩ := valid
  obtain ⟨D, bound, covers⟩ := fits
  rw [restore_eq voters old learners hMAX hv ho hl]
  unfold restoreSpec
  have he : voters.isEmpty = false := by simpa using ne
  simp only [he, Bool.false_eq_true, if_false]
  obtain ⟨a, h1⟩ := pass_accepts (MAX := MAX) true (fun _ => false) 0 D bound [] voters.toList
    ((valid_iff _ _ _ _).mpr ⟨fun _ => ⟨nv, by simp⟩, by simp⟩)
    (fun x hx => covers x (by simp [hx])) (empty MAX) empty_unique (fun q hq => absurd hq (empty_no_identity q))
  have ua := pass_unique _ _ _ _ _ _ _ h1 empty_unique
  have ca : ∀ q, HasIdentity a q → q ∈ D := by
    intro q hq
    rcases (pass_identities _ _ _ _ _ _ _ h1 q).mp hq with h | h
    · exact absurd h (empty_no_identity q)
    · exact covers q (by simp [h])
  obtain ⟨b, h2⟩ := pass_accepts true (fun x => voters.toList.contains x) 1 D bound [] learners.toList
    ((valid_iff _ _ _ _).mpr ⟨fun _ => ⟨nl, by simp⟩, fun x hx => by simpa using disj x hx⟩)
    (fun x hx => covers x (by simp [hx])) a ua ca
  have ub := pass_unique _ _ _ _ _ _ _ h2 ua
  have cb : ∀ q, HasIdentity b q → q ∈ D := by
    intro q hq
    rcases (pass_identities _ _ _ _ _ _ _ h2 q).mp hq with h | h
    · exact ca q h
    · exact covers q (by simp [h])
  obtain ⟨c, h3⟩ := pass_accepts true (fun _ => false) 2 D bound [] old.toList
    ((valid_iff _ _ _ _).mpr ⟨fun _ => ⟨no, by simp⟩, by simp⟩)
    (fun x hx => covers x (by simp [hx])) b ub cb
  exact ⟨c, by simp only [h1, h2, h3]⟩

theorem restore_accepts_iff (voters old learners : Array Id) (hMAX : MAX < 2 ^ 64)
    (hv : voters.size < 2 ^ 64) (ho : old.size < 2 ^ 64) (hl : learners.size < 2 ^ 64) :
    (∃ r, Jarl.Membership.restore (MAX := MAX) voters old learners = pure (.Ok r)) ↔
      ValidInputs voters.toList old.toList learners.toList ∧
        Fits MAX (voters.toList ++ learners.toList ++ old.toList) := by
  constructor
  · rintro ⟨r, success⟩
    refine ⟨Restoration.valid voters old learners hMAX hv ho hl r success, keys_fit r _ ?_⟩
    intro q hq
    exact (restore_identities voters old learners hMAX hv ho hl r success q).mpr (by simpa [or_assoc] using hq)
  · rintro ⟨valid, fits⟩
    exact restore_accepts voters old learners hMAX hv ho hl valid fits

theorem stable_accepts_iff (voters learners : Array Id) (hMAX : MAX < 2 ^ 64)
    (hv : voters.size < 2 ^ 64) (hl : learners.size < 2 ^ 64) :
    (∃ r, Jarl.Membership.new (MAX := MAX) voters learners = pure (.Ok r)) ↔
      ValidInputs voters.toList [] learners.toList ∧ Fits MAX (voters.toList ++ learners.toList) := by
  simp only [new_eq]
  simpa using restore_accepts_iff (MAX := MAX) voters #[] learners hMAX hv (by simp) hl

theorem restore_accepts_by_count (voters old learners : Array Id) (hMAX : MAX < 2 ^ 64)
    (hv : voters.size < 2 ^ 64) (ho : old.size < 2 ^ 64) (hl : learners.size < 2 ^ 64) :
    (∃ r, Jarl.Membership.restore (MAX := MAX) voters old learners = pure (.Ok r)) ↔
      ValidInputs voters.toList old.toList learners.toList ∧
        (uniqueKeys (voters.toList ++ learners.toList ++ old.toList)).length ≤ MAX := by
  rw [restore_accepts_iff voters old learners hMAX hv ho hl, fits_iff_count]

theorem stable_accepts_by_count (voters learners : Array Id) (hMAX : MAX < 2 ^ 64)
    (hv : voters.size < 2 ^ 64) (hl : learners.size < 2 ^ 64) :
    (∃ r, Jarl.Membership.new (MAX := MAX) voters learners = pure (.Ok r)) ↔
      ValidInputs voters.toList [] learners.toList ∧ (uniqueKeys (voters.toList ++ learners.toList)).length ≤ MAX := by
  rw [stable_accepts_iff voters learners hMAX hv hl, fits_iff_count]

theorem stored_identity_count (voters old learners : Array Id) (hMAX : MAX < 2 ^ 64)
    (hv : voters.size < 2 ^ 64) (ho : old.size < 2 ^ 64) (hl : learners.size < 2 ^ 64) (r : Jarl.Membership MAX)
    (success : Jarl.Membership.restore voters old learners = pure (.Ok r)) :
    (Keys r).length = (uniqueKeys (voters.toList ++ learners.toList ++ old.toList)).length := by
  apply keys_count r (Restoration.unique_identities voters old learners hMAX hv ho hl r success)
  intro q
  rw [restore_identities voters old learners hMAX hv ho hl r success q]
  simp

theorem restore_error_code (voters old learners : Array Id) (hMAX : MAX < 2 ^ 64)
    (hv : voters.size < 2 ^ 64) (ho : old.size < 2 ^ 64) (hl : learners.size < 2 ^ 64) (e : Error)
    (failure : Jarl.Membership.restore (MAX := MAX) voters old learners = pure (.Err e)) : e = .Config := by
  rcases restore_err (MAX := MAX) voters old learners hMAX hv ho hl with ⟨r, h⟩ | h
  · rw [h] at failure; have := Rust.pure_inj failure; cases this
  · rw [h] at failure; have := Rust.pure_inj failure; cases this; rfl

theorem restore_rejects_iff (voters old learners : Array Id) (hMAX : MAX < 2 ^ 64)
    (hv : voters.size < 2 ^ 64) (ho : old.size < 2 ^ 64) (hl : learners.size < 2 ^ 64) :
    Jarl.Membership.restore (MAX := MAX) voters old learners = pure (.Err .Config) ↔
      ¬(ValidInputs voters.toList old.toList learners.toList ∧
        (uniqueKeys (voters.toList ++ learners.toList ++ old.toList)).length ≤ MAX) := by
  rw [← restore_accepts_by_count voters old learners hMAX hv ho hl]
  constructor
  · rintro failure ⟨r, success⟩
    rw [failure] at success; have := Rust.pure_inj success; cases this
  · intro rejected
    rcases restore_err (MAX := MAX) voters old learners hMAX hv ho hl with h | h
    · exact absurd h rejected
    · exact h

theorem stable_rejects_iff (voters learners : Array Id) (hMAX : MAX < 2 ^ 64)
    (hv : voters.size < 2 ^ 64) (hl : learners.size < 2 ^ 64) :
    Jarl.Membership.new (MAX := MAX) voters learners = pure (.Err .Config) ↔
      ¬(ValidInputs voters.toList [] learners.toList ∧ (uniqueKeys (voters.toList ++ learners.toList)).length ≤ MAX) := by
  simp only [new_eq]
  simpa using restore_rejects_iff (MAX := MAX) voters #[] learners hMAX hv (by simp) hl

end CapacityAcceptance

/-! ## Peers -/

namespace Peers
open SetInterpretation

theorem capacity_preserved (m : Jarl.Membership MAX) :
    m.peers.toList.length = m.members.toList.length := by simp

theorem slot_identity (m : Jarl.Membership MAX) (i : Nat) (h : i < MAX) :
    m.peers[i] = m.members[i].map Member.id := by
  simp [Jarl.Membership.peers]

theorem member_iff (m : Jarl.Membership MAX) (q : Id) : some q ∈ m.peers.toList ↔ HasIdentity m q := by
  simp only [Jarl.Membership.peers, Vector.toList_map, List.mem_map, HasIdentity]
  constructor
  · rintro ⟨o, ho, hq⟩
    cases o with
    | none => cases hq
    | some s => exact ⟨s, ho, by simpa using hq⟩
  · rintro ⟨s, hs, hq⟩
    exact ⟨some s, hs, by simp [hq]⟩

theorem restored_members (voters old learners : Array Id) (hMAX : MAX < 2 ^ 64)
    (hv : voters.size < 2 ^ 64) (ho : old.size < 2 ^ 64) (hl : learners.size < 2 ^ 64) (r : Jarl.Membership MAX)
    (success : Jarl.Membership.restore voters old learners = pure (.Ok r)) (q : Id) :
    some q ∈ r.peers.toList ↔ q ∈ voters.toList ∨ q ∈ learners.toList ∨ q ∈ old.toList := by
  rw [member_iff]; exact restore_identities voters old learners hMAX hv ho hl r success q

theorem stable_members (voters learners : Array Id) (hMAX : MAX < 2 ^ 64)
    (hv : voters.size < 2 ^ 64) (hl : learners.size < 2 ^ 64) (r : Jarl.Membership MAX)
    (success : Jarl.Membership.new voters learners = pure (.Ok r)) (q : Id) :
    some q ∈ r.peers.toList ↔ q ∈ voters.toList ∨ q ∈ learners.toList := by
  rw [new_eq] at success
  simpa using restored_members voters #[] learners hMAX hv (by simp) hl r success q

end Peers

end Jarl.Contracts.Membership
