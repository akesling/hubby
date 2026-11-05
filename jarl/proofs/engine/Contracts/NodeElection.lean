import Generated

/-!
Exact whole-body effects of `node::Node::reset_election` and `node::Node::follow`
over Provium's typed translation. Each theorem gives the complete resulting
receiver record as `{ self with ... }`, so every field it does not name is
unchanged. Premise: a positive election timeout of at most `2^63`.
-/

namespace Jarl.Contracts.NodeElection

/-- The advanced SplitMix64 state (https://prng.di.unimi.it/splitmix64.c). -/
def advance (random : Nat) : Nat := (random + 0x9e3779b97f4a7c15) % 2^64

/-- SplitMix64's 30/27/31 xor-shift-multiply mix of an advanced state. -/
def mix (z : Nat) : Nat :=
  let z := ((z ^^^ (z / 2^30)) * 0xbf58476d1ce4e5b9) % 2^64
  let z := ((z ^^^ (z / 2^27)) * 0x94d049bb133111eb) % 2^64
  z ^^^ (z / 2^31)

private theorem xor_shr_val (a : Rust.u64) (k : Nat) :
    (Rust.xor a (Rust.shrK a k)).val = a.val ^^^ (a.val / 2^k) := by
  have h1 : a.val / 2^k < 2^64 := Nat.lt_of_le_of_lt (Nat.div_le_self _ _) a.isLt
  have h2 := Nat.xor_lt_two_pow a.isLt h1
  simp only [Rust.xor, Rust.shrK, Nat.shiftRight_eq_div_pow]
  exact Nat.mod_eq_of_lt h2

/-- The sampled value computed by the body equals `mix (advance random)`. -/
private theorem sample_val (r : Rust.u64) :
    (Rust.xor
      (Rust.wrapping_mul
        (Rust.xor
          (Rust.wrapping_mul
            (Rust.xor (Rust.wrapping_add r 11400714819323198485)
              (Rust.shrK (Rust.wrapping_add r 11400714819323198485) 30))
            13787848793156543929)
          (Rust.shrK
            (Rust.wrapping_mul
              (Rust.xor (Rust.wrapping_add r 11400714819323198485)
                (Rust.shrK (Rust.wrapping_add r 11400714819323198485) 30))
              13787848793156543929) 27))
        10723151780598845931)
      (Rust.shrK
        (Rust.wrapping_mul
          (Rust.xor
            (Rust.wrapping_mul
              (Rust.xor (Rust.wrapping_add r 11400714819323198485)
                (Rust.shrK (Rust.wrapping_add r 11400714819323198485) 30))
              13787848793156543929)
            (Rust.shrK
              (Rust.wrapping_mul
                (Rust.xor (Rust.wrapping_add r 11400714819323198485)
                  (Rust.shrK (Rust.wrapping_add r 11400714819323198485) 30))
                13787848793156543929) 27))
          10723151780598845931) 31)).val = mix (advance r.val) := by
  simp only [xor_shr_val, Rust.wrapping_mul, Rust.val_wrapping_add, mix, advance]
  rfl

theorem advance_lt (random : Nat) : advance random < 2^64 := Nat.mod_lt _ (by decide)

/-- The body of `reset_election` when it returns: the generator advanced, a deadline
    `ticks + mix (advance random) % ticks` and a restarted elapsed count. -/
theorem reset_election_exact {V S : Type} {N CAP : Nat} [Rust.Clone V] [Rust.Clone S]
    (n : Node V S N CAP)
    (positive : 0 < n.config.election_ticks.val) (safe : n.config.election_ticks.val ≤ 2^63) :
    Node.reset_election n = pure { n with
      random := Rust.ofNat (advance n.random.val),
      election_deadline := Rust.ofNat
        (n.config.election_ticks.val + mix (advance n.random.val) % n.config.election_ticks.val),
      elapsed := 0 } := by
  unfold Node.reset_election
  simp only [bind_pure_comp]
  rw [Rust.rem_ok _ _ (by omega)]
  simp only [pure_bind]
  have hm := Nat.mod_lt (mix (advance n.random.val)) positive
  rw [Rust.add_ok _ _ (by simp only [sample_val]; omega)]
  simp only [map_pure]
  refine congrArg pure ?_
  simp only [Node.mk.injEq, true_and, and_true]
  refine ⟨?_, ?_⟩
  · apply Fin.ext
    simp only [Rust.ofNat, Fin.val_mk, sample_val]
    rw [Nat.mod_eq_of_lt (show n.config.election_ticks.val +
      mix (advance n.random.val) % n.config.election_ticks.val < 2^64 by omega)]
  · apply Fin.ext
    simp only [Rust.ofNat, Fin.val_mk, Rust.val_wrapping_add]
    rw [Nat.mod_eq_of_lt (advance_lt _)]
    rfl

/-- `follow` steps down: Follower role, no pre-vote, the given leader, a restarted
    leader age when a leader is known, and a fresh election timer. -/
theorem follow_exact {V S : Type} {N CAP : Nat} [Rust.Clone V] [Rust.Clone S]
    (n : Node V S N CAP) (leader : Option Id)
    (positive : 0 < n.config.election_ticks.val) (safe : n.config.election_ticks.val ≤ 2^63) :
    Node.follow n leader = pure { n with
      role := Role.Follower,
      prevoting := none,
      leader := leader,
      leader_age := if leader.isSome then 0 else n.leader_age,
      random := Rust.ofNat (advance n.random.val),
      election_deadline := Rust.ofNat
        (n.config.election_ticks.val + mix (advance n.random.val) % n.config.election_ticks.val),
      elapsed := 0 } := by
  unfold Node.follow
  cases leader with
  | none =>
    simp only [Option.isSome_none, Bool.false_eq_true, if_false, bind_pure]
    exact reset_election_exact _ positive safe
  | some l =>
    simp only [Option.isSome_some, if_true, bind_pure]
    exact reset_election_exact _ positive safe

end Jarl.Contracts.NodeElection
