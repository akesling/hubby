use crate::{Entry, Error, Id, LogId, Snapshot, Write};

/// Metadata persisted atomically with the log and snapshot.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct HardState {
    /// Highest observed election term.
    pub term: u64,
    /// Peer voted for in this term.
    pub voted_for: Option<Id>,
    /// Highest committed index.
    pub commit: u64,
}

/// An owned, bounded checkpoint. Its private layout is not a serialization format.
///
/// Persist [`Self::hard`], [`Self::snapshot`], and [`Self::entries`] as one logical
/// transaction. Reconstruct with [`Self::restore`], using the original membership
/// and node identity. A larger capacity can be chosen during reconstruction.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct State<V, S, const CAP: usize> {
    pub(crate) hard: HardState,
    pub(crate) snapshot: Option<Snapshot<S>>,
    entries: [Option<Entry<V>>; CAP],
    len: usize,
}

impl<V, S, const CAP: usize> Default for State<V, S, CAP> {
    fn default() -> Self {
        Self::new()
    }
}

impl<V, S, const CAP: usize> State<V, S, CAP> {
    /// Empty state for a new cluster member. Never use this to restart an existing voter.
    pub fn new() -> Self {
        Self {
            hard: HardState::default(),
            snapshot: None,
            entries: core::array::from_fn(|_| None),
            len: 0,
        }
    }

    /// Restore an ordered, contiguous checkpoint, rejecting inconsistent metadata.
    pub fn restore(
        hard: HardState,
        snapshot: Option<Snapshot<S>>,
        entries: impl IntoIterator<Item = Entry<V>>,
    ) -> Result<Self, Error> {
        let mut state = Self::new();
        state.hard = hard;
        state.snapshot = snapshot;
        let base = state.base();
        if (state.snapshot.is_some() && (base.index == 0 || base.term == 0))
            || base.term > hard.term
            || (hard.term == 0 && hard.voted_for.is_some())
        {
            return Err(Error::State);
        }
        for entry in entries {
            let last = state.last();
            if last.index.checked_add(1) != Some(entry.id.index)
                || entry.id.term == 0
                || entry.id.term < last.term
                || entry.id.term > hard.term
            {
                return Err(Error::State);
            }
            state.push(entry)?;
        }
        if hard.commit < base.index || hard.commit > state.last().index {
            return Err(Error::State);
        }
        Ok(state)
    }

    /// Current persistent metadata.
    pub fn hard(&self) -> HardState {
        self.hard
    }

    /// Latest snapshot, if compaction or installation has occurred.
    pub fn snapshot(&self) -> Option<&Snapshot<S>> {
        self.snapshot.as_ref()
    }

    /// Retained entries in ascending index order, including uncommitted entries.
    pub fn entries(&self) -> impl DoubleEndedIterator<Item = &Entry<V>> {
        self.entries[..self.len].iter().flatten()
    }

    /// Last retained entry, or the snapshot boundary when the suffix is empty.
    pub fn last(&self) -> LogId {
        self.entries().next_back().map_or(self.base(), |e| e.id)
    }

    pub(crate) fn base(&self) -> LogId {
        self.snapshot.as_ref().map_or(LogId::default(), |s| s.last)
    }

    pub(crate) fn write(&self, from: Option<u64>, snapshot_changed: bool) -> Write<'_, V, S> {
        let offset = from.map_or(self.len, |index| {
            usize::try_from(index.saturating_sub(self.base().index).saturating_sub(1))
                .unwrap_or(self.len)
                .min(self.len)
        });
        Write {
            hard: self.hard,
            snapshot: self.snapshot.as_ref().filter(|_| snapshot_changed),
            truncate_from: from,
            entries: &self.entries[offset..self.len],
        }
    }

    pub(crate) fn grow<const NEW: usize>(mut self) -> State<V, S, NEW> {
        const {
            assert!(NEW >= CAP, "new capacity must not be smaller");
        }
        State {
            hard: self.hard,
            snapshot: self.snapshot.take(),
            entries: core::array::from_fn(|i| {
                if i < self.len {
                    self.entries[i].take()
                } else {
                    None
                }
            }),
            len: self.len,
        }
    }

    pub(crate) fn get(&self, index: u64) -> Option<&Entry<V>> {
        let offset = index.checked_sub(self.base().index)?.checked_sub(1)?;
        let offset = usize::try_from(offset).ok()?;
        self.entries.get(offset)?.as_ref()
    }

    pub(crate) fn id_at(&self, index: u64) -> Option<LogId> {
        if index == self.base().index {
            Some(self.base())
        } else {
            self.get(index).map(|e| e.id)
        }
    }

    pub(crate) fn full(&self) -> bool {
        self.len == CAP
    }

    pub(crate) fn push(&mut self, entry: Entry<V>) -> Result<(), Error> {
        if self.full() {
            return Err(Error::Full);
        }
        self.entries[self.len] = Some(entry);
        self.len += 1;
        Ok(())
    }

    pub(crate) fn truncate(&mut self, from: u64) {
        while self.last().index >= from && self.len > 0 {
            self.len -= 1;
            self.entries[self.len] = None;
        }
    }

    pub(crate) fn install(&mut self, snapshot: Snapshot<S>) {
        if self.id_at(snapshot.last.index) == Some(snapshot.last) {
            let remove = (snapshot.last.index - self.base().index) as usize;
            self.entries[..self.len].rotate_left(remove);
            self.len -= remove;
            for entry in &mut self.entries[self.len..] {
                *entry = None;
            }
        } else {
            for entry in &mut self.entries[..self.len] {
                *entry = None;
            }
            self.len = 0;
        }
        self.hard.commit = self.hard.commit.max(snapshot.last.index);
        self.snapshot = Some(snapshot);
    }
}
