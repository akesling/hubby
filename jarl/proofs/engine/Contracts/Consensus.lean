import Contracts.Membership

/-!
# Consensus contracts (typed backend)

The deep-embedding `consensus` project proved properties of *expression slices*
cut out of `Membership::quorum`, `Membership::quorum_index`, `Node::append`,
`Node::commit_to` and `Node::advance_commit`. Here each property is stated
about the translated function that contains the expression.
-/

namespace Jarl.Contracts.Consensus
open Jarl Jarl.Contracts.Membership

/-! ## Frame lemmas: what `commit_to` and `append` do to the commit index -/

section Frame
variable {V S : Type} {N CAP : Nat} [Rust.Clone V] [Rust.Clone S]

theorem forIn_preserve {α β : Type} (l : List α) (b : β) (f : α → β → Rust.M (ForInStep β)) (P : β → Prop)
    (hb : P b) (hf : ∀ x ∈ l, ∀ c r, P c → f x c = pure r → P r.value) (r : β) (h : forIn l b f = pure r) : P r := by
  induction l generalizing b with
  | nil => have := Rust.pure_inj h; subst this; exact hb
  | cons x xs ih =>
    rw [List.forIn_cons] at h
    obtain ⟨s, hs, h2⟩ := Rust.bind_eq_pure h
    have hP := hf x (by simp) b s hb hs
    cases s with
    | done c => have := Rust.pure_inj h2; subst this; exact hP
    | yield c => exact ih c hP (fun y hy => hf y (by simp [hy])) h2

theorem reset_election_state (n n' : Node V S N CAP) (h : n.reset_election = pure n') : n'.state = n.state := by
  unfold Node.reset_election at h
  obtain ⟨_, _, h⟩ := Rust.bind_eq_pure h
  obtain ⟨_, _, h⟩ := Rust.bind_eq_pure h
  have := Rust.pure_inj h; subst this; rfl

theorem follow_state (n n' : Node V S N CAP) (l : Option Id) (h : n.follow l = pure n') : n'.state = n.state := by
  unfold Node.follow at h
  split at h
  · obtain ⟨m, hm, h⟩ := Rust.bind_eq_pure h
    have := Rust.pure_inj h; subst this
    have := reset_election_state _ _ hm; exact this
  · obtain ⟨m, hm, h⟩ := Rust.bind_eq_pure h
    have := Rust.pure_inj h; subst this
    have := reset_election_state _ _ hm; exact this

theorem refresh_state (n n' : Node V S N CAP) (h : n.refresh_membership = pure n') : n'.state = n.state := by
  unfold Node.refresh_membership at h
  obtain ⟨_, _, h⟩ := Rust.bind_eq_pure h
  obtain ⟨_, _, h⟩ := Rust.bind_eq_pure h
  obtain ⟨s, hs, h⟩ := Rust.bind_eq_pure h
  have hs' : s.state = n.state := by
    refine forIn_preserve _ _ _ (fun c : Node V S N CAP => c.state = n.state) ?_ ?_ s hs
    · rfl
    intro x _ c r hc hr
    dsimp only at hr
    split at hr
    · obtain ⟨_, _, hr⟩ := Rust.bind_eq_pure hr
      obtain ⟨_, _, hr⟩ := Rust.bind_eq_pure hr
      obtain ⟨_, _, hr⟩ := Rust.bind_eq_pure hr
      obtain ⟨_, _, hr⟩ := Rust.bind_eq_pure hr
      obtain ⟨_, _, hr⟩ := Rust.bind_eq_pure hr
      obtain ⟨_, _, hr⟩ := Rust.bind_eq_pure hr
      obtain ⟨_, _, hr⟩ := Rust.bind_eq_pure hr
      have := Rust.pure_inj hr; subst this; exact hc
    · have := Rust.pure_inj hr; subst this; exact hc
  dsimp only at h
  split at h
  · obtain ⟨_, _, h⟩ := Rust.bind_eq_pure h
    obtain ⟨_, _, h⟩ := Rust.bind_eq_pure h
    split at h
    · obtain ⟨m, hm, h⟩ := Rust.bind_eq_pure h
      have := Rust.pure_inj h; subst this
      have := follow_state _ _ _ hm; rw [this]; exact hs'
    · have := Rust.pure_inj h; subst this; exact hs'
  · have := Rust.pure_inj h; subst this; exact hs'


theorem commit_to_eq (n n' : Node V S N CAP) (i : Rust.u64) (h : n.commit_to i = pure n') :
    (i.val ≤ n.state.hard.commit.val → n' = n) ∧
      (n.state.hard.commit.val < i.val → n'.state = { n.state with hard := { n.state.hard with commit := i } }) := by
  unfold Node.commit_to at h
  dsimp only at h
  split at h
  · rename_i hc
    simp only [decide_eq_true_eq, gt_iff_lt, Fin.lt_def] at hc
    obtain ⟨m, hm, h⟩ := Rust.bind_eq_pure h
    have := Rust.pure_inj h; subst this
    refine ⟨fun hle => absurd hc (by omega), fun _ => ?_⟩
    have := refresh_state _ _ hm; rw [this]
  · rename_i hc
    simp only [decide_eq_true_eq, gt_iff_lt, Fin.lt_def, Nat.not_lt] at hc
    have := Rust.pure_inj h; subst this
    exact ⟨fun _ => rfl, fun hlt => absurd hc (by omega)⟩

theorem commit_to_noop (n : Node V S N CAP) (i : Rust.u64) (h : i.val ≤ n.state.hard.commit.val) :
    n.commit_to i = pure n := by
  unfold Node.commit_to
  have : ¬ (i > n.state.hard.commit) := by simp [Fin.lt_def]; omega
  simp [this]

theorem commit_to_val (n n' : Node V S N CAP) (i : Rust.u64) (h : n.commit_to i = pure n') :
    n'.state.hard.commit.val = max n.state.hard.commit.val i.val ∧
      (n.state.hard.commit.val < n'.state.hard.commit.val → n'.state.hard.commit = i) := by
  obtain ⟨h1, h2⟩ := commit_to_eq n n' i h
  by_cases hc : i.val ≤ n.state.hard.commit.val
  · rw [h1 hc]; exact ⟨by omega, fun h => absurd h (Nat.lt_irrefl _)⟩
  · have := h2 (by omega)
    rw [this]; exact ⟨by simp only; omega, fun _ => rfl⟩


theorem sub_eq_pure {n : Nat} (a b c : Fin (2 ^ n)) (h : Rust.sub a b = pure c) : b.val ≤ a.val ∧ c.val = a.val - b.val := by
  unfold Rust.sub at h
  split at h
  · have := Rust.pure_inj h; subst this; rename_i hb; exact ⟨hb, rfl⟩
  · exact absurd h (by simp [Rust.fail]; intro h'; have := congrArg ExceptT.run h'; simp at this)

omit [Rust.Clone V] [Rust.Clone S] in
theorem truncate_hard (s s' : State V S CAP) (f : Rust.u64) (h : s.truncate f = pure s') : s'.hard = s.hard := by
  unfold State.truncate at h
  obtain ⟨b, hb, h⟩ := Rust.bind_eq_pure h
  have := Rust.pure_inj h; subst this
  have loop : ∀ k (s0 : State V S CAP), s0.len.val = k → s0.hard = s.hard → ∀ r,
      forIn Lean.Loop.mk s0 (fun (_ : Unit) (__s : State V S CAP) => do
        let t1 ← __s.last
        if (!(decide (t1.index ≥ f) && decide (__s.len > 0))) = true then pure (ForInStep.done __s)
        else do
          let t2 ← Rust.sub __s.len 1
          let t3 ← Rust.Slice.set __s.entries t2 none
          pure (ForInStep.yield ({ hard := __s.hard, snapshot := __s.snapshot, entries := t3, len := t2 } : State V S CAP)))
        = pure r → r.hard = s.hard := by
    intro k
    induction k using Nat.strongRecOn with
    | _ k ih =>
      intro s0 hk hh r hr
      change Lean.Loop.forIn _ _ _ = _ at hr
      rw [Lean.Loop.forIn_eq_of_monadTail] at hr
      obtain ⟨st, hst, hr⟩ := Rust.bind_eq_pure hr
      obtain ⟨t1, _, hst⟩ := Rust.bind_eq_pure hst
      split at hst
      · have := Rust.pure_inj hst; subst this
        have := Rust.pure_inj hr; subst this; exact hh
      · obtain ⟨t2, ht2, hst⟩ := Rust.bind_eq_pure hst
        obtain ⟨t3, _, hst⟩ := Rust.bind_eq_pure hst
        have := Rust.pure_inj hst; subst this
        obtain ⟨hle, hv⟩ := sub_eq_pure _ _ _ ht2
        simp only [Fin.val_one] at hle hv
        dsimp only at hr
        exact ih t2.val (by omega) { hard := s0.hard, snapshot := s0.snapshot, entries := t3, len := t2 } rfl hh r hr
  exact loop _ s rfl rfl b hb


omit [Rust.Clone V] [Rust.Clone S] in
theorem push_hard (s s' : State V S CAP) (e : Entry V) (r : Rust.Result Unit Error) (h : s.push e = pure (r, s')) :
    s'.hard = s.hard := by
  unfold State.push at h
  dsimp only at h
  split at h
  · have := Rust.pure_inj h; cases this; rfl
  · obtain ⟨_, _, h⟩ := Rust.bind_eq_pure h
    obtain ⟨_, _, h⟩ := Rust.bind_eq_pure h
    have := Rust.pure_inj h; cases this; rfl

/-- The commit index `append` leaves: unchanged, or exactly `max(commit, min(leader_commit, matched))`
    where `matched` is the index `append` reports. -/
theorem append_commit (n n' : Node V S N CAP) (prev : LogId) (entry : Option (Entry V)) (c : Rust.u64)
    (mi : Rust.u64) (rej : Option Rejection) (h : n.append prev entry c = pure ((mi, rej), n')) :
    n'.state.hard.commit = n.state.hard.commit ∨
      (n'.state.hard.commit.val = max n.state.hard.commit.val (Rust.min c mi).val ∧
        (n.state.hard.commit.val < n'.state.hard.commit.val → n'.state.hard.commit = Rust.min c mi)) := by
  have fin : ∀ (x : Node V S N CAP) (i : Rust.u64), x.state.hard.commit = n.state.hard.commit →
      x.commit_to (Rust.min c i) = pure n' → mi = i →
      n'.state.hard.commit.val = max n.state.hard.commit.val (Rust.min c mi).val ∧
        (n.state.hard.commit.val < n'.state.hard.commit.val → n'.state.hard.commit = Rust.min c mi) := by
    intro x i hx hc hm
    subst hm
    rw [← hx]
    exact commit_to_val x n' _ hc
  unfold Node.append at h
  dsimp only at h
  split at h
  · split at h
    · obtain ⟨_, _, h⟩ := Rust.bind_eq_pure h
      have := Rust.pure_inj h; cases this; exact Or.inl rfl
    · obtain ⟨_, _, h⟩ := Rust.bind_eq_pure h
      obtain ⟨_, _, h⟩ := Rust.bind_eq_pure h
      have := Rust.pure_inj h; cases this; exact Or.inl rfl
  · split at h
    · split at h
      · split at h
        · have := Rust.pure_inj h; cases this; exact Or.inl rfl
        · split at h
          · obtain ⟨_, _, h⟩ := Rust.bind_eq_pure h
            simp only [pure_bind] at h
            split at h
            · obtain ⟨m, hm, h⟩ := Rust.bind_eq_pure h
              have := Rust.pure_inj h; cases this
              right; exact fin n _ rfl hm rfl
            · obtain ⟨t5, _, h⟩ := Rust.bind_eq_pure h
              obtain ⟨m1, hm1, h⟩ := Rust.bind_eq_pure h
              obtain ⟨⟨r2, s2⟩, hx, h⟩ := Rust.bind_eq_pure h
              have hs2 : s2.hard = n.state.hard := (push_hard _ _ _ _ hx).trans (truncate_hard _ _ _ hm1)
              split at h
              · have := Rust.pure_inj h; cases this
                left; simp only; rw [hs2]
              · obtain ⟨m3, hm3, h⟩ := Rust.bind_eq_pure h
                obtain ⟨m4, hm4, h⟩ := Rust.bind_eq_pure h
                have := Rust.pure_inj h; cases this
                right
                have h3 := refresh_state _ _ hm3
                exact fin _ _ (by simp only; rw [h3]; simp only; rw [hs2]) hm4 rfl
          · simp only [pure_bind, Bool.false_eq_true, if_false] at h
            obtain ⟨t5, _, h⟩ := Rust.bind_eq_pure h
            obtain ⟨m1, hm1, h⟩ := Rust.bind_eq_pure h
            obtain ⟨⟨r2, s2⟩, hx, h⟩ := Rust.bind_eq_pure h
            have hs2 : s2.hard = n.state.hard := (push_hard _ _ _ _ hx).trans (truncate_hard _ _ _ hm1)
            split at h
            · have := Rust.pure_inj h; cases this
              left; simp only; rw [hs2]
            · obtain ⟨m3, hm3, h⟩ := Rust.bind_eq_pure h
              obtain ⟨m4, hm4, h⟩ := Rust.bind_eq_pure h
              have := Rust.pure_inj h; cases this
              right
              have h3 := refresh_state _ _ hm3
              exact fin _ _ (by simp only; rw [h3]; simp only; rw [hs2]) hm4 rfl
      · obtain ⟨m, hm, h⟩ := Rust.bind_eq_pure h
        have := Rust.pure_inj h; cases this
        right; exact fin n _ rfl hm rfl
    · obtain ⟨m, hm, h⟩ := Rust.bind_eq_pure h
      have := Rust.pure_inj h; cases this
      right; exact fin n _ rfl hm rfl


end Frame

/-! ## Majorities in `Membership::quorum` -/

section Quorums
variable {MAX : Nat}

/-- `count > total / 2` in `quorum` is strict majority: `quorum` succeeds iff
    `total < 2 * count` for the current voters and, when joint, the old voters. -/
theorem majority_strict (m : Jarl.Membership MAX) (a : Id → Rust.M Bool) (answer : Id → Bool)
    (hMAX : MAX < 2 ^ Rust.usizeBits) (normal : ∀ id, a id = pure (answer id)) :
    m.quorum a = pure true ↔ m.voters.length < 2 * m.voters.countP answer ∧
      (m.is_joint = true → m.old_voters.length < 2 * m.old_voters.countP answer) := by
  rw [Quorum.result m a answer hMAX normal]
  constructor
  · intro h
    have h := of_decide_eq_true (Rust.pure_inj h)
    unfold Quorum.Majority at h
    exact ⟨by have := h.1; omega, fun j => by have := h.2 j; omega⟩
  · rintro ⟨h1, h2⟩
    have : Quorum.Majority answer m.voters ∧ (m.is_joint = true → Quorum.Majority answer m.old_voters) :=
      ⟨by unfold Quorum.Majority; omega, fun j => by have := h2 j; unfold Quorum.Majority; omega⟩
    rw [decide_eq_true this]

/-- Two successful `quorum` calls over one configuration have acknowledgement
    counts summing to more than the voter count (current, and old when joint). -/
theorem majority_cardinality_overlap (m : Jarl.Membership MAX) (a1 a2 : Id → Rust.M Bool) (first second : Id → Bool)
    (hMAX : MAX < 2 ^ Rust.usizeBits) (n1 : ∀ id, a1 id = pure (first id)) (n2 : ∀ id, a2 id = pure (second id))
    (q1 : m.quorum a1 = pure true) (q2 : m.quorum a2 = pure true) :
    m.voters.length < m.voters.countP first + m.voters.countP second ∧
      (m.is_joint = true → m.old_voters.length < m.old_voters.countP first + m.old_voters.countP second) := by
  have h1 := (majority_strict m a1 first hMAX n1).mp q1
  have h2 := (majority_strict m a2 second hMAX n2).mp q2
  exact ⟨by omega, fun j => by have := h1.2 j; have := h2.2 j; omega⟩

/-- Majority intersection for the translated `quorum` (the old count-level
    lemma's connection to `quorum` is exactly `Quorum.quorums_intersect`). -/
theorem majority_intersection (m : Jarl.Membership MAX) (a1 a2 : Id → Rust.M Bool) (first second : Id → Bool)
    (hMAX : MAX < 2 ^ Rust.usizeBits) (n1 : ∀ id, a1 id = pure (first id)) (n2 : ∀ id, a2 id = pure (second id))
    (q1 : m.quorum a1 = pure true) (q2 : m.quorum a2 = pure true) :
    (∃ voter ∈ m.voters, first voter = true ∧ second voter = true) ∧
      (m.is_joint = true → ∃ voter ∈ m.old_voters, first voter = true ∧ second voter = true) :=
  Quorum.quorums_intersect m a1 a2 first second hMAX n1 n2 q1 q2

theorem voters_nodup (m : Jarl.Membership MAX) (u : UniqueIdentities m) : m.voters.Nodup :=
  ((List.filter_sublist (l := occ m)).map Member.id).nodup u

theorem old_voters_nodup (m : Jarl.Membership MAX) (u : UniqueIdentities m) : m.old_voters.Nodup :=
  ((List.filter_sublist (l := occ m)).map Member.id).nodup u

/-- Stable→joint→stable transitions: a quorum of the source configuration and a
    quorum of the joint configuration `source.joint(target)` share a source
    voter, and a quorum of the joint configuration and a quorum of its
    finalization share a target voter. No overlap of arbitrary old/new sets is
    assumed; identities are unique, as `restore`/`new`/`joint` establish. -/
theorem joint_transition_intersection (source target J : Jarl.Membership MAX) (hMAX : MAX < 2 ^ Rust.usizeBits)
    (us : UniqueIdentities source) (ut : UniqueIdentities target) (hJ : source.joint target = pure (.Ok J))
    (before during after : Id → Rust.M Bool) (gb gd ga : Id → Bool)
    (nb : ∀ id, before id = pure (gb id)) (nd : ∀ id, during id = pure (gd id)) (na : ∀ id, after id = pure (ga id))
    (qb : source.quorum before = pure true) (qd : J.quorum during = pure true)
    (qa : J.finalized.quorum after = pure true) :
    (∃ id ∈ source.voters, gb id = true ∧ gd id = true) ∧
      (∃ id ∈ J.finalized.voters, gd id = true ∧ ga id = true) := by
  rw [Quorum.result _ _ gb hMAX nb] at qb
  rw [Quorum.result _ _ gd hMAX nd] at qd
  rw [Quorum.result _ _ ga hMAX na] at qa
  have hb := Rust.pure_inj qb
  have hd := Rust.pure_inj qd
  have ha := Rust.pure_inj qa
  simp only [decide_eq_true_eq] at hb hd ha
  refine ⟨?_, ?_⟩
  · have ne : source.voters ≠ [] := by
      intro e; have := hb.1; rw [e] at this; simp [Quorum.Majority] at this
    have joint := (JointConstruction.joint_iff_source_voters source target J hMAX hJ).mpr ne
    have hold := hd.2 joint
    have uJ := JointConstruction.unique_identities source target J hMAX ut hJ
    have perm : J.old_voters.Perm source.voters :=
      (List.perm_ext_iff_of_nodup (old_voters_nodup J uJ) (voters_nodup source us)).mpr
        (JointConstruction.old_voters_exact source target J hMAX hJ)
    have hsrc : Quorum.Majority gd source.voters := by
      unfold Quorum.Majority at hold ⊢
      rw [← perm.length_eq, ← perm.countP_eq]; exact hold
    exact Quorum.majorities_intersect gb gd _ hb.1 hsrc
  · rw [MembershipProjection.finalization_preserves_voters] at ha ⊢
    exact Quorum.majorities_intersect gd ga _ hd.1 ha.1

end Quorums

/-! ## Positions in `Membership::quorum_index` -/

section QuorumIndex
variable {MAX : Nat}
open QuorumIndex

theorem rank_mem (vals : List Rust.u64) (hne : vals ≠ []) : rank vals ∈ vals := by
  obtain ⟨hp, hr⟩ := rank_eq vals hne
  rw [hr]
  exact (List.mergeSort_perm vals _).subset (List.getElem_mem hp)

/-- The majority position `count - (count / 2 + 1)` is in bounds: with a nonempty
    current voter set, `quorum_index` returns (no index panic) one of the
    acknowledged positions. -/
theorem majority_position_in_bounds (m : Jarl.Membership MAX) (a : Id → Rust.M Rust.u64) (matched : Id → Rust.u64)
    (hMAX : MAX < 2 ^ Rust.usizeBits) (normal : ∀ id, a id = pure (matched id)) (nonempty : m.voters ≠ []) :
    ∃ v, m.quorum_index a = pure v ∧ (v ∈ m.voters.map matched ∨ v ∈ m.old_voters.map matched) := by
  refine ⟨_, QuorumIndex.exact m a matched hMAX normal nonempty, ?_⟩
  have hc := rank_mem (m.voters.map matched) (by simpa using nonempty)
  split
  · rename_i hj
    have hold : m.old_voters ≠ [] := (SetInterpretation.joint_iff_old_nonempty m).mp hj
    have ho := rank_mem (m.old_voters.map matched) (by simpa using hold)
    unfold Rust.min
    split
    · exact Or.inl hc
    · exact Or.inr ho
  · exact Or.inl hc

/-- `new.min(old)` in `quorum_index`: a joint configuration commits exactly the
    smaller of the two majority positions, so never beyond either. -/
theorem joint_commit_requires_both (m : Jarl.Membership MAX) (a : Id → Rust.M Rust.u64) (matched : Id → Rust.u64)
    (hMAX : MAX < 2 ^ Rust.usizeBits) (normal : ∀ id, a id = pure (matched id)) (joint : m.is_joint = true)
    (r : Rust.u64) (result : m.quorum_index a = pure r) :
    r = Rust.min (rank (m.voters.map matched)) (rank (m.old_voters.map matched)) ∧
      r.val ≤ (rank (m.voters.map matched)).val ∧ r.val ≤ (rank (m.old_voters.map matched)).val := by
  have nonempty : m.voters ≠ [] := by
    intro h; rw [QuorumIndex.empty_current m a h] at result; exact fail_ne_pure _ _ result
  rw [QuorumIndex.exact m a matched hMAX normal nonempty, joint, if_pos rfl] at result
  have := Rust.pure_inj result
  subst this
  exact ⟨rfl, by rw [Rust.val_min]; exact Nat.min_le_left _ _, by rw [Rust.val_min]; exact Nat.min_le_right _ _⟩

end QuorumIndex

/-! ## Commit index in `Node` -/

section Commit
variable {V S : Type} {N CAP : Nat} [Rust.Clone V] [Rust.Clone S]

/-- `commit.min(matched)` passed by `Node::append` to `commit_to`: whenever
    `append` returns, the commit index never decreases, and if it advanced it is
    exactly `min(leader_commit, matched)` for the reported `matched` index — so
    a follower never commits beyond the leader's commit or its own matched log. -/
theorem follower_never_overcommits (n n' : Node V S N CAP) (prev : LogId) (entry : Option (Entry V))
    (leader : Rust.u64) (matched : Rust.u64) (rej : Option Rejection)
    (h : n.append prev entry leader = pure ((matched, rej), n')) :
    n.state.hard.commit.val ≤ n'.state.hard.commit.val ∧
      (n.state.hard.commit.val < n'.state.hard.commit.val →
        n'.state.hard.commit = Rust.min leader matched ∧
          n'.state.hard.commit.val ≤ leader.val ∧ n'.state.hard.commit.val ≤ matched.val) := by
  rcases append_commit n n' prev entry leader matched rej h with e | ⟨hv, hadv⟩
  · rw [e]; exact ⟨Nat.le_refl _, fun h => absurd h (Nat.lt_irrefl _)⟩
  · refine ⟨by omega, fun hlt => ⟨hadv hlt, ?_, ?_⟩⟩ <;> rw [hadv hlt, Rust.val_min]
    · exact Nat.min_le_left _ _
    · exact Nat.min_le_right _ _

/-- `if index > commit { commit = index }` in `commit_to`: whenever `commit_to`
    returns, the new commit index is exactly `max(commit, index)`; and when
    `index ≤ commit` it returns the node unchanged (no refresh runs). -/
theorem commit_never_regresses (n : Node V S N CAP) (i : Rust.u64) :
    (∀ n', n.commit_to i = pure n' →
      n'.state.hard.commit.val = max n.state.hard.commit.val i.val ∧
        n.state.hard.commit.val ≤ n'.state.hard.commit.val) ∧
      (i.val ≤ n.state.hard.commit.val → n.commit_to i = pure n) := by
  refine ⟨fun n' h => ?_, commit_to_noop n i⟩
  have := (commit_to_val n n' i h).1
  exact ⟨this, by omega⟩

/-- `id.term == self.state.hard.term` in `advance_commit`: when `advance_commit`
    reports progress, the new commit index is the `quorum_index` result, lies
    strictly beyond the old commit, and names a log entry of the current term;
    when it reports none, the node is unchanged. -/
theorem current_term_required (n n' : Node V S N CAP) (progress : Bool)
    (h : n.advance_commit = pure (progress, n')) :
    (progress = true → ∃ idx, n.membership.quorum_index (fun id => n.matched_fn id) = pure idx ∧
      n.state.hard.commit.val < idx.val ∧
      (∃ e, n.state.id_at idx = some e ∧ e.term = n.state.hard.term) ∧
      n.commit_to idx = pure n' ∧ n'.state.hard.commit = idx) ∧
    (progress = false → n' = n) := by
  unfold Node.advance_commit at h
  dsimp only at h
  obtain ⟨idx, hq, h⟩ := Rust.bind_eq_pure h
  split at h
  · rename_i hc
    obtain ⟨m, hm, h⟩ := Rust.bind_eq_pure h
    simp only [pure_bind] at h
    have := Rust.pure_inj h
    cases this
    refine ⟨fun _ => ⟨idx, hq, ?_, ?_, hm, ?_⟩, fun h => by cases h⟩
    · simp only [Bool.and_eq_true, decide_eq_true_eq, gt_iff_lt, Fin.lt_def] at hc; exact hc.1
    · simp only [Bool.and_eq_true] at hc
      have h2 := hc.2
      cases he : n.state.id_at idx with
      | none => rw [he] at h2; simp at h2
      | some e => rw [he] at h2; exact ⟨e, rfl, by simpa using h2⟩
    · simp only [Bool.and_eq_true, decide_eq_true_eq, gt_iff_lt, Fin.lt_def] at hc
      obtain ⟨h1, h2⟩ := commit_to_val n _ idx hm
      exact h2 (by omega)
  · simp only [pure_bind] at h
    have := Rust.pure_inj h
    cases this
    exact ⟨(fun h => by cases h), fun _ => rfl⟩

/-- Nodes reachable from `initial` by translated `commit_to` calls that returned. -/
inductive CommitTrace (initial : Node V S N CAP) : Node V S N CAP → Prop where
  | start : CommitTrace initial initial
  | step {current next : Node V S N CAP} {index : Rust.u64} :
      CommitTrace initial current → current.commit_to index = pure next → CommitTrace initial next

/-- Arbitrarily many `commit_to` steps never lower the commit index, and every
    further returning step keeps it at least as large. -/
theorem commit_sequence_monotone (initial final : Node V S N CAP) (trace : CommitTrace initial final) :
    initial.state.hard.commit.val ≤ final.state.hard.commit.val ∧
      ∀ (index : Rust.u64) (next : Node V S N CAP), final.commit_to index = pure next →
        final.state.hard.commit.val ≤ next.state.hard.commit.val := by
  refine ⟨?_, fun index next h => ((commit_never_regresses final index).1 next h).2⟩
  induction trace with
  | start => exact Nat.le_refl _
  | step _ h ih => exact Nat.le_trans ih ((commit_never_regresses _ _).1 _ h).2

end Commit

end Jarl.Contracts.Consensus
