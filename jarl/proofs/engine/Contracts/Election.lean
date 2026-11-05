import Contracts.NodeElection

/-!
Successful-state projections of `node::Node::reset_election` over Provium's typed
translation: exact wrapping seed advance, zero elapsed time, and a deadline in
`[ticks, 2*ticks)` given by SplitMix64. Premise: `0 < ticks ≤ 2^63` where `ticks`
is the configured election timeout. The body returns (no panic, no divergence)
under that premise, and the returned receiver has the stated fields.
-/

namespace Jarl.Contracts.Election

open Jarl.Contracts.NodeElection (reset_election_exact)

/-- SplitMix64 (https://prng.di.unimi.it/splitmix64.c): advance the state by
    the golden-ratio increment, then apply the 30/27/31 xor-shift-multiply mix. -/
def splitMix64 (state : Nat) : Nat :=
  let z := (state + 0x9e3779b97f4a7c15) % 2^64
  let z := ((z ^^^ (z / 2^30)) * 0xbf58476d1ce4e5b9) % 2^64
  let z := ((z ^^^ (z / 2^27)) * 0x94d049bb133111eb) % 2^64
  z ^^^ (z / 2^31)

private theorem splitMix64_eq (state : Nat) : splitMix64 state = NodeElection.mix (NodeElection.advance state) := rfl

theorem elapsed_reset {V S : Type} {N CAP : Nat} [Rust.Clone V] [Rust.Clone S]
    (n : Node V S N CAP)
    (positive : 0 < n.config.election_ticks.val) (safe : n.config.election_ticks.val ≤ 2^63) :
    ∃ n', Node.reset_election n = pure n' ∧ n'.elapsed = 0 :=
  ⟨_, reset_election_exact n positive safe, rfl⟩

theorem deadline_range {V S : Type} {N CAP : Nat} [Rust.Clone V] [Rust.Clone S]
    (n : Node V S N CAP)
    (positive : 0 < n.config.election_ticks.val) (safe : n.config.election_ticks.val ≤ 2^63) :
    ∃ n', Node.reset_election n = pure n' ∧
      n.config.election_ticks.val ≤ n'.election_deadline.val ∧
      n'.election_deadline.val < 2 * n.config.election_ticks.val := by
  refine ⟨_, reset_election_exact n positive safe, ?_⟩
  have hm := Nat.mod_lt (NodeElection.mix (NodeElection.advance n.random.val)) positive
  simp only [Rust.ofNat]
  rw [Nat.mod_eq_of_lt (show n.config.election_ticks.val +
    NodeElection.mix (NodeElection.advance n.random.val) % n.config.election_ticks.val < 2^64 by omega)]
  omega

/-- Exact, not just the range: removing or changing the jitter fails this. -/
theorem deadline_exact {V S : Type} {N CAP : Nat} [Rust.Clone V] [Rust.Clone S]
    (n : Node V S N CAP)
    (positive : 0 < n.config.election_ticks.val) (safe : n.config.election_ticks.val ≤ 2^63) :
    ∃ n', Node.reset_election n = pure n' ∧
      n'.election_deadline.val =
        n.config.election_ticks.val + splitMix64 n.random.val % n.config.election_ticks.val := by
  refine ⟨_, reset_election_exact n positive safe, ?_⟩
  have hm := Nat.mod_lt (NodeElection.mix (NodeElection.advance n.random.val)) positive
  simp only [Rust.ofNat, splitMix64_eq]
  exact Nat.mod_eq_of_lt (by omega)

theorem random_advanced {V S : Type} {N CAP : Nat} [Rust.Clone V] [Rust.Clone S]
    (n : Node V S N CAP)
    (positive : 0 < n.config.election_ticks.val) (safe : n.config.election_ticks.val ≤ 2^63) :
    ∃ n', Node.reset_election n = pure n' ∧
      n'.random.val = (n.random.val + 11400714819323198485) % 2^64 := by
  refine ⟨_, reset_election_exact n positive safe, ?_⟩
  simp only [Rust.ofNat]
  rw [Nat.mod_eq_of_lt (Jarl.Contracts.NodeElection.advance_lt _)]
  rfl

end Jarl.Contracts.Election
