import Engine.Host

/-! The public wrappers `propose`, `propose_batch` and `compact` reduce to
`propose_many` and `compact_with`, with the application's `Clone` of each
value deferred into the list (or closure) they pass. -/

namespace Jarl.Engine
open Jarl

variable {V S : Type} {N CAP : Nat} [Rust.Clone V] [Rust.Clone S]

theorem propose_wrap (n : Node V S N CAP) (v : V) (r : Rust.Result LogId Error) (n' : Node V S N CAP)
    (h : Node.propose n v = pure (r, n')) : ∃ r', Node.propose_many n 1 [Rust.Clone.clone v] = pure (r', n') := by
  unfold Node.propose at h
  obtain ⟨⟨r', m⟩, h1, h2⟩ := bind_eq_pure _ _ _ h
  refine ⟨r', ?_⟩
  have hm : m = n' := by
    cases r' with
    | Ok v => simp at h2; exact (Prod.mk.inj (pure_inj h2)).2
    | Err e => simp at h2; exact (Prod.mk.inj (pure_inj h2)).2
  rw [← hm]; simpa only [bind_pure] using h1

theorem propose_batch_wrap (n : Node V S N CAP) (vs : Array V) (r : Rust.Result ProposalRange Error)
    (n' : Node V S N CAP) (h : Node.propose_batch n vs = pure (r, n')) :
    Node.propose_many n (Rust.usizeOf vs.size) (vs.toList.map Rust.Clone.clone) = pure (r, n') := by
  unfold Node.propose_batch at h
  obtain ⟨⟨r', m⟩, h1, h2⟩ := bind_eq_pure _ _ _ h
  simp at h2
  obtain ⟨rfl, rfl⟩ := Prod.mk.inj (pure_inj h2)
  exact h1

theorem compact_wrap (n : Node V S N CAP) (index : Rust.u64) (v : S) (r : Rust.Result Unit Error)
    (n' : Node V S N CAP) (h : Node.compact n index v = pure (r, n')) :
    Node.compact_with n index (fun _ => Rust.Clone.clone v) = pure (r, n') := by
  unfold Node.compact at h
  obtain ⟨⟨r', m⟩, h1, h2⟩ := bind_eq_pure _ _ _ h
  simp at h2
  obtain ⟨rfl, rfl⟩ := Prod.mk.inj (pure_inj h2)
  exact h1

end Jarl.Engine
