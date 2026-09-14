//! Optional host adapters. These traits perform no I/O themselves and impose no
//! executor, thread, allocation, or `Send` requirement. Implement them using the
//! consumer's storage system. An async implementation must actually yield while
//! waiting; wrapping blocking I/O in `async fn` does not make it nonblocking.

use crate::{Ready, Write};
use core::future::Future;

/// Synchronous atomic durable storage.
pub trait Storage<V, S> {
    /// Backend-defined failure.
    type Error;
    /// Atomically persist the exact transaction before returning success.
    /// After failure, stop the node or retry only if the backend guarantees its
    /// recovered transaction ordering. Never acknowledge an ambiguous save.
    fn save(&mut self, write: Write<'_, V, S>) -> Result<(), Self::Error>;
}

/// Asynchronous atomic durable storage with consumer-selected futures.
///
/// Cancellation must not permit an older background write to overtake a later
/// transaction. Quiesce or reopen the backend after cancellation if necessary.
/// Dropping the future returned by `persist_async` leaves the node write pending.
pub trait AsyncStorage<V, S> {
    /// Backend-defined failure.
    type Error;
    /// Finish atomic durability before resolving successfully.
    fn save(&mut self, write: Write<'_, V, S>) -> impl Future<Output = Result<(), Self::Error>>;
}

/// Save and acknowledge one transaction using a synchronous backend.
pub fn persist<V, S, B: Storage<V, S>, const N: usize, const CAP: usize>(
    ready: Ready<'_, V, S, N, CAP>,
    storage: &mut B,
) -> Result<(), B::Error> {
    storage.save(ready.write())?;
    ready.persisted();
    Ok(())
}

/// Save and acknowledge one transaction using an asynchronous backend.
/// The exclusive token prevents input processing or output publication while
/// awaiting durability; other nodes and host tasks remain independently runnable.
pub async fn persist_async<V, S, B: AsyncStorage<V, S>, const N: usize, const CAP: usize>(
    ready: Ready<'_, V, S, N, CAP>,
    storage: &mut B,
) -> Result<(), B::Error> {
    storage.save(ready.write()).await?;
    ready.persisted();
    Ok(())
}
