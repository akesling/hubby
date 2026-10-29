import Refine
open Provium.State Provium.Imperative
set_option linter.unusedSimpArgs false
namespace Refine

def readyv (n : Fields) : PureValue := .record "Ready" [("node", n.value)]

/-- `Ready::persisted` clears the dirty flag and the pending log and snapshot marks. -/
theorem persisted_spec (target : Target) (n : Fields) {fuel : Nat} {v r : PureValue}
    (h : Jarl.ready_Ready_persisted target fuel (readyv n) [] = .ok (v, r)) :
    r = readyv { n with dirty := .boolean false, log_from := .absent,
                        snapshot_changed := .boolean false } := by
  simp only [Jarl.ready_Ready_persisted] at h
  refine run_of_wp (m := machine target) (P := fun _ r => r = readyv
    { n with dirty := .boolean false, log_from := .absent, snapshot_changed := .boolean false }) ?_ h
  simp only [Jarl.ready_Ready_persisted_ir, frameOf, List.zipIdx, List.foldl]
  wp_walk [readyv, Fields.value]
  wp_receiver
  rfl

end Refine
