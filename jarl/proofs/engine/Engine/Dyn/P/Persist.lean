import Engine.Dyn.Common

/-!
# Preservation: persistence, restart, and the initial state
-/

set_option linter.unusedSectionVars false

namespace Jarl.Engine.Dyn
open Jarl Jarl.Engine

variable {V S : Type} {MAX CAP K : Nat} [Rust.Clone V] [Rust.Clone S]

/-! ## Generic ghost facts -/

theorem pp_ackOk_le (G : Ghost (Record V MAX) K) (t j j' : Nat) (h : AckOk G t j) (hj : j' ≤ j) : AckOk G t j' := by
  obtain ⟨L, hL, hle⟩ := h
  exact ⟨L, hL, by omega⟩

theorem pp_ackOk_extends {G G' : Ghost (Record V MAX) K} (e : Extends G G') (t j : Nat) (h : AckOk G t j) :
    AckOk G' t j := by
  obtain ⟨L, hL, hle⟩ := h
  obtain ⟨L', hL', hp⟩ := e.leader t L hL
  exact ⟨L', hL', Nat.le_trans hle hp.length_le⟩

theorem pp_elect_inj (G : Ghost (Record V MAX) K) (t : Nat) (a b : Fin K) (x y : List (DEntry V MAX))
    (h1 : G.elect t = some (a, x)) (h2 : G.elect t = some (b, y)) : a = b := by
  rw [h1] at h2
  simp only [Option.some.injEq, Prod.mk.injEq] at h2
  exact h2.1

theorem pp_boundary_extends {G G' : Ghost (Record V MAX) K} (e : Extends G G') (s : DState V S MAX CAP)
    (h : StateOk G s) : boundary G' s = boundary G s := by
  unfold boundary
  split
  · rfl
  · obtain ⟨L, hL, hle, -⟩ := h.base (by omega)
    exact prefix_extends e _ _ L hL hle

theorem pp_snapOk_extends (g : Membership MAX) {G G' : Ghost (Record V MAX) K} (e : Extends G G')
    (s : DState V S MAX CAP) (h : StateOk G s) (hs : SnapOk g G s) : SnapOk g G' s := by
  unfold SnapOk at *; rw [pp_boundary_extends e s h]; exact hs

theorem pp_leading_iff {G G' : Ghost (Record V MAX) K} (hel : G'.elect = G.elect) (k : Fin K) (n : DNode V S MAX CAP) :
    Leading G' k n ↔ Leading G k n := by
  unfold Leading; rw [hel]

theorem pp_committedBy_mono_chain {ids : Vector Id K} {g : Membership MAX} {G G' : Ghost (Record V MAX) K}
    (e : Extends G G') (L : List (DEntry V MAX)) (h : ChainIn (ids := ids) (g := g) G L) :
    ChainIn (ids := ids) (g := g) G' L :=
  ⟨h.1, fun a b hab hb ha hb' => committedBy_mono e _ _ (h.2 a b hab hb ha hb')⟩

/-- Entries of a well-formed checkpoint's full log carry their positions. -/
theorem pp_fullLog_index {ids : Vector Id K} {g : Membership MAX} (G : Ghost (Record V MAX) K) (hw : Wf ids g G)
    (s : DState V S MAX CAP) (h : StateOk G s) (i : Nat)
    (hi : i < (fullLog G s).length) : ((fullLog G s)[i]).id.index.val = i + 1 := by
  by_cases hlo : s.base.index.val ≤ i
  · obtain ⟨hr, he⟩ := fullLog_getElem_ret G s h i hlo hi
    rw [he, h.contig _ hr]
    omega
  · have hpos : 0 < s.base.index.val := by omega
    obtain ⟨L, hL, hle, -⟩ := h.base hpos
    have hb : boundary G s = L.take s.base.index.val := by
      simp [boundary, Ghost.prefix, hL, show s.base.index.val ≠ 0 by omega]
    have hbl := boundary_len G s h
    have hiL : i < L.length := by omega
    have h1 : (boundary G s)[i]'(by omega) = (fullLog G s)[i] :=
      List.IsPrefix.getElem (⟨ret s, rfl⟩ : boundary G s <+: fullLog G s) _
    have h2 : (boundary G s)[i]'(by omega) = L[i] := by
      simp only [hb, List.getElem_take]
    rw [← h1, h2]
    exact ((hw.leader _ L hL).1 i hiL).1

/-- A leader's log is consistent once it is its term's leader log. -/
theorem pp_leader_log_consistent {ids : Vector Id K} {g : Membership MAX} (G G' : Ghost (Record V MAX) K)
    (hw : Wf ids g G) (e : Extends G G') (s : DState V S MAX CAP)
    (hs : StateOk G s) (T : Nat) (eL : List (DEntry V MAX)) (hcons : Consistent G eL) (hp : eL <+: fullLog G s)
    (hbeyond : ∀ i (h : i < (fullLog G s).length), eL.length ≤ i → ((fullLog G s)[i]).id.term.val = T)
    (hT : G'.leader T = some (fullLog G s)) : Consistent G' (fullLog G s) := by
  intro i hi
  refine ⟨pp_fullLog_index G hw s hs i hi, ?_⟩
  by_cases hlt : i < eL.length
  · obtain ⟨-, L, hL, hpL⟩ := hcons i hlt
    obtain ⟨L', hL', hp'⟩ := e.leader _ L hL
    have he : eL[i] = (fullLog G s)[i] := List.IsPrefix.getElem hp hlt
    refine ⟨L', by rw [← he]; exact hL', ?_⟩
    rw [take_of_prefix eL _ hp _ (by omega)]
    exact hpL.trans hp'
  · rw [hbeyond i hi (by omega)]
    exact ⟨_, hT, List.take_prefix _ _⟩

theorem pp_withOwn_extends (G : Ghost (Record V MAX) K) (k : Fin K) (n : DNode V S MAX CAP) (L : List (DEntry V MAX))
    (hL : G.leader n.state.hard.term.val = some L) (hp : L <+: fullLog G n.state) : Extends G (withOwnD G k n) := by
  refine ⟨fun t L0 h => ?_, fun t x h => h, fun a h => List.mem_cons_of_mem _ h, fun b h => h⟩
  by_cases ht : t = n.state.hard.term.val
  · subst ht
    rw [hL] at h
    cases h
    exact ⟨_, by simp [withOwnD], hp⟩
  · exact ⟨L0, by simp [withOwnD, ht, h], List.prefix_refl _⟩

/-- Extending the ghost history extends a leader's own-log ghost. -/
theorem pp_withOwn_mono {G G' : Ghost (Record V MAX) K} (e : Extends G G') (j : Fin K) (n : DNode V S MAX CAP)
    (hs : StateOk G n.state) : Extends (withOwnD G j n) (withOwnD G' j n) := by
  have hf := fullLog_extends e n.state hs
  refine ⟨fun t L h => ?_, fun t x h => e.elect t x h, fun a h => ?_, fun b h => e.ballots b h⟩
  · by_cases ht : t = n.state.hard.term.val
    · simp only [withOwnD, ht, if_true, Option.some.injEq] at h
      subst h
      exact ⟨_, by simp [withOwnD, ht, hf], List.prefix_refl _⟩
    · simp only [withOwnD, ht, if_false] at h
      obtain ⟨L', h', hp⟩ := e.leader t L h
      exact ⟨L', by simp [withOwnD, ht, h'], hp⟩
  · simp only [withOwnD, List.mem_cons] at h ⊢
    rcases h with h | h
    · left; rw [hf]; exact h
    · right; exact e.acks a h

/-! ## Checkpoints of a fresh node -/

theorem pp_new_ret : ret (State.new : DState V S MAX CAP) = [] := by
  simp [ret, State.new]

theorem pp_new_layout : Layout (State.new : DState V S MAX CAP) := by
  refine ⟨by simp [State.new], ?_⟩
  rw [pp_new_ret]
  apply List.ext_getElem <;> simp [State.new, Rust.Slice.from_fn]

theorem pp_new_contig : Contig (State.new : DState V S MAX CAP) := by
  intro k hk; simp [pp_new_ret] at hk

theorem pp_new_base : (State.new : DState V S MAX CAP).base = LogId.default := rfl

theorem pp_new_fullLog (G : Ghost (Record V MAX) K) : fullLog G (State.new : DState V S MAX CAP) = [] := by
  simp [fullLog, pp_new_base, LogId.default, pp_new_ret]

theorem pp_new_stateOk (G : Ghost (Record V MAX) K) : StateOk G (State.new : DState V S MAX CAP) where
  layout := pp_new_layout
  contig := pp_new_contig
  base := by intro h; simp [pp_new_base, LogId.default] at h
  snapshot := by simp [State.new]
  terms := by rw [pp_new_fullLog]; simp
  commit_ge := by rw [pp_new_base]; simp [LogId.default, State.new, HardState.default]
  commit_le := by simp [State.new, HardState.default]
  unvoted := by simp [State.new, HardState.default]

theorem pp_new_snapOk (g : Membership MAX) (G : Ghost (Record V MAX) K) : SnapOk g G (State.new : DState V S MAX CAP) := by
  have hb : boundary G (State.new : DState V S MAX CAP) = [] := by
    unfold boundary; rw [pp_new_base]; simp [LogId.default]
  unfold SnapOk snapMem memInit
  rw [hb]; simp [State.new]

/-- A node started by `Cluster::new` satisfies `DynOk`. -/
theorem pp_dynOk_fresh {g : Membership MAX} {me : Id} {st : DState V S MAX CAP} {n : DNode V S MAX CAP}
    (h0 : 0 < MAX) (hMAX : MAX < 2 ^ (Rust.usizeBits - 1)) (h4 : 4 ≤ CAP) (hCAP : CAP < 2 ^ (Rust.usizeBits - 1))
    (hL : Layout st) (hC : Contig st) (hf : FreshD g me st n) : DynOk g me n := by
  obtain ⟨hs, hr, hd, hhk, hb, hid, hx, hpv, hld, hm, hob, hh, he, hel, hu, hmem, hle, hslot⟩ := hf
  exact
    { n_pos := h0, n_lt := hMAX, cap_ge := h4, cap_lt := hCAP, hooks := hhk, bootstrap := hb, id := hid
      heartbeat := hh, election := he, election_le := hel
      layout := by rw [hs]; exact hL
      contig := by rw [hs]; exact hC
      membership := by rw [hm, hs]
      peers_nodup := fun i j hi hj x h1 h2 => congrArg Fin.val (hu ⟨i, hi⟩ ⟨j, hj⟩ x h1 h2)
      members := fun id h => by obtain ⟨i, hi⟩ := hmem id h; exact ⟨i.val, i.isLt, hi⟩
      local_le := hle
      local_slot := hslot
      prevoting := by intro t h; rw [hpv] at h; cases h }

theorem pp_restore {id : Id} {g : Membership MAX} {st : DState V S MAX CAP} {saved : ClusterState V S MAX CAP}
    (h : ClusterState.restore id g st = .Ok saved) : saved = { id := id, genesis := g, state := st } := by
  unfold ClusterState.restore at h
  simp only [Id.run] at h
  split at h
  · cases h
  · cases h; rfl

variable (ids : Vector Id K) (g : Membership MAX) (hid : ∀ a b : Fin K, ids[a] = ids[b] → a = b) (hg : MemOk g)

/-- A node whose checkpoint is its disk and that leads its disk term has the leader-log facts. -/
theorem pp_lead_of_disk (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (hi : Inv ids g C G) (k : Fin K)
    (n : DNode V S MAX CAP) (hs : n.state = C.disk k) (hL : Leading G k n) : LeadLog ids g G k n := by
  obtain ⟨eL, he⟩ := hL
  rw [hs] at he
  have hT := hi.disk_lead k eL he
  obtain ⟨-, -, ⟨c, eL', he', hp, hb⟩, hch⟩ := hi.wf.leader _ _ hT
  rw [he] at he'
  simp only [Option.some.injEq, Prod.mk.injEq] at he'
  obtain ⟨rfl, rfl⟩ := he'
  refine ⟨⟨eL, by rw [hs]; exact he, by rw [hs]; exact hp, ?_⟩,
    ⟨_, by rw [hs]; exact hT, by rw [hs]; exact List.prefix_refl _, fun _ => by rw [hs]⟩, by rw [hs]; exact hch, ?_⟩
  · rw [hs]; intro i hi' hle
    exact Fin.ext (hb i hi' hle)
  · rw [hs]; intro i hi' X hX
    exact hi.cfgs _ _ hT i hi' X hX

include hid hg in
theorem preserve_restart (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (hi : Inv ids g C G) (k : Fin K)
    (settings : Settings) (saved : ClusterState V S MAX CAP) (c : Jarl.Cluster V S MAX CAP)
    (h1 : ClusterState.restore ids[k] g (C.disk k) = .Ok saved) (h2 : Cluster.new settings saved = pure (.Ok c)) :
    ∃ G', Extends G G' ∧ Inv ids g (C.setLive k c) G' := by
  have hsv := pp_restore h1
  subst hsv
  have hd0 := hi.dyn k
  have hdk := hi.disk k
  obtain ⟨h4, hf⟩ := cluster_new_rel settings _ c hd0.n_lt hd0.cap_lt hdk.1.layout hdk.1.contig hg.1 h2
  have hdyn := pp_dynOk_fresh hd0.n_pos hd0.n_lt h4 hd0.cap_lt hdk.1.layout hdk.1.contig hf
  obtain ⟨hs, hr, hd, -, -, -, hx, -, -, -, hob, -⟩ := hf
  dsimp only at hs
  refine ⟨G, Extends.refl G, setLive_inv' ids g C G hi k c ?_⟩
  exact
    { dyn := hdyn
      live := hs ▸ hdk
      consistent := Or.inl (hs ▸ hi.consistent_disk k)
      clean := fun _ => hs
      terms := by rw [hs]; exact Nat.le_refl _
      acks := fun t j h j' hj' => hs ▸ ((hi.acks k t j h).2.2 j' hj').2
      ballots := fun T c' v h ht => by rw [hs] at ht ⊢; exact (hi.ballots T k c' v h).2.2.1 ht
      ballot_cand := fun h => by rw [hr] at h; cases h
      elect := fun T eL h hdT ht => by
        obtain ⟨-, b, -, -⟩ := hi.elect T k eL h hdT
        rw [hs, hr]; exact ⟨b, by simp, rfl⟩
      elect_cand := fun T eL h => by rw [hr]; simp
      lead := pp_lead_of_disk ids g C G hi k c.node hs
      leader := fun h => by rw [hr] at h; cases h
      candidate := fun h => by rw [hr] at h; cases h
      outbox := fun j o ho => by rw [(hob j).1] at ho; cases ho
      outbox_self := fun h o ho => by
        have h0 := (hob ⟨_, h⟩).1
        simp only [Fin.getElem_fin] at h0
        rw [h0] at ho; cases ho
      extra := fun to o ho => by rw [hx] at ho; cases ho
      votes := fun env he T last hfr hm => by rw [hr]; simp
      committed := Or.inl (hs ▸ (hi.committed k).1) }

theorem pp_wf_empty : Wf ids g (⟨fun _ => none, fun _ => none, [], []⟩ : Ghost (Record V MAX) K) where
  leader := by intro t L h; simp at h
  elect := by intro T c eL h; simp at h
  ballot := by intro T w c v h; simp at h
  good := by
    intro T p h hne
    rcases h with rfl | ⟨t, j, -, ⟨n, -, -, L, hL, -⟩, -⟩
    · exact absurd rfl hne
    · simp at hL

theorem pp_max_pos (hg : MemOk g) : 0 < MAX := by
  apply Classical.byContradiction; intro h
  have h0 : MAX = 0 := by omega
  apply hg.2
  have : g.members.toList = [] := by
    apply List.eq_nil_of_length_eq_zero; simp [h0]
  simp [Membership.voters, this, Rust.Iter.flatten]

include hid hg in
theorem init_inv' (hMAX : MAX < 2 ^ (Rust.usizeBits - 1)) (hCAP : CAP < 2 ^ (Rust.usizeBits - 1))
    (C : World V S MAX CAP K) (h : DInitial ids g C) : Inv ids g C ⟨fun _ => none, fun _ => none, [], []⟩ := by
  obtain ⟨hsent, hk⟩ := h
  have hnew : ∀ k, 4 ≤ CAP ∧ FreshD g ids[k] State.new (C.node k) := by
    intro k
    obtain ⟨-, settings, saved, h1, h2⟩ := hk k
    have hsv := pp_restore h1
    subst hsv
    exact cluster_new_rel settings _ _ hMAX hCAP pp_new_layout pp_new_contig hg.1 h2
  have hstate : ∀ k, (C.node k).state = State.new := fun k => (hnew k).2.1
  have hrole : ∀ k, (C.node k).role = .Follower := fun k => (hnew k).2.2.1
  have hdisk : ∀ k, C.disk k = State.new := fun k => (hk k).1
  refine
    { wf := pp_wf_empty ids g
      cfgs := by intro t L h; simp at h
      dyn := fun k => pp_dynOk_fresh (pp_max_pos g hg) hMAX (hnew k).1 hCAP pp_new_layout pp_new_contig (hnew k).2
      live := fun k => by rw [hstate]; exact ⟨pp_new_stateOk _, pp_new_snapOk g _⟩
      disk := fun k => by rw [hdisk]; exact ⟨pp_new_stateOk _, pp_new_snapOk g _⟩
      consistent_disk := fun k => by rw [hdisk, pp_new_fullLog]; intro i hi; simp at hi
      consistent_live := fun k => Or.inl (by rw [hstate, pp_new_fullLog]; intro i hi; simp at hi)
      clean := fun k _ => by rw [hstate, hdisk]
      terms := fun k => by rw [hstate, hdisk]; exact Nat.le_refl _
      disk_lead := by intro k eL h; simp at h
      acks := by intro w t j h; simp at h
      ballots := by intro T w c v h; simp at h
      ballot_unique := by intro T w c c' v v' h; simp at h
      ballot_cand := by intro T w c v h; simp at h
      elect := by intro T c eL h; simp at h
      elect_cand := by intro T c eL h; simp at h
      lead := by intro k h; obtain ⟨eL, h⟩ := h; simp at h
      leader := by intro k h; rw [hrole] at h; cases h
      candidate := by intro k h; rw [hrole] at h; cases h
      outbox := by intro k j o h; rw [((hnew k).2.2.2.2.2.2.2.2.2.2.2.1 j).1] at h; cases h
      outbox_self := fun k h o ho => by
        have h0 := ((hnew k).2.2.2.2.2.2.2.2.2.2.2.1 ⟨_, h⟩).1
        simp only [Fin.getElem_fin] at h0
        rw [h0] at ho; cases ho
      elect_disk := by intro T c eL h; simp at h
      extra := by intro k to o h; rw [(hnew k).2.2.2.2.2.2.2.1] at h; cases h
      sent := by intro env h; rw [hsent] at h; cases h
      committed := fun k => ⟨Or.inl (by rw [hdisk, pp_new_fullLog]; simp),
        Or.inl (Or.inl (by rw [hstate, pp_new_fullLog]; simp))⟩ }


/-! ## Saving a checkpoint -/

theorem pp_node_self (C : World V S MAX CAP K) (k : Fin K) (m : DNode V S MAX CAP) :
    (C.persist k ⟨m⟩).node k = m := by simp [World.persist, World.node]

theorem pp_node_other (C : World V S MAX CAP K) (k j : Fin K) (m : DNode V S MAX CAP) (h : j ≠ k) :
    (C.persist k ⟨m⟩).node j = C.node j := by simp [World.persist, World.node, h]

theorem pp_disk_self (C : World V S MAX CAP K) (k : Fin K) (m : DNode V S MAX CAP) :
    (C.persist k ⟨m⟩).disk k = (C.node k).state := by simp [World.persist, World.node]

theorem pp_disk_other (C : World V S MAX CAP K) (k j : Fin K) (m : DNode V S MAX CAP) (h : j ≠ k) :
    (C.persist k ⟨m⟩).disk j = C.disk j := by simp [World.persist, h]

theorem pp_leader_none {G : Ghost (Record V MAX) K} (hw : Wf ids g G) (T : Nat) (h : G.elect T = none) :
    G.leader T = none := by
  cases hL : G.leader T with
  | none => rfl
  | some L =>
    obtain ⟨-, -, ⟨c, eL, he, -⟩, -⟩ := hw.leader T L hL
    rw [h] at he; cases he

theorem pp_winOwn_extends (G : Ghost (Record V MAX) K) (k : Fin K) (n : DNode V S MAX CAP) (eL : List (DEntry V MAX))
    (hT : G.elect n.state.hard.term.val = none) (hL : G.leader n.state.hard.term.val = none) :
    Extends G (winOwnD G k n eL) := by
  refine ⟨fun t L h => ?_, fun t x h => ?_, fun a h => List.mem_cons_of_mem _ h, fun b h => List.mem_cons_of_mem _ h⟩
  · by_cases ht : t = n.state.hard.term.val
    · rw [ht, hL] at h; cases h
    · exact ⟨L, by simp [winOwnD, ht, h], List.prefix_refl _⟩
  · by_cases ht : t = n.state.hard.term.val
    · rw [ht, hT] at h; cases h
    · simp [winOwnD, ht, h]

theorem pp_winOwn_mono {G G' : Ghost (Record V MAX) K} (e : Extends G G') (j : Fin K) (n : DNode V S MAX CAP)
    (eL : List (DEntry V MAX)) (hs : StateOk G n.state) : Extends (winOwnD G j n eL) (winOwnD G' j n eL) := by
  have hf := fullLog_extends e n.state hs
  refine ⟨fun t L h => ?_, fun t x h => ?_, fun a h => ?_, fun b h => ?_⟩
  · by_cases ht : t = n.state.hard.term.val
    · simp only [winOwnD, ht, if_true, Option.some.injEq] at h
      subst h
      exact ⟨_, by simp [winOwnD, ht, hf], List.prefix_refl _⟩
    · simp only [winOwnD, ht, if_false] at h
      obtain ⟨L', h', hp⟩ := e.leader t L h
      exact ⟨L', by simp [winOwnD, ht, h'], hp⟩
  · by_cases ht : t = n.state.hard.term.val
    · simp only [winOwnD, ht, if_true] at h ⊢; exact h
    · simp only [winOwnD, ht, if_false] at h ⊢; exact e.elect t x h
  · simp only [winOwnD, List.mem_cons] at h ⊢
    rcases h with h | h
    · left; rw [hf]; exact h
    · right; exact e.acks a h
  · simp only [winOwnD, List.mem_cons] at h ⊢
    rcases h with h | h
    · left; exact h
    · right; exact e.ballots b h

theorem pp_outOk (C C' : World V S MAX CAP K) {G G' : Ghost (Record V MAX) K} (e : Extends G G')
    (j : Fin K) (to : Id) (o : Outbound) (hst : (C'.node j).state = (C.node j).state)
    (hr : (C'.node j).role = (C.node j).role) (hsent : C'.sent = C.sent) (hs : StateOk G (C.node j).state)
    (hrep : Leading G j (C.node j) ∨ PendingWin ids g C G j (C.node j) →
      Leading G' j (C'.node j) ∨ PendingWin ids g C' G' j (C'.node j))
    (h : OutOk ids g C G j to o) : OutOk ids g C' G' j to o := by
  have hf := fullLog_extends e _ hs
  cases o with
  | Vote => simp only [OutOk] at h ⊢; rw [hr]; exact h
  | Voted gr => simp only [OutOk] at h ⊢; rw [hst, hsent, hf]; exact h
  | Replicated i r =>
    simp only [OutOk] at h ⊢
    rw [hst, hf]
    intro hr0
    obtain ⟨a, L, hL, hle⟩ := h hr0
    rw [prefix_extends e _ _ L hL hle]
    exact ⟨a, pp_ackOk_extends e _ _ ⟨L, hL, hle⟩⟩
  | Replicate => simp only [OutOk] at h ⊢; exact hrep h
  | PreVote _ => exact trivial
  | PreVoted _ _ => exact trivial

theorem pp_sentOk (C C' : World V S MAX CAP K) {G G' : Ghost (Record V MAX) K} (e : Extends G G')
    (hnew : ∀ t c x, G'.elect t = some (c, x) → G.elect t = some (c, x) ∨
      (G.leader t = none ∧ (C.disk c).hard.term.val < t))
    (hdisk : ∀ c, (C.disk c).hard.term.val ≤ (C'.disk c).hard.term.val)
    (hnode : ∀ c, (C'.node c).role = (C.node c).role ∧ (C'.node c).state = (C.node c).state)
    (env : DEnv V S MAX) (h : SentOk ids g C G env) : SentOk ids g C' G' env := by
  unfold SentOk at h ⊢
  refine ⟨h.1, ?_⟩
  have h2 := h.2
  revert h2
  cases hm : env.message with
  | Vote T last =>
    intro h2 c hc
    obtain ⟨a, b, d⟩ := h2 c hc
    refine ⟨Nat.le_trans a (hdisk c), ?_, fun eL he => ?_⟩
    · rw [(hnode c).1, (hnode c).2]; exact b
    · rcases hnew _ _ _ he with he | ⟨-, hlt⟩
      · exact d eL he
      · omega
  | Voted T gr =>
    intro h2 hg w c hw hc
    rcases h2 hg w c hw hc with ⟨vlog, hb⟩ | ⟨eL, he⟩
    · exact Or.inl ⟨vlog, e.ballots _ hb⟩
    · exact Or.inr ⟨eL, e.elect _ _ he⟩
  | Replicated T j r => intro h2 hr w hw; exact e.acks _ (h2 hr w hw)
  | Append T prev entry commit =>
    intro ⟨L, hL, h1, h3, h4, h5, h6⟩
    obtain ⟨L', hL', hp⟩ := e.leader _ L hL
    refine ⟨L', hL', ⟨fun hpos => ?_, h1.2⟩, fun en hen => ?_, Nat.le_trans h4 hp.length_le, ?_, fun c eL he => ?_⟩
    · obtain ⟨hl, hid⟩ := h1.1 hpos
      exact ⟨by have := hp.length_le; omega, by rw [getElem_of_prefix L L' hp _ hl]; exact hid⟩
    · obtain ⟨⟨hl, hid⟩, hidx⟩ := h3 en hen
      exact ⟨⟨by have := hp.length_le; omega, by rw [getElem_of_prefix L L' hp _ hl]; exact hid⟩, hidx⟩
    · rw [take_of_prefix L L' hp _ h4]; exact committedBy_mono e _ _ h5
    · rcases hnew _ _ _ he with he | ⟨hn, -⟩
      · exact h6 c eL he
      · rw [hL] at hn; cases hn
  | AppendBatch T prev es commit =>
    intro ⟨L, hL, h1, h3, h4, h5, h6⟩
    obtain ⟨L', hL', hp⟩ := e.leader _ L hL
    refine ⟨L', hL', ⟨fun hpos => ?_, h1.2⟩, fun en hen => ?_, Nat.le_trans h4 hp.length_le, ?_, fun c eL he => ?_⟩
    · obtain ⟨hl, hid⟩ := h1.1 hpos
      exact ⟨by have := hp.length_le; omega, by rw [getElem_of_prefix L L' hp _ hl]; exact hid⟩
    · obtain ⟨hl, hid⟩ := h3 en hen
      exact ⟨by have := hp.length_le; omega, by rw [getElem_of_prefix L L' hp _ hl]; exact hid⟩
    · rw [take_of_prefix L L' hp _ h4]; exact committedBy_mono e _ _ h5
    · rcases hnew _ _ _ he with he | ⟨hn, -⟩
      · exact h6 c eL he
      · rw [hL] at hn; cases hn
  | Install T snap =>
    intro ⟨L, hL, hpos, ⟨hl, hid⟩, h5, h6, h7⟩
    obtain ⟨L', hL', hp⟩ := e.leader _ L hL
    refine ⟨L', hL', hpos, ⟨by have := hp.length_le; omega, by rw [getElem_of_prefix L L' hp _ hl]; exact hid⟩,
      ?_, ?_, fun c eL he => ?_⟩
    · rw [take_of_prefix L L' hp _ (by omega)]; exact committedBy_mono e _ _ h5
    · rw [take_of_prefix L L' hp _ (by omega)]; exact h6
    · rcases hnew _ _ _ he with he | ⟨hn, -⟩
      · exact h7 c eL he
      · rw [hL] at hn; cases hn
  | _ => intro h2; exact h2

theorem pp_leaderOk {G G' : Ghost (Record V MAX) K} (e : Extends G G') (j : Fin K) (n m : DNode V S MAX CAP)
    (hst : m.state = n.state) (hmat : m.matched = n.matched) (hloc : m.local = n.local) (hpeers : m.peers = n.peers)
    (hs : StateOk G n.state) (h : LeaderOk' ids G j n) : LeaderOk' ids G' j m := by
  obtain ⟨h1, h2⟩ := h
  refine ⟨?_, ?_⟩
  · rw [hst, hmat, hloc, hpeers]
    intro i hi hm
    obtain ⟨w, a, b⟩ := h1 i hi hm
    exact ⟨w, a, e.acks _ b⟩
  · rw [hst, hmat, hloc, fullLog_extends e _ hs]; exact h2

theorem pp_candidateOk {G G' : Ghost (Record V MAX) K} (e : Extends G G')
    (j : Fin K) (n : DNode V S MAX CAP) (hs : StateOk G n.state) (h : CandidateOk' ids G j n) :
    CandidateOk' ids G' j n := by
  have hf := fullLog_extends e _ hs
  obtain ⟨a, b, c⟩ := h
  refine ⟨a, by rw [hf]; exact b, fun i hi => ?_⟩
  rcases c i hi with h | ⟨w, hw, vlog, hb, hu⟩
  · exact Or.inl h
  · exact Or.inr ⟨w, hw, vlog, e.ballots _ hb, by rw [hf]; exact hu⟩

theorem pp_leadLog {G G' : Ghost (Record V MAX) K} (e : Extends G G') (j : Fin K)
    (n : DNode V S MAX CAP) (hs : StateOk G n.state)
    (hlog : G'.leader n.state.hard.term.val = G.leader n.state.hard.term.val) (h : LeadLog ids g G j n) :
    LeadLog ids g G' j n := by
  have hf := fullLog_extends e _ hs
  obtain ⟨⟨eL, he, hp, hb⟩, ⟨L, hL, hp', hd⟩, hch, hc⟩ := h
  refine ⟨⟨eL, e.elect _ _ he, by rw [hf]; exact hp, by rw [hf]; exact hb⟩,
    ⟨L, by rw [hlog]; exact hL, by rw [hf]; exact hp', by rw [hf]; exact hd⟩, ?_, ?_⟩
  · rw [hf]; exact pp_committedBy_mono_chain e _ hch
  · rw [hf]; exact hc

theorem pp_leadLog_saved {G G' : Ghost (Record V MAX) K} (e : Extends G G') (j : Fin K)
    (n m : DNode V S MAX CAP) (hst : m.state = n.state) (hs : StateOk G n.state)
    (hel1 : ∃ eL, G'.elect n.state.hard.term.val = some (j, eL) ∧ eL <+: fullLog G n.state ∧
      ∀ i (h : i < (fullLog G n.state).length), eL.length ≤ i →
        ((fullLog G n.state)[i]).id.term = n.state.hard.term)
    (hlog : G'.leader n.state.hard.term.val = some (fullLog G n.state))
    (hch : ChainIn (ids := ids) (g := g) G (fullLog G n.state))
    (hc : ∀ i (hi : i < (fullLog G n.state).length) X, recCfg ((fullLog G n.state)[i]).value = some X → MemOk X) :
    LeadLog ids g G' j m := by
  have hf := fullLog_extends e _ hs
  refine ⟨?_, ⟨fullLog G' m.state, ?_, List.prefix_refl _, fun _ => rfl⟩, ?_, ?_⟩
  · rw [hst, hf]; exact hel1
  · rw [hst, hf]; exact hlog
  · rw [hst, hf]; exact pp_committedBy_mono_chain e _ hch
  · rw [hst, hf]; exact hc

/-- The ghost of a leader that saved its log is well formed. -/
theorem pp_wf_withOwn (G : Ghost (Record V MAX) K) (hw : Wf ids g G) (k : Fin K) (n : DNode V S MAX CAP)
    (hs : StateOk G n.state) (e : Extends G (withOwnD G k n)) (hll : LeadLog ids g G k n)
    (hcons : Consistent (withOwnD G k n) (fullLog G n.state))
    (hack : ∀ w t j, (w, t, j) ∈ G.acks → AckOk G t j)
    (hb : ∀ Tb c vlog, (Tb, k, c, vlog) ∈ G.ballots → n.state.hard.term.val < Tb → vlog = fullLog G n.state) :
    Wf ids g (withOwnD G k n) := by
  obtain ⟨⟨eL, he, hp, hbt⟩, -, hch, -⟩ := hll
  have hchain : ∀ t L', (withOwnD G k n).leader t = some L' → ChainIn (ids := ids) (g := g) G L' := by
    intro t L' h
    by_cases ht : t = n.state.hard.term.val
    · simp only [withOwnD, ht, if_true, Option.some.injEq] at h
      subst h; exact hch
    · have h' : G.leader t = some L' := by simpa [withOwnD, ht] using h
      exact (hw.leader t L' h').2.2.2
  have hterms : ∀ t L', (withOwnD G k n).leader t = some L' → ∀ x ∈ L', x.id.term.val ≤ t := by
    intro t L' h x hx
    by_cases ht : t = n.state.hard.term.val
    · simp only [withOwnD, ht, if_true, Option.some.injEq] at h
      subst h; rw [ht]; exact hs.terms x hx
    · have h' : G.leader t = some L' := by simpa [withOwnD, ht] using h
      exact ((hw.leader t L' h').2.1 x hx).2
  refine ⟨fun t L h => ?_, fun T' c eL' h => ?_, fun Tb w c vlog h => ?_,
    good_preserve e hw.good hchain hterms⟩
  · by_cases ht : t = n.state.hard.term.val
    · subst ht
      simp only [withOwnD, if_true, Option.some.injEq] at h
      subst h
      refine ⟨hcons, fun x hx => ?_, ⟨k, eL, he, hp, fun i hi hle => congrArg Fin.val (hbt i hi hle)⟩,
        pp_committedBy_mono_chain e _ hch⟩
      refine ⟨?_, hs.terms x hx⟩
      obtain ⟨i, hi, rfl⟩ := List.getElem_of_mem hx
      by_cases hlt : i < eL.length
      · have := (consistent_terms' G hw eL (hw.elect _ _ _ he).2.1 (eL[i]) (List.getElem_mem _)).1
        rwa [List.IsPrefix.getElem hp hlt] at this
      · rw [hbt i hi (by omega)]
        exact (hw.elect _ _ _ he).1
    · have h' : G.leader t = some L := by simpa [withOwnD, ht] using h
      obtain ⟨a, b, c, d⟩ := hw.leader t L h'
      exact ⟨consistent_extends e L a, b, c, pp_committedBy_mono_chain e L d⟩
  · obtain ⟨a, b, c', d⟩ := hw.elect T' c eL' h
    exact ⟨a, consistent_extends e _ b, c', d⟩
  · obtain ⟨a, b⟩ := hw.ballot Tb w c vlog h
    refine ⟨consistent_extends e _ a, fun t j' hack' hlt j hj => ?_⟩
    rcases List.mem_cons.mp hack' with heq | hold
    · simp only [Prod.mk.injEq] at heq
      obtain ⟨rfl, rfl, rfl⟩ := heq
      left; left
      rw [hb Tb c vlog h hlt]
      simp only [Ghost.prefix, withOwnD, if_true, Option.getD_some]
      exact List.take_prefix _ _
    · have ha := pp_ackOk_le G t j' j (hack _ _ _ hold) hj
      rcases b t j' hold hlt j hj with hk | ⟨c', eL', he', hne, hnp⟩
      · exact Or.inl (kept_extends e _ _ _ _ _ hk ha)
      · obtain ⟨L, hL, hle⟩ := ha
        exact Or.inr ⟨c', eL', he', hne, by rw [prefix_extends e _ _ L hL hle]; exact hnp⟩

/-- The ghost of a node whose pending win is saved is well formed. -/
theorem pp_wf_winOwn (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (hw : Wf ids g G) (k : Fin K)
    (n : DNode V S MAX CAP) (hs : StateOk G n.state) (hD : StateOk G (C.disk k))
    (hp : PendingWin ids g C G k n) (e : Extends G (winOwnD G k n (fullLog G (C.disk k))))
    (hconsD : Consistent G (fullLog G (C.disk k)))
    (hcons : Consistent (winOwnD G k n (fullLog G (C.disk k))) (fullLog G n.state))
    (hack : ∀ w t j, (w, t, j) ∈ G.acks → AckOk G t j)
    (hacksD : ∀ t j', (k, t, j') ∈ G.acks → ∀ jj ≤ j',
      Kept G k t jj ((C.disk k).hard.term.val + 1) (fullLog G (C.disk k)))
    (hbk : ∀ Tb c vlog, (Tb, k, c, vlog) ∈ G.ballots → Tb ≤ (C.disk k).hard.term.val ∨
      (k = c ∧ (C.disk k).hard.term.val + 1 = Tb ∧ G.elect Tb = some (c, vlog))) :
    Wf ids g (winOwnD G k n (fullLog G (C.disk k))) := by
  obtain ⟨-, -, pnone, pterm, -, pquo, ppre, pbey, pch, -⟩ := hp
  have hchain : ∀ t L', (winOwnD G k n (fullLog G (C.disk k))).leader t = some L' →
      ChainIn (ids := ids) (g := g) G L' := by
    intro t L' h
    by_cases ht : t = n.state.hard.term.val
    · simp only [winOwnD, ht, if_true, Option.some.injEq] at h
      subst h; exact pch
    · have h' : G.leader t = some L' := by simpa [winOwnD, ht] using h
      exact (hw.leader t L' h').2.2.2
  have hterms : ∀ t L', (winOwnD G k n (fullLog G (C.disk k))).leader t = some L' → ∀ x ∈ L', x.id.term.val ≤ t := by
    intro t L' h x hx
    by_cases ht : t = n.state.hard.term.val
    · simp only [winOwnD, ht, if_true, Option.some.injEq] at h
      subst h; rw [ht]; exact hs.terms x hx
    · have h' : G.leader t = some L' := by simpa [winOwnD, ht] using h
      exact ((hw.leader t L' h').2.1 x hx).2
  refine ⟨fun t L h => ?_, fun T' c eL' h => ?_, fun Tb w c vlog h => ?_,
    good_preserve e hw.good hchain hterms⟩
  · by_cases ht : t = n.state.hard.term.val
    · subst ht
      simp only [winOwnD, if_true, Option.some.injEq] at h
      subst h
      refine ⟨hcons, fun x hx => ?_, ⟨k, fullLog G (C.disk k), by simp [winOwnD], ppre,
        fun i hi hle => congrArg Fin.val (pbey i hi hle)⟩, pp_committedBy_mono_chain e _ pch⟩
      refine ⟨?_, hs.terms x hx⟩
      obtain ⟨i, hi, rfl⟩ := List.getElem_of_mem hx
      by_cases hlt : i < (fullLog G (C.disk k)).length
      · have := (consistent_terms' G hw _ hconsD ((fullLog G (C.disk k))[i]) (List.getElem_mem _)).1
        rwa [List.IsPrefix.getElem ppre hlt] at this
      · rw [pbey i hi (by omega)]
        omega
    · have h' : G.leader t = some L := by simpa [winOwnD, ht] using h
      obtain ⟨a, b, ⟨c, eL, he, d1, d2⟩, d⟩ := hw.leader t L h'
      exact ⟨consistent_extends e L a, b, ⟨c, eL, by simp [winOwnD, ht, he], d1, d2⟩,
        pp_committedBy_mono_chain e L d⟩
  · by_cases ht : T' = n.state.hard.term.val
    · subst ht
      simp only [winOwnD, if_true, Option.some.injEq, Prod.mk.injEq] at h
      obtain ⟨rfl, rfl⟩ := h
      refine ⟨by omega, consistent_extends e _ hconsD, fun x hx => ?_, ?_⟩
      · have := hD.terms x hx; omega
      · apply quorum_mono _ _ _ _ pquo
        intro id hid
        subst hid
        refine ⟨k, rfl, fullLog G (C.disk k), by simp [winOwnD], Or.inr ⟨rfl, Nat.le_refl _⟩⟩
    · have h' : G.elect T' = some (c, eL') := by simpa [winOwnD, ht] using h
      obtain ⟨a, b, c', d⟩ := hw.elect T' c eL' h'
      refine ⟨a, consistent_extends e _ b, c', ?_⟩
      apply quorum_mono _ _ _ _ d
      intro id ⟨w, hw1, vlog, hb, hu⟩
      exact ⟨w, hw1, vlog, List.mem_cons_of_mem _ hb, hu⟩
  · rcases List.mem_cons.mp h with heq | hold
    · simp only [Prod.mk.injEq] at heq
      obtain ⟨rfl, rfl, rfl, rfl⟩ := heq
      refine ⟨consistent_extends e _ hconsD, fun t j' hack' hlt j hj => ?_⟩
      rcases List.mem_cons.mp hack' with heq | hold
      · simp only [Prod.mk.injEq] at heq; omega
      · left
        have := hacksD t j' hold j hj
        rw [pterm] at this
        exact kept_extends e _ _ _ _ _ this (pp_ackOk_le G t j' j (hack _ _ _ hold) hj)
    · obtain ⟨a, b⟩ := hw.ballot Tb w c vlog hold
      refine ⟨consistent_extends e _ a, fun t j' hack' hlt j hj => ?_⟩
      rcases List.mem_cons.mp hack' with heq | hold'
      · simp only [Prod.mk.injEq] at heq
        obtain ⟨rfl, rfl, rfl⟩ := heq
        exfalso
        rcases hbk Tb c vlog hold with h1 | ⟨-, h2, -⟩ <;> omega
      · have ha := pp_ackOk_le G t j' j (hack _ _ _ hold') hj
        rcases b t j' hold' hlt j hj with hk | ⟨c', eL', he', hne, hnp⟩
        · exact Or.inl (kept_extends e _ _ _ _ _ hk ha)
        · obtain ⟨L, hL, hle⟩ := ha
          exact Or.inr ⟨c', eL', e.elect _ _ he', hne, by rw [prefix_extends e _ _ L hL hle]; exact hnp⟩

/-! ## Election safety for a pending win -/

theorem pp_lcp {α : Type} : ∀ (l1 l2 : List α), ∃ a, a ≤ l1.length ∧ a ≤ l2.length ∧
    l1.take a = l2.take a ∧ ∀ q, q <+: l1 → q <+: l2 → q.length ≤ a
  | [], _ => ⟨0, by simp, by simp, by simp, fun q h1 _ => by have := h1.length_le; simpa using this⟩
  | _ :: _, [] => ⟨0, by simp, by simp, by simp, fun q _ h2 => by have := h2.length_le; simpa using this⟩
  | x :: xs, y :: ys => by
    by_cases hxy : x = y
    · subst hxy
      obtain ⟨a, h1, h2, h3, h4⟩ := pp_lcp xs ys
      refine ⟨a + 1, by simp; omega, by simp; omega, by simp [h3], ?_⟩
      intro q hq1 hq2
      cases q with
      | nil => simp
      | cons z zs =>
        rw [List.cons_prefix_cons] at hq1 hq2
        have := h4 zs hq1.2 hq2.2
        simp; omega
    · refine ⟨0, by simp, by simp, by simp, ?_⟩
      intro q hq1 hq2
      cases q with
      | nil => simp
      | cons z zs =>
        rw [List.cons_prefix_cons] at hq1 hq2
        exact absurd (hq1.1.symm.trans hq2.1) hxy

theorem pp_min (P : Nat → Prop) (n : Nat) (h : P n) : ∃ m, P m ∧ ∀ m' < m, ¬ P m' := by
  induction n using Nat.strongRecOn with
  | _ n ih =>
    by_cases hx : ∃ m' < n, P m'
    · obtain ⟨m', hm', hp⟩ := hx; exact ih m' hm' hp
    · exact ⟨n, h, fun m' hm' hp => hx ⟨m', hm', hp⟩⟩

/-- A quorum of the configuration of a consistent log of terms below `T`, whose
    members kept every acknowledged prefix in that log, meets the voters of the
    election of term `T` (copied from the tick proof). -/
theorem pp_inter (hid : ∀ a b : Fin K, ids[a] = ids[b] → a = b)
    (G : Ghost (Record V MAX) K) (hw : Wf ids g G) (T : Nat) (c : Fin K) (eL' : List (DEntry V MAX))
    (he : G.elect T = some (c, eL')) (l : List (DEntry V MAX)) (hl : Consistent G l)
    (hlt : ∀ e ∈ l, e.id.term.val < T) (P : Id → Prop) (hP : Quorum (cfgOf g l) P)
    (hkept : ∀ id, P id → ∃ w : Fin K, ids[w] = id ∧
      ∀ t j', (w, t, j') ∈ G.acks → t < T → ∀ j ≤ j', Kept G w t j T l) :
    ∃ id, P id ∧ Voters ids G T c eL' id := by
  obtain ⟨hT0, hcons', hlt', hquo'⟩ := hw.elect T c eL' he
  obtain ⟨a, hal, hal', hta, hmax⟩ := pp_lcp l eL'
  have hch := chain_of_consistent G hw l hl
  have hch' := chain_of_consistent G hw eL' hcons'
  have hnear1 : Near (cfgOf g (l.take a)) (cfgOf g l) := by
    apply near_tail l a hch.1
    intro k1 k2 hk2 h1 h12 hc1 hc2
    rcases hch.2 k1 k2 h12 hk2 hc1 hc2 with h0 | ⟨t, j, ht, hc, hp⟩
    · have := congrArg List.length h0; simp only [List.length_take, List.length_nil] at this; omega
    · have hk2T : (l[k2]).id.term.val < T := hlt _ (List.getElem_mem _)
      have hpe := hp.trans (leader_complete hid G hw T c eL' he t j (by omega) hc)
      have := hmax _ (List.take_prefix _ _) hpe
      simp at this; omega
  by_cases hex : ∃ k1 k2, ∃ (h2 : k2 < eL'.length) (h12 : k1 < k2), a ≤ k1 ∧ isCfg (eL'[k1]'(by omega)) ∧ isCfg eL'[k2]
  · exfalso
    obtain ⟨k1, k2, hk2, h12, hak, hc1, hc2⟩ := hex
    obtain ⟨m, ⟨hm2, ham, hmk2, hcm⟩, hmin⟩ := pp_min
      (fun m => ∃ hm : m < eL'.length, a ≤ m ∧ m < k2 ∧ isCfg (eL'[m]'hm)) k1 ⟨by omega, hak, h12, hc1⟩
    have hnoc : ∀ i (hi : i < eL'.length), a ≤ i → i < m → ¬ isCfg eL'[i] :=
      fun i hi h1 h2 hc => hmin i h2 ⟨hi, h1, by omega, hc⟩
    have hcb := hch'.2 m k2 hmk2 hk2 hcm hc2
    have hne : eL'.take (m + 1) ≠ [] := by
      intro h0; have := congrArg List.length h0; simp only [List.length_take, List.length_nil] at this; omega
    have hk2T : (eL'[k2]).id.term.val < T := hlt' _ (List.getElem_mem _)
    obtain ⟨t', j', n', L', ht', hca, hL', hpL', hnear⟩ := hw.good _ _ hcb hne
    have hdrop : (eL'.take (m + 1)).dropLast = eL'.take m := by
      rw [List.dropLast_eq_take]; simp only [List.length_take]; rw [List.take_take]; congr 1; omega
    rw [hdrop] at hnear
    have hcm' : cfgOf g (eL'.take m) = cfgOf g (l.take a) := by
      rw [cfgOf_take_noCfg g eL' a m ham hnoc, hta]
    rw [hcm'] at hnear
    obtain ⟨hj'0, hjn', Lw, hLw, hnL, hterm', hquo⟩ := hca
    rw [hL'] at hLw; cases hLw
    obtain ⟨id, hPid, w, hw1, j'', hj'', hack⟩ := near_inter _ _ _ hnear1 hnear P _ hP hquo
    obtain ⟨w0, hw0, hk⟩ := hkept id hPid
    obtain rfl : w0 = w := hid w0 w (hw0.trans hw1.symm)
    have ht'T : t' < T := by omega
    have hpl : G.prefix t' j' <+: l := by
      rcases hk t' j'' hack ht'T j' hj'' with hp | ⟨t'', h1, h2, c'', eL'', he'', -, hnot⟩
      · exact hp
      · exact absurd (leader_complete hid G hw t'' c'' eL'' he'' t' j' h1
          ⟨n', hj'0, hjn', L', hL', hnL, hterm', hquo⟩) hnot
    rw [prefix_eq_take G t' j' L' hL'] at hpl
    have := hmax _ (hpL'.trans hpl) (List.take_prefix _ _)
    simp at this; omega
  · have hnear2 : Near (cfgOf g (eL'.take a)) (cfgOf g eL') := by
      apply near_tail eL' a hch'.1
      intro k1 k2 hk2 h1 h12 hc1 hc2
      exact hex ⟨k1, k2, hk2, h12, h1, hc1, hc2⟩
    rw [← hta] at hnear2
    exact near_inter _ _ _ hnear1 hnear2 P _ hP hquo'

/-! ## The invariant after saving -/

/-- The invariant after saving node `k`, for a suitable ghost; `pw` says the save records a pending win. -/
theorem pp_persist_inv (C : World V S MAX CAP K) (G G' : Ghost (Record V MAX) K) (hi : Inv ids g C G) (k : Fin K)
    (pw : Prop) (hpw : pw → PendingWin ids g C G k (C.node k)) (hpwk : PendingWin ids g C G k (C.node k) → pw)
    (e : Extends G G') (hwf : Wf ids g G')
    (hcfgs : ∀ t L, G'.leader t = some L → ∀ i (hi : i < L.length) X, recCfg L[i].value = some X → MemOk X)
    (hnew : ∀ t c x, G'.elect t = some (c, x) → G.elect t = some (c, x) ∨
      (pw ∧ t = (C.node k).state.hard.term.val ∧ c = k ∧ x = fullLog G (C.disk k)))
    (helT : pw → G'.elect (C.node k).state.hard.term.val = some (k, fullLog G (C.disk k)))
    (hbal : ∀ b, b ∈ G'.ballots → b ∈ G.ballots ∨
      (pw ∧ b = ((C.node k).state.hard.term.val, k, k, fullLog G (C.disk k))))
    (hacks : ∀ w t j, (w, t, j) ∈ G'.acks → (w, t, j) ∈ G.acks ∨
      (w = k ∧ t = (C.node k).state.hard.term.val ∧ j = (fullLog G (C.node k).state).length ∧
        G'.leader t = some (fullLog G (C.node k).state)))
    (hlead : ∀ t, ((Leading G k (C.node k) ∨ pw) → t ≠ (C.node k).state.hard.term.val) → G'.leader t = G.leader t)
    (hleadT : (Leading G k (C.node k) ∨ pw) →
      G'.leader (C.node k).state.hard.term.val = some (fullLog G (C.node k).state))
    (hcons : Consistent G' (fullLog G (C.node k).state))
    (hcom : CommittedBy ids g G' (C.node k).state.hard.term.val
      ((fullLog G (C.node k).state).take (C.node k).state.hard.commit.val))
    (hpwo : ∀ j, j ≠ k → PendingWin ids g C G j (C.node j) → G'.elect (C.node j).state.hard.term.val = none)
    (hrole : pw → (C.node k).role ≠ .Candidate) :
    Inv ids g (C.persist k ⟨{ C.node k with dirty := false, log_from := none, snapshot_changed := false }⟩) G' := by
  have hsk := (hi.live k).1
  have hfk : fullLog G' (C.node k).state = fullLog G (C.node k).state := fullLog_extends e _ hsk
  have hnotboth : Leading G k (C.node k) → pw → False := by
    intro ⟨x, hx⟩ hp
    rw [(hpw hp).2.2.1] at hx; cases hx
  have hLk : Leading G k (C.node k) ∨ pw → Leading G' k (C.node k) := by
    rintro (⟨x, hx⟩ | hp)
    · exact ⟨x, e.elect _ _ hx⟩
    · exact ⟨_, helT hp⟩
  have hLk' : Leading G' k (C.node k) → Leading G k (C.node k) ∨ pw := by
    intro ⟨x, hx⟩
    rcases hnew _ _ _ hx with h | ⟨hp, -⟩
    · exact Or.inl ⟨x, h⟩
    · exact Or.inr hp
  have hLd : ∀ j, j ≠ k → (Leading G' j (C.node j) ↔ Leading G j (C.node j)) := by
    intro j hj
    constructor
    · intro ⟨x, hx⟩
      rcases hnew _ _ _ hx with h | ⟨-, -, hc, -⟩
      · exact ⟨x, h⟩
      · exact absurd hc hj
    · intro ⟨x, hx⟩; exact ⟨x, e.elect _ _ hx⟩
  -- Another node's term differs from `k`'s when one of them leads it or `k`'s win is recorded.
  have hsep : ∀ j, j ≠ k → ∀ t x, G.elect t = some (j, x) → (Leading G k (C.node k) ∨ pw) →
      t ≠ (C.node k).state.hard.term.val := by
    intro j hj t x hx hor heq
    rw [heq] at hx
    rcases hor with ⟨y, hy⟩ | hp
    · exact hj (pp_elect_inj G _ j k x y hx hy)
    · rw [(hpw hp).2.2.1] at hx; cases hx
  have hPW : ∀ j, j ≠ k → PendingWin ids g C G j (C.node j) →
      PendingWin ids g (C.persist k ⟨{ C.node k with dirty := false, log_from := none, snapshot_changed := false }⟩)
        G' j (C.node j) := by
    intro j hj hp
    have hnone := hpwo j hj hp
    obtain ⟨a1, a2, -, a3, a4, a5, a6, a7, a8, a9⟩ := hp
    have hfD := fullLog_extends e _ (hi.disk j).1
    have hfL := fullLog_extends e _ (hi.live j).1
    unfold PendingWin
    rw [pp_disk_other C k j _ hj, hfD, hfL]
    exact ⟨a1, a2, hnone, a3, a4, a5, a6, a7, pp_committedBy_mono_chain e _ a8, a9⟩
  have hdiskle : ∀ c, (C.disk c).hard.term.val ≤
      ((C.persist k ⟨{ C.node k with dirty := false, log_from := none, snapshot_changed := false }⟩).disk c).hard.term.val := by
    intro c
    by_cases hc : c = k
    · subst hc; rw [pp_disk_self]; exact hi.terms c
    · rw [pp_disk_other C k c _ hc]; exact Nat.le_refl _
  have hED : ∀ T c eL, G'.elect T = some (c, eL) →
      T ≤ ((C.persist k ⟨{ C.node k with dirty := false, log_from := none, snapshot_changed := false }⟩).disk c).hard.term.val := by
    intro T c eL h
    rcases hnew _ _ _ h with h' | ⟨-, hT, hc, -⟩
    · exact Nat.le_trans (hi.elect_disk T c eL h') (hdiskle c)
    · rw [hc, pp_disk_self]; omega
  -- The ballot of a recorded pending win is the only ballot of `k` in its term.
  have hbk : ∀ T w c v, (T, w, c, v) ∈ G.ballots → pw → T = (C.node k).state.hard.term.val → w = k → c = k := by
    intro T w c v h hp hT hw
    subst hw
    obtain ⟨-, -, -, a3, -⟩ := hpw hp
    rcases (hi.ballots T w c v h).1 with h1 | ⟨h1, -, -⟩
    · omega
    · exact h1.symm
  refine
    { wf := hwf
      cfgs := hcfgs
      dyn := fun j => ?dyn
      live := fun j => ?live
      disk := fun j => ?disk
      consistent_disk := fun j => ?cdisk
      consistent_live := fun j => ?clive
      clean := fun j => ?clean
      terms := fun j => ?terms
      disk_lead := fun j eL h => ?disk_lead
      acks := fun w t j h => ?acks
      ballots := fun Tb w c v h => ?ballots
      ballot_unique := ?bu
      ballot_cand := fun Tb w c v h hr ht => ?bcand
      elect := fun T c eL h hd => absurd hd (by have := hED T c eL h; omega)
      elect_disk := hED
      elect_cand := fun T c eL h => ?elect_cand
      lead := fun j hL => ?lead
      leader := fun j hr => ?leader
      candidate := fun j hr => ?candidate
      outbox := fun j i o ho => ?outbox
      outbox_self := fun j => ?outbox_self
      extra := fun j to o ho => ?extra
      sent := fun env h => ?sent
      committed := fun j => ?committed }
  case dyn =>
    by_cases hj : j = k
    · subst hj; rw [pp_node_self]
      have hd := hi.dyn j
      exact dynOk_frame hd rfl rfl rfl rfl rfl rfl rfl hd.layout hd.contig hd.prevoting
    · rw [pp_node_other C k j _ hj]; exact hi.dyn j
  case live =>
    by_cases hj : j = k
    · subst hj; rw [pp_node_self]
      exact ⟨stateOk_extends e _ (hi.live j).1, pp_snapOk_extends g e _ (hi.live j).1 (hi.live j).2⟩
    · rw [pp_node_other C k j _ hj]
      exact ⟨stateOk_extends e _ (hi.live j).1, pp_snapOk_extends g e _ (hi.live j).1 (hi.live j).2⟩
  case disk =>
    by_cases hj : j = k
    · subst hj; rw [pp_disk_self]
      exact ⟨stateOk_extends e _ (hi.live j).1, pp_snapOk_extends g e _ (hi.live j).1 (hi.live j).2⟩
    · rw [pp_disk_other C k j _ hj]
      exact ⟨stateOk_extends e _ (hi.disk j).1, pp_snapOk_extends g e _ (hi.disk j).1 (hi.disk j).2⟩
  case cdisk =>
    by_cases hj : j = k
    · subst hj; rw [pp_disk_self, hfk]; exact hcons
    · rw [pp_disk_other C k j _ hj, fullLog_extends e _ (hi.disk j).1]
      exact consistent_extends e _ (hi.consistent_disk j)
  case clive =>
    by_cases hj : j = k
    · subst hj; rw [pp_node_self]; left
      show Consistent G' (fullLog G' (C.node j).state)
      rw [hfk]; exact hcons
    · rw [pp_node_other C k j _ hj]
      rcases hi.consistent_live j with h | ⟨h1, h2⟩ | h
      · left; rw [fullLog_extends e _ (hi.live j).1]; exact consistent_extends e _ h
      · right; left; exact ⟨h1, (hLd j hj).mpr h2⟩
      · right; right; exact hPW j hj h
  case clean =>
    by_cases hj : j = k
    · subst hj; rw [pp_node_self, pp_disk_self]; intro _; rfl
    · rw [pp_node_other C k j _ hj, pp_disk_other C k j _ hj]; exact hi.clean j
  case terms =>
    by_cases hj : j = k
    · subst hj; rw [pp_node_self, pp_disk_self]; exact Nat.le_refl _
    · rw [pp_node_other C k j _ hj, pp_disk_other C k j _ hj]; exact hi.terms j
  case disk_lead =>
    by_cases hj : j = k
    · subst hj
      rw [pp_disk_self] at h ⊢
      rw [hleadT (hLk' ⟨eL, h⟩), hfk]
    · rw [pp_disk_other C k j _ hj] at h ⊢
      rcases hnew _ _ _ h with h' | ⟨-, -, hc, -⟩
      · rw [hlead _ (hsep j hj _ _ h'), fullLog_extends e _ (hi.disk j).1]
        exact hi.disk_lead j eL h'
      · exact absurd hc hj
  case acks =>
    rcases hacks w t j h with hold | ⟨hw, ht, hj, hL⟩
    · obtain ⟨a, b, c⟩ := hi.acks w t j hold
      refine ⟨pp_ackOk_extends e _ _ a, ?_, fun j' hj' => ?_⟩
      · by_cases hw : w = k
        · subst hw; rw [pp_disk_self]; exact Nat.le_trans b (hi.terms w)
        · rw [pp_disk_other C k w _ hw]; exact b
      · have ha' := pp_ackOk_le G t j j' a hj'
        obtain ⟨c1, c2⟩ := c j' hj'
        by_cases hw : w = k
        · subst hw
          rw [pp_node_self, pp_disk_self]
          show Kept G' w t j' ((C.node w).state.hard.term.val + 1) (fullLog G' (C.node w).state) ∧
            Kept G' w t j' ((C.node w).state.hard.term.val + 1) (fullLog G' (C.node w).state)
          rw [fullLog_extends e _ (hi.live w).1]
          exact ⟨kept_extends e _ _ _ _ _ c1 ha', kept_extends e _ _ _ _ _ c1 ha'⟩
        · rw [pp_node_other C k w _ hw, pp_disk_other C k w _ hw, fullLog_extends e _ (hi.live w).1,
            fullLog_extends e _ (hi.disk w).1]
          exact ⟨kept_extends e _ _ _ _ _ c1 ha', kept_extends e _ _ _ _ _ c2 ha'⟩
    · subst ht hj
      rw [hw]
      have hpre : ∀ j', G'.prefix (C.node k).state.hard.term.val j' <+: fullLog G' (C.node k).state := by
        intro j'
        rw [hfk]
        simp only [Ghost.prefix, hL, Option.getD_some]
        exact List.take_prefix _ _
      refine ⟨⟨_, hL, Nat.le_refl _⟩, ?_, fun j' _ => ?_⟩
      · rw [pp_disk_self]; exact Nat.le_refl _
      · rw [pp_node_self, pp_disk_self]
        exact ⟨Or.inl (hpre j'), Or.inl (hpre j')⟩
  case ballots =>
    rcases hbal _ h with h | ⟨hp, hb⟩
    · obtain ⟨a, b, c', d⟩ := hi.ballots Tb w c v h
      refine ⟨?_, fun hwc => ?_, ?_, ?_⟩
      · by_cases hw : w = k
        · subst hw
          rw [pp_disk_self]
          have ht := hi.terms w
          rcases a with a | ⟨hwc, hd1, he'⟩
          · exact Or.inl (Nat.le_trans a ht)
          · by_cases hlt : (C.disk w).hard.term.val < (C.node w).state.hard.term.val
            · exact Or.inl (by omega)
            · exact Or.inr ⟨hwc, by omega, e.elect _ _ he'⟩
        · rw [pp_disk_other C k w _ hw]
          rcases a with a | ⟨hwc, hd1, he'⟩
          · exact Or.inl a
          · exact Or.inr ⟨hwc, hd1, e.elect _ _ he'⟩
      · by_cases hc : c = k
        · subst hc; rw [pp_disk_self]; exact Nat.le_trans (b hwc) (hi.terms c)
        · rw [pp_disk_other C k c _ hc]; exact b hwc
      · by_cases hw : w = k
        · subst hw; rw [pp_disk_self]; exact d
        · rw [pp_disk_other C k w _ hw]; exact c'
      · by_cases hw : w = k
        · subst hw; rw [pp_node_self]; exact d
        · rw [pp_node_other C k w _ hw]; exact d
    · simp only [Prod.mk.injEq] at hb
      obtain ⟨h1, h2, h3, -⟩ := hb
      subst h1
      rw [h2, h3, pp_disk_self, pp_node_self]
      have hv := (hpw hp).2.2.2.2.1
      exact ⟨Or.inl (Nat.le_refl _), fun h => absurd rfl h, fun _ => hv, fun _ => hv⟩
  case bu =>
    intro T w c c' v v' h1 h2
    rcases hbal _ h1 with h1 | ⟨hp1, hb1⟩ <;> rcases hbal _ h2 with h2 | ⟨hp2, hb2⟩
    · exact hi.ballot_unique T w c c' v v' h1 h2
    · simp only [Prod.mk.injEq] at hb2
      rw [hb2.2.2.1]; exact hbk T w c v h1 hp2 hb2.1 hb2.2.1
    · simp only [Prod.mk.injEq] at hb1
      rw [hb1.2.2.1]; exact (hbk T w c' v' h2 hp1 hb1.1 hb1.2.1).symm
    · simp only [Prod.mk.injEq] at hb1 hb2
      rw [hb1.2.2.1, hb2.2.2.1]
  case bcand =>
    rcases hbal _ h with h | ⟨hp, hb⟩
    · by_cases hc : c = k
      · subst hc
        rw [pp_node_self] at hr ht ⊢
        show upToDate (lastOf (fullLog G' (C.node c).state)) (lastOf v)
        rw [hfk]; exact hi.ballot_cand Tb w c v h hr ht
      · rw [pp_node_other C k c _ hc] at hr ht ⊢
        rw [fullLog_extends e _ (hi.live c).1]; exact hi.ballot_cand Tb w c v h hr ht
    · simp only [Prod.mk.injEq] at hb
      obtain ⟨-, -, h3, -⟩ := hb
      subst h3
      rw [pp_node_self] at hr
      exact absurd hr (hrole hp)
  case elect_cand =>
    rcases hnew _ _ _ h with h' | ⟨hp, -, hc, -⟩
    · by_cases hc : c = k
      · subst hc; rw [pp_node_self]; exact hi.elect_cand T c eL h'
      · rw [pp_node_other C k c _ hc]; exact hi.elect_cand T c eL h'
    · subst hc; rw [pp_node_self]
      intro hrt
      exact hrole hp hrt.1
  case lead =>
    by_cases hj : j = k
    · subst hj
      rw [pp_node_self] at hL ⊢
      have hL0 : Leading G' j (C.node j) := hL
      rcases hLk' hL0 with hLG | hp
      · obtain ⟨⟨eL, he, hpre, hb⟩, -, hch, hc⟩ := hi.lead j hLG
        exact pp_leadLog_saved ids g e j (C.node j) _ rfl hsk ⟨eL, e.elect _ _ he, hpre, hb⟩
          (hleadT (Or.inl hLG)) hch hc
      · obtain ⟨-, -, -, -, -, -, ppre, pbey, pch, pcf⟩ := hpw hp
        exact pp_leadLog_saved ids g e j (C.node j) _ rfl hsk ⟨_, helT hp, ppre, pbey⟩
          (hleadT (Or.inr hp)) pch pcf
    · rw [pp_node_other C k j _ hj] at hL ⊢
      have hL' : Leading G j (C.node j) := (hLd j hj).mp hL
      obtain ⟨x, hx⟩ := hL'
      exact pp_leadLog ids g e j _ (hi.live j).1 (hlead _ (hsep j hj _ _ hx)) (hi.lead j ⟨x, hx⟩)
  case leader =>
    by_cases hj : j = k
    · subst hj
      rw [pp_node_self] at hr ⊢
      obtain ⟨hLP, hok⟩ := hi.leader j hr
      exact ⟨Or.inl (hLk (hLP.imp id hpwk)),
        pp_leaderOk ids e j (C.node j) _ rfl rfl rfl rfl (hi.live j).1 hok⟩
    · rw [pp_node_other C k j _ hj] at hr ⊢
      obtain ⟨hLP, hok⟩ := hi.leader j hr
      exact ⟨hLP.imp (hLd j hj).mpr (hPW j hj),
        pp_leaderOk ids e j (C.node j) _ rfl rfl rfl rfl (hi.live j).1 hok⟩
  case candidate =>
    by_cases hj : j = k
    · subst hj
      rw [pp_node_self] at hr ⊢
      exact pp_candidateOk ids e j (C.node j) (hi.live j).1 (hi.candidate j hr)
    · rw [pp_node_other C k j _ hj] at hr ⊢
      exact pp_candidateOk ids e j (C.node j) (hi.live j).1 (hi.candidate j hr)
  case outbox =>
    by_cases hj : j = k
    · subst hj
      rw [pp_node_self] at ho ⊢
      obtain ⟨to, h1, h2⟩ := hi.outbox j i o ho
      exact ⟨to, h1, pp_outOk ids g C _ e j to o (by rw [pp_node_self]) (by rw [pp_node_self]) rfl (hi.live j).1
        (fun h => by rw [pp_node_self]; exact Or.inl (hLk (h.imp id hpwk))) h2⟩
    · rw [pp_node_other C k j _ hj] at ho ⊢
      obtain ⟨to, h1, h2⟩ := hi.outbox j i o ho
      exact ⟨to, h1, pp_outOk ids g C _ e j to o (by rw [pp_node_other C k j _ hj])
        (by rw [pp_node_other C k j _ hj]) rfl (hi.live j).1
        (fun h => by rw [pp_node_other C k j _ hj]; exact h.imp (hLd j hj).mpr (hPW j hj)) h2⟩
  case outbox_self =>
    by_cases hj : j = k
    · subst hj; rw [pp_node_self]; exact hi.outbox_self j
    · rw [pp_node_other C k j _ hj]; exact hi.outbox_self j
  case extra =>
    by_cases hj : j = k
    · subst hj
      rw [pp_node_self] at ho
      exact pp_outOk ids g C _ e j to o (by rw [pp_node_self]) (by rw [pp_node_self]) rfl (hi.live j).1
        (fun h => by rw [pp_node_self]; exact Or.inl (hLk (h.imp id hpwk))) (hi.extra j to o ho)
    · rw [pp_node_other C k j _ hj] at ho
      exact pp_outOk ids g C _ e j to o (by rw [pp_node_other C k j _ hj])
        (by rw [pp_node_other C k j _ hj]) rfl (hi.live j).1
        (fun h => by rw [pp_node_other C k j _ hj]; exact h.imp (hLd j hj).mpr (hPW j hj)) (hi.extra j to o ho)
  case sent =>
    refine pp_sentOk ids g C _ e (fun t c x hx => ?_) hdiskle (fun c => ?_) env (hi.sent env h)
    · rcases hnew _ _ _ hx with h' | ⟨hp, ht, hc, -⟩
      · exact Or.inl h'
      · right
        obtain ⟨-, -, pnone, pterm, -⟩ := hpw hp
        rw [ht, hc]
        exact ⟨pp_leader_none ids g hi.wf _ pnone, by omega⟩
    · by_cases hc : c = k
      · subst hc; rw [pp_node_self]; exact ⟨rfl, rfl⟩
      · rw [pp_node_other C k c _ hc]; exact ⟨rfl, rfl⟩
  case committed =>
    by_cases hj : j = k
    · subst hj
      rw [pp_disk_self, pp_node_self]
      have hc : CommittedBy ids g G' (C.node j).state.hard.term.val
          ((fullLog G' (C.node j).state).take (C.node j).state.hard.commit.val) := by
        rw [hfk]; exact hcom
      exact ⟨hc, Or.inl hc⟩
    · rw [pp_disk_other C k j _ hj, pp_node_other C k j _ hj, fullLog_extends e _ (hi.disk j).1]
      obtain ⟨a, b⟩ := hi.committed j
      refine ⟨committedBy_mono e _ _ a, ?_⟩
      unfold CommitOk' at b ⊢
      rw [fullLog_extends e _ (hi.live j).1]
      rcases b with b | ⟨b1, b2, b3⟩ | ⟨eL, hp, heL, b3⟩
      · exact Or.inl (committedBy_mono e _ _ b)
      · exact Or.inr (Or.inl ⟨b1, (hLd j hj).mpr b2,
          committedBy_mono (pp_withOwn_mono e j _ (hi.live j).1) _ _ b3⟩)
      · refine Or.inr (Or.inr ⟨eL, hPW j hj hp, ?_, committedBy_mono (pp_winOwn_mono e j _ eL (hi.live j).1) _ _ b3⟩)
        rw [pp_disk_other C k j _ hj, fullLog_extends e _ (hi.disk j).1]; exact heL

include hid hg in
theorem preserve_persist (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (hi : Inv ids g C G) (k : Fin K)
    (ready : Ready (Record V MAX) (Checkpoint S MAX) MAX CAP) (h : Cluster.ready (C.live k) = some ready) :
    ∃ G', Extends G G' ∧ Inv ids g (C.persist k { node := (Ready.persisted ready).node }) G' := by
  unfold Cluster.ready Node.ready Rust.Option.then_some at h
  cases hd : (C.live k).node.dirty with
  | false => simp [hd] at h
  | true =>
    simp [hd] at h
    subst h
    show ∃ G', Extends G G' ∧
      Inv ids g (C.persist k ⟨{ C.node k with dirty := false, log_from := none, snapshot_changed := false }⟩) G'
    have hs := (hi.live k).1
    have hackOk : ∀ w t j, (w, t, j) ∈ G.acks → AckOk G t j := fun w t j h => (hi.acks w t j h).1
    by_cases hL : Leading G k (C.node k)
    · have hnp : PendingWin ids g C G k (C.node k) → False := by
        intro hp; obtain ⟨x, hx⟩ := hL; rw [hp.2.2.1] at hx; cases hx
      have hll := hi.lead k hL
      obtain ⟨⟨eL, h1, h2, h3⟩, ⟨L, h4, h5, -⟩, -, hcf⟩ := hll
      have e := pp_withOwn_extends G k (C.node k) L h4 h5
      have hbeyond : ∀ i (h : i < (fullLog G (C.node k).state).length), eL.length ≤ i →
          ((fullLog G (C.node k).state)[i]).id.term.val = (C.node k).state.hard.term.val :=
        fun i hi' hle => by rw [h3 i hi' hle]
      have hcons := pp_leader_log_consistent G _ hi.wf e _ hs _ eL (hi.wf.elect _ _ _ h1).2.1 h2 hbeyond
        (by simp [withOwnD])
      have hb : ∀ Tb c vlog, (Tb, k, c, vlog) ∈ G.ballots → (C.node k).state.hard.term.val < Tb →
          vlog = fullLog G (C.node k).state := by
        intro Tb c vlog hbv hlt
        have := hi.elect_disk
        obtain ⟨a, -, -, -⟩ := hi.ballots Tb k c vlog hbv
        have ht := hi.terms k
        rcases a with a | ⟨hkc, hd1, he'⟩
        · omega
        · subst hkc
          have := hi.elect_disk Tb _ _ he'
          omega
      refine ⟨_, e, pp_persist_inv ids g C G _ hi k False (fun h => h.elim) hnp e
        (pp_wf_withOwn ids g G hi.wf k _ hs e (hi.lead k hL) hcons hackOk hb)
        ?_ (fun t c x h => Or.inl h) (fun h => h.elim) (fun b h => Or.inl h) ?_ ?_ ?_ hcons ?_
        (fun j _ hp => hp.2.2.1) (fun h => h.elim)⟩
      · intro t L' h i hi' X hX
        by_cases ht : t = (C.node k).state.hard.term.val
        · simp only [withOwnD, ht, if_true, Option.some.injEq] at h
          subst h; exact hcf i hi' X hX
        · have h' : G.leader t = some L' := by simpa [withOwnD, ht] using h
          exact hi.cfgs t L' h' i hi' X hX
      · intro w t j h
        rcases List.mem_cons.mp h with h | h
        · simp only [Prod.mk.injEq] at h
          exact Or.inr ⟨h.1, h.2.1, h.2.2, by rw [h.2.1]; simp [withOwnD]⟩
        · exact Or.inl h
      · intro t ht; simp [withOwnD, ht (Or.inl hL)]
      · intro _; simp [withOwnD]
      · rcases (hi.committed k).2 with c | ⟨-, -, c⟩ | ⟨-, hp, -⟩
        · exact committedBy_mono e _ _ c
        · exact c
        · exact (hnp hp).elim
    by_cases hP : PendingWin ids g C G k (C.node k)
    · have hp := hP
      obtain ⟨-, -, pnone, pterm, -, -, ppre, pbey, -, pcf⟩ := hp
      have hLn := pp_leader_none ids g hi.wf _ pnone
      have e := pp_winOwn_extends G k (C.node k) (fullLog G (C.disk k)) pnone hLn
      have hbeyond : ∀ i (h : i < (fullLog G (C.node k).state).length), (fullLog G (C.disk k)).length ≤ i →
          ((fullLog G (C.node k).state)[i]).id.term.val = (C.node k).state.hard.term.val :=
        fun i hi' hle => by rw [pbey i hi' hle]
      have hcons := pp_leader_log_consistent G _ hi.wf e _ hs _ _ (hi.consistent_disk k) ppre hbeyond
        (by simp [winOwnD])
      have hwf := pp_wf_winOwn ids g C G hi.wf k _ hs (hi.disk k).1 hP e (hi.consistent_disk k) hcons hackOk
        (fun t j' h jj hjj => ((hi.acks k t j' h).2.2 jj hjj).2) (fun Tb c vlog h => (hi.ballots Tb k c vlog h).1)
      refine ⟨_, e, pp_persist_inv ids g C G _ hi k _ id id e hwf ?_ ?_ (fun _ => by simp [winOwnD]) ?_ ?_ ?_
        (fun _ => by simp [winOwnD]) hcons ?_ ?_ ?_⟩
      · intro t L' h i hi' X hX
        by_cases ht : t = (C.node k).state.hard.term.val
        · simp only [winOwnD, ht, if_true, Option.some.injEq] at h
          subst h; exact pcf i hi' X hX
        · have h' : G.leader t = some L' := by simpa [winOwnD, ht] using h
          exact hi.cfgs t L' h' i hi' X hX
      · intro t c x h
        by_cases ht : t = (C.node k).state.hard.term.val
        · simp only [winOwnD, ht, if_true, Option.some.injEq, Prod.mk.injEq] at h
          exact Or.inr ⟨hP, ht, h.1.symm, h.2.symm⟩
        · exact Or.inl (by simpa [winOwnD, ht] using h)
      · intro b h
        rcases List.mem_cons.mp h with h | h
        · exact Or.inr ⟨hP, h⟩
        · exact Or.inl h
      · intro w t j h
        rcases List.mem_cons.mp h with h | h
        · simp only [Prod.mk.injEq] at h
          exact Or.inr ⟨h.1, h.2.1, h.2.2, by rw [h.2.1]; simp [winOwnD]⟩
        · exact Or.inl h
      · intro t ht; simp [winOwnD, ht (Or.inr hP)]
      · rcases (hi.committed k).2 with c | ⟨-, hL', -⟩ | ⟨eL', -, heL, c⟩
        · exact committedBy_mono e _ _ c
        · exact (hL hL').elim
        · subst heL; exact c
      · intro j hj hpj
        by_cases htj : (C.node j).state.hard.term.val = (C.node k).state.hard.term.val
        · exfalso
          obtain ⟨-, -, -, jterm, jvote, jquo, -⟩ := hpj
          have he : (winOwnD G k (C.node k) (fullLog G (C.disk k))).elect (C.node k).state.hard.term.val =
              some (k, fullLog G (C.disk k)) := by simp [winOwnD]
          obtain ⟨id, hid', w, hw1, vlog, hb, -⟩ := pp_inter ids g hid _ hwf _ k _ he (fullLog G (C.disk j))
            (consistent_extends e _ (hi.consistent_disk j))
            (fun x hx => by have := (hi.disk j).1.terms x hx; omega) (fun id => id = ids[j]) jquo
            (by
              intro id hid'
              refine ⟨j, hid'.symm, fun t j' hack htT jj hjj => ?_⟩
              rcases List.mem_cons.mp hack with heq | hold
              · simp only [Prod.mk.injEq] at heq; exact absurd heq.1 hj
              · have := ((hi.acks j t j' hold).2.2 jj hjj).2
                rw [jterm, htj] at this
                exact kept_extends e _ _ _ _ _ this (pp_ackOk_le G t j' jj (hackOk _ _ _ hold) hjj))
          have hwj : w = j := hid w j (hw1.trans hid')
          subst hwj
          rcases List.mem_cons.mp hb with heq | hold
          · simp only [Prod.mk.injEq] at heq; exact hj heq.2.1
          · have := (hi.ballots _ w k vlog hold).2.2.2 htj
            rw [jvote] at this
            exact hj (hid _ _ (Option.some.inj this))
        · simp only [winOwnD, htj, if_false]; exact hpj.2.2.1
      · intro hp hr
        exact hp.2.1 hr
    · have hcons : Consistent G (fullLog G (C.node k).state) := by
        rcases hi.consistent_live k with c | ⟨-, h'⟩ | h'
        · exact c
        · exact absurd h' hL
        · exact absurd h' hP
      refine ⟨G, Extends.refl G, pp_persist_inv ids g C G G hi k False (fun h => h.elim) hP (Extends.refl G)
        hi.wf hi.cfgs (fun t c x h => Or.inl h) (fun h => h.elim) (fun b h => Or.inl h)
        (fun w t j h => Or.inl h) (fun t _ => rfl) (fun h => absurd (h.resolve_right id) hL) hcons ?_
        (fun j _ hp => hp.2.2.1) (fun h => h.elim)⟩
      rcases (hi.committed k).2 with c | ⟨-, h', -⟩ | ⟨-, h', -⟩
      · exact c
      · exact absurd h' hL
      · exact absurd h' hP

/-- At most one node holds a pending win of a given term: recording one of them
    would make the other's own-vote quorum a voter for it. -/
theorem pending_unique (hid : ∀ a b : Fin K, ids[a] = ids[b] → a = b) (C : World V S MAX CAP K)
    (G : Ghost (Record V MAX) K) (hi : Inv ids g C G) (k j : Fin K)
    (hP : PendingWin ids g C G k (C.node k)) (hpj : PendingWin ids g C G j (C.node j))
    (htj : (C.node j).state.hard.term.val = (C.node k).state.hard.term.val) : j = k := by
  apply Classical.byContradiction; intro hj
  have hs := (hi.live k).1
  have hackOk : ∀ w t j, (w, t, j) ∈ G.acks → AckOk G t j := fun w t j h => (hi.acks w t j h).1
  have hP0 := hP
  obtain ⟨-, -, pnone, pterm, -, -, ppre, pbey, -, pcf⟩ := hP0
  have hLn := pp_leader_none ids g hi.wf _ pnone
  have e := pp_winOwn_extends G k (C.node k) (fullLog G (C.disk k)) pnone hLn
  have hbeyond : ∀ i (h : i < (fullLog G (C.node k).state).length), (fullLog G (C.disk k)).length ≤ i →
      ((fullLog G (C.node k).state)[i]).id.term.val = (C.node k).state.hard.term.val :=
    fun i hi' hle => by rw [pbey i hi' hle]
  have hcons := pp_leader_log_consistent G _ hi.wf e _ hs _ _ (hi.consistent_disk k) ppre hbeyond
    (by simp [winOwnD])
  have hwf := pp_wf_winOwn ids g C G hi.wf k _ hs (hi.disk k).1 hP e (hi.consistent_disk k) hcons hackOk
    (fun t j' h jj hjj => ((hi.acks k t j' h).2.2 jj hjj).2) (fun Tb c vlog h => (hi.ballots Tb k c vlog h).1)
  obtain ⟨-, -, -, jterm, jvote, jquo, -⟩ := hpj
  have he : (winOwnD G k (C.node k) (fullLog G (C.disk k))).elect (C.node k).state.hard.term.val =
      some (k, fullLog G (C.disk k)) := by simp [winOwnD]
  obtain ⟨id, hid', w, hw1, vlog, hb, -⟩ := pp_inter ids g hid _ hwf _ k _ he (fullLog G (C.disk j))
    (consistent_extends e _ (hi.consistent_disk j))
    (fun x hx => by have := (hi.disk j).1.terms x hx; omega) (fun id => id = ids[j]) jquo
    (by
      intro id hid'
      refine ⟨j, hid'.symm, fun t j' hack htT jj hjj => ?_⟩
      rcases List.mem_cons.mp hack with heq | hold
      · simp only [Prod.mk.injEq] at heq; exact absurd heq.1 hj
      · have := ((hi.acks j t j' hold).2.2 jj hjj).2
        rw [jterm, htj] at this
        exact kept_extends e _ _ _ _ _ this (pp_ackOk_le G t j' jj (hackOk _ _ _ hold) hjj))
  have hwj : w = j := hid w j (hw1.trans hid')
  subst hwj
  rcases List.mem_cons.mp hb with heq | hold
  · simp only [Prod.mk.injEq] at heq; exact hj heq.2.1
  · have := (hi.ballots _ w k vlog hold).2.2.2 htj
    rw [jvote] at this
    exact hj (hid _ _ (Option.some.inj this))

end Jarl.Engine.Dyn
