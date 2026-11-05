import Engine.NodeOps

/-!
# `append`: a follower handling one replicated entry

Outcomes of `Node::append(previous, entry, commit)` on a fixed node whose
checkpoint satisfies `base ≤ commit ≤ last`.
-/

namespace Jarl.Engine
open Jarl

variable {V S : Type} {N CAP : Nat} [Rust.Clone V] [Rust.Clone S]

/-- `append` replaced the suffix from the entry's index with that entry. -/
def Replaced (n : Node V S N CAP) (e : Entry V) (s' : State V S CAP) : Prop :=
  ret s' = (ret n.state).take (e.id.index.val - n.state.base.index.val - 1) ++ [e] ∧
  s'.hard = n.state.hard ∧ s'.snapshot = n.state.snapshot ∧ Layout s' ∧ Contig s'

/-- The follower after replacing its suffix: a pending save from the entry's index. -/
def accepted (n : Node V S N CAP) (e : Entry V) (s' : State V S CAP) : Node V S N CAP :=
  { n with state := s', dirty := true, log_from := some (Rust.Option.map_or n.log_from e.id.index (fun f => Rust.min f e.id.index)) }

omit [Rust.Clone V] [Rust.Clone S] in
/-- A computation equal to `pure x` is faithful to `x`. -/
theorem faithful_of_eq {γ : Type} {m : Rust.M γ} {x : γ} (h : m = pure x) : Rust.Faithful m x :=
  h ▸ Rust.faithful_pure x

/-- The outcomes of `append`, stated as the possible results of a run that
returns: cloning the entry may panic or diverge, but with a lawful `Clone` a
run that returns is one of these. -/
theorem append_rel [Rust.LawfulClone V] (ids : Vector Id N) (n : Node V S N CAP) (hf : Fixed ids n)
    (prev : LogId) (entry : Option (Entry V)) (commit : Rust.u64)
    (_hbase : n.state.base.index.val ≤ n.state.hard.commit.val)
    (_hcommit : n.state.hard.commit.val ≤ (lastId n.state).index.val)
    (hnext : ∀ e, entry = some e → e.id.index.val = prev.index.val + 1) :
    ∀ r n', Node.append n prev entry commit = pure (r, n') → Fixed ids n' ∧ (
      -- The predecessor does not match: reject without change.
      (idAt n.state prev.index.val ≠ some prev ∧ r.2.isSome ∧ n' = n) ∨
      -- A heartbeat: commit up to the predecessor.
      (idAt n.state prev.index.val = some prev ∧ entry = none ∧ r = (prev.index, none) ∧
        n' = commitTo n (Rust.min commit prev.index)) ∨
      -- The entry is already present.
      (∃ e, idAt n.state prev.index.val = some prev ∧ entry = some e ∧
        idAt n.state e.id.index.val = some e.id ∧ r = (e.id.index, none) ∧
        n' = commitTo n (Rust.min commit e.id.index)) ∨
      -- A conflict at or below the commit index: reject without change.
      (∃ e, entry = some e ∧ idAt n.state e.id.index.val ≠ some e.id ∧
        e.id.index.val ≤ n.state.hard.commit.val ∧ r.2.isSome ∧ n' = n) ∨
      -- No room: reject, committing up to the predecessor.
      (∃ e, idAt n.state prev.index.val = some prev ∧ entry = some e ∧
        idAt n.state e.id.index.val ≠ some e.id ∧ r.2 = some .Full ∧
        n' = commitTo n (Rust.min commit prev.index)) ∨
      -- Replace the conflicting suffix with the entry.
      (∃ e s', idAt n.state prev.index.val = some prev ∧ entry = some e ∧
        idAt n.state e.id.index.val ≠ some e.id ∧ n.state.hard.commit.val < e.id.index.val ∧
        Replaced n e s' ∧ r = (e.id.index, none) ∧
        n' = commitTo (accepted n e s') (Rust.min commit e.id.index))) := by
  suffices hs : ∃ r n', Rust.Faithful (Node.append n prev entry commit) (r, n') ∧ Fixed ids n' ∧ (
      (idAt n.state prev.index.val ≠ some prev ∧ r.2.isSome ∧ n' = n) ∨
      (idAt n.state prev.index.val = some prev ∧ entry = none ∧ r = (prev.index, none) ∧
        n' = commitTo n (Rust.min commit prev.index)) ∨
      (∃ e, idAt n.state prev.index.val = some prev ∧ entry = some e ∧
        idAt n.state e.id.index.val = some e.id ∧ r = (e.id.index, none) ∧
        n' = commitTo n (Rust.min commit e.id.index)) ∨
      (∃ e, entry = some e ∧ idAt n.state e.id.index.val ≠ some e.id ∧
        e.id.index.val ≤ n.state.hard.commit.val ∧ r.2.isSome ∧ n' = n) ∨
      (∃ e, idAt n.state prev.index.val = some prev ∧ entry = some e ∧
        idAt n.state e.id.index.val ≠ some e.id ∧ r.2 = some .Full ∧
        n' = commitTo n (Rust.min commit prev.index)) ∨
      (∃ e s', idAt n.state prev.index.val = some prev ∧ entry = some e ∧
        idAt n.state e.id.index.val ≠ some e.id ∧ n.state.hard.commit.val < e.id.index.val ∧
        Replaced n e s' ∧ r = (e.id.index, none) ∧
        n' = commitTo (accepted n e s') (Rust.min commit e.id.index))) by
    intro r n' h
    obtain ⟨r0, n0, hF, hrest⟩ := hs
    obtain ⟨rfl, rfl⟩ := Prod.mk.inj (hF _ h)
    exact hrest
  have hl := hf.layout
  have hc := hf.contig
  have hcap : CAP < 2 ^ 64 := by have := hf.cap_lt; omega
  have hlr := len_eq _ hl
  have hlast := lastId_eq _ hc
  unfold Node.append
  simp only [id_at_eq _ hl, last_eq _ hl.1]
  by_cases hp : idAt n.state prev.index.val = some prev
  · simp only [hp, bne_self_eq_false, Bool.false_eq_true, if_false]
    obtain ⟨hpb, hpl⟩ := idAt_some _ hl hc _ hp
    cases entry with
    | none =>
      refine ⟨_, _, faithful_of_eq (by simp [commit_to_eq ids n hf]), fixed_commitTo ids n hf _, Or.inr (Or.inl ⟨trivial, rfl, rfl, rfl⟩)⟩
    | some e =>
      have hen := hnext e rfl
      simp only
      by_cases he : idAt n.state e.id.index.val = some e.id
      · refine ⟨_, _, faithful_of_eq (by simp [he, commit_to_eq ids n hf]), fixed_commitTo ids n hf _,
          Or.inr (Or.inr (Or.inl ⟨e, trivial, rfl, he, rfl, rfl⟩))⟩
      · have hne : (idAt n.state e.id.index.val != some e.id) = true := by simpa using he
        simp only [hne, if_true]
        by_cases hle : e.id.index ≤ n.state.hard.commit
        · refine ⟨(prev.index, some (.Conflict e.id.index)), n, faithful_of_eq (by simp [hle]), hf, Or.inr (Or.inr (Or.inr (Or.inl ⟨e, rfl, he, Fin.le_def.mp hle, rfl, rfl⟩)))⟩
        · have hlt : n.state.hard.commit.val < e.id.index.val := by rw [Fin.le_def] at hle; omega
          simp only [hle, decide_false, Bool.false_eq_true, if_false]
          by_cases hfull : n.state.full = true ∧ (lastId n.state).index < e.id.index
          · refine ⟨(prev.index, some .Full), _, faithful_of_eq (by simp [hfull.1, hfull.2, commit_to_eq ids n hf]), fixed_commitTo ids n hf _,
              Or.inr (Or.inr (Or.inr (Or.inr (Or.inl ⟨e, trivial, rfl, he, rfl, rfl⟩))))⟩
          · obtain ⟨s1, hs1, h1h, h1s, h1r, hl1, hc1⟩ := truncate_spec n.state e.id.index hl hc
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
            have hf2 : Fixed ids { n with state := s2 } := fixed_state ids n hf s2 hl2 hc2 n.dirty n.log_from n.matched
            have hf3 := fixed_state ids n hf s2 hl2 hc2 true (some (Rust.Option.map_or n.log_from e.id.index (fun f => Rust.min f e.id.index))) n.matched
            refine ⟨_, _, ?_, fixed_commitTo ids _ hf3 _,
              Or.inr (Or.inr (Or.inr (Or.inr (Or.inr ⟨e, s2, trivial, rfl, he, hlt,
                ⟨(by rw [h2r, h1r]), (by rw [h2h, h1h]), (by rw [h2s, h1s]), hl2, hc2⟩, rfl, rfl⟩))))⟩
            by_cases hfl : n.state.full = true
            · have : ¬ (lastId n.state).index < e.id.index := fun h => hfull ⟨hfl, h⟩
              simp [hfl, this]
              refine Rust.faithful_bind (Rust.faithful_clone _) (faithful_of_eq ?_)
              simp [hs1, hs2, Rust.Result.is_err, refresh_fixed ids _ hf2, commit_to_eq ids _ hf3]
            · simp [hfl]
              refine Rust.faithful_bind (Rust.faithful_clone _) (faithful_of_eq ?_)
              simp [hs1, hs2, Rust.Result.is_err, refresh_fixed ids _ hf2, commit_to_eq ids _ hf3]
  · have hne : (idAt n.state prev.index.val != some prev) = true := by simpa using hp
    simp only [hne, if_true]
    by_cases hb : prev.index < n.state.base.index
    · exact ⟨(prev.index, some (.Conflict _)), n, faithful_of_eq (by simp [hb]; rfl), hf, Or.inl ⟨hp, rfl, rfl⟩⟩
    · exact ⟨(prev.index, some (.Conflict _)), n, faithful_of_eq (by simp [hb]; rfl), hf, Or.inl ⟨hp, rfl, rfl⟩⟩

end Jarl.Engine
