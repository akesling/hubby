//! Ownership admission and initialized Option::take traversal controls.
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
fn optional_slot_moves_preserve_initialization_and_require_exclusive_access() {
    let w = Work(
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("artifacts")
            .join(format!("array-moves-{}", std::process::id())),
    );
    fs::create_dir_all(w.0.join("Provium")).unwrap();
    let source = include_str!("../lean/Provium/ArrayMoves.lean");
    for (name, text) in [
        ("State", include_str!("../lean/Provium/State.lean")),
        ("Loans", include_str!("../lean/Provium/Loans.lean")),
        ("ArrayMoves", source),
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
    fs::write(w.0.join("Check.lean"), r#"import Provium.ArrayMoves
import Provium.Audit
open Provium.State
open Provium.State.ArrayMoves
def owned : Loans.World := fun i => if i = 0 then some (Loans.initial ⟨["slots"], .exclusive⟩) else none
def shared : Loans.World := fun i => if i = 0 then some (Loans.initial ⟨["slots"], .shared⟩) else none
theorem takes_present_and_absent : run false 2 0 3 [some (some 7), some none, some (some 9)] =
    .done [some 7, none, none] [some none, some none, some (some 9)] := rfl
theorem no_access_beyond_length : ArrayMoves.run (α := Nat) false 0 0 2 [none] =
    .done [none, none] [none] := rfl
theorem uninitialized_preserves_partial_state : run false 3 0 2 [some (some 7), none, some none] =
    .uninitialized 1 [some 7] [some none, none, some none] := rfl
theorem bounds_preserves_partial_state : run false 3 0 2 [some (some 7)] =
    .bounds 1 [some 7] [some none] := rfl
theorem exclusive_admitted : move owned 0 0 ["slots"] false 1 0 1 [some (some 7)] =
    .ok (.done [some 7] [some none]) := rfl
theorem shared_denied : move shared 0 0 ["slots"] false 1 0 1 [some (some 7)] =
    .error .denied := rfl
theorem stale_ticket_denied : move owned 0 1 ["slots"] false 1 0 1 [some (some 7)] =
    .error .denied := rfl
theorem wrong_region_denied : move owned 0 0 ["other"] false 1 0 1 [some (some 7)] =
    .error .denied := rfl
#provium_check Provium.State.ArrayMoves.run_refines references Provium.State.ArrayMoves.run
#provium_check Provium.State.ArrayMoves.move_refines references Provium.State.ArrayMoves.move
#provium_check Provium.State.ArrayMoves.excludes_other_access references Provium.State.Loans.Allowed
#provium_check takes_present_and_absent references Provium.State.ArrayMoves.run
#provium_check no_access_beyond_length references Provium.State.ArrayMoves.run
#provium_check uninitialized_preserves_partial_state references Provium.State.ArrayMoves.run
#provium_check bounds_preserves_partial_state references Provium.State.ArrayMoves.run
#provium_check exclusive_admitted references Provium.State.ArrayMoves.move
#provium_check shared_denied references Provium.State.ArrayMoves.move
#provium_check stale_ticket_denied references Provium.State.ArrayMoves.move
#provium_check wrong_region_denied references Provium.State.ArrayMoves.move
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
        11
    );
    for (from, to) in [
        ("else .error .denied", "else .error .missing"),
        (
            "| none :: rest => .uninitialized index [] (none :: rest)",
            "| none :: rest => .bounds index [] (none :: rest)",
        ),
    ] {
        assert_eq!(source.matches(from).count(), 1);
        fs::write(
            w.0.join("Provium/ArrayMoves.lean"),
            source.replace(from, to),
        )
        .unwrap();
        let built = lean(
            &w,
            "Provium/ArrayMoves.lean",
            Some("Provium/ArrayMoves.olean"),
        );
        assert!(
            built.status.success(),
            "{}",
            String::from_utf8_lossy(&built.stdout)
        );
        let rejected = lean(&w, "Check.lean", None);
        assert!(!rejected.status.success(), "accepted {to}");
        assert!(String::from_utf8_lossy(&rejected.stdout).contains("error:"));
    }
}
