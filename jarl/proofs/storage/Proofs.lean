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
private theorem move_prefix (live tail : List (Option α)) (start extra : Nat) :
    moveSlots false (start + live.length) start (live.length + extra) (live ++ tail) =
      .done (live ++ List.replicate extra none) (List.replicate live.length none ++ tail) := by
  induction live generalizing start with
  | nil =>
    cases extra <;> simp [moveSlots]
  | cons entry rest ih =>
    simp only [List.length_cons, Nat.succ_add, List.cons_append, moveSlots]
    simp only [Bool.false_eq_true, ↓reduceIte]
    have active : start < start + (rest.length + 1) := by omega
    rw [if_pos active]
    rw [show start + (rest.length + 1) = (start + 1) + rest.length by omega]
    rw [ih (start + 1)]
    rfl

private theorem dispose_empty (count : Nat) (next : RelocationRun α β) :
    disposeSlots (List.replicate count none) next = next := by
  induction count with
  | zero => rfl
  | succ count ih => simpa [List.replicate_succ, disposeSlots] using ih

private theorem relocate_prefix (oldCapacity newCapacity : Nat) (live : List (Option α)) (metadata : β)
    (fits : live.length ≤ oldCapacity) (grows : oldCapacity ≤ newCapacity) :
    JarlStorage.state_State_grow oldCapacity newCapacity
      ⟨live ++ List.replicate (oldCapacity - live.length) none, live.length⟩ metadata =
      .returned ⟨live ++ List.replicate (newCapacity - live.length) none, live.length⟩ metadata := by
  have room : live.length ≤ newCapacity := by omega
  have moves := move_prefix (live) (List.replicate (oldCapacity - live.length) none)
    0 (newCapacity - live.length)
  simp only [Nat.zero_add, Nat.add_sub_of_le room] at moves
  have empty : List.replicate live.length (none : Option α) ++
      List.replicate (oldCapacity - live.length) none = List.replicate oldCapacity none := by
    rw [List.replicate_append_replicate, Nat.add_sub_of_le fits]
  simp only [JarlStorage.state_State_grow, JarlStorage.state_State_grow_ir,
    relocate, ↓reduceIte, grows, moves, empty, dispose_empty]
theorem grow_exact (oldCapacity newCapacity : Nat) (live : List α) (metadata : β)
    (fits : live.length ≤ oldCapacity) (grows : oldCapacity ≤ newCapacity) :
    JarlStorage.state_State_grow oldCapacity newCapacity
      ⟨live.map some ++ List.replicate (oldCapacity - live.length) none, live.length⟩ metadata =
      .returned ⟨live.map some ++ List.replicate (newCapacity - live.length) none, live.length⟩ metadata := by
  simpa only [List.length_map] using
    relocate_prefix oldCapacity newCapacity (live.map some) metadata (by simpa using fits) grows

private theorem empty_suffix (state : BufferState α) (capacity : Nat) (shape : Shape state capacity) :
    state.slots.drop state.len = List.replicate (capacity - state.len) none := by
  apply List.ext_getElem?
  intro i
  rw [List.getElem?_drop, List.getElem?_replicate]
  by_cases inside : i < capacity - state.len
  · rw [if_pos inside]
    exact shape.2.2.2 (state.len + i) (by omega) (by omega)
  · rw [if_neg inside]
    apply List.getElem?_eq_none
    rw [shape.1]
    have := shape.2.1
    omega

theorem grow_preserves_shape (oldCapacity newCapacity : Nat) (state : BufferState α) (metadata : β)
    (shape : Shape state oldCapacity) (grows : oldCapacity ≤ newCapacity) :
    ∃ next, JarlStorage.state_State_grow oldCapacity newCapacity state metadata = .returned next metadata ∧
      Shape next newCapacity ∧ next.len = state.len ∧
      (∀ i, i < state.len → next.slots[i]? = state.slots[i]?) := by
  have length : (state.slots.take state.len).length = state.len :=
    List.length_take_of_le (by rw [shape.1]; exact shape.2.1)
  have decompose : state.slots.take state.len ++ List.replicate (oldCapacity - state.len) none = state.slots := by
    rw [← empty_suffix state oldCapacity shape]
    exact List.take_append_drop _ _
  have execution := relocate_prefix oldCapacity newCapacity (state.slots.take state.len) metadata
    (by rw [length]; exact shape.2.1) grows
  simp only [length, decompose] at execution
  cases state with
  | mk slots len =>
    dsimp [Shape] at shape length decompose execution ⊢
    refine ⟨⟨slots.take len ++ List.replicate (newCapacity - len) none, len⟩, execution, ?_, rfl, ?_⟩
    · refine ⟨?_, ?_, ?_, ?_⟩
      · simp only [List.length_append, length, List.length_replicate]
        have := shape.2.1
        omega
      · have := shape.2.1
        dsimp
        omega
      · intro i hi
        dsimp at hi
        obtain ⟨value, present⟩ := shape.2.2.1 i hi
        refine ⟨value, ?_⟩
        dsimp
        rw [List.getElem?_append_left (by omega), List.getElem?_take_of_lt hi]
        exact present
      · intro i hi bound
        dsimp at hi ⊢
        rw [List.getElem?_append_right (by omega), length, List.getElem?_replicate]
        rw [if_pos (by omega)]
    · intro i hi
      dsimp
      rw [List.getElem?_append_left (by omega), List.getElem?_take_of_lt hi]
-- Capacity is part of the history index, so growth is not treated as a fixed
-- capacity assumption. These histories still exclude restore/truncate/install.
inductive StorageHistory (bits : Nat) : Nat → BufferState α → Prop where
  | fresh (capacity : Nat) (word : capacity < 2^bits) :
      StorageHistory bits capacity ⟨List.replicate capacity none, 0⟩
  | append {capacity : Nat} {state next : BufferState α} (input : α) :
      StorageHistory bits capacity state →
      JarlStorage.state_State_push bits capacity state input = .returned (.ok ()) next →
      StorageHistory bits capacity next
  | grow {oldCapacity newCapacity : Nat} {state next : BufferState α} :
      StorageHistory bits oldCapacity state → oldCapacity ≤ newCapacity → newCapacity < 2^bits →
      JarlStorage.state_State_grow oldCapacity newCapacity state () = .returned next () →
      StorageHistory bits newCapacity next

private theorem storage_history_valid (bits capacity : Nat) (state : BufferState α)
    (history : StorageHistory bits capacity state) : Shape state capacity ∧ capacity < 2^bits := by
  induction history with
  | fresh capacity word => exact ⟨(fresh_representation (α := α) (fun _ => capacity)).2, word⟩
  | @append capacity before next input previous execution ih =>
    have space : before.len < capacity := by
      have bound := ih.1.2.1
      by_cases h : before.len < capacity
      · exact h
      · have full : before.len = capacity := by omega
        rw [full_preserves_state_at_drop bits capacity before input full] at execution
        contradiction
    obtain ⟨result, computed, preserved, _⟩ :=
      append_preserves_shape bits capacity before input ih.1 space ih.2
    rw [computed] at execution
    cases execution
    exact ⟨preserved, ih.2⟩
  | @grow oldCapacity newCapacity before next previous grows word execution ih =>
    obtain ⟨result, computed, preserved, _, _⟩ :=
      grow_preserves_shape oldCapacity newCapacity before () ih.1 grows
    rw [computed] at execution
    cases execution
    exact ⟨preserved, word⟩

theorem history_supports_growth (bits capacity newCapacity : Nat) (state : BufferState α) (metadata : β)
    (history : StorageHistory bits capacity state) (grows : capacity ≤ newCapacity) :
    Shape state capacity ∧ capacity < 2^bits ∧
      ∃ next, JarlStorage.state_State_grow capacity newCapacity state metadata = .returned next metadata ∧
        Shape next newCapacity ∧ next.len = state.len ∧
        (∀ i, i < state.len → next.slots[i]? = state.slots[i]?) := by
  have valid := storage_history_valid bits capacity state history
  exact ⟨valid.1, valid.2, grow_preserves_shape capacity newCapacity state metadata valid.1 grows⟩
end Storage
