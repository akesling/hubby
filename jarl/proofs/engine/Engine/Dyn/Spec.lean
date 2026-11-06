import Engine.Dyn.Ops

/-!
# What the public operations of a dynamic node do

One relation per operation, describing every successful run (a panic or
divergence is no transition). The theorems proving that the generated code
satisfies them live in `Engine/Dyn/Op*.lean`.

Replies to an identity without a slot go to `extra_reply`; `queueD n a src o`
queues `o` for slot `a`, or for the requester `src` when `a = none`.
-/

set_option linter.unusedSectionVars false

namespace Jarl.Engine.Dyn
open Jarl Jarl.Engine

variable {V S : Type} {MAX CAP : Nat} [Rust.Clone V] [Rust.Clone S]

/-! ## Common shapes -/

/-- Queue descriptor `o` for slot `a`, or for requester `src` without a slot. -/
def queueD (n : DNode V S MAX CAP) (a : Option (Fin MAX)) (src : Id) (o : Outbound) : DNode V S MAX CAP :=
  match a with
  | some i => { n with outbox := n.outbox.set i.val (some o) i.isLt }
  | none => { n with extra_reply := some (src, o) }

/-- Only the elapsed-time and liveness counters differ. -/
def TimeOnlyD (n n' : DNode V S MAX CAP) : Prop :=
  ∃ e a q act, n' = { n with elapsed := e, leader_age := a, quorum_elapsed := q, active := act }

/-- Observing a message's term: record the sender, and step down to a follower
    of the higher term with no vote (a pending durable change). -/
def ObservedD (n : DNode V S MAX CAP) (src : Id) (t : Rust.u64) (n1 : DNode V S MAX CAP) : Prop :=
  let n0 : DNode V S MAX CAP := { n with request_from := some src }
  (t.val ≤ n.state.hard.term.val ∧ n1 = n0) ∨
  (n.state.hard.term.val < t.val ∧
    Timers { n0 with state := { n0.state with hard := { n0.state.hard with term := t, voted_for := none } }, dirty := true, role := .Follower, prevoting := none, leader := none } n1)

/-- Following a leader of the current term (`follow(Some(src))`). -/
def FollowingD (n : DNode V S MAX CAP) (src : Id) (n2 : DNode V S MAX CAP) : Prop :=
  Timers { n with role := .Follower, prevoting := none, leader := some src, leader_age := 0 } n2

/-! ## `append` -/

/-- `append` replaced the suffix from the entry's index with that entry. -/
def ReplacedD (n : DNode V S MAX CAP) (e : DEntry V MAX) (s' : DState V S MAX CAP) : Prop :=
  ret s' = (ret n.state).take (e.id.index.val - n.state.base.index.val - 1) ++ [e] ∧
  s'.hard = n.state.hard ∧ s'.snapshot = n.state.snapshot ∧ Layout s' ∧ Contig s'

/-- The outcomes of `append(previous, entry, commit)`. -/
def AppendD (n : DNode V S MAX CAP) (prev : LogId) (entry : Option (DEntry V MAX)) (commit : Rust.u64)
    (r : Rust.u64 × Option Rejection) (n' : DNode V S MAX CAP) : Prop :=
  -- The predecessor does not match: reject without change.
  (idAt n.state prev.index.val ≠ some prev ∧ r.1 = prev.index ∧ r.2.isSome ∧ n' = n) ∨
  -- A heartbeat: commit up to the predecessor.
  (idAt n.state prev.index.val = some prev ∧ entry = none ∧ r = (prev.index, none) ∧
    CommitTo n (Rust.min commit prev.index) n') ∨
  -- The entry is already present.
  (∃ e, idAt n.state prev.index.val = some prev ∧ entry = some e ∧
    idAt n.state e.id.index.val = some e.id ∧ r = (e.id.index, none) ∧
    CommitTo n (Rust.min commit e.id.index) n') ∨
  -- A conflict at or below the commit index: reject without change.
  (∃ e, entry = some e ∧ idAt n.state e.id.index.val ≠ some e.id ∧
    e.id.index.val ≤ n.state.hard.commit.val ∧ r.1 = prev.index ∧ r.2.isSome ∧ n' = n) ∨
  -- No room: reject, committing up to the predecessor.
  (∃ e, idAt n.state prev.index.val = some prev ∧ entry = some e ∧
    idAt n.state e.id.index.val ≠ some e.id ∧ r = (prev.index, some .Full) ∧
    CommitTo n (Rust.min commit prev.index) n') ∨
  -- Replace the conflicting suffix with the entry, refresh the configuration,
  -- record the pending save, then commit up to the entry.
  (∃ e s' n1, idAt n.state prev.index.val = some prev ∧ entry = some e ∧
    idAt n.state e.id.index.val ≠ some e.id ∧ n.state.hard.commit.val < e.id.index.val ∧
    ReplacedD n e s' ∧ r = (e.id.index, none) ∧
    Refresh { n with state := s' } n1 ∧
    CommitTo { n1 with dirty := true, log_from := some (Rust.Option.map_or n1.log_from e.id.index (fun f => Rust.min f e.id.index)) }
      (Rust.min commit e.id.index) n')

/-! ## `replicated` -/

/-- The leader after recording a reply from slot `p`: only `active`, `next`
    and slot `p`'s match index may change, the latter raised to `index` on success. -/
def RecordedD (n m : DNode V S MAX CAP) (p : Fin MAX) (index : Rust.u64) (rej : Option Rejection) : Prop :=
  ∃ act nx, (m = { n with active := act, «next» := nx } ∨
    (rej = none ∧ index.val ≤ (lastId n.state).index.val ∧ (n.matched[p]).val < index.val ∧
      m = { n with active := act, «next» := nx, matched := n.matched.set p.val index p.isLt }))

/-- What `replicated(p, index, rejection)` does: record the reply, possibly advance
    the commit index, and queue replication (only `Replicate` descriptors are added). -/
def ReplicatedD (n : DNode V S MAX CAP) (p : Fin MAX) (index : Rust.u64) (rej : Option Rejection)
    (n' : DNode V S MAX CAP) : Prop :=
  ∃ m m', RecordedD n m p index rej ∧ Adv' m m' ∧
    n' = { m' with outbox := n'.outbox } ∧
    ∀ j : Fin MAX, n'.outbox[j] = m'.outbox[j] ∨ (n'.outbox[j] = some .Replicate ∧
      (j = p ∨ (j.val ≠ m'.local.val ∧ ∃ id, m'.peers[j] = some id)))

/-! ## `tick` -/

/-- Pre-vote requests queued for every other slot whose identity votes. -/
def preVotesD (n : DNode V S MAX CAP) (t : Rust.u64) : DNode V S MAX CAP :=
  { n with outbox := Vector.ofFn fun j => if j.val ≠ n.local.val ∧ Rust.Option.is_some_and n.peers[j] (fun id => Membership.is_voter n.membership id) = true then some (.PreVote t) else n.outbox[j] }

/-- The node after starting a pre-vote for term `t`. -/
def prevotingD (n : DNode V S MAX CAP) (t : Rust.u64) (h : n.local.val < MAX) : DNode V S MAX CAP :=
  { n with role := .Follower, prevoting := some t, votes := (Rust.Slice.fill n.votes false).set n.local.val true h }

inductive TickedD (n : DNode V S MAX CAP) : DNode V S MAX CAP → Prop
  /-- Busy: nothing changes. -/
  | same : TickedD n n
  /-- Time passes (including a term that cannot be incremented). -/
  | time (n' : DNode V S MAX CAP) : Idle n → TimeOnlyD n n' → TickedD n n'
  /-- A leader without recent quorum activity steps down. -/
  | stepdown (n0 n' : DNode V S MAX CAP) : Idle n → n.role = .Leader → TimeOnlyD n n0 →
      Timers { n0 with role := .Follower, prevoting := none, leader := none } n' → TickedD n n'
  /-- A leader's heartbeat: maybe a barrier, then replicate. -/
  | heartbeat (n0 n2 : DNode V S MAX CAP) : Idle n → n.role = .Leader → TimeOnlyD n n0 →
      BarrierD n0 n2 → TickedD n (bcastD n2)
  /-- A voter whose deadline passed starts a pre-vote for the next term, or campaigns
      at once if its own vote is a quorum. -/
  | prevote (n0 n2 n' : DNode V S MAX CAP) (h : n0.local.val < MAX) (ht : n.state.hard.term.val + 1 < 2 ^ 64) :
      Idle n → n.role ≠ .Leader → Membership.is_voter n.membership n.config.id = true → TimeOnlyD n n0 →
      Timers (prevotingD n0 ⟨n.state.hard.term.val + 1, ht⟩ h) n2 →
      ((Quorum n2.membership (fun id => votedBy n2 id = true) ∧ CampaignD n2 ⟨n.state.hard.term.val + 1, ht⟩ n') ∨
        (¬ Quorum n2.membership (fun id => votedBy n2 id = true) ∧ n' = preVotesD n2 ⟨n.state.hard.term.val + 1, ht⟩)) →
      TickedD n n'

/-! ## `step` -/

/-- Whether `last` is at least as up to date as `ours` (the grant condition). -/
def upToDateB (last ours : LogId) : Bool :=
  decide (last.term > ours.term) || (last.term == ours.term && decide (last.index ≥ ours.index))

/-- The rest of the batch after at least one accepted entry: a later rejection
    stops the loop but the response stays the last accepted index. -/
inductive BatchAfterD : DNode V S MAX CAP → LogId → List (DEntry V MAX) → Rust.u64 → Rust.u64 →
    Rust.u64 × Option Rejection → DNode V S MAX CAP → Prop
  | nil (n : DNode V S MAX CAP) (prev : LogId) (commit last : Rust.u64) : BatchAfterD n prev [] commit last (last, none) n
  | reject (n n' : DNode V S MAX CAP) (prev : LogId) (e : DEntry V MAX) (es : List (DEntry V MAX)) (commit last : Rust.u64)
      (r : Rust.u64 × Option Rejection) :
      AppendD n prev (some e) commit r n' → r.2.isSome → BatchAfterD n prev (e :: es) commit last (last, none) n'
  | accept (n n1 n' : DNode V S MAX CAP) (prev : LogId) (e : DEntry V MAX) (es : List (DEntry V MAX)) (commit last : Rust.u64)
      (r resp : Rust.u64 × Option Rejection) :
      AppendD n prev (some e) commit r n1 → r.2 = none → BatchAfterD n1 e.id es commit r.1 resp n' →
      BatchAfterD n prev (e :: es) commit last resp n'

/-- `AppendBatch`'s loop: append each entry after the previous until a rejection.
    `resp` is the last accepted index, or the first rejection when none was accepted. -/
inductive BatchD : DNode V S MAX CAP → LogId → List (DEntry V MAX) → Rust.u64 → Rust.u64 × Option Rejection →
    DNode V S MAX CAP → Prop
  | nil (n : DNode V S MAX CAP) (prev : LogId) (commit : Rust.u64) : BatchD n prev [] commit (prev.index, none) n
  | reject (n n' : DNode V S MAX CAP) (prev : LogId) (e : DEntry V MAX) (es : List (DEntry V MAX)) (commit : Rust.u64)
      (r : Rust.u64 × Option Rejection) :
      AppendD n prev (some e) commit r n' → r.2.isSome → BatchD n prev (e :: es) commit r n'
  | accept (n n1 n' : DNode V S MAX CAP) (prev : LogId) (e : DEntry V MAX) (es : List (DEntry V MAX)) (commit : Rust.u64)
      (r resp : Rust.u64 × Option Rejection) :
      AppendD n prev (some e) commit r n1 → r.2 = none → BatchAfterD n1 e.id es commit r.1 resp n' →
      BatchD n prev (e :: es) commit resp n'

inductive SteppedD (n : DNode V S MAX CAP) (a : Option (Fin MAX)) (src : Id) : DMsg V S MAX → DNode V S MAX CAP → Prop
  /-- Busy, invalid, from an unexpected identity, or an ignored vote request: at most the requester is recorded. -/
  | same (m : DMsg V S MAX) : SteppedD n a src m n
  | ignored (m : DMsg V S MAX) : Idle n → SteppedD n a src m { n with request_from := some src }
  /-- `PreVote`: answer whether a campaign for `t` would be supported; nothing else changes. -/
  | prevote (t : Rust.u64) (last : LogId) (g : Bool) : Idle n →
      SteppedD n a src (.PreVote t last) (queueD { n with request_from := some src } a src (.PreVoted t g))
  /-- `PreVoted`: count a grant for the current pre-vote, and campaign on a quorum. -/
  | prevoted (t c : Rust.u64) (g : Bool) (n1 n' : DNode V S MAX CAP) (i : Fin MAX) : Idle n → a = some i →
      ObservedD n src t n1 →
      ((¬ (n1.prevoting = some c ∧ g = true) ∧ n' = n1) ∨
        (n1.prevoting = some c ∧ g = true ∧
          let nv : DNode V S MAX CAP := { n1 with votes := n1.votes.set i.val true i.isLt }
          ((¬ Quorum nv.membership (fun id => votedBy nv id = true) ∧ n' = nv) ∨
            (Quorum nv.membership (fun id => votedBy nv id = true) ∧ CampaignD nv c n')))) →
      SteppedD n a src (.PreVoted t c g) n'
  /-- A message of an older term: optionally answer with a rejection. -/
  | stale (m : DMsg V S MAX) (n1 n' : DNode V S MAX CAP) :
      Idle n → ObservedD n src m.term n1 → m.term.val < n1.state.hard.term.val →
      (n' = n1 ∨ n' = queueD n1 a src (.Voted false) ∨ ∃ i, n' = queueD n1 a src (.Replicated i (some (.Conflict 1)))) →
      SteppedD n a src m n'
  /-- `Vote`: grant when not yet voted for another and the candidate's log is at
      least as up to date; always answer. -/
  | vote (t : Rust.u64) (last : LogId) (n1 n2 : DNode V S MAX CAP) (g : Bool) :
      Idle n → ObservedD n src t n1 → n1.state.hard.term = t →
      g = decide ((n1.state.hard.voted_for = none ∨ n1.state.hard.voted_for = some src) ∧
        upToDate last (lastId n1.state)) →
      (g = false → n2 = n1) →
      (g = true → Timers { n1 with state := { n1.state with hard := { n1.state.hard with voted_for := some src } }, dirty := (n1.dirty || decide (n1.state.hard.voted_for ≠ some src)) } n2) →
      SteppedD n a src (.Vote t last) (queueD n2 a src (.Voted g))
  /-- `Voted`: a candidate counts a grant from slot `i` and may win. -/
  | voted (t : Rust.u64) (g : Bool) (n1 n' : DNode V S MAX CAP) (i : Fin MAX) :
      Idle n → a = some i → ObservedD n src t n1 → n1.state.hard.term = t →
      ((¬ (n1.role = .Candidate ∧ g = true) ∧ n' = n1) ∨
        (n1.role = .Candidate ∧ g = true ∧
          let nv : DNode V S MAX CAP := { n1 with votes := n1.votes.set i.val true i.isLt }
          ((¬ Quorum nv.membership (fun id => votedBy nv id = true) ∧ n' = nv) ∨
            (Quorum nv.membership (fun id => votedBy nv id = true) ∧ BecomeLeaderD nv n')))) →
      SteppedD n a src (.Voted t g) n'
  /-- `Append`: follow the sender, append, and answer. -/
  | append (t : Rust.u64) (prev : LogId) (entry : Option (DEntry V MAX)) (commit : Rust.u64)
      (n1 n2 n3 : DNode V S MAX CAP) (r : Rust.u64 × Option Rejection) :
      Idle n → ObservedD n src t n1 → n1.state.hard.term = t → FollowingD n1 src n2 →
      AppendD n2 prev entry commit r n3 →
      SteppedD n a src (.Append t prev entry commit) (queueD n3 a src (.Replicated r.1 r.2))
  /-- `AppendBatch`: follow the sender, append the entries in order until one is
      rejected, and answer with the last accepted index (or the first rejection). -/
  | appendBatch (t : Rust.u64) (prev : LogId) (entries : Vector (Option (DEntry V MAX)) MAX_APPEND_ENTRIES)
      (commit : Rust.u64) (n1 n2 n3 : DNode V S MAX CAP) (resp : Rust.u64 × Option Rejection) :
      Idle n → ObservedD n src t n1 → n1.state.hard.term = t → FollowingD n1 src n2 →
      BatchD n2 prev (Rust.Iter.flatten entries.toList) commit resp n3 →
      SteppedD n a src (.AppendBatch t prev entries commit) (queueD n3 a src (.Replicated resp.1 resp.2))
  /-- `Install`: follow the sender; reject a conflict below the commit index,
      install a newer snapshot (refreshing the configuration), and answer. -/
  | install (t : Rust.u64) (snap : Snapshot (Checkpoint S MAX)) (n1 n2 n3 : DNode V S MAX CAP) (rej : Option Rejection) :
      Idle n → ObservedD n src t n1 → n1.state.hard.term = t → FollowingD n1 src n2 →
      ((snap.last.index.val ≤ n2.state.hard.commit.val ∧
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
                n3 = { n4 with snapshot_changed := true, dirty := true })))) →
      SteppedD n a src (.Install t snap) (queueD n3 a src (.Replicated snap.last.index rej))
  /-- `Replicated`: a leader records the reply from slot `i`. -/
  | replicated (t index : Rust.u64) (rej : Option Rejection) (n1 n' : DNode V S MAX CAP) (i : Fin MAX) :
      Idle n → a = some i → ObservedD n src t n1 → n1.state.hard.term = t →
      ((n1.role ≠ .Leader ∧ n' = n1) ∨ (n1.role = .Leader ∧ ReplicatedD n1 i index rej n')) →
      SteppedD n a src (.Replicated t index rej) n'

/-! ## `next_message` -/

/-- The message built from a descriptor for slot `k` (`none`: the requester without a slot). -/
inductive BuiltD (n : DNode V S MAX CAP) : Option (Fin MAX) → Outbound → DMsg V S MAX → Prop
  | vote (k : Option (Fin MAX)) : BuiltD n k .Vote (.Vote n.state.hard.term (lastId n.state))
  | voted (k : Option (Fin MAX)) (g : Bool) : BuiltD n k (.Voted g) (.Voted n.state.hard.term g)
  | replicated (k : Option (Fin MAX)) (i : Rust.u64) (r : Option Rejection) :
      BuiltD n k (.Replicated i r) (.Replicated n.state.hard.term i r)
  | prevote (k : Option (Fin MAX)) (c : Rust.u64) : BuiltD n k (.PreVote c) (.PreVote c (lastId n.state))
  | prevoted (k : Option (Fin MAX)) (c : Rust.u64) (g : Bool) :
      BuiltD n k (.PreVoted c g) (.PreVoted n.state.hard.term c g)
  | install (k : Fin MAX) (s : Snapshot (Checkpoint S MAX)) : n.next[k].val ≤ n.state.base.index.val →
      n.state.snapshot = some s → BuiltD n (some k) .Replicate (.Install n.state.hard.term s)
  | appendBatch (k : Fin MAX) (prev : LogId) (es : Vector (Option (DEntry V MAX)) MAX_APPEND_ENTRIES) :
      n.state.base.index.val < n.next[k].val → idAt n.state (n.next[k].val - 1) = some prev →
      (∀ o (ho : o < MAX_APPEND_ENTRIES), es[o] = if h : n.next[k].val + o < 2 ^ 64
        then State.get n.state ⟨n.next[k].val + o, h⟩ else none) →
      BuiltD n (some k) .Replicate (.AppendBatch n.state.hard.term prev es n.state.hard.commit)
  | append (k : Fin MAX) (prev : LogId) : n.state.base.index.val < n.next[k].val →
      idAt n.state (n.next[k].val - 1) = some prev →
      BuiltD n (some k) .Replicate (.Append n.state.hard.term prev (State.get n.state n.next[k]) n.state.hard.commit)

/-- What `next_message` does: nothing while a save is pending; otherwise take the
    first slot's descriptor, or the requester's reply, and build its message. A
    `Replicate` descriptor whose message cannot be built (no snapshot to install,
    or no predecessor identity) is dropped without sending. -/
def NextD (n : DNode V S MAX CAP) (r : Option (DEnv V S MAX)) (n' : DNode V S MAX CAP) : Prop :=
  (r = none ∧ (n' = n ∨ (n.dirty = false ∧ (∀ j : Fin MAX, n.outbox[j] = none) ∧ n' = { n with extra_reply := none }) ∨
    (n.dirty = false ∧ ∃ (k : Fin MAX) (to : Id), (∀ j : Fin MAX, j.val < k.val → n.outbox[j] = none) ∧
      n.outbox[k] = some .Replicate ∧ n.peers[k] = some to ∧ n' = { n with outbox := n.outbox.set k.val none k.isLt } ∧
      ((n.next[k].val ≤ n.state.base.index.val ∧ n.state.snapshot = none) ∨
        (n.state.base.index.val < n.next[k].val ∧ idAt n.state (n.next[k].val - 1) = none))))) ∨
  (∃ env, r = some env ∧ n.dirty = false ∧ env.from = n.config.id ∧
    ((∃ (k : Fin MAX) (o : Outbound) (to : Id), (∀ j : Fin MAX, j.val < k.val → n.outbox[j] = none) ∧
        n.outbox[k] = some o ∧ n.peers[k] = some to ∧ env.to = to ∧
        n' = { n with outbox := n.outbox.set k.val none k.isLt } ∧ BuiltD n (some k) o env.message) ∨
      (∃ (o : Outbound) (to : Id), (∀ j : Fin MAX, n.outbox[j] = none) ∧ n.extra_reply = some (to, o) ∧
        env.to = to ∧ n' = { n with extra_reply := none } ∧ BuiltD n none o env.message)))

/-! ## Proposals, compaction and reconfiguration -/

/-- The entries a leader appends for proposed values, after its last entry. -/
def proposedD (n : DNode V S MAX CAP) (vs : List (Record V MAX)) : List (DEntry V MAX) :=
  vs.zipIdx.map fun (v, i) =>
    { id := { index := Rust.ofNat ((lastId n.state).index.val + 1 + i), term := n.state.hard.term }, value := some v }

/-- What `propose_many` does: an idle leader with room appends the batch
    atomically, refreshes its configuration, matches it itself, may advance the
    commit index, and replicates; any other outcome leaves the node unchanged. -/
def ProposeD (n : DNode V S MAX CAP) (vs : List (Record V MAX)) (n' : DNode V S MAX CAP) : Prop :=
  n' = n ∨
    (Idle n ∧ n.role = .Leader ∧ 0 < vs.length ∧ (lastId n.state).index.val + vs.length < 2 ^ 64 ∧
      ∃ (s' : DState V S MAX CAP) (n1 n2 : DNode V S MAX CAP),
        ret s' = ret n.state ++ proposedD n vs ∧ s'.hard = n.state.hard ∧ s'.snapshot = n.state.snapshot ∧
        Layout s' ∧ Contig s' ∧
        Refresh { n with state := s', dirty := true, log_from := some (Rust.ofNat ((lastId n.state).index.val + 1)) } n1 ∧
        Adv' { n1 with matched := if h : n1.local.val < MAX then n1.matched.set n1.local.val (Rust.ofNat ((lastId n.state).index.val + vs.length)) h else n1.matched } n2 ∧
        n' = bcastD n2)

/-- What `compact_with(index, value)` does: an idle node compacts a committed
    retained index into a snapshot of the supplied value; a leader then may
    append a barrier and replicates. Any other outcome leaves the node unchanged. -/
def CompactD (n : DNode V S MAX CAP) (index : Rust.u64) (value : Unit → Rust.M (Checkpoint S MAX))
    (n' : DNode V S MAX CAP) : Prop :=
  n' = n ∨
    (Idle n ∧ n.state.base.index.val < index.val ∧ index.val ≤ n.state.hard.commit.val ∧
      ∃ (last : LogId) (v : Checkpoint S MAX) (s' : DState V S MAX CAP), idAt n.state index.val = some last ∧ value () = pure v ∧
        State.install n.state { last := last, value := v } = pure s' ∧
        let n1 : DNode V S MAX CAP := { n with state := s', dirty := true, snapshot_changed := true }
        ((n.role ≠ .Leader ∧ n' = n1) ∨
          (n.role = .Leader ∧ ∃ n2, BarrierD n1 n2 ∧ n' = bcastD n2)))

/-- The facts `change_available` checks: an idle leader whose latest configuration
    is stable and committed, and whose commit index is an entry of its own term. -/
def ChangeOk (n : DNode V S MAX CAP) : Prop :=
  Idle n ∧ n.role = .Leader ∧ Membership.is_joint (memAt n.state n.bootstrap (lastId n.state).index).2 = false ∧
    (memAt n.state n.bootstrap (lastId n.state).index).1 ≤ n.state.hard.commit ∧
    ((ret n.state).find? (fun e => e.id.index == n.state.hard.commit)).map (fun e => e.id.term) =
      some n.state.hard.term ∨
    (((ret n.state).find? (fun e => e.id.index == n.state.hard.commit)) = none ∧
      (n.state.snapshot.filter (fun s => s.last.index == n.state.hard.commit)).map (fun s => s.last.term) = some n.state.hard.term)

/-- A configuration has distinct identities and voters. -/
def MemOk (m : Membership MAX) : Prop :=
  Jarl.Contracts.Membership.UniqueIdentities m ∧ m.voters ≠ []

/-- What a membership operation does: nothing, or propose the configuration `X`
    from the node's own configuration `C`, where `X` is a valid step from `C`. -/
def ReconfigD (n : DNode V S MAX CAP) (n' : DNode V S MAX CAP) : Prop :=
  n' = n ∨ ∃ X, ProposeD n [Record.Configuration X] n' ∧ MemOk X ∧ Idle n ∧ n.role = .Leader ∧
    (memAt n.state n.bootstrap (lastId n.state).index).1 ≤ n.state.hard.commit ∧
    ((Membership.is_joint n.membership = false ∧
        (X = n.membership ∨ (X.voters = n.membership.voters ∧ X.is_joint = false)) ∨
        (X.is_joint = true ∧ X.old_voters.Perm n.membership.voters)) ∨
      (Membership.is_joint n.membership = true ∧ X = Membership.finalized n.membership))

/-! ## Construction -/

/-- A freshly built node: a clean follower of its own checkpoint with no pending
    messages, votes or progress, peers from its configuration. -/
def FreshD (g : Membership MAX) (me : Id) (st : DState V S MAX CAP) (n : DNode V S MAX CAP) : Prop :=
  n.state = st ∧ n.role = .Follower ∧ n.dirty = false ∧ n.hooks = some hooksC ∧ n.bootstrap = g ∧
    n.config.id = me ∧ n.extra_reply = none ∧ n.prevoting = none ∧ n.leader = none ∧
    n.membership = memOf st g ∧
    (∀ j : Fin MAX, n.outbox[j] = none ∧ n.votes[j] = false ∧ n.matched[j] = 0) ∧
    0 < n.config.heartbeat_ticks.val ∧ n.config.heartbeat_ticks.val < n.config.election_ticks.val ∧
    n.config.election_ticks.val ≤ 2 ^ 63 ∧
    (∀ i j : Fin MAX, ∀ x, n.peers[i] = some x → n.peers[j] = some x → i = j) ∧
    (∀ id, Membership.contains n.membership id = true → ∃ i : Fin MAX, n.peers[i] = some id) ∧
    n.local.val ≤ MAX ∧ (∀ i (hi : i < MAX), n.peers[i] = some me ↔ i = n.local.val)

end Jarl.Engine.Dyn
