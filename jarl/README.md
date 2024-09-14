[Jarl](https://github.com/akesling/hubby/jarl) may be Just Another Raft Library,
but it makes a point to be literally _just_ another Raft library.  There's no
I/O, no standard library, no dependencies, no internal allocations, no async...
literally _just_ a state machine for managing consensus of a "virtual" cell.

The library is a single Rust file.  As simple as it gets.

All Raft log state is managed in-memory.

The goal is to eventually have wrapping libraries which implement various
transport integrations for using "off-the-shelf" (e.g. gRPC, OpenAPI, etc.) in
an actual networked context.  If we're feeling cheeky, we might even implement
some unexpected IPC mechanisms (Raft over SMS anyone? What about Raft over S3?
Serverless Raft‽).
