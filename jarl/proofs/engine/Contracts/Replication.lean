import Contracts.Storage

/-!
# Replication contracts over the typed translation

Ports the `replication-contract` project: composes the storage contracts with the
original append validation (`Node::valid`) and the actual translated `id_at`,
`truncate` and `push`. Accepted append validation supplies the storage
successor/term condition; the replacement contract derives the retained
predecessor and available space, preserves the ordered log and committed slots,
and proves the resulting length. The facts needed about `Node::valid` are proved
here directly from its translation.
-/

namespace Jarl.Contracts.Replication
open Jarl Jarl.Engine Jarl.Contracts.Storage

variable {V S : Type} {CAP : Nat}

/-- What an accepted single-entry `Append` guarantees, read off `Node::valid`. -/
theorem append_accepted {N : Nat} [Rust.Clone V] [Rust.Clone S]
    (term : Rust.u64) (previous : LogId) (entry : Entry V) (commit : Rust.u64)
    (accepted : Node.valid (N := N) (CAP := CAP)
      (Message.Append term previous (some entry) commit : Message V S) = pure true) :
    0 < term.val ∧ entry.id.index.val = previous.index.val + 1 ∧ 0 < entry.id.term.val ∧
      previous.term.val ≤ entry.id.term.val ∧ entry.id.term.val ≤ term.val := by
  unfold Node.valid at accepted
  simp [Message.term] at accepted
  split at accepted
  · rename_i hpos
    have h := Rust.pure_inj accepted
    by_cases c : previous.index.val + 1 < 2 ^ 64
    · simp only [c, dite_true, Bool.and_eq_true, Bool.or_eq_true, beq_iff_eq, decide_eq_true_eq,
        Option.some.injEq, Fin.ext_iff, Fin.lt_def, Fin.le_def] at h hpos
      obtain ⟨_, ⟨⟨hid, hsucc⟩, hmono⟩⟩ := h
      have z : ((0 : Rust.u64) : Nat) = 0 := rfl
      rcases hid with hd | ⟨⟨a, b⟩, c⟩
      · have := congrArg (fun x : LogId => x.index.val) hd
        simp [LogId.default] at this; omega
      · rw [z] at a b hpos; omega
    · simp [c] at h
  · have := Rust.pure_inj accepted; simp at this

/-- Accepted append validation, with the hard term advanced to the message term,
supplies the storage successor condition. -/
theorem validation_supplies_successor {N : Nat} [Rust.Clone V] [Rust.Clone S]
    (term : Rust.u64) (previous : LogId) (entry : Entry V) (commit : Rust.u64) (hard : HardState)
    (accepted : Node.valid (N := N) (CAP := CAP)
      (Message.Append term previous (some entry) commit : Message V S) = pure true)
    (advancedTerm : term.val ≤ hard.term.val) :
    LogSuccessor hard previous entry.id := by
  obtain ⟨_, successor, positive, monotone, upper⟩ := append_accepted term previous entry commit accepted
  exact ⟨successor, positive, monotone, Nat.le_trans upper advancedTerm⟩

theorem validated_append_preserves_log {N : Nat} [Rust.Clone V] [Rust.Clone S]
    {hard : HardState} {base : LogId} (s : State V S CAP)
    (term : Rust.u64) (previous : LogId) (input : Entry V) (commit : Rust.u64)
    (accepted : Node.valid (N := N) (CAP := CAP)
      (Message.Append term previous (some input) commit : Message V S) = pure true)
    (advancedTerm : term.val ≤ hard.term.val)
    (selected : s.base = base) (valid : LogRep hard base s)
    (space : s.len.val < CAP) (word : CAP < 2 ^ Rust.usizeBits)
    (fetched : State.last s = pure previous) :
    ∃ next, State.push s input = pure (.Ok (), next) ∧ LogRep hard base next ∧
      next.len.val = s.len.val + 1 ∧
      ∀ position, position < s.len.val →
        next.entries.toList[position]? = s.entries.toList[position]? :=
  append_preserves_log s input selected valid space word fetched
    (validation_supplies_successor term previous input commit hard accepted advancedTerm)

/-- Truncating at an authorized boundary leaves room for the replacement entry.
`canStore` is the scalar form of append's full-buffer rejection guard. -/
theorem replacement_prepares_append {hard : HardState} {base : LogId}
    (s : State V S CAP) (f : Rust.u64) (commit : Nat)
    (selected : s.base = base) (valid : LogRep hard base s)
    (commitBounds : base.index.val ≤ commit ∧ commit ≤ base.index.val + s.len.val)
    (authorized : commit < f.val)
    (canStore : ¬(s.len.val = CAP ∧ f.val > base.index.val + s.len.val)) :
    ∃ shortened, State.truncate s f = pure shortened ∧ LogRep hard base shortened ∧
      shortened.len.val < CAP ∧
      shortened.len.val = min s.len.val (f.val - (base.index.val + 1)) ∧
      commit ≤ base.index.val + shortened.len.val ∧
      ∀ position, position < commit - base.index.val →
        shortened.entries.toList[position]? = s.entries.toList[position]? := by
  obtain ⟨shortened, execution, retained, length, _⟩ := truncation_complete_result s f selected valid
  have committedPrefix := truncation_preserves_committed_prefix s shortened f commit selected valid
    commitBounds authorized execution
  have oldBound : s.len.val ≤ CAP := valid.1.1
  exact ⟨shortened, execution, retained, by omega, length, committedPrefix.2.1, committedPrefix.2.2⟩

theorem replacement_storage_succeeds {hard : HardState} {base : LogId}
    (s : State V S CAP) (f : Rust.u64) (commit : Nat) (input : Entry V)
    (selected : s.base = base) (valid : LogRep hard base s) (word : CAP < 2 ^ Rust.usizeBits)
    (commitBounds : base.index.val ≤ commit ∧ commit ≤ base.index.val + s.len.val)
    (authorized : commit < f.val)
    (canStore : ¬(s.len.val = CAP ∧ f.val > base.index.val + s.len.val)) :
    ∃ shortened next,
      State.truncate s f = pure shortened ∧
      State.push shortened input = pure (.Ok (), next) ∧
      Shape next ∧
      next.len.val = min s.len.val (f.val - (base.index.val + 1)) + 1 ∧
      commit ≤ base.index.val + next.len.val ∧
      ∀ position, position < commit - base.index.val →
        next.entries.toList[position]? = s.entries.toList[position]? := by
  obtain ⟨shortened, truncated, retained, space, length, bounded, committedPrefix⟩ :=
    replacement_prepares_append s f commit selected valid commitBounds authorized canStore
  obtain ⟨next, pushed, shape, nextLength⟩ := append_preserves_shape shortened input retained.1 space word
  obtain ⟨framed, same, unchanged⟩ := append_preserves_prefix shortened input retained.1 space word
  rw [pushed] at same
  cases (Prod.mk.inj (Rust.pure_inj same)).2
  refine ⟨shortened, next, truncated, pushed, shape, by omega, by omega, ?_⟩
  intro position inside
  exact (unchanged position (by omega)).trans (committedPrefix position inside)

/-- Exact capacity characterization, including zero capacity. -/
theorem truncation_space_iff {hard : HardState} {base : LogId}
    (s shortened : State V S CAP) (f : Rust.u64)
    (selected : s.base = base) (valid : LogRep hard base s)
    (pastBase : base.index.val < f.val)
    (execution : State.truncate s f = pure shortened) :
    shortened.len.val < CAP ↔ ¬(s.len.val = CAP ∧ f.val > base.index.val + s.len.val) := by
  obtain ⟨expected, returned, _, length, _⟩ := truncation_complete_result s f selected valid
  rw [returned] at execution
  cases Rust.pure_inj execution
  have oldBound : s.len.val ≤ CAP := valid.1.1
  omega

/-- The predecessor of a boundary in the old log: the base itself, or a retained
entry just before the boundary. -/
def PredecessorAt (base : LogId) (boundary : Nat) (s : State V S CAP) (last : LogId) : Prop :=
  (boundary = base.index.val + 1 ∧ last = base) ∨
  ∃ position previous, boundary = base.index.val + position + 2 ∧ position < s.len.val ∧
    s.entries.toList[position]? = some (some previous) ∧ last = previous.id

theorem predecessor_after_truncation {hard : HardState} {base last : LogId}
    (s shortened : State V S CAP) (f : Rust.u64)
    (selected : s.base = base) (valid : LogRep hard base s)
    (predecessor : PredecessorAt base f.val s last)
    (execution : State.truncate s f = pure shortened) :
    State.last shortened = pure last := by
  rcases predecessor with ⟨cut, same⟩ | ⟨position, previous, cut, inside, hit, same⟩
  · rw [same]
    exact truncation_retains_base s shortened f selected valid cut execution
  · rw [same]
    exact truncation_retains_predecessor s shortened f position previous selected valid cut inside hit execution

/-- Replacing the suffix from an identified predecessor with a successor entry keeps
an ordered log, the committed slots, and the exact length. -/
theorem replacement_append_preserves_log {hard : HardState} {base last : LogId}
    (s shortened : State V S CAP) (f : Rust.u64) (commit : Nat) (input : Entry V)
    (selected : s.base = base) (valid : LogRep hard base s) (word : CAP < 2 ^ Rust.usizeBits)
    (commitBounds : base.index.val ≤ commit ∧ commit ≤ base.index.val + s.len.val)
    (authorized : commit < f.val)
    (canStore : ¬(s.len.val = CAP ∧ f.val > base.index.val + s.len.val))
    (execution : State.truncate s f = pure shortened)
    (predecessor : PredecessorAt base f.val s last)
    (follows : LogSuccessor hard last input.id) :
    ∃ next, State.push shortened input = pure (.Ok (), next) ∧
      LogRep hard base next ∧
      next.len.val = min s.len.val (f.val - (base.index.val + 1)) + 1 ∧
      commit ≤ base.index.val + next.len.val ∧
      ∀ position, position < commit - base.index.val →
        next.entries.toList[position]? = s.entries.toList[position]? := by
  obtain ⟨expected, returned, retained, space, length, bounded, committedPrefix⟩ :=
    replacement_prepares_append s f commit selected valid commitBounds authorized canStore
  rw [returned] at execution
  cases Rust.pure_inj execution
  have fetched := predecessor_after_truncation s shortened f selected valid predecessor returned
  have hb : shortened.base = base := by
    obtain ⟨_, _, _, _, hs⟩ := truncation_preserves_shape s shortened f valid.1 returned
    rw [← selected]; simp [State.base, hs]
  obtain ⟨next, pushed, logValid, nextLength, unchanged⟩ :=
    append_preserves_log shortened input hb retained space word fetched follows
  refine ⟨next, pushed, logValid, by omega, by omega, ?_⟩
  intro position inside
  exact (unchanged position (by omega)).trans (committedPrefix position inside)

/-- A successful `id_at` lookup identifies the predecessor relation in the old log. -/
theorem lookup_identifies_predecessor {hard : HardState} {base last : LogId}
    (s : State V S CAP) (previousIndex : Rust.u64)
    (selected : s.base = base) (valid : LogRep hard base s)
    (found : State.id_at s previousIndex = some last) :
    PredecessorAt base (previousIndex.val + 1) s last := by
  obtain ⟨hl, _⟩ := logrep_layout valid
  rw [id_at_eq s hl, idAt, selected] at found
  split at found
  · rename_i same
    cases found
    exact Or.inl ⟨by omega, rfl⟩
  · rename_i different
    split at found
    · rename_i after
      simp only [Option.map_eq_some_iff] at found
      obtain ⟨previous, hit, rfl⟩ := found
      have inside := (List.getElem?_eq_some_iff.mp hit).1
      have hlr := len_eq s hl
      have slot := slot_eq s hl (previousIndex.val - base.index.val - 1)
      rw [hit] at slot
      have present : s.entries.toList[previousIndex.val - base.index.val - 1]? = some (some previous) :=
        Option.join_eq_some_iff.mp slot
      exact Or.inr ⟨_, previous, by omega, by omega, present, rfl⟩
    · cases found

theorem lookup_retained_after_truncation {hard : HardState} {base last : LogId}
    (s shortened : State V S CAP) (previousIndex f : Rust.u64)
    (selected : s.base = base) (valid : LogRep hard base s)
    (next : f.val = previousIndex.val + 1)
    (found : State.id_at s previousIndex = some last)
    (execution : State.truncate s f = pure shortened) :
    State.last shortened = pure last := by
  have predecessor := lookup_identifies_predecessor s previousIndex selected valid found
  rw [← next] at predecessor
  exact predecessor_after_truncation s shortened f selected valid predecessor execution

/-- All conditions concern the old state and incoming record: storage execution,
free space and the retained predecessor are conclusions about the translation. -/
theorem matched_replacement_preserves_log {hard : HardState} {base last : LogId}
    (s : State V S CAP) (previousIndex f : Rust.u64) (commit : Nat) (input : Entry V)
    (selected : s.base = base) (valid : LogRep hard base s) (word : CAP < 2 ^ Rust.usizeBits)
    (next : f.val = previousIndex.val + 1)
    (commitBounds : base.index.val ≤ commit ∧ commit ≤ base.index.val + s.len.val)
    (authorized : commit < previousIndex.val + 1)
    (canStore : ¬(s.len.val = CAP ∧ previousIndex.val + 1 > base.index.val + s.len.val))
    (found : State.id_at s previousIndex = some last)
    (follows : LogSuccessor hard last input.id) :
    ∃ shortened next,
      State.truncate s f = pure shortened ∧
      State.push shortened input = pure (.Ok (), next) ∧
      LogRep hard base next ∧
      next.len.val = min s.len.val (previousIndex.val + 1 - (base.index.val + 1)) + 1 ∧
      commit ≤ base.index.val + next.len.val ∧
      ∀ position, position < commit - base.index.val →
        next.entries.toList[position]? = s.entries.toList[position]? := by
  have predecessor := lookup_identifies_predecessor s previousIndex selected valid found
  rw [← next] at predecessor authorized canStore ⊢
  obtain ⟨shortened, execution, _⟩ := replacement_prepares_append s f commit selected valid
    commitBounds authorized canStore
  obtain ⟨n, pushed, logValid, length, bounded, unchanged⟩ :=
    replacement_append_preserves_log s shortened f commit input selected valid word commitBounds
      authorized canStore execution predecessor follows
  exact ⟨shortened, n, execution, pushed, logValid, length, bounded, unchanged⟩

end Jarl.Contracts.Replication
