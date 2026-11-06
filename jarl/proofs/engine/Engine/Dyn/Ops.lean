import Engine.Dyn.Refresh
import Contracts.MembershipQuorum

/-!
# Internal helpers of a dynamic node

Each helper is characterized by what a successful run did. Votes and match
indices are read through an identity's slot (`votedBy`, `matchOf`), so an
identity's progress is whatever its own slot records, and an identity without
a slot counts as no vote and match index zero.
-/

set_option linter.unusedSectionVars false

namespace Jarl.Engine.Dyn
open Jarl Jarl.Engine

variable {V S : Type} {MAX CAP : Nat} [Rust.Clone V] [Rust.Clone S]

/-- The slot of identity `id`. -/
def pos (n : DNode V S MAX CAP) (id : Id) : Option Rust.usize :=
  Rust.Iter.position n.peers.toList (fun p => p == some id)

/-- Whether identity `id`'s slot holds a vote. -/
def votedBy (n : DNode V S MAX CAP) (id : Id) : Bool :=
  match pos n id with
  | some i => n.votes[i.val]!
  | none => false

/-- Identity `id`'s match index. -/
def matchOf (n : DNode V S MAX CAP) (id : Id) : Rust.u64 :=
  match pos n id with
  | some i => n.matched[i.val]!
  | none => 0

theorem pos_lt (n : DNode V S MAX CAP) (id : Id) (i : Rust.usize) (hMAX : MAX < 2 ^ Rust.usizeBits)
    (h : pos n id = some i) : i.val < MAX ∧ n.peers[i.val]! = some id := by
  obtain ⟨hs, hp⟩ := position_some _ _ _ (by simpa using hMAX) h
  have hi : i.val < MAX := by simpa using hs
  refine ⟨hi, ?_⟩
  rw [getElem!_pos n.peers i.val hi]
  have : n.peers.toList[i.val]'hs = n.peers[i.val] := by first | rfl | simp
  rw [← this]; simpa using hp

/-- The first slot holding `id`. -/
theorem pos_of_slot (n : DNode V S MAX CAP) (_hMAX : MAX < 2 ^ Rust.usizeBits)
    (huniq : ∀ i j : Fin MAX, ∀ x, n.peers[i] = some x → n.peers[j] = some x → i = j)
    (i : Fin MAX) (id : Id) (h : n.peers[i] = some id) : pos n id = some (Rust.ofNat i.val) := by
  simp only [pos, Rust.Iter.position]
  have hfind : List.findIdx? (fun p => p == some id) n.peers.toList = some i.val := by
    rw [List.findIdx?_eq_some_iff_getElem]
    refine ⟨by simp, by simpa using h, ?_⟩
    intro j hj
    simp only [beq_iff_eq]
    intro he
    have hjM : j < MAX := by have := i.isLt; omega
    have := huniq ⟨j, hjM⟩ i id (by simpa using he) h
    have := congrArg Fin.val this; simp at this; omega
  rw [hfind]; rfl

theorem pos_none (n : DNode V S MAX CAP) (id : Id) (h : pos n id = none) : ∀ i : Fin MAX, n.peers[i] ≠ some id := by
  intro i hi
  simp only [pos, Rust.Iter.position, Option.map_eq_none_iff, List.findIdx?_eq_none_iff] at h
  have := h (some id) (by simp [List.mem_iff_getElem]; exact ⟨i.val, i.isLt, by simpa using hi⟩)
  simp at this

/-! ## Quorum checks -/

theorem majority_iff (answer : Id → Bool) (l : List Id) :
    Jarl.Contracts.Membership.Quorum.Majority answer l ↔ Maj l (fun id => answer id = true) := by
  unfold Jarl.Contracts.Membership.Quorum.Majority Maj
  have : l.countP answer = l.countP (fun x => @decide (answer x = true) (Classical.propDecidable _)) := by
    apply List.countP_congr; intro x _; simp
  rw [this]

theorem quorum_iff (m : Membership MAX) (answer : Id → Bool) :
    (Jarl.Contracts.Membership.Quorum.Majority answer m.voters ∧
      (m.is_joint = true → Jarl.Contracts.Membership.Quorum.Majority answer m.old_voters)) ↔
      Quorum m (fun id => answer id = true) := by
  unfold Quorum; rw [majority_iff, majority_iff]

/-- `election_quorum`: a quorum of the node's configuration has votes in its slots. -/
theorem election_quorum_eq' (n : DNode V S MAX CAP) (hMAX : MAX < 2 ^ Rust.usizeBits) :
    ∃ b, Node.election_quorum n = pure b ∧ (b = true ↔ Quorum n.membership (fun id => votedBy n id = true)) := by
  unfold Node.election_quorum
  rw [Jarl.Contracts.Membership.Quorum.result n.membership _ (votedBy n) hMAX]
  · refine ⟨_, by first | rfl | simp only [pure_bind], ?_⟩
    rw [decide_eq_true_iff, quorum_iff]
  · intro id
    unfold votedBy
    cases hp : pos n id with
    | none => simp only [pos] at hp; simp [hp, Rust.Option.is_some_andM]
    | some i =>
      obtain ⟨hi, -⟩ := pos_lt n id i hMAX hp
      simp only [pos] at hp
      simp [hp, Rust.Option.is_some_andM, hi]

/-- `matched(id)` reads the identity's slot. -/
theorem matched_fn_eq' (n : DNode V S MAX CAP) (hMAX : MAX < 2 ^ Rust.usizeBits) (id : Id) :
    Node.matched_fn n id = pure (matchOf n id) := by
  unfold Node.matched_fn matchOf
  cases hp : pos n id with
  | none => simp only [pos] at hp; simp [hp, Rust.Option.map_orM]
  | some i =>
    obtain ⟨hi, -⟩ := pos_lt n id i hMAX hp
    simp only [pos] at hp
    simp [hp, Rust.Option.map_orM, hi]

/-- A quorum of the node's configuration has matched at least `v`. -/
def QuorumAt (n : DNode V S MAX CAP) (v : Rust.u64) : Prop :=
  Quorum n.membership (fun id => v.val ≤ (matchOf n id).val)

/-- `commit_to(i)`: raise the commit index and refresh, or nothing. -/
def CommitTo (n : DNode V S MAX CAP) (i : Rust.u64) (n' : DNode V S MAX CAP) : Prop :=
  (n.state.hard.commit < i ∧ Refresh (commitTo n i) n') ∨ (¬ n.state.hard.commit < i ∧ n' = n)

theorem commit_to_rel (n n' : DNode V S MAX CAP) (i : Rust.u64) (hh : n.hooks = some hooksC) (hl : Layout n.state)
    (hc : Contig n.state) (hMAX : MAX < 2 ^ Rust.usizeBits)
    (h0 : 0 < n.config.election_ticks.val) (h1 : n.config.election_ticks.val ≤ 2 ^ 63)
    (huniq : ∀ i j : Fin MAX, ∀ x, n.peers[i] = some x → n.peers[j] = some x → i = j)
    (h : Node.commit_to n i = pure n') : CommitTo n i n' := by
  unfold Node.commit_to at h
  by_cases hc' : n.state.hard.commit < i
  · simp only [gt_iff_lt, hc', decide_true, if_true, bind_pure] at h
    left
    have hct : commitTo n i = { n with state := { n.state with hard := { n.state.hard with commit := i } }, dirty := true } := by
      simp [commitTo, hc']
    refine ⟨hc', refresh_rel _ _ (by rw [hct]; exact hh) (by rw [hct]; exact hl) (by rw [hct]; exact hc) hMAX
      (by rw [hct]; exact h0) (by rw [hct]; exact h1) (by rw [hct]; exact huniq) ?_⟩
    rw [hct]; exact h
  · simp only [gt_iff_lt, hc', decide_false, Bool.false_eq_true, if_false] at h
    exact Or.inr ⟨hc', (Rust.pure_inj h).symm⟩

/-- What `advance_commit` may do: nothing, or commit a current-term index a
    quorum of the configuration has matched. -/
def Adv' (n n' : DNode V S MAX CAP) : Prop :=
  n' = n ∨ ∃ v : Rust.u64, QuorumAt n v ∧ n.state.hard.commit < v ∧
    Rust.Option.is_some_and (State.id_at n.state v) (fun id => id.term == n.state.hard.term) = true ∧
    CommitTo n v n'

theorem majorityAt_iff (matched : Id → Rust.u64) (l : List Id) (x : Rust.u64) :
    Jarl.Contracts.Membership.QuorumIndex.MajorityAt matched l x ↔ Maj l (fun id => x.val ≤ (matched id).val) := by
  unfold Jarl.Contracts.Membership.QuorumIndex.MajorityAt Maj
  have : (l.map matched).countP (fun v => decide (x.val ≤ v.val)) =
      l.countP (fun id => @decide (x.val ≤ (matched id).val) (Classical.propDecidable _)) := by
    rw [List.countP_map]; apply List.countP_congr; intro y _; simp
  rw [this]

theorem advance_rel' (n : DNode V S MAX CAP) (b : Bool) (n' : DNode V S MAX CAP)
    (hh : n.hooks = some hooksC) (hl : Layout n.state) (hc : Contig n.state) (hMAX : MAX < 2 ^ Rust.usizeBits)
    (h0 : 0 < n.config.election_ticks.val) (h1 : n.config.election_ticks.val ≤ 2 ^ 63)
    (huniq : ∀ i j : Fin MAX, ∀ x, n.peers[i] = some x → n.peers[j] = some x → i = j)
    (h : Node.advance_commit n = pure (b, n')) : Adv' n n' := by
  unfold Node.advance_commit at h
  obtain ⟨v, hv, h⟩ := Rust.bind_eq_pure h
  have hq := (Jarl.Contracts.Membership.QuorumIndex.result_majority n.membership _ (matchOf n) hMAX
    (fun id => by first | exact matched_fn_eq' n hMAX id | (simp only [bind_pure]; exact matched_fn_eq' n hMAX id)) v hv v).mp (Nat.le_refl _)
  have hQ : QuorumAt n v := ⟨(majorityAt_iff _ _ _).mp hq.1, fun hj => (majorityAt_iff _ _ _).mp (hq.2 hj)⟩
  dsimp only at h
  split at h
  · rename_i hcond
    simp only [Bool.and_eq_true, decide_eq_true_eq, gt_iff_lt] at hcond
    obtain ⟨m, hm, h⟩ := Rust.bind_eq_pure h
    cases Rust.pure_inj h
    exact Or.inr ⟨v, hQ, hcond.1, hcond.2, commit_to_rel n _ v hh hl hc hMAX h0 h1 huniq hm⟩
  · left; exact (congrArg Prod.snd (Rust.pure_inj h)).symm

/-! ## Broadcast and vote requests -/

/-- `Replicate` queued for every slot other than the node's own whose identity
    is in the configuration. -/
def bcastD (n : DNode V S MAX CAP) : DNode V S MAX CAP :=
  { n with outbox := Vector.ofFn fun j => if j.val ≠ n.local.val ∧ Rust.Option.is_some_and n.peers[j] (fun id => Membership.contains n.membership id) = true then some .Replicate else n.outbox[j] }

theorem broadcast_eq' (n : DNode V S MAX CAP) (hMAX : MAX < 2 ^ Rust.usizeBits) :
    Node.broadcast n = pure (bcastD n) := by
  unfold Node.broadcast
  simp only [bind_pure]
  refine Rust.forIn_eq_inv _ _ _ _
    (fun k b => b = { n with outbox := Vector.ofFn fun j => if j.val < k ∧ (j.val ≠ n.local.val ∧ Rust.Option.is_some_and n.peers[j] (fun id => Membership.contains n.membership id) = true) then some .Replicate else n.outbox[j] }) ?_ ?_ ?_
  · have : (Vector.ofFn fun j : Fin MAX =>
        if j.val < 0 ∧ (j.val ≠ n.local.val ∧
          Rust.Option.is_some_and n.peers[j] (fun id => Membership.contains n.membership id) = true)
        then some Outbound.Replicate else n.outbox[j]) = n.outbox := by
      ext j hj; simp
    rw [this]
  · intro k hk b hb
    obtain ⟨hget, hkN⟩ := range_get MAX hMAX k hk
    rw [hget]
    have hv : (Rust.ofNat k : Rust.usize).val = k := by simp [Rust.ofNat]; uomega
    rw [hb]
    by_cases hkl : k = n.local.val
    · refine ⟨_, ?_, rfl⟩
      have : (Rust.ofNat k : Rust.usize) = n.local := Fin.ext (by rw [hv, hkl])
      simp only [this, bne_self_eq_false, Bool.false_eq_true, if_false, pure_bind]
      congr 3
      ext j hj
      simp only [Vector.getElem_ofFn]
      by_cases hjk : j = k
      · subst hjk; simp [hkl]
      · have hlt : j < k ↔ j < k + 1 := by omega
        simp only [hlt]
    · have hne : (Rust.ofNat k : Rust.usize) ≠ n.local := fun e => hkl (by rw [← hv, e])
      have hp : (Rust.ofNat k : Rust.usize).val < MAX := by rw [hv]; exact hkN
      by_cases hcont : Rust.Option.is_some_and n.peers[k] (fun id => Membership.contains n.membership id) = true
      · refine ⟨_, ?_, rfl⟩
        simp only [bne_iff_ne, ne_eq, hne, not_false_eq_true, if_true, Rust.Slice.index_ok _ _ hp,
          pure_bind, hv, hcont, replicate_eq _ _ hMAX hp]
        congr 3
        ext j hj
        simp only [Vector.getElem_set, Vector.getElem_ofFn]
        split
        · rename_i h; subst h; simp [hkl, hcont]
        · split <;> split <;> first | rfl | (rename_i h1 h2; exfalso; omega) | (rename_i h1 h2 h3; omega) | simp_all <;> omega
      · refine ⟨_, ?_, rfl⟩
        have hf : Rust.Option.is_some_and n.peers[k] (fun id => Membership.contains n.membership id) = false := by
          simpa using hcont
        simp only [bne_iff_ne, ne_eq, hne, not_false_eq_true, if_true, Rust.Slice.index_ok _ _ hp,
          pure_bind, hv, hf, Bool.false_eq_true, if_false]
        congr 3
        ext j hj
        simp only [Vector.getElem_ofFn]
        by_cases hjk : j = k
        · subst hjk; simp [hf]
        · split <;> split <;> first | rfl | omega | simp_all <;> omega
  · intro b hb
    rw [hb]; unfold bcastD
    congr 1
    ext j hj
    simp [Rust.Iter.range, Rust.val_usizeOf _ hMAX]

/-! ## Barrier, leadership and campaigns -/

/-- A leader's own append: the new state, a pending save from `idx`, and its own match index when it has a slot. -/
def ownAppendD (n : DNode V S MAX CAP) (s' : DState V S MAX CAP) (idx : Rust.u64) : DNode V S MAX CAP :=
  { n with state := s', dirty := true, log_from := some idx, matched := if h : n.local.val < MAX then n.matched.set n.local.val idx h else n.matched }

/-- What `barrier` may do: nothing, or append a current-term no-op at the next
    index and then possibly advance the commit index. -/
def BarrierD (n n' : DNode V S MAX CAP) : Prop :=
  n' = n ∨ ∃ (s' : DState V S MAX CAP) (idx : Rust.u64),
    idx.val = (lastId n.state).index.val + 1 ∧ (lastId n.state).term ≠ n.state.hard.term ∧
    ret s' = ret n.state ++ [{ id := { index := idx, term := n.state.hard.term }, value := none }] ∧
    s'.hard = n.state.hard ∧ s'.snapshot = n.state.snapshot ∧ Layout s' ∧ Contig s' ∧
    Adv' (ownAppendD n s' idx) n'

/-- The facts the helpers need of a node. -/
structure Pre (n : DNode V S MAX CAP) : Prop where
  hooks : n.hooks = some hooksC
  layout : Layout n.state
  contig : Contig n.state
  n_lt : MAX < 2 ^ Rust.usizeBits
  cap_lt : CAP < 2 ^ Rust.usizeBits
  e0 : 0 < n.config.election_ticks.val
  e1 : n.config.election_ticks.val ≤ 2 ^ 63
  uniq : ∀ i j : Fin MAX, ∀ x, n.peers[i] = some x → n.peers[j] = some x → i = j

theorem barrier_rel' (n n' : DNode V S MAX CAP) (hp : Pre n) (h : Node.barrier n = pure n') : BarrierD n n' := by
  have hl := hp.layout
  unfold Node.barrier at h
  simp only [last_eq _ hl.1, pure_bind] at h
  by_cases h1 : ((lastId n.state).term == n.state.hard.term || State.full n.state) = true
  · rw [if_pos h1] at h; exact Or.inl (Rust.pure_inj h).symm
  rw [if_neg h1] at h
  have hterm : (lastId n.state).term ≠ n.state.hard.term := by
    intro e; simp [e] at h1
  have hfull : n.state.len.val < CAP := by
    have hf0 : State.full n.state = false := by
      cases hfl : State.full n.state <;> simp_all
    have hne : n.state.len ≠ Rust.usizeOf CAP := by
      intro e; simp [State.full, e] at hf0
    have := hl.1
    rcases Nat.lt_or_ge n.state.len.val CAP with h' | h'
    · exact h'
    · exact absurd (Fin.ext (by rw [Rust.val_usizeOf _ hp.cap_lt]; omega)) hne
  by_cases h2 : (lastId n.state).index.val + (1 : Rust.u64).val < 2 ^ 64
  · simp only [Rust.checked_add_eq, dif_pos h2] at h
    obtain ⟨s', hpush, hh, hsn, hr, hlen, hl'⟩ := push_ok n.state
      { id := { index := ⟨(lastId n.state).index.val + (1 : Rust.u64).val, h2⟩, term := n.state.hard.term },
        value := none } hp.cap_lt hl hfull
    have hc' : Contig s' := by
      apply contig_push n.state s' _ hp.contig (by simp [State.base, hsn]) hr
      simp only
      rw [lastId_eq n.state hp.contig]; simp
    rw [hpush] at h
    simp only [pure_bind, Rust.Result.is_ok, if_true] at h
    right
    refine ⟨s', _, by simp, hterm, hr, hh, hsn, hl', hc', ?_⟩
    have hp' : Pre (ownAppendD n s' ⟨(lastId n.state).index.val + (1 : Rust.u64).val, h2⟩) :=
      { hp with layout := hl', contig := hc', uniq := hp.uniq }
    by_cases hlt : n.local.val < MAX
    · have hd : decide (n.local < Rust.usizeOf MAX) = true := by
        simp [Fin.lt_def, Rust.val_usizeOf _ hp.n_lt, hlt]
      simp only [hd, if_true, Rust.Slice.set_ok _ _ _ hlt, pure_bind] at h
      obtain ⟨⟨b, m⟩, hm, h⟩ := Rust.bind_eq_pure h
      cases Rust.pure_inj h
      apply advance_rel' _ b _ hp'.hooks hp'.layout hp'.contig hp.n_lt hp'.e0 hp'.e1 hp'.uniq
      simpa [ownAppendD, hlt] using hm
    · have hd : decide (n.local < Rust.usizeOf MAX) = false := by
        simp [Fin.lt_def, Rust.val_usizeOf _ hp.n_lt, hlt]
      simp only [hd, Bool.false_eq_true, if_false] at h
      obtain ⟨⟨b, m⟩, hm, h⟩ := Rust.bind_eq_pure h
      cases Rust.pure_inj h
      apply advance_rel' _ b _ hp'.hooks hp'.layout hp'.contig hp.n_lt hp'.e0 hp'.e1 hp'.uniq
      simpa [ownAppendD, hlt] using hm
  · simp only [Rust.checked_add_eq, dif_neg h2] at h
    exact Or.inl (Rust.pure_inj h).symm

/-- The node just after `become_leader` sets its leader bookkeeping. -/
def leaderInitD (n : DNode V S MAX CAP) : DNode V S MAX CAP :=
  { n with quorum_elapsed := 0, active := Rust.Slice.fill n.active false, role := .Leader, leader := some n.config.id, elapsed := 0, «next» := Rust.Slice.fill n.next (Rust.saturating_add (lastId n.state).index 1), matched := if h : n.local.val < MAX then (Rust.Slice.fill n.matched 0).set n.local.val (lastId n.state).index h else Rust.Slice.fill n.matched 0 }

/-- What `become_leader` does: leader bookkeeping, `barrier`, then `broadcast`. -/
def BecomeLeaderD (n n' : DNode V S MAX CAP) : Prop :=
  ∃ n2, BarrierD (leaderInitD n) n2 ∧ n' = bcastD n2

theorem become_leader_rel' (n n' : DNode V S MAX CAP) (hp : Pre n) (h : Node.become_leader n = pure n') :
    BecomeLeaderD n n' := by
  unfold Node.become_leader at h
  simp only [last_eq _ hp.layout.1, pure_bind] at h
  have hp' : Pre (leaderInitD n) := { hp with layout := hp.layout, contig := hp.contig, uniq := hp.uniq }
  by_cases hlt : n.local.val < MAX
  · have hd : decide (n.local < Rust.usizeOf MAX) = true := by
      simp [Fin.lt_def, Rust.val_usizeOf _ hp.n_lt, hlt]
    simp only [hd, if_true, Rust.Slice.set_ok _ _ _ hlt, pure_bind] at h
    obtain ⟨n2, hb, h⟩ := Rust.bind_eq_pure h
    have hb' : Node.barrier (leaderInitD n) = pure n2 := by simpa [leaderInitD, hlt] using hb
    have hB := barrier_rel' _ _ hp' hb'
    rw [broadcast_eq' _ hp.n_lt] at h
    exact ⟨n2, hB, (Rust.pure_inj h).symm⟩
  · have hd : decide (n.local < Rust.usizeOf MAX) = false := by
      simp [Fin.lt_def, Rust.val_usizeOf _ hp.n_lt, hlt]
    simp only [hd, Bool.false_eq_true, if_false] at h
    obtain ⟨n2, hb, h⟩ := Rust.bind_eq_pure h
    have hb' : Node.barrier (leaderInitD n) = pure n2 := by simpa [leaderInitD, hlt] using hb
    have hB := barrier_rel' _ _ hp' hb'
    rw [broadcast_eq' _ hp.n_lt] at h
    exact ⟨n2, hB, (Rust.pure_inj h).symm⟩

/-- Vote requests queued for every other slot whose identity votes in the configuration. -/
def requestVotesD (n : DNode V S MAX CAP) : DNode V S MAX CAP :=
  { n with outbox := Vector.ofFn fun j => if j.val ≠ n.local.val ∧ Rust.Option.is_some_and n.peers[j] (fun id => Membership.is_voter n.membership id) = true then some .Vote else n.outbox[j] }

/-- The node just after `campaign(term)` updates its durable vote and role. -/
def candidateD (n : DNode V S MAX CAP) (t : Rust.u64) (h : n.local.val < MAX) : DNode V S MAX CAP :=
  { n with prevoting := none, state := { n.state with hard := { n.state.hard with term := t, voted_for := some n.config.id } }, dirty := true, role := .Candidate, leader := none, votes := (Rust.Slice.fill n.votes false).set n.local.val true h }

/-- What `campaign(term)` does: vote for itself in `term`, then win at once on a
    quorum of its own vote, or request votes. -/
def CampaignD (n : DNode V S MAX CAP) (t : Rust.u64) (n' : DNode V S MAX CAP) : Prop :=
  ∃ (h : n.local.val < MAX) (n1 : DNode V S MAX CAP), Timers (candidateD n t h) n1 ∧
    ((Quorum n1.membership (fun id => votedBy n1 id = true) ∧ BecomeLeaderD n1 n') ∨
      (¬ Quorum n1.membership (fun id => votedBy n1 id = true) ∧ n' = requestVotesD n1))

theorem request_votes_eq (n : DNode V S MAX CAP) (hMAX : MAX < 2 ^ Rust.usizeBits) :
    forIn (Rust.Iter.range 0 (Rust.usizeOf MAX)) n (fun peer (self : DNode V S MAX CAP) => do
      let t4 ← if (peer != self.«local») then do
          let t3 ← Rust.Slice.index self.peers peer
          pure (Rust.Option.is_some_and t3 (fun id => Membership.is_voter self.membership id))
        else pure false
      if t4 then do
        let m_2 ← Node.send self peer Outbound.Vote
        pure (ForInStep.yield m_2)
      else pure (ForInStep.yield self)) = pure (requestVotesD n) := by
  refine Rust.forIn_eq_inv _ _ _ _
    (fun k b => b = { n with outbox := Vector.ofFn fun j => if j.val < k ∧ (j.val ≠ n.local.val ∧ Rust.Option.is_some_and n.peers[j] (fun id => Membership.is_voter n.membership id) = true) then some .Vote else n.outbox[j] }) ?_ ?_ ?_
  · have : (Vector.ofFn fun j : Fin MAX => if j.val < 0 ∧ (j.val ≠ n.local.val ∧ Rust.Option.is_some_and n.peers[j] (fun id => Membership.is_voter n.membership id) = true) then some Outbound.Vote else n.outbox[j]) = n.outbox := by
      ext j hj; simp
    rw [this]
  · intro k hk b hb
    obtain ⟨hget, hkN⟩ := range_get MAX hMAX k hk
    rw [hget]
    have hv : (Rust.ofNat k : Rust.usize).val = k := by simp [Rust.ofNat]; uomega
    rw [hb]
    by_cases hkl : k = n.local.val
    · refine ⟨_, ?_, rfl⟩
      have : (Rust.ofNat k : Rust.usize) = n.local := Fin.ext (by rw [hv, hkl])
      simp only [this, bne_self_eq_false, Bool.false_eq_true, if_false, pure_bind]
      congr 3
      ext j hj
      simp only [Vector.getElem_ofFn]
      by_cases hjk : j = k
      · subst hjk; simp [hkl]
      · have hlt : j < k ↔ j < k + 1 := by omega
        simp only [hlt]
    · have hne : (Rust.ofNat k : Rust.usize) ≠ n.local := fun e => hkl (by rw [← hv, e])
      have hp : (Rust.ofNat k : Rust.usize).val < MAX := by rw [hv]; exact hkN
      by_cases hcont : Rust.Option.is_some_and n.peers[k] (fun id => Membership.is_voter n.membership id) = true
      · refine ⟨_, ?_, rfl⟩
        simp only [bne_iff_ne, ne_eq, hne, not_false_eq_true, if_true, Rust.Slice.index_ok _ _ hp,
          pure_bind, hv, hcont, send_eq _ _ _ hMAX hp]
        congr 3
        ext j hj
        simp only [Vector.getElem_set, Vector.getElem_ofFn]
        split
        · rename_i h; subst h; simp [hkl, hcont]
        · rename_i hjk
          have hlt : j < k ↔ j < k + 1 := by omega
          simp only [hlt]
      · refine ⟨_, ?_, rfl⟩
        have hf : Rust.Option.is_some_and n.peers[k] (fun id => Membership.is_voter n.membership id) = false := by
          simpa using hcont
        simp only [bne_iff_ne, ne_eq, hne, not_false_eq_true, if_true, Rust.Slice.index_ok _ _ hp,
          pure_bind, hv, hf, Bool.false_eq_true, if_false]
        congr 3
        ext j hj
        simp only [Vector.getElem_ofFn]
        by_cases hjk : j = k
        · subst hjk; simp [hf]
        · have hlt : j < k ↔ j < k + 1 := by omega
          simp only [hlt]
  · intro b hb
    rw [hb]; unfold requestVotesD
    congr 1
    ext j hj
    simp [Rust.Iter.range, Rust.val_usizeOf _ hMAX]

theorem reset_timers' (n : DNode V S MAX CAP) (h0 : 0 < n.config.election_ticks.val)
    (h1 : n.config.election_ticks.val ≤ 2 ^ 63) : ∃ n', Node.reset_election n = pure n' ∧ Timers n n' := by
  obtain ⟨r, d, h⟩ := reset_election_eq n h0 h1
  exact ⟨_, h, r, d, rfl⟩

theorem pre_timers (n n' : DNode V S MAX CAP) (hp : Pre n) (h : Timers n n') : Pre n' := by
  obtain ⟨r, d, rfl⟩ := h; exact { hp with layout := hp.layout, contig := hp.contig, uniq := hp.uniq }

theorem campaign_rel' (n n' : DNode V S MAX CAP) (hp : Pre n) (t : Rust.u64) (h : Node.campaign n t = pure n') :
    CampaignD n t n' := by
  unfold Node.campaign at h
  dsimp only at h
  obtain ⟨vt, hvt, h⟩ := Rust.bind_eq_pure h
  have hlt : n.local.val < MAX := by
    apply Classical.byContradiction; intro hge
    simp only [Rust.Slice.set, hge, dite_false] at hvt
    exact fail_ne_pure' _ _ hvt
  rw [Rust.Slice.set_ok _ _ _ hlt] at hvt
  cases Rust.pure_inj hvt
  obtain ⟨n1, hr, ht⟩ := reset_timers' (candidateD n t hlt) hp.e0 hp.e1
  have hpc : Pre (candidateD n t hlt) := { hp with layout := hp.layout, contig := hp.contig, uniq := hp.uniq }
  have hp1 := pre_timers _ _ hpc ht
  have hr' : Node.reset_election { n with prevoting := none, state := { n.state with hard := { n.state.hard with term := t, voted_for := some n.config.id } }, dirty := true, role := .Candidate, leader := none, votes := (Rust.Slice.fill n.votes false).set n.local.val true hlt } = pure n1 := hr
  rw [hr', pure_bind] at h
  obtain ⟨b, hq, hb⟩ := election_quorum_eq' n1 hp.n_lt
  rw [hq, pure_bind] at h
  refine ⟨hlt, n1, ht, ?_⟩
  cases b
  · right
    refine ⟨fun hQ => by simpa using hb.mpr hQ, ?_⟩
    simp only [Bool.false_eq_true, if_false] at h
    rw [request_votes_eq n1 hp.n_lt] at h
    simp only [pure_bind] at h
    exact (Rust.pure_inj h).symm
  · left
    refine ⟨hb.mp rfl, ?_⟩
    simp only [if_true] at h
    obtain ⟨m, hm, h⟩ := Rust.bind_eq_pure h
    cases Rust.pure_inj h
    exact become_leader_rel' _ _ hp1 hm

end Jarl.Engine.Dyn
