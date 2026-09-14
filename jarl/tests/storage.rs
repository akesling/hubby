use jarl::{
    Config, Entry, Envelope, Error, HardState, Id, LogId, Message, Node, Rejection, Role, Snapshot,
    State,
};
use std::{cell::Cell, mem::size_of, rc::Rc};

fn flush<V: Clone, S: Clone, const N: usize, const CAP: usize>(node: &mut Node<V, S, N, CAP>) {
    if let Some(ready) = node.ready() {
        ready.persisted();
    }
    while node.next_message().is_some() {}
}

fn campaign<V: Clone, S: Clone, const N: usize, const CAP: usize>(node: &mut Node<V, S, N, CAP>) {
    while node.role() == Role::Follower {
        node.tick().unwrap();
        flush(node);
    }
}

#[test]
fn dropped_persistence_token_leaves_the_same_transaction_pending() {
    let mut node = Node::<u64, (), 1, 8>::new(Config::new(Id(0), [Id(0)]), State::new()).unwrap();
    campaign(&mut node);
    node.propose(&42).unwrap();
    {
        let ready = node.ready().unwrap();
        assert_eq!(ready.write().entries().count(), 1);
        // A failed save returns without consuming the token with persisted().
    }
    assert_eq!(node.tick(), Err(Error::Busy));
    assert!(node.committed().next().is_none());
    let ready = node.ready().unwrap();
    assert_eq!(ready.write().entries().next().unwrap().value, Some(42));
    ready.persisted();
    assert!(node.ready().is_none());
    assert!(node.committed().any(|e| e.value == Some(42)));
}

#[test]
fn metadata_updates_do_not_rewrite_snapshots_or_entries() {
    let snapshot = Snapshot {
        last: LogId { index: 3, term: 1 },
        value: 7,
    };
    let state = State::restore(
        HardState {
            term: 1,
            voted_for: None,
            commit: 3,
        },
        Some(snapshot),
        [Entry {
            id: LogId { index: 4, term: 1 },
            value: Some(9),
        }],
    )
    .unwrap();
    let mut node =
        Node::<u64, u64, 3, 8>::new(Config::new(Id(0), [Id(0), Id(1), Id(2)]), state).unwrap();
    node.step(&Envelope {
        from: Id(1),
        to: Id(0),
        message: Message::Append {
            term: 2,
            previous: LogId { index: 4, term: 1 },
            entry: None,
            commit: 4,
        },
    })
    .unwrap();
    let ready = node.ready().unwrap();
    let write = ready.write();
    assert_eq!(write.hard.term, 2);
    assert_eq!(write.hard.commit, 4);
    assert_eq!(write.truncate_from, None);
    assert!(write.snapshot.is_none());
    assert_eq!(write.entries().count(), 0);
}

#[test]
fn snapshot_installation_reports_only_the_storage_changes_it_requires() {
    for snapshot_term in [1, 2] {
        let entries = (1..=4).map(|index| Entry {
            id: LogId { index, term: 1 },
            value: Some(index),
        });
        let state = State::restore(
            HardState {
                term: 2,
                voted_for: None,
                commit: 1,
            },
            None,
            entries,
        )
        .unwrap();
        let mut node =
            Node::<u64, u64, 3, 8>::new(Config::new(Id(0), [Id(0), Id(1), Id(2)]), state).unwrap();
        node.step(&Envelope {
            from: Id(1),
            to: Id(0),
            message: Message::Install {
                term: 2,
                snapshot: Snapshot {
                    last: LogId {
                        index: 2,
                        term: snapshot_term,
                    },
                    value: 3,
                },
            },
        })
        .unwrap();
        let ready = node.ready().unwrap();
        let write = ready.write();
        assert_eq!(write.snapshot.unwrap().value, 3);
        assert_eq!(write.truncate_from, (snapshot_term == 2).then_some(3));
        assert_eq!(write.entries().count(), 0);
        assert_eq!(
            ready.state().entries().count(),
            if snapshot_term == 1 { 2 } else { 0 }
        );
    }
}

#[test]
fn live_growth_preserves_pending_persistence_leadership_and_outbox() {
    let mut node =
        Node::<u64, (), 3, 2>::new(Config::new(Id(0), [Id(0), Id(1), Id(2)]), State::new())
            .unwrap();
    campaign(&mut node);
    node.step(&Envelope {
        from: Id(1),
        to: Id(0),
        message: Message::Voted {
            term: 1,
            granted: true,
        },
    })
    .unwrap();
    let mut node = node.grow::<8>();
    assert_eq!(node.role(), Role::Leader);
    assert!(node.next_message().is_none());
    let ready = node.ready().unwrap();
    assert_eq!(ready.write().truncate_from, Some(1));
    ready.persisted();
    let mut count = 0;
    while let Some(envelope) = node.next_message() {
        assert!(matches!(
            envelope.message,
            Message::Append { entry: Some(_), .. }
        ));
        count += 1;
    }
    assert_eq!(count, 2);
    assert_eq!(node.propose(&42).unwrap(), LogId { index: 2, term: 1 });
}

#[test]
fn full_uncommitted_log_recovers_without_an_election_or_restart() {
    let state = State::restore(
        HardState {
            term: 1,
            voted_for: None,
            commit: 0,
        },
        None,
        [Entry {
            id: LogId { index: 1, term: 1 },
            value: Some(7),
        }],
    )
    .unwrap();
    let mut node = Node::<u64, (), 1, 1>::new(Config::new(Id(0), [Id(0)]), state).unwrap();
    campaign(&mut node);
    assert_eq!(node.propose(&8), Err(Error::Full));
    let term = node.state().hard().term;
    let mut node = node.grow::<4>();
    for _ in 0..2 {
        node.tick().unwrap();
        flush(&mut node);
    }
    assert_eq!(node.state().hard().term, term);
    assert_eq!(node.role(), Role::Leader);
    assert_eq!(node.state().hard().commit, 2);
    assert_eq!(node.committed().next().unwrap().value, Some(7));
}

#[derive(Debug)]
struct Counted(Rc<Cell<usize>>);
impl Clone for Counted {
    fn clone(&self) -> Self {
        self.0.set(self.0.get() + 1);
        Self(self.0.clone())
    }
}

#[test]
fn outgoing_payloads_and_growth_do_not_clone_application_data() {
    let clones = Rc::new(Cell::new(0));
    let snapshot = Snapshot {
        last: LogId { index: 1, term: 1 },
        value: Counted(clones.clone()),
    };
    let state = State::restore(
        HardState {
            term: 1,
            voted_for: None,
            commit: 1,
        },
        Some(snapshot),
        [],
    )
    .unwrap();
    let mut node =
        Node::<Counted, Counted, 3, 4>::new(Config::new(Id(0), [Id(0), Id(1), Id(2)]), state)
            .unwrap();
    campaign(&mut node);
    node.step(&Envelope {
        from: Id(1),
        to: Id(0),
        message: Message::Voted {
            term: 2,
            granted: true,
        },
    })
    .unwrap();
    flush(&mut node);
    node.step(&Envelope {
        from: Id(1),
        to: Id(0),
        message: Message::Replicated {
            term: 2,
            index: 1,
            rejection: Some(Rejection::Conflict { next: 1 }),
        },
    })
    .unwrap();
    assert!(matches!(
        node.next_message().unwrap().message,
        Message::Install { .. }
    ));
    assert_eq!(clones.get(), 0);
    let mut node = node.grow::<8>();
    assert_eq!(clones.get(), 0);
    node.propose(&Counted(clones.clone())).unwrap();
    assert_eq!(clones.get(), 1); // The one copy stored in the log.
    flush(&mut node);
    assert_eq!(clones.get(), 1);
}

#[test]
fn node_memory_does_not_include_payload_copies_per_peer() {
    type V = [u8; 4096];
    type S = [u8; 8192];
    let overhead = size_of::<Node<V, S, 5, 4>>() - size_of::<State<V, S, 4>>();
    assert!(
        overhead < 1024,
        "outbox contains payloads: {overhead} extra bytes"
    );
}

#[test]
fn dynamic_batches_snapshots_and_growth_clone_only_stored_payloads() {
    use jarl::{Cluster, ClusterState, Membership, Settings};
    let clones = Rc::new(Cell::new(0));
    let initial = Membership::new(&[Id(0)], &[]).unwrap();
    let mut node = Cluster::<Counted, Counted, 3, 16>::new(
        Settings::default(),
        ClusterState::new(Id(0), initial).unwrap(),
    )
    .unwrap();
    while node.role() != Role::Leader {
        node.tick().unwrap();
        if let Some(ready) = node.ready() {
            ready.persisted();
        }
    }
    node.set_learners(&[Id(1)]).unwrap();
    node.ready().unwrap().persisted();
    while node.next_message().is_some() {}
    node.propose_batch(&[Counted(clones.clone()), Counted(clones.clone())])
        .unwrap();
    assert_eq!(clones.get(), 2);
    node.ready().unwrap().persisted();
    assert!(matches!(
        node.next_message().unwrap().message,
        Message::AppendBatch { .. }
    ));
    assert_eq!(clones.get(), 2);
    node.compact(node.state().hard().commit, &Counted(clones.clone()))
        .unwrap();
    assert_eq!(clones.get(), 3);
    node.ready().unwrap().persisted();
    assert!(matches!(
        node.next_message().unwrap().message,
        Message::Install { .. }
    ));
    let mut node = node.grow::<32>();
    assert_eq!(clones.get(), 3);
    assert!(node.next_message().is_none());
    assert!(size_of::<Membership<8>>() <= 8 * 24);
}

#[test]
fn panicking_application_clone_rolls_back_the_entire_local_batch() {
    use jarl::{Cluster, ClusterState, Membership, Settings};
    struct Payload(Rc<Cell<usize>>);
    impl Clone for Payload {
        fn clone(&self) -> Self {
            let left = self.0.get();
            assert!(left > 0, "application clone failed");
            self.0.set(left - 1);
            Self(self.0.clone())
        }
    }
    let budget = Rc::new(Cell::new(1));
    let mut node = Cluster::<Payload, (), 1, 8>::new(
        Settings::default(),
        ClusterState::new(Id(0), Membership::new(&[Id(0)], &[]).unwrap()).unwrap(),
    )
    .unwrap();
    while node.role() != Role::Leader {
        node.tick().unwrap();
        if let Some(ready) = node.ready() {
            ready.persisted();
        }
    }
    let before = node.status();
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        node.propose_batch(&[Payload(budget.clone()), Payload(budget.clone())])
    }));
    assert!(result.is_err());
    assert_eq!(node.status(), before);
    assert_eq!(node.state().entries().count(), 1);
    budget.set(1);
    node.propose(&Payload(budget)).unwrap();
    node.ready().unwrap().persisted();
    assert_eq!(node.committed().count(), 2);
}
