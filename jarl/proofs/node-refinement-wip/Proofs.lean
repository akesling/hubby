import Sim

/-! Root of the `Node` refinement. Every other module is a proof module of
    `project.json`, checked in the order listed there; the obligations name the
    specification of each translated method and `node_election_safety`, the
    election safety of every run of a stable cluster of `Node`s. -/
