import Engine.Dyn.World

/-!
# Frames for preservation proofs

Most actions change one node's volatile state and leave the ghost history
alone; `setLive_inv'` reduces the invariant to that node's own clauses
(`LocalOk'`).
-/

set_option linter.unusedSectionVars false

namespace Jarl.Engine.Dyn
open Jarl Jarl.Engine

variable {V S : Type} {MAX CAP K : Nat} [Rust.Clone V] [Rust.Clone S]

theorem setLive_self' (C : World V S MAX CAP K) (k : Fin K) (c : Jarl.Cluster V S MAX CAP) :
    (C.setLive k c).node k = c.node := by simp [World.setLive, World.node]

theorem setLive_other' (C : World V S MAX CAP K) (k j : Fin K) (c : Jarl.Cluster V S MAX CAP) (h : j ≠ k) :
    (C.setLive k c).node j = C.node j := by simp [World.setLive, World.node, h]

theorem setLive_disk (C : World V S MAX CAP K) (k : Fin K) (c : Jarl.Cluster V S MAX CAP) :
    (C.setLive k c).disk = C.disk := rfl

theorem setLive_sent (C : World V S MAX CAP K) (k : Fin K) (c : Jarl.Cluster V S MAX CAP) :
    (C.setLive k c).sent = C.sent := rfl

variable (ids : Vector Id K) (g : Membership MAX)

/-- The clauses of `Inv` about node `k`, for its new volatile state `c.node`. -/
structure LocalOk' (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (k : Fin K) (c : Jarl.Cluster V S MAX CAP) : Prop where
  dyn : DynOk g ids[k] c.node
  live : StateOk G c.node.state ∧ SnapOk g G c.node.state
  consistent : Consistent G (fullLog G c.node.state) ∨ (c.node.dirty = true ∧ Leading G k c.node) ∨
    PendingWin ids g (C.setLive k c) G k c.node
  clean : c.node.dirty = false → c.node.state = C.disk k
  terms : (C.disk k).hard.term.val ≤ c.node.state.hard.term.val
  acks : ∀ t j, (k, t, j) ∈ G.acks → ∀ j' ≤ j, Kept G k t j' (c.node.state.hard.term.val + 1) (fullLog G c.node.state)
  ballots : ∀ T c' vlog, (T, k, c', vlog) ∈ G.ballots → c.node.state.hard.term.val = T →
    c.node.state.hard.voted_for = some ids[c']
  ballot_cand : c.node.role = .Candidate → ∀ T w vlog, (T, w, k, vlog) ∈ G.ballots → c.node.state.hard.term.val = T →
    upToDate (lastOf (fullLog G c.node.state)) (lastOf vlog)
  elect : ∀ T eL, G.elect T = some (k, eL) → (C.disk k).hard.term.val < T → c.node.state.hard.term.val < T →
    fullLog G c.node.state = eL ∧ c.node.role ≠ .Leader ∧ c.node.state.hard.term = (C.disk k).hard.term
  elect_cand : ∀ T eL, G.elect T = some (k, eL) → ¬ (c.node.role = .Candidate ∧ c.node.state.hard.term.val = T)
  lead : Leading G k c.node → LeadLog ids g G k c.node
  leader : c.node.role = .Leader → (Leading G k c.node ∨ PendingWin ids g (C.setLive k c) G k c.node) ∧ LeaderOk' ids G k c.node
  candidate : c.node.role = .Candidate → CandidateOk' ids G k c.node
  outbox : ∀ (i : Fin MAX) o, c.node.outbox[i] = some o → ∃ to, c.node.peers[i] = some to ∧ OutOk ids g (C.setLive k c) G k to o
  outbox_self : ∀ (h : c.node.local.val < MAX) o, c.node.outbox[c.node.local.val] = some o → ∃ i r, o = .Replicated i r
  extra : ∀ to o, c.node.extra_reply = some (to, o) → OutOk ids g (C.setLive k c) G k to o
  votes : ∀ env ∈ C.sent, ∀ T last, env.from = ids[k] → env.message = .Vote T last →
    c.node.role = .Candidate ∧ c.node.state.hard.term = T → lastId c.node.state = last
  committed : CommitOk' ids g (C.setLive k c) G k c.node

/-- A pending win depends only on the node's own saved checkpoint. -/
theorem pendingWin_setLive (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (k j : Fin K)
    (c : Jarl.Cluster V S MAX CAP) (n : DNode V S MAX CAP) :
    PendingWin ids g (C.setLive k c) G j n ↔ PendingWin ids g C G j n := by
  unfold PendingWin; simp only [setLive_disk]

theorem outOk_other (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (k j : Fin K) (c : Jarl.Cluster V S MAX CAP)
    (h : j ≠ k) (to : Id) (o : Outbound) : OutOk ids g (C.setLive k c) G j to o ↔ OutOk ids g C G j to o := by
  unfold OutOk; simp only [setLive_other' C k j c h, setLive_sent, pendingWin_setLive]

theorem setLive_inv' (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K)
    (hi : Inv ids g C G) (k : Fin K) (c : Jarl.Cluster V S MAX CAP) (hl : LocalOk' ids g C G k c) :
    Inv ids g (C.setLive k c) G := by
  refine
    { wf := hi.wf
      cfgs := hi.cfgs
      dyn := fun j => ?_
      live := fun j => ?_
      disk := hi.disk
      consistent_disk := hi.consistent_disk
      consistent_live := fun j => ?_
      clean := fun j => ?_
      terms := fun j => ?_
      disk_lead := hi.disk_lead
      acks := fun w t j h => ?_
      ballots := fun T w c v h => ?_
      ballot_unique := hi.ballot_unique
      ballot_cand := fun T w c v h => ?_
      elect := fun T c eL h hd => ?_
      elect_disk := hi.elect_disk
      elect_cand := fun T c eL h => ?_
      lead := fun j => ?_
      leader := fun j => ?_
      candidate := fun j => ?_
      outbox := fun j i o => ?_
      outbox_self := fun j => ?_
      extra := fun j to o => ?_
      sent := fun env h => ?_
      committed := fun j => ?_ }
  · by_cases hj : j = k
    · subst hj; simp only [setLive_self']; exact hl.dyn
    · simp only [setLive_other' C k j c hj]; exact hi.dyn j
  · by_cases hj : j = k
    · subst hj; simp only [setLive_self']; exact hl.live
    · simp only [setLive_other' C k j c hj]; exact hi.live j
  · by_cases hj : j = k
    · subst hj; simp only [setLive_self']; exact hl.consistent
    · simp only [setLive_other' C k j c hj]; exact hi.consistent_live j
  · by_cases hj : j = k
    · subst hj; simp only [setLive_self']; exact hl.clean
    · simp only [setLive_other' C k j c hj]; exact hi.clean j
  · by_cases hj : j = k
    · subst hj; simp only [setLive_self']; exact hl.terms
    · simp only [setLive_other' C k j c hj]; exact hi.terms j
  · obtain ⟨a, b, d⟩ := hi.acks w t j h
    refine ⟨a, b, fun j' hj' => ⟨?_, (d j' hj').2⟩⟩
    by_cases hw : w = k
    · subst hw; rw [setLive_self']; exact hl.acks t j h j' hj'
    · rw [setLive_other' C k w c hw]; exact (d j' hj').1
  · obtain ⟨a, a', b, d⟩ := hi.ballots T w c v h
    refine ⟨a, a', b, ?_⟩
    by_cases hw : w = k
    · subst hw; rw [setLive_self']; exact hl.ballots T c v h
    · rw [setLive_other' C k w _ hw]; exact d
  · by_cases hc : c = k
    · subst hc; rw [setLive_self']; intro hr ht; exact hl.ballot_cand hr T w v h ht
    · rw [setLive_other' C k c _ hc]; exact hi.ballot_cand T w c v h
  · obtain ⟨a, b, c', d⟩ := hi.elect T c eL h hd
    refine ⟨a, b, c', ?_⟩
    by_cases hc : c = k
    · subst hc; rw [setLive_self']; exact hl.elect T eL h hd
    · rw [setLive_other' C k c _ hc]; exact d
  · by_cases hc : c = k
    · subst hc; rw [setLive_self']; exact hl.elect_cand T eL h
    · rw [setLive_other' C k c _ hc]; exact hi.elect_cand T c eL h
  · by_cases hj : j = k
    · subst hj; simp only [setLive_self']; exact hl.lead
    · simp only [setLive_other' C k j c hj]; exact hi.lead j
  · by_cases hj : j = k
    · subst hj; simp only [setLive_self']; exact hl.leader
    · simp only [setLive_other' C k j c hj]; exact hi.leader j
  · by_cases hj : j = k
    · subst hj; simp only [setLive_self']; exact hl.candidate
    · simp only [setLive_other' C k j c hj]; exact hi.candidate j
  · by_cases hj : j = k
    · subst hj; simp only [setLive_self']; intro ho; exact hl.outbox i o ho
    · simp only [setLive_other' C k j c hj]; intro ho; obtain ⟨to, h1, h2⟩ := hi.outbox j i o ho; exact ⟨to, h1, (outOk_other ids g C G k j c hj to o).mpr h2⟩
  · by_cases hj : j = k
    · subst hj; simp only [setLive_self']; exact hl.outbox_self
    · simp only [setLive_other' C k j c hj]; exact hi.outbox_self j
  · by_cases hj : j = k
    · subst hj; simp only [setLive_self']; intro ho; exact hl.extra to o ho
    · simp only [setLive_other' C k j c hj]; intro ho; exact (outOk_other ids g C G k j c hj to o).mpr (hi.extra j to o ho)
  · have := hi.sent env h
    unfold SentOk at this ⊢
    refine ⟨this.1, ?_⟩
    have h2 := this.2
    revert h2
    cases hm : env.message with
    | Vote T last =>
      intro h2 c' hc
      obtain ⟨a, b, d⟩ := h2 c' hc
      refine ⟨a, ?_, d⟩
      by_cases hck : c' = k
      · subst hck; rw [setLive_self']; exact hl.votes env h T last hc hm
      · rw [setLive_other' C k c' _ hck]; exact b
    | _ => intro h2; exact h2
  · by_cases hj : j = k
    · subst hj; simp only [setLive_self']; exact ⟨(hi.committed j).1, hl.committed⟩
    · simp only [setLive_other' C k j c hj]; exact hi.committed j

end Jarl.Engine.Dyn
