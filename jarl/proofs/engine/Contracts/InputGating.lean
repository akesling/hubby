import Generated

/-!
Complete `node::Node::available` and `node::Node::idle`: exact result,
dirty-state/reply/outbox rejection, clean/drained admission over arbitrary
outbox lengths, and the gate after `ready::Ready::persisted`. Not proved: that
every protocol caller invokes the gate or that storage acknowledgment was truthful.
-/

namespace Jarl.Contracts.InputGating

theorem exact_result {V S : Type} {N CAP : Nat} [Rust.Clone V] [Rust.Clone S]
    (n : Node V S N CAP) :
    Node.available n =
      if n.dirty || n.extra_reply.isSome || n.outbox.toList.any Option.isSome then
        .Err .Busy else .Ok () :=
  rfl

theorem dirty_blocks {V S : Type} {N CAP : Nat} [Rust.Clone V] [Rust.Clone S]
    (n : Node V S N CAP) (hd : n.dirty = true) :
    Node.available n = .Err .Busy := by
  simp [Node.available, hd]

theorem pending_reply_blocks {V S : Type} {N CAP : Nat} [Rust.Clone V] [Rust.Clone S]
    (n : Node V S N CAP) (reply : Id × Outbound) (he : n.extra_reply = some reply) :
    Node.available n = .Err .Busy := by
  simp [Node.available, he]

theorem pending_outbox_blocks {V S : Type} {N CAP : Nat} [Rust.Clone V] [Rust.Clone S]
    (n : Node V S N CAP) (pending : n.outbox.toList.any Option.isSome = true) :
    Node.available n = .Err .Busy := by
  simp only [Node.available, pending, Bool.or_true, if_true]

theorem clean_allows {V S : Type} {N CAP : Nat} [Rust.Clone V] [Rust.Clone S]
    (n : Node V S N CAP) (hd : n.dirty = false) (he : n.extra_reply = none)
    (drained : n.outbox.toList.any Option.isSome = false) :
    Node.available n = .Ok () := by
  simp only [Node.available, hd, he, drained, Option.isSome_none, Bool.or_false,
    Bool.false_eq_true, if_false]

theorem idle_agrees {V S : Type} {N CAP : Nat} [Rust.Clone V] [Rust.Clone S]
    (n : Node V S N CAP) : Node.idle n = Node.available n :=
  rfl

/-- After acknowledging persistence, only pending replies and outbox messages gate input. -/
theorem after_ack_exact {V S : Type} {N CAP : Nat} [Rust.Clone V] [Rust.Clone S]
    (r : Ready V S N CAP) :
    Node.available (Ready.persisted r).node =
      if r.node.extra_reply.isSome || r.node.outbox.toList.any Option.isSome then
        .Err .Busy else .Ok () :=
  rfl

theorem ack_preserves_pending_outputs {V S : Type} {N CAP : Nat} [Rust.Clone V] [Rust.Clone S]
    (r : Ready V S N CAP)
    (pending : (r.node.extra_reply.isSome || r.node.outbox.toList.any Option.isSome) = true) :
    Node.available (Ready.persisted r).node = .Err .Busy := by
  rw [after_ack_exact, pending, if_pos rfl]

end Jarl.Contracts.InputGating
