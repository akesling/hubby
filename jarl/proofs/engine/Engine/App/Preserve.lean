import Engine.App.Model

/-!
# Every honest step preserves the application invariant

Snapshots enter the system in five ways, each covered here:

* compaction (`compact_snap`): the honest value is the snapshot value folded
  over the retained entries through `index`; since the node is clean its full
  log is consistent, so that is `state` of the leader prefix through `index`;
* persistence (`persist_app`): the durable state becomes a copy of the live one;
* restart (`restart_app`): `Node::new` takes the durable state as is;
* sending (`send_app`): an `Install` message carries the sender's snapshot;
* delivery (`deliver_snap`): `step` keeps the snapshot or installs the
  delivered `Install` message's snapshot.

Every other path leaves the snapshot alone.
-/

namespace Jarl.Engine.App
open Jarl Jarl.Engine Jarl.Engine.Deliver

variable {V S : Type} {N CAP : Nat} [Rust.Clone V] [Rust.Clone S]

section
variable (init : S) (apply : S → Option V → S)

omit [Rust.Clone V] [Rust.Clone S] in
/-- A checkpoint whose snapshot is `SnapOk` holds the application state of its boundary prefix. -/
theorem boundary_value (G : Ghost V N) (s : State V S CAP) (hok : StateOk G s)
    (hs : ∀ sn, s.snapshot = some sn → SnapOk init apply G sn) :
    state init apply (boundary G s) = baseValue init s := by
  unfold boundary baseValue
  cases h : s.snapshot with
  | none =>
    have : s.base.index.val = 0 := by simp [State.base, h, Rust.Option.map_or, LogId.default]
    simp [this, state]
  | some sn =>
    obtain ⟨-, -, -, hv⟩ := hs sn h
    have hb := base_some s sn h
    have hpos := hok.snapshot (by simp [h])
    rw [hb] at hpos ⊢
    simp [show sn.last.index.val ≠ 0 by omega, hv]

omit [Rust.Clone V] [Rust.Clone S] in
/-- An honest compaction value is the application state of the full log through `index`. -/
theorem honest_value (G : Ghost V N) (n : Node V S N CAP) (hok : StateOk G n.state)
    (hs : ∀ sn, n.state.snapshot = some sn → SnapOk init apply G sn) (index : Rust.u64)
    (hle : n.state.base.index.val ≤ index.val) :
    honest init apply n index = state init apply ((fullLog G n.state).take index.val) := by
  have hbl := boundary_len G n.state hok
  rw [fullLog_def, List.take_append, List.take_of_length_le (by omega), hbl]
  unfold honest
  rw [← boundary_value init apply G n.state hok hs]
  unfold state
  rw [List.foldl_append]

theorem compact_snap [Rust.LawfulClone S] (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP)
    (G : Ghost V N) (hi : Inv ids cfg C G) (hA : AppInv init apply C G) (k : Fin N) (index : Rust.u64)
    (r : Rust.Result Unit Error) (n : Node V S N CAP)
    (h : Node.compact (C.live k) index (honest init apply (C.live k) index) = pure (r, n)) :
    ∀ sn, n.state.snapshot = some sn → SnapOk init apply G sn := by
  have hf := (hi.fixed k).1
  rcases compact_with_rel ids (C.live k) hf index _ r n (compact_wrap _ index _ r n h) with rfl |
    ⟨⟨hd, -, -⟩, hlo, hhi, last, v, s', hid, hv, hins, hcase⟩
  · exact hA.live k
  have hv' : v = honest init apply (C.live k) index := Rust.LawfulClone.clone_eq _ _ hv
  have hsn : n.state.snapshot = s'.snapshot := by
    rcases hcase with ⟨-, rfl⟩ | ⟨-, n2, hB, rfl⟩
    · rfl
    · have := snap_barrier hB; exact this
  obtain ⟨s2, hins2, hsn2, -, -, -⟩ := install_spec (C.live k).state { last := last, value := v }
    (by have := hf.cap_lt; uomega) hf.layout hf.contig
  obtain rfl : s' = s2 := pure_inj (hins.symm.trans hins2)
  intro sn hsn'
  rw [hsn, hsn2] at hsn'
  cases hsn'
  have hok0 := hi.live k
  have hcons : Consistent G (fullLog G (C.live k).state) := by
    rw [hi.clean k hd]; exact hi.consistent_disk k
  have hpos : 0 < index.val := by omega
  obtain ⟨-, hil, hiid⟩ := (idAt_fullLog G _ hok0 index.val hpos last).mp hid
  have hlidx : last.index.val = index.val := by
    have := (hcons (index.val - 1) hil).1; rw [hiid] at this; omega
  have htp := consistent_take_prefix G _ hcons index.val hpos hil
  rw [hiid] at htp
  obtain ⟨-, L, hL, hpL⟩ := hcons (index.val - 1) hil
  rw [hiid] at hL
  refine ⟨L, hL, ?_, ?_⟩
  · show last.index.val ≤ L.length
    have := hpL.length_le; simp at this; omega
  · show v = state init apply (G.prefix last.term.val last.index.val)
    rw [hlidx, ← htp, hv']
    exact honest_value init apply G _ hok0 (hA.live k) index (by omega)

omit [Rust.Clone V] [Rust.Clone S] in
theorem built_install {n : Node V S N CAP} {j : Fin N} {o : Outbound} {m : Message V S} (hb : Built n j o m)
    (t : Rust.u64) (sn : Snapshot S) (hm : m = .Install t sn) : n.state.snapshot = some sn := by
  cases hb with
  | install s _ hs => injection hm with _ h2; rw [← h2]; exact hs
  | _ => cases hm

/-- `step` keeps the snapshot or installs the delivered one. -/
theorem stepped_snap [Rust.LawfulClone V] (ids : Vector Id N) (n : Node V S N CAP) (hf : Fixed ids n) (a : Fin N)
    (src : Id) (m : Message V S) (n' : Node V S N CAP) (hst : Stepped n a src m n')
    (hb : n.state.base.index.val ≤ n.state.hard.commit.val)
    (hc : n.state.hard.commit.val ≤ (lastId n.state).index.val)
    (hnext : ∀ t prev entry commit, m = .Append t prev entry commit → ∀ e, entry = some e →
      e.id.index.val = prev.index.val + 1) :
    n'.state.snapshot = n.state.snapshot ∨ ∃ t snap, m = .Install t snap ∧ n'.state.snapshot = some snap := by
  -- What observing and following leave of the checkpoint.
  have obs : ∀ t n1 n2, Observed n src t n1 → Following n1 src n2 →
      Fixed ids n2 ∧ n2.state.snapshot = n.state.snapshot ∧ n2.state.hard.commit = n.state.hard.commit ∧
        lastId n2.state = lastId n.state := by
    intro t n1 n2 hO hFol
    have hF1 := fixed_observed ids _ _ hf src _ hO
    have hY : Fixed ids ({ n1 with role := .Follower, prevoting := none, leader := some src, leader_age := 0 } :
        Node V S N CAP) := { hF1 with layout := hF1.layout, contig := hF1.contig, prevoting := rfl }
    have hF2 : Fixed ids n2 := fixed_timers ids _ _ hY hFol
    have e2 : n2.state = n1.state := by obtain ⟨r2, d2, rfl⟩ := hFol; rfl
    obtain ⟨-, -, -, -, -, -, hA⟩ := observed_facts _ _ src _ hO
    rw [e2]
    rcases hA with ⟨-, h1, -⟩ | ⟨-, h1, -⟩ <;> rw [h1] <;> exact ⟨hF2, rfl, rfl, rfl⟩
  cases hst with
  | same => exact Or.inl rfl
  | stale m n1 n' _ hO _ hn =>
    left; have := snap_observed hO; rcases hn with rfl | rfl | ⟨i, rfl⟩ <;> exact this
  | vote t last n1 n2 g _ hO _ _ h1 h2 =>
    left; show n2.state.snapshot = _
    cases g
    · rw [h1 rfl]; exact snap_observed hO
    · rw [snap_timers (h2 rfl)]; have := snap_observed hO; exact this
  | voted t g n1 n' _ hO _ hc =>
    left
    rcases hc with ⟨-, rfl⟩ | ⟨-, -, ⟨-, rfl⟩ | ⟨-, hB⟩⟩
    · exact snap_observed hO
    · have := snap_observed hO; exact this
    · rw [snap_becomeLeader hB]; have := snap_observed hO; exact this
  | append t prev entry commit n1 n2 n3 r _ hO _ hFol hx =>
    left; show n3.state.snapshot = _
    obtain ⟨hF2, hs2, hc2, hl2⟩ := obs t n1 n2 hO hFol
    have hb2 : n2.state.base = n.state.base := base_of_snapshot _ _ hs2
    obtain ⟨-, hcases⟩ := append_rel ids n2 hF2 prev entry commit (by rw [hb2, hc2]; exact hb)
      (by rw [hl2, hc2]; exact hc) (hnext t prev entry commit rfl) r n3 hx
    rw [← hs2]
    rcases hcases with ⟨-, -, rfl⟩ | ⟨-, -, -, rfl⟩ | ⟨e, -, -, -, -, rfl⟩ | ⟨e, -, -, -, -, rfl⟩ |
        ⟨e, -, -, -, -, rfl⟩ | ⟨e, s', -, -, -, -, hrep, -, rfl⟩
    · rfl
    · exact snap_commitTo _ _
    · exact snap_commitTo _ _
    · rfl
    · exact snap_commitTo _ _
    · rw [snap_commitTo]; exact hrep.2.2.1
  | install t snap n1 n2 n3 rej _ hO _ hFol hc =>
    obtain ⟨hF2, hs2, -, -⟩ := obs t n1 n2 hO hFol
    rcases hc with ⟨-, -, -, rfl⟩ | ⟨-, -, ⟨-, rfl⟩ | ⟨-, -, s', lf, hins, rfl⟩⟩
    · exact Or.inl hs2
    · exact Or.inl hs2
    · right
      refine ⟨t, snap, rfl, ?_⟩
      obtain ⟨s2, hins2, hsn2, -, -, -⟩ := install_spec n2.state snap (by have := hF2.cap_lt; uomega)
        hF2.layout hF2.contig
      obtain rfl : s' = s2 := pure_inj (hins.symm.trans hins2)
      exact hsn2
  | replicated t index rej n1 n' _ hO _ hc =>
    left
    rcases hc with ⟨-, rfl⟩ | ⟨-, hr⟩
    · exact snap_observed hO
    · have hF1 := fixed_observed ids _ _ hf src _ hO
      have hN : N < 2 ^ Rust.usizeBits := by have := hF1.n_lt; uomega
      have hav : (Rust.ofNat a.val : Rust.usize).val = a.val := by simp [Rust.ofNat]; uomega
      have hp : (Rust.ofNat a.val : Rust.usize).val < N := by rw [hav]; exact a.isLt
      obtain ⟨n'', hr', -, m, hR, -, m', hA', -, hst, -⟩ := replicated_rel2 ids n1 hF1 _ hp index rej
      rw [hr'] at hr
      obtain rfl : n' = n'' := (pure_inj hr).symm
      rw [hst, snap_adv hA', hR.2.1]
      exact snap_observed hO

theorem deliver_snap [Rust.LawfulClone V] [Rust.LawfulClone S] (ids : Vector Id N) (cfg : Fin N → Config N)
    (C : Cluster V S N CAP) (G : Ghost V N) (hi : Inv ids cfg C G) (k : Fin N) (env : Envelope V S)
    (r : Rust.Result Unit Error) (n : Node V S N CAP) (hm : env ∈ C.sent)
    (h : Node.step (C.live k) env = pure (r, n)) :
    n.state.snapshot = (C.live k).state.snapshot ∨
      ∃ t snap, env.message = .Install t snap ∧ n.state.snapshot = some snap := by
  have hF := (hi.fixed k).1
  have hFM : FixedMessage env.message := by
    have h2 := (hi.sent env hm).2
    revert h2
    cases env.message <;> intro h2 <;> first | exact h2.elim | trivial
  obtain ⟨⟨a, ha⟩, -⟩ := hi.sent env hm
  have hst := step_rel ids _ hF a env ha hFM r n h
  refine stepped_snap ids _ hF a _ _ n hst (hi.live k).commit_ge (hi.live k).commit_le ?_
  intro t prev entry commit hmsg e he
  obtain ⟨L, -, -, -, hent, -⟩ := sent_append ids cfg C G hi env hm t prev entry commit hmsg
  exact (hent e he).2.2

theorem persist_app (C : Cluster V S N CAP) (G : Ghost V N) (hA : AppInv init apply C G) (k : Fin N)
    (ready : Ready V S N CAP) (h : Node.ready (C.live k) = some ready) :
    AppInv init apply (C.persist k (Ready.persisted ready).node) G := by
  have hr : ready = ⟨C.live k⟩ := by
    unfold Node.ready Rust.Option.then_some at h
    cases hd : (C.live k).dirty <;> simp [hd] at h
    exact h.symm
  subst hr
  rw [persisted_eq]
  refine ⟨fun j sn hs => ?_, fun j sn hs => ?_, hA.sent⟩
  · by_cases hj : j = k
    · subst hj; simp only [Cluster.persist, if_true] at hs; exact hA.live j sn hs
    · simp only [Cluster.persist, hj, if_false] at hs; exact hA.live j sn hs
  · by_cases hj : j = k
    · subst hj; simp only [Cluster.persist, if_true] at hs; exact hA.live j sn hs
    · simp only [Cluster.persist, hj, if_false] at hs; exact hA.disk j sn hs

theorem send_app (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (hA : AppInv init apply C G) (k : Fin N) (env : Envelope V S) (n : Node V S N CAP)
    (h : Node.next_message (C.live k) = pure (some env, n)) :
    AppInv init apply { C.setLive k n with sent := env :: C.sent } G := by
  obtain ⟨hn, -, -, henv⟩ := next_message_rel ids (C.live k) (hi.fixed k).1 _ n h
  have hst : n.state = (C.live k).state := by have := congrArg Node.state hn; exact this
  have h1 := appInv_keep init apply C G hA k n (by rw [hst])
  refine ⟨h1.live, h1.disk, fun env' hm t sn hmsg => ?_⟩
  rcases List.mem_cons.mp hm with rfl | hm
  · obtain ⟨-, j, o, -, -, -, -, hb⟩ := henv env' rfl
    exact hA.live k sn (built_install hb t sn hmsg)
  · exact hA.sent env' hm t sn hmsg

theorem drain_app (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (hA : AppInv init apply C G) (k : Fin N) (n : Node V S N CAP)
    (h : Node.next_message (C.live k) = pure (none, n)) : AppInv init apply (C.setLive k n) G := by
  obtain ⟨hn, -, -, -⟩ := next_message_rel ids (C.live k) (hi.fixed k).1 _ n h
  have hst : n.state = (C.live k).state := by have := congrArg Node.state hn; exact this
  exact appInv_keep init apply C G hA k n (by rw [hst])

theorem restart_app (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (hA : AppInv init apply C G) (k : Fin N) (n : Node V S N CAP)
    (h : Node.new (cfg k) (C.disk k) = pure (.Ok n)) : AppInv init apply (C.setLive k n) G := by
  obtain ⟨hf0, hc0⟩ := hi.fixed k
  have hm : (cfg k).members = ids := by rw [← hc0]; exact hf0.members
  obtain ⟨-, hs, -⟩ := new_rel ids (cfg k) (C.disk k) n h hf0.n_pos hf0.n_lt hf0.cap_lt hm
    hf0.nodup (hi.disk k).layout (hi.disk k).contig
  exact appInv_setLive init apply C G hA k n (fun sn h => hA.disk k sn (hs ▸ h))

theorem propose_app (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (hA : AppInv init apply C G) (k : Fin N) (vs : List V) (values : List (Rust.M V))
    (hvlen : values.length = vs.length)
    (hval : ∀ i (hi : i < vs.length), Rust.Faithful (values[i]'(hvlen ▸ hi)) vs[i])
    (count : Rust.usize) (hc : count.val = vs.length) (r : Rust.Result ProposalRange Error) (n : Node V S N CAP)
    (h : Node.propose_many (C.live k) count values = pure (r, n)) : AppInv init apply (C.setLive k n) G := by
  apply appInv_keep init apply C G hA k n
  rcases propose_many_rel ids (C.live k) (hi.fixed k).1 vs values hvlen hval count hc r n h with rfl |
    ⟨-, -, -, -, s', n2, -, -, hs, -, -, hA', rfl⟩
  · rfl
  · show n2.state.snapshot = _
    rw [snap_adv hA']; exact hs

/-- Every honest step keeps every snapshot in the system `SnapOk` for the old history. -/
theorem app_step [Rust.LawfulClone V] [Rust.LawfulClone S] (ids : Vector Id N) (cfg : Fin N → Config N)
    (C C' : Cluster V S N CAP) (G : Ghost V N) (hi : Inv ids cfg C G) (hA : AppInv init apply C G)
    (ha : AppAct init apply cfg C C') : AppInv init apply C' G := by
  cases ha with
  | tick k r n h =>
    exact appInv_keep init apply C G hA k n (snap_ticked (tick_rel ids _ (hi.fixed k).1 r n h))
  | deliver k env r n hm h =>
    apply appInv_setLive init apply C G hA k n
    intro sn hs
    rcases deliver_snap ids cfg C G hi k env r n hm h with e | ⟨t, snap, hmsg, e⟩
    · exact hA.live k sn (e ▸ hs)
    · rw [e] at hs; cases hs; exact hA.sent env hm t _ hmsg
  | propose k v r n h =>
    obtain ⟨r', h'⟩ := propose_wrap _ v r n h
    refine propose_app init apply ids cfg C G hi hA k [v] [Rust.Clone.clone v] rfl ?_ 1 (by simp) r' n h'
    intro i hi'; obtain rfl : i = 0 := by simpa using hi'
    exact Rust.faithful_clone v
  | proposeBatch k vs r n hs h =>
    exact propose_app init apply ids cfg C G hi hA k vs.toList (vs.toList.map Rust.Clone.clone)
      (List.length_map _) (fun i _ => by simpa only [List.getElem_map] using Rust.faithful_clone _)
      (Rust.usizeOf vs.size) (by simp [Rust.val_usizeOf _ hs]) r n (propose_batch_wrap _ vs r n h)
  | compact k index r n h =>
    exact appInv_setLive init apply C G hA k n (compact_snap init apply ids cfg C G hi hA k index r n h)
  | persist k ready h => exact persist_app init apply C G hA k ready h
  | send k env n h => exact send_app init apply ids cfg C G hi hA k env n h
  | drain k n h => exact drain_app init apply ids cfg C G hi hA k n h
  | restart k n h => exact restart_app init apply ids cfg C G hi hA k n h

/-- Every honest step preserves `Inv` and `AppInv`, extending the ghost history. -/
theorem app_preserve [Rust.LawfulClone V] [Rust.LawfulClone S] (ids : Vector Id N) (cfg : Fin N → Config N)
    (C C' : Cluster V S N CAP) (G : Ghost V N) (hi : Inv ids cfg C G) (hA : AppInv init apply C G)
    (ha : AppAct init apply cfg C C') :
    ∃ G', Extends G G' ∧ Inv ids cfg C' G' ∧ AppInv init apply C' G' := by
  obtain ⟨G', e, hi'⟩ := preserve ids cfg C C' G hi (ha.toAct init apply)
  exact ⟨G', e, hi', appInv_mono init apply e C' (app_step init apply ids cfg C C' G hi hA ha)⟩

/-- Initial clusters hold no snapshot. -/
theorem init_app (ids : Vector Id N) (cfg : Fin N → Config N) (ha : Assumptions ids cfg CAP)
    (C : Cluster V S N CAP) (hC : Initial cfg C) (G : Ghost V N) : AppInv init apply C G := by
  obtain ⟨hs, hk⟩ := hC
  refine ⟨fun k sn h => ?_, fun k sn h => ?_, fun env hm => by rw [hs] at hm; cases hm⟩
  · obtain ⟨-, hst, -⟩ := new_rel ids (cfg k) _ _ (hk k).2 ha.nonempty ha.members_fit ha.capacity_fits
      (ha.members k) ha.distinct new_layout new_contig
    rw [hst] at h; simp [State.new] at h
  · rw [(hk k).1] at h; simp [State.new] at h

/-- Every honestly reachable cluster satisfies `Inv` and `AppInv` for some ghost history. -/
theorem app_reach_inv [Rust.LawfulClone V] [Rust.LawfulClone S] (ids : Vector Id N) (cfg : Fin N → Config N)
    (ha : Assumptions ids cfg CAP) (C : Cluster V S N CAP) (h : AppReach init apply cfg C) :
    ∃ G, Inv ids cfg C G ∧ AppInv init apply C G := by
  induction h with
  | init C hC =>
    exact ⟨_, init_inv ids cfg ha.nonempty ha.members_fit ha.capacity_fits ha.distinct ha.members
      ha.identity C hC, init_app init apply ids cfg ha C hC _⟩
  | step C C' _ hs ih =>
    obtain ⟨G, hi, hA⟩ := ih
    obtain ⟨G', -, hi', hA'⟩ := app_preserve init apply ids cfg C C' G hi hA hs
    exact ⟨G', hi', hA'⟩

/-- Honest steps from an invariant cluster extend the ghost history. -/
theorem app_steps_inv [Rust.LawfulClone V] [Rust.LawfulClone S] (ids : Vector Id N) (cfg : Fin N → Config N)
    (C C' : Cluster V S N CAP) (G : Ghost V N) (hi : Inv ids cfg C G) (hA : AppInv init apply C G)
    (hs : AppSteps init apply cfg C C') :
    ∃ G', Extends G G' ∧ Inv ids cfg C' G' ∧ AppInv init apply C' G' := by
  induction hs generalizing G with
  | refl => exact ⟨G, Extends.refl G, hi, hA⟩
  | step C C1 C2 ha _ ih =>
    obtain ⟨G1, e1, h1, hA1⟩ := app_preserve init apply ids cfg C C1 G hi hA ha
    obtain ⟨G2, e2, h2, hA2⟩ := ih G1 h1 hA1
    exact ⟨G2, e1.trans e2, h2, hA2⟩

end

end Jarl.Engine.App
