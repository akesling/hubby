import Engine.Host.Refine

/-! Raft safety for every reachable cluster of hosts that persist `Ready`
deltas into durable records and restart through `State::restore`.

The theorems of `Engine.Main`, restated over `HReach` and proved by
refinement: a host execution is a model execution with the same live nodes
and network (`host_refinement`). -/

namespace Jarl.Engine.Host
open Jarl Jarl.Engine Jarl.Contracts.StorageView

variable {V S : Type} {N CAP : Nat} [Rust.Clone V] [Rust.Clone S]

/-- Refinement: every reachable host cluster has a reachable model cluster with
    the same live nodes and network, whose checkpoints are exactly what restoring
    the durable records yields; and every node's dirty tracking is correct for its
    durable record. -/
theorem host_refinement [Rust.LawfulClone V] [Rust.LawfulClone S] (ids : Vector Id N) (cfg : Fin N → Config N)
    (ha : Assumptions ids cfg CAP) (H : HCluster V S N CAP) (h : HReach cfg H) :
    ∃ C, Reach cfg C ∧ C.live = H.live ∧ C.sent = H.sent ∧
      (∀ k, State.restore (H.durable k).hard (H.durable k).snapshot ((H.durable k).entries.map pure) =
        (pure (.Ok (C.disk k)) : Rust.M (Rust.Result (State V S CAP) Error))) ∧
      (∀ k, H.durable k = view (C.disk k)) ∧ ∀ k, DeltaOk (H.durable k) (H.live k) := by
  obtain ⟨C, hC, hR⟩ := refines_reach ids cfg ha H h
  exact ⟨C, hC, hR.live.symm, hR.sent.symm, host_restore ids cfg ha H C hR hC, hR.durable, hR.delta⟩

/-- Every reachable host node's dirty tracking is correct: applying its pending
    write to its durable record yields the durable view of its live state. -/
theorem host_write_exact [Rust.LawfulClone V] [Rust.LawfulClone S] (ids : Vector Id N) (cfg : Fin N → Config N)
    (ha : Assumptions ids cfg CAP) (H : HCluster V S N CAP) (h : HReach cfg H) (k : Fin N)
    (ready : Ready V S N CAP) (hr : Node.ready (H.live k) = some ready) (w : Jarl.Write V S)
    (hw : readyWrite ready = pure w) : applyWrite (H.durable k) w = view (H.live k).state := by
  obtain ⟨C, hC, hR⟩ := refines_reach ids cfg ha H h
  obtain ⟨rfl, -⟩ := ready_node _ ready hr
  exact deltaOk_write _ _ (hR.delta k) w hw

/-- Election safety: at most one node is leader in any term. -/
theorem host_election_safety [Rust.LawfulClone V] [Rust.LawfulClone S] (ids : Vector Id N) (cfg : Fin N → Config N)
    (ha : Assumptions ids cfg CAP) (H : HCluster V S N CAP) (h : HReach cfg H) (k k' : Fin N)
    (hk : (H.live k).role = .Leader) (hk' : (H.live k').role = .Leader)
    (ht : (H.live k).state.hard.term = (H.live k').state.hard.term) : k = k' := by
  obtain ⟨C, hC, hR⟩ := refines_reach ids cfg ha H h
  rw [hR.live] at hk hk' ht
  exact election_safety ids cfg ha C hC k k' hk hk' ht

/-- State machine safety: two entries a node exposes as committed (anywhere
    along one host execution) at the same index are equal. -/
theorem host_state_machine_safety [Rust.LawfulClone V] [Rust.LawfulClone S] (ids : Vector Id N)
    (cfg : Fin N → Config N) (ha : Assumptions ids cfg CAP) (H H' : HCluster V S N CAP) (h : HReach cfg H)
    (hs : HSteps cfg H H') (k k' : Fin N) (e e' : Entry V) (he : Exposes (H.live k) e)
    (he' : Exposes (H'.live k') e') (hidx : e.id.index = e'.id.index) : e = e' := by
  obtain ⟨C, hC, hR⟩ := refines_reach ids cfg ha H h
  obtain ⟨C', hS, hR'⟩ := refines_steps ids cfg ha H H' C hR hC hs
  rw [hR.live] at he
  rw [hR'.live] at he'
  exact raft_state_machine_safety ids cfg ha C C' hC hS k k' e e' he he' hidx

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
  rw [hR.live] at hx
  rw [hR'.live]
  exact raft_snapshot_safety ids cfg ha C C' hC hS k k' snap hx

end Jarl.Engine.Host
