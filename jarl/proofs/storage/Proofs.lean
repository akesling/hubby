import Generated
open Provium.State
namespace Storage

-- This is the representation predicate still to be established for restore and
-- snapshot installation. Payloads are opaque owned values.
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
private theorem clear_preserves_shape (state : BufferState α) (capacity : Nat)
    (shape : Shape state capacity) (positive : state.len > 0) :
    Shape (⟨state.slots.set (state.len - 1) none, state.len - 1⟩ : BufferState α) capacity := by
  refine ⟨by simpa using shape.1, by dsimp; have := shape.2.1; omega, ?_, ?_⟩
  · intro i hi
    dsimp at hi ⊢
    obtain ⟨value, present⟩ := shape.2.2.1 i (by omega)
    exact ⟨value, by simpa [List.getElem?_set_ne (show state.len - 1 ≠ i by omega)] using present⟩
  · intro i hi bound
    dsimp at hi ⊢
    by_cases equal : i = state.len - 1
    · subst i
      exact List.getElem?_set_self (by rw [shape.1]; have := shape.2.1; omega)
    · simpa [List.getElem?_set_ne (Ne.symm equal)] using shape.2.2.2 i (by omega) bound

private theorem truncate_shape (program : Truncation) (view : α → Path → InitStore)
    (records : SelectionStore) (boundary fuel capacity : Nat) (state next : BufferState α)
    (shape : Shape state capacity)
    (execution : resumeTruncation (truncateSteps program view records boundary fuel state) = .returned next) :
    Shape next capacity ∧ next.len ≤ state.len ∧
      (∀ i, i < next.len → next.slots[i]? = state.slots[i]?) := by
  induction fuel generalizing state with
  | zero => simp [truncateSteps, resumeTruncation] at execution
  | succ fuel ih =>
    simp only [truncateSteps] at execution
    split at execution
    · simp [resumeTruncation] at execution
    · split at execution
      · split at execution
        · simp [resumeTruncation] at execution
        · split at execution
          · rename_i condition
            have positive : state.len > 0 := condition.2
            have preserved := clear_preserves_shape state capacity shape positive
            split at execution
            · simp [resumeTruncation] at execution
            · split at execution <;> try simp only [resumeTruncation] at execution
              all_goals
                obtain ⟨valid, shorter, front⟩ := ih _ preserved execution
                refine ⟨valid, by dsimp at shorter; omega, ?_⟩
                intro i hi
                rw [front i hi]
                dsimp
                exact List.getElem?_set_ne (by dsimp at shorter; omega)
          · simp only [resumeTruncation, TruncationRun.returned.injEq] at execution
            subst next
            exact ⟨shape, Nat.le_refl _, fun _ _ => rfl⟩
      all_goals simp [resumeTruncation] at execution

theorem truncation_preserves_shape (view : α → Path → InitStore) (records : SelectionStore)
    (boundary capacity : Nat) (state next : BufferState α) (shape : Shape state capacity)
    (execution : resumeTruncation (JarlStorage.state_State_truncate view records state boundary) = .returned next) :
    Shape next capacity ∧ next.len ≤ state.len ∧
      (∀ i, i < next.len → next.slots[i]? = state.slots[i]?) := by
  exact truncate_shape _ view records boundary _ capacity state next shape execution

-- Capacity is part of the history index, so growth is not treated as a fixed
-- capacity assumption. These histories still exclude restore and snapshot installation.
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

  | truncate {capacity : Nat} {state next : BufferState α}
      (view : α → Path → InitStore) (records : SelectionStore) (boundary : Nat) :
      StorageHistory bits capacity state →
      resumeTruncation (JarlStorage.state_State_truncate view records state boundary) = .returned next →
      StorageHistory bits capacity next

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
  | @truncate capacity before next view records boundary previous execution ih =>
    exact ⟨(truncation_preserves_shape view records boundary capacity before next ih.1 execution).1, ih.2⟩

theorem history_supports_growth (bits capacity newCapacity : Nat) (state : BufferState α) (metadata : β)
    (history : StorageHistory bits capacity state) (grows : capacity ≤ newCapacity) :
    Shape state capacity ∧ capacity < 2^bits ∧
      ∃ next, JarlStorage.state_State_grow capacity newCapacity state metadata = .returned next metadata ∧
        Shape next newCapacity ∧ next.len = state.len ∧
        (∀ i, i < state.len → next.slots[i]? = state.slots[i]?) := by
  have valid := storage_history_valid bits capacity state history
  exact ⟨valid.1, valid.2, grow_preserves_shape capacity newCapacity state metadata valid.1 grows⟩
-- Bind the projected buffer state to the original Rust places and capacity
-- parameters. Changing which fields a source method operates on must invalidate
-- this contract, even if its arithmetic would still preserve an abstract buffer.
theorem append_representation (bits capacity : Nat) (state : BufferState α) (input : α)
    (shape : Shape state capacity) (space : state.len < capacity) (word : capacity < 2^bits) :
    JarlStorage.state_State_push_ir.slotsPath = ["entries"] ∧
    JarlStorage.state_State_push_ir.lengthPath = ["len"] ∧
    JarlStorage.state_State_push_ir.capacityName = "CAP" ∧
    JarlStorage.state_State_push bits capacity state input =
      .returned (.ok ()) ⟨state.slots.set state.len (some input), state.len + 1⟩ := by
  exact ⟨rfl, rfl, rfl, append_exact bits capacity state input shape space word⟩

theorem growth_representation (oldCapacity newCapacity : Nat) (live : List α) (metadata : β)
    (fits : live.length ≤ oldCapacity) (grows : oldCapacity ≤ newCapacity) :
    JarlStorage.state_State_grow_ir.slotsPath = ["entries"] ∧
    JarlStorage.state_State_grow_ir.lengthPath = ["len"] ∧
    JarlStorage.state_State_grow_ir.oldCapacityName = "CAP" ∧
    JarlStorage.state_State_grow_ir.newCapacityName = "NEW" ∧
    JarlStorage.state_State_grow oldCapacity newCapacity
      ⟨live.map some ++ List.replicate (oldCapacity - live.length) none, live.length⟩ metadata =
      .returned ⟨live.map some ++ List.replicate (newCapacity - live.length) none, live.length⟩ metadata := by
  exact ⟨rfl, rfl, rfl, rfl, grow_exact oldCapacity newCapacity live metadata fits grows⟩

private theorem places_append (path : Path) (start : Nat) (first rest : List (Option α)) :
    presentPlaces path start (first ++ rest) =
      presentPlaces path start first ++ presentPlaces path (start + first.length) rest := by
  induction first generalizing start with
  | nil => simp [presentPlaces]
  | cons entry tail ih =>
    cases entry <;> simp [presentPlaces, ih, Nat.add_right_comm, Nat.add_assoc]

private theorem last_before_truncation (view : α → Path → InitStore) (records : SelectionStore)
    (front suffix : List (Option α)) (entry : α) :
    lastRecord JarlStorage.state_State_truncate_ir.last
      (truncationView view records ⟨(front ++ [some entry]) ++ suffix,front.length + 1⟩) =
      .ok (view entry ["id"]) := by
  let state := truncationView view records (⟨(front ++ [some entry]) ++ suffix,front.length + 1⟩ : BufferState α)
  have slots : state.lookups.slots ["entries"] =
      (front.map (Option.map view) ++ [some (view entry)]) ++ suffix.map (Option.map view) := by
    simp [state, truncationView]
  have iter : iterateRecords JarlStorage.state_State_truncate_ir.last.iteration state =
      .ok (presentPlaces ["entries"] 0 (front.map (Option.map view)) ++ [⟨["entries"],front.length⟩]) := by
    simp only [iterateRecords, JarlStorage.state_State_truncate_ir]
    change (if front.length + 1 + 0 ≤ (state.lookups.slots ["entries"]).length then _ else _) = _
    rw [slots]
    simp only [List.length_append, List.length_map, List.length_singleton, Nat.add_zero]
    rw [if_pos (by omega), List.take_left' (by simp [state, truncationView])]
    simp [places_append, presentPlaces]
  have hit : (state.lookups.slots ["entries"])[front.length]? = some (some (view entry)) := by
    rw [slots, List.getElem?_append_left (by simp), List.getElem?_append_right (by simp)]
    simp
  change lastRecord JarlStorage.state_State_truncate_ir.last state = _
  simp only [lastRecord, iter]
  simp [JarlStorage.state_State_truncate_ir, hit]

theorem truncation_drop_order (view : α → Path → InitStore) (records : SelectionStore)
    (front suffix : List (Option α)) (entry : α) (index boundary : Nat)
    (value : view entry ["id"] ["index"] = .unsigned "u64" index)
    (valid_index : index < 2^64) (valid_boundary : boundary < 2^64) (remove : boundary ≤ index) :
    JarlStorage.state_State_truncate view records ⟨(front ++ [some entry]) ++ suffix,front.length + 1⟩ boundary =
      .drop entry ⟨(front ++ [some entry]) ++ suffix,front.length⟩
        (JarlStorage.state_State_truncate view records
          ⟨((front ++ [some entry]) ++ suffix).set front.length none,front.length⟩ boundary) := by
  have read := last_before_truncation view records front suffix entry
  have vi : ¬ index ≥ 2^64 := by omega
  have vb : ¬ boundary ≥ 2^64 := by omega
  unfold JarlStorage.state_State_truncate truncateBuffer
  rw [truncateSteps, read]
  simp [JarlStorage.state_State_truncate_ir, value, vi, vb, truncationCompare, remove]

theorem truncation_empty (view : α → Path → InitStore) (records : SelectionStore)
    (slots : List (Option α)) (base boundary : Nat)
    (base_value : selectRecord JarlStorage.state_State_truncate_ir.last.base records ["index"] = .unsigned "u64" base)
    (valid_base : base < 2^64) (valid_boundary : boundary < 2^64) :
    JarlStorage.state_State_truncate view records ⟨slots,0⟩ boundary = .returned ⟨slots,0⟩ := by
  have vb : ¬ base ≥ 2^64 := by omega
  have vi : ¬ boundary ≥ 2^64 := by omega
  have selected : lastRecord JarlStorage.state_State_truncate_ir.last
      (truncationView view records ⟨slots,0⟩) =
      .ok (selectRecord JarlStorage.state_State_truncate_ir.last.base records) := by
    simp [lastRecord,iterateRecords,truncationView,JarlStorage.state_State_truncate_ir,presentPlaces]
  unfold JarlStorage.state_State_truncate truncateBuffer
  rw [truncateSteps,selected]
  simp only [show JarlStorage.state_State_truncate_ir.indexField = ["index"] by rfl,base_value]
  simp [vb,vi]

private theorem truncate_fuel_sufficient (program : Truncation) (view : α → Path → InitStore)
    (records : SelectionStore) (boundary fuel : Nat) (state failed : BufferState α)
    (enough : state.len < fuel) :
    resumeTruncation (truncateSteps program view records boundary fuel state) ≠ .fault .exhausted failed := by
  induction fuel generalizing state with
  | zero => omega
  | succ fuel ih =>
    simp only [truncateSteps]
    split
    · simp [resumeTruncation]
    · split
      · split
        · simp [resumeTruncation]
        · split
          · rename_i condition
            have positive : state.len > 0 := condition.2
            split
            · simp [resumeTruncation]
            · split <;> try simp only [resumeTruncation]
              all_goals exact ih _ (by dsimp; omega)
          · simp [resumeTruncation]
      all_goals simp [resumeTruncation]

theorem truncation_fuel_sufficient (view : α → Path → InitStore) (records : SelectionStore)
    (boundary : Nat) (state failed : BufferState α) :
    resumeTruncation (JarlStorage.state_State_truncate view records state boundary) ≠ .fault .exhausted failed := by
  exact truncate_fuel_sufficient _ view records boundary _ state failed (by omega)

end Storage
