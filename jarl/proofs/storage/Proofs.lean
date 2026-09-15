import Generated
open Provium.State
namespace Storage

-- This is the representation predicate still to be established for restore,
-- truncate, install and growth. Payloads are opaque owned values.
def Shape (state : BufferState α) (capacity : Nat) : Prop :=
  state.slots.length = capacity ∧ state.len ≤ capacity ∧
  (∀ i, i < state.len → ∃ value, state.slots[i]? = some (some value)) ∧
  (∀ i, state.len ≤ i → i < capacity → state.slots[i]? = some none)

theorem append_exact (bits capacity : Nat) (state : BufferState α) (input : α)
    (shape : Shape state capacity) (space : state.len < capacity)
    (word : capacity < 2^bits) :
    JarlStorage.state_State_push bits capacity state input =
      .returned (.ok ()) ⟨state.slots.set state.len (some input), state.len + 1⟩ := by
  have different : state.len ≠ capacity := by omega
  have empty := shape.2.2.2 state.len (by omega) space
  have fits : state.len + 1 < 2^bits := by omega
  simp [JarlStorage.state_State_push, JarlStorage.state_State_push_ir,
    appendBuffer, different, empty, fits]

theorem append_preserves_shape (bits capacity : Nat) (state : BufferState α) (input : α)
    (shape : Shape state capacity) (space : state.len < capacity)
    (word : capacity < 2^bits) :
    ∃ next, JarlStorage.state_State_push bits capacity state input = .returned (.ok ()) next ∧
      Shape next capacity ∧ next.len = state.len + 1 := by
  refine ⟨⟨state.slots.set state.len (some input), state.len + 1⟩,
    append_exact bits capacity state input shape space word, ?_, rfl⟩
  refine ⟨by simpa using shape.1, by dsimp; omega, ?_, ?_⟩
  · intro i hi
    dsimp at hi ⊢
    by_cases same : i = state.len
    · subst i
      exact ⟨input, List.getElem?_set_self (by rw [shape.1]; exact space)⟩
    · obtain ⟨value, present⟩ := shape.2.2.1 i (by omega)
      exact ⟨value, by simpa [List.getElem?_set_ne (Ne.symm same)] using present⟩
  · intro i hi bound
    dsimp at hi ⊢
    have different : state.len ≠ i := by omega
    simpa [List.getElem?_set_ne different] using shape.2.2.2 i (by omega) bound

-- Returning Error::Full first destroys the rejected owned input. This states the
-- suspension and its normal-return continuation, never that Drop must return.
theorem full_preserves_state_at_drop (bits capacity : Nat) (state : BufferState α) (input : α)
    (full : state.len = capacity) :
    JarlStorage.state_State_push bits capacity state input =
      .drop input state (.returned (.error "Error::Full") state) := by
  simp [JarlStorage.state_State_push, JarlStorage.state_State_push_ir, appendBuffer, full]

theorem append_preserves_prefix (bits capacity : Nat) (state : BufferState α) (input : α)
    (shape : Shape state capacity) (space : state.len < capacity)
    (word : capacity < 2^bits) :
    ∃ next, JarlStorage.state_State_push bits capacity state input = .returned (.ok ()) next ∧
      ∀ i, i < state.len → next.slots[i]? = state.slots[i]? := by
  refine ⟨⟨state.slots.set state.len (some input), state.len + 1⟩,
    append_exact bits capacity state input shape space word, ?_⟩
  intro i hi
  exact List.getElem?_set_ne (by omega)
-- Erasing payloads preserves presence; this relation does not identify Rust
-- layout or borrow semantics with either store representation.
def InitialRepresents (initial : InitStore) (state : BufferState α) : Prop :=
  initial ["len"] = .unsigned "usize" state.len ∧
  initial ["entries"] = .slots (state.slots.map (Option.map (fun _ => ())))

theorem fresh_representation (sizes : String → Nat) :
    InitialRepresents (JarlStorage.state_State_new sizes)
      (⟨List.replicate (sizes "CAP") none, 0⟩ : BufferState α) ∧
    Shape (⟨List.replicate (sizes "CAP") none, 0⟩ : BufferState α) (sizes "CAP") := by
  simp [InitialRepresents, JarlStorage.state_State_new, JarlStorage.state_State_new_ir,
    initializeFields, initialCell, Shape, List.getElem?_replicate]

-- This history contains exactly fresh initialization and successful appends.
-- It deliberately excludes restore, truncation, snapshots, and capacity growth;
-- their preservation lemmas must be added before closing the storage invariant.
inductive AppendHistory (bits capacity : Nat) : BufferState α → Prop where
  | fresh : AppendHistory bits capacity ⟨List.replicate capacity none, 0⟩
  | append {state next : BufferState α} (input : α) :
      AppendHistory bits capacity state →
      JarlStorage.state_State_push bits capacity state input = .returned (.ok ()) next →
      AppendHistory bits capacity next

private theorem history_shape (bits capacity : Nat) (state : BufferState α)
    (word : capacity < 2^bits) (history : AppendHistory bits capacity state) :
    Shape state capacity := by
  induction history with
  | fresh =>
    exact (fresh_representation (α := α) (fun _ => capacity)).2
  | @append before next input previous execution ih =>
    have space : before.len < capacity := by
      have bound := ih.2.1
      by_cases h : before.len < capacity
      · exact h
      · have full : before.len = capacity := by omega
        rw [full_preserves_state_at_drop bits capacity before input full] at execution
        contradiction
    obtain ⟨result, computed, preserved, _⟩ :=
      append_preserves_shape bits capacity before input ih space word
    rw [computed] at execution
    cases execution
    exact preserved
theorem history_preserves_shape (bits capacity : Nat) (state : BufferState α) (input : α)
    (word : capacity < 2^bits) (history : AppendHistory bits capacity state) :
    Shape state capacity ∧ (state.len < capacity →
      ∃ next, JarlStorage.state_State_push bits capacity state input = .returned (.ok ()) next ∧
        Shape next capacity ∧ next.len = state.len + 1) := by
  have shape := history_shape bits capacity state word history
  exact ⟨shape, fun space => append_preserves_shape bits capacity state input shape space word⟩
end Storage
