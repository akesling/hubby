What if Google's Chubby were implemented as a self-sufficient Rust library and
"trivially" useful binary?  This is the question I asked myself, and this
project is some dabbling in answering it.

The Hubby service is aspirational. Current development focuses on
[Jarl](jarl/README.md), the bounded, no_std, sans-I/O Raft core with runtime membership. Its API, recovery
contract, reference host, and validation are documented in the Jarl crate.

Goals:
* [ ] A [Sans-I/O](https://sans-io.readthedocs.io/) implementation of all
  "supported" functionality -- i.e. a fully described state machine which
  prescribes nothing about the network layer / async or not / etc.
* [ ] Support lock files of less than 1MB in memory
* [ ] Full lock file replication among peers, write ACK only after quorum is reached
  on write
* [ ] A full server implementation which uses gRPC
* [ ] Full test coverage
* [ ] Complete validation suite for sans-I/O core

Non-goals:
* Writing out lock files to disk, etc.  If you want this, write a wrapper or a
  client to manage it.
* Support *your distributed consensus algorithm of choice*
* Low latency.  Hubby promises your latency will be high.  Leader election
  should be done deliberately and without rushing ;).

Project structure:
* The `/jarl` crate contains the Raft core and its validation suite.
* The [`/hubby`](https://crates.io/crates/hubby) crate represents the
  server/service. It will contain a gRPC library to surface from any "embedding"
  server and a standalone server binary for general use.
* The [`/hubby-core`](https://crates.io/crates/hubby-core) crate represents the
  core sans-I/O library for the Hubby service.

Where does the name come from?
2) Hubby is a supportive partner in your distributed systems journey.
1) Chubby-style locking services generally represent consensus and
    configuration hubs for distributed systems -- thus hub-by.
3) Hubby has an edit distance of one from the originating paper.
