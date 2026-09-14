//! Bounded schedules around durable joint and final configuration records.
use crate::{
    Checkpoint, Cluster, ClusterState, Entry, Envelope, Id, Membership, Record, Role, Settings,
    State,
};
use std::{collections::HashMap, format, string::String, vec, vec::Vec};
type Peer = Cluster<u64, u64, 4, 8>;
type Disk = State<Record<u64, 4>, Checkpoint<u64, 4>, 8>;
type Wire = Envelope<Record<u64, 4>, Checkpoint<u64, 4>>;
#[derive(Clone, Debug)]
struct World {
    nodes: [Peer; 4],
    disk: [Disk; 4],
    network: Vec<Wire>,
    history: Vec<Entry<Record<u64, 4>>>,
    leaders: [Option<Id>; 4],
}
#[derive(Clone, Copy, Debug)]
enum Action {
    Deliver(usize),
    Drop(usize),
    Duplicate(usize),
    Save(usize),
    Crash(usize),
    Timeout(usize),
    Finish(usize),
    Compact(usize),
}
fn genesis() -> Membership<4> {
    Membership::new(&[Id(0), Id(1)], &[Id(2), Id(3)]).unwrap()
}
fn restored(i: usize, disk: Disk) -> Peer {
    Cluster::new(
        Settings {
            seed: i as u64 + 1,
            ..Settings::default()
        },
        ClusterState::restore(Id(i as u64), genesis(), disk).unwrap(),
    )
    .unwrap()
}
impl World {
    fn new() -> Self {
        Self {
            nodes: core::array::from_fn(|i| restored(i, Disk::new())),
            disk: core::array::from_fn(|_| Disk::new()),
            network: vec![],
            history: vec![],
            leaders: [None; 4],
        }
    }
    fn output(&mut self, i: usize) {
        while let Some(m) = self.nodes[i].next_message() {
            self.network.push(m.cloned());
        }
    }
    fn apply(&mut self, action: Action) {
        match action {
            Action::Deliver(i) => {
                let m = self.network.remove(i);
                let to = m.to.0 as usize;
                self.nodes[to].step(&m).unwrap();
                self.output(to);
            }
            Action::Drop(i) => {
                self.network.remove(i);
            }
            Action::Duplicate(i) => self.network.push(self.network[i].clone()),
            Action::Save(i) => {
                let ready = self.nodes[i].ready().unwrap();
                self.disk[i] = ready.state().clone();
                ready.persisted();
                self.output(i);
            }
            Action::Crash(i) => self.nodes[i] = restored(i, self.disk[i].clone()),
            Action::Timeout(i) => {
                for _ in 0..20 {
                    self.nodes[i].tick().unwrap();
                    let status = self.nodes[i].status();
                    if status.persistence_pending || status.messages_pending > 0 {
                        break;
                    }
                }
                self.output(i);
            }
            Action::Finish(i) => {
                self.nodes[i].finish_reconfiguration().unwrap();
                self.output(i);
            }
            Action::Compact(i) => {
                let commit = self.nodes[i].state().hard().commit;
                self.nodes[i].compact(commit, &0).unwrap();
                self.output(i);
            }
        }
        self.network.sort_by_key(|m| format!("{m:?}"));
    }
    fn idle(&self, i: usize) -> bool {
        let s = self.nodes[i].status();
        !s.persistence_pending && s.messages_pending == 0
    }
    fn check(&mut self, path: &[Action]) {
        for node in &mut self.nodes {
            let status = node.status();
            if status.role == Role::Leader {
                if let Some(id) = self.leaders[status.term as usize] {
                    assert_eq!(id, status.id, "election safety: {path:?}");
                }
                self.leaders[status.term as usize] = Some(status.id);
                let base = node.state().snapshot().map_or(0, |s| s.last.index);
                for entry in &self.history {
                    if entry.id.term < status.term && entry.id.index > base {
                        assert_eq!(
                            node.state()
                                .entries()
                                .find(|e| e.id.index == entry.id.index),
                            Some(entry),
                            "leader completeness: {path:?}"
                        );
                    }
                }
            }
            if status.persistence_pending {
                assert!(node.next_message().is_none());
                assert!(node.committed().next().is_none());
                assert!(node.snapshot().is_none());
            }
            for entry in node.committed() {
                if let Some(previous) = self.history.iter().find(|e| e.id.index == entry.id.index) {
                    assert_eq!(previous, entry, "agreement: {path:?}");
                } else {
                    self.history.push(entry.clone());
                }
            }
        }
        self.history.sort_by_key(|e| e.id.index);
    }
    fn actions(&self) -> Vec<Action> {
        let mut actions = vec![];
        for i in 0..self.network.len() {
            if self.idle(self.network[i].to.0 as usize) {
                actions.push(Action::Deliver(i));
            }
            actions.push(Action::Drop(i));
            if self.network.len() < 5
                && self
                    .network
                    .iter()
                    .filter(|m| **m == self.network[i])
                    .count()
                    < 2
            {
                actions.push(Action::Duplicate(i));
            }
        }
        for i in 0..4 {
            let node = &self.nodes[i];
            let status = node.status();
            if status.persistence_pending {
                actions.push(Action::Save(i));
            }
            if status.persistence_pending || status.role != Role::Follower {
                actions.push(Action::Crash(i));
            }
            if self.idle(i) {
                if status.term < 3 && node.membership().is_voter(Id(i as u64)) {
                    actions.push(Action::Timeout(i));
                }
                if status.role == Role::Leader
                    && node.membership().is_joint()
                    && node.node.membership_at(status.last.index).0 <= status.commit
                    && node.remaining() > 0
                {
                    actions.push(Action::Finish(i));
                }
                if status.commit > node.state().snapshot().map_or(0, |s| s.last.index) {
                    actions.push(Action::Compact(i));
                }
            }
        }
        actions
    }
    fn settle(&mut self) {
        loop {
            for i in 0..4 {
                if self.nodes[i].status().persistence_pending {
                    self.apply(Action::Save(i));
                }
            }
            if self.network.is_empty() {
                break;
            }
            self.apply(Action::Deliver(0));
            self.check(&[]);
        }
    }
}
fn visit(
    mut world: World,
    depth: usize,
    seen: &mut HashMap<String, usize>,
    path: &mut Vec<Action>,
) {
    world.check(path);
    let key = format!("{world:?}");
    if seen.get(&key).is_some_and(|previous| *previous >= depth) {
        return;
    }
    seen.insert(key, depth);
    if depth == 0 {
        return;
    }
    for action in world.actions() {
        let mut next = world.clone();
        next.apply(action);
        path.push(action);
        visit(next, depth - 1, seen, path);
        path.pop();
    }
}
#[test]
fn bounded_joint_and_final_configuration_schedules() {
    let mut initial = World::new();
    initial.apply(Action::Timeout(0));
    initial.settle();
    assert_eq!(initial.nodes[0].role(), Role::Leader);
    initial.nodes[0]
        .reconfigure(Membership::new(&[Id(0), Id(2), Id(3)], &[]).unwrap())
        .unwrap();
    for final_stage in [false, true] {
        let mut world = initial.clone();
        if final_stage {
            world.settle();
            world.apply(Action::Finish(0));
        }
        let mut seen = HashMap::new();
        visit(world, 5, &mut seen, &mut vec![]);
        std::println!(
            "dynamic {} exploration: {} states",
            if final_stage { "final" } else { "joint" },
            seen.len()
        );
        assert!(seen.len() > 1000);
    }
}
