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
    input_word,matched,recordEquality,show JarlStorage.state_State_install_ir.equalityFields = [["index"],["term"]] by rfl,values]
  simp only [bind, pure, Option.bind, beq_self_eq_true,show JarlStorage.state_State_install_ir.equal = true by rfl,if_true,
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

-- Capacity is part of the history index, so growth is not treated as a fixed
-- capacity assumption. These histories still exclude restore and do not encode protocol reachability.
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

end Storage
