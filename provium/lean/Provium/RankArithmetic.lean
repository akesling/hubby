import Provium.Semantics
import Provium.OrderStatistics

namespace Provium.RankArithmetic

-- Typed operations for count - (count / divisor + 1), retaining validation
-- of each word and the selected arithmetic overflow profile.
def offset (bits count divisor : Nat) (checked : Bool) : Result :=
  bind (binary .div (.uint bits count) (.uint bits divisor)) fun quotient =>
    bind (binary (if checked then .add else .wrappingAdd) quotient (.uint bits 1)) fun amount =>
      binary (if checked then .sub else .wrappingSub) (.uint bits count) amount

theorem nonempty_offset (bits count divisor : Nat) (checked : Bool)
    (width : validWidth bits = true) (positive : 0 < count) (proper : 1 < divisor)
    (count_fits : count < 2^bits) (divisor_fits : divisor < 2^bits) :
    offset bits count divisor checked = .ok (.uint bits (OrderStatistics.rankOffset count divisor)) := by
  have quotient_fits : count / divisor < 2^bits := Nat.lt_trans (Nat.div_lt_self positive proper) count_fits
  obtain ⟨amount_le, amount_fits, index_lt⟩ := OrderStatistics.rank_arithmetic_bounds count divisor (2^bits) positive proper count_fits
  have one_fits : 1 < 2^bits := Nat.lt_trans proper divisor_fits
  have index_fits : count - (count / divisor + 1) < 2^bits := Nat.lt_trans index_lt count_fits
  have nonzero : divisor ≠ 0 := by omega
  have no_underflow : ¬count < count / divisor + 1 := Nat.not_lt.mpr amount_le
  have wrapping : (count + 2^bits - (count / divisor + 1)) % 2^bits = count - (count / divisor + 1) := by
    have rearrange : count + 2^bits - (count / divisor + 1) = (count - (count / divisor + 1)) + 2^bits := by omega
    rw [rearrange, Nat.add_mod]
    simp [Nat.mod_eq_of_lt index_fits]
  cases checked <;> simp [offset, binary, uintOp, word, bind, width, count_fits, divisor_fits,
    quotient_fits, one_fits, amount_fits, index_fits, nonzero, no_underflow,
    Nat.mod_eq_of_lt amount_fits, wrapping, OrderStatistics.rankOffset]

theorem empty_offset (bits divisor : Nat) (width : validWidth bits = true)
    (proper : 1 < divisor) (divisor_fits : divisor < 2^bits) :
    offset bits 0 divisor true = .error .overflow ∧
      offset bits 0 divisor false = .ok (.uint bits (2^bits - 1)) := by
  have zero_fits : 0 < 2^bits := Nat.two_pow_pos bits
  have one_fits : 1 < 2^bits := Nat.lt_trans proper divisor_fits
  have nonzero : divisor ≠ 0 := by omega
  have maximum_fits : 2^bits - 1 < 2^bits := Nat.sub_lt zero_fits (by decide)
  simp [offset, binary, uintOp, word, bind, width, zero_fits, one_fits,
    divisor_fits, nonzero, Nat.mod_eq_of_lt one_fits, Nat.mod_eq_of_lt maximum_fits, maximum_fits]

def increment (bits count : Nat) (checked : Bool) : Result :=
  binary (if checked then .add else .wrappingAdd) (.uint bits count) (.uint bits 1)

theorem increment_within_capacity (bits count capacity : Nat) (checked : Bool)
    (width : validWidth bits = true) (within : count < capacity) (capacity_fits : capacity < 2^bits) :
    increment bits count checked = .ok (.uint bits (count + 1)) := by
  have count_fits : count < 2^bits := Nat.lt_trans within capacity_fits
  have result_fits : count + 1 < 2^bits := Nat.lt_of_le_of_lt (Nat.succ_le_of_lt within) capacity_fits
  have one_fits : 1 < 2^bits := by omega
  cases checked <;> simp [increment, binary, uintOp, word, width, count_fits,
    one_fits, result_fits, Nat.mod_eq_of_lt result_fits]

theorem empty_wrapping_not_index (bits divisor capacity : Nat) (width : validWidth bits = true)
    (proper : 1 < divisor) (divisor_fits : divisor < 2^bits) (capacity_fits : capacity < 2^bits) :
    offset bits 0 divisor false = .ok (.uint bits (2^bits - 1)) ∧ ¬ (2^bits - 1 < capacity) := by
  exact ⟨(empty_offset bits divisor width proper divisor_fits).2, by omega⟩

def select (buffer : List α) (bits count divisor : Nat) (checked : Bool) : Except Fault α :=
  match offset bits count divisor checked with
  | .error fault => .error fault
  | .ok (.boolean _) => .error .typeMismatch
  | .ok (.uint _ index) => match buffer[index]? with
    | none => .error .input
    | some value => .ok value

theorem select_nonempty (buffer : List α) (bits count divisor : Nat) (checked : Bool)
    (width : validWidth bits = true) (positive : 0 < count) (proper : 1 < divisor)
    (count_fits : count < 2^bits) (divisor_fits : divisor < 2^bits) :
    (select buffer bits count divisor checked).toOption = buffer[OrderStatistics.rankOffset count divisor]? := by
  unfold select
  rw [nonempty_offset bits count divisor checked width positive proper count_fits divisor_fits]
  dsimp only
  cases buffer[OrderStatistics.rankOffset count divisor]? <;> rfl

theorem select_empty (buffer : List α) (bits divisor : Nat) (checked : Bool)
    (width : validWidth bits = true) (proper : 1 < divisor)
    (divisor_fits : divisor < 2^bits) (capacity_fits : buffer.length < 2^bits) :
    select buffer bits 0 divisor checked = .error (if checked then .overflow else .input) := by
  have missing : buffer[2^bits - 1]? = none := List.getElem?_eq_none (by omega)
  cases checked
  · simp only [select, (empty_offset bits divisor width proper divisor_fits).2, missing]
    rfl
  · simp only [select, (empty_offset bits divisor width proper divisor_fits).1]
    rfl

end Provium.RankArithmetic
