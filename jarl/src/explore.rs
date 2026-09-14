//! Bounded schedule exploration. The oracle observes public protocol state;
//! test-only cloning forks executions without adding Clone to the public Node API.
use std::{collections::HashMap, format, string::String, vec, vec::Vec};

use crate::{Config, Entry, Envelope, Id, Node, Role, State};

#[derive(Clone, Debug)]
struct World {
    nodes: [Node<u64, (), 3, 4>; 3],
    disk: [State<u64, (), 4>; 3],
    network: Vec<Envelope<u64, ()>>,
    history: Vec<Entry<u64>>,
    leaders: [Option<Id>; 3],
}

#[derive(Clone, Copy, Debug)]
enum Action {
    Deliver(usize),
    Drop(usize),
    Duplicate(usize),
    Save(usize),
    Crash(usize),
    Timeout(usize),
    Propose(usize),
}

impl World {
    fn config(i: usize) -> Config<3> {
        Config::new(Id(i as u64), [Id(0), Id(1), Id(2)])
    }

    fn new() -> Self {
        Self {
            nodes: core::array::from_fn(|i| Node::new(Self::config(i), State::new()).unwrap()),
            disk: core::array::from_fn(|_| State::new()),
            network: vec![],
            history: vec![],
            leaders: [None; 3],
        }
    }

    fn output(&mut self, i: usize) {
        while let Some(message) = self.nodes[i].next_message() {
            self.network.push(message.cloned());
        }
    }

    fn apply(&mut self, action: Action) {
        match action {
            Action::Deliver(index) => {
                let message = self.network.remove(index);
                let to = message.to.0 as usize;
                self.nodes[to].step(&message).unwrap();
                self.output(to);
            }
            Action::Drop(index) => {
                self.network.remove(index);
            }
            Action::Duplicate(index) => self.network.push(self.network[index].clone()),
            Action::Save(i) => {
                let ready = self.nodes[i].ready().unwrap();
                self.disk[i] = ready.state().clone();
                ready.persisted();
                self.output(i);
            }
            Action::Crash(i) => {
                self.nodes[i] = Node::new(Self::config(i), self.disk[i].clone()).unwrap();
            }
            Action::Timeout(i) => {
                let term = self.nodes[i].state().hard().term;
                while self.nodes[i].state().hard().term == term {
                    self.nodes[i].tick().unwrap();
                }
            }
            Action::Propose(i) => {
                // Different leaders propose different commands at the same index.
                self.nodes[i].propose(&(100 + i as u64)).unwrap();
            }
        }
        // The network is an unordered multiset: delivery actions select any item.
        self.network.sort_by_key(|message| format!("{message:?}"));
    }

    fn check(&mut self, path: &[Action]) {
        for (i, node) in self.nodes.iter_mut().enumerate() {
            if node.role() == Role::Leader {
                let term = node.state().hard().term as usize;
                if let Some(id) = self.leaders[term] {
                    assert_eq!(id, Id(i as u64), "election safety: {path:?}");
                }
                self.leaders[term] = Some(Id(i as u64));
                let earlier = self
                    .history
                    .iter()
                    .take_while(|e| e.id.term < term as u64)
                    .count();
                let log: Vec<_> = node.state().entries().take(earlier).cloned().collect();
                assert_eq!(
                    log,
                    self.history[..earlier],
                    "leader completeness: {path:?}"
                );
            }
            if node.ready().is_some() {
                assert!(
                    node.next_message().is_none(),
                    "unpersisted output: {path:?}"
                );
                assert!(node.committed().next().is_none());
            }
            let applied: Vec<_> = node.committed().cloned().collect();
            for (a, b) in applied.iter().zip(&self.history) {
                assert_eq!(a, b, "state machine safety: {path:?}");
            }
            if applied.len() > self.history.len() {
                self.history = applied;
            }
        }
    }

    fn actions(&mut self) -> Vec<Action> {
        let mut actions = vec![];
        for i in 0..self.network.len() {
            let to = self.network[i].to.0 as usize;
            if self.nodes[to].ready().is_none() {
                actions.push(Action::Deliver(i));
            }
            actions.push(Action::Drop(i));
            if self.network.len() < 4
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
        for i in 0..3 {
            let node = &mut self.nodes[i];
            if node.ready().is_some() {
                actions.push(Action::Save(i));
                actions.push(Action::Crash(i));
            } else if node.role() != Role::Leader && node.state().hard().term < 2 {
                actions.push(Action::Timeout(i));
            }
            if node.ready().is_none()
                && node.role() == Role::Leader
                && node.state().last().index < 2
            {
                actions.push(Action::Propose(i));
            }
            if node.role() != Role::Follower {
                actions.push(Action::Crash(i));
            }
        }
        actions
    }
}

fn visit(mut world: World, left: usize, seen: &mut HashMap<String, usize>, path: &mut Vec<Action>) {
    world.check(path);
    let key = format!("{world:?}");
    if seen.get(&key).is_some_and(|depth| *depth >= left) {
        return;
    }
    seen.insert(key, left);
    if left == 0 {
        return;
    }
    for action in world.actions() {
        let mut next = world.clone();
        next.apply(action);
        path.push(action);
        visit(next, left - 1, seen, path);
        path.pop();
    }
}

#[test]
fn exhaustive_election_and_persistence_schedules() {
    let mut world = World::new();
    // Competing candidates begin with durable self-votes and four queued requests.
    for i in 0..2 {
        world.apply(Action::Timeout(i));
        world.apply(Action::Save(i));
    }
    let mut seen = HashMap::new();
    visit(world, 6, &mut seen, &mut vec![]);
    std::println!("election exploration: {} distinct states", seen.len());
    assert!(seen.len() > 1_000);
}

#[test]
fn exhaustive_commit_and_crash_schedules() {
    let mut world = World::new();
    world.apply(Action::Timeout(0));
    world.apply(Action::Save(0));
    while !world.network.is_empty() {
        world.apply(Action::Deliver(0));
        for i in 0..3 {
            if world.nodes[i].ready().is_some() {
                world.apply(Action::Save(i));
            }
        }
    }
    world.apply(Action::Propose(0));
    let mut seen = HashMap::new();
    visit(world, 6, &mut seen, &mut vec![]);
    std::println!("commit exploration: {} distinct states", seen.len());
    assert!(seen.len() > 1_000);
}
