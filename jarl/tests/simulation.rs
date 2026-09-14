use std::collections::BTreeMap;

use jarl::{Config, Entry, Envelope, Error, Id, LogId, Node, Role, State};

type History = Vec<Entry<u64>>;

struct Cluster<const N: usize, const CAP: usize> {
    nodes: [Node<u64, History, N, CAP>; N],
    disk: [State<u64, History, CAP>; N],
    applied: [History; N],
    network: Vec<Envelope<u64, History>>,
    links: [[bool; N]; N],
    elected: BTreeMap<u64, Id>,
    committed: History,
    boots: [u64; N],
}

impl<const N: usize, const CAP: usize> Cluster<N, CAP> {
    fn new(seed: u64) -> Self {
        Self {
            nodes: core::array::from_fn(|i| {
                let mut config = Config::new(Id(i as u64), core::array::from_fn(|j| Id(j as u64)));
                config.seed = seed.wrapping_mul(N as u64).wrapping_add(i as u64);
                Node::new(config, State::new()).unwrap()
            }),
            disk: core::array::from_fn(|_| State::new()),
            applied: core::array::from_fn(|_| vec![]),
            network: vec![],
            links: [[true; N]; N],
            elected: BTreeMap::new(),
            committed: vec![],
            boots: [0; N],
        }
    }

    fn finish(&mut self, i: usize) {
        let node = &mut self.nodes[i];
        if let Some(ready) = node.ready() {
            let write = ready.write();
            let saved = &self.disk[i];
            let snapshot = write.snapshot.or(saved.snapshot()).cloned();
            let base = snapshot.as_ref().map_or(0, |s| s.last.index);
            let entries: Vec<_> = saved
                .entries()
                .filter(|e| {
                    e.id.index > base && write.truncate_from.is_none_or(|from| e.id.index < from)
                })
                .chain(write.entries())
                .cloned()
                .collect();
            self.disk[i] = State::restore(write.hard, snapshot, entries).unwrap();
            assert_eq!(
                &self.disk[i],
                ready.state(),
                "incremental save differs from checkpoint"
            );
            ready.persisted();
        }
        while let Some(message) = node.next_message() {
            self.network.push(message.cloned());
        }
        if node.role() == Role::Leader {
            let term = node.state().hard().term;
            if let Some(previous) = self.elected.insert(term, Id(i as u64)) {
                assert_eq!(previous, Id(i as u64), "two leaders in term {term}");
            }
            // An older, isolated leader need not contain later-term commits.
            let history: History = node
                .snapshot()
                .map_or_else(Vec::new, |s| s.value.clone())
                .into_iter()
                .chain(node.state().entries().cloned())
                .collect();
            let earlier = self
                .committed
                .iter()
                .take_while(|entry| entry.id.term < term)
                .count();
            assert!(history.len() >= earlier, "leader lost committed entries");
            assert_eq!(&history[..earlier], &self.committed[..earlier]);
        }
        if let Some(snapshot) = node.snapshot() {
            assert_eq!(snapshot.value.len() as u64, snapshot.last.index);
            for (a, b) in self.applied[i].iter().zip(&snapshot.value) {
                assert_eq!(a, b, "installed snapshot disagrees with applied history");
            }
            if snapshot.value.len() > self.applied[i].len() {
                self.applied[i] = snapshot.value.clone();
            }
        }
        for entry in node.committed() {
            let offset = entry.id.index as usize - 1;
            if offset == self.applied[i].len() {
                self.applied[i].push(entry.clone());
            } else {
                assert_eq!(
                    self.applied[i].get(offset),
                    Some(entry),
                    "application gap or overwrite"
                );
            }
        }
        for (a, b) in self.applied[i].iter().zip(&self.committed) {
            assert_eq!(a, b, "nodes applied different commands at one index");
        }
        if self.applied[i].len() > self.committed.len() {
            self.committed = self.applied[i].clone();
        }
    }

    fn deliver(&mut self, position: usize) {
        let message = self.network.remove(position);
        let from = message.from.0 as usize;
        let to = message.to.0 as usize;
        if self.links[from][to] {
            self.nodes[to].step(&message).unwrap();
            self.finish(to);
        }
    }

    fn drain(&mut self) {
        for _ in 0..10_000 {
            if self.network.is_empty() {
                return;
            }
            self.deliver(0);
        }
        panic!("message exchange failed to quiesce");
    }

    fn tick(&mut self) {
        for i in 0..N {
            self.nodes[i].tick().unwrap();
            self.finish(i);
        }
    }

    fn elect(&mut self, i: usize) {
        for _ in 0..100 {
            self.nodes[i].tick().unwrap();
            self.finish(i);
            self.drain();
            if self.nodes[i].role() == Role::Leader {
                return;
            }
        }
        panic!("node {i} could not win election");
    }

    fn leader(&self) -> Option<usize> {
        (0..N)
            .filter(|i| self.nodes[*i].role() == Role::Leader)
            .max_by_key(|i| self.nodes[*i].state().hard().term)
    }

    fn settle(&mut self) {
        self.links = [[true; N]; N];
        for _ in 0..100 {
            self.tick();
            self.drain();
            self.compact();
            self.drain();
        }
        assert!(self.leader().is_some());
    }

    fn isolate(&mut self, i: usize) {
        for j in 0..N {
            self.links[i][j] = false;
            self.links[j][i] = false;
        }
    }

    fn propose(&mut self, i: usize, value: u64) -> Result<LogId, Error> {
        let result = self.nodes[i].propose(&value);
        self.finish(i);
        result
    }

    fn compact(&mut self) {
        for i in 0..N {
            let base = self.nodes[i].snapshot().map_or(0, |s| s.last.index);
            let commit = self.nodes[i].state().hard().commit;
            if commit - base >= (CAP / 2).clamp(1, 8) as u64 {
                self.nodes[i].compact(commit, &self.applied[i]).unwrap();
                self.finish(i);
            }
        }
    }

    fn restart(&mut self, i: usize) {
        self.boots[i] += 1;
        let mut config = Config::new(Id(i as u64), core::array::from_fn(|j| Id(j as u64)));
        config.seed = self.boots[i] * N as u64 + i as u64;
        let saved = &self.disk[i];
        // Exercise the public serialization boundary, not just State::clone.
        let restored = State::restore(
            saved.hard(),
            saved.snapshot().cloned(),
            saved.entries().cloned(),
        )
        .unwrap();
        self.nodes[i] = Node::new(config, restored).unwrap();
        self.applied[i].clear();
        self.finish(i);
    }
}

#[test]
fn partitioned_leader_cannot_commit_and_its_suffix_is_repaired() {
    let mut c = Cluster::<3, 16>::new(1);
    c.elect(0);
    c.propose(0, 7).unwrap();
    c.drain();
    c.isolate(0);
    let lost = c.propose(0, 99).unwrap();
    c.drain();
    assert!(c.nodes[0].state().hard().commit < lost.index);
    c.elect(1);
    let kept = c.propose(1, 8).unwrap();
    c.drain();
    assert!(c.nodes[1].state().hard().commit >= kept.index);
    c.settle();
    for history in &c.applied {
        assert_eq!(history, &c.committed);
        assert!(!history.iter().any(|entry| entry.value == Some(99)));
        assert!(history
            .iter()
            .any(|entry| entry.id == kept && entry.value == Some(8)));
    }
}

#[test]
fn lagging_follower_recovers_via_snapshot_and_retained_suffix() {
    let mut c = Cluster::<3, 4>::new(2);
    c.elect(0);
    c.isolate(2);
    for value in 1..20 {
        c.propose(0, value).unwrap();
        c.drain();
        c.compact();
        c.drain();
    }
    assert!(c.nodes[0].snapshot().unwrap().last.index > c.nodes[2].state().last().index);
    c.settle();
    assert_eq!(c.applied[2], c.committed);
    assert_eq!(
        c.applied[2].iter().filter(|e| e.value.is_some()).count(),
        19
    );
    c.restart(2);
    assert_eq!(c.applied[2], c.committed);
}

#[test]
fn all_voters_restart_from_durable_snapshots_and_logs() {
    let mut c = Cluster::<5, 8>::new(3);
    c.elect(0);
    for value in 0..12 {
        c.propose(0, value).unwrap();
        c.drain();
        c.compact();
        c.drain();
    }
    let before = c.committed.clone();
    for i in 0..5 {
        c.restart(i);
    }
    c.settle();
    let leader = c.leader().unwrap();
    c.propose(leader, 100).unwrap();
    c.drain();
    for history in &c.applied {
        assert_eq!(&history[..before.len()], before.as_slice());
        assert_eq!(history.last().unwrap().value, Some(100));
    }
}

#[test]
fn even_membership_requires_a_strict_majority() {
    let mut c = Cluster::<4, 8>::new(4);
    c.elect(0);
    c.isolate(2);
    c.isolate(3);
    let pending = c.propose(0, 42).unwrap();
    c.drain();
    assert!(c.nodes[0].state().hard().commit < pending.index);
    c.links[0][2] = true;
    c.links[2][0] = true;
    c.tick();
    c.drain();
    c.tick();
    c.drain();
    assert_eq!(c.nodes[0].state().hard().commit, pending.index);
}

#[test]
fn responses_delayed_beyond_heartbeat_interval_still_make_progress() {
    let mut c = Cluster::<3, 16>::new(5);
    c.elect(0);
    let pending = c.propose(0, 42).unwrap();
    // Heartbeats can overtake acknowledgments without invalidating them.
    for _ in 0..8 {
        c.nodes[0].tick().unwrap();
        c.finish(0);
    }
    while !c.network.is_empty() {
        c.deliver(c.network.len() - 1);
    }
    assert_eq!(c.nodes[0].state().hard().commit, pending.index);
}

fn random(seed: &mut u64) -> u64 {
    *seed ^= *seed << 13;
    *seed ^= *seed >> 7;
    *seed ^= *seed << 17;
    *seed
}

fn simulate<const N: usize>(seed: u64) {
    let mut rng = seed + 1;
    let mut c = Cluster::<N, 512>::new(seed);
    c.elect(0);
    for event in 0..2_000 {
        let choice = random(&mut rng);
        match choice % 100 {
            0..=44 if !c.network.is_empty() => {
                let index = random(&mut rng) as usize % c.network.len();
                c.deliver(index);
            }
            45..=49 if !c.network.is_empty() => {
                let index = random(&mut rng) as usize % c.network.len();
                c.network.remove(index); // Drop.
            }
            50..=54 if !c.network.is_empty() => {
                let index = random(&mut rng) as usize % c.network.len();
                c.network.push(c.network[index].clone()); // Duplicate.
            }
            55..=69 => c.tick(),
            70..=79 => {
                if let Some(leader) = c.leader() {
                    let result = c.propose(leader, event);
                    assert!(result.is_ok() || result == Err(Error::Full));
                }
            }
            80..=83 => c.isolate(random(&mut rng) as usize % N),
            84..=87 => c.links = [[true; N]; N],
            88..=91 => c.restart(random(&mut rng) as usize % N),
            92..=94 => {
                let from = random(&mut rng) as usize % N;
                let to = random(&mut rng) as usize % N;
                c.links[from][to] = false; // Asymmetric partition.
            }
            _ => {}
        }
        c.compact();
        if event % 200 == 199 {
            // Alternate hostile schedules with periods of reliable delivery.
            c.settle();
            c.propose(c.leader().unwrap(), event).unwrap();
            c.drain();
        }
        // Bound the simulated transport independently of the core's bounded outbox.
        if c.network.len() > 512 {
            c.network.remove(0);
        }
    }
    c.settle();
    let leader = c.leader().unwrap();
    c.propose(leader, u64::MAX).unwrap();
    c.drain();
    c.settle();
    for history in &c.applied {
        assert_eq!(history, &c.committed, "failed to converge with seed {seed}");
        assert!(history.iter().any(|entry| entry.value == Some(u64::MAX)));
    }
}

#[test]
fn seeded_fault_schedules_preserve_safety_and_recover() {
    for seed in 0..32 {
        simulate::<3>(seed);
        simulate::<5>(seed);
    }
}
