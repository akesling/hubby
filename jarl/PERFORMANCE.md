# Local durable baseline

Measured September 13, 2026, on Darwin arm64, Rust 1.96.0, release build.
Three voters use real incremental file journals with `sync_all`; transport is an
in-memory queue in one process. Each of 30 iterations submits one batch and waits
for all three nodes to persist commitment. Timings include compaction when needed.
The workload uses u64 commands/snapshots, six peer slots, and 64 retained log slots.

| Proposal batch | Replication policy | Commands/s | Median batch latency | p99 batch latency | Storage transactions | Messages |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 1 | One entry | 45.5 | 21.99 ms | 24.06 ms | 180 | 240 |
| 4 | One entry | 62.3 | 63.94 ms | 77.22 ms | 543 | 784 |
| 16 | One entry | 67.4 | 239.42 ms | 257.76 ms | 2,007 | 2,976 |
| 1 | Up to 16 entries | 53.8 | 18.04 ms | 20.97 ms | 180 | 240 |
| 4 | Up to 16 entries | 200.7 | 19.87 ms | 28.90 ms | 183 | 244 |
| 16 | Up to 16 entries | 710.9 | 20.11 ms | 31.23 ms | 207 | 276 |

The original baseline already batched proposals into one leader transaction.
Bounded replication batching additionally lets followers persist the batch once.
For the 16-command workload, transaction count fell about 90% and measured
throughput increased about 10.5 times. The single-command workload had identical
transaction/message counts; its timing difference illustrates measurement noise.

This is an exploratory comparison, not an SLA. Thirty samples are insufficient
for a reliable tail distribution (the reported p99 is the largest sample).
There is no WAN latency, concurrent client load, real transport encoding, large
snapshot transfer, or representative storage contention here. `sync_all` exercises
the platform's durability API; these measurements do not establish guarantees
about a particular physical device's power-loss behavior.

Reproduce the current implementation with a new directory:

```sh
cargo run -p jarl --release --example benchmark -- /tmp/jarl-benchmark 100
```

The benchmark prints CSV with batch size, iterations, commands/second, median and
p99 batch microseconds, storage transactions, and message count. Initialization
and election are excluded. Batches are preassembled; client-side batch formation
latency is not included. It intentionally waits for every voter rather than only
the first quorum, so it also exercises follower commitment publication.

Before selecting production limits, measure at least: quorum-only client latency,
slow/minority peers, target payload sizes, realistic RTT/loss, storage stalls,
catch-up, snapshots, executor fairness, and memory/stack usage at the chosen
`MAX` and `CAP`. Application values and membership records are stored inline;
large capacities require planning node placement and stack usage in the host.
