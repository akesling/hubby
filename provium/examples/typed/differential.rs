//! Seeded operations on a queue, digested; compared natively and in Lean.
use typed_example::{Error, Queue, Sink};

/// Accepts items until it holds three, then refuses.
struct Bounded {
    held: u64,
    total: u64,
}

impl Sink<u64> for Bounded {
    type Error = ();
    fn put(&mut self, item: u64) -> Result<(), ()> {
        if self.held == 3 {
            return Err(());
        }
        self.held += 1;
        self.total = self.total.wrapping_add(item);
        Ok(())
    }
}

fn mix(state: &mut u64) -> u64 {
    *state = state.wrapping_add(0x9e3779b97f4a7c15);
    let mut z = *state;
    z = (z ^ (z >> 30)).wrapping_mul(0xbf58476d1ce4e5b9);
    z ^ (z >> 31)
}

pub fn run(seed: u64) -> u64 {
    let mut rng = seed;
    let mut queue: Queue<u64, 5> = Queue::new();
    let mut digest: u64 = 0xcbf29ce484222325;
    let mut step = 0;
    while step < 300 {
        let r = mix(&mut rng);
        let value = match r % 4 {
            0 => match queue.push(r >> 8) {
                Ok(()) => 1,
                Err(Error::Full) => 2,
                Err(Error::Empty) => 3,
            },
            1 => queue.pop().unwrap_or(7),
            2 => u64::from(queue.push_cloned(&(r >> 16)).is_ok()) + 4,
            3 if r % 7 == 0 => {
                let mut sink = Bounded { held: 0, total: 0 };
                match queue.drain_into(&mut sink) {
                    Ok(n) => n as u64 + sink.total,
                    Err(()) => 100 + sink.total,
                }
            }
            _ => queue.retain(|item| item % 3 != r % 3) as u64,
        };
        digest = (digest ^ value ^ queue.len() as u64 ^ u64::from(queue.is_empty()))
            .wrapping_mul(0x100000001b3);
        step += 1;
    }
    digest
}
