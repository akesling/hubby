use super::Work;
use std::{fs, path::Path};

#[test]
#[ignore = "requires pinned Lean and installed wasm32 target; scripts/verify.sh runs this"]
fn composed_validation_and_storage_contract_verifies_on_32_bit() {
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
}
