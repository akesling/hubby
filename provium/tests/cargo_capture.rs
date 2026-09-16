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
    let cfg = root["effective_cfg"].as_str().unwrap();
    assert!(cfg.lines().any(|line| line == "panic=\"abort\""));
    assert!(!cfg.lines().any(|line| line == "debug_assertions"));
    assert!(cfg
        .lines()
        .any(|line| line.starts_with("target_pointer_width=")));
    assert!(units.iter().any(|unit| unit["effective_cfg"].is_null()));
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

#[test]
fn effective_cfg_includes_build_script_features_and_actual_profile_override() {
    let subject = Subject::new();
    let manifest = subject.0.join("Cargo.toml");
    let mut contents = fs::read_to_string(&manifest).unwrap();
    contents.push_str("\n[features]\nselected=[]\n");
    fs::write(manifest, contents).unwrap();
    fs::write(subject.0.join("build.rs"),
        "fn main() { println!(\"cargo::rustc-cfg=from_build_script\"); println!(\"cargo::rustc-check-cfg=cfg(from_build_script)\"); }").unwrap();
    fs::write(
        subject.0.join("build.json"),
        r#"{"manifest":"Cargo.toml","target":"host","profile":"release","features":["selected"]}"#,
    )
    .unwrap();
    fs::write(
        subject.0.join("src/lib.rs"),
        r#"
        #![no_std]
        #[cfg(all(from_build_script, feature="selected", debug_assertions))]
        pub fn enabled() {}
        #[cfg(not(all(from_build_script, feature="selected", debug_assertions)))]
        pub fn disabled() {}
    "#,
    )
    .unwrap();
    let result = Command::new(env!("CARGO_BIN_EXE_provium"))
        .args(["capture-cargo", "build.json", "--out", "evidence"])
        .env("CARGO_PROFILE_RELEASE_DEBUG_ASSERTIONS", "true")
        .current_dir(&subject.0)
        .output()
        .unwrap();
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    let report: serde_json::Value =
        serde_json::from_slice(&fs::read(subject.certificate()).unwrap()).unwrap();
    let units = report["invocations"].as_array().unwrap();
    let root = units
        .iter()
        .find(|unit| {
            unit["arguments"]
                .as_array()
                .unwrap()
                .iter()
                .any(|a| a == "capture_subject")
        })
        .unwrap();
    let cfg = root["effective_cfg"].as_str().unwrap();
    for expected in [
        "debug_assertions",
        "feature=\"selected\"",
        "from_build_script",
    ] {
        assert!(
            cfg.lines().any(|line| line == expected),
            "missing {expected}: {cfg}"
        );
    }
    assert_eq!(
        &units[report["configured_root_invocation"].as_u64().unwrap() as usize],
        root
    );
    let selected = report["configured_inventory"]["items"].as_array().unwrap();
    assert!(selected.iter().any(|i| i["id"] == "crate::enabled"));
    assert!(!selected.iter().any(|i| i["id"] == "crate::disabled"));
    let result = Command::new(env!("CARGO_BIN_EXE_provium"))
        .args(["capture-cargo", "build.json", "--out", "evidence"])
        .env("CARGO_PROFILE_RELEASE_DEBUG_ASSERTIONS", "false")
        .current_dir(&subject.0)
        .output()
        .unwrap();
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    let changed: serde_json::Value =
        serde_json::from_slice(&fs::read(subject.certificate()).unwrap()).unwrap();
    let selected = changed["configured_inventory"]["items"].as_array().unwrap();
    assert!(!selected.iter().any(|i| i["id"] == "crate::enabled"));
    assert!(selected.iter().any(|i| i["id"] == "crate::disabled"));
    assert_eq!(report["source_inventory"], changed["source_inventory"]);
    // Metadata's requested release profile deliberately differs from Cargo's
    // effective override, demonstrating why the unit-level query is necessary.
    assert!(!report["subject"]["target_cfg"]
        .as_str()
        .unwrap()
        .lines()
        .any(|line| line == "debug_assertions"));
    let build = units
        .iter()
        .find(|unit| {
            unit["arguments"]
                .as_array()
                .unwrap()
                .iter()
                .any(|a| a == "build_script_build")
        })
        .unwrap();
    assert!(!build["effective_cfg"]
        .as_str()
        .unwrap()
        .lines()
        .any(|line| line == "from_build_script"));
}

#[test]
fn response_files_fail_closed_and_invalidate_prior_capture() {
    let subject = Subject::new();
    assert!(subject.capture().status.success());
    let response = subject.0.join("flags.rsp");
    fs::write(&response, "--cfg=hidden_configuration\n").unwrap();
    let result = Command::new(env!("CARGO_BIN_EXE_provium"))
        .args(["capture-cargo", "build.json", "--out", "evidence"])
        .env(
            "CARGO_ENCODED_RUSTFLAGS",
            format!("@{}", response.display()),
        )
        .current_dir(&subject.0)
        .output()
        .unwrap();
    assert!(!result.status.success());
    assert!(
        String::from_utf8_lossy(&result.stderr)
            .contains("compiler response-file capture is not implemented"),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    assert!(!subject.certificate().exists());
}

#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn cargo_method_proof_uses_features_profile_and_original_source() {
    let subject = Subject::new();
    let manifest = subject.0.join("Cargo.toml");
    let contents = fs::read_to_string(&manifest).unwrap() + "\n[features]\nchosen=[]\n";
    fs::write(manifest, contents).unwrap();
    let source = "#![no_std]\npub struct State { flag: bool } impl State { #[cfg(all(feature=\"chosen\", not(debug_assertions)))] pub fn clear(&mut self) { self.flag = false; } }";
    fs::write(subject.0.join("src/lib.rs"), source).unwrap();
    let request = r#"{"manifest":"Cargo.toml","target":"host","profile":"release","panic":"abort","features":["chosen"]}"#;
    fs::write(subject.0.join("build.json"), request).unwrap();
    fs::write(subject.0.join("Proofs.lean"), "import Generated\nopen Provium.State\ntheorem cleared (s : Store α) : Subject.State_clear s [\"flag\"] = .boolean false := by simp [Subject.State_clear, put]\n").unwrap();
    let mut project = serde_json::json!({"crate_root":"src/lib.rs","cargo_build":"build.json","namespace":"Subject","methods":["State::clear"],"proofs":"Proofs.lean","obligations":[{"theorem":"cleared","function":"State_clear"}]});
    let project_path = subject.0.join("project.json");
    fs::write(&project_path, project.to_string()).unwrap();
    let verify = || {
        Command::new(env!("CARGO_BIN_EXE_provium"))
            .args(["verify-methods", "project.json", "--out", "proofs-out"])
            .current_dir(&subject.0)
            .output()
            .unwrap()
    };
    let result = verify();
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    let evidence = subject.0.join("proofs-out/manifest.json");
    let report: serde_json::Value = serde_json::from_slice(&fs::read(evidence).unwrap()).unwrap();
    assert_eq!(
        report["sources"][0]["sha256"],
        provium::project::hash(source)
    );
    assert!(report["rust_target_cfg"]
        .as_str()
        .unwrap()
        .contains("feature=\"chosen\""));
    assert!(!report["rust_target_cfg"]
        .as_str()
        .unwrap()
        .lines()
        .any(|line| line == "debug_assertions"));
    assert_eq!(
        report["typecheck_args"],
        report["cargo_build"]["root_invocation"]["arguments"]
    );
    assert_eq!(
        report["cargo_build"]["capture_sha256"],
        provium::project::hash(
            fs::read(subject.0.join("proofs-out/Cargo/captured-build.json")).unwrap()
        )
    );
    assert!(!subject.0.join("proofs-out/subject.rmeta").exists());
    let proof_path = subject.0.join("Proofs.lean");
    let proof = fs::read_to_string(&proof_path).unwrap();
    let request_literal =
        serde_json::to_string(subject.0.join("build.json").to_str().unwrap()).unwrap();
    fs::write(
        &proof_path,
        format!("{proof}\nrun_cmd do IO.FS.writeFile {request_literal} \"{{}}\"\n"),
    )
    .unwrap();
    let result = verify();
    assert!(!result.status.success());
    assert!(
        String::from_utf8_lossy(&result.stderr).contains("Cargo build request or evidence changed"),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    assert!(!subject.0.join("proofs-out/verified.json").exists());
    fs::write(&proof_path, proof).unwrap();
    fs::write(subject.0.join("build.json"), request).unwrap();
    fs::write(
        subject.0.join("src/lib.rs"),
        source.replace("flag = false", "flag = true"),
    )
    .unwrap();
    let result = verify();
    assert!(!result.status.success());
    assert!(String::from_utf8_lossy(&result.stderr).contains("Lean rejected Proofs.lean"));
    assert!(!subject.0.join("proofs-out/verified.json").exists());
    fs::write(subject.0.join("src/lib.rs"), source).unwrap();
    fs::write(
        subject.0.join("build.json"),
        request.replace("[\"chosen\"]", "[]"),
    )
    .unwrap();
    let result = verify();
    assert!(!result.status.success());
    assert!(
        String::from_utf8_lossy(&result.stderr).contains("unknown method"),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    fs::write(subject.0.join("build.json"), request).unwrap();
    fs::write(subject.0.join("wrong.rs"), "pub struct Other;").unwrap();
    project["crate_root"] = "wrong.rs".into();
    fs::write(&project_path, project.to_string()).unwrap();
    let result = verify();
    assert!(!result.status.success());
    assert!(String::from_utf8_lossy(&result.stderr).contains("not the captured Cargo library root"));
    project["rust_target"] = "wasm32-unknown-unknown".into();
    fs::write(&project_path, project.to_string()).unwrap();
    let result = verify();
    assert!(!result.status.success());
    assert!(String::from_utf8_lossy(&result.stderr).contains("cannot both select"));
}
