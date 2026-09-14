use std::{path::Path, process::Command};

#[test]
fn all_external_rust_dependencies_come_from_crates_io() {
    let output = Command::new("cargo")
        .args(["metadata", "--locked", "--offline", "--format-version", "1"])
        .current_dir(env!("CARGO_MANIFEST_DIR"))
        .output()
        .expect("cargo metadata must run");
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let metadata: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    let manifest = Path::new(env!("CARGO_MANIFEST_DIR")).join("Cargo.toml");
    for package in metadata["packages"].as_array().unwrap() {
        if Path::new(package["manifest_path"].as_str().unwrap()) == manifest {
            continue;
        }
        assert_eq!(
            package["source"].as_str(),
            Some("registry+https://github.com/rust-lang/crates.io-index"),
            "{} must be a crates.io dependency, not a Git, path, or alternate-registry dependency",
            package["name"]
        );
    }
}

#[test]
fn proof_output_cannot_be_written_in_cargos_target_directory() {
    let error = provium::project::compile(
        Path::new("missing-project.json"),
        Path::new("target/proofs"),
    )
    .unwrap_err();
    assert!(error.contains("Cargo exclusively owns target/"), "{error}");
}
