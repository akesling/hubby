import Engine.Dyn.Common
import Engine.Dyn.OpStep

/-!
# Preservation: delivering replication messages
-/

set_option linter.unusedSectionVars false

namespace Jarl.Engine.Dyn
open Jarl Jarl.Engine

variable {V S : Type} {MAX CAP K : Nat} [Rust.Clone V] [Rust.Clone S]

namespace PLog

/-! ## Frames -/

theorem setLive_same (C : World V S MAX CAP K) (k : Fin K) : C.setLive k (C.live k) = C := by
  cases C with
  | mk live disk sent =>
    simp only [World.setLive]
    congr 1
    funext j
    split
    · rename_i h; subst h; rfl
    · rfl

theorem setLive_node (C : World V S MAX CAP K) (k : Fin K) (m : DNode V S MAX CAP) :
    (C.setLive k ⟨m⟩).node k = m := by simp [World.setLive, World.node]

/-- The clauses of `Inv` about node `k` hold of its current state. -/
theorem local_self (ids : Vector Id K) (g : Membership MAX) (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K)
    (hi : Inv ids g C G) (k : Fin K) : LocalOk' ids g C G k (C.live k) := by
  have hs : C.setLive k (C.live k) = C := setLive_same C k
  refine ⟨hi.dyn k, hi.live k, ?_, hi.clean k, hi.terms k,
    fun t j h j' hj' => ((hi.acks k t j h).2.2 j' hj').1, fun T c v h => (hi.ballots T k c v h).2.2.2,
    fun hr T w v h ht => hi.ballot_cand T w k v h hr ht, fun T eL h hd ht => (hi.elect T k eL h hd).2.2.2 ht,
    fun T eL h => hi.elect_cand T k eL h, hi.lead k, ?_, hi.candidate k, ?_, hi.outbox_self k, ?_, ?_, ?_⟩
  · rw [hs]; exact hi.consistent_live k
  · rw [hs]; exact hi.leader k
  · rw [hs]; exact hi.outbox k
  · rw [hs]; exact hi.extra k
  · intro env h T last hf hm hr
    have := (hi.sent env h).2
    rw [hm] at this
    exact (this k hf).2.1 hr
  · rw [hs]; exact (hi.committed k).2

theorem idle_consistent (ids : Vector Id K) (g : Membership MAX) (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K)
    (hi : Inv ids g C G) (k : Fin K) (hd : (C.node k).dirty = false) : Consistent G (fullLog G (C.node k).state) := by
  rcases hi.consistent_live k with h | ⟨h, -⟩ | h
  · exact h
  · rw [hd] at h; cases h
  · exact absurd (h.1.symm.trans hd) (by decide)

theorem idle_leader (ids : Vector Id K) (g : Membership MAX) (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K)
    (hi : Inv ids g C G) (k : Fin K) (hd : (C.node k).dirty = false) (hr : (C.node k).role = .Leader) :
    Leading G k (C.node k) ∧ LeaderOk' ids G k (C.node k) := by
  obtain ⟨h | h, h2⟩ := hi.leader k hr
  · exact ⟨h, h2⟩
  · exact absurd (h.1.symm.trans hd) (by decide)

theorem idle_committed (ids : Vector Id K) (g : Membership MAX) (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K)
    (hi : Inv ids g C G) (k : Fin K) (hd : (C.node k).dirty = false) :
    CommittedBy ids g G (C.node k).state.hard.term.val
      ((fullLog G (C.node k).state).take (C.node k).state.hard.commit.val) := by
  rcases (hi.committed k).2 with h | ⟨h, -⟩ | ⟨-, h, -⟩
  · exact h
  · rw [hd] at h; cases h
  · exact absurd (h.1.symm.trans hd) (by decide)

/-- `LocalOk'` for an idle node's state, role, slots and progress; only its queues may differ. -/
theorem local_keep (ids : Vector Id K) (g : Membership MAX) (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K)
    (hi : Inv ids g C G) (k : Fin K) (hd0 : (C.node k).dirty = false) (m : DNode V S MAX CAP)
    (hcfg : m.config = (C.node k).config) (hhk : m.hooks = (C.node k).hooks) (hb : m.bootstrap = (C.node k).bootstrap)
    (hst : m.state = (C.node k).state) (hrole : m.role = (C.node k).role) (hloc : m.local = (C.node k).local)
    (hmem : m.membership = (C.node k).membership) (hp : m.peers = (C.node k).peers) (hv : m.votes = (C.node k).votes)
    (hmt : m.matched = (C.node k).matched) (hd : m.dirty = (C.node k).dirty) (hpv : m.prevoting = (C.node k).prevoting)
    (houtbox : ∀ (i : Fin MAX) o, m.outbox[i] = some o → ∃ to, m.peers[i] = some to ∧ OutOk ids g (C.setLive k ⟨m⟩) G k to o)
    (hoself : ∀ (h : m.local.val < MAX) o, m.outbox[m.local.val] = some o → ∃ i r, o = .Replicated i r)
    (hextra : ∀ to o, m.extra_reply = some (to, o) → OutOk ids g (C.setLive k ⟨m⟩) G k to o) :
    LocalOk' ids g C G k ⟨m⟩ := by
  have L := local_self ids g C G hi k
  have hfl : fullLog G m.state = fullLog G (C.node k).state := by rw [hst]
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, houtbox, hoself, hextra, ?_, ?_⟩
  · show DynOk g ids[k] m
    exact dynOk_frame L.dyn hcfg hhk hb hp hloc hmem (by rw [hst]) (by rw [hst]; exact L.dyn.layout)
      (by rw [hst]; exact L.dyn.contig) (by rw [hpv, hrole, hst]; exact L.dyn.prevoting)
  · show StateOk G m.state ∧ SnapOk g G m.state
    rw [hst]; exact L.live
  · left; show Consistent G (fullLog G m.state)
    rw [hfl]; exact idle_consistent ids g C G hi k hd0
  · show m.dirty = false → m.state = C.disk k
    rw [hd, hst]; exact L.clean
  · show _ ≤ m.state.hard.term.val
    rw [hst]; exact L.terms
  · show ∀ t j, (k, t, j) ∈ G.acks → ∀ j' ≤ j, Kept G k t j' (m.state.hard.term.val + 1) (fullLog G m.state)
    rw [hst]; exact L.acks
  · show ∀ T c' vlog, (T, k, c', vlog) ∈ G.ballots → m.state.hard.term.val = T → m.state.hard.voted_for = some ids[c']
    rw [hst]; exact L.ballots
  · show m.role = .Candidate → ∀ T w vlog, (T, w, k, vlog) ∈ G.ballots → m.state.hard.term.val = T →
      upToDate (lastOf (fullLog G m.state)) (lastOf vlog)
    rw [hrole, hst]; exact L.ballot_cand
  · show ∀ T eL, G.elect T = some (k, eL) → (C.disk k).hard.term.val < T → m.state.hard.term.val < T →
      fullLog G m.state = eL ∧ m.role ≠ .Leader ∧ m.state.hard.term = (C.disk k).hard.term
    rw [hrole, hst]; exact L.elect
  · show ∀ T eL, G.elect T = some (k, eL) → ¬ (m.role = .Candidate ∧ m.state.hard.term.val = T)
    rw [hrole, hst]; exact L.elect_cand
  · show Leading G k m → LeadLog ids g G k m
    have h := L.lead
    unfold Leading at h ⊢
    rw [hst]
    intro hl
    obtain ⟨a1, a2, a3, a4⟩ := h hl
    exact ⟨by rw [hst]; exact a1, by rw [hst, hd]; exact a2, by rw [hst]; exact a3, by rw [hst]; exact a4⟩
  · intro hr
    change m.role = .Leader at hr
    rw [hrole] at hr
    obtain ⟨h1, h2, h3⟩ := idle_leader ids g C G hi k hd0 hr
    refine ⟨Or.inl (by show Leading G k m; unfold Leading at h1 ⊢; rw [hst]; exact h1), ?_, ?_⟩
    · show ∀ i : Fin MAX, i.val ≠ m.local.val → 0 < (m.matched[i]).val →
        ∃ w : Fin K, m.peers[i] = some ids[w] ∧ (w, m.state.hard.term.val, (m.matched[i]).val) ∈ G.acks
      rw [hmt, hloc, hp, hst]; exact h2
    · show ∀ h : m.local.val < MAX, (m.matched[m.local.val]'h).val ≤ (fullLog G m.state).length
      rw [hmt, hloc, hst]; exact h3
  · show m.role = .Candidate → CandidateOk' ids G k m
    have h := L.candidate
    rw [hrole]
    intro hr
    have := h hr
    unfold CandidateOk' at this ⊢
    rw [hst, hv, hp, hloc]; exact this
  · show ∀ env ∈ C.sent, ∀ T last, env.from = ids[k] → env.message = .Vote T last →
      m.role = .Candidate ∧ m.state.hard.term = T → lastId m.state = last
    rw [hrole, hst]; exact L.votes
  · left
    show CommittedBy ids g G m.state.hard.term.val ((fullLog G m.state).take m.state.hard.commit.val)
    rw [hst]; exact idle_committed ids g C G hi k hd0


/-! ## Queues -/

theorem queue_outbox (n : DNode V S MAX CAP) (a : Option (Fin MAX)) (src : Id) (o : Outbound)
    (hob : ∀ j : Fin MAX, n.outbox[j] = none) (i : Fin MAX) (o' : Outbound)
    (h : (queueD n a src o).outbox[i] = some o') : a = some i ∧ o' = o := by
  cases a with
  | none => simp only [queueD] at h; rw [hob i] at h; cases h
  | some j =>
    simp only [queueD, Fin.getElem_fin, Vector.getElem_set] at h
    split at h
    · rename_i hj; exact ⟨congrArg some (Fin.ext hj), (Option.some.inj h).symm⟩
    · have := hob i; simp only [Fin.getElem_fin] at this; rw [this] at h; cases h

theorem queue_extra (n : DNode V S MAX CAP) (a : Option (Fin MAX)) (src : Id) (o : Outbound)
    (hex : n.extra_reply = none) (to : Id) (o' : Outbound)
    (h : (queueD n a src o).extra_reply = some (to, o')) : a = none ∧ to = src ∧ o' = o := by
  cases a with
  | none => simp only [queueD, Option.some.injEq, Prod.mk.injEq] at h; exact ⟨rfl, h.1.symm, h.2.symm⟩
  | some j => simp only [queueD] at h; rw [hex] at h; cases h

/-- The fields `queueD` keeps. -/
theorem queue_fields (n : DNode V S MAX CAP) (a : Option (Fin MAX)) (src : Id) (o : Outbound) :
    (queueD n a src o).config = n.config ∧ (queueD n a src o).hooks = n.hooks ∧
    (queueD n a src o).bootstrap = n.bootstrap ∧ (queueD n a src o).state = n.state ∧
    (queueD n a src o).role = n.role ∧ (queueD n a src o).local = n.local ∧
    (queueD n a src o).membership = n.membership ∧ (queueD n a src o).peers = n.peers ∧
    (queueD n a src o).votes = n.votes ∧ (queueD n a src o).matched = n.matched ∧
    (queueD n a src o).dirty = n.dirty ∧ (queueD n a src o).prevoting = n.prevoting := by
  cases a <;> exact ⟨rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl⟩

/-- A slot holding another identity is not the node's own. -/
theorem slot_ne_local {g : Membership MAX} {me : Id} {n : DNode V S MAX CAP} (hd : DynOk g me n) (i : Fin MAX) (x : Id)
    (hp : n.peers[i] = some x) (hx : x ≠ me) : i.val ≠ n.local.val := by
  intro e
  have := (hd.local_slot i.val i.isLt).mpr e
  simp only [Fin.getElem_fin] at hp
  rw [hp] at this
  exact hx (Option.some.inj this)

/-- The outbox clauses after queueing `o` for the sender, from an idle node. -/
theorem queue_ok (ids : Vector Id K) (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (k : Fin K)
    {g : Membership MAX} (n : DNode V S MAX CAP) (hd : DynOk g ids[k] n) (a : Option (Fin MAX)) (src : Id) (o : Outbound)
    (hob : ∀ j : Fin MAX, n.outbox[j] = none) (hex : n.extra_reply = none)
    (hslot : ∀ i, a = some i → ∃ x, n.peers[i] = some x ∧ (x ≠ ids[k] ∨ ∃ i' r, o = .Replicated i' r))
    (hO : ∀ to, OutOk ids g (C.setLive k ⟨queueD n a src o⟩) G k to o) :
    (∀ (i : Fin MAX) o', (queueD n a src o).outbox[i] = some o' →
      ∃ to, (queueD n a src o).peers[i] = some to ∧ OutOk ids g (C.setLive k ⟨queueD n a src o⟩) G k to o') ∧
    (∀ (h : (queueD n a src o).local.val < MAX) o', (queueD n a src o).outbox[(queueD n a src o).local.val] = some o' →
      ∃ i r, o' = .Replicated i r) ∧
    (∀ to o', (queueD n a src o).extra_reply = some (to, o') → OutOk ids g (C.setLive k ⟨queueD n a src o⟩) G k to o') := by
  obtain ⟨-, -, -, -, -, hloc, -, hp, -⟩ := queue_fields n a src o
  refine ⟨fun i o' h => ?_, fun hl => ?_, fun to o' h => ?_⟩
  · obtain ⟨rfl, rfl⟩ := queue_outbox n a src o hob i o' h
    obtain ⟨x, hx, -⟩ := hslot i rfl
    exact ⟨x, by rw [hp]; exact hx, hO x⟩
  · intro o' ho'
    have := queue_outbox n a src o hob ⟨_, hl⟩ o' (by simpa using ho')
    obtain ⟨x, hx, hxk | hr⟩ := hslot _ this.1
    · exact absurd (congrArg Fin.val hloc) (slot_ne_local hd _ x hx hxk)
    · rw [this.2]; exact hr
  · obtain ⟨-, -, rfl⟩ := queue_extra n a src o hex to o' h
    exact hO to

/-! ## Observing a message's term -/

theorem observed_cases (n : DNode V S MAX CAP) (src : Id) (t : Rust.u64) (n1 : DNode V S MAX CAP)
    (h : ObservedD n src t n1) :
    (t.val ≤ n.state.hard.term.val ∧ n1 = { n with request_from := some src }) ∨
    (n.state.hard.term.val < t.val ∧ ∃ r d, n1 = { n with request_from := some src, state := { n.state with hard := { n.state.hard with term := t, voted_for := none } }, dirty := true, role := .Follower, prevoting := none, leader := none, random := r, election_deadline := d, elapsed := 0 }) := by
  rcases h with ⟨ht, rfl⟩ | ⟨ht, r, d, rfl⟩
  · exact Or.inl ⟨ht, rfl⟩
  · exact Or.inr ⟨ht, r, d, rfl⟩

/-- `ignored` and `stale`: the node keeps its state and only queues a rejection. -/
theorem case_stale (ids : Vector Id K) (g : Membership MAX) (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K)
    (hi : Inv ids g C G) (k : Fin K) (a : Option (Fin MAX)) (src : Id) (hsrc : src ≠ ids[k])
    (ha : ∀ i, a = some i → (C.node k).peers[i] = some src) (hI : Idle (C.node k))
    (m : DMsg V S MAX) (n1 n' : DNode V S MAX CAP)
    (hO : ObservedD (C.node k) src m.term n1) (hlt : m.term.val < n1.state.hard.term.val)
    (hn : n' = n1 ∨ n' = queueD n1 a src (.Voted false) ∨ ∃ i, n' = queueD n1 a src (.Replicated i (some (.Conflict 1)))) :
    LocalOk' ids g C G k ⟨n'⟩ := by
  obtain ⟨hd0, hex0, hob0⟩ := hI
  have hn1 : n1 = { C.node k with request_from := some src } := by
    rcases observed_cases _ src _ n1 hO with ⟨-, h⟩ | ⟨-, r, d, h⟩
    · exact h
    · rw [h] at hlt; simp at hlt
  subst hn1
  have hD := hi.dyn k
  have hgen : ∀ o : Outbound, (∀ to, OutOk ids g (C.setLive k ⟨queueD { C.node k with request_from := some src } a src o⟩) G k to o) →
      LocalOk' ids g C G k ⟨queueD { C.node k with request_from := some src } a src o⟩ := by
    intro o hO'
    obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12⟩ := queue_fields { C.node k with request_from := some src } a src o
    have hD' : DynOk g ids[k] { C.node k with request_from := some src } :=
      dynOk_frame hD rfl rfl rfl rfl rfl rfl rfl hD.layout hD.contig hD.prevoting
    obtain ⟨q1, q2, q3⟩ := queue_ok ids C G k { C.node k with request_from := some src } hD' a src o hob0 hex0
      (fun i hi' => ⟨src, ha i hi', Or.inl hsrc⟩) hO'
    exact local_keep ids g C G hi k hd0 _ h1 h2 h3 h4 h5 h6 h7 h8 h9 h10 h11 h12 q1 q2 q3
  rcases hn with rfl | rfl | ⟨i, rfl⟩
  · exact local_keep ids g C G hi k hd0 _ rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl
      (fun i o h => by simp only at h; rw [hob0 i] at h; cases h)
      (fun h o ho => absurd ((hob0 ⟨_, h⟩).symm.trans ho) (by simp))
      (fun to o h => by simp only at h; rw [hex0] at h; cases h)
  · exact hgen _ (fun to => by simp [OutOk])
  · exact hgen _ (fun to => by simp [OutOk])


/-! ## Refreshing a node whose log did not change -/

/-- The slot `refresh_membership` computes for a node's own identity is its slot. -/
theorem local_pos {g : Membership MAX} {me : Id} {n : DNode V S MAX CAP} (hd : DynOk g me n) :
    (Rust.Iter.position n.peers.toList (fun p => p == some n.config.id)).getD (Rust.usizeOf MAX) = n.local := by
  have hM64 : MAX < 2 ^ Rust.usizeBits := by have := hd.n_lt; uomega
  have hu : ∀ i j : Fin MAX, ∀ x, n.peers[i] = some x → n.peers[j] = some x → i = j :=
    fun i j x hi hj => Fin.ext (hd.peers_nodup i j i.isLt j.isLt x hi hj)
  obtain ⟨hle, hslot⟩ := local_of_unique n.peers n.config.id hM64 hu
  rw [hd.id] at hle hslot ⊢
  generalize (Rust.Iter.position n.peers.toList (fun p => p == some me)).getD (Rust.usizeOf MAX) = loc at hle hslot ⊢
  apply Fin.ext
  have hl := hd.local_le
  by_cases h1 : n.local.val < MAX
  · exact ((hslot _ h1).mp ((hd.local_slot _ h1).mpr rfl)).symm
  · by_cases h2 : loc.val < MAX
    · have := (hd.local_slot _ h2).mp ((hslot _ h2).mpr rfl); omega
    · omega

/-- `refresh_membership` on a node whose configuration is already its log's:
    nothing changes, except that a removed leader may step down. -/
theorem refresh_same {g : Membership MAX} {me : Id} {n n' : DNode V S MAX CAP} (hd : DynOk g me n)
    (h : Refresh n n') :
    n' = n ∨ (n.role = .Leader ∧ ∃ r d, n' = { n with role := .Follower, prevoting := none, leader := none, random := r, election_deadline := d, elapsed := 0 }) := by
  obtain ⟨n1, ⟨hshape, hkept, -⟩, -, hfin⟩ := h
  have hM : memOf n.state n.bootstrap = n.membership := by rw [hd.bootstrap, hd.membership]
  have hk : ∀ i : Fin MAX, n1.peers[i] = n.peers[i] ∧ n1.votes[i] = n.votes[i] ∧ n1.active[i] = n.active[i] ∧
      n1.next[i] = n.next[i] ∧ n1.matched[i] = n.matched[i] ∧ n1.outbox[i] = n.outbox[i] := by
    intro i
    rcases hkept i with h | ⟨-, x, -, hx, hnone, -⟩
    · exact h
    · rw [hM] at hx
      obtain ⟨j, hj, hp⟩ := hd.members x hx
      exact absurd (by simpa using hp) (hnone ⟨j, hj⟩)
  have e1 : n1 = n := by
    rw [hshape, hM]
    have hP : n1.peers = n.peers := by apply Vector.ext; intro j hj; exact (hk ⟨j, hj⟩).1
    have hV : n1.votes = n.votes := by apply Vector.ext; intro j hj; exact (hk ⟨j, hj⟩).2.1
    have hA : n1.active = n.active := by apply Vector.ext; intro j hj; exact (hk ⟨j, hj⟩).2.2.1
    have hN : n1.next = n.next := by apply Vector.ext; intro j hj; exact (hk ⟨j, hj⟩).2.2.2.1
    have hT : n1.matched = n.matched := by apply Vector.ext; intro j hj; exact (hk ⟨j, hj⟩).2.2.2.2.1
    have hO : n1.outbox = n.outbox := by apply Vector.ext; intro j hj; exact (hk ⟨j, hj⟩).2.2.2.2.2
    rw [hP, hV, hA, hN, hT, hO]
  subst e1
  simp only at hfin
  rw [local_pos hd] at hfin
  rcases hfin with rfl | ⟨hr, -, -, r, d, rfl⟩
  · exact Or.inl rfl
  · exact Or.inr ⟨hr, r, d, rfl⟩

/-- `commit_to` on a node whose configuration is its log's. -/
theorem commitTo_same {g : Membership MAX} {me : Id} {n n' : DNode V S MAX CAP} (hd : DynOk g me n) (i : Rust.u64)
    (h : CommitTo n i n') :
    n' = n ∨ (n.state.hard.commit < i ∧
      (n' = { n with state := { n.state with hard := { n.state.hard with commit := i } }, dirty := true } ∨
       (n.role = .Leader ∧ ∃ r d, n' = { n with state := { n.state with hard := { n.state.hard with commit := i } }, dirty := true, role := .Follower, prevoting := none, leader := none, random := r, election_deadline := d, elapsed := 0 }))) := by
  rcases h with ⟨hlt, hR⟩ | ⟨-, rfl⟩
  · right
    refine ⟨hlt, ?_⟩
    have hct : commitTo n i = { n with state := { n.state with hard := { n.state.hard with commit := i } }, dirty := true } := by
      simp [commitTo, hlt]
    rw [hct] at hR
    have hd' : DynOk g me { n with state := { n.state with hard := { n.state.hard with commit := i } }, dirty := true } :=
      dynOk_frame hd rfl rfl rfl rfl rfl rfl rfl hd.layout hd.contig hd.prevoting
    rcases refresh_same hd' hR with rfl | ⟨hr, r, d, rfl⟩
    · exact Or.inl rfl
    · exact Or.inr ⟨hr, r, d, rfl⟩
  · exact Or.inl rfl

/-- A checkpoint with a new hard state. -/
theorem stateOk_hard (G : Ghost (Record V MAX) K) (s : DState V S MAX CAP) (hs : StateOk G s) (h : HardState)
    (ht : s.hard.term.val ≤ h.term.val) (hc1 : s.base.index.val ≤ h.commit.val)
    (hc2 : h.commit.val ≤ (lastId s).index.val) (hu : h.term.val = 0 → h.voted_for = none) :
    StateOk G { s with hard := h } :=
  ⟨hs.layout, hs.contig, hs.base, hs.snapshot, fun e he => Nat.le_trans (hs.terms e he) ht, hc1, hc2, hu⟩

/-- An index whose identity a checkpoint knows is at most its last index. -/
theorem idAt_le (s : DState V S MAX CAP) (_hl : Layout s) (hc : Contig s) (v : Rust.u64) (x : LogId)
    (h : idAt s v.val = some x) : v.val ≤ (lastId s).index.val := by
  unfold idAt at h
  rw [lastId_eq s hc]
  split at h
  · omega
  · split at h
    · simp only [Option.map_eq_some_iff] at h
      obtain ⟨e, he, -⟩ := h
      have := (List.getElem?_eq_some_iff.mp he).1
      omega
    · cases h


/-! ## A node that observed a higher term -/

/-- `LocalOk'` for a node that stepped down to a higher term `t` without a vote,
    provided `k` did not win `t` without saving it. -/
theorem local_up (ids : Vector Id K) (g : Membership MAX) (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K)
    (hi : Inv ids g C G) (k : Fin K) (hI : Idle (C.node k)) (src : Id) (t : Rust.u64)
    (hlt : (C.node k).state.hard.term.val < t.val)
    (hph : ∀ vlog, G.elect t.val = some (k, vlog) → (C.disk k).hard.term.val < t.val → False)
    (r d : Rust.u64) :
    LocalOk' ids g C G k ⟨{ C.node k with request_from := some src, state := { (C.node k).state with hard := { (C.node k).state.hard with term := t, voted_for := none } }, dirty := true, role := .Follower, prevoting := none, leader := none, random := r, election_deadline := d, elapsed := 0 }⟩ := by
  obtain ⟨hd0, hex0, hob0⟩ := hI
  have L := local_self ids g C G hi k
  have hD := hi.dyn k
  have hsl := (hi.live k).1
  have hcons := idle_consistent ids g C G hi k hd0
  have hdk := hi.terms k
  have hsnap := (hi.live k).2
  have hfl : fullLog G { (C.node k).state with hard := { (C.node k).state.hard with term := t, voted_for := none } } = fullLog G (C.node k).state := rfl
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · exact dynOk_frame hD rfl rfl rfl rfl rfl rfl rfl hD.layout hD.contig (fun t h => by cases h)
  · exact ⟨stateOk_hard G _ hsl _ (Nat.le_of_lt hlt) hsl.commit_ge hsl.commit_le (fun _ => rfl), hsnap⟩
  · left; show Consistent G (fullLog G { (C.node k).state with hard := _ }); rw [hfl]; exact hcons
  · intro h; cases h
  · show (C.disk k).hard.term.val ≤ t.val; omega
  · intro t' j h j' hj'
    show Kept G k t' j' (t.val + 1) (fullLog G { (C.node k).state with hard := _ })
    rw [hfl]; exact kept_mono_bound G k t' j' ((C.node k).state.hard.term.val + 1) _ _ (by omega) (L.acks t' j h j' hj')
  · intro T c v hb ht
    exfalso
    change t.val = T at ht
    subst ht
    rcases (hi.ballots _ k c v hb).1 with h | ⟨hkc, h2, he⟩
    · omega
    · subst hkc; exact hph v he (by omega)
  · intro hr; cases hr
  · intro T eL he hd ht
    exfalso
    change t.val < T at ht
    obtain ⟨-, -, h3, -⟩ := hi.elect T k eL he hd
    omega
  · intro T eL he ⟨hr, _⟩; cases hr
  · intro hl
    obtain ⟨eL, he⟩ := hl
    change G.elect t.val = some (k, eL) at he
    exact absurd (hph eL he (by omega)) id
  · intro hr; cases hr
  · intro hr; cases hr
  · intro i o h; change (C.node k).outbox[i] = some o at h; rw [hob0 i] at h; cases h
  · intro h o ho; exact absurd ((hob0 ⟨_, h⟩).symm.trans ho) (by simp)
  · intro to o h; change (C.node k).extra_reply = some (to, o) at h; rw [hex0] at h; cases h
  · intro env _ T last _ _ ⟨hr, _⟩; cases hr
  · left
    show CommittedBy ids g G t.val ((fullLog G { (C.node k).state with hard := _ }).take (C.node k).state.hard.commit.val)
    rw [hfl]
    exact committedBy_mono_term G (C.node k).state.hard.term.val t.val (by omega) _
      (idle_committed ids g C G hi k hd0)


/-! ## Commitment by a leader -/

/-- A quorum of the configuration matched `v`: every such identity acknowledged
    at least `v` entries of the leader's term, counting the leader's own log. -/
theorem quorum_ackers (ids : Vector Id K) {g : Membership MAX} (G W : Ghost (Record V MAX) K) (k : Fin K)
    (m : DNode V S MAX CAP) (hd : DynOk g ids[k] m) (hL : LeaderOk' ids G k m) (v : Rust.u64) (hv0 : 0 < v.val)
    (len : Nat) (hvlen : v.val ≤ len) (hacks : ∀ x ∈ G.acks, x ∈ W.acks)
    (hown : (k, m.state.hard.term.val, len) ∈ W.acks) (hq : QuorumAt m v) :
    Quorum m.membership (Ackers ids W m.state.hard.term.val v.val) := by
  have hM : MAX < 2 ^ Rust.usizeBits := by have := hd.n_lt; uomega
  refine quorum_mono _ _ _ (fun id hid => ?_) hq
  unfold matchOf at hid
  cases hp : pos m id with
  | none => rw [hp] at hid; simp at hid; omega
  | some p =>
    rw [hp] at hid
    obtain ⟨hpM, hpe⟩ := pos_lt m id p hM hp
    simp only at hid
    rw [getElem!_pos m.matched p.val hpM] at hid
    rw [getElem!_pos m.peers p.val hpM] at hpe
    by_cases hpl : p.val = m.local.val
    · have h1 := (hd.local_slot p.val hpM).mpr hpl
      rw [hpe] at h1
      cases h1
      exact ⟨k, rfl, len, hvlen, hown⟩
    · obtain ⟨w, hpw, hack⟩ := hL.matched ⟨p.val, hpM⟩ hpl (by simp only [Fin.getElem_fin]; omega)
      simp only [Fin.getElem_fin] at hpw hack
      rw [hpe] at hpw
      cases hpw
      exact ⟨w, rfl, _, hid, hacks _ hack⟩

/-- A leader's commitment of `v` once its own log counts as acknowledged. -/
theorem commit_own (ids : Vector Id K) (g : Membership MAX) (G : Ghost (Record V MAX) K) (k : Fin K)
    (n : DNode V S MAX CAP) (hd : DynOk g ids[k] n) (hsnap : SnapOk g G n.state) (v : Nat) (hv0 : 0 < v)
    (hvl : v ≤ (fullLog G n.state).length)
    (hterm : ∃ h : v - 1 < (fullLog G n.state).length, ((fullLog G n.state)[v - 1]).id.term.val = n.state.hard.term.val)
    (hq : Quorum n.membership (Ackers ids (withOwnD G k n) n.state.hard.term.val v)) :
    CommittedBy ids g (withOwnD G k n) n.state.hard.term.val ((fullLog G n.state).take v) := by
  refine Or.inr ⟨n.state.hard.term.val, v, Nat.le_refl _, ⟨(fullLog G n.state).length, hv0, hvl, fullLog G n.state,
    by simp [withOwnD], Nat.le_refl _, hterm, ?_⟩, ?_⟩
  · rw [List.take_length, ← memOf_fullLog g G _ hsnap, ← hd.membership]; exact hq
  · simp [Ghost.prefix, withOwnD]

/-- The ghost records no election of `k` above its saved term (`Inv.elect_disk`). -/
theorem no_elect_above (ids : Vector Id K) (g : Membership MAX) (C : World V S MAX CAP K)
    (G : Ghost (Record V MAX) K) (hi : Inv ids g C G) (k : Fin K) (T : Nat) (eL : List (DEntry V MAX))
    (he : G.elect T = some (k, eL)) (hlt : (C.disk k).hard.term.val < T) : False := by
  have := hi.elect_disk T k eL he; omega

theorem leaderOk_congr (ids : Vector Id K) (G : Ghost (Record V MAX) K) (k : Fin K) (n m : DNode V S MAX CAP)
    (h : LeaderOk' ids G k m) (hl : n.local = m.local) (hm : n.matched = m.matched) (hp : n.peers = m.peers)
    (ht : n.state.hard.term = m.state.hard.term) (hf : fullLog G n.state = fullLog G m.state) : LeaderOk' ids G k n := by
  obtain ⟨a, b⟩ := h
  refine ⟨fun i hi hpos => ?_, fun hlt => ?_⟩
  · rw [hl] at hi; rw [hm] at hpos ⊢; rw [hp, ht]; exact a i hi hpos
  · have := b (by rw [← hl]; exact hlt)
    rw [hf, hm]
    simp only [hl]; exact this

theorem adv_point (G : Ghost (Record V MAX) K) (s : DState V S MAX CAP) (hs : StateOk G s) (v T : Rust.u64)
    (hb : 0 < v.val) (h : Rust.Option.is_some_and (State.id_at s v) (fun id => id.term == T) = true) :
    v.val ≤ (fullLog G s).length ∧ ∃ hl : v.val - 1 < (fullLog G s).length, ((fullLog G s)[v.val - 1]).id.term = T := by
  rw [id_at_eq s hs.layout] at h
  cases hid : idAt s v.val with
  | none => rw [hid] at h; simp [Rust.Option.is_some_and] at h
  | some id =>
    rw [hid] at h
    simp [Rust.Option.is_some_and] at h
    obtain ⟨-, hl, he⟩ := (idAt_fullLog G s hs v.val hb id).mp hid
    refine ⟨by rw [fullLog_length G s hs]; exact idAt_le s hs.layout hs.contig v id hid, hl, by rw [he]; exact h⟩

/-- A leader records a reply from slot `i` and may advance its commit index. -/
theorem case_lead (ids : Vector Id K) (g : Membership MAX) (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K)
    (hi : Inv ids g C G) (k : Fin K) (i : Fin MAX) (src : Id) (hsrc : src ≠ ids[k])
    (hpi : (C.node k).peers[i] = some src) (hI : Idle (C.node k)) (t index : Rust.u64) (rej : Option Rejection)
    (hacks : rej = none → ∃ w, src = ids[w] ∧ (w, t.val, index.val) ∈ G.acks)
    (htn : (C.node k).state.hard.term = t) (hr : (C.node k).role = .Leader)
    (n' : DNode V S MAX CAP) (hR : ReplicatedD { C.node k with request_from := some src } i index rej n') :
    LocalOk' ids g C G k ⟨n'⟩ := by
  obtain ⟨hd0, hex0, hob0⟩ := hI
  have L := local_self ids g C G hi k
  have hD := hi.dyn k
  have hsl := (hi.live k).1
  have hsnap := (hi.live k).2
  have hcons := idle_consistent ids g C G hi k hd0
  obtain ⟨hLd, hLo⟩ := idle_leader ids g C G hi k hd0 hr
  have hpv0 : (C.node k).prevoting = none := by
    cases h : (C.node k).prevoting with
    | none => rfl
    | some x => have := (hD.prevoting x h).1; rw [hr] at this; cases this
  have hil : i.val ≠ (C.node k).local.val := slot_ne_local hD i src hpi hsrc
  have hR' := hR
  obtain ⟨m, m', hRec, hAdv, hn', hob⟩ := hR
  obtain ⟨act, nx, hm⟩ := hRec
  obtain ⟨M, hM, rfl⟩ : ∃ M, (M = (C.node k).matched ∨ (rej = none ∧ M = (C.node k).matched.set i.val index i.isLt)) ∧
      m = { C.node k with request_from := some src, active := act, «next» := nx, matched := M } := by
    rcases hm with rfl | ⟨hrej, -, -, rfl⟩
    · exact ⟨_, Or.inl rfl, rfl⟩
    · exact ⟨_, Or.inr ⟨hrej, rfl⟩, rfl⟩
  have hDm : DynOk g ids[k] { C.node k with request_from := some src, active := act, «next» := nx, matched := M } :=
    dynOk_frame hD rfl rfl rfl rfl rfl rfl rfl hD.layout hD.contig hD.prevoting
  have hLm : LeaderOk' ids G k { C.node k with request_from := some src, active := act, «next» := nx, matched := M } := by
    refine ⟨fun j hj hpos => ?_, fun h => ?_⟩
    · change j.val ≠ (C.node k).local.val at hj
      change ∃ w : Fin K, (C.node k).peers[j] = some ids[w] ∧ (w, (C.node k).state.hard.term.val, (M[j]).val) ∈ G.acks
      change 0 < (M[j]).val at hpos
      rcases hM with rfl | ⟨hrej, rfl⟩
      · exact hLo.matched j hj hpos
      · by_cases hji : j = i
        · subst hji
          obtain ⟨w, hw, hack⟩ := hacks hrej
          refine ⟨w, by rw [hpi, hw], ?_⟩
          simp only [Fin.getElem_fin, Vector.getElem_set_self]
          rw [htn]; exact hack
        · have hne : i.val ≠ j.val := fun e => hji (Fin.ext e.symm)
          simp only [Fin.getElem_fin, Vector.getElem_set_ne _ _ hne] at hpos ⊢
          exact hLo.matched j hj (by simpa using hpos)
    · change (M[(C.node k).local.val]'h).val ≤ (fullLog G (C.node k).state).length
      rcases hM with rfl | ⟨-, rfl⟩
      · exact hLo.own h
      · rw [Vector.getElem_set_ne _ _ hil]; exact hLo.own h
  -- the shape of the new node
  generalize hmm : ({ C.node k with request_from := some src, active := act, «next» := nx, matched := M } : DNode V S MAX CAP) = mm at hDm hLm hAdv hn'
  have hmmf : mm.state = (C.node k).state ∧ mm.config = (C.node k).config ∧ mm.hooks = (C.node k).hooks ∧
      mm.bootstrap = (C.node k).bootstrap ∧ mm.local = (C.node k).local ∧ mm.membership = (C.node k).membership ∧
      mm.peers = (C.node k).peers ∧ mm.votes = (C.node k).votes ∧ mm.matched = M ∧ mm.prevoting = none ∧
      mm.extra_reply = none ∧ mm.outbox = (C.node k).outbox ∧ mm.role = .Leader ∧ mm.dirty = false := by
    rw [← hmm]; exact ⟨rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, hpv0, hex0, rfl, hr, hd0⟩
  obtain ⟨m1, m2, m3, m4, m5, m6, m7, m8, m9, m10, m11, m12, m13, m14⟩ := hmmf
  have hshape : m' = mm ∨ ∃ v : Rust.u64, QuorumAt mm v ∧ (C.node k).state.hard.commit < v ∧
      Rust.Option.is_some_and (State.id_at (C.node k).state v) (fun id => id.term == (C.node k).state.hard.term) = true ∧
      (m' = { mm with state := { mm.state with hard := { mm.state.hard with commit := v } }, dirty := true } ∨
        ∃ r d, m' = { mm with state := { mm.state with hard := { mm.state.hard with commit := v } }, dirty := true, role := .Follower, prevoting := none, leader := none, random := r, election_deadline := d, elapsed := 0 }) := by
    rcases hAdv with rfl | ⟨v, hQ, hlt, hid, hCT⟩
    · exact Or.inl rfl
    · rw [m1] at hlt hid
      rcases commitTo_same hDm v hCT with rfl | ⟨-, h⟩
      · exact Or.inl rfl
      · refine Or.inr ⟨v, hQ, hlt, hid, ?_⟩
        rcases h with h | ⟨-, r, d, h⟩
        · exact Or.inl h
        · exact Or.inr ⟨r, d, h⟩
  have e1 : n'.peers = m'.peers := by rw [hn']
  have e2 : n'.local = m'.local := by rw [hn']
  have F : n'.config = (C.node k).config ∧ n'.hooks = (C.node k).hooks ∧ n'.bootstrap = (C.node k).bootstrap ∧
      n'.local = (C.node k).local ∧ n'.membership = (C.node k).membership ∧ n'.peers = (C.node k).peers ∧
      n'.votes = (C.node k).votes ∧ n'.matched = M ∧ n'.prevoting = none ∧ n'.extra_reply = none ∧
      (n'.role = .Leader ∨ n'.role = .Follower) ∧ (∀ j : Fin MAX, m'.outbox[j] = none) ∧
      ((n'.state = (C.node k).state ∧ n'.dirty = false) ∨
        ∃ v : Rust.u64, QuorumAt mm v ∧ (C.node k).state.hard.commit < v ∧
          Rust.Option.is_some_and (State.id_at (C.node k).state v) (fun id => id.term == (C.node k).state.hard.term) = true ∧
          n'.state = { (C.node k).state with hard := { (C.node k).state.hard with commit := v } } ∧ n'.dirty = true) := by
    rcases hshape with rfl | ⟨v, hQ, hlt, hid, rfl | ⟨r, d, rfl⟩⟩ <;> rw [hn']
    · exact ⟨m2, m3, m4, m5, m6, m7, m8, m9, m10, m11, Or.inl m13, fun j => by rw [m12]; exact hob0 j, Or.inl ⟨m1, m14⟩⟩
    · exact ⟨m2, m3, m4, m5, m6, m7, m8, m9, m10, m11, Or.inl m13, fun j => by dsimp only; rw [m12]; exact hob0 j,
        Or.inr ⟨v, hQ, hlt, hid, by dsimp only; rw [m1], rfl⟩⟩
    · exact ⟨m2, m3, m4, m5, m6, m7, m8, m9, rfl, m11, Or.inr rfl, fun j => by dsimp only; rw [m12]; exact hob0 j,
        Or.inr ⟨v, hQ, hlt, hid, by dsimp only; rw [m1], rfl⟩⟩
  obtain ⟨f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13⟩ := F
  have hrep : ∀ (j : Fin MAX) o, n'.outbox[j] = some o → o = .Replicate := by
    intro j o ho
    rcases hob j with h | h
    · rw [h, f12 j] at ho; cases ho
    · rw [h.1] at ho; exact (Option.some.inj ho).symm
  obtain ⟨hd', hst', ht', hvf', hc1, hc2⟩ : ∃ hd' : HardState, n'.state = { (C.node k).state with hard := hd' } ∧
      hd'.term = (C.node k).state.hard.term ∧ hd'.voted_for = (C.node k).state.hard.voted_for ∧
      (C.node k).state.hard.commit.val ≤ hd'.commit.val ∧ hd'.commit.val ≤ (lastId (C.node k).state).index.val := by
    rcases f13 with ⟨h1, -⟩ | ⟨v, -, hlt, hid, h4, -⟩
    · exact ⟨_, h1, rfl, rfl, Nat.le_refl _, hsl.commit_le⟩
    · have hv0 : 0 < v.val := by rw [Fin.lt_def] at hlt; omega
      obtain ⟨hvl, -⟩ := adv_point G _ hsl v _ hv0 hid
      rw [fullLog_length G _ hsl] at hvl
      exact ⟨_, h4, rfl, rfl, by rw [Fin.lt_def] at hlt; exact Nat.le_of_lt hlt, hvl⟩
  have hfl : fullLog G n'.state = fullLog G (C.node k).state := by rw [hst']; rfl
  have hnt : n'.state.hard.term = (C.node k).state.hard.term := by rw [hst']; exact ht'
  have hnv : n'.state.hard.voted_for = (C.node k).state.hard.voted_for := by rw [hst']; exact hvf'
  have hDn : DynOk g ids[k] n' :=
    dynOk_frame hD f1 f2 f3 f6 f4 f5 (by rw [hst']; rfl) (by rw [hst']; exact hD.layout) (by rw [hst']; exact hD.contig)
      (by rw [f9]; intro t h; cases h)
  have hLn : Leading G k n' := by unfold Leading at hLd ⊢; rw [hnt]; exact hLd
  have hgap : ∀ j : Fin MAX, n'.outbox[j] = some .Replicate → (∃ to, n'.peers[j] = some to) ∧ j.val ≠ n'.local.val := by
    intro j hj
    rcases hob j with h | ⟨-, h⟩
    · rw [h, f12 j] at hj; cases hj
    · rcases h with rfl | ⟨h1, id, h2⟩
      · exact ⟨⟨src, by rw [f6]; exact hpi⟩, by rw [f4]; exact hil⟩
      · exact ⟨⟨id, by rw [e1]; exact h2⟩, by rw [e2]; exact h1⟩
  refine ⟨hDn, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · show StateOk G n'.state ∧ SnapOk g G n'.state
    rw [hst']
    exact ⟨stateOk_hard G _ hsl _ (by rw [ht']; exact Nat.le_refl _) (Nat.le_trans hsl.commit_ge hc1) hc2
      (by rw [ht', hvf']; exact hsl.unvoted), hsnap⟩
  · left; show Consistent G (fullLog G n'.state); rw [hfl]; exact hcons
  · intro hd
    change n'.dirty = false at hd
    show n'.state = C.disk k
    rcases f13 with ⟨h1, -⟩ | ⟨v, -, -, -, -, h5⟩
    · rw [h1]; exact hi.clean k hd0
    · rw [h5] at hd; cases hd
  · show (C.disk k).hard.term.val ≤ n'.state.hard.term.val
    rw [hnt]; exact hi.terms k
  · show ∀ t j, (k, t, j) ∈ G.acks → ∀ j' ≤ j, Kept G k t j' (n'.state.hard.term.val + 1) (fullLog G n'.state)
    rw [hnt, hfl]; exact L.acks
  · show ∀ T c' vlog, (T, k, c', vlog) ∈ G.ballots → n'.state.hard.term.val = T → n'.state.hard.voted_for = some ids[c']
    rw [hnt, hnv]; exact L.ballots
  · intro hc; change n'.role = .Candidate at hc; rcases f11 with h | h <;> rw [h] at hc <;> cases hc
  · intro T eL he hd ht
    exfalso
    change n'.state.hard.term.val < T at ht
    rw [hnt] at ht
    exact ((hi.elect T k eL he hd).2.2.2 ht).2.1 hr
  · intro T eL he ⟨hc, _⟩; change n'.role = .Candidate at hc; rcases f11 with h | h <;> rw [h] at hc <;> cases hc
  · intro _
    obtain ⟨⟨eL, he, hp, hb⟩, ⟨L', hL1, hL2, hL3⟩, hch, hcf⟩ := hi.lead k hLd
    refine ⟨⟨eL, ?_, ?_, ?_⟩, ⟨L', ?_, ?_, fun _ => ?_⟩, ?_, ?_⟩
    · show G.elect n'.state.hard.term.val = some (k, eL); rw [hnt]; exact he
    · show eL <+: fullLog G n'.state; rw [hfl]; exact hp
    · show ∀ i (h : i < (fullLog G n'.state).length), eL.length ≤ i →
        ((fullLog G n'.state)[i]).id.term = n'.state.hard.term
      rw [hfl, hnt]; exact hb
    · show G.leader n'.state.hard.term.val = some L'; rw [hnt]; exact hL1
    · show L' <+: fullLog G n'.state; rw [hfl]; exact hL2
    · show L' = fullLog G n'.state; rw [hfl]; exact hL3 hd0
    · show ChainIn (ids := ids) (g := g) G (fullLog G n'.state); rw [hfl]; exact hch
    · show ∀ i (hi : i < (fullLog G n'.state).length) X, recCfg ((fullLog G n'.state)[i]).value = some X → MemOk X
      rw [hfl]; exact hcf
  · intro _
    refine ⟨Or.inl hLn, leaderOk_congr ids G k n' mm hLm (by rw [f4, m5]) (by rw [f8, m9]) (by rw [f6, m7])
      (by rw [hnt, m1]) (by rw [hfl, m1])⟩
  · intro hc; change n'.role = .Candidate at hc; rcases f11 with h | h <;> rw [h] at hc <;> cases hc
  · intro j o ho
    change n'.outbox[j] = some o at ho
    have e := hrep j o ho
    subst e
    obtain ⟨⟨to, hto⟩, -⟩ := hgap j ho
    refine ⟨to, hto, ?_⟩
    unfold OutOk; simp only [setLive_node]; exact Or.inl hLn
  · intro h o ho
    change n'.outbox[n'.local.val] = some o at ho
    have e := hrep ⟨_, h⟩ o ho
    subst e
    exact absurd rfl (hgap ⟨_, h⟩ ho).2
  · intro to o h; change n'.extra_reply = some (to, o) at h; rw [f10] at h; cases h
  · intro env _ T last _ _ ⟨hc, _⟩; change n'.role = .Candidate at hc; rcases f11 with h | h <;> rw [h] at hc <;> cases hc
  · show CommitOk' ids g (C.setLive k ⟨n'⟩) G k n'
    rcases f13 with ⟨h1, h2⟩ | ⟨v, hQ, hlt, hid, h4, h5⟩
    · left; rw [h1]; exact idle_committed ids g C G hi k hd0
    · right; left
      refine ⟨h5, hLn, ?_⟩
      have hv0 : 0 < v.val := by rw [Fin.lt_def] at hlt; omega
      obtain ⟨hvl, hl0, hterm0⟩ := adv_point G _ hsl v _ hv0 hid
      have hcv : n'.state.hard.commit = v := by rw [h4]
      rw [hcv]
      apply commit_own ids g G k n' hDn (by rw [hst']; exact hsnap) v.val hv0 (by rw [hfl]; exact hvl)
        ⟨by rw [hfl]; exact hl0, by simp only [hfl, hterm0, hnt]⟩
      have hq := quorum_ackers ids G (withOwnD G k n') k mm hDm hLm v hv0 (fullLog G n'.state).length
        (by rw [hfl]; exact hvl) (fun x hx => List.mem_cons_of_mem _ hx)
        (by rw [m1, ← hnt]; exact List.mem_cons_self) hQ
      rw [m6, m1, ← hnt] at hq
      rw [f5]; exact hq


/-- `Replicated`: a reply from slot `i`. -/
theorem case_replicated (ids : Vector Id K) (g : Membership MAX) (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K)
    (hi : Inv ids g C G) (k : Fin K) (i : Fin MAX) (src dst : Id) (hsrc : src ≠ ids[k])
    (hpi : (C.node k).peers[i] = some src) (hI : Idle (C.node k)) (t index : Rust.u64) (rej : Option Rejection)
    (hm : (⟨src, dst, .Replicated t index rej⟩ : DEnv V S MAX) ∈ C.sent)
    (n1 n' : DNode V S MAX CAP) (hO : ObservedD (C.node k) src t n1) (hT : n1.state.hard.term = t)
    (hc : (n1.role ≠ .Leader ∧ n' = n1) ∨ (n1.role = .Leader ∧ ReplicatedD n1 i index rej n')) :
    LocalOk' ids g C G k ⟨n'⟩ := by
  obtain ⟨⟨w0, hw0⟩, hS2⟩ := hi.sent _ hm
  have hacks : rej = none → ∃ w, src = ids[w] ∧ (w, t.val, index.val) ∈ G.acks := fun h => ⟨w0, hw0, hS2 h w0 hw0⟩
  rcases observed_cases _ src t n1 hO with ⟨-, rfl⟩ | ⟨hlt, r, d, rfl⟩
  · rcases hc with ⟨-, rfl⟩ | ⟨hr, hR⟩
    · obtain ⟨hd0, hex0, hob0⟩ := hI
      exact local_keep ids g C G hi k hd0 _ rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl
        (fun i o h => by simp only at h; rw [hob0 i] at h; cases h)
        (fun h o ho => absurd ((hob0 ⟨_, h⟩).symm.trans ho) (by simp)) (fun to o h => by simp only at h; rw [hex0] at h; cases h)
    · exact case_lead ids g C G hi k i src hsrc hpi hI t index rej hacks hT hr n' hR
  · rcases hc with ⟨-, rfl⟩ | ⟨hr, -⟩
    · exact local_up ids g C G hi k hI src t hlt
        (fun vlog he hd => no_elect_above ids g C G hi k t.val vlog he hd) r d
    · cases hr


/-! ## Followers: appending and installing -/

theorem match_take (G : Ghost (Record V MAX) K) (s : DState V S MAX CAP) (hs : StateOk G s)
    (hc : Consistent G (fullLog G s)) (L : List (DEntry V MAX)) (hL : Consistent G L) (idx : Nat) (id : LogId)
    (hid : idAt s idx = some id) (hL' : 0 < idx → ∃ h : idx - 1 < L.length, L[idx - 1].id = id) :
    (fullLog G s).take idx = L.take idx ∧ idx ≤ (fullLog G s).length := by
  by_cases h0 : idx = 0
  · subst h0; simp
  · obtain ⟨-, hl, he⟩ := (idAt_fullLog G s hs idx (by omega) id).mp hid
    obtain ⟨hl', he'⟩ := hL' (by omega)
    have := log_matching G _ L hc hL (idx - 1) hl hl' (by rw [he, he'])
    rw [show idx - 1 + 1 = idx by omega] at this
    exact ⟨this, by omega⟩

/-- An acknowledged prefix survives a replacement by a prefix of the leader log of
    term `t`, or that term's leader (another node) lacks it. -/
theorem kept_replace (G : Ghost (Record V MAX) K) (k a : Fin K) (hak : a ≠ k) (t t' j B : Nat)
    (old l' L eLt : List (DEntry V MAX))
    (hL : G.leader t = some L) (he : G.elect t = some (a, eLt)) (hp : eLt <+: L) (ht' : t' ≤ t) (hB : B ≤ t + 1)
    (hk : Kept G k t' j B old) (hrep : ∀ p, p <+: old → p <+: L → p <+: l') : Kept G k t' j (t + 1) l' := by
  rcases hk with hk | ⟨t3, h1, h2, hl⟩
  · by_cases hpl : G.prefix t' j <+: L
    · exact Or.inl (hrep _ hk hpl)
    · refine Or.inr ⟨t, ?_, by omega, a, eLt, he, hak, fun h => hpl (h.trans hp)⟩
      apply Classical.byContradiction; intro h
      have : t' = t := by omega
      subst this
      exact hpl (prefix_le G t' j L hL)
  · exact Or.inr ⟨t3, h1, by omega, hl⟩

theorem prefix_take_of (p L : List (DEntry V MAX)) (m : Nat) (hp : p <+: L) (hm : p.length ≤ m) : p <+: L.take m := by
  rw [List.prefix_iff_eq_take] at hp
  rw [hp]
  have : List.take p.length L = List.take p.length (L.take m) := by rw [List.take_take, Nat.min_eq_left hm]
  rw [this]; exact List.take_prefix _ _

theorem take_of_take (l L : List (DEntry V MAX)) (idx i : Nat) (h : l.take idx = L.take idx) (hi : i ≤ idx) :
    l.take i = L.take i := by
  have h1 : l.take i = (l.take idx).take i := by rw [List.take_take, Nat.min_eq_left hi]
  have h2 : L.take i = (L.take idx).take i := by rw [List.take_take, Nat.min_eq_left hi]
  rw [h1, h2, h]

theorem committedBy_take (ids : Vector Id K) (g : Membership MAX) (G : Ghost (Record V MAX) K) (T : Nat)
    (L : List (DEntry V MAX)) (i c : Nat) (h : CommittedBy ids g G T (L.take c)) (hi : i ≤ c) :
    CommittedBy ids g G T (L.take i) := by
  refine committedBy_prefix G T _ _ ?_ h
  have : L.take i = (L.take c).take i := by rw [List.take_take, Nat.min_eq_left hi]
  rw [this]; exact List.take_prefix _ _

/-- What a follower handling `Append`, `AppendBatch` or `Install` in term `t`
    keeps true of its node `n`, relative to the node `n2` it started from. -/
structure FOk (ids : Vector Id K) (g : Membership MAX) (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K)
    (k : Fin K) (t : Nat) (n2 n : DNode V S MAX CAP) : Prop where
  dyn : DynOk g ids[k] n
  role : n.role = .Follower
  outbox : ∀ j : Fin MAX, n.outbox[j] = none
  extra : n.extra_reply = none
  term : n.state.hard.term = n2.state.hard.term
  vf : n.state.hard.voted_for = n2.state.hard.voted_for
  live : StateOk G n.state
  snap : SnapOk g G n.state
  cons : Consistent G (fullLog G n.state)
  acks : ∀ t' j, (k, t', j) ∈ G.acks → t' ≤ t ∧ ∀ j' ≤ j, Kept G k t' j' (t + 1) (fullLog G n.state)
  clean : n.dirty = false → n.state = n2.state ∧ n2.dirty = false
  committed : CommittedBy ids g G t ((fullLog G n.state).take n.state.hard.commit.val)
  elect : ∀ T eL, G.elect T = some (k, eL) → (C.disk k).hard.term.val < T → t < T → fullLog G n.state = eL
  slot : ∀ (i : Fin MAX) y, n2.peers[i] = some y → ∃ x, n.peers[i] = some x

/-- The facts about a follower before it handles `Append`, `AppendBatch` or `Install` in term `t`. -/
structure FPre (ids : Vector Id K) (g : Membership MAX) (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K)
    (k : Fin K) (t : Nat) (n2 : DNode V S MAX CAP) : Prop where
  term : n2.state.hard.term.val = t
  terms : (C.disk k).hard.term.val ≤ t
  clean : n2.dirty = false → n2.state = C.disk k
  ballots : ∀ T c vlog, (T, k, c, vlog) ∈ G.ballots → t = T → n2.state.hard.voted_for = some ids[c]
  elect : ∀ T eL, G.elect T = some (k, eL) → (C.disk k).hard.term.val < T → t < T → t = (C.disk k).hard.term.val
  notlead : ∀ eL, G.elect t ≠ some (k, eL)
  ok : FOk ids g C G k t n2 n2

/-- `LocalOk'` once a follower has queued its reply. -/
theorem local_reply (ids : Vector Id K) (g : Membership MAX) (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K)
    (k : Fin K) (a : Option (Fin MAX)) (src : Id) (_hsrc : src ≠ ids[k]) (t : Nat) (n2 n3 : DNode V S MAX CAP)
    (hP : FPre ids g C G k t n2) (hF : FOk ids g C G k t n2 n3) (ha : ∀ i, a = some i → n2.peers[i] = some src)
    (r1 : Rust.u64) (r2 : Option Rejection)
    (hreply : r2 = none → G.prefix t r1.val <+: fullLog G n3.state ∧ AckOk G t r1.val) :
    LocalOk' ids g C G k ⟨queueD n3 a src (.Replicated r1 r2)⟩ := by
  obtain ⟨q1, q2, q3, q4, q5, q6, q7, q8, q9, q10, q11, q12⟩ := queue_fields n3 a src (.Replicated r1 r2)
  generalize hm : queueD n3 a src (.Replicated r1 r2) = m at q1 q2 q3 q4 q5 q6 q7 q8 q9 q10 q11 q12
  have hmt : m.state.hard.term.val = t := by rw [q4, hF.term, hP.term]
  have hfl : fullLog G m.state = fullLog G n3.state := by rw [q4]
  have hrole : m.role = .Follower := by rw [q5, hF.role]
  have hOut := queue_ok ids C G k n3 hF.dyn a src (.Replicated r1 r2) hF.outbox hF.extra
    (fun i hi' => let ⟨x, hx⟩ := hF.slot i src (ha i hi'); ⟨x, hx, Or.inr ⟨_, _, rfl⟩⟩) (fun to => by
      show _ → _
      intro hr
      rw [hm, setLive_node]
      show G.prefix m.state.hard.term.val r1.val <+: fullLog G m.state ∧ AckOk G m.state.hard.term.val r1.val
      rw [hmt, hfl]; exact hreply hr)
  rw [hm] at hOut
  obtain ⟨o1, o2, o3⟩ := hOut
  refine ⟨?_, ?_, Or.inl ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, o1, o2, o3, ?_, Or.inl ?_⟩
  · exact dynOk_frame hF.dyn q1 q2 q3 q8 q6 q7 (by rw [q4]) (by rw [q4]; exact hF.dyn.layout)
      (by rw [q4]; exact hF.dyn.contig) (by rw [q12, q5, q4]; exact hF.dyn.prevoting)
  · show StateOk G m.state ∧ SnapOk g G m.state
    rw [q4]; exact ⟨hF.live, hF.snap⟩
  · show Consistent G (fullLog G m.state); rw [hfl]; exact hF.cons
  · intro hd
    change m.dirty = false at hd
    rw [q11] at hd
    show m.state = C.disk k
    obtain ⟨h1, h2⟩ := hF.clean hd
    rw [q4, h1]; exact hP.clean h2
  · show (C.disk k).hard.term.val ≤ m.state.hard.term.val
    rw [hmt]; exact hP.terms
  · intro t' j h j' hj'
    show Kept G k t' j' (m.state.hard.term.val + 1) (fullLog G m.state)
    rw [hmt, hfl]; exact (hF.acks t' j h).2 j' hj'
  · intro T c vlog hb ht
    change m.state.hard.term.val = T at ht
    show m.state.hard.voted_for = some ids[c]
    rw [q4, hF.vf]; exact hP.ballots T c vlog hb (by rw [← hmt, ht])
  · intro hc; change m.role = .Candidate at hc; rw [hrole] at hc; cases hc
  · intro T eL he hd ht
    change m.state.hard.term.val < T at ht
    rw [hmt] at ht
    refine ⟨?_, ?_, ?_⟩
    · show fullLog G m.state = eL; rw [hfl]; exact hF.elect T eL he hd ht
    · show m.role ≠ .Leader; rw [hrole]; intro h; cases h
    · show m.state.hard.term = (C.disk k).hard.term
      apply Fin.ext; rw [hmt]; exact hP.elect T eL he hd ht
  · intro T eL he ⟨hc, _⟩; change m.role = .Candidate at hc; rw [hrole] at hc; cases hc
  · intro hl
    obtain ⟨eL, he⟩ := hl
    change G.elect m.state.hard.term.val = some (k, eL) at he
    rw [hmt] at he
    exact absurd he (hP.notlead eL)
  · intro hc; change m.role = .Leader at hc; rw [hrole] at hc; cases hc
  · intro hc; change m.role = .Candidate at hc; rw [hrole] at hc; cases hc
  · intro env _ T last _ _ ⟨hc, _⟩; change m.role = .Candidate at hc; rw [hrole] at hc; cases hc
  · show CommittedBy ids g G m.state.hard.term.val ((fullLog G m.state).take m.state.hard.commit.val)
    rw [hmt, hfl, q4]; exact hF.committed


/-- A follower about to handle a replication request of term `t` from the elected leader of `t`. -/
theorem pre_of (ids : Vector Id K) (g : Membership MAX) (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K)
    (hi : Inv ids g C G) (k : Fin K) (hI : Idle (C.node k)) (src : Id) (t : Rust.u64) (n1 n2 : DNode V S MAX CAP)
    (hO : ObservedD (C.node k) src t n1) (hT : n1.state.hard.term = t) (hFol : FollowingD n1 src n2)
    (hlead : ∀ c eL, G.elect t.val = some (c, eL) → c ≠ k) :
    FPre ids g C G k t.val n2 ∧ n2.peers = (C.node k).peers := by
  obtain ⟨hd0, hex0, hob0⟩ := hI
  have L := local_self ids g C G hi k
  have hD := hi.dyn k
  have hsl := (hi.live k).1
  have hsnap := (hi.live k).2
  have hcons := idle_consistent ids g C G hi k hd0
  have hdk := hi.terms k
  have hcomm : CommittedBy ids g G (C.node k).state.hard.term.val
      ((fullLog G (C.node k).state).take (C.node k).state.hard.commit.val) :=
    idle_committed ids g C G hi k hd0
  have hnl : ∀ eL, G.elect t.val ≠ some (k, eL) := fun eL he => hlead k eL he rfl
  obtain ⟨r2, d2, rfl⟩ := hFol
  rcases observed_cases _ src t n1 hO with ⟨-, rfl⟩ | ⟨hlt, r, d, rfl⟩
  · have htn : (C.node k).state.hard.term = t := hT
    have htv : (C.node k).state.hard.term.val = t.val := by rw [htn]
    refine ⟨⟨htv, (by omega), fun hd => hi.clean k hd, fun T c v hb ht => ?_, fun T eL he hd ht => ?_, hnl,
      ⟨?_, rfl, hob0, hex0, rfl, rfl, hsl, hsnap, hcons, fun t' j h => ?_, fun hd => ⟨rfl, hd⟩, ?_,
        fun T eL he hd ht => ?_, fun i y h => ⟨y, h⟩⟩⟩, rfl⟩
    · exact L.ballots T c v hb (by rw [htv]; exact ht)
    · have := ((hi.elect T k eL he hd).2.2.2 (by rw [htv]; exact ht)).2.2
      rw [← htv, this]
    · exact dynOk_frame hD rfl rfl rfl rfl rfl rfl rfl hD.layout hD.contig (fun t h => by cases h)
    · refine ⟨?_, fun j' hj' => ?_⟩
      · have := (hi.acks k t' j h).2.1; omega
      · have := L.acks t' j h j' hj'; rw [htv] at this; exact this
    · show CommittedBy ids g G t.val _; rw [← htv]; exact hcomm
    · exact ((hi.elect T k eL he hd).2.2.2 (by rw [htv]; exact ht)).1
  · have hfl : fullLog G { (C.node k).state with hard := { (C.node k).state.hard with term := t, voted_for := none } } =
        fullLog G (C.node k).state := rfl
    have hnoel : ∀ T eL, G.elect T = some (k, eL) → (C.disk k).hard.term.val < T → t.val < T → False := by
      intro T eL he hd ht
      obtain ⟨-, -, h3, -⟩ := hi.elect T k eL he hd
      omega
    refine ⟨⟨rfl, (by omega), fun hd => (by cases hd), fun T c v hb ht => ?_, fun T eL he hd ht => (hnoel T eL he hd ht).elim,
      hnl, ⟨?_, rfl, hob0, hex0, rfl, rfl, ?_, hsnap, ?_, fun t' j h => ?_, fun hd => (by cases hd), ?_,
        fun T eL he hd ht => (hnoel T eL he hd ht).elim, fun i y h => ⟨y, h⟩⟩⟩, rfl⟩
    · exfalso
      subst ht
      rcases (hi.ballots _ k c v hb).1 with h | ⟨hkc, h2, he⟩
      · omega
      · subst hkc; exact hnl v he
    · exact dynOk_frame hD rfl rfl rfl rfl rfl rfl rfl hD.layout hD.contig (fun t h => by cases h)
    · exact stateOk_hard G _ hsl _ (Nat.le_of_lt hlt) hsl.commit_ge hsl.commit_le (fun _ => rfl)
    · show Consistent G (fullLog G { (C.node k).state with hard := _ }); rw [hfl]; exact hcons
    · refine ⟨?_, fun j' hj' => ?_⟩
      · have := (hi.acks k t' j h).2.1; omega
      · show Kept G k t' j' (t.val + 1) (fullLog G { (C.node k).state with hard := _ })
        rw [hfl]
        exact kept_mono_bound G k t' j' ((C.node k).state.hard.term.val + 1) _ _ (by omega) (L.acks t' j h j' hj')
    · show CommittedBy ids g G t.val ((fullLog G { (C.node k).state with hard := _ }).take (C.node k).state.hard.commit.val)
      rw [hfl]; exact committedBy_mono_term G _ _ (by omega) _ hcomm


/-- A follower commits up to `i`, a point where its log agrees with the leader log `L`. -/
theorem fok_commit (ids : Vector Id K) (g : Membership MAX) (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K)
    (k : Fin K) (t : Nat) (n2 nA nB : DNode V S MAX CAP) (hF : FOk ids g C G k t n2 nA)
    (L : List (DEntry V MAX)) (idx : Nat) (htake : (fullLog G nA.state).take idx = L.take idx)
    (hidx : idx ≤ (fullLog G nA.state).length) (commit : Nat) (hcomm : CommittedBy ids g G t (L.take commit))
    (i : Rust.u64) (hi1 : i.val ≤ idx) (hi2 : i.val ≤ commit) (h : CommitTo nA i nB) :
    FOk ids g C G k t n2 nB ∧ fullLog G nB.state = fullLog G nA.state := by
  rcases commitTo_same hF.dyn i h with rfl | ⟨hlt, rfl | ⟨hr, -⟩⟩
  · exact ⟨hF, rfl⟩
  · have hlen := fullLog_length G _ hF.live
    refine ⟨⟨dynOk_frame hF.dyn rfl rfl rfl rfl rfl rfl rfl hF.dyn.layout hF.dyn.contig hF.dyn.prevoting,
      hF.role, hF.outbox, hF.extra, hF.term, hF.vf, ?_, hF.snap, hF.cons, hF.acks, fun hd => (by cases hd), ?_,
      hF.elect, hF.slot⟩, rfl⟩
    · exact stateOk_hard G _ hF.live _ (Nat.le_refl _)
        (Nat.le_trans hF.live.commit_ge (by rw [Fin.lt_def] at hlt; exact Nat.le_of_lt hlt)) (show i.val ≤ _ by omega) hF.live.unvoted
    · show CommittedBy ids g G t ((fullLog G nA.state).take i.val)
      rw [take_of_take _ _ idx _ htake hi1]
      exact committedBy_take ids g G t L _ _ hcomm hi2
  · rw [hF.role] at hr; cases hr


/-- What `refresh_membership` does to a follower after a log change. -/
theorem refresh_follower {g : Membership MAX} {me : Id} (nA n0 n1 : DNode V S MAX CAP) (hd : DynOk g me nA)
    (hcfg : n0.config = nA.config) (hhk : n0.hooks = nA.hooks) (hb : n0.bootstrap = nA.bootstrap)
    (hrole : n0.role = .Follower) (hL : Layout n0.state) (hC : Contig n0.state)
    (hpv : ∀ t, n0.prevoting = some t → n0.role = .Follower ∧ t.val = n0.state.hard.term.val + 1)
    (hob : ∀ j : Fin MAX, n0.outbox[j] = none) (h : Refresh n0 n1) :
    DynOk g me n1 ∧ n1.role = .Follower ∧ n1.state = n0.state ∧ n1.dirty = n0.dirty ∧
      n1.extra_reply = n0.extra_reply ∧ (∀ j : Fin MAX, n1.outbox[j] = none) ∧
      ∀ (i : Fin MAX) y, n0.peers[i] = some y → ∃ x, n1.peers[i] = some x ∧ (x = y ∨ ∀ j : Fin MAX, n0.peers[j] ≠ some x) := by
  have hD1 := dynOk_refresh (g := g) (me := me) n0 n1 hd.n_pos hd.n_lt hd.cap_ge hd.cap_lt (by rw [hhk]; exact hd.hooks)
    (by rw [hb]; exact hd.bootstrap) (by rw [hcfg]; exact hd.id) (by rw [hcfg]; exact hd.heartbeat)
    (by rw [hcfg]; exact hd.election) (by rw [hcfg]; exact hd.election_le) hL hC hpv h
  obtain ⟨nn, ⟨hshape, hkept, -⟩, -, hfin⟩ := h
  simp only at hfin
  rcases hfin with rfl | ⟨hr, -⟩
  · refine ⟨hD1, ?_, ?_, ?_, ?_, fun j => ?_, fun i y hy => ?_⟩
    · show nn.role = _; rw [hshape]; exact hrole
    · show nn.state = _; rw [hshape]
    · show nn.dirty = _; rw [hshape]
    · show nn.extra_reply = _; rw [hshape]
    · show nn.outbox[j] = none
      rcases hkept j with ⟨-, -, -, -, -, h6⟩ | ⟨-, -, -, -, -, -, -, -, -, h8⟩
      · rw [h6]; exact hob j
      · exact h8
    · show ∃ x, nn.peers[i] = some x ∧ _
      rcases hkept i with ⟨h1, -⟩ | ⟨-, x, hx, -, hnone, -⟩
      · exact ⟨y, by rw [h1]; exact hy, Or.inl rfl⟩
      · exact ⟨x, hx, Or.inr hnone⟩
  · rw [hrole] at hr; cases hr



/-- `append` replaced the suffix from the entry's index with the leader's entry. -/
theorem fok_replace (ids : Vector Id K) (g : Membership MAX) (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K)
    (hi : Inv ids g C G) (k : Fin K) (t : Nat) (n2 nA nB : DNode V S MAX CAP) (hF : FOk ids g C G k t n2 nA)
    (htn : n2.state.hard.term.val = t)
    (L : List (DEntry V MAX)) (hL : G.leader t = some L) (hLc : Consistent G L)
    (hLt : ∀ e ∈ L, 0 < e.id.term.val ∧ e.id.term.val ≤ t) (a : Fin K) (hak : a ≠ k) (eLt : List (DEntry V MAX))
    (he : G.elect t = some (a, eLt)) (hpe : eLt <+: L)
    (prev : LogId) (e : DEntry V MAX) (hprev : idAt nA.state prev.index.val = some prev)
    (hprevL : 0 < prev.index.val → ∃ h : prev.index.val - 1 < L.length, L[prev.index.val - 1].id = prev)
    (hel : e.id.index.val - 1 < L.length) (hLe : L[e.id.index.val - 1] = e) (hei : e.id.index.val = prev.index.val + 1)
    (hconf : idAt nA.state e.id.index.val ≠ some e.id) (hlt : nA.state.hard.commit.val < e.id.index.val)
    (s' : DState V S MAX CAP) (hrep : ReplacedD nA e s') (n1 : DNode V S MAX CAP) (hR : Refresh { nA with state := s' } n1)
    (commit : Rust.u64) (hcomm : CommittedBy ids g G t (L.take commit.val)) (lf : Option Rust.u64)
    (hCT : CommitTo { n1 with dirty := true, log_from := lf } (Rust.min commit e.id.index) nB) :
    FOk ids g C G k t n2 nB ∧ fullLog G nB.state = L.take e.id.index.val := by
  obtain ⟨hr', hh', hsn', hl', hc'⟩ := hrep
  have hs2 := hF.live
  have hlen2 := fullLog_length G _ hs2
  have hlast2 := lastId_eq _ hs2.contig
  obtain ⟨hpt, hpl⟩ := match_take G _ hs2 hF.cons L hLc prev.index.val prev hprev hprevL
  have hbase : nA.state.base.index.val < e.id.index.val := by have := hs2.commit_ge; omega
  have hhi : e.id.index.val ≤ (lastId nA.state).index.val + 1 := by omega
  have hfl' := fullLog_replaced G nA.state s' e hs2 hbase hhi hr' hsn'
  have hb' : s'.base = nA.state.base := base_of_snapshot _ _ hsn'
  have hget : L[prev.index.val]? = some e := by
    rw [show prev.index.val = e.id.index.val - 1 by omega, List.getElem?_eq_getElem hel, hLe]
  have hnew : fullLog G s' = L.take e.id.index.val := by
    rw [hfl', show e.id.index.val - 1 = prev.index.val by omega, hpt, hei, List.take_add_one, hget]; rfl
  have hlast' : (lastId s').index.val = e.id.index.val := by
    rw [lastId_eq s' hc', hr', hb']; simp only [List.length_append, List.length_take, List.length_singleton]
    rw [lastId_eq _ hs2.contig] at hhi; omega
  have hnt : nA.state.hard.term.val = t := by rw [hF.term]; exact htn
  have hst' : StateOk G s' := by
    refine ⟨hl', hc', ?_, ?_, ?_, ?_, ?_, ?_⟩
    · intro hpos; rw [hb'] at hpos ⊢; exact hs2.base hpos
    · intro hs; rw [hb']; exact hs2.snapshot (by rw [← hsn']; exact hs)
    · intro x hx
      rw [hnew] at hx
      rw [hh', hnt]; exact (hLt x (List.mem_of_mem_take hx)).2
    · rw [hh', hb']; exact hs2.commit_ge
    · rw [hh', hlast']; omega
    · rw [hh']; exact hs2.unvoted
  have hsnap' : SnapOk g G s' := by
    have h1 : snapMem s' g = snapMem nA.state g := by unfold snapMem memInit; rw [hsn']
    have h2 : boundary G s' = boundary G nA.state := by unfold boundary; rw [hb']
    unfold SnapOk; rw [h1, h2]; exact hF.snap
  have hrepl : ∀ p, p <+: fullLog G nA.state → p <+: L → p <+: L.take e.id.index.val := by
    intro p hp1 hp2
    by_cases hpl' : p.length ≤ e.id.index.val
    · exact prefix_take_of p L _ hp2 hpl'
    · exfalso; apply hconf
      have hlt1 : e.id.index.val - 1 < p.length := by omega
      have h1 := hp1.getElem hlt1
      have h2 := hp2.getElem hlt1
      rw [hLe] at h2
      refine (idAt_fullLog G _ hs2 _ (by omega) _).mpr ⟨by omega, by have := hp1.length_le; omega, ?_⟩
      rw [← h1, h2]
  obtain ⟨hD1, hr1, hs1, hd1, hx1, ho1, hp1⟩ := refresh_follower (g := g) (me := ids[k]) nA { nA with state := s' } n1 hF.dyn rfl rfl rfl
    hF.role hl' hc' (fun t' h => by
      have := hF.dyn.prevoting t' h
      refine ⟨this.1, ?_⟩
      show t'.val = s'.hard.term.val + 1; rw [hh']; exact this.2) hF.outbox hR
  -- the node before committing
  have hC : FOk ids g C G k t n2 { n1 with dirty := true, log_from := lf } := by
    have hsC : n1.state = s' := hs1
    refine ⟨dynOk_frame hD1 rfl rfl rfl rfl rfl rfl rfl hD1.layout hD1.contig hD1.prevoting, hr1, ho1,
      by rw [show n1.extra_reply = nA.extra_reply from hx1]; exact hF.extra, ?_, ?_, ?_, ?_, ?_, ?_,
      fun hd => (by cases hd), ?_, ?_, ?_⟩
    · show n1.state.hard.term = _; rw [hsC, hh']; exact hF.term
    · show n1.state.hard.voted_for = _; rw [hsC, hh']; exact hF.vf
    · show StateOk G n1.state; rw [hsC]; exact hst'
    · show SnapOk g G n1.state; rw [hsC]; exact hsnap'
    · show Consistent G (fullLog G n1.state); rw [hsC, hnew]; exact consistent_take G L hLc _
    · intro t' j h
      obtain ⟨h1, h2⟩ := hF.acks t' j h
      refine ⟨h1, fun j' hj' => ?_⟩
      show Kept G k t' j' (t + 1) (fullLog G n1.state)
      rw [hsC, hnew]
      exact kept_replace G k a hak t t' j' (t + 1) _ _ L eLt hL he hpe h1 (Nat.le_refl _) (h2 j' hj') hrepl
    · show CommittedBy ids g G t ((fullLog G n1.state).take n1.state.hard.commit.val)
      rw [hsC, hnew, hh']
      have hc2 : nA.state.hard.commit.val ≤ prev.index.val := by omega
      have : (L.take e.id.index.val).take nA.state.hard.commit.val = (fullLog G nA.state).take nA.state.hard.commit.val := by
        rw [List.take_take, Nat.min_eq_left (by omega)]; exact (take_of_take _ _ prev.index.val _ hpt hc2).symm
      rw [this]; exact hF.committed
    · intro T eL hel' hd ht
      exact (no_elect_above ids g C G hi k T eL hel' hd).elim
    · intro i y hy
      obtain ⟨x, hx⟩ := hF.slot i y hy
      obtain ⟨x', hx', -⟩ := hp1 i x hx
      exact ⟨x', hx'⟩
  have hmin : (Rust.min commit e.id.index).val ≤ commit.val ∧ (Rust.min commit e.id.index).val ≤ e.id.index.val := by
    rw [Rust.val_min]; exact ⟨Nat.min_le_left _ _, Nat.min_le_right _ _⟩
  have hflC : fullLog G ({ n1 with dirty := true, log_from := lf } : DNode V S MAX CAP).state = L.take e.id.index.val := by
    show fullLog G n1.state = _; rw [hs1]; exact hnew
  have hlenC : e.id.index.val ≤ (fullLog G ({ n1 with dirty := true, log_from := lf } : DNode V S MAX CAP).state).length := by
    rw [hflC]; simp; omega
  obtain ⟨hB, hflB⟩ := fok_commit ids g C G k t n2 _ nB hC L e.id.index.val (by rw [hflC, List.take_take, Nat.min_self])
    hlenC commit.val hcomm _ hmin.2 hmin.1 hCT
  exact ⟨hB, by rw [hflB, hflC]⟩


/-- One `append` by a follower, of an entry of the leader log `L` of term `t`. -/
theorem step_append (ids : Vector Id K) (g : Membership MAX) (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K)
    (hi : Inv ids g C G) (k : Fin K) (t : Nat) (n2 nA nB : DNode V S MAX CAP) (hF : FOk ids g C G k t n2 nA)
    (htn : n2.state.hard.term.val = t)
    (L : List (DEntry V MAX)) (hL : G.leader t = some L) (hLc : Consistent G L)
    (hLt : ∀ e ∈ L, 0 < e.id.term.val ∧ e.id.term.val ≤ t) (a : Fin K) (hak : a ≠ k) (eLt : List (DEntry V MAX))
    (he : G.elect t = some (a, eLt)) (hpe : eLt <+: L)
    (prev : LogId) (hprev : PrevOk L prev) (entry : Option (DEntry V MAX))
    (hent : ∀ e, entry = some e → InLog L e ∧ e.id.index.val = prev.index.val + 1)
    (commit : Rust.u64) (hcomm : CommittedBy ids g G t (L.take commit.val))
    (r : Rust.u64 × Option Rejection) (hA : AppendD nA prev entry commit r nB) :
    FOk ids g C G k t n2 nB ∧ (r.2 = none → G.prefix t r.1.val <+: fullLog G nB.state ∧ AckOk G t r.1.val) ∧
      (r.2.isSome → fullLog G nB.state = fullLog G nA.state) := by
  have hprevL : prev.index.val ≤ L.length := by
    by_cases h0 : prev.index.val = 0
    · omega
    · obtain ⟨h, -⟩ := hprev.1 (by omega); omega
  have hmin : ∀ x : Rust.u64, (Rust.min commit x).val ≤ commit.val ∧ (Rust.min commit x).val ≤ x.val := by
    intro x; rw [Rust.val_min]; exact ⟨Nat.min_le_left _ _, Nat.min_le_right _ _⟩
  have hpre : ∀ idx, G.prefix t idx = L.take idx := fun idx => prefix_eq_take G t idx L hL
  rcases hA with ⟨-, -, hr2, rfl⟩ | ⟨hp, rfl, rfl, hCT⟩ | ⟨e, hp, rfl, hide, rfl, hCT⟩ |
      ⟨e, rfl, -, -, -, hr2, rfl⟩ | ⟨e, hp, rfl, -, rfl, hCT⟩ | ⟨e, s', n1, hp, rfl, hconf, hlt, hrep, rfl, hR, hCT⟩
  · exact ⟨hF, fun h => (by rw [h] at hr2; cases hr2), fun _ => rfl⟩
  · obtain ⟨htake, hidx⟩ := match_take G _ hF.live hF.cons L hLc _ prev hp hprev.1
    obtain ⟨hB, hfl⟩ := fok_commit ids g C G k t n2 nA nB hF L _ htake hidx commit.val hcomm _ (hmin _).2 (hmin _).1 hCT
    refine ⟨hB, fun _ => ⟨?_, L, hL, hprevL⟩, fun h => (by simp at h)⟩
    rw [hpre, ← htake, hfl]; exact List.take_prefix _ _
  · obtain ⟨⟨hel, hLe⟩, hei⟩ := hent e rfl
    obtain ⟨htake, hidx⟩ := match_take G _ hF.live hF.cons L hLc _ e.id hide (fun _ => ⟨hel, by rw [hLe]⟩)
    obtain ⟨hB, hfl⟩ := fok_commit ids g C G k t n2 nA nB hF L _ htake hidx commit.val hcomm _ (hmin _).2 (hmin _).1 hCT
    refine ⟨hB, fun _ => ⟨?_, L, hL, show e.id.index.val ≤ L.length by omega⟩, fun h => (by simp at h)⟩
    rw [hpre, ← htake, hfl]; exact List.take_prefix _ _
  · exact ⟨hF, fun h => (by rw [h] at hr2; cases hr2), fun _ => rfl⟩
  · obtain ⟨htake, hidx⟩ := match_take G _ hF.live hF.cons L hLc _ prev hp hprev.1
    obtain ⟨hB, hfl⟩ := fok_commit ids g C G k t n2 nA nB hF L _ htake hidx commit.val hcomm _ (hmin _).2 (hmin _).1 hCT
    exact ⟨hB, fun h => (by cases h), fun _ => hfl⟩
  · obtain ⟨⟨hel, hLe⟩, hei⟩ := hent e rfl
    obtain ⟨hB, hfl⟩ := fok_replace ids g C G hi k t n2 nA nB hF htn L hL hLc hLt a hak eLt he hpe prev e hp hprev.1
      hel hLe hei hconf hlt s' hrep n1 hR commit hcomm _ hCT
    refine ⟨hB, fun _ => ⟨by rw [hpre, hfl]; exact List.prefix_refl _, L, hL, show e.id.index.val ≤ L.length by omega⟩, fun h => (by simp at h)⟩


/-- `Append`: follow the sender, append and reply. -/
theorem case_append (ids : Vector Id K) (g : Membership MAX) (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K)
    (hi : Inv ids g C G) (k : Fin K) (a : Option (Fin MAX)) (src dst : Id) (hsrc : src ≠ ids[k])
    (ha : ∀ i, a = some i → (C.node k).peers[i] = some src) (hI : Idle (C.node k))
    (t : Rust.u64) (prev : LogId) (entry : Option (DEntry V MAX)) (commit : Rust.u64)
    (hm : (⟨src, dst, .Append t prev entry commit⟩ : DEnv V S MAX) ∈ C.sent)
    (n1 n2 n3 : DNode V S MAX CAP) (r : Rust.u64 × Option Rejection)
    (hO : ObservedD (C.node k) src t n1) (hT : n1.state.hard.term = t) (hFol : FollowingD n1 src n2)
    (hA : AppendD n2 prev entry commit r n3) :
    LocalOk' ids g C G k ⟨queueD n3 a src (.Replicated r.1 r.2)⟩ := by
  obtain ⟨-, L, hL, hprev, hent, -, hcomm, hsender⟩ := hi.sent _ hm
  obtain ⟨hLc, hLt, ⟨ca, eLt, he, hpe, -⟩, -⟩ := hi.wf.leader t.val L hL
  have hlead : ∀ c eL, G.elect t.val = some (c, eL) → c ≠ k := fun c eL h e => hsrc (by
    have := hsender c eL h; rw [e] at this; exact this)
  obtain ⟨hP, hpeers⟩ := pre_of ids g C G hi k hI src t n1 n2 hO hT hFol hlead
  obtain ⟨hF, hrep, -⟩ := step_append ids g C G hi k t.val n2 n2 n3 hP.ok hP.term L hL hLc hLt ca (hlead ca eLt he)
    eLt he hpe prev hprev entry hent commit hcomm r hA
  exact local_reply ids g C G k a src hsrc t.val n2 n3 hP hF (fun i h => by rw [hpeers]; exact ha i h) r.1 r.2 hrep


/-- Entries numbered consecutively after `p`. -/
inductive Consec : LogId → List (DEntry V MAX) → Prop
  | nil (p : LogId) : Consec p []
  | cons (p : LogId) (e : DEntry V MAX) (es : List (DEntry V MAX)) :
      e.id.index.val = p.index.val + 1 → Consec e.id es → Consec p (e :: es)

theorem prevOk_of_inLog (L : List (DEntry V MAX)) (p : LogId) (e : DEntry V MAX) (hL : InLog L e)
    (he : e.id.index.val = p.index.val + 1) : PrevOk L e.id := by
  obtain ⟨h, hLe⟩ := hL
  exact ⟨fun _ => ⟨h, by rw [hLe]⟩, fun h0 => by omega⟩

/-- The rest of a batch after an accepted entry. -/
theorem batch_after (ids : Vector Id K) (g : Membership MAX) (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K)
    (hi : Inv ids g C G) (k : Fin K) (t : Nat) (n2 : DNode V S MAX CAP) (htn : n2.state.hard.term.val = t)
    (L : List (DEntry V MAX)) (hL : G.leader t = some L) (hLc : Consistent G L)
    (hLt : ∀ e ∈ L, 0 < e.id.term.val ∧ e.id.term.val ≤ t) (a : Fin K) (hak : a ≠ k) (eLt : List (DEntry V MAX))
    (he : G.elect t = some (a, eLt)) (hpe : eLt <+: L) (commit : Rust.u64)
    (hcomm : CommittedBy ids g G t (L.take commit.val))
    (nA : DNode V S MAX CAP) (prev : LogId) (es : List (DEntry V MAX)) (last : Rust.u64)
    (resp : Rust.u64 × Option Rejection) (nB : DNode V S MAX CAP)
    (hB : BatchAfterD nA prev es commit last resp nB) (hF : FOk ids g C G k t n2 nA) (hprev : PrevOk L prev)
    (hes : ∀ e ∈ es, InLog L e) (hc : Consec prev es)
    (hlast : G.prefix t last.val <+: fullLog G nA.state ∧ AckOk G t last.val) :
    FOk ids g C G k t n2 nB ∧ (resp.2 = none → G.prefix t resp.1.val <+: fullLog G nB.state ∧ AckOk G t resp.1.val) := by
  induction hB with
  | nil n p c l => exact ⟨hF, fun _ => hlast⟩
  | reject n n' p e es c l r hA hr =>
    cases hc with
    | cons _ _ _ hei hc' =>
    obtain ⟨hF', -, hfl⟩ := step_append ids g C G hi k t n2 n n' hF htn L hL hLc hLt a hak eLt he hpe p hprev
      (some e) (fun e' h => by cases h; exact ⟨hes e List.mem_cons_self, hei⟩) c hcomm r hA
    exact ⟨hF', fun _ => by rw [hfl hr]; exact hlast⟩
  | accept n n1 n' p e es c l r resp hA hr hB' ih =>
    cases hc with
    | cons _ _ _ hei hc' =>
    have hinl := hes e List.mem_cons_self
    obtain ⟨hF1, hrep, -⟩ := step_append ids g C G hi k t n2 n n1 hF htn L hL hLc hLt a hak eLt he hpe p hprev
      (some e) (fun e' h => by cases h; exact ⟨hinl, hei⟩) c hcomm r hA
    exact ih hcomm hF1 (prevOk_of_inLog L p e hinl hei) (fun x hx => hes x (List.mem_cons_of_mem _ hx)) hc' (hrep hr)

/-- A whole batch. -/
theorem batch_all (ids : Vector Id K) (g : Membership MAX) (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K)
    (hi : Inv ids g C G) (k : Fin K) (t : Nat) (n2 : DNode V S MAX CAP) (htn : n2.state.hard.term.val = t)
    (L : List (DEntry V MAX)) (hL : G.leader t = some L) (hLc : Consistent G L)
    (hLt : ∀ e ∈ L, 0 < e.id.term.val ∧ e.id.term.val ≤ t) (a : Fin K) (hak : a ≠ k) (eLt : List (DEntry V MAX))
    (he : G.elect t = some (a, eLt)) (hpe : eLt <+: L) (commit : Rust.u64)
    (hcomm : CommittedBy ids g G t (L.take commit.val))
    (nA : DNode V S MAX CAP) (prev : LogId) (es : List (DEntry V MAX))
    (resp : Rust.u64 × Option Rejection) (nB : DNode V S MAX CAP)
    (hB : BatchD nA prev es commit resp nB) (hF : FOk ids g C G k t n2 nA) (hprev : PrevOk L prev)
    (hes : ∀ e ∈ es, InLog L e) (hne : es ≠ []) (hc : Consec prev es) :
    FOk ids g C G k t n2 nB ∧ (resp.2 = none → G.prefix t resp.1.val <+: fullLog G nB.state ∧ AckOk G t resp.1.val) := by
  cases hB with
  | nil => exact absurd rfl hne
  | reject _ _ e es' _ r hA hr =>
    cases hc with
    | cons _ _ _ hei hc' =>
    obtain ⟨hF', -, -⟩ := step_append ids g C G hi k t n2 nA nB hF htn L hL hLc hLt a hak eLt he hpe prev hprev
      (some e) (fun e' h => by cases h; exact ⟨hes e List.mem_cons_self, hei⟩) commit hcomm resp hA
    exact ⟨hF', fun h => by rw [h] at hr; cases hr⟩
  | accept n1 _ _ e es' _ r _ hA hr hB' =>
    cases hc with
    | cons _ _ _ hei hc' =>
    have hinl := hes e List.mem_cons_self
    obtain ⟨hF1, hrep, -⟩ := step_append ids g C G hi k t n2 nA n1 hF htn L hL hLc hLt a hak eLt he hpe prev hprev
      (some e) (fun e' h => by cases h; exact ⟨hinl, hei⟩) commit hcomm r hA
    exact batch_after ids g C G hi k t n2 htn L hL hLc hLt a hak eLt he hpe commit hcomm n1 e.id es' r.1 resp nB hB' hF1
      (prevOk_of_inLog L prev e hinl hei) (fun x hx => hes x (List.mem_cons_of_mem _ hx)) hc' (hrep hr)


/-- The entry loop of `valid` for `AppendBatch`: unless it rejects, the entries
    present are numbered consecutively and the count moves only on an entry. -/
theorem batch_loop {α : Type}
    (f : Option (DEntry V MAX) → Option Bool × LogId × Bool × α → Rust.M (ForInStep (Option Bool × LogId × Bool × α)))
    (hnone : ∀ s, f none s = pure (.yield (none, s.2.1, true, s.2.2.2)))
    (hsome : ∀ e s b', f (some e) s = pure b' → (∃ x, b' = .done (some false, x)) ∨
      (e.id.index.val = s.2.1.index.val + 1 ∧ ∃ en c, b' = .yield (none, e.id, en, c))) :
    ∀ (l : List (Option (DEntry V MAX))) (s r : Option Bool × LogId × Bool × α), s.1 = none → forIn l s f = pure r →
      r.1 = some false ∨ (r.1 = none ∧ Consec s.2.1 (Rust.Iter.flatten l) ∧
        (Rust.Iter.flatten l = [] → r.2.2.2 = s.2.2.2)) := by
  intro l
  induction l with
  | nil =>
    intro s r hs h
    have := Rust.pure_inj h
    subst this
    exact Or.inr ⟨hs, Consec.nil _, fun _ => rfl⟩
  | cons x xs ih =>
    intro s r hs h
    rw [List.forIn_cons] at h
    obtain ⟨st, hst, h⟩ := Rust.bind_eq_pure h
    cases x with
    | none =>
      rw [hnone s] at hst
      have := Rust.pure_inj hst
      subst this
      rcases ih _ r rfl h with h1 | ⟨h1, h2, h3⟩
      · exact Or.inl h1
      · exact Or.inr ⟨h1, by simpa [Rust.Iter.flatten] using h2, fun he => by
          have := h3 (by simpa [Rust.Iter.flatten] using he); exact this⟩
    | some e =>
      rcases hsome e s st hst with ⟨x, rfl⟩ | ⟨hei, en, c, rfl⟩
      · exact Or.inl (by rw [← Rust.pure_inj h])
      · rcases ih _ r rfl h with h1 | ⟨h1, h2, -⟩
        · exact Or.inl h1
        · refine Or.inr ⟨h1, ?_, fun he => by simp [Rust.Iter.flatten] at he⟩
          have : Rust.Iter.flatten (some e :: xs) = e :: Rust.Iter.flatten xs := by simp [Rust.Iter.flatten]
          rw [this]
          exact Consec.cons _ e _ hei h2

/-- A valid `AppendBatch` carries at least one entry, numbered consecutively after its predecessor. -/
theorem ite_pure {α : Type} (c : Prop) [Decidable c] (x y : Rust.M α) (r : α) (h : (if c then x else y) = pure r) :
    (c ∧ x = pure r) ∨ (¬ c ∧ y = pure r) := by
  by_cases hc : c
  · rw [if_pos hc] at h; exact Or.inl ⟨hc, h⟩
  · rw [if_neg hc] at h; exact Or.inr ⟨hc, h⟩

theorem valid_batch (t : Rust.u64) (prev : LogId) (entries : Vector (Option (DEntry V MAX)) MAX_APPEND_ENTRIES)
    (commit : Rust.u64)
    (h : Node.valid (V := Record V MAX) (S := Checkpoint S MAX) (N := MAX) (CAP := CAP)
      (Message.AppendBatch t prev entries commit) = pure true) :
    Rust.Iter.flatten entries.toList ≠ [] ∧ Consec prev (Rust.Iter.flatten entries.toList) := by
  unfold Node.valid at h
  simp only [Message.term] at h
  rcases ite_pure _ _ _ _ h with ⟨-, h⟩ | ⟨-, h⟩
  · rcases ite_pure _ _ _ _ h with ⟨-, h⟩ | ⟨-, h⟩
    · have := Rust.pure_inj h; cases this
    · obtain ⟨b, hb, h⟩ := Rust.bind_eq_pure h
      have key := batch_loop _ (fun s => rfl) (fun e s b' hf => by
          rcases ite_pure _ _ _ _ hf with ⟨-, hf⟩ | ⟨hc, hf⟩
          · exact Or.inl ⟨_, (Rust.pure_inj hf).symm⟩
          · obtain ⟨t1, -, hf⟩ := Rust.bind_eq_pure hf
            right
            refine ⟨?_, _, _, (Rust.pure_inj hf).symm⟩
            simp only [Bool.or_eq_true, bne_iff_ne, ne_eq, not_or] at hc
            have h3 := hc.1.2
            simp only [Decidable.not_not, Rust.checked_add_eq] at h3
            split at h3
            · simp only [Option.some.injEq] at h3; rw [← h3]; rfl
            · cases h3) entries.toList _ b rfl hb
      rcases key with h1 | ⟨h1, hc, hcnt⟩
      · rw [h1] at h; have := Rust.pure_inj h; cases this
      · rw [h1] at h
        simp only [bind_pure] at h
        refine ⟨fun he => ?_, hc⟩
        rw [hcnt he] at h
        have := Rust.pure_inj h
        change decide ((0 : Rust.i32) > 0) = true at this
        exact absurd this (by decide)
  · simp only [pure_bind] at h; have := Rust.pure_inj h; cases this

/-- `AppendBatch`: follow the sender, append the entries in order, and reply. -/
theorem case_batch (ids : Vector Id K) (g : Membership MAX) (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K)
    (hi : Inv ids g C G) (k : Fin K) (a : Option (Fin MAX)) (src dst : Id) (hsrc : src ≠ ids[k])
    (ha : ∀ i, a = some i → (C.node k).peers[i] = some src) (hI : Idle (C.node k))
    (t : Rust.u64) (prev : LogId) (entries : Vector (Option (DEntry V MAX)) MAX_APPEND_ENTRIES) (commit : Rust.u64)
    (hm : (⟨src, dst, .AppendBatch t prev entries commit⟩ : DEnv V S MAX) ∈ C.sent)
    (hvalid : Rust.Iter.flatten entries.toList ≠ [] ∧ Consec prev (Rust.Iter.flatten entries.toList))
    (n1 n2 n3 : DNode V S MAX CAP) (resp : Rust.u64 × Option Rejection)
    (hO : ObservedD (C.node k) src t n1) (hT : n1.state.hard.term = t) (hFol : FollowingD n1 src n2)
    (hB : BatchD n2 prev (Rust.Iter.flatten entries.toList) commit resp n3) :
    LocalOk' ids g C G k ⟨queueD n3 a src (.Replicated resp.1 resp.2)⟩ := by
  obtain ⟨-, L, hL, hprev, hent, -, hcomm, hsender⟩ := hi.sent _ hm
  obtain ⟨hLc, hLt, ⟨ca, eLt, he, hpe, -⟩, -⟩ := hi.wf.leader t.val L hL
  have hlead : ∀ c eL, G.elect t.val = some (c, eL) → c ≠ k := fun c eL h e => hsrc (by
    have := hsender c eL h; rw [e] at this; exact this)
  obtain ⟨hP, hpeers⟩ := pre_of ids g C G hi k hI src t n1 n2 hO hT hFol hlead
  obtain ⟨hF, hrep⟩ := batch_all ids g C G hi k t.val n2 hP.term L hL hLc hLt ca (hlead ca eLt he) eLt he hpe
    commit hcomm n2 prev _ resp n3 hB hP.ok hprev hent hvalid.1 hvalid.2
  exact local_reply ids g C G k a src hsrc t.val n2 n3 hP hF (fun i h => by rw [hpeers]; exact ha i h) resp.1 resp.2 hrep


/-- `Install`: a snapshot of the leader log's committed prefix is installed. -/
theorem fok_install (ids : Vector Id K) (g : Membership MAX) (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K)
    (hi : Inv ids g C G) (k : Fin K) (t : Nat) (n2 : DNode V S MAX CAP) (hF : FOk ids g C G k t n2 n2)
    (htn : n2.state.hard.term.val = t)
    (L : List (DEntry V MAX)) (hL : G.leader t = some L) (hLc : Consistent G L)
    (hLt : ∀ e ∈ L, 0 < e.id.term.val ∧ e.id.term.val ≤ t) (a : Fin K) (hak : a ≠ k) (eLt : List (DEntry V MAX))
    (he : G.elect t = some (a, eLt)) (hpe : eLt <+: L)
    (snap : Snapshot (Checkpoint S MAX)) (hpos : 0 < snap.last.index.val)
    (hsl : snap.last.index.val - 1 < L.length) (hLs : L[snap.last.index.val - 1].id = snap.last)
    (hcomm : CommittedBy ids g G t (L.take snap.last.index.val))
    (hmem : snap.value.membership = cfgOf g (L.take snap.last.index.val))
    (hc2 : n2.state.base.index.val < snap.last.index.val ∧
      (n2.state.hard.commit.val < snap.last.index.val ∨ idAt n2.state snap.last.index.val = some snap.last))
    (s' : DState V S MAX CAP) (hins : State.install n2.state snap = pure s') (lf : Option Rust.u64)
    (n4 : DNode V S MAX CAP) (hR : Refresh { n2 with state := s', log_from := lf } n4) :
    FOk ids g C G k t n2 { n4 with snapshot_changed := true, dirty := true } ∧
      G.prefix t snap.last.index.val <+: fullLog G n4.state ∧ AckOk G t snap.last.index.val := by
  have hs2 := hF.live
  obtain ⟨s'', hins', hsn, hhard, hr, hl'⟩ :=
    install_spec n2.state snap (by have := hF.dyn.cap_lt; uomega) hs2.layout hs2.contig
  rw [hins'] at hins
  have e : s'' = s' := Rust.pure_inj hins
  subst e
  have hc' := install_contig n2.state s'' snap hs2.layout hs2.contig hsn hr
  have hb' : s''.base = snap.last := base_some s'' snap hsn
  have hlen2 := fullLog_length G _ hs2
  have hlast2 := lastId_eq _ hs2.contig
  have hLp : L.take snap.last.index.val = G.prefix snap.last.term.val snap.last.index.val := by
    have := consistent_take_prefix G L hLc _ hpos hsl; rw [hLs] at this; exact this
  obtain ⟨-, L'', hL'', hpL''⟩ := hLc (snap.last.index.val - 1) hsl
  rw [hLs] at hL''
  rw [show snap.last.index.val - 1 + 1 = snap.last.index.val by omega] at hpL''
  have hmx : n2.state.hard.commit.val ≤ (Rust.max n2.state.hard.commit snap.last.index).val ∧
      snap.last.index.val ≤ (Rust.max n2.state.hard.commit snap.last.index).val ∧
      ((Rust.max n2.state.hard.commit snap.last.index).val = n2.state.hard.commit.val ∧
          snap.last.index.val ≤ n2.state.hard.commit.val ∨
        (Rust.max n2.state.hard.commit snap.last.index).val = snap.last.index.val) := by
    rw [Rust.val_max]; simp only [Nat.max_def]; split <;> omega
  have hbase : 0 < s''.base.index.val → ∃ L, G.leader s''.base.term.val = some L ∧ s''.base.index.val ≤ L.length ∧
      ∃ h : s''.base.index.val - 1 < L.length, L[s''.base.index.val - 1].id = s''.base := by
    intro _
    rw [hb']
    have hl1 := hpL''.length_le
    simp only [List.length_take] at hl1
    refine ⟨L'', hL'', by omega, by omega, ?_⟩
    rw [← List.IsPrefix.getElem hpL'' (by simp; omega)]
    simp only [List.getElem_take]; exact hLs
  have hsnap : s''.snapshot.isSome → 0 < s''.base.index.val := fun _ => by rw [hb']; exact hpos
  have hSnap : SnapOk g G s'' := by
    unfold SnapOk snapMem memInit boundary
    rw [hsn, hb']
    simp only [show snap.last.index.val ≠ 0 by omega, if_false]
    rw [← hLp]; exact hmem
  have hnt : n2.state.hard.term.val = t := htn
  obtain ⟨hD4, hr4, hs4, -, hx4, ho4, hp4⟩ := refresh_follower (g := g) (me := ids[k]) n2
    { n2 with state := s'', log_from := lf } n4 hF.dyn rfl rfl rfl hF.role hl' hc' (fun t' h => by
      have := hF.dyn.prevoting t' h
      refine ⟨this.1, ?_⟩
      show t'.val = s''.hard.term.val + 1; rw [hhard]; exact this.2) hF.outbox hR
  have hs4' : n4.state = s'' := hs4
  -- facts common to both outcomes, given the new full log
  have common : ∀ l, fullLog G s'' = l → StateOk G s'' → Consistent G l →
      (∀ t' j, (k, t', j) ∈ G.acks → t' ≤ t ∧ ∀ j' ≤ j, Kept G k t' j' (t + 1) l) →
      CommittedBy ids g G t (l.take s''.hard.commit.val) →
      (∀ T eL, G.elect T = some (k, eL) → (C.disk k).hard.term.val < T → t < T → l = eL) →
      FOk ids g C G k t n2 { n4 with snapshot_changed := true, dirty := true } := by
    intro l hfl hst hcons hacks hcomm' helect
    refine ⟨dynOk_frame hD4 rfl rfl rfl rfl rfl rfl rfl hD4.layout hD4.contig hD4.prevoting, hr4, ho4,
      by rw [show n4.extra_reply = n2.extra_reply from hx4]; exact hF.extra, ?_, ?_, ?_, ?_, ?_, ?_,
      fun hd => (by cases hd), ?_, ?_, ?_⟩
    · show n4.state.hard.term = _; rw [hs4', hhard]
    · show n4.state.hard.voted_for = _; rw [hs4', hhard]
    · show StateOk G n4.state; rw [hs4']; exact hst
    · show SnapOk g G n4.state; rw [hs4']; exact hSnap
    · show Consistent G (fullLog G n4.state); rw [hs4', hfl]; exact hcons
    · intro t' j h; show t' ≤ t ∧ ∀ j' ≤ j, Kept G k t' j' (t + 1) (fullLog G n4.state); rw [hs4', hfl]; exact hacks t' j h
    · show CommittedBy ids g G t ((fullLog G n4.state).take n4.state.hard.commit.val); rw [hs4', hfl]; exact hcomm'
    · intro T eL hel' hd ht; show fullLog G n4.state = eL; rw [hs4', hfl]; exact helect T eL hel' hd ht
    · intro i y hy
      obtain ⟨x', hx', -⟩ := hp4 i y hy
      exact ⟨x', hx'⟩
  have hreply : ∀ l, L.take snap.last.index.val <+: l → G.prefix t snap.last.index.val <+: l ∧ AckOk G t snap.last.index.val := by
    intro l hl
    refine ⟨by rw [prefix_eq_take G t _ L hL]; exact hl, L, hL, by omega⟩
  by_cases hkeep : idAt n2.state snap.last.index.val = some snap.last
  · rw [if_pos hkeep] at hr
    have hfl := fullLog_install_keep G n2.state s'' snap hs2 hF.cons hkeep hpos hr hsn
    obtain ⟨htake, hidx⟩ := match_take G _ hs2 hF.cons L hLc _ snap.last hkeep (fun _ => ⟨hsl, hLs⟩)
    obtain ⟨hi1, hi2⟩ := idAt_some _ hs2.layout hs2.contig _ hkeep
    have hlast' : (lastId s'').index.val = (lastId n2.state).index.val := by
      rw [lastId_eq s'' hc', hr, hb', hlast2]; simp only [List.length_drop]; omega
    have hst : StateOk G s'' := by
      refine ⟨hl', hc', hbase, hsnap, ?_, ?_, ?_, ?_⟩
      · rw [hfl, hhard]; exact hs2.terms
      · rw [hhard, hb']; exact hmx.2.1
      · rw [hhard, hlast']; have := hs2.commit_le
        show (Rust.max n2.state.hard.commit snap.last.index).val ≤ _
        rcases hmx.2.2 with ⟨h, -⟩ | h <;> rw [h] <;> omega
      · rw [hhard]; exact hs2.unvoted
    refine ⟨common _ hfl hst hF.cons hF.acks ?_ hF.elect, ?_⟩
    · rw [hhard]
      show CommittedBy ids g G t ((fullLog G n2.state).take (Rust.max n2.state.hard.commit snap.last.index).val)
      rcases hmx.2.2 with ⟨h, -⟩ | h <;> rw [h]
      · exact hF.committed
      · rw [htake]; exact hcomm
    · rw [hs4', hfl]; exact hreply _ (by rw [← htake]; exact List.take_prefix _ _)
  · rw [if_neg hkeep] at hr
    have hfl := fullLog_install_reset G s'' snap hr hsn hpos
    rw [← hLp] at hfl
    have hcl : n2.state.hard.commit.val < snap.last.index.val := hc2.2.resolve_right hkeep
    have hlast' : (lastId s'').index.val = snap.last.index.val := by
      rw [lastId_eq s'' hc', hr, hb']; rfl
    have hrepl : ∀ p, p <+: fullLog G n2.state → p <+: L → p <+: L.take snap.last.index.val := by
      intro p hp1 hp2
      by_cases hpl' : p.length ≤ snap.last.index.val
      · exact prefix_take_of p L _ hp2 hpl'
      · exfalso; apply hkeep
        have hlt1 : snap.last.index.val - 1 < p.length := by omega
        have h1 := hp1.getElem hlt1
        have h2 := hp2.getElem hlt1
        refine (idAt_fullLog G _ hs2 _ hpos _).mpr ⟨by omega, by have := hp1.length_le; omega, ?_⟩
        rw [← h1, h2, hLs]
    have hst : StateOk G s'' := by
      refine ⟨hl', hc', hbase, hsnap, ?_, ?_, ?_, ?_⟩
      · rw [hfl, hhard]; intro x hx; rw [hnt]; exact (hLt x (List.mem_of_mem_take hx)).2
      · rw [hhard, hb']; exact hmx.2.1
      · rw [hhard, hlast']
        show (Rust.max n2.state.hard.commit snap.last.index).val ≤ _
        rcases hmx.2.2 with ⟨h, -⟩ | h <;> rw [h] <;> omega
      · rw [hhard]; exact hs2.unvoted
    refine ⟨common _ hfl hst (consistent_take G L hLc _) (fun t' j h => ?_) ?_
      (fun T eL hel' hd ht => (no_elect_above ids g C G hi k T eL hel' hd).elim), ?_⟩
    · obtain ⟨h1, h2⟩ := hF.acks t' j h
      exact ⟨h1, fun j' hj' => kept_replace G k a hak t t' j' (t + 1) _ _ L eLt hL he hpe h1 (Nat.le_refl _)
        (h2 j' hj') hrepl⟩
    · rw [hhard]
      show CommittedBy ids g G t ((L.take snap.last.index.val).take (Rust.max n2.state.hard.commit snap.last.index).val)
      rcases hmx.2.2 with ⟨-, h⟩ | h
      · omega
      · rw [h, List.take_take, Nat.min_self]; exact hcomm
    · rw [hs4', hfl]; exact hreply _ (List.prefix_refl _)


/-- `Install`: follow the sender, maybe install its snapshot, and reply. -/
theorem case_install (ids : Vector Id K) (g : Membership MAX) (hid : ∀ a b : Fin K, ids[a] = ids[b] → a = b)
    (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K)
    (hi : Inv ids g C G) (k : Fin K) (a : Option (Fin MAX)) (src dst : Id) (hsrc : src ≠ ids[k])
    (ha : ∀ i, a = some i → (C.node k).peers[i] = some src) (hI : Idle (C.node k))
    (t : Rust.u64) (snap : Snapshot (Checkpoint S MAX))
    (hm : (⟨src, dst, .Install t snap⟩ : DEnv V S MAX) ∈ C.sent)
    (n1 n2 n3 : DNode V S MAX CAP) (rej : Option Rejection)
    (hO : ObservedD (C.node k) src t n1) (hT : n1.state.hard.term = t) (hFol : FollowingD n1 src n2)
    (hc : (snap.last.index.val ≤ n2.state.hard.commit.val ∧
          Rust.Option.is_some_and (State.id_at n2.state snap.last.index) (fun id => id != snap.last) = true ∧
          rej.isSome ∧ n3 = n2) ∨
        (¬ (snap.last.index.val ≤ n2.state.hard.commit.val ∧
          Rust.Option.is_some_and (State.id_at n2.state snap.last.index) (fun id => id != snap.last) = true) ∧
          rej = none ∧
          ((¬ (n2.state.base.index.val < snap.last.index.val ∧
              (n2.state.hard.commit.val < snap.last.index.val ∨ idAt n2.state snap.last.index.val = some snap.last))
              ∧ n3 = n2) ∨
            (n2.state.base.index.val < snap.last.index.val ∧
              (n2.state.hard.commit.val < snap.last.index.val ∨ idAt n2.state snap.last.index.val = some snap.last) ∧
              ∃ s' lf n4, State.install n2.state snap = pure s' ∧
                Refresh { n2 with state := s', log_from := lf } n4 ∧
                n3 = { n4 with snapshot_changed := true, dirty := true })))) :
    LocalOk' ids g C G k ⟨queueD n3 a src (.Replicated snap.last.index rej)⟩ := by
  obtain ⟨-, L, hL, hpos, ⟨hsl, hLs⟩, hcomm, hmem, hsender⟩ := hi.sent _ hm
  obtain ⟨hLc, hLt, ⟨ca, eLt, he, hpe, -⟩, -⟩ := hi.wf.leader t.val L hL
  have hlead : ∀ c eL, G.elect t.val = some (c, eL) → c ≠ k := fun c eL h e => hsrc (by
    have := hsender c eL h; rw [e] at this; exact this)
  obtain ⟨hP, hpeers⟩ := pre_of ids g C G hi k hI src t n1 n2 hO hT hFol hlead
  have ha' : ∀ i, a = some i → n2.peers[i] = some src := fun i h => by rw [hpeers]; exact ha i h
  rcases hc with ⟨-, -, hr, h3⟩ | ⟨-, rfl, ⟨hn, h3⟩ | ⟨h1, h2, s', lf, n4, hins, hR, rfl⟩⟩
  · rw [h3]; exact local_reply ids g C G k a src hsrc t.val n2 n2 hP hP.ok ha' _ _ (fun h => by rw [h] at hr; cases hr)
  · rw [h3]
    refine local_reply ids g C G k a src hsrc t.val n2 n2 hP hP.ok ha' _ _ (fun _ => ⟨?_, L, hL, by omega⟩)
    have hs2 := hP.ok.live
    have hle : snap.last.index.val ≤ n2.state.hard.commit.val := by
      by_cases hb : n2.state.base.index.val < snap.last.index.val
      · apply Classical.byContradiction; intro h; exact hn ⟨hb, Or.inl (by omega)⟩
      · have := hs2.commit_ge; omega
    have hlen := fullLog_length G _ hs2
    have hcl := hs2.commit_le
    rw [prefix_eq_take G t.val _ L hL]
    rcases committed_compatible hid G hi.wf _ _ _ _ hcomm hP.ok.committed with hp | hp
    · exact hp.trans (List.take_prefix _ _)
    · have h1 : (L.take snap.last.index.val).length = snap.last.index.val := by simp; omega
      have h2 : ((fullLog G n2.state).take n2.state.hard.commit.val).length = n2.state.hard.commit.val := by
        simp; omega
      have := hp.length_le
      rw [← hp.eq_of_length (by omega)]
      exact List.take_prefix _ _
  · obtain ⟨hF, hrep, hack⟩ := fok_install ids g C G hi k t.val n2 hP.ok hP.term L hL hLc hLt ca (hlead ca eLt he) eLt he
      hpe snap hpos hsl hLs hcomm hmem ⟨h1, h2⟩ s' hins lf n4 hR
    exact local_reply ids g C G k a src hsrc t.val n2 _ hP hF ha' _ _ (fun _ => ⟨hrep, hack⟩)

end PLog

/-- Messages of log replication. -/
def LogMsg (m : DMsg V S MAX) : Prop :=
  match m with
  | .Append .. | .AppendBatch .. | .Install .. | .Replicated .. => True
  | _ => False

variable (ids : Vector Id K) (g : Membership MAX) (hid : ∀ a b : Fin K, ids[a] = ids[b] → a = b) (hg : MemOk g)

include hid hg in
theorem preserve_deliver_log [Rust.LawfulClone V] [Rust.LawfulClone S] (C : World V S MAX CAP K)
    (G : Ghost (Record V MAX) K) (hi : Inv ids g C G) (k : Fin K) (env : DEnv V S MAX) (henv : env ∈ C.sent)
    (hm : LogMsg env.message) (r : Rust.Result Unit Error) (c : Jarl.Cluster V S MAX CAP)
    (h : Cluster.step (C.live k) env = pure (r, c)) : ∃ G', Extends G G' ∧ Inv ids g (C.setLive k c) G' := by
  have hD := hi.dyn k
  unfold Cluster.step at h
  obtain ⟨⟨r', m⟩, hstep, hcl⟩ := Rust.bind_eq_pure h
  have hc' := Rust.pure_inj hcl
  obtain ⟨-, rfl⟩ := Prod.mk.inj hc'
  obtain ⟨a, ha, -, hst, hval⟩ := step_rel' (C.live k).node hD.pre (hi.live k).1.commit_ge (hi.live k).1.commit_le
    env r' m hstep
  rcases hval with heq | ⟨hto, hne, hvalid⟩
  · subst heq
    have e : (⟨(C.live k).node⟩ : Jarl.Cluster V S MAX CAP) = C.live k := rfl
    refine ⟨G, Extends.refl G, ?_⟩
    rw [e, PLog.setLive_same]; exact hi
  have hsrc : env.from ≠ ids[k] := by rw [← hD.id]; exact hne
  have hS := hi.sent env henv
  refine ⟨G, Extends.refl G, setLive_inv' ids g C G hi k _ ?_⟩
  rcases env with ⟨src, dst, msg⟩
  simp only at hsrc ha hst hS hm
  cases hst with
  | same => exact PLog.local_self ids g C G hi k
  | ignored _ hI =>
    obtain ⟨hd0, hex0, hob0⟩ := hI
    exact PLog.local_keep ids g C G hi k hd0 _ rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl
      (fun i o h => by simp only at h; rw [hob0 i] at h; cases h)
      (fun h o ho => absurd ((hob0 ⟨_, h⟩).symm.trans ho) (by simp)) (fun to o h => by simp only at h; rw [hex0] at h; cases h)
  | prevote => exact hm.elim
  | prevoted => exact hm.elim
  | vote => exact hm.elim
  | voted => exact hm.elim
  | stale _ n1 _ hI hO hlt hn => exact PLog.case_stale ids g C G hi k a src hsrc ha hI msg n1 _ hO hlt hn
  | append t prev entry commit n1 n2 n3 r hI hO hT hFol hA =>
    exact PLog.case_append ids g C G hi k a src dst hsrc ha hI t prev entry commit henv n1 n2 n3 r hO hT hFol hA
  | appendBatch t prev entries commit n1 n2 n3 resp hI hO hT hFol hB =>
    exact PLog.case_batch ids g C G hi k a src dst hsrc ha hI t prev entries commit henv
      (PLog.valid_batch t prev entries commit hvalid) n1 n2 n3 resp hO hT hFol hB
  | install t snap n1 n2 n3 rej hI hO hT hFol hc =>
    exact PLog.case_install ids g hid C G hi k a src dst hsrc ha hI t snap henv n1 n2 n3 rej hO hT hFol hc
  | replicated t index rej n1 _ i hI ha' hO hT hc =>
    subst ha'
    exact PLog.case_replicated ids g C G hi k i src dst hsrc (ha i rfl) hI t index rej henv n1 _ hO hT hc

end Jarl.Engine.Dyn
