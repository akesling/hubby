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
end Boundary
