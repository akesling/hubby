import Provium.State
import Provium.OrderStatistics
import Provium.RankArithmetic

namespace Provium.State

structure NumericFold where
  first : RecordProjection
  second : RecordProjection
  secondRequired : Condition
  divisor : Nat
  divisorProper : 1 < divisor

-- Numeric replies are bounded u64 values. The list represents the initialized
-- buffer prefix. Buffer/layout and Rust sort_unstable refinement remain open.
def numericRank (values : List UInt64) (divisor : Nat) : Option UInt64 :=
  (Provium.OrderStatistics.rank (values.map UInt64.toNat) divisor).map UInt64.ofNat

theorem numericRank_eq_of_counts (values : List UInt64) (divisor : Nat) (value : UInt64)
    (proper : 1 < divisor)
    (supported : values.length / divisor < (values.map UInt64.toNat).countP (fun v => decide (value.toNat ≤ v)))
    (rejected : (values.map UInt64.toNat).countP (fun v => decide (value.toNat + 1 ≤ v)) ≤ values.length / divisor) :
    numericRank values divisor = some value := by
  unfold numericRank
  rw [Provium.OrderStatistics.rank_eq_of_counts _ _ value.toNat proper
    (by simpa only [List.length_map] using supported)
    (by simpa only [List.length_map] using rejected)]
  simp

theorem numericRank_toNat (values : List UInt64) (divisor : Nat) (value : UInt64)
    (selected : numericRank values divisor = some value) :
    Provium.OrderStatistics.rank (values.map UInt64.toNat) divisor = some value.toNat := by
  cases ranked : Provium.OrderStatistics.rank (values.map UInt64.toNat) divisor with
  | none => simp [numericRank, ranked] at selected
  | some number =>
    have bounded : number < UInt64.size := Provium.OrderStatistics.rank_bound _ _ _ _ ranked (by
      intro n member
      obtain ⟨v, _, rfl⟩ := List.mem_map.mp member
      exact v.toNat_lt_size)
    have same : UInt64.ofNat number = value := by simpa [numericRank, ranked] using selected
    rw [← same, UInt64.toNat_ofNat_of_lt' bounded]

theorem numericRank_threshold (values : List UInt64) (divisor : Nat) (value x : UInt64)
    (proper : 1 < divisor) (selected : numericRank values divisor = some value) :
    x.toNat ≤ value.toNat ↔ values.length / divisor <
      (values.map UInt64.toNat).countP (fun v => decide (x.toNat ≤ v)) := by
  simpa only [List.length_map] using Provium.OrderStatistics.rank_threshold _ divisor value.toNat proper
    (numericRank_toNat values divisor value selected) x.toNat

def finishNumericPanic (callback : σ) (abortOnPanic : Bool) : CallbackRun α σ UInt64 UInt64 :=
  finishCallback callback (if abortOnPanic then .abort else .unwind)

-- Indexed writes expose the initialized prefix and preserve the unused suffix.
-- The guard is checked after the callback reply, matching RHS-before-place
-- evaluation. This remains a logical buffer model, not a Rust memory theorem.
def writeNumeric (buffer : List UInt64) (count : Nat) : List UInt64 → List UInt64
  | [] => buffer
  | value :: rest => writeNumeric (buffer.set count value) (count + 1) rest

theorem writeNumeric_length (buffer : List UInt64) (count : Nat) (values : List UInt64) :
    (writeNumeric buffer count values).length = buffer.length := by
  induction values generalizing buffer count with
  | nil => rfl
  | cons value rest ih => simpa only [writeNumeric, List.length_set] using ih (buffer.set count value) (count + 1)

theorem writeNumeric_cons (head : UInt64) (buffer : List UInt64) (count : Nat) (values : List UInt64) :
    writeNumeric (head :: buffer) (count + 1) values = head :: writeNumeric buffer count values := by
  induction values generalizing buffer count with
  | nil => rfl
  | cons value rest ih => simpa only [writeNumeric, List.set_cons_succ] using ih (buffer.set count value) (count + 1)

theorem writeNumeric_contents (buffer : List UInt64) (count : Nat) (values : List UInt64)
    (room : count + values.length ≤ buffer.length) :
    writeNumeric buffer count values = buffer.take count ++ values ++ buffer.drop (count + values.length) := by
  induction buffer generalizing count values with
  | nil =>
    have zero : count = 0 := by simp only [List.length_nil] at room; omega
    have empty : values = [] := List.length_eq_zero_iff.mp (by simp only [List.length_nil] at room; omega)
    subst count; subst values; rfl
  | cons head tail ih =>
    cases count with
    | zero =>
      cases values with
      | nil => simp [writeNumeric]
      | cons value rest =>
        have space : 0 + rest.length ≤ tail.length := by simpa using room
        simpa [writeNumeric, writeNumeric_cons] using congrArg (List.cons value) (ih 0 rest space)
    | succ count =>
      have space : count + values.length ≤ tail.length := by simp only [List.length_cons] at room; omega
      simpa only [writeNumeric_cons, Nat.succ_add, List.take_succ_cons, List.drop_succ_cons, List.cons_append] using congrArg (List.cons head) (ih count values space)

def fillNumericCallbacks (keys : List (Cell α)) (callback : σ) (buffer : List UInt64)
    (count : Nat) (abortOnPanic : Bool)
    (next : List UInt64 → Nat → σ → CallbackRun α σ UInt64 UInt64) : CallbackRun α σ UInt64 UInt64 :=
  match keys with
  | [] => next buffer count callback
  | key :: rest => .call key callback fun reply => match reply with
    | .value answer advanced =>
      if count < buffer.length then
        fillNumericCallbacks rest advanced (buffer.set count answer) (count + 1) abortOnPanic next
      else finishNumericPanic advanced abortOnPanic
    | .unwind advanced => finishCallback advanced .unwind
    | .abort => .returned .abort

def fillNumericWords (keys : List (Cell α)) (callback : σ) (buffer : List UInt64)
    (count bits : Nat) (checked abortOnPanic : Bool)
    (next : List UInt64 → Nat → σ → CallbackRun α σ UInt64 UInt64) : CallbackRun α σ UInt64 UInt64 :=
  match keys with
  | [] => next buffer count callback
  | key :: rest => .call key callback fun reply => match reply with
    | .value answer advanced =>
      if count < buffer.length then
        let written := buffer.set count answer
        match Provium.RankArithmetic.increment bits count checked with
        | .ok (.uint _ successor) => fillNumericWords rest advanced written successor bits checked abortOnPanic next
        | _ => finishNumericPanic advanced abortOnPanic
      else finishNumericPanic advanced abortOnPanic
    | .unwind advanced => finishCallback advanced .unwind
    | .abort => .returned .abort

theorem fillNumericWords_refines (keys : List (Cell α)) (callback : σ) (buffer : List UInt64)
    (count bits : Nat) (checked abortOnPanic : Bool)
    (next : List UInt64 → Nat → σ → CallbackRun α σ UInt64 UInt64)
    (width : Provium.validWidth bits = true) (capacity : buffer.length < 2^bits) :
    fillNumericWords keys callback buffer count bits checked abortOnPanic next =
      fillNumericCallbacks keys callback buffer count abortOnPanic next := by
  induction keys generalizing callback buffer count with
  | nil => rfl
  | cons key rest ih =>
    simp only [fillNumericWords, fillNumericCallbacks]
    congr 1
    funext reply
    cases reply with
    | value answer advanced =>
      dsimp only
      split
      · rename_i within
        rw [Provium.RankArithmetic.increment_within_capacity bits count buffer.length checked width within capacity]
        exact ih advanced (buffer.set count answer) (count + 1) (by simpa only [List.length_set] using capacity)
      · rfl
    | unwind advanced => rfl
    | abort => rfl

theorem fillNumericCallbacks_refines (keys : List (Cell α)) (callback : σ) (buffer : List UInt64)
    (count : Nat) (abortOnPanic : Bool)
    (next : List UInt64 → Nat → σ → CallbackRun α σ UInt64 UInt64)
    (room : count + keys.length ≤ buffer.length) :
    fillNumericCallbacks keys callback buffer count abortOnPanic next =
      collectCallbacks keys callback (fun values advanced => next (writeNumeric buffer count values) (count + values.length) advanced) := by
  induction keys generalizing callback buffer count next with
  | nil => simp [fillNumericCallbacks, collectCallbacks, writeNumeric]
  | cons key rest ih =>
    have within : count < buffer.length := by simp only [List.length_cons] at room; omega
    simp only [fillNumericCallbacks, collectCallbacks]
    congr 1
    funext reply
    cases reply with
    | value answer advanced =>
      simp only [within, ↓reduceIte]
      rw [ih advanced (buffer.set count answer) (count + 1) next (by simpa [Nat.add_assoc, Nat.add_comm, Nat.add_left_comm] using room)]
      congr 1
      funext values final
      simp only [writeNumeric, List.length_cons]
      congr 1 <;> omega
    | unwind advanced => rfl
    | abort => rfl

theorem collectCallbacks_congr (keys : List (Cell α)) (callback : σ)
    (left right : List β → σ → CallbackRun α σ β ρ)
    (agree : ∀ values advanced, values.length = keys.length → left values advanced = right values advanced) :
    collectCallbacks keys callback left = collectCallbacks keys callback right := by
  induction keys generalizing callback left right with
  | nil => exact agree [] callback rfl
  | cons key rest ih =>
    simp only [collectCallbacks]
    congr 1
    funext reply
    cases reply with
    | value answer advanced =>
      apply ih
      intro values final length
      exact agree (answer :: values) final (by simp only [List.length_cons, length])
    | unwind advanced => rfl
    | abort => rfl

theorem writeNumeric_prefix (buffer values : List UInt64) (room : values.length ≤ buffer.length) :
    (writeNumeric buffer 0 values).take values.length = values := by
  rw [writeNumeric_contents buffer 0 values (by simpa using room)]
  simp

-- Only continuations reached after exactly one normal reply per key matter.
-- The theorem does not require equal answers for repeated keys.
theorem fillNumericCallbacks_prefix (keys : List (Cell α)) (callback : σ) (buffer : List UInt64)
    (abortOnPanic : Bool) (next : List UInt64 → σ → CallbackRun α σ UInt64 UInt64)
    (room : keys.length ≤ buffer.length) :
    fillNumericCallbacks keys callback buffer 0 abortOnPanic (fun buffer count advanced => next (buffer.take count) advanced) =
      collectCallbacks keys callback next := by
  rw [fillNumericCallbacks_refines keys callback buffer 0 abortOnPanic _ (by simpa using room)]
  apply collectCallbacks_congr
  intro values advanced length
  simp only [Nat.zero_add]
  rw [writeNumeric_prefix buffer values (by omega)]

-- Canonical numeric sorting updates only the initialized prefix. Connecting
-- this operation to Rust's unstable sorting algorithm remains a library proof.
def sortNumericBuffer (buffer : List UInt64) (count : Nat) : List UInt64 :=
  (Provium.OrderStatistics.sort ((buffer.take count).map UInt64.toNat)).map UInt64.ofNat ++ buffer.drop count

def selectNumericBuffer (buffer : List UInt64) (count divisor : Nat) : Option UInt64 :=
  if count = 0 then none else buffer[Provium.OrderStatistics.rankOffset count divisor]?

-- This equates success/failure observations while the scalar model retains
-- the distinct overflow versus bounds faults for empty inputs.
theorem selectNumericBuffer_word_refines (buffer : List UInt64) (bits count divisor : Nat) (checked : Bool)
    (width : Provium.validWidth bits = true) (within : count ≤ buffer.length)
    (capacity_fits : buffer.length < 2^bits) (proper : 1 < divisor) (divisor_fits : divisor < 2^bits) :
    (Provium.RankArithmetic.select buffer bits count divisor checked).toOption = selectNumericBuffer buffer count divisor := by
  by_cases zero : count = 0
  · subst count
    rw [Provium.RankArithmetic.select_empty buffer bits divisor checked width proper divisor_fits capacity_fits]
    cases checked <;> rfl
  · rw [Provium.RankArithmetic.select_nonempty buffer bits count divisor checked width
      (Nat.pos_of_ne_zero zero) proper (Nat.lt_of_le_of_lt within capacity_fits) divisor_fits]
    simp only [selectNumericBuffer, zero, ↓reduceIte]

theorem sortNumericBuffer_length (buffer : List UInt64) (count : Nat) :
    (sortNumericBuffer buffer count).length = buffer.length := by
  simp only [sortNumericBuffer, List.length_append, List.length_map,
    Provium.OrderStatistics.sort_length, List.length_take, List.length_drop]
  omega

theorem sortNumericBuffer_permutation (buffer : List UInt64) (count : Nat) :
    (sortNumericBuffer buffer count).Perm buffer := by
  have sorted : ((Provium.OrderStatistics.sort ((buffer.take count).map UInt64.toNat)).map UInt64.ofNat).Perm
      (buffer.take count) := by
    simpa [Function.comp_def] using (Provium.OrderStatistics.sort_permutation ((buffer.take count).map UInt64.toNat)).map UInt64.ofNat
  simpa only [sortNumericBuffer, List.take_append_drop] using sorted.append (List.Perm.refl (buffer.drop count))

theorem sortNumericBuffer_suffix (buffer : List UInt64) (count : Nat)
    (within : count ≤ buffer.length) :
    (sortNumericBuffer buffer count).drop count = buffer.drop count := by
  unfold sortNumericBuffer
  have length : ((Provium.OrderStatistics.sort ((buffer.take count).map UInt64.toNat)).map UInt64.ofNat).length = count := by
    simp [Provium.OrderStatistics.sort_length, Nat.min_eq_left within]
  simpa only [length] using (List.drop_left (l₁ := (Provium.OrderStatistics.sort ((buffer.take count).map UInt64.toNat)).map UInt64.ofNat) (l₂ := buffer.drop count))

theorem selectNumericBuffer_refines (buffer : List UInt64) (count divisor : Nat)
    (within : count ≤ buffer.length) :
    selectNumericBuffer (sortNumericBuffer buffer count) count divisor = numericRank (buffer.take count) divisor := by
  have prefix_length : (buffer.take count).length = count := by simp [Nat.min_eq_left within]
  by_cases zero : count = 0
  · subst count
    rfl
  · have nonempty : (buffer.take count).isEmpty = false := List.isEmpty_eq_false_iff.mpr (by
      intro empty
      rw [empty] at prefix_length
      simp only [List.length_nil] at prefix_length
      exact zero prefix_length.symm)
    have index : Provium.OrderStatistics.rankOffset count divisor < count :=
      Nat.sub_lt (Nat.pos_of_ne_zero zero) (Nat.succ_pos _)
    simp only [selectNumericBuffer, zero, ↓reduceIte, sortNumericBuffer,
      numericRank, Provium.OrderStatistics.rank, List.isEmpty_map, nonempty,
      Bool.false_eq_true, List.length_map, prefix_length]
    rw [List.getElem?_append_left (by simpa only [List.length_map, Provium.OrderStatistics.sort_length, prefix_length] using index)]
    exact List.getElem?_map

theorem fillNumericRank_refines (keys : List (Cell α)) (callback : σ) (buffer : List UInt64)
    (divisor : Nat) (abortOnPanic : Bool) (next : Option UInt64 → σ → CallbackRun α σ UInt64 UInt64)
    (room : keys.length ≤ buffer.length) :
    fillNumericCallbacks keys callback buffer 0 abortOnPanic
      (fun buffer count advanced => next (selectNumericBuffer (sortNumericBuffer buffer count) count divisor) advanced) =
      collectCallbacks keys callback (fun values advanced => next (numericRank values divisor) advanced) := by
  rw [fillNumericCallbacks_refines _ _ _ _ _ _ (by simpa using room)]
  apply collectCallbacks_congr
  intro values advanced length
  simp only [Nat.zero_add]
  rw [selectNumericBuffer_refines _ _ _ (by simpa only [writeNumeric_length, length] using room)]
  rw [writeNumeric_prefix buffer values (by omega)]

theorem fillNumericRankWords_refines (keys : List (Cell α)) (callback : σ) (buffer : List UInt64)
    (bits divisor : Nat) (checked abortOnPanic : Bool) (next : Option UInt64 → σ → CallbackRun α σ UInt64 UInt64)
    (width : Provium.validWidth bits = true) (capacity : buffer.length < 2^bits)
    (proper : 1 < divisor) (divisor_fits : divisor < 2^bits) (room : keys.length ≤ buffer.length) :
    fillNumericWords keys callback buffer 0 bits checked abortOnPanic
      (fun buffer count advanced => next (Provium.RankArithmetic.select (sortNumericBuffer buffer count) bits count divisor checked).toOption advanced) =
      collectCallbacks keys callback (fun values advanced => next (numericRank values divisor) advanced) := by
  rw [fillNumericWords_refines _ _ _ _ _ _ _ _ width capacity]
  rw [fillNumericCallbacks_refines _ _ _ _ _ _ (by simpa using room)]
  apply collectCallbacks_congr
  intro values advanced length
  simp only [Nat.zero_add]
  rw [selectNumericBuffer_word_refines _ _ _ _ _ width
    (by simpa only [sortNumericBuffer_length, writeNumeric_length, length] using room)
    (by simpa only [sortNumericBuffer_length, writeNumeric_length] using capacity) proper divisor_fits]
  rw [selectNumericBuffer_refines _ _ _ (by simpa only [writeNumeric_length, length] using room)]
  rw [writeNumeric_prefix buffer values (by omega)]

def runNumericFoldList (program : NumericFold) (entries : ArrayStore α) (callback : σ)
    (abortOnPanic : Bool) : CallbackRun α σ UInt64 UInt64 :=
  collectCallbacks (projectArray program.first entries) callback fun values advanced =>
    match numericRank values program.divisor with
    | none => finishNumericPanic advanced abortOnPanic
    | some first =>
      if queryArray program.secondRequired entries then
        collectCallbacks (projectArray program.second entries) advanced fun values advanced =>
          match numericRank values program.divisor with
          | none => finishNumericPanic advanced abortOnPanic
          | some second => finishCallback advanced (.value (min first second))
      else finishCallback advanced (.value first)

-- The executable model carries the fixed-capacity buffer, prefix sorts, index
-- reads and count through both passes. Rust memory/library refinement is open.
def runNumericFold (program : NumericFold) (entries : ArrayStore α) (callback : σ)
    (abortOnPanic : Bool) : CallbackRun α σ UInt64 UInt64 :=
  fillNumericCallbacks (projectArray program.first entries) callback (List.replicate entries.length 0) 0 abortOnPanic
    fun buffer count advanced =>
      let sorted := sortNumericBuffer buffer count
      match selectNumericBuffer sorted count program.divisor with
      | none => finishNumericPanic advanced abortOnPanic
      | some first =>
        if queryArray program.secondRequired entries then
          fillNumericCallbacks (projectArray program.second entries) advanced sorted 0 abortOnPanic
            fun buffer count advanced =>
              let sorted := sortNumericBuffer buffer count
              match selectNumericBuffer sorted count program.divisor with
              | none => finishNumericPanic advanced abortOnPanic
              | some second => finishCallback advanced (.value (min first second))
        else finishCallback advanced (.value first)

theorem runNumericFold_refines (program : NumericFold) (entries : ArrayStore α) (callback : σ)
    (abortOnPanic : Bool) :
    runNumericFold program entries callback abortOnPanic = runNumericFoldList program entries callback abortOnPanic := by
  unfold runNumericFold runNumericFoldList
  rw [fillNumericCallbacks_refines _ _ _ _ _ _ (by simpa using projectArray_length program.first entries)]
  apply collectCallbacks_congr
  intro values advanced length
  simp only [Nat.zero_add]
  rw [selectNumericBuffer_refines _ _ _ (by simpa only [writeNumeric_length, List.length_replicate, length] using projectArray_length program.first entries)]
  rw [writeNumeric_prefix _ values (by simpa [length] using projectArray_length program.first entries)]
  cases ranked : numericRank values program.divisor with
  | none => rfl
  | some first =>
    simp only []
    split
    · exact fillNumericRank_refines (projectArray program.second entries) advanced _ program.divisor abortOnPanic
        (fun result advanced => match result with
          | none => finishNumericPanic advanced abortOnPanic
          | some second => finishCallback advanced (.value (min first second)))
        (by simpa only [sortNumericBuffer_length, writeNumeric_length, List.length_replicate] using projectArray_length program.second entries)
    · rfl

def runNumericWords (program : NumericFold) (entries : ArrayStore α) (callback : σ)
    (bits : Nat) (checked abortOnPanic : Bool) : CallbackRun α σ UInt64 UInt64 :=
  fillNumericWords (projectArray program.first entries) callback (List.replicate entries.length 0) 0 bits checked abortOnPanic
    fun buffer count advanced =>
      let sorted := sortNumericBuffer buffer count
      match (Provium.RankArithmetic.select sorted bits count program.divisor checked).toOption with
      | none => finishNumericPanic advanced abortOnPanic
      | some first =>
        if queryArray program.secondRequired entries then
          fillNumericWords (projectArray program.second entries) advanced sorted 0 bits checked abortOnPanic
            fun buffer count advanced =>
              let sorted := sortNumericBuffer buffer count
              match (Provium.RankArithmetic.select sorted bits count program.divisor checked).toOption with
              | none => finishNumericPanic advanced abortOnPanic
              | some second => finishCallback advanced (.value (min first second))
        else finishCallback advanced (.value first)

theorem runNumericWords_refines (program : NumericFold) (entries : ArrayStore α) (callback : σ)
    (bits : Nat) (checked abortOnPanic : Bool) (width : Provium.validWidth bits = true)
    (capacity : entries.length < 2^bits) (divisor_fits : program.divisor < 2^bits) :
    runNumericWords program entries callback bits checked abortOnPanic = runNumericFold program entries callback abortOnPanic := by
  rw [runNumericFold_refines]
  unfold runNumericWords runNumericFoldList
  rw [fillNumericWords_refines _ _ _ _ _ _ _ _ width (by simpa using capacity)]
  rw [fillNumericCallbacks_refines _ _ _ _ _ _ (by simpa using projectArray_length program.first entries)]
  apply collectCallbacks_congr
  intro values advanced length
  simp only [Nat.zero_add]
  rw [selectNumericBuffer_word_refines _ _ _ _ _ width
    (by simpa only [sortNumericBuffer_length, writeNumeric_length, List.length_replicate, length] using projectArray_length program.first entries)
    (by simpa only [sortNumericBuffer_length, writeNumeric_length, List.length_replicate] using capacity)
    program.divisorProper divisor_fits]
  rw [selectNumericBuffer_refines _ _ _ (by simpa only [writeNumeric_length, List.length_replicate, length] using projectArray_length program.first entries)]
  rw [writeNumeric_prefix _ values (by simpa [length] using projectArray_length program.first entries)]
  cases ranked : numericRank values program.divisor with
  | none => rfl
  | some first =>
    simp only []
    split
    · exact fillNumericRankWords_refines (projectArray program.second entries) advanced _ bits program.divisor checked abortOnPanic
        (fun result advanced => match result with
          | none => finishNumericPanic advanced abortOnPanic
          | some second => finishCallback advanced (.value (min first second)))
        width (by simpa only [sortNumericBuffer_length, writeNumeric_length, List.length_replicate] using capacity)
        program.divisorProper divisor_fits
        (by simpa only [sortNumericBuffer_length, writeNumeric_length, List.length_replicate] using projectArray_length program.second entries)
    · rfl

-- A bound on completed interactions, conditional on callback/drop responses.
-- This does not discharge Rust source, library or callback termination contracts.
theorem numeric_fold_budget (program : NumericFold) (entries : ArrayStore α)
    (callback : σ) (abortOnPanic : Bool) :
    callbackBudget ((projectArray program.first entries).length + (projectArray program.second entries).length + 2)
      (runNumericFold program entries callback abortOnPanic) := by
  rw [runNumericFold_refines]
  unfold runNumericFoldList
  rw [Nat.add_assoc]
  apply callback_collect_budget _ _ _ _ (by omega)
  intro values advanced
  have finish (result : CallbackExit UInt64) :
      callbackBudget ((projectArray program.second entries).length + 2)
        (finishCallback advanced result : CallbackRun α σ UInt64 UInt64) := by
    simpa [Nat.add_comm] using callback_budget_add 2 (projectArray program.second entries).length _
      (callback_finish_budget advanced result)
  split
  · exact finish _
  · split
    · apply callback_collect_budget _ _ _ 2 (by omega)
      intro values final
      split <;> exact callback_finish_budget final _
    · exact finish _

theorem numeric_words_budget (program : NumericFold) (entries : ArrayStore α)
    (callback : σ) (bits : Nat) (checked abortOnPanic : Bool)
    (width : Provium.validWidth bits = true) (capacity : entries.length < 2^bits)
    (divisor_fits : program.divisor < 2^bits) :
    callbackBudget ((projectArray program.first entries).length + (projectArray program.second entries).length + 2)
      (runNumericWords program entries callback bits checked abortOnPanic) := by
  rw [runNumericWords_refines _ _ _ _ _ _ width capacity divisor_fits]
  exact numeric_fold_budget program entries callback abortOnPanic

/-! Pure callback evaluation: one admissible environment for stating what a
    callback fold computes; general responses remain `observeCallback`. -/

/-- Outcome of a callback interaction when every call returns normally with
    `answer key`, leaving the handle unchanged, and every destructor returns
    normally. This is one admissible environment, not a claim that Rust
    callbacks are pure; general response sequences remain `observeCallback`. -/
def pureCallbackResult (answer : Cell α → β) : CallbackRun α σ β ρ → CallbackExit ρ
  | .returned result => result
  | .call key callback resume => pureCallbackResult answer (resume (.value (answer key) callback))
  | .drop _ resume => pureCallbackResult answer (resume .returned)

theorem pure_collect_callbacks (answer : Cell α → β) (keys : List (Cell α)) (callback : σ)
    (next : List β → σ → CallbackRun α σ β ρ) :
    pureCallbackResult answer (collectCallbacks keys callback next) =
      pureCallbackResult answer (next (keys.map answer) callback) := by
  induction keys generalizing next with
  | nil => rfl
  | cons key rest ih =>
    simp only [collect_callbacks_head, pureCallbackResult, List.map_cons]
    exact ih (fun values final => next (answer key :: values) final)

theorem pure_finish_value (answer : Cell α → β) (callback : σ) (result : ρ) :
    pureCallbackResult answer (finishCallback callback (.value result) : CallbackRun α σ β ρ) =
      .value result := rfl

theorem pure_finish_numeric_panic (answer : Cell α → UInt64) (callback : σ) (abortOnPanic : Bool) :
    pureCallbackResult answer (finishNumericPanic callback abortOnPanic : CallbackRun α σ UInt64 UInt64) ≠
      .value result := by
  cases abortOnPanic <;> simp [finishNumericPanic, finishCallback, pureCallbackResult]

theorem pure_count_predicates (answer : Cell α → Bool) (keys : List (Cell α)) (callback : σ)
    (count : Nat) (next : Nat → σ → PredicateRun α σ) :
    pureCallbackResult answer (countPredicates keys callback count next) =
      pureCallbackResult answer (next (count + keys.countP answer) callback) := by
  induction keys generalizing count with
  | nil => rfl
  | cons key rest ih =>
    simp only [predicate_count_head, pureCallbackResult, ih, List.countP_cons]
    congr 2
    cases answer key <;> simp [Nat.add_assoc, Nat.add_comm]

end Provium.State
