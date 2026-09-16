//! Kernel tests for the callback protocol; no Rust-to-IR claim is made here.
use std::{fs, path::PathBuf, process::Command};
struct Work(PathBuf);
impl Drop for Work {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn kernel_predicate_calls_preserve_state_order_cleanup_and_panic_paths() {
    let w = Work(
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("artifacts")
            .join(format!("predicate-runs-{}", std::process::id())),
    );
    fs::create_dir_all(w.0.join("Provium")).unwrap();
    fs::write(
        w.0.join("Provium/State.lean"),
        include_str!("../lean/Provium/State.lean"),
    )
    .unwrap();
    fs::write(
        w.0.join("Provium/Audit.lean"),
        include_str!("../lean/Provium/Audit.lean"),
    )
    .unwrap();
    let proof = r#"import Provium.State
import Provium.Audit
open Provium.State
namespace Check
 def row (key:Nat) (current old:Bool):Store Nat := fun field=>
   if field=["key"] then .other key else if field=["current"] then .boolean current
   else if field=["old"] then .boolean old else .absent
 def entries:ArrayStore Nat := [some (row 1 true false),some (row 2 true true),some (row 3 false true)]
 def program:PredicateFold := {
   first:=⟨.field ["current"],["key"]⟩
   second:=⟨.field ["old"],["key"]⟩
   secondRequired:=.field ["old"]
   divisor:=2
   divisorPositive:=(by decide)
   inclusive:=false }
 def stateful (_:Cell Nat) (state:Nat):PredicateReply Nat := .value (state<2) (state+1)
 def panicSecond (_:Cell Nat) (state:Nat):PredicateReply Nat := if state=1 then .unwind 2 else .value true (state+1)
 theorem ordered:
   observePredicate 6 stateful (fun _=>.returned) (runPredicateFold program entries 0) =
   some (.value false,[.called (.other 1) 0 (.value true 1),.called (.other 2) 1 (.value true 2),
     .called (.other 2) 2 (.value false 3),.called (.other 3) 3 (.value false 4),.dropped 4 .returned]) := rfl
 theorem failed_first:
   observePredicate 4 (fun _ n=>.value false (n+1)) (fun _=>.returned) (runPredicateFold program entries 0) =
   some (.value false,[.called (.other 1) 0 (.value false 1),.called (.other 2) 1 (.value false 2),.dropped 2 .returned]) := rfl
 theorem stable:
   observePredicate 4 stateful (fun _=>.returned)
     (runPredicateFold program [some (row 1 true false),some (row 2 true false)] 0) =
   some (.value true,[.called (.other 1) 0 (.value true 1),.called (.other 2) 1 (.value true 2),.dropped 2 .returned]) := rfl
 theorem unwind:
   observePredicate 4 panicSecond (fun _=>.returned) (runPredicateFold program entries 0) =
   some (.unwind,[.called (.other 1) 0 (.value true 1),.called (.other 2) 1 (.unwind 2),.dropped 2 .returned]) := rfl
 theorem double_panic:
   observePredicate 4 panicSecond (fun _=>.unwind) (runPredicateFold program entries 0) =
   some (.abort,[.called (.other 1) 0 (.value true 1),.called (.other 2) 1 (.unwind 2),.dropped 2 .unwind]) := rfl
 theorem drop_panic:
   observePredicate 4 stateful (fun _=>.unwind)
     (runPredicateFold program [some (row 1 true false),some (row 2 true false)] 0) =
   some (.unwind,[.called (.other 1) 0 (.value true 1),.called (.other 2) 1 (.value true 2),.dropped 2 .unwind]) := rfl
 theorem abort_skips_drop:
   observePredicate 3 (fun _ n=>if n=1 then .abort else .value true (n+1)) (fun _=>.returned)
     (runPredicateFold program entries 0) =
   some (.abort,[.called (.other 1) 0 (.value true 1),.called (.other 2) 1 .abort]) := rfl
 theorem empty : observePredicate 2 stateful (fun _=>.returned) (runPredicateFold program [] 0) =
   some (.value false,[.dropped 0 .returned]) := rfl
 theorem finish_abort : (finishPredicate (0:Nat) .abort : PredicateRun Nat Nat) = .returned .abort := rfl
 theorem no_fabricated_completion:
   observePredicate 3 stateful (fun _=>.returned) (runPredicateFold program entries 0) = none := rfl
 theorem bounded (plan:PredicateFold) (entries:ArrayStore α) (callback:σ) :
   predicateBudget ((projectArray plan.first entries).length + (projectArray plan.second entries).length + 2)
     (runPredicateFold plan entries callback) := predicate_fold_budget plan entries callback
 theorem complete (plan:PredicateFold) (entries:ArrayStore α) (callback:σ)
   (call:Cell α→σ→PredicateReply σ) (drop:σ→PredicateDropReply) :
   ∃ outcome, observePredicate ((projectArray plan.first entries).length + (projectArray plan.second entries).length + 2)
     call drop (runPredicateFold plan entries callback) = some outcome :=
   predicate_observation_complete _ _ (predicate_fold_budget plan entries callback) call drop
end Check
#provium_check Check.empty references Provium.State.runPredicateFold
#provium_check Check.finish_abort references Provium.State.finishPredicate
#provium_check Check.bounded references Provium.State.runPredicateFold
#provium_check Check.complete references Provium.State.runPredicateFold
#provium_check Check.ordered references Provium.State.runPredicateFold
#provium_check Check.failed_first references Provium.State.runPredicateFold
#provium_check Check.stable references Provium.State.runPredicateFold
#provium_check Check.unwind references Provium.State.runPredicateFold
#provium_check Check.double_panic references Provium.State.runPredicateFold
#provium_check Check.drop_panic references Provium.State.runPredicateFold
#provium_check Check.abort_skips_drop references Provium.State.runPredicateFold
#provium_check Check.no_fabricated_completion references Provium.State.runPredicateFold
"#;
    fs::write(w.0.join("Check.lean"), proof).unwrap();
    for args in [
        vec!["-o", "Provium/State.olean", "Provium/State.lean"],
        vec!["-o", "Provium/Audit.olean", "Provium/Audit.lean"],
        vec!["Check.lean"],
    ] {
        let result = Command::new("elan")
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
            .args(args)
            .current_dir(&w.0)
            .env("LEAN_PATH", &w.0)
            .env_remove("LEAN_SRC_PATH")
            .output()
            .unwrap();
        assert!(
            result.status.success(),
            "{}{}",
            String::from_utf8_lossy(&result.stdout),
            String::from_utf8_lossy(&result.stderr)
        );
    }
    fs::write(
        w.0.join("Bad.lean"),
        r#"import Provium.State
open Provium.State
 theorem skipped_drop : observePredicate 1 (fun (_:Cell Nat) n=>.value true n) (fun _=>.returned)
   (finishPredicate (0:Nat) (.value true)) = some (.value true,[]) := rfl
"#,
    )
    .unwrap();
    let rejected = Command::new("elan")
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
        .arg("Bad.lean")
        .current_dir(&w.0)
        .env("LEAN_PATH", &w.0)
        .env_remove("LEAN_SRC_PATH")
        .output()
        .unwrap();
    assert!(!rejected.status.success());
    let message = format!(
        "{}{}",
        String::from_utf8_lossy(&rejected.stdout),
        String::from_utf8_lossy(&rejected.stderr)
    );
    assert!(message.contains("Not a definitional equality"), "{message}");
}
