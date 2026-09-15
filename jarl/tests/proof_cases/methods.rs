use super::Work;
use std::{fs, path::Path};
#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn changing_jarl_acknowledgment_breaks_the_kernel_checked_contract() {
    let w = Work::new();
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    fs::create_dir(w.0.join("src")).unwrap();
    for file in fs::read_dir(root.join("src")).unwrap() {
        let file = file.unwrap();
        if file.path().extension().is_some_and(|e| e == "rs") {
            fs::copy(file.path(), w.0.join("src").join(file.file_name())).unwrap();
        }
    }
    fs::copy(root.join("README.md"), w.0.join("README.md")).unwrap();
    let ready = w.0.join("src/ready.rs");
    let original = fs::read_to_string(&ready).unwrap();
    assert!(original.contains("self.node.dirty = false;"));
    fs::write(
        &ready,
        original.replace("self.node.dirty = false;", "self.node.dirty = true;"),
    )
    .unwrap();
    let mut project: serde_json::Value =
        serde_json::from_slice(&fs::read(root.join("proofs/persistence/project.json")).unwrap())
            .unwrap();
    project["crate_root"] = "src/lib.rs".into();
    fs::copy(
        root.join("proofs/persistence/Proofs.lean"),
        w.0.join("Proofs.lean"),
    )
    .unwrap();
    let config = w.0.join("project.json");
    fs::write(&config, project.to_string()).unwrap();
    let error = provium::methods::verify(&config, &w.0.join("out")).unwrap_err();
    assert!(error.contains("Lean rejected Proofs.lean"), "{error}");
}
