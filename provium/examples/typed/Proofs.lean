import Generated

/-! Proofs about the typed translation of the example queue. -/

namespace Example.Proofs
open Example

/-- A new queue is empty. -/
theorem new_empty {T : Type} {N : Nat} : (Queue.new : Queue T N).is_empty = true := by
  simp [Queue.new, Queue.is_empty]

/-- Pushing onto a queue that is not full succeeds and adds one item. -/
theorem push_len {T : Type} {N : Nat} (q : Queue T N) (x : T)
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
inductive Pushed {T : Type} {N : Nat} : Queue T N → Queue T N → Prop
  | push (q q' : Queue T N) (x : T) : Queue.push q x = pure (.Ok (), q') → Pushed q q'

/-- A theorem about `Pushed` is about `Queue.push`, which its constructor runs. -/
theorem pushed_len {T : Type} {N : Nat} (q q' : Queue T N)
    (hn : N < 2 ^ 63) (hlen : q.len.val < N) (hhead : q.head.val < N) (h : Pushed q q') :
    q'.len.val = q.len.val + 1 := by
  cases h with
  | push x hp =>
    obtain ⟨q'', hq, hl⟩ := push_len q x hn hlen hhead
    rw [hp] at hq
    cases hq
    exact hl
end Example.Proofs
