import Generated
import Engine.Log

/-!
# Storage contracts over the typed translation of `state::State`

Ports the `storage` project. The old deep embedding modelled the buffer as an
abstract slot list with destructor suspensions, interpreter fuel and heap
loans; the typed translation has none of those, so the corresponding
obligations are restated as properties of the translated functions:
exact results, never diverging, and which fields a function reads or writes.

`State::grow` is not translated yet; its section is to be appended at the end
of this file (see `StorageHistory`, whose growth step is a parameter).
-/

namespace Jarl.Contracts.Storage
open Jarl Jarl.Engine

variable {V S : Type} {CAP : Nat}

/-! ## Shared helpers -/

/-- A computation that does not diverge (it returns or panics). -/
def Term {α : Type} (m : Rust.M α) : Prop := m.run ≠ none

theorem term_pure {α : Type} (a : α) : Term (pure a : Rust.M α) := by
  simp [Term, ExceptT.run_pure]

theorem term_throw {α : Type} (e : Rust.Panic) : Term (throw e : Rust.M α) := by
  simp [Term, ExceptT.run_throw]

theorem term_fail {α : Type} (msg : String) : Term (Rust.fail msg : Rust.M α) := term_throw _

theorem term_bind {α β : Type} {m : Rust.M α} {f : α → Rust.M β} (hm : Term m)
    (hf : ∀ a, m = pure a → Term (f a)) : Term (m >>= f) := by
  unfold Term at *
  rw [ExceptT.run_bind]
  rcases h : m.run with _ | (e | a)
  · exact absurd h hm
  · simp
  · have : m = pure a := by apply ExceptT.ext; rw [h]; rfl
    simpa using hf a this

theorem term_ite {α : Type} {c : Prop} [Decidable c] {a b : Rust.M α} (ha : Term a) (hb : Term b) :
    Term (if c then a else b) := by
  split <;> assumption

/-! ## Accessors: `State::hard` and `State::snapshot` -/

/-- `hard` returns a copy of the `hard` field. -/
theorem hard_copy (s : State V S CAP) : State.hard_fn s = s.hard := rfl

/-- The result of `hard` is read from the `hard` field alone: every other field is
irrelevant (the typed form of the old source-place refinement). -/
theorem hard_source_read (s : State V S CAP) (snapshot : Option (Snapshot S))
    (entries : Vector (Option (Entry V)) CAP) (len : Rust.usize) :
    State.hard_fn { s with snapshot := snapshot, entries := entries, len := len } = s.hard := rfl

/-- `hard` is a total read of a shared borrow: it returns the field and cannot
panic or diverge (it is a pure function), and leaves the receiver unchanged. -/
theorem hard_loan_read (s : State V S CAP) :
    (pure (State.hard_fn s) : Rust.M HardState) = pure s.hard ∧ Term (pure (State.hard_fn s) : Rust.M HardState) :=
  ⟨rfl, term_pure _⟩

theorem snapshot_none (s : State V S CAP) (absent : s.snapshot = none) :
    State.snapshot_fn s = none := absent

theorem snapshot_some (s : State V S CAP) (payload : Snapshot S) (present : s.snapshot = some payload) :
    State.snapshot_fn s = some payload := present

/-- The returned reference resolves to exactly the stored payload. -/
theorem snapshot_borrowed_payload (s : State V S CAP) (payload : Snapshot S)
    (present : s.snapshot = some payload) :
    State.snapshot_fn s = some payload ∧ (State.snapshot_fn s).map (·.value) = some payload.value ∧
      (State.snapshot_fn s).map (·.last) = some payload.last := by
  simp [State.snapshot_fn, present]

/-- The returned snapshot is the `snapshot` field only: writes to any other field
(the only places a concurrent writer could hold) do not change it. -/
theorem snapshot_excludes_writes (s : State V S CAP) (payload : Snapshot S)
    (present : s.snapshot = some payload) (hard : HardState)
    (entries : Vector (Option (Entry V)) CAP) (len : Rust.usize) :
    State.snapshot_fn s = some payload ∧
      State.snapshot_fn { s with hard := hard, entries := entries, len := len } = some payload := by
  simp [State.snapshot_fn, present]

/-- Any returned snapshot is the live stored one. -/
theorem snapshot_result_is_live (s : State V S CAP) (returned : Snapshot S)
    (success : State.snapshot_fn s = some returned) :
    s.snapshot = some returned ∧ State.snapshot_fn s = s.snapshot :=
  ⟨success, rfl⟩

/-! ## Buffer shape -/

/-- The occupied-prefix invariant: slots below `len` are occupied, the rest empty.
(The slot array has exactly `CAP` slots by its type.) -/
def Shape (s : State V S CAP) : Prop :=
  s.len.val ≤ CAP ∧
  (∀ i, i < s.len.val → ∃ value, s.entries.toList[i]? = some (some value)) ∧
  (∀ i, s.len.val ≤ i → i < CAP → s.entries.toList[i]? = some none)

private theorem map_some_filterMap {α : Type} :
    ∀ (l : List (Option α)), (∀ x ∈ l, x.isSome) → (l.filterMap id).map some = l
  | [], _ => rfl
  | none :: _, h => by simp at h
  | some a :: l, h => by
    simp only [List.filterMap_cons, id, List.map_cons]
    rw [map_some_filterMap l (fun x hx => h x (by simp [hx]))]

theorem shape_iff_layout (s : State V S CAP) : Shape s ↔ Layout s := by
  constructor
  · rintro ⟨hlen, hocc, hemp⟩
    refine ⟨hlen, ?_⟩
    have hsome : ∀ x ∈ s.entries.toList.take s.len.val, x.isSome := by
      intro x hx
      obtain ⟨i, hi, hx⟩ := List.getElem_of_mem hx
      have hi' : i < s.len.val := by simp at hi; omega
      obtain ⟨v, hv⟩ := hocc i hi'
      rw [List.getElem_take] at hx
      rw [List.getElem?_eq_getElem (by simp; omega)] at hv
      simp only [Option.some.injEq] at hv
      rw [← hx, hv]; rfl
    have hdrop : s.entries.toList.drop s.len.val = List.replicate (CAP - s.len.val) none := by
      apply List.ext_getElem?
      intro i
      rw [List.getElem?_drop, List.getElem?_replicate]
      split
      · exact hemp _ (by omega) (by omega)
      · exact List.getElem?_eq_none (by simp; omega)
    unfold ret
    rw [map_some_filterMap _ hsome, ← hdrop, List.take_append_drop]
  · intro hl
    have hlr := len_eq s hl
    refine ⟨hl.1, ?_, ?_⟩
    · intro i hi
      refine ⟨(ret s)[i]'(by omega), ?_⟩
      rw [hl.2, List.getElem?_append_left (by simp; omega)]
      simp
    · intro i hi hc
      rw [hl.2, List.getElem?_append_right (by simp; omega)]
      simp only [List.length_map, List.getElem?_replicate]
      rw [if_pos (by omega)]

/-! ## `State::push` -/

/-- With room, `push` stores the entry in slot `len` and advances `len`, returning `Ok`. -/
theorem append_exact (s : State V S CAP) (input : Entry V)
    (shape : Shape s) (space : s.len.val < CAP) (word : CAP < 2 ^ Rust.usizeBits) :
    State.push s input =
      pure (.Ok (), { s with entries := s.entries.set s.len.val (some input) space,
                             len := ⟨s.len.val + 1, by uomega⟩ }) := by
  have hne : s.len ≠ Rust.usizeOf CAP := fun h => by
    have := congrArg Fin.val h; rw [Rust.val_usizeOf _ word] at this; omega
  have hlen : s.len.val + 1 < 2 ^ Rust.usizeBits := by uomega
  simp only [Rust.usizeBits_eq] at hlen
  have _ := shape
  simp [State.push, State.full, hne, space, hlen]

theorem append_preserves_shape (s : State V S CAP) (input : Entry V)
    (shape : Shape s) (space : s.len.val < CAP) (word : CAP < 2 ^ Rust.usizeBits) :
    ∃ next, State.push s input = pure (.Ok (), next) ∧ Shape next ∧ next.len.val = s.len.val + 1 := by
  obtain ⟨s', h1, _, _, _, h4, h5⟩ := push_ok s input word ((shape_iff_layout s).1 shape) space
  exact ⟨s', h1, (shape_iff_layout s').2 h5, h4⟩

/-- A full buffer rejects the entry with `Error::Full` and leaves the state unchanged.
(The typed translation has no destructor effects: the rejected input is simply
not stored.) -/
theorem full_preserves_state_at_drop (s : State V S CAP) (input : Entry V)
    (full : s.len.val = CAP) :
    State.push s input = pure (.Err .Full, s) :=
  push_full s input (by have := s.len.isLt; uomega) full

theorem append_preserves_prefix (s : State V S CAP) (input : Entry V)
    (shape : Shape s) (space : s.len.val < CAP) (word : CAP < 2 ^ Rust.usizeBits) :
    ∃ next, State.push s input = pure (.Ok (), next) ∧
      ∀ i, i < s.len.val → next.entries.toList[i]? = s.entries.toList[i]? := by
  refine ⟨_, append_exact s input shape space word, ?_⟩
  intro i hi
  simp only [Vector.toList_set]
  exact List.getElem?_set_ne (by omega)

/-- `push` writes only the `entries` and `len` fields (the typed form of binding the
projected buffer to the source places `entries`, `len` and `CAP`). -/
theorem append_representation (s : State V S CAP) (input : Entry V)
    (shape : Shape s) (space : s.len.val < CAP) (word : CAP < 2 ^ Rust.usizeBits) :
    ∃ next, State.push s input = pure (.Ok (), next) ∧
      next.hard = s.hard ∧ next.snapshot = s.snapshot ∧
      next.entries = s.entries.set s.len.val (some input) space ∧ next.len.val = s.len.val + 1 :=
  ⟨_, append_exact s input shape space word, rfl, rfl, rfl, rfl⟩

/-! ## `State::new` -/

/-- The fresh state is exactly the empty, default-metadata buffer, and it is shape-valid. -/
theorem fresh_representation :
    (State.new : State V S CAP).hard = HardState.default ∧
    (State.new : State V S CAP).snapshot = none ∧
    (State.new : State V S CAP).len.val = 0 ∧
    (State.new : State V S CAP).entries.toList = List.replicate CAP none ∧
    Shape (State.new : State V S CAP) := by
  have hl : (State.new : State V S CAP).entries.toList = List.replicate CAP none := by
    apply List.ext_getElem
    · simp [State.new, Rust.Slice.from_fn]
    · intro i h1 h2; simp [State.new, Rust.Slice.from_fn]
  refine ⟨rfl, rfl, rfl, hl, Nat.zero_le _, fun i hi => by simp [State.new] at hi, ?_⟩
  intro i _ hi
  rw [hl, List.getElem?_replicate, if_pos hi]

/-- Fresh initialization followed by successful appends. -/
inductive AppendHistory : State V S CAP → Prop where
  | fresh : AppendHistory State.new
  | append {s next : State V S CAP} (input : Entry V) :
      AppendHistory s → State.push s input = pure (.Ok (), next) → AppendHistory next

private theorem push_space (s : State V S CAP) (input : Entry V) (next : State V S CAP)
    (shape : Shape s)
    (execution : State.push s input = pure (.Ok (), next)) : s.len.val < CAP := by
  by_cases h : s.len.val < CAP
  · exact h
  · rw [full_preserves_state_at_drop s input (by have := shape.1; omega)] at execution
    have := Rust.pure_inj execution
    simp at this

private theorem push_shape (s : State V S CAP) (input : Entry V) (next : State V S CAP)
    (shape : Shape s) (word : CAP < 2 ^ Rust.usizeBits)
    (execution : State.push s input = pure (.Ok (), next)) : Shape next ∧ next.len.val = s.len.val + 1 := by
  obtain ⟨n, h, hs, hl⟩ := append_preserves_shape s input shape (push_space s input next shape execution) word
  rw [h] at execution
  have := Rust.pure_inj execution
  simp only [Prod.mk.injEq, true_and] at this
  subst this
  exact ⟨hs, hl⟩

theorem history_preserves_shape (s : State V S CAP) (input : Entry V)
    (word : CAP < 2 ^ Rust.usizeBits) (history : AppendHistory s) :
    Shape s ∧ (s.len.val < CAP →
      ∃ next, State.push s input = pure (.Ok (), next) ∧ Shape next ∧ next.len.val = s.len.val + 1) := by
  have shape : Shape s := by
    induction history with
    | fresh => exact fresh_representation.2.2.2.2
    | append input _ execution ih => exact (push_shape _ input _ ih word execution).1
  exact ⟨shape, fun space => append_preserves_shape s input shape space word⟩

/-! ## Monadic helpers -/

theorem fail_ne_pure {α : Type} (msg : String) (a : α) : (Rust.fail msg : Rust.M α) ≠ pure a := by
  intro h
  have := congrArg ExceptT.run h
  simp [Rust.fail, ExceptT.run_throw, ExceptT.run_pure] at this

theorem sub_pure {n : Nat} {a b c : Fin (2 ^ n)} (h : Rust.sub a b = pure c) :
    b.val ≤ a.val ∧ c.val = a.val - b.val := by
  unfold Rust.sub at h
  split at h
  · have := Rust.pure_inj h; subst this; simp_all
  · exact absurd h (fail_ne_pure _ _)

theorem set_pure {α : Type} {n : Nat} {a b : Vector α n} {i : Rust.usize} {v : α}
    (h : Rust.Slice.set a i v = pure b) : ∃ hi : i.val < n, b = a.set i.val v hi := by
  unfold Rust.Slice.set at h
  split at h
  · rename_i hi; exact ⟨hi, (Rust.pure_inj h).symm⟩
  · exact absurd h (fail_ne_pure _ _)

theorem term_last (s : State V S CAP) : Term (State.last s) := by
  unfold State.last State.entries_fn Rust.Slice.range
  apply term_bind
  · apply term_bind
    · split
      · exact term_pure _
      · exact term_fail _
    · intro _ _; exact term_pure _
  · intro _ _; exact term_pure _

theorem term_sub {n : Nat} (a b : Fin (2 ^ n)) : Term (Rust.sub a b) := by
  unfold Rust.sub; split
  · exact term_pure _
  · exact term_fail _

theorem term_add {n : Nat} (a b : Fin (2 ^ n)) : Term (Rust.add a b) := by
  unfold Rust.add; split
  · exact term_pure _
  · exact term_fail _

theorem term_set {α : Type} {n : Nat} (a : Vector α n) (i : Rust.usize) (v : α) :
    Term (Rust.Slice.set a i v) := by
  unfold Rust.Slice.set; split
  · exact term_pure _
  · exact term_fail _

/-- The last retained identity when slot `k` is the final occupied slot of the prefix. -/
theorem last_of_slot (s : State V S CAP) (k : Nat) (entry : Entry V) (hk : k < CAP)
    (length : s.len.val = k + 1) (hit : s.entries.toList[k]? = some (some entry)) :
    State.last s = pure entry.id := by
  rw [last_eq s (by omega)]
  unfold lastId ret
  rw [length, List.take_add_one, hit]
  simp [List.filterMap_append, List.getLast?_append]

/-! ## `State::truncate` -/

/-- One iteration of the truncation loop. -/
theorem truncate_step (s : State V S CAP) (f : Rust.u64) :
    State.truncate s f = (State.last s >>= fun t1 =>
      if (!(decide (t1.index ≥ f) && decide (s.len > 0))) = true then pure s else
      Rust.sub s.len 1 >>= fun t2 => Rust.Slice.set s.entries t2 none >>= fun t3 =>
        State.truncate { s with len := t2, entries := t3 } f) := by
  conv => lhs; unfold State.truncate
  simp only [bind_pure]
  change Lean.Loop.forIn _ s _ = _
  rw [Lean.Loop.forIn_eq_of_monadTail]
  simp only [bind_assoc]
  congr 1; funext t1
  split
  · simp
  · simp only [bind_assoc, pure_bind]
    congr 1; funext t2; congr 1; funext t3
    unfold State.truncate
    simp only [bind_pure]
    rfl

/-- Truncating an empty buffer returns it unchanged. -/
theorem truncation_empty (s : State V S CAP) (f : Rust.u64) (empty : s.len.val = 0) :
    State.truncate s f = pure s := by
  rw [truncate_step, last_eq s (by omega)]
  have : s.len = 0 := Fin.ext empty
  simp [this]

/-- Truncation never diverges, from any state (the typed counterpart of the old
interpreter-fuel sufficiency: the only loop always terminates). -/
theorem truncation_fuel_sufficient (s : State V S CAP) (f : Rust.u64) :
    Term (State.truncate s f) := by
  induction h : s.len.val generalizing s with
  | zero => rw [truncation_empty s f h]; exact term_pure _
  | succ n ih =>
    rw [truncate_step]
    apply term_bind (term_last s)
    intro t1 _
    split
    · exact term_pure _
    · apply term_bind (term_sub _ _)
      intro t2 ht2
      apply term_bind (term_set _ _ _)
      intro t3 _
      have h1 : (1 : Rust.usize).val = 1 := rfl
      have := (sub_pure ht2).2
      exact ih _ (by show t2.val = n; omega)

/-- When the last retained entry is at or after the boundary, truncation clears its
slot after decrementing `len`, then continues with the shortened buffer. -/
theorem truncation_drop_order (s : State V S CAP) (f : Rust.u64) (k : Nat) (entry : Entry V)
    (hk : k < CAP) (length : s.len.val = k + 1)
    (hit : s.entries.toList[k]? = some (some entry)) (remove : f.val ≤ entry.id.index.val) :
    State.truncate s f =
      State.truncate { s with len := ⟨k, by omega⟩, entries := s.entries.set k none hk } f := by
  rw [truncate_step, last_of_slot s k entry hk length hit]
  have c1 : entry.id.index ≥ f := by rw [ge_iff_le, Fin.le_def]; exact remove
  have c2 : s.len > 0 := Fin.lt_def.mpr (by simp; omega)
  have hsub : Rust.sub s.len 1 = pure ⟨k, by omega⟩ := by
    unfold Rust.sub; rw [dif_pos (by simp; omega)]; congr 2; simp; omega
  have hset : Rust.Slice.set s.entries ⟨k, by omega⟩ none = pure (s.entries.set k none hk) := by
    unfold Rust.Slice.set; rw [dif_pos hk]
  simp only [c1, c2, decide_true, Bool.and_self, Bool.not_true, Bool.false_eq_true, if_false,
    pure_bind, hsub, hset]

/-- Clearing the last occupied slot preserves the shape. -/
theorem pop_shape (s : State V S CAP) (shape : Shape s) (positive : 0 < s.len.val) :
    Shape { s with len := ⟨s.len.val - 1, by omega⟩,
                   entries := s.entries.set (s.len.val - 1) none (by have := shape.1; omega) } := by
  obtain ⟨hlen, hocc, hemp⟩ := shape
  refine ⟨by simp; omega, ?_, ?_⟩
  · intro i hi
    simp only [Vector.toList_set] at hi ⊢
    obtain ⟨v, hv⟩ := hocc i (by simp at hi; omega)
    exact ⟨v, by rw [List.getElem?_set_ne (by simp at hi; omega)]; exact hv⟩
  · intro i hi hc
    simp only [Vector.toList_set] at hi ⊢
    by_cases e : i = s.len.val - 1
    · subst e; rw [List.getElem?_set_self (by simp; omega)]
    · rw [List.getElem?_set_ne (Ne.symm e)]; exact hemp i (by omega) hc

theorem truncation_preserves_shape (s next : State V S CAP) (f : Rust.u64) (shape : Shape s)
    (execution : State.truncate s f = pure next) :
    Shape next ∧ next.len.val ≤ s.len.val ∧
      (∀ i, i < next.len.val → next.entries.toList[i]? = s.entries.toList[i]?) ∧
      next.hard = s.hard ∧ next.snapshot = s.snapshot := by
  induction h : s.len.val generalizing s with
  | zero =>
    rw [truncation_empty s f h] at execution
    cases Rust.pure_inj execution
    exact ⟨shape, by omega, fun _ _ => rfl, rfl, rfl⟩
  | succ n ih =>
    have hl := (shape_iff_layout s).1 shape
    by_cases cut : f.val ≤ (lastId s).index.val ∧ 0 < s.len.val
    · rw [truncate_pop s f hl cut] at execution
      have ps := pop_shape s shape cut.2
      obtain ⟨a, b, c, d, e⟩ := ih (pop s cut.2 hl.1) ps execution (by simp [pop]; omega)
      refine ⟨a, by simp at b; omega, ?_, d, e⟩
      intro i hi
      rw [c i hi]
      simp only [pop, Vector.toList_set]
      exact List.getElem?_set_ne (by simp at b; omega)
    · rw [truncate_stop s f hl cut] at execution
      cases Rust.pure_inj execution
      exact ⟨shape, by omega, fun _ _ => rfl, rfl, rfl⟩

/-! ## `State::install` -/

theorem range_pure {α : Type} {n : Nat} {a : Vector α n} {lo hi : Rust.usize} {b : Array α}
    (h : Rust.Slice.range a lo hi = pure b) : lo.val ≤ hi.val ∧ hi.val ≤ n ∧ b = a.toArray.extract lo.val hi.val := by
  unfold Rust.Slice.range at h
  split at h
  · rename_i c; exact ⟨c.1, c.2, (Rust.pure_inj h).symm⟩
  · exact absurd h (fail_ne_pure _ _)

theorem rotate_pure {α : Type} {a b : Array α} {k : Rust.usize}
    (h : Rust.Slice.rotate_left a k = pure b) : k.val ≤ a.size ∧ b = a.extract k.val a.size ++ a.extract 0 k.val := by
  unfold Rust.Slice.rotate_left at h
  split at h
  · rename_i c; exact ⟨c, (Rust.pure_inj h).symm⟩
  · exact absurd h (fail_ne_pure _ _)

theorem mapRange_pure {α : Type} {n : Nat} {a b : Vector α n} {lo hi : Rust.usize} {g : α → α}
    (h : Rust.Slice.mapRangeM a lo hi (fun e => pure (g e)) = pure b) :
    lo.val ≤ hi.val ∧ hi.val ≤ n ∧
      b = Vector.ofFn fun i : Fin n => if lo.val ≤ i.val ∧ i.val < hi.val then g a[i] else a[i] := by
  by_cases c : lo.val ≤ hi.val ∧ hi.val ≤ n
  · rw [Rust.Slice.mapRangeM_pure a lo hi g c] at h
    exact ⟨c.1, c.2, (Rust.pure_inj h).symm⟩
  · unfold Rust.Slice.mapRangeM at h
    rw [if_neg c] at h
    exact absurd h (fail_ne_pure _ _)

/-- Everything a returning `install` does. The removed prefix length is
`(index - base) as usize`, i.e. reduced modulo `2 ^ usizeBits`; that is the plain
difference on 64-bit targets, and on 32-bit ones whenever the slot array fits a
`usize` (see `installation_matching_suffix`). -/
theorem install_returns (s next : State V S CAP) (snap : Snapshot S)
    (h : State.install s snap = pure next) :
    next.hard = { s.hard with commit := Rust.max s.hard.commit snap.last.index } ∧
    next.snapshot = some snap ∧
    ((State.id_at s snap.last.index = some snap.last ∧
      s.base.index.val ≤ snap.last.index.val ∧ s.len.val ≤ CAP ∧
      (snap.last.index.val - s.base.index.val) % 2 ^ Rust.usizeBits ≤ s.len.val ∧
      next.len.val = s.len.val - (snap.last.index.val - s.base.index.val) % 2 ^ Rust.usizeBits ∧
      (CAP < 2 ^ Rust.usizeBits → next.entries.toList =
        (s.entries.toList.take s.len.val).drop
          ((snap.last.index.val - s.base.index.val) % 2 ^ Rust.usizeBits) ++
          List.replicate (CAP - next.len.val) none)) ∨
     (State.id_at s snap.last.index ≠ some snap.last ∧ s.len.val ≤ CAP ∧ next.len.val = 0 ∧
      next.entries.toList = List.replicate s.len.val none ++ s.entries.toList.drop s.len.val)) := by
  unfold State.install at h; dsimp only at h
  split at h
  · rename_i hm
    obtain ⟨t1, h1, h⟩ := Rust.bind_eq_pure h
    obtain ⟨t2, h2, h⟩ := Rust.bind_eq_pure h
    obtain ⟨t3, h3, h⟩ := Rust.bind_eq_pure h
    obtain ⟨t4, h4, h⟩ := Rust.bind_eq_pure h
    obtain ⟨t5, h5, h⟩ := Rust.bind_eq_pure h
    cases Rust.pure_inj h
    obtain ⟨b1, e1⟩ := sub_pure h1
    obtain ⟨_, b2, e2⟩ := range_pure h2
    obtain ⟨b3, e3⟩ := rotate_pure h3
    obtain ⟨b4, e4⟩ := sub_pure h4
    obtain ⟨b5, b5', e5⟩ := mapRange_pure h5
    subst e2 e3 e5
    have hm' : State.id_at s snap.last.index = some snap.last := by simpa using hm
    simp only [Array.size_extract] at b3
    -- `remove` is `(index - base) as usize`: the identity on 64-bit targets, reduction
    -- modulo `2 ^ 32` on 32-bit ones.
    have t1lt := t1.isLt
    have xlt : snap.last.index.val - s.base.index.val < 2 ^ 64 := e1 ▸ t1lt
    refine ⟨rfl, rfl, Or.inl ⟨hm', by omega, by simpa using b2, ?_, ?_, ?_⟩⟩
    all_goals ((try unfold Rust.cast at *); simp only [Rust.usizeBits_eq] at *)
    all_goals (try simp only [Nat.mod_eq_of_lt xlt] at *)
    · simp at b3; omega
    · simp; omega
    intro hcap
    apply List.ext_getElem
    · simp; omega
    · intro i hi1 hi2
      simp [Rust.Slice.setRange, Rust.val_usizeOf _ hcap] at hi1 ⊢
      have m1 : min s.len.val CAP = s.len.val := Nat.min_eq_left (by simpa using b2)
      simp only [m1]
      by_cases hi : i < t4.val
      · rw [if_neg (by omega), dif_pos (by omega), Array.getElem_append_left (by simp; omega),
          List.getElem_append_left (by simp; omega)]
        simp [e1]
      · rw [if_pos (by omega), List.getElem_append_right (by simp; omega)]
        simp
  · rename_i hm
    obtain ⟨t6, h6, h⟩ := Rust.bind_eq_pure h
    cases Rust.pure_inj h
    obtain ⟨_, b6, e6⟩ := mapRange_pure h6
    subst e6
    refine ⟨rfl, rfl, Or.inr ⟨by simpa using hm, by simpa using b6, rfl, ?_⟩⟩
    apply List.ext_getElem
    · simp; omega
    · intro i hi1 hi2
      simp at hi1 ⊢
      by_cases hi : i < s.len.val
      · rw [if_pos hi, List.getElem_append_left (by simp; omega)]
        simp
      · rw [if_neg hi, List.getElem_append_right (by simp; omega)]
        simp; congr 1; omega

theorem exists_bind {α β : Type} {m : Rust.M α} {f : α → Rust.M β} (a : α) (hm : m = pure a)
    (hf : ∃ b, f a = pure b) : ∃ b, m >>= f = pure b := by
  rw [hm, pure_bind]; exact hf

theorem install_match_returns (s : State V S CAP) (snap : Snapshot S)
    (hm : State.id_at s snap.last.index = some snap.last)
    (hb : s.base.index.val ≤ snap.last.index.val) (hlen : s.len.val ≤ CAP)
    (hr : snap.last.index.val - s.base.index.val ≤ s.len.val) (hcap : CAP < 2 ^ Rust.usizeBits) :
    ∃ next, State.install s snap = pure next := by
  unfold State.install; dsimp only
  rw [if_pos (by simp [hm])]
  refine exists_bind _ (Rust.sub_ok _ _ hb) ?_
  refine exists_bind _ (Rust.Slice.range_ok _ _ _ ⟨Nat.zero_le _, hlen⟩) ?_
  have := s.len.isLt
  refine exists_bind _ (Rust.Slice.rotate_left_ok _ _ (by (try unfold Rust.cast); simp; uomega)) ?_
  refine exists_bind _ (Rust.sub_ok _ _ (by (try unfold Rust.cast); simp; uomega)) ?_
  refine exists_bind _ (Rust.Slice.mapRangeM_pure _ _ _ (fun _ => none) ?_) ?_
  · simp [Rust.val_usizeOf _ hcap]; omega
  · exact ⟨_, rfl⟩

theorem install_mismatch_returns (s : State V S CAP) (snap : Snapshot S)
    (hm : State.id_at s snap.last.index ≠ some snap.last) (hlen : s.len.val ≤ CAP) :
    ∃ next, State.install s snap = pure next := by
  unfold State.install; dsimp only
  rw [if_neg (by simp [hm])]
  refine exists_bind _ (Rust.Slice.mapRangeM_pure _ _ _ (fun _ => none) ⟨Nat.zero_le _, hlen⟩) ?_
  exact ⟨_, rfl⟩

private theorem layout_split (s : State V S CAP) (hl : Layout s) :
    s.entries.toList.take s.len.val = (ret s).map some ∧
      s.entries.toList.drop s.len.val = List.replicate (CAP - s.len.val) none := by
  have hlr := len_eq s hl
  constructor
  · rw [hl.2, List.take_append_of_le_length (by simp; omega), hlr,
      List.take_of_length_le (by simp)]
  · rw [hl.2, List.drop_append_of_le_length (by simp; omega)]
    simp [hlr]

theorem installation_preserves_capacity_and_commit (s next : State V S CAP) (snap : Snapshot S)
    (execution : State.install s snap = pure next) :
    next.len.val ≤ s.len.val ∧ s.hard.commit.val ≤ next.hard.commit.val ∧ next.snapshot = some snap := by
  obtain ⟨hh, hs, rest⟩ := install_returns s next snap execution
  refine ⟨?_, by rw [hh]; simp only [Rust.val_max]; exact Nat.le_max_left _ _, hs⟩
  rcases rest with ⟨_, _, _, _, hl, _⟩ | ⟨_, _, hl, _⟩ <;> omega

/-- `install` writes only `entries`, `len`, `snapshot` and `hard.commit`
(the typed form of binding the operation to its source places). -/
theorem installation_places (s next : State V S CAP) (snap : Snapshot S)
    (execution : State.install s snap = pure next) :
    next.hard.term = s.hard.term ∧ next.hard.voted_for = s.hard.voted_for ∧
    next.hard.commit = Rust.max s.hard.commit snap.last.index ∧
    next.len.val ≤ s.len.val ∧ s.hard.commit.val ≤ next.hard.commit.val ∧ next.snapshot = some snap := by
  obtain ⟨hh, _, _⟩ := install_returns s next snap execution
  have := installation_preserves_capacity_and_commit s next snap execution
  rw [hh] at this ⊢
  exact ⟨rfl, rfl, rfl, this⟩

/-- A matching boundary (decided by the original `id_at` lookup and field-wise
`LogId` equality) keeps exactly the suffix after it. -/
theorem installation_matching_suffix_by_equality (s : State V S CAP) (snap : Snapshot S)
    (removed retained padding : List (Option (Entry V))) (found : LogId)
    (slots : s.entries.toList = removed ++ retained ++ padding)
    (length : s.len.val = removed.length + retained.length)
    (index : snap.last.index.val = s.base.index.val + removed.length)
    (matched : State.id_at s snap.last.index = some found)
    (equal : found.index = snap.last.index ∧ found.term = snap.last.term) (word : CAP < 2 ^ Rust.usizeBits) :
    ∃ next, State.install s snap = pure next ∧
      next.entries.toList = retained ++ List.replicate (removed.length + padding.length) none ∧
      next.len.val = retained.length ∧
      next.hard = { s.hard with commit := Rust.max s.hard.commit snap.last.index } ∧
      next.snapshot = some snap := by
  have hf : found = snap.last := by cases found; cases h : snap.last; simp_all
  subst hf
  have size := congrArg List.length slots
  simp only [Vector.length_toList, List.length_append] at size
  obtain ⟨next, h⟩ := install_match_returns s snap matched (by omega) (by omega) (by omega) word
  obtain ⟨hh, hs, rest⟩ := install_returns s next snap h
  rcases rest with ⟨_, _, _, _, hl, he⟩ | ⟨hm, _⟩
  · have r : (snap.last.index.val - s.base.index.val) % 2 ^ Rust.usizeBits = removed.length := by
      have := s.len.isLt; uomega
    refine ⟨next, h, ?_, by omega, hh, hs⟩
    have tk : List.take (removed.length + retained.length) (removed ++ retained ++ padding) =
        removed ++ retained := List.take_left' (by simp)
    rw [he word, slots, length, hl, length, r, tk, List.drop_left]
    congr 2; omega
  · exact absurd matched hm

theorem installation_matching_suffix (s : State V S CAP) (snap : Snapshot S)
    (removed retained padding : List (Option (Entry V)))
    (slots : s.entries.toList = removed ++ retained ++ padding)
    (length : s.len.val = removed.length + retained.length)
    (index : snap.last.index.val = s.base.index.val + removed.length)
    (matched : State.id_at s snap.last.index = some snap.last) (word : CAP < 2 ^ Rust.usizeBits) :
    ∃ next, State.install s snap = pure next ∧
      next.entries.toList = retained ++ List.replicate (removed.length + padding.length) none ∧
      next.len.val = retained.length ∧
      next.hard = { s.hard with commit := Rust.max s.hard.commit snap.last.index } ∧
      next.snapshot = some snap :=
  installation_matching_suffix_by_equality s snap removed retained padding snap.last slots length index
    matched ⟨rfl, rfl⟩ word

/-- A mismatching boundary clears the whole occupied prefix. -/
theorem installation_mismatching_prefix (s : State V S CAP) (snap : Snapshot S)
    (retained padding : List (Option (Entry V)))
    (slots : s.entries.toList = retained ++ padding) (length : s.len.val = retained.length)
    (different : State.id_at s snap.last.index ≠ some snap.last) :
    ∃ next, State.install s snap = pure next ∧
      next.entries.toList = List.replicate retained.length none ++ padding ∧
      next.len.val = 0 ∧
      next.hard = { s.hard with commit := Rust.max s.hard.commit snap.last.index } ∧
      next.snapshot = some snap := by
  have size := congrArg List.length slots
  simp only [Vector.length_toList, List.length_append] at size
  obtain ⟨next, h⟩ := install_mismatch_returns s snap different (by omega)
  obtain ⟨hh, hs, rest⟩ := install_returns s next snap h
  rcases rest with ⟨hm, _⟩ | ⟨_, _, hl, he⟩
  · exact absurd hm different
  · refine ⟨next, h, ?_, hl, hh, hs⟩
    rw [he, slots, length, List.drop_left]

theorem installation_preserves_shape (s next : State V S CAP) (snap : Snapshot S)
    (shape : Shape s) (word : CAP < 2 ^ Rust.usizeBits)
    (execution : State.install s snap = pure next) : Shape next := by
  have hl := (shape_iff_layout s).1 shape
  have hlr := len_eq s hl
  obtain ⟨tk, dr⟩ := layout_split s hl
  obtain ⟨_, _, rest⟩ := install_returns s next snap execution
  apply (shape_iff_layout next).2
  rcases rest with ⟨_, _, _, hr, hlen, he⟩ | ⟨_, _, hlen, he⟩
  · refine (layout_of next ((ret s).drop ((snap.last.index.val - s.base.index.val) % 2 ^ Rust.usizeBits))
      (by simp; uomega) (by simp; uomega) ?_).1
    rw [he word, tk, ← List.map_drop]
    congr 2; simp; uomega
  · refine (layout_of next [] hlen (Nat.zero_le _) ?_).1
    rw [he, dr, List.replicate_append_replicate]
    simp; omega

/-! ## Logical log representation -/

/-- A chain of entries rooted at `base`: each entry's index is its predecessor's
plus one, its term is positive, at least its predecessor's, and at most the hard
term. The last argument is the chain's final identity. -/
inductive Ordered (hard : HardState) (base : LogId) : List (Entry V) → LogId → Prop where
  | empty : Ordered hard base [] base
  | snoc {entries : List (Entry V)} {previous : LogId} (entry : Entry V) :
      Ordered hard base entries previous →
      entry.id.index.val = previous.index.val + 1 → 0 < entry.id.term.val →
      previous.term.val ≤ entry.id.term.val → entry.id.term.val ≤ hard.term.val →
      Ordered hard base (entries ++ [entry]) entry.id

/-- The scalar successor conditions an appended entry must satisfy. -/
def LogSuccessor (hard : HardState) (previous entry : LogId) : Prop :=
  entry.index.val = previous.index.val + 1 ∧ 0 < entry.term.val ∧
    previous.term.val ≤ entry.term.val ∧ entry.term.val ≤ hard.term.val

/-- A shape-valid buffer whose occupied prefix is an ordered chain from `base`. -/
def LogRep (hard : HardState) (base : LogId) (s : State V S CAP) : Prop :=
  Shape s ∧ ∃ entries last,
    s.entries.toList = entries.map some ++ List.replicate (CAP - s.len.val) none ∧
    s.len.val = entries.length ∧ Ordered hard base entries last

theorem ordered_last_index {hard : HardState} {base last : LogId} {entries : List (Entry V)}
    (chain : Ordered hard base entries last) : last.index.val = base.index.val + entries.length := by
  induction chain with
  | empty => simp
  | snoc entry _ successor _ _ _ ih => simp [successor, ih]; omega

theorem ordered_entry_index {hard : HardState} {base last : LogId} {entries : List (Entry V)}
    (chain : Ordered hard base entries last) :
    ∀ position entry, entries[position]? = some entry →
      entry.id.index.val = base.index.val + position + 1 := by
  induction chain with
  | empty => simp
  | @snoc entries previous entry inner successor _ _ _ ih =>
    intro position found present
    by_cases earlier : position < entries.length
    · rw [List.getElem?_append_left earlier] at present
      exact ih position found present
    · rw [List.getElem?_append_right (by omega)] at present
      have : position = entries.length := by
        rcases Nat.lt_or_ge position (entries.length + 1) with h | h
        · omega
        · rw [List.getElem?_eq_none (by simp; omega)] at present
          contradiction
      subst this
      simp only [Nat.sub_self, List.getElem?_cons_zero, Option.some.injEq] at present
      subst present
      rw [successor, ordered_last_index inner]

theorem ordered_split {hard : HardState} {base last : LogId} {entries : List (Entry V)}
    (chain : Ordered hard base entries last) :
    ∀ count, count ≤ entries.length → ∃ middle,
      Ordered hard base (entries.take count) middle ∧ Ordered hard middle (entries.drop count) last := by
  induction chain with
  | empty => intro count _; exact ⟨base, by simpa using Ordered.empty, by simpa using Ordered.empty⟩
  | @snoc entries previous entry inner successor positive monotone upper ih =>
    intro count bound
    by_cases earlier : count ≤ entries.length
    · obtain ⟨middle, left, right⟩ := ih count earlier
      refine ⟨middle, by simpa only [List.take_append_of_le_length earlier] using left, ?_⟩
      rw [List.drop_append_of_le_length earlier]
      exact .snoc entry right successor positive monotone upper
    · have full : (entries ++ [entry]).length ≤ count := by simp at bound ⊢; omega
      rw [List.take_of_length_le full, List.drop_of_length_le full]
      exact ⟨entry.id, .snoc entry inner successor positive monotone upper, .empty⟩

theorem ordered_take {hard : HardState} {base last : LogId} {entries : List (Entry V)}
    (chain : Ordered hard base entries last) (count : Nat) (bound : count ≤ entries.length) :
    ∃ record, Ordered hard base (entries.take count) record :=
  let ⟨m, h, _⟩ := ordered_split chain count bound; ⟨m, h⟩

theorem ordered_nil {hard : HardState} {base last : LogId}
    (chain : Ordered hard base ([] : List (Entry V)) last) : last = base := by
  generalize e : ([] : List (Entry V)) = l at chain
  cases chain with
  | empty => rfl
  | snoc => simp at e

/-- The chain's final identity, as the translation's `last` would compute it. -/
theorem ordered_getLast {hard : HardState} {base last : LogId} {entries : List (Entry V)}
    (chain : Ordered hard base entries last) : (entries.getLast?.map (·.id)).getD base = last := by
  cases chain with
  | empty => rfl
  | snoc entry _ _ _ _ _ => simp

theorem logrep_layout {hard : HardState} {base : LogId} {s : State V S CAP}
    (valid : LogRep hard base s) :
    Layout s ∧ ∃ last, Ordered hard base (ret s) last := by
  obtain ⟨shape, entries, last, slots, length, chain⟩ := valid
  have hr := ret_of_slots s entries length (by rw [slots, length])
  exact ⟨(shape_iff_layout s).1 shape, last, hr ▸ chain⟩

theorem logrep_last {hard : HardState} {s : State V S CAP}
    (valid : LogRep hard s.base s) :
    ∃ last, State.last s = pure last ∧ Ordered hard s.base (ret s) last := by
  obtain ⟨hl, last, chain⟩ := logrep_layout valid
  refine ⟨last, ?_, chain⟩
  rw [last_eq s hl.1, lastId, ordered_getLast chain]

theorem logrep_contig {hard : HardState} {s : State V S CAP} (valid : LogRep hard s.base s) : Contig s := by
  obtain ⟨_, last, chain⟩ := logrep_layout valid
  intro k hk
  exact ordered_entry_index chain k _ (List.getElem?_eq_getElem hk)

private theorem logrep_of_layout {hard : HardState} {base last : LogId} {s : State V S CAP}
    (hl : Layout s) (chain : Ordered hard base (ret s) last) : LogRep hard base s :=
  ⟨(shape_iff_layout s).2 hl, ret s, last, by rw [hl.2, len_eq s hl], len_eq s hl, chain⟩

private theorem log_rep_prefix {hard : HardState} {base : LogId} (s next : State V S CAP)
    (valid : LogRep hard base s) (shape : Shape next) (shorter : next.len.val ≤ s.len.val)
    (unchanged : ∀ i, i < next.len.val → next.entries.toList[i]? = s.entries.toList[i]?) :
    LogRep hard base next := by
  obtain ⟨hl, last, chain⟩ := logrep_layout valid
  have hln := (shape_iff_layout next).1 shape
  have hlr := len_eq s hl
  have hnr := len_eq next hln
  have same : ret next = (ret s).take next.len.val := by
    apply List.ext_getElem?
    intro i
    have a := slot_eq next hln i
    have b := slot_eq s hl i
    by_cases inside : i < next.len.val
    · rw [← a, unchanged i inside, b, List.getElem?_take_of_lt inside]
    · rw [List.getElem?_eq_none (by omega), List.getElem?_eq_none (by simp; omega)]
  obtain ⟨record, prefixChain⟩ := ordered_take chain next.len.val (by omega)
  exact logrep_of_layout hln (same ▸ prefixChain)

/-! ### Truncation and the log -/

theorem truncation_preserves_log {hard : HardState} {base : LogId} (s next : State V S CAP)
    (f : Rust.u64) (valid : LogRep hard base s)
    (execution : State.truncate s f = pure next) :
    LogRep hard base next ∧ next.len.val ≤ s.len.val := by
  obtain ⟨shape, shorter, unchanged, _, _⟩ := truncation_preserves_shape s next f valid.1 execution
  exact ⟨log_rep_prefix s next valid shape shorter unchanged, shorter⟩

/-- On a valid log, truncation returns, keeps an ordered prefix, and keeps exactly
the entries below the boundary. -/
theorem truncation_complete_result {hard : HardState} {base : LogId} (s : State V S CAP)
    (f : Rust.u64) (selected : s.base = base) (valid : LogRep hard base s) :
    ∃ next, State.truncate s f = pure next ∧ LogRep hard base next ∧
      next.len.val = min s.len.val (f.val - (base.index.val + 1)) ∧
      ∀ position, position < next.len.val →
        next.entries.toList[position]? = s.entries.toList[position]? := by
  subst selected
  obtain ⟨hl, _, _⟩ := logrep_layout valid
  obtain ⟨next, h, _, _, hr, hln, _⟩ := truncate_spec s f hl (logrep_contig valid)
  obtain ⟨_, _, unchanged, _, _⟩ := truncation_preserves_shape s next f valid.1 h
  refine ⟨next, h, (truncation_preserves_log s next f valid h).1, ?_, unchanged⟩
  rw [len_eq next hln, hr, List.length_take, ← len_eq s hl]
  omega

theorem truncation_preserves_committed_prefix {hard : HardState} {base : LogId}
    (s next : State V S CAP) (f : Rust.u64) (commit : Nat)
    (selected : s.base = base) (valid : LogRep hard base s)
    (commitBounds : base.index.val ≤ commit ∧ commit ≤ base.index.val + s.len.val)
    (authorized : commit < f.val)
    (execution : State.truncate s f = pure next) :
    LogRep hard base next ∧ commit ≤ base.index.val + next.len.val ∧
      ∀ position, position < commit - base.index.val →
        next.entries.toList[position]? = s.entries.toList[position]? := by
  obtain ⟨n, h, rep, length, unchanged⟩ := truncation_complete_result s f selected valid
  rw [h] at execution
  cases Rust.pure_inj execution
  exact ⟨rep, by omega, fun position inside => unchanged position (by omega)⟩

/-- Truncating just after a retained entry leaves that entry's identity as `last()`. -/
theorem truncation_retains_predecessor {hard : HardState} {base : LogId}
    (s shortened : State V S CAP) (f : Rust.u64) (position : Nat) (entry : Entry V)
    (selected : s.base = base) (valid : LogRep hard base s)
    (cut : f.val = base.index.val + position + 2) (inside : position < s.len.val)
    (hit : s.entries.toList[position]? = some (some entry))
    (execution : State.truncate s f = pure shortened) :
    State.last shortened = pure entry.id := by
  obtain ⟨n, h, rep, length, unchanged⟩ := truncation_complete_result s f selected valid
  rw [h] at execution
  cases Rust.pure_inj execution
  exact last_of_slot shortened position entry (by have := valid.1.1; omega) (by omega)
    ((unchanged position (by omega)).trans hit)

/-- Truncating just after the boundary leaves the boundary as `last()`. -/
theorem truncation_retains_base {hard : HardState} {base : LogId}
    (s shortened : State V S CAP) (f : Rust.u64)
    (selected : s.base = base) (valid : LogRep hard base s)
    (cut : f.val = base.index.val + 1)
    (execution : State.truncate s f = pure shortened) :
    State.last shortened = pure base := by
  obtain ⟨n, h, rep, length, _⟩ := truncation_complete_result s f selected valid
  rw [h] at execution
  cases Rust.pure_inj execution
  have empty : shortened.len.val = 0 := by omega
  have hb : shortened.base = s.base := by
    obtain ⟨_, _, _, _, hs⟩ := truncation_preserves_shape s shortened f valid.1 h
    simp [State.base, hs]
  rw [last_eq shortened (by omega), lastId, ret, empty]
  simp [hb, selected]

/-! ### Appending and the log -/

theorem append_preserves_log {hard : HardState} {base last : LogId} (s : State V S CAP)
    (input : Entry V) (selected : s.base = base) (valid : LogRep hard base s)
    (space : s.len.val < CAP) (word : CAP < 2 ^ Rust.usizeBits)
    (fetched : State.last s = pure last) (follows : LogSuccessor hard last input.id) :
    ∃ next, State.push s input = pure (.Ok (), next) ∧ LogRep hard base next ∧
      next.len.val = s.len.val + 1 ∧
      ∀ position, position < s.len.val →
        next.entries.toList[position]? = s.entries.toList[position]? := by
  subst selected
  obtain ⟨last', hlast, chain⟩ := logrep_last valid
  rw [hlast] at fetched
  cases Rust.pure_inj fetched
  obtain ⟨hl, _⟩ := logrep_layout valid
  obtain ⟨next, h, _, _, hr, hlen, hln⟩ := push_ok s input word hl space
  obtain ⟨_, h', unchanged⟩ := append_preserves_prefix s input valid.1 space word
  rw [h] at h'
  cases (Prod.mk.inj (Rust.pure_inj h')).2
  obtain ⟨succ, pos, mono, up⟩ := follows
  refine ⟨next, h, logrep_of_layout hln (hr ▸ Ordered.snoc input chain succ pos mono up), hlen, unchanged⟩

theorem append_preserves_committed_prefix (s : State V S CAP) (input : Entry V) (baseIndex commit : Nat)
    (shape : Shape s) (space : s.len.val < CAP) (word : CAP < 2 ^ Rust.usizeBits)
    (commitBounds : baseIndex ≤ commit ∧ commit ≤ baseIndex + s.len.val) :
    ∃ next, State.push s input = pure (.Ok (), next) ∧
      commit ≤ baseIndex + next.len.val ∧
      ∀ position, position < commit - baseIndex →
        next.entries.toList[position]? = s.entries.toList[position]? := by
  obtain ⟨next, h, _, hlen⟩ := append_preserves_shape s input shape space word
  obtain ⟨_, h', unchanged⟩ := append_preserves_prefix s input shape space word
  rw [h] at h'
  cases (Prod.mk.inj (Rust.pure_inj h')).2
  exact ⟨next, h, by omega, fun position inside => unchanged position (by omega)⟩

/-! ### Installation and the log -/

/-- A matching installation keeps an ordered log rooted at the snapshot, the exact
retained payloads, and a commit inside the new log. -/
theorem installation_matching_preserves_log {hard : HardState} {base last : LogId}
    (s : State V S CAP) (snap : Snapshot S) (removed retained : List (Entry V)) (padding : Nat)
    (found : LogId)
    (slots : s.entries.toList = removed.map some ++ retained.map some ++ List.replicate padding none)
    (length : s.len.val = removed.length + retained.length)
    (chain : Ordered hard base (removed ++ retained) last)
    (selected : s.base = base)
    (index : snap.last.index.val = base.index.val + removed.length)
    (commitBound : s.hard.commit.val ≤ base.index.val + removed.length + retained.length)
    (matched : State.id_at s snap.last.index = some found)
    (equal : found.index = snap.last.index ∧ found.term = snap.last.term) (word : CAP < 2 ^ Rust.usizeBits) :
    ∃ next, State.install s snap = pure next ∧
      LogRep hard snap.last next ∧
      next.snapshot = some snap ∧
      next.hard.commit.val = max s.hard.commit.val (base.index.val + removed.length) ∧
      base.index.val + removed.length ≤ next.hard.commit.val ∧
      next.hard.commit.val ≤ base.index.val + removed.length + next.len.val ∧
      ∀ position, position < next.len.val →
        next.entries.toList[position]? = s.entries.toList[removed.length + position]? := by
  have hf : found = snap.last := by cases found; cases h : snap.last; simp_all
  subst hf
  have size := congrArg List.length slots
  simp only [Vector.length_toList, List.length_append, List.length_map, List.length_replicate] at size
  obtain ⟨next, h, he, hlen, hh, hs⟩ := installation_matching_suffix_by_equality s snap
    (removed.map some) (retained.map some) (List.replicate padding none) snap.last slots
    (by simpa using length) (by simpa [selected] using index) matched ⟨rfl, rfl⟩ word
  simp only [List.length_map, List.length_replicate] at he hlen
  -- the boundary identity is the last removed entry's (or the old base)
  obtain ⟨middle, front, back⟩ := ordered_split chain removed.length (by simp)
  simp only [List.take_left, List.drop_left] at front back
  have hl : Layout s := (layout_of s (removed ++ retained) (by simpa using length)
      (by simp; omega) (by rw [slots]; simp; congr 2; omega)).1
  have hret : ret s = removed ++ retained :=
    ret_of_slots s _ (by simpa using length) (by rw [slots]; simp; congr 2; omega)
  have boundary : middle = snap.last := by
    have look := id_at_eq s hl snap.last.index
    rw [matched] at look
    unfold idAt at look
    by_cases e : removed = []
    · subst e
      have := ordered_nil front
      subst this
      simp [selected, index] at look
      exact look.symm
    · have pos : 0 < removed.length := List.length_pos_iff.mpr e
      rw [if_neg (by rw [selected]; omega), if_pos (by rw [selected]; omega)] at look
      rw [hret, selected, index, List.getElem?_append_left (by omega)] at look
      have := ordered_getLast front
      rw [List.getLast?_eq_getElem?] at this
      simp only [show base.index.val + removed.length - base.index.val - 1 = removed.length - 1 by omega] at look
      rw [← this]
      cases hx : removed[removed.length - 1]? with
      | none => simp [hx] at look
      | some x => simp [hx] at look ⊢; exact look.symm
  subst boundary
  have nextShape := installation_preserves_shape s next snap ((shape_iff_layout s).2 hl) word h
  refine ⟨next, h, ⟨nextShape, retained, last, ?_, hlen, back⟩, hs, ?_, ?_, ?_, ?_⟩
  · rw [he, hlen]; congr 2; omega
  · rw [hh]; simp [index]
  · rw [hh]; simp only [Rust.val_max, index, Nat.max_def]; split <;> omega
  · rw [hh, hlen]; simp only [Rust.val_max, index, Nat.max_def]; split <;> omega
  · intro position inside
    rw [he, slots, List.getElem?_append_left (by simp; omega), List.append_assoc,
      List.getElem?_append_right (by simp), List.getElem?_append_left (by simp; omega)]
    simp

/-- A mismatching installation (whose snapshot covers the old commit) leaves an
empty log rooted at the snapshot and commits exactly the snapshot index. -/
theorem installation_mismatching_resets_log {hard : HardState} (s : State V S CAP) (snap : Snapshot S)
    (entries : List (Entry V)) (padding : Nat)
    (slots : s.entries.toList = entries.map some ++ List.replicate padding none)
    (length : s.len.val = entries.length)
    (covered : s.hard.commit.val ≤ snap.last.index.val)
    (different : State.id_at s snap.last.index ≠ some snap.last) (word : CAP < 2 ^ Rust.usizeBits) :
    ∃ next, State.install s snap = pure next ∧
      LogRep hard snap.last next ∧ next.len.val = 0 ∧
      next.hard.commit = snap.last.index ∧ next.snapshot = some snap := by
  have size := congrArg List.length slots
  simp only [Vector.length_toList, List.length_append, List.length_map, List.length_replicate] at size
  obtain ⟨next, h, he, hlen, hh, hs⟩ := installation_mismatching_prefix s snap (entries.map some)
    (List.replicate padding none) slots (by simpa using length) different
  have hl : Layout s := (layout_of s entries length (by omega) (by rw [slots]; congr 2; omega)).1
  have nextShape := installation_preserves_shape s next snap ((shape_iff_layout s).2 hl) word h
  refine ⟨next, h, ⟨nextShape, [], snap.last, ?_, by simpa using hlen, .empty⟩, hlen, ?_, hs⟩
  · rw [he, hlen]; simp [List.replicate_append_replicate]; omega
  · rw [hh]; apply Fin.ext; simp only [Rust.val_max, Nat.max_def]; split <;> omega

/-! ## `State::restore` -/

/-- The snapshot boundary selected by `State::base` for a given snapshot field. -/
def boundaryOf (snap : Option (Snapshot S)) : LogId :=
  Rust.Option.map_or snap LogId.default (fun s => s.last)

/-- `restore`'s initial validation guard (`true` rejects). -/
def initialGuard (hard : HardState) (snap : Option (Snapshot S)) : Bool :=
  (snap.isSome && ((boundaryOf snap).index == 0 || (boundaryOf snap).term == 0)) ||
    decide ((boundaryOf snap).term > hard.term) || (hard.term == 0 && hard.voted_for.isSome)

/-- `restore`'s per-entry guard (`true` rejects). -/
def entryGuard (hard : HardState) (last : LogId) (entry : Entry V) : Bool :=
  (Rust.checked_add last.index 1 != some entry.id.index) || (entry.id.term == 0) ||
    decide (entry.id.term < last.term) || decide (entry.id.term > hard.term)

/-- The initial state of `restore`, before entries are appended. -/
def initial (hard : HardState) (snap : Option (Snapshot S)) : State V S CAP :=
  { (State.new : State V S CAP) with hard := hard, snapshot := snap }

/-- The body of `restore`'s entry loop. -/
def restoreBody (hard : HardState) (entry : Rust.M (Entry V))
    (acc : Option (Rust.Result (State V S CAP) Error) × State V S CAP) :
    Rust.M (ForInStep (Option (Rust.Result (State V S CAP) Error) × State V S CAP)) := do
  let state := acc.2
  let entry ← entry
  let last ← State.last state
  if entryGuard hard last entry then
    pure (ForInStep.done (some (Rust.Result.Err Error.State), state))
  else do
    let x ← State.push state entry
    match x.1 with
    | Rust.Result.Ok _ => pure (ForInStep.yield (none, x.2))
    | Rust.Result.Err e => pure (ForInStep.done (some (Rust.Result.Err e), x.2))

/-- What `restore` does after the loop. -/
def restoreFinish (hard : HardState) (base : LogId)
    (acc : Option (Rust.Result (State V S CAP) Error) × State V S CAP) :
    Rust.M (Rust.Result (State V S CAP) Error) :=
  match acc.1 with
  | some r => pure r
  | none =>
    if !(decide (hard.commit < base.index)) then do
      let last ← State.last acc.2
      if decide (hard.commit > last.index) then pure (Rust.Result.Err Error.State)
      else pure (Rust.Result.Ok acc.2)
    else pure (Rust.Result.Err Error.State)

theorem bind_congr2 {α β : Type} {a a' : Rust.M α} {f f' : α → Rust.M β} (h1 : a = a') (h2 : f = f') :
    a >>= f = a' >>= f' := by subst h1 h2; rfl

theorem restore_eq (hard : HardState) (snap : Option (Snapshot S)) (entries : List (Rust.M (Entry V))) :
    (State.restore hard snap entries : Rust.M (Rust.Result (State V S CAP) Error)) =
      if initialGuard hard snap then pure (Rust.Result.Err Error.State)
      else forIn entries (none, initial hard snap) (restoreBody hard) >>=
        restoreFinish hard (boundaryOf snap) := by
  unfold State.restore initialGuard boundaryOf initial State.base
  dsimp only
  split
  · rfl
  · refine bind_congr2 ?_ ?_
    · congr 1
    · funext acc
      unfold restoreFinish
      rcases acc with ⟨r, m⟩
      cases r <;> simp

theorem entryGuard_false (hard : HardState) (last : LogId) (entry : Entry V) :
    entryGuard hard last entry = false ↔ LogSuccessor hard last entry.id := by
  unfold entryGuard LogSuccessor
  have hb := entry.id.index.isLt
  by_cases c : last.index.val + 1 < 2 ^ 64
  · have e1 : Rust.checked_add last.index 1 = some ⟨last.index.val + 1, c⟩ := by
      simp [Rust.checked_add, c]
    rw [e1]
    simp only [Bool.or_eq_false_iff, bne_eq_false_iff_eq, Option.some.injEq, beq_eq_false_iff_ne,
      decide_eq_false_iff_not, Fin.ext_iff, Fin.lt_def, ne_eq]
    have z : ((0 : Rust.u64) : Nat) = 0 := rfl
    rw [z]
    omega
  · have e1 : Rust.checked_add last.index 1 = none := by
      simp [Rust.checked_add, c]
    rw [e1]
    simp only [Bool.or_eq_false_iff, bne_eq_false_iff_eq, reduceCtorEq, false_and, false_iff]
    omega

theorem body_step (hard : HardState) (x : Rust.M (Entry V)) (st : State V S CAP)
    (r0 : Option (Rust.Result (State V S CAP) Error)) (step) (word : CAP < 2 ^ Rust.usizeBits) (hl : Layout st)
    (h : restoreBody hard x (r0, st) = pure step) :
    ∃ e, x = pure e ∧
      ((LogSuccessor hard (lastId st) e.id ∧ st.len.val < CAP ∧
        ∃ st', State.push st e = pure (.Ok (), st') ∧ step = .yield (none, st')) ∨
       (∃ err st', step = .done (some (.Err err), st'))) := by
  unfold restoreBody at h
  obtain ⟨e, he, h⟩ := Rust.bind_eq_pure h
  refine ⟨e, he, ?_⟩
  obtain ⟨l, hlast, h⟩ := Rust.bind_eq_pure h
  rw [last_eq st hl.1] at hlast
  cases Rust.pure_inj hlast
  dsimp only at h
  split at h
  · exact Or.inr ⟨_, _, (Rust.pure_inj h).symm⟩
  · rename_i g
    have succ := (entryGuard_false hard (lastId st) e).1 (by simpa using g)
    obtain ⟨x, hx, h⟩ := Rust.bind_eq_pure h
    by_cases space : st.len.val < CAP
    · obtain ⟨st', hp, _⟩ := push_ok st e word hl space
      rw [hp] at hx
      cases Rust.pure_inj hx
      exact Or.inl ⟨succ, space, st', hp, (Rust.pure_inj h).symm⟩
    · rw [push_full st e word (by have := hl.1; omega)] at hx
      cases Rust.pure_inj hx
      exact Or.inr ⟨_, _, (Rust.pure_inj h).symm⟩

/-- The invariant of `restore`'s loop. -/
def LoopInv (hard : HardState) (st : State V S CAP) : Prop :=
  Layout st ∧ Ordered hard st.base (ret st) (lastId st)

theorem loop_sound (hard : HardState) (word : CAP < 2 ^ Rust.usizeBits) :
    ∀ (es : List (Rust.M (Entry V))) (st : State V S CAP) p, LoopInv hard st →
      forIn es (none, st) (restoreBody hard) = pure p →
      (∃ err, p.1 = some (.Err err)) ∨
      (p.1 = none ∧ ∃ vs, es = vs.map pure ∧ LoopInv hard p.2 ∧ ret p.2 = ret st ++ vs ∧
        p.2.hard = st.hard ∧ p.2.snapshot = st.snapshot)
  | [], st, p, inv, h => by
    simp only [List.forIn_nil] at h
    cases Rust.pure_inj h
    exact Or.inr ⟨rfl, [], rfl, inv, by simp, rfl, rfl⟩
  | x :: xs, st, p, inv, h => by
    rw [List.forIn_cons] at h
    obtain ⟨step, hs, h⟩ := Rust.bind_eq_pure h
    obtain ⟨e, he, cases⟩ := body_step hard x st none step word inv.1 hs
    rcases cases with ⟨succ, space, st', hp, rfl⟩ | ⟨err, st', rfl⟩
    · obtain ⟨st'', hp', hh, hsn, hr', _, hl''⟩ := push_ok st e word inv.1 space
      rw [hp] at hp'
      cases (Prod.mk.inj (Rust.pure_inj hp')).2
      have hb : st'.base = st.base := by simp [State.base, hsn]
      have chain : Ordered hard st'.base (ret st') (lastId st') := by
        rw [hb, hr']
        have lid : lastId st' = e.id := by simp [lastId, hr']
        rw [lid]
        exact Ordered.snoc e inv.2 succ.1 succ.2.1 succ.2.2.1 succ.2.2.2
      rcases loop_sound hard word xs st' p ⟨hl'', chain⟩ h with done | ⟨hn, vs, hes, inv', hrr, hhh, hss⟩
      · exact Or.inl done
      · refine Or.inr ⟨hn, e :: vs, by rw [he, hes]; rfl, inv', ?_, by rw [hhh, hh], by rw [hss, hsn]⟩
        rw [hrr, hr']; simp
    · cases Rust.pure_inj h
      exact Or.inl ⟨err, rfl⟩

theorem initial_inv (hard : HardState) (snap : Option (Snapshot S)) :
    LoopInv hard (initial hard snap : State V S CAP) ∧ (initial hard snap : State V S CAP).base = boundaryOf snap ∧
      ret (initial hard snap : State V S CAP) = [] := by
  have fresh := (fresh_representation (V := V) (S := S) (CAP := CAP))
  have hl : Layout (initial hard snap : State V S CAP) :=
    (layout_of (initial hard snap : State V S CAP) [] fresh.2.2.1 (Nat.zero_le _)
      (by simpa [initial] using fresh.2.2.2.1)).1
  have hr : ret (initial hard snap : State V S CAP) = [] :=
    ret_of_slots _ [] fresh.2.2.1 (by simpa [initial] using fresh.2.2.2.1)
  refine ⟨⟨hl, ?_⟩, rfl, hr⟩
  rw [hr]
  simp only [lastId, hr, List.getLast?_nil, Option.map_none, Option.getD_none]
  exact Ordered.empty

/-- Everything a successful `restore` establishes. -/
theorem restore_sound (hard : HardState) (snap : Option (Snapshot S)) (es : List (Rust.M (Entry V)))
    (out : State V S CAP) (word : CAP < 2 ^ Rust.usizeBits)
    (execution : State.restore hard snap es = pure (.Ok out)) :
    initialGuard hard snap = false ∧ ∃ vs, es = vs.map pure ∧ Layout out ∧ ret out = vs ∧
      out.hard = hard ∧ out.snapshot = snap ∧ Ordered hard (boundaryOf snap) vs (lastId out) ∧
      State.last out = pure (lastId out) ∧
      (boundaryOf snap).index.val ≤ hard.commit.val ∧ hard.commit.val ≤ (lastId out).index.val := by
  rw [restore_eq] at execution
  split at execution
  · have := Rust.pure_inj execution; simp at this
  · rename_i g
    obtain ⟨p, hp, hf⟩ := Rust.bind_eq_pure execution
    obtain ⟨inv0, hb0, hr0⟩ := initial_inv (V := V) (CAP := CAP) hard snap
    rcases loop_sound hard word es _ p inv0 hp with ⟨err, he⟩ | ⟨hn, vs, hes, inv, hr, hh, hs⟩
    · unfold restoreFinish at hf
      rw [he] at hf
      have := Rust.pure_inj hf; simp at this
    · unfold restoreFinish at hf
      rw [hn] at hf
      dsimp only at hf
      split at hf
      · rename_i c
        rw [last_eq p.2 inv.1.1] at hf
        simp only [pure_bind] at hf
        split at hf
        · have := Rust.pure_inj hf; simp at this
        · rename_i c2
          have := Rust.pure_inj hf
          simp only [Rust.Result.Ok.injEq] at this
          subst this
          have hb : p.2.base = boundaryOf snap := by
            rw [← hb0]; simp [State.base, hs]
          simp only [Bool.not_eq_eq_eq_not, Bool.not_true, decide_eq_false_iff_not, Fin.lt_def] at c
          simp only [decide_eq_true_eq, Fin.lt_def] at c2
          refine ⟨by simpa using g, vs, hes, inv.1, by rw [hr, hr0]; rfl, by rw [hh]; rfl,
            by rw [hs]; rfl, ?_, last_eq _ inv.1.1, by omega, by omega⟩
          have := inv.2
          rw [hb, hr, hr0] at this
          simpa using this
      · have := Rust.pure_inj hf; simp at this

theorem ordered_head {hard : HardState} {m last : LogId} {e : Entry V} {rest : List (Entry V)}
    (chain : Ordered hard m (e :: rest) last) :
    LogSuccessor hard m e.id ∧ Ordered hard e.id rest last := by
  obtain ⟨middle, first, remaining⟩ := ordered_split chain 1 (by simp)
  simp only [List.take_succ_cons, List.take_zero, List.drop_succ_cons, List.drop_zero] at first remaining
  generalize single : [e] = l at first
  cases first with
  | empty => simp at single
  | @snoc entries previous final inner succ pos mono up =>
    have nil : entries = [] := by
      have size := congrArg List.length single
      simp only [List.length_append, List.length_cons, List.length_nil] at size
      exact List.eq_nil_of_length_eq_zero (by omega)
    subst nil
    have same : e = final := by simpa using single
    subst same
    have := ordered_nil inner
    subst this
    exact ⟨⟨succ, pos, mono, up⟩, remaining⟩

theorem body_yield (hard : HardState) (e : Entry V) (st : State V S CAP)
    (r0 : Option (Rust.Result (State V S CAP) Error)) (word : CAP < 2 ^ Rust.usizeBits) (hl : Layout st)
    (succ : LogSuccessor hard (lastId st) e.id) (space : st.len.val < CAP) :
    ∃ st', restoreBody hard (pure e) (r0, st) = pure (.yield (none, st')) ∧
      Layout st' ∧ ret st' = ret st ++ [e] ∧ st'.hard = st.hard ∧ st'.snapshot = st.snapshot := by
  obtain ⟨st', hp, hh, hs, hr, _, hl'⟩ := push_ok st e word hl space
  refine ⟨st', ?_, hl', hr, hh, hs⟩
  have g : entryGuard hard (lastId st) e = false := (entryGuard_false hard (lastId st) e).2 succ
  unfold restoreBody
  simp [last_eq st hl.1, g, hp]

theorem loop_complete (hard : HardState) (word : CAP < 2 ^ Rust.usizeBits) :
    ∀ (rest : List (Entry V)) (st : State V S CAP) (final : LogId), Layout st →
      Ordered hard (lastId st) rest final → (ret st).length + rest.length ≤ CAP →
      ∃ st', forIn (rest.map pure) (none, st) (restoreBody hard) = pure (none, st') ∧
        Layout st' ∧ ret st' = ret st ++ rest ∧ st'.hard = st.hard ∧ st'.snapshot = st.snapshot ∧
        lastId st' = final
  | [], st, final, hl, chain, _ => by
    refine ⟨st, rfl, hl, by simp, rfl, rfl, (ordered_nil chain).symm⟩
  | e :: rest, st, final, hl, chain, room => by
    obtain ⟨succ, remaining⟩ := ordered_head chain
    have space : st.len.val < CAP := by rw [len_eq st hl]; simp at room; omega
    obtain ⟨st1, hb, hl1, hr1, hh1, hs1⟩ := body_yield hard e st none word hl succ space
    have lid : lastId st1 = e.id := by simp [lastId, hr1]
    obtain ⟨st', h, hl', hr', hh', hs', hlast⟩ :=
      loop_complete hard word rest st1 final hl1 (lid ▸ remaining) (by rw [hr1]; simp at room ⊢; omega)
    refine ⟨st', ?_, hl', by rw [hr', hr1]; simp, by rw [hh', hh1], by rw [hs', hs1], hlast⟩
    rw [List.map_cons, List.forIn_cons, hb, pure_bind]
    exact h

/-- Every checkpoint meeting `restore`'s validity conditions is accepted, with exactly
its entries. -/
theorem restore_complete (hard : HardState) (snap : Option (Snapshot S)) (vs : List (Entry V))
    (last : LogId) (word : CAP < 2 ^ Rust.usizeBits)
    (snapshotNonzero : ∀ sn, snap = some sn → sn.last.index.val ≠ 0 ∧ sn.last.term.val ≠ 0)
    (termBound : (boundaryOf snap).term.val ≤ hard.term.val)
    (noVote : hard.term.val = 0 → hard.voted_for = none)
    (chain : Ordered hard (boundaryOf snap) vs last) (room : vs.length ≤ CAP)
    (lower : (boundaryOf snap).index.val ≤ hard.commit.val)
    (upper : hard.commit.val ≤ (boundaryOf snap).index.val + vs.length) :
    ∃ out, (State.restore hard snap (vs.map pure) : Rust.M (Rust.Result (State V S CAP) Error)) =
        pure (.Ok out) ∧ out.hard = hard ∧ out.snapshot = snap ∧ out.len.val = vs.length ∧
      out.entries.toList = vs.map some ++ List.replicate (CAP - vs.length) none := by
  obtain ⟨inv0, hb0, hr0⟩ := initial_inv (V := V) (CAP := CAP) hard snap
  have g : initialGuard hard snap = false := by
    unfold initialGuard
    cases snap with
    | none =>
      have hz : (boundaryOf (none : Option (Snapshot S))).term.val = 0 := rfl
      simp only [Option.isSome_none, Bool.false_and, Bool.false_or, Bool.or_eq_false_iff,
        decide_eq_false_iff_not, Fin.lt_def, Bool.and_eq_false_imp, beq_iff_eq]
      refine ⟨by omega, fun h0 => ?_⟩
      have : hard.voted_for = none := noVote (by rw [Fin.ext_iff] at h0; exact h0)
      simp [this]
    | some sn =>
      obtain ⟨n1, n2⟩ := snapshotNonzero sn rfl
      have hb : boundaryOf (some sn) = sn.last := rfl
      rw [hb] at termBound ⊢
      simp only [Option.isSome_some, Bool.true_and, Bool.or_eq_false_iff, beq_eq_false_iff_ne,
        ne_eq, Fin.ext_iff, decide_eq_false_iff_not, Fin.lt_def, Bool.and_eq_false_imp, beq_iff_eq]
      refine ⟨⟨⟨n1, n2⟩, by omega⟩, fun h0 => ?_⟩
      have : hard.voted_for = none := noVote (by simpa using h0)
      simp [this]
  obtain ⟨st', h, hl', hr', hh', hs', hlast⟩ := loop_complete hard word vs (initial hard snap) last inv0.1
    (by rw [show lastId (initial hard snap : State V S CAP) = boundaryOf snap by
          simp [lastId, hr0, hb0]]; exact chain)
    (by rw [hr0]; simpa using room)
  rw [hr0] at hr'
  simp only [List.nil_append] at hr'
  have li := ordered_last_index chain
  refine ⟨st', ?_, by rw [hh']; rfl, by rw [hs']; rfl, by rw [len_eq st' hl', hr'], ?_⟩
  · rw [restore_eq, if_neg (by simp [g]), h, pure_bind]
    unfold restoreFinish
    simp only [last_eq st' hl'.1, hlast, pure_bind]
    have c1 : ¬ hard.commit < (boundaryOf snap).index := by rw [Fin.lt_def]; omega
    have c2 : ¬ hard.commit > last.index := by rw [gt_iff_lt, Fin.lt_def]; omega
    simp [c1, c2]
  · rw [hl'.2, hr', len_eq st' hl', hr']

theorem term_push (s : State V S CAP) (e : Entry V) : Term (State.push s e) := by
  unfold State.push
  dsimp only
  split
  · exact term_pure _
  · apply term_bind (term_set _ _ _); intro _ _
    apply term_bind (term_add _ _); intro _ _
    exact term_pure _

theorem term_forIn {α β : Type} (f : α → β → Rust.M (ForInStep β)) :
    ∀ (l : List α), (∀ x ∈ l, ∀ b, Term (f x b)) → ∀ init, Term (forIn l init f)
  | [], _, init => by simp only [List.forIn_nil]; exact term_pure _
  | a :: l, h, init => by
    rw [List.forIn_cons]
    apply term_bind (h a (by simp) init)
    intro step _
    cases step with
    | done b => exact term_pure _
    | yield b => exact term_forIn f l (fun x hx => h x (by simp [hx])) b

/-- `restore` never diverges unless consuming one of its input items diverges. -/
theorem restore_term (hard : HardState) (snap : Option (Snapshot S)) (es : List (Rust.M (Entry V)))
    (items : ∀ x ∈ es, Term x) :
    Term (State.restore hard snap es : Rust.M (Rust.Result (State V S CAP) Error)) := by
  rw [restore_eq]
  apply term_ite (term_pure _)
  apply term_bind
  · apply term_forIn _ es _ _
    intro x hx acc
    unfold restoreBody
    apply term_bind (items x hx); intro e _
    apply term_bind (term_last _); intro l _
    apply term_ite (term_pure _)
    apply term_bind (term_push _ _); intro r _
    split <;> exact term_pure _
  · intro p _
    unfold restoreFinish
    split
    · exact term_pure _
    · apply term_ite _ (term_pure _)
      apply term_bind (term_last _); intro l _
      exact term_ite (term_pure _) (term_pure _)

theorem initialGuard_false (hard : HardState) (snap : Option (Snapshot S)) :
    initialGuard hard snap = false ↔
      (∀ sn, snap = some sn → sn.last.index.val ≠ 0 ∧ sn.last.term.val ≠ 0) ∧
      (boundaryOf snap).term.val ≤ hard.term.val ∧ (hard.term.val = 0 → hard.voted_for = none) := by
  unfold initialGuard
  have vz : ∀ (o : Option Id), o.isSome = false ↔ o = none := by intro o; cases o <;> simp
  cases snap with
  | none =>
    have hz : (boundaryOf (none : Option (Snapshot S))).term.val = 0 := rfl
    simp only [Option.isSome_none, Bool.false_and, Bool.false_or, Bool.or_eq_false_iff,
      decide_eq_false_iff_not, Fin.lt_def, Bool.and_eq_false_imp, beq_iff_eq, Fin.ext_iff, vz]
    simp only [reduceCtorEq, false_implies, implies_true, true_and]
    constructor
    · rintro ⟨a, b⟩; exact ⟨by omega, b⟩
    · rintro ⟨a, b⟩; exact ⟨by omega, b⟩
  | some sn =>
    have hb : boundaryOf (some sn) = sn.last := rfl
    rw [hb]
    simp only [Option.isSome_some, Bool.true_and, Bool.or_eq_false_iff, beq_eq_false_iff_ne,
      ne_eq, Fin.ext_iff, decide_eq_false_iff_not, Fin.lt_def, Bool.and_eq_false_imp, beq_iff_eq, vz,
      Option.some.injEq, forall_eq']
    constructor
    · rintro ⟨⟨a, b⟩, c⟩; exact ⟨a, by omega, c⟩
    · rintro ⟨a, b, c⟩; exact ⟨⟨a, by omega⟩, c⟩

/-! ### Restore obligations -/

theorem restoration_preserves_shape (hard : HardState) (snap : Option (Snapshot S))
    (es : List (Rust.M (Entry V))) (out : State V S CAP) (word : CAP < 2 ^ Rust.usizeBits)
    (execution : State.restore hard snap es = pure (.Ok out)) :
    Shape out ∧ out.hard = hard ∧ out.snapshot = snap := by
  obtain ⟨_, _, _, hl, _, hh, hs, _⟩ := restore_sound hard snap es out word execution
  exact ⟨(shape_iff_layout out).2 hl, hh, hs⟩

/-- `restore` cannot diverge unless consuming an input item diverges (the typed
counterpart of the old interpreter bound being sufficient for every response
sequence). -/
theorem restoration_fuel_sufficient (hard : HardState) (snap : Option (Snapshot S))
    (es : List (Rust.M (Entry V))) (items : ∀ x ∈ es, Term x) :
    Term (State.restore hard snap es : Rust.M (Rust.Result (State V S CAP) Error)) :=
  restore_term hard snap es items

/-- A successful `restore` passed its final guard: neither comparison rejected. -/
theorem restoration_final_guard (hard : HardState) (snap : Option (Snapshot S))
    (es : List (Rust.M (Entry V))) (out : State V S CAP) (word : CAP < 2 ^ Rust.usizeBits)
    (execution : State.restore hard snap es = pure (.Ok out)) :
    ¬ (hard.commit < (boundaryOf snap).index) ∧
      ∃ last, State.last out = pure last ∧ ¬ (hard.commit > last.index) := by
  obtain ⟨_, _, _, _, _, _, _, _, hlast, lo, hi⟩ := restore_sound hard snap es out word execution
  exact ⟨by rw [Fin.lt_def]; omega, _, hlast, by rw [gt_iff_lt, Fin.lt_def]; omega⟩

/-- `restore` installs the supplied `hard` and `snapshot` and a shape-valid buffer;
its boundary is the supplied snapshot's. -/
theorem restoration_places (hard : HardState) (snap : Option (Snapshot S))
    (es : List (Rust.M (Entry V))) (out : State V S CAP) (word : CAP < 2 ^ Rust.usizeBits)
    (execution : State.restore hard snap es = pure (.Ok out)) :
    out.hard = hard ∧ out.snapshot = snap ∧ State.base out = boundaryOf snap ∧ Shape out := by
  obtain ⟨shape, hh, hs⟩ := restoration_preserves_shape hard snap es out word execution
  exact ⟨hh, hs, by simp [State.base, boundaryOf, hs], shape⟩

theorem restoration_commit_bounds (hard : HardState) (snap : Option (Snapshot S))
    (es : List (Rust.M (Entry V))) (out : State V S CAP) (word : CAP < 2 ^ Rust.usizeBits)
    (execution : State.restore hard snap es = pure (.Ok out)) :
    ∃ last, State.last out = pure last ∧
      (boundaryOf snap).index.val ≤ out.hard.commit.val ∧ out.hard.commit.val ≤ last.index.val := by
  obtain ⟨_, _, _, _, _, hh, _, _, hlast, lo, hi⟩ := restore_sound hard snap es out word execution
  exact ⟨_, hlast, by rw [hh]; exact lo, by rw [hh]; exact hi⟩

/-- A successful `restore` passed its initial guard. -/
theorem restoration_initial_guard (hard : HardState) (snap : Option (Snapshot S))
    (es : List (Rust.M (Entry V))) (out : State V S CAP) (word : CAP < 2 ^ Rust.usizeBits)
    (execution : State.restore hard snap es = pure (.Ok out)) :
    initialGuard hard snap = false :=
  (restore_sound hard snap es out word execution).1

theorem restoration_base_term_bound (hard : HardState) (snap : Option (Snapshot S))
    (es : List (Rust.M (Entry V))) (out : State V S CAP) (word : CAP < 2 ^ Rust.usizeBits)
    (execution : State.restore hard snap es = pure (.Ok out)) :
    (boundaryOf snap).term.val ≤ hard.term.val :=
  ((initialGuard_false hard snap).1 (restoration_initial_guard hard snap es out word execution)).2.1

theorem restoration_zero_term_has_no_vote (hard : HardState) (snap : Option (Snapshot S))
    (es : List (Rust.M (Entry V))) (out : State V S CAP) (word : CAP < 2 ^ Rust.usizeBits)
    (zero : hard.term.val = 0)
    (execution : State.restore hard snap es = pure (.Ok out)) :
    hard.voted_for = none :=
  ((initialGuard_false hard snap).1 (restoration_initial_guard hard snap es out word execution)).2.2 zero

theorem restoration_snapshot_nonzero (hard : HardState) (snap : Snapshot S)
    (es : List (Rust.M (Entry V))) (out : State V S CAP) (word : CAP < 2 ^ Rust.usizeBits)
    (execution : State.restore hard (some snap) es = pure (.Ok out)) :
    0 < snap.last.index.val ∧ 0 < snap.last.term.val := by
  have := ((initialGuard_false hard (some snap)).1
    (restoration_initial_guard hard (some snap) es out word execution)).1 snap rfl
  omega

/-- A successful `restore` consumed every input item, and the result holds exactly
those entries as an ordered chain from the snapshot boundary. -/
theorem restoration_orders_log (hard : HardState) (snap : Option (Snapshot S))
    (es : List (Rust.M (Entry V))) (out : State V S CAP) (word : CAP < 2 ^ Rust.usizeBits)
    (execution : State.restore hard snap es = pure (.Ok out)) :
    ∃ vs last, es = vs.map pure ∧
      out.entries.toList = vs.map some ++ List.replicate (CAP - vs.length) none ∧
      out.len.val = vs.length ∧ Ordered hard (boundaryOf snap) vs last ∧
      State.last out = pure last := by
  obtain ⟨_, vs, hes, hl, hr, _, _, chain, hlast, _, _⟩ := restore_sound hard snap es out word execution
  refine ⟨vs, _, hes, ?_, by rw [len_eq out hl, hr], chain, hlast⟩
  rw [hl.2, hr, len_eq out hl, hr]

theorem restoration_exact_indices (hard : HardState) (snap : Option (Snapshot S))
    (es : List (Rust.M (Entry V))) (out : State V S CAP) (word : CAP < 2 ^ Rust.usizeBits)
    (execution : State.restore hard snap es = pure (.Ok out)) :
    ∃ last, State.last out = pure last ∧
      last.index.val = (boundaryOf snap).index.val + out.len.val ∧
      ∀ position entry, position < out.len.val →
        out.entries.toList[position]? = some (some entry) →
        entry.id.index.val = (boundaryOf snap).index.val + position + 1 := by
  obtain ⟨vs, last, _, slots, length, chain, hlast⟩ := restoration_orders_log hard snap es out word execution
  refine ⟨last, hlast, by rw [length]; exact ordered_last_index chain, ?_⟩
  intro position entry inside present
  rw [slots, List.getElem?_append_left (by simp; omega)] at present
  simp only [List.getElem?_map, Option.map_eq_some_iff, Option.some.injEq] at present
  obtain ⟨e, he, rfl⟩ := present
  exact ordered_entry_index chain position e he

theorem restoration_log_representation (hard : HardState) (snap : Option (Snapshot S))
    (es : List (Rust.M (Entry V))) (out : State V S CAP) (word : CAP < 2 ^ Rust.usizeBits)
    (execution : State.restore hard snap es = pure (.Ok out)) :
    LogRep hard (boundaryOf snap) out := by
  obtain ⟨vs, last, _, slots, length, chain, _⟩ := restoration_orders_log hard snap es out word execution
  exact ⟨(restoration_preserves_shape hard snap es out word execution).1, vs, last,
    by rw [slots, length], length, chain⟩

/-- Completeness: every checkpoint meeting the source's validity conditions
(nonzero snapshot id, snapshot term at most the hard term, no vote at term zero, an
ordered chain from the snapshot that fits, and commit between the boundary and the
last index) is accepted, yielding exactly those entries. -/
theorem restoration_accepts (hard : HardState) (snap : Option (Snapshot S)) (vs : List (Entry V))
    (last : LogId) (word : CAP < 2 ^ Rust.usizeBits)
    (snapshotNonzero : ∀ sn, snap = some sn → sn.last.index.val ≠ 0 ∧ sn.last.term.val ≠ 0)
    (termBound : (boundaryOf snap).term.val ≤ hard.term.val)
    (noVote : hard.term.val = 0 → hard.voted_for = none)
    (chain : Ordered hard (boundaryOf snap) vs last) (room : vs.length ≤ CAP)
    (lower : (boundaryOf snap).index.val ≤ hard.commit.val)
    (upper : hard.commit.val ≤ (boundaryOf snap).index.val + vs.length) :
    ∃ out, (State.restore hard snap (vs.map pure) : Rust.M (Rust.Result (State V S CAP) Error)) =
        pure (.Ok out) ∧ out.hard = hard ∧ out.snapshot = snap ∧ out.len.val = vs.length ∧
      out.entries.toList = vs.map some ++ List.replicate (CAP - vs.length) none :=
  restore_complete hard snap vs last word snapshotNonzero termBound noVote chain room lower upper

/-! ## Storage histories -/

/-- Buffer histories across capacities. Growth is a parameter `grow` (a relation
from a state of one capacity to a state of a larger one) until `State::grow` is
translated; instantiate it with the translated function. These are buffer
histories; they do not encode protocol or durable-history reachability. -/
inductive StorageHistory (grow : ∀ {c d : Nat}, State V S c → State V S d → Prop) :
    (CAP : Nat) → State V S CAP → Prop where
  | fresh (CAP : Nat) (word : CAP < 2 ^ Rust.usizeBits) : StorageHistory grow CAP State.new
  | append {CAP : Nat} {s next : State V S CAP} (input : Entry V) :
      StorageHistory grow CAP s → State.push s input = pure (.Ok (), next) → StorageHistory grow CAP next
  | grow {c d : Nat} {s : State V S c} {next : State V S d} :
      StorageHistory grow c s → c ≤ d → d < 2 ^ Rust.usizeBits → grow s next → StorageHistory grow d next
  | truncate {CAP : Nat} {s next : State V S CAP} (f : Rust.u64) :
      StorageHistory grow CAP s → State.truncate s f = pure next → StorageHistory grow CAP next
  | install {CAP : Nat} {s next : State V S CAP} (snap : Snapshot S) :
      StorageHistory grow CAP s → State.install s snap = pure next → StorageHistory grow CAP next
  | restore (CAP : Nat) (hard : HardState) (snap : Option (Snapshot S)) (es : List (Rust.M (Entry V)))
      (out : State V S CAP) :
      CAP < 2 ^ Rust.usizeBits → State.restore hard snap es = pure (.Ok out) → StorageHistory grow CAP out

/-- Every history state is shape-valid with a word-sized capacity, given that the
growth step preserves shape. -/
theorem storage_history_valid (grow : ∀ {c d : Nat}, State V S c → State V S d → Prop)
    (growShape : ∀ {c d : Nat} (s : State V S c) (next : State V S d), Shape s → c ≤ d → d < 2 ^ Rust.usizeBits →
      grow s next → Shape next)
    (CAP : Nat) (s : State V S CAP) (history : StorageHistory grow CAP s) :
    Shape s ∧ CAP < 2 ^ Rust.usizeBits := by
  induction history with
  | fresh CAP word => exact ⟨fresh_representation.2.2.2.2, word⟩
  | append input _ execution ih => exact ⟨(push_shape _ input _ ih.1 ih.2 execution).1, ih.2⟩
  | grow _ le word step ih => exact ⟨growShape _ _ ih.1 le word step, word⟩
  | truncate f _ execution ih => exact ⟨(truncation_preserves_shape _ _ f ih.1 execution).1, ih.2⟩
  | install snap _ execution ih => exact ⟨installation_preserves_shape _ _ snap ih.1 ih.2 execution, ih.2⟩
  | restore CAP hard snap es out word execution =>
    exact ⟨(restoration_preserves_shape hard snap es out word execution).1, word⟩

theorem history_supports_installation (grow : ∀ {c d : Nat}, State V S c → State V S d → Prop)
    (growShape : ∀ {c d : Nat} (s : State V S c) (next : State V S d), Shape s → c ≤ d → d < 2 ^ Rust.usizeBits →
      grow s next → Shape next)
    (s next : State V S CAP) (snap : Snapshot S)
    (history : StorageHistory grow CAP s)
    (execution : State.install s snap = pure next) :
    Shape s ∧ Shape next ∧ s.hard.commit.val ≤ next.hard.commit.val ∧ next.snapshot = some snap := by
  have valid := storage_history_valid grow growShape CAP s history
  have effects := installation_preserves_capacity_and_commit s next snap execution
  exact ⟨valid.1, installation_preserves_shape s next snap valid.1 valid.2 execution, effects.2⟩

/-! ## `State::grow`

The translation's const assertion `NEW >= CAP` panics when false
(`grow_assertion_fails`); otherwise an index loop takes each live slot out of the
old array (leaving `None`) and pushes it onto the new one. -/

/-- The body of `grow`'s slot loop: slot `i` below `len` is taken (moved out,
leaving `None` behind) and pushed onto the new array; other slots push `None`. -/
def growBody (i : Nat) (acc : State V S CAP × Array (Option (Entry V))) :
    Rust.M (ForInStep (State V S CAP × Array (Option (Entry V)))) :=
  if decide (Rust.usizeOf i < acc.1.len) then do
    let t1 ← Rust.Slice.index acc.1.entries (Rust.usizeOf i)
    let t2 ← Rust.Slice.set acc.1.entries (Rust.usizeOf i) none
    pure (.yield ({ acc.1 with entries := t2 }, acc.2.push t1))
  else pure (.yield (acc.1, acc.2.push none))

/-- What `grow` does after its loop. -/
def growFinish {NEW : Nat} (taken : Option (Snapshot S)) (p : State V S CAP × Array (Option (Entry V))) :
    Rust.M (State V S NEW) := do
  let t4 ← Rust.Slice.ofArray NEW p.2
  pure { hard := p.1.hard, snapshot := taken, entries := t4, len := p.1.len }

theorem grow_eq {NEW : Nat} (s : State V S CAP) :
    (State.grow s : Rust.M (State V S NEW)) =
      (if (!decide (Rust.usizeOf NEW ≥ Rust.usizeOf CAP)) = true then (Rust.fail "assertion failed" : Rust.M Unit)
        else pure ()) >>= fun _ =>
      forIn (List.range NEW) ({ s with snapshot := none }, #[]) growBody >>= growFinish s.snapshot := by
  unfold State.grow
  dsimp only
  split
  · rfl
  · simp only [pure_bind]
    rfl

/-- The value pushed for slot `i`: the live payload below `len`, otherwise `None`. -/
def movedSlot (s : State V S CAP) (i : Nat) : Option (Entry V) :=
  if i < s.len.val then (s.entries.toList[i]?).getD none else none

theorem grow_loop {NEW : Nat} (s : State V S CAP) (hlen : s.len.val ≤ CAP) (grows : CAP ≤ NEW)
    (word : NEW < 2 ^ Rust.usizeBits) :
    ∃ p : State V S CAP × Array (Option (Entry V)),
      forIn (List.range NEW) (({ s with snapshot := none } : State V S CAP), (#[] : Array (Option (Entry V)))) growBody = pure p ∧
      p.1.hard = s.hard ∧ p.1.len = s.len ∧ p.1.snapshot = none ∧
      p.2.toList = (List.range NEW).map (movedSlot s) ∧
      ∀ j, p.1.entries.toList[j]? = if j < s.len.val then some none else s.entries.toList[j]? := by
  let I : Nat → State V S CAP × Array (Option (Entry V)) → Prop := fun k b =>
    b.1.hard = s.hard ∧ b.1.len = s.len ∧ b.1.snapshot = none ∧
      b.2.toList = (List.range k).map (movedSlot s) ∧
      ∀ j, b.1.entries.toList[j]? = if j < min k s.len.val then some none else s.entries.toList[j]?
  obtain ⟨p, hp, h1, h2, h3, h4, h5⟩ := Rust.forIn_inv (List.range NEW) (({ s with snapshot := none } : State V S CAP), (#[] : Array (Option (Entry V)))) growBody I
    ⟨rfl, rfl, rfl, by simp, fun j => by simp⟩ (by
      intro k hk b ⟨b1, b2, b3, b4, b5⟩
      simp only [List.length_range] at hk
      simp only [List.getElem_range]
      have uk : (Rust.usizeOf k).val = k := Rust.val_usizeOf k (by uomega)
      unfold growBody
      by_cases live : k < s.len.val
      · have c : Rust.usizeOf k < b.1.len := by rw [Fin.lt_def, uk, b2]; exact live
        have kc : k < CAP := by omega
        rw [if_pos (by simpa using c), Rust.Slice.index_ok _ _ (by rw [uk]; exact kc), pure_bind,
          Rust.Slice.set_ok _ _ _ (by rw [uk]; exact kc), pure_bind]
        refine ⟨_, rfl, b1, b2, b3, ?_, ?_⟩
        · have e : b.1.entries[(Rust.usizeOf k).val] = movedSlot s k := by
            have := b5 k
            rw [if_neg (by omega), List.getElem?_eq_getElem (by simp; omega),
              List.getElem?_eq_getElem (by simp; omega)] at this
            simp only [Option.some.injEq, Vector.getElem_toList] at this
            simp only [uk, this, movedSlot, if_pos live, List.getElem?_eq_getElem (by simp; omega : k < s.entries.toList.length), Option.getD_some, Vector.getElem_toList]
          simp only [Array.toList_push, b4, List.range_succ, List.map_append, List.map_cons, List.map_nil, e]
        · intro j
          simp only [Vector.toList_set, uk]
          by_cases e : j = k
          · subst e; rw [List.getElem?_set_self (by simp; omega), if_pos (by omega)]
          · rw [List.getElem?_set_ne (Ne.symm e), b5 j]
            congr 1; apply propext; omega
      · have c : ¬ Rust.usizeOf k < b.1.len := by rw [Fin.lt_def, uk, b2]; exact live
        rw [if_neg (by simpa using c)]
        refine ⟨_, rfl, b1, b2, b3, ?_, ?_⟩
        · simp only [Array.toList_push, b4, List.range_succ, List.map_append, List.map_cons, List.map_nil,
            movedSlot, if_neg live]
        · intro j; rw [b5 j]; congr 1; apply propext; omega)
  refine ⟨p, hp, h1, h2, h3, by simpa using h4, fun j => ?_⟩
  rw [h5 j]; simp only [List.length_range]; congr 1; apply propext; omega

private theorem moved_list (s : State V S CAP) (NEW : Nat) (hlen : s.len.val ≤ CAP) (grows : CAP ≤ NEW) :
    (List.range NEW).map (movedSlot s) =
      s.entries.toList.take s.len.val ++ List.replicate (NEW - s.len.val) none := by
  apply List.ext_getElem
  · simp; omega
  · intro i h1 h2
    simp only [List.getElem_map, List.getElem_range, movedSlot]
    by_cases live : i < s.len.val
    · rw [if_pos live, List.getElem_append_left (by simp; omega)]
      simp [List.getElem?_eq_getElem (show i < s.entries.toList.length by simp; omega)]
    · rw [if_neg live, List.getElem_append_right (by simp; omega)]
      simp

/-- Everything a valid `grow` does: live slots move unchanged into the new array,
the rest of it is empty, and `len`, `hard` and `snapshot` carry over. -/
theorem grow_returns {NEW : Nat} (s : State V S CAP) (hlen : s.len.val ≤ CAP) (grows : CAP ≤ NEW)
    (word : NEW < 2 ^ Rust.usizeBits) :
    ∃ p : State V S CAP × Array (Option (Entry V)),
      forIn (List.range NEW) (({ s with snapshot := none } : State V S CAP), (#[] : Array (Option (Entry V))))
        growBody = pure p ∧
      (∀ j, p.1.entries.toList[j]? = if j < s.len.val then some none else s.entries.toList[j]?) ∧
      ∃ next : State V S NEW, State.grow s = pure next ∧
        next.entries.toList = s.entries.toList.take s.len.val ++ List.replicate (NEW - s.len.val) none ∧
        next.entries.toArray = p.2 ∧
        next.len = s.len ∧ next.hard = s.hard ∧ next.snapshot = s.snapshot := by
  obtain ⟨p, hp, h1, h2, _, h4, h5⟩ := grow_loop (NEW := NEW) s hlen grows word
  have size : p.2.size = NEW := by
    have := congrArg List.length h4; simpa using this
  have c : (!decide (Rust.usizeOf NEW ≥ Rust.usizeOf CAP)) = false := by
    simp only [Bool.not_eq_false', decide_eq_true_eq, ge_iff_le, Fin.le_def]
    rw [Rust.val_usizeOf _ word, Rust.val_usizeOf _ (by uomega)]; exact grows
  refine ⟨p, hp, h5, ⟨p.1.hard, s.snapshot, ⟨p.2, size⟩, p.1.len⟩, ?_, ?_, rfl, h2, h1, rfl⟩
  · rw [grow_eq, c]
    simp only [Bool.false_eq_true, if_false, pure_bind, hp, growFinish, Rust.Slice.ofArray, dif_pos size]
  · show p.2.toList = _
    rw [h4, moved_list s NEW hlen grows]

/-- The const assertion: shrinking panics. -/
theorem grow_assertion_fails {NEW : Nat} (s : State V S CAP) (shrinks : NEW < CAP) (word : CAP < 2 ^ Rust.usizeBits) :
    (State.grow s : Rust.M (State V S NEW)) = Rust.fail "assertion failed" := by
  have c : (!decide (Rust.usizeOf NEW ≥ Rust.usizeOf CAP)) = true := by
    simp only [Bool.not_eq_true', decide_eq_false_iff_not, ge_iff_le, Fin.le_def]
    rw [Rust.val_usizeOf _ word, Rust.val_usizeOf _ (by uomega)]; omega
  rw [grow_eq, c, if_pos rfl]
  rfl

theorem grow_exact {NEW : Nat} (s : State V S CAP) (live : List (Entry V))
    (slots : s.entries.toList = live.map some ++ List.replicate (CAP - live.length) none)
    (length : s.len.val = live.length) (grows : CAP ≤ NEW) (word : NEW < 2 ^ Rust.usizeBits) :
    ∃ next : State V S NEW, State.grow s = pure next ∧
      next.entries.toList = live.map some ++ List.replicate (NEW - live.length) none ∧
      next.len = s.len ∧ next.hard = s.hard ∧ next.snapshot = s.snapshot := by
  have size := congrArg List.length slots
  simp at size
  obtain ⟨_, _, _, next, h, he, _, hl, hh, hs⟩ := grow_returns (NEW := NEW) s (by omega) grows word
  refine ⟨next, h, ?_, hl, hh, hs⟩
  rw [he, slots, length, List.take_left' (by simp)]

/-- `grow` reads and writes only the original fields: `entries` (moved), `len`,
`hard` and `snapshot` (carried), from capacity `CAP` to `NEW`. -/
theorem growth_representation {NEW : Nat} (s : State V S CAP) (live : List (Entry V))
    (slots : s.entries.toList = live.map some ++ List.replicate (CAP - live.length) none)
    (length : s.len.val = live.length) (grows : CAP ≤ NEW) (word : NEW < 2 ^ Rust.usizeBits) :
    ∃ next : State V S NEW, State.grow s = pure next ∧
      next = { hard := s.hard, snapshot := s.snapshot, len := s.len,
               entries := ⟨(live.map some ++ List.replicate (NEW - live.length) none).toArray,
                 by have := congrArg List.length slots; simp at this; simp; omega⟩ } := by
  obtain ⟨next, h, he, hl, hh, hs⟩ := grow_exact (NEW := NEW) s live slots length grows word
  refine ⟨next, h, ?_⟩
  cases next with
  | mk hard snapshot entries len =>
    simp only at he hl hh hs
    subst hl hh hs
    congr
    apply Vector.toList_inj.mp
    rw [he]; simp

theorem grow_preserves_shape {NEW : Nat} (s : State V S CAP) (shape : Shape s) (grows : CAP ≤ NEW)
    (word : NEW < 2 ^ Rust.usizeBits) :
    ∃ next : State V S NEW, State.grow s = pure next ∧ Shape next ∧ next.len = s.len ∧
      (∀ i, i < s.len.val → next.entries.toList[i]? = s.entries.toList[i]?) := by
  have hl := (shape_iff_layout s).1 shape
  have hlr := len_eq s hl
  obtain ⟨_, _, _, next, h, he, _, hlen, _, _⟩ := grow_returns (NEW := NEW) s shape.1 grows word
  have tk : s.entries.toList.take s.len.val = (ret s).map some := by
    rw [hl.2, List.take_append_of_le_length (by simp; omega), hlr, List.take_of_length_le (by simp)]
  refine ⟨next, h, (shape_iff_layout next).2 (layout_of next (ret s) (by rw [hlen]; exact hlr)
    (by have := shape.1; omega) (by rw [he, tk, hlr])).1, hlen, ?_⟩
  intro i hi
  have hi' : i < (s.entries.toList.take s.len.val).length := by
    simp only [List.length_take, Vector.length_toList]; rw [Nat.min_eq_left shape.1]; exact hi
  rw [he, List.getElem?_append_left hi', List.getElem?_take_of_lt hi]

/-- Moving the payloads out of the old array leaves every old slot empty, and the
new array receives exactly the live payloads (the typed form of the old
initialized-moves account). -/
theorem grow_initialized_moves {NEW : Nat} (s : State V S CAP) (live : List (Entry V))
    (slots : s.entries.toList = live.map some ++ List.replicate (CAP - live.length) none)
    (length : s.len.val = live.length) (grows : CAP ≤ NEW) (word : NEW < 2 ^ Rust.usizeBits) :
    ∃ p : State V S CAP × Array (Option (Entry V)),
      forIn (List.range NEW) (({ s with snapshot := none } : State V S CAP), (#[] : Array (Option (Entry V))))
        growBody = pure p ∧
      p.2.toList = live.map some ++ List.replicate (NEW - live.length) none ∧
      p.1.entries.toList = List.replicate CAP none ∧
      ∃ next : State V S NEW, State.grow s = pure next ∧ next.entries.toArray = p.2 ∧
        next.len = s.len ∧ next.hard = s.hard ∧ next.snapshot = s.snapshot := by
  have size := congrArg List.length slots
  simp at size
  obtain ⟨p, hp, h5, next, h, he, ha, hl, hh, hs⟩ := grow_returns (NEW := NEW) s (by omega) grows word
  refine ⟨p, hp, ?_, ?_, next, h, ha, hl, hh, hs⟩
  · rw [← ha, Vector.toList_toArray, he, slots, length, List.take_left' (by simp)]
  · apply List.ext_getElem?
    intro j
    rw [h5 j, List.getElem?_replicate]
    by_cases live' : j < s.len.val
    · rw [if_pos live', if_pos (by omega)]
    · rw [if_neg live', slots, List.getElem?_append_right (by simp; omega), List.getElem?_replicate]
      simp only [List.length_map]
      split <;> split <;> first | rfl | omega

/-- `grow` preserves the logical log representation. -/
theorem growth_preserves_log {NEW : Nat} {hard : HardState} {base : LogId} (s : State V S CAP)
    (valid : LogRep hard base s) (grows : CAP ≤ NEW) (word : NEW < 2 ^ Rust.usizeBits) :
    ∃ next : State V S NEW, State.grow s = pure next ∧ LogRep hard base next ∧ next.len = s.len := by
  obtain ⟨shape, entries, last, slots, length, chain⟩ := valid
  obtain ⟨next, h, he, hl, _, _⟩ := grow_exact (NEW := NEW) s entries (by rw [slots, length]) length grows word
  obtain ⟨next', h', nshape, _, _⟩ := grow_preserves_shape (NEW := NEW) s shape grows word
  rw [h] at h'
  cases Rust.pure_inj h'
  exact ⟨next, h, ⟨nshape, entries, last, by rw [he, hl, length], by rw [hl, length], chain⟩, hl⟩

/-- The translated growth step, for `StorageHistory`. -/
def growStep : ∀ {c d : Nat}, State V S c → State V S d → Prop :=
  fun s next => State.grow s = pure next

theorem growStep_shape {c d : Nat} (s : State V S c) (next : State V S d) (shape : Shape s) (grows : c ≤ d)
    (word : d < 2 ^ Rust.usizeBits) (step : growStep s next) : Shape next := by
  obtain ⟨next', h, nshape, _, _⟩ := grow_preserves_shape (NEW := d) s shape grows word
  unfold growStep at step
  rw [h] at step
  cases Rust.pure_inj step
  exact nshape

/-- Every history built from the translated operations (growth included) is
shape-valid, and growing it to any larger word-sized capacity succeeds, keeping
the live prefix. -/
theorem history_supports_growth {NEW : Nat} (s : State V S CAP)
    (history : StorageHistory growStep CAP s) (grows : CAP ≤ NEW) (word : NEW < 2 ^ Rust.usizeBits) :
    Shape s ∧ CAP < 2 ^ Rust.usizeBits ∧
      ∃ next : State V S NEW, State.grow s = pure next ∧ Shape next ∧ next.len = s.len ∧
        (∀ i, i < s.len.val → next.entries.toList[i]? = s.entries.toList[i]?) := by
  have valid := storage_history_valid growStep growStep_shape CAP s history
  exact ⟨valid.1, valid.2, grow_preserves_shape s valid.1 grows word⟩

end Jarl.Contracts.Storage
