//! Kernel-checked specification witnesses, explicitly separate from Rust proofs.
//! These projects establish consistency facts about a consumer's handwritten
//! model. They never provide source correspondence or a whole-program certificate.
use crate::project::{hash, lean_file, prepare_output, AUDIT, TOOLCHAIN};
use serde::Deserialize;
use std::{collections::BTreeSet, fs, path::Path};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Obligation {
    theorem: String,
    definition: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Project {
    kind: String,
    schema: u32,
    proofs: String,
    obligations: Vec<Obligation>,
}
fn identifier(value: &str) -> bool {
    value.split('.').all(|part| {
        !part.is_empty()
            && part != "_"
            && part
                .bytes()
                .enumerate()
                .all(|(i, c)| c.is_ascii_alphabetic() || c == b'_' || (i > 0 && c.is_ascii_digit()))
    })
}

/// Check a self-contained Lean specification, with only the pinned Lean library
/// imported by the verifier. Every obligation must reference its named definition
/// in its statement and pass the transitive axiom audit. Evidence is labelled
/// `specification_only`; no Rust source is translated by this entry point.
pub fn verify(project: &Path, output: &Path) -> Result<String, String> {
    prepare_output(output)?;
    let read = |path: &Path| fs::read(path).map_err(|e| format!("{}: {e}", path.display()));
    let config = read(project)?;
    let request: Project = serde_json::from_slice(&config).map_err(|e| e.to_string())?;
    if request.kind != "specification" || request.schema != 1 || request.obligations.is_empty() {
        return Err("specification requires schema 1 and nonempty obligations".into());
    }
    let mut names = BTreeSet::new();
    for obligation in &request.obligations {
        if !identifier(&obligation.theorem)
            || !identifier(&obligation.definition)
            || !names.insert(&obligation.theorem)
        {
            return Err("invalid or repeated specification obligation".into());
        }
    }
    let directory = project
        .parent()
        .ok_or("project has no parent")?
        .canonicalize()
        .map_err(|e| e.to_string())?;
    let input = directory
        .join(&request.proofs)
        .canonicalize()
        .map_err(|e| e.to_string())?;
    if !input.starts_with(&directory) {
        return Err("specification must belong to its project directory".into());
    }
    let source = read(&input)?;
    let text = std::str::from_utf8(&source).map_err(|e| e.to_string())?;
    // Deliberately conservative: reject this word even in comments/strings.
    // No unaccounted local module or stale object may enter the specification.
    if text
        .split(|c: char| !c.is_alphanumeric() && c != '_')
        .any(|s| s == "import")
    {
        return Err(
            "self-contained specification must not contain import; Lean is supplied".into(),
        );
    }
    fs::create_dir_all(output).map_err(|e| e.to_string())?;
    let output = output.canonicalize().map_err(|e| e.to_string())?;
    if input.starts_with(&output)
        || project
            .canonicalize()
            .map_err(|e| e.to_string())?
            .starts_with(&output)
    {
        return Err("specification output must not contain its inputs".into());
    }
    let generated = format!("import Lean\n{text}");
    let mut audit = "import Specification\nimport Provium.Audit\n".to_owned();
    for obligation in &request.obligations {
        audit.push_str(&format!(
            "#provium_check {} references {}\n",
            obligation.theorem, obligation.definition
        ));
    }
    fs::create_dir_all(output.join("Provium")).map_err(|e| e.to_string())?;
    for (path, content) in [
        ("Specification.lean", generated.as_str()),
        ("Provium/Audit.lean", AUDIT),
        ("Check.lean", audit.as_str()),
    ] {
        fs::write(output.join(path), content).map_err(|e| e.to_string())?;
    }
    lean_file(&output, "Provium/Audit.lean", Some("Provium/Audit.olean"))?;
    lean_file(&output, "Specification.lean", Some("Specification.olean"))?;
    let report = lean_file(&output, "Check.lean", None)?;
    if read(project)? != config || read(&input)? != source {
        return Err("specification inputs changed during verification".into());
    }
    for (path, content) in [
        ("Specification.lean", generated.as_str()),
        ("Provium/Audit.lean", AUDIT),
        ("Check.lean", audit.as_str()),
    ] {
        if read(&output.join(path))? != content.as_bytes() {
            return Err("specification artifacts changed during verification".into());
        }
    }
    let certificate = serde_json::json!({
        "schema":1, "kind":"specification_only", "whole_program_proved":false,
        "source_correspondence_proved":false, "lean_toolchain":TOOLCHAIN,
        "config_sha256":hash(config), "specification_sha256":hash(source),
        "generated_sha256":hash(generated), "audit_sha256":hash(AUDIT),
        "check_sha256":hash(audit), "obligations":request.obligations.len(), "audit":report,
        "trust_boundary":"Handwritten model consistency only. No Rust execution, compiler correspondence, protocol safety, or progress theorem is certified."
    });
    fs::write(
        output.join("verified.json"),
        serde_json::to_vec_pretty(&certificate).map_err(|e| e.to_string())?,
    )
    .map_err(|e| e.to_string())?;
    Ok(format!(
        "Verified {} specification obligations; no source correspondence claim.\n{report}",
        request.obligations.len()
    ))
}
