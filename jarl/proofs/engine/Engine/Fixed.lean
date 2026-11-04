import Engine.Log

/-!
# The fixed engine's membership

`Node::new` builds its membership with `Membership::new(&members, &[])`. For
distinct members this is the stable configuration whose slot `k` holds
`members[k]` as a voter. Its `quorum` is a strict majority and its
`quorum_index` the largest index a majority has matched.
-/

namespace Jarl.Engine
open Jarl

/-- A member slot for a voter of a stable configuration. -/
def voter (id : Id) : Member := { id := id, voter := true, old := false, learner := false }

/-- Slots of a configuration whose first members are the voters `pre`. -/
def slots (pre : List Id) (r : Nat) : List (Option Member) :=
  pre.map (fun i => some (voter i)) ++ List.replicate r none

theorem position_id_none (pre : List Id) (r : Nat) (id : Id) (hd : id ∉ pre) :
    Rust.Iter.position (slots pre r) (fun m => Rust.Option.is_some_and m (fun m1 => m1.id == id)) = none := by
  simp only [Rust.Iter.position, Option.map_eq_none_iff, List.findIdx?_eq_none_iff]
  intro x hx
  simp only [slots, List.mem_append, List.mem_map, List.mem_replicate] at hx
  rcases hx with ⟨i, hi, rfl⟩ | ⟨_, rfl⟩
  · simp [voter]; intro h; subst h; exact hd hi
  · rfl

theorem position_free (pre : List Id) (r : Nat) (hr : 0 < r) :
    Rust.Iter.position (slots pre r) (fun o => o.isNone) = some (Rust.ofNat pre.length) := by
  simp only [Rust.Iter.position, slots]
  rw [List.findIdx?_append]
  have : List.findIdx? (fun o => o.isNone) (pre.map fun i => some (voter i)) = none := by
    simp [List.findIdx?_eq_none_iff]
  rw [this]
  obtain ⟨r', rfl⟩ : ∃ r', r = r' + 1 := ⟨r - 1, by omega⟩
  simp only [List.replicate_succ]
  simp
  exact ⟨0, by simp [List.findIdx?_cons], by simp⟩

/-- `include(id, 0)` of a fresh voter into the first free slot. -/
theorem include_voter {MAX : Nat} (m : Membership MAX) (pre : List Id) (r : Nat) (id : Id)
    (hm : m.members.toList = slots pre (r + 1)) (hd : id ∉ pre) (hmax : MAX < 2 ^ 64) :
    ∃ m', Membership.«include» m id 0 = pure (.Ok (), m') ∧ m'.members.toList = slots (pre ++ [id]) r := by
  have hlen : MAX = pre.length + (r + 1) := by
    have := congrArg List.length hm; simp [slots] at this; omega
  have hpos1 := position_id_none pre (r + 1) id hd
  have hpos2 := position_free pre (r + 1) (by omega)
  rw [← hm] at hpos1 hpos2
  have hslot : (Rust.ofNat pre.length : Rust.usize).val = pre.length := by
    simp [Rust.ofNat]; omega
  have hlt : (Rust.ofNat pre.length : Rust.usize).val < MAX := by omega
  have hget : m.members[pre.length]'(by omega) = none := by
    have : m.members[pre.length]'(by omega) = m.members.toList[pre.length]'(by simp; omega) := by simp
    rw [this]; simp only [hm, slots]
    rw [List.getElem_append_right (by simp)]; simp
  unfold Membership.«include»
  simp only [hpos1, hpos2, Option.orElse, Rust.Option.ok_or]
  simp [Rust.Slice.index_ok _ _ hlt, Rust.Slice.set_ok _ _ _ hlt, hslot, hget]
  refine ⟨_, rfl, ?_⟩
  simp only [Vector.toList_set, hm, slots]
  rw [List.set_append_right _ _ (by simp)]
  simp [List.replicate_succ, voter]

theorem enumerate_length {α : Type} (l : List α) : (Rust.Iter.enumerate l).length = l.length := by
  simp [Rust.Iter.enumerate]

theorem enumerate_get {α : Type} (l : List α) (k : Nat) (hk : k < (Rust.Iter.enumerate l).length) :
    (Rust.Iter.enumerate l)[k] = (Rust.ofNat k, l[k]'(by simpa [enumerate_length] using hk)) := by
  simp [Rust.Iter.enumerate]

/-- The stable configuration of `ids`, in slot order. -/
def stable {N : Nat} (ids : Vector Id N) : Membership N := ⟨ids.map (fun i => some (voter i))⟩

/-- `Membership::new(&members, &[])` for distinct members. -/
theorem new_stable {N : Nat} (ids : Vector Id N) (hn : 0 < N) (hN : N < 2 ^ 64) (hd : ids.toList.Nodup) :
    Membership.new (MAX := N) ids.toArray #[] = pure (.Ok (stable ids)) := by
  unfold Membership.new Membership.restore
  have hne : (ids.toArray.isEmpty) = false := by
    simp [Array.isEmpty]; omega
  simp only [hne, Bool.false_eq_true, if_false]
  simp only [Vector.toList_mk, List.forIn_cons, List.forIn_nil]
  have he : Rust.Iter.enumerate ([] : List Id) = [] := rfl
  simp only [he, List.forIn_nil, pure_bind, bind_assoc]
  refine Rust.forIn_bind_inv _ _ _ _ _
    (fun k b => b.1 = none ∧ b.2.members.toList = slots (ids.toList.take k) (N - k)) ⟨rfl, by simp [slots]⟩ ?_ ?_
  · intro k hk b ⟨hb1, hb2⟩
    rw [enumerate_length] at hk
    simp only [Array.length_toList, Vector.size_toArray] at hk
    have hkN : k < N := hk
    have hk2 : (Rust.ofNat k : Rust.usize).val = k := by simp [Rust.ofNat]; omega
    have hkl : k < ids.toList.length := by simpa using hkN
    have hnot : ids.toList[k] ∉ ids.toList.take k := by
      intro hm
      have hsplit := List.take_append_drop k ids.toList
      rw [← hsplit] at hd
      have hdisj := (List.nodup_append.mp hd).2.2
      have hmem : ids.toList[k] ∈ ids.toList.drop k := by
        rw [List.mem_iff_getElem]; exact ⟨0, by simp; omega, by simp⟩
      exact hdisj _ hm _ hmem rfl
    obtain ⟨m', hm', hs'⟩ := include_voter b.2 (ids.toList.take k) (N - k - 1) (ids.toList[k])
      (by rw [hb2]; congr 1; omega) hnot hN
    refine ⟨(none, m'), ?_, rfl, ?_⟩
    · simp only [enumerate_get]
      have hr : Rust.Slice.rangeA ids.toArray 0 (Rust.ofNat k) = pure (ids.toArray.extract 0 k) := by
        simp [Rust.Slice.rangeA, hk2]; omega
      have hidk : ids.toList[k] = ids[k] := by simp
      have hc : (ids.toArray.extract 0 k).toList.contains (ids.toArray.toList[k]'(by simpa using hkN)) = false := by
        simp only [Array.toList_extract, List.extract_eq_take_drop, List.drop_zero, Nat.sub_zero]
        have h' : ¬ (ids.toArray.toList[k]'(by simpa using hkN)) ∈ List.take k ids.toArray.toList := hnot
        simpa using h'
      rw [hidk] at hm'
      rw [hr]; simp only [pure_bind, hc]
      simp [hm']
    · rw [hs']; congr 1
      · rw [List.take_add_one, List.getElem?_eq_getElem hkl]; simp
  · intro b ⟨hb1, hb2⟩
    simp [hb1]
    rw [enumerate_length] at hb2
    simp only [Array.length_toList, Vector.size_toArray, Nat.sub_self] at hb2
    rw [List.take_of_length_le (by simp)] at hb2
    cases hb : b.2 with
    | mk members =>
      rw [hb] at hb2
      simp only [stable]
      have : members = Vector.map (fun i => some (voter i)) ids := by
        apply Vector.toList_inj.mp
        rw [show members.toList = _ from hb2]; simp [slots, Vector.toList_map]
      rw [this]

theorem stable_members {N : Nat} (ids : Vector Id N) :
    Rust.Iter.flatten (stable ids).members.toList = ids.toList.map voter := by
  simp only [stable, Rust.Iter.flatten, Vector.toList_map, List.filterMap_map]
  induction ids.toList with
  | nil => rfl
  | cons x xs ih => simp

theorem stable_not_joint {N : Nat} (ids : Vector Id N) : Membership.is_joint (stable ids) = false := by
  simp only [Membership.is_joint, stable_members, List.any_map]
  induction ids.toList with
  | nil => rfl
  | cons x xs ih => simp only [List.any_cons, Function.comp, voter, Bool.false_or]; exact ih

theorem stable_voters {N : Nat} (ids : Vector Id N) : Membership.voters (stable ids) = ids.toList := by
  simp only [Membership.voters, stable_members]
  induction ids.toList with
  | nil => rfl
  | cons x xs ih => simp [voter] at ih ⊢; exact ih

theorem any_eq_id (l : List Id) (id : Id) : l.any (fun x => x == id) = decide (id ∈ l) := by
  induction l with
  | nil => rfl
  | cons x xs ih =>
    simp only [List.any_cons, ih]
    by_cases h : x = id
    · subst h; simp
    · have : id ≠ x := fun e => h e.symm
      simp [h, this]

theorem stable_is_voter {N : Nat} (ids : Vector Id N) (id : Id) :
    Membership.is_voter (stable ids) id = decide (id ∈ ids.toList) := by
  simp only [Membership.is_voter, stable_members, List.any_map]
  rw [← any_eq_id]; simp [voter, Function.comp_def]

theorem stable_contains {N : Nat} (ids : Vector Id N) (id : Id) :
    Membership.contains (stable ids) id = decide (id ∈ ids.toList) := by
  simp only [Membership.contains, stable_members, List.any_map]
  rw [← any_eq_id]; simp [voter, Function.comp_def]

theorem stable_peers {N : Nat} (ids : Vector Id N) : Membership.peers (stable ids) = ids.map some := by
  simp [Membership.peers, stable, voter, Vector.map_map, Function.comp_def]

/-- A quorum of the stable configuration is a strict majority of its members. -/
theorem quorum_stable {N : Nat} (ids : Vector Id N) (hN : N < 2 ^ 64) (f : Id → Rust.M Bool) (g : Id → Bool)
    (hf : ∀ id ∈ ids.toList, f id = pure (g id)) :
    Membership.quorum (stable ids) f = pure (decide (N / 2 < (ids.toList.filter g).length)) := by
  have hv : List.filter (fun m => m.voter) (Rust.Iter.flatten (stable ids).members.toList) = ids.toList.map voter := by
    rw [stable_members]; simp [voter]
  have hfil : List.filterM (fun m => f m.id) (ids.toList.map voter) =
      pure ((ids.toList.map voter).filter (fun m => g m.id)) := by
    apply Rust.filterM_pure
    intro m hm
    obtain ⟨id, hid, rfl⟩ := List.mem_map.mp hm
    simp [hf id hid, voter]
  have hlen : ((ids.toList.map voter).filter (fun m => g m.id)).length = (ids.toList.filter g).length := by
    rw [List.filter_map, List.length_map]; rfl
  have hle : (ids.toList.filter g).length ≤ N := by
    have := List.length_filter_le g ids.toList; simpa using this
  unfold Membership.quorum
  simp only [hv, hfil, pure_bind, bind_pure, stable_not_joint, Bool.not_false, Bool.not_true, Bool.false_eq_true,
    if_false, Bool.false_eq_true]
  congr 1
  simp only [Rust.Iter.count, Rust.divK, Rust.ofNat, hlen, List.length_map, Fin.lt_def]
  have hl : ids.toList.length = N := by simp
  rw [hl, Nat.mod_eq_of_lt (by omega), Nat.mod_eq_of_lt (by omega)]
  by_cases hc : N / 2 < (List.filter g ids.toList).length <;> simp [hc] <;> omega

/-- In an ascending list, the element at `p` is at most every later one. -/
theorem sorted_count (s : List Rust.u64) (hs : s.Pairwise (fun a b => a.val ≤ b.val)) (p : Nat) (hp : p < s.length) :
    s.length - p ≤ (s.filter (fun x => decide (s[p].val ≤ x.val))).length := by
  have hsub : (s.drop p).Sublist s := List.drop_sublist _ _
  have hall : ∀ x ∈ s.drop p, decide (s[p].val ≤ x.val) = true := by
    intro x hx
    obtain ⟨j, hj, rfl⟩ := List.mem_iff_getElem.mp hx
    simp only [List.getElem_drop, decide_eq_true_eq]
    by_cases hj0 : j = 0
    · subst hj0; simp
    · have := List.pairwise_iff_getElem.mp hs p (p + j) hp (by simp at hj; omega) (by omega)
      exact this
  have := (hsub.filter (fun x => decide (s[p].val ≤ x.val))).length_le
  rw [List.filter_eq_self.mpr hall] at this
  simpa using this

/-- `quorum_index` of the stable configuration: a value matched by a strict majority. -/
theorem quorum_index_stable {N : Nat} (ids : Vector Id N) (hN0 : 0 < N) (hN : N < 2 ^ 63)
    (f : Id → Rust.M Rust.u64) (h : Id → Rust.u64) (hf : ∀ id ∈ ids.toList, f id = pure (h id)) :
    ∃ v, Membership.quorum_index (stable ids) f = pure v ∧
      N / 2 < (ids.toList.filter (fun id => decide (v.val ≤ (h id).val))).length := by
  unfold Membership.quorum_index
  simp only [stable_voters, stable_not_joint, Bool.not_false, if_true]
  have hl : ids.toList.length = N := by simp
  let srt := (ids.toList.map h).mergeSort (fun a b => decide (a.val ≤ b.val))
  have hsl : srt.length = N := by simp [srt]
  have hp : N - (N / 2 + 1) < srt.length := by omega
  refine ⟨srt[N - (N / 2 + 1)], Rust.forIn_bind_inv _ _ _ _ _
    (fun k b => b.2.val = k ∧ b.1.toList.take k = (ids.toList.take k).map h) ⟨rfl, by simp⟩ ?step ?fin, ?prop⟩
  case step =>
    intro k hk b ⟨hb1, hb2⟩
    rw [hl] at hk
    have hset : b.2.val < N := by omega
    refine ⟨(b.1.set b.2.val (h ids.toList[k]) hset, ⟨k + 1, by omega⟩), ?_, rfl, ?_⟩
    · have hfk := hf (ids.toList[k]'(by omega)) (List.getElem_mem _)
      simp only [hfk, pure_bind, Rust.Slice.set_ok _ _ _ hset]
      rw [Rust.add_ok _ _ (by simp [hb1]; omega)]
      simp [hb1]
    · show (b.1.set b.2.val (h ids.toList[k]) hset).toList.take (k + 1) = _
      rw [Vector.toList_set, hb1]
      have hk' : k < b.1.toList.length := by simp; omega
      rw [List.take_add_one, List.take_add_one, List.take_set_of_le (by omega) , hb2,
        List.getElem?_set_self hk', List.getElem?_eq_getElem (by simp; omega)]
      simp
  case fin =>
    intro b ⟨hb1, hb2⟩
    rw [hl] at hb1 hb2
    have hfull : b.1.toList = ids.toList.map h := by
      rw [List.take_of_length_le (by simp)] at hb2
      rw [List.take_of_length_le (by simp)] at hb2
      exact hb2
    have hcnt : b.2 = Rust.usizeOf N := Fin.ext (by rw [Rust.val_usizeOf _ (by omega)]; exact hb1)
    have hext : b.1.toArray.extract 0 N = b.1.toArray := by simp
    rw [hcnt, Rust.Slice.range_ok _ _ _ (by simp [Rust.val_usizeOf _ (show N < 2 ^ 64 by omega)])]
    simp only [pure_bind, Rust.val_usizeOf _ (show N < 2 ^ 64 by omega), Fin.val_zero, hext]
    have hsort : (Rust.Slice.sort_unstable b.1.toArray) = srt.toArray := by
      simp only [Rust.Slice.sort_unstable, srt]
      congr 1
      show b.1.toList.mergeSort _ = _
      rw [hfull]
    rw [hsort]
    have hN64 : N < 2 ^ 64 := by omega
    have hdiv : (Rust.divK (Rust.usizeOf N) 2).val = N / 2 := by
      simp [Rust.divK, Rust.val_usizeOf _ hN64]
    rw [Rust.add_ok _ _ (by rw [hdiv]; simp; omega)]
    simp only [pure_bind]
    rw [Rust.sub_ok _ _ (by simp [hdiv, Rust.val_usizeOf _ hN64]; omega)]
    simp only [pure_bind]
    rw [Rust.Slice.index_ok _ _ (by simp [hdiv, Rust.val_usizeOf _ hN64]; omega)]
    congr 1
    simp only [Rust.Slice.setRange, Vector.getElem_ofFn]
    simp [hdiv, Rust.val_usizeOf _ hN64, hsl]
    rw [dif_pos (by omega)]
  case prop =>
    have hperm := (List.mergeSort_perm (ids.toList.map h) (fun a b => decide (a.val ≤ b.val)))
    have hsorted : srt.Pairwise (fun a b => a.val ≤ b.val) := by
      have := List.pairwise_mergeSort (le := fun a b : Rust.u64 => decide (a.val ≤ b.val))
        (by intro a b c h1 h2; simp at *; omega) (by intro a b; simp; omega) (ids.toList.map h)
      simpa using this
    have hc := sorted_count srt hsorted (N - (N / 2 + 1)) hp
    have hf' := (hperm.filter (fun x => decide (srt[N - (N / 2 + 1)].val ≤ x.val))).length_eq
    rw [hsl] at hc
    rw [show (ids.toList.filter fun id => decide (srt[N - (N / 2 + 1)].val ≤ (h id).val)).length =
        ((ids.toList.map h).filter fun x => decide (srt[N - (N / 2 + 1)].val ≤ x.val)).length by
      rw [List.filter_map, List.length_map]; rfl]
    rw [hf'] at hc; omega



end Jarl.Engine
