use super::Work;
use provium::project::verify;
use std::{fs, path::Path};
#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn jarl_source_mutations_break_the_actual_invariants() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let config: serde_json::Value = serde_json::from_str(
        &fs::read_to_string(root.join("proofs/consensus/project.json")).unwrap(),
    )
    .unwrap();
    let membership = fs::read_to_string(root.join("src/membership.rs")).unwrap();
    let node = fs::read_to_string(root.join("src/node.rs")).unwrap();
    for (file, from, to) in [
        // Control: the unmutated fixture must verify, or a fixture-level
        // failure would satisfy every mutation below.
        ("node.rs", "", ""),
        ("membership.rs", "count > total / 2", "count >= total / 2"),
        ("membership.rs", "new.min(old)", "new.max(old)"),
        ("node.rs", "commit.min(matched)", "commit.max(matched)"),
        (
            "node.rs",
            "id.term == self.state.hard.term",
            "id.term != self.state.hard.term",
        ),
        (
            "node.rs",
            "self.state.hard.commit = index;",
            "self.state.hard.commit = 0;",
        ),
    ] {
        let w = Work::new();
        let mut config = config.clone();
        w.write("membership.rs", &membership);
        w.write("node.rs", &node);
        let source = if file == "membership.rs" {
            &membership
        } else {
            &node
        };
        assert!(source.contains(from));
        w.write(file, &source.replace(from, to));
        for slice in config["slices"].as_array_mut().unwrap() {
            let filename = Path::new(slice["source"].as_str().unwrap())
                .file_name()
                .unwrap()
                .to_str()
                .unwrap()
                .to_owned();
            slice["source"] = filename.into();
        }
        w.write(
            "Proofs.lean",
            &fs::read_to_string(root.join("proofs/consensus/Proofs.lean")).unwrap(),
        );
        let p = w.write("project.json", &config.to_string());
        if from.is_empty() {
            verify(&p, &w.out()).unwrap();
            assert!(w.out().join("verified.json").exists());
            continue;
        }
        let error = verify(&p, &w.out()).unwrap_err();
        // A selector/compiler failure is not evidence that the invariant caught
        // the mutation. The changed source must reach the theorem checker.
        assert!(
            error.contains("Lean rejected Proofs.lean"),
            "mutation {from} -> {to}: {error}"
        );
        assert!(!w.out().join("verified.json").exists());
    }
}

#[test]
#[ignore = "requires Lean and wasm32 Rust target; scripts/verify.sh runs this"]
fn jarl_obligations_also_hold_for_32_bit_usize() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let base = root.join("proofs/consensus");
    let mut config: serde_json::Value =
        serde_json::from_slice(&fs::read(base.join("project.json")).unwrap()).unwrap();
    for slice in config["slices"].as_array_mut().unwrap() {
        slice["source"] = base
            .join(slice["source"].as_str().unwrap())
            .canonicalize()
            .unwrap()
            .display()
            .to_string()
            .into();
    }
    config["proofs"] = base.join("Proofs.lean").display().to_string().into();
    config["usize_bits"] = 32.into();
    config["rust_target"] = "wasm32-unknown-unknown".into();
    let w = Work::new();
    let p = w.write("project.json", &config.to_string());
    verify(&p, &w.out()).unwrap();
}
