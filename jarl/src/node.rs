use crate::{
    Config, Entry, Envelope, Error, Id, LogId, Membership, Message, PeerProgress, ProposalRange,
    Ready, Rejection, Role, Snapshot, State, Status,
};

// Application Clone implementations may unwind in a std host. Roll back a
// partially constructed local batch before that host can reuse the node.
struct BatchRollback<'a, V, S, const CAP: usize> {
    state: &'a mut State<V, S, CAP>,
    from: u64,
    finished: bool,
}
impl<V, S, const CAP: usize> Drop for BatchRollback<'_, V, S, CAP> {
    fn drop(&mut self) {
        if !self.finished {
            self.state.truncate(self.from);
        }
    }
}

#[derive(Clone, Copy, Debug)]
enum Outbound {
    PreVote(u64),
    PreVoted(u64, bool),
    Vote,
    Voted(bool),
    Replicate,
    Replicated(u64, Option<Rejection>),
}

#[derive(Debug)]
pub(crate) struct MembershipHooks<V, S, const N: usize> {
    pub record: fn(&V) -> Option<Membership<N>>,
    pub snapshot: fn(&S) -> Membership<N>,
}
impl<V, S, const N: usize> Copy for MembershipHooks<V, S, N> {}
impl<V, S, const N: usize> Clone for MembershipHooks<V, S, N> {
    fn clone(&self) -> Self {
        *self
    }
}

/// One Raft voter with bounded log and message storage.
///
/// Operations borrow their inputs so backpressure never consumes a command or
/// incoming message. Before another operation, persist pending state and drain
/// the outbox. Network delivery itself need not finish before proceeding.
#[derive(Debug)]
#[cfg_attr(test, derive(Clone))]
pub struct Node<V, S, const N: usize, const CAP: usize> {
    config: Config<N>,
    pub(crate) state: State<V, S, CAP>,
    role: Role,
    leader: Option<Id>,
    local: usize,
    pub(crate) membership: Membership<N>,
    bootstrap: Membership<N>,
    hooks: Option<MembershipHooks<V, S, N>>,
    peers: [Option<Id>; N],
    votes: [bool; N],
    next: [u64; N],
    matched: [u64; N],
    outbox: [Option<Outbound>; N],
    pub(crate) dirty: bool,
    pub(crate) log_from: Option<u64>,
    pub(crate) snapshot_changed: bool,
    elapsed: u64,
    election_deadline: u64,
    random: u64,
    prevoting: Option<u64>,
    leader_age: u64,
    quorum_elapsed: u64,
    active: [bool; N],
    extra_reply: Option<(Id, Outbound)>,
    request_from: Option<Id>,
}

impl<V: Clone, S: Clone, const N: usize, const CAP: usize> Node<V, S, N, CAP> {
    /// Start as a follower using a fresh or durably restored checkpoint.
    ///
    /// Membership and identity are an external part of the checkpoint contract;
    /// they must not change when restoring a voter.
    pub fn new(config: Config<N>, state: State<V, S, CAP>) -> Result<Self, Error> {
        let local = config.members.iter().position(|id| *id == config.id);
        if N == 0
            || CAP == 0
            || local.is_none()
            || config.heartbeat_ticks == 0
            || config.election_ticks <= config.heartbeat_ticks
            || config.election_ticks > u64::MAX / 2
            || config
                .members
                .iter()
                .enumerate()
                .any(|(i, id)| config.members[..i].contains(id))
        {
            return Err(Error::Config);
        }
        if state
            .hard
            .voted_for
            .is_some_and(|id| !config.members.contains(&id))
        {
            return Err(Error::State);
        }
        let membership = Membership::new(&config.members, &[])?;
        Self::build(config, state, membership, None)
    }

    pub(crate) fn build(
        config: Config<N>,
        state: State<V, S, CAP>,
        membership: Membership<N>,
        hooks: Option<MembershipHooks<V, S, N>>,
    ) -> Result<Self, Error> {
        if CAP == 0
            || config.heartbeat_ticks == 0
            || config.election_ticks <= config.heartbeat_ticks
            || config.election_ticks > u64::MAX / 2
        {
            return Err(Error::Config);
        }
        let random = config.seed;
        let peers = membership.peers();
        let local = peers
            .iter()
            .position(|id| *id == Some(config.id))
            .unwrap_or(N);
        let mut node = Self {
            config,
            state,
            role: Role::Follower,
            leader: None,
            local,
            membership,
            bootstrap: membership,
            hooks,
            peers,
            votes: [false; N],
            next: [1; N],
            matched: [0; N],
            outbox: core::array::from_fn(|_| None),
            dirty: false,
            log_from: None,
            snapshot_changed: false,
            elapsed: 0,
            election_deadline: 0,
            random,
            prevoting: None,
            leader_age: u64::MAX,
            quorum_elapsed: 0,
            active: [false; N],
            extra_reply: None,
            request_from: None,
        };
        node.refresh_membership();
        node.reset_election();
        Ok(node)
    }

    /// Current local role. Leadership alone does not authorize a linearizable read.
    pub fn role(&self) -> Role {
        self.role
    }

    /// Most recently observed leader; this is a routing hint, not a lease.
    pub fn leader(&self) -> Option<Id> {
        self.leader
    }

    /// Checkpoint to persist. It may contain changes not yet safe to publish.
    pub fn state(&self) -> &State<V, S, CAP> {
        &self.state
    }

    /// Move into a larger log buffer without cloning payloads,
    /// restarting, or changing protocol state. Pending writes and messages survive.
    /// `NEW` must be at least the current capacity; shrinking fails at compile time.
    ///
    /// ```compile_fail
    /// use jarl::{Config, Id, Node, State};
    /// let node = Node::<(), (), 1, 8>::new(Config::new(Id(0), [Id(0)]), State::new()).unwrap();
    /// let smaller = node.grow::<4>();
    /// ```
    #[must_use]
    pub fn grow<const NEW: usize>(self) -> Node<V, S, N, NEW> {
        Node {
            state: self.state.grow(),
            config: self.config,
            role: self.role,
            leader: self.leader,
            local: self.local,
            membership: self.membership,
            bootstrap: self.bootstrap,
            hooks: self.hooks,
            peers: self.peers,
            votes: self.votes,
            next: self.next,
            matched: self.matched,
            outbox: self.outbox,
            dirty: self.dirty,
            log_from: self.log_from,
            snapshot_changed: self.snapshot_changed,
            elapsed: self.elapsed,
            election_deadline: self.election_deadline,
            random: self.random,
            prevoting: self.prevoting,
            leader_age: self.leader_age,
            quorum_elapsed: self.quorum_elapsed,
            active: self.active,
            extra_reply: self.extra_reply,
            request_from: self.request_from,
        }
    }

    /// Borrow a pending storage transaction, if any. Dropping the token does not
    /// acknowledge persistence. No new input can be accepted until it is saved.
    pub fn ready(&mut self) -> Option<Ready<'_, V, S, N, CAP>> {
        self.dirty.then_some(Ready { node: self })
    }

    /// Take one outgoing message, borrowing its payloads without cloning them.
    /// Returns `None` while persistence is pending. Encode before dropping it,
    /// or use [`Envelope::cloned`] to enqueue an owned copy.
    pub fn next_message(&mut self) -> Option<Envelope<&V, &S>> {
        if self.dirty {
            return None;
        }
        let (peer, to, outbound) = if let Some(peer) = self.outbox.iter().position(Option::is_some)
        {
            (peer, self.peers[peer]?, self.outbox[peer].take()?)
        } else {
            let (to, outbound) = self.extra_reply.take()?;
            (N, to, outbound)
        };
        let term = self.state.hard.term;
        let message = match outbound {
            Outbound::PreVote(campaign) => Message::PreVote {
                term: campaign,
                last: self.state.last(),
            },
            Outbound::PreVoted(campaign, granted) => Message::PreVoted {
                term,
                campaign,
                granted,
            },
            Outbound::Vote => Message::Vote {
                term,
                last: self.state.last(),
            },
            Outbound::Voted(granted) => Message::Voted { term, granted },
            Outbound::Replicated(index, rejection) => Message::Replicated {
                term,
                index,
                rejection,
            },
            Outbound::Replicate if self.next[peer] <= self.state.base().index => {
                let snapshot = self.state.snapshot.as_ref()?;
                Message::Install {
                    term,
                    snapshot: Snapshot {
                        last: snapshot.last,
                        value: &snapshot.value,
                    },
                }
            }
            Outbound::Replicate
                if self.hooks.is_some()
                    && self.next[peer]
                        .checked_add(1)
                        .and_then(|index| self.state.get(index))
                        .is_some() =>
            {
                Message::AppendBatch {
                    term,
                    previous: self.state.id_at(self.next[peer] - 1)?,
                    entries: core::array::from_fn(|offset| {
                        self.next[peer]
                            .checked_add(offset as u64)
                            .and_then(|index| self.state.get(index))
                            .map(|e| Entry {
                                id: e.id,
                                value: e.value.as_ref(),
                            })
                    }),
                    commit: self.state.hard.commit,
                }
            }
            Outbound::Replicate => Message::Append {
                term,
                previous: self.state.id_at(self.next[peer] - 1)?,
                entry: self.state.get(self.next[peer]).map(|e| Entry {
                    id: e.id,
                    value: e.value.as_ref(),
                }),
                commit: self.state.hard.commit,
            },
        };
        Some(Envelope {
            from: self.config.id,
            to,
            message,
        })
    }

    /// Durable committed entries still retained after the snapshot.
    ///
    /// Track the last applied index in the application; repeated calls include
    /// already applied entries. Internal barriers (`value == None`) also advance
    /// that index. No entries are exposed while persistence is pending.
    pub fn committed(&self) -> impl Iterator<Item = &Entry<V>> {
        self.state
            .entries()
            .take_while(|entry| !self.dirty && entry.id.index <= self.state.hard.commit)
    }

    /// Durable application snapshot. Install it before applying its retained suffix.
    pub fn snapshot(&self) -> Option<&Snapshot<S>> {
        self.state.snapshot().filter(|_| !self.dirty)
    }

    /// Advance one unit of local monotonic time.
    pub fn tick(&mut self) -> Result<(), Error> {
        self.available()?;
        self.elapsed = self.elapsed.saturating_add(1);
        self.leader_age = self.leader_age.saturating_add(1);
        if self.hooks.is_some() && self.role == Role::Leader {
            self.quorum_elapsed = self.quorum_elapsed.saturating_add(1);
            if self.quorum_elapsed >= self.config.election_ticks {
                let quorum = self.membership.quorum(|id| {
                    id == self.config.id
                        || self
                            .peers
                            .iter()
                            .position(|peer| *peer == Some(id))
                            .is_some_and(|i| self.active[i])
                });
                self.quorum_elapsed = 0;
                self.active.fill(false);
                if !quorum {
                    self.follow(None);
                    return Ok(());
                }
            }
        }
        if self.role == Role::Leader {
            if self.elapsed >= self.config.heartbeat_ticks {
                self.elapsed = 0;
                self.barrier();
                self.broadcast();
            }
        } else if self.membership.is_voter(self.config.id) && self.elapsed >= self.election_deadline
        {
            let term = self
                .state
                .hard
                .term
                .checked_add(1)
                .ok_or(Error::Exhausted)?;
            if self.hooks.is_some() {
                self.prevoting = Some(term);
                self.votes.fill(false);
                self.votes[self.local] = true;
                self.reset_election();
                if self.election_quorum() {
                    self.campaign(term);
                } else {
                    for peer in 0..N {
                        if peer != self.local
                            && self.peers[peer].is_some_and(|id| self.membership.is_voter(id))
                        {
                            self.send(peer, Outbound::PreVote(term));
                        }
                    }
                }
            } else {
                self.campaign(term);
            }
        }
        Ok(())
    }

    /// Process one authenticated message addressed to this node.
    ///
    /// Unknown peers and structurally invalid messages are rejected without
    /// mutation. Stale messages are safe to duplicate, reorder, or drop.
    pub fn step(&mut self, envelope: &Envelope<V, S>) -> Result<(), Error> {
        self.available()?;
        let peer = self
            .peers
            .iter()
            .position(|id| *id == Some(envelope.from))
            .or_else(|| {
                (self.hooks.is_some()
                    && matches!(
                        envelope.message,
                        Message::Vote { .. }
                            | Message::PreVote { .. }
                            | Message::Append { .. }
                            | Message::AppendBatch { .. }
                            | Message::Install { .. }
                    ))
                .then_some(N)
            })
            .ok_or(Error::Message)?;
        if envelope.from == self.config.id
            || envelope.to != self.config.id
            || !Self::valid(&envelope.message)
        {
            return Err(Error::Message);
        }
        self.request_from = Some(envelope.from);
        if let Message::PreVote { term, last } = &envelope.message {
            let ours = self.state.last();
            let granted = *term > self.state.hard.term
                && self.role != Role::Leader
                && self.leader_age >= self.config.election_ticks
                && (last.term, last.index) >= (ours.term, ours.index);
            self.send(peer, Outbound::PreVoted(*term, granted));
            return Ok(());
        }
        // A recently heard leader suppresses disruptive campaigns, including
        // requests from a removed voter that has not learned its removal.
        if self.hooks.is_some()
            && matches!(envelope.message, Message::Vote { .. })
            && (self.role == Role::Leader || self.leader_age < self.config.election_ticks)
        {
            return Ok(());
        }
        let term = envelope.message.term();
        if term > self.state.hard.term {
            self.state.hard.term = term;
            self.state.hard.voted_for = None;
            self.dirty = true;
            self.follow(None);
        }
        if let Message::PreVoted {
            campaign, granted, ..
        } = envelope.message
        {
            if self.prevoting == Some(campaign) && granted {
                self.votes[peer] = true;
                if self.election_quorum() {
                    self.campaign(campaign);
                }
            }
            return Ok(());
        }
        if term < self.state.hard.term {
            match &envelope.message {
                Message::Vote { .. } => self.send(peer, Outbound::Voted(false)),
                Message::Append { previous, .. } | Message::AppendBatch { previous, .. } => {
                    self.reply(peer, previous.index, Some(Rejection::Conflict { next: 1 }));
                }
                Message::Install { snapshot, .. } => {
                    self.reply(
                        peer,
                        snapshot.last.index,
                        Some(Rejection::Conflict { next: 1 }),
                    );
                }
                _ => {}
            }
            return Ok(());
        }
        match &envelope.message {
            Message::PreVote { .. } | Message::PreVoted { .. } => {
                unreachable!("election probes handled before ordinary term processing")
            }
            Message::Vote { last, .. } => {
                let ours = self.state.last();
                let granted = self
                    .state
                    .hard
                    .voted_for
                    .is_none_or(|id| id == envelope.from)
                    && (last.term, last.index) >= (ours.term, ours.index);
                if granted {
                    if self.state.hard.voted_for != Some(envelope.from) {
                        self.state.hard.voted_for = Some(envelope.from);
                        self.dirty = true;
                    }
                    self.reset_election();
                }
                self.send(peer, Outbound::Voted(granted));
            }
            Message::Voted { granted, .. } => {
                if self.role == Role::Candidate && *granted {
                    self.votes[peer] = true;
                    if self.election_quorum() {
                        self.become_leader();
                    }
                }
            }
            Message::Append {
                previous,
                entry,
                commit,
                ..
            } => {
                self.follow(Some(envelope.from));
                let (index, rejection) = self.append(*previous, entry.as_ref(), *commit);
                self.reply(peer, index, rejection);
            }
            Message::AppendBatch {
                previous,
                entries,
                commit,
                ..
            } => {
                self.follow(Some(envelope.from));
                let mut previous = *previous;
                let mut accepted = false;
                let mut response = (previous.index, None);
                for entry in entries.iter().flatten() {
                    let (index, rejection) = self.append(previous, Some(entry), *commit);
                    if rejection.is_some() {
                        if !accepted {
                            response = (index, rejection);
                        }
                        break;
                    }
                    previous = entry.id;
                    accepted = true;
                    response = (index, None);
                }
                self.reply(peer, response.0, response.1);
            }
            Message::Install { snapshot, .. } => {
                self.follow(Some(envelope.from));
                if snapshot.last.index <= self.state.hard.commit
                    && self
                        .state
                        .id_at(snapshot.last.index)
                        .is_some_and(|id| id != snapshot.last)
                {
                    self.reply(
                        peer,
                        snapshot.last.index,
                        Some(Rejection::Conflict {
                            next: self.state.base().index.saturating_add(1),
                        }),
                    );
                    return Ok(());
                }
                // An old snapshot may still compact a matching committed prefix.
                // It must never replace a conflicting already committed history.
                if snapshot.last.index > self.state.base().index
                    && (snapshot.last.index > self.state.hard.commit
                        || self.state.id_at(snapshot.last.index) == Some(snapshot.last))
                {
                    if self.state.id_at(snapshot.last.index) != Some(snapshot.last) {
                        self.log_from = snapshot.last.index.checked_add(1);
                    }
                    self.state.install(snapshot.clone());
                    self.refresh_membership();
                    self.snapshot_changed = true;
                    self.dirty = true;
                }
                self.reply(peer, snapshot.last.index, None);
            }
            Message::Replicated {
                index, rejection, ..
            } => {
                if self.role == Role::Leader {
                    self.replicated(peer, *index, *rejection);
                }
            }
        }
        Ok(())
    }

    /// Append a command locally and return its identity. This is not a commit ACK.
    ///
    /// Confirm the same identity in [`Self::committed`] before acknowledging the
    /// application. A later leader may replace an uncommitted proposal.
    pub fn propose(&mut self, value: &V) -> Result<LogId, Error> {
        Ok(self
            .propose_many(1, core::iter::once_with(|| value.clone()))?
            .first)
    }

    /// Admit a nonempty batch as one durable transaction. Capacity and index
    /// bounds are checked before mutation; messages still replicate one entry.
    pub fn propose_batch(&mut self, values: &[V]) -> Result<ProposalRange, Error> {
        self.propose_many(values.len(), values.iter().cloned())
    }

    pub(crate) fn propose_many(
        &mut self,
        count: usize,
        values: impl Iterator<Item = V>,
    ) -> Result<ProposalRange, Error> {
        self.available()?;
        if self.role != Role::Leader {
            return Err(Error::NotLeader(self.leader));
        }
        if count == 0 {
            return Err(Error::Config);
        }
        if count > CAP - self.state.entries().count() {
            return Err(Error::Full);
        }
        let last_index = self
            .state
            .last()
            .index
            .checked_add(u64::try_from(count).map_err(|_| Error::Exhausted)?)
            .ok_or(Error::Exhausted)?;
        let first = LogId {
            index: self.state.last().index + 1,
            term: self.state.hard.term,
        };
        let mut rollback = BatchRollback {
            state: &mut self.state,
            from: first.index,
            finished: false,
        };
        for (offset, value) in values.enumerate() {
            rollback.state.push(Entry {
                id: LogId {
                    index: first.index + offset as u64,
                    term: first.term,
                },
                value: Some(value),
            })?;
        }
        rollback.finished = true;
        drop(rollback);
        let last = LogId {
            index: last_index,
            term: first.term,
        };
        self.dirty = true;
        self.log_from = Some(first.index);
        self.refresh_membership();
        if self.local < N {
            self.matched[self.local] = last.index;
        }
        self.advance_commit();
        self.broadcast();
        Ok(ProposalRange { first, last })
    }

    /// Local scheduling, durability, and capacity diagnostics.
    pub fn status(&self) -> Status {
        Status {
            id: self.config.id,
            role: self.role,
            term: self.state.hard.term,
            last: self.state.last(),
            commit: self.state.hard.commit,
            retained: self.state.entries().count(),
            capacity: CAP,
            persistence_pending: self.dirty,
            messages_pending: self.outbox.iter().flatten().count()
                + usize::from(self.extra_reply.is_some()),
        }
    }

    /// Current replication positions; meaningful only while this node is leader.
    pub fn progress(&self) -> impl Iterator<Item = PeerProgress> + '_ {
        self.peers.iter().enumerate().filter_map(|(i, peer)| {
            let id = (*peer)?;
            (self.role == Role::Leader && self.membership.contains(id) && id != self.config.id)
                .then_some(PeerProgress {
                    id,
                    voter: self.membership.is_voter(id),
                    matched: self.matched[i],
                    next: self.next[i],
                })
        })
    }

    /// Replace an applied, committed prefix with its application snapshot.
    ///
    /// The caller must supply the exact state after applying through `index`.
    /// Persistence of this checkpoint must finish before old log storage is removed.
    pub fn compact(&mut self, index: u64, value: &S) -> Result<(), Error> {
        self.compact_with(index, || value.clone())
    }

    pub(crate) fn compact_with(
        &mut self,
        index: u64,
        value: impl FnOnce() -> S,
    ) -> Result<(), Error> {
        self.available()?;
        if index <= self.state.base().index || index > self.state.hard.commit {
            return Err(Error::NotCommitted);
        }
        let last = self.state.id_at(index).ok_or(Error::NotCommitted)?;
        self.state.install(Snapshot {
            last,
            value: value(),
        });
        self.dirty = true;
        self.snapshot_changed = true;
        if self.role == Role::Leader {
            self.barrier();
            self.broadcast();
        }
        Ok(())
    }

    fn available(&self) -> Result<(), Error> {
        if self.dirty || self.extra_reply.is_some() || self.outbox.iter().any(Option::is_some) {
            Err(Error::Busy)
        } else {
            Ok(())
        }
    }

    fn valid(message: &Message<V, S>) -> bool {
        if let Message::PreVoted { campaign, .. } = message {
            return *campaign > 0;
        }
        let term = message.term();
        let valid_id = |id: LogId| {
            (id == LogId::default()) || (id.index > 0 && id.term > 0 && id.term <= term)
        };
        term > 0
            && match message {
                Message::Vote { last, .. } | Message::PreVote { last, .. } => valid_id(*last),
                Message::Append {
                    previous, entry, ..
                } => {
                    valid_id(*previous)
                        && entry.as_ref().is_none_or(|entry| {
                            valid_id(entry.id)
                                && previous.index.checked_add(1) == Some(entry.id.index)
                                && entry.id.term >= previous.term
                        })
                }
                Message::AppendBatch {
                    previous, entries, ..
                } => {
                    let mut previous = *previous;
                    let mut ended = false;
                    let mut count = 0;
                    if !valid_id(previous) {
                        return false;
                    }
                    for entry in entries {
                        if let Some(entry) = entry {
                            if ended
                                || !valid_id(entry.id)
                                || previous.index.checked_add(1) != Some(entry.id.index)
                                || entry.id.term < previous.term
                            {
                                return false;
                            }
                            previous = entry.id;
                            count += 1;
                        } else {
                            ended = true;
                        }
                    }
                    count > 0
                }
                Message::Install { snapshot, .. } => {
                    snapshot.last.index > 0 && valid_id(snapshot.last)
                }
                Message::Replicated {
                    rejection: Some(Rejection::Conflict { next }),
                    ..
                } => *next > 0,
                _ => true,
            }
    }

    fn reset_election(&mut self) {
        // SplitMix64: reproducible jitter, including for a zero seed.
        self.random = self.random.wrapping_add(0x9e3779b97f4a7c15);
        let mut sample = self.random;
        sample = (sample ^ (sample >> 30)).wrapping_mul(0xbf58476d1ce4e5b9);
        sample = (sample ^ (sample >> 27)).wrapping_mul(0x94d049bb133111eb);
        sample ^= sample >> 31;
        self.election_deadline = self.config.election_ticks + sample % self.config.election_ticks;
        self.elapsed = 0;
    }

    fn follow(&mut self, leader: Option<Id>) {
        self.role = Role::Follower;
        self.prevoting = None;
        if leader.is_some() {
            self.leader_age = 0;
        }
        self.leader = leader;
        self.reset_election();
    }

    fn election_quorum(&self) -> bool {
        self.membership.quorum(|id| {
            self.peers
                .iter()
                .position(|peer| *peer == Some(id))
                .is_some_and(|i| self.votes[i])
        })
    }

    pub(crate) fn membership_at(&self, index: u64) -> (u64, Membership<N>) {
        let Some(hooks) = self.hooks else {
            return (0, self.bootstrap);
        };
        let mut result = self.state.snapshot().map_or((0, self.bootstrap), |s| {
            (s.last.index, (hooks.snapshot)(&s.value))
        });
        for entry in self.state.entries().take_while(|e| e.id.index <= index) {
            if let Some(membership) = entry.value.as_ref().and_then(hooks.record) {
                result = (entry.id.index, membership);
            }
        }
        result
    }

    fn refresh_membership(&mut self) {
        self.membership = self.membership_at(self.state.last().index).1;
        for id in self.membership.peers().iter().flatten() {
            if !self.peers.contains(&Some(*id)) {
                let slot = self
                    .peers
                    .iter()
                    .position(|peer| peer.is_none_or(|id| !self.membership.contains(id)))
                    .expect("membership fits peer capacity");
                self.peers[slot] = Some(*id);
                self.votes[slot] = false;
                self.active[slot] = false;
                self.next[slot] = 1;
                self.matched[slot] = 0;
                self.outbox[slot] = None;
            }
        }
        self.local = self
            .peers
            .iter()
            .position(|id| *id == Some(self.config.id))
            .unwrap_or(N);
        if self.role == Role::Leader && !self.membership.is_voter(self.config.id) {
            let (index, _) = self.membership_at(self.state.last().index);
            if index <= self.state.hard.commit {
                self.follow(None);
            }
        }
    }

    pub(crate) fn matched(&self, id: Id) -> u64 {
        self.peers
            .iter()
            .position(|peer| *peer == Some(id))
            .map_or(0, |i| self.matched[i])
    }

    pub(crate) fn idle(&self) -> Result<(), Error> {
        self.available()
    }

    fn campaign(&mut self, term: u64) {
        self.prevoting = None;
        self.state.hard.term = term;
        self.state.hard.voted_for = Some(self.config.id);
        self.dirty = true;
        self.role = Role::Candidate;
        self.leader = None;
        self.votes.fill(false);
        self.votes[self.local] = true;
        self.reset_election();
        if self.election_quorum() {
            self.become_leader();
        } else {
            for peer in 0..N {
                if peer != self.local
                    && self.peers[peer].is_some_and(|id| self.membership.is_voter(id))
                {
                    self.send(peer, Outbound::Vote);
                }
            }
        }
    }

    fn become_leader(&mut self) {
        self.quorum_elapsed = 0;
        self.active.fill(false);
        self.role = Role::Leader;
        self.leader = Some(self.config.id);
        self.elapsed = 0;
        self.next.fill(self.state.last().index.saturating_add(1));
        self.matched.fill(0);
        if self.local < N {
            self.matched[self.local] = self.state.last().index;
        }
        self.barrier();
        self.broadcast();
    }

    fn barrier(&mut self) {
        if self.state.last().term == self.state.hard.term || self.state.full() {
            return;
        }
        let Some(index) = self.state.last().index.checked_add(1) else {
            return;
        };
        let id = LogId {
            index,
            term: self.state.hard.term,
        };
        // Capacity was checked above; application values are not constructed.
        if self.state.push(Entry { id, value: None }).is_ok() {
            self.dirty = true;
            self.log_from = Some(index);
            if self.local < N {
                self.matched[self.local] = index;
            }
            self.advance_commit();
        }
    }

    fn append(
        &mut self,
        previous: LogId,
        entry: Option<&Entry<V>>,
        commit: u64,
    ) -> (u64, Option<Rejection>) {
        if self.state.id_at(previous.index) != Some(previous) {
            let next = if previous.index < self.state.base().index {
                self.state.base().index.saturating_add(1)
            } else {
                previous
                    .index
                    .min(self.state.last().index.saturating_add(1))
                    .max(1)
            };
            return (previous.index, Some(Rejection::Conflict { next }));
        }
        let mut matched = previous.index;
        if let Some(entry) = entry {
            if self.state.id_at(entry.id.index) != Some(entry.id) {
                if entry.id.index <= self.state.hard.commit {
                    return (
                        previous.index,
                        Some(Rejection::Conflict {
                            next: entry.id.index,
                        }),
                    );
                }
                // Replacing a suffix frees a slot even when the log is full.
                if self.state.full() && entry.id.index > self.state.last().index {
                    self.commit_to(commit.min(matched));
                    return (previous.index, Some(Rejection::Full));
                }
                let cloned = entry.clone();
                self.state.truncate(entry.id.index);
                if self.state.push(cloned).is_err() {
                    // Unreachable with the capacity check, but never panic on replication.
                    return (previous.index, Some(Rejection::Full));
                }
                self.refresh_membership();
                self.dirty = true;
                self.log_from = Some(
                    self.log_from
                        .map_or(entry.id.index, |from| from.min(entry.id.index)),
                );
            }
            matched = entry.id.index;
        }
        self.commit_to(commit.min(matched));
        (matched, None)
    }

    fn replicated(&mut self, peer: usize, index: u64, rejection: Option<Rejection>) {
        self.active[peer] = true;
        if index > self.state.last().index {
            return;
        }
        match rejection {
            None => {
                if index <= self.matched[peer] {
                    return;
                }
                self.matched[peer] = index;
                self.next[peer] = self.next[peer].max(index.saturating_add(1));
                if self.advance_commit() {
                    self.broadcast();
                } else if index < self.state.last().index {
                    self.replicate(peer);
                }
            }
            Some(Rejection::Conflict { next }) => {
                // Ignore delayed rejection of a prefix already acknowledged, or of
                // a request superseded by a different retry position.
                if index >= self.matched[peer] && index.checked_add(1) == Some(self.next[peer]) {
                    self.next[peer] = next.clamp(
                        self.matched[peer].saturating_add(1),
                        self.state.last().index.saturating_add(1),
                    );
                    self.replicate(peer);
                }
            }
            Some(Rejection::Full) => {} // Retry on heartbeat after the follower compacts.
        }
    }

    fn advance_commit(&mut self) -> bool {
        let index = self.membership.quorum_index(|id| self.matched(id));
        if index > self.state.hard.commit
            && self
                .state
                .id_at(index)
                .is_some_and(|id| id.term == self.state.hard.term)
        {
            self.commit_to(index);
            true
        } else {
            false
        }
    }

    fn commit_to(&mut self, index: u64) {
        if index > self.state.hard.commit {
            self.state.hard.commit = index;
            self.dirty = true;
            self.refresh_membership();
        }
    }

    fn send(&mut self, peer: usize, outbound: Outbound) {
        if peer == N {
            if let Some(from) = self.request_from {
                self.extra_reply = Some((from, outbound));
            }
        } else {
            self.outbox[peer] = Some(outbound);
        }
    }

    fn reply(&mut self, peer: usize, index: u64, rejection: Option<Rejection>) {
        self.send(peer, Outbound::Replicated(index, rejection));
    }

    fn broadcast(&mut self) {
        for peer in 0..N {
            if peer != self.local && self.peers[peer].is_some_and(|id| self.membership.contains(id))
            {
                self.replicate(peer);
            }
        }
    }

    fn replicate(&mut self, peer: usize) {
        self.send(peer, Outbound::Replicate);
    }
}
