//! Coverage of a differential scenario: which translated functions, and how
//! much of their code, the scenario actually executes. The scenario runs
//! natively with `-C instrument-coverage`; since the native and Lean runs must
//! agree, an unexecuted function is one the differential says nothing about.
use super::load::Krate;
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::process::Command;

/// Per translated function: whether it ran, and its covered/total regions.
#[derive(Debug, Default, Clone)]
pub struct FnCoverage {
    pub executed: bool,
    pub covered: usize,
    pub regions: usize,
}

/// The LLVM tools of the active Rust toolchain (`rustup component add llvm-tools`).
fn llvm_tool(name: &str) -> Result<PathBuf, String> {
    let sysroot = Command::new("rustc")
        .args(["--print", "sysroot"])
        .output()
        .map_err(|e| e.to_string())?;
    let version = Command::new("rustc")
        .arg("-vV")
        .output()
        .map_err(|e| e.to_string())?;
    let host = String::from_utf8_lossy(&version.stdout)
        .lines()
        .find_map(|l| l.strip_prefix("host: ").map(str::to_owned))
        .ok_or("rustc -vV printed no host")?;
    let tool = PathBuf::from(String::from_utf8_lossy(&sysroot.stdout).trim())
        .join("lib/rustlib")
        .join(host)
        .join("bin")
        .join(name);
    if !tool.exists() {
        return Err(format!(
            "differential coverage needs {name}: run `rustup component add llvm-tools`"
        ));
    }
    Ok(tool)
}

/// Run the scenario binary of `native` (a Cargo project) instrumented, and
/// return the `llvm-cov export` JSON.
pub fn run_instrumented(native: &Path, overflow_flags: &[&str]) -> Result<String, String> {
    let target = native.join("target-coverage");
    let profiles = native.join("profiles");
    if profiles.exists() {
        std::fs::remove_dir_all(&profiles).map_err(|e| e.to_string())?;
    }
    std::fs::create_dir_all(&profiles).map_err(|e| e.to_string())?;
    let mut flags = vec!["-C", "instrument-coverage"];
    flags.extend_from_slice(overflow_flags);
    let build = Command::new("cargo")
        .args(["build", "--quiet", "--offline"])
        .current_dir(native)
        .env("CARGO_TARGET_DIR", &target)
        .env("RUSTFLAGS", flags.join(" "))
        .output()
        .map_err(|e| e.to_string())?;
    if !build.status.success() {
        return Err(format!(
            "instrumented differential build failed:\n{}",
            String::from_utf8_lossy(&build.stderr)
        ));
    }
    let binary = target.join("debug/provium-differential");
    let run = Command::new(&binary)
        .env("LLVM_PROFILE_FILE", profiles.join("run-%p-%m.profraw"))
        .output()
        .map_err(|e| e.to_string())?;
    if !run.status.success() {
        return Err("instrumented differential run failed".into());
    }
    let raws: Vec<PathBuf> = std::fs::read_dir(&profiles)
        .map_err(|e| e.to_string())?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "profraw"))
        .collect();
    let merged = profiles.join("merged.profdata");
    let merge = Command::new(llvm_tool("llvm-profdata")?)
        .args(["merge", "-sparse", "-o"])
        .arg(&merged)
        .args(&raws)
        .output()
        .map_err(|e| e.to_string())?;
    if !merge.status.success() {
        return Err(format!(
            "llvm-profdata merge failed:\n{}",
            String::from_utf8_lossy(&merge.stderr)
        ));
    }
    let export = Command::new(llvm_tool("llvm-cov")?)
        .args(["export", "--format=text", "--skip-expansions"])
        .arg("--instr-profile")
        .arg(&merged)
        .arg(&binary)
        .output()
        .map_err(|e| e.to_string())?;
    if !export.status.success() {
        return Err(format!(
            "llvm-cov export failed:\n{}",
            String::from_utf8_lossy(&export.stderr)
        ));
    }
    String::from_utf8(export.stdout).map_err(|e| e.to_string())
}

/// Attribute `llvm-cov export` regions to the translated functions by source
/// span. A region counts as covered if any instantiation executed it.
pub fn attribute(
    k: &Krate,
    translated: &BTreeSet<String>,
    export: &str,
) -> Result<BTreeMap<String, FnCoverage>, String> {
    let json: serde_json::Value = serde_json::from_str(export).map_err(|e| e.to_string())?;
    // Region (file, start line, start col, end line, end col) -> executed.
    let mut regions: BTreeMap<(String, u64, u64, u64, u64), bool> = BTreeMap::new();
    for data in json["data"].as_array().into_iter().flatten() {
        for f in data["functions"].as_array().into_iter().flatten() {
            let files: Vec<String> = f["filenames"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|n| n.as_str().map(str::to_owned))
                .collect();
            for r in f["regions"].as_array().into_iter().flatten() {
                let r: Vec<u64> = r
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(|v| v.as_u64())
                    .collect();
                // [line start, col start, line end, col end, count, file, expanded file, kind]
                if r.len() < 8 || r[7] != 0 {
                    continue;
                }
                let Some(file) = files.get(r[5] as usize) else {
                    continue;
                };
                let hit = regions
                    .entry((file.clone(), r[0], r[1], r[2], r[3]))
                    .or_insert(false);
                *hit |= r[4] > 0;
            }
        }
    }
    // Regions by canonical file.
    let mut by_file: BTreeMap<String, Vec<(u64, bool)>> = BTreeMap::new();
    for ((rf, l0, _, _, _), hit) in &regions {
        if let Ok(p) = Path::new(rf).canonicalize() {
            by_file
                .entry(p.to_string_lossy().into_owned())
                .or_default()
                .push((*l0, *hit));
        }
    }
    let mut out = BTreeMap::new();
    for path in translated {
        let Some(f) = k.functions.get(path) else {
            continue;
        };
        let file = f.file.canonicalize().map_err(|e| e.to_string())?;
        let start = f.sig.fn_token.span.start().line as u64;
        let end = f.block.brace_token.span.close().end().line as u64;
        let mut c = FnCoverage::default();
        for (l0, hit) in by_file
            .get(file.to_string_lossy().as_ref())
            .into_iter()
            .flatten()
        {
            if *l0 >= start && *l0 <= end {
                c.regions += 1;
                if *hit {
                    c.covered += 1;
                    c.executed = true;
                }
            }
        }
        out.insert(path.clone(), c);
    }
    Ok(out)
}
