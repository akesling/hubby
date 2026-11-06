import Engine.Dyn.Host.Refine

/-! Raft safety for every reachable dynamic cluster of hosts that persist
`Ready` deltas into durable records (acknowledged or not) and restart through
`State::restore`, `ClusterState::restore` and `Cluster::new`.

The theorems of `Engine.Dyn.Safety`, restated over `DHReach` and proved by
refinement: a host execution is a model execution with the same network, whose
nodes are the host nodes up to the pending-save flags of nodes whose write is
saved but unacknowledged (`dhost_refinement`). -/

set_option linter.unusedSectionVars false

namespace Jarl.Engine.DynHost
open Jarl Jarl.Engine Jarl.Engine.Host Jarl.Engine.Dyn Jarl.Contracts.StorageView

variable {V S : Type} {MAX CAP K : Nat} [Rust.Clone V] [Rust.Clone S]

/-- Refinement: every reachable host cluster has a reachable model cluster with
    the same network whose checkpoints are exactly what restoring the durable
    records yields; every node's dirty tracking is correct for its durable record;
    and each host node is the model node, or is dirty with its write saved: the
    model node is its acknowledged form and the model checkpoint its live state. -/
theorem dhost_refinement [Rust.LawfulClone V] [Rust.LawfulClone S] (ids : Vector Id K) (g : Membership MAX)
    (ha : Dyn.Assumptions ids g CAP) (H : HWorld V S MAX CAP K) (h : DHReach ids g H) :
    ∃ C, DReach ids g C ∧ C.sent = H.sent ∧
      (∀ k, State.restore (H.durable k).hard (H.durable k).snapshot ((H.durable k).entries.map pure) =
        (pure (.Ok (C.disk k)) : Rust.M (Rust.Result (DState V S MAX CAP) Error))) ∧
      (∀ k, H.durable k = view (C.disk k)) ∧ (∀ k, DeltaOk (H.durable k) (H.live k).node) ∧
      ∀ k, H.live k = C.live k ∨ ((H.live k).node.dirty = true ∧
        (C.live k).node = (Ready.persisted ⟨(H.live k).node⟩).node ∧ C.disk k = (H.live k).node.state) := by
  obtain ⟨C, hC, hR⟩ := drefines_reach ids g ha H h
  exact ⟨C, hC, hR.sent.symm, dhost_restore ids g ha H C hR hC, fun k => (hR.node k).1,
    fun k => (hR.node k).2.1, fun k => (hR.node k).2.2⟩

/-- Every reachable host node's dirty tracking is correct: applying its pending
    write to its durable record yields the durable view of its live state. -/
theorem dhost_write_exact [Rust.LawfulClone V] [Rust.LawfulClone S] (ids : Vector Id K) (g : Membership MAX)
    (ha : Dyn.Assumptions ids g CAP) (H : HWorld V S MAX CAP K) (h : DHReach ids g H) (k : Fin K)
    (ready : Ready (Record V MAX) (Checkpoint S MAX) MAX CAP) (hr : Cluster.ready (H.live k) = some ready)
    (w : Jarl.Write (Record V MAX) (Checkpoint S MAX)) (hw : readyWrite ready = pure w) :
    applyWrite (H.durable k) w = view (H.live k).node.state := by
  obtain ⟨C, -, hR⟩ := drefines_reach ids g ha H h
  obtain ⟨rfl, -⟩ := dh_cluster_ready _ ready hr
  exact deltaOk_write _ _ (hR.node k).2.1 w hw

/-- Election safety: at most one host node leads each term. -/
theorem dhost_election_safety [Rust.LawfulClone V] [Rust.LawfulClone S] (ids : Vector Id K) (g : Membership MAX)
    (ha : Dyn.Assumptions ids g CAP) (H : HWorld V S MAX CAP K) (h : DHReach ids g H) (k k' : Fin K)
    (hk : (H.live k).node.role = .Leader) (hk' : (H.live k').node.role = .Leader)
    (ht : (H.live k).node.state.hard.term = (H.live k').node.state.hard.term) : k = k' := by
  obtain ⟨C, hC, hR⟩ := drefines_reach ids g ha H h
  obtain ⟨r1, s1, -⟩ := noderef_view _ _ _ _ (hR.node k)
  obtain ⟨r2, s2, -⟩ := noderef_view _ _ _ _ (hR.node k')
  rw [r1] at hk
  rw [r2] at hk'
  rw [s1, s2] at ht
  exact Dyn.election_safety ids g ha C hC k k' hk hk' ht

/-- What a host node exposes, the model node exposes. -/
theorem dh_exposes (hc mc : Jarl.Cluster V S MAX CAP) (d : Durable (Record V MAX) (Checkpoint S MAX))
    (disk : DState V S MAX CAP) (h : NodeRef hc d mc disk) (e : DEntry V MAX) (he : Dyn.Exposes hc.node e) :
    Dyn.Exposes mc.node e := by
  rw [← (noderef_view _ _ _ _ h).2.2 he.1]; exact he

theorem dh_exposesSnapshot (hc mc : Jarl.Cluster V S MAX CAP) (d : Durable (Record V MAX) (Checkpoint S MAX))
    (disk : DState V S MAX CAP) (h : NodeRef hc d mc disk) (snap : Snapshot (Checkpoint S MAX))
    (he : Dyn.ExposesSnapshot hc.node snap) : Dyn.ExposesSnapshot mc.node snap := by
  rw [← (noderef_view _ _ _ _ h).2.2 he.1]; exact he

/-- State machine safety: two entries host nodes expose as committed (anywhere
    along one host execution) at the same index are equal. -/
theorem dhost_state_machine_safety [Rust.LawfulClone V] [Rust.LawfulClone S] (ids : Vector Id K)
    (g : Membership MAX) (ha : Dyn.Assumptions ids g CAP) (H H' : HWorld V S MAX CAP K) (h : DHReach ids g H)
    (hs : DHSteps ids g H H') (k k' : Fin K) (e e' : DEntry V MAX) (he : Dyn.Exposes (H.live k).node e)
    (he' : Dyn.Exposes (H'.live k').node e') (hidx : e.id.index = e'.id.index) : e = e' := by
  obtain ⟨C, hC, hR⟩ := drefines_reach ids g ha H h
  obtain ⟨C', hS, hR'⟩ := drefines_steps ids g ha H H' C hR hC hs
  exact Dyn.state_machine_safety ids g ha C C' hC hS k k' e e' (dh_exposes _ _ _ _ (hR.node k) e he)
    (dh_exposes _ _ _ _ (hR'.node k') e' he') hidx

/-- Snapshot safety: a snapshot a host node exposes agrees with every entry and
    snapshot exposed later at its boundary. -/
theorem dhost_snapshot_safety [Rust.LawfulClone V] [Rust.LawfulClone S] (ids : Vector Id K)
    (g : Membership MAX) (ha : Dyn.Assumptions ids g CAP) (H H' : HWorld V S MAX CAP K) (h : DHReach ids g H)
    (hs : DHSteps ids g H H') (k k' : Fin K) (snap : Snapshot (Checkpoint S MAX))
    (hx : Dyn.ExposesSnapshot (H.live k).node snap) :
    (∀ e, Dyn.Exposes (H'.live k').node e → e.id.index = snap.last.index → e.id = snap.last) ∧
    (∀ snap', Dyn.ExposesSnapshot (H'.live k').node snap' → snap'.last.index = snap.last.index →
      snap'.last = snap.last) := by
  obtain ⟨C, hC, hR⟩ := drefines_reach ids g ha H h
  obtain ⟨C', hS, hR'⟩ := drefines_steps ids g ha H H' C hR hC hs
  obtain ⟨h1, h2⟩ := Dyn.snapshot_safety ids g ha C C' hC hS k k' snap (dh_exposesSnapshot _ _ _ _ (hR.node k) snap hx)
  exact ⟨fun e he hi => h1 e (dh_exposes _ _ _ _ (hR'.node k') e he) hi,
    fun s hs' hi => h2 s (dh_exposesSnapshot _ _ _ _ (hR'.node k') s hs') hi⟩

end Jarl.Engine.DynHost
