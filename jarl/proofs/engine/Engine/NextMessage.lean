import Engine.NodeOps

/-!
# `next_message`: materializing one outgoing descriptor

A clean node takes the first pending descriptor and builds its message from
the current checkpoint. Failed builds drop the descriptor.
-/

namespace Jarl.Engine
open Jarl

variable {V S : Type} {N CAP : Nat}

/-- The message `next_message` builds from descriptor `o` for peer slot `k`. -/
inductive Built (n : Node V S N CAP) (k : Fin N) : Outbound → Message V S → Prop
  | vote : Built n k .Vote (.Vote n.state.hard.term (lastId n.state))
  | voted (g : Bool) : Built n k (.Voted g) (.Voted n.state.hard.term g)
  | replicated (i : Rust.u64) (r : Option Rejection) :
      Built n k (.Replicated i r) (.Replicated n.state.hard.term i r)
  | prevote (c : Rust.u64) : Built n k (.PreVote c) (.PreVote c (lastId n.state))
  | prevoted (c : Rust.u64) (g : Bool) : Built n k (.PreVoted c g) (.PreVoted n.state.hard.term c g)
  | install (s : Snapshot S) : n.next[k].val ≤ n.state.base.index.val → n.state.snapshot = some s →
      Built n k .Replicate (.Install n.state.hard.term s)
  | append (prev : LogId) : n.state.base.index.val < n.next[k].val →
      idAt n.state (n.next[k].val - 1) = some prev →
      Built n k .Replicate (.Append n.state.hard.term prev (State.get n.state n.next[k]) n.state.hard.commit)

theorem pure_inj_M {α : Type} {a b : α} (h : (pure a : Rust.M α) = pure b) : a = b := by
  simp only [pure, ExceptT.pure, ExceptT.mk] at h
  injection h with h; injection h

theorem fail_ne_pure {α : Type} (s : String) (b : α) : (Rust.fail s : Rust.M α) ≠ pure b := by
  simp [Rust.fail, throw, throwThe, MonadExceptOf.throw, pure, ExceptT.pure, ExceptT.mk]
  intro h; cases h

theorem entry_map_id (o : Option (Entry V)) :
    Option.map (fun e => ({ id := e.id, value := e.value } : Entry V)) o = o := by
  cases o <;> rfl

theorem nm_none (ids : Vector Id N) (n : Node V S N CAP) (hf : Fixed ids n) (hd : n.dirty = false)
    (j : Nat) (hj : j < N) (r : Option (Envelope V S)) (n' : Node V S N CAP)
    (h : (pure (none, { n with outbox := n.outbox.set j none hj, dirty := false }) : Rust.M _) = pure (r, n')) :
    n' = { n with outbox := n'.outbox } ∧ Fixed ids n' ∧
      (∀ j : Fin N, n'.outbox[j] = n.outbox[j] ∨ n'.outbox[j] = none) ∧
      ∀ env, r = some env → n.dirty = false ∧ ∃ (k : Fin N) (o : Outbound),
        n.outbox[k] = some o ∧ n'.outbox = n.outbox.set k.val none k.isLt ∧
        env.from = n.config.id ∧ env.to = ids[k] ∧ Built n k o env.message := by
  obtain ⟨rfl, rfl⟩ := Prod.mk.inj (pure_inj_M h)
  refine ⟨by cases n; simp_all, { hf with layout := hf.layout, contig := hf.contig }, ?_, fun env he => by cases he⟩
  intro i
  simp only [Fin.getElem_fin, Vector.getElem_set]
  split <;> simp

theorem nm_some (ids : Vector Id N) (n : Node V S N CAP) (hf : Fixed ids n) (hd : n.dirty = false)
    (j : Nat) (hj : j < N) (o : Outbound) (ho : n.outbox[j] = some o) (msg : Message V S)
    (hb : Built n ⟨j, hj⟩ o msg) (r : Option (Envelope V S)) (n' : Node V S N CAP)
    (h : (pure (some ({ «from» := n.config.id, to := ids[j], message := msg } : Envelope V S),
      { n with outbox := n.outbox.set j none hj, dirty := false }) : Rust.M _) = pure (r, n')) :
    n' = { n with outbox := n'.outbox } ∧ Fixed ids n' ∧
      (∀ j : Fin N, n'.outbox[j] = n.outbox[j] ∨ n'.outbox[j] = none) ∧
      ∀ env, r = some env → n.dirty = false ∧ ∃ (k : Fin N) (o : Outbound),
        n.outbox[k] = some o ∧ n'.outbox = n.outbox.set k.val none k.isLt ∧
        env.from = n.config.id ∧ env.to = ids[k] ∧ Built n k o env.message := by
  obtain ⟨rfl, rfl⟩ := Prod.mk.inj (pure_inj_M h)
  refine ⟨by cases n; simp_all, { hf with layout := hf.layout, contig := hf.contig }, ?_, ?_⟩
  · intro i
    simp only [Fin.getElem_fin, Vector.getElem_set]
    split <;> simp
  · intro env he
    cases he
    exact ⟨hd, ⟨j, hj⟩, o, ho, rfl, rfl, rfl, hb⟩

/-- `next_message` only takes descriptors; a message comes from a clean node's
    first pending descriptor, built from its checkpoint. -/
theorem next_message_rel (ids : Vector Id N) (n : Node V S N CAP) (hf : Fixed ids n)
    (r : Option (Envelope V S)) (n' : Node V S N CAP) (h : Node.next_message n = pure (r, n')) :
    n' = { n with outbox := n'.outbox } ∧ Fixed ids n' ∧
      (∀ j : Fin N, n'.outbox[j] = n.outbox[j] ∨ n'.outbox[j] = none) ∧
      ∀ env, r = some env → n.dirty = false ∧ ∃ (k : Fin N) (o : Outbound),
        n.outbox[k] = some o ∧ n'.outbox = n.outbox.set k.val none k.isLt ∧
        env.from = n.config.id ∧ env.to = ids[k] ∧ Built n k o env.message := by
  have hN : N < 2 ^ 64 := by have := hf.n_lt; omega
  unfold Node.next_message at h
  by_cases hd : n.dirty = true
  · simp only [hd, if_true] at h
    obtain ⟨rfl, rfl⟩ := Prod.mk.inj (pure_inj_M h)
    exact ⟨rfl, hf, fun j => Or.inl rfl, fun env he => by cases he⟩
  simp only [hd, Bool.false_eq_true, if_false, Rust.Iter.position] at h
  cases hfind : List.findIdx? (fun o => o.isSome) n.outbox.toList with
  | none =>
    simp only [hfind, Option.map_none, hf.extra] at h
    obtain ⟨rfl, rfl⟩ := Prod.mk.inj (pure_inj_M h)
    have hx := hf.extra
    exact ⟨by cases n; simp_all, { hf with extra := rfl, layout := hf.layout, contig := hf.contig }, fun j => Or.inl rfl,
      fun env he => by cases he⟩
  | some j =>
    obtain ⟨hjl, hjp, -⟩ := List.findIdx?_eq_some_iff_getElem.mp hfind
    have hj : j < N := by simpa using hjl
    have hv : (Rust.ofNat j : Rust.usize).val = j := by
      simp [Rust.ofNat]; omega
    obtain ⟨o, ho⟩ : ∃ o, n.outbox[j] = some o := by
      simp only [Vector.getElem_toList] at hjp
      exact Option.isSome_iff_exists.mp hjp
    have hpe : n.peers[j] = some ids[j] := by simp [hf.peers]
    simp only [hfind, Option.map_some, Rust.Slice.index_ok _ _ (hv ▸ hj), Rust.Slice.set_ok _ _ _ (hv ▸ hj),
      pure_bind, hv, hpe, ho] at h
    have hd' : n.dirty = false := by simpa using hd
    cases o with
    | Vote =>
      simp only [last_eq _ hf.layout.1, pure_bind] at h
      exact nm_some ids n hf hd' j hj _ ho _ (Built.vote) r n' h
    | Voted g => exact nm_some ids n hf hd' j hj _ ho _ (Built.voted g) r n' h
    | PreVote c =>
      simp only [last_eq _ hf.layout.1, pure_bind] at h
      exact nm_some ids n hf hd' j hj _ ho _ (Built.prevote c) r n' h
    | PreVoted c g => exact nm_some ids n hf hd' j hj _ ho _ (Built.prevoted c g) r n' h
    | Replicated i rj => exact nm_some ids n hf hd' j hj _ ho _ (Built.replicated i rj) r n' h
    | Replicate =>
      by_cases hle : n.next[j] ≤ n.state.base.index
      · simp only [hle, decide_true, if_true] at h
        cases hs : n.state.snapshot with
        | none =>
          simp only [hs] at h
          exact nm_none ids n hf hd' j hj r n' h
        | some sn =>
          simp only [hs] at h
          exact nm_some ids n hf hd' j hj _ ho _ (Built.install sn (Fin.le_def.mp hle) hs) r n' h
      · have hlt : n.state.base.index.val < n.next[j].val := by
          rw [Fin.le_def] at hle; omega
        have hk : n.hooks.isSome = false := by simp [hf.hooks]
        simp only [hle, decide_false, Bool.false_eq_true, if_false, hk,
          Rust.sub_ok _ _ (show (1 : Rust.u64).val ≤ n.next[j].val by simp; omega), pure_bind,
          id_at_eq _ hf.layout, entry_map_id] at h
        have h1 : ((1 : Rust.u64) : Nat) = 1 := rfl
        simp only [h1] at h
        cases hid : idAt n.state (n.next[j].val - 1) with
        | none =>
          simp only [hid] at h
          exact nm_none ids n hf hd' j hj r n' h
        | some prev =>
          simp only [hid] at h
          exact nm_some ids n hf hd' j hj _ ho _ (Built.append prev hlt hid) r n' h

end Jarl.Engine
