//! Three local voters with real durable journals and an in-memory transport.
//! Run twice against the same directory to exercise complete process recovery.
#[path = "support/journal.rs"]
pub(crate) mod journal;

use jarl::{Config, Envelope, Id, Node, Role};
use journal::{Journal, CAP};
use std::{collections::VecDeque, fs, io, path::Path};

struct Host {
    node: Node<u64, u64, 3, CAP>,
    journal: Journal,
    applied: u64,
    total: u64,
}

impl Host {
    fn open(path: &Path, id: Id) -> io::Result<Self> {
        let journal = Journal::open(path, id)?;
        let node = Node::new(
            Config::new(id, [Id(0), Id(1), Id(2)]),
            journal.state.clone(),
        )
        .map_err(io::Error::other)?;
        Ok(Self {
            node,
            journal,
            applied: 0,
            total: 0,
        })
    }

    fn flush(&mut self, network: &mut VecDeque<Envelope<u64, u64>>) -> io::Result<()> {
        if let Some(ready) = self.node.ready() {
            self.journal.save(ready.write())?;
            ready.persisted();
        }
        while let Some(message) = self.node.next_message() {
            network.push_back(message.cloned());
        }
        if let Some(snapshot) = self.node.snapshot().filter(|s| s.last.index > self.applied) {
            self.total = snapshot.value;
            self.applied = snapshot.last.index;
        }
        for entry in self.node.committed().filter(|e| e.id.index > self.applied) {
            self.total = self
                .total
                .checked_add(entry.value.unwrap_or(0))
                .ok_or_else(|| io::Error::other("application overflow"))?;
        }
        self.applied = self.node.state().hard().commit;
        Ok(())
    }
}

fn drain(hosts: &mut [Host], network: &mut VecDeque<Envelope<u64, u64>>) -> io::Result<()> {
    while let Some(message) = network.pop_front() {
        let host = &mut hosts[message.to.0 as usize];
        host.node.step(&message).map_err(io::Error::other)?;
        host.flush(network)?;
    }
    Ok(())
}

pub fn run(path: &Path) -> io::Result<[u64; 3]> {
    match fs::create_dir(path) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
        Err(error) => return Err(error),
    }
    // Persist the directory entry as well as the journal files (Unix reference host).
    fs::File::open(
        path.parent()
            .filter(|p| !p.as_os_str().is_empty())
            .unwrap_or_else(|| Path::new(".")),
    )?
    .sync_all()?;
    let mut hosts = [
        Host::open(path, Id(0))?,
        Host::open(path, Id(1))?,
        Host::open(path, Id(2))?,
    ];
    let mut network = VecDeque::new();
    for host in &mut hosts {
        host.flush(&mut network)?;
    }
    let mut leader = None;
    for _ in 0..100 {
        for host in &mut hosts {
            host.node.tick().map_err(io::Error::other)?;
            host.flush(&mut network)?;
        }
        drain(&mut hosts, &mut network)?;
        leader = hosts
            .iter()
            .position(|host| host.node.role() == Role::Leader);
        if leader.is_some() {
            break;
        }
    }
    let leader = leader.ok_or_else(|| io::Error::other("election did not converge"))?;
    for command in [40, 2] {
        hosts[leader]
            .node
            .propose(&command)
            .map_err(io::Error::other)?;
        hosts[leader].flush(&mut network)?;
        drain(&mut hosts, &mut network)?;
    }
    // Snapshot exactly the applied state; subsequent runs replay only its suffix.
    for host in &mut hosts {
        host.node
            .compact(host.applied, &host.total)
            .map_err(io::Error::other)?;
        host.flush(&mut network)?;
    }
    drain(&mut hosts, &mut network)?;
    Ok(core::array::from_fn(|i| hosts[i].total))
}

#[cfg(not(test))]
fn main() -> io::Result<()> {
    let path = std::env::args_os()
        .nth(1)
        .ok_or_else(|| io::Error::other("usage: cluster <storage-directory>"))?;
    let totals = run(Path::new(&path))?;
    println!("Replicated totals: {totals:?}");
    Ok(())
}
