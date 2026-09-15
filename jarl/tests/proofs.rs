//! Jarl owns these contracts; Provium is the reusable verification dependency.
use std::{
    fs,
    path::{Path, PathBuf},
    sync::atomic::{AtomicUsize, Ordering},
};
static NEXT: AtomicUsize = AtomicUsize::new(0);
struct Work(PathBuf);
impl Work {
    fn new() -> Self {
        let path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("artifacts")
            .join(format!(
                "proof-test-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }
    fn write(&self, name: &str, text: &str) -> PathBuf {
        let p = self.0.join(name);
        fs::write(&p, text).unwrap();
        p
    }
    fn source(&self, text: &str) -> PathBuf {
        self.write("lib.rs", text)
    }
    fn out(&self) -> PathBuf {
        self.0.join("out")
    }
}
impl Drop for Work {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn invariants() {
    provium::assert_proofs!("proofs");
}

#[test]
fn source_coverage_review_is_current() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let report = provium::coverage::audit(
        root,
        Path::new("src/lib.rs"),
        &root.join("proofs/coverage.json"),
    )
    .expect("review changed Jarl source and update its coverage ledger");
    println!(
        "{} inventoried items; {} with declared component evidence; full proof remains open",
        report.items, report.component_items
    );
}

#[test]
fn cargo_subject_keeps_proof_tools_out_of_the_runtime_graph() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let mut request: provium::cargo_subject::Request =
        serde_json::from_slice(&fs::read(root.join("proofs/builds.json")).unwrap()).unwrap();
    request.manifest = root.join("proofs").join(request.manifest);
    let report =
        provium::cargo_subject::write(request, &root.join("artifacts/provium/build-profile"))
            .unwrap();
    assert_eq!(
        report.packages.len(),
        1,
        "Jarl must retain its dependency-free runtime graph"
    );
    assert_eq!(report.packages[0].name, "jarl");
    assert!(report.packages[0].normal_dependencies.is_empty());
    assert!(report.packages[0].build_dependencies.is_empty());
    assert!(report.target_cfg.contains("target_pointer_width"));
    assert!(report
        .workspace_inputs
        .keys()
        .any(|p| p.ends_with("Cargo.lock")));
}

#[path = "proof_cases/capacity.rs"]
mod capacity;
#[path = "proof_cases/lean.rs"]
mod consensus;
#[path = "proof_cases/scalar_methods.rs"]
mod election;
#[path = "proof_cases/queries.rs"]
mod input_gating;
#[path = "proof_cases/arrays.rs"]
mod membership;
#[path = "proof_cases/methods.rs"]
mod persistence;
