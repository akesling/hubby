import Generated
open Provium
namespace JarlProofs

-- Inputs are mathematical naturals constrained to the actual Rust word range.
-- Theorems mention generated functions, not a separately implemented algorithm.
private theorem half_bound (n : Nat) (h : n < 2^JarlRules.proviumUsizeBits) : n / 2 < 2^JarlRules.proviumUsizeBits := by omega

theorem majority_strict (count total : Nat)
    (hc : count < 2^JarlRules.proviumUsizeBits) (ht : total < 2^JarlRules.proviumUsizeBits) :
    JarlRules.majority [.uint JarlRules.proviumUsizeBits count, .uint JarlRules.proviumUsizeBits total] =
      .ok (.boolean (decide (total < 2 * count))) := by
  have hd := half_bound total ht
  simp only [JarlRules.proviumUsizeBits] at *
  simp [JarlRules.majority, validArgs, validWidth, Provium.get, Provium.bind,
    binary, uintOp, word, hc, ht, hd]
  omega

theorem majority_cardinality_overlap (a b total : Nat)
    (ha : a < 2^JarlRules.proviumUsizeBits) (hb : b < 2^JarlRules.proviumUsizeBits) (ht : total < 2^JarlRules.proviumUsizeBits)
    (qa : JarlRules.majority [.uint JarlRules.proviumUsizeBits a, .uint JarlRules.proviumUsizeBits total] = .ok (.boolean true))
    (qb : JarlRules.majority [.uint JarlRules.proviumUsizeBits b, .uint JarlRules.proviumUsizeBits total] = .ok (.boolean true)) :
    total < a + b := by
  rw [majority_strict a total ha ht] at qa
  rw [majority_strict b total hb ht] at qb
  simp at qa qb
  omega

theorem majority_position_in_bounds (total : Nat)
    (positive : 0 < total) (bounded : total < 2^JarlRules.proviumUsizeBits) :
    ∃ index, JarlRules.majority_position [.uint JarlRules.proviumUsizeBits total] = .ok (.uint JarlRules.proviumUsizeBits index)
      ∧ index < total := by
  have hd := half_bound total bounded
  have sum_le : total / 2 + 1 ≤ total := by omega
  have sum_bound : total / 2 + 1 < 2^JarlRules.proviumUsizeBits := by omega
  have diff_bound : total - (total / 2 + 1) < 2^JarlRules.proviumUsizeBits := by omega
  simp only [JarlRules.proviumUsizeBits] at *
  refine ⟨total - (total / 2 + 1), ?_, ?_⟩
  · simp [JarlRules.majority_position, validArgs, validWidth, Provium.get, Provium.bind,
      binary, uintOp, word, bounded, hd, sum_bound, diff_bound, show ¬ total < total / 2 + 1 by omega]
  · omega

private theorem joint_value (new old : Nat) (hn : new < 2^64) (ho : old < 2^64) :
    JarlRules.joint_commit_index [.uint 64 new, .uint 64 old] = .ok (.uint 64 (min new old)) := by
  have hm : min new old < 2^64 := by omega
  simp [JarlRules.joint_commit_index, validArgs, validWidth, Provium.get, Provium.bind,
    binary, uintOp, word, hn, ho, hm]

theorem joint_commit_requires_both (new old index : Nat)
    (hn : new < 2^64) (ho : old < 2^64)
    (result : JarlRules.joint_commit_index [.uint 64 new, .uint 64 old] = .ok (.uint 64 index)) :
    index ≤ new ∧ index ≤ old := by
  rw [joint_value new old hn ho] at result
  simp at result
  omega

theorem follower_never_overcommits (leader matched index : Nat)
    (hl : leader < 2^64) (hm : matched < 2^64)
    (result : JarlRules.follower_commit [.uint 64 leader, .uint 64 matched] = .ok (.uint 64 index)) :
    index ≤ leader ∧ index ≤ matched := by
  change JarlRules.joint_commit_index [.uint 64 leader, .uint 64 matched] = .ok (.uint 64 index) at result
  exact joint_commit_requires_both leader matched index hl hm result

theorem commit_never_regresses (current incoming : Nat)
    (hc : current < 2^64) (hi : incoming < 2^64) :
    ∃ next, JarlRules.commit_index [.uint 64 current, .uint 64 incoming] = .ok (.uint 64 next)
      ∧ current ≤ next ∧ next < 2^64 := by
  by_cases h : incoming > current
  · refine ⟨incoming, ?_, by omega, hi⟩
    simp [JarlRules.commit_index, validArgs, validWidth, Provium.get, Provium.bind, binary, uintOp, branch, hc, hi, h]
  · refine ⟨current, ?_, by omega, hc⟩
    simp [JarlRules.commit_index, validArgs, validWidth, Provium.get, Provium.bind, binary, uintOp, branch, hc, hi, h]

theorem current_term_required (entry current : Nat)
    (he : entry < 2^64) (hc : current < 2^64)
    (accepted : JarlRules.can_commit_term [.uint 64 entry, .uint 64 current] = .ok (.boolean true)) :
    entry = current := by
  simpa [JarlRules.can_commit_term, validArgs, validWidth, Provium.get, Provium.bind, binary, uintOp, he, hc] using accepted

-- Transitive closure uses the generated Rust transition directly. It is not a
-- hand-written substitute transition system. This proves arbitrarily many steps
-- of the extracted guarded assignment prefix, not reachability of Node state
-- or effects of the remainder of commit_to (including refresh_membership).
inductive CommitTrace (initial : Nat) : Nat → Prop where
  | start : CommitTrace initial initial
  | step {current incoming next : Nat} : CommitTrace initial current →
      current < 2^64 → incoming < 2^64 →
      JarlRules.commit_index [.uint 64 current, .uint 64 incoming] = .ok (.uint 64 next) →
      CommitTrace initial next

theorem commit_sequence_monotone (initial final : Nat)
    (trace : CommitTrace initial final) :
    initial ≤ final ∧
      (∀ incoming, incoming < 2^64 → final < 2^64 →
        ∃ next, JarlRules.commit_index [.uint 64 final, .uint 64 incoming] = .ok (.uint 64 next)
          ∧ final ≤ next) := by
  have monotone : initial ≤ final := by
    induction trace with
    | start => omega
    | @step current incoming next _ hc hi result ih =>
      obtain ⟨value, hv, hmono, _⟩ := commit_never_regresses current incoming hc hi
      rw [hv] at result
      simp at result
      omega
  refine ⟨monotone, ?_⟩
  intro incoming hi hf
  obtain ⟨next, hnext, hmono, _⟩ := commit_never_regresses final incoming hf hi
  exact ⟨next, hnext, hmono⟩
end JarlProofs
