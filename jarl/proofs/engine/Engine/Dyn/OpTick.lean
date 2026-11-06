import Engine.Dyn.Spec

/-!
# `tick` on a dynamic node
-/

set_option linter.unusedSectionVars false

namespace Jarl.Engine.Dyn
open Jarl Jarl.Engine

variable {V S : Type} {MAX CAP : Nat} [Rust.Clone V] [Rust.Clone S]

/-- The pre-vote loop queues `PreVote t` for every other slot whose identity votes. -/
theorem pre_votes_eq (n : DNode V S MAX CAP) (t : Rust.u64) (hMAX : MAX < 2 ^ Rust.usizeBits) :
    forIn (Rust.Iter.range 0 (Rust.usizeOf MAX)) n (fun peer_1 (s : DNode V S MAX CAP) =>
      if (peer_1 != s.«local») = true then do
        let t9 ← Rust.Slice.index s.peers peer_1
        if (Rust.Option.is_some_and t9 fun id_1 => s.membership.is_voter id_1) = true then do
            let m_5 ← s.send peer_1 (Outbound.PreVote t)
            pure (ForInStep.yield m_5)
          else pure (ForInStep.yield s)
      else pure (ForInStep.yield s)) = pure (preVotesD n t) := by
  refine Rust.forIn_eq_inv _ _ _ _
    (fun k b => b = { n with outbox := Vector.ofFn fun j => if j.val < k ∧ (j.val ≠ n.local.val ∧ Rust.Option.is_some_and n.peers[j] (fun id => Membership.is_voter n.membership id) = true) then some (.PreVote t) else n.outbox[j] }) ?_ ?_ ?_
  · have : (Vector.ofFn fun j : Fin MAX => if j.val < 0 ∧ (j.val ≠ n.local.val ∧ Rust.Option.is_some_and n.peers[j] (fun id => Membership.is_voter n.membership id) = true) then some (Outbound.PreVote t) else n.outbox[j]) = n.outbox := by
      ext j hj; simp
    rw [this]
  · intro k hk b hb
    obtain ⟨hget, hkN⟩ := range_get MAX hMAX k hk
    rw [hget]
    have hv : (Rust.ofNat k : Rust.usize).val = k := by simp [Rust.ofNat]; uomega
    rw [hb]
    by_cases hkl : k = n.local.val
    · refine ⟨_, ?_, rfl⟩
      have : (Rust.ofNat k : Rust.usize) = n.local := Fin.ext (by rw [hv, hkl])
      simp only [this, bne_self_eq_false, Bool.false_eq_true, if_false]
      congr 3
      ext j hj
      simp only [Vector.getElem_ofFn]
      by_cases hjk : j = k
      · subst hjk; simp [hkl]
      · have hlt : j < k ↔ j < k + 1 := by omega
        simp only [hlt]
    · have hne : (Rust.ofNat k : Rust.usize) ≠ n.local := fun e => hkl (by rw [← hv, e])
      have hp : (Rust.ofNat k : Rust.usize).val < MAX := by rw [hv]; exact hkN
      by_cases hcont : Rust.Option.is_some_and n.peers[k] (fun id => Membership.is_voter n.membership id) = true
      · refine ⟨_, ?_, rfl⟩
        simp only [bne_iff_ne, ne_eq, hne, not_false_eq_true, if_true, Rust.Slice.index_ok _ _ hp,
          pure_bind, hv, hcont, send_eq _ _ _ hMAX hp]
        congr 3
        ext j hj
        simp only [Vector.getElem_set, Vector.getElem_ofFn]
        split
        · rename_i h; subst h; simp [hkl, hcont]
        · rename_i hjk
          have hlt : j < k ↔ j < k + 1 := by omega
          simp only [hlt]
      · refine ⟨_, ?_, rfl⟩
        have hf : Rust.Option.is_some_and n.peers[k] (fun id => Membership.is_voter n.membership id) = false := by
          simpa using hcont
        simp only [bne_iff_ne, ne_eq, hne, not_false_eq_true, if_true, Rust.Slice.index_ok _ _ hp,
          pure_bind, hv, hf, Bool.false_eq_true, if_false]
        congr 3
        ext j hj
        simp only [Vector.getElem_ofFn]
        by_cases hjk : j = k
        · subst hjk; simp [hf]
        · have hlt : j < k ↔ j < k + 1 := by omega
          simp only [hlt]
  · intro b hb
    rw [hb]; unfold preVotesD
    congr 1
    ext j hj
    simp [Rust.Iter.range, Rust.val_usizeOf _ hMAX]

theorem pre_timeOnly (n : DNode V S MAX CAP) (hp : Pre n) (e a q : Rust.u64) (act : Vector Bool MAX) :
    Pre { n with elapsed := e, leader_age := a, quorum_elapsed := q, active := act } :=
  { hp with layout := hp.layout, contig := hp.contig, uniq := hp.uniq }

theorem tick_rel' (n : DNode V S MAX CAP) (hp : Pre n) (r : Rust.Result Unit Error) (n' : DNode V S MAX CAP)
    (h : Node.tick n = pure (r, n')) : TickedD n n' := by
  unfold Node.tick at h
  cases hav : Node.available n with
  | Err e =>
    simp only [hav] at h
    cases Rust.pure_inj h
    exact TickedD.same
  | Ok u =>
    have hidle := idle_of_available n (by cases u; exact hav)
    have hhk : n.hooks.isSome = true := by simp [hp.hooks]
    simp only [hav, pure_bind, hhk, Bool.true_and] at h
    by_cases hl : n.role = Role.Leader
    · have hl1 : (n.role == Role.Leader) = true := by simp [hl]
      simp only [hl1, if_true] at h
      by_cases hq : Rust.saturating_add n.quorum_elapsed 1 ≥ n.config.election_ticks
      · simp only [hq, decide_true, if_true] at h
        obtain ⟨b, -, h⟩ := Rust.bind_eq_pure h
        cases b
        · simp only [Bool.not_false, if_true] at h
          obtain ⟨m, hm, h⟩ := Rust.bind_eq_pure h
          cases Rust.pure_inj h
          have hp0 := pre_timeOnly n hp (Rust.saturating_add n.elapsed 1) (Rust.saturating_add n.leader_age 1) 0 (Rust.Slice.fill n.active false)
          obtain ⟨m', hf, hT⟩ := follow_eq' _ hp0.e0 hp0.e1 none
          have : n' = m' := Rust.pure_inj (hm.symm.trans hf)
          subst this
          exact TickedD.stepdown _ _ hidle hl ⟨_, _, _, _, rfl⟩ (by simpa using hT)
        · simp only [Bool.not_true, Bool.false_eq_true, if_false] at h
          have hp0 := pre_timeOnly n hp 0 (Rust.saturating_add n.leader_age 1) 0 (Rust.Slice.fill n.active false)
          by_cases he : Rust.saturating_add n.elapsed 1 ≥ n.config.heartbeat_ticks
          · simp only [he, decide_true, if_true] at h
            obtain ⟨m1, hm1, h⟩ := Rust.bind_eq_pure h
            have hB := barrier_rel' _ _ hp0 hm1
            rw [broadcast_eq' _ hp.n_lt, pure_bind] at h
            cases Rust.pure_inj h
            exact TickedD.heartbeat _ _ hidle hl ⟨_, _, _, _, rfl⟩ hB
          · simp only [he, decide_false, Bool.false_eq_true, if_false] at h
            cases Rust.pure_inj h
            exact TickedD.time _ hidle ⟨_, _, _, _, rfl⟩
      · simp only [hq, decide_false, Bool.false_eq_true, if_false] at h
        have hp0 := pre_timeOnly n hp 0 (Rust.saturating_add n.leader_age 1) (Rust.saturating_add n.quorum_elapsed 1) n.active
        by_cases he : Rust.saturating_add n.elapsed 1 ≥ n.config.heartbeat_ticks
        · simp only [he, decide_true, if_true] at h
          obtain ⟨m1, hm1, h⟩ := Rust.bind_eq_pure h
          have hB := barrier_rel' _ _ hp0 hm1
          rw [broadcast_eq' _ hp.n_lt, pure_bind] at h
          cases Rust.pure_inj h
          exact TickedD.heartbeat _ _ hidle hl ⟨_, _, _, _, rfl⟩ hB
        · simp only [he, decide_false, Bool.false_eq_true, if_false] at h
          cases Rust.pure_inj h
          exact TickedD.time _ hidle ⟨_, _, _, _, rfl⟩
    · have hl' : (n.role == Role.Leader) = false := by
        cases hr : n.role <;> simp_all
      simp only [hl', Bool.false_eq_true, if_false] at h
      by_cases hv : (n.membership.is_voter n.config.id && decide (Rust.saturating_add n.elapsed 1 ≥ n.election_deadline)) = true
      · rw [if_pos hv] at h
        have hvoter : n.membership.is_voter n.config.id = true := by
          simp only [Bool.and_eq_true] at hv; exact hv.1
        by_cases ht : n.state.hard.term.val + (1 : Rust.u64).val < 2 ^ 64
        · simp only [Rust.checked_add_eq, dif_pos ht, Rust.Option.ok_or, if_true] at h
          have ht' : n.state.hard.term.val + 1 < 2 ^ 64 := by simpa using ht
          have hp0 := pre_timeOnly n hp (Rust.saturating_add n.elapsed 1) (Rust.saturating_add n.leader_age 1) n.quorum_elapsed n.active
          obtain ⟨t7, ht7, h⟩ := Rust.bind_eq_pure h
          have hlt : n.local.val < MAX := by
            apply Classical.byContradiction; intro hge
            simp only [Rust.Slice.set, hge, dite_false] at ht7
            exact fail_ne_pure' _ _ ht7
          rw [Rust.Slice.set_ok _ _ _ hlt] at ht7
          cases Rust.pure_inj ht7
          obtain ⟨m3, hm3, h⟩ := Rust.bind_eq_pure h
          let n0 : DNode V S MAX CAP := { n with elapsed := Rust.saturating_add n.elapsed 1, leader_age := Rust.saturating_add n.leader_age 1, quorum_elapsed := n.quorum_elapsed, active := n.active }
          obtain ⟨n2, hr, hT⟩ := reset_timers' (prevotingD n0 ⟨n.state.hard.term.val + 1, ht'⟩ hlt) hp0.e0 hp0.e1
          have : m3 = n2 := Rust.pure_inj (hm3.symm.trans hr)
          subst this
          have hpp : Pre (prevotingD n0 ⟨n.state.hard.term.val + 1, ht'⟩ hlt) :=
            { hp with layout := hp.layout, contig := hp.contig, uniq := hp.uniq }
          have hp2 := pre_timers _ _ hpp hT
          obtain ⟨b, hq, hb⟩ := election_quorum_eq' m3 hp.n_lt
          rw [hq, pure_bind] at h
          cases b
          · simp only [Bool.false_eq_true, if_false] at h
            obtain ⟨m, hm, h⟩ := Rust.bind_eq_pure h
            cases Rust.pure_inj h
            have hpv := pre_votes_eq m3 ⟨n.state.hard.term.val + 1, ht'⟩ hp.n_lt
            have : n' = preVotesD m3 ⟨n.state.hard.term.val + 1, ht'⟩ := Rust.pure_inj (hm.symm.trans hpv)
            subst this
            exact TickedD.prevote n0 m3 _ hlt ht' hidle hl hvoter ⟨_, _, _, _, rfl⟩ hT
              (Or.inr ⟨fun hQ => by simpa using hb.mpr hQ, rfl⟩)
          · simp only [if_true] at h
            obtain ⟨m, hm, h⟩ := Rust.bind_eq_pure h
            cases Rust.pure_inj h
            exact TickedD.prevote n0 m3 _ hlt ht' hidle hl hvoter ⟨_, _, _, _, rfl⟩ hT
              (Or.inl ⟨hb.mp rfl, campaign_rel' _ _ hp2 _ hm⟩)
        · simp only [Rust.checked_add_eq, dif_neg ht, Rust.Option.ok_or] at h
          cases Rust.pure_inj h
          exact TickedD.time _ hidle ⟨_, _, _, _, rfl⟩
      · rw [if_neg hv] at h
        cases Rust.pure_inj h
        exact TickedD.time _ hidle ⟨_, _, _, _, rfl⟩

end Jarl.Engine.Dyn
