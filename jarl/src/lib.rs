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
    pub struct Id(u32);

    struct Node<const CELL_SIZE: usize, const MAX_LOG: usize, VALUE, SNAPSHOT> {
        id: Id,

        term: u32,

        next_index: u32,
        match_indexes: [u32; CELL_SIZE],

        log: crate::log::Log<VALUE, MAX_LOG>,
        snapshot: SNAPSHOT,

        initialized: bool,
    }

    impl<const CELL_SIZE: usize, const MAX_LOG: usize, VALUE, SNAPSHOT>
        Node<CELL_SIZE, MAX_LOG, VALUE, SNAPSHOT>
    {
        // * If commitIndex > lastApplied: increment lastApplied, apply log[lastApplied] to state
        //   machine (§5.3)
        // * If RPC request or response contains term T > currentTerm: set currentTerm = T, convert
        //   to follower (§5.1)
    }

    pub struct Leader<const CELL_SIZE: usize, const MAX_LOG: usize, VALUE, SNAPSHOT>(
        Node<CELL_SIZE, MAX_LOG, VALUE, SNAPSHOT>,
    );
    pub struct Candidate<const CELL_SIZE: usize, const MAX_LOG: usize, VALUE, SNAPSHOT>(
        Node<CELL_SIZE, MAX_LOG, VALUE, SNAPSHOT>,
    );
    pub struct Follower<const CELL_SIZE: usize, const MAX_LOG: usize, VALUE, SNAPSHOT>(
        Node<CELL_SIZE, MAX_LOG, VALUE, SNAPSHOT>,
    );

    impl<const CELL_SIZE: usize, const MAX_LOG: usize, VALUE, SNAPSHOT>
        Leader<CELL_SIZE, MAX_LOG, VALUE, SNAPSHOT>
    {
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

    impl<const CELL_SIZE: usize, const MAX_LOG: usize, VALUE, SNAPSHOT>
        Follower<CELL_SIZE, MAX_LOG, VALUE, SNAPSHOT>
    {
        // * Respond to RPCs from candidates and leaders
        // * If election timeout elapses without receiving AppendEntries RPC from current leader or
        //   granting vote to candidate: convert to candidate
    }

    impl<const CELL_SIZE: usize, const MAX_LOG: usize, VALUE, SNAPSHOT>
        Candidate<CELL_SIZE, MAX_LOG, VALUE, SNAPSHOT>
    {
        // * On conversion to candidate, start election:
        //   * Increment currentTerm
        //   * Vote for self
        //   * Reset election timer
        //   * Send RequestVote RPCs to all other servers
        // * If votes received from majority of servers: become leader
        // * If AppendEntries RPC received from new leader: convert to follower
        // * If election timeout elapses: start new election
    }
}

pub mod msg {
    pub struct AppendEntries<'e, VALUE> {
        pub leader: crate::node::Id,
        pub term: u32,
        pub high_watermark: u32,
        pub entries: &'e [crate::log::Entry<VALUE>],
    }

    pub struct AppendResponse {
        pub term: u32,
        pub success: bool,
    }

    pub struct RequestVote {
        pub term: u32,
        pub candidate: crate::node::Id,
        pub last_index: u32,
        pub last_term: u32,
    }

    pub struct VoteResponse {
        pub term: u32,
        pub granted: bool,
    }
}

pub mod log {
    pub trait Snapshot {
        fn update_from_log<VALUE, const MAX_LOG: usize>(&mut self, log: &Log<VALUE, MAX_LOG>);
    }

    pub struct Entry<VALUE> {
        pub term: u32,
        pub index: u32,
        pub value: VALUE,
    }
    pub type Log<VALUE, const MAX_LOG: usize> = [crate::log::Entry<VALUE>; MAX_LOG];

    pub enum AppendEntriesError {
        /// Log slice provided did not have capacity to append new entries.
        LogUnderCapacity,
    }

    /// Append entries to node's log
    ///
    /// ```Invoked by leader to replicate log entries (§5.3); also used as heartbeat (§5.2).```
    ///
    /// `entries` includes the entry immediately previous to the append state.  This differs from
    /// the Raft paper in that it includes the value of that entry along with the term and index.
    ///
    pub fn append_entries<'e, VALUE: Clone>(
        msg: &crate::msg::AppendEntries<'e, VALUE>,
        log: &mut [Entry<VALUE>],
    ) -> Result<crate::msg::AppendResponse, AppendEntriesError> {
        let _ = msg;
        let _ = log;
        todo!("Implement append entries!")
    }
}

#[cfg(test)]
mod cell_semantics_test {
    /*********************************************************************************************/
    /* Follower **********************************************************************************/
    /*********************************************************************************************/

    #[ignore]
    #[test]
    fn follower_becomes_candidate_upon_heartbeat_timeout() {}

    #[ignore]
    #[test]
    fn follower_increments_term_upon_new_leader_message() {}

    /*********************************************************************************************/
    /* Candidate *********************************************************************************/
    /*********************************************************************************************/

    #[ignore]
    #[test]
    fn candidate_becomes_leader_when_receive_majority_vote() {}

    #[ignore]
    #[test]
    fn candidate_starts_new_election_when_election_times_out_without_majority() {}

    #[ignore]
    #[test]
    fn candidate_becomes_follower_upon_new_leader_message() {}

    /*********************************************************************************************/
    /* Leader ************************************************************************************/
    /*********************************************************************************************/

    #[ignore]
    #[test]
    fn fresh_leader_issues_empty_append_entries() {}

    #[ignore]
    #[test]
    fn leader_becomes_follower_upon_new_leader_message_with_higher_term() {}
}
