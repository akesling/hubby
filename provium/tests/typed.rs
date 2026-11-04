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
    assert!(report.contains("Differential: 16 scenarios"), "{report}");
}
