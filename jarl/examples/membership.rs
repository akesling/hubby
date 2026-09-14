//! Durable runtime reconfiguration: three voters -> four voters, with a learner.
//! Run twice against the same directory to validate membership and app recovery.
#[path = "support/dynamic_journal.rs"]
pub(crate) mod journal;
use jarl::{host, Cluster, ClusterState, Envelope, Id, Membership, Record, Role, Settings};
use journal::{Journal, CAP, MAX};
use std::{collections::VecDeque, fs, io, path::Path};
type Peer = Cluster<u64, u64, MAX, CAP>;
type Wire = Envelope<journal::Value, journal::Snap>;
struct Host {
    node: Peer,
    journal: Journal,
    applied: u64,
    total: u64,
}
impl Host {
    fn flush(&mut self, queue: &mut VecDeque<Wire>) -> io::Result<()> {
        if let Some(ready) = self.node.ready() {
            host::persist(ready, &mut self.journal)?;
        }
        while let Some(message) = self.node.next_message() {
            // Bounded transport: dropping at saturation is legal; Raft retries.
            if queue.len() < 32 {
                queue.push_back(message.cloned());
            }
        }
        if let Some(snapshot) = self.node.snapshot().filter(|s| s.last.index > self.applied) {
            self.total = snapshot.value.application;
            self.applied = snapshot.last.index;
        }
        for entry in self.node.committed().filter(|e| e.id.index > self.applied) {
            if let Some(Record::Command(value)) = entry.value {
                self.total = self
                    .total
                    .checked_add(value)
                    .ok_or_else(|| io::Error::other("application overflow"))?;
            }
        }
        self.applied = self.node.state().hard().commit;
        Ok(())
    }
}
fn drain(hosts: &mut [Host], queue: &mut VecDeque<Wire>) -> io::Result<()> {
    while let Some(message) = queue.pop_front() {
        let host = &mut hosts[message.to.0 as usize];
        host.node.step(&message).map_err(io::Error::other)?;
        host.flush(queue)?;
    }
    Ok(())
}
pub fn run(path: &Path) -> io::Result<[u64; 4]> {
    match fs::create_dir(path) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
        Err(error) => return Err(error),
    }
    fs::File::open(
        path.parent()
            .filter(|p| !p.as_os_str().is_empty())
            .unwrap_or_else(|| Path::new(".")),
    )?
    .sync_all()?;
    let genesis = Membership::new(&[Id(0), Id(1), Id(2)], &[]).map_err(io::Error::other)?;
    let mut hosts = (0..4)
        .map(|i| {
            let journal = Journal::open(path, 2026, Id(i), genesis)?;
            let saved = ClusterState::restore(Id(i), genesis, journal.state.clone())
                .map_err(io::Error::other)?;
            let node = Cluster::new(
                Settings {
                    seed: i + 1,
                    ..Settings::default()
                },
                saved,
            )
            .map_err(io::Error::other)?;
            Ok(Host {
                node,
                journal,
                applied: 0,
                total: 0,
            })
        })
        .collect::<io::Result<Vec<_>>>()?;
    let mut queue = VecDeque::with_capacity(32);
    for host in &mut hosts {
        host.flush(&mut queue)?;
    }
    let mut leader = None;
    for _ in 0..100 {
        for host in &mut hosts {
            host.node.tick().map_err(io::Error::other)?;
            host.flush(&mut queue)?;
        }
        drain(&mut hosts, &mut queue)?;
        leader = hosts.iter().position(|h| h.node.role() == Role::Leader);
        if leader.is_some() {
            break;
        }
    }
    let leader = leader.ok_or_else(|| io::Error::other("election did not converge"))?;
    // Resume an interrupted joint transition before starting another operation.
    if hosts[leader].node.membership().is_joint() {
        hosts[leader]
            .node
            .finish_reconfiguration()
            .map_err(io::Error::other)?;
        hosts[leader].flush(&mut queue)?;
        drain(&mut hosts, &mut queue)?;
    }
    if !hosts[leader].node.membership().is_voter(Id(3)) {
        hosts[leader]
            .node
            .set_learners(&[Id(3)])
            .map_err(io::Error::other)?;
        hosts[leader].flush(&mut queue)?;
        drain(&mut hosts, &mut queue)?;
        hosts[leader]
            .node
            .reconfigure(
                Membership::new(&[Id(0), Id(1), Id(2), Id(3)], &[]).map_err(io::Error::other)?,
            )
            .map_err(io::Error::other)?;
        hosts[leader].flush(&mut queue)?;
        drain(&mut hosts, &mut queue)?;
        hosts[leader]
            .node
            .finish_reconfiguration()
            .map_err(io::Error::other)?;
        hosts[leader].flush(&mut queue)?;
        drain(&mut hosts, &mut queue)?;
    }
    hosts[leader]
        .node
        .propose_batch(&[40, 2])
        .map_err(io::Error::other)?;
    hosts[leader].flush(&mut queue)?;
    drain(&mut hosts, &mut queue)?;
    for host in &mut hosts {
        host.node
            .compact(host.applied, &host.total)
            .map_err(io::Error::other)?;
        host.flush(&mut queue)?;
    }
    drain(&mut hosts, &mut queue)?;
    Ok(core::array::from_fn(|i| hosts[i].total))
}
#[cfg(not(test))]
fn main() -> io::Result<()> {
    let path = std::env::args_os()
        .nth(1)
        .ok_or_else(|| io::Error::other("usage: membership <storage-directory>"))?;
    println!("Four voters: {:?}", run(Path::new(&path))?);
    Ok(())
}
