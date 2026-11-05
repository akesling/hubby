import Engine.App.Preserve

/-! Application safety of snapshots for every honestly reachable cluster.

A cluster moves by `AppAct`: `Act` with every compaction passing the value an
honest host computes from what the node exposes (`honest`). Then every
snapshot a node exposes holds the application state (`state init apply`) of
the committed history through its boundary, and that history agrees with
every entry any node exposes as committed, then or later. -/

namespace Jarl.Engine.App
open Jarl Jarl.Engine Jarl.Engine.Deliver

variable {V S : Type} {N CAP : Nat} [Rust.Clone V] [Rust.Clone S]

section
variable (init : S) (apply : S → Option V → S)

omit [Rust.Clone V] [Rust.Clone S] in
/-- A committed prefix is consistent. -/
theorem committed_consistent (G : Ghost V N) (hw : Wf G) (p : List (Entry V)) (h : Committed G p) :
    Consistent G p := by
  rcases h with rfl | ⟨t, j, ⟨-, L, hL, -⟩, hp⟩
  · intro i hi; simp at hi
  · have hpL : p <+: L := hp.trans (prefix_le G t j L hL)
    obtain ⟨r, rfl⟩ := hpL
    have := consistent_take G _ (hw.leader t _ hL).1 p.length
    simpa using this

omit [Rust.Clone V] [Rust.Clone S] in
/-- An exposed snapshot holds the application state of a committed prefix ending at its boundary. -/
theorem snapshot_value_committed (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP)
    (G : Ghost V N) (hi : Inv ids cfg C G) (hA : AppInv init apply C G) (k : Fin N) (snap : Snapshot S)
    (hx : ExposesSnapshot (C.live k) snap) :
    ∃ P, Committed G P ∧ P.length = snap.last.index.val ∧
      (∃ h : snap.last.index.val - 1 < P.length, (P[snap.last.index.val - 1]).id = snap.last) ∧
      snap.value = state init apply P := by
  obtain ⟨p, hp, hpl, hpe, hpos⟩ := snapshot_committed ids cfg C G hi k snap hx
  have hc := committed_consistent G hi.wf p hp
  have ht := consistent_take_prefix G p hc _ hpos hpl
  rw [hpe] at ht
  obtain ⟨-, -, -, hv⟩ := hA.live k snap hx.2
  refine ⟨p.take snap.last.index.val, committed_prefix G p _ hp (List.take_prefix _ _),
    by simp; omega, ⟨by simp; omega, by simp [hpe]⟩, by rw [ht]; exact hv⟩

/-- Application safety of snapshots: for every honestly reachable cluster, every
    snapshot a node exposes holds the application state of the committed history
    through its boundary. That history `P` is a committed prefix (for a ghost
    history `G` satisfying the cluster invariant) of exactly `snap.last.index`
    entries ending at the boundary, and it agrees with every entry any node
    exposes as committed at or below the boundary, now or after any further steps. -/
theorem raft_snapshot_application_safety [Rust.LawfulClone V] [Rust.LawfulClone S] (ids : Vector Id N)
    (cfg : Fin N → Config N) (ha : Assumptions ids cfg CAP) (C : Cluster V S N CAP)
    (h : AppReach init apply cfg C) (k : Fin N) (snap : Snapshot S) (hx : ExposesSnapshot (C.live k) snap) :
    ∃ G P, Inv ids cfg C G ∧ Committed G P ∧ P.length = snap.last.index.val ∧
      (∃ h : snap.last.index.val - 1 < P.length, (P[snap.last.index.val - 1]).id = snap.last) ∧
      snap.value = state init apply P ∧
      ∀ C', Steps cfg C C' → ∀ k' e, Exposes (C'.live k') e → e.id.index.val ≤ snap.last.index.val →
        ∃ h : e.id.index.val - 1 < P.length, P[e.id.index.val - 1] = e := by
  obtain ⟨G, hi, hA⟩ := app_reach_inv init apply ids cfg ha C h
  obtain ⟨P, hP, hlen, hlast, hv⟩ := snapshot_value_committed init apply ids cfg C G hi hA k snap hx
  refine ⟨G, P, hi, hP, hlen, hlast, hv, fun C' hs k' e he hle => ?_⟩
  obtain ⟨G', hext, hi'⟩ := steps_inv ids cfg C C' G hi hs
  obtain ⟨q, hq, hql, hqe⟩ := exposed_committed ids cfg C' G' hi' k' e he
  have hpos : 0 < e.id.index.val := by
    obtain ⟨-, hmem, -⟩ := he
    obtain ⟨p, hp, rfl⟩ := List.getElem_of_mem hmem
    have := (hi'.live k').contig p hp; omega
  have hPl : e.id.index.val - 1 < P.length := by omega
  refine ⟨hPl, ?_⟩
  refine Eq.trans ?_ hqe
  rcases committed_compatible G' hi'.wf P q (committed_mono hext P hP) hq with hpq | hpq
  · exact List.IsPrefix.getElem hpq hPl
  · exact (List.IsPrefix.getElem hpq hql).symm

/-- Two snapshots exposed at the same boundary index, by any nodes at any two
    points of an honest execution, hold the same application state. -/
theorem raft_snapshot_value_agreement [Rust.LawfulClone V] [Rust.LawfulClone S] (ids : Vector Id N)
    (cfg : Fin N → Config N) (ha : Assumptions ids cfg CAP) (C C' : Cluster V S N CAP)
    (h : AppReach init apply cfg C) (hs : AppSteps init apply cfg C C') (k k' : Fin N) (snap snap' : Snapshot S)
    (hx : ExposesSnapshot (C.live k) snap) (hx' : ExposesSnapshot (C'.live k') snap')
    (hidx : snap.last.index = snap'.last.index) : snap.value = snap'.value := by
  obtain ⟨G, hi, hA⟩ := app_reach_inv init apply ids cfg ha C h
  obtain ⟨G', hext, hi', hA'⟩ := app_steps_inv init apply ids cfg C C' G hi hA hs
  obtain ⟨P, hP, hlen, -, hv⟩ := snapshot_value_committed init apply ids cfg C G hi hA k snap hx
  obtain ⟨Q, hQ, hlen', -, hv'⟩ := snapshot_value_committed init apply ids cfg C' G' hi' hA' k' snap' hx'
  have hl : P.length = Q.length := by rw [hlen, hlen', hidx]
  have hPQ : P = Q := by
    rcases committed_compatible G' hi'.wf P Q (committed_mono hext P hP) hQ with h | h
    · exact h.eq_of_length hl
    · exact (h.eq_of_length hl.symm).symm
  rw [hv, hv', hPQ]

end

end Jarl.Engine.App
