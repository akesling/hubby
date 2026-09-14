import Generated
open Provium
namespace Contracts

theorem increment_safe : Ensures Assertions.increment
    (fun env => ∃ x : Nat, x < 255 ∧ env = [.uint 8 x])
    (fun env value => ∃ x : Nat, env = [.uint 8 x] ∧ value = .uint 8 (x + 1)) := by
  intro env ⟨x, hx, henv⟩
  subst env
  have bounded : x < 2^8 := by omega
  have next_bounded : x + 1 < 2^8 := by omega
  refine ⟨.uint 8 (x+1), ?_, x, rfl, rfl⟩
  simp [Assertions.increment, validArgs, validWidth, Provium.get, Provium.bind,
    binary, uintOp, word, Provium.guard, hx, bounded, next_bounded]

theorem assertion_is_a_failure :
    Assertions.increment [.uint 8 255] = .error .assertion := by rfl

theorem zero_divisor_short_circuits (x : Nat) (hx : x < 256) :
    Assertions.guarded_division [.uint 8 x, .uint 8 0] = .ok (.boolean false) := by
  simp [Assertions.guarded_division, validArgs, validWidth, Provium.get,
    Provium.bind, binary, uintOp, word, branch, hx]
end Contracts
