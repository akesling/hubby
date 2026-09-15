import Generated
open Provium.State
namespace Storage

-- All translated storage operations preserve this occupied-prefix predicate.
-- Payloads are opaque owned values; log semantics are separate obligations.
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


private theorem finish_installation_frame (program : Installation) (snapshotView : β → Path → InitStore)
    (state next : InstallationState α β) (input : β) (maximum : program.maximum = true)
    (execution : resumeInstallation (finishInstallation program snapshotView state input) = .returned next) :
    next.buffer = state.buffer ∧ state.commit ≤ next.commit ∧ next.snapshot = some input := by
  simp only [finishInstallation,maximum] at execution
  split at execution
  · simp [resumeInstallation] at execution
  · split at execution
    · simp [resumeInstallation] at execution
    · split at execution <;> simp [resumeInstallation] at execution
      all_goals subst next; exact ⟨rfl,Nat.le_max_left _ _,rfl⟩

private theorem clear_installation_frame (program : Installation) (snapshotView : β → Path → InitStore)
    (state next : InstallationState α β) (input : β) (resetLength : Bool) (start count : Nat)
    (maximum : program.maximum = true)
    (execution : resumeInstallation (clearInstallation program snapshotView resetLength input start count state) = .returned next) :
    next.buffer.slots.length = state.buffer.slots.length ∧ next.buffer.len ≤ state.buffer.len ∧
      state.commit ≤ next.commit ∧ next.snapshot = some input := by
  induction count generalizing start state with
  | zero =>
    have result := finish_installation_frame program snapshotView _ next input maximum execution
    cases resetLength <;> simp_all
  | succ count ih =>
    simp only [clearInstallation] at execution
    split at execution
    · simp [resumeInstallation] at execution
    · split at execution <;> try simp only [resumeInstallation] at execution
      all_goals
        obtain ⟨length, short, commit, snapshot⟩ := ih _ _ execution
        exact ⟨by simpa using length,short,commit,snapshot⟩

theorem installation_preserves_capacity_and_commit (bits : Nat) (view : α → Path → InitStore)
    (snapshotView : β → Path → InitStore) (state next : InstallationState α β) (input : β)
    (execution : resumeInstallation (JarlStorage.state_State_install bits view snapshotView state input) = .returned next) :
    next.buffer.slots.length = state.buffer.slots.length ∧ next.buffer.len ≤ state.buffer.len ∧
      state.commit ≤ next.commit ∧ next.snapshot = some input := by
  unfold JarlStorage.state_State_install installSnapshot at execution
  dsimp only [JarlStorage.state_State_install_ir] at execution
  simp only [if_true] at execution
  split at execution
  · simp [resumeInstallation] at execution
  · split at execution
    · simp [resumeInstallation] at execution
    · split at execution
      · simp [resumeInstallation] at execution
      · split at execution
        · split at execution
          · simp [resumeInstallation] at execution
          · split at execution
            · simp [resumeInstallation] at execution
            · split at execution
              · simp [resumeInstallation] at execution
              · obtain ⟨length, shorter, commit, snapshot⟩ :=
                  clear_installation_frame _ snapshotView _ next input false _ _ rfl execution
                refine ⟨?_, ?_, commit, snapshot⟩
                · simp only [List.length_append,List.length_drop,List.length_take] at length
                  omega
                · dsimp at shorter
                  omega
        · split at execution
          · simp [resumeInstallation] at execution
          · exact clear_installation_frame _ snapshotView state next input true 0 _ rfl execution

private theorem clear_installation_exact (program : Installation) (snapshotView : β → Path → InitStore)
    (front removed suffix : List (Option α)) (length commit : Nat) (saved : Option β)
    (input : β) (resetLength : Bool) :
    resumeInstallation (clearInstallation program snapshotView resetLength input front.length removed.length
      ⟨⟨front ++ removed ++ suffix,length⟩,commit,saved⟩) =
    resumeInstallation (finishInstallation program snapshotView
      ⟨⟨front ++ List.replicate removed.length none ++ suffix,if resetLength then 0 else length⟩,commit,saved⟩ input) := by
  induction removed generalizing front with
  | nil => cases resetLength <;> simp [clearInstallation]
  | cons entry rest ih =>
    have hit : (front ++ (entry :: rest) ++ suffix)[front.length]? = some entry := by
      rw [List.getElem?_append_left (by simp),List.getElem?_append_right (by omega)]
      simp
    have store : (front ++ (entry :: rest) ++ suffix).set front.length none =
        (front ++ [none]) ++ rest ++ suffix := by
      simp [List.append_assoc]
    simp only [List.length_cons,clearInstallation,hit]
    cases entry <;> simp only [resumeInstallation]
    all_goals
      rw [store]
      have step := ih (front ++ [none])
      simp only [List.length_append,List.length_singleton] at step
      rw [step]
      simp [List.replicate_succ,List.append_assoc]

theorem installation_matching_suffix_by_equality (bits base commit : Nat) (view : α → Path → InitStore)
    (snapshotView : β → Path → InitStore) (removed retained padding : List (Option α))
    (saved : Option β) (input : β) (found : Option InitStore)
    (index_value : snapshotView input ["last"] ["index"] = .unsigned "u64" (base + removed.length))
    (index_valid : base + removed.length < 2^64) (word_bound : removed.length < 2^bits)
    (commit_valid : commit < 2^64)
    (base_value : selectRecord JarlStorage.state_State_install_ir.recordAt.lookup.base
      (installationView view snapshotView ⟨⟨removed ++ retained ++ padding,removed.length + retained.length⟩,commit,saved⟩).records
      ["index"] = .unsigned "u64" base)
    (matched : recordAt JarlStorage.state_State_install_ir.recordAt bits
      (installationView view snapshotView ⟨⟨removed ++ retained ++ padding,removed.length + retained.length⟩,commit,saved⟩)
      (base + removed.length) = .ok found)
    (equal : recordEquality found (snapshotView input ["last"]) [["index"],["term"]] = some true) :
    resumeInstallation (JarlStorage.state_State_install bits view snapshotView
      ⟨⟨removed ++ retained ++ padding,removed.length + retained.length⟩,commit,saved⟩ input) =
      .returned ⟨⟨retained ++ List.replicate (removed.length + padding.length) none,retained.length⟩,
        max commit (base + removed.length),some input⟩ := by
  have input_word : recordWord (snapshotView input ["last"]) ["index"] = some (base + removed.length) := by
    simp [recordWord,index_value,index_valid]
  have base_valid : base < 2^64 := by omega
  have base_word : recordWord (selectRecord JarlStorage.state_State_install_ir.recordAt.lookup.base
      (installationView view snapshotView ⟨⟨removed ++ retained ++ padding,removed.length + retained.length⟩,commit,saved⟩).records)
      ["index"] = some base := by
    unfold recordWord
    rw [base_value]
    simp [base_valid]
  unfold JarlStorage.state_State_install installSnapshot
  simp only [show JarlStorage.state_State_install_ir.recordField = ["last"] by rfl,
    show JarlStorage.state_State_install_ir.indexField = ["index"] by rfl,
    input_word,matched,show JarlStorage.state_State_install_ir.equalityFields = [["index"],["term"]] by rfl,equal]
  simp only [beq_self_eq_true,show JarlStorage.state_State_install_ir.equal = true by rfl,if_true,
    show JarlStorage.state_State_install_ir.baseIndexField = ["index"] by rfl,base_word]
  have subtraction : base + removed.length - base = removed.length := by omega
  have no_underflow : ¬ base + removed.length < base := by omega
  simp only [no_underflow,if_false,subtraction,Nat.mod_eq_of_lt word_bound,
    show JarlStorage.state_State_install_ir.rotateLeft = true by rfl,if_true]
  simp only [List.length_append]
  rw [if_neg (by omega)]
  rw [List.take_left' (by simp)]
  simp only [List.drop_left,List.take_left]
  have tail : List.drop (removed.length + retained.length) (removed ++ retained ++ padding) = padding := by
    rw [← List.length_append, List.drop_left]
  rw [tail]
  simp only [Nat.add_sub_cancel_left, Nat.add_assoc]
  have clear := clear_installation_exact JarlStorage.state_State_install_ir snapshotView retained
    (removed ++ padding) [] retained.length commit saved input false
  simp only [List.length_append,List.append_nil,Bool.false_eq_true,if_false] at clear
  simp only [List.append_assoc]
  rw [clear]
  unfold finishInstallation
  simp only [show JarlStorage.state_State_install_ir.recordField = ["last"] by rfl,
    show JarlStorage.state_State_install_ir.commitIndexField = ["index"] by rfl,input_word]
  have bound : ¬ commit ≥ 2^64 := by omega
  simp only [bound,if_false,show JarlStorage.state_State_install_ir.maximum = true by rfl,if_true]
  cases saved <;> rfl

theorem installation_matching_suffix (bits base commit : Nat) (view : α → Path → InitStore)
    (snapshotView : β → Path → InitStore) (removed retained padding : List (Option α))
    (saved : Option β) (input : β) (words : List Nat)
    (index_value : snapshotView input ["last"] ["index"] = .unsigned "u64" (base + removed.length))
    (index_valid : base + removed.length < 2^64) (word_bound : removed.length < 2^bits)
    (commit_valid : commit < 2^64)
    (base_value : selectRecord JarlStorage.state_State_install_ir.recordAt.lookup.base
      (installationView view snapshotView ⟨⟨removed ++ retained ++ padding,removed.length + retained.length⟩,commit,saved⟩).records
      ["index"] = .unsigned "u64" base)
    (matched : recordAt JarlStorage.state_State_install_ir.recordAt bits
      (installationView view snapshotView ⟨⟨removed ++ retained ++ padding,removed.length + retained.length⟩,commit,saved⟩)
      (base + removed.length) = .ok (some (snapshotView input ["last"])))
    (values : recordWords (snapshotView input ["last"]) [["index"],["term"]] = some words) :
    resumeInstallation (JarlStorage.state_State_install bits view snapshotView
      ⟨⟨removed ++ retained ++ padding,removed.length + retained.length⟩,commit,saved⟩ input) =
      .returned ⟨⟨retained ++ List.replicate (removed.length + padding.length) none,retained.length⟩,
        max commit (base + removed.length),some input⟩ := by
  apply installation_matching_suffix_by_equality bits base commit view snapshotView removed retained padding saved input
    (some (snapshotView input ["last"])) index_value index_valid word_bound commit_valid base_value matched
  simp [recordEquality,values,bind,pure,Option.bind]

theorem installation_mismatching_prefix (bits index commit : Nat) (view : α → Path → InitStore)
    (snapshotView : β → Path → InitStore) (retained padding : List (Option α))
    (saved : Option β) (input : β) (found : Option InitStore)
    (index_value : snapshotView input ["last"] ["index"] = .unsigned "u64" index)
    (index_valid : index < 2^64) (commit_valid : commit < 2^64)
    (different : recordEquality found (snapshotView input ["last"]) [["index"],["term"]] = some false)
    (looked : recordAt JarlStorage.state_State_install_ir.recordAt bits
      (installationView view snapshotView ⟨⟨retained ++ padding,retained.length⟩,commit,saved⟩)
      index = .ok found) :
    resumeInstallation (JarlStorage.state_State_install bits view snapshotView
      ⟨⟨retained ++ padding,retained.length⟩,commit,saved⟩ input) =
      .returned ⟨⟨List.replicate retained.length none ++ padding,0⟩,max commit index,some input⟩ := by
  have input_word : recordWord (snapshotView input ["last"]) ["index"] = some index := by
    simp [recordWord,index_value,index_valid]
  unfold JarlStorage.state_State_install installSnapshot
  simp only [show JarlStorage.state_State_install_ir.recordField = ["last"] by rfl,
    show JarlStorage.state_State_install_ir.indexField = ["index"] by rfl,input_word,looked,
    show JarlStorage.state_State_install_ir.equalityFields = [["index"],["term"]] by rfl,
    show JarlStorage.state_State_install_ir.equal = true by rfl]
  rw [different]
  simp
  rw [if_neg (by omega)]
  have clear := clear_installation_exact JarlStorage.state_State_install_ir snapshotView [] retained padding
    retained.length commit saved input true
  simp only [List.length_nil,List.nil_append,if_true] at clear
  rw [clear]
  unfold finishInstallation
  simp only [show JarlStorage.state_State_install_ir.recordField = ["last"] by rfl,
    show JarlStorage.state_State_install_ir.commitIndexField = ["index"] by rfl,input_word]
  have bound : ¬ commit ≥ 2^64 := by omega
  simp only [bound,if_false,show JarlStorage.state_State_install_ir.maximum = true by rfl,if_true]
  cases saved <;> rfl

theorem installation_places (bits : Nat) (view : α → Path → InitStore)
    (snapshotView : β → Path → InitStore) (state next : InstallationState α β) (input : β)
    (execution : resumeInstallation (JarlStorage.state_State_install bits view snapshotView state input) = .returned next) :
    JarlStorage.state_State_install_ir.slotsPath = ["entries"] ∧
    JarlStorage.state_State_install_ir.lengthPath = ["len"] ∧
    JarlStorage.state_State_install_ir.snapshotPath = ["snapshot"] ∧
    JarlStorage.state_State_install_ir.commitPath = ["hard","commit"] ∧
    next.buffer.slots.length = state.buffer.slots.length ∧ next.buffer.len ≤ state.buffer.len ∧
      state.commit ≤ next.commit ∧ next.snapshot = some input := by
  exact ⟨rfl,rfl,rfl,rfl,installation_preserves_capacity_and_commit bits view snapshotView state next input execution⟩

private theorem rotation_preserves_shape (state : BufferState α) (capacity amount : Nat)
    (shape : Shape state capacity) (bound : amount ≤ state.len) :
    Shape (⟨(state.slots.take state.len).drop amount ++ (state.slots.take state.len).take amount ++
      state.slots.drop state.len,state.len⟩ : BufferState α) capacity := by
  let front := state.slots.take state.len
  have front_length : front.length = state.len := by
    simp only [front,List.length_take,shape.1]
    exact Nat.min_eq_left shape.2.1
  let rotated := front.drop amount ++ front.take amount
  have rotated_length : rotated.length = state.len := by
    simp only [rotated,List.length_append,List.length_drop,List.length_take,front_length]
    omega
  have filled : ∀ entry, entry ∈ front → ∃ value, entry = some value := by
    intro entry member
    obtain ⟨i,hi,equal⟩ := List.getElem_of_mem member
    have inside : i < state.len := by omega
    obtain ⟨value,present⟩ := shape.2.2.1 i inside
    have fetched : front[i]? = some entry := by simp [List.getElem?_eq_getElem hi,equal]
    have original : front[i]? = state.slots[i]? := List.getElem?_take_of_lt inside
    rw [original,present] at fetched
    exact ⟨value,Option.some.inj fetched.symm⟩
  have rotated_filled : ∀ entry, entry ∈ rotated → ∃ value, entry = some value := by
    intro entry member
    rcases List.mem_append.mp member with first | second
    · exact filled entry (List.mem_of_mem_drop first)
    · exact filled entry (List.mem_of_mem_take second)
  change Shape ⟨rotated ++ state.slots.drop state.len,state.len⟩ capacity
  refine ⟨?_,shape.2.1,?_,?_⟩
  · simp only [List.length_append,rotated_length,List.length_drop,shape.1]
    have := shape.2.1
    omega
  · intro i inside
    dsimp at inside
    have index : i < rotated.length := by omega
    obtain ⟨value,equal⟩ := rotated_filled rotated[i] (List.getElem_mem index)
    refine ⟨value,?_⟩
    dsimp
    rw [List.getElem?_append_left index,List.getElem?_eq_getElem index,equal]
  · intro i after inside
    dsimp at after
    dsimp
    rw [List.getElem?_append_right (by omega),List.getElem?_drop]
    have index : state.len + (i - rotated.length) = i := by omega
    rw [index]
    exact shape.2.2.2 i after inside

private theorem shortened_shape (state : BufferState α) (capacity keep : Nat)
    (shape : Shape state capacity) (shorter : keep ≤ state.len) :
    Shape (⟨state.slots.take keep ++ List.replicate (capacity - keep) none,keep⟩ : BufferState α) capacity := by
  have bounded : keep ≤ state.slots.length := by rw [shape.1]; have := shape.2.1; omega
  have count : (state.slots.take keep).length = keep := by simp [List.length_take,Nat.min_eq_left bounded]
  refine ⟨?_,by dsimp; have := shape.2.1; omega,?_,?_⟩
  · simp only [List.length_append,count,List.length_replicate]
    have := shape.2.1
    omega
  · intro i inside
    dsimp at inside ⊢
    obtain ⟨value,present⟩ := shape.2.2.1 i (by omega)
    refine ⟨value,?_⟩
    rw [List.getElem?_append_left (by omega),List.getElem?_take_of_lt inside]
    exact present
  · intro i after inside
    dsimp at after ⊢
    rw [List.getElem?_append_right (by omega),List.getElem?_replicate]
    rw [if_pos (by omega)]

private theorem clearing_suffix_preserves_shape (program : Installation) (snapshotView : β → Path → InitStore)
    (state next : InstallationState α β) (input : β) (capacity oldLength : Nat)
    (maximum : program.maximum = true) (shape : Shape ⟨state.buffer.slots,oldLength⟩ capacity)
    (shorter : state.buffer.len ≤ oldLength)
    (execution : resumeInstallation (clearInstallation program snapshotView false input state.buffer.len
      (state.buffer.slots.length - state.buffer.len) state) = .returned next) : Shape next.buffer capacity := by
  rcases state with ⟨⟨slots,keep⟩,commit,saved⟩
  dsimp [Shape] at shape
  dsimp at shorter execution
  have bounded : keep ≤ slots.length := by have := shape.1;have := shape.2.1;omega
  have count : (slots.take keep).length = keep := by simp [List.length_take,Nat.min_eq_left bounded]
  have clear := clear_installation_exact program snapshotView (slots.take keep) (slots.drop keep) []
    keep commit saved input false
  simp only [count,List.length_drop,List.append_nil,List.take_append_drop,Bool.false_eq_true,if_false] at clear
  rw [clear] at execution
  have result := finish_installation_frame program snapshotView _ next input maximum execution
  rw [result.1]
  have shortened := shortened_shape (⟨slots,oldLength⟩ : BufferState α) capacity keep shape shorter
  simpa only [shape.1] using shortened

private theorem clearing_prefix_preserves_shape (program : Installation) (snapshotView : β → Path → InitStore)
    (state next : InstallationState α β) (input : β) (capacity : Nat)
    (maximum : program.maximum = true) (shape : Shape state.buffer capacity)
    (execution : resumeInstallation (clearInstallation program snapshotView true input 0 state.buffer.len state) = .returned next) :
    Shape next.buffer capacity := by
  rcases state with ⟨⟨slots,length⟩,commit,saved⟩
  dsimp [Shape] at shape
  dsimp at execution
  have bounded : length ≤ slots.length := by have := shape.1;have := shape.2.1;omega
  have count : (slots.take length).length = length := by simp [List.length_take,Nat.min_eq_left bounded]
  have clear := clear_installation_exact program snapshotView [] (slots.take length) (slots.drop length)
    length commit saved input true
  simp only [count,List.length_nil,List.nil_append,List.take_append_drop,if_true] at clear
  rw [clear] at execution
  have result := finish_installation_frame program snapshotView _ next input maximum execution
  rw [result.1]
  refine ⟨?_,by simp,?_,?_⟩
  · simp only [List.length_append,List.length_replicate,List.length_drop]
    have := shape.1
    omega
  · intro i inside
    dsimp at inside
    omega
  · intro i _ inside
    dsimp
    by_cases before : i < length
    · rw [List.getElem?_append_left (by simpa using before),List.getElem?_replicate,if_pos before]
    · rw [List.getElem?_append_right (by simp;omega),List.getElem?_drop,List.length_replicate]
      have index : length + (i - length) = i := by omega
      rw [index]
      exact shape.2.2.2 i (by omega) inside

private theorem clear_suffix_execution (program : Installation) (snapshotView : β → Path → InitStore)
    (state next : InstallationState α β) (input : β) (capacity oldLength start count : Nat)
    (execution : resumeInstallation (clearInstallation program snapshotView false input start count state) = .returned next)
    (maximum : program.maximum = true) (shape : Shape ⟨state.buffer.slots,oldLength⟩ capacity)
    (shorter : state.buffer.len ≤ oldLength)
    (range : start = state.buffer.len ∧ count = state.buffer.slots.length - state.buffer.len) : Shape next.buffer capacity := by
  rcases range with ⟨rfl,rfl⟩
  exact clearing_suffix_preserves_shape program snapshotView state next input capacity oldLength maximum shape shorter execution

theorem installation_preserves_shape (bits capacity : Nat) (view : α → Path → InitStore)
    (snapshotView : β → Path → InitStore) (state next : InstallationState α β) (input : β)
    (shape : Shape state.buffer capacity)
    (execution : resumeInstallation (JarlStorage.state_State_install bits view snapshotView state input) = .returned next) :
    Shape next.buffer capacity := by
  unfold JarlStorage.state_State_install installSnapshot at execution
  dsimp only [JarlStorage.state_State_install_ir] at execution
  simp only [if_true] at execution
  split at execution
  · simp [resumeInstallation] at execution
  · split at execution
    · simp [resumeInstallation] at execution
    · split at execution
      · simp [resumeInstallation] at execution
      · split at execution
        · split at execution
          · simp [resumeInstallation] at execution
          · split at execution
            · simp [resumeInstallation] at execution
            · split at execution
              · simp [resumeInstallation] at execution
              · refine clear_suffix_execution _ snapshotView _ next input capacity state.buffer.len _ _ execution rfl ?_ ?_ ⟨rfl,rfl⟩
                · exact rotation_preserves_shape state.buffer capacity _ shape (by omega)
                · dsimp
                  omega
        · split at execution
          · simp [resumeInstallation] at execution
          · exact clearing_prefix_preserves_shape _ snapshotView state next input capacity rfl shape execution

private theorem recovery_loop_shape (bits capacity fuel : Nat) (view : α → Path → InitStore)
    (snapshotView : β → Path → InitStore) (hardView : δ → InitStore) (hardPresence : δ → Path → Bool)
    (base : InitStore) (state output : RecoveryState α β δ) (iterator : ι)
    (shape : Shape state.buffer capacity) (word : capacity < 2^bits)
    (execution : RecoveryReturns (recoveryLoop JarlStorage.state_State_restore_ir bits capacity view snapshotView hardView hardPresence base fuel state iterator : RecoveryRun α β δ σ ι) (.ok output)) :
    Shape output.buffer capacity ∧ output.hard = state.hard ∧ output.snapshot = state.snapshot := by
  induction fuel generalizing state iterator with
  | zero => simp [recoveryLoop] at execution
  | succ fuel ih =>
    simp only [recoveryLoop,recovery_returns_next] at execution
    obtain ⟨entry,advanced,execution⟩ := execution
    cases entry with
    | none =>
      simp only [recovery_returns_dropIterator] at execution
      obtain ⟨same,_⟩ := recovery_finish_success _ view snapshotView hardView hardPresence state output base execution
      cases same
      exact ⟨shape,rfl,rfl⟩
    | some entry =>
      dsimp only at execution
      split at execution
      · simp at execution
      · split at execution
        · simp at execution
        · simp at execution
        · obtain ⟨buffer,appended,continued⟩ := recovery_append_success _ state output advanced _ _ execution
          change resumeDrops (JarlStorage.state_State_push bits capacity state.buffer entry) = .returned (.ok ()) buffer at appended
          have space : state.buffer.len < capacity := by
            by_cases room : state.buffer.len < capacity
            · exact room
            · have full : state.buffer.len = capacity := by have := shape.2.1;omega
              rw [full_preserves_state_at_drop bits capacity state.buffer entry full] at appended
              simp [resumeDrops] at appended
          obtain ⟨updated,computed,preserved,_⟩ := append_preserves_shape bits capacity state.buffer entry shape space word
          rw [computed] at appended
          simp only [resumeDrops,BufferRun.returned.injEq] at appended
          obtain ⟨_,same⟩ := appended
          cases same
          exact ih {state with buffer := buffer} advanced preserved continued

theorem restoration_preserves_shape (bits : Nat) (sizes : String → Nat)
    (view : α → Path → InitStore) (snapshotView : β → Path → InitStore)
    (hardView : δ → InitStore) (hardPresence : δ → Path → Bool)
    (hard : δ) (snapshot : Option β) (source : σ) (output : RecoveryState α β δ)
    (word : sizes "CAP" < 2^bits)
    (execution : RecoveryReturns (JarlStorage.state_State_restore bits sizes view snapshotView hardView hardPresence hard snapshot source : RecoveryRun α β δ σ ι) (.ok output)) :
    Shape output.buffer (sizes "CAP") ∧ output.hard = hard ∧ output.snapshot = snapshot := by
  unfold JarlStorage.state_State_restore restoreState at execution
  simp only [JarlStorage.state_State_restore_ir,initializeFields,initialCell] at execution
  simp at execution
  split at execution
  · simp at execution
  · simp at execution
  · simp only [recovery_returns_intoIterator] at execution
    obtain ⟨iterator,execution⟩ := execution
    exact recovery_loop_shape bits (sizes "CAP") _ view snapshotView hardView hardPresence _
      ⟨⟨List.replicate (sizes "CAP") none,0⟩,hard,snapshot⟩ output iterator
      (fresh_representation (α := α) sizes).2 word execution

private theorem recovery_loop_fuel_safe (bits capacity fuel : Nat) (view : α → Path → InitStore)
    (snapshotView : β → Path → InitStore) (hardView : δ → InitStore) (hardPresence : δ → Path → Bool)
    (base : InitStore) (state : RecoveryState α β δ) (iterator : ι)
    (shape : Shape state.buffer capacity) (word : capacity < 2^bits)
    (enough : capacity < state.buffer.len + fuel) :
    recoveryFuelSafe (recoveryLoop JarlStorage.state_State_restore_ir bits capacity view snapshotView hardView hardPresence base fuel state iterator : RecoveryRun α β δ σ ι) := by
  induction fuel generalizing state iterator with
  | zero => have := shape.2.1;omega
  | succ fuel ih =>
    rw [recoveryLoop]
    change ∀ entry advanced, _
    intro entry advanced
    cases entry with
    | none => exact recovery_finish_fuel_safe _ view snapshotView hardView hardPresence state base
    | some entry =>
      dsimp only
      split
      · trivial
      · split
        · trivial
        · simp [recoveryFuelSafe]
        · by_cases space : state.buffer.len < capacity
          · obtain ⟨buffer,computed,preserved,advanced_length⟩ := append_preserves_shape bits capacity state.buffer entry shape space word
            have appended : appendBuffer JarlStorage.state_State_restore_ir.append bits capacity state.buffer entry =
                .returned (.ok ()) buffer := computed
            rw [appended]
            simp only [recoveryAppend]
            exact ih {state with buffer := buffer} advanced preserved (by dsimp;rw [advanced_length];omega)
          · have full : state.buffer.len = capacity := by have := shape.2.1;omega
            have appended : appendBuffer JarlStorage.state_State_restore_ir.append bits capacity state.buffer entry =
                .drop entry state.buffer (.returned (.error "Error::Full") state.buffer) :=
              full_preserves_state_at_drop bits capacity state.buffer entry full
            rw [appended]
            simp [recoveryAppend,recoveryFuelSafe]

theorem restoration_fuel_sufficient (bits : Nat) (sizes : String → Nat)
    (view : α → Path → InitStore) (snapshotView : β → Path → InitStore)
    (hardView : δ → InitStore) (hardPresence : δ → Path → Bool)
    (hard : δ) (snapshot : Option β) (source : σ) (word : sizes "CAP" < 2^bits) :
    recoveryFuelSafe (JarlStorage.state_State_restore bits sizes view snapshotView hardView hardPresence hard snapshot source : RecoveryRun α β δ σ ι) := by
  unfold JarlStorage.state_State_restore restoreState
  simp only [JarlStorage.state_State_restore_ir,initializeFields,initialCell]
  simp
  split
  · trivial
  · simp [recoveryFuelSafe]
  · intro iterator
    exact recovery_loop_fuel_safe bits (sizes "CAP") _ view snapshotView hardView hardPresence _
      ⟨⟨List.replicate (sizes "CAP") none,0⟩,hard,snapshot⟩ iterator
      (fresh_representation (α := α) sizes).2 word (by simp)

-- Capacity is part of the history index, so growth is not treated as a fixed
-- capacity assumption. These are buffer histories; they do not encode protocol or durable-history reachability.
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

  | install {β : Type} {capacity : Nat} {before after : InstallationState α β}
      (view : α → Path → InitStore) (snapshotView : β → Path → InitStore) (input : β) :
      StorageHistory bits capacity before.buffer →
      resumeInstallation (JarlStorage.state_State_install bits view snapshotView before input) = .returned after →
      StorageHistory bits capacity after.buffer

  | restore {β δ σ ι : Type} (sizes : String → Nat)
      (view : α → Path → InitStore) (snapshotView : β → Path → InitStore)
      (hardView : δ → InitStore) (hardPresence : δ → Path → Bool)
      (hard : δ) (snapshot : Option β) (source : σ) (output : RecoveryState α β δ) :
      sizes "CAP" < 2^bits →
      RecoveryReturns (JarlStorage.state_State_restore bits sizes view snapshotView hardView hardPresence hard snapshot source : RecoveryRun α β δ σ ι) (.ok output) →
      StorageHistory bits (sizes "CAP") output.buffer

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
  | @install β capacity before after view snapshotView input previous execution ih =>
    exact ⟨installation_preserves_shape bits capacity view snapshotView before after input ih.1 execution,ih.2⟩
  | @restore β δ σ ι sizes view snapshotView hardView hardPresence hard snapshot source output word execution =>
    exact ⟨(restoration_preserves_shape bits sizes view snapshotView hardView hardPresence hard snapshot source output word execution).1,word⟩

theorem history_supports_growth (bits capacity newCapacity : Nat) (state : BufferState α) (metadata : β)
    (history : StorageHistory bits capacity state) (grows : capacity ≤ newCapacity) :
    Shape state capacity ∧ capacity < 2^bits ∧
      ∃ next, JarlStorage.state_State_grow capacity newCapacity state metadata = .returned next metadata ∧
        Shape next newCapacity ∧ next.len = state.len ∧
        (∀ i, i < state.len → next.slots[i]? = state.slots[i]?) := by
  have valid := storage_history_valid bits capacity state history
  exact ⟨valid.1, valid.2, grow_preserves_shape capacity newCapacity state metadata valid.1 grows⟩
theorem history_supports_installation (bits capacity : Nat) (view : α → Path → InitStore)
    (snapshotView : β → Path → InitStore) (state next : InstallationState α β) (input : β)
    (history : StorageHistory bits capacity state.buffer)
    (execution : resumeInstallation (JarlStorage.state_State_install bits view snapshotView state input) = .returned next) :
    Shape state.buffer capacity ∧ Shape next.buffer capacity ∧ state.commit ≤ next.commit ∧ next.snapshot = some input := by
  have valid := storage_history_valid bits capacity state.buffer history
  have effects := installation_preserves_capacity_and_commit bits view snapshotView state next input execution
  exact ⟨valid.1,installation_preserves_shape bits capacity view snapshotView state next input valid.1 execution,effects.2.2⟩


theorem restoration_final_guard (bits : Nat) (sizes : String → Nat)
    (view : α → Path → InitStore) (snapshotView : β → Path → InitStore)
    (hardView : δ → InitStore) (hardPresence : δ → Path → Bool)
    (hard : δ) (snapshot : Option β) (source : σ) (output : RecoveryState α β δ)
    (execution : RecoveryReturns (JarlStorage.state_State_restore bits sizes view snapshotView hardView hardPresence hard snapshot source : RecoveryRun α β δ σ ι) (.ok output)) :
    recoveryPredicate JarlStorage.state_State_restore_ir view snapshotView hardView hardPresence
      ⟨output,selectRecord JarlStorage.state_State_restore_ir.last.base (fun _ => snapshot.map snapshotView),
        (fun _ => .absent),(fun _ => .absent)⟩ JarlStorage.state_State_restore_ir.finalGuard = .ok false := by
  unfold JarlStorage.state_State_restore restoreState at execution
  simp only [JarlStorage.state_State_restore_ir,initializeFields,initialCell] at execution
  simp at execution
  split at execution
  · simp at execution
  · simp at execution
  · simp only [recovery_returns_intoIterator] at execution
    obtain ⟨iterator,execution⟩ := execution
    exact recovery_loop_final_guard _ bits (sizes "CAP") _ view snapshotView hardView hardPresence _
      ⟨⟨List.replicate (sizes "CAP") none,0⟩,hard,snapshot⟩ output iterator execution

theorem restoration_places (bits : Nat) (sizes : String → Nat)
    (view : α → Path → InitStore) (snapshotView : β → Path → InitStore)
    (hardView : δ → InitStore) (hardPresence : δ → Path → Bool)
    (hard : δ) (snapshot : Option β) (source : σ) (output : RecoveryState α β δ)
    (word : sizes "CAP" < 2^bits)
    (execution : RecoveryReturns (JarlStorage.state_State_restore bits sizes view snapshotView hardView hardPresence hard snapshot source : RecoveryRun α β δ σ ι) (.ok output)) :
    JarlStorage.state_State_restore_ir.hardPath = ["hard"] ∧
    JarlStorage.state_State_restore_ir.snapshotPath = ["snapshot"] ∧
    JarlStorage.state_State_restore_ir.append.slotsPath = ["entries"] ∧
    JarlStorage.state_State_restore_ir.append.lengthPath = ["len"] ∧
    JarlStorage.state_State_restore_ir.append.capacityName = "CAP" ∧
    Shape output.buffer (sizes "CAP") ∧ output.hard = hard ∧ output.snapshot = snapshot := by
  exact ⟨rfl,rfl,rfl,rfl,rfl,restoration_preserves_shape bits sizes view snapshotView hardView hardPresence hard snapshot source output word execution⟩

theorem restoration_commit_bounds (bits : Nat) (sizes : String → Nat)
    (view : α → Path → InitStore) (snapshotView : β → Path → InitStore)
    (hardView : δ → InitStore) (hardPresence : δ → Path → Bool)
    (hard : δ) (snapshot : Option β) (source : σ) (output : RecoveryState α β δ)
    (execution : RecoveryReturns (JarlStorage.state_State_restore bits sizes view snapshotView hardView hardPresence hard snapshot source : RecoveryRun α β δ σ ι) (.ok output)) :
    ∃ commit boundary lastIndex record,
      recordWord (hardView output.hard) ["commit"] = some commit ∧
      recordWord (selectRecord JarlStorage.state_State_restore_ir.last.base (fun _ => snapshot.map snapshotView)) ["index"] = some boundary ∧
      recoveryLast JarlStorage.state_State_restore_ir view snapshotView output = .ok record ∧
      recordWord record ["index"] = some lastIndex ∧ boundary ≤ commit ∧ commit ≤ lastIndex := by
  have guarded := restoration_final_guard bits sizes view snapshotView hardView hardPresence hard snapshot source output execution
  have both := recovery_or_false _ _ _ _ _ _ _ _ guarded
  obtain ⟨commit,boundary,readCommit,readBoundary,lower⟩ := recovery_less_false _ _ _ _ _ _ _ _ both.1
  obtain ⟨commit',lastIndex,readCommit',readLast,upper⟩ := recovery_greater_false _ _ _ _ _ _ _ _ both.2
  have same : commit = commit' := Except.ok.inj (readCommit.symm.trans readCommit')
  subst commit'
  have hardRead := (recovery_hard_value _ _ _ _ _ _ _).mp readCommit
  have baseRead := (recovery_base_value _ _ _ _ _ _ _).mp readBoundary
  obtain ⟨record,lastRead,indexRead⟩ := (recovery_last_value _ _ _ _ _ _ _).mp readLast
  exact ⟨commit,boundary,lastIndex,record,hardRead,baseRead,lastRead,indexRead,lower,upper⟩

theorem restoration_initial_guard (bits : Nat) (sizes : String → Nat)
    (view : α → Path → InitStore) (snapshotView : β → Path → InitStore)
    (hardView : δ → InitStore) (hardPresence : δ → Path → Bool)
    (hard : δ) (snapshot : Option β) (source : σ) (output : RecoveryState α β δ)
    (execution : RecoveryReturns (JarlStorage.state_State_restore bits sizes view snapshotView hardView hardPresence hard snapshot source : RecoveryRun α β δ σ ι) (.ok output)) :
    recoveryPredicate JarlStorage.state_State_restore_ir view snapshotView hardView hardPresence
      ⟨⟨⟨List.replicate (sizes "CAP") none,0⟩,hard,snapshot⟩,
        selectRecord JarlStorage.state_State_restore_ir.last.base (fun _ => snapshot.map snapshotView),
        (fun _ => .absent),(fun _ => .absent)⟩ JarlStorage.state_State_restore_ir.initialGuard = .ok false := by
  unfold JarlStorage.state_State_restore restoreState at execution
  simp only [JarlStorage.state_State_restore_ir,initializeFields,initialCell] at execution
  simp at execution
  split at execution
  · simp at execution
  · simp at execution
  · assumption

theorem restoration_base_term_bound (bits : Nat) (sizes : String → Nat)
    (view : α → Path → InitStore) (snapshotView : β → Path → InitStore)
    (hardView : δ → InitStore) (hardPresence : δ → Path → Bool)
    (hard : δ) (snapshot : Option β) (source : σ) (output : RecoveryState α β δ)
    (execution : RecoveryReturns (JarlStorage.state_State_restore bits sizes view snapshotView hardView hardPresence hard snapshot source : RecoveryRun α β δ σ ι) (.ok output)) :
    ∃ baseTerm hardTerm,
      recordWord (selectRecord JarlStorage.state_State_restore_ir.last.base (fun _ => snapshot.map snapshotView)) ["term"] = some baseTerm ∧
      recordWord (hardView hard) ["term"] = some hardTerm ∧ baseTerm ≤ hardTerm := by
  have guarded := restoration_initial_guard bits sizes view snapshotView hardView hardPresence hard snapshot source output execution
  have outer := recovery_or_false _ _ _ _ _ _ _ _ guarded
  have inner := recovery_or_false _ _ _ _ _ _ _ _ outer.1
  obtain ⟨baseTerm,hardTerm,readBase,readHard,bound⟩ := recovery_greater_false _ _ _ _ _ _ _ _ inner.2
  exact ⟨baseTerm,hardTerm,(recovery_base_value _ _ _ _ _ _ _).mp readBase,
    (recovery_hard_value _ _ _ _ _ _ _).mp readHard,bound⟩

-- Decode one accepted entry; restoration_orders_log composes this obligation
-- with the actual loop and exact append effects for every retained entry.
private theorem accepted_entry_order (view : α → Path → InitStore)
    (snapshotView : β → Path → InitStore) (hardView : δ → InitStore) (hardPresence : δ → Path → Bool)
    (context : RecoveryContext α β δ)
    (accepted : recoveryPredicate JarlStorage.state_State_restore_ir view snapshotView hardView hardPresence
      context JarlStorage.state_State_restore_ir.entryGuard = .ok false) :
    ∃ previousIndex index previousTerm term hardTerm,
      recordWord context.last ["index"] = some previousIndex ∧
      recordWord context.entry ["index"] = some index ∧
      recordWord context.last ["term"] = some previousTerm ∧
      recordWord context.entry ["term"] = some term ∧
      recordWord (hardView context.state.hard) ["term"] = some hardTerm ∧
      index = previousIndex + 1 ∧ index < 2^64 ∧ 0 < term ∧ previousTerm ≤ term ∧ term ≤ hardTerm := by
  have outer := recovery_or_false _ _ _ _ _ _ _ _ accepted
  have middle := recovery_or_false _ _ _ _ _ _ _ _ outer.1
  have inner := recovery_or_false _ _ _ _ _ _ _ _ middle.1
  obtain ⟨previousIndex,index,readPrevious,readIndex,successor,range⟩ := recovery_checked_ne_false _ _ _ _ _ _ _ _ _ inner.1
  obtain ⟨term,zeroValue,readTerm,readZero,positive⟩ := recovery_equal_false _ _ _ _ _ _ _ _ inner.2
  have isZero : zeroValue = 0 := by simpa [recoveryValue,bind,Except.bind] using readZero.symm
  subst zeroValue
  obtain ⟨term',previousTerm,readTerm',readPreviousTerm,nondecreasing⟩ := recovery_less_false _ _ _ _ _ _ _ _ middle.2
  have same : term = term' := Except.ok.inj (readTerm.symm.trans readTerm')
  subst term'
  obtain ⟨term',hardTerm,readTerm',readHardTerm,upper⟩ := recovery_greater_false _ _ _ _ _ _ _ _ outer.2
  have same : term = term' := Except.ok.inj (readTerm.symm.trans readTerm')
  subst term'
  exact ⟨previousIndex,index,previousTerm,term,hardTerm,
    (recovery_cached_last_value _ _ _ _ _ _ _).mp readPrevious,
    (recovery_entry_value _ _ _ _ _ _ _).mp readIndex,
    (recovery_cached_last_value _ _ _ _ _ _ _).mp readPreviousTerm,
    (recovery_entry_value _ _ _ _ _ _ _).mp readTerm,
    (recovery_hard_value _ _ _ _ _ _ _).mp readHardTerm,
    successor.symm,range,by omega,nondecreasing,upper⟩

theorem restoration_zero_term_has_no_vote (bits : Nat) (sizes : String → Nat)
    (view : α → Path → InitStore) (snapshotView : β → Path → InitStore)
    (hardView : δ → InitStore) (hardPresence : δ → Path → Bool)
    (hard : δ) (snapshot : Option β) (source : σ) (output : RecoveryState α β δ)
    (zeroValue : recordWord (hardView hard) ["term"] = some 0)
    (execution : RecoveryReturns (JarlStorage.state_State_restore bits sizes view snapshotView hardView hardPresence hard snapshot source : RecoveryRun α β δ σ ι) (.ok output)) :
    hardPresence hard ["voted_for"] = false := by
  have guarded := restoration_initial_guard bits sizes view snapshotView hardView hardPresence hard snapshot source output execution
  have outer := recovery_or_false _ _ _ _ _ _ _ _ guarded
  simpa [recoveryPredicate,recoveryValue,bind,Except.bind,zeroValue] using outer.2
theorem restoration_snapshot_nonzero (bits : Nat) (sizes : String → Nat)
    (view : α → Path → InitStore) (snapshotView : β → Path → InitStore)
    (hardView : δ → InitStore) (hardPresence : δ → Path → Bool)
    (hard : δ) (snapshot : β) (source : σ) (output : RecoveryState α β δ)
    (execution : RecoveryReturns (JarlStorage.state_State_restore bits sizes view snapshotView hardView hardPresence hard (some snapshot) source : RecoveryRun α β δ σ ι) (.ok output)) :
    ∃ index term, recordWord (snapshotView snapshot ["last"]) ["index"] = some index ∧
      recordWord (snapshotView snapshot ["last"]) ["term"] = some term ∧ 0 < index ∧ 0 < term := by
  have guarded := restoration_initial_guard bits sizes view snapshotView hardView hardPresence hard (some snapshot) source output execution
  have outer := recovery_or_false _ _ _ _ _ _ _ _ guarded
  have inner := recovery_or_false _ _ _ _ _ _ _ _ outer.1
  have checked := recovery_and_true _ _ _ _ _ _ _ _ rfl inner.1
  have both := recovery_or_false _ _ _ _ _ _ _ _ checked
  obtain ⟨index,zeroValue,readIndex,readZero,positiveIndex⟩ := recovery_equal_false _ _ _ _ _ _ _ _ both.1
  have isZero : zeroValue = 0 := by simpa [recoveryValue,bind,Except.bind] using readZero.symm
  subst zeroValue
  obtain ⟨term,zeroValue,readTerm,readZero,positiveTerm⟩ := recovery_equal_false _ _ _ _ _ _ _ _ both.2
  have isZero : zeroValue = 0 := by simpa [recoveryValue,bind,Except.bind] using readZero.symm
  subst zeroValue
  exact ⟨index,term,(recovery_base_value _ _ _ _ _ _ _).mp readIndex,
    (recovery_base_value _ _ _ _ _ _ _).mp readTerm,by omega,by omega⟩

-- A chain rooted at the actual snapshot/default LogId, with opaque payloads.
-- Every snoc records checked successor arithmetic and the term inequalities.
inductive OrderedEntries (view : α → Path → InitStore) (hard base : InitStore) : List α → InitStore → Prop where
  | empty : OrderedEntries view hard base [] base
  | snoc {entries : List α} {previous : InitStore} (entry : α)
      (previousIndex index previousTerm term hardTerm : Nat) :
      OrderedEntries view hard base entries previous →
      recordWord previous ["index"] = some previousIndex →
      recordWord (view entry ["id"]) ["index"] = some index →
      recordWord previous ["term"] = some previousTerm →
      recordWord (view entry ["id"]) ["term"] = some term →
      recordWord hard ["term"] = some hardTerm →
      index = previousIndex + 1 → index < 2^64 → 0 < term → previousTerm ≤ term → term ≤ hardTerm →
      OrderedEntries view hard base (entries ++ [entry]) (view entry ["id"])

private def RecoveryOrdered (capacity : Nat) (view : α → Path → InitStore)
    (snapshotView : β → Path → InitStore) (hardView : δ → InitStore)
    (hard : δ) (snapshot : Option β) (base : InitStore) (state : RecoveryState α β δ) : Prop :=
  Shape state.buffer capacity ∧ state.hard = hard ∧ state.snapshot = snapshot ∧
  ∃ entries padding last,
    state.buffer.slots = entries.map some ++ List.replicate padding none ∧
    state.buffer.len = entries.length ∧ OrderedEntries view (hardView hard) base entries last ∧
    recoveryLast JarlStorage.state_State_restore_ir view snapshotView state = .ok last

private theorem recovery_ordered_step (bits capacity : Nat) (view : α → Path → InitStore)
    (snapshotView : β → Path → InitStore) (hardView : δ → InitStore) (hardPresence : δ → Path → Bool)
    (hard : δ) (snapshot : Option β) (base : InitStore) (word : capacity < 2^bits)
    (state : RecoveryState α β δ) (entry : α) (record : InitStore) (buffer : BufferState α)
    (valid : RecoveryOrdered capacity view snapshotView hardView hard snapshot base state)
    (fetched : recoveryLast JarlStorage.state_State_restore_ir view snapshotView state = .ok record)
    (accepted : recoveryPredicate JarlStorage.state_State_restore_ir view snapshotView hardView hardPresence
      ⟨state,base,record,view entry ["id"]⟩ JarlStorage.state_State_restore_ir.entryGuard = .ok false)
    (appended : resumeDrops (JarlStorage.state_State_push bits capacity state.buffer entry) = .returned (.ok ()) buffer) :
    RecoveryOrdered capacity view snapshotView hardView hard snapshot base {state with buffer := buffer} := by
  obtain ⟨shape,hardSame,snapshotSame,entries,padding,last,slots,length,chain,lastRead⟩ := valid
  have same : last = record := Except.ok.inj (lastRead.symm.trans fetched)
  subst record
  have space : state.buffer.len < capacity := by
    by_cases room : state.buffer.len < capacity
    · exact room
    · have full : state.buffer.len = capacity := by have := shape.2.1;omega
      rw [full_preserves_state_at_drop bits capacity state.buffer entry full] at appended
      simp [resumeDrops] at appended
  obtain ⟨updated,computed,preserved,newLength⟩ := append_preserves_shape bits capacity state.buffer entry shape space word
  rw [computed] at appended
  simp only [resumeDrops,BufferRun.returned.injEq] at appended
  obtain ⟨_,same⟩ := appended
  subst buffer
  have exactBuffer : updated = ⟨state.buffer.slots.set state.buffer.len (some entry),state.buffer.len + 1⟩ := by
    rw [append_exact bits capacity state.buffer entry shape space word] at computed
    exact (BufferRun.returned.inj computed).2.symm
  obtain ⟨previousIndex,index,previousTerm,term,hardTerm,readPrevious,readIndex,readPreviousTerm,readTerm,readHard,successor,range,positive,monotone,upper⟩ :=
    accepted_entry_order view snapshotView hardView hardPresence _ accepted
  have nextChain : OrderedEntries view (hardView hard) base (entries ++ [entry]) (view entry ["id"]) :=
    .snoc entry previousIndex index previousTerm term hardTerm chain readPrevious readIndex readPreviousTerm readTerm
      (by simpa [hardSame] using readHard) successor range positive monotone upper
  have padPositive : 0 < padding := by
    have size := shape.1
    rw [slots] at size
    simp only [List.length_append,List.length_map,List.length_replicate] at size
    omega
  obtain ⟨remaining,rfl⟩ := Nat.exists_eq_succ_of_ne_zero (by omega : padding ≠ 0)
  have nextSlots : updated.slots = (entries ++ [entry]).map some ++ List.replicate remaining none := by
    rw [exactBuffer]
    dsimp
    rw [slots,length]
    simp [List.set_append_right,List.replicate_succ,List.map_append,List.append_assoc]
  refine ⟨preserved,hardSame,snapshotSame,entries ++ [entry],remaining,view entry ["id"],nextSlots,?_,nextChain,?_⟩
  · simpa [length] using newLength
  · have nextLen : updated.len = (entries.map some).length + 1 := by simpa [length] using newLength
    have lookup := last_before_truncation view (recoveryRecords snapshotView {state with buffer := updated})
      (entries.map some) (List.replicate remaining none) entry
    unfold recoveryLast
    rw [show JarlStorage.state_State_restore_ir.last = JarlStorage.state_State_truncate_ir.last by rfl]
    have bufferEq : updated = ⟨(entries.map some ++ [some entry]) ++ List.replicate remaining none,(entries.map some).length + 1⟩ := by
      cases updated
      simp_all
    rw [bufferEq]
    exact congrArg (fun result => match result with
      | .ok record => Except.ok record
      | .error reason => Except.error (RecoveryReadFault.read reason)) lookup
theorem restoration_orders_log (bits : Nat) (sizes : String → Nat)
    (view : α → Path → InitStore) (snapshotView : β → Path → InitStore)
    (hardView : δ → InitStore) (hardPresence : δ → Path → Bool)
    (hard : δ) (snapshot : Option β) (source : σ) (output : RecoveryState α β δ)
    (word : sizes "CAP" < 2^bits)
    (execution : RecoveryReturns (JarlStorage.state_State_restore bits sizes view snapshotView hardView hardPresence hard snapshot source : RecoveryRun α β δ σ ι) (.ok output)) :
    ∃ entries padding last,
      output.buffer.slots = entries.map some ++ List.replicate padding none ∧
      output.buffer.len = entries.length ∧
      OrderedEntries view (hardView hard)
        (selectRecord JarlStorage.state_State_restore_ir.last.base (fun _ => snapshot.map snapshotView)) entries last ∧
      recoveryLast JarlStorage.state_State_restore_ir view snapshotView output = .ok last := by
  unfold JarlStorage.state_State_restore restoreState at execution
  simp only [JarlStorage.state_State_restore_ir,initializeFields,initialCell] at execution
  simp at execution
  split at execution
  · simp at execution
  · simp at execution
  · simp only [recovery_returns_intoIterator] at execution
    obtain ⟨iterator,execution⟩ := execution
    have initial : RecoveryOrdered (sizes "CAP") view snapshotView hardView hard snapshot
        (selectRecord JarlStorage.state_State_restore_ir.last.base (fun _ => snapshot.map snapshotView))
        ⟨⟨List.replicate (sizes "CAP") none,0⟩,hard,snapshot⟩ := by
      refine ⟨(fresh_representation (α := α) sizes).2,rfl,rfl,[],sizes "CAP",_,rfl,rfl,.empty,?_⟩
      simp [recoveryLast,lastRecord,iterateRecords,truncationView,JarlStorage.state_State_restore_ir,presentPlaces]
      rfl
    have result := recovery_loop_invariant JarlStorage.state_State_restore_ir bits (sizes "CAP") _
      view snapshotView hardView hardPresence _
      (RecoveryOrdered (sizes "CAP") view snapshotView hardView hard snapshot _)
      (recovery_ordered_step bits (sizes "CAP") view snapshotView hardView hardPresence hard snapshot _ word)
      _ output iterator initial execution
    exact result.2.2.2

private theorem ordered_last_index (view : α → Path → InitStore) (hard base : InitStore)
    (entries : List α) (last : InitStore) (baseIndex : Nat)
    (baseRead : recordWord base ["index"] = some baseIndex)
    (chain : OrderedEntries view hard base entries last) :
    recordWord last ["index"] = some (baseIndex + entries.length) := by
  induction chain with
  | empty => simpa using baseRead
  | @snoc entries previous entry previousIndex index previousTerm term hardTerm chain previousRead indexRead _ _ _ successor _ _ _ _ ih =>
    have same : previousIndex = baseIndex + entries.length := Option.some.inj (previousRead.symm.trans ih)
    simpa [successor,same,Nat.add_assoc] using indexRead

private theorem ordered_entry_index (view : α → Path → InitStore) (hard base : InitStore)
    (entries : List α) (last : InitStore) (baseIndex : Nat)
    (baseRead : recordWord base ["index"] = some baseIndex)
    (chain : OrderedEntries view hard base entries last) :
    ∀ position entry, entries[position]? = some entry →
      recordWord (view entry ["id"]) ["index"] = some (baseIndex + position + 1) := by
  induction chain with
  | empty => simp
  | @snoc entries previous entry previousIndex index previousTerm term hardTerm chain previousRead indexRead _ _ _ successor _ _ _ _ ih =>
    intro position found present
    by_cases earlier : position < entries.length
    · rw [List.getElem?_append_left earlier] at present
      exact ih position found present
    · rw [List.getElem?_append_right (by omega)] at present
      have offset : position - entries.length = 0 := by
        by_cases same : position - entries.length = 0
        · exact same
        · have outside : 1 ≤ position - entries.length := by omega
          rw [List.getElem?_eq_none (by simpa using outside)] at present
          contradiction
      have positionEq : position = entries.length := by omega
      subst position
      simp only [Nat.sub_self,List.getElem?_cons_zero,Option.some.injEq] at present
      subst found
      have prior := ordered_last_index view hard base entries previous baseIndex baseRead chain
      have same : previousIndex = baseIndex + entries.length := Option.some.inj (previousRead.symm.trans prior)
      simpa [successor,same] using indexRead

theorem restoration_exact_indices (bits : Nat) (sizes : String → Nat)
    (view : α → Path → InitStore) (snapshotView : β → Path → InitStore)
    (hardView : δ → InitStore) (hardPresence : δ → Path → Bool)
    (hard : δ) (snapshot : Option β) (source : σ) (output : RecoveryState α β δ)
    (word : sizes "CAP" < 2^bits)
    (execution : RecoveryReturns (JarlStorage.state_State_restore bits sizes view snapshotView hardView hardPresence hard snapshot source : RecoveryRun α β δ σ ι) (.ok output)) :
    ∃ boundary last,
      recordWord (selectRecord JarlStorage.state_State_restore_ir.last.base (fun _ => snapshot.map snapshotView)) ["index"] = some boundary ∧
      recoveryLast JarlStorage.state_State_restore_ir view snapshotView output = .ok last ∧
      recordWord last ["index"] = some (boundary + output.buffer.len) ∧
      ∀ position entry, position < output.buffer.len → output.buffer.slots[position]? = some (some entry) →
        recordWord (view entry ["id"]) ["index"] = some (boundary + position + 1) := by
  obtain ⟨entries,padding,last,slots,length,chain,lastRead⟩ := restoration_orders_log bits sizes view snapshotView hardView hardPresence hard snapshot source output word execution
  obtain ⟨commit,boundary,lastIndex,record,_,baseRead,_,_,_,_⟩ := restoration_commit_bounds bits sizes view snapshotView hardView hardPresence hard snapshot source output execution
  refine ⟨boundary,last,baseRead,lastRead,?_,?_⟩
  · rw [length]
    exact ordered_last_index view _ _ entries last boundary baseRead chain
  · intro position entry inside present
    rw [slots,List.getElem?_append_left (by simpa [length] using inside)] at present
    have member : entries[position]? = some entry := by
      simpa [List.getElem?_map,Option.map_eq_some_iff] using present
    exact ordered_entry_index view _ _ entries last boundary baseRead chain position entry member

-- Logical log validity is separate from durability and the caller's authority
-- to change the committed prefix.
def LogRep (view : α → Path → InitStore) (hard base : InitStore)
    (state : BufferState α) (capacity : Nat) : Prop :=
  Shape state capacity ∧ ∃ entries last,
    state.slots = entries.map some ++ List.replicate (capacity - state.len) none ∧
    state.len = entries.length ∧ OrderedEntries view hard base entries last

private theorem ordered_take (view : α → Path → InitStore) (hard base : InitStore)
    (entries : List α) (last : InitStore) (chain : OrderedEntries view hard base entries last) :
    ∀ count, count ≤ entries.length → ∃ record, OrderedEntries view hard base (entries.take count) record := by
  induction chain with
  | empty => intro count bound; exact ⟨base,by simpa using OrderedEntries.empty (view := view) (hard := hard) (base := base)⟩
  | @snoc entries previous entry previousIndex index previousTerm term hardTerm chain previousRead indexRead previousTermRead termRead hardRead successor range positive monotone upper ih =>
    intro count bound
    by_cases earlier : count ≤ entries.length
    · rw [List.take_append_of_le_length earlier]
      exact ih count earlier
    · have full : (entries ++ [entry]).length ≤ count := by simp only [List.length_append,List.length_singleton] at bound ⊢;omega
      rw [List.take_of_length_le full]
      exact ⟨view entry ["id"],.snoc entry previousIndex index previousTerm term hardTerm chain previousRead indexRead previousTermRead termRead hardRead successor range positive monotone upper⟩

private theorem log_rep_prefix (view : α → Path → InitStore) (hard base : InitStore)
    (state next : BufferState α) (capacity nextCapacity : Nat)
    (valid : LogRep view hard base state capacity) (shape : Shape next nextCapacity)
    (shorter : next.len ≤ state.len)
    (unchanged : ∀ i, i < next.len → next.slots[i]? = state.slots[i]?) :
    LogRep view hard base next nextCapacity := by
  obtain ⟨_,entries,last,slots,length,chain⟩ := valid
  have bound : next.len ≤ entries.length := by omega
  obtain ⟨record,prefixChain⟩ := ordered_take view hard base entries last chain next.len bound
  have front : next.slots.take next.len = (entries.take next.len).map some := by
    apply List.ext_getElem?
    intro i
    by_cases inside : i < next.len
    · rw [List.getElem?_take_of_lt inside,List.getElem?_map,List.getElem?_take_of_lt inside,unchanged i inside,slots,
        List.getElem?_append_left (by simp only [List.length_map];omega),List.getElem?_map]
    · simp [List.getElem?_take,inside]
  refine ⟨shape,entries.take next.len,record,?_,?_,prefixChain⟩
  · rw [← front,← empty_suffix next nextCapacity shape]
    exact (List.take_append_drop next.len next.slots).symm
  · exact (List.length_take_of_le bound).symm

theorem restoration_log_representation (bits : Nat) (sizes : String → Nat)
    (view : α → Path → InitStore) (snapshotView : β → Path → InitStore)
    (hardView : δ → InitStore) (hardPresence : δ → Path → Bool)
    (hard : δ) (snapshot : Option β) (source : σ) (output : RecoveryState α β δ)
    (word : sizes "CAP" < 2^bits)
    (execution : RecoveryReturns (JarlStorage.state_State_restore bits sizes view snapshotView hardView hardPresence hard snapshot source : RecoveryRun α β δ σ ι) (.ok output)) :
    LogRep view (hardView hard)
      (selectRecord JarlStorage.state_State_restore_ir.last.base (fun _ => snapshot.map snapshotView)) output.buffer (sizes "CAP") := by
  have shape := (restoration_preserves_shape bits sizes view snapshotView hardView hardPresence hard snapshot source output word execution).1
  obtain ⟨entries,padding,last,slots,length,chain,_⟩ := restoration_orders_log bits sizes view snapshotView hardView hardPresence hard snapshot source output word execution
  have size := shape.1
  rw [slots] at size
  simp only [List.length_append,List.length_map,List.length_replicate] at size
  have paddingEq : padding = sizes "CAP" - output.buffer.len := by omega
  exact ⟨shape,entries,last,by simpa [paddingEq] using slots,length,chain⟩

theorem growth_preserves_log (oldCapacity newCapacity : Nat) (view : α → Path → InitStore)
    (hard base : InitStore) (state : BufferState α) (metadata : β)
    (valid : LogRep view hard base state oldCapacity) (grows : oldCapacity ≤ newCapacity) :
    ∃ next, JarlStorage.state_State_grow oldCapacity newCapacity state metadata = .returned next metadata ∧
      LogRep view hard base next newCapacity ∧ next.len = state.len := by
  obtain ⟨next,execution,shape,length,unchanged⟩ := grow_preserves_shape oldCapacity newCapacity state metadata valid.1 grows
  exact ⟨next,execution,log_rep_prefix view hard base state next oldCapacity newCapacity valid shape (by omega)
    (fun i inside => unchanged i (by omega)),length⟩

theorem truncation_preserves_log (view : α → Path → InitStore) (records : SelectionStore)
    (hard base : InitStore) (boundary capacity : Nat) (state next : BufferState α)
    (valid : LogRep view hard base state capacity)
    (execution : resumeTruncation (JarlStorage.state_State_truncate view records state boundary) = .returned next) :
    LogRep view hard base next capacity ∧ next.len ≤ state.len := by
  obtain ⟨shape,shorter,unchanged⟩ := truncation_preserves_shape view records boundary capacity state next valid.1 execution
  exact ⟨log_rep_prefix view hard base state next capacity capacity valid shape shorter unchanged,shorter⟩

private theorem ordered_last_record (view : α → Path → InitStore) (records : SelectionStore)
    (hard base : InitStore) (entries : List α) (last : InitStore) (padding : Nat)
    (selected : selectRecord JarlStorage.state_State_truncate_ir.last.base records = base)
    (chain : OrderedEntries view hard base entries last) :
    lastRecord JarlStorage.state_State_truncate_ir.last
      (truncationView view records ⟨entries.map some ++ List.replicate padding none,entries.length⟩) = .ok last := by
  cases chain with
  | empty =>
    simpa [lastRecord,iterateRecords,truncationView,JarlStorage.state_State_truncate_ir,presentPlaces] using congrArg (Except.ok (ε := TraversalFault)) selected
  | @snoc entries previous entry previousIndex index previousTerm term hardTerm chain previousRead indexRead previousTermRead termRead hardRead successor range positive monotone upper =>
    simpa only [List.map_append,List.map_cons,List.map_nil,List.length_append,List.length_singleton,List.length_map]
      using last_before_truncation view records (entries.map some) (List.replicate padding none) entry

private theorem record_word_read (record : InitStore) (path : Path) (value : Nat)
    (read : recordWord record path = some value) :
    record path = .unsigned "u64" value ∧ value < 2^64 := by
  cases cell : record path <;> simp only [recordWord,cell] at read
  all_goals try contradiction
  split at read
  · rename_i valid
    cases read
    obtain ⟨rfl,range⟩ := valid
    exact ⟨rfl,range⟩
  · contradiction

private theorem log_rep_last_index (view : α → Path → InitStore) (records : SelectionStore)
    (hard base : InitStore) (state : BufferState α) (capacity baseIndex : Nat)
    (selected : selectRecord JarlStorage.state_State_truncate_ir.last.base records = base)
    (baseRead : recordWord base ["index"] = some baseIndex)
    (valid : LogRep view hard base state capacity) :
    ∃ record, lastRecord JarlStorage.state_State_truncate_ir.last (truncationView view records state) = .ok record ∧
      record ["index"] = .unsigned "u64" (baseIndex + state.len) ∧ baseIndex + state.len < 2^64 := by
  obtain ⟨_,entries,last,slots,length,chain⟩ := valid
  have stateEq : state = ⟨entries.map some ++ List.replicate (capacity - state.len) none,entries.length⟩ := by
    cases state
    simp_all
  have fetched := ordered_last_record view records hard base entries last (capacity - state.len) selected chain
  have read := ordered_last_index view hard base entries last baseIndex baseRead chain
  refine ⟨last,?_,?_⟩
  · rw [← stateEq] at fetched
    exact fetched
  · rw [length]
    exact record_word_read last ["index"] _ read

private theorem truncation_length_exact (view : α → Path → InitStore) (records : SelectionStore)
    (hard base : InitStore) (boundary capacity baseIndex fuel : Nat) (state next : BufferState α)
    (selected : selectRecord JarlStorage.state_State_truncate_ir.last.base records = base)
    (baseRead : recordWord base ["index"] = some baseIndex)
    (valid : LogRep view hard base state capacity) (boundaryWord : boundary < 2^64)
    (execution : resumeTruncation (truncateSteps JarlStorage.state_State_truncate_ir view records boundary fuel state) = .returned next) :
    next.len = min state.len (boundary - (baseIndex + 1)) := by
  induction fuel generalizing state with
  | zero => simp [truncateSteps,resumeTruncation] at execution
  | succ fuel ih =>
    obtain ⟨record,fetched,read,range⟩ := log_rep_last_index view records hard base state capacity baseIndex selected baseRead valid
    rw [truncateSteps,fetched] at execution
    simp only [show JarlStorage.state_State_truncate_ir.indexField = ["index"] by rfl,read] at execution
    simp only [show JarlStorage.state_State_truncate_ir.inclusive = true by rfl,truncationCompare,↓reduceIte] at execution
    rw [if_neg (by simp;omega)] at execution
    by_cases cut : baseIndex + state.len ≥ boundary ∧ state.len > 0
    · rw [if_pos cut] at execution
      have occupied := valid.1.2.2.1 (state.len - 1) (by omega)
      obtain ⟨entry,present⟩ := occupied
      simp only [present,resumeTruncation] at execution
      have shape := clear_preserves_shape state capacity valid.1 cut.2
      have retained : LogRep view hard base
          ⟨state.slots.set (state.len - 1) none,state.len - 1⟩ capacity :=
        log_rep_prefix view hard base state _ capacity capacity valid shape (by dsimp;omega)
          (fun i inside => List.getElem?_set_ne (by dsimp at inside;omega))
      have shorter := ih _ retained execution
      dsimp at shorter
      omega
    · rw [if_neg cut] at execution
      simp only [resumeTruncation,TruncationRun.returned.injEq] at execution
      subst next
      omega

theorem truncation_preserves_committed_prefix (view : α → Path → InitStore) (records : SelectionStore)
    (hard base : InitStore) (boundary capacity baseIndex commit : Nat) (state next : BufferState α)
    (selected : selectRecord JarlStorage.state_State_truncate_ir.last.base records = base)
    (baseRead : recordWord base ["index"] = some baseIndex)
    (valid : LogRep view hard base state capacity) (boundaryWord : boundary < 2^64)
    (commitBounds : baseIndex ≤ commit ∧ commit ≤ baseIndex + state.len)
    (authorized : commit < boundary)
    (execution : resumeTruncation (JarlStorage.state_State_truncate view records state boundary) = .returned next) :
    LogRep view hard base next capacity ∧ commit ≤ baseIndex + next.len ∧
      ∀ position, position < commit - baseIndex → next.slots[position]? = state.slots[position]? := by
  have length := truncation_length_exact view records hard base boundary capacity baseIndex _ state next selected baseRead valid boundaryWord execution
  have shape := truncation_preserves_shape view records boundary capacity state next valid.1 execution
  refine ⟨(truncation_preserves_log view records hard base boundary capacity state next valid execution).1,by omega,?_⟩
  intro position committed
  exact shape.2.2 position (by omega)
private theorem truncation_returns (view : α → Path → InitStore) (records : SelectionStore)
    (hard base : InitStore) (boundary capacity baseIndex fuel : Nat) (state : BufferState α)
    (selected : selectRecord JarlStorage.state_State_truncate_ir.last.base records = base)
    (baseRead : recordWord base ["index"] = some baseIndex)
    (valid : LogRep view hard base state capacity) (boundaryWord : boundary < 2^64)
    (enough : state.len < fuel) :
    ∃ next, resumeTruncation (truncateSteps JarlStorage.state_State_truncate_ir view records boundary fuel state) = .returned next := by
  induction fuel generalizing state with
  | zero => omega
  | succ fuel ih =>
    obtain ⟨record,fetched,read,range⟩ := log_rep_last_index view records hard base state capacity baseIndex selected baseRead valid
    rw [truncateSteps,fetched]
    simp only [show JarlStorage.state_State_truncate_ir.indexField = ["index"] by rfl,read]
    simp only [show JarlStorage.state_State_truncate_ir.inclusive = true by rfl,truncationCompare,↓reduceIte]
    rw [if_neg (by simp;omega)]
    by_cases cut : baseIndex + state.len ≥ boundary ∧ state.len > 0
    · rw [if_pos cut]
      obtain ⟨entry,present⟩ := valid.1.2.2.1 (state.len - 1) (by omega)
      simp only [present,resumeTruncation]
      have shape := clear_preserves_shape state capacity valid.1 cut.2
      have retained : LogRep view hard base
          ⟨state.slots.set (state.len - 1) none,state.len - 1⟩ capacity :=
        log_rep_prefix view hard base state _ capacity capacity valid shape (by dsimp;omega)
          (fun i inside => List.getElem?_set_ne (by dsimp at inside;omega))
      exact ih _ retained (by dsimp;omega)
    · rw [if_neg cut]
      exact ⟨state,rfl⟩

-- Following all Drop continuations is explicit in resumeTruncation. This
-- completion theorem does not assume arbitrary user destructors must return.
theorem truncation_complete_result (view : α → Path → InitStore) (records : SelectionStore)
    (hard base : InitStore) (boundary capacity baseIndex : Nat) (state : BufferState α)
    (selected : selectRecord JarlStorage.state_State_truncate_ir.last.base records = base)
    (baseRead : recordWord base ["index"] = some baseIndex)
    (valid : LogRep view hard base state capacity) (boundaryWord : boundary < 2^64) :
    ∃ next, resumeTruncation (JarlStorage.state_State_truncate view records state boundary) = .returned next ∧
      LogRep view hard base next capacity ∧ next.len = min state.len (boundary - (baseIndex + 1)) ∧
      ∀ position, position < next.len → next.slots[position]? = state.slots[position]? := by
  obtain ⟨next,execution⟩ := truncation_returns view records hard base boundary capacity baseIndex (state.len + 1) state selected baseRead valid boundaryWord (by omega)
  have shape := truncation_preserves_shape view records boundary capacity state next valid.1 execution
  exact ⟨next,execution,(truncation_preserves_log view records hard base boundary capacity state next valid execution).1,
    truncation_length_exact view records hard base boundary capacity baseIndex _ state next selected baseRead valid boundaryWord execution,
    shape.2.2⟩

-- The append caller must establish these scalar relationships. push itself
-- deliberately remains a readable bounded-storage operation.
def LogSuccessor (hard previous entry : InitStore) : Prop :=
  ∃ previousIndex index previousTerm term hardTerm,
    recordWord previous ["index"] = some previousIndex ∧
    recordWord entry ["index"] = some index ∧
    recordWord previous ["term"] = some previousTerm ∧
    recordWord entry ["term"] = some term ∧
    recordWord hard ["term"] = some hardTerm ∧
    index = previousIndex + 1 ∧ index < 2^64 ∧ 0 < term ∧ previousTerm ≤ term ∧ term ≤ hardTerm

theorem append_preserves_log (bits capacity : Nat) (view : α → Path → InitStore) (records : SelectionStore)
    (hard base last : InitStore) (state : BufferState α) (entry : α)
    (selected : selectRecord JarlStorage.state_State_truncate_ir.last.base records = base)
    (valid : LogRep view hard base state capacity) (space : state.len < capacity) (word : capacity < 2^bits)
    (fetched : lastRecord JarlStorage.state_State_truncate_ir.last (truncationView view records state) = .ok last)
    (follows : LogSuccessor hard last (view entry ["id"])) :
    ∃ next, JarlStorage.state_State_push bits capacity state entry = .returned (.ok ()) next ∧
      LogRep view hard base next capacity ∧ next.len = state.len + 1 ∧
      ∀ position, position < state.len → next.slots[position]? = state.slots[position]? := by
  obtain ⟨shape,entries,previous,slots,length,chain⟩ := valid
  have stateEq : state = ⟨entries.map some ++ List.replicate (capacity - state.len) none,entries.length⟩ := by
    cases state
    simp_all
  have read := ordered_last_record view records hard base entries previous (capacity - state.len) selected chain
  rw [← stateEq] at read
  have same : previous = last := Except.ok.inj (read.symm.trans fetched)
  subst previous
  obtain ⟨previousIndex,index,previousTerm,term,hardTerm,readPrevious,readIndex,readPreviousTerm,readTerm,readHard,successor,range,positive,monotone,upper⟩ := follows
  have nextChain : OrderedEntries view hard base (entries ++ [entry]) (view entry ["id"]) :=
    .snoc entry previousIndex index previousTerm term hardTerm chain readPrevious readIndex readPreviousTerm readTerm readHard successor range positive monotone upper
  obtain ⟨next,execution,nextShape,nextLength⟩ := append_preserves_shape bits capacity state entry shape space word
  have nextEq : next = ⟨state.slots.set state.len (some entry),state.len + 1⟩ := by
    rw [append_exact bits capacity state entry shape space word] at execution
    exact (BufferRun.returned.inj execution).2.symm
  refine ⟨next,execution,⟨nextShape,entries ++ [entry],view entry ["id"],?_,by simpa [length] using nextLength,nextChain⟩,nextLength,?_⟩
  · rw [nextEq]
    dsimp
    rw [slots,length]
    have padding : capacity - entries.length = (capacity - (entries.length + 1)) + 1 := by omega
    rw [padding,List.replicate_succ]
    simp [List.set_append_right,List.map_append,List.append_assoc]
  · intro position inside
    rw [nextEq]
    exact List.getElem?_set_ne (by omega)

theorem append_preserves_committed_prefix (bits capacity baseIndex commit : Nat) (state : BufferState α) (entry : α)
    (shape : Shape state capacity) (space : state.len < capacity) (word : capacity < 2^bits)
    (commitBounds : baseIndex ≤ commit ∧ commit ≤ baseIndex + state.len) :
    ∃ next, JarlStorage.state_State_push bits capacity state entry = .returned (.ok ()) next ∧
      commit ≤ baseIndex + next.len ∧
      ∀ position, position < commit - baseIndex → next.slots[position]? = state.slots[position]? := by
  obtain ⟨next,execution,_,length⟩ := append_preserves_shape bits capacity state entry shape space word
  obtain ⟨framed,same,unchanged⟩ := append_preserves_prefix bits capacity state entry shape space word
  rw [execution] at same
  have identical := (BufferRun.returned.inj same).2
  subst framed
  exact ⟨next,execution,by omega,fun position inside => unchanged position (by omega)⟩

private theorem ordered_split (view : α → Path → InitStore) (hard base : InitStore)
    (entries : List α) (last : InitStore) (chain : OrderedEntries view hard base entries last) :
    ∀ count, count ≤ entries.length → ∃ middle,
      OrderedEntries view hard base (entries.take count) middle ∧
      OrderedEntries view hard middle (entries.drop count) last := by
  induction chain with
  | empty => intro count bound; exact ⟨base,by simpa using OrderedEntries.empty,by simpa using OrderedEntries.empty⟩
  | @snoc entries previous entry previousIndex index previousTerm term hardTerm chain previousRead indexRead previousTermRead termRead hardRead successor range positive monotone upper ih =>
    intro count bound
    by_cases earlier : count ≤ entries.length
    · obtain ⟨middle,left,right⟩ := ih count earlier
      refine ⟨middle,?_,?_⟩
      · simpa only [List.take_append_of_le_length earlier] using left
      · rw [List.drop_append_of_le_length earlier]
        exact .snoc entry previousIndex index previousTerm term hardTerm right previousRead indexRead previousTermRead termRead hardRead successor range positive monotone upper
    · have full : (entries ++ [entry]).length ≤ count := by simp only [List.length_append,List.length_singleton] at bound ⊢;omega
      rw [List.take_of_length_le full,List.drop_of_length_le full]
      exact ⟨view entry ["id"],.snoc entry previousIndex index previousTerm term hardTerm chain previousRead indexRead previousTermRead termRead hardRead successor range positive monotone upper,.empty⟩

private theorem record_at_live_offset (bits baseIndex offset : Nat) (state : LookupStore (Path → InitStore))
    (entry : Path → InitStore)
    (baseRead : selectRecord JarlStorage.state_State_install_ir.recordAt.lookup.base state.records ["index"] = .unsigned "u64" baseIndex)
    (range : baseIndex + offset + 1 < 2^64) (word : offset < 2^bits)
    (present : (state.slots ["entries"])[offset]? = some (some entry)) :
    recordAt JarlStorage.state_State_install_ir.recordAt bits state (baseIndex + offset + 1) = .ok (some (entry ["id"])) := by
  have indexRange : ¬ baseIndex + offset + 1 ≥ 2^64 := by omega
  have baseRange : ¬ baseIndex ≥ 2^64 := by omega
  have before : ¬ baseIndex + offset + 1 < baseIndex := by omega
  have equal : ¬ baseIndex + offset + 1 = baseIndex := by omega
  have bias : ¬ baseIndex + offset + 1 - baseIndex < 1 := by omega
  have position : baseIndex + offset + 1 - baseIndex - 1 = offset := by omega
  have offsetRange : ¬ offset ≥ 2^bits := by omega
  simp only [recordAt,show JarlStorage.state_State_install_ir.recordAt.guardField = ["index"] by rfl,baseRead]
  simp only [indexRange,baseRange,ne_eq,false_or,not_true_eq_false,if_false,
    show JarlStorage.state_State_install_ir.recordAt.equal = true by rfl,equal,decide_false]
  simp only [lookupRecord,show JarlStorage.state_State_install_ir.recordAt.lookup.baseField = ["index"] by rfl,baseRead]
  simp [JarlStorage.state_State_install_ir,indexRange,baseRange,before,bias,position,offsetRange,present]

private theorem ordered_boundary_lookup (bits baseIndex : Nat) (view : α → Path → InitStore)
    (records : SelectionStore) (hard base last : InitStore) (removed retained : List α) (padding : Nat)
    (slots : List (Option α))
    (selected : selectRecord JarlStorage.state_State_install_ir.recordAt.lookup.base records = base)
    (baseRead : recordWord base ["index"] = some baseIndex)
    (chain : OrderedEntries view hard base removed last)
    (slotRep : slots = removed.map some ++ retained.map some ++ List.replicate padding none)
    (range : baseIndex + removed.length < 2^64) (word : removed.length < 2^bits) :
    recordAt JarlStorage.state_State_install_ir.recordAt bits
      ⟨records,fun _ => slots.map (Option.map view)⟩ (baseIndex + removed.length) = .ok (some last) := by
  have baseValue := (record_word_read base ["index"] baseIndex baseRead).1
  cases chain with
  | empty =>
    simp only [List.length_nil,Nat.add_zero,recordAt,show JarlStorage.state_State_install_ir.recordAt.guardField = ["index"] by rfl,selected,baseValue]
    simp [JarlStorage.state_State_install_ir,show ¬ baseIndex ≥ 2^64 by omega]
  | @snoc front previous entry previousIndex index previousTerm term hardTerm chain previousRead indexRead previousTermRead termRead hardRead successor indexRange positive monotone upper =>
    have present : (slots.map (Option.map view))[front.length]? = some (some (view entry)) := by
      rw [slotRep]
      simp only [List.map_append,List.map_cons,List.map_nil]
      rw [List.getElem?_append_left (by simp),List.getElem?_append_left (by simp),List.getElem?_append_right (by simp)]
      simp
    have fetched := record_at_live_offset bits baseIndex front.length
      ⟨records,fun _ => slots.map (Option.map view)⟩ (view entry) (by simpa [selected] using baseValue)
      (by simpa [Nat.add_assoc] using range) (by simp only [List.length_append,List.length_singleton] at word;omega) present
    simpa [Nat.add_assoc] using fetched
private def SameLogId (left right : InitStore) : Prop :=
  recordWord left ["index"] = recordWord right ["index"] ∧ recordWord left ["term"] = recordWord right ["term"]

private theorem equality_log_id (left right : InitStore)
    (equal : recordEquality (some left) right [["index"],["term"]] = some true) : SameLogId left right := by
  cases li : recordWord left ["index"] <;>
    cases lt : recordWord left ["term"] <;>
    cases ri : recordWord right ["index"] <;>
    cases rt : recordWord right ["term"] <;>
    simp_all [recordEquality,recordWords,SameLogId,bind,pure,Option.bind]

private theorem ordered_rebase (view : α → Path → InitStore) (hard base newBase : InitStore)
    (entries : List α) (last : InitStore) (chain : OrderedEntries view hard base entries last)
    (same : SameLogId base newBase) :
    ∃ newLast, OrderedEntries view hard newBase entries newLast ∧ SameLogId last newLast := by
  induction chain with
  | empty => exact ⟨newBase,.empty,same⟩
  | @snoc entries previous entry previousIndex index previousTerm term hardTerm chain previousRead indexRead previousTermRead termRead hardRead successor range positive monotone upper ih =>
    obtain ⟨newPrevious,newChain,previousSame⟩ := ih
    exact ⟨view entry ["id"],.snoc entry previousIndex index previousTerm term hardTerm newChain
      (previousSame.1.symm.trans previousRead) indexRead (previousSame.2.symm.trans previousTermRead) termRead hardRead successor range positive monotone upper,⟨rfl,rfl⟩⟩
private def splitBuffer (removed retained : List α) (padding : Nat) : BufferState α :=
  ⟨removed.map some ++ retained.map some ++ List.replicate padding none,removed.length + retained.length⟩

theorem installation_matching_preserves_log (bits capacity baseIndex commit : Nat)
    (view : α → Path → InitStore) (snapshotView : β → Path → InitStore)
    (hard base last : InitStore) (removed retained : List α) (padding : Nat)
    (saved : Option β) (input : β) (found : Option InitStore)
    (shape : Shape (splitBuffer removed retained padding) capacity)
    (chain : OrderedEntries view hard base (removed ++ retained) last)
    (selected : selectRecord JarlStorage.state_State_install_ir.recordAt.lookup.base
      (installationView view snapshotView ⟨splitBuffer removed retained padding,commit,saved⟩).records = base)
    (baseRead : recordWord base ["index"] = some baseIndex)
    (inputRead : recordWord (snapshotView input ["last"]) ["index"] = some (baseIndex + removed.length))
    (word : removed.length < 2^bits) (commitWord : commit < 2^64)
    (commitBound : commit ≤ baseIndex + removed.length + retained.length)
    (matched : recordAt JarlStorage.state_State_install_ir.recordAt bits
      (installationView view snapshotView ⟨splitBuffer removed retained padding,commit,saved⟩)
      (baseIndex + removed.length) = .ok found)
    (equal : recordEquality found (snapshotView input ["last"]) [["index"],["term"]] = some true) :
    ∃ next, resumeInstallation (JarlStorage.state_State_install bits view snapshotView
        ⟨splitBuffer removed retained padding,commit,saved⟩ input) = .returned next ∧
      LogRep view hard (snapshotView input ["last"]) next.buffer capacity ∧
      next.snapshot = some input ∧ next.commit = max commit (baseIndex + removed.length) ∧
      baseIndex + removed.length ≤ next.commit ∧ next.commit ≤ baseIndex + removed.length + next.buffer.len ∧
      ∀ position, position < next.buffer.len →
        next.buffer.slots[position]? = (splitBuffer removed retained padding).slots[removed.length + position]? := by
  obtain ⟨middle,front,back⟩ := ordered_split view hard base (removed ++ retained) last chain removed.length (by simp)
  simp only [List.take_left,List.drop_left] at front back
  obtain ⟨inputValue,inputRange⟩ := record_word_read _ _ _ inputRead
  have baseValue := (record_word_read base ["index"] baseIndex baseRead).1
  have boundaryLookup := ordered_boundary_lookup bits baseIndex view
    (installationView view snapshotView ⟨splitBuffer removed retained padding,commit,saved⟩).records
    hard base middle removed retained padding (splitBuffer removed retained padding).slots selected baseRead front rfl inputRange word
  change recordAt JarlStorage.state_State_install_ir.recordAt bits
    (installationView view snapshotView ⟨splitBuffer removed retained padding,commit,saved⟩)
    (baseIndex + removed.length) = .ok (some middle) at boundaryLookup
  have foundEq : found = some middle := Except.ok.inj (matched.symm.trans boundaryLookup)
  have same := equality_log_id middle (snapshotView input ["last"]) (by simpa only [foundEq] using equal)
  obtain ⟨newLast,rebased,_⟩ := ordered_rebase view hard middle (snapshotView input ["last"]) retained last back same
  have selectedValue := (congrArg (fun record => record ["index"]) selected).trans baseValue
  have result := installation_matching_suffix_by_equality bits baseIndex commit view snapshotView
    (removed.map some) (retained.map some) (List.replicate padding none) saved input found
    (by simpa using inputValue) (by simpa using inputRange) (by simpa using word) commitWord
    (by simpa only [splitBuffer,List.length_map] using selectedValue) (by simpa [splitBuffer] using matched) equal
  simp only [List.length_map,List.length_replicate] at result
  let next : InstallationState α β :=
    ⟨⟨retained.map some ++ List.replicate (removed.length + padding) none,retained.length⟩,
      max commit (baseIndex + removed.length),some input⟩
  have execution : resumeInstallation (JarlStorage.state_State_install bits view snapshotView
      ⟨splitBuffer removed retained padding,commit,saved⟩ input) = .returned next := result
  have nextShape := installation_preserves_shape bits capacity view snapshotView
    ⟨splitBuffer removed retained padding,commit,saved⟩ next input shape execution
  have size := shape.1
  simp only [splitBuffer,List.length_append,List.length_map,List.length_replicate] at size
  have paddingEq : removed.length + padding = capacity - retained.length := by omega
  refine ⟨next,execution,⟨nextShape,retained,newLast,?_,rfl,rebased⟩,rfl,rfl,?_,?_,?_⟩
  · dsimp [next]
    rw [paddingEq]
  · dsimp [next];omega
  · dsimp [next];omega
  · intro position inside
    dsimp [next,splitBuffer] at inside ⊢
    rw [List.getElem?_append_left (by simpa using inside)]
    rw [List.getElem?_append_left (by simp;omega),List.getElem?_append_right (by simp)]
    simp
theorem installation_mismatching_resets_log (bits capacity index commit : Nat)
    (view : α → Path → InitStore) (snapshotView : β → Path → InitStore)
    (hard : InitStore) (entries : List α) (padding : Nat) (saved : Option β) (input : β) (found : Option InitStore)
    (shape : Shape (⟨entries.map some ++ List.replicate padding none,entries.length⟩ : BufferState α) capacity)
    (inputRead : recordWord (snapshotView input ["last"]) ["index"] = some index)
    (commitWord : commit < 2^64) (covered : commit ≤ index)
    (different : recordEquality found (snapshotView input ["last"]) [["index"],["term"]] = some false)
    (looked : recordAt JarlStorage.state_State_install_ir.recordAt bits
      (installationView view snapshotView ⟨⟨entries.map some ++ List.replicate padding none,entries.length⟩,commit,saved⟩)
      index = .ok found) :
    ∃ next, resumeInstallation (JarlStorage.state_State_install bits view snapshotView
        ⟨⟨entries.map some ++ List.replicate padding none,entries.length⟩,commit,saved⟩ input) = .returned next ∧
      LogRep view hard (snapshotView input ["last"]) next.buffer capacity ∧
      next.buffer.len = 0 ∧ next.commit = index ∧ next.snapshot = some input := by
  obtain ⟨value,range⟩ := record_word_read _ _ _ inputRead
  have result := installation_mismatching_prefix bits index commit view snapshotView
    (entries.map some) (List.replicate padding none) saved input found value range commitWord different (by simpa using looked)
  simp only [List.length_map] at result
  let next : InstallationState α β :=
    ⟨⟨List.replicate entries.length none ++ List.replicate padding none,0⟩,max commit index,some input⟩
  have execution : resumeInstallation (JarlStorage.state_State_install bits view snapshotView
      ⟨⟨entries.map some ++ List.replicate padding none,entries.length⟩,commit,saved⟩ input) = .returned next := result
  have nextShape := installation_preserves_shape bits capacity view snapshotView
    ⟨⟨entries.map some ++ List.replicate padding none,entries.length⟩,commit,saved⟩ next input shape execution
  have size := shape.1
  simp only [List.length_append,List.length_map,List.length_replicate] at size
  refine ⟨next,execution,⟨nextShape,[],snapshotView input ["last"],?_,rfl,.empty⟩,rfl,?_,rfl⟩
  · simp [next,List.replicate_append_replicate,size]
  · dsimp [next];omega

end Storage
