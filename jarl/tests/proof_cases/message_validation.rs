use super::Work;
use std::{fs, path::Path};
#[test]
#[ignore = "requires pinned Lean and installed wasm32 target; scripts/verify.sh runs this"]
fn complete_validation_rejects_missing_batch_and_snapshot_guards() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let w = Work::new();
    let mut project: serde_json::Value = serde_json::from_slice(
        &fs::read(root.join("proofs/message-validation/project.json")).unwrap(),
    )
    .unwrap();
    project["crate_root"] = root.join("src/lib.rs").to_str().unwrap().into();
    project["proofs"] = root
        .join("proofs/message-validation/Proofs.lean")
        .to_str()
        .unwrap()
        .into();
    w.build_request(&root.join("Cargo.toml"), "wasm32-unknown-unknown");
    project["cargo_build"] = "build.json".into();
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
    project["crate_root"] = "src/lib.rs".into();
    w.cargo_build_for("wasm32-unknown-unknown");
    project["cargo_build"] = "build.json".into();
    fs::write(&config, project.to_string()).unwrap();
    let file = w.0.join("src/node.rs");
    let source = fs::read_to_string(&file).unwrap();
    for (original, changed) in [
        ("if ended\n", "if false\n"),
        (
            "snapshot.last.index > 0 && valid_id(snapshot.last)",
            "snapshot.last.index >= 0 && valid_id(snapshot.last)",
        ),
        ("return *campaign > 0;", "return *campaign >= 0;"),
        (
            "previous.index.checked_add(1) != Some(entry.id.index)",
            "false",
        ),
        ("count += 1;", "count += 0;"),
    ] {
        assert_eq!(source.matches(original).count(), 1);
        fs::write(&file, source.replace(original, changed)).unwrap();
        let error = provium::methods::verify(&config, &w.out()).unwrap_err();
        assert!(error.contains("Lean rejected Proofs.lean"), "{error}");
        assert!(!w.out().join("verified.json").exists());
    }
}
