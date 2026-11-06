import Engine.Dyn.Host.Refine
import Engine.Host.Adapters

/-!
# Dynamic hosts that persist through `persist` or `persist_async`

As for the fixed engine (`Engine/Host/Adapted.lean`): every run of either
adapter on a dynamic node's pending `Ready`, against a storage meeting the host
contract, is a host step (`persist` or `save`) or changes nothing, so the
dynamic host theorems cover hosts that use the adapters.
-/

namespace Jarl.Engine.DynHost
open Jarl Jarl.Engine Jarl.Engine.Host Jarl.Engine.Dyn Jarl.Contracts.StorageView

variable {V S B : Type} {MAX CAP K : Nat} [Rust.Clone V] [Rust.Clone S]

omit [Rust.Clone V] [Rust.Clone S] in
theorem hworld_ext (H H' : HWorld V S MAX CAP K) (h1 : H'.live = H.live) (h2 : H'.durable = H.durable)
    (h3 : H'.sent = H.sent) : H' = H := by
  cases H; cases H'; simp_all

/-- An adapter's outcome on node `k` is a host step or nothing. -/
theorem saved_dstep (ids : Vector Id K) (g : Membership MAX) (dur : B → Durable (Record V MAX) (Checkpoint S MAX))
    (H : HWorld V S MAX CAP K) (k : Fin K) (ready : Ready (Record V MAX) (Checkpoint S MAX) MAX CAP)
    (hr : Cluster.ready (H.live k) = some ready) (st : B) (hd : H.durable k = dur st)
    (w : Jarl.Write (Record V MAX) (Checkpoint S MAX)) (hw : readyWrite ready = pure w)
    (ready' : Ready (Record V MAX) (Checkpoint S MAX) MAX CAP) (st' : B) (acked : Bool)
    (hs : Saved dur ready ready' st st' w acked) :
    H.persist k { node := ready'.node } (dur st') = H ∨ DHAct ids g H (H.persist k { node := ready'.node } (dur st')) := by
  have hr' : Node.ready (H.live k).node = some ready := hr
  obtain ⟨rfl, -⟩ := ready_node _ ready hr'
  have heta : ({ node := (H.live k).node } : Jarl.Cluster V S MAX CAP) = H.live k := by cases H.live k; rfl
  rcases hs with ⟨-, rfl, happ⟩ | ⟨-, rfl, hd' | happ⟩
  · right
    rw [happ, ← hd]
    exact DHAct.persist k _ w hr hw
  · left
    apply hworld_ext
    · funext j; simp only [HWorld.persist]; split <;> simp_all
    · funext j; simp only [HWorld.persist]; split <;> simp_all
    · rfl
  · right
    have : H.persist k { node := (H.live k).node } (dur st') = H.save k (applyWrite (H.durable k) w) := by
      apply hworld_ext
      · funext j; simp only [HWorld.persist, HWorld.save]; split <;> simp_all
      · funext j; simp only [HWorld.persist, HWorld.save]; split <;> simp_all
      · rfl
    rw [this]
    exact DHAct.save k _ w hr hw

theorem persist_dstep [Storage (Record V MAX) (Checkpoint S MAX) B] (ids : Vector Id K) (g : Membership MAX)
    (dur : B → Durable (Record V MAX) (Checkpoint S MAX)) (hs : StorageOk dur) (H : HWorld V S MAX CAP K) (k : Fin K)
    (ready : Ready (Record V MAX) (Checkpoint S MAX) MAX CAP) (hr : Cluster.ready (H.live k) = some ready) (st : B)
    (hd : H.durable k = dur st) (w : Jarl.Write (Record V MAX) (Checkpoint S MAX)) (hw : readyWrite ready = pure w)
    (r : Rust.Result Unit (Storage.Error (V := Record V MAX) (S := Checkpoint S MAX) (Self := B)))
    (ready' : Ready (Record V MAX) (Checkpoint S MAX) MAX CAP) (st' : B) (h : persist ready st = pure (r, ready', st')) :
    H.persist k { node := ready'.node } (dur st') = H ∨ DHAct ids g H (H.persist k { node := ready'.node } (dur st')) :=
  saved_dstep ids g dur H k ready hr st hd w hw ready' st' _ (persist_outcome dur hs ready st w hw r ready' st' h)

theorem persist_async_dstep [AsyncStorage (Record V MAX) (Checkpoint S MAX) B] (ids : Vector Id K) (g : Membership MAX)
    (dur : B → Durable (Record V MAX) (Checkpoint S MAX)) (hs : AsyncStorageOk dur) (H : HWorld V S MAX CAP K) (k : Fin K)
    (ready : Ready (Record V MAX) (Checkpoint S MAX) MAX CAP) (hr : Cluster.ready (H.live k) = some ready) (st : B)
    (hd : H.durable k = dur st) (budget : Nat) (w : Jarl.Write (Record V MAX) (Checkpoint S MAX)) (hw : readyWrite ready = pure w)
    (r : Rust.Run (Rust.Result Unit (AsyncStorage.Error (V := Record V MAX) (S := Checkpoint S MAX) (Self := B))))
    (ready' : Ready (Record V MAX) (Checkpoint S MAX) MAX CAP) (st' : B) (budget' : Nat)
    (h : persist_async ready st budget = pure (r, ready', st', budget')) :
    H.persist k { node := ready'.node } (dur st') = H ∨ DHAct ids g H (H.persist k { node := ready'.node } (dur st')) :=
  saved_dstep ids g dur H k ready hr st hd w hw ready' st' _
    (persist_async_outcome dur hs ready st budget w hw r ready' st' budget' h)

end Jarl.Engine.DynHost
