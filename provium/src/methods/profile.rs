//! Compiler-option interpretation, still within the trusted frontend boundary.
//! The effective cfg supplies panic mode and the overflow-check default; an
//! explicit codegen option overrides that default regardless of Cargo profile.
use serde::Serialize;

#[derive(Debug, Serialize, PartialEq, Eq)]
pub(super) struct Profile {
    pub overflow_checked: bool,
    pub panic_abort: bool,
}

fn enabled(value: &str) -> Result<bool, String> {
    match value {
        "y" | "yes" | "on" | "true" => Ok(true),
        "n" | "no" | "off" | "false" => Ok(false),
        _ => Err("unsupported overflow-checks value".into()),
    }
}

impl Profile {
    pub fn from_invocation(cfg: &str, arguments: &[String]) -> Result<Self, String> {
        let mut debug = false;
        let mut panic_abort = None;
        for line in cfg.lines().filter(|line| !line.trim().is_empty()) {
            let meta = syn::parse_str::<syn::Meta>(line).map_err(|e| e.to_string())?;
            if meta.path().is_ident("debug_assertions") {
                if !matches!(meta, syn::Meta::Path(_)) || debug {
                    return Err("ambiguous effective debug_assertions cfg".into());
                }
                debug = true;
            } else if meta.path().is_ident("panic") {
                let syn::Meta::NameValue(pair) = meta else {
                    return Err("panic cfg must have a unique string value".into());
                };
                let syn::Expr::Lit(lit) = pair.value else {
                    return Err("panic cfg must have a unique string value".into());
                };
                let syn::Lit::Str(value) = lit.lit else {
                    return Err("panic cfg must have a unique string value".into());
                };
                let abort = match value.value().as_str() {
                    "abort" => true,
                    "unwind" => false,
                    _ => return Err("unsupported effective panic strategy".into()),
                };
                if panic_abort.replace(abort).is_some() {
                    return Err("ambiguous effective panic strategy".into());
                }
            }
        }
        let mut overflow_checked = debug;
        let mut args = arguments.iter();
        while let Some(arg) = args.next() {
            // The capture layer also rejects response files. Retain this guard
            // here so options hidden in one cannot silently acquire defaults.
            if arg.starts_with('@') {
                return Err("response-file options are unsupported".into());
            }
            if arg.starts_with("-Z") {
                return Err("unstable compiler options have no admitted profile semantics".into());
            }
            let injected = if arg == "--cfg" {
                Some(args.next().ok_or("cfg option is missing")?.as_str())
            } else {
                arg.strip_prefix("--cfg=")
            };
            if let Some(injected) = injected {
                let predicate = syn::parse_str::<syn::Meta>(injected).map_err(|e| e.to_string())?;
                if ["debug_assertions", "panic", "target_pointer_width"]
                    .iter()
                    .any(|key| predicate.path().is_ident(key))
                {
                    return Err("injected builtin cfg has no admitted profile semantics".into());
                }
                continue;
            }
            let option = if arg == "-C" || arg == "--codegen" {
                Some(args.next().ok_or("codegen option is missing")?.as_str())
            } else {
                arg.strip_prefix("-C")
                    .or_else(|| arg.strip_prefix("--codegen="))
            };
            if let Some(option) = option {
                let option = option.strip_prefix('=').unwrap_or(option);
                let (name, value) = option
                    .split_once('=')
                    .map_or((option, None), |(name, value)| (name, Some(value)));
                if name.replace('_', "-") == "overflow-checks" {
                    overflow_checked = value.map(enabled).transpose()?.unwrap_or(true);
                }
            }
        }
        Ok(Self {
            overflow_checked,
            panic_abort: panic_abort.ok_or("effective compiler cfg omits panic strategy")?,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::Profile;

    fn profile(cfg: &str, arguments: &[&str]) -> Result<Profile, String> {
        Profile::from_invocation(
            cfg,
            &arguments
                .iter()
                .map(|a| (*a).to_owned())
                .collect::<Vec<_>>(),
        )
    }

    #[test]
    fn effective_options_override_cfg_defaults_in_argument_order() {
        for (cfg, checked, abort) in [
            ("debug_assertions\npanic=\"unwind\"", true, false),
            ("panic=\"abort\"", false, true),
        ] {
            assert_eq!(
                profile(cfg, &[]).unwrap(),
                Profile {
                    overflow_checked: checked,
                    panic_abort: abort,
                }
            );
            for flag in ["y", "yes", "on", "true", "n", "no", "off", "false"] {
                for args in [
                    vec!["-C".into(), format!("overflow-checks={flag}")],
                    vec![format!("-Coverflow-checks={flag}")],
                    vec!["--codegen".into(), format!("overflow-checks={flag}")],
                    vec![format!("--codegen=overflow-checks={flag}")],
                ] {
                    assert_eq!(
                        Profile::from_invocation(cfg, &args)
                            .unwrap()
                            .overflow_checked,
                        matches!(flag, "y" | "yes" | "on" | "true")
                    );
                }
            }
            assert!(
                profile(cfg, &["-Coverflow-checks=no", "--codegen=overflow-checks"])
                    .unwrap()
                    .overflow_checked
            );
            assert!(
                !profile(cfg, &["-Coverflow-checks=yes", "-C", "overflow-checks=no"])
                    .unwrap()
                    .overflow_checked
            );
        }
    }

    #[test]
    fn ambiguous_or_unsupported_modes_fail_closed() {
        for cfg in [
            "",
            "panic",
            "panic=0",
            "panic=\"immediate-abort\"",
            "panic=\"abort\"\npanic=\"unwind\"",
            "panic=\"abort\"\ndebug_assertions\ndebug_assertions",
            "panic=\"abort\"\ndebug_assertions=\"yes\"",
        ] {
            assert!(profile(cfg, &[]).is_err(), "accepted {cfg}");
        }
        for args in [
            vec!["-C"],
            vec!["--codegen"],
            vec!["@hidden"],
            vec!["-Coverflow-checks=maybe"],
            vec!["--cfg", "debug_assertions"],
            vec!["--cfg=panic=\"abort\""],
            vec!["--cfg=target_pointer_width=\"32\""],
            vec!["-Zforce-overflow-checks=yes"],
        ] {
            assert!(profile("panic=\"abort\"", &args).is_err());
        }
    }

    #[test]
    fn profile_interpretation_matches_native_overflow_and_override_order() {
        use std::{fs, path::PathBuf, process::Command};
        struct Work(PathBuf);
        impl Drop for Work {
            fn drop(&mut self) {
                let _ = fs::remove_dir_all(&self.0);
            }
        }
        let work = Work(
            PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("artifacts")
                .join(format!("profile-native-{}", std::process::id())),
        );
        fs::create_dir_all(&work.0).unwrap();
        let source = work.0.join("main.rs");
        fs::write(
            &source,
            r#"fn main() {
    std::panic::set_hook(Box::new(|_| {}));
    let input = std::hint::black_box(u8::MAX);
    let result = std::panic::catch_unwind(|| std::hint::black_box(input) + 1);
    print!("{}", result.is_err());
}"#,
        )
        .unwrap();
        let cases: &[&[&str]] = &[
            &[],
            &["-O"],
            &["-O", "-Cdebug-assertions=yes"],
            &["-Cdebug-assertions=no"],
            &["-Coverflow-checks=no"],
            &["-O", "-Coverflow-checks=yes"],
            &["-Coverflow_checks=no", "--codegen", "overflow-checks=yes"],
            &["-C", "overflow-checks=yes", "--codegen=overflow-checks=no"],
        ];
        for (i, options) in cases.iter().enumerate() {
            let mut args = vec!["--edition=2021".to_owned(), "-Cpanic=unwind".to_owned()];
            args.extend(options.iter().map(|s| (*s).to_owned()));
            let cfg = Command::new("rustc")
                .args(&args)
                .args(["--print", "cfg"])
                .output()
                .unwrap();
            assert!(
                cfg.status.success(),
                "{}",
                String::from_utf8_lossy(&cfg.stderr)
            );
            let interpreted =
                Profile::from_invocation(&String::from_utf8(cfg.stdout).unwrap(), &args).unwrap();
            assert!(!interpreted.panic_abort);
            let binary = work.0.join(format!("case-{i}"));
            let built = Command::new("rustc")
                .args(&args)
                .arg(&source)
                .arg("-o")
                .arg(&binary)
                .output()
                .unwrap();
            assert!(
                built.status.success(),
                "{}",
                String::from_utf8_lossy(&built.stderr)
            );
            let ran = Command::new(binary).output().unwrap();
            assert!(ran.status.success());
            assert_eq!(
                String::from_utf8(ran.stdout).unwrap(),
                interpreted.overflow_checked.to_string(),
                "{options:?}"
            );
        }
    }
}
