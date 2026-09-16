use provium::methods::Crate;
use std::{
    fs,
    path::PathBuf,
    process::Command,
    sync::atomic::{AtomicUsize, Ordering},
};
static NEXT: AtomicUsize = AtomicUsize::new(0);
struct Work(PathBuf);
impl Work {
    fn new(source: &str) -> Self {
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("artifacts")
            .join(format!(
                "projection-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
        fs::create_dir_all(&path).unwrap();
        fs::write(path.join("source.rs"), source).unwrap();
        Self(path)
    }
    fn lower(&self) -> Result<provium::methods::Method, String> {
        Crate::load(&self.0.join("source.rs"))?.lower("Table::keys")
    }
}
impl Drop for Work {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
const SOURCE: &str = r#"
#[derive(Clone, Copy)] struct Key(u64);
struct Row { key: Key, alternate: Key, enabled: bool, retired: bool }
struct Table<const N: usize> { rows: [Option<Row>; N] }
impl<const N: usize> Table<N> {
    fn keys(&self) -> impl Iterator<Item = Key> + '_ {
        self.rows.iter().flatten().filter(|r| r.enabled && !r.retired).map(|r| r.key)
    }
}
"#;

#[test]
fn complete_projection_retains_filter_field_and_copy_type() {
    let work = Work::new(SOURCE);
    let method = work.lower().unwrap();
    let shape = method.array.unwrap();
    assert_eq!(shape.projection.unwrap(), ["key"]);
    assert_eq!(shape.field, "rows");
    for source in [
        SOURCE.replace(".map(|r| r.key)", ".map(|r| r.key.clone())"),
        SOURCE.replace(".map(|r| r.key)", ".map(|r| { panic!(); r.key })"),
        SOURCE.replace("self.rows.iter()", "panic!(); self.rows.iter()"),
        SOURCE.replace("|r| r.enabled && !r.retired", "|r| external(r)"),
        SOURCE.replace(".map(|r| r.key)", ".map(move |r| r.key)"),
        SOURCE.replace("Item = Key", "Item = u64"),
        SOURCE.replace("Clone, Copy", "Clone"),
        SOURCE.replace(
            "impl Iterator<Item = Key> + '_",
            "impl Iterator<Item = Key> + Send + '_",
        ),
        format!("{SOURCE}\ntrait Foreign {{ fn filter(self); }}"),
        SOURCE
            .replace(
                "rows: [Option<Row>; N]",
                "rows: [Option<Row>; N], enabled: bool",
            )
            .replace("|r| r.enabled", "|r| self.enabled"),
        SOURCE
            .replace("rows: [Option<Row>; N]", "rows: [Option<Row>; N], key: Key")
            .replace(".map(|r| r.key)", ".map(|r| self.key)"),
        SOURCE.replace(
            "struct Row { key: Key, alternate: Key, enabled: bool, retired: bool }",
            "enum Row { Empty }",
        ),
    ] {
        assert!(Work::new(&source).lower().is_err(), "accepted {source}");
    }
    let scalar = SOURCE
        .replace("key: Key", "key: u64")
        .replace("Item = Key", "Item = u64");
    Work::new(&scalar).lower().unwrap();
    for import in ["use core::iter::Iterator;", "use std::iter::Iterator;"] {
        Work::new(&format!("{import}\n{SOURCE}")).lower().unwrap();
    }
}

#[test]
fn native_projection_preserves_order_values_and_payload_drop_counts() {
    let work = Work::new(SOURCE);
    let native = format!(
        "{SOURCE}\n{}",
        r#"
static DROPS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
impl Drop for Row { fn drop(&mut self) { DROPS.fetch_add(1, std::sync::atomic::Ordering::Relaxed); } }
fn main() {
 for mask in 0usize..4096 {
  let before = DROPS.load(std::sync::atomic::Ordering::Relaxed);
  let table: Table<4> = Table { rows: core::array::from_fn(|i| {
   let flags = (mask >> (3 * i)) & 7;
   (flags & 1 != 0).then_some(Row { key: Key(i as u64), alternate: Key(99), enabled: flags & 2 != 0, retired: flags & 4 != 0 })
  }) };
  let created = DROPS.load(std::sync::atomic::Ordering::Relaxed);
  println!("{:?}", table.keys().map(|k| k.0).collect::<Vec<_>>());
  assert_eq!(DROPS.load(std::sync::atomic::Ordering::Relaxed), created);
  drop(table);
  assert_eq!(DROPS.load(std::sync::atomic::Ordering::Relaxed) - before, 4);
 }
}
"#
    );
    fs::write(work.0.join("native.rs"), native).unwrap();
    let binary = work.0.join("native");
    let compile = Command::new("rustc")
        .args(["--edition=2021", "-Adead_code"])
        .arg(work.0.join("native.rs"))
        .arg("-o")
        .arg(&binary)
        .output()
        .unwrap();
    assert!(
        compile.status.success(),
        "{}",
        String::from_utf8_lossy(&compile.stderr)
    );
    let output = Command::new(binary).output().unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let expected: String = (0usize..4096)
        .map(|mask| {
            let values: Vec<_> = (0..4).filter(|i| (mask >> (3 * i)) & 7 == 3).collect();
            format!("{values:?}\n")
        })
        .collect();
    assert_eq!(String::from_utf8(output.stdout).unwrap(), expected);
}

#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn kernel_projection_origin_and_changed_field_rejection() {
    let work = Work::new(SOURCE);
    fs::write(
        work.0.join("Proofs.lean"),
        r#"import Generated
open Provium.State
 theorem selected (entries : ArrayStore α) (value : Cell α) :
    value ∈ Subject.Table_keys entries ↔ ∃ state, some state ∈ entries ∧
      evalCondition (.and (.field ["enabled"]) (.not (.field ["retired"]))) state = true ∧
      state ["key"] = value := projectArray_member Subject.Table_keys_ir entries value
 theorem bounded (entries : ArrayStore α) : (Subject.Table_keys entries).length ≤ entries.length :=
  projectArray_length Subject.Table_keys_ir entries
"#,
    )
    .unwrap();
    let project = work.0.join("project.json");
    fs::write(&project, r#"{"crate_root":"source.rs","namespace":"Subject","methods":["Table::keys"],"proofs":"Proofs.lean","obligations":[{"theorem":"selected","function":"Table_keys"},{"theorem":"bounded","function":"Table_keys"}]}"#).unwrap();
    let out = work.0.join("out");
    provium::methods::verify(&project, &out).unwrap();
    for source in [
        SOURCE.replace(".map(|r| r.key)", ".map(|r| r.alternate)"),
        SOURCE.replace("r.enabled && !r.retired", "r.enabled || !r.retired"),
    ] {
        fs::write(work.0.join("source.rs"), source).unwrap();
        fs::write(out.join("verified.json"), "stale").unwrap();
        let error = provium::methods::verify(&project, &out).unwrap_err();
        assert!(error.contains("Lean rejected Proofs.lean"), "{error}");
        assert!(!out.join("verified.json").exists());
    }
}

const KEY_SOURCE: &str = r#"
#[derive(Clone, Copy, PartialEq)] struct Key(u64);
struct Row { key: Key, alternate: Key, enabled: bool, retired: bool }
struct Table<const N: usize> { rows: [Option<Row>; N] }
impl<const N: usize> Table<N> {
    fn keys(&self, id: Key) -> bool {
        self.rows.iter().flatten().any(|r| r.key == id && (r.enabled || r.retired))
    }
}
"#;

#[test]
fn identity_query_checks_equality_types_predicates_and_shadowing() {
    let method = Work::new(KEY_SOURCE).lower().unwrap();
    let key = method.array.unwrap().key.unwrap();
    assert_eq!(key.path, ["key"]);
    assert_eq!(key.argument, "id");
    for source in [
        KEY_SOURCE.replace("Copy, PartialEq", "Copy"),
        KEY_SOURCE.replace("r.key == id", "r.key != id"),
        KEY_SOURCE.replace("r.key == id", "custom(r.key, id)"),
        KEY_SOURCE.replace("id: Key", "id: u64"),
        KEY_SOURCE.replace("struct Key(u64)", "struct Key(f64)"),
        KEY_SOURCE.replace("|r| r.key == id", "|id| id.key == id"),
        format!("{KEY_SOURCE}\ntrait Foreign {{ fn any(self); }}"),
    ] {
        assert!(Work::new(&source).lower().is_err(), "accepted {source}");
    }
}

#[test]
fn native_identity_queries_match_membership_with_repeated_keys_and_holes() {
    let work = Work::new(KEY_SOURCE);
    let native = format!(
        "{KEY_SOURCE}\n{}",
        r#"
fn main() {
 for mask in 0usize..4096 {
  let table: Table<4> = Table { rows: core::array::from_fn(|i| {
   let flags = (mask >> (3 * i)) & 7;
   (flags & 1 != 0).then_some(Row { key: Key((i % 2) as u64), alternate: Key(99), enabled: flags & 2 != 0, retired: flags & 4 != 0 })
  }) };
  for id in 0..3 {
   let expected = (0..4).any(|i| {
    let flags = (mask >> (3 * i)) & 7;
    i % 2 == id && flags & 1 != 0 && flags & 6 != 0
   });
   assert_eq!(table.keys(Key(id as u64)), expected);
  }
 }
}
"#
    );
    fs::write(work.0.join("native.rs"), native).unwrap();
    let binary = work.0.join("native");
    let result = Command::new("rustc")
        .args(["--edition=2021", "-Adead_code"])
        .arg(work.0.join("native.rs"))
        .arg("-o")
        .arg(&binary)
        .output()
        .unwrap();
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    assert!(Command::new(binary).status().unwrap().success());
}

#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn kernel_identity_query_rejects_changed_equality_and_flags() {
    let work = Work::new(KEY_SOURCE);
    fs::write(
        work.0.join("Proofs.lean"),
        r#"import Generated
open Provium.State
 theorem exact_query [DecidableEq α] (entries : ArrayStore α) (key : Cell α) :
    Subject.Table_keys entries key = true ↔
      key ∈ projectArray ⟨.or (.field ["enabled"]) (.field ["retired"]), ["key"]⟩ entries :=
  queryKey_member Subject.Table_keys_ir entries key
"#,
    )
    .unwrap();
    let project = work.0.join("project.json");
    fs::write(&project, r#"{"crate_root":"source.rs","namespace":"Subject","methods":["Table::keys"],"proofs":"Proofs.lean","obligations":[{"theorem":"exact_query","function":"Table_keys"}]}"#).unwrap();
    let out = work.0.join("out");
    provium::methods::verify(&project, &out).unwrap();
    for source in [
        KEY_SOURCE.replace("r.key == id", "r.alternate == id"),
        KEY_SOURCE.replace("r.enabled || r.retired", "r.enabled && r.retired"),
    ] {
        fs::write(work.0.join("source.rs"), source).unwrap();
        let error = provium::methods::verify(&project, &out).unwrap_err();
        assert!(error.contains("Lean rejected Proofs.lean"), "{error}");
        assert!(!out.join("verified.json").exists());
    }
}
