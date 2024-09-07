#![no_std]

pub mod node {
    pub enum State {
        Leader,
        Candidate,
        Follower,
    }

    pub struct Id(u32);

    pub struct Node<const CELL_SIZE: usize, const MAX_LOG: usize, VALUE, SNAPSHOT> {
        id: Id,

        state: State,
        term: u32,

        next_index: u32,
        match_indexes: [u32; CELL_SIZE],

        log: crate::log::Log<VALUE, MAX_LOG>,
        snapshot: SNAPSHOT,

        initialized: bool,
    }
}

pub mod msg {
    pub struct AppendEntries<'e, VALUE> {
        leader: crate::node::Id,
        term: u32,
        high_watermark: u32,
        entries: &'e [crate::log::Entry<VALUE>],
    }

    pub struct AppendResponse {
        term: u32,
        success: bool,
    }

    pub struct RequestVote {
        term: u32,
        candidate: crate::node::Id,
        last_index: u32,
        last_term: u32,
    }

    pub struct VoteResponse {
        term: u32,
        granted: bool,
    }
}

pub mod log {
    pub trait Snapshot {
        fn update_from_log<VALUE, const MAX_LOG: usize>(&mut self, log: &Log<VALUE, MAX_LOG>);
    }

    pub struct Entry<VALUE> {
        term: u32,
        index: u32,
        value: VALUE,
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
    /// `entries` includes the entry immediately previous to the append state.  This differs from the
    /// Raft paper in that it includes the value of that entry along with the term and index.
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
