import Generated

/-!
`state::State::full`: exact equality against the const-generic capacity `CAP`
(which must be a valid `usize`); non-full implies room under the separate
`len ≤ CAP` representation invariant.
-/

namespace Jarl.Contracts.Capacity

theorem full_exact {V S : Type} {CAP : Nat} (s : State V S CAP) (hc : CAP < 2^64) :
    State.full s = decide (s.len.val = CAP) := by
  unfold State.full
  by_cases h : s.len.val = CAP
  · simp [h, Fin.ext_iff, Rust.val_usizeOf CAP hc]
  · simp [h, Fin.ext_iff, Rust.val_usizeOf CAP hc]

/-- The representation invariant `len ≤ CAP` is a caller obligation, not inferred
    from the source equality. Under that invariant, admission has room. -/
theorem not_full_has_space {V S : Type} {CAP : Nat} (s : State V S CAP) (hc : CAP < 2^64)
    (within : s.len.val ≤ CAP) (available : State.full s = false) : s.len.val < CAP := by
  rw [full_exact s hc] at available
  simp only [decide_eq_false_iff_not] at available
  omega

end Jarl.Contracts.Capacity
