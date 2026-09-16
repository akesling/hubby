use std::{path::Path, process::ExitCode};
fn run() -> Result<(), String> {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    if args.len() == 2 && matches!(args[0].as_str(), "audit-coverage" | "verify-complete") {
        let root = Path::new(&args[1]);
        let ledger = root.join("proofs/coverage.json");
        if args[0] == "verify-complete" {
            provium::coverage::require_complete(root, Path::new("src/lib.rs"), &ledger)?;
        } else {
            let report = provium::coverage::audit(root, Path::new("src/lib.rs"), &ledger)?;
            println!("Coverage accounting current: {} items, {} with declared component evidence. This is not a correctness certificate.", report.items, report.component_items);
        }
        return Ok(());
    }
    if args.len() == 1 && matches!(args[0].as_str(), "--help" | "-h") {
        println!("provium capture-cargo <build.json> --out <directory>\nprovium inspect-cargo <build.json> --out <directory>\nprovium inventory <crate-directory> --out <directory>\nprovium audit-coverage <crate-directory>\nprovium verify-complete <crate-directory> (fails until complete proof support exists)\n");
        println!("provium <compile|verify|verify-methods> <project.json> --out <directory>\n\ncompile: generate source-linked Lean and IR (no proof success claim)\nverify: regenerate, run pinned Lean with trust=0, audit all obligations\nverify-methods: check supported complete method bodies and state contracts\n\nSupported Rust: closed scalar unsigned/bool functions; checked arithmetic,\nif expressions, local lets/assignments, assertions, acyclic source-local calls.\nUnsupported Rust is rejected. See README.md for the trusted boundary.");
        return Ok(());
    }
    if args.len() != 4 || args[2] != "--out" {
        return Err(
            "usage: provium <compile|verify|verify-methods|inspect-cargo|capture-cargo|inventory> <input> --out <directory>; or <audit-coverage|verify-complete> <crate-directory>"
                .into(),
        );
    }
    match args[0].as_str() {
        "inspect-cargo" | "capture-cargo" => {
            let config = Path::new(&args[1]);
            let mut request: provium::cargo_subject::Request =
                serde_json::from_slice(&std::fs::read(config).map_err(|e| e.to_string())?)
                    .map_err(|e| e.to_string())?;
            request.manifest = config
                .parent()
                .unwrap_or(Path::new("."))
                .join(request.manifest);
            if args[0] == "capture-cargo" {
                let report = provium::cargo_capture::capture(request, Path::new(&args[3]))?;
                println!(
                    "Captured {} actual compiler invocations; no semantic preservation claim.",
                    report.invocations.len()
                );
                return Ok(());
            }
            let report = provium::cargo_subject::write(request, Path::new(&args[3]))?;
            println!(
                "Recorded {} normal/build dependency packages for {}. No semantic proof claim.",
                report.packages.len(),
                report.request.target
            );
        }
        "inventory" => {
            let inventory = provium::coverage::write_inventory(
                Path::new(&args[1]),
                Path::new("src/lib.rs"),
                Path::new(&args[3]),
            )?;
            println!(
                "Inventoried {} items. No call closure or proof claim.",
                inventory.items.len()
            );
        }
        "verify-methods" => println!(
            "{}",
            provium::methods::verify(Path::new(&args[1]), Path::new(&args[3]))?
        ),
        "compile" => {
            let manifest = provium::project::compile(Path::new(&args[1]), Path::new(&args[3]))?;
            println!(
                "Generated {} functions in {}. No proofs checked.\nTranslated Rust SHA-256: {}",
                manifest.functions.len(),
                args[3],
                manifest.source_sha256
            );
        }
        "verify" => println!(
            "{}",
            provium::project::verify(Path::new(&args[1]), Path::new(&args[3]))?
        ),
        _ => return Err("unknown command; run provium --help".into()),
    }
    Ok(())
}
fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("provium: {error}");
            ExitCode::FAILURE
        }
    }
}
