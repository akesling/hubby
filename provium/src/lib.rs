//! Source-linked compilation for an explicitly checked, scalar Rust subset.
//! The Rust frontend and Lean operational semantics remain in the trusted base.
pub mod extract;
pub mod frontend;
pub mod ir;
pub mod lean;
pub mod methods;
pub mod project;
