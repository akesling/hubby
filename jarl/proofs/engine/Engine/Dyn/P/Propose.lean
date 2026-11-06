import Engine.Dyn.Common

/-!
# Preservation: proposals, compaction and membership changes
-/

set_option linter.unusedSectionVars false

namespace Jarl.Engine.Dyn
open Jarl Jarl.Engine

variable {V S : Type} {MAX CAP K : Nat} [Rust.Clone V] [Rust.Clone S]
/-! ## Helpers -/

theorem pp_cfgOf_cases (g : Membership MAX) (l : List (DEntry V MAX)) :
    cfgOf g l = g ∨ ∃ i, ∃ h : i < l.length, recCfg l[i].value = some (cfgOf g l) := by
  induction l generalizing g with
  | nil => exact Or.inl rfl
  | cons e l ih =>
    have he : cfgOf g (e :: l) = cfgOf ((recCfg e.value).getD g) l := rfl
    rcases ih ((recCfg e.value).getD g) with h | ⟨i, hi, h⟩
    · cases hr : recCfg e.value with
      | none => left; rw [he, h, hr]; rfl
      | some X =>
        right; refine ⟨0, by simp, ?_⟩
        rw [he, h, hr]; simpa using hr
    · right; refine ⟨i + 1, by simp; omega, ?_⟩
      rw [he]; simpa using h

theorem pp_setLive_same (C : World V S MAX CAP K) (k : Fin K) (c : Jarl.Cluster V S MAX CAP)
    (hc : c.node = C.node k) : C.setLive k c = C := by
  have hc' : c = C.live k := by cases c; cases h : C.live k; simp_all [World.node]
  subst hc'
  cases C with
  | mk live disk sent =>
    simp only [World.setLive, World.mk.injEq, and_true]
    funext j; by_cases hj : j = k
    · subst hj; simp
    · simp [hj]

theorem pp_refresh_fields {n n' : DNode V S MAX CAP} (h : Refresh n n') :
    n'.state = n.state ∧ n'.dirty = n.dirty ∧ n'.extra_reply = n.extra_reply ∧ n'.config = n.config ∧
    n'.hooks = n.hooks ∧ n'.bootstrap = n.bootstrap ∧
    ((n'.role = n.role ∧ n'.prevoting = n.prevoting) ∨ (n'.role = .Follower ∧ n'.prevoting = none)) ∧
    ∀ i : Fin MAX, SlotKept (memOf n.state n.bootstrap) n n' i := by
  obtain ⟨n1, ⟨hshape, hkept, -⟩, -, hfin⟩ := h
  obtain ⟨P, Vo, A, Nx, Mt, O, rfl⟩ : ∃ P Vo A Nx Mt O, n1 = { n with membership := memOf n.state n.bootstrap, peers := P, votes := Vo, active := A, «next» := Nx, matched := Mt, outbox := O } :=
    ⟨_, _, _, _, _, _, hshape⟩
  simp only at hfin
  rcases hfin with rfl | ⟨-, -, -, r, d, rfl⟩
  · exact ⟨rfl, rfl, rfl, rfl, rfl, rfl, Or.inl ⟨rfl, rfl⟩, hkept⟩
  · exact ⟨rfl, rfl, rfl, rfl, rfl, rfl, Or.inr ⟨rfl, rfl⟩, hkept⟩

/-- Appending entries of the current term keeps a checkpoint's facts. -/
theorem pp_stateOk_append (G : Ghost (Record V MAX) K) (s s' : DState V S MAX CAP) (l : List (DEntry V MAX))
    (h : StateOk G s) (hs : s'.snapshot = s.snapshot) (hh : s'.hard = s.hard) (hr : ret s' = ret s ++ l)
    (hl' : Layout s') (hc' : Contig s') (hl : ∀ e ∈ l, e.id.term = s.hard.term) : StateOk G s' := by
  have hb := base_of_snapshot s s' hs
  refine ⟨hl', hc', ?_, ?_, ?_, ?_, ?_, ?_⟩
  · rw [hb]; exact h.base
  · rw [hs, hb]; exact h.snapshot
  · rw [fullLog_append G s s' l hs hr, hh]
    intro e he
    rcases List.mem_append.mp he with he | he
    · exact h.terms e he
    · rw [hl e he]; exact Nat.le_refl _
  · rw [hb, hh]; exact h.commit_ge
  · have := h.commit_le
    rw [hh, lastId_eq s' hc', hr, hb]
    rw [lastId_eq s h.contig] at this
    simp only [List.length_append]; omega
  · rw [hh]; exact h.unvoted

theorem pp_snapOk_append (g : Membership MAX) (G : Ghost (Record V MAX) K) (s s' : DState V S MAX CAP)
    (h : SnapOk g G s) (hs : s'.snapshot = s.snapshot) : SnapOk g G s' := by
  unfold SnapOk snapMem memInit at *
  have hb := base_of_snapshot s s' hs
  rw [hs]; unfold boundary at *; rw [hb]; exact h

variable (ids : Vector Id K) (g : Membership MAX)

/-- A log extended by entries without configuration keeps its chain. -/
theorem pp_chain_plain (G : Ghost (Record V MAX) K) (F0 l : List (DEntry V MAX))
    (hch : ChainIn (ids := ids) (g := g) G F0) (hl : ∀ e ∈ l, recCfg e.value = none) :
    ChainIn (ids := ids) (g := g) G (F0 ++ l) := by
  obtain ⟨h1, h2⟩ := hch
  constructor
  · intro i hi X hX
    by_cases hlt : i < F0.length
    · rw [List.getElem_append_left hlt] at hX
      rw [List.take_append_of_le_length (by omega)]
      exact h1 i hlt X hX
    · rw [List.getElem_append_right (by omega)] at hX
      rw [hl _ (List.getElem_mem _)] at hX; cases hX
  · intro k i hk hi hck hci
    by_cases hlt : i < F0.length
    · rw [List.getElem_append_left hlt] at hci ⊢
      rw [List.getElem_append_left (by omega)] at hck
      rw [List.take_append_of_le_length (by omega)]
      exact h2 k i hk hlt hck hci
    · rw [List.getElem_append_right (by omega)] at hci
      simp [isCfg, hl _ (List.getElem_mem _)] at hci

/-- A log extended by one configuration record that is a step from its
    configuration, with every earlier configuration record committed. -/
theorem pp_chain_cfg (G : Ghost (Record V MAX) K) (F0 : List (DEntry V MAX)) (e : DEntry V MAX) (X : Membership MAX)
    (hch : ChainIn (ids := ids) (g := g) G F0) (he : recCfg e.value = some X) (hstep : Step (cfgOf g F0) X)
    (hcom : ∀ k (hk : k < F0.length), isCfg F0[k] → CommittedBy ids g G e.id.term.val (F0.take (k + 1))) :
    ChainIn (ids := ids) (g := g) G (F0 ++ [e]) := by
  obtain ⟨h1, h2⟩ := hch
  constructor
  · intro i hi X' hX
    by_cases hlt : i < F0.length
    · rw [List.getElem_append_left hlt] at hX
      rw [List.take_append_of_le_length (by omega)]
      exact h1 i hlt X' hX
    · have hi' : i = F0.length := by simp at hi; omega
      subst hi'
      rw [List.getElem_append_right (by omega)] at hX
      simp only [Nat.sub_self, List.getElem_cons_zero] at hX
      rw [he] at hX; cases hX
      rw [List.take_append_of_le_length (Nat.le_refl _), List.take_length]
      exact hstep
  · intro k i hk hi hck hci
    by_cases hlt : i < F0.length
    · rw [List.getElem_append_left hlt] at hci ⊢
      rw [List.getElem_append_left (by omega)] at hck
      rw [List.take_append_of_le_length (by omega)]
      exact h2 k i hk hlt hck hci
    · have hi' : i = F0.length := by simp at hi; omega
      subst hi'
      rw [List.getElem_append_right (by omega)]
      simp only [Nat.sub_self, List.getElem_cons_zero]
      rw [List.getElem_append_left hk] at hck
      rw [List.take_append_of_le_length (by omega)]
      exact hcom k hk hck

/-- The ghost once node `k` acknowledges `F` as the leader log of term `T`. -/
def ppOwnG (G : Ghost (Record V MAX) K) (k : Fin K) (T : Nat) (F : List (DEntry V MAX)) : Ghost (Record V MAX) K :=
  { G with acks := (k, T, F.length) :: G.acks, leader := fun t => if t = T then some F else G.leader t }

/-- A leader node of term `T` in the middle of a proposal: its full log is `F`. -/
structure PPQ (G : Ghost (Record V MAX) K) (k : Fin K) (T : Rust.u64) (vf : Option Id) (F : List (DEntry V MAX))
    (n : DNode V S MAX CAP) : Prop where
  hooks : n.hooks = some hooksC
  boot : n.bootstrap = g
  cid : n.config.id = ids[k]
  hb : 0 < n.config.heartbeat_ticks.val
  he : n.config.heartbeat_ticks.val < n.config.election_ticks.val
  hel : n.config.election_ticks.val ≤ 2 ^ 63
  pv : ∀ t, n.prevoting = some t → n.role = .Follower ∧ t.val = n.state.hard.term.val + 1
  slot : ∀ i (hi : i < MAX), n.peers[i] = some ids[k] ↔ i = n.local.val
  ok : StateOk G n.state
  snap : SnapOk g G n.state
  log : fullLog G n.state = F
  term : n.state.hard.term = T
  vote : n.state.hard.voted_for = vf
  role : n.role = .Leader ∨ n.role = .Follower
  dirty : n.dirty = true
  extra : n.extra_reply = none
  outbox : ∀ j : Fin MAX, n.outbox[j] = none
  matched : ∀ i : Fin MAX, i.val ≠ n.local.val → 0 < (n.matched[i]).val →
    ∃ w : Fin K, n.peers[i] = some ids[w] ∧ (w, T.val, (n.matched[i]).val) ∈ G.acks
  own : ∀ h : n.local.val < MAX, (n.matched[n.local.val]'h).val ≤ F.length
  commit : CommittedBy ids g G T.val (F.take n.state.hard.commit.val) ∨
    CommittedBy ids g (ppOwnG G k T.val F) T.val (F.take n.state.hard.commit.val)

theorem pp_pq_refresh {G : Ghost (Record V MAX) K} {k : Fin K} {T : Rust.u64} {vf : Option Id} {F : List (DEntry V MAX)}
    {n0 n n' : DNode V S MAX CAP} {me : Id} (hd0 : DynOk g me n0) (hq : PPQ ids g G k T vf F n) (h : Refresh n n') :
    PPQ ids g G k T vf F n' ∧ DynOk g ids[k] n' := by
  have hd : DynOk g ids[k] n' := dynOk_refresh n n' hd0.n_pos hd0.n_lt hd0.cap_ge hd0.cap_lt hq.hooks hq.boot hq.cid
    hq.hb hq.he hq.hel hq.ok.layout hq.ok.contig hq.pv h
  obtain ⟨hs, hdi, hex, -, -, -, hrole, hkept⟩ := pp_refresh_fields h
  refine ⟨{
      hooks := hd.hooks
      boot := hd.bootstrap
      cid := hd.id
      hb := hd.heartbeat
      he := hd.election
      hel := hd.election_le
      pv := hd.prevoting
      slot := hd.local_slot
      ok := by rw [hs]; exact hq.ok
      snap := by rw [hs]; exact hq.snap
      log := by rw [hs]; exact hq.log
      term := by rw [hs]; exact hq.term
      vote := by rw [hs]; exact hq.vote
      role := ?_
      dirty := by rw [hdi]; exact hq.dirty
      extra := by rw [hex]; exact hq.extra
      outbox := ?_
      matched := ?_
      own := ?_
      commit := by rw [hs]; exact hq.commit }, hd⟩
  · rcases hrole with ⟨h1, -⟩ | ⟨h1, -⟩
    · rw [h1]; exact hq.role
    · rw [h1]; exact Or.inr rfl
  · intro j
    rcases hkept j with ⟨-, -, -, -, -, h6⟩ | ⟨-, x, -, -, -, -, -, -, -, h8⟩
    · rw [h6]; exact hq.outbox j
    · exact h8
  · intro i hi h0
    rcases hkept i with ⟨h1, -, -, -, h5, -⟩ | ⟨-, x, -, -, -, -, -, -, h7, -⟩
    · simp only [Fin.getElem_fin] at h1 h5 h0 ⊢
      have hne : i.val ≠ n.local.val := fun e => hi ((hd.local_slot i.val i.isLt).mp (by
        rw [h1]; exact (hq.slot i.val i.isLt).mpr e))
      rw [h5] at h0 ⊢; rw [h1]
      have := hq.matched i hne (by simpa only [Fin.getElem_fin] using h0)
      simpa only [Fin.getElem_fin] using this
    · rw [h7] at h0; simp at h0
  · intro h
    rcases hkept ⟨n'.local.val, h⟩ with ⟨h1, -, -, -, h5, -⟩ | ⟨-, x, -, -, -, -, -, -, h7, -⟩
    · simp only [Fin.getElem_fin] at h1 h5
      have hp' : n'.peers[n'.local.val] = some ids[k] := (hd.local_slot _ h).mpr rfl
      have hl : n'.local.val = n.local.val := (hq.slot _ h).mp (by rw [← h1]; exact hp')
      rw [h5]
      have := hq.own (hl ▸ h)
      simpa only [hl] using this
    · simp only [Fin.getElem_fin] at h7; rw [h7]; simp

theorem pp_pq_commit {G : Ghost (Record V MAX) K} {k : Fin K} {T : Rust.u64} {vf : Option Id} {F : List (DEntry V MAX)}
    {m : DNode V S MAX CAP} (hq : PPQ ids g G k T vf F m) (hd : DynOk g ids[k] m) (v : Rust.u64)
    (hQ : QuorumAt m v) (hlt : m.state.hard.commit < v)
    (hsome : Rust.Option.is_some_and (State.id_at m.state v) (fun id => id.term == m.state.hard.term) = true) :
    PPQ ids g G k T vf F (commitTo m v) ∧ DynOk g ids[k] (commitTo m v) := by
  have hc : commitTo m v = { m with state := { m.state with hard := { m.state.hard with commit := v } }, dirty := true } := by
    unfold commitTo; rw [if_pos hlt]
  rw [hc]
  rw [id_at_eq _ hd.layout] at hsome
  obtain ⟨id, hid, hidt⟩ : ∃ id, idAt m.state v.val = some id ∧ id.term = m.state.hard.term := by
    cases h : idAt m.state v.val with
    | none => rw [h] at hsome; simp [Rust.Option.is_some_and] at hsome
    | some id => rw [h] at hsome; simp [Rust.Option.is_some_and] at hsome; exact ⟨id, rfl, hsome⟩
  have hlt' : m.state.hard.commit.val < v.val := Fin.lt_def.mp hlt
  have hv0 : 0 < v.val := by omega
  have hok := hq.ok
  obtain ⟨-, hvl, hvid⟩ := (idAt_fullLog G m.state hok v.val hv0 id).mp hid
  have hlen := fullLog_length G m.state hok
  have hlog := hq.log
  have hvF : v.val ≤ F.length := by rw [← hlog]; omega
  have hd' : DynOk g ids[k] { m with state := { m.state with hard := { m.state.hard with commit := v } }, dirty := true } :=
    dynOk_frame hd rfl rfl rfl rfl rfl rfl rfl hd.layout hd.contig hd.prevoting
  refine ⟨{ hq with
      ok := { hok with commit_ge := by have := hok.commit_ge; show m.state.base.index.val ≤ v.val; omega,
                       commit_le := by show v.val ≤ (lastId m.state).index.val; omega }
      dirty := rfl
      commit := Or.inr ?_ }, hd'⟩
  show CommittedBy ids g (ppOwnG G k T.val F) T.val (F.take v.val)
  have hG1 : (ppOwnG G k T.val F).leader T.val = some F := by simp [ppOwnG]
  refine Or.inr ⟨T.val, v.val, Nat.le_refl _, ⟨F.length, hv0, hvF, F, hG1, Nat.le_refl _, ⟨by omega, ?_⟩, ?_⟩, ?_⟩
  · have e1 : F[v.val - 1]'(by omega) = (fullLog G m.state)[v.val - 1] := by simp only [hlog]
    rw [e1, hvid, hidt, hq.term]
  · rw [List.take_length]
    have hmem : m.membership = cfgOf g F := by rw [hd.membership, memOf_fullLog g G m.state hq.snap, hlog]
    unfold QuorumAt at hQ
    rw [hmem] at hQ
    apply quorum_mono _ _ _ _ hQ
    intro x hx
    unfold matchOf at hx
    cases hp : pos m x with
    | none => rw [hp] at hx; dsimp only at hx; simp at hx; omega
    | some i =>
      rw [hp] at hx; dsimp only at hx
      obtain ⟨hiM, hpe⟩ := pos_lt m x i hd.pre.n_lt hp
      rw [getElem!_pos m.matched i.val hiM] at hx
      rw [getElem!_pos m.peers i.val hiM] at hpe
      by_cases hil : i.val = m.local.val
      · have hs := (hq.slot i.val hiM).mpr hil
        rw [hs] at hpe; cases hpe
        refine ⟨k, rfl, F.length, ?_, List.mem_cons_self⟩
        have := hq.own (hil ▸ hiM)
        have e : m.matched[i.val]'hiM = m.matched[m.local.val]'(hil ▸ hiM) := by simp only [hil]
        rw [e] at hx; omega
      · obtain ⟨w, hw, ha⟩ := hq.matched ⟨i.val, hiM⟩ hil (by simp only [Fin.getElem_fin]; omega)
        simp only [Fin.getElem_fin] at hw ha
        rw [hw] at hpe; cases hpe
        exact ⟨w, rfl, _, hx, List.mem_cons_of_mem _ ha⟩
  · simp [Ghost.prefix, ppOwnG]

theorem pp_pq_adv {G : Ghost (Record V MAX) K} {k : Fin K} {T : Rust.u64} {vf : Option Id} {F : List (DEntry V MAX)}
    {m m' : DNode V S MAX CAP} (hq : PPQ ids g G k T vf F m) (hd : DynOk g ids[k] m) (h : Adv' m m') :
    PPQ ids g G k T vf F m' ∧ DynOk g ids[k] m' := by
  rcases h with rfl | ⟨v, hQ, hlt, hsome, hct⟩
  · exact ⟨hq, hd⟩
  rcases hct with ⟨-, hR⟩ | ⟨-, rfl⟩
  · obtain ⟨hq1, -⟩ := pp_pq_commit ids g hq hd v hQ hlt hsome
    exact pp_pq_refresh ids g hd hq1 hR
  · exact ⟨hq, hd⟩

theorem ppr_leadLog (G : Ghost (Record V MAX) K) (k : Fin K) (n : DNode V S MAX CAP) (F : List (DEntry V MAX))
    (T : Rust.u64) (hF : fullLog G n.state = F) (hT : n.state.hard.term = T) (hdirty : n.dirty = true)
    (hel : ∃ eL, G.elect T.val = some (k, eL) ∧ eL <+: F ∧
      ∀ i (h : i < F.length), eL.length ≤ i → (F[i]).id.term = T)
    (hL : ∃ L, G.leader T.val = some L ∧ L <+: F) (hch : ChainIn (ids := ids) (g := g) G F)
    (hcf : ∀ i (hi : i < F.length) X, recCfg (F[i]).value = some X → MemOk X) : LeadLog ids g G k n := by
  refine ⟨?_, ?_, ?_, ?_⟩
  · rw [hF, hT]; exact hel
  · rw [hF, hT]; obtain ⟨L, h1, h2⟩ := hL; exact ⟨L, h1, h2, fun h => by rw [hdirty] at h; cases h⟩
  · rw [hF]; exact hch
  · rw [hF]; exact hcf

theorem pp_leader_of (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (hi : Inv ids g C G) (k : Fin K)
    (hd : (C.node k).dirty = false) (hr0 : (C.node k).role = .Leader) :
    Leading G k (C.node k) ∧ LeaderOk' ids G k (C.node k) := by
  obtain ⟨h1, h2⟩ := hi.leader k hr0
  refine ⟨?_, h2⟩
  rcases h1 with h | h
  · exact h
  · have := h.1; rw [hd] at this; cases this

/-- A leader that appended to its log, refreshed, matched and advanced (`f`),
    then broadcast, keeps its clauses. -/
theorem pp_local_bcast (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (hi : Inv ids g C G) (k : Fin K)
    (hr0 : (C.node k).role = .Leader) (hdirty0 : (C.node k).dirty = false)
    {F : List (DEntry V MAX)} {f : DNode V S MAX CAP}
    (hq : PPQ ids g G k (C.node k).state.hard.term (C.node k).state.hard.voted_for F f) (hd : DynOk g ids[k] f)
    (hpre : fullLog G (C.node k).state <+: F)
    (hnew : ∀ i (h : i < F.length), (fullLog G (C.node k).state).length ≤ i → (F[i]).id.term = (C.node k).state.hard.term)
    (hch : ChainIn (ids := ids) (g := g) G F)
    (hcf : ∀ i (h : i < F.length) X, recCfg (F[i]).value = some X → MemOk X)
    (c : Jarl.Cluster V S MAX CAP) (hc : c.node = bcastD f) : LocalOk' ids g C G k c := by
  obtain ⟨hlead, hlok⟩ := pp_leader_of ids g C G hi k hdirty0 hr0
  have hLL := hi.lead k hlead
  obtain ⟨cn⟩ := c
  simp only at hc
  subst hc
  have hLead : Leading G k (bcastD f) := by
    unfold Leading; show ∃ eL, G.elect f.state.hard.term.val = some (k, eL); rw [hq.term]; exact hlead
  have hrole : ∀ h : f.role = .Candidate, False := by
    intro h; rcases hq.role with e | e <;> rw [e] at h <;> cases h
  refine
    { dyn := dynOk_frame hd rfl rfl rfl rfl rfl rfl rfl hd.layout hd.contig hd.prevoting
      live := ⟨hq.ok, hq.snap⟩
      consistent := Or.inr (Or.inl ⟨hq.dirty, hLead⟩)
      clean := fun h => by have h' : f.dirty = false := h; rw [hq.dirty] at h'; cases h'
      terms := by show (C.disk k).hard.term.val ≤ f.state.hard.term.val; rw [hq.term]; exact hi.terms k
      acks := fun t j h j' hj' => by
        show Kept G k t j' (f.state.hard.term.val + 1) (fullLog G f.state)
        rw [hq.term, hq.log]; exact kept_of_prefix G k t j' _ _ _ hpre ((hi.acks k t j h).2.2 j' hj').1
      ballots := fun T c' v h ht => by
        have ht' : f.state.hard.term.val = T := ht
        show f.state.hard.voted_for = _
        rw [hq.vote]; rw [hq.term] at ht'; exact (hi.ballots T k c' v h).2.2.2 ht'
      ballot_cand := fun h => absurd h hrole
      elect := fun T eL h hd ht => by
        have ht' : f.state.hard.term.val < T := ht
        rw [hq.term] at ht'
        exact absurd hr0 ((hi.elect T k eL h hd).2.2.2 ht').2.1
      elect_cand := fun T eL h ⟨hr, _⟩ => hrole hr
      lead := fun _ => ?_
      leader := fun _ => ⟨Or.inl hLead, ?_, ?_⟩
      candidate := fun h => absurd h hrole
      outbox := fun i o ho => ?_
      outbox_self := fun h => ?_
      extra := fun to o h => by have h' : f.extra_reply = some (to, o) := h; rw [hq.extra] at h'; cases h'
      votes := fun env he T last hfr hm ⟨hr, _⟩ => absurd hr hrole
      committed := ?_ }
  · obtain ⟨eL, he, hp, hte⟩ := hLL.elected
    obtain ⟨L, hL, hLp, -⟩ := hLL.log
    refine ppr_leadLog ids g G k _ F _ hq.log hq.term hq.dirty ⟨eL, he, hp.trans hpre, fun i hi' hle => ?_⟩
      ⟨L, hL, hLp.trans hpre⟩ hch hcf
    by_cases hlt : i < (fullLog G (C.node k).state).length
    · rw [← hte i hlt hle]; exact congrArg (fun e : DEntry V MAX => e.id.term) (List.IsPrefix.getElem hpre hlt).symm
    · exact hnew i hi' (by omega)
  · intro i hne h0
    obtain ⟨w, a, b⟩ := hq.matched i hne h0
    exact ⟨w, a, by show (w, f.state.hard.term.val, _) ∈ G.acks; rw [hq.term]; exact b⟩
  · intro h
    have := hq.own h
    show _ ≤ (fullLog G f.state).length
    rw [hq.log]; exact this
  · have ho' : (bcastD f).outbox[i] = some o := ho
    simp only [bcastD, Fin.getElem_fin, Vector.getElem_ofFn] at ho'
    split at ho'
    · rename_i hcond
      cases ho'
      obtain ⟨-, hs⟩ := hcond
      cases hp : f.peers[i.val] with
      | none => rw [hp] at hs; simp [Rust.Option.is_some_and] at hs
      | some to =>
        refine ⟨to, by show f.peers[i] = some to; simpa only [Fin.getElem_fin] using hp, ?_⟩
        unfold OutOk; rw [setLive_self']; exact Or.inl hLead
    · have := hq.outbox i; simp only [Fin.getElem_fin] at this; rw [this] at ho'; cases ho'
  · intro o ho
    have ho' : (bcastD f).outbox[f.local.val] = some o := ho
    simp only [bcastD, Vector.getElem_ofFn] at ho'
    rw [if_neg (by simp)] at ho'
    have := hq.outbox ⟨f.local.val, h⟩; rw [this] at ho'; cases ho'
  · rcases hq.commit with h | h
    · left
      show CommittedBy ids g G f.state.hard.term.val ((fullLog G f.state).take f.state.hard.commit.val)
      rw [hq.term, hq.log]; exact h
    · right; left
      refine ⟨hq.dirty, hLead, ?_⟩
      have e : withOwnD G k (bcastD f) = ppOwnG G k (C.node k).state.hard.term.val F := by
        have h1 : fullLog G (bcastD f).state = F := hq.log
        have h2 : (bcastD f).state.hard.term = (C.node k).state.hard.term := hq.term
        unfold withOwnD ppOwnG; rw [h1, h2]
      show CommittedBy ids g (withOwnD G k (bcastD f)) f.state.hard.term.val ((fullLog G f.state).take f.state.hard.commit.val)
      rw [e]
      rw [hq.term, hq.log]; exact h

theorem pp_proposedD_terms (n : DNode V S MAX CAP) (vs : List (Record V MAX)) :
    ∀ e ∈ proposedD n vs, e.id.term = n.state.hard.term := by
  intro e he; simp only [proposedD, List.mem_map] at he; obtain ⟨_, _, rfl⟩ := he; rfl

theorem pp_proposedD_length (n : DNode V S MAX CAP) (vs : List (Record V MAX)) :
    (proposedD n vs).length = vs.length := by
  simp [proposedD]

/-- A proposal (`ProposeD`) keeps the invariant, given the chain of the extended log. -/
theorem pp_propose_inv (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (hi : Inv ids g C G) (k : Fin K)
    (vs : List (Record V MAX)) (c : Jarl.Cluster V S MAX CAP) (hP : ProposeD (C.node k) vs c.node)
    (hch : Idle (C.node k) → (C.node k).role = .Leader →
      ChainIn (ids := ids) (g := g) G (fullLog G (C.node k).state ++ proposedD (C.node k) vs))
    (hcf : ∀ e ∈ proposedD (C.node k) vs, ∀ X, recCfg e.value = some X → MemOk X) :
    Inv ids g (C.setLive k c) G := by
  rcases hP with hsame | ⟨hI, hr0, -, hbound, s', n1, n2, hr, hh, hs, hl', hc', hR, hA, hn'⟩
  · rw [pp_setLive_same C k c hsame]; exact hi
  apply setLive_inv' ids g C G hi k c
  have hd0 := hi.dyn k
  obtain ⟨hlead, hlok⟩ := pp_leader_of ids g C G hi k hI.1 hr0
  have hLL := hi.lead k hlead
  have hok0 := (hi.live k).1
  have hterms := pp_proposedD_terms (C.node k) vs
  have hok' : StateOk G s' := pp_stateOk_append G _ s' _ hok0 hs hh hr hl' hc' hterms
  have hsn' : SnapOk g G s' := pp_snapOk_append g G _ s' (hi.live k).2 hs
  have hF : fullLog G s' = fullLog G (C.node k).state ++ proposedD (C.node k) vs := fullLog_append G _ s' _ hs hr
  have hlen0 := fullLog_length G _ hok0
  have hcl : (C.node k).state.hard.commit.val ≤ (fullLog G (C.node k).state).length := by
    have := hok0.commit_le; omega
  have hcom0 : CommittedBy ids g G (C.node k).state.hard.term.val
      ((fullLog G (C.node k).state).take (C.node k).state.hard.commit.val) := by
    rcases (hi.committed k).2 with h | ⟨hd, -⟩ | ⟨-, hpw, -⟩
    · exact h
    · rw [hI.1] at hd; cases hd
    · have := hpw.1; rw [hI.1] at this; cases this
  have hqa : PPQ ids g G k (C.node k).state.hard.term (C.node k).state.hard.voted_for
      (fullLog G (C.node k).state ++ proposedD (C.node k) vs)
      { C.node k with state := s', dirty := true, log_from := some (Rust.ofNat ((lastId (C.node k).state).index.val + 1)) } :=
    { hooks := hd0.hooks
      boot := hd0.bootstrap
      cid := hd0.id
      hb := hd0.heartbeat
      he := hd0.election
      hel := hd0.election_le
      pv := fun t ht => by
        have := (hd0.prevoting t ht).1
        have h2 : (C.node k).role = .Follower := this
        rw [hr0] at h2; cases h2
      slot := hd0.local_slot
      ok := hok'
      snap := hsn'
      log := hF
      term := by show s'.hard.term = _; rw [hh]
      vote := by show s'.hard.voted_for = _; rw [hh]
      role := Or.inl hr0
      dirty := rfl
      extra := hI.2.1
      outbox := hI.2.2
      matched := hlok.matched
      own := fun h => by
        have := hlok.own h
        show _ ≤ (fullLog G (C.node k).state ++ proposedD (C.node k) vs).length
        simp only [List.length_append]; omega
      commit := Or.inl (by
        show CommittedBy ids g G _ (List.take s'.hard.commit.val _)
        rw [hh, List.take_append_of_le_length hcl]; exact hcom0) }
  obtain ⟨hq1, hd1⟩ := pp_pq_refresh ids g hd0 hqa hR
  have hlenF : (fullLog G (C.node k).state ++ proposedD (C.node k) vs).length =
      (lastId (C.node k).state).index.val + vs.length := by
    simp only [List.length_append, pp_proposedD_length]; omega
  have hqm : PPQ ids g G k (C.node k).state.hard.term (C.node k).state.hard.voted_for
      (fullLog G (C.node k).state ++ proposedD (C.node k) vs)
      { n1 with matched := if h : n1.local.val < MAX then n1.matched.set n1.local.val (Rust.ofNat ((lastId (C.node k).state).index.val + vs.length)) h else n1.matched } := by
    refine { hq1 with matched := ?_, own := ?_ }
    · intro i hne h0
      have e : (if h : n1.local.val < MAX then n1.matched.set n1.local.val (Rust.ofNat ((lastId (C.node k).state).index.val + vs.length)) h else n1.matched)[i] = n1.matched[i] := by
        by_cases hl : n1.local.val < MAX
        · rw [dif_pos hl, Fin.getElem_fin, Fin.getElem_fin, Vector.getElem_set_ne]; exact fun e => hne e.symm
        · rw [dif_neg hl]
      show ∃ w : Fin K, n1.peers[i] = some ids[w] ∧ _
      have h0' : 0 < (n1.matched[i]).val := by rw [← e]; exact h0
      obtain ⟨w, a, b⟩ := hq1.matched i hne h0'
      refine ⟨w, a, ?_⟩
      show (w, _, ((if h : n1.local.val < MAX then n1.matched.set n1.local.val (Rust.ofNat ((lastId (C.node k).state).index.val + vs.length)) h else n1.matched)[i]).val) ∈ G.acks
      rw [e]; exact b
    · intro h
      show ((if h : n1.local.val < MAX then n1.matched.set n1.local.val (Rust.ofNat ((lastId (C.node k).state).index.val + vs.length)) h else n1.matched)[n1.local.val]'h).val ≤ _
      simp only [dif_pos h, Vector.getElem_set_self, Rust.ofNat]
      rw [hlenF]; exact Nat.mod_le _ _
  have hdm := dynOk_frame (n' := { n1 with matched := if h : n1.local.val < MAX then n1.matched.set n1.local.val (Rust.ofNat ((lastId (C.node k).state).index.val + vs.length)) h else n1.matched }) hd1 rfl rfl rfl rfl rfl rfl rfl hd1.layout hd1.contig hd1.prevoting
  obtain ⟨hq2, hd2⟩ := pp_pq_adv ids g hqm hdm hA
  refine pp_local_bcast ids g C G hi k hr0 hI.1 hq2 hd2 (List.prefix_append _ _) ?_ (hch hI hr0) ?_ c hn'
  · intro i h hle
    rw [List.getElem_append_right hle]; exact hterms _ (List.getElem_mem _)
  · intro i h X hX
    by_cases hlt : i < (fullLog G (C.node k).state).length
    · rw [List.getElem_append_left hlt] at hX; exact hLL.cfgs i hlt X hX
    · rw [List.getElem_append_right (by omega)] at hX; exact hcf _ (List.getElem_mem _) X hX

theorem pp_proposedD_value (n : DNode V S MAX CAP) (vs : List (Record V MAX)) :
    ∀ e ∈ proposedD n vs, ∃ x ∈ vs, e.value = some x := by
  intro e he; simp only [proposedD, List.mem_map] at he
  obtain ⟨⟨x, i⟩, hm, rfl⟩ := he
  exact ⟨x, List.fst_mem_of_mem_zipIdx hm, rfl⟩

theorem pp_memOk (hg : MemOk g) (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (hi : Inv ids g C G)
    (k : Fin K) : MemOk (C.node k).membership := by
  rw [(hi.dyn k).membership, memOf_fullLog g G _ (hi.live k).2]
  rcases pp_cfgOf_cases g (fullLog G (C.node k).state) with h | ⟨i, hi', h⟩
  · rw [h]; exact hg
  · rcases hi.consistent_live k with hc | ⟨-, hl⟩ | hpw
    · obtain ⟨-, L, hL, hp⟩ := hc i hi'
      have hiL : i < L.length := by have := hp.length_le; simp at this; omega
      have e := List.IsPrefix.getElem hp (i := i) (by simp; omega)
      rw [List.getElem_take] at e
      exact hi.cfgs _ L hL i hiL _ (by rw [← e]; exact h)
    · exact (hi.lead k hl).cfgs i hi' _ h
    · exact hpw.2.2.2.2.2.2.2.2.2 i hi' _ h

/-- A membership change (`ReconfigD`) keeps the invariant. -/
theorem pp_reconfig_inv (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (hi : Inv ids g C G) (k : Fin K)
    (c : Jarl.Cluster V S MAX CAP) (hR : ReconfigD (C.node k) c.node) : Inv ids g (C.setLive k c) G := by
  rcases hR with hsame | ⟨X, hP, hX, hI, hr0, hcm, hshape⟩
  · rw [pp_setLive_same C k c hsame]; exact hi
  have hd0 := hi.dyn k
  have hok0 := (hi.live k).1
  have hmem : (C.node k).membership = cfgOf g (fullLog G (C.node k).state) := by
    rw [hd0.membership, memOf_fullLog g G _ (hi.live k).2]
  have he : proposedD (C.node k) [Record.Configuration X] =
      [{ id := { index := Rust.ofNat ((lastId (C.node k).state).index.val + 1 + 0), term := (C.node k).state.hard.term },
         value := some (Record.Configuration X) }] := rfl
  have hcom0 : CommittedBy ids g G (C.node k).state.hard.term.val
      ((fullLog G (C.node k).state).take (C.node k).state.hard.commit.val) := by
    rcases (hi.committed k).2 with h | ⟨hd, -⟩ | ⟨-, hpw, -⟩
    · exact h
    · rw [hI.1] at hd; cases hd
    · have := hpw.1; rw [hI.1] at this; cases this
  refine pp_propose_inv ids g C G hi k _ c hP ?_ ?_
  · intro _ _
    rw [he]
    refine pp_chain_cfg ids g G _ _ X (hi.lead k (pp_leader_of ids g C G hi k hI.1 hr0).1).chain rfl ?_ ?_
    · rw [← hmem]
      rcases hshape with (⟨-, rfl | ⟨hv, -⟩⟩ | ⟨hj, hp⟩) | ⟨-, rfl⟩
      · exact Or.inl (List.Perm.refl _)
      · exact Or.inl (by rw [hv])
      · exact Or.inr ⟨hj, hp⟩
      · exact Or.inl (by rw [Jarl.Contracts.Membership.MembershipProjection.finalization_preserves_voters])
    · intro k' hk' hck
      have hlen := fullLog_length G _ hok0
      have hpos := memAt_pos g G _ hok0 (lastId (C.node k).state).index
        (by rw [lastId_eq _ hok0.contig]; omega) k' hk' (by omega) hck
      rw [hd0.bootstrap] at hcm
      have hc' : (memAt (C.node k).state g (lastId (C.node k).state).index).1.val ≤ (C.node k).state.hard.commit.val := hcm
      show CommittedBy ids g G (C.node k).state.hard.term.val _
      apply committedBy_prefix G _ _ _ _ hcom0
      rw [show (fullLog G (C.node k).state).take (k' + 1) =
        ((fullLog G (C.node k).state).take (C.node k).state.hard.commit.val).take (k' + 1) by
          rw [List.take_take, Nat.min_eq_left (by omega)]]
      exact List.take_prefix _ _
  · intro e he' Y hY
    rw [he] at he'; simp only [List.mem_singleton] at he'; subst he'
    simp only [recCfg, Option.some.injEq] at hY; subst hY; exact hX

theorem pp_set_matched (G : Ghost (Record V MAX) K) (n : DNode V S MAX CAP) (x : Rust.u64) (T : Nat)
    (hm : ∀ i : Fin MAX, i.val ≠ n.local.val → 0 < (n.matched[i]).val →
      ∃ w : Fin K, n.peers[i] = some ids[w] ∧ (w, T, (n.matched[i]).val) ∈ G.acks) :
    ∀ i : Fin MAX, i.val ≠ n.local.val →
      0 < ((if h : n.local.val < MAX then n.matched.set n.local.val x h else n.matched)[i]).val →
      ∃ w : Fin K, n.peers[i] = some ids[w] ∧
        (w, T, ((if h : n.local.val < MAX then n.matched.set n.local.val x h else n.matched)[i]).val) ∈ G.acks := by
  intro i hne h0
  have e : (if h : n.local.val < MAX then n.matched.set n.local.val x h else n.matched)[i] = n.matched[i] := by
    by_cases hl : n.local.val < MAX
    · rw [dif_pos hl, Fin.getElem_fin, Fin.getElem_fin, Vector.getElem_set_ne]; exact fun e => hne e.symm
    · rw [dif_neg hl]
  rw [e] at h0 ⊢; exact hm i hne h0

/-- A non-leader whose checkpoint changes without changing its full log, hard
    state or last identity (a compaction) keeps its clauses. -/
theorem pp_local_samelog (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (hi : Inv ids g C G) (k : Fin K)
    (hI : Idle (C.node k)) (hr0 : (C.node k).role ≠ .Leader) (s' : DState V S MAX CAP)
    (hd1 : DynOk g ids[k] { C.node k with state := s', dirty := true, snapshot_changed := true })
    (hok : StateOk G s') (hsnap : SnapOk g G s') (hfl : fullLog G s' = fullLog G (C.node k).state)
    (hh : s'.hard = (C.node k).state.hard) (hlast : lastId s' = lastId (C.node k).state)
    (hcons : Consistent G (fullLog G (C.node k).state))
    (hcom0 : CommittedBy ids g G (C.node k).state.hard.term.val
      ((fullLog G (C.node k).state).take (C.node k).state.hard.commit.val))
    (c : Jarl.Cluster V S MAX CAP) (hc : c.node = { C.node k with state := s', dirty := true, snapshot_changed := true }) :
    LocalOk' ids g C G k c := by
  obtain ⟨cn⟩ := c
  simp only at hc
  subst hc
  refine
    { dyn := hd1
      live := ⟨hok, hsnap⟩
      consistent := Or.inl (by dsimp only; rw [hfl]; exact hcons)
      clean := fun h => by dsimp only at h; cases h
      terms := by dsimp only; rw [hh]; exact hi.terms k
      acks := fun t j h j' hj' => by dsimp only; rw [hh, hfl]; exact ((hi.acks k t j h).2.2 j' hj').1
      ballots := fun T c' v h ht => by
        dsimp only at ht ⊢; rw [hh] at ht ⊢; exact (hi.ballots T k c' v h).2.2.2 ht
      ballot_cand := fun hr T w v hb ht => by
        dsimp only at hr ht ⊢; rw [hfl]; rw [hh] at ht; exact hi.ballot_cand T w k v hb hr ht
      elect := fun T eL h hd ht => by
        dsimp only at ht ⊢; rw [hh] at ht
        obtain ⟨a, b, d⟩ := (hi.elect T k eL h hd).2.2.2 ht
        exact ⟨by rw [hfl]; exact a, b, by rw [hh]; exact d⟩
      elect_cand := fun T eL h ⟨hr, ht⟩ => by
        dsimp only at hr ht; rw [hh] at ht; exact hi.elect_cand T k eL h ⟨hr, ht⟩
      lead := fun hl => ?_
      leader := fun hr => absurd hr hr0
      candidate := fun hr => ?_
      outbox := fun i o ho => by dsimp only at ho; rw [hI.2.2 i] at ho; cases ho
      outbox_self := fun h o ho => by
        dsimp only at ho; have := hI.2.2 ⟨(C.node k).local.val, h⟩; simp only [Fin.getElem_fin] at this
        rw [this] at ho; cases ho
      extra := fun to o h => by dsimp only at h; rw [hI.2.1] at h; cases h
      votes := fun env he T last hfr hm hc => by
        dsimp only at hc ⊢
        rw [hlast]
        have := hi.sent env he
        unfold SentOk at this
        rw [hm] at this
        exact (this.2 k hfr).2.1 ⟨hc.1, by rw [← hh]; exact hc.2⟩
      committed := Or.inl (by dsimp only; rw [hh, hfl]; exact hcom0) }
  · have hl' : Leading G k (C.node k) := by
      unfold Leading at hl ⊢; dsimp only at hl; rw [hh] at hl; exact hl
    have hLL := hi.lead k hl'
    obtain ⟨L, hL, hLp, -⟩ := hLL.log
    exact ppr_leadLog ids g G k _ _ (C.node k).state.hard.term hfl (by dsimp only; rw [hh]) rfl hLL.elected
      ⟨L, hL, hLp⟩ hLL.chain hLL.cfgs
  · have := hi.candidate k hr
    unfold CandidateOk' at this ⊢
    dsimp only
    rw [hh, hfl]; exact this

theorem pp_compact_inv [Rust.LawfulClone S] (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (hi : Inv ids g C G)
    (k : Fin K) (index : Rust.u64) (app : S) (r : Rust.Result Unit Error) (c : Jarl.Cluster V S MAX CAP)
    (h : Cluster.compact (C.live k) index app = pure (r, c)) : Inv ids g (C.setLive k c) G := by
  have hd0 := hi.dyn k
  obtain ⟨value, hval, hC⟩ := cluster_compact_rel (C.live k) hd0.pre index app r c h
  rcases hC with hsame | ⟨hI, hlo, hhi, last, v, s', hid, hv, hins, hcase⟩
  · rw [pp_setLive_same C k c hsame]; exact hi
  apply setLive_inv' ids g C G hi k c
  have hlo' : (C.node k).state.base.index.val < index.val := hlo
  have hhi' : index.val ≤ (C.node k).state.hard.commit.val := hhi
  clear hlo hhi
  have hok0 := (hi.live k).1
  have hcons : Consistent G (fullLog G (C.node k).state) := by
    rcases hi.consistent_live k with h | ⟨hd, -⟩ | hpw
    · exact h
    · rw [hI.1] at hd; cases hd
    · have := hpw.1; rw [hI.1] at this; cases this
  have hcom0 : CommittedBy ids g G (C.node k).state.hard.term.val
      ((fullLog G (C.node k).state).take (C.node k).state.hard.commit.val) := by
    rcases (hi.committed k).2 with h | ⟨hd, -⟩ | ⟨-, hpw, -⟩
    · exact h
    · rw [hI.1] at hd; cases hd
    · have := hpw.1; rw [hI.1] at this; cases this
  obtain ⟨s2, hins2, hsn, hhard, hret, hlay⟩ := install_spec (C.node k).state { last := last, value := v }
    (by have := hd0.cap_lt; uomega) hd0.layout hd0.contig
  obtain rfl : s' = s2 := Rust.pure_inj (hins.symm.trans hins2)
  have hpos : 0 < index.val := by omega
  obtain ⟨hbi, hil, hiid⟩ := (idAt_fullLog G _ hok0 index.val hpos last).mp hid
  have hlidx : last.index.val = index.val := by
    have := (hcons (index.val - 1) hil).1; rw [hiid] at this; omega
  have hm : idAt (C.node k).state last.index.val = some last := by rw [hlidx]; exact hid
  have hret' : ret s' = (ret (C.node k).state).drop (last.index.val - (C.node k).state.base.index.val) := by
    rw [hret, if_pos hm]
  have hcont := install_contig (C.node k).state s' _ hd0.layout hd0.contig hsn hret
  have hfl : fullLog G s' = fullLog G (C.node k).state :=
    fullLog_install_keep G _ s' { last := last, value := v } hok0 hcons hm (by show 0 < last.index.val; omega) hret' hsn
  have hh : s'.hard = (C.node k).state.hard := by
    have : Rust.max (C.node k).state.hard.commit last.index = (C.node k).state.hard.commit := by
      unfold Rust.max; split
      · apply Fin.ext; omega
      · rfl
    rw [hhard]; simp only [this]
  have hb' : s'.base = last := base_some s' _ hsn
  obtain ⟨h1, h2⟩ := idAt_some _ hd0.layout hd0.contig _ hm
  have hok : StateOk G s' := by
    refine ⟨hlay, hcont, ?_, ?_, ?_, ?_, ?_, ?_⟩
    · intro _
      rw [hb']
      obtain ⟨-, L, hL, hp⟩ := hcons (index.val - 1) hil
      rw [hiid] at hL
      have hlen := hp.length_le
      simp only [List.length_take] at hlen
      refine ⟨L, hL, by omega, by omega, ?_⟩
      have := List.IsPrefix.getElem hp (i := index.val - 1) (by simp; omega)
      simp only [hlidx]; rw [← this, List.getElem_take]; exact hiid
    · intro _; rw [hb']; omega
    · rw [hfl, hh]; exact hok0.terms
    · rw [hb', hh]; omega
    · rw [hh, lastId_eq s' hcont, hret', hb']
      have := hok0.commit_le
      rw [lastId_eq _ hd0.contig] at this
      simp only [List.length_drop]; omega
    · rw [hh]; exact hok0.unvoted
  have hsnap : SnapOk g G s' := by
    unfold SnapOk snapMem memInit
    rw [hsn]
    show v.membership = cfgOf g (boundary G s')
    rw [hval v hv, hd0.bootstrap, memAt_take g G _ hok0 (hi.live k).2 index (by omega)]
    have hbl := boundary_len G s' hok
    have hb2 : boundary G s' = (fullLog G s').take s'.base.index.val := by
      rw [fullLog_def, List.take_append_of_le_length (by omega), ← hbl, List.take_length]
    rw [hb2, hfl, hb', hlidx]
  have hlast : lastId s' = lastId (C.node k).state := by
    rw [← lastOf_fullLog G s' hok, ← lastOf_fullLog G _ hok0, hfl]
  have hmem1 : memOf s' g = memOf (C.node k).state g := by
    rw [memOf_fullLog g G s' hsnap, memOf_fullLog g G _ (hi.live k).2, hfl]
  have hd1 : DynOk g ids[k] { C.node k with state := s', dirty := true, snapshot_changed := true } :=
    dynOk_frame hd0 rfl rfl rfl rfl rfl rfl hmem1 hlay hcont (fun t ht => by
      have := hd0.prevoting t ht
      show _ ∧ t.val = s'.hard.term.val + 1; rw [hh]; exact this)
  rcases hcase with ⟨hr0, hn⟩ | ⟨hr0, n2, hB, hn⟩
  · exact pp_local_samelog ids g C G hi k hI hr0 s' hd1 hok hsnap hfl hh hlast hcons hcom0 c hn
  obtain ⟨hlead, hlok⟩ := pp_leader_of ids g C G hi k hI.1 hr0
  have hLL := hi.lead k hlead
  have hq1 : PPQ ids g G k (C.node k).state.hard.term (C.node k).state.hard.voted_for (fullLog G (C.node k).state)
      { C.node k with state := s', dirty := true, snapshot_changed := true } :=
    { hooks := hd0.hooks
      boot := hd0.bootstrap
      cid := hd0.id
      hb := hd0.heartbeat
      he := hd0.election
      hel := hd0.election_le
      pv := fun t ht => by
        have := (hd0.prevoting t ht).1
        have h2 : (C.node k).role = .Follower := this
        rw [hr0] at h2; cases h2
      slot := hd0.local_slot
      ok := hok
      snap := hsnap
      log := hfl
      term := by show s'.hard.term = _; rw [hh]
      vote := by show s'.hard.voted_for = _; rw [hh]
      role := Or.inl hr0
      dirty := rfl
      extra := hI.2.1
      outbox := hI.2.2
      matched := hlok.matched
      own := hlok.own
      commit := Or.inl (by show CommittedBy ids g G _ (List.take s'.hard.commit.val _); rw [hh]; exact hcom0) }
  rcases hB with rfl | ⟨s'', idx, hidx, -, hr'', hh'', hs'', hl'', hc'', hA⟩
  · refine pp_local_bcast ids g C G hi k hr0 hI.1 hq1 hd1 (List.prefix_refl _) (fun i h hle => by omega)
      hLL.chain hLL.cfgs c hn
  have hterms : ∀ e ∈ [({ id := { index := idx, term := s'.hard.term }, value := none } : DEntry V MAX)],
      e.id.term = s'.hard.term := by
    intro e he; simp only [List.mem_singleton] at he; subst he; rfl
  have hok'' := pp_stateOk_append G s' s'' _ hok hs'' hh'' hr'' hl'' hc'' hterms
  have hsnap'' := pp_snapOk_append g G s' s'' hsnap hs''
  have hF : fullLog G s'' = fullLog G (C.node k).state ++
      [({ id := { index := idx, term := s'.hard.term }, value := none } : DEntry V MAX)] := by
    rw [fullLog_append G s' s'' _ hs'' hr'', hfl]
  have hmem2 : memOf s'' g = memOf s' g := by
    rw [memOf_fullLog g G s'' hsnap'', memOf_fullLog g G s' hsnap, hF, hfl, cfgOf_snoc]; rfl
  have hlen0 := fullLog_length G _ hok0
  have hcl : (C.node k).state.hard.commit.val ≤ (fullLog G (C.node k).state).length := by
    have := hok0.commit_le; omega
  have hidxv : idx.val = (fullLog G (C.node k).state).length + 1 := by
    have hidx' : idx.val = (lastId s').index.val + 1 := hidx
    rw [hidx', ← fullLog_length G s' hok, hfl]
  have hq2 : PPQ ids g G k (C.node k).state.hard.term (C.node k).state.hard.voted_for
      (fullLog G (C.node k).state ++ [({ id := { index := idx, term := s'.hard.term }, value := none } : DEntry V MAX)])
      (ownAppendD { C.node k with state := s', dirty := true, snapshot_changed := true } s'' idx) :=
    { hooks := hd0.hooks
      boot := hd0.bootstrap
      cid := hd0.id
      hb := hd0.heartbeat
      he := hd0.election
      hel := hd0.election_le
      pv := fun t ht => by
        have := (hd0.prevoting t ht).1
        have h2 : (C.node k).role = .Follower := this
        rw [hr0] at h2; cases h2
      slot := hd0.local_slot
      ok := hok''
      snap := hsnap''
      log := hF
      term := by show s''.hard.term = _; rw [hh'', hh]
      vote := by show s''.hard.voted_for = _; rw [hh'', hh]
      role := Or.inl hr0
      dirty := rfl
      extra := hI.2.1
      outbox := hI.2.2
      matched := pp_set_matched ids G (C.node k) idx _ hlok.matched
      own := fun h => by
        have h' : (C.node k).local.val < MAX := h
        show ((if h : (C.node k).local.val < MAX then (C.node k).matched.set (C.node k).local.val idx h else (C.node k).matched)[(C.node k).local.val]'h').val ≤ _
        simp only [dif_pos h', Vector.getElem_set_self, List.length_append, List.length_singleton]
        omega
      commit := Or.inl (by
        show CommittedBy ids g G _ (List.take s''.hard.commit.val _)
        rw [hh'', hh, List.take_append_of_le_length hcl]; exact hcom0) }
  have hd2 : DynOk g ids[k] (ownAppendD { C.node k with state := s', dirty := true, snapshot_changed := true } s'' idx) :=
    dynOk_frame hd1 rfl rfl rfl rfl rfl rfl hmem2 hl'' hc'' (fun t ht => by
      have := hd0.prevoting t ht
      show _ ∧ t.val = s''.hard.term.val + 1; rw [hh'', hh]; exact this)
  obtain ⟨hq3, hd3⟩ := pp_pq_adv ids g hq2 hd2 hA
  refine pp_local_bcast ids g C G hi k hr0 hI.1 hq3 hd3 (List.prefix_append _ _) ?_ ?_ ?_ c hn
  · intro i h hle
    rw [List.getElem_append_right hle]; simp only [List.getElem_singleton]; exact hh ▸ rfl
  · exact pp_chain_plain ids g G _ _ hLL.chain (fun e he => by
      simp only [List.mem_singleton] at he; subst he; rfl)
  · intro i h X hX
    by_cases hlt : i < (fullLog G (C.node k).state).length
    · rw [List.getElem_append_left hlt] at hX; exact hLL.cfgs i hlt X hX
    · rw [List.getElem_append_right (by omega)] at hX; simp [recCfg] at hX

end Jarl.Engine.Dyn

namespace Jarl.Engine.Dyn
open Jarl Jarl.Engine

variable {V S : Type} {MAX CAP K : Nat} [Rust.Clone V] [Rust.Clone S]

variable (ids : Vector Id K) (g : Membership MAX) (hid : ∀ a b : Fin K, ids[a] = ids[b] → a = b) (hg : MemOk g)

include hid hg in
theorem preserve_propose [Rust.LawfulClone V] (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (hi : Inv ids g C G)
    (k : Fin K) (v : V) (r : Rust.Result LogId Error) (c : Jarl.Cluster V S MAX CAP)
    (h : Cluster.propose (C.live k) v = pure (r, c)) : ∃ G', Extends G G' ∧ Inv ids g (C.setLive k c) G' := by
  refine ⟨G, Extends.refl G, ?_⟩
  have hrel := cluster_propose_rel (C.live k) (hi.dyn k).pre v r c h
  refine pp_propose_inv ids g C G hi k _ c hrel (fun hI hr0 => ?_) ?_
  · exact pp_chain_plain ids g G _ _ (hi.lead k (pp_leader_of ids g C G hi k hI.1 hr0).1).chain (fun e he => by
      obtain ⟨x, hx, hv⟩ := pp_proposedD_value _ _ e he
      simp only [List.mem_singleton] at hx; subst hx; rw [hv]; rfl)
  · intro e he X hX
    obtain ⟨x, hx, hv⟩ := pp_proposedD_value _ _ e he
    simp only [List.mem_singleton] at hx; subst hx; rw [hv] at hX; cases hX

include hid hg in
theorem preserve_propose_batch [Rust.LawfulClone V] (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (hi : Inv ids g C G)
    (k : Fin K) (vs : Array V) (hvs : vs.size < 2 ^ Rust.usizeBits) (r : Rust.Result ProposalRange Error) (c : Jarl.Cluster V S MAX CAP)
    (h : Cluster.propose_batch (C.live k) vs = pure (r, c)) : ∃ G', Extends G G' ∧ Inv ids g (C.setLive k c) G' := by
  refine ⟨G, Extends.refl G, ?_⟩
  have hrel := cluster_propose_batch_rel (C.live k) (hi.dyn k).pre vs hvs r c h
  refine pp_propose_inv ids g C G hi k _ c hrel (fun hI hr0 => ?_) ?_
  · exact pp_chain_plain ids g G _ _ (hi.lead k (pp_leader_of ids g C G hi k hI.1 hr0).1).chain (fun e he => by
      obtain ⟨x, hx, hv⟩ := pp_proposedD_value _ _ e he
      obtain ⟨a, -, rfl⟩ := List.mem_map.mp hx; rw [hv]; rfl)
  · intro e he X hX
    obtain ⟨x, hx, hv⟩ := pp_proposedD_value _ _ e he
    obtain ⟨a, -, rfl⟩ := List.mem_map.mp hx; rw [hv] at hX; cases hX

include hid hg in
theorem preserve_compact [Rust.LawfulClone S] (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (hi : Inv ids g C G)
    (k : Fin K) (index : Rust.u64) (app : S) (r : Rust.Result Unit Error) (c : Jarl.Cluster V S MAX CAP)
    (h : Cluster.compact (C.live k) index app = pure (r, c)) : ∃ G', Extends G G' ∧ Inv ids g (C.setLive k c) G' := by
  refine ⟨G, Extends.refl G, ?_⟩
  exact pp_compact_inv ids g C G hi k index app r c h

include hid hg in
theorem preserve_set_learners (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (hi : Inv ids g C G)
    (k : Fin K) (learners : Array Id) (hl : learners.size < 2 ^ Rust.usizeBits) (r : Rust.Result LogId Error)
    (c : Jarl.Cluster V S MAX CAP) (h : Cluster.set_learners (C.live k) learners = pure (r, c)) :
    ∃ G', Extends G G' ∧ Inv ids g (C.setLive k c) G' := by
  have hd0 := hi.dyn k
  have hrel := cluster_set_learners_rel (C.live k) hd0.pre (by rw [hd0.bootstrap]; exact hd0.membership)
    (pp_memOk ids g hg C G hi k) learners hl r c h
  exact ⟨G, Extends.refl G, pp_reconfig_inv ids g C G hi k c hrel⟩

include hid hg in
theorem preserve_reconfigure (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (hi : Inv ids g C G)
    (k : Fin K) (target : Membership MAX) (ht : MemOk target) (r : Rust.Result LogId Error)
    (c : Jarl.Cluster V S MAX CAP) (h : Cluster.reconfigure (C.live k) target = pure (r, c)) :
    ∃ G', Extends G G' ∧ Inv ids g (C.setLive k c) G' := by
  have hd0 := hi.dyn k
  have hrel := cluster_reconfigure_rel (C.live k) hd0.pre (by rw [hd0.bootstrap]; exact hd0.membership)
    (pp_memOk ids g hg C G hi k) target ht r c h
  exact ⟨G, Extends.refl G, pp_reconfig_inv ids g C G hi k c hrel⟩

include hid hg in
theorem preserve_finish (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (hi : Inv ids g C G)
    (k : Fin K) (r : Rust.Result LogId Error) (c : Jarl.Cluster V S MAX CAP)
    (h : Cluster.finish_reconfiguration (C.live k) = pure (r, c)) :
    ∃ G', Extends G G' ∧ Inv ids g (C.setLive k c) G' := by
  have hd0 := hi.dyn k
  have hrel := cluster_finish_rel (C.live k) hd0.pre (by rw [hd0.bootstrap]; exact hd0.membership)
    (pp_memOk ids g hg C G hi k) r c h
  exact ⟨G, Extends.refl G, pp_reconfig_inv ids g C G hi k c hrel⟩

end Jarl.Engine.Dyn
