import Engine.Dyn.Common

/-!
# Error outcomes of the public `Cluster` operations

For each public operation, what an `Err` result means: which check failed and
what (if anything) changed. Every proposal-like operation (`propose`,
`propose_batch`, `compact`, `set_learners`, `reconfigure`,
`finish_reconfiguration`) leaves the cluster unchanged on every error; `step`
leaves it unchanged on its only errors (`Busy`, `Message`); `tick` leaves it
unchanged when `Busy` and changes exactly the elapsed time and leader age when
the term is exhausted. Successful proposals report the identity of the entry
they appended.
-/

set_option linter.unusedSectionVars false

namespace Jarl.Engine.Dyn
open Jarl Jarl.Engine

variable {V S : Type} {MAX CAP : Nat} [Rust.Clone V] [Rust.Clone S]

/-! ## Availability -/

theorem errs_avail_err {N : Nat} (n : Node V S N CAP) (e : Error) (h : Node.available n = .Err e) :
    e = .Busy ∧ ¬ Idle n := by
  unfold Node.available at h
  split at h
  · rename_i hc
    cases h
    refine ⟨rfl, fun ⟨hd, he, ho⟩ => ?_⟩
    simp only [hd, he, Option.isSome_none, Bool.or_false, Bool.false_or, List.any_eq_true] at hc
    obtain ⟨x, hx, hs⟩ := hc
    rw [List.mem_iff_getElem] at hx
    obtain ⟨i, hi, rfl⟩ := hx
    have := ho ⟨i, by simpa using hi⟩
    simp_all
  · cases h

theorem errs_avail_busy {N : Nat} (n : Node V S N CAP) (h : ¬ Idle n) : Node.available n = .Err .Busy := by
  cases ha : Node.available n with
  | Ok u => exact absurd (idle_of_available n (by cases u; exact ha)) h
  | Err e => rw [(errs_avail_err n e ha).1]

theorem errs_exit {α β : Type} {e : Error} {x x' : β} {r : Rust.Result α Error}
    (h : (pure (.Err e, x) : Rust.M _) = pure (r, x')) : r = .Err e ∧ x' = x := by
  have := Rust.pure_inj h
  simp only [Prod.mk.injEq] at this
  exact ⟨this.1.symm, this.2.symm⟩

theorem errs_fst {α β : Type} {a b : α} {x y : β} (h : (pure (a, x) : Rust.M _) = pure (b, y)) : a = b :=
  congrArg Prod.fst (Rust.pure_inj h)

/-! ## `propose_many` -/

/-- Why `propose_many(count, _)` fails, in the order it checks. -/
def PMErr (n : DNode V S MAX CAP) (count : Rust.usize) (e : Error) : Prop :=
  (e = .Busy ∧ ¬ Idle n) ∨
  (Idle n ∧ ((e = .NotLeader n.leader ∧ n.role ≠ .Leader) ∨
    (n.role = .Leader ∧ ((e = .Config ∧ count.val = 0) ∨
      (0 < count.val ∧ ((e = .Full ∧ CAP - (ret n.state).length < count.val) ∨
        (e = .Exhausted ∧ count.val ≤ CAP - (ret n.state).length ∧
          2 ^ 64 ≤ (lastId n.state).index.val + count.val)))))))

/-- The entry `propose_many` appends at offset `i` for value `v`. -/
def errsEntry (n : DNode V S MAX CAP) (i : Nat) (v : Record V MAX) : DEntry V MAX :=
  { id := { index := Rust.ofNat ((lastId n.state).index.val + 1 + i), term := n.state.hard.term }, value := some v }

/-- Every outcome of `propose_many(count, values)`: an error leaves the node
    unchanged, for the reason `PMErr` gives; success appends one entry per
    value (whatever each value computation returned) and reports their range. -/
theorem errs_pm (n : DNode V S MAX CAP) (hp : Pre n) (count : Rust.usize)
    (values : List (Rust.M (Record V MAX))) (hvlen : values.length = count.val)
    (r : Rust.Result ProposalRange Error) (n' : DNode V S MAX CAP)
    (h : Node.propose_many n count values = pure (r, n')) :
    (∃ e, r = .Err e ∧ n' = n ∧ PMErr n count e) ∨
    (Idle n ∧ n.role = .Leader ∧ 0 < count.val ∧ (lastId n.state).index.val + count.val < 2 ^ 64 ∧
      r = .Ok { first := { index := Rust.ofNat ((lastId n.state).index.val + 1), term := n.state.hard.term },
                last := { index := Rust.ofNat ((lastId n.state).index.val + count.val), term := n.state.hard.term } } ∧
      ∃ L : List (DEntry V MAX), L.length = count.val ∧
        (∀ i (hi : i < L.length), ∃ v, values[i]? = some (pure v) ∧ L[i] = errsEntry n i v) ∧
        ∃ (s' : DState V S MAX CAP) (n1 n2 : DNode V S MAX CAP),
          ret s' = ret n.state ++ L ∧ s'.hard = n.state.hard ∧ s'.snapshot = n.state.snapshot ∧
          Layout s' ∧ Contig s' ∧
          Refresh { n with state := s', dirty := true, log_from := some (Rust.ofNat ((lastId n.state).index.val + 1)) } n1 ∧
          Adv' { n1 with matched := if h : n1.local.val < MAX then n1.matched.set n1.local.val (Rust.ofNat ((lastId n.state).index.val + count.val)) h else n1.matched } n2 ∧
          n' = bcastD n2) := by
  unfold Node.propose_many at h
  rcases ha : Node.available n with u | e
  rotate_left
  · simp only [ha] at h
    obtain ⟨rfl, hn⟩ := errs_exit h
    exact Or.inl ⟨e, rfl, hn, Or.inl (errs_avail_err n e ha)⟩
  simp only [ha] at h
  have hI := idle_of_available n (by cases u; exact ha)
  by_cases hrole : (n.role != Role.Leader) = true
  · rw [if_pos hrole] at h
    obtain ⟨rfl, hn⟩ := errs_exit h
    exact Or.inl ⟨_, rfl, hn, Or.inr ⟨hI, Or.inl ⟨rfl, by simpa using hrole⟩⟩⟩
  rw [if_neg hrole] at h
  have hrole' : n.role = Role.Leader := by simpa using hrole
  by_cases hz : (count == 0) = true
  · rw [if_pos hz] at h
    obtain ⟨rfl, hn⟩ := errs_exit h
    have : count = 0 := by simpa using hz
    exact Or.inl ⟨_, rfl, hn, Or.inr ⟨hI, Or.inr ⟨hrole', Or.inl ⟨rfl, by rw [this]; rfl⟩⟩⟩⟩
  rw [if_neg hz] at h
  have hpos : 0 < count.val := by
    have : count ≠ 0 := by simpa using hz
    exact Nat.pos_of_ne_zero fun e => this (Fin.ext e)
  have hl := hp.layout
  have hcap : CAP < 2 ^ Rust.usizeBits := hp.cap_lt
  have hlen := len_eq _ hl
  have hrc : (Rust.Iter.count (ret n.state)).val = (ret n.state).length := by
    simp [Rust.Iter.count, Rust.ofNat]; have := hl.1; omega
  have hCv := Rust.val_usizeOf _ hcap
  rw [entries_fn_eq _ hl.1, pure_bind, Rust.sub_ok _ _ (by rw [hrc, hCv]; have := hl.1; omega), pure_bind] at h
  by_cases hfull : decide (count > (⟨(Rust.usizeOf CAP).val - (Rust.Iter.count (ret n.state)).val, by omega⟩ : Rust.usize)) = true
  · rw [if_pos hfull] at h
    obtain ⟨rfl, hn⟩ := errs_exit h
    have : CAP - (ret n.state).length < count.val := by
      simp only [decide_eq_true_eq, gt_iff_lt, Fin.lt_def, hrc, hCv] at hfull; omega
    exact Or.inl ⟨_, rfl, hn, Or.inr ⟨hI, Or.inr ⟨hrole', Or.inr ⟨hpos, Or.inl ⟨rfl, this⟩⟩⟩⟩⟩
  rw [if_neg hfull] at h
  have hroom : count.val ≤ CAP - (ret n.state).length := by
    simp only [decide_eq_true_eq, gt_iff_lt, Fin.lt_def, hrc, hCv] at hfull; omega
  have htry : ((Rust.try_from (m := 64) count).map_err fun _ => Error.Exhausted) =
      Rust.Result.Ok (⟨count.val, usize_lt_u64 count⟩ : Rust.u64) := by
    simp [Rust.try_from, Rust.Result.map_err, usize_lt_u64 count]
  rw [last_eq _ hl.1, pure_bind, htry] at h
  simp only [pure_bind] at h
  by_cases hov : (lastId n.state).index.val + count.val < 2 ^ 64
  rotate_left
  · simp only [Rust.checked_add_eq, dif_neg hov, Rust.Option.ok_or] at h
    obtain ⟨rfl, hn⟩ := errs_exit h
    exact Or.inl ⟨_, rfl, hn, Or.inr ⟨hI, Or.inr ⟨hrole', Or.inr ⟨hpos, Or.inr ⟨rfl, hroom, by omega⟩⟩⟩⟩⟩
  simp only [Rust.checked_add_eq, dif_pos hov, Rust.Option.ok_or] at h
  rw [Rust.add_ok _ _ (by simp; omega)] at h
  simp only [pure_bind] at h
  have hF : (lastId n.state).index.val + (1 : Rust.u64).val < 2 ^ 64 := by simp; omega
  have hcont := hp.contig
  have hLb := lastId_eq n.state hcont
  refine (fun key => ?_) (forIn_bind_elim _ _ _ _ _
    (fun k b => ∃ (sk : DState V S MAX CAP) (L : List (DEntry V MAX)),
      b = (none, { n with state := sk }, { state := sk, «from» := ⟨_, hF⟩, finished := false }) ∧
      ret sk = ret n.state ++ L ∧ L.length = k ∧
      (∀ i (hi : i < L.length), ∃ v, values[i]? = some (pure v) ∧ L[i] = errsEntry n i v) ∧
      sk.hard = n.state.hard ∧ sk.snapshot = n.state.snapshot ∧ Layout sk ∧ Contig sk)
    ⟨n.state, [], rfl, by simp, rfl, by simp, rfl, rfl, hl, hcont⟩ ?step h)
  case step =>
    intro k hk b ⟨sk, L, hb, hr, hL, hLv, hh, hs, hlk, hck⟩ st hst
    subst hb
    simp only [enumerate_get] at hst
    obtain ⟨v, hv, hst⟩ := Rust.bind_eq_pure hst
    rw [enumerate_length] at hk
    have hkv64 : (Rust.ofNat k : Rust.u64).val = k := by
      have := usize_lt_u64 count; simp [Rust.ofNat]; uomega
    try simp only [cast_ofNat_usize k (by omega)] at hst
    have hlenk : (ret sk).length = (ret n.state).length + k := by
      rw [hr]; simp [hL]
    have hbase : sk.base = n.state.base := by simp [State.base, hs]
    have hadd : (⟨(lastId n.state).index.val + (1 : Rust.u64).val, hF⟩ : Rust.u64).val + (Rust.ofNat k : Rust.u64).val < 2 ^ 64 := by
      rw [hkv64]; simp; omega
    obtain ⟨s2, hp2, hh2, hs2, hr2, -, hl2⟩ := push_ok sk
      { id := { index := ⟨_, hadd⟩, term := n.state.hard.term }, value := some v } hcap hlk
      (by rw [len_eq _ hlk]; omega)
    have hidx : (⟨_, hadd⟩ : Rust.u64) = Rust.ofNat ((lastId n.state).index.val + 1 + k) := by
      apply Fin.ext; simp [Rust.ofNat]; uomega
    refine ⟨_, ?_, s2, L ++ [errsEntry n k v], rfl, ?_, by simp [hL], ?_, hh2.trans hh, hs2.trans hs, hl2, ?_⟩
    · simp only [Rust.add_ok _ _ hadd, pure_bind, hp2] at hst
      exact (Rust.pure_inj hst).symm
    · rw [hr2, hr, hidx]; simp [errsEntry]
    · intro i hi
      rw [List.length_append, List.length_singleton] at hi
      by_cases hik : i < L.length
      · rw [List.getElem_append_left hik]; exact hLv i hik
      · have hik' : i = k := by omega
        subst hik'
        refine ⟨v, ?_, ?_⟩
        · rw [List.getElem?_eq_getElem (by omega), hv]
        · rw [List.getElem_append_right (by omega)]; simp [hL]
    · apply contig_push sk s2 _ hck (by simp [State.base, hs2]) hr2
      simp only [hkv64, hbase]; simp; omega
  obtain ⟨b, ⟨sk, L, hb, hr, hL, hLv, hh, hs, hlk, hck⟩, h⟩ := key
  subst hb
  rw [enumerate_length] at hL
  simp only [BatchRollback.drop, Bool.not_true, Bool.false_eq_true, if_false, pure_bind] at h
  have e1 : (⟨(lastId n.state).index.val + count.val, hov⟩ : Rust.u64) = Rust.ofNat ((lastId n.state).index.val + count.val) := by
    apply Fin.ext; simp [Rust.ofNat]; uomega
  have e2 : (⟨(lastId n.state).index.val + (1 : Rust.u64).val, hF⟩ : Rust.u64) = Rust.ofNat ((lastId n.state).index.val + 1) := by
    apply Fin.ext; simp [Rust.ofNat]; uomega
  rw [e1, e2] at h
  obtain ⟨n1, hr1, h⟩ := Rust.bind_eq_pure h
  have hp0 : Pre { n with state := sk, dirty := true, log_from := some (Rust.ofNat ((lastId n.state).index.val + 1)) } :=
    { hooks := hp.hooks, layout := hlk, contig := hck, n_lt := hp.n_lt, cap_lt := hp.cap_lt, e0 := hp.e0, e1 := hp.e1, uniq := hp.uniq }
  have hR := refresh_rel _ _ hp0.hooks hp0.layout hp0.contig hp.n_lt hp0.e0 hp0.e1 hp0.uniq hr1
  have hp1 := pre_refresh_p _ _ hp0 hR
  have hpm : Pre { n1 with matched := if h : n1.local.val < MAX then n1.matched.set n1.local.val (Rust.ofNat ((lastId n.state).index.val + count.val)) h else n1.matched } :=
    { hp1 with layout := hp1.layout, contig := hp1.contig, uniq := hp1.uniq }
  have hLc : L.length = count.val := by rw [hL, hvlen]
  have key2 : ∃ b m, Node.advance_commit { n1 with matched := if h : n1.local.val < MAX then n1.matched.set n1.local.val (Rust.ofNat ((lastId n.state).index.val + count.val)) h else n1.matched } = pure (b, m) ∧
      (do let m_3 ← Node.broadcast m; pure (Rust.Result.Ok ({ first := { index := Rust.ofNat ((lastId n.state).index.val + 1), term := n.state.hard.term }, last := { index := Rust.ofNat ((lastId n.state).index.val + count.val), term := n.state.hard.term } } : ProposalRange), m_3)) = (pure (r, n') : Rust.M _) := by
    by_cases hlt : n1.local.val < MAX
    · have hd : decide (n1.local < Rust.usizeOf MAX) = true := by
        simp [Fin.lt_def, Rust.val_usizeOf _ hp.n_lt, hlt]
      simp only [hd, if_true, Rust.Slice.set_ok _ _ _ hlt, pure_bind] at h
      obtain ⟨⟨b, m⟩, hm, h⟩ := Rust.bind_eq_pure h
      exact ⟨b, m, by simpa [hlt] using hm, h⟩
    · have hd : decide (n1.local < Rust.usizeOf MAX) = false := by
        simp [Fin.lt_def, Rust.val_usizeOf _ hp.n_lt, hlt]
      simp only [hd, Bool.false_eq_true, if_false] at h
      obtain ⟨⟨b, m⟩, hm, h⟩ := Rust.bind_eq_pure h
      exact ⟨b, m, by simpa [hlt] using hm, h⟩
  obtain ⟨b, m, hm, hb⟩ := key2
  have hA := advance_rel' _ b _ hpm.hooks hpm.layout hpm.contig hp.n_lt hpm.e0 hpm.e1 hpm.uniq hm
  rw [broadcast_eq' _ hp.n_lt, pure_bind] at hb
  have hb' := Rust.pure_inj hb
  simp only [Prod.mk.injEq] at hb'
  exact Or.inr ⟨hI, hrole', hpos, hov, hb'.1.symm, L, hLc, hLv, sk, n1, m, hr, hh, hs, hlk, hck, hR, hA, hb'.2.symm⟩

/-! ## A single appended entry -/

theorem errs_refresh_state (n n' : DNode V S MAX CAP) (h : Refresh n n') : n'.state = n.state := by
  obtain ⟨n1, ⟨hs, -, -⟩, -, hn⟩ := h
  have e1 : n1.state = n.state := by rw [hs]
  rcases hn with rfl | ⟨-, -, -, ⟨r, d, rfl⟩⟩
  · exact e1
  · exact e1

theorem errs_adv_state (n n' : DNode V S MAX CAP) (h : Adv' n n') : ∃ hd, n'.state = { n.state with hard := hd } := by
  rcases h with h | ⟨v, -, -, -, hc⟩
  · subst h; exact ⟨_, rfl⟩
  · rcases hc with ⟨hlt, hR⟩ | ⟨-, h⟩
    · refine ⟨{ n.state.hard with commit := v }, ?_⟩
      rw [errs_refresh_state _ _ hR]
      simp [commitTo, hlt]
    · subst h; exact ⟨_, rfl⟩

/-- `n'` is `n` with one entry holding `x` appended at the identity `id`, the
    next index in the node's current term. -/
def AppendedAt (n n' : DNode V S MAX CAP) (id : LogId) (x : Record V MAX) : Prop :=
  id.index.val = (lastId n.state).index.val + 1 ∧ id.term = n.state.hard.term ∧
  ret n'.state = ret n.state ++ [{ id := id, value := some x }] ∧ n'.state.snapshot = n.state.snapshot ∧
  State.get n'.state id.index = some { id := id, value := some x }

/-- `propose_many(1, [m])` for a value computation `m` faithful to `x`. -/
theorem errs_pm_one (n : DNode V S MAX CAP) (hp : Pre n) (m : Rust.M (Record V MAX)) (x : Record V MAX)
    (hm : Rust.Faithful m x) (r : Rust.Result ProposalRange Error) (n' : DNode V S MAX CAP)
    (h : Node.propose_many n 1 [m] = pure (r, n')) :
    (∃ e, r = .Err e ∧ n' = n ∧ PMErr n 1 e) ∨
    (Idle n ∧ n.role = .Leader ∧ ∃ id, r = .Ok { first := id, last := id } ∧ AppendedAt n n' id x) := by
  rcases errs_pm n hp 1 [m] (by simp) r n' h with he | ⟨hI, hL, -, hov, hr, L, hLc, hLv, s', n1, n2, hret, -, hs, hls, -, hR, hA, rfl⟩
  · exact Or.inl he
  refine Or.inr ⟨hI, hL, ?_⟩
  have h1 : (1 : Rust.usize).val = 1 := by simp
  rw [h1] at hLc hov hr
  obtain ⟨e0, rfl⟩ : ∃ e0, L = [e0] := by
    match L, hLc with
    | [e0], _ => exact ⟨e0, rfl⟩
  obtain ⟨v, hv, he0⟩ := hLv 0 (by simp)
  simp only [List.getElem?_cons_zero, Option.some.injEq] at hv
  obtain rfl := hm v hv
  simp only [List.getElem_cons_zero] at he0
  subst he0
  obtain ⟨hd, hst⟩ := errs_adv_state _ _ hA
  have hst' : (bcastD n2).state = { s' with hard := hd } := by
    show n2.state = _
    rw [hst]
    show { n1.state with hard := hd } = _
    rw [errs_refresh_state _ _ hR]
  have hidv : (Rust.ofNat ((lastId n.state).index.val + 1) : Rust.u64).val = (lastId n.state).index.val + 1 := by
    simp [Rust.ofNat]; omega
  have hb := lastId_eq n.state hp.contig
  refine ⟨_, hr, hidv, rfl, ?_, ?_, ?_⟩
  · rw [hst']; show ret s' = _; rw [hret]; simp [errsEntry]
  · rw [hst']; exact hs
  · rw [hst', get_eq _ (show Layout { s' with hard := hd } from hls)]
    have hbase : State.base { s' with hard := hd } = n.state.base := by simp [State.base, hs]
    rw [hbase, hidv, if_pos (by omega)]
    show (ret s')[_]? = _
    rw [hret, List.getElem?_append_right (by omega)]
    simp [errsEntry, show (lastId n.state).index.val + 1 - n.state.base.index.val - 1 - (ret n.state).length = 0 by omega]

/-- `Node.propose(x)` for a value whose clone is faithful. -/
theorem errs_node_propose (n : DNode V S MAX CAP) (hp : Pre n) (x : Record V MAX)
    (hx : Rust.Faithful (Rust.Clone.clone x) x) (r : Rust.Result LogId Error) (n' : DNode V S MAX CAP)
    (h : Node.propose n x = pure (r, n')) :
    (∃ e, r = .Err e ∧ n' = n ∧ PMErr n 1 e) ∨
    (Idle n ∧ n.role = .Leader ∧ ∃ id, r = .Ok id ∧ AppendedAt n n' id x) := by
  unfold Node.propose at h
  dsimp only at h
  obtain ⟨⟨r1, m1⟩, hm, h2⟩ := Rust.bind_eq_pure h
  rcases errs_pm_one n hp _ x hx r1 m1 hm with ⟨e, he, hn, hc⟩ | ⟨hI, hL, id, hr, hA⟩
  · subst he hn
    simp only at h2
    obtain ⟨rfl, hn⟩ := errs_exit h2
    exact Or.inl ⟨e, rfl, hn, hc⟩
  · subst hr
    simp only [pure_bind] at h2
    have := Rust.pure_inj h2
    simp only [Prod.mk.injEq] at this
    obtain ⟨rfl, rfl⟩ := this
    exact Or.inr ⟨hI, hL, id, rfl, hA⟩

/-! ## `Cluster::propose` and `Cluster::propose_batch` -/

theorem errs_remaining (c : Jarl.Cluster V S MAX CAP) (hp : Pre c.node) (t : Rust.usize)
    (h : Cluster.remaining c = pure t) : t.val = CAP - (ret c.node.state).length := by
  have hl := hp.layout
  have hcap : CAP < 2 ^ Rust.usizeBits := hp.cap_lt
  have hrc : (Rust.Iter.count (ret c.node.state)).val = (ret c.node.state).length := by
    simp [Rust.Iter.count, Rust.ofNat]; have := len_eq _ hl; have := hl.1; omega
  have hCv := Rust.val_usizeOf _ hcap
  unfold Cluster.remaining at h
  simp only [Node.state_fn] at h
  rw [entries_fn_eq _ hl.1, pure_bind, Rust.sub_ok _ _ (by rw [hrc, hCv]; have := len_eq _ hl; have := hl.1; omega)] at h
  rw [← Rust.pure_inj h]
  simp only [hrc, hCv]

/-- Why a proposal of `k` values fails, in the order the checks run: busy,
    not the leader, no room for the values and a reserve of three entries,
    no values, or an index past `u64::MAX`. -/
def PropErr (n : DNode V S MAX CAP) (k : Nat) (e : Error) : Prop :=
  (e = .Busy ∧ ¬ Idle n) ∨
  (Idle n ∧ ((e = .NotLeader n.leader ∧ n.role ≠ .Leader) ∨
    (n.role = .Leader ∧ ((e = .Full ∧ CAP - (ret n.state).length - 3 < k) ∨
      (k ≤ CAP - (ret n.state).length - 3 ∧ ((e = .Config ∧ k = 0) ∨
        (0 < k ∧ e = .Exhausted ∧ 2 ^ 64 ≤ (lastId n.state).index.val + k)))))))

theorem errs_pmErr_room (n : DNode V S MAX CAP) (k : Nat) (count : Rust.usize) (hk : count.val = k) (e : Error)
    (hI : Idle n) (hL : n.role = .Leader) (hroom : k ≤ CAP - (ret n.state).length - 3) (h : PMErr n count e) :
    PropErr n k e := by
  subst hk
  rcases h with ⟨-, hn⟩ | ⟨-, ⟨-, hn⟩ | ⟨-, ⟨rfl, h0⟩ | ⟨hpos, ⟨-, hf⟩ | ⟨rfl, -, hov⟩⟩⟩⟩
  · exact absurd hI hn
  · exact absurd hL hn
  · exact Or.inr ⟨hI, Or.inr ⟨hL, Or.inr ⟨hroom, Or.inl ⟨rfl, h0⟩⟩⟩⟩
  · omega
  · exact Or.inr ⟨hI, Or.inr ⟨hL, Or.inr ⟨hroom, Or.inr ⟨hpos, rfl, hov⟩⟩⟩⟩

/-- `propose(v)` fails without changing the cluster, for the reason `PropErr` gives. -/
theorem errs_propose (c : Jarl.Cluster V S MAX CAP) (hp : Pre c.node) (v : V) (e : Error) (c' : Jarl.Cluster V S MAX CAP)
    (h : Cluster.propose c v = pure (.Err e, c')) : c' = c ∧ PropErr c.node 1 e := by
  unfold Cluster.propose at h
  dsimp only at h
  split at h
  · rename_i u ha
    have hI := idle_of_available c.node (by cases u; exact ha)
    split at h
    · rename_i hr
      obtain ⟨he, hc⟩ := errs_exit h
      cases he
      exact ⟨hc, Or.inr ⟨hI, Or.inl ⟨rfl, by simpa [Node.role_fn] using hr⟩⟩⟩
    rename_i hr
    have hL : c.node.role = .Leader := by simpa [Node.role_fn] using hr
    obtain ⟨t2, ht2, h⟩ := Rust.bind_eq_pure h
    have ht := errs_remaining c hp t2 ht2
    split at h
    · rename_i hf
      obtain ⟨he, hc⟩ := errs_exit h
      cases he
      have : t2.val ≤ 3 := by simp [Fin.le_def] at hf; uomega
      exact ⟨hc, Or.inr ⟨hI, Or.inr ⟨hL, Or.inl ⟨rfl, by omega⟩⟩⟩⟩
    rename_i hf
    have hroom : 1 ≤ CAP - (ret c.node.state).length - 3 := by
      have : ¬ t2.val ≤ 3 := by simp [Fin.le_def] at hf; uomega
      omega
    obtain ⟨⟨r1, m⟩, hm, h⟩ := Rust.bind_eq_pure h
    rcases errs_pm c.node hp 1 _ (by simp) r1 m hm with ⟨e1, he1, hn, hc⟩ | ⟨-, -, -, -, hr1, -⟩
    · subst he1 hn
      simp only at h
      obtain ⟨he, hc'⟩ := errs_exit h
      cases he
      exact ⟨hc', errs_pmErr_room _ 1 1 (by simp) e hI hL hroom hc⟩
    · subst hr1
      simp only [pure_bind] at h
      cases errs_fst h
  · rename_i e1 ha
    obtain ⟨he, hc⟩ := errs_exit h
    cases he
    exact ⟨hc, Or.inl (errs_avail_err _ _ ha)⟩

theorem errs_propose_busy (c : Jarl.Cluster V S MAX CAP) (v : V) (h : ¬ Idle c.node) :
    Cluster.propose c v = pure (.Err .Busy, c) := by
  unfold Cluster.propose
  simp only [Node.idle, errs_avail_busy _ h]

/-- A successful `propose(v)` reports the identity of the entry it appended,
    which holds `Command(v)`. -/
theorem errs_propose_ok [Rust.LawfulClone V] (c : Jarl.Cluster V S MAX CAP) (hp : Pre c.node) (v : V) (id : LogId)
    (c' : Jarl.Cluster V S MAX CAP) (h : Cluster.propose c v = pure (.Ok id, c')) :
    Idle c.node ∧ c.node.role = .Leader ∧ AppendedAt c.node c'.node id (Record.Command v) := by
  unfold Cluster.propose at h
  dsimp only at h
  split at h
  · split at h
    · cases errs_fst h
    obtain ⟨t2, -, h⟩ := Rust.bind_eq_pure h
    split at h
    · cases errs_fst h
    obtain ⟨⟨r1, m⟩, hm, h⟩ := Rust.bind_eq_pure h
    rcases errs_pm_one c.node hp _ (Record.Command v)
      (Rust.faithful_bind (Rust.faithful_clone v) (Rust.faithful_pure _)) r1 m hm with
      ⟨e1, he1, -, -⟩ | ⟨hI, hL, id', hr1, hA⟩
    · subst he1
      simp only at h
      cases errs_fst h
    · subst hr1
      simp only [pure_bind] at h
      have := Rust.pure_inj h
      simp only [Prod.mk.injEq, Rust.Result.Ok.injEq] at this
      obtain ⟨rfl, rfl⟩ := this
      exact ⟨hI, hL, hA⟩
  · cases errs_fst h

/-- `propose_batch(vs)` fails without changing the cluster, for the reason `PropErr` gives. -/
theorem errs_propose_batch (c : Jarl.Cluster V S MAX CAP) (hp : Pre c.node) (vs : Array V)
    (hvs : vs.size < 2 ^ Rust.usizeBits) (e : Error) (c' : Jarl.Cluster V S MAX CAP)
    (h : Cluster.propose_batch c vs = pure (.Err e, c')) : c' = c ∧ PropErr c.node vs.size e := by
  have hsz : (Rust.usizeOf vs.size).val = vs.size := Rust.val_usizeOf _ hvs
  unfold Cluster.propose_batch at h
  dsimp only at h
  split at h
  · rename_i u ha
    have hI := idle_of_available c.node (by cases u; exact ha)
    split at h
    · rename_i hr
      obtain ⟨he, hc⟩ := errs_exit h
      cases he
      exact ⟨hc, Or.inr ⟨hI, Or.inl ⟨rfl, by simpa [Cluster.role, Node.role_fn] using hr⟩⟩⟩
    rename_i hr
    have hL : c.node.role = .Leader := by simpa [Cluster.role, Node.role_fn] using hr
    obtain ⟨t2, ht2, h⟩ := Rust.bind_eq_pure h
    have ht := errs_remaining c hp t2 ht2
    split at h
    · rename_i hf
      obtain ⟨he, hc⟩ := errs_exit h
      cases he
      have : t2.val - 3 < vs.size := by
        simp [Fin.lt_def, Rust.saturating_sub, hsz] at hf; uomega
      refine ⟨hc, Or.inr ⟨hI, Or.inr ⟨hL, Or.inl ⟨rfl, by omega⟩⟩⟩⟩
    rename_i hf
    have hroom : vs.size ≤ CAP - (ret c.node.state).length - 3 := by
      have : ¬ t2.val - 3 < vs.size := by
        simp [Fin.lt_def, Rust.saturating_sub, hsz] at hf; uomega
      omega
    obtain ⟨⟨r1, m⟩, hm, h⟩ := Rust.bind_eq_pure h
    rcases errs_pm c.node hp _ _ (by simp [hsz]) r1 m hm with ⟨e1, he1, hn, hc⟩ | ⟨-, -, -, -, hr1, -⟩
    · subst he1 hn
      obtain ⟨he, hc'⟩ := errs_exit h
      cases he
      exact ⟨hc', errs_pmErr_room _ vs.size _ hsz e hI hL hroom hc⟩
    · subst hr1
      cases errs_fst h
  · rename_i e1 ha
    obtain ⟨he, hc⟩ := errs_exit h
    cases he
    exact ⟨hc, Or.inl (errs_avail_err _ _ ha)⟩

theorem errs_propose_batch_busy (c : Jarl.Cluster V S MAX CAP) (vs : Array V) (h : ¬ Idle c.node) :
    Cluster.propose_batch c vs = pure (.Err .Busy, c) := by
  unfold Cluster.propose_batch
  simp only [Node.idle, errs_avail_busy _ h]

theorem errs_entries_eq (n : DNode V S MAX CAP) (xs : List (Record V MAX)) (L : List (DEntry V MAX))
    (hlen : L.length = xs.length) (h : ∀ i (hi : i < L.length), L[i] = errsEntry n i (xs[i]'(by omega))) :
    L = proposedD n xs := by
  apply List.ext_getElem (by simp [proposedD, hlen])
  intro i h1 h2
  rw [h i h1]
  simp [proposedD, errsEntry]

/-- A successful `propose_batch(vs)` reports the range of the entries it
    appended, which hold the commands in order. -/
theorem errs_propose_batch_ok [Rust.LawfulClone V] (c : Jarl.Cluster V S MAX CAP) (hp : Pre c.node) (vs : Array V)
    (hvs : vs.size < 2 ^ Rust.usizeBits) (rg : ProposalRange) (c' : Jarl.Cluster V S MAX CAP)
    (h : Cluster.propose_batch c vs = pure (.Ok rg, c')) :
    Idle c.node ∧ c.node.role = .Leader ∧ 0 < vs.size ∧ (lastId c.node.state).index.val + vs.size < 2 ^ 64 ∧
      rg = { first := { index := Rust.ofNat ((lastId c.node.state).index.val + 1), term := c.node.state.hard.term },
             last := { index := Rust.ofNat ((lastId c.node.state).index.val + vs.size), term := c.node.state.hard.term } } ∧
      ret c'.node.state = ret c.node.state ++ proposedD c.node (vs.toList.map Record.Command) ∧
      c'.node.state.snapshot = c.node.state.snapshot := by
  have hsz : (Rust.usizeOf vs.size).val = vs.size := Rust.val_usizeOf _ hvs
  unfold Cluster.propose_batch at h
  dsimp only at h
  split at h
  · split at h
    · cases errs_fst h
    obtain ⟨t2, -, h⟩ := Rust.bind_eq_pure h
    split at h
    · cases errs_fst h
    obtain ⟨⟨r1, m⟩, hm, h⟩ := Rust.bind_eq_pure h
    rcases errs_pm c.node hp _ _ (by simp [hsz]) r1 m hm with
      ⟨e1, he1, -, -⟩ | ⟨hI, hL, hpos, hov, hr1, L, hLc, hLv, s', n1, n2, hret, -, hs, -, -, hR, hA, hn'⟩
    · subst he1
      cases errs_fst h
    have := Rust.pure_inj h
    simp only [Prod.mk.injEq] at this
    obtain ⟨hr, hc'⟩ := this
    subst hc'
    rw [hr1] at hr
    simp only [Rust.Result.Ok.injEq] at hr
    subst hr
    rw [hsz] at hpos hov
    refine ⟨hI, hL, hpos, hov, by simp only [hsz], ?_⟩
    have hL' : L = proposedD c.node (vs.toList.map Record.Command) := by
      refine errs_entries_eq _ _ L (by simp [hLc, hsz]) (fun i hi => ?_)
      obtain ⟨v, hv, he⟩ := hLv i hi
      have hi' : i < vs.size := by rw [hLc, hsz] at hi; exact hi
      simp only [List.getElem?_map, Array.getElem?_toList, Array.getElem?_eq_getElem hi', Option.map_some,
        Option.some.injEq] at hv
      have hf := Rust.faithful_bind (Rust.faithful_clone vs[i]) (Rust.faithful_pure (Record.Command vs[i])) v hv
      rw [he, hf]
      simp
    subst hL'
    obtain ⟨hd, hst⟩ := errs_adv_state _ _ hA
    have hst' : m.state = { s' with hard := hd } := by
      rw [hn']
      show n2.state = _
      rw [hst]
      show { n1.state with hard := hd } = _
      rw [errs_refresh_state _ _ hR]
    rw [hst']
    exact ⟨hret, hs⟩
  · cases errs_fst h

/-! ## `change_available` -/

theorem errs_ite {α : Type} {b : Bool} {x y z : Rust.M α} (h : (if b = true then x else y) = z) :
    (b = true ∧ x = z) ∨ (b = false ∧ y = z) := by
  cases b
  · exact Or.inr ⟨rfl, h⟩
  · exact Or.inl ⟨rfl, h⟩

/-- The term of the committed entry (or of the snapshot boundary at the commit index). -/
def errsCommittedTerm (n : DNode V S MAX CAP) : Option Rust.u64 :=
  (((ret n.state).find? (fun e => e.id.index == n.state.hard.commit)).map (fun e => e.id.term)).orElse
    (fun _ => (n.state.snapshot.filter (fun s => s.last.index == n.state.hard.commit)).map (fun s => s.last.term))

/-- What `change_available` checks of an idle leader: its latest configuration
    is stable and committed, and its commit index is an entry of its own term. -/
def errsStable (n : DNode V S MAX CAP) : Prop :=
  Membership.is_joint (memAt n.state n.bootstrap (lastId n.state).index).2 = false ∧
    (memAt n.state n.bootstrap (lastId n.state).index).1 ≤ n.state.hard.commit ∧
    errsCommittedTerm n = some n.state.hard.term

/-- Why `change_available` fails: busy, not the leader, or a configuration
    change still pending (`errsStable` fails). -/
def ChangeErr (n : DNode V S MAX CAP) (e : Error) : Prop :=
  (e = .Busy ∧ ¬ Idle n) ∨
  (Idle n ∧ ((e = .NotLeader n.leader ∧ n.role ≠ .Leader) ∨
    (n.role = .Leader ∧ e = .Reconfiguring ∧ ¬ errsStable n)))

theorem errs_change (c : Jarl.Cluster V S MAX CAP) (hp : Pre c.node) (r : Rust.Result Unit Error)
    (h : Cluster.change_available c = pure r) :
    (r = .Ok () ∧ Idle c.node ∧ c.node.role = .Leader ∧ errsStable c.node) ∨ (∃ e, r = .Err e ∧ ChangeErr c.node e) := by
  unfold Cluster.change_available at h
  dsimp only at h
  split at h
  · rename_i u ha
    have hI := idle_of_available c.node (by cases u; exact ha)
    split at h
    · rename_i hr
      exact Or.inr ⟨_, (Rust.pure_inj h).symm, Or.inr ⟨hI, Or.inl ⟨rfl, by simpa [Cluster.role, Node.role_fn] using hr⟩⟩⟩
    rename_i hr
    have hL : c.node.role = .Leader := by simpa [Cluster.role, Node.role_fn] using hr
    dsimp only [Cluster.state, Node.state_fn, State.hard_fn] at h
    rw [last_eq _ hp.layout.1, pure_bind, membership_at_eq _ hp.hooks hp.layout, pure_bind] at h
    rcases errs_ite h with ⟨h1, h⟩ | ⟨h1, h⟩
    · refine Or.inr ⟨_, (Rust.pure_inj h).symm, Or.inr ⟨hI, Or.inr ⟨hL, rfl, fun hs => ?_⟩⟩⟩
      simp only [hs.1, Bool.false_or] at h1
      exact absurd hs.2.1 (Fin.not_le.mpr (of_decide_eq_true h1))
    rw [entries_fn_eq _ hp.layout.1, pure_bind] at h
    have h' : (if (errsCommittedTerm c.node != some c.node.state.hard.term) = true then pure (Rust.Result.Err Error.Reconfiguring)
        else pure (Rust.Result.Ok ()) : Rust.M (Rust.Result Unit Error)) = pure r := h
    simp only [Bool.or_eq_false_iff, decide_eq_false_iff_not, gt_iff_lt, Fin.not_lt] at h1
    rcases errs_ite h' with ⟨h2, h'⟩ | ⟨h2, h'⟩
    · refine Or.inr ⟨_, (Rust.pure_inj h').symm, Or.inr ⟨hI, Or.inr ⟨hL, rfl, fun hs => ?_⟩⟩⟩
      simp [hs.2.2] at h2
    · exact Or.inl ⟨(Rust.pure_inj h').symm, hI, hL, h1.1, h1.2, by simpa using h2⟩
  · rename_i e1 ha
    exact Or.inr ⟨_, (Rust.pure_inj h).symm, Or.inl (errs_avail_err _ _ ha)⟩

/-! ## `Cluster::compact` -/

/-- Why `compact(index, _)` fails: busy, or `index` is not a committed index
    after the snapshot boundary with an identity in the log. -/
def CompactErr (n : DNode V S MAX CAP) (index : Rust.u64) (e : Error) : Prop :=
  (e = .Busy ∧ ¬ Idle n) ∨
  (Idle n ∧ e = .NotCommitted ∧
    (index.val ≤ n.state.base.index.val ∨ n.state.hard.commit.val < index.val ∨ idAt n.state index.val = none))

theorem errs_compact_with (n : DNode V S MAX CAP) (hp : Pre n) (index : Rust.u64)
    (value : Unit → Rust.M (Checkpoint S MAX)) (e : Error) (n' : DNode V S MAX CAP)
    (h : Node.compact_with n index value = pure (.Err e, n')) : n' = n ∧ CompactErr n index e := by
  unfold Node.compact_with at h
  cases ha : Node.available n with
  | Err e1 =>
    simp only [ha] at h
    obtain ⟨he, hn⟩ := errs_exit h
    cases he
    exact ⟨hn, Or.inl (errs_avail_err n _ ha)⟩
  | Ok u =>
    simp only [ha] at h
    have hI := idle_of_available n (by cases u; exact ha)
    by_cases hc : (decide (index ≤ n.state.base.index) || decide (index > n.state.hard.commit)) = true
    · rw [if_pos hc] at h
      obtain ⟨he, hn⟩ := errs_exit h
      cases he
      refine ⟨hn, Or.inr ⟨hI, rfl, ?_⟩⟩
      simp only [Bool.or_eq_true, decide_eq_true_eq, gt_iff_lt] at hc
      rcases hc with hc | hc
      · exact Or.inl (Fin.le_def.mp hc)
      · exact Or.inr (Or.inl (Fin.lt_def.mp hc))
    rw [if_neg hc] at h
    simp only [Bool.or_eq_true, decide_eq_true_eq, not_or, Fin.not_le, gt_iff_lt, Fin.not_lt] at hc
    rw [id_at_eq _ hp.layout] at h
    cases hid : idAt n.state index.val with
    | none =>
      simp only [hid, Rust.Option.ok_or] at h
      obtain ⟨he, hn⟩ := errs_exit h
      cases he
      exact ⟨hn, Or.inr ⟨hI, rfl, Or.inr (Or.inr hid)⟩⟩
    | some last =>
      simp only [hid, Rust.Option.ok_or, pure_bind] at h
      obtain ⟨v, -, h⟩ := Rust.bind_eq_pure h
      obtain ⟨s', -, h⟩ := Rust.bind_eq_pure h
      split at h
      · obtain ⟨n2, -, h⟩ := Rust.bind_eq_pure h
        obtain ⟨n3, -, h⟩ := Rust.bind_eq_pure h
        cases errs_fst h
      · cases errs_fst h

/-- `compact(index, application)` fails without changing the cluster, for the reason `CompactErr` gives. -/
theorem errs_compact (c : Jarl.Cluster V S MAX CAP) (hp : Pre c.node) (index : Rust.u64) (app : S) (e : Error)
    (c' : Jarl.Cluster V S MAX CAP) (h : Cluster.compact c index app = pure (.Err e, c')) :
    c' = c ∧ CompactErr c.node index e := by
  unfold Cluster.compact at h
  dsimp only at h
  rw [membership_at_eq _ hp.hooks hp.layout, pure_bind] at h
  obtain ⟨⟨r1, m⟩, hm, h⟩ := Rust.bind_eq_pure h
  have := Rust.pure_inj h
  simp only [Prod.mk.injEq] at this
  obtain ⟨hr, hc'⟩ := this
  subst hr hc'
  obtain ⟨hm', hc⟩ := errs_compact_with c.node hp index _ e m hm
  subst hm'
  exact ⟨rfl, hc⟩

theorem errs_compact_busy (c : Jarl.Cluster V S MAX CAP) (hp : Pre c.node) (index : Rust.u64) (app : S)
    (h : ¬ Idle c.node) : Cluster.compact c index app = pure (.Err .Busy, c) := by
  unfold Cluster.compact Node.compact_with
  simp only [membership_at_eq _ hp.hooks hp.layout, pure_bind, errs_avail_busy _ h]

/-! ## `Cluster::finish_reconfiguration` -/

/-- The failures `propose_many(1, _)` can still have at an idle leader: no
    free slot, or no next index. -/
theorem errs_pm1 (n : DNode V S MAX CAP) (e : Error) (hI : Idle n) (hL : n.role = .Leader) (h : PMErr n 1 e) :
    (e = .Full ∧ CAP ≤ (ret n.state).length) ∨
    (e = .Exhausted ∧ (ret n.state).length < CAP ∧ 2 ^ 64 ≤ (lastId n.state).index.val + 1) := by
  have h1 : (1 : Rust.usize).val = 1 := by simp
  rcases h with ⟨-, hn⟩ | ⟨-, ⟨-, hn⟩ | ⟨-, ⟨-, h0⟩ | ⟨-, ⟨rfl, hf⟩ | ⟨rfl, hr, hov⟩⟩⟩⟩
  · exact absurd hI hn
  · exact absurd hL hn
  · rw [h1] at h0; omega
  · rw [h1] at hf; exact Or.inl ⟨rfl, by omega⟩
  · rw [h1] at hr hov; exact Or.inr ⟨rfl, by omega, hov⟩

/-- Why `finish_reconfiguration()` fails. `memAt … (lastId …)` is the latest
    configuration and its position: it must be joint and committed; then the
    finalized configuration needs a free slot and a next index. -/
def FinishErr (n : DNode V S MAX CAP) (e : Error) : Prop :=
  (e = .Busy ∧ ¬ Idle n) ∨
  (Idle n ∧ ((e = .NotLeader n.leader ∧ n.role ≠ .Leader) ∨
    (n.role = .Leader ∧
      ((e = .Reconfiguring ∧ (Membership.is_joint (memAt n.state n.bootstrap (lastId n.state).index).2 = false ∨
          n.state.hard.commit < (memAt n.state n.bootstrap (lastId n.state).index).1)) ∨
       (Membership.is_joint (memAt n.state n.bootstrap (lastId n.state).index).2 = true ∧
          (memAt n.state n.bootstrap (lastId n.state).index).1 ≤ n.state.hard.commit ∧
          ((e = .Full ∧ CAP ≤ (ret n.state).length) ∨
           (e = .Exhausted ∧ (ret n.state).length < CAP ∧ 2 ^ 64 ≤ (lastId n.state).index.val + 1)))))))

/-- Every outcome of `finish_reconfiguration()`: an error leaves the cluster
    unchanged, for the reason `FinishErr` gives; success appends the finalized
    latest configuration at the reported identity. -/
theorem errs_finish (c : Jarl.Cluster V S MAX CAP) (hp : Pre c.node) (r : Rust.Result LogId Error)
    (c' : Jarl.Cluster V S MAX CAP) (h : Cluster.finish_reconfiguration c = pure (r, c')) :
    (∃ e, r = .Err e ∧ c' = c ∧ FinishErr c.node e) ∨
    (∃ id, r = .Ok id ∧ Idle c.node ∧ c.node.role = .Leader ∧
      Membership.is_joint (memAt c.node.state c.node.bootstrap (lastId c.node.state).index).2 = true ∧
      (memAt c.node.state c.node.bootstrap (lastId c.node.state).index).1 ≤ c.node.state.hard.commit ∧
      AppendedAt c.node c'.node id
        (Record.Configuration (Membership.finalized (memAt c.node.state c.node.bootstrap (lastId c.node.state).index).2))) := by
  unfold Cluster.finish_reconfiguration at h
  dsimp only at h
  split at h
  · rename_i u hid
    have hI := idle_of_available c.node (by cases u; exact hid)
    split at h
    · rename_i hr
      obtain ⟨rfl, hc⟩ := errs_exit h
      exact Or.inl ⟨_, rfl, hc, Or.inr ⟨hI, Or.inl ⟨rfl, by simpa [Cluster.role, Node.role_fn] using hr⟩⟩⟩
    rename_i hrole
    have hL : c.node.role = .Leader := by simpa [Cluster.role, Node.role_fn] using hrole
    dsimp only [Cluster.state, Node.state_fn, State.hard_fn] at h
    rw [last_eq _ hp.layout.1, pure_bind, membership_at_eq _ hp.hooks hp.layout, pure_bind] at h
    split at h
    · rename_i hj
      have hj' : Membership.is_joint (memAt c.node.state c.node.bootstrap (lastId c.node.state).index).2 = true := by
        simpa using hj
      simp only [pure_bind] at h
      split at h
      · rename_i hc
        obtain ⟨rfl, hc'⟩ := errs_exit h
        have : c.node.state.hard.commit < (memAt c.node.state c.node.bootstrap (lastId c.node.state).index).1 := by
          simpa using hc
        exact Or.inl ⟨_, rfl, hc', Or.inr ⟨hI, Or.inr ⟨hL, Or.inl ⟨rfl, Or.inr this⟩⟩⟩⟩
      rename_i hc
      have hc2 : (memAt c.node.state c.node.bootstrap (lastId c.node.state).index).1 ≤ c.node.state.hard.commit := by
        simpa using hc
      obtain ⟨⟨r1, m⟩, hpr, h⟩ := Rust.bind_eq_pure h
      have := Rust.pure_inj h
      simp only [Prod.mk.injEq] at this
      obtain ⟨hr, hc'⟩ := this
      subst hr hc'
      rcases errs_node_propose c.node hp _ (Rust.faithful_pure _) r1 m hpr with ⟨e, rfl, hm, hpe⟩ | ⟨-, -, id, rfl, hA⟩
      · subst hm
        exact Or.inl ⟨e, rfl, rfl, Or.inr ⟨hI, Or.inr ⟨hL, Or.inr ⟨hj', hc2, errs_pm1 _ e hI hL hpe⟩⟩⟩⟩
      · exact Or.inr ⟨id, rfl, hI, hL, hj', hc2, hA⟩
    · rename_i hj
      have hj' : Membership.is_joint (memAt c.node.state c.node.bootstrap (lastId c.node.state).index).2 = false := by
        simpa using hj
      simp only [pure_bind, if_true] at h
      obtain ⟨rfl, hc'⟩ := errs_exit h
      exact Or.inl ⟨_, rfl, hc', Or.inr ⟨hI, Or.inr ⟨hL, Or.inl ⟨rfl, Or.inl hj'⟩⟩⟩⟩
  · rename_i e1 ha
    obtain ⟨rfl, hc⟩ := errs_exit h
    exact Or.inl ⟨_, rfl, hc, Or.inl (errs_avail_err _ _ ha)⟩

theorem errs_finish_busy (c : Jarl.Cluster V S MAX CAP) (h : ¬ Idle c.node) :
    Cluster.finish_reconfiguration c = pure (.Err .Busy, c) := by
  unfold Cluster.finish_reconfiguration
  simp only [Node.idle, errs_avail_busy _ h]

/-! ## `Cluster::set_learners` -/

theorem errs_voters_le (m : Membership MAX) : m.voters.length ≤ MAX := by
  unfold Membership.voters Rust.Iter.flatten
  simp only [List.length_map]
  calc _ ≤ (m.members.toList.filterMap id).length := List.length_filter_le _ _
    _ ≤ m.members.toList.length := List.length_filterMap_le _ _
    _ = MAX := by simp

theorem errs_add_val {n : Nat} (a b t : Fin (2 ^ n)) (h : Rust.add a b = pure t) : t.val = a.val + b.val := by
  unfold Rust.add at h
  split at h
  · rw [← Rust.pure_inj h]
  · exact absurd h (fail_ne_pure' _ _)

/-- Why `set_learners(learners)` fails: `change_available` fails, or (at an
    idle leader with a stable committed configuration) the voters and learners
    exceed the slots, `with_learners` rejects the list, the log lacks room for
    the change and two more entries, or there is no next index. -/
def SetLearnersErr (n : DNode V S MAX CAP) (learners : Array Id) (e : Error) : Prop :=
  ChangeErr n e ∨
  (Idle n ∧ n.role = .Leader ∧ errsStable n ∧
    ((e = .Full ∧ MAX < n.membership.voters.length + learners.size) ∨
     (n.membership.voters.length + learners.size ≤ MAX ∧
       ((e = .Config ∧ n.membership.with_learners learners = pure (.Err .Config)) ∨
        (∃ X, n.membership.with_learners learners = pure (.Ok X) ∧
          ((e = .Full ∧ CAP - (ret n.state).length ≤ 2) ∨
           (2 < CAP - (ret n.state).length ∧ e = .Exhausted ∧ 2 ^ 64 ≤ (lastId n.state).index.val + 1)))))))

/-- Every outcome of `set_learners(learners)`: an error leaves the cluster
    unchanged, for the reason `SetLearnersErr` gives; success appends the new
    configuration at the reported identity. -/
theorem errs_set_learners (c : Jarl.Cluster V S MAX CAP) (hp : Pre c.node) (learners : Array Id)
    (hl : learners.size < 2 ^ Rust.usizeBits) (r : Rust.Result LogId Error) (c' : Jarl.Cluster V S MAX CAP)
    (h : Cluster.set_learners c learners = pure (r, c')) :
    (∃ e, r = .Err e ∧ c' = c ∧ SetLearnersErr c.node learners e) ∨
    (∃ id X, r = .Ok id ∧ c.node.membership.with_learners learners = pure (.Ok X) ∧
      AppendedAt c.node c'.node id (Record.Configuration X)) := by
  unfold Cluster.set_learners at h
  dsimp only at h
  obtain ⟨t1, hca, h⟩ := Rust.bind_eq_pure h
  rcases errs_change c hp t1 hca with ⟨rfl, hI, hL, hS⟩ | ⟨e, rfl, he⟩
  rotate_left
  · obtain ⟨rfl, hc⟩ := errs_exit h
    exact Or.inl ⟨e, rfl, hc, Or.inl he⟩
  simp only [pure_bind, Cluster.membership] at h
  obtain ⟨t3, ht3, h⟩ := Rust.bind_eq_pure h
  have hv := errs_voters_le c.node.membership
  have hM : MAX < 2 ^ Rust.usizeBits := hp.n_lt
  have ht3v : t3.val = c.node.membership.voters.length + learners.size := by
    rw [errs_add_val _ _ _ ht3]
    simp only [Rust.Iter.count, Rust.ofNat, Rust.val_usizeOf _ hl]
    rw [Nat.mod_eq_of_lt (by uomega)]
  split at h
  · rename_i hf
    obtain ⟨rfl, hc⟩ := errs_exit h
    have : MAX < t3.val := by simpa [Fin.lt_def, Rust.val_usizeOf _ hM] using hf
    exact Or.inl ⟨_, rfl, hc, Or.inr ⟨hI, hL, hS, Or.inl ⟨rfl, by omega⟩⟩⟩
  rename_i hf
  have hfit : c.node.membership.voters.length + learners.size ≤ MAX := by
    have : ¬ MAX < t3.val := by simpa [Fin.lt_def, Rust.val_usizeOf _ hM] using hf
    omega
  obtain ⟨t4, hw, h⟩ := Rust.bind_eq_pure h
  rcases t4 with X | e
  rotate_left
  · obtain ⟨rfl, hc⟩ := errs_exit h
    obtain rfl := Jarl.Contracts.Membership.LearnerReplacement.error_code _ learners hp.n_lt hl e hw
    exact Or.inl ⟨_, rfl, hc, Or.inr ⟨hI, hL, hS, Or.inr ⟨hfit, Or.inl ⟨rfl, hw⟩⟩⟩⟩
  simp only at h
  obtain ⟨t6, ht6, h⟩ := Rust.bind_eq_pure h
  have ht := errs_remaining c hp t6 ht6
  split at h
  · rename_i hf2
    obtain ⟨rfl, hc⟩ := errs_exit h
    have : t6.val ≤ 2 := by simp [Fin.le_def] at hf2; uomega
    exact Or.inl ⟨_, rfl, hc, Or.inr ⟨hI, hL, hS, Or.inr ⟨hfit, Or.inr ⟨X, hw, Or.inl ⟨rfl, by omega⟩⟩⟩⟩⟩
  rename_i hf2
  have hroom : 2 < CAP - (ret c.node.state).length := by
    have : ¬ t6.val ≤ 2 := by simp [Fin.le_def] at hf2; uomega
    omega
  obtain ⟨⟨r1, m⟩, hpr, h⟩ := Rust.bind_eq_pure h
  have := Rust.pure_inj h
  simp only [Prod.mk.injEq] at this
  obtain ⟨hr, hc'⟩ := this
  subst hr hc'
  rcases errs_node_propose c.node hp _ (Rust.faithful_pure _) r1 m hpr with ⟨e, rfl, hm, hpe⟩ | ⟨-, -, id, rfl, hA⟩
  · subst hm
    refine Or.inl ⟨e, rfl, rfl, Or.inr ⟨hI, hL, hS, Or.inr ⟨hfit, Or.inr ⟨X, hw, ?_⟩⟩⟩⟩
    rcases errs_pm1 _ e hI hL hpe with ⟨rfl, hf⟩ | ⟨rfl, -, hov⟩
    · omega
    · exact Or.inr ⟨hroom, rfl, hov⟩
  · exact Or.inr ⟨id, X, rfl, hw, hA⟩

theorem errs_set_learners_busy (c : Jarl.Cluster V S MAX CAP) (learners : Array Id) (h : ¬ Idle c.node) :
    Cluster.set_learners c learners = pure (.Err .Busy, c) := by
  unfold Cluster.set_learners Cluster.change_available
  simp only [Node.idle, errs_avail_busy _ h, pure_bind]

/-! ## `Cluster::reconfigure` -/

/-- A search loop whose body ignores its state: it stops at the first element
    satisfying `Q`, returning a value satisfying `P`, or runs to the end. -/
theorem errs_forIn_find {γ π : Type} (l : List γ) (g : γ → Rust.M (ForInStep (Option π × Unit)))
    (init : Option π × Unit) (r : Option π × Unit) (h : forIn l init (fun x _ => g x) = pure r)
    (Q : γ → Prop) (P : π → Prop)
    (hg : ∀ x ∈ l, ∀ s, g x = pure s → (s = .yield (none, ()) ∧ ¬ Q x) ∨ (∃ p, s = .done (some p, ()) ∧ P p ∧ Q x))
    (hinit : init = (none, ())) :
    (r.1 = none ∧ ∀ x ∈ l, ¬ Q x) ∨ (∃ p, r.1 = some p ∧ P p ∧ ∃ x ∈ l, Q x) := by
  induction l generalizing init with
  | nil =>
    rw [List.forIn_nil] at h
    rw [← Rust.pure_inj h, hinit]
    exact Or.inl ⟨rfl, fun x hx => by cases hx⟩
  | cons x xs ih =>
    rw [List.forIn_cons] at h
    obtain ⟨s, hs, h⟩ := Rust.bind_eq_pure h
    rcases hg x (by simp) s hs with ⟨rfl, hq⟩ | ⟨p, rfl, hp, hq⟩
    · simp only at h
      rcases ih (none, ()) h (fun y hy => hg y (by simp [hy])) rfl with ⟨hn, hall⟩ | ⟨p, hp1, hp2, y, hy, hqy⟩
      · refine Or.inl ⟨hn, fun y hy => ?_⟩
        rcases List.mem_cons.mp hy with rfl | hy
        · exact hq
        · exact hall y hy
      · exact Or.inr ⟨p, hp1, hp2, y, by simp [hy], hqy⟩
    · simp only at h
      rw [← Rust.pure_inj h]
      exact Or.inr ⟨p, rfl, hp, x, by simp, hq⟩

/-- A voter of the target that is not a voter now has not caught up: it is
    not a learner, or its match index is behind the leader's last index. -/
def errsBehindAt (n : DNode V S MAX CAP) (id : Id) : Prop :=
  (n.membership.learners.any fun l => l == id) = false ∨ (matchOf n id).val < (lastId n.state).index.val

def errsBehind (n : DNode V S MAX CAP) (target : Membership MAX) : Prop :=
  ∃ id ∈ target.voters, Membership.is_voter n.membership id = false ∧ errsBehindAt n id

/-- Why `reconfigure(target)` fails: `change_available` fails, or (at an idle
    leader with a stable committed configuration) the target is joint, a new
    voter has not caught up, the log lacks room for the change and two more
    entries, `joint` rejects the pair, or there is no next index. -/
def ReconfigureErr (n : DNode V S MAX CAP) (target : Membership MAX) (e : Error) : Prop :=
  ChangeErr n e ∨
  (Idle n ∧ n.role = .Leader ∧ errsStable n ∧
    ((e = .Config ∧ target.is_joint = true) ∨
     (target.is_joint = false ∧
      ((e = .NotCaughtUp ∧ errsBehind n target) ∨
       (¬ errsBehind n target ∧
        ((e = .Full ∧ CAP - (ret n.state).length < 3) ∨
         (3 ≤ CAP - (ret n.state).length ∧
          (((e = .Reconfiguring ∨ e = .Full) ∧ n.membership.joint target = pure (.Err e)) ∨
           (∃ X, n.membership.joint target = pure (.Ok X) ∧ e = .Exhausted ∧
             2 ^ 64 ≤ (lastId n.state).index.val + 1)))))))))

theorem errs_reconfigure (c : Jarl.Cluster V S MAX CAP) (hp : Pre c.node) (target : Membership MAX)
    (r : Rust.Result LogId Error) (c' : Jarl.Cluster V S MAX CAP)
    (h : Cluster.reconfigure c target = pure (r, c')) :
    (∃ e, r = .Err e ∧ c' = c ∧ ReconfigureErr c.node target e) ∨
    (∃ id X, r = .Ok id ∧ c.node.membership.joint target = pure (.Ok X) ∧
      AppendedAt c.node c'.node id (Record.Configuration X)) := by
  unfold Cluster.reconfigure at h
  dsimp only at h
  obtain ⟨t1, hca, h⟩ := Rust.bind_eq_pure h
  rcases errs_change c hp t1 hca with ⟨rfl, hI, hL, hS⟩ | ⟨e, rfl, he⟩
  rotate_left
  · obtain ⟨rfl, hc⟩ := errs_exit h
    exact Or.inl ⟨e, rfl, hc, Or.inl he⟩
  simp only [pure_bind, Cluster.membership] at h
  split at h
  · rename_i hj
    obtain ⟨rfl, hc⟩ := errs_exit h
    exact Or.inl ⟨_, rfl, hc, Or.inr ⟨hI, hL, hS, Or.inl ⟨rfl, hj⟩⟩⟩
  rename_i hj
  have hj' : target.is_joint = false := by simpa using hj
  obtain ⟨st, hst, h⟩ := Rust.bind_eq_pure h
  have hinv := errs_forIn_find _ _ _ st hst (errsBehindAt c.node) (fun p => p = (.Err .NotCaughtUp, c))
    (fun x hx sx hy => by
      rw [List.mem_filter] at hx
      split at hy
      · rename_i hA
        obtain ⟨t3, ht3, hy⟩ := Rust.bind_eq_pure hy
        obtain ⟨t4, ht4, hy⟩ := Rust.bind_eq_pure hy
        unfold Cluster.matched at ht3
        rw [matched_fn_eq' _ hp.n_lt] at ht3
        cases Rust.pure_inj ht3
        rw [show Cluster.state c = c.node.state from rfl, last_eq _ hp.layout.1] at ht4
        cases Rust.pure_inj ht4
        split at hy
        · rename_i hlt
          cases Rust.pure_inj hy
          exact Or.inr ⟨_, rfl, rfl, Or.inr (by simpa [Fin.lt_def] using hlt)⟩
        · rename_i hlt
          cases Rust.pure_inj hy
          refine Or.inl ⟨rfl, fun hB => ?_⟩
          rcases hB with hB | hB
          · simp [hB] at hA
          · simp [Fin.lt_def] at hlt; omega
      · rename_i hA
        split at hy
        · cases Rust.pure_inj hy
          exact Or.inr ⟨_, rfl, rfl, Or.inl (by simpa only [Bool.not_not, Bool.not_eq_true] using hA)⟩
        · rename_i hne; exact absurd trivial hne)
    rfl
  split at h
  · rename_i q hq
    rcases hinv with ⟨hn, -⟩ | ⟨q', hq', rfl, x, hx, hB⟩
    · rw [hn] at hq; cases hq
    rw [hq] at hq'
    cases hq'
    obtain ⟨rfl, hc⟩ := errs_exit h
    rw [List.mem_filter] at hx
    exact Or.inl ⟨_, rfl, hc, Or.inr ⟨hI, hL, hS, Or.inr ⟨hj', Or.inl ⟨rfl, x, hx.1, by simpa using hx.2, hB⟩⟩⟩⟩
  rename_i hnone
  have hNB : ¬ errsBehind c.node target := by
    rintro ⟨id, hid, hnv, hB⟩
    rcases hinv with ⟨-, hall⟩ | ⟨q', hq', -⟩
    · exact hall id (by rw [List.mem_filter]; exact ⟨hid, by simp [hnv]⟩) hB
    · rw [hnone] at hq'; cases hq'
  obtain ⟨t6, ht6, h⟩ := Rust.bind_eq_pure h
  have ht := errs_remaining c hp t6 ht6
  split at h
  · rename_i hf
    obtain ⟨rfl, hc⟩ := errs_exit h
    have : t6.val < 3 := by simp [Fin.lt_def] at hf; uomega
    exact Or.inl ⟨_, rfl, hc, Or.inr ⟨hI, hL, hS, Or.inr ⟨hj', Or.inr ⟨hNB, Or.inl ⟨rfl, by omega⟩⟩⟩⟩⟩
  rename_i hf
  have hroom : 3 ≤ CAP - (ret c.node.state).length := by
    have : ¬ t6.val < 3 := by simp [Fin.lt_def] at hf; uomega
    omega
  obtain ⟨t7, hjt, h⟩ := Rust.bind_eq_pure h
  rcases t7 with X | e
  rotate_left
  · obtain ⟨rfl, hc⟩ := errs_exit h
    exact Or.inl ⟨e, rfl, hc, Or.inr ⟨hI, hL, hS, Or.inr ⟨hj', Or.inr ⟨hNB, Or.inr ⟨hroom, Or.inl
      ⟨Jarl.Contracts.Membership.JointConstruction.error_codes _ target hp.n_lt e hjt, hjt⟩⟩⟩⟩⟩⟩
  simp only at h
  obtain ⟨⟨r1, m⟩, hpr, h⟩ := Rust.bind_eq_pure h
  have := Rust.pure_inj h
  simp only [Prod.mk.injEq] at this
  obtain ⟨hr, hc'⟩ := this
  subst hr hc'
  rcases errs_node_propose c.node hp _ (Rust.faithful_pure _) r1 m hpr with ⟨e, rfl, hm, hpe⟩ | ⟨-, -, id, rfl, hA⟩
  · subst hm
    refine Or.inl ⟨e, rfl, rfl, Or.inr ⟨hI, hL, hS, Or.inr ⟨hj', Or.inr ⟨hNB, Or.inr ⟨hroom, Or.inr ⟨X, hjt, ?_⟩⟩⟩⟩⟩⟩
    rcases errs_pm1 _ e hI hL hpe with ⟨rfl, hf⟩ | ⟨rfl, -, hov⟩
    · omega
    · exact ⟨rfl, hov⟩
  · exact Or.inr ⟨id, X, rfl, hjt, hA⟩

theorem errs_reconfigure_busy (c : Jarl.Cluster V S MAX CAP) (target : Membership MAX) (h : ¬ Idle c.node) :
    Cluster.reconfigure c target = pure (.Err .Busy, c) := by
  unfold Cluster.reconfigure Cluster.change_available
  simp only [Node.idle, errs_avail_busy _ h, pure_bind]

/-! ## `Cluster::tick` -/

/-- What a failed `tick()` did: nothing when busy; when the term cannot be
    incremented for an election, only the elapsed time and the leader age moved. -/
def TickErr (n n' : DNode V S MAX CAP) (e : Error) : Prop :=
  (e = .Busy ∧ ¬ Idle n ∧ n' = n) ∨
  (e = .Exhausted ∧ Idle n ∧ n.role ≠ .Leader ∧ Membership.is_voter n.membership n.config.id = true ∧
    n.election_deadline ≤ Rust.saturating_add n.elapsed 1 ∧ n.state.hard.term.val + 1 = 2 ^ 64 ∧
    n' = { n with elapsed := Rust.saturating_add n.elapsed 1, leader_age := Rust.saturating_add n.leader_age 1 })

theorem errs_node_tick (n : DNode V S MAX CAP) (e : Error) (n' : DNode V S MAX CAP)
    (h : Node.tick n = pure (.Err e, n')) : TickErr n n' e := by
  unfold Node.tick at h
  cases hav : Node.available n with
  | Err e1 =>
    simp only [hav] at h
    obtain ⟨he, hn⟩ := errs_exit h
    cases he
    obtain ⟨he2, hb⟩ := errs_avail_err n _ hav
    exact Or.inl ⟨he2, hb, hn⟩
  | Ok u =>
    have hI := idle_of_available n (by cases u; exact hav)
    simp only [hav, pure_bind] at h
    by_cases hl : n.role = Role.Leader
    · have hl1 : (n.role == Role.Leader) = true := by simp [hl]
      simp only [hl1, Bool.and_true, if_true] at h
      repeat' (first | (obtain ⟨_, -, h⟩ := Rust.bind_eq_pure h) | split at h | (dsimp only at h))
      all_goals cases errs_fst h
    · have hl' : (n.role == Role.Leader) = false := by
        cases hr : n.role <;> simp_all
      simp only [hl', Bool.and_false, Bool.false_eq_true, if_false] at h
      by_cases hv : (n.membership.is_voter n.config.id && decide (Rust.saturating_add n.elapsed 1 ≥ n.election_deadline)) = true
      · rw [if_pos hv] at h
        simp only [Bool.and_eq_true, decide_eq_true_eq] at hv
        by_cases ht : n.state.hard.term.val + (1 : Rust.u64).val < 2 ^ 64
        · simp only [Rust.checked_add_eq, dif_pos ht, Rust.Option.ok_or] at h
          repeat' (first | (obtain ⟨_, -, h⟩ := Rust.bind_eq_pure h) | split at h | (dsimp only at h))
          all_goals cases errs_fst h
        · simp only [Rust.checked_add_eq, dif_neg ht, Rust.Option.ok_or] at h
          obtain ⟨he, hn⟩ := errs_exit h
          cases he
          have := n.state.hard.term.isLt
          simp only [Fin.val_one] at ht
          exact Or.inr ⟨rfl, hI, hl, hv.1, hv.2, by omega, hn⟩
      · rw [if_neg hv] at h
        cases errs_fst h

/-- `tick()` fails only as `TickErr` describes; the cluster is unchanged when busy. -/
theorem errs_tick (c : Jarl.Cluster V S MAX CAP) (e : Error) (c' : Jarl.Cluster V S MAX CAP)
    (h : Cluster.tick c = pure (.Err e, c')) : TickErr c.node c'.node e := by
  unfold Cluster.tick at h
  obtain ⟨⟨r1, m⟩, hm, h⟩ := Rust.bind_eq_pure h
  have := Rust.pure_inj h
  simp only [Prod.mk.injEq] at this
  obtain ⟨hr, hc'⟩ := this
  subst hr hc'
  exact errs_node_tick c.node e m hm

theorem errs_tick_busy_eq (c : Jarl.Cluster V S MAX CAP) (c' : Jarl.Cluster V S MAX CAP)
    (h : Cluster.tick c = pure (.Err .Busy, c')) : c' = c ∧ ¬ Idle c.node := by
  rcases errs_tick c _ c' h with ⟨-, hI, hn⟩ | ⟨he, -⟩
  · exact ⟨by cases c; cases c'; simp only at hn; rw [hn], hI⟩
  · cases he

theorem errs_tick_busy (c : Jarl.Cluster V S MAX CAP) (h : ¬ Idle c.node) :
    Cluster.tick c = pure (.Err .Busy, c) := by
  unfold Cluster.tick Node.tick
  simp only [errs_avail_busy _ h, pure_bind]

/-! ## `Cluster::step` -/

/-- The messages a node accepts from an identity without a slot (when it has hooks). -/
def errsRequest : DMsg V S MAX → Bool
  | .Vote _ _ | .PreVote _ _ | .Append _ _ _ _ | .AppendBatch _ _ _ _ | .Install _ _ => true
  | _ => false

/-- Why `step` rejects an envelope as `Message`: an unknown sender of a message
    that needs a slot, a message from itself or to another identity, or an
    invalid message. -/
def StepRejected (n : DNode V S MAX CAP) (env : DEnv V S MAX) : Prop :=
  ((∀ i : Fin MAX, n.peers[i] ≠ some env.from) ∧ (n.hooks.isSome && errsRequest env.message) = false) ∨
  env.from = n.config.id ∨ env.to ≠ n.config.id ∨
  Node.valid (V := Record V MAX) (S := Checkpoint S MAX) (N := MAX) (CAP := CAP) env.message = pure false

theorem errs_node_step (n : DNode V S MAX CAP) (env : DEnv V S MAX) (e : Error) (n' : DNode V S MAX CAP)
    (h : Node.step n env = pure (.Err e, n')) :
    n' = n ∧ ((e = .Busy ∧ ¬ Idle n) ∨ (e = .Message ∧ Idle n ∧ StepRejected n env)) := by
  rcases env with ⟨src, dst, msg⟩
  unfold Node.step at h
  cases hA : Node.available n with
  | Err e1 =>
    simp only [hA] at h
    obtain ⟨he, hn⟩ := errs_exit h
    cases he
    exact ⟨hn, Or.inl (errs_avail_err n _ hA)⟩
  | Ok u =>
    have hI := idle_of_available n (by cases u; exact hA)
    simp only [hA] at h
    split at h
    · rename_i peer hpeer
      rw [pure_bind] at h
      rcases errs_ite h with ⟨hc, h⟩ | ⟨hc, h⟩
      · obtain ⟨t3, hv, h⟩ := Rust.bind_eq_pure h
        rw [pure_bind] at h
        rcases errs_ite h with ⟨ht, h⟩ | ⟨ht, h⟩
        · obtain ⟨he, hn⟩ := errs_exit h
          cases he
          obtain rfl : t3 = false := by cases t3 <;> first | rfl | exact absurd ht (by decide)
          exact ⟨hn, Or.inr ⟨rfl, hI, Or.inr (Or.inr (Or.inr hv))⟩⟩
        · cases msg <;> dsimp only at h
          all_goals repeat' (first | (obtain ⟨_, -, h⟩ := Rust.bind_eq_pure h) | split at h | (dsimp only at h))
          all_goals first | cases errs_fst h | exact absurd h (fail_ne_pure' _ _)
      · rw [pure_bind] at h
        obtain ⟨he, hn⟩ := errs_exit h
        cases he
        refine ⟨hn, Or.inr ⟨rfl, hI, Or.inr ?_⟩⟩
        have hc' : (src == n.config.id || dst != n.config.id) = true := by
          revert hc; cases (src == n.config.id || dst != n.config.id) <;> decide
        simp only [Bool.or_eq_true, beq_iff_eq, bne_iff_ne, ne_eq] at hc'
        rcases hc' with hc | hc
        · exact Or.inl hc
        · exact Or.inr (Or.inl hc)
    · rename_i e1 hpeer
      obtain ⟨he, hn⟩ := errs_exit h
      cases he
      refine ⟨hn, Or.inr ⟨?_, hI, Or.inl ?_⟩⟩
      · simp only [Rust.Option.ok_or] at hpeer
        split at hpeer <;> cases hpeer <;> rfl
      · cases hpos : Rust.Iter.position n.peers.toList (fun id => id == some src) with
        | some q =>
          simp [hpos, Rust.Option.ok_or] at hpeer
        | none =>
          refine ⟨pos_none n src hpos, ?_⟩
          simp only [hpos, Option.orElse, Rust.Option.ok_or, Rust.Option.then_some] at hpeer
          cases msg <;> cases hh : n.hooks.isSome <;> simp_all [errsRequest]

theorem errs_step (c : Jarl.Cluster V S MAX CAP) (env : DEnv V S MAX) (e : Error) (c' : Jarl.Cluster V S MAX CAP)
    (h : Cluster.step c env = pure (.Err e, c')) :
    c' = c ∧ ((e = .Busy ∧ ¬ Idle c.node) ∨ (e = .Message ∧ Idle c.node ∧ StepRejected c.node env)) := by
  unfold Cluster.step at h
  obtain ⟨⟨r1, m⟩, hm, h⟩ := Rust.bind_eq_pure h
  have := Rust.pure_inj h
  simp only [Prod.mk.injEq] at this
  obtain ⟨hr, hc'⟩ := this
  subst hr hc'
  obtain ⟨rfl, hc⟩ := errs_node_step c.node env e m hm
  exact ⟨rfl, hc⟩

theorem errs_step_busy (c : Jarl.Cluster V S MAX CAP) (env : DEnv V S MAX) (h : ¬ Idle c.node) :
    Cluster.step c env = pure (.Err .Busy, c) := by
  unfold Cluster.step Node.step
  simp only [errs_avail_busy _ h, pure_bind]

/-! ## `ClusterState::restore` and `Cluster::new` -/

/-- `ClusterState::restore` fails exactly on a joint genesis configuration, with `Config`. -/
theorem errs_restore (id : Id) (g : Membership MAX) (st : DState V S MAX CAP) (e : Error)
    (h : ClusterState.restore (V := V) (S := S) id g st = .Err e) : e = .Config ∧ g.is_joint = true := by
  unfold ClusterState.restore at h
  cases hj : g.is_joint
  · simp [hj] at h
  · simp only [hj] at h
    cases h
    exact ⟨rfl, rfl⟩

theorem errs_restore_joint (id : Id) (g : Membership MAX) (st : DState V S MAX CAP) (hj : g.is_joint = true) :
    ClusterState.restore (V := V) (S := S) id g st = .Err .Config := by
  unfold ClusterState.restore
  simp [hj]

theorem errs_restore_ok (id : Id) (g : Membership MAX) (st : DState V S MAX CAP) (hj : g.is_joint = false) :
    ClusterState.restore (V := V) (S := S) id g st = .Ok { id := id, genesis := g, state := st } := by
  unfold ClusterState.restore
  simp [hj]

/-- The settings `Cluster::new` rejects (for a capacity `CAP`): fewer than four
    slots, no heartbeat interval, an election timeout not above the heartbeat,
    or one above `u64::MAX / 2`. -/
def NewErr (CAP : Nat) (settings : Settings) : Prop :=
  CAP < 4 ∨ settings.heartbeat_ticks.val = 0 ∨ settings.election_ticks.val ≤ settings.heartbeat_ticks.val ∨
    2 ^ 63 ≤ settings.election_ticks.val

/-- `Cluster::new` fails only with `Config`, and only for settings `NewErr` rejects. -/
theorem errs_new (settings : Settings) (saved : ClusterState V S MAX CAP) (hCw : CAP < 2 ^ Rust.usizeBits)
    (e : Error) (h : Cluster.new settings saved = pure (.Err e)) : e = .Config ∧ NewErr CAP settings := by
  have h4 : ((4 : Rust.usize) : Nat) = 4 := rfl
  unfold Cluster.new at h
  split at h
  · rename_i hcap
    cases Rust.pure_inj h
    refine ⟨rfl, Or.inl ?_⟩
    simpa only [decide_eq_true_eq, Fin.lt_def, Rust.val_usizeOf _ hCw, h4] using hcap
  rename_i hcap
  have hcap4 : 4 ≤ CAP := by
    apply Classical.byContradiction; intro hn; apply hcap
    simp only [decide_eq_true_eq, Fin.lt_def, Rust.val_usizeOf _ hCw, h4]; omega
  obtain ⟨t1, hb, h⟩ := Rust.bind_eq_pure h
  unfold Node.build at hb
  split at hb
  · rename_i hc
    cases Rust.pure_inj hb
    simp only at h
    cases Rust.pure_inj h
    refine ⟨rfl, Or.inr ?_⟩
    have hz : (Rust.usizeOf CAP == 0) = false := by
      rw [beq_eq_false_iff_ne]; intro h0; have := congrArg Fin.val h0; rw [Rust.val_usizeOf _ hCw] at this
      have h00 : ((0 : Rust.usize) : Nat) = 0 := rfl
      omega
    simp only [hz, Bool.false_or, Bool.or_eq_true, beq_iff_eq, decide_eq_true_eq] at hc
    rcases hc with (hc | hc) | hc
    · exact Or.inl (by rw [hc]; rfl)
    · exact Or.inr (Or.inl (Fin.le_def.mp hc))
    · refine Or.inr (Or.inr ?_)
      simp only [gt_iff_lt, Fin.lt_def, Rust.divK, Rust.umax] at hc
      omega
  · obtain ⟨m, -, hb⟩ := Rust.bind_eq_pure hb
    obtain ⟨m1, -, hb⟩ := Rust.bind_eq_pure hb
    cases Rust.pure_inj hb
    simp only at h
    cases Rust.pure_inj h

theorem errs_new_of (settings : Settings) (saved : ClusterState V S MAX CAP) (hCw : CAP < 2 ^ Rust.usizeBits)
    (hb : NewErr CAP settings) : Cluster.new settings saved = pure (.Err .Config) := by
  have h4 : ((4 : Rust.usize) : Nat) = 4 := rfl
  unfold Cluster.new
  by_cases hcap : CAP < 4
  · have : decide (Rust.usizeOf CAP < (4 : Rust.usize)) = true := by
      simp only [decide_eq_true_eq, Fin.lt_def, Rust.val_usizeOf _ hCw, h4]; exact hcap
    rw [if_pos this]
  · have : decide (Rust.usizeOf CAP < (4 : Rust.usize)) = false := by
      simp only [decide_eq_false_iff_not, Fin.lt_def, Rust.val_usizeOf _ hCw, h4]; exact hcap
    rw [if_neg (by simp only [this]; decide)]
    unfold Node.build
    dsimp only
    split
    · rfl
    · rename_i hn
      apply absurd _ hn
      simp only [Bool.or_eq_true, beq_iff_eq, decide_eq_true_eq, gt_iff_lt, Fin.lt_def, Fin.le_def, Rust.divK, Rust.umax]
      rcases hb with hb | hb | hb | hb
      · exact absurd hb hcap
      · exact Or.inl (Or.inl (Or.inr (Fin.ext (by rw [hb]; rfl))))
      · exact Or.inl (Or.inr hb)
      · right; omega

/-! ## Summary: every error leaves the cluster unchanged; `Busy` exactly when not idle -/

theorem errs_propose_unchanged (c : Jarl.Cluster V S MAX CAP) (hp : Pre c.node) (v : V) (e : Error)
    (c' : Jarl.Cluster V S MAX CAP) (h : Cluster.propose c v = pure (.Err e, c')) : c' = c :=
  (errs_propose c hp v e c' h).1

theorem errs_propose_batch_unchanged (c : Jarl.Cluster V S MAX CAP) (hp : Pre c.node) (vs : Array V)
    (hvs : vs.size < 2 ^ Rust.usizeBits) (e : Error) (c' : Jarl.Cluster V S MAX CAP)
    (h : Cluster.propose_batch c vs = pure (.Err e, c')) : c' = c :=
  (errs_propose_batch c hp vs hvs e c' h).1

theorem errs_compact_unchanged (c : Jarl.Cluster V S MAX CAP) (hp : Pre c.node) (index : Rust.u64) (app : S)
    (e : Error) (c' : Jarl.Cluster V S MAX CAP) (h : Cluster.compact c index app = pure (.Err e, c')) : c' = c :=
  (errs_compact c hp index app e c' h).1

theorem errs_set_learners_err (c : Jarl.Cluster V S MAX CAP) (hp : Pre c.node) (learners : Array Id)
    (hl : learners.size < 2 ^ Rust.usizeBits) (e : Error) (c' : Jarl.Cluster V S MAX CAP)
    (h : Cluster.set_learners c learners = pure (.Err e, c')) : c' = c ∧ SetLearnersErr c.node learners e := by
  rcases errs_set_learners c hp learners hl _ c' h with ⟨e', he, hc, hE⟩ | ⟨_, _, he, _⟩
  · cases he; exact ⟨hc, hE⟩
  · cases he

theorem errs_reconfigure_err (c : Jarl.Cluster V S MAX CAP) (hp : Pre c.node) (target : Membership MAX)
    (e : Error) (c' : Jarl.Cluster V S MAX CAP)
    (h : Cluster.reconfigure c target = pure (.Err e, c')) : c' = c ∧ ReconfigureErr c.node target e := by
  rcases errs_reconfigure c hp target _ c' h with ⟨e', he, hc, hE⟩ | ⟨_, _, he, _⟩
  · cases he; exact ⟨hc, hE⟩
  · cases he

theorem errs_finish_err (c : Jarl.Cluster V S MAX CAP) (hp : Pre c.node) (e : Error) (c' : Jarl.Cluster V S MAX CAP)
    (h : Cluster.finish_reconfiguration c = pure (.Err e, c')) : c' = c ∧ FinishErr c.node e := by
  rcases errs_finish c hp _ c' h with ⟨e', he, hc, hE⟩ | ⟨_, he, _⟩
  · cases he; exact ⟨hc, hE⟩
  · cases he

theorem errs_step_unchanged (c : Jarl.Cluster V S MAX CAP) (env : DEnv V S MAX) (e : Error)
    (c' : Jarl.Cluster V S MAX CAP) (h : Cluster.step c env = pure (.Err e, c')) : c' = c :=
  (errs_step c env e c' h).1

theorem errs_propose_busy_iff (c : Jarl.Cluster V S MAX CAP) (hp : Pre c.node) (v : V) :
    (∃ c', Cluster.propose c v = pure (.Err .Busy, c')) ↔ ¬ Idle c.node :=
  ⟨fun ⟨c', h⟩ => by simpa [PropErr] using (errs_propose c hp v _ c' h).2, fun h => ⟨c, errs_propose_busy c v h⟩⟩

theorem errs_propose_batch_busy_iff (c : Jarl.Cluster V S MAX CAP) (hp : Pre c.node) (vs : Array V)
    (hvs : vs.size < 2 ^ Rust.usizeBits) :
    (∃ c', Cluster.propose_batch c vs = pure (.Err .Busy, c')) ↔ ¬ Idle c.node :=
  ⟨fun ⟨c', h⟩ => by simpa [PropErr] using (errs_propose_batch c hp vs hvs _ c' h).2,
   fun h => ⟨c, errs_propose_batch_busy c vs h⟩⟩

theorem errs_compact_busy_iff (c : Jarl.Cluster V S MAX CAP) (hp : Pre c.node) (index : Rust.u64) (app : S) :
    (∃ c', Cluster.compact c index app = pure (.Err .Busy, c')) ↔ ¬ Idle c.node :=
  ⟨fun ⟨c', h⟩ => by simpa [CompactErr] using (errs_compact c hp index app _ c' h).2,
   fun h => ⟨c, errs_compact_busy c hp index app h⟩⟩

theorem errs_set_learners_busy_iff (c : Jarl.Cluster V S MAX CAP) (hp : Pre c.node) (learners : Array Id)
    (hl : learners.size < 2 ^ Rust.usizeBits) :
    (∃ c', Cluster.set_learners c learners = pure (.Err .Busy, c')) ↔ ¬ Idle c.node :=
  ⟨fun ⟨c', h⟩ => by simpa [SetLearnersErr, ChangeErr] using (errs_set_learners_err c hp learners hl _ c' h).2,
   fun h => ⟨c, errs_set_learners_busy c learners h⟩⟩

theorem errs_reconfigure_busy_iff (c : Jarl.Cluster V S MAX CAP) (hp : Pre c.node) (target : Membership MAX) :
    (∃ c', Cluster.reconfigure c target = pure (.Err .Busy, c')) ↔ ¬ Idle c.node :=
  ⟨fun ⟨c', h⟩ => by simpa [ReconfigureErr, ChangeErr] using (errs_reconfigure_err c hp target _ c' h).2,
   fun h => ⟨c, errs_reconfigure_busy c target h⟩⟩

theorem errs_finish_busy_iff (c : Jarl.Cluster V S MAX CAP) (hp : Pre c.node) :
    (∃ c', Cluster.finish_reconfiguration c = pure (.Err .Busy, c')) ↔ ¬ Idle c.node :=
  ⟨fun ⟨c', h⟩ => by simpa [FinishErr] using (errs_finish_err c hp _ c' h).2,
   fun h => ⟨c, errs_finish_busy c h⟩⟩

theorem errs_tick_busy_iff (c : Jarl.Cluster V S MAX CAP) :
    (∃ c', Cluster.tick c = pure (.Err .Busy, c')) ↔ ¬ Idle c.node :=
  ⟨fun ⟨c', h⟩ => (errs_tick_busy_eq c c' h).2, fun h => ⟨c, errs_tick_busy c h⟩⟩

theorem errs_step_busy_iff (c : Jarl.Cluster V S MAX CAP) (env : DEnv V S MAX) :
    (∃ c', Cluster.step c env = pure (.Err .Busy, c')) ↔ ¬ Idle c.node :=
  ⟨fun ⟨c', h⟩ => by simpa using (errs_step c env _ c' h).2, fun h => ⟨c, errs_step_busy c env h⟩⟩

end Jarl.Engine.Dyn
