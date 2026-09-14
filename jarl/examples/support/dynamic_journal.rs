//! Versioned incremental journal for the runtime-membership reference host.
//! Fixed example application: u64 addition, six simultaneous peers, 64 log slots.
use jarl::{
    host::Storage, Checkpoint, Entry, HardState, Id, LogId, Membership, Record, Snapshot, State,
    Write,
};
use std::{
    fs::{File, OpenOptions},
    io::{self, Read, Seek, SeekFrom, Write as _},
    path::Path,
};
pub const MAX: usize = 6;
pub const CAP: usize = 64;
pub type Value = Record<u64, MAX>;
pub type Snap = Checkpoint<u64, MAX>;
pub type Disk = State<Value, Snap, CAP>;
const MAX_FRAME: usize = 65536;
fn invalid() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, "invalid dynamic Jarl journal")
}
fn checksum(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf29ce484222325, |h, b| {
        (h ^ u64::from(*b)).wrapping_mul(0x100000001b3)
    })
}
fn word(bytes: &mut &[u8]) -> io::Result<u64> {
    let value = u64::from_le_bytes(
        bytes
            .get(..8)
            .ok_or_else(invalid)?
            .try_into()
            .map_err(|_| invalid())?,
    );
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
fn membership(words: &mut Vec<u64>, m: Membership<MAX>) {
    for set in [
        m.voters().collect::<Vec<_>>(),
        m.old_voters().collect(),
        m.learners().collect(),
    ] {
        words.push(set.len() as u64);
        words.extend(set.iter().map(|id| id.0));
    }
}
fn read_membership(bytes: &mut &[u8]) -> io::Result<Membership<MAX>> {
    let mut sets = [vec![], vec![], vec![]];
    for set in &mut sets {
        let count = word(bytes)?;
        if count > MAX as u64 {
            return Err(invalid());
        }
        for _ in 0..count {
            set.push(Id(word(bytes)?));
        }
    }
    Membership::restore(&sets[0], &sets[1], &sets[2]).map_err(|_| invalid())
}
pub fn encode(write: &Write<'_, Value, Snap>) -> Vec<u8> {
    let mut words = vec![
        write.hard.term,
        u64::from(write.hard.voted_for.is_some()),
        write.hard.voted_for.map_or(0, |id| id.0),
        write.hard.commit,
        u64::from(write.snapshot.is_some()),
    ];
    if let Some(snapshot) = write.snapshot {
        words.extend([
            snapshot.last.index,
            snapshot.last.term,
            snapshot.value.application,
        ]);
        membership(&mut words, snapshot.value.membership);
    }
    words.push(u64::from(write.truncate_from.is_some()));
    if let Some(from) = write.truncate_from {
        words.push(from);
    }
    words.push(write.entries().count() as u64);
    for entry in write.entries() {
        words.extend([entry.id.index, entry.id.term]);
        match &entry.value {
            None => words.push(0),
            Some(Record::Command(value)) => words.extend([1, *value]),
            Some(Record::Configuration(m)) => {
                words.push(2);
                membership(&mut words, *m);
            }
        }
    }
    words.into_iter().flat_map(u64::to_le_bytes).collect()
}
fn apply(saved: &Disk, mut bytes: &[u8]) -> io::Result<Disk> {
    let term = word(&mut bytes)?;
    let voted = flag(&mut bytes)?;
    let vote = word(&mut bytes)?;
    let hard = HardState {
        term,
        voted_for: voted.then_some(Id(vote)),
        commit: word(&mut bytes)?,
    };
    let snapshot = if flag(&mut bytes)? {
        Some(Snapshot {
            last: LogId {
                index: word(&mut bytes)?,
                term: word(&mut bytes)?,
            },
            value: Checkpoint {
                application: word(&mut bytes)?,
                membership: read_membership(&mut bytes)?,
            },
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
    let mut log = saved
        .entries()
        .filter(|e| e.id.index > base && truncate.is_none_or(|from| e.id.index < from))
        .cloned()
        .collect::<Vec<_>>();
    let count = word(&mut bytes)?;
    if count > CAP as u64 {
        return Err(invalid());
    }
    for _ in 0..count {
        let id = LogId {
            index: word(&mut bytes)?,
            term: word(&mut bytes)?,
        };
        let value = match word(&mut bytes)? {
            0 => None,
            1 => Some(Record::Command(word(&mut bytes)?)),
            2 => Some(Record::Configuration(read_membership(&mut bytes)?)),
            _ => return Err(invalid()),
        };
        log.push(Entry { id, value });
    }
    if !bytes.is_empty() {
        return Err(invalid());
    }
    Disk::restore(hard, snapshot, log).map_err(|_| invalid())
}

pub struct Journal {
    file: File,
    pub state: Disk,
    failed: bool,
}
impl Journal {
    pub fn open(
        directory: &Path,
        namespace: u64,
        id: Id,
        genesis: Membership<MAX>,
    ) -> io::Result<Self> {
        let mut file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(directory.join(format!("dynamic-{}.jarl", id.0)))?;
        file.try_lock().map_err(io::Error::other)?;
        let mut words = vec![namespace, id.0];
        membership(&mut words, genesis);
        let mut header = b"Jarl dynamic journal v1\0".to_vec();
        header.extend(words.into_iter().flat_map(u64::to_le_bytes));
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
        let mut state = Disk::new();
        while bytes.len() - offset >= 4 {
            let length = u32::from_le_bytes(
                bytes[offset..offset + 4]
                    .try_into()
                    .map_err(|_| invalid())?,
            ) as usize;
            if length == 0 || length > MAX_FRAME {
                return Err(invalid());
            }
            let end = offset + 4 + length + 8;
            if end > bytes.len() {
                break;
            }
            let payload = &bytes[offset + 4..offset + 4 + length];
            let stored = u64::from_le_bytes(bytes[end - 8..end].try_into().map_err(|_| invalid())?);
            if stored != checksum(payload) {
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
}
impl Journal {
    pub fn save_encoded(&mut self, bytes: Vec<u8>) -> io::Result<()> {
        if self.failed {
            return Err(io::Error::other(
                "reopen after ambiguous persistence failure",
            ));
        }
        let state = apply(&self.state, &bytes)?;
        if bytes.len() > MAX_FRAME {
            return Err(invalid());
        }
        let mut frame = (bytes.len() as u32).to_le_bytes().to_vec();
        frame.extend(&bytes);
        frame.extend(checksum(&bytes).to_le_bytes());
        self.failed = true;
        self.file.write_all(&frame)?;
        self.file.sync_all()?;
        self.state = state;
        self.failed = false;
        Ok(())
    }
}

impl Storage<Value, Snap> for Journal {
    type Error = io::Error;
    fn save(&mut self, write: Write<'_, Value, Snap>) -> io::Result<()> {
        self.save_encoded(encode(&write))
    }
}
