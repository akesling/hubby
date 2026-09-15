import Generated
open Provium.State
namespace Persistence

theorem flags_cleared (state : Store α) :
    JarlMethods.ready_Ready_persisted state ["node", "dirty"] = .boolean false ∧
    JarlMethods.ready_Ready_persisted state ["node", "log_from"] = .absent ∧
    JarlMethods.ready_Ready_persisted state ["node", "snapshot_changed"] = .boolean false := by
  simp [JarlMethods.ready_Ready_persisted, put]

theorem other_fields_unchanged (state : Store α) (key : Path)
    (hd : key ≠ ["node", "dirty"])
    (hl : key ≠ ["node", "log_from"])
    (hs : key ≠ ["node", "snapshot_changed"]) :
    JarlMethods.ready_Ready_persisted state key = state key := by
  simp [JarlMethods.ready_Ready_persisted, put, hd, hl, hs]

-- Algebraic idempotence of the extracted effect, not permission to acknowledge
-- a consumed Ready token twice or to acknowledge storage that was never durable.
theorem idempotent (state : Store α) :
    JarlMethods.ready_Ready_persisted (JarlMethods.ready_Ready_persisted state) =
      JarlMethods.ready_Ready_persisted state := by
  funext key
  simp only [JarlMethods.ready_Ready_persisted, put]
  split <;> simp_all
end Persistence
