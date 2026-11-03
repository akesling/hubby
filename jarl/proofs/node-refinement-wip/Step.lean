import StepCase_prevote
import StepCase_prevoted
import StepCase_vote
import StepCase_voted
import StepCase_append
import StepCase_batch
import StepCase_install
import StepCase_replicated_none
import StepCase_replicated_full
import StepCase_replicated_conflict
open Provium.State Provium.Imperative
namespace Refine

/-- `step`: either the election state stays calm, or an idle node handles a
    message from another member addressed to it as `StepOut` describes. The
    stored vote is absent or a member id, as `Abs` provides. -/
theorem step_spec (target : Target) (n : Fields) (ids : List Nat) (me : Nat) (good : Good ids me n)
    (t : Nat) (vf c sn en ln : PureValue) (hs : n.state = statev (hardv t vf c) sn en ln)
    (hvf : vf = .absent ∨ ∃ x, vf = .present (idv x))
    (src dst : Nat) (m : Msg) (cap : PureValue) {fuel : Nat} {v r : PureValue}
    (h : Jarl.node_Node_step target fuel n.value [envelopev src dst m, .number "usize" ids.length, cap] =
      .ok (v, r)) :
    ∃ n', r = n'.value ∧ (Calm n n' ∨ (Idle n ∧ src ∈ ids ∧ src ≠ me ∧ dst = me ∧
      ∃ os bs, n.outbox = .array os ∧ n.votes = boolsv bs ∧ StepOut ids n t vf c sn en ln os bs src m n')) := by
  cases m with
  | prevote T last => exact step_prevote target n ids me good t vf c sn en ln hs src dst T last cap h
  | prevoted T camp g => exact step_prevoted target n ids me good t vf c sn en ln hs src dst T camp g cap h
  | vote T last => exact step_vote target n ids me good t vf c sn en ln hs hvf src dst T last cap h
  | voted T g => exact step_voted target n ids me good t vf c sn en ln hs src dst T g cap h
  | append T prev entry commit =>
    exact step_append target n ids me good t vf c sn en ln hs src dst T prev entry commit cap h
  | batch T prev entries commit =>
    exact step_batch target n ids me good t vf c sn en ln hs src dst T prev entries commit cap h
  | install T snap => exact step_install target n ids me good t vf c sn en ln hs src dst T snap cap h
  | replicated T index rej =>
    cases rej with
    | none => exact step_replicated_none target n ids me good t vf c sn en ln hs src dst T index cap h
    | full => exact step_replicated_full target n ids me good t vf c sn en ln hs src dst T index cap h
    | conflict nx =>
      exact step_replicated_conflict target n ids me good t vf c sn en ln hs src dst T index nx cap h

end Refine
