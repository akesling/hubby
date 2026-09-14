use jarl::{
    Config, Entry, Envelope, Error, HardState, Id, LogId, Message, Node, Rejection, Role, Snapshot,
    State,
};

type Peer<const N: usize = 3, const CAP: usize = 8> = Node<u64, u64, N, CAP>;

fn fresh<const N: usize, const CAP: usize>(id: u64) -> Peer<N, CAP> {
    Node::new(
        Config::new(Id(id), core::array::from_fn(|i| Id(i as u64))),
        State::new(),
    )
    .unwrap()
}

fn entry(index: u64, term: u64, value: u64) -> Entry<u64> {
    Entry {
        id: LogId { index, term },
        value: Some(value),
    }
}

fn input<const N: usize, const CAP: usize>(
    node: &mut Peer<N, CAP>,
    from: u64,
    message: Message<u64, u64>,
) {
    node.step(&Envelope {
        from: Id(from),
        to: Id(0),
        message,
    })
    .unwrap();
}

fn flush<const N: usize, const CAP: usize>(node: &mut Peer<N, CAP>) -> Vec<Envelope<u64, u64>> {
    if let Some(ready) = node.ready() {
        ready.persisted();
    }
    core::iter::from_fn(|| node.next_message().map(|message| message.cloned())).collect()
}

fn campaign<const N: usize, const CAP: usize>(node: &mut Peer<N, CAP>) -> Vec<Envelope<u64, u64>> {
    let term = node.state().hard().term;
    for _ in 0..20 {
        node.tick().unwrap();
        if node.state().hard().term != term {
            return flush(node);
        }
        assert!(flush(node).is_empty());
    }
    panic!("election did not start");
}

fn elect(node: &mut Peer) {
    campaign(node);
    input(
        node,
        1,
        Message::Voted {
            term: node.state().hard().term,
            granted: true,
        },
    );
    flush(node);
    assert_eq!(node.role(), Role::Leader);
}

#[test]
fn config_rejects_invalid_membership_and_timers() {
    let configs = [
        Config::new(Id(0), [Id(0), Id(0), Id(1)]),
        Config::new(Id(9), [Id(0), Id(1), Id(2)]),
        Config {
            heartbeat_ticks: 0,
            ..Config::new(Id(0), [Id(0), Id(1), Id(2)])
        },
        Config {
            election_ticks: 2,
            ..Config::new(Id(0), [Id(0), Id(1), Id(2)])
        },
        Config {
            election_ticks: u64::MAX,
            ..Config::new(Id(0), [Id(0), Id(1), Id(2)])
        },
    ];
    for config in configs {
        assert!(matches!(
            Peer::<3, 8>::new(config, State::new()),
            Err(Error::Config)
        ));
    }
    assert!(matches!(
        Node::<u64, u64, 0, 8>::new(Config::new(Id(0), []), State::new()),
        Err(Error::Config)
    ));
    assert!(matches!(
        Node::<u64, u64, 1, 0>::new(Config::new(Id(0), [Id(0)]), State::new()),
        Err(Error::Config)
    ));
}

#[test]
fn persistence_and_outbox_gate_all_input() {
    let mut n: Peer = fresh(0);
    assert_eq!(n.role(), Role::Follower);
    assert_eq!(n.propose(&1), Err(Error::NotLeader(None)));
    for _ in 0..20 {
        n.tick().unwrap();
        if n.ready().is_some() {
            break;
        }
    }
    assert!(n.ready().is_some());
    assert_eq!(n.state().hard().voted_for, Some(Id(0)));
    assert!(n.next_message().is_none());
    let before = n.state().clone();
    assert_eq!(n.tick(), Err(Error::Busy));
    assert_eq!(n.propose(&1), Err(Error::Busy));
    assert_eq!(n.state(), &before);
    if let Some(ready) = n.ready() {
        ready.persisted();
    }
    assert_eq!(n.tick(), Err(Error::Busy));
    assert_eq!(flush(&mut n).len(), 2);
    assert_eq!(n.tick(), Ok(()));
}

#[test]
fn higher_term_is_persisted_before_rejecting_log_mismatch() {
    let mut n: Peer = fresh(0);
    input(
        &mut n,
        1,
        Message::Append {
            term: 7,
            previous: LogId { index: 1, term: 6 },
            entry: None,
            commit: 0,
        },
    );
    assert_eq!(n.state().hard().term, 7);
    assert!(n.next_message().is_none());
    assert_eq!(
        flush(&mut n)[0].message,
        Message::Replicated {
            term: 7,
            index: 1,
            rejection: Some(Rejection::Conflict { next: 1 }),
        }
    );
}

#[test]
fn votes_are_durable_unique_and_log_aware() {
    let mut n: Peer = fresh(0);
    input(
        &mut n,
        1,
        Message::Vote {
            term: 1,
            last: LogId::default(),
        },
    );
    assert!(n.ready().is_some());
    let saved = n.state().clone();
    assert_eq!(
        flush(&mut n)[0].message,
        Message::Voted {
            term: 1,
            granted: true
        }
    );
    let mut n = Peer::<3, 8>::new(Config::new(Id(0), [Id(0), Id(1), Id(2)]), saved).unwrap();
    input(
        &mut n,
        2,
        Message::Vote {
            term: 1,
            last: LogId::default(),
        },
    );
    assert_eq!(
        flush(&mut n)[0].message,
        Message::Voted {
            term: 1,
            granted: false
        }
    );
    input(
        &mut n,
        1,
        Message::Vote {
            term: 1,
            last: LogId::default(),
        },
    );
    assert!(n.ready().is_none());
    assert_eq!(
        flush(&mut n)[0].message,
        Message::Voted {
            term: 1,
            granted: true
        }
    );

    let state = State::restore(
        HardState {
            term: 3,
            voted_for: None,
            commit: 0,
        },
        None,
        [entry(1, 2, 5)],
    )
    .unwrap();
    let mut n = Peer::<3, 8>::new(Config::new(Id(0), [Id(0), Id(1), Id(2)]), state).unwrap();
    for (last, granted) in [
        (LogId { index: 10, term: 1 }, false),
        (LogId { index: 1, term: 2 }, true),
    ] {
        input(&mut n, 1, Message::Vote { term: 3, last });
        assert_eq!(
            flush(&mut n)[0].message,
            Message::Voted { term: 3, granted }
        );
    }
}

#[test]
fn votes_count_distinct_peers_and_only_the_current_term() {
    let mut n: Peer<5> = fresh(0);
    campaign(&mut n);
    input(
        &mut n,
        1,
        Message::Voted {
            term: 1,
            granted: true,
        },
    );
    flush(&mut n);
    input(
        &mut n,
        1,
        Message::Voted {
            term: 1,
            granted: true,
        },
    );
    flush(&mut n);
    assert_eq!(n.role(), Role::Candidate);
    campaign(&mut n);
    assert_eq!(n.state().hard().term, 2);
    input(
        &mut n,
        2,
        Message::Voted {
            term: 1,
            granted: true,
        },
    );
    flush(&mut n);
    input(
        &mut n,
        1,
        Message::Voted {
            term: 2,
            granted: true,
        },
    );
    flush(&mut n);
    assert_eq!(n.role(), Role::Candidate);
    input(
        &mut n,
        2,
        Message::Voted {
            term: 2,
            granted: true,
        },
    );
    assert_eq!(n.role(), Role::Leader);
    assert_eq!(flush(&mut n).len(), 4);
}

#[test]
fn higher_term_response_steps_down_a_leader() {
    let mut n: Peer = fresh(0);
    elect(&mut n);
    input(
        &mut n,
        1,
        Message::Replicated {
            term: 2,
            index: 0,
            rejection: None,
        },
    );
    assert_eq!(n.role(), Role::Follower);
    assert_eq!(n.leader(), None);
    assert_eq!(n.state().hard().voted_for, None);
    assert!(n.ready().is_some());
    flush(&mut n);
    assert_eq!(n.propose(&1), Err(Error::NotLeader(None)));
}

#[test]
fn valid_heartbeats_reset_elections_and_stale_ones_do_not() {
    let mut n: Peer = fresh(0);
    let heartbeat = |term| Message::Append {
        term,
        previous: LogId::default(),
        entry: None,
        commit: 99,
    };
    for _ in 0..50 {
        input(&mut n, 1, heartbeat(2));
        assert_eq!(
            flush(&mut n)[0].message,
            Message::Replicated {
                term: 2,
                index: 0,
                rejection: None
            }
        );
        for _ in 0..8 {
            n.tick().unwrap();
        }
        assert_eq!(n.role(), Role::Follower);
        assert_eq!(n.state().hard().commit, 0);
    }
    for _ in 0..20 {
        input(&mut n, 1, heartbeat(1));
        flush(&mut n);
        n.tick().unwrap();
        flush(&mut n);
        if n.role() == Role::Candidate {
            break;
        }
    }
    assert_eq!(n.role(), Role::Candidate);
    assert_eq!(n.state().hard().term, 3);
}

#[test]
fn append_repairs_a_suffix_and_duplicates_do_not_truncate_it() {
    let state = State::restore(
        HardState {
            term: 2,
            voted_for: None,
            commit: 1,
        },
        None,
        [entry(1, 1, 10), entry(2, 1, 20), entry(3, 1, 30)],
    )
    .unwrap();
    let mut n = Peer::<3, 8>::new(Config::new(Id(0), [Id(0), Id(1), Id(2)]), state).unwrap();
    input(
        &mut n,
        1,
        Message::Append {
            term: 2,
            previous: LogId { index: 1, term: 1 },
            entry: Some(entry(2, 2, 99)),
            commit: 9,
        },
    );
    assert_eq!(n.committed().count(), 0);
    flush(&mut n);
    assert_eq!(n.state().last(), LogId { index: 2, term: 2 });
    assert_eq!(n.state().hard().commit, 2);
    input(
        &mut n,
        1,
        Message::Append {
            term: 2,
            previous: LogId { index: 2, term: 2 },
            entry: Some(entry(3, 2, 100)),
            commit: 2,
        },
    );
    flush(&mut n);
    input(
        &mut n,
        1,
        Message::Append {
            term: 2,
            previous: LogId { index: 1, term: 1 },
            entry: Some(entry(2, 2, 99)),
            commit: 9,
        },
    );
    assert!(n.ready().is_none());
    flush(&mut n);
    assert_eq!(n.state().last().index, 3);
    assert_eq!(n.state().hard().commit, 2);
    input(
        &mut n,
        1,
        Message::Append {
            term: 2,
            previous: LogId { index: 1, term: 1 },
            entry: None,
            commit: 9,
        },
    );
    flush(&mut n);
    assert_eq!(n.state().last().index, 3);
    assert_eq!(n.state().hard().commit, 2);
}

#[test]
fn full_follower_can_commit_then_compact_and_retry() {
    let state = State::restore(
        HardState {
            term: 1,
            voted_for: None,
            commit: 0,
        },
        None,
        [entry(1, 1, 10)],
    )
    .unwrap();
    let mut n = Peer::<3, 1>::new(Config::new(Id(0), [Id(0), Id(1), Id(2)]), state).unwrap();
    let message = Message::Append {
        term: 1,
        previous: LogId { index: 1, term: 1 },
        entry: Some(entry(2, 1, 20)),
        commit: 2,
    };
    input(&mut n, 1, message.clone());
    assert_eq!(
        flush(&mut n)[0].message,
        Message::Replicated {
            term: 1,
            index: 1,
            rejection: Some(Rejection::Full)
        }
    );
    assert_eq!(n.state().last().index, 1);
    assert_eq!(n.state().hard().commit, 1);
    n.compact(1, &10).unwrap();
    flush(&mut n);
    input(&mut n, 1, message);
    assert_eq!(
        flush(&mut n)[0].message,
        Message::Replicated {
            term: 1,
            index: 2,
            rejection: None
        }
    );
    assert_eq!(n.committed().next().unwrap().value, Some(20));
}

#[test]
fn full_log_can_replace_uncommitted_entries_but_not_committed_entries() {
    for commit in [0, 1] {
        let state = State::restore(
            HardState {
                term: 2,
                voted_for: None,
                commit,
            },
            None,
            [entry(1, 1, 10)],
        )
        .unwrap();
        let mut n = Peer::<3, 1>::new(Config::new(Id(0), [Id(0), Id(1), Id(2)]), state).unwrap();
        input(
            &mut n,
            1,
            Message::Append {
                term: 2,
                previous: LogId::default(),
                entry: Some(entry(1, 2, 20)),
                commit: 0,
            },
        );
        flush(&mut n);
        assert_eq!(
            n.state().entries().next().unwrap().value,
            Some(if commit == 0 { 20 } else { 10 })
        );
    }
}

#[test]
fn prior_term_entries_need_a_current_term_majority() {
    let state = State::restore(
        HardState {
            term: 1,
            voted_for: None,
            commit: 0,
        },
        None,
        [entry(1, 1, 10)],
    )
    .unwrap();
    let mut n = Peer::<3, 8>::new(Config::new(Id(0), [Id(0), Id(1), Id(2)]), state).unwrap();
    elect(&mut n);
    assert_eq!(n.state().last(), LogId { index: 2, term: 2 });
    input(
        &mut n,
        1,
        Message::Replicated {
            term: 2,
            index: 1,
            rejection: None,
        },
    );
    flush(&mut n);
    assert_eq!(n.state().hard().commit, 0);
    input(
        &mut n,
        1,
        Message::Replicated {
            term: 2,
            index: 2,
            rejection: None,
        },
    );
    assert!(n.committed().next().is_none());
    flush(&mut n);
    assert_eq!(n.state().hard().commit, 2);
    assert_eq!(n.committed().count(), 2);
}

#[test]
fn delayed_rejection_cannot_undo_success() {
    let mut n: Peer = fresh(0);
    elect(&mut n);
    input(
        &mut n,
        1,
        Message::Replicated {
            term: 1,
            index: 1,
            rejection: None,
        },
    );
    flush(&mut n);
    input(
        &mut n,
        1,
        Message::Replicated {
            term: 1,
            index: 0,
            rejection: Some(Rejection::Conflict { next: 1 }),
        },
    );
    assert!(flush(&mut n).is_empty());
    let id = n.propose(&7).unwrap();
    let messages = flush(&mut n);
    let to_one = messages.iter().find(|m| m.to == Id(1)).unwrap();
    assert!(
        matches!(&to_one.message, Message::Append { previous, entry: Some(e), .. } if previous.index == 1 && e.id == id)
    );
}

#[test]
fn single_voter_commits_and_reuses_bounded_storage() {
    let mut n: Peer<1, 2> = fresh(0);
    campaign(&mut n);
    assert_eq!(n.role(), Role::Leader);
    assert_eq!(n.state().hard().commit, 1);
    assert_eq!(n.propose(&10).unwrap().index, 2);
    assert_eq!(n.committed().count(), 0);
    flush(&mut n);
    assert_eq!(n.committed().count(), 2);
    let before = n.state().clone();
    assert_eq!(n.propose(&20), Err(Error::Full));
    assert_eq!(n.state(), &before);
    assert_eq!(n.compact(3, &10), Err(Error::NotCommitted));
    n.compact(2, &10).unwrap();
    assert!(n.snapshot().is_none());
    flush(&mut n);
    assert_eq!(n.snapshot().unwrap().value, 10);
    assert_eq!(n.state().entries().count(), 0);
    assert_eq!(n.propose(&20).unwrap().index, 3);
}

#[test]
fn snapshots_preserve_matching_suffixes_and_replace_conflicting_ones() {
    for snapshot_term in [1, 2] {
        let state = State::restore(
            HardState {
                term: 2,
                voted_for: None,
                commit: 1,
            },
            None,
            [entry(1, 1, 10), entry(2, 1, 20), entry(3, 1, 30)],
        )
        .unwrap();
        let mut n = Peer::<3, 8>::new(Config::new(Id(0), [Id(0), Id(1), Id(2)]), state).unwrap();
        let snapshot = Snapshot {
            last: LogId {
                index: 2,
                term: snapshot_term,
            },
            value: 20,
        };
        input(
            &mut n,
            1,
            Message::Install {
                term: 2,
                snapshot: snapshot.clone(),
            },
        );
        assert!(n.ready().is_some());
        flush(&mut n);
        assert_eq!(n.state().hard().commit, 2);
        assert_eq!(n.snapshot(), Some(&snapshot));
        assert_eq!(n.state().entries().count(), usize::from(snapshot_term == 1));
        let saved = n.state().clone();
        input(&mut n, 1, Message::Install { term: 2, snapshot });
        assert!(n.ready().is_none());
        flush(&mut n);
        assert_eq!(n.state(), &saved);
    }
}

#[test]
fn compacted_follower_supplies_a_forward_retry_hint() {
    let snapshot = Snapshot {
        last: LogId { index: 5, term: 1 },
        value: 5,
    };
    let state = State::restore(
        HardState {
            term: 1,
            voted_for: None,
            commit: 5,
        },
        Some(snapshot),
        [],
    )
    .unwrap();
    let mut n = Peer::<3, 8>::new(Config::new(Id(0), [Id(0), Id(1), Id(2)]), state).unwrap();
    input(
        &mut n,
        1,
        Message::Append {
            term: 1,
            previous: LogId { index: 2, term: 1 },
            entry: Some(entry(3, 1, 3)),
            commit: 5,
        },
    );
    assert_eq!(
        flush(&mut n)[0].message,
        Message::Replicated {
            term: 1,
            index: 2,
            rejection: Some(Rejection::Conflict { next: 6 })
        }
    );
}

#[test]
fn malformed_messages_do_not_mutate_state() {
    let mut n: Peer = fresh(0);
    let before = n.state().clone();
    let messages = [
        Message::Append {
            term: 5,
            previous: LogId::default(),
            entry: Some(entry(2, 5, 0)),
            commit: 0,
        },
        Message::Append {
            term: 5,
            previous: LogId { index: 1, term: 4 },
            entry: Some(entry(2, 3, 0)),
            commit: 0,
        },
        Message::Vote {
            term: 5,
            last: LogId { index: 0, term: 1 },
        },
        Message::Vote {
            term: 0,
            last: LogId::default(),
        },
    ];
    for message in messages {
        assert_eq!(
            n.step(&Envelope {
                from: Id(1),
                to: Id(0),
                message
            }),
            Err(Error::Message)
        );
        assert_eq!(n.state(), &before);
    }
    for (from, to) in [(Id(9), Id(0)), (Id(1), Id(9)), (Id(0), Id(0))] {
        assert_eq!(
            n.step(&Envelope {
                from,
                to,
                message: Message::Vote {
                    term: 5,
                    last: LogId::default()
                }
            }),
            Err(Error::Message)
        );
    }
    assert_eq!(n.state(), &before);
}

#[test]
fn checkpoints_validate_structure_and_can_grow_capacity() {
    let hard = HardState {
        term: 2,
        voted_for: Some(Id(0)),
        commit: 1,
    };
    for entries in [
        vec![entry(2, 1, 0)],
        vec![entry(1, 3, 0)],
        vec![entry(1, 2, 0), entry(2, 1, 0)],
        vec![],
    ] {
        assert!(matches!(
            State::<u64, u64, 8>::restore(hard, None, entries),
            Err(Error::State)
        ));
    }
    assert!(matches!(
        State::<u64, u64, 8>::restore(
            HardState::default(),
            Some(Snapshot {
                last: LogId::default(),
                value: 0
            }),
            []
        ),
        Err(Error::State)
    ));
    assert!(matches!(
        State::<u64, u64, 1>::restore(hard, None, [entry(1, 1, 10), entry(2, 2, 20)]),
        Err(Error::Full)
    ));
    let small = State::<u64, u64, 1>::restore(hard, None, [entry(1, 1, 10)]).unwrap();
    let large = State::<u64, u64, 8>::restore(
        small.hard(),
        small.snapshot().cloned(),
        small.entries().cloned(),
    )
    .unwrap();
    assert_eq!(
        small.entries().collect::<Vec<_>>(),
        large.entries().collect::<Vec<_>>()
    );
}

#[test]
fn crash_before_persistence_cannot_publish_a_vote_or_commit() {
    let durable = State::new();
    let config = Config::new(Id(0), [Id(0), Id(1), Id(2)]);
    let mut n = Peer::<3, 8>::new(config.clone(), durable.clone()).unwrap();
    input(
        &mut n,
        1,
        Message::Vote {
            term: 1,
            last: LogId::default(),
        },
    );
    assert!(n.next_message().is_none());
    assert!(n.committed().next().is_none());
    let mut n = Peer::<3, 8>::new(config, durable).unwrap();
    input(
        &mut n,
        2,
        Message::Vote {
            term: 1,
            last: LogId::default(),
        },
    );
    assert_eq!(
        flush(&mut n)[0].message,
        Message::Voted {
            term: 1,
            granted: true
        }
    );
}

#[test]
fn term_and_index_exhaustion_are_errors() {
    let state = State::restore(
        HardState {
            term: u64::MAX,
            voted_for: None,
            commit: 0,
        },
        None,
        [],
    )
    .unwrap();
    let mut n = Peer::<3, 8>::new(Config::new(Id(0), [Id(0), Id(1), Id(2)]), state).unwrap();
    let mut exhausted = false;
    for _ in 0..30 {
        if n.tick() == Err(Error::Exhausted) {
            exhausted = true;
        }
    }
    assert!(exhausted);
    assert_eq!(n.role(), Role::Follower);
    let snapshot = Snapshot {
        last: LogId {
            index: u64::MAX,
            term: 1,
        },
        value: 0,
    };
    let state = State::restore(
        HardState {
            term: 1,
            voted_for: None,
            commit: u64::MAX,
        },
        Some(snapshot),
        [],
    )
    .unwrap();
    let mut n = Peer::<1>::new(Config::new(Id(0), [Id(0)]), state).unwrap();
    campaign(&mut n);
    assert_eq!(n.propose(&1), Err(Error::Exhausted));
}

#[test]
fn application_values_need_no_default_implementation() {
    #[derive(Clone)]
    struct Command;
    let mut n = Node::<Command, (), 1, 4>::new(Config::new(Id(0), [Id(0)]), State::new()).unwrap();
    for _ in 0..20 {
        n.tick().unwrap();
        if let Some(ready) = n.ready() {
            ready.persisted();
        }
        if n.role() == Role::Leader {
            break;
        }
    }
    n.propose(&Command).unwrap();
}

#[test]
fn growing_capacity_unblocks_a_log_full_of_uncommitted_entries() {
    let state = State::restore(
        HardState {
            term: 1,
            voted_for: None,
            commit: 0,
        },
        None,
        [entry(1, 1, 10), entry(2, 1, 20)],
    )
    .unwrap();
    let config = Config::new(Id(0), [Id(0)]);
    let mut small = Peer::<1, 2>::new(config.clone(), state).unwrap();
    campaign(&mut small);
    assert_eq!(small.role(), Role::Leader);
    assert_eq!(small.state().hard().commit, 0);
    assert_eq!(small.propose(&30), Err(Error::Full));
    assert_eq!(small.compact(1, &10), Err(Error::NotCommitted));
    let saved = small.state();
    let grown = State::restore(
        saved.hard(),
        saved.snapshot().cloned(),
        saved.entries().cloned(),
    )
    .unwrap();
    let mut large = Peer::<1, 4>::new(config, grown).unwrap();
    campaign(&mut large);
    assert_eq!(large.state().hard().commit, 3);
    assert_eq!(
        large
            .committed()
            .filter_map(|e| e.value)
            .collect::<Vec<_>>(),
        [10, 20]
    );
    assert_eq!(large.propose(&30).unwrap().index, 4);
}

#[test]
fn unpersisted_proposals_and_snapshots_are_not_applied_after_crash() {
    let config = Config::new(Id(0), [Id(0)]);
    let mut n: Peer<1> = fresh(0);
    campaign(&mut n);
    let saved = n.state().clone();
    n.propose(&42).unwrap();
    assert_eq!(n.committed().count(), 0);
    let recovered = Peer::<1, 8>::new(config, saved).unwrap();
    assert!(!recovered.committed().any(|e| e.value == Some(42)));

    let config = Config::new(Id(0), [Id(0), Id(1), Id(2)]);
    let saved = State::new();
    let mut n = Peer::<3, 8>::new(config.clone(), saved.clone()).unwrap();
    input(
        &mut n,
        1,
        Message::Install {
            term: 1,
            snapshot: Snapshot {
                last: LogId { index: 5, term: 1 },
                value: 42,
            },
        },
    );
    assert!(n.ready().is_some());
    assert!(n.snapshot().is_none());
    assert!(n.next_message().is_none());
    let recovered = Peer::<3, 8>::new(config, saved).unwrap();
    assert!(recovered.snapshot().is_none());
    assert_eq!(recovered.state().hard().commit, 0);
}

#[test]
fn a_candidate_accepts_a_leader_in_its_own_term() {
    let mut n: Peer = fresh(0);
    campaign(&mut n);
    input(
        &mut n,
        1,
        Message::Append {
            term: 1,
            previous: LogId::default(),
            entry: None,
            commit: 0,
        },
    );
    assert_eq!(n.role(), Role::Follower);
    assert_eq!(n.leader(), Some(Id(1)));
    assert_eq!(n.state().hard().voted_for, Some(Id(0)));
    assert_eq!(
        flush(&mut n)[0].message,
        Message::Replicated {
            term: 1,
            index: 0,
            rejection: None
        }
    );
}

#[test]
fn a_snapshot_cannot_replace_or_claim_a_conflicting_committed_prefix() {
    let state = State::restore(
        HardState {
            term: 2,
            voted_for: None,
            commit: 1,
        },
        None,
        [entry(1, 1, 10)],
    )
    .unwrap();
    let mut n = Peer::<3, 8>::new(Config::new(Id(0), [Id(0), Id(1), Id(2)]), state).unwrap();
    let before = n.state().clone();
    input(
        &mut n,
        1,
        Message::Install {
            term: 2,
            snapshot: Snapshot {
                last: LogId { index: 1, term: 2 },
                value: 99,
            },
        },
    );
    assert_eq!(n.state(), &before);
    assert!(matches!(
        flush(&mut n)[0].message,
        Message::Replicated {
            rejection: Some(_),
            ..
        }
    ));
}
