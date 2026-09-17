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
-- Logical loan admission for the complete source-derived acknowledgment body.
-- The caller must still establish that Ready owns this loan and that storage
-- completed durably; neither fact follows from these field effects.
theorem loan_checked_acknowledgment (world : Loans.World) (owner : Nat)
    (loan : Loans.Loan) (present : world owner = some loan)
    (active : loan.active = ⟨["node"], .exclusive⟩)
    (heap : Initialized.Heap α) (state : Store α)
    (related : Initialized.Relates JarlMethods.ready_Ready_persisted_layout heap state) :
    ∃ result,
      Loans.execute world owner loan.stack.ticket JarlMethods.ready_Ready_persisted_layout
        JarlMethods.ready_Ready_persisted_ir heap = .ok result ∧
      Initialized.Relates JarlMethods.ready_Ready_persisted_layout result
        (JarlMethods.ready_Ready_persisted state) ∧
      result ["node", "dirty"] = some (.boolean false) ∧
      result ["node", "log_from"] = some .absent ∧
      result ["node", "snapshot_changed"] = some (.boolean false) := by
  have allowed : Loans.ProgramAllowed world owner loan.stack.ticket JarlMethods.ready_Ready_persisted_ir := by
    simp [Loans.ProgramAllowed, Loans.Allowed, present, active, Loans.Nested,
      JarlMethods.ready_Ready_persisted_ir]
  obtain ⟨result, completed, finalRelated⟩ :=
    JarlMethods.ready_Ready_persisted_loan_refinement world owner loan.stack.ticket heap state related allowed
  refine ⟨result, completed, finalRelated, ?_, ?_, ?_⟩
  · have field := (finalRelated ["node", "dirty"] .boolean
      (by simp [JarlMethods.ready_Ready_persisted_layout])).1
    simpa [JarlMethods.ready_Ready_persisted, put] using field
  · have field := (finalRelated ["node", "log_from"] .optional
      (by simp [JarlMethods.ready_Ready_persisted_layout])).1
    simpa [JarlMethods.ready_Ready_persisted, put] using field
  · have field := (finalRelated ["node", "snapshot_changed"] .boolean
      (by simp [JarlMethods.ready_Ready_persisted_layout])).1
    simpa [JarlMethods.ready_Ready_persisted, put] using field

theorem loan_preserves_other_borrow (world : Loans.World)
    (owner ticket otherOwner otherTicket : Nat) (state : Store α) (path : Path)
    (valid : Loans.Valid world) (different : owner ≠ otherOwner)
    (allowed : Loans.ProgramAllowed world owner ticket JarlMethods.ready_Ready_persisted_ir)
    (other : Loans.Allowed world otherOwner otherTicket ⟨path, .shared⟩) :
    JarlMethods.ready_Ready_persisted state path = state path := by
  rw [← JarlMethods.ready_Ready_persisted_correspondence]
  exact Loans.execute_other_loan_frame valid different allowed other

end Persistence
