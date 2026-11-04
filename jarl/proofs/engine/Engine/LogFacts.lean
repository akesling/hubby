import Engine.Invariant

/-!
# Full logs of checkpoints

How `fullLog` changes when a checkpoint appends, replaces a suffix or installs
a snapshot, and how it relates to `idAt`, `State.get` and `lastId`.
-/

namespace Jarl.Engine
open Jarl

variable {V S : Type} {N CAP : Nat}

/-- The boundary prefix of a checkpoint's full log. -/
def boundary (G : Ghost V N) (s : State V S CAP) : List (Entry V) :=
  if s.base.index.val = 0 then [] else G.prefix s.base.term.val s.base.index.val

theorem fullLog_def (G : Ghost V N) (s : State V S CAP) : fullLog G s = boundary G s ++ ret s := rfl

theorem boundary_len (G : Ghost V N) (s : State V S CAP) (h : StateOk G s) :
    (boundary G s).length = s.base.index.val := by
  unfold boundary
  split
  · simp_all
  · obtain ⟨L, hL, hle, -⟩ := h.base (by omega)
    simp [Ghost.prefix, hL]; omega

theorem fullLog_length (G : Ghost V N) (s : State V S CAP) (h : StateOk G s) :
    (fullLog G s).length = (lastId s).index.val := by
  rw [fullLog_def, List.length_append, boundary_len G s h, lastId_eq s h.contig]

/-- Same boundary and retained entries, same full log. -/
theorem fullLog_congr (G : Ghost V N) (s s' : State V S CAP) (hb : s'.base = s.base) (hr : ret s' = ret s) :
    fullLog G s' = fullLog G s := by
  simp [fullLog_def, boundary, hb, hr]

theorem base_of_snapshot (s s' : State V S CAP) (h : s'.snapshot = s.snapshot) : s'.base = s.base := by
  simp [State.base, h]

theorem base_some (s : State V S CAP) (snap : Snapshot S) (h : s.snapshot = some snap) : s.base = snap.last := by
  simp [State.base, h]

theorem base_zero (G : Ghost V N) (s : State V S CAP) (h : StateOk G s) (h0 : s.base.index.val = 0) :
    s.base = LogId.default := by
  cases hs : s.snapshot with
  | none => simp [State.base, hs]
  | some snap =>
    have := h.snapshot (by simp [hs]); omega

/-- The boundary's last entry is the boundary identity. -/
theorem boundary_last (G : Ghost V N) (s : State V S CAP) (h : StateOk G s) (hpos : 0 < s.base.index.val) :
    ∃ hl : s.base.index.val - 1 < (boundary G s).length, ((boundary G s)[s.base.index.val - 1]).id = s.base := by
  have hb := boundary_len G s h
  refine ⟨by omega, ?_⟩
  obtain ⟨L, hL, hle, hl, hid⟩ := h.base hpos
  have : boundary G s = L.take s.base.index.val := by
    simp [boundary, Ghost.prefix, hL, show s.base.index.val ≠ 0 by omega]
  simp only [this, List.getElem_take]
  exact hid

theorem fullLog_getElem_ret (G : Ghost V N) (s : State V S CAP) (h : StateOk G s) (i : Nat)
    (hlo : s.base.index.val ≤ i) (hl : i < (fullLog G s).length) :
    ∃ hr : i - s.base.index.val < (ret s).length, (fullLog G s)[i] = (ret s)[i - s.base.index.val] := by
  have hb := boundary_len G s h
  have hfl := fullLog_def G s
  generalize hB : boundary G s = B at hb hfl
  have hl' := hl
  simp only [hfl, List.length_append] at hl'
  refine ⟨by omega, ?_⟩
  simp only [hfl]
  rw [List.getElem_append_right (by omega)]
  simp only [hb]

/-- Appending to the retained entries appends to the full log. -/
theorem fullLog_append (G : Ghost V N) (s s' : State V S CAP) (l : List (Entry V))
    (hb : s'.snapshot = s.snapshot) (hr : ret s' = ret s ++ l) : fullLog G s' = fullLog G s ++ l := by
  simp [fullLog_def, boundary, base_of_snapshot s s' hb, hr]

/-- The entry at index `i` (`1 ≤ i ≤ last`) of a full log. -/
theorem fullLog_get (G : Ghost V N) (s : State V S CAP) (h : StateOk G s) (i : Nat)
    (hlo : s.base.index.val < i) (hhi : i ≤ (lastId s).index.val) :
    ∃ hl : i - 1 < (fullLog G s).length, State.get s ⟨i % 2 ^ 64, Nat.mod_lt _ (by decide)⟩ =
      some (fullLog G s)[i - 1] := by
  have hlen := fullLog_length G s h
  have hlast := lastId_eq s h.contig
  have hlt : i < 2 ^ 64 := Nat.lt_of_le_of_lt hhi (lastId s).index.isLt
  have hl : i - 1 < (fullLog G s).length := by omega
  refine ⟨hl, ?_⟩
  obtain ⟨hr, he⟩ := fullLog_getElem_ret G s h (i - 1) (by omega) hl
  rw [he, get_eq s h.layout]
  simp only [Nat.mod_eq_of_lt hlt, if_pos hlo]
  rw [List.getElem?_eq_getElem (by omega)]
  congr 2; omega

/-- `idAt` reads identities of the full log, and the boundary itself. -/
theorem idAt_fullLog (G : Ghost V N) (s : State V S CAP) (h : StateOk G s)
    (i : Nat) (hi : 0 < i) (id : LogId) :
    idAt s i = some id ↔ s.base.index.val ≤ i ∧ ∃ hl : i - 1 < (fullLog G s).length, ((fullLog G s)[i - 1]).id = id := by
  have hlen := fullLog_length G s h
  have hlast := lastId_eq s h.contig
  unfold idAt
  by_cases he : i = s.base.index.val
  · subst he
    obtain ⟨hl, hid⟩ := boundary_last G s h hi
    have hb := boundary_len G s h
    have hl' : s.base.index.val - 1 < (fullLog G s).length := by omega
    have : (fullLog G s)[s.base.index.val - 1] = (boundary G s)[s.base.index.val - 1] := by
      simp only [fullLog_def]; rw [List.getElem_append_left]
    rw [if_pos rfl]
    simp only [Option.some.injEq]
    constructor
    · rintro rfl; exact ⟨Nat.le_refl _, hl', by rw [this, hid]⟩
    · rintro ⟨-, _, h2⟩; rw [← h2, this, hid]
  · rw [if_neg he]
    by_cases hlt : s.base.index.val < i
    · rw [if_pos hlt]
      constructor
      · intro hs
        simp only [Option.map_eq_some_iff] at hs
        obtain ⟨e, he1, rfl⟩ := hs
        obtain ⟨hk, rfl⟩ := List.getElem?_eq_some_iff.mp he1
        have hl : i - 1 < (fullLog G s).length := by omega
        obtain ⟨hr, hg⟩ := fullLog_getElem_ret G s h (i - 1) (by omega) hl
        refine ⟨by omega, hl, ?_⟩
        have hx : i - 1 - s.base.index.val = i - s.base.index.val - 1 := by omega
        simp only [hg, hx]
      · rintro ⟨-, hl, rfl⟩
        obtain ⟨hr, hg⟩ := fullLog_getElem_ret G s h (i - 1) (by omega) hl
        have hx : i - 1 - s.base.index.val = i - s.base.index.val - 1 := by omega
        rw [List.getElem?_eq_getElem (by omega), hg]
        simp only [Option.map_some, hx]
    · rw [if_neg hlt]; simp; omega

theorem lastOf_fullLog (G : Ghost V N) (s : State V S CAP) (h : StateOk G s) :
    lastOf (fullLog G s) = lastId s := by
  have hb := boundary_len G s h
  unfold lastOf lastId
  rw [fullLog_def]
  cases hr : (ret s).getLast? with
  | some e =>
    rw [List.getLast?_append, hr]; rfl
  | none =>
    have hr' : ret s = [] := List.getLast?_eq_none_iff.mp hr
    rw [hr', List.append_nil]
    simp only [Option.map_none, Option.getD_none]
    by_cases h0 : s.base.index.val = 0
    · have : boundary G s = [] := List.eq_nil_of_length_eq_zero (by omega)
      rw [this, base_zero G s h h0]; rfl
    · obtain ⟨hl, hid⟩ := boundary_last G s h (by omega)
      have hne : boundary G s ≠ [] := by intro e; rw [e] at hb; simp at hb; omega
      rw [List.getLast?_eq_getElem?, List.getElem?_eq_getElem (by omega)]
      simp only [hb, Option.map_some, Option.getD_some]
      exact hid

theorem idAt_zero (G : Ghost V N) (s : State V S CAP) (h : StateOk G s) (id : LogId) :
    idAt s 0 = some id ↔ s.base.index.val = 0 ∧ id = LogId.default := by
  unfold idAt
  by_cases h0 : s.base.index.val = 0
  · rw [if_pos h0.symm, base_zero G s h h0]
    constructor
    · rintro ⟨⟩; exact ⟨rfl, rfl⟩
    · rintro ⟨-, rfl⟩; rfl
  · rw [if_neg (Ne.symm h0), if_neg (by omega)]
    simp [h0]

/-- Two prefixes of a consistent log's leader logs: the prefix through an entry of
    a consistent log is that entry's term's leader prefix. -/
theorem consistent_take_prefix (G : Ghost V N) (l : List (Entry V)) (hc : Consistent G l) (i : Nat)
    (hi : 0 < i) (hl : i - 1 < l.length) : l.take i = G.prefix (l[i - 1]).id.term.val i := by
  obtain ⟨-, L, hL, hp⟩ := hc (i - 1) hl
  rw [show i - 1 + 1 = i by omega] at hp
  have hlen : (l.take i).length = i := by simp; omega
  simp only [Ghost.prefix, hL, Option.getD_some]
  rw [List.prefix_iff_eq_take] at hp
  rw [hp, hlen]

/-- `append` replacing the suffix from the entry's index (see `Replaced`). -/
theorem fullLog_replaced (G : Ghost V N) (s s' : State V S CAP) (e : Entry V) (h : StateOk G s)
    (hlo : s.base.index.val < e.id.index.val) (_hhi : e.id.index.val ≤ (lastId s).index.val + 1)
    (hr : ret s' = (ret s).take (e.id.index.val - s.base.index.val - 1) ++ [e]) (hs : s'.snapshot = s.snapshot) :
    fullLog G s' = (fullLog G s).take (e.id.index.val - 1) ++ [e] := by
  have hb := base_of_snapshot s s' hs
  have hbl := boundary_len G s h
  have hfl' : fullLog G s' = boundary G s ++ ret s' := by
    rw [fullLog_def]; simp [boundary, hb]
  have hfl := fullLog_def G s
  rw [hfl', hfl, hr]
  generalize hB : boundary G s = B at hbl ⊢
  rw [List.take_append, List.take_of_length_le (l := B) (by omega), List.append_assoc, hbl]
  congr 3; omega

/-- Installing a snapshot whose boundary is in the log keeps the full log. -/
theorem fullLog_install_keep (G : Ghost V N) (s s' : State V S CAP) (snap : Snapshot S) (h : StateOk G s)
    (hc : Consistent G (fullLog G s)) (hm : idAt s snap.last.index.val = some snap.last) (hpos : 0 < snap.last.index.val)
    (hr : ret s' = (ret s).drop (snap.last.index.val - s.base.index.val)) (hs : s'.snapshot = some snap) :
    fullLog G s' = fullLog G s := by
  have hb := base_some s' snap hs
  obtain ⟨hle, hl, hid⟩ := (idAt_fullLog G s h _ hpos snap.last).mp hm
  have ht := consistent_take_prefix G _ hc _ hpos hl
  rw [hid] at ht
  have hbl := boundary_len G s h
  have hfl' : fullLog G s' = G.prefix snap.last.term.val snap.last.index.val ++ ret s' := by
    rw [fullLog_def]; simp [boundary, hb, show snap.last.index.val ≠ 0 by omega]
  rw [hfl', ← ht, hr]
  conv => rhs; rw [← List.take_append_drop snap.last.index.val (fullLog G s)]
  congr 1
  have hfl := fullLog_def G s
  rw [hfl]
  generalize hB : boundary G s = B at hbl ⊢
  rw [List.drop_append, List.drop_of_length_le (l := B) (by omega), List.nil_append, hbl]

/-- Installing a snapshot outside the log replaces it by the boundary's prefix. -/
theorem fullLog_install_reset (G : Ghost V N) (s' : State V S CAP) (snap : Snapshot S)
    (hr : ret s' = []) (hs : s'.snapshot = some snap) (hpos : 0 < snap.last.index.val) :
    fullLog G s' = G.prefix snap.last.term.val snap.last.index.val := by
  have hb := base_some s' snap hs
  rw [fullLog_def, hr, List.append_nil]
  simp [boundary, hb, show snap.last.index.val ≠ 0 by omega]

/-! ## Extending the ghost history -/

theorem fullLog_extends {G G' : Ghost V N} (e : Extends G G') (s : State V S CAP) (h : StateOk G s) :
    fullLog G' s = fullLog G s := by
  rw [fullLog_def, fullLog_def]
  congr 1
  unfold boundary
  split
  · rfl
  · obtain ⟨L, hL, hle, -⟩ := h.base (by omega)
    exact prefix_extends e _ _ L hL hle

theorem consistent_extends {G G' : Ghost V N} (e : Extends G G') (l : List (Entry V)) (h : Consistent G l) :
    Consistent G' l := by
  intro k hk
  obtain ⟨h1, L, hL, hp⟩ := h k hk
  obtain ⟨L', hL', hp'⟩ := e.leader _ L hL
  exact ⟨h1, L', hL', hp.trans hp'⟩

theorem stateOk_extends {G G' : Ghost V N} (e : Extends G G') (s : State V S CAP) (h : StateOk G s) :
    StateOk G' s := by
  have hf := fullLog_extends e s h
  refine ⟨h.layout, h.contig, ?_, h.snapshot, ?_, h.commit_ge, h.commit_le, h.unvoted⟩
  · intro hpos
    obtain ⟨L, hL, hle, hl, hid⟩ := h.base hpos
    obtain ⟨L', hL', hp⟩ := e.leader _ L hL
    refine ⟨L', hL', Nat.le_trans hle hp.length_le, by have := hp.length_le; omega, ?_⟩
    rw [← List.IsPrefix.getElem hp hl]; exact hid
  · rw [hf]; exact h.terms

theorem kept_extends {G G' : Ghost V N} (e : Extends G G') (w : Fin N) (t j b : Nat) (l : List (Entry V))
    (hk : Kept G w t j b l) (ha : AckOk G t j) : Kept G' w t j b l := by
  obtain ⟨L, hL, hj⟩ := ha
  have hpe := prefix_extends e t j L hL hj
  unfold Kept at *
  rw [hpe]
  rcases hk with hk | ⟨t', h1, h2, c, eL, hel, hc, hn⟩
  · exact Or.inl hk
  · exact Or.inr ⟨t', h1, h2, c, eL, e.elect _ _ hel, hc, hn⟩

theorem kept_mono_bound (G : Ghost V N) (w : Fin N) (t j b b' : Nat) (l : List (Entry V)) (hb : b ≤ b')
    (hk : Kept G w t j b l) : Kept G w t j b' l := by
  rcases hk with hk | ⟨t', h1, h2, hl⟩
  · exact Or.inl hk
  · exact Or.inr ⟨t', h1, by omega, hl⟩

theorem kept_of_prefix (G : Ghost V N) (w : Fin N) (t j b : Nat) (l l' : List (Entry V)) (hp : l <+: l')
    (hk : Kept G w t j b l) : Kept G w t j b l' := by
  rcases hk with hk | hk
  · exact Or.inl (hk.trans hp)
  · exact Or.inr hk

end Jarl.Engine
