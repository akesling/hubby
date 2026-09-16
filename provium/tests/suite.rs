use provium::{verify_project, verify_suite};
use std::{
    fs,
    path::{Path, PathBuf},
    sync::atomic::{AtomicUsize, Ordering},
};
static NEXT: AtomicUsize = AtomicUsize::new(0);
struct Consumer(PathBuf);
impl Consumer {
    fn new() -> Self {
        let p = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("artifacts")
            .join(format!(
                "consumer-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
        fs::create_dir_all(p.join("proofs")).unwrap();
        Self(p)
    }
}
impl Drop for Consumer {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
#[test]
fn empty_suites_and_projects_without_obligations_fail() {
    let consumer = Consumer::new();
    assert!(verify_suite(&consumer.0, Path::new("proofs"))
        .unwrap_err()
        .contains("no project.json"));
    let project = consumer.0.join("proofs/project.json");
    fs::write(&project, r#"{"source":"source.rs"}"#).unwrap();
    let out = consumer.0.join("artifacts/provium/root");
    fs::create_dir_all(&out).unwrap();
    fs::write(out.join("verified.json"), "stale").unwrap();
    assert!(verify_project(&project, &out)
        .unwrap_err()
        .contains("nonempty obligations"));
    assert!(!out.join("verified.json").exists());
}
#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn consumer_suite_discovers_both_backends_and_owns_its_evidence() {
    let consumer = Consumer::new();
    let scalar = consumer.0.join("proofs/scalar");
    fs::create_dir(&scalar).unwrap();
    let fixture = Path::new(env!("CARGO_MANIFEST_DIR")).join("examples/assertions");
    for name in ["project.json", "source.rs", "Proofs.lean"] {
        fs::copy(fixture.join(name), scalar.join(name)).unwrap();
    }
    let methods = consumer.0.join("proofs/state");
    fs::create_dir(&methods).unwrap();
    fs::write(
        methods.join("lib.rs"),
        "struct State{dirty:bool} impl State{fn clear(&mut self){self.dirty=false;}}",
    )
    .unwrap();
    fs::write(methods.join("Proofs.lean"),"import Generated\nopen Provium.State\ntheorem cleared (s : Store α) : Consumer.State_clear s [\"dirty\"] = .boolean false := by simp [Consumer.State_clear,put]\n").unwrap();
    fs::write(methods.join("project.json"),r#"{"crate_root":"lib.rs","namespace":"Consumer","methods":["State::clear"],"proofs":"Proofs.lean","obligations":[{"theorem":"cleared","function":"State_clear"}]}"#).unwrap();
    let reports = verify_suite(&consumer.0, Path::new("proofs")).unwrap();
    assert_eq!(reports.len(), 2);
    for report in &reports {
        assert!(report
            .output
            .starts_with(consumer.0.join("artifacts/provium")));
        assert!(report.output.join("verified.json").exists());
    }
    let subset = verify_suite(&consumer.0, Path::new("proofs/scalar")).unwrap();
    assert_eq!(subset.len(), 1);
    assert_eq!(subset[0].output, reports[0].output);
    assert_eq!(
        subset[0].output,
        consumer.0.join("artifacts/provium/proofs/scalar")
    );
    fs::write(scalar.join("Proofs.lean"), "invalid Lean").unwrap();
    assert!(verify_suite(&consumer.0, Path::new("proofs"))
        .unwrap_err()
        .contains("Lean rejected"));
    for report in &reports {
        assert!(!report.output.join("verified.json").exists());
    }
}

#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn specification_evidence_cannot_claim_source_correspondence_or_hide_axioms() {
    let consumer = Consumer::new();
    let directory = consumer.0.join("proofs");
    let project = directory.join("project.json");
    let proofs = directory.join("Model.lean");
    fs::write(&project, r#"{"kind":"specification","schema":1,"proofs":"Model.lean","obligations":[{"theorem":"witness","definition":"initial"}]}"#).unwrap();
    fs::write(
        &proofs,
        "def initial : Nat := 0\ntheorem witness : initial = 0 := rfl\n",
    )
    .unwrap();
    let reports = verify_suite(&consumer.0, Path::new("proofs")).unwrap();
    let out = &reports[0].output;
    let certificate: serde_json::Value =
        serde_json::from_slice(&fs::read(out.join("verified.json")).unwrap()).unwrap();
    assert_eq!(certificate["kind"], "specification_only");
    assert_eq!(certificate["whole_program_proved"], false);
    assert_eq!(certificate["source_correspondence_proved"], false);
    for bad in [
        "def initial : Nat := 1\ntheorem witness : initial = 0 := rfl\n",
        "def initial : Nat := 0\naxiom hidden : initial = 0\ntheorem witness : initial = 0 := hidden\n",
        "def initial : Nat := 0\nopaque hidden : initial = 0 := by sorry\ntheorem witness : initial = 0 := hidden\n",
        "def initial : Nat := 0\ntheorem witness : True := True.intro\n",
        "import Other\ndef initial : Nat := 0\ntheorem witness : initial = 0 := rfl\n",
    ] {
        fs::write(out.join("verified.json"), "stale").unwrap();
        fs::write(&proofs, bad).unwrap();
        assert!(verify_project(&project, out).is_err(), "accepted {bad}");
        assert!(!out.join("verified.json").exists());
    }
}
