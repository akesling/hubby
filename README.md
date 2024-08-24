What if the Google's Chubby were implemented as a self-sufficient Rust library
and "trivially" useful binary?  This is the question I asked myself, and this
project is some dabbling in answering it.

At this time, nothing works and this project is aspirational.  From there,
hopefully it will become experimental, and then... maybe, just maybe, we can get
to a feature-complete Chubby clone that can reach "sustainable" maintenance.

Goals:
[] A [Sans-I/O](https://sans-io.readthedocs.io/) implementation of all
  "supported" functionality -- i.e. a fully described state machine which
  prescribes nothing about the network layer / async or not / etc.
[] Support lock files of less than 1MB in memory
[] Full lock file replication among peers, write ACK only after quorum is reached
  on write
[] A full server implementation which uses gRPC
[] Full test coverage
[] Complete validation suite for sans-I/O core

Non-goals:
* Writing out lock files to disk, etc.  If you want this, write a wrapper or a
  client to manage it.
* Support *your distributed consensus algorithm of choice*
* Low latency.  Hubby promises your latency will be high.  Leader election
  should be done deliberately and without rushing ;).
