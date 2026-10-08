use super::Work;
use std::{fs, path::Path};
#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn changing_jarl_acknowledgment_breaks_the_kernel_checked_contract() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let original = fs::read_to_string(root.join("src/ready.rs")).unwrap();
    assert!(original.contains("self.node.dirty = false;"));
    let run = |ready: &str| {
        let w = Work::new();
        fs::create_dir(w.0.join("src")).unwrap();
        for file in fs::read_dir(root.join("src")).unwrap() {
            let file = file.unwrap();
            if file.path().extension().is_some_and(|e| e == "rs") {
                fs::copy(file.path(), w.0.join("src").join(file.file_name())).unwrap();
            }
        }
        fs::copy(root.join("README.md"), w.0.join("README.md")).unwrap();
        fs::write(w.0.join("src/ready.rs"), ready).unwrap();
        let mut project: serde_json::Value = serde_json::from_slice(
            &fs::read(root.join("proofs/persistence/project.json")).unwrap(),
        )
        .unwrap();
        project["crate_root"] = "src/lib.rs".into();
        w.cargo_build();
        project["cargo_build"] = "build.json".into();
        fs::copy(
            root.join("proofs/persistence/Proofs.lean"),
            w.0.join("Proofs.lean"),
        )
        .unwrap();
        let config = w.0.join("project.json");
        fs::write(&config, project.to_string()).unwrap();
        provium::methods::verify(&config, &w.0.join("out"))
    };
    // Control: the copied, unmutated crate must verify, or a fixture-level
    // failure would satisfy the mutation check below.
    run(&original).unwrap();
    let error =
        run(&original.replace("self.node.dirty = false;", "self.node.dirty = true;")).unwrap_err();
    assert!(error.contains("Lean rejected Proofs.lean"), "{error}");
}
