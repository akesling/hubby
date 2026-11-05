import Engine.Host.Delta

/-!
# Dirty tracking of every node operation

For each public operation of a fixed node: either the node is unchanged, or
it started clean and its result `Agrees` with its starting checkpoint under its
own `log_from` and `snapshot_changed`. Derived from the per-operation
specifications; `Install` is re-derived from the generated `step`, because
`step_rel` leaves the `log_from` it sets existential.
-/

namespace Jarl.Engine.Host
open Jarl Jarl.Engine Jarl.Engine.Deliver Jarl.Contracts.StorageView

variable {V S : Type} {N CAP : Nat}

theorem tick_agrees [Rust.Clone V] [Rust.Clone S] (ids : Vector Id N) (n : Node V S N CAP) (hf : Fixed ids n)
    (r : Rust.Result Unit Error) (n' : Node V S N CAP) (h : Node.tick n = pure (r, n')) :
    n' = n ∨ (n.dirty = false ∧ AgreesN n.state n') := by
  cases tick_rel ids n hf r n' h with
  | same => exact Or.inl rfl
  | time _ hI hT => exact Or.inr ⟨hI.1, agreesN_of_same _ _ (same_timeOnly hT)⟩
  | heartbeat n0 n2 hI _ hT hB =>
    have hS := same_timeOnly hT
    refine Or.inr ⟨hI.1, agreesN_same _ _ _ ?_ (same_bcast n2)⟩
    exact agrees_barrier _ n0 n2 (full_of_same _ _ hS) (contig_congr _ _ hS.1 hS.2.1 hf.contig) hB
  | campaign n0 _ h0 hI _ hT _ hC =>
    have hS := same_timeOnly hT
    exact Or.inr ⟨hI.1, agrees_campaigned _ n0 _ _ h0 hS.1 hS.2.1 (contig_congr _ _ hS.1 hS.2.1 hf.contig) hC⟩

theorem propose_agrees [Rust.Clone V] [Rust.Clone S] (ids : Vector Id N) (n : Node V S N CAP) (hf : Fixed ids n)
    (vs : List V) (values : List (Rust.M V)) (hvlen : values.length = vs.length)
    (hval : ∀ i (hi : i < vs.length), Rust.Faithful (values[i]'(hvlen ▸ hi)) vs[i])
    (count : Rust.usize) (hc : count.val = vs.length)
    (r : Rust.Result ProposalRange Error) (n' : Node V S N CAP)
    (h : Node.propose_many n count values = pure (r, n')) :
    n' = n ∨ (n.dirty = false ∧ AgreesN n.state n') := by
  rcases propose_many_rel ids n hf vs values hvlen hval count hc r n' h with
    rfl | ⟨hI, -, hpos, hfit, s', n2, hr, -, hs, -, -, hA, rfl⟩
  · exact Or.inl rfl
  refine Or.inr ⟨hI.1, agreesN_same _ _ _ ?_ (same_bcast n2)⟩
  apply agreesN_same _ _ _ _ (same_adv hA)
  show Agrees n.state s' n.snapshot_changed (some (Rust.ofNat ((lastId n.state).index.val + 1)))
  refine agrees_prefix n.state n.state s' _ none (agrees_of_log _ _ rfl rfl _ _) hs (ret n.state).length
    (by rw [hr]; simp) _ ?_ (by simp)
  have := lastId_eq n.state hf.contig
  simp only [Rust.ofNat]
  rw [Nat.mod_eq_of_lt (by omega)]
  omega

theorem compact_agrees [Rust.Clone V] [Rust.Clone S] (ids : Vector Id N) (n : Node V S N CAP) (hf : Fixed ids n)
    (index : Rust.u64) (value : Unit → Rust.M S) (r : Rust.Result Unit Error) (n' : Node V S N CAP)
    (h : Node.compact_with n index value = pure (r, n')) :
    n' = n ∨ (n.dirty = false ∧ AgreesN n.state n') := by
  rcases compact_with_rel ids n hf index value r n' h with rfl | ⟨hI, hlo, -, last, v, s', hid, -, hins, hcase⟩
  · exact Or.inl rfl
  refine Or.inr ⟨hI.1, ?_⟩
  obtain ⟨s'', hins', hsn, -, hr, -⟩ := install_spec n.state ⟨last, v⟩
    (by have := hf.cap_lt; uomega) hf.layout hf.contig
  rw [hins] at hins'
  cases Rust.pure_inj hins'
  have hlast : last.index.val = index.val := by
    have hid' := hid
    unfold idAt at hid'
    rw [if_neg (by omega), if_pos hlo] at hid'
    obtain ⟨e, he, rfl⟩ := Option.map_eq_some_iff.mp hid'
    obtain ⟨hj, rfl⟩ := List.getElem?_eq_some_iff.mp he
    have := hf.contig _ hj
    omega
  have hm : idAt n.state last.index.val = some last := by rw [hlast]; exact hid
  obtain ⟨hle, -⟩ := idAt_some n.state hf.layout hf.contig last hm
  have hc' := install_contig n.state s' _ hf.layout hf.contig hsn hr
  simp only [if_pos hm] at hr
  have hfull : Agrees n.state s' true none :=
    agrees_install_keep n.state n.state s' n.snapshot_changed (agrees_of_log _ _ rfl rfl _ _) _ hsn hle hr
  rcases hcase with ⟨-, rfl⟩ | ⟨-, n2, hB, rfl⟩
  · exact agrees_weaken _ _ _ hfull _
  · exact agreesN_same _ _ _ (agrees_barrier _ _ n2 hfull hc' hB) (same_bcast n2)

/-- `Install` from the generated code of `step`: the stale and conflicting
    branches keep the log; installing a matching snapshot keeps the suffix
    after it; installing a conflicting one empties the log and cuts just past
    the new boundary. -/
theorem step_install_agrees [Rust.Clone V] [Rust.Clone S] [Rust.LawfulClone S] (ids : Vector Id N)
    (n : Node V S N CAP) (hf : Fixed ids n) (a : Fin N) (src dst : Id) (hsrc : src = ids[a])
    (t : Rust.u64) (snap : Snapshot S) (r : Rust.Result Unit Error) (n' : Node V S N CAP)
    (h : Node.step n ⟨src, dst, .Install t snap⟩ = pure (r, n')) :
    n' = n ∨ (n.dirty = false ∧ AgreesN n.state n') := by
  have hN : N < 2 ^ Rust.usizeBits := by have := hf.n_lt; uomega
  have hpos : Rust.Iter.position n.peers.toList (fun id => id == some src) = some (Rust.ofNat a.val) := by
    rw [hf.peers, hsrc]; exact position_member ids hf.nodup a.val a.isLt
  unfold Node.step at h
  cases hA : Node.available n
  case Err e =>
    simp only [hA] at h
    exact Or.inl (congrArg Prod.snd (pure_inj h)).symm
  rename_i u
  have hI := idle_of_available n hA
  simp only [hA, hpos, Option.orElse, Rust.Option.ok_or, pure_bind] at h
  by_cases hc : (!(src == n.config.id || dst != n.config.id)) = true
  case neg =>
    rw [if_neg hc] at h
    exact Or.inl (congrArg Prod.snd (pure_inj h)).symm
  rw [if_pos hc] at h
  obtain ⟨v, -, h1⟩ := bind_eq_pure _ _ _ h
  clear h
  cases v
  case false =>
    rw [if_pos (show (!false) = true from rfl)] at h1
    exact Or.inl (congrArg Prod.snd (pure_inj h1)).symm
  rw [if_neg (by decide : ¬ (!true) = true)] at h1
  have hk : ∀ b c : Bool, (n.hooks.isSome && b && c) = false := by simp [hf.hooks]
  rw [hk, if_neg (by decide : ¬ (false = true))] at h1
  dsimp only [Message.term] at h1
  obtain ⟨n1, hO, hF1, hle, h⟩ := observe_split ids n hf src t _ _ h1
  refine Or.inr ⟨hI.1, ?_⟩
  have hS1 : Same n n1 := same_observed hO
  by_cases hs : t.val < n1.state.hard.term.val
  · have hd : t < n1.state.hard.term := Fin.lt_def.mpr hs
    simp only [hd, decide_true, if_true, reply_peer _ _ _ _ hN, pure_bind] at h
    obtain rfl := (congrArg Prod.snd (pure_inj h))
    exact agreesN_of_same _ _ (hS1.trans (same_queue _ _ _))
  have hd : ¬ t < n1.state.hard.term := fun e => hs (Fin.lt_def.mp e)
  simp only [hd, decide_false, Bool.false_eq_true, if_false] at h
  obtain ⟨n2, hfo, hFol, hF2⟩ := follow_some ids n1 hF1 src
  rw [hfo, pure_bind] at h
  have hS2 : Same n n2 := hS1.trans (same_following hFol)
  by_cases c1 : snap.last.index.val ≤ n2.state.hard.commit.val ∧
      Rust.Option.is_some_and (State.id_at n2.state snap.last.index) (fun id => id != snap.last) = true
  · rw [if_pos (by simp only [Bool.and_eq_true, decide_eq_true_eq, Fin.le_def]; exact c1)] at h
    rw [reply_peer _ _ _ _ hN, pure_bind] at h
    obtain rfl := (congrArg Prod.snd (pure_inj h))
    exact agreesN_of_same _ _ (hS2.trans (same_queue _ _ _))
  rw [if_neg (by simp only [Bool.and_eq_true, decide_eq_true_eq, Fin.le_def]; exact c1)] at h
  by_cases c2 : n2.state.base.index.val < snap.last.index.val ∧
      (n2.state.hard.commit.val < snap.last.index.val ∨ idAt n2.state snap.last.index.val = some snap.last)
  · rw [if_pos (by rw [id_at_eq _ hF2.layout]; simpa [Fin.lt_def] using c2)] at h
    obtain ⟨s', hins, hsn, -, hr, hl'⟩ :=
      install_spec n2.state snap (by have := hF2.cap_lt; uomega) hF2.layout hF2.contig
    have hc' := install_contig n2.state s' _ hF2.layout hF2.contig hsn hr
    by_cases c3 : (State.id_at n2.state snap.last.index != some snap.last) = true
    · rw [if_pos c3] at h
      obtain ⟨sc, hsc, h⟩ := bind_eq_pure _ _ _ h
      rw [Rust.LawfulClone.clone_eq _ _ hsc, hins, pure_bind] at h
      have hX : Fixed ids { n2 with state := s', log_from := Rust.checked_add snap.last.index 1 } :=
        { hF2 with layout := hl', contig := hc' }
      rw [refresh_fixed ids _ hX, pure_bind, reply_peer _ _ _ _ hN, pure_bind] at h
      obtain rfl := (congrArg Prod.snd (pure_inj h))
      have hm : idAt n2.state snap.last.index.val ≠ some snap.last := by
        rw [← id_at_eq _ hF2.layout]; simpa using c3
      rw [if_neg hm] at hr
      exact agrees_install_reset n.state s' hf.contig snap hsn hr
    · rw [if_neg c3] at h
      obtain ⟨sc, hsc, h⟩ := bind_eq_pure _ _ _ h
      rw [Rust.LawfulClone.clone_eq _ _ hsc, hins, pure_bind] at h
      have hX : Fixed ids { n2 with state := s' } := { hF2 with layout := hl', contig := hc' }
      rw [refresh_fixed ids _ hX, pure_bind, reply_peer _ _ _ _ hN, pure_bind] at h
      obtain rfl := (congrArg Prod.snd (pure_inj h))
      have hm : idAt n2.state snap.last.index.val = some snap.last := by
        rw [← id_at_eq _ hF2.layout]; simpa using c3
      rw [if_pos hm] at hr
      obtain ⟨hle', -⟩ := idAt_some n2.state hF2.layout hF2.contig _ hm
      exact agrees_weaken _ _ _ (agrees_install_keep n.state n2.state s' n2.snapshot_changed
        (full_of_same _ _ hS2) snap hsn hle' hr) _
  · rw [if_neg (by rw [id_at_eq _ hF2.layout]; simpa [Fin.lt_def] using c2)] at h
    rw [reply_peer _ _ _ _ hN, pure_bind] at h
    obtain rfl := (congrArg Prod.snd (pure_inj h))
    exact agreesN_of_same _ _ (hS2.trans (same_queue _ _ _))

/-- Delivering any sent message. -/
theorem deliver_agrees [Rust.Clone V] [Rust.Clone S] [Rust.LawfulClone V] [Rust.LawfulClone S]
    (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (k : Fin N) (env : Envelope V S) (r : Rust.Result Unit Error) (n : Node V S N CAP)
    (hm : env ∈ C.sent) (h : Node.step (C.live k) env = pure (r, n)) :
    n = C.live k ∨ ((C.live k).dirty = false ∧ AgreesN (C.live k).state n) := by
  have hF := (hi.fixed k).1
  have hFM : FixedMessage env.message := by
    have h2 := (hi.sent env hm).2
    revert h2
    cases env.message <;> intro h2 <;> first | exact h2.elim | trivial
  by_cases hsame : env.from = (C.live k).config.id ∨ env.to ≠ (C.live k).config.id ∨ env.message.term.val = 0
  · exact Or.inl (step_same ids _ hF env hFM hsame r n h)
  obtain ⟨⟨a, ha⟩, -⟩ := hi.sent env hm
  have hst := step_rel ids _ hF a env ha hFM r n h
  rcases env with ⟨src, dst, msg⟩
  simp only at hst ha
  cases hst with
  | same => exact Or.inl rfl
  | stale _ n1 _ hI hO _ hn =>
    refine Or.inr ⟨hI.1, agreesN_of_same _ _ ?_⟩
    have hS := same_observed hO
    rcases hn with rfl | rfl | ⟨i, rfl⟩
    · exact hS
    · exact hS.trans (same_queue _ _ _)
    · exact hS.trans (same_queue _ _ _)
  | vote t last n1 n2 g hI hO _ _ h1 h2 =>
    have hS := same_observed hO
    have h12 : Same n1 n2 := by
      cases g
      · rw [h1 rfl]; exact Same.refl _
      · have hT := same_timers (h2 rfl)
        exact ⟨hT.1, hT.2.1, hT.2.2.1, hT.2.2.2⟩
    exact Or.inr ⟨hI.1, agreesN_of_same _ _ ((hS.trans h12).trans (same_queue _ _ _))⟩
  | voted t g n1 _ hI hO _ hc =>
    have hS := same_observed hO
    refine Or.inr ⟨hI.1, ?_⟩
    rcases hc with ⟨-, rfl⟩ | ⟨-, -, ⟨-, rfl⟩ | ⟨-, hB⟩⟩
    · exact agreesN_of_same _ _ hS
    · exact agreesN_of_same _ _ (hS.trans ⟨rfl, rfl, rfl, rfl⟩)
    · have hSv : Same (C.live k) { n1 with votes := n1.votes.set a.val true a.isLt } :=
        hS.trans ⟨rfl, rfl, rfl, rfl⟩
      exact agrees_becomeLeader _ _ _ (full_of_same _ _ hSv) (contig_congr _ _ hSv.1 hSv.2.1 hF.contig) hB
  | append t prev entry commit n1 n2 n3 rr hI hO _ hFol hx =>
    have hS1 := same_observed hO
    have hF1 := fixed_observed ids _ n1 hF src t hO
    have hY : Fixed ids ({ n1 with role := .Follower, prevoting := none, leader := some src, leader_age := 0 } :
        Node V S N CAP) := { hF1 with layout := hF1.layout, contig := hF1.contig, prevoting := rfl }
    have hF2 : Fixed ids n2 := fixed_timers ids _ n2 hY hFol
    have hS2 := hS1.trans (same_following hFol)
    obtain ⟨L, -, -, -, hent, -⟩ := sent_append ids cfg C G hi _ hm t prev entry commit rfl
    have hok := hi.live k
    have hcommit : n2.state.hard.commit = (C.live k).state.hard.commit := by
      obtain ⟨r', d', rfl⟩ := hFol
      rcases (observed_facts _ _ _ _ hO).2.2.2.2.2.2 with ⟨-, hs1, -, -⟩ | ⟨-, hs1, -, -⟩ <;> simp [hs1]
    have hbase : n2.state.base = (C.live k).state.base := by simp [State.base, hS2.1]
    have hlast : lastId n2.state = lastId (C.live k).state := by simp only [lastId, hS2.2.1, hbase]
    obtain ⟨-, hcases⟩ := append_rel ids n2 hF2 prev entry commit (by rw [hbase, hcommit]; exact hok.commit_ge)
      (by rw [hlast, hcommit]; exact hok.commit_le) (fun e he => (hent e he).2.2) rr n3 hx
    refine Or.inr ⟨hI.1, agreesN_same _ _ _ ?_ (same_queue _ _ _)⟩
    rcases hcases with ⟨-, -, rfl⟩ | ⟨-, -, -, rfl⟩ | ⟨e, -, -, -, -, rfl⟩ | ⟨e, -, -, -, -, rfl⟩ |
        ⟨e, -, -, -, -, rfl⟩ | ⟨e, s', hp, rfl, -, -, hrep, -, rfl⟩
    · exact agreesN_of_same _ _ hS2
    · exact agreesN_of_same _ _ (hS2.trans (same_commitTo _ _))
    · exact agreesN_of_same _ _ (hS2.trans (same_commitTo _ _))
    · exact agreesN_of_same _ _ hS2
    · exact agreesN_of_same _ _ (hS2.trans (same_commitTo _ _))
    · apply agreesN_same _ _ _ _ (same_commitTo _ _)
      obtain ⟨hr', -, hsn', -, -⟩ := hrep
      obtain ⟨hle1, hle2⟩ := idAt_some n2.state hF2.layout hF2.contig prev hp
      have hei : e.id.index.val = prev.index.val + 1 := (hent e rfl).2.2
      show Agrees (C.live k).state s' n2.snapshot_changed
        (some (Rust.Option.map_or n2.log_from e.id.index (fun f => Rust.min f e.id.index)))
      refine agrees_prefix _ n2.state s' _ n2.log_from (agreesN_of_same _ _ hS2) hsn'
        (e.id.index.val - n2.state.base.index.val - 1) ?_ _ ?_ ?_
      · rw [hr', List.take_append_of_le_length (by simp; omega), List.take_take, Nat.min_self]
      · cases n2.log_from with
        | none => simp only [Rust.Option.map_or]; omega
        | some f =>
          simp only [Rust.Option.map_or, Rust.val_min, Nat.min_def]
          split <;> omega
      · intro c₀ hc₀
        rw [hc₀]
        simp only [Rust.Option.map_or, Rust.val_min]
        exact Nat.min_le_left _ _
  | install t snap n1 n2 n3 rej _ _ _ _ _ =>
    exact step_install_agrees ids _ hF a src dst ha t snap r _ h
  | replicated t index rej n1 n' hI hO _ hc =>
    have hS1 := same_observed hO
    refine Or.inr ⟨hI.1, ?_⟩
    rcases hc with ⟨-, rfl⟩ | ⟨-, hr⟩
    · exact agreesN_of_same _ _ hS1
    · have hF1 := fixed_observed ids _ n1 hF src t hO
      have hp : (Rust.ofNat a.val : Rust.usize).val < N := by
        have := hF.n_lt
        simp only [Rust.ofNat]
        rw [Nat.mod_eq_of_lt (by uomega)]
        exact a.isLt
      obtain ⟨n'', hn'', -, m, hrec, -, m', hA, -, hst, -⟩ := replicated_rel ids n1 hF1 _ hp index rej
      rw [hr] at hn''
      obtain rfl := Rust.pure_inj hn''
      have hSm := same_adv hA
      exact agrees_of_log _ _ (by rw [hst, hSm.1, hrec.2.1, hS1.1]) (by rw [hst, hSm.2.1, hrec.2.1, hS1.2.1]) _ _

end Jarl.Engine.Host
