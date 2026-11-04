import Engine.Safety

/-! Raft safety for every reachable cluster of fixed-membership `Node`s.

A cluster starts from `Node::new` on empty states (`Initial`) and moves by
`Act`: any node ticks, steps an envelope ever sent, proposes, compacts,
persists its pending transaction, sends or drops an outgoing message, or
restarts from its persisted state. The configuration assumptions are those
of `init_inv`: a non-empty duplicate-free membership `ids` shared by every
node, with node `k` having identity `ids[k]`. -/

namespace Jarl.Engine
open Jarl

variable {V S : Type} {N CAP : Nat}

/-- The configuration assumptions under which the theorems below hold. -/
structure Assumptions (ids : Vector Id N) (cfg : Fin N → Config N) (CAP : Nat) : Prop where
  nonempty : 0 < N
  members_fit : N < 2 ^ 63
  capacity_fits : CAP < 2 ^ 63
  distinct : ids.toList.Nodup
  members : ∀ k, (cfg k).members = ids
  identity : ∀ k, (cfg k).id = ids[k]

theorem reach_inv (ids : Vector Id N) (cfg : Fin N → Config N) (ha : Assumptions ids cfg CAP)
    (C : Cluster V S N CAP) (h : Reach cfg C) : ∃ G, Inv ids cfg C G := by
  induction h with
  | init C hC =>
    exact ⟨_, init_inv ids cfg ha.nonempty ha.members_fit ha.capacity_fits ha.distinct ha.members
      ha.identity C hC⟩
  | step C C' _ hs ih =>
    obtain ⟨G, hi⟩ := ih
    obtain ⟨G', -, hi'⟩ := preserve ids cfg C C' G hi hs
    exact ⟨G', hi'⟩

/-- Election safety: at most one node is leader in any term. -/
theorem election_safety (ids : Vector Id N) (cfg : Fin N → Config N) (ha : Assumptions ids cfg CAP)
    (C : Cluster V S N CAP) (h : Reach cfg C) (k k' : Fin N)
    (hk : (C.live k).role = .Leader) (hk' : (C.live k').role = .Leader)
    (ht : (C.live k).state.hard.term = (C.live k').state.hard.term) : k = k' := by
  obtain ⟨G, hi⟩ := reach_inv ids cfg ha C h
  obtain ⟨eL, he, -⟩ := (hi.leader k hk).elected
  obtain ⟨eL', he', -⟩ := (hi.leader k' hk').elected
  rw [ht, he'] at he
  cases he
  rfl

/-- State machine safety: two entries a node exposes as committed (anywhere
    along one execution) at the same index are equal. -/
theorem raft_state_machine_safety (ids : Vector Id N) (cfg : Fin N → Config N)
    (ha : Assumptions ids cfg CAP) (C C' : Cluster V S N CAP) (h : Reach cfg C) (hs : Steps cfg C C')
    (k k' : Fin N) (e e' : Entry V) (he : Exposes (C.live k) e) (he' : Exposes (C'.live k') e')
    (hidx : e.id.index = e'.id.index) : e = e' := by
  obtain ⟨G, hi⟩ := reach_inv ids cfg ha C h
  exact state_machine_safety ids cfg C C' G hi hs k k' e e' he he' hidx

/-- Snapshot safety: an exposed snapshot's boundary agrees with every entry and
    snapshot exposed later at its index. -/
theorem raft_snapshot_safety (ids : Vector Id N) (cfg : Fin N → Config N)
    (ha : Assumptions ids cfg CAP) (C C' : Cluster V S N CAP) (h : Reach cfg C) (hs : Steps cfg C C')
    (k k' : Fin N) (snap : Snapshot S) (hx : ExposesSnapshot (C.live k) snap) :
    (∀ e, Exposes (C'.live k') e → e.id.index = snap.last.index → e.id = snap.last) ∧
    (∀ snap', ExposesSnapshot (C'.live k') snap' → snap'.last.index = snap.last.index →
      snap'.last = snap.last) := by
  obtain ⟨G, hi⟩ := reach_inv ids cfg ha C h
  exact snapshot_safety ids cfg C C' G hi hs k k' snap hx

end Jarl.Engine
