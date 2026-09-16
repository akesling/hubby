import Generated
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
end StorageView
