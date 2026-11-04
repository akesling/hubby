# Node refinement

A refinement from the generated `Node` (fixed engine: hooks absent, peers equal
to members) to the [election-safety](../election-safety/Model.lean) model,
ending in `node_election_safety`, election safety for every run of a stable
cluster of `Node`s. [project.json](project.json) generates Lean for
`Node::tick`, `step`, `next_message`, `build` and `Ready::persisted`, then
checks the modules below as proof modules, in order, with `--trust=0` and
warnings as errors; `assert_proofs!` and `jarl/scripts/verify.sh` run it.
To check it alone:

```sh
cargo run -p provium -- verify-methods jarl/proofs/node-refinement-wip/project.json --out <dir>
```

| Module | Contents | Status |
| --- | --- | --- |
| [Refine.lean](Refine.lean) | Value encodings (`Fields`, `idv`, `statev`, …), `Calm`, `Good`, `Campaigned`, and specs for every helper `step`/`tick` call plus `tick_spec` | complete |
| [Abstract.lean](Abstract.lean) | The abstraction `Abs` from node fields to the model's `Local`; lifting of calm steps and campaigns | complete |
| [StepDefs.lean](StepDefs.lean) | Uniform helper specs, check lemmas, `calm_tac`, `subst_reads`, and `StepOut`, the per-message outcome of `step` | complete |
| [Persist.lean](Persist.lean) | `Ready::persisted` | complete |
| [AbsStep.lean](AbsStep.lean) | Outbox and majority lemmas; `Abs` lemmas mapping each `StepOut` arm to the model: `Abs.vote` (`handleVote`), `Abs.voted` (`handleVoted`), `Abs.prevote` (`answerProbe`), `Abs.adopt_calm` (`PreVoted`, `Replicated`), `Abs.follow` (`Append`, `AppendBatch`, `Install`: unchanged or `demote ∘ adopt`) | complete |
| `StepCase_<kind>.lean` | One `step` proof per message kind (`Replicated` split by rejection), sharing one walk through the dispatch and differing in the message's own arm; `AppendBatch` uses a loop invariant over its entries | complete |
| [Step.lean](Step.lean) | `step_spec`: the cases combined, for a node whose stored vote is absent or a member id (which `Abs` provides) | complete |
| [NextMessage.lean](NextMessage.lean) | `next_spec`: `next_message` changes nothing, or clears the first occupied slot of a clean node and sends for it only what the model's `materialize` stamps (`Sends`); `Abs.next` | complete |
| [Build.lean](Build.lean) | `build_spec`: a node built for a stable configuration is `Good`, a clean follower with no votes and an empty outbox; `Abs.built`: it is the model's node restarted from its checkpoint (`crash`, or `fresh`) | complete |
| [Leaders.lean](Leaders.lean) | Model side: every leader of a reachable world is recorded in `elected`, so `one_leader`: at most one leader per term | complete |
| [Sound.lean](Sound.lean) | `Sound`: `Good` plus well-formed outbox descriptors, kept by every outcome of `tick`, `step`, `next_message`, `Ready::persisted` and `build` | complete |
| [Sim.lean](Sim.lean) | The cluster: `Act` (tick, deliver, send, persist, restart over a network that drops, duplicates, reorders, and forges non-election messages) and `Runs`; the simulation `Sim` with one lemma per action, `runs_sim`, and **`node_election_safety`**: two nodes of a run that are both leader in the same term are the same node | complete |

`node_election_safety` is the implementation-level election-safety theorem for
the fixed engine. Its assumptions: a stable configuration `ids` (membership
hooks absent, every node built by `Node::build` with `membershipv ids`), message
payloads of the shapes `Msg` describes, and a network whose election messages
were sent by a node; the network may drop, duplicate and reorder anything and
forge replication traffic. Dynamic membership (the hook engine) is not covered.
