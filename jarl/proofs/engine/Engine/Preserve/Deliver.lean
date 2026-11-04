import Engine.Frame
import Engine.LogFacts

/-! # Preservation: Delivering a message -/

namespace Jarl.Engine
open Jarl

variable {V S : Type} {N CAP : Nat}

namespace Deliver


theorem valid_zero (m : Message V S) (hm : FixedMessage m) (h0 : m.term.val = 0) :
    Node.valid (N := N) (CAP := CAP) m = pure false := by
  have h0' : m.term = 0 := Fin.ext h0
  cases m <;> simp_all [Node.valid, Message.term, FixedMessage]

theorem step_same (ids : Vector Id N) (n : Node V S N CAP) (hf : Fixed ids n) (env : Envelope V S)
    (hm : FixedMessage env.message)
    (hc : env.from = n.config.id ∨ env.to ≠ n.config.id ∨ env.message.term.val = 0)
    (r : Rust.Result Unit Error) (n' : Node V S N CAP) (h : Node.step n env = pure (r, n')) : n' = n := by
  rcases env with ⟨src, dst, msg⟩
  simp only at hc hm
  unfold Node.step at h
  cases hA : Node.available n
  case Err e =>
    simp only [hA] at h
    exact (congrArg Prod.snd (pure_inj h)).symm
  rename_i u
  simp only [hA, pure_bind] at h
  cases hp : Rust.Iter.position n.peers.toList (fun id => id == some src)
  case none =>
    simp only [hp, Option.orElse, hf.hooks, Option.isSome_none, Bool.false_and, 
      Rust.Option.ok_or] at h
    exact (congrArg Prod.snd (pure_inj h)).symm
  rename_i p
  simp only [hp, Option.orElse, Rust.Option.ok_or] at h
  by_cases hc2 : (!(src == n.config.id || dst != n.config.id)) = true
  case neg =>
    rw [if_neg hc2] at h
    exact (congrArg Prod.snd (pure_inj h)).symm
  rw [if_pos hc2] at h
  have h0 : msg.term.val = 0 := by
    rcases hc with hc | hc | hc
    · simp [hc] at hc2
    · simp [hc] at hc2
    · exact hc
  rw [valid_zero msg hm h0, pure_bind] at h
  exact (congrArg Prod.snd (pure_inj h)).symm


theorem setLive_live (C : Cluster V S N CAP) (k : Fin N) : C.setLive k (C.live k) = C := by
  cases C with
  | mk live disk sent =>
    simp only [Cluster.setLive]
    congr 1
    funext j
    split
    · rename_i h; subst h; rfl
    · rfl

theorem ids_inj (ids : Vector Id N) (hnd : ids.toList.Nodup) (i j : Fin N) (h : ids[i] = ids[j]) : i = j := by
  have h' : ids.toList[i.val]'(by simp) = ids.toList[j.val]'(by simp) := by simpa using h
  exact Fin.ext ((List.getElem_inj hnd).mp h')

theorem id_slot (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (k : Fin N) : (C.live k).config.id = ids[k] := by
  have hf := (hi.fixed k).1
  rw [← hf.local_id]
  have := hi.slot k
  simp only [Fin.getElem_fin, this]

theorem majority_only (P : Fin N → Prop) (k : Fin N) (h : ∀ w, P w → w = k) (hm : Majority N P) :
    N / 2 < 1 := by
  unfold Majority at hm
  have : (List.finRange N).countP (fun w => @decide (P w) (Classical.propDecidable _)) ≤
      (List.finRange N).countP (fun w => decide (w.val = k.val)) := by
    apply List.countP_mono_left
    intro w _ hw; simp only [decide_eq_true_eq] at hw ⊢; rw [h w hw]
  rw [countP_single k.val k.isLt _ (fun j => rfl)] at this
  omega

theorem no_early_elect (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (a k : Fin N) (hak : a ≠ k) (T : Nat) (eL : List (Entry V))
    (he : G.elect T = some (k, eL)) : ¬ (C.disk k).hard.term.val < T := by
  intro hlt
  obtain ⟨-, -, -, hmaj⟩ := hi.wf.elect T k eL he
  have := majority_only _ k (fun w hw => by
    obtain ⟨vlog, hb, -⟩ := hw
    apply Classical.byContradiction; intro hw
    have := (hi.ballots T w k vlog hb).2.1 hw
    omega) hmaj
  exact hak (Fin.ext (by have := a.isLt; have := k.isLt; omega))

theorem ballot_up (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (a k : Fin N) (hak : a ≠ k) (T : Nat) (c : Fin N) (v : List (Entry V))
    (hb : (T, k, c, v) ∈ G.ballots) (hlt : (C.live k).state.hard.term.val < T) : False := by
  have ht := hi.terms k
  rcases (hi.ballots T k c v hb).1 with h | ⟨hkc, h2, he⟩
  · omega
  · rw [← hkc] at he
    exact no_early_elect ids cfg C G hi a k hak T v he (by omega)

theorem idle_consistent (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (k : Fin N) (hd : (C.live k).dirty = false) :
    Consistent G (fullLog G (C.live k).state) := by
  by_cases hr : (C.live k).role = .Leader
  · obtain ⟨L, hL, -, he⟩ := (hi.leader k hr).log
    rw [← he hd]; exact (hi.wf.leader _ L hL).1
  · exact hi.consistent_live k hr

/-- What observing a message's term changes. -/
theorem observed_facts (n0 n1 : Node V S N CAP) (src : Id) (t : Rust.u64) (h : Observed n0 src t n1) :
    n1.config = n0.config ∧ n1.local = n0.local ∧ n1.votes = n0.votes ∧ n1.matched = n0.matched ∧
    n1.outbox = n0.outbox ∧ n1.extra_reply = n0.extra_reply ∧
    ((t.val ≤ n0.state.hard.term.val ∧ n1.state = n0.state ∧ n1.role = n0.role ∧ n1.dirty = n0.dirty) ∨
     (n0.state.hard.term.val < t.val ∧
      n1.state = { n0.state with hard := { n0.state.hard with term := t, voted_for := none } } ∧
      n1.role = .Follower ∧ n1.dirty = true)) := by
  rcases h with ⟨ht, rfl⟩ | ⟨ht, r, d, rfl⟩
  · exact ⟨rfl, rfl, rfl, rfl, rfl, rfl, Or.inl ⟨ht, rfl, rfl, rfl⟩⟩
  · exact ⟨rfl, rfl, rfl, rfl, rfl, rfl, Or.inr ⟨ht, rfl, rfl, rfl⟩⟩

theorem fixed_observed (ids : Vector Id N) (n0 n1 : Node V S N CAP) (hf : Fixed ids n0) (src : Id) (t : Rust.u64)
    (h : Observed n0 src t n1) : Fixed ids n1 := by
  rcases h with ⟨ht, rfl⟩ | ⟨ht, r, d, rfl⟩
  · exact { hf with layout := hf.layout, contig := hf.contig }
  · exact { hf with layout := hf.layout, contig := hf.contig, prevoting := rfl }

theorem fixed_queue (ids : Vector Id N) (n : Node V S N CAP) (hf : Fixed ids n) (a : Fin N) (o : Outbound) :
    Fixed ids (queue n a o) := { hf with layout := hf.layout, contig := hf.contig }

theorem queue_outbox (n : Node V S N CAP) (hI : ∀ j : Fin N, n.outbox[j] = none) (a j : Fin N) (o o' : Outbound)
    (h : (queue n a o).outbox[j] = some o') : j = a ∧ o' = o := by
  simp only [queue, Fin.getElem_fin, Vector.getElem_set] at h
  split at h
  · rename_i hj; exact ⟨Fin.ext hj.symm, (Option.some.inj h).symm⟩
  · have := hI j; simp only [Fin.getElem_fin] at this; rw [this] at h; cases h


theorem state_hard_eta (s : State V S CAP) : ({ s with hard := s.hard } : State V S CAP) = s := by
  cases s; rfl

/-- `LocalOk` for a node whose log is node `k`'s, idle, with a new hard state. -/
theorem local_light (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (a k : Fin N) (hak : a ≠ k) (hd0 : (C.live k).dirty = false)
    (n : Node V S N CAP) (h : HardState) (hs : n.state = { (C.live k).state with hard := h })
    (hfix : Fixed ids n ∧ n.config = cfg k) (hslot : n.local.val = k.val)
    (hterm : (C.live k).state.hard.term.val ≤ h.term.val)
    (hc1 : (C.live k).state.hard.commit.val ≤ h.commit.val)
    (hc2 : h.commit.val ≤ (lastId (C.live k).state).index.val)
    (hunv : h.term.val = 0 → h.voted_for = none)
    (hclean : n.dirty = false → h = (C.live k).state.hard)
    (hballots : ∀ T c vlog, (T, k, c, vlog) ∈ G.ballots → n.state.hard.term.val = T →
      n.state.hard.voted_for = some ids[c])
    (helect_cand : ∀ T eL, G.elect T = some (k, eL) → ¬ (n.role = .Candidate ∧ n.state.hard.term.val = T))
    (hleader : n.role = .Leader → LeaderOk ids (C.setLive k n) G k)
    (hcand : n.role = .Candidate → CandidateOk ids (C.setLive k n) G k)
    (houtbox : ∀ j o, n.outbox[j] = some o → OutOk ids (C.setLive k n) G k j o)
    (hoself : n.outbox[k] = none)
    (hvotes : ∀ env ∈ C.sent, ∀ T last, env.from = ids[k] → env.message = .Vote T last →
      n.role = .Candidate ∧ n.state.hard.term = T → lastId n.state = last)
    (hcommitted : CommitOk G k n)
    (hbc : n.role = .Candidate → (C.live k).role = .Candidate ∧
      n.state.hard.term = (C.live k).state.hard.term) : LocalOk ids cfg C G k n := by
  have h0 := hi.live k
  refine ⟨hfix, hslot, ?_, ?_, ?_, ?_, ?_, ?_, hballots, ?_, helect_cand, hleader, hcand, houtbox, hoself, hvotes,
    hcommitted⟩
  · rw [hs]
    exact ⟨h0.layout, h0.contig, h0.base, h0.snapshot, fun e he => Nat.le_trans (h0.terms e he) hterm,
      Nat.le_trans h0.commit_ge hc1, hc2, hunv⟩
  · intro hd
    rw [hs, hclean hd, state_hard_eta (C.live k).state]
    exact hi.clean k hd0
  · rw [hs]; exact Nat.le_trans (hi.terms k) hterm
  · intro _; rw [hs]; exact idle_consistent ids cfg C G hi k hd0
  · intro t j hj j' hj'
    rw [hs]
    exact kept_mono_bound G k t j' _ _ _ (by simp only; omega) (((hi.acks k t j hj).2.2 j' hj').1)
  · intro T eL he hlt _
    exact absurd hlt (no_early_elect ids cfg C G hi a k hak T eL he)
  · intro hr T w v hb ht
    obtain ⟨h1, h2⟩ := hbc hr
    have := hi.ballot_cand T w k v hb h1 (by rw [← ht, h2])
    rw [hs]; exact this

theorem commit_same (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (k : Fin N) (hd0 : (C.live k).dirty = false)
    (n : Node V S N CAP) (h : HardState) (hs : n.state = { (C.live k).state with hard := h })
    (hc : h.commit = (C.live k).state.hard.commit) : CommitOk G k n := by
  rcases (hi.committed k).2 with h1 | ⟨-, h2, -⟩
  · left; rw [hs]; simp only [hc]; exact h1
  · rw [hd0] at h2; cases h2

theorem leader_transfer (ids : Vector Id N) (C : Cluster V S N CAP) (G : Ghost V N) (k : Fin N)
    (hL : LeaderOk ids C G k) (hd0 : (C.live k).dirty = false) (n : Node V S N CAP)
    (hf : fullLog G n.state = fullLog G (C.live k).state) (ht : n.state.hard.term = (C.live k).state.hard.term)
    (hm : n.matched = (C.live k).matched) : LeaderOk ids (C.setLive k n) G k := by
  obtain ⟨⟨eL, he, hp, hb⟩, ⟨L, hL1, hL2, hL3⟩, hmt, hown⟩ := hL
  refine ⟨⟨eL, ?_, ?_, ?_⟩, ⟨L, ?_, ?_, ?_⟩, ?_, ?_⟩ <;> simp only [setLive_self, hf, ht, hm]
  · exact he
  · exact hp
  · exact hb
  · exact hL1
  · exact hL2
  · intro _; exact hL3 hd0
  · exact hmt
  · exact hown

theorem cand_transfer (ids : Vector Id N) (C : Cluster V S N CAP) (G : Ghost V N) (k : Fin N)
    (hc : CandidateOk ids C G k) (n : Node V S N CAP)
    (hf : fullLog G n.state = fullLog G (C.live k).state) (ht : n.state.hard.term = (C.live k).state.hard.term)
    (hv : n.votes = (C.live k).votes) (hvf : n.state.hard.voted_for = (C.live k).state.hard.voted_for) :
    CandidateOk ids (C.setLive k n) G k := by
  unfold CandidateOk at *
  simp only [setLive_self, hf, ht, hv, hvf]
  exact hc

theorem sent_vote (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (env : Envelope V S) (hm : env ∈ C.sent) (T : Rust.u64) (last : LogId)
    (hmsg : env.message = .Vote T last) (c : Fin N) (hc : env.from = ids[c]) :
    T.val ≤ (C.disk c).hard.term.val ∧
      ((C.live c).role = .Candidate ∧ (C.live c).state.hard.term = T → lastId (C.live c).state = last) ∧
      (∀ eL, G.elect T.val = some (c, eL) → lastOf eL = last) := by
  have h := (hi.sent env hm).2
  rw [hmsg] at h
  exact h c hc

theorem sent_voted (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (env : Envelope V S) (hm : env ∈ C.sent) (T : Rust.u64)
    (hmsg : env.message = .Voted T true) (w c : Fin N) (hw : env.from = ids[w]) (hc : env.to = ids[c]) :
    (∃ vlog, (T.val, w, c, vlog) ∈ G.ballots) ∨ ∃ eL, G.elect T.val = some (c, eL) := by
  have h := (hi.sent env hm).2
  rw [hmsg] at h
  exact h rfl w c hw hc

theorem sent_replicated (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (env : Envelope V S) (hm : env ∈ C.sent) (T j : Rust.u64)
    (hmsg : env.message = .Replicated T j none) (w : Fin N) (hw : env.from = ids[w]) :
    (w, T.val, j.val) ∈ G.acks := by
  have h := (hi.sent env hm).2
  rw [hmsg] at h
  exact h rfl w hw

theorem votes_keep (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (k : Fin N) (n : Node V S N CAP)
    (h : n.role = .Candidate → (C.live k).role = .Candidate ∧
      n.state.hard.term = (C.live k).state.hard.term ∧ lastId n.state = lastId (C.live k).state) :
    ∀ env ∈ C.sent, ∀ T last, env.from = ids[k] → env.message = .Vote T last →
      n.role = .Candidate ∧ n.state.hard.term = T → lastId n.state = last := by
  intro env hm T last hf hmsg ⟨hr, ht⟩
  have := sent_vote ids cfg C G hi env hm T last hmsg k hf
  obtain ⟨h1, h2, h3⟩ := h hr
  rw [h3]; exact this.2.1 ⟨h1, by rw [← h2, ht]⟩

theorem outbox_queue (ids : Vector Id N) (C : Cluster V S N CAP) (G : Ghost V N) (k a : Fin N)
    (n0 n : Node V S N CAP) (hI : ∀ j : Fin N, n0.outbox[j] = none) (o : Outbound)
    (hob : n.outbox = n0.outbox.set a.val (some o) a.isLt) (hO : OutOk ids C G k a o) :
    ∀ j o', n.outbox[j] = some o' → OutOk ids C G k j o' := by
  intro j o' h
  rw [hob] at h
  simp only [Fin.getElem_fin, Vector.getElem_set] at h
  split at h
  · rename_i hj
    have : j = a := Fin.ext hj.symm
    subst this; rw [← Option.some.inj h]; exact hO
  · have := hI j; simp only [Fin.getElem_fin] at this; rw [this] at h; cases h

theorem outbox_queue_self (k a : Fin N) (hak : a ≠ k) (n0 n : Node V S N CAP) (hI : ∀ j : Fin N, n0.outbox[j] = none)
    (o : Outbound) (hob : n.outbox = n0.outbox.set a.val (some o) a.isLt) : n.outbox[k] = none := by
  rw [hob]
  simp only [Fin.getElem_fin, Vector.getElem_set]
  rw [if_neg (fun e => hak (Fin.ext e))]
  have := hI k; simpa using this


/-- `LocalOk` for a node with node `k`'s state, role, votes and match indexes. -/
theorem local_keep (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (a k : Fin N) (hak : a ≠ k) (hd0 : (C.live k).dirty = false)
    (n : Node V S N CAP) (hF : Fixed ids n) (hcfg : n.config = (C.live k).config) (hloc : n.local = (C.live k).local)
    (hst : n.state = (C.live k).state) (hrole : n.role = (C.live k).role) (hv : n.votes = (C.live k).votes)
    (hm : n.matched = (C.live k).matched)
    (houtbox : ∀ j o, n.outbox[j] = some o → OutOk ids (C.setLive k n) G k j o)
    (hoself : n.outbox[k] = none) : LocalOk ids cfg C G k n := by
  have hs : n.state = { (C.live k).state with hard := (C.live k).state.hard } := by
    rw [state_hard_eta (C.live k).state]; exact hst
  refine local_light ids cfg C G hi a k hak hd0 n _ hs ⟨hF, by rw [hcfg]; exact (hi.fixed k).2⟩
    (by rw [hloc]; exact hi.slot k) (Nat.le_refl _) (Nat.le_refl _) (hi.live k).commit_le (hi.live k).unvoted
    (fun _ => rfl) ?_ ?_ ?_ ?_ houtbox hoself ?_ (commit_same ids cfg C G hi k hd0 n _ hs rfl)
    (fun hr => ⟨hrole ▸ hr, by rw [hst]⟩)
  · intro T c v hb ht; rw [hst] at ht ⊢; exact (hi.ballots T k c v hb).2.2.2 ht
  · intro T eL he; rw [hrole, hst]; exact hi.elect_cand T k eL he
  · intro hr; rw [hrole] at hr
    exact leader_transfer ids C G k (hi.leader k hr) hd0 n (by rw [hst]) (by rw [hst]) hm
  · intro hr; rw [hrole] at hr
    exact cand_transfer ids C G k (hi.candidate k hr) n (by rw [hst]) (by rw [hst]) hv (by rw [hst])
  · exact votes_keep ids cfg C G hi k n (fun hr => ⟨hrole ▸ hr, by rw [hst], by rw [hst]⟩)

/-- `LocalOk` for a node that stepped down to a higher term without a vote. -/
theorem local_up (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (a k : Fin N) (hak : a ≠ k) (hd0 : (C.live k).dirty = false)
    (n : Node V S N CAP) (hF : Fixed ids n) (hcfg : n.config = (C.live k).config) (hloc : n.local = (C.live k).local)
    (t : Rust.u64) (hlt : (C.live k).state.hard.term.val < t.val)
    (hst : n.state = { (C.live k).state with hard := { (C.live k).state.hard with term := t, voted_for := none } })
    (hrole : n.role = .Follower) (hdirty : n.dirty = true)
    (houtbox : ∀ j o, n.outbox[j] = some o → OutOk ids (C.setLive k n) G k j o)
    (hoself : n.outbox[k] = none) : LocalOk ids cfg C G k n := by
  refine local_light ids cfg C G hi a k hak hd0 n _ hst ⟨hF, by rw [hcfg]; exact (hi.fixed k).2⟩
    (by rw [hloc]; exact hi.slot k) (Nat.le_of_lt hlt) (Nat.le_refl _) (hi.live k).commit_le (fun _ => rfl)
    (fun hd => by rw [hdirty] at hd; cases hd) ?_ ?_ ?_ ?_ houtbox hoself ?_
    (commit_same ids cfg C G hi k hd0 n _ hst rfl) (fun hr => by rw [hrole] at hr; cases hr)
  · intro T c v hb ht
    rw [hst] at ht
    exact absurd (ballot_up ids cfg C G hi a k hak T c v hb (by simp only at ht; omega)) id
  · intro T eL _ ⟨hr, _⟩; rw [hrole] at hr; cases hr
  · intro hr; rw [hrole] at hr; cases hr
  · intro hr; rw [hrole] at hr; cases hr
  · exact votes_keep ids cfg C G hi k n (fun hr => by rw [hrole] at hr; cases hr)


theorem outbox_none_ok (ids : Vector Id N) (C : Cluster V S N CAP) (G : Ghost V N) (k : Fin N)
    (n : Node V S N CAP) (hI : ∀ j : Fin N, n.outbox[j] = none) :
    ∀ j o, n.outbox[j] = some o → OutOk ids C G k j o := by
  intro j o h; rw [hI j] at h; cases h

theorem case_stale (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (a k : Fin N) (hak : a ≠ k) (src : Id) (m : Message V S) (n1 n' : Node V S N CAP)
    (hI : Idle (C.live k)) (hO : Observed (C.live k) src m.term n1) (hlt : m.term.val < n1.state.hard.term.val)
    (hn : n' = n1 ∨ n' = queue n1 a (.Voted false) ∨ ∃ i, n' = queue n1 a (.Replicated i (some (.Conflict 1)))) :
    LocalOk ids cfg C G k n' := by
  have hF := fixed_observed ids _ _ (hi.fixed k).1 src _ hO
  obtain ⟨hc, hl, hv, hmt, hob, -, hA | ⟨-, hs, -⟩⟩ := observed_facts _ _ src _ hO
  case inr => rw [hs] at hlt; simp only at hlt; omega
  obtain ⟨-, hs, hr, hd⟩ := hA
  have hI' : ∀ j : Fin N, n1.outbox[j] = none := fun j => by rw [hob]; exact hI.2.2 j
  rcases hn with rfl | rfl | ⟨i, rfl⟩
  · exact local_keep ids cfg C G hi a k hak hI.1 _ hF hc hl hs hr hv hmt (outbox_none_ok ids _ G k _ hI') (hI' k)
  · exact local_keep ids cfg C G hi a k hak hI.1 _ (fixed_queue ids _ hF a _) hc hl hs hr hv hmt
      (outbox_queue ids _ G k a n1 _ hI' _ rfl (by simp [OutOk]))
      (outbox_queue_self k a hak n1 _ hI' _ rfl)
  · exact local_keep ids cfg C G hi a k hak hI.1 _ (fixed_queue ids _ hF a _) hc hl hs hr hv hmt
      (outbox_queue ids _ G k a n1 _ hI' _ rfl (by simp [OutOk]))
      (outbox_queue_self k a hak n1 _ hI' _ rfl)


theorem state_eq_of (s s0 : State V S CAP) (h1 : s.snapshot = s0.snapshot) (h2 : s.entries = s0.entries)
    (h3 : s.len = s0.len) : s = { s0 with hard := s.hard } := by
  cases s; cases s0; simp_all

theorem state_vf_same (s : State V S CAP) (x : Option Id) (h : s.hard.voted_for = x) :
    ({ s with hard := { s.hard with voted_for := x } } : State V S CAP) = s := by
  rcases s with ⟨⟨_, _, _⟩, _, _, _⟩
  simp only at h; subst h; rfl

theorem case_vote (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (a k : Fin N) (hak : a ≠ k) (src dst : Id) (hsrc : src = ids[a]) (hdst : dst = ids[k])
    (t : Rust.u64) (last : LogId) (ht0 : t.val ≠ 0) (hm : ⟨src, dst, .Vote t last⟩ ∈ C.sent)
    (n1 n2 : Node V S N CAP) (g : Bool)
    (hI : Idle (C.live k)) (hO : Observed (C.live k) src t n1) (hT : n1.state.hard.term = t)
    (hg : g = decide ((n1.state.hard.voted_for = none ∨ n1.state.hard.voted_for = some src) ∧
        upToDate last (lastId n1.state)))
    (h1 : g = false → n2 = n1)
    (h2 : g = true → Timers { n1 with state := { n1.state with hard := { n1.state.hard with voted_for := some src } }, dirty := (n1.dirty || decide (n1.state.hard.voted_for ≠ some src)) } n2)
    (n : Node V S N CAP) (hn : n = queue n2 a (.Voted g)) : LocalOk ids cfg C G k n := by
  have hF1 := fixed_observed ids _ _ (hi.fixed k).1 src _ hO
  have hsl := hi.live k
  obtain ⟨hc1, hl1, hv1, hm1, hob1, -, hA⟩ := observed_facts _ _ src _ hO
  -- `n2` relative to `n1`
  have hn2 : Fixed ids n2 ∧ n2.config = n1.config ∧ n2.local = n1.local ∧ n2.votes = n1.votes ∧
      n2.matched = n1.matched ∧ n2.outbox = n1.outbox ∧ n2.role = n1.role ∧
      n2.state.snapshot = n1.state.snapshot ∧ n2.state.entries = n1.state.entries ∧ n2.state.len = n1.state.len ∧
      n2.state.hard.term = n1.state.hard.term ∧ n2.state.hard.commit = n1.state.hard.commit ∧
      n2.state.hard.voted_for = (if g then some src else n1.state.hard.voted_for) ∧
      (n2.dirty = false → n1.dirty = false ∧ n2.state = n1.state) := by
    cases g
    · obtain rfl := h1 rfl
      exact ⟨hF1, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, fun h => ⟨h, rfl⟩⟩
    · obtain ⟨r, d, rfl⟩ := h2 rfl
      refine ⟨{ hF1 with layout := hF1.layout, contig := hF1.contig }, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, fun hd => ?_⟩
      simp only [Bool.or_eq_false_iff, decide_eq_false_iff_not, Classical.not_not] at hd
      exact ⟨hd.1, state_vf_same _ _ hd.2⟩
  obtain ⟨hF2, hc2, hl2, hv2, hm2, hob2, hr2, hsn, hen, hln, hte, hco, hvf, hdc⟩ := hn2
  -- the old node and the observed term
  have hn1 : n1.state.snapshot = (C.live k).state.snapshot ∧ n1.state.entries = (C.live k).state.entries ∧
      n1.state.len = (C.live k).state.len ∧ n1.state.hard.commit = (C.live k).state.hard.commit ∧
      (C.live k).state.hard.term.val ≤ t.val := by
    rcases hA with ⟨ht, hs, -⟩ | ⟨ht, hs, -⟩
    · have hT' := hT; rw [hs] at hT' ⊢; exact ⟨rfl, rfl, rfl, rfl, by rw [hT']; exact Nat.le_refl _⟩
    · rw [hs]; exact ⟨rfl, rfl, rfl, rfl, by omega⟩
  obtain ⟨hsn1, hen1, hln1, hco1, hle⟩ := hn1
  have hns : n.state = n2.state := by rw [hn]; rfl
  have hnr : n.role = n2.role := by rw [hn]; rfl
  have hs : n.state = { (C.live k).state with hard := n.state.hard } := by
    rw [hns]; exact state_eq_of _ _ (hsn.trans hsn1) (hen.trans hen1) (hln.trans hln1)
  have hnt : n.state.hard.term = t := by rw [hns]; exact hte.trans hT
  have hfl : fullLog G n.state = fullLog G (C.live k).state := by rw [hs]; rfl
  have hli : lastId n.state = lastId (C.live k).state := by rw [hs]; rfl
  have hl1' : lastId n1.state = lastId (C.live k).state := by
    rcases hA with ⟨-, h, -⟩ | ⟨-, h, -⟩ <;> rw [h] <;> rfl
  -- in the same term, the old vote stands or is for the sender
  have hsame : ∀ c : Fin N, (C.live k).state.hard.voted_for = some ids[c] → (C.live k).state.hard.term = t →
      n.state.hard.voted_for = some ids[c] := by
    intro c hc htt
    rcases hA with ⟨-, h, -⟩ | ⟨h, -⟩
    · rw [hns, hvf, h]
      cases g
      · exact hc
      · simp only [if_true]
        have := hg.symm; simp only [decide_eq_true_eq, h] at this
        rcases this.1 with h' | h'
        · rw [hc] at h'; cases h'
        · rw [hc] at h'; exact congrArg some (Option.some.inj h').symm
    · rw [htt] at h; omega
  have hcaseA : n.role = .Leader ∨ n.role = .Candidate → n1.state = (C.live k).state ∧ n.role = (C.live k).role := by
    intro hr
    rcases hA with ⟨-, h, h', -⟩ | ⟨-, -, h', -⟩
    · exact ⟨h, by rw [hnr, hr2, h']⟩
    · rw [hnr, hr2, h'] at hr; rcases hr with hr | hr <;> cases hr
  refine local_light ids cfg C G hi a k hak hI.1 n _ hs ⟨by rw [hn]; exact fixed_queue ids _ hF2 a _, ?_⟩ ?_
    (by rw [hnt]; exact hle) (by rw [hns, hco, hco1]; exact Nat.le_refl _) (by rw [hns, hco, hco1]; exact hsl.commit_le)
    (fun h => absurd (by rw [hnt] at h; exact h) ht0) ?_ ?_ ?_ ?_ ?_ ?_ ?_ ?_ ?_
    (fun hr => ⟨by rw [← (hcaseA (Or.inr hr)).2]; exact hr, by rw [hnt, ← hT, (hcaseA (Or.inr hr)).1]⟩)
  · rw [hn]; show n2.config = _; rw [hc2, hc1]; exact (hi.fixed k).2
  · rw [hn]; show n2.local.val = _; rw [hl2, hl1]; exact hi.slot k
  · intro hd
    obtain ⟨hd1, hs2⟩ := hdc (by rw [hn] at hd; exact hd)
    rcases hA with ⟨-, h, -, -⟩ | ⟨-, -, -, h⟩
    · rw [hns, hs2, h]
    · rw [h] at hd1; cases hd1
  · intro T c v hb ht
    by_cases hlt : (C.live k).state.hard.term.val < T
    · exact absurd (ballot_up ids cfg C G hi a k hak T c v hb hlt) id
    · have h1 : t.val = T := by rw [hnt] at ht; exact ht
      have htt : (C.live k).state.hard.term = t := Fin.ext (by omega)
      exact hsame c ((hi.ballots T k c v hb).2.2.2 (by rw [htt, ← ht, hnt])) htt
  · intro T eL he ⟨hr, ht⟩
    rcases hA with ⟨-, h', h, -⟩ | ⟨-, -, h, -⟩
    · apply hi.elect_cand T k eL he
      refine ⟨by rw [← h, ← hr2, ← hnr]; exact hr, ?_⟩
      rw [← ht, hnt, ← hT, h']
    · rw [hnr, hr2, h] at hr; cases hr
  · intro hr
    obtain ⟨h1s, h1r⟩ := hcaseA (Or.inl hr)
    rw [h1r] at hr
    exact leader_transfer ids C G k (hi.leader k hr) hI.1 n hfl (by rw [hnt, ← hT, h1s])
      (by rw [hn]; show n2.matched = _; rw [hm2, hm1])
  · intro hr
    obtain ⟨h1s, h1r⟩ := hcaseA (Or.inr hr)
    rw [h1r] at hr
    have hc := hi.candidate k hr
    have htt : (C.live k).state.hard.term = t := by rw [← hT, h1s]
    exact cand_transfer ids C G k hc n hfl (by rw [hnt, htt]) (by rw [hn]; show n2.votes = _; rw [hv2, hv1])
      (by rw [hsame k hc.1 htt, hc.1])
  · refine outbox_queue ids (C.setLive k n) G k a n2 n (fun j => by rw [hob2, hob1]; exact hI.2.2 j) _
      (by rw [hn]; rfl) ?_
    unfold OutOk
    simp only [setLive_self]
    intro hgt
    have hg' := hg.symm
    rw [hgt] at hg'
    simp only [decide_eq_true_eq] at hg'
    refine ⟨?_, last, ?_, ?_⟩
    · rw [hns, hvf, hgt, hsrc]; rfl
    · show _ ∈ C.sent
      rw [hnt, ← hsrc, ← hdst]; exact hm
    · rw [hfl, lastOf_fullLog G _ hsl, ← hl1']; exact hg'.2
  · exact outbox_queue_self k a hak n2 n (fun j => by rw [hob2, hob1]; exact hI.2.2 j) _ (by rw [hn]; rfl)
  · refine votes_keep ids cfg C G hi k n (fun hr => ?_)
    obtain ⟨h1s, h1r⟩ := hcaseA (Or.inr hr)
    exact ⟨h1r ▸ hr, by rw [hnt, ← hT, h1s], hli⟩
  · exact commit_same ids cfg C G hi k hI.1 n _ hs (by rw [hns, hco, hco1])


theorem adv_local (m m' : Node V S N CAP) (h : Adv m m') : m'.local = m.local := by
  rcases h with rfl | ⟨v, -, -, -, rfl⟩
  · rfl
  · unfold commitTo; split <;> rfl

/-- The early-return case: only `active` changed. -/
theorem replicated_trivial2 (ids : Vector Id N) (n : Node V S N CAP) (hf : Fixed ids n)
    (p : Nat) (hp : p < N) (index : Rust.u64) (rej : Option Rejection) (a : Vector Bool N) (nx : Vector Rust.u64 N)
    (ob : Vector (Option Outbound) N) (hob : ∀ j : Fin N, ob[j] = n.outbox[j] ∨ (ob[j] = some .Replicate ∧ (j.val = p ∨ j.val ≠ n.local.val))) :
    Fixed ids { n with active := a, next := nx, outbox := ob } ∧
      ∃ m, Recorded n m p hp index rej ∧ Fixed ids m ∧
        ∃ m', Adv m m' ∧ ({ n with active := a, next := nx, outbox := ob } : Node V S N CAP).config = m'.config ∧
          ({ n with active := a, next := nx, outbox := ob } : Node V S N CAP).state = m'.state ∧
          ({ n with active := a, next := nx, outbox := ob } : Node V S N CAP).role = m'.role ∧
          ({ n with active := a, next := nx, outbox := ob } : Node V S N CAP).votes = m'.votes ∧
          ({ n with active := a, next := nx, outbox := ob } : Node V S N CAP).dirty = m'.dirty ∧
          ({ n with active := a, next := nx, outbox := ob } : Node V S N CAP).matched = m'.matched ∧
          ({ n with active := a, next := nx, outbox := ob } : Node V S N CAP).local = m'.local ∧
          ({ n with active := a, next := nx, outbox := ob } : Node V S N CAP).extra_reply = m'.extra_reply ∧
          ∀ j : Fin N, ({ n with active := a, next := nx, outbox := ob } : Node V S N CAP).outbox[j] = m'.outbox[j] ∨
            (({ n with active := a, next := nx, outbox := ob } : Node V S N CAP).outbox[j] = some .Replicate ∧
              (j.val = p ∨ j.val ≠ n.local.val)) :=
  ⟨fixed_misc ids n hf a nx n.matched ob, n, ⟨rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, Or.inl rfl⟩, hf, n, Or.inl rfl,
    rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, hob⟩

theorem replicated_rel2 (ids : Vector Id N) (n : Node V S N CAP) (hf : Fixed ids n)
    (p : Rust.usize) (hp : p.val < N) (index : Rust.u64) (rej : Option Rejection) :
    ∃ n', Node.replicated n p index rej = pure n' ∧ Fixed ids n' ∧
      ∃ m, Recorded n m p.val hp index rej ∧ Fixed ids m ∧
        ∃ m', Adv m m' ∧ n'.config = m'.config ∧ n'.state = m'.state ∧ n'.role = m'.role ∧
          n'.votes = m'.votes ∧ n'.dirty = m'.dirty ∧ n'.matched = m'.matched ∧ n'.local = m'.local ∧
          n'.extra_reply = m'.extra_reply ∧
          ∀ j : Fin N, n'.outbox[j] = m'.outbox[j] ∨
            (n'.outbox[j] = some .Replicate ∧ (j.val = p.val ∨ j.val ≠ n.local.val)) := by
  have hN : N < 2 ^ 64 := by have := hf.n_lt; omega
  have triv := replicated_trivial2 ids n hf p.val hp index rej (n.active.set p.val true hp) n.next n.outbox
    (fun _ => Or.inl rfl)
  unfold Node.replicated
  simp only [Rust.Slice.set_ok _ _ _ hp, pure_bind, last_eq _ hf.layout.1]
  by_cases h1 : index > (lastId n.state).index
  · simp only [h1, decide_true, if_true]
    exact ⟨_, rfl, triv⟩
  · rcases rej with _ | (nx | _) <;> simp only [h1, decide_false, Bool.false_eq_true, if_false]
    · simp only [Rust.Slice.index_ok _ _ hp, pure_bind]
      by_cases h2 : index ≤ n.matched[p.val]
      · simp only [h2, decide_true, if_true]
        exact ⟨_, rfl, triv⟩
      · simp only [h2, decide_false, Bool.false_eq_true, if_false]
        have hfm := fixed_misc ids n hf (n.active.set p.val true hp)
          (n.next.set p.val (Rust.max n.next[p.val] (Rust.saturating_add index 1)) hp)
          (n.matched.set p.val index hp) n.outbox
        obtain ⟨b, m', hadv, hA⟩ := advance_rel ids _ hfm
        have hfm' := fixed_adv ids _ _ hfm hA
        have hR : Recorded n { n with active := n.active.set p.val true hp, next := n.next.set p.val (Rust.max n.next[p.val] (Rust.saturating_add index 1)) hp, matched := n.matched.set p.val index hp, outbox := n.outbox } p.val hp index none :=
          ⟨rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, Or.inr ⟨rfl, by simp [Fin.lt_def] at h1; omega,
            by simp [Fin.le_def] at h2; omega, rfl⟩⟩
        simp only [hadv, pure_bind]
        cases b
        · simp only [Bool.false_eq_true, if_false, last_eq _ hfm'.layout.1, pure_bind]
          by_cases h3 : index < (lastId m'.state).index
          · simp only [h3, decide_true, if_true, replicate_eq _ _ hN hp, pure_bind]
            refine ⟨_, rfl, ?_, _, hR, hfm, m', hA, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, ?_⟩
            · exact { hfm' with layout := hfm'.layout, contig := hfm'.contig }
            · intro j
              simp only [Fin.getElem_fin, Vector.getElem_set]
              split
              · rename_i hj; exact Or.inr ⟨rfl, Or.inl hj.symm⟩
              · exact Or.inl rfl
          · simp only [h3, decide_false, Bool.false_eq_true, if_false]
            exact ⟨_, rfl, hfm', _, hR, hfm, m', hA, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, fun _ => Or.inl rfl⟩
        · simp only [if_true, broadcast_eq ids m' hfm', pure_bind]
          refine ⟨_, rfl, ?_, _, hR, hfm, m', hA, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, ?_⟩
          · exact { hfm' with layout := hfm'.layout, contig := hfm'.contig }
          · intro j
            simp only [bcast, Fin.getElem_fin, Vector.getElem_ofFn]
            split
            · rename_i hj; exact Or.inr ⟨rfl, Or.inr (by rw [adv_local _ _ hA] at hj; exact hj)⟩
            · exact Or.inl rfl
    · simp only [Rust.Slice.index_ok _ _ hp, pure_bind]
      by_cases h2 : index ≥ n.matched[p.val]
      · simp only [h2, decide_true, if_true]
        by_cases h3 : (Rust.checked_add index 1 == some n.next[p.val]) = true
        · have hcl : (Rust.saturating_add n.matched[p.val] 1).val ≤
              (Rust.saturating_add (lastId n.state).index 1).val := by
            rw [Rust.val_saturating_add, Rust.val_saturating_add]
            simp only [Fin.le_def, gt_iff_lt, Fin.lt_def, ge_iff_le, Nat.not_lt] at h1 h2
            simp only [Nat.min_def]
            split <;> split <;> omega
          simp only [h3, if_true, Rust.clamp_ok _ _ _ hcl, pure_bind,
            replicate_eq _ _ hN hp]
          exact ⟨_, rfl, replicated_trivial2 ids n hf p.val hp index _ (n.active.set p.val true hp)
            (n.next.set p.val (Rust.min (Rust.max nx (Rust.saturating_add n.matched[p.val] 1))
              (Rust.saturating_add (lastId n.state).index 1)) hp)
            (n.outbox.set p.val (some .Replicate) hp) (fun j => by
              simp only [Fin.getElem_fin, Vector.getElem_set]
              split
              · rename_i hj; exact Or.inr ⟨rfl, Or.inl hj.symm⟩
              · exact Or.inl rfl)⟩
        · simp only [h3, Bool.false_eq_true, if_false]
          exact ⟨_, rfl, triv⟩
      · simp only [h2, decide_false, Bool.false_eq_true, if_false]
        exact ⟨_, rfl, triv⟩
    · exact ⟨_, rfl, triv⟩



theorem majority_of_countP (P : Fin N → Prop) (b : Fin N → Bool) (h : ∀ j, b j = true ↔ P j)
    (hc : N / 2 < (List.finRange N).countP b) : Majority N P := by
  unfold Majority
  have : (List.finRange N).countP (fun w => @decide (P w) (Classical.propDecidable _)) =
      (List.finRange N).countP b := by
    apply List.countP_congr; intro x _; simp only [decide_eq_true_eq]; exact (h x).symm
  omega

theorem adv_point (G : Ghost V N) (s : State V S CAP) (hs : StateOk G s) (v T : Rust.u64)
    (hb : s.base.index.val < v.val)
    (h : Rust.Option.is_some_and (State.id_at s v) (fun id => id.term == T) = true) :
    ∃ hl : v.val - 1 < (fullLog G s).length, ((fullLog G s)[v.val - 1]).id.term = T := by
  rw [id_at_eq s hs.layout] at h
  cases hid : idAt s v.val with
  | none => rw [hid] at h; simp at h
  | some id =>
    rw [hid] at h
    simp at h
    obtain ⟨-, hl, he⟩ := (idAt_fullLog G s hs v.val (by omega) id).mp hid
    exact ⟨hl, by rw [he]; exact h⟩

theorem adv_cases (m m' : Node V S N CAP) (h : Adv m m') : m' = m ∨ ∃ v : Rust.u64,
    N / 2 < (List.finRange N).countP (fun j => decide (v.val ≤ (m.matched[j]).val)) ∧
    m.state.hard.commit < v ∧
    Rust.Option.is_some_and (State.id_at m.state v) (fun id => id.term == m.state.hard.term) = true ∧
    m' = { m with state := { m.state with hard := { m.state.hard with commit := v } }, dirty := true } := by
  rcases h with rfl | ⟨v, h1, h2, h3, rfl⟩
  · exact Or.inl rfl
  · exact Or.inr ⟨v, h1, h2, h3, by simp [commitTo, h2]⟩

/-- `LocalOk` for the node right after observing a message's term. -/
theorem local_observed (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (a k : Fin N) (hak : a ≠ k) (hI : Idle (C.live k)) (src : Id) (t : Rust.u64)
    (n1 : Node V S N CAP) (hO : Observed (C.live k) src t n1) : LocalOk ids cfg C G k n1 := by
  have hF1 := fixed_observed ids _ _ (hi.fixed k).1 src _ hO
  obtain ⟨hc, hl, hv, hmt, hob, -, ⟨-, hs, hr, -⟩ | ⟨hlt, hs, hr, hd⟩⟩ := observed_facts _ _ src _ hO
  · have hI' : ∀ j : Fin N, n1.outbox[j] = none := fun j => by rw [hob]; exact hI.2.2 j
    exact local_keep ids cfg C G hi a k hak hI.1 _ hF1 hc hl hs hr hv hmt (outbox_none_ok ids _ G k _ hI') (hI' k)
  · have hI' : ∀ j : Fin N, n1.outbox[j] = none := fun j => by rw [hob]; exact hI.2.2 j
    exact local_up ids cfg C G hi a k hak hI.1 _ hF1 hc hl t hlt hs hr hd (outbox_none_ok ids _ G k _ hI') (hI' k)


theorem case_replicated (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (a k : Fin N) (hak : a ≠ k) (src dst : Id) (hsrc : src = ids[a])
    (t index : Rust.u64) (rej : Option Rejection) (hm : ⟨src, dst, .Replicated t index rej⟩ ∈ C.sent)
    (n1 n' : Node V S N CAP) (hI : Idle (C.live k)) (hO : Observed (C.live k) src t n1)
    (hT : n1.state.hard.term = t) (hl : n1.role = .Leader)
    (hr : Node.replicated n1 (Rust.ofNat a.val) index rej = pure n') : LocalOk ids cfg C G k n' := by
  have hF1 := fixed_observed ids _ _ (hi.fixed k).1 src _ hO
  obtain ⟨hc1, hl1, hv1, hm1, hob1, -, hA⟩ := observed_facts _ _ src _ hO
  have hA1 : n1.state = (C.live k).state ∧ n1.role = (C.live k).role ∧ n1.dirty = (C.live k).dirty := by
    rcases hA with ⟨-, h, h', h''⟩ | ⟨-, -, h, -⟩
    · exact ⟨h, h', h''⟩
    · rw [h] at hl; cases hl
  obtain ⟨hs1, hr1, hd1⟩ := hA1
  have hN : N < 2 ^ 64 := by have := hF1.n_lt; omega
  have hav : (Rust.ofNat a.val : Rust.usize).val = a.val := by simp [Rust.ofNat]; omega
  have hp : (Rust.ofNat a.val : Rust.usize).val < N := by rw [hav]; exact a.isLt
  obtain ⟨n'', hr', hF', m, hR, -, m', hA', hcf, hst, hro, hvo, hdi, hma, hlo, -, hob⟩ :=
    replicated_rel2 ids n1 hF1 _ hp index rej
  rw [hr'] at hr
  have e : n' = n'' := (pure_inj hr).symm
  subst e
  obtain ⟨hRc, hRs, hRr, hRv, hRd, hRl, hRo, -, hRm⟩ := hR
  have hL0 := hi.leader k (by rw [← hr1]; exact hl)
  have hsl := hi.live k
  have hd0 := hI.1
  have hT0 : (C.live k).state.hard.term = t := by rw [← hs1]; exact hT
  have hk0 : (C.live k).local.val = k.val := hi.slot k
  -- every raised match index of another node is acknowledged
  have hmatch : ∀ j : Fin N, j ≠ k → 0 < (m.matched[j]).val →
      (j, (C.live k).state.hard.term.val, (m.matched[j]).val) ∈ G.acks := by
    intro j hj hpos
    rcases hRm with h | ⟨hrej, -, -, h⟩
    · rw [h, hm1] at hpos ⊢; exact hL0.matched j hj hpos
    · rw [h] at hpos ⊢
      simp only [Fin.getElem_fin, Vector.getElem_set, hav] at hpos ⊢
      split
      · rename_i hja
        have : j = a := Fin.ext hja.symm
        subst this
        rw [hrej] at hm
        rw [hT0]
        exact sent_replicated ids cfg C G hi _ hm t index rfl j hsrc
      · rename_i hja
        rw [if_neg hja] at hpos
        rw [hm1] at hpos ⊢; exact hL0.matched j hj hpos
  have hown : (m.matched[k]).val = ((C.live k).matched[k]).val := by
    rcases hRm with h | ⟨-, -, -, h⟩
    · rw [h, hm1]
    · rw [h]
      simp only [Fin.getElem_fin, Vector.getElem_set, hav]
      rw [if_neg (fun e => hak (Fin.ext e)), hm1]
  have hAdv := adv_cases _ _ hA'
  have hms : m.state = (C.live k).state := hRs.trans hs1
  have hs : n'.state = { (C.live k).state with hard := n'.state.hard } := by
    rw [hst]
    rcases hAdv with h | ⟨v, -, -, -, h⟩ <;> rw [h] <;> exact state_eq_of _ _ (by rw [hms]) (by rw [hms]) (by rw [hms])
  have hht : n'.state.hard.term = (C.live k).state.hard.term ∧
      n'.state.hard.voted_for = (C.live k).state.hard.voted_for := by
    rw [hst]
    rcases hAdv with h | ⟨v, -, -, -, h⟩ <;> rw [h] <;> simp [hms]
  have hfl : fullLog G n'.state = fullLog G (C.live k).state := by rw [hs]; rfl
  have hrole : n'.role = .Leader := by rw [hro]; rcases hAdv with h | ⟨v, -, -, -, h⟩ <;> rw [h] <;> exact hRr.trans hl
  have hmat : n'.matched = m.matched := by rw [hma]; rcases hAdv with h | ⟨v, -, -, -, h⟩ <;> rw [h]
  have hloc : n'.local = (C.live k).local := by rw [hlo]; rcases hAdv with h | ⟨v, -, -, -, h⟩ <;> rw [h] <;> exact hRl.trans hl1
  have hobx : ∀ j : Fin N, n'.outbox[j] = none ∨ (n'.outbox[j] = some .Replicate ∧ j ≠ k) := by
    intro j
    have hmo : m'.outbox = (C.live k).outbox := by
      rcases hAdv with h | ⟨v, -, -, -, h⟩ <;> rw [h] <;> exact hRo.trans hob1
    rcases hob j with h | ⟨h, h'⟩
    · left; rw [h, hmo]; exact hI.2.2 j
    · right; refine ⟨h, fun e => ?_⟩
      subst e
      rcases h' with h' | h'
      · rw [hav] at h'; exact hak (Fin.ext h'.symm)
      · rw [hl1, hk0] at h'; exact h' rfl
  -- the commit index: unchanged, or raised by a majority
  have hcommit : (n'.state = (C.live k).state ∧ n'.dirty = false) ∨
      ∃ v : Rust.u64, n'.state.hard.commit = v ∧ (C.live k).state.hard.commit < v ∧ n'.dirty = true ∧
        N / 2 < (List.finRange N).countP (fun j => decide (v.val ≤ (m.matched[j]).val)) ∧
        Rust.Option.is_some_and (State.id_at (C.live k).state v)
          (fun id => id.term == (C.live k).state.hard.term) = true := by
    rcases hAdv with h | ⟨v, h1, h2, h3, h⟩
    · left; rw [hst, hdi, h, hms, hRd, hd1]; exact ⟨rfl, hd0⟩
    · right; refine ⟨v, by rw [hst, h], by rw [← hms]; exact h2, by rw [hdi, h], h1, by rw [← hms]; exact h3⟩
  have hcfg : n'.config = (C.live k).config := by
    rw [hcf]; rcases hAdv with h | ⟨v, -, -, -, h⟩ <;> rw [h] <;> exact hRc.trans hc1
  have hcm : n'.state.hard.commit.val ≤ (lastId (C.live k).state).index.val := by
    rcases hcommit with ⟨h, -⟩ | ⟨v, h, hlt, -, -, hid⟩
    · rw [h]; exact hsl.commit_le
    · obtain ⟨hl, -⟩ := adv_point G _ hsl v _ (by have := hsl.commit_ge; rw [Fin.lt_def] at hlt; omega) hid
      rw [fullLog_length G _ hsl] at hl
      rw [h]; omega
  refine local_light ids cfg C G hi a k hak hd0 n' _ hs ⟨hF', by rw [hcfg]; exact (hi.fixed k).2⟩
    (by rw [hloc]; exact hk0) (by rw [hht.1]; exact Nat.le_refl _) ?_ hcm
    (by rw [hht.1, hht.2]; exact hsl.unvoted) ?_ ?_ ?_ ?_ ?_ ?_ ?_ ?_ ?_
    (fun hr => by rw [hrole] at hr; cases hr)
  · rcases hcommit with ⟨h, -⟩ | ⟨v, h, hlt, -, -, -⟩
    · rw [h]; exact Nat.le_refl _
    · rw [h]; rw [Fin.lt_def] at hlt; omega
  · intro hd
    rcases hcommit with ⟨h, -⟩ | ⟨v, -, -, h, -, -⟩
    · rw [h]
    · rw [h] at hd; cases hd
  · intro T c v hb ht; rw [hht.1] at ht; rw [hht.2]; exact (hi.ballots T k c v hb).2.2.2 ht
  · intro T eL _ ⟨hr, _⟩; rw [hrole] at hr; cases hr
  · intro _
    obtain ⟨⟨eL, he, hp, hb⟩, ⟨L, hL1, hL2, hL3⟩, -, hown0⟩ := hL0
    refine ⟨⟨eL, ?_, ?_, ?_⟩, ⟨L, ?_, ?_, ?_⟩, ?_, ?_⟩ <;> simp only [setLive_self, hfl, hht.1, hmat]
    · exact he
    · exact hp
    · exact hb
    · exact hL1
    · exact hL2
    · intro _; exact hL3 hd0
    · exact hmatch
    · rw [hown]; exact hown0
  · intro hr; rw [hrole] at hr; cases hr
  · intro j o h
    rcases hobx j with h' | ⟨h', -⟩
    · rw [h'] at h; cases h
    · rw [h'] at h; cases h
      simp only [OutOk, setLive_self]; exact hrole
  · rcases hobx k with h' | ⟨-, h'⟩
    · exact h'
    · exact absurd rfl h'
  · exact votes_keep ids cfg C G hi k n' (fun hr => by rw [hrole] at hr; cases hr)
  · rcases hcommit with ⟨h, -⟩ | ⟨v, h, hlt, hdt, hmaj, hid⟩
    · exact commit_same ids cfg C G hi k hd0 n' _ hs (by rw [h])
    · right
      refine ⟨hrole, hdt, Or.inr ⟨n'.state.hard.term.val, v.val, ⟨?_, ?_⟩, ?_⟩⟩
      · rw [Fin.lt_def] at hlt; omega
      · obtain ⟨hl, hterm⟩ := adv_point G _ hsl v _ (by have := hsl.commit_ge; rw [Fin.lt_def] at hlt; omega) hid
        refine ⟨fullLog G n'.state, by simp [withOwn], by rw [hfl]; exact hl, ?_, ?_⟩
        · simp only [hfl, hterm, hht.1]
        · refine majority_mono _ _ ?_ (majority_of_countP _ _ (fun j => by simp only [decide_eq_true_eq]; exact Iff.rfl) hmaj)
          intro w hw
          by_cases hwk : w = k
          · refine ⟨(fullLog G n'.state).length, by rw [hfl]; omega, ?_⟩
            simp only [withOwn, hwk]; exact List.mem_cons_self
          · refine ⟨(m.matched[w]).val, hw, ?_⟩
            simp only [withOwn]
            apply List.mem_cons_of_mem
            rw [hht.1]
            exact hmatch w hwk (by rw [Fin.lt_def] at hlt; omega)
      · simp [Ghost.prefix, withOwn, h]


/-- A candidate counting the vote of `a`. -/
theorem local_count (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (a k : Fin N) (hak : a ≠ k) (hI : Idle (C.live k))
    (hcand : (C.live k).role = .Candidate)
    (hup : ∃ vlog, ((C.live k).state.hard.term.val, a, k, vlog) ∈ G.ballots ∧
      upToDate (lastOf (fullLog G (C.live k).state)) (lastOf vlog))
    (n : Node V S N CAP) (hF : Fixed ids n) (hcfg : n.config = (C.live k).config) (hloc : n.local = (C.live k).local)
    (hst : n.state = (C.live k).state) (hrole : n.role = (C.live k).role)
    (hv : n.votes = (C.live k).votes.set a.val true a.isLt) (_hm : n.matched = (C.live k).matched)
    (hob : ∀ j : Fin N, n.outbox[j] = none) : LocalOk ids cfg C G k n := by
  have hs : n.state = { (C.live k).state with hard := (C.live k).state.hard } := by
    rw [state_hard_eta (C.live k).state]; exact hst
  refine local_light ids cfg C G hi a k hak hI.1 n _ hs ⟨hF, by rw [hcfg]; exact (hi.fixed k).2⟩
    (by rw [hloc]; exact hi.slot k) (Nat.le_refl _) (Nat.le_refl _) (hi.live k).commit_le (hi.live k).unvoted
    (fun _ => rfl) ?_ ?_ ?_ ?_ (outbox_none_ok ids _ G k n hob) (hob k) ?_
    (commit_same ids cfg C G hi k hI.1 n _ hs rfl) (fun hr => ⟨hrole ▸ hr, by rw [hst]⟩)
  · intro T c v hb ht; rw [hst] at ht ⊢; exact (hi.ballots T k c v hb).2.2.2 ht
  · intro T eL he; rw [hrole, hst]; exact hi.elect_cand T k eL he
  · intro hr; rw [hrole, hcand] at hr; cases hr
  · intro _
    have hc := hi.candidate k hcand
    unfold CandidateOk at hc ⊢
    simp only [setLive_self, hst, hv]
    refine ⟨hc.1, hc.2.1, fun j hj => ?_⟩
    simp only [Fin.getElem_fin, Vector.getElem_set] at hj
    split at hj
    · rename_i hja
      have : j = a := Fin.ext hja.symm
      subst this
      exact Or.inr hup
    · exact hc.2.2 j (by simpa using hj)
  · exact votes_keep ids cfg C G hi k n (fun hr => ⟨hrole ▸ hr, by rw [hst], by rw [hst]⟩)


theorem withOwn_extends {G G' : Ghost V N} (e : Extends G G') (j : Fin N) (m : Node V S N CAP)
    (hs : StateOk G m.state) : Extends (withOwn G j m) (withOwn G' j m) := by
  have hf := fullLog_extends e m.state hs
  refine ⟨fun t L h => ?_, fun t x h => e.elect t x h, fun x h => ?_, fun x h => e.ballots x h⟩
  · simp only [withOwn] at h ⊢
    split
    · rename_i ht; rw [if_pos ht] at h; rw [hf]; exact ⟨L, h, List.prefix_refl L⟩
    · rename_i ht; rw [if_neg ht] at h; exact e.leader t L h
  · simp only [withOwn, List.mem_cons] at h ⊢
    rcases h with h | h
    · left; rw [h, hf]
    · right; exact e.acks x h

theorem commitOk_extends {G G' : Ghost V N} (e : Extends G G') (j : Fin N) (m : Node V S N CAP)
    (hs : StateOk G m.state) (h : CommitOk G j m) : CommitOk G' j m := by
  have hf := fullLog_extends e m.state hs
  rcases h with h | ⟨h1, h2, h3⟩
  · left; rw [hf]; exact committed_mono e _ h
  · right; refine ⟨h1, h2, ?_⟩; rw [hf]; exact committed_mono (withOwn_extends e j m hs) _ h3

/-- The frame for a step that also records new history about node `k`. -/
theorem setLive_grow (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G G' : Ghost V N)
    (hi : Inv ids cfg C G) (k : Fin N) (n : Node V S N CAP)
    (gl : ∀ t L, G.leader t = some L → G'.leader t = some L)
    (ge : ∀ t x, G.elect t = some x → G'.elect t = some x)
    (gacks : G'.acks = G.acks)
    (gb : ∀ b ∈ G.ballots, b ∈ G'.ballots)
    (gnb : ∀ T w c v, (T, w, c, v) ∈ G'.ballots → (T, w, c, v) ∉ G.ballots →
      w = k ∧ c = k ∧ T ≤ (C.disk k).hard.term.val ∧
      ((C.disk k).hard.term.val = T → (C.disk k).hard.voted_for = some ids[k]))
    (gne : ∀ T x, G'.elect T = some x → G.elect T = none →
      x.1 = k ∧ ¬ (C.disk k).hard.term.val < T ∧ G.leader T = none)
    (hwf : Wf G')
    (hbu : ∀ T w c c' v v', (T, w, c, v) ∈ G'.ballots → (T, w, c', v') ∈ G'.ballots → c = c')
    (hvote : ∀ env ∈ C.sent, ∀ T last, env.from = ids[k] → env.message = .Vote T last →
      ∀ eL, G'.elect T.val = some (k, eL) → G.elect T.val = none → lastOf eL = last)
    (hl : LocalOk ids cfg C G' k n) : Inv ids cfg (C.setLive k n) G' := by
  have ext : Extends G G' := ⟨fun t L h => ⟨L, gl t L h, List.prefix_refl L⟩, ge,
    fun x h => by rw [gacks]; exact h, gb⟩
  have flv : ∀ j, fullLog G' (C.live j).state = fullLog G (C.live j).state :=
    fun j => fullLog_extends ext _ (hi.live j)
  have fld : ∀ j, fullLog G' (C.disk j) = fullLog G (C.disk j) := fun j => fullLog_extends ext _ (hi.disk j)
  have ackok : ∀ t j, AckOk G t j → AckOk G' t j := fun t j ⟨L, h1, h2⟩ => ⟨L, gl t L h1, h2⟩
  -- an election in `G'` is old, or is `k`'s new one
  have hdk : (C.setLive k n).disk = C.disk := rfl
  have eold : ∀ T c eL, G'.elect T = some (c, eL) →
      G.elect T = some (c, eL) ∨ (c = k ∧ ¬ (C.disk k).hard.term.val < T ∧ G.leader T = none) := by
    intro T c eL h
    cases hg : G.elect T with
    | none => right; exact gne T _ h hg
    | some x =>
      left; have := ge T x hg; rw [h] at this; rw [Option.some.inj this]
  refine
    { wf := hwf
      fixed := fun j => ?_
      slot := fun j => ?_
      live := fun j => ?_
      disk := fun j => stateOk_extends ext _ (hi.disk j)
      consistent_disk := fun j => by rw [hdk, fld]; exact consistent_extends ext _ (hi.consistent_disk j)
      consistent_live := fun j => ?_
      clean := fun j => ?_
      terms := fun j => ?_
      acks := fun w t j h => ?_
      ballots := fun T w c v h => ?_
      ballot_unique := hbu
      elect := fun T c eL h hd => ?_
      elect_cand := fun T c eL h => ?_
      leader := fun j => ?_
      candidate := fun j => ?_
      outbox := fun j j' o => ?_
      outbox_self := fun j => ?_
      sent := fun env h => ?_
      committed := fun j => ?_
      ballot_cand := fun T w c v h => ?_ }
  · by_cases hj : j = k
    · subst hj; rw [setLive_self]; exact hl.fixed
    · rw [setLive_other C k j n hj]; exact hi.fixed j
  · by_cases hj : j = k
    · subst hj; rw [setLive_self]; exact hl.slot
    · rw [setLive_other C k j n hj]; exact hi.slot j
  · by_cases hj : j = k
    · subst hj; rw [setLive_self]; exact hl.live
    · rw [setLive_other C k j n hj]; exact stateOk_extends ext _ (hi.live j)
  · by_cases hj : j = k
    · subst hj; rw [setLive_self]; exact hl.consistent
    · rw [setLive_other C k j n hj, flv]; intro hr; exact consistent_extends ext _ (hi.consistent_live j hr)
  · by_cases hj : j = k
    · subst hj; rw [setLive_self]; exact hl.clean
    · rw [setLive_other C k j n hj]; exact hi.clean j
  · by_cases hj : j = k
    · subst hj; rw [setLive_self]; exact hl.terms
    · rw [setLive_other C k j n hj]; exact hi.terms j
  · rw [gacks] at h
    obtain ⟨a, b, c⟩ := hi.acks w t j h
    refine ⟨ackok t j a, b, fun j' hj' => ⟨?_, ?_⟩⟩
    · by_cases hw : w = k
      · subst hw; rw [setLive_self]; exact hl.acks t j (by rw [gacks]; exact h) j' hj'
      · rw [setLive_other C k w n hw, flv]
        obtain ⟨L, h1, h2⟩ := a
        exact kept_extends ext _ _ _ _ _ (c j' hj').1 ⟨L, h1, by omega⟩
    · rw [hdk, fld]
      obtain ⟨L, h1, h2⟩ := a
      exact kept_extends ext _ _ _ _ _ (c j' hj').2 ⟨L, h1, by omega⟩
  · by_cases hb : (T, w, c, v) ∈ G.ballots
    · obtain ⟨a, a', b, d⟩ := hi.ballots T w c v hb
      refine ⟨?_, a', b, ?_⟩
      · rcases a with a | ⟨h1, h2, h3⟩
        · exact Or.inl a
        · exact Or.inr ⟨h1, h2, ge _ _ h3⟩
      · by_cases hw : w = k
        · subst hw; rw [setLive_self]; exact hl.ballots T _ v h
        · rw [setLive_other C k w n hw]; exact d
    · obtain ⟨rfl, rfl, h1, h2⟩ := gnb T w c v h hb
      refine ⟨Or.inl h1, fun e => absurd rfl e, h2, ?_⟩
      rw [setLive_self]; exact hl.ballots T _ v h
  · by_cases hc : c = k
    · subst hc; rw [setLive_self]; intro hr ht; exact hl.ballot_cand hr T w v h ht
    · rw [setLive_other C k c n hc, flv]; intro hr ht
      by_cases hb : (T, w, c, v) ∈ G.ballots
      · exact hi.ballot_cand T w c v hb hr ht
      · exact absurd (gnb T w c v h hb).2.1 hc
  · rcases eold T c eL h with h' | ⟨rfl, h2, -⟩
    · obtain ⟨a, b, c', d⟩ := hi.elect T c eL h' hd
      refine ⟨gl _ _ a, by rw [hdk, fld]; exact b, c', ?_⟩
      by_cases hc : c = k
      · subst hc; rw [setLive_self]; exact hl.elect T eL h hd
      · rw [setLive_other C k c n hc, flv]; exact d
    · exact absurd hd h2
  · by_cases hc : c = k
    · subst hc; rw [setLive_self]; exact hl.elect_cand T eL h
    · rw [setLive_other C k c n hc]
      rcases eold T c eL h with h' | ⟨h1, -⟩
      · exact hi.elect_cand T c eL h'
      · exact absurd h1 hc
  · by_cases hj : j = k
    · subst hj; rw [setLive_self]; exact hl.leader
    · rw [setLive_other C k j n hj]; intro hr
      obtain ⟨⟨eL, he, hp, hb⟩, ⟨L, hL1, hL2, hL3⟩, hmt, hown⟩ := hi.leader j hr
      refine ⟨⟨eL, ?_, ?_, ?_⟩, ⟨L, ?_, ?_, ?_⟩, ?_, ?_⟩ <;>
        simp only [setLive_other C k j n hj, flv, gacks]
      · exact ge _ _ he
      · exact hp
      · exact hb
      · exact gl _ _ hL1
      · exact hL2
      · exact hL3
      · exact hmt
      · exact hown
  · by_cases hj : j = k
    · subst hj; rw [setLive_self]; exact hl.candidate
    · rw [setLive_other C k j n hj]; intro hr
      have := hi.candidate j hr
      unfold CandidateOk at this ⊢
      simp only [setLive_other C k j n hj, flv]
      refine ⟨this.1, this.2.1, fun i hi' => ?_⟩
      rcases this.2.2 i hi' with h | ⟨v, h1, h2⟩
      · exact Or.inl h
      · exact Or.inr ⟨v, gb _ h1, h2⟩
  · by_cases hj : j = k
    · subst hj; rw [setLive_self]; exact hl.outbox j' o
    · rw [setLive_other C k j n hj]; intro ho
      have := hi.outbox j j' o ho
      unfold OutOk at this ⊢
      simp only [setLive_other C k j n hj, flv]
      revert this
      cases o with
      | Replicated i r =>
        intro h1 hr
        obtain ⟨h2, h3⟩ := h1 hr
        obtain ⟨L, hL, hle⟩ := h3
        refine ⟨?_, ackok _ _ ⟨L, hL, hle⟩⟩
        rw [prefix_extends ext _ _ L hL hle]; exact h2
      | _ => intro h1; exact h1
  · by_cases hj : j = k
    · subst hj; rw [setLive_self]; exact hl.outbox_self
    · rw [setLive_other C k j n hj]; exact hi.outbox_self j
  · have := hi.sent env h
    unfold SentOk at this ⊢
    refine ⟨this.1, ?_⟩
    have h2 := this.2
    revert h2
    cases hm : env.message with
    | Vote T last =>
      intro h2 c hc
      obtain ⟨a, b, d⟩ := h2 c hc
      refine ⟨a, ?_, fun eL he => ?_⟩
      · by_cases hck : c = k
        · subst hck; rw [setLive_self]; exact hl.votes env h T last hc hm
        · rw [setLive_other C k c n hck]; exact b
      · cases hg : G.elect T.val with
        | none =>
          have := (gne _ _ he hg).1; simp only at this; subst this
          exact hvote env h T last hc hm eL he hg
        | some x =>
          have h3 := ge _ _ hg; rw [he] at h3; rw [← Option.some.inj h3] at hg; exact d eL hg
    | Voted T g =>
      intro h2 hg w c hw hc
      rcases h2 hg w c hw hc with ⟨v, hv⟩ | ⟨eL, he⟩
      · exact Or.inl ⟨v, gb _ hv⟩
      · exact Or.inr ⟨eL, ge _ _ he⟩
    | Replicated T j r =>
      intro h2 hr w hw; rw [gacks]; exact h2 hr w hw
    | Append T prev entry commit =>
      intro h2
      obtain ⟨L, hL, h3, h4, h5, h6, h7, h8⟩ := h2
      refine ⟨L, gl _ _ hL, h3, h4, h5, h6, committed_mono ext _ h7, fun c eL he => ?_⟩
      cases hg : G.elect T.val with
      | none => have := (gne _ _ he hg).2.2; rw [this] at hL; cases hL
      | some x =>
        have h9 := ge _ _ hg; rw [he] at h9; rw [← Option.some.inj h9] at hg; exact h8 c eL hg
    | Install T snap =>
      intro h2
      obtain ⟨L, hL, h3, h4, h5, h6, h8⟩ := h2
      refine ⟨L, gl _ _ hL, h3, h4, h5, committed_mono ext _ h6, fun c eL he => ?_⟩
      cases hg : G.elect T.val with
      | none => have := (gne _ _ he hg).2.2; rw [this] at hL; cases hL
      | some x =>
        have h9 := ge _ _ hg; rw [he] at h9; rw [← Option.some.inj h9] at hg; exact h8 c eL hg
    | _ => intro h2; exact h2
  · refine ⟨by rw [hdk, fld]; exact committed_mono ext _ (hi.committed j).1, ?_⟩
    by_cases hj : j = k
    · subst hj; rw [setLive_self]; exact hl.committed
    · rw [setLive_other C k j n hj]; exact commitOk_extends ext j _ (hi.live j) (hi.committed j).2


/-- What `become_leader` does to a candidate with at least two slots. -/
theorem win_node (ids : Vector Id N) (G : Ghost V N) (nv n' : Node V S N CAP) (k : Fin N)
    (hF : Fixed ids nv) (hloc : nv.local.val = k.val) (_hd : nv.dirty = false)
    (hob : ∀ j : Fin N, nv.outbox[j] = none) (hsl : StateOk G nv.state) (hN : ¬ N / 2 < 1)
    (hB : BecomeLeader nv n') :
    Fixed ids n' ∧ n'.config = nv.config ∧ n'.local = nv.local ∧ n'.role = .Leader ∧
    n'.state.hard = nv.state.hard ∧ StateOk G n'.state ∧
    (∃ l, fullLog G n'.state = fullLog G nv.state ++ l ∧ ∀ e ∈ l, e.id.term = nv.state.hard.term) ∧
    (n'.dirty = false → n'.state = nv.state) ∧
    (n'.matched[k]).val ≤ (fullLog G n'.state).length ∧
    (∀ j : Fin N, j ≠ k → (n'.matched[j]).val = 0) ∧
    (∀ j : Fin N, ∀ o, n'.outbox[j] = some o → j ≠ k ∧ o = .Replicate) ∧ n'.outbox[k] = none := by
  obtain ⟨h, n2, hb, rfl⟩ := hB
  have hFi : Fixed ids (leaderInit nv h) := fixed_leaderInit ids nv hF
  have hF2 := fixed_barrier ids _ n2 hFi hb
  have hlen0 := fullLog_length G _ hsl
  have hn2 : n2.config = nv.config ∧ n2.local = nv.local ∧ n2.role = .Leader ∧ n2.state.hard = nv.state.hard ∧
      n2.outbox = nv.outbox ∧ StateOk G n2.state ∧
      (∃ l, fullLog G n2.state = fullLog G nv.state ++ l ∧ ∀ e ∈ l, e.id.term = nv.state.hard.term) ∧
      (n2.dirty = false → n2.state = nv.state) ∧
      (n2.matched[k]).val ≤ (fullLog G n2.state).length ∧ (∀ j : Fin N, j ≠ k → (n2.matched[j]).val = 0) := by
    rcases hb with rfl | ⟨s', idx, h', hidx, -, hr, hh, hsn, hl', hc', hA⟩
    · refine ⟨rfl, rfl, rfl, rfl, rfl, hsl, ⟨[], by rw [List.append_nil]; rfl, by simp⟩, fun _ => rfl, ?_, ?_⟩
      · simp only [leaderInit, Fin.getElem_fin, Vector.getElem_set, hloc, if_true]
        rw [hlen0]; exact Nat.le_refl _
      · intro j hj
        simp only [leaderInit, Rust.Slice.fill, Fin.getElem_fin, Vector.getElem_set, Vector.getElem_replicate]
        rw [if_neg (fun e => hj (Fin.ext (by rw [← e, hloc])))]; rfl
    · have hli : (leaderInit nv h).state = nv.state := rfl
      rw [hli] at hidx hr hh hsn
      have hA' : n2 = ownAppend (leaderInit nv h) s' idx h' := by
        rcases adv_cases _ _ hA with e | ⟨v, hmaj, hlt, -, -⟩
        · exact e
        · exfalso; apply hN
          refine majority_only (fun j => decide (v.val ≤ ((ownAppend (leaderInit nv h) s' idx h').matched[j]).val) = true) k
            (fun j hj => ?_) (majority_of_countP _ _ (fun j => Iff.rfl) hmaj)
          apply Classical.byContradiction; intro hjk
          simp only [ownAppend, leaderInit, Rust.Slice.fill, Fin.getElem_fin, Vector.getElem_set,
            Vector.getElem_replicate, decide_eq_true_eq] at hj
          rw [if_neg (fun e => hjk (Fin.ext (by rw [← e, hloc]))),
            if_neg (fun e => hjk (Fin.ext (by rw [← e, hloc])))] at hj
          rw [Fin.lt_def] at hlt
          have : ((ownAppend (leaderInit nv h) s' idx h').state.hard.commit).val = nv.state.hard.commit.val := by
            simp [ownAppend, hh]
          have h0 : ((0 : Rust.u64)).val = 0 := rfl
          omega
      subst hA'
      have hb' : s'.base = nv.state.base := base_of_snapshot _ _ hsn
      have hfl' := fullLog_append G nv.state s' _ hsn hr
      have hlast : (lastId s').index.val = (lastId nv.state).index.val + 1 := by
        rw [lastId_eq s' hc', lastId_eq nv.state hsl.contig, hr, hb']; simp; omega
      have hst : StateOk G s' := by
        refine ⟨hl', hc', ?_, ?_, ?_, ?_, ?_, ?_⟩
        · intro hpos; rw [hb'] at hpos ⊢; exact hsl.base hpos
        · intro hs; rw [hb']; exact hsl.snapshot (by rw [← hsn]; exact hs)
        · intro e he
          rw [hfl', List.mem_append] at he
          rw [hh]
          rcases he with he | he
          · exact hsl.terms e he
          · simp only [List.mem_singleton] at he; subst he; exact Nat.le_refl _
        · rw [hh, hb']; exact hsl.commit_ge
        · rw [hh, hlast]; have := hsl.commit_le; omega
        · rw [hh]; exact hsl.unvoted
      refine ⟨rfl, rfl, rfl, hh, rfl, hst, ⟨_, hfl', ?_⟩, fun e => absurd e (by simp [ownAppend]), ?_, ?_⟩
      · intro e he; simp only [List.mem_singleton] at he; subst he; rfl
      · simp only [ownAppend, Fin.getElem_fin, Vector.getElem_set, leaderInit, hloc, if_true]
        rw [fullLog_length G _ hst, hlast, hidx]; exact Nat.le_refl _
      · intro j hj
        simp only [ownAppend, leaderInit, Rust.Slice.fill, Fin.getElem_fin, Vector.getElem_set,
          Vector.getElem_replicate]
        rw [if_neg (fun e => hj (Fin.ext (by rw [← e, hloc]))), if_neg (fun e => hj (Fin.ext (by rw [← e, hloc])))]
        rfl
  obtain ⟨hc2, hl2, hr2, hh2, ho2, hs2, hlog2, hd2, hmk, hmj⟩ := hn2
  refine ⟨{ hF2 with layout := hF2.layout, contig := hF2.contig }, hc2, hl2, hr2, hh2, hs2, hlog2, hd2, hmk, hmj,
    ?_, ?_⟩
  · intro j o ho
    simp only [bcast, Fin.getElem_fin, Vector.getElem_ofFn] at ho
    split at ho
    · rename_i hj
      refine ⟨fun e => hj (by rw [e, hl2, hloc]), (Option.some.inj ho).symm⟩
    · have := hob j; rw [← ho2] at this; simp only [Fin.getElem_fin] at this; rw [this] at ho; cases ho
  · simp only [bcast, Fin.getElem_fin, Vector.getElem_ofFn]
    rw [if_neg (by rw [hl2, hloc]; exact fun e => e rfl)]
    have := hob k; rw [← ho2] at this; simpa using this


/-- The history once candidate `k` wins term `T` with log `eL`. -/
def winGhost (G : Ghost V N) (T : Nat) (k : Fin N) (eL : List (Entry V)) : Ghost V N :=
  { leader := fun x => if x = T then some eL else G.leader x,
    elect := fun x => if x = T then some (k, eL) else G.elect x,
    acks := G.acks,
    ballots := (T, k, k, eL) :: G.ballots }

theorem case_win (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (a k : Fin N) (hak : a ≠ k) (src : Id) (t : Rust.u64) (ht0 : t.val ≠ 0)
    (n1 nv n' : Node V S N CAP) (hI : Idle (C.live k)) (hO : Observed (C.live k) src t n1)
    (hT : n1.state.hard.term = t) (hcand : n1.role = .Candidate)
    (hnv : nv = { n1 with votes := n1.votes.set a.val true a.isLt })
    (hq : N / 2 < (List.finRange N).countP (fun j => nv.votes[j])) (hB : BecomeLeader nv n')
    (hup : ∃ vlog, ((C.live k).state.hard.term.val, a, k, vlog) ∈ G.ballots ∧
      upToDate (lastOf (fullLog G (C.live k).state)) (lastOf vlog)) :
    ∃ G', Extends G G' ∧ Inv ids cfg (C.setLive k n') G' := by
  have hF1 := fixed_observed ids _ _ (hi.fixed k).1 src _ hO
  obtain ⟨hc1, hl1, hv1, hm1, hob1, -, hA⟩ := observed_facts _ _ src _ hO
  have hA1 : n1.state = (C.live k).state ∧ n1.role = (C.live k).role ∧ n1.dirty = (C.live k).dirty := by
    rcases hA with ⟨-, h, h', h''⟩ | ⟨-, -, h, -⟩
    · exact ⟨h, h', h''⟩
    · rw [h] at hcand; cases hcand
  obtain ⟨hs1, hr1, hd1⟩ := hA1
  have hcand0 : (C.live k).role = .Candidate := hr1 ▸ hcand
  have hc0 := hi.candidate k hcand0
  have hsl := hi.live k
  have hd0 := hI.1
  have hdisk : C.disk k = (C.live k).state := (hi.clean k hd0).symm
  have hT0 : (C.live k).state.hard.term = t := by rw [← hs1]; exact hT
  have hN : ¬ N / 2 < 1 := fun h => hak (Fin.ext (by have := a.isLt; have := k.isLt; omega))
  have hnd := (hi.fixed k).1.nodup
  have hcons : Consistent G (fullLog G (C.live k).state) := idle_consistent ids cfg C G hi k hd0
  have hvm : Majority N (fun j => nv.votes[j] = true) := majority_of_countP _ _ (fun j => Iff.rfl) hq
  have hvc : ∀ j, nv.votes[j] = true → j = a ∨ j = k ∨ ∃ vlog,
      ((C.live k).state.hard.term.val, j, k, vlog) ∈ G.ballots ∧
        upToDate (lastOf (fullLog G (C.live k).state)) (lastOf vlog) := by
    intro j hj
    rw [hnv] at hj
    simp only [Fin.getElem_fin, Vector.getElem_set] at hj
    split at hj
    · rename_i hja; exact Or.inl (Fin.ext hja.symm)
    · right
      rw [hv1] at hj
      exact hc0.2.2 j (by simpa using hj)
  -- election safety: nobody else won the term
  have hnone : G.elect (C.live k).state.hard.term.val = none := by
    cases he : G.elect (C.live k).state.hard.term.val with
    | none => rfl
    | some x =>
      obtain ⟨c, eL'⟩ := x
      exfalso
      by_cases hck : c = k
      · rw [hck] at he; exact hi.elect_cand _ k eL' he ⟨hcand0, rfl⟩
      · obtain ⟨-, -, -, hmaj⟩ := hi.wf.elect _ c eL' he
        obtain ⟨w, ⟨v, hb, -⟩, hw⟩ := majority_inter _ _ hmaj hvm
        rcases hvc w hw with h | h | ⟨v', hb', -⟩
        · rw [h] at hb
          obtain ⟨v', hb', -⟩ := hup
          exact hck (hi.ballot_unique _ _ _ _ _ _ hb hb')
        · rw [h] at hb
          have := (hi.ballots _ k c v hb).2.2.2 rfl
          rw [hc0.1] at this
          exact hck (ids_inj ids hnd _ _ (Option.some.inj this)).symm
        · exact hck (hi.ballot_unique _ _ _ _ _ _ hb hb')
  have hlnone : G.leader (C.live k).state.hard.term.val = none := by
    cases hl : G.leader (C.live k).state.hard.term.val with
    | none => rfl
    | some L =>
      obtain ⟨-, -, c, eL', he, -⟩ := hi.wf.leader _ L hl
      rw [hnone] at he; cases he
  generalize hTe : (C.live k).state.hard.term.val = T at hnone hlnone hup hvc
  generalize hLe : fullLog G (C.live k).state = eL at hup hvc hcons
  have gl : ∀ x L, G.leader x = some L → (winGhost G T k eL).leader x = some L := by
    intro x L h
    simp only [winGhost]
    rw [if_neg (fun e => by rw [e, hlnone] at h; cases h)]; exact h
  have ge : ∀ x y, G.elect x = some y → (winGhost G T k eL).elect x = some y := by
    intro x y h
    simp only [winGhost]
    rw [if_neg (fun e => by rw [e, hnone] at h; cases h)]; exact h
  have gb : ∀ b ∈ G.ballots, b ∈ (winGhost G T k eL).ballots := fun b h => List.mem_cons_of_mem _ h
  have ext : Extends G (winGhost G T k eL) := ⟨fun t L h => ⟨L, gl t L h, List.prefix_refl L⟩, ge,
    fun x h => h, gb⟩
  have hTv : t.val = T := by rw [← hTe, hT0]
  have hnvs : nv.state = (C.live k).state := by rw [hnv]; exact hs1
  have hterms : ∀ e ∈ eL, 0 < e.id.term.val ∧ e.id.term.val ≤ T := by
    intro e he
    refine ⟨(consistent_terms G hi.wf eL hcons e he).1, ?_⟩
    have := hc0.2.1 e (by rw [hLe]; exact he); omega
  -- the new history is well formed
  have hwf : Wf (winGhost G T k eL) := by
    refine ⟨fun x L h => ?_, fun x c eL' h => ?_, fun x w c v h => ?_⟩
    · by_cases hx : x = T
      · subst hx
        simp only [winGhost, if_true, Option.some.injEq] at h
        subst h
        refine ⟨consistent_extends ext _ hcons, hterms, k, eL, by simp [winGhost], List.prefix_refl eL,
          fun i hi1 hi2 => absurd hi1 (by omega)⟩
      · simp only [winGhost, if_neg hx] at h
        obtain ⟨h1, h2, c, eL', he, hp, hb⟩ := hi.wf.leader x L h
        exact ⟨consistent_extends ext L h1, h2, c, eL', ge x _ he, hp, hb⟩
    · by_cases hx : x = T
      · subst hx
        simp only [winGhost, if_true, Option.some.injEq, Prod.mk.injEq] at h
        obtain ⟨rfl, rfl⟩ := h
        refine ⟨by omega, consistent_extends ext _ hcons, fun e he => ?_, ?_⟩
        · have := hc0.2.1 e (by rw [hLe]; exact he); omega
        · refine majority_mono _ _ (fun w hw => ?_) hvm
          rcases hvc w hw with h | h | ⟨v, hb, hu⟩
          · rw [h]; obtain ⟨v, hb, hu⟩ := hup; exact ⟨v, gb _ hb, hu⟩
          · rw [h]; exact ⟨eL, List.mem_cons_self, Or.inr ⟨rfl, Nat.le_refl _⟩⟩
          · exact ⟨v, gb _ hb, hu⟩
      · simp only [winGhost, if_neg hx] at h
        obtain ⟨h0, h1, h2, h3⟩ := hi.wf.elect x c eL' h
        exact ⟨h0, consistent_extends ext _ h1, h2,
          majority_mono _ _ (fun w ⟨v, hb, hu⟩ => ⟨v, gb _ hb, hu⟩) h3⟩
    · simp only [winGhost, List.mem_cons] at h
      rcases h with h | h
      · simp only [Prod.mk.injEq] at h
        obtain ⟨h1, h2, h3, h4⟩ := h
        rw [h1, h2, h4]
        refine ⟨consistent_extends ext _ hcons, fun t'' j' ha hlt j hj => Or.inl ?_⟩
        obtain ⟨hack, -, hkept⟩ := hi.acks k t'' j' ha
        have hk := (hkept j hj).1
        rw [hLe, hTe] at hk
        obtain ⟨L, hL1, hL2⟩ := hack
        refine kept_extends ext _ _ _ _ _ ?_ ⟨L, hL1, by omega⟩
        rcases hk with hk | ⟨t3, h1, h2, c, eL', he, hc, hn⟩
        · exact Or.inl hk
        · refine Or.inr ⟨t3, h1, ?_, c, eL', he, hc, hn⟩
          apply Classical.byContradiction; intro h3
          have : t3 = T := by omega
          rw [this, hnone] at he; cases he
      · obtain ⟨h1, h2⟩ := hi.wf.ballot x w c v h
        refine ⟨consistent_extends ext _ h1, fun t'' j' ha hlt j hj => ?_⟩
        obtain ⟨⟨L, hL1, hL2⟩, -, -⟩ := hi.acks w t'' j' ha
        rcases h2 t'' j' ha hlt j hj with hk | ⟨c', eL', he, hc⟩
        · exact Or.inl (kept_extends ext _ _ _ _ _ hk ⟨L, hL1, by omega⟩)
        · exact Or.inr ⟨c', eL', ge _ _ he, hc⟩
  have hvf0 : (C.live k).state.hard.voted_for = some ids[k] := hc0.1
  -- the new ballot is `k`'s own
  have hnew : ∀ x w c v, (x, w, c, v) ∈ (winGhost G T k eL).ballots → (x, w, c, v) ∉ G.ballots →
      x = T ∧ w = k ∧ c = k := by
    intro x w c v h hn
    simp only [winGhost, List.mem_cons] at h
    rcases h with h | h
    · simp only [Prod.mk.injEq] at h; exact ⟨h.1, h.2.1, h.2.2.1⟩
    · exact absurd h hn
  have hold : ∀ c v, (T, k, c, v) ∈ G.ballots → c = k := by
    intro c v hb
    have := (hi.ballots T k c v hb).2.2.2 hTe
    rw [hvf0] at this
    exact (ids_inj ids hnd _ _ (Option.some.inj this)).symm
  have hbu : ∀ x w c c' v v', (x, w, c, v) ∈ (winGhost G T k eL).ballots →
      (x, w, c', v') ∈ (winGhost G T k eL).ballots → c = c' := by
    intro x w c c' v v' h h'
    by_cases hb : (x, w, c, v) ∈ G.ballots
    · by_cases hb' : (x, w, c', v') ∈ G.ballots
      · exact hi.ballot_unique _ _ _ _ _ _ hb hb'
      · obtain ⟨hx, hw, hc⟩ := hnew _ _ _ _ h' hb'
        rw [hx, hw] at hb; rw [hc]; exact hold c v hb
    · obtain ⟨hx, hw, hc⟩ := hnew _ _ _ _ h hb
      rw [hc]
      by_cases hb' : (x, w, c', v') ∈ G.ballots
      · rw [hx, hw] at hb'; exact (hold c' v' hb').symm
      · exact (hnew _ _ _ _ h' hb').2.2.symm
  have gne : ∀ x y, (winGhost G T k eL).elect x = some y → G.elect x = none →
      y.1 = k ∧ ¬ (C.disk k).hard.term.val < x ∧ G.leader x = none := by
    intro x y h hn
    simp only [winGhost] at h
    split at h
    · rename_i hx
      rw [← Option.some.inj h, hdisk, hTe, hx]
      exact ⟨rfl, by omega, hlnone⟩
    · rw [hn] at h; cases h
  have hvote : ∀ env ∈ C.sent, ∀ T' last, env.from = ids[k] → env.message = .Vote T' last →
      ∀ eL', (winGhost G T k eL).elect T'.val = some (k, eL') → G.elect T'.val = none → lastOf eL' = last := by
    intro env hm T' last hf hmsg eL' he hn
    simp only [winGhost] at he
    split at he
    · rename_i hx
      simp only [Option.some.injEq, Prod.mk.injEq] at he
      rw [← he.2, ← hLe, lastOf_fullLog G _ hsl]
      exact (sent_vote ids cfg C G hi env hm T' last hmsg k hf).2.1 ⟨hcand0, Fin.ext (by rw [hTe, hx])⟩
    · rw [hn] at he; cases he
  -- the new leader
  have hFv : Fixed ids nv := by rw [hnv]; exact { hF1 with layout := hF1.layout, contig := hF1.contig }
  obtain ⟨hF', hcf, hlo, hro, hhd, hst', ⟨l, hfl, hlt⟩, hdc, hmk, hmj, hox, hok⟩ :=
    win_node ids G nv n' k hFv (by rw [hnv]; show n1.local.val = _; rw [hl1]; exact hi.slot k)
      (by rw [hnv]; show n1.dirty = _; rw [hd1]; exact hd0)
      (fun j => by rw [hnv]; show n1.outbox[j] = _; rw [hob1]; exact hI.2.2 j) (by rw [hnvs]; exact hsl) hN hB
  rw [hnvs] at hhd hfl hlt hdc
  rw [hLe] at hfl
  have hcfg : nv.config = (C.live k).config := by rw [hnv]; exact hc1
  have hlocal : nv.local = (C.live k).local := by rw [hnv]; exact hl1
  have hfl' : fullLog (winGhost G T k eL) n'.state = eL ++ l := by rw [fullLog_extends ext _ hst', hfl]
  have hnt : n'.state.hard.term.val = T := by rw [hhd, hTe]
  have hl : LocalOk ids cfg C (winGhost G T k eL) k n' := by
    refine ⟨⟨hF', by rw [hcf, hcfg]; exact (hi.fixed k).2⟩, by rw [hlo, hlocal]; exact hi.slot k,
      stateOk_extends ext _ hst', fun hd => by rw [hdc hd, hdisk], by rw [hhd]; exact hi.terms k,
      fun hr => absurd hro hr, ?_, ?_, ?_, fun hr => (by rw [hro] at hr; cases hr), ?_, ?_, ?_, ?_, hok, ?_, ?_⟩
    · intro t' j hj j' hj'
      obtain ⟨⟨L, hL1, hL2⟩, -, hk⟩ := hi.acks k t' j hj
      have hk1 := (hk j' hj').1
      rw [hLe, hTe] at hk1
      rw [hfl', hnt]
      exact kept_extends ext _ _ _ _ _ (kept_of_prefix G k t' j' _ _ _ (List.prefix_append eL l) hk1)
        ⟨L, hL1, by omega⟩
    · intro x eL' he hlt1 hlt2
      simp only [winGhost] at he
      split at he
      · rename_i hx; rw [hdisk, hTe, hx] at hlt1; omega
      · exact absurd hlt1 (no_early_elect ids cfg C G hi a k hak x eL' he)
    · intro x c v hb ht
      rw [hhd, hvf0]
      by_cases hb' : (x, k, c, v) ∈ G.ballots
      · have := (hi.ballots x k c v hb').2.2.2 (by rw [← ht, hhd])
        rw [hvf0] at this; exact this
      · obtain ⟨-, -, rfl⟩ := hnew _ _ _ _ hb hb'; rfl
    · intro x eL' _ ⟨hr, _⟩; rw [hro] at hr; cases hr
    · intro _
      refine ⟨⟨eL, ?_, ?_, ?_⟩, ⟨eL, ?_, ?_, ?_⟩, ?_, ?_⟩ <;> simp only [setLive_self]
      · rw [hnt]; simp [winGhost]
      · rw [hfl']; exact List.prefix_append eL l
      · intro i hi1 hi2
        simp only [hfl'] at hi1 ⊢
        rw [List.getElem_append_right hi2]
        rw [hhd, hT0]; rw [← hT0]
        exact hlt _ (List.getElem_mem _)
      · rw [hnt]; simp [winGhost]
      · rw [hfl']; exact List.prefix_append eL l
      · intro hd; rw [hdc hd, fullLog_extends ext _ hsl, hLe]
      · intro j hj hpos; rw [hmj j hj] at hpos; omega
      · rw [fullLog_extends ext _ hst']; exact hmk
    · intro hr; rw [hro] at hr; cases hr
    · intro j o h
      obtain ⟨-, rfl⟩ := hox j o h
      simp only [OutOk, setLive_self]; exact hro
    · intro env _ x last _ _ ⟨hr, _⟩; rw [hro] at hr; cases hr
    · left
      have hc := (hi.committed k).2
      rcases hc with hc | ⟨-, hc, -⟩
      · rw [hfl', hhd]
        have hlen : (C.live k).state.hard.commit.val ≤ eL.length := by
          rw [← hLe, fullLog_length G _ hsl]; exact hsl.commit_le
        rw [List.take_append_of_le_length hlen]
        rw [hLe] at hc
        exact committed_mono ext _ hc
      · rw [hd0] at hc; cases hc
  refine ⟨winGhost G T k eL, ext, setLive_grow ids cfg C G _ hi k n' gl ge rfl gb ?_ gne hwf hbu hvote hl⟩
  intro x w c v h hn
  obtain ⟨hx, hw, hc⟩ := hnew _ _ _ _ h hn
  refine ⟨hw, hc, by rw [hdisk, hTe, hx]; exact Nat.le_refl _, fun _ => by rw [hdisk]; exact hvf0⟩



theorem sent_append (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (env : Envelope V S) (hm : env ∈ C.sent) (T : Rust.u64) (prev : LogId)
    (entry : Option (Entry V)) (commit : Rust.u64) (hmsg : env.message = .Append T prev entry commit) :
    ∃ L, G.leader T.val = some L ∧
      (0 < prev.index.val → ∃ h : prev.index.val - 1 < L.length, L[prev.index.val - 1].id = prev) ∧
      (prev.index.val = 0 → prev = LogId.default) ∧
      (∀ e, entry = some e → ∃ h : e.id.index.val - 1 < L.length, L[e.id.index.val - 1] = e ∧
        e.id.index.val = prev.index.val + 1) ∧
      commit.val ≤ L.length ∧ Committed G (L.take commit.val) ∧
      ∀ c eL, G.elect T.val = some (c, eL) → env.from = ids[c] := by
  have h := (hi.sent env hm).2
  rw [hmsg] at h
  exact h

theorem sent_install (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (env : Envelope V S) (hm : env ∈ C.sent) (T : Rust.u64) (snap : Snapshot S)
    (hmsg : env.message = .Install T snap) :
    ∃ L, G.leader T.val = some L ∧ 0 < snap.last.index.val ∧
      ∃ h : snap.last.index.val - 1 < L.length, L[snap.last.index.val - 1].id = snap.last ∧
      Committed G (L.take snap.last.index.val) ∧
      ∀ c eL, G.elect T.val = some (c, eL) → env.from = ids[c] := by
  have h := (hi.sent env hm).2
  rw [hmsg] at h
  exact h

theorem stateOk_hard (G : Ghost V N) (s : State V S CAP) (hs : StateOk G s) (h : HardState)
    (ht : s.hard.term.val ≤ h.term.val) (hc1 : s.hard.commit.val ≤ h.commit.val)
    (hc2 : h.commit.val ≤ (lastId s).index.val) (hu : h.term.val = 0 → h.voted_for = none) :
    StateOk G { s with hard := h } :=
  ⟨hs.layout, hs.contig, hs.base, hs.snapshot, fun e he => Nat.le_trans (hs.terms e he) ht,
    Nat.le_trans hs.commit_ge hc1, hc2, hu⟩

theorem commitTo_cases (n : Node V S N CAP) (i : Rust.u64) : commitTo n i = n ∨
    (n.state.hard.commit < i ∧
      commitTo n i = { n with state := { n.state with hard := { n.state.hard with commit := i } }, dirty := true }) := by
  unfold commitTo; split
  · rename_i h; exact Or.inr ⟨h, rfl⟩
  · exact Or.inl rfl

theorem committed_prefix (G : Ghost V N) (p q : List (Entry V)) (h : Committed G p) (hq : q <+: p) :
    Committed G q := by
  rcases h with rfl | ⟨t, j, hc, hp⟩
  · left; exact List.eq_nil_of_prefix_nil hq
  · right; exact ⟨t, j, hc, hq.trans hp⟩

theorem match_take (G : Ghost V N) (s : State V S CAP) (hs : StateOk G s) (hc : Consistent G (fullLog G s))
    (L : List (Entry V)) (hL : Consistent G L) (idx : Nat) (id : LogId) (hid : idAt s idx = some id)
    (hL' : 0 < idx → ∃ h : idx - 1 < L.length, L[idx - 1].id = id) :
    (fullLog G s).take idx = L.take idx ∧ idx ≤ (fullLog G s).length := by
  by_cases h0 : idx = 0
  · subst h0; simp
  · obtain ⟨-, hl, he⟩ := (idAt_fullLog G s hs idx (by omega) id).mp hid
    obtain ⟨hl', he'⟩ := hL' (by omega)
    have := log_matching G _ L hc hL (idx - 1) hl hl' (by rw [he, he'])
    rw [show idx - 1 + 1 = idx by omega] at this
    exact ⟨this, by omega⟩

/-- An acknowledged prefix survives a replacement by a prefix of the leader log of
    term `t`, or that term's leader (another node) lacks it. -/
theorem kept_replace (G : Ghost V N) (k a : Fin N) (hak : a ≠ k) (t t' j B : Nat) (old l' L eLt : List (Entry V))
    (hL : G.leader t = some L) (he : G.elect t = some (a, eLt)) (hp : eLt <+: L) (ht' : t' ≤ t) (hB : B ≤ t + 1)
    (hk : Kept G k t' j B old) (hrep : ∀ p, p <+: old → p <+: L → p <+: l') : Kept G k t' j (t + 1) l' := by
  rcases hk with hk | ⟨t3, h1, h2, hl⟩
  · by_cases hpl : G.prefix t' j <+: L
    · exact Or.inl (hrep _ hk hpl)
    · refine Or.inr ⟨t, ?_, by omega, a, eLt, he, hak, fun h => hpl (h.trans hp)⟩
      apply Classical.byContradiction; intro h
      have : t' = t := by omega
      subst this
      exact hpl (prefix_le G t' j L hL)
  · exact Or.inr ⟨t3, h1, by omega, hl⟩

/-- An observed node's vote matches `k`'s ballots of its term. -/
theorem ballots_observed (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (a k : Fin N) (hak : a ≠ k) (src : Id) (t : Rust.u64) (n1 : Node V S N CAP)
    (hO : Observed (C.live k) src t n1) :
    ∀ T c vlog, (T, k, c, vlog) ∈ G.ballots → n1.state.hard.term.val = T → n1.state.hard.voted_for = some ids[c] := by
  intro T c v hb ht
  obtain ⟨-, -, -, -, -, -, ⟨-, h, -⟩ | ⟨hlt, h, -⟩⟩ := observed_facts _ _ src _ hO
  · rw [h] at ht ⊢; exact (hi.ballots T k c v hb).2.2.2 ht
  · rw [h] at ht; simp only at ht
    exact absurd (ballot_up ids cfg C G hi a k hak T c v hb (by omega)) id

/-- `LocalOk` for a follower. -/
theorem local_follower (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (a k : Fin N) (hak : a ≠ k) (n : Node V S N CAP)
    (hfix : Fixed ids n ∧ n.config = cfg k) (hslot : n.local.val = k.val) (hlive : StateOk G n.state)
    (hclean : n.dirty = false → n.state = C.disk k) (hterms : (C.disk k).hard.term.val ≤ n.state.hard.term.val)
    (hcons : Consistent G (fullLog G n.state))
    (hacks : ∀ t j, (k, t, j) ∈ G.acks → ∀ j' ≤ j, Kept G k t j' (n.state.hard.term.val + 1) (fullLog G n.state))
    (hballots : ∀ T c vlog, (T, k, c, vlog) ∈ G.ballots → n.state.hard.term.val = T →
      n.state.hard.voted_for = some ids[c])
    (hrole : n.role = .Follower)
    (houtbox : ∀ j o, n.outbox[j] = some o → OutOk ids (C.setLive k n) G k j o)
    (hoself : n.outbox[k] = none) (hcommitted : CommitOk G k n) : LocalOk ids cfg C G k n :=
  ⟨hfix, hslot, hlive, hclean, hterms, fun _ => hcons, hacks,
    fun T eL he hlt _ => absurd hlt (no_early_elect ids cfg C G hi a k hak T eL he), hballots,
    fun hr => (by rw [hrole] at hr; cases hr),
    fun T eL _ ⟨hr, _⟩ => (by rw [hrole] at hr; cases hr), fun hr => (by rw [hrole] at hr; cases hr),
    fun hr => (by rw [hrole] at hr; cases hr), houtbox, hoself,
    fun _ _ _ _ _ _ ⟨hr, _⟩ => (by rw [hrole] at hr; cases hr), hcommitted⟩


/-- What a follower's handling of `Append` or `Install` guarantees about its new state `n3`. -/
structure Post (ids : Vector Id N) (G : Ghost V N) (k : Fin N) (t : Nat) (n2 n3 : Node V S N CAP)
    (r1 : Rust.u64) (r2 : Option Rejection) : Prop where
  fixed : Fixed ids n3
  config : n3.config = n2.config
  loc : n3.local = n2.local
  role : n3.role = n2.role
  outbox : n3.outbox = n2.outbox
  term : n3.state.hard.term = n2.state.hard.term
  vf : n3.state.hard.voted_for = n2.state.hard.voted_for
  live : StateOk G n3.state
  cons : Consistent G (fullLog G n3.state)
  acks : ∀ t' j, (k, t', j) ∈ G.acks → ∀ j' ≤ j, Kept G k t' j' (t + 1) (fullLog G n3.state)
  clean : n3.dirty = false → n3.state = n2.state ∧ n2.dirty = false
  committed : Committed G ((fullLog G n3.state).take n3.state.hard.commit.val)
  reply : r2 = none → G.prefix t r1.val <+: fullLog G n3.state ∧ AckOk G t r1.val

/-- The facts about a follower before it handles `Append` or `Install`. -/
structure Pre (ids : Vector Id N) (C : Cluster V S N CAP) (G : Ghost V N) (k : Fin N) (t : Nat)
    (n2 : Node V S N CAP) : Prop where
  fixed : Fixed ids n2
  live : StateOk G n2.state
  cons : Consistent G (fullLog G n2.state)
  acks : ∀ t' j, (k, t', j) ∈ G.acks → t' ≤ t ∧ ∀ j' ≤ j, Kept G k t' j' (t + 1) (fullLog G n2.state)
  committed : Committed G ((fullLog G n2.state).take n2.state.hard.commit.val)
  term : n2.state.hard.term.val = t

theorem pre_of (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (k : Fin N) (hI : Idle (C.live k)) (src : Id) (t : Rust.u64) (n1 n2 : Node V S N CAP)
    (ht0 : t.val ≠ 0) (hO : Observed (C.live k) src t n1) (hT : n1.state.hard.term = t)
    (hFol : Following n1 src n2) : Pre ids C G k t.val n2 ∧ n2.state = n1.state ∧ n2.dirty = n1.dirty ∧
      n2.config = n1.config ∧ n2.local = n1.local ∧ n2.outbox = n1.outbox ∧ n2.role = .Follower := by
  have hF1 := fixed_observed ids _ _ (hi.fixed k).1 src _ hO
  obtain ⟨hc1, hl1, hv1, hm1, hob1, -, hA⟩ := observed_facts _ _ src _ hO
  have hsl := hi.live k
  have hd0 := hI.1
  have hs1 : n1.state = { (C.live k).state with hard := n1.state.hard } ∧
      (C.live k).state.hard.term.val ≤ t.val ∧ n1.state.hard.commit = (C.live k).state.hard.commit := by
    rcases hA with ⟨-, h, -⟩ | ⟨hlt, h, -⟩
    · rw [h, state_hard_eta (C.live k).state]; exact ⟨rfl, by rw [← h, hT]; exact Nat.le_refl _, rfl⟩
    · rw [h]; exact ⟨rfl, by omega, rfl⟩
  obtain ⟨hs1, hle, hco⟩ := hs1
  obtain ⟨r2, d2, rfl⟩ := hFol
  refine ⟨⟨{ hF1 with layout := hF1.layout, contig := hF1.contig, prevoting := rfl }, ?_, ?_, ?_, ?_, ?_⟩,
    rfl, rfl, rfl, rfl, rfl, rfl⟩
  · show StateOk G n1.state
    rw [hs1]
    exact stateOk_hard G _ hsl _ (by rw [hT]; exact hle) (by rw [hco]; exact Nat.le_refl _)
      (by rw [hco]; exact hsl.commit_le) (fun h => absurd (by rw [hT] at h; exact h) ht0)
  · show Consistent G (fullLog G n1.state)
    rw [hs1]; exact idle_consistent ids cfg C G hi k hd0
  · intro t' j hj
    obtain ⟨-, h1, h2⟩ := hi.acks k t' j hj
    refine ⟨by have := hi.terms k; omega, fun j' hj' => ?_⟩
    show Kept G k t' j' (t.val + 1) (fullLog G n1.state)
    rw [hs1]
    exact kept_mono_bound G k t' j' _ _ _ (by omega) (h2 j' hj').1
  · show Committed G ((fullLog G n1.state).take n1.state.hard.commit.val)
    rw [hs1]
    rcases (hi.committed k).2 with h | ⟨-, h, -⟩
    · simp only [hco]; exact h
    · rw [hd0] at h; cases h
  · show n1.state.hard.term.val = t.val
    rw [hT]

/-- `LocalOk` once a follower has queued its reply. -/
theorem local_reply (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (a k : Fin N) (hak : a ≠ k) (hI : Idle (C.live k)) (src : Id) (t : Rust.u64)
    (n1 n2 n3 : Node V S N CAP) (hO : Observed (C.live k) src t n1) (hT : n1.state.hard.term = t)
    (hn2 : n2.state = n1.state ∧ n2.dirty = n1.dirty ∧ n2.config = n1.config ∧ n2.local = n1.local ∧
      n2.outbox = n1.outbox ∧ n2.role = .Follower)
    (r1 : Rust.u64) (r2 : Option Rejection) (hP : Post ids G k t.val n2 n3 r1 r2) :
    LocalOk ids cfg C G k (queue n3 a (.Replicated r1 r2)) := by
  obtain ⟨hs2, hd2, hc2, hl2, ho2, hr2⟩ := hn2
  obtain ⟨hc1, hl1, -, -, hob1, -, hA⟩ := observed_facts _ _ src _ hO
  have hI' : ∀ j : Fin N, n3.outbox[j] = none := fun j => by rw [hP.outbox, ho2, hob1]; exact hI.2.2 j
  have hnt : n3.state.hard.term = t := by rw [hP.term, hs2, hT]
  refine local_follower ids cfg C G hi a k hak _ ⟨fixed_queue ids _ hP.fixed a _, ?_⟩ ?_ hP.live ?_ ?_ hP.cons ?_ ?_
    (by show n3.role = _; rw [hP.role, hr2]) ?_ (outbox_queue_self k a hak n3 _ hI' _ rfl) (Or.inl hP.committed)
  · show n3.config = _; rw [hP.config, hc2, hc1]; exact (hi.fixed k).2
  · show n3.local.val = _; rw [hP.loc, hl2, hl1]; exact hi.slot k
  · intro hd
    obtain ⟨h1, h2⟩ := hP.clean hd
    show n3.state = _
    rw [h1, hs2]
    rw [hd2] at h2
    rcases hA with ⟨-, h, -, -⟩ | ⟨-, -, -, h⟩
    · rw [h]; exact hi.clean k hI.1
    · rw [h] at h2; cases h2
  · show _ ≤ n3.state.hard.term.val
    rw [hnt]
    rcases hA with ⟨h, h', -⟩ | ⟨h, -⟩
    · have e : (C.live k).state.hard.term.val = t.val := by rw [← h', hT]
      have := hi.terms k; omega
    · have := hi.terms k; omega
  · intro t' j hj j' hj'; show Kept G k t' j' (n3.state.hard.term.val + 1) _; rw [hnt]; exact hP.acks t' j hj j' hj'
  · intro T c v hb ht
    show n3.state.hard.voted_for = _
    rw [hP.vf, hs2]
    exact ballots_observed ids cfg C G hi a k hak src t n1 hO T c v hb (by rw [hT]; rw [← hnt]; exact ht)
  · refine outbox_queue ids _ G k a n3 _ hI' _ rfl ?_
    unfold OutOk
    simp only [setLive_self]
    intro hr
    show G.prefix n3.state.hard.term.val r1.val <+: fullLog G n3.state ∧ AckOk G n3.state.hard.term.val r1.val
    rw [hnt]; exact hP.reply hr


theorem post_same (ids : Vector Id N) (C : Cluster V S N CAP) (G : Ghost V N) (k : Fin N) (t : Nat)
    (n2 : Node V S N CAP) (hP : Pre ids C G k t n2) (r1 : Rust.u64) (r2 : Option Rejection) (hr : r2.isSome) :
    Post ids G k t n2 n2 r1 r2 :=
  ⟨hP.fixed, rfl, rfl, rfl, rfl, rfl, rfl, hP.live, hP.cons, fun t' j h => (hP.acks t' j h).2,
    fun h => ⟨rfl, h⟩, hP.committed, fun h => by rw [h] at hr; cases hr⟩

theorem prefix_take_of (p L : List (Entry V)) (m : Nat) (hp : p <+: L) (hm : p.length ≤ m) : p <+: L.take m := by
  rw [List.prefix_iff_eq_take] at hp
  rw [hp]
  have : List.take p.length L = List.take p.length (L.take m) := by rw [List.take_take, Nat.min_eq_left hm]
  rw [this]; exact List.take_prefix _ _

theorem take_of_take (l L : List (Entry V)) (idx i : Nat) (h : l.take idx = L.take idx) (hi : i ≤ idx) :
    l.take i = L.take i := by
  have h1 : l.take i = (l.take idx).take i := by rw [List.take_take, Nat.min_eq_left hi]
  have h2 : L.take i = (L.take idx).take i := by rw [List.take_take, Nat.min_eq_left hi]
  rw [h1, h2, h]

theorem committed_take (G : Ghost V N) (L : List (Entry V)) (i c : Nat) (h : Committed G (L.take c)) (hi : i ≤ c) :
    Committed G (L.take i) := by
  refine committed_prefix G _ _ h ?_
  have : L.take i = (L.take c).take i := by rw [List.take_take, Nat.min_eq_left hi]
  rw [this]; exact List.take_prefix _ _

theorem post_commit (ids : Vector Id N) (C : Cluster V S N CAP) (G : Ghost V N) (k : Fin N) (t : Nat)
    (n2 : Node V S N CAP) (hP : Pre ids C G k t n2) (L : List (Entry V)) (hL : G.leader t = some L)
    (idx : Nat) (htake : (fullLog G n2.state).take idx = L.take idx) (hidx : idx ≤ (fullLog G n2.state).length)
    (hidxL : idx ≤ L.length) (commit : Nat) (hcomm : Committed G (L.take commit)) (i : Rust.u64)
    (hi1 : i.val ≤ idx) (hi2 : i.val ≤ commit) (r1 : Rust.u64) (r2 : Option Rejection)
    (hr : r2 = none → r1.val = idx) : Post ids G k t n2 (commitTo n2 i) r1 r2 := by
  have hreply : r2 = none → G.prefix t r1.val <+: fullLog G n2.state ∧ AckOk G t r1.val := by
    intro h
    rw [hr h]
    refine ⟨?_, L, hL, hidxL⟩
    have : G.prefix t idx = (fullLog G n2.state).take idx := by simp only [Ghost.prefix, hL, Option.getD_some, htake]
    rw [this]; exact List.take_prefix _ _
  rcases commitTo_cases n2 i with h | ⟨hlt, h⟩ <;> rw [h]
  · exact ⟨hP.fixed, rfl, rfl, rfl, rfl, rfl, rfl, hP.live, hP.cons, fun t' j h => (hP.acks t' j h).2,
      fun h => ⟨rfl, h⟩, hP.committed, hreply⟩
  · have hlen := fullLog_length G _ hP.live
    refine ⟨fixed_hard ids n2 hP.fixed _ true, rfl, rfl, rfl, rfl, rfl, rfl, ?_, hP.cons,
      fun t' j h => (hP.acks t' j h).2, fun h => (by simp at h), ?_, hreply⟩
    · exact stateOk_hard G _ hP.live _ (Nat.le_refl _)
        (by show n2.state.hard.commit.val ≤ i.val; rw [Fin.lt_def] at hlt; omega)
        (by show i.val ≤ _; omega) (hP.live.unvoted)
    · show Committed G ((fullLog G n2.state).take i.val)
      rw [take_of_take _ _ idx _ htake hi1]
      exact committed_take G L _ _ hcomm hi2


theorem post_replace (ids : Vector Id N) (C : Cluster V S N CAP) (G : Ghost V N) (k a : Fin N) (hak : a ≠ k)
    (t : Nat) (n2 : Node V S N CAP) (hP : Pre ids C G k t n2) (L eLt : List (Entry V)) (hL : G.leader t = some L)
    (hLc : Consistent G L) (hLt : ∀ e ∈ L, 0 < e.id.term.val ∧ e.id.term.val ≤ t)
    (he : G.elect t = some (a, eLt)) (hpe : eLt <+: L)
    (prev : LogId) (e : Entry V) (hprev : idAt n2.state prev.index.val = some prev)
    (hprevL : 0 < prev.index.val → ∃ h : prev.index.val - 1 < L.length, L[prev.index.val - 1].id = prev)
    (hel : e.id.index.val - 1 < L.length) (hLe : L[e.id.index.val - 1] = e) (hei : e.id.index.val = prev.index.val + 1)
    (hconf : idAt n2.state e.id.index.val ≠ some e.id) (hlt : n2.state.hard.commit.val < e.id.index.val)
    (s' : State V S CAP) (hrep : Replaced n2 e s') (commit : Rust.u64) (hcomm : Committed G (L.take commit.val))
    (n3 : Node V S N CAP) (hF3 : Fixed ids n3)
    (hn3 : n3 = commitTo (accepted n2 e s') (Rust.min commit e.id.index)) :
    Post ids G k t n2 n3 e.id.index none := by
  obtain ⟨hr', hh', hsn', hl', hc'⟩ := hrep
  have hs2 := hP.live
  have hlen2 := fullLog_length G _ hs2
  have hlast2 := lastId_eq _ hs2.contig
  obtain ⟨hpt, hpl⟩ := match_take G _ hs2 hP.cons L hLc prev.index.val prev hprev hprevL
  have hbase : n2.state.base.index.val < e.id.index.val := by have := hs2.commit_ge; omega
  have hhi : e.id.index.val ≤ (lastId n2.state).index.val + 1 := by omega
  have hfl' := fullLog_replaced G n2.state s' e hs2 hbase hhi hr' hsn'
  have hb' : s'.base = n2.state.base := base_of_snapshot _ _ hsn'
  have hget : L[prev.index.val]? = some e := by
    rw [show prev.index.val = e.id.index.val - 1 by omega, List.getElem?_eq_getElem hel, hLe]
  have hnew : fullLog G s' = L.take e.id.index.val := by
    rw [hfl', show e.id.index.val - 1 = prev.index.val by omega, hpt, hei, List.take_add_one, hget]; rfl
  have hlast' : (lastId s').index.val = e.id.index.val := by
    rw [lastId_eq s' hc', hr', hb']; simp only [List.length_append, List.length_take, List.length_singleton]
    rw [lastId_eq _ hs2.contig] at hhi; omega
  have hst' : StateOk G s' := by
    refine ⟨hl', hc', ?_, ?_, ?_, ?_, ?_, ?_⟩
    · intro hpos; rw [hb'] at hpos ⊢; exact hs2.base hpos
    · intro hs; rw [hb']; exact hs2.snapshot (by rw [← hsn']; exact hs)
    · intro x hx
      rw [hnew] at hx
      rw [hh', hP.term]; exact (hLt x (List.mem_of_mem_take hx)).2
    · rw [hh', hb']; exact hs2.commit_ge
    · rw [hh', hlast']; omega
    · rw [hh']; exact hs2.unvoted
  have hrepl : ∀ p, p <+: fullLog G n2.state → p <+: L → p <+: L.take e.id.index.val := by
    intro p hp1 hp2
    by_cases hpl' : p.length ≤ e.id.index.val
    · exact prefix_take_of p L _ hp2 hpl'
    · exfalso; apply hconf
      have hlt1 : e.id.index.val - 1 < p.length := by omega
      have h1 := hp1.getElem hlt1
      have h2 := hp2.getElem hlt1
      rw [hLe] at h2
      refine (idAt_fullLog G _ hs2 _ (by omega) _).mpr ⟨by omega, by have := hp1.length_le; omega, ?_⟩
      rw [← h1, h2]
  have hacks : ∀ t' j, (k, t', j) ∈ G.acks → ∀ j' ≤ j,
      Kept G k t' j' (t + 1) (L.take e.id.index.val) := by
    intro t' j h j' hj'
    obtain ⟨h1, h2⟩ := hP.acks t' j h
    exact kept_replace G k a hak t t' j' (t + 1) _ _ L eLt hL he hpe h1 (Nat.le_refl _) (h2 j' hj') hrepl
  have hreply : G.prefix t e.id.index.val <+: L.take e.id.index.val ∧ AckOk G t e.id.index.val := by
    refine ⟨by simp only [Ghost.prefix, hL, Option.getD_some]; exact List.prefix_refl _, L, hL, by omega⟩
  rcases commitTo_cases (accepted n2 e s') (Rust.min commit e.id.index) with h | ⟨hlt3, h⟩ <;> rw [h] at hn3 <;>
    subst hn3
  · refine ⟨hF3, rfl, rfl, rfl, rfl, by show s'.hard.term = _; rw [hh'], by show s'.hard.voted_for = _; rw [hh'],
      hst', by show Consistent G (fullLog G s'); rw [hnew]; exact consistent_take G L hLc _,
      by show ∀ t' j, _ → ∀ j' ≤ j, Kept G k t' j' (t + 1) (fullLog G s'); rw [hnew]; exact hacks,
      fun h => (by simp [accepted] at h), ?_, fun _ => by show _ <+: fullLog G s' ∧ _; rw [hnew]; exact hreply⟩
    show Committed G ((fullLog G s').take s'.hard.commit.val)
    have hc2 : n2.state.hard.commit.val ≤ prev.index.val := by omega
    have : (L.take e.id.index.val).take n2.state.hard.commit.val = (fullLog G n2.state).take n2.state.hard.commit.val := by
      rw [List.take_take, Nat.min_eq_left (by omega)]; exact (take_of_take _ _ prev.index.val _ hpt hc2).symm
    rw [hnew, hh', this]; exact hP.committed
  · have hmin : (Rust.min commit e.id.index).val ≤ commit.val ∧ (Rust.min commit e.id.index).val ≤ e.id.index.val := by
      rw [Rust.val_min]; exact ⟨Nat.min_le_left _ _, Nat.min_le_right _ _⟩
    refine ⟨hF3, rfl, rfl, rfl, rfl, by show s'.hard.term = _; rw [hh'], by show s'.hard.voted_for = _; rw [hh'],
      ?_, by show Consistent G (fullLog G s'); rw [hnew]; exact consistent_take G L hLc _,
      by show ∀ t' j, _ → ∀ j' ≤ j, Kept G k t' j' (t + 1) (fullLog G s'); rw [hnew]; exact hacks,
      fun h => (by simp at h), ?_, fun _ => by show _ <+: fullLog G s' ∧ _; rw [hnew]; exact hreply⟩
    · exact stateOk_hard G s' hst' _ (Nat.le_refl _)
        (by show s'.hard.commit.val ≤ (Rust.min commit e.id.index).val; rw [Fin.lt_def] at hlt3; exact Nat.le_of_lt hlt3)
        (by show (Rust.min commit e.id.index).val ≤ _; rw [hlast']; exact hmin.2) hst'.unvoted
    · show Committed G ((fullLog G s').take (Rust.min commit e.id.index).val)
      rw [hnew, List.take_take, Nat.min_eq_left hmin.2]
      exact committed_take G L _ _ hcomm hmin.1



theorem post_keep (ids : Vector Id N) (C : Cluster V S N CAP) (G : Ghost V N) (k : Fin N) (t : Nat)
    (n2 : Node V S N CAP) (hP : Pre ids C G k t n2) (r1 : Rust.u64) (r2 : Option Rejection)
    (hr : r2 = none → G.prefix t r1.val <+: fullLog G n2.state ∧ AckOk G t r1.val) :
    Post ids G k t n2 n2 r1 r2 :=
  ⟨hP.fixed, rfl, rfl, rfl, rfl, rfl, rfl, hP.live, hP.cons, fun t' j h => (hP.acks t' j h).2,
    fun h => ⟨rfl, h⟩, hP.committed, hr⟩

theorem post_install (ids : Vector Id N) (C : Cluster V S N CAP) (G : Ghost V N) (k a : Fin N) (hak : a ≠ k)
    (t : Nat) (n2 : Node V S N CAP) (hP : Pre ids C G k t n2) (L eLt : List (Entry V)) (hL : G.leader t = some L)
    (hLc : Consistent G L) (hLt : ∀ e ∈ L, 0 < e.id.term.val ∧ e.id.term.val ≤ t)
    (he : G.elect t = some (a, eLt)) (hpe : eLt <+: L) (snap : Snapshot S) (hpos : 0 < snap.last.index.val)
    (hsl : snap.last.index.val - 1 < L.length) (hLs : L[snap.last.index.val - 1].id = snap.last)
    (hcomm : Committed G (L.take snap.last.index.val))
    (hc2 : n2.state.base.index.val < snap.last.index.val ∧
      (n2.state.hard.commit.val < snap.last.index.val ∨ idAt n2.state snap.last.index.val = some snap.last))
    (s' : State V S CAP) (hins : State.install n2.state snap = pure s') (lf : Option Rust.u64) :
    Post ids G k t n2 { n2 with state := s', dirty := true, snapshot_changed := true, log_from := lf }
      snap.last.index none := by
  have hs2 := hP.live
  obtain ⟨s'', hins', hsn, hhard, hr, hl'⟩ :=
    install_spec n2.state snap (by have := hP.fixed.cap_lt; omega) hs2.layout hs2.contig
  rw [hins'] at hins
  have e : s'' = s' := pure_inj hins
  subst e
  have hc' := install_contig n2.state s'' snap hs2.layout hs2.contig hsn hr
  have hb' : s''.base = snap.last := base_some s'' snap hsn
  have hlen2 := fullLog_length G _ hs2
  have hlast2 := lastId_eq _ hs2.contig
  have hLp : L.take snap.last.index.val = G.prefix snap.last.term.val snap.last.index.val := by
    have := consistent_take_prefix G L hLc _ hpos hsl; rw [hLs] at this; exact this
  obtain ⟨-, L'', hL'', hpL''⟩ := hLc (snap.last.index.val - 1) hsl
  rw [hLs] at hL''
  rw [show snap.last.index.val - 1 + 1 = snap.last.index.val by omega] at hpL''
  have hmx : n2.state.hard.commit.val ≤ (Rust.max n2.state.hard.commit snap.last.index).val ∧
      snap.last.index.val ≤ (Rust.max n2.state.hard.commit snap.last.index).val ∧
      ((Rust.max n2.state.hard.commit snap.last.index).val = n2.state.hard.commit.val ∧
          snap.last.index.val ≤ n2.state.hard.commit.val ∨
        (Rust.max n2.state.hard.commit snap.last.index).val = snap.last.index.val) := by
    rw [Rust.val_max]; simp only [Nat.max_def]; split <;> omega
  have hbase : 0 < s''.base.index.val → ∃ L, G.leader s''.base.term.val = some L ∧ s''.base.index.val ≤ L.length ∧
      ∃ h : s''.base.index.val - 1 < L.length, L[s''.base.index.val - 1].id = s''.base := by
    intro _
    rw [hb']
    have hl1 := hpL''.length_le
    simp only [List.length_take] at hl1
    refine ⟨L'', hL'', by omega, by omega, ?_⟩
    rw [← List.IsPrefix.getElem hpL'' (by simp; omega)]
    simp only [List.getElem_take]; exact hLs
  have hsnap : s''.snapshot.isSome → 0 < s''.base.index.val := fun _ => by rw [hb']; exact hpos
  have hreply' : ∀ l, L.take snap.last.index.val <+: l →
      (none : Option Rejection) = none → G.prefix t snap.last.index.val <+: l ∧ AckOk G t snap.last.index.val := by
    intro l hl _
    refine ⟨by simp only [Ghost.prefix, hL, Option.getD_some]; exact hl, L, hL, by omega⟩
  by_cases hkeep : idAt n2.state snap.last.index.val = some snap.last
  · rw [if_pos hkeep] at hr
    have hfl := fullLog_install_keep G n2.state s'' snap hs2 hP.cons hkeep hpos hr hsn
    obtain ⟨htake, hidx⟩ := match_take G _ hs2 hP.cons L hLc _ snap.last hkeep (fun _ => ⟨hsl, hLs⟩)
    obtain ⟨hi1, hi2⟩ := idAt_some _ hs2.layout hs2.contig _ hkeep
    have hlast' : (lastId s'').index.val = (lastId n2.state).index.val := by
      rw [lastId_eq s'' hc', hr, hb', hlast2]; simp only [List.length_drop]; omega
    refine ⟨{ hP.fixed with layout := hl', contig := hc' }, rfl, rfl, rfl, rfl, by show s''.hard.term = _; rw [hhard],
      by show s''.hard.voted_for = _; rw [hhard], ?_, by show Consistent G (fullLog G s''); rw [hfl]; exact hP.cons,
      fun t' j h => by show ∀ j' ≤ j, Kept G k t' j' (t + 1) (fullLog G s''); rw [hfl]; exact (hP.acks t' j h).2,
      fun h => (by simp at h), ?_, hreply' _ (by show _ <+: fullLog G s''; rw [hfl, ← htake]; exact List.take_prefix _ _)⟩
    · refine ⟨hl', hc', hbase, hsnap, ?_, ?_, ?_, ?_⟩
      · rw [hfl, hhard]; exact hs2.terms
      · rw [hhard, hb']; exact hmx.2.1
      · rw [hhard, hlast']; have := hs2.commit_le
        show (Rust.max n2.state.hard.commit snap.last.index).val ≤ _
        rcases hmx.2.2 with ⟨h, -⟩ | h <;> rw [h] <;> omega
      · rw [hhard]; exact hs2.unvoted
    · show Committed G ((fullLog G s'').take s''.hard.commit.val)
      rw [hfl, hhard]
      show Committed G ((fullLog G n2.state).take (Rust.max n2.state.hard.commit snap.last.index).val)
      rcases hmx.2.2 with ⟨h, -⟩ | h <;> rw [h]
      · exact hP.committed
      · rw [htake]; exact hcomm
  · rw [if_neg hkeep] at hr
    have hfl := fullLog_install_reset G s'' snap hr hsn hpos
    rw [← hLp] at hfl
    have hcl : n2.state.hard.commit.val < snap.last.index.val := hc2.2.resolve_right hkeep
    have hlast' : (lastId s'').index.val = snap.last.index.val := by
      rw [lastId_eq s'' hc', hr, hb']; rfl
    have hrepl : ∀ p, p <+: fullLog G n2.state → p <+: L → p <+: L.take snap.last.index.val := by
      intro p hp1 hp2
      by_cases hpl' : p.length ≤ snap.last.index.val
      · exact prefix_take_of p L _ hp2 hpl'
      · exfalso; apply hkeep
        have hlt1 : snap.last.index.val - 1 < p.length := by omega
        have h1 := hp1.getElem hlt1
        have h2 := hp2.getElem hlt1
        refine (idAt_fullLog G _ hs2 _ hpos _).mpr ⟨by omega, by have := hp1.length_le; omega, ?_⟩
        rw [← h1, h2, hLs]
    refine ⟨{ hP.fixed with layout := hl', contig := hc' }, rfl, rfl, rfl, rfl, by show s''.hard.term = _; rw [hhard],
      by show s''.hard.voted_for = _; rw [hhard], ?_,
      by show Consistent G (fullLog G s''); rw [hfl]; exact consistent_take G L hLc _,
      fun t' j h j' hj' => ?_, fun h => (by simp at h), ?_,
      hreply' _ (by show _ <+: fullLog G s''; rw [hfl]; exact List.prefix_refl _)⟩
    · refine ⟨hl', hc', hbase, hsnap, ?_, ?_, ?_, ?_⟩
      · rw [hfl, hhard]; intro x hx; rw [hP.term]; exact (hLt x (List.mem_of_mem_take hx)).2
      · rw [hhard, hb']; exact hmx.2.1
      · rw [hhard, hlast']
        show (Rust.max n2.state.hard.commit snap.last.index).val ≤ _
        rcases hmx.2.2 with ⟨h, -⟩ | h <;> rw [h] <;> omega
      · rw [hhard]; exact hs2.unvoted
    · show Kept G k t' j' (t + 1) (fullLog G s'')
      rw [hfl]
      obtain ⟨h1, h2⟩ := hP.acks t' j h
      exact kept_replace G k a hak t t' j' (t + 1) _ _ L eLt hL he hpe h1 (Nat.le_refl _) (h2 j' hj') hrepl
    · show Committed G ((fullLog G s'').take s''.hard.commit.val)
      rw [hfl, hhard]
      show Committed G ((L.take snap.last.index.val).take (Rust.max n2.state.hard.commit snap.last.index).val)
      rcases hmx.2.2 with ⟨-, h⟩ | h
      · omega
      · rw [h, List.take_take, Nat.min_self]; exact hcomm

theorem case_append (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (a k : Fin N) (hak : a ≠ k) (src dst : Id) (hsrc : src = ids[a])
    (t : Rust.u64) (ht0 : t.val ≠ 0) (prev : LogId) (entry : Option (Entry V)) (commit : Rust.u64)
    (hm : ⟨src, dst, .Append t prev entry commit⟩ ∈ C.sent)
    (n1 n2 n3 : Node V S N CAP) (r : Rust.u64 × Option Rejection)
    (hI : Idle (C.live k)) (hO : Observed (C.live k) src t n1) (hT : n1.state.hard.term = t)
    (hFol : Following n1 src n2) (hx : Node.append n2 prev entry commit = pure (r, n3)) :
    LocalOk ids cfg C G k (queue n3 a (.Replicated r.1 r.2)) := by
  obtain ⟨hP, hn2⟩ := pre_of ids cfg C G hi k hI src t n1 n2 ht0 hO hT hFol
  obtain ⟨L, hL, hprev, -, hent, -, hcomm, hsender⟩ := sent_append ids cfg C G hi _ hm t prev entry commit rfl
  obtain ⟨hLc, hLt, ca, eLt, he, hpe, -⟩ := hi.wf.leader t.val L hL
  have hca : ca = a := ids_inj ids (hi.fixed k).1.nodup _ _ ((hsender ca eLt he).symm.trans hsrc)
  rw [hca] at he
  obtain ⟨r', n', hap, hF3, hcases⟩ := append_rel ids n2 hP.fixed prev entry commit hP.live.commit_ge
    hP.live.commit_le (fun e h => (hent e h).2.2)
  rw [hap] at hx
  obtain ⟨hrr, hnn⟩ := Prod.mk.inj (pure_inj hx)
  subst hrr hnn
  refine local_reply ids cfg C G hi a k hak hI src t n1 n2 _ hO hT hn2 _ _ ?_
  have hprevL : prev.index.val ≤ L.length := by
    by_cases h0 : prev.index.val = 0
    · omega
    · obtain ⟨h, -⟩ := hprev (by omega); omega
  have hmin : ∀ x : Rust.u64, (Rust.min commit x).val ≤ commit.val ∧ (Rust.min commit x).val ≤ x.val := by
    intro x; rw [Rust.val_min]; exact ⟨Nat.min_le_left _ _, Nat.min_le_right _ _⟩
  rcases hcases with ⟨-, hr2, rfl⟩ | ⟨hp, rfl, rfl, rfl⟩ | ⟨e, hp, rfl, hide, rfl, rfl⟩ |
      ⟨e, rfl, -, -, hr2, rfl⟩ | ⟨e, hp, rfl, -, hr2, rfl⟩ | ⟨e, s', hp, rfl, hconf, hlt, hrep, rfl, rfl⟩
  · exact post_same ids C G k _ _ hP _ _ hr2
  · obtain ⟨htake, hidx⟩ := match_take G _ hP.live hP.cons L hLc _ prev hp hprev
    exact post_commit ids C G k _ n2 hP L hL _ htake hidx hprevL _ hcomm _ (hmin _).2 (hmin _).1 _ _ (fun _ => rfl)
  · obtain ⟨hel, hLe, hei⟩ := hent e rfl
    obtain ⟨htake, hidx⟩ := match_take G _ hP.live hP.cons L hLc _ e.id hide (fun _ => ⟨hel, by rw [hLe]⟩)
    exact post_commit ids C G k _ n2 hP L hL _ htake hidx (by omega) _ hcomm _ (hmin _).2 (hmin _).1 _ _
      (fun _ => rfl)
  · exact post_same ids C G k _ _ hP _ _ hr2
  · obtain ⟨htake, hidx⟩ := match_take G _ hP.live hP.cons L hLc _ prev hp hprev
    exact post_commit ids C G k _ n2 hP L hL _ htake hidx hprevL _ hcomm _ (hmin _).2 (hmin _).1 _ _
      (fun h => by rw [hr2] at h; cases h)
  · obtain ⟨hel, hLe, hei⟩ := hent e rfl
    exact post_replace ids C G k a hak _ n2 hP L eLt hL hLc hLt he hpe prev e hp hprev hel hLe hei hconf
      hlt s' hrep commit hcomm _ hF3 rfl


theorem case_install (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (a k : Fin N) (hak : a ≠ k) (src dst : Id) (hsrc : src = ids[a])
    (t : Rust.u64) (ht0 : t.val ≠ 0) (snap : Snapshot S) (hm : ⟨src, dst, .Install t snap⟩ ∈ C.sent)
    (n1 n2 n3 : Node V S N CAP) (rej : Option Rejection)
    (hI : Idle (C.live k)) (hO : Observed (C.live k) src t n1) (hT : n1.state.hard.term = t)
    (hFol : Following n1 src n2)
    (hc : (snap.last.index.val ≤ n2.state.hard.commit.val ∧
          Rust.Option.is_some_and (State.id_at n2.state snap.last.index) (fun id => id != snap.last) = true ∧
          rej.isSome ∧ n3 = n2) ∨
        (¬ (snap.last.index.val ≤ n2.state.hard.commit.val ∧
          Rust.Option.is_some_and (State.id_at n2.state snap.last.index) (fun id => id != snap.last) = true) ∧
          rej = none ∧
          ((¬ (n2.state.base.index.val < snap.last.index.val ∧
              (n2.state.hard.commit.val < snap.last.index.val ∨ idAt n2.state snap.last.index.val = some snap.last))
              ∧ n3 = n2) ∨
            (n2.state.base.index.val < snap.last.index.val ∧
              (n2.state.hard.commit.val < snap.last.index.val ∨ idAt n2.state snap.last.index.val = some snap.last) ∧
              ∃ s' lf, State.install n2.state snap = pure s' ∧
                n3 = { n2 with state := s', dirty := true, snapshot_changed := true, log_from := lf })))) :
    LocalOk ids cfg C G k (queue n3 a (.Replicated snap.last.index rej)) := by
  obtain ⟨hP, hn2⟩ := pre_of ids cfg C G hi k hI src t n1 n2 ht0 hO hT hFol
  obtain ⟨L, hL, hpos, hsl, hLs, hcomm, hsender⟩ := sent_install ids cfg C G hi _ hm t snap rfl
  obtain ⟨hLc, hLt, ca, eLt, he, hpe, -⟩ := hi.wf.leader t.val L hL
  have hca : ca = a := ids_inj ids (hi.fixed k).1.nodup _ _ ((hsender ca eLt he).symm.trans hsrc)
  rw [hca] at he
  refine local_reply ids cfg C G hi a k hak hI src t n1 n2 _ hO hT hn2 _ _ ?_
  rcases hc with ⟨-, -, hr, rfl⟩ | ⟨-, rfl, ⟨hn, hn3⟩ | ⟨h1, h2, s', lf, hins, rfl⟩⟩
  · exact post_same ids C G k _ _ hP _ _ hr
  · rw [hn3]
    refine post_keep ids C G k _ _ hP _ _ (fun _ => ⟨?_, L, hL, by omega⟩)
    have hs2 := hP.live
    have hle : snap.last.index.val ≤ n2.state.hard.commit.val := by
      by_cases hb : n2.state.base.index.val < snap.last.index.val
      · apply Classical.byContradiction; intro h; exact hn ⟨hb, Or.inl (by omega)⟩
      · have := hs2.commit_ge; omega
    have hlen := fullLog_length G _ hs2
    have hcl := hs2.commit_le
    have hpre : G.prefix t.val snap.last.index.val = L.take snap.last.index.val := by
      simp only [Ghost.prefix, hL, Option.getD_some]
    rw [hpre]
    rcases committed_compatible G hi.wf _ _ hcomm hP.committed with hp | hp
    · exact hp.trans (List.take_prefix _ _)
    · have h1 : (L.take snap.last.index.val).length = snap.last.index.val := by simp; omega
      have h2 : ((fullLog G n2.state).take n2.state.hard.commit.val).length = n2.state.hard.commit.val := by
        simp; omega
      have := hp.length_le
      rw [← hp.eq_of_length (by omega)]
      exact List.take_prefix _ _
  · exact post_install ids C G k a hak _ n2 hP L eLt hL hLc hLt he hpe snap hpos hsl hLs hcomm ⟨h1, h2⟩ s' hins lf

/-- The counted vote's ballot (the candidate's log is at least as up to date). -/
theorem voted_ballot (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (a k : Fin N) (src dst : Id) (hsrc : src = ids[a]) (hdst : dst = ids[k])
    (t : Rust.u64) (hm : ⟨src, dst, .Voted t true⟩ ∈ C.sent)
    (hcand : (C.live k).role = .Candidate) (hT : (C.live k).state.hard.term = t) :
    ∃ vlog, ((C.live k).state.hard.term.val, a, k, vlog) ∈ G.ballots ∧
      upToDate (lastOf (fullLog G (C.live k).state)) (lastOf vlog) := by
  rcases sent_voted ids cfg C G hi _ hm t rfl a k hsrc hdst with ⟨vlog, hb⟩ | ⟨eL, he⟩
  · have hb' : ((C.live k).state.hard.term.val, a, k, vlog) ∈ G.ballots := by rw [hT]; exact hb
    exact ⟨vlog, hb', hi.ballot_cand _ a k vlog hb' hcand rfl⟩
  · exact absurd ⟨hcand, by rw [hT]⟩ (hi.elect_cand _ k eL he)

theorem case_count (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (a k : Fin N) (_hak : a ≠ k) (src : Id) (t : Rust.u64)
    (n1 : Node V S N CAP) (hI : Idle (C.live k)) (hO : Observed (C.live k) src t n1)
    (hcand : n1.role = .Candidate) :
    Fixed ids { n1 with votes := n1.votes.set a.val true a.isLt } ∧
    ({ n1 with votes := n1.votes.set a.val true a.isLt } : Node V S N CAP).config = (C.live k).config ∧
    ({ n1 with votes := n1.votes.set a.val true a.isLt } : Node V S N CAP).local = (C.live k).local ∧
    n1.state = (C.live k).state ∧ n1.role = (C.live k).role ∧
    n1.votes = (C.live k).votes ∧ n1.matched = (C.live k).matched ∧ ∀ j : Fin N, n1.outbox[j] = none := by
  have hF1 := fixed_observed ids _ _ (hi.fixed k).1 src _ hO
  obtain ⟨hc1, hl1, hv1, hm1, hob1, -, hA⟩ := observed_facts _ _ src _ hO
  rcases hA with ⟨-, h, h', -⟩ | ⟨-, -, h, -⟩
  · exact ⟨{ hF1 with layout := hF1.layout, contig := hF1.contig }, hc1, hl1, h, h', hv1, hm1,
      fun j => by rw [hob1]; exact hI.2.2 j⟩
  · rw [h] at hcand; cases hcand

end Deliver

open Deliver in
theorem preserve_deliver (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (k : Fin N) (env : Envelope V S) (r : Rust.Result Unit Error) (n : Node V S N CAP)
    (hm : env ∈ C.sent) (h : Node.step (C.live k) env = pure (r, n)) :
    ∃ G', Extends G G' ∧ Inv ids cfg (C.setLive k n) G' := by
  have hF := (hi.fixed k).1
  have hFM : FixedMessage env.message := by
    have h2 := (hi.sent env hm).2
    revert h2
    cases env.message <;> intro h2 <;> first | exact h2.elim | trivial
  by_cases hsame : env.from = (C.live k).config.id ∨ env.to ≠ (C.live k).config.id ∨ env.message.term.val = 0
  · have := step_same ids _ hF env hFM hsame r n h
    subst this
    exact ⟨G, Extends.refl G, by rw [setLive_live]; exact hi⟩
  simp only [not_or, Classical.not_not] at hsame
  obtain ⟨hne, hto, ht0⟩ := hsame
  obtain ⟨⟨a, ha⟩, -⟩ := hi.sent env hm
  have hid := id_slot ids cfg C G hi k
  have hak : a ≠ k := fun e => hne (by rw [ha, e, hid])
  rw [hid] at hto
  have hst := step_rel ids _ hF a env ha hFM r n h
  rcases env with ⟨src, dst, msg⟩
  simp only at hst hto ha hm ht0
  cases hst with
  | same => exact ⟨G, Extends.refl G, by rw [setLive_live]; exact hi⟩
  | stale _ n1 _ hI hO hlt hn =>
    exact ⟨G, Extends.refl G, setLive_inv ids cfg C G hi k _ (case_stale ids cfg C G hi a k hak src msg n1 n hI hO hlt hn)⟩
  | vote t last n1 n2 g hI hO hT hg h1 h2 =>
    exact ⟨G, Extends.refl G, setLive_inv ids cfg C G hi k _ (case_vote ids cfg C G hi a k hak src dst ha hto t last
      (by simpa [Message.term] using ht0) hm n1 n2 g hI hO hT hg h1 h2 _ rfl)⟩
  | voted t g n1 _ hI hO hT hc =>
    rcases hc with ⟨-, hn⟩ | ⟨hcand, hg, hrest⟩
    · rw [hn]; exact ⟨G, Extends.refl G, setLive_inv ids cfg C G hi k _ (local_observed ids cfg C G hi a k hak hI src t n1 hO)⟩
    · subst hg
      obtain ⟨hFv, hcv, hlv, hs1, hr1, hv1, hm1, hob⟩ := case_count ids cfg C G hi a k hak src t n1 hI hO hcand
      have hcand0 : (C.live k).role = .Candidate := hr1 ▸ hcand
      have hT0 : (C.live k).state.hard.term = t := by rw [← hs1]; exact hT
      have hup := voted_ballot ids cfg C G hi a k src dst ha hto t hm hcand0 hT0
      rcases hrest with ⟨-, hn⟩ | ⟨hq, hB⟩
      · rw [hn]
        refine ⟨G, Extends.refl G, setLive_inv ids cfg C G hi k _ ?_⟩
        exact local_count ids cfg C G hi a k hak hI hcand0 hup _ hFv hcv hlv hs1 hr1 (by simp only [hv1]) hm1 hob
      · exact case_win ids cfg C G hi a k hak src t (by simpa [Message.term] using ht0) n1 _ n hI hO hT hcand rfl
          hq hB hup
  | append t prev entry commit n1 n2 n3 r hI hO hT hFol hx =>
    exact ⟨G, Extends.refl G, setLive_inv ids cfg C G hi k _ (case_append ids cfg C G hi a k hak src dst ha t
      (by simpa [Message.term] using ht0) prev entry commit hm n1 n2 n3 r hI hO hT hFol hx)⟩
  | install t snap n1 n2 n3 rej hI hO hT hFol hc =>
    exact ⟨G, Extends.refl G, setLive_inv ids cfg C G hi k _ (case_install ids cfg C G hi a k hak src dst ha t
      (by simpa [Message.term] using ht0) snap hm n1 n2 n3 rej hI hO hT hFol hc)⟩
  | replicated t index rej n1 _ hI hO hT hc =>
    refine ⟨G, Extends.refl G, setLive_inv ids cfg C G hi k _ ?_⟩
    rcases hc with ⟨-, hn⟩ | ⟨hl, hr⟩
    · rw [hn]; exact local_observed ids cfg C G hi a k hak hI src t n1 hO
    · exact case_replicated ids cfg C G hi a k hak src dst ha t index rej hm n1 n hI hO hT hl hr

end Jarl.Engine
