//! Local three-voter durable baseline. Transport is an in-memory queue.
//! Reports real file-sync costs; this is not a WAN or production-load benchmark.
#[path = "support/dynamic_journal.rs"]
mod journal;
use jarl::{host, Cluster, ClusterState, Envelope, Id, Membership, Role, Settings};
use journal::{Journal, CAP, MAX};
use std::{collections::VecDeque, fs, io, path::Path, time::Instant};
type Peer = Cluster<u64, u64, MAX, CAP>;
type Wire = Envelope<journal::Value, journal::Snap>;
fn flush(
    i: usize,
    nodes: &mut [Peer],
    disks: &mut [Journal],
    queue: &mut VecDeque<Wire>,
    writes: &mut usize,
) -> io::Result<()> {
    if let Some(ready) = nodes[i].ready() {
        host::persist(ready, &mut disks[i])?;
        *writes += 1;
    }
    while let Some(message) = nodes[i].next_message() {
        queue.push_back(message.cloned());
    }
    Ok(())
}
fn drain(
    nodes: &mut [Peer],
    disks: &mut [Journal],
    queue: &mut VecDeque<Wire>,
    writes: &mut usize,
    messages: &mut usize,
) -> io::Result<()> {
    while let Some(message) = queue.pop_front() {
        *messages += 1;
        let i = message.to.0 as usize;
        nodes[i].step(&message).map_err(io::Error::other)?;
        flush(i, nodes, disks, queue, writes)?;
    }
    Ok(())
}
fn benchmark(path: &Path, batch: usize, iterations: usize) -> io::Result<()> {
    fs::create_dir(path)?;
    fs::File::open(path.parent().unwrap())?.sync_all()?;
    let genesis = Membership::new(&[Id(0), Id(1), Id(2)], &[]).map_err(io::Error::other)?;
    let mut disks = (0..3)
        .map(|i| Journal::open(path, 2028, Id(i), genesis))
        .collect::<io::Result<Vec<_>>>()?;
    let mut nodes = (0..3)
        .map(|i| {
            Cluster::new(
                Settings {
                    seed: i + 1,
                    ..Settings::default()
                },
                ClusterState::new(Id(i), genesis).unwrap(),
            )
            .unwrap()
        })
        .collect::<Vec<_>>();
    let mut queue = VecDeque::new();
    let mut writes = 0;
    let mut messages = 0;
    let leader = loop {
        for i in 0..3 {
            nodes[i].tick().map_err(io::Error::other)?;
            flush(i, &mut nodes, &mut disks, &mut queue, &mut writes)?;
        }
        drain(
            &mut nodes,
            &mut disks,
            &mut queue,
            &mut writes,
            &mut messages,
        )?;
        if let Some(i) = nodes.iter().position(|n| n.role() == Role::Leader) {
            break i;
        }
    };
    writes = 0;
    messages = 0;
    let mut latencies = Vec::with_capacity(iterations);
    let commands = vec![1; batch];
    let begin = Instant::now();
    for round in 0..iterations {
        let start = Instant::now();
        if nodes.iter().any(|n| n.remaining() < batch + 3) {
            for i in 0..3 {
                let commit = nodes[i].state().hard().commit;
                nodes[i]
                    .compact(commit, &((round * batch) as u64))
                    .map_err(io::Error::other)?;
                flush(i, &mut nodes, &mut disks, &mut queue, &mut writes)?;
            }
            drain(
                &mut nodes,
                &mut disks,
                &mut queue,
                &mut writes,
                &mut messages,
            )?;
        }
        let proposed = nodes[leader]
            .propose_batch(&commands)
            .map_err(io::Error::other)?;
        flush(leader, &mut nodes, &mut disks, &mut queue, &mut writes)?;
        drain(
            &mut nodes,
            &mut disks,
            &mut queue,
            &mut writes,
            &mut messages,
        )?;
        assert!(nodes
            .iter()
            .all(|n| n.state().hard().commit >= proposed.last.index));
        latencies.push(start.elapsed().as_micros());
    }
    let elapsed = begin.elapsed().as_secs_f64();
    latencies.sort_unstable();
    println!(
        "{batch},{iterations},{:.1},{},{},{writes},{messages}",
        (batch * iterations) as f64 / elapsed,
        latencies[iterations / 2],
        latencies[(iterations * 99 / 100).min(iterations - 1)]
    );
    Ok(())
}
fn main() -> io::Result<()> {
    let mut args = std::env::args_os().skip(1);
    let path = args
        .next()
        .ok_or_else(|| io::Error::other("usage: benchmark <new-storage-directory> [iterations]"))?;
    let iterations = args
        .next()
        .map(|s| s.to_string_lossy().parse::<usize>())
        .transpose()
        .map_err(io::Error::other)?
        .unwrap_or(100);
    if iterations == 0 {
        return Err(io::Error::other("iterations must be positive"));
    }
    let path = Path::new(&path);
    fs::create_dir(path)?;
    fs::File::open(
        path.parent()
            .filter(|p| !p.as_os_str().is_empty())
            .unwrap_or_else(|| Path::new(".")),
    )?
    .sync_all()?;
    println!(
        "batch,iterations,commands_per_second,p50_batch_us,p99_batch_us,transactions,messages"
    );
    for batch in [1, 4, 16] {
        benchmark(&path.join(format!("batch-{batch}")), batch, iterations)?;
    }
    Ok(())
}
