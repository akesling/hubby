import Generated

/-!
Complete `ready::Ready::persisted` field effects: clear the three persistence
flags, preserve every other field, algebraic idempotence. This does not authorize
acknowledging an undurable save or reusing a consumed `Ready` token.
-/

namespace Jarl.Contracts.Persistence

/-- The exact resulting record: the function is total (pure) and changes only the
    three flags of the wrapped node. -/
theorem persisted_exact {V S : Type} {N CAP : Nat} (r : Ready V S N CAP) :
    Ready.persisted r =
      { node := { r.node with dirty := false, log_from := none, snapshot_changed := false } } :=
  rfl

theorem flags_cleared {V S : Type} {N CAP : Nat} (r : Ready V S N CAP) :
    (Ready.persisted r).node.dirty = false ∧
    (Ready.persisted r).node.log_from = none ∧
    (Ready.persisted r).node.snapshot_changed = false :=
  ⟨rfl, rfl, rfl⟩

/-- Every field other than the three flags is unchanged. -/
theorem other_fields_unchanged {V S : Type} {N CAP : Nat} (r : Ready V S N CAP) :
    let n' := (Ready.persisted r).node
    n'.config = r.node.config ∧ n'.state = r.node.state ∧ n'.role = r.node.role ∧
    n'.leader = r.node.leader ∧ n'.local = r.node.local ∧
    n'.membership = r.node.membership ∧ n'.bootstrap = r.node.bootstrap ∧
    n'.hooks = r.node.hooks ∧ n'.peers = r.node.peers ∧ n'.votes = r.node.votes ∧
    n'.next = r.node.next ∧ n'.matched = r.node.matched ∧ n'.outbox = r.node.outbox ∧
    n'.elapsed = r.node.elapsed ∧ n'.election_deadline = r.node.election_deadline ∧
    n'.random = r.node.random ∧ n'.prevoting = r.node.prevoting ∧
    n'.leader_age = r.node.leader_age ∧ n'.quorum_elapsed = r.node.quorum_elapsed ∧
    n'.active = r.node.active ∧ n'.extra_reply = r.node.extra_reply ∧
    n'.request_from = r.node.request_from :=
  ⟨rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl,
   rfl, rfl, rfl, rfl, rfl⟩

/-- Algebraic idempotence of the effect, not permission to acknowledge a consumed
    `Ready` token twice or to acknowledge storage that was never durable. -/
theorem idempotent {V S : Type} {N CAP : Nat} (r : Ready V S N CAP) :
    Ready.persisted (Ready.persisted r) = Ready.persisted r :=
  rfl

end Jarl.Contracts.Persistence
