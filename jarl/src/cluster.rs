use crate::{
    node::MembershipHooks, Config, Entry, Envelope, Error, Id, LogId, Membership, Node, Ready,
    Role, Snapshot, State,
};

/// A replicated application command or protocol-owned configuration record.
/// Hosts must preserve both variants in durable storage and transport encoding.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Record<V, const MAX: usize> {
    /// Application input.
    Command(V),
    /// Effective membership, including intermediate joint configurations.
    Configuration(Membership<MAX>),
}

/// Snapshot contents including the configuration at the included log position.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Checkpoint<S, const MAX: usize> {
    /// Application state through the snapshot boundary.
    pub application: S,
    /// Membership at that same boundary, possibly joint.
    pub membership: Membership<MAX>,
}

/// Local timer configuration; membership is persisted separately.
#[derive(Clone, Copy, Debug)]
pub struct Settings {
    /// Ticks between heartbeats; positive.
    pub heartbeat_ticks: u64,
    /// Minimum election timeout; greater than the heartbeat interval.
    pub election_ticks: u64,
    /// Independent election jitter seed. Use fresh entropy on process restart.
    pub seed: u64,
}
impl Default for Settings {
    fn default() -> Self {
        Self {
            heartbeat_ticks: 2,
            election_ticks: 10,
            seed: 1,
        }
    }
}

/// Durable identity, genesis configuration, and Raft checkpoint.
///
/// Persist `id` and `genesis` once before starting a fresh node. Subsequently
/// save the transactions from [`Cluster::ready`]. Restarts must use the same
/// identity and genesis, even after reconfiguration. Bind the storage and
/// authenticated transport to a unique cluster namespace in the host.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ClusterState<V, S, const MAX: usize, const CAP: usize> {
    id: Id,
    genesis: Membership<MAX>,
    state: State<Record<V, MAX>, Checkpoint<S, MAX>, CAP>,
}
impl<V, S, const MAX: usize, const CAP: usize> ClusterState<V, S, MAX, CAP> {
    /// Fresh voter or passive joiner. Never substitute this for lost voter state.
    /// A joiner uses the cluster's original genesis and a previously unused ID.
    pub fn new(id: Id, genesis: Membership<MAX>) -> Result<Self, Error> {
        Self::restore(id, genesis, State::new())
    }
    /// Reconstruct from the immutable storage header and recovered transactions.
    pub fn restore(
        id: Id,
        genesis: Membership<MAX>,
        state: State<Record<V, MAX>, Checkpoint<S, MAX>, CAP>,
    ) -> Result<Self, Error> {
        if genesis.is_joint() {
            return Err(Error::Config);
        }
        Ok(Self { id, genesis, state })
    }
    /// Immutable voter identity.
    pub fn id(&self) -> Id {
        self.id
    }
    /// Immutable initial cluster configuration.
    pub fn genesis(&self) -> Membership<MAX> {
        self.genesis
    }
    /// Recovered Raft state.
    pub fn state(&self) -> &State<Record<V, MAX>, Checkpoint<S, MAX>, CAP> {
        &self.state
    }
}

/// Allocation-free Raft with runtime voters, learners, and joint consensus.
///
/// `MAX` bounds simultaneous peers, not the lifetime set of identities. `CAP`
/// bounds retained entries. The same `tick/step/ready/next_message` interface
/// works with synchronous I/O and async hosts; no executor or I/O is required.
/// Configuration records become effective when appended, before commitment.
/// Only one membership change may be outstanding at a time.
#[derive(Debug)]
#[cfg_attr(test, derive(Clone))]
pub struct Cluster<V, S, const MAX: usize, const CAP: usize> {
    pub(crate) node: Node<Record<V, MAX>, Checkpoint<S, MAX>, MAX, CAP>,
}

impl<V: Clone, S: Clone, const MAX: usize, const CAP: usize> Cluster<V, S, MAX, CAP> {
    /// Start or recover a node. An identity outside the configuration is passive.
    pub fn new(settings: Settings, saved: ClusterState<V, S, MAX, CAP>) -> Result<Self, Error> {
        if CAP < 4 {
            return Err(Error::Config);
        }
        let config = Config {
            id: saved.id,
            // The private dynamic constructor uses the persisted membership.
            members: [saved.id; MAX],
            heartbeat_ticks: settings.heartbeat_ticks,
            election_ticks: settings.election_ticks,
            seed: settings.seed,
        };
        let hooks = MembershipHooks {
            record: |record| match record {
                Record::Configuration(m) => Some(*m),
                _ => None,
            },
            snapshot: |snapshot: &Checkpoint<S, MAX>| snapshot.membership,
        };
        Ok(Self {
            node: Node::build(config, saved.state, saved.genesis, Some(hooks))?,
        })
    }
    /// Advance one local tick. Drain pending work between operations.
    pub fn tick(&mut self) -> Result<(), Error> {
        self.node.tick()
    }
    /// Process an authenticated message from this cluster's namespace.
    pub fn step(
        &mut self,
        message: &Envelope<Record<V, MAX>, Checkpoint<S, MAX>>,
    ) -> Result<(), Error> {
        self.node.step(message)
    }
    /// Pending atomic durable transaction. Can be held across an async save.
    pub fn ready(&mut self) -> Option<Ready<'_, Record<V, MAX>, Checkpoint<S, MAX>, MAX, CAP>> {
        self.node.ready()
    }
    /// Next borrowed outgoing message, available after required persistence.
    pub fn next_message(&mut self) -> Option<Envelope<&Record<V, MAX>, &Checkpoint<S, MAX>>> {
        self.node.next_message()
    }
    /// Local role; never a read lease.
    pub fn role(&self) -> Role {
        self.node.role()
    }
    /// Routing hint, not proof of an available quorum.
    pub fn leader(&self) -> Option<Id> {
        self.node.leader()
    }
    /// Latest effective configuration, possibly not yet durable or committed.
    pub fn membership(&self) -> Membership<MAX> {
        self.node.membership
    }
    /// Configuration at the committed position. May be awaiting persistence.
    pub fn committed_membership(&self) -> Membership<MAX> {
        self.node.membership_at(self.node.state().hard().commit).1
    }
    /// Complete Raft checkpoint. Save through `ready`, not this diagnostic view.
    pub fn state(&self) -> &State<Record<V, MAX>, Checkpoint<S, MAX>, CAP> {
        self.node.state()
    }
    /// Durable committed records. Advance the application cursor for every entry;
    /// only `Record::Command` changes application state.
    pub fn committed(&self) -> impl Iterator<Item = &Entry<Record<V, MAX>>> {
        self.node.committed()
    }
    /// Durable snapshot, to install before applying the retained committed suffix.
    pub fn snapshot(&self) -> Option<&Snapshot<Checkpoint<S, MAX>>> {
        self.node.snapshot()
    }
    /// Propose an application command, reserving three slots for protocol work.
    /// The reserve reduces pressure; repeated failed elections can still exhaust
    /// it. Monitor capacity, compact applied entries, or explicitly grow storage.
    pub fn propose(&mut self, command: &V) -> Result<LogId, Error> {
        self.node.idle()?;
        if self.node.role() != Role::Leader {
            return Err(Error::NotLeader(self.node.leader()));
        }
        if self.remaining() <= 3 {
            return Err(Error::Full);
        }
        Ok(self
            .node
            .propose_many(
                1,
                core::iter::once_with(|| Record::Command(command.clone())),
            )?
            .first)
    }
    /// Admit a nonempty application batch with one persistence transaction,
    /// preserving the three-slot protocol reserve. Failure admits no commands.
    pub fn propose_batch(&mut self, commands: &[V]) -> Result<crate::ProposalRange, Error> {
        self.node.idle()?;
        if self.role() != Role::Leader {
            return Err(Error::NotLeader(self.leader()));
        }
        if commands.len() > self.remaining().saturating_sub(3) {
            return Err(Error::Full);
        }
        self.node.propose_many(
            commands.len(),
            commands.iter().cloned().map(Record::Command),
        )
    }
    /// Scheduling, durability, and capacity diagnostics; never a read lease.
    pub fn status(&self) -> crate::Status {
        self.node.status()
    }
    /// Per-peer replication positions while leader.
    pub fn progress(&self) -> impl Iterator<Item = crate::PeerProgress> + '_ {
        self.node.progress()
    }
    /// Number of unused retained-log slots, including the protocol reserve.
    pub fn remaining(&self) -> usize {
        CAP - self.node.state().entries().count()
    }
    /// Last index acknowledged by a peer in this leader term; zero if unknown.
    pub fn matched(&self, id: Id) -> u64 {
        self.node.matched(id)
    }

    fn change_available(&self) -> Result<(), Error> {
        self.node.idle()?;
        if self.role() != Role::Leader {
            return Err(Error::NotLeader(self.leader()));
        }
        let (index, membership) = self.node.membership_at(self.state().last().index);
        let hard = self.state().hard();
        if membership.is_joint()
            || index > hard.commit
            || self.node.membership_at(hard.commit).1 != membership
        {
            return Err(Error::Reconfiguring);
        }
        // Establish leadership in this term before making configuration decisions.
        let committed_term = self
            .state()
            .entries()
            .find(|e| e.id.index == hard.commit)
            .map(|e| e.id.term)
            .or_else(|| {
                self.state()
                    .snapshot()
                    .filter(|s| s.last.index == hard.commit)
                    .map(|s| s.last.term)
            });
        if committed_term != Some(hard.term) {
            return Err(Error::Reconfiguring);
        }
        Ok(())
    }

    /// Replace the learner set without changing voters. New identities begin
    /// replication immediately; wait for this record to commit before promotion.
    pub fn set_learners(&mut self, learners: &[Id]) -> Result<LogId, Error> {
        self.change_available()?;
        let current = self.membership();
        if current.voters().count() + learners.len() > MAX {
            return Err(Error::Full);
        }
        let next = current.with_learners(learners)?;
        if self.remaining() <= 2 {
            return Err(Error::Full);
        }
        self.node.propose(&Record::Configuration(next))
    }

    /// Begin joint consensus with a stable target configuration. Each newly
    /// promoted voter must already be a learner caught up through the current
    /// last log entry. The old/new union must fit `MAX`. Poll `membership` and
    /// call `finish_reconfiguration` after the joint record commits.
    pub fn reconfigure(&mut self, target: Membership<MAX>) -> Result<LogId, Error> {
        self.change_available()?;
        if target.is_joint() {
            return Err(Error::Config);
        }
        let current = self.membership();
        for id in target.voters().filter(|id| !current.is_voter(*id)) {
            if !current.learners().any(|learner| learner == id)
                || self.matched(id) < self.state().last().index
            {
                return Err(Error::NotCaughtUp);
            }
        }
        if self.remaining() < 3 {
            return Err(Error::Full);
        }
        self.node
            .propose(&Record::Configuration(current.joint(target)?))
    }

    /// Append the final stable configuration after joint consensus is committed.
    /// Safe to retry on a new leader after a crash. A removed leader steps down
    /// when the final configuration commits. Wait for that final commitment before
    /// acknowledging the membership operation to an administrator.
    pub fn finish_reconfiguration(&mut self) -> Result<LogId, Error> {
        self.node.idle()?;
        if self.role() != Role::Leader {
            return Err(Error::NotLeader(self.leader()));
        }
        let (index, membership) = self.node.membership_at(self.state().last().index);
        if !membership.is_joint() || index > self.state().hard().commit {
            return Err(Error::Reconfiguring);
        }
        self.node
            .propose(&Record::Configuration(membership.finalized()))
    }

    /// Snapshot the exact application state through an applied committed index.
    /// Jarl attaches the configuration at that index, not the latest configuration.
    pub fn compact(&mut self, index: u64, application: &S) -> Result<(), Error> {
        let membership = self.node.membership_at(index).1;
        self.node.compact_with(index, || Checkpoint {
            application: application.clone(),
            membership,
        })
    }
    /// Move to larger log storage without restarting or cloning payloads.
    #[must_use]
    pub fn grow<const NEW: usize>(self) -> Cluster<V, S, MAX, NEW> {
        Cluster {
            node: self.node.grow(),
        }
    }
}
