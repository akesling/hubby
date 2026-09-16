use provium::{cfg::Configuration, coverage};
use std::{
    fs,
    path::PathBuf,
    sync::atomic::{AtomicUsize, Ordering},
};
static NEXT: AtomicUsize = AtomicUsize::new(0);
struct Source(PathBuf);
impl Source {
    fn new(source: &str) -> Self {
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("artifacts")
            .join(format!(
                "cfg-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
        fs::create_dir_all(&path).unwrap();
        fs::write(path.join("lib.rs"), source).unwrap();
        Self(path)
    }
    fn inventory(&self, cfg: &str) -> Result<coverage::Inventory, String> {
        coverage::inventory_configured(&self.0, &self.0.join("lib.rs"), &Configuration::parse(cfg)?)
    }
}
impl Drop for Source {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
#[test]
fn cfg_operators_multivalued_keys_and_rejection() {
    let cfg = Configuration::parse(
        "unix\nfeature=\"one\"\nfeature=\"two\"\ntarget_pointer_width=\"64\"\n",
    )
    .unwrap();
    for (predicate, expected) in [
        ("all()", true),
        ("any()", false),
        ("not(unix)", false),
        ("r#unix", true),
        (
            "all(unix, any(feature=\"one\", feature=\"missing\"), feature=\"two\",)",
            true,
        ),
        ("all(target_pointer_width=\"32\", unix)", false),
        ("unknown", false),
    ] {
        assert_eq!(
            cfg.evaluate(&syn::parse_str(predicate).unwrap()).unwrap(),
            expected,
            "{predicate}"
        );
    }
    for predicate in [
        "not()",
        "not(unix,unix)",
        "maybe(unix)",
        "feature=3",
        "qualified::name",
        "any(unix,unsupported())",
    ] {
        assert!(
            cfg.evaluate(&syn::parse_str(predicate).unwrap()).is_err(),
            "{predicate}"
        );
    }
    assert!(Configuration::parse("all(unix)").is_err());
    assert!(Configuration::parse("feature=1").is_err());
}
#[test]
fn selects_nested_declarations_without_loading_disabled_modules() {
    let source = Source::new(
        r#"
        #[cfg(feature="missing")] mod nonexistent;
        #[cfg_attr(unix, cfg(feature="chosen"))]
        mod selected {
            pub struct Item;
            impl Item {
                #[cfg(target_pointer_width="32")] pub fn narrow() {}
                #[cfg(target_pointer_width="64")] pub fn wide() {}
            }
            pub trait Interface {
                #[cfg(unix)] fn active();
                #[cfg(not(unix))] fn inactive();
            }
        }
        #[cfg_attr(unix, cfg_attr(feature="chosen", cfg(any())))] fn excluded() {}
        #[cfg(not(unix))] fn alternative() {}
    "#,
    );
    let inventory = source
        .inventory("unix\nfeature=\"chosen\"\ntarget_pointer_width=\"64\"\n")
        .unwrap();
    let ids = inventory
        .items
        .iter()
        .map(|i| i.id.as_str())
        .collect::<Vec<_>>();
    assert!(ids.iter().any(|id| id.ends_with("::wide")));
    assert!(ids.iter().any(|id| id.ends_with("::active")));
    for excluded in [
        "narrow",
        "inactive",
        "excluded",
        "alternative",
        "nonexistent",
    ] {
        assert!(!ids.iter().any(|id| id.ends_with(excluded)), "{excluded}");
    }
    assert_eq!(inventory.sources.len(), 1);
    let other = source.inventory("").unwrap();
    assert!(other.items.iter().any(|i| i.id == "crate::alternative"));
}
#[test]
fn cfg_attr_cannot_hide_an_active_path_override() {
    let source = Source::new("#[cfg_attr(unix, path=\"different.rs\")] mod child;");
    fs::write(source.0.join("child.rs"), "pub fn ordinary() {}").unwrap();
    assert!(source.inventory("unix").unwrap_err().contains("#[path]"));
    assert!(source
        .inventory("")
        .unwrap()
        .items
        .iter()
        .any(|i| i.id.ends_with("ordinary")));
}
#[test]
fn crate_cfg_and_multiple_guards_are_conjunctive() {
    let source =
        Source::new("#![cfg(unix)]\n#[cfg(unix)] #[cfg(feature=\"chosen\")] fn gated() {}\n");
    assert!(source.inventory("").unwrap().items.is_empty());
    assert!(source.inventory("unix").unwrap().items.is_empty());
    assert_eq!(
        source
            .inventory("unix\nfeature=\"chosen\"")
            .unwrap()
            .items
            .len(),
        1
    );
}

#[test]
fn predicate_results_match_installed_rustc_across_configurations() {
    let predicates = [
        "all()",
        "any()",
        "r#custom",
        "not(custom)",
        "all(custom, any(feature=\"x\", feature=\"y\"))",
        "all(feature=\"x\", feature=\"y\")",
        "not(any(custom, feature=\"x\"))",
    ];
    let body = format!(
        "fn main() {{ for value in [{}] {{ println!(\"{{value}}\"); }} }}",
        predicates
            .iter()
            .map(|p| format!("cfg!({p})"))
            .collect::<Vec<_>>()
            .join(",")
    );
    let source = Source::new(&body);
    for mask in 0..8 {
        let flags = ["custom", "feature=\"x\"", "feature=\"y\""]
            .into_iter()
            .enumerate()
            .filter(|(bit, _)| mask & (1 << bit) != 0)
            .map(|(_, flag)| flag)
            .collect::<Vec<_>>();
        let cfg = Configuration::parse(&flags.join("\n")).unwrap();
        let mut compiler = std::process::Command::new("rustc");
        compiler
            .arg(source.0.join("lib.rs"))
            .args(["--edition=2021", "--crate-name=cfg_fixture", "-o"])
            .arg(source.0.join("fixture"));
        for flag in &flags {
            compiler.args(["--cfg", flag]);
        }
        let compiled = compiler.output().unwrap();
        assert!(
            compiled.status.success(),
            "{}",
            String::from_utf8_lossy(&compiled.stderr)
        );
        let result = std::process::Command::new(source.0.join("fixture"))
            .output()
            .unwrap();
        assert!(result.status.success());
        let expected = predicates
            .iter()
            .map(|p| format!("{}\n", cfg.evaluate(&syn::parse_str(p).unwrap()).unwrap()))
            .collect::<String>();
        assert_eq!(
            String::from_utf8(result.stdout).unwrap(),
            expected,
            "configuration {mask}"
        );
    }
}
