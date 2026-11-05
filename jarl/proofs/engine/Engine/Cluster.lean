import Engine.Ghost
import Engine.Step
import Engine.Tick
import Engine.NextMessage

/-!
# A fixed cluster of Jarl nodes

`N` nodes with the distinct identities `ids` run the generated code of every
public `Node` operation. Each node has volatile state (`live`) and a durable
checkpoint (`disk`); `sent` is every message ever materialized. The network
may deliver any sent message to any node, any number of times, in any order.
An operation that panics or diverges produces no transition, which is the
same as crashing the node; `restart` rebuilds a node from its checkpoint.
-/

namespace Jarl.Engine
open Jarl

variable {V S : Type} {N CAP : Nat} [Rust.Clone V] [Rust.Clone S]

structure Cluster (V S : Type) (N CAP : Nat) where
  live : Fin N → Node V S N CAP
  disk : Fin N → State V S CAP
  sent : List (Envelope V S)

/-- Replace node `k`'s volatile state. -/
def Cluster.setLive (C : Cluster V S N CAP) (k : Fin N) (n : Node V S N CAP) : Cluster V S N CAP :=
  { C with live := fun j => if j = k then n else C.live j }

/-- `persist`: save node `k`'s checkpoint and acknowledge it through `Ready`. -/
def Cluster.persist (C : Cluster V S N CAP) (k : Fin N) (n : Node V S N CAP) : Cluster V S N CAP :=
  { C with live := fun j => if j = k then n else C.live j,
           disk := fun j => if j = k then (C.live k).state else C.disk j }

/-- One step of the cluster under the host's configurations `cfg`. -/
inductive Act (cfg : Fin N → Config N) (C : Cluster V S N CAP) : Cluster V S N CAP → Prop
  | tick (k : Fin N) (r : Rust.Result Unit Error) (n : Node V S N CAP) :
      Node.tick (C.live k) = pure (r, n) → Act cfg C (C.setLive k n)
  | deliver (k : Fin N) (env : Envelope V S) (r : Rust.Result Unit Error) (n : Node V S N CAP) :
      env ∈ C.sent → Node.step (C.live k) env = pure (r, n) → Act cfg C (C.setLive k n)
  | propose (k : Fin N) (v : V) (r : Rust.Result LogId Error) (n : Node V S N CAP) :
      Node.propose (C.live k) v = pure (r, n) → Act cfg C (C.setLive k n)
  | proposeBatch (k : Fin N) (vs : Array V) (r : Rust.Result ProposalRange Error) (n : Node V S N CAP) :
      vs.size < 2 ^ Rust.usizeBits → Node.propose_batch (C.live k) vs = pure (r, n) → Act cfg C (C.setLive k n)
  | compact (k : Fin N) (index : Rust.u64) (v : S) (r : Rust.Result Unit Error) (n : Node V S N CAP) :
      Node.compact (C.live k) index v = pure (r, n) → Act cfg C (C.setLive k n)
  | persist (k : Fin N) (ready : Ready V S N CAP) :
      Node.ready (C.live k) = some ready → Act cfg C (C.persist k (Ready.persisted ready).node)
  | send (k : Fin N) (env : Envelope V S) (n : Node V S N CAP) :
      Node.next_message (C.live k) = pure (some env, n) → Act cfg C { C.setLive k n with sent := env :: C.sent }
  | drain (k : Fin N) (n : Node V S N CAP) :
      Node.next_message (C.live k) = pure (none, n) → Act cfg C (C.setLive k n)
  | restart (k : Fin N) (n : Node V S N CAP) :
      Node.new (cfg k) (C.disk k) = pure (.Ok n) → Act cfg C (C.setLive k n)

/-- Every node starts from an empty checkpoint, and no message was sent. -/
def Initial (cfg : Fin N → Config N) (C : Cluster V S N CAP) : Prop :=
  C.sent = [] ∧ ∀ k, C.disk k = State.new ∧ Node.new (cfg k) State.new = pure (.Ok (C.live k))

inductive Reach (cfg : Fin N → Config N) : Cluster V S N CAP → Prop
  | init (C : Cluster V S N CAP) : Initial cfg C → Reach cfg C
  | step (C C' : Cluster V S N CAP) : Reach cfg C → Act cfg C C' → Reach cfg C'

end Jarl.Engine
