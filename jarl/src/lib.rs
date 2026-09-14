#![no_std]
#![forbid(unsafe_code)]
#![warn(missing_docs)]
#![doc = include_str!("../README.md")]

mod cluster;
pub mod host;
mod membership;
mod node;
mod ready;
mod state;

#[cfg(test)]
extern crate std;
#[cfg(test)]
mod explore;
#[cfg(test)]
mod explore_dynamic;

pub use cluster::{Checkpoint, Cluster, ClusterState, Record, Settings};
pub use membership::Membership;
pub use node::Node;
pub use ready::{Ready, Write};
pub use state::{HardState, State};

/// A stable identity within one fixed cluster.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Id(pub u64);

/// A log position and the election term that created it. Zero denotes genesis.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct LogId {
    /// One-based position in the log.
    pub index: u64,
    /// Election term.
    pub term: u64,
}

/// A replicated command. `None` is an internal leadership barrier.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Entry<V> {
    /// Position of this entry.
    pub id: LogId,
    /// Application command, or a no-op.
    pub value: Option<V>,
}

/// Application state after applying every entry through `last`.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Snapshot<S> {
    /// Last included entry.
    pub last: LogId,
    /// Application-defined snapshot contents.
    pub value: S,
}

/// Local role. Only a leader accepts proposals.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Role {
    /// Receives replication and votes in elections.
    Follower,
    /// Requests a majority of votes.
    Candidate,
    /// Replicates proposals to the cluster.
    Leader,
}

/// Fixed membership and local timer settings.
#[derive(Clone, Debug)]
pub struct Config<const N: usize> {
    /// This node's identity.
    pub id: Id,
    /// All voters, including this node. Identities must be distinct.
    pub members: [Id; N],
    /// Ticks between leader heartbeats; must be positive.
    pub heartbeat_ticks: u64,
    /// Election deadlines are sampled in `[election_ticks, 2 * election_ticks)`.
    /// Must exceed `heartbeat_ticks` and be at most `u64::MAX / 2`.
    pub election_ticks: u64,
    /// Seed for deterministic election jitter. Use independent seeds per node.
    pub seed: u64,
}

impl<const N: usize> Config<N> {
    /// Use two-tick heartbeats and election deadlines between ten and twenty ticks.
    pub fn new(id: Id, members: [Id; N]) -> Self {
        Self {
            id,
            members,
            heartbeat_ticks: 2,
            election_ticks: 10,
            seed: id.0.wrapping_add(1),
        }
    }
}

/// A local operation could not be performed. The node remains usable.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Error {
    /// Invalid membership, timing, or zero log capacity.
    Config,
    /// Malformed or inconsistent persisted state.
    State,
    /// Persist pending state and drain messages before the next operation.
    Busy,
    /// Proposals require leadership. The known leader, if any, is provided.
    NotLeader(Option<Id>),
    /// Log capacity is exhausted. Compact applied entries or increase capacity.
    Full,
    /// The requested snapshot position is not in the committed log.
    NotCommitted,
    /// A term or index cannot be incremented without overflow.
    Exhausted,
    /// Envelope identities or message contents are invalid.
    Message,
    /// A membership change must finish committing before another can begin.
    Reconfiguring,
    /// A new voter must first catch up as a learner.
    NotCaughtUp,
}

impl core::fmt::Display for Error {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            Self::Config => f.write_str("invalid configuration"),
            Self::State => f.write_str("invalid checkpoint"),
            Self::Busy => f.write_str("persist state and drain messages first"),
            Self::NotLeader(Some(id)) => write!(f, "not leader; last known leader is {}", id.0),
            Self::NotLeader(None) => f.write_str("not leader; leader unknown"),
            Self::Full => f.write_str("log capacity exhausted"),
            Self::NotCommitted => f.write_str("snapshot index is outside the committed suffix"),
            Self::Exhausted => f.write_str("term or index exhausted"),
            Self::Message => f.write_str("invalid message"),
            Self::Reconfiguring => f.write_str("membership change is pending"),
            Self::NotCaughtUp => f.write_str("new voter has not caught up"),
        }
    }
}

impl core::error::Error for Error {}

/// Why a follower could not replicate a request.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Rejection {
    /// The predecessor does not match; retry an earlier position.
    Conflict {
        /// Suggested next index, possibly beyond a compacted prefix.
        next: u64,
    },
    /// The follower needs compaction or more log capacity.
    Full,
}

/// Maximum entries in one allocation-free replication message.
pub const MAX_APPEND_ENTRIES: usize = 16;

/// A protocol message. Transport must authenticate the sending peer.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Message<V, S> {
    /// Probe a prospective election without advancing durable terms.
    PreVote {
        /// Proposed next term, not the sender's durable term.
        term: u64,
        /// Candidate's last log position.
        last: LogId,
    },
    /// Reply to an election probe; never a durable vote.
    PreVoted {
        /// Responder's actual durable term (possibly zero).
        term: u64,
        /// Proposed term from the probe being answered.
        campaign: u64,
        /// Whether the responder would support that election.
        granted: bool,
    },
    /// Request a vote using the candidate's last log position.
    Vote {
        /// Candidate term.
        term: u64,
        /// Candidate's last entry or snapshot boundary.
        last: LogId,
    },
    /// Response to a vote request.
    Voted {
        /// Responder's current term.
        term: u64,
        /// Whether the vote was granted.
        granted: bool,
    },
    /// Replicate one entry, or send a heartbeat when `entry` is `None`.
    Append {
        /// Leader term.
        term: u64,
        /// Entry immediately preceding this request.
        previous: LogId,
        /// Optional next entry.
        entry: Option<Entry<V>>,
        /// Leader's committed position.
        commit: u64,
    },
    /// Replicate a nonempty contiguous batch. Occupied slots form a prefix;
    /// unused slots are `None`. The fixed upper bound needs no allocator.
    AppendBatch {
        /// Leader term.
        term: u64,
        /// Entry immediately preceding this batch.
        previous: LogId,
        /// At most `MAX_APPEND_ENTRIES` entries, in index order.
        entries: [Option<Entry<V>>; MAX_APPEND_ENTRIES],
        /// Leader's committed position.
        commit: u64,
    },
    /// Install a complete application snapshot.
    Install {
        /// Leader term.
        term: u64,
        /// Snapshot and its log boundary.
        snapshot: Snapshot<S>,
    },
    /// Response to append or snapshot installation.
    Replicated {
        /// Responder's current term.
        term: u64,
        /// On success, the last matched index. On rejection, the requested predecessor.
        index: u64,
        /// `None` means success.
        rejection: Option<Rejection>,
    },
}

impl<V, S> Message<V, S> {
    pub(crate) fn term(&self) -> u64 {
        match self {
            Self::PreVote { term, .. }
            | Self::PreVoted { term, .. }
            | Self::Vote { term, .. }
            | Self::Voted { term, .. }
            | Self::Append { term, .. }
            | Self::AppendBatch { term, .. }
            | Self::Install { term, .. }
            | Self::Replicated { term, .. } => *term,
        }
    }
}

/// A message addressed to one peer in this cluster.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Envelope<V, S> {
    /// Sending peer.
    pub from: Id,
    /// Receiving peer.
    pub to: Id,
    /// Protocol contents.
    pub message: Message<V, S>,
}

impl<V: Clone, S: Clone> Envelope<&V, &S> {
    /// Own the payloads for an in-memory queue. Encoders can use the borrowed
    /// envelope directly and avoid these clones.
    pub fn cloned(&self) -> Envelope<V, S> {
        let message = match &self.message {
            Message::PreVote { term, last } => Message::PreVote {
                term: *term,
                last: *last,
            },
            Message::PreVoted {
                term,
                campaign,
                granted,
            } => Message::PreVoted {
                term: *term,
                campaign: *campaign,
                granted: *granted,
            },
            Message::Vote { term, last } => Message::Vote {
                term: *term,
                last: *last,
            },
            Message::Voted { term, granted } => Message::Voted {
                term: *term,
                granted: *granted,
            },
            Message::Append {
                term,
                previous,
                entry,
                commit,
            } => Message::Append {
                term: *term,
                previous: *previous,
                commit: *commit,
                entry: entry.as_ref().map(|e| Entry {
                    id: e.id,
                    value: e.value.cloned(),
                }),
            },
            Message::AppendBatch {
                term,
                previous,
                entries,
                commit,
            } => Message::AppendBatch {
                term: *term,
                previous: *previous,
                commit: *commit,
                entries: core::array::from_fn(|i| {
                    entries[i].as_ref().map(|e| Entry {
                        id: e.id,
                        value: e.value.cloned(),
                    })
                }),
            },
            Message::Install { term, snapshot } => Message::Install {
                term: *term,
                snapshot: Snapshot {
                    last: snapshot.last,
                    value: snapshot.value.clone(),
                },
            },
            Message::Replicated {
                term,
                index,
                rejection,
            } => Message::Replicated {
                term: *term,
                index: *index,
                rejection: *rejection,
            },
        };
        Envelope {
            from: self.from,
            to: self.to,
            message,
        }
    }
}

/// Identities of the first and last entries admitted in one atomic proposal batch.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ProposalRange {
    /// First proposed entry.
    pub first: LogId,
    /// Last proposed entry, inclusive. Neither identity implies commitment.
    pub last: LogId,
}

/// Local diagnostics for host scheduling and monitoring. Never a read lease.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Status {
    /// Local node identity.
    pub id: Id,
    /// Local role.
    pub role: Role,
    /// Current term, possibly awaiting persistence.
    pub term: u64,
    /// Last retained log identity or snapshot boundary.
    pub last: LogId,
    /// Committed position, possibly awaiting persistence.
    pub commit: u64,
    /// Number of occupied log slots.
    pub retained: usize,
    /// Total log slot capacity.
    pub capacity: usize,
    /// Whether an atomic storage update must be saved.
    pub persistence_pending: bool,
    /// Number of outgoing descriptors waiting for the host.
    pub messages_pending: usize,
}

/// A leader's view of one replication recipient. Values can be stale.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PeerProgress {
    /// Stable peer identity.
    pub id: Id,
    /// Whether this peer votes in either active configuration.
    pub voter: bool,
    /// Last acknowledged log position in this leader term.
    pub matched: u64,
    /// Next replication position.
    pub next: u64,
}
