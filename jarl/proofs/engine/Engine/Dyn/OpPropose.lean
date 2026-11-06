import Engine.Dyn.Spec

/-!
# Proposals, compaction and membership changes through `Cluster`
-/

set_option linter.unusedSectionVars false

namespace Jarl.Engine.Dyn
open Jarl Jarl.Engine Jarl.Contracts.Membership

variable {V S : Type} {MAX CAP : Nat} [Rust.Clone V] [Rust.Clone S]

theorem pre_refresh_p (n n' : DNode V S MAX CAP) (hp : Pre n) (h : Refresh n n') : Pre n' := by
  obtain ⟨n1, ⟨hs, -, hu⟩, -, h⟩ := h
  have e1 : n1.hooks = n.hooks := by rw [hs]
  have e2 : n1.state = n.state := by rw [hs]
  have e3 : n1.config = n.config := by rw [hs]
  have hp1 : Pre { n1 with «local» := (Rust.Iter.position n1.peers.toList (fun p => p == some n.config.id)).getD (Rust.usizeOf MAX) } := by
    exact { hooks := e1.trans hp.hooks, layout := e2 ▸ hp.layout, contig := e2 ▸ hp.contig, n_lt := hp.n_lt, cap_lt := hp.cap_lt, e0 := e3 ▸ hp.e0, e1 := e3 ▸ hp.e1, uniq := hu }
  rcases h with h | ⟨-, -, -, h⟩
  · rw [h]; exact hp1
  · refine pre_timers _ _ ?_ h
    exact { hooks := e1.trans hp.hooks, layout := e2 ▸ hp.layout, contig := e2 ▸ hp.contig, n_lt := hp.n_lt, cap_lt := hp.cap_lt, e0 := e3 ▸ hp.e0, e1 := e3 ▸ hp.e1, uniq := hu }

/-- `propose_many(count, values)`, for values whose clones are faithful to `vs`. -/
theorem propose_many_rel' (n : DNode V S MAX CAP) (hp : Pre n)
    (vs : List (Record V MAX)) (values : List (Rust.M (Record V MAX))) (hvlen : values.length = vs.length)
    (hval : ∀ i (hi : i < vs.length), Rust.Faithful (values[i]'(hvlen ▸ hi)) vs[i])
    (count : Rust.usize) (hc : count.val = vs.length)
    (r : Rust.Result ProposalRange Error) (n' : DNode V S MAX CAP)
    (h : Node.propose_many n count values = pure (r, n')) : ProposeD n vs n' := by
  unfold Node.propose_many at h
  rcases ha : Node.available n with u | e
  rotate_left
  · simp only [ha] at h
    exact Or.inl (congrArg Prod.snd (Rust.pure_inj h)).symm
  simp only [ha] at h
  have hI := idle_of_available n ha
  by_cases hrole : (n.role != Role.Leader) = true
  · rw [if_pos hrole] at h
    exact Or.inl (congrArg Prod.snd (Rust.pure_inj h)).symm
  rw [if_neg hrole] at h
  have hrole' : n.role = Role.Leader := by simpa using hrole
  by_cases hz : (count == 0) = true
  · rw [if_pos hz] at h
    exact Or.inl (congrArg Prod.snd (Rust.pure_inj h)).symm
  rw [if_neg hz] at h
  have hpos : 0 < vs.length := by
    have : count ≠ 0 := by simpa using hz
    rw [← hc]; exact Nat.pos_of_ne_zero fun e => this (Fin.ext e)
  have hl := hp.layout
  have hcap : CAP < 2 ^ Rust.usizeBits := hp.cap_lt
  have hlen := len_eq _ hl
  have hrc : (Rust.Iter.count (ret n.state)).val = (ret n.state).length := by
    simp [Rust.Iter.count, Rust.ofNat]; have := hl.1; omega
  have hCv := Rust.val_usizeOf _ hcap
  rw [entries_fn_eq _ hl.1, pure_bind, Rust.sub_ok _ _ (by rw [hrc, hCv]; have := hl.1; omega), pure_bind] at h
  by_cases hfull : decide (count > (⟨(Rust.usizeOf CAP).val - (Rust.Iter.count (ret n.state)).val, by omega⟩ : Rust.usize)) = true
  · rw [if_pos hfull] at h
    exact Or.inl (congrArg Prod.snd (Rust.pure_inj h)).symm
  rw [if_neg hfull] at h
  have hroom : vs.length ≤ CAP - (ret n.state).length := by
    simp only [decide_eq_true_eq, gt_iff_lt, Fin.lt_def, hrc, hCv] at hfull; omega
  have htry : ((Rust.try_from (m := 64) count).map_err fun _ => Error.Exhausted) =
      Rust.Result.Ok (⟨count.val, usize_lt_u64 count⟩ : Rust.u64) := by
    simp [Rust.try_from, Rust.Result.map_err, usize_lt_u64 count]
  rw [last_eq _ hl.1, pure_bind, htry] at h
  simp only [pure_bind] at h
  by_cases hov : (lastId n.state).index.val + count.val < 2 ^ 64
  rotate_left
  · simp only [Rust.checked_add_eq, dif_neg hov, Rust.Option.ok_or] at h
    exact Or.inl (congrArg Prod.snd (Rust.pure_inj h)).symm
  simp only [Rust.checked_add_eq, dif_pos hov, Rust.Option.ok_or] at h
  rw [Rust.add_ok _ _ (by simp; omega)] at h
  simp only [pure_bind] at h
  have hF : (lastId n.state).index.val + (1 : Rust.u64).val < 2 ^ 64 := by simp; omega
  have hcont := hp.contig
  have hLb := lastId_eq n.state hcont
  have hplen : (proposed n vs).length = vs.length := by simp [proposed]
  refine (fun key => ?_) (forIn_bind_elim _ _ _ _ _
    (fun k b => ∃ sk : DState V S MAX CAP,
      b = (none, { n with state := sk }, { state := sk, «from» := ⟨_, hF⟩, finished := false }) ∧
      ret sk = ret n.state ++ (proposed n vs).take k ∧ sk.hard = n.state.hard ∧
      sk.snapshot = n.state.snapshot ∧ Layout sk ∧ Contig sk)
    ⟨n.state, rfl, by simp, rfl, rfl, hl, hcont⟩ ?step h)
  case step =>
    intro k hk b ⟨sk, hb, hr, hh, hs, hlk, hck⟩ st hst
    subst hb
    simp only [enumerate_get] at hst
    obtain ⟨v, hv, hst⟩ := Rust.bind_eq_pure hst
    rw [enumerate_length, hvlen] at hk
    obtain rfl := hval k hk v hv
    have hkv : (Rust.ofNat k : Rust.usize).val = k := by simp [Rust.ofNat]; uomega
    have hkv64 : (Rust.ofNat k : Rust.u64).val = k := by
      have := usize_lt_u64 count; simp [Rust.ofNat]; uomega
    try simp only [cast_ofNat_usize k (by omega)] at hst
    have hlenk : (ret sk).length = (ret n.state).length + k := by
      rw [hr]; simp [hplen]; omega
    have hbase : sk.base = n.state.base := by simp [State.base, hs]
    have hadd : (⟨(lastId n.state).index.val + (1 : Rust.u64).val, hF⟩ : Rust.u64).val + (Rust.ofNat k : Rust.u64).val < 2 ^ 64 := by
      rw [hkv64]; simp; omega
    obtain ⟨s2, hp2, hh2, hs2, hr2, -, hl2⟩ := push_ok sk
      { id := { index := ⟨_, hadd⟩, term := n.state.hard.term }, value := some vs[k] } hcap hlk
      (by rw [len_eq _ hlk]; omega)
    refine ⟨_, ?_, s2, rfl, ?_, hh2.trans hh, hs2.trans hs, hl2, ?_⟩
    · simp only [Rust.add_ok _ _ hadd, pure_bind, hp2] at hst
      exact (Rust.pure_inj hst).symm
    · rw [hr2, hr, List.take_add_one, List.getElem?_eq_getElem (by rw [hplen]; exact hk),
        proposed_getElem n vs k hk]
      have hidx : (⟨_, hadd⟩ : Rust.u64) = Rust.ofNat ((lastId n.state).index.val + 1 + k) := by
        apply Fin.ext; simp [Rust.ofNat]; uomega
      rw [hidx]; simp
    · apply contig_push sk s2 _ hck (by simp [State.base, hs2]) hr2
      simp only [hkv64, hbase]; simp; omega
  obtain ⟨b, ⟨sk, hb, hr, hh, hs, hlk, hck⟩, h⟩ := key
  subst hb
  rw [enumerate_length, List.take_of_length_le (by omega)] at hr
  simp only [BatchRollback.drop, Bool.not_true, Bool.false_eq_true, if_false, pure_bind] at h
  have e1 : (⟨(lastId n.state).index.val + count.val, hov⟩ : Rust.u64) = Rust.ofNat ((lastId n.state).index.val + vs.length) := by
    apply Fin.ext; simp [Rust.ofNat]; uomega
  have e2 : (⟨(lastId n.state).index.val + (1 : Rust.u64).val, hF⟩ : Rust.u64) = Rust.ofNat ((lastId n.state).index.val + 1) := by
    apply Fin.ext; simp [Rust.ofNat]; uomega
  rw [e1, e2] at h
  obtain ⟨n1, hr1, h⟩ := Rust.bind_eq_pure h
  have hp0 : Pre { n with state := sk, dirty := true, log_from := some (Rust.ofNat ((lastId n.state).index.val + 1)) } :=
    { hooks := hp.hooks, layout := hlk, contig := hck, n_lt := hp.n_lt, cap_lt := hp.cap_lt, e0 := hp.e0, e1 := hp.e1, uniq := hp.uniq }
  have hR := refresh_rel _ _ hp0.hooks hp0.layout hp0.contig hp.n_lt hp0.e0 hp0.e1 hp0.uniq hr1
  have hp1 := pre_refresh_p _ _ hp0 hR
  have hpm : Pre { n1 with matched := if h : n1.local.val < MAX then n1.matched.set n1.local.val (Rust.ofNat ((lastId n.state).index.val + vs.length)) h else n1.matched } :=
    { hp1 with layout := hp1.layout, contig := hp1.contig, uniq := hp1.uniq }
  have hadv : ∀ b m, Node.advance_commit { n1 with matched := if h : n1.local.val < MAX then n1.matched.set n1.local.val (Rust.ofNat ((lastId n.state).index.val + vs.length)) h else n1.matched } = pure (b, m) →
      (do let m_3 ← Node.broadcast m; pure (Rust.Result.Ok ({ first := { index := Rust.ofNat ((lastId n.state).index.val + 1), term := n.state.hard.term }, last := { index := Rust.ofNat ((lastId n.state).index.val + vs.length), term := n.state.hard.term } } : ProposalRange), m_3)) = (pure (r, n') : Rust.M _) →
      ProposeD n vs n' := by
    intro b m hm hb
    have hA := advance_rel' _ b _ hpm.hooks hpm.layout hpm.contig hp.n_lt hpm.e0 hpm.e1 hpm.uniq hm
    rw [broadcast_eq' _ hp.n_lt, pure_bind] at hb
    exact Or.inr ⟨hI, hrole', hpos, by omega, sk, n1, m, hr, hh, hs, hlk, hck, hR, hA,
      (congrArg Prod.snd (Rust.pure_inj hb)).symm⟩
  by_cases hlt : n1.local.val < MAX
  · have hd : decide (n1.local < Rust.usizeOf MAX) = true := by
      simp [Fin.lt_def, Rust.val_usizeOf _ hp.n_lt, hlt]
    simp only [hd, if_true, Rust.Slice.set_ok _ _ _ hlt, pure_bind] at h
    obtain ⟨⟨b, m⟩, hm, h⟩ := Rust.bind_eq_pure h
    exact hadv b m (by simpa [hlt] using hm) h
  · have hd : decide (n1.local < Rust.usizeOf MAX) = false := by
      simp [Fin.lt_def, Rust.val_usizeOf _ hp.n_lt, hlt]
    simp only [hd, Bool.false_eq_true, if_false] at h
    obtain ⟨⟨b, m⟩, hm, h⟩ := Rust.bind_eq_pure h
    exact hadv b m (by simpa [hlt] using hm) h

theorem cluster_propose_rel [Rust.LawfulClone V] (c : Cluster V S MAX CAP) (hp : Pre c.node) (v : V)
    (r : Rust.Result LogId Error) (c' : Cluster V S MAX CAP) (h : Cluster.propose c v = pure (r, c')) :
    ProposeD c.node [Record.Command v] c'.node := by
  unfold Cluster.propose at h
  dsimp only at h
  split at h
  · split at h
    · exact Or.inl (congrArg (fun p => p.2.node) (Rust.pure_inj h)).symm
    obtain ⟨t2, -, h⟩ := Rust.bind_eq_pure h
    split at h
    · exact Or.inl (congrArg (fun p => p.2.node) (Rust.pure_inj h)).symm
    obtain ⟨⟨r1, m⟩, hm, h⟩ := Rust.bind_eq_pure h
    have hm' : c'.node = m := by
      split at h <;> (simp only [pure_bind] at h; exact (congrArg (fun p => p.2.node) (Rust.pure_inj h)).symm)
    rw [hm']
    refine propose_many_rel' c.node hp [Record.Command v] _ rfl (fun i hi => ?_) 1 rfl r1 m hm
    obtain rfl : i = 0 := by simp at hi; omega
    exact Rust.faithful_bind (Rust.faithful_clone v) (Rust.faithful_pure _)
  · exact Or.inl (congrArg (fun p => p.2.node) (Rust.pure_inj h)).symm

theorem cluster_propose_batch_rel [Rust.LawfulClone V] (c : Cluster V S MAX CAP) (hp : Pre c.node) (vs : Array V)
    (hvs : vs.size < 2 ^ Rust.usizeBits)
    (r : Rust.Result ProposalRange Error) (c' : Cluster V S MAX CAP) (h : Cluster.propose_batch c vs = pure (r, c')) :
    ProposeD c.node (vs.toList.map Record.Command) c'.node := by
  unfold Cluster.propose_batch at h
  dsimp only at h
  split at h
  · split at h
    · exact Or.inl (congrArg (fun p => p.2.node) (Rust.pure_inj h)).symm
    obtain ⟨t2, -, h⟩ := Rust.bind_eq_pure h
    split at h
    · exact Or.inl (congrArg (fun p => p.2.node) (Rust.pure_inj h)).symm
    obtain ⟨⟨r1, m⟩, hm, h⟩ := Rust.bind_eq_pure h
    have hm' : c'.node = m := (congrArg (fun p => p.2.node) (Rust.pure_inj h)).symm
    rw [hm']
    refine propose_many_rel' c.node hp _ _ (by simp) (fun i hi => ?_) _ (by simp [Rust.val_usizeOf _ hvs]) r1 m hm
    simp only [List.getElem_map]
    exact Rust.faithful_bind (Rust.faithful_clone _) (Rust.faithful_pure _)
  · exact Or.inl (congrArg (fun p => p.2.node) (Rust.pure_inj h)).symm

/-- `compact_with(index, value)` on a dynamic node. -/
theorem compact_with_rel' (n : DNode V S MAX CAP) (hp : Pre n)
    (index : Rust.u64) (value : Unit → Rust.M (Checkpoint S MAX)) (r : Rust.Result Unit Error) (n' : DNode V S MAX CAP)
    (h : Node.compact_with n index value = pure (r, n')) : CompactD n index value n' := by
  unfold Node.compact_with at h
  cases ha : Node.available n with
  | Err e =>
    simp only [ha] at h
    exact Or.inl (congrArg Prod.snd (Rust.pure_inj h)).symm
  | Ok u =>
    simp only [ha] at h
    have hI := idle_of_available n ha
    by_cases hc : (decide (index ≤ n.state.base.index) || decide (index > n.state.hard.commit)) = true
    · rw [if_pos hc] at h
      exact Or.inl (congrArg Prod.snd (Rust.pure_inj h)).symm
    rw [if_neg hc] at h
    simp only [Bool.or_eq_true, decide_eq_true_eq, not_or, Fin.not_le, gt_iff_lt, Fin.not_lt] at hc
    rw [id_at_eq _ hp.layout] at h
    cases hid : idAt n.state index.val with
    | none =>
      simp only [hid, Rust.Option.ok_or] at h
      exact Or.inl (congrArg Prod.snd (Rust.pure_inj h)).symm
    | some last =>
      simp only [hid, Rust.Option.ok_or, pure_bind] at h
      obtain ⟨v, hv, h⟩ := Rust.bind_eq_pure h
      obtain ⟨s', hins, hsn, hhard, hr, hl'⟩ := install_spec n.state { last := last, value := v }
        hp.cap_lt hp.layout hp.contig
      have hc' := install_contig n.state s' _ hp.layout hp.contig hsn hr
      rw [hins, pure_bind] at h
      refine Or.inr ⟨hI, Fin.lt_def.mp hc.1, Fin.le_def.mp hc.2, last, v, s', hid, hv, hins, ?_⟩
      have hp1 : Pre { n with state := s', dirty := true, snapshot_changed := true } :=
        { hooks := hp.hooks, layout := hl', contig := hc', n_lt := hp.n_lt, cap_lt := hp.cap_lt, e0 := hp.e0, e1 := hp.e1, uniq := hp.uniq }
      by_cases hrole : n.role = Role.Leader
      · have hrb : (n.role == Role.Leader) = true := by simp [hrole]
        rw [if_pos hrb] at h
        obtain ⟨n2, hb, h⟩ := Rust.bind_eq_pure h
        have hB := barrier_rel' _ _ hp1 hb
        rw [broadcast_eq' _ hp.n_lt, pure_bind] at h
        exact Or.inr ⟨hrole, n2, hB, (congrArg Prod.snd (Rust.pure_inj h)).symm⟩
      · have : (n.role == Role.Leader) = false := by simpa using hrole
        simp only [this, Bool.false_eq_true, if_false] at h
        exact Or.inl ⟨hrole, (congrArg Prod.snd (Rust.pure_inj h)).symm⟩

/-- `Cluster::compact(index, application)`: the snapshot carries the configuration at `index`. -/
theorem cluster_compact_rel (c : Cluster V S MAX CAP) (hp : Pre c.node) (index : Rust.u64) (app : S)
    (r : Rust.Result Unit Error) (c' : Cluster V S MAX CAP) (h : Cluster.compact c index app = pure (r, c')) :
    ∃ value : Unit → Rust.M (Checkpoint S MAX),
      (∀ v, value () = pure v → v.membership = (memAt c.node.state c.node.bootstrap index).2) ∧
      CompactD c.node index value c'.node := by
  unfold Cluster.compact at h
  dsimp only at h
  rw [membership_at_eq _ hp.hooks hp.layout, pure_bind] at h
  obtain ⟨⟨r1, m⟩, hm, h⟩ := Rust.bind_eq_pure h
  have hm' : c'.node = m := (congrArg (fun p => p.2.node) (Rust.pure_inj h)).symm
  refine ⟨_, fun v hv => ?_, hm' ▸ compact_with_rel' _ hp index _ r1 m hm⟩
  obtain ⟨a, -, hv⟩ := Rust.bind_eq_pure hv
  rw [← Rust.pure_inj hv]

/-- The projection `voters` reads off each slot. -/
def voterOf : Option Member → Option Id
  | none => none
  | some s => if s.voter then some s.id else none

theorem voters_eq' {MAX : Nat} (m : Membership MAX) : m.voters = m.members.toList.filterMap voterOf := by
  rw [MembershipProjection.voters_exact]
  rfl

theorem filterMap_set {α β : Type} (f : α → Option β) (l : List α) (i : Nat) (x : α) (hi : i < l.length)
    (hx : f x = f l[i]) : (l.set i x).filterMap f = l.filterMap f := by
  induction l generalizing i with
  | nil => simp at hi
  | cons y ys ih =>
    cases i with
    | zero => simp only [List.getElem_cons_zero] at hx; simp [List.filterMap_cons, hx]
    | succ i =>
      simp only [List.set_cons_succ, List.filterMap_cons]
      rw [ih i (by simp at hi; omega) (by simpa using hx)]

/-- Adding a learner flag leaves the voters unchanged. -/
theorem incSpec_learner_voters {MAX : Nat} (m m' : Membership MAX) (id : Id)
    (h : incSpec m id 1 = some m') : m'.voters = m.voters := by
  obtain ⟨i, hi, -, hc, rfl⟩ := incSpec_some m m' id 1 h
  rw [voters_eq', voters_eq']
  simp only [Vector.toList_set]
  apply filterMap_set _ _ _ _ (by simpa using hi)
  simp only [Vector.getElem_toList]
  rcases hc with ⟨s, hs, -⟩ | ⟨hs, -⟩
  · rw [hs]; simp [setFlag, voterOf]
  · rw [hs]; simp [setFlag, voterOf, blank]

theorem pass_learner_voters {MAX : Nat} (dup : Bool) (extra : Id → Bool) (seen l : List Id)
    (m r : Membership MAX) (h : pass dup extra 1 seen l m = .ok r) : r.voters = m.voters := by
  induction l generalizing seen m with
  | nil => simp only [pass] at h; cases h; rfl
  | cons x xs ih =>
    simp only [pass] at h
    split at h
    · cases h
    · rename_i m' hm
      rw [ih _ _ h]
      unfold stepOk at hm
      split at hm
      · cases hm
      · exact incSpec_learner_voters _ _ _ hm

/-- A fresh voter record. -/
def vSlot (x : Id) : Option Member := some { id := x, voter := true, old := false, learner := false }

theorem findSlot_fresh (P : List Id) (k : Nat) (x : Id) (hx : x ∉ P) :
    findSlot (P.map vSlot ++ List.replicate (k + 1) none) x = some P.length := by
  unfold findSlot
  have h1 : List.findIdx? (fun o => Rust.Option.is_some_and o (fun s => s.id == x)) (P.map vSlot ++ List.replicate (k + 1) none) = none := by
    rw [List.findIdx?_eq_none_iff]
    intro o ho
    simp only [List.mem_append, List.mem_map, List.mem_replicate] at ho
    rcases ho with ⟨y, hy, rfl⟩ | ⟨-, rfl⟩
    · simp only [vSlot, Rust.Option.is_some_and]
      rw [beq_eq_false_iff_ne]; intro e; subst e; exact hx hy
    · rfl
  rw [h1, List.findIdx?_append]
  have h2 : List.findIdx? (fun o : Option Member => o.isNone) (P.map vSlot) = none := by
    rw [List.findIdx?_eq_none_iff]
    intro o ho
    simp only [List.mem_map] at ho
    obtain ⟨y, -, rfl⟩ := ho
    rfl
  rw [h2, List.findIdx?_replicate]
  simp

theorem pass_voters_fresh {MAX : Nat} (l : List Id) (P : List Id) (k : Nat) (seen : List Id)
    (m r : Membership MAX) (hm : m.members.toList = P.map vSlot ++ List.replicate k none)
    (hnd : (P ++ l).Nodup) (h : pass false (fun _ => false) 0 seen l m = .ok r) : r.voters = P ++ l := by
  induction l generalizing P k seen m with
  | nil =>
    simp only [pass] at h; cases h
    rw [voters_eq', hm]
    simp only [List.filterMap_append, List.append_nil]
    have : (List.replicate k (none : Option Member)).filterMap voterOf = [] := by
      induction k with
      | zero => rfl
      | succ k ih => simp [List.replicate_succ, voterOf]
    rw [this, List.append_nil]
    clear hm hnd
    induction P with
    | nil => rfl
    | cons y ys ih => simp only [List.map_cons, List.filterMap_cons, vSlot, voterOf, if_true]; rw [ih]
  | cons x xs ih =>
    simp only [pass] at h
    split at h
    · cases h
    rename_i m' hm'
    unfold stepOk at hm'
    simp only [Bool.false_and, Bool.or_false, Bool.false_eq_true, if_false] at hm'
    have hx : x ∉ P := by
      intro hxP
      have := (List.nodup_append.mp hnd).2.2 x hxP x (by simp)
      exact this rfl
    cases k with
    | zero =>
      unfold incSpec at hm'
      have : findSlot m.members.toList x = none := by
        rw [hm]; unfold findSlot
        simp only [List.replicate_zero, List.append_nil]
        have h1 : List.findIdx? (fun o => Rust.Option.is_some_and o (fun s => s.id == x)) (P.map vSlot) = none := by
          rw [List.findIdx?_eq_none_iff]
          intro o ho
          simp only [List.mem_map] at ho
          obtain ⟨y, hy, rfl⟩ := ho
          simp only [vSlot, Rust.Option.is_some_and]
          rw [beq_eq_false_iff_ne]; intro e; subst e; exact hx hy
        have h2 : List.findIdx? (fun o : Option Member => o.isNone) (P.map vSlot) = none := by
          rw [List.findIdx?_eq_none_iff]
          intro o ho
          simp only [List.mem_map] at ho
          obtain ⟨y, -, rfl⟩ := ho
          rfl
        rw [h1, h2]; rfl
      rw [this] at hm'; cases hm'
    | succ k =>
      have hlen : m.members.toList.length = MAX := by simp
      have hPk : P.length + (k + 1) = MAX := by rw [← hlen, hm]; simp
      unfold incSpec at hm'
      rw [hm, findSlot_fresh P k x hx] at hm'
      simp only [show P.length < MAX by omega, dif_pos] at hm'
      cases hm'
      have hget : m.members[P.length] = none := by
        rw [← Vector.getElem_toList (by simp; omega)]
        simp only [hm, List.getElem_append_right (by simp : (P.map vSlot).length ≤ P.length)]
        simp
      have := ih (P ++ [x]) k (seen ++ [x]) _ ?_ (by simpa using hnd) h
      · simpa using this
      · rw [Vector.toList_set, hm, hget]
        rw [List.set_append_right _ _ (by simp)]
        simp [List.replicate_succ, setFlag, blank, vSlot]

theorem voters_nodup {MAX : Nat} (m : Membership MAX) (h : UniqueIdentities m) : m.voters.Nodup :=
  List.Nodup.sublist ((List.filter_sublist).map _) h

theorem old_voters_nodup {MAX : Nat} (m : Membership MAX) (h : UniqueIdentities m) : m.old_voters.Nodup :=
  List.Nodup.sublist ((List.filter_sublist).map _) h

/-- `with_learners` keeps the voters, in order. -/
theorem with_learners_voters {MAX : Nat} (m : Membership MAX) (learners : Array Id) (hMAX : MAX < 2 ^ Rust.usizeBits)
    (hl : learners.size < 2 ^ Rust.usizeBits) (hnd : m.voters.Nodup) (r : Membership MAX)
    (success : m.with_learners learners = pure (.Ok r)) : r.voters = m.voters := by
  obtain ⟨a, h1, h2⟩ := LearnerReplacement.with_learners_ok m learners hMAX hl r success
  rw [pass_learner_voters _ _ _ _ _ _ h2]
  have := pass_voters_fresh m.voters [] MAX [] (empty MAX) a (by simp [empty]) (by simpa using hnd) h1
  simpa using this

theorem ite_err_ok {b : Bool} {e : Error} {k : Rust.M (Rust.Result Unit Error)} {u : Unit}
    (h : (if b = true then pure (.Err e) else k) = pure (.Ok u)) : b = false ∧ k = pure (.Ok u) := by
  cases b
  · exact ⟨rfl, h⟩
  · simp only [if_true] at h; cases Rust.pure_inj h

/-- What a successful `change_available` checked. -/
theorem change_available_ok (c : Cluster V S MAX CAP) (hp : Pre c.node) (u : Unit)
    (h : Cluster.change_available c = pure (.Ok u)) :
    Idle c.node ∧ c.node.role = .Leader ∧
      Membership.is_joint (memAt c.node.state c.node.bootstrap (lastId c.node.state).index).2 = false ∧
      (memAt c.node.state c.node.bootstrap (lastId c.node.state).index).1 ≤ c.node.state.hard.commit := by
  unfold Cluster.change_available at h
  dsimp only at h
  split at h
  · rename_i hid
    have hI := idle_of_available c.node hid
    split at h
    · cases Rust.pure_inj h
    rename_i hrole
    dsimp only [Cluster.state, Node.state_fn, State.hard_fn] at h
    rw [last_eq _ hp.layout.1, pure_bind, membership_at_eq _ hp.hooks hp.layout, pure_bind] at h
    obtain ⟨hj, -⟩ := ite_err_ok h
    simp only [Bool.or_eq_false_iff, decide_eq_false_iff_not, gt_iff_lt, Fin.not_lt] at hj
    exact ⟨hI, by simpa [Cluster.role, Node.role_fn] using hrole, hj.1, hj.2⟩
  · cases Rust.pure_inj h


theorem keys_fin_sublist (l : List (Option Member)) :
    ((Rust.Iter.flatten (l.map Finalization.finSlot)).map Member.id).Sublist ((Rust.Iter.flatten l).map Member.id) := by
  induction l with
  | nil => simp [Rust.Iter.flatten]
  | cons e l ih =>
    simp only [Rust.Iter.flatten] at ih ⊢
    cases e with
    | none => simpa [Finalization.finSlot] using ih
    | some s =>
      by_cases k : (s.voter || s.learner) = true
      · simp only [List.map_cons, Finalization.finSlot, if_pos k, List.filterMap_cons, id]
        exact List.Sublist.cons_cons _ ih
      · simp only [List.map_cons, Finalization.finSlot, if_neg k, List.filterMap_cons, id]
        exact List.Sublist.cons _ ih

theorem finalized_memOk {MAX : Nat} (m : Membership MAX) (h : MemOk m) : MemOk m.finalized := by
  refine ⟨?_, by rw [MembershipProjection.finalization_preserves_voters]; exact h.2⟩
  have hs := keys_fin_sublist m.members.toList
  unfold UniqueIdentities Keys occ
  rw [Finalization.finalized_members, Vector.toList_map]
  exact List.Nodup.sublist hs h.1

/-- `Node.propose` of a configuration record. -/
theorem propose_cfg_rel (n : DNode V S MAX CAP) (hp : Pre n) (X : Membership MAX)
    (r : Rust.Result LogId Error) (m : DNode V S MAX CAP)
    (h : Node.propose n (Record.Configuration X) = pure (r, m)) : ProposeD n [Record.Configuration X] m := by
  unfold Node.propose at h
  dsimp only at h
  obtain ⟨⟨r1, m1⟩, hm, h⟩ := Rust.bind_eq_pure h
  have hm' : m = m1 := by
    split at h <;> (simp only at h; exact (congrArg Prod.snd (Rust.pure_inj h)).symm)
  rw [hm']
  refine propose_many_rel' n hp [Record.Configuration X] _ rfl (fun i hi => ?_) 1 rfl r1 m1 hm
  obtain rfl : i = 0 := by simp at hi; omega
  exact Rust.faithful_bind (Rust.faithful_pure _) (Rust.faithful_pure _)

theorem reconfig_of (n : DNode V S MAX CAP) (hp : Pre n) (hI : Idle n) (hl : n.role = .Leader)
    (X : Membership MAX) (hok : MemOk X)
    (hc : (memAt n.state n.bootstrap (lastId n.state).index).1 ≤ n.state.hard.commit)
    (hX : (Membership.is_joint n.membership = false ∧
        (X = n.membership ∨ (X.voters = n.membership.voters ∧ X.is_joint = false)) ∨
        (X.is_joint = true ∧ X.old_voters.Perm n.membership.voters)) ∨
      (Membership.is_joint n.membership = true ∧ X = Membership.finalized n.membership))
    (r : Rust.Result LogId Error) (m : DNode V S MAX CAP)
    (h : Node.propose n (Record.Configuration X) = pure (r, m)) : ReconfigD n m :=
  Or.inr ⟨X, propose_cfg_rel n hp X r m h, hok, hI, hl, hc, hX⟩

theorem cluster_set_learners_rel (c : Cluster V S MAX CAP) (hp : Pre c.node)
    (hmem : c.node.membership = memOf c.node.state c.node.bootstrap) (hm : MemOk c.node.membership)
    (learners : Array Id) (hl : learners.size < 2 ^ Rust.usizeBits)
    (r : Rust.Result LogId Error) (c' : Cluster V S MAX CAP) (h : Cluster.set_learners c learners = pure (r, c')) :
    ReconfigD c.node c'.node := by
  unfold Cluster.set_learners at h
  dsimp only at h
  obtain ⟨t1, hca, h⟩ := Rust.bind_eq_pure h
  rcases t1 with u | e
  rotate_left
  · exact Or.inl (congrArg (fun p => p.2.node) (Rust.pure_inj h)).symm
  obtain ⟨hI, hL, hJ, hC⟩ := change_available_ok c hp u hca
  rw [memAt_last _ _ hp.contig, ← hmem] at hJ
  simp only [pure_bind, Cluster.membership] at h
  obtain ⟨t3, -, h⟩ := Rust.bind_eq_pure h
  split at h
  · exact Or.inl (congrArg (fun p => p.2.node) (Rust.pure_inj h)).symm
  obtain ⟨t4, hw, h⟩ := Rust.bind_eq_pure h
  rcases t4 with X | e
  rotate_left
  · exact Or.inl (congrArg (fun p => p.2.node) (Rust.pure_inj h)).symm
  simp only at h
  obtain ⟨t6, -, h⟩ := Rust.bind_eq_pure h
  split at h
  · exact Or.inl (congrArg (fun p => p.2.node) (Rust.pure_inj h)).symm
  obtain ⟨⟨r1, m⟩, hpr, h⟩ := Rust.bind_eq_pure h
  rw [show c'.node = m from (congrArg (fun p => p.2.node) (Rust.pure_inj h)).symm]
  have hv := with_learners_voters _ learners hp.n_lt hl (voters_nodup _ hm.1) X hw
  refine reconfig_of c.node hp hI hL X ⟨LearnerReplacement.unique_identities _ learners hp.n_lt hl X hw, hv ▸ hm.2⟩ hC ?_ r1 m hpr
  exact Or.inl (Or.inl ⟨hJ, Or.inr ⟨hv,
    LearnerReplacement.not_joint _ learners hp.n_lt hl X hw⟩⟩)

set_option linter.unusedVariables false in
theorem cluster_reconfigure_rel (c : Cluster V S MAX CAP) (hp : Pre c.node)
    (hmem : c.node.membership = memOf c.node.state c.node.bootstrap) (hm : MemOk c.node.membership)
    (target : Membership MAX) (ht : MemOk target)
    (r : Rust.Result LogId Error) (c' : Cluster V S MAX CAP) (h : Cluster.reconfigure c target = pure (r, c')) :
    ReconfigD c.node c'.node := by
  unfold Cluster.reconfigure at h
  dsimp only at h
  obtain ⟨t1, hca, h⟩ := Rust.bind_eq_pure h
  rcases t1 with u | e
  rotate_left
  · exact Or.inl (congrArg (fun p => p.2.node) (Rust.pure_inj h)).symm
  obtain ⟨hI, hL, -, hC⟩ := change_available_ok c hp u hca
  simp only [pure_bind, Cluster.membership] at h
  split at h
  · exact Or.inl (congrArg (fun p => p.2.node) (Rust.pure_inj h)).symm
  obtain ⟨st, hst, h⟩ := Rust.bind_eq_pure h
  have hinv := forIn_pure_inv _ _ _ (fun _ b => ∀ p, b.1 = some p → p.2 = c) (by intro p hp; cases hp)
    (fun k hk b b' _ => by
      constructor
      · intro hy
        split at hy
        · obtain ⟨_, -, hy⟩ := Rust.bind_eq_pure hy
          obtain ⟨_, -, hy⟩ := Rust.bind_eq_pure hy
          split at hy <;> cases Rust.pure_inj hy <;> (intro p hp; cases hp)
        · split at hy <;> cases Rust.pure_inj hy <;> (intro p hp; cases hp)
      · intro hy m _ _
        split at hy
        · obtain ⟨_, -, hy⟩ := Rust.bind_eq_pure hy
          obtain ⟨_, -, hy⟩ := Rust.bind_eq_pure hy
          split at hy <;> cases Rust.pure_inj hy <;> (intro p hp; cases hp; rfl)
        · split at hy <;> cases Rust.pure_inj hy <;> (intro p hp; cases hp; rfl)) st hst
  split at h
  · rename_i p hp
    have := hinv p hp
    have e := Rust.pure_inj h
    subst e
    exact Or.inl (congrArg Cluster.node this)
  obtain ⟨t6, -, h⟩ := Rust.bind_eq_pure h
  split at h
  · exact Or.inl (congrArg (fun p => p.2.node) (Rust.pure_inj h)).symm
  obtain ⟨t7, hj, h⟩ := Rust.bind_eq_pure h
  rcases t7 with X | e
  rotate_left
  · exact Or.inl (congrArg (fun p => p.2.node) (Rust.pure_inj h)).symm
  simp only at h
  obtain ⟨⟨r1, m⟩, hpr, h⟩ := Rust.bind_eq_pure h
  rw [show c'.node = m from (congrArg (fun p => p.2.node) (Rust.pure_inj h)).symm]
  have hXu := JointConstruction.unique_identities _ target X hp.n_lt ht.1 hj
  have hXv : X.voters ≠ [] := by
    obtain ⟨q, hq⟩ := List.exists_mem_of_ne_nil _ ht.2
    exact List.ne_nil_of_mem ((JointConstruction.voters_exact _ target X hp.n_lt hj q).mpr hq)
  refine reconfig_of c.node hp hI hL X ⟨hXu, hXv⟩ hC ?_ r1 m hpr
  refine Or.inl (Or.inr ⟨(JointConstruction.joint_iff_source_voters _ target X hp.n_lt hj).mpr hm.2, ?_⟩)
  exact (List.perm_ext_iff_of_nodup (old_voters_nodup X hXu) (voters_nodup _ hm.1)).mpr
    (fun a => JointConstruction.old_voters_exact _ target X hp.n_lt hj a)

theorem cluster_finish_rel (c : Cluster V S MAX CAP) (hp : Pre c.node)
    (hmem : c.node.membership = memOf c.node.state c.node.bootstrap) (hm : MemOk c.node.membership)
    (r : Rust.Result LogId Error) (c' : Cluster V S MAX CAP) (h : Cluster.finish_reconfiguration c = pure (r, c')) :
    ReconfigD c.node c'.node := by
  unfold Cluster.finish_reconfiguration at h
  dsimp only at h
  split at h
  · rename_i hid
    have hI := idle_of_available c.node hid
    split at h
    · exact Or.inl (congrArg (fun p => p.2.node) (Rust.pure_inj h)).symm
    rename_i hrole
    have hL : c.node.role = .Leader := by simpa [Cluster.role, Node.role_fn] using hrole
    dsimp only [Cluster.state, Node.state_fn, State.hard_fn] at h
    rw [last_eq _ hp.layout.1, pure_bind, membership_at_eq _ hp.hooks hp.layout, pure_bind] at h
    rw [memAt_last _ _ hp.contig, ← hmem] at h
    split at h
    · rename_i hj
      simp only [pure_bind] at h
      split at h
      · exact Or.inl (congrArg (fun p => p.2.node) (Rust.pure_inj h)).symm
      rename_i hc
      obtain ⟨⟨r1, m⟩, hpr, h⟩ := Rust.bind_eq_pure h
      rw [show c'.node = m from (congrArg (fun p => p.2.node) (Rust.pure_inj h)).symm]
      simp only [decide_eq_true_eq, gt_iff_lt, Fin.not_lt] at hc
      exact reconfig_of c.node hp hI hL _ (finalized_memOk _ hm) hc (Or.inr ⟨by simpa using hj, rfl⟩) r1 m hpr
    · simp only [pure_bind, if_true] at h
      exact Or.inl (congrArg (fun p => p.2.node) (Rust.pure_inj h)).symm
  · exact Or.inl (congrArg (fun p => p.2.node) (Rust.pure_inj h)).symm

end Jarl.Engine.Dyn
