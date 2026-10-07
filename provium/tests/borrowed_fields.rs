//! Borrowed Option identities retain shared tickets through every dereference.
use std::{fs, path::PathBuf, process::Command};
struct Work(PathBuf);
impl Drop for Work {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
fn lean(work: &Work, file: &str, output: Option<&str>) -> std::process::Output {
    let mut command = Command::new("elan");
    command
        .args([
            "run",
            provium::project::TOOLCHAIN,
            "lean",
            "--trust=0",
            "--threads=1",
            "-DwarningAsError=true",
        ])
        .arg(format!(
            "--memory={}",
            provium::project::lean_memory_limit_mb().unwrap()
        ))
        .current_dir(&work.0)
        .env("LEAN_PATH", &work.0)
        .env_remove("LEAN_SRC_PATH");
    if let Some(output) = output {
        command.args(["-o", output]);
    }
    command.arg(file).output().unwrap()
}
#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn returned_references_retain_shared_authority_and_expire() {
    let w = Work(
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("artifacts")
            .join(format!("borrowed-fields-{}", std::process::id())),
    );
    fs::create_dir_all(w.0.join("Provium")).unwrap();
    let source = include_str!("../lean/Provium/FieldReads.lean");
    for (name, text) in [
        ("State", include_str!("../lean/Provium/State.lean")),
        ("Loans", include_str!("../lean/Provium/Loans.lean")),
        (
            "ScalarSource",
            include_str!("../lean/Provium/ScalarSource.lean"),
        ),
        ("FieldReads", source),
        ("Audit", include_str!("../lean/Provium/Audit.lean")),
    ] {
        let file = format!("Provium/{name}.lean");
        fs::write(w.0.join(&file), text).unwrap();
        let built = lean(&w, &file, Some(&format!("Provium/{name}.olean")));
        assert!(
            built.status.success(),
            "{}",
            String::from_utf8_lossy(&built.stdout)
        );
    }
    fs::write(w.0.join("Check.lean"), r#"import Provium.FieldReads
import Provium.Audit
open Provium.State
open Provium.State.FieldReads.Borrowed
def original : Loans.Loan := Loans.initial ⟨[], .exclusive⟩
def child : Loans.Loan := Loans.childLoan original ⟨[], .shared⟩ (by decide)
def nextChild : Loans.Loan := Loans.childLoan (Loans.advance original) ⟨[], .shared⟩ (by decide)
def world (loan : Loans.Loan) : Loans.World := Loans.set (fun _ => none) 0 (some loan)
def reference : Reference := ⟨0, 1, ["value"]⟩
def layout : Initialized.Layout := fun _ => some .optional
def heap : Initialized.Heap Nat := fun _ => some (.other 7)
theorem present_reference : read (world child) reference layout heap = .ok (some reference) := rfl
theorem absent_reference : read (world child) reference layout (α := Nat) (fun _ => some .absent) = .ok none := rfl
theorem reads_payload : dereference (world child) reference layout heap = .ok 7 := rfl
theorem read_twice : (dereference (world child) reference layout heap).bind
    (fun _ => dereference (world child) reference layout heap) = .ok 7 := rfl
theorem exclusive_not_shared : read (world original) ⟨0,0,["value"]⟩ layout heap = .error (.inl .denied) := rfl
theorem parent_still_suspended : ¬ Loans.Allowed (world child) 0 0 ⟨["value"], .exclusive⟩ := by decide
theorem same_ticket_cannot_write : ¬ Loans.Allowed (world child) 0 1 ⟨["value"], .exclusive⟩ := by decide
theorem returned_child_denied : dereference (world (Loans.advance original)) reference layout heap = .error (.inl .denied) := rfl
theorem sibling_does_not_revive : dereference (world nextChild) reference layout heap = .error (.inl .denied) := rfl
theorem lifetime_ended : dereference (fun _ => none) reference layout heap = .error (.inl .denied) := rfl
theorem uninitialized : read (world child) reference layout (α := Nat) (fun _ => none) = .error (.inr .uninitialized) := rfl
theorem invalid_place : read (world child) reference (fun _ => none) heap = .error (.inr .invalidPlace) := rfl
theorem wrong_kind : read (world child) reference (fun _ => some .boolean) heap = .error (.inr .wrongType) := rfl
theorem absent_not_dereferenceable : dereference (world child) reference layout (α := Nat) (fun _ => some .absent) = .error (.inr .wrongType) := rfl
#provium_check Provium.State.FieldReads.Borrowed.read_returns_live references Provium.State.FieldReads.Borrowed.read
#provium_check Provium.State.FieldReads.Borrowed.live_allowed references Provium.State.FieldReads.Borrowed.Live
#provium_check Provium.State.FieldReads.Borrowed.same_owner_cannot_write references Provium.State.FieldReads.Borrowed.Live
#provium_check Provium.State.FieldReads.Borrowed.other_owner_cannot_overlap references Provium.State.FieldReads.Borrowed.Live
#provium_check Provium.State.FieldReads.Borrowed.read_refines references Provium.State.FieldReads.Borrowed.read
#provium_check Provium.State.FieldReads.Borrowed.dereference_present references Provium.State.FieldReads.Borrowed.dereference
#provium_check Provium.State.FieldReads.Borrowed.ended_denied references Provium.State.FieldReads.Borrowed.dereference
#provium_check Provium.State.FieldReads.Borrowed.ended_not_revived references Provium.State.FieldReads.Borrowed.Live
#provium_check present_reference references Provium.State.FieldReads.Borrowed.read
#provium_check absent_reference references Provium.State.FieldReads.Borrowed.read
#provium_check reads_payload references Provium.State.FieldReads.Borrowed.dereference
#provium_check read_twice references Provium.State.FieldReads.Borrowed.dereference
#provium_check exclusive_not_shared references Provium.State.FieldReads.Borrowed.read
#provium_check parent_still_suspended references Provium.State.Loans.Allowed
#provium_check same_ticket_cannot_write references Provium.State.Loans.Allowed
#provium_check returned_child_denied references Provium.State.FieldReads.Borrowed.dereference
#provium_check sibling_does_not_revive references Provium.State.FieldReads.Borrowed.dereference
#provium_check lifetime_ended references Provium.State.FieldReads.Borrowed.dereference
#provium_check uninitialized references Provium.State.FieldReads.Borrowed.read
#provium_check invalid_place references Provium.State.FieldReads.Borrowed.read
#provium_check wrong_kind references Provium.State.FieldReads.Borrowed.read
#provium_check absent_not_dereferenceable references Provium.State.FieldReads.Borrowed.dereference
"#).unwrap();
    let checked = lean(&w, "Check.lean", None);
    assert!(
        checked.status.success(),
        "{}",
        String::from_utf8_lossy(&checked.stdout)
    );
    assert_eq!(
        String::from_utf8_lossy(&checked.stdout)
            .matches("PROVIUM_VERIFIED ")
            .count(),
        22
    );
    // Corruptions must fail either the generic theorem or the concrete controls.
    for (from, to) in [
        (
            "loan.active.mode = .shared ∧ loan.active.path",
            "True ∧ loan.active.path",
        ),
        ("reference.ticket = loan.stack.ticket ∧", "True ∧"),
        (
            "| .other _ => .ok (some reference)",
            "| .other _ => .ok none",
        ),
    ] {
        assert_eq!(source.matches(from).count(), 1);
        fs::write(
            w.0.join("Provium/FieldReads.lean"),
            source.replace(from, to),
        )
        .unwrap();
        let built = lean(
            &w,
            "Provium/FieldReads.lean",
            Some("Provium/FieldReads.olean"),
        );
        if built.status.success() {
            assert!(
                !lean(&w, "Check.lean", None).status.success(),
                "accepted {to}"
            );
        }
    }
}
