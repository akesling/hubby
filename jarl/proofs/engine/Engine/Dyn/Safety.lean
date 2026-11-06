import Engine.Dyn.Preserve

/-!
# Safety of a dynamic Jarl cluster

Over every execution of the generated code of `Cluster`'s public operations,
from empty checkpoints and a shared genesis configuration, with any sequence
of learner changes, joint reconfigurations and finalizations, crashes,
restarts, persistence, compaction, proposals and an adversarial network:

* `election_safety`: at most one node leads each term;
* `state_machine_safety`: two entries ever exposed as committed (`committed()`)
  at the same index are equal — including configuration records, so all nodes
  agree on the committed configuration history;
* `snapshot_safety`: an exposed snapshot agrees with every entry and snapshot
  later exposed at its boundary.
-/

set_option linter.unusedSectionVars false

namespace Jarl.Engine.Dyn
open Jarl Jarl.Engine

variable {V S : Type} {MAX CAP K : Nat} [Rust.Clone V] [Rust.Clone S]

/-- The assumptions of the theorems: distinct node identities, a valid genesis
    configuration (distinct identities, nonempty voters), and capacities that
    fit the pointer width. -/
structure Assumptions (ids : Vector Id K) (g : Membership MAX) (CAP : Nat) : Prop where
  distinct : ids.toList.Nodup
  genesis : MemOk g
  members_fit : MAX < 2 ^ (Rust.usizeBits - 1)
  capacity_fits : CAP < 2 ^ (Rust.usizeBits - 1)

theorem ids_inj (ids : Vector Id K) (h : ids.toList.Nodup) (a b : Fin K) (he : ids[a] = ids[b]) : a = b := by
  have : ids.toList[a.val]'(by simp) = ids.toList[b.val]'(by simp) := by simpa using he
  exact Fin.ext ((List.getElem_inj h).mp this)

/-- Reachable from `C` by any number of steps. -/
inductive Steps (ids : Vector Id K) (g : Membership MAX) : World V S MAX CAP K → World V S MAX CAP K → Prop
  | refl (C : World V S MAX CAP K) : Steps ids g C C
  | step (C C' C'' : World V S MAX CAP K) : DAct ids g C C' → Steps ids g C' C'' → Steps ids g C C''

theorem reach_inv [Rust.LawfulClone V] [Rust.LawfulClone S] (ids : Vector Id K) (g : Membership MAX)
    (ha : Assumptions ids g CAP) (C : World V S MAX CAP K) (h : DReach ids g C) : ∃ G, Inv ids g C G := by
  induction h with
  | init C hC =>
    exact ⟨_, init_inv ids g (ids_inj ids ha.distinct) ha.genesis ha.members_fit ha.capacity_fits C hC⟩
  | step C C' _ hs ih =>
    obtain ⟨G, hi⟩ := ih
    obtain ⟨G', -, hi'⟩ := preserve ids g (ids_inj ids ha.distinct) ha.genesis C C' G hi hs
    exact ⟨G', hi'⟩

theorem steps_inv [Rust.LawfulClone V] [Rust.LawfulClone S] (ids : Vector Id K) (g : Membership MAX)
    (ha : Assumptions ids g CAP) (C C' : World V S MAX CAP K) (G : Ghost (Record V MAX) K)
    (hi : Inv ids g C G) (hs : Steps ids g C C') : ∃ G', Extends G G' ∧ Inv ids g C' G' := by
  induction hs generalizing G with
  | refl => exact ⟨G, Extends.refl G, hi⟩
  | step C C1 C2 hact _ ih =>
    obtain ⟨G1, e1, h1⟩ := preserve ids g (ids_inj ids ha.distinct) ha.genesis C C1 G hi hact
    obtain ⟨G2, e2, h2⟩ := ih G1 h1
    exact ⟨G2, e1.trans e2, h2⟩

/-- A retained entry sits in the full log at its index. -/
theorem ret_in_fullLog' (G : Ghost (Record V MAX) K) (s : DState V S MAX CAP) (h : StateOk G s) (e : DEntry V MAX)
    (he : e ∈ ret s) : ∃ hl : e.id.index.val - 1 < (fullLog G s).length, (fullLog G s)[e.id.index.val - 1] = e := by
  obtain ⟨p, hp, rfl⟩ := List.getElem_of_mem he
  have hidx := h.contig p hp
  have hb := boundary_len G s h
  have hfl : fullLog G s = boundary G s ++ ret s := rfl
  have : (ret s)[p].id.index.val - 1 = s.base.index.val + p := by omega
  rw [this, hfl]
  refine ⟨by simp; omega, ?_⟩
  rw [List.getElem_append_right (by omega)]
  congr 1; omega

/-- `committed()` yields `e`: the node is clean and `e` is a retained entry at or below the commit index. -/
def Exposes (n : DNode V S MAX CAP) (e : DEntry V MAX) : Prop :=
  n.dirty = false ∧ e ∈ ret n.state ∧ e.id.index.val ≤ n.state.hard.commit.val

/-- `snapshot()` yields `snap`: the node is clean and holds that snapshot. -/
def ExposesSnapshot (n : DNode V S MAX CAP) (snap : Snapshot (Checkpoint S MAX)) : Prop :=
  n.dirty = false ∧ n.state.snapshot = some snap

theorem exposed_committed (ids : Vector Id K) (g : Membership MAX) (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K)
    (hi : Inv ids g C G) (k : Fin K) (e : DEntry V MAX) (he : Exposes (C.node k) e) :
    ∃ T p, CommittedBy ids g G T p ∧ ∃ h : e.id.index.val - 1 < p.length, p[e.id.index.val - 1] = e := by
  obtain ⟨hd, hmem, hc⟩ := he
  have hs := hi.clean k hd
  rw [hs] at hmem hc
  obtain ⟨hl, hget⟩ := ret_in_fullLog' G _ (hi.disk k).1 e hmem
  have hpos : 0 < e.id.index.val := by
    obtain ⟨p, hp, rfl⟩ := List.getElem_of_mem hmem
    have := (hi.disk k).1.contig p hp; omega
  refine ⟨_, _, (hi.committed k).1, by simp; omega, ?_⟩
  rw [List.getElem_take]; exact hget

theorem snapshot_committed (ids : Vector Id K) (g : Membership MAX) (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K)
    (hi : Inv ids g C G) (k : Fin K) (snap : Snapshot (Checkpoint S MAX)) (h : ExposesSnapshot (C.node k) snap) :
    ∃ T p, CommittedBy ids g G T p ∧ ∃ h : snap.last.index.val - 1 < p.length, (p[snap.last.index.val - 1]).id = snap.last ∧
      0 < snap.last.index.val := by
  obtain ⟨hd, hs⟩ := h
  have hcl := hi.clean k hd
  rw [hcl] at hs
  have hok := (hi.disk k).1
  have hbase : (C.disk k).base = snap.last := by simp [State.base, hs]
  have hpos0 : 0 < (C.disk k).base.index.val := hok.snapshot (by simp [hs])
  suffices H : ∃ T p, CommittedBy ids g G T p ∧ ∃ h : (C.disk k).base.index.val - 1 < p.length,
      (p[(C.disk k).base.index.val - 1]).id = (C.disk k).base ∧ 0 < (C.disk k).base.index.val by
    rw [hbase] at H; exact H
  have hlen := fullLog_length G (C.disk k) hok
  have hge := hok.commit_ge
  have hle := hok.commit_le
  obtain ⟨L, hL, hbl, hlt, hid⟩ := hok.base hpos0
  have hb := boundary_len G (C.disk k) hok
  refine ⟨_, _, (hi.committed k).1, by simp; omega, ?_, hpos0⟩
  rw [List.getElem_take]
  have hin : (C.disk k).base.index.val - 1 < (boundary G (C.disk k)).length := by omega
  simp only [fullLog_def]
  rw [List.getElem_append_left hin]
  simp only [boundary, show (C.disk k).base.index.val ≠ 0 by omega, if_false, Ghost.prefix, hL, Option.getD_some,
    List.getElem_take]
  exact hid

/-- Election safety: two nodes leading the same term are the same node. -/
theorem election_safety [Rust.LawfulClone V] [Rust.LawfulClone S] (ids : Vector Id K) (g : Membership MAX)
    (ha : Assumptions ids g CAP) (C : World V S MAX CAP K) (h : DReach ids g C) (k k' : Fin K)
    (hk : (C.node k).role = .Leader) (hk' : (C.node k').role = .Leader)
    (ht : (C.node k).state.hard.term = (C.node k').state.hard.term) : k = k' := by
  obtain ⟨G, hi⟩ := reach_inv ids g ha C h
  have hid := ids_inj ids ha.distinct
  rcases (hi.leader k hk).1 with ⟨eL, he⟩ | hp <;> rcases (hi.leader k' hk').1 with ⟨eL', he'⟩ | hp'
  · rw [ht, he'] at he; cases he; rfl
  · rw [ht, hp'.2.2.1] at he; cases he
  · rw [← ht, hp.2.2.1] at he'; cases he'
  · exact (pending_unique ids g hid C G hi k k' hp hp' (by rw [ht])).symm

/-- State-machine safety: two entries exposed as committed at the same index,
    by any nodes at any two points of one execution, are equal. -/
theorem state_machine_safety [Rust.LawfulClone V] [Rust.LawfulClone S] (ids : Vector Id K) (g : Membership MAX)
    (ha : Assumptions ids g CAP) (C C' : World V S MAX CAP K) (h : DReach ids g C) (hs : Steps ids g C C')
    (k k' : Fin K) (e e' : DEntry V MAX) (he : Exposes (C.node k) e) (he' : Exposes (C'.node k') e')
    (hidx : e.id.index = e'.id.index) : e = e' := by
  obtain ⟨G, hi⟩ := reach_inv ids g ha C h
  obtain ⟨G', hext, hi'⟩ := steps_inv ids g ha C C' G hi hs
  obtain ⟨T, p, hp, hpl, hpe⟩ := exposed_committed ids g C G hi k e he
  obtain ⟨T', q, hq, hql, hqe⟩ := exposed_committed ids g C' G' hi' k' e' he'
  have hp' := committedBy_mono hext T p hp
  rcases committed_compatible (ids_inj ids ha.distinct) G' hi'.wf T T' p q hp' hq with h | h
  · rw [← hpe, ← hqe]
    simp only [hidx] at hpl hpe ⊢
    exact List.IsPrefix.getElem h _
  · rw [← hpe, ← hqe]
    simp only [hidx] at hpl hpe ⊢
    exact (List.IsPrefix.getElem h _).symm

/-- Snapshot safety: an exposed snapshot's boundary agrees with every entry and
    snapshot later exposed at its index. -/
theorem snapshot_safety [Rust.LawfulClone V] [Rust.LawfulClone S] (ids : Vector Id K) (g : Membership MAX)
    (ha : Assumptions ids g CAP) (C C' : World V S MAX CAP K) (h : DReach ids g C) (hs : Steps ids g C C')
    (k k' : Fin K) (snap : Snapshot (Checkpoint S MAX)) (hx : ExposesSnapshot (C.node k) snap) :
    (∀ e, Exposes (C'.node k') e → e.id.index = snap.last.index → e.id = snap.last) ∧
    (∀ snap', ExposesSnapshot (C'.node k') snap' → snap'.last.index = snap.last.index →
      snap'.last = snap.last) := by
  obtain ⟨G, hi⟩ := reach_inv ids g ha C h
  obtain ⟨G', hext, hi'⟩ := steps_inv ids g ha C C' G hi hs
  obtain ⟨T, p, hp, hpl, hpe, hpos⟩ := snapshot_committed ids g C G hi k snap hx
  have hp' := committedBy_mono hext T p hp
  have agree : ∀ T' q, CommittedBy ids g G' T' q → ∀ hq : snap.last.index.val - 1 < q.length,
      (q[snap.last.index.val - 1]).id = snap.last := by
    intro T' q hq hql
    rcases committed_compatible (ids_inj ids ha.distinct) G' hi'.wf T T' p q hp' hq with hpq | hpq
    · rw [← List.IsPrefix.getElem hpq hpl]; exact hpe
    · rw [List.IsPrefix.getElem hpq hql]; exact hpe
  constructor
  · intro e he hidx
    obtain ⟨T', q, hq, hql, hqe⟩ := exposed_committed ids g C' G' hi' k' e he
    rw [← hqe]; simp only [hidx] at hql ⊢; exact agree T' q hq hql
  · intro snap' hs' hidx
    obtain ⟨T', q, hq, hql, hqe, -⟩ := snapshot_committed ids g C' G' hi' k' snap' hs'
    rw [← hqe]; simp only [hidx] at hql ⊢; exact agree T' q hq hql

end Jarl.Engine.Dyn
