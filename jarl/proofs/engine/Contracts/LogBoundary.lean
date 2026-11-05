import Generated

/-!
Complete `state::State::base`, `get`, `id_at`, `entries` (`State.entries_fn`) and
`last`: snapshot boundary, checked lookup, ordered prefix iteration, and exact
boundary/final-entry records. Indexes are `u64` and offsets are relative to the
snapshot boundary `(State.base s).index`.
-/

namespace Jarl.Contracts.LogBoundary

theorem without_snapshot {V S : Type} {CAP : Nat} (s : State V S CAP)
    (absent : s.snapshot = none) : State.base s = { index := 0, term := 0 } := by
  simp [State.base, absent, LogId.default]

theorem snapshot_boundary {V S : Type} {CAP : Nat} (s : State V S CAP) (snap : Snapshot S)
    (present : s.snapshot = some snap) : State.base s = snap.last := by
  simp [State.base, present]

/-- The complete lookup: `none` at or before the boundary, otherwise the slot at
    offset `index - base - 1` when it is in range, else `none`. -/
theorem get_exact {V S : Type} {CAP : Nat} (s : State V S CAP) (i : Rust.u64) :
    State.get s i =
      if i.val ≤ (State.base s).index.val then none
      else if h : i.val - (State.base s).index.val - 1 < CAP then
        s.entries[i.val - (State.base s).index.val - 1] else none := by
  unfold State.get
  simp only [Rust.checked_sub_eq]
  by_cases h1 : (State.base s).index.val ≤ i.val
  · by_cases h2 : i.val ≤ (State.base s).index.val
    · have : i.val = (State.base s).index.val := by omega
      simp [this]
    · have h3 : 1 ≤ i.val - (State.base s).index.val := by omega
      simp [h1, h2, h3, Id.run, Rust.try_from, Rust.Result.ok, Rust.Slice.get]
      by_cases h4 : i.val - (State.base s).index.val - 1 < CAP
      · rw [dif_pos h4, Vector.getElem?_eq_getElem h4]
        cases s.entries[i.val - (State.base s).index.val - 1] <;> rfl
      · rw [dif_neg h4, Vector.getElem?_eq_none (by omega)]
        rfl
  · have h2 : i.val ≤ (State.base s).index.val := by omega
    simp [h1]
    intro _ _
    omega

theorem iterator_exact {V S : Type} {CAP : Nat} (s : State V S CAP) (bound : s.len.val ≤ CAP) :
    State.entries_fn s = pure ((s.entries.toList.take s.len.val).filterMap id) := by
  unfold State.entries_fn
  rw [Rust.Slice.range_ok _ _ _ (by simp [bound])]
  simp [Rust.Iter.flatten]
  rfl

theorem iterator_rejects_invalid_length {V S : Type} {CAP : Nat} (s : State V S CAP)
    (invalid : CAP < s.len.val) :
    State.entries_fn s = throw ⟨"range out of bounds"⟩ := by
  unfold State.entries_fn Rust.Slice.range
  rw [if_neg (by omega)]
  rfl

theorem last_exact {V S : Type} {CAP : Nat} (s : State V S CAP) (bound : s.len.val ≤ CAP) :
    State.last s = pure ((((s.entries.toList.take s.len.val).filterMap id).getLast?.map
      (·.id)).getD (State.base s)) := by
  unfold State.last
  rw [iterator_exact s bound]
  simp only [pure_bind]
  cases ((s.entries.toList.take s.len.val).filterMap id).getLast? <;> rfl

theorem lookup_all_offsets {V S : Type} {CAP : Nat} (s : State V S CAP) (i : Rust.u64) (offset : Nat)
    (index : i.val = (State.base s).index.val + 1 + offset) :
    State.get s i = if h : offset < CAP then s.entries[offset] else none := by
  rw [get_exact, if_neg (by omega)]
  have : i.val - (State.base s).index.val - 1 = offset := by omega
  simp only [this]

theorem lookup_exact {V S : Type} {CAP : Nat} (s : State V S CAP) (i : Rust.u64) (offset : Nat)
    (entry : Entry V) (index : i.val = (State.base s).index.val + 1 + offset)
    (target : offset < CAP) (present : s.entries[offset] = some entry) :
    State.get s i = some entry := by
  rw [lookup_all_offsets s i offset index, dif_pos target, present]

theorem lookup_at_or_before_boundary {V S : Type} {CAP : Nat} (s : State V S CAP) (i : Rust.u64)
    (before : i.val ≤ (State.base s).index.val) : State.get s i = none := by
  rw [get_exact, if_pos before]

theorem record_at_snapshot {V S : Type} {CAP : Nat} (s : State V S CAP) (i : Rust.u64)
    (boundary : i = (State.base s).index) : State.id_at s i = some (State.base s) := by
  simp [State.id_at, boundary]

theorem record_at_entry {V S : Type} {CAP : Nat} (s : State V S CAP) (i : Rust.u64) (offset : Nat)
    (entry : Entry V) (index : i.val = (State.base s).index.val + 1 + offset)
    (target : offset < CAP) (present : s.entries[offset] = some entry) :
    State.id_at s i = some entry.id := by
  have different : i ≠ (State.base s).index := by
    intro h; rw [h] at index; omega
  simp [State.id_at, different, lookup_exact s i offset entry index target present]

theorem record_at_absent {V S : Type} {CAP : Nat} (s : State V S CAP) (i : Rust.u64)
    (different : i ≠ (State.base s).index) (missing : State.get s i = none) :
    State.id_at s i = none := by
  simp [State.id_at, different, missing]

theorem last_empty {V S : Type} {CAP : Nat} (s : State V S CAP) (empty : s.len.val = 0) :
    State.last s = pure (State.base s) := by
  rw [last_exact s (by omega), empty]
  rfl

private theorem filterMap_holes {α : Type} (holes : List (Option α))
    (empty : ∀ hole ∈ holes, hole = none) : holes.filterMap id = [] := by
  rw [List.filterMap_eq_nil_iff]
  intro a h
  simp [empty a h]

theorem last_final_slot {V S : Type} {CAP : Nat} (s : State V S CAP)
    (front suffix : List (Option (Entry V))) (entry : Entry V)
    (length : s.len.val = front.length + 1)
    (slots : s.entries.toList = front ++ [some entry] ++ suffix) :
    State.last s = pure entry.id := by
  have bound : s.len.val ≤ CAP := by
    have := congrArg List.length slots; simp at this; omega
  rw [last_exact s bound, slots, length]
  simp [List.take_append, List.filterMap_append]

/-- A retained prefix with no present entry yields the snapshot boundary, for
    any length; `last_empty` is the zero-length case. -/
theorem last_without_present {V S : Type} {CAP : Nat} (s : State V S CAP)
    (holes suffix : List (Option (Entry V)))
    (length : s.len.val = holes.length) (empty : ∀ hole ∈ holes, hole = none)
    (slots : s.entries.toList = holes ++ suffix) :
    State.last s = pure (State.base s) := by
  have bound : s.len.val ≤ CAP := by
    have := congrArg List.length slots; simp at this; omega
  rw [last_exact s bound, slots, length]
  simp [filterMap_holes holes empty]

/-- Holes after the final present entry of the retained prefix are skipped:
    `last` returns that entry's id. -/
theorem last_skips_trailing_holes {V S : Type} {CAP : Nat} (s : State V S CAP)
    (front holes suffix : List (Option (Entry V))) (entry : Entry V)
    (length : s.len.val = front.length + 1 + holes.length)
    (empty : ∀ hole ∈ holes, hole = none)
    (slots : s.entries.toList = front ++ [some entry] ++ holes ++ suffix) :
    State.last s = pure entry.id := by
  have bound : s.len.val ≤ CAP := by
    have := congrArg List.length slots; simp at this; omega
  rw [last_exact s bound, slots, length, List.take_left' (by simp; omega),
    List.filterMap_append, filterMap_holes holes empty]
  simp

end Jarl.Contracts.LogBoundary
