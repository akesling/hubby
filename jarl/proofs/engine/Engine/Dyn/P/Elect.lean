import Engine.Dyn.Common
import Engine.Dyn.OpStep

/-!
# Preservation: delivering election messages (and every message that changes nothing but the term)
-/

set_option linter.unusedSectionVars false

namespace Jarl.Engine.Dyn
open Jarl Jarl.Engine

variable {V S : Type} {MAX CAP K : Nat} [Rust.Clone V] [Rust.Clone S]
variable (ids : Vector Id K) (g : Membership MAX) (hid : ∀ a b : Fin K, ids[a] = ids[b] → a = b) (hg : MemOk g)

/-- Messages of the election protocol. -/
def ElectMsg (m : DMsg V S MAX) : Prop :=
  match m with
  | .Vote .. | .Voted .. | .PreVote .. | .PreVoted .. => True
  | _ => False

/-! ## Basic facts -/

omit [Rust.Clone V] [Rust.Clone S] in
private theorem el_setLive_live (C : World V S MAX CAP K) (k : Fin K) : C.setLive k (C.live k) = C := by
  cases C with
  | mk live disk sent =>
    simp only [World.setLive]
    congr 1
    funext j
    split
    · rename_i h; subst h; rfl
    · rfl

private theorem el_cluster_step (cl : Jarl.Cluster V S MAX CAP) (env : DEnv V S MAX) (r : Rust.Result Unit Error)
    (c : Jarl.Cluster V S MAX CAP) (h : Cluster.step cl env = pure (r, c)) :
    Node.step cl.node env = pure (r, c.node) := by
  unfold Cluster.step at h
  obtain ⟨⟨r', m⟩, h1, h2⟩ := Rust.bind_eq_pure h
  have := Rust.pure_inj h2
  simp only [Prod.mk.injEq] at this
  obtain ⟨rfl, rfl⟩ := this
  exact h1

omit [Rust.Clone V] [Rust.Clone S] in
private theorem el_state_hard_eta (s : DState V S MAX CAP) : ({ s with hard := s.hard } : DState V S MAX CAP) = s := by
  cases s; rfl

/-- What observing a message's term changes. -/
private theorem el_observed (n n1 : DNode V S MAX CAP) (src : Id) (t : Rust.u64) (h : ObservedD n src t n1) :
    n1.config = n.config ∧ n1.local = n.local ∧ n1.votes = n.votes ∧ n1.matched = n.matched ∧
    n1.outbox = n.outbox ∧ n1.extra_reply = n.extra_reply ∧ n1.peers = n.peers ∧
    n1.membership = n.membership ∧ n1.hooks = n.hooks ∧ n1.bootstrap = n.bootstrap ∧
    ((t.val ≤ n.state.hard.term.val ∧ n1 = { n with request_from := some src }) ∨
     (n.state.hard.term.val < t.val ∧
      n1.state = { n.state with hard := { n.state.hard with term := t, voted_for := none } } ∧
      n1.role = .Follower ∧ n1.dirty = true ∧ n1.prevoting = none)) := by
  rcases h with ⟨ht, rfl⟩ | ⟨ht, r, d, rfl⟩
  · exact ⟨rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, Or.inl ⟨ht, rfl⟩⟩
  · exact ⟨rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, Or.inr ⟨ht, rfl, rfl, rfl, rfl⟩⟩


/-- `LocalOk'` for idle node `k` with its log unchanged and a new hard state. -/
private theorem el_light (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (hi : Inv ids g C G) (k : Fin K)
    (hI : Idle (C.node k)) (c : Jarl.Cluster V S MAX CAP) (h : HardState)
    (hs : c.node.state = { (C.node k).state with hard := h })
    (hdyn : DynOk g ids[k] c.node)
    (hterm : (C.node k).state.hard.term.val ≤ h.term.val)
    (hcom : h.commit = (C.node k).state.hard.commit)
    (hunv : h.term.val = 0 → h.voted_for = none)
    (hclean : c.node.dirty = false → h = (C.node k).state.hard)
    (hbc : c.node.role = .Candidate ∨ c.node.role = .Leader →
      c.node.role = (C.node k).role ∧ h.term = (C.node k).state.hard.term)
    (hballots : ∀ T c' vlog, (T, k, c', vlog) ∈ G.ballots → c.node.state.hard.term.val = T →
      c.node.state.hard.voted_for = some ids[c'])
    (helect_cand : ∀ T eL, G.elect T = some (k, eL) → ¬ (c.node.role = .Candidate ∧ c.node.state.hard.term.val = T))
    (hlead : Leading G k c.node → LeadLog ids g G k c.node)
    (hleader : c.node.role = .Leader → Leading G k c.node ∧ LeaderOk' ids G k c.node)
    (hcand : c.node.role = .Candidate → CandidateOk' ids G k c.node)
    (houtbox : ∀ (i : Fin MAX) o, c.node.outbox[i] = some o → ∃ to, c.node.peers[i] = some to ∧ OutOk ids g (C.setLive k c) G k to o)
    (hoself : ∀ hl : c.node.local.val < MAX, c.node.outbox[c.node.local.val] = none)
    (hextra : ∀ to o, c.node.extra_reply = some (to, o) → OutOk ids g (C.setLive k c) G k to o) :
    LocalOk' ids g C G k c := by
  have h0 := (hi.live k).1
  have hT : c.node.state.hard.term = h.term := by rw [hs]
  refine
    { dyn := hdyn
      live := ⟨?_, ?_⟩
      consistent := ?_
      clean := ?_
      terms := ?_
      acks := ?_
      ballots := hballots
      ballot_cand := ?_
      elect := ?_
      elect_cand := helect_cand
      lead := hlead
      leader := fun hr => ⟨Or.inl (hleader hr).1, (hleader hr).2⟩
      candidate := hcand
      outbox := houtbox
      outbox_self := fun hl o h => by rw [hoself hl] at h; cases h
      extra := hextra
      votes := ?_
      committed := ?_ }
  · rw [hs]
    exact ⟨h0.layout, h0.contig, h0.base, h0.snapshot, fun e he => Nat.le_trans (h0.terms e he) hterm,
      by show _ ≤ h.commit.val; rw [hcom]; exact h0.commit_ge,
      by show h.commit.val ≤ _; rw [hcom]; exact h0.commit_le, hunv⟩
  · rw [hs]; exact (hi.live k).2
  · left; rw [hs]
    rcases hi.consistent_live k with h1 | ⟨hd, -⟩ | ⟨hd, -⟩
    · exact h1
    all_goals rw [hI.1] at hd; cases hd
  · intro hd; rw [hs, hclean hd, el_state_hard_eta (C.node k).state]; exact hi.clean k hI.1
  · rw [hT]; exact Nat.le_trans (hi.terms k) hterm
  · intro t j hj j' hj'
    rw [hs]
    exact kept_mono_bound G k t j' _ _ _ (by show _ ≤ h.term.val + 1; omega) ((hi.acks k t j hj).2.2 j' hj').1
  · intro hr T w vlog hb ht
    obtain ⟨h1, h2⟩ := hbc (Or.inl hr)
    rw [hs]
    exact hi.ballot_cand T w k vlog hb (h1 ▸ hr) (by rw [← h2, ← hT]; exact ht)
  · intro T eL he hd ht
    obtain ⟨-, -, hT1, hl⟩ := hi.elect T k eL he hd
    rw [hT] at ht
    obtain ⟨a, b, c'⟩ := hl (by omega)
    refine ⟨by rw [hs]; exact a, fun hr => b ((hbc (Or.inr hr)).1 ▸ hr), ?_⟩
    rw [hT]; apply Fin.ext
    have := hi.terms k
    have hc := congrArg Fin.val c'
    omega
  · intro env henv T last hf hmsg ⟨hr, ht⟩
    obtain ⟨h1, h2⟩ := hbc (Or.inl hr)
    have hs' := (hi.sent env henv).2
    simp only [hmsg] at hs'
    have := (hs' k hf).2.1 ⟨h1 ▸ hr, by rw [← h2, ← hT]; exact ht⟩
    rw [hs]; exact this
  · left; rw [hs]
    rcases (hi.committed k).2 with h1 | ⟨hd, -⟩ | ⟨-, ⟨hd, -⟩, -⟩
    · show CommittedBy ids g G h.term.val ((fullLog G (C.node k).state).take h.commit.val)
      rw [hcom]; exact committedBy_mono_term G _ _ hterm _ h1
    all_goals rw [hI.1] at hd; cases hd


/-- `LocalOk'` for idle node `k` after changing only the requester, outbox and extra reply. -/
private theorem el_keep (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (hi : Inv ids g C G) (k : Fin K)
    (hI : Idle (C.node k)) (c : Jarl.Cluster V S MAX CAP) (x : Option Id) (O : Vector (Option Outbound) MAX)
    (E : Option (Id × Outbound))
    (hcn : c.node = { C.node k with request_from := x, outbox := O, extra_reply := E })
    (houtbox : ∀ (i : Fin MAX) o, c.node.outbox[i] = some o → ∃ to, c.node.peers[i] = some to ∧ OutOk ids g (C.setLive k c) G k to o)
    (hoself : ∀ hl : c.node.local.val < MAX, c.node.outbox[c.node.local.val] = none)
    (hextra : ∀ to o, c.node.extra_reply = some (to, o) → OutOk ids g (C.setLive k c) G k to o) :
    LocalOk' ids g C G k c := by
  have hd := hi.dyn k
  refine el_light ids g C G hi k hI c (C.node k).state.hard (by rw [hcn]; try exact (el_state_hard_eta _).symm)
    (by rw [hcn]; exact dynOk_frame hd rfl rfl rfl rfl rfl rfl rfl hd.layout hd.contig hd.prevoting)
    (Nat.le_refl _) rfl (hi.live k).1.unvoted (fun _ => rfl) (fun _ => by rw [hcn]; exact ⟨rfl, rfl⟩)
    (fun T c' v hb ht => by rw [hcn] at ht ⊢; exact (hi.ballots T k c' v hb).2.2.2 ht)
    (fun T eL he => by rw [hcn]; exact hi.elect_cand T k eL he)
    (fun hL => by rw [hcn] at hL ⊢; have h := hi.lead k hL; exact ⟨h.elected, h.log, h.chain, h.cfgs⟩)
    (fun hr => by rw [hcn] at hr ⊢; have h := hi.leader k hr; exact ⟨h.1.resolve_right (fun hp => by have := hp.1; rw [hI.1] at this; cases this), h.2.matched, h.2.own⟩)
    (fun hr => by rw [hcn] at hr ⊢; exact hi.candidate k hr) houtbox hoself hextra

/-- A node never observes a higher term `t` in which the ghost holds an election
    of the node itself: every recorded election's winner has saved its term. -/
private theorem el_no_phantom (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (hi : Inv ids g C G) (k : Fin K)
    (t : Nat) (ht : (C.node k).state.hard.term.val < t) : ∀ eL, G.elect t ≠ some (k, eL) := by
  intro eL he
  have := hi.elect_disk t k eL he
  have := hi.terms k
  omega

/-- `LocalOk'` for idle node `k` after stepping down to a higher term with no vote. -/
private theorem el_up (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (hi : Inv ids g C G) (k : Fin K)
    (hI : Idle (C.node k)) (c : Jarl.Cluster V S MAX CAP) (t : Rust.u64) (v : Option Id)
    (hlt : (C.node k).state.hard.term.val < t.val)
    (hst : c.node.state = { (C.node k).state with hard := { (C.node k).state.hard with term := t, voted_for := v } })
    (hrole : c.node.role = .Follower) (hdirty : c.node.dirty = true) (hpv : c.node.prevoting = none)
    (hcfg : c.node.config = (C.node k).config) (hhk : c.node.hooks = (C.node k).hooks)
    (hb : c.node.bootstrap = (C.node k).bootstrap) (hp : c.node.peers = (C.node k).peers)
    (hl : c.node.local = (C.node k).local) (hm : c.node.membership = (C.node k).membership)
    (houtbox : ∀ (i : Fin MAX) o, c.node.outbox[i] = some o → ∃ to, c.node.peers[i] = some to ∧ OutOk ids g (C.setLive k c) G k to o)
    (hoself : ∀ hl : c.node.local.val < MAX, c.node.outbox[c.node.local.val] = none)
    (hextra : ∀ to o, c.node.extra_reply = some (to, o) → OutOk ids g (C.setLive k c) G k to o) :
    LocalOk' ids g C G k c := by
  have hd := hi.dyn k
  have hnp := el_no_phantom ids g C G hi k t.val hlt
  have hT : c.node.state.hard.term = t := by rw [hst]
  refine el_light ids g C G hi k hI c _ hst
    (dynOk_frame hd hcfg hhk hb hp hl hm (by rw [hst]; rfl) (by rw [hst]; exact hd.layout) (by rw [hst]; exact hd.contig)
      (by intro t' h; rw [hpv] at h; cases h))
    (Nat.le_of_lt hlt) rfl (fun h => by simp only at h; omega) (fun h => by rw [hdirty] at h; cases h)
    (fun h => by rw [hrole] at h; rcases h with h | h <;> cases h) ?_
    (fun T eL _ ⟨h, _⟩ => by rw [hrole] at h; cases h) ?_
    (fun h => by rw [hrole] at h; cases h) (fun h => by rw [hrole] at h; cases h) houtbox hoself hextra
  · intro T c' v hb ht
    rw [hT] at ht
    rcases (hi.ballots T k c' v hb).1 with h1 | ⟨rfl, -, h3⟩
    · have := hi.terms k; omega
    · exact absurd h3 (by rw [← ht]; exact hnp v)
  · intro ⟨eL, he⟩
    rw [hT] at he
    exact absurd he (hnp eL)

/-- Queuing descriptor `o` for the requester `src` (another identity) on a node with an empty outbox. -/
private theorem el_reply (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (hi : Inv ids g C G) (k : Fin K)
    (c : Jarl.Cluster V S MAX CAP) (src : Id) (hsrc : src ≠ ids[k]) (a : Option (Fin MAX))
    (ha : ∀ i, a = some i → (C.node k).peers[i] = some src) (o : Outbound) (n0 : DNode V S MAX CAP)
    (hp : n0.peers = (C.node k).peers) (hl : n0.local = (C.node k).local)
    (hob : ∀ j : Fin MAX, n0.outbox[j] = none) (hx : n0.extra_reply = none)
    (hcn : c.node = queueD n0 a src o) (hO : OutOk ids g (C.setLive k c) G k src o) :
    (∀ (i : Fin MAX) o', c.node.outbox[i] = some o' → ∃ to, c.node.peers[i] = some to ∧ OutOk ids g (C.setLive k c) G k to o') ∧
    (∀ hl : c.node.local.val < MAX, c.node.outbox[c.node.local.val] = none) ∧
    (∀ to o', c.node.extra_reply = some (to, o') → OutOk ids g (C.setLive k c) G k to o') := by
  have hd := hi.dyn k
  cases a with
  | none =>
    have e1 : c.node.outbox = n0.outbox := by rw [hcn]; rfl
    have e2 : c.node.extra_reply = some (src, o) := by rw [hcn]; rfl
    refine ⟨fun i o' h => ?_, fun hl' => ?_, fun to o' h => ?_⟩
    · rw [e1, hob i] at h; cases h
    · rw [e1]; exact hob ⟨_, hl'⟩
    · rw [e2] at h; simp only [Option.some.injEq, Prod.mk.injEq] at h; obtain ⟨rfl, rfl⟩ := h; exact hO
  | some i =>
    have e1 : c.node.outbox = n0.outbox.set i.val (some o) i.isLt := by rw [hcn]; rfl
    have e2 : c.node.extra_reply = none := by rw [hcn]; exact hx
    have e3 : c.node.peers = (C.node k).peers := by rw [hcn]; exact hp
    have e4 : c.node.local = (C.node k).local := by rw [hcn]; exact hl
    have hpi := ha i rfl
    refine ⟨fun j o' h => ?_, fun hl' => ?_, fun to o' h => ?_⟩
    · rw [e1] at h
      simp only [Fin.getElem_fin, Vector.getElem_set] at h
      split at h
      · rename_i hj
        have : j = i := Fin.ext hj.symm
        subst this
        cases h
        exact ⟨src, by rw [e3]; exact hpi, hO⟩
      · have := hob j; simp only [Fin.getElem_fin] at this; rw [this] at h; cases h
    · rw [e1]
      simp only [Vector.getElem_set]
      rw [if_neg]
      · exact hob ⟨_, hl'⟩
      · intro e
        have h1 := (hd.local_slot i.val i.isLt).mpr (by rw [← e4]; exact e)
        have : (C.node k).peers[i] = some src := hpi
        simp only [Fin.getElem_fin] at this
        rw [this] at h1
        exact hsrc (Option.some.inj h1)
    · rw [e2] at h; cases h


/-! ## Helpers shared with the tick proof (copied from `P/Tick.lean`, renamed) -/

private theorem elt_some_and {α : Type} (o : Option α) (f : α → Bool) (h : Rust.Option.is_some_and o f = true) :
    ∃ x, o = some x ∧ f x = true := by
  cases o with
  | none => simp [Rust.Option.is_some_and] at h
  | some x => exact ⟨x, rfl, h⟩

private theorem elt_preVotes_outbox (n : DNode V S MAX CAP) (t : Rust.u64) (j : Fin MAX) :
    (preVotesD n t).outbox[j] = if j.val ≠ n.local.val ∧ Rust.Option.is_some_and n.peers[j]
      (fun id => Membership.is_voter n.membership id) = true then some (.PreVote t) else n.outbox[j] := by
  simp [preVotesD, Fin.getElem_fin]

private theorem elt_bcast_outbox (n : DNode V S MAX CAP) (j : Fin MAX) :
    (bcastD n).outbox[j] = if j.val ≠ n.local.val ∧ Rust.Option.is_some_and n.peers[j]
      (fun id => Membership.contains n.membership id) = true then some .Replicate else n.outbox[j] := by
  simp [bcastD, Fin.getElem_fin]

private theorem elt_preVotes_self (n : DNode V S MAX CAP) (t : Rust.u64) (h : (preVotesD n t).local.val < MAX) :
    (preVotesD n t).outbox[(preVotesD n t).local.val] = n.outbox[n.local.val]'h := by
  have := elt_preVotes_outbox n t ⟨n.local.val, h⟩
  simp at this; exact this

private theorem elt_bcast_self (n : DNode V S MAX CAP) (h : (bcastD n).local.val < MAX) :
    (bcastD n).outbox[(bcastD n).local.val] = n.outbox[n.local.val]'h := by
  have := elt_bcast_outbox n ⟨n.local.val, h⟩
  simp at this; exact this

/-! ## Barrier -/

private theorem elt_refresh (x y : DNode V S MAX CAP) (hr : Refresh x y) :
    y.state = x.state ∧ y.dirty = x.dirty ∧ y.extra_reply = x.extra_reply ∧ (y.role = x.role ∨ y.role = .Follower) ∧
    ∀ i, SlotKept (memOf x.state x.bootstrap) x y i := by
  obtain ⟨n1, ⟨hshape, hkept, -⟩, -, hfin⟩ := hr
  obtain ⟨P, Vo, A, Nx, Mt, O, rfl⟩ : ∃ P Vo A Nx Mt O, n1 = { x with membership := memOf x.state x.bootstrap, peers := P, votes := Vo, active := A, «next» := Nx, matched := Mt, outbox := O } :=
    ⟨_, _, _, _, _, _, hshape⟩
  simp only at hfin
  rcases hfin with rfl | ⟨-, -, -, r, d, rfl⟩
  · exact ⟨rfl, rfl, rfl, Or.inl rfl, hkept⟩
  · exact ⟨rfl, rfl, rfl, Or.inr rfl, hkept⟩

private theorem elt_snapOk_same (g : Membership MAX) (G : Ghost (Record V MAX) K) (s s' : DState V S MAX CAP)
    (hsn : s'.snapshot = s.snapshot) (h : SnapOk g G s) : SnapOk g G s' := by
  unfold SnapOk at *
  have h1 : snapMem s' g = snapMem s g := by unfold snapMem memInit; rw [hsn]
  have h2 : boundary G s' = boundary G s := by unfold boundary; rw [base_of_snapshot _ _ hsn]
  rw [h1, h2]; exact h

/-- What a `barrier` does to a node, in terms of full logs and slots. -/
private theorem elt_barrier (g : Membership MAX) (G : Ghost (Record V MAX) K) (me : Id) (p n3 : DNode V S MAX CAP)
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
  have hsn2 : SnapOk g G s' := elt_snapOk_same g G p.state s' hsn' hsn
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
  obtain ⟨hst3, hd3, hex3, hrole3, hkept3⟩ := elt_refresh _ _ hR
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
  obtain ⟨id, hid1, hid2⟩ := elt_some_and _ _ hid
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
    hdyn3, by rw [hst3]; exact hs2, by rw [hst3]; exact elt_snapOk_same g G s' _ rfl hsn2, Or.inr ⟨hd3, _, rfl, rfl,
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

private theorem elt_chain_noop (ids : Vector Id K) (g : Membership MAX) (G : Ghost (Record V MAX) K)
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

private theorem elt_cfgs_noop (l : List (DEntry V MAX)) (e : DEntry V MAX) (he : e.value = none)
    (h : ∀ i (hi : i < l.length) X, recCfg (l[i]).value = some X → MemOk X) :
    ∀ i (hi : i < (l ++ [e]).length) X, recCfg ((l ++ [e])[i]).value = some X → MemOk X := by
  intro i hi X hX
  by_cases hil : i < l.length
  · rw [List.getElem_append_left hil] at hX; exact h i hil X hX
  · have : i = l.length := by simp at hi; omega
    subst this
    rw [List.getElem_append_right (by omega)] at hX
    simp [he, recCfg] at hX

/-- A leader `p` of node `k` (possibly dirty, idle outbox) running `barrier` then
    `broadcast` keeps its local clauses. -/
private theorem elt_lead (ids : Vector Id K) (g : Membership MAX) (C : World V S MAX CAP K)
    (G : Ghost (Record V MAX) K) (k : Fin K) (p n3 : DNode V S MAX CAP)
    (hdyn : DynOk g ids[k] p) (hr : p.role = .Leader) (hs : StateOk G p.state) (hsn : SnapOk g G p.state)
    (hterm : (C.disk k).hard.term.val ≤ p.state.hard.term.val)
    (hcons : Consistent G (fullLog G p.state) ∨ (p.dirty = true ∧ Leading G k p) ∨ PendingWin ids g C G k p)
    (hclean : p.dirty = false → p.state = C.disk k)
    (hacks : ∀ t j, (k, t, j) ∈ G.acks → ∀ j' ≤ j, Kept G k t j' (p.state.hard.term.val + 1) (fullLog G p.state))
    (helect : ∀ T eL, G.elect T = some (k, eL) → (C.disk k).hard.term.val < T → p.state.hard.term.val < T → False)
    (hballot : ∀ T c vlog, (T, k, c, vlog) ∈ G.ballots → p.state.hard.term.val = T →
      p.state.hard.voted_for = some ids[c])
    (hst : LeadLog ids g G k p ∨ PendingWin ids g C G k p) (hlok : LeaderOk' ids G k p)
    (hout : ∀ j : Fin MAX, p.outbox[j] = none) (hex : p.extra_reply = none)
    (hcom : CommittedBy ids g G p.state.hard.term.val ((fullLog G p.state).take p.state.hard.commit.val))
    (hB : BarrierD p n3) : LocalOk' ids g C G k ⟨bcastD n3⟩ := by
  obtain ⟨ht3, hv3, hex3, hrole3, hdyn3, hs3, hsn3, hcase⟩ := elt_barrier g G ids[k] p n3 hdyn hs hsn hB
  have hchain : ChainIn (ids := ids) (g := g) G (fullLog G p.state) ∧
      ∀ i (hi : i < (fullLog G p.state).length) X, recCfg ((fullLog G p.state)[i]).value = some X → MemOk X := by
    rcases hst with h | h
    · exact ⟨h.chain, h.cfgs⟩
    · exact ⟨h.2.2.2.2.2.2.2.2.1, h.2.2.2.2.2.2.2.2.2⟩
  have hnc : n3.role ≠ .Candidate := by rcases hrole3 with h | h <;> rw [h] <;> simp [hr]
  have hlenp := fullLog_length G p.state hs
  have hcle : p.state.hard.commit.val ≤ (fullLog G p.state).length := by have := hs.commit_le; omega
  have hslot : ∀ i (hi : i < MAX), p.peers[i] = some ids[k] ↔ i = p.local.val := hdyn.local_slot
  have hslot3 : ∀ i (hi : i < MAX), n3.peers[i] = some ids[k] ↔ i = n3.local.val := hdyn3.local_slot
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
  have F3 : n3.dirty = false → n3 = p := by
    rcases hcase with h | ⟨hd, -⟩
    · intro _; exact h
    · intro h; rw [hd] at h; cases h
  have F4 : ChainIn (ids := ids) (g := g) G (fullLog G n3.state) ∧
      ∀ i (hi : i < (fullLog G n3.state).length) X, recCfg ((fullLog G n3.state)[i]).value = some X → MemOk X := by
    rcases hcase with rfl | ⟨-, e, -, hev, hfl, -⟩
    · exact hchain
    · rw [hfl]; exact ⟨elt_chain_noop ids g G _ e hev hchain.1, elt_cfgs_noop _ e hev hchain.2⟩
  have hW3 : Leading G k n3 ∨ PendingWin ids g C G k n3 := by
    rcases hst with h | ⟨d1, -, d2, d3, d4, d5, d6, d7, -, -⟩
    · left; obtain ⟨eL, he, -⟩ := h.elected; unfold Leading; rw [ht3]; exact ⟨eL, he⟩
    · right
      refine ⟨?_, hnc, by rw [ht3]; exact d2, by rw [ht3]; exact d3, by rw [hv3]; exact d4, d5, d6.trans F1, ?_, F4.1, F4.2⟩
      · rcases hcase with rfl | ⟨hd, -⟩
        · exact d1
        · exact hd
      · intro i h hle
        rw [ht3]
        by_cases hi : i < (fullLog G p.state).length
        · rw [← d7 i hi hle]
          exact congrArg (fun x : DEntry V MAX => x.id.term) (List.IsPrefix.getElem F1 hi).symm
        · exact F2 i h (by omega)
  have hW3' : Leading G k (bcastD n3) ∨ PendingWin ids g (C.setLive k ⟨bcastD n3⟩) G k (bcastD n3) := by
    rcases hW3 with h | h
    · exact Or.inl h
    · exact Or.inr ((pendingWin_setLive ids g C G k k _ (bcastD n3)).mpr h)
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
  have F7 : CommitOk' ids g C G k n3 := by
    rcases hcase with rfl | ⟨hd3, e, het, hev, hfl, hslots, hc | ⟨hlt, hv, hvt, hq⟩⟩
    · exact Or.inl hcom
    · left; rw [ht3, hc, hfl, List.take_append_of_le_length hcle]; exact hcom
    have key : ∀ G2 : Ghost (Record V MAX) K, G2.leader n3.state.hard.term.val = some (fullLog G n3.state) →
        (k, n3.state.hard.term.val, (fullLog G n3.state).length) ∈ G2.acks → (∀ x ∈ G.acks, x ∈ G2.acks) →
        CommittedBy ids g G2 n3.state.hard.term.val ((fullLog G n3.state).take n3.state.hard.commit.val) := by
      intro G2 hl2 ha2 hac2
      refine Or.inr ⟨n3.state.hard.term.val, n3.state.hard.commit.val, Nat.le_refl _,
        ⟨(fullLog G n3.state).length, by omega, by omega, fullLog G n3.state, hl2, Nat.le_refl _,
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
          refine ⟨k, Option.some.inj h2, (fullLog G n3.state).length, ?_, ha2⟩
          rw [hfl]; simp; omega
        · rw [if_neg hip] at hle
          obtain ⟨w, hw, ha⟩ := hlok.matched i hip (by omega)
          rw [hpi] at hw
          refine ⟨w, (Option.some.inj hw).symm, (p.matched[i]).val, hle, hac2 _ ?_⟩
          rw [ht3]; exact ha
      · rw [prefix_eq_take G2 _ _ _ hl2]; exact List.prefix_refl _
    rcases hW3 with hL3 | hP3
    · exact Or.inr (Or.inl ⟨hd3, hL3, key _ (by simp [withOwnD]) (by simp [withOwnD])
        (fun x h => by simp [withOwnD, h])⟩)
    · exact Or.inr (Or.inr ⟨fullLog G (C.disk k), hP3, rfl, key _ (by simp [winOwnD]) (by simp [winOwnD])
        (fun x h => by simp [winOwnD, h])⟩)
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
      lead := fun hL => ?_
      leader := fun _ => ⟨hW3', F6.matched, F6.own⟩
      candidate := fun h => absurd h hnc
      outbox := ?_
      outbox_self := ?_
      extra := by intro to o h; have : n3.extra_reply = some (to, o) := h; rw [hex3, hex] at this; cases this
      votes := fun _ _ _ _ _ _ h => absurd h.1 hnc
      committed := ?_ }
  · by_cases hd : n3.dirty = true
    · rcases hW3' with h | h
      · exact Or.inr (Or.inl ⟨hd, h⟩)
      · exact Or.inr (Or.inr h)
    · left
      have := F3 (by simpa using hd)
      subst this
      rcases hcons with h | ⟨h, -⟩ | ⟨h, -⟩
      · exact h
      · exact absurd h hd
      · exact absurd h hd
  · intro hd
    have hd' : n3.dirty = false := hd
    have := F3 hd'
    subst this
    exact hclean hd'
  · rcases hst with hlead | hp
    case inr =>
      exfalso; obtain ⟨eL, he⟩ := hL; have := hp.2.2.1; rw [← ht3] at this
      have he' : G.elect n3.state.hard.term.val = some (k, eL) := he
      rw [he'] at this; cases this
    refine ⟨?_, ?_, F4.1, F4.2⟩
    · obtain ⟨eL, he, hp, hb⟩ := hlead.elected
      refine ⟨eL, by show G.elect n3.state.hard.term.val = _; rw [ht3]; exact he, hp.trans F1, ?_⟩
      intro i h hle
      show ((fullLog G n3.state)[i]).id.term = n3.state.hard.term
      rw [ht3]
      by_cases hi : i < (fullLog G p.state).length
      · rw [← hb i hi hle]
        exact congrArg (fun x : DEntry V MAX => x.id.term) (List.IsPrefix.getElem F1 hi).symm
      · exact F2 i h (by omega)
    · obtain ⟨L, hL, hLp, hLd⟩ := hlead.log
      refine ⟨L, by show G.leader n3.state.hard.term.val = _; rw [ht3]; exact hL, hLp.trans F1, ?_⟩
      intro hd
      have hd' : n3.dirty = false := hd
      have := F3 hd'
      subst this
      exact hLd hd'
  · intro i o ho
    have ho' : (bcastD n3).outbox[i] = some o := ho
    rw [elt_bcast_outbox] at ho'
    split at ho'
    · rename_i hc
      cases ho'
      obtain ⟨x, hx, -⟩ := elt_some_and _ _ hc.2
      refine ⟨x, hx, ?_⟩
      simp only [OutOk, setLive_self']
      exact hW3'
    · rw [F5 i] at ho'; cases ho'
  · intro h o ho
    rw [(elt_bcast_self n3 h).trans (F5 ⟨n3.local.val, h⟩)] at ho; cases ho
  · unfold CommitOk'
    rw [setLive_disk]
    rcases F7 with h | h | ⟨eL, h1, h2, h3⟩
    · exact Or.inl h
    · exact Or.inr (Or.inl h)
    · exact Or.inr (Or.inr ⟨eL, (pendingWin_setLive ids g C G k k _ (bcastD n3)).mpr h1, h2, h3⟩)

/-! ## Election safety for a self-elected node -/

private theorem elt_lcp {α : Type} : ∀ (l1 l2 : List α), ∃ a, a ≤ l1.length ∧ a ≤ l2.length ∧
    l1.take a = l2.take a ∧ ∀ q, q <+: l1 → q <+: l2 → q.length ≤ a
  | [], _ => ⟨0, by simp, by simp, by simp, fun q h1 _ => by have := h1.length_le; simpa using this⟩
  | _ :: _, [] => ⟨0, by simp, by simp, by simp, fun q _ h2 => by have := h2.length_le; simpa using this⟩
  | x :: xs, y :: ys => by
    by_cases hxy : x = y
    · subst hxy
      obtain ⟨a, h1, h2, h3, h4⟩ := elt_lcp xs ys
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

private theorem elt_min (P : Nat → Prop) (n : Nat) (h : P n) : ∃ m, P m ∧ ∀ m' < m, ¬ P m' := by
  induction n using Nat.strongRecOn with
  | _ n ih =>
    by_cases hx : ∃ m' < n, P m'
    · obtain ⟨m', hm', hp⟩ := hx; exact ih m' hm' hp
    · exact ⟨n, h, fun m' hm' hp => hx ⟨m', hm', hp⟩⟩

/-- A quorum of the configuration of a consistent log of terms below `T`, whose
    members kept every acknowledged prefix in that log, meets the voters of the
    election of term `T`. -/
private theorem elt_inter (ids : Vector Id K) (g : Membership MAX) (hid : ∀ a b : Fin K, ids[a] = ids[b] → a = b)
    (G : Ghost (Record V MAX) K) (hw : Wf ids g G) (T : Nat) (c : Fin K) (eL' : List (DEntry V MAX))
    (he : G.elect T = some (c, eL')) (l : List (DEntry V MAX)) (hl : Consistent G l)
    (hlt : ∀ e ∈ l, e.id.term.val < T) (P : Id → Prop) (hP : Quorum (cfgOf g l) P)
    (hkept : ∀ id, P id → ∃ w : Fin K, ids[w] = id ∧
      ∀ t j', (w, t, j') ∈ G.acks → t < T → ∀ j ≤ j', Kept G w t j T l) :
    ∃ id, P id ∧ Voters ids G T c eL' id := by
  obtain ⟨hT0, hcons', hlt', hquo'⟩ := hw.elect T c eL' he
  obtain ⟨a, hal, hal', hta, hmax⟩ := elt_lcp l eL'
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
    obtain ⟨m, ⟨hm2, ham, hmk2, hcm⟩, hmin⟩ := elt_min
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

/-- `elt_inter` asking members to keep only committed acknowledged prefixes. -/
private theorem el_inter (ids : Vector Id K) (g : Membership MAX) (hid : ∀ a b : Fin K, ids[a] = ids[b] → a = b)
    (G : Ghost (Record V MAX) K) (hw : Wf ids g G) (T : Nat) (c : Fin K) (eL' : List (DEntry V MAX))
    (he : G.elect T = some (c, eL')) (l : List (DEntry V MAX)) (hl : Consistent G l)
    (hlt : ∀ e ∈ l, e.id.term.val < T) (P : Id → Prop) (hP : Quorum (cfgOf g l) P)
    (hkept : ∀ id, P id → ∃ w : Fin K, ids[w] = id ∧
      ∀ t j' j, (w, t, j') ∈ G.acks → t < T → j ≤ j' → CommitQ ids g G t j → G.prefix t j <+: l) :
    ∃ id, P id ∧ Voters ids G T c eL' id := by
  obtain ⟨hT0, hcons', hlt', hquo'⟩ := hw.elect T c eL' he
  obtain ⟨a, hal, hal', hta, hmax⟩ := elt_lcp l eL'
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
    obtain ⟨m, ⟨hm2, ham, hmk2, hcm⟩, hmin⟩ := elt_min
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
    have hpl : G.prefix t' j' <+: l := hk t' j'' j' hack ht'T hj'' ⟨n', hj'0, hjn', L', hL', hnL, hterm', hquo⟩
    rw [prefix_eq_take G t' j' L' hL'] at hpl
    have := hmax _ (hpL'.trans hpl) (List.take_prefix _ _)
    simp at this; omega
  · have hnear2 : Near (cfgOf g (eL'.take a)) (cfgOf g eL') := by
      apply near_tail eL' a hch'.1
      intro k1 k2 hk2 h1 h12 hc1 hc2
      exact hex ⟨k1, k2, hk2, h12, h1, hc1, hc2⟩
    rw [← hta] at hnear2
    exact near_inter _ _ _ hnear1 hnear2 P _ hP hquo'

/-! ## Growing the ghost -/

private theorem elt_ackOk_le (G : Ghost (Record V MAX) K) (t j j' : Nat) (h : AckOk G t j') (hj : j ≤ j') : AckOk G t j := by
  obtain ⟨L, hL, hl⟩ := h; exact ⟨L, hL, by omega⟩

private theorem elt_ackOk_ext {G G' : Ghost (Record V MAX) K} (e : Extends G G') (t j : Nat) (h : AckOk G t j) :
    AckOk G' t j := by
  obtain ⟨L, hL, hl⟩ := h
  obtain ⟨L', hL', hp⟩ := e.leader t L hL
  exact ⟨L', hL', Nat.le_trans hl hp.length_le⟩

private theorem elt_snapOk_ext (g : Membership MAX) {G G' : Ghost (Record V MAX) K} (e : Extends G G')
    (s : DState V S MAX CAP) (hs : StateOk G s) (h : SnapOk g G s) : SnapOk g G' s := by
  have hf := fullLog_extends e s hs
  rw [fullLog_def, fullLog_def] at hf
  have hb : boundary G' s = boundary G s := List.append_cancel_right hf
  unfold SnapOk at *; rw [hb]; exact h

private theorem elt_chainIn_ext (ids : Vector Id K) (g : Membership MAX) {G G' : Ghost (Record V MAX) K}
    (e : Extends G G') (L : List (DEntry V MAX)) (h : ChainIn (ids := ids) (g := g) G L) :
    ChainIn (ids := ids) (g := g) G' L :=
  ⟨h.1, fun k i hk hi hc1 hc2 => committedBy_mono e _ _ (h.2 k i hk hi hc1 hc2)⟩

private theorem elt_withOwn_ext {G G' : Ghost (Record V MAX) K} (e : Extends G G') (j : Fin K) (n : DNode V S MAX CAP)
    (hs : StateOk G n.state) : Extends (withOwnD G j n) (withOwnD G' j n) := by
  have hf := fullLog_extends e n.state hs
  refine ⟨fun t L h => ?_, fun t x h => e.elect t x h, fun a h => ?_, fun b h => e.ballots b h⟩
  · simp only [withOwnD] at h ⊢
    split at h
    · cases h; rw [if_pos (by assumption), hf]; exact ⟨_, rfl, List.prefix_refl _⟩
    · rw [if_neg (by assumption)]; exact e.leader t L h
  · simp only [withOwnD, List.mem_cons] at h ⊢
    rw [hf]
    rcases h with h | h
    · exact Or.inl h
    · exact Or.inr (e.acks a h)

private theorem el_pw_ext (ids : Vector Id K) (g : Membership MAX) (C : World V S MAX CAP K)
    {G G' : Ghost (Record V MAX) K} (e : Extends G G') (j : Fin K) (n : DNode V S MAX CAP)
    (hs : StateOk G n.state) (hds : StateOk G (C.disk j)) (hnone : G'.elect n.state.hard.term.val = none)
    (h : PendingWin ids g C G j n) : PendingWin ids g C G' j n := by
  obtain ⟨d1, d0, -, d3, d4, d5, d6, d7, d8, d9⟩ := h
  have hf := fullLog_extends e n.state hs
  have hfd := fullLog_extends e (C.disk j) hds
  refine ⟨d1, d0, hnone, d3, d4, ?_, ?_, ?_, ?_, ?_⟩ <;> (try rw [hfd]) <;> (try rw [hf])
  · exact d5
  · exact d6
  · exact d7
  · exact elt_chainIn_ext ids g e _ d8
  · exact d9

private theorem el_winOwn_ext {G G' : Ghost (Record V MAX) K} (e : Extends G G') (j : Fin K) (n : DNode V S MAX CAP)
    (eL : List (DEntry V MAX)) (hs : StateOk G n.state) : Extends (winOwnD G j n eL) (winOwnD G' j n eL) := by
  have hf := fullLog_extends e n.state hs
  refine ⟨fun t L h => ?_, fun t x h => ?_, fun a h => ?_, fun b h => ?_⟩
  · simp only [winOwnD] at h ⊢
    split at h
    · cases h; rw [if_pos (by assumption), hf]; exact ⟨_, rfl, List.prefix_refl _⟩
    · rw [if_neg (by assumption)]; exact e.leader t L h
  · simp only [winOwnD] at h ⊢
    split at h
    · rw [if_pos (by assumption)]; exact h
    · rw [if_neg (by assumption)]; exact e.elect t x h
  · simp only [winOwnD, List.mem_cons] at h ⊢
    rw [hf]
    rcases h with h | h
    · exact Or.inl h
    · exact Or.inr (e.acks a h)
  · simp only [winOwnD, List.mem_cons] at h ⊢
    rcases h with h | h
    · exact Or.inl h
    · exact Or.inr (e.ballots b h)

private theorem elt_outOk_ext (ids : Vector Id K) (g : Membership MAX) (C : World V S MAX CAP K) {G G' : Ghost (Record V MAX) K}
    (e : Extends G G') (j : Fin K) (hs : StateOk G (C.node j).state) (to : Id) (o : Outbound)
    (hpw : PendingWin ids g C G j (C.node j) → PendingWin ids g C G' j (C.node j))
    (h : OutOk ids g C G j to o) : OutOk ids g C G' j to o := by
  cases o with
  | Vote => exact h
  | Voted gr =>
    dsimp only [OutOk] at h ⊢
    intro hg
    obtain ⟨a, last, b, c⟩ := h hg
    refine ⟨a, last, b, ?_⟩
    rw [fullLog_extends e _ hs]; exact c
  | Replicated i r =>
    dsimp only [OutOk] at h ⊢
    intro hr
    obtain ⟨a, b⟩ := h hr
    obtain ⟨L, hL, hle⟩ := b
    rw [prefix_extends e _ _ L hL hle, fullLog_extends e _ hs]
    exact ⟨a, elt_ackOk_ext e _ _ ⟨L, hL, hle⟩⟩
  | Replicate =>
    dsimp only [OutOk] at h ⊢
    rcases h with ⟨eL, he⟩ | h
    · exact Or.inl ⟨eL, e.elect _ _ he⟩
    · exact Or.inr (hpw h)
  | PreVote _ => trivial
  | PreVoted _ _ => trivial

/-- The ghost once node `k` wins term `t1` with log `L0` by its own vote. -/
private def eltGhost (G : Ghost (Record V MAX) K) (t1 : Nat) (k : Fin K) (L0 : List (DEntry V MAX)) :
    Ghost (Record V MAX) K :=
  { G with leader := fun T => if T = t1 then some L0 else G.leader T, elect := fun T => if T = t1 then some (k, L0) else G.elect T, ballots := (t1, k, k, L0) :: G.ballots }

private theorem el_elect_in (ids : Vector Id K) (g : Membership MAX) (hid : ∀ a b : Fin K, ids[a] = ids[b] → a = b)
    (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (hi : Inv ids g C G) (k : Fin K)
    (hidle : Idle (C.node k)) (hfol : (C.node k).role = .Follower)
    (hvf : (C.node k).state.hard.voted_for = some ids[k])
    (hLt0 : ∀ e ∈ fullLog G (C.node k).state, e.id.term.val < (C.node k).state.hard.term.val)
    (hel : G.elect (C.node k).state.hard.term.val = none)
    (hq : Quorum (cfgOf g (fullLog G (C.node k).state)) (fun id => id = ids[k] ∨ ∃ w : Fin K, ids[w] = id ∧
      ∃ vlog, ((C.node k).state.hard.term.val, w, k, vlog) ∈ G.ballots ∧
        upToDate (lastOf (fullLog G (C.node k).state)) (lastOf vlog)))
    (hvote : ∀ env ∈ C.sent, ∀ last, env.from = ids[k] → env.message = .Vote (C.node k).state.hard.term last →
      lastId (C.node k).state = last) :
    ∃ G', Extends G G' ∧ Inv ids g C G' ∧
      G'.elect (C.node k).state.hard.term.val = some (k, fullLog G (C.node k).state) ∧
      G'.leader (C.node k).state.hard.term.val = some (fullLog G (C.node k).state) := by
  have hrl : (C.node k).role ≠ .Leader := by rw [hfol]; intro h; cases h
  have hcl := hi.clean k hidle.1
  have hs := (hi.live k).1
  have hdt : (C.disk k).hard.term.val = (C.node k).state.hard.term.val := by rw [hcl]
  have hdvf : (C.disk k).hard.voted_for = some ids[k] := by rw [← hcl]; exact hvf
  have hcons : Consistent G (fullLog G (C.node k).state) := by
    rcases hi.consistent_live k with h | ⟨h, -⟩ | ⟨h, -⟩
    · exact h
    all_goals rw [hidle.1] at h; cases h
  have hlast : lastOf (fullLog G (C.node k).state) = lastId (C.node k).state := lastOf_fullLog G _ hs
  obtain ⟨t1, ht1⟩ : ∃ t1, (C.node k).state.hard.term.val = t1 := ⟨_, rfl⟩
  obtain ⟨L0, hL0⟩ : ∃ L0, fullLog G (C.node k).state = L0 := ⟨_, rfl⟩
  rw [ht1, hL0]
  rw [hL0] at hcons hq hlast
  rw [ht1] at hel hq
  have hLt : ∀ e ∈ L0, e.id.term.val < t1 := by
    intro e he; rw [← hL0] at he; have := hLt0 e he; omega
  have hlnone : G.leader t1 = none := by
    cases h : G.leader t1 with
    | none => rfl
    | some L =>
      obtain ⟨-, -, ⟨c, eL, he, -⟩, -⟩ := hi.wf.leader t1 L h
      rw [hel] at he; cases he
  let G' := eltGhost G t1 k L0
  have hel' : ∀ T, G'.elect T = if T = t1 then some (k, L0) else G.elect T := fun T => rfl
  have hle' : ∀ T, G'.leader T = if T = t1 then some L0 else G.leader T := fun T => rfl
  have hbal' : ∀ b, b ∈ G'.ballots ↔ b = (t1, k, k, L0) ∨ b ∈ G.ballots := fun b => List.mem_cons
  have hack' : G'.acks = G.acks := rfl
  have hlead : ∀ T L, G.leader T = some L → G'.leader T = some L := by
    intro T L h
    have : T ≠ t1 := by intro e; subst e; rw [hlnone] at h; cases h
    rw [hle', if_neg this]; exact h
  have helect : ∀ T x, G.elect T = some x → G'.elect T = some x := by
    intro T x h
    have : T ≠ t1 := by intro e; subst e; rw [hel] at h; cases h
    rw [hel', if_neg this]; exact h
  have hext : Extends G G' :=
    ⟨fun T L h => ⟨L, hlead T L h, List.prefix_refl L⟩, helect, fun _ h => h,
      fun _ h => List.mem_cons_of_mem _ h⟩
  have hfle : ∀ j, fullLog G' (C.node j).state = fullLog G (C.node j).state :=
    fun j => fullLog_extends hext _ (hi.live j).1
  have hfde : ∀ j, fullLog G' (C.disk j) = fullLog G (C.disk j) := fun j => fullLog_extends hext _ (hi.disk j).1
  have hLead : ∀ j, Leading G j (C.node j) → Leading G' j (C.node j) := by
    intro j ⟨eL, he⟩; exact ⟨eL, helect _ _ he⟩
  have hLead' : ∀ j, Leading G' j (C.node j) → Leading G j (C.node j) ∨ (j = k ∧ (C.node j).state.hard.term.val = t1) := by
    intro j ⟨eL, he⟩
    rw [hel'] at he
    split at he
    · rename_i hT
      cases he
      exact Or.inr ⟨rfl, hT⟩
    · exact Or.inl ⟨eL, he⟩
  have ht0 : 0 < t1 := by
    apply Classical.byContradiction; intro h0
    have := hs.unvoted (by omega); rw [hvf] at this; cases this
  have hchain0 : Chain ids g G L0 := chain_of_consistent G hi.wf L0 hcons
  have hchainIn : ∀ t L', G'.leader t = some L' → ChainIn (ids := ids) (g := g) G L' := by
    intro t L' h
    rw [hle'] at h
    split at h
    · cases h; exact hchain0
    · exact (hi.wf.leader t L' h).2.2.2
  have hterms : ∀ t L', G'.leader t = some L' → ∀ e ∈ L', e.id.term.val ≤ t := by
    intro t L' h e he
    rw [hle'] at h
    split at h
    · cases h; rename_i hT; have := hLt e he; omega
    · exact ((hi.wf.leader t L' h).2.1 e he).2
  have hcons' : Consistent G' L0 := consistent_extends hext _ hcons
  have hwf' : Wf ids g G' := by
    refine ⟨?_, ?_, ?_, good_preserve hext hi.wf.good hchainIn hterms⟩
    · -- Wf.leader
      intro T L h
      rw [hle'] at h
      split at h
      · cases h
        rename_i hT
        refine ⟨hcons', ?_, ⟨k, L0, by rw [hel', if_pos hT], List.prefix_refl _, fun i hi hle => by omega⟩,
          ⟨hchain0.1, fun a b hab hb hca hcb => committedBy_mono hext _ _ (hchain0.2 a b hab hb hca hcb)⟩⟩
        intro e he
        refine ⟨(consistent_terms' G hi.wf _ hcons e he).1, ?_⟩
        have := hLt e he; omega
      · obtain ⟨a, b, ⟨c, eL, he, hp, hb⟩, d⟩ := hi.wf.leader T L h
        exact ⟨consistent_extends hext _ a, b, ⟨c, eL, helect _ _ he, hp, hb⟩,
          ⟨d.1, fun a b hab hb hca hcb => committedBy_mono hext _ _ (d.2 a b hab hb hca hcb)⟩⟩
    · -- Wf.elect
      intro T c eL h
      rw [hel'] at h
      split at h
      · cases h
        rename_i hT
        refine ⟨by omega, hcons', fun e he => by rw [hT]; exact hLt e he, ?_⟩
        refine quorum_mono _ _ _ ?_ hq
        intro id hid'
        rcases hid' with hid' | ⟨w, hw, v, hv, hu⟩
        · exact ⟨k, hid'.symm, L0, (hbal' _).mpr (Or.inl (by rw [hT])), Or.inr ⟨rfl, Nat.le_refl _⟩⟩
        · exact ⟨w, hw, v, hext.ballots _ (by rw [hT]; exact hv), hu⟩
      · obtain ⟨a, b, c', d⟩ := hi.wf.elect T c eL h
        exact ⟨a, consistent_extends hext _ b, c', quorum_mono _ _ _
          (fun id ⟨w, hw, v, hv, hu⟩ => ⟨w, hw, v, hext.ballots _ hv, hu⟩) d⟩
    · -- Wf.ballot
      intro T w c vlog h
      rcases (hbal' _).mp h with h | h
      · simp only [Prod.mk.injEq] at h
        obtain ⟨hT, hw, hc, hv⟩ := h
        rw [hT, hw, hc, hv]
        refine ⟨hcons', ?_⟩
        intro t j' ha hlt j hj
        left
        obtain ⟨hak, -, hkept⟩ := hi.acks k t j' ha
        have := (hkept j hj).1
        rw [hL0, ht1] at this
        have this' : Kept G k t j t1 L0 := by
          rcases this with h | ⟨t'', h1, h2, c'', eL'', he'', h3⟩
          · exact Or.inl h
          · by_cases ht'' : t'' = t1
            · rw [ht'', hel] at he''; cases he''
            · exact Or.inr ⟨t'', h1, by omega, c'', eL'', he'', h3⟩
        exact kept_extends hext _ _ _ _ _ this' (elt_ackOk_le G t j j' hak hj)
      · obtain ⟨a, b⟩ := hi.wf.ballot T w c vlog h
        refine ⟨consistent_extends hext _ a, ?_⟩
        intro t j' ha hlt j hj
        rcases b t j' ha hlt j hj with b | ⟨c', eL', he, hne, hnp⟩
        · exact Or.inl (kept_extends hext _ _ _ _ _ b (elt_ackOk_le G t j j' (hi.acks w t j' ha).1 hj))
        · refine Or.inr ⟨c', eL', helect _ _ he, hne, ?_⟩
          obtain ⟨L, hL, hle⟩ := elt_ackOk_le G t j j' (hi.acks w t j' ha).1 hj
          rw [prefix_extends hext t j L hL hle]; exact hnp
  -- no other node holds a pending win of term `t1`
  have hnopend : ∀ j, PendingWin ids g C G j (C.node j) → (C.node j).state.hard.term.val ≠ t1 := by
    intro j hp hjt
    obtain ⟨d1, -, -, d3, d4, d5, -, -, -, -⟩ := hp
    have hjk : j ≠ k := by intro e; subst e; rw [hidle.1] at d1; cases d1
    have hds := (hi.disk j).1
    obtain ⟨id, rfl, w, hw, vlog, hb, -⟩ := el_inter ids g hid G' hwf' t1 k L0 (by simp [hel'])
      (fullLog G (C.disk j)) (consistent_extends hext _ (hi.consistent_disk j))
      (fun e he => by have := hds.terms e he; omega) _ d5 (by
        intro id hid'
        refine ⟨j, hid'.symm, fun t j' jj ha ht hjj hc => ?_⟩
        rw [hack'] at ha
        obtain ⟨hak, -, hk⟩ := hi.acks j t j' ha
        obtain ⟨L, hL, hle⟩ := elt_ackOk_le G t jj j' hak hjj
        rw [prefix_extends hext t jj L hL hle]
        rcases (hk jj hjj).2 with h | ⟨t'', h1, h2, c'', eL'', he'', -, hn⟩
        · exact h
        · exfalso; apply hn
          have := leader_complete hid G' hwf' t'' c'' eL'' (helect _ _ he'') t jj h1 hc
          rwa [prefix_extends hext t jj L hL hle] at this)
    obtain rfl : w = j := hid w j hw
    rcases (hbal' _).mp hb with h | h
    · simp only [Prod.mk.injEq] at h; exact hjk h.2.1
    · have := (hi.ballots _ _ _ _ h).2.2.2 hjt
      rw [d4] at this; exact hjk (hid _ _ (Option.some.inj this))
  have hPW : ∀ j, PendingWin ids g C G j (C.node j) → PendingWin ids g C G' j (C.node j) := by
    intro j hp
    refine el_pw_ext ids g C hext j _ (hi.live j).1 (hi.disk j).1 ?_ hp
    rw [hel', if_neg (hnopend j hp)]; exact hp.2.2.1
  refine ⟨G', hext, ?_, by simp [hel'], by simp [hle']⟩
  refine
    { wf := hwf'
      elect_disk := by
        intro T c eL h
        rw [hel'] at h
        split at h
        · cases h; rename_i hT; omega
        · exact hi.elect_disk T c eL h
      cfgs := ?_
      dyn := hi.dyn
      live := fun j => ⟨stateOk_extends hext _ (hi.live j).1, elt_snapOk_ext g hext _ (hi.live j).1 (hi.live j).2⟩
      disk := fun j => ⟨stateOk_extends hext _ (hi.disk j).1, elt_snapOk_ext g hext _ (hi.disk j).1 (hi.disk j).2⟩
      consistent_disk := fun j => by rw [hfde]; exact consistent_extends hext _ (hi.consistent_disk j)
      consistent_live := fun j => by
        rw [hfle]
        rcases hi.consistent_live j with h | ⟨h1, h2⟩ | h
        · exact Or.inl (consistent_extends hext _ h)
        · exact Or.inr (Or.inl ⟨h1, hLead j h2⟩)
        · rw [← hfle]; exact Or.inr (Or.inr (hPW j h))
      clean := hi.clean
      terms := hi.terms
      disk_lead := ?_
      acks := ?_
      ballots := ?_
      ballot_unique := ?_
      ballot_cand := ?_
      elect := ?_
      elect_cand := ?_
      lead := ?_
      leader := ?_
      candidate := ?_
      outbox := fun j i o h => by
        obtain ⟨to, h1, h2⟩ := hi.outbox j i o h
        exact ⟨to, h1, elt_outOk_ext ids g C hext j (hi.live j).1 to o (hPW j) h2⟩
      outbox_self := hi.outbox_self
      extra := fun j to o h => elt_outOk_ext ids g C hext j (hi.live j).1 to o (hPW j) (hi.extra j to o h)
      sent := ?_
      committed := ?_ }
  · -- cfgs
    intro t L h i hi' X hX
    rw [hle'] at h
    split at h
    · cases h
      obtain ⟨-, L, hL, hp⟩ := hcons i hi'
      have hiL : i < L.length := by have := hp.length_le; simp at this; omega
      have hget : L[i] = L0[i] := by
        have := List.IsPrefix.getElem hp (show i < (L0.take (i + 1)).length by simp; omega)
        simp at this; exact this.symm
      exact hi.cfgs _ L hL i hiL X (by rw [hget]; exact hX)
    · exact hi.cfgs t L h i hi' X hX
  · -- disk_lead
    intro j eL h
    rw [hel'] at h
    split at h
    · cases h; rename_i hT
      rw [hfde, hle', if_pos hT, ← hcl, hL0]
    · have := hi.disk_lead j eL h
      rw [hfde]
      have hne : (C.disk j).hard.term.val ≠ t1 := by rename_i hT; exact hT
      rw [hle', if_neg hne]; exact this
  · -- acks
    intro w t j h
    obtain ⟨a, b, c⟩ := hi.acks w t j h
    refine ⟨elt_ackOk_ext hext _ _ a, b, fun j' hj' => ?_⟩
    have hak := elt_ackOk_le G t j' j a hj'
    rw [hfle, hfde]
    exact ⟨kept_extends hext _ _ _ _ _ (c j' hj').1 hak, kept_extends hext _ _ _ _ _ (c j' hj').2 hak⟩
  · -- ballots
    intro T w c vlog h
    rcases (hbal' _).mp h with h | h
    · simp only [Prod.mk.injEq] at h
      obtain ⟨hT, hw, hc, hv⟩ := h
      subst hT hw hc hv
      exact ⟨Or.inl (by omega), fun h => absurd rfl h, fun _ => hdvf, fun _ => hvf⟩
    · obtain ⟨a, a', b, d⟩ := hi.ballots T w c vlog h
      refine ⟨?_, a', b, d⟩
      rcases a with a | ⟨a1, a2, a3⟩
      · exact Or.inl a
      · exact Or.inr ⟨a1, a2, helect _ _ a3⟩
  · -- ballot_unique
    intro T w c c' v v' h1 h2
    rcases (hbal' _).mp h1 with e1 | e1 <;> rcases (hbal' _).mp h2 with e2 | e2
    · simp only [Prod.mk.injEq] at e1 e2; rw [e1.2.2.1, e2.2.2.1]
    · simp only [Prod.mk.injEq] at e1
      obtain ⟨rfl, rfl, rfl, rfl⟩ := e1
      have := (hi.ballots _ _ c' v' e2).2.2.2 ht1
      rw [hvf] at this; exact hid _ _ (Option.some.inj this)
    · simp only [Prod.mk.injEq] at e2
      obtain ⟨rfl, rfl, rfl, rfl⟩ := e2
      have := (hi.ballots _ _ c v e1).2.2.2 ht1
      rw [hvf] at this; exact (hid _ _ (Option.some.inj this)).symm
    · exact hi.ballot_unique T w c c' v v' e1 e2
  · -- ballot_cand
    intro T w c vlog h hr ht
    rcases (hbal' _).mp h with h | h
    · simp only [Prod.mk.injEq] at h
      obtain ⟨rfl, -, rfl, -⟩ := h
      rw [hfol] at hr; cases hr
    · rw [hfle]; exact hi.ballot_cand T w c vlog h hr ht
  · -- elect
    intro T c eL h hd
    rw [hel'] at h
    split at h
    · cases h
      rename_i hT
      omega
    · rename_i hT
      obtain ⟨a, b, c', d⟩ := hi.elect T c eL h hd
      refine ⟨by rw [hle', if_neg hT]; exact a, by rw [hfde]; exact b, c', fun hlt => ?_⟩
      rw [hfle]; exact d hlt
  · -- elect_cand
    intro T c eL h
    rw [hel'] at h
    split at h
    · cases h
      rintro ⟨h1, -⟩; rw [hfol] at h1; cases h1
    · exact hi.elect_cand T c eL h
  · -- lead
    intro j hl
    rcases hLead' j hl with hl0 | ⟨rfl, hjt⟩
    case inr =>
      refine ⟨⟨L0, ?_, ?_, ?_⟩, ⟨L0, ?_, ?_, ?_⟩, ?_, ?_⟩
      · rw [hjt]; simp [hel']
      · rw [hfle, hL0]; exact List.prefix_refl _
      · intro i h hle; rw [hfle, hL0] at h; omega
      · rw [hjt]; simp [hle']
      · rw [hfle, hL0]; exact List.prefix_refl _
      · intro _; rw [hfle, hL0]
      · rw [hfle, hL0]; exact ⟨hchain0.1, fun a b hab hb hca hcb => committedBy_mono hext _ _ (hchain0.2 a b hab hb hca hcb)⟩
      · rw [hfle, hL0]
        intro i hi' X hX
        obtain ⟨-, L, hL, hp⟩ := hcons i hi'
        have hiL : i < L.length := by have := hp.length_le; simp at this; omega
        have hget : L[i] = L0[i] := by
          have := List.IsPrefix.getElem hp (show i < (L0.take (i + 1)).length by simp; omega)
          simp at this; exact this.symm
        exact hi.cfgs _ L hL i hiL X (by rw [hget]; exact hX)
    obtain ⟨a, b, c, d⟩ := hi.lead j hl0
    have hne : (C.node j).state.hard.term.val ≠ t1 := by
      obtain ⟨eL, he⟩ := hl0; intro e; rw [e, hel] at he; cases he
    refine ⟨?_, ?_, ?_, ?_⟩
    · obtain ⟨eL, he, hp, hb⟩ := a
      refine ⟨eL, helect _ _ he, ?_⟩
      rw [hfle]; exact ⟨hp, hb⟩
    · obtain ⟨L, hL, hp, hd⟩ := b
      refine ⟨L, hlead _ _ hL, ?_⟩
      rw [hfle]; exact ⟨hp, hd⟩
    · rw [hfle]; exact elt_chainIn_ext ids g hext _ c
    · rw [hfle]; exact d
  · -- leader
    intro j hr
    obtain ⟨a, b⟩ := hi.leader j hr
    refine ⟨a.imp (hLead j) (hPW j), b.matched, ?_⟩
    rw [hfle]; exact b.own
  · -- candidate
    intro j hr
    have := hi.candidate j hr
    unfold CandidateOk' at this ⊢
    rw [hfle]
    obtain ⟨a, b, c⟩ := this
    exact ⟨a, b, fun i hv => (c i hv).imp id (fun ⟨w, hw, vlog, hb, hu⟩ => ⟨w, hw, vlog, hext.ballots _ hb, hu⟩)⟩
  · -- sent
    intro env h
    have := hi.sent env h
    unfold SentOk at this ⊢
    refine ⟨this.1, ?_⟩
    have h2 := this.2
    revert h2
    cases hm : env.message with
    | Vote T last =>
      intro h2 c hc
      obtain ⟨a, b, d⟩ := h2 c hc
      refine ⟨a, b, fun eL he => ?_⟩
      rw [hel'] at he
      split at he
      · rename_i hT
        cases he
        rw [hlast]; exact hvote env h last hc (by rw [hm]; congr 1; exact Fin.ext (by rw [ht1]; exact hT))
      · exact d eL he
    | Voted T gr =>
      intro h2 hg w c hw hc
      rcases h2 hg w c hw hc with ⟨v, hv⟩ | ⟨eL, he⟩
      · exact Or.inl ⟨v, hext.ballots _ hv⟩
      · exact Or.inr ⟨eL, helect _ _ he⟩
    | Replicated T j r => intro h2; exact h2
    | Append T prev entry commit =>
      intro h2
      obtain ⟨L, hL, a, b, c, d, f⟩ := h2
      have hT : T.val ≠ t1 := by intro e; rw [e, hlnone] at hL; cases hL
      refine ⟨L, hlead _ _ hL, a, b, c, committedBy_mono hext _ _ d, fun c' eL he => f c' eL ?_⟩
      rw [hel', if_neg hT] at he; exact he
    | AppendBatch T prev es commit =>
      intro h2
      obtain ⟨L, hL, a, b, c, d, f⟩ := h2
      have hT : T.val ≠ t1 := by intro e; rw [e, hlnone] at hL; cases hL
      refine ⟨L, hlead _ _ hL, a, b, c, committedBy_mono hext _ _ d, fun c' eL he => f c' eL ?_⟩
      rw [hel', if_neg hT] at he; exact he
    | Install T snap =>
      intro h2
      obtain ⟨L, hL, a, b, d, e', f⟩ := h2
      have hT : T.val ≠ t1 := by intro e; rw [e, hlnone] at hL; cases hL
      refine ⟨L, hlead _ _ hL, a, b, committedBy_mono hext _ _ d, e', fun c' eL he => f c' eL ?_⟩
      rw [hel', if_neg hT] at he; exact he
    | PreVote _ _ => intro h2; exact h2
    | PreVoted _ _ _ => intro h2; exact h2
  · -- committed
    intro j
    obtain ⟨a, b⟩ := hi.committed j
    refine ⟨by rw [hfde]; exact committedBy_mono hext _ _ a, ?_⟩
    unfold CommitOk' at b ⊢
    rw [hfle]
    rcases b with b | ⟨h1, h2, h3⟩ | ⟨eL, h1, h2, h3⟩
    · exact Or.inl (committedBy_mono hext _ _ b)
    · exact Or.inr (Or.inl ⟨h1, hLead j h2, committedBy_mono (elt_withOwn_ext hext j _ (hi.live j).1) _ _ h3⟩)
    · rw [hfde]
      exact Or.inr (Or.inr ⟨eL, hPW j h1, h2, committedBy_mono (el_winOwn_ext hext j _ eL (hi.live j).1) _ _ h3⟩)

/-! ## Campaigns -/

private theorem elt_stateOk_term (G : Ghost (Record V MAX) K) (s : DState V S MAX CAP) (hs : StateOk G s)
    (T : Rust.u64) (hT : s.hard.term.val < T.val) (v : Option Id) :
    StateOk G { s with hard := { s.hard with term := T, voted_for := v } } := by
  have hfl : fullLog G ({ s with hard := { s.hard with term := T, voted_for := v } } : DState V S MAX CAP) =
      fullLog G s := fullLog_congr G _ _ rfl rfl
  refine ⟨hs.layout, hs.contig, hs.base, hs.snapshot, ?_, hs.commit_ge, hs.commit_le, ?_⟩
  · rw [hfl]; intro e he; have := hs.terms e he; show _ ≤ T.val; omega
  · intro h0; have : T.val = 0 := h0; omega

private theorem elt_voted_self (n : DNode V S MAX CAP) (hMAX : MAX < 2 ^ Rust.usizeBits) (me : Id)
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

private theorem elt_leaderInit_matched (n : DNode V S MAX CAP) (i : Fin MAX) :
    ((leaderInitD n).matched[i]).val = if i.val = n.local.val then (lastId n.state).index.val else 0 := by
  simp only [leaderInitD]
  by_cases hj : i.val = n.local.val
  · have hlt : n.local.val < MAX := hj ▸ i.isLt
    simp [hlt, hj, Rust.Slice.fill]
  · by_cases hlt : n.local.val < MAX <;> simp [hlt, hj, Ne.symm hj, Rust.Slice.fill]

private theorem elt_leaderInit_own (n : DNode V S MAX CAP) (h : (leaderInitD n).local.val < MAX) :
    ((leaderInitD n).matched[(leaderInitD n).local.val]'h).val = (lastId n.state).index.val := by
  have := elt_leaderInit_matched n ⟨n.local.val, h⟩
  simp at this; exact this


/-! ## The cases -/

omit [Rust.Clone V] [Rust.Clone S] in
private theorem el_hard_vf (h : HardState) (x : Option Id) (e : h.voted_for = x) : { h with voted_for := x } = h := by
  cases h; simp only at e; subst e; rfl

private theorem el_leaderOk_congr (G : Ghost (Record V MAX) K) (k : Fin K) (n n' : DNode V S MAX CAP)
    (ht : n'.state.hard.term = n.state.hard.term) (hfl : fullLog G n'.state = fullLog G n.state)
    (hm : n'.matched = n.matched) (hp : n'.peers = n.peers) (hl : n'.local = n.local)
    (h : LeaderOk' ids G k n) : LeaderOk' ids G k n' := by
  obtain ⟨h1, h2⟩ := h
  refine ⟨fun i hi hpos => ?_, fun hh => ?_⟩
  · rw [hm] at hpos ⊢; rw [hl] at hi; rw [hp, ht]; exact h1 i hi hpos
  · have := h2 (hl ▸ hh)
    simp only [hm, hl, hfl]; exact this

private theorem el_leadLog_congr (G : Ghost (Record V MAX) K) (k : Fin K) (n n' : DNode V S MAX CAP)
    (ht : n'.state.hard.term = n.state.hard.term) (hfl : fullLog G n'.state = fullLog G n.state)
    (hd : n'.dirty = false → n.dirty = false)
    (h : LeadLog ids g G k n) : LeadLog ids g G k n' := by
  obtain ⟨⟨eL, h1, h2, h3⟩, ⟨L, l1, l2, l3⟩, h4, h5⟩ := h
  refine ⟨⟨eL, ?_, ?_, ?_⟩, ⟨L, ?_, ?_, ?_⟩, ?_, ?_⟩ <;> simp only [ht, hfl]
  · exact h1
  · exact h2
  · exact h3
  · exact l1
  · exact l2
  · intro hd'; exact l3 (hd hd')
  · exact h4
  · exact h5

private theorem el_cand_congr (G : Ghost (Record V MAX) K) (k : Fin K) (n n' : DNode V S MAX CAP)
    (ht : n'.state.hard.term = n.state.hard.term) (hfl : fullLog G n'.state = fullLog G n.state)
    (hv : n'.votes = n.votes) (hp : n'.peers = n.peers) (hl : n'.local = n.local)
    (hvf : n'.state.hard.voted_for = n.state.hard.voted_for)
    (h : CandidateOk' ids G k n) : CandidateOk' ids G k n' := by
  unfold CandidateOk' at h ⊢
  rw [ht, hfl, hv, hp, hl, hvf]; exact h

omit [Rust.Clone V] [Rust.Clone S] in
private theorem el_qf (n : DNode V S MAX CAP) (a : Option (Fin MAX)) (src : Id) (o : Outbound) :
    (queueD n a src o).state = n.state ∧ (queueD n a src o).role = n.role ∧ (queueD n a src o).dirty = n.dirty ∧
    (queueD n a src o).prevoting = n.prevoting ∧ (queueD n a src o).config = n.config ∧
    (queueD n a src o).hooks = n.hooks ∧ (queueD n a src o).bootstrap = n.bootstrap ∧
    (queueD n a src o).peers = n.peers ∧ (queueD n a src o).local = n.local ∧
    (queueD n a src o).membership = n.membership ∧ (queueD n a src o).votes = n.votes ∧
    (queueD n a src o).matched = n.matched := by
  cases a <;> exact ⟨rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl⟩

/-- The replies' facts when the node answers with `o` or not at all. -/
private theorem el_reply' (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (hi : Inv ids g C G) (k : Fin K)
    (c : Jarl.Cluster V S MAX CAP) (src : Id) (hsrc : src ≠ ids[k]) (a : Option (Fin MAX))
    (ha : ∀ i, a = some i → (C.node k).peers[i] = some src) (n0 : DNode V S MAX CAP)
    (hp : n0.peers = (C.node k).peers) (hl : n0.local = (C.node k).local)
    (hob : ∀ j : Fin MAX, n0.outbox[j] = none) (hx : n0.extra_reply = none)
    (hcn : c.node = n0 ∨ ∃ o, c.node = queueD n0 a src o ∧ OutOk ids g (C.setLive k c) G k src o) :
    (∀ (i : Fin MAX) o', c.node.outbox[i] = some o' → ∃ to, c.node.peers[i] = some to ∧ OutOk ids g (C.setLive k c) G k to o') ∧
    (∀ hl : c.node.local.val < MAX, c.node.outbox[c.node.local.val] = none) ∧
    (∀ to o', c.node.extra_reply = some (to, o') → OutOk ids g (C.setLive k c) G k to o') := by
  rcases hcn with h | ⟨o, h, hO⟩
  · refine ⟨fun j o h' => ?_, fun hl' => ?_, fun to o h' => ?_⟩
    · rw [h] at h'; have := hob j; simp only [Fin.getElem_fin] at this h'; rw [this] at h'; cases h'
    · have e : c.node.outbox = n0.outbox := by rw [h]
      rw [e]; exact hob ⟨_, hl'⟩
    · rw [h, hx] at h'; cases h'
  · exact el_reply ids g C G hi k c src hsrc a ha o n0 hp hl hob hx h hO

/-- The node only observed the sender's term, and maybe answered with `o`. -/
private theorem el_obs_gen (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (hi : Inv ids g C G) (k : Fin K)
    (src : Id) (hsrc : src ≠ ids[k]) (a : Option (Fin MAX)) (ha : ∀ i, a = some i → (C.node k).peers[i] = some src)
    (t : Rust.u64) (n1 : DNode V S MAX CAP) (c : Jarl.Cluster V S MAX CAP)
    (hI : Idle (C.node k)) (hO : ObservedD (C.node k) src t n1)
    (hn : c.node = n1 ∨ ∃ o, c.node = queueD n1 a src o ∧ OutOk ids g (C.setLive k c) G k src o) :
    ∃ G', Extends G G' ∧ Inv ids g (C.setLive k c) G' := by
  obtain ⟨hc1, hl1, hv1, hm1, hob1, hx1, hp1, hmem1, hhk1, hb1, hA⟩ := el_observed _ _ _ _ hO
  have hob1' : ∀ j : Fin MAX, n1.outbox[j] = none := fun j => by rw [hob1]; exact hI.2.2 j
  have hx1' : n1.extra_reply = none := by rw [hx1]; exact hI.2.1
  obtain ⟨hob, hos, hex⟩ := el_reply' ids g C G hi k c src hsrc a ha n1 hp1 hl1 hob1' hx1' hn
  refine ⟨G, Extends.refl G, setLive_inv' ids g C G hi k c ?_⟩
  rcases hA with ⟨-, rfl⟩ | ⟨hup, hst, hr, hd, hpv⟩
  · refine el_keep ids g C G hi k hI c (some src) c.node.outbox c.node.extra_reply ?_ hob hos hex
    rcases hn with h | ⟨o, h, -⟩ <;> rw [h]
    cases a <;> rfl
  · have hf : c.node.state = n1.state ∧ c.node.role = n1.role ∧ c.node.dirty = n1.dirty ∧
        c.node.prevoting = n1.prevoting ∧ c.node.config = n1.config ∧ c.node.hooks = n1.hooks ∧
        c.node.bootstrap = n1.bootstrap ∧ c.node.peers = n1.peers ∧ c.node.local = n1.local ∧
        c.node.membership = n1.membership := by
      rcases hn with h | ⟨o, h, -⟩ <;> rw [h]
      · exact ⟨rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl⟩
      · obtain ⟨e1, e2, e3, e4, e5, e6, e7, e8, e9, e10, -⟩ := el_qf n1 a src o
        exact ⟨e1, e2, e3, e4, e5, e6, e7, e8, e9, e10⟩
    obtain ⟨f1, f2, f3, f4, f5, f6, f7, f8, f9, f10⟩ := hf
    exact el_up ids g C G hi k hI c _ none hup (f1.trans hst) (f2.trans hr) (f3.trans hd) (f4.trans hpv)
      (f5.trans hc1) (f6.trans hhk1) (f7.trans hb1) (f8.trans hp1) (f9.trans hl1) (f10.trans hmem1) hob hos hex

private theorem el_case_stale (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (hi : Inv ids g C G) (k : Fin K)
    (env : DEnv V S MAX) (hsrc : env.from ≠ ids[k]) (a : Option (Fin MAX))
    (ha : ∀ i, a = some i → (C.node k).peers[i] = some env.from)
    (msg : DMsg V S MAX) (n1 : DNode V S MAX CAP) (c : Jarl.Cluster V S MAX CAP)
    (hI : Idle (C.node k)) (hO : ObservedD (C.node k) env.from msg.term n1)
    (hn : c.node = n1 ∨ c.node = queueD n1 a env.from (.Voted false) ∨
      ∃ i, c.node = queueD n1 a env.from (.Replicated i (some (.Conflict 1)))) :
    ∃ G', Extends G G' ∧ Inv ids g (C.setLive k c) G' :=
  el_obs_gen ids g C G hi k env.from hsrc a ha _ n1 c hI hO (by
    rcases hn with h | h | ⟨i, h⟩
    · exact Or.inl h
    · exact Or.inr ⟨_, h, by simp [OutOk]⟩
    · exact Or.inr ⟨_, h, by simp [OutOk]⟩)

/-- `votedBy` reads the slot holding the identity. -/
private theorem el_votedBy_slot (m : DNode V S MAX CAP) (hMAX : MAX < 2 ^ Rust.usizeBits)
    (huniq : ∀ i j : Fin MAX, ∀ x, m.peers[i] = some x → m.peers[j] = some x → i = j)
    (i : Fin MAX) (id : Id) (h : m.peers[i] = some id) : votedBy m id = m.votes[i] := by
  unfold votedBy
  rw [pos_of_slot m hMAX huniq i id h]
  have : (Rust.ofNat i.val : Rust.usize).val = i.val := Nat.mod_eq_of_lt (Nat.lt_trans i.isLt hMAX)
  simp only
  rw [this, getElem!_pos m.votes i.val i.isLt]; rfl

private theorem el_votedBy_true (m : DNode V S MAX CAP) (hMAX : MAX < 2 ^ Rust.usizeBits) (id : Id)
    (h : votedBy m id = true) : ∃ i : Fin MAX, m.peers[i] = some id ∧ m.votes[i] = true := by
  unfold votedBy at h
  cases hp : pos m id with
  | none => rw [hp] at h; cases h
  | some j =>
    rw [hp] at h
    obtain ⟨hj, hpj⟩ := pos_lt m id j hMAX hp
    refine ⟨⟨j.val, hj⟩, ?_, ?_⟩
    · rw [getElem!_pos m.peers j.val hj] at hpj; exact hpj
    · simp only at h; rw [getElem!_pos m.votes j.val hj] at h; exact h

/-- An unsaved election of `k`'s is won by `k`'s own vote. -/
private theorem el_phantom_quorum (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (hi : Inv ids g C G)
    (k : Fin K) (T : Nat) (eL : List (DEntry V MAX)) (he : G.elect T = some (k, eL)) (hlt : (C.disk k).hard.term.val < T) :
    Quorum (cfgOf g eL) (fun id => id = ids[k]) := by
  obtain ⟨-, -, -, hq⟩ := hi.wf.elect T k eL he
  refine quorum_mono _ _ _ (fun id ⟨w, hw, vlog, hb, _⟩ => ?_) hq
  by_cases hwk : w = k
  · rw [← hw, hwk]
  · have := (hi.ballots T w k vlog hb).2.1 hwk; omega

/-- `LocalOk'` for idle node `k` after changing only the requester, votes, outbox and extra reply. -/
private theorem el_keepv (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (hi : Inv ids g C G) (k : Fin K)
    (hI : Idle (C.node k)) (c : Jarl.Cluster V S MAX CAP) (x : Option Id) (Vt : Vector Bool MAX)
    (O : Vector (Option Outbound) MAX) (E : Option (Id × Outbound))
    (hcn : c.node = { C.node k with request_from := x, votes := Vt, outbox := O, extra_reply := E })
    (hcand : (C.node k).role = .Candidate → CandidateOk' ids G k c.node)
    (houtbox : ∀ (i : Fin MAX) o, c.node.outbox[i] = some o → ∃ to, c.node.peers[i] = some to ∧ OutOk ids g (C.setLive k c) G k to o)
    (hoself : ∀ hl : c.node.local.val < MAX, c.node.outbox[c.node.local.val] = none)
    (hextra : ∀ to o, c.node.extra_reply = some (to, o) → OutOk ids g (C.setLive k c) G k to o) :
    LocalOk' ids g C G k c := by
  have hd := hi.dyn k
  refine el_light ids g C G hi k hI c (C.node k).state.hard (by rw [hcn]; try exact (el_state_hard_eta _).symm)
    (by rw [hcn]; exact dynOk_frame hd rfl rfl rfl rfl rfl rfl rfl hd.layout hd.contig hd.prevoting)
    (Nat.le_refl _) rfl (hi.live k).1.unvoted (fun _ => rfl) (fun _ => by rw [hcn]; exact ⟨rfl, rfl⟩)
    (fun T c' v hb ht => by rw [hcn] at ht ⊢; exact (hi.ballots T k c' v hb).2.2.2 ht)
    (fun T eL he => by rw [hcn]; exact hi.elect_cand T k eL he)
    (fun hL => by rw [hcn] at hL ⊢; have h := hi.lead k hL; exact ⟨h.elected, h.log, h.chain, h.cfgs⟩)
    (fun hr => by rw [hcn] at hr ⊢; have h := hi.leader k hr; exact ⟨h.1.resolve_right (fun hp => by have := hp.1; rw [hI.1] at this; cases this), h.2.matched, h.2.own⟩)
    (fun hr => hcand (by rw [hcn] at hr; exact hr)) houtbox hoself hextra

omit [Rust.Clone V] [Rust.Clone S] in
private theorem el_rv_outbox (n : DNode V S MAX CAP) (j : Fin MAX) (o : Outbound)
    (h : (requestVotesD n).outbox[j] = some o) :
    (o = .Vote ∧ j.val ≠ n.local.val ∧ ∃ id, n.peers[j] = some id) ∨ n.outbox[j] = some o := by
  simp only [requestVotesD, Fin.getElem_fin, Vector.getElem_ofFn] at h
  split at h
  · rename_i hc
    left
    refine ⟨(Option.some.inj h).symm, hc.1, ?_⟩
    obtain ⟨-, h2⟩ := hc
    cases hp : n.peers[j] with
    | none => simp only [Fin.getElem_fin] at hp; rw [hp] at h2; simp [Rust.Option.is_some_and] at h2
    | some id => exact ⟨id, rfl⟩
  · right; simpa using h

omit [Rust.Clone V] [Rust.Clone S] in
private theorem el_rv_self (n : DNode V S MAX CAP) (h : n.local.val < MAX) :
    (requestVotesD n).outbox[(requestVotesD n).local.val] = n.outbox[n.local.val] := by
  simp only [requestVotesD, Vector.getElem_ofFn]
  rw [if_neg (fun h' => h'.1 rfl)]; rfl

/-- `LocalOk'` for idle node `k` after a campaign it did not win at once. -/
private theorem el_campaign_local (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (hi : Inv ids g C G) (k : Fin K)
    (hI : Idle (C.node k)) (x : Option Id) (Vt : Vector Bool MAX) (cc : Rust.u64)
    (hcc : cc.val = (C.node k).state.hard.term.val + 1) (hlt : (C.node k).local.val < MAX) (n1 : DNode V S MAX CAP)
    (htm : Timers (candidateD { C.node k with request_from := x, votes := Vt } cc hlt) n1)
    (hnQ : ¬ Quorum n1.membership (fun id => votedBy n1 id = true)) (c : Jarl.Cluster V S MAX CAP)
    (hc : c.node = requestVotesD n1) : LocalOk' ids g C G k c := by
  have hd := hi.dyn k
  have hsl := (hi.live k).1
  obtain ⟨r, dl, hn1⟩ := htm
  rw [hn1] at hc
  have hp1 : n1.peers = (C.node k).peers := by rw [hn1]; rfl
  have hv1 : n1.votes = (Rust.Slice.fill Vt false).set (C.node k).local.val true hlt := by rw [hn1]; rfl
  have hm1 : n1.membership = (C.node k).membership := by rw [hn1]; rfl
  have hcs : c.node.state = { (C.node k).state with hard := { (C.node k).state.hard with term := cc, voted_for := some ids[k] } } := by
    rw [hc, ← hd.id]; rfl
  have hcr : c.node.role = .Candidate := by rw [hc]; rfl
  have hct : c.node.state.hard.term = cc := by rw [hcs]
  have hfl : fullLog G c.node.state = fullLog G (C.node k).state := by rw [hcs]; rfl
  -- no unsaved election of `k`'s in the new term: its own vote would have won it
  have hnoph : ∀ eL, G.elect cc.val ≠ some (k, eL) := by
    intro eL he
    have hlt' : (C.disk k).hard.term.val < cc.val := by have := hi.terms k; omega
    have hq := el_phantom_quorum ids g C G hi k _ eL he hlt'
    obtain ⟨-, -, -, h4⟩ := hi.elect _ k eL he hlt'
    obtain ⟨hfl', -, -⟩ := h4 (by omega)
    apply hnQ
    have hm : (C.node k).membership = cfgOf g eL := by
      rw [hd.membership, memOf_fullLog g G _ (hi.live k).2, hfl']
    rw [hm1, hm]
    refine quorum_mono _ _ _ (fun id hid => ?_) hq
    subst hid
    rw [el_votedBy_slot n1 hd.pre.n_lt (by rw [hp1]; exact hd.pre.uniq) ⟨_, hlt⟩ ids[k]
      (by rw [hp1]; exact (hd.local_slot _ hlt).mpr rfl), hv1]
    simp
  have hdk := hi.terms k
  refine
    { dyn := ?_
      live := ⟨?_, ?_⟩
      consistent := ?_
      clean := fun h => by rw [hc] at h; cases h
      terms := by rw [hct]; omega
      acks := ?_
      ballots := ?_
      ballot_cand := ?_
      elect := ?_
      elect_cand := ?_
      lead := ?_
      leader := fun h => by rw [hcr] at h; cases h
      candidate := ?_
      outbox := ?_
      outbox_self := ?_
      extra := ?_
      votes := ?_
      committed := ?_ }
  · refine dynOk_frame hd (by rw [hc]; rfl) (by rw [hc]; rfl) (by rw [hc]; rfl) (by rw [hc]; rfl) (by rw [hc]; rfl)
      (by rw [hc]; rfl) (by rw [hcs]; rfl) (by rw [hcs]; exact hd.layout) (by rw [hcs]; exact hd.contig) ?_
    intro t h; rw [hc] at h; cases h
  · rw [hcs]
    exact ⟨hsl.layout, hsl.contig, hsl.base, hsl.snapshot, fun e he => by have := hsl.terms e he; show _ ≤ cc.val; omega,
      hsl.commit_ge, hsl.commit_le, fun h => by simp only at h; omega⟩
  · rw [hcs]; exact (hi.live k).2
  · left; rw [hfl]
    rcases hi.consistent_live k with h1 | ⟨hd1, -⟩ | ⟨hd1, -⟩
    · exact h1
    all_goals rw [hI.1] at hd1; cases hd1
  · intro t j hj j' hj'
    rw [hfl, hct]
    exact kept_mono_bound G k t j' _ _ _ (by omega) ((hi.acks k t j hj).2.2 j' hj').1
  · intro T c' v hb ht
    rw [hct] at ht
    rcases (hi.ballots T k c' v hb).1 with h | ⟨hkc, -, h⟩
    · omega
    · rw [← hkc] at h; exact absurd (by rw [ht]; exact h) (hnoph v)
  · intro _ T w v hb ht
    rw [hct] at ht
    by_cases hwk : w = k
    · subst hwk
      rcases (hi.ballots T w w v hb).1 with h | ⟨-, -, h⟩
      · omega
      · exact absurd (by rw [ht]; exact h) (hnoph v)
    · have := (hi.ballots T w k v hb).2.1 hwk; omega
  · intro T eL he hdT hT
    have := (hi.elect T k eL he hdT).2.2.1
    rw [hct] at hT; omega
  · rintro T eL he ⟨-, hT⟩
    rw [hct] at hT
    exact hnoph eL (by rw [hT]; exact he)
  · rintro ⟨eL, he⟩
    rw [hct] at he
    exact (hnoph eL he).elim
  · intro _
    unfold CandidateOk'
    rw [hfl, hct]
    refine ⟨by rw [hcs], fun e he => by have := hsl.terms e he; omega, fun i hi' => Or.inl ?_⟩
    have hv : c.node.votes = (Rust.Slice.fill Vt false).set (C.node k).local.val true hlt := by rw [hc]; rfl
    have hl : c.node.local = (C.node k).local := by rw [hc]; rfl
    rw [hv] at hi'
    simp only [Rust.Slice.fill, Fin.getElem_fin, Vector.getElem_set, Vector.getElem_replicate] at hi'
    rw [hl]
    split at hi'
    · rename_i h; exact h.symm
    · cases hi'
  · intro i o h
    rw [hc] at h
    rcases el_rv_outbox _ i o h with ⟨rfl, -, id, hp⟩ | h
    · exact ⟨id, by rw [hc]; exact hp, by simp only [OutOk, setLive_self']; exact hcr⟩
    · have h' : (C.node k).outbox[i] = some o := h
      rw [hI.2.2 i] at h'; cases h'
  · have key : ∀ m : DNode V S MAX CAP, m = requestVotesD n1 → ∀ h : m.local.val < MAX, m.outbox[m.local.val] = none := by
      intro m hm h; subst hm
      rw [el_rv_self n1 h]
      have e1 : n1.outbox = (C.node k).outbox := by rw [hn1]; try rfl
      have e2 : n1.local = (C.node k).local := by rw [hn1]; try rfl
      simp only [e1, e2]; exact hI.2.2 ⟨_, hlt⟩
    intro h o ho
    rw [key c.node (by rw [hc, hn1]) h] at ho; cases ho
  · intro to o h
    have : c.node.extra_reply = (C.node k).extra_reply := by rw [hc]; rfl
    rw [this, hI.2.1] at h; cases h
  · rintro env henv T last hf hmsg ⟨-, hT⟩
    have hs' := (hi.sent env henv).2
    simp only [hmsg] at hs'
    have := (hs' k hf).1
    rw [hct] at hT; subst hT; omega
  · left
    rw [hfl, hct]
    have hcm : c.node.state.hard.commit = (C.node k).state.hard.commit := by rw [hcs]
    rw [hcm]
    rcases (hi.committed k).2 with h1 | ⟨hd1, -⟩ | ⟨-, ⟨hd1, -⟩, -⟩
    · exact committedBy_mono_term G _ _ (by omega) _ h1
    all_goals rw [hI.1] at hd1; cases hd1

private theorem el_case_vote (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (hi : Inv ids g C G) (k : Fin K)
    (env : DEnv V S MAX) (henv : env ∈ C.sent) (hsrc : env.from ≠ ids[k]) (hto : env.to = ids[k]) (a : Option (Fin MAX))
    (ha : ∀ i, a = some i → (C.node k).peers[i] = some env.from)
    (t : Rust.u64) (last : LogId) (hmsg : env.message = .Vote t last) (ht0 : 0 < t.val)
    (n1 n2 : DNode V S MAX CAP) (gr : Bool) (c : Jarl.Cluster V S MAX CAP)
    (hI : Idle (C.node k)) (hO : ObservedD (C.node k) env.from t n1) (hT : n1.state.hard.term = t)
    (hg : gr = decide ((n1.state.hard.voted_for = none ∨ n1.state.hard.voted_for = some env.from) ∧
        upToDate last (lastId n1.state)))
    (h1 : gr = false → n2 = n1)
    (h2 : gr = true → Timers { n1 with state := { n1.state with hard := { n1.state.hard with voted_for := some env.from } }, dirty := (n1.dirty || decide (n1.state.hard.voted_for ≠ some env.from)) } n2)
    (hcn : c.node = queueD n2 a env.from (.Voted gr)) :
    ∃ G', Extends G G' ∧ Inv ids g (C.setLive k c) G' := by
  have hd := hi.dyn k
  have hsl := (hi.live k).1
  obtain ⟨hc1, hl1, hv1, hm1, hob1, hx1, hp1, hmem1, hhk1, hb1, hA⟩ := el_observed _ _ _ _ hO
  -- `n2` relative to `n1`
  have hn2 : n2.config = n1.config ∧ n2.local = n1.local ∧ n2.votes = n1.votes ∧ n2.matched = n1.matched ∧
      n2.outbox = n1.outbox ∧ n2.extra_reply = n1.extra_reply ∧ n2.peers = n1.peers ∧
      n2.membership = n1.membership ∧ n2.hooks = n1.hooks ∧ n2.bootstrap = n1.bootstrap ∧ n2.role = n1.role ∧
      n2.prevoting = n1.prevoting ∧
      n2.state = { n1.state with hard := { n1.state.hard with voted_for := if gr then some env.from else n1.state.hard.voted_for } } ∧
      n2.dirty = (n1.dirty || (gr && decide (n1.state.hard.voted_for ≠ some env.from))) := by
    cases gr
    · obtain rfl := h1 rfl
      refine ⟨rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, ?_, by simp⟩
      simp only [Bool.false_eq_true, if_false]
      try rw [el_hard_vf _ _ rfl, el_state_hard_eta]
    · obtain ⟨r, d, rfl⟩ := h2 rfl
      exact ⟨rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, by simp⟩
  obtain ⟨hc2, hl2, hv2, hm2, hob2, hx2, hp2, hmem2, hhk2, hb2, hr2, hpv2, hst2, hd2⟩ := hn2
  obtain ⟨f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12⟩ := el_qf n2 a env.from (.Voted gr)
  rw [← hcn] at f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12
  have hlast1 : lastId n1.state = lastId (C.node k).state := by
    rcases hA with ⟨-, rfl⟩ | ⟨-, h, -⟩
    · rfl
    · rw [h]; rfl
  have hfl : fullLog G c.node.state = fullLog G (C.node k).state := by
    rw [f1, hst2]
    rcases hA with ⟨-, rfl⟩ | ⟨-, h, -⟩
    · rfl
    · rw [h]; rfl
  have hct : c.node.state.hard.term = t := by rw [f1, hst2]; exact hT
  have hcvf : c.node.state.hard.voted_for = if gr then some env.from else n1.state.hard.voted_for := by
    rw [f1, hst2]
  have hOut : OutOk ids g (C.setLive k c) G k env.from (.Voted gr) := by
    simp only [OutOk, setLive_self', setLive_sent]
    intro hgr
    subst hgr
    have hg' := hg.symm
    simp only [decide_eq_true_eq] at hg'
    refine ⟨by rw [hcvf]; rfl, last, ?_, ?_⟩
    · rw [hct, ← hto, ← hmsg]; exact henv
    · rw [hfl, lastOf_fullLog G _ hsl, ← hlast1]; exact hg'.2
  obtain ⟨hob, hos, hex⟩ := el_reply ids g C G hi k c env.from hsrc a ha (.Voted gr) n2 (hp2.trans hp1)
    (hl2.trans hl1) (fun j => by rw [hob2, hob1]; exact hI.2.2 j) (by rw [hx2, hx1]; exact hI.2.1) hcn hOut
  refine ⟨G, Extends.refl G, setLive_inv' ids g C G hi k c ?_⟩
  rcases hA with ⟨-, rfl⟩ | ⟨hup, hst1, hr1, hd1, hpv1⟩
  · -- the same term
    have htn : (C.node k).state.hard.term = t := hT
    have hs : c.node.state = { (C.node k).state with hard := { (C.node k).state.hard with
        voted_for := if gr then some env.from else (C.node k).state.hard.voted_for } } := by rw [f1, hst2]
    have hvfn : gr = true → (C.node k).state.hard.voted_for = none ∨ (C.node k).state.hard.voted_for = some env.from := by
      intro hgr; have hg' := hg.symm; rw [hgr] at hg'; simp only [decide_eq_true_eq] at hg'; exact hg'.1
    have hrole : c.node.role = (C.node k).role := f2.trans hr2
    refine el_light ids g C G hi k hI c _ hs ?_ (by simp only; exact Nat.le_refl _) rfl
      (fun h => by simp only at h; rw [htn] at h; omega) ?_ (fun _ => ⟨hrole, by simp only⟩) ?_ ?_ ?_ ?_ ?_ hob hos hex
    · refine dynOk_frame hd (f5.trans hc2) (f6.trans hhk2) (f7.trans hb2) (f8.trans hp2) (f9.trans hl2)
        (f10.trans hmem2) (by rw [hs]; rfl) (by rw [hs]; exact hd.layout) (by rw [hs]; exact hd.contig) ?_
      intro t' h
      rw [f4, hpv2] at h
      obtain ⟨a1, a2⟩ := hd.prevoting t' h
      exact ⟨by rw [hrole]; exact a1, by rw [hs]; exact a2⟩
    · intro hdc
      rw [f3, hd2] at hdc
      cases gr
      · simp only [Bool.false_eq_true, if_false]; try exact el_hard_vf _ _ rfl
      · simp only [Bool.or_eq_false_iff, Bool.true_and, decide_eq_false_iff_not, Classical.not_not] at hdc
        simp only [if_true]; exact el_hard_vf _ _ hdc.2
    · intro T c' v hb hT'
      have hold := (hi.ballots T k c' v hb).2.2.2 (by rw [← hT', hct, htn])
      rw [hcvf]
      cases gr
      · exact hold
      · simp only [if_true]
        rcases hvfn rfl with h | h
        · rw [h] at hold; cases hold
        · rw [h] at hold; exact hold
    · intro T eL he; rw [hrole, hct, ← htn]; exact hi.elect_cand T k eL he
    · intro hL
      have hL' : Leading G k (C.node k) := by obtain ⟨eL, he⟩ := hL; exact ⟨eL, by rw [htn, ← hct]; exact he⟩
      exact el_leadLog_congr ids g G k _ _ (by rw [hct, htn]) hfl (fun _ => hI.1) (hi.lead k hL')
    · intro hr
      obtain ⟨hL, hok⟩ := hi.leader k (hrole ▸ hr)
      replace hL := hL.resolve_right (fun hp => by have := hp.1; rw [hI.1] at this; cases this)
      refine ⟨by obtain ⟨eL, he⟩ := hL; exact ⟨eL, by rw [hct, ← htn]; exact he⟩, ?_⟩
      exact el_leaderOk_congr ids G k _ _ (by rw [hct, htn]) hfl (f12.trans hm2) (f8.trans hp2) (f9.trans hl2) hok
    · intro hr
      have hc := hi.candidate k (hrole ▸ hr)
      refine el_cand_congr ids G k _ _ (by rw [hct, htn]) hfl (f11.trans hv2) (f8.trans hp2) (f9.trans hl2) ?_ hc
      rw [hcvf]
      cases gr
      · rfl
      · exfalso
        have h1 := hc.1
        rcases hvfn rfl with h | h
        · rw [h] at h1; cases h1
        · rw [h] at h1; exact hsrc (Option.some.inj h1)
  · -- a higher term
    refine el_up ids g C G hi k hI c t (if gr then some env.from else none) (hT ▸ hup) ?_ (f2.trans (hr2.trans hr1))
      (by rw [f3, hd2, hd1]; rfl) (by rw [f4, hpv2, hpv1]) (f5.trans (hc2.trans hc1)) (f6.trans (hhk2.trans hhk1))
      (f7.trans (hb2.trans hb1)) (f8.trans (hp2.trans hp1)) (f9.trans (hl2.trans hl1)) (f10.trans (hmem2.trans hmem1))
      hob hos hex
    rw [f1, hst2, hst1]
    try (cases gr <;> rfl)

/-- A log at least as up to date as a ballot log that keeps a committed prefix keeps it too. -/
private theorem el_vlog_keep (ids : Vector Id K) (g : Membership MAX) (hid : ∀ a b : Fin K, ids[a] = ids[b] → a = b)
    (G : Ghost (Record V MAX) K) (hw : Wf ids g G) (eK : List (DEntry V MAX)) (hcons : Consistent G eK)
    (vlog : List (DEntry V MAX)) (hvlog : Consistent G vlog) (hup : upToDate (lastOf eK) (lastOf vlog))
    (t j : Nat) (hc : CommitQ ids g G t j) (hp : G.prefix t j <+: vlog) : G.prefix t j <+: eK := by
  obtain ⟨L, hL, hjL, hj0, hjL', hterm⟩ := commitQ_leader G t j hc
  have hPeq := prefix_eq_take G t j L hL
  have hmem : L[j - 1] ∈ vlog := hp.subset (by
    rw [hPeq]; exact List.mem_iff_getElem.mpr ⟨j - 1, by simp; omega, by simp⟩)
  have hvt : t ≤ (lastOf vlog).term.val := by
    have := (consistent_terms' G hw vlog hvlog _ hmem).2; rwa [hterm] at this
  have hpos : 0 < t := by
    have := ((hw.leader t L hL).2.1 L[j - 1] (List.getElem_mem _)).1; rwa [hterm] at this
  have hτ : t ≤ (lastOf eK).term.val := by rcases hup with h | ⟨h, -⟩ <;> omega
  have heKne : eK ≠ [] := by
    intro e; rw [e] at hτ; simp [lastOf, LogId.default] at hτ; omega
  by_cases hgt : t < (lastOf eK).term.val
  · obtain ⟨Lτ, hLτ, hpτ⟩ := consistent_prefix_last G eK hcons heKne
    obtain ⟨-, -, ⟨c3, eL3, he3, heL3, -⟩, -⟩ := hw.leader _ Lτ hLτ
    exact (leader_complete hid G hw _ c3 eL3 he3 t j hgt hc).trans
      (elect_prefix_of_last G hw eK hcons heKne Lτ hLτ hpτ c3 eL3 he3 heL3)
  · have heq : (lastOf eK).term.val = t := by omega
    have hveq : (lastOf vlog).term.val = t := by rcases hup with h | ⟨h, -⟩ <;> omega
    have hvne : vlog ≠ [] := List.ne_nil_of_mem hmem
    obtain ⟨Lv, hLv, hvp⟩ := consistent_prefix_last G vlog hvlog hvne
    obtain ⟨Le, hLe, hep⟩ := consistent_prefix_last G eK hcons heKne
    rw [hveq, hL] at hLv; cases hLv
    rw [heq, hL] at hLe; cases hLe
    have h1 := consistent_length G vlog hvlog hvne
    have h2 := consistent_length G eK hcons heKne
    have hidx : (lastOf vlog).index.val ≤ (lastOf eK).index.val := by rcases hup with h | ⟨-, h⟩ <;> omega
    exact hp.trans (List.prefix_of_prefix_length_le hvp hep (by omega))

/-- A ballot log keeps every committed prefix its voter acknowledged. -/
private theorem el_ballot_keep (ids : Vector Id K) (g : Membership MAX) (hid : ∀ a b : Fin K, ids[a] = ids[b] → a = b)
    (G : Ghost (Record V MAX) K) (hw : Wf ids g G) (T : Nat) (w c : Fin K) (vlog : List (DEntry V MAX))
    (hb : (T, w, c, vlog) ∈ G.ballots) (t j' j : Nat) (ha : (w, t, j') ∈ G.acks) (ht : t < T) (hj : j ≤ j')
    (hc : CommitQ ids g G t j) : G.prefix t j <+: vlog := by
  rcases (hw.ballot T w c vlog hb).2 t j' ha ht j hj with (h | ⟨t'', h1, -, c'', eL'', he'', -, hn⟩) | ⟨c', eL', he', -, hn⟩
  · exact h
  · exact absurd (leader_complete hid G hw t'' c'' eL'' he'' t j h1 hc) hn
  · exact absurd (leader_complete hid G hw T c' eL' he' t j ht hc) hn

omit [Rust.Clone V] [Rust.Clone S] in
private theorem el_setLive_twice (C : World V S MAX CAP K) (k : Fin K) (c0 c : Jarl.Cluster V S MAX CAP) :
    (C.setLive k c0).setLive k c = C.setLive k c := by
  simp only [World.setLive]
  congr 1
  funext j
  split <;> rfl

include hid in
/-- A candidate wins on counting a vote. -/
private theorem el_win_voted (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (hi : Inv ids g C G) (k : Fin K)
    (hI : Idle (C.node k)) (x : Option Id) (i : Fin MAX) (w : Fin K) (hpi : (C.node k).peers[i] = some ids[w])
    (hcand : (C.node k).role = .Candidate) (vlog : List (DEntry V MAX))
    (hb : ((C.node k).state.hard.term.val, w, k, vlog) ∈ G.ballots)
    (hup : upToDate (lastOf (fullLog G (C.node k).state)) (lastOf vlog)) (c : Jarl.Cluster V S MAX CAP)
    (hQ : Quorum (C.node k).membership (fun id => votedBy { C.node k with request_from := x, votes := (C.node k).votes.set i.val true i.isLt } id = true))
    (hB : BecomeLeaderD { C.node k with request_from := x, votes := (C.node k).votes.set i.val true i.isLt } c.node) :
    ∃ G', Extends G G' ∧ Inv ids g (C.setLive k c) G' := by
  have hdk := hi.dyn k
  have hs0 := (hi.live k).1
  have hcl := hi.clean k hI.1
  have hc0 := hi.candidate k hcand
  have hpvn : (C.node k).prevoting = none := by
    cases h : (C.node k).prevoting with
    | none => rfl
    | some t => have := (hdk.prevoting t h).1; rw [hcand] at this; cases this
  have hcons : Consistent G (fullLog G (C.node k).state) := by
    rcases hi.consistent_live k with h | ⟨h, -⟩ | ⟨h, -⟩
    · exact h
    all_goals rw [hI.1] at h; cases h
  -- the votes counted: `k` itself or ballots for `k`
  have hP : ∀ id, votedBy { C.node k with request_from := x, votes := (C.node k).votes.set i.val true i.isLt } id = true →
      id = ids[k] ∨ ∃ w' : Fin K, ids[w'] = id ∧ ∃ vlog', ((C.node k).state.hard.term.val, w', k, vlog') ∈ G.ballots ∧
        upToDate (lastOf (fullLog G (C.node k).state)) (lastOf vlog') := by
    intro id hv
    obtain ⟨j, hpj, hvj⟩ := el_votedBy_true _ hdk.pre.n_lt id hv
    have hpj' : (C.node k).peers[j] = some id := hpj
    have hvj' : ((C.node k).votes.set i.val true i.isLt)[j] = true := hvj
    simp only [Fin.getElem_fin, Vector.getElem_set] at hvj'
    split at hvj'
    · rename_i hji
      have : j = i := Fin.ext hji.symm
      subst this
      rw [hpi] at hpj'; cases hpj'
      exact Or.inr ⟨w, rfl, vlog, hb, hup⟩
    · rcases hc0.2.2 j (by simpa using hvj') with h | ⟨w', hw', vlog', hb', hu'⟩
      · left
        have := (hdk.local_slot j.val j.isLt).mpr h
        have hpj'' : (C.node k).peers[j.val] = some id := hpj'
        rw [hpj''] at this; exact Option.some.inj this
      · right; rw [hpj'] at hw'; exact ⟨w', (Option.some.inj hw').symm, vlog', hb', hu'⟩
  have hmem : (C.node k).membership = cfgOf g (fullLog G (C.node k).state) := by
    rw [hdk.membership, memOf_fullLog g G _ (hi.live k).2]
  -- nobody else won the term
  have hel : G.elect (C.node k).state.hard.term.val = none := by
    cases he : G.elect (C.node k).state.hard.term.val with
    | none => rfl
    | some y =>
      obtain ⟨c', eL'⟩ := y
      exfalso
      by_cases hck : c' = k
      · subst hck; exact hi.elect_cand _ _ eL' he ⟨hcand, rfl⟩
      obtain ⟨id, hPid, w2, hw2, v2, hb2, -⟩ := el_inter ids g hid G hi.wf _ c' eL' he _ hcons hc0.2.1 _
        (by rw [← hmem]; exact hQ) (by
          intro id hv
          rcases hP id hv with rfl | ⟨w', hw', vlog', hb', hu'⟩
          · refine ⟨k, rfl, fun t j' j ha ht hj hc => ?_⟩
            rcases ((hi.acks k t j' ha).2.2 j hj).1 with h | ⟨t'', h1, -, c'', eL'', he'', -, hn⟩
            · exact h
            · exact absurd (leader_complete hid G hi.wf t'' c'' eL'' he'' t j h1 hc) hn
          · refine ⟨w', hw', fun t j' j ha ht hj hc => ?_⟩
            exact el_vlog_keep ids g hid G hi.wf _ hcons vlog' (hi.wf.ballot _ _ _ _ hb').1 hu' t j hc
              (el_ballot_keep ids g hid G hi.wf _ w' k vlog' hb' t j' j ha ht hj hc))
      rcases hv : votedBy { C.node k with request_from := x, votes := (C.node k).votes.set i.val true i.isLt } id with _ | _
      · rw [hv] at hPid; cases hPid
      rcases hP id hv with rfl | ⟨w', hw', vlog', hb', -⟩
      · obtain rfl := hid _ _ hw2
        have := (hi.ballots _ _ _ _ hb2).2.2.2 rfl
        rw [hc0.1] at this; exact hck (hid _ _ (Option.some.inj this)).symm
      · obtain rfl := hid _ _ (hw2.trans hw'.symm)
        exact hck (hi.ballot_unique _ _ _ _ _ _ hb2 hb')
  -- an intermediate world where `k` is a follower of its term
  have hlq : LocalOk' ids g C G k ⟨{ C.node k with role := .Follower }⟩ := by
    refine el_light ids g C G hi k hI _ (C.node k).state.hard (by exact (el_state_hard_eta _).symm)
      (dynOk_frame hdk rfl rfl rfl rfl rfl rfl rfl hdk.layout hdk.contig (by intro t h; rw [hpvn] at h; cases h))
      (Nat.le_refl _) rfl hs0.unvoted (fun _ => rfl) (fun h => by rcases h with h | h <;> cases h)
      (fun T c' v hb' ht => (hi.ballots T k c' v hb').2.2.2 ht) (fun T eL _ ⟨h, _⟩ => by cases h) ?_
      (fun h => by cases h) (fun h => by cases h) (fun j o h => ?_) (fun hl => hI.2.2 ⟨_, hl⟩)
      (fun to o h => by have : (C.node k).extra_reply = some (to, o) := h; rw [hI.2.1] at this; cases this)
    · rintro ⟨eL, he⟩
      exact absurd ⟨hcand, rfl⟩ (hi.elect_cand _ _ eL he)
    · have : (C.node k).outbox[j] = some o := h; rw [hI.2.2 j] at this; cases this
  have hi0 := setLive_inv' ids g C G hi k _ hlq
  have hnode : (C.setLive k ⟨{ C.node k with role := .Follower }⟩).node k = { C.node k with role := .Follower } :=
    setLive_self' _ _ _
  obtain ⟨G', hext, hi', helG, hleG⟩ := el_elect_in ids g hid (C.setLive k ⟨{ C.node k with role := .Follower }⟩) G hi0 k
    (by rw [hnode]; exact hI) (by rw [hnode]) (by rw [hnode]; exact hc0.1) (by rw [hnode]; exact hc0.2.1)
    (by rw [hnode]; exact hel) (by rw [hnode, ← hmem]; exact quorum_mono _ _ _ hP hQ) (by
      rw [hnode]
      intro env henv last hf hm
      have := (hi.sent env henv).2
      simp only [hm] at this
      exact (this k hf).2.1 ⟨hcand, rfl⟩)
  rw [hnode] at helG hleG
  obtain ⟨n3, hB, hcn⟩ := hB
  have hc : c = ⟨bcastD n3⟩ := by cases c; simp only at hcn; rw [hcn]
  subst hc
  rw [← el_setLive_twice C k ⟨{ C.node k with role := .Follower }⟩]
  have hfle : fullLog G' (C.node k).state = fullLog G (C.node k).state := fullLog_extends hext _ hs0
  refine ⟨G', hext, setLive_inv' ids g _ G' hi' k _ ?_⟩
  have hdisk : (C.setLive k ⟨{ C.node k with role := .Follower }⟩).disk = C.disk := rfl
  refine elt_lead ids g _ G' k (leaderInitD { C.node k with request_from := x, votes := (C.node k).votes.set i.val true i.isLt }) n3 ?_ rfl (stateOk_extends hext _ hs0) (elt_snapOk_ext g hext _ hs0 (hi.live k).2)
    ?_ ?_ ?_ ?_ ?_ ?_ ?_ ?_ (fun j => hI.2.2 j) hI.2.1 ?_ hB
  · exact dynOk_frame hdk rfl rfl rfl rfl rfl rfl rfl hdk.layout hdk.contig (by
      intro t h; have h' : (C.node k).prevoting = some t := h; rw [hpvn] at h'; cases h')
  · rw [hdisk]; exact hi.terms k
  · left; show Consistent G' (fullLog G' (C.node k).state); rw [hfle]; exact consistent_extends hext _ hcons
  · intro _; rw [hdisk]; exact hcl
  · intro t j h j' hj'
    have := ((hi'.acks k t j h).2.2 j' hj').1
    rw [hnode] at this; exact this
  · intro T eL he hd hlt
    rw [hdisk] at hd
    have := (hi'.elect T k eL he (by rw [hdisk]; exact hd)).2.2.1
    rw [hdisk] at this
    have htd : (C.disk k).hard.term = (C.node k).state.hard.term := by rw [hcl]
    have hlt' : (C.node k).state.hard.term.val < T := hlt
    have h2 := congrArg Fin.val htd
    exact el_no_phantom ids g _ G' hi' k T (by rw [hnode]; exact hlt') eL he
  · intro T c' v hb' ht
    have := (hi'.ballots T k c' v hb').2.2.2 (by rw [hnode]; exact ht)
    rw [hnode] at this; exact this
  · have hL : Leading G' k (C.node k) := ⟨_, helG⟩
    have h := hi'.lead k (by rw [hnode]; exact hL)
    rw [hnode] at h
    exact Or.inl ⟨h.elected, h.log, h.chain, h.cfgs⟩
  · constructor
    · intro j hjl h0
      rw [elt_leaderInit_matched] at h0
      split at h0
      · rename_i hh; exact absurd hh hjl
      · omega
    · intro h
      rw [elt_leaderInit_own]; show _ ≤ (fullLog G' (C.node k).state).length
      rw [hfle, fullLog_length G _ hs0]; exact Nat.le_refl _
  · rcases (hi.committed k).2 with h1 | ⟨hd, -⟩ | ⟨-, ⟨hd, -⟩, -⟩
    · show CommittedBy ids g G' (C.node k).state.hard.term.val ((fullLog G' (C.node k).state).take _)
      rw [hfle]; exact committedBy_mono hext _ _ h1
    all_goals rw [hI.1] at hd; cases hd

include hid in
/-- A node wins the campaign it starts at once, by its own vote. -/
private theorem el_win_campaign (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (hi : Inv ids g C G) (k : Fin K)
    (hI : Idle (C.node k)) (x : Option Id) (Vt : Vector Bool MAX) (cc : Rust.u64)
    (hcc : cc.val = (C.node k).state.hard.term.val + 1) (hfol : (C.node k).role = .Follower)
    (hlt : (C.node k).local.val < MAX) (n1 : DNode V S MAX CAP)
    (htm : Timers (candidateD { C.node k with request_from := x, votes := Vt } cc hlt) n1)
    (hQ : Quorum n1.membership (fun id => votedBy n1 id = true)) (c : Jarl.Cluster V S MAX CAP)
    (hB : BecomeLeaderD n1 c.node) : ∃ G', Extends G G' ∧ Inv ids g (C.setLive k c) G' := by
  have hdk := hi.dyn k
  have hs0 := (hi.live k).1
  have hrl : (C.node k).role ≠ .Leader := by rw [hfol]; intro h; cases h
  obtain ⟨r1, d1, hn1⟩ := htm
  have hp1 : n1.peers = (C.node k).peers := by rw [hn1]; try rfl
  have hl1 : n1.local = (C.node k).local := by rw [hn1]; try rfl
  have hm1 : n1.membership = (C.node k).membership := by rw [hn1]; try rfl
  have hv1 : n1.votes = (Rust.Slice.fill Vt false).set (C.node k).local.val true hlt := by rw [hn1]; try rfl
  have hq0 : Quorum (cfgOf g (fullLog G (C.node k).state)) (fun id => id = ids[k]) := by
    rw [← memOf_fullLog g G _ (hi.live k).2, ← hdk.membership, ← hm1]
    refine quorum_mono _ _ _ ?_ hQ
    intro id hv
    refine elt_voted_self n1 hdk.pre.n_lt ids[k] (by rw [hp1, hl1]; exact hdk.local_slot) ?_ id hv
    intro i hvi
    rw [hl1]
    have : ((Rust.Slice.fill Vt false).set (C.node k).local.val true hlt)[i] = true := by rw [← hv1]; exact hvi
    simp only [Rust.Slice.fill, Fin.getElem_fin, Vector.getElem_set, Vector.getElem_replicate] at this
    split at this
    · rename_i h; exact h.symm
    · cases this
  subst hn1
  obtain ⟨n3, hB, hcn⟩ := hB
  have hc : c = ⟨bcastD n3⟩ := by cases c; simp only at hcn; rw [hcn]
  subst hc
  have hcl := hi.clean k hI.1
  have hdt : (C.disk k).hard.term.val = (C.node k).state.hard.term.val := by rw [hcl]
  have hcons : Consistent G (fullLog G (C.node k).state) := by
    rcases hi.consistent_live k with h | ⟨h, -⟩ | ⟨h, -⟩
    · exact h
    all_goals rw [hI.1] at h; cases h
  have hsp : StateOk G { (C.node k).state with hard := { (C.node k).state.hard with term := cc, voted_for := some (C.node k).config.id } } :=
    elt_stateOk_term G _ hs0 _ (by omega) _
  have hflp : fullLog G ({ (C.node k).state with hard := { (C.node k).state.hard with term := cc, voted_for := some (C.node k).config.id } } : DState V S MAX CAP) = fullLog G (C.node k).state :=
    fullLog_congr G _ _ rfl rfl
  have hfd : fullLog G (C.disk k) = fullLog G (C.node k).state := by rw [hcl]
  -- nobody holds an election of the new term
  have hnone : G.elect cc.val = none := by
    cases he : G.elect cc.val with
    | none => rfl
    | some y =>
      exfalso
      obtain ⟨c', eL'⟩ := y
      have hed := hi.elect_disk _ _ _ he
      by_cases hck : c' = k
      · subst hck; omega
      obtain ⟨id, rfl, w, hw, vlog, hb, -⟩ := el_inter ids g hid G hi.wf cc.val c' eL' he
        (fullLog G (C.node k).state) hcons (fun e he' => by have := hs0.terms e he'; omega) _ hq0 (by
          intro id hid'
          refine ⟨k, hid'.symm, fun t j' jj ha ht hjj hc => ?_⟩
          rcases ((hi.acks k t j' ha).2.2 jj hjj).1 with h | ⟨t'', h1, h2, c'', eL'', he'', -, hn⟩
          · exact h
          · exact absurd (leader_complete hid G hi.wf t'' c'' eL'' he'' t jj h1 hc) hn)
      obtain rfl : w = k := hid w k hw
      rcases (hi.ballots _ _ _ _ hb).1 with h | ⟨h, -⟩
      · omega
      · exact hck h.symm
  have hPW : ∀ p : DNode V S MAX CAP, p.state = { (C.node k).state with hard := { (C.node k).state.hard with term := cc, voted_for := some (C.node k).config.id } } →
      p.dirty = true → p.role ≠ .Candidate → PendingWin ids g C G k p := by
    intro p hps hpd hpr
    have hfp : fullLog G p.state = fullLog G (C.node k).state := by rw [hps]; exact hflp
    refine ⟨hpd, hpr, by rw [hps]; exact hnone, by rw [hps]; show _ = cc.val; omega,
      by rw [hps]; show some (C.node k).config.id = _; rw [hdk.id], by rw [hfd]; exact hq0,
      by rw [hfp, hfd]; exact List.prefix_refl _, fun i h hle => by rw [hfp, hfd] at *; omega, ?_, ?_⟩
    · rw [hfp]; exact chain_of_consistent G hi.wf _ hcons
    · rw [hfp]
      intro i hi' X hX
      obtain ⟨-, L, hL, hp⟩ := hcons i hi'
      have hiL : i < L.length := by have := hp.length_le; simp at this; omega
      have hget : L[i] = (fullLog G (C.node k).state)[i] := by
        have := List.IsPrefix.getElem hp (show i < ((fullLog G (C.node k).state).take (i + 1)).length by simp; omega)
        simp at this; exact this.symm
      exact hi.cfgs _ L hL i hiL X (by rw [hget]; exact hX)
  refine ⟨G, Extends.refl G, setLive_inv' ids g C G hi k _ ?_⟩
  refine elt_lead ids g C G k _ n3 ?_ ?_ ?_ ?_ ?_ ?_ ?_ ?_ ?_ ?_ ?_ ?_ ?_ ?_ ?_ hB
  · exact dynOk_frame hdk rfl rfl rfl rfl rfl rfl rfl hdk.layout hdk.contig (by intro t h; cases h)
  · rfl
  · exact hsp
  · exact elt_snapOk_same g G _ _ rfl (hi.live k).2
  · show _ ≤ cc.val; have := hi.terms k; omega
  · exact Or.inr (Or.inr (hPW _ rfl rfl (by intro h; cases h)))
  · intro h; cases h
  · intro t j h j' hj'
    have := ((hi.acks k t j h).2.2 j' hj').1
    show Kept G k t j' (cc.val + 1) _
    erw [hflp]
    exact kept_mono_bound _ _ _ _ _ _ _ (by omega) this
  · intro T eL he hd _
    have := hi.elect_disk T k eL he; omega
  · intro T c vlog hb hT
    have hT' : cc.val = T := hT
    rcases (hi.ballots T k c vlog hb).1 with h1 | ⟨rfl, -⟩
    · omega
    · show some (C.node k).config.id = some ids[k]; rw [hdk.id]
  · exact Or.inr (hPW _ rfl rfl (by intro h; cases h))
  · constructor
    · intro i hil h0
      rw [elt_leaderInit_matched] at h0
      split at h0
      · rename_i hh; exact absurd hh hil
      · omega
    · intro h
      rw [elt_leaderInit_own]; erw [hflp]; rw [fullLog_length G _ hs0]; exact Nat.le_refl _
  · exact hI.2.2
  · exact hI.2.1
  · rcases (hi.committed k).2 with h1 | ⟨hd, -⟩ | ⟨-, ⟨hd, -⟩, -⟩
    · show CommittedBy ids g G cc.val _
      erw [hflp]
      exact committedBy_mono_term G _ _ (by omega) _ h1
    all_goals rw [hI.1] at hd; cases hd

include hid in
private theorem el_case_voted (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (hi : Inv ids g C G) (k : Fin K)
    (env : DEnv V S MAX) (henv : env ∈ C.sent) (hsrc : env.from ≠ ids[k]) (hto : env.to = ids[k]) (a : Option (Fin MAX))
    (ha : ∀ i, a = some i → (C.node k).peers[i] = some env.from)
    (t : Rust.u64) (gr : Bool) (hmsg : env.message = .Voted t gr)
    (n1 : DNode V S MAX CAP) (i : Fin MAX) (c : Jarl.Cluster V S MAX CAP)
    (hI : Idle (C.node k)) (hai : a = some i) (hO : ObservedD (C.node k) env.from t n1) (hT : n1.state.hard.term = t)
    (hrest : (¬ (n1.role = .Candidate ∧ gr = true) ∧ c.node = n1) ∨
        (n1.role = .Candidate ∧ gr = true ∧
          let nv : DNode V S MAX CAP := { n1 with votes := n1.votes.set i.val true i.isLt }
          ((¬ Quorum nv.membership (fun id => votedBy nv id = true) ∧ c.node = nv) ∨
            (Quorum nv.membership (fun id => votedBy nv id = true) ∧ BecomeLeaderD nv c.node)))) :
    ∃ G', Extends G G' ∧ Inv ids g (C.setLive k c) G' := by
  obtain ⟨hc1, hl1, hv1, hm1, hob1, hx1, hp1, hmem1, hhk1, hb1, hA⟩ := el_observed _ _ _ _ hO
  rcases hrest with ⟨-, hc⟩ | ⟨hcand1, hgr, hq⟩
  · exact el_obs_gen ids g C G hi k env.from hsrc a ha t n1 c hI hO (Or.inl hc)
  have hA' : n1 = { C.node k with request_from := some env.from } := by
    rcases hA with ⟨-, h⟩ | ⟨-, -, h, -⟩
    · exact h
    · rw [h] at hcand1; cases hcand1
  subst hA'
  have hcand : (C.node k).role = .Candidate := hcand1
  have htn : (C.node k).state.hard.term = t := hT
  obtain ⟨w, hw⟩ := (hi.sent env henv).1
  have hs' := (hi.sent env henv).2
  simp only [hmsg] at hs'
  obtain ⟨vlog, hb⟩ : ∃ vlog, (t.val, w, k, vlog) ∈ G.ballots := by
    rcases hs' hgr w k hw hto with h | ⟨eL, he⟩
    · exact h
    · exact absurd ⟨hcand, by rw [htn]⟩ (hi.elect_cand t.val k eL he)
  rw [← htn] at hb
  have hup := hi.ballot_cand _ _ _ _ hb hcand rfl
  have hpi : (C.node k).peers[i] = some ids[w] := by rw [← hw]; exact ha i hai
  rcases hq with ⟨-, hc⟩ | ⟨hQ, hB⟩
  · obtain ⟨hob, hos, hex⟩ := el_reply' ids g C G hi k c env.from hsrc none (fun _ h => by cases h) c.node
      (by rw [hc]) (by rw [hc]) (fun j => by rw [hc]; exact hI.2.2 j) (by rw [hc]; exact hI.2.1) (Or.inl rfl)
    refine ⟨G, Extends.refl G, setLive_inv' ids g C G hi k c (el_keepv ids g C G hi k hI c (some env.from)
      ((C.node k).votes.set i.val true i.isLt) (C.node k).outbox (C.node k).extra_reply (by rw [hc]) (fun _ => ?_)
      hob hos hex)⟩
    have hc0 := hi.candidate k hcand
    rw [hc]
    refine ⟨hc0.1, hc0.2.1, fun j hj => ?_⟩
    have hj' : ((C.node k).votes.set i.val true i.isLt)[j] = true := hj
    simp only [Fin.getElem_fin, Vector.getElem_set] at hj'
    split at hj'
    · rename_i hji
      have : j = i := Fin.ext hji.symm
      subst this
      exact Or.inr ⟨w, hpi, vlog, hb, hup⟩
    · exact hc0.2.2 j (by simpa using hj')
  · exact el_win_voted ids g hid C G hi k hI (some env.from) i w hpi hcand vlog hb hup c hQ hB

include hid in
private theorem el_case_prevoted (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (hi : Inv ids g C G) (k : Fin K)
    (env : DEnv V S MAX) (hsrc : env.from ≠ ids[k]) (a : Option (Fin MAX))
    (ha : ∀ i, a = some i → (C.node k).peers[i] = some env.from)
    (t cc : Rust.u64) (gr : Bool)
    (n1 : DNode V S MAX CAP) (i : Fin MAX) (c : Jarl.Cluster V S MAX CAP)
    (hI : Idle (C.node k)) (_hai : a = some i) (hO : ObservedD (C.node k) env.from t n1)
    (hrest : (¬ (n1.prevoting = some cc ∧ gr = true) ∧ c.node = n1) ∨
        (n1.prevoting = some cc ∧ gr = true ∧
          let nv : DNode V S MAX CAP := { n1 with votes := n1.votes.set i.val true i.isLt }
          ((¬ Quorum nv.membership (fun id => votedBy nv id = true) ∧ c.node = nv) ∨
            (Quorum nv.membership (fun id => votedBy nv id = true) ∧ CampaignD nv cc c.node)))) :
    ∃ G', Extends G G' ∧ Inv ids g (C.setLive k c) G' := by
  obtain ⟨hc1, hl1, hv1, hm1, hob1, hx1, hp1, hmem1, hhk1, hb1, hA⟩ := el_observed _ _ _ _ hO
  rcases hrest with ⟨-, hc⟩ | ⟨hpv1, hgr, hq⟩
  · exact el_obs_gen ids g C G hi k env.from hsrc a ha t n1 c hI hO (Or.inl hc)
  have hA' : n1 = { C.node k with request_from := some env.from } := by
    rcases hA with ⟨-, h⟩ | ⟨-, -, -, -, h⟩
    · exact h
    · rw [h] at hpv1; cases hpv1
  subst hA'
  obtain ⟨hfol, hcc⟩ := (hi.dyn k).prevoting cc hpv1
  rcases hq with ⟨-, hc⟩ | ⟨hQ, hCa⟩
  · obtain ⟨hob, hos, hex⟩ := el_reply' ids g C G hi k c env.from hsrc none (fun _ h => by cases h) c.node
      (by rw [hc]) (by rw [hc]) (fun j => by rw [hc]; exact hI.2.2 j) (by rw [hc]; exact hI.2.1) (Or.inl rfl)
    exact ⟨G, Extends.refl G, setLive_inv' ids g C G hi k c (el_keepv ids g C G hi k hI c (some env.from)
      ((C.node k).votes.set i.val true i.isLt) (C.node k).outbox (C.node k).extra_reply (by rw [hc])
      (fun h => by rw [hfol] at h; cases h) hob hos hex)⟩
  obtain ⟨hlt, n1', htm, ⟨hQ1, hBL⟩ | ⟨hnQ, hc⟩⟩ := hCa
  · exact el_win_campaign ids g hid C G hi k hI (some env.from) ((C.node k).votes.set i.val true i.isLt) cc hcc hfol
      hlt n1' htm hQ1 c hBL
  · exact ⟨G, Extends.refl G, setLive_inv' ids g C G hi k c (el_campaign_local ids g C G hi k hI (some env.from)
      ((C.node k).votes.set i.val true i.isLt) cc hcc hlt n1' htm hnQ c hc)⟩

include hid hg in
theorem preserve_deliver_elect [Rust.LawfulClone V] [Rust.LawfulClone S] (C : World V S MAX CAP K)
    (G : Ghost (Record V MAX) K) (hi : Inv ids g C G) (k : Fin K) (env : DEnv V S MAX) (henv : env ∈ C.sent)
    (hm : ElectMsg env.message) (r : Rust.Result Unit Error) (c : Jarl.Cluster V S MAX CAP)
    (h : Cluster.step (C.live k) env = pure (r, c)) : ∃ G', Extends G G' ∧ Inv ids g (C.setLive k c) G' := by
  have hstep := el_cluster_step (C.live k) env r c h
  have hd := hi.dyn k
  have hs0 := (hi.live k).1
  obtain ⟨a, ha, -, hS, hor⟩ := step_rel' (C.node k) hd.pre hs0.commit_ge hs0.commit_le env r c.node hstep
  have hsame : c.node = C.node k → ∃ G', Extends G G' ∧ Inv ids g (C.setLive k c) G' := by
    intro he
    have : c = C.live k := by cases c; simp only at he; rw [he]
    subst this; exact ⟨G, Extends.refl G, by rw [el_setLive_live]; exact hi⟩
  rcases hor with heq | ⟨hto, hfrom, hval⟩
  · exact hsame heq
  have hsrc : env.from ≠ ids[k] := by rw [← hd.id]; exact hfrom
  have hto' : env.to = ids[k] := by rw [← hd.id]; exact hto
  generalize hcn : c.node = m at hS
  generalize hmsg : env.message = msg at hS hm hval
  cases hS with
  | same => exact hsame hcn
  | ignored _ hI =>
    refine ⟨G, Extends.refl G, setLive_inv' ids g C G hi k c
      (el_keep ids g C G hi k hI c _ _ _ hcn (fun i o h => ?_) (fun hl => ?_) (fun to o h => ?_))⟩
    · rw [hcn] at h; have := hI.2.2 i; simp only [Fin.getElem_fin] at this h; rw [this] at h; cases h
    · have e : c.node.outbox = (C.node k).outbox := by rw [hcn]
      rw [e]; exact hI.2.2 ⟨_, hl⟩
    · rw [hcn] at h; rw [hI.2.1] at h; cases h
  | prevote t last gr hI =>
    obtain ⟨hob, hos, hex⟩ := el_reply ids g C G hi k c env.from hsrc a ha (.PreVoted t gr)
      { C.node k with request_from := some env.from } rfl rfl hI.2.2 hI.2.1 hcn (by unfold OutOk; trivial)
    refine ⟨G, Extends.refl G, setLive_inv' ids g C G hi k c ?_⟩
    cases a with
    | none => exact el_keep ids g C G hi k hI c _ (C.node k).outbox _ (by rw [hcn]; rfl) hob hos hex
    | some i => exact el_keep ids g C G hi k hI c _ _ (C.node k).extra_reply (by rw [hcn]; rfl) hob hos hex
  | prevoted t cc gr n1 m' i hI hai hO hrest =>
    subst hcn
    exact el_case_prevoted ids g hid C G hi k env hsrc a ha t cc gr n1 i c hI hai hO hrest
  | stale msg n1 m' hI hO hlt hn =>
    subst hcn
    exact el_case_stale ids g C G hi k env hsrc a ha msg n1 c hI hO hn
  | vote t last n1 n2 gr hI hO hT hg h1 h2 =>
    have ht0 : 0 < t.val := by
      apply Classical.byContradiction; intro h0
      have : t = 0 := Fin.ext (by simp; omega)
      subst this
      simp [Node.valid, Message.term] at hval
      have := Rust.pure_inj hval; cases this
    exact el_case_vote ids g C G hi k env henv hsrc hto' a ha t last hmsg ht0 n1 n2 gr c hI hO hT hg h1 h2 hcn
  | voted t gr n1 m' i hI hai hO hT hrest =>
    subst hcn
    exact el_case_voted ids g hid C G hi k env henv hsrc hto' a ha t gr hmsg n1 i c hI hai hO hT hrest
  | append => exact absurd hm id
  | appendBatch => exact absurd hm id
  | install => exact absurd hm id
  | replicated => exact absurd hm id

end Jarl.Engine.Dyn
