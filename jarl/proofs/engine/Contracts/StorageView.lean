import Generated

/-!
# Storage-view contracts over the typed translation

Ports the `storage-view` project: `State::write` returns an exact view (copied
hard state, the snapshot only when it changed, the truncation point, and the
borrowed suffix of the slot array), `Write::entries` yields exactly the present
payloads of that suffix, and, under explicit log/snapshot/index premises, applying
the transaction to a durable checkpoint reproduces the source checkpoint and is
idempotent on retry.

In the old deep embedding the suffix was a borrowed location (`entries`, start,
end) that had to be rebased; in the typed translation it is the array slice
itself, so "rebased locations" become: slice position `i` holds source slot
`start + i`.
-/

namespace Jarl.Contracts.StorageView
open Jarl

/-! ## The host storage contract (ported from `Delta.lean`)

Jarl's host storage contract, not an implementation of a storage adapter.
Applying a `Write` discards through a replacement snapshot, truncates a suffix,
appends the borrowed entries, then replaces hard state atomically. -/
namespace Delta

structure Durable (H S E : Type) where
  hard : H
  snapshot : Option S
  entries : List E

structure Write (H S E : Type) where
  hard : H
  snapshot : Option S
  first : Option Nat
  entries : List E
  deriving DecidableEq

variable {H S E : Type}

def afterSnapshot (boundary : S → Nat) (index : E → Nat) (replacement : Option S) (entry : E) : Bool :=
  match replacement with
  | none => true
  | some snapshot => decide (boundary snapshot < index entry)

def beforeTruncation (index : E → Nat) (first : Option Nat) (entry : E) : Bool :=
  match first with
  | none => true
  | some cut => decide (index entry < cut)

def survives (boundary : S → Nat) (index : E → Nat) (write : Write H S E) (entry : E) : Bool :=
  beforeTruncation index write.first entry && afterSnapshot boundary index write.snapshot entry

def replaceSnapshot (old replacement : Option S) : Option S :=
  match replacement with
  | none => old
  | some snapshot => some snapshot

def apply (boundary : S → Nat) (index : E → Nat) (old : Durable H S E) (write : Write H S E) :
    Durable H S E :=
  ⟨write.hard, replaceSnapshot old.snapshot write.snapshot,
   ((old.entries.filter (afterSnapshot boundary index write.snapshot)).filter
     (beforeTruncation index write.first)) ++ write.entries⟩

theorem apply_normalize (boundary : S → Nat) (index : E → Nat) (old : Durable H S E) (write : Write H S E) :
    apply boundary index old write =
      ⟨write.hard, replaceSnapshot old.snapshot write.snapshot,
       old.entries.filter (survives boundary index write) ++ write.entries⟩ := by
  simp only [apply, List.filter_filter]
  rfl

/-- The caller supplies the old-log split and per-entry index classifications,
rather than assuming that applying the transaction yields the new checkpoint. -/
structure Retains (boundary : S → Nat) (index : E → Nat) (old : Durable H S E)
    (replacement : Option S) (first : Option Nat) (retained : List E) : Prop where
  split : ∃ before after, old.entries = before ++ retained ++ after ∧
    (∀ e ∈ before, (beforeTruncation index first e && afterSnapshot boundary index replacement e) = false) ∧
    (∀ e ∈ retained, (beforeTruncation index first e && afterSnapshot boundary index replacement e) = true) ∧
    (∀ e ∈ after, (beforeTruncation index first e && afterSnapshot boundary index replacement e) = false)

theorem retained_entries {boundary : S → Nat} {index : E → Nat} {old : Durable H S E}
    {write : Write H S E} {retained : List E}
    (tracked : Retains boundary index old write.snapshot write.first retained) :
    old.entries.filter (survives boundary index write) = retained := by
  obtain ⟨before, after, split, removedBefore, kept, removedAfter⟩ := tracked.split
  have left : before.filter (survives boundary index write) = [] :=
    List.filter_eq_nil_iff.mpr (by
      intro e member
      have removed : survives boundary index write e = false := removedBefore e member
      simp [removed])
  have right : after.filter (survives boundary index write) = [] :=
    List.filter_eq_nil_iff.mpr (by
      intro e member
      have removed : survives boundary index write e = false := removedAfter e member
      simp [removed])
  have middle : retained.filter (survives boundary index write) = retained :=
    List.filter_eq_self.mpr kept
  simp [split, left, right, middle]

theorem apply_retained {boundary : S → Nat} {index : E → Nat} {old : Durable H S E}
    {write : Write H S E} {retained : List E}
    (tracked : Retains boundary index old write.snapshot write.first retained) :
    apply boundary index old write =
      ⟨write.hard, replaceSnapshot old.snapshot write.snapshot, retained ++ write.entries⟩ := by
  rw [apply_normalize, retained_entries tracked]

theorem replaceSnapshot_idempotent (old replacement : Option S) :
    replaceSnapshot (replaceSnapshot old replacement) replacement = replaceSnapshot old replacement := by
  cases replacement <;> rfl

/-- An identical retry removes its previously appended suffix before re-appending.
A metadata-only transaction has an empty suffix, satisfying this vacuously. -/
theorem retry_idempotent (boundary : S → Nat) (index : E → Nat) (old : Durable H S E) (write : Write H S E)
    (removed : ∀ e ∈ write.entries, survives boundary index write e = false) :
    apply boundary index (apply boundary index old write) write = apply boundary index old write := by
  have suffix : write.entries.filter (survives boundary index write) = [] :=
    List.filter_eq_nil_iff.mpr (by intro e member; simp [removed e member])
  simp only [apply_normalize]
  simp [List.filter_append, suffix, replaceSnapshot_idempotent]

theorem snapshot_tracking (old current : Option S) (changed : Bool)
    (unchanged : changed = false → old = current)
    (cannotRemove : current = none → old = none) :
    replaceSnapshot old (if changed then current else none) = current := by
  cases changed with
  | false => exact unchanged rfl
  | true =>
    cases current with
    | none => exact cannotRemove rfl
    | some value => rfl

theorem suffix_indices (slots : List (Option E)) (length base cut : Nat) (index : E → Nat)
    (positioned : ∀ position entry, slots[position]? = some (some entry) →
      position < length → index entry = base + position + 1)
    (entry : E)
    (member : entry ∈ ((slots.drop (min (cut - base - 1) length)).take
      (length - min (cut - base - 1) length)).filterMap id) :
    cut ≤ index entry := by
  obtain ⟨cell, member, present⟩ := List.mem_filterMap.mp member
  change cell = some entry at present
  subst cell
  obtain ⟨position, found⟩ := List.getElem?_of_mem member
  have within := (List.getElem?_eq_some_iff.mp found).1
  have small : position < length - min (cut - base - 1) length := by
    simp only [List.length_take, List.length_drop] at within
    omega
  have read : slots[min (cut - base - 1) length + position]? = some (some entry) := by
    simpa [List.getElem?_take_of_lt small, List.getElem?_drop] using found
  rw [positioned _ entry read (by omega)]
  omega

end Delta

/-! ## `State::write` and `Write::entries` -/

variable {V S : Type} {CAP : Nat}

/-- The first slot of the returned suffix: `len` for a metadata-only update,
otherwise the (saturating) offset of the truncation index past the boundary,
clamped to `len`. -/
def writeStart (s : State V S CAP) (first : Option Rust.u64) : Nat :=
  match first with
  | none => s.len.val
  | some index => min (index.val - s.base.index.val - 1) s.len.val

theorem writeStart_le (s : State V S CAP) (first : Option Rust.u64) : writeStart s first ≤ s.len.val := by
  unfold writeStart; split <;> omega

/-- The host transaction denoted by a returned `Write`: its fields, with the
borrowed snapshot resolved and the suffix replaced by the payloads `entries()`
yields. -/
def materialize (w : Jarl.Write V S) : Delta.Write HardState (Snapshot S) (Entry V) :=
  ⟨w.hard, w.snapshot, w.truncate_from.map (·.val), Write.entries_fn w⟩

private theorem write_offset (s : State V S CAP) (first : Option Rust.u64) :
    (Rust.Option.map_or first s.len (fun index => Rust.min (Rust.Result.unwrap_or
      (Rust.try_from (m := 64) (Rust.saturating_sub (Rust.saturating_sub index (State.base s).index) 1)) s.len)
      s.len)).val = writeStart s first := by
  cases first with
  | none => rfl
  | some index =>
    have tf : ∀ a : Rust.u64, Rust.try_from (m := 64) a = .Ok a := fun a => by
      simp [Rust.try_from, a.isLt]
    simp only [writeStart, Rust.Option.map_or, tf, Rust.Result.unwrap_or, Rust.val_min,
      Rust.val_saturating_sub]
    rfl

/-- Any returned view has exactly this form. -/
theorem write_returns (s : State V S CAP) (first : Option Rust.u64) (changed : Bool) (w : Jarl.Write V S)
    (h : State.write s first changed = pure w) :
    s.len.val ≤ CAP ∧
      w = { hard := s.hard, snapshot := if changed then s.snapshot else none, truncate_from := first,
            entries := s.entries.toArray.extract (writeStart s first) s.len.val } := by
  unfold State.write at h
  obtain ⟨t1, h1, h⟩ := Rust.bind_eq_pure h
  unfold Rust.Slice.range at h1
  split at h1
  · rename_i c
    cases Rust.pure_inj h1
    cases Rust.pure_inj h
    refine ⟨c.2, ?_⟩
    rw [write_offset]
    cases changed <;> cases s.snapshot <;> rfl
  · have := congrArg ExceptT.run h1
    simp [Rust.fail, ExceptT.run_throw, ExceptT.run_pure] at this

/-- The exact view: copied hard state, the snapshot only when changed, the
truncation point, and slots `writeStart .. len` of the source array. -/
theorem exact_view (s : State V S CAP) (first : Option Rust.u64) (changed : Bool)
    (capacity : s.len.val ≤ CAP) :
    State.write s first changed =
      pure { hard := s.hard, snapshot := if changed then s.snapshot else none, truncate_from := first,
             entries := s.entries.toArray.extract (writeStart s first) s.len.val } := by
  unfold State.write
  dsimp only
  have c : (Rust.Option.map_or first s.len (fun index => Rust.min (Rust.Result.unwrap_or
      (Rust.try_from (m := 64) (Rust.saturating_sub (Rust.saturating_sub index (State.base s).index) 1)) s.len)
      s.len)).val ≤ s.len.val ∧ s.len.val ≤ CAP := ⟨by rw [write_offset]; exact writeStart_le s first, capacity⟩
  rw [Rust.Slice.range_ok _ _ _ c, pure_bind, write_offset]
  cases changed <;> cases s.snapshot <;> rfl

theorem hard_matches_write (s : State V S CAP) (first : Option Rust.u64) (changed : Bool)
    (capacity : s.len.val ≤ CAP) :
    ∃ result, State.write s first changed = pure result ∧ State.hard_fn s = result.hard :=
  ⟨_, exact_view s first changed capacity, rfl⟩

/-- No truncation point and no snapshot change: only metadata, with an empty suffix. -/
theorem metadata_only (s : State V S CAP) (capacity : s.len.val ≤ CAP) :
    State.write s none false =
      pure { hard := s.hard, snapshot := none, truncate_from := none, entries := #[] } := by
  rw [exact_view s none false capacity]
  rw [show writeStart s none = s.len.val from rfl,
    Array.extract_eq_empty_iff.mpr (Nat.min_le_left _ _)]
  rfl

/-- A truncation point `index` returns the suffix from offset `index - boundary - 1`. -/
theorem replacement_suffix (s : State V S CAP) (index : Rust.u64) (changed : Bool)
    (capacity : s.len.val ≤ CAP) :
    State.write s (some index) changed =
      pure { hard := s.hard, snapshot := if changed then s.snapshot else none, truncate_from := some index,
             entries := s.entries.toArray.extract
               (min (index.val - s.base.index.val - 1) s.len.val) s.len.val } :=
  exact_view s (some index) changed capacity

/-- `entries()` yields exactly the present payloads of the slice, in order. -/
theorem entries_exact (w : Jarl.Write V S) : Write.entries_fn w = w.entries.toList.filterMap id := by
  simp [Write.entries_fn, Rust.Iter.flatten]

/-- The returned slice, rebased: its position `i` is source slot `start + i`, and
`entries()` yields the present payloads of source slots `start .. len`. -/
theorem returned_entries (s : State V S CAP) (first : Option Rust.u64) (changed : Bool)
    (capacity : s.len.val ≤ CAP) :
    ∃ result, State.write s first changed = pure result ∧
      result.entries.toList = (s.entries.toList.drop (writeStart s first)).take
        (s.len.val - writeStart s first) ∧
      (∀ i, i < s.len.val - writeStart s first →
        result.entries.toList[i]? = s.entries.toList[writeStart s first + i]?) ∧
      Write.entries_fn result = ((s.entries.toList.drop (writeStart s first)).take
        (s.len.val - writeStart s first)).filterMap id := by
  have sl : (s.entries.toArray.extract (writeStart s first) s.len.val).toList =
      (s.entries.toList.drop (writeStart s first)).take (s.len.val - writeStart s first) := by
    rw [Array.toList_extract, List.extract_eq_take_drop, Vector.toList_toArray]
  refine ⟨_, exact_view s first changed capacity, sl, ?_, ?_⟩
  · intro i hi
    rw [sl, List.getElem?_take_of_lt hi, List.getElem?_drop]
  · rw [entries_exact, sl]

theorem returned_payloads (s : State V S CAP) (first : Option Rust.u64) (changed : Bool)
    (capacity : s.len.val ≤ CAP) :
    ∃ result, State.write s first changed = pure result ∧
      Write.entries_fn result = ((s.entries.toList.drop (writeStart s first)).take
        (s.len.val - writeStart s first)).filterMap id :=
  let ⟨r, h, _, _, e⟩ := returned_entries s first changed capacity; ⟨r, h, e⟩

/-- The list-splice part of the durable transaction contract. The caller must still
establish that snapshot discard and truncation leave this prefix. -/
theorem retained_prefix_plus_returned_payloads (s : State V S CAP) (first : Option Rust.u64)
    (changed : Bool) (retained : List (Entry V)) (capacity : s.len.val ≤ CAP)
    (retainedPrefix : retained = (s.entries.toList.take (writeStart s first)).filterMap id) :
    ∃ result, State.write s first changed = pure result ∧
      retained ++ Write.entries_fn result = (s.entries.toList.take s.len.val).filterMap id := by
  obtain ⟨result, h, e⟩ := returned_payloads s first changed capacity
  refine ⟨result, h, ?_⟩
  have bound := writeStart_le s first
  rw [e, retainedPrefix, ← List.filterMap_append, ← List.take_add, Nat.add_sub_of_le bound]

/-- The transaction a returned view denotes. -/
theorem materialize_returned (s : State V S CAP) (first : Option Rust.u64) (changed : Bool)
    (view : Jarl.Write V S) (returned : State.write s first changed = pure view) :
    materialize view = ⟨s.hard, if changed then s.snapshot else none, first.map (·.val),
      ((s.entries.toList.drop (writeStart s first)).take (s.len.val - writeStart s first)).filterMap id⟩ := by
  obtain ⟨capacity, rfl⟩ := write_returns s first changed view returned
  obtain ⟨r, h, _, _, e⟩ := returned_entries s first changed capacity
  rw [exact_view s first changed capacity] at h
  cases Rust.pure_inj h
  simp only [materialize, e]

/-- Atomic checkpoint equivalence: under explicit premises on the old durable
checkpoint, applying the returned transaction yields exactly the source checkpoint. -/
theorem source_checkpoint (s : State V S CAP) (first : Option Rust.u64) (changed : Bool)
    (old : Delta.Durable HardState (Snapshot S) (Entry V))
    (boundary : Snapshot S → Nat) (index : Entry V → Nat) (capacity : s.len.val ≤ CAP)
    (unchanged : changed = false → old.snapshot = s.snapshot)
    (cannotRemove : s.snapshot = none → old.snapshot = none)
    (tracked : Delta.Retains boundary index old (if changed then s.snapshot else none) (first.map (·.val))
      ((s.entries.toList.take (writeStart s first)).filterMap id)) :
    ∃ view, State.write s first changed = pure view ∧
      Delta.apply boundary index old (materialize view) =
        ⟨s.hard, s.snapshot, (s.entries.toList.take s.len.val).filterMap id⟩ := by
  obtain ⟨view, returned, _⟩ := returned_payloads s first changed capacity
  refine ⟨view, returned, ?_⟩
  rw [materialize_returned s first changed view returned]
  rw [Delta.apply_retained (write := ⟨s.hard, if changed then s.snapshot else none, first.map (·.val), _⟩) tracked]
  have snapshotOk := Delta.snapshot_tracking old.snapshot s.snapshot changed unchanged cannotRemove
  have bound := writeStart_le s first
  simp only [Delta.Durable.mk.injEq, true_and]
  rw [snapshotOk, ← List.filterMap_append, ← List.take_add, Nat.add_sub_of_le bound]
  exact ⟨rfl, rfl⟩

/-- Retry idempotence for a replacement: if every slot below `len` holds the entry
of index `boundary + position + 1`, applying the transaction twice equals applying
it once. -/
theorem source_retry_some (s : State V S CAP) (cut : Rust.u64) (changed : Bool)
    (boundary : Snapshot S → Nat) (index : Entry V → Nat) (capacity : s.len.val ≤ CAP)
    (positioned : ∀ position entry, s.entries.toList[position]? = some (some entry) →
      position < s.len.val → index entry = s.base.index.val + position + 1) :
    ∃ view, State.write s (some cut) changed = pure view ∧
      ∀ old, Delta.apply boundary index (Delta.apply boundary index old (materialize view)) (materialize view) =
        Delta.apply boundary index old (materialize view) := by
  refine ⟨_, exact_view s (some cut) changed capacity, ?_⟩
  intro old
  apply Delta.retry_idempotent
  intro entry member
  rw [materialize_returned s (some cut) changed _ (exact_view s (some cut) changed capacity)] at member ⊢
  have atOrAfter := Delta.suffix_indices s.entries.toList s.len.val s.base.index.val cut.val index
    positioned entry (by simpa [writeStart] using member)
  simp [Delta.survives, Delta.beforeTruncation, Nat.not_lt.mpr atOrAfter]

/-- Retry idempotence for a metadata/snapshot-only transaction. -/
theorem source_retry_none (s : State V S CAP) (changed : Bool)
    (boundary : Snapshot S → Nat) (index : Entry V → Nat) (capacity : s.len.val ≤ CAP) :
    ∃ view, State.write s none changed = pure view ∧ (materialize view).entries = [] ∧
      ∀ old, Delta.apply boundary index (Delta.apply boundary index old (materialize view)) (materialize view) =
        Delta.apply boundary index old (materialize view) := by
  obtain ⟨view, hv⟩ : ∃ view, State.write s none changed = pure view :=
    ⟨_, exact_view s none changed capacity⟩
  have empty : (materialize view).entries = [] := by
    rw [materialize_returned s none changed view hv]; simp [writeStart]
  refine ⟨view, hv, empty, ?_⟩
  intro old
  apply Delta.retry_idempotent
  intro entry member
  rw [empty] at member
  simp at member

/-! ## A concrete checkpoint witness

Exercises all three log phases: discard 3/4 through snapshot 4, retain 5, replace
6 with suffix 6/7. A component witness, not reachability from genesis. -/

private def wEntry (k : Nat) : Entry Nat := ⟨⟨Rust.ofNat k, 1⟩, some k⟩
private def wSnap (k : Nat) : Snapshot Nat := ⟨⟨Rust.ofNat k, 1⟩, k⟩
private def wHard (k : Nat) : HardState := ⟨1, none, Rust.ofNat k⟩

private def checkpointState : State Nat Nat 3 :=
  ⟨wHard 1, some (wSnap 4), #v[some (wEntry 5), some (wEntry 6), some (wEntry 7)], 3⟩

private def byIndex (e : Entry Nat) : Nat := e.id.index.val
private def bySnap (s : Snapshot Nat) : Nat := s.last.index.val

theorem checkpoint_witness :
    ∃ view, State.write checkpointState (some 6) true = pure view ∧
      Write.entries_fn view = [wEntry 6, wEntry 7] ∧
      materialize view = ⟨wHard 1, some (wSnap 4), some 6, [wEntry 6, wEntry 7]⟩ ∧
      Delta.apply bySnap byIndex ⟨wHard 0, some (wSnap 2), [wEntry 3, wEntry 4, wEntry 5, wEntry 6]⟩
        (materialize view) = ⟨wHard 1, some (wSnap 4), [wEntry 5, wEntry 6, wEntry 7]⟩ := by
  refine ⟨_, exact_view checkpointState (some 6) true (by decide), ?_, ?_, ?_⟩ <;> rfl

end Jarl.Contracts.StorageView
