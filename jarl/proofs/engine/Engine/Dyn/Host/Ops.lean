import Engine.Host.Refine
import Engine.Dyn.Safety

/-!
# Dirty tracking of every dynamic operation

The dynamic counterpart of `Engine/Host/Ops.lean`. For each public operation
of a `Cluster` other than persistence and restart (`COp`): either the node is
unchanged, or it started clean and its result `Agrees` with its starting
checkpoint under its own `log_from` and `snapshot_changed` (`OpOk`).
`refresh_membership` keeps the log and the tracking (`dh_same_refresh`).

Derived from the operation relations of `Engine/Dyn/Spec.lean`, except
`Install`, which is re-derived from the generated `step` because `SteppedD`
leaves the `log_from` it sets existential.
-/

set_option linter.unusedSectionVars false

namespace Jarl.Engine.DynHost
open Jarl Jarl.Engine Jarl.Engine.Host Jarl.Engine.Dyn Jarl.Contracts.StorageView

variable {V S : Type} {MAX CAP : Nat} [Rust.Clone V] [Rust.Clone S]

/-- An operation's effect on a node: none, or from a clean node to one that
    agrees with the starting checkpoint under its own dirty tracking. -/
def OpOk (n n' : DNode V S MAX CAP) : Prop := n' = n ∨ (n.dirty = false ∧ AgreesN n.state n')

/-! ## Updates that keep the log and the tracking -/

theorem dh_same_timers_of {N : Nat} {V' S' : Type} {n m n' : Node V' S' N CAP} (hT : Timers m n')
    (h1 : m.state.snapshot = n.state.snapshot) (h2 : ret m.state = ret n.state) (h3 : m.log_from = n.log_from)
    (h4 : m.snapshot_changed = n.snapshot_changed) : Same n n' := by
  obtain ⟨r, d, rfl⟩ := hT
  exact ⟨h1, h2, h3, h4⟩

/-- `refresh_membership` keeps the log and the tracking. -/
theorem dh_same_refresh {n n' : DNode V S MAX CAP} (h : Refresh n n') : Same n n' := by
  obtain ⟨n1, ⟨hs, -, -⟩, -, hn⟩ := h
  have e : Same n n1 := ⟨by rw [hs], by rw [hs], by rw [hs], by rw [hs]⟩
  rcases hn with rfl | ⟨-, -, -, ⟨r, d, rfl⟩⟩
  · exact e
  · exact e

theorem dh_same_commit {n n' : DNode V S MAX CAP} {i : Rust.u64} (h : CommitTo n i n') : Same n n' := by
  rcases h with ⟨-, hr⟩ | ⟨-, rfl⟩
  · exact (same_commitTo n i).trans (dh_same_refresh hr)
  · exact Same.refl _

theorem dh_same_adv {n n' : DNode V S MAX CAP} (h : Adv' n n') : Same n n' := by
  rcases h with rfl | ⟨v, -, -, -, hc⟩
  · exact Same.refl _
  · exact dh_same_commit hc

theorem dh_same_time {n n' : DNode V S MAX CAP} (h : TimeOnlyD n n') : Same n n' := by
  obtain ⟨e, a, q, act, rfl⟩ := h
  exact ⟨rfl, rfl, rfl, rfl⟩

theorem dh_same_observed {n n1 : DNode V S MAX CAP} {src : Id} {t : Rust.u64} (h : ObservedD n src t n1) :
    Same n n1 := by
  rcases h with ⟨-, rfl⟩ | ⟨-, r, d, rfl⟩
  · exact ⟨rfl, rfl, rfl, rfl⟩
  · exact ⟨rfl, rfl, rfl, rfl⟩

theorem dh_same_following {n n2 : DNode V S MAX CAP} {src : Id} (h : FollowingD n src n2) : Same n n2 := by
  obtain ⟨r, d, rfl⟩ := h
  exact ⟨rfl, rfl, rfl, rfl⟩

theorem dh_same_queue (n : DNode V S MAX CAP) (a : Option (Fin MAX)) (src : Id) (o : Outbound) :
    Same n (queueD n a src o) := by
  cases a <;> exact ⟨rfl, rfl, rfl, rfl⟩

theorem dh_same_recorded {n m : DNode V S MAX CAP} {p : Fin MAX} {index : Rust.u64} {rej : Option Rejection}
    (h : RecordedD n m p index rej) : Same n m := by
  obtain ⟨act, nx, rfl | ⟨-, -, -, rfl⟩⟩ := h
  · exact ⟨rfl, rfl, rfl, rfl⟩
  · exact ⟨rfl, rfl, rfl, rfl⟩

theorem dh_same_replicated {n n' : DNode V S MAX CAP} {p : Fin MAX} {index : Rust.u64} {rej : Option Rejection}
    (h : ReplicatedD n p index rej n') : Same n n' := by
  obtain ⟨m, m', hR, hA, hn, -⟩ := h
  have h2 : Same m' n' := by rw [hn]; exact ⟨rfl, rfl, rfl, rfl⟩
  exact ((dh_same_recorded hR).trans (dh_same_adv hA)).trans h2

/-- `send` only queues a descriptor. -/
theorem dh_send_same {N : Nat} {V' S' : Type} [Rust.Clone V'] [Rust.Clone S'] (n n' : Node V' S' N CAP)
    (p : Rust.usize) (o : Outbound) (h : Node.send n p o = pure n') : Same n n' := by
  unfold Node.send at h
  split at h
  · dsimp only at h
    split at h
    · cases Rust.pure_inj h; exact ⟨rfl, rfl, rfl, rfl⟩
    · cases Rust.pure_inj h; exact ⟨rfl, rfl, rfl, rfl⟩
  · obtain ⟨t, -, h⟩ := Rust.bind_eq_pure h
    cases Rust.pure_inj h; exact ⟨rfl, rfl, rfl, rfl⟩

theorem dh_reply_same {N : Nat} {V' S' : Type} [Rust.Clone V'] [Rust.Clone S'] (n n' : Node V' S' N CAP)
    (p : Rust.usize) (i : Rust.u64) (rj : Option Rejection) (h : Node.reply n p i rj = pure n') : Same n n' := by
  unfold Node.reply at h
  obtain ⟨m, hm, h⟩ := Rust.bind_eq_pure h
  cases Rust.pure_inj h
  exact dh_send_same _ _ _ _ hm

/-! ## Appending, leadership and campaigns -/

/-- `barrier` after a fully agreeing node: its no-op entry starts the cut. -/
theorem dh_agrees_barrier (s₀ : DState V S MAX CAP) (m m' : DNode V S MAX CAP)
    (hm : Agrees s₀ m.state m.snapshot_changed none) (hcm : Contig m.state) (hb : BarrierD m m') :
    AgreesN s₀ m' := by
  rcases hb with rfl | ⟨s', idx, hidx, -, hr, -, hsn, -, -, hA⟩
  · exact agrees_weaken _ _ _ hm _
  · apply agreesN_same s₀ _ _ _ (dh_same_adv hA)
    show Agrees s₀ s' m.snapshot_changed (some idx)
    refine agrees_prefix s₀ m.state s' _ none hm hsn (ret m.state).length (by rw [hr]; simp) idx ?_ (by simp)
    have := lastId_eq m.state hcm
    omega

theorem dh_agrees_become (s₀ : DState V S MAX CAP) (m m' : DNode V S MAX CAP)
    (hm : Agrees s₀ m.state m.snapshot_changed none) (hcm : Contig m.state) (hb : BecomeLeaderD m m') :
    AgreesN s₀ m' := by
  obtain ⟨n2, hB, rfl⟩ := hb
  exact agreesN_same s₀ _ _ (dh_agrees_barrier s₀ (leaderInitD m) n2 hm hcm hB) ⟨rfl, rfl, rfl, rfl⟩

/-- A campaign from a node with the checkpoint's log. -/
theorem dh_agrees_campaign (s₀ : DState V S MAX CAP) (n0 n' : DNode V S MAX CAP) (t : Rust.u64)
    (hsn : n0.state.snapshot = s₀.snapshot) (hr : ret n0.state = ret s₀) (hc : Contig n0.state)
    (hC : CampaignD n0 t n') : AgreesN s₀ n' := by
  obtain ⟨h, n1, hT, hcase⟩ := hC
  have hS : Same n0 n1 := dh_same_timers_of hT rfl rfl rfl rfl
  have hfull : Agrees s₀ n1.state n1.snapshot_changed none :=
    agrees_of_log _ _ (hS.1.trans hsn) (hS.2.1.trans hr) _ _
  have hc1 : Contig n1.state := contig_congr _ _ hS.1 hS.2.1 hc
  rcases hcase with ⟨-, hB⟩ | ⟨-, rfl⟩
  · exact dh_agrees_become s₀ n1 n' hfull hc1 hB
  · exact agreesN_same s₀ _ _ (agrees_weaken _ _ _ hfull _) ⟨rfl, rfl, rfl, rfl⟩

/-- `append` keeps any agreement: it truncates at most to the entry's index and cuts there. -/
theorem dh_agrees_append (s₀ : DState V S MAX CAP) (n n' : DNode V S MAX CAP) (prev : LogId)
    (entry : Option (DEntry V MAX)) (commit : Rust.u64) (r : Rust.u64 × Option Rejection)
    (ha : AgreesN s₀ n) (h : AppendD n prev entry commit r n') : AgreesN s₀ n' := by
  rcases h with ⟨-, -, -, rfl⟩ | ⟨-, -, -, hc⟩ | ⟨e, -, -, -, -, hc⟩ | ⟨e, -, -, -, -, -, rfl⟩ |
      ⟨e, -, -, -, -, hc⟩ | ⟨e, s', n1, -, -, -, -, hrep, -, hR, hc⟩
  · exact ha
  · exact agreesN_same _ _ _ ha (dh_same_commit hc)
  · exact agreesN_same _ _ _ ha (dh_same_commit hc)
  · exact ha
  · exact agreesN_same _ _ _ ha (dh_same_commit hc)
  apply agreesN_same _ _ _ _ (dh_same_commit hc)
  have hS1 := dh_same_refresh hR
  obtain ⟨hr', -, hsn', -, hc'⟩ := hrep
  have hbase' : s'.base = n.state.base := by simp [State.base, hsn']
  have hlen : e.id.index.val - n.state.base.index.val - 1 ≤ (ret n.state).length := by
    have hp : ((ret n.state).take (e.id.index.val - n.state.base.index.val - 1)).length < (ret s').length := by
      rw [hr']; simp
    have h1 := hc' _ hp
    rw [List.getElem_of_eq hr' hp, List.getElem_concat_length (by rfl), hbase'] at h1
    simp only [List.length_take] at h1
    omega
  have key : Agrees s₀ s' n.snapshot_changed
      (some (Rust.Option.map_or n.log_from e.id.index (fun f => Rust.min f e.id.index))) := by
    refine agrees_prefix s₀ n.state s' _ n.log_from ha hsn' (e.id.index.val - n.state.base.index.val - 1) ?_ _ ?_ ?_
    · rw [hr', List.take_append_of_le_length (by simp; omega), List.take_take, Nat.min_self]
    · cases n.log_from with
      | none => simp only [Rust.Option.map_or]; omega
      | some f =>
        simp only [Rust.Option.map_or, Rust.val_min, Nat.min_def]
        split <;> omega
    · intro c₀ hc₀
      rw [hc₀]
      simp only [Rust.Option.map_or, Rust.val_min]
      exact Nat.min_le_left _ _
  show Agrees s₀ n1.state n1.snapshot_changed
    (some (Rust.Option.map_or n1.log_from e.id.index (fun f => Rust.min f e.id.index)))
  rw [hS1.2.2.1, hS1.2.2.2]
  exact agrees_congr _ _ _ _ _ key hS1.1 hS1.2.1

theorem dh_agrees_batchAfter (s₀ : DState V S MAX CAP) {n : DNode V S MAX CAP} {p : LogId} {L : List (DEntry V MAX)}
    {commit last : Rust.u64} {resp : Rust.u64 × Option Rejection} {n' : DNode V S MAX CAP}
    (h : BatchAfterD n p L commit last resp n') : AgreesN s₀ n → AgreesN s₀ n' := by
  induction h with
  | nil => exact id
  | reject =>
    rename_i hA _
    exact fun ha => dh_agrees_append s₀ _ _ _ _ _ _ ha hA
  | accept =>
    rename_i hA _ _ ih
    exact fun ha => ih (dh_agrees_append s₀ _ _ _ _ _ _ ha hA)

theorem dh_agrees_batch (s₀ : DState V S MAX CAP) {n : DNode V S MAX CAP} {p : LogId} {L : List (DEntry V MAX)}
    {commit : Rust.u64} {resp : Rust.u64 × Option Rejection} {n' : DNode V S MAX CAP}
    (h : BatchD n p L commit resp n') (ha : AgreesN s₀ n) : AgreesN s₀ n' := by
  cases h with
  | nil => exact ha
  | reject => exact dh_agrees_append s₀ _ _ _ _ _ _ ha ‹AppendD _ _ _ _ _ _›
  | accept =>
    exact dh_agrees_batchAfter s₀ ‹BatchAfterD _ _ _ _ _ _ _› (dh_agrees_append s₀ _ _ _ _ _ _ ha ‹AppendD _ _ _ _ _ _›)

/-! ## `tick` -/

theorem dh_tick (n n' : DNode V S MAX CAP) (hc : Contig n.state) (h : TickedD n n') : OpOk n n' := by
  cases h with
  | same => exact Or.inl rfl
  | time _ hI hT => exact Or.inr ⟨hI.1, agreesN_of_same _ _ (dh_same_time hT)⟩
  | stepdown n0 _ hI _ hT hT2 =>
    exact Or.inr ⟨hI.1, agreesN_of_same _ _ ((dh_same_time hT).trans (dh_same_timers_of hT2 rfl rfl rfl rfl))⟩
  | heartbeat n0 n2 hI _ hT hB =>
    have hS := dh_same_time hT
    refine Or.inr ⟨hI.1, agreesN_same _ _ _ ?_ ⟨rfl, rfl, rfl, rfl⟩⟩
    exact dh_agrees_barrier _ n0 n2 (full_of_same _ _ hS) (contig_congr _ _ hS.1 hS.2.1 hc) hB
  | prevote n0 n2 _ h0 ht hI _ _ hT hT2 hcase =>
    have hS : Same n n2 := (dh_same_time hT).trans (dh_same_timers_of hT2 rfl rfl rfl rfl)
    refine Or.inr ⟨hI.1, ?_⟩
    rcases hcase with ⟨-, hC⟩ | ⟨-, rfl⟩
    · exact dh_agrees_campaign _ n2 _ _ hS.1 hS.2.1 (contig_congr _ _ hS.1 hS.2.1 hc) hC
    · exact agreesN_of_same _ _ (hS.trans ⟨rfl, rfl, rfl, rfl⟩)

/-! ## `step` -/

/-- `Install` from the generated code of `step`: the stale, conflicting and old
    branches keep the log; installing a matching snapshot keeps the suffix after
    it; installing a conflicting one empties the log and cuts just past the new
    boundary. -/
theorem dh_step_install [Rust.LawfulClone S] (n : DNode V S MAX CAP) (hp : Pre n) (hb : Bnd n)
    (src dst : Id) (t : Rust.u64) (snap : Snapshot (Checkpoint S MAX)) (r : Rust.Result Unit Error)
    (n' : DNode V S MAX CAP) (h : Node.step n ⟨src, dst, .Install t snap⟩ = pure (r, n')) : OpOk n n' := by
  have hMAX := hp.n_lt
  unfold Node.step at h
  cases hA : Node.available n
  case Err e =>
    simp only [hA] at h
    exact Or.inl (congrArg Prod.snd (Rust.pure_inj h)).symm
  rename_i u
  have hI := idle_of_available n (by cases u; exact hA)
  have hk : n.hooks.isSome = true := by rw [hp.hooks]; rfl
  simp only [hA, hk, Bool.true_and, pure_bind] at h
  split at h
  rotate_left
  · exact Or.inl (congrArg Prod.snd (Rust.pure_inj h)).symm
  rename_i peer hpeer
  clear hpeer
  by_cases hc : (!(src == n.config.id || dst != n.config.id)) = true
  rotate_left
  · rw [if_neg hc] at h
    exact Or.inl (congrArg Prod.snd (Rust.pure_inj h)).symm
  rw [if_pos hc] at h
  obtain ⟨v, -, h⟩ := Rust.bind_eq_pure h
  cases v
  · exact Or.inl (congrArg Prod.snd (Rust.pure_inj h)).symm
  simp only [Bool.not_true, Bool.false_eq_true, if_false] at h
  dsimp only [Message.term] at h
  simp only [Bool.false_and, Bool.false_eq_true, ↓reduceIte] at h
  obtain ⟨n1, hO, hp1, hb1, -, -, h⟩ := observe_split' n hp hb src t _ _ h
  refine Or.inr ⟨hI.1, ?_⟩
  have hS1 : Same n n1 := dh_same_observed hO
  -- The final reply only queues a descriptor.
  have reply : ∀ (m : DNode V S MAX CAP) (i : Rust.u64) (rj : Option Rejection),
      AgreesN n.state m → (Node.reply m peer i rj >>= fun m' => pure (Rust.Result.Ok (), m')) = pure (r, n') →
      AgreesN n.state n' := by
    intro m i rj ha hr
    obtain ⟨m', hm', hr⟩ := Rust.bind_eq_pure hr
    obtain rfl := congrArg Prod.snd (Rust.pure_inj hr)
    exact agreesN_same _ _ _ ha (dh_reply_same _ _ _ _ _ hm')
  by_cases hs : t.val < n1.state.hard.term.val
  · have hd : t < n1.state.hard.term := Fin.lt_def.mpr hs
    simp only [hd, decide_true, if_true] at h
    exact reply n1 _ _ (agreesN_of_same _ _ hS1) h
  have hd : ¬ t < n1.state.hard.term := fun e => hs (Fin.lt_def.mp e)
  simp only [hd, decide_false, Bool.false_eq_true, if_false] at h
  obtain ⟨n2, hfo, hFol, hp2, -, -⟩ := follow_some' n1 hp1 hb1 src
  rw [hfo, pure_bind] at h
  have hS2 : Same n n2 := hS1.trans (dh_same_following hFol)
  by_cases c1 : snap.last.index.val ≤ n2.state.hard.commit.val ∧
      Rust.Option.is_some_and (State.id_at n2.state snap.last.index) (fun id => id != snap.last) = true
  · rw [if_pos (by simp only [Bool.and_eq_true, decide_eq_true_eq, Fin.le_def]; exact c1)] at h
    exact reply n2 _ _ (agreesN_of_same _ _ hS2) h
  rw [if_neg (by simp only [Bool.and_eq_true, decide_eq_true_eq, Fin.le_def]; exact c1)] at h
  by_cases c2 : n2.state.base.index.val < snap.last.index.val ∧
      (n2.state.hard.commit.val < snap.last.index.val ∨ idAt n2.state snap.last.index.val = some snap.last)
  · rw [if_pos (by rw [id_at_eq _ hp2.layout]; simpa [Fin.lt_def] using c2)] at h
    obtain ⟨s', hins, hsn, -, hr, hl'⟩ := install_spec n2.state snap hp2.cap_lt hp2.layout hp2.contig
    have hc' := install_contig n2.state s' _ hp2.layout hp2.contig hsn hr
    by_cases c3 : (State.id_at n2.state snap.last.index != some snap.last) = true
    · rw [if_pos c3] at h
      obtain ⟨sc, hsc, h⟩ := Rust.bind_eq_pure h
      rw [Rust.LawfulClone.clone_eq _ _ hsc, hins, pure_bind] at h
      obtain ⟨n4, hn4, h⟩ := Rust.bind_eq_pure h
      have hR := refresh_rel { n2 with state := s', log_from := Rust.checked_add snap.last.index 1 } n4
        hp2.hooks hl' hc' hMAX hp2.e0 hp2.e1 hp2.uniq hn4
      have hR4 := dh_same_refresh hR
      have hm : idAt n2.state snap.last.index.val ≠ some snap.last := by
        rw [← id_at_eq _ hp2.layout]; simpa using c3
      rw [if_neg hm] at hr
      refine reply { n4 with snapshot_changed := true, dirty := true } _ _ ?_ h
      show Agrees n.state n4.state true n4.log_from
      rw [hR4.2.2.1]
      exact agrees_congr _ _ _ _ _ (agrees_install_reset n.state s' hp.contig snap hsn hr) hR4.1 hR4.2.1
    · rw [if_neg c3] at h
      obtain ⟨sc, hsc, h⟩ := Rust.bind_eq_pure h
      rw [Rust.LawfulClone.clone_eq _ _ hsc, hins, pure_bind] at h
      obtain ⟨n4, hn4, h⟩ := Rust.bind_eq_pure h
      have hR := refresh_rel { n2 with state := s' } n4 hp2.hooks hl' hc' hMAX hp2.e0 hp2.e1 hp2.uniq hn4
      have hR4 := dh_same_refresh hR
      have hm : idAt n2.state snap.last.index.val = some snap.last := by
        rw [← id_at_eq _ hp2.layout]; simpa using c3
      rw [if_pos hm] at hr
      obtain ⟨hle', -⟩ := idAt_some n2.state hp2.layout hp2.contig _ hm
      refine reply { n4 with snapshot_changed := true, dirty := true } _ _ ?_ h
      show Agrees n.state n4.state true n4.log_from
      exact agrees_congr _ _ _ _ _ (agrees_weaken _ _ _ (agrees_install_keep n.state n2.state s'
        n2.snapshot_changed (full_of_same _ _ hS2) snap hsn hle' hr) _) hR4.1 hR4.2.1
  · rw [if_neg (by rw [id_at_eq _ hp2.layout]; simpa [Fin.lt_def] using c2)] at h
    exact reply n2 _ _ (agreesN_of_same _ _ hS2) h

theorem dh_step [Rust.LawfulClone V] [Rust.LawfulClone S] (n : DNode V S MAX CAP) (hp : Pre n) (hb : Bnd n)
    (env : DEnv V S MAX) (r : Rust.Result Unit Error) (n' : DNode V S MAX CAP)
    (h : Node.step n env = pure (r, n')) : OpOk n n' := by
  rcases env with ⟨src, dst, msg⟩
  by_cases hins : ∃ t snap, msg = .Install t snap
  · obtain ⟨t, snap, rfl⟩ := hins
    exact dh_step_install n hp hb src dst t snap r n' h
  obtain ⟨a, -, -, hst, -⟩ := step_rel' n hp hb.1 hb.2 _ r n' h
  simp only at hst
  have hq : ∀ (m : DNode V S MAX CAP) (o : Outbound), Same n m → Same n (queueD m a src o) :=
    fun m o hm => hm.trans (dh_same_queue _ _ _ _)
  have hreq : Same n { n with request_from := some src } := ⟨rfl, rfl, rfl, rfl⟩
  cases hst with
  | same => exact Or.inl rfl
  | ignored _ hI => exact Or.inr ⟨hI.1, agreesN_of_same _ _ hreq⟩
  | prevote t last g hI => exact Or.inr ⟨hI.1, agreesN_of_same _ _ (hq _ _ hreq)⟩
  | prevoted t c g n1 _ i hI _ hO hcase =>
    have hS := dh_same_observed hO
    refine Or.inr ⟨hI.1, ?_⟩
    rcases hcase with ⟨-, rfl⟩ | ⟨-, -, ⟨-, rfl⟩ | ⟨-, hC⟩⟩
    · exact agreesN_of_same _ _ hS
    · exact agreesN_of_same _ _ (hS.trans ⟨rfl, rfl, rfl, rfl⟩)
    · have hSv : Same n { n1 with votes := n1.votes.set i.val true i.isLt } := hS.trans ⟨rfl, rfl, rfl, rfl⟩
      exact dh_agrees_campaign _ _ _ c hSv.1 hSv.2.1 (contig_congr _ _ hSv.1 hSv.2.1 hp.contig) hC
  | stale _ n1 _ hI hO _ hn =>
    have hS := dh_same_observed hO
    refine Or.inr ⟨hI.1, agreesN_of_same _ _ ?_⟩
    rcases hn with rfl | rfl | ⟨i, rfl⟩
    · exact hS
    · exact hq _ _ hS
    · exact hq _ _ hS
  | vote t last n1 n2 g hI hO _ _ h1 h2 =>
    have hS := dh_same_observed hO
    have h12 : Same n1 n2 := by
      cases g
      · rw [h1 rfl]; exact Same.refl _
      · exact dh_same_timers_of (h2 rfl) rfl rfl rfl rfl
    exact Or.inr ⟨hI.1, agreesN_of_same _ _ (hq _ _ (hS.trans h12))⟩
  | voted t g n1 _ i hI _ hO _ hc =>
    have hS := dh_same_observed hO
    refine Or.inr ⟨hI.1, ?_⟩
    rcases hc with ⟨-, rfl⟩ | ⟨-, -, ⟨-, rfl⟩ | ⟨-, hB⟩⟩
    · exact agreesN_of_same _ _ hS
    · exact agreesN_of_same _ _ (hS.trans ⟨rfl, rfl, rfl, rfl⟩)
    · have hSv : Same n { n1 with votes := n1.votes.set i.val true i.isLt } := hS.trans ⟨rfl, rfl, rfl, rfl⟩
      exact dh_agrees_become _ _ _ (full_of_same _ _ hSv) (contig_congr _ _ hSv.1 hSv.2.1 hp.contig) hB
  | append t prev entry commit n1 n2 n3 rr hI hO _ hFol hx =>
    have hS2 := (dh_same_observed hO).trans (dh_same_following hFol)
    refine Or.inr ⟨hI.1, agreesN_same _ _ _ ?_ (dh_same_queue _ _ _ _)⟩
    exact dh_agrees_append _ _ _ _ _ _ _ (agreesN_of_same _ _ hS2) hx
  | appendBatch t prev entries commit n1 n2 n3 resp hI hO _ hFol hB =>
    have hS2 := (dh_same_observed hO).trans (dh_same_following hFol)
    refine Or.inr ⟨hI.1, agreesN_same _ _ _ ?_ (dh_same_queue _ _ _ _)⟩
    exact dh_agrees_batch _ hB (agreesN_of_same _ _ hS2)
  | install t snap => exact absurd ⟨t, snap, rfl⟩ hins
  | replicated t index rej n1 _ i hI _ hO _ hc =>
    have hS := dh_same_observed hO
    refine Or.inr ⟨hI.1, ?_⟩
    rcases hc with ⟨-, rfl⟩ | ⟨-, hr⟩
    · exact agreesN_of_same _ _ hS
    · exact agreesN_of_same _ _ (hS.trans (dh_same_replicated hr))

/-! ## `next_message`, proposals, compaction and membership changes -/

/-- `next_message` only drops a descriptor, and sends only from a clean node. -/
theorem dh_next (n n' : DNode V S MAX CAP) (r : Option (DEnv V S MAX)) (h : NextD n r n') :
    OpOk n n' ∧ (r.isSome = true → n.dirty = false) := by
  rcases h with ⟨rfl, rfl | ⟨hd, -, rfl⟩ | ⟨hd, k, to, -, -, -, rfl, -⟩⟩ |
      ⟨env, -, hd, -, ⟨k, o, to, -, -, -, -, rfl, -⟩ | ⟨o, to, -, -, -, rfl, -⟩⟩
  · exact ⟨Or.inl rfl, by simp⟩
  · exact ⟨Or.inr ⟨hd, agreesN_of_same _ _ ⟨rfl, rfl, rfl, rfl⟩⟩, by simp⟩
  · exact ⟨Or.inr ⟨hd, agreesN_of_same _ _ ⟨rfl, rfl, rfl, rfl⟩⟩, by simp⟩
  · exact ⟨Or.inr ⟨hd, agreesN_of_same _ _ ⟨rfl, rfl, rfl, rfl⟩⟩, fun _ => hd⟩
  · exact ⟨Or.inr ⟨hd, agreesN_of_same _ _ ⟨rfl, rfl, rfl, rfl⟩⟩, fun _ => hd⟩

theorem dh_propose (n n' : DNode V S MAX CAP) (vs : List (Record V MAX)) (hc : Contig n.state)
    (h : ProposeD n vs n') : OpOk n n' := by
  rcases h with rfl | ⟨hI, -, hpos, hfit, s', n1, n2, hr, -, hs, -, -, hR, hA, rfl⟩
  · exact Or.inl rfl
  refine Or.inr ⟨hI.1, agreesN_same _ _ _ ?_ ⟨rfl, rfl, rfl, rfl⟩⟩
  apply agreesN_same _ _ _ _ (dh_same_adv hA)
  have hS1 := dh_same_refresh hR
  have key : Agrees n.state s' n.snapshot_changed (some (Rust.ofNat ((lastId n.state).index.val + 1))) := by
    refine agrees_prefix n.state n.state s' _ none (agrees_of_log _ _ rfl rfl _ _) hs (ret n.state).length
      (by rw [hr]; simp) _ ?_ (by simp)
    have := lastId_eq n.state hc
    simp only [Rust.ofNat]
    rw [Nat.mod_eq_of_lt (by omega)]
    omega
  show Agrees n.state n1.state n1.snapshot_changed n1.log_from
  rw [hS1.2.2.1, hS1.2.2.2]
  exact agrees_congr _ _ _ _ _ key hS1.1 hS1.2.1

theorem dh_compact (n n' : DNode V S MAX CAP) (index : Rust.u64) (value : Unit → Rust.M (Checkpoint S MAX))
    (hp : Pre n) (h : CompactD n index value n') : OpOk n n' := by
  rcases h with rfl | ⟨hI, hlo, -, last, v, s', hid, -, hins, hcase⟩
  · exact Or.inl rfl
  refine Or.inr ⟨hI.1, ?_⟩
  obtain ⟨s'', hins', hsn, -, hr, -⟩ := install_spec n.state ⟨last, v⟩ hp.cap_lt hp.layout hp.contig
  rw [hins] at hins'
  cases Rust.pure_inj hins'
  have hlast : last.index.val = index.val := by
    have hid' := hid
    unfold idAt at hid'
    rw [if_neg (by omega), if_pos hlo] at hid'
    obtain ⟨e, he, rfl⟩ := Option.map_eq_some_iff.mp hid'
    obtain ⟨hj, rfl⟩ := List.getElem?_eq_some_iff.mp he
    have := hp.contig _ hj
    omega
  have hm : idAt n.state last.index.val = some last := by rw [hlast]; exact hid
  obtain ⟨hle, -⟩ := idAt_some n.state hp.layout hp.contig last hm
  have hc' := install_contig n.state s' _ hp.layout hp.contig hsn hr
  simp only [if_pos hm] at hr
  have hfull : Agrees n.state s' true none :=
    agrees_install_keep n.state n.state s' n.snapshot_changed (agrees_of_log _ _ rfl rfl _ _) _ hsn hle hr
  rcases hcase with ⟨-, rfl⟩ | ⟨-, n2, hB, rfl⟩
  · exact agrees_weaken _ _ _ hfull _
  · exact agreesN_same _ _ _ (dh_agrees_barrier _ _ n2 hfull hc' hB) ⟨rfl, rfl, rfl, rfl⟩

theorem dh_reconfig (n n' : DNode V S MAX CAP) (hc : Contig n.state) (h : ReconfigD n n') : OpOk n n' := by
  rcases h with rfl | ⟨X, hP, -⟩
  · exact Or.inl rfl
  · exact dh_propose n n' _ hc hP

/-! ## The operations of a `Cluster` -/

/-- The facts the operation relations need of a node. -/
structure NodeFacts (n : DNode V S MAX CAP) : Prop where
  pre : Pre n
  bnd : Bnd n
  mem : n.membership = memOf n.state n.bootstrap
  memOk : MemOk n.membership

/-- Every node of a reachable cluster has them. -/
theorem nodeFacts_of_inv {K : Nat} (ids : Vector Id K) (g : Membership MAX) (hg : MemOk g)
    (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (hi : Dyn.Inv ids g C G) (k : Fin K) :
    NodeFacts (C.node k) :=
  ⟨(hi.dyn k).pre, ⟨(hi.live k).1.commit_ge, (hi.live k).1.commit_le⟩,
    by rw [(hi.dyn k).bootstrap]; exact (hi.dyn k).membership, pp_memOk ids g hg C G hi k⟩

/-- They do not depend on the pending-save flags. -/
theorem nodeFacts_flags (n : DNode V S MAX CAP) (d : Bool) (lf : Option Rust.u64) (sc : Bool)
    (h : NodeFacts { n with dirty := d, log_from := lf, snapshot_changed := sc }) : NodeFacts n :=
  ⟨⟨h.pre.hooks, h.pre.layout, h.pre.contig, h.pre.n_lt, h.pre.cap_lt, h.pre.e0, h.pre.e1, h.pre.uniq⟩,
    h.bnd, h.mem, h.memOk⟩

/-- One public operation of a `Cluster` other than persistence and restart, on a
    node of a cluster whose network holds `sent`, possibly emitting a message. -/
inductive COp (sent : List (DEnv V S MAX)) (c : Jarl.Cluster V S MAX CAP) :
    Option (DEnv V S MAX) → Jarl.Cluster V S MAX CAP → Prop
  | tick (r : Rust.Result Unit Error) (c' : Jarl.Cluster V S MAX CAP) :
      Cluster.tick c = pure (r, c') → COp sent c none c'
  | deliver (env : DEnv V S MAX) (r : Rust.Result Unit Error) (c' : Jarl.Cluster V S MAX CAP) :
      env ∈ sent → Cluster.step c env = pure (r, c') → COp sent c none c'
  | propose (v : V) (r : Rust.Result LogId Error) (c' : Jarl.Cluster V S MAX CAP) :
      Cluster.propose c v = pure (r, c') → COp sent c none c'
  | proposeBatch (vs : Array V) (r : Rust.Result ProposalRange Error) (c' : Jarl.Cluster V S MAX CAP) :
      vs.size < 2 ^ Rust.usizeBits → Cluster.propose_batch c vs = pure (r, c') → COp sent c none c'
  | compact (index : Rust.u64) (app : S) (r : Rust.Result Unit Error) (c' : Jarl.Cluster V S MAX CAP) :
      Cluster.compact c index app = pure (r, c') → COp sent c none c'
  | setLearners (learners : Array Id) (r : Rust.Result LogId Error) (c' : Jarl.Cluster V S MAX CAP) :
      learners.size < 2 ^ Rust.usizeBits → Cluster.set_learners c learners = pure (r, c') → COp sent c none c'
  | reconfigure (target : Membership MAX) (r : Rust.Result LogId Error) (c' : Jarl.Cluster V S MAX CAP) :
      MemOk target → Cluster.reconfigure c target = pure (r, c') → COp sent c none c'
  | finish (r : Rust.Result LogId Error) (c' : Jarl.Cluster V S MAX CAP) :
      Cluster.finish_reconfiguration c = pure (r, c') → COp sent c none c'
  | send (env : DEnv V S MAX) (c' : Jarl.Cluster V S MAX CAP) :
      Cluster.next_message c = pure (some env, c') → COp sent c (some env) c'
  | drain (c' : Jarl.Cluster V S MAX CAP) :
      Cluster.next_message c = pure (none, c') → COp sent c none c'

theorem dh_cluster_tick (c c' : Jarl.Cluster V S MAX CAP) (r : Rust.Result Unit Error)
    (h : Cluster.tick c = pure (r, c')) : Node.tick c.node = pure (r, c'.node) := by
  unfold Cluster.tick at h
  obtain ⟨⟨r', m⟩, h1, h2⟩ := Rust.bind_eq_pure h
  have := Rust.pure_inj h2
  simp only [Prod.mk.injEq] at this
  obtain ⟨rfl, rfl⟩ := this
  exact h1

theorem dh_cluster_step (c c' : Jarl.Cluster V S MAX CAP) (env : DEnv V S MAX) (r : Rust.Result Unit Error)
    (h : Cluster.step c env = pure (r, c')) : Node.step c.node env = pure (r, c'.node) := by
  unfold Cluster.step at h
  obtain ⟨⟨r', m⟩, h1, h2⟩ := Rust.bind_eq_pure h
  have := Rust.pure_inj h2
  simp only [Prod.mk.injEq] at this
  obtain ⟨rfl, rfl⟩ := this
  exact h1

theorem dh_cluster_next (c c' : Jarl.Cluster V S MAX CAP) (r : Option (DEnv V S MAX))
    (h : Cluster.next_message c = pure (r, c')) : Node.next_message c.node = pure (r, c'.node) := by
  unfold Cluster.next_message at h
  obtain ⟨⟨r', m⟩, h1, h2⟩ := Rust.bind_eq_pure h
  have := Rust.pure_inj h2
  simp only [Prod.mk.injEq] at this
  obtain ⟨rfl, rfl⟩ := this
  exact h1

/-- Every operation keeps the dirty tracking exact, and only a clean node sends. -/
theorem cop_ok [Rust.LawfulClone V] [Rust.LawfulClone S] (sent : List (DEnv V S MAX)) (c c' : Jarl.Cluster V S MAX CAP)
    (out : Option (DEnv V S MAX)) (hf : NodeFacts c.node) (h : COp sent c out c') :
    OpOk c.node c'.node ∧ (out.isSome = true → c.node.dirty = false) := by
  cases h with
  | tick r c' h => exact ⟨dh_tick _ _ hf.pre.contig (tick_rel' _ hf.pre r _ (dh_cluster_tick _ _ _ h)), by simp⟩
  | deliver env r c' _ h => exact ⟨dh_step _ hf.pre hf.bnd env r _ (dh_cluster_step _ _ _ _ h), by simp⟩
  | propose v r c' h => exact ⟨dh_propose _ _ _ hf.pre.contig (cluster_propose_rel c hf.pre v r c' h), by simp⟩
  | proposeBatch vs r c' hs h =>
    exact ⟨dh_propose _ _ _ hf.pre.contig (cluster_propose_batch_rel c hf.pre vs hs r c' h), by simp⟩
  | compact index app r c' h =>
    obtain ⟨value, -, hC⟩ := cluster_compact_rel c hf.pre index app r c' h
    exact ⟨dh_compact _ _ index value hf.pre hC, by simp⟩
  | setLearners ls r c' hl h =>
    exact ⟨dh_reconfig _ _ hf.pre.contig (cluster_set_learners_rel c hf.pre hf.mem hf.memOk ls hl r c' h), by simp⟩
  | reconfigure target r c' ht h =>
    exact ⟨dh_reconfig _ _ hf.pre.contig (cluster_reconfigure_rel c hf.pre hf.mem hf.memOk target ht r c' h),
      by simp⟩
  | finish r c' h =>
    exact ⟨dh_reconfig _ _ hf.pre.contig (cluster_finish_rel c hf.pre hf.mem hf.memOk r c' h), by simp⟩
  | send env c' h => exact dh_next _ _ _ (next_message_rel' _ hf.pre _ _ (dh_cluster_next _ _ _ h))
  | drain c' h => exact dh_next _ _ _ (next_message_rel' _ hf.pre _ _ (dh_cluster_next _ _ _ h))

/-- On a node with a pending save, every operation is a no-op: it is not available. -/
theorem cop_dirty [Rust.LawfulClone V] [Rust.LawfulClone S] (sent : List (DEnv V S MAX)) (c c' : Jarl.Cluster V S MAX CAP)
    (out : Option (DEnv V S MAX)) (hf : NodeFacts c.node) (hd : c.node.dirty = true) (h : COp sent c out c') :
    c' = c ∧ out = none := by
  obtain ⟨hok, hout⟩ := cop_ok sent c c' out hf h
  refine ⟨?_, ?_⟩
  · rcases hok with he | ⟨hd', -⟩
    · cases c; cases c'; simp only at he; rw [he]
    · rw [hd] at hd'; cases hd'
  · cases out with
    | none => rfl
    | some env => rw [hout rfl] at hd; cases hd

end Jarl.Engine.DynHost
