//! Loan reservations, scoped reborrows and ownership admission negative controls.
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
fn loan_machine_checks_exclusion_restoration_and_denials() {
    let w = Work(
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("artifacts")
            .join(format!("loans-{}", std::process::id())),
    );
    fs::create_dir_all(w.0.join("Provium")).unwrap();
    let source = include_str!("../lean/Provium/Loans.lean");
    for (file, contents) in [
        ("State", include_str!("../lean/Provium/State.lean")),
        ("Loans", source),
        ("Audit", include_str!("../lean/Provium/Audit.lean")),
    ] {
        let path = format!("Provium/{file}.lean");
        fs::write(w.0.join(&path), contents).unwrap();
        let result = lean(&w, &path, Some(&format!("Provium/{file}.olean")));
        assert!(
            result.status.success(),
            "{}",
            String::from_utf8_lossy(&result.stdout)
        );
    }
    fs::write(
        w.0.join("Check.lean"),
        r#"import Provium.Loans
import Provium.Audit
open Provium.State
open Provium.State.Loans

def original : Loan := initial ⟨[], .exclusive⟩
def borrowed : Loan := childLoan original ⟨["field"], .shared⟩ (by decide)

theorem return_child : endBorrow borrowed 1 = .ok (advance original) := rfl
theorem reject_root_return : endBorrow original 0 = .error .rootRelease := rfl
theorem reject_upgrade : reborrow borrowed 1 ⟨["field"], .exclusive⟩ = .error .denied := rfl
theorem reject_escape : reborrow borrowed 1 ⟨["sibling"], .shared⟩ = .error .denied := rfl
theorem reject_shared_write : Loans.execute (α := Unit)
    (Loans.set (fun _ => none) 0 (some borrowed)) 0 1 (fun _ => some .boolean)
    (.write ⟨["field"], .boolean false⟩) (fun _ => some (.boolean true)) =
      .error (.inl .denied) := rfl

def start : Arena := Arena.empty.reserve ⟨[], .exclusive⟩
  (by intro j other impossible; cases impossible)
def firstChild : Except Fault Arena := start.reborrow 0 0 ⟨["field"], .shared⟩
def returned : Except Fault Arena := firstChild.bind (fun arena => arena.endBorrow 0 1)
def secondChild : Except Fault Arena := returned.bind (fun arena => arena.reborrow 0 0 ⟨["field"], .shared⟩)
def permits (result : Except Fault Arena) (owner ticket : Nat) : Bool :=
  match result with
  | .error _ => false
  | .ok arena => decide (Allowed arena.world owner ticket ⟨["field"], .shared⟩)
def failed (result : Except Fault Arena) : Option Fault :=
  match result with
  | .error fault => some fault
  | .ok _ => none

theorem parent_suspended : permits firstChild 0 0 = false := rfl
theorem child_active : permits firstChild 0 1 = true := rfl
theorem parent_restored : permits returned 0 0 = true := rfl
theorem returned_child_inactive : permits returned 0 1 = false := rfl
theorem old_sibling_inactive : permits secondChild 0 1 = false := rfl
theorem new_sibling_active : permits secondChild 0 2 = true := rfl
theorem parent_cannot_return_child :
    failed (firstChild.bind (fun arena => arena.endBorrow 0 0)) = some .denied := rfl
theorem lifetime_cannot_end_with_child :
    failed (firstChild.bind (fun arena => arena.endLifetime 0 1)) = some .denied := rfl
def retired : Arena := start.invalidate 0
def replacement : Arena := retired.reserve ⟨[], .exclusive⟩
  (by intro j other present; simp [retired, start, Arena.invalidate, Arena.reserve, Arena.empty, Loans.set] at present
      exact False.elim (present.1 present.2.1))
theorem old_root_inactive : permits (.ok replacement) 0 0 = false := rfl
theorem replacement_root_active : permits (.ok replacement) 1 0 = true := rfl

#provium_check parent_suspended references permits
#provium_check child_active references permits
#provium_check parent_restored references permits
#provium_check returned_child_inactive references permits
#provium_check old_sibling_inactive references permits
#provium_check new_sibling_active references permits
#provium_check parent_cannot_return_child references failed
#provium_check lifetime_cannot_end_with_child references failed
#provium_check old_root_inactive references permits
#provium_check replacement_root_active references permits
#provium_check Provium.State.Loans.nested_trans references Provium.State.Loans.Nested
#provium_check Provium.State.Loans.Stack.nested references Provium.State.Loans.Nested
#provium_check Provium.State.Loans.reborrow_restores references Provium.State.Loans.reborrow
#provium_check Provium.State.Loans.reborrow_reserves references Provium.State.Loans.reborrow
#provium_check Provium.State.Loans.endBorrow_reserves references Provium.State.Loans.endBorrow
#provium_check Provium.State.Loans.acquire_valid references Provium.State.Loans.Valid
#provium_check Provium.State.Loans.replace_valid references Provium.State.Loans.Valid
#provium_check Provium.State.Loans.release_valid references Provium.State.Loans.Valid
#provium_check Provium.State.Loans.reborrow_rejects_old_ticket references Provium.State.Loans.Allowed
#provium_check Provium.State.Loans.reborrow_suspends_parent references Provium.State.Loans.Allowed
#provium_check Provium.State.Loans.allowed_root references Provium.State.Loans.Allowed
#provium_check Provium.State.Loans.exclusive_excludes references Provium.State.Loans.Allowed
#provium_check Provium.State.Loans.writes_allowed references Provium.State.Loans.Allowed
#provium_check Provium.State.Loans.other_loan_untouched references Provium.State.Loans.ProgramAllowed
#provium_check Provium.State.Loans.execute_other_loan_frame references Provium.State.execute
#provium_check Provium.State.Loans.execute_refines references Provium.State.Loans.execute
#provium_check Provium.State.Loans.Arena.fresh references Provium.State.Loans.Arena.world
#provium_check Provium.State.Loans.Arena.reserve_next references Provium.State.Loans.Arena.reserve
#provium_check Provium.State.Loans.Arena.invalidate_next references Provium.State.Loans.Arena.invalidate
#provium_check Provium.State.Loans.Arena.retired_not_revived references Provium.State.Loans.Arena.reserve
#provium_check return_child references Provium.State.Loans.endBorrow
#provium_check reject_root_return references Provium.State.Loans.endBorrow
#provium_check reject_upgrade references Provium.State.Loans.reborrow
#provium_check reject_escape references Provium.State.Loans.reborrow
#provium_check reject_shared_write references Provium.State.Loans.execute
"#,
    )
    .unwrap();
    let result = lean(&w, "Check.lean", None);
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stdout)
    );
    assert_eq!(
        String::from_utf8_lossy(&result.stdout)
            .matches("PROVIUM_VERIFIED ")
            .count(),
        35
    );
    for (original, changed) in [
        (
            "childLoan loan child within)\n    else .error .denied",
            "childLoan loan child within)\n    else .error .missing",
        ),
        (
            ".root _, _, _⟩ => .error .rootRelease",
            ".root _, _, _⟩ => .error .missing",
        ),
        ("else .error (.inl .denied)", "else .error (.inl .missing)"),
    ] {
        assert_eq!(source.matches(original).count(), 1);
        fs::write(
            w.0.join("Provium/Loans.lean"),
            source.replace(original, changed),
        )
        .unwrap();
        let compiled = lean(&w, "Provium/Loans.lean", Some("Provium/Loans.olean"));
        assert!(
            compiled.status.success(),
            "{}",
            String::from_utf8_lossy(&compiled.stdout)
        );
        let rejected = lean(&w, "Check.lean", None);
        assert!(
            !rejected.status.success(),
            "accepted changed loan failure semantics: {changed}"
        );
        assert!(String::from_utf8_lossy(&rejected.stdout).contains("error:"));
    }
}
