import Engine.Invariant

/-! The invariant holds for every initial cluster, with an empty ghost history. -/

namespace Jarl.Engine
open Jarl

variable {V S : Type} {N CAP : Nat}

/-- The empty history. -/
def Ghost.empty : Ghost V N := ⟨fun _ => none, fun _ => none, [], []⟩

theorem new_ret : ret (State.new : State V S CAP) = [] := by
  simp [ret, State.new]

theorem new_layout : Layout (State.new : State V S CAP) := by
  refine ⟨by simp [State.new], ?_⟩
  rw [new_ret]
  apply List.ext_getElem <;> simp [State.new, Rust.Slice.from_fn]

theorem new_contig : Contig (State.new : State V S CAP) := by
  intro k hk; simp [new_ret] at hk

theorem new_base : (State.new : State V S CAP).base = LogId.default := rfl

theorem new_fullLog (G : Ghost V N) : fullLog G (State.new : State V S CAP) = [] := by
  simp [fullLog, new_base, LogId.default, new_ret]

theorem new_stateOk (G : Ghost V N) : StateOk G (State.new : State V S CAP) where
  layout := new_layout
  contig := new_contig
  base := by intro h; simp [new_base, LogId.default] at h
  snapshot := by simp [State.new]
  terms := by rw [new_fullLog]; simp
  commit_ge := by rw [new_base]; simp [LogId.default, State.new, HardState.default]
  commit_le := by simp [State.new, HardState.default]
  unvoted := by simp [State.new, HardState.default]

theorem wf_empty : Wf (Ghost.empty : Ghost V N) where
  leader := by intro t L h; simp [Ghost.empty] at h
  elect := by intro T c eL h; simp [Ghost.empty] at h
  ballot := by intro T w c v h; simp [Ghost.empty] at h

theorem init_inv (ids : Vector Id N) (cfg : Fin N → Config N) (hn : 0 < N) (hN : N < 2 ^ 63)
    (hcap : CAP < 2 ^ 63) (hd : ids.toList.Nodup) (hm : ∀ k, (cfg k).members = ids)
    (hid : ∀ k, (cfg k).id = ids[k])
    (C : Cluster V S N CAP) (hC : Initial cfg C) : Inv ids cfg C Ghost.empty := by
  obtain ⟨hs, hk⟩ := hC
  have hnew := fun k => new_rel ids (cfg k) _ _ (hk k).2 hn hN hcap (hm k) hd new_layout new_contig
  have hstate : ∀ k, (C.live k).state = State.new := fun k => (hnew k).2.1
  refine
    { wf := wf_empty
      fixed := fun k => ⟨(hnew k).1, (hnew k).2.2.1⟩
      slot := fun k => by
        have hf := (hnew k).1
        have h1 := hf.local_id
        rw [(hnew k).2.2.1, hid k] at h1
        exact (List.getElem_inj hd (h₀ := by simp [hf.local_lt]) (h₁ := by simp)).mp (by simpa using h1)
      live := fun k => by rw [hstate]; exact new_stateOk _
      disk := fun k => by rw [(hk k).1]; exact new_stateOk _
      consistent_disk := fun k => by rw [(hk k).1, new_fullLog]; intro i hi; simp at hi
      consistent_live := fun k _ => by rw [hstate, new_fullLog]; intro i hi; simp at hi
      clean := fun k _ => by rw [hstate, (hk k).1]
      terms := fun k => by rw [hstate, (hk k).1]; exact Nat.le_refl _
      acks := by intro w t j h; simp [Ghost.empty] at h
      ballots := by intro T w c v h; simp [Ghost.empty] at h
      ballot_unique := by intro T w c c' v v' h; simp [Ghost.empty] at h
      ballot_cand := by intro T w c v h; simp [Ghost.empty] at h
      elect := by intro T c eL h; simp [Ghost.empty] at h
      elect_cand := by intro T c eL h; simp [Ghost.empty] at h
      leader := by intro k h; rw [(hnew k).2.2.2.1] at h; cases h
      candidate := by intro k h; rw [(hnew k).2.2.2.1] at h; cases h
      outbox := by intro k j o h; rw [((hnew k).2.2.2.2.2 j).1] at h; cases h
      outbox_self := fun k => ((hnew k).2.2.2.2.2 k).1
      sent := by intro env h; rw [hs] at h; cases h
      committed := fun k => ⟨Or.inl (by rw [(hk k).1, new_fullLog]; simp),
        Or.inl (Or.inl (by rw [hstate, new_fullLog]; simp))⟩ }

end Jarl.Engine
