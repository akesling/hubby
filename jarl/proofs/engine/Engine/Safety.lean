import Engine.Init
import Engine.Preserve.All

/-!
# Safety of a fixed Jarl cluster

Over every execution of the generated code of `Node`'s public operations,
from empty checkpoints, with crashes, restarts, persistence, compaction,
proposals and an adversarial network:

* `state_machine_safety`: two entries a node ever exposes as committed
  (`Node::committed`), at any times, at the same index, are equal;
* `election_safety`: at most one node is leader in each term.
-/

namespace Jarl.Engine
open Jarl

variable {V S : Type} {N CAP : Nat}

/-- Reachable from `C` by any number of cluster steps. -/
inductive Steps (cfg : Fin N → Config N) : Cluster V S N CAP → Cluster V S N CAP → Prop
  | refl (C : Cluster V S N CAP) : Steps cfg C C
  | step (C C' C'' : Cluster V S N CAP) : Act cfg C C' → Steps cfg C' C'' → Steps cfg C C''

/-- `Node::committed` yields `e`: the node is clean and `e` is a retained entry
    at or below the commit index. -/
def Exposes (n : Node V S N CAP) (e : Entry V) : Prop :=
  n.dirty = false ∧ e ∈ ret n.state ∧ e.id.index.val ≤ n.state.hard.commit.val

theorem steps_inv (ids : Vector Id N) (cfg : Fin N → Config N) (C C' : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (hs : Steps cfg C C') : ∃ G', Extends G G' ∧ Inv ids cfg C' G' := by
  induction hs generalizing G with
  | refl => exact ⟨G, Extends.refl G, hi⟩
  | step C C1 C2 ha _ ih =>
    obtain ⟨G1, e1, h1⟩ := preserve ids cfg C C1 G hi ha
    obtain ⟨G2, e2, h2⟩ := ih G1 h1
    exact ⟨G2, e1.trans e2, h2⟩

/-- The boundary prefix of a full log has exactly `base.index` entries. -/
theorem boundary_length (G : Ghost V N) (s : State V S CAP) (h : StateOk G s) :
    (if s.base.index.val = 0 then [] else G.prefix s.base.term.val s.base.index.val).length = s.base.index.val := by
  split
  · simp_all
  · obtain ⟨L, hL, hle, -⟩ := h.base (by omega)
    simp [Ghost.prefix, hL]; omega

/-- A retained entry sits in the full log at its index. -/
theorem ret_in_fullLog (G : Ghost V N) (s : State V S CAP) (h : StateOk G s) (e : Entry V) (he : e ∈ ret s) :
    ∃ hl : e.id.index.val - 1 < (fullLog G s).length, (fullLog G s)[e.id.index.val - 1] = e := by
  obtain ⟨p, hp, rfl⟩ := List.getElem_of_mem he
  have hidx := h.contig p hp
  have hb := boundary_length G s h
  generalize hB : (if s.base.index.val = 0 then [] else G.prefix s.base.term.val s.base.index.val) = B at hb
  have hfl : fullLog G s = B ++ ret s := by rw [← hB]; rfl
  have : (ret s)[p].id.index.val - 1 = s.base.index.val + p := by omega
  rw [this, hfl]
  refine ⟨by simp; omega, ?_⟩
  rw [List.getElem_append_right (by omega)]
  congr 1; omega

/-- An exposed entry is the entry at its index of a committed prefix. -/
theorem exposed_committed (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (k : Fin N) (e : Entry V) (he : Exposes (C.live k) e) :
    ∃ p, Committed G p ∧ ∃ h : e.id.index.val - 1 < p.length, p[e.id.index.val - 1] = e := by
  obtain ⟨hd, hmem, hc⟩ := he
  have hs := hi.clean k hd
  rw [hs] at hmem hc
  obtain ⟨hl, hget⟩ := ret_in_fullLog G _ (hi.disk k) e hmem
  have hpos : 0 < e.id.index.val := by
    obtain ⟨p, hp, rfl⟩ := List.getElem_of_mem hmem
    have := (hi.disk k).contig p hp; omega
  refine ⟨_, (hi.committed k).1, by simp; omega, ?_⟩
  rw [List.getElem_take]; exact hget

theorem state_machine_safety (ids : Vector Id N) (cfg : Fin N → Config N) (C C' : Cluster V S N CAP)
    (G : Ghost V N) (hi : Inv ids cfg C G) (hs : Steps cfg C C') (k k' : Fin N) (e e' : Entry V)
    (he : Exposes (C.live k) e) (he' : Exposes (C'.live k') e') (hidx : e.id.index = e'.id.index) : e = e' := by
  obtain ⟨G', hext, hi'⟩ := steps_inv ids cfg C C' G hi hs
  obtain ⟨p, hp, hpl, hpe⟩ := exposed_committed ids cfg C G hi k e he
  obtain ⟨q, hq, hql, hqe⟩ := exposed_committed ids cfg C' G' hi' k' e' he'
  have hp' := committed_mono hext p hp
  rcases committed_compatible G' hi'.wf p q hp' hq with h | h
  · rw [← hpe, ← hqe]
    simp only [hidx] at hpl hpe ⊢
    exact List.IsPrefix.getElem h _
  · rw [← hpe, ← hqe]
    simp only [hidx] at hpl hpe ⊢
    exact (List.IsPrefix.getElem h _).symm

/-- `Node::snapshot` yields `snap`: the node is clean and holds that snapshot. -/
def ExposesSnapshot (n : Node V S N CAP) (snap : Snapshot S) : Prop :=
  n.dirty = false ∧ n.state.snapshot = some snap

/-- An exposed snapshot's boundary is the identity at its index of a committed prefix. -/
theorem snapshot_committed (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (k : Fin N) (snap : Snapshot S) (h : ExposesSnapshot (C.live k) snap) :
    ∃ p, Committed G p ∧ ∃ h : snap.last.index.val - 1 < p.length, (p[snap.last.index.val - 1]).id = snap.last ∧
      0 < snap.last.index.val := by
  obtain ⟨hd, hs⟩ := h
  have hcl := hi.clean k hd
  rw [hcl] at hs
  have hok := hi.disk k
  have hbase : (C.disk k).base = snap.last := by simp [State.base, hs]
  have hpos0 : 0 < (C.disk k).base.index.val := hok.snapshot (by simp [hs])
  suffices H : ∃ p, Committed G p ∧ ∃ h : (C.disk k).base.index.val - 1 < p.length,
      (p[(C.disk k).base.index.val - 1]).id = (C.disk k).base ∧ 0 < (C.disk k).base.index.val by
    rw [hbase] at H; exact H
  have hlen := fullLog_length G (C.disk k) hok
  have hge := hok.commit_ge
  have hle := hok.commit_le
  obtain ⟨L, hL, hbl, hlt, hid⟩ := hok.base hpos0
  have hb := boundary_len G (C.disk k) hok
  refine ⟨_, (hi.committed k).1, by simp; omega, ?_, hpos0⟩
  rw [List.getElem_take]
  have hin : (C.disk k).base.index.val - 1 < (boundary G (C.disk k)).length := by omega
  simp only [fullLog_def]
  rw [List.getElem_append_left hin]
  simp only [boundary, show (C.disk k).base.index.val ≠ 0 by omega, if_false, Ghost.prefix, hL, Option.getD_some,
    List.getElem_take]
  exact hid

/-- Snapshot safety: an exposed snapshot boundary agrees with every entry and
    snapshot boundary exposed at the same index, at any times. -/
theorem snapshot_safety (ids : Vector Id N) (cfg : Fin N → Config N) (C C' : Cluster V S N CAP)
    (G : Ghost V N) (hi : Inv ids cfg C G) (hs : Steps cfg C C') (k k' : Fin N) (snap : Snapshot S)
    (h : ExposesSnapshot (C.live k) snap) :
    (∀ e, Exposes (C'.live k') e → e.id.index = snap.last.index → e.id = snap.last) ∧
    (∀ snap', ExposesSnapshot (C'.live k') snap' → snap'.last.index = snap.last.index → snap'.last = snap.last) := by
  obtain ⟨G', hext, hi'⟩ := steps_inv ids cfg C C' G hi hs
  obtain ⟨p, hp, hpl, hpe, hpos⟩ := snapshot_committed ids cfg C G hi k snap h
  have hp' := committed_mono hext p hp
  have agree : ∀ q, Committed G' q → ∀ hq : snap.last.index.val - 1 < q.length,
      (q[snap.last.index.val - 1]).id = snap.last := by
    intro q hq hql
    rcases committed_compatible G' hi'.wf p q hp' hq with hpq | hpq
    · rw [← List.IsPrefix.getElem hpq hpl]; exact hpe
    · rw [List.IsPrefix.getElem hpq hql]; exact hpe
  constructor
  · intro e he hidx
    obtain ⟨q, hq, hql, hqe⟩ := exposed_committed ids cfg C' G' hi' k' e he
    rw [← hqe]; simp only [hidx] at hql ⊢; exact agree q hq hql
  · intro snap' hs' hidx
    obtain ⟨q, hq, hql, hqe, -⟩ := snapshot_committed ids cfg C' G' hi' k' snap' hs'
    rw [← hqe]; simp only [hidx] at hql ⊢; exact agree q hq hql

end Jarl.Engine
