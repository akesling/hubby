import Engine.Log

/-!
# Ghost history and log consistency

The proof keeps erasable history that never constrains execution:

* `leader t`: the log of term `t`'s leader, as last made durable while it led;
* `elect t`: that leader and its log when it was elected;
* `acks`: every success acknowledgment a node sent (node, term, index);
* `ballots`: every vote granted (term, voter, candidate, voter's log).

A log is consistent when each of its entries, together with everything before
it, is a prefix of the leader log of that entry's term. Log matching follows.
-/

namespace Jarl.Engine
open Jarl

variable {V : Type}

/-- Log identities compared lexicographically by (term, index), as in `step`. -/
def upToDate (a b : LogId) : Prop :=
  b.term.val < a.term.val ∨ (b.term.val = a.term.val ∧ b.index.val ≤ a.index.val)

instance (a b : LogId) : Decidable (upToDate a b) := by unfold upToDate; infer_instance

/-- The last identity of a full log (genesis when empty). -/
def lastOf (l : List (Entry V)) : LogId := (l.getLast?.map (·.id)).getD LogId.default

structure Ghost (V : Type) (N : Nat) where
  leader : Nat → Option (List (Entry V))
  elect : Nat → Option (Fin N × List (Entry V))
  acks : List (Fin N × Nat × Nat)
  ballots : List (Nat × Fin N × Fin N × List (Entry V))

variable {N : Nat}

/-- The prefix of the log of term `t`'s leader with `i` entries. -/
def Ghost.prefix (G : Ghost V N) (t i : Nat) : List (Entry V) := ((G.leader t).getD []).take i

/-- The full log of a checkpoint: the leader prefix ending at its boundary, then its entries. -/
def fullLog {S : Type} {CAP : Nat} (G : Ghost V N) (s : State V S CAP) : List (Entry V) :=
  (if s.base.index.val = 0 then [] else G.prefix s.base.term.val s.base.index.val) ++ ret s

/-- Every entry, with all before it, is a prefix of its term's leader log. -/
def Consistent (G : Ghost V N) (l : List (Entry V)) : Prop :=
  ∀ k (hk : k < l.length), l[k].id.index.val = k + 1 ∧
    ∃ L, G.leader l[k].id.term.val = some L ∧ l.take (k + 1) <+: L

theorem consistent_take (G : Ghost V N) (l : List (Entry V)) (h : Consistent G l) (n : Nat) :
    Consistent G (l.take n) := by
  intro k hk
  simp only [List.length_take] at hk
  have hk' : k < l.length := by omega
  obtain ⟨h1, L, h2, h3⟩ := h k hk'
  refine ⟨by simpa using h1, L, by simpa using h2, ?_⟩
  rw [List.take_take, show min (k + 1) n = k + 1 by omega]
  exact h3

/-- Log matching: consistent logs agreeing on an entry agree on everything before it. -/
theorem log_matching (G : Ghost V N) (a b : List (Entry V)) (ha : Consistent G a) (hb : Consistent G b)
    (k : Nat) (hka : k < a.length) (hkb : k < b.length) (he : a[k].id = b[k].id) :
    a.take (k + 1) = b.take (k + 1) := by
  obtain ⟨-, La, hLa, pa⟩ := ha k hka
  obtain ⟨-, Lb, hLb, pb⟩ := hb k hkb
  rw [he] at hLa
  rw [hLa] at hLb
  cases hLb
  have la : (a.take (k + 1)).length = k + 1 := by simp; omega
  have lb : (b.take (k + 1)).length = k + 1 := by simp; omega
  obtain ⟨ra, hra⟩ := pa
  obtain ⟨rb, hrb⟩ := pb
  have := congrArg (List.take (k + 1)) (hra.trans hrb.symm)
  simpa [List.take_append_of_le_length, la, lb] using this

/-! ## Majorities -/

/-- A strict majority of the `N` node slots satisfies `P`. -/
noncomputable def Majority (N : Nat) (P : Fin N → Prop) : Prop :=
  N / 2 < (List.finRange N).countP (fun w => @decide (P w) (Classical.propDecidable _))

theorem countP_disjoint {α : Type} (l : List α) (p q : α → Bool) (h : ∀ x ∈ l, ¬ (p x = true ∧ q x = true)) :
    l.countP p + l.countP q ≤ l.length := by
  induction l with
  | nil => simp
  | cons x xs ih =>
    have ih' := ih (fun y hy => h y (by simp [hy]))
    have hx := h x (by simp)
    simp only [List.countP_cons, List.length_cons]
    cases hp : p x <;> cases hq : q x <;> simp_all <;> omega

theorem majority_inter (P Q : Fin N → Prop) (hp : Majority N P) (hq : Majority N Q) : ∃ w, P w ∧ Q w := by
  apply Classical.byContradiction
  intro h
  have hd : ∀ x ∈ List.finRange N, ¬ (@decide (P x) (Classical.propDecidable _) = true ∧
      @decide (Q x) (Classical.propDecidable _) = true) := by
    intro x _ ⟨a, b⟩; exact h ⟨x, by simpa using a, by simpa using b⟩
  have := countP_disjoint (List.finRange N) _ _ hd
  simp only [List.length_finRange] at this
  unfold Majority at hp hq
  omega

/-! ## Leader completeness -/

/-- The leader of term `t'`, a node other than `w`, was elected without the prefix `p`. -/
def Lacks (G : Ghost V N) (w : Fin N) (t' : Nat) (p : List (Entry V)) : Prop :=
  ∃ c eL, G.elect t' = some (c, eL) ∧ c ≠ w ∧ ¬ p <+: eL

/-- A prefix of term `t` that node `w` acknowledged is still in `l`, or a leader
    of a term in `(t, bound)` other than `w` was elected without it. -/
def Kept (G : Ghost V N) (w : Fin N) (t j bound : Nat) (l : List (Entry V)) : Prop :=
  G.prefix t j <+: l ∨ ∃ t', t < t' ∧ t' < bound ∧ Lacks G w t' (G.prefix t j)

/-- Structural facts about the ghost history. -/
structure Wf (G : Ghost V N) : Prop where
  leader : ∀ t L, G.leader t = some L → Consistent G L ∧ (∀ e ∈ L, 0 < e.id.term.val ∧ e.id.term.val ≤ t) ∧
    ∃ c eL, G.elect t = some (c, eL) ∧ eL <+: L ∧
      ∀ k (hk : k < L.length), eL.length ≤ k → L[k].id.term.val = t
  elect : ∀ T c eL, G.elect T = some (c, eL) → 0 < T ∧ Consistent G eL ∧ (∀ e ∈ eL, e.id.term.val < T) ∧
    Majority N (fun w => ∃ vlog, (T, w, c, vlog) ∈ G.ballots ∧ upToDate (lastOf eL) (lastOf vlog))
  ballot : ∀ T w c vlog, (T, w, c, vlog) ∈ G.ballots → Consistent G vlog ∧
    ∀ t j', (w, t, j') ∈ G.acks → t < T → ∀ j ≤ j',
      Kept G w t j T vlog ∨ ∃ c' eL', G.elect T = some (c', eL') ∧ c' ≠ c

/-- Entry `j` of term `t`'s leader log was created in `t` and a majority acknowledged it. -/
def CommitQ (G : Ghost V N) (t j : Nat) : Prop :=
  0 < j ∧ ∃ L, G.leader t = some L ∧ ∃ h : j - 1 < L.length, L[j - 1].id.term.val = t ∧
    Majority N (fun w => ∃ j', j ≤ j' ∧ (w, t, j') ∈ G.acks)

theorem lastOf_cons_last (l : List (Entry V)) (hl : l ≠ []) :
    lastOf l = (l.getLast hl).id := by
  simp [lastOf, List.getLast?_eq_some_getLast hl]

/-- A consistent nonempty log is a prefix of the leader log of its last entry's term. -/
theorem consistent_prefix_last (G : Ghost V N) (l : List (Entry V)) (h : Consistent G l) (hl : l ≠ []) :
    ∃ L, G.leader (lastOf l).term.val = some L ∧ l <+: L := by
  have hlen := List.length_pos_iff.mpr hl
  have hk : l.length - 1 < l.length := by omega
  obtain ⟨-, L, hL, hp⟩ := h _ hk
  rw [lastOf_cons_last l hl, List.getLast_eq_getElem]
  refine ⟨L, hL, ?_⟩
  rwa [show l.length - 1 + 1 = l.length by omega, List.take_length] at hp

theorem consistent_length (G : Ghost V N) (l : List (Entry V)) (h : Consistent G l) (hl : l ≠ []) :
    (lastOf l).index.val = l.length := by
  have hlen := List.length_pos_iff.mpr hl
  rw [lastOf_cons_last l hl, List.getLast_eq_getElem]
  have := (h (l.length - 1) (by omega)).1
  omega

/-- Entries of a consistent log have positive terms, at most its last term. -/
theorem consistent_terms (G : Ghost V N) (hw : Wf G) (l : List (Entry V)) (h : Consistent G l) :
    ∀ e ∈ l, 0 < e.id.term.val ∧ e.id.term.val ≤ (lastOf l).term.val := by
  intro e he
  have hl : l ≠ [] := List.ne_nil_of_mem he
  obtain ⟨L, hL, hp⟩ := consistent_prefix_last G l h hl
  exact (hw.leader _ L hL).2.1 e (hp.subset he)

theorem prefix_length (G : Ghost V N) (t j : Nat) (L : List (Entry V)) (hL : G.leader t = some L)
    (hj : j ≤ L.length) : (G.prefix t j).length = j := by
  simp [Ghost.prefix, hL]; omega

theorem prefix_le (G : Ghost V N) (t j : Nat) (L : List (Entry V)) (hL : G.leader t = some L) :
    G.prefix t j <+: L := by
  simp [Ghost.prefix, hL, List.take_prefix]

/-- Leader completeness: a prefix committed in term `t` is in the election log of
    every later term's leader. -/
theorem leader_complete (G : Ghost V N) (hw : Wf G) (t j : Nat) (hc : CommitQ G t j) :
    ∀ T c eL, G.elect T = some (c, eL) → t < T → G.prefix t j <+: eL := by
  obtain ⟨hj0, L, hL, hjL, hterm, hmaj⟩ := hc
  intro T
  induction T using Nat.strongRecOn with
  | _ T ih =>
  intro c eL he htT
  obtain ⟨-, heL, hlt, hvotes⟩ := hw.elect T c eL he
  obtain ⟨w, ⟨vlog, hb, hup⟩, ⟨j', hjj', hack⟩⟩ := majority_inter _ _ hvotes hmaj
  obtain ⟨hvlog, hkept⟩ := hw.ballot T w c vlog hb
  -- The voter kept the acknowledged prefix: no leader in between lacked it.
  have hp : G.prefix t j <+: vlog := by
    rcases hkept t j' hack htT j hjj' with (hp | ⟨t', h1, h2, c', eL', he', -, hn⟩) | ⟨c', eL', he', hne⟩
    · exact hp
    · exact absurd (ih t' h2 c' eL' he' h1) hn
    · rw [he] at he'; cases he'; exact absurd rfl hne
  have hplen : (G.prefix t j).length = j := prefix_length G t j L hL (by omega)
  have hvne : vlog ≠ [] := by
    intro e; rw [e] at hp; have := hp.length_le; simp only [List.length_nil] at this; omega
  -- The voter's last term is at least `t`.
  have hlastp : (G.prefix t j)[j - 1]'(by omega) = L[j - 1] := by
    simp [Ghost.prefix, hL]
  have hvt : t ≤ (lastOf vlog).term.val := by
    have hmem : (G.prefix t j)[j - 1]'(by omega) ∈ vlog := hp.subset (List.getElem_mem _)
    have := (consistent_terms G hw vlog hvlog _ hmem).2
    rw [hlastp, hterm] at this; exact this
  have ht0 : 0 < t := by
    have := ((hw.leader t L hL).2.1 L[j - 1] (List.getElem_mem _)).1; rwa [hterm] at this
  have heLne : eL ≠ [] := by
    intro e
    have : (lastOf eL).term.val = 0 := by rw [e]; rfl
    rcases hup with h | ⟨h1, -⟩ <;> omega
  obtain ⟨Lτ, hLτ, heLp⟩ := consistent_prefix_last G eL heL heLne
  rcases hup with hlt' | ⟨heq, hle⟩
  · -- The candidate's last entry is from a later term τ < T, whose leader had the prefix.
    have hτT : (lastOf eL).term.val < T := by
      have := hlt _ (List.getLast_mem heLne); rwa [← lastOf_cons_last eL heLne] at this
    obtain ⟨-, -, c', eL', he', heL'p, hbeyond⟩ := hw.leader _ Lτ hLτ
    have hih := ih _ hτT c' eL' he' (by omega)
    have hlen : eL'.length ≤ eL.length := by
      apply Classical.byContradiction
      intro hn
      have hk : eL.length - 1 < eL'.length := by have := List.length_pos_iff.mpr heLne; omega
      have h1 : eL'[eL.length - 1] = Lτ[eL.length - 1]'(by have := heL'p.length_le; omega) :=
        List.IsPrefix.getElem heL'p hk
      have h2 : eL[eL.length - 1]'(by have := List.length_pos_iff.mpr heLne; omega) =
          Lτ[eL.length - 1]'(by have := heLp.length_le; have := List.length_pos_iff.mpr heLne; omega) :=
        List.IsPrefix.getElem heLp _
      have h3 : (eL'[eL.length - 1]).id.term.val < (lastOf eL).term.val :=
        (hw.elect _ c' eL' he').2.2.1 _ (List.getElem_mem _)
      rw [h1, ← h2, lastOf_cons_last eL heLne, List.getLast_eq_getElem] at h3
      omega
    exact List.IsPrefix.trans hih (List.prefix_of_prefix_length_le heL'p heLp hlen)
  · -- Equal last terms: both logs are prefixes of that term's leader log.
    obtain ⟨Lv, hLv, hvp⟩ := consistent_prefix_last G vlog hvlog hvne
    rw [heq, hLτ] at hLv
    cases hLv
    have h1 := consistent_length G vlog hvlog hvne
    have h2 := consistent_length G eL heL heLne
    exact List.IsPrefix.trans hp (List.prefix_of_prefix_length_le hvp heLp (by omega))

/-- A log prefix covered by a commitment. -/
def Committed (G : Ghost V N) (p : List (Entry V)) : Prop :=
  p = [] ∨ ∃ t j, CommitQ G t j ∧ p <+: G.prefix t j

theorem commit_prefixes (G : Ghost V N) (hw : Wf G) (t1 j1 t2 j2 : Nat) (h1 : CommitQ G t1 j1)
    (h2 : CommitQ G t2 j2) (hlt : t1 < t2) : ∃ L, G.prefix t1 j1 <+: L ∧ G.prefix t2 j2 <+: L := by
  obtain ⟨-, L2, hL2, -⟩ := h2
  obtain ⟨-, -, c, eL, he, heL, -⟩ := hw.leader t2 L2 hL2
  exact ⟨L2, (leader_complete G hw t1 j1 h1 t2 c eL he hlt).trans heL, prefix_le G t2 j2 L2 hL2⟩

/-- State-machine safety for logs: any two committed prefixes are compatible. -/
theorem committed_compatible (G : Ghost V N) (hw : Wf G) (p q : List (Entry V))
    (hp : Committed G p) (hq : Committed G q) : p <+: q ∨ q <+: p := by
  rcases hp with rfl | ⟨t1, j1, h1, hp⟩
  · exact Or.inl (List.nil_prefix)
  rcases hq with rfl | ⟨t2, j2, h2, hq⟩
  · exact Or.inr (List.nil_prefix)
  have common : ∃ L, G.prefix t1 j1 <+: L ∧ G.prefix t2 j2 <+: L := by
    rcases Nat.lt_trichotomy t1 t2 with hlt | rfl | hgt
    · exact commit_prefixes G hw t1 j1 t2 j2 h1 h2 hlt
    · obtain ⟨-, L, hL, -⟩ := h1
      exact ⟨L, prefix_le G t1 j1 L hL, prefix_le G t1 j2 L hL⟩
    · obtain ⟨L, a, b⟩ := commit_prefixes G hw t2 j2 t1 j1 h2 h1 hgt
      exact ⟨L, b, a⟩
  obtain ⟨L, a, b⟩ := common
  exact List.prefix_or_prefix_of_prefix (hp.trans a) (hq.trans b)

/-! ## Monotonicity -/

/-- `G'` extends `G`: leader logs only grow; elections, acknowledgments and ballots are kept. -/
structure Extends (G G' : Ghost V N) : Prop where
  leader : ∀ t L, G.leader t = some L → ∃ L', G'.leader t = some L' ∧ L <+: L'
  elect : ∀ t x, G.elect t = some x → G'.elect t = some x
  acks : ∀ a, a ∈ G.acks → a ∈ G'.acks
  ballots : ∀ b, b ∈ G.ballots → b ∈ G'.ballots

theorem Extends.refl (G : Ghost V N) : Extends G G :=
  ⟨fun _ L h => ⟨L, h, List.prefix_refl L⟩, fun _ _ h => h, fun _ h => h, fun _ h => h⟩

theorem Extends.trans {G G' G'' : Ghost V N} (a : Extends G G') (b : Extends G' G'') : Extends G G'' := by
  refine ⟨fun t L h => ?_, fun t x h => b.elect t x (a.elect t x h), fun x h => b.acks x (a.acks x h),
    fun x h => b.ballots x (a.ballots x h)⟩
  obtain ⟨L', h', p'⟩ := a.leader t L h
  obtain ⟨L'', h'', p''⟩ := b.leader t L' h'
  exact ⟨L'', h'', p'.trans p''⟩

theorem majority_mono (P Q : Fin N → Prop) (h : ∀ w, P w → Q w) (hp : Majority N P) : Majority N Q := by
  unfold Majority at *
  have : (List.finRange N).countP (fun w => @decide (P w) (Classical.propDecidable _)) ≤
      (List.finRange N).countP (fun w => @decide (Q w) (Classical.propDecidable _)) := by
    apply List.countP_mono_left
    intro w _ hw; simp only [decide_eq_true_eq] at hw ⊢; exact h w hw
  omega

theorem prefix_extends {G G' : Ghost V N} (e : Extends G G') (t j : Nat) (L : List (Entry V))
    (hL : G.leader t = some L) (hj : j ≤ L.length) : G'.prefix t j = G.prefix t j := by
  obtain ⟨L', h', ⟨r, rfl⟩⟩ := e.leader t L hL
  simp [Ghost.prefix, hL, h', List.take_append_of_le_length hj]

theorem commitQ_mono {G G' : Ghost V N} (e : Extends G G') (t j : Nat) (h : CommitQ G t j) : CommitQ G' t j := by
  obtain ⟨hj, L, hL, hl, ht, hm⟩ := h
  obtain ⟨L', h', hp⟩ := e.leader t L hL
  refine ⟨hj, L', h', by have := hp.length_le; omega, ?_, ?_⟩
  · rw [← ht]; exact (List.IsPrefix.getElem hp hl).symm ▸ rfl
  · exact majority_mono _ _ (fun w ⟨j', a, b⟩ => ⟨j', a, e.acks _ b⟩) hm

theorem committed_mono {G G' : Ghost V N} (e : Extends G G') (p : List (Entry V)) (h : Committed G p) :
    Committed G' p := by
  rcases h with rfl | ⟨t, j, hc, hp⟩
  · exact Or.inl rfl
  refine Or.inr ?_
  have hc' := hc
  obtain ⟨hj, L, hL, hl, -, -⟩ := hc'
  exact ⟨t, j, commitQ_mono e t j hc, by rw [prefix_extends e t j L hL (by omega)]; exact hp⟩

end Jarl.Engine
