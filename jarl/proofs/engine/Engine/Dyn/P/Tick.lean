import Engine.Dyn.Common
import Engine.Dyn.OpTick

/-!
# Preservation: local time
-/

set_option linter.unusedSectionVars false

namespace Jarl.Engine.Dyn
open Jarl Jarl.Engine

variable {V S : Type} {MAX CAP K : Nat} [Rust.Clone V] [Rust.Clone S]

/-! ## Frames -/

private theorem tk_cluster (c0 c : Jarl.Cluster V S MAX CAP) (r : Rust.Result Unit Error)
    (h : Cluster.tick c0 = pure (r, c)) : ∃ n', Node.tick c0.node = pure (r, n') ∧ c = ⟨n'⟩ := by
  unfold Cluster.tick at h
  obtain ⟨⟨r', m⟩, hm, h⟩ := Rust.bind_eq_pure h
  simp only at h
  have := Rust.pure_inj h
  simp only [Prod.mk.injEq] at this
  obtain ⟨rfl, rfl⟩ := this
  exact ⟨m, hm, rfl⟩

private theorem tk_setLive_same (C : World V S MAX CAP K) (k : Fin K) : C.setLive k (C.live k) = C := by
  cases C
  simp only [World.setLive, World.mk.injEq, and_true]
  funext j
  split <;> simp_all

private theorem tk_not_pending (ids : Vector Id K) (g : Membership MAX) (C : World V S MAX CAP K)
    (G : Ghost (Record V MAX) K) (k : Fin K) (n : DNode V S MAX CAP) (hd : n.dirty = false) :
    ¬ PendingWin ids g C G k n := by
  intro h; have : n.dirty = true := h.1; rw [hd] at this; cases this

/-- A node that only changed timers, bookkeeping or its role to follower, with
    only pre-vote descriptors queued. -/
private theorem tk_quiet (ids : Vector Id K) (g : Membership MAX) (C : World V S MAX CAP K)
    (G : Ghost (Record V MAX) K) (hi : Inv ids g C G) (k : Fin K) (hidle : Idle (C.node k))
    (n' : DNode V S MAX CAP) (hdyn : DynOk g ids[k] n')
    (hst : n'.state = (C.node k).state) (hd : n'.dirty = (C.node k).dirty)
    (hrole : n'.role = .Follower ∨ (n'.role = (C.node k).role ∧ n'.matched = (C.node k).matched ∧
      n'.local = (C.node k).local ∧ n'.peers = (C.node k).peers ∧ n'.votes = (C.node k).votes))
    (hout : ∀ (i : Fin MAX) o, n'.outbox[i] = some o → (∃ to, n'.peers[i] = some to) ∧ ∃ t, o = .PreVote t)
    (hself : ∀ h : n'.local.val < MAX, n'.outbox[n'.local.val] = none)
    (hex : n'.extra_reply = none) :
    LocalOk' ids g C G k ⟨n'⟩ := by
  have hlead : Leading G k n' ↔ Leading G k (C.node k) := by unfold Leading; rw [hst]
  refine
    { dyn := hdyn
      live := by show StateOk G n'.state ∧ SnapOk g G n'.state; rw [hst]; exact hi.live k
      consistent := ?_
      clean := by show n'.dirty = false → n'.state = C.disk k; rw [hst, hd]; exact hi.clean k
      terms := by show _ ≤ n'.state.hard.term.val; rw [hst]; exact hi.terms k
      acks := by
        intro t j h j' hj'
        show Kept G k t j' (n'.state.hard.term.val + 1) (fullLog G n'.state)
        rw [hst]; exact ((hi.acks k t j h).2.2 j' hj').1
      ballots := by
        intro T c v h
        show n'.state.hard.term.val = T → n'.state.hard.voted_for = some ids[c]
        rw [hst]; exact (hi.ballots T k c v h).2.2.2
      ballot_cand := ?_
      elect := ?_
      elect_cand := ?_
      lead := ?_
      leader := ?_
      candidate := ?_
      outbox := ?_
      outbox_self := by
        intro h o ho; have : n'.outbox[n'.local.val] = some o := ho; rw [hself h] at this; cases this
      extra := by intro to o h; have : n'.extra_reply = some (to, o) := h; rw [hex] at this; cases this
      votes := ?_
      committed := ?_ }
  · rcases hi.consistent_live k with h | h | h
    · left; show Consistent G (fullLog G n'.state); rw [hst]; exact h
    · right; left; show n'.dirty = true ∧ Leading G k n'; rw [hd, hlead]; exact h
    · exact absurd h (tk_not_pending ids g C G k _ hidle.1)
  · intro hr T w v h ht
    have hr' : n'.role = .Candidate := hr
    rcases hrole with h1 | ⟨h1, -⟩
    · rw [h1] at hr'; cases hr'
    · show upToDate (lastOf (fullLog G n'.state)) (lastOf v)
      have ht' : n'.state.hard.term.val = T := ht
      rw [hst] at ht' ⊢
      exact hi.ballot_cand T w k v h (by rw [← h1]; exact hr') ht'
  · intro T eL h hd' ht
    have ht' : n'.state.hard.term.val < T := ht
    rw [hst] at ht'
    obtain ⟨a, b, c⟩ := (hi.elect T k eL h hd').2.2.2 ht'
    refine ⟨by show fullLog G n'.state = eL; rw [hst]; exact a, ?_, by show n'.state.hard.term = _; rw [hst]; exact c⟩
    show n'.role ≠ .Leader
    rcases hrole with h1 | ⟨h1, -⟩
    · rw [h1]; simp
    · rw [h1]; exact b
  · rintro T eL h ⟨hr, ht⟩
    have hr' : n'.role = .Candidate := hr
    have ht' : n'.state.hard.term.val = T := ht
    rcases hrole with h1 | ⟨h1, -⟩
    · rw [h1] at hr'; cases hr'
    · rw [hst] at ht'
      exact hi.elect_cand T k eL h ⟨by rw [← h1]; exact hr', ht'⟩
  · intro hl
    have hl' := (hlead.mp hl)
    obtain ⟨a, b, c, d⟩ := hi.lead k hl'
    refine ⟨?_, ?_, ?_, ?_⟩
    · show ∃ eL, G.elect n'.state.hard.term.val = some (k, eL) ∧ eL <+: fullLog G n'.state ∧ _
      rw [hst]; exact a
    · show ∃ L, G.leader n'.state.hard.term.val = some L ∧ L <+: fullLog G n'.state ∧ (n'.dirty = false → _)
      rw [hst, hd]; exact b
    · show ChainIn G (fullLog G n'.state); rw [hst]; exact c
    · show ∀ i (hi : i < (fullLog G n'.state).length) X, _; rw [hst]; exact d
  · intro hr
    have hr' : n'.role = .Leader := hr
    rcases hrole with h1 | ⟨h1, hm, hlo, hp, -⟩
    · rw [h1] at hr'; cases hr'
    · obtain ⟨a, b⟩ := hi.leader k (by rw [← h1]; exact hr')
      have a := a.resolve_right (tk_not_pending ids g C G k _ hidle.1)
      refine ⟨Or.inl (hlead.mpr a), ?_, ?_⟩
      · show ∀ i : Fin MAX, i.val ≠ n'.local.val → 0 < (n'.matched[i]).val →
          ∃ w : Fin K, n'.peers[i] = some ids[w] ∧ (w, n'.state.hard.term.val, (n'.matched[i]).val) ∈ G.acks
        rw [hm, hlo, hp, hst]; exact b.matched
      · show ∀ h : n'.local.val < MAX, (n'.matched[n'.local.val]'h).val ≤ (fullLog G n'.state).length
        rw [hm, hlo, hst]; exact b.own
  · intro hr
    have hr' : n'.role = .Candidate := hr
    rcases hrole with h1 | ⟨h1, -, hlo, hp, hv⟩
    · rw [h1] at hr'; cases hr'
    · have := hi.candidate k (by rw [← h1]; exact hr')
      unfold CandidateOk' at this ⊢
      show n'.state.hard.voted_for = some ids[k] ∧ (∀ e ∈ fullLog G n'.state, e.id.term.val < n'.state.hard.term.val) ∧
        ∀ i : Fin MAX, n'.votes[i] = true → i.val = n'.local.val ∨
          ∃ w : Fin K, n'.peers[i] = some ids[w] ∧ ∃ vlog, (n'.state.hard.term.val, w, k, vlog) ∈ G.ballots ∧
            upToDate (lastOf (fullLog G n'.state)) (lastOf vlog)
      rw [hst, hlo, hp, hv]; exact this
  · intro i o ho
    obtain ⟨⟨to, hto⟩, t, rfl⟩ := hout i o ho
    exact ⟨to, hto, trivial⟩
  · intro env h T last hfrom hm hc
    have hc' : n'.role = .Candidate ∧ n'.state.hard.term = T := hc
    show lastId n'.state = last
    rcases hrole with h1 | ⟨h1, -⟩
    · rw [h1] at hc'; cases hc'.1
    · have h2 := (hi.sent env h).2
      rw [hm] at h2
      rw [hst]
      exact (h2 k hfrom).2.1 ⟨by rw [← h1]; exact hc'.1, by rw [← hst]; exact hc'.2⟩
  · rcases (hi.committed k).2 with h | ⟨h, -⟩ | ⟨_, h, -⟩
    · left; show CommittedBy ids g G n'.state.hard.term.val _; rw [hst]; exact h
    · rw [hidle.1] at h; cases h
    · exact absurd h (tk_not_pending ids g C G k _ hidle.1)

private theorem tk_some_and {α : Type} (o : Option α) (f : α → Bool) (h : Rust.Option.is_some_and o f = true) :
    ∃ x, o = some x ∧ f x = true := by
  cases o with
  | none => simp [Rust.Option.is_some_and] at h
  | some x => exact ⟨x, rfl, h⟩

private theorem tk_preVotes_outbox (n : DNode V S MAX CAP) (t : Rust.u64) (j : Fin MAX) :
    (preVotesD n t).outbox[j] = if j.val ≠ n.local.val ∧ Rust.Option.is_some_and n.peers[j]
      (fun id => Membership.is_voter n.membership id) = true then some (.PreVote t) else n.outbox[j] := by
  simp [preVotesD, Fin.getElem_fin]

private theorem tk_bcast_outbox (n : DNode V S MAX CAP) (j : Fin MAX) :
    (bcastD n).outbox[j] = if j.val ≠ n.local.val ∧ Rust.Option.is_some_and n.peers[j]
      (fun id => Membership.contains n.membership id) = true then some .Replicate else n.outbox[j] := by
  simp [bcastD, Fin.getElem_fin]

private theorem tk_preVotes_self (n : DNode V S MAX CAP) (t : Rust.u64) (h : (preVotesD n t).local.val < MAX) :
    (preVotesD n t).outbox[(preVotesD n t).local.val] = n.outbox[n.local.val]'h := by
  have := tk_preVotes_outbox n t ⟨n.local.val, h⟩
  simp at this; exact this

private theorem tk_bcast_self (n : DNode V S MAX CAP) (h : (bcastD n).local.val < MAX) :
    (bcastD n).outbox[(bcastD n).local.val] = n.outbox[n.local.val]'h := by
  have := tk_bcast_outbox n ⟨n.local.val, h⟩
  simp at this; exact this

/-! ## Barrier -/

private theorem tk_refresh (x y : DNode V S MAX CAP) (hr : Refresh x y) :
    y.state = x.state ∧ y.dirty = x.dirty ∧ y.extra_reply = x.extra_reply ∧ (y.role = x.role ∨ y.role = .Follower) ∧
    ∀ i, SlotKept (memOf x.state x.bootstrap) x y i := by
  obtain ⟨n1, ⟨hshape, hkept, -⟩, -, hfin⟩ := hr
  obtain ⟨P, Vo, A, Nx, Mt, O, rfl⟩ : ∃ P Vo A Nx Mt O, n1 = { x with membership := memOf x.state x.bootstrap, peers := P, votes := Vo, active := A, «next» := Nx, matched := Mt, outbox := O } :=
    ⟨_, _, _, _, _, _, hshape⟩
  simp only at hfin
  rcases hfin with rfl | ⟨-, -, -, r, d, rfl⟩
  · exact ⟨rfl, rfl, rfl, Or.inl rfl, hkept⟩
  · exact ⟨rfl, rfl, rfl, Or.inr rfl, hkept⟩

private theorem tk_snapOk_same (g : Membership MAX) (G : Ghost (Record V MAX) K) (s s' : DState V S MAX CAP)
    (hsn : s'.snapshot = s.snapshot) (h : SnapOk g G s) : SnapOk g G s' := by
  unfold SnapOk at *
  have h1 : snapMem s' g = snapMem s g := by unfold snapMem memInit; rw [hsn]
  have h2 : boundary G s' = boundary G s := by unfold boundary; rw [base_of_snapshot _ _ hsn]
  rw [h1, h2]; exact h

/-- What a `barrier` does to a node, in terms of full logs and slots. -/
private theorem tk_barrier (g : Membership MAX) (G : Ghost (Record V MAX) K) (me : Id) (p n3 : DNode V S MAX CAP)
    (hdyn : DynOk g me p) (hs : StateOk G p.state) (hsn : SnapOk g G p.state) (hB : BarrierD p n3) :
    n3.state.hard.term = p.state.hard.term ∧ n3.state.hard.voted_for = p.state.hard.voted_for ∧
    n3.extra_reply = p.extra_reply ∧ (n3.role = p.role ∨ n3.role = .Follower) ∧ DynOk g me n3 ∧
    StateOk G n3.state ∧ SnapOk g G n3.state ∧
    (n3 = p ∨ (n3.dirty = true ∧ ∃ e : DEntry V MAX, e.id.term = p.state.hard.term ∧ e.value = none ∧
      fullLog G n3.state = fullLog G p.state ++ [e] ∧
      (∀ i : Fin MAX, (n3.peers[i] = p.peers[i] ∧ n3.outbox[i] = p.outbox[i] ∧
          (n3.matched[i]).val = if i.val = p.local.val then (fullLog G p.state).length + 1 else (p.matched[i]).val) ∨
        (n3.matched[i] = 0 ∧ n3.outbox[i] = none)) ∧
      (n3.state.hard.commit = p.state.hard.commit ∨
        (p.state.hard.commit.val < n3.state.hard.commit.val ∧
         ∃ hv : n3.state.hard.commit.val - 1 < (fullLog G n3.state).length,
          ((fullLog G n3.state)[n3.state.hard.commit.val - 1]).id.term = p.state.hard.term ∧
          Quorum (memOf p.state g) (fun id => ∃ i : Fin MAX, p.peers[i] = some id ∧
            n3.state.hard.commit.val ≤ (if i.val = p.local.val then (fullLog G p.state).length + 1 else (p.matched[i]).val)))))) := by
  rcases hB with rfl | ⟨s', idx, hidx, hterm, hr, hh, hsn', hl', hc', hA⟩
  · exact ⟨rfl, rfl, rfl, Or.inl rfl, hdyn, hs, hsn, Or.inl rfl⟩
  have hlen := fullLog_length G p.state hs
  have hfl : fullLog G s' = fullLog G p.state ++
      [{ id := { index := idx, term := p.state.hard.term }, value := none }] :=
    fullLog_append G p.state s' _ hsn' hr
  have hbase : s'.base = p.state.base := base_of_snapshot _ _ hsn'
  have hlast' : (lastId s').index.val = (lastId p.state).index.val + 1 := by
    rw [lastId_eq s' hc', lastId_eq p.state hs.contig, hbase, hr]; simp; omega
  have hs' : StateOk G s' := by
    refine ⟨hl', hc', ?_, ?_, ?_, ?_, ?_, ?_⟩
    · rw [hbase]; exact hs.base
    · rw [hsn', hbase]; exact hs.snapshot
    · rw [hfl]; intro e he
      rcases List.mem_append.mp he with he | he
      · rw [hh]; exact hs.terms e he
      · simp at he; subst he; simp [hh]
    · rw [hbase, hh]; exact hs.commit_ge
    · rw [hlast', hh]; have := hs.commit_le; omega
    · rw [hh]; exact hs.unvoted
  have hsn2 : SnapOk g G s' := tk_snapOk_same g G p.state s' hsn' hsn
  have hmem : memOf s' g = memOf p.state g := by
    unfold memOf
    have h1 : snapMem s' g = snapMem p.state g := by unfold snapMem memInit; rw [hsn']
    rw [h1, hr, cfgOf_snoc]; rfl
  have hdm : DynOk g me (ownAppendD p s' idx) := by
    refine dynOk_frame hdyn rfl rfl rfl rfl rfl rfl hmem hl' hc' ?_
    intro t ht; obtain ⟨a, b⟩ := hdyn.prevoting t ht
    exact ⟨a, by show t.val = s'.hard.term.val + 1; rw [hh]; exact b⟩
  have hmatch : ∀ i : Fin MAX, ((ownAppendD p s' idx).matched[i]).val =
      if i.val = p.local.val then (fullLog G p.state).length + 1 else (p.matched[i]).val := by
    intro i
    simp only [ownAppendD]
    by_cases hj : i.val = p.local.val
    · have hlt : p.local.val < MAX := by rw [← hj]; exact i.isLt
      simp [hlt, hj, hidx, hlen]
    · by_cases hlt : p.local.val < MAX
      · simp [hlt, hj, Ne.symm hj]
      · simp [hlt, hj]
  rcases hA with rfl | ⟨v, hQ, hlt, hid, hct⟩
  · refine ⟨by show s'.hard.term = _; rw [hh], by show s'.hard.voted_for = _; rw [hh], rfl, Or.inl rfl, hdm, hs', hsn2,
      Or.inr ⟨rfl, _, rfl, rfl, hfl, fun i => Or.inl ⟨rfl, rfl, hmatch i⟩, Or.inl (by show s'.hard.commit = _; rw [hh])⟩⟩
  obtain ⟨hlt', hR⟩ := hct.resolve_right (fun ⟨hn, _⟩ => hn hlt)
  have hct' : commitTo (ownAppendD p s' idx) v =
      { (ownAppendD p s' idx) with state := { s' with hard := { s'.hard with commit := v } }, dirty := true } := by
    rw [commitTo, if_pos hlt']; rfl
  rw [hct'] at hR
  obtain ⟨hst3, hd3, hex3, hrole3, hkept3⟩ := tk_refresh _ _ hR
  have hdyn3 : DynOk g me n3 := by
    refine dynOk_refresh { (ownAppendD p s' idx) with state := { s' with hard := { s'.hard with commit := v } }, dirty := true } n3 hdyn.n_pos hdyn.n_lt hdyn.cap_ge hdyn.cap_lt hdyn.hooks hdyn.bootstrap hdyn.id
      hdyn.heartbeat hdyn.election hdyn.election_le hl' hc' ?_ hR
    intro t ht; obtain ⟨a, b⟩ := hdyn.prevoting t ht
    exact ⟨a, by show t.val = s'.hard.term.val + 1; rw [hh]; exact b⟩
  have hfl2 : fullLog G ({ s' with hard := { s'.hard with commit := v } } : DState V S MAX CAP) = fullLog G s' :=
    fullLog_congr G _ _ rfl rfl
  have hcv : p.state.hard.commit < v := by
    have : s'.hard.commit < v := hlt
    rw [hh] at this; exact this
  obtain ⟨id, hid1, hid2⟩ := tk_some_and _ _ hid
  have hid1' : State.id_at s' v = some id := hid1
  rw [id_at_eq s' hl'] at hid1'
  have hv0 : 0 < v.val := by rw [Fin.lt_def] at hcv; omega
  obtain ⟨hvb, hvl, hvid⟩ := (idAt_fullLog G s' hs' v.val hv0 id).mp hid1'
  have hs2 : StateOk G ({ s' with hard := { s'.hard with commit := v } } : DState V S MAX CAP) := by
    refine ⟨hl', hc', hs'.base, hs'.snapshot, ?_, ?_, ?_, ?_⟩
    · rw [hfl2]; exact hs'.terms
    · show s'.base.index.val ≤ v.val; exact hvb
    · show v.val ≤ (lastId s').index.val
      have := fullLog_length G s' hs'; omega
    · exact hs'.unvoted
  have hc3 : n3.state.hard.commit = v := by rw [hst3]
  refine ⟨by rw [hst3]; show s'.hard.term = _; rw [hh], by rw [hst3]; show s'.hard.voted_for = _; rw [hh], hex3, hrole3,
    hdyn3, by rw [hst3]; exact hs2, by rw [hst3]; exact tk_snapOk_same g G s' _ rfl hsn2, Or.inr ⟨hd3, _, rfl, rfl,
    by rw [hst3, hfl2, hfl], ?_, Or.inr ⟨?_, ?_⟩⟩⟩
  · intro i
    rcases hkept3 i with ⟨h1, -, -, -, h5, h6⟩ | ⟨-, x, -, -, -, -, -, -, h7, h8⟩
    · left; exact ⟨h1, h6, by rw [h5]; exact hmatch i⟩
    · right; exact ⟨h7, h8⟩
  · rw [hc3]; rw [Fin.lt_def] at hcv; exact hcv
  · rw [hc3, hst3, hfl2]
    refine ⟨hvl, ?_, ?_⟩
    · rw [hvid]
      have : (id.term == s'.hard.term) = true := hid2
      rw [beq_iff_eq] at this; rw [this, hh]
    · have hQ' : Quorum (memOf p.state g) (fun id => v.val ≤ (matchOf (ownAppendD p s' idx) id).val) := by
        have := hQ; unfold QuorumAt at this; rw [show (ownAppendD p s' idx).membership = p.membership from rfl,
          hdyn.membership] at this; exact this
      refine quorum_mono _ _ _ ?_ hQ'
      intro x hx
      unfold matchOf at hx
      cases hpos : pos (ownAppendD p s' idx) x with
      | none => rw [hpos] at hx; simp at hx; omega
      | some i =>
        rw [hpos] at hx
        dsimp only at hx
        obtain ⟨hi, hpi⟩ := pos_lt _ x i hdyn.pre.n_lt hpos
        rw [getElem!_pos _ i.val hi] at hx hpi
        refine ⟨⟨i.val, hi⟩, hpi, ?_⟩
        have := hmatch ⟨i.val, hi⟩
        rw [← this]; exact hx

/-! ## A leader's heartbeat -/

private theorem tk_chain_noop (ids : Vector Id K) (g : Membership MAX) (G : Ghost (Record V MAX) K)
    (l : List (DEntry V MAX)) (e : DEntry V MAX) (he : e.value = none)
    (h : ChainIn (ids := ids) (g := g) G l) : ChainIn (ids := ids) (g := g) G (l ++ [e]) := by
  have hnc : ¬ isCfg e := by simp [isCfg, he, recCfg]
  obtain ⟨h1, h2⟩ := h
  constructor
  · intro i hi X hX
    by_cases hil : i < l.length
    · rw [List.getElem_append_left hil] at hX
      rw [List.take_append_of_le_length (by omega)]
      exact h1 i hil X hX
    · have : i = l.length := by simp at hi; omega
      subst this
      rw [List.getElem_append_right (by omega)] at hX
      simp [he, recCfg] at hX
  · intro k i hk hi hck hci
    by_cases hil : i < l.length
    · rw [List.getElem_append_left hil] at hci ⊢
      rw [List.getElem_append_left (by omega)] at hck
      rw [List.take_append_of_le_length (by omega)]
      exact h2 k i hk hil hck hci
    · have : i = l.length := by simp at hi; omega
      subst this
      rw [List.getElem_append_right (by omega)] at hci
      simp at hci; exact absurd hci hnc

private theorem tk_cfgs_noop (l : List (DEntry V MAX)) (e : DEntry V MAX) (he : e.value = none)
    (h : ∀ i (hi : i < l.length) X, recCfg (l[i]).value = some X → MemOk X) :
    ∀ i (hi : i < (l ++ [e]).length) X, recCfg ((l ++ [e])[i]).value = some X → MemOk X := by
  intro i hi X hX
  by_cases hil : i < l.length
  · rw [List.getElem_append_left hil] at hX; exact h i hil X hX
  · have : i = l.length := by simp at hi; omega
    subst this
    rw [List.getElem_append_right (by omega)] at hX
    simp [he, recCfg] at hX

/-- A leader `p` of node `k` (leading its term, or a pending win; idle outbox)
    running `barrier` then `broadcast` keeps its local clauses. -/
private theorem tk_lead (ids : Vector Id K) (g : Membership MAX) (C : World V S MAX CAP K)
    (G : Ghost (Record V MAX) K) (k : Fin K) (p n3 : DNode V S MAX CAP)
    (hdyn : DynOk g ids[k] p) (hr : p.role = .Leader) (hs : StateOk G p.state) (hsn : SnapOk g G p.state)
    (hterm : (C.disk k).hard.term.val ≤ p.state.hard.term.val)
    (hcons : Consistent G (fullLog G p.state) ∨ (p.dirty = true ∧ Leading G k p) ∨ PendingWin ids g C G k p)
    (hclean : p.dirty = false → p.state = C.disk k)
    (hacks : ∀ t j, (k, t, j) ∈ G.acks → ∀ j' ≤ j, Kept G k t j' (p.state.hard.term.val + 1) (fullLog G p.state))
    (helect : ∀ T eL, G.elect T = some (k, eL) → (C.disk k).hard.term.val < T → p.state.hard.term.val < T → False)
    (hballot : ∀ T c vlog, (T, k, c, vlog) ∈ G.ballots → p.state.hard.term.val = T →
      p.state.hard.voted_for = some ids[c])
    (hLP : LeadLog ids g G k p ∨ PendingWin ids g C G k p) (hlok : LeaderOk' ids G k p)
    (hout : ∀ j : Fin MAX, p.outbox[j] = none) (hex : p.extra_reply = none)
    (hcom : CommittedBy ids g G p.state.hard.term.val ((fullLog G p.state).take p.state.hard.commit.val))
    (hB : BarrierD p n3) : LocalOk' ids g C G k ⟨bcastD n3⟩ := by
  obtain ⟨ht3, hv3, hex3, hrole3, hdyn3, hs3, hsn3, hcase⟩ := tk_barrier g G ids[k] p n3 hdyn hs hsn hB
  have hnc : n3.role ≠ .Candidate := by rcases hrole3 with h | h <;> rw [h] <;> simp [hr]
  have hlenp := fullLog_length G p.state hs
  have hcle : p.state.hard.commit.val ≤ (fullLog G p.state).length := by have := hs.commit_le; omega
  have hslot : ∀ i (hi : i < MAX), p.peers[i] = some ids[k] ↔ i = p.local.val := hdyn.local_slot
  have hslot3 : ∀ i (hi : i < MAX), n3.peers[i] = some ids[k] ↔ i = n3.local.val := hdyn3.local_slot
  have hLead3 : Leading G k n3 ↔ Leading G k p := by unfold Leading; rw [ht3]
  have hchp : ChainIn (ids := ids) (g := g) G (fullLog G p.state) ∧
      ∀ i (hi : i < (fullLog G p.state).length) X, recCfg ((fullLog G p.state)[i]).value = some X → MemOk X := by
    rcases hLP with h | h
    · exact ⟨h.chain, h.cfgs⟩
    · exact ⟨h.2.2.2.2.2.2.2.2.1, h.2.2.2.2.2.2.2.2.2⟩
  have F1 : fullLog G p.state <+: fullLog G n3.state := by
    rcases hcase with rfl | ⟨-, e, -, -, hfl, -⟩
    · exact List.prefix_refl _
    · rw [hfl]; exact List.prefix_append _ _
  have F2 : ∀ i (h : i < (fullLog G n3.state).length), (fullLog G p.state).length ≤ i →
      ((fullLog G n3.state)[i]).id.term = p.state.hard.term := by
    rcases hcase with rfl | ⟨-, e, het, -, hfl, -⟩
    · intro i h hle; omega
    · intro i h hle
      have hi' : i < (fullLog G p.state ++ [e]).length := by rw [← hfl]; exact h
      rw [List.getElem_of_eq hfl h, List.getElem_append_right hle]
      simp at hi'
      simp [show i - (fullLog G p.state).length = 0 by omega, het]
  have F2' : ∀ (L : List (DEntry V MAX)),
      (∀ i (h : i < (fullLog G p.state).length), L.length ≤ i → ((fullLog G p.state)[i]).id.term = p.state.hard.term) →
      ∀ i (h : i < (fullLog G n3.state).length), L.length ≤ i → ((fullLog G n3.state)[i]).id.term = p.state.hard.term := by
    intro L hb i h hle
    by_cases hi : i < (fullLog G p.state).length
    · rw [← hb i hi hle]
      exact congrArg (fun x : DEntry V MAX => x.id.term) (List.IsPrefix.getElem F1 hi).symm
    · exact F2 i h (by omega)
  have F3 : n3.dirty = false → n3 = p := by
    rcases hcase with h | ⟨hd, -⟩
    · intro _; exact h
    · intro h; rw [hd] at h; cases h
  have F4 : ChainIn (ids := ids) (g := g) G (fullLog G n3.state) ∧
      ∀ i (hi : i < (fullLog G n3.state).length) X, recCfg ((fullLog G n3.state)[i]).value = some X → MemOk X := by
    rcases hcase with rfl | ⟨-, e, -, hev, hfl, -⟩
    · exact hchp
    · rw [hfl]; exact ⟨tk_chain_noop ids g G _ e hev hchp.1, tk_cfgs_noop _ e hev hchp.2⟩
  have hP3 : PendingWin ids g C G k p → PendingWin ids g C G k n3 := by
    rintro ⟨a1, -, a2, a3, a4, a5, a6, a7, -, -⟩
    refine ⟨?_, hnc, by rw [ht3]; exact a2, by rw [ht3]; exact a3, by rw [hv3]; exact a4, a5, a6.trans F1,
      by rw [ht3]; exact F2' _ a7, F4.1, F4.2⟩
    rcases hcase with rfl | ⟨hd, -⟩
    · exact a1
    · exact hd
  have hLP3 : Leading G k n3 ∨ PendingWin ids g C G k n3 := by
    rcases hLP with h | h
    · obtain ⟨eL, he, -⟩ := h.elected; exact Or.inl (hLead3.mpr ⟨eL, he⟩)
    · exact Or.inr (hP3 h)
  have hLP3' : Leading G k n3 ∨ PendingWin ids g (C.setLive k ⟨bcastD n3⟩) G k (bcastD n3) := by
    rw [pendingWin_setLive]; exact hLP3
  have F5 : ∀ i : Fin MAX, n3.outbox[i] = none := by
    rcases hcase with rfl | ⟨-, e, -, -, -, hslots, -⟩
    · exact hout
    · intro i
      rcases hslots i with ⟨-, ho, -⟩ | ⟨-, ho⟩
      · rw [ho]; exact hout i
      · exact ho
  have F6 : LeaderOk' ids G k n3 := by
    rcases hcase with rfl | ⟨-, e, -, -, hfl, hslots, -⟩
    · exact hlok
    constructor
    · intro i hil h0
      rcases hslots i with ⟨hp, -, hm⟩ | ⟨hm, -⟩
      · by_cases hip : i.val = p.local.val
        · exfalso
          have h1 : p.peers[i.val] = some ids[k] := (hslot i.val i.isLt).mpr hip
          have h2 : n3.peers[i.val] = some ids[k] := by
            have : n3.peers[i] = p.peers[i] := hp
            simp only [Fin.getElem_fin] at this; rw [this]; exact h1
          exact hil ((hslot3 i.val i.isLt).mp h2)
        · rw [if_neg hip] at hm
          obtain ⟨w, hw, ha⟩ := hlok.matched i hip (by rw [← hm]; exact h0)
          refine ⟨w, by rw [hp]; exact hw, ?_⟩
          rw [hm, ht3]; exact ha
      · rw [hm] at h0; simp at h0
    · intro h
      rcases hslots ⟨n3.local.val, h⟩ with ⟨hp, -, hm⟩ | ⟨hm, -⟩
      · by_cases hip : n3.local.val = p.local.val
        · rw [if_pos hip] at hm
          have : (n3.matched[n3.local.val]'h).val = (fullLog G p.state).length + 1 := hm
          rw [this, hfl]; simp
        · exfalso
          have h1 : n3.peers[n3.local.val]'h = some ids[k] := (hslot3 _ h).mpr rfl
          have h2 : p.peers[n3.local.val]'h = some ids[k] := by
            have : n3.peers[(⟨n3.local.val, h⟩ : Fin MAX)] = p.peers[(⟨n3.local.val, h⟩ : Fin MAX)] := hp
            simp only [Fin.getElem_fin] at this; rw [← this]; exact h1
          exact hip ((hslot _ h).mp h2)
      · have : n3.matched[n3.local.val]'h = 0 := hm
        rw [this]; simp
  have F7 : CommitOk' ids g (C.setLive k ⟨bcastD n3⟩) G k (bcastD n3) := by
    rcases hcase with rfl | ⟨hd3, e, het, hev, hfl, hslots, hc | ⟨hlt, hv, hvt, hq⟩⟩
    · exact Or.inl hcom
    · left
      show CommittedBy ids g G n3.state.hard.term.val ((fullLog G n3.state).take n3.state.hard.commit.val)
      rw [ht3, hc, hfl, List.take_append_of_le_length hcle]; exact hcom
    have hW : ∀ W : Ghost (Record V MAX) K, W.leader n3.state.hard.term.val = some (fullLog G n3.state) →
        (k, n3.state.hard.term.val, (fullLog G n3.state).length) ∈ W.acks → (∀ a ∈ G.acks, a ∈ W.acks) →
        CommittedBy ids g W n3.state.hard.term.val ((fullLog G n3.state).take n3.state.hard.commit.val) := by
      intro W hWl hWk hWa
      refine Or.inr ⟨n3.state.hard.term.val, n3.state.hard.commit.val, Nat.le_refl _,
        ⟨(fullLog G n3.state).length, by omega, by omega, fullLog G n3.state, hWl, Nat.le_refl _,
          ⟨hv, by rw [hvt, ht3]⟩, ?_⟩, ?_⟩
      · rw [List.take_length]
        have hcfg : cfgOf g (fullLog G n3.state) = memOf p.state g := by
          rw [hfl, cfgOf_snoc, hev, memOf_fullLog g G p.state hsn]; rfl
        rw [hcfg]
        refine quorum_mono _ _ _ ?_ hq
        intro id ⟨i, hpi, hle⟩
        by_cases hip : i.val = p.local.val
        · rw [if_pos hip] at hle
          have h1 : p.peers[i.val] = some ids[k] := (hslot i.val i.isLt).mpr hip
          have h2 : p.peers[i.val] = some id := hpi
          rw [h1] at h2
          refine ⟨k, Option.some.inj h2, (fullLog G n3.state).length, ?_, hWk⟩
          rw [hfl]; simp; omega
        · rw [if_neg hip] at hle
          obtain ⟨w, hw, ha⟩ := hlok.matched i hip (by omega)
          rw [hpi] at hw
          refine ⟨w, (Option.some.inj hw).symm, (p.matched[i]).val, hle, hWa _ ?_⟩
          rw [ht3]; exact ha
      · simp [Ghost.prefix, hWl]
    rcases hLP3 with hl | hpw
    · exact Or.inr (Or.inl ⟨hd3, hl, hW (withOwnD G k n3) (by simp [withOwnD]) (by simp [withOwnD])
        (fun a h => List.mem_cons_of_mem _ h)⟩)
    · exact Or.inr (Or.inr ⟨fullLog G (C.disk k), (pendingWin_setLive ids g C G k k _ _).mpr hpw, rfl,
        hW (winOwnD G k n3 _) (by simp [winOwnD]) (by simp [winOwnD]) (fun a h => List.mem_cons_of_mem _ h)⟩)
  refine
    { dyn := dynOk_frame hdyn3 rfl rfl rfl rfl rfl rfl rfl hdyn3.layout hdyn3.contig hdyn3.prevoting
      live := ⟨hs3, hsn3⟩
      consistent := ?_
      clean := ?_
      terms := by show _ ≤ n3.state.hard.term.val; rw [ht3]; exact hterm
      acks := by
        intro t j h j' hj'
        show Kept G k t j' (n3.state.hard.term.val + 1) (fullLog G n3.state)
        rw [ht3]; exact kept_of_prefix _ _ _ _ _ _ _ F1 (hacks t j h j' hj')
      ballots := by
        intro T c vlog h ht
        have ht' : n3.state.hard.term.val = T := ht
        show n3.state.hard.voted_for = some ids[c]
        rw [ht3] at ht'; rw [hv3]; exact hballot T c vlog h ht'
      ballot_cand := fun h => absurd h hnc
      elect := by
        intro T eL he hd hlt
        have hlt' : n3.state.hard.term.val < T := hlt
        rw [ht3] at hlt'; exact (helect T eL he hd hlt').elim
      elect_cand := fun T eL _ h => hnc h.1
      lead := ?_
      leader := fun _ => ⟨hLP3', F6.matched, F6.own⟩
      candidate := fun h => absurd h hnc
      outbox := ?_
      outbox_self := ?_
      extra := by intro to o h; have : n3.extra_reply = some (to, o) := h; rw [hex3, hex] at this; cases this
      votes := fun _ _ _ _ _ _ h => absurd h.1 hnc
      committed := F7 }
  · by_cases hd : n3.dirty = true
    · right
      rcases hLP3' with h | h
      · exact Or.inl ⟨hd, h⟩
      · exact Or.inr h
    · left
      have := F3 (by simpa using hd)
      subst this
      rcases hcons with h | ⟨h, -⟩ | h
      · exact h
      · exact absurd h hd
      · exact absurd h.1 hd
  · intro hd
    have hd' : n3.dirty = false := hd
    have := F3 hd'
    subst this
    exact hclean hd'
  · intro hl
    have hl' : Leading G k p := hLead3.mp hl
    have hlead : LeadLog ids g G k p := by
      rcases hLP with h | hpw
      · exact h
      · exfalso; obtain ⟨eL, he⟩ := hl'; rw [hpw.2.2.1] at he; cases he
    refine ⟨?_, ?_, F4.1, F4.2⟩
    · obtain ⟨eL, he, hp, hb⟩ := hlead.elected
      refine ⟨eL, by show G.elect n3.state.hard.term.val = _; rw [ht3]; exact he, hp.trans F1, ?_⟩
      intro i h hle
      show ((fullLog G n3.state)[i]).id.term = n3.state.hard.term
      rw [ht3]; exact F2' eL hb i h hle
    · obtain ⟨L, hL, hLp, hLd⟩ := hlead.log
      refine ⟨L, by show G.leader n3.state.hard.term.val = _; rw [ht3]; exact hL, hLp.trans F1, ?_⟩
      intro hd
      have hd' : n3.dirty = false := hd
      have := F3 hd'
      subst this
      exact hLd hd'
  · intro i o ho
    have ho' : (bcastD n3).outbox[i] = some o := ho
    rw [tk_bcast_outbox] at ho'
    split at ho'
    · rename_i hc
      cases ho'
      obtain ⟨x, hx, -⟩ := tk_some_and _ _ hc.2
      refine ⟨x, hx, ?_⟩
      simp only [OutOk, setLive_self']
      exact hLP3'
    · rw [F5 i] at ho'; cases ho'
  · intro h o ho
    have := (tk_bcast_self n3 h).trans (F5 ⟨n3.local.val, h⟩)
    have ho' : (bcastD n3).outbox[(bcastD n3).local.val]'h = some o := ho
    rw [this] at ho'; cases ho'

/-! ## Election safety for a self-elected node -/

private theorem tk_lcp {α : Type} : ∀ (l1 l2 : List α), ∃ a, a ≤ l1.length ∧ a ≤ l2.length ∧
    l1.take a = l2.take a ∧ ∀ q, q <+: l1 → q <+: l2 → q.length ≤ a
  | [], _ => ⟨0, by simp, by simp, by simp, fun q h1 _ => by have := h1.length_le; simpa using this⟩
  | _ :: _, [] => ⟨0, by simp, by simp, by simp, fun q _ h2 => by have := h2.length_le; simpa using this⟩
  | x :: xs, y :: ys => by
    by_cases hxy : x = y
    · subst hxy
      obtain ⟨a, h1, h2, h3, h4⟩ := tk_lcp xs ys
      refine ⟨a + 1, by simp; omega, by simp; omega, by simp [h3], ?_⟩
      intro q hq1 hq2
      cases q with
      | nil => simp
      | cons z zs =>
        rw [List.cons_prefix_cons] at hq1 hq2
        have := h4 zs hq1.2 hq2.2
        simp; omega
    · refine ⟨0, by simp, by simp, by simp, ?_⟩
      intro q hq1 hq2
      cases q with
      | nil => simp
      | cons z zs =>
        rw [List.cons_prefix_cons] at hq1 hq2
        exact absurd (hq1.1.symm.trans hq2.1) hxy

private theorem tk_min (P : Nat → Prop) (n : Nat) (h : P n) : ∃ m, P m ∧ ∀ m' < m, ¬ P m' := by
  induction n using Nat.strongRecOn with
  | _ n ih =>
    by_cases hx : ∃ m' < n, P m'
    · obtain ⟨m', hm', hp⟩ := hx; exact ih m' hm' hp
    · exact ⟨n, h, fun m' hm' hp => hx ⟨m', hm', hp⟩⟩

/-- A quorum of the configuration of a consistent log of terms below `T`, whose
    members kept every acknowledged prefix in that log, meets the voters of the
    election of term `T`. -/
private theorem tk_inter (ids : Vector Id K) (g : Membership MAX) (hid : ∀ a b : Fin K, ids[a] = ids[b] → a = b)
    (G : Ghost (Record V MAX) K) (hw : Wf ids g G) (T : Nat) (c : Fin K) (eL' : List (DEntry V MAX))
    (he : G.elect T = some (c, eL')) (l : List (DEntry V MAX)) (hl : Consistent G l)
    (hlt : ∀ e ∈ l, e.id.term.val < T) (P : Id → Prop) (hP : Quorum (cfgOf g l) P)
    (hkept : ∀ id, P id → ∃ w : Fin K, ids[w] = id ∧
      ∀ t j', (w, t, j') ∈ G.acks → t < T → ∀ j ≤ j', Kept G w t j T l) :
    ∃ id, P id ∧ Voters ids G T c eL' id := by
  obtain ⟨hT0, hcons', hlt', hquo'⟩ := hw.elect T c eL' he
  obtain ⟨a, hal, hal', hta, hmax⟩ := tk_lcp l eL'
  have hch := chain_of_consistent G hw l hl
  have hch' := chain_of_consistent G hw eL' hcons'
  have hnear1 : Near (cfgOf g (l.take a)) (cfgOf g l) := by
    apply near_tail l a hch.1
    intro k1 k2 hk2 h1 h12 hc1 hc2
    rcases hch.2 k1 k2 h12 hk2 hc1 hc2 with h0 | ⟨t, j, ht, hc, hp⟩
    · have := congrArg List.length h0; simp only [List.length_take, List.length_nil] at this; omega
    · have hk2T : (l[k2]).id.term.val < T := hlt _ (List.getElem_mem _)
      have hpe := hp.trans (leader_complete hid G hw T c eL' he t j (by omega) hc)
      have := hmax _ (List.take_prefix _ _) hpe
      simp at this; omega
  by_cases hex : ∃ k1 k2, ∃ (h2 : k2 < eL'.length) (h12 : k1 < k2), a ≤ k1 ∧ isCfg (eL'[k1]'(by omega)) ∧ isCfg eL'[k2]
  · exfalso
    obtain ⟨k1, k2, hk2, h12, hak, hc1, hc2⟩ := hex
    obtain ⟨m, ⟨hm2, ham, hmk2, hcm⟩, hmin⟩ := tk_min
      (fun m => ∃ hm : m < eL'.length, a ≤ m ∧ m < k2 ∧ isCfg (eL'[m]'hm)) k1 ⟨by omega, hak, h12, hc1⟩
    have hnoc : ∀ i (hi : i < eL'.length), a ≤ i → i < m → ¬ isCfg eL'[i] :=
      fun i hi h1 h2 hc => hmin i h2 ⟨hi, h1, by omega, hc⟩
    have hcb := hch'.2 m k2 hmk2 hk2 hcm hc2
    have hne : eL'.take (m + 1) ≠ [] := by
      intro h0; have := congrArg List.length h0; simp only [List.length_take, List.length_nil] at this; omega
    have hk2T : (eL'[k2]).id.term.val < T := hlt' _ (List.getElem_mem _)
    obtain ⟨t', j', n', L', ht', hca, hL', hpL', hnear⟩ := hw.good _ _ hcb hne
    have hdrop : (eL'.take (m + 1)).dropLast = eL'.take m := by
      rw [List.dropLast_eq_take]; simp only [List.length_take]; rw [List.take_take]; congr 1; omega
    rw [hdrop] at hnear
    have hcm' : cfgOf g (eL'.take m) = cfgOf g (l.take a) := by
      rw [cfgOf_take_noCfg g eL' a m ham hnoc, hta]
    rw [hcm'] at hnear
    obtain ⟨hj'0, hjn', Lw, hLw, hnL, hterm', hquo⟩ := hca
    rw [hL'] at hLw; cases hLw
    obtain ⟨id, hPid, w, hw1, j'', hj'', hack⟩ := near_inter _ _ _ hnear1 hnear P _ hP hquo
    obtain ⟨w0, hw0, hk⟩ := hkept id hPid
    obtain rfl : w0 = w := hid w0 w (hw0.trans hw1.symm)
    have ht'T : t' < T := by omega
    have hpl : G.prefix t' j' <+: l := by
      rcases hk t' j'' hack ht'T j' hj'' with hp | ⟨t'', h1, h2, c'', eL'', he'', -, hnot⟩
      · exact hp
      · exact absurd (leader_complete hid G hw t'' c'' eL'' he'' t' j' h1
          ⟨n', hj'0, hjn', L', hL', hnL, hterm', hquo⟩) hnot
    rw [prefix_eq_take G t' j' L' hL'] at hpl
    have := hmax _ (hpL'.trans hpl) (List.take_prefix _ _)
    simp at this; omega
  · have hnear2 : Near (cfgOf g (eL'.take a)) (cfgOf g eL') := by
      apply near_tail eL' a hch'.1
      intro k1 k2 hk2 h1 h12 hc1 hc2
      exact hex ⟨k1, k2, hk2, h12, h1, hc1, hc2⟩
    rw [← hta] at hnear2
    exact near_inter _ _ _ hnear1 hnear2 P _ hP hquo'

/-! ## Campaigns -/

private theorem tk_stateOk_term (G : Ghost (Record V MAX) K) (s : DState V S MAX CAP) (hs : StateOk G s)
    (T : Rust.u64) (hT : s.hard.term.val < T.val) (v : Option Id) :
    StateOk G { s with hard := { s.hard with term := T, voted_for := v } } := by
  have hfl : fullLog G ({ s with hard := { s.hard with term := T, voted_for := v } } : DState V S MAX CAP) =
      fullLog G s := fullLog_congr G _ _ rfl rfl
  refine ⟨hs.layout, hs.contig, hs.base, hs.snapshot, ?_, hs.commit_ge, hs.commit_le, ?_⟩
  · rw [hfl]; intro e he; have := hs.terms e he; show _ ≤ T.val; omega
  · intro h0; have : T.val = 0 := h0; omega

private theorem tk_voted_self (n : DNode V S MAX CAP) (hMAX : MAX < 2 ^ Rust.usizeBits) (me : Id)
    (hslot : ∀ i (hi : i < MAX), n.peers[i] = some me ↔ i = n.local.val)
    (hv : ∀ i : Fin MAX, n.votes[i] = true → i.val = n.local.val) (id : Id) (h : votedBy n id = true) : id = me := by
  unfold votedBy at h
  cases hpos : pos n id with
  | none => rw [hpos] at h; simp at h
  | some i =>
    rw [hpos] at h
    dsimp only at h
    obtain ⟨hi, hpi⟩ := pos_lt n id i hMAX hpos
    rw [getElem!_pos _ i.val hi] at h hpi
    have h2 := (hslot i.val hi).mpr (hv ⟨i.val, hi⟩ h)
    rw [h2] at hpi
    exact (Option.some.inj hpi).symm

private theorem tk_leaderInit_matched (n : DNode V S MAX CAP) (i : Fin MAX) :
    ((leaderInitD n).matched[i]).val = if i.val = n.local.val then (lastId n.state).index.val else 0 := by
  simp only [leaderInitD]
  by_cases hj : i.val = n.local.val
  · have hlt : n.local.val < MAX := hj ▸ i.isLt
    simp [hlt, hj, Rust.Slice.fill]
  · by_cases hlt : n.local.val < MAX <;> simp [hlt, hj, Ne.symm hj, Rust.Slice.fill]

private theorem tk_leaderInit_own (n : DNode V S MAX CAP) (h : (leaderInitD n).local.val < MAX) :
    ((leaderInitD n).matched[(leaderInitD n).local.val]'h).val = (lastId n.state).index.val := by
  have := tk_leaderInit_matched n ⟨n.local.val, h⟩
  simp at this; exact this

variable (ids : Vector Id K) (g : Membership MAX) (hid : ∀ a b : Fin K, ids[a] = ids[b] → a = b) (hg : MemOk g)

include hid hg in
theorem preserve_tick (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (hi : Inv ids g C G) (k : Fin K)
    (r : Rust.Result Unit Error) (c : Jarl.Cluster V S MAX CAP) (h : Cluster.tick (C.live k) = pure (r, c)) :
    ∃ G', Extends G G' ∧ Inv ids g (C.setLive k c) G' := by
  obtain ⟨n', hn', rfl⟩ := tk_cluster _ _ r h
  have hdk := hi.dyn k
  cases tick_rel' _ hdk.pre r n' hn' with
  | same =>
    have : (⟨(C.live k).node⟩ : Jarl.Cluster V S MAX CAP) = C.live k := rfl
    exact ⟨G, Extends.refl G, by rw [this, tk_setLive_same]; exact hi⟩
  | time n'' hidle hto =>
    obtain ⟨e, a, q, act, rfl⟩ := hto
    refine ⟨G, Extends.refl G, setLive_inv' ids g C G hi k _ (tk_quiet ids g C G hi k hidle _
      (dynOk_frame hdk rfl rfl rfl rfl rfl rfl rfl hdk.layout hdk.contig hdk.prevoting) rfl rfl
      (Or.inr ⟨rfl, rfl, rfl, rfl, rfl⟩) ?_ (fun h => hidle.2.2 ⟨_, h⟩) hidle.2.1)⟩
    intro i o ho
    have : (C.node k).outbox[i] = some o := ho
    rw [hidle.2.2 i] at this; cases this
  | stepdown n0 n'' hidle hl hto htm =>
    obtain ⟨e, a, q, act, rfl⟩ := hto
    obtain ⟨r', d, rfl⟩ := htm
    refine ⟨G, Extends.refl G, setLive_inv' ids g C G hi k _ (tk_quiet ids g C G hi k hidle _
      (dynOk_frame hdk rfl rfl rfl rfl rfl rfl rfl hdk.layout hdk.contig (by intro t ht; cases ht)) rfl rfl
      (Or.inl rfl) ?_ (fun h => hidle.2.2 ⟨_, h⟩) hidle.2.1)⟩
    intro i o ho
    have : (C.node k).outbox[i] = some o := ho
    rw [hidle.2.2 i] at this; cases this
  | heartbeat n0 n2 hidle hl hto hB =>
    obtain ⟨e, a, q, act, rfl⟩ := hto
    have hlk := hi.leader k hl
    have hld := hi.lead k (hlk.1.resolve_right (tk_not_pending ids g C G k _ hidle.1))
    refine ⟨G, Extends.refl G, setLive_inv' ids g C G hi k _ (tk_lead ids g C G k { C.node k with elapsed := e, leader_age := a, quorum_elapsed := q, active := act } n2
      (dynOk_frame hdk rfl rfl rfl rfl rfl rfl rfl hdk.layout hdk.contig hdk.prevoting) hl (hi.live k).1 (hi.live k).2
      (hi.terms k) (hi.consistent_live k) (hi.clean k) (fun t j h j' hj' => ((hi.acks k t j h).2.2 j' hj').1) ?_
      (fun T c v h => (hi.ballots T k c v h).2.2.2) (Or.inl ⟨hld.elected, hld.log, hld.chain, hld.cfgs⟩)
      ⟨hlk.2.matched, hlk.2.own⟩ hidle.2.2 hidle.2.1 ?_ hB)⟩
    · intro T eL he hd hlt; exact ((hi.elect T k eL he hd).2.2.2 hlt).2.1 hl
    · rcases (hi.committed k).2 with h1 | ⟨hd, -⟩ | ⟨_, hpw, -⟩
      · exact h1
      · rw [hidle.1] at hd; cases hd
      · exact absurd hpw (tk_not_pending ids g C G k _ hidle.1)
  | prevote n0 n2 n'' hloc ht hidle hrl hvoter hto htm hcase =>
    obtain ⟨e, a, q, act, rfl⟩ := hto
    obtain ⟨r', d, rfl⟩ := htm
    rcases hcase with ⟨hQ, hC⟩ | ⟨hN, rfl⟩
    · have hs0 := (hi.live k).1
      have hcl := hi.clean k hidle.1
      have hdt : (C.disk k).hard.term.val = (C.node k).state.hard.term.val := by rw [hcl]
      have hq0 : Quorum (cfgOf g (fullLog G (C.node k).state)) (fun id => id = ids[k]) := by
        rw [← memOf_fullLog g G _ (hi.live k).2, ← hdk.membership]
        refine quorum_mono _ _ _ ?_ hQ
        intro id hv
        refine tk_voted_self _ hdk.pre.n_lt ids[k] ?_ ?_ id hv
        · exact hdk.local_slot
        intro i hvi
        have : ((Rust.Slice.fill (C.node k).votes false).set (C.node k).local.val true hloc)[i] = true := hvi
        simp only [Rust.Slice.fill, Fin.getElem_fin, Vector.getElem_set, Vector.getElem_replicate] at this
        split at this
        · rename_i h; exact h.symm
        · cases this
      obtain ⟨h', n1, htm1, ⟨hQ1, hBL⟩ | ⟨hN1, rfl⟩⟩ := hC
      · obtain ⟨n3, hB, rfl⟩ := hBL
        obtain ⟨r1, d1, rfl⟩ := htm1
        have hcons0 : Consistent G (fullLog G (C.node k).state) := by
          rcases hi.consistent_live k with h | ⟨h, -⟩ | h
          · exact h
          · rw [hidle.1] at h; cases h
          · exact absurd h (tk_not_pending ids g C G k _ hidle.1)
        have hLt : ∀ x ∈ fullLog G (C.node k).state, x.id.term.val < (C.node k).state.hard.term.val + 1 := by
          intro x hx; have := hs0.terms x hx; omega
        have hnone : G.elect ((C.node k).state.hard.term.val + 1) = none := by
          cases hel : G.elect ((C.node k).state.hard.term.val + 1) with
          | none => rfl
          | some x =>
            exfalso
            obtain ⟨c, eL⟩ := x
            by_cases hck : c = k
            · subst hck; have := hi.elect_disk _ c eL hel; omega
            · obtain ⟨id, rfl, w, hw, vlog, hb, -⟩ := tk_inter ids g hid G hi.wf _ c eL hel _ hcons0 hLt _ hq0 (by
                intro id hid'
                exact ⟨k, hid'.symm, fun t j' ha _ j hj => ((hi.acks k t j' ha).2.2 j hj).1⟩)
              obtain rfl : w = k := hid w k hw
              rcases (hi.ballots _ w c vlog hb).1 with h1 | ⟨h1, -⟩
              · omega
              · exact hck h1.symm
        have hsp : StateOk G { (C.node k).state with hard := { (C.node k).state.hard with term := ⟨(C.node k).state.hard.term.val + 1, ht⟩, voted_for := some (C.node k).config.id } } :=
          tk_stateOk_term G _ hs0 _ (by show _ < _ + 1; omega) _
        have hflp : fullLog G ({ (C.node k).state with hard := { (C.node k).state.hard with term := ⟨(C.node k).state.hard.term.val + 1, ht⟩, voted_for := some (C.node k).config.id } } : DState V S MAX CAP) = fullLog G (C.node k).state :=
          fullLog_congr G _ _ rfl rfl
        have hP : ∀ p : DNode V S MAX CAP, p.dirty = true → p.role ≠ .Candidate →
            p.state = { (C.node k).state with hard := { (C.node k).state.hard with term := ⟨(C.node k).state.hard.term.val + 1, ht⟩, voted_for := some (C.node k).config.id } } →
            PendingWin ids g C G k p := by
          intro p hd hrc hps
          unfold PendingWin
          rw [hps, hd, hflp, ← hcl]
          refine ⟨rfl, hrc, hnone, rfl, by rw [hdk.id], hq0, List.prefix_refl _, fun i h hle => by omega,
            chain_of_consistent G hi.wf _ hcons0, ?_⟩
          intro i hi' X hX
          obtain ⟨-, L, hL, hp⟩ := hcons0 i hi'
          have hiL : i < L.length := by have := hp.length_le; simp at this; omega
          have hget : L[i] = (fullLog G (C.node k).state)[i] := by
            have := List.IsPrefix.getElem hp (show i < ((fullLog G (C.node k).state).take (i + 1)).length by simp; omega)
            simp at this; exact this.symm
          exact hi.cfgs _ L hL i hiL X (by rw [hget]; exact hX)
        refine ⟨G, Extends.refl G, setLive_inv' ids g C G hi k _ ?_⟩
        refine tk_lead ids g C G k _ n3 ?_ ?_ ?_ ?_ ?_ ?_ ?_ ?_ ?_ ?_ ?_ ?_ ?_ ?_ ?_ hB
        · exact dynOk_frame hdk rfl rfl rfl rfl rfl rfl rfl hdk.layout hdk.contig (by intro t h; cases h)
        · rfl
        · exact hsp
        · exact tk_snapOk_same g G _ _ rfl (hi.live k).2
        · show _ ≤ _ + 1; omega
        · exact Or.inr (Or.inr (hP _ rfl (fun h => by cases h) rfl))
        · intro h; cases h
        · intro t j h j' hj'
          have := ((hi.acks k t j h).2.2 j' hj').1
          show Kept G k t j' (_ + 1 + 1) _
          erw [hflp]
          exact kept_mono_bound _ _ _ _ _ _ _ (by omega) this
        · intro T eL he hd hlt
          have := hi.elect_disk T k eL he
          omega
        · intro T c vlog hb hT
          have hT' : (C.node k).state.hard.term.val + 1 = T := hT
          rcases (hi.ballots T k c vlog hb).1 with h1 | ⟨rfl, -⟩
          · omega
          · show some (C.node k).config.id = some ids[k]; rw [hdk.id]
        · exact Or.inr (hP _ rfl (fun h => by cases h) rfl)
        · constructor
          · intro i hil h0
            rw [tk_leaderInit_matched] at h0
            split at h0
            · rename_i hh; exact absurd hh hil
            · omega
          · intro h
            rw [tk_leaderInit_own]; erw [hflp]; rw [fullLog_length G _ hs0]; exact Nat.le_refl _
        · exact hidle.2.2
        · exact hidle.2.1
        · rcases (hi.committed k).2 with h1 | ⟨hd, -⟩ | ⟨_, hpw, -⟩
          · show CommittedBy ids g G ((C.node k).state.hard.term.val + 1) _
            erw [hflp]
            exact committedBy_mono_term G _ _ (by omega) _ h1
          · rw [hidle.1] at hd; cases hd
          · exact absurd hpw (tk_not_pending ids g C G k _ hidle.1)
      · exfalso; apply hN1
        obtain ⟨r1, d1, rfl⟩ := htm1
        refine quorum_mono _ _ _ ?_ hQ
        intro id h; exact h
    · refine ⟨G, Extends.refl G, setLive_inv' ids g C G hi k _ (tk_quiet ids g C G hi k hidle _
        (dynOk_frame hdk rfl rfl rfl rfl rfl rfl rfl hdk.layout hdk.contig ?_) rfl rfl
        (Or.inl rfl) ?_ ?_ hidle.2.1)⟩
      · intro t ht; cases ht; exact ⟨rfl, rfl⟩
      · intro i o ho
        have ho' := ho
        rw [tk_preVotes_outbox] at ho'
        split at ho'
        · rename_i hc
          cases ho'
          obtain ⟨x, hx, -⟩ := tk_some_and _ _ hc.2
          exact ⟨⟨x, hx⟩, _, rfl⟩
        · have : (C.node k).outbox[i] = some o := ho'
          rw [hidle.2.2 i] at this; cases this
      · intro hlt
        exact (tk_preVotes_self _ _ hlt).trans (hidle.2.2 ⟨(C.node k).local.val, hlt⟩)

end Jarl.Engine.Dyn
