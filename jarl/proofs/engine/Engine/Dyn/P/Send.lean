import Engine.Dyn.Common
import Engine.Dyn.OpNext

/-!
# Preservation: sending and dropping messages
-/

set_option linter.unusedSectionVars false

namespace Jarl.Engine.Dyn
open Jarl Jarl.Engine

variable {V S : Type} {MAX CAP K : Nat} [Rust.Clone V] [Rust.Clone S]

/-- The ghost with the same leader logs and elections, and new acks and ballots. -/
private def growS (G : Ghost (Record V MAX) K) (A : List (Fin K × Nat × Nat))
    (B : List (Nat × Fin K × Fin K × List (Entry (Record V MAX)))) : Ghost (Record V MAX) K :=
  ⟨G.leader, G.elect, A, B⟩

private theorem growS_extends (G : Ghost (Record V MAX) K) (A : List (Fin K × Nat × Nat))
    (B : List (Nat × Fin K × Fin K × List (Entry (Record V MAX))))
    (ha : ∀ a ∈ G.acks, a ∈ A) (hb : ∀ b ∈ G.ballots, b ∈ B) : Extends G (growS G A B) :=
  ⟨fun _ L h => ⟨L, h, List.prefix_refl L⟩, fun _ _ h => h, ha, hb⟩

private theorem send_prefix_prefix (G : Ghost (Record V MAX) K) (t j i : Nat) (h : j ≤ i) :
    G.prefix t j <+: G.prefix t i := by
  unfold Ghost.prefix
  rw [show ((G.leader t).getD []).take j = (((G.leader t).getD []).take i).take j by
    rw [List.take_take, Nat.min_eq_left h]]
  exact List.take_prefix _ _

private theorem prefix_take_le' {α : Type} (L : List α) (a b : Nat) (h : a ≤ b) : L.take a <+: L.take b := by
  rw [show L.take a = (L.take b).take a by rw [List.take_take, Nat.min_eq_left h]]
  exact List.take_prefix _ _

variable (ids : Vector Id K) (g : Membership MAX) (hid : ∀ a b : Fin K, ids[a] = ids[b] → a = b) (hg : MemOk g)

/-- An updated outbox or reply slot: only descriptors are dropped. -/
private theorem send_localOk (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (hi : Inv ids g C G) (k : Fin K)
    (O : Vector (Option Outbound) MAX) (E : Option (Id × Outbound))
    (hO : ∀ j : Fin MAX, O[j] = (C.node k).outbox[j] ∨ O[j] = none)
    (hE : E = (C.node k).extra_reply ∨ E = none) :
    LocalOk' ids g C G k ⟨{ C.node k with outbox := O, extra_reply := E }⟩ := by
  have hoo : ∀ to o, OutOk ids g (C.setLive k ⟨{ C.node k with outbox := O, extra_reply := E }⟩) G k to o ↔
      OutOk ids g C G k to o := by
    intro to o; unfold OutOk; simp only [setLive_self', setLive_sent, pendingWin_setLive]; exact Iff.rfl
  refine
    { dyn := dynOk_frame (hi.dyn k) rfl rfl rfl rfl rfl rfl rfl (hi.dyn k).layout (hi.dyn k).contig (hi.dyn k).prevoting
      live := hi.live k
      consistent := (hi.consistent_live k).imp id (Or.imp id (pendingWin_setLive ids g C G k k _ _).mpr)
      clean := hi.clean k
      terms := hi.terms k
      acks := fun t j h j' hj' => ((hi.acks k t j h).2.2 j' hj').1
      ballots := fun T c v h => (hi.ballots T k c v h).2.2.2
      ballot_cand := fun hr T w v h ht => hi.ballot_cand T w k v h hr ht
      elect := fun T eL h hd => (hi.elect T k eL h hd).2.2.2
      elect_cand := fun T eL h => hi.elect_cand T k eL h
      lead := fun hl => let h := hi.lead k hl; ⟨h.elected, h.log, h.chain, h.cfgs⟩
      leader := fun hr => let h := hi.leader k hr; ⟨h.1.imp id (pendingWin_setLive ids g C G k k _ _).mpr, h.2.matched, h.2.own⟩
      candidate := hi.candidate k
      outbox := fun j o h => ?_
      outbox_self := fun hl => ?_
      extra := fun to o h => ?_
      votes := fun env h T last hf hm => ?_
      committed := ?_ }
  · have ho : (C.node k).outbox[j] = some o := by
      rcases hO j with e | e
      · rw [← e]; exact h
      · exact absurd (e ▸ h) (by simp)
    obtain ⟨to, h1, h2⟩ := hi.outbox k j o ho
    exact ⟨to, h1, (hoo to o).mpr h2⟩
  · intro o h
    rcases hO ⟨(C.node k).local.val, hl⟩ with e | e
    · exact hi.outbox_self k hl o (e.symm.trans h)
    · exact absurd (e.symm.trans h) (by simp)
  · have : (C.node k).extra_reply = some (to, o) := by
      rcases hE with e | e
      · rw [← e]; exact h
      · exact absurd (e ▸ h) (by simp)
    exact (hoo to o).mpr (hi.extra k to o this)
  · have hs := hi.sent env h
    unfold SentOk at hs
    rw [hm] at hs
    exact (hs.2 k hf).2.1
  · rcases (hi.committed k).2 with h | h | ⟨eL, hp, h2⟩
    · exact Or.inl h
    · exact Or.inr (Or.inl h)
    · exact Or.inr (Or.inr ⟨eL, (pendingWin_setLive ids g C G k k _ _).mpr hp, h2⟩)

/-- Recording a new message. -/
private theorem send_inv_send (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K)
    (hi : Inv ids g C G) (env : DEnv V S MAX) (hs : SentOk ids g C G env) :
    Inv ids g { C with sent := env :: C.sent } G := by
  have hoo : ∀ k to o, OutOk ids g C G k to o → OutOk ids g { C with sent := env :: C.sent } G k to o := by
    intro k to o ho
    cases o with
    | Voted gr =>
      intro hg
      obtain ⟨a, last, b, c⟩ := ho hg
      exact ⟨a, last, List.mem_cons_of_mem _ b, c⟩
    | _ => exact ho
  refine
    { wf := hi.wf
      cfgs := hi.cfgs
      dyn := hi.dyn
      live := hi.live
      disk := hi.disk
      consistent_disk := hi.consistent_disk
      consistent_live := hi.consistent_live
      clean := hi.clean
      terms := hi.terms
      disk_lead := hi.disk_lead
      acks := hi.acks
      ballots := hi.ballots
      ballot_unique := hi.ballot_unique
      ballot_cand := hi.ballot_cand
      elect := hi.elect
      elect_disk := hi.elect_disk
      elect_cand := hi.elect_cand
      lead := hi.lead
      leader := hi.leader
      candidate := hi.candidate
      outbox := fun k j o h => ?_
      outbox_self := hi.outbox_self
      extra := fun k to o h => hoo k to o (hi.extra k to o h)
      sent := fun e h => ?_
      committed := hi.committed }
  · obtain ⟨to, h1, h2⟩ := hi.outbox k j o h
    exact ⟨to, h1, hoo k to o h2⟩
  · rcases List.mem_cons.mp h with rfl | h
    · exact hs
    · exact hi.sent e h

private theorem send_withOwn_grow (G : Ghost (Record V MAX) K) (A : List (Fin K × Nat × Nat))
    (B : List (Nat × Fin K × Fin K × List (Entry (Record V MAX))))
    (ha : ∀ a ∈ G.acks, a ∈ A) (hb : ∀ b ∈ G.ballots, b ∈ B) (k : Fin K) (n : DNode V S MAX CAP) :
    Extends (withOwnD G k n) (withOwnD (growS G A B) k n) := by
  refine ⟨fun _ L h => ⟨L, h, List.prefix_refl L⟩, fun _ _ h => h, fun a h => ?_, hb⟩
  simp only [withOwnD, List.mem_cons] at h ⊢
  rcases h with h | h
  · exact Or.inl h
  · exact Or.inr (ha _ h)

private theorem send_winOwn_grow (G : Ghost (Record V MAX) K) (A : List (Fin K × Nat × Nat))
    (B : List (Nat × Fin K × Fin K × List (Entry (Record V MAX))))
    (ha : ∀ a ∈ G.acks, a ∈ A) (hb : ∀ b ∈ G.ballots, b ∈ B) (k : Fin K) (n : DNode V S MAX CAP)
    (eL : List (DEntry V MAX)) :
    Extends (winOwnD G k n eL) (winOwnD (growS G A B) k n eL) := by
  refine ⟨fun _ L h => ⟨L, h, List.prefix_refl L⟩, fun _ _ h => h, fun a h => ?_, fun b h => ?_⟩
  · simp only [winOwnD, List.mem_cons] at h ⊢
    rcases h with h | h
    · exact Or.inl h
    · exact Or.inr (ha _ h)
  · simp only [winOwnD, List.mem_cons] at h ⊢
    rcases h with h | h
    · exact Or.inl h
    · exact Or.inr (hb _ h)

/-- Growing the acknowledgments and ballots preserves the invariant, given the
    obligations of the new elements. -/
private theorem send_inv_grow (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K)
    (hi : Inv ids g C G) (A : List (Fin K × Nat × Nat)) (B : List (Nat × Fin K × Fin K × List (Entry (Record V MAX))))
    (ha : ∀ a ∈ G.acks, a ∈ A) (hb : ∀ b ∈ G.ballots, b ∈ B)
    (wb_new : ∀ T w c vlog, (T, w, c, vlog) ∈ B → (T, w, c, vlog) ∉ G.ballots → Consistent G vlog ∧
      ∀ t j', (w, t, j') ∈ A → t < T → ∀ j ≤ j',
        Kept G w t j T vlog ∨ ∃ c' eL', G.elect T = some (c', eL') ∧ c' ≠ c ∧ ¬ G.prefix t j <+: eL')
    (wb_old : ∀ T w c vlog, (T, w, c, vlog) ∈ G.ballots → ∀ t j', (w, t, j') ∈ A → (w, t, j') ∉ G.acks →
      t < T → ∀ j ≤ j', Kept G w t j T vlog ∨ ∃ c' eL', G.elect T = some (c', eL') ∧ c' ≠ c ∧ ¬ G.prefix t j <+: eL')
    (acks_new : ∀ w t j, (w, t, j) ∈ A → (w, t, j) ∉ G.acks → AckOk G t j ∧ t ≤ (C.disk w).hard.term.val ∧
      ∀ j' ≤ j, Kept G w t j' ((C.node w).state.hard.term.val + 1) (fullLog G (C.node w).state) ∧
        Kept G w t j' ((C.disk w).hard.term.val + 1) (fullLog G (C.disk w)))
    (ballots_new : ∀ T w c vlog, (T, w, c, vlog) ∈ B → (T, w, c, vlog) ∉ G.ballots →
      (T ≤ (C.disk w).hard.term.val ∨
        (w = c ∧ (C.disk w).hard.term.val + 1 = T ∧ G.elect T = some (c, vlog))) ∧ (w ≠ c → T ≤ (C.disk c).hard.term.val) ∧
      ((C.disk w).hard.term.val = T → (C.disk w).hard.voted_for = some ids[c]) ∧
      ((C.node w).state.hard.term.val = T → (C.node w).state.hard.voted_for = some ids[c]))
    (bu : ∀ T w c c' v v', (T, w, c, v) ∈ B → (T, w, c', v') ∈ B → c = c')
    (bc : ∀ T w c vlog, (T, w, c, vlog) ∈ B → (T, w, c, vlog) ∉ G.ballots → (C.node c).role = .Candidate →
      (C.node c).state.hard.term.val = T → upToDate (lastOf (fullLog G (C.node c).state)) (lastOf vlog)) :
    Inv ids g C (growS G A B) := by
  have E := growS_extends G A B ha hb
  have chainM : ∀ L, ChainIn (ids := ids) (g := g) G L → ChainIn (ids := ids) (g := g) (growS G A B) L :=
    fun L h => ⟨h.1, fun a b hab hb' h1 h2 => committedBy_mono E _ _ (h.2 a b hab hb' h1 h2)⟩
  have pwG : ∀ k n, PendingWin ids g C G k n → PendingWin ids g C (growS G A B) k n :=
    fun k n ⟨a, r, b, c, d, e, f, h, ch, m⟩ => ⟨a, r, b, c, d, e, f, h, chainM _ ch, m⟩
  have ooG : ∀ k to o, OutOk ids g C G k to o → OutOk ids g C (growS G A B) k to o := by
    intro k to o h
    cases o with
    | Replicate => exact Or.imp id (pwG _ _) h
    | _ => exact h
  have stG : ∀ s : DState V S MAX CAP, StateOk G s → StateOk (growS G A B) s :=
    fun s h => ⟨h.layout, h.contig, h.base, h.snapshot, h.terms, h.commit_ge, h.commit_le, h.unvoted⟩
  refine
    { wf := ?_
      cfgs := hi.cfgs
      dyn := hi.dyn
      live := fun k => ⟨stG _ (hi.live k).1, (hi.live k).2⟩
      disk := fun k => ⟨stG _ (hi.disk k).1, (hi.disk k).2⟩
      consistent_disk := hi.consistent_disk
      consistent_live := fun k => (hi.consistent_live k).imp id (Or.imp id (pwG _ _))
      clean := hi.clean
      terms := hi.terms
      disk_lead := hi.disk_lead
      acks := fun w t j h => ?_
      ballots := fun T w c v h => ?_
      ballot_unique := bu
      ballot_cand := fun T w c v h => ?_
      elect := hi.elect
      elect_disk := hi.elect_disk
      elect_cand := hi.elect_cand
      lead := fun k hl => ?_
      leader := fun k hr => ?_
      candidate := fun k hr => ?_
      outbox := fun k j o h => let ⟨to, a, b⟩ := hi.outbox k j o h; ⟨to, a, ooG _ _ _ b⟩
      outbox_self := hi.outbox_self
      extra := fun k to o h => ooG _ _ _ (hi.extra k to o h)
      sent := fun env h => ?_
      committed := fun k => ?_ }
  · refine ⟨fun t L h => ?_, fun T c eL h => ?_, fun T w c vlog h => ?_, ?_⟩
    · obtain ⟨a, b, d, ch⟩ := hi.wf.leader t L h
      exact ⟨a, b, d, chainM L ch⟩
    · obtain ⟨z, a, b, m⟩ := hi.wf.elect T c eL h
      exact ⟨z, a, b, quorum_mono _ _ _ (fun id ⟨w, hw, v, hv, hu⟩ => ⟨w, hw, v, hb _ hv, hu⟩) m⟩
    · by_cases hold : (T, w, c, vlog) ∈ G.ballots
      · obtain ⟨hc, hk⟩ := hi.wf.ballot T w c vlog hold
        refine ⟨hc, fun t j' hm ht j hj => ?_⟩
        by_cases hm' : (w, t, j') ∈ G.acks
        · exact hk t j' hm' ht j hj
        · exact wb_old T w c vlog hold t j' hm hm' ht j hj
      · exact wb_new T w c vlog h hold
    · exact good_preserve E hi.wf.good (fun t L' h => (hi.wf.leader t L' h).2.2.2)
        (fun t L' h e he => ((hi.wf.leader t L' h).2.1 e he).2)
  · by_cases hold : (w, t, j) ∈ G.acks
    · exact hi.acks w t j hold
    · exact acks_new w t j h hold
  · by_cases hold : (T, w, c, v) ∈ G.ballots
    · exact hi.ballots T w c v hold
    · exact ballots_new T w c v h hold
  · by_cases hold : (T, w, c, v) ∈ G.ballots
    · exact hi.ballot_cand T w c v hold
    · exact bc T w c v h hold
  · have h := hi.lead k hl
    exact ⟨h.elected, h.log, chainM _ h.chain, h.cfgs⟩
  · have h := hi.leader k hr
    exact ⟨h.1.imp id (pwG _ _), fun j hj hp => let ⟨w, a, b⟩ := h.2.matched j hj hp; ⟨w, a, ha _ b⟩, h.2.own⟩
  · obtain ⟨a1, a2, b⟩ := hi.candidate k hr
    exact ⟨a1, a2, fun j hj => (b j hj).imp id (fun ⟨w, hw, v, hv, hu⟩ => ⟨w, hw, v, hb _ hv, hu⟩)⟩
  · have hs := hi.sent env h
    unfold SentOk at hs ⊢
    refine ⟨hs.1, ?_⟩
    have h2 := hs.2
    revert h2
    cases env.message with
    | Voted T gr => intro h2 hg w c hw hc
                    exact (h2 hg w c hw hc).imp (fun ⟨v, hv⟩ => ⟨v, hb _ hv⟩) id
    | Replicated T i r => intro h2 hr w hw; exact ha _ (h2 hr w hw)
    | Append T prev e cm =>
      intro ⟨L, a, b, c, d, f, f'⟩
      exact ⟨L, a, b, c, d, committedBy_mono E _ _ f, f'⟩
    | AppendBatch T prev es cm =>
      intro ⟨L, a, b, c, d, f, f'⟩
      exact ⟨L, a, b, c, d, committedBy_mono E _ _ f, f'⟩
    | Install T snap =>
      intro ⟨L, a, b, c, d, f, f'⟩
      exact ⟨L, a, b, c, committedBy_mono E _ _ d, f, f'⟩
    | _ => intro h2; exact h2
  · refine ⟨committedBy_mono E _ _ (hi.committed k).1, ?_⟩
    rcases (hi.committed k).2 with h | ⟨r, d, h⟩ | ⟨eL, hp, he, h⟩
    · exact Or.inl (committedBy_mono E _ _ h)
    · exact Or.inr (Or.inl ⟨r, d, committedBy_mono (send_withOwn_grow G A B ha hb k (C.node k)) _ _ h⟩)
    · exact Or.inr (Or.inr ⟨eL, pwG _ _ hp, he, committedBy_mono (send_winOwn_grow G A B ha hb k (C.node k) eL) _ _ h⟩)

private theorem send_cluster_nm (c0 : Jarl.Cluster V S MAX CAP) (r : Option (DEnv V S MAX)) (c : Jarl.Cluster V S MAX CAP)
    (h : Cluster.next_message c0 = pure (r, c)) : Node.next_message c0.node = pure (r, c.node) := by
  unfold Cluster.next_message at h
  obtain ⟨⟨r', m⟩, h1, h2⟩ := Rust.bind_eq_pure h
  have h3 := Rust.pure_inj h2
  simp only [Prod.mk.injEq] at h3
  obtain ⟨rfl, rfl⟩ := h3
  exact h1

/-- An entry `State.get` reads is the full log's entry at its index. -/
private theorem send_get_inLog (G : Ghost (Record V MAX) K) (s : DState V S MAX CAP) (hok : StateOk G s)
    (hc : Consistent G (fullLog G s)) (i : Rust.u64) (e : DEntry V MAX) (he : State.get s i = some e) :
    InLog (fullLog G s) e ∧ e.id.index.val = i.val := by
  rw [get_eq _ hok.layout] at he
  by_cases hlt : s.base.index.val < i.val
  · rw [if_pos hlt] at he
    obtain ⟨hr, hre⟩ := List.getElem?_eq_some_iff.mp he
    have hlen := fullLog_length G s hok
    have hlast := lastId_eq s hok.contig
    have hl : i.val - 1 < (fullLog G s).length := by omega
    obtain ⟨hr', hg⟩ := fullLog_getElem_ret G s hok (i.val - 1) (by omega) hl
    have hx : (fullLog G s)[i.val - 1] = e := by
      rw [hg, ← hre]; congr 1; omega
    have hidx := (hc _ hl).1
    rw [hx] at hidx
    refine ⟨⟨by omega, ?_⟩, by omega⟩
    simp only [hidx, show i.val - 1 + 1 - 1 = i.val - 1 by omega]
    exact hx
  · rw [if_neg hlt] at he; cases he

include hid hg in
theorem preserve_drain (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (hi : Inv ids g C G) (k : Fin K)
    (c : Jarl.Cluster V S MAX CAP) (h : Cluster.next_message (C.live k) = pure (none, c)) :
    ∃ G', Extends G G' ∧ Inv ids g (C.setLive k c) G' := by
  have hN := next_message_rel' (C.node k) (hi.dyn k).pre _ _ (send_cluster_nm _ _ _ h)
  have hc : c = ⟨c.node⟩ := rfl
  refine ⟨G, Extends.refl G, setLive_inv' ids g C G hi k c ?_⟩
  rcases hN with ⟨-, hN⟩ | ⟨env, he, -⟩
  · rcases hN with e | ⟨-, -, e⟩ | ⟨-, j, to, -, -, -, e, -⟩
    · rw [hc, e]
      exact send_localOk ids g C G hi k _ _ (fun j => Or.inl rfl) (Or.inl rfl)
    · rw [hc, e]
      exact send_localOk ids g C G hi k _ _ (fun j => Or.inl rfl) (Or.inr rfl)
    · rw [hc, e]
      refine send_localOk ids g C G hi k _ _ (fun i => ?_) (Or.inl rfl)
      by_cases hij : i = j
      · subst hij; right; simp
      · left; simp only [Fin.getElem_fin]; rw [Vector.getElem_set_ne]; intro h; exact hij (Fin.ext h.symm)
  · cases he

/-- The predecessor identity of a replication request is the full log's. -/
private theorem send_prevOk (G : Ghost (Record V MAX) K) (s : DState V S MAX CAP) (hok : StateOk G s)
    (hc : Consistent G (fullLog G s)) (x : Nat) (prev : LogId) (hp : idAt s x = some prev) :
    prev.index.val = x ∧ PrevOk (fullLog G s) prev := by
  by_cases hx : x = 0
  · subst hx
    obtain ⟨-, rfl⟩ := (idAt_zero G s hok prev).mp hp
    exact ⟨rfl, fun h => absurd h (by decide), fun _ => rfl⟩
  · obtain ⟨-, hl, hpid⟩ := (idAt_fullLog G s hok x (by omega) prev).mp hp
    have hidx := (hc _ hl).1
    rw [hpid] at hidx
    have hpx : prev.index.val = x := by omega
    refine ⟨hpx, fun _ => ?_, fun h0 => absurd h0 (by omega)⟩
    rw [hpx]; exact ⟨hl, hpid⟩

private theorem send_C1 (C : World V S MAX CAP K) (k : Fin K) (O : Vector (Option Outbound) MAX)
    (E : Option (Id × Outbound)) (j : Fin K) :
    ((C.setLive k ⟨{ C.node k with outbox := O, extra_reply := E }⟩).node j).state = (C.node j).state ∧
    ((C.setLive k ⟨{ C.node k with outbox := O, extra_reply := E }⟩).node j).role = (C.node j).role := by
  by_cases hj : j = k
  · subst hj; rw [setLive_self']; exact ⟨rfl, rfl⟩
  · rw [setLive_other' _ _ _ _ hj]; exact ⟨rfl, rfl⟩

include hid hg in
theorem preserve_send (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (hi : Inv ids g C G) (k : Fin K)
    (env : DEnv V S MAX) (c : Jarl.Cluster V S MAX CAP) (h : Cluster.next_message (C.live k) = pure (some env, c)) :
    ∃ G', Extends G G' ∧ Inv ids g { C.setLive k c with sent := env :: C.sent } G' := by
  obtain ⟨cn⟩ := c
  have hN := next_message_rel' (C.node k) (hi.dyn k).pre _ _ (send_cluster_nm _ _ _ h)
  rcases hN with ⟨he, -⟩ | ⟨env', he, hd, hfrom0, hN⟩
  · cases he
  obtain rfl : env = env' := Option.some.inj he
  obtain ⟨O, E, o, to, ko, hO, hE, hcn, hto, hout, hb⟩ : ∃ (O : Vector (Option Outbound) MAX)
      (E : Option (Id × Outbound)) (o : Outbound) (to : Id) (ko : Option (Fin MAX)),
      (∀ j : Fin MAX, O[j] = (C.node k).outbox[j] ∨ O[j] = none) ∧ (E = (C.node k).extra_reply ∨ E = none) ∧
      cn = { C.node k with outbox := O, extra_reply := E } ∧ env.to = to ∧ OutOk ids g C G k to o ∧
      BuiltD (C.node k) ko o env.message := by
    rcases hN with ⟨kk, o, to, -, ho, hp, hto, e, hb⟩ | ⟨o, to, -, hx, hto, e, hb⟩
    · obtain ⟨to', hp', hok⟩ := hi.outbox k kk o ho
      rw [hp] at hp'
      obtain rfl := Option.some.inj hp'
      refine ⟨_, _, o, to, some kk, fun i => ?_, Or.inl rfl, e, hto, hok, hb⟩
      by_cases hij : i = kk
      · subst hij; right; simp
      · left; simp only [Fin.getElem_fin]; rw [Vector.getElem_set_ne]; intro h; exact hij (Fin.ext h.symm)
    · exact ⟨_, _, o, to, none, fun i => Or.inl rfl, Or.inr rfl, e, hto, hi.extra k to o hx, hb⟩
  subst hcn
  have hi1 := setLive_inv' ids g C G hi k _ (send_localOk ids g C G hi k O E hO hE)
  have hC1 := send_C1 C k O E
  have hfrom : env.from = ids[k] := by rw [hfrom0]; exact (hi.dyn k).id
  have hw : ∀ w : Fin K, env.from = ids[w] → w = k := fun w e => hid w k (e.symm.trans hfrom)
  have hs : (C.node k).state = C.disk k := hi.clean k hd
  have hT : (C.node k).state.hard.term.val = (C.disk k).hard.term.val := by rw [hs]
  have hok := (hi.live k).1
  have hcons : Consistent G (fullLog G (C.node k).state) := by rw [hs]; exact hi.consistent_disk k
  have hcom : CommittedBy ids g G (C.node k).state.hard.term.val
      ((fullLog G (C.node k).state).take (C.node k).state.hard.commit.val) := by
    rcases (hi.committed k).2 with h | ⟨hd', -⟩ | ⟨-, ⟨hd', -⟩, -⟩
    · exact h
    · rw [hd] at hd'; cases hd'
    · rw [hd] at hd'; cases hd'
  have hlead : OutOk ids g C G k to .Replicate → Leading G k (C.node k) := by
    rintro (h | ⟨hd', -⟩)
    · exact h
    · rw [hd] at hd'; cases hd'
  generalize hm : env.message = msg at hb
  cases hb with
  | vote =>
    have hr : (C.node k).role = .Candidate := hout
    refine ⟨G, Extends.refl G, send_inv_send ids g _ G hi1 env ?_⟩
    unfold SentOk; rw [hm]
    refine ⟨⟨k, hfrom⟩, fun c hc' => ?_⟩
    obtain rfl := hw c hc'
    refine ⟨Nat.le_of_eq hT, fun _ => by rw [(hC1 c).1], fun eL he => absurd ⟨hr, rfl⟩ (hi.elect_cand _ c eL he)⟩
  | voted _ gr =>
    cases gr with
    | false =>
      refine ⟨G, Extends.refl G, send_inv_send ids g _ G hi1 env ?_⟩
      unfold SentOk; rw [hm]
      exact ⟨⟨k, hfrom⟩, fun h => by cases h⟩
    | true =>
      obtain ⟨hvf, last, hvm, hup⟩ := hout rfl
      by_cases hcx : ¬ ∃ cc : Fin K, ids[cc] = to
      · refine ⟨G, Extends.refl G, send_inv_send ids g _ G hi1 env ?_⟩
        unfold SentOk; rw [hm]
        exact ⟨⟨k, hfrom⟩, fun _ w c _ hc' => absurd ⟨c, hc'.symm.trans hto⟩ hcx⟩
      obtain ⟨j, rfl⟩ := Classical.not_not.mp hcx
      have hc : ∀ c : Fin K, env.to = ids[c] → c = j := fun c e => hid c j (e.symm.trans hto)
      by_cases hel : ∃ eL, G.elect (C.node k).state.hard.term.val = some (j, eL)
      · refine ⟨G, Extends.refl G, send_inv_send ids g _ G hi1 env ?_⟩
        unfold SentOk; rw [hm]
        refine ⟨⟨k, hfrom⟩, fun _ w c _ hc' => ?_⟩
        obtain rfl := hc c hc'
        exact Or.inr hel
      · have hvs := (hi.sent _ hvm).2
        refine ⟨growS G G.acks (((C.node k).state.hard.term.val, k, j, fullLog G (C.node k).state) :: G.ballots),
          growS_extends G _ _ (fun a h => h) (fun b h => List.mem_cons_of_mem _ h),
          send_inv_send ids g _ _ ?_ env ?_⟩
        · apply send_inv_grow ids g _ G hi1 _ _ (fun a h => h) (fun b h => List.mem_cons_of_mem _ h)
          · intro T w c vlog hmem hnot
            rcases List.mem_cons.mp hmem with e | e
            · simp only [Prod.mk.injEq] at e
              obtain ⟨e1, e2, e3, e4⟩ := e
              subst e1; subst w c vlog
              refine ⟨hcons, fun t j' hm' ht jj hjj => ?_⟩
              have hk := ((hi.acks k t j' hm').2.2 jj hjj).1
              rcases hk with hp | ⟨t', h1, h2, c', eL', he', hck, hn⟩
              · exact Or.inl (Or.inl hp)
              · by_cases ht' : t' < (C.node k).state.hard.term.val
                · exact Or.inl (Or.inr ⟨t', h1, ht', c', eL', he', hck, hn⟩)
                · have : t' = (C.node k).state.hard.term.val := by omega
                  subst this
                  exact Or.inr ⟨c', eL', he', fun hcj => hel ⟨eL', hcj ▸ he'⟩, hn⟩
            · exact absurd e hnot
          · intro T w c vlog _ t j' hm' hn; exact absurd hm' hn
          · intro w t jj hm' hn; exact absurd hm' hn
          · intro T w c v hmem hnot
            rcases List.mem_cons.mp hmem with e | e
            · simp only [Prod.mk.injEq] at e
              obtain ⟨e1, e2, e3, e4⟩ := e
              subst e1; subst w c v
              refine ⟨Or.inl (Nat.le_of_eq hT), fun _ => (hvs j rfl).1, fun _ => ?_, fun _ => ?_⟩
              · show (C.disk k).hard.voted_for = _
                rw [← hs]; exact hvf
              · rw [(hC1 k).1]; exact hvf
            · exact absurd e hnot
          · intro T w c c' v v' h1 h2
            have key : ∀ a b x y, (T, w, a, x) ∈ G.ballots → (T, w, b, y) =
                ((C.node k).state.hard.term.val, k, j, fullLog G (C.node k).state) → a = b := by
              intro a b x y hb2 e
              simp only [Prod.mk.injEq] at e
              obtain ⟨e1, e2, e3, e4⟩ := e
              subst e1; subst w b y
              have := (hi.ballots _ k a x hb2).2.2.1 hT.symm
              rw [← hs, hvf] at this
              exact (hid _ _ (Option.some.inj this)).symm
            rcases List.mem_cons.mp h1 with e1 | e1 <;> rcases List.mem_cons.mp h2 with e2 | e2
            · simp only [Prod.mk.injEq] at e1 e2
              exact e1.2.2.1.trans e2.2.2.1.symm
            · exact (key c' c v' v e2 e1).symm
            · exact key c c' v v' e1 e2
            · exact hi.ballot_unique T w c c' v v' e1 e2
          · intro T w c vlog hmem hnot hr ht
            rcases List.mem_cons.mp hmem with e | e
            · simp only [Prod.mk.injEq] at e
              obtain ⟨e1, e2, e3, e4⟩ := e
              subst e1; subst w c vlog
              rw [(hC1 j).2] at hr; rw [(hC1 j).1] at ht ⊢
              have hl := (hvs j rfl).2.1 ⟨hr, Fin.ext ht⟩
              rw [lastOf_fullLog G _ (hi.live j).1, hl]
              exact hup
            · exact absurd e hnot
        · unfold SentOk; rw [hm]
          refine ⟨⟨k, hfrom⟩, fun _ w c hw' hc' => ?_⟩
          obtain rfl := hw w hw'
          obtain rfl := hc c hc'
          exact Or.inl ⟨fullLog G (C.node w).state, by simp [growS]⟩
  | replicated _ i r =>
    cases r with
    | some rj =>
      refine ⟨G, Extends.refl G, send_inv_send ids g _ G hi1 env ?_⟩
      unfold SentOk; rw [hm]
      exact ⟨⟨k, hfrom⟩, fun h => by cases h⟩
    | none =>
      obtain ⟨hpre, hack⟩ := hout rfl
      refine ⟨growS G ((k, (C.node k).state.hard.term.val, i.val) :: G.acks) G.ballots,
        growS_extends G _ _ (fun a h => List.mem_cons_of_mem _ h) (fun b h => h),
        send_inv_send ids g _ _ ?_ env ?_⟩
      · apply send_inv_grow ids g _ G hi1 _ _ (fun a h => List.mem_cons_of_mem _ h) (fun b h => h)
        · intro T w c vlog h hn; exact absurd h hn
        · intro T w c vlog hb t j' hm' hn ht jj hjj
          rcases List.mem_cons.mp hm' with e | e
          · simp only [Prod.mk.injEq] at e
            obtain ⟨e1, e2, e3⟩ := e
            subst w; subst e2; subst e3
            rcases (hi.ballots T k c vlog hb).1 with hle | ⟨hkc, hT', he⟩
            · exfalso; omega
            · subst hkc
              have hdl := (hi.elect T k vlog he (by omega)).2.1
              refine Or.inl (Or.inl ((send_prefix_prefix G _ _ _ hjj).trans ?_))
              rw [← hdl, ← hs]; exact hpre
          · exact absurd e hn
        · intro w t jj hm' hn
          rcases List.mem_cons.mp hm' with e | e
          · simp only [Prod.mk.injEq] at e
            obtain ⟨e1, e2, e3⟩ := e
            subst w; subst e2; subst e3
            refine ⟨hack, Nat.le_of_eq hT, fun j' hj' => ⟨Or.inl ?_, Or.inl ?_⟩⟩
            · rw [(hC1 k).1]; exact (send_prefix_prefix G _ _ _ hj').trans hpre
            · show _ <+: fullLog G (C.disk k)
              rw [← hs]; exact (send_prefix_prefix G _ _ _ hj').trans hpre
          · exact absurd e hn
        · intro T w c v h hn; exact absurd h hn
        · exact hi.ballot_unique
        · intro T w c vlog h hn; exact absurd h hn
      · unfold SentOk; rw [hm]
        refine ⟨⟨k, hfrom⟩, fun _ w hw' => ?_⟩
        obtain rfl := hw w hw'
        simp [growS]
  | prevote _ c =>
    refine ⟨G, Extends.refl G, send_inv_send ids g _ G hi1 env ?_⟩
    unfold SentOk; rw [hm]; exact ⟨⟨k, hfrom⟩, trivial⟩
  | prevoted _ c gr =>
    refine ⟨G, Extends.refl G, send_inv_send ids g _ G hi1 env ?_⟩
    unfold SentOk; rw [hm]; exact ⟨⟨k, hfrom⟩, trivial⟩
  | install j snap hle hsnap =>
    have hout := hlead hout
    have hL := hi.lead k hout
    obtain ⟨L, hLl, -, hcl⟩ := hL.log
    obtain rfl := hcl hd
    obtain ⟨eL0, hel0⟩ := hout
    have hbase := base_some _ snap hsnap
    have hpos : 0 < (C.node k).state.base.index.val := hok.snapshot (by simp [hsnap])
    refine ⟨G, Extends.refl G, send_inv_send ids g _ G hi1 env ?_⟩
    unfold SentOk; rw [hm]
    refine ⟨⟨k, hfrom⟩, _, hLl, ?_⟩
    rw [← hbase]
    obtain ⟨hl, hlid⟩ := boundary_last G _ hok hpos
    have hbl := boundary_len G _ hok
    have htake : (fullLog G (C.node k).state).take (C.node k).state.base.index.val = boundary G (C.node k).state := by
      rw [fullLog_def, ← hbl, List.take_left']; rfl
    refine ⟨hpos, ⟨by rw [fullLog_def]; simp; omega, ?_⟩, ?_, ?_, ?_⟩
    · simp only [fullLog_def]
      rw [List.getElem_append_left hl]; exact hlid
    · exact committedBy_prefix G _ _ _ (prefix_take_le' _ _ _ hok.commit_ge) hcom
    · rw [htake, ← (hi.live k).2]
      simp [snapMem, memInit, hsnap]
    · intro c eL he
      rw [hel0] at he
      cases he
      exact hfrom
  | appendBatch j prev es hlt hidp hes =>
    have hout := hlead hout
    have hL := hi.lead k hout
    obtain ⟨L, hLl, -, hcl⟩ := hL.log
    obtain rfl := hcl hd
    obtain ⟨eL0, hel0⟩ := hout
    have hlen := fullLog_length G _ hok
    obtain ⟨-, hprev⟩ := send_prevOk G _ hok hcons _ prev hidp
    refine ⟨G, Extends.refl G, send_inv_send ids g _ G hi1 env ?_⟩
    unfold SentOk; rw [hm]
    refine ⟨⟨k, hfrom⟩, _, hLl, hprev, ?_, ?_, hcom, ?_⟩
    · intro e he
      simp only [Rust.Iter.flatten, List.mem_filterMap, id] at he
      obtain ⟨a, ha, rfl⟩ := he
      obtain ⟨o, ho, hoe⟩ := List.getElem_of_mem ha
      have ho' : o < MAX_APPEND_ENTRIES := by simpa using ho
      have := hes o ho'
      simp only [Vector.getElem_toList] at hoe
      rw [hoe] at this
      split at this
      · exact (send_get_inLog G _ hok hcons _ _ this.symm).1
      · cases this
    · have := hok.commit_le; omega
    · intro c eL he
      rw [hel0] at he
      cases he
      exact hfrom
  | append j prev hlt hidp =>
    have hout := hlead hout
    have hL := hi.lead k hout
    obtain ⟨L, hLl, -, hcl⟩ := hL.log
    obtain rfl := hcl hd
    obtain ⟨eL0, hel0⟩ := hout
    have hlen := fullLog_length G _ hok
    obtain ⟨hpx, hprev⟩ := send_prevOk G _ hok hcons _ prev hidp
    refine ⟨G, Extends.refl G, send_inv_send ids g _ G hi1 env ?_⟩
    unfold SentOk; rw [hm]
    refine ⟨⟨k, hfrom⟩, _, hLl, hprev, ?_, ?_, hcom, ?_⟩
    · intro e he
      obtain ⟨h1, h2⟩ := send_get_inLog G _ hok hcons _ _ he
      exact ⟨h1, by omega⟩
    · have := hok.commit_le; omega
    · intro c eL he
      rw [hel0] at he
      cases he
      exact hfrom

end Jarl.Engine.Dyn
