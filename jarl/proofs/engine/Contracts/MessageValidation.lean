import Generated

/-!
Contracts for Rust `node::Node::valid` over Provium's typed translation.

`valid_spec` characterizes the function exactly: on every message it returns
normally (no panic, no divergence) with `decide (Accepts m)`. The remaining
theorems are per-variant corollaries and concrete cases.
-/

namespace Jarl.Contracts.MessageValidation

open Jarl

/-- A log id acceptable in a message of term `term`: the default (empty) id, or a
positive index with a positive term not exceeding `term`. -/
def ValidId (term : Rust.u64) (id : LogId) : Prop :=
  (id.index = 0 ∧ id.term = 0) ∨ (0 < id.index ∧ 0 < id.term ∧ id.term ≤ term)

instance (term : Rust.u64) (id : LogId) : Decidable (ValidId term id) :=
  inferInstanceAs (Decidable (_ ∨ _))

/-- `next` may directly follow `previous` in a message of term `term`: it is a valid
id, its index is exactly the successor (without overflow, since `next.index` is a
`u64`), and its term does not decrease. -/
def Successor (term : Rust.u64) (previous next : LogId) : Prop :=
  ValidId term next ∧ previous.index.val + 1 = next.index.val ∧ previous.term ≤ next.term

instance (term : Rust.u64) (previous next : LogId) : Decidable (Successor term previous next) :=
  inferInstanceAs (Decidable (_ ∧ _ ∧ _))

/-- Every slot is empty. -/
def Vacant {V : Type} (slots : List (Option (Entry V))) : Prop :=
  ∀ slot ∈ slots, slot.isNone = true

instance {V : Type} (slots : List (Option (Entry V))) : Decidable (Vacant slots) :=
  inferInstanceAs (Decidable (∀ slot ∈ slots, _))

/-- Batch slots form an occupied prefix, each entry the `Successor` of the one before
(the first of `previous`), followed only by empty slots. -/
def OrderedSlots {V : Type} (term : Rust.u64) : LogId → List (Option (Entry V)) → Prop
  | _, [] => True
  | _, none :: rest => Vacant rest
  | previous, some entry :: rest => Successor term previous entry.id ∧ OrderedSlots term entry.id rest

instance decOrderedSlots {V : Type} (term : Rust.u64) :
    (previous : LogId) → (slots : List (Option (Entry V))) → Decidable (OrderedSlots term previous slots)
  | _, [] => inferInstanceAs (Decidable True)
  | _, none :: rest => inferInstanceAs (Decidable (Vacant rest))
  | _, some entry :: rest =>
    have := decOrderedSlots term entry.id rest
    inferInstanceAs (Decidable (_ ∧ _))

/-- Number of occupied slots. -/
def occupied {V : Type} (slots : List (Option (Entry V))) : Nat :=
  slots.countP (fun slot => slot.isSome)

/-- Exactly the messages `Node::valid` accepts. -/
def Accepts {V S : Type} : Message V S → Prop
  | .PreVoted _ campaign _ => 0 < campaign
  | .PreVote term last => 0 < term ∧ ValidId term last
  | .Vote term last => 0 < term ∧ ValidId term last
  | .Voted term _ => 0 < term
  | .Append term previous entry _ =>
    0 < term ∧ ValidId term previous ∧
      (match entry with
       | none => True
       | some entry => Successor term previous entry.id)
  | .AppendBatch term previous entries _ =>
    0 < term ∧ ValidId term previous ∧ 0 < occupied entries.toList ∧
      OrderedSlots term previous entries.toList
  | .Install term snapshot => 0 < term ∧ 0 < snapshot.last.index ∧ ValidId term snapshot.last
  | .Replicated term _ (some (.Conflict next)) => 0 < term ∧ 0 < next
  | .Replicated term _ none => 0 < term
  | .Replicated term _ (some .Full) => 0 < term

instance {V S : Type} (m : Message V S) : Decidable (Accepts m) := by
  cases m with
  | Replicated term index rejection =>
    rcases rejection with _ | _ | _ <;> unfold Accepts <;> infer_instance
  | AppendBatch => unfold Accepts; exact inferInstanceAs (Decidable (_ ∧ _ ∧ _ ∧ _))
  | Append _ _ entry _ => rcases entry with _ | _ <;> unfold Accepts <;> infer_instance
  | _ => unfold Accepts; infer_instance

/-! ## Boolean model of the translated closure and batch loop -/

private def validIdB (term : Rust.u64) (id : LogId) : Bool :=
  id == LogId.default || decide (id.index > 0) && decide (id.term > 0) && decide (id.term ≤ term)

private theorem validIdB_iff (term : Rust.u64) (id : LogId) :
    validIdB term id = true ↔ ValidId term id := by
  rcases id with ⟨⟨i, hi⟩, ⟨t, ht⟩⟩
  simp [validIdB, ValidId, LogId.default, Fin.ext_iff, Fin.lt_def, Fin.le_def]
  omega

private def stepRejects (term : Rust.u64) (previous : LogId) (ended : Bool) (id : LogId) : Bool :=
  ended || !validIdB term id || Rust.checked_add previous.index 1 != some id.index ||
    decide (id.term < previous.term)

private theorem stepRejects_false_iff (term : Rust.u64) (previous id : LogId) :
    stepRejects term previous false id = false ↔ Successor term previous id := by
  rcases previous with ⟨⟨pi, hpi⟩, ⟨pt, hpt⟩⟩
  rcases id with ⟨⟨i, hi⟩, ⟨t, ht⟩⟩
  have hv := validIdB_iff term ⟨⟨i, hi⟩, ⟨t, ht⟩⟩
  unfold stepRejects Successor
  by_cases h : pi + 1 < 2 ^ 64
  · simp [h, Fin.ext_iff, Fin.lt_def, Fin.le_def, ← hv, and_assoc]
  · simp [h]
    omega

/-- Result of the batch loop: `none` if it returns `false` early, otherwise the count. -/
private def scan {V : Type} (term : Rust.u64) :
    LogId → Bool → Nat → List (Option (Entry V)) → Option Nat
  | _, _, n, [] => some n
  | previous, _, n, none :: rest => scan term previous true n rest
  | previous, ended, n, some entry :: rest =>
    if stepRejects term previous ended entry.id then none
    else scan term entry.id ended (n + 1) rest

private abbrev LoopState := Option Bool × LogId × Bool × Rust.i32

private theorem i32_one_val : (1 : Rust.i32).val = 1 := by rfl
private theorem i32_zero_val : (0 : Rust.i32).val = 0 := by rfl

private theorem loop_spec {V : Type} (term : Rust.u64)
    (f : Option (Entry V) → LoopState → Rust.M (ForInStep LoopState))
    (hnone : ∀ p e c, f none (none, p, e, c) = pure (.yield (none, p, true, c)))
    (hsome : ∀ x p e c, f (some x) (none, p, e, c) =
      if stepRejects term p e x.id = true then pure (.done (some false, p, e, c))
      else do
        let t ← Rust.iadd c 1
        pure (.yield (none, x.id, e, t))) :
    ∀ (slots : List (Option (Entry V))) (p : LogId) (e : Bool) (c : Rust.i32),
      0 ≤ c.val → c.val + slots.length < 2 ^ 31 →
      ∃ s : LoopState, forIn slots (none, p, e, c) f = pure s ∧
        match scan term p e c.val.toNat slots with
        | none => s.1 = some false
        | some n => s.1 = none ∧ s.2.2.2.val = n := by
  intro slots
  induction slots with
  | nil =>
    intro p e c h0 _
    refine ⟨(none, p, e, c), rfl, ?_⟩
    simp [scan]
    omega
  | cons slot rest ih =>
    intro p e c h0 hlen
    simp only [List.length_cons] at hlen
    cases slot with
    | none =>
      obtain ⟨s, hs, hm⟩ := ih p true c h0 (by omega)
      refine ⟨s, ?_, ?_⟩
      · simp [List.forIn_cons, hnone, hs]
      · simpa [scan] using hm
    | some x =>
      by_cases hr : stepRejects term p e x.id = true
      · refine ⟨(some false, p, e, c), ?_, ?_⟩
        · simp [List.forIn_cons, hsome, hr]
        · simp [scan, hr]
      · have hb : -(2 ^ (32 - 1) : Int) ≤ c.val + (1 : Rust.i32).val ∧
            c.val + (1 : Rust.i32).val < 2 ^ (32 - 1) := by
          rw [i32_one_val]; omega
        let c' : Rust.i32 := ⟨c.val + (1 : Rust.i32).val, hb.1, hb.2⟩
        obtain ⟨s, hs, hm⟩ := ih x.id e c' (by simp [c', i32_one_val]; omega)
          (by simp [c', i32_one_val]; omega)
        refine ⟨s, ?_, ?_⟩
        · rw [List.forIn_cons, hsome, if_neg hr, Rust.iadd, dif_pos hb]
          simpa using hs
        · have hn : (c'.val).toNat = c.val.toNat + 1 := by
            simp [c', i32_one_val]; omega
          simp only [scan, hr, Bool.false_eq_true, if_false]
          rw [← hn]
          exact hm


private def body {V : Type} (term : Rust.u64) (entry_2 : Option (Entry V)) (__s : LoopState) :
    Rust.M (ForInStep LoopState) :=
  match entry_2 with
  | some entry_3 =>
    if stepRejects term __s.snd.fst __s.snd.snd.fst entry_3.id = true then
      pure (ForInStep.done (some false, __s.snd.fst, __s.snd.snd.fst, __s.snd.snd.snd))
    else do
      let t1 ← Rust.iadd __s.snd.snd.snd 1
      pure (ForInStep.yield (none, entry_3.id, __s.snd.snd.fst, t1))
  | _ => pure (ForInStep.yield (none, __s.snd.fst, true, __s.snd.snd.snd))

private theorem occupied_nil {V : Type} : occupied ([] : List (Option (Entry V))) = 0 := rfl
private theorem occupied_none {V : Type} (rest : List (Option (Entry V))) :
    occupied (none :: rest) = occupied rest := by simp [occupied]
private theorem occupied_some {V : Type} (x : Entry V) (rest : List (Option (Entry V))) :
    occupied (some x :: rest) = occupied rest + 1 := by simp [occupied]

private theorem occupied_vacant {V : Type} (l : List (Option (Entry V))) (h : Vacant l) :
    occupied l = 0 := by
  induction l with
  | nil => rfl
  | cons slot rest ih =>
    cases slot with
    | none => rw [occupied_none]; exact ih (fun s hs => h s (List.mem_cons_of_mem _ hs))
    | some x => exact absurd (h (some x) List.mem_cons_self) (by simp)

private theorem scan_ended {V : Type} (term : Rust.u64) (l : List (Option (Entry V))) :
    ∀ (p : LogId) (k n : Nat), scan term p true k l = some n ↔ Vacant l ∧ n = k := by
  induction l with
  | nil => intro p k n; simp only [scan, Option.some.injEq]; simp [Vacant]; exact eq_comm
  | cons slot rest ih =>
    intro p k n
    cases slot with
    | none =>
      rw [scan, ih]
      simp [Vacant]
    | some x =>
      simp [scan, stepRejects, Vacant]

private theorem scan_open {V : Type} (term : Rust.u64) (l : List (Option (Entry V))) :
    ∀ (p : LogId) (k n : Nat),
      scan term p false k l = some n ↔ OrderedSlots term p l ∧ n = k + occupied l := by
  induction l with
  | nil => intro p k n; simp [scan, OrderedSlots, occupied_nil, eq_comm]
  | cons slot rest ih =>
    intro p k n
    cases slot with
    | none =>
      rw [scan, scan_ended, occupied_none, OrderedSlots]
      constructor
      · rintro ⟨hv, rfl⟩; exact ⟨hv, by rw [occupied_vacant rest hv]; rfl⟩
      · rintro ⟨hv, rfl⟩; exact ⟨hv, by rw [occupied_vacant rest hv]; rfl⟩
    | some x =>
      rw [scan, OrderedSlots, occupied_some, ← stepRejects_false_iff]
      cases hr : stepRejects term p false x.id
      · simp only [Bool.false_eq_true, if_false, ih, true_and]
        constructor <;> rintro ⟨h1, h2⟩ <;> exact ⟨h1, by omega⟩
      · simp

private theorem succB_iff (term : Rust.u64) (previous id : LogId) :
    (validIdB term id && Rust.checked_add previous.index 1 == some id.index &&
      decide (id.term ≥ previous.term)) = true ↔ Successor term previous id := by
  rw [← stepRejects_false_iff]
  have hd : decide (id.term ≥ previous.term) = !decide (id.term < previous.term) := by
    by_cases h : id.term < previous.term
    · simp [h, Fin.not_le.mpr h]
    · simp [h, Fin.not_lt.mp h]
  unfold stepRejects
  simp only [bne, hd]
  generalize validIdB term id = a
  generalize (Rust.checked_add previous.index 1 == some id.index) = c
  generalize decide (id.term < previous.term) = d
  cases a <;> cases c <;> cases d <;> decide

private theorem valid_of {V S : Type} {N CAP : Nat} [Rust.Clone V] [Rust.Clone S]
    (m : Message V S) (b : Bool) (h : Node.valid (N := N) (CAP := CAP) m = pure b)
    (hb : b = true ↔ Accepts m) :
    Node.valid (N := N) (CAP := CAP) m = pure (decide (Accepts m)) := by
  rw [h]
  congr 1
  cases b <;> simp_all

/-- **Exact characterization of `node::Node::valid`.** On every message the translated
function returns normally (never panics, never diverges), and the returned Boolean is
exactly `Accepts m`. -/
theorem valid_spec {V S : Type} {N CAP : Nat} [Rust.Clone V] [Rust.Clone S] (m : Message V S) :
    Node.valid (N := N) (CAP := CAP) m = pure (decide (Accepts m)) := by
  cases m with
  | PreVoted term campaign granted =>
    exact valid_of _ (decide (campaign > 0)) rfl (by simp [Accepts])
  | PreVote term last =>
    refine valid_of _ (decide (term > 0) && validIdB term last) ?_ ?_
    · by_cases ht : term > 0 <;> simp [Node.valid, Message.term, ht, validIdB] <;> rfl
    · simp [Accepts, validIdB_iff]
  | Vote term last =>
    refine valid_of _ (decide (term > 0) && validIdB term last) ?_ ?_
    · by_cases ht : term > 0 <;> simp [Node.valid, Message.term, ht, validIdB] <;> rfl
    · simp [Accepts, validIdB_iff]
  | Voted term granted =>
    refine valid_of _ (decide (term > 0)) ?_ ?_
    · by_cases ht : term > 0 <;> simp [Node.valid, Message.term, ht]
    · simp [Accepts]
  | Append term previous entry commit =>
    refine valid_of _ (decide (term > 0) && validIdB term previous &&
      Rust.Option.is_none_or entry (fun e => validIdB term e.id &&
        Rust.checked_add previous.index 1 == some e.id.index && decide (e.id.term ≥ previous.term))) ?_ ?_
    · by_cases ht : term > 0 <;> simp only [Node.valid, Message.term, ht, decide_true, decide_false] <;> rfl
    · cases entry with
      | none => simp [Accepts, validIdB_iff]
      | some e =>
        simp only [Rust.Option.is_none_or_some]
        rw [Bool.and_eq_true, succB_iff, Bool.and_eq_true, decide_eq_true_eq, validIdB_iff]
        exact ⟨fun ⟨⟨a, b⟩, c⟩ => ⟨a, b, c⟩, fun ⟨a, b, c⟩ => ⟨⟨a, b⟩, c⟩⟩
  | AppendBatch term previous entries commit =>
    obtain ⟨s, hs, hm⟩ := loop_spec term (body term) (fun _ _ _ => rfl) (fun _ _ _ _ => rfl)
      entries.toList previous false 0 (by rw [i32_zero_val]; decide)
      (by rw [i32_zero_val, Vector.length_toList]; simp [MAX_APPEND_ENTRIES])
    rw [i32_zero_val, show (0 : Int).toNat = 0 from rfl] at hm
    refine valid_of _ (decide (term > 0) && validIdB term previous &&
      (match scan term previous false 0 entries.toList with
       | none => false
       | some n => decide (n > 0))) ?_ ?_
    · simp only [Node.valid, Message.term]
      erw [hs]
      rcases s with ⟨r, q, e, c⟩
      rcases hscan : scan term previous false 0 entries.toList with _ | n <;> rw [hscan] at hm <;>
        simp only at hm
      · subst hm
        by_cases ht : term > 0 <;> simp [ht, validIdB]
      · rw [hm.1]
        have hc : (0 : Rust.i32) < c ↔ 0 < n := by
          show (0 : Rust.i32).val < c.val ↔ _
          rw [i32_zero_val, hm.2]; omega
        by_cases ht : term > 0 <;> simp [ht, validIdB, hc]
        by_cases hd : previous = LogId.default
        · simp [hd]
        · simp only [hd, not_false_eq_true, true_and]
          have hb : (previous == LogId.default) = false := by simp [hd]
          rw [hb]
          split <;> rename_i h
          · rcases h with (h | h) | h
            · simp [h]
            · simp [h]
            · have h' : ¬previous.term ≤ term := of_decide_eq_false h
              simp [h']
          · simp only [not_or, Bool.not_eq_false] at h
            obtain ⟨⟨h1, h2⟩, h3⟩ := h
            have h3' : previous.term ≤ term := of_decide_eq_true h3
            simp [Fin.pos_iff_ne_zero, h1, h2, h3']
    · rcases hscan : scan term previous false 0 entries.toList with _ | n
      · have hno : ¬OrderedSlots term previous entries.toList := fun ho => by
          have h := (scan_open term entries.toList previous 0 (0 + occupied entries.toList)).2 ⟨ho, rfl⟩
          rw [hscan] at h
          cases h
        simp [Accepts, hno]
      · obtain ⟨ho, hn⟩ := (scan_open term entries.toList previous 0 n).1 hscan
        simp [Accepts, ho, hn, validIdB_iff, and_assoc]
  | Install term snapshot =>
    refine valid_of _ (decide (term > 0) && (decide (snapshot.last.index > 0) && validIdB term snapshot.last)) ?_ ?_
    · by_cases ht : term > 0 <;> simp [Node.valid, Message.term, ht, validIdB] <;> rfl
    · simp [Accepts, validIdB_iff]
  | Replicated term index rejection =>
    rcases rejection with _ | ⟨next⟩ | _
    · refine valid_of _ (decide (term > 0)) ?_ ?_
      · by_cases ht : term > 0 <;> simp [Node.valid, Message.term, ht]
      · simp [Accepts]
    · refine valid_of _ (decide (term > 0) && decide (next > 0)) ?_ ?_
      · by_cases ht : term > 0 <;> simp [Node.valid, Message.term, ht]
      · simp [Accepts]
    · refine valid_of _ (decide (term > 0)) ?_ ?_
      · by_cases ht : term > 0 <;> simp [Node.valid, Message.term, ht]
      · simp [Accepts]


section Corollaries

variable {V S : Type} {N CAP : Nat} [Rust.Clone V] [Rust.Clone S]

/-! ## Acceptance, rejection, totality -/

/-- `Node::valid` accepts exactly the messages satisfying `Accepts`. -/
theorem valid_iff (m : Message V S) :
    Node.valid (N := N) (CAP := CAP) m = pure true ↔ Accepts m := by
  rw [valid_spec]
  constructor
  · intro h; exact of_decide_eq_true (Rust.pure_inj h)
  · intro h; simp [h]

/-- `Node::valid` rejects exactly the messages violating `Accepts`. -/
theorem valid_false_iff (m : Message V S) :
    Node.valid (N := N) (CAP := CAP) m = pure false ↔ ¬Accepts m := by
  rw [valid_spec]
  constructor
  · intro h; exact of_decide_eq_false (Rust.pure_inj h)
  · intro h; simp [h]

/-- Validation always returns a Boolean (old `validation_total`, now for every message). -/
theorem validation_total (m : Message V S) :
    ∃ accepted, Node.valid (N := N) (CAP := CAP) m = pure accepted :=
  ⟨_, valid_spec m⟩

/-- Validation never panics (old `validation_no_fault`). -/
theorem validation_no_fault (m : Message V S) (p : Rust.Panic) :
    Node.valid (N := N) (CAP := CAP) m ≠ throw p := by
  rw [valid_spec]
  intro h
  have := congrArg ExceptT.run h
  simp [ExceptT.run_pure, ExceptT.run_throw] at this

/-- Validation never diverges. -/
theorem validation_terminates (m : Message V S) :
    (Node.valid (N := N) (CAP := CAP) m).run ≠ none := by
  rw [valid_spec]
  simp [ExceptT.run_pure]

/-! ## Per-variant exact results -/

theorem campaign_range (term campaign : Rust.u64) (granted : Bool) :
    Node.valid (N := N) (CAP := CAP) (Message.PreVoted (V := V) (S := S) term campaign granted) =
      pure (decide (0 < campaign)) := by
  rw [valid_spec]; rfl

theorem positive_campaign_ignores_term (term campaign : Rust.u64) (granted : Bool) (h : 0 < campaign) :
    Node.valid (N := N) (CAP := CAP) (Message.PreVoted (V := V) (S := S) term campaign granted) = pure true := by
  rw [campaign_range]; simp [h]

theorem zero_campaign_ignores_term (term : Rust.u64) (granted : Bool) :
    Node.valid (N := N) (CAP := CAP) (Message.PreVoted (V := V) (S := S) term 0 granted) = pure false := by
  rw [campaign_range]; rfl

theorem zero_campaign (granted : Bool) :
    Node.valid (N := N) (CAP := CAP) (Message.PreVoted (V := V) (S := S) 1 0 granted) = pure false :=
  zero_campaign_ignores_term 1 granted

theorem vote_range (term : Rust.u64) (last : LogId) :
    Node.valid (N := N) (CAP := CAP) (Message.Vote (V := V) (S := S) term last) =
      pure (decide (0 < term ∧ ValidId term last)) := by
  rw [valid_spec]; rfl

theorem prevote_range (term : Rust.u64) (last : LogId) :
    Node.valid (N := N) (CAP := CAP) (Message.PreVote (V := V) (S := S) term last) =
      pure (decide (0 < term ∧ ValidId term last)) := by
  rw [valid_spec]; rfl

theorem voted_range (term : Rust.u64) (granted : Bool) :
    Node.valid (N := N) (CAP := CAP) (Message.Voted (V := V) (S := S) term granted) =
      pure (decide (0 < term)) := by
  rw [valid_spec]; rfl

theorem heartbeat_range (term : Rust.u64) (previous : LogId) (commit : Rust.u64) :
    Node.valid (N := N) (CAP := CAP) (Message.Append (V := V) (S := S) term previous none commit) =
      pure (decide (0 < term ∧ ValidId term previous)) := by
  rw [valid_spec]
  congr 1
  exact decide_eq_decide.mpr ⟨fun ⟨a, b, _⟩ => ⟨a, b⟩, fun ⟨a, b⟩ => ⟨a, b, trivial⟩⟩

theorem append_range (term : Rust.u64) (previous : LogId) (entry : Entry V) (commit : Rust.u64) :
    Node.valid (N := N) (CAP := CAP) (Message.Append (S := S) term previous (some entry) commit) =
      pure (decide (0 < term ∧ ValidId term previous ∧ ValidId term entry.id ∧
        previous.index.val + 1 = entry.id.index.val ∧ previous.term ≤ entry.id.term)) := by
  rw [valid_spec]; rfl

theorem append_accepted (term : Rust.u64) (previous : LogId) (entry : Entry V) (commit : Rust.u64)
    (accepted : Node.valid (N := N) (CAP := CAP) (Message.Append (S := S) term previous (some entry) commit) =
      pure true) :
    0 < term ∧ entry.id.index.val = previous.index.val + 1 ∧ 0 < entry.id.term ∧
      previous.term ≤ entry.id.term ∧ entry.id.term ≤ term := by
  obtain ⟨ht, _, hid, hidx, hle⟩ := (valid_iff _).1 accepted
  refine ⟨ht, hidx.symm, ?_, hle, ?_⟩
  · rcases hid with ⟨h0, _⟩ | ⟨_, hpos, _⟩
    · rw [Fin.ext_iff] at h0; simp at h0; omega
    · exact hpos
  · rcases hid with ⟨h0, _⟩ | ⟨_, _, hle'⟩
    · rw [Fin.ext_iff] at h0; simp at h0; omega
    · exact hle'

/-- The entry payload is never inspected. -/
theorem append_payload_irrelevant (term : Rust.u64) (previous id : LogId) (value value' : Option V)
    (commit : Rust.u64) :
    Node.valid (N := N) (CAP := CAP) (Message.Append (S := S) term previous (some ⟨id, value⟩) commit) =
      Node.valid (N := N) (CAP := CAP) (Message.Append (S := S) term previous (some ⟨id, value'⟩) commit) := by
  rw [append_range, append_range]

theorem append_payload_unread (value : Option V) (commit : Rust.u64) :
    Node.valid (N := N) (CAP := CAP)
      (Message.Append (S := S) 1 ⟨0, 0⟩ (some ⟨⟨1, 1⟩, value⟩) commit) = pure true := by
  rw [append_range]; rfl

theorem snapshot_range (term : Rust.u64) (snapshot : Snapshot S) :
    Node.valid (N := N) (CAP := CAP) (Message.Install (V := V) term snapshot) =
      pure (decide (0 < term ∧ 0 < snapshot.last.index ∧ 0 < snapshot.last.term ∧
        snapshot.last.term ≤ term)) := by
  rw [valid_spec]
  congr 1
  refine decide_eq_decide.mpr ⟨fun ⟨a, b, c⟩ => ?_, fun ⟨a, b, c, d⟩ => ⟨a, b, Or.inr ⟨b, c, d⟩⟩⟩
  rcases c with ⟨h0, _⟩ | ⟨_, c, d⟩
  · rw [h0] at b; exact absurd b (Fin.lt_irrefl 0)
  · exact ⟨a, b, c, d⟩

theorem replicated_range (term index : Rust.u64) (rejection : Option Rejection)
    (kind : rejection = none ∨ rejection = some .Full) :
    Node.valid (N := N) (CAP := CAP) (Message.Replicated (V := V) (S := S) term index rejection) =
      pure (decide (0 < term)) := by
  rcases kind with rfl | rfl <;> (rw [valid_spec]; rfl)

theorem conflict_range (term index next : Rust.u64) :
    Node.valid (N := N) (CAP := CAP)
      (Message.Replicated (V := V) (S := S) term index (some (.Conflict next))) =
      pure (decide (0 < term ∧ 0 < next)) := by
  rw [valid_spec]; rfl

/-! ## Batches -/

theorem batch_range (term : Rust.u64) (previous : LogId)
    (entries : Vector (Option (Entry V)) MAX_APPEND_ENTRIES) (commit : Rust.u64) :
    Node.valid (N := N) (CAP := CAP) (Message.AppendBatch (S := S) term previous entries commit) =
      pure (decide (0 < term ∧ ValidId term previous ∧ 0 < occupied entries.toList ∧
        OrderedSlots term previous entries.toList)) := by
  rw [valid_spec]; rfl

theorem batch_accepts_iff (term : Rust.u64) (previous : LogId)
    (entries : Vector (Option (Entry V)) MAX_APPEND_ENTRIES) (commit : Rust.u64) :
    Node.valid (N := N) (CAP := CAP) (Message.AppendBatch (S := S) term previous entries commit) = pure true ↔
      0 < term ∧ ValidId term previous ∧ 0 < occupied entries.toList ∧
        OrderedSlots term previous entries.toList :=
  valid_iff _

theorem batch_accepted (term : Rust.u64) (previous : LogId)
    (entries : Vector (Option (Entry V)) MAX_APPEND_ENTRIES) (commit : Rust.u64)
    (accepted : Node.valid (N := N) (CAP := CAP)
      (Message.AppendBatch (S := S) term previous entries commit) = pure true) :
    0 < term ∧ ValidId term previous ∧ 0 < occupied entries.toList ∧
      OrderedSlots term previous entries.toList :=
  (batch_accepts_iff term previous entries commit).1 accepted

theorem empty_batch_any_length (term : Rust.u64) (previous : LogId)
    (entries : Vector (Option (Entry V)) MAX_APPEND_ENTRIES) (commit : Rust.u64)
    (empty : Vacant entries.toList) :
    Node.valid (N := N) (CAP := CAP) (Message.AppendBatch (S := S) term previous entries commit) =
      pure false := by
  rw [valid_false_iff]
  rintro ⟨_, _, h, _⟩
  rw [occupied_vacant _ empty] at h
  exact Nat.lt_irrefl 0 h

theorem leading_hole_rejected (term : Rust.u64) (previous : LogId)
    (entries : Vector (Option (Entry V)) MAX_APPEND_ENTRIES) (commit : Rust.u64)
    (entry : Entry V) (rest : List (Option (Entry V)))
    (shape : entries.toList = none :: some entry :: rest) :
    Node.valid (N := N) (CAP := CAP) (Message.AppendBatch (S := S) term previous entries commit) =
      pure false := by
  rw [valid_false_iff]
  rintro ⟨_, _, _, h⟩
  rw [shape] at h
  exact absurd (h (some entry) List.mem_cons_self) (by simp)

/-! ## Zero term rejects every non-`PreVoted` message, whatever its other fields -/

theorem zero_term_prevote (last : LogId) :
    Node.valid (N := N) (CAP := CAP) (Message.PreVote (V := V) (S := S) 0 last) = pure false := by
  rw [prevote_range]; rfl
theorem zero_term_vote (last : LogId) :
    Node.valid (N := N) (CAP := CAP) (Message.Vote (V := V) (S := S) 0 last) = pure false := by
  rw [vote_range]; rfl
theorem zero_term_voted (granted : Bool) :
    Node.valid (N := N) (CAP := CAP) (Message.Voted (V := V) (S := S) 0 granted) = pure false := by
  rw [voted_range]; rfl
theorem zero_term_append (previous : LogId) (entry : Option (Entry V)) (commit : Rust.u64) :
    Node.valid (N := N) (CAP := CAP) (Message.Append (S := S) 0 previous entry commit) = pure false := by
  rw [valid_false_iff]; rintro ⟨h, _⟩; exact Fin.lt_irrefl 0 h
theorem zero_term_appendbatch (previous : LogId)
    (entries : Vector (Option (Entry V)) MAX_APPEND_ENTRIES) (commit : Rust.u64) :
    Node.valid (N := N) (CAP := CAP) (Message.AppendBatch (S := S) 0 previous entries commit) =
      pure false := by
  rw [valid_false_iff]; rintro ⟨h, _⟩; exact Fin.lt_irrefl 0 h
theorem zero_term_install (snapshot : Snapshot S) :
    Node.valid (N := N) (CAP := CAP) (Message.Install (V := V) 0 snapshot) = pure false := by
  rw [valid_false_iff]; rintro ⟨h, _⟩; exact Fin.lt_irrefl 0 h
theorem zero_term_replicated (index : Rust.u64) (rejection : Option Rejection) :
    Node.valid (N := N) (CAP := CAP) (Message.Replicated (V := V) (S := S) 0 index rejection) =
      pure false := by
  rcases rejection with _ | _ | _ <;> (rw [valid_spec]; rfl)

/-! ## Concrete cases -/

/-- An entry with the given id; the payload is arbitrary. -/
def entry (index term : Rust.u64) (value : Option V := none) : Entry V := ⟨⟨index, term⟩, value⟩

/-- Batch slots: the given list, padded with empty slots to `MAX_APPEND_ENTRIES`. -/
def slots (l : List (Option (Entry V))) : Vector (Option (Entry V)) MAX_APPEND_ENTRIES :=
  ⟨((l ++ List.replicate MAX_APPEND_ENTRIES none).take MAX_APPEND_ENTRIES).toArray, by simp⟩

omit [Rust.Clone V] in
theorem slots_toList (l : List (Option (Entry V))) :
    (slots l).toList = (l ++ List.replicate MAX_APPEND_ENTRIES none).take MAX_APPEND_ENTRIES := rfl

theorem voted (granted : Bool) :
    Node.valid (N := N) (CAP := CAP) (Message.Voted (V := V) (S := S) 1 granted) = pure true := by
  rw [voted_range]; rfl
theorem vote_empty :
    Node.valid (N := N) (CAP := CAP) (Message.Vote (V := V) (S := S) 1 ⟨0, 0⟩) = pure true := by
  rw [vote_range]; rfl
theorem prevote_empty :
    Node.valid (N := N) (CAP := CAP) (Message.PreVote (V := V) (S := S) 1 ⟨0, 0⟩) = pure true := by
  rw [prevote_range]; rfl
theorem vote_zero_log_term :
    Node.valid (N := N) (CAP := CAP) (Message.Vote (V := V) (S := S) 1 ⟨1, 0⟩) = pure false := by
  rw [vote_range]; rfl
theorem vote_future_log_term :
    Node.valid (N := N) (CAP := CAP) (Message.Vote (V := V) (S := S) 1 ⟨1, 2⟩) = pure false := by
  rw [vote_range]; rfl
theorem vote_nonzero_term_zero_index :
    Node.valid (N := N) (CAP := CAP) (Message.Vote (V := V) (S := S) 1 ⟨0, 1⟩) = pure false := by
  rw [vote_range]; rfl
theorem heartbeat (commit : Rust.u64) :
    Node.valid (N := N) (CAP := CAP) (Message.Append (V := V) (S := S) 1 ⟨0, 0⟩ none commit) =
      pure true := by
  rw [heartbeat_range]; rfl
theorem append_successor (value : Option V) (commit : Rust.u64) :
    Node.valid (N := N) (CAP := CAP)
      (Message.Append (S := S) 2 ⟨1, 1⟩ (some (entry 2 2 value)) commit) = pure true := by
  rw [append_range]; rfl
theorem append_gap (value : Option V) (commit : Rust.u64) :
    Node.valid (N := N) (CAP := CAP)
      (Message.Append (S := S) 2 ⟨1, 1⟩ (some (entry 3 2 value)) commit) = pure false := by
  rw [append_range]; rfl
theorem append_decreasing_term (value : Option V) (commit : Rust.u64) :
    Node.valid (N := N) (CAP := CAP)
      (Message.Append (S := S) 2 ⟨1, 2⟩ (some (entry 2 1 value)) commit) = pure false := by
  rw [append_range]; rfl
theorem append_overflow (value : Option V) (commit : Rust.u64) :
    Node.valid (N := N) (CAP := CAP)
      (Message.Append (S := S) 2 ⟨⟨2 ^ 64 - 1, by decide⟩, 2⟩
        (some (entry 0 2 value)) commit) = pure false := by
  rw [append_range]; rfl
theorem empty_batch (commit : Rust.u64) :
    Node.valid (N := N) (CAP := CAP) (Message.AppendBatch (S := S) 1 ⟨0, 0⟩ (slots (V := V) []) commit) =
      pure false := by
  rw [batch_range]; rfl
theorem one_entry_batch (commit : Rust.u64) :
    Node.valid (N := N) (CAP := CAP)
      (Message.AppendBatch (S := S) 1 ⟨0, 0⟩ (slots [some (entry (V := V) 1 1)]) commit) = pure true := by
  refine (batch_accepts_iff _ _ _ _).2 ⟨by decide, Or.inl ⟨rfl, rfl⟩, ?_, ?_⟩ <;>
    (rw [slots_toList]; simp [MAX_APPEND_ENTRIES, occupied, OrderedSlots, Vacant, Successor, ValidId, entry])
theorem batch_hole (commit : Rust.u64) :
    Node.valid (N := N) (CAP := CAP)
      (Message.AppendBatch (S := S) 2 ⟨0, 0⟩
        (slots [some (entry (V := V) 1 1), none, some (entry 2 2)]) commit) = pure false := by
  rw [batch_range]; rfl
theorem batch_gap (commit : Rust.u64) :
    Node.valid (N := N) (CAP := CAP)
      (Message.AppendBatch (S := S) 2 ⟨0, 0⟩
        (slots [some (entry (V := V) 1 1), some (entry 3 2)]) commit) = pure false := by
  rw [batch_range]; rfl
theorem batch_decreasing_term (commit : Rust.u64) :
    Node.valid (N := N) (CAP := CAP)
      (Message.AppendBatch (S := S) 2 ⟨0, 0⟩
        (slots [some (entry (V := V) 1 2), some (entry 2 1)]) commit) = pure false := by
  rw [batch_range]; rfl
theorem batch_future_term (commit : Rust.u64) :
    Node.valid (N := N) (CAP := CAP)
      (Message.AppendBatch (S := S) 2 ⟨0, 0⟩ (slots [some (entry (V := V) 1 3)]) commit) =
        pure false := by
  rw [batch_range]; rfl
theorem batch_invalid_previous (commit : Rust.u64) :
    Node.valid (N := N) (CAP := CAP)
      (Message.AppendBatch (S := S) 2 ⟨0, 1⟩ (slots [some (entry (V := V) 1 1)]) commit) =
        pure false := by
  rw [batch_range]; rfl
theorem batch_overflow (commit : Rust.u64) :
    Node.valid (N := N) (CAP := CAP)
      (Message.AppendBatch (S := S) 2 ⟨⟨2 ^ 64 - 1, by decide⟩, 2⟩ (slots [some (entry (V := V) 0 2)])
        commit) = pure false := by
  rw [batch_range]; rfl
theorem full_batch (commit : Rust.u64) :
    Node.valid (N := N) (CAP := CAP)
      (Message.AppendBatch (S := S) 1 ⟨0, 0⟩
        (slots (V := V) [some (entry 1 1), some (entry 2 1), some (entry 3 1), some (entry 4 1), some (entry 5 1), some (entry 6 1), some (entry 7 1), some (entry 8 1), some (entry 9 1), some (entry 10 1), some (entry 11 1), some (entry 12 1), some (entry 13 1), some (entry 14 1), some (entry 15 1), some (entry 16 1)]) commit) =
        pure true := by
  refine (batch_accepts_iff _ _ _ _).2 ⟨by decide, Or.inl ⟨rfl, rfl⟩, ?_, ?_⟩ <;>
    (rw [slots_toList]; simp [MAX_APPEND_ENTRIES, occupied, OrderedSlots, Successor, ValidId, entry]) <;> decide
theorem snapshot_valid (value : S) :
    Node.valid (N := N) (CAP := CAP) (Message.Install (V := V) 1 ⟨⟨1, 1⟩, value⟩) = pure true := by
  rw [snapshot_range]; rfl
theorem snapshot_empty (value : S) :
    Node.valid (N := N) (CAP := CAP) (Message.Install (V := V) 1 ⟨⟨0, 0⟩, value⟩) = pure false := by
  rw [snapshot_range]; rfl
theorem snapshot_zero_term (value : S) :
    Node.valid (N := N) (CAP := CAP) (Message.Install (V := V) 1 ⟨⟨1, 0⟩, value⟩) = pure false := by
  rw [snapshot_range]; rfl
theorem snapshot_future_term (value : S) :
    Node.valid (N := N) (CAP := CAP) (Message.Install (V := V) 1 ⟨⟨1, 2⟩, value⟩) = pure false := by
  rw [snapshot_range]; rfl
theorem replicated_success (index : Rust.u64) :
    Node.valid (N := N) (CAP := CAP) (Message.Replicated (V := V) (S := S) 1 index none) = pure true := by
  rw [valid_spec]; rfl
theorem replicated_full (index : Rust.u64) :
    Node.valid (N := N) (CAP := CAP) (Message.Replicated (V := V) (S := S) 1 index (some .Full)) =
      pure true := by
  rw [valid_spec]; rfl
theorem conflict_zero (index : Rust.u64) :
    Node.valid (N := N) (CAP := CAP)
      (Message.Replicated (V := V) (S := S) 1 index (some (.Conflict 0))) = pure false := by
  rw [conflict_range]; rfl
theorem conflict_positive (index : Rust.u64) :
    Node.valid (N := N) (CAP := CAP)
      (Message.Replicated (V := V) (S := S) 1 index (some (.Conflict 1))) = pure true := by
  rw [conflict_range]; rfl

end Corollaries

end Jarl.Contracts.MessageValidation
