import Generated

/-!
# Membership contracts: projections, finalization, identity queries, `include`

Typed-backend port of the `membership` proof project. Every theorem is about the
translated `Jarl.Membership.*` definitions in `Generated.lean`.
-/

namespace Jarl.Contracts.Membership
open Jarl

variable {MAX : Nat}

/-! ## Vocabulary -/

/-- The occupied slots of a configuration, in slot order. -/
def occ (m : Jarl.Membership MAX) : List Member := Rust.Iter.flatten m.members.toList

theorem mem_occ (m : Jarl.Membership MAX) (s : Member) : s ∈ occ m ↔ some s ∈ m.members.toList := by
  simp [occ, Rust.Iter.flatten]

/-- The identities stored in occupied slots, in slot order. -/
def Keys (m : Jarl.Membership MAX) : List Id := (occ m).map Member.id

/-- No identity occupies two slots. -/
def UniqueIdentities (m : Jarl.Membership MAX) : Prop := (Keys m).Nodup

/-- Some occupied slot holds identity `q`. -/
def HasIdentity (m : Jarl.Membership MAX) (q : Id) : Prop :=
  ∃ s, some s ∈ m.members.toList ∧ s.id = q

theorem keys_member (m : Jarl.Membership MAX) (q : Id) : q ∈ Keys m ↔ HasIdentity m q := by
  simp only [Keys, List.mem_map, mem_occ, HasIdentity]

theorem keys_length (m : Jarl.Membership MAX) : (Keys m).length ≤ MAX := by
  have h := List.length_filterMap_le (f := (id : Option Member → Option Member)) m.members.toList
  simpa [Keys, occ, Rust.Iter.flatten] using h

/-- The three per-slot role flags. -/
inductive Flag where
  | voter
  | learner
  | old
  deriving DecidableEq

def Flag.get : Flag → Member → Bool
  | .voter, s => s.voter
  | .learner, s => s.learner
  | .old, s => s.old

/-- The flag `include(id, kind)` sets. -/
def Flag.ofKind (k : Rust.u8) : Flag := if k = 0 then .voter else if k = 1 then .learner else .old

/-- Identity `q` occupies a slot whose flag `F` is set. -/
def FlagMember (F : Flag) (m : Jarl.Membership MAX) (q : Id) : Prop :=
  ∃ s, some s ∈ m.members.toList ∧ s.id = q ∧ F.get s = true

/-! ## Projections -/

namespace MembershipProjection

private theorem proj_exact (l : List (Option Member)) (p : Member → Bool) :
    ((Rust.Iter.flatten l).filter p).map Member.id =
      l.filterMap (fun e => match e with
        | none => none
        | some s => if p s then some s.id else none) := by
  induction l with
  | nil => rfl
  | cons e rest ih =>
    cases e with
    | none => simpa [Rust.Iter.flatten] using ih
    | some s =>
      by_cases hp : p s
      · simp only [Rust.Iter.flatten] at ih ⊢; simp [hp, ih]
      · simp only [Rust.Iter.flatten] at ih ⊢; simp [hp, ih]

theorem voters_exact (m : Jarl.Membership MAX) :
    m.voters = m.members.toList.filterMap (fun e => match e with
      | none => none
      | some s => if s.voter then some s.id else none) :=
  proj_exact _ _

theorem old_voters_exact (m : Jarl.Membership MAX) :
    m.old_voters = m.members.toList.filterMap (fun e => match e with
      | none => none
      | some s => if s.old then some s.id else none) :=
  proj_exact _ _

theorem learners_exact (m : Jarl.Membership MAX) :
    m.learners = m.members.toList.filterMap (fun e => match e with
      | none => none
      | some s => if s.learner then some s.id else none) :=
  proj_exact _ _

theorem voters_member (m : Jarl.Membership MAX) (q : Id) :
    q ∈ m.voters ↔ ∃ s, some s ∈ m.members.toList ∧ s.voter = true ∧ s.id = q := by
  simp [Jarl.Membership.voters, Rust.Iter.flatten, and_assoc]

theorem old_voters_member (m : Jarl.Membership MAX) (q : Id) :
    q ∈ m.old_voters ↔ ∃ s, some s ∈ m.members.toList ∧ s.old = true ∧ s.id = q := by
  simp [Jarl.Membership.old_voters, Rust.Iter.flatten, and_assoc]

theorem learners_member (m : Jarl.Membership MAX) (q : Id) :
    q ∈ m.learners ↔ ∃ s, some s ∈ m.members.toList ∧ s.learner = true ∧ s.id = q := by
  simp [Jarl.Membership.learners, Rust.Iter.flatten, and_assoc]

theorem voters_flag (m : Jarl.Membership MAX) (q : Id) : q ∈ m.voters ↔ FlagMember .voter m q := by
  rw [voters_member]; simp only [FlagMember, Flag.get]
  exact ⟨fun ⟨s, a, b, c⟩ => ⟨s, a, c, b⟩, fun ⟨s, a, b, c⟩ => ⟨s, a, c, b⟩⟩

theorem old_voters_flag (m : Jarl.Membership MAX) (q : Id) : q ∈ m.old_voters ↔ FlagMember .old m q := by
  rw [old_voters_member]; simp only [FlagMember, Flag.get]
  exact ⟨fun ⟨s, a, b, c⟩ => ⟨s, a, c, b⟩, fun ⟨s, a, b, c⟩ => ⟨s, a, c, b⟩⟩

theorem learners_flag (m : Jarl.Membership MAX) (q : Id) : q ∈ m.learners ↔ FlagMember .learner m q := by
  rw [learners_member]; simp only [FlagMember, Flag.get]
  exact ⟨fun ⟨s, a, b, c⟩ => ⟨s, a, c, b⟩, fun ⟨s, a, b, c⟩ => ⟨s, a, c, b⟩⟩

end MembershipProjection

/-! ## Finalization -/

namespace Finalization

/-- The per-slot effect of `finalized`. -/
def finSlot : Option Member → Option Member
  | none => none
  | some s => if s.voter || s.learner then some { s with old := false } else none

theorem finalized_members (m : Jarl.Membership MAX) :
    m.finalized.members = m.members.map finSlot := by
  apply Vector.ext
  intro i hi
  simp only [Jarl.Membership.finalized, Id.run, Vector.getElem_map, pure]
  cases m.members[i] with
  | none => rfl
  | some s =>
    cases hv : s.voter <;> cases hl : s.learner <;> simp [finSlot, hv, hl]

theorem capacity_preserved (m : Jarl.Membership MAX) :
    m.finalized.members.toList.length = m.members.toList.length := by simp

/-- All four voter/learner combinations, for any identity: a slot survives
    (with its old flag cleared and every other field kept) exactly when it is
    a voter or a learner; empty slots stay empty. -/
theorem slot_effect (m : Jarl.Membership MAX) (i : Nat) (h : i < MAX) :
    m.finalized.members[i] =
      match m.members[i] with
      | none => none
      | some s => if s.voter || s.learner then some { s with old := false } else none := by
  rw [finalized_members, Vector.getElem_map]
  cases m.members[i] <;> rfl

theorem retained_fields (m : Jarl.Membership MAX) (i : Nat) (h : i < MAX) (r : Member)
    (retained : m.finalized.members[i] = some r) :
    r.old = false ∧ ∃ s, m.members[i] = some s ∧ r.id = s.id ∧ r.voter = s.voter ∧ r.learner = s.learner := by
  rw [slot_effect m i h] at retained
  cases hs : m.members[i] with
  | none => rw [hs] at retained; cases retained
  | some s =>
    rw [hs] at retained
    dsimp only at retained
    by_cases k : (s.voter || s.learner) = true
    · rw [if_pos k] at retained
      cases retained
      exact ⟨rfl, s, rfl, rfl, rfl, rfl⟩
    · rw [if_neg k] at retained; cases retained

theorem all_old_flags_cleared (m : Jarl.Membership MAX) (r : Member)
    (member : some r ∈ m.finalized.members.toList) : r.old = false := by
  obtain ⟨i, hi, hr⟩ := List.getElem_of_mem member
  simp only [Vector.length_toList] at hi
  simp only [Vector.getElem_toList] at hr
  exact (retained_fields m i hi r hr).1

theorem identity_origin (m : Jarl.Membership MAX) (r : Member)
    (member : some r ∈ m.finalized.members.toList) :
    ∃ s, some s ∈ m.members.toList ∧ r.id = s.id := by
  obtain ⟨i, hi, hr⟩ := List.getElem_of_mem member
  simp only [Vector.length_toList] at hi
  simp only [Vector.getElem_toList] at hr
  obtain ⟨_, s, hs, hid, _⟩ := retained_fields m i hi r hr
  refine ⟨s, ?_, hid⟩
  rw [← hs]; simp

theorem no_longer_joint (m : Jarl.Membership MAX) : m.finalized.is_joint = false := by
  simp only [Jarl.Membership.is_joint, List.any_eq_false]
  intro s hs
  have := all_old_flags_cleared m s ((mem_occ _ _).mp hs)
  simp [this]

end Finalization

namespace MembershipProjection
open Finalization

private theorem fin_proj (l : List (Option Member)) (p : Member → Bool)
    (hp : ∀ s : Member, p s = true → (s.voter || s.learner) = true) (hold : ∀ s : Member, p { s with old := false } = p s) :
    ((Rust.Iter.flatten (l.map finSlot)).filter p).map Member.id =
      ((Rust.Iter.flatten l).filter p).map Member.id := by
  induction l with
  | nil => rfl
  | cons e rest ih =>
    cases e with
    | none => simpa [Rust.Iter.flatten, finSlot] using ih
    | some s =>
      simp only [Rust.Iter.flatten, List.filterMap_map, show (id ∘ finSlot) = finSlot from rfl] at ih ⊢
      rw [List.filterMap_cons, List.filterMap_cons]
      by_cases k : (s.voter || s.learner) = true
      · have hf : finSlot (some s) = some { s with old := false } := by simp only [finSlot, k, if_true]
        rw [hf]
        by_cases q : p s = true
        · simp [q, hold, ih]
        · simp [q, hold, ih]
      · have q : p s = false := by
          cases h : p s
          · rfl
          · exact absurd (hp s h) k
        have hf : finSlot (some s) = none := by simp only [finSlot, k]; rfl
        rw [hf]
        simp [q, ih]

theorem finalization_preserves_voters (m : Jarl.Membership MAX) : m.finalized.voters = m.voters := by
  simp only [Jarl.Membership.voters, finalized_members, Vector.toList_map]
  exact fin_proj _ _ (fun s h => by simp [h]) (fun _ => rfl)

theorem finalization_preserves_learners (m : Jarl.Membership MAX) : m.finalized.learners = m.learners := by
  simp only [Jarl.Membership.learners, finalized_members, Vector.toList_map]
  exact fin_proj _ _ (fun s h => by simp [h]) (fun _ => rfl)

theorem finalization_has_no_old_voters (m : Jarl.Membership MAX) : m.finalized.old_voters = [] := by
  apply List.eq_nil_iff_forall_not_mem.mpr
  intro q hq
  obtain ⟨s, hs, ho, _⟩ := (old_voters_member _ q).mp hq
  rw [all_old_flags_cleared m s hs] at ho
  cases ho

end MembershipProjection

/-! ## Identity queries -/

namespace IdentityQuery
open MembershipProjection

theorem contains_exact (m : Jarl.Membership MAX) (q : Id) :
    m.contains q = true ↔ ∃ s, some s ∈ m.members.toList ∧ s.id = q := by
  simp only [Jarl.Membership.contains, List.any_eq_true, Rust.Iter.flatten, List.mem_filterMap, id_eq,
    beq_iff_eq]
  constructor
  · rintro ⟨s, ⟨_, hm, rfl⟩, hid⟩; exact ⟨s, hm, hid⟩
  · rintro ⟨s, hm, hid⟩; exact ⟨s, ⟨_, hm, rfl⟩, hid⟩

theorem is_voter_exact (m : Jarl.Membership MAX) (q : Id) :
    m.is_voter q = true ↔ q ∈ m.voters ∨ q ∈ m.old_voters := by
  rw [voters_member, old_voters_member]
  simp only [Jarl.Membership.is_voter, List.any_eq_true, Bool.and_eq_true, beq_iff_eq,
    Bool.or_eq_true, Rust.Iter.flatten, List.mem_filterMap, id_eq]
  constructor
  · rintro ⟨s, ⟨_, hm, rfl⟩, hid, hv | ho⟩
    · exact Or.inl ⟨s, hm, hv, hid⟩
    · exact Or.inr ⟨s, hm, ho, hid⟩
  · rintro (⟨s, hm, hv, hid⟩ | ⟨s, hm, ho, hid⟩)
    · exact ⟨s, ⟨_, hm, rfl⟩, hid, Or.inl hv⟩
    · exact ⟨s, ⟨_, hm, rfl⟩, hid, Or.inr ho⟩

theorem voter_participates (m : Jarl.Membership MAX) (q : Id) (voter : m.is_voter q = true) :
    m.contains q = true := by
  rw [contains_exact]
  rcases (is_voter_exact m q).mp voter with h | h
  · obtain ⟨s, hm, _, hid⟩ := (voters_member m q).mp h; exact ⟨s, hm, hid⟩
  · obtain ⟨s, hm, _, hid⟩ := (old_voters_member m q).mp h; exact ⟨s, hm, hid⟩

theorem contains_iff_has (m : Jarl.Membership MAX) (q : Id) : m.contains q = true ↔ HasIdentity m q :=
  contains_exact m q

end IdentityQuery

end Jarl.Contracts.Membership
