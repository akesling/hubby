import Engine.NodeOps

/-!
# Host operations: proposals, compaction, persistence and restart
-/

namespace Jarl.Engine
open Jarl

variable {V S : Type} {N CAP : Nat}

/-- No pending save or outgoing message (`available` succeeds). -/
def Idle (n : Node V S N CAP) : Prop :=
  n.dirty = false ∧ n.extra_reply = none ∧ ∀ j : Fin N, n.outbox[j] = none

/-- The entries a leader appends for proposed values, after its last entry. -/
def proposed (n : Node V S N CAP) (vs : List V) : List (Entry V) :=
  vs.zipIdx.map fun (v, i) =>
    { id := { index := Rust.ofNat ((lastId n.state).index.val + 1 + i), term := n.state.hard.term }, value := some v }

theorem pure_inj {α : Type} {a b : α} (h : (pure a : Rust.M α) = pure b) : a = b := by
  simp only [pure, ExceptT.pure, ExceptT.mk] at h
  injection h with h; injection h

theorem bind_eq_pure {α β : Type} (x : Rust.M α) (f : α → Rust.M β) (b : β) (h : (x >>= f) = pure b) :
    ∃ a, x = pure a ∧ f a = pure b := by
  have key : ∀ o : Option (Except Rust.Panic α), (ExceptT.mk o >>= f) = pure b →
      ∃ a, (ExceptT.mk o : Rust.M α) = pure a ∧ f a = pure b := by
    intro o h
    rcases o with _ | e | a
    · simp [bind, ExceptT.bind, ExceptT.mk, pure, ExceptT.pure] at h
    · simp [bind, ExceptT.bind, ExceptT.mk, ExceptT.bindCont, pure, ExceptT.pure] at h
      cases h
    · exact ⟨a, rfl, h⟩
  exact key x.run h

theorem install_contig (s s' : State V S CAP) (snap : Snapshot S) (hl : Layout s) (hc : Contig s)
    (hsn : s'.snapshot = some snap)
    (hr : ret s' = (if idAt s snap.last.index.val = some snap.last
        then (ret s).drop (snap.last.index.val - s.base.index.val) else [])) : Contig s' := by
  intro k hk
  have hb : s'.base = snap.last := by simp [State.base, hsn]
  rw [hb]
  by_cases hm : idAt s snap.last.index.val = some snap.last
  · obtain ⟨h1, h2⟩ := idAt_some s hl hc _ hm
    have hk' : k < ((ret s).drop (snap.last.index.val - s.base.index.val)).length := by
      have := hk; rw [hr, if_pos hm] at this; exact this
    rw [List.getElem_of_eq (hr.trans (if_pos hm)) hk, List.getElem_drop]
    rw [hc _ (by simp at hk'; omega)]
    omega
  · have : (ret s').length = 0 := by rw [hr, if_neg hm]; rfl
    omega

theorem idle_of_available (n : Node V S N CAP) (h : Node.available n = .Ok ()) : Idle n := by
  unfold Node.available at h
  split at h
  · cases h
  · rename_i hc
    simp only [Bool.or_eq_true, not_or, List.any_eq_true, not_exists, not_and, Option.isSome_iff_ne_none,
      ne_eq, Classical.not_not, Bool.not_eq_true] at hc
    refine ⟨hc.1.1, hc.1.2, fun j => hc.2 _ (by simp)⟩

theorem anyM_false {α : Type} (l : List α) (p : α → Rust.M Bool) (h : ∀ x ∈ l, p x = pure false) :
    l.anyM p = pure false := by
  induction l with
  | nil => rfl
  | cons x xs ih =>
    rw [List.anyM_cons, h x (by simp)]
    simp only [pure_bind, Bool.false_eq_true, if_false]
    exact ih (fun y hy => h y (by simp [hy]))

theorem new_tail (ids : Vector Id N) (n0 n : Node V S N CAP) (hf0 : Fixed ids n0)
    (h : (do let m ← n0.refresh_membership; let m_1 ← m.reset_election; pure (Rust.Result.Ok m_1)) =
      (pure (Rust.Result.Ok n) : Rust.M (Rust.Result (Node V S N CAP) Error))) :
    Fixed ids n ∧ Timers n0 n := by
  rw [refresh_fixed ids n0 hf0, pure_bind] at h
  obtain ⟨n', hr, ht⟩ := reset_timers ids n0 hf0
  rw [hr, pure_bind] at h
  simp only [pure, ExceptT.pure, ExceptT.mk] at h
  injection h with h; injection h with h; injection h with h
  subst h
  exact ⟨fixed_timers ids _ _ hf0 ht, ht⟩

theorem forIn_bind_elim {β γ δ : Type} (l : List γ) (init : β) (f : γ → β → Rust.M (ForInStep β))
    (k : β → Rust.M δ) (R : Rust.M δ) (I : Nat → β → Prop) (h0 : I 0 init)
    (hstep : ∀ i (hi : i < l.length) b, I i b → ∃ b', f l[i] b = pure (.yield b') ∧ I (i + 1) b')
    (h : (forIn l init f >>= k) = R) : ∃ b, I l.length b ∧ k b = R := by
  obtain ⟨b, hb, hI⟩ := Rust.forIn_inv l init f I h0 hstep
  rw [hb, pure_bind] at h
  exact ⟨b, hI, h⟩

theorem proposed_getElem (n : Node V S N CAP) (vs : List V) (k : Nat) (hk : k < vs.length) :
    (proposed n vs)[k]'(by simp [proposed]; exact hk) =
      { id := { index := Rust.ofNat ((lastId n.state).index.val + 1 + k), term := n.state.hard.term },
        value := some vs[k] } := by
  simp [proposed]

/-- `propose_many(count, values)`: an idle leader with room appends the batch
    atomically and replicates it; any other outcome leaves the node unchanged. -/
theorem propose_many_rel (ids : Vector Id N) (n : Node V S N CAP) (hf : Fixed ids n)
    (vs : List V) (count : Rust.usize) (hc : count.val = vs.length)
    (r : Rust.Result ProposalRange Error) (n' : Node V S N CAP)
    (h : Node.propose_many n count vs = pure (r, n')) :
    n' = n ∨
      (Idle n ∧ n.role = .Leader ∧ 0 < vs.length ∧ (lastId n.state).index.val + vs.length < 2 ^ 64 ∧
        ∃ (s' : State V S CAP) (n2 : Node V S N CAP),
          ret s' = ret n.state ++ proposed n vs ∧ s'.hard = n.state.hard ∧ s'.snapshot = n.state.snapshot ∧
          Layout s' ∧ Contig s' ∧
          Adv { ownAppend n s' (Rust.ofNat ((lastId n.state).index.val + vs.length)) hf.local_lt with log_from := some (Rust.ofNat ((lastId n.state).index.val + 1)) } n2 ∧
          n' = bcast n2) := by
  unfold Node.propose_many at h
  rcases ha : Node.available n with u | e
  rotate_left
  · simp only [ha] at h
    exact Or.inl (congrArg Prod.snd (pure_inj h)).symm
  simp only [ha] at h
  have hI := idle_of_available n ha
  by_cases hrole : (n.role != Role.Leader) = true
  · rw [if_pos hrole] at h
    exact Or.inl (congrArg Prod.snd (pure_inj h)).symm
  rw [if_neg hrole] at h
  have hrole' : n.role = Role.Leader := by simpa using hrole
  by_cases hz : (count == 0) = true
  · rw [if_pos hz] at h
    exact Or.inl (congrArg Prod.snd (pure_inj h)).symm
  rw [if_neg hz] at h
  have hpos : 0 < vs.length := by
    have : count ≠ 0 := by simpa using hz
    rw [← hc]; exact Nat.pos_of_ne_zero fun e => this (Fin.ext e)
  have hl := hf.layout
  have hcap : CAP < 2 ^ 64 := by have := hf.cap_lt; omega
  have hlen := len_eq _ hl
  have hrc : (Rust.Iter.count (ret n.state)).val = (ret n.state).length := by
    simp [Rust.Iter.count, Rust.ofNat]; have := hl.1; omega
  have hCv := Rust.val_usizeOf _ hcap
  rw [entries_fn_eq _ hl.1, pure_bind, Rust.sub_ok _ _ (by rw [hrc, hCv]; have := hl.1; omega), pure_bind] at h
  by_cases hfull : decide (count > (⟨(Rust.usizeOf CAP).val - (Rust.Iter.count (ret n.state)).val, by omega⟩ : Rust.usize)) = true
  · rw [if_pos hfull] at h
    exact Or.inl (congrArg Prod.snd (pure_inj h)).symm
  rw [if_neg hfull] at h
  have hroom : vs.length ≤ CAP - (ret n.state).length := by
    simp only [decide_eq_true_eq, gt_iff_lt, Fin.lt_def, hrc, hCv] at hfull; omega
  have htry : ((Rust.try_from (m := 64) count).map_err fun _ => Error.Exhausted) = Rust.Result.Ok count := by
    simp [Rust.try_from, Rust.Result.map_err]
  rw [last_eq _ hl.1, pure_bind, htry] at h
  simp only [pure_bind] at h
  by_cases hov : (lastId n.state).index.val + count.val < 2 ^ 64
  rotate_left
  · simp only [Rust.checked_add_eq, dif_neg hov, Rust.Option.ok_or] at h
    exact Or.inl (congrArg Prod.snd (pure_inj h)).symm
  simp only [Rust.checked_add_eq, dif_pos hov, Rust.Option.ok_or] at h
  rw [Rust.add_ok _ _ (by simp; omega)] at h
  simp only [pure_bind] at h
  have hF : (lastId n.state).index.val + (1 : Rust.u64).val < 2 ^ 64 := by simp; omega
  have hcont := hf.contig
  have hLb := lastId_eq n.state hcont
  have hplen : (proposed n vs).length = vs.length := by simp [proposed]
  refine (fun key => ?_) (forIn_bind_elim _ _ _ _ _
    (fun k b => ∃ sk : State V S CAP,
      b = (none, { n with state := sk }, { state := sk, «from» := ⟨_, hF⟩, finished := false }) ∧
      ret sk = ret n.state ++ (proposed n vs).take k ∧ sk.hard = n.state.hard ∧
      sk.snapshot = n.state.snapshot ∧ Layout sk ∧ Contig sk)
    ⟨n.state, rfl, by simp, rfl, rfl, hl, hcont⟩ ?step h)
  case step =>
    intro k hk b ⟨sk, hb, hr, hh, hs, hlk, hck⟩
    subst hb
    rw [enumerate_length] at hk
    have hkv : (Rust.ofNat k : Rust.usize).val = k := by simp [Rust.ofNat]; omega
    have hlenk : (ret sk).length = (ret n.state).length + k := by
      rw [hr]; simp [hplen]; omega
    have hbase : sk.base = n.state.base := by simp [State.base, hs]
    have hadd : (⟨(lastId n.state).index.val + (1 : Rust.u64).val, hF⟩ : Rust.u64).val + (Rust.ofNat k : Rust.usize).val < 2 ^ 64 := by
      rw [hkv]; simp; omega
    obtain ⟨s2, hp, hh2, hs2, hr2, -, hl2⟩ := push_ok sk
      { id := { index := ⟨_, hadd⟩, term := n.state.hard.term }, value := some vs[k] } hcap hlk
      (by rw [len_eq _ hlk]; omega)
    refine ⟨_, ?_, s2, rfl, ?_, hh2.trans hh, hs2.trans hs, hl2, ?_⟩
    · simp only [enumerate_get, Rust.add_ok _ _ hadd, pure_bind, hp]
    · rw [hr2, hr, List.take_add_one, List.getElem?_eq_getElem (by rw [hplen]; exact hk),
        proposed_getElem n vs k hk]
      have hidx : (⟨_, hadd⟩ : Rust.u64) = Rust.ofNat ((lastId n.state).index.val + 1 + k) := by
        apply Fin.ext; simp [Rust.ofNat]; omega
      rw [hidx]; simp
    · apply contig_push sk s2 _ hck (by simp [State.base, hs2]) hr2
      simp only [hkv, hbase]; simp; omega
  obtain ⟨b, ⟨sk, hb, hr, hh, hs, hlk, hck⟩, h⟩ := key
  subst hb
  rw [enumerate_length, List.take_of_length_le (by omega)] at hr
  simp only [BatchRollback.drop, Bool.not_true, Bool.false_eq_true, if_false, pure_bind] at h
  have hfx : Fixed ids { n with state := sk, dirty := true, log_from := some ⟨_, hF⟩ } :=
    fixed_state ids n hf sk hlk hck true _ n.matched
  rw [refresh_fixed ids _ hfx, pure_bind] at h
  have hlt : decide (n.local < Rust.usizeOf N) = true := by
    simp [Fin.lt_def, Rust.val_usizeOf _ (show N < 2 ^ 64 by have := hf.n_lt; omega), hf.local_lt]
  simp only [hlt, if_true, Rust.Slice.set_ok _ _ _ hf.local_lt, pure_bind] at h
  have e1 : (⟨(lastId n.state).index.val + count.val, hov⟩ : Rust.u64) = Rust.ofNat ((lastId n.state).index.val + vs.length) := by
    apply Fin.ext; simp [Rust.ofNat]; omega
  have e2 : (⟨(lastId n.state).index.val + (1 : Rust.u64).val, hF⟩ : Rust.u64) = Rust.ofNat ((lastId n.state).index.val + 1) := by
    apply Fin.ext; simp [Rust.ofNat]; omega
  rw [e1, e2] at h
  have hfX := fixed_state ids n hf sk hlk hck true (some (Rust.ofNat ((lastId n.state).index.val + 1)))
    (n.matched.set n.local.val (Rust.ofNat ((lastId n.state).index.val + vs.length)) hf.local_lt)
  obtain ⟨b, n2, hadv, hA⟩ := advance_rel ids _ hfX
  rw [hadv, pure_bind, broadcast_eq ids _ (fixed_adv ids _ _ hfX hA), pure_bind] at h
  exact Or.inr ⟨hI, hrole', hpos, by omega, sk, n2, hr, hh, hs, hlk, hck, hA,
    (congrArg Prod.snd (pure_inj h)).symm⟩

/-- `compact_with(index, value)`: an idle node compacts a committed retained
    index into a snapshot of the supplied value; a leader then may append a
    barrier and replicates. Any other outcome leaves the node unchanged. -/
theorem compact_with_rel (ids : Vector Id N) (n : Node V S N CAP) (hf : Fixed ids n)
    (index : Rust.u64) (value : Unit → Rust.M S) (r : Rust.Result Unit Error) (n' : Node V S N CAP)
    (h : Node.compact_with n index value = pure (r, n')) :
    n' = n ∨
      (Idle n ∧ n.state.base.index.val < index.val ∧ index.val ≤ n.state.hard.commit.val ∧
        ∃ (last : LogId) (v : S) (s' : State V S CAP), idAt n.state index.val = some last ∧ value () = pure v ∧
          State.install n.state { last := last, value := v } = pure s' ∧
          let n1 : Node V S N CAP := { n with state := s', dirty := true, snapshot_changed := true }
          ((n.role ≠ .Leader ∧ n' = n1) ∨
            (n.role = .Leader ∧ ∃ n2, Barrier n1 n2 ∧ n' = bcast n2))) := by
  unfold Node.compact_with at h
  cases ha : Node.available n with
  | Err e =>
    simp only [ha] at h
    exact Or.inl (congrArg Prod.snd (pure_inj h)).symm
  | Ok u =>
    simp only [ha] at h
    have hI := idle_of_available n ha
    by_cases hc : (decide (index ≤ n.state.base.index) || decide (index > n.state.hard.commit)) = true
    · rw [if_pos hc] at h
      exact Or.inl (congrArg Prod.snd (pure_inj h)).symm
    rw [if_neg hc] at h
    simp only [Bool.or_eq_true, decide_eq_true_eq, not_or, Fin.not_le, gt_iff_lt, Fin.not_lt] at hc
    rw [id_at_eq _ hf.layout] at h
    cases hid : idAt n.state index.val with
    | none =>
      simp only [hid, Rust.Option.ok_or] at h
      exact Or.inl (congrArg Prod.snd (pure_inj h)).symm
    | some last =>
      simp only [hid, Rust.Option.ok_or, pure_bind] at h
      obtain ⟨v, hv, h⟩ := bind_eq_pure _ _ _ h
      obtain ⟨s', hins, hsn, hhard, hr, hl'⟩ := install_spec n.state { last := last, value := v }
        (by have := hf.cap_lt; omega) hf.layout hf.contig
      have hc' := install_contig n.state s' _ hf.layout hf.contig hsn hr
      rw [hins, pure_bind] at h
      refine Or.inr ⟨hI, Fin.lt_def.mp hc.1, Fin.le_def.mp hc.2, last, v, s', rfl, hv, hins, ?_⟩
      have hf1 : Fixed ids { n with state := s', dirty := true, snapshot_changed := true } :=
        { hf with layout := hl', contig := hc' }
      by_cases hrole : n.role = Role.Leader
      · have hrb : (n.role == Role.Leader) = true := by simp [hrole]
        rw [if_pos hrb] at h
        obtain ⟨n2, hb, hB⟩ := barrier_rel ids _ hf1
        rw [hb, pure_bind, broadcast_eq ids _ (fixed_barrier ids _ _ hf1 hB), pure_bind] at h
        exact Or.inr ⟨hrole, n2, hB, (congrArg Prod.snd (pure_inj h)).symm⟩
      · have : (n.role == Role.Leader) = false := by simpa using hrole
        simp only [this, Bool.false_eq_true, if_false] at h
        exact Or.inl ⟨hrole, (congrArg Prod.snd (pure_inj h)).symm⟩

/-- `Ready::persisted` clears the pending-save flags. -/
theorem persisted_eq (n : Node V S N CAP) :
    Ready.persisted ⟨n⟩ = ⟨{ n with dirty := false, log_from := none, snapshot_changed := false }⟩ := by
  rfl

/-- `Node::new` from a well-formed checkpoint with a valid configuration of the
    distinct `ids`: a clean follower with no pending messages. -/
theorem new_rel (ids : Vector Id N) (config : Config N) (s : State V S CAP) (n : Node V S N CAP)
    (h : Node.new config s = pure (.Ok n)) (hn : 0 < N) (hN : N < 2 ^ 63) (hcap : CAP < 2 ^ 63)
    (hm : config.members = ids) (hd : ids.toList.Nodup) (hl : Layout s) (hc : Contig s) :
    Fixed ids n ∧ n.state = s ∧ n.config = config ∧ n.role = .Follower ∧ n.dirty = false ∧
      (∀ j : Fin N, n.outbox[j] = none ∧ n.votes[j] = false ∧ n.matched[j] = 0) := by
  subst hm
  have hN64 : N < 2 ^ 64 := by omega
  unfold Node.new at h
  by_cases hcond : (!(Rust.usizeOf N == 0 || Rust.usizeOf CAP == 0 || (Rust.Iter.position config.members.toList fun id => id == config.id).isNone || config.heartbeat_ticks == 0 ||
                decide (config.election_ticks ≤ config.heartbeat_ticks) ||
              decide (config.election_ticks > Rust.divK (Rust.umax 64) 2))) = true
  · have hany : (Rust.Iter.enumerate config.members.toList).anyM (fun x => match x with
        | (i, id_1) => do
          let t1 ← Rust.Slice.range config.members 0 i
          pure (t1.toList.contains id_1)) = pure false := by
      apply anyM_false
      intro x hx
      obtain ⟨k, hk, rfl⟩ := List.getElem_of_mem hx
      rw [enumerate_length] at hk
      have hkN : k < N := by simpa using hk
      have hk2 : (Rust.ofNat k : Rust.usize).val = k := by simp [Rust.ofNat]; omega
      simp only [enumerate_get]
      rw [Rust.Slice.range_ok _ _ _ (by simp [hk2]; omega)]
      simp only [pure_bind, hk2]
      congr 1
      have hnot : config.members.toList[k] ∉ config.members.toList.take k := by
        intro hm
        have hsplit := List.take_append_drop k config.members.toList
        rw [← hsplit] at hd
        have hdisj := (List.nodup_append.mp hd).2.2
        have hmem : config.members.toList[k] ∈ config.members.toList.drop k := by
          rw [List.mem_iff_getElem]; exact ⟨0, by simp; omega, by simp⟩
        exact hdisj _ hm _ hmem rfl
      simp only [Array.toList_extract, List.extract_eq_take_drop]
      simp
      exact hnot
    simp only [hcond, if_true, hany, pure_bind, Bool.false_eq_true, if_false] at h
    simp only [Bool.not_eq_true', Bool.or_eq_false_iff, beq_eq_false_iff_ne, decide_eq_false_iff_not] at hcond
    split at h
    · simp [pure, ExceptT.pure, ExceptT.mk] at h
      cases h
    rw [new_stable _ hn hN64 hd] at h
    simp only [pure_bind] at h
    unfold Node.build at h
    obtain ⟨⟨⟨⟨⟨hN0, hC0⟩, hpos⟩, hhb⟩, hel⟩, hel2⟩ := hcond
    have hb : (Rust.usizeOf CAP == 0 || config.heartbeat_ticks == 0 ||
              decide (config.election_ticks ≤ config.heartbeat_ticks) ||
            decide (config.election_ticks > Rust.divK (Rust.umax 64) 2)) = false := by
      simp [hC0, hhb, hel, hel2]
    rw [hb, if_neg (by simp)] at h
    simp only [] at h
    have hpos' := hpos
    simp only [Rust.Iter.position, Option.isNone_map, Option.isNone_eq_false_iff, Option.isSome_iff_exists] at hpos'
    obtain ⟨j, hj⟩ := hpos'
    rw [List.findIdx?_eq_some_iff_getElem] at hj
    obtain ⟨hjl, hjp, -⟩ := hj
    have hjN : j < N := by simpa using hjl
    have hjid : config.members[j] = config.id := by simpa using hjp
    have hloc : (Rust.Iter.position (stable config.members).peers.toList fun id => id == some config.id) = some (Rust.ofNat j) := by
      rw [stable_peers, ← hjid]; exact position_member _ hd j hjN
    have hjv : (Rust.ofNat j : Rust.usize).val = j := by simp [Rust.ofNat]; omega
    have hC : (Rust.usizeOf CAP).val = CAP := Rust.val_usizeOf _ (by omega)
    have hdiv : (Rust.divK (Rust.umax 64) 2).val = 2 ^ 63 - 1 := by decide
    refine (fun key => ?_) (new_tail config.members _ n ?hf h)
    · obtain ⟨hF, r, d, rfl⟩ := key
      refine ⟨hF, rfl, rfl, rfl, rfl, fun j => ⟨?_, ?_, ?_⟩⟩ <;> simp [Rust.Slice.from_fn]
    case hf =>
      refine
        { n_pos := hn, n_lt := hN, cap_pos := ?_, cap_lt := hcap, nodup := hd, hooks := rfl,
          members := rfl, membership := rfl, bootstrap := rfl, peers := stable_peers _, local_lt := ?_,
          local_id := ?_, heartbeat := ?_, election := ?_, election_le := ?_, extra := rfl, prevoting := rfl,
          layout := hl, contig := hc }
      · exact Nat.pos_of_ne_zero fun h0 => hC0 (Fin.ext (by rw [hC, h0]; rfl))
      · show ((Rust.Iter.position _ _).getD _ : Rust.usize).val < N
        rw [hloc]; simp only [Option.getD_some, hjv]; exact hjN
      · show config.members[((Rust.Iter.position _ _).getD _ : Rust.usize).val]'_ = config.id
        simp only [hloc, Option.getD_some, hjv]; exact hjid
      · show 0 < config.heartbeat_ticks.val
        have := fun e => hhb (Fin.ext e); simp at this; omega
      · show config.heartbeat_ticks.val < config.election_ticks.val
        rw [Fin.le_def] at hel; omega
      · show config.election_ticks.val ≤ 2 ^ 63
        rw [gt_iff_lt, Fin.lt_def, hdiv] at hel2; omega
  · simp only [hcond, Bool.false_eq_true, if_false, pure_bind, if_true] at h
    simp [pure, ExceptT.pure, ExceptT.mk] at h
    cases h

end Jarl.Engine
