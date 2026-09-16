//! Capture actual Cargo compiler invocations without installing a toolchain.
//! This is build evidence, not name resolution or Rust semantic preservation.
use crate::{cargo_subject, project};
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
    process::Command,
    sync::atomic::{AtomicU64, Ordering},
};

static NEXT: AtomicU64 = AtomicU64::new(0);
const WRAPPER: &str = r#"
use std::{env, fs::OpenOptions, io::Write, process::{Command, ExitCode}};
fn run() -> Result<i32, Box<dyn std::error::Error>> {
    let args = env::args().skip(1).collect::<Vec<_>>();
    let program = args.first().ok_or("missing compiler executable")?;
    let directory = env::var_os("PROVIUM_CAPTURE_RECORDS").ok_or("missing capture directory")?;
    let path = std::path::PathBuf::from(directory).join(format!("{}.args", std::process::id()));
    let mut file = OpenOptions::new().write(true).create_new(true).open(&path)?;
    let cwd = env::current_dir()?;
    let cwd = cwd.to_str().ok_or("non-UTF8 compiler working directory")?;
    for arg in std::iter::once(cwd).chain(args.iter().map(String::as_str)) {
        file.write_all(&(arg.len() as u64).to_le_bytes())?;
        file.write_all(arg.as_bytes())?;
    }
    file.sync_all()?;
    // Cargo probes may request several different printed values. Only actual
    // compilation units get a cfg query; preserve their complete argument vector
    // and Cargo-provided environment, including build-script cfg settings.
    let probe = args[1..].iter().any(|a| a == "--print" || a.starts_with("--print=")
        || a == "-vV" || a == "--version" || a == "-V");
    if !probe {
        if args[1..].iter().any(|a| a.starts_with('@')) {
            return Err("compiler response-file capture is not implemented".into());
        }
        let cfg = Command::new(program).args(&args[1..]).args(["--print", "cfg"]).output()?;
        if !cfg.status.success() {
            return Err(format!("effective cfg query failed: {}", String::from_utf8_lossy(&cfg.stderr)).into());
        }
        let mut cfg_file = OpenOptions::new().write(true).create_new(true).open(path.with_extension("cfg"))?;
        cfg_file.write_all(&cfg.stdout)?;
        cfg_file.sync_all()?;
    }
    Ok(Command::new(program).args(&args[1..]).status()?.code().unwrap_or(1))
}
fn main() -> ExitCode {
    match run() {
        Ok(0) => ExitCode::SUCCESS,
        Ok(code) => std::process::exit(code),
        Err(error) => { eprintln!("Provium compiler capture: {error}"); ExitCode::FAILURE }
    }
}
"#;

#[derive(Debug, Serialize, Deserialize)]
pub struct Invocation {
    pub working_directory: PathBuf,
    pub executable: String,
    pub arguments: Vec<String>,
    /// rustc --print cfg with this unit's actual arguments and Cargo environment.
    /// None identifies a compiler probe, not a compiled unit.
    pub effective_cfg: Option<String>,
}
#[derive(Debug, Serialize)]
pub struct CompilerIdentity {
    pub executable: PathBuf,
    pub executable_sha256: String,
    pub verbose_version: String,
}
#[derive(Debug, Serialize)]
pub struct Capture {
    pub schema: u32,
    pub kind: &'static str,
    pub subject: cargo_subject::Report,
    pub source_inventory: crate::coverage::Inventory,
    pub run_directory: PathBuf,
    pub cargo_working_directory: PathBuf,
    pub cargo_arguments: Vec<String>,
    pub invocations: Vec<Invocation>,
    pub compilers: Vec<CompilerIdentity>,
    pub wrapper_sha256: String,
    pub cargo_stdout_sha256: String,
    pub cargo_stderr_sha256: String,
    pub semantic_preservation_proved: bool,
    pub limitations: Vec<String>,
}
fn decode(bytes: &[u8]) -> Result<Invocation, String> {
    let mut cursor = bytes;
    let mut args = vec![];
    while !cursor.is_empty() {
        let prefix: [u8; 8] = cursor
            .get(..8)
            .ok_or("truncated argument length")?
            .try_into()
            .unwrap();
        let len =
            usize::try_from(u64::from_le_bytes(prefix)).map_err(|_| "argument length overflow")?;
        cursor = &cursor[8..];
        let arg = cursor.get(..len).ok_or("truncated argument")?;
        args.push(
            std::str::from_utf8(arg)
                .map_err(|e| e.to_string())?
                .to_owned(),
        );
        cursor = &cursor[len..];
    }
    if args.len() < 2 {
        return Err("empty compiler invocation".into());
    }
    Ok(Invocation {
        working_directory: PathBuf::from(args.remove(0)),
        executable: args.remove(0),
        arguments: args,
        effective_cfg: None,
    })
}
fn compiler_identity(
    invocation: &Invocation,
    expected_version: &str,
) -> Result<CompilerIdentity, String> {
    let executable = Path::new(&invocation.executable);
    let path = if executable.is_absolute() || executable.components().count() > 1 {
        invocation.working_directory.join(executable)
    } else {
        std::env::split_paths(&std::env::var_os("PATH").ok_or("missing compiler search path")?)
            .map(|p| invocation.working_directory.join(p).join(executable))
            .find(|p| p.is_file())
            .ok_or("captured compiler executable cannot be resolved")?
    }
    .canonicalize()
    .map_err(|e| e.to_string())?;
    let bytes = fs::read(&path).map_err(|e| e.to_string())?;
    let version = Command::new(&invocation.executable)
        .arg("-vV")
        .current_dir(&invocation.working_directory)
        .output()
        .map_err(|e| e.to_string())?;
    if !version.status.success() || version.stdout != expected_version.as_bytes() {
        return Err("captured compiler identity differs from subject metadata".into());
    }
    Ok(CompilerIdentity {
        executable: path,
        executable_sha256: project::hash(bytes),
        verbose_version: expected_version.into(),
    })
}

fn utf8(path: &Path) -> Result<String, String> {
    path.to_str()
        .map(str::to_owned)
        .ok_or("non-UTF8 capture path".into())
}
fn invalidate(output: &Path) -> Result<(), String> {
    project::prepare_output(output)?;
    match fs::remove_file(output.join("captured-build.json")) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e.to_string()),
    }
}

/// Build the selected library using a forwarding rustc wrapper. Cargo owns a
/// fresh target directory so cached artifacts cannot hide compiler invocations.
/// Only Cargo creates/writes that target directory; wrapper inputs and records
/// are written beside the consumer's evidence. Existing wrapper overrides are
/// rejected rather than silently removed. No proof certificate is issued.
pub fn capture(request: cargo_subject::Request, output: &Path) -> Result<Capture, String> {
    invalidate(output)?;
    for key in [
        "RUSTC_WRAPPER",
        "RUSTC_WORKSPACE_WRAPPER",
        "CARGO_BUILD_RUSTC_WRAPPER",
        "CARGO_BUILD_RUSTC_WORKSPACE_WRAPPER",
    ] {
        if std::env::var_os(key).is_some_and(|v| !v.is_empty()) {
            return Err(format!("capture cannot replace an existing {key}"));
        }
    }
    let cwd = std::env::current_dir().map_err(|e| e.to_string())?;
    let mut config_dirs = cwd
        .ancestors()
        .map(|p| p.join(".cargo"))
        .collect::<Vec<_>>();
    if let Some(cargo_home) = std::env::var_os("CARGO_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|p| PathBuf::from(p).join(".cargo")))
    {
        config_dirs.push(cargo_home);
    }
    for directory in config_dirs {
        for filename in ["config", "config.toml"] {
            let path = directory.join(filename);
            if path.exists() {
                return Err(format!(
                    "Cargo configuration capture is not implemented: {}",
                    path.display()
                ));
            }
        }
    }
    let subject = cargo_subject::inspect(request)?;
    let root_package = subject
        .packages
        .iter()
        .find(|p| p.id == subject.root)
        .ok_or("missing root package")?;
    let library = root_package
        .targets
        .as_array()
        .ok_or("missing root targets")?
        .iter()
        .find(|t| {
            t["kind"].as_array().is_some_and(|kinds| {
                kinds.iter().any(|k| {
                    matches!(
                        k.as_str(),
                        Some("lib" | "rlib" | "dylib" | "cdylib" | "staticlib" | "proc-macro")
                    )
                })
            })
        })
        .and_then(|t| t["src_path"].as_str())
        .ok_or("capture requires a library target")?;
    let library = PathBuf::from(library);
    let package_root = root_package
        .manifest
        .parent()
        .ok_or("manifest has no parent")?
        .to_owned();
    let source_inventory = crate::coverage::inventory(&package_root, &library)?;
    let manifest = subject
        .request
        .manifest
        .canonicalize()
        .map_err(|e| e.to_string())?;
    fs::create_dir_all(output).map_err(|e| e.to_string())?;
    let output = output.canonicalize().map_err(|e| e.to_string())?;
    if manifest.starts_with(&output)
        || source_inventory
            .sources
            .iter()
            .any(|s| package_root.join(&s.path).starts_with(&output))
    {
        return Err("capture output must not contain its manifest or source inputs".into());
    }
    let id = format!(
        "{}-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(|e| e.to_string())?
            .as_nanos()
    );
    let run = output.join(format!("run-{id}"));
    let records = run.join("records");
    fs::create_dir_all(&records).map_err(|e| e.to_string())?;
    for input in &source_inventory.sources {
        let bytes = fs::read(package_root.join(&input.path)).map_err(|e| e.to_string())?;
        if project::hash(&bytes) != input.sha256 {
            return Err("source changed during capture preflight".into());
        }
        let snapshot = run.join("source").join(&input.path);
        fs::create_dir_all(snapshot.parent().ok_or("snapshot has no parent")?)
            .map_err(|e| e.to_string())?;
        fs::write(snapshot, bytes).map_err(|e| e.to_string())?;
    }
    let source = run.join("wrapper.rs");
    let wrapper = run.join(format!("rustc-wrapper{}", std::env::consts::EXE_SUFFIX));
    fs::write(&source, WRAPPER).map_err(|e| e.to_string())?;
    let built = Command::new("rustc")
        .args([
            "--edition=2021",
            "--crate-name",
            "provium_capture",
            "-D",
            "warnings",
        ])
        .arg(&source)
        .arg("-o")
        .arg(&wrapper)
        .output()
        .map_err(|e| e.to_string())?;
    if !built.status.success() {
        return Err(format!(
            "cannot build compiler wrapper: {}",
            String::from_utf8_lossy(&built.stderr)
        ));
    }
    let profile = match subject.request.profile {
        cargo_subject::Profile::Dev => "dev",
        cargo_subject::Profile::Release => "release",
    };
    // Pass this path only to Cargo. Do not create or populate it ourselves.
    let target = manifest
        .parent()
        .ok_or("manifest has no parent")?
        .join("target")
        .join("provium-capture")
        .join(&id);
    let mut args = vec![
        "rustc".into(),
        "--locked".into(),
        "--offline".into(),
        "--lib".into(),
        "--manifest-path".into(),
        utf8(&manifest)?,
        "--target".into(),
        subject.request.target.clone(),
        "--profile".into(),
        profile.into(),
        "--target-dir".into(),
        utf8(&target)?,
        "--message-format=json".into(),
    ];
    if subject.request.no_default_features {
        args.push("--no-default-features".into());
    }
    if !subject.request.features.is_empty() {
        args.extend(["--features".into(), subject.request.features.join(",")]);
    }
    args.extend(["--".into(), "--emit=metadata".into()]);
    if let Some(panic) = &subject.request.panic {
        args.extend([
            "-C".into(),
            match panic {
                cargo_subject::Panic::Abort => "panic=abort",
                cargo_subject::Panic::Unwind => "panic=unwind",
            }
            .into(),
        ]);
    }
    let result = Command::new("cargo")
        .args(&args)
        .env("RUSTC_WRAPPER", &wrapper)
        .env("PROVIUM_CAPTURE_RECORDS", &records)
        .output()
        .map_err(|e| e.to_string())?;
    fs::write(run.join("cargo.stdout"), &result.stdout).map_err(|e| e.to_string())?;
    fs::write(run.join("cargo.stderr"), &result.stderr).map_err(|e| e.to_string())?;
    if !result.status.success() {
        return Err(format!(
            "captured Cargo build failed ({}): {}",
            result.status,
            String::from_utf8_lossy(&result.stderr)
        ));
    }
    let mut files = fs::read_dir(&records)
        .map_err(|e| e.to_string())?
        .map(|e| e.map(|e| e.path()))
        .collect::<Result<Vec<PathBuf>, _>>()
        .map_err(|e| e.to_string())?;
    files.retain(|p| p.extension().is_some_and(|ext| ext == "args"));
    files.sort();
    let invocations = files
        .iter()
        .map(|p| {
            let mut invocation = decode(&fs::read(p).map_err(|e| e.to_string())?)?;
            let probe = invocation.arguments.iter().any(|a| {
                a == "--print"
                    || a.starts_with("--print=")
                    || matches!(a.as_str(), "-vV" | "--version" | "-V")
            });
            if !probe {
                invocation.effective_cfg = Some(
                    fs::read_to_string(p.with_extension("cfg"))
                        .map_err(|e| format!("missing effective compiler cfg: {e}"))?,
                );
            }
            Ok::<_, String>(invocation)
        })
        .collect::<Result<Vec<_>, _>>()?;
    let mut compilers = BTreeMap::new();
    for invocation in &invocations {
        if !compilers.contains_key(&invocation.executable) {
            compilers.insert(
                invocation.executable.clone(),
                compiler_identity(invocation, &subject.rustc_identity)?,
            );
        }
    }
    let compilers = compilers.into_values().collect::<Vec<_>>();
    let root = subject
        .packages
        .iter()
        .find(|p| p.id == subject.root)
        .ok_or("missing root package")?;
    let targets = root.targets.as_array().ok_or("missing package targets")?;
    let captured_root = targets.iter().any(|target| {
        let Some(source) = target["src_path"].as_str() else {
            return false;
        };
        let Some(name) = target["name"].as_str() else {
            return false;
        };
        let Ok(expected_source) = Path::new(source).canonicalize() else {
            return false;
        };
        invocations.iter().any(|invocation| {
            invocation.effective_cfg.is_some()
                && invocation
                    .arguments
                    .windows(2)
                    .any(|pair| pair[0] == "--crate-name" && pair[1] == name.replace('-', "_"))
                && invocation.arguments.iter().any(|arg| {
                    invocation
                        .working_directory
                        .join(arg)
                        .canonicalize()
                        .is_ok_and(|p| p == expected_source)
                })
        })
    });
    if !captured_root {
        return Err("Cargo produced no captured root-source compilation unit".into());
    }
    if invocations.iter().any(|i| {
        i.arguments
            .iter()
            .any(|a| a == "--test" || a == "--cfg=test")
            || i.arguments
                .windows(2)
                .any(|p| p[0] == "--cfg" && p[1] == "test")
    }) {
        return Err("capture does not inventory cfg(test) modules".into());
    }
    if crate::coverage::inventory(&package_root, &library)? != source_inventory {
        return Err("source inputs changed during capture".into());
    }
    for package in &subject.packages {
        if project::hash(fs::read(&package.manifest).map_err(|e| e.to_string())?)
            != package.manifest_sha256
        {
            return Err("package manifest changed during capture".into());
        }
    }
    for (path, expected) in &subject.workspace_inputs {
        if project::hash(fs::read(path).map_err(|e| e.to_string())?) != *expected {
            return Err("workspace inputs changed during capture".into());
        }
    }
    let report = Capture { schema: 1, kind: "compiler_invocation_capture", subject, source_inventory, run_directory: run.clone(), cargo_working_directory: cwd, cargo_arguments: args,
        invocations, compilers, wrapper_sha256: project::hash(WRAPPER), cargo_stdout_sha256: project::hash(&result.stdout),
        cargo_stderr_sha256: project::hash(&result.stderr), semantic_preservation_proved: false,
        limitations: vec!["Generated/dependency source files, environment, build-script inputs and compiler sysroot/dynamic libraries still require complete attestation".into(),
            "Captured commands and effective cfg are build provenance, not expanded Rust, resolved modules/calls or a source-preservation theorem".into()] };
    let publication = run.join("captured-build.json");
    fs::write(
        &publication,
        serde_json::to_vec_pretty(&report).map_err(|e| e.to_string())?,
    )
    .map_err(|e| e.to_string())?;
    fs::rename(publication, output.join("captured-build.json")).map_err(|e| e.to_string())?;
    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn argument_framing_preserves_quotes_spaces_and_newlines() {
        let args = [
            "/working directory",
            "rustc",
            "a path/with spaces.rs",
            "--cfg",
            "value=\"a\nb\"",
            "",
        ];
        let encoded = args
            .iter()
            .flat_map(|arg| {
                (arg.len() as u64)
                    .to_le_bytes()
                    .into_iter()
                    .chain(arg.bytes())
            })
            .collect::<Vec<_>>();
        let decoded = decode(&encoded).unwrap();
        assert_eq!(decoded.working_directory, Path::new(args[0]));
        assert_eq!(decoded.executable, args[1]);
        assert_eq!(decoded.arguments, args[2..]);
        assert!(decode(&encoded[..encoded.len() - 1]).is_err());
        assert!(decode(&[]).is_err());
    }
}
