import Engine.Dyn.Spec

/-!
# `append` and `replicated` on a dynamic node
-/

set_option linter.unusedSectionVars false

namespace Jarl.Engine.Dyn
open Jarl Jarl.Engine

variable {V S : Type} {MAX CAP : Nat} [Rust.Clone V] [Rust.Clone S]

theorem commit_to_rel_pre (m m' : DNode V S MAX CAP) (i : Rust.u64) (hp : Pre m)
    (h : Node.commit_to m i = pure m') : CommitTo m i m' :=
  commit_to_rel m m' i hp.hooks hp.layout hp.contig hp.n_lt hp.e0 hp.e1 hp.uniq h

theorem refresh_rel_pre (m m' : DNode V S MAX CAP) (hp : Pre m)
    (h : Node.refresh_membership m = pure m') : Refresh m m' :=
  refresh_rel m m' hp.hooks hp.layout hp.contig hp.n_lt hp.e0 hp.e1 hp.uniq h

/-- The facts of `Pre` survive a refresh. -/
theorem pre_refresh (n n' : DNode V S MAX CAP) (hp : Pre n) (h : Refresh n n') : Pre n' := by
  obtain ⟨n1, ⟨he, -, hu⟩, -, h2⟩ := h
  have hp1 : Pre n1 := by
    rw [he]; exact { hp with layout := hp.layout, contig := hp.contig, uniq := hu }
  have hp2 : Pre { n1 with «local» := (Rust.Iter.position n1.peers.toList (fun p => p == some n.config.id)).getD (Rust.usizeOf MAX) } :=
    { hp1 with layout := hp1.layout, contig := hp1.contig, uniq := hp1.uniq }
  rcases h2 with rfl | ⟨-, -, -, ht⟩
  · exact hp2
  · obtain ⟨r, d, rfl⟩ := ht
    exact { hp2 with layout := hp2.layout, contig := hp2.contig, uniq := hp2.uniq }

/-- The outcomes of `append`, for a run that returns. -/
theorem append_rel' [Rust.LawfulClone V] (n : DNode V S MAX CAP) (hp : Pre n)
    (prev : LogId) (entry : Option (DEntry V MAX)) (commit : Rust.u64)
    (hbase : n.state.base.index.val ≤ n.state.hard.commit.val)
    (hcommit : n.state.hard.commit.val ≤ (lastId n.state).index.val)
    (hnext : ∀ e, entry = some e → e.id.index.val = prev.index.val + 1)
    (r : Rust.u64 × Option Rejection) (n' : DNode V S MAX CAP)
    (h : Node.append n prev entry commit = pure (r, n')) : AppendD n prev entry commit r n' := by
  have _hb := hbase
  have _hc := hcommit
  have hl := hp.layout
  have hc := hp.contig
  have hcap : CAP < 2 ^ Rust.usizeBits := hp.cap_lt
  have hlr := len_eq _ hl
  have hlast := lastId_eq _ hc
  unfold Node.append at h
  simp only [id_at_eq _ hl, last_eq _ hl.1] at h
  by_cases hpv : idAt n.state prev.index.val = some prev
  · simp only [hpv, bne_self_eq_false, Bool.false_eq_true, if_false] at h
    obtain ⟨hpb, hpl⟩ := idAt_some _ hl hc _ hpv
    cases entry with
    | none =>
      simp only at h
      obtain ⟨m, hm, h⟩ := Rust.bind_eq_pure h
      obtain ⟨rfl, rfl⟩ := Prod.mk.inj (Rust.pure_inj h)
      exact Or.inr (Or.inl ⟨hpv, rfl, rfl, commit_to_rel_pre n _ _ hp hm⟩)
    | some e =>
      have hen := hnext e rfl
      simp only at h
      by_cases he : idAt n.state e.id.index.val = some e.id
      · simp only [he, bne_self_eq_false, Bool.false_eq_true, if_false] at h
        obtain ⟨m, hm, h⟩ := Rust.bind_eq_pure h
        obtain ⟨rfl, rfl⟩ := Prod.mk.inj (Rust.pure_inj h)
        exact Or.inr (Or.inr (Or.inl ⟨e, hpv, rfl, he, rfl, commit_to_rel_pre n _ _ hp hm⟩))
      · have hne : (idAt n.state e.id.index.val != some e.id) = true := by simpa using he
        simp only [hne, if_true] at h
        by_cases hle : e.id.index ≤ n.state.hard.commit
        · simp only [hle, decide_true, if_true] at h
          obtain ⟨rfl, rfl⟩ := Prod.mk.inj (Rust.pure_inj h)
          exact Or.inr (Or.inr (Or.inr (Or.inl ⟨e, rfl, he, Fin.le_def.mp hle, rfl, rfl, rfl⟩)))
        · have hlt : n.state.hard.commit.val < e.id.index.val := by rw [Fin.le_def] at hle; omega
          simp only [hle, decide_false, Bool.false_eq_true, if_false, pure_bind] at h
          by_cases hfull : n.state.full = true ∧ (lastId n.state).index < e.id.index
          · simp only [hfull.1, hfull.2, decide_true, if_true] at h
            obtain ⟨m, hm, h⟩ := Rust.bind_eq_pure h
            obtain ⟨rfl, rfl⟩ := Prod.mk.inj (Rust.pure_inj h)
            exact Or.inr (Or.inr (Or.inr (Or.inr (Or.inl ⟨e, hpv, rfl, he, rfl, commit_to_rel_pre n _ _ hp hm⟩))))
          · have h' : ∃ t5, Rust.Clone.clone e = pure t5 ∧ (do
                let m_1 ← n.state.truncate e.id.index
                let __x ← m_1.push t5
                if __x.fst.is_err = true then
                    pure ((prev.index, some Rejection.Full), { n with state := __x.snd })
                  else do
                    let m_3 ← Node.refresh_membership { n with state := __x.snd }
                    let m_4 ← Node.commit_to { m_3 with dirty := true, log_from := some (Rust.Option.map_or m_3.log_from e.id.index fun «from» => Rust.min «from» e.id.index) } (Rust.min commit e.id.index)
                    pure ((e.id.index, none), m_4)) = pure (r, n') := by
              by_cases hfl : n.state.full = true
              · have : ¬ (lastId n.state).index < e.id.index := fun h => hfull ⟨hfl, h⟩
                simp only [hfl, this, decide_false, Bool.false_eq_true, if_true, if_false] at h
                exact Rust.bind_eq_pure h
              · simp only [hfl, Bool.false_eq_true, if_false] at h
                exact Rust.bind_eq_pure h
            obtain ⟨t5, ht5, h⟩ := h'
            cases Rust.LawfulClone.clone_eq _ _ ht5
            obtain ⟨s1, hs1, h1h, h1s, h1r, hl1, hc1⟩ := truncate_spec n.state e.id.index hl hc
            have hb1 : s1.base = n.state.base := by simp [State.base, h1s]
            have hlen1 := len_eq _ hl1
            have hroom : s1.len.val < CAP := by
              rw [hlen1, h1r, List.length_take]
              have := hl.1
              by_cases hfl : n.state.full = true
              · have : ¬ (lastId n.state).index < e.id.index := fun h => hfull ⟨hfl, h⟩
                rw [Fin.lt_def] at this
                omega
              · have : n.state.len.val ≠ CAP := by
                  intro h; apply hfl
                  have : n.state.len = Rust.usizeOf CAP := Fin.ext (by rw [Rust.val_usizeOf _ hcap]; exact h)
                  simp [State.full, this]
                omega
            obtain ⟨s2, hs2, h2h, h2s, h2r, -, hl2⟩ := push_ok s1 e hcap hl1 hroom
            have hb2 : s2.base = s1.base := by simp [State.base, h2s]
            have hc2 : Contig s2 := by
              apply contig_push s1 s2 e hc1 hb2 h2r
              rw [h1r, List.length_take, hb1]; omega
            rw [hs1, pure_bind, hs2, pure_bind] at h
            simp only [Rust.Result.is_err, Bool.false_eq_true, if_false] at h
            obtain ⟨m3, hm3, h⟩ := Rust.bind_eq_pure h
            obtain ⟨m4, hm4, h⟩ := Rust.bind_eq_pure h
            obtain ⟨rfl, rfl⟩ := Prod.mk.inj (Rust.pure_inj h)
            have hp2 : Pre { n with state := s2 } := { hp with layout := hl2, contig := hc2, uniq := hp.uniq }
            have hR := refresh_rel_pre _ _ hp2 hm3
            have hp3 := pre_refresh _ _ hp2 hR
            have hp4 : Pre { m3 with dirty := true, log_from := some (Rust.Option.map_or m3.log_from e.id.index (fun f => Rust.min f e.id.index)) } :=
              { hp3 with layout := hp3.layout, contig := hp3.contig, uniq := hp3.uniq }
            exact Or.inr (Or.inr (Or.inr (Or.inr (Or.inr ⟨e, s2, m3, hpv, rfl, he, hlt,
              ⟨(by rw [h2r, h1r]), (by rw [h2h, h1h]), (by rw [h2s, h1s]), hl2, hc2⟩, rfl, hR,
              commit_to_rel_pre _ _ _ hp4 hm4⟩))))
  · have hne : (idAt n.state prev.index.val != some prev) = true := by simpa using hpv
    simp only [hne, if_true] at h
    split at h <;>
    · simp only [pure_bind] at h
      obtain ⟨rfl, rfl⟩ := Prod.mk.inj (Rust.pure_inj h)
      exact Or.inl ⟨hpv, rfl, rfl, rfl⟩

/-- The facts of `Pre` survive `advance_commit`. -/
theorem pre_adv (m m' : DNode V S MAX CAP) (hp : Pre m) (h : Adv' m m') : Pre m' := by
  rcases h with rfl | ⟨v, -, -, -, hct⟩
  · exact hp
  · rcases hct with ⟨hlt, hR⟩ | ⟨-, rfl⟩
    · apply pre_refresh _ _ _ hR
      simp only [commitTo, hlt, if_true]
      exact { hp with layout := hp.layout, contig := hp.contig, uniq := hp.uniq }
    · exact hp

/-- A run of `replicated` that only touched `active`, `next` and some outbox slots. -/
theorem replicated_triv (n : DNode V S MAX CAP) (p : Fin MAX) (index : Rust.u64) (rej : Option Rejection)
    (a : Vector Bool MAX) (nx : Vector Rust.u64 MAX) (ob : Vector (Option Outbound) MAX)
    (hob : ∀ j : Fin MAX, ob[j] = n.outbox[j] ∨ (ob[j] = some .Replicate ∧
      (j = p ∨ (j.val ≠ n.local.val ∧ ∃ id, n.peers[j] = some id)))) :
    ReplicatedD n p index rej { n with active := a, «next» := nx, outbox := ob } :=
  ⟨{ n with active := a, «next» := nx }, _, ⟨a, nx, Or.inl rfl⟩, Or.inl rfl, rfl, hob⟩

/-- The outcomes of `replicated` for a reply from slot `p`. -/
theorem replicated_rel' (n : DNode V S MAX CAP) (hp : Pre n) (p : Fin MAX) (index : Rust.u64)
    (rej : Option Rejection) (n' : DNode V S MAX CAP)
    (h : Node.replicated n (Rust.ofNat p.val) index rej = pure n') : ReplicatedD n p index rej n' := by
  have hl := hp.layout
  have hN := hp.n_lt
  generalize hq : (Rust.ofNat p.val : Rust.usize) = q at h
  have hqv : q.val = p.val := by
    rw [← hq]; simp only [Rust.ofNat]; have := p.isLt; uomega
  have hqp : q.val < MAX := by rw [hqv]; exact p.isLt
  have hpq : p = ⟨q.val, hqp⟩ := Fin.ext hqv.symm
  clear hq hqv
  subst hpq
  unfold Node.replicated at h
  simp only [Rust.Slice.set_ok _ _ _ hqp, pure_bind, last_eq _ hl.1] at h
  by_cases h1 : index > (lastId n.state).index
  · simp only [h1, decide_true, if_true] at h
    cases Rust.pure_inj h
    exact replicated_triv n _ index rej _ n.next n.outbox (fun _ => Or.inl rfl)
  · rcases rej with _ | (nx | _) <;> simp only [h1, decide_false, Bool.false_eq_true, if_false] at h
    · simp only [Rust.Slice.index_ok _ _ hqp, pure_bind] at h
      by_cases h2 : index ≤ n.matched[q.val]
      · simp only [h2, decide_true, if_true] at h
        cases Rust.pure_inj h
        exact replicated_triv n _ index none _ n.next n.outbox (fun _ => Or.inl rfl)
      · simp only [h2, decide_false, Bool.false_eq_true, if_false] at h
        have hpm : Pre { n with active := n.active.set q.val true hqp, «next» := n.next.set q.val (Rust.max n.next[q.val] (Rust.saturating_add index 1)) hqp, matched := n.matched.set q.val index hqp } :=
          { hp with layout := hp.layout, contig := hp.contig, uniq := hp.uniq }
        obtain ⟨⟨b, m'⟩, hadv, h⟩ := Rust.bind_eq_pure h
        have hA := advance_rel' _ b m' hpm.hooks hpm.layout hpm.contig hN hpm.e0 hpm.e1 hpm.uniq hadv
        have hpm' := pre_adv _ _ hpm hA
        have hR : RecordedD n { n with active := n.active.set q.val true hqp, «next» := n.next.set q.val (Rust.max n.next[q.val] (Rust.saturating_add index 1)) hqp, matched := n.matched.set q.val index hqp } ⟨q.val, hqp⟩ index none :=
          ⟨_, _, Or.inr ⟨rfl, by simp only [gt_iff_lt, Fin.lt_def, Nat.not_lt] at h1; exact h1,
            by simp only [Fin.le_def, Nat.not_le] at h2; exact h2, rfl⟩⟩
        cases b
        · simp only [Bool.false_eq_true, if_false, last_eq _ hpm'.layout.1, pure_bind] at h
          by_cases h3 : index < (lastId m'.state).index
          · simp only [h3, decide_true, if_true, replicate_eq _ _ hN hqp, pure_bind] at h
            cases Rust.pure_inj h
            refine ⟨_, m', hR, hA, rfl, ?_⟩
            intro j
            simp only [Fin.getElem_fin, Vector.getElem_set]
            split
            · rename_i hj
              exact Or.inr ⟨rfl, Or.inl (Fin.ext (by simp only at hj ⊢; omega))⟩
            · exact Or.inl rfl
          · simp only [h3, decide_false, Bool.false_eq_true, if_false] at h
            have he := Rust.pure_inj h
            subst he
            exact ⟨_, m', hR, hA, rfl, fun _ => Or.inl rfl⟩
        · simp only [if_true, broadcast_eq' m' hN, pure_bind] at h
          cases Rust.pure_inj h
          refine ⟨_, m', hR, hA, rfl, ?_⟩
          intro j
          simp only [bcastD, Fin.getElem_fin, Vector.getElem_ofFn]
          split
          · rename_i hj
            obtain ⟨hj1, hj2⟩ := hj
            refine Or.inr ⟨rfl, Or.inr ⟨hj1, ?_⟩⟩
            revert hj2
            cases m'.peers[j.val] with
            | some id => exact fun _ => ⟨id, rfl⟩
            | none => intro hj2; simp [Rust.Option.is_some_and] at hj2
          · exact Or.inl rfl
    · simp only [Rust.Slice.index_ok _ _ hqp, pure_bind] at h
      by_cases h2 : index ≥ n.matched[q.val]
      · simp only [h2, decide_true, if_true] at h
        by_cases h3 : (Rust.checked_add index 1 == some n.next[q.val]) = true
        · have hcl : (Rust.saturating_add n.matched[q.val] 1).val ≤
              (Rust.saturating_add (lastId n.state).index 1).val := by
            rw [Rust.val_saturating_add, Rust.val_saturating_add]
            simp only [Fin.le_def, gt_iff_lt, Fin.lt_def, ge_iff_le, Nat.not_lt] at h1 h2
            simp only [Nat.min_def]
            split <;> split <;> omega
          simp only [h3, if_true, Rust.clamp_ok _ _ _ hcl, pure_bind, replicate_eq _ _ hN hqp] at h
          cases Rust.pure_inj h
          exact replicated_triv n _ index _ _ _ _ (fun j => by
            simp only [Fin.getElem_fin, Vector.getElem_set]
            split
            · rename_i hj
              exact Or.inr ⟨rfl, Or.inl (Fin.ext (by simp only at hj ⊢; omega))⟩
            · exact Or.inl rfl)
        · simp only [h3, Bool.false_eq_true, if_false] at h
          cases Rust.pure_inj h
          exact replicated_triv n _ index _ _ n.next n.outbox (fun _ => Or.inl rfl)
      · simp only [h2, decide_false, Bool.false_eq_true, if_false] at h
        cases Rust.pure_inj h
        exact replicated_triv n _ index _ _ n.next n.outbox (fun _ => Or.inl rfl)
    · cases Rust.pure_inj h
      exact replicated_triv n _ index _ _ n.next n.outbox (fun _ => Or.inl rfl)

end Jarl.Engine.Dyn
