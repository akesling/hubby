import Engine.Invariant

/-!
# Frames for preservation proofs

Most actions change one node's volatile state and leave the ghost history
alone; `setLive_inv` reduces the invariant to that node's own clauses.
Extending the ghost history preserves full logs, consistency, kept prefixes
and commitments.
-/

namespace Jarl.Engine
open Jarl

variable {V S : Type} {N CAP : Nat}

theorem setLive_self (C : Cluster V S N CAP) (k : Fin N) (n : Node V S N CAP) : (C.setLive k n).live k = n := by
  simp [Cluster.setLive]

theorem setLive_other (C : Cluster V S N CAP) (k j : Fin N) (n : Node V S N CAP) (h : j ≠ k) :
    (C.setLive k n).live j = C.live j := by
  simp [Cluster.setLive, h]

theorem leaderOk_congr (ids : Vector Id N) (C C' : Cluster V S N CAP) (G : Ghost V N) (j : Fin N)
    (e : C'.live j = C.live j) : LeaderOk ids C G j ↔ LeaderOk ids C' G j := by
  constructor
  · intro ⟨a, b, c, d⟩; exact ⟨by rw [e]; exact a, by rw [e]; exact b, by rw [e]; exact c, by rw [e]; exact d⟩
  · intro ⟨a, b, c, d⟩; exact ⟨by rw [← e]; exact a, by rw [← e]; exact b, by rw [← e]; exact c, by rw [← e]; exact d⟩

/-- The clauses of `Inv` about node `k`, for its new volatile state `n`. -/
structure LocalOk (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (k : Fin N) (n : Node V S N CAP) : Prop where
  fixed : Fixed ids n ∧ n.config = cfg k
  slot : n.local.val = k.val
  live : StateOk G n.state
  clean : n.dirty = false → n.state = C.disk k
  terms : (C.disk k).hard.term.val ≤ n.state.hard.term.val
  consistent : n.role ≠ .Leader → Consistent G (fullLog G n.state)
  acks : ∀ t j, (k, t, j) ∈ G.acks → ∀ j' ≤ j, Kept G k t j' (n.state.hard.term.val + 1) (fullLog G n.state)
  elect : ∀ T eL, G.elect T = some (k, eL) → (C.disk k).hard.term.val < T → n.state.hard.term.val < T →
    fullLog G n.state = eL ∧ n.role ≠ .Leader ∧ n.state.hard.term = (C.disk k).hard.term
  ballots : ∀ T c vlog, (T, k, c, vlog) ∈ G.ballots → n.state.hard.term.val = T →
    n.state.hard.voted_for = some ids[c]
  ballot_cand : n.role = .Candidate → ∀ T w vlog, (T, w, k, vlog) ∈ G.ballots → n.state.hard.term.val = T →
    upToDate (lastOf (fullLog G n.state)) (lastOf vlog)
  elect_cand : ∀ T eL, G.elect T = some (k, eL) → ¬ (n.role = .Candidate ∧ n.state.hard.term.val = T)
  leader : n.role = .Leader → LeaderOk ids (C.setLive k n) G k
  candidate : n.role = .Candidate → CandidateOk ids (C.setLive k n) G k
  outbox : ∀ j o, n.outbox[j] = some o → OutOk ids (C.setLive k n) G k j o
  outbox_self : n.outbox[k] = none
  votes : ∀ env ∈ C.sent, ∀ T last, env.from = ids[k] → env.message = .Vote T last →
    n.role = .Candidate ∧ n.state.hard.term = T → lastId n.state = last
  committed : CommitOk G k n

theorem setLive_inv (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (k : Fin N) (n : Node V S N CAP) (hl : LocalOk ids cfg C G k n) :
    Inv ids cfg (C.setLive k n) G := by
  have live : ∀ j, (C.setLive k n).live j = if j = k then n else C.live j := fun j => rfl
  have leader_eq : ∀ j, j ≠ k → (LeaderOk ids C G j ↔ LeaderOk ids (C.setLive k n) G j) := by
    intro j hj
    exact leaderOk_congr ids C (C.setLive k n) G j (setLive_other C k j n hj)
  refine
    { wf := hi.wf
      fixed := fun j => ?_
      slot := fun j => ?_
      live := fun j => ?_
      disk := hi.disk
      consistent_disk := hi.consistent_disk
      consistent_live := fun j => ?_
      clean := fun j => ?_
      terms := fun j => ?_
      acks := fun w t j h => ?_
      ballots := fun T w c v h => ?_
      ballot_unique := hi.ballot_unique
      ballot_cand := fun T w c v h => ?_
      elect := fun T c eL h hd => ?_
      elect_cand := fun T c eL h => ?_
      leader := fun j => ?_
      candidate := fun j => ?_
      outbox := fun j j' o => ?_
      outbox_self := fun j => ?_
      sent := fun env h => ?_
      committed := fun j => ?_ }
  · by_cases hj : j = k
    · subst hj; rw [setLive_self]; exact hl.fixed
    · rw [setLive_other C k j n hj]; exact hi.fixed j
  · by_cases hj : j = k
    · subst hj; rw [setLive_self]; exact hl.slot
    · rw [setLive_other C k j n hj]; exact hi.slot j
  · by_cases hj : j = k
    · subst hj; rw [setLive_self]; exact hl.live
    · rw [setLive_other C k j n hj]; exact hi.live j
  · by_cases hj : j = k
    · subst hj; rw [setLive_self]; exact hl.consistent
    · rw [setLive_other C k j n hj]; exact hi.consistent_live j
  · by_cases hj : j = k
    · subst hj; rw [setLive_self]; exact hl.clean
    · rw [setLive_other C k j n hj]; exact hi.clean j
  · by_cases hj : j = k
    · subst hj; rw [setLive_self]; exact hl.terms
    · rw [setLive_other C k j n hj]; exact hi.terms j
  · obtain ⟨a, b, c⟩ := hi.acks w t j h
    refine ⟨a, b, fun j' hj' => ⟨?_, (c j' hj').2⟩⟩
    by_cases hw : w = k
    · subst hw; rw [setLive_self]; exact hl.acks t j h j' hj'
    · rw [setLive_other C k w n hw]; exact (c j' hj').1
  · obtain ⟨a, a', b, c⟩ := hi.ballots T w c v h
    refine ⟨a, a', b, ?_⟩
    by_cases hw : w = k
    · subst hw; rw [setLive_self]; exact hl.ballots T _ v h
    · rw [setLive_other C k w n hw]; exact c
  · by_cases hc : c = k
    · subst hc; rw [setLive_self]; intro hr ht; exact hl.ballot_cand hr T w v h ht
    · rw [setLive_other C k c n hc]; exact hi.ballot_cand T w c v h
  · obtain ⟨a, b, c', d⟩ := hi.elect T c eL h hd
    refine ⟨a, b, c', ?_⟩
    by_cases hc : c = k
    · subst hc; rw [setLive_self]; exact hl.elect T eL h hd
    · rw [setLive_other C k c n hc]; exact d
  · by_cases hc : c = k
    · subst hc; rw [setLive_self]; exact hl.elect_cand T eL h
    · rw [setLive_other C k c n hc]; exact hi.elect_cand T c eL h
  · by_cases hj : j = k
    · subst hj; rw [setLive_self]; exact hl.leader
    · rw [setLive_other C k j n hj]; intro hr; exact (leader_eq j hj).mp (hi.leader j hr)
  · by_cases hj : j = k
    · subst hj; rw [setLive_self]; exact hl.candidate
    · rw [setLive_other C k j n hj]; intro hr
      have := hi.candidate j hr
      unfold CandidateOk at this ⊢
      simp only [setLive_other C k j n hj]
      exact this
  · by_cases hj : j = k
    · subst hj; rw [setLive_self]; exact hl.outbox j' o
    · rw [setLive_other C k j n hj]; intro ho
      have := hi.outbox j j' o ho
      unfold OutOk at this ⊢
      simp only [setLive_other C k j n hj]
      exact this
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
      refine ⟨a, ?_, d⟩
      by_cases hck : c = k
      · subst hck; rw [setLive_self]; exact hl.votes env h T last hc hm
      · rw [setLive_other C k c n hck]; exact b
    | _ => intro h2; exact h2
  · refine ⟨(hi.committed j).1, ?_⟩
    by_cases hj : j = k
    · subst hj; rw [setLive_self]; exact hl.committed
    · rw [setLive_other C k j n hj]; exact (hi.committed j).2

end Jarl.Engine
