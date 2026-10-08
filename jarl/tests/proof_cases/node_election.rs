use super::Work;
use std::{fs, path::Path};

#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn whole_body_election_timer_effects_reject_changed_bodies() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let w = Work::new();
    let mut project: serde_json::Value =
        serde_json::from_slice(&fs::read(root.join("proofs/node-election/project.json")).unwrap())
            .unwrap();
    fs::create_dir(w.0.join("src")).unwrap();
    for file in fs::read_dir(root.join("src")).unwrap() {
        let file = file.unwrap();
        if file.path().extension().is_some_and(|e| e == "rs") {
            fs::copy(file.path(), w.0.join("src").join(file.file_name())).unwrap();
        }
    }
    fs::copy(root.join("README.md"), w.0.join("README.md")).unwrap();
    project["crate_root"] = "src/lib.rs".into();
    project["proofs"] = root
        .join("proofs/node-election/Proofs.lean")
        .to_str()
        .unwrap()
        .into();
    w.cargo_build();
    project["cargo_build"] = "build.json".into();
    let config = w.write("project.json", &project.to_string());
    provium::methods::verify(&config, &w.out()).unwrap();
    let node = w.0.join("src/node.rs");
    let source = fs::read_to_string(&node).unwrap();
    for (from, to) in [
        (
            "        self.role = Role::Follower;\n        self.prevoting = None;\n        if leader",
            "        self.role = Role::Candidate;\n        self.prevoting = None;\n        if leader",
        ),
        (
            "        self.prevoting = None;\n        if leader.is_some()",
            "        if leader.is_some()",
        ),
        ("self.leader_age = 0;", "self.leader_age = 1;"),
        ("if leader.is_some() {", "if leader.is_none() {"),
        ("self.leader = leader;", "self.leader = None;"),
        ("sample ^= sample >> 31;", "sample ^= sample >> 30;"),
        (
            "self.config.election_ticks + sample % self.config.election_ticks",
            "self.config.election_ticks + sample % (self.config.election_ticks + 1)",
        ),
    ] {
        assert_eq!(source.matches(from).count(), 1, "{from}");
        fs::write(&node, source.replace(from, to)).unwrap();
        let error = provium::methods::verify(&config, &w.out()).unwrap_err();
        assert!(error.contains("Lean rejected Proofs.lean"), "{from}: {error}");
        assert!(!w.out().join("verified.json").exists());
    }
}
