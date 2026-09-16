use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
    sync::atomic::{AtomicUsize, Ordering},
};
static NEXT: AtomicUsize = AtomicUsize::new(0);
struct Subject(PathBuf);
impl Subject {
    fn new() -> Self {
        let path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("artifacts")
            .join(format!(
                "capture subject-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
        fs::create_dir_all(path.join("src")).unwrap();
        fs::write(path.join("Cargo.toml"), "[package]\nname=\"capture_subject\"\nversion=\"0.1.0\"\nedition=\"2021\"\n[workspace]\n").unwrap();
        fs::write(
            path.join("src/lib.rs"),
            "#![no_std]\npub fn answer() -> u32 { 7 }\n",
        )
        .unwrap();
        let locked = Command::new("cargo")
            .args(["generate-lockfile", "--offline", "--manifest-path"])
            .arg(path.join("Cargo.toml"))
            .output()
            .unwrap();
        assert!(
            locked.status.success(),
            "{}",
            String::from_utf8_lossy(&locked.stderr)
        );
        fs::write(path.join("build.json"), r#"{"manifest":"Cargo.toml","target":"host","profile":"release","panic":"abort","features":[],"no_default_features":true}"#).unwrap();
        Self(path)
    }
    fn capture(&self) -> std::process::Output {
        Command::new(env!("CARGO_BIN_EXE_provium"))
            .args(["capture-cargo", "build.json", "--out", "evidence"])
            .current_dir(&self.0)
            .output()
            .unwrap()
    }
    fn certificate(&self) -> PathBuf {
        self.0.join("evidence/captured-build.json")
    }
}
impl Drop for Subject {
    fn drop(&mut self) {
        // Cargo exclusively owns its target tree, including its cleanup.
        let cleaned = Command::new("cargo")
            .args(["clean", "--manifest-path"])
            .arg(self.0.join("Cargo.toml"))
            .arg("--target-dir")
            .arg(self.0.join("target"))
            .output();
        if cleaned.is_ok_and(|o| o.status.success()) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
}
#[test]
fn actual_compiler_arguments_and_sources_are_captured_and_failure_invalidates() {
    let subject = Subject::new();
    let result = subject.capture();
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    let report: serde_json::Value =
        serde_json::from_slice(&fs::read(subject.certificate()).unwrap()).unwrap();
    assert_eq!(report["semantic_preservation_proved"], false);
    let compilers = report["compilers"].as_array().unwrap();
    assert_eq!(compilers.len(), 1);
    assert_eq!(
        compilers[0]["verbose_version"],
        report["subject"]["rustc_identity"]
    );
    assert_eq!(
        compilers[0]["executable_sha256"].as_str().unwrap().len(),
        64
    );
    assert!(Path::new(report["run_directory"].as_str().unwrap())
        .join("source/src/lib.rs")
        .exists());
    assert_eq!(
        report["source_inventory"]["sources"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    let units = report["invocations"].as_array().unwrap();
    let root = units
        .iter()
        .find(|i| {
            i["arguments"]
                .as_array()
                .unwrap()
                .iter()
                .any(|a| a == "capture_subject")
        })
        .unwrap();
    let args = root["arguments"].as_array().unwrap();
    assert!(args.iter().any(|a| a == "opt-level=3"));
    assert!(args.iter().any(|a| a == "panic=abort"));
    assert!(args.iter().any(|a| a == "--emit=metadata"));
    assert_eq!(
        Path::new(root["working_directory"].as_str().unwrap()),
        subject.0
    );
    fs::write(
        subject.0.join("src/lib.rs"),
        "pub fn answer() -> u32 { \"wrong type\" }",
    )
    .unwrap();
    let failed = subject.capture();
    assert!(!failed.status.success());
    assert!(String::from_utf8_lossy(&failed.stderr).contains("captured Cargo build failed"));
    assert!(!subject.certificate().exists());
}
#[test]
fn source_mutation_by_build_script_is_rejected() {
    let subject = Subject::new();
    fs::write(
        subject.0.join("build.rs"),
        r#"fn main() { std::fs::write("src/lib.rs", "pub fn changed() -> u32 { 8 }").unwrap(); }"#,
    )
    .unwrap();
    let result = subject.capture();
    assert!(!result.status.success());
    assert!(
        String::from_utf8_lossy(&result.stderr).contains("source inputs changed during capture"),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    assert!(!subject.certificate().exists());
}
#[test]
fn unhandled_cargo_configuration_does_not_silently_change_wrappers() {
    let subject = Subject::new();
    fs::create_dir_all(subject.0.join(".cargo")).unwrap();
    fs::write(subject.0.join(".cargo/config.toml"), "[build]\njobs=1\n").unwrap();
    let result = subject.capture();
    assert!(!result.status.success());
    assert!(String::from_utf8_lossy(&result.stderr)
        .contains("Cargo configuration capture is not implemented"));
}
