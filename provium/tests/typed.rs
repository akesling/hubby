//! The typed backend: Rust items to ordinary Lean definitions.
use std::{
    fs,
    path::{Path, PathBuf},
    sync::atomic::{AtomicUsize, Ordering},
};

static NEXT: AtomicUsize = AtomicUsize::new(0);

struct Work(PathBuf);
impl Work {
    fn new(source: &str) -> Self {
        let path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("artifacts")
            .join(format!(
                "typed-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
        fs::create_dir_all(&path).unwrap();
        fs::write(path.join("lib.rs"), source).unwrap();
        Self(path)
    }
    fn generate(&self, roots: &[&str]) -> Result<String, String> {
        let roots: Vec<String> = roots.iter().map(|r| r.to_string()).collect();
        provium::typed::generate_host(&self.0.join("lib.rs"), &roots, "T")
    }
}
impl Drop for Work {
    fn drop(&mut self) {
        if !std::thread::panicking() {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
}

#[test]
fn structs_enums_and_methods_become_lean_definitions() {
    let w = Work::new(
        r#"
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Role { Follower, Leader }
pub struct Counter<const N: usize> { hits: [u64; N], role: Role, total: u64 }
impl<const N: usize> Counter<N> {
    pub fn bump(&mut self, i: usize) -> Option<u64> {
        let next = self.hits[i].checked_add(1)?;
        self.hits[i] = next;
        self.total = self.total.wrapping_add(1);
        if self.role == Role::Leader { Some(next) } else { None }
    }
    pub fn leader(&self) -> bool { matches!(self.role, Role::Leader) }
}
"#,
    );
    let lean = w.generate(&["Counter::bump", "Counter::leader"]).unwrap();
    assert!(lean
        .contains("inductive Role where\n  | Follower\n  | Leader\n  deriving DecidableEq, Repr"));
    assert!(lean.contains("structure Counter (N : Nat) where\n  hits : (Vector Rust.u64 N)"));
    // `&mut self` is returned with the result; indexing can panic, so `bump` is monadic.
    assert!(lean.contains("def Counter.bump {N : Nat} (self : (Counter N)) (i : Rust.usize) : Rust.M ((Option Rust.u64) × (Counter N)) := do"));
    // A function that cannot fail is pure.
    assert!(lean.contains("def Counter.leader {N : Nat} (self : (Counter N)) : Bool :="));
}

#[test]
fn borrows_write_through_to_their_places() {
    let w = Work::new(
        r#"
pub struct S { a: [Option<u64>; 4], n: u64 }
impl S {
    pub fn clear(&mut self) {
        for slot in &mut self.a {
            if let Some(v) = slot {
                *v += 1;
                if *v > 3 { *slot = None; }
            }
        }
    }
    pub fn first(&mut self) {
        let x = self.a[0].get_or_insert(7);
        *x += 1;
        let n = &mut self.n;
        *n = 5;
    }
}
"#,
    );
    let lean = w.generate(&["S::clear", "S::first"]).unwrap();
    // Each write to a borrowed element is written back to the array slot.
    assert!(lean.contains("self := { self with a := "), "{lean}");
    assert!(lean.contains("self := { self with n := n }"), "{lean}");
}

#[test]
fn aliases_equality_and_stateful_array_closures() {
    let w = Work::new(
        r#"
#[derive(Clone, Copy, Debug)]
pub struct Set { items: [Option<u64>; 2] }
impl PartialEq for Set {
    fn eq(&self, other: &Self) -> bool {
        self.items.iter().flatten().all(|x| other.items.iter().flatten().any(|y| y == x))
    }
}
#[derive(Clone, Debug, PartialEq)]
pub enum Item { Raw(u64), Group(Set) }
pub type Pair = [Option<u64>; 2];
pub struct Bag { slots: Pair, len: usize }
impl Bag {
    pub fn moved(mut self) -> [Option<u64>; 4] {
        core::array::from_fn(|i| if i < self.len { self.slots[i].take() } else { None })
    }
    pub fn same(a: &Item, b: &Item) -> bool { a == b }
    pub fn wrap(x: Option<u64>) -> Option<Item> { x.map(Item::Raw) }
}
"#,
    );
    let lean = w
        .generate(&["Bag::moved", "Bag::same", "Bag::wrap"])
        .unwrap();
    // The alias is expanded.
    assert!(
        lean.contains("slots : (Vector (Option Rust.u64) 2)"),
        "{lean}"
    );
    // A hand-written `PartialEq` is the type's `==`; types around it derive `BEq`.
    assert!(lean.contains("instance : BEq Set := ⟨Set.eq⟩"), "{lean}");
    assert!(lean.contains("  deriving BEq, Repr"), "{lean}");
    // A closure mutating captured state runs as a loop over the indices.
    assert!(lean.contains("for i in List.range 4 do"), "{lean}");
    assert!(lean.contains("Rust.Slice.ofArray 4"), "{lean}");
    // A constructor named as a function is its eta-expansion.
    assert!(lean.contains("Item.Raw eta_0"), "{lean}");
}

#[test]
fn inclusive_slice_ranges_include_their_end() {
    let w = Work::new(
        r#"
pub fn upto(a: &[u64; 4], n: usize) -> usize { a[..=n].len() }
"#,
    );
    let lean = w.generate(&["upto"]).unwrap();
    // `..=n` ends after `n`; `n + 1` overflowing panics as Rust does.
    assert!(lean.contains("Rust.add n 1"), "{lean}");
}

/// rustc's MIR for the work crate, emitted the way the cross-check does.
fn crate_mir(w: &Work) -> String {
    let out = std::process::Command::new("rustc")
        .current_dir(&w.0)
        .args([
            "--crate-type",
            "lib",
            "--edition",
            "2021",
            "-C",
            "opt-level=0",
        ])
        .arg("--emit=mir=crate.mir")
        .arg("lib.rs")
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    fs::read_to_string(w.0.join("crate.mir")).unwrap()
}

#[test]
fn rustc_cross_check_catches_misresolved_calls_and_mistyped_locals() {
    let w = Work::new(
        r#"
pub struct A { n: u64 }
pub struct B { n: u32 }
impl A {
    pub fn get(&self) -> u64 { self.n }
    pub fn twice(&self) -> u64 { let v = self.get(); v.wrapping_mul(2) }
}
impl B {
    pub fn get(&self) -> u32 { self.n }
}
pub fn use_b(b: &B) -> u32 { let x = b.get(); x }
"#,
    );
    let roots: Vec<String> = ["A::twice", "use_b"]
        .iter()
        .map(|r| r.to_string())
        .collect();
    let (krate, generated) =
        provium::typed::translate_host(&w.0.join("lib.rs"), &roots, "T").unwrap();
    let mir = provium::typed::mircheck::parse(&crate_mir(&w));
    let dir = w.0.canonicalize().unwrap();
    let dir = dir.to_str().unwrap();
    let ok = provium::typed::mircheck::check(&krate, &generated.facts, &mir, dir);
    assert!(ok.problems.is_empty(), "{:?}", ok.problems);
    assert!(ok.locals >= 4 && ok.calls >= 2, "{ok:?}");

    // A call resolved to the wrong type's method.
    let mut facts = generated.facts.clone();
    let calls = &mut facts.get_mut("use_b").unwrap().calls;
    assert!(calls.remove("B::get"));
    calls.insert("A::get".into());
    let bad = provium::typed::mircheck::check(&krate, &facts, &mir, dir);
    assert!(
        bad.problems
            .iter()
            .any(|p| p.contains("rustc calls B::get")),
        "{:?}",
        bad.problems
    );
    assert!(
        bad.problems
            .iter()
            .any(|p| p.contains("the translation calls A::get")),
        "{:?}",
        bad.problems
    );

    // A local inferred at the wrong width.
    let mut facts = generated.facts.clone();
    for (name, ty) in &mut facts.get_mut("A::twice").unwrap().locals {
        if name == "v" {
            *ty = provium::typed::types::Ty::Uint(32, "u32");
        }
    }
    let bad = provium::typed::mircheck::check(&krate, &facts, &mir, dir);
    assert!(
        bad.problems
            .iter()
            .any(|p| p.contains("local `v` is u32 in the translation")),
        "{:?}",
        bad.problems
    );
}

#[test]
fn mir_parsing_handles_function_types_and_promoted_constants() {
    let mir = r#"
fn m::<impl at a.rs:3:1: 3:9>::f(_1: &mut S<V>, _2: impl FnOnce() -> V) -> Result<(), E> {
    debug self => _1;
    debug make => _2;
    let mut _3: core::option::Option<&'a mut Entry<V>>;
    scope 1 {
        debug slot => _3;
    }
    bb0: {
        _4 = S::<V>::g::<Map<Cloned<core::slice::Iter<'_, V>>, fn(V) -> R<V> {R::<V>::C}>>(move _1) -> [return: bb1, unwind continue];
        _5 = const m::S::<V>::f::<impl FnOnce() -> V>::promoted[0];
        _6 = <impl FnOnce() -> V as FnOnce<()>>::call_once(move _2, const ()) -> [return: bb2, unwind continue];
    }
}
"#;
    let parsed = provium::typed::mircheck::parse(mir);
    let f = &parsed[&("a.rs".to_owned(), 3, "f".to_owned())];
    assert_eq!(
        f.locals["slot"].iter().collect::<Vec<_>>(),
        ["Option<Entry<V>>"]
    );
    assert_eq!(f.locals["self"].iter().collect::<Vec<_>>(), ["S<V>"]);
    // The promoted constant is not a call; the two calls are.
    assert_eq!(f.callees.len(), 2, "{:?}", f.callees);
    assert!(f.callees.iter().all(|c| !c.contains("promoted")));
}

#[test]
fn unsupported_constructs_are_rejected_with_their_function() {
    for (source, root, message) in [
        (
            "pub fn f(n: u64) -> u64 { if n == 0 { 0 } else { f(n - 1) } }",
            "f",
            "recursive function f",
        ),
        (
            "pub fn f() -> u64 { let mut c = 0u64; let mut g = || c += 1; g(); c }",
            "f",
            "closures that mutate captured state",
        ),
        (
            "pub struct S { x: u64 } impl S { pub fn x(&mut self) -> &mut u64 { &mut self.x } }",
            "S::x",
            "returning &mut",
        ),
        ("pub fn f() { 'a: loop { break 'a; } }", "f", "labeled"),
    ] {
        let w = Work::new(source);
        let error = w.generate(&[root]).unwrap_err();
        assert!(error.contains(message), "{source}: {error}");
    }
}

/// The example crate: proofs against the generated Lean, and a differential
/// scenario that must agree natively and in Lean.
#[test]
#[ignore = "requires the pinned Lean toolchain and Cargo"]
fn example_verifies() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let out = root.join("artifacts/typed-example");
    let report =
        provium::typed::verify::verify(&root.join("examples/typed/project.json"), &out).unwrap();
    assert!(
        report.contains("PROVIUM_VERIFIED Example.Proofs.push_len"),
        "{report}"
    );
    assert!(
        report.contains("PROVIUM_VERIFIED Example.Proofs.pushed_len"),
        "{report}"
    );
    assert!(report.contains("Differential: 16 scenarios"), "{report}");
    for theorem in [
        "display_text",
        "send_front_dropped",
        "send_front_sent",
        "drain_empty",
    ] {
        assert!(
            report.contains(&format!("PROVIUM_VERIFIED Example.Proofs.{theorem}")),
            "{report}"
        );
    }
    assert!(report.contains("rustc cross-check:"), "{report}");
    assert!(
        report.contains("Differential coverage: 9 of 11 translated functions executed"),
        "{report}"
    );
}

/// The differential must execute every translated function or name it, with a
/// reason, as unexercised; a stale entry fails too.
#[test]
#[ignore = "requires the pinned Lean toolchain, Cargo and llvm-tools"]
fn differential_coverage_must_be_exact() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("examples/typed");
    let out = Path::new(env!("CARGO_MANIFEST_DIR")).join("artifacts/typed-coverage");
    let mut project: serde_json::Value =
        serde_json::from_slice(&fs::read(root.join("project.json")).unwrap()).unwrap();
    project["differential"]["unexercised"] =
        serde_json::json!({ "Queue::pop": "claimed unexercised, but the scenario pops" });
    let config = root.join("project-coverage-test.json");
    fs::write(&config, project.to_string()).unwrap();
    let result = provium::typed::verify::verify(&config, &out);
    fs::remove_file(&config).unwrap();
    let error = result.unwrap_err();
    assert!(
        error.contains("Queue::pop is listed as unexercised but the scenario executes it"),
        "{error}"
    );
}

/// A theorem reaches a generated function through a consumer relation whose
/// constructors run it, but not a function the relation never runs.
#[test]
#[ignore = "requires the pinned Lean toolchain and Cargo"]
fn obligations_must_reach_their_function() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let w = Work::new(&fs::read_to_string(root.join("examples/typed/src/lib.rs")).unwrap());
    fs::copy(
        root.join("examples/typed/Proofs.lean"),
        w.0.join("Proofs.lean"),
    )
    .unwrap();
    let mut project: serde_json::Value =
        serde_json::from_slice(&fs::read(root.join("examples/typed/project.json")).unwrap())
            .unwrap();
    project["crate_root"] = "lib.rs".into();
    project.as_object_mut().unwrap().remove("differential");
    project.as_object_mut().unwrap().remove("cargo_build");
    project["obligations"] = serde_json::json!([
        { "theorem": "Example.Proofs.pushed_len", "function": "Queue::pop" }
    ]);
    fs::write(w.0.join("project.json"), project.to_string()).unwrap();
    let error =
        provium::typed::verify::verify(&w.0.join("project.json"), &w.0.join("out")).unwrap_err();
    assert!(
        error.contains("pushed_len does not mention generated function Example.Queue.pop"),
        "{error}"
    );
}
