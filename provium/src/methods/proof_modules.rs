//! Consumer proof libraries and a fresh import environment for each verification.
use super::*;
use std::sync::atomic::{AtomicUsize, Ordering};

pub(super) struct Loaded {
    pub module: String,
    pub path: PathBuf,
    pub artifact: String,
    pub source: String,
}
pub(super) fn load(base: &Path, modules: &[ProofModule]) -> Result<Vec<Loaded>, String> {
    let mut names = std::collections::BTreeSet::new();
    modules
        .iter()
        .map(|module| {
            let root = module
                .name
                .split('.')
                .next()
                .unwrap_or("")
                .to_ascii_lowercase();
            if !module.name.split('.').all(identifier)
                || [
                    "generated",
                    "proofs",
                    "check",
                    "provium",
                    "init",
                    "lean",
                    "lake",
                    "std",
                ]
                .contains(&root.as_str())
                || !names.insert(module.name.to_ascii_lowercase())
            {
                return Err(format!(
                    "invalid, reserved or duplicate proof module {}",
                    module.name
                ));
            }
            let path = base
                .join(&module.path)
                .canonicalize()
                .map_err(|e| e.to_string())?;
            let source = fs::read_to_string(&path).map_err(|e| e.to_string())?;
            Ok(Loaded {
                module: module.name.clone(),
                path,
                artifact: format!("{}.lean", module.name.replace('.', "/")),
                source,
            })
        })
        .collect()
}

static NEXT: AtomicUsize = AtomicUsize::new(0);
pub(super) struct Workspace(PathBuf);
impl Workspace {
    pub fn new(out: &Path) -> Result<Self, String> {
        // create_dir, rather than create_dir_all, prevents reusing a previous
        // invocation's modules or following a pre-existing directory symlink.
        loop {
            let path = out.join(format!(
                "lean-build-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            match fs::create_dir(&path) {
                Ok(()) => return Ok(Self(path)),
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(e) => return Err(e.to_string()),
            }
        }
    }
    pub fn write(&self, file: &str, source: &str) -> Result<(), String> {
        let path = self.0.join(file);
        fs::create_dir_all(path.parent().unwrap()).map_err(|e| e.to_string())?;
        fs::write(path, source).map_err(|e| e.to_string())
    }
    pub fn source_unchanged(&self, file: &str, source: &str) -> Result<(), String> {
        if fs::read_to_string(self.0.join(file)).map_err(|e| e.to_string())? != source {
            return Err("Lean build source changed during verification".into());
        }
        Ok(())
    }
    pub fn check(&self, file: &str, object: Option<&str>) -> Result<String, String> {
        crate::project::lean_file(&self.0, file, object)
    }
    pub fn publish(&self, object: &str, out: &Path) -> Result<(), String> {
        let path = out.join(object);
        fs::create_dir_all(path.parent().unwrap()).map_err(|e| e.to_string())?;
        fs::copy(self.0.join(object), path).map_err(|e| e.to_string())?;
        Ok(())
    }
}
impl Drop for Workspace {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
