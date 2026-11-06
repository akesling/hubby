import Engine.Dyn.Config

/-!
# Leader completeness under configuration changes

The ghost history is the fixed engine's (`Ghost`: leader logs, elections,
acknowledgments, ballots), over `K` nodes with distinct identities `ids`.
What changes is which sets count:

* an election in term `T` needs a quorum of the candidate's own configuration
  (`cfgOf g eL`) to have voted for it;
* a commitment of `j` entries in term `t` (`CommitAt t j n`) needs a quorum of
  the configuration of the first `n ≥ j` entries of the leader's log, the
  leader's configuration at the time, to have acknowledged them.

`Wf` adds two facts about configurations in leader logs (`Chain`): each
configuration record is one `Step` from the configuration before it, and a
configuration record is only followed by another once it is committed. From
these, every committed prefix has a witness commitment whose configuration is
near the prefix's own (`Wf.good`): the first commitment covering a position
happens before a second configuration change after it can be appended.

`leader_complete` then proves that every elected leader's log contains every
earlier commitment. Where the candidate's log diverges from a committed log, both
the candidate's configuration and the witness commitment's configuration are
near the configuration at the divergence point, so a voter acknowledged the
committed entry (`near_inter`), and the candidate's log cannot be at least as
up to date as that voter's.
-/

namespace Jarl.Engine.Dyn
open Jarl Jarl.Engine

variable {V : Type} {MAX K : Nat}

/-- Identity `id` is a node that acknowledged at least `j` entries of term `t`. -/
def Ackers (ids : Vector Id K) (G : Ghost (Record V MAX) K) (t j : Nat) (id : Id) : Prop :=
  ∃ w : Fin K, ids[w] = id ∧ ∃ j', j ≤ j' ∧ (w, t, j') ∈ G.acks

/-- Identity `id` is a node that voted for `c` in term `T` with a log `eL` is at least as up to date as. -/
def Voters (ids : Vector Id K) (G : Ghost (Record V MAX) K) (T : Nat) (c : Fin K)
    (eL : List (Entry (Record V MAX))) (id : Id) : Prop :=
  ∃ w : Fin K, ids[w] = id ∧ ∃ vlog, (T, w, c, vlog) ∈ G.ballots ∧ upToDate (lastOf eL) (lastOf vlog)

variable (ids : Vector Id K) (g : Membership MAX)

/-- Entry `j` of term `t`'s leader log was created in `t`, and a quorum of the
    configuration of that log's first `n ≥ j` entries acknowledged it. -/
def CommitAt (G : Ghost (Record V MAX) K) (t j n : Nat) : Prop :=
  0 < j ∧ j ≤ n ∧ ∃ L, G.leader t = some L ∧ n ≤ L.length ∧ (∃ h : j - 1 < L.length, L[j - 1].id.term.val = t) ∧
    Quorum (cfgOf g (L.take n)) (Ackers ids G t j)

def CommitQ (G : Ghost (Record V MAX) K) (t j : Nat) : Prop := ∃ n, CommitAt ids g G t j n

/-- A log prefix covered by a commitment of a term at most `T`. -/
def CommittedBy (G : Ghost (Record V MAX) K) (T : Nat) (p : List (Entry (Record V MAX))) : Prop :=
  p = [] ∨ ∃ t j, t ≤ T ∧ CommitQ ids g G t j ∧ p <+: G.prefix t j

/-- A commitment of a term at most `T` covering `p` whose configuration is near
    the configuration before `p`'s last entry. -/
def Good (G : Ghost (Record V MAX) K) (T : Nat) (p : List (Entry (Record V MAX))) : Prop :=
  ∃ t j n L, t ≤ T ∧ CommitAt ids g G t j n ∧ G.leader t = some L ∧ p <+: L.take j ∧
    Near (cfgOf g p.dropLast) (cfgOf g (L.take n))

/-- Configuration facts of a log: each record is a step from the configuration
    before it, and a record followed by another is committed by the later one's term. -/
def Chain (G : Ghost (Record V MAX) K) (L : List (Entry (Record V MAX))) : Prop :=
  (∀ i (hi : i < L.length) X, recCfg L[i].value = some X → Step (cfgOf g (L.take i)) X) ∧
  ∀ k i (hk : k < i) (hi : i < L.length), isCfg L[k] → isCfg L[i] →
    CommittedBy ids g G L[i].id.term.val (L.take (k + 1))

/-- Structural facts about the ghost history of a dynamic cluster. -/
structure Wf (G : Ghost (Record V MAX) K) : Prop where
  leader : ∀ t L, G.leader t = some L → Consistent G L ∧ (∀ e ∈ L, 0 < e.id.term.val ∧ e.id.term.val ≤ t) ∧
    (∃ c eL, G.elect t = some (c, eL) ∧ eL <+: L ∧
      ∀ k (hk : k < L.length), eL.length ≤ k → L[k].id.term.val = t) ∧
    Chain ids g G L
  elect : ∀ T c eL, G.elect T = some (c, eL) → 0 < T ∧ Consistent G eL ∧ (∀ e ∈ eL, e.id.term.val < T) ∧
    Quorum (cfgOf g eL) (Voters ids G T c eL)
  ballot : ∀ T w c vlog, (T, w, c, vlog) ∈ G.ballots → Consistent G vlog ∧
    ∀ t j', (w, t, j') ∈ G.acks → t < T → ∀ j ≤ j',
      Kept G w t j T vlog ∨ ∃ c' eL', G.elect T = some (c', eL') ∧ c' ≠ c ∧ ¬ G.prefix t j <+: eL'
  good : ∀ T p, CommittedBy ids g G T p → p ≠ [] → Good ids g G T p

variable {ids g}

/-! ## Basic facts -/

theorem committedBy_mono_term (G : Ghost (Record V MAX) K) (T T' : Nat) (h : T ≤ T') (p : List (Entry (Record V MAX)))
    (hp : CommittedBy ids g G T p) : CommittedBy ids g G T' p := by
  rcases hp with rfl | ⟨t, j, ht, hc, hp⟩
  · exact Or.inl rfl
  · exact Or.inr ⟨t, j, by omega, hc, hp⟩

theorem committedBy_prefix (G : Ghost (Record V MAX) K) (T : Nat) (p q : List (Entry (Record V MAX)))
    (hpq : p <+: q) (hq : CommittedBy ids g G T q) : CommittedBy ids g G T p := by
  rcases hq with rfl | ⟨t, j, ht, hc, hq⟩
  · exact Or.inl (List.eq_nil_of_prefix_nil hpq)
  · exact Or.inr ⟨t, j, ht, hc, hpq.trans hq⟩

theorem commitQ_leader (G : Ghost (Record V MAX) K) (t j : Nat) (h : CommitQ ids g G t j) :
    ∃ L, G.leader t = some L ∧ j ≤ L.length ∧ 0 < j ∧ ∃ h : j - 1 < L.length, L[j - 1].id.term.val = t := by
  obtain ⟨n, hj, hjn, L, hL, hn, hterm, -⟩ := h
  exact ⟨L, hL, by omega, hj, hterm⟩

theorem prefix_eq_take (G : Ghost (Record V MAX) K) (t j : Nat) (L : List (Entry (Record V MAX)))
    (hL : G.leader t = some L) : G.prefix t j = L.take j := by
  simp [Ghost.prefix, hL]

/-- Entries of a consistent log have positive terms, at most its last term. -/
theorem consistent_terms' (G : Ghost (Record V MAX) K) (hw : Wf ids g G) (l : List (Entry (Record V MAX)))
    (h : Consistent G l) : ∀ e ∈ l, 0 < e.id.term.val ∧ e.id.term.val ≤ (lastOf l).term.val := by
  intro e he
  have hl : l ≠ [] := List.ne_nil_of_mem he
  obtain ⟨L, hL, hp⟩ := consistent_prefix_last G l h hl
  exact (hw.leader _ L hL).2.1 e (hp.subset he)

/-- A consistent log inherits the configuration facts of the leader logs it is drawn from. -/
theorem chain_of_consistent (G : Ghost (Record V MAX) K) (hw : Wf ids g G) (l : List (Entry (Record V MAX)))
    (h : Consistent G l) : Chain ids g G l := by
  constructor
  · intro i hi X hX
    obtain ⟨-, L, hL, hp⟩ := h i hi
    obtain ⟨-, -, -, hstep, -⟩ := hw.leader _ L hL
    have hi' : i < L.length := by have := hp.length_le; simp at this; omega
    have heq : l.take (i + 1) = L.take (i + 1) := by
      rw [List.prefix_iff_eq_take] at hp; rw [hp]; simp; omega
    have hget : L[i] = l[i] := by
      have := congrArg (fun x => x[i]?) heq
      simp only [List.getElem?_take, if_pos (show i < i + 1 by omega), List.getElem?_eq_getElem hi,
        List.getElem?_eq_getElem hi'] at this
      exact (Option.some.inj this).symm
    have htake : L.take i = l.take i := by
      have := congrArg (List.take i) heq
      simp only [List.take_take, Nat.min_eq_left (show i ≤ i + 1 by omega)] at this
      exact this.symm
    have := hstep i hi' X (by rw [hget]; exact hX)
    rwa [htake] at this
  · intro k i hk hi hck hci
    obtain ⟨-, L, hL, hp⟩ := h i hi
    obtain ⟨-, -, -, -, hchain⟩ := hw.leader _ L hL
    have hi' : i < L.length := by have := hp.length_le; simp at this; omega
    have heq : l.take (i + 1) = L.take (i + 1) := by
      rw [List.prefix_iff_eq_take] at hp; rw [hp]; simp; omega
    have hgi : L[i] = l[i] := by
      have := congrArg (fun x => x[i]?) heq
      simp only [List.getElem?_take, if_pos (show i < i + 1 by omega), List.getElem?_eq_getElem hi,
        List.getElem?_eq_getElem hi'] at this
      exact (Option.some.inj this).symm
    have hgk : L[k]'(by omega) = l[k]'(by omega) := by
      have := congrArg (fun x => x[k]?) heq
      simp only [List.getElem?_take, if_pos (show k < i + 1 by omega), List.getElem?_eq_getElem (show k < l.length by omega),
        List.getElem?_eq_getElem (show k < L.length by omega)] at this
      exact (Option.some.inj this).symm
    have := hchain k i hk hi' (by rw [hgk]; exact hck) (by rw [hgi]; exact hci)
    have htk : L.take (k + 1) = l.take (k + 1) := by
      have := congrArg (List.take (k + 1)) heq
      simp only [List.take_take, Nat.min_eq_left (show k + 1 ≤ i + 1 by omega)] at this
      exact this.symm
    rwa [hgi, htk] at this

/-- Where two lists first differ. -/
theorem diverge {α : Type} (P l : List α) (h : ¬ P <+: l) :
    ∃ a, a < P.length ∧ l.take a = P.take a ∧ l.take (a + 1) ≠ P.take (a + 1) := by
  induction P generalizing l with
  | nil => exact absurd List.nil_prefix h
  | cons x xs ih =>
    cases l with
    | nil => exact ⟨0, by simp, rfl, by simp⟩
    | cons y ys =>
      by_cases hxy : y = x
      · subst hxy
        have h' : ¬ xs <+: ys := fun hp => h (List.prefix_cons_inj _ |>.mpr hp)
        obtain ⟨a, ha, h1, h2⟩ := ih ys h'
        refine ⟨a + 1, by simp; omega, by simp [h1], ?_⟩
        simp only [List.take_succ_cons, ne_eq, List.cons.injEq, true_and]; exact h2
      · exact ⟨0, by simp, rfl, by simp [hxy]⟩

/-- A log whose configuration records from position `a` on are at most one ends
    near the configuration of its first `a` entries. -/
theorem near_tail (l : List (Entry (Record V MAX))) (a : Nat)
    (hstep : ∀ i (hi : i < l.length) X, recCfg l[i].value = some X → Step (cfgOf g (l.take i)) X)
    (huniq : ∀ k1 k2 (h2 : k2 < l.length) (_h1 : a ≤ k1) (h12 : k1 < k2), isCfg (l[k1]'(by omega)) → isCfg l[k2] → False) :
    Near (cfgOf g (l.take a)) (cfgOf g l) := by
  by_cases hex : ∃ k, ∃ hk : k < l.length, a ≤ k ∧ isCfg l[k]
  · obtain ⟨k, hk, hak, hck⟩ := hex
    have hafter : cfgOf g l = cfgOf g (l.take (k + 1)) := by
      have e : cfgOf g l = cfgOf g (l.take l.length) := by rw [List.take_length]
      rw [e]
      apply cfgOf_take_noCfg g l (k + 1) l.length (by omega)
      intro k2 hk2 h1 h2 hc2
      exact huniq k k2 hk2 hak (by omega) hck hc2
    have hbefore : cfgOf g (l.take k) = cfgOf g (l.take a) := by
      apply cfgOf_take_noCfg g l a k hak
      intro k1 hk1 h1 h2 hc1
      exact huniq k1 k hk h1 h2 hc1 hck
    obtain ⟨X, hX⟩ := Option.isSome_iff_exists.mp hck
    rw [hafter, cfgOf_take_succ g l k hk, hX, Option.getD_some]
    have := hstep k hk X hX
    rw [hbefore] at this
    exact Or.inr this
  · left
    by_cases hal : a ≤ l.length
    · have e : cfgOf g l = cfgOf g (l.take l.length) := by rw [List.take_length]
      rw [e]
      apply cfgOf_take_noCfg g l a l.length hal
      intro k hk h1 h2 hc
      exact hex ⟨k, hk, h1, hc⟩
    · rw [List.take_of_length_le (by omega : l.length ≤ a)]

/-- An elected leader's log is a prefix of every consistent log ending in that
    leader's term. -/
theorem elect_prefix_of_last (G : Ghost (Record V MAX) K) (hw : Wf ids g G) (l : List (Entry (Record V MAX)))
    (_hl : Consistent G l) (hne : l ≠ []) (Lτ : List (Entry (Record V MAX)))
    (_hLτ : G.leader (lastOf l).term.val = some Lτ) (hp : l <+: Lτ) (c : Fin K) (eL : List (Entry (Record V MAX)))
    (he : G.elect (lastOf l).term.val = some (c, eL)) (heL : eL <+: Lτ) : eL <+: l := by
  have hlt := (hw.elect _ c eL he).2.2.1
  have hlen : eL.length ≤ l.length := by
    apply Classical.byContradiction
    intro hn
    have hpos := List.length_pos_iff.mpr hne
    have hk : l.length - 1 < eL.length := by omega
    have h1 : eL[l.length - 1] = Lτ[l.length - 1]'(by have := heL.length_le; omega) :=
      List.IsPrefix.getElem heL hk
    have h2 : l[l.length - 1]'(by omega) = Lτ[l.length - 1]'(by have := hp.length_le; omega) :=
      List.IsPrefix.getElem hp _
    have h3 : (eL[l.length - 1]).id.term.val < (lastOf l).term.val := hlt _ (List.getElem_mem _)
    rw [h1, ← h2, lastOf_cons_last l hne, List.getLast_eq_getElem] at h3
    omega
  exact List.prefix_of_prefix_length_le heL hp hlen

/-! ## Leader completeness -/

/-- Every elected leader's log contains every commitment of an earlier term. -/
theorem leader_complete (hid : ∀ a b : Fin K, ids[a] = ids[b] → a = b) (G : Ghost (Record V MAX) K)
    (hw : Wf ids g G) :
    ∀ T c eL, G.elect T = some (c, eL) → ∀ t j, t < T → CommitQ ids g G t j → G.prefix t j <+: eL := by
  intro T
  induction T using Nat.strongRecOn with
  | _ T ih =>
  intro c eL he t j htT hc
  -- Commitments of earlier terms are compatible.
  have compat : ∀ t1 j1 t2 j2, t1 < T → t2 < T → CommitQ ids g G t1 j1 → CommitQ ids g G t2 j2 →
      ∃ L, G.prefix t1 j1 <+: L ∧ G.prefix t2 j2 <+: L := by
    intro t1 j1 t2 j2 h1T h2T h1 h2
    obtain ⟨L1, hL1, -⟩ := commitQ_leader G t1 j1 h1
    obtain ⟨L2, hL2, -⟩ := commitQ_leader G t2 j2 h2
    rcases Nat.lt_trichotomy t1 t2 with hlt | rfl | hgt
    · obtain ⟨-, -, ⟨c2, eL2, he2, heL2, -⟩, -⟩ := hw.leader t2 L2 hL2
      exact ⟨L2, (ih t2 h2T c2 eL2 he2 t1 j1 hlt h1).trans heL2, by rw [prefix_eq_take G t2 j2 L2 hL2]; exact List.take_prefix _ _⟩
    · exact ⟨L1, by rw [prefix_eq_take G t1 j1 L1 hL1]; exact List.take_prefix _ _,
        by rw [prefix_eq_take G t1 j2 L1 hL1]; exact List.take_prefix _ _⟩
    · obtain ⟨-, -, ⟨c1, eL1, he1, heL1, -⟩, -⟩ := hw.leader t1 L1 hL1
      exact ⟨L1, by rw [prefix_eq_take G t1 j1 L1 hL1]; exact List.take_prefix _ _,
        (ih t1 h1T c1 eL1 he1 t2 j2 hgt h2).trans heL1⟩
  apply Classical.byContradiction
  intro hn
  obtain ⟨hT0, heLc, hlt, hquo⟩ := hw.elect T c eL he
  obtain ⟨L, hL, hjL, hj0, hjL', hterm⟩ := commitQ_leader G t j hc
  have hPeq : G.prefix t j = L.take j := prefix_eq_take G t j L hL
  have hPlen : (G.prefix t j).length = j := by rw [hPeq]; simp; omega
  -- A later leader of the candidate's last term already contains the commitment.
  have via_last : ∀ t' j', t' < (lastOf eL).term.val → CommitQ ids g G t' j' → eL ≠ [] → G.prefix t' j' <+: eL := by
    intro t' j' ht' hc' hne
    obtain ⟨Lτ, hLτ, hp⟩ := consistent_prefix_last G eL heLc hne
    obtain ⟨-, -, ⟨c3, eL3, he3, heL3, -⟩, -⟩ := hw.leader _ Lτ hLτ
    have hτT : (lastOf eL).term.val < T := by
      have := hlt _ (List.getLast_mem hne); rwa [← lastOf_cons_last eL hne] at this
    exact (ih _ hτT c3 eL3 he3 t' j' ht' hc').trans (elect_prefix_of_last G hw eL heLc hne Lτ hLτ hp c3 eL3 he3 heL3)
  by_cases hτ : t < (lastOf eL).term.val
  · apply hn
    apply via_last t j hτ hc
    intro e; rw [e] at hτ; simp [lastOf, LogId.default] at hτ
  -- The candidate's log diverges from the committed log at position `a`.
  obtain ⟨a, ha, hta, hta1⟩ := diverge (G.prefix t j) eL hn
  have haP : a < (G.prefix t j).length := ha
  have hpc : CommittedBy ids g G t ((G.prefix t j).take (a + 1)) := Or.inr ⟨t, j, Nat.le_refl t, hc, List.take_prefix _ _⟩
  have hpne : (G.prefix t j).take (a + 1) ≠ [] := by
    intro e
    rcases List.take_eq_nil_iff.mp e with h | h
    · omega
    · rw [h] at haP; simp at haP
  obtain ⟨t', j', n', L', ht't, hca, hL', hpL', hnear⟩ := hw.good t _ hpc hpne
  have hdrop : ((G.prefix t j).take (a + 1)).dropLast = (G.prefix t j).take a := by
    rw [List.dropLast_eq_take]; simp only [List.length_take]; rw [List.take_take]; congr 1; omega
  rw [hdrop] at hnear
  have haL : a ≤ eL.length := by
    apply Classical.byContradiction; intro hh
    have := congrArg List.length hta
    simp at this; omega
  -- The candidate's configuration is near the one at the divergence point.
  have hchain := chain_of_consistent G hw eL heLc
  have hnearD : Near (cfgOf g (eL.take a)) (cfgOf g eL) := by
    apply near_tail eL a hchain.1
    intro k1 k2 hk2 hak1 hk12 hc1 hc2
    have hcb := hchain.2 k1 k2 hk12 hk2 hc1 hc2
    have hk2T : (eL[k2]).id.term.val < T := hlt _ (List.getElem_mem _)
    rcases hcb with he0 | ⟨t2, j2, ht2, hc2', hp2⟩
    · rcases List.take_eq_nil_iff.mp he0 with h | h
      · omega
      · rw [h] at hk2; simp at hk2
    obtain ⟨Lc, h1, h2⟩ := compat t j t2 j2 htT (by omega) hc hc2'
    rcases List.prefix_or_prefix_of_prefix (hp2.trans h2) h1 with hq | hq
    · -- The committed prefix of the candidate's log lies on the committed log.
      apply hta1
      have hlen : (eL.take (k1 + 1)).length = k1 + 1 := by simp; omega
      rw [List.prefix_iff_eq_take] at hq
      have e1 : eL.take (a + 1) = (eL.take (k1 + 1)).take (a + 1) := by rw [List.take_take]; congr 1; omega
      rw [e1, hq, List.take_take, hlen]; congr 1; omega
    · exact hn (hq.trans (List.take_prefix _ _))
  rw [hta] at hnearD
  -- A voter for the candidate acknowledged the witness commitment.
  obtain ⟨hj'0, hjn', Lw, hLw, hnL, hterm', hquo'⟩ := hca
  rw [hL'] at hLw; cases hLw
  obtain ⟨id, ⟨w, hw1, vlog, hb, hup⟩, ⟨w2, hw2, j'', hj'', hack⟩⟩ :=
    near_inter _ _ _ hnearD hnear _ _ hquo hquo'
  obtain rfl : w = w2 := hid w w2 (hw1.trans hw2.symm)
  have ht'T : t' < T := by omega
  obtain ⟨hvlog, hkept⟩ := hw.ballot T w c vlog hb
  have hpv : G.prefix t' j' <+: vlog := by
    rcases hkept t' j'' hack ht'T j' hj'' with (hp | ⟨t'', h1, h2, c'', eL'', he'', -, hnot⟩) | ⟨c', eL', he', hne, -⟩
    · exact hp
    · exact absurd (ih t'' h2 c'' eL'' he'' t' j' h1 ⟨n', hj'0, hjn', L', hL', hnL, hterm', hquo'⟩) hnot
    · rw [he] at he'; cases he'; exact absurd rfl hne
  have hPw : G.prefix t' j' = L'.take j' := prefix_eq_take G t' j' L' hL'
  have hpv' : (G.prefix t j).take (a + 1) <+: vlog := hpL'.trans (hPw ▸ hpv)
  -- The voter's last term is at least `t'`.
  obtain ⟨hj'L, hlast⟩ := hterm'
  have hmem : L'[j' - 1] ∈ vlog := by
    apply hpv.subset; rw [hPw]
    exact List.mem_iff_getElem.mpr ⟨j' - 1, by simp; omega, by simp⟩
  have hvt : t' ≤ (lastOf vlog).term.val := by
    have := (consistent_terms' G hw vlog hvlog _ hmem).2; rwa [hlast] at this
  have hvne : vlog ≠ [] := List.ne_nil_of_mem hmem
  have hpos : 0 < t' := by
    have := ((hw.leader t' L' hL').2.1 L'[j' - 1] (List.getElem_mem _)).1; rwa [hlast] at this
  have hτge : t' ≤ (lastOf eL).term.val := by
    rcases hup with h | ⟨h, -⟩ <;> omega
  have heLne : eL ≠ [] := by
    intro e; rw [e] at hτge; simp [lastOf, LogId.default] at hτge; omega
  have hcontra : (G.prefix t j).take (a + 1) <+: eL → False := by
    intro hq
    apply hta1
    rw [List.prefix_iff_eq_take] at hq
    rw [hq]; simp only [List.length_take]
    congr 1; omega
  by_cases hgt : t' < (lastOf eL).term.val
  · exact hcontra (hpL'.trans (hPw ▸ via_last t' j' hgt ⟨n', hj'0, hjn', L', hL', hnL, ⟨hj'L, hlast⟩, hquo'⟩ heLne))
  -- Equal last terms: both logs are prefixes of the leader log of term `t'`.
  have heq : (lastOf eL).term.val = t' := by omega
  have hveq : (lastOf vlog).term.val = t' := by
    rcases hup with h | ⟨h, -⟩ <;> omega
  obtain ⟨Lv, hLv, hvp⟩ := consistent_prefix_last G vlog hvlog hvne
  obtain ⟨Le, hLe, hep⟩ := consistent_prefix_last G eL heLc heLne
  rw [hveq, hL'] at hLv; cases hLv
  rw [heq, hL'] at hLe; cases hLe
  have h1 := consistent_length G vlog hvlog hvne
  have h2 := consistent_length G eL heLc heLne
  have hidx : (lastOf vlog).index.val ≤ (lastOf eL).index.val := by
    rcases hup with h | ⟨-, h⟩ <;> omega
  exact hcontra (hpv'.trans (List.prefix_of_prefix_length_le hvp hep (by omega)))

end Jarl.Engine.Dyn
