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
    if args.len() >= 4 && args[0] == "typed-generate" {
        // typed-generate <crate-root> <namespace> <root>...
        let lean = provium::typed::generate_host(Path::new(&args[1]), &args[3..], &args[2])?;
        print!("{lean}");
        return Ok(());
    }
    if args.first().map(String::as_str) == Some("mir-lean") {
        // mir-lean <file.mir> --crate-root <lib.rs> --namespace <Ns> --out <file.lean> [--skip-unsupported]
        return mir_lean(&args[1..]);
    }
    if args.first().map(String::as_str) == Some("mir-enc") {
        // mir-enc <project.json | lib.rs> [--namespace <Ns>] --out <file.lean> [--check <file.lean>] [--root <fn>]...
        return mir_enc(&args[1..]);
    }
    if args.len() == 1 && matches!(args[0].as_str(), "--help" | "-h") {
        println!("provium capture-cargo <build.json> --out <directory>\nprovium inspect-cargo <build.json> --out <directory>\nprovium inventory <crate-directory> --out <directory>\nprovium audit-coverage <crate-directory>\nprovium verify-complete <crate-directory> (fails until complete proof support exists)\n");
        println!("provium <compile|verify|verify-methods|verify-project> <project.json> --out <directory>\n\ncompile: generate source-linked Lean and IR (no proof success claim)\nverify: regenerate, run pinned Lean with trust=0, audit all obligations\nverify-methods: check supported complete method bodies and state contracts\nverify-project: verify any project kind with the backend assert_proofs! selects\n\nSupported Rust: closed scalar unsigned/bool functions; checked arithmetic,\nif expressions, local lets/assignments, assertions, acyclic source-local calls.\nUnsupported Rust is rejected. See README.md for the trusted boundary.");
        return Ok(());
    }
    if args.len() != 4 || args[2] != "--out" {
        return Err(
            "usage: provium <compile|verify|verify-methods|verify-project|inspect-cargo|capture-cargo|inventory> <input> --out <directory>; or <audit-coverage|verify-complete> <crate-directory>"
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
        "verify-typed" => println!(
            "{}",
            provium::typed::verify::verify(Path::new(&args[1]), Path::new(&args[3]))?
        ),
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
        "verify-project" => println!(
            "{}",
            provium::suite::verify_project(Path::new(&args[1]), Path::new(&args[3]))?.details
        ),
        _ => return Err("unknown command; run provium --help".into()),
    }
    Ok(())
}
fn mir_lean(args: &[String]) -> Result<(), String> {
    let usage = "usage: provium mir-lean <file.mir> --crate-root <lib.rs> --namespace <Ns> --out <file.lean> [--skip-unsupported]";
    let mir = args.first().ok_or(usage)?;
    let (mut root, mut ns, mut out, mut skip) = (None, None, None, false);
    let mut rest = args[1..].iter();
    while let Some(a) = rest.next() {
        match a.as_str() {
            "--crate-root" => root = rest.next(),
            "--namespace" => ns = rest.next(),
            "--out" => out = rest.next(),
            "--skip-unsupported" => skip = true,
            _ => return Err(usage.into()),
        }
    }
    let (root, ns, out) = (root.ok_or(usage)?, ns.ok_or(usage)?, out.ok_or(usage)?);
    let text = std::fs::read_to_string(mir).map_err(|e| format!("{mir}: {e}"))?;
    let src = provium::typed::mir::SourceMap::load(Path::new(root))?;
    let bodies = if skip {
        let (bodies, errors) = provium::typed::mir::parse_lenient(&text, &src)?;
        for e in &errors {
            eprintln!("provium: skipped {e}");
        }
        bodies
    } else {
        provium::typed::mir::parse(&text, &src)?
    };
    std::fs::write(out, provium::typed::mir::emit(&bodies, ns))
        .map_err(|e| format!("{out}: {e}"))?;
    println!("Emitted {} MIR bodies to {out}.", bodies.len());
    Ok(())
}
fn mir_enc(args: &[String]) -> Result<(), String> {
    let usage = "usage: provium mir-enc <project.json | lib.rs> [--namespace <Ns>] --out <file.lean> [--check <file.lean>] [--root <fn>]...";
    let input = args.first().ok_or(usage)?;
    let (mut ns, mut out, mut check, mut roots) = (None, None, None, vec![]);
    let mut rest = args[1..].iter();
    while let Some(a) = rest.next() {
        match a.as_str() {
            "--namespace" => ns = Some(rest.next().ok_or(usage)?),
            "--out" => out = Some(rest.next().ok_or(usage)?),
            "--check" => check = Some(rest.next().ok_or(usage)?),
            "--root" => roots.push(rest.next().ok_or(usage)?.clone()),
            _ => return Err(usage.into()),
        }
    }
    let out = out.ok_or(usage)?;
    let module = Path::new(out)
        .file_stem()
        .and_then(|s| s.to_str())
        .ok_or(usage)?;
    let o = provium::typed::mirenc::from_input(
        Path::new(input),
        &roots,
        ns.map(String::as_str),
        module,
    )?;
    std::fs::write(out, &o.lean).map_err(|e| format!("{out}: {e}"))?;
    if let Some(c) = check {
        std::fs::write(c, &o.checks).map_err(|e| format!("{c}: {e}"))?;
    }
    for (p, why) in &o.skipped {
        eprintln!("provium: no encoding for {p}: {why}");
    }
    for (c, why) in &o.unfolded {
        eprintln!("provium: mkAgg folds of {c} are not mir_enc lemmas: {why}");
    }
    println!("Emitted encodings of {} types to {out}.", o.encoded.len());
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
