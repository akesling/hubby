use jarl::{
    host::{self, AsyncStorage, Storage},
    Checkpoint, Cluster, ClusterState, Error, Id, Membership, Record, Role, Settings, State, Write,
};
use std::{
    future::{poll_fn, Future},
    pin::pin,
    task::{Context, Poll, Waker},
};
type Value = Record<u64, 3>;
type Snap = Checkpoint<u64, 3>;
type Disk = State<Value, Snap, 16>;
type Peer = Cluster<u64, u64, 3, 16>;

// A conformance backend: reconstruct every incremental transaction through the
// public restore API, the same contract implemented by a real journal backend.
struct Backend {
    disk: Disk,
    fail: bool,
}
impl Storage<Value, Snap> for Backend {
    type Error = ();
    fn save(&mut self, write: Write<'_, Value, Snap>) -> Result<(), ()> {
        if self.fail {
            return Err(());
        }
        let snapshot = write
            .snapshot
            .cloned()
            .or_else(|| self.disk.snapshot().cloned());
        let base = snapshot.as_ref().map_or(0, |s| s.last.index);
        let entries = self
            .disk
            .entries()
            .filter(|e| {
                e.id.index > base && write.truncate_from.is_none_or(|from| e.id.index < from)
            })
            .cloned()
            .chain(write.entries().cloned());
        self.disk = Disk::restore(write.hard, snapshot, entries).unwrap();
        Ok(())
    }
}
impl AsyncStorage<Value, Snap> for Backend {
    type Error = ();
    async fn save(&mut self, write: Write<'_, Value, Snap>) -> Result<(), ()> {
        let mut pending = true;
        poll_fn(|cx| {
            if pending {
                pending = false;
                cx.waker().wake_by_ref();
                Poll::Pending
            } else {
                Poll::Ready(())
            }
        })
        .await;
        Storage::save(self, write)
    }
}
fn context(waker: &Waker) -> Context<'_> {
    Context::from_waker(waker)
}
fn node() -> (Peer, Backend) {
    let genesis = Membership::new(&[Id(0)], &[]).unwrap();
    let node = Cluster::new(
        Settings::default(),
        ClusterState::new(Id(0), genesis).unwrap(),
    )
    .unwrap();
    (
        node,
        Backend {
            disk: Disk::new(),
            fail: false,
        },
    )
}
fn drive(async_mode: bool) -> Disk {
    let (mut node, mut backend) = node();
    let waker = Waker::noop();
    for _ in 0..30 {
        node.tick().unwrap();
        if let Some(ready) = node.ready() {
            if async_mode {
                let mut future = pin!(host::persist_async(ready, &mut backend));
                assert!(future.as_mut().poll(&mut context(waker)).is_pending());
                assert_eq!(
                    future.as_mut().poll(&mut context(waker)),
                    Poll::Ready(Ok(()))
                );
            } else {
                host::persist(ready, &mut backend).unwrap();
            }
        }
    }
    assert_eq!(node.role(), Role::Leader);
    let ids = node.propose_batch(&[10, 20, 30]).unwrap();
    assert_eq!(ids.last.index - ids.first.index, 2);
    if async_mode {
        let future = host::persist_async(node.ready().unwrap(), &mut backend);
        fn require_send<T: Send>(_: &T) {}
        require_send(&future);
        let mut future = pin!(future);
        assert!(future.as_mut().poll(&mut context(waker)).is_pending());
        assert_eq!(
            future.as_mut().poll(&mut context(waker)),
            Poll::Ready(Ok(()))
        );
    } else {
        host::persist(node.ready().unwrap(), &mut backend).unwrap();
    }
    assert_eq!(node.state(), &backend.disk);
    assert_eq!(
        node.committed()
            .filter(|e| matches!(e.value, Some(Record::Command(_))))
            .count(),
        3
    );
    backend.disk
}
#[test]
fn synchronous_and_pending_async_backends_produce_identical_durable_histories() {
    assert_eq!(drive(false), drive(true));
}

#[test]
fn async_cancellation_and_storage_failure_leave_the_exact_write_pending() {
    let (mut node, mut backend) = node();
    while !node.status().persistence_pending {
        node.tick().unwrap();
    }
    let before = node.state().clone();
    let waker = Waker::noop();
    {
        let future = host::persist_async(node.ready().unwrap(), &mut backend);
        fn require_send<T: Send>(_: &T) {}
        require_send(&future);
        let mut future = pin!(future);
        assert!(future.as_mut().poll(&mut context(waker)).is_pending());
    }
    assert_eq!(node.tick(), Err(Error::Busy));
    assert!(node.committed().next().is_none());
    assert!(node.next_message().is_none());
    assert_eq!(node.state(), &before);
    backend.fail = true;
    assert_eq!(host::persist(node.ready().unwrap(), &mut backend), Err(()));
    assert!(node.status().persistence_pending);
    backend.fail = false;
    host::persist(node.ready().unwrap(), &mut backend).unwrap();
    assert_eq!(backend.disk, before);
    assert!(!node.status().persistence_pending);
}

#[path = "../examples/async_storage.rs"]
mod async_reference;
#[test]
fn actual_async_storage_worker_recovers_committed_application_state() {
    struct Temp(std::path::PathBuf);
    impl Drop for Temp {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    let dir = Temp(std::env::temp_dir().join(format!("jarl-async-worker-{}", std::process::id())));
    assert_eq!(async_reference::run(&dir.0).unwrap(), 42);
    assert_eq!(async_reference::run(&dir.0).unwrap(), 84);
}
