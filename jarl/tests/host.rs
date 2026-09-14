#[path = "../examples/cluster.rs"]
mod cluster;

use cluster::journal::Journal;
use jarl::{Config, Id, Node, Role};
use std::{
    fs,
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
};

static NEXT: AtomicU64 = AtomicU64::new(0);
struct Directory(PathBuf);
impl Directory {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "jarl-host-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
}
impl Drop for Directory {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}

#[test]
fn reference_host_recovers_all_voters_and_snapshots() {
    let directory = Directory::new();
    assert_eq!(cluster::run(&directory.0).unwrap(), [42; 3]);
    assert_eq!(cluster::run(&directory.0).unwrap(), [84; 3]);
    assert_eq!(cluster::run(&directory.0).unwrap(), [126; 3]);
}

#[test]
fn every_torn_frame_boundary_recovers_the_previous_checkpoint() {
    let directory = Directory::new();
    let mut journal = Journal::open(&directory.0, Id(0)).unwrap();
    let mut node =
        Node::<u64, u64, 1, 8>::new(Config::new(Id(0), [Id(0)]), journal.state.clone()).unwrap();
    while node.role() != Role::Leader {
        node.tick().unwrap();
        if let Some(ready) = node.ready() {
            journal.save(ready.write()).unwrap();
            ready.persisted();
        }
    }
    let previous = journal.state.clone();
    let path = directory.0.join("node-0.jarl");
    let prefix = fs::metadata(&path).unwrap().len() as usize;
    node.propose(&42).unwrap();
    let ready = node.ready().unwrap();
    journal.save(ready.write()).unwrap();
    ready.persisted();
    let complete = fs::read(&path).unwrap();
    drop(journal);
    for cut in prefix..complete.len() {
        fs::write(&path, &complete[..cut]).unwrap();
        let recovered = Journal::open(&directory.0, Id(0)).unwrap();
        assert_eq!(recovered.state, previous, "torn frame at byte {cut}");
        assert_eq!(fs::metadata(&path).unwrap().len() as usize, prefix);
    }
    fs::write(&path, &complete).unwrap();
    let recovered = Journal::open(&directory.0, Id(0)).unwrap();
    assert_eq!(recovered.state, *node.state());
}

#[test]
fn complete_corruption_and_wrong_identity_are_rejected() {
    let directory = Directory::new();
    cluster::run(&directory.0).unwrap();
    let path = directory.0.join("node-0.jarl");
    let mut bytes = fs::read(&path).unwrap();
    fs::write(directory.0.join("node-1.jarl"), &bytes).unwrap();
    assert!(Journal::open(&directory.0, Id(1)).is_err());
    *bytes.last_mut().unwrap() ^= 1;
    fs::write(path, bytes).unwrap();
    assert!(Journal::open(&directory.0, Id(0)).is_err());
}

#[test]
fn one_host_exclusively_owns_each_voter_journal() {
    let directory = Directory::new();
    let first = Journal::open(&directory.0, Id(0)).unwrap();
    assert!(Journal::open(&directory.0, Id(0)).is_err());
    drop(first);
    assert!(Journal::open(&directory.0, Id(0)).is_ok());
}
