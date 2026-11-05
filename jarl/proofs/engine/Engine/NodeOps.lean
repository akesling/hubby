import Engine.Fixed

/-!
# Node helpers of the fixed engine

`Fixed ids n` collects the facts every node of a fixed cluster of distinct
`ids` satisfies; under it each internal helper of `Node` has an explicit
result. Timer values (`random`, `election_deadline`) are left existential:
safety does not depend on them.
-/

namespace Jarl.Engine
open Jarl

variable {V S : Type} {N CAP : Nat} [Rust.Clone V] [Rust.Clone S]

/-- Facts of every node of a fixed cluster of the distinct identities `ids`. -/
structure Fixed (ids : Vector Id N) (n : Node V S N CAP) : Prop where
  n_pos : 0 < N
  n_lt : N < 2 ^ (Rust.usizeBits - 1)
  cap_pos : 0 < CAP
  cap_lt : CAP < 2 ^ (Rust.usizeBits - 1)
  nodup : ids.toList.Nodup
  hooks : n.hooks = none
  members : n.config.members = ids
  membership : n.membership = stable ids
  bootstrap : n.bootstrap = stable ids
  peers : n.peers = ids.map some
  local_lt : n.local.val < N
  local_id : ids[n.local.val]'local_lt = n.config.id
  heartbeat : 0 < n.config.heartbeat_ticks.val
  election : n.config.heartbeat_ticks.val < n.config.election_ticks.val
  election_le : n.config.election_ticks.val ≤ 2 ^ 63
  extra : n.extra_reply = none
  prevoting : n.prevoting = none
  layout : Layout n.state
  contig : Contig n.state

theorem add_mod_lt {e x : Nat} (h0 : 0 < e) (h1 : e ≤ 2 ^ 63) : e + x % e < 2 ^ 64 := by
  have := Nat.mod_lt x h0; omega

/-- `reset_election` only redraws the timer. -/
theorem reset_election_eq (n : Node V S N CAP)
    (h0 : 0 < n.config.election_ticks.val) (h1 : n.config.election_ticks.val ≤ 2 ^ 63) :
    ∃ r d, Node.reset_election n = pure { n with random := r, election_deadline := d, elapsed := 0 } := by
  simp only [Node.reset_election]
  rw [Rust.rem_ok _ _ (by omega)]
  simp only [pure_bind]
  rw [Rust.add_ok _ _ (add_mod_lt h0 h1)]
  exact ⟨_, _, rfl⟩

/-- The node after redrawing timers: only `random`, `election_deadline` and `elapsed` differ. -/
def Timers (n n' : Node V S N CAP) : Prop :=
  ∃ r d, n' = { n with random := r, election_deadline := d, elapsed := 0 }

theorem reset_timers (ids : Vector Id N) (n : Node V S N CAP) (hf : Fixed ids n) :
    ∃ n', Node.reset_election n = pure n' ∧ Timers n n' := by
  obtain ⟨r, d, h⟩ := reset_election_eq n (by have := hf.heartbeat; have := hf.election; omega) hf.election_le
  exact ⟨_, h, r, d, rfl⟩

/-- `follow(leader)`: become a follower and redraw the timer. -/
theorem follow_eq (ids : Vector Id N) (n : Node V S N CAP) (hf : Fixed ids n) (l : Option Id) :
    ∃ n', Node.follow n l = pure n' ∧
      Timers { n with role := .Follower, prevoting := none, leader := l, leader_age := (if l.isSome then 0 else n.leader_age) } n' := by
  have h0 : 0 < n.config.election_ticks.val := by have := hf.heartbeat; have := hf.election; omega
  obtain ⟨r, d, h⟩ := reset_election_eq { n with role := .Follower, prevoting := none, leader_age := (if l.isSome then 0 else n.leader_age), leader := l } h0 hf.election_le
  refine ⟨_, ?_, r, d, rfl⟩
  cases l <;> simp_all [Node.follow]

/-- `send` to a peer slot overwrites that slot's pending descriptor. -/
theorem send_eq (n : Node V S N CAP) (p : Rust.usize) (o : Outbound) (hN : N < 2 ^ Rust.usizeBits) (hp : p.val < N) :
    Node.send n p o = pure { n with outbox := n.outbox.set p.val (some o) hp } := by
  have : p ≠ Rust.usizeOf N := fun e => by
    have := congrArg Fin.val e; rw [Rust.val_usizeOf _ hN] at this; omega
  simp [Node.send, this, Rust.Slice.set_ok _ _ _ hp]

theorem reply_eq (n : Node V S N CAP) (p : Rust.usize) (i : Rust.u64) (r : Option Rejection)
    (hN : N < 2 ^ Rust.usizeBits) (hp : p.val < N) :
    Node.reply n p i r = pure { n with outbox := n.outbox.set p.val (some (.Replicated i r)) hp } := by
  simp [Node.reply, send_eq n p _ hN hp]

theorem replicate_eq (n : Node V S N CAP) (p : Rust.usize) (hN : N < 2 ^ Rust.usizeBits) (hp : p.val < N) :
    Node.replicate n p = pure { n with outbox := n.outbox.set p.val (some .Replicate) hp } := by
  simp [Node.replicate, send_eq n p _ hN hp]

theorem membership_at_fixed (ids : Vector Id N) (n : Node V S N CAP) (hf : Fixed ids n) (i : Rust.u64) :
    Node.membership_at n i = pure (0, stable ids) := by
  simp [Node.membership_at, hf.hooks, hf.bootstrap]

omit [Rust.Clone V] [Rust.Clone S] in
theorem local_position (ids : Vector Id N) (n : Node V S N CAP) (hf : Fixed ids n) :
    Rust.Iter.position (ids.map some).toList (fun p => p == some n.config.id) = some n.local := by
  have hl := hf.local_lt
  have hnd := hf.nodup
  simp only [Rust.Iter.position, Vector.toList_map]
  have hfind : List.findIdx? (fun p => p == some n.config.id) (ids.toList.map some) = some n.local.val := by
    rw [List.findIdx?_eq_some_iff_getElem]
    refine ⟨by simp; omega, ?_, ?_⟩
    · simp [← hf.local_id]
    · intro j hj
      simp only [List.getElem_map, beq_iff_eq, Option.some.injEq, ← hf.local_id]
      intro he
      have : ids.toList[j]'(by simp; omega) = ids.toList[n.local.val]'(by simp; omega) := by simpa using he
      have := (List.getElem_inj hnd).mp this
      omega
  rw [hfind]
  simp only [Option.map_some, Option.some.injEq, Rust.ofNat]
  apply Fin.ext; simp only; exact Nat.mod_eq_of_lt n.local.isLt

/-- In the fixed engine `refresh_membership` changes nothing. -/
theorem refresh_fixed (ids : Vector Id N) (n : Node V S N CAP) (hf : Fixed ids n) :
    Node.refresh_membership n = pure n := by
  unfold Node.refresh_membership
  simp only [last_eq _ hf.layout.1, pure_bind, membership_at_fixed ids n hf]
  have hn : ({ n with membership := stable ids } : Node V S N CAP) = n := by
    rw [← hf.membership]
  rw [hn]
  have hflat : ∀ l : List Id, Rust.Iter.flatten (l.map some) = l := by
    intro l; induction l with
    | nil => rfl
    | cons x xs ih => simp [Rust.Iter.flatten] at ih ⊢
  have hpeers : Rust.Iter.flatten (Membership.peers (stable ids)).toList = ids.toList := by
    rw [stable_peers, Vector.toList_map, hflat]
  have hpeers' : Rust.Iter.flatten (Membership.peers n.membership).toList = ids.toList := by
    rw [hf.membership, hpeers]
  first | rw [hpeers] | rw [hpeers']
  refine Rust.forIn_bind_inv _ _ _ _ _ (fun _ b => b = n) rfl ?_ ?_
  · intro i hi b hb
    rw [hb]
    refine ⟨n, ?_, rfl⟩
    have hi' : i < N := by simpa using hi
    have hc : some (ids[i]'hi') ∈ n.peers := by
      rw [hf.peers]; simp
    simp [hc]
  · intro b hb
    rw [hb]
    have hpos := local_position ids n hf
    rw [← hf.peers] at hpos
    have hv : Membership.is_voter n.membership n.config.id = true := by
      rw [hf.membership, stable_is_voter, ← hf.local_id]; simp
    simp only [hpos, Option.getD_some, hv, Bool.not_true, Bool.and_false, Bool.false_eq_true, if_false]

/-- The slot of a member identity. -/
theorem position_member (ids : Vector Id N) (hnd : ids.toList.Nodup) (j : Nat) (hj : j < N) :
    Rust.Iter.position (ids.map some).toList (fun p => p == some (ids[j]'hj)) = some (Rust.ofNat j) := by
  simp only [Rust.Iter.position, Vector.toList_map]
  have hfind : List.findIdx? (fun p => p == some (ids[j]'hj)) (ids.toList.map some) = some j := by
    rw [List.findIdx?_eq_some_iff_getElem]
    refine ⟨by simp; omega, by simp, ?_⟩
    intro i hi
    simp only [List.getElem_map, beq_iff_eq, Option.some.injEq]
    intro he
    have : ids.toList[i]'(by simp; omega) = ids.toList[j]'(by simp; omega) := by simpa using he
    have := (List.getElem_inj hnd).mp this
    omega
  rw [hfind]; rfl

theorem ids_filter_count (ids : Vector Id N) (g : Id → Bool) (h : Fin N → Bool)
    (hg : ∀ j : Fin N, g ids[j] = h j) :
    (ids.toList.filter g).length = (List.finRange N).countP h := by
  have : ids.toList = (List.finRange N).map (fun j => ids[j]) := by
    apply List.ext_getElem <;> simp
  rw [this, List.filter_map, List.length_map, List.countP_eq_length_filter]
  congr 1
  apply List.filter_congr
  intro j _; exact hg j

/-- `election_quorum`: a strict majority of slots granted a vote. -/
theorem election_quorum_eq (ids : Vector Id N) (n : Node V S N CAP) (hf : Fixed ids n) :
    Node.election_quorum n = pure (decide (N / 2 < (List.finRange N).countP (fun j => n.votes[j]))) := by
  unfold Node.election_quorum
  simp only [hf.membership]
  rw [quorum_stable ids (by have := hf.n_lt; uomega) _ (fun id => match Rust.Iter.position (ids.map some).toList
      (fun p => p == some id) with | some j => n.votes[j.val]! | none => false)]
  · rw [ids_filter_count ids _ (fun j => n.votes[j])]
    intro j
    show (match Rust.Iter.position (ids.map some).toList (fun p => p == some (ids[j.val]'j.isLt)) with
      | some j => n.votes[j.val]! | none => false) = n.votes[j]
    rw [position_member ids hf.nodup j.val j.isLt]
    simp (disch := (have := hf.n_lt; uomega)) [Rust.ofNat, Nat.mod_eq_of_lt]
  · intro id hid
    obtain ⟨j, hj, rfl⟩ := List.getElem_of_mem hid
    have hj' : j < N := by simpa using hj
    simp only [hf.peers]
    have hp := position_member ids hf.nodup j hj'
    simp only [Vector.getElem_toList] at hp ⊢
    rw [hp]
    have hv : (Rust.ofNat j : Rust.usize).val = j := by
      simp [Rust.ofNat]; have := hf.n_lt; uomega
    simp only [Rust.Option.is_some_andM]
    rw [Rust.Slice.index_ok _ _ (by rw [hv]; exact hj')]
    simp [hv, hj']

/-- Outbox descriptors queued for every peer slot other than the node's own. -/
def bcast (n : Node V S N CAP) : Node V S N CAP :=
  { n with outbox := Vector.ofFn fun j => if j.val ≠ n.local.val then some .Replicate else n.outbox[j] }

theorem range_get (N : Nat) (hN : N < 2 ^ Rust.usizeBits) (k : Nat) (hk : k < (Rust.Iter.range 0 (Rust.usizeOf N)).length) :
    (Rust.Iter.range 0 (Rust.usizeOf N))[k] = Rust.ofNat k ∧ k < N := by
  simp [Rust.Iter.range, Rust.val_usizeOf _ hN] at hk ⊢; omega

theorem broadcast_eq (ids : Vector Id N) (n : Node V S N CAP) (hf : Fixed ids n) :
    Node.broadcast n = pure (bcast n) := by
  have hN : N < 2 ^ Rust.usizeBits := by have := hf.n_lt; uomega
  unfold Node.broadcast
  simp only [bind_pure]
  refine Rust.forIn_eq_inv _ _ _ _
    (fun k b => b = { n with outbox := Vector.ofFn fun j =>
      if j.val < k ∧ j.val ≠ n.local.val then some .Replicate else n.outbox[j] }) ?_ ?_ ?_
  · have : (Vector.ofFn fun j : Fin N =>
        if j.val < 0 ∧ j.val ≠ n.local.val then some Outbound.Replicate else n.outbox[j]) = n.outbox := by
      ext j hj; simp
    rw [this]
  · intro k hk b hb
    obtain ⟨hget, hkN⟩ := range_get N hN k hk
    rw [hget]
    have hv : (Rust.ofNat k : Rust.usize).val = k := by simp [Rust.ofNat]; uomega
    rw [hb]
    by_cases hkl : k = n.local.val
    · refine ⟨_, ?_, rfl⟩
      have : (Rust.ofNat k : Rust.usize) = n.local := Fin.ext (by rw [hv, hkl])
      simp only [this, bne_self_eq_false, Bool.false_eq_true, if_false, pure_bind]
      congr 3
      ext j hj
      simp only [Vector.getElem_ofFn]
      split <;> split <;> first | rfl | omega
    · refine ⟨_, ?_, rfl⟩
      have hne : (Rust.ofNat k : Rust.usize) ≠ n.local := fun e => hkl (by rw [← hv, e])
      have hp : (Rust.ofNat k : Rust.usize).val < N := by rw [hv]; exact hkN
      have hcont : Rust.Option.is_some_and n.peers[k] (fun id => Membership.contains n.membership id) = true := by
        rw [hf.peers, hf.membership]; simp [stable_contains]
      simp only [bne_iff_ne, ne_eq, hne, not_false_eq_true, if_true, Rust.Slice.index_ok _ _ hp,
        pure_bind, hv, hcont, replicate_eq _ _ hN hp]
      congr 3
      ext j hj
      simp only [Vector.getElem_set, Vector.getElem_ofFn]
      split
      · rename_i h; subst h; simp [hkl]
      · split <;> split <;> first | rfl | omega
  · intro b hb
    rw [hb]; unfold bcast
    congr 1
    ext j hj
    simp [Rust.Iter.range, Rust.val_usizeOf _ hN]

/-- Raise the commit index (a pending durable change). -/
def commitTo (n : Node V S N CAP) (i : Rust.u64) : Node V S N CAP :=
  if n.state.hard.commit < i then
    { n with state := { n.state with hard := { n.state.hard with commit := i } }, dirty := true }
  else n

omit [Rust.Clone V] [Rust.Clone S] in
theorem fixed_hard (ids : Vector Id N) (n : Node V S N CAP) (hf : Fixed ids n) (h : HardState) (d : Bool) :
    Fixed ids { n with state := { n.state with hard := h }, dirty := d } :=
  { hf with layout := hf.layout, contig := hf.contig }

theorem commit_to_eq (ids : Vector Id N) (n : Node V S N CAP) (hf : Fixed ids n) (i : Rust.u64) :
    Node.commit_to n i = pure (commitTo n i) := by
  unfold Node.commit_to commitTo
  by_cases h : n.state.hard.commit < i
  · have hf' := fixed_hard ids n hf { n.state.hard with commit := i } true
    simp only [gt_iff_lt, h, decide_true, if_true, bind_pure]
    exact refresh_fixed ids _ hf'
  · simp [h]

/-- The match index of a member's slot. -/
theorem matched_fn_eq (ids : Vector Id N) (n : Node V S N CAP) (hf : Fixed ids n) (j : Nat) (hj : j < N) :
    Node.matched_fn n (ids[j]'hj) = pure (n.matched[j]'hj) := by
  unfold Node.matched_fn
  rw [hf.peers, position_member ids hf.nodup j hj]
  have hv : (Rust.ofNat j : Rust.usize).val = j := by simp [Rust.ofNat]; have := hf.n_lt; uomega
  simp [Rust.Option.map_orM, Rust.Slice.index_ok _ _ (by rw [hv]; exact hj), hv]

/-- `advance_commit`: commit the largest index matched by a majority, if it is
    from the current term. -/
theorem advance_commit_eq (ids : Vector Id N) (n : Node V S N CAP) (hf : Fixed ids n) :
    ∃ v : Rust.u64, N / 2 < (List.finRange N).countP (fun j => decide (v.val ≤ (n.matched[j]).val)) ∧
      Node.advance_commit n = pure (
        if n.state.hard.commit < v ∧ Rust.Option.is_some_and (State.id_at n.state v) (fun id => id.term == n.state.hard.term) = true
        then (true, commitTo n v) else (false, n)) := by
  have hN : N < 2 ^ (Rust.usizeBits - 1) := hf.n_lt
  obtain ⟨v, hq, hmaj⟩ := quorum_index_stable ids hf.n_pos hN (fun id => do let t ← Node.matched_fn n id; pure t)
    (fun id => match Rust.Iter.position (ids.map some).toList (fun p => p == some id) with
      | some j => n.matched[j.val]! | none => 0) (by
      intro id hid
      obtain ⟨j, hj, rfl⟩ := List.getElem_of_mem hid
      have hj' : j < N := by simpa using hj
      simp only [Vector.getElem_toList]
      rw [matched_fn_eq ids n hf j hj', position_member ids hf.nodup j hj']
      have hv : (Rust.ofNat j : Rust.usize).val = j := by simp [Rust.ofNat]; uomega
      simp [hv, hj'])
  refine ⟨v, ?_, ?_⟩
  · rw [← ids_filter_count ids _ (fun j => decide (v.val ≤ (n.matched[j]).val))]
    · exact hmaj
    · intro j
      show decide (v.val ≤ (match Rust.Iter.position (ids.map some).toList (fun p => p == some (ids[j.val]'j.isLt)) with
        | some j => n.matched[j.val]! | none => 0).val) = _
      rw [position_member ids hf.nodup j.val j.isLt]
      simp (disch := (uomega)) [Rust.ofNat, Nat.mod_eq_of_lt]
  · unfold Node.advance_commit
    simp only [hf.membership, hq, pure_bind]
    by_cases hc : n.state.hard.commit < v ∧ Rust.Option.is_some_and (State.id_at n.state v) (fun id => id.term == n.state.hard.term) = true
    · rw [if_pos hc]
      have h1 : decide (v > n.state.hard.commit) = true := by simpa using hc.1
      simp [h1, hc.2, commit_to_eq ids n hf]
    · rw [if_neg hc]
      by_cases h1 : n.state.hard.commit < v
      · have h2 : Rust.Option.is_some_and (State.id_at n.state v) (fun id => id.term == n.state.hard.term) = false := by
          simpa [h1] using hc
        simp [h1, h2]
      · simp [h1]

/-- What `advance_commit` may do: nothing, or commit a current-term index
    that a majority has matched. -/
def Adv (n n' : Node V S N CAP) : Prop :=
  n' = n ∨ ∃ v : Rust.u64, N / 2 < (List.finRange N).countP (fun j => decide (v.val ≤ (n.matched[j]).val)) ∧
    n.state.hard.commit < v ∧
    Rust.Option.is_some_and (State.id_at n.state v) (fun id => id.term == n.state.hard.term) = true ∧
    n' = commitTo n v

theorem advance_rel (ids : Vector Id N) (n : Node V S N CAP) (hf : Fixed ids n) :
    ∃ b n', Node.advance_commit n = pure (b, n') ∧ Adv n n' := by
  obtain ⟨v, hmaj, h⟩ := advance_commit_eq ids n hf
  by_cases hc : n.state.hard.commit < v ∧
      Rust.Option.is_some_and (State.id_at n.state v) (fun id => id.term == n.state.hard.term) = true
  · rw [if_pos hc] at h; exact ⟨_, _, h, Or.inr ⟨v, hmaj, hc.1, hc.2, rfl⟩⟩
  · rw [if_neg hc] at h; exact ⟨_, _, h, Or.inl rfl⟩

/-- A leader's own append: the new state, a pending save from `idx`, and its own match index. -/
def ownAppend (n : Node V S N CAP) (s' : State V S CAP) (idx : Rust.u64) (h : n.local.val < N) : Node V S N CAP :=
  { n with state := s', dirty := true, log_from := some idx, matched := n.matched.set n.local.val idx h }

omit [Rust.Clone V] [Rust.Clone S] in
theorem fixed_state (ids : Vector Id N) (n : Node V S N CAP) (hf : Fixed ids n) (s' : State V S CAP)
    (hl : Layout s') (hc : Contig s') (d : Bool) (lf : Option Rust.u64) (m : Vector Rust.u64 N) :
    Fixed ids { n with state := s', dirty := d, log_from := lf, matched := m } :=
  { hf with layout := hl, contig := hc }

/-- What `barrier` may do: nothing, or append a current-term no-op at the next
    index and then possibly advance the commit index. -/
def Barrier (n n' : Node V S N CAP) : Prop :=
  n' = n ∨ ∃ (s' : State V S CAP) (idx : Rust.u64) (h : n.local.val < N),
    idx.val = (lastId n.state).index.val + 1 ∧ (lastId n.state).term ≠ n.state.hard.term ∧
    ret s' = ret n.state ++ [{ id := { index := idx, term := n.state.hard.term }, value := none }] ∧
    s'.hard = n.state.hard ∧ s'.snapshot = n.state.snapshot ∧ Layout s' ∧ Contig s' ∧
    Adv (ownAppend n s' idx h) n'

/-- `barrier`: unless the log already ends in the current term or is full, append
    a no-op at the next index, then try to advance the commit index. -/
theorem barrier_rel (ids : Vector Id N) (n : Node V S N CAP) (hf : Fixed ids n) :
    ∃ n', Node.barrier n = pure n' ∧ Barrier n n' := by
  have hcap : CAP < 2 ^ Rust.usizeBits := by have := hf.cap_lt; uomega
  have hl := hf.layout
  unfold Node.barrier
  simp only [last_eq _ hl.1, pure_bind]
  by_cases h1 : ((lastId n.state).term == n.state.hard.term || State.full n.state) = true
  · exact ⟨n, by simp [h1], Or.inl rfl⟩
  · simp only [h1, Bool.false_eq_true, if_false]
    have hterm : (lastId n.state).term ≠ n.state.hard.term := by
      intro e; simp [e] at h1
    have hfull : n.state.len.val < CAP := by
      have hf0 : State.full n.state = false := by
        cases hfl : State.full n.state <;> simp_all
      have hne : n.state.len ≠ Rust.usizeOf CAP := by
        intro e; simp [State.full, e] at hf0
      have := hl.1
      rcases Nat.lt_or_ge n.state.len.val CAP with h | h
      · exact h
      · exact absurd (Fin.ext (by rw [Rust.val_usizeOf _ hcap]; omega)) hne
    by_cases h2 : (lastId n.state).index.val + (1 : Rust.u64).val < 2 ^ 64
    · simp only [Rust.checked_add_eq, dif_pos h2]
      obtain ⟨s', hpush, hh, hsn, hr, hlen, hl'⟩ := push_ok n.state
        { id := { index := ⟨(lastId n.state).index.val + (1 : Rust.u64).val, h2⟩, term := n.state.hard.term },
          value := none } hcap hl hfull
      have hc' : Contig s' := by
        apply contig_push n.state s' _ hf.contig (by simp [State.base, hsn]) hr
        simp only
        rw [lastId_eq n.state hf.contig]; simp
      rw [hpush]
      simp only [pure_bind, Rust.Result.is_ok, if_true]
      have hlt : decide (n.local < Rust.usizeOf N) = true := by
        simp [Fin.lt_def, Rust.val_usizeOf _ (show N < 2 ^ Rust.usizeBits by have := hf.n_lt; uomega), hf.local_lt]
      simp only [hlt, if_true, Rust.Slice.set_ok _ _ _ hf.local_lt, pure_bind]
      have hf1 := fixed_state ids n hf s' hl' hc' true (some ⟨(lastId n.state).index.val + (1 : Rust.u64).val, h2⟩)
        (n.matched.set n.local.val ⟨(lastId n.state).index.val + (1 : Rust.u64).val, h2⟩ hf.local_lt)
      obtain ⟨b, n', hadv, hA⟩ := advance_rel ids _ hf1
      refine ⟨n', ?_, Or.inr ⟨s', _, hf.local_lt, by simp, hterm, hr, hh, hsn, hl', hc', hA⟩⟩
      rw [hadv]; rfl
    · exact ⟨n, by simp only [Rust.checked_add_eq, dif_neg h2], Or.inl rfl⟩

/-- The node just after `become_leader` sets its leader bookkeeping. -/
def leaderInit (n : Node V S N CAP) (h : n.local.val < N) : Node V S N CAP :=
  { n with quorum_elapsed := 0, active := Rust.Slice.fill n.active false, role := .Leader, leader := some n.config.id, elapsed := 0, next := Rust.Slice.fill n.next (Rust.saturating_add (lastId n.state).index 1), matched := (Rust.Slice.fill n.matched 0).set n.local.val (lastId n.state).index h }

omit [Rust.Clone V] [Rust.Clone S] in
theorem fixed_leaderInit (ids : Vector Id N) (n : Node V S N CAP) (hf : Fixed ids n) :
    Fixed ids (leaderInit n hf.local_lt) := { hf with layout := hf.layout, contig := hf.contig }

/-- What `become_leader` does: leader bookkeeping, `barrier`, then `broadcast`. -/
def BecomeLeader (n n' : Node V S N CAP) : Prop :=
  ∃ (h : n.local.val < N) (n2 : Node V S N CAP), Barrier (leaderInit n h) n2 ∧ n' = bcast n2

omit [Rust.Clone V] [Rust.Clone S] in
theorem fixed_commitTo (ids : Vector Id N) (n : Node V S N CAP) (hf : Fixed ids n) (v : Rust.u64) :
    Fixed ids (commitTo n v) := by
  unfold commitTo; split
  · exact fixed_hard ids n hf _ true
  · exact hf

omit [Rust.Clone V] [Rust.Clone S] in
theorem fixed_adv (ids : Vector Id N) (n n' : Node V S N CAP) (hf : Fixed ids n) (h : Adv n n') : Fixed ids n' := by
  rcases h with rfl | ⟨v, -, -, -, rfl⟩
  · exact hf
  · exact fixed_commitTo ids n hf v

omit [Rust.Clone V] [Rust.Clone S] in
theorem fixed_barrier (ids : Vector Id N) (n n' : Node V S N CAP) (hf : Fixed ids n) (hb : Barrier n n') :
    Fixed ids n' := by
  rcases hb with rfl | ⟨s', idx, h, -, -, -, -, -, hl, hc, hA⟩
  · exact hf
  · exact fixed_adv ids _ _ (fixed_state ids n hf s' hl hc true _ _) hA

theorem become_leader_rel (ids : Vector Id N) (n : Node V S N CAP) (hf : Fixed ids n) :
    ∃ n', Node.become_leader n = pure n' ∧ BecomeLeader n n' := by
  have hN : N < 2 ^ Rust.usizeBits := by have := hf.n_lt; uomega
  obtain ⟨n2, hb, hB⟩ := barrier_rel ids _ (fixed_leaderInit ids n hf)
  refine ⟨bcast n2, ?_, hf.local_lt, n2, hB, rfl⟩
  have hlt : decide (n.local < Rust.usizeOf N) = true := by
    simp [Fin.lt_def, Rust.val_usizeOf _ hN, hf.local_lt]
  unfold Node.become_leader
  simp only [last_eq _ hf.layout.1, pure_bind, hlt, if_true, Rust.Slice.set_ok _ _ _ hf.local_lt]
  simp only [leaderInit] at hb
  rw [hb]
  simp only [pure_bind]
  rw [broadcast_eq ids n2 (fixed_barrier ids _ n2 (fixed_leaderInit ids n hf) hB)]
  simp

/-- Vote requests queued for every other slot. -/
def requestVotes (n : Node V S N CAP) : Node V S N CAP :=
  { n with outbox := Vector.ofFn fun j => if j.val ≠ n.local.val then some .Vote else n.outbox[j] }

/-- The node just after `campaign(term)` updates its durable vote and role. -/
def candidate (n : Node V S N CAP) (t : Rust.u64) (h : n.local.val < N) : Node V S N CAP :=
  { n with prevoting := none, state := { n.state with hard := { n.state.hard with term := t, voted_for := some n.config.id } }, dirty := true, role := .Candidate, leader := none, votes := (Rust.Slice.fill n.votes false).set n.local.val true h }

omit [Rust.Clone V] [Rust.Clone S] in
theorem fixed_candidate (ids : Vector Id N) (n : Node V S N CAP) (hf : Fixed ids n) (t : Rust.u64) :
    Fixed ids (candidate n t hf.local_lt) := { hf with layout := hf.layout, contig := hf.contig, prevoting := rfl }

omit [Rust.Clone V] [Rust.Clone S] in
theorem fixed_timers (ids : Vector Id N) (n n' : Node V S N CAP) (hf : Fixed ids n) (h : Timers n n') :
    Fixed ids n' := by
  obtain ⟨r, d, rfl⟩ := h; exact { hf with layout := hf.layout, contig := hf.contig }

theorem countP_single (k : Nat) (h : k < N) (p : Fin N → Bool) (hp : ∀ j : Fin N, p j = decide (j.val = k)) :
    (List.finRange N).countP p = 1 := by
  have : (List.finRange N).countP p = (List.finRange N).count ⟨k, h⟩ := by
    rw [List.count_eq_countP]; apply List.countP_congr; intro j _; simp [hp, Fin.ext_iff]
  rw [this, List.Nodup.count (List.nodup_finRange N)]; simp

omit [Rust.Clone V] [Rust.Clone S] in
/-- Only the node's own vote is counted right after `campaign` starts. -/
theorem candidate_votes (n : Node V S N CAP) (t : Rust.u64) (h : n.local.val < N) :
    (List.finRange N).countP (fun j => (candidate n t h).votes[j]) = 1 := by
  apply countP_single n.local.val h
  intro j
  simp only [candidate, Rust.Slice.fill]
  by_cases hj : n.local.val = j.val <;> simp [hj] <;> omega

theorem campaign_rel (ids : Vector Id N) (n : Node V S N CAP) (hf : Fixed ids n) (t : Rust.u64) :
    ∃ n', Node.campaign n t = pure n' ∧ ∃ n1, Timers (candidate n t hf.local_lt) n1 ∧
      ((N / 2 < 1 ∧ BecomeLeader n1 n') ∨ (¬ N / 2 < 1 ∧ n' = requestVotes n1)) := by
  have hN : N < 2 ^ Rust.usizeBits := by have := hf.n_lt; uomega
  have hc := fixed_candidate ids n hf t
  obtain ⟨n1, hr, ht⟩ := reset_timers ids _ hc
  have hf1 := fixed_timers ids _ _ hc ht
  have hvotes : n1.votes = (candidate n t hf.local_lt).votes := by obtain ⟨r, d, rfl⟩ := ht; rfl
  have hq := election_quorum_eq ids n1 hf1
  rw [hvotes, candidate_votes] at hq
  unfold Node.campaign
  simp only [Rust.Slice.set_ok _ _ _ hf.local_lt, pure_bind]
  have hr' := hr
  simp only [candidate] at hr'
  rw [hr']
  simp only [pure_bind, hq]
  by_cases hq1 : N / 2 < 1
  · obtain ⟨n', hb, hB⟩ := become_leader_rel ids n1 hf1
    refine ⟨n', ?_, n1, ht, Or.inl ⟨hq1, hB⟩⟩
    simp [hq1, hb]
  · refine ⟨requestVotes n1, ?_, n1, ht, Or.inr ⟨hq1, rfl⟩⟩
    simp only [hq1, decide_false, Bool.false_eq_true, if_false, bind_pure]
    refine Rust.forIn_eq_inv _ _ _ _
      (fun k b => b = { n1 with outbox := Vector.ofFn fun j =>
        if j.val < k ∧ j.val ≠ n1.local.val then some .Vote else n1.outbox[j] }) ?_ ?_ ?_
    · have : (Vector.ofFn fun j : Fin N =>
          if j.val < 0 ∧ j.val ≠ n1.local.val then some Outbound.Vote else n1.outbox[j]) = n1.outbox := by
        ext j hj; simp
      rw [this]
    · intro k hk b hb
      obtain ⟨hget, hkN⟩ := range_get N hN k hk
      rw [hget]
      have hv : (Rust.ofNat k : Rust.usize).val = k := by simp [Rust.ofNat]; uomega
      rw [hb]
      by_cases hkl : k = n1.local.val
      · refine ⟨_, ?_, rfl⟩
        have : (Rust.ofNat k : Rust.usize) = n1.local := Fin.ext (by rw [hv, hkl])
        simp only [this, bne_self_eq_false, Bool.false_eq_true, if_false]
        congr 3
        ext j hj
        simp only [Vector.getElem_ofFn]
        split <;> split <;> first | rfl | omega
      · refine ⟨_, ?_, rfl⟩
        have hne : (Rust.ofNat k : Rust.usize) ≠ n1.local := fun e => hkl (by rw [← hv, e])
        have hp : (Rust.ofNat k : Rust.usize).val < N := by rw [hv]; exact hkN
        have hvoter : Rust.Option.is_some_and n1.peers[k] (fun id => Membership.is_voter n1.membership id) = true := by
          rw [hf1.peers, hf1.membership]; simp [stable_is_voter]
        simp only [bne_iff_ne, ne_eq, hne, not_false_eq_true, if_true, Rust.Slice.index_ok _ _ hp,
          pure_bind, hv, hvoter, send_eq _ _ _ hN hp]
        congr 3
        ext j hj
        simp only [Vector.getElem_set, Vector.getElem_ofFn]
        split
        · rename_i h; subst h; simp [hkl]
        · split <;> split <;> first | rfl | omega
    · intro b hb
      rw [hb]; unfold requestVotes
      congr 1
      ext j hj
      simp [Rust.Iter.range, Rust.val_usizeOf _ hN]

end Jarl.Engine
