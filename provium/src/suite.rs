//! Consumer-facing proof assertions. Proofs and generated evidence belong to the
//! consuming crate; this module never installs toolchains or modifies its source.
use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};

/// Evidence for one verified project. This is not a whole-program correctness claim.
#[derive(Debug)]
pub struct ProjectReport {
    pub project: PathBuf,
    pub output: PathBuf,
    pub details: String,
}

/// Verify a project with the appropriate backend, requiring actual obligations.
pub fn verify_project(project: &Path, output: &Path) -> Result<ProjectReport, String> {
    crate::project::prepare_output(output)?;
    let value: serde_json::Value = serde_json::from_slice(
        &fs::read(project).map_err(|e| format!("{}: {e}", project.display()))?,
    )
    .map_err(|e| e.to_string())?;
    if value["obligations"].as_array().is_none_or(|o| o.is_empty()) || !value["proofs"].is_string()
    {
        return Err(format!(
            "{}: proof assertions require a proof file and nonempty obligations",
            project.display()
        ));
    }
    let details = if value["kind"] == "specification" {
        crate::specification::verify(project, output)
    } else if value.get("methods").is_some() {
        crate::methods::verify(project, output)
    } else {
        crate::project::verify(project, output)
    }
    .map_err(|e| format!("{}: {e}", project.display()))?;
    Ok(ProjectReport {
        project: project.into(),
        output: output.into(),
        details,
    })
}

/// Verify every `project.json` beneath a consumer-owned proof directory.
///
/// Paths resolve from `crate_root`, never from the process working directory.
/// Evidence is written to `crate_root/artifacts/provium/<crate-relative project directory>`.
/// Empty suites fail. An installed pinned Lean toolchain is required; it is never
/// installed implicitly by this entry point. Use [`crate::assert_proofs!`] in tests.
pub fn verify_suite(crate_root: &Path, proofs: &Path) -> Result<Vec<ProjectReport>, String> {
    let root = crate_root.canonicalize().map_err(|e| e.to_string())?;
    let directory = root
        .join(proofs)
        .canonicalize()
        .map_err(|e| format!("proof directory {}: {e}", root.join(proofs).display()))?;
    if !directory.starts_with(&root) {
        return Err("proof suite must belong to the consuming crate".into());
    }
    let output = root.join("artifacts/provium");
    crate::project::prepare_output(&output)?;
    if directory.starts_with(&output) || output.starts_with(&directory) {
        return Err("proof inputs and generated evidence must have separate directories".into());
    }
    // Certificates of projects that were removed, renamed or moved must not
    // survive as success markers beside fresh evidence for this suite.
    remove_certificates(&output.join(directory.strip_prefix(&root).map_err(|e| e.to_string())?))?;
    let mut projects = vec![];
    discover(&directory, &mut projects)?;
    if projects.is_empty() {
        return Err(format!(
            "no project.json files found in {}",
            directory.display()
        ));
    }
    projects.sort();
    // Invalidate every selected certificate before any verifier/preflight can fail.
    let mut selected = vec![];
    for project in projects {
        let relative = project
            .parent()
            .unwrap()
            .strip_prefix(&root)
            .map_err(|e| e.to_string())?;
        let out = output.join(relative);
        if selected
            .iter()
            .any(|(_, previous): &(PathBuf, PathBuf)| previous == &out)
        {
            return Err("proof projects have colliding output directories".into());
        }
        crate::project::prepare_output(&out)?;
        selected.push((project, out));
    }
    let installed = Command::new("elan")
        .args(["toolchain", "list"])
        .output()
        .map_err(|e| {
            format!(
                "Lean is required: install elan and run `elan toolchain install {}` ({e})",
                crate::project::TOOLCHAIN
            )
        })?;
    if !installed.status.success()
        || !String::from_utf8_lossy(&installed.stdout)
            .lines()
            .any(|line| line.split_whitespace().next() == Some(crate::project::TOOLCHAIN))
    {
        return Err(format!(
            "required Lean toolchain is not installed; run `elan toolchain install {}`",
            crate::project::TOOLCHAIN
        ));
    }
    selected
        .into_iter()
        .map(|(project, out)| verify_project(&project, &out))
        .collect()
}
fn remove_certificates(dir: &Path) -> Result<(), String> {
    let entries = match fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(format!("{}: {e}", dir.display())),
    };
    for entry in entries {
        let entry = entry.map_err(|e| e.to_string())?;
        let kind = entry.file_type().map_err(|e| e.to_string())?;
        if kind.is_dir() {
            remove_certificates(&entry.path())?;
        } else if entry.file_name() == "verified.json" {
            fs::remove_file(entry.path()).map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}
fn discover(dir: &Path, projects: &mut Vec<PathBuf>) -> Result<(), String> {
    for entry in fs::read_dir(dir).map_err(|e| format!("{}: {e}", dir.display()))? {
        let entry = entry.map_err(|e| e.to_string())?;
        let kind = entry.file_type().map_err(|e| e.to_string())?;
        if kind.is_symlink() {
            return Err(format!(
                "proof suite cannot traverse symlinks: {}",
                entry.path().display()
            ));
        }
        if kind.is_dir() {
            discover(&entry.path(), projects)?;
        } else if entry.file_name() == "project.json" {
            projects.push(entry.path());
        }
    }
    Ok(())
}
