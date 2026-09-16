//! Fresh Cargo provenance for method verification. Dependency/sysroot semantics
//! and source-preservation proofs remain separate requirements.
use super::{Crate, Project};
use crate::{cargo_capture, cargo_subject, project::hash};
use std::{
    fs,
    path::{Path, PathBuf},
};

pub(super) struct Build {
    pub capture: cargo_capture::Capture,
    request_path: PathBuf,
    request_bytes: Vec<u8>,
    evidence_path: PathBuf,
    evidence_bytes: Vec<u8>,
}
impl Build {
    pub fn capture(
        project: &Project,
        config: &Path,
        output: &Path,
    ) -> Result<Option<Self>, String> {
        let Some(request) = &project.cargo_build else {
            return Ok(None);
        };
        if project.rust_target.is_some() {
            return Err("cargo_build and rust_target cannot both select the method build".into());
        }
        let base = config.parent().unwrap_or(Path::new("."));
        let request_path = base
            .join(request)
            .canonicalize()
            .map_err(|e| e.to_string())?;
        let request_bytes = fs::read(&request_path).map_err(|e| e.to_string())?;
        let mut request: cargo_subject::Request =
            serde_json::from_slice(&request_bytes).map_err(|e| e.to_string())?;
        request.manifest = request_path
            .parent()
            .ok_or("build request has no parent")?
            .join(&request.manifest);
        fs::create_dir_all(output).map_err(|e| e.to_string())?;
        let output = output.canonicalize().map_err(|e| e.to_string())?;
        for path in [
            config.to_owned(),
            request_path.clone(),
            base.join(&project.crate_root),
            base.join(&project.proofs),
        ]
        .into_iter()
        .chain(
            project
                .proof_modules
                .iter()
                .map(|module| base.join(&module.path)),
        ) {
            if path
                .canonicalize()
                .map_err(|e| e.to_string())?
                .starts_with(&output)
            {
                return Err("method build inputs must be outside output directory".into());
            }
        }
        let capture = cargo_capture::capture(request, &output.join("Cargo"))?;
        if capture.subject.packages.len() != 1 {
            return Err(
                "Cargo method verification requires dependency-free subject resolution".into(),
            );
        }
        let root = &capture.subject.packages[0];
        if root.edition != "2021"
            || root.targets.as_array().is_none_or(|targets| {
                targets.iter().any(|t| {
                    t["kind"].as_array().is_some_and(|kinds| {
                        kinds
                            .iter()
                            .any(|k| k == "custom-build" || k == "proc-macro")
                    })
                })
            })
        {
            return Err(
                "Cargo method verification requires Rust 2021 without build scripts or proc macros"
                    .into(),
            );
        }
        let source = base
            .join(&project.crate_root)
            .canonicalize()
            .map_err(|e| e.to_string())?;
        let unit = &capture.invocations[capture.configured_root_invocation];
        if !unit.arguments.iter().any(|arg| {
            unit.working_directory
                .join(arg)
                .canonicalize()
                .is_ok_and(|p| p == source)
        }) {
            return Err("method crate_root is not the captured Cargo library root".into());
        }
        let evidence_path = output.join("Cargo/captured-build.json");
        let evidence_bytes = fs::read(&evidence_path).map_err(|e| e.to_string())?;
        if evidence_bytes != serde_json::to_vec_pretty(&capture).map_err(|e| e.to_string())? {
            return Err("Cargo capture evidence changed before method verification".into());
        }
        Ok(Some(Self {
            capture,
            request_path,
            request_bytes,
            evidence_path,
            evidence_bytes,
        }))
    }
    pub fn cfg(&self) -> Result<&str, String> {
        self.capture.invocations[self.capture.configured_root_invocation]
            .effective_cfg
            .as_deref()
            .ok_or("captured root has no effective cfg".into())
    }
    pub fn bind_sources(&self, krate: &Crate) -> Result<(), String> {
        let package = self.capture.subject.packages[0]
            .manifest
            .parent()
            .ok_or("missing package directory")?;
        for (path, text) in &krate.files {
            if !self.capture.source_inventory.sources.iter().any(|source| {
                package
                    .join(&source.path)
                    .canonicalize()
                    .is_ok_and(|p| &p == path)
                    && source.sha256 == hash(text)
            }) {
                return Err("lowered source does not match captured Cargo inputs".into());
            }
        }
        Ok(())
    }
    pub fn revalidate(&self) -> Result<(), String> {
        if fs::read(&self.request_path).map_err(|e| e.to_string())? != self.request_bytes
            || fs::read(&self.evidence_path).map_err(|e| e.to_string())? != self.evidence_bytes
        {
            return Err("Cargo build request or evidence changed during verification".into());
        }
        let package = self.capture.subject.packages[0]
            .manifest
            .parent()
            .ok_or("missing package directory")?;
        for source in &self.capture.source_inventory.sources {
            for path in [
                package.join(&source.path),
                self.capture.run_directory.join("source").join(&source.path),
            ] {
                if hash(fs::read(path).map_err(|e| e.to_string())?) != source.sha256 {
                    return Err("Cargo source or snapshot changed during verification".into());
                }
            }
        }
        for (path, expected) in self.capture.subject.workspace_inputs.iter().chain(
            self.capture
                .subject
                .packages
                .iter()
                .map(|p| (&p.manifest, &p.manifest_sha256)),
        ) {
            if hash(fs::read(path).map_err(|e| e.to_string())?) != *expected {
                return Err("Cargo manifest or lockfile changed during verification".into());
            }
        }
        for compiler in &self.capture.compilers {
            if hash(fs::read(&compiler.executable).map_err(|e| e.to_string())?)
                != compiler.executable_sha256
            {
                return Err("captured compiler changed during verification".into());
            }
        }
        Ok(())
    }
    pub fn evidence(&self) -> serde_json::Value {
        serde_json::json!({"request_path":self.request_path,"request_sha256":hash(&self.request_bytes),
            "capture_path":"Cargo/captured-build.json","capture_sha256":hash(&self.evidence_bytes),
            "subject":self.capture.subject,"root_invocation":self.capture.invocations[self.capture.configured_root_invocation],
            "limitations":self.capture.limitations})
    }
}
