import Engine.Host.Delta

/-!
# The host adapters `persist` and `persist_async`

`host.rs` saves a `Ready`'s transaction through a consumer storage and
acknowledges it only after the save succeeds. The storage is consumer code,
so its contract is an assumption, stated against a durable view `dur` of the
storage (`StorageOk`, `AsyncStorageOk`, as documented in `host.rs`):

* a successful save has made the whole transaction durable;
* a failed save, or a cancelled asynchronous one (its future dropped), applied
  the transaction in full or not at all, and never applies it later.

Under that contract, from their generated bodies, every run of `persist` and of
`persist_async` (for any number of completed awaits before a drop, the
translation's await budget) ends in one of three ways
(`persist_outcome`, `persist_async_outcome`): acknowledged with the write
durable; unacknowledged with the write durable; or unacknowledged with the
record unchanged. These are exactly the host steps of the refinement (`persist`,
an unacknowledged `save`, or no step), so the safety theorems hold for hosts that
persist through either adapter.
-/

namespace Jarl.Engine.Host
open Jarl Jarl.Engine Jarl.Contracts.StorageView

variable {V S B : Type} {N CAP : Nat}

/-- A synchronous storage meeting the host contract, observed through `dur`. -/
structure StorageOk [Storage V S B] (dur : B → Durable V S) : Prop where
  ok : ∀ st w st', Storage.save st w = pure (.Ok (), st') → dur st' = applyWrite (dur st) w
  err : ∀ st w e st', Storage.save st w = pure (.Err e, st') →
    dur st' = dur st ∨ dur st' = applyWrite (dur st) w

/-- An asynchronous storage meeting the host contract, observed through `dur`:
    a dropped save (`save_dropped`) is all or nothing too. -/
structure AsyncStorageOk [AsyncStorage V S B] (dur : B → Durable V S) : Prop where
  ok : ∀ st w st', AsyncStorage.save st w = pure (.Ok (), st') → dur st' = applyWrite (dur st) w
  err : ∀ st w e st', AsyncStorage.save st w = pure (.Err e, st') →
    dur st' = dur st ∨ dur st' = applyWrite (dur st) w
  dropped : ∀ st w, dur (AsyncStorage.save_dropped st w) = dur st ∨
    dur (AsyncStorage.save_dropped st w) = applyWrite (dur st) w

/-- How a save through an adapter ends, for the token `ready` whose write is `w`. -/
def Saved (dur : B → Durable V S) (ready ready' : Ready V S N CAP) (st st' : B) (w : Jarl.Write V S) (acked : Bool) : Prop :=
  (acked = true ∧ ready' = Ready.persisted ready ∧ dur st' = applyWrite (dur st) w) ∨
  (acked = false ∧ ready' = ready ∧ (dur st' = dur st ∨ dur st' = applyWrite (dur st) w))

theorem ready_write_eq (ready : Ready V S N CAP) :
    Ready.write ready = State.write ready.node.state ready.node.log_from ready.node.snapshot_changed := by
  unfold Ready.write; simp

/-- `persist`: acknowledged exactly when the storage reports success, after the
    write is durable; otherwise unacknowledged with the write applied in full or not at all. -/
theorem persist_outcome [Storage V S B] (dur : B → Durable V S) (hs : StorageOk dur)
    (ready : Ready V S N CAP) (st : B) (w : Jarl.Write V S)
    (hw : State.write ready.node.state ready.node.log_from ready.node.snapshot_changed = pure w)
    (r : Rust.Result Unit (Storage.Error (V := V) (S := S) (Self := B))) (ready' : Ready V S N CAP) (st' : B)
    (h : persist ready st = pure (r, ready', st')) :
    Saved dur ready ready' st st' w (r matches .Ok _) := by
  unfold persist at h
  dsimp only at h
  rw [ready_write_eq, hw, pure_bind] at h
  obtain ⟨⟨r0, st0⟩, hsave, h⟩ := Rust.bind_eq_pure h
  cases r0 with
  | Ok u =>
    cases u
    simp only at h
    cases Rust.pure_inj h
    exact Or.inl ⟨rfl, rfl, hs.ok st w st' hsave⟩
  | Err e =>
    simp only at h
    cases Rust.pure_inj h
    exact Or.inr ⟨rfl, rfl, hs.err st w e st' hsave⟩

/-- `persist_async` with any await budget: if the future completes, as `persist`;
    if it is dropped before the save completes, unacknowledged, with the write
    applied in full or not at all. -/
theorem persist_async_outcome [AsyncStorage V S B] (dur : B → Durable V S) (hs : AsyncStorageOk dur)
    (ready : Ready V S N CAP) (st : B) (budget : Nat) (w : Jarl.Write V S)
    (hw : State.write ready.node.state ready.node.log_from ready.node.snapshot_changed = pure w)
    (r : Rust.Run (Rust.Result Unit (AsyncStorage.Error (V := V) (S := S) (Self := B)))) (ready' : Ready V S N CAP)
    (st' : B) (budget' : Nat) (h : persist_async ready st budget = pure (r, ready', st', budget')) :
    Saved dur ready ready' st st' w (r matches .ready (.Ok _)) := by
  unfold persist_async at h
  dsimp only at h
  rw [ready_write_eq, hw, pure_bind] at h
  by_cases hb : budget = 0
  · simp only [hb, if_true] at h
    cases Rust.pure_inj h
    exact Or.inr ⟨rfl, rfl, hs.dropped st w⟩
  · simp only [hb, if_false] at h
    obtain ⟨⟨r0, st0⟩, hsave, h⟩ := Rust.bind_eq_pure h
    cases r0 with
    | Ok u =>
      cases u
      simp only at h
      cases Rust.pure_inj h
      exact Or.inl ⟨rfl, rfl, hs.ok st w st' hsave⟩
    | Err e =>
      simp only at h
      cases Rust.pure_inj h
      exact Or.inr ⟨rfl, rfl, hs.err st w e st' hsave⟩

end Jarl.Engine.Host
