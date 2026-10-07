use provium::methods::{
    constructors::{Capacity, Initial},
    Crate,
};
use std::{
    fs,
    path::{Path, PathBuf},
    sync::atomic::{AtomicUsize, Ordering},
};
static NEXT: AtomicUsize = AtomicUsize::new(0);
struct Source(PathBuf);
impl Source {
    fn new(text: &str) -> Self {
        let root = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("artifacts")
            .join(format!(
                "constructor-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
        fs::create_dir_all(&root).unwrap();
        fs::write(root.join("lib.rs"), text).unwrap();
        Self(root)
    }
    fn lower(&self) -> Result<provium::methods::Method, String> {
        Crate::load(&self.0.join("lib.rs"))?.lower("State::new")
    }
}
impl Drop for Source {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
const SOURCE: &str = r#"
#[derive(Default)] struct Header { term:u64, dirty:bool, vote:Option<u64> }
struct State<T,const N:usize> { header:Header, entries:[Option<T>;N], len:usize }
impl<T,const CAP:usize> State<T,CAP> {
    fn new()->Self { Self { header:Header::default(),entries:core::array::from_fn(|_|None),len:0 } }
}
"#;
#[test]
fn original_const_substitution_and_derived_fields_are_explicit() {
    let source = Source::new(SOURCE);
    let method = source.lower().unwrap();
    let c = method.constructor.unwrap();
    assert_eq!(c.constants, ["CAP"]);
    assert_eq!(c.fields.len(), 5);
    assert!(c.fields.iter().any(|f| f.path == ["header", "term"]
        && matches!(&f.value,Initial::Unsigned{rust_type,value:0} if rust_type=="u64")));
    assert!(c
        .fields
        .iter()
        .any(|f| matches!(&f.value,Initial::EmptySlots(Capacity::Parameter(p)) if p=="CAP")));
}
#[test]
fn hidden_initialization_effects_and_shadowed_builtins_are_rejected() {
    for source in [
        SOURCE.replace("Self { header", "panic!(\"effect\"); Self { header"),
        SOURCE.replace("|_|None", "|_|{external();None}"),
        SOURCE.replace("#[derive(Default)]", ""),
        format!("{SOURCE} impl Header{{fn default()->Self{{panic!()}}}}"),
        format!("{SOURCE} trait Default {{}}"),
        format!("{SOURCE} mod core;"),
        SOURCE.replace("len:0", "len:external()"),
        // rustc accepts and wraps these under `allow(overflowing_literals)`.
        "#![allow(overflowing_literals)] struct State { v:u8 } impl State { fn new()->Self { Self { v:300 } } }".to_string(),
        // Unconfigured crates use the smallest Rust usize width.
        SOURCE.replace("len:0", "len:65536"),
        SOURCE.replace("len:0", "len:0u64"),
    ] {
        assert!(Source::new(&source).lower().is_err(), "accepted {source}");
    }
    let shadow = "struct State<u64>{value:u64} impl State<u8>{fn new()->Self{Self{value:0}}}";
    assert!(Source::new(shadow)
        .lower()
        .unwrap_err()
        .contains("shadows a builtin type"));
}

#[test]
fn native_construction_matches_explicit_initial_field_ir() {
    let source = Source::new(SOURCE);
    let method = source.lower().unwrap();
    let c = method.constructor.unwrap();
    let field = |path: &[&str]| {
        &c.fields
            .iter()
            .find(|f| f.path.iter().map(String::as_str).eq(path.iter().copied()))
            .unwrap()
            .value
    };
    let Initial::Unsigned { value: term, .. } = field(&["header", "term"]) else {
        panic!()
    };
    let Initial::Unsigned { value: len, .. } = field(&["len"]) else {
        panic!()
    };
    let Initial::Boolean(dirty) = field(&["header", "dirty"]) else {
        panic!()
    };
    assert!(matches!(field(&["header", "vote"]), Initial::Absent));
    let Initial::EmptySlots(capacity) = field(&["entries"]) else {
        panic!()
    };
    let mut expected = String::new();
    for size in [0, 1, 4, 16] {
        let capacity = match capacity {
            Capacity::Fixed(n) => *n,
            Capacity::Parameter(p) => {
                assert_eq!(p, "CAP");
                size
            }
        };
        expected.push_str(&format!("{term} {dirty} false {len} {capacity} true\n"));
    }
    let runner = format!(
        r#"{SOURCE}
fn check<const N:usize>(){{let s=State::<u64,N>::new();println!("{{}} {{}} {{}} {{}} {{}} {{}}",s.header.term,s.header.dirty,s.header.vote.is_some(),s.len,s.entries.len(),s.entries.iter().all(Option::is_none));}}
fn main(){{check::<0>();check::<1>();check::<4>();check::<16>();}}
"#
    );
    let main = source.0.join("main.rs");
    fs::write(&main, runner).unwrap();
    let binary = source.0.join("native");
    let output = std::process::Command::new("rustc")
        .arg("--edition=2021")
        .arg(main)
        .arg("-o")
        .arg(&binary)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let output = std::process::Command::new(binary).output().unwrap();
    assert!(output.status.success());
    assert_eq!(String::from_utf8(output.stdout).unwrap(), expected);
}

#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn independent_constructor_contract_rejects_source_drift() {
    let source = Source::new(SOURCE);
    fs::write(
        source.0.join("Proofs.lean"),
        r#"import Generated
open Provium.State
theorem empty (sizes : String → Nat) : Subject.State_new sizes ["len"] = .unsigned "usize" 0 := by
  simp [Subject.State_new, Subject.State_new_ir, initializeFields, initialCell]
"#,
    )
    .unwrap();
    let config = source.0.join("project.json");
    fs::write(&config,r#"{"crate_root":"lib.rs","namespace":"Subject","methods":["State::new"],"proofs":"Proofs.lean","obligations":[{"theorem":"empty","function":"State_new"}]}"#).unwrap();
    let out = source.0.join("out");
    provium::methods::verify(&config, &out).unwrap();
    fs::write(source.0.join("lib.rs"), SOURCE.replace("len:0", "len:1")).unwrap();
    let error = provium::methods::verify(&config, &out).unwrap_err();
    assert!(error.contains("Lean rejected Proofs.lean"), "{error}");
    assert!(!out.join("verified.json").exists());
}
