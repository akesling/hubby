use super::Work;
use provium::{frontend::Compiler, ir, methods::Crate, project};
use std::{fs, path::Path, process::Command};
#[test]
fn jarl_complete_timer_body_agrees_with_native_rust() {
    let w = Work::new();
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let translation = Crate::load(&root.join("src/lib.rs"))
        .unwrap()
        .scalar_projections("node::Node::reset_election")
        .unwrap();
    let body = &translation.evidence.rust;
    let native = format!(
        r#"
struct Config {{election_ticks:u64}}
struct Node {{random:u64, elapsed:u64,election_deadline:u64,config:Config}}
impl Node {{{body}}}
fn main() {{
 for random in [0,1,u64::MAX/2,u64::MAX] {{
  for ticks in [1,2,100,1u64<<63] {{
   let mut node=Node{{random,elapsed:73,election_deadline:91,config:Config{{election_ticks:ticks}}}};
   node.reset_election();
   println!("{{}} {{}} {{}}",node.random,node.election_deadline,node.elapsed);
  }}
 }}
}}
"#
    );
    let source = w.source(&native);
    let binary = w.0.join("native");
    let built = Command::new("rustc")
        .args(["--edition=2021", "-C", "overflow-checks=yes"])
        .arg(source)
        .arg("-o")
        .arg(&binary)
        .output()
        .unwrap();
    assert!(
        built.status.success(),
        "{}",
        String::from_utf8_lossy(&built.stderr)
    );
    let actual = Command::new(binary).output().unwrap();
    assert!(actual.status.success());
    let functions = Compiler::parse(&translation.source, 64)
        .unwrap()
        .compile()
        .unwrap();
    let mut expected = String::new();
    for random in [0, 1, u64::MAX / 2, u64::MAX] {
        for ticks in [1, 2, 100, 1u64 << 63] {
            let args = [ticks, 73, 91, random].map(|value| ir::Value::UInt { bits: 64, value });
            let output = |field: &str| {
                let f = functions
                    .iter()
                    .find(|f| f.name == format!("node_Node_reset_election_{field}"))
                    .unwrap();
                let ir::Value::UInt { value, .. } = ir::run(f, &args, 64).unwrap() else {
                    panic!("nonuint")
                };
                value
            };
            expected.push_str(&format!(
                "{} {} {}\n",
                output("random"),
                output("election_deadline"),
                output("elapsed")
            ));
        }
    }
    assert_eq!(String::from_utf8(actual.stdout).unwrap(), expected);
}

#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn original_timer_mutations_break_successful_execution_contracts() {
    let w = Work::new();
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    fs::create_dir(w.0.join("src")).unwrap();
    for file in fs::read_dir(root.join("src")).unwrap() {
        let file = file.unwrap();
        if file.path().is_file() {
            fs::copy(file.path(), w.0.join("src").join(file.file_name())).unwrap();
        }
    }
    fs::copy(root.join("README.md"), w.0.join("README.md")).unwrap();
    let mut config: serde_json::Value =
        serde_json::from_slice(&fs::read(root.join("proofs/election/project.json")).unwrap())
            .unwrap();
    config["scalar_method"]["crate_root"] = "src/lib.rs".into();
    let config_path = w.0.join("project.json");
    fs::write(&config_path, config.to_string()).unwrap();
    fs::copy(
        root.join("proofs/election/Proofs.lean"),
        w.0.join("Proofs.lean"),
    )
    .unwrap();
    let path = w.0.join("src/node.rs");
    let original = fs::read_to_string(&path).unwrap();
    let out = w.0.join("out");
    project::verify(&config_path, &out).unwrap();
    for (from, to) in [
        ("self.elapsed = 0;", "self.elapsed = 1;"),
        (
            "sample % self.config.election_ticks",
            "sample / self.config.election_ticks",
        ),
        (
            "self.elapsed = 0;",
            "self.elapsed = 0; self.election_deadline = 0;",
        ),
    ] {
        assert!(original.contains(from));
        fs::write(&path, original.replace(from, to)).unwrap();
        let error = project::verify(&config_path, &out).unwrap_err();
        assert!(
            error.contains("Lean rejected Proofs.lean"),
            "{from} -> {to}: {error}"
        );
        assert!(!out.join("verified.json").exists());
    }
}

#[test]
#[ignore = "requires pinned Lean and installed wasm32 Rust target; scripts/verify.sh runs this"]
fn complete_timer_projections_also_verify_for_the_no_std_32_bit_target() {
    let w = Work::new();
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let mut config: serde_json::Value =
        serde_json::from_slice(&fs::read(root.join("proofs/election/project.json")).unwrap())
            .unwrap();
    config["scalar_method"]["crate_root"] = root.join("src/lib.rs").to_str().unwrap().into();
    config["proofs"] = root
        .join("proofs/election/Proofs.lean")
        .to_str()
        .unwrap()
        .into();
    config["usize_bits"] = 32.into();
    config["rust_target"] = "wasm32-unknown-unknown".into();
    let path = w.0.join("project.json");
    fs::write(&path, config.to_string()).unwrap();
    project::verify(&path, &w.0.join("out")).unwrap();
}
