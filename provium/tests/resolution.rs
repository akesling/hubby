//! Crate shapes that could make a backend's by-spelling interpretation of a
//! method or path disagree with Rust's resolution are rejected at load time.
use provium::methods::Crate;
use std::{
    fs,
    path::{Path, PathBuf},
    sync::atomic::{AtomicUsize, Ordering},
};
static NEXT: AtomicUsize = AtomicUsize::new(0);
struct Work(PathBuf);
impl Work {
    fn new(files: &[(&str, &str)]) -> Self {
        let p = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("artifacts")
            .join(format!(
                "resolution-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
        fs::create_dir_all(&p).unwrap();
        for (name, text) in files {
            fs::write(p.join(name), text).unwrap();
        }
        Self(p)
    }
    fn load(&self) -> Result<Crate, String> {
        Crate::load(&self.0.join("lib.rs"))
    }
}
impl Drop for Work {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
fn rejected(files: &[(&str, &str)], expected: &str) {
    let error = Work::new(files)
        .load()
        .err()
        .unwrap_or_else(|| panic!("accepted {files:?}"));
    assert!(error.contains(expected), "{error}");
}

#[test]
fn trait_impls_for_standard_or_reference_types_are_rejected() {
    // By-value trait methods on Copy std types win Rust's method probe over the
    // inherent `&self`/`&mut self` methods the backends interpret.
    for (source, target) in [
        (
            "pub trait Hide { fn as_ref(self) -> Option<&'static u64>; }
             impl Hide for Option<u64> { fn as_ref(self) -> Option<&'static u64> { None } }
             pub struct S { pub v: Option<u64> }
             impl S { pub fn get(&self) -> Option<&u64> { self.v.as_ref() } }",
            "Option",
        ),
        (
            "pub trait Steal { fn take(self) -> Self; }
             impl Steal for Option<u64> { fn take(self) -> Self { None } }
             pub struct S { pub meta: Option<u64> }",
            "Option",
        ),
        (
            "pub trait Sort { fn sort_unstable(&mut self); }
             impl Sort for [u64] { fn sort_unstable(&mut self) {} }
             pub struct S { pub v: u64 }",
            "[u64]",
        ),
        (
            // A trait for `&mut Receiver` wins over the inherent guard helper.
            "pub enum Error { Full }
             pub struct Buf<T, const N: usize> { slots: [Option<T>; N], len: usize }
             pub trait Hijack { fn full(self) -> bool; }
             impl<T, const N: usize> Hijack for &mut Buf<T, N> { fn full(self) -> bool { false } }
             impl<T, const N: usize> Buf<T, N> { fn full(&self) -> bool { self.len == N } }",
            "&",
        ),
        (
            "pub trait Any2 { fn any2(&self) -> bool; }
             impl<T> Any2 for T { fn any2(&self) -> bool { true } }
             pub struct S { pub v: u64 }",
            "T",
        ),
    ] {
        rejected(&[("lib.rs", source)], &format!("trait impl for {target}"));
    }
}

#[test]
fn crate_trait_methods_cannot_share_inherent_names() {
    rejected(
        &[(
            "lib.rs",
            "pub struct S { pub v: u64 }
             pub trait Helper { fn helper(&self) -> u64; }
             impl Helper for S { fn helper(&self) -> u64 { 0 } }
             impl S { fn helper(&self) -> u64 { self.v } }",
        )],
        "shares a name with inherent",
    );
}

#[test]
fn inherent_functions_cannot_hide_derived_methods() {
    rejected(
        &[(
            "lib.rs",
            "#[derive(Clone, Copy, Default)] pub struct Out { pub n: u64 }
             impl Out { pub fn default() -> Out { Out { n: 7 } } }",
        )],
        "hides a derived/standard trait method",
    );
}

#[test]
fn items_cannot_take_prelude_or_standard_root_names() {
    rejected(
        &[
            ("lib.rs", "mod Option; pub struct S { pub v: u64 }"),
            ("Option.rs", "pub fn is_some(_: &u64) -> bool { true }"),
        ],
        "crate item Option",
    );
    rejected(&[("lib.rs", "pub fn core() {}")], "crate item core");
    rejected(
        &[(
            "lib.rs",
            "use core::fmt::Result; pub struct S { pub v: u64 }",
        )],
        "shadowed primitive/prelude names",
    );
}

#[test]
fn unconfigured_loads_reject_conditional_declarations() {
    for source in [
        "#[cfg(feature = \"x\")] use core::cmp::max; pub struct S { pub v: u64 }",
        "#[cfg(not(test))] pub enum E { A } pub struct S { pub v: u64 }",
        "#[cfg_attr(feature = \"x\", derive(Clone))] pub struct S { pub v: u64 }",
    ] {
        rejected(&[("lib.rs", source)], "require a compilation configuration");
    }
    // Test-only declarations and attributes never reach a production build.
    Work::new(&[(
        "lib.rs",
        "#[cfg(test)] extern crate std; #[cfg_attr(test, derive(Clone))] pub struct S { pub v: u64 }",
    )])
    .load()
    .unwrap();
}

#[test]
fn canonical_imports_and_crate_type_impls_remain_supported() {
    let w = Work::new(&[(
        "lib.rs",
        "use core::iter::DoubleEndedIterator;
         use core::default::Default;
         #[derive(Clone, Copy, Debug, Default, Eq, PartialEq)] pub struct Id(pub u64);
         pub enum Error { Full }
         impl core::fmt::Display for Error {
             fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result { f.write_str(\"full\") }
         }
         pub struct State { pub v: u64 }
         impl Default for State { fn default() -> Self { State { v: 0 } } }
         pub trait Storage { fn save(&mut self) -> bool; }
         impl State { pub fn value(&self) -> u64 { self.v } }",
    )]);
    w.load().unwrap();
}
