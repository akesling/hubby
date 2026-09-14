use reference::journal;
#[path = "../examples/membership.rs"]
mod reference;
use jarl::{host, Config, Id, Membership, Node, Record, Role, State};
use std::{
    fs,
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
};
static NEXT: AtomicU64 = AtomicU64::new(0);
struct Temp(PathBuf);
impl Temp {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "jarl-dynamic-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
}
impl Drop for Temp {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn durable_reference_host_reconfigures_and_restarts_the_whole_cluster() {
    let dir = Temp::new();
    assert_eq!(reference::run(&dir.0).unwrap(), [42; 4]);
    assert_eq!(reference::run(&dir.0).unwrap(), [84; 4]);
    assert_eq!(reference::run(&dir.0).unwrap(), [126; 4]);
}

#[test]
fn torn_joint_configuration_transaction_recovers_the_previous_membership() {
    let dir = Temp::new();
    let genesis = Membership::new(&[Id(0)], &[]).unwrap();
    let mut journal = journal::Journal::open(&dir.0, 42, Id(0), genesis).unwrap();
    let mut node = Node::<journal::Value, journal::Snap, 1, { journal::CAP }>::new(
        Config::new(Id(0), [Id(0)]),
        State::new(),
    )
    .unwrap();
    while node.role() != Role::Leader {
        node.tick().unwrap();
        if let Some(ready) = node.ready() {
            host::persist(ready, &mut journal).unwrap();
        }
    }
    let before = journal.state.clone();
    let path = dir.0.join("dynamic-0.jarl");
    let boundary = fs::metadata(&path).unwrap().len() as usize;
    let joint = Membership::restore(&[Id(1), Id(2)], &[Id(0)], &[Id(3)]).unwrap();
    node.propose(&Record::Configuration(joint)).unwrap();
    host::persist(node.ready().unwrap(), &mut journal).unwrap();
    let after = journal.state.clone();
    drop(journal);
    let bytes = fs::read(&path).unwrap();
    let copy = Temp::new();
    for end in boundary..bytes.len() {
        fs::write(copy.0.join("dynamic-0.jarl"), &bytes[..end]).unwrap();
        let restored = journal::Journal::open(&copy.0, 42, Id(0), genesis).unwrap();
        assert_eq!(restored.state, before, "torn byte {end}");
    }
    assert_eq!(
        journal::Journal::open(&dir.0, 42, Id(0), genesis)
            .unwrap()
            .state,
        after
    );
    assert!(journal::Journal::open(&dir.0, 43, Id(0), genesis).is_err());
    let mut damaged = bytes;
    let end = damaged.len();
    damaged[end - 1] ^= 1;
    fs::write(copy.0.join("dynamic-0.jarl"), damaged).unwrap();
    assert!(journal::Journal::open(&copy.0, 42, Id(0), genesis).is_err());
}
