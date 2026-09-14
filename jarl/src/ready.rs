use crate::{Entry, HardState, Node, Snapshot, State};

/// An atomic storage transaction. Apply in this order:
///
/// 1. If present, replace the snapshot and discard entries through its boundary.
/// 2. If present, remove log entries starting at `truncate_from`.
/// 3. Append `entries()` and replace the hard state.
///
/// Unchanged entries and snapshot contents are not included. The transaction must
/// become durable in full before acknowledging its [`Ready`] token.
pub struct Write<'a, V, S> {
    /// New term, vote, and committed position.
    pub hard: HardState,
    /// A replacement snapshot, only when it changed.
    pub snapshot: Option<&'a Snapshot<S>>,
    /// Beginning of a replaced suffix, including when the replacement is empty.
    pub truncate_from: Option<u64>,
    pub(crate) entries: &'a [Option<Entry<V>>],
}

impl<V, S> Write<'_, V, S> {
    /// Replacement suffix in ascending order. Empty for metadata-only updates.
    pub fn entries(&self) -> impl DoubleEndedIterator<Item = &Entry<V>> {
        self.entries.iter().flatten()
    }
}

/// Exclusive access to one pending storage transaction.
///
/// Save [`Self::write`] (or the complete [`Self::state`]) and then consume this
/// token with [`Self::persisted`]. Dropping it leaves the update pending, allowing
/// retry after a failed save. Holding it across an async save prevents further
/// node operations and acknowledgment of a different update.
///
/// ```compile_fail
/// use jarl::{Config, Id, Node, State};
/// let mut node = Node::<(), (), 1, 8>::new(Config::new(Id(0), [Id(0)]), State::new()).unwrap();
/// # while node.ready().is_none() { node.tick().unwrap(); }
/// let ready = node.ready().unwrap();
/// node.tick().unwrap(); // A pending persistence token exclusively borrows the node.
/// ready.persisted();
/// ```
#[must_use = "save this update before acknowledging it; dropping leaves it pending"]
pub struct Ready<'a, V, S, const N: usize, const CAP: usize> {
    pub(crate) node: &'a mut Node<V, S, N, CAP>,
}

impl<V, S, const N: usize, const CAP: usize> Ready<'_, V, S, N, CAP> {
    /// Incremental changes since the last successful persistence acknowledgment.
    pub fn write(&self) -> Write<'_, V, S> {
        self.node
            .state
            .write(self.node.log_from, self.node.snapshot_changed)
    }

    /// Complete checkpoint, for hosts that prefer atomic checkpoint replacement.
    pub fn state(&self) -> &State<V, S, CAP> {
        &self.node.state
    }

    /// Acknowledge successful durable storage of this exact transaction.
    pub fn persisted(self) {
        self.node.dirty = false;
        self.node.log_from = None;
        self.node.snapshot_changed = false;
    }
}
