//! Source-linked compilation for an explicitly checked, scalar Rust subset.
//! The Rust frontend and Lean operational semantics remain in the trusted base.
pub mod extract;
pub mod frontend;
pub mod ir;
pub mod lean;
pub mod methods;
pub mod project;

pub mod suite;
pub use suite::{verify_project, verify_suite, ProjectReport};

/// Assert all projects in a proof directory owned by the calling crate.
///
/// ```no_run
/// #[test]
/// fn invariants() {
///     provium::assert_proofs!("proofs");
/// }
/// ```
///
/// Requires an installed supported Lean toolchain. Failures panic with project
/// context, so they fail an ordinary Rust integration test. Evidence lives in
/// the caller's `artifacts/provium/` directory, never Cargo's `target/`.
#[macro_export]
macro_rules! assert_proofs {
    ($directory:expr $(,)?) => {{
        match $crate::verify_suite(
            ::std::path::Path::new(env!("CARGO_MANIFEST_DIR")),
            ::std::path::Path::new($directory),
        ) {
            Ok(reports) => {
                for report in reports {
                    println!("{}\n{}", report.project.display(), report.details);
                }
            }
            Err(error) => panic!("Provium proof assertion failed: {error}"),
        }
    }};
}
