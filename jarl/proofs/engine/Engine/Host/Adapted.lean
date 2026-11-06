import Engine.Host.Refine
import Engine.Host.Adapters

/-!
# Hosts that persist through `persist` or `persist_async`

Every run of either adapter on a node's pending `Ready`, against a storage
meeting the host contract whose durable view is the node's record, is a host
step (`HAct.persist` when acknowledged, `HAct.save` when the write became
durable without acknowledgment) or changes nothing. So the host theorems
(`host_refinement` and the safety theorems over `HReach`) cover hosts that use
the adapters, synchronously or asynchronously, with failed and cancelled saves.
-/

namespace Jarl.Engine.Host
open Jarl Jarl.Engine Jarl.Contracts.StorageView

variable {V S B : Type} {N CAP : Nat} [Rust.Clone V] [Rust.Clone S]

omit [Rust.Clone V] [Rust.Clone S] in
theorem hcluster_ext (H H' : HCluster V S N CAP) (h1 : H'.live = H.live) (h2 : H'.durable = H.durable)
    (h3 : H'.sent = H.sent) : H' = H := by
  cases H; cases H'; simp_all

/-- An adapter's outcome on node `k` is a host step or nothing. -/
theorem saved_step (cfg : Fin N → Config N) (dur : B → Durable V S) (H : HCluster V S N CAP) (k : Fin N)
    (ready : Ready V S N CAP) (hr : Node.ready (H.live k) = some ready) (st : B) (hd : H.durable k = dur st)
    (w : Jarl.Write V S) (hw : readyWrite ready = pure w) (ready' : Ready V S N CAP) (st' : B) (acked : Bool)
    (hs : Saved dur ready ready' st st' w acked) :
    H.persist k ready'.node (dur st') = H ∨ HAct cfg H (H.persist k ready'.node (dur st')) := by
  obtain ⟨rfl, -⟩ := ready_node _ ready hr
  rcases hs with ⟨-, rfl, happ⟩ | ⟨-, rfl, hd' | happ⟩
  · right
    rw [happ, ← hd]
    exact HAct.persist k _ w hr hw
  · left
    apply hcluster_ext
    · funext j; simp only [HCluster.persist]; split <;> simp_all
    · funext j; simp only [HCluster.persist]; split <;> simp_all
    · rfl
  · right
    have : H.persist k (H.live k) (dur st') =
        { H with durable := fun j => if j = k then applyWrite (H.durable k) w else H.durable j } := by
      apply hcluster_ext
      · funext j; simp only [HCluster.persist]; split <;> simp_all
      · funext j; simp only [HCluster.persist]; split <;> simp_all
      · rfl
    rw [this]
    exact HAct.save k _ w hr hw

/-- `persist` on node `k`'s pending `Ready` is a host step or nothing. -/
theorem persist_step [Storage V S B] (cfg : Fin N → Config N) (dur : B → Durable V S) (hs : StorageOk dur)
    (H : HCluster V S N CAP) (k : Fin N) (ready : Ready V S N CAP) (hr : Node.ready (H.live k) = some ready)
    (st : B) (hd : H.durable k = dur st) (w : Jarl.Write V S) (hw : readyWrite ready = pure w)
    (r : Rust.Result Unit (Storage.Error (V := V) (S := S) (Self := B))) (ready' : Ready V S N CAP) (st' : B)
    (h : persist ready st = pure (r, ready', st')) :
    H.persist k ready'.node (dur st') = H ∨ HAct cfg H (H.persist k ready'.node (dur st')) :=
  saved_step cfg dur H k ready hr st hd w hw ready' st' _ (persist_outcome dur hs ready st w hw r ready' st' h)

/-- `persist_async` on node `k`'s pending `Ready`, run to completion or dropped
    after any number of awaits, is a host step or nothing. -/
theorem persist_async_step [AsyncStorage V S B] (cfg : Fin N → Config N) (dur : B → Durable V S)
    (hs : AsyncStorageOk dur) (H : HCluster V S N CAP) (k : Fin N) (ready : Ready V S N CAP)
    (hr : Node.ready (H.live k) = some ready) (st : B) (hd : H.durable k = dur st) (budget : Nat)
    (w : Jarl.Write V S) (hw : readyWrite ready = pure w)
    (r : Rust.Run (Rust.Result Unit (AsyncStorage.Error (V := V) (S := S) (Self := B)))) (ready' : Ready V S N CAP)
    (st' : B) (budget' : Nat) (h : persist_async ready st budget = pure (r, ready', st', budget')) :
    H.persist k ready'.node (dur st') = H ∨ HAct cfg H (H.persist k ready'.node (dur st')) :=
  saved_step cfg dur H k ready hr st hd w hw ready' st' _
    (persist_async_outcome dur hs ready st budget w hw r ready' st' budget' h)

end Jarl.Engine.Host
