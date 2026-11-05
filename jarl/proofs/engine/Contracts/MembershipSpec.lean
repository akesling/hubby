import Contracts.MembershipPass

/-!
# Membership contracts: the translated constructors as pure specifications

`restore`, `new`, `with_learners` and `joint` always return (for `usize`-sized
inputs) and equal the pure specifications below, built from `pass`.
-/

namespace Jarl.Contracts.Membership
open Jarl

variable {MAX : Nat}

def withLearnersSpec (m : Jarl.Membership MAX) (learners : Array Id) : Rust.Result (Jarl.Membership MAX) Error :=
  match pass false (fun _ => false) 0 [] m.voters (empty MAX) with
  | .error _ => .Err .Config
  | .ok a =>
    match pass true (fun x => m.is_voter x) 1 [] learners.toList a with
    | .error _ => .Err .Config
    | .ok b => .Ok b

def jointSpec (source target : Jarl.Membership MAX) : Rust.Result (Jarl.Membership MAX) Error :=
  if (source.is_joint || target.is_joint) = true then .Err .Reconfiguring else
  match pass false (fun _ => false) 2 [] source.voters target with
  | .error _ => .Err .Full
  | .ok r => .Ok r

theorem rangeA_prefix (set : Array Id) (j : Nat) (hj : j < set.size) (hs : set.size < 2 ^ Rust.usizeBits) :
    Rust.Slice.rangeA set 0 (Rust.ofNat j) = pure (set.extract 0 j) := by
  have hv : (Rust.ofNat j : Rust.usize).val = j := by simp [Rust.ofNat] at hs ⊢; omega
  simp [Rust.Slice.rangeA, hv]; omega

theorem extract_prefix (set : Array Id) (j : Nat) : (set.extract 0 j).toList = set.toList.take j := by
  simp [Array.toList_extract, List.extract_eq_take_drop]

theorem with_learners_eq (m : Jarl.Membership MAX) (learners : Array Id) (hMAX : MAX < 2 ^ Rust.usizeBits)
    (hl : learners.size < 2 ^ Rust.usizeBits) : m.with_learners learners = pure (withLearnersSpec m learners) := by
  unfold Jarl.Membership.with_learners withLearnersSpec
  dsimp only
  rw [forIn_list m.voters 0 (Rust.Result.Err Error.Config) _ ?h1 [] _]
  case h1 =>
    intro x _ n
    simp only [include_eq _ _ _ hMAX, pure_bind]
    cases incSpec n x 0 <;> rfl
  rw [show ({ members := Vector.replicate MAX none } : Jarl.Membership MAX) = empty MAX from rfl]
  simp only [pure_bind]
  cases h1 : pass false (fun _ => false) 0 [] m.voters (empty MAX) with
  | error a => simp [out]
  | ok a =>
    simp only [out]
    rw [forIn_enum learners.toList true (fun x => m.is_voter x) 1 (Rust.Result.Err Error.Config) _ ?h2]
    case h2 =>
      intro j hj n
      have hx : learners.toList[j] = learners[j]'(by simpa using hj) := by simp
      rw [hx]
      by_cases c' : m.is_voter learners[j] = true
      · simp [stepOk, c']
      · simp only [c', Bool.not_false, if_true, rangeA_prefix learners j (by simpa using hj) hl, pure_bind,
          extract_prefix, include_eq _ _ _ hMAX]
        by_cases c : learners[j] ∈ learners.toList.take j
        · simp [stepOk, c, c']
        · cases hi : incSpec n learners[j] 1 <;> simp [stepOk, c, c', hi]
    cases h2 : pass true (fun x => m.is_voter x) 1 [] learners.toList a with
    | error b => simp [out]
    | ok b => simp [out]

theorem joint_eq (source target : Jarl.Membership MAX) (hMAX : MAX < 2 ^ Rust.usizeBits) :
    source.joint target = pure (jointSpec source target) := by
  unfold Jarl.Membership.joint jointSpec
  by_cases g : (source.is_joint || target.is_joint) = true
  · simp [g]
  · simp only [g, if_false, Bool.false_eq_true]
    rw [forIn_list source.voters 2 (Rust.Result.Err Error.Full) _ ?h1 [] _]
    case h1 =>
      intro x _ n
      simp only [include_eq _ _ _ hMAX, pure_bind]
      cases incSpec n x 2 <;> rfl
    simp only [pure_bind]
    cases h1 : pass false (fun _ => false) 2 [] source.voters target with
    | error a => simp [out]
    | ok a => simp [out]

def restoreSpec (voters old learners : Array Id) : Rust.Result (Jarl.Membership MAX) Error :=
  if voters.isEmpty then .Err .Config else
  match pass true (fun _ => false) 0 [] voters.toList (empty MAX) with
  | .error _ => .Err .Config
  | .ok a =>
    match pass true (fun x => voters.toList.contains x) 1 [] learners.toList a with
    | .error _ => .Err .Config
    | .ok b =>
      match pass true (fun _ => false) 2 [] old.toList b with
      | .error _ => .Err .Config
      | .ok c => .Ok c

theorem restore_eq (voters old learners : Array Id) (hMAX : MAX < 2 ^ Rust.usizeBits) (hv : voters.size < 2 ^ Rust.usizeBits)
    (ho : old.size < 2 ^ Rust.usizeBits) (hl : learners.size < 2 ^ Rust.usizeBits) :
    Jarl.Membership.restore (MAX := MAX) voters old learners = pure (restoreSpec voters old learners) := by
  unfold Jarl.Membership.restore restoreSpec
  by_cases he : voters.isEmpty = true
  · simp [he]
  · simp only [he, if_false, Bool.false_eq_true]
    simp only [Vector.toList_mk, List.forIn_cons, List.forIn_nil]
    rw [forIn_enum voters.toList true (fun _ => false) 0 (Rust.Result.Err Error.Config) _ ?h1]
    case h1 =>
      intro j hj m
      simp only [rangeA_prefix voters j (by simpa using hj) hv, pure_bind, extract_prefix, include_eq _ _ _ hMAX]
      have hx : voters.toList[j] = voters[j]'(by simpa using hj) := by simp
      rw [hx]
      by_cases c : voters[j] ∈ voters.toList.take j
      · simp [stepOk, c]
      · cases hi : incSpec m voters[j] 0 <;> simp [stepOk, c, hi]
    rw [show ({ members := Vector.replicate MAX none } : Jarl.Membership MAX) = empty MAX from rfl]
    cases h1 : pass true (fun _ => false) 0 [] voters.toList (empty MAX) with
    | error a => simp [out]
    | ok a =>
      simp only [out, pure_bind]
      rw [forIn_enum learners.toList true (fun x => voters.toList.contains x) 1 (Rust.Result.Err Error.Config) _ ?h2]
      case h2 =>
        intro j hj m
        simp only [rangeA_prefix learners j (by simpa using hj) hl, pure_bind, extract_prefix, include_eq _ _ _ hMAX]
        have hx : learners.toList[j] = learners[j]'(by simpa using hj) := by simp
        rw [hx]
        by_cases c : learners[j] ∈ learners.toList.take j
        · simp [stepOk, c]
        · by_cases c' : learners[j] ∈ voters.toList
          · simp [stepOk, c, c']
          · cases hi : incSpec m learners[j] 1 <;> simp [stepOk, c, c', hi]
      cases h2 : pass true (fun x => voters.toList.contains x) 1 [] learners.toList a with
      | error b => simp [out]
      | ok b =>
        simp only [out, pure_bind]
        rw [forIn_enum old.toList true (fun _ => false) 2 (Rust.Result.Err Error.Config) _ ?h3]
        case h3 =>
          intro j hj m
          simp only [rangeA_prefix old j (by simpa using hj) ho, pure_bind, extract_prefix, include_eq _ _ _ hMAX]
          have hx : old.toList[j] = old[j]'(by simpa using hj) := by simp
          rw [hx]
          by_cases c : old[j] ∈ old.toList.take j
          · simp [stepOk, c]
          · cases hi : incSpec m old[j] 2 <;> simp [stepOk, c, hi]
        cases h3 : pass true (fun _ => false) 2 [] old.toList b with
        | error c => simp [out]
        | ok c => simp [out]

theorem new_eq (voters learners : Array Id) :
    Jarl.Membership.new (MAX := MAX) voters learners = Jarl.Membership.restore voters #[] learners := by
  unfold Jarl.Membership.new
  simp

end Jarl.Contracts.Membership
