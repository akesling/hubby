import Generated
import StorageDelta
open Provium.State
namespace StorageView

-- Field roles are bound by the original Rust record construction:
-- hard = copied, snapshot = optional, truncate_from = first, entries = slice.
-- This proves the returned view, not the host's application of its transaction.
theorem exact_view (bits : Nat) (state : SharedSuffixStore α)
    (first : Option Nat) (changed : Bool) (start : Nat)
    (offset : suffixOffset JarlView.state_State_write_offset bits state.view first = .ok start)
    (capacity : state.view.lengths ["len"] ≤ state.capacities ["entries"]) :
    JarlView.state_State_write bits state first changed = .ok
      ⟨state.copied ["hard"],
       if changed && (state.view.records ["snapshot"]).isSome then some ["snapshot"] else none,
       first, ⟨["entries"], start, state.view.lengths ["len"]⟩, ["hard", "snapshot", "truncate_from", "entries"]⟩ := by
  have result := sharedSuffix_success (program := JarlView.state_State_write_ir)
    (changed := changed) offset capacity
  simpa [JarlView.state_State_write, JarlView.state_State_write_ir,
    JarlView.state_State_write_offset] using result

theorem hard_matches_write (bits : Nat) (state : SharedSuffixStore α)
    (first : Option Nat) (changed : Bool) (start : Nat)
    (offset : suffixOffset JarlView.state_State_write_offset bits state.view first = .ok start)
    (capacity : state.view.lengths ["len"] ≤ state.capacities ["entries"]) :
    ∃ result, JarlView.state_State_write bits state first changed = .ok result ∧
      JarlView.state_State_hard (fun path => .other (state.copied path)) = .other result.copied := by
  refine ⟨_, exact_view bits state first changed start offset capacity, ?_⟩
  rfl

theorem metadata_only (bits : Nat) (state : SharedSuffixStore α)
    (word : state.view.lengths ["len"] < 2^bits)
    (capacity : state.view.lengths ["len"] ≤ state.capacities ["entries"]) :
    JarlView.state_State_write bits state none false = .ok
      ⟨state.copied ["hard"], none, none,
       ⟨["entries"], state.view.lengths ["len"], state.view.lengths ["len"]⟩, ["hard", "snapshot", "truncate_from", "entries"]⟩ := by
  have offset := suffixOffset_none JarlView.state_State_write_offset bits state.view word
  simpa [JarlView.state_State_write_offset] using exact_view bits state none false _ offset capacity
theorem replacement_suffix (bits : Nat) (state : SharedSuffixStore α)
    (index boundary : Nat) (changed : Bool)
    (word : state.view.lengths ["len"] < 2^bits)
    (selected : selectRecord JarlView.state_State_write_offset.base state.view.records
      ["index"] = .unsigned "u64" boundary)
    (indexBound : index < 2^64) (boundaryBound : boundary < 2^64)
    (capacity : state.view.lengths ["len"] ≤ state.capacities ["entries"]) :
    JarlView.state_State_write bits state (some index) changed = .ok
      ⟨state.copied ["hard"],
       if changed && (state.view.records ["snapshot"]).isSome then some ["snapshot"] else none,
       some index,
       ⟨["entries"], min (index - boundary - 1) (state.view.lengths ["len"]),
         state.view.lengths ["len"]⟩, ["hard", "snapshot", "truncate_from", "entries"]⟩ := by
  have offset := suffixOffset_some JarlView.state_State_write_offset bits state.view
    index boundary word selected indexBound boundaryBound (by decide)
  exact exact_view bits state (some index) changed _ offset capacity
-- Iterator coordinates are relative to the returned slice; rebase them before
-- interpreting the entries as positions in State's original storage array.
theorem entries_exact (place : SlicePlace) (slots : List (Option α)) :
    JarlView.ready_Write_entries (sliceTraversal ["entries"] place slots) =
      .ok (presentPlaces ["entries"] 0 (sliceContents place slots)) :=
  iterateWholeSlice ["entries"] place slots

theorem returned_entries (bits : Nat) (state : SharedSuffixStore α)
    (slots : List (Option β)) (first : Option Nat) (changed : Bool) (start : Nat)
    (offset : suffixOffset JarlView.state_State_write_offset bits state.view first = .ok start)
    (storage : state.capacities ["entries"] = slots.length)
    (length : state.view.lengths ["len"] ≤ slots.length) :
    ∃ result, JarlView.state_State_write bits state first changed = .ok result ∧
      (JarlView.ready_Write_entries (sliceTraversal ["entries"] result.slice slots)).map
        (List.map (rebasePlace result.slice)) =
        .ok (presentPlaces ["entries"] start
          ((slots.drop start).take (state.view.lengths ["len"] - start))) := by
  let result : SharedSuffixResult α :=
    ⟨state.copied ["hard"],
     if changed && (state.view.records ["snapshot"]).isSome then some ["snapshot"] else none,
     first, ⟨["entries"], start, state.view.lengths ["len"]⟩,
     ["hard", "snapshot", "truncate_from", "entries"]⟩
  refine ⟨result, exact_view bits state first changed start offset (by simpa [storage] using length), ?_⟩
  simpa [result, sliceContents, JarlView.ready_Write_entries, JarlView.ready_Write_entries_ir] using iterateWholeSlice_rebased ["entries"] result.slice slots
theorem returned_payloads (bits : Nat) (state : SharedSuffixStore α)
    (slots : List (Option β)) (first : Option Nat) (changed : Bool) (start : Nat)
    (offset : suffixOffset JarlView.state_State_write_offset bits state.view first = .ok start)
    (storage : state.capacities ["entries"] = slots.length)
    (length : state.view.lengths ["len"] ≤ slots.length) :
    ∃ result places, JarlView.state_State_write bits state first changed = .ok result ∧
      (JarlView.ready_Write_entries (sliceTraversal ["entries"] result.slice slots)).map
        (List.map (rebasePlace result.slice)) = .ok places ∧
      loadPlaces (loadFrom ["entries"] slots) places =
        some (((slots.drop start).take (state.view.lengths ["len"] - start)).filterMap id) := by
  obtain ⟨result, written, iterated⟩ := returned_entries bits state slots first changed start offset storage length
  refine ⟨result, _, written, iterated, ?_⟩
  exact load_sliceContents ⟨["entries"], start, state.view.lengths ["len"]⟩ slots

-- This is the list-splice part of the durable transaction contract. The caller
-- must still establish that snapshot discard and truncation leave this prefix;
-- the theorem does not assume or claim that dirty tracking already does so.
theorem retained_prefix_plus_returned_payloads (bits : Nat) (state : SharedSuffixStore α)
    (slots : List (Option β)) (first : Option Nat) (changed : Bool) (start : Nat)
    (retained : List β)
    (offset : suffixOffset JarlView.state_State_write_offset bits state.view first = .ok start)
    (storage : state.capacities ["entries"] = slots.length)
    (length : state.view.lengths ["len"] ≤ slots.length)
    (retainedPrefix : retained = (slots.take start).filterMap id) :
    ∃ result places suffix, JarlView.state_State_write bits state first changed = .ok result ∧
      (JarlView.ready_Write_entries (sliceTraversal ["entries"] result.slice slots)).map
        (List.map (rebasePlace result.slice)) = .ok places ∧
      loadPlaces (loadFrom ["entries"] slots) places = some suffix ∧
      retained ++ suffix = (slots.take (state.view.lengths ["len"])).filterMap id := by
  obtain ⟨result, places, written, iterated, loaded⟩ :=
    returned_payloads bits state slots first changed start offset storage length
  refine ⟨result, places, _, written, iterated, loaded, ?_⟩
  have bound : start ≤ state.view.lengths ["len"] := suffixOffset_bounded offset
  rw [retainedPrefix, ← List.filterMap_append, ← List.take_add, Nat.add_sub_of_le bound]
theorem materialize_returned (bits : Nat) (state : SharedSuffixStore H)
    (first : Option Nat) (changed : Bool) (start : Nat)
    (view : SharedSuffixResult H) (snapshot : Option S) (suffix : List E)
    (offset : suffixOffset JarlView.state_State_write_offset bits state.view first = .ok start)
    (capacity : state.view.lengths ["len"] ≤ state.capacities ["entries"])
    (presence : (state.view.records ["snapshot"]).isSome = snapshot.isSome)
    (returned : JarlView.state_State_write bits state first changed = .ok view) :
    StorageDelta.materialize view snapshot suffix =
      some ⟨state.copied ["hard"], if changed then snapshot else none, first, suffix⟩ := by
  have shape := Except.ok.inj (returned.symm.trans (exact_view bits state first changed start offset capacity))
  rw [shape]
  cases snapshot <;> cases changed <;> simp [StorageDelta.materialize, presence]

theorem source_checkpoint (bits : Nat) (state : SharedSuffixStore H)
    (slots : List (Option E)) (first : Option Nat) (changed : Bool) (start : Nat)
    (snapshot : Option S) (old : StorageDelta.Durable H S E)
    (boundary : S → Nat) (index : E → Nat)
    (offset : suffixOffset JarlView.state_State_write_offset bits state.view first = .ok start)
    (storage : state.capacities ["entries"] = slots.length)
    (length : state.view.lengths ["len"] ≤ slots.length)
    (presence : (state.view.records ["snapshot"]).isSome = snapshot.isSome)
    (unchanged : changed = false → old.snapshot = snapshot)
    (cannotRemove : snapshot = none → old.snapshot = none)
    (tracked : StorageDelta.Retains boundary index old (if changed then snapshot else none) first
      ((slots.take start).filterMap id)) :
    ∃ view places write,
      JarlView.state_State_write bits state first changed = .ok view ∧
      (JarlView.ready_Write_entries (sliceTraversal ["entries"] view.slice slots)).map
        (List.map (rebasePlace view.slice)) = .ok places ∧
      loadPlaces (loadFrom ["entries"] slots) places = some write.entries ∧
      StorageDelta.materialize view snapshot write.entries = some write ∧
      StorageDelta.apply boundary index old write =
        ⟨state.copied ["hard"], snapshot, (slots.take (state.view.lengths ["len"])).filterMap id⟩ := by
  obtain ⟨view, places, returned, iterated, loaded⟩ :=
    returned_payloads bits state slots first changed start offset storage length
  let write : StorageDelta.Write H S E :=
    ⟨state.copied ["hard"], if changed then snapshot else none, first,
     ((slots.drop start).take (state.view.lengths ["len"] - start)).filterMap id⟩
  refine ⟨view, places, write, returned, iterated, loaded, ?_, ?_⟩
  · exact materialize_returned bits state first changed start view snapshot write.entries offset
      (by simpa [storage] using length) presence returned
  · rw [StorageDelta.apply_retained (write := write) tracked]
    have snapshotOk := StorageDelta.snapshot_tracking old.snapshot snapshot changed unchanged cannotRemove
    have bound : start ≤ state.view.lengths ["len"] := suffixOffset_bounded offset
    dsimp [write]
    rw [snapshotOk, ← List.filterMap_append, ← List.take_add, Nat.add_sub_of_le bound]
theorem source_retry_some (bits : Nat) (state : SharedSuffixStore H)
    (slots : List (Option E)) (cut base : Nat) (changed : Bool) (snapshot : Option S)
    (boundary : S → Nat) (index : E → Nat)
    (word : state.view.lengths ["len"] < 2^bits)
    (selected : selectRecord JarlView.state_State_write_offset.base state.view.records
      ["index"] = .unsigned "u64" base)
    (cutBound : cut < 2^64) (baseBound : base < 2^64)
    (storage : state.capacities ["entries"] = slots.length)
    (length : state.view.lengths ["len"] ≤ slots.length)
    (presence : (state.view.records ["snapshot"]).isSome = snapshot.isSome)
    (positioned : ∀ position entry, slots[position]? = some (some entry) →
      position < state.view.lengths ["len"] → index entry = base + position + 1) :
    ∃ view places write,
      JarlView.state_State_write bits state (some cut) changed = .ok view ∧
      (JarlView.ready_Write_entries (sliceTraversal ["entries"] view.slice slots)).map
        (List.map (rebasePlace view.slice)) = .ok places ∧
      loadPlaces (loadFrom ["entries"] slots) places = some write.entries ∧
      StorageDelta.materialize view snapshot write.entries = some write ∧
      ∀ old, StorageDelta.apply boundary index (StorageDelta.apply boundary index old write) write =
        StorageDelta.apply boundary index old write := by
  let start := min (cut - base - 1) (state.view.lengths ["len"])
  have offset := suffixOffset_some JarlView.state_State_write_offset bits state.view
    cut base word selected cutBound baseBound (by decide)
  obtain ⟨view, places, returned, iterated, loaded⟩ :=
    returned_payloads bits state slots (some cut) changed start offset storage length
  let write : StorageDelta.Write H S E :=
    ⟨state.copied ["hard"], if changed then snapshot else none, some cut,
     ((slots.drop start).take (state.view.lengths ["len"] - start)).filterMap id⟩
  refine ⟨view, places, write, returned, iterated, loaded, ?_, ?_⟩
  · exact materialize_returned bits state (some cut) changed start view snapshot write.entries offset
      (by simpa [storage] using length) presence returned
  · intro old
    apply StorageDelta.retry_idempotent
    intro entry member
    have atOrAfter := StorageDelta.suffix_indices slots (state.view.lengths ["len"]) base cut index
      positioned entry member
    simp [StorageDelta.survives, StorageDelta.beforeTruncation, write, Nat.not_lt.mpr atOrAfter]

theorem source_retry_none (bits : Nat) (state : SharedSuffixStore H)
    (slots : List (Option E)) (changed : Bool) (snapshot : Option S)
    (boundary : S → Nat) (index : E → Nat)
    (word : state.view.lengths ["len"] < 2^bits)
    (storage : state.capacities ["entries"] = slots.length)
    (length : state.view.lengths ["len"] ≤ slots.length)
    (presence : (state.view.records ["snapshot"]).isSome = snapshot.isSome) :
    ∃ view places write,
      JarlView.state_State_write bits state none changed = .ok view ∧
      (JarlView.ready_Write_entries (sliceTraversal ["entries"] view.slice slots)).map
        (List.map (rebasePlace view.slice)) = .ok places ∧
      loadPlaces (loadFrom ["entries"] slots) places = some write.entries ∧
      StorageDelta.materialize view snapshot write.entries = some write ∧
      ∀ old, StorageDelta.apply boundary index (StorageDelta.apply boundary index old write) write =
        StorageDelta.apply boundary index old write := by
  let start := state.view.lengths ["len"]
  have offset := suffixOffset_none JarlView.state_State_write_offset bits state.view word
  obtain ⟨view, places, returned, iterated, loaded⟩ :=
    returned_payloads bits state slots none changed start offset storage length
  let write : StorageDelta.Write H S E :=
    ⟨state.copied ["hard"], if changed then snapshot else none, none, []⟩
  refine ⟨view, places, write, returned, iterated, ?_, ?_, ?_⟩
  · simpa [start, write] using loaded
  · exact materialize_returned bits state none changed start view snapshot write.entries offset
      (by simpa [storage] using length) presence returned
  · intro old
    apply StorageDelta.retry_idempotent
    intro entry member
    simp [write] at member
-- Concrete, satisfiable view/store interpretation exercising all three log
-- phases: discard 3/4 through snapshot 4, retain 5, replace 6 with suffix 6/7.
-- This is a component witness, not reachability from the node's genesis.
private def checkpointState : SharedSuffixStore Nat :=
  ⟨⟨fun _ => some (fun _ key =>
       if key = ["index"] then .unsigned "u64" 4 else .unsigned "u64" 1),
     fun _ => 3⟩,
   fun _ => 1, fun _ => 3⟩

theorem checkpoint_witness :
    ∃ view places,
      JarlView.state_State_write 64 checkpointState (some 6) true = .ok view ∧
      (JarlView.ready_Write_entries
        (sliceTraversal ["entries"] view.slice [some 5, some 6, some 7])).map
        (List.map (rebasePlace view.slice)) = .ok places ∧
      loadPlaces (loadFrom ["entries"] [some 5, some 6, some 7]) places = some [6,7] ∧
      StorageDelta.materialize view (some 4) [6,7] = some ⟨1, some 4, some 6, [6,7]⟩ ∧
      StorageDelta.apply (fun n : Nat => n) (fun n : Nat => n)
        (⟨0, some 2, [3,4,5,6]⟩ : StorageDelta.Durable Nat Nat Nat)
        ⟨1, some 4, some 6, [6,7]⟩ = ⟨1, some 4, [5,6,7]⟩ := by
  refine ⟨⟨1, some ["snapshot"], some 6, ⟨["entries"],1,3⟩,
    ["hard", "snapshot", "truncate_from", "entries"]⟩,
    [⟨["entries"],1⟩,⟨["entries"],2⟩], rfl, rfl, rfl, rfl, rfl⟩
end StorageView
