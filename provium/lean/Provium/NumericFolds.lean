import Provium.State
import Provium.OrderStatistics

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

def runNumericFold (program : NumericFold) (entries : ArrayStore α) (callback : σ)
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

end Provium.State
