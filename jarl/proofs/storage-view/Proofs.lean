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
end StorageView
