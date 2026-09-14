use provium::methods::{Crate, Literal};
use std::{
    fs,
    path::{Path, PathBuf},
    sync::atomic::{AtomicUsize, Ordering},
};
static NEXT: AtomicUsize = AtomicUsize::new(0);
struct Work(PathBuf);
impl Work {
    fn new() -> Self {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("artifacts")
            .join(format!(
                "method-tests-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
        fs::create_dir_all(&dir).unwrap();
        Self(dir)
    }
    fn source(&self, text: &str) -> PathBuf {
        let p = self.0.join("lib.rs");
        fs::write(&p, text).unwrap();
        p
    }
}
impl Drop for Work {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
const SOURCE:&str="struct State {dirty:bool, from:Option<u64>, unrelated:bool} struct Ready<'a>{node:&'a mut State} impl Ready<'_>{fn persisted(self){self.node.dirty=false;self.node.from=None;}}";

#[test]
fn lowers_every_statement_and_resolves_field_types_from_the_crate() {
    let w = Work::new();
    let krate = Crate::load(&w.source(SOURCE)).unwrap();
    let method = krate.lower("Ready::persisted").unwrap();
    assert_eq!(method.writes.len(), 2);
    assert_eq!(method.writes[0].path, ["node", "dirty"]);
    assert_eq!(method.writes[0].rust_type, "bool");
    assert!(matches!(method.writes[0].literal, Literal::Boolean(false)));
    assert_eq!(method.writes[1].rust_type, "Option < u64 >");
    assert!(matches!(method.writes[1].literal, Literal::Absent));
    let extra = SOURCE.replace(
        "self.node.from=None;",
        "self.node.from=None;self.node.unrelated=true;",
    );
    assert_eq!(
        Crate::load(&w.source(&extra))
            .unwrap()
            .lower("Ready::persisted")
            .unwrap()
            .writes
            .len(),
        3
    );
}

#[test]
fn complete_method_rejects_hidden_effects_and_context_changes() {
    let w = Work::new();
    for source in [
        SOURCE.replace("self.node.from=None;", "self.node.from=None;self.flush();"),
        SOURCE.replace(
            "self.node.dirty=false;",
            "let alias=&mut self.node;alias.dirty=false;",
        ),
        SOURCE.replace(
            "self.node.from=None;",
            "if self.node.dirty {self.node.from=None;}",
        ),
        format!(
            "{SOURCE} impl Drop for Ready<'_>{{fn drop(&mut self){{self.node.unrelated=true;}}}}"
        ),
        SOURCE.replace("Option<u64>", "Option<Payload>"),
        SOURCE.replace("fn persisted", "#[cfg(any())] fn persisted"),
        SOURCE.replace("dirty:bool", "#[cfg(any())] dirty:bool"),
        SOURCE.replace("struct State", "#[derive(Custom)] struct State"),
        format!("#![cfg(any())]\n{SOURCE}"),
        format!("enum Option<T>{{None,Some(T)}} {SOURCE}"),
        SOURCE.replace("struct Ready<'a>", "struct Ready<'a, bool>"),
        format!("use other::Node as State;{SOURCE}"),
        format!("macro_rules! effects {{ () => {{}} }} {SOURCE}"),
    ] {
        let result = Crate::load(&w.source(&source)).and_then(|k| k.lower("Ready::persisted"));
        assert!(result.is_err(), "accepted {source}");
    }
}

#[test]
fn owned_receivers_cannot_silently_drop_payloads() {
    let w = Work::new();
    let src = "struct State {flag:bool} impl State{fn clear(self){self.flag=false;}}";
    assert!(Crate::load(&w.source(src))
        .unwrap()
        .lower("State::clear")
        .unwrap_err()
        .contains("potentially dropping fields"));
}

#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn kernel_checks_complete_methods_and_rejects_a_changed_postcondition() {
    let w = Work::new();
    w.source(SOURCE);
    let proofs="import Generated\nopen Provium.State\ntheorem cleared (s : Store α) : Subject.Ready_persisted s [\"node\",\"dirty\"] = .boolean false := by simp [Subject.Ready_persisted, put]\n";
    fs::write(w.0.join("Proofs.lean"), proofs).unwrap();
    let config = serde_json::json!({"crate_root":"lib.rs","namespace":"Subject","methods":["Ready::persisted"],"proofs":"Proofs.lean","obligations":[{"theorem":"cleared","function":"Ready_persisted"}]});
    let path = w.0.join("project.json");
    fs::write(&path, config.to_string()).unwrap();
    let out = w.0.join("out");
    provium::methods::verify(&path, &out).unwrap();
    w.source(&SOURCE.replace("self.node.dirty=false", "self.node.dirty=true"));
    let error = provium::methods::verify(&path, &out).unwrap_err();
    assert!(error.contains("Lean rejected Proofs.lean"), "{error}");
    assert!(!out.join("verified.json").exists());
    w.source(&SOURCE.replace("self.node.from=None;", "self.node.from=None;self.flush();"));
    fs::write(out.join("verified.json"), "stale").unwrap();
    assert!(provium::methods::verify(&path, &out)
        .unwrap_err()
        .contains("unsupported complete-method statement"));
    assert!(!out.join("verified.json").exists());
}

#[test]
fn field_effects_agree_with_executing_the_original_rust_body() {
    use std::process::Command;
    let w = Work::new();
    let source = w.source(SOURCE);
    let method = Crate::load(&source)
        .unwrap()
        .lower("Ready::persisted")
        .unwrap();
    let main = r#"
fn main() {
    for dirty in [false,true] {
        for from in [None,Some(0),Some(u64::MAX)] {
            for unrelated in [false,true] {
                let mut state=State{dirty,from,unrelated};
                Ready{node:&mut state}.persisted();
                println!("{}|{:?}|{}",state.dirty,state.from,state.unrelated);
            }
        }
    }
}
"#;
    fs::write(&source, format!("{SOURCE}\n{main}")).unwrap();
    let binary = w.0.join("native");
    let built = Command::new("rustc")
        .args(["--edition=2021", "-C", "overflow-checks=yes"])
        .arg(&source)
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
    let mut expected = String::new();
    for initial_dirty in [false, true] {
        for initial_from in [None, Some(0), Some(u64::MAX)] {
            for unrelated in [false, true] {
                let mut dirty = initial_dirty;
                let mut from = initial_from;
                for write in &method.writes {
                    match (write.path.last().unwrap().as_str(), &write.literal) {
                        ("dirty", Literal::Boolean(value)) => dirty = *value,
                        ("from", Literal::Absent) => from = None,
                        _ => panic!("unexpected extracted write"),
                    }
                }
                expected.push_str(&format!("{dirty}|{from:?}|{unrelated}\n"));
            }
        }
    }
    assert_eq!(String::from_utf8(actual.stdout).unwrap(), expected);
}

#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn changing_jarl_acknowledgment_breaks_the_kernel_checked_contract() {
    let w = Work::new();
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    fs::create_dir(w.0.join("src")).unwrap();
    for file in fs::read_dir(root.join("../jarl/src")).unwrap() {
        let file = file.unwrap();
        if file.path().extension().is_some_and(|e| e == "rs") {
            fs::copy(file.path(), w.0.join("src").join(file.file_name())).unwrap();
        }
    }
    fs::copy(root.join("../jarl/README.md"), w.0.join("README.md")).unwrap();
    let ready = w.0.join("src/ready.rs");
    let original = fs::read_to_string(&ready).unwrap();
    assert!(original.contains("self.node.dirty = false;"));
    fs::write(
        &ready,
        original.replace("self.node.dirty = false;", "self.node.dirty = true;"),
    )
    .unwrap();
    let mut project: serde_json::Value =
        serde_json::from_slice(&fs::read(root.join("examples/jarl-methods/project.json")).unwrap())
            .unwrap();
    project["crate_root"] = "src/lib.rs".into();
    fs::copy(
        root.join("examples/jarl-methods/Proofs.lean"),
        w.0.join("Proofs.lean"),
    )
    .unwrap();
    let config = w.0.join("project.json");
    fs::write(&config, project.to_string()).unwrap();
    let error = provium::methods::verify(&config, &w.0.join("out")).unwrap_err();
    assert!(error.contains("Lean rejected Proofs.lean"), "{error}");
}

#[test]
fn field_resolution_does_not_confuse_foreign_and_local_structs() {
    let w = Work::new();
    let root = w.source("struct Range {start:Option<u64>} mod child;");
    fs::write(w.0.join("child.rs"),"use core::ops::Range; struct Ready<'a>{ node: &'a mut Range<Option<u64>> } impl Ready<'_>{fn persisted(self){self.node.start=None;}}").unwrap();
    let error = Crate::load(&root)
        .unwrap()
        .lower("child::Ready::persisted")
        .unwrap_err();
    assert!(error.contains("not resolved"), "{error}");
    fs::write(w.0.join("child.rs"),"use crate::Range; struct Ready<'a>{ node: &'a mut Range } impl Ready<'_>{fn persisted(self){self.node.start=None;}}").unwrap();
    assert!(Crate::load(&root)
        .unwrap()
        .lower("child::Ready::persisted")
        .is_ok());
}
