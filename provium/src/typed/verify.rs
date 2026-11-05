//! Verification of typed-backend projects: generate Lean from the crate as
//! Cargo builds it, check consumer proofs against it, and audit obligations.
use crate::methods::{build::Build, profile::Profile, proof_modules};
use crate::project::{hash, Obligation, AUDIT, TOOLCHAIN};
use serde::Deserialize;
use std::{collections::BTreeMap, fs, path::Path, process::Command};

const RUST: &str = include_str!("../../lean/Provium/Rust.lean");

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TypedProject {
    pub kind: String,
    pub crate_root: std::path::PathBuf,
    #[serde(default)]
    pub cargo_build: Option<std::path::PathBuf>,
    pub namespace: String,
    /// Rust paths (`module::Type::method`) of the functions to translate; every
    /// function they call is translated too.
    pub roots: Vec<String>,
    pub proofs: std::path::PathBuf,
    #[serde(default)]
    pub proof_modules: Vec<crate::methods::ProofModule>,
    /// Theorems and the Rust function each must mention.
    pub obligations: Vec<Obligation>,
    /// Scenarios run both natively and in Lean, which must agree exactly.
    #[serde(default)]
    pub differential: Option<Differential>,
}

/// A consumer scenario module, written against the crate's public API as an
/// external user would (`use <crate_name>::...`), exporting
/// `pub fn <function>(seed: u64) -> u64`.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Differential {
    pub source: std::path::PathBuf,
    pub crate_name: String,
    pub function: String,
    pub seeds: u64,
}

use super::lean::MOUNT;

fn identifier(s: &str) -> bool {
    let mut c = s.chars();
    c.next()
        .is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
        && c.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

pub fn verify(config: &Path, out: &Path) -> Result<String, String> {
    crate::project::prepare_output(out)?;
    let config_bytes = fs::read(config).map_err(|e| e.to_string())?;
    let project: TypedProject = serde_json::from_slice(&config_bytes).map_err(|e| e.to_string())?;
    if project.kind != "typed"
        || !identifier(&project.namespace)
        || project.roots.is_empty()
        || project.obligations.is_empty()
    {
        return Err(
            "typed projects need kind \"typed\", a namespace, roots and obligations".into(),
        );
    }
    let base = config.parent().unwrap_or(Path::new("."));
    let as_methods = crate::methods::Project {
        crate_root: project.crate_root.clone(),
        rust_target: None,
        cargo_build: project.cargo_build.clone(),
        namespace: project.namespace.clone(),
        methods: vec![],
        imperative_methods: vec![],
        proofs: project.proofs.clone(),
        proof_modules: project
            .proof_modules
            .iter()
            .map(|m| crate::methods::ProofModule {
                name: m.name.clone(),
                path: m.path.clone(),
            })
            .collect(),
        obligations: project.obligations.clone(),
    };
    let build = Build::capture(&as_methods, config, out)?;
    let (cfg_text, args) = match &build {
        Some(b) => (
            b.cfg()?.to_owned(),
            b.capture.invocations[b.capture.configured_root_invocation]
                .arguments
                .clone(),
        ),
        None => {
            let args: Vec<String> = [
                "--print",
                "cfg",
                "-C",
                "overflow-checks=yes",
                "-C",
                "debug-assertions=yes",
            ]
            .iter()
            .map(|s| s.to_string())
            .collect();
            let o = Command::new("rustc")
                .args(&args)
                .output()
                .map_err(|e| e.to_string())?;
            (
                String::from_utf8(o.stdout).map_err(|e| e.to_string())?,
                vec!["-C".into(), "overflow-checks=yes".into()],
            )
        }
    };
    let configuration = crate::cfg::Configuration::parse(&cfg_text)?;
    if configuration.pointer_width() != Some(64) {
        return Err("the typed backend supports 64-bit targets only".into());
    }
    let profile = Profile::from_invocation(&cfg_text, &args)?;
    let debug_assertions = cfg_text.lines().any(|l| l.trim() == "debug_assertions");
    let extras: Vec<(String, std::path::PathBuf)> = project
        .differential
        .iter()
        .map(|d| (MOUNT.to_owned(), base.join(&d.source)))
        .collect();
    let krate = super::load::Krate::load_with(
        &base.join(&project.crate_root),
        Some(configuration),
        &extras,
        project.differential.as_ref().map(|d| d.crate_name.as_str()),
    )?;
    let mounted: Vec<std::path::PathBuf> = extras
        .iter()
        .filter_map(|(_, p)| p.canonicalize().ok())
        .collect();
    if let Some(b) = &build {
        let crate_files = krate
            .files
            .iter()
            .filter(|(p, _)| !mounted.contains(p))
            .map(|(p, t)| (p.clone(), t.clone()))
            .collect();
        b.bind_sources(&crate_files)?;
    }
    let mut roots = project.roots.clone();
    if let Some(d) = &project.differential {
        roots.push(format!("{MOUNT}::{}", d.function));
    }
    let generated = super::gen::generate(
        &krate,
        &roots,
        &super::gen::Options {
            namespace: project.namespace.clone(),
            overflow_checks: profile.overflow_checked,
            debug_assertions,
        },
    )?;
    let mut audit = "import Provium.Audit\nimport Proofs\n".to_string();
    for o in &project.obligations {
        let lean = generated.functions.get(&o.function).ok_or_else(|| {
            format!(
                "obligation {} names untranslated function {}",
                o.theorem, o.function
            )
        })?;
        if !o.theorem.split('.').all(identifier) {
            return Err(format!("invalid theorem name {}", o.theorem));
        }
        audit.push_str(&format!(
            "#provium_obligation {} references {}.{lean}\n",
            o.theorem, project.namespace
        ));
    }
    let proofs_path = base
        .join(&project.proofs)
        .canonicalize()
        .map_err(|e| e.to_string())?;
    let proofs = fs::read_to_string(&proofs_path).map_err(|e| e.to_string())?;
    let libraries = proof_modules::load(base, &as_methods.proof_modules)?;
    fs::create_dir_all(out).map_err(|e| e.to_string())?;
    let out = out.canonicalize().map_err(|e| e.to_string())?;
    let toolchain = format!("{TOOLCHAIN}\n");
    let mut artifacts: Vec<(&str, &str)> = vec![
        ("lean-toolchain", &toolchain),
        ("Provium/Rust.lean", RUST),
        ("Provium/Audit.lean", AUDIT),
        ("Generated.lean", &generated.lean),
        ("Proofs.lean", &proofs),
        ("Check.lean", &audit),
    ];
    artifacts.extend(
        libraries
            .iter()
            .map(|l| (l.artifact.as_str(), l.source.as_str())),
    );
    let workspace = proof_modules::Workspace::new(&out)?;
    for (file, text) in &artifacts {
        let path = out.join(file);
        fs::create_dir_all(path.parent().unwrap()).map_err(|e| e.to_string())?;
        fs::write(path, text).map_err(|e| e.to_string())?;
        workspace.write(file, text)?;
    }
    let mut report = String::new();
    for (file, object) in [
        ("Provium/Rust.lean", "Provium/Rust.olean"),
        ("Provium/Audit.lean", "Provium/Audit.olean"),
        ("Generated.lean", "Generated.olean"),
    ] {
        report.push_str(&workspace.check(file, Some(object))?);
    }
    for l in &libraries {
        report
            .push_str(&workspace.check(&l.artifact, Some(&l.artifact.replace(".lean", ".olean")))?);
    }
    if let Some(d) = &project.differential {
        report.push_str(&differential(
            d,
            base,
            &out,
            &workspace,
            &generated,
            &project.namespace,
            profile.overflow_checked,
        )?);
    }
    report.push_str(&workspace.check("Proofs.lean", Some("Proofs.olean"))?);
    let audited = workspace.check("Check.lean", None)?;
    if audited.matches("PROVIUM_VERIFIED ").count() != project.obligations.len() {
        return Err(format!("incomplete obligation audit:\n{audited}"));
    }
    report.push_str(&audited);
    for (file, text) in &artifacts {
        workspace.source_unchanged(file, text)?;
    }
    if fs::read(config).map_err(|e| e.to_string())? != config_bytes {
        return Err("project changed during verification".into());
    }
    for (path, text) in &krate.files {
        if fs::read_to_string(path).map_err(|e| e.to_string())? != *text {
            return Err("Rust source changed during verification".into());
        }
    }
    if let Some(b) = &build {
        b.revalidate()?;
    }
    for object in [
        "Provium/Rust.olean",
        "Provium/Audit.olean",
        "Generated.olean",
        "Proofs.olean",
    ] {
        workspace.publish(object, &out)?;
    }
    for l in &libraries {
        workspace.publish(&l.artifact.replace(".lean", ".olean"), &out)?;
    }
    let manifest = serde_json::json!({
        "format": 1,
        "backend": "typed",
        "compiler_sha256": hash(fs::read(std::env::current_exe().map_err(|e| e.to_string())?).map_err(|e| e.to_string())?),
        "scope": "Rust functions translated to typed Lean definitions; the syn frontend's name resolution and the core-library interpretations in Provium/Rust.lean remain trusted",
        "lean_toolchain": TOOLCHAIN,
        "rust_target_cfg": cfg_text,
        "arithmetic_profile": profile,
        "cargo_build": build.as_ref().map(Build::evidence),
        "config_sha256": hash(&config_bytes),
        "sources": krate.files.iter().map(|(p, t)| (p.display().to_string(), hash(t))).collect::<BTreeMap<_, _>>(),
        "functions": generated.functions,
        "pure_functions": generated.pure,
        "artifacts": artifacts.iter().map(|(p, t)| (p.to_string(), hash(t))).collect::<BTreeMap<_, _>>(),
        "obligations": project.obligations,
        "audit": report,
    });
    let bytes = serde_json::to_vec_pretty(&manifest).map_err(|e| e.to_string())?;
    fs::write(out.join("manifest.json"), &bytes).map_err(|e| e.to_string())?;
    crate::project::publish_certificate(
        &out,
        serde_json::to_vec_pretty(&serde_json::json!({
            "manifest_sha256": hash(bytes),
            "backend": "typed",
            "translated_functions": generated.functions.len(),
            "obligations": project.obligations.len(),
            "whole_program_proved": false,
        }))
        .map_err(|e| e.to_string())?,
    )?;
    Ok(format!(
        "Verified {} obligations against {} translated functions.\n{report}",
        project.obligations.len(),
        generated.functions.len()
    ))
}

/// Run the scenario natively (a Cargo binary depending on the crate) and in
/// Lean (`#eval` of its translation), and require identical results.
fn differential(
    d: &Differential,
    base: &Path,
    out: &Path,
    workspace: &proof_modules::Workspace,
    generated: &super::gen::Generated,
    namespace: &str,
    overflow_checks: bool,
) -> Result<String, String> {
    let source = base
        .join(&d.source)
        .canonicalize()
        .map_err(|e| e.to_string())?;
    let manifest_dir = find_manifest(&source)?;
    let package = package_name(&manifest_dir.join("Cargo.toml"))?;
    let native = out.join("differential-native");
    fs::create_dir_all(native.join("src")).map_err(|e| e.to_string())?;
    fs::write(
        native.join("Cargo.toml"),
        format!(
            "[package]\nname = \"provium-differential\"\nversion = \"0.0.0\"\nedition = \"2021\"\npublish = false\n\n[dependencies]\n{} = {{ package = {:?}, path = {:?} }}\n\n[profile.dev]\noverflow-checks = {overflow_checks}\n\n[workspace]\n",
            d.crate_name,
            package,
            manifest_dir.display().to_string()
        ),
    )
    .map_err(|e| e.to_string())?;
    fs::write(
        native.join("src/main.rs"),
        format!(
            "#[path = {:?}]\nmod scenario;\nfn main() {{\n    std::panic::set_hook(Box::new(|_| {{}}));\n    for seed in 0..{}u64 {{\n        match std::panic::catch_unwind(|| scenario::{}(seed)) {{\n            Ok(v) => println!(\"{{seed}} ok {{v}}\"),\n            Err(_) => println!(\"{{seed}} panic\"),\n        }}\n    }}\n}}\n",
            source.display().to_string(),
            d.seeds,
            d.function
        ),
    )
    .map_err(|e| e.to_string())?;
    let run = Command::new("cargo")
        .args(["run", "--quiet", "--offline"])
        .current_dir(&native)
        .env("CARGO_TARGET_DIR", native.join("target"))
        .output()
        .map_err(|e| e.to_string())?;
    if !run.status.success() {
        return Err(format!(
            "native differential run failed:\n{}",
            String::from_utf8_lossy(&run.stderr)
        ));
    }
    let native_out = String::from_utf8_lossy(&run.stdout).into_owned();
    let path = format!("{MOUNT}::{}", d.function);
    let lean_fn = generated
        .functions
        .get(&path)
        .ok_or("differential function was not translated")?;
    let call = format!("{namespace}.{lean_fn} (Rust.ofNat s)");
    let shown = if generated.pure.contains(&path) {
        format!("s!\"{{s}} ok {{({call}).val}}\"")
    } else {
        format!(
            "match ({call}).run with | some (.ok v) => s!\"{{s}} ok {{v.val}}\" | some (.error _) => s!\"{{s}} panic\" | none => s!\"{{s}} div\""
        )
    };
    let lean = format!(
        "import Generated\n\n/-! Differential evaluation of `{path}`. -/\n#eval show IO Unit from do\n  for s in List.range {} do\n    IO.println ({shown})\n",
        d.seeds
    );
    workspace.write("Differential.lean", &lean)?;
    let lean_out = workspace.check("Differential.lean", None)?;
    let lean_lines: Vec<&str> = lean_out
        .lines()
        .filter(|l| {
            l.split(' ')
                .nth(1)
                .is_some_and(|w| ["ok", "panic", "div"].contains(&w))
        })
        .collect();
    let native_lines: Vec<&str> = native_out.lines().collect();
    if lean_lines != native_lines {
        let first = native_lines
            .iter()
            .zip(lean_lines.iter())
            .find(|(a, b)| a != b)
            .map(|(a, b)| format!("native {a:?}, Lean {b:?}"))
            .unwrap_or_else(|| {
                format!(
                    "{} native results, {} Lean results",
                    native_lines.len(),
                    lean_lines.len()
                )
            });
        return Err(format!("differential mismatch for {path}: {first}"));
    }
    fs::write(out.join("differential.txt"), &native_out).map_err(|e| e.to_string())?;
    Ok(format!(
        "Differential: {} scenarios of {path} agree natively and in Lean.\n",
        native_lines.len()
    ))
}

/// The `[package]` name of a Cargo manifest.
fn package_name(manifest: &Path) -> Result<String, String> {
    let text = fs::read_to_string(manifest).map_err(|e| e.to_string())?;
    let mut in_package = false;
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            in_package = line == "[package]";
        } else if in_package {
            if let Some(rest) = line.strip_prefix("name") {
                if let Some(v) = rest.trim_start().strip_prefix('=') {
                    return Ok(v.trim().trim_matches('"').to_owned());
                }
            }
        }
    }
    Err(format!("{}: no package name", manifest.display()))
}

fn find_manifest(from: &Path) -> Result<std::path::PathBuf, String> {
    let mut dir = from.parent();
    while let Some(d) = dir {
        let m = d.join("Cargo.toml");
        if m.exists() && fs::read_to_string(&m).is_ok_and(|t| t.contains("[package]")) {
            return Ok(d.to_owned());
        }
        dir = d.parent();
    }
    Err("no Cargo package encloses the differential source".into())
}
