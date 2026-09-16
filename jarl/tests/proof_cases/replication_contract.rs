use super::Work;
use std::{fs, path::Path};

#[test]
#[ignore = "requires pinned Lean and installed wasm32 target; scripts/verify.sh runs this"]
fn composed_replacement_verifies_on_32_bit_and_rejects_changed_lookup_and_cut() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let directory = root.join("proofs/replication-contract");
    let mut project: serde_json::Value =
        serde_json::from_slice(&fs::read(directory.join("project.json")).unwrap()).unwrap();
    project["crate_root"] = root.join("src/lib.rs").to_str().unwrap().into();
    project["proofs"] = directory.join("Proofs.lean").to_str().unwrap().into();
    project["rust_target"] = "wasm32-unknown-unknown".into();
    for library in project["proof_modules"].as_array_mut().unwrap() {
        library["path"] = directory
            .join(library["path"].as_str().unwrap())
            .to_str()
            .unwrap()
            .into();
    }
    let w = Work::new();
    let config = w.write("project.json", &project.to_string());
    provium::methods::verify(&config, &w.out()).unwrap();
    let certificate: serde_json::Value =
        serde_json::from_slice(&fs::read(w.out().join("verified.json")).unwrap()).unwrap();
    assert_eq!(certificate["whole_program_proved"], false);
    fs::create_dir(w.0.join("src")).unwrap();
    for file in fs::read_dir(root.join("src")).unwrap() {
        let file = file.unwrap();
        if file
            .path()
            .extension()
            .is_some_and(|extension| extension == "rs")
        {
            fs::copy(file.path(), w.0.join("src").join(file.file_name())).unwrap();
        }
    }
    fs::copy(root.join("README.md"), w.0.join("README.md")).unwrap();
    project["crate_root"] = "src/lib.rs".into();
    fs::write(&config, project.to_string()).unwrap();
    let path = w.0.join("src/state.rs");
    let source = fs::read_to_string(&path).unwrap();
    for (original, changed) in [
        ("checked_sub(1)?;", "checked_sub(0)?;"),
        ("self.last().index >= from", "self.last().index > from"),
    ] {
        assert_eq!(source.matches(original).count(), 1);
        fs::write(&path, source.replace(original, changed)).unwrap();
        let error = provium::methods::verify(&config, &w.out()).unwrap_err();
        assert!(error.contains("Lean rejected"), "{error}");
        assert!(!w.out().join("verified.json").exists());
    }
}
