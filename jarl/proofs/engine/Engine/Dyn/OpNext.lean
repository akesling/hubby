import Engine.Dyn.Spec

/-!
# `next_message` on a dynamic node
-/

set_option linter.unusedSectionVars false

namespace Jarl.Engine.Dyn
open Jarl Jarl.Engine

variable {V S : Type} {MAX CAP : Nat} [Rust.Clone V] [Rust.Clone S]

theorem mapM_map_pure {α : Type} {n : Nat} (xs : Vector α n) :
    Vector.mapM id (xs.map (pure : α → Rust.M α)) = pure xs := by
  have := Vector.mapM_pure (m := Rust.M) (xs := xs) (fun x => x)
  simp at this
  rw [← this, Vector.mapM_map]; rfl

/-- `from_fnM` of a function that always succeeds: the vector of its results. -/
theorem from_fnM_pure {α : Type} (n : Nat) (g : Rust.usize → α) :
    Rust.Slice.from_fnM n (fun i => pure (g i)) = pure (Vector.ofFn fun i : Fin n => g (Rust.ofNat i.val)) := by
  unfold Rust.Slice.from_fnM
  have : (Vector.ofFn fun i : Fin n => (pure (g (Rust.ofNat i.val)) : Rust.M α)) =
      (Vector.ofFn fun i : Fin n => g (Rust.ofNat i.val)).map pure := by
    ext i hi; simp
  rw [this, mapM_map_pure]

omit [Rust.Clone V] in
theorem dentry_map_id (o : Option (DEntry V MAX)) :
    Option.map (fun e => ({ id := e.id, value := e.value } : DEntry V MAX)) o = o := by
  cases o <;> rfl

omit [Rust.Clone V] [Rust.Clone S] in
theorem eta1 (n : DNode V S MAX CAP) (hd : n.dirty = false) :
    ∀ X, ({ n with outbox := X, dirty := false } : DNode V S MAX CAP) = { n with outbox := X } := by
  intro X; cases n; cases hd; rfl

omit [Rust.Clone V] [Rust.Clone S] in
theorem eta2 (n : DNode V S MAX CAP) (hd : n.dirty = false) :
    ({ n with extra_reply := none, dirty := false } : DNode V S MAX CAP) = { n with extra_reply := none } := by
  cases n; cases hd; rfl

omit [Rust.Clone V] [Rust.Clone S] in
/-- Reading the entry at `a + c` for an offset `c` of value `o`. -/
theorem add_get (s : DState V S MAX CAP) (a c : Rust.u64) (o : Nat) (hc : c.val = o) :
    (Rust.checked_add a c).bind (fun i => State.get s i) =
      if h : a.val + o < 2 ^ 64 then State.get s ⟨a.val + o, h⟩ else none := by
  subst hc; rw [Rust.checked_add_eq]; split <;> rfl

theorem next_message_rel' (n : DNode V S MAX CAP) (hp : Pre n) (r : Option (DEnv V S MAX)) (n' : DNode V S MAX CAP)
    (h : Node.next_message n = pure (r, n')) : NextD n r n' := by
  have hl := hp.layout
  have hN : MAX < 2 ^ Rust.usizeBits := hp.n_lt
  unfold Node.next_message at h
  by_cases hd : n.dirty = true
  · simp only [hd, if_true] at h
    obtain ⟨rfl, rfl⟩ := Prod.mk.inj (Rust.pure_inj h)
    exact Or.inl ⟨rfl, Or.inl rfl⟩
  have hd' : n.dirty = false := by simpa using hd
  have e1 := eta1 n hd'
  have e2 := eta2 n hd'
  simp only [hd', Bool.false_eq_true, if_false, Rust.Iter.position] at h
  cases hfind : List.findIdx? (fun o => o.isSome) n.outbox.toList with
  | none =>
    have hall : ∀ j : Fin MAX, n.outbox[j] = none := by
      intro j
      have := List.findIdx?_eq_none_iff.mp hfind n.outbox[j] (by simp)
      simpa using this
    simp only [hfind, Option.map_none, e2] at h
    cases hx : n.extra_reply with
    | none =>
      simp only [hx] at h
      obtain ⟨rfl, rfl⟩ := Prod.mk.inj (Rust.pure_inj h)
      exact Or.inl ⟨rfl, Or.inr (Or.inl ⟨hd', hall, rfl⟩)⟩
    | some p =>
      obtain ⟨to, o⟩ := p
      simp only [hx, pure_bind] at h
      cases o with
      | Vote =>
        simp only [last_eq _ hl.1, pure_bind] at h
        obtain ⟨rfl, rfl⟩ := Prod.mk.inj (Rust.pure_inj h)
        exact Or.inr ⟨_, rfl, hd', rfl, Or.inr ⟨_, to, hall, hx, rfl, rfl, BuiltD.vote none⟩⟩
      | Voted g =>
        obtain ⟨rfl, rfl⟩ := Prod.mk.inj (Rust.pure_inj h)
        exact Or.inr ⟨_, rfl, hd', rfl, Or.inr ⟨_, to, hall, hx, rfl, rfl, BuiltD.voted none g⟩⟩
      | PreVote c =>
        simp only [last_eq _ hl.1, pure_bind] at h
        obtain ⟨rfl, rfl⟩ := Prod.mk.inj (Rust.pure_inj h)
        exact Or.inr ⟨_, rfl, hd', rfl, Or.inr ⟨_, to, hall, hx, rfl, rfl, BuiltD.prevote none c⟩⟩
      | PreVoted c g =>
        obtain ⟨rfl, rfl⟩ := Prod.mk.inj (Rust.pure_inj h)
        exact Or.inr ⟨_, rfl, hd', rfl, Or.inr ⟨_, to, hall, hx, rfl, rfl, BuiltD.prevoted none c g⟩⟩
      | Replicated i rj =>
        obtain ⟨rfl, rfl⟩ := Prod.mk.inj (Rust.pure_inj h)
        exact Or.inr ⟨_, rfl, hd', rfl, Or.inr ⟨_, to, hall, hx, rfl, rfl, BuiltD.replicated none i rj⟩⟩
      | Replicate =>
        have hf : Rust.Slice.index n.next (Rust.usizeOf MAX) = Rust.fail "index out of bounds" := by
          simp [Rust.Slice.index, Rust.val_usizeOf _ (by simpa using hN)]
        simp only [hf] at h
        obtain ⟨a, ha, -⟩ := Rust.bind_eq_pure h
        exact absurd ha (fail_ne_pure' _ _)
  | some j =>
    obtain ⟨hjl, hjp, hbefore⟩ := List.findIdx?_eq_some_iff_getElem.mp hfind
    have hj : j < MAX := by simpa using hjl
    have hv : (Rust.ofNat j : Rust.usize).val = j := by
      simp [Rust.ofNat]; uomega
    obtain ⟨o, ho⟩ : ∃ o, n.outbox[j] = some o := by
      simp only [Vector.getElem_toList] at hjp
      exact Option.isSome_iff_exists.mp hjp
    have hprev : ∀ i : Fin MAX, i.val < (⟨j, hj⟩ : Fin MAX).val → n.outbox[i] = none := by
      intro i hi
      have := hbefore i.val hi
      simpa using this
    simp only [hfind, Option.map_some, Rust.Slice.index_ok _ _ (hv ▸ hj), Rust.Slice.set_ok _ _ _ (hv ▸ hj),
      pure_bind, hv, ho, e1] at h
    cases hpe : n.peers[j] with
    | none =>
      simp only [hpe] at h
      obtain ⟨rfl, rfl⟩ := Prod.mk.inj (Rust.pure_inj h)
      exact Or.inl ⟨rfl, Or.inl rfl⟩
    | some to =>
    simp only [hpe] at h
    have ho' : n.outbox[(⟨j, hj⟩ : Fin MAX)] = some o := ho
    have hpe' : n.peers[(⟨j, hj⟩ : Fin MAX)] = some to := hpe
    cases o with
    | Vote =>
      simp only [last_eq _ hl.1, pure_bind] at h
      obtain ⟨rfl, rfl⟩ := Prod.mk.inj (Rust.pure_inj h)
      exact Or.inr ⟨_, rfl, hd', rfl, Or.inl ⟨⟨j, hj⟩, _, to, hprev, ho', hpe', rfl, rfl, BuiltD.vote _⟩⟩
    | Voted g =>
      obtain ⟨rfl, rfl⟩ := Prod.mk.inj (Rust.pure_inj h)
      exact Or.inr ⟨_, rfl, hd', rfl, Or.inl ⟨⟨j, hj⟩, _, to, hprev, ho', hpe', rfl, rfl, BuiltD.voted _ g⟩⟩
    | PreVote c =>
      simp only [last_eq _ hl.1, pure_bind] at h
      obtain ⟨rfl, rfl⟩ := Prod.mk.inj (Rust.pure_inj h)
      exact Or.inr ⟨_, rfl, hd', rfl, Or.inl ⟨⟨j, hj⟩, _, to, hprev, ho', hpe', rfl, rfl, BuiltD.prevote _ c⟩⟩
    | PreVoted c g =>
      obtain ⟨rfl, rfl⟩ := Prod.mk.inj (Rust.pure_inj h)
      exact Or.inr ⟨_, rfl, hd', rfl, Or.inl ⟨⟨j, hj⟩, _, to, hprev, ho', hpe', rfl, rfl, BuiltD.prevoted _ c g⟩⟩
    | Replicated i rj =>
      obtain ⟨rfl, rfl⟩ := Prod.mk.inj (Rust.pure_inj h)
      exact Or.inr ⟨_, rfl, hd', rfl, Or.inl ⟨⟨j, hj⟩, _, to, hprev, ho', hpe', rfl, rfl, BuiltD.replicated _ i rj⟩⟩
    | Replicate =>
      have drop : ∀ (P : Prop), P → r = none → n' = { n with outbox := n.outbox.set j none hj } →
          (P → (n.next[j].val ≤ n.state.base.index.val ∧ n.state.snapshot = none) ∨
            (n.state.base.index.val < n.next[j].val ∧ idAt n.state (n.next[j].val - 1) = none)) → NextD n r n' := by
        intro P hP hr hn hw
        exact Or.inl ⟨hr, Or.inr (Or.inr ⟨hd', ⟨j, hj⟩, to, hprev, ho', hpe', hn, hw hP⟩)⟩
      by_cases hle : n.next[j] ≤ n.state.base.index
      · simp only [hle, decide_true, if_true] at h
        cases hs : n.state.snapshot with
        | none =>
          simp only [hs] at h
          obtain ⟨rfl, rfl⟩ := Prod.mk.inj (Rust.pure_inj h)
          exact drop _ hs rfl rfl (fun hs => Or.inl ⟨Fin.le_def.mp hle, hs⟩)
        | some sn =>
          simp only [hs] at h
          obtain ⟨rfl, rfl⟩ := Prod.mk.inj (Rust.pure_inj h)
          exact Or.inr ⟨_, rfl, hd', rfl, Or.inl ⟨⟨j, hj⟩, _, to, hprev, ho', hpe', rfl, rfl,
            BuiltD.install _ sn (Fin.le_def.mp hle) hs⟩⟩
      · have hlt : n.state.base.index.val < n.next[j].val := by
          rw [Fin.le_def] at hle; omega
        have hk : n.hooks.isSome = true := by simp [hp.hooks]
        simp only [hle, decide_false, Bool.false_eq_true, if_false, hk, if_true,
          Rust.sub_ok _ _ (show (1 : Rust.u64).val ≤ n.next[j].val by simp; omega), pure_bind,
          id_at_eq _ hl, dentry_map_id] at h
        have h1 : ((1 : Rust.u64) : Nat) = 1 := rfl
        simp only [h1] at h
        cases hid : idAt n.state (n.next[j].val - 1) with
        | none =>
          simp only [hid] at h
          split at h <;>
          · obtain ⟨rfl, rfl⟩ := Prod.mk.inj (Rust.pure_inj h)
            exact drop _ hid rfl rfl (fun hid => Or.inr ⟨hlt, hid⟩)
        | some prev =>
          simp only [hid] at h
          split at h
          · simp only [from_fnM_pure, pure_bind] at h
            obtain ⟨rfl, rfl⟩ := Prod.mk.inj (Rust.pure_inj h)
            refine Or.inr ⟨_, rfl, hd', rfl, Or.inl ⟨⟨j, hj⟩, _, to, hprev, ho', hpe', rfl, rfl,
              BuiltD.appendBatch _ prev _ hlt hid ?_⟩⟩
            intro o ho
            simp only [Vector.getElem_ofFn, Fin.getElem_fin]
            simp only [MAX_APPEND_ENTRIES] at ho
            refine add_get _ _ _ o ?_
            revert o
            decide
          · obtain ⟨rfl, rfl⟩ := Prod.mk.inj (Rust.pure_inj h)
            exact Or.inr ⟨_, rfl, hd', rfl, Or.inl ⟨⟨j, hj⟩, _, to, hprev, ho', hpe', rfl, rfl,
              BuiltD.append _ prev hlt hid⟩⟩

end Jarl.Engine.Dyn
