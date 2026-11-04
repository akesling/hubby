import Engine.Frame
import Engine.LogFacts

/-! # Preservation: Saving a checkpoint -/

namespace Jarl.Engine
open Jarl

variable {V S : Type} {N CAP : Nat}

/-! ## The cluster after `persist` -/

theorem persist_live_self (C : Cluster V S N CAP) (k : Fin N) (m : Node V S N CAP) :
    (C.persist k m).live k = m := by
  simp [Cluster.persist]

theorem persist_live_other (C : Cluster V S N CAP) (k j : Fin N) (m : Node V S N CAP) (h : j ≠ k) :
    (C.persist k m).live j = C.live j := by
  simp [Cluster.persist, h]

theorem persist_disk_self (C : Cluster V S N CAP) (k : Fin N) (m : Node V S N CAP) :
    (C.persist k m).disk k = (C.live k).state := by
  simp [Cluster.persist]

theorem persist_disk_other (C : Cluster V S N CAP) (k j : Fin N) (m : Node V S N CAP) (h : j ≠ k) :
    (C.persist k m).disk j = C.disk j := by
  simp [Cluster.persist, h]

theorem fixed_saved (ids : Vector Id N) (n : Node V S N CAP) (h : Fixed ids n) :
    Fixed ids { n with dirty := false, log_from := none, snapshot_changed := false } :=
  ⟨h.n_pos, h.n_lt, h.cap_pos, h.cap_lt, h.nodup, h.hooks, h.members, h.membership, h.bootstrap, h.peers,
    h.local_lt, h.local_id, h.heartbeat, h.election, h.election_le, h.extra, h.prevoting, h.layout, h.contig⟩

/-! ## List and ghost facts -/

theorem take_of_prefix {α : Type} {l l' : List α} (hp : l <+: l') {c : Nat} (hc : c ≤ l.length) :
    l'.take c = l.take c := by
  obtain ⟨r, rfl⟩ := hp
  exact List.take_append_of_le_length hc

theorem ackOk_le (G : Ghost V N) (t j j' : Nat) (h : AckOk G t j) (hj : j' ≤ j) : AckOk G t j' := by
  obtain ⟨L, hL, hle⟩ := h
  exact ⟨L, hL, by omega⟩

theorem ackOk_extends {G G' : Ghost V N} (e : Extends G G') (t j : Nat) (h : AckOk G t j) : AckOk G' t j := by
  obtain ⟨L, hL, hle⟩ := h
  obtain ⟨L', hL', hp⟩ := e.leader t L hL
  exact ⟨L', hL', Nat.le_trans hle hp.length_le⟩

theorem elect_inj (G : Ghost V N) (t : Nat) (a b : Fin N) (x y : List (Entry V))
    (h1 : G.elect t = some (a, x)) (h2 : G.elect t = some (b, y)) : a = b := by
  rw [h1] at h2
  simp only [Option.some.injEq, Prod.mk.injEq] at h2
  exact h2.1

/-- Entries of a well-formed checkpoint's full log carry their positions. -/
theorem fullLog_index (G : Ghost V N) (hw : Wf G) (s : State V S CAP) (h : StateOk G s) (i : Nat)
    (hi : i < (fullLog G s).length) : ((fullLog G s)[i]).id.index.val = i + 1 := by
  by_cases hlo : s.base.index.val ≤ i
  · obtain ⟨hr, he⟩ := fullLog_getElem_ret G s h i hlo hi
    rw [he, h.contig _ hr]
    omega
  · have hpos : 0 < s.base.index.val := by omega
    obtain ⟨L, hL, hle, -⟩ := h.base hpos
    have hb : boundary G s = L.take s.base.index.val := by
      simp [boundary, Ghost.prefix, hL, show s.base.index.val ≠ 0 by omega]
    have hbl := boundary_len G s h
    have hiL : i < L.length := by omega
    have h1 : (boundary G s)[i]'(by omega) = (fullLog G s)[i] :=
      List.IsPrefix.getElem (⟨ret s, rfl⟩ : boundary G s <+: fullLog G s) _
    have h2 : (boundary G s)[i]'(by omega) = L[i] := by
      simp only [hb, List.getElem_take]
    rw [← h1, h2]
    exact ((hw.leader _ L hL).1 i hiL).1

/-- A leader's log is consistent once it is its term's leader log. -/
theorem leader_log_consistent (G G' : Ghost V N) (hw : Wf G) (e : Extends G G') (s : State V S CAP)
    (hs : StateOk G s) (T : Nat) (eL : List (Entry V)) (hcons : Consistent G eL) (hp : eL <+: fullLog G s)
    (hbeyond : ∀ i (h : i < (fullLog G s).length), eL.length ≤ i → ((fullLog G s)[i]).id.term.val = T)
    (hT : G'.leader T = some (fullLog G s)) : Consistent G' (fullLog G s) := by
  intro i hi
  refine ⟨fullLog_index G hw s hs i hi, ?_⟩
  by_cases hlt : i < eL.length
  · obtain ⟨-, L, hL, hpL⟩ := hcons i hlt
    obtain ⟨L', hL', hp'⟩ := e.leader _ L hL
    have he : eL[i] = (fullLog G s)[i] := List.IsPrefix.getElem hp hlt
    refine ⟨L', by rw [← he]; exact hL', ?_⟩
    rw [take_of_prefix hp (by omega)]
    exact hpL.trans hp'
  · rw [hbeyond i hi (by omega)]
    exact ⟨_, hT, List.take_prefix _ _⟩

theorem withOwn_extends (G : Ghost V N) (k : Fin N) (n : Node V S N CAP) (L : List (Entry V))
    (hL : G.leader n.state.hard.term.val = some L) (hp : L <+: fullLog G n.state) : Extends G (withOwn G k n) := by
  refine ⟨fun t L0 h => ?_, fun t x h => h, fun a h => List.mem_cons_of_mem _ h, fun b h => h⟩
  by_cases ht : t = n.state.hard.term.val
  · subst ht
    rw [hL] at h
    cases h
    exact ⟨_, by simp [withOwn], hp⟩
  · exact ⟨L0, by simp [withOwn, ht, h], List.prefix_refl _⟩

/-- Extending the ghost history extends a leader's own-log ghost. -/
theorem withOwn_mono {G G' : Ghost V N} (e : Extends G G') (j : Fin N) (n : Node V S N CAP)
    (hs : StateOk G n.state) : Extends (withOwn G j n) (withOwn G' j n) := by
  have hf := fullLog_extends e n.state hs
  refine ⟨fun t L h => ?_, fun t x h => e.elect t x h, fun a h => ?_, fun b h => e.ballots b h⟩
  · by_cases ht : t = n.state.hard.term.val
    · simp only [withOwn, ht, if_true, Option.some.injEq] at h
      subst h
      exact ⟨_, by simp [withOwn, ht, hf], List.prefix_refl _⟩
    · simp only [withOwn, ht, if_false] at h
      obtain ⟨L', h', hp⟩ := e.leader t L h
      exact ⟨L', by simp [withOwn, ht, h'], hp⟩
  · simp only [withOwn, List.mem_cons] at h ⊢
    rcases h with h | h
    · left; rw [hf]; exact h
    · right; exact e.acks a h

/-- The ghost of a leader that saved its log is well formed. -/
theorem wf_withOwn (G : Ghost V N) (hw : Wf G) (k : Fin N) (n : Node V S N CAP) (hs : StateOk G n.state)
    (e : Extends G (withOwn G k n)) (eL : List (Entry V)) (hel : G.elect n.state.hard.term.val = some (k, eL))
    (hp : eL <+: fullLog G n.state)
    (hbeyond : ∀ i (h : i < (fullLog G n.state).length), eL.length ≤ i →
      ((fullLog G n.state)[i]).id.term.val = n.state.hard.term.val)
    (hcons : Consistent (withOwn G k n) (fullLog G n.state))
    (hack : ∀ w t j, (w, t, j) ∈ G.acks → AckOk G t j)
    (hb : ∀ Tb c vlog, (Tb, k, c, vlog) ∈ G.ballots → Tb ≤ n.state.hard.term.val) :
    Wf (withOwn G k n) := by
  refine ⟨fun t L h => ?_, fun T' c eL' h => ?_, fun Tb w c vlog h => ?_⟩
  · by_cases ht : t = n.state.hard.term.val
    · subst ht
      simp only [withOwn, if_true, Option.some.injEq] at h
      subst h
      refine ⟨hcons, fun x hx => ?_, k, eL, hel, hp, fun i hi hle => hbeyond i hi hle⟩
      refine ⟨?_, hs.terms x hx⟩
      obtain ⟨i, hi, rfl⟩ := List.getElem_of_mem hx
      by_cases hlt : i < eL.length
      · have := (consistent_terms G hw eL (hw.elect _ _ _ hel).2.1 (eL[i]) (List.getElem_mem _)).1
        rwa [List.IsPrefix.getElem hp hlt] at this
      · rw [hbeyond i hi (by omega)]
        exact (hw.elect _ _ _ hel).1
    · have h' : G.leader t = some L := by simpa [withOwn, ht] using h
      obtain ⟨a, b, c, eL', d, f, g⟩ := hw.leader t L h'
      exact ⟨consistent_extends e L a, b, c, eL', d, f, g⟩
  · obtain ⟨a, b, c', d⟩ := hw.elect T' c eL' h
    exact ⟨a, consistent_extends e _ b, c', d⟩
  · obtain ⟨a, b⟩ := hw.ballot Tb w c vlog h
    refine ⟨consistent_extends e _ a, fun t j' hack' hlt j hj => ?_⟩
    rcases List.mem_cons.mp hack' with heq | hold
    · simp only [Prod.mk.injEq] at heq
      obtain ⟨rfl, rfl, -⟩ := heq
      have := hb Tb c vlog h
      omega
    · rcases b t j' hold hlt j hj with hk | hk
      · exact Or.inl (kept_extends e _ _ _ _ _ hk (ackOk_le G t j' j (hack _ _ _ hold) hj))
      · exact Or.inr hk

/-! ## Transfer of the per-node clauses -/

theorem candidateOk_transfer (ids : Vector Id N) (C C' : Cluster V S N CAP) {G G' : Ghost V N} (e : Extends G G')
    (hbal : G'.ballots = G.ballots) (j : Fin N) (hst : (C'.live j).state = (C.live j).state)
    (hv : (C'.live j).votes = (C.live j).votes) (hs : StateOk G (C.live j).state) (h : CandidateOk ids C G j) :
    CandidateOk ids C' G' j := by
  unfold CandidateOk at h ⊢
  rw [hst, hv, fullLog_extends e _ hs, hbal]
  exact h

theorem outOk_transfer (ids : Vector Id N) (C C' : Cluster V S N CAP) {G G' : Ghost V N} (e : Extends G G')
    (j j' : Fin N) (o : Outbound) (hst : (C'.live j).state = (C.live j).state)
    (hr : (C'.live j).role = (C.live j).role) (hsent : C'.sent = C.sent) (hs : StateOk G (C.live j).state)
    (h : OutOk ids C G j j' o) : OutOk ids C' G' j j' o := by
  have hf := fullLog_extends e _ hs
  cases o with
  | Vote => simp only [OutOk] at h ⊢; rw [hr]; exact h
  | Voted g =>
    simp only [OutOk] at h ⊢
    rw [hst, hsent, hf]; exact h
  | Replicated i r =>
    simp only [OutOk] at h ⊢
    rw [hst, hf]
    intro hr0
    obtain ⟨a, L, hL, hle⟩ := h hr0
    rw [prefix_extends e _ _ L hL hle]
    exact ⟨a, ackOk_extends e _ _ ⟨L, hL, hle⟩⟩
  | Replicate => simp only [OutOk] at h ⊢; rw [hr]; exact h
  | PreVote _ => simp only [OutOk] at h
  | PreVoted _ _ => simp only [OutOk] at h

theorem leaderOk_saved (ids : Vector Id N) (C C' : Cluster V S N CAP) (G' : Ghost V N) (j : Fin N)
    (hst : (C'.live j).state = (C.live j).state) (hm : (C'.live j).matched = (C.live j).matched)
    (eL : List (Entry V)) (h1 : G'.elect (C.live j).state.hard.term.val = some (j, eL))
    (h2 : eL <+: fullLog G' (C.live j).state)
    (h3 : ∀ i (h : i < (fullLog G' (C.live j).state).length), eL.length ≤ i →
      ((fullLog G' (C.live j).state)[i]).id.term = (C.live j).state.hard.term)
    (h4 : G'.leader (C.live j).state.hard.term.val = some (fullLog G' (C.live j).state))
    (h7 : ∀ j' : Fin N, j' ≠ j → 0 < ((C.live j).matched[j']).val →
      (j', (C.live j).state.hard.term.val, ((C.live j).matched[j']).val) ∈ G'.acks)
    (h8 : ((C.live j).matched[j]).val ≤ (fullLog G' (C.live j).state).length) : LeaderOk ids C' G' j := by
  refine ⟨?_, ?_, ?_, ?_⟩
  · rw [hst]; exact ⟨eL, h1, h2, h3⟩
  · rw [hst]; exact ⟨_, h4, List.prefix_refl _, fun _ => rfl⟩
  · rw [hst, hm]; exact h7
  · rw [hst, hm]; exact h8

/-! ## The invariant after saving, for a suitable ghost -/

theorem persist_inv (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G G' : Ghost V N)
    (hi : Inv ids cfg C G) (k : Fin N) (e : Extends G G') (hel : G'.elect = G.elect)
    (hbal : G'.ballots = G.ballots) (hwf : Wf G')
    (hacks : ∀ w t j, (w, t, j) ∈ G'.acks → (w, t, j) ∈ G.acks ∨
      (w = k ∧ t = (C.live k).state.hard.term.val ∧ j = (fullLog G (C.live k).state).length ∧
        G'.leader t = some (fullLog G (C.live k).state)))
    (hlead : ∀ t, ((C.live k).role = .Leader → t ≠ (C.live k).state.hard.term.val) → G'.leader t = G.leader t)
    (hleadT : (C.live k).role = .Leader →
      G'.leader (C.live k).state.hard.term.val = some (fullLog G (C.live k).state))
    (hcons : Consistent G' (fullLog G (C.live k).state))
    (hcom : Committed G' ((fullLog G (C.live k).state).take (C.live k).state.hard.commit.val)) :
    Inv ids cfg (C.persist k { C.live k with dirty := false, log_from := none, snapshot_changed := false }) G' := by
  have hs := hi.live k
  have hfk : fullLog G' (C.live k).state = fullLog G (C.live k).state := fullLog_extends e _ hs
  have hother : ∀ j, j ≠ k → (C.live j).role = .Leader → ((C.live k).role = .Leader →
      (C.live j).state.hard.term.val ≠ (C.live k).state.hard.term.val) := by
    intro j hj hrj hrk heq
    obtain ⟨⟨eLj, hj1, -, -⟩, -⟩ := hi.leader j hrj
    obtain ⟨⟨eLk, hk1, -, -⟩, -⟩ := hi.leader k hrk
    rw [heq] at hj1
    exact hj (elect_inj G _ j k eLj eLk hj1 hk1)
  refine
    { wf := hwf
      fixed := fun j => ?fixed
      slot := fun j => ?slot
      live := fun j => ?live
      disk := fun j => ?disk
      consistent_disk := fun j => ?cdisk
      consistent_live := fun j => ?clive
      clean := fun j => ?clean
      terms := fun j => ?terms
      acks := fun w t j h => ?acks
      ballots := fun Tb w c v h => ?ballots
      ballot_unique := ?bu
      ballot_cand := fun Tb w c v h hr ht => ?bcand
      elect := fun T c eL h hd => ?elect
      elect_cand := fun T c eL h => ?elect_cand
      leader := fun j => ?leader
      candidate := fun j => ?candidate
      outbox := fun j j' o => ?outbox
      outbox_self := fun j => ?outbox_self
      sent := fun env h => ?sent
      committed := fun j => ?committed }
  case fixed =>
    by_cases hj : j = k
    · subst hj; rw [persist_live_self]; exact ⟨fixed_saved ids _ (hi.fixed j).1, (hi.fixed j).2⟩
    · rw [persist_live_other C k j _ hj]; exact hi.fixed j
  case slot =>
    by_cases hj : j = k
    · subst hj; rw [persist_live_self]; exact hi.slot j
    · rw [persist_live_other C k j _ hj]; exact hi.slot j
  case live =>
    by_cases hj : j = k
    · subst hj; rw [persist_live_self]; exact stateOk_extends e _ (hi.live j)
    · rw [persist_live_other C k j _ hj]; exact stateOk_extends e _ (hi.live j)
  case disk =>
    by_cases hj : j = k
    · subst hj; rw [persist_disk_self]; exact stateOk_extends e _ (hi.live j)
    · rw [persist_disk_other C k j _ hj]; exact stateOk_extends e _ (hi.disk j)
  case cdisk =>
    by_cases hj : j = k
    · subst hj; rw [persist_disk_self, hfk]; exact hcons
    · rw [persist_disk_other C k j _ hj, fullLog_extends e _ (hi.disk j)]
      exact consistent_extends e _ (hi.consistent_disk j)
  case clive =>
    by_cases hj : j = k
    · subst hj; rw [persist_live_self]; intro _
      show Consistent G' (fullLog G' (C.live j).state)
      rw [hfk]; exact hcons
    · rw [persist_live_other C k j _ hj]; intro hr
      rw [fullLog_extends e _ (hi.live j)]
      exact consistent_extends e _ (hi.consistent_live j hr)
  case clean =>
    by_cases hj : j = k
    · subst hj; rw [persist_live_self, persist_disk_self]; intro _; rfl
    · rw [persist_live_other C k j _ hj, persist_disk_other C k j _ hj]; exact hi.clean j
  case terms =>
    by_cases hj : j = k
    · subst hj; rw [persist_live_self, persist_disk_self]; exact Nat.le_refl _
    · rw [persist_live_other C k j _ hj, persist_disk_other C k j _ hj]; exact hi.terms j
  case acks =>
    rcases hacks w t j h with hold | ⟨hw, ht, hj, hL⟩
    · obtain ⟨a, b, c⟩ := hi.acks w t j hold
      refine ⟨ackOk_extends e _ _ a, ?_, fun j' hj' => ?_⟩
      · by_cases hw : w = k
        · subst hw; rw [persist_disk_self]; exact Nat.le_trans b (hi.terms w)
        · rw [persist_disk_other C k w _ hw]; exact b
      · have ha' := ackOk_le G t j j' a hj'
        obtain ⟨c1, c2⟩ := c j' hj'
        by_cases hw : w = k
        · subst hw
          rw [persist_live_self, persist_disk_self]
          show Kept G' w t j' ((C.live w).state.hard.term.val + 1) (fullLog G' (C.live w).state) ∧
            Kept G' w t j' ((C.live w).state.hard.term.val + 1) (fullLog G' (C.live w).state)
          rw [hfk]
          exact ⟨kept_extends e _ _ _ _ _ c1 ha', kept_extends e _ _ _ _ _ c1 ha'⟩
        · rw [persist_live_other C k w _ hw, persist_disk_other C k w _ hw, fullLog_extends e _ (hi.live w),
            fullLog_extends e _ (hi.disk w)]
          exact ⟨kept_extends e _ _ _ _ _ c1 ha', kept_extends e _ _ _ _ _ c2 ha'⟩
    · subst ht
      subst hj
      rw [hw]
      have hpre : ∀ j', G'.prefix (C.live k).state.hard.term.val j' <+: fullLog G' (C.live k).state := by
        intro j'
        rw [hfk]
        simp only [Ghost.prefix, hL, Option.getD_some]
        exact List.take_prefix _ _
      refine ⟨⟨_, hL, Nat.le_refl _⟩, ?_, fun j' _ => ?_⟩
      · rw [persist_disk_self]; exact Nat.le_refl _
      · rw [persist_live_self, persist_disk_self]
        exact ⟨Or.inl (hpre j'), Or.inl (hpre j')⟩
  case ballots =>
    rw [hbal] at h
    obtain ⟨a, b, c', d⟩ := hi.ballots Tb w c v h
    refine ⟨?_, fun hwc => ?_, ?_, ?_⟩
    · by_cases hw : w = k
      · subst hw
        rw [persist_disk_self]
        have ht := hi.terms w
        rcases a with a | ⟨hwc, hd1, he'⟩
        · exact Or.inl (Nat.le_trans a ht)
        · by_cases hlt : (C.disk w).hard.term.val < (C.live w).state.hard.term.val
          · exact Or.inl (by omega)
          · exact Or.inr ⟨hwc, by omega, by rw [hel]; exact he'⟩
      · rw [persist_disk_other C k w _ hw]
        rcases a with a | ⟨hwc, hd1, he'⟩
        · exact Or.inl a
        · exact Or.inr ⟨hwc, hd1, by rw [hel]; exact he'⟩
    · by_cases hc : c = k
      · subst hc; rw [persist_disk_self]; exact Nat.le_trans (b hwc) (hi.terms c)
      · rw [persist_disk_other C k c _ hc]; exact b hwc
    · by_cases hw : w = k
      · subst hw; rw [persist_disk_self]; exact d
      · rw [persist_disk_other C k w _ hw]; exact c'
    · by_cases hw : w = k
      · subst hw; rw [persist_live_self]; exact d
      · rw [persist_live_other C k w _ hw]; exact d
  case bcand =>
    rw [hbal] at h
    by_cases hc : c = k
    · subst hc
      rw [persist_live_self] at hr ht ⊢
      show upToDate (lastOf (fullLog G' (C.live c).state)) (lastOf v)
      rw [hfk]; exact hi.ballot_cand Tb w c v h hr ht
    · rw [persist_live_other C k c _ hc] at hr ht ⊢
      rw [fullLog_extends e _ (hi.live c)]; exact hi.ballot_cand Tb w c v h hr ht
  case bu =>
    rw [hbal]; exact hi.ballot_unique
  case elect =>
    rw [hel] at h
    by_cases hc : c = k
    · subst hc
      rw [persist_disk_self] at hd
      obtain ⟨a, -, c', d⟩ := hi.elect T c eL h (by have := hi.terms c; omega)
      obtain ⟨d1, d2, d3⟩ := d hd
      rw [persist_disk_self, persist_live_self]
      show G'.leader T = some eL ∧ fullLog G' (C.live c).state = eL ∧ (C.live c).state.hard.term.val + 1 = T ∧
        ((C.live c).state.hard.term.val < T → fullLog G' (C.live c).state = eL ∧ (C.live c).role ≠ .Leader ∧
          (C.live c).state.hard.term = (C.live c).state.hard.term)
      rw [hlead T (fun h' => absurd h' d2), hfk]
      refine ⟨a, d1, ?_, fun _ => ⟨d1, d2, rfl⟩⟩
      rw [d3]; exact c'
    · rw [persist_disk_other C k c _ hc] at hd
      obtain ⟨a, b, c', d⟩ := hi.elect T c eL h hd
      rw [persist_disk_other C k c _ hc, persist_live_other C k c _ hc, fullLog_extends e _ (hi.disk c),
        fullLog_extends e _ (hi.live c)]
      refine ⟨?_, b, c', d⟩
      rw [hlead T ?_]
      · exact a
      · intro hrk hT
        obtain ⟨⟨eLk, hk1, -, -⟩, -⟩ := hi.leader k hrk
        rw [← hT] at hk1
        exact hc (elect_inj G _ c k eL eLk h hk1)
  case elect_cand =>
    rw [hel] at h
    by_cases hc : c = k
    · subst hc; rw [persist_live_self]; exact hi.elect_cand T c eL h
    · rw [persist_live_other C k c _ hc]; exact hi.elect_cand T c eL h
  case leader =>
    by_cases hj : j = k
    · subst hj
      rw [persist_live_self]
      intro hr
      have hr' : (C.live j).role = .Leader := hr
      obtain ⟨⟨eL, h1, h2, h3⟩, -, h7, h8⟩ := hi.leader j hr'
      have h3' : ∀ i (h : i < (fullLog G' (C.live j).state).length), eL.length ≤ i →
          ((fullLog G' (C.live j).state)[i]).id.term = (C.live j).state.hard.term := by
        rw [hfk]; exact h3
      exact leaderOk_saved ids C _ G' j (by rw [persist_live_self]) (by rw [persist_live_self]) eL
        (by rw [hel]; exact h1) (by rw [hfk]; exact h2) h3' (by rw [hfk]; exact hleadT hr')
        (fun j' hj' hm => e.acks _ (h7 j' hj' hm)) (by rw [hfk]; exact h8)
    · rw [persist_live_other C k j _ hj]
      intro hr
      apply (leaderOk_congr ids C _ G' j (persist_live_other C k j _ hj)).mp
      obtain ⟨⟨eL, h1, h2, h3⟩, ⟨L, h4, h5, h6⟩, h7, h8⟩ := hi.leader j hr
      have hf := fullLog_extends e _ (hi.live j)
      refine ⟨⟨eL, by rw [hel]; exact h1, by rw [hf]; exact h2, by rw [hf]; exact h3⟩,
        ⟨L, ?_, by rw [hf]; exact h5, by rw [hf]; exact h6⟩, fun j' hj' hm => e.acks _ (h7 j' hj' hm),
        by rw [hf]; exact h8⟩
      rw [hlead _ (hother j hj hr)]; exact h4
  case candidate =>
    intro hr
    by_cases hj : j = k
    · subst hj
      rw [persist_live_self] at hr
      exact candidateOk_transfer ids C _ e hbal j (by rw [persist_live_self]) (by rw [persist_live_self])
        (hi.live j) (hi.candidate j hr)
    · rw [persist_live_other C k j _ hj] at hr
      exact candidateOk_transfer ids C _ e hbal j (by rw [persist_live_other C k j _ hj])
        (by rw [persist_live_other C k j _ hj]) (hi.live j) (hi.candidate j hr)
  case outbox =>
    intro ho
    by_cases hj : j = k
    · subst hj
      rw [persist_live_self] at ho
      exact outOk_transfer ids C _ e j j' o (by rw [persist_live_self]) (by rw [persist_live_self]) rfl
        (hi.live j) (hi.outbox j j' o ho)
    · rw [persist_live_other C k j _ hj] at ho
      exact outOk_transfer ids C _ e j j' o (by rw [persist_live_other C k j _ hj])
        (by rw [persist_live_other C k j _ hj]) rfl (hi.live j) (hi.outbox j j' o ho)
  case outbox_self =>
    by_cases hj : j = k
    · subst hj; rw [persist_live_self]; exact hi.outbox_self j
    · rw [persist_live_other C k j _ hj]; exact hi.outbox_self j
  case sent =>
    have h0 := hi.sent env h
    unfold SentOk at h0 ⊢
    refine ⟨h0.1, ?_⟩
    have h2 := h0.2
    revert h2
    cases hm : env.message with
    | Vote T last =>
      intro h2 c hc
      obtain ⟨a, b, d⟩ := h2 c hc
      refine ⟨?_, ?_, by rw [hel]; exact d⟩
      · by_cases hck : c = k
        · subst hck; rw [persist_disk_self]; exact Nat.le_trans a (hi.terms c)
        · rw [persist_disk_other C k c _ hck]; exact a
      · by_cases hck : c = k
        · subst hck; rw [persist_live_self]; exact b
        · rw [persist_live_other C k c _ hck]; exact b
    | Voted T g => intro h2; rw [hbal, hel]; exact h2
    | Replicated T j r => intro h2 hr w hw; exact e.acks _ (h2 hr w hw)
    | Append T prev entry commit =>
      intro ⟨L, hL, h1, h2, h3, h4, h5, h6⟩
      obtain ⟨L', hL', hp⟩ := e.leader _ L hL
      refine ⟨L', hL', fun hpos => ?_, h2, fun en hen => ?_, Nat.le_trans h4 hp.length_le, ?_,
        by rw [hel]; exact h6⟩
      · obtain ⟨hl, hid⟩ := h1 hpos
        exact ⟨by have := hp.length_le; omega, by rw [← List.IsPrefix.getElem hp hl]; exact hid⟩
      · obtain ⟨hl, hid, hidx⟩ := h3 en hen
        exact ⟨by have := hp.length_le; omega, by rw [← List.IsPrefix.getElem hp hl]; exact hid, hidx⟩
      · rw [take_of_prefix hp h4]; exact committed_mono e _ h5
    | Install T snap =>
      intro ⟨L, hL, hpos, hl, hid, h5, h6⟩
      obtain ⟨L', hL', hp⟩ := e.leader _ L hL
      refine ⟨L', hL', hpos, by have := hp.length_le; omega, by rw [← List.IsPrefix.getElem hp hl]; exact hid,
        ?_, by rw [hel]; exact h6⟩
      rw [take_of_prefix hp (by omega)]; exact committed_mono e _ h5
    | _ => intro h2; exact h2
  case committed =>
    by_cases hj : j = k
    · subst hj
      rw [persist_disk_self, persist_live_self]
      have hc : Committed G' ((fullLog G' (C.live j).state).take (C.live j).state.hard.commit.val) := by
        rw [hfk]; exact hcom
      exact ⟨hc, Or.inl hc⟩
    · rw [persist_disk_other C k j _ hj, persist_live_other C k j _ hj, fullLog_extends e _ (hi.disk j)]
      obtain ⟨a, b⟩ := hi.committed j
      refine ⟨committed_mono e _ a, ?_⟩
      unfold CommitOk at b ⊢
      rw [fullLog_extends e _ (hi.live j)]
      rcases b with b | ⟨b1, b2, b3⟩
      · exact Or.inl (committed_mono e _ b)
      · exact Or.inr ⟨b1, b2, committed_mono (withOwn_mono e j _ (hi.live j)) _ b3⟩

theorem preserve_persist (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (k : Fin N) (ready : Ready V S N CAP) (h : Node.ready (C.live k) = some ready) :
    ∃ G', Extends G G' ∧ Inv ids cfg (C.persist k (Ready.persisted ready).node) G' := by
  unfold Node.ready Rust.Option.then_some at h
  cases hd : (C.live k).dirty with
  | false => simp [hd] at h
  | true =>
    simp [hd] at h
    subst h
    show ∃ G', Extends G G' ∧
      Inv ids cfg (C.persist k { C.live k with dirty := false, log_from := none, snapshot_changed := false }) G'
    have hs := hi.live k
    by_cases hl : (C.live k).role = .Leader
    · obtain ⟨⟨eL, h1, h2, h3⟩, ⟨L, h4, h5, -⟩, -, -⟩ := hi.leader k hl
      have e := withOwn_extends G k (C.live k) L h4 h5
      have hbeyond : ∀ i (h : i < (fullLog G (C.live k).state).length), eL.length ≤ i →
          ((fullLog G (C.live k).state)[i]).id.term.val = (C.live k).state.hard.term.val :=
        fun i hi' hle => by rw [h3 i hi' hle]
      have hcons := leader_log_consistent G _ hi.wf e _ hs _ eL (hi.wf.elect _ _ _ h1).2.1 h2 hbeyond
        (by simp [withOwn])
      have hb : ∀ Tb c vlog, (Tb, k, c, vlog) ∈ G.ballots → Tb ≤ (C.live k).state.hard.term.val := by
        intro Tb c vlog hbv
        obtain ⟨a, -, -, -⟩ := hi.ballots Tb k c vlog hbv
        have ht := hi.terms k
        rcases a with a | ⟨hkc, hd1, he'⟩
        · omega
        · apply Classical.byContradiction
          intro hlt
          subst hkc
          obtain ⟨-, -, -, d⟩ := hi.elect Tb _ _ he' (by omega)
          exact (d (by omega)).2.1 hl
      refine ⟨_, e, persist_inv ids cfg C G _ hi k e rfl rfl
        (wf_withOwn G hi.wf k _ hs e eL h1 h2 hbeyond hcons (fun w t j h => (hi.acks w t j h).1) hb)
        ?_ ?_ ?_ hcons ?_⟩
      · intro w t j h
        rcases List.mem_cons.mp h with h | h
        · simp only [Prod.mk.injEq] at h
          exact Or.inr ⟨h.1, h.2.1, h.2.2, by rw [h.2.1]; simp [withOwn]⟩
        · exact Or.inl h
      · intro t ht; simp [withOwn, ht hl]
      · intro _; simp [withOwn]
      · rcases (hi.committed k).2 with c | ⟨-, -, c⟩
        · exact committed_mono e _ c
        · exact c
    · refine ⟨G, Extends.refl G, persist_inv ids cfg C G G hi k (Extends.refl G) rfl rfl hi.wf
        (fun w t j h => Or.inl h) (fun t _ => rfl) (fun h => absurd h hl) (hi.consistent_live k hl) ?_⟩
      rcases (hi.committed k).2 with c | ⟨h', -, -⟩
      · exact c
      · exact absurd h' hl

end Jarl.Engine
