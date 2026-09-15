import Generated
open Provium.State
namespace Boundary

theorem without_snapshot (state : SelectionStore) (absent : state ["snapshot"] = none) :
    JarlBoundary.state_State_base state ["index"] = .unsigned "u64" 0 ∧
    JarlBoundary.state_State_base state ["term"] = .unsigned "u64" 0 := by
  simp [JarlBoundary.state_State_base, JarlBoundary.state_State_base_ir, selectRecord,
    absent, initializeFields, initialCell]

theorem snapshot_boundary (state : SelectionStore) (snapshot : Path → InitStore)
    (present : state ["snapshot"] = some snapshot) :
    JarlBoundary.state_State_base state = snapshot ["last"] := by
  simp [JarlBoundary.state_State_base, JarlBoundary.state_State_base_ir, selectRecord, present]
theorem lookup_exact (bits base offset : Nat) (state : LookupStore α) (value : α)
    (base_value : JarlBoundary.state_State_base state.records ["index"] = .unsigned "u64" base)
    (valid : base + 1 + offset < 2^64) (target : offset < 2^bits)
    (present : (state.slots ["entries"])[offset]? = some (some value)) :
    JarlBoundary.state_State_get bits state (base + 1 + offset) =
      .ok (some ⟨["entries"], offset⟩) := by
  have selected : selectRecord JarlBoundary.state_State_get_ir.base state.records
      JarlBoundary.state_State_get_ir.baseField = .unsigned "u64" base := base_value
  have hi : ¬ base + 1 + offset ≥ 2^64 := by omega
  have hb : ¬ base ≥ 2^64 := by omega
  have before : ¬ base + 1 + offset < base := by omega
  have bias : ¬ base + 1 + offset - base < 1 := by omega
  have position : base + 1 + offset - base - 1 = offset := by omega
  have word : ¬ offset ≥ 2^bits := by omega
  simp only [JarlBoundary.state_State_get, lookupRecord, selected]
  simp [JarlBoundary.state_State_get_ir, hi, hb, before, bias, position, word, present]

theorem lookup_at_or_before_boundary (bits base index : Nat) (state : LookupStore α)
    (base_value : JarlBoundary.state_State_base state.records ["index"] = .unsigned "u64" base)
    (valid : base < 2^64) (before : index ≤ base) :
    JarlBoundary.state_State_get bits state index = .ok none := by
  have selected : selectRecord JarlBoundary.state_State_get_ir.base state.records
      JarlBoundary.state_State_get_ir.baseField = .unsigned "u64" base := base_value
  have hi : ¬ index ≥ 2^64 := by omega
  have hb : ¬ base ≥ 2^64 := by omega
  simp only [JarlBoundary.state_State_get, lookupRecord, selected]
  by_cases less : index < base
  · simp [JarlBoundary.state_State_get_ir, hi, hb, less]
  · have same : index = base := by omega
    subst index
    simp [JarlBoundary.state_State_get_ir, hb]
theorem lookup_all_offsets (bits base offset : Nat) (state : LookupStore α)
    (base_value : JarlBoundary.state_State_base state.records ["index"] = .unsigned "u64" base)
    (valid : base + 1 + offset < 2^64) :
    JarlBoundary.state_State_get bits state (base + 1 + offset) =
      .ok (if offset < 2^bits then
        match (state.slots ["entries"])[offset]? with
        | some (some _) => some ⟨["entries"], offset⟩
        | _ => none
      else none) := by
  have selected : selectRecord JarlBoundary.state_State_get_ir.base state.records
      JarlBoundary.state_State_get_ir.baseField = .unsigned "u64" base := base_value
  have hi : ¬ base + 1 + offset ≥ 2^64 := by omega
  have hb : ¬ base ≥ 2^64 := by omega
  have before : ¬ base + 1 + offset < base := by omega
  have bias : ¬ base + 1 + offset - base < 1 := by omega
  have position : base + 1 + offset - base - 1 = offset := by omega
  simp only [JarlBoundary.state_State_get, lookupRecord, selected]
  by_cases target : offset < 2^bits
  · have word : ¬ offset ≥ 2^bits := by omega
    cases slot : (state.slots ["entries"])[offset]? with
    | none => simp [JarlBoundary.state_State_get_ir, hi, hb, before, bias, position, target, word, slot]
    | some value => cases value <;> simp [JarlBoundary.state_State_get_ir, hi, hb, before, bias, position, target, word, slot]
  · have word : offset ≥ 2^bits := by omega
    simp [JarlBoundary.state_State_get_ir, hi, hb, before, bias, position, target, word]
theorem record_at_snapshot (bits base : Nat) (state : LookupStore (Path → InitStore))
    (base_value : JarlBoundary.state_State_base state.records ["index"] = .unsigned "u64" base)
    (valid : base < 2^64) :
    JarlBoundary.state_State_id_at bits state base =
      .ok (some (JarlBoundary.state_State_base state.records)) := by
  have selected : selectRecord JarlBoundary.state_State_id_at_ir.lookup.base state.records
      JarlBoundary.state_State_id_at_ir.guardField = .unsigned "u64" base := base_value
  have hb : ¬ base ≥ 2^64 := by omega
  simp only [JarlBoundary.state_State_id_at, recordAt, selected]
  simp [JarlBoundary.state_State_id_at_ir, JarlBoundary.state_State_base,
    JarlBoundary.state_State_base_ir, hb]

theorem record_at_entry (bits base offset : Nat) (state : LookupStore (Path → InitStore))
    (entry : Path → InitStore)
    (base_value : JarlBoundary.state_State_base state.records ["index"] = .unsigned "u64" base)
    (valid : base + 1 + offset < 2^64) (target : offset < 2^bits)
    (present : (state.slots ["entries"])[offset]? = some (some entry)) :
    JarlBoundary.state_State_id_at bits state (base + 1 + offset) = .ok (some (entry ["id"])) := by
  have selected : selectRecord JarlBoundary.state_State_id_at_ir.lookup.base state.records
      JarlBoundary.state_State_id_at_ir.guardField = .unsigned "u64" base := base_value
  have looked : lookupRecord JarlBoundary.state_State_id_at_ir.lookup bits state (base + 1 + offset) =
      .ok (some ⟨["entries"], offset⟩) := lookup_exact bits base offset state entry base_value valid target present
  have hi : ¬ base + 1 + offset ≥ 2^64 := by omega
  have hb : ¬ base ≥ 2^64 := by omega
  have different : base + 1 + offset ≠ base := by omega
  simp only [JarlBoundary.state_State_id_at, recordAt, selected]
  simp [JarlBoundary.state_State_id_at_ir, hi, hb, different] at looked ⊢
  rw [looked]
  simp [present]
theorem record_at_absent (bits base index : Nat) (state : LookupStore (Path → InitStore))
    (base_value : JarlBoundary.state_State_base state.records ["index"] = .unsigned "u64" base)
    (valid_base : base < 2^64) (valid_index : index < 2^64) (different : index ≠ base)
    (missing : JarlBoundary.state_State_get bits state index = .ok none) :
    JarlBoundary.state_State_id_at bits state index = .ok none := by
  have selected : selectRecord JarlBoundary.state_State_id_at_ir.lookup.base state.records
      JarlBoundary.state_State_id_at_ir.guardField = .unsigned "u64" base := base_value
  have looked : lookupRecord JarlBoundary.state_State_id_at_ir.lookup bits state index = .ok none := missing
  have hi : ¬ index ≥ 2^64 := by omega
  have hb : ¬ base ≥ 2^64 := by omega
  simp only [JarlBoundary.state_State_id_at, recordAt, selected]
  simp [JarlBoundary.state_State_id_at_ir, hi, hb, different] at looked ⊢
  simp [looked]
end Boundary
