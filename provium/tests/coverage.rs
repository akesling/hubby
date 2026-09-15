use provium::coverage::{audit, inventory, require_complete, Entry, Ledger, Status};
use std::{
    fs,
    path::{Path, PathBuf},
    sync::atomic::{AtomicUsize, Ordering},
};
static NEXT: AtomicUsize = AtomicUsize::new(0);
struct Subject(PathBuf);
impl Subject {
    fn new() -> Self {
        let root = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("artifacts")
            .join(format!(
                "coverage-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
        fs::create_dir_all(root.join("src/nested")).unwrap();
        fs::write(
            root.join("src/lib.rs"),
            "mod nested; pub use nested::State; #[cfg(test)] mod unavailable_tests;",
        )
        .unwrap();
        fs::write(root.join("src/nested.rs"), "pub struct State { pub ready: bool } impl State { pub fn clear(&mut self) { self.ready = false; } } mod deeper;").unwrap();
        fs::write(
            root.join("src/nested/deeper.rs"),
            "pub fn helper() { external::effect(); }",
        )
        .unwrap();
        Self(root)
    }
    fn ledger(&self) -> Ledger {
        let inventory = inventory(&self.0, Path::new("src/lib.rs")).unwrap();
        let entries = inventory
            .items
            .iter()
            .map(|item| {
                (
                    item.id.clone(),
                    Entry {
                        requirements: vec!["C01".into()],
                        status: Status::Planned,
                        note: "Not translated or proved".into(),
                    },
                )
            })
            .collect();
        Ledger {
            schema: 1,
            inventory,
            entries,
        }
    }
    fn save(&self, ledger: &Ledger) -> PathBuf {
        let path = self.0.join("coverage.json");
        fs::write(&path, serde_json::to_vec_pretty(ledger).unwrap()).unwrap();
        path
    }
}
impl Drop for Subject {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn follows_modules_and_records_unresolved_calls_without_proof_claims() {
    let subject = Subject::new();
    let ledger = subject.ledger();
    assert_eq!(ledger.inventory.sources.len(), 3);
    assert!(
        ledger
            .inventory
            .items
            .iter()
            .any(|i| i.id == "crate::nested::deeper::helper"
                && i.calls == ["call external :: effect"])
    );
    let path = subject.save(&ledger);
    assert_eq!(
        audit(&subject.0, Path::new("src/lib.rs"), &path)
            .unwrap()
            .component_items,
        0
    );
    assert!(require_complete(&subject.0, Path::new("src/lib.rs"), &path)
        .unwrap_err()
        .contains("full proof unavailable"));
}

#[test]
fn source_changes_and_unclassified_items_cannot_pass_accounting() {
    let subject = Subject::new();
    let mut ledger = subject.ledger();
    let path = subject.save(&ledger);
    fs::write(
        subject.0.join("src/nested/deeper.rs"),
        "pub fn helper() {} pub fn new_api() {}",
    )
    .unwrap();
    assert!(audit(&subject.0, Path::new("src/lib.rs"), &path)
        .unwrap_err()
        .contains("stale"));
    ledger = subject.ledger();
    ledger.entries.pop_first();
    let path = subject.save(&ledger);
    assert!(audit(&subject.0, Path::new("src/lib.rs"), &path)
        .unwrap_err()
        .contains("exactly every"));
}

#[test]
fn changed_variants_fields_and_late_effects_invalidate_review() {
    for code in [
        "pub struct State { pub ready: bool, pub new_field: bool }",
        "pub enum State { Ready, NewlyAdded }",
        "pub struct State { pub ready: bool } impl State { pub fn clear(&mut self) { self.ready = false; panic!(\"late effect\"); } }",
    ] {
        let subject = Subject::new();
        let path = subject.save(&subject.ledger());
        fs::write(subject.0.join("src/nested.rs"), code).unwrap();
        assert!(audit(&subject.0, Path::new("src/lib.rs"), &path).is_err());
    }
}

#[test]
fn component_labels_cannot_promote_a_ledger_to_complete() {
    let subject = Subject::new();
    let mut ledger = subject.ledger();
    for entry in ledger.entries.values_mut() {
        entry.status = Status::ComponentEvidence;
    }
    let path = subject.save(&ledger);
    assert!(require_complete(&subject.0, Path::new("src/lib.rs"), &path).is_err());
    let mut json = serde_json::to_value(ledger).unwrap();
    json["entries"]
        .as_object_mut()
        .unwrap()
        .values_mut()
        .next()
        .unwrap()["status"] = "complete".into();
    fs::write(&path, serde_json::to_vec(&json).unwrap()).unwrap();
    assert!(audit(&subject.0, Path::new("src/lib.rs"), &path).is_err());
}

#[test]
fn ambiguous_modules_and_path_redirection_fail_explicitly() {
    let subject = Subject::new();
    fs::write(subject.0.join("src/nested/mod.rs"), "").unwrap();
    assert!(inventory(&subject.0, Path::new("src/lib.rs"))
        .unwrap_err()
        .contains("ambiguous"));
    fs::write(
        subject.0.join("src/lib.rs"),
        "#[path = \"nested.rs\"] mod redirected;",
    )
    .unwrap();
    assert!(inventory(&subject.0, Path::new("src/lib.rs"))
        .unwrap_err()
        .contains("#[path]"));
}
