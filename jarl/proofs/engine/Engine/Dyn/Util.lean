import Engine.Host

/-!
# Reading successful runs backwards

The dynamic engine's safety proof only needs what a successful run did: a
panic or divergence is no transition. These lemmas recover facts from
`x = pure r` for loops and binds without proving that the code completes.
-/

namespace Jarl.Engine.Dyn
open Jarl

/-- An invariant kept by every step of a `for` loop holds of its result, whichever
    iterations ran and whether the loop broke early. -/
theorem forIn_pure_inv {β γ : Type} (l : List γ) (init : β) (f : γ → β → Rust.M (ForInStep β))
    (I : Nat → β → Prop) (h0 : I 0 init)
    (hstep : ∀ k (hk : k < l.length) b b', I k b → (f l[k] b = pure (.yield b') → I (k + 1) b') ∧
      (f l[k] b = pure (.done b') → ∀ m, k < m → m ≤ l.length → I m b'))
    (r : β) (h : forIn l init f = pure r) : I l.length r := by
  induction l generalizing init I with
  | nil => simp at h; rw [← Rust.pure_inj h]; exact h0
  | cons x xs ih =>
    rw [List.forIn_cons] at h
    obtain ⟨s, hs, h⟩ := Rust.bind_eq_pure h
    have hx := hstep 0 (by simp) init
    simp only [List.getElem_cons_zero] at hx
    cases s with
    | done b' =>
      simp at h
      rw [← Rust.pure_inj h]
      exact (hx b' h0).2 hs (xs.length + 1) (by omega) (by simp)
    | yield b' =>
      simp only at h
      have := ih b' (fun k => I (k + 1)) ((hx b' h0).1 hs) (fun k hk b b'' hb => by
        have := hstep (k + 1) (by simp; omega) b b'' hb
        simp only [List.getElem_cons_succ] at this
        exact ⟨this.1, fun hd m h1 h2 => by
          have := this.2 hd (m + 1) (by omega) (by simp; omega)
          exact this⟩) h
      simpa using this

/-- A loop whose body always yields `g`: a left fold. -/
theorem forIn_fold {β γ : Type} (l : List γ) (init : β) (g : β → γ → β) :
    forIn l init (fun x b => (pure (.yield (g b x)) : Rust.M (ForInStep β))) = pure (l.foldl g init) := by
  induction l generalizing init with
  | nil => rfl
  | cons x xs ih => rw [List.forIn_cons]; simp only [pure_bind]; exact ih _

theorem bind_pure_split {α β : Type} {x : Rust.M α} {f : α → Rust.M β} {b : β} (h : (x >>= f) = pure b) :
    ∃ a, x = pure a ∧ f a = pure b := Rust.bind_eq_pure h

theorem fail_ne_pure' {α : Type} (msg : String) (a : α) : (Rust.fail msg : Rust.M α) ≠ pure a := by
  intro h; have := congrArg ExceptT.run h; simp [Rust.fail] at this

end Jarl.Engine.Dyn
