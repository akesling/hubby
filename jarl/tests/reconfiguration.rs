use jarl::{
    Checkpoint, Cluster, ClusterState, Entry, Envelope, Error, Id, Membership, Message, Record,
    Role, Settings, State,
};
use std::collections::VecDeque;

const MAX: usize = 6;
const CAP: usize = 32;
type Peer = Cluster<u64, u64, MAX, CAP>;
type Disk = State<Record<u64, MAX>, Checkpoint<u64, MAX>, CAP>;
type Wire = Envelope<Record<u64, MAX>, Checkpoint<u64, MAX>>;

struct World {
    nodes: Vec<Peer>,
    disk: Vec<Disk>,
    network: VecDeque<Wire>,
    links: [[bool; MAX]; MAX],
    genesis: Membership<MAX>,
    history: Vec<Entry<Record<u64, MAX>>>,
}
impl World {
    fn new() -> Self {
        let genesis = Membership::new(&[Id(0), Id(1), Id(2)], &[]).unwrap();
        let nodes = (0..MAX)
            .map(|i| {
                Cluster::new(
                    Settings {
                        seed: i as u64 + 1,
                        ..Settings::default()
                    },
                    ClusterState::new(Id(i as u64), genesis).unwrap(),
                )
                .unwrap()
            })
            .collect();
        Self {
            nodes,
            disk: vec![Disk::new(); MAX],
            network: VecDeque::new(),
            links: [[true; MAX]; MAX],
            genesis,
            history: vec![],
        }
    }
    fn output(&mut self, i: usize) {
        while let Some(message) = self.nodes[i].next_message() {
            self.network.push_back(message.cloned());
        }
    }
    fn save(&mut self, i: usize) {
        if let Some(ready) = self.nodes[i].ready() {
            let write = ready.write();
            let snapshot = write
                .snapshot
                .cloned()
                .or_else(|| self.disk[i].snapshot().cloned());
            let base = snapshot.as_ref().map_or(0, |s| s.last.index);
            let log = self.disk[i]
                .entries()
                .filter(|e| {
                    e.id.index > base && write.truncate_from.is_none_or(|from| e.id.index < from)
                })
                .cloned()
                .chain(write.entries().cloned())
                .collect::<Vec<_>>();
            let state = Disk::restore(write.hard, snapshot, log).unwrap();
            assert_eq!(&state, ready.state());
            self.disk[i] = state;
            ready.persisted();
        }
        self.output(i);
        self.check();
    }
    fn check(&mut self) {
        for node in &self.nodes {
            for entry in node.committed() {
                if let Some(previous) = self.history.iter().find(|e| e.id.index == entry.id.index) {
                    assert_eq!(previous, entry, "committed history diverged");
                } else {
                    self.history.push(entry.clone());
                }
            }
        }
    }
    fn drain(&mut self) {
        let mut budget = 10000;
        while let Some(message) = self.network.pop_front() {
            budget -= 1;
            assert!(budget > 0, "network did not quiesce");
            let (from, to) = (message.from.0 as usize, message.to.0 as usize);
            if self.links[from][to] {
                match self.nodes[to].step(&message) {
                    Ok(()) | Err(Error::Message) => {}
                    other => panic!("delivery: {other:?}"),
                }
                self.save(to);
            }
        }
    }
    fn elect(&mut self, i: usize) {
        for _ in 0..100 {
            for j in 0..MAX {
                self.nodes[j].tick().unwrap();
                self.save(j);
            }
            // Prefer this candidate by dropping competing election requests.
            self.network.retain(|m| {
                m.from == Id(i as u64)
                    || !matches!(m.message, Message::Vote { .. } | Message::PreVote { .. })
            });
            self.drain();
            if self.nodes[i].role() == Role::Leader {
                return;
            }
        }
        panic!("failed to elect {i}");
    }
    fn healthy(&mut self) {
        for _ in 0..80 {
            for i in 0..MAX {
                self.nodes[i].tick().unwrap();
                self.save(i);
            }
            self.drain();
        }
    }
    fn isolate(&mut self, i: usize) {
        for j in 0..MAX {
            self.links[i][j] = false;
            self.links[j][i] = false;
        }
    }
    fn restart(&mut self, i: usize) {
        self.nodes[i] = Cluster::new(
            Settings {
                seed: i as u64 + 77,
                ..Settings::default()
            },
            ClusterState::restore(Id(i as u64), self.genesis, self.disk[i].clone()).unwrap(),
        )
        .unwrap();
    }
    fn learners(&mut self) {
        self.nodes[0].set_learners(&[Id(3), Id(4), Id(5)]).unwrap();
        self.save(0);
        self.drain();
    }
}

#[test]
fn learners_are_passive_and_must_catch_up_before_promotion() {
    let mut w = World::new();
    w.elect(0);
    let target = Membership::new(&[Id(0), Id(1), Id(3)], &[]).unwrap();
    assert_eq!(w.nodes[0].reconfigure(target), Err(Error::NotCaughtUp));
    w.isolate(3);
    w.learners();
    assert_eq!(w.nodes[0].reconfigure(target), Err(Error::NotCaughtUp));
    for _ in 0..50 {
        w.nodes[3].tick().unwrap();
        w.save(3);
    }
    assert_eq!(w.nodes[3].role(), Role::Follower);
    assert_eq!(w.nodes[3].state().hard().term, 0);
    w.links = [[true; MAX]; MAX];
    w.healthy();
    let index = w.nodes[0].reconfigure(target).unwrap();
    w.save(0);
    w.drain();
    assert!(w.nodes[0].membership().is_joint());
    assert!(w.nodes[0].state().hard().commit >= index.index);
}

#[test]
fn joint_commit_requires_both_majorities() {
    for surviving in [[0, 1, 2], [0, 3, 4]] {
        let mut w = World::new();
        w.elect(0);
        w.learners();
        for i in 0..MAX {
            if !surviving.contains(&i) {
                w.isolate(i);
            }
        }
        let index = w.nodes[0]
            .reconfigure(Membership::new(&[Id(0), Id(3), Id(4)], &[]).unwrap())
            .unwrap();
        w.save(0);
        w.drain();
        assert!(w.nodes[0].state().hard().commit < index.index);
        assert_eq!(
            w.nodes[0].finish_reconfiguration(),
            Err(Error::Reconfiguring)
        );
        w.links = [[true; MAX]; MAX];
        w.healthy();
        let leader = w
            .nodes
            .iter()
            .position(|n| n.role() == Role::Leader)
            .unwrap();
        assert!(w.nodes[leader].state().hard().commit >= index.index);
        w.nodes[leader].finish_reconfiguration().unwrap();
        w.save(leader);
        w.drain();
        assert!(!w.nodes[leader].committed_membership().is_joint());
    }
}

#[test]
fn removed_leader_finishes_change_then_new_voters_make_progress() {
    let mut w = World::new();
    w.elect(0);
    w.learners();
    let target = Membership::new(&[Id(3), Id(4), Id(5)], &[]).unwrap();
    w.nodes[0].reconfigure(target).unwrap();
    w.save(0);
    w.drain();
    let final_id = w.nodes[0].finish_reconfiguration().unwrap();
    w.save(0);
    w.drain();
    assert_eq!(w.nodes[0].role(), Role::Follower);
    assert!(w.nodes[0].state().hard().commit >= final_id.index);
    for i in 0..3 {
        w.isolate(i);
    }
    w.elect(3);
    let id = w.nodes[3].propose(&42).unwrap();
    w.save(3);
    w.drain();
    assert!(w.nodes[3].state().hard().commit >= id.index);
    assert_eq!(w.nodes[3].membership(), target);
}

#[test]
fn restart_at_each_configuration_persistence_boundary() {
    for boundary in 0..4 {
        let mut w = World::new();
        w.elect(0);
        w.learners();
        let target = Membership::new(&[Id(0), Id(3), Id(4)], &[Id(5)]).unwrap();
        w.nodes[0].reconfigure(target).unwrap();
        if boundary >= 1 {
            w.save(0);
        }
        if boundary >= 2 {
            w.drain();
            w.nodes[0].finish_reconfiguration().unwrap();
        }
        if boundary >= 3 {
            w.save(0);
        }
        w.restart(0);
        w.network.clear();
        w.elect(0);
        if w.nodes[0].membership().is_joint() {
            w.nodes[0].finish_reconfiguration().unwrap();
            w.save(0);
            w.drain();
        }
        let id = w.nodes[0].propose(&123).unwrap();
        w.save(0);
        w.drain();
        assert!(w.nodes[0].state().hard().commit >= id.index);
    }
}

#[test]
fn snapshot_carries_configuration_at_its_boundary_and_recovers_joiner() {
    let mut w = World::new();
    w.elect(0);
    w.isolate(5);
    w.learners();
    let before = w.nodes[0].state().hard().commit;
    let target = Membership::new(&[Id(0), Id(3), Id(4)], &[Id(5)]).unwrap();
    w.nodes[0].reconfigure(target).unwrap();
    w.save(0);
    w.drain();
    // Compact behind an effective joint configuration: preserve the old voters.
    w.nodes[0].compact(before, &0).unwrap();
    w.save(0);
    w.drain();
    assert!(!w.nodes[0].snapshot().unwrap().value.membership.is_joint());
    w.nodes[0].finish_reconfiguration().unwrap();
    w.save(0);
    w.drain();
    let through = w.nodes[0].state().hard().commit;
    w.nodes[0].compact(through, &0).unwrap();
    w.save(0);
    w.drain();
    w.restart(0);
    assert_eq!(w.nodes[0].membership(), target);
    w.elect(0);
    // A genuinely fresh learner catches up from a membership-bearing snapshot.
    w.restart(5);
    w.links = [[true; MAX]; MAX];
    w.healthy();
    assert_eq!(w.nodes[5].membership(), target);
    assert!(w.nodes[5].snapshot().is_some());
}

#[test]
fn capacity_reserve_and_membership_validation() {
    assert!(Membership::<2>::new(&[], &[]).is_err());
    assert!(Membership::<2>::new(&[Id(0), Id(0)], &[]).is_err());
    assert!(Membership::<2>::new(&[Id(0)], &[Id(0)]).is_err());
    let genesis = Membership::<4>::new(&[Id(88)], &[]).unwrap();
    let mut node = Cluster::<u64, (), 4, 4>::new(
        Settings::default(),
        ClusterState::new(Id(88), genesis).unwrap(),
    )
    .unwrap();
    for _ in 0..30 {
        node.tick().unwrap();
        if let Some(ready) = node.ready() {
            ready.persisted();
        }
    }
    assert_eq!(node.propose(&1), Err(Error::Full));
    assert_eq!(node.remaining(), 3);
    let mut node = node.grow::<8>();
    node.propose(&1).unwrap();
}

#[test]
fn isolated_follower_does_not_inflate_terms_and_isolated_leader_steps_down() {
    let mut w = World::new();
    w.elect(0);
    let term = w.nodes[0].state().hard().term;
    w.isolate(2);
    w.healthy();
    assert_eq!(w.nodes[2].state().hard().term, term);
    assert_eq!(w.nodes[0].state().hard().term, term);
    w.links = [[true; MAX]; MAX];
    w.healthy();
    assert_eq!(w.nodes[0].state().hard().term, term);
    w.isolate(0);
    w.healthy();
    assert_ne!(w.nodes[0].role(), Role::Leader);
    assert!(matches!(w.nodes[0].propose(&9), Err(Error::NotLeader(_))));
}

#[test]
fn unknown_authenticated_leader_can_update_a_stale_joiner() {
    let mut w = World::new();
    w.elect(0);
    w.isolate(5);
    w.learners();
    let target = Membership::new(&[Id(3), Id(4)], &[Id(5)]).unwrap();
    w.nodes[0].reconfigure(target).unwrap();
    w.save(0);
    w.drain();
    w.nodes[0].finish_reconfiguration().unwrap();
    w.save(0);
    w.drain();
    for i in 0..3 {
        w.isolate(i);
    }
    w.elect(3);
    let through = w.nodes[3].state().hard().commit;
    w.nodes[3].compact(through, &0).unwrap();
    w.save(3);
    w.drain();
    for i in [3, 4] {
        w.links[i][5] = true;
        w.links[5][i] = true;
    }
    w.healthy();
    assert_eq!(w.nodes[5].membership(), target);
    assert!(w.nodes[5].snapshot().is_some());
}

#[test]
fn rejected_batch_does_not_admit_a_prefix_or_clone_payloads() {
    let mut w = World::new();
    w.elect(0);
    let before = w.nodes[0].state().clone();
    assert_eq!(w.nodes[0].propose_batch(&[1; CAP]), Err(Error::Full));
    assert_eq!(w.nodes[0].state(), &before);
    assert!(!w.nodes[0].status().persistence_pending);
    let batch = w.nodes[0].propose_batch(&[10, 20, 30]).unwrap();
    assert_eq!(w.nodes[0].ready().unwrap().write().entries().count(), 3);
    w.save(0);
    w.drain();
    assert!(w.nodes[0].state().hard().commit >= batch.last.index);
}

fn random(seed: &mut u64) -> u64 {
    *seed = seed.wrapping_add(0x9e3779b97f4a7c15);
    let mut value = *seed;
    value = (value ^ (value >> 30)).wrapping_mul(0xbf58476d1ce4e5b9);
    value = (value ^ (value >> 27)).wrapping_mul(0x94d049bb133111eb);
    value ^ (value >> 31)
}

#[test]
fn seeded_reconfiguration_faults_preserve_history_and_recover() {
    let mut transitions = 0;
    let mut finalized = 0;
    for initial_seed in 0..64 {
        let mut seed = initial_seed;
        let mut w = World::new();
        w.elect(0);
        w.learners();
        // Start at each of the four joint/final durability boundaries so every
        // seed exercises a real membership transition, even under heavy loss.
        w.nodes[0]
            .reconfigure(Membership::new(&[Id(0), Id(3), Id(4)], &[Id(1), Id(2), Id(5)]).unwrap())
            .unwrap();
        transitions += 1;
        if initial_seed % 4 >= 1 {
            w.save(0);
        }
        if initial_seed % 4 >= 2 {
            w.drain();
        }
        if initial_seed % 4 >= 3 {
            w.nodes[0].finish_reconfiguration().unwrap();
            finalized += 1;
        }
        let mut leaders = std::collections::HashMap::new();
        for event in 0..2000 {
            let i = random(&mut seed) as usize % MAX;
            let action = random(&mut seed) % 12;
            let idle = !w.nodes[i].status().persistence_pending
                && w.nodes[i].status().messages_pending == 0;
            match action {
                0 if idle => {
                    w.nodes[i].tick().unwrap();
                    w.output(i);
                }
                1 => {
                    w.save(i);
                }
                2 => {
                    w.restart(i);
                }
                3..=4 if !w.network.is_empty() => {
                    let index = random(&mut seed) as usize % w.network.len();
                    let message = w.network.remove(index).unwrap();
                    let (from, to) = (message.from.0 as usize, message.to.0 as usize);
                    if w.links[from][to] {
                        match w.nodes[to].step(&message) {
                            Ok(()) => w.output(to),
                            Err(Error::Busy | Error::Message) => {}
                            error => panic!("seed {initial_seed} event {event}: {error:?}"),
                        }
                    }
                }
                5 if !w.network.is_empty() => {
                    let index = random(&mut seed) as usize % w.network.len();
                    if w.network.len() < 64 {
                        w.network.push_back(w.network[index].clone());
                    }
                }
                6 if idle => {
                    let _ = w.nodes[i].propose(&(event as u64));
                    w.output(i);
                }
                7 if idle => {
                    let voters = if w.nodes[i].membership().is_voter(Id(3)) {
                        [Id(0), Id(1), Id(2)]
                    } else {
                        [Id(0), Id(3), Id(4)]
                    };
                    let learners = (0..MAX)
                        .map(|i| Id(i as u64))
                        .filter(|id| !voters.contains(id))
                        .collect::<Vec<_>>();
                    if w.nodes[i]
                        .reconfigure(Membership::new(&voters, &learners).unwrap())
                        .is_ok()
                    {
                        transitions += 1;
                    }
                    w.output(i);
                }
                8 if idle => {
                    if w.nodes[i].finish_reconfiguration().is_ok() {
                        finalized += 1;
                    }
                    w.output(i);
                }
                9 if idle => {
                    let commit = w.nodes[i].state().hard().commit;
                    let total = w
                        .history
                        .iter()
                        .filter(|e| e.id.index <= commit)
                        .filter_map(|e| match e.value {
                            Some(Record::Command(v)) => Some(v),
                            _ => None,
                        })
                        .sum();
                    let _ = w.nodes[i].compact(commit, &total);
                    w.output(i);
                }
                10 => {
                    let j = random(&mut seed) as usize % MAX;
                    w.links[i][j] = !w.links[i][j];
                }
                _ => {
                    if !w.network.is_empty() {
                        w.network.pop_front();
                    }
                }
            }
            while w.network.len() > 64 {
                w.network.pop_front();
            }
            w.check();
            for node in &w.nodes {
                if node.role() == Role::Leader {
                    let status = node.status();
                    if let Some(previous) = leaders.insert(status.term, status.id) {
                        assert_eq!(
                            previous, status.id,
                            "two leaders: seed {initial_seed} event {event}"
                        );
                    }
                    for entry in &w.history {
                        if entry.id.term < status.term {
                            if let Some(actual) = node
                                .state()
                                .entries()
                                .find(|e| e.id.index == entry.id.index)
                            {
                                assert_eq!(
                                    actual, entry,
                                    "leader completeness: seed {initial_seed}"
                                );
                            }
                        }
                    }
                }
                if let Some(snapshot) = node.snapshot() {
                    let expected: u64 = w
                        .history
                        .iter()
                        .filter(|e| e.id.index <= snapshot.last.index)
                        .filter_map(|e| match e.value {
                            Some(Record::Command(v)) => Some(v),
                            _ => None,
                        })
                        .sum();
                    assert_eq!(
                        snapshot.value.application, expected,
                        "snapshot: seed {initial_seed}"
                    );
                }
            }
        }
        w.links = [[true; MAX]; MAX];
        for i in 0..MAX {
            w.save(i);
        }
        w.drain();
        for _ in 0..100 {
            for i in 0..MAX {
                let commit = w.nodes[i].state().hard().commit;
                let total = w
                    .history
                    .iter()
                    .filter(|e| e.id.index <= commit)
                    .filter_map(|e| match e.value {
                        Some(Record::Command(v)) => Some(v),
                        _ => None,
                    })
                    .sum();
                let _ = w.nodes[i].compact(commit, &total);
                w.save(i);
                w.nodes[i].tick().unwrap();
                w.save(i);
            }
            w.drain();
        }
        let leader = w
            .nodes
            .iter()
            .position(|n| n.role() == Role::Leader)
            .expect("healthy cluster must elect");
        if w.nodes[leader].membership().is_joint() {
            w.nodes[leader].finish_reconfiguration().unwrap();
            w.save(leader);
            w.drain();
            w.healthy();
        }
        let leader = w
            .nodes
            .iter()
            .position(|n| n.role() == Role::Leader)
            .expect("final configuration elects");
        let id = w.nodes[leader].propose(&9999).unwrap();
        w.save(leader);
        w.drain();
        assert!(
            w.nodes[leader].state().hard().commit >= id.index,
            "failed recovery: seed {initial_seed}"
        );
    }
    println!(
        "fault schedules including initial boundaries: {transitions} joint transitions, {finalized} finalizations"
    );
    assert!(transitions >= 64);
    assert!(finalized >= 16);
}

#[test]
fn malformed_batches_are_rejected_before_term_or_log_mutation() {
    let mut w = World::new();
    for malformed in 0..3 {
        let mut entries = core::array::from_fn(|_| None);
        if malformed != 0 {
            entries[0] = Some(Entry {
                id: jarl::LogId { index: 1, term: 1 },
                value: Some(Record::Command(10)),
            });
            entries[if malformed == 1 { 2 } else { 1 }] = Some(Entry {
                id: jarl::LogId { index: 3, term: 1 },
                value: Some(Record::Command(20)),
            });
        }
        let before = w.nodes[1].state().clone();
        let result = w.nodes[1].step(&Envelope {
            from: Id(0),
            to: Id(1),
            message: Message::AppendBatch {
                term: 2,
                previous: jarl::LogId::default(),
                entries,
                commit: 100,
            },
        });
        assert_eq!(result, Err(Error::Message));
        assert_eq!(w.nodes[1].state(), &before);
    }
}

#[test]
fn peer_capacity_can_be_reused_by_new_lifetime_identities() {
    use std::collections::BTreeMap;
    type Small = Cluster<u64, (), 3, 32>;
    type Packet = Envelope<Record<u64, 3>, Checkpoint<(), 3>>;
    fn flush(node: &mut Small, queue: &mut VecDeque<Packet>) {
        if let Some(ready) = node.ready() {
            ready.persisted();
        }
        while let Some(message) = node.next_message() {
            queue.push_back(message.cloned());
        }
    }
    fn drain(nodes: &mut BTreeMap<u64, Small>) {
        let mut queue = VecDeque::new();
        for node in nodes.values_mut() {
            flush(node, &mut queue);
        }
        while let Some(message) = queue.pop_front() {
            if let Some(node) = nodes.get_mut(&message.to.0) {
                node.step(&message).unwrap();
                flush(node, &mut queue);
            }
        }
    }
    let initial = Membership::new(&[Id(0)], &[]).unwrap();
    let mut nodes = [0, 1, 2, 99]
        .into_iter()
        .map(|i| {
            (
                i,
                Small::new(
                    Settings {
                        seed: i + 1,
                        ..Settings::default()
                    },
                    ClusterState::new(Id(i), initial).unwrap(),
                )
                .unwrap(),
            )
        })
        .collect::<BTreeMap<_, _>>();
    for _ in 0..30 {
        nodes.get_mut(&0).unwrap().tick().unwrap();
        drain(&mut nodes);
    }
    nodes
        .get_mut(&0)
        .unwrap()
        .set_learners(&[Id(1), Id(2)])
        .unwrap();
    drain(&mut nodes);
    nodes
        .get_mut(&0)
        .unwrap()
        .reconfigure(Membership::new(&[Id(0), Id(1)], &[]).unwrap())
        .unwrap();
    drain(&mut nodes);
    nodes.get_mut(&0).unwrap().finish_reconfiguration().unwrap();
    drain(&mut nodes);
    nodes.get_mut(&0).unwrap().set_learners(&[Id(99)]).unwrap();
    drain(&mut nodes);
    let target = Membership::new(&[Id(0), Id(99)], &[]).unwrap();
    nodes.get_mut(&0).unwrap().reconfigure(target).unwrap();
    drain(&mut nodes);
    nodes.get_mut(&0).unwrap().finish_reconfiguration().unwrap();
    drain(&mut nodes);
    let id = nodes.get_mut(&0).unwrap().propose(&42).unwrap();
    drain(&mut nodes);
    assert_eq!(nodes[&99].membership(), target);
    assert!(nodes[&99].state().hard().commit >= id.index);
}
