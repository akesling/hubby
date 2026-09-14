//! Executor-independent async durability using a bounded storage worker.
//! Startup and shutdown are synchronous; the running protocol never blocks on I/O.
#[path = "support/dynamic_journal.rs"]
pub(crate) mod journal;
use jarl::{
    host::{self, AsyncStorage},
    Cluster, ClusterState, Id, Membership, Record, Role, Settings, Write,
};
use journal::{Journal, CAP, MAX};
use std::{
    fs,
    future::{poll_fn, Future},
    io,
    path::Path,
    pin::pin,
    sync::{mpsc, Arc, Mutex},
    task::{Context, Poll, Wake, Waker},
    thread,
};
#[derive(Default)]
struct Completion {
    result: Option<io::Result<()>>,
    waker: Option<Waker>,
}
struct Job {
    bytes: Vec<u8>,
    completion: Arc<Mutex<Completion>>,
}
struct Worker {
    sender: mpsc::SyncSender<Job>,
    thread: thread::JoinHandle<()>,
}
impl Worker {
    fn new(mut journal: Journal) -> Self {
        let (sender, receiver) = mpsc::sync_channel::<Job>(1);
        let thread = thread::spawn(move || {
            while let Ok(job) = receiver.recv() {
                let result = journal.save_encoded(job.bytes);
                let mut completion = job.completion.lock().unwrap();
                completion.result = Some(result);
                let waker = completion.waker.take();
                drop(completion);
                if let Some(waker) = waker {
                    waker.wake();
                }
            }
        });
        Self { sender, thread }
    }
    fn close(self) -> io::Result<()> {
        drop(self.sender);
        self.thread
            .join()
            .map_err(|_| io::Error::other("storage worker panicked"))
    }
}
impl AsyncStorage<journal::Value, journal::Snap> for Worker {
    type Error = io::Error;
    async fn save(&mut self, write: Write<'_, journal::Value, journal::Snap>) -> io::Result<()> {
        let completion = Arc::new(Mutex::new(Completion::default()));
        let job = Job {
            bytes: journal::encode(&write),
            completion: completion.clone(),
        };
        self.sender
            .try_send(job)
            .map_err(|error| io::Error::other(error.to_string()))?;
        poll_fn(|cx| {
            let mut state = completion.lock().unwrap();
            if let Some(result) = state.result.take() {
                Poll::Ready(result)
            } else {
                state.waker = Some(cx.waker().clone());
                Poll::Pending
            }
        })
        .await
    }
}
struct ThreadWake(thread::Thread);
impl Wake for ThreadWake {
    fn wake(self: Arc<Self>) {
        self.0.unpark();
    }
    fn wake_by_ref(self: &Arc<Self>) {
        self.0.unpark();
    }
}
// Minimal example executor. Consumers can await the same future in their own runtime.
fn block_on<F: Future>(future: F) -> F::Output {
    let waker = Waker::from(Arc::new(ThreadWake(thread::current())));
    let mut context = Context::from_waker(&waker);
    let mut future = pin!(future);
    loop {
        match future.as_mut().poll(&mut context) {
            Poll::Ready(value) => return value,
            Poll::Pending => thread::park(),
        }
    }
}
pub fn run(path: &Path) -> io::Result<u64> {
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
    let genesis = Membership::new(&[Id(0)], &[]).map_err(io::Error::other)?;
    let journal = Journal::open(path, 2027, Id(0), genesis)?;
    let mut node = Cluster::<u64, u64, MAX, CAP>::new(
        Settings::default(),
        ClusterState::restore(Id(0), genesis, journal.state.clone()).map_err(io::Error::other)?,
    )
    .map_err(io::Error::other)?;
    let mut worker = Worker::new(journal);
    let result = block_on(async {
        while node.role() != Role::Leader {
            node.tick().map_err(io::Error::other)?;
            if let Some(ready) = node.ready() {
                host::persist_async(ready, &mut worker).await?;
            }
        }
        node.propose_batch(&[40, 2]).map_err(io::Error::other)?;
        host::persist_async(node.ready().unwrap(), &mut worker).await?;
        let mut total = node.snapshot().map_or(0, |s| s.value.application);
        for entry in node.committed() {
            if let Some(Record::Command(value)) = entry.value {
                total += value;
            }
        }
        node.compact(node.state().hard().commit, &total)
            .map_err(io::Error::other)?;
        host::persist_async(node.ready().unwrap(), &mut worker).await?;
        Ok(total)
    });
    worker.close()?;
    result
}
#[cfg(not(test))]
fn main() -> io::Result<()> {
    let path = std::env::args_os()
        .nth(1)
        .ok_or_else(|| io::Error::other("usage: async_storage <storage-directory>"))?;
    println!("Durable total: {}", run(Path::new(&path))?);
    Ok(())
}
