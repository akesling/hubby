//! Offline Cargo dependency accounting. Metadata is not expanded Rust or a
//! semantic call graph; those remaining boundaries are included in every report.
use crate::project::hash;
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    path::{Path, PathBuf},
    process::Command,
};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    pub manifest: PathBuf,
    pub target: String,
    #[serde(default)]
    pub features: Vec<String>,
    #[serde(default)]
    pub no_default_features: bool,
}

#[derive(Debug, Serialize)]
pub struct Package {
    pub name: String,
    pub version: String,
    pub id: String,
    pub source: Option<String>,
    pub manifest: PathBuf,
    pub manifest_sha256: String,
    pub features: Vec<String>,
    pub normal_dependencies: Vec<String>,
    pub build_dependencies: Vec<String>,
    pub targets: serde_json::Value,
}
#[derive(Debug, Serialize)]
pub struct Report {
    pub schema: u32,
    pub request: Request,
    pub rustc_identity: String,
    pub target_cfg: String,
    pub root: String,
    pub packages: Vec<Package>,
    pub workspace_inputs: BTreeMap<PathBuf, String>,
    pub metadata_sha256: String,
    pub limitations: Vec<String>,
}
fn output(command: &mut Command) -> Result<String, String> {
    let result = command.output().map_err(|e| e.to_string())?;
    if !result.status.success() {
        return Err(String::from_utf8_lossy(&result.stderr).into_owned());
    }
    String::from_utf8(result.stdout).map_err(|e| e.to_string())
}
fn string<'a>(v: &'a serde_json::Value, key: &str) -> Result<&'a str, String> {
    v[key]
        .as_str()
        .ok_or_else(|| format!("Cargo metadata missing {key}"))
}
fn strings(v: &serde_json::Value) -> Result<Vec<String>, String> {
    v.as_array()
        .ok_or("expected metadata array")?
        .iter()
        .map(|x| {
            x.as_str()
                .map(str::to_owned)
                .ok_or("expected metadata string".into())
        })
        .collect()
}
fn dependencies(node: &serde_json::Value, kind: Option<&str>) -> Result<Vec<String>, String> {
    let mut out = vec![];
    for dependency in node["deps"]
        .as_array()
        .ok_or("missing resolved dependency edges")?
    {
        if dependency["dep_kinds"]
            .as_array()
            .ok_or("missing dependency kinds")?
            .iter()
            .any(|k| k["kind"].as_str() == kind)
        {
            out.push(string(dependency, "pkg")?.into());
        }
    }
    out.sort();
    out.dedup();
    Ok(out)
}

/// Inspect the selected package's normal and build dependency closure, excluding
/// dev-only dependencies. Uses locked, offline Cargo metadata and installs nothing.
/// Build scripts and proc macros are inventoried, never treated as verified.
pub fn inspect(mut request: Request) -> Result<Report, String> {
    let rustc_identity = output(Command::new("rustc").arg("-vV"))?;
    if request.target == "host" {
        request.target = rustc_identity
            .lines()
            .find_map(|l| l.strip_prefix("host: "))
            .ok_or("rustc did not report its host target")?
            .to_owned();
    }
    let manifest = request.manifest.canonicalize().map_err(|e| e.to_string())?;
    let mut command = Command::new("cargo");
    command
        .args([
            "metadata",
            "--format-version",
            "1",
            "--locked",
            "--offline",
            "--manifest-path",
        ])
        .arg(&manifest)
        .args(["--filter-platform", &request.target]);
    if request.no_default_features {
        command.arg("--no-default-features");
    }
    if !request.features.is_empty() {
        command.arg("--features").arg(request.features.join(","));
    }
    let metadata = output(&mut command)?;
    let value: serde_json::Value = serde_json::from_str(&metadata).map_err(|e| e.to_string())?;
    let (root, packages) = resolve(&value, &manifest)?;
    let workspace = Path::new(string(&value, "workspace_root")?);
    let mut workspace_inputs = BTreeMap::new();
    for file in [workspace.join("Cargo.toml"), workspace.join("Cargo.lock")] {
        workspace_inputs.insert(
            file.clone(),
            hash(fs::read(&file).map_err(|e| format!("{}: {e}", file.display()))?),
        );
    }
    let target_cfg =
        output(Command::new("rustc").args(["--print", "cfg", "--target", &request.target]))?;
    Ok(Report {schema:1,request,rustc_identity,target_cfg,root,packages,workspace_inputs,metadata_sha256:hash(metadata),limitations:vec![
        "Cargo metadata feature resolution is recorded; this is not a captured compiler invocation".into(),
        "build scripts, proc macros, cfg expansion and source/type/call closure still require checking".into(),
        "ambient Cargo configuration/environment and dependency source files are not fully attested".into(),
        "no semantic preservation or protocol correctness theorem is established by this report".into(),
    ]})
}

fn resolve(value: &serde_json::Value, manifest: &Path) -> Result<(String, Vec<Package>), String> {
    let packages = value["packages"]
        .as_array()
        .ok_or("missing Cargo packages")?;
    let root_package = packages
        .iter()
        .find(|p| {
            p["manifest_path"]
                .as_str()
                .is_some_and(|s| Path::new(s) == manifest)
        })
        .ok_or("requested package not found in Cargo metadata")?;
    let root = string(root_package, "id")?.to_owned();
    let nodes = value["resolve"]["nodes"]
        .as_array()
        .ok_or("Cargo metadata has no resolved graph")?;
    let mut pending = vec![root.clone()];
    let mut visited = BTreeSet::new();
    let mut result = vec![];
    while let Some(id) = pending.pop() {
        if !visited.insert(id.clone()) {
            continue;
        }
        let p = packages
            .iter()
            .find(|p| p["id"].as_str() == Some(&id))
            .ok_or("missing dependency package")?;
        let n = nodes
            .iter()
            .find(|n| n["id"].as_str() == Some(&id))
            .ok_or("missing dependency node")?;
        let source = p["source"].as_str().map(str::to_owned);
        if source.as_deref().is_some_and(|s| {
            s != "registry+https://github.com/rust-lang/crates.io-index"
                && s != "sparse+https://index.crates.io/"
        }) {
            return Err(format!(
                "{}: third-party dependencies must resolve directly from crates.io",
                string(p, "name")?
            ));
        }
        let normal = dependencies(n, None)?;
        let build = dependencies(n, Some("build"))?;
        pending.extend(normal.iter().chain(&build).cloned());
        let manifest = PathBuf::from(string(p, "manifest_path")?);
        result.push(Package {
            name: string(p, "name")?.into(),
            version: string(p, "version")?.into(),
            id,
            source,
            manifest: manifest.clone(),
            manifest_sha256: hash(fs::read(manifest).map_err(|e| e.to_string())?),
            features: strings(&n["features"])?,
            normal_dependencies: normal,
            build_dependencies: build,
            targets: p["targets"].clone(),
        });
    }
    result.sort_by(|a, b| a.id.cmp(&b.id));
    Ok((root, result))
}

/// Write build accounting beside consumer evidence, never into Cargo's target.
pub fn write(request: Request, output: &Path) -> Result<Report, String> {
    crate::project::prepare_output(output)?;
    let report = inspect(request)?;
    fs::create_dir_all(output).map_err(|e| e.to_string())?;
    fs::write(
        output.join("cargo-build.json"),
        serde_json::to_vec_pretty(&report).map_err(|e| e.to_string())?,
    )
    .map_err(|e| e.to_string())?;
    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn graph_keeps_normal_and_build_edges_but_excludes_dev_only_edges() {
        let edge = |id: &str, kind: Option<&str>| serde_json::json!({"pkg":id,"dep_kinds":[{"kind":kind,"target":null}]} );
        let node = serde_json::json!({"deps":[edge("runtime",None),edge("generator",Some("build")),edge("test",Some("dev"))]});
        assert_eq!(dependencies(&node, None).unwrap(), ["runtime"]);
        assert_eq!(dependencies(&node, Some("build")).unwrap(), ["generator"]);
    }
    #[test]
    fn git_dependency_is_rejected_before_reading_its_checkout() {
        let value = serde_json::json!({"packages":[{"id":"bad","name":"bad","manifest_path":"/unread/bad/Cargo.toml","source":"git+https://example.invalid/backend"}],"resolve":{"nodes":[{"id":"bad"}]}});
        assert!(resolve(&value, Path::new("/unread/bad/Cargo.toml"))
            .unwrap_err()
            .contains("crates.io"));
    }
}
