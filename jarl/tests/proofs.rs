//! Jarl owns these contracts; Provium is the reusable verification dependency.
use std::{
    fs,
    path::{Path, PathBuf},
    sync::atomic::{AtomicUsize, Ordering},
};
static NEXT: AtomicUsize = AtomicUsize::new(0);
struct Work(PathBuf);
impl Work {
    fn new() -> Self {
        let path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("artifacts")
            .join(format!(
                "proof-test-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }
    fn write(&self, name: &str, text: &str) -> PathBuf {
        let p = self.0.join(name);
        fs::write(&p, text).unwrap();
        p
    }
    fn source(&self, text: &str) -> PathBuf {
        self.write("lib.rs", text)
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

#[test]
fn invariants() {
    provium::assert_proofs!("proofs");
}

#[path = "proof_cases/lean.rs"]
mod consensus;
#[path = "proof_cases/scalar_methods.rs"]
mod election;
#[path = "proof_cases/arrays.rs"]
mod membership;
#[path = "proof_cases/methods.rs"]
mod persistence;
