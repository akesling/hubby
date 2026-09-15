import Generated
set_option maxRecDepth 4096
open Provium
namespace Election

private theorem xor_shift_bound (x shift : Nat) (h : x < 2^64) :
    (x ^^^ (x / 2^shift)) < 2^64 :=
  Nat.xor_lt_two_pow h (Nat.lt_of_le_of_lt (Nat.div_le_self _ _) h)

-- Mathematical names for intermediate values, used only to state and discharge
-- the computation of the generated complete-body projections below.
private def advanced (random : Nat) := (random + 11400714819323198485) % 2^64
private def first (random : Nat) :=
  ((advanced random ^^^ (advanced random / 2^30)) * 13787848793156543929) % 2^64
private def second (random : Nat) :=
  ((first random ^^^ (first random / 2^27)) * 10723151780598845931) % 2^64
private def sample (random : Nat) := (second random ^^^ (second random / 2^31))

private theorem wrap_add64 (a b : Nat) (ha : a < 2^64) (hb : b < 2^64) :
    binary .wrappingAdd (.uint 64 a) (.uint 64 b) = .ok (.uint 64 ((a+b)%2^64)) := by
  simp [binary, uintOp, word, validWidth, ha, hb, Nat.mod_lt _ (by decide : 0 < 2^64)]

private theorem wrap_mul64 (a b : Nat) (ha : a < 2^64) (hb : b < 2^64) :
    binary .wrappingMul (.uint 64 a) (.uint 64 b) = .ok (.uint 64 ((a*b)%2^64)) := by
  simp [binary, uintOp, word, validWidth, ha, hb, Nat.mod_lt _ (by decide : 0 < 2^64)]

private theorem shift64 (a b : Nat) (ha : a < 2^64) (hb : b < 64) :
    binary .shr (.uint 64 a) (.uint 64 b) = .ok (.uint 64 (a/2^b)) := by
  have hbb : b < 2^64 := by omega
  have had : a/2^b < 2^64 := Nat.lt_of_le_of_lt (Nat.div_le_self _ _) ha
  simp [binary, uintOp, word, validWidth, ha, hb, hbb, had]

private theorem xor64 (a b : Nat) (ha : a < 2^64) (hb : b < 2^64) :
    binary .bitXor (.uint 64 a) (.uint 64 b) = .ok (.uint 64 (a ^^^ b)) := by
  have hx := Nat.xor_lt_two_pow ha hb
  simp [binary, uintOp, word, validWidth, ha, hb, hx]

private theorem rem64 (a b : Nat) (ha : a < 2^64) (hb : b < 2^64) (positive : 0 < b) :
    binary .rem (.uint 64 a) (.uint 64 b) = .ok (.uint 64 (a%b)) := by
  have hm : a%b < 2^64 := Nat.lt_trans (Nat.mod_lt _ positive) hb
  simp [binary, uintOp, word, validWidth, ha, hb, hm, Nat.ne_of_gt positive]

private theorem add64 (a b : Nat) (h : a+b < 2^64) :
    binary .add (.uint 64 a) (.uint 64 b) = .ok (.uint 64 (a+b)) := by
  have ha : a < 2^64 := by omega
  have hb : b < 2^64 := by omega
  simp [binary, uintOp, word, validWidth, ha, hb, h]

private theorem constant64 (n : Nat) (h : n < 2^64) : word 64 n = .ok (.uint 64 n) := by
  simp [word, validWidth, h]

private theorem execute_success (ticks elapsed deadline random a b c d : Nat)
    (valid : validArgs [.uint 64, .uint 64, .uint 64, .uint 64]
      [.uint 64 ticks, .uint 64 elapsed, .uint 64 deadline, .uint 64 random] = true)
    (eadd : binary .wrappingAdd (.uint 64 random) (.uint 64 11400714819323198485) = .ok (.uint 64 (a)))
    (eshift1 : binary .shr (.uint 64 (a)) (.uint 64 30) = .ok (.uint 64 (a / 2^30)))
    (exor1 : binary .bitXor (.uint 64 (a)) (.uint 64 (a / 2^30)) = .ok (.uint 64 ((a ^^^ (a / 2^30)))))
    (emul1 : binary .wrappingMul (.uint 64 ((a ^^^ (a / 2^30)))) (.uint 64 13787848793156543929) = .ok (.uint 64 (b)))
    (eshift2 : binary .shr (.uint 64 (b)) (.uint 64 27) = .ok (.uint 64 (b / 2^27)))
    (exor2 : binary .bitXor (.uint 64 (b)) (.uint 64 (b / 2^27)) = .ok (.uint 64 ((b ^^^ (b / 2^27)))))
    (emul2 : binary .wrappingMul (.uint 64 ((b ^^^ (b / 2^27)))) (.uint 64 10723151780598845931) = .ok (.uint 64 (c)))
    (eshift3 : binary .shr (.uint 64 (c)) (.uint 64 31) = .ok (.uint 64 (c / 2^31)))
    (exor3 : binary .bitXor (.uint 64 (c)) (.uint 64 (c / 2^31)) = .ok (.uint 64 (d)))
    (erem : binary .rem (.uint 64 (d)) (.uint 64 ticks) = .ok (.uint 64 (d % ticks)))
    (esum : binary .add (.uint 64 ticks) (.uint 64 (d % ticks)) = .ok (.uint 64 (ticks + d % ticks))) :
    JarlElection.node_Node_reset_election_random [.uint 64 ticks, .uint 64 elapsed, .uint 64 deadline, .uint 64 random] = .ok (.uint 64 (a)) ∧
    JarlElection.node_Node_reset_election_election_deadline [.uint 64 ticks, .uint 64 elapsed, .uint 64 deadline, .uint 64 random] = .ok (.uint 64 (ticks + d % ticks)) ∧
    JarlElection.node_Node_reset_election_elapsed [.uint 64 ticks, .uint 64 elapsed, .uint 64 deadline, .uint 64 random] = .ok (.uint 64 0) := by
  unfold JarlElection.node_Node_reset_election_random
    JarlElection.node_Node_reset_election_election_deadline
    JarlElection.node_Node_reset_election_elapsed
  simp only [valid, ite_true]
  dsimp only [Provium.get, Provium.bind, List.getElem?_cons_zero, List.getElem?_cons_succ]
  simp only [constant64 _ (by decide : 11400714819323198485 < 2^64),
    constant64 _ (by decide : 13787848793156543929 < 2^64),
    constant64 _ (by decide : 10723151780598845931 < 2^64),
    constant64 _ (by decide : 30 < 2^64), constant64 _ (by decide : 27 < 2^64),
    constant64 _ (by decide : 31 < 2^64), constant64 _ (by decide : 0 < 2^64)]
  simp only [eadd, eshift1, exor1, emul1, eshift2, exor2, emul2, eshift3, exor3, erem, esum]
  exact ⟨True.intro, True.intro, True.intro⟩

private theorem computation (ticks elapsed deadline random : Nat)
    (positive : 0 < ticks) (safe : ticks ≤ 2^63)
    (he : elapsed < 2^64) (hd : deadline < 2^64) (hr : random < 2^64) :
    JarlElection.node_Node_reset_election_random [.uint 64 ticks, .uint 64 elapsed, .uint 64 deadline, .uint 64 random] = .ok (.uint 64 (advanced random)) ∧
    JarlElection.node_Node_reset_election_election_deadline [.uint 64 ticks, .uint 64 elapsed, .uint 64 deadline, .uint 64 random] = .ok (.uint 64 (ticks + sample random % ticks)) ∧
    JarlElection.node_Node_reset_election_elapsed [.uint 64 ticks, .uint 64 elapsed, .uint 64 deadline, .uint 64 random] = .ok (.uint 64 0) := by
  have ht : ticks < 2^64 := by omega
  have ha : advanced random < 2^64 := Nat.mod_lt _ (by decide)
  have hf : first random < 2^64 := Nat.mod_lt _ (by decide)
  have hs : second random < 2^64 := Nat.mod_lt _ (by decide)
  have hax := xor_shift_bound _ 30 ha
  have hfx := xor_shift_bound _ 27 hf
  have hsample : sample random < 2^64 := xor_shift_bound _ 31 hs
  have had : advanced random / 2^30 < 2^64 := Nat.lt_of_le_of_lt (Nat.div_le_self _ _) ha
  have hfd : first random / 2^27 < 2^64 := Nat.lt_of_le_of_lt (Nat.div_le_self _ _) hf
  have hsd : second random / 2^31 < 2^64 := Nat.lt_of_le_of_lt (Nat.div_le_self _ _) hs
  have hm : sample random % ticks < ticks := Nat.mod_lt _ positive
  have hsum : ticks + sample random % ticks < 2^64 := by omega
  have eadd : binary .wrappingAdd (.uint 64 random) (.uint 64 11400714819323198485) = .ok (.uint 64 (advanced random)) := by
    exact wrap_add64 _ _ hr (by decide)
  have eshift1 : binary .shr (.uint 64 (advanced random)) (.uint 64 30) = .ok (.uint 64 (advanced random / 2^30)) := by
    exact shift64 _ _ ha (by decide)
  have exor1 : binary .bitXor (.uint 64 (advanced random)) (.uint 64 (advanced random / 2^30)) = .ok (.uint 64 ((advanced random ^^^ (advanced random / 2^30)))) := by
    exact xor64 _ _ ha had
  have emul1 : binary .wrappingMul (.uint 64 ((advanced random ^^^ (advanced random / 2^30)))) (.uint 64 13787848793156543929) = .ok (.uint 64 (first random)) := by
    exact wrap_mul64 _ _ hax (by decide)
  have eshift2 : binary .shr (.uint 64 (first random)) (.uint 64 27) = .ok (.uint 64 (first random / 2^27)) := by
    exact shift64 _ _ hf (by decide)
  have exor2 : binary .bitXor (.uint 64 (first random)) (.uint 64 (first random / 2^27)) = .ok (.uint 64 ((first random ^^^ (first random / 2^27)))) := by
    exact xor64 _ _ hf hfd
  have emul2 : binary .wrappingMul (.uint 64 ((first random ^^^ (first random / 2^27)))) (.uint 64 10723151780598845931) = .ok (.uint 64 (second random)) := by
    exact wrap_mul64 _ _ hfx (by decide)
  have eshift3 : binary .shr (.uint 64 (second random)) (.uint 64 31) = .ok (.uint 64 (second random / 2^31)) := by
    exact shift64 _ _ hs (by decide)
  have exor3 : binary .bitXor (.uint 64 (second random)) (.uint 64 (second random / 2^31)) = .ok (.uint 64 (sample random)) := by
    exact xor64 _ _ hs hsd
  have erem : binary .rem (.uint 64 (sample random)) (.uint 64 ticks) = .ok (.uint 64 (sample random % ticks)) := by
    exact rem64 _ _ hsample ht positive
  have esum : binary .add (.uint 64 ticks) (.uint 64 (sample random % ticks)) = .ok (.uint 64 (ticks + sample random % ticks)) := by
    exact add64 _ _ hsum
  have valid : validArgs [.uint 64, .uint 64, .uint 64, .uint 64]
      [.uint 64 ticks, .uint 64 elapsed, .uint 64 deadline, .uint 64 random] = true := by
    simp [validArgs, validWidth, ht, he, hd, hr]
  exact execute_success ticks elapsed deadline random (advanced random) (first random) (second random) (sample random)
    valid eadd eshift1 exor1 emul1 eshift2 exor2 emul2 eshift3 exor3 erem esum

theorem elapsed_reset (ticks elapsed deadline random : Nat)
    (positive : 0 < ticks) (safe : ticks ≤ 2^63)
    (he : elapsed < 2^64) (hd : deadline < 2^64) (hr : random < 2^64) :
    JarlElection.node_Node_reset_election_elapsed
      [.uint 64 ticks, .uint 64 elapsed, .uint 64 deadline, .uint 64 random] = .ok (.uint 64 0) :=
  (computation ticks elapsed deadline random positive safe he hd hr).2.2

theorem deadline_range (ticks elapsed deadline random : Nat)
    (positive : 0 < ticks) (safe : ticks ≤ 2^63)
    (he : elapsed < 2^64) (hd : deadline < 2^64) (hr : random < 2^64) :
    ∃ next, JarlElection.node_Node_reset_election_election_deadline
      [.uint 64 ticks, .uint 64 elapsed, .uint 64 deadline, .uint 64 random] = .ok (.uint 64 next)
      ∧ ticks ≤ next ∧ next < 2*ticks ∧ next < 2^64 := by
  refine ⟨ticks + sample random % ticks, (computation ticks elapsed deadline random positive safe he hd hr).2.1, ?_⟩
  have := Nat.mod_lt (sample random) positive
  omega

theorem random_advanced (ticks elapsed deadline random : Nat)
    (positive : 0 < ticks) (safe : ticks ≤ 2^63)
    (he : elapsed < 2^64) (hd : deadline < 2^64) (hr : random < 2^64) :
    JarlElection.node_Node_reset_election_random
      [.uint 64 ticks, .uint 64 elapsed, .uint 64 deadline, .uint 64 random] =
      .ok (.uint 64 ((random + 11400714819323198485) % 2^64)) :=
  (computation ticks elapsed deadline random positive safe he hd hr).1
end Election
