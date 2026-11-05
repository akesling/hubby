//! Differential scenario for Provium's typed translation of Jarl.
//!
//! Provium runs `run` natively and as its Lean translation for every seed and
//! requires identical digests (or identical panics). The scenario drives a
//! three-node fixed cluster whose host persists each `Write` to its own
//! durable copy and restarts nodes from it with `State::restore`, then a
//! four-slot dynamic cluster that adds a learner, promotes it through joint
//! consensus and removes a voter, then single nodes and clusters that grow
//! their log storage, through seeded ticks, deliveries, persistence,
//! proposals, batches and compaction, using only the public API.
use jarl::{
    Checkpoint, Cluster, ClusterState, Config, Entry, Envelope, HardState, Id, Membership, Node,
    Record, Role, Settings, Snapshot, State, Write,
};

const SLOTS: usize = 24;

fn mix(state: &mut u64) -> u64 {
    *state = state.wrapping_add(0x9e3779b97f4a7c15);
    let mut z = *state;
    z = (z ^ (z >> 30)).wrapping_mul(0xbf58476d1ce4e5b9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94d049bb133111eb);
    z ^ (z >> 31)
}

fn fold(digest: u64, value: u64) -> u64 {
    (digest ^ value).wrapping_mul(0x100000001b3)
}

fn role(r: Role) -> u64 {
    match r {
        Role::Follower => 1,
        Role::Candidate => 2,
        Role::Leader => 3,
    }
}

/// A host's durable copy of one node: what it has saved from `Write`s.
struct Disk {
    hard: HardState,
    snapshot: Option<Snapshot<u64>>,
    log: [Option<Entry<u64>>; 6],
    len: usize,
}

fn empty_disk() -> Disk {
    Disk {
        hard: HardState::default(),
        snapshot: None,
        log: core::array::from_fn(|_| None),
        len: 0,
    }
}

/// Apply a storage transaction in the documented order: replace the snapshot
/// and discard entries through its boundary, truncate, then append and
/// replace the hard state.
fn apply(disk: &mut Disk, write: &Write<'_, u64, u64>) {
    if let Some(snapshot) = write.snapshot {
        let mut covered = 0;
        while covered < disk.len
            && disk.log[covered]
                .as_ref()
                .is_some_and(|e| e.id.index <= snapshot.last.index)
        {
            covered += 1;
        }
        let mut k = 0;
        while k + covered < disk.len {
            disk.log[k] = disk.log[k + covered].take();
            k += 1;
        }
        while k < disk.len {
            disk.log[k] = None;
            k += 1;
        }
        disk.len -= covered;
        disk.snapshot = Some(snapshot.clone());
    }
    if let Some(from) = write.truncate_from {
        let mut keep = 0;
        while keep < disk.len && disk.log[keep].as_ref().is_some_and(|e| e.id.index < from) {
            keep += 1;
        }
        let mut k = keep;
        while k < disk.len {
            disk.log[k] = None;
            k += 1;
        }
        disk.len = keep;
    }
    for entry in write.entries() {
        disk.log[disk.len] = Some(entry.clone());
        disk.len += 1;
    }
    disk.hard = write.hard;
}

fn config(i: usize, seed: u64) -> Config<3> {
    let mut config = Config::new(Id(i as u64), [Id(0), Id(1), Id(2)]);
    config.seed = seed.wrapping_add(i as u64);
    config.election_ticks = 4;
    config.heartbeat_ticks = 1;
    config
}

/// Recover node `i` from its durable copy, as after a crash.
fn restart(i: usize, seed: u64, disk: &Disk) -> Option<Node<u64, u64, 3, 6>> {
    let state = State::restore(
        disk.hard,
        disk.snapshot.clone(),
        disk.log.iter().flatten().cloned(),
    )
    .ok()?;
    Node::new(config(i, seed), state).ok()
}

/// Act as the node's host: persist any pending transaction, then move every
/// outgoing message into a random network slot (overwriting drops a message).
fn service(
    node: &mut Node<u64, u64, 3, 6>,
    disk: &mut Disk,
    net: &mut [Option<Envelope<u64, u64>>; SLOTS],
    rng: &mut u64,
) {
    if let Some(ready) = node.ready() {
        apply(disk, &ready.write());
        ready.persisted();
    }
    while let Some(envelope) = node.next_message() {
        let owned = envelope.cloned();
        let slot = (mix(rng) % SLOTS as u64) as usize;
        net[slot] = Some(owned);
    }
}

pub fn run(seed: u64) -> u64 {
    fold(fold(fixed(seed), dynamic(seed)), growth(seed))
}

fn fixed(seed: u64) -> u64 {
    let mut rng = seed;
    let mut nodes: [Node<u64, u64, 3, 6>; 3] =
        core::array::from_fn(|i| Node::new(config(i, seed), State::new()).unwrap());
    let mut disks: [Disk; 3] = core::array::from_fn(|_| empty_disk());
    let mut net: [Option<Envelope<u64, u64>>; SLOTS] = core::array::from_fn(|_| None);
    let mut digest: u64 = 0xcbf29ce484222325;
    let mut step = 0;
    while step < 400 {
        let r = mix(&mut rng);
        let i = (r % 3) as usize;
        let action = (r >> 8) % 10;
        if action <= 1 {
            service(&mut nodes[i], &mut disks[i], &mut net, &mut rng);
            digest = fold(digest, u64::from(nodes[i].tick().is_ok()));
        } else if action <= 4 {
            let slot = ((r >> 16) % SLOTS as u64) as usize;
            if let Some(envelope) = net[slot].take() {
                let to = envelope.to.0 as usize;
                service(&mut nodes[to], &mut disks[to], &mut net, &mut rng);
                let ok = nodes[to].step(&envelope).is_ok();
                digest = fold(digest, u64::from(ok));
            }
        } else if action == 5 {
            service(&mut nodes[i], &mut disks[i], &mut net, &mut rng);
        } else if action == 6 {
            service(&mut nodes[i], &mut disks[i], &mut net, &mut rng);
            let proposed = nodes[i].propose(&(r >> 32));
            digest = fold(digest, u64::from(proposed.is_ok()));
        } else if action == 7 {
            service(&mut nodes[i], &mut disks[i], &mut net, &mut rng);
            let status = nodes[i].status();
            let ok = nodes[i].compact(status.commit, &(r >> 40)).is_ok();
            digest = fold(digest, u64::from(ok));
        } else if action == 8 {
            service(&mut nodes[i], &mut disks[i], &mut net, &mut rng);
            let proposed = nodes[i].propose_batch(&[r >> 32, r >> 36]);
            digest = fold(digest, u64::from(proposed.is_ok()));
        } else {
            // A crash: the node restarts from what its host made durable.
            match restart(i, seed, &disks[i]) {
                Some(node) => {
                    nodes[i] = node;
                    digest = fold(digest, 1);
                }
                None => digest = fold(digest, 0),
            }
        }
        for node in &nodes {
            let status = node.status();
            digest = fold(digest, role(status.role));
            digest = fold(digest, status.term);
            digest = fold(digest, status.commit);
            digest = fold(digest, status.last.index);
            digest = fold(digest, status.last.term);
            digest = fold(digest, status.retained as u64);
            digest = fold(digest, u64::from(status.persistence_pending));
            digest = fold(digest, status.messages_pending as u64);
        }
        step += 1;
    }
    digest
}

type Dyn = Cluster<u64, u64, 4, 8>;
type DynEnvelope = Envelope<Record<u64, 4>, Checkpoint<u64, 4>>;

fn service_dynamic(node: &mut Dyn, net: &mut [Option<DynEnvelope>; SLOTS], rng: &mut u64) {
    if let Some(ready) = node.ready() {
        ready.persisted();
    }
    while let Some(envelope) = node.next_message() {
        let owned = envelope.cloned();
        let slot = (mix(rng) % SLOTS as u64) as usize;
        net[slot] = Some(owned);
    }
}

fn dynamic(seed: u64) -> u64 {
    let mut rng = seed ^ 0x5851f42d4c957f2d;
    let genesis = Membership::new(&[Id(0), Id(1), Id(2)], &[]).unwrap();
    let mut nodes: [Dyn; 4] = core::array::from_fn(|i| {
        let settings = Settings {
            heartbeat_ticks: 1,
            election_ticks: 4,
            seed: seed.wrapping_add(i as u64),
        };
        Cluster::new(settings, ClusterState::new(Id(i as u64), genesis).unwrap()).unwrap()
    });
    let target = Membership::new(&[Id(0), Id(1), Id(3)], &[]).unwrap();
    let mut net: [Option<DynEnvelope>; SLOTS] = core::array::from_fn(|_| None);
    let mut digest: u64 = 0x84222325cbf29ce4;
    let mut step = 0;
    while step < 600 {
        let r = mix(&mut rng);
        let action = (r >> 8) % 11;
        // Membership changes go to a leader when there is one.
        let mut i = (r % 4) as usize;
        if action >= 7 && action <= 9 {
            let mut k = 0;
            while k < 4 {
                if nodes[k].role() == Role::Leader {
                    i = k;
                }
                k += 1;
            }
        }
        service_dynamic(&mut nodes[i], &mut net, &mut rng);
        let ok = if action <= 1 {
            nodes[i].tick().is_ok()
        } else if action <= 4 {
            let slot = ((r >> 16) % SLOTS as u64) as usize;
            match net[slot].take() {
                Some(envelope) => {
                    let to = envelope.to.0 as usize;
                    service_dynamic(&mut nodes[to], &mut net, &mut rng);
                    nodes[to].step(&envelope).is_ok()
                }
                None => false,
            }
        } else if action == 5 {
            nodes[i].propose(&(r >> 32)).is_ok()
        } else if action == 6 {
            let commit = nodes[i].status().commit;
            nodes[i].compact(commit, &(r >> 40)).is_ok()
        } else if action == 7 {
            nodes[i].set_learners(&[Id(3)]).is_ok()
        } else if action == 8 {
            nodes[i].reconfigure(target).is_ok()
        } else if action == 9 {
            nodes[i].finish_reconfiguration().is_ok()
        } else {
            nodes[i].propose_batch(&[r >> 32, r >> 40]).is_ok()
        };
        digest = fold(digest, u64::from(ok));
        for node in &nodes {
            let status = node.status();
            digest = fold(digest, role(status.role));
            digest = fold(digest, status.term);
            digest = fold(digest, status.commit);
            digest = fold(digest, status.last.index);
            digest = fold(digest, status.last.term);
            digest = fold(digest, u64::from(node.membership().is_joint()));
            digest = fold(digest, node.membership().voters().count() as u64);
            digest = fold(digest, node.membership().learners().count() as u64);
        }
        step += 1;
    }
    digest
}

/// Drive a single node until it leads, proposing on the way.
fn drive_node<const CAP: usize>(node: &mut Node<u64, u64, 1, CAP>, steps: u64, digest: u64) -> u64 {
    let mut digest = digest;
    let mut k = 0;
    while k < steps {
        if let Some(ready) = node.ready() {
            ready.persisted();
        }
        while node.next_message().is_some() {}
        digest = fold(digest, u64::from(node.tick().is_ok()));
        digest = fold(digest, u64::from(node.propose(&k).is_ok()));
        k += 1;
    }
    fold(digest, node.status().last.index)
}

fn drive_cluster<const CAP: usize>(
    cluster: &mut Cluster<u64, u64, 1, CAP>,
    steps: u64,
    digest: u64,
) -> u64 {
    let mut digest = digest;
    let mut k = 0;
    while k < steps {
        if let Some(ready) = cluster.ready() {
            ready.persisted();
        }
        while cluster.next_message().is_some() {}
        digest = fold(digest, u64::from(cluster.tick().is_ok()));
        digest = fold(digest, u64::from(cluster.propose(&k).is_ok()));
        k += 1;
    }
    fold(digest, cluster.status().last.index)
}

/// Single-member engines that move to larger log storage mid-run.
fn growth(seed: u64) -> u64 {
    let mut config = Config::new(Id(0), [Id(0)]);
    config.seed = seed;
    config.election_ticks = 2;
    config.heartbeat_ticks = 1;
    let mut small: Node<u64, u64, 1, 4> = Node::new(config, State::new()).unwrap();
    let digest = drive_node(&mut small, 10, 0x6c62272e07bb0142);
    let mut large: Node<u64, u64, 1, 8> = small.grow();
    let digest = drive_node(&mut large, 10, digest);
    let genesis = Membership::new(&[Id(0)], &[]).unwrap();
    let settings = Settings {
        heartbeat_ticks: 1,
        election_ticks: 2,
        seed,
    };
    let mut cluster: Cluster<u64, u64, 1, 4> =
        Cluster::new(settings, ClusterState::new(Id(0), genesis).unwrap()).unwrap();
    let digest = drive_cluster(&mut cluster, 10, digest);
    let mut grown: Cluster<u64, u64, 1, 8> = cluster.grow();
    drive_cluster(&mut grown, 10, digest)
}
