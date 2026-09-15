//! Slow kernel checks. Run through scripts/verify.sh; never silently skip Lean.
use provium::project::{compile, verify};
use std::{
    fs,
    path::{Path, PathBuf},
    sync::atomic::{AtomicUsize, Ordering},
};
static NEXT: AtomicUsize = AtomicUsize::new(0);
struct Work(PathBuf);
impl Work {
    fn new() -> Self {
        let p = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("artifacts")
            .join(format!(
                "proof-test-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
        fs::create_dir_all(&p).unwrap();
        Self(p)
    }
    fn write(&self, name: &str, text: &str) -> PathBuf {
        let path = self.0.join(name);
        fs::write(&path, text).unwrap();
        path
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
fn project(w: &Work, proof: bool) -> PathBuf {
    w.write("project.json",&serde_json::json!({"source":"source.rs","namespace":"Subject","usize_bits":usize::BITS,"proofs":proof.then_some("Proofs.lean"),"obligations":if proof {vec![serde_json::json!({"theorem":"checked","function":"f"})]} else {vec![]}}).to_string())
}

#[test]
fn stale_success_is_invalidated_even_when_frontend_or_rustc_rejects() {
    let w = Work::new();
    let p = project(&w, false);
    fs::create_dir_all(w.out()).unwrap();
    for source in [
        "fn f(x:i32)->i32{x}",
        "fn g(x:u8)->u8{x} const fn f(x:u8)->u8{g(x)}",
    ] {
        w.write("source.rs", source);
        fs::write(w.out().join("verified.json"), "old success").unwrap();
        assert!(compile(&p, &w.out()).is_err());
        assert!(!w.out().join("verified.json").exists());
    }
    w.write("source.rs", "fn f(x:u8)->u8{x}");
    let mut config: serde_json::Value = serde_json::from_slice(&fs::read(&p).unwrap()).unwrap();
    config["usize_bits"] = (if usize::BITS == 64 { 32 } else { 64 }).into();
    fs::write(&p, config.to_string()).unwrap();
    assert!(compile(&p, &w.out())
        .unwrap_err()
        .contains("usize_bits differs"));
}

#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn kernel_rejects_admits_unrelated_claims_and_stale_success() {
    let w = Work::new();
    let p = project(&w, true);
    w.write("source.rs", "fn f(x:u8)->u8{x}");
    let claim = "Subject.f [.uint 8 1] = .ok (.uint 8 1)";
    w.write(
        "Proofs.lean",
        &format!("import Generated\ntheorem checked : {claim} := by rfl\n"),
    );
    verify(&p, &w.out()).unwrap();
    assert!(w.out().join("verified.json").exists());
    for (proof,expected) in [
        (format!("import Generated\ntheorem checked : {claim} := by sorry\n"),"sorry"),
        (format!("import Generated\naxiom oracle : {claim}\ntheorem checked : {claim} := oracle\n"),"unapproved axiom"),
        ("import Generated\ntheorem checked : True := True.intro\n".into(),"does not mention"),
        (format!("import Generated\nset_option linter.defProp false\ndef checked : {claim} := rfl\n"),"requires a theorem"),
        ("import Generated\ntheorem checked : Subject.f [.uint 8 1] = .ok (.uint 8 2) := by rfl\n".into(),"Lean rejected Proofs.lean"),
    ] {
        w.write("Proofs.lean",&proof);
        fs::write(w.out().join("verified.json"),"stale").unwrap();
        let error=verify(&p,&w.out()).unwrap_err();
        assert!(error.contains(expected),"{error}");
        assert!(!w.out().join("verified.json").exists());
    }
}

#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn generated_lean_agrees_with_native_rust_boundary_results() {
    let w = Work::new();
    w.write("source.rs", include_str!("fixtures/scalars.rs"));
    let mut config: serde_json::Value =
        serde_json::from_slice(&fs::read(project(&w, true)).unwrap()).unwrap();
    config["obligations"] = serde_json::json!([{"theorem":"checked","function":"arithmetic"}]);
    let p = w.write("project.json", &config.to_string());
    let mut proof = String::from("import Generated\n");
    let mut first = true;
    for x in [0u8, 1, 127, 255] {
        for y in [0u8, 1, 128, 255] {
            let a = x.wrapping_add(y);
            let result = a
                .saturating_sub(x)
                .wrapping_sub(y)
                .saturating_add(x)
                .max(y)
                .min(a);
            let declaration = if first { "theorem checked" } else { "example" };
            first = false;
            proof.push_str(&format!("{declaration} : Subject.arithmetic [.uint 8 {x}, .uint 8 {y}] = .ok (.uint 8 {result}) := by rfl\n"));
        }
    }
    for x in [0u8, 1, 128, 255] {
        for y in [0u8, 1, 7, 8, 255] {
            let bits = x.wrapping_mul(y) ^ ((x & y) | (x ^ y));
            proof.push_str(&format!("example : Subject.bits [.uint 8 {x}, .uint 8 {y}] = .ok (.uint 8 {bits}) := by rfl\n"));
            for (name, result) in [
                ("shl", x.checked_shl(y.into())),
                ("shr", x.checked_shr(y.into())),
            ] {
                let expected = result.map_or_else(
                    || ".error .overflow".to_string(),
                    |n| format!(".ok (.uint 8 {n})"),
                );
                proof.push_str(&format!(
                    "example : Subject.{name} [.uint 8 {x}, .uint 8 {y}] = {expected} := by rfl\n"
                ));
            }
        }
    }
    for x in [0u64, 1, u64::MAX / 2, u64::MAX] {
        let y = 0x9e3779b97f4a7c15u64;
        let a = x.wrapping_add(y);
        let b = (a ^ (a >> 30)).wrapping_mul(0xbf58476d1ce4e5b9);
        let c = (b ^ (b >> 27)).wrapping_mul(0x94d049bb133111eb);
        let result = c ^ (c >> 31);
        proof.push_str(&format!("example : Subject.mix [.uint 64 {x}, .uint 64 {y}] = .ok (.uint 64 {result}) := by rfl\n"));
    }
    proof.push_str("example : Subject.call_order [.uint 8 255, .uint 8 0] = .error .overflow := by rfl\nexample : Subject.div [.uint 8 1, .uint 8 0] = .error .divisionByZero := by rfl\nexample : Subject.assertion [.uint 8 2, .uint 8 1] = .error .assertion := by rfl\n");
    w.write("Proofs.lean", &proof);
    verify(&p, &w.out()).unwrap();
}
