use super::Work;
use std::{fs, path::Path};

#[test]
#[ignore = "requires pinned Lean and installed wasm32 target; scripts/verify.sh runs this"]
fn append_shape_holds_on_32_bit_and_rejects_changed_effects() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let w = Work::new();
    let mut project: serde_json::Value =
        serde_json::from_slice(&fs::read(root.join("proofs/storage/project.json")).unwrap())
            .unwrap();
    project["crate_root"] = root.join("src/lib.rs").to_str().unwrap().into();
    project["proofs"] = root
        .join("proofs/storage/Proofs.lean")
        .to_str()
        .unwrap()
        .into();
    project["rust_target"] = "wasm32-unknown-unknown".into();
    let config = w.write("project.json", &project.to_string());
    provium::methods::verify(&config, &w.out()).unwrap();
    fs::create_dir(w.0.join("src")).unwrap();
    for file in fs::read_dir(root.join("src")).unwrap() {
        let file = file.unwrap();
        if file.path().extension().is_some_and(|e| e == "rs") {
            fs::copy(file.path(), w.0.join("src").join(file.file_name())).unwrap();
        }
    }
    fs::copy(root.join("README.md"), w.0.join("README.md")).unwrap();
    let state = w.0.join("src/state.rs");
    let source = fs::read_to_string(&state).unwrap();
    project["crate_root"] = "src/lib.rs".into();
    fs::write(&config, project.to_string()).unwrap();
    for (from, to) in [
        ("self.len += 1;", "self.len += 2;"),
        ("self.len == CAP", "self.len != CAP"),
    ] {
        assert_eq!(source.matches(from).count(), 1);
        fs::write(&state, source.replace(from, to)).unwrap();
        let error = provium::methods::verify(&config, &w.out()).unwrap_err();
        assert!(error.contains("Lean rejected Proofs.lean"), "{error}");
        assert!(!w.out().join("verified.json").exists());
    }
}
