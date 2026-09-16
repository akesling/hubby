import Lean

/- Logical order-statistic contracts. Rust sorting, buffer ownership, numeric
representation and source lowering must separately refine these operations. -/
namespace Provium.OrderStatistics

def sort (values : List Nat) : List Nat := values.mergeSort (fun a b => decide (a ≤ b))

theorem sort_length (values : List Nat) : (sort values).length = values.length :=
  List.length_mergeSort values

theorem sort_permutation (values : List Nat) : (sort values).Perm values :=
  List.mergeSort_perm values _

theorem sort_ordered (values : List Nat) : (sort values).Pairwise (· ≤ ·) := by
  have sorted := List.pairwise_mergeSort (le := fun a b : Nat => decide (a ≤ b))
    (by intro a b c ab bc; simp only [decide_eq_true_eq] at *; omega)
    (by intro a b; simp; omega) values
  simpa only [sort, decide_eq_true_eq] using sorted

-- A sorted element at offset k is at least x exactly when at least n-k
-- elements are at least x. Ties count independently; no uniqueness is assumed.
theorem sorted_threshold (values : List Nat) (ordered : values.Pairwise (· ≤ ·))
    (k : Nat) (within : k < values.length) (x : Nat) :
    values.length - k ≤ values.countP (fun v => decide (x ≤ v)) ↔ x ≤ values[k] := by
  induction values generalizing k with
  | nil => simp at within
  | cons head tail ih =>
    obtain ⟨head_le, ordered⟩ := List.pairwise_cons.mp ordered
    by_cases accepted : x ≤ head
    · have all : ∀ v ∈ head :: tail, decide (x ≤ v) = true := by
        intro v member
        rcases List.mem_cons.mp member with same | member
        · subst v; exact decide_eq_true accepted
        · exact decide_eq_true (Nat.le_trans accepted (head_le v member))
      have count := List.countP_eq_length.mpr all
      have selected := of_decide_eq_true (all _ (List.getElem_mem within))
      rw [count]
      exact ⟨fun _ => selected, fun _ => Nat.sub_le _ _⟩
    · cases k with
      | zero =>
        simp only [List.getElem_cons_zero, Nat.sub_zero]
        have count : (head :: tail).countP (fun v => decide (x ≤ v)) =
            tail.countP (fun v => decide (x ≤ v)) := List.countP_cons_of_neg (by simpa using accepted)
        rw [count]
        have bound := List.countP_le_length (p := fun v => decide (x ≤ v)) (l := tail)
        simp only [List.length_cons]
        omega
      | succ k =>
        have bound : k < tail.length := by simpa using within
        simpa [List.countP_cons, accepted] using ih ordered k bound

-- The expression preserves the source rank n - (n/divisor + 1). Divisor and
-- nonempty constraints are explicit; failed selection has no fabricated value.
def rankOffset (count divisor : Nat) : Nat := count - (count / divisor + 1)

def wrappingRankOffset (bits count divisor : Nat) : Nat :=
  (count + 2^bits - (count / divisor + 1)) % 2^bits

def rank (values : List Nat) (divisor : Nat) : Option Nat :=
  if values.isEmpty then none
  else (sort values)[rankOffset values.length divisor]?

theorem rank_exists (values : List Nat) (divisor : Nat) (proper : 1 < divisor)
    (nonempty : values ≠ []) : ∃ value, rank values divisor = some value := by
  have positive : 0 < values.length := List.length_pos_iff.mpr nonempty
  have division : values.length / divisor < values.length := Nat.div_lt_self positive proper
  have within : values.length - (values.length / divisor + 1) < (sort values).length := by
    rw [sort_length]
    exact Nat.sub_lt positive (Nat.succ_pos _)
  unfold rank
  rw [List.isEmpty_eq_false_iff.mpr nonempty]
  simp only [Bool.false_eq_true, ↓reduceIte]
  exact ⟨_, List.getElem?_eq_some_iff.mpr ⟨within, rfl⟩⟩

theorem rank_threshold (values : List Nat) (divisor value : Nat) (proper : 1 < divisor)
    (selected : rank values divisor = some value) (x : Nat) :
    x ≤ value ↔ values.length / divisor < values.countP (fun v => decide (x ≤ v)) := by
  have nonempty : values ≠ [] := by
    intro empty
    simp [rank, empty] at selected
  have positive : 0 < values.length := List.length_pos_iff.mpr nonempty
  have division : values.length / divisor < values.length := Nat.div_lt_self positive proper
  unfold rank at selected
  rw [List.isEmpty_eq_false_iff.mpr nonempty] at selected
  obtain ⟨within, same⟩ := List.getElem?_eq_some_iff.mp selected
  have threshold := sorted_threshold (sort values) (sort_ordered values) _ within x
  rw [same, sort_length, (sort_permutation values).countP_eq] at threshold
  have subtraction : values.length - (values.length - (values.length / divisor + 1)) =
      values.length / divisor + 1 := Nat.sub_sub_self (Nat.succ_le_of_lt division)
  simp only [rankOffset] at threshold
  rw [subtraction] at threshold
  omega

theorem rank_member (values : List Nat) (divisor value : Nat)
    (selected : rank values divisor = some value) : value ∈ values := by
  unfold rank at selected
  split at selected
  · contradiction
  · exact (sort_permutation values).mem_iff.mp (List.mem_of_getElem? selected)

theorem rank_none_iff (values : List Nat) (divisor : Nat) (proper : 1 < divisor) :
    rank values divisor = none ↔ values = [] := by
  constructor
  · intro missing
    by_cases empty : values = []
    · exact empty
    · obtain ⟨value, selected⟩ := rank_exists values divisor proper empty
      rw [missing] at selected
      contradiction
  · intro empty
    simp [rank, empty]

theorem rank_supported (values : List Nat) (divisor value : Nat) (proper : 1 < divisor)
    (selected : rank values divisor = some value) :
    values.length / divisor < values.countP (fun v => decide (value ≤ v)) :=
  (rank_threshold values divisor value proper selected value).mp (Nat.le_refl value)

theorem rank_larger_rejected (values : List Nat) (divisor value x : Nat) (proper : 1 < divisor)
    (selected : rank values divisor = some value) (larger : value < x) :
    values.countP (fun v => decide (x ≤ v)) ≤ values.length / divisor := by
  have threshold := rank_threshold values divisor value proper selected x
  omega

-- Preservation of scalar representation bounds follows from selecting an
-- actual reply. Instantiating bound with 2^64 does not prove usize indexing.
theorem rank_bound (values : List Nat) (divisor value bound : Nat)
    (selected : rank values divisor = some value) (bounded : ∀ v ∈ values, v < bound) :
    value < bound := bounded value (rank_member values divisor value selected)

theorem rank_permutation (values other : List Nat) (divisor value result : Nat)
    (proper : 1 < divisor) (permutation : values.Perm other)
    (selected : rank values divisor = some value) (other_selected : rank other divisor = some result) :
    value = result := by
  have first := rank_supported values divisor value proper selected
  have second := rank_supported other divisor result proper other_selected
  rw [permutation.length_eq, permutation.countP_eq] at first
  rw [← permutation.length_eq, ← permutation.countP_eq] at second
  have forward := (rank_threshold other divisor result proper other_selected value).mpr first
  have backward := (rank_threshold values divisor value proper selected result).mpr second
  omega

-- A count-based oracle can identify the selected value without executing sort.
theorem rank_eq_of_counts (values : List Nat) (divisor value : Nat) (proper : 1 < divisor)
    (supported : values.length / divisor < values.countP (fun v => decide (value ≤ v)))
    (rejected : values.countP (fun v => decide (value + 1 ≤ v)) ≤ values.length / divisor) :
    rank values divisor = some value := by
  have nonempty : values ≠ [] := by
    intro empty
    simp [empty] at supported
  obtain ⟨result, selected⟩ := rank_exists values divisor proper nonempty
  have lower := (rank_threshold values divisor result proper selected value).mpr supported
  have upper := rank_threshold values divisor result proper selected (value + 1)
  have same : result = value := by omega
  simpa only [same] using selected

-- These bounds justify the quotient increment and subtraction on a nonempty
-- initialized prefix. They do not assert that a Rust buffer has this prefix.
theorem rank_arithmetic_bounds (count divisor bound : Nat) (positive : 0 < count)
    (proper : 1 < divisor) (representable : count < bound) :
    count / divisor + 1 ≤ count ∧ count / divisor + 1 < bound ∧
      rankOffset count divisor < count := by
  have division := Nat.div_lt_self positive proper
  exact ⟨Nat.succ_le_of_lt division,
    Nat.lt_of_le_of_lt (Nat.succ_le_of_lt division) representable,
    Nat.sub_lt positive (Nat.succ_pos _)⟩

-- On an empty prefix, unchecked subtraction produces the maximum word, not
-- zero. This index is outside any buffer whose length fits in that word.
theorem empty_wrapping_index (bits : Nat) :
    wrappingRankOffset bits 0 2 = 2^bits - 1 := by
  have positive : 0 < 2^bits := Nat.two_pow_pos bits
  simp only [wrappingRankOffset, Nat.zero_div, Nat.zero_add]
  exact Nat.mod_eq_of_lt (Nat.sub_lt positive (by decide))

theorem empty_wrapping_out_of_bounds (bits capacity : Nat) (bounded : capacity < 2^bits) :
    capacity ≤ wrappingRankOffset bits 0 2 := by
  rw [empty_wrapping_index]
  omega

end Provium.OrderStatistics
