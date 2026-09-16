import Provium.State

/- Jarl's host storage contract, not an implementation of a storage adapter.
   Applying Write discards through a replacement snapshot, truncates a suffix,
   appends the borrowed entries, then replaces hard state atomically. -/
namespace StorageDelta
structure Durable (H S E : Type) where
  hard : H
  snapshot : Option S
  entries : List E

structure Write (H S E : Type) where
  hard : H
  snapshot : Option S
  first : Option Nat
  entries : List E

def afterSnapshot (boundary : S → Nat) (index : E → Nat) (replacement : Option S)
    (entry : E) : Bool :=
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

def apply (boundary : S → Nat) (index : E → Nat) (old : Durable H S E)
    (write : Write H S E) : Durable H S E :=
  ⟨write.hard, replaceSnapshot old.snapshot write.snapshot,
   ((old.entries.filter (afterSnapshot boundary index write.snapshot)).filter
     (beforeTruncation index write.first)) ++ write.entries⟩

theorem apply_normalize (boundary : S → Nat) (index : E → Nat)
    (old : Durable H S E) (write : Write H S E) :
    apply boundary index old write =
      ⟨write.hard, replaceSnapshot old.snapshot write.snapshot,
       old.entries.filter (survives boundary index write) ++ write.entries⟩ := by
  simp only [apply, List.filter_filter]
  rfl

-- The caller supplies the old-log split and per-entry index classifications,
-- rather than assuming that applying the transaction yields the new checkpoint.
structure Retains (boundary : S → Nat) (index : E → Nat) (old : Durable H S E)
    (replacement : Option S) (first : Option Nat) (retained : List E) : Prop where
  split : ∃ before after, old.entries = before ++ retained ++ after ∧
    (∀ e ∈ before, (beforeTruncation index first e && afterSnapshot boundary index replacement e) = false) ∧
    (∀ e ∈ retained, (beforeTruncation index first e && afterSnapshot boundary index replacement e) = true) ∧
    (∀ e ∈ after, (beforeTruncation index first e && afterSnapshot boundary index replacement e) = false)

theorem retained_entries (tracked : Retains boundary index old write.snapshot write.first retained) :
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

theorem apply_retained (tracked : Retains boundary index old write.snapshot write.first retained) :
    apply boundary index old write =
      ⟨write.hard, replaceSnapshot old.snapshot write.snapshot, retained ++ write.entries⟩ := by
  rw [apply_normalize, retained_entries tracked]

theorem replaceSnapshot_idempotent (old replacement : Option S) :
    replaceSnapshot (replaceSnapshot old replacement) replacement = replaceSnapshot old replacement := by
  cases replacement <;> rfl

-- An identical retry removes its previously appended suffix before re-appending.
-- A metadata-only transaction has an empty suffix, satisfying this vacuously.
theorem retry_idempotent (boundary : S → Nat) (index : E → Nat)
    (old : Durable H S E) (write : Write H S E)
    (removed : ∀ e ∈ write.entries, survives boundary index write e = false) :
    apply boundary index (apply boundary index old write) write = apply boundary index old write := by
  have suffix : write.entries.filter (survives boundary index write) = [] :=
    List.filter_eq_nil_iff.mpr (by intro e member; simp [removed e member])
  simp only [apply_normalize]
  simp [List.filter_append, suffix, replaceSnapshot_idempotent]
-- Resolve the borrowed snapshot and the named Rust record fields. Invalid
-- abstract locations/field mappings fail rather than being treated as no update.
def materialize (view : Provium.State.SharedSuffixResult H) (snapshot : Option S)
    (entries : List E) : Option (Write H S E) :=
  if view.outputFields = ["hard", "snapshot", "truncate_from", "entries"] then
    match view.optional with
    | none => some ⟨view.copied, none, view.first, entries⟩
    | some path =>
      if path = ["snapshot"] then
        match snapshot with
        | none => none
        | some value => some ⟨view.copied, some value, view.first, entries⟩
      else none
  else none

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

-- Satisfiability and ordering witnesses for the host contract.
example : Retains (fun n : Nat => n) (fun n : Nat => n)
    (⟨0, some 2, [3,4,5,6]⟩ : Durable Nat Nat Nat) (some 4) (some 6) [5] := by
  constructor
  refine ⟨[3,4], [6], rfl, ?_, ?_, ?_⟩ <;> simp [beforeTruncation, afterSnapshot]

example : apply (fun n : Nat => n) (fun n : Nat => n)
    (⟨0, some 2, [3,4,5,6]⟩ : Durable Nat Nat Nat)
    ⟨1, some 4, some 6, [6,7]⟩ = ⟨1, some 4, [5,6,7]⟩ := rfl
example : (apply (fun n : Nat => n) (fun n : Nat => n)
    (apply (fun n : Nat => n) (fun n : Nat => n)
      (⟨0, none, []⟩ : Durable Nat Nat Nat) ⟨1, none, none, [1]⟩)
    ⟨1, none, none, [1]⟩).entries = [1,1] := rfl
example : materialize
    (⟨1, some ["snapshot"], none, ⟨["entries"],0,0⟩,
      ["hard", "snapshot", "truncate_from", "entries"]⟩ : Provium.State.SharedSuffixResult Nat)
    (none : Option Nat) ([] : List Nat) = none := rfl
example : materialize
    (⟨1, some ["other"], none, ⟨["entries"],0,0⟩,
      ["hard", "snapshot", "truncate_from", "entries"]⟩ : Provium.State.SharedSuffixResult Nat)
    (some 4 : Option Nat) ([] : List Nat) = none := rfl
end StorageDelta
