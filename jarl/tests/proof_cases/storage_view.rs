use super::Work;
use std::{fs, path::Path};

fn copy_sources(from: &Path, to: &Path) {
    fs::create_dir_all(to).unwrap();
    for entry in fs::read_dir(from).unwrap() {
        let entry = entry.unwrap();
        let destination = to.join(entry.file_name());
        if entry.file_type().unwrap().is_dir() {
            copy_sources(&entry.path(), &destination);
        } else {
            fs::copy(entry.path(), destination).unwrap();
        }
    }
}

#[test]
#[ignore = "requires pinned Lean and installed wasm32; scripts/verify.sh runs this"]
fn delta_contracts_reject_source_and_host_order_changes() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let work = Work::new();
    copy_sources(&root.join("src"), &work.0.join("src"));
    fs::copy(root.join("README.md"), work.0.join("README.md")).unwrap();
    let proof = root.join("proofs/storage-view");
    let model = fs::read_to_string(proof.join("Delta.lean")).unwrap();
    let model_path = work.write("Delta.lean", &model);
    let mut project: serde_json::Value =
        serde_json::from_slice(&fs::read(proof.join("project.json")).unwrap()).unwrap();
    project["crate_root"] = "src/lib.rs".into();
    project["proofs"] = proof.join("Proofs.lean").to_str().unwrap().into();
    project["proof_modules"][0]["path"] = "Delta.lean".into();
    work.cargo_build_for("wasm32-unknown-unknown");
    project["cargo_build"] = "build.json".into();
    let config = work.write("project.json", &project.to_string());
    let out = work.out();
    provium::methods::verify(&config, &out).unwrap();
    let state_path = work.0.join("src/state.rs");
    let state = fs::read_to_string(&state_path).unwrap();
    // Each mutation must fail for its stated reason, never an unrelated Cargo
    // failure: either the theorem checker rejects it, or the frontend's
    // fail-closed shape check names the construct it no longer admits.
    for (old, new, expected) in [
        (
            ".saturating_sub(1)",
            ".saturating_sub(0)",
            "Lean rejected Proofs.lean",
        ),
        (
            "filter(|_| snapshot_changed)",
            "filter(|_| !snapshot_changed)",
            "view filter must test its boolean input",
        ),
        (
            "truncate_from: from,",
            "truncate_from: None,",
            "unsupported shared view field expression",
        ),
    ] {
        assert!(state.contains(old));
        fs::write(&state_path, state.replacen(old, new, 1)).unwrap();
        fs::write(out.join("verified.json"), "stale").unwrap();
        let error = provium::methods::verify(&config, &out).unwrap_err();
        assert!(error.contains(expected), "{old} -> {new}: {error}");
        assert!(!out.join("verified.json").exists());
    }
    fs::write(&state_path, state).unwrap();
    let ready_path = work.0.join("src/ready.rs");
    let ready = fs::read_to_string(&ready_path).unwrap();
    fs::write(
        &ready_path,
        ready.replace(
            "self.entries.iter().flatten()",
            "self.entries.iter().flatten().rev()",
        ),
    )
    .unwrap();
    fs::write(out.join("verified.json"), "stale").unwrap();
    let error = provium::methods::verify(&config, &out).unwrap_err();
    assert!(
        error.contains("expected builtin lookup flatten"),
        "reversed entries: {error}"
    );
    assert!(!out.join("verified.json").exists());
    fs::write(&ready_path, ready).unwrap();
    for (old, new) in [
        (
            "boundary snapshot < index entry",
            "boundary snapshot <= index entry",
        ),
        ("index entry < cut", "index entry <= cut"),
        ("| some snapshot => some snapshot", "| some _ => old"),
    ] {
        assert!(model.contains(old));
        fs::write(&model_path, model.replacen(old, new, 1)).unwrap();
        fs::write(out.join("verified.json"), "stale").unwrap();
        let error = provium::methods::verify(&config, &out).unwrap_err();
        assert!(error.contains("Lean rejected StorageDelta.lean"), "{error}");
        assert!(!out.join("verified.json").exists());
    }
}
