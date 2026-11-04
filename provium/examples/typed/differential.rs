//! Seeded operations on a queue, digested; compared natively and in Lean.
use typed_example::{Error, Queue};

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
        let value = match r % 3 {
            0 => match queue.push(r >> 8) {
                Ok(()) => 1,
                Err(Error::Full) => 2,
                Err(Error::Empty) => 3,
            },
            1 => queue.pop().unwrap_or(7),
            _ => queue.retain(|item| item % 3 != r % 3) as u64,
        };
        digest = (digest ^ value ^ queue.len() as u64).wrapping_mul(0x100000001b3);
        step += 1;
    }
    digest
}
