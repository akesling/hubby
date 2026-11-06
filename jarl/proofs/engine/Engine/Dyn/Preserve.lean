import Engine.Dyn.P.Persist
import Engine.Dyn.P.Send
import Engine.Dyn.P.Tick
import Engine.Dyn.P.Propose
import Engine.Dyn.P.Elect
import Engine.Dyn.P.Log

/-!
# Every step preserves the invariant

The cases are proved in `Engine/Dyn/P/*`; here they are assembled.
-/

set_option linter.unusedSectionVars false

namespace Jarl.Engine.Dyn
open Jarl Jarl.Engine

variable {V S : Type} {MAX CAP K : Nat} [Rust.Clone V] [Rust.Clone S]

theorem preserve [Rust.LawfulClone V] [Rust.LawfulClone S] (ids : Vector Id K) (g : Membership MAX)
    (hid : ∀ a b : Fin K, ids[a] = ids[b] → a = b) (hg : MemOk g)
    (C C' : World V S MAX CAP K) (G : Ghost (Record V MAX) K)
    (hi : Inv ids g C G) (ha : DAct ids g C C') : ∃ G', Extends G G' ∧ Inv ids g C' G' := by
  cases ha with
  | tick k r c h => exact preserve_tick ids g hid hg C G hi k r c h
  | deliver k env r c hs h =>
    by_cases he : ElectMsg env.message
    · exact preserve_deliver_elect ids g hid hg C G hi k env hs he r c h
    · refine preserve_deliver_log ids g hid hg C G hi k env hs ?_ r c h
      revert he; cases env.message <;> simp [ElectMsg, LogMsg]
  | propose k v r c h => exact preserve_propose ids g hid hg C G hi k v r c h
  | proposeBatch k vs r c hvs h => exact preserve_propose_batch ids g hid hg C G hi k vs hvs r c h
  | compact k index app r c h => exact preserve_compact ids g hid hg C G hi k index app r c h
  | setLearners k ls r c hl h => exact preserve_set_learners ids g hid hg C G hi k ls hl r c h
  | reconfigure k target r c ht h => exact preserve_reconfigure ids g hid hg C G hi k target ht r c h
  | finish k r c h => exact preserve_finish ids g hid hg C G hi k r c h
  | persist k ready h => exact preserve_persist ids g hid hg C G hi k ready h
  | send k env c h => exact preserve_send ids g hid hg C G hi k env c h
  | drain k c h => exact preserve_drain ids g hid hg C G hi k c h
  | restart k settings saved c h1 h2 => exact preserve_restart ids g hid hg C G hi k settings saved c h1 h2

theorem init_inv (ids : Vector Id K) (g : Membership MAX) (hid : ∀ a b : Fin K, ids[a] = ids[b] → a = b)
    (hg : MemOk g) (hMAX : MAX < 2 ^ (Rust.usizeBits - 1)) (hCAP : CAP < 2 ^ (Rust.usizeBits - 1))
    (C : World V S MAX CAP K) (h : DInitial ids g C) : Inv ids g C ⟨fun _ => none, fun _ => none, [], []⟩ :=
  init_inv' ids g hid hg hMAX hCAP C h

end Jarl.Engine.Dyn
