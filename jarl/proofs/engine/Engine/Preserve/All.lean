import Engine.Api
import Engine.Preserve.Local
import Engine.Preserve.Send
import Engine.Preserve.Persist
import Engine.Preserve.Tick
import Engine.Preserve.Deliver

/-! Every cluster step preserves the invariant, extending the ghost history. -/

namespace Jarl.Engine
open Jarl

variable {V S : Type} {N CAP : Nat} [Rust.Clone V] [Rust.Clone S]

theorem preserve [Rust.LawfulClone V] [Rust.LawfulClone S] (ids : Vector Id N) (cfg : Fin N → Config N) (C C' : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (ha : Act cfg C C') : ∃ G', Extends G G' ∧ Inv ids cfg C' G' := by
  cases ha with
  | tick k r n h => exact preserve_tick ids cfg C G hi k r n h
  | deliver k env r n hm h => exact preserve_deliver ids cfg C G hi k env r n hm h
  | propose k v r n h =>
    obtain ⟨r', h'⟩ := propose_wrap _ v r n h
    refine ⟨G, Extends.refl G, preserve_propose ids cfg C G hi k [v] [Rust.Clone.clone v] rfl ?_ 1 (by simp) r' n h'⟩
    intro i hi'; obtain rfl : i = 0 := by simpa using hi'
    exact Rust.faithful_clone v
  | proposeBatch k vs r n hs h =>
    exact ⟨G, Extends.refl G, preserve_propose ids cfg C G hi k vs.toList (vs.toList.map Rust.Clone.clone)
      (List.length_map _) (fun i _ => by simpa only [List.getElem_map] using Rust.faithful_clone _)
      (Rust.usizeOf vs.size) (by simp [Rust.val_usizeOf _ hs]) r n (propose_batch_wrap _ vs r n h)⟩
  | compact k index v r n h =>
    exact ⟨G, Extends.refl G, preserve_compact ids cfg C G hi k index _ r n (compact_wrap _ index v r n h)⟩
  | persist k ready h => exact preserve_persist ids cfg C G hi k ready h
  | send k env n h => exact preserve_send ids cfg C G hi k env n h
  | drain k n h => exact ⟨G, Extends.refl G, preserve_drain ids cfg C G hi k n h⟩
  | restart k n h => exact ⟨G, Extends.refl G, preserve_restart ids cfg C G hi k n h⟩

end Jarl.Engine
