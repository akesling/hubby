use provium::methods::Crate;
use std::{
    fs,
    path::PathBuf,
    sync::atomic::{AtomicUsize, Ordering},
};
static NEXT: AtomicUsize = AtomicUsize::new(0);
struct Work(PathBuf);
impl Work {
    fn new(source: &str) -> Self {
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("artifacts")
            .join(format!(
                "getters-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
        fs::create_dir_all(&path).unwrap();
        fs::write(path.join("lib.rs"), source).unwrap();
        Self(path)
    }
    fn lower(&self, method: &str) -> Result<provium::methods::Method, String> {
        Crate::load(&self.0.join("lib.rs"))?.lower(method)
    }
}
impl Drop for Work {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
const SOURCE: &str = r#"
#[derive(Clone,Copy)] struct Header { term:u64 }
struct State { hard:Header, backup:Header, dirty:bool, vote:Option<u64> }
impl State {
 fn hard(&self)->Header { self.hard }
 fn term(&self)->u64 { self.hard.term }
 fn dirty(&self)->bool { self.dirty }
 fn vote(&self)->Option<u64> { self.vote }
}
"#;

#[test]
fn copied_fields_retain_nested_places_and_concrete_copy_admission() {
    let w = Work::new(SOURCE);
    let hard = w.lower("State::hard").unwrap().getter.unwrap();
    assert_eq!(hard.path, ["hard"]);
    assert_eq!(hard.kind, "payload");
    assert!(hard.copy_declarations["Header"].contains("term : u64"));
    let term = w.lower("State::term").unwrap().getter.unwrap();
    assert_eq!(term.path, ["hard", "term"]);
    assert_eq!(
        term.source_place,
        ".field (.field (.receiver) \"hard\") \"term\""
    );
    assert_eq!(
        w.lower("State::dirty").unwrap().getter.unwrap().kind,
        "boolean"
    );
    assert_eq!(
        w.lower("State::vote").unwrap().getter.unwrap().kind,
        "optional"
    );
    for changed in [
        SOURCE.replace("Clone,Copy", "Clone"),
        SOURCE.replace("{ self.hard }", "{ external(); self.hard }"),
        SOURCE.replace("{ self.hard }", "{ self.hard.clone() }"),
        SOURCE.replace("fn hard(&self)", "fn hard(&mut self)"),
        SOURCE.replace("fn hard(&self)", "fn hard(self)"),
        SOURCE.replace("fn hard(&self)->Header", "fn hard(&self)->u64"),
    ] {
        assert!(
            Work::new(&changed).lower("State::hard").is_err(),
            "accepted {changed}"
        );
    }
    let generic = "struct State<T>{value:T} impl<T:Copy>State<T>{fn value(&self)->T{self.value}}";
    assert!(Work::new(generic).lower("State::value").is_err());
    let shadow = "#[derive(Clone,Copy)] struct i128 { x:u64 } struct State{value:i128} impl State{fn value(&self)->i128{self.value}}";
    assert!(Work::new(shadow).lower("State::value").is_err());
}

#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn copied_field_contracts_keep_source_paths_and_reject_source_drift() {
    let w = Work::new(SOURCE);
    fs::write(w.0.join("Proofs.lean"), r#"import Generated
open Provium.State
theorem hard_value (state : Store α) : Subject.State_hard state = state ["hard"] := rfl
theorem term_value (state : Store α) : Subject.State_term state = state ["hard", "term"] := rfl
theorem dirty_value (state : Store α) : Subject.State_dirty state = state ["dirty"] := rfl
theorem vote_value (state : Store α) : Subject.State_vote state = state ["vote"] := rfl
theorem source_copied (layout : Initialized.Layout) (heap : Initialized.Heap α) (state : Store α)
    (related : Initialized.Relates layout heap state) (declared : layout ["hard"] = some .payload) :
    Subject.State_hard state = state ["hard"] ∧
    FieldReads.readSourceMemory .payload Subject.State_hard_source_place layout heap = .ok (state ["hard"]) := by
  exact ⟨rfl, Subject.State_hard_source_refinement layout heap state related declared⟩
"#).unwrap();
    let obligations: Vec<_> = [
        ("hard_value", "State_hard"),
        ("term_value", "State_term"),
        ("dirty_value", "State_dirty"),
        ("vote_value", "State_vote"),
        ("source_copied", "State_hard"),
    ]
    .into_iter()
    .map(|(theorem, function)| serde_json::json!({"theorem":theorem,"function":function}))
    .collect();
    let config = w.0.join("project.json");
    fs::write(
        &config,
        serde_json::json!({"crate_root":"lib.rs", "namespace":"Subject",
        "methods":["State::hard","State::term","State::dirty","State::vote"],
        "proofs":"Proofs.lean","obligations":obligations})
        .to_string(),
    )
    .unwrap();
    let out = w.0.join("out");
    provium::methods::verify(&config, &out).unwrap();
    let report: serde_json::Value =
        serde_json::from_slice(&fs::read(out.join("verified.json")).unwrap()).unwrap();
    assert_eq!(report["copied_field_refinements"], 4);
    fs::write(
        w.0.join("lib.rs"),
        SOURCE.replace("{ self.hard }", "{ self.backup }"),
    )
    .unwrap();
    let error = provium::methods::verify(&config, &out).unwrap_err();
    assert!(error.contains("Lean rejected Proofs.lean"), "{error}");
    assert!(!out.join("verified.json").exists());
}

const BORROWED: &str = "struct State<T>{value:Option<T>,backup:Option<T>} impl<T> State<T>{fn value(&self)->Option<&T>{self.value.as_ref()}}";
#[test]
fn borrowed_fields_require_builtin_option_and_shared_elided_lifetimes() {
    let getter = Work::new(BORROWED)
        .lower("State::value")
        .unwrap()
        .getter
        .unwrap();
    assert!(getter.borrowed);
    assert_eq!(getter.path, ["value"]);
    assert!(getter.copy_declarations.is_empty());
    for changed in [
        BORROWED.replace("&self", "&mut self"),
        BORROWED.replace("Option<&T>", "Option<&mut T>"),
        BORROWED.replace("Option<&T>", "Option<&'static T>"),
        BORROWED.replace("as_ref()", "as_mut()"),
        BORROWED.replace("self.value.as_ref()", "external();self.value.as_ref()"),
        BORROWED.replace("Option<&T>", "Option<&u64>"),
        BORROWED.replace("as_ref()", "as_ref::<T>()"),
    ] {
        assert!(
            Work::new(&changed).lower("State::value").is_err(),
            "accepted {changed}"
        );
    }
}

#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn borrowed_field_contracts_retain_identity_and_reject_source_drift() {
    let w = Work::new(BORROWED);
    fs::write(w.0.join("Proofs.lean"), r#"import Generated
open Provium.State
theorem borrowed_none (owner ticket : Nat) (state : Store α) (absent : state ["value"] = .absent) :
    Subject.State_value owner ticket state = .ok none := by
  simp [Subject.State_value, Subject.State_value_ir, absent, FieldReads.Borrowed.select]
theorem borrowed_some (owner ticket : Nat) (state : Store α) (payload : α) (present : state ["value"] = .other payload) :
    Subject.State_value owner ticket state = .ok (some ⟨owner, ticket, ["value"]⟩) := by
  simp [Subject.State_value, Subject.State_value_ir, present, FieldReads.Borrowed.select]
"#).unwrap();
    let config = w.0.join("project.json");
    fs::write(
        &config,
        serde_json::json!({"crate_root":"lib.rs","namespace":"Subject",
        "methods":["State::value"],"proofs":"Proofs.lean","obligations":[
        {"theorem":"borrowed_none","function":"State_value"},
        {"theorem":"borrowed_some","function":"State_value"}]})
        .to_string(),
    )
    .unwrap();
    provium::methods::verify(&config, &w.0.join("out")).unwrap();
    let report: serde_json::Value =
        serde_json::from_slice(&fs::read(w.0.join("out/verified.json")).unwrap()).unwrap();
    assert_eq!(report["borrowed_field_refinements"], 1);
    assert_eq!(report["copied_field_refinements"], 0);
    fs::write(
        w.0.join("lib.rs"),
        BORROWED.replace("self.value.as_ref()", "self.backup.as_ref()"),
    )
    .unwrap();
    assert!(provium::methods::verify(&config, &w.0.join("changed")).is_err());
}

#[test]
fn native_borrowed_getter_preserves_location_and_payload_ownership() {
    let w = Work::new(BORROWED);
    let program = format!(
        r#"{BORROWED}
use std::sync::atomic::{{AtomicUsize,Ordering}};
static DROPS:AtomicUsize=AtomicUsize::new(0);
struct Payload(u64);
impl Drop for Payload{{fn drop(&mut self){{DROPS.fetch_add(1,Ordering::SeqCst);}}}}
fn main(){{
 let state=State{{value:Some(Payload(7)),backup:None}};
 let first=state.value().unwrap();
 let second=state.value().unwrap();
 assert!(std::ptr::eq(first,state.value.as_ref().unwrap()));
 assert!(std::ptr::eq(first,second));
 assert_eq!(second.0,7);
 assert_eq!(DROPS.load(Ordering::SeqCst),0);
 drop(state);
 assert_eq!(DROPS.load(Ordering::SeqCst),1);
 let empty:State<Payload>=State{{value:None,backup:None}};
 assert!(empty.value().is_none());
}}
"#
    );
    let source = w.0.join("native.rs");
    let binary = w.0.join("native");
    fs::write(&source, program).unwrap();
    let built = std::process::Command::new("rustc")
        .args(["--edition=2021", "-Adead_code"])
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
    assert!(std::process::Command::new(&binary)
        .status()
        .unwrap()
        .success());
    fs::write(&source, format!("{BORROWED} fn main(){{let r;{{let state=State{{value:Some(7),backup:None}};r=state.value();}}assert_eq!(r,Some(&7));}}")).unwrap();
    let rejected = std::process::Command::new("rustc")
        .args(["--edition=2021", "-Adead_code"])
        .arg(&source)
        .arg("-o")
        .arg(&binary)
        .output()
        .unwrap();
    assert!(!rejected.status.success());
    assert!(String::from_utf8_lossy(&rejected.stderr).contains("does not live long enough"));
}
