//! A small reference journal for the example's fixed three-voter configuration.
//! Each frame is one Write transaction. Recovery ignores an incomplete final
//! frame, rejects corruption, and truncates the tail before allowing new writes.
use std::{
    fs::{File, OpenOptions},
    io::{self, Read, Seek, SeekFrom, Write as _},
    path::Path,
};

use jarl::{Entry, HardState, Id, LogId, Snapshot, State, Write};

pub const CAP: usize = 8;
pub type Checkpoint = State<u64, u64, CAP>;
const MAX_FRAME: usize = 80 + 32 * CAP;

pub struct Journal {
    file: File,
    pub state: Checkpoint,
    failed: bool,
}

fn invalid() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, "invalid Jarl example journal")
}

fn checksum(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf29ce484222325, |hash, byte| {
        (hash ^ u64::from(*byte)).wrapping_mul(0x100000001b3)
    })
}

fn word(bytes: &mut &[u8]) -> io::Result<u64> {
    let value = bytes.get(..8).ok_or_else(invalid)?;
    let value = u64::from_le_bytes(value.try_into().map_err(|_| invalid())?);
    *bytes = &bytes[8..];
    Ok(value)
}

fn flag(bytes: &mut &[u8]) -> io::Result<bool> {
    match word(bytes)? {
        0 => Ok(false),
        1 => Ok(true),
        _ => Err(invalid()),
    }
}

fn encode(write: &Write<'_, u64, u64>) -> Vec<u8> {
    let mut words = vec![
        write.hard.term,
        write.hard.voted_for.map_or(u64::MAX, |id| id.0),
        write.hard.commit,
    ];
    words.push(u64::from(write.snapshot.is_some()));
    if let Some(s) = write.snapshot {
        words.extend([s.last.index, s.last.term, s.value]);
    }
    words.push(u64::from(write.truncate_from.is_some()));
    if let Some(from) = write.truncate_from {
        words.push(from);
    }
    words.push(write.entries().count() as u64);
    for e in write.entries() {
        words.extend([
            e.id.index,
            e.id.term,
            u64::from(e.value.is_some()),
            e.value.unwrap_or(0),
        ]);
    }
    words.into_iter().flat_map(u64::to_le_bytes).collect()
}

fn apply(saved: &Checkpoint, mut bytes: &[u8]) -> io::Result<Checkpoint> {
    let term = word(&mut bytes)?;
    let vote = word(&mut bytes)?;
    if vote != u64::MAX && vote >= 3 {
        return Err(invalid());
    }
    let hard = HardState {
        term,
        voted_for: (vote != u64::MAX).then_some(Id(vote)),
        commit: word(&mut bytes)?,
    };
    let snapshot = if flag(&mut bytes)? {
        Some(Snapshot {
            last: LogId {
                index: word(&mut bytes)?,
                term: word(&mut bytes)?,
            },
            value: word(&mut bytes)?,
        })
    } else {
        saved.snapshot().cloned()
    };
    let truncate = if flag(&mut bytes)? {
        Some(word(&mut bytes)?)
    } else {
        None
    };
    let base = snapshot.as_ref().map_or(0, |s| s.last.index);
    let mut log: Vec<_> = saved
        .entries()
        .filter(|e| e.id.index > base && truncate.is_none_or(|from| e.id.index < from))
        .cloned()
        .collect();
    let count = word(&mut bytes)?;
    if count > CAP as u64 {
        return Err(invalid());
    }
    for _ in 0..count {
        let id = LogId {
            index: word(&mut bytes)?,
            term: word(&mut bytes)?,
        };
        let present = flag(&mut bytes)?;
        let value = word(&mut bytes)?;
        log.push(Entry {
            id,
            value: present.then_some(value),
        });
    }
    if !bytes.is_empty() {
        return Err(invalid());
    }
    State::restore(hard, snapshot, log).map_err(|_| invalid())
}

impl Journal {
    pub fn open(directory: &Path, id: Id) -> io::Result<Self> {
        let path = directory.join(format!("node-{}.jarl", id.0));
        let mut file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(path)?;
        // Two hosts must never run the same voter identity concurrently.
        file.try_lock().map_err(io::Error::other)?;
        // Bind the checkpoint to its identity and fixed membership.
        let mut header = b"Jarl example v1; voters=0,1,2; id=".to_vec();
        header.extend(id.0.to_le_bytes());
        let mut bytes = vec![];
        file.read_to_end(&mut bytes)?;
        if bytes.is_empty() {
            file.write_all(&header)?;
            file.sync_all()?;
            File::open(directory)?.sync_all()?;
            bytes = header.clone();
        }
        if !bytes.starts_with(&header) {
            return Err(invalid());
        }
        let mut offset = header.len();
        let mut state = Checkpoint::new();
        while bytes.len() - offset >= 4 {
            let len = u32::from_le_bytes(
                bytes[offset..offset + 4]
                    .try_into()
                    .map_err(|_| invalid())?,
            ) as usize;
            if len == 0 || len > MAX_FRAME {
                return Err(invalid());
            }
            let end = offset + 4 + len + 8;
            if end > bytes.len() {
                break;
            }
            let payload = &bytes[offset + 4..offset + 4 + len];
            let stored = u64::from_le_bytes(bytes[end - 8..end].try_into().map_err(|_| invalid())?);
            if checksum(payload) != stored {
                return Err(invalid());
            }
            state = apply(&state, payload)?;
            offset = end;
        }
        file.set_len(offset as u64)?;
        file.sync_all()?;
        file.seek(SeekFrom::End(0))?;
        Ok(Self {
            file,
            state,
            failed: false,
        })
    }

    pub fn save(&mut self, write: Write<'_, u64, u64>) -> io::Result<()> {
        if self.failed {
            return Err(io::Error::other("reopen the journal after a failed write"));
        }
        let payload = encode(&write);
        let state = apply(&self.state, &payload)?;
        let mut frame = (payload.len() as u32).to_le_bytes().to_vec();
        frame.extend(&payload);
        frame.extend(checksum(&payload).to_le_bytes());
        // A failed write may have left a partial frame. Do not append behind it.
        self.failed = true;
        self.file.write_all(&frame)?;
        self.file.sync_all()?;
        self.state = state;
        self.failed = false;
        Ok(())
    }
}
