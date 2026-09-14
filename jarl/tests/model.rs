//! A separate, vector-based follower model derived from Raft Figure 2.
//! It does not call Jarl's log helpers. Capacity and snapshot boundaries are
//! explicit adaptations to the paper's unbounded log.
use jarl::{Config, Entry, Envelope, HardState, Id, LogId, Message, Node, Snapshot, State};

#[derive(Clone, Debug)]
struct Model {
    hard: HardState,
    snapshot: Option<Snapshot<u64>>,
    log: Vec<Entry<u64>>,
}

impl Model {
    fn base(&self) -> LogId {
        self.snapshot.as_ref().map_or(LogId::default(), |s| s.last)
    }

    fn at(&self, index: u64) -> Option<LogId> {
        if index == self.base().index {
            Some(self.base())
        } else {
            self.log.iter().find(|e| e.id.index == index).map(|e| e.id)
        }
    }

    fn term(&mut self, term: u64) -> bool {
        if term > self.hard.term {
            self.hard.term = term;
            self.hard.voted_for = None;
        }
        term == self.hard.term
    }

    fn append(
        &mut self,
        term: u64,
        previous: LogId,
        entry: Option<&Entry<u64>>,
        commit: u64,
    ) -> bool {
        if !self.term(term) || self.at(previous.index) != Some(previous) {
            return false;
        }
        let mut established = previous.index;
        if let Some(entry) = entry {
            if self.at(entry.id.index) != Some(entry.id) {
                if entry.id.index <= self.hard.commit {
                    return false;
                }
                let mut replacement: Vec<_> = self
                    .log
                    .iter()
                    .filter(|e| e.id.index < entry.id.index)
                    .cloned()
                    .collect();
                replacement.push(entry.clone());
                if replacement.len() > 4 {
                    self.hard.commit = self.hard.commit.max(commit.min(established));
                    return false;
                }
                self.log = replacement;
            }
            established = entry.id.index;
        }
        self.hard.commit = self.hard.commit.max(commit.min(established));
        true
    }

    fn vote(&mut self, term: u64, last: LogId) -> bool {
        if !self.term(term) {
            return false;
        }
        let ours = self.log.last().map_or(self.base(), |e| e.id);
        let eligible = self.hard.voted_for.is_none() || self.hard.voted_for == Some(Id(1));
        let fresh = last.term > ours.term || (last.term == ours.term && last.index >= ours.index);
        if eligible && fresh {
            self.hard.voted_for = Some(Id(1));
            true
        } else {
            false
        }
    }

    fn compare(&self, request: Message<u64, u64>, expected: &Self, success: bool) {
        let state = State::restore(self.hard, self.snapshot.clone(), self.log.clone()).unwrap();
        let mut node =
            Node::<u64, u64, 3, 4>::new(Config::new(Id(0), [Id(0), Id(1), Id(2)]), state).unwrap();
        node.step(&Envelope {
            from: Id(1),
            to: Id(0),
            message: request.clone(),
        })
        .unwrap();
        assert_eq!(node.state().hard(), expected.hard, "{self:?}, {request:?}");
        assert_eq!(
            node.state().entries().cloned().collect::<Vec<_>>(),
            expected.log,
            "{self:?}, {request:?}"
        );
        if let Some(ready) = node.ready() {
            ready.persisted();
        }
        let reply = node.next_message().unwrap();
        let actual = match reply.message {
            Message::Voted { granted, .. } => granted,
            Message::Replicated { rejection, .. } => rejection.is_none(),
            _ => panic!("unexpected response"),
        };
        assert_eq!(actual, success, "{self:?}, {request:?}");
    }
}

#[test]
fn follower_matches_independent_model_across_short_histories() {
    let mut cases = 0;
    for base in [0, 2] {
        for len in 0..=4 {
            for split in 0..=len {
                for commit in base..=base + len {
                    for vote in [None, Some(Id(1)), Some(Id(2))] {
                        let original = Model {
                            hard: HardState {
                                term: 2,
                                voted_for: vote,
                                commit,
                            },
                            snapshot: (base > 0).then_some(Snapshot {
                                last: LogId {
                                    index: base,
                                    term: 1,
                                },
                                value: 0,
                            }),
                            log: (1..=len)
                                .map(|i| Entry {
                                    id: LogId {
                                        index: base + i,
                                        term: if i <= split { 1 } else { 2 },
                                    },
                                    value: Some(i),
                                })
                                .collect(),
                        };
                        for term in 1..=3 {
                            for index in 0..=base + len + 1 {
                                for log_term in 0..=term {
                                    if (index == 0) != (log_term == 0) {
                                        continue;
                                    }
                                    let previous = LogId {
                                        index,
                                        term: log_term,
                                    };
                                    let mut expected = original.clone();
                                    let granted = expected.vote(term, previous);
                                    original.compare(
                                        Message::Vote {
                                            term,
                                            last: previous,
                                        },
                                        &expected,
                                        granted,
                                    );
                                    cases += 1;
                                    for new_term in log_term.max(1)..=term + 1 {
                                        let entry = (new_term <= term).then_some(Entry {
                                            id: LogId {
                                                index: index + 1,
                                                term: new_term,
                                            },
                                            value: Some(99),
                                        });
                                        for leader_commit in [0, base + len + 2] {
                                            let mut expected = original.clone();
                                            let accepted = expected.append(
                                                term,
                                                previous,
                                                entry.as_ref(),
                                                leader_commit,
                                            );
                                            original.compare(
                                                Message::Append {
                                                    term,
                                                    previous,
                                                    entry: entry.clone(),
                                                    commit: leader_commit,
                                                },
                                                &expected,
                                                accepted,
                                            );
                                            cases += 1;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    println!("independent model: {cases} transitions");
    assert!(cases > 50_000);
}

#[test]
fn batched_replication_matches_sequential_follower_rules_including_partial_capacity() {
    let mut cases = 0;
    for base in [0, 2] {
        for len in 0..=4 {
            for commit in base..=base + len {
                let original = Model {
                    hard: HardState {
                        term: 2,
                        voted_for: None,
                        commit,
                    },
                    snapshot: (base > 0).then_some(Snapshot {
                        last: LogId {
                            index: base,
                            term: 1,
                        },
                        value: 0,
                    }),
                    log: (1..=len)
                        .map(|i| Entry {
                            id: LogId {
                                index: base + i,
                                term: 2,
                            },
                            value: Some(i),
                        })
                        .collect(),
                };
                for predecessor in base..=base + len {
                    for count in 1..=6 {
                        let previous = original.at(predecessor).unwrap();
                        let entries = core::array::from_fn(|i| {
                            (i < count).then_some(Entry {
                                id: LogId {
                                    index: predecessor + i as u64 + 1,
                                    term: 3,
                                },
                                value: Some(100 + i as u64),
                            })
                        });
                        let mut expected = original.clone();
                        let mut cursor = previous;
                        let mut accepted = false;
                        for entry in entries.iter().flatten() {
                            if !expected.append(3, cursor, Some(entry), base + len + 10) {
                                break;
                            }
                            accepted = true;
                            cursor = entry.id;
                        }
                        original.compare(
                            Message::AppendBatch {
                                term: 3,
                                previous,
                                entries,
                                commit: base + len + 10,
                            },
                            &expected,
                            accepted,
                        );
                        cases += 1;
                    }
                }
            }
        }
    }
    assert_eq!(cases, 660);
}
