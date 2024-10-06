#![no_std]
//! # Raft state machine
//!
//! (Figure 4 from [Raft paper](https://raft.github.io/raft.pdf))
//! ```text
//! Starting state = [Follower]
//! ===========================
//!
//! *******************          ┌───────────┐   **************
//! * Times out,      *          │           ┼──>* Times out, *
//! * starts election *─────────>│ Candidate │   * tries new  *
//! *                 *          │           │<──* election   *
//! *******************          └─┬───────┬─┘   **************
//!       ^                        v       │
//!  ┌────┴─────┐   *********************  │
//!  │ Follower │<──* Discovers current *  │
//!  └──────────┘   * leader or         *  │
//!       ^         * new term          *  │
//!       │         *********************  v
//!       │                               ******************
//! ********************    ┌────────┐    * Receives votes *
//! * Discovers server *<───┼ Leader │<───* from majority  *
//! * with higher term *    └────────┘    * of nodes       *
//! ********************                  ******************
//! ```

pub mod node {
    #[derive(Debug, PartialEq, Clone, Copy)]
    pub struct Id(pub u32);
    pub type Term = u32;

    /// NodeTime is a non-negative, unitless, monotonic time
    ///
    /// Practically, this will generally store a UNIX-epoch based timestamp, but it is left to the
    /// library consumer to make that decision for themselves.
    #[derive(Debug, Clone, Copy)]
    pub struct NodeTime(pub u64);

    impl core::ops::Add<NodeTimeDuration> for NodeTime {
        type Output = Self;

        fn add(self, other: NodeTimeDuration) -> Self {
            Self(self.0 + other.0 .0)
        }
    }

    #[derive(Debug, Clone, Copy)]
    pub struct NodeTimeDuration(NodeTime);

    impl core::ops::Add for NodeTimeDuration {
        type Output = Self;

        fn add(self, other: Self) -> Self {
            Self(NodeTime(self.0 .0 + other.0 .0))
        }
    }

    impl NodeTimeDuration {
        pub fn new(duration: u64) -> Self {
            NodeTimeDuration(NodeTime(duration))
        }
    }

    #[derive(Debug)]
    pub enum Error {
        ElectionStartTimeInFuture,
    }

    #[derive(Debug)]
    pub enum NodeState {
        Follower,
        Candidate,
        Leader,
    }

    pub struct CellConfig<const CELL_SIZE: usize> {
        pub election_interval: (NodeTimeDuration, NodeTimeDuration),
        pub heartbeat_ttl: NodeTimeDuration,
    }

    #[derive(Debug)]
    pub struct Node<const CELL_SIZE: usize, const MAX_LOG: usize, VALUE: Default, SNAPSHOT> {
        /// A cell-unique identifier for this node
        id: Id,

        /// The current election term
        term: Term,

        leader_commit_index: crate::log::Index,

        /// The maximum time seen
        high_watermark: NodeTime,

        // TODO(alex): Figure out how to keep around a source of randomness that _could_ be a
        // deterministic random number generator for testing purposes.  This will be used for
        // determining heartbeat and election expirations.  Raft paper recommends 150–300ms as the
        // window for "normal" leader election periods.
        /// The time at which a follower will become a candidate if it doesn't get
        /// a new heartbeat / reset this before then.
        heartbeat_expiration: NodeTime,

        /// The time at which the current election expires
        election_expiration: NodeTime,

        next_index_to_replicate_per_node: [crate::log::Index; CELL_SIZE],
        max_replicated_index_per_node: [crate::log::Index; CELL_SIZE],

        log: crate::log::Log<VALUE, MAX_LOG>,
        snapshot: SNAPSHOT,

        initialized: bool,
    }

    impl<const CELL_SIZE: usize, const MAX_LOG: usize, VALUE: Default, SNAPSHOT>
        Node<CELL_SIZE, MAX_LOG, VALUE, SNAPSHOT>
    {
        #[inline]
        pub fn new(id: Id) -> Follower<CELL_SIZE, MAX_LOG, VALUE, SNAPSHOT>
        where
            SNAPSHOT: Default,
        {
            Follower(Node {
                id,
                term: 0,
                leader_commit_index: 0,
                high_watermark: NodeTime(0),
                heartbeat_expiration: NodeTime(0),
                election_expiration: NodeTime(0),
                next_index_to_replicate_per_node: [0; CELL_SIZE],
                max_replicated_index_per_node: [0; CELL_SIZE],
                log: crate::log::Log::<VALUE, MAX_LOG>::new(),
                snapshot: Default::default(),
                initialized: false,
            })
        }

        #[inline]
        pub fn progress_time(&mut self, new_time: NodeTime) {
            self.high_watermark.0 = core::cmp::max(self.high_watermark.0, new_time.0);
        }

        // * If commitIndex > lastApplied: increment lastApplied, apply log[lastApplied] to state
        //   machine (§5.3)
        // * If RPC request or response contains term T > currentTerm: set currentTerm = T, convert
        //   to follower (§5.1)
    }

    #[derive(Debug)]
    pub struct Follower<const CELL_SIZE: usize, const MAX_LOG: usize, VALUE: Default, SNAPSHOT>(
        Node<CELL_SIZE, MAX_LOG, VALUE, SNAPSHOT>,
    );

    impl<const CELL_SIZE: usize, const MAX_LOG: usize, VALUE: Clone + Default, SNAPSHOT>
        Follower<CELL_SIZE, MAX_LOG, VALUE, SNAPSHOT>
    {
        pub fn get_state(&self) -> NodeState {
            NodeState::Follower
        }

        pub fn init(&mut self, start_time: NodeTime, cell_config: &CellConfig<CELL_SIZE>) {
            let n = &mut self.0;

            n.high_watermark = start_time;
            n.heartbeat_expiration = start_time + cell_config.heartbeat_ttl;

            n.initialized = true;
        }

        #[inline]
        pub fn term(&self) -> Term {
            self.0.term
        }

        // TODO(alex): Figure out a less dumb return type here / way to manage type transition to
        // Candidate.
        pub fn progress_time(&mut self, new_time: NodeTime) -> bool {
            let n = &mut self.0;
            n.progress_time(new_time);

            let start_election = n.heartbeat_expiration.0 <= n.high_watermark.0;
            start_election
        }

        pub fn start_election(
            self,
        ) -> Result<Candidate<CELL_SIZE, MAX_LOG, VALUE, SNAPSHOT>, Error> {
            let n = self.0;
            if n.high_watermark.0 < n.heartbeat_expiration.0 {
                return Err(Error::ElectionStartTimeInFuture);
            }

            // TODO(alex): Increment term and perform necessary election preparation.

            Ok(Candidate(n))
        }

        pub fn receive_append_entries(
            &mut self,
            msg: &crate::msg::AppendEntries<VALUE>,
        ) -> crate::msg::AppendResponse {
            let last_entry = self.0.log.last_entry();
            // Reject messages from old leaders
            if msg.term < self.term()
                || last_entry
                    .map(|le| {
                        // Do terms and indexes match?
                        msg.previous_log_item_term != le.term
                            || msg.previous_log_item_index != le.index
                    })
                    .unwrap_or_else(|| {
                        // Should there _be_ a previous message?
                        msg.previous_log_item_term != 0 || msg.previous_log_item_index != 0
                    })
            {
                return crate::msg::AppendResponse {
                    term: self.term(),
                    success: false,
                };
            }

            let result = crate::log::append_entries(msg, &mut self.0.log).expect(concat!(
                "A failure occurred when attempting to append entries in ",
                "Follower::receive_append_entries"
            ));

            if !result.success {
                return result;
            }

            if msg.term > self.0.term {
                self.0.term = msg.term
            }

            if msg.commit_index > self.0.leader_commit_index {
                self.0.leader_commit_index = msg.commit_index
            }

            return result;
        }

        // * If election timeout elapses without receiving AppendEntries RPC from current leader or
        //   granting vote to candidate: convert to candidate
    }

    #[derive(Debug)]
    pub struct Candidate<const CELL_SIZE: usize, const MAX_LOG: usize, VALUE: Default, SNAPSHOT>(
        Node<CELL_SIZE, MAX_LOG, VALUE, SNAPSHOT>,
    );

    impl<const CELL_SIZE: usize, const MAX_LOG: usize, VALUE: Default, SNAPSHOT>
        Candidate<CELL_SIZE, MAX_LOG, VALUE, SNAPSHOT>
    {
        pub fn get_state() -> NodeState {
            NodeState::Candidate
        }

        // * On conversion to candidate, start election:
        //   * Increment currentTerm
        //   * Vote for self
        //   * Reset election timer
        //   * Send RequestVote RPCs to all other servers
        // * If votes received from majority of servers: become leader
        // * If AppendEntries RPC received from new leader: convert to follower
        // * If election timeout elapses: start new election
    }

    #[derive(Debug)]
    pub struct Leader<const CELL_SIZE: usize, const MAX_LOG: usize, VALUE: Default, SNAPSHOT>(
        Node<CELL_SIZE, MAX_LOG, VALUE, SNAPSHOT>,
    );

    impl<const CELL_SIZE: usize, const MAX_LOG: usize, VALUE: Default, SNAPSHOT>
        Leader<CELL_SIZE, MAX_LOG, VALUE, SNAPSHOT>
    {
        pub fn get_state() -> NodeState {
            NodeState::Leader
        }

        // * Upon election: send initial empty AppendEntries RPCs (heartbeat) to each server; repeat
        //   during idle periods to prevent election timeouts (§5.2)
        // * If command received from client: append entry to local log, respond after entry
        //   applied to state machine (§5.3)
        // * If last log index ≥ nextIndex for a follower: send AppendEntries RPC with log entries
        //   starting at nextIndex
        //   * If successful: update nextIndex and matchIndex for follower (§5.3)
        //   * If AppendEntries fails because of log inconsistency: decrement nextIndex and retry
        //     (§5.3)
        // * If there exists an N such that N > commitIndex, a majority of matchIndex[i] ≥ N, and
        //   log[N].term == currentTerm: set commitIndex = N (§5.3, §5.4).

        fn fill_append_entries<'e>(
            &'e self,
            append_msg: &mut crate::msg::AppendEntries<'e, VALUE>,
        ) {
            todo!("Implement `fill_append_entries`")
        }
    }
}

pub mod msg {
    #[derive(Debug)]
    pub struct AppendEntries<'e, VALUE: Default> {
        pub leader: crate::node::Id,

        pub term: crate::node::Term,
        pub commit_index: crate::log::Index,

        pub previous_log_item_index: crate::log::Index,
        pub previous_log_item_term: crate::node::Term,

        pub entries: &'e [crate::log::Entry<VALUE>],
    }

    #[derive(Debug, PartialEq)]
    pub struct AppendResponse {
        pub term: crate::node::Term,
        pub success: bool,
    }

    #[derive(Debug, PartialEq)]
    pub struct RequestVote {
        pub term: crate::node::Term,
        pub candidate: crate::node::Id,
        pub last_index: crate::log::Index,
        pub last_term: crate::node::Term,
    }

    #[derive(Debug, PartialEq)]
    pub struct VoteResponse {
        pub term: crate::node::Term,
        pub granted: bool,
    }
}

pub mod log {
    pub type Index = u32;

    pub trait Snapshot {
        fn update_from_log<VALUE: Default, const MAX_LOG: usize>(
            &mut self,
            log: &Log<VALUE, MAX_LOG>,
        );
    }

    #[derive(Default, Debug)]
    pub struct Entry<VALUE: Default> {
        pub term: crate::node::Term,
        pub index: crate::log::Index,
        pub value: VALUE,
    }

    #[derive(Debug)]
    pub struct Log<VALUE: Default, const MAX_LOG: usize>([crate::log::Entry<VALUE>; MAX_LOG]);
    impl<VALUE: Default, const MAX_LOG: usize> Log<VALUE, MAX_LOG> {
        pub fn new() -> Self {
            Log(core::array::from_fn(|_| Default::default()))
        }

        pub fn last_entry(&self) -> Option<&Entry<VALUE>> {
            self.0.get(self.0.len() - 1)
        }

        #[inline]
        pub fn len(&self) -> usize {
            self.0.len()
        }

        #[inline]
        pub fn is_empty(&self) -> bool {
            self.0.is_empty()
        }
    }

    #[derive(Debug)]
    pub enum AppendEntriesError {
        /// Log slice provided did not have capacity to append new entries.
        LogUnderCapacity,
    }

    /// Append entries to provided log
    ///
    /// `Invoked by leader to replicate log entries (§5.3); also used as heartbeat (§5.2).`
    ///
    /// `If an existing entry conflicts with a new one (same index but different terms), delete
    /// the existing entry and all that follow it (§5.3)`
    pub fn append_entries<'e, VALUE: Clone + Default, const MAX_LOG: usize>(
        msg: &crate::msg::AppendEntries<'e, VALUE>,
        log: &mut Log<VALUE, MAX_LOG>,
    ) -> Result<crate::msg::AppendResponse, AppendEntriesError> {
        let _ = msg;
        let _ = log;
        todo!("Implement append_entries!")
    }

    #[cfg(test)]
    mod test {
        use super::*;

        #[test]
        fn append_entries_works() {
            let mut log = Log::<u32, 10 /* log length */>::new();
            assert!(log.is_empty());

            let empty_update_result = append_entries(
                &crate::msg::AppendEntries {
                    leader: crate::node::Id(0),
                    term: 1,
                    commit_index: 0,

                    previous_log_item_term: 0,
                    previous_log_item_index: 0,

                    entries: &[],
                },
                &mut log,
            );
            assert!(log.is_empty());

            let single_update = append_entries(
                &crate::msg::AppendEntries {
                    leader: crate::node::Id(0),
                    term: 1,
                    commit_index: 0,

                    previous_log_item_term: 0,
                    previous_log_item_index: 0,

                    entries: &[Entry {
                        term: 1,
                        index: 1,
                        value: 42,
                    }],
                },
                &mut log,
            );
            assert_eq!(log.len(), 1);
        }

        #[ignore]
        #[test]
        fn append_overwrites_inconsistent_term_items() {}

        #[ignore]
        #[test]
        fn append_fails_if_index_is_inconsistent() {}
    }
}

#[cfg(test)]
mod cell_semantics_test {
    use super::*;

    /************************************************************************/
    /* Follower *************************************************************/
    /************************************************************************/
    mod follower {
        use super::*;

        #[test]
        fn node_starts_in_follower_state() {
            let mut n = node::Node::<5, 10, usize, usize>::new(node::Id(0));
            let start_time = node::NodeTime(1);
            n.init(
                start_time,
                &node::CellConfig {
                    election_interval: (
                        node::NodeTimeDuration::new(150),
                        node::NodeTimeDuration::new(300),
                    ),
                    heartbeat_ttl: node::NodeTimeDuration::new(300),
                },
            );
            match n.get_state() {
                node::NodeState::Follower => (), // Success!
                wrong_type @ _ => panic!("Node was not of follower type: {wrong_type:#?}"),
            }
        }

        #[test]
        fn follower_becomes_candidate_upon_heartbeat_timeout() {
            let mut follower = node::Node::<5, 10, usize, usize>::new(node::Id(0));
            let start_time = node::NodeTime(1);
            follower.init(
                start_time,
                &node::CellConfig {
                    election_interval: (
                        node::NodeTimeDuration::new(150),
                        node::NodeTimeDuration::new(300),
                    ),
                    heartbeat_ttl: node::NodeTimeDuration::new(300),
                },
            );

            let start_election = follower.progress_time(node::NodeTime(302));
            assert!(
                start_election,
                "Progressing time did not trigger election start"
            );
            let _candidate = follower.start_election().expect(
                "Election failed to start despite progress_time signalling it was ready to start one",
            );
        }

        #[test]
        fn follower_increments_term_upon_new_leader_message() {
            let follower_id = node::Id(0);
            let leader_id = node::Id(1);

            let mut follower = node::Node::<5, 10, usize, usize>::new(follower_id);
            let start_time = node::NodeTime(1);
            follower.init(
                start_time,
                &node::CellConfig {
                    election_interval: (
                        node::NodeTimeDuration::new(150),
                        node::NodeTimeDuration::new(300),
                    ),
                    heartbeat_ttl: node::NodeTimeDuration::new(300),
                },
            );

            assert_eq!(follower.term(), 0);

            let log = &[];
            let response = follower.receive_append_entries(&msg::AppendEntries {
                leader: leader_id,
                term: 1,
                commit_index: 0,

                previous_log_item_term: 0,
                previous_log_item_index: 0,

                entries: log,
            });
            assert_eq!(
                response,
                msg::AppendResponse {
                    term: 1,
                    success: true,
                }
            );
            assert_eq!(follower.term(), 1);

            let response = follower.receive_append_entries(&msg::AppendEntries {
                leader: leader_id,
                term: 2,
                commit_index: 0,

                previous_log_item_term: 1,
                previous_log_item_index: 0,

                entries: log,
            });
            assert_eq!(
                response,
                msg::AppendResponse {
                    term: 2,
                    success: true,
                }
            );
            assert_eq!(follower.term(), 2);
        }

        #[ignore]
        #[test]
        fn follower_appends_to_log_for_current_term() {}

        #[ignore]
        #[test]
        fn follower_election_window_resets_upon_append_receipt() {}

        #[ignore]
        #[test]
        fn follower_rejects_append_from_old_leader() {}

        #[ignore]
        #[test]
        fn follower_rejects_vote_request_from_old_candidate() {}

        #[ignore]
        #[test]
        fn follower_accepts_one_candidate_per_voting_term() {}
    }

    /************************************************************************/
    /* Candidate ************************************************************/
    /************************************************************************/
    mod candidate {
        use super::*;

        #[ignore]
        #[test]
        fn candidate_candidate_sends_vote_requests_upon_new_election() {}

        #[ignore]
        #[test]
        fn candidate_becomes_leader_when_receive_majority_vote() {}

        #[ignore]
        #[test]
        fn candidate_starts_new_election_when_election_times_out_without_majority() {}

        #[ignore]
        #[test]
        fn candidate_becomes_follower_upon_new_leader_message() {}
    }

    /************************************************************************/
    /* Leader ***************************************************************/
    /************************************************************************/
    mod leader {
        use super::*;

        #[ignore]
        #[test]
        fn fresh_leader_issues_empty_append_entries() {}

        #[ignore]
        #[test]
        fn leader_becomes_follower_upon_new_leader_message_with_higher_term() {}
    }
}
