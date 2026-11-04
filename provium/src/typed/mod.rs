//! Typed backend: Rust items compiled to ordinary Lean definitions.
pub mod emit;
pub mod gen;
pub mod lean;
pub mod lib;
pub mod load;
pub mod types;
pub mod verify;

use std::path::Path;

/// Generate Lean for `roots` of the crate at `crate_root`, configured for the host.
pub fn generate_host(
    crate_root: &Path,
    roots: &[String],
    namespace: &str,
) -> Result<String, String> {
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
    if configuration.pointer_width() != Some(64) {
        return Err("the typed backend supports 64-bit targets only".into());
    }
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
    Ok(g.lean)
}
