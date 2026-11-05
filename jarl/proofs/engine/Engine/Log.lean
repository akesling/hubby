import Generated

/-!
# Logs of `State`

A `State` stores a snapshot boundary (`base`) and a retained suffix in the
first `len` of `CAP` slots. This module names that suffix (`ret`), states the
representation invariant (`Layout`), and characterizes every `State` function
the engine uses in terms of it.
-/

namespace Jarl.Engine
open Jarl

variable {V S : Type} {CAP : Nat}

/-- `omega` after rewriting the pointer width `Rust.usizeBits` to the build's literal
    everywhere, so bounds stated with `2 ^ Rust.usizeBits` become linear facts. -/
macro "uomega" : tactic => `(tactic| ((try simp only [Rust.usizeBits_eq] at *) <;> omega))

/-- Every `usize` value fits a `u64` (`usize` is at most 64 bits wide). -/
theorem usize_lt_u64 (x : Rust.usize) : x.val < 2 ^ 64 :=
  Nat.lt_of_lt_of_le x.isLt (Nat.pow_le_pow_right (by decide) Rust.usizeBits_range.2)

/-- `k as usize as u64` for a `k` that fits the pointer width. -/
theorem cast_ofNat_usize (k : Nat) (h : k < 2 ^ Rust.usizeBits) :
    (Rust.cast (Rust.ofNat k : Rust.usize) : Rust.u64) = Rust.ofNat k := by
  have h64 : k < 2 ^ 64 := Nat.lt_of_lt_of_le h (Nat.pow_le_pow_right (by decide) Rust.usizeBits_range.2)
  apply Fin.ext
  simp only [Rust.cast, Rust.ofNat]
  rw [Nat.mod_eq_of_lt h, Nat.mod_eq_of_lt h64]

/-- Retained entries in slot order: the occupied prefix of the slots. -/
def ret (s : State V S CAP) : List (Entry V) := (s.entries.toList.take s.len.val).filterMap id

/-- The last retained identity, or the snapshot boundary when none is retained. -/
def lastId (s : State V S CAP) : LogId := ((ret s).getLast?.map (·.id)).getD s.base

/-- Slot layout: the first `len` slots hold the retained entries, the rest are empty. -/
def Layout (s : State V S CAP) : Prop :=
  s.len.val ≤ CAP ∧ s.entries.toList = (ret s).map some ++ List.replicate (CAP - s.len.val) none

theorem ret_of_slots (s : State V S CAP) (l : List (Entry V)) (hlen : s.len.val = l.length)
    (h : s.entries.toList = l.map some ++ List.replicate (CAP - l.length) none) : ret s = l := by
  simp only [ret, h, hlen]
  simp

/-- A layout from an explicit list of retained entries. -/
theorem layout_of (s : State V S CAP) (l : List (Entry V)) (hlen : s.len.val = l.length)
    (hc : l.length ≤ CAP) (h : s.entries.toList = l.map some ++ List.replicate (CAP - l.length) none) :
    Layout s ∧ ret s = l := by
  have hr := ret_of_slots s l hlen h
  exact ⟨⟨by omega, by rw [hr, h, hlen]⟩, hr⟩

theorem set_after {α : Type} (A : List α) (x : α) (m : Nat) (d : α) :
    (A ++ List.replicate (m + 1) d).set A.length x = (A ++ [x]) ++ List.replicate m d := by
  rw [List.set_append_right _ _ (by omega)]
  simp [List.replicate_succ]

theorem toList_take_len (s : State V S CAP) (h : s.len.val ≤ CAP) :
    (s.entries.toList.take s.len.val).length = s.len.val := by simp; omega

theorem entries_fn_eq (s : State V S CAP) (h : s.len.val ≤ CAP) :
    State.entries_fn s = pure (ret s) := by
  simp [State.entries_fn, Rust.Slice.range, h, ret, Rust.Iter.flatten, Array.toList_extract]
  rfl

theorem last_eq (s : State V S CAP) (h : s.len.val ≤ CAP) : State.last s = pure (lastId s) := by
  simp only [State.last, entries_fn_eq s h, pure_bind, lastId]
  cases (ret s).getLast? <;> rfl

/-- Reading slot `k` under the layout: the `k`-th retained entry. -/
theorem slot_eq (s : State V S CAP) (hl : Layout s) (k : Nat) :
    (s.entries.toList[k]?).join = (ret s)[k]? := by
  rw [hl.2]
  by_cases hk : k < (ret s).length
  · rw [List.getElem?_append_left (by simpa using hk)]
    simp [hk]
  · rw [List.getElem?_append_right (by simpa using hk)]
    simp only [List.getElem?_replicate, List.length_map]
    rw [List.getElem?_eq_none (by omega)]
    split <;> rfl

theorem len_eq (s : State V S CAP) (hl : Layout s) : s.len.val = (ret s).length := by
  have := congrArg List.length hl.2; have := hl.1; simp at *; omega

-- Width-generic proofs: some simp arguments only fire at one pointer width.
set_option linter.unusedSimpArgs false in
theorem get_eq (s : State V S CAP) (hl : Layout s) (i : Rust.u64) :
    State.get s i = if s.base.index.val < i.val then (ret s)[i.val - s.base.index.val - 1]? else none := by
  unfold State.get
  by_cases h : s.base.index.val < i.val
  · have h1 : s.base.index.val ≤ i.val := by omega
    have h2 : 1 ≤ i.val - s.base.index.val := by omega
    rw [if_pos h]
    by_cases hw : i.val - s.base.index.val - 1 < 2 ^ Rust.usizeBits
    · rw [← slot_eq s hl]
      simp only [Rust.usizeBits_eq] at hw
      simp [Rust.checked_sub_eq, h1, h2, Rust.try_from, Rust.Result.ok, Rust.Slice.get, hw]
      cases s.entries[i.val - s.base.index.val - 1]? with
      | none => rfl
      | some o => cases o <;> rfl
    · -- offsets past the pointer width are past every retained slot (`len` is a `usize`)
      have hlen : (ret s).length < 2 ^ Rust.usizeBits := len_eq s hl ▸ s.len.isLt
      rw [List.getElem?_eq_none (by omega)]
      simp only [Rust.usizeBits_eq] at hw
      first
        | (exfalso; have := i.isLt; omega)
        | simp [Rust.checked_sub_eq, h1, h2, Rust.try_from, Rust.Result.ok, hw]
  · rw [if_neg h]
    by_cases h1 : s.base.index.val ≤ i.val
    · have h2 : ¬ 1 ≤ i.val - s.base.index.val := by omega
      simp [Rust.checked_sub_eq, h1, h2]
    · simp [Rust.checked_sub_eq, h1]

/-- The identity at `i`: the boundary itself, or a retained entry's. -/
def idAt (s : State V S CAP) (i : Nat) : Option LogId :=
  if i = s.base.index.val then some s.base
  else if s.base.index.val < i then ((ret s)[i - s.base.index.val - 1]?).map (·.id) else none

theorem id_at_eq (s : State V S CAP) (hl : Layout s) (i : Rust.u64) :
    State.id_at s i = idAt s i.val := by
  unfold State.id_at idAt
  by_cases h : i.val = s.base.index.val
  · have : i = s.base.index := Fin.ext h
    simp [this]
  · have : i ≠ s.base.index := fun e => h (congrArg Fin.val e)
    simp [this, h, get_eq s hl]
    split <;> rfl

theorem push_full (s : State V S CAP) (e : Entry V) (hc : CAP < 2 ^ Rust.usizeBits) (hf : s.len.val = CAP) :
    State.push s e = pure (.Err .Full, s) := by
  have : s.len = Rust.usizeOf CAP := Fin.ext (by rw [Rust.val_usizeOf _ hc]; exact hf)
  simp [State.push, State.full, this]

/-- Pushing into a free slot appends to the retained entries. -/
theorem push_ok (s : State V S CAP) (e : Entry V) (hc : CAP < 2 ^ Rust.usizeBits) (hl : Layout s)
    (hf : s.len.val < CAP) :
    ∃ s', State.push s e = pure (.Ok (), s') ∧ s'.hard = s.hard ∧ s'.snapshot = s.snapshot ∧
      ret s' = ret s ++ [e] ∧ s'.len.val = s.len.val + 1 ∧ Layout s' := by
  have hne : s.len ≠ Rust.usizeOf CAP := fun h => by
    have := congrArg Fin.val h; rw [Rust.val_usizeOf _ hc] at this; omega
  have hlen : s.len.val + 1 < 2 ^ Rust.usizeBits := by omega
  refine ⟨{ s with entries := s.entries.set s.len.val (some e) hf, len := ⟨s.len.val + 1, hlen⟩ }, ?_, rfl, rfl, ?_, rfl, ?_⟩
  · have hlen' := hlen
    simp only [Rust.usizeBits_eq] at hlen'
    simp [State.push, State.full, hne, hf, hlen']
  all_goals
    have hs : s.entries.toList.set s.len.val (some e) =
        (ret s ++ [e]).map some ++ List.replicate (CAP - (ret s ++ [e]).length) none := by
      have hr := hl.2
      have hlr : s.len.val = (ret s).length := by
        have := congrArg List.length hr; simp at this; omega
      rw [hr, hlr, show CAP - (ret s).length = (CAP - ((ret s).length + 1)) + 1 by omega]
      have := set_after ((ret s).map some) (some e) (CAP - ((ret s).length + 1)) none
      simp only [List.length_map] at this
      rw [this]; simp
    have hlr : s.len.val = (ret s).length := by
      have := congrArg List.length hl.2; simp at this; omega
    have := layout_of { s with entries := s.entries.set s.len.val (some e) hf, len := ⟨s.len.val + 1, hlen⟩ }
      (ret s ++ [e]) (by simp; omega) (by simp; omega) (by rw [Vector.toList_set]; exact hs)
  · exact this.2
  · exact this.1

/-- Retained entries are numbered consecutively after the snapshot boundary. -/
def Contig (s : State V S CAP) : Prop :=
  ∀ k (h : k < (ret s).length), ((ret s)[k]).id.index.val = s.base.index.val + k + 1

theorem lastId_eq (s : State V S CAP) (hc : Contig s) :
    (lastId s).index.val = s.base.index.val + (ret s).length := by
  unfold lastId
  cases h : (ret s).getLast? with
  | none => simp [List.getLast?_eq_none_iff.mp h]
  | some e =>
    have hne : ret s ≠ [] := by intro h'; simp [h'] at h
    have hlen : 0 < (ret s).length := List.length_pos_iff.mpr hne
    rw [List.getLast?_eq_getElem?] at h
    have := hc ((ret s).length - 1) (by omega)
    rw [List.getElem?_eq_getElem (by omega)] at h
    simp at h; subst h; simp; omega

/-- Removing the last occupied slot. -/
def pop (s : State V S CAP) (h : 0 < s.len.val) (hc : s.len.val ≤ CAP) : State V S CAP :=
  { s with len := ⟨s.len.val - 1, by omega⟩, entries := s.entries.set (s.len.val - 1) none (by omega) }

theorem pop_spec (s : State V S CAP) (hl : Layout s) (hc : Contig s) (h : 0 < s.len.val) :
    Layout (pop s h hl.1) ∧ ret (pop s h hl.1) = (ret s).dropLast ∧ Contig (pop s h hl.1) := by
  have hlr := len_eq s hl
  obtain ⟨l, x, hlx⟩ : ∃ l x, ret s = l ++ [x] := by
    obtain ⟨l, x, e⟩ := List.eq_nil_or_concat (ret s) |>.resolve_left (by intro e; simp [e] at hlr; omega)
    exact ⟨l, x, by rw [e, List.concat_eq_append]⟩
  have hs : (pop s h hl.1).entries.toList = l.map some ++ List.replicate (CAP - l.length) none := by
    simp only [pop, Vector.toList_set]
    rw [hl.2, hlx]
    have : s.len.val - 1 = (l.map some).length := by simp [hlr, hlx]
    rw [this]
    simp only [List.map_append, List.map_cons, List.map_nil, List.append_assoc, List.singleton_append]
    rw [List.set_append_right _ _ (by simp)]
    simp only [List.length_map, Nat.sub_self, List.set_cons_zero]
    have hcap := hl.1
    rw [hlr, hlx] at hcap; simp at hcap
    rw [hlr, hlx]; simp only [List.length_append, List.length_singleton]
    rw [show CAP - l.length = (CAP - (l.length + 1)) + 1 by omega, List.replicate_succ]
  have hl' := layout_of (pop s h hl.1) l (by simp [pop, hlr, hlx]) (by have := hl.1; rw [hlr, hlx] at this; simp at this; omega) hs
  refine ⟨hl'.1, by rw [hl'.2, hlx]; simp, ?_⟩
  intro k hk
  have hk2 : k < l.length := by rw [hl'.2] at hk; exact hk
  have hk' : k < (ret s).length := by rw [hlx]; simp; omega
  have h1 := hc k hk'
  have h2 : (ret s)[k] = l[k] := by
    rw [List.getElem_of_eq hlx]; exact List.getElem_append_left hk2
  have h3 : (ret (pop s h hl.1))[k] = l[k] := List.getElem_of_eq hl'.2 _
  rw [h3, ← h2, h1]; rfl

theorem truncate_pop (s : State V S CAP) (f : Rust.u64) (hl : Layout s)
    (h : f.val ≤ (lastId s).index.val ∧ 0 < s.len.val) :
    State.truncate s f = State.truncate (pop s h.2 hl.1) f := by
  unfold State.truncate
  simp only [bind_pure]
  apply Rust.loop_yield
  have h1 : 1 ≤ s.len.val := h.2
  have h2 : s.len.val - 1 < CAP := by have := hl.1; omega
  have a1 : ¬ (lastId s).index < f := by rw [Fin.lt_def]; omega
  have a2 : s.len ≠ 0 := fun e => by simp [e] at h1
  simp [last_eq s hl.1, a1, a2, h1, h2, pop]

theorem truncate_stop (s : State V S CAP) (f : Rust.u64) (hl : Layout s)
    (h : ¬ (f.val ≤ (lastId s).index.val ∧ 0 < s.len.val)) : State.truncate s f = pure s := by
  unfold State.truncate
  simp only [bind_pure]
  apply Rust.loop_done
  simp only [last_eq s hl.1, pure_bind]
  by_cases a1 : f ≤ (lastId s).index
  · have a2 : s.len = 0 := by
      apply Fin.ext; rw [Fin.le_def] at a1; simp; omega
    simp [a1, a2]
  · simp [a1]

/-- `truncate from` drops every retained entry at or after `from`. -/
theorem truncate_spec (s : State V S CAP) (f : Rust.u64) (hl : Layout s) (hc : Contig s) :
    ∃ s', State.truncate s f = pure s' ∧ s'.hard = s.hard ∧ s'.snapshot = s.snapshot ∧
      ret s' = (ret s).take (f.val - s.base.index.val - 1) ∧ Layout s' ∧ Contig s' := by
  induction h : s.len.val generalizing s with
  | zero =>
    have : ret s = [] := by have := len_eq s hl; rw [h] at this; exact List.eq_nil_of_length_eq_zero this.symm
    refine ⟨s, truncate_stop s f hl (by omega), rfl, rfl, by simp [this], hl, hc⟩
  | succ n ih =>
    have hlen := len_eq s hl
    have hlast := lastId_eq s hc
    by_cases hf : f.val ≤ (lastId s).index.val
    · obtain ⟨hl', hr', hc'⟩ := pop_spec s hl hc (by omega)
      obtain ⟨s', e, h1, h2, h3, h4, h5⟩ := ih (pop s (by omega) hl.1) hl' hc' (by simp [pop]; omega)
      refine ⟨s', by rw [truncate_pop s f hl ⟨hf, by omega⟩, e], h1, h2, ?_, h4, h5⟩
      have hb : State.base (pop s (by omega) hl.1) = State.base s := rfl
      rw [h3, hr', hb, List.dropLast_eq_take, List.take_take]
      congr 1; omega
    · refine ⟨s, truncate_stop s f hl (by omega), rfl, rfl, ?_, hl, hc⟩
      rw [List.take_of_length_le (by omega)]

/-- A slot under the layout: the retained entry, or empty. -/
theorem entry_get (s : State V S CAP) (hl : Layout s) (j : Nat) (hj : j < CAP) :
    s.entries[j] = if h : j < (ret s).length then some (ret s)[j] else none := by
  have : s.entries[j] = s.entries.toList[j]'(by simpa using hj) := by simp
  rw [this]
  simp only [hl.2]
  split
  · rename_i h; rw [List.getElem_append_left (by simpa using h)]; simp
  · rename_i h; rw [List.getElem_append_right (by simpa using h)]; simp
theorem idAt_some (s : State V S CAP) (_hl : Layout s) (_hc : Contig s) (id : LogId)
    (h : idAt s id.index.val = some id) :
    s.base.index.val ≤ id.index.val ∧ id.index.val - s.base.index.val ≤ (ret s).length := by
  unfold idAt at h
  split at h
  · simp_all
  · split at h
    · rename_i h1 h2
      simp only [Option.map_eq_some_iff] at h
      obtain ⟨e, he, _⟩ := h
      have := (List.getElem?_eq_some_iff.mp he).1
      omega
    · simp at h

set_option linter.unusedSimpArgs false in
theorem install_spec (s : State V S CAP) (snap : Snapshot S) (hcap : CAP < 2 ^ Rust.usizeBits)
    (hl : Layout s) (hc : Contig s) :
    ∃ s', State.install s snap = pure s' ∧ s'.snapshot = some snap ∧
      s'.hard = { s.hard with commit := Rust.max s.hard.commit snap.last.index } ∧
      ret s' = (if idAt s snap.last.index.val = some snap.last
        then (ret s).drop (snap.last.index.val - s.base.index.val) else []) ∧ Layout s' := by
  have hlr := len_eq s hl
  simp only [Rust.usizeBits_eq] at hcap
  by_cases hm : idAt s snap.last.index.val = some snap.last
  · obtain ⟨h1, h2⟩ := idAt_some s hl hc _ hm
    have hid : (State.id_at s snap.last.index == some snap.last) = true := by
      rw [id_at_eq s hl]; simp [hm]
    have hk : (snap.last.index.val - s.base.index.val) ≤ s.len.val := by omega
    have hL := hl.1
    unfold State.install
    simp (disch := first | omega | (simp [Rust.val_usizeOf _ hcap]; omega)) [hid, Rust.Slice.mapRangeM_pure, Rust.cast, Nat.mod_eq_of_lt]
    refine ⟨_, rfl, rfl, rfl, ?_⟩
    rw [if_pos hm]
    refine And.symm (layout_of _ _ (by simp; omega) (by simp; omega) ?_)
    apply List.ext_getElem
    · simp; omega
    · intro i hi1 hi2
      simp only [Vector.getElem_toList, Vector.getElem_ofFn, Rust.Slice.setRange]
      have hsz : (s.entries.toArray.extract (snap.last.index.val - s.base.index.val) s.len.val ++
          s.entries.toArray.extract 0 (snap.last.index.val - s.base.index.val)).size = s.len.val := by
        simp; omega
      by_cases hi : i < s.len.val - (snap.last.index.val - s.base.index.val)
      · rw [if_neg (by omega), dif_pos (by simp; omega)]
        rw [List.getElem_append_left (by simp; omega)]
        simp only [Fin.val_zero, Nat.sub_zero, List.getElem_map, List.getElem_drop]
        rw [Array.getElem_append_left (by simp; omega)]
        simp only [Array.getElem_extract, Vector.getElem_toArray]
        rw [entry_get s hl _ (by omega), dif_pos (by omega)]
      · rw [if_pos (by omega), List.getElem_append_right (by simp; omega)]
        simp
  · have hid : (State.id_at s snap.last.index == some snap.last) = false := by
      rw [id_at_eq s hl]; simp [hm]
    have hL := hl.1
    unfold State.install
    simp (disch := first | omega | (simp [Rust.val_usizeOf _ hcap]; omega)) [hid, Rust.Slice.mapRangeM_pure, Rust.cast, Nat.mod_eq_of_lt]
    refine ⟨_, rfl, rfl, rfl, ?_⟩
    rw [if_neg hm]
    refine And.symm (layout_of _ _ rfl (by simp) ?_)
    apply List.ext_getElem
    · simp
    · intro i hi1 hi2
      simp only [Vector.getElem_toList, Vector.getElem_ofFn]
      by_cases hi : i < s.len.val
      · simp [hi]
      · simp only [hi, if_false]
        rw [entry_get s hl _ (by simpa using hi1), dif_neg (by omega)]; simp

/-- Appending the next contiguous entry keeps the log contiguous. -/
theorem contig_push (s s' : State V S CAP) (e : Entry V) (hc : Contig s) (hb : s'.base = s.base)
    (hr : ret s' = ret s ++ [e]) (he : e.id.index.val = s.base.index.val + (ret s).length + 1) : Contig s' := by
  intro k hk
  rw [hb]
  have hk' : k < (ret s ++ [e]).length := by rw [← hr]; exact hk
  have : (ret s')[k] = (ret s ++ [e])[k]'hk' := List.getElem_of_eq hr _
  rw [this]
  by_cases h : k < (ret s).length
  · rw [List.getElem_append_left h]; exact hc k h
  · have : k = (ret s).length := by simp at hk'; omega
    subst this
    simp [he]

end Jarl.Engine
