import Engine.Dyn.OpPropose
import Engine.LogFacts

/-!
# A dynamic cluster and its invariant

`K` nodes with the distinct identities `ids` run the generated code of every
public `Cluster` operation (`DAct`). Each node has volatile state (`live`) and a
durable checkpoint (`disk`); `sent` is every message ever materialized. The
network may deliver any sent message to any node, any number of times, in any
order. Nodes start empty from the shared genesis configuration `g`; a node
whose identity is outside a configuration is passive until added. A
membership change's target is any valid `Membership` (`MemOk`), and every
operation may be invoked at any time with any arguments. An operation that
panics or diverges has no transition (the node crashed); `restart` rebuilds a
node from its checkpoint through `ClusterState::restore` and `Cluster::new`.

`Inv ids g C G` relates a reachable cluster to a ghost history (`Ghost`, over
the `K` nodes). Compared with the fixed engine, a node is `Leading` when it is
the elected leader of its current term, whatever its role: a removed leader
steps down once the configuration removing it is committed, possibly with
entries not yet saved, and its log is still its term's leader log.
-/

set_option linter.unusedSectionVars false

namespace Jarl.Engine.Dyn
open Jarl Jarl.Engine

variable {V S : Type} {MAX CAP K : Nat} [Rust.Clone V] [Rust.Clone S]

structure World (V S : Type) (MAX CAP K : Nat) where
  live : Fin K → Jarl.Cluster V S MAX CAP
  disk : Fin K → DState V S MAX CAP
  sent : List (DEnv V S MAX)

/-- Node `k`'s volatile state. -/
abbrev World.node (C : World V S MAX CAP K) (k : Fin K) : DNode V S MAX CAP := (C.live k).node

/-- Replace node `k`'s volatile state. -/
def World.setLive (C : World V S MAX CAP K) (k : Fin K) (c : Jarl.Cluster V S MAX CAP) : World V S MAX CAP K :=
  { C with live := fun j => if j = k then c else C.live j }

/-- Save node `k`'s checkpoint and acknowledge it through `Ready`. -/
def World.persist (C : World V S MAX CAP K) (k : Fin K) (c : Jarl.Cluster V S MAX CAP) : World V S MAX CAP K :=
  { C with live := fun j => if j = k then c else C.live j,
           disk := fun j => if j = k then (C.live k).node.state else C.disk j }

/-- One step of the cluster. -/
inductive DAct (ids : Vector Id K) (g : Membership MAX) (C : World V S MAX CAP K) : World V S MAX CAP K → Prop
  | tick (k : Fin K) (r : Rust.Result Unit Error) (c : Jarl.Cluster V S MAX CAP) :
      Cluster.tick (C.live k) = pure (r, c) → DAct ids g C (C.setLive k c)
  | deliver (k : Fin K) (env : DEnv V S MAX) (r : Rust.Result Unit Error) (c : Jarl.Cluster V S MAX CAP) :
      env ∈ C.sent → Cluster.step (C.live k) env = pure (r, c) → DAct ids g C (C.setLive k c)
  | propose (k : Fin K) (v : V) (r : Rust.Result LogId Error) (c : Jarl.Cluster V S MAX CAP) :
      Cluster.propose (C.live k) v = pure (r, c) → DAct ids g C (C.setLive k c)
  | proposeBatch (k : Fin K) (vs : Array V) (r : Rust.Result ProposalRange Error) (c : Jarl.Cluster V S MAX CAP) :
      vs.size < 2 ^ Rust.usizeBits → Cluster.propose_batch (C.live k) vs = pure (r, c) → DAct ids g C (C.setLive k c)
  | compact (k : Fin K) (index : Rust.u64) (app : S) (r : Rust.Result Unit Error) (c : Jarl.Cluster V S MAX CAP) :
      Cluster.compact (C.live k) index app = pure (r, c) → DAct ids g C (C.setLive k c)
  | setLearners (k : Fin K) (learners : Array Id) (r : Rust.Result LogId Error) (c : Jarl.Cluster V S MAX CAP) :
      learners.size < 2 ^ Rust.usizeBits → Cluster.set_learners (C.live k) learners = pure (r, c) →
      DAct ids g C (C.setLive k c)
  | reconfigure (k : Fin K) (target : Membership MAX) (r : Rust.Result LogId Error) (c : Jarl.Cluster V S MAX CAP) :
      MemOk target → Cluster.reconfigure (C.live k) target = pure (r, c) → DAct ids g C (C.setLive k c)
  | finish (k : Fin K) (r : Rust.Result LogId Error) (c : Jarl.Cluster V S MAX CAP) :
      Cluster.finish_reconfiguration (C.live k) = pure (r, c) → DAct ids g C (C.setLive k c)
  | persist (k : Fin K) (ready : Ready (Record V MAX) (Checkpoint S MAX) MAX CAP) :
      Cluster.ready (C.live k) = some ready → DAct ids g C (C.persist k { node := (Ready.persisted ready).node })
  | send (k : Fin K) (env : DEnv V S MAX) (c : Jarl.Cluster V S MAX CAP) :
      Cluster.next_message (C.live k) = pure (some env, c) → DAct ids g C { C.setLive k c with sent := env :: C.sent }
  | drain (k : Fin K) (c : Jarl.Cluster V S MAX CAP) :
      Cluster.next_message (C.live k) = pure (none, c) → DAct ids g C (C.setLive k c)
  | restart (k : Fin K) (settings : Settings) (saved : ClusterState V S MAX CAP) (c : Jarl.Cluster V S MAX CAP) :
      ClusterState.restore ids[k] g (C.disk k) = .Ok saved → Cluster.new settings saved = pure (.Ok c) →
      DAct ids g C (C.setLive k c)

/-- Every node starts from an empty checkpoint and the genesis configuration, and no message was sent. -/
def DInitial (ids : Vector Id K) (g : Membership MAX) (C : World V S MAX CAP K) : Prop :=
  C.sent = [] ∧ ∀ k, C.disk k = State.new ∧ ∃ settings saved,
    ClusterState.new ids[k] g = .Ok saved ∧ Cluster.new settings saved = pure (.Ok (C.live k))

inductive DReach (ids : Vector Id K) (g : Membership MAX) : World V S MAX CAP K → Prop
  | init (C : World V S MAX CAP K) : DInitial ids g C → DReach ids g C
  | step (C C' : World V S MAX CAP K) : DReach ids g C → DAct ids g C C' → DReach ids g C'

/-! ## The invariant -/

/-- Node `k` is the elected leader of its current term. -/
def Leading (G : Ghost (Record V MAX) K) (k : Fin K) (n : DNode V S MAX CAP) : Prop :=
  ∃ eL, G.elect n.state.hard.term.val = some (k, eL)

/-- A checkpoint's snapshot carries the configuration of the history it covers. -/
def SnapOk (g : Membership MAX) (G : Ghost (Record V MAX) K) (s : DState V S MAX CAP) : Prop :=
  snapMem s g = cfgOf g (boundary G s)

/-- The ghost once node `k` saves its log as its term's leader: its log is the
    leader log of its term and it acknowledges all of it. -/
def withOwnD (G : Ghost (Record V MAX) K) (k : Fin K) (n : DNode V S MAX CAP) : Ghost (Record V MAX) K :=
  { G with acks := (k, n.state.hard.term.val, (fullLog G n.state).length) :: G.acks,
           leader := fun t => if t = n.state.hard.term.val then some (fullLog G n.state) else G.leader t }

/-- The ghost once node `k`, which won its term `T` at once with its own vote
    (before saving `T`), saves it: the election with log `eL` and its self-ballot are
    recorded, its log becomes the leader log of `T`, and it acknowledges all of it. -/
def winOwnD (G : Ghost (Record V MAX) K) (k : Fin K) (n : DNode V S MAX CAP) (eL : List (DEntry V MAX)) :
    Ghost (Record V MAX) K :=
  { leader := fun t => if t = n.state.hard.term.val then some (fullLog G n.state) else G.leader t,
    elect := fun t => if t = n.state.hard.term.val then some (k, eL) else G.elect t,
    acks := (k, n.state.hard.term.val, (fullLog G n.state).length) :: G.acks,
    ballots := (n.state.hard.term.val, k, k, eL) :: G.ballots }

variable (ids : Vector Id K) (g : Membership MAX)

/-- Node `k` won its current term at once with its own vote (its configuration's
    quorum is itself) before saving that term: the win is pending, recorded in the
    ghost only when the term is saved (`winOwnD`). Until then the node is frozen
    (dirty), its saved log is its election log, and its live log extends it by
    entries of the new term. -/
def PendingWin (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (k : Fin K) (n : DNode V S MAX CAP) : Prop :=
  n.dirty = true ∧ n.role ≠ .Candidate ∧ G.elect n.state.hard.term.val = none ∧
  (C.disk k).hard.term.val + 1 = n.state.hard.term.val ∧ n.state.hard.voted_for = some ids[k] ∧
  Quorum (cfgOf g (fullLog G (C.disk k))) (fun id => id = ids[k]) ∧
  fullLog G (C.disk k) <+: fullLog G n.state ∧
  (∀ i (h : i < (fullLog G n.state).length), (fullLog G (C.disk k)).length ≤ i →
    ((fullLog G n.state)[i]).id.term = n.state.hard.term) ∧
  ChainIn (ids := ids) (g := g) G (fullLog G n.state) ∧
  (∀ i (hi : i < (fullLog G n.state).length) X, recCfg ((fullLog G n.state)[i]).value = some X → MemOk X)

/-- The log facts of a node leading its term: it extends its election log by
    entries of its term and extends its term's leader log (equal once saved),
    and its configuration records satisfy the chain with commitment judged now. -/
structure LeadLog (G : Ghost (Record V MAX) K) (k : Fin K) (n : DNode V S MAX CAP) : Prop where
  elected : ∃ eL, G.elect n.state.hard.term.val = some (k, eL) ∧ eL <+: fullLog G n.state ∧
    ∀ i (h : i < (fullLog G n.state).length), eL.length ≤ i →
      ((fullLog G n.state)[i]).id.term = n.state.hard.term
  log : ∃ L, G.leader n.state.hard.term.val = some L ∧ L <+: fullLog G n.state ∧
    (n.dirty = false → L = fullLog G n.state)
  chain : ChainIn (ids := ids) (g := g) G (fullLog G n.state)
  cfgs : ∀ i (hi : i < (fullLog G n.state).length) X, recCfg ((fullLog G n.state)[i]).value = some X → MemOk X

/-- A leader's facts: every positive match index of another slot is an
    acknowledgment by that slot's identity, and its own is within its log. -/
structure LeaderOk' (G : Ghost (Record V MAX) K) (k : Fin K) (n : DNode V S MAX CAP) : Prop where
  matched : ∀ i : Fin MAX, i.val ≠ n.local.val → 0 < (n.matched[i]).val →
    ∃ w : Fin K, n.peers[i] = some ids[w] ∧ (w, n.state.hard.term.val, (n.matched[i]).val) ∈ G.acks
  own : ∀ h : n.local.val < MAX, (n.matched[n.local.val]'h).val ≤ (fullLog G n.state).length

/-- A candidate's facts: it voted for itself, its log predates its term, and
    each counted vote is a ballot for it by the slot's identity. -/
def CandidateOk' (G : Ghost (Record V MAX) K) (k : Fin K) (n : DNode V S MAX CAP) : Prop :=
  n.state.hard.voted_for = some ids[k] ∧
  (∀ e ∈ fullLog G n.state, e.id.term.val < n.state.hard.term.val) ∧
  ∀ i : Fin MAX, n.votes[i] = true → i.val = n.local.val ∨
    ∃ w : Fin K, n.peers[i] = some ids[w] ∧ ∃ vlog, (n.state.hard.term.val, w, k, vlog) ∈ G.ballots ∧
      upToDate (lastOf (fullLog G n.state)) (lastOf vlog)

/-- A pending descriptor's facts, for recipient `to`. -/
def OutOk (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (k : Fin K) (to : Id) (o : Outbound) : Prop :=
  let n := C.node k
  match o with
  | .Vote => n.role = .Candidate
  | .Voted gr => gr = true → n.state.hard.voted_for = some to ∧
      ∃ last, (⟨to, ids[k], .Vote n.state.hard.term last⟩ : DEnv V S MAX) ∈ C.sent ∧
        upToDate last (lastOf (fullLog G n.state))
  | .Replicated i r => r = none → G.prefix n.state.hard.term.val i.val <+: fullLog G n.state ∧
      AckOk G n.state.hard.term.val i.val
  | .Replicate => Leading G k n ∨ PendingWin ids g C G k n
  | .PreVote .. | .PreVoted .. => True

/-- The leader-log facts of a replication request in term `T` with predecessor `prev`. -/
def PrevOk (L : List (DEntry V MAX)) (prev : LogId) : Prop :=
  (0 < prev.index.val → ∃ h : prev.index.val - 1 < L.length, L[prev.index.val - 1].id = prev) ∧
  (prev.index.val = 0 → prev = LogId.default)

/-- An entry is the leader log's entry at its index. -/
def InLog (L : List (DEntry V MAX)) (e : DEntry V MAX) : Prop :=
  ∃ h : e.id.index.val - 1 < L.length, L[e.id.index.val - 1] = e

/-- A message's facts, by kind. -/
def SentOk (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (env : DEnv V S MAX) : Prop :=
  (∃ a : Fin K, env.from = ids[a]) ∧
  match env.message with
  | .Vote T last => ∀ c : Fin K, env.from = ids[c] →
      T.val ≤ (C.disk c).hard.term.val ∧
      ((C.node c).role = .Candidate ∧ (C.node c).state.hard.term = T → lastId (C.node c).state = last) ∧
      (∀ eL, G.elect T.val = some (c, eL) → lastOf eL = last)
  | .Voted T gr => gr = true → ∀ w c : Fin K, env.from = ids[w] → env.to = ids[c] →
      (∃ vlog, (T.val, w, c, vlog) ∈ G.ballots) ∨ ∃ eL, G.elect T.val = some (c, eL)
  | .Replicated T j r => r = none → ∀ w : Fin K, env.from = ids[w] → (w, T.val, j.val) ∈ G.acks
  | .Append T prev entry commit => ∃ L, G.leader T.val = some L ∧ PrevOk L prev ∧
      (∀ e, entry = some e → InLog L e ∧ e.id.index.val = prev.index.val + 1) ∧
      commit.val ≤ L.length ∧ CommittedBy ids g G T.val (L.take commit.val) ∧
      ∀ c eL, G.elect T.val = some (c, eL) → env.from = ids[c]
  | .AppendBatch T prev es commit => ∃ L, G.leader T.val = some L ∧ PrevOk L prev ∧
      (∀ e ∈ Rust.Iter.flatten es.toList, InLog L e) ∧
      commit.val ≤ L.length ∧ CommittedBy ids g G T.val (L.take commit.val) ∧
      ∀ c eL, G.elect T.val = some (c, eL) → env.from = ids[c]
  | .Install T snap => ∃ L, G.leader T.val = some L ∧ 0 < snap.last.index.val ∧
      (∃ h : snap.last.index.val - 1 < L.length, L[snap.last.index.val - 1].id = snap.last) ∧
      CommittedBy ids g G T.val (L.take snap.last.index.val) ∧
      snap.value.membership = cfgOf g (L.take snap.last.index.val) ∧
      ∀ c eL, G.elect T.val = some (c, eL) → env.from = ids[c]
  | .PreVote .. | .PreVoted .. => True

/-- A node's committed prefix. A node leading its term with an unsaved commit
    counts its own log as acknowledged. -/
def CommitOk' (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (k : Fin K) (n : DNode V S MAX CAP) : Prop :=
  CommittedBy ids g G n.state.hard.term.val ((fullLog G n.state).take n.state.hard.commit.val) ∨
    (n.dirty = true ∧ Leading G k n ∧
      CommittedBy ids g (withOwnD G k n) n.state.hard.term.val ((fullLog G n.state).take n.state.hard.commit.val)) ∨
    (∃ eL, PendingWin ids g C G k n ∧ eL = fullLog G (C.disk k) ∧
      CommittedBy ids g (winOwnD G k n eL) n.state.hard.term.val ((fullLog G n.state).take n.state.hard.commit.val))

structure Inv (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) : Prop where
  wf : Wf ids g G
  cfgs : ∀ t L, G.leader t = some L → ∀ i (hi : i < L.length) X, recCfg L[i].value = some X → MemOk X
  dyn : ∀ k, DynOk g ids[k] (C.node k)
  live : ∀ k, StateOk G (C.node k).state ∧ SnapOk g G (C.node k).state
  disk : ∀ k, StateOk G (C.disk k) ∧ SnapOk g G (C.disk k)
  consistent_disk : ∀ k, Consistent G (fullLog G (C.disk k))
  consistent_live : ∀ k, Consistent G (fullLog G (C.node k).state) ∨ ((C.node k).dirty = true ∧ Leading G k (C.node k)) ∨
    PendingWin ids g C G k (C.node k)
  clean : ∀ k, (C.node k).dirty = false → (C.node k).state = C.disk k
  terms : ∀ k, (C.disk k).hard.term.val ≤ (C.node k).state.hard.term.val
  disk_lead : ∀ k eL, G.elect (C.disk k).hard.term.val = some (k, eL) →
    G.leader (C.disk k).hard.term.val = some (fullLog G (C.disk k))
  acks : ∀ w t j, (w, t, j) ∈ G.acks → AckOk G t j ∧ t ≤ (C.disk w).hard.term.val ∧
    ∀ j' ≤ j, Kept G w t j' ((C.node w).state.hard.term.val + 1) (fullLog G (C.node w).state) ∧
      Kept G w t j' ((C.disk w).hard.term.val + 1) (fullLog G (C.disk w))
  ballots : ∀ T w c vlog, (T, w, c, vlog) ∈ G.ballots →
    (T ≤ (C.disk w).hard.term.val ∨
      (w = c ∧ (C.disk w).hard.term.val + 1 = T ∧ G.elect T = some (c, vlog))) ∧
    (w ≠ c → T ≤ (C.disk c).hard.term.val) ∧
    ((C.disk w).hard.term.val = T → (C.disk w).hard.voted_for = some ids[c]) ∧
    ((C.node w).state.hard.term.val = T → (C.node w).state.hard.voted_for = some ids[c])
  ballot_unique : ∀ T w c c' v v', (T, w, c, v) ∈ G.ballots → (T, w, c', v') ∈ G.ballots → c = c'
  ballot_cand : ∀ T w c vlog, (T, w, c, vlog) ∈ G.ballots → (C.node c).role = .Candidate →
    (C.node c).state.hard.term.val = T → upToDate (lastOf (fullLog G (C.node c).state)) (lastOf vlog)
  elect : ∀ T c eL, G.elect T = some (c, eL) → (C.disk c).hard.term.val < T →
    G.leader T = some eL ∧ fullLog G (C.disk c) = eL ∧ (C.disk c).hard.term.val + 1 = T ∧
    ((C.node c).state.hard.term.val < T → fullLog G (C.node c).state = eL ∧ (C.node c).role ≠ .Leader ∧
      (C.node c).state.hard.term = (C.disk c).hard.term)
  elect_disk : ∀ T c eL, G.elect T = some (c, eL) → T ≤ (C.disk c).hard.term.val
  elect_cand : ∀ T c eL, G.elect T = some (c, eL) →
    ¬ ((C.node c).role = .Candidate ∧ (C.node c).state.hard.term.val = T)
  lead : ∀ k, Leading G k (C.node k) → LeadLog ids g G k (C.node k)
  leader : ∀ k, (C.node k).role = .Leader → (Leading G k (C.node k) ∨ PendingWin ids g C G k (C.node k)) ∧
    LeaderOk' ids G k (C.node k)
  candidate : ∀ k, (C.node k).role = .Candidate → CandidateOk' ids G k (C.node k)
  outbox : ∀ k (i : Fin MAX) o, (C.node k).outbox[i] = some o →
    ∃ to, (C.node k).peers[i] = some to ∧ OutOk ids g C G k to o
  outbox_self : ∀ k (h : (C.node k).local.val < MAX) o, (C.node k).outbox[(C.node k).local.val] = some o →
    ∃ i r, o = .Replicated i r
  extra : ∀ k to o, (C.node k).extra_reply = some (to, o) → OutOk ids g C G k to o
  sent : ∀ env ∈ C.sent, SentOk ids g C G env
  committed : ∀ k, CommittedBy ids g G (C.disk k).hard.term.val
      ((fullLog G (C.disk k)).take (C.disk k).hard.commit.val) ∧ CommitOk' ids g C G k (C.node k)

end Jarl.Engine.Dyn
