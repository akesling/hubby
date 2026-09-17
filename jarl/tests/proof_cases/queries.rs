use super::Work;
use std::{fs, path::Path};

#[test]
#[ignore = "requires pinned Lean and installed wasm32 Rust target; scripts/verify.sh runs this"]
fn complete_input_gate_and_acknowledgment_composition_verify_on_32_bit() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let w = Work::new();
    let mut project: serde_json::Value =
        serde_json::from_slice(&fs::read(root.join("proofs/input-gating/project.json")).unwrap())
            .unwrap();
    project["crate_root"] = root.join("src/lib.rs").to_str().unwrap().into();
    project["proofs"] = root
        .join("proofs/input-gating/Proofs.lean")
        .to_str()
        .unwrap()
        .into();
    w.build_request(&root.join("Cargo.toml"), "wasm32-unknown-unknown");
    project["cargo_build"] = "build.json".into();
    let config = w.write("project.json", &project.to_string());
    provium::methods::verify(&config, &w.out()).unwrap();
    let manifest: serde_json::Value =
        serde_json::from_slice(&fs::read(w.out().join("manifest.json")).unwrap()).unwrap();
    assert!(manifest["rust_target_cfg"]
        .as_str()
        .unwrap()
        .contains("target_pointer_width=\"32\""));
    assert!(manifest["typecheck_args"]
        .as_array()
        .unwrap()
        .iter()
        .any(|a| a == "wasm32-unknown-unknown"));
}

#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn each_missing_input_gate_breaks_the_original_source_contract() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let original = fs::read_to_string(root.join("src/node.rs")).unwrap();
    let condition =
        "self.dirty || self.extra_reply.is_some() || self.outbox.iter().any(Option::is_some)";
    assert_eq!(original.matches(condition).count(), 1);
    for replacement in [
        "self.extra_reply.is_some() || self.outbox.iter().any(Option::is_some)",
        "self.dirty || self.outbox.iter().any(Option::is_some)",
        "self.dirty || self.extra_reply.is_some()",
    ] {
        let w = Work::new();
        fs::create_dir(w.0.join("src")).unwrap();
        for file in fs::read_dir(root.join("src")).unwrap() {
            let file = file.unwrap();
            if file.path().extension().is_some_and(|e| e == "rs") {
                fs::copy(file.path(), w.0.join("src").join(file.file_name())).unwrap();
            }
        }
        fs::copy(root.join("README.md"), w.0.join("README.md")).unwrap();
        fs::write(
            w.0.join("src/node.rs"),
            original.replace(condition, replacement),
        )
        .unwrap();
        let mut project: serde_json::Value = serde_json::from_slice(
            &fs::read(root.join("proofs/input-gating/project.json")).unwrap(),
        )
        .unwrap();
        project["crate_root"] = "src/lib.rs".into();
        w.cargo_build_for("host");
        project["cargo_build"] = "build.json".into();
        fs::copy(
            root.join("proofs/input-gating/Proofs.lean"),
            w.0.join("Proofs.lean"),
        )
        .unwrap();
        let config = w.write("project.json", &project.to_string());
        let error = provium::methods::verify(&config, &w.out()).unwrap_err();
        assert!(error.contains("Lean rejected Proofs.lean"), "{error}");
        assert!(!w.out().join("verified.json").exists());
    }
}
