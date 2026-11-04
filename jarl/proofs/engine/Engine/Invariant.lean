import Engine.Cluster

/-!
# The cluster invariant

`Inv ids cfg C G` relates a reachable cluster `C` to a ghost history `G`. Its
consequence `Wf G` gives leader completeness (`leader_complete`), and its
commitment clause makes every node's durable committed prefix `Committed`, so
any two committed prefixes are compatible (`committed_compatible`).
-/

namespace Jarl.Engine
open Jarl

variable {V S : Type} {N CAP : Nat}

/-- A checkpoint's own facts: its snapshot boundary is an entry of a leader
    log, entries are no newer than its term, and `base ≤ commit ≤ last`. -/
structure StateOk (G : Ghost V N) (s : State V S CAP) : Prop where
  layout : Layout s
  contig : Contig s
  base : 0 < s.base.index.val → ∃ L, G.leader s.base.term.val = some L ∧ s.base.index.val ≤ L.length ∧
    ∃ h : s.base.index.val - 1 < L.length, L[s.base.index.val - 1].id = s.base
  snapshot : s.snapshot.isSome → 0 < s.base.index.val
  terms : ∀ e ∈ fullLog G s, e.id.term.val ≤ s.hard.term.val
  commit_ge : s.base.index.val ≤ s.hard.commit.val
  commit_le : s.hard.commit.val ≤ (lastId s).index.val
  unvoted : s.hard.term.val = 0 → s.hard.voted_for = none

/-- The prefix a success acknowledgment of `j` entries in term `t` refers to exists. -/
def AckOk (G : Ghost V N) (t j : Nat) : Prop := ∃ L, G.leader t = some L ∧ j ≤ L.length

/-- The slot of node `k`'s identity. -/
abbrev idOf (ids : Vector Id N) (k : Fin N) : Id := ids[k]

/-- A message's facts, by kind. -/
def SentOk (ids : Vector Id N) (C : Cluster V S N CAP) (G : Ghost V N) (env : Envelope V S) : Prop :=
  (∃ a : Fin N, env.from = ids[a]) ∧
  match env.message with
  | .Vote T last => ∀ c : Fin N, env.from = ids[c] →
      T.val ≤ (C.disk c).hard.term.val ∧
      ((C.live c).role = .Candidate ∧ (C.live c).state.hard.term = T → lastId (C.live c).state = last) ∧
      (∀ eL, G.elect T.val = some (c, eL) → lastOf eL = last)
  | .Voted T g => g = true → ∀ w c : Fin N, env.from = ids[w] → env.to = ids[c] →
      (∃ vlog, (T.val, w, c, vlog) ∈ G.ballots) ∨ ∃ eL, G.elect T.val = some (c, eL)
  | .Replicated T j r => r = none → ∀ w : Fin N, env.from = ids[w] → (w, T.val, j.val) ∈ G.acks
  | .Append T prev entry commit => ∃ L, G.leader T.val = some L ∧
      (0 < prev.index.val → ∃ h : prev.index.val - 1 < L.length, L[prev.index.val - 1].id = prev) ∧
      (prev.index.val = 0 → prev = LogId.default) ∧
      (∀ e, entry = some e → ∃ h : e.id.index.val - 1 < L.length, L[e.id.index.val - 1] = e ∧
        e.id.index.val = prev.index.val + 1) ∧
      commit.val ≤ L.length ∧ Committed G (L.take commit.val) ∧
      ∀ c eL, G.elect T.val = some (c, eL) → env.from = ids[c]
  | .Install T snap => ∃ L, G.leader T.val = some L ∧ 0 < snap.last.index.val ∧
      ∃ h : snap.last.index.val - 1 < L.length, L[snap.last.index.val - 1].id = snap.last ∧
      Committed G (L.take snap.last.index.val) ∧
      ∀ c eL, G.elect T.val = some (c, eL) → env.from = ids[c]
  | .PreVote .. | .PreVoted .. | .AppendBatch .. => False

/-- A pending descriptor's facts. -/
def OutOk (ids : Vector Id N) (C : Cluster V S N CAP) (G : Ghost V N) (k j : Fin N) (o : Outbound) : Prop :=
  let n := C.live k
  match o with
  | .Vote => n.role = .Candidate
  | .Voted g => g = true → n.state.hard.voted_for = some ids[j] ∧
      ∃ last, (⟨ids[j], ids[k], .Vote n.state.hard.term last⟩ : Envelope V S) ∈ C.sent ∧
        upToDate last (lastOf (fullLog G n.state))
  | .Replicated i r => r = none → G.prefix n.state.hard.term.val i.val <+: fullLog G n.state ∧
      AckOk G n.state.hard.term.val i.val
  | .Replicate => n.role = .Leader
  | .PreVote .. | .PreVoted .. => False

/-- A leader's facts: it is the elected leader of its term, its log extends its
    election log by entries of its term and extends the leader log, and every
    match index is backed by an acknowledgment. -/
structure LeaderOk (ids : Vector Id N) (C : Cluster V S N CAP) (G : Ghost V N) (k : Fin N) : Prop where
  elected : ∃ eL, G.elect (C.live k).state.hard.term.val = some (k, eL) ∧ eL <+: fullLog G (C.live k).state ∧
    ∀ i (h : i < (fullLog G (C.live k).state).length), eL.length ≤ i →
      ((fullLog G (C.live k).state)[i]).id.term = (C.live k).state.hard.term
  log : ∃ L, G.leader (C.live k).state.hard.term.val = some L ∧ L <+: fullLog G (C.live k).state ∧
    ((C.live k).dirty = false → L = fullLog G (C.live k).state)
  matched : ∀ j : Fin N, j ≠ k → 0 < ((C.live k).matched[j]).val →
    (j, (C.live k).state.hard.term.val, ((C.live k).matched[j]).val) ∈ G.acks
  own : ((C.live k).matched[k]).val ≤ (fullLog G (C.live k).state).length

/-- A candidate's facts: each counted vote is a ballot for it whose voter's log
    its own log is at least as up to date as. -/
def CandidateOk (ids : Vector Id N) (C : Cluster V S N CAP) (G : Ghost V N) (k : Fin N) : Prop :=
  (C.live k).state.hard.voted_for = some ids[k] ∧
  (∀ e ∈ fullLog G (C.live k).state, e.id.term.val < (C.live k).state.hard.term.val) ∧
  ∀ j : Fin N, (C.live k).votes[j] = true → j = k ∨
    ∃ vlog, ((C.live k).state.hard.term.val, j, k, vlog) ∈ G.ballots ∧
      upToDate (lastOf (fullLog G (C.live k).state)) (lastOf vlog)

/-- The ghost once leader `k` saves its log: its log is the leader log of its
    term and it acknowledges all of it. -/
def withOwn (G : Ghost V N) (k : Fin N) (n : Node V S N CAP) : Ghost V N :=
  { G with acks := (k, n.state.hard.term.val, (fullLog G n.state).length) :: G.acks, leader := fun t => if t = n.state.hard.term.val then some (fullLog G n.state) else G.leader t }

/-- A node's committed prefix. For a leader with an unsaved commit, its own log
    counts as acknowledged. -/
def CommitOk (G : Ghost V N) (k : Fin N) (n : Node V S N CAP) : Prop :=
  Committed G ((fullLog G n.state).take n.state.hard.commit.val) ∨
    (n.role = .Leader ∧ n.dirty = true ∧
      Committed (withOwn G k n) ((fullLog G n.state).take n.state.hard.commit.val))

structure Inv (ids : Vector Id N) (cfg : Fin N → Config N) (C : Cluster V S N CAP) (G : Ghost V N) : Prop where
  wf : Wf G
  fixed : ∀ k, Fixed ids (C.live k) ∧ (C.live k).config = cfg k
  slot : ∀ k, (C.live k).local.val = k.val
  live : ∀ k, StateOk G (C.live k).state
  disk : ∀ k, StateOk G (C.disk k)
  consistent_disk : ∀ k, Consistent G (fullLog G (C.disk k))
  consistent_live : ∀ k, (C.live k).role ≠ .Leader → Consistent G (fullLog G (C.live k).state)
  clean : ∀ k, (C.live k).dirty = false → (C.live k).state = C.disk k
  terms : ∀ k, (C.disk k).hard.term.val ≤ (C.live k).state.hard.term.val
  acks : ∀ w t j, (w, t, j) ∈ G.acks → AckOk G t j ∧ t ≤ (C.disk w).hard.term.val ∧
    ∀ j' ≤ j, Kept G w t j' ((C.live w).state.hard.term.val + 1) (fullLog G (C.live w).state) ∧
      Kept G w t j' ((C.disk w).hard.term.val + 1) (fullLog G (C.disk w))
  ballots : ∀ T w c vlog, (T, w, c, vlog) ∈ G.ballots →
    (T ≤ (C.disk w).hard.term.val ∨
      (w = c ∧ (C.disk w).hard.term.val + 1 = T ∧ G.elect T = some (c, vlog))) ∧
    (w ≠ c → T ≤ (C.disk c).hard.term.val) ∧
    ((C.disk w).hard.term.val = T → (C.disk w).hard.voted_for = some ids[c]) ∧
    ((C.live w).state.hard.term.val = T → (C.live w).state.hard.voted_for = some ids[c])
  ballot_unique : ∀ T w c c' v v', (T, w, c, v) ∈ G.ballots → (T, w, c', v') ∈ G.ballots → c = c'
  ballot_cand : ∀ T w c vlog, (T, w, c, vlog) ∈ G.ballots → (C.live c).role = .Candidate →
    (C.live c).state.hard.term.val = T → upToDate (lastOf (fullLog G (C.live c).state)) (lastOf vlog)
  elect : ∀ T c eL, G.elect T = some (c, eL) → (C.disk c).hard.term.val < T →
    G.leader T = some eL ∧ fullLog G (C.disk c) = eL ∧ (C.disk c).hard.term.val + 1 = T ∧
    ((C.live c).state.hard.term.val < T → fullLog G (C.live c).state = eL ∧ (C.live c).role ≠ .Leader ∧
      (C.live c).state.hard.term = (C.disk c).hard.term)
  elect_cand : ∀ T c eL, G.elect T = some (c, eL) →
    ¬ ((C.live c).role = .Candidate ∧ (C.live c).state.hard.term.val = T)
  leader : ∀ k, (C.live k).role = .Leader → LeaderOk ids C G k
  candidate : ∀ k, (C.live k).role = .Candidate → CandidateOk ids C G k
  outbox : ∀ k j o, (C.live k).outbox[j] = some o → OutOk ids C G k j o
  outbox_self : ∀ k, (C.live k).outbox[k] = none
  sent : ∀ env ∈ C.sent, SentOk ids C G env
  committed : ∀ k, Committed G ((fullLog G (C.disk k)).take (C.disk k).hard.commit.val) ∧ CommitOk G k (C.live k)

end Jarl.Engine
