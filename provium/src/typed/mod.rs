//! Typed backend: Rust items compiled to ordinary Lean definitions.
pub mod diffcov;
pub mod emit;
pub mod gen;
pub mod lean;
pub mod lib;
pub mod load;
pub mod mir;
pub mod mircheck;
pub mod mirenc;
pub mod types;
pub mod verify;

use std::path::Path;

/// Generate Lean for `roots` of the crate at `crate_root`, configured for the host.
pub fn generate_host(
    crate_root: &Path,
    roots: &[String],
    namespace: &str,
) -> Result<String, String> {
    Ok(translate_host(crate_root, roots, namespace)?.1.lean)
}

/// The loaded crate and its translation for the host, with the facts the
/// rustc cross-check compares.
pub fn translate_host(
    crate_root: &Path,
    roots: &[String],
    namespace: &str,
) -> Result<(load::Krate, gen::Generated), String> {
    let configuration = host_configuration()?;
    let k = load::Krate::load(crate_root, Some(configuration))?;
    let g = gen::generate(
        &k,
        roots,
        &gen::Options {
            namespace: namespace.to_owned(),
            overflow_checks: true,
            debug_assertions: true,
        },
    )?;
    Ok((k, g))
}

/// The host's `cfg` with overflow checks and debug assertions on; sets the
/// translation's pointer width to the host's.
pub fn host_configuration() -> Result<crate::cfg::Configuration, String> {
    let cfg = std::process::Command::new("rustc")
        .args([
            "--print",
            "cfg",
            "-C",
            "overflow-checks=yes",
            "-C",
            "debug-assertions=yes",
        ])
        .output()
        .map_err(|e| e.to_string())?;
    let cfg_text = String::from_utf8(cfg.stdout).map_err(|e| e.to_string())?;
    let configuration = crate::cfg::Configuration::parse(&cfg_text)?;
    let width = match configuration.pointer_width() {
        Some(w @ (32 | 64)) => w,
        _ => return Err("the typed backend supports 32- and 64-bit targets only".into()),
    };
    types::set_pointer_width(width);
    Ok(configuration)
}
