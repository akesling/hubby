use std::{path::Path, process::ExitCode};
fn run() -> Result<(), String> {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    if args.len() == 1 && matches!(args[0].as_str(), "--help" | "-h") {
        println!("provium <compile|verify> <project.json> --out <directory>\n\ncompile: generate source-linked Lean and IR (no proof success claim)\nverify: regenerate, run pinned Lean with trust=0, audit all obligations\n\nSupported Rust: closed scalar unsigned/bool functions; checked arithmetic,\nif expressions, local lets/assignments, assertions, acyclic source-local calls.\nUnsupported Rust is rejected. See README.md for the trusted boundary.");
        return Ok(());
    }
    if args.len() != 4 || args[2] != "--out" {
        return Err("usage: provium <compile|verify> <project.json> --out <directory>".into());
    }
    match args[0].as_str() {
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
        _ => return Err("expected compile or verify".into()),
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
