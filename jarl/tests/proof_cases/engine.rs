use std::{fs, path::Path};

/// M3: the fixed `Node` engine, translated by Provium's typed backend, is safe
/// on every reachable cluster (`proofs/engine/Engine/Main.lean`).
#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn fixed_engine_safety_is_kernel_checked() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let report = provium::typed::verify::verify(
        &root.join("proofs/engine/project.json"),
        &root.join("artifacts/provium/engine"),
    )
    .unwrap();
    for theorem in [
        "Jarl.Engine.election_safety",
        "Jarl.Engine.raft_state_machine_safety",
        "Jarl.Engine.raft_snapshot_safety",
        "Jarl.Engine.App.raft_snapshot_application_safety",
        "Jarl.Engine.Host.host_state_machine_safety",
    ] {
        assert!(
            report.contains(&format!("PROVIUM_VERIFIED {theorem}")),
            "{report}"
        );
    }
    assert!(report.contains("Differential: 40 scenarios"), "{report}");
    assert!(
        report.contains("Differential coverage: 96 of 98 translated functions executed"),
        "{report}"
    );
    assert!(report.contains("rustc cross-check:"), "{report}");
}

/// The same proofs, checked against the translation of a 32-bit build
/// (wasm32), where `usize` is 32 bits wide. The differential scenario runs
/// natively, so this variant omits it.
#[test]
#[ignore = "requires pinned Lean and the wasm32 target; scripts/verify.sh runs this"]
fn fixed_engine_safety_holds_on_32_bit() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let proofs = root.join("proofs/engine");
    let out = root.join("artifacts/provium/engine-wasm32");
    let mut project: serde_json::Value =
        serde_json::from_slice(&fs::read(proofs.join("project.json")).unwrap()).unwrap();
    project["cargo_build"] = root
        .join("proofs/builds-wasm32.json")
        .to_str()
        .unwrap()
        .into();
    project["crate_root"] = root.join("src/lib.rs").to_str().unwrap().into();
    project["proofs"] = proofs.join("Proofs.lean").to_str().unwrap().into();
    for module in project["proof_modules"].as_array_mut().unwrap() {
        let path = proofs.join(module["path"].as_str().unwrap());
        module["path"] = path.to_str().unwrap().into();
    }
    project.as_object_mut().unwrap().remove("differential");
    fs::create_dir_all(&out).unwrap();
    let config = out.join("project.json");
    fs::write(&config, project.to_string()).unwrap();
    let report = provium::typed::verify::verify(&config, &out.join("verified")).unwrap();
    for theorem in [
        "Jarl.Engine.election_safety",
        "Jarl.Engine.raft_state_machine_safety",
        "Jarl.Engine.raft_snapshot_safety",
        "Jarl.Engine.App.raft_snapshot_application_safety",
        "Jarl.Engine.Host.host_state_machine_safety",
    ] {
        assert!(
            report.contains(&format!("PROVIUM_VERIFIED {theorem}")),
            "{report}"
        );
    }
    assert!(report.contains("rustc cross-check:"), "{report}");
}
