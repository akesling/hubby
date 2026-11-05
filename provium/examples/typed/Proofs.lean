import Generated

/-! Proofs about the typed translation of the example queue. -/

namespace Example.Proofs
open Example

/-- A new queue is empty. -/
theorem new_empty {T : Type} {N : Nat} [Rust.Clone T] : (Queue.new : Queue T N).is_empty = true := by
  simp [Queue.new, Queue.is_empty]

/-- Pushing onto a queue that is not full succeeds and adds one item. -/
theorem push_len {T : Type} {N : Nat} [Rust.Clone T] (q : Queue T N) (x : T)
    (hn : N < 2 ^ 63) (hlen : q.len.val < N) (hhead : q.head.val < N) :
    ∃ q', Queue.push q x = pure (.Ok (), q') ∧ q'.len.val = q.len.val + 1 := by
  have hN : (Rust.usizeOf N).val = N := by
    simp [Rust.usizeOf, Rust.ofNat, Nat.mod_eq_of_lt (by omega : N < 2 ^ 64)]
  have hne : ¬ q.len = Rust.usizeOf N := by
    intro h; rw [Fin.ext_iff, hN] at h; omega
  have h1 : q.head.val + q.len.val < 2 ^ 64 := by omega
  have h2 : (q.head.val + q.len.val) % N < N := Nat.mod_lt _ (by omega)
  have h3 : q.len.val + 1 < 2 ^ 64 := by omega
  simp only [Queue.push, hne, beq_iff_eq, if_false, Rust.add, Rust.rem, Rust.Slice.set, hN,
    dif_pos h1]
  simp [show ¬ N = 0 by omega, dif_pos h2, show q.len.val + 1 < 18446744073709551616 by omega]
  exact ⟨_, rfl, rfl⟩

/-- A consumer's execution relation: one successful push. -/
inductive Pushed {T : Type} {N : Nat} [Rust.Clone T] : Queue T N → Queue T N → Prop
  | push (q q' : Queue T N) (x : T) : Queue.push q x = pure (.Ok (), q') → Pushed q q'

/-- A theorem about `Pushed` is about `Queue.push`, which its constructor runs. -/
theorem pushed_len {T : Type} {N : Nat} [Rust.Clone T] (q q' : Queue T N)
    (hn : N < 2 ^ 63) (hlen : q.len.val < N) (hhead : q.head.val < N) (h : Pushed q q') :
    q'.len.val = q.len.val + 1 := by
  cases h with
  | push x hp =>
    obtain ⟨q'', hq, hl⟩ := push_len q x hn hlen hhead
    rw [hp] at hq
    cases hq
    exact hl

/-- A full queue rejects `push_cloned` without running `T::clone`: the result is
    the same for every `Clone`, including one that always panics. -/
theorem full_skips_clone {T : Type} {N : Nat} [Rust.Clone T] (q : Queue T N) (x : T)
    (hfull : q.len = Rust.usizeOf N) :
    Queue.push_cloned q x = pure (.Err .Full, q) := by
  simp [Queue.push_cloned, Queue.push_all, hfull]

/-- When the clone returns the item, `push_cloned` is `push`. -/
theorem push_cloned_len {T : Type} {N : Nat} [Rust.Clone T] (q : Queue T N) (x : T)
    (hc : Rust.Clone.clone x = pure x)
    (hn : N < 2 ^ 63) (hlen : q.len.val < N) (hhead : q.head.val < N) :
    ∃ q', Queue.push_cloned q x = pure (.Ok (), q') ∧ q'.len.val = q.len.val + 1 := by
  obtain ⟨q', hq, hl⟩ := push_len q x hn hlen hhead
  have hne : ¬ q.len = Rust.usizeOf N := by
    intro h; rw [h] at hlen
    simp [Rust.usizeOf, Rust.ofNat, Nat.mod_eq_of_lt (by omega : N < 2 ^ 64)] at hlen
  refine ⟨q', ?_, hl⟩
  simp [Queue.push_cloned, Queue.push_all, hne, hc, hq]

/-- `Display` writes the exact text, appended to what the formatter holds. -/
theorem display_text (f : Rust.Formatter) :
    Error.fmt .Full f = (.Ok (), f ++ "queue full") ∧
    Error.fmt .Empty f = (.Ok (), f ++ "queue empty (0 items)") := by
  constructor <;> rfl

/-- Dropping `send_front` before its `.await` completes (no budget left) leaves
    only the consumer's effect of a dropped `put`; nothing is sent. -/
theorem send_front_dropped {T K : Type} {N : Nat} [Rust.Clone T] [AsyncSink T K]
    (q : Queue T N) (sink : K) (x : T) (hlen : q.len ≠ 0) (hhead : q.head.val < N)
    (hslot : q.slots[q.head.val] = some x) (hc : Rust.Clone.clone (some x) = pure (some x)) :
    Queue.send_front q sink 0 = pure (.dropped, AsyncSink.put_dropped sink x, 0) := by
  simp [Queue.send_front, hlen, Rust.Slice.index, hhead, hslot, hc]

/-- With budget left, `send_front` completes once `put` does, spending one unit. -/
theorem send_front_sent {T K : Type} {N : Nat} [Rust.Clone T] [AsyncSink T K]
    (q : Queue T N) (sink sink' : K) (x : T) (b : Nat) (hlen : q.len ≠ 0) (hhead : q.head.val < N)
    (hslot : q.slots[q.head.val] = some x) (hc : Rust.Clone.clone (some x) = pure (some x))
    (hput : AsyncSink.put sink x = pure (.Ok (), sink')) :
    Queue.send_front q sink (b + 1) = pure (.ready (.Ok true), sink', b) := by
  simp [Queue.send_front, hlen, Rust.Slice.index, hhead, hslot, hc, hput]

/-- Draining an empty queue moves nothing and never calls the sink. -/
theorem drain_empty {T K : Type} {N : Nat} [Rust.Clone T] [Sink T K] (q : Queue T N) (sink : K)
    (hlen : q.len = 0) : Queue.drain_into q sink = pure (.Ok 0, q, sink) := by
  unfold Queue.drain_into
  simp only []
  rw [Rust.loop_done (b' := (none, q, sink, (0 : Rust.usize))) (by simp [hlen])]
  rfl
end Example.Proofs
