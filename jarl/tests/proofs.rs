//! Jarl owns these contracts; Provium is the reusable verification dependency.
use std::{
    fs,
    path::{Path, PathBuf},
    sync::atomic::{AtomicUsize, Ordering},
};
static NEXT: AtomicUsize = AtomicUsize::new(0);
struct Work(PathBuf);
impl Work {
    fn new() -> Self {
        let path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("artifacts")
            .join(format!(
                "proof-test-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }
    fn write(&self, name: &str, text: &str) -> PathBuf {
        let p = self.0.join(name);
        fs::write(&p, text).unwrap();
        p
    }
    fn source(&self, text: &str) -> PathBuf {
        self.write("lib.rs", text)
    }
    fn out(&self) -> PathBuf {
        self.0.join("out")
    }
}
impl Drop for Work {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn invariants() {
    provium::assert_proofs!("proofs");
}

#[test]
fn source_coverage_review_is_current() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let report = provium::coverage::audit(
        root,
        Path::new("src/lib.rs"),
        &root.join("proofs/coverage.json"),
    )
    .expect("review changed Jarl source and update its coverage ledger");
    println!(
        "{} inventoried items; {} with declared component evidence; full proof remains open",
        report.items, report.component_items
    );
}

#[test]
fn cargo_subject_keeps_proof_tools_out_of_the_runtime_graph() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let mut request: provium::cargo_subject::Request =
        serde_json::from_slice(&fs::read(root.join("proofs/builds.json")).unwrap()).unwrap();
    request.manifest = root.join("proofs").join(request.manifest);
    let report =
        provium::cargo_subject::write(request, &root.join("artifacts/provium/build-profile"))
            .unwrap();
    assert_eq!(
        report.packages.len(),
        1,
        "Jarl must retain its dependency-free runtime graph"
    );
    assert_eq!(report.packages[0].name, "jarl");
    assert!(report.packages[0].normal_dependencies.is_empty());
    assert!(report.packages[0].build_dependencies.is_empty());
    assert!(report.target_cfg.contains("target_pointer_width"));
    assert!(report
        .workspace_inputs
        .keys()
        .any(|p| p.ends_with("Cargo.lock")));
}

#[path = "proof_cases/capacity.rs"]
mod capacity;
#[path = "proof_cases/lean.rs"]
mod consensus;
#[path = "proof_cases/scalar_methods.rs"]
mod election;
#[path = "proof_cases/initialization.rs"]
mod initialization;
#[path = "proof_cases/queries.rs"]
mod input_gating;
#[path = "proof_cases/arrays.rs"]
mod membership;
#[path = "proof_cases/methods.rs"]
mod persistence;

#[path = "proof_cases/storage.rs"]
mod storage;

#[path = "proof_cases/boundary.rs"]
mod boundary;

#[path = "proof_cases/message_dispatch.rs"]
mod message_dispatch;

#[path = "proof_cases/message_validation.rs"]
mod message_validation;

#[path = "proof_cases/replication_contract.rs"]
mod replication_contract;

#[test]
fn specification_witnesses_are_kernel_checked() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let report = provium::verify_project(
        &root.join("proofs/specification/project.json"),
        &root.join("artifacts/provium/m0-specification"),
    )
    .unwrap();
    assert!(report.details.contains("no source correspondence claim"));
}

#[test]
fn m0_build_profiles_account_for_host_32_bit_and_bare_metal() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let matrix_bytes = fs::read(root.join("proofs/build-matrix.json")).unwrap();
    let matrix: serde_json::Value = serde_json::from_slice(&matrix_bytes).unwrap();
    assert_eq!(matrix["schema"], 1);
    let profiles = matrix["profiles"].as_array().unwrap();
    assert_eq!(profiles.len(), 8);
    let coverage: provium::coverage::Ledger =
        serde_json::from_slice(&fs::read(root.join("proofs/coverage.json")).unwrap()).unwrap();
    let mut ids = std::collections::BTreeSet::new();
    for profile in profiles {
        let id = profile["id"].as_str().unwrap();
        assert!(ids.insert(id));
        assert!(coverage.build_profiles.contains_key(id));
        let mut request: provium::cargo_subject::Request =
            serde_json::from_value(profile["subject"].clone()).unwrap();
        assert_eq!(
            id,
            format!(
                "{}-{}-{}",
                request.target,
                profile["subject"]["profile"].as_str().unwrap(),
                profile["subject"]["panic"].as_str().unwrap()
            )
        );
        request.manifest = root.join("proofs").join(request.manifest);
        let output = root.join("artifacts/provium/m0-builds").join(id);
        let report = provium::cargo_subject::write(request, &output).unwrap();
        let width = profile["usize_bits"].as_u64().unwrap();
        assert!(report
            .target_cfg
            .lines()
            .any(|l| l == format!("target_pointer_width=\"{width}\"")));
        let panic = profile["subject"]["panic"].as_str().unwrap();
        assert!(report
            .target_cfg
            .lines()
            .any(|l| l == format!("panic=\"{panic}\"")));
        let debug = profile["subject"]["profile"] == "dev";
        assert_eq!(
            report.target_cfg.lines().any(|l| l == "debug_assertions"),
            debug
        );
        assert_eq!(report.packages.len(), 1);
        assert_eq!(report.packages[0].edition, "2021");
        assert_eq!(report.packages[0].name, "jarl");
        assert!(report.packages[0].normal_dependencies.is_empty());
        assert!(report.packages[0].build_dependencies.is_empty());
        fs::write(output.join("scope.json"), serde_json::to_vec_pretty(&serde_json::json!({
            "kind":"requested_build_accounting", "compiled":false,
            "matrix_sha256":provium::project::hash(&matrix_bytes),
            "coverage_sha256":provium::project::hash(fs::read(root.join("proofs/coverage.json")).unwrap()),
            "limitation":"Target cfg inspection does not require an installed target library and is not build or proof evidence. Effective Cargo invocations and ambient configuration remain P01."
        })).unwrap()).unwrap();
    }
    assert_eq!(ids.len(), coverage.build_profiles.len());
    for target in ["host", "wasm32-unknown-unknown", "thumbv7em-none-eabi"] {
        assert!(profiles.iter().any(|p| p["subject"]["target"] == target));
    }
    let assumptions: std::collections::BTreeSet<_> = coverage.assumptions.keys().cloned().collect();
    assert_eq!(assumptions, (1..=10).map(|i| format!("A{i:02}")).collect());
}

#[test]
fn m0_native_genesis_witnesses_match_the_engine_capacity_boundary() {
    use jarl::{Cluster, ClusterState, Config, Error, Id, Membership, Node, Settings, State};
    let fixed = Node::<u64, u64, 1, 1>::new(Config::new(Id(0), [Id(0)]), State::new());
    assert!(fixed.is_ok(), "fixed-engine safety includes capacity one");
    let membership = Membership::<1>::new(&[Id(0)], &[]).unwrap();
    let dynamic = Cluster::<u64, u64, 1, 4>::new(
        Settings::default(),
        ClusterState::new(Id(0), membership).unwrap(),
    );
    assert!(dynamic.is_ok());
    let too_small = Cluster::<u64, u64, 1, 1>::new(
        Settings::default(),
        ClusterState::new(Id(0), membership).unwrap(),
    );
    assert!(matches!(too_small, Err(Error::Config)));
    assert!(matches!(Membership::<1>::new(&[], &[]), Err(Error::Config)));
    assert!(matches!(
        Membership::<2>::new(&[Id(0), Id(0)], &[]),
        Err(Error::Config)
    ));
}

#[test]
fn m0_review_binding_matches_the_specification_and_scope() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let review: serde_json::Value =
        serde_json::from_slice(&fs::read(root.join("proofs/m0-review.json")).unwrap()).unwrap();
    assert_eq!(review["schema"], 1);
    assert_eq!(review["review_kind"], "implementation_self_review");
    assert_eq!(review["whole_program_proved"], false);
    let inputs = review["inputs"].as_object().unwrap();
    let required = [
        "Cargo.toml",
        "../Cargo.toml",
        "../Cargo.lock",
        "proofs/CORRECTNESS_PLAN.md",
        "proofs/M0.md",
        "proofs/coverage.json",
        "proofs/build-matrix.json",
        "proofs/specification/project.json",
        "proofs/specification/Model.lean",
        "scripts/verify-m0.sh",
    ];
    assert_eq!(inputs.len(), required.len());
    for path in required {
        assert_eq!(inputs[path], provium::project::hash(fs::read(root.join(path)).unwrap()),
            "{path} changed: review its M0 scope and theorem statements before updating m0-review.json");
    }
    let ledger: provium::coverage::Ledger =
        serde_json::from_slice(&fs::read(root.join("proofs/coverage.json")).unwrap()).unwrap();
    let coverage_ids: std::collections::BTreeSet<_> = ledger
        .entries
        .values()
        .flat_map(|entry| &entry.requirements)
        .filter(|id| id.starts_with('C'))
        .cloned()
        .collect();
    assert_eq!(coverage_ids, (1..=12).map(|i| format!("C{i:02}")).collect());
}

#[test]
fn m1_actual_cargo_compilation_is_bound_to_original_sources() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let mut request: provium::cargo_subject::Request =
        serde_json::from_slice(&fs::read(root.join("proofs/builds.json")).unwrap()).unwrap();
    request.manifest = root.join("proofs").join(request.manifest);
    let report =
        provium::cargo_capture::capture(request, &root.join("artifacts/provium/m1-capture-host"))
            .unwrap();
    assert_eq!(
        report.source_inventory,
        provium::coverage::inventory(root, Path::new("src/lib.rs")).unwrap()
    );
    assert_eq!(report.subject.packages.len(), 1);
    assert_eq!(report.subject.packages[0].name, "jarl");
    assert!(!report.semantic_preservation_proved);
    assert!(report.invocations.iter().any(|i| i
        .arguments
        .windows(2)
        .any(|pair| pair[0] == "--crate-name" && pair[1] == "jarl")));
}

#[test]
fn m1_write_suffix_offset_is_inspected_from_original_rust() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let source = provium::methods::Crate::load(&root.join("src/lib.rs")).unwrap();
    let offset = source.inspect_suffix_offset("state::State::write").unwrap();
    assert_eq!(offset.length, ["len"]);
    assert_eq!(offset.base_method, "state::State::base");
    assert_eq!(offset.bias, 1);
    let method = source.lower("state::State::write").unwrap();
    let view = method.view.unwrap();
    assert_eq!(
        view.output_fields,
        ["hard", "snapshot", "truncate_from", "entries"]
    );
    assert_eq!(view.slots, ["entries"]);
    let entries = source
        .lower("ready::Write::entries")
        .unwrap()
        .iteration
        .unwrap();
    assert!(entries.whole);
    assert_eq!(entries.slots, ["entries"]);
    // A truncating cast at 2^32 would incorrectly select a prefix here.
    assert_eq!(
        offset.evaluate(32, 7, 0, Some((1u64 << 32) + 1)).unwrap(),
        7
    );
    assert_eq!(offset.evaluate(64, 7, 10, Some(9)).unwrap(), 0);
    assert_eq!(offset.evaluate(64, 7, 10, None).unwrap(), 7);
}

#[path = "proof_cases/storage_view.rs"]
mod storage_view;

#[path = "proof_cases/quorum_callbacks.rs"]
mod quorum_callbacks;
