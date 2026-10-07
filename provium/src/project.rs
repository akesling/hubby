use crate::{frontend::Compiler, ir::Function, lean};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
    sync::Mutex,
};
pub const TOOLCHAIN: &str = "leanprover/lean4:v4.33.1";
pub const SEMANTICS: &str = include_str!("../lean/Provium/Semantics.lean");
pub const AUDIT: &str = include_str!("../lean/Provium/Audit.lean");

fn parse_lean_memory_limit(value: &str) -> Result<u32, String> {
    match value.parse::<u32>() {
        Ok(limit) if limit > 0 => Ok(limit),
        _ => Err("PROVIUM_LEAN_MEMORY_MB must be a positive integer (MiB)".into()),
    }
}

/// Per-process Lean memory budget, in MiB. Verifier invocations are serialized
/// within a process; independent verifier processes have independent budgets.
pub fn lean_memory_limit_mb() -> Result<u32, String> {
    match std::env::var("PROVIUM_LEAN_MEMORY_MB") {
        Ok(value) => parse_lean_memory_limit(&value),
        Err(std::env::VarError::NotPresent) => Ok(2048),
        Err(error) => Err(format!("invalid PROVIUM_LEAN_MEMORY_MB: {error}")),
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Obligation {
    pub theorem: String,
    pub function: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Project {
    pub source: Option<PathBuf>,
    pub scalar_method: Option<crate::methods::scalar::Request>,
    #[serde(default)]
    pub slices: Vec<crate::extract::Slice>,
    pub namespace: String,
    pub usize_bits: u32,
    pub rust_target: Option<String>,
    pub proofs: Option<PathBuf>,
    #[serde(default)]
    pub obligations: Vec<Obligation>,
}
#[derive(Clone, Debug, Serialize)]
pub struct Source {
    pub path: String,
    pub sha256: String,
    pub snapshot: String,
}
#[derive(Debug, Serialize)]
pub struct Manifest {
    pub rustc: String,
    pub rust_target_cfg: String,
    pub compiler_sha256: String,
    pub config_sha256: String,
    pub audit_sha256: String,
    pub format: u32,
    pub provium_version: String,
    pub lean_toolchain: String,
    pub sources: Vec<Source>,
    pub extraction: Vec<crate::extract::Evidence>,
    pub scalar_method: Option<crate::methods::scalar::Evidence>,
    pub source_path: String,
    pub source_sha256: String,
    pub semantics_sha256: String,
    pub generated_sha256: String,
    pub proofs_sha256: Option<String>,
    pub usize_bits: u32,
    pub overflow: &'static str,
    pub functions: Vec<Function>,
    pub obligations: Vec<Obligation>,
    pub trusted_boundary: &'static str,
}
pub fn hash(bytes: impl AsRef<[u8]>) -> String {
    format!("{:x}", Sha256::digest(bytes.as_ref()))
}
fn io<T>(value: std::io::Result<T>) -> Result<T, String> {
    value.map_err(|e| e.to_string())
}
fn identifier(name: &str) -> bool {
    name.split('.').all(|part| {
        part != "_"
            && !part.is_empty()
            && part
                .bytes()
                .enumerate()
                .all(|(i, c)| c == b'_' || c.is_ascii_alphabetic() || (i > 0 && c.is_ascii_digit()))
    })
}
pub fn read(path: &Path) -> Result<Project, String> {
    parse(&io(fs::read(path))?)
}
fn parse(bytes: &[u8]) -> Result<Project, String> {
    let project: Project =
        serde_json::from_slice(bytes).map_err(|e| format!("invalid project file: {e}"))?;
    if usize::from(project.source.is_some())
        + usize::from(!project.slices.is_empty())
        + usize::from(project.scalar_method.is_some())
        != 1
    {
        return Err("choose exactly one: source, scalar_method, or nonempty slices".into());
    }
    if !identifier(&project.namespace) {
        return Err("invalid Lean namespace".into());
    }
    for obligation in &project.obligations {
        if !identifier(&obligation.theorem)
            || !identifier(&obligation.function)
            || obligation.function.contains('.')
        {
            return Err("invalid obligation declaration/function name".into());
        }
    }
    if project.proofs.is_none() && !project.obligations.is_empty() {
        return Err("obligations require a proof file".into());
    }
    if project.proofs.is_some() && project.obligations.is_empty() {
        return Err("proof file requires an explicit nonempty obligation list".into());
    }
    Ok(project)
}
/// Whether `output`, resolved against `cwd`, lies under a Cargo `target/` tree.
/// Relative paths are resolved first: a relative output whose ancestors do not
/// yet exist would otherwise canonicalize only `.`, skipping the working directory.
fn beneath_target(cwd: &Path, output: &Path) -> bool {
    let in_target = |path: &Path| {
        path.components()
            .any(|part| matches!(part, std::path::Component::Normal(name) if name == "target"))
    };
    let absolute = cwd.join(output);
    in_target(&absolute)
        || absolute
            .ancestors()
            .find_map(|p| p.canonicalize().ok())
            .is_some_and(|p| in_target(&p))
}
pub(crate) fn prepare_output(output: &Path) -> Result<(), String> {
    // Cargo owns target directories. Check before even invalidating artifacts.
    if beneath_target(&io(std::env::current_dir())?, output) {
        return Err("Cargo exclusively owns target/; use an artifacts/ output directory".into());
    }
    // Invalidate before parsing: even a rejected edit must invalidate old success.
    remove_if_present(&output.join("verified.json"))
}
fn remove_if_present(path: &Path) -> Result<(), String> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e.to_string()),
    }
}
/// Remove compiled Lean objects left by earlier runs. Backends that compile in
/// their output directory resolve imports through it, so an old object must
/// never satisfy an import of this run. Symlinks are not followed.
pub(crate) fn clear_lean_objects(directory: &Path) -> Result<(), String> {
    let entries = match fs::read_dir(directory) {
        Ok(entries) => entries,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(e.to_string()),
    };
    for entry in entries {
        let entry = io(entry)?;
        let path = entry.path();
        if io(entry.file_type())?.is_dir() {
            clear_lean_objects(&path)?;
        } else if path
            .extension()
            .is_some_and(|e| e == "olean" || e == "ilean")
        {
            io(fs::remove_file(&path))?;
        }
    }
    Ok(())
}
/// Publish a success certificate atomically: readers see either no certificate
/// or a complete one, never a partially written file.
pub(crate) fn publish_certificate(output: &Path, bytes: impl AsRef<[u8]>) -> Result<(), String> {
    let staged = output.join("verified.json.tmp");
    io(fs::write(&staged, bytes))?;
    io(fs::rename(&staged, output.join("verified.json")))
}
pub fn compile(project_path: &Path, output: &Path) -> Result<Manifest, String> {
    prepare_output(output)?;
    clear_lean_objects(output)?;
    // Hash and parse the same bytes, so the recorded hash describes the
    // configuration that was actually used.
    let config_bytes = io(fs::read(project_path))?;
    let config_hash = hash(&config_bytes);
    let project = parse(&config_bytes)?;
    let base = project_path.parent().unwrap_or_else(|| Path::new("."));
    let mut sources = Vec::<Source>::new();
    let mut snapshots = Vec::<String>::new();
    let mut extraction = vec![];
    let mut scalar_method = None;
    let source = if let Some(path) = &project.source {
        let path = io(base.join(path).canonicalize())?;
        let text = io(fs::read_to_string(&path))?;
        sources.push(Source {
            path: path.display().to_string(),
            sha256: hash(&text),
            snapshot: "Source.rs".into(),
        });
        text
    } else if let Some(request) = &project.scalar_method {
        let krate = crate::methods::Crate::load(&base.join(&request.crate_root))?;
        let translation = krate.scalar_projections(&request.method)?;
        scalar_method = Some(translation.evidence);
        for (path, text) in translation.files {
            sources.push(Source {
                path: path.display().to_string(),
                sha256: hash(&text),
                snapshot: format!("Inputs/{}.rs", snapshots.len()),
            });
            snapshots.push(text);
        }
        translation.source
    } else {
        for slice in &project.slices {
            let path = io(base.join(&slice.source).canonicalize())?;
            let text = io(fs::read_to_string(&path))?;
            extraction.push(crate::extract::extract(
                &text,
                &path.display().to_string(),
                slice,
            )?);
            if sources
                .iter()
                .any(|s| s.path == path.display().to_string() && s.sha256 != hash(&text))
            {
                return Err("source changed between slice extractions".into());
            }
            if !sources.iter().any(|s| s.path == path.display().to_string()) {
                sources.push(Source {
                    path: path.display().to_string(),
                    sha256: hash(&text),
                    snapshot: format!("Inputs/{}.rs", snapshots.len()),
                });
                snapshots.push(text);
            }
        }
        extraction
            .iter()
            .map(|e| e.abstracted_rust.as_str())
            .collect::<Vec<_>>()
            .join("\n")
    };
    let source_path = if project.source.is_some() {
        sources[0].path.clone()
    } else {
        "Source.rs (generated abstraction; see extraction/scalar-method evidence)".into()
    };
    let functions = Compiler::parse(&source, project.usize_bits)?
        .compile()
        .map_err(|e| format!("{}:{e}", source_path))?;
    for f in &functions {
        if !identifier(&f.name) || f.name.contains('.') {
            return Err("only ASCII function identifiers are currently supported".into());
        }
    }
    let mut symbols = std::collections::BTreeSet::from(["proviumUsizeBits".to_owned()]);
    for f in &functions {
        for name in [
            f.name.clone(),
            format!("{}_ir", f.name),
            format!("{}_correspondence", f.name),
        ] {
            if !symbols.insert(name) {
                return Err("generated Lean symbol collision; rename the Rust function".into());
            }
        }
    }
    for obligation in &project.obligations {
        if !functions.iter().any(|f| f.name == obligation.function) {
            return Err(format!(
                "obligation names unknown function {}",
                obligation.function
            ));
        }
    }
    let source_hash = hash(&source);
    let generated = lean::generate(
        &functions,
        &project.namespace,
        project.usize_bits,
        &source_hash,
    );
    let proofs = project
        .proofs
        .as_ref()
        .map(|p| io(fs::read_to_string(base.join(p))))
        .transpose()?;
    // The output directory is disposable compiler output; protect input files.
    io(fs::create_dir_all(output))?;
    let output_absolute = io(output.canonicalize())?;
    if sources
        .iter()
        .any(|s| Path::new(&s.path).starts_with(&output_absolute))
        || io(project_path.canonicalize())?.starts_with(&output_absolute)
        || project
            .proofs
            .as_ref()
            .map(|p| {
                base.join(p)
                    .canonicalize()
                    .map(|p| p.starts_with(&output_absolute))
            })
            .transpose()
            .map_err(|e| e.to_string())?
            .unwrap_or(false)
    {
        return Err("input files must be outside the output directory".into());
    }
    // Reject invalid Rust too: syn is a parser, not Rust's type checker.
    if let Some(request) = &project.scalar_method {
        let mut rustc = Command::new("rustc");
        rustc
            .args([
                "--crate-name",
                "provium_original",
                "--crate-type",
                "lib",
                "--emit=metadata",
                "--edition=2021",
                "-C",
                "overflow-checks=yes",
            ])
            .arg(base.join(&request.crate_root))
            .arg("-o")
            .arg(output.join("original.rmeta"));
        if let Some(target) = &project.rust_target {
            rustc.args(["--target", target]);
        }
        let checked = io(rustc.output())?;
        if !checked.status.success() {
            return Err(format!(
                "rustc rejected original crate: {}",
                String::from_utf8_lossy(&checked.stderr)
            ));
        }
    }
    let rustc = rustc_output(&["--version"], None)?;
    let cfg = rustc_output(&["--print", "cfg"], project.rust_target.as_deref())?;
    if !cfg
        .lines()
        .any(|line| line == format!("target_pointer_width=\"{}\"", project.usize_bits))
    {
        return Err("usize_bits differs from rustc target; select a matching rust_target".into());
    }
    io(fs::create_dir_all(output.join("Provium")))?;
    io(fs::write(output.join("Provium/Semantics.lean"), SEMANTICS))?;
    io(fs::write(output.join("Provium/Audit.lean"), AUDIT))?;
    io(fs::write(output.join("Generated.lean"), &generated))?;
    io(fs::write(output.join("Source.rs"), &source))?;
    if !snapshots.is_empty() {
        io(fs::create_dir_all(output.join("Inputs")))?;
        for (input, text) in sources.iter().zip(&snapshots) {
            io(fs::write(output.join(&input.snapshot), text))?;
        }
    }
    io(fs::write(
        output.join("RustCheck.rs"),
        "#![no_std]\ninclude!(\"Source.rs\");\n",
    ))?;
    let mut rust_check = Command::new("rustc");
    rust_check
        .args([
            "--crate-name",
            "provium_subject",
            "--crate-type",
            "lib",
            "--emit=metadata",
            "--edition=2021",
            "-C",
            "overflow-checks=yes",
            "-A",
            "dead_code",
        ])
        .arg(output.join("RustCheck.rs"))
        .arg("-o")
        .arg(output.join("subject.rmeta"));
    if let Some(target) = &project.rust_target {
        rust_check.args(["--target", target]);
    }
    let checked = rust_check
        .output()
        .map_err(|e| format!("cannot run rustc: {e}"))?;
    if !checked.status.success() {
        return Err(format!(
            "rustc rejected source: {}",
            String::from_utf8_lossy(&checked.stderr)
        ));
    }
    io(fs::write(
        output.join("lean-toolchain"),
        format!("{TOOLCHAIN}\n"),
    ))?;
    if let Some(proofs) = &proofs {
        io(fs::write(output.join("Proofs.lean"), proofs))?;
    }
    let mut audit = "import Provium.Audit\nimport Generated\n".to_string();
    if proofs.is_some() {
        audit.push_str("import Proofs\n");
    }
    for f in &functions {
        audit.push_str(&format!(
            "#provium_check {}.{}_correspondence references {}.{}\n",
            project.namespace, f.name, project.namespace, f.name
        ));
    }
    for o in &project.obligations {
        audit.push_str(&format!(
            "#provium_obligation {} references {}.{}\n",
            o.theorem, project.namespace, o.function
        ));
    }
    io(fs::write(output.join("Check.lean"), audit))?;
    let manifest = Manifest {
        scalar_method,
        rustc: rustc.trim().into(), rust_target_cfg: cfg,
        compiler_sha256: hash(io(fs::read(io(std::env::current_exe())?))?),
        config_sha256: config_hash, audit_sha256: hash(AUDIT),
        format: 1, provium_version: env!("CARGO_PKG_VERSION").into(), lean_toolchain: TOOLCHAIN.into(),
        sources, extraction, source_path, source_sha256: source_hash,
        semantics_sha256: hash(SEMANTICS), generated_sha256: hash(generated), proofs_sha256: proofs.map(hash),
        usize_bits: project.usize_bits, overflow: "checked (explicit wrapping/saturating methods retain their semantics)",
        functions, obligations: project.obligations,
        trusted_boundary: "syn parsing, source name/type checking and AST-to-IR lowering, the specified Rust subset semantics, explicit slice bindings and scope (when used), successful-state field projections and borrow/layout refinement (when used), and Lean's trusted implementation. Generated correspondence proves backend agreement with IR, not frontend correctness or whole-program correctness.",
    };
    io(fs::write(
        output.join("manifest.json"),
        serde_json::to_string_pretty(&manifest).map_err(|e| e.to_string())?,
    ))?;
    Ok(manifest)
}
fn rustc_output(args: &[&str], target: Option<&str>) -> Result<String, String> {
    let mut command = Command::new("rustc");
    command.args(args);
    if let Some(target) = target {
        command.args(["--target", target]);
    }
    let result = command
        .output()
        .map_err(|e| format!("cannot run rustc: {e}"))?;
    if !result.status.success() {
        return Err(format!(
            "rustc failed: {}",
            String::from_utf8_lossy(&result.stderr)
        ));
    }
    String::from_utf8(result.stdout).map_err(|e| e.to_string())
}
pub(crate) fn lean_file(output: &Path, file: &str, object: Option<&str>) -> Result<String, String> {
    // A test binary may verify several projects concurrently. Keep their Lean
    // heaps from accumulating, independently of the Rust test runner settings.
    static LEAN_PROCESS: Mutex<()> = Mutex::new(());
    let _permit = LEAN_PROCESS
        .lock()
        .map_err(|_| "Lean execution lock poisoned")?;
    let mut command = Command::new("elan");
    command
        .args([
            "run",
            TOOLCHAIN,
            "lean",
            "--trust=0",
            "--threads=1",
            "-DwarningAsError=true",
        ])
        .arg(format!("--memory={}", lean_memory_limit_mb()?))
        .current_dir(output)
        .env("LEAN_PATH", output)
        .env_remove("LEAN_SRC_PATH");
    if let Some(object) = object {
        command.args(["-o", object]);
    }
    command.arg(file);
    let result = command
        .output()
        .map_err(|e| format!("cannot run Lean through elan: {e}"))?;
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&result.stdout),
        String::from_utf8_lossy(&result.stderr)
    );
    if !result.status.success() {
        return Err(format!("Lean rejected {file} ({}):\n{text}", result.status));
    }
    Ok(text)
}
pub fn verify(project_path: &Path, output: &Path) -> Result<String, String> {
    let manifest = compile(project_path, output)?;
    let output = io(output.canonicalize())?;
    let version = Command::new("elan")
        .args(["run", TOOLCHAIN, "lean", "--version"])
        .output()
        .map_err(|e| e.to_string())?;
    if !version.status.success() {
        return Err(format!(
            "Lean toolchain unavailable: {}",
            String::from_utf8_lossy(&version.stderr)
        ));
    }
    lean_file(
        &output,
        "Provium/Semantics.lean",
        Some("Provium/Semantics.olean"),
    )?;
    lean_file(&output, "Provium/Audit.lean", Some("Provium/Audit.olean"))?;
    lean_file(&output, "Generated.lean", Some("Generated.olean"))?;
    if manifest.proofs_sha256.is_some() {
        lean_file(&output, "Proofs.lean", Some("Proofs.olean"))?;
    }
    let report = lean_file(&output, "Check.lean", None)?;
    let expected = manifest.functions.len() + manifest.obligations.len();
    if report.matches("PROVIUM_VERIFIED ").count() != expected {
        return Err("incomplete Lean axiom-audit report".into());
    }
    let project = read(project_path)?;
    let base = project_path.parent().unwrap_or_else(|| Path::new("."));
    if hash(io(fs::read(project_path))?) != manifest.config_sha256
        || manifest.sources.iter().any(|source| {
            fs::read(&source.path)
                .map(|bytes| hash(bytes) != source.sha256)
                .unwrap_or(true)
        })
        || project
            .proofs
            .as_ref()
            .map(|p| io(fs::read(base.join(p))).map(hash))
            .transpose()?
            != manifest.proofs_sha256
    {
        return Err("inputs changed during verification; rerun on a stable source tree".into());
    }
    let mut artifacts = vec![
        ("Source.rs", manifest.source_sha256.clone()),
        ("Generated.lean", manifest.generated_sha256.clone()),
        ("Provium/Semantics.lean", manifest.semantics_sha256.clone()),
        ("Provium/Audit.lean", manifest.audit_sha256.clone()),
        (
            "manifest.json",
            hash(serde_json::to_string_pretty(&manifest).map_err(|e| e.to_string())?),
        ),
    ];
    if let Some(proofs_hash) = &manifest.proofs_sha256 {
        artifacts.push(("Proofs.lean", proofs_hash.clone()));
    }
    for source in &manifest.sources {
        artifacts.push((&source.snapshot, source.sha256.clone()));
    }
    for (file, expected) in artifacts {
        if hash(io(fs::read(output.join(file)))?) != expected {
            return Err(format!("artifact {file} changed during verification"));
        }
    }
    let certificate = serde_json::json!({ "whole_program_proved": false, "manifest_sha256": hash(io(fs::read(output.join("manifest.json")))?), "source_sha256": manifest.source_sha256, "generated_sha256": manifest.generated_sha256, "semantics_sha256": manifest.semantics_sha256, "proofs_sha256": manifest.proofs_sha256, "lean": String::from_utf8_lossy(&version.stdout).trim(), "backend_certificates": manifest.functions.len(), "invariant_obligations": manifest.obligations.len(), "audit": report, "trust_boundary": manifest.trusted_boundary });
    publish_certificate(
        &output,
        &serde_json::to_string_pretty(&certificate).map_err(|e| e.to_string())?,
    )?;
    Ok(format!("Verified {} generated backend certificates and {} invariant obligations.\nTranslated Rust SHA-256: {}\n{}", manifest.functions.len(), manifest.obligations.len(), manifest.source_sha256, report))
}

#[cfg(test)]
mod output_tests {
    use super::beneath_target;
    use std::path::Path;

    #[test]
    fn relative_outputs_resolve_against_the_working_directory() {
        let scratch = std::env::temp_dir().join(format!("provium-target-{}", std::process::id()));
        let work = scratch.join("crate/target/work");
        std::fs::create_dir_all(&work).unwrap();
        // Neither `newout` nor `newout/inv` exists, so no ancestor canonicalizes
        // except through the working directory.
        assert!(beneath_target(&work, Path::new("newout/inv")));
        assert!(beneath_target(&scratch, Path::new("crate/target/new")));
        assert!(!beneath_target(&scratch, Path::new("crate/artifacts/new")));
        std::fs::remove_dir_all(&scratch).unwrap();
    }
}

#[cfg(test)]
mod resource_tests {
    use super::parse_lean_memory_limit;

    #[test]
    fn memory_budget_cannot_disable_the_limit() {
        for value in ["0", "-1", "", "unlimited", "1.5", "4294967296"] {
            assert!(parse_lean_memory_limit(value).is_err(), "accepted {value}");
        }
        assert_eq!(parse_lean_memory_limit("2048").unwrap(), 2048);
        assert_eq!(parse_lean_memory_limit("8192").unwrap(), 8192);
    }
}
