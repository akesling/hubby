import Engine.Dyn.Node

/-!
# `refresh_membership`

After any log change the node recomputes its configuration from its log and
reconciles its peer slots: every member without a slot takes the first slot
that is empty or holds an identity outside the configuration, and that slot's
vote, activity, progress and outbox are reset. A slot keeps its bookkeeping
only while it keeps its identity (`SlotKept`), so progress never moves between
identities. A leader that is no longer a voter steps down once the
configuration that removed it is committed.
-/

set_option linter.unusedSectionVars false

namespace Jarl.Engine.Dyn
open Jarl Jarl.Engine

variable {V S : Type} {MAX CAP : Nat} [Rust.Clone V] [Rust.Clone S]

/-- `follow(leader)` for any node with valid election settings. -/
theorem follow_eq' (n : DNode V S MAX CAP) (h0 : 0 < n.config.election_ticks.val)
    (h1 : n.config.election_ticks.val ≤ 2 ^ 63) (l : Option Id) :
    ∃ n', Node.follow n l = pure n' ∧
      Timers { n with role := .Follower, prevoting := none, leader := l, leader_age := (if l.isSome then 0 else n.leader_age) } n' := by
  obtain ⟨r, d, h⟩ := reset_election_eq { n with role := .Follower, prevoting := none, leader_age := (if l.isSome then 0 else n.leader_age), leader := l } h0 h1
  refine ⟨_, ?_, r, d, rfl⟩
  cases l <;> simp_all [Node.follow]

/-- Slot `i` of `n1` is slot `i` of `n`, or was reassigned from an identity
    outside `M` (or from empty) to a member `x` of `M` that had no slot, with
    its bookkeeping reset. -/
def SlotKept (M : Membership MAX) (n n1 : DNode V S MAX CAP) (i : Fin MAX) : Prop :=
  (n1.peers[i] = n.peers[i] ∧ n1.votes[i] = n.votes[i] ∧ n1.active[i] = n.active[i] ∧
    n1.next[i] = n.next[i] ∧ n1.matched[i] = n.matched[i] ∧ n1.outbox[i] = n.outbox[i]) ∨
  ((∀ y, n.peers[i] = some y → Membership.contains M y = false) ∧
    ∃ x, n1.peers[i] = some x ∧ Membership.contains M x = true ∧ (∀ j : Fin MAX, n.peers[j] ≠ some x) ∧
      n1.votes[i] = false ∧ n1.active[i] = false ∧ n1.next[i] = 1 ∧ n1.matched[i] = 0 ∧ n1.outbox[i] = none)

/-- The node after the slot loop: only the configuration and slot arrays changed. -/
def Slotted (M : Membership MAX) (n n1 : DNode V S MAX CAP) : Prop :=
  n1 = { n with membership := M, peers := n1.peers, votes := n1.votes, active := n1.active, «next» := n1.next, matched := n1.matched, outbox := n1.outbox } ∧
  (∀ i, SlotKept M n n1 i) ∧
  (∀ i j : Fin MAX, ∀ x, n1.peers[i] = some x → n1.peers[j] = some x → i = j)

/-- What `refresh_membership` does. -/
def Refresh (n n' : DNode V S MAX CAP) : Prop :=
  ∃ n1 : DNode V S MAX CAP, Slotted (memOf n.state n.bootstrap) n n1 ∧
    (∀ id, Membership.contains (memOf n.state n.bootstrap) id = true → ∃ i : Fin MAX, n1.peers[i] = some id) ∧
    let n2 : DNode V S MAX CAP := { n1 with «local» := (Rust.Iter.position n1.peers.toList (fun p => p == some n.config.id)).getD (Rust.usizeOf MAX) }
    (n' = n2 ∨
      (n.role = .Leader ∧ Membership.is_voter (memOf n.state n.bootstrap) n.config.id = false ∧
        (memAt n.state n.bootstrap (lastId n.state).index).1 ≤ n.state.hard.commit ∧
        Timers { n2 with role := .Follower, prevoting := none, leader := none } n'))

theorem flatten_mem {α : Type} (l : List (Option α)) (x : α) : x ∈ Rust.Iter.flatten l ↔ some x ∈ l := by
  simp [Rust.Iter.flatten]

theorem peers_contains (M : Membership MAX) (x : Id) (h : x ∈ Rust.Iter.flatten (Membership.peers M).toList) :
    Membership.contains M x = true := by
  rw [flatten_mem] at h
  simp only [Membership.peers, Vector.toList_map, List.mem_map] at h
  obtain ⟨o, ho, he⟩ := h
  cases o with
  | none => simp at he
  | some m =>
    simp only [Option.map_some, Option.some.injEq] at he
    subst he
    simp only [Membership.contains, List.any_eq_true, beq_iff_eq]
    exact ⟨m, by simpa [Rust.Iter.flatten] using ho, rfl⟩

theorem vec_contains_iff (v : Vector (Option Id) MAX) (x : Id) :
    v.toList.contains (some x) = true ↔ ∃ i : Fin MAX, v[i] = some x := by
  simp only [List.contains_iff_mem, List.mem_iff_getElem]
  constructor
  · rintro ⟨i, hi, he⟩; exact ⟨⟨i, by simpa using hi⟩, by simpa using he⟩
  · rintro ⟨i, he⟩; exact ⟨i.val, by simp, by simpa using he⟩

/-- One iteration of the slot loop for member `x`: keep a node that already has
    a slot for `x`, or give `x` an eligible slot `s` and reset its bookkeeping. -/
def SlotStep (x : Id) (b : DNode V S MAX CAP) (b' : ForInStep (DNode V S MAX CAP)) : Prop :=
  (b' = .yield b ∧ ∃ i : Fin MAX, b.peers[i] = some x) ∨
  ((∀ i : Fin MAX, b.peers[i] ≠ some x) ∧ ∃ s : Fin MAX,
    (∀ y, b.peers[s] = some y → Membership.contains b.membership y = false) ∧
    b' = .yield { b with peers := b.peers.set s.val (some x) s.isLt, votes := b.votes.set s.val false s.isLt, active := b.active.set s.val false s.isLt, «next» := b.next.set s.val 1 s.isLt, matched := b.matched.set s.val 0 s.isLt, outbox := b.outbox.set s.val none s.isLt })

/-- The slot loop of `refresh_membership` over members `L` of `M`. -/
theorem slot_loop (n : DNode V S MAX CAP) (M : Membership MAX) (L : List Id)
    (hL : ∀ x ∈ L, Membership.contains M x = true)
    (huniq : ∀ i j : Fin MAX, ∀ x, n.peers[i] = some x → n.peers[j] = some x → i = j)
    (f : Id → DNode V S MAX CAP → Rust.M (ForInStep (DNode V S MAX CAP)))
    (hf : ∀ x ∈ L, ∀ b b', b.membership = M → f x b = pure b' → SlotStep x b b')
    (r : DNode V S MAX CAP) (h : forIn L { n with membership := M } f = pure r) :
    Slotted M n r ∧ ∀ x ∈ L, ∃ i : Fin MAX, r.peers[i] = some x := by
  have key := forIn_pure_inv L { n with membership := M } f
    (fun k b => Slotted M n b ∧ ∀ x ∈ L.take k, ∃ i : Fin MAX, b.peers[i] = some x)
    ⟨⟨rfl, fun i => Or.inl ⟨rfl, rfl, rfl, rfl, rfl, rfl⟩, huniq⟩, by simp⟩
    (by
      intro k hk b b' ⟨⟨hshape, hkept, hu⟩, hpres⟩
      have hmem : L[k] ∈ L := List.getElem_mem hk
      have hbM : b.membership = M := by rw [hshape]
      constructor
      · intro hb
        rcases hf _ hmem b _ hbM hb with ⟨heq, i, hi⟩ | ⟨hnone, s, hel, heq⟩
        · cases heq
          refine ⟨⟨hshape, hkept, hu⟩, fun x hx => ?_⟩
          rw [List.take_add_one, List.mem_append] at hx
          rcases hx with hx | hx
          · exact hpres x hx
          · simp [List.getElem?_eq_getElem hk] at hx; subst hx; exact ⟨i, hi⟩
        · cases heq
          have hx := hL _ hmem
          -- The eligible slot held no member of `M`.
          have hsel : ∀ y, b.peers[s] = some y → Membership.contains M y = false := by
            intro y hy; rw [← hbM]; exact hel y hy
          refine ⟨⟨?_, fun i => ?_, ?_⟩, fun x hx' => ?_⟩
          · rw [hshape]
          · by_cases his : i = s
            · subst his
              right
              refine ⟨?_, L[k], by simp, hx, ?_, by simp, by simp, by simp, by simp, by simp⟩
              · intro y hy
                rcases hkept i with ⟨hp, -⟩ | ⟨-, x', hx', hcx', -⟩
                · exact hsel y (by rw [hp]; exact hy)
                · have := hsel x' hx'; rw [hcx'] at this; cases this
              · intro j hj
                rcases hkept j with ⟨hp, -⟩ | ⟨hold, -⟩
                · exact hnone j (by rw [hp]; exact hj)
                · have := hold _ hj; rw [hx] at this; cases this
            · have hne : i.val ≠ s.val := fun e => his (Fin.ext e)
              rcases hkept i with ⟨a1, a2, a3, a4, a5, a6⟩ | ⟨hold, x', h1, h2, h3, h4, h5, h6, h7, h8⟩
              · left; simp only [Fin.getElem_fin, Vector.getElem_set_ne _ _ (Ne.symm hne)] at *
                exact ⟨a1, a2, a3, a4, a5, a6⟩
              · right; simp only [Fin.getElem_fin, Vector.getElem_set_ne _ _ (Ne.symm hne)] at *
                exact ⟨hold, x', h1, h2, h3, h4, h5, h6, h7, h8⟩
          · intro i j x hi hj
            simp only [Fin.getElem_fin] at hi hj
            by_cases his : i = s <;> by_cases hjs : j = s
            · rw [his, hjs]
            · have hne : j.val ≠ s.val := fun e => hjs (Fin.ext e)
              subst his
              rw [Vector.getElem_set_self] at hi
              rw [Vector.getElem_set_ne _ _ (Ne.symm hne)] at hj
              cases hi; exact absurd hj (hnone j)
            · have hne : i.val ≠ s.val := fun e => his (Fin.ext e)
              subst hjs
              rw [Vector.getElem_set_self] at hj
              rw [Vector.getElem_set_ne _ _ (Ne.symm hne)] at hi
              cases hj; exact absurd hi (hnone i)
            · have h1 : i.val ≠ s.val := fun e => his (Fin.ext e)
              have h2 : j.val ≠ s.val := fun e => hjs (Fin.ext e)
              rw [Vector.getElem_set_ne _ _ (Ne.symm h1)] at hi
              rw [Vector.getElem_set_ne _ _ (Ne.symm h2)] at hj
              exact hu i j x hi hj
          · rw [List.take_add_one, List.mem_append] at hx'
            rcases hx' with hx' | hx'
            · obtain ⟨i, hi⟩ := hpres x hx'
              have his : i ≠ s := by
                intro e; subst e
                have := hsel x hi; rw [hL x (List.mem_of_mem_take hx')] at this; cases this
              have hne : i.val ≠ s.val := fun e => his (Fin.ext e)
              refine ⟨i, ?_⟩
              simp only [Fin.getElem_fin, Vector.getElem_set_ne _ _ (Ne.symm hne)]
              exact hi
            · simp [List.getElem?_eq_getElem hk] at hx'; subst hx'
              exact ⟨s, by simp⟩
      · intro hb
        rcases hf _ hmem b _ hbM hb with ⟨heq, -⟩ | ⟨-, s, -, heq⟩ <;> cases heq) r h
  rw [List.take_length] at key
  exact key

/-- Every member of a configuration is in its peer list. -/
theorem contains_peers (M : Membership MAX) (x : Id) (h : Membership.contains M x = true) :
    x ∈ Rust.Iter.flatten (Membership.peers M).toList := by
  rw [flatten_mem]
  simp only [Membership.contains, List.any_eq_true, beq_iff_eq] at h
  obtain ⟨m, hm, rfl⟩ := h
  simp only [Membership.peers, Vector.toList_map, List.mem_map]
  exact ⟨some m, by simpa [Rust.Iter.flatten] using hm, rfl⟩

theorem expect_pure {α : Type} (o : Option α) (msg : String) (a : α) (h : Rust.Option.expect o msg = pure a) :
    o = some a := by
  cases o with
  | none => exact absurd h (fail_ne_pure' _ _)
  | some x => exact congrArg some (Rust.pure_inj h)

/-- A position found by `Iter::position` is in bounds and satisfies the predicate. -/
theorem position_some {α : Type} (l : List α) (p : α → Bool) (s : Rust.usize) (hl : l.length < 2 ^ Rust.usizeBits)
    (h : Rust.Iter.position l p = some s) : ∃ hs : s.val < l.length, p (l[s.val]'hs) = true := by
  simp only [Rust.Iter.position, Option.map_eq_some_iff] at h
  obtain ⟨i, hi, rfl⟩ := h
  rw [List.findIdx?_eq_some_iff_getElem] at hi
  obtain ⟨hlt, hp, -⟩ := hi
  have hv : (Rust.ofNat i : Rust.usize).val = i := by
    simp only [Rust.ofNat]; exact Nat.mod_eq_of_lt (by uomega)
  refine ⟨by rw [hv]; exact hlt, ?_⟩
  simp only [hv]; exact hp

theorem refresh_rel (n n' : DNode V S MAX CAP) (hh : n.hooks = some hooksC) (hl : Layout n.state) (hc : Contig n.state)
    (hMAX : MAX < 2 ^ Rust.usizeBits)
    (h0 : 0 < n.config.election_ticks.val) (h1 : n.config.election_ticks.val ≤ 2 ^ 63)
    (huniq : ∀ i j : Fin MAX, ∀ x, n.peers[i] = some x → n.peers[j] = some x → i = j)
    (h : Node.refresh_membership n = pure n') : Refresh n n' := by
  unfold Node.refresh_membership at h
  simp only [last_eq _ hl.1, pure_bind, membership_at_eq n hh hl, memAt_last _ _ hc] at h
  obtain ⟨r, hr, h⟩ := Rust.bind_eq_pure h
  have hloop := slot_loop n (memOf n.state n.bootstrap) _ (fun x hx => peers_contains _ x hx) huniq _ (by
    intro x hx b b' hbM hb
    split at hb
    · rename_i hnc
      right
      have hnone : ∀ i : Fin MAX, b.peers[i] ≠ some x := by
        intro i hi
        have := (vec_contains_iff b.peers x).mpr ⟨i, hi⟩
        rw [this] at hnc; exact absurd hnc (by decide)
      refine ⟨hnone, ?_⟩
      obtain ⟨t3, h3, hb⟩ := Rust.bind_eq_pure hb
      have hpos := expect_pure _ _ _ h3
      obtain ⟨hs, hel⟩ := position_some _ _ _ (by simpa using hMAX) hpos
      have hsM : t3.val < MAX := by simpa using hs
      refine ⟨⟨t3.val, hsM⟩, ?_, ?_⟩
      · intro y hy
        simp only [Fin.getElem_fin] at hy
        have : (b.peers.toList[t3.val]'hs) = some y := by simpa using hy
        rw [this] at hel
        simpa using hel
      · simp only [Rust.Slice.set_ok _ _ _ hsM, pure_bind] at hb
        exact (Rust.pure_inj hb).symm
    · rename_i hnc
      left
      refine ⟨(Rust.pure_inj hb).symm, ?_⟩
      exact (vec_contains_iff b.peers x).mp (by simpa using hnc)) r hr
  obtain ⟨⟨hshape, hkept, hu⟩, hpres⟩ := hloop
  refine ⟨r, ⟨hshape, hkept, hu⟩, fun id hid => hpres id (contains_peers _ id hid), ?_⟩
  obtain ⟨P, Vo, A, Nx, Mt, O, rfl⟩ : ∃ P Vo A Nx Mt O, r = { n with membership := memOf n.state n.bootstrap, peers := P, votes := Vo, active := A, «next» := Nx, matched := Mt, outbox := O } :=
    ⟨_, _, _, _, _, _, hshape⟩
  simp only at h ⊢
  split at h
  · rename_i hcond
    simp only [Bool.and_eq_true, beq_iff_eq, Bool.not_eq_eq_eq_not, Bool.not_true] at hcond
    simp only [last_eq _ hl.1, pure_bind] at h
    generalize hL : (Rust.Iter.position P.toList fun id_2 => id_2 == some n.config.id).getD (Rust.usizeOf MAX) = loc at h ⊢
    rw [membership_at_eq { n with membership := memOf n.state n.bootstrap, peers := P, votes := Vo, active := A, «next» := Nx, matched := Mt, outbox := O, «local» := loc } hh hl] at h
    simp only [pure_bind] at h
    split at h
    · rename_i hle
      obtain ⟨m, hm, ht⟩ := follow_eq' { n with membership := memOf n.state n.bootstrap, peers := P, votes := Vo, active := A, «next» := Nx, matched := Mt, outbox := O, «local» := loc }
        h0 h1 none
      rw [hm] at h
      simp only [bind_pure] at h
      cases Rust.pure_inj h
      right
      refine ⟨hcond.1, hcond.2, by simpa using hle, ?_⟩
      simpa using ht
    · left; exact (Rust.pure_inj h).symm
  · left; exact (Rust.pure_inj h).symm

end Jarl.Engine.Dyn
