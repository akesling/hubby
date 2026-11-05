import Engine.Frame
import Engine.LogFacts

/-! # Preservation: A tick -/

namespace Jarl.Engine
open Jarl

variable {V S : Type} {N CAP : Nat} [Rust.Clone V] [Rust.Clone S]

namespace PTick

theorem is_some_and_term (o : Option LogId) (T : Rust.u64)
    (h : Rust.Option.is_some_and o (fun id => id.term == T) = true) : ∃ id, o = some id ∧ id.term = T := by
  cases o with
  | none => simp at h
  | some id => exact ⟨id, rfl, by simpa using h⟩

omit [Rust.Clone V] [Rust.Clone S] in
/-- What a `Barrier` step does to a node, in terms of full logs. -/
theorem barrier_spec (ids : Vector Id N) (G : Ghost V N) (p n2 : Node V S N CAP) (hf : Fixed ids p)
    (hs : StateOk G p.state) (hB : Barrier p n2) :
    n2.role = p.role ∧ n2.outbox = p.outbox ∧ n2.local = p.local ∧ n2.config = p.config ∧
    n2.state.hard.term = p.state.hard.term ∧ n2.state.hard.voted_for = p.state.hard.voted_for ∧
    Fixed ids n2 ∧ StateOk G n2.state ∧
    (n2 = p ∨ (n2.dirty = true ∧ ∃ e : Entry V, e.id.term = p.state.hard.term ∧
      fullLog G n2.state = fullLog G p.state ++ [e] ∧
      (∀ j : Fin N, (n2.matched[j]).val =
        if j.val = p.local.val then (fullLog G p.state).length + 1 else (p.matched[j]).val) ∧
      (n2.state.hard.commit = p.state.hard.commit ∨
        (p.state.hard.commit.val < n2.state.hard.commit.val ∧
         ∃ hv : n2.state.hard.commit.val - 1 < (fullLog G n2.state).length,
          ((fullLog G n2.state)[n2.state.hard.commit.val - 1]).id.term = p.state.hard.term ∧
          N / 2 < (List.finRange N).countP (fun j => decide (n2.state.hard.commit.val ≤ (n2.matched[j]).val)))))) := by
  have hfn := fixed_barrier ids p n2 hf hB
  rcases hB with rfl | ⟨s', idx, h, hidx, hterm, hr, hh, hsn, hl, hc, hA⟩
  · exact ⟨rfl, rfl, rfl, rfl, rfl, rfl, hf, hs, Or.inl rfl⟩
  have hlen := fullLog_length G p.state hs
  have hfl : fullLog G s' = fullLog G p.state ++
      [{ id := { index := idx, term := p.state.hard.term }, value := none }] :=
    fullLog_append G p.state s' _ hsn hr
  have hbase : s'.base = p.state.base := base_of_snapshot _ _ hsn
  have hlast' : (lastId s').index.val = (lastId p.state).index.val + 1 := by
    rw [lastId_eq s' hc, lastId_eq p.state hs.contig, hbase, hr]; simp; omega
  have hs' : StateOk G s' := by
    refine ⟨hl, hc, ?_, ?_, ?_, ?_, ?_, ?_⟩
    · rw [hbase]; exact hs.base
    · rw [hsn, hbase]; exact hs.snapshot
    · rw [hfl]; intro e he
      rcases List.mem_append.mp he with he | he
      · rw [hh]; exact hs.terms e he
      · simp at he; subst he; simp [hh]
    · rw [hbase, hh]; exact hs.commit_ge
    · rw [hlast', hh]; have := hs.commit_le; omega
    · rw [hh]; exact hs.unvoted
  have hmatch : ∀ j : Fin N, ((ownAppend p s' idx h).matched[j]).val =
      if j.val = p.local.val then (fullLog G p.state).length + 1 else (p.matched[j]).val := by
    intro j
    simp only [ownAppend]
    by_cases hj : p.local.val = j.val
    · simp [hj, hidx, hlen]
    · simp [hj, Ne.symm hj]
  rcases hA with rfl | ⟨v, hmaj, hlt, hid, rfl⟩
  · refine ⟨rfl, rfl, rfl, rfl, by simp [ownAppend, hh], by simp [ownAppend, hh], hfn, hs', Or.inr ⟨rfl, _, rfl, hfl, hmatch, Or.inl (by simp [ownAppend, hh])⟩⟩
  · have hlt' : (ownAppend p s' idx h).state.hard.commit < v := hlt
    have hct : commitTo (ownAppend p s' idx h) v =
        { (ownAppend p s' idx h) with state := { s' with hard := { s'.hard with commit := v } }, dirty := true } := by
      rw [commitTo, if_pos hlt']; rfl
    rw [hct] at hfn ⊢
    have hfl2 : fullLog G ({ s' with hard := { s'.hard with commit := v } } : State V S CAP) = fullLog G s' :=
      fullLog_congr G _ _ rfl rfl
    have hcv : p.state.hard.commit < v := by simpa [ownAppend, hh] using hlt
    obtain ⟨id, hid1, hid2⟩ := is_some_and_term _ _ hid
    have hid1' : State.id_at s' v = some id := hid1
    rw [id_at_eq s' hl] at hid1'
    have hv0 : 0 < v.val := by rw [Fin.lt_def] at hcv; omega
    obtain ⟨hvb, hvl, hvid⟩ := (idAt_fullLog G s' hs' v.val hv0 id).mp hid1'
    have hs2 : StateOk G ({ s' with hard := { s'.hard with commit := v } } : State V S CAP) := by
      refine ⟨hl, hc, hs'.base, hs'.snapshot, ?_, ?_, ?_, ?_⟩
      · rw [hfl2]; exact hs'.terms
      · show s'.base.index.val ≤ v.val; exact hvb
      · show v.val ≤ (lastId s').index.val
        have := fullLog_length G s' hs'; omega
      · exact hs'.unvoted
    refine ⟨rfl, rfl, rfl, rfl, by simp [hh], by simp [hh], hfn, hs2,
      Or.inr ⟨rfl, _, rfl, hfl2.trans hfl, hmatch, Or.inr ⟨by rw [Fin.lt_def] at hcv; exact hcv, ?_⟩⟩⟩
    refine ⟨by rw [hfl2]; exact hvl, ?_, hmaj⟩
    simp only [hfl2]
    rw [hvid, hid2]; simp [ownAppend, hh]

omit [Rust.Clone V] [Rust.Clone S] in
@[local simp] theorem bcast_state (n : Node V S N CAP) : (bcast n).state = n.state := rfl
omit [Rust.Clone V] [Rust.Clone S] in
@[local simp] theorem bcast_role (n : Node V S N CAP) : (bcast n).role = n.role := rfl
omit [Rust.Clone V] [Rust.Clone S] in
@[local simp] theorem bcast_dirty (n : Node V S N CAP) : (bcast n).dirty = n.dirty := rfl
omit [Rust.Clone V] [Rust.Clone S] in
@[local simp] theorem bcast_matched (n : Node V S N CAP) : (bcast n).matched = n.matched := rfl
omit [Rust.Clone V] [Rust.Clone S] in
@[local simp] theorem bcast_local (n : Node V S N CAP) : (bcast n).local = n.local := rfl
omit [Rust.Clone V] [Rust.Clone S] in
theorem bcast_outbox (n : Node V S N CAP) (j : Fin N) :
    (bcast n).outbox[j] = if j.val ≠ n.local.val then some .Replicate else n.outbox[j] := by
  simp [bcast, Fin.getElem_fin]

omit [Rust.Clone V] [Rust.Clone S] in
@[local simp] theorem bcast_config (n : Node V S N CAP) : (bcast n).config = n.config := rfl

omit [Rust.Clone V] [Rust.Clone S] in
theorem fixed_bcast (ids : Vector Id N) (n : Node V S N CAP) (hf : Fixed ids n) : Fixed ids (bcast n) :=
  { hf with layout := hf.layout, contig := hf.contig }

theorem majority_of_countP (P : Fin N → Prop) (f : Fin N → Bool) (hf : ∀ j, f j = true → P j)
    (h : N / 2 < (List.finRange N).countP f) : Majority N P := by
  unfold Majority
  have : (List.finRange N).countP f ≤ (List.finRange N).countP (fun w => @decide (P w) (Classical.propDecidable _)) := by
    apply List.countP_mono_left; intro w _ hw; simpa using hf w hw
  omega

omit [Rust.Clone V] [Rust.Clone S] in
/-- A leader `p` (node `k`, possibly dirty) running `barrier` then `broadcast` keeps its local clauses. -/
theorem leader_local (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (k : Fin N) (p n2 : Node V S N CAP)
    (hf : Fixed ids p) (hcfg : p.config = cfg k) (hslot : p.local.val = k.val) (hr : p.role = .Leader)
    (hs : StateOk G p.state) (hterm : (C.disk k).hard.term.val ≤ p.state.hard.term.val)
    (hclean : p.dirty = false → p.state = C.disk k)
    (hacks : ∀ t j, (k, t, j) ∈ G.acks → ∀ j' ≤ j, Kept G k t j' (p.state.hard.term.val + 1) (fullLog G p.state))
    (helect : ∀ T eL, G.elect T = some (k, eL) → (C.disk k).hard.term.val < T → p.state.hard.term.val < T → False)
    (hballot : ∀ T c vlog, (T, k, c, vlog) ∈ G.ballots → p.state.hard.term.val = T →
      p.state.hard.voted_for = some ids[c])
    (hel : ∃ eL, G.elect p.state.hard.term.val = some (k, eL) ∧ eL <+: fullLog G p.state ∧
      ∀ i (h : i < (fullLog G p.state).length), eL.length ≤ i → ((fullLog G p.state)[i]).id.term = p.state.hard.term)
    (hlog : ∃ L, G.leader p.state.hard.term.val = some L ∧ L <+: fullLog G p.state ∧
      (p.dirty = false → L = fullLog G p.state))
    (hmatched : ∀ j : Fin N, j ≠ k → 0 < (p.matched[j]).val → (j, p.state.hard.term.val, (p.matched[j]).val) ∈ G.acks)
    (hown : (p.matched[k]).val ≤ (fullLog G p.state).length)
    (hout : ∀ j : Fin N, p.outbox[j] = none)
    (hcom : Committed G ((fullLog G p.state).take p.state.hard.commit.val))
    (hB : Barrier p n2) : LocalOk ids cfg C G k (bcast n2) := by
  obtain ⟨hrole, hout2, hloc, hcfg2, hterm2, hvf2, hfix2, hs2, hcase⟩ := barrier_spec ids G p n2 hf hs hB
  have hlenp := fullLog_length G p.state hs
  have hcle : p.state.hard.commit.val ≤ (fullLog G p.state).length := by have := hs.commit_le; omega
  -- Unified facts about `n2`.
  have F1 : fullLog G p.state <+: fullLog G n2.state := by
    rcases hcase with rfl | ⟨-, e, -, hfl, -⟩
    · exact List.prefix_refl _
    · rw [hfl]; exact List.prefix_append _ _
  have F2 : ∀ i (h : i < (fullLog G n2.state).length), (fullLog G p.state).length ≤ i →
      ((fullLog G n2.state)[i]).id.term = p.state.hard.term := by
    rcases hcase with rfl | ⟨-, e, het, hfl, -⟩
    · intro i h hle; omega
    · intro i h hle
      have hi' : i < (fullLog G p.state ++ [e]).length := by rw [← hfl]; exact h
      rw [List.getElem_of_eq hfl h, List.getElem_append_right hle]
      simp at hi'
      simp [show i - (fullLog G p.state).length = 0 by omega, het]
  have F3 : n2.dirty = false → n2 = p := by
    rcases hcase with h | ⟨hd, -⟩
    · intro _; exact h
    · intro h; rw [hd] at h; cases h
  have F4 : ∀ j : Fin N, j ≠ k → n2.matched[j] = p.matched[j] := by
    rcases hcase with rfl | ⟨-, e, -, -, hm, -⟩
    · intro j _; rfl
    · intro j hj
      apply Fin.ext
      rw [hm j, if_neg]
      intro h; apply hj; apply Fin.ext; omega
  have F5 : (n2.matched[k]).val ≤ (fullLog G n2.state).length := by
    rcases hcase with rfl | ⟨-, e, -, hfl, hm, -⟩
    · exact hown
    · rw [hm k, if_pos (by omega), hfl]; simp
  have F6 : CommitOk G k n2 := by
    rcases hcase with rfl | ⟨hd, e, -, hfl, hm, hc | ⟨hlt, hv, hvt, hmaj⟩⟩
    · exact Or.inl hcom
    · left; rw [hc, hfl, List.take_append_of_le_length hcle]; exact hcom
    · right
      refine ⟨by rw [hrole]; exact hr, hd, Or.inr ⟨n2.state.hard.term.val, n2.state.hard.commit.val,
        ⟨by omega, fullLog G n2.state, by simp [withOwn], hv, by rw [hvt, hterm2], ?_⟩, ?_⟩⟩
      · apply majority_of_countP _ _ _ hmaj
        intro j hj
        simp only [decide_eq_true_eq] at hj
        by_cases hjk : j = k
        · subst hjk
          exact ⟨(fullLog G n2.state).length, by omega, by simp [withOwn]⟩
        · refine ⟨(n2.matched[j]).val, hj, ?_⟩
          simp only [withOwn]
          apply List.mem_cons_of_mem
          rw [F4 j hjk, hterm2]
          exact hmatched j hjk (by rw [← F4 j hjk]; omega)
      · simp [Ghost.prefix, withOwn]
  refine
    { fixed := ⟨fixed_bcast ids n2 hfix2, by simp [hcfg2, hcfg]⟩
      slot := by simp [hloc, hslot]
      live := by simpa using hs2
      clean := ?_
      terms := by simp [hterm2]; exact hterm
      consistent := by simp [hrole, hr]
      acks := ?_
      elect := ?_
      ballots := ?_
      elect_cand := by intro T eL _; simp [hrole, hr]
      ballot_cand := by intro hc; simp [hrole, hr] at hc
      leader := ?_
      candidate := by simp [hrole, hr]
      outbox := ?_
      outbox_self := by rw [bcast_outbox, if_neg (by simp [hloc, hslot]), hout2, hout k]
      votes := by intro env _ T last _ _; simp [hrole, hr]
      committed := F6 }
  · intro hd; simp only [bcast_dirty, bcast_state] at hd ⊢
    rw [F3 hd]; exact hclean (by rw [← F3 hd]; exact hd)
  · intro t j h j' hj'
    simp only [bcast_state, hterm2]
    exact kept_of_prefix _ _ _ _ _ _ _ F1 (hacks t j h j' hj')
  · intro T eL he hd hlt
    simp only [bcast_state, hterm2] at hlt
    exact (helect T eL he hd hlt).elim
  · intro T c vlog h ht
    simp only [bcast_state, hterm2, hvf2] at ht ⊢
    exact hballot T c vlog h ht
  · intro _
    obtain ⟨eL, he, hp, hb⟩ := hel
    obtain ⟨L, hL, hLp, hLd⟩ := hlog
    refine ⟨?_, ?_, ?_, ?_⟩ <;> simp only [setLive_self, bcast_state, bcast_dirty, bcast_matched, hterm2]
    · refine ⟨eL, he, hp.trans F1, ?_⟩
      intro i h hle
      by_cases hi : i < (fullLog G p.state).length
      · rw [← hb i hi hle]
        exact congrArg (fun x : Entry V => x.id.term) (List.IsPrefix.getElem F1 hi).symm
      · exact F2 i h (by omega)
    · refine ⟨L, hL, hLp.trans F1, ?_⟩
      intro hd
      rw [F3 hd]; exact hLd (by rw [← F3 hd]; exact hd)
    · intro j hj h0
      rw [F4 j hj] at h0 ⊢
      exact hmatched j hj h0
    · exact F5
  · intro j o ho
    unfold OutOk
    simp only [setLive_self]
    rw [bcast_outbox] at ho
    split at ho
    · cases ho; simp [hrole, hr]
    · rw [hout2, hout j] at ho; cases ho

omit [Rust.Clone V] [Rust.Clone S] in
theorem config_id (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (k : Fin N) : (C.live k).config.id = ids[k] := by
  have hf := (hi.fixed k).1
  rw [← hf.local_id]
  simp only [Fin.getElem_fin, hi.slot k]

omit [Rust.Clone V] [Rust.Clone S] in
theorem sent_vote (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (env : Envelope V S) (h : env ∈ C.sent) (T : Rust.u64) (last : LogId) (c : Fin N)
    (hfrom : env.from = ids[c]) (hm : env.message = .Vote T last) : T.val ≤ (C.disk c).hard.term.val := by
  have h2 := (hi.sent env h).2
  rw [hm] at h2
  exact (h2 c hfrom).1

omit [Rust.Clone V] [Rust.Clone S] in
/-- Only the elapsed-time counters changed. -/
theorem localOk_time (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (k : Fin N) (e a : Rust.u64) :
    LocalOk ids cfg C G k { C.live k with elapsed := e, leader_age := a } := by
  have hf := hi.fixed k
  refine
    { fixed := ⟨fixed_timeOnly ids _ hf.1 e a, hf.2⟩
      slot := hi.slot k
      live := hi.live k
      clean := hi.clean k
      terms := hi.terms k
      consistent := hi.consistent_live k
      acks := fun t j h j' hj' => ((hi.acks k t j h).2.2 j' hj').1
      elect := fun T eL h hd => (hi.elect T k eL h hd).2.2.2
      ballots := fun T c v h => (hi.ballots T k c v h).2.2.2
      elect_cand := fun T eL h => hi.elect_cand T k eL h
      ballot_cand := fun hc T w v h ht => hi.ballot_cand T w k v h hc ht
      leader := ?_
      candidate := ?_
      outbox := ?_
      outbox_self := hi.outbox_self k
      votes := ?_
      committed := (hi.committed k).2 }
  · intro hr
    obtain ⟨a1, a2, a3, a4⟩ := hi.leader k hr
    refine ⟨?_, ?_, ?_, ?_⟩ <;> simp only [setLive_self] <;> assumption
  · intro hr
    have := hi.candidate k hr
    unfold CandidateOk at this ⊢
    simp only [setLive_self]
    exact this
  · intro j o ho
    have := hi.outbox k j o ho
    unfold OutOk at this ⊢
    simp only [setLive_self]
    exact this
  · intro env h T last hfrom hm hc
    have h2 := (hi.sent env h).2
    rw [hm] at h2
    exact (h2 k hfrom).2.1 hc

omit [Rust.Clone V] [Rust.Clone S] in
theorem setLive_live (C : Cluster V S N CAP) (k : Fin N) : C.setLive k (C.live k) = C := by
  cases C
  simp only [Cluster.setLive, Cluster.mk.injEq, and_true]
  funext j
  split <;> simp_all

/-- A strict majority of at least two slots contains a slot other than `k`. -/
theorem majority_other (k : Fin N) (hN : ¬ N / 2 < 1) (P : Fin N → Prop) (h : Majority N P) : ∃ w, w ≠ k ∧ P w := by
  apply Classical.byContradiction
  intro hn
  have hle : (List.finRange N).countP (fun w => @decide (P w) (Classical.propDecidable _)) ≤
      (List.finRange N).countP (fun w => decide (w.val = k.val)) := by
    apply List.countP_mono_left
    intro w _ hw
    simp only [decide_eq_true_eq] at hw ⊢
    apply Classical.byContradiction
    intro hne
    exact hn ⟨w, fun e => hne (by rw [e]), hw⟩
  rw [countP_single k.val k.isLt _ (fun j => rfl)] at hle
  unfold Majority at h
  omega

omit [Rust.Clone V] [Rust.Clone S] in
theorem stateOk_cand (G : Ghost V N) (s : State V S CAP) (hs : StateOk G s) (T : Rust.u64)
    (hT : s.hard.term.val < T.val) (v : Option Id) :
    StateOk G { s with hard := { s.hard with term := T, voted_for := v } } := by
  have hfl : fullLog G ({ s with hard := { s.hard with term := T, voted_for := v } } : State V S CAP) = fullLog G s :=
    fullLog_congr G _ _ rfl rfl
  refine ⟨hs.layout, hs.contig, hs.base, hs.snapshot, ?_, hs.commit_ge, hs.commit_le, ?_⟩
  · rw [hfl]; intro e he; have := hs.terms e he; show _ ≤ T.val; omega
  · intro h0; have : T.val = 0 := h0; omega

omit [Rust.Clone V] [Rust.Clone S] in
theorem requestVotes_outbox (n : Node V S N CAP) (j : Fin N) :
    (requestVotes n).outbox[j] = if j.val ≠ n.local.val then some .Vote else n.outbox[j] := by
  simp [requestVotes, Fin.getElem_fin]

omit [Rust.Clone V] [Rust.Clone S] in
/-- A campaign with at least two slots: a candidate of the next term requesting votes. -/
theorem campaign_local (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (k : Fin N) (T : Rust.u64) (n' : Node V S N CAP)
    (hidle : Idle (C.live k)) (hrl : (C.live k).role ≠ .Leader)
    (hT : T.val = (C.live k).state.hard.term.val + 1) (hN : ¬ N / 2 < 1)
    (hstate : n'.state = { (C.live k).state with hard := { (C.live k).state.hard with term := T, voted_for := some (C.live k).config.id } })
    (hrole : n'.role = .Candidate) (hdirty : n'.dirty = true) (hloc : n'.local = (C.live k).local)
    (hcfg : n'.config = (C.live k).config) (hfix : Fixed ids n')
    (hvotes : ∀ j : Fin N, n'.votes[j] = true → j.val = n'.local.val)
    (hout : ∀ j : Fin N, n'.outbox[j] = if j.val ≠ (C.live k).local.val then some .Vote else (C.live k).outbox[j]) :
    LocalOk ids cfg C G k n' := by
  have hf := hi.fixed k
  have hs := hi.live k
  have hcl := hi.clean k hidle.1
  have hdt : (C.disk k).hard.term.val = (C.live k).state.hard.term.val := by rw [hcl]
  have hcid := config_id ids cfg C G hi k
  have hfl : fullLog G n'.state = fullLog G (C.live k).state := by rw [hstate]; exact fullLog_congr G _ _ rfl rfl
  have hterm : n'.state.hard.term = T := by rw [hstate]
  have hvf : n'.state.hard.voted_for = some ids[k] := by rw [hstate]; simp [hcid]
  have hcom : n'.state.hard.commit = (C.live k).state.hard.commit := by rw [hstate]
  refine
    { fixed := ⟨hfix, by rw [hcfg]; exact hf.2⟩
      slot := by rw [hloc]; exact hi.slot k
      live := by rw [hstate]; exact stateOk_cand G _ hs T (by omega) _
      clean := by intro hd; rw [hdirty] at hd; cases hd
      terms := by rw [hterm]; omega
      consistent := by intro _; rw [hfl]; exact hi.consistent_live k hrl
      acks := ?_
      elect := ?_
      ballots := ?_
      elect_cand := ?_
      ballot_cand := by
        intro _ T' w vlog hb hT'
        rw [hterm] at hT'
        by_cases hw : w = k
        · subst hw
          rcases (hi.ballots T' w w vlog hb).1 with h1 | ⟨-, -, he⟩
          · omega
          · obtain ⟨-, -, -, hmaj⟩ := hi.wf.elect T' w vlog he
            obtain ⟨w', hw', vlog', hb', -⟩ := majority_other w hN _ hmaj
            have := (hi.ballots T' w' w vlog' hb').2.1 hw'
            omega
        · have := (hi.ballots T' w k vlog hb).2.1 hw
          omega
      leader := by intro hr; rw [hrole] at hr; cases hr
      candidate := ?_
      outbox := ?_
      outbox_self := ?_
      votes := ?_
      committed := ?_ }
  · intro t j hm j' hj'
    rw [hfl, hterm]
    exact kept_mono_bound _ _ _ _ _ _ _ (by omega) ((hi.acks k t j hm).2.2 j' hj').1
  · intro T' eL he hd hlt
    have := (hi.elect T' k eL he hd).2.2.1
    rw [hterm] at hlt
    omega
  · intro T' c vlog hb hT'
    rw [hterm] at hT'
    rcases (hi.ballots T' k c vlog hb).1 with h1 | ⟨rfl, -⟩
    · omega
    · exact hvf
  · rintro T' eL he ⟨-, hT'⟩
    rw [hterm] at hT'
    obtain ⟨-, -, -, hmaj⟩ := hi.wf.elect T' k eL he
    obtain ⟨w, hw, vlog, hb, -⟩ := majority_other k hN _ hmaj
    have := (hi.ballots T' w k vlog hb).2.1 hw
    omega
  · intro _
    unfold CandidateOk
    simp only [setLive_self]
    refine ⟨hvf, ?_, ?_⟩
    · rw [hfl, hterm]; intro x hx; have := hs.terms x hx; omega
    · intro j hj
      left
      apply Fin.ext
      rw [hvotes j hj, hloc, hi.slot k]
  · intro j o ho
    rw [hout] at ho
    split at ho
    · cases ho; unfold OutOk; simp only [setLive_self]; exact hrole
    · rw [hidle.2.2 j] at ho; cases ho
  · rw [hout, if_neg (by simp [hi.slot k])]
    exact hidle.2.2 k
  · rintro env hm T' last hfrom hmsg ⟨-, hT'⟩
    have := sent_vote ids cfg C G hi env hm T' last k hfrom hmsg
    rw [hterm] at hT'
    subst hT'
    omega
  · rcases (hi.committed k).2 with h1 | ⟨hr, -⟩
    · left
      rw [hfl, hcom]; exact h1
    · exact absurd hr hrl

/-- The ghost after a single-node election in term `t1` with log `L0`. -/
def singleGhost (G : Ghost V N) (t1 : Nat) (k : Fin N) (L0 : List (Entry V)) : Ghost V N :=
  { G with leader := fun T => if T = t1 then some L0 else G.leader T, elect := fun T => if T = t1 then some (k, L0) else G.elect T, ballots := (t1, k, k, L0) :: G.ballots }

omit [Rust.Clone V] in
theorem ackOk_le (G : Ghost V N) (t j j' : Nat) (h : AckOk G t j') (hj : j ≤ j') : AckOk G t j := by
  obtain ⟨L, hL, hl⟩ := h; exact ⟨L, hL, by omega⟩

omit [Rust.Clone V] in
theorem ackOk_extends {G G' : Ghost V N} (e : Extends G G') (t j : Nat) (h : AckOk G t j) : AckOk G' t j := by
  obtain ⟨L, hL, hl⟩ := h
  obtain ⟨L', hL', hp⟩ := e.leader t L hL
  exact ⟨L', hL', Nat.le_trans hl hp.length_le⟩

omit [Rust.Clone V] [Rust.Clone S] in
/-- A single node about to win term `t + 1` by its own vote: record the election. -/
theorem single_elect (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (k : Fin N) (hN1 : N = 1) (hidle : Idle (C.live k)) (hrl : (C.live k).role ≠ .Leader) :
    ∃ G', Extends G G' ∧ Inv ids cfg C G' ∧
      G'.elect ((C.live k).state.hard.term.val + 1) = some (k, fullLog G (C.live k).state) ∧
      G'.leader ((C.live k).state.hard.term.val + 1) = some (fullLog G (C.live k).state) := by
  have hall : ∀ j : Fin N, j = k := fun j => Fin.ext (by have := j.isLt; have := k.isLt; omega)
  have hcl := hi.clean k hidle.1
  have hs := hi.live k
  have hdt : (C.disk k).hard.term.val = (C.live k).state.hard.term.val := by rw [hcl]
  generalize ht1 : (C.live k).state.hard.term.val + 1 = t1
  generalize hL0 : fullLog G (C.live k).state = L0
  cases hel : G.elect t1 with
  | some x =>
    obtain ⟨c, eL⟩ := x
    have hc := hall c
    subst hc
    obtain ⟨h1, h2, -⟩ := hi.elect t1 c eL hel (by omega)
    rw [hcl, ← hL0, ← hcl, h2] at *
    exact ⟨G, Extends.refl G, hi, hel, h1⟩
  | none =>
  have hlnone : G.leader t1 = none := by
    cases h : G.leader t1 with
    | none => rfl
    | some L =>
      obtain ⟨-, -, c, eL, he, -⟩ := hi.wf.leader t1 L h
      rw [hel] at he; cases he
  have hcons : Consistent G L0 := hL0 ▸ hi.consistent_live k hrl
  let G' := singleGhost G t1 k L0
  have hlead : ∀ T L, G.leader T = some L → G'.leader T = some L := by
    intro T L h
    have : T ≠ t1 := by intro e; subst e; rw [hlnone] at h; cases h
    simp [G', singleGhost, this, h]
  have helect : ∀ T x, G.elect T = some x → G'.elect T = some x := by
    intro T x h
    have : T ≠ t1 := by intro e; subst e; rw [hel] at h; cases h
    simp [G', singleGhost, this, h]
  have hext : Extends G G' :=
    ⟨fun T L h => ⟨L, hlead T L h, List.prefix_refl L⟩, helect, fun _ h => h,
      fun _ h => List.mem_cons_of_mem _ h⟩
  have hel' : ∀ T, G'.elect T = if T = t1 then some (k, L0) else G.elect T := fun T => rfl
  have hle' : ∀ T, G'.leader T = if T = t1 then some L0 else G.leader T := fun T => rfl
  have hbal' : ∀ b, b ∈ G'.ballots ↔ b = (t1, k, k, L0) ∨ b ∈ G.ballots := fun b => List.mem_cons
  have hfle : ∀ j, fullLog G' (C.live j).state = fullLog G (C.live j).state :=
    fun j => fullLog_extends hext _ (hi.live j)
  have hfde : ∀ j, fullLog G' (C.disk j) = fullLog G (C.disk j) := fun j => fullLog_extends hext _ (hi.disk j)
  refine ⟨G', hext, ?_, by simp [hel'], by simp [hle']⟩
  refine
    { wf := ⟨?_, ?_, ?_⟩
      fixed := hi.fixed
      slot := hi.slot
      live := fun j => stateOk_extends hext _ (hi.live j)
      disk := fun j => stateOk_extends hext _ (hi.disk j)
      consistent_disk := fun j => by rw [hfde]; exact consistent_extends hext _ (hi.consistent_disk j)
      consistent_live := fun j hr => by rw [hfle]; exact consistent_extends hext _ (hi.consistent_live j hr)
      clean := hi.clean
      terms := hi.terms
      acks := ?_
      ballots := ?_
      ballot_unique := fun T w c c' v v' _ _ => by rw [hall c, hall c']
      elect := ?_
      elect_cand := ?_
      ballot_cand := by
        intro T w c vlog h hr ht
        rcases (hbal' _).mp h with h | h
        · simp only [Prod.mk.injEq] at h
          obtain ⟨hT, -, hc, -⟩ := h
          rw [hc] at ht; omega
        · rw [hfle]; exact hi.ballot_cand T w c vlog h hr ht
      leader := fun j hr => by rw [hall j] at hr; exact absurd hr hrl
      candidate := ?_
      outbox := fun j j' o ho => by rw [hall j, hidle.2.2 j'] at ho; cases ho
      outbox_self := hi.outbox_self
      sent := ?_
      committed := ?_ }
  · -- Wf.leader
    intro T L h
    rw [hle'] at h
    split at h
    · cases h
      rename_i hT
      refine ⟨consistent_extends hext _ hcons, ?_, k, L0, by simp [hel', hT], List.prefix_refl _, ?_⟩
      · intro e he
        refine ⟨(consistent_terms G hi.wf _ hcons e he).1, ?_⟩
        have := hs.terms e (hL0 ▸ he); omega
      · intro i hi hle; omega
    · obtain ⟨a, b, c, eL, he, hp, hb⟩ := hi.wf.leader T L h
      exact ⟨consistent_extends hext _ a, b, c, eL, helect _ _ he, hp, hb⟩
  · -- Wf.elect
    intro T c eL h
    rw [hel'] at h
    split at h
    · cases h
      rename_i hT
      refine ⟨by omega, consistent_extends hext _ hcons, ?_, ?_⟩
      · intro e he; have := hs.terms e (hL0 ▸ he); omega
      · apply majority_of_countP _ (fun _ => true)
        · intro j _
          refine ⟨L0, ?_, Or.inr ⟨rfl, Nat.le_refl _⟩⟩
          rw [hall j, hbal']; left; rw [hT]
        · simp [hN1]
    · obtain ⟨a, b, c', d⟩ := hi.wf.elect T c eL h
      exact ⟨a, consistent_extends hext _ b, c', majority_mono _ _
        (fun w ⟨v, hv, hu⟩ => ⟨v, hext.ballots _ hv, hu⟩) d⟩
  · -- Wf.ballot
    intro T w c vlog h
    rcases (hbal' _).mp h with h | h
    · simp only [Prod.mk.injEq] at h
      obtain ⟨hT, hw, hc, hv⟩ := h
      subst T w c vlog
      refine ⟨consistent_extends hext _ hcons, ?_⟩
      intro t j' ha hlt j hj
      left
      obtain ⟨hak, -, hkept⟩ := hi.acks k t j' ha
      have := (hkept j hj).1
      rw [hL0, ht1] at this
      exact kept_extends hext _ _ _ _ _ this (ackOk_le G t j j' hak hj)
    · obtain ⟨a, b⟩ := hi.wf.ballot T w c vlog h
      refine ⟨consistent_extends hext _ a, ?_⟩
      intro t j' ha hlt j hj
      rcases b t j' ha hlt j hj with b | ⟨c', eL', he, hne⟩
      · exact Or.inl (kept_extends hext _ _ _ _ _ b (ackOk_le G t j j' (hi.acks w t j' ha).1 hj))
      · exact Or.inr ⟨c', eL', helect _ _ he, hne⟩
  · -- acks
    intro w t j h
    obtain ⟨a, b, c⟩ := hi.acks w t j h
    refine ⟨ackOk_extends hext _ _ a, b, fun j' hj' => ?_⟩
    have hak := ackOk_le G t j' j a hj'
    rw [hfle, hfde]
    exact ⟨kept_extends hext _ _ _ _ _ (c j' hj').1 hak, kept_extends hext _ _ _ _ _ (c j' hj').2 hak⟩
  · -- ballots
    intro T w c vlog h
    rcases (hbal' _).mp h with h | h
    · simp only [Prod.mk.injEq] at h
      obtain ⟨hT, hw, hc, hv⟩ := h
      subst T w c vlog
      refine ⟨Or.inr ⟨rfl, by omega, by simp [hel']⟩, fun h => absurd rfl h, ?_, ?_⟩
      · intro h; omega
      · intro h; omega
    · obtain ⟨a, b, c', d⟩ := hi.ballots T w c vlog h
      refine ⟨?_, b, c', d⟩
      rcases a with a | ⟨a1, a2, a3⟩
      · exact Or.inl a
      · exact Or.inr ⟨a1, a2, helect _ _ a3⟩
  · -- elect
    intro T c eL h hd
    rw [hel'] at h
    split at h
    · cases h
      rename_i hT
      subst hT
      refine ⟨by simp [hle'], by rw [hfde, ← hcl, hL0], by omega, fun _ => ⟨by rw [hfle, hL0], hrl, ?_⟩⟩
      rw [hcl]
    · obtain ⟨a, b, c', d⟩ := hi.elect T c eL h hd
      refine ⟨hlead _ _ a, by rw [hfde]; exact b, c', fun hlt => ?_⟩
      rw [hfle]; exact d hlt
  · -- elect_cand
    intro T c eL h
    rw [hel'] at h
    split at h
    · cases h
      rename_i hT
      rintro ⟨-, h2⟩; omega
    · exact hi.elect_cand T c eL h
  · -- candidate
    intro j hr
    have := hi.candidate j hr
    unfold CandidateOk at this ⊢
    rw [hfle]
    obtain ⟨a, b, -⟩ := this
    refine ⟨a, b, fun j' _ => Or.inl (by rw [hall j', hall j])⟩
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
        have := hall c; subst this; omega
      · exact d eL he
    | Voted T g =>
      intro h2 hg w c hw hc
      rcases h2 hg w c hw hc with ⟨v, hv⟩ | ⟨eL, he⟩
      · exact Or.inl ⟨v, hext.ballots _ hv⟩
      · exact Or.inr ⟨eL, helect _ _ he⟩
    | Replicated T j r => intro h2; exact h2
    | Append T prev entry commit =>
      intro h2
      obtain ⟨L, hL, a, b, c, d, e, f⟩ := h2
      refine ⟨L, hlead _ _ hL, a, b, c, d, committed_mono hext _ e, fun c' eL he => f c' eL ?_⟩
      have : T.val ≠ t1 := by intro e; rw [e, hlnone] at hL; cases hL
      rw [hel', if_neg this] at he; exact he
    | Install T snap =>
      intro h2
      obtain ⟨L, hL, a, b, c, d, f⟩ := h2
      refine ⟨L, hlead _ _ hL, a, b, c, committed_mono hext _ d, fun c' eL he => f c' eL ?_⟩
      have : T.val ≠ t1 := by intro e; rw [e, hlnone] at hL; cases hL
      rw [hel', if_neg this] at he; exact he
    | _ => intro h2; exact h2
  · -- committed
    intro j
    obtain ⟨a, b⟩ := hi.committed j
    refine ⟨by rw [hfde]; exact committed_mono hext _ a, ?_⟩
    rcases b with b | ⟨hr, -⟩
    · left; rw [hfle]; exact committed_mono hext _ b
    · rw [hall j] at hr; exact absurd hr hrl

omit [Rust.Clone V] [Rust.Clone S] in
/-- A single node that just won term `T` by its own vote runs `barrier` and `broadcast`. -/
theorem single_local (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (k : Fin N) (hN1 : N = 1) (T : Rust.u64) (p n2 : Node V S N CAP)
    (hidle : Idle (C.live k)) (hrl : (C.live k).role ≠ .Leader)
    (hT : T.val = (C.live k).state.hard.term.val + 1)
    (helG : G.elect T.val = some (k, fullLog G (C.live k).state))
    (hleG : G.leader T.val = some (fullLog G (C.live k).state))
    (hstate : p.state = { (C.live k).state with hard := { (C.live k).state.hard with term := T, voted_for := some (C.live k).config.id } })
    (hrole : p.role = .Leader) (hdirty : p.dirty = true) (hloc : p.local = (C.live k).local)
    (hcfg : p.config = (C.live k).config) (hfix : Fixed ids p)
    (hmk : (p.matched[k]).val = (lastId (C.live k).state).index.val)
    (hout : ∀ j : Fin N, p.outbox[j] = (C.live k).outbox[j]) (hB : Barrier p n2) :
    LocalOk ids cfg C G k (bcast n2) := by
  have hall : ∀ j : Fin N, j = k := fun j => Fin.ext (by have := j.isLt; have := k.isLt; omega)
  have hs := hi.live k
  have hcl := hi.clean k hidle.1
  have hdt : (C.disk k).hard.term.val = (C.live k).state.hard.term.val := by rw [hcl]
  have hcid := config_id ids cfg C G hi k
  have hfl : fullLog G p.state = fullLog G (C.live k).state := by rw [hstate]; exact fullLog_congr G _ _ rfl rfl
  have hterm : p.state.hard.term = T := by rw [hstate]
  have hvf : p.state.hard.voted_for = some ids[k] := by rw [hstate]; simp [hcid]
  have hcom : p.state.hard.commit = (C.live k).state.hard.commit := by rw [hstate]
  have hsp : StateOk G p.state := by rw [hstate]; exact stateOk_cand G _ hs T (by omega) _
  apply leader_local ids cfg C G k p n2 hfix (by rw [hcfg]; exact (hi.fixed k).2) (by rw [hloc]; exact hi.slot k)
    hrole hsp (by rw [hterm]; omega) (by intro hd; rw [hdirty] at hd; cases hd)
  · intro t j hm j' hj'
    rw [hfl, hterm]
    exact kept_mono_bound _ _ _ _ _ _ _ (by omega) ((hi.acks k t j hm).2.2 j' hj').1
  · intro T' eL he hd hlt
    have := (hi.elect T' k eL he hd).2.2.1
    rw [hterm] at hlt
    omega
  · intro T' c vlog hb hT'
    rw [hterm] at hT'
    rcases (hi.ballots T' k c vlog hb).1 with h1 | ⟨rfl, -⟩
    · omega
    · exact hvf
  · refine ⟨fullLog G (C.live k).state, by rw [hterm]; exact helG, by rw [hfl]; exact List.prefix_refl _, ?_⟩
    intro i h hle; rw [hfl] at h; omega
  · exact ⟨_, by rw [hterm]; exact hleG, by rw [hfl]; exact List.prefix_refl _, by intro hd; rw [hdirty] at hd; cases hd⟩
  · intro j hj; exact absurd (hall j) hj
  · rw [hmk, hfl, fullLog_length G _ hs]; exact Nat.le_refl _
  · intro j; rw [hout]; exact hidle.2.2 j
  · rcases (hi.committed k).2 with h1 | ⟨hr, -⟩
    · rw [hfl, hcom]; exact h1
    · exact absurd hr hrl
  · exact hB

omit [Rust.Clone V] [Rust.Clone S] in
theorem fixed_requestVotes (ids : Vector Id N) (n : Node V S N CAP) (hf : Fixed ids n) : Fixed ids (requestVotes n) :=
  { hf with layout := hf.layout, contig := hf.contig }

end PTick

open PTick

theorem preserve_tick (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (k : Fin N) (r : Rust.Result Unit Error) (n : Node V S N CAP)
    (h : Node.tick (C.live k) = pure (r, n)) : ∃ G', Extends G G' ∧ Inv ids cfg (C.setLive k n) G' := by
  have hf := (hi.fixed k).1
  cases tick_rel ids _ hf r n h with
  | same => exact ⟨G, Extends.refl G, by rw [setLive_live]; exact hi⟩
  | time n' _ hto =>
    obtain ⟨e, a, rfl⟩ := hto
    exact ⟨G, Extends.refl G, setLive_inv ids cfg C G hi k _ (localOk_time ids cfg C G hi k e a)⟩
  | heartbeat n0 n2 hidle hl hto hB =>
    obtain ⟨e, a, rfl⟩ := hto
    obtain ⟨L1, L2, L3, L4⟩ := hi.leader k hl
    refine ⟨G, Extends.refl G, setLive_inv ids cfg C G hi k _ (leader_local ids cfg C G k _ n2
      (fixed_timeOnly ids _ hf e a) (hi.fixed k).2 (hi.slot k) hl (hi.live k) (hi.terms k)
      (fun _ => hi.clean k hidle.1) (fun t j h j' hj' => ((hi.acks k t j h).2.2 j' hj').1) ?_
      (fun T c v h => (hi.ballots T k c v h).2.2.2) L1 L2 L3 L4 hidle.2.2 ?_ hB)⟩
    · intro T eL he hd hlt; exact (((hi.elect T k eL he hd).2.2.2 hlt).2.1 hl).elim
    · rcases (hi.committed k).2 with h1 | ⟨-, hd, -⟩
      · exact h1
      · rw [hidle.1] at hd; cases hd
  | campaign n0 n' h0 hidle hrl hto ht hC =>
    obtain ⟨e, a, rfl⟩ := hto
    obtain ⟨n1, htm, ⟨hN, hBL⟩ | ⟨hN, rfl⟩⟩ := hC
    · obtain ⟨r', d, rfl⟩ := htm
      obtain ⟨h', n2, hB, rfl⟩ := hBL
      have hN1 : N = 1 := by have := hf.n_pos; omega
      obtain ⟨G', hext, hi', helG, hleG⟩ := single_elect ids cfg C G hi k hN1 hidle hrl
      have hfle := fullLog_extends hext _ (hi.live k)
      rw [← hfle] at helG hleG
      have hf1 := fixed_timers ids _ _ (fixed_candidate ids _ (fixed_timeOnly ids _ hf e a) ⟨_, ht⟩) ⟨r', d, rfl⟩
      refine ⟨G', hext, setLive_inv ids cfg C G' hi' k _ (single_local ids cfg C G' hi' k hN1 ⟨_, ht⟩ (leaderInit _ h') n2
        hidle hrl rfl helG hleG rfl rfl rfl rfl rfl (fixed_leaderInit ids _ hf1) ?_
        (fun j => rfl) hB)⟩
      simp [leaderInit, candidate, Fin.getElem_fin, hi.slot k]; rfl
    · obtain ⟨r', d, rfl⟩ := htm
      have hf1 := fixed_timers ids _ _ (fixed_candidate ids _ (fixed_timeOnly ids _ hf e a) ⟨_, ht⟩) ⟨r', d, rfl⟩
      refine ⟨G, Extends.refl G, setLive_inv ids cfg C G hi k _ (campaign_local ids cfg C G hi k ⟨_, ht⟩ _
        hidle hrl rfl hN rfl rfl rfl rfl rfl (fixed_requestVotes ids _ hf1) ?_ ?_)⟩
      · intro j hj
        simp only [requestVotes, candidate, Rust.Slice.fill, Fin.getElem_fin, Vector.getElem_set,
          Vector.getElem_replicate] at hj ⊢
        split at hj
        · omega
        · cases hj
      · intro j; rw [requestVotes_outbox]; rfl

end Jarl.Engine
