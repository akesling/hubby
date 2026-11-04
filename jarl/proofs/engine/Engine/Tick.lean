import Engine.Host

/-!
# `tick`: local time on a fixed node

A tick advances timers; a leader whose heartbeat is due appends a barrier when
needed and replicates; a follower or candidate whose election deadline passed
starts a campaign for the next term.
-/

namespace Jarl.Engine
open Jarl

variable {V S : Type} {N CAP : Nat}

/-- Only the elapsed-time counters differ. -/
def TimeOnly (n n' : Node V S N CAP) : Prop :=
  ∃ e a, n' = { n with elapsed := e, leader_age := a }

/-- The result of `campaign(t)` from `n` (see `campaign_rel`). -/
def Campaigned (n : Node V S N CAP) (t : Rust.u64) (h : n.local.val < N) (n' : Node V S N CAP) : Prop :=
  ∃ n1, Timers (candidate n t h) n1 ∧
    ((N / 2 < 1 ∧ BecomeLeader n1 n') ∨ (¬ N / 2 < 1 ∧ n' = requestVotes n1))

inductive Ticked (n : Node V S N CAP) : Node V S N CAP → Prop
  | same : Ticked n n
  | time (n' : Node V S N CAP) : Idle n → TimeOnly n n' → Ticked n n'
  | heartbeat (n0 n2 : Node V S N CAP) : Idle n → n.role = .Leader → TimeOnly n n0 →
      Barrier n0 n2 → Ticked n (bcast n2)
  | campaign (n0 n' : Node V S N CAP) (h : n0.local.val < N) : Idle n → n.role ≠ .Leader → TimeOnly n n0 →
      (ht : n.state.hard.term.val + 1 < 2 ^ 64) →
      Campaigned n0 ⟨n.state.hard.term.val + 1, ht⟩ h n' → Ticked n n'

theorem fixed_timeOnly (ids : Vector Id N) (n : Node V S N CAP) (hf : Fixed ids n) (e a : Rust.u64) :
    Fixed ids { n with elapsed := e, leader_age := a } := { hf with layout := hf.layout, contig := hf.contig }

theorem tick_rel (ids : Vector Id N) (n : Node V S N CAP) (hf : Fixed ids n)
    (r : Rust.Result Unit Error) (n' : Node V S N CAP) (h : Node.tick n = pure (r, n')) : Ticked n n' := by
  unfold Node.tick at h
  cases hav : Node.available n with
  | Err e =>
    simp only [hav] at h
    have := pure_inj h
    cases this
    exact Ticked.same
  | Ok u =>
    have hidle := idle_of_available n hav
    have hhk : n.hooks.isSome = false := by simp [hf.hooks]
    simp only [hav, pure_bind, hhk, Bool.false_and, Bool.false_eq_true, if_false] at h
    by_cases hl : n.role = Role.Leader
    · have hl1 : (n.role == Role.Leader) = true := by simp [hl]
      simp only [hl1, if_true] at h
      by_cases hb : Rust.saturating_add n.elapsed 1 ≥ n.config.heartbeat_ticks
      · simp only [hb, decide_true, if_true] at h
        have hf0 := fixed_timeOnly ids n hf 0 (Rust.saturating_add n.leader_age 1)
        obtain ⟨n2, hbar, hB⟩ := barrier_rel ids _ hf0
        rw [hbar] at h
        simp only [pure_bind, broadcast_eq ids n2 (fixed_barrier ids _ n2 hf0 hB)] at h
        have := pure_inj h
        cases this
        exact Ticked.heartbeat _ n2 hidle hl ⟨_, _, rfl⟩ hB
      · simp only [hb, decide_false, Bool.false_eq_true, if_false] at h
        have := pure_inj h
        cases this
        exact Ticked.time _ hidle ⟨_, _, rfl⟩
    · have hl' : (n.role == Role.Leader) = false := by
        cases hr : n.role <;> simp_all
      have hv : n.membership.is_voter n.config.id = true := by
        rw [hf.membership, stable_is_voter, ← hf.local_id]; simp
      simp only [hl', Bool.false_eq_true, if_false, hv, Bool.true_and] at h
      by_cases he : Rust.saturating_add n.elapsed 1 ≥ n.election_deadline
      · simp only [he, decide_true, if_true] at h
        by_cases ht : n.state.hard.term.val + (1 : Rust.u64).val < 2 ^ 64
        · simp only [Rust.checked_add_eq, dif_pos ht, Rust.Option.ok_or] at h
          have hf0 := fixed_timeOnly ids n hf (Rust.saturating_add n.elapsed 1) (Rust.saturating_add n.leader_age 1)
          obtain ⟨n1, hc, hC⟩ := campaign_rel ids _ hf0 ⟨n.state.hard.term.val + (1 : Rust.u64).val, ht⟩
          rw [hc] at h
          simp only [pure_bind] at h
          have := pure_inj h
          cases this
          have ht' : n.state.hard.term.val + 1 < 2 ^ 64 := by simpa using ht
          exact Ticked.campaign _ _ hf0.local_lt hidle hl ⟨_, _, rfl⟩ ht' hC
        · simp only [Rust.checked_add_eq, dif_neg ht, Rust.Option.ok_or] at h
          have := pure_inj h
          cases this
          exact Ticked.time _ hidle ⟨_, _, rfl⟩
      · simp only [he, decide_false, Bool.false_eq_true, if_false] at h
        have := pure_inj h
        cases this
        exact Ticked.time _ hidle ⟨_, _, rfl⟩

end Jarl.Engine
