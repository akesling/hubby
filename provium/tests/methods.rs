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
        SOURCE.replace("self.node.from=None;", "if self.node.dirty {self.flush();}"),
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

#[test]
fn branches_retain_both_effects_and_reject_untyped_conditions() {
    let w = Work::new();
    let src = SOURCE.replace("self.node.dirty=false;self.node.from=None;", "if self.node.dirty && !false {self.node.dirty=false;} else if self.node.unrelated {self.node.from=None;} else {self.node.unrelated=true;} self.node.from=None;");
    let m = Crate::load(&w.source(&src))
        .unwrap()
        .lower("Ready::persisted")
        .unwrap();
    assert_eq!(m.writes.len(), 4);
    assert!(matches!(
        m.body[0],
        provium::methods::Statement::Branch { .. }
    ));
    assert_eq!(m.body.len(), 2);
    for bad in [
        src.replace("self.node.dirty && !false", "self.node.from"),
        src.replace("self.node.unrelated=true;", "self.flush();"),
        src.replace("self.node.dirty && !false", "self.check()"),
        src.replace("self.node.dirty && !false", "{self.node.dirty=false;true}"),
    ] {
        assert!(
            Crate::load(&w.source(&bad))
                .unwrap()
                .lower("Ready::persisted")
                .is_err(),
            "accepted {bad}"
        );
    }
}

#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn branches_agree_with_native_rust_and_kernel_checks_order_and_frame() {
    use std::process::Command;
    let w = Work::new();
    let source = SOURCE.replace(
        "self.node.dirty=false;self.node.from=None;",
        "if self.node.dirty {self.node.unrelated=true;} else {self.node.unrelated=false;} if self.node.unrelated && !false {self.node.dirty=false;} else {self.node.dirty=true;} self.node.from=None;",
    );
    let source = source.replace("fn persisted(self)", "fn persisted(mut self)").replace(
        "if self.node.dirty {self.node.unrelated=true;} else {self.node.unrelated=false;}",
        "self.prepare();",
    ) + " impl Ready<'_>{fn prepare(&mut self){if self.node.dirty {self.node.unrelated=true;} else {self.node.unrelated=false;}}}";
    let path = w.source(&source);
    let main = r#"
fn main() {
 for dirty in [false,true] {
  for unrelated in [false,true] {
   let mut state=State{dirty,from:Some(7),unrelated};
   Ready{node:&mut state}.persisted();
   println!("{} {}",state.dirty,state.unrelated);
  }
 }
}
"#;
    fs::write(&path, format!("{source}\n{main}")).unwrap();
    let binary = w.0.join("native");
    let built = Command::new("rustc")
        .args(["--edition=2021", "-C", "overflow-checks=yes"])
        .arg(&path)
        .arg("-o")
        .arg(&binary)
        .output()
        .unwrap();
    assert!(
        built.status.success(),
        "{}",
        String::from_utf8_lossy(&built.stderr)
    );
    let native = Command::new(binary).output().unwrap();
    assert!(native.status.success());
    let actual = String::from_utf8(native.stdout).unwrap();
    w.source(&source);
    let mut proofs = String::from("import Generated\nopen Provium.State\n");
    for (i, ((dirty, unrelated), output)) in [false, true]
        .into_iter()
        .flat_map(|d| [false, true].map(move |u| (d, u)))
        .zip(actual.lines())
        .enumerate()
    {
        let values: Vec<_> = output.split_whitespace().collect();
        assert_eq!(values.len(), 2);
        proofs.push_str(&format!("example : let initial : Store Unit := fun key => if key = [\"node\",\"dirty\"] then .boolean {dirty} else if key = [\"node\",\"unrelated\"] then .boolean {unrelated} else .other (); (Subject.Ready_persisted initial [\"node\",\"dirty\"], Subject.Ready_persisted initial [\"node\",\"unrelated\"]) = (.boolean {}, .boolean {}) := by decide\n-- Native case {i}\n", values[0], values[1]));
    }
    assert_eq!(actual.lines().count(), 4);
    proofs.push_str(
        r#"
theorem branch_order (s : Store α) (d : Bool) (h : s ["node","dirty"] = .boolean d) :
 Subject.Ready_persisted s ["node","dirty"] = .boolean (!d) ∧
 Subject.Ready_persisted s ["node","unrelated"] = .boolean d := by
 cases d <;> simp [Subject.Ready_persisted, evalCondition, put, h]
theorem frame (s : Store α) (key : Path)
 (h : key ∉ writes Subject.Ready_persisted_ir) :
 Subject.Ready_persisted s key = s key := by
 rw [← Subject.Ready_persisted_correspondence]
 exact execute_frame _ _ _ h
"#,
    );
    fs::write(w.0.join("Proofs.lean"), proofs).unwrap();
    let config = serde_json::json!({"crate_root":"lib.rs","namespace":"Subject","methods":["Ready::persisted"],"proofs":"Proofs.lean","obligations":[{"theorem":"branch_order","function":"Ready_persisted"},{"theorem":"frame","function":"Ready_persisted"}]});
    let config_path = w.0.join("project.json");
    fs::write(&config_path, config.to_string()).unwrap();
    let out = w.0.join("out");
    provium::methods::verify(&config_path, &out).unwrap();
    w.source(&source.replace(
        "if self.node.unrelated && !false",
        "if !self.node.unrelated && !false",
    ));
    let error = provium::methods::verify(&config_path, &out).unwrap_err();
    assert!(error.contains("Lean rejected Proofs.lean"), "{error}");
    assert!(!out.join("verified.json").exists());
}

#[test]
fn calls_are_resolved_inlined_and_bounded_without_opaque_effects() {
    let w = Work::new();
    let source = SOURCE
        .replace("fn persisted(self)", "fn persisted(mut self)")
        .replace("self.node.dirty=false;", "self.clear();")
        + " impl Ready<'_>{fn clear(&mut self){self.node.dirty=false;}}";
    let method = Crate::load(&w.source(&source))
        .unwrap()
        .lower("Ready::persisted")
        .unwrap();
    assert_eq!(method.writes.len(), 2);
    assert!(
        matches!(&method.body[0], provium::methods::Statement::Call {method,..} if method == "Ready::clear")
    );
    for bad in [
        source.replace("self.node.dirty=false;", "self.clear();"),
        source.replace("self.node.dirty=false;", "self.persisted();"),
        source.replace("fn clear(&mut self)", "fn clear(self)"),
        source.replace("self.clear();", "self.clear::<u64>();"),
        source.replace("self.clear();", "self.clear(false);"),
        source.replace("self.clear();", "self.node.clear();"),
        source.replace("self.node.dirty=false;", "external();"),
    ] {
        assert!(
            Crate::load(&w.source(&bad))
                .unwrap()
                .lower("Ready::persisted")
                .is_err(),
            "accepted {bad}"
        );
    }
    let mut explosive = String::from("struct State {flag:bool} impl State {");
    for i in 0..18 {
        explosive.push_str(&format!(
            "fn f{i}(&mut self){{self.f{}();self.f{}();}}",
            i + 1,
            i + 1
        ));
    }
    explosive.push_str("fn f18(&mut self){} }");
    let error = Crate::load(&w.source(&explosive))
        .unwrap()
        .lower("State::f0")
        .unwrap_err();
    assert!(error.contains("expansion exceeds budget"), "{error}");
}
