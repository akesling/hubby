use std::path::Path;

#[test]
fn independent_provider_dependency_graph_is_resolved_offline() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let report = provium::cargo_subject::inspect(provium::cargo_subject::Request {
        manifest: root.join("Cargo.toml"),
        target: "host".into(),
        features: vec![],
        no_default_features: false,
    })
    .unwrap();
    assert_ne!(report.request.target, "host");
    assert!(report
        .packages
        .iter()
        .any(|p| p.name == "syn" && p.source.is_some()));
    assert!(report.packages.iter().all(|p| p.name != "jarl"));
    assert!(report
        .packages
        .iter()
        .any(|p| p.targets.as_array().unwrap().iter().any(|t| t["kind"]
            .as_array()
            .unwrap()
            .iter()
            .any(|k| k == "proc-macro"))));
    for package in &report.packages {
        for dependency in package
            .normal_dependencies
            .iter()
            .chain(&package.build_dependencies)
        {
            assert!(report.packages.iter().any(|p| &p.id == dependency));
        }
    }
    assert!(report
        .limitations
        .iter()
        .any(|s| s.contains("cfg expansion")));
}
