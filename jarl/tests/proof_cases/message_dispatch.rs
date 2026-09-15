use super::Work;
use std::{fs, path::Path};
#[test]
#[ignore = "requires pinned Lean and installed wasm32 target; scripts/verify.sh runs this"]
fn complete_message_term_rejects_using_campaign_as_durable_term() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let w = Work::new();
    let mut project: serde_json::Value = serde_json::from_slice(
        &fs::read(root.join("proofs/message-dispatch/project.json")).unwrap(),
    )
    .unwrap();
    project["crate_root"] = root.join("src/lib.rs").to_str().unwrap().into();
    project["proofs"] = root
        .join("proofs/message-dispatch/Proofs.lean")
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
    let file = w.0.join("src/lib.rs");
    let source = fs::read_to_string(&file).unwrap();
    let original = "Self::PreVoted { term, .. }";
    assert_eq!(source.matches(original).count(), 1);
    fs::write(
        file,
        source.replace(original, "Self::PreVoted { campaign: term, .. }"),
    )
    .unwrap();
    project["crate_root"] = "src/lib.rs".into();
    fs::write(&config, project.to_string()).unwrap();
    let error = provium::methods::verify(&config, &w.out()).unwrap_err();
    assert!(error.contains("Lean rejected Proofs.lean"), "{error}");
    assert!(!w.out().join("verified.json").exists());
}
