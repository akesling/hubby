//! A bounded FIFO queue, the typed backend's example subject.
#![no_std]

/// Why an operation failed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
    /// The queue holds `N` items.
    Full,
    /// The queue holds no items.
    Empty,
}

impl core::fmt::Display for Error {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            Error::Full => f.write_str("queue full"),
            Error::Empty => write!(f, "queue empty ({} items)", 0u8),
        }
    }
}

/// A consumer's destination for drained items.
pub trait Sink<T> {
    /// Why the sink refused an item.
    type Error;
    /// Accept one item.
    fn put(&mut self, item: T) -> Result<(), Self::Error>;
}

/// An asynchronous destination; dropping a `put` future leaves the item unsent.
pub trait AsyncSink<T> {
    /// Why the sink refused an item.
    type Error;
    /// Accept one item.
    fn put(&mut self, item: T) -> impl core::future::Future<Output = Result<(), Self::Error>>;
}

/// At most `N` items in insertion order, stored in a ring.
#[derive(Clone, Debug)]
pub struct Queue<T, const N: usize> {
    slots: [Option<T>; N],
    head: usize,
    len: usize,
    pushed: u64,
}

impl<T: Clone, const N: usize> Queue<T, N> {
    /// An empty queue.
    pub fn new() -> Self {
        Self {
            slots: core::array::from_fn(|_| None),
            head: 0,
            len: 0,
            pushed: 0,
        }
    }

    /// Number of queued items.
    pub fn len(&self) -> usize {
        self.len
    }

    /// Whether no item is queued.
    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    /// Append an item, failing when full.
    pub fn push(&mut self, item: T) -> Result<(), Error> {
        if self.len == N {
            return Err(Error::Full);
        }
        let tail = (self.head + self.len) % N;
        self.slots[tail] = Some(item);
        self.len += 1;
        self.pushed = self.pushed.wrapping_add(1);
        Ok(())
    }

    /// Append a copy of an item, failing when full. The copy is made only once
    /// there is room: a full queue never runs `T::clone`.
    pub fn push_cloned(&mut self, item: &T) -> Result<(), Error> {
        self.push_all(core::iter::once_with(|| item.clone()))
    }

    /// Append items in order while there is room.
    pub fn push_all(&mut self, items: impl Iterator<Item = T>) -> Result<(), Error> {
        if self.len == N {
            return Err(Error::Full);
        }
        for item in items {
            self.push(item)?;
        }
        Ok(())
    }

    /// Move every item into `sink`, oldest first, stopping at its first refusal.
    pub fn drain_into<K: Sink<T>>(&mut self, sink: &mut K) -> Result<usize, K::Error> {
        let mut moved = 0;
        while self.len > 0 {
            let item = self.pop();
            if let Ok(item) = item {
                sink.put(item)?;
                moved += 1;
            }
        }
        Ok(moved)
    }

    /// Send the oldest item to `sink` without removing it.
    pub async fn send_front<K: AsyncSink<T>>(&self, sink: &mut K) -> Result<bool, K::Error> {
        if self.len == 0 {
            return Ok(false);
        }
        match self.slots[self.head].clone() {
            Some(item) => {
                sink.put(item).await?;
                Ok(true)
            }
            None => Ok(false),
        }
    }

    /// Remove the oldest item.
    pub fn pop(&mut self) -> Result<T, Error> {
        let item = self.slots[self.head].take().ok_or(Error::Empty)?;
        self.head = (self.head + 1) % N;
        self.len -= 1;
        Ok(item)
    }

    /// Remove every item for which `keep` is false, preserving order.
    pub fn retain(&mut self, keep: impl Fn(&T) -> bool) -> usize {
        let mut removed = 0;
        let mut kept: [Option<T>; N] = core::array::from_fn(|_| None);
        let mut count = 0;
        for offset in 0..self.len {
            let slot = (self.head + offset) % N;
            if let Some(item) = self.slots[slot].take() {
                if keep(&item) {
                    kept[count] = Some(item);
                    count += 1;
                } else {
                    removed += 1;
                }
            }
        }
        self.slots = kept;
        self.head = 0;
        self.len = count;
        removed
    }
}
