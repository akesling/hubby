import Engine.Host.Refine

/-! Raft safety for every reachable cluster of hosts that persist `Ready`
deltas into durable records and restart through `State::restore`.

The theorems of `Engine.Main`, restated over `HReach` and proved by
refinement: a host execution is a model execution with the same network, each
host node being the model's or saved but unacknowledged (`host_refinement`).
An unacknowledged node is dirty, so it exposes nothing, and its role and state
are the model node's. -/

namespace Jarl.Engine.Host
open Jarl Jarl.Engine Jarl.Contracts.StorageView

variable {V S : Type} {N CAP : Nat} [Rust.Clone V] [Rust.Clone S]

/-- Refinement: every reachable host cluster has a reachable model cluster with
    the same network whose checkpoints are exactly what restoring the durable
    records yields; each host node is the model node, or saved but
    unacknowledged (the model node acknowledged, its checkpoint the node's
    state); and every node's dirty tracking is correct for its durable record. -/
theorem host_refinement [Rust.LawfulClone V] [Rust.LawfulClone S] (ids : Vector Id N) (cfg : Fin N → Config N)
    (ha : Assumptions ids cfg CAP) (H : HCluster V S N CAP) (h : HReach cfg H) :
    ∃ C, Reach cfg C ∧ C.sent = H.sent ∧
      (∀ k, H.live k = C.live k ∨ Unacked (H.live k) (C.live k) (C.disk k)) ∧
      (∀ k, State.restore (H.durable k).hard (H.durable k).snapshot ((H.durable k).entries.map pure) =
        (pure (.Ok (C.disk k)) : Rust.M (Rust.Result (State V S CAP) Error))) ∧
      (∀ k, H.durable k = view (C.disk k)) ∧ ∀ k, DeltaOk (H.durable k) (H.live k) := by
  obtain ⟨C, hC, hR⟩ := refines_reach ids cfg ha H h
  exact ⟨C, hC, hR.sent.symm, fun k => (hR.node k).live, host_restore ids cfg ha H C hR hC,
    fun k => (hR.node k).durable, fun k => (hR.node k).delta⟩

omit [Rust.Clone V] [Rust.Clone S] in
/-- What a refined host node exposes, the model node exposes. -/
theorem nodeRef_exposes {h m : Node V S N CAP} {dh : Durable V S} {dm : State V S CAP} (r : NodeRef h dh m dm) :
    (∀ e, Exposes h e → Exposes m e) ∧ ∀ snap, ExposesSnapshot h snap → ExposesSnapshot m snap := by
  rcases r.live with rfl | u
  · exact ⟨fun _ he => he, fun _ hx => hx⟩
  · refine ⟨fun _ he => ?_, fun _ hx => ?_⟩
    · have := he.1; rw [u.dirty] at this; cases this
    · have := hx.1; rw [u.dirty] at this; cases this

/-- Every reachable host node's dirty tracking is correct: applying its pending
    write to its durable record yields the durable view of its live state. -/
theorem host_write_exact [Rust.LawfulClone V] [Rust.LawfulClone S] (ids : Vector Id N) (cfg : Fin N → Config N)
    (ha : Assumptions ids cfg CAP) (H : HCluster V S N CAP) (h : HReach cfg H) (k : Fin N)
    (ready : Ready V S N CAP) (hr : Node.ready (H.live k) = some ready) (w : Jarl.Write V S)
    (hw : readyWrite ready = pure w) : applyWrite (H.durable k) w = view (H.live k).state := by
  obtain ⟨C, hC, hR⟩ := refines_reach ids cfg ha H h
  obtain ⟨rfl, -⟩ := ready_node _ ready hr
  exact deltaOk_write _ _ (hR.node k).delta w hw

/-- Election safety: at most one node is leader in any term. -/
theorem host_election_safety [Rust.LawfulClone V] [Rust.LawfulClone S] (ids : Vector Id N) (cfg : Fin N → Config N)
    (ha : Assumptions ids cfg CAP) (H : HCluster V S N CAP) (h : HReach cfg H) (k k' : Fin N)
    (hk : (H.live k).role = .Leader) (hk' : (H.live k').role = .Leader)
    (ht : (H.live k).state.hard.term = (H.live k').state.hard.term) : k = k' := by
  obtain ⟨C, hC, hR⟩ := refines_reach ids cfg ha H h
  rw [← ((hR.node k).same).2] at hk
  rw [← ((hR.node k').same).2] at hk'
  rw [← ((hR.node k).same).1, ← ((hR.node k').same).1] at ht
  exact election_safety ids cfg ha C hC k k' hk hk' ht

/-- State machine safety: two entries a node exposes as committed (anywhere
    along one host execution) at the same index are equal. -/
theorem host_state_machine_safety [Rust.LawfulClone V] [Rust.LawfulClone S] (ids : Vector Id N)
    (cfg : Fin N → Config N) (ha : Assumptions ids cfg CAP) (H H' : HCluster V S N CAP) (h : HReach cfg H)
    (hs : HSteps cfg H H') (k k' : Fin N) (e e' : Entry V) (he : Exposes (H.live k) e)
    (he' : Exposes (H'.live k') e') (hidx : e.id.index = e'.id.index) : e = e' := by
  obtain ⟨C, hC, hR⟩ := refines_reach ids cfg ha H h
  obtain ⟨C', hS, hR'⟩ := refines_steps ids cfg ha H H' C hR hC hs
  exact raft_state_machine_safety ids cfg ha C C' hC hS k k' e e' ((nodeRef_exposes (hR.node k)).1 e he)
    ((nodeRef_exposes (hR'.node k')).1 e' he') hidx

/-- Snapshot safety: an exposed snapshot's boundary agrees with every entry and
    snapshot exposed later at its index. -/
theorem host_snapshot_safety [Rust.LawfulClone V] [Rust.LawfulClone S] (ids : Vector Id N)
    (cfg : Fin N → Config N) (ha : Assumptions ids cfg CAP) (H H' : HCluster V S N CAP) (h : HReach cfg H)
    (hs : HSteps cfg H H') (k k' : Fin N) (snap : Snapshot S) (hx : ExposesSnapshot (H.live k) snap) :
    (∀ e, Exposes (H'.live k') e → e.id.index = snap.last.index → e.id = snap.last) ∧
    (∀ snap', ExposesSnapshot (H'.live k') snap' → snap'.last.index = snap.last.index →
      snap'.last = snap.last) := by
  obtain ⟨C, hC, hR⟩ := refines_reach ids cfg ha H h
  obtain ⟨C', hS, hR'⟩ := refines_steps ids cfg ha H H' C hR hC hs
  obtain ⟨h1, h2⟩ := raft_snapshot_safety ids cfg ha C C' hC hS k k' snap ((nodeRef_exposes (hR.node k)).2 snap hx)
  exact ⟨fun e he => h1 e ((nodeRef_exposes (hR'.node k')).1 e he),
    fun snap' hx' => h2 snap' ((nodeRef_exposes (hR'.node k')).2 snap' hx')⟩

end Jarl.Engine.Host
