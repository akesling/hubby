import Engine.Dyn.Ghost

/-!
# Ghost monotonicity and commitment compatibility

Growing the ghost (`Extends`: leader logs extend, elections, acknowledgments and
ballots are kept) keeps every commitment and its witnesses. Two committed
prefixes are compatible (`committed_compatible`). `good_preserve` is the step
that keeps `Wf.good` when new commitments appear: a prefix committed for the
first time sees at most one configuration change after it, since a second
change requires the first to have been committed already.
-/

namespace Jarl.Engine.Dyn
open Jarl Jarl.Engine

variable {V : Type} {MAX K : Nat} {ids : Vector Id K} {g : Membership MAX}

theorem take_of_prefix {α : Type} (L L' : List α) (h : L <+: L') (n : Nat) (hn : n ≤ L.length) :
    L'.take n = L.take n := by
  obtain ⟨r, rfl⟩ := h
  exact List.take_append_of_le_length hn

theorem getElem_of_prefix {α : Type} (L L' : List α) (h : L <+: L') (i : Nat) (hi : i < L.length) :
    L'[i]'(by have := h.length_le; omega) = L[i] :=
  (List.IsPrefix.getElem h hi).symm

theorem commitAt_mono {G G' : Ghost (Record V MAX) K} (e : Extends G G') (t j n : Nat)
    (h : CommitAt ids g G t j n) : CommitAt ids g G' t j n := by
  obtain ⟨hj, hjn, L, hL, hn, ⟨hjL, ht⟩, hq⟩ := h
  obtain ⟨L', h', hp⟩ := e.leader t L hL
  refine ⟨hj, hjn, L', h', by have := hp.length_le; omega, ⟨by have := hp.length_le; omega, ?_⟩, ?_⟩
  · rw [getElem_of_prefix L L' hp _ hjL]; exact ht
  · rw [take_of_prefix L L' hp n hn]
    exact quorum_mono _ _ _ (fun id ⟨w, hw, j', a, b⟩ => ⟨w, hw, j', a, e.acks _ b⟩) hq

theorem commitQ_mono {G G' : Ghost (Record V MAX) K} (e : Extends G G') (t j : Nat)
    (h : CommitQ ids g G t j) : CommitQ ids g G' t j := by
  obtain ⟨n, h⟩ := h; exact ⟨n, commitAt_mono e t j n h⟩

theorem committedBy_mono {G G' : Ghost (Record V MAX) K} (e : Extends G G') (T : Nat) (p : List (Entry (Record V MAX)))
    (h : CommittedBy ids g G T p) : CommittedBy ids g G' T p := by
  rcases h with rfl | ⟨t, j, ht, hc, hp⟩
  · exact Or.inl rfl
  refine Or.inr ⟨t, j, ht, commitQ_mono e t j hc, ?_⟩
  obtain ⟨L, hL, hjL, -⟩ := commitQ_leader G t j hc
  rw [prefix_extends e t j L hL hjL]; exact hp

theorem good_mono {G G' : Ghost (Record V MAX) K} (e : Extends G G') (T : Nat) (p : List (Entry (Record V MAX)))
    (h : Good ids g G T p) : Good ids g G' T p := by
  obtain ⟨t, j, n, L, ht, hc, hL, hp, hn⟩ := h
  obtain ⟨L', hL', hpre⟩ := e.leader t L hL
  have hnL : n ≤ L.length := by obtain ⟨-, -, L2, h2, h3, -⟩ := hc; rw [hL] at h2; cases h2; exact h3
  have hjn : j ≤ n := hc.2.1
  refine ⟨t, j, n, L', ht, commitAt_mono e t j n hc, hL', ?_, ?_⟩
  · rw [take_of_prefix L L' hpre j (by omega)]; exact hp
  · rw [take_of_prefix L L' hpre n hnL]; exact hn

/-- Two committed prefixes are compatible: one extends the other. -/
theorem committed_compatible (hid : ∀ a b : Fin K, ids[a] = ids[b] → a = b) (G : Ghost (Record V MAX) K)
    (hw : Wf ids g G) (T1 T2 : Nat) (p q : List (Entry (Record V MAX)))
    (hp : CommittedBy ids g G T1 p) (hq : CommittedBy ids g G T2 q) : p <+: q ∨ q <+: p := by
  rcases hp with rfl | ⟨t1, j1, -, h1, hp⟩
  · exact Or.inl List.nil_prefix
  rcases hq with rfl | ⟨t2, j2, -, h2, hq⟩
  · exact Or.inr List.nil_prefix
  obtain ⟨L1, hL1, -⟩ := commitQ_leader G t1 j1 h1
  obtain ⟨L2, hL2, -⟩ := commitQ_leader G t2 j2 h2
  have common : ∃ L, G.prefix t1 j1 <+: L ∧ G.prefix t2 j2 <+: L := by
    rcases Nat.lt_trichotomy t1 t2 with hlt | rfl | hgt
    · obtain ⟨-, -, ⟨c, eL, he, heL, -⟩, -⟩ := hw.leader t2 L2 hL2
      exact ⟨L2, (leader_complete hid G hw t2 c eL he t1 j1 hlt h1).trans heL,
        by rw [prefix_eq_take G t2 j2 L2 hL2]; exact List.take_prefix _ _⟩
    · exact ⟨L1, by rw [prefix_eq_take G t1 j1 L1 hL1]; exact List.take_prefix _ _,
        by rw [prefix_eq_take G t1 j2 L1 hL1]; exact List.take_prefix _ _⟩
    · obtain ⟨-, -, ⟨c, eL, he, heL, -⟩, -⟩ := hw.leader t1 L1 hL1
      exact ⟨L1, by rw [prefix_eq_take G t1 j1 L1 hL1]; exact List.take_prefix _ _,
        (leader_complete hid G hw t1 c eL he t2 j2 hgt h2).trans heL⟩
  obtain ⟨L, a, b⟩ := common
  exact List.prefix_or_prefix_of_prefix (hp.trans a) (hq.trans b)

/-- Configuration records of a log, each a step from the configuration before it,
    where a record is followed by another only once committed in `G`. -/
def ChainIn (G : Ghost (Record V MAX) K) (L : List (Entry (Record V MAX))) : Prop :=
  (∀ i (hi : i < L.length) X, recCfg L[i].value = some X → Step (cfgOf g (L.take i)) X) ∧
  ∀ k i (hk : k < i) (hi : i < L.length), isCfg L[k] → isCfg L[i] →
    CommittedBy ids g G L[i].id.term.val (L.take (k + 1))

/-- `Wf.good` survives a ghost extension whose leader logs satisfy the
    configuration chain with commitment judged before the extension. -/
theorem good_preserve {G G' : Ghost (Record V MAX) K} (e : Extends G G')
    (hgood : ∀ T p, CommittedBy ids g G T p → p ≠ [] → Good ids g G T p)
    (hchain : ∀ t L', G'.leader t = some L' → ChainIn (ids := ids) (g := g) G L')
    (hterms : ∀ t L', G'.leader t = some L' → ∀ e ∈ L', e.id.term.val ≤ t) :
    ∀ T p, CommittedBy ids g G' T p → p ≠ [] → Good ids g G' T p := by
  intro T p hp hne
  by_cases hold : CommittedBy ids g G T p
  · exact good_mono e T p (hgood T p hold hne)
  rcases hp with rfl | ⟨t, j, ht, ⟨n, hc⟩, hpre⟩
  · exact absurd rfl hne
  have hc' := hc
  obtain ⟨hj, hjn, L', hL', hn, -, -⟩ := hc'
  have hPeq : G'.prefix t j = L'.take j := prefix_eq_take G' t j L' hL'
  rw [hPeq] at hpre
  refine ⟨t, j, n, L', ht, hc, hL', hpre, ?_⟩
  have hpl : p.length ≤ j := by have := hpre.length_le; simp at this; omega
  obtain ⟨l, hl⟩ : ∃ l, p.length = l := ⟨_, rfl⟩
  have hpeq : p = L'.take l := by
    rw [List.prefix_iff_eq_take] at hpre
    rw [hpre, List.take_take, hl, Nat.min_eq_left (by omega)]
  subst hpeq
  have hlL : l ≤ L'.length := by simp at hl; omega
  have hlj : l ≤ j := by simp at hpl; omega
  have hdl : (L'.take l).dropLast = (L'.take n).take (l - 1) := by
    rw [List.dropLast_eq_take, List.take_take, List.take_take, hl, Nat.min_eq_left (by omega), Nat.min_eq_left (by omega)]
  rw [hdl]
  obtain ⟨hstep, hch⟩ := hchain t L' hL'
  apply near_tail (L'.take n) (l - 1)
  · intro i hi X hX
    simp only [List.length_take] at hi
    have hiL : i < L'.length := by omega
    have := hstep i hiL X (by simpa using hX)
    rw [List.take_take, Nat.min_eq_left (by omega)]; exact this
  · intro k1 k2 hk2 h1 h12 hc1 hc2
    simp only [List.length_take] at hk2
    have hk2L : k2 < L'.length := by omega
    have hcb := hch k1 k2 h12 hk2L (by simpa using hc1) (by simpa using hc2)
    apply hold
    apply committedBy_prefix G T (L'.take l) (L'.take (k1 + 1))
    · rw [show L'.take l = (L'.take (k1 + 1)).take l by rw [List.take_take, Nat.min_eq_left (by omega)]]
      exact List.take_prefix _ _
    · exact committedBy_mono_term G _ T (by have := hterms t L' hL' _ (List.getElem_mem hk2L); omega) _ hcb

end Jarl.Engine.Dyn
