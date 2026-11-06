import Engine.Dyn.OpAppend

/-!
# `step` on a dynamic node
-/

set_option linter.unusedSectionVars false

namespace Jarl.Engine.Dyn
open Jarl Jarl.Engine

variable {V S : Type} {MAX CAP : Nat} [Rust.Clone V] [Rust.Clone S]

/-- The `send` target for slot `a`: its index, or `MAX` for the requester. -/
def PeerOf (a : Option (Fin MAX)) (p : Rust.usize) : Prop :=
  match a with
  | some i => p.val = i.val
  | none => p = Rust.usizeOf MAX

theorem send_q (n : DNode V S MAX CAP) (a : Option (Fin MAX)) (p : Rust.usize) (src : Id) (o : Outbound)
    (hMAX : MAX < 2 ^ Rust.usizeBits) (hpa : PeerOf a p) (hr : n.request_from = some src) :
    Node.send n p o = pure (queueD n a src o) := by
  cases a with
  | some i =>
    have hpv : p.val = i.val := hpa
    rw [send_eq n p o hMAX (by rw [hpv]; exact i.isLt)]
    simp only [queueD, hpv]
  | none =>
    have hpv : p = Rust.usizeOf MAX := hpa
    subst hpv
    simp [Node.send, hr, queueD]

theorem reply_q (n : DNode V S MAX CAP) (a : Option (Fin MAX)) (p : Rust.usize) (src : Id) (i : Rust.u64)
    (rj : Option Rejection) (hMAX : MAX < 2 ^ Rust.usizeBits) (hpa : PeerOf a p) (hr : n.request_from = some src) :
    Node.reply n p i rj = pure (queueD n a src (.Replicated i rj)) := by
  simp [Node.reply, send_q n a p src _ hMAX hpa hr]

/-- Consecutive indices after `p`. -/
def ChainD : LogId → List (DEntry V MAX) → Prop
  | _, [] => True
  | p, e :: es => e.id.index.val = p.index.val + 1 ∧ ChainD e.id es

theorem valid_append (t : Rust.u64) (prev : LogId) (entry : Option (DEntry V MAX)) (c : Rust.u64)
    (h : Node.valid (V := Record V MAX) (S := Checkpoint S MAX) (N := MAX) (CAP := CAP) (.Append t prev entry c) = pure true) :
    ∀ e, entry = some e → e.id.index.val = prev.index.val + 1 := by
  intro e he
  subst he
  unfold Node.valid at h
  simp at h
  split at h
  · have h' := Rust.pure_inj h
    simp only [Bool.and_eq_true, beq_iff_eq] at h'
    obtain ⟨-, ⟨-, hc⟩, -⟩ := h'
    split at hc
    · simp only [Option.some.injEq] at hc; rw [← hc]
    · cases hc
  · cases Rust.pure_inj h

/-- A validity loop over optional entries: a returned flag stays unset only if
    every present entry follows the previous one. -/
theorem chain_loop {β : Type} (f : Option (DEntry V MAX) → (Option Bool × LogId × β) → Rust.M (ForInStep (Option Bool × LogId × β)))
    (hy : ∀ e b b', f (some e) b = pure (.yield b') → e.id.index.val = b.2.1.index.val + 1 ∧ b'.2.1 = e.id)
    (hy' : ∀ b b', f none b = pure (.yield b') → b'.2.1 = b.2.1)
    (hd : ∀ x b b', f x b = pure (.done b') → b'.1 = some false)
    (l : List (Option (DEntry V MAX))) (b r : Option Bool × LogId × β) (h : forIn l b f = pure r) (hr : r.1 = none) :
    ChainD b.2.1 (Rust.Iter.flatten l) := by
  induction l generalizing b with
  | nil => simp [Rust.Iter.flatten, ChainD]
  | cons x xs ih =>
    rw [List.forIn_cons] at h
    obtain ⟨st, hst, h⟩ := Rust.bind_eq_pure h
    cases st with
    | done b' =>
      simp at h
      have := hd x b b' hst
      rw [Rust.pure_inj h] at this
      rw [this] at hr; cases hr
    | yield b' =>
      simp only at h
      have := ih b' h
      cases x with
      | none =>
        rw [hy' b b' hst] at this
        simpa [Rust.Iter.flatten] using this
      | some e =>
        obtain ⟨h1, h2⟩ := hy e b b' hst
        rw [h2] at this
        show ChainD b.2.1 (e :: Rust.Iter.flatten xs)
        exact ⟨h1, this⟩

theorem valid_batch (t : Rust.u64) (prev : LogId) (entries : Vector (Option (DEntry V MAX)) MAX_APPEND_ENTRIES) (c : Rust.u64)
    (h : Node.valid (V := Record V MAX) (S := Checkpoint S MAX) (N := MAX) (CAP := CAP) (.AppendBatch t prev entries c) = pure true) :
    ChainD prev (Rust.Iter.flatten entries.toList) := by
  unfold Node.valid at h
  dsimp only at h
  split at h
  · split at h
    · cases Rust.pure_inj h
    · obtain ⟨st, hst, h⟩ := Rust.bind_eq_pure h
      have hflag := forIn_pure_inv _ _ _ (fun _ b => b.1 = none ∨ b.1 = some false) (Or.inl rfl) (by
        intro k hk b b' _
        constructor
        · intro hx
          generalize entries.toList[k] = x at hx
          cases x with
          | none => cases Rust.pure_inj hx; exact Or.inl rfl
          | some e =>
            dsimp only at hx
            split at hx
            · cases Rust.pure_inj hx
            · obtain ⟨t1, -, hx⟩ := Rust.bind_eq_pure hx
              cases Rust.pure_inj hx; exact Or.inl rfl
        · intro hx m _ _
          generalize entries.toList[k] = x at hx
          cases x with
          | none => cases Rust.pure_inj hx
          | some e =>
            dsimp only at hx
            split at hx
            · cases Rust.pure_inj hx; exact Or.inr rfl
            · obtain ⟨t1, -, hx⟩ := Rust.bind_eq_pure hx
              cases Rust.pure_inj hx) st hst
      have hr : st.1 = none := by
        rcases hflag with h1 | h1
        · exact h1
        · rw [h1] at h; cases Rust.pure_inj h
      refine chain_loop _ ?_ ?_ ?_ _ _ st hst hr
      · intro e b b' hx
        dsimp only at hx
        split at hx
        · cases Rust.pure_inj hx
        · rename_i hc
          obtain ⟨t1, -, hx⟩ := Rust.bind_eq_pure hx
          cases Rust.pure_inj hx
          refine ⟨?_, rfl⟩
          simp only [Bool.or_eq_true, not_or, bne_iff_ne, ne_eq, Classical.not_not] at hc
          have hc2 := hc.1.2
          simp only [Rust.checked_add_eq] at hc2
          split at hc2
          · simp only [Option.some.injEq] at hc2; rw [← hc2]; rfl
          · cases hc2
      · intro b b' hx
        cases Rust.pure_inj hx; rfl
      · intro x b b' hx
        cases x with
        | none => cases Rust.pure_inj hx
        | some e =>
          dsimp only at hx
          split at hx
          · cases Rust.pure_inj hx; rfl
          · obtain ⟨t1, -, hx⟩ := Rust.bind_eq_pure hx
            cases Rust.pure_inj hx
  · obtain ⟨st, hst, h⟩ := Rust.bind_eq_pure h
    cases Rust.pure_inj hst
    cases Rust.pure_inj h

/-- Commit index between the snapshot boundary and the last entry. -/
def Bnd (n : DNode V S MAX CAP) : Prop :=
  n.state.base.index.val ≤ n.state.hard.commit.val ∧ n.state.hard.commit.val ≤ (lastId n.state).index.val

theorem refresh_facts (n n' : DNode V S MAX CAP) (h : Refresh n n') :
    n'.state = n.state ∧ n'.config = n.config ∧ n'.hooks = n.hooks ∧ n'.request_from = n.request_from ∧
      (∀ i j : Fin MAX, ∀ x, n'.peers[i] = some x → n'.peers[j] = some x → i = j) := by
  obtain ⟨n1, ⟨hs, -, hu⟩, -, hn⟩ := h
  have e1 : n1.state = n.state := by rw [hs]
  have e2 : n1.config = n.config := by rw [hs]
  have e3 : n1.hooks = n.hooks := by rw [hs]
  have e4 : n1.request_from = n.request_from := by rw [hs]
  rcases hn with rfl | ⟨-, -, -, ⟨r, d, rfl⟩⟩
  · exact ⟨e1, e2, e3, e4, hu⟩
  · exact ⟨e1, e2, e3, e4, hu⟩

theorem pre_of (n n' : DNode V S MAX CAP) (hp : Pre n) (hl : Layout n'.state) (hc : Contig n'.state)
    (hcf : n'.config = n.config) (hh : n'.hooks = n.hooks)
    (hu : ∀ i j : Fin MAX, ∀ x, n'.peers[i] = some x → n'.peers[j] = some x → i = j) : Pre n' :=
  { hooks := hh.trans hp.hooks, layout := hl, contig := hc, n_lt := hp.n_lt, cap_lt := hp.cap_lt,
    e0 := by rw [hcf]; exact hp.e0, e1 := by rw [hcf]; exact hp.e1, uniq := hu }

theorem min_le' (a b : Rust.u64) : (Rust.min a b).val ≤ b.val := by
  unfold Rust.min; split <;> omega

theorem idAt_le (s : DState V S MAX CAP) (hl : Layout s) (hc : Contig s) (id : LogId)
    (h : idAt s id.index.val = some id) : id.index.val ≤ (lastId s).index.val := by
  obtain ⟨h1, h2⟩ := idAt_some s hl hc id h
  rw [lastId_eq s hc]; omega

theorem commit_facts (n n' : DNode V S MAX CAP) (i : Rust.u64) (hp : Pre n) (hb : Bnd n)
    (hi : i.val ≤ (lastId n.state).index.val) (h : CommitTo n i n') :
    Pre n' ∧ Bnd n' ∧ n'.request_from = n.request_from := by
  rcases h with ⟨hlt, hr⟩ | ⟨-, rfl⟩
  · have hct : commitTo n i = { n with state := { n.state with hard := { n.state.hard with commit := i } }, dirty := true } := by
      simp [commitTo, hlt]
    rw [hct] at hr
    obtain ⟨hs, hc, hh, hrf, hu⟩ := refresh_facts _ _ hr
    have hlt' : n.state.hard.commit.val < i.val := hlt
    refine ⟨pre_of n n' hp (by rw [hs]; exact hp.layout) (by rw [hs]; exact hp.contig) hc hh hu, ?_, hrf⟩
    rw [Bnd, hs]
    exact ⟨by have := hb.1; show n.state.base.index.val ≤ i.val; omega, hi⟩
  · exact ⟨hp, hb, rfl⟩

theorem appendD_facts (n n' : DNode V S MAX CAP) (prev : LogId) (entry : Option (DEntry V MAX)) (commit : Rust.u64)
    (r : Rust.u64 × Option Rejection) (hp : Pre n) (hb : Bnd n) (h : AppendD n prev entry commit r n') :
    Pre n' ∧ Bnd n' ∧ n'.request_from = n.request_from := by
  rcases h with ⟨-, -, -, rfl⟩ | ⟨hid, -, -, hc⟩ | ⟨e, -, -, hid, -, hc⟩ | ⟨e, -, -, -, -, -, rfl⟩ |
      ⟨e, hid, -, -, -, hc⟩ | ⟨e, s', n1, -, -, -, hlt, ⟨hret, hhard, hsn, hl, hcg⟩, -, hr, hc⟩
  · exact ⟨hp, hb, rfl⟩
  · exact commit_facts _ _ _ hp hb (Nat.le_trans (min_le' _ _) (idAt_le _ hp.layout hp.contig _ hid)) hc
  · exact commit_facts _ _ _ hp hb (Nat.le_trans (min_le' _ _) (idAt_le _ hp.layout hp.contig _ hid)) hc
  · exact ⟨hp, hb, rfl⟩
  · exact commit_facts _ _ _ hp hb (Nat.le_trans (min_le' _ _) (idAt_le _ hp.layout hp.contig _ hid)) hc
  · obtain ⟨hs1, hc1, hh1, hrf1, hu1⟩ := refresh_facts _ _ hr
    have hpm : Pre { n1 with dirty := true, log_from := some (Rust.Option.map_or n1.log_from e.id.index (fun f => Rust.min f e.id.index)) } :=
      pre_of n _ hp (by show Layout n1.state; rw [hs1]; exact hl) (by show Contig n1.state; rw [hs1]; exact hcg) hc1 hh1 hu1
    have hlast : lastId s' = e.id := by unfold lastId; rw [hret]; simp
    have hbase : s'.base = n.state.base := by unfold State.base; rw [hsn]
    have hbm : Bnd { n1 with dirty := true, log_from := some (Rust.Option.map_or n1.log_from e.id.index (fun f => Rust.min f e.id.index)) } := by
      show n1.state.base.index.val ≤ n1.state.hard.commit.val ∧ n1.state.hard.commit.val ≤ (lastId n1.state).index.val
      rw [hs1]
      show s'.base.index.val ≤ s'.hard.commit.val ∧ s'.hard.commit.val ≤ (lastId s').index.val
      rw [hbase, hhard, hlast]
      exact ⟨hb.1, Nat.le_of_lt hlt⟩
    obtain ⟨h1, h2, h3⟩ := commit_facts _ _ _ hpm hbm (by
      show _ ≤ (lastId n1.state).index.val
      rw [hs1]; show _ ≤ (lastId s').index.val
      rw [hlast]; exact min_le' _ _) hc
    exact ⟨h1, h2, h3.trans hrf1⟩

theorem batch_loop [Rust.LawfulClone V] (commit : Rust.u64) (L : List (DEntry V MAX)) :
    ∀ (m : DNode V S MAX CAP) (p : LogId) (acc : Bool) (resp : Rust.u64 × Option Rejection)
      (out : DNode V S MAX CAP × LogId × Bool × Rust.u64 × Option Rejection),
      Pre m → Bnd m → ChainD p L → (acc = true → resp.2 = none) →
      forIn L (m, p, acc, resp) (fun entry_1 (__s : DNode V S MAX CAP × LogId × Bool × Rust.u64 × Option Rejection) => do
          let __x ← Node.append __s.1 __s.2.1 (some entry_1) commit
          if __x.1.2.isSome = true then
            if (!__s.2.2.1) = true then pure (ForInStep.done (__x.2, __s.2.1, __s.2.2.1, __x.1.1, __x.1.2))
            else pure (ForInStep.done (__x.2, __s.2.1, __s.2.2.1, __s.2.2.2))
          else pure (ForInStep.yield (__x.2, entry_1.id, true, __x.1.1, none))) = pure out →
      Pre out.1 ∧ Bnd out.1 ∧ out.1.request_from = m.request_from ∧
        (acc = false → resp = (p.index, none) → BatchD m p L commit out.2.2.2 out.1) ∧
        (acc = true → BatchAfterD m p L commit resp.1 out.2.2.2 out.1) := by
  induction L with
  | nil =>
    intro m p acc resp out hp hb _ hacc h
    simp only [List.forIn_nil] at h
    cases Rust.pure_inj h
    refine ⟨hp, hb, rfl, fun _ hr => ?_, fun ha => ?_⟩
    · subst hr; exact BatchD.nil m p commit
    · obtain ⟨i, rj⟩ := resp
      have : rj = none := hacc ha
      subst this
      exact BatchAfterD.nil m p commit i
  | cons e es ih =>
    intro m p acc resp out hp hb hch hacc h
    rw [List.forIn_cons] at h
    obtain ⟨st, hst, h⟩ := Rust.bind_eq_pure h
    obtain ⟨⟨⟨ri, rj⟩, m1⟩, hap, hst⟩ := Rust.bind_eq_pure hst
    have hAD := append_rel' m hp p (some e) commit hb.1 hb.2 (fun e' he' => by cases he'; exact hch.1) _ m1 hap
    obtain ⟨hp1, hb1, hrf1⟩ := appendD_facts _ _ _ _ _ _ hp hb hAD
    dsimp only at hst
    by_cases hrj : rj.isSome = true
    · rw [if_pos hrj] at hst
      cases acc
      · rw [if_pos (by decide : (!false) = true)] at hst
        cases Rust.pure_inj hst
        simp only at h
        cases Rust.pure_inj h
        exact ⟨hp1, hb1, hrf1, fun _ _ => BatchD.reject m m1 p e es commit (ri, rj) hAD hrj, (fun h => by cases h)⟩
      · rw [if_neg (by decide)] at hst
        cases Rust.pure_inj hst
        simp only at h
        cases Rust.pure_inj h
        obtain ⟨i, rj'⟩ := resp
        have : rj' = none := hacc rfl
        subst this
        exact ⟨hp1, hb1, hrf1, (fun h => by cases h), fun _ => BatchAfterD.reject m m1 p e es commit i (ri, rj) hAD hrj⟩
    · rw [if_neg hrj] at hst
      cases Rust.pure_inj hst
      simp only at h
      have hr2 : rj = none := by simpa using hrj
      subst hr2
      obtain ⟨hpo, hbo, hrfo, -, hafter⟩ := ih m1 e.id true (ri, none) out hp1 hb1 hch.2 (fun _ => rfl) h
      exact ⟨hpo, hbo, hrfo.trans hrf1,
        fun _ _ => BatchD.accept m m1 out.1 p e es commit (ri, none) out.2.2.2 hAD rfl (hafter rfl),
        fun _ => BatchAfterD.accept m m1 out.1 p e es commit resp.1 (ri, none) out.2.2.2 hAD rfl (hafter rfl)⟩

theorem observe_split' {β : Type} (n : DNode V S MAX CAP) (hp : Pre n) (hb : Bnd n) (src : Id) (t : Rust.u64)
    (K : DNode V S MAX CAP → Rust.M β) (x : β)
    (h : (if decide (t > n.state.hard.term) = true then
        (Node.follow { n with request_from := some src, state := { n.state with hard := { n.state.hard with term := t, voted_for := none } }, dirty := true } none >>= K)
      else K { n with request_from := some src }) = pure x) :
    ∃ n1, ObservedD n src t n1 ∧ Pre n1 ∧ Bnd n1 ∧ n1.request_from = some src ∧
      t.val ≤ n1.state.hard.term.val ∧ K n1 = pure x := by
  by_cases ht : n.state.hard.term < t
  · rw [if_pos (decide_eq_true ht)] at h
    obtain ⟨n1, hfo, hT⟩ := follow_eq' { n with request_from := some src, state := { n.state with hard := { n.state.hard with term := t, voted_for := none } }, dirty := true } hp.e0 hp.e1 none
    rw [hfo, pure_bind] at h
    obtain ⟨r, d, hn1⟩ := hT
    refine ⟨n1, Or.inr ⟨Fin.lt_def.mp ht, ⟨r, d, by rw [hn1]; simp⟩⟩, by rw [hn1]; exact { hp with layout := hp.layout, contig := hp.contig, uniq := hp.uniq },
      by rw [hn1]; exact hb, by rw [hn1], by rw [hn1]; exact Nat.le_refl _, h⟩
  · rw [if_neg (by simpa using ht)] at h
    have ht' : t.val ≤ n.state.hard.term.val := by rw [Fin.lt_def] at ht; omega
    exact ⟨_, Or.inl ⟨ht', rfl⟩, { hp with layout := hp.layout, contig := hp.contig, uniq := hp.uniq }, hb, rfl, ht', h⟩

theorem follow_some' (n : DNode V S MAX CAP) (hp : Pre n) (hb : Bnd n) (src : Id) :
    ∃ n2, Node.follow n (some src) = pure n2 ∧ FollowingD n src n2 ∧ Pre n2 ∧ Bnd n2 ∧
      n2.request_from = n.request_from := by
  obtain ⟨n2, hfo, hT⟩ := follow_eq' n hp.e0 hp.e1 (some src)
  obtain ⟨r, d, rfl⟩ := hT
  exact ⟨_, hfo, ⟨r, d, by simp⟩, { hp with layout := hp.layout, contig := hp.contig, uniq := hp.uniq }, hb, rfl⟩

theorem set_q {α : Type} (v : Vector α MAX) (p : Rust.usize) (i : Fin MAX) (x : α) (hpv : p.val = i.val) :
    Rust.Slice.set v p x = pure (v.set i.val x i.isLt) := by
  rw [Rust.Slice.set_ok _ _ _ (by rw [hpv]; exact i.isLt)]
  simp only [hpv]

theorem granted_eq' (v : Option Id) (src : Id) (l o : LogId) :
    (Rust.Option.is_none_or v (fun id => id == src) &&
      (decide (l.term > o.term) || (l.term == o.term && decide (l.index ≥ o.index)))) =
    decide ((v = none ∨ v = some src) ∧ upToDate l o) := by
  rw [Bool.eq_iff_iff]
  cases v <;> simp [Rust.Option.is_none_or, upToDate, Fin.lt_def, Fin.le_def, Fin.ext_iff] <;> omega

theorem vote_same' (n1 : DNode V S MAX CAP) (src : Id) (hv : n1.state.hard.voted_for = some src) :
    ({ n1 with state := { n1.state with hard := { n1.state.hard with voted_for := some src } }, dirty := (n1.dirty || decide (n1.state.hard.voted_for ≠ some src)) } : DNode V S MAX CAP) = n1 := by
  rcases n1 with ⟨_, ⟨⟨_, _, _⟩, _, _, _⟩⟩
  simp only at hv
  subst hv
  simp

/-- Messages an identity without a slot may send. -/
def NoSlotOk : DMsg V S MAX → Prop
  | .Vote .. | .PreVote .. | .Append .. | .AppendBatch .. | .Install .. => True
  | _ => False

/-- Every run of `step` that returns follows a path of `SteppedD`, with `a` the
    sender's slot (or `none` when it has none). Unless nothing changed, the
    envelope was addressed to the node from another identity and is valid. -/
theorem step_rel' [Rust.LawfulClone V] [Rust.LawfulClone S] (n : DNode V S MAX CAP) (hp : Pre n)
    (hbase : n.state.base.index.val ≤ n.state.hard.commit.val)
    (hcommit : n.state.hard.commit.val ≤ (lastId n.state).index.val)
    (env : DEnv V S MAX) (r : Rust.Result Unit Error) (n' : DNode V S MAX CAP)
    (h : Node.step n env = pure (r, n')) :
    ∃ a : Option (Fin MAX), (∀ i, a = some i → n.peers[i] = some env.from) ∧
      (a = none → ∀ i : Fin MAX, n.peers[i] ≠ some env.from) ∧
      SteppedD n a env.from env.message n' ∧
      (n' = n ∨ (env.to = n.config.id ∧ env.from ≠ n.config.id ∧
        Node.valid (V := Record V MAX) (S := Checkpoint S MAX) (N := MAX) (CAP := CAP) env.message = pure true)) := by
  have hMAX := hp.n_lt
  rcases env with ⟨src, dst, msg⟩
  obtain ⟨a, ha1, ha2, hpa⟩ : ∃ a : Option (Fin MAX), (∀ i, a = some i → n.peers[i] = some src) ∧
      (a = none → ∀ i : Fin MAX, n.peers[i] ≠ some src) ∧
      Rust.Iter.position n.peers.toList (fun id => id == some src) = a.map (fun i => Rust.ofNat i.val) := by
    cases hpos : Rust.Iter.position n.peers.toList (fun id => id == some src) with
    | none => exact ⟨none, (fun _ h => by cases h), (fun _ => pos_none n src hpos), rfl⟩
    | some q =>
      obtain ⟨hs, hq⟩ := position_some _ _ _ (by simpa using hMAX) hpos
      have hqM : q.val < MAX := by simpa using hs
      refine ⟨some ⟨q.val, hqM⟩, (fun i hi => ?_), (fun h => by cases h), ?_⟩
      · cases hi
        have : n.peers.toList[q.val]'hs = n.peers[q.val] := by simp
        rw [this] at hq; simpa using hq
      · simp only [Option.map_some]; congr 1; apply Fin.ext; simp [Rust.ofNat]; uomega
  refine ⟨a, ha1, ha2, ?_⟩
  dsimp only
  unfold Node.step at h
  cases hA : Node.available n
  case Err e =>
    simp only [hA] at h
    obtain rfl := (congrArg Prod.snd (Rust.pure_inj h))
    exact ⟨.same _, Or.inl rfl⟩
  rename_i u
  have hI := idle_of_available n (by cases u; exact hA)
  have hk : n.hooks.isSome = true := by rw [hp.hooks]; rfl
  simp only [hA, hk, Bool.true_and, pure_bind] at h
  split at h
  rotate_left
  · obtain rfl := (congrArg Prod.snd (Rust.pure_inj h))
    exact ⟨.same _, Or.inl rfl⟩
  rename_i peer hpeer
  rw [hpa] at hpeer
  have hPO : PeerOf a peer ∧ (a = none → NoSlotOk msg) := by
    cases a with
    | none =>
      cases msg <;> simp [Option.orElse, Rust.Option.ok_or, Rust.Option.then_some] at hpeer <;>
        exact ⟨hpeer.symm, fun _ => trivial⟩
    | some i =>
      simp [Option.orElse, Rust.Option.ok_or] at hpeer
      subst hpeer
      refine ⟨?_, fun h => by cases h⟩
      show (Rust.ofNat i.val : Rust.usize).val = i.val
      simp [Rust.ofNat]; uomega
  obtain ⟨hPO, hns⟩ := hPO
  clear hpeer
  by_cases hc : (!(src == n.config.id || dst != n.config.id)) = true
  rotate_left
  · rw [if_neg hc] at h
    obtain rfl := (congrArg Prod.snd (Rust.pure_inj h))
    exact ⟨.same _, Or.inl rfl⟩
  rw [if_pos hc] at h
  replace h := Rust.bind_eq_pure h
  obtain ⟨v, hv, h⟩ := h
  cases v
  · obtain rfl := (congrArg Prod.snd (Rust.pure_inj h))
    exact ⟨.same _, Or.inl rfl⟩
  have hc' : dst = n.config.id ∧ src ≠ n.config.id := by
    simp only [Bool.not_or, Bool.and_eq_true, Bool.not_eq_true', beq_eq_false_iff_ne, bne_eq_false_iff_eq] at hc
    exact ⟨hc.2, hc.1⟩
  refine ⟨?_, Or.inr ⟨hc'.1, hc'.2, hv⟩⟩
  simp only [Bool.not_true, Bool.false_eq_true, if_false] at h
  have hb : Bnd n := ⟨hbase, hcommit⟩
  clear hc hc' hA hpa hbase hcommit
  cases msg with
  | PreVote t last => ?prevote
  | PreVoted t c g => ?prevoted
  | Vote t last => ?vote
  | Voted t g => ?voted
  | Append t prev entry commit => ?append
  | AppendBatch t prev entries commit => ?batch
  | Install t snap => ?install
  | Replicated t index rej => ?replicated
  case prevote =>
    dsimp only at h
    rw [last_eq _ hp.layout.1, pure_bind, send_q _ a peer src _ hMAX hPO rfl, pure_bind] at h
    obtain rfl := (congrArg Prod.snd (Rust.pure_inj h))
    exact SteppedD.prevote t last _ hI
  all_goals
    dsimp only [Message.term] at h
  all_goals
    first
    | (by_cases hig : (true && (n.role == Role.Leader || decide (n.leader_age < n.config.election_ticks))) = true
       · rw [if_pos hig] at h
         obtain rfl := (congrArg Prod.snd (Rust.pure_inj h))
         exact SteppedD.ignored _ hI
       rw [if_neg hig] at h)
    | simp only [Bool.false_and, Bool.false_eq_true, ↓reduceIte] at h
    obtain ⟨n1, hO, hp1, hb1, hrf1, hle, h⟩ := observe_split' n hp hb src t _ _ h
  case prevoted =>
    obtain ⟨i, rfl⟩ : ∃ i, a = some i := by
      cases a with
      | none => exact (hns rfl).elim
      | some i => exact ⟨i, rfl⟩
    have hpv : peer.val = i.val := hPO
    by_cases hc : n1.prevoting = some c ∧ g = true
    · rw [if_pos (by simp [hc.1, hc.2])] at h
      rw [set_q _ _ i _ hpv, pure_bind] at h
      have hpv' : Pre { n1 with votes := n1.votes.set i.val true i.isLt } :=
        { hp1 with layout := hp1.layout, contig := hp1.contig, uniq := hp1.uniq }
      obtain ⟨b, hq, hbq⟩ := election_quorum_eq' { n1 with votes := n1.votes.set i.val true i.isLt } hMAX
      rw [hq, pure_bind] at h
      cases b
      · rw [if_neg (by decide)] at h
        obtain rfl := (congrArg Prod.snd (Rust.pure_inj h))
        exact SteppedD.prevoted t c g n1 _ i hI rfl hO
          (Or.inr ⟨hc.1, hc.2, Or.inl ⟨fun hQ => by simpa using hbq.mpr hQ, rfl⟩⟩)
      · rw [if_pos rfl] at h
        obtain ⟨m, hm, h⟩ := Rust.bind_eq_pure h
        obtain rfl := (congrArg Prod.snd (Rust.pure_inj h))
        exact SteppedD.prevoted t c g n1 _ i hI rfl hO
          (Or.inr ⟨hc.1, hc.2, Or.inr ⟨hbq.mp rfl, campaign_rel' _ _ hpv' c hm⟩⟩)
    · rw [if_neg (by simpa using hc)] at h
      obtain rfl := (congrArg Prod.snd (Rust.pure_inj h))
      exact SteppedD.prevoted t c g n1 n1 i hI rfl hO (Or.inl ⟨hc, rfl⟩)
  all_goals
    by_cases hs : t.val < n1.state.hard.term.val
    · have hd : t < n1.state.hard.term := Fin.lt_def.mpr hs
      simp only [hd, decide_true, if_true] at h
      try rw [send_q n1 a peer src _ hMAX hPO hrf1, pure_bind] at h
      try rw [reply_q n1 a peer src _ _ hMAX hPO hrf1, pure_bind] at h
      obtain rfl := (congrArg Prod.snd (Rust.pure_inj h))
      exact SteppedD.stale _ n1 _ hI hO hs
        (by first | exact Or.inl rfl | exact Or.inr (Or.inl rfl) | exact Or.inr (Or.inr ⟨_, rfl⟩))
    have hd : ¬ t < n1.state.hard.term := fun e => hs (Fin.lt_def.mp e)
    simp only [hd, decide_false, Bool.false_eq_true, if_false] at h
    have hT : n1.state.hard.term = t := Fin.ext (by omega)
    clear hs hle
  -- Vote
  · rw [last_eq _ hp1.layout.1, pure_bind, granted_eq'] at h
    by_cases hG : (n1.state.hard.voted_for = none ∨ n1.state.hard.voted_for = some src) ∧ upToDate last (lastId n1.state)
    · rw [if_pos (by simpa using hG)] at h
      by_cases hv : n1.state.hard.voted_for = some src
      · rw [if_neg (by simp [hv])] at h
        obtain ⟨m6, hr, hT6⟩ := reset_timers' n1 hp1.e0 hp1.e1
        have hrf6 : m6.request_from = some src := by obtain ⟨_, _, rfl⟩ := hT6; exact hrf1
        rw [hr, pure_bind, send_q m6 a peer src _ hMAX hPO hrf6, pure_bind] at h
        obtain rfl := (congrArg Prod.snd (Rust.pure_inj h))
        refine SteppedD.vote t last n1 m6 _ hI hO hT rfl (fun hg => absurd hg (by simpa using hG)) (fun _ => ?_)
        rw [vote_same' n1 src hv]; exact hT6
      · rw [if_pos (by simp [hv])] at h
        obtain ⟨m6, hr, hT6⟩ := reset_timers' { n1 with state := { n1.state with hard := { n1.state.hard with voted_for := some src } }, dirty := true } hp1.e0 hp1.e1
        have hrf6 : m6.request_from = some src := by obtain ⟨_, _, rfl⟩ := hT6; exact hrf1
        rw [hr, pure_bind, send_q m6 a peer src _ hMAX hPO hrf6, pure_bind] at h
        obtain rfl := (congrArg Prod.snd (Rust.pure_inj h))
        refine SteppedD.vote t last n1 m6 _ hI hO hT rfl (fun hg => absurd hg (by simpa using hG)) (fun _ => ?_)
        have hd : (n1.dirty || decide (n1.state.hard.voted_for ≠ some src)) = true := by simp [hv]
        rw [hd]; exact hT6
    · rw [if_neg (by simpa using hG)] at h
      rw [send_q n1 a peer src _ hMAX hPO hrf1, pure_bind] at h
      obtain rfl := (congrArg Prod.snd (Rust.pure_inj h))
      exact SteppedD.vote t last n1 n1 _ hI hO hT rfl (fun _ => rfl) (fun hg => absurd hg (by simpa using hG))
  -- Voted
  · obtain ⟨i, rfl⟩ : ∃ i, a = some i := by
      cases a with
      | none => exact (hns rfl).elim
      | some i => exact ⟨i, rfl⟩
    have hpv : peer.val = i.val := hPO
    by_cases hc : n1.role = .Candidate ∧ g = true
    · rw [if_pos (by simp [hc.1, hc.2])] at h
      rw [set_q _ _ i _ hpv, pure_bind] at h
      have hpv' : Pre { n1 with votes := n1.votes.set i.val true i.isLt } :=
        { hp1 with layout := hp1.layout, contig := hp1.contig, uniq := hp1.uniq }
      obtain ⟨b, hq, hbq⟩ := election_quorum_eq' { n1 with votes := n1.votes.set i.val true i.isLt } hMAX
      rw [hq, pure_bind] at h
      cases b
      · rw [if_neg (by decide)] at h
        obtain rfl := (congrArg Prod.snd (Rust.pure_inj h))
        exact SteppedD.voted t g n1 _ i hI rfl hO hT
          (Or.inr ⟨hc.1, hc.2, Or.inl ⟨fun hQ => by simpa using hbq.mpr hQ, rfl⟩⟩)
      · rw [if_pos rfl] at h
        obtain ⟨m, hm, h⟩ := Rust.bind_eq_pure h
        obtain rfl := (congrArg Prod.snd (Rust.pure_inj h))
        exact SteppedD.voted t g n1 _ i hI rfl hO hT
          (Or.inr ⟨hc.1, hc.2, Or.inr ⟨hbq.mp rfl, become_leader_rel' _ _ hpv' hm⟩⟩)
    · rw [if_neg (by simpa using hc)] at h
      obtain rfl := (congrArg Prod.snd (Rust.pure_inj h))
      exact SteppedD.voted t g n1 n1 i hI rfl hO hT (Or.inl ⟨hc, rfl⟩)
  -- Append
  · obtain ⟨n2, hfo, hFol, hp2, hb2, hrf2⟩ := follow_some' n1 hp1 hb1 src
    rw [hfo, pure_bind] at h
    obtain ⟨⟨⟨idx, rj⟩, n3⟩, hx, h⟩ := Rust.bind_eq_pure h
    have hAD := append_rel' n2 hp2 prev entry commit hb2.1 hb2.2 (valid_append t prev entry commit hv) _ _ hx
    obtain ⟨-, -, hrf3⟩ := appendD_facts _ _ _ _ _ _ hp2 hb2 hAD
    dsimp only at h
    rw [reply_q n3 a peer src _ _ hMAX hPO (hrf3.trans (hrf2.trans hrf1)), pure_bind] at h
    obtain rfl := (congrArg Prod.snd (Rust.pure_inj h))
    exact SteppedD.append t prev entry commit n1 n2 n3 (idx, rj) hI hO hT hFol hAD
  -- AppendBatch
  · obtain ⟨n2, hfo, hFol, hp2, hb2, hrf2⟩ := follow_some' n1 hp1 hb1 src
    rw [hfo, pure_bind] at h
    obtain ⟨out, hloop, h⟩ := Rust.bind_eq_pure h
    obtain ⟨-, -, hrfo, hB, -⟩ := batch_loop commit _ n2 prev false (prev.index, none) out hp2 hb2
      (valid_batch t prev entries commit hv) (fun h => by cases h) hloop
    rw [reply_q out.1 a peer src _ _ hMAX hPO (hrfo.trans (hrf2.trans hrf1)), pure_bind] at h
    obtain rfl := (congrArg Prod.snd (Rust.pure_inj h))
    exact SteppedD.appendBatch t prev entries commit n1 n2 out.1 out.2.2.2 hI hO hT hFol (hB rfl rfl)
  -- Install
  · obtain ⟨n2, hfo, hFol, hp2, hb2, hrf2⟩ := follow_some' n1 hp1 hb1 src
    rw [hfo, pure_bind] at h
    have hrf : n2.request_from = some src := hrf2.trans hrf1
    by_cases c1 : snap.last.index.val ≤ n2.state.hard.commit.val ∧
        Rust.Option.is_some_and (State.id_at n2.state snap.last.index) (fun id => id != snap.last) = true
    · rw [if_pos (by simp only [Bool.and_eq_true, decide_eq_true_eq, Fin.le_def]; exact c1)] at h
      rw [reply_q n2 a peer src _ _ hMAX hPO hrf, pure_bind] at h
      obtain rfl := (congrArg Prod.snd (Rust.pure_inj h))
      exact SteppedD.install t snap n1 n2 n2 _ hI hO hT hFol (Or.inl ⟨c1.1, c1.2, rfl, rfl⟩)
    · rw [if_neg (by simp only [Bool.and_eq_true, decide_eq_true_eq, Fin.le_def]; exact c1)] at h
      by_cases c2 : n2.state.base.index.val < snap.last.index.val ∧
          (n2.state.hard.commit.val < snap.last.index.val ∨ idAt n2.state snap.last.index.val = some snap.last)
      · rw [if_pos (by rw [id_at_eq _ hp2.layout]; simpa [Fin.lt_def] using c2)] at h
        obtain ⟨s', hins, hsn, hhard, hr, hl'⟩ := install_spec n2.state snap hp2.cap_lt hp2.layout hp2.contig
        have hc' := install_contig n2.state s' _ hp2.layout hp2.contig hsn hr
        by_cases c3 : (State.id_at n2.state snap.last.index != some snap.last) = true
        · rw [if_pos c3] at h
          obtain ⟨sc, hsc, h⟩ := Rust.bind_eq_pure h
          rw [Rust.LawfulClone.clone_eq _ _ hsc, hins, pure_bind] at h
          obtain ⟨n4, hn4, h⟩ := Rust.bind_eq_pure h
          have hR := refresh_rel { n2 with state := s', log_from := Rust.checked_add snap.last.index 1 } n4
            hp2.hooks hl' hc' hMAX hp2.e0 hp2.e1 hp2.uniq hn4
          obtain ⟨-, -, -, hrf4, -⟩ := refresh_facts _ _ hR
          rw [reply_q { n4 with snapshot_changed := true, dirty := true } a peer src _ _ hMAX hPO (hrf4.trans hrf), pure_bind] at h
          obtain rfl := (congrArg Prod.snd (Rust.pure_inj h))
          exact SteppedD.install t snap n1 n2 _ none hI hO hT hFol
            (Or.inr ⟨c1, rfl, Or.inr ⟨c2.1, c2.2, s', _, n4, hins, hR, rfl⟩⟩)
        · rw [if_neg c3] at h
          obtain ⟨sc, hsc, h⟩ := Rust.bind_eq_pure h
          rw [Rust.LawfulClone.clone_eq _ _ hsc, hins, pure_bind] at h
          obtain ⟨n4, hn4, h⟩ := Rust.bind_eq_pure h
          have hR := refresh_rel { n2 with state := s' } n4
            hp2.hooks hl' hc' hMAX hp2.e0 hp2.e1 hp2.uniq hn4
          obtain ⟨-, -, -, hrf4, -⟩ := refresh_facts _ _ hR
          rw [reply_q { n4 with snapshot_changed := true, dirty := true } a peer src _ _ hMAX hPO (hrf4.trans hrf), pure_bind] at h
          obtain rfl := (congrArg Prod.snd (Rust.pure_inj h))
          exact SteppedD.install t snap n1 n2 _ none hI hO hT hFol
            (Or.inr ⟨c1, rfl, Or.inr ⟨c2.1, c2.2, s', n2.log_from, n4, hins, hR, rfl⟩⟩)
      · rw [if_neg (by rw [id_at_eq _ hp2.layout]; simpa [Fin.lt_def] using c2)] at h
        rw [reply_q n2 a peer src _ _ hMAX hPO hrf, pure_bind] at h
        obtain rfl := (congrArg Prod.snd (Rust.pure_inj h))
        exact SteppedD.install t snap n1 n2 n2 none hI hO hT hFol (Or.inr ⟨c1, rfl, Or.inl ⟨c2, rfl⟩⟩)
  -- Replicated
  · obtain ⟨i, rfl⟩ : ∃ i, a = some i := by
      cases a with
      | none => exact (hns rfl).elim
      | some i => exact ⟨i, rfl⟩
    have hpv : peer = Rust.ofNat i.val := Fin.ext (by
      rw [show peer.val = i.val from hPO]; simp [Rust.ofNat]; uomega)
    subst hpv
    by_cases hl : n1.role = .Leader
    · rw [if_pos (by simp [hl])] at h
      obtain ⟨m, hm, h⟩ := Rust.bind_eq_pure h
      obtain rfl := (congrArg Prod.snd (Rust.pure_inj h))
      exact SteppedD.replicated t index rej n1 _ i hI rfl hO hT (Or.inr ⟨hl, replicated_rel' n1 hp1 i index rej _ hm⟩)
    · rw [if_neg (by simpa using hl)] at h
      obtain rfl := (congrArg Prod.snd (Rust.pure_inj h))
      exact SteppedD.replicated t index rej n1 _ i hI rfl hO hT (Or.inl ⟨hl, rfl⟩)

end Jarl.Engine.Dyn
