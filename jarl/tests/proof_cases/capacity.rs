use super::Work;
use std::{fs, path::Path};

#[test]
#[ignore = "requires pinned Lean and installed wasm32 target; scripts/verify.sh runs this"]
fn capacity_contract_is_target_parametric_and_source_sensitive() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let w = Work::new();
    let mut project: serde_json::Value =
        serde_json::from_slice(&fs::read(root.join("proofs/capacity/project.json")).unwrap())
            .unwrap();
    project["scalar_method"]["crate_root"] = root.join("src/lib.rs").to_str().unwrap().into();
    project["proofs"] = root
        .join("proofs/capacity/Proofs.lean")
        .to_str()
        .unwrap()
        .into();
    project["usize_bits"] = 32.into();
    project["rust_target"] = "wasm32-unknown-unknown".into();
    let config = w.write("project.json", &project.to_string());
    provium::project::verify(&config, &w.out()).unwrap();
    fs::create_dir(w.0.join("src")).unwrap();
    for entry in fs::read_dir(root.join("src")).unwrap() {
        let entry = entry.unwrap();
        if entry.path().extension().is_some_and(|e| e == "rs") {
            fs::copy(entry.path(), w.0.join("src").join(entry.file_name())).unwrap();
        }
    }
    fs::copy(root.join("README.md"), w.0.join("README.md")).unwrap();
    let state = w.0.join("src/state.rs");
    let source = fs::read_to_string(&state).unwrap();
    assert_eq!(source.matches("self.len == CAP").count(), 1);
    fs::write(&state, source.replace("self.len == CAP", "self.len != CAP")).unwrap();
    project["scalar_method"]["crate_root"] = "src/lib.rs".into();
    fs::write(&config, project.to_string()).unwrap();
    let error = provium::project::verify(&config, &w.out()).unwrap_err();
    assert!(error.contains("Lean rejected Proofs.lean"), "{error}");
    assert!(!w.out().join("verified.json").exists());
}
