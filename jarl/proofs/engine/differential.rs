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
use jarl::host::{persist, Storage};
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

/// The host's storage backend: it applies each transaction in the documented
/// order (replace the snapshot and discard entries through its boundary,
/// truncate, then append and replace the hard state) and never fails.
impl Storage<u64, u64> for Disk {
    type Error = ();
    fn save(&mut self, write: Write<'_, u64, u64>) -> Result<(), ()> {
        apply(self, &write);
        Ok(())
    }
}

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
        let saved = persist(ready, disk);
        let _ = saved;
    }
    while let Some(envelope) = node.next_message() {
        let owned = envelope.cloned();
        let slot = (mix(rng) % SLOTS as u64) as usize;
        net[slot] = Some(owned);
    }
}

pub fn run(seed: u64) -> u64 {
    let digest = fold(fold(fixed(seed), dynamic(seed)), growth(seed));
    fold(digest, rejections(seed))
}

fn fixed(seed: u64) -> u64 {
    let mut rng = seed;
    let mut nodes: [Node<u64, u64, 3, 6>; 3] =
        core::array::from_fn(|i| Node::new(config(i, seed), State::new()).unwrap());
    let mut disks: [Disk; 3] = core::array::from_fn(|_| empty_disk());
    let mut net: [Option<Envelope<u64, u64>>; SLOTS] = core::array::from_fn(|_| None);
    let mut digest: u64 = 0xcbf29ce484222325;
    // A partitioned node (3: none) exchanges no messages until `heal`, so it
    // falls behind the compacting majority (snapshot installation) or
    // diverges from it as a stale leader (conflict truncation).
    let mut isolated = 3;
    let mut heal = 0;
    let mut step = 0;
    while step < 1200 {
        if step >= heal {
            isolated = 3;
        }
        let r = mix(&mut rng);
        let mut i = (r % 3) as usize;
        let action = (r >> 8) % 32;
        // Proposals and compaction go to a leader when there is one.
        if action >= 22 && action <= 27 {
            let mut k = 0;
            while k < 3 {
                if nodes[k].role() == Role::Leader && k != isolated {
                    i = k;
                }
                k += 1;
            }
        }
        if action <= 5 {
            service(&mut nodes[i], &mut disks[i], &mut net, &mut rng);
            digest = fold(digest, u64::from(nodes[i].tick().is_ok()));
        } else if action <= 21 {
            // Deliver the first pending message from a random slot on.
            let start = ((r >> 16) % SLOTS as u64) as usize;
            let mut k = 0;
            let mut found = SLOTS;
            while k < SLOTS && found == SLOTS {
                if net[(start + k) % SLOTS].is_some() {
                    found = (start + k) % SLOTS;
                }
                k += 1;
            }
            if found < SLOTS {
                if let Some(envelope) = net[found].take() {
                    let to = envelope.to.0 as usize;
                    if to != isolated && envelope.from.0 as usize != isolated {
                        service(&mut nodes[to], &mut disks[to], &mut net, &mut rng);
                        let ok = nodes[to].step(&envelope).is_ok();
                        digest = fold(digest, u64::from(ok));
                    }
                }
            }
        } else if action <= 24 {
            service(&mut nodes[i], &mut disks[i], &mut net, &mut rng);
            let proposed = nodes[i].propose(&(r >> 32));
            digest = fold(digest, u64::from(proposed.is_ok()));
        } else if action == 25 {
            service(&mut nodes[i], &mut disks[i], &mut net, &mut rng);
            let proposed = nodes[i].propose_batch(&[r >> 32, r >> 36]);
            digest = fold(digest, u64::from(proposed.is_ok()));
        } else if action <= 27 {
            service(&mut nodes[i], &mut disks[i], &mut net, &mut rng);
            let status = nodes[i].status();
            let ok = nodes[i].compact(status.commit, &(r >> 40)).is_ok();
            digest = fold(digest, u64::from(ok));
        } else if action == 28 {
            service(&mut nodes[i], &mut disks[i], &mut net, &mut rng);
        } else if action == 29 {
            // An operation on a node that may still be busy, and compaction
            // on any node, so followers fill up and reject with `Full`.
            let status = nodes[i].status();
            let ok = nodes[i].compact(status.commit, &(r >> 40)).is_ok();
            digest = fold(digest, u64::from(ok));
            let j = ((r >> 56) % 3) as usize;
            service(&mut nodes[j], &mut disks[j], &mut net, &mut rng);
            let status = nodes[j].status();
            let ok = nodes[j].compact(status.commit, &(r >> 40)).is_ok();
            digest = fold(digest, u64::from(ok));
        } else if action == 30 {
            if isolated == 3 && (r >> 44) % 4 == 0 {
                isolated = i;
                heal = step + 80 + (r >> 48) % 80;
            }
        } else if (r >> 44) % 4 == 0 {
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
    // Valid targets add the learner 3 and remove 2 (possibly the leader);
    // the others are joint, uncaught-up or oversized and must be rejected.
    let target = Membership::new(&[Id(0), Id(1), Id(3)], &[]).unwrap();
    let joint_target = Membership::restore(&[Id(0), Id(1)], &[Id(2)], &[]).unwrap();
    let stranger = Membership::new(&[Id(0), Id(1), Id(2), Id(3)], &[]).unwrap();
    let mut net: [Option<DynEnvelope>; SLOTS] = core::array::from_fn(|_| None);
    let mut digest: u64 = 0x84222325cbf29ce4;
    let mut step = 0;
    while step < 1200 {
        let r = mix(&mut rng);
        let action = (r >> 8) % 32;
        // Proposals and membership changes go to a leader when there is one.
        let mut i = (r % 4) as usize;
        if action >= 20 {
            let mut k = 0;
            while k < 4 {
                if nodes[k].role() == Role::Leader {
                    i = k;
                }
                k += 1;
            }
        }
        // Occasionally operate on a node without servicing it first, so the
        // busy-state rejections run.
        if (r >> 52) % 8 != 0 {
            service_dynamic(&mut nodes[i], &mut net, &mut rng);
        }
        let ok = if action <= 3 {
            nodes[i].tick().is_ok()
        } else if action <= 19 {
            let start = ((r >> 16) % SLOTS as u64) as usize;
            let mut k = 0;
            let mut found = SLOTS;
            while k < SLOTS && found == SLOTS {
                if net[(start + k) % SLOTS].is_some() {
                    found = (start + k) % SLOTS;
                }
                k += 1;
            }
            if found < SLOTS {
                match net[found].take() {
                    Some(envelope) => {
                        let to = envelope.to.0 as usize;
                        service_dynamic(&mut nodes[to], &mut net, &mut rng);
                        nodes[to].step(&envelope).is_ok()
                    }
                    None => false,
                }
            } else {
                false
            }
        } else if action <= 22 {
            nodes[i].propose(&(r >> 32)).is_ok()
        } else if action == 23 {
            nodes[i].propose_batch(&[r >> 32, r >> 40]).is_ok()
        } else if action <= 25 {
            let commit = nodes[i].status().commit;
            nodes[i].compact(commit, &(r >> 40)).is_ok()
        } else if action == 26 {
            nodes[i].set_learners(&[Id(3)]).is_ok()
        } else if action == 27 {
            nodes[i].reconfigure(target).is_ok()
        } else if action == 28 {
            nodes[i].finish_reconfiguration().is_ok()
        } else if action == 29 {
            nodes[i].reconfigure(joint_target).is_ok()
        } else if action == 30 {
            nodes[i].reconfigure(stranger).is_ok()
        } else {
            nodes[i].set_learners(&[Id(3), Id(4)]).is_ok()
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

fn result<T>(r: Result<T, jarl::Error>) -> u64 {
    match r {
        Ok(_) => 0,
        Err(jarl::Error::Config) => 1,
        Err(jarl::Error::State) => 2,
        Err(jarl::Error::Full) => 3,
        Err(jarl::Error::Reconfiguring) => 4,
        Err(jarl::Error::Message) => 6,
        Err(_) => 5,
    }
}

/// Invalid inputs: every validating constructor and guard rejects, with the
/// documented error.
fn rejections(seed: u64) -> u64 {
    let mut digest: u64 = 0x2545f4914f6cdd1d ^ seed;
    let k = seed % 4;
    // Memberships: empty, duplicate voters, a learner that is also a voter,
    // more members than slots.
    digest = fold(digest, result(Membership::<3>::new(&[], &[Id(k)])));
    digest = fold(digest, result(Membership::<3>::new(&[Id(k), Id(k)], &[])));
    digest = fold(digest, result(Membership::<3>::new(&[Id(0)], &[Id(0)])));
    digest = fold(
        digest,
        result(Membership::<2>::new(&[Id(0), Id(1)], &[Id(2)])),
    );
    digest = fold(
        digest,
        result(Membership::<3>::restore(&[Id(0)], &[Id(0), Id(0)], &[])),
    );
    // Node configuration: zero timers, an identity outside the membership,
    // duplicate members, a vote for a stranger.
    let mut bad = Config::new(Id(0), [Id(0), Id(1), Id(2)]);
    bad.heartbeat_ticks = 0;
    digest = fold(digest, result(Node::<u64, u64, 3, 6>::new(bad, State::new())));
    let mut bad = Config::new(Id(0), [Id(0), Id(1), Id(2)]);
    bad.election_ticks = bad.heartbeat_ticks;
    digest = fold(digest, result(Node::<u64, u64, 3, 6>::new(bad, State::new())));
    let stranger = Config::new(Id(7), [Id(0), Id(1), Id(2)]);
    digest = fold(digest, result(Node::<u64, u64, 3, 6>::new(stranger, State::new())));
    let doubled = Config::new(Id(0), [Id(0), Id(0), Id(2)]);
    digest = fold(digest, result(Node::<u64, u64, 3, 6>::new(doubled, State::new())));
    let hard = HardState {
        term: 1,
        voted_for: Some(Id(9)),
        commit: 0,
    };
    let voted = State::restore(hard, None, core::iter::empty()).unwrap();
    digest = fold(
        digest,
        result(Node::<u64, u64, 3, 6>::new(config(0, seed), voted)),
    );
    // Checkpoints: a vote at term zero, a commit beyond the log, a snapshot at
    // index zero, entries that are not consecutive.
    let zero_vote = HardState {
        term: 0,
        voted_for: Some(Id(1)),
        commit: 0,
    };
    digest = fold(
        digest,
        result(State::<u64, u64, 6>::restore(zero_vote, None, core::iter::empty())),
    );
    let ahead = HardState {
        term: 1,
        voted_for: None,
        commit: 3,
    };
    digest = fold(
        digest,
        result(State::<u64, u64, 6>::restore(ahead, None, core::iter::empty())),
    );
    let origin = Snapshot {
        last: jarl::LogId { index: 0, term: 1 },
        value: seed,
    };
    digest = fold(
        digest,
        result(State::<u64, u64, 6>::restore(ahead, Some(origin), core::iter::empty())),
    );
    let gap = [
        Entry {
            id: jarl::LogId { index: 1, term: 1 },
            value: Some(seed),
        },
        Entry {
            id: jarl::LogId { index: 3, term: 1 },
            value: None,
        },
    ];
    digest = fold(
        digest,
        result(State::<u64, u64, 6>::restore(ahead, None, gap.iter().cloned())),
    );
    // Messages from a stranger, and malformed messages, are rejected.
    let mut node = Node::<u64, u64, 3, 6>::new(config(0, seed), State::new()).unwrap();
    let stranger = Envelope {
        from: Id(9),
        to: Id(0),
        message: jarl::Message::Vote {
            term: 1,
            last: jarl::LogId::default(),
        },
    };
    digest = fold(digest, result(node.step(&stranger)));
    let malformed = Envelope {
        from: Id(1),
        to: Id(0),
        message: jarl::Message::Voted {
            term: 0,
            granted: true,
        },
    };
    digest = fold(digest, result(node.step(&malformed)));
    let misaddressed = Envelope {
        from: Id(1),
        to: Id(2),
        message: jarl::Message::Voted {
            term: 1,
            granted: true,
        },
    };
    digest = fold(digest, result(node.step(&misaddressed)));
    // Clusters: capacity below the protocol reserve, an identity in no
    // configuration, and changes that do not fit.
    let genesis = Membership::new(&[Id(0), Id(1)], &[]).unwrap();
    let settings = Settings {
        heartbeat_ticks: 1,
        election_ticks: 2,
        seed,
    };
    digest = fold(
        digest,
        result(Cluster::<u64, u64, 2, 3>::new(
            settings,
            ClusterState::new(Id(0), genesis).unwrap(),
        )),
    );
    let mut solo: Cluster<u64, u64, 2, 8> = Cluster::new(
        settings,
        ClusterState::new(Id(0), Membership::new(&[Id(0)], &[]).unwrap()).unwrap(),
    )
    .unwrap();
    digest = drive_cluster_small(&mut solo, digest);
    digest = fold(digest, result(solo.set_learners(&[Id(1), Id(2)])));
    digest = fold(digest, result(solo.reconfigure(Membership::new(&[Id(1)], &[]).unwrap())));
    digest = fold(digest, result(solo.finish_reconfiguration()));
    digest
}

fn drive_cluster_small(cluster: &mut Cluster<u64, u64, 2, 8>, digest: u64) -> u64 {
    let mut digest = digest;
    let mut k = 0;
    while k < 8 {
        if let Some(ready) = cluster.ready() {
            ready.persisted();
        }
        while cluster.next_message().is_some() {}
        digest = fold(digest, u64::from(cluster.tick().is_ok()));
        k += 1;
    }
    digest
}
