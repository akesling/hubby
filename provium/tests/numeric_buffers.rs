//! Indexed-buffer refinement and evaluation-order negative controls.
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
fn kernel_indexed_buffer_refines_collection_and_rejects_wrong_writes() {
    let w = Work(
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("artifacts")
            .join(format!("numeric-buffers-{}", std::process::id())),
    );
    fs::create_dir_all(w.0.join("Provium")).unwrap();
    let source = include_str!("../lean/Provium/NumericFolds.lean");
    for (file, contents) in [
        ("State", include_str!("../lean/Provium/State.lean")),
        (
            "OrderStatistics",
            include_str!("../lean/Provium/OrderStatistics.lean"),
        ),
        ("NumericFolds", source),
        ("Audit", include_str!("../lean/Provium/Audit.lean")),
    ] {
        let path = format!("Provium/{file}.lean");
        fs::write(w.0.join(&path), contents).unwrap();
        let result = lean(&w, &path, Some(&format!("Provium/{file}.olean")));
        assert!(
            result.status.success(),
            "{}{}",
            String::from_utf8_lossy(&result.stdout),
            String::from_utf8_lossy(&result.stderr)
        );
    }
    fs::write(w.0.join("Check.lean"),r#"import Provium.NumericFolds
import Provium.Audit
open Provium.State
 def done (buffer:List UInt64) (count:Nat) (state:Nat):CallbackRun Nat Nat UInt64 UInt64 := finishCallback state (.value (UInt64.ofNat (buffer.length+count)))
 theorem callback_before_bounds :
   observeCallback 3 (fun (_:Cell Nat) (state:Nat)=>.value (9:UInt64) (state+1)) (fun _=>.returned)
     (fillNumericCallbacks [.other 7] 0 [] 0 false done) =
       some (.unwind,[.called (.other 7) 0 (.value 9 1),.dropped 1 .returned]) := rfl
 theorem bounds_abort :
   observeCallback 2 (fun (_:Cell Nat) (state:Nat)=>.value (9:UInt64) (state+1)) (fun _=>.returned)
     (fillNumericCallbacks [.other 7] 0 [] 0 true done) =
       some (.abort,[.called (.other 7) 0 (.value 9 1)]) := rfl
 theorem writes : writeNumeric [99,98,97,96] 1 [4,5] = [99,4,5,96] := rfl
 theorem reset_overwrites : writeNumeric (writeNumeric [0,0,0] 0 [9,8,7]) 0 [1,2] = [1,2,7] := rfl
#provium_check Provium.State.writeNumeric_length references Provium.State.writeNumeric
#provium_check Provium.State.writeNumeric_contents references Provium.State.writeNumeric
#provium_check Provium.State.writeNumeric_prefix references Provium.State.writeNumeric
#provium_check Provium.State.fillNumericCallbacks_refines references Provium.State.fillNumericCallbacks
#provium_check Provium.State.fillNumericCallbacks_prefix references Provium.State.fillNumericCallbacks
#provium_check Provium.State.runNumericFold_refines references Provium.State.runNumericFold
#provium_check callback_before_bounds references Provium.State.fillNumericCallbacks
#provium_check bounds_abort references Provium.State.fillNumericCallbacks
#provium_check writes references Provium.State.writeNumeric
#provium_check reset_overwrites references Provium.State.writeNumeric
"#).unwrap();
    let result = lean(&w, "Check.lean", None);
    assert!(
        result.status.success(),
        "{}{}",
        String::from_utf8_lossy(&result.stdout),
        String::from_utf8_lossy(&result.stderr)
    );
    for (from, to) in [
        (
            "fillNumericCallbacks rest advanced (buffer.set count answer) (count + 1)",
            "fillNumericCallbacks rest advanced (buffer.set (count + 1) answer) (count + 1)",
        ),
        (
            "fillNumericCallbacks rest advanced (buffer.set count answer) (count + 1)",
            "fillNumericCallbacks rest advanced (buffer.set count answer) (count + 2)",
        ),
        (
            "| [] => next buffer count callback",
            "| [] => next buffer 0 callback",
        ),
        (
            "writeNumeric (buffer.set count value)",
            "writeNumeric (buffer.set (count + 1) value)",
        ),
    ] {
        assert!(source.contains(from));
        fs::write(
            w.0.join("Provium/NumericFolds.lean"),
            source.replace(from, to),
        )
        .unwrap();
        let result = lean(&w, "Provium/NumericFolds.lean", None);
        assert!(!result.status.success(), "accepted {from} -> {to}");
        let diagnostic = String::from_utf8_lossy(&result.stdout);
        assert!(diagnostic.contains("error:"), "{diagnostic}");
        assert!(!diagnostic.contains("unexpected token"), "{diagnostic}");
    }
}
