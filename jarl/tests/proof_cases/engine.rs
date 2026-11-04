use std::path::Path;

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
    ] {
        assert!(
            report.contains(&format!("PROVIUM_VERIFIED {theorem}")),
            "{report}"
        );
    }
    assert!(report.contains("Differential: 40 scenarios"), "{report}");
}
