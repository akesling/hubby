import Engine.NodeOps

/-!
# `replicated`: a leader handling a replication reply

Only what safety depends on is specified: the reply can raise the peer's match
index to the acknowledged index (successes only), the commit index can advance
as `advance_commit` allows, and replication descriptors can be queued.
-/

namespace Jarl.Engine
open Jarl

variable {V S : Type} {N CAP : Nat}

/-- The leader after recording a reply: role, votes, configuration, log and
    pending-save state are unchanged; the peer's match index is unchanged or
    raised to `index` on success (never past the last entry); other match
    indexes are unchanged. -/
def Recorded (n m : Node V S N CAP) (p : Nat) (hp : p < N) (index : Rust.u64)
    (rej : Option Rejection) : Prop :=
  m.config = n.config ∧ m.state = n.state ∧ m.role = n.role ∧ m.votes = n.votes ∧ m.dirty = n.dirty ∧
  m.local = n.local ∧ m.outbox = n.outbox ∧ m.extra_reply = n.extra_reply ∧
  (m.matched = n.matched ∨
    (rej = none ∧ index.val ≤ (lastId n.state).index.val ∧ (n.matched[p]'hp).val < index.val ∧
      m.matched = n.matched.set p index hp))

theorem fixed_misc (ids : Vector Id N) (n : Node V S N CAP) (hf : Fixed ids n) (a : Vector Bool N)
    (nx mt : Vector Rust.u64 N) (ob : Vector (Option Outbound) N) :
    Fixed ids { n with active := a, next := nx, matched := mt, outbox := ob } :=
  { hf with layout := hf.layout, contig := hf.contig }

/-- The early-return case: only `active` changed. -/
theorem replicated_trivial (ids : Vector Id N) (n : Node V S N CAP) (hf : Fixed ids n)
    (p : Nat) (hp : p < N) (index : Rust.u64) (rej : Option Rejection) (a : Vector Bool N) (nx : Vector Rust.u64 N)
    (ob : Vector (Option Outbound) N) (hob : ∀ j : Fin N, ob[j] = n.outbox[j] ∨ ob[j] = some .Replicate) :
    Fixed ids { n with active := a, next := nx, outbox := ob } ∧
      ∃ m, Recorded n m p hp index rej ∧ Fixed ids m ∧
        ∃ m', Adv m m' ∧ ({ n with active := a, next := nx, outbox := ob } : Node V S N CAP).config = m'.config ∧
          ({ n with active := a, next := nx, outbox := ob } : Node V S N CAP).state = m'.state ∧
          ({ n with active := a, next := nx, outbox := ob } : Node V S N CAP).role = m'.role ∧
          ({ n with active := a, next := nx, outbox := ob } : Node V S N CAP).votes = m'.votes ∧
          ({ n with active := a, next := nx, outbox := ob } : Node V S N CAP).dirty = m'.dirty ∧
          ({ n with active := a, next := nx, outbox := ob } : Node V S N CAP).matched = m'.matched ∧
          ({ n with active := a, next := nx, outbox := ob } : Node V S N CAP).local = m'.local ∧
          ({ n with active := a, next := nx, outbox := ob } : Node V S N CAP).extra_reply = m'.extra_reply ∧
          ∀ j : Fin N, ({ n with active := a, next := nx, outbox := ob } : Node V S N CAP).outbox[j] = m'.outbox[j] ∨
            ({ n with active := a, next := nx, outbox := ob } : Node V S N CAP).outbox[j] = some .Replicate :=
  ⟨fixed_misc ids n hf a nx n.matched ob, n, ⟨rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, Or.inl rfl⟩, hf, n, Or.inl rfl,
    rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, hob⟩

theorem replicated_rel (ids : Vector Id N) (n : Node V S N CAP) (hf : Fixed ids n)
    (p : Rust.usize) (hp : p.val < N) (index : Rust.u64) (rej : Option Rejection) :
    ∃ n', Node.replicated n p index rej = pure n' ∧ Fixed ids n' ∧
      ∃ m, Recorded n m p.val hp index rej ∧ Fixed ids m ∧
        ∃ m', Adv m m' ∧ n'.config = m'.config ∧ n'.state = m'.state ∧ n'.role = m'.role ∧
          n'.votes = m'.votes ∧ n'.dirty = m'.dirty ∧ n'.matched = m'.matched ∧ n'.local = m'.local ∧
          n'.extra_reply = m'.extra_reply ∧
          ∀ j : Fin N, n'.outbox[j] = m'.outbox[j] ∨ n'.outbox[j] = some .Replicate := by
  have hN : N < 2 ^ 64 := by have := hf.n_lt; omega
  have triv := replicated_trivial ids n hf p.val hp index rej (n.active.set p.val true hp) n.next n.outbox
    (fun _ => Or.inl rfl)
  unfold Node.replicated
  simp only [Rust.Slice.set_ok _ _ _ hp, pure_bind, last_eq _ hf.layout.1]
  by_cases h1 : index > (lastId n.state).index
  · simp only [h1, decide_true, if_true]
    exact ⟨_, rfl, triv⟩
  · rcases rej with _ | (nx | _) <;> simp only [h1, decide_false, Bool.false_eq_true, if_false]
    · simp only [Rust.Slice.index_ok _ _ hp, pure_bind]
      by_cases h2 : index ≤ n.matched[p.val]
      · simp only [h2, decide_true, if_true]
        exact ⟨_, rfl, triv⟩
      · simp only [h2, decide_false, Bool.false_eq_true, if_false]
        have hfm := fixed_misc ids n hf (n.active.set p.val true hp)
          (n.next.set p.val (Rust.max n.next[p.val] (Rust.saturating_add index 1)) hp)
          (n.matched.set p.val index hp) n.outbox
        obtain ⟨b, m', hadv, hA⟩ := advance_rel ids _ hfm
        have hfm' := fixed_adv ids _ _ hfm hA
        have hR : Recorded n { n with active := n.active.set p.val true hp, next := n.next.set p.val (Rust.max n.next[p.val] (Rust.saturating_add index 1)) hp, matched := n.matched.set p.val index hp, outbox := n.outbox } p.val hp index none :=
          ⟨rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, Or.inr ⟨rfl, by simp [Fin.lt_def] at h1; omega,
            by simp [Fin.le_def] at h2; omega, rfl⟩⟩
        simp only [hadv, pure_bind]
        cases b
        · simp only [Bool.false_eq_true, if_false, last_eq _ hfm'.layout.1, pure_bind]
          by_cases h3 : index < (lastId m'.state).index
          · simp only [h3, decide_true, if_true, replicate_eq _ _ hN hp, pure_bind]
            refine ⟨_, rfl, ?_, _, hR, hfm, m', hA, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, ?_⟩
            · exact { hfm' with layout := hfm'.layout, contig := hfm'.contig }
            · intro j
              simp only [Fin.getElem_fin, Vector.getElem_set]
              split
              · exact Or.inr rfl
              · exact Or.inl rfl
          · simp only [h3, decide_false, Bool.false_eq_true, if_false]
            exact ⟨_, rfl, hfm', _, hR, hfm, m', hA, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, fun _ => Or.inl rfl⟩
        · simp only [if_true, broadcast_eq ids m' hfm', pure_bind]
          refine ⟨_, rfl, ?_, _, hR, hfm, m', hA, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, ?_⟩
          · exact { hfm' with layout := hfm'.layout, contig := hfm'.contig }
          · intro j
            simp only [bcast, Fin.getElem_fin, Vector.getElem_ofFn]
            split
            · exact Or.inr rfl
            · exact Or.inl rfl
    · simp only [Rust.Slice.index_ok _ _ hp, pure_bind]
      by_cases h2 : index ≥ n.matched[p.val]
      · simp only [h2, decide_true, if_true]
        by_cases h3 : (Rust.checked_add index 1 == some n.next[p.val]) = true
        · have hcl : (Rust.saturating_add n.matched[p.val] 1).val ≤
              (Rust.saturating_add (lastId n.state).index 1).val := by
            rw [Rust.val_saturating_add, Rust.val_saturating_add]
            simp only [Fin.le_def, gt_iff_lt, Fin.lt_def, ge_iff_le, Nat.not_lt] at h1 h2
            simp only [Nat.min_def]
            split <;> split <;> omega
          simp only [h3, if_true, Rust.clamp_ok _ _ _ hcl, pure_bind,
            replicate_eq _ _ hN hp]
          exact ⟨_, rfl, replicated_trivial ids n hf p.val hp index _ (n.active.set p.val true hp)
            (n.next.set p.val (Rust.min (Rust.max nx (Rust.saturating_add n.matched[p.val] 1))
              (Rust.saturating_add (lastId n.state).index 1)) hp)
            (n.outbox.set p.val (some .Replicate) hp) (fun j => by
              simp only [Fin.getElem_fin, Vector.getElem_set]
              split
              · exact Or.inr rfl
              · exact Or.inl rfl)⟩
        · simp only [h3, Bool.false_eq_true, if_false]
          exact ⟨_, rfl, triv⟩
      · simp only [h2, decide_false, Bool.false_eq_true, if_false]
        exact ⟨_, rfl, triv⟩
    · exact ⟨_, rfl, triv⟩

end Jarl.Engine
