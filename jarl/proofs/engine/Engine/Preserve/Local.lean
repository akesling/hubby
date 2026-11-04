import Engine.Frame
import Engine.LogFacts

/-! # Preservation: Drain, restart, proposals and compaction -/

namespace Jarl.Engine
open Jarl

variable {V S : Type} {N CAP : Nat}


/-- Replacing only the outbox by a sub-outbox keeps node `k`'s clauses. -/
theorem localOk_outbox (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (k : Fin N) (ob : Vector (Option Outbound) N)
    (hf : Fixed ids { C.live k with outbox := ob })
    (hout : ∀ (j : Fin N) (o : Outbound), ob[j] = some o → (C.live k).outbox[j] = some o) :
    LocalOk ids cfg C G k { C.live k with outbox := ob } := by
  have hs : ∀ j, (C.setLive k { C.live k with outbox := ob }).live j = if j = k then { C.live k with outbox := ob } else C.live j := fun j => rfl
  refine
    { fixed := ⟨hf, (hi.fixed k).2⟩
      slot := hi.slot k
      live := hi.live k
      clean := hi.clean k
      terms := hi.terms k
      consistent := hi.consistent_live k
      acks := fun t j h j' hj' => ((hi.acks k t j h).2.2 j' hj').1
      elect := fun T eL h hd ht => (hi.elect T k eL h hd).2.2.2 ht
      ballots := fun T c v h ht => (hi.ballots T k c v h).2.2.2 ht
      ballot_cand := fun hr T w v h ht => hi.ballot_cand T w k v h hr ht
      elect_cand := fun T eL h => hi.elect_cand T k eL h
      leader := fun hr => ?_
      candidate := fun hr => ?_
      outbox := fun j o ho => ?_
      outbox_self := ?_
      votes := fun env he T last hfr hm => ?_
      committed := (hi.committed k).2 }
  · obtain ⟨a, b, c, d⟩ := hi.leader k hr
    exact ⟨by rw [setLive_self]; exact a, by rw [setLive_self]; exact b, by rw [setLive_self]; exact c,
      by rw [setLive_self]; exact d⟩
  · have := hi.candidate k hr
    unfold CandidateOk at this ⊢
    rw [setLive_self]; exact this
  · have := hi.outbox k j o (hout j o ho)
    unfold OutOk at this ⊢
    rw [setLive_self]; exact this
  · show ob[k] = none
    cases h : ob[k] with
    | none => rfl
    | some o => have := hout k o h; rw [hi.outbox_self k] at this; cases this
  · have := hi.sent env he
    unfold SentOk at this
    obtain ⟨-, h2⟩ := this
    rw [hm] at h2
    obtain ⟨a, b, -⟩ := h2 k hfr
    exact b



theorem fixed_bcast (ids : Vector Id N) (n : Node V S N CAP) (hf : Fixed ids n) : Fixed ids (bcast n) :=
  { hf with layout := hf.layout, contig := hf.contig }

/-- `advance_commit` on a dirty leader: only the commit index may change, and the
    new commitment is backed by the acknowledgments and the leader's own log. -/
theorem adv_facts (ids : Vector Id N) (G : Ghost V N) (k : Fin N) (m n2 : Node V S N CAP) (hfm : Fixed ids m)
    (hadv : Adv m n2) (hok : StateOk G m.state) (hrole : m.role = .Leader) (hd : m.dirty = true)
    (hcom : Committed G ((fullLog G m.state).take m.state.hard.commit.val))
    (hacks : ∀ j : Fin N, j ≠ k → 0 < (m.matched[j]).val → (j, m.state.hard.term.val, (m.matched[j]).val) ∈ G.acks)
    (hown : (m.matched[k]).val ≤ (fullLog G m.state).length) :
    ∃ c : Rust.u64, n2 = { m with state := { m.state with hard := { m.state.hard with commit := c } }, dirty := true } ∧
      StateOk G n2.state ∧ CommitOk G k n2 := by
  rcases hadv with rfl | ⟨v, hmaj, hlt, hsome, rfl⟩
  · refine ⟨n2.state.hard.commit, ?_, hok, Or.inl hcom⟩
    cases n2; simp only at hd; subst hd; rfl
  · have hc : commitTo m v = { m with state := { m.state with hard := { m.state.hard with commit := v } }, dirty := true } := by
      unfold commitTo; rw [if_pos hlt]
    rw [hc]
    rw [id_at_eq _ hfm.layout] at hsome
    obtain ⟨id, hid, hidt⟩ : ∃ id, idAt m.state v.val = some id ∧ id.term = m.state.hard.term := by
      cases h : idAt m.state v.val with
      | none => rw [h] at hsome; simp [Rust.Option.is_some_and] at hsome
      | some id => rw [h] at hsome; simp [Rust.Option.is_some_and] at hsome; exact ⟨id, rfl, hsome⟩
    have hlt' : m.state.hard.commit.val < v.val := Fin.lt_def.mp hlt
    have hv0 : 0 < v.val := by omega
    obtain ⟨-, hvl, hvid⟩ := (idAt_fullLog G m.state hok v.val hv0 id).mp hid
    have hlen := fullLog_length G m.state hok
    refine ⟨v, rfl, ?_, ?_⟩
    · exact { hok with commit_ge := by have := hok.commit_ge; show m.state.base.index.val ≤ v.val; omega,
                       commit_le := by show v.val ≤ (lastId m.state).index.val; omega }
    · refine Or.inr ⟨hrole, rfl, Or.inr ⟨m.state.hard.term.val, v.val, ⟨hv0, fullLog G m.state, ?_, hvl, ?_, ?_⟩, ?_⟩⟩
      · simp [withOwn]; rfl
      · show ((fullLog G m.state)[v.val - 1]).id.term.val = m.state.hard.term.val
        rw [hvid, hidt]
      · have hM : Majority N (fun j => v.val ≤ (m.matched[j]).val) := by
          unfold Majority
          rw [List.countP_congr (q := fun j : Fin N => decide (v.val ≤ (m.matched[j]).val)) (fun j _ => by simp)]
          exact hmaj
        apply majority_mono _ _ _ hM
        intro w hw
        by_cases hwk : w = k
        · subst hwk
          exact ⟨(fullLog G m.state).length, by omega, List.mem_cons_self⟩
        · exact ⟨(m.matched[w]).val, hw, List.mem_cons_of_mem _ (hacks w hwk (by omega))⟩
      · simp [Ghost.prefix, withOwn]

/-- A leader whose log grows by entries of its term keeps its clauses. -/
theorem localOk_leader (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (k : Fin N) (n : Node V S N CAP) (hr0 : (C.live k).role = .Leader)
    (hf : Fixed ids n) (hcfg : n.config = cfg k) (hslot : n.local.val = k.val)
    (hrole : n.role = .Leader) (hdirty : n.dirty = true)
    (hterm : n.state.hard.term = (C.live k).state.hard.term)
    (hvote : n.state.hard.voted_for = (C.live k).state.hard.voted_for)
    (hok : StateOk G n.state) (l : List (Entry V))
    (hlog : fullLog G n.state = fullLog G (C.live k).state ++ l)
    (hl : ∀ e ∈ l, e.id.term = (C.live k).state.hard.term)
    (hmatch : ∀ j : Fin N, j ≠ k → n.matched[j] = (C.live k).matched[j])
    (hown : (n.matched[k]).val ≤ (fullLog G n.state).length)
    (hob : ∀ (j : Fin N) (o : Outbound), n.outbox[j] = some o → o = .Replicate) (hobk : n.outbox[k] = none)
    (hcom : CommitOk G k n) : LocalOk ids cfg C G k n := by
  have hpre : fullLog G (C.live k).state <+: fullLog G n.state := hlog ▸ List.prefix_append _ _
  have hT : n.state.hard.term.val = (C.live k).state.hard.term.val := by rw [hterm]
  refine
    { fixed := ⟨hf, hcfg⟩
      slot := hslot
      live := hok
      clean := fun h => by rw [hdirty] at h; cases h
      terms := by rw [hT]; exact hi.terms k
      consistent := fun h => absurd hrole h
      acks := fun t j h j' hj' => by
        rw [hT]; exact kept_of_prefix G k t j' _ _ _ hpre ((hi.acks k t j h).2.2 j' hj').1
      elect := fun T eL h hd ht => ?_
      ballots := fun T c v h ht => by
        rw [hvote]; rw [hT] at ht; exact (hi.ballots T k c v h).2.2.2 ht
      ballot_cand := fun h => by rw [hrole] at h; cases h
      elect_cand := fun T eL h => by rw [hrole]; simp
      leader := fun _ => ?_
      candidate := fun h => by rw [hrole] at h; cases h
      outbox := fun j o ho => ?_
      outbox_self := hobk
      votes := fun env he T last hfr hm => by rw [hrole]; simp
      committed := hcom }
  · rw [hT] at ht
    exact absurd hr0 ((hi.elect T k eL h hd).2.2.2 ht).2.1
  · obtain ⟨⟨eL, he, hp, hte⟩, ⟨L, hL, hLp, -⟩, hm, -⟩ := hi.leader k hr0
    refine ⟨?_, ?_, ?_, ?_⟩ <;> rw [setLive_self]
    · refine ⟨eL, by rw [hT]; exact he, hp.trans hpre, fun i hi' hle => ?_⟩
      rw [hterm]
      have hi2 : i < (fullLog G (C.live k).state ++ l).length := hlog ▸ hi'
      rw [List.getElem_of_eq hlog hi']
      by_cases hlt : i < (fullLog G (C.live k).state).length
      · rw [List.getElem_append_left hlt]; exact hte i hlt hle
      · rw [List.getElem_append_right (by omega)]; exact hl _ (List.getElem_mem _)
    · exact ⟨L, by rw [hT]; exact hL, hLp.trans hpre, fun h => by rw [hdirty] at h; cases h⟩
    · intro j hj h0
      rw [hmatch j hj, hT] at *
      exact hm j hj h0
    · exact hown
  · rw [hob j o ho]; unfold OutOk; rw [setLive_self]; exact hrole

/-- A leader appends entries of its term (`m`), possibly advances its commit
    index, and broadcasts. -/
theorem localOk_leader_adv (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (k : Fin N) (m n2 : Node V S N CAP) (hr0 : (C.live k).role = .Leader)
    (hf : Fixed ids m) (hcfg : m.config = cfg k) (hslot : m.local.val = k.val)
    (hrole : m.role = .Leader) (hdirty : m.dirty = true)
    (hhard : m.state.hard = (C.live k).state.hard)
    (hok : StateOk G m.state) (l : List (Entry V))
    (hlog : fullLog G m.state = fullLog G (C.live k).state ++ l)
    (hl : ∀ e ∈ l, e.id.term = (C.live k).state.hard.term)
    (hmatch : ∀ j : Fin N, j ≠ k → m.matched[j] = (C.live k).matched[j])
    (hown : (m.matched[k]).val ≤ (fullLog G m.state).length)
    (hob : ∀ j : Fin N, m.outbox[j] = none)
    (hcom : Committed G ((fullLog G m.state).take m.state.hard.commit.val))
    (hadv : Adv m n2) : LocalOk ids cfg C G k (bcast n2) := by
  have hf2 := fixed_adv ids m n2 hf hadv
  have hterm : m.state.hard.term = (C.live k).state.hard.term := by rw [hhard]
  have hacks : ∀ j : Fin N, j ≠ k → 0 < (m.matched[j]).val → (j, m.state.hard.term.val, (m.matched[j]).val) ∈ G.acks := by
    intro j hj h0
    rw [hmatch j hj, hterm] at *
    exact (hi.leader k hr0).matched j hj h0
  obtain ⟨c, rfl, hok2, hcom2⟩ := adv_facts ids G k m n2 hf hadv hok hrole hdirty hcom hacks hown
  refine localOk_leader ids cfg C G hi k _ hr0 (fixed_bcast ids _ hf2) hcfg hslot hrole rfl hterm
    (by show m.state.hard.voted_for = _; rw [hhard]) hok2 l hlog hl hmatch hown ?_ ?_ hcom2
  · intro j o ho
    simp only [bcast, Fin.getElem_fin, Vector.getElem_ofFn] at ho
    split at ho
    · cases ho; rfl
    · have := hob j; simp only [Fin.getElem_fin] at this; rw [this] at ho; cases ho
  · simp only [bcast, Fin.getElem_fin, Vector.getElem_ofFn]
    rw [if_neg (by rw [hslot]; simp)]
    have := hob k; simp only [Fin.getElem_fin] at this; exact this

/-- Appending entries of the current term keeps a checkpoint's facts. -/
theorem stateOk_append (G : Ghost V N) (s s' : State V S CAP) (l : List (Entry V)) (h : StateOk G s)
    (hs : s'.snapshot = s.snapshot) (hh : s'.hard = s.hard) (hr : ret s' = ret s ++ l)
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

theorem committed_append (G : Ghost V N) (s : State V S CAP) (l : List (Entry V)) (h : StateOk G s)
    (hc : Committed G ((fullLog G s).take s.hard.commit.val)) :
    Committed G ((fullLog G s ++ l).take s.hard.commit.val) := by
  have := h.commit_le
  rw [← fullLog_length G s h] at this
  rw [List.take_append_of_le_length this]; exact hc

theorem localOk_self (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (k : Fin N) : LocalOk ids cfg C G k (C.live k) :=
  localOk_outbox ids cfg C G hi k (C.live k).outbox (hi.fixed k).1 (fun _ _ h => h)

/-- A non-leader whose checkpoint changes without changing its full log, hard
    state or last identity (a compaction) keeps its clauses. -/
theorem localOk_samelog (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (k : Fin N) (n : Node V S N CAP) (hf : Fixed ids n) (hcfg : n.config = cfg k)
    (hslot : n.local.val = k.val) (hr0 : (C.live k).role ≠ .Leader) (hrole : n.role = (C.live k).role)
    (hdirty : n.dirty = true) (hh : n.state.hard = (C.live k).state.hard) (hok : StateOk G n.state)
    (hfl : fullLog G n.state = fullLog G (C.live k).state) (hlast : lastId n.state = lastId (C.live k).state)
    (hvotes : n.votes = (C.live k).votes) (hob : ∀ j : Fin N, n.outbox[j] = none)
    (hcom : Committed G ((fullLog G n.state).take n.state.hard.commit.val)) : LocalOk ids cfg C G k n := by
  refine
    { fixed := ⟨hf, hcfg⟩
      slot := hslot
      live := hok
      clean := fun h => by rw [hdirty] at h; cases h
      terms := by rw [hh]; exact hi.terms k
      consistent := fun _ => hfl ▸ hi.consistent_live k hr0
      acks := fun t j h j' hj' => by rw [hfl, hh]; exact ((hi.acks k t j h).2.2 j' hj').1
      elect := fun T eL h hd ht => ?_
      ballots := fun T c v h ht => by rw [hh] at ht ⊢; exact (hi.ballots T k c v h).2.2.2 ht
      ballot_cand := fun h T w v hb ht => by
        rw [hfl]; rw [hh] at ht; exact hi.ballot_cand T w k v hb (hrole ▸ h) ht
      elect_cand := fun T eL h => by rw [hrole, hh]; exact hi.elect_cand T k eL h
      leader := fun h => absurd (hrole ▸ h) hr0
      candidate := fun h => ?_
      outbox := fun j o ho => by rw [hob j] at ho; cases ho
      outbox_self := hob k
      votes := fun env he T last hfr hm hc => ?_
      committed := Or.inl hcom }
  · rw [hh] at ht
    obtain ⟨a, b, c⟩ := (hi.elect T k eL h hd).2.2.2 ht
    exact ⟨hfl.trans a, hrole ▸ b, by rw [hh]; exact c⟩
  · have := hi.candidate k (hrole ▸ h)
    unfold CandidateOk at this ⊢
    rw [setLive_self, hfl, hh, hvotes]; exact this
  · rw [hlast]
    have := hi.sent env he
    unfold SentOk at this
    rw [hm] at this
    exact (this.2 k hfr).2.1 ⟨hrole ▸ hc.1, by rw [← hh]; exact hc.2⟩

theorem preserve_drain (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (k : Fin N) (n : Node V S N CAP) (h : Node.next_message (C.live k) = pure (none, n)) :
    Inv ids cfg (C.setLive k n) G := by
  obtain ⟨hn, hf, hout, -⟩ := next_message_rel ids (C.live k) (hi.fixed k).1 none n h
  apply setLive_inv ids cfg C G hi k n
  obtain ⟨ob, rfl⟩ : ∃ ob, n = { C.live k with outbox := ob } := ⟨_, hn⟩
  refine localOk_outbox ids cfg C G hi k ob hf ?_
  intro j o ho
  rcases hout j with e | e
  · exact e ▸ ho
  · simp only at e; rw [e] at ho; cases ho

theorem preserve_restart (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (k : Fin N) (n : Node V S N CAP) (h : Node.new (cfg k) (C.disk k) = pure (.Ok n)) :
    Inv ids cfg (C.setLive k n) G := by
  obtain ⟨hf0, hc0⟩ := hi.fixed k
  have hm : (cfg k).members = ids := by rw [← hc0]; exact hf0.members
  obtain ⟨hf, hs, hcfg, hr, hd, hob⟩ := new_rel ids (cfg k) (C.disk k) n h hf0.n_pos hf0.n_lt hf0.cap_lt hm
    hf0.nodup (hi.disk k).layout (hi.disk k).contig
  apply setLive_inv ids cfg C G hi k n
  refine
    { fixed := ⟨hf, hcfg⟩
      slot := ?_
      live := hs ▸ hi.disk k
      clean := fun _ => hs
      terms := by rw [hs]; exact Nat.le_refl _
      consistent := fun _ => hs ▸ hi.consistent_disk k
      acks := fun t j h j' hj' => hs ▸ ((hi.acks k t j h).2.2 j' hj').2
      elect := fun T eL h hd ht => ?_
      ballots := fun T c v h ht => ?_
      ballot_cand := fun h => by rw [hr] at h; cases h
      elect_cand := fun T eL h => by rw [hr]; simp
      leader := fun h => by rw [hr] at h; cases h
      candidate := fun h => by rw [hr] at h; cases h
      outbox := fun j o ho => by rw [(hob j).1] at ho; cases ho
      outbox_self := (hob k).1
      votes := fun env he T last hfr hm => by rw [hr]; simp
      committed := Or.inl (hs ▸ (hi.committed k).1) }
  · have h1 := hf.local_id
    have h2 := hf0.local_id
    rw [hcfg, ← hc0, ← h2] at h1
    rw [← hi.slot k]
    exact (List.getElem_inj hf0.nodup (h₀ := by simp [hf.local_lt]) (h₁ := by simp [hf0.local_lt])).mp (by simpa using h1)
  · obtain ⟨-, b, -, -⟩ := hi.elect T k eL h hd
    rw [hs, hr]; exact ⟨b, by simp, rfl⟩
  · rw [hs] at ht ⊢; exact (hi.ballots T k c v h).2.2.1 ht

theorem preserve_propose (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (k : Fin N) (vs : List V) (count : Rust.usize) (hc : count.val = vs.length)
    (r : Rust.Result ProposalRange Error) (n : Node V S N CAP)
    (h : Node.propose_many (C.live k) count vs = pure (r, n)) : Inv ids cfg (C.setLive k n) G := by
  have hf := (hi.fixed k).1
  rcases propose_many_rel ids (C.live k) hf vs count hc r n h with rfl |
    ⟨⟨hd, -, hob⟩, hr0, hpos, hbound, s', n2, hr, hh, hs, hl', hc', hadv, rfl⟩
  · exact setLive_inv ids cfg C G hi k _ (localOk_self ids cfg C G hi k)
  apply setLive_inv ids cfg C G hi k _
  have hok0 := hi.live k
  have hterms : ∀ e ∈ proposed (C.live k) vs, e.id.term = (C.live k).state.hard.term := by
    intro e he; simp only [proposed, List.mem_map] at he; obtain ⟨_, _, rfl⟩ := he; rfl
  have hok := stateOk_append G _ s' _ hok0 hs hh hr hl' hc' hterms
  have hslot := hi.slot k
  refine localOk_leader_adv ids cfg C G hi k _ n2 hr0 (fixed_state ids _ hf s' hl' hc' true _ _) (hi.fixed k).2
    hslot hr0 rfl hh hok (proposed (C.live k) vs) (fullLog_append G _ s' _ hs hr) hterms ?_ ?_ ?_ ?_ hadv
  · intro j hj
    show ((C.live k).matched.set (C.live k).local.val _ hf.local_lt)[j] = _
    rw [Fin.getElem_fin, Fin.getElem_fin, Vector.getElem_set_ne]
    intro e; apply hj; apply Fin.ext; omega
  · show (((C.live k).matched.set (C.live k).local.val _ hf.local_lt)[k]).val ≤ _
    rw [fullLog_length G s' hok, lastId_eq s' hc', hr, base_of_snapshot _ _ hs]
    have := lastId_eq _ hok0.contig
    simp [Fin.getElem_fin, hslot, proposed, Rust.ofNat]
    omega
  · intro j; exact hob j
  · have := (hi.committed k).1
    rw [← hi.clean k hd] at this
    rw [hh, fullLog_append G _ s' _ hs hr]
    exact committed_append G _ _ hok0 this

theorem preserve_compact (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (k : Fin N) (index : Rust.u64) (value : Unit → Rust.M S)
    (r : Rust.Result Unit Error) (n : Node V S N CAP)
    (h : Node.compact_with (C.live k) index value = pure (r, n)) : Inv ids cfg (C.setLive k n) G := by
  have hf := (hi.fixed k).1
  rcases compact_with_rel ids (C.live k) hf index value r n h with rfl |
    ⟨⟨hd, -, hob⟩, hlo, hhi, last, v, s', hid, -, hins, hcase⟩
  · exact setLive_inv ids cfg C G hi k _ (localOk_self ids cfg C G hi k)
  apply setLive_inv ids cfg C G hi k _
  have hok0 := hi.live k
  have hclean := hi.clean k hd
  have hcons : Consistent G (fullLog G (C.live k).state) := by rw [hclean]; exact hi.consistent_disk k
  have hcom0 : Committed G ((fullLog G (C.live k).state).take (C.live k).state.hard.commit.val) := by
    rw [hclean]; exact (hi.committed k).1
  obtain ⟨s2, hins2, hsn, hhard, hret, hlay⟩ := install_spec (C.live k).state { last := last, value := v }
    (by have := hf.cap_lt; omega) hf.layout hf.contig
  obtain rfl : s' = s2 := pure_inj (hins.symm.trans hins2)
  have hpos : 0 < index.val := by omega
  obtain ⟨hbi, hil, hiid⟩ := (idAt_fullLog G _ hok0 index.val hpos last).mp hid
  have hlidx : last.index.val = index.val := by
    have := (hcons (index.val - 1) hil).1; rw [hiid] at this; omega
  have hm : idAt (C.live k).state last.index.val = some last := by rw [hlidx]; exact hid
  have hret' : ret s' = (ret (C.live k).state).drop (last.index.val - (C.live k).state.base.index.val) := by
    rw [hret, if_pos hm]
  have hcont := install_contig (C.live k).state s' _ hf.layout hf.contig hsn hret
  have hfl : fullLog G s' = fullLog G (C.live k).state :=
    fullLog_install_keep G _ s' { last := last, value := v } hok0 hcons hm (by show 0 < last.index.val; omega) hret' hsn
  have hh : s'.hard = (C.live k).state.hard := by
    have : Rust.max (C.live k).state.hard.commit last.index = (C.live k).state.hard.commit := by
      unfold Rust.max; split
      · apply Fin.ext; omega
      · rfl
    rw [hhard]; simp only [this]
  have hb' : s'.base = last := base_some s' _ hsn
  obtain ⟨h1, h2⟩ := idAt_some _ hf.layout hf.contig _ hm
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
      rw [lastId_eq _ hf.contig] at this
      simp only [List.length_drop]; omega
    · rw [hh]; exact hok0.unvoted
  have hlast : lastId s' = lastId (C.live k).state := by
    rw [← lastOf_fullLog G s' hok, ← lastOf_fullLog G _ hok0, hfl]
  have hf1 : Fixed ids { C.live k with state := s', dirty := true, snapshot_changed := true } :=
    { hf with layout := hlay, contig := hcont }
  have hcom1 : Committed G ((fullLog G s').take s'.hard.commit.val) := by rw [hfl, hh]; exact hcom0
  rcases hcase with ⟨hr0, rfl⟩ | ⟨hr0, n2, hB, rfl⟩
  · exact localOk_samelog ids cfg C G hi k _ hf1 (hi.fixed k).2 (hi.slot k) hr0 rfl rfl hh hok hfl hlast rfl
      (fun j => hob j) hcom1
  rcases hB with rfl | ⟨s'', idx, hlt, hidx, -, hr'', hh'', hs'', hl'', hc'', hA⟩
  · refine localOk_leader_adv ids cfg C G hi k _ _ hr0 hf1 (hi.fixed k).2 (hi.slot k) hr0 rfl hh hok []
      (by rw [hfl, List.append_nil]) (by simp) (fun _ _ => rfl) ?_ (fun j => hob j) hcom1 (Or.inl rfl)
    show _ ≤ (fullLog G s').length
    rw [hfl]; exact (hi.leader k hr0).own
  · have hterms : ∀ e ∈ [({ id := { index := idx, term := s'.hard.term }, value := none } : Entry V)],
        e.id.term = s'.hard.term := by
      intro e he; simp only [List.mem_singleton] at he; subst he; rfl
    have hok'' := stateOk_append G s' s'' _ hok hs'' hh'' hr'' hl'' hc'' hterms
    have hslot := hi.slot k
    refine localOk_leader_adv ids cfg C G hi k _ _ hr0 (fixed_state ids _ hf1 s'' hl'' hc'' true _ _) (hi.fixed k).2
      hslot hr0 rfl (hh''.trans hh) hok'' _ (by rw [fullLog_append G s' s'' _ hs'' hr'', hfl])
      (by rw [← hh]; exact hterms) ?_ ?_ (fun j => hob j) ?_ hA
    · intro j hj
      show ((C.live k).matched.set (C.live k).local.val _ hlt)[j] = _
      rw [Fin.getElem_fin, Fin.getElem_fin, Vector.getElem_set_ne]
      intro e; apply hj; apply Fin.ext; omega
    · show (((C.live k).matched.set (C.live k).local.val _ hlt)[k]).val ≤ _
      rw [fullLog_length G s'' hok'', lastId_eq s'' hc'', hr'', base_of_snapshot _ _ hs'']
      have := lastId_eq s' hcont
      simp only at hidx
      simp [Fin.getElem_fin, hslot]
      omega
    · show Committed G ((fullLog G s'').take s''.hard.commit.val)
      rw [hh'', fullLog_append G s' s'' _ hs'' hr'']
      exact committed_append G _ _ hok hcom1

end Jarl.Engine
