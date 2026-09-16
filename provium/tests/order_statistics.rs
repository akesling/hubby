//! Unbounded logical rank contracts, separate from Rust sorting refinement.
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
fn kernel_rank_threshold_is_exact_for_arbitrary_lists_and_rejects_rank_mutation() {
    let work = Work(
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("artifacts")
            .join(format!("order-statistics-{}", std::process::id())),
    );
    fs::create_dir_all(work.0.join("Provium")).unwrap();
    let source = include_str!("../lean/Provium/OrderStatistics.lean");
    fs::write(work.0.join("Provium/OrderStatistics.lean"), source).unwrap();
    fs::write(
        work.0.join("Provium/Audit.lean"),
        include_str!("../lean/Provium/Audit.lean"),
    )
    .unwrap();
    fs::write(
        work.0.join("Check.lean"),
        r#"import Provium.OrderStatistics
import Provium.Audit
open Provium.OrderStatistics
 theorem even : rank [9,2,8,4] 2 = some 4 := by apply rank_eq_of_counts _ _ _ (by decide) <;> decide
 theorem odd : rank [9,2,8] 2 = some 8 := by apply rank_eq_of_counts _ _ _ (by decide) <;> decide
 theorem ties : rank [7,7,1,7] 2 = some 7 := by apply rank_eq_of_counts _ _ _ (by decide) <;> decide
 theorem zero : rank [0,0] 2 = some 0 := by apply rank_eq_of_counts _ _ _ (by decide) <;> decide
 theorem singleton : rank [18446744073709551615] 2 = some 18446744073709551615 := by apply rank_eq_of_counts _ _ _ (by decide) <;> decide
 theorem empty : rank [] 2 = none := rfl
#provium_check Provium.OrderStatistics.sort_length references Provium.OrderStatistics.sort
#provium_check Provium.OrderStatistics.sort_permutation references Provium.OrderStatistics.sort
#provium_check Provium.OrderStatistics.sort_ordered references Provium.OrderStatistics.sort
#provium_check Provium.OrderStatistics.rank_exists references Provium.OrderStatistics.rank
#provium_check Provium.OrderStatistics.rank_threshold references Provium.OrderStatistics.rank
#provium_check Provium.OrderStatistics.rank_member references Provium.OrderStatistics.rank
#provium_check Provium.OrderStatistics.rank_none_iff references Provium.OrderStatistics.rank
#provium_check Provium.OrderStatistics.rank_supported references Provium.OrderStatistics.rank
#provium_check Provium.OrderStatistics.rank_larger_rejected references Provium.OrderStatistics.rank
#provium_check Provium.OrderStatistics.rank_bound references Provium.OrderStatistics.rank
#provium_check Provium.OrderStatistics.rank_permutation references Provium.OrderStatistics.rank
#provium_check Provium.OrderStatistics.rank_eq_of_counts references Provium.OrderStatistics.rank
#provium_check Provium.OrderStatistics.rank_arithmetic_bounds references Provium.OrderStatistics.rankOffset
#provium_check Provium.OrderStatistics.empty_wrapping_index references Provium.OrderStatistics.wrappingRankOffset
#provium_check Provium.OrderStatistics.empty_wrapping_out_of_bounds references Provium.OrderStatistics.wrappingRankOffset
#provium_check even references Provium.OrderStatistics.rank
#provium_check odd references Provium.OrderStatistics.rank
#provium_check ties references Provium.OrderStatistics.rank
#provium_check zero references Provium.OrderStatistics.rank
#provium_check singleton references Provium.OrderStatistics.rank
#provium_check empty references Provium.OrderStatistics.rank
"#,
    )
    .unwrap();
    for (file, output) in [
        (
            "Provium/OrderStatistics.lean",
            Some("Provium/OrderStatistics.olean"),
        ),
        ("Provium/Audit.lean", Some("Provium/Audit.olean")),
        ("Check.lean", None),
    ] {
        let result = lean(&work, file, output);
        assert!(
            result.status.success(),
            "{}{}",
            String::from_utf8_lossy(&result.stdout),
            String::from_utf8_lossy(&result.stderr)
        );
    }
    // Only mutate the definition, leaving the contract statements unchanged.
    // Rechecking the module must reject a wrong rank, comparison or empty result.
    for (from, to) in [
        (
            "else (sort values)[rankOffset values.length divisor]?",
            "else (sort values)[values.length - (values.length / divisor)]?",
        ),
        (
            "values.mergeSort (fun a b => decide (a ≤ b))",
            "values.mergeSort (fun a b => decide (b ≤ a))",
        ),
        (
            "if values.isEmpty then none",
            "if values.isEmpty then some 0",
        ),
    ] {
        assert!(source.contains(from));
        fs::write(
            work.0.join("Provium/OrderStatistics.lean"),
            source.replace(from, to),
        )
        .unwrap();
        let result = lean(&work, "Provium/OrderStatistics.lean", None);
        assert!(!result.status.success(), "accepted {from} -> {to}");
        let diagnostic = String::from_utf8_lossy(&result.stdout);
        assert!(diagnostic.contains("error:"), "{diagnostic}");
        assert!(!diagnostic.contains("unexpected token"), "{diagnostic}");
    }
}
