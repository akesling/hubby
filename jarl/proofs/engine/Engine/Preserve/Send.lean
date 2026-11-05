import Engine.Frame
import Engine.LogFacts

/-! # Preservation: Materializing a message -/

namespace Jarl.Engine
open Jarl

variable {V S : Type} {N CAP : Nat} [Rust.Clone V] [Rust.Clone S]

/-- The ghost with the same leader logs and elections, and new acks and ballots. -/
def grow (G : Ghost V N) (A : List (Fin N × Nat × Nat)) (B : List (Nat × Fin N × Fin N × List (Entry V))) :
    Ghost V N := ⟨G.leader, G.elect, A, B⟩

omit [Rust.Clone V] in
theorem grow_extends (G : Ghost V N) (A : List (Fin N × Nat × Nat)) (B : List (Nat × Fin N × Fin N × List (Entry V)))
    (ha : ∀ a ∈ G.acks, a ∈ A) (hb : ∀ b ∈ G.ballots, b ∈ B) : Extends G (grow G A B) :=
  ⟨fun _ L h => ⟨L, h, List.prefix_refl L⟩, fun _ _ h => h, ha, hb⟩

omit [Rust.Clone V] [Rust.Clone S] in
theorem stateOk_grow (G : Ghost V N) (A : List (Fin N × Nat × Nat)) (B : List (Nat × Fin N × Fin N × List (Entry V)))
    (s : State V S CAP) (h : StateOk G s) : StateOk (grow G A B) s :=
  ⟨h.layout, h.contig, h.base, h.snapshot, h.terms, h.commit_ge, h.commit_le, h.unvoted⟩

omit [Rust.Clone V] [Rust.Clone S] in
theorem withOwn_grow (G : Ghost V N) (A : List (Fin N × Nat × Nat)) (B : List (Nat × Fin N × Fin N × List (Entry V)))
    (ha : ∀ a ∈ G.acks, a ∈ A) (hb : ∀ b ∈ G.ballots, b ∈ B) (k : Fin N) (n : Node V S N CAP) :
    Extends (withOwn G k n) (withOwn (grow G A B) k n) := by
  refine ⟨fun _ L h => ⟨L, h, List.prefix_refl L⟩, fun _ _ h => h, fun a h => ?_, hb⟩
  simp only [withOwn, List.mem_cons] at h ⊢
  rcases h with h | h
  · exact Or.inl h
  · exact Or.inr (ha _ h)

omit [Rust.Clone V] in
theorem committed_of_prefix (G : Ghost V N) (p q : List (Entry V)) (h : Committed G p) (hq : q <+: p) :
    Committed G q := by
  rcases h with rfl | ⟨t, j, hc, hp⟩
  · exact Or.inl (List.prefix_nil.mp hq)
  · exact Or.inr ⟨t, j, hc, hq.trans hp⟩

omit [Rust.Clone V] in
theorem prefix_prefix (G : Ghost V N) (t j i : Nat) (h : j ≤ i) : G.prefix t j <+: G.prefix t i := by
  unfold Ghost.prefix
  rw [show ((G.leader t).getD []).take j = (((G.leader t).getD []).take i).take j by
    rw [List.take_take, Nat.min_eq_left h]]
  exact List.take_prefix _ _

theorem ids_inj (ids : Vector Id N) (hnd : ids.toList.Nodup) (a b : Fin N) (h : ids[a] = ids[b]) : a = b := by
  have h' : ids.toList[a.val]'(by simp) = ids.toList[b.val]'(by simp) := by simpa using h
  exact Fin.ext ((List.getElem_inj hnd).mp h')

omit [Rust.Clone V] [Rust.Clone S] in
/-- Growing the acknowledgments and ballots preserves the invariant, given the
    obligations of the new elements. -/
theorem inv_grow (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (A : List (Fin N × Nat × Nat)) (B : List (Nat × Fin N × Fin N × List (Entry V)))
    (ha : ∀ a ∈ G.acks, a ∈ A) (hb : ∀ b ∈ G.ballots, b ∈ B)
    (wb_new : ∀ T w c vlog, (T, w, c, vlog) ∈ B → (T, w, c, vlog) ∉ G.ballots → Consistent G vlog ∧
      ∀ t j', (w, t, j') ∈ A → t < T → ∀ j ≤ j',
        Kept G w t j T vlog ∨ ∃ c' eL', G.elect T = some (c', eL') ∧ c' ≠ c)
    (wb_old : ∀ T w c vlog, (T, w, c, vlog) ∈ G.ballots → ∀ t j', (w, t, j') ∈ A → (w, t, j') ∉ G.acks →
      t < T → ∀ j ≤ j', Kept G w t j T vlog ∨ ∃ c' eL', G.elect T = some (c', eL') ∧ c' ≠ c)
    (acks_new : ∀ w t j, (w, t, j) ∈ A → (w, t, j) ∉ G.acks → AckOk G t j ∧ t ≤ (C.disk w).hard.term.val ∧
      ∀ j' ≤ j, Kept G w t j' ((C.live w).state.hard.term.val + 1) (fullLog G (C.live w).state) ∧
        Kept G w t j' ((C.disk w).hard.term.val + 1) (fullLog G (C.disk w)))
    (ballots_new : ∀ T w c vlog, (T, w, c, vlog) ∈ B → (T, w, c, vlog) ∉ G.ballots →
      (T ≤ (C.disk w).hard.term.val ∨
        (w = c ∧ (C.disk w).hard.term.val + 1 = T ∧ G.elect T = some (c, vlog))) ∧ (w ≠ c → T ≤ (C.disk c).hard.term.val) ∧
      ((C.disk w).hard.term.val = T → (C.disk w).hard.voted_for = some ids[c]) ∧
      ((C.live w).state.hard.term.val = T → (C.live w).state.hard.voted_for = some ids[c]))
    (bu : ∀ T w c c' v v', (T, w, c, v) ∈ B → (T, w, c', v') ∈ B → c = c')
    (bc : ∀ T w c vlog, (T, w, c, vlog) ∈ B → (T, w, c, vlog) ∉ G.ballots → (C.live c).role = .Candidate →
      (C.live c).state.hard.term.val = T → upToDate (lastOf (fullLog G (C.live c).state)) (lastOf vlog)) :
    Inv ids cfg C (grow G A B) := by
  have E := grow_extends G A B ha hb
  refine
    { wf := ?_
      fixed := hi.fixed
      slot := hi.slot
      live := fun k => stateOk_grow G A B _ (hi.live k)
      disk := fun k => stateOk_grow G A B _ (hi.disk k)
      consistent_disk := hi.consistent_disk
      consistent_live := hi.consistent_live
      clean := hi.clean
      terms := hi.terms
      acks := fun w t j h => ?_
      ballots := fun T w c v h => ?_
      ballot_unique := bu
      ballot_cand := fun T w c v h => ?_
      elect := hi.elect
      elect_cand := hi.elect_cand
      leader := fun k hr => ?_
      candidate := fun k hr => ?_
      outbox := hi.outbox
      outbox_self := hi.outbox_self
      sent := fun env h => ?_
      committed := fun k => ?_ }
  · refine ⟨hi.wf.leader, fun T c eL h => ?_, fun T w c vlog h => ?_⟩
    · obtain ⟨z, a, b, m⟩ := hi.wf.elect T c eL h
      exact ⟨z, a, b, majority_mono _ _ (fun w ⟨v, hv, hu⟩ => ⟨v, hb _ hv, hu⟩) m⟩
    · by_cases hold : (T, w, c, vlog) ∈ G.ballots
      · obtain ⟨hc, hk⟩ := hi.wf.ballot T w c vlog hold
        refine ⟨hc, fun t j' hm ht j hj => ?_⟩
        by_cases hm' : (w, t, j') ∈ G.acks
        · exact hk t j' hm' ht j hj
        · exact wb_old T w c vlog hold t j' hm hm' ht j hj
      · exact wb_new T w c vlog h hold
  · by_cases hold : (w, t, j) ∈ G.acks
    · exact hi.acks w t j hold
    · exact acks_new w t j h hold
  · by_cases hold : (T, w, c, v) ∈ G.ballots
    · exact hi.ballots T w c v hold
    · exact ballots_new T w c v h hold
  · by_cases hold : (T, w, c, v) ∈ G.ballots
    · exact hi.ballot_cand T w c v hold
    · exact bc T w c v h hold
  · have h := hi.leader k hr
    exact ⟨h.elected, h.log, fun j hj hp => ha _ (h.matched j hj hp), h.own⟩
  · obtain ⟨a1, a2, b⟩ := hi.candidate k hr
    exact ⟨a1, a2, fun j hj => (b j hj).imp id (fun ⟨v, hv, hu⟩ => ⟨v, hb _ hv, hu⟩)⟩
  · have hs := hi.sent env h
    unfold SentOk at hs ⊢
    refine ⟨hs.1, ?_⟩
    have h2 := hs.2
    revert h2
    cases env.message with
    | Voted T g => intro h2 hg w c hw hc
                   exact (h2 hg w c hw hc).imp (fun ⟨v, hv⟩ => ⟨v, hb _ hv⟩) id
    | Replicated T i r => intro h2 hr w hw; exact ha _ (h2 hr w hw)
    | Append T prev e cm =>
      intro ⟨L, a, b, c, d, f, g, g'⟩
      exact ⟨L, a, b, c, d, f, committed_mono E _ g, g'⟩
    | Install T snap =>
      intro ⟨L, a, b, c, d, f, f'⟩
      exact ⟨L, a, b, c, d, committed_mono E _ f, f'⟩
    | _ => intro h2; exact h2
  · refine ⟨committed_mono E _ (hi.committed k).1, ?_⟩
    rcases (hi.committed k).2 with h | ⟨r, d, h⟩
    · exact Or.inl (committed_mono E _ h)
    · exact Or.inr ⟨r, d, committed_mono (withOwn_grow G A B ha hb k (C.live k)) _ h⟩

omit [Rust.Clone V] [Rust.Clone S] in
/-- Recording a new message. -/
theorem inv_send (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (env : Envelope V S) (hs : SentOk ids C G env) :
    Inv ids cfg { C with sent := env :: C.sent } G := by
  refine
    { wf := hi.wf
      fixed := hi.fixed
      slot := hi.slot
      live := hi.live
      disk := hi.disk
      consistent_disk := hi.consistent_disk
      consistent_live := hi.consistent_live
      clean := hi.clean
      terms := hi.terms
      acks := hi.acks
      ballots := hi.ballots
      ballot_unique := hi.ballot_unique
      ballot_cand := hi.ballot_cand
      elect := hi.elect
      elect_cand := hi.elect_cand
      leader := fun k hr => (leaderOk_congr ids C { C with sent := env :: C.sent } G k rfl).mp (hi.leader k hr)
      candidate := hi.candidate
      outbox := fun k j o h => ?_
      outbox_self := hi.outbox_self
      sent := fun e h => ?_
      committed := hi.committed }
  · have ho := hi.outbox k j o h
    cases o with
    | Voted g =>
      intro hg
      obtain ⟨a, last, b, c⟩ := ho hg
      exact ⟨a, last, List.mem_cons_of_mem _ b, c⟩
    | _ => exact ho
  · rcases List.mem_cons.mp h with rfl | h
    · exact hs
    · exact hi.sent e h


omit [Rust.Clone V] [Rust.Clone S] in
/-- Only the outbox of node `k` changes, by dropping descriptors. -/
theorem send_localOk_outbox (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (k : Fin N) (O : Vector (Option Outbound) N)
    (hf : Fixed ids { C.live k with outbox := O })
    (hO : ∀ j : Fin N, O[j] = (C.live k).outbox[j] ∨ O[j] = none) :
    LocalOk ids cfg C G k { C.live k with outbox := O } := by
  refine
    { fixed := ⟨hf, (hi.fixed k).2⟩
      slot := hi.slot k
      live := hi.live k
      clean := hi.clean k
      terms := hi.terms k
      consistent := hi.consistent_live k
      acks := fun t j h j' hj' => ((hi.acks k t j h).2.2 j' hj').1
      elect := fun T eL h hd => (hi.elect T k eL h hd).2.2.2
      ballots := fun T c v h => (hi.ballots T k c v h).2.2.2
      elect_cand := fun T eL h => hi.elect_cand T k eL h
      ballot_cand := fun hr T w v h ht => hi.ballot_cand T w k v h hr ht
      leader := fun hr => ?_
      candidate := fun hr => ?_
      outbox := fun j o h => ?_
      outbox_self := ?_
      votes := fun env h T last hf' hm => ?_
      committed := (hi.committed k).2 }
  · have h := hi.leader k hr
    refine ⟨?_, ?_, ?_, ?_⟩ <;> rw [setLive_self]
    · exact h.elected
    · exact h.log
    · exact h.matched
    · exact h.own
  · have h := hi.candidate k hr
    unfold CandidateOk at h ⊢
    rw [setLive_self]
    exact h
  · have ho : (C.live k).outbox[j] = some o := by
      rcases hO j with e | e
      · rw [← e]; exact h
      · exact absurd (e ▸ h) (by simp)
    have := hi.outbox k j o ho
    unfold OutOk at this ⊢
    rw [setLive_self]
    exact this
  · rcases hO k with e | e
    · rw [e]; exact hi.outbox_self k
    · exact e
  · have hs := hi.sent env h
    unfold SentOk at hs
    rw [hm] at hs
    exact (hs.2 k hf').2.1

theorem prefix_take_le {α : Type} (L : List α) (a b : Nat) (h : a ≤ b) : L.take a <+: L.take b := by
  rw [show L.take a = (L.take b).take a by rw [List.take_take, Nat.min_eq_left h]]
  exact List.take_prefix _ _

theorem preserve_send (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N)
    (hi : Inv ids cfg C G) (k : Fin N) (env : Envelope V S) (n : Node V S N CAP)
    (h : Node.next_message (C.live k) = pure (some env, n)) :
    ∃ G', Extends G G' ∧ Inv ids cfg { C.setLive k n with sent := env :: C.sent } G' := by
  obtain ⟨hn, hf, hout, henv⟩ := next_message_rel ids (C.live k) (hi.fixed k).1 _ n h
  obtain ⟨hd, j, o, ho, -, hfrom, hto, hb⟩ := henv env rfl
  obtain ⟨O, rfl⟩ : ∃ O, n = { C.live k with outbox := O } := ⟨n.outbox, hn⟩
  have hi1 := setLive_inv ids cfg C G hi k _ (send_localOk_outbox ids cfg C G hi k O hf hout)
  have hnd := (hi.fixed k).1.nodup
  have hid : env.from = ids[k] := by
    rw [hfrom, ← (hi.fixed k).1.local_id]
    simp [hi.slot k]
  have hw : ∀ w : Fin N, env.from = ids[w] → w = k := fun w e => ids_inj ids hnd w k (e.symm.trans hid)
  have hc : ∀ c : Fin N, env.to = ids[c] → c = j := fun c e => ids_inj ids hnd c j (e.symm.trans hto)
  have hs : (C.live k).state = C.disk k := hi.clean k hd
  have hself : (C.setLive k { C.live k with outbox := O }).live k = { C.live k with outbox := O } :=
    setLive_self _ _ _
  have hOut := hi.outbox k j o ho
  have hT : (C.live k).state.hard.term.val = (C.disk k).hard.term.val := by rw [hs]
  generalize hm : env.message = msg at hb
  cases hb with
  | vote =>
    have hr : (C.live k).role = .Candidate := hOut
    refine ⟨G, Extends.refl G, inv_send ids cfg _ G hi1 env ?_⟩
    unfold SentOk; rw [hm]
    refine ⟨⟨k, hid⟩, fun c hc' => ?_⟩
    obtain rfl := hw c hc'
    refine ⟨?_, fun _ => by rw [hself], fun eL he => absurd ⟨hr, rfl⟩ (hi.elect_cand _ c eL he)⟩
    show _ ≤ (C.disk c).hard.term.val
    rw [hs]; exact Nat.le_refl _
  | voted g =>
    cases g with
    | false =>
      refine ⟨G, Extends.refl G, inv_send ids cfg _ G hi1 env ?_⟩
      unfold SentOk; rw [hm]
      exact ⟨⟨k, hid⟩, fun h => by cases h⟩
    | true =>
      obtain ⟨hvf, last, hvm, hup⟩ := hOut rfl
      by_cases hel : ∃ eL, G.elect (C.live k).state.hard.term.val = some (j, eL)
      · refine ⟨G, Extends.refl G, inv_send ids cfg _ G hi1 env ?_⟩
        unfold SentOk; rw [hm]
        refine ⟨⟨k, hid⟩, fun _ w c _ hc' => ?_⟩
        obtain rfl := hc c hc'
        exact Or.inr hel
      · refine ⟨grow G G.acks (((C.live k).state.hard.term.val, k, j, fullLog G (C.live k).state) :: G.ballots),
          grow_extends G _ _ (fun a h => h) (fun b h => List.mem_cons_of_mem _ h),
          inv_send ids cfg _ _ ?_ env ?_⟩
        · apply inv_grow ids cfg _ G hi1 _ _ (fun a h => h) (fun b h => List.mem_cons_of_mem _ h)
          · intro T w c vlog hmem hnot
            rcases List.mem_cons.mp hmem with e | e
            · simp only [Prod.mk.injEq] at e
              obtain ⟨rfl, rfl, rfl, rfl⟩ := e
              refine ⟨by rw [hs]; exact hi.consistent_disk w, fun t j' hm' ht jj hjj => ?_⟩
              have hk := ((hi.acks w t j' hm').2.2 jj hjj).2
              rw [← hs] at hk
              rcases hk with hp | ⟨t', h1, h2, c', eL', he', hck, hn⟩
              · exact Or.inl (Or.inl hp)
              · by_cases ht' : t' < (C.live w).state.hard.term.val
                · exact Or.inl (Or.inr ⟨t', h1, ht', c', eL', he', hck, hn⟩)
                · have : t' = (C.live w).state.hard.term.val := by omega
                  subst this
                  exact Or.inr ⟨c', eL', he', fun hcj => hel ⟨eL', hcj ▸ he'⟩⟩
            · exact absurd e hnot
          · intro T w c vlog _ t j' hm' hn; exact absurd hm' hn
          · intro w t jj hm' hn; exact absurd hm' hn
          · intro T w c v hmem hnot
            rcases List.mem_cons.mp hmem with e | e
            · simp only [Prod.mk.injEq] at e
              obtain ⟨rfl, rfl, rfl, rfl⟩ := e
              refine ⟨Or.inl (Nat.le_of_eq hT), fun _ => ?_, fun _ => ?_, fun _ => ?_⟩
              · exact ((hi.sent _ hvm).2 c rfl).1
              · show (C.disk w).hard.voted_for = _
                rw [← hs]; exact hvf
              · rw [hself]; exact hvf
            · exact absurd e hnot
          · intro T w c c' v v' h1 h2
            have key : ∀ a b x y, (T, w, a, x) ∈ G.ballots → (T, w, b, y) =
                ((C.live k).state.hard.term.val, k, j, fullLog G (C.live k).state) → a = b := by
              intro a b x y hb2 e
              simp only [Prod.mk.injEq] at e
              obtain ⟨rfl, rfl, rfl, rfl⟩ := e
              have := (hi.ballots _ w a x hb2).2.2.1 hT.symm
              rw [← hs, hvf] at this
              exact (ids_inj ids hnd _ _ (Option.some.inj this)).symm
            rcases List.mem_cons.mp h1 with e1 | e1 <;> rcases List.mem_cons.mp h2 with e2 | e2
            · simp only [Prod.mk.injEq] at e1 e2
              exact e1.2.2.1.trans e2.2.2.1.symm
            · exact (key c' c v' v e2 e1).symm
            · exact key c c' v v' e1 e2
            · exact hi.ballot_unique T w c c' v v' e1 e2
          · intro T w c vlog hmem hnot hr ht
            rcases List.mem_cons.mp hmem with e | e
            · simp only [Prod.mk.injEq] at e
              obtain ⟨rfl, rfl, rfl, rfl⟩ := e
              have hcl : ((C.setLive w { C.live w with outbox := O }).live c).role = (C.live c).role ∧
                  ((C.setLive w { C.live w with outbox := O }).live c).state = (C.live c).state := by
                by_cases hcw : c = w
                · subst hcw; rw [setLive_self]; exact ⟨rfl, rfl⟩
                · rw [setLive_other _ _ _ _ hcw]; exact ⟨rfl, rfl⟩
              rw [hcl.1] at hr; rw [hcl.2] at ht ⊢
              have hl := ((hi.sent _ hvm).2 c rfl).2.1 ⟨hr, Fin.ext ht⟩
              rw [lastOf_fullLog G _ (hi.live c), hl]
              exact hup
            · exact absurd e hnot
        · unfold SentOk; rw [hm]
          refine ⟨⟨k, hid⟩, fun _ w c hw' hc' => ?_⟩
          obtain rfl := hw w hw'
          obtain rfl := hc c hc'
          exact Or.inl ⟨fullLog G (C.live w).state, by simp [grow]⟩
  | replicated i r =>
    cases r with
    | some rj =>
      refine ⟨G, Extends.refl G, inv_send ids cfg _ G hi1 env ?_⟩
      unfold SentOk; rw [hm]
      exact ⟨⟨k, hid⟩, fun h => by cases h⟩
    | none =>
      obtain ⟨hpre, hack⟩ := hOut rfl
      refine ⟨grow G ((k, (C.live k).state.hard.term.val, i.val) :: G.acks) G.ballots,
        grow_extends G _ _ (fun a h => List.mem_cons_of_mem _ h) (fun b h => h), inv_send ids cfg _ _ ?_ env ?_⟩
      · apply inv_grow ids cfg _ G hi1 _ _ (fun a h => List.mem_cons_of_mem _ h) (fun b h => h)
        · intro T w c vlog h hn; exact absurd h hn
        · intro T w c vlog hb t j' hm' hn ht jj hjj
          rcases List.mem_cons.mp hm' with e | e
          · simp only [Prod.mk.injEq] at e
            obtain ⟨rfl, rfl, rfl⟩ := e
            rcases (hi.ballots T w c vlog hb).1 with hle | ⟨rfl, hT', he⟩
            · exfalso; omega
            · have hdl := (hi.elect T w vlog he (by omega)).2.1
              refine Or.inl (Or.inl ((prefix_prefix G _ _ _ hjj).trans ?_))
              rw [← hdl, ← hs]; exact hpre
          · exact absurd e hn
        · intro w t jj hm' hn
          rcases List.mem_cons.mp hm' with e | e
          · simp only [Prod.mk.injEq] at e
            obtain ⟨rfl, rfl, rfl⟩ := e
            refine ⟨hack, Nat.le_of_eq hT, fun j' hj' => ⟨Or.inl ?_, Or.inl ?_⟩⟩
            all_goals first
              | (rw [setLive_self]; exact (prefix_prefix G _ _ _ hj').trans hpre)
              | (show _ <+: fullLog G (C.disk w); rw [← hs]; exact (prefix_prefix G _ _ _ hj').trans hpre)
          · exact absurd e hn
        · intro T w c v h hn; exact absurd h hn
        · exact hi.ballot_unique
        · intro T w c vlog h hn; exact absurd h hn
      · unfold SentOk; rw [hm]
        refine ⟨⟨k, hid⟩, fun _ w hw' => ?_⟩
        obtain rfl := hw w hw'
        simp [grow]
  | prevote c => exact absurd hOut id
  | prevoted c g => exact absurd hOut id
  | install snap hle hsnap =>
    have hr : (C.live k).role = .Leader := hOut
    have hL := hi.leader k hr
    obtain ⟨L, hLl, -, hcl⟩ := hL.log
    obtain rfl := hcl hd
    obtain ⟨eL0, hel0, -⟩ := hL.elected
    have hok := hi.live k
    have hbase := base_some _ snap hsnap
    have hpos : 0 < (C.live k).state.base.index.val := hok.snapshot (by simp [hsnap])
    refine ⟨G, Extends.refl G, inv_send ids cfg _ G hi1 env ?_⟩
    unfold SentOk; rw [hm]
    refine ⟨⟨k, hid⟩, _, hLl, ?_⟩
    rw [← hbase]
    obtain ⟨hl, hlid⟩ := boundary_last G _ hok hpos
    have hlen : (boundary G (C.live k).state).length ≤ (fullLog G (C.live k).state).length := by
      rw [fullLog_def]; simp
    refine ⟨hpos, by omega, ?_, ?_, ?_⟩
    · simp only [fullLog_def]
      rw [List.getElem_append_left hl]; exact hlid
    · have hc := (hi.committed k).1
      rw [← hs] at hc
      exact committed_of_prefix G _ _ hc (prefix_take_le _ _ _ hok.commit_ge)
    · intro c eL he
      rw [hel0] at he
      cases he
      exact hid
  | append prev hlt hidp =>
    have hr : (C.live k).role = .Leader := hOut
    have hL := hi.leader k hr
    obtain ⟨L, hLl, -, hcl⟩ := hL.log
    obtain rfl := hcl hd
    obtain ⟨eL0, hel0, -⟩ := hL.elected
    have hok := hi.live k
    have hcons : Consistent G (fullLog G (C.live k).state) := by rw [hs]; exact hi.consistent_disk k
    have hlen := fullLog_length G _ hok
    have hprev : prev.index.val = (C.live k).next[j].val - 1 ∧
        (0 < (C.live k).next[j].val - 1 → ∃ h : (C.live k).next[j].val - 1 - 1 < (fullLog G (C.live k).state).length,
          ((fullLog G (C.live k).state)[(C.live k).next[j].val - 1 - 1]).id = prev) ∧
        ((C.live k).next[j].val - 1 = 0 → prev = LogId.default) := by
      by_cases hx : (C.live k).next[j].val - 1 = 0
      · rw [hx] at hidp
        obtain ⟨-, rfl⟩ := (idAt_zero G _ hok prev).mp hidp
        exact ⟨by rw [hx]; rfl, fun h => by omega, fun _ => rfl⟩
      · obtain ⟨-, hl, hpid⟩ := (idAt_fullLog G _ hok _ (by omega) prev).mp hidp
        have := (hcons _ hl).1
        rw [hpid] at this
        exact ⟨by omega, fun _ => ⟨hl, hpid⟩, fun h => absurd h hx⟩
    refine ⟨G, Extends.refl G, inv_send ids cfg _ G hi1 env ?_⟩
    unfold SentOk; rw [hm]
    refine ⟨⟨k, hid⟩, _, hLl, ?_, ?_, ?_, ?_, ?_, ?_⟩
    · intro hp; rw [hprev.1] at hp ⊢; exact hprev.2.1 hp
    · intro hp; exact hprev.2.2 (by omega)
    · intro e he
      have he' := he
      rw [get_eq _ hok.layout, if_pos hlt] at he'
      have hr' := (List.getElem?_eq_some_iff.mp he').1
      have hlast := lastId_eq _ hok.contig
      obtain ⟨hl, hget⟩ := fullLog_get G _ hok _ hlt (by omega)
      have hfin : (⟨(C.live k).next[j].val % 2 ^ 64, Nat.mod_lt _ (by decide)⟩ : Rust.u64) = (C.live k).next[j] :=
        Fin.ext (Nat.mod_eq_of_lt (C.live k).next[j].isLt)
      rw [hfin, he] at hget
      cases hget
      have hidx := (hcons _ hl).1
      refine ⟨by omega, ?_, by omega⟩
      simp only [hidx, show (C.live k).next[j].val - 1 + 1 - 1 = (C.live k).next[j].val - 1 by omega]
    · have := hok.commit_le; omega
    · have hc := (hi.committed k).1
      rw [← hs] at hc
      exact hc
    · intro c eL he
      rw [hel0] at he
      cases he
      exact hid

end Jarl.Engine
