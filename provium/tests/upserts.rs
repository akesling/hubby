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
                "upsert-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
        fs::create_dir_all(&path).unwrap();
        fs::write(path.join("source.rs"), source).unwrap();
        Self(path)
    }
    fn lower(&self) -> Result<provium::methods::Method, String> {
        Crate::load(&self.0.join("source.rs"))?.lower("Table::include")
    }
}
impl Drop for Work {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
const SOURCE: &str = r#"
#[derive(Clone, Copy, PartialEq, Debug)] struct Key(u64);
#[derive(Clone, Copy, PartialEq, Debug)] struct Row { key: Key, active: bool, learner: bool, old: bool }
#[derive(Clone, Copy, PartialEq, Debug)] struct Table<const N: usize> { rows: [Option<Row>; N] }
#[derive(Debug, PartialEq)] enum Error { Full, Other }
impl<const N: usize> Table<N> {
 fn include(&mut self, key: Key, tag: u8) -> Result<(), Error> {
  let slot = self.rows.iter().position(|r| r.is_some_and(|r| r.key == key))
      .or_else(|| self.rows.iter().position(Option::is_none)).ok_or(Error::Full)?;
  let row = self.rows[slot].get_or_insert(Row { key, active: false, learner: false, old: false });
  match tag { 0 => row.active = true, 1 => row.learner = true, _ => row.old = true }
  Ok(())
 }
}
"#;
#[test]
fn complete_upsert_checks_search_index_initializer_and_dispatch() {
    let method = Work::new(SOURCE).lower().unwrap();
    let array = method.array.unwrap();
    let ir = array.upsert.unwrap();
    assert_eq!(array.field, "rows");
    assert_eq!(ir.key, ["key"]);
    assert_eq!(ir.initial.len(), 3);
    assert_eq!(ir.cases.len(), 2);
    assert_eq!(ir.fallback.path, ["old"]);
    assert_eq!(ir.error, "Full");
    for source in [
        SOURCE.replace("r.key == key", "r.key != key"),
        SOURCE.replace("rows[slot]", "rows[0]"),
        SOURCE.replace("Option::is_none", "Option::is_some"),
        SOURCE.replace("row.active = true", "side_effect()"),
        SOURCE.replace("Row { key,", "Row { key: Key(9),"),
        SOURCE.replace("_ => row.old", "2 => row.old"),
        SOURCE.replace("match tag", "match 0"),
        SOURCE.replace("Ok(())", "panic!(); Ok(())"),
        SOURCE.replace(
            "Clone, Copy, PartialEq, Debug)] struct Key",
            "Clone, Copy, Debug)] struct Key",
        ),
        SOURCE.replace(
            "Clone, Copy, PartialEq, Debug)] struct Row",
            "Clone, PartialEq, Debug)] struct Row",
        ),
        SOURCE.replace("row.active = true", "self.active = true"),
        format!("{SOURCE}\ntrait Foreign {{ fn position(self); }}"),
        format!("{SOURCE}\nimpl Drop for Error {{ fn drop(&mut self) {{}} }}"),
    ] {
        assert!(Work::new(&source).lower().is_err(), "accepted {source}");
    }
}
#[test]
fn native_upsert_preserves_other_slots_for_all_tags_and_full_arrays() {
    let work = Work::new(SOURCE);
    let native = format!(
        "{SOURCE}\n{}",
        r#"
fn cases<const N: usize>() {
 for code in 0..9usize.pow(N as u32) {
  let mut rest = code;
  let before = Table::<N> { rows: core::array::from_fn(|i| {
    let digit = rest % 9; rest /= 9;
    if digit == 0 { None } else { let flags = digit - 1;
      Some(Row { key: Key((i % 2) as u64), active: flags & 1 != 0, learner: flags & 2 != 0, old: flags & 4 != 0 }) }
  }) };
  for key in 0..3 { for tag in 0..=255u8 {
   let mut result = before;
   let status = result.include(Key(key), tag);
   let mut existing = None; let mut empty = None;
   for i in (0..N).rev() { match before.rows[i] {
    Some(r) if r.key.0 == key => existing = Some(i), None => empty = Some(i), _ => ()
   } }
   let chosen = if existing.is_some() { existing } else { empty };
   match chosen {
    None => { assert_eq!(status, Err(Error::Full)); assert_eq!(result, before); }
    Some(index) => {
     assert_eq!(status, Ok(()));
     for i in 0..N {
      if i != index { assert_eq!(result.rows[i], before.rows[i]); continue; }
      let old = before.rows[i].unwrap_or(Row { key: Key(key), active: false, learner: false, old: false });
      let new = result.rows[i].unwrap();
      assert_eq!(new.key, Key(key));
      assert_eq!(new.active, old.active || tag == 0);
      assert_eq!(new.learner, old.learner || tag == 1);
      assert_eq!(new.old, old.old || tag > 1);
     }
    }
   }
  } }
 }
}
fn main() { cases::<0>(); cases::<1>(); cases::<2>(); cases::<3>(); }
"#
    );
    fs::write(work.0.join("native.rs"), native).unwrap();
    let binary = work.0.join("native");
    let built = Command::new("rustc")
        .args(["--edition=2021", "-Adead_code"])
        .arg(work.0.join("native.rs"))
        .arg("-o")
        .arg(&binary)
        .output()
        .unwrap();
    assert!(
        built.status.success(),
        "{}",
        String::from_utf8_lossy(&built.stderr)
    );
    assert!(Command::new(binary).status().unwrap().success());
}
#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn kernel_upsert_rejects_changed_flags_initializers_and_error() {
    let work = Work::new(SOURCE);
    fs::write(work.0.join("Proofs.lean"),r#"import Generated
open Provium.State
 theorem capacity [DecidableEq α] (entries : ArrayStore α) (key : Cell α) (tag : Nat) :
    (Subject.Table_include entries key tag).1.length = entries.length :=
  runUpsert_length Subject.Table_include_ir entries key tag
 theorem active [DecidableEq α] (key : Cell α) :
    ((Subject.Table_include [none] key 0).1[0]?.bind (fun entry => entry.map (fun state => state ["active"]))) = some (.boolean true) := by
  simp [Subject.Table_include, runUpsert, upsertIndex, firstSlot, keySlot,
    upsertRecord, upsertWrite, Subject.Table_include_ir, run, value, put]
 theorem initial [DecidableEq α] (key : Cell α) :
    ((Subject.Table_include [none] key 0).1[0]?.bind (fun entry => entry.map (fun state => state ["old"]))) = some (.boolean false) := by
  simp [Subject.Table_include, runUpsert, upsertIndex, firstSlot, keySlot,
    upsertRecord, upsertWrite, Subject.Table_include_ir, run, value, put]
 theorem full [DecidableEq α] (key : Cell α) : Subject.Table_include [] key 0 = ([], some "Full") := rfl
"#).unwrap();
    let project = work.0.join("project.json");
    let obligations: Vec<_> = ["capacity", "active", "initial", "full"]
        .into_iter()
        .map(|t| serde_json::json!({"theorem":t,"function":"Table_include"}))
        .collect();
    fs::write(&project,serde_json::json!({"crate_root":"source.rs","namespace":"Subject","methods":["Table::include"],"proofs":"Proofs.lean","obligations":obligations}).to_string()).unwrap();
    let out = work.0.join("out");
    provium::methods::verify(&project, &out).unwrap();
    for source in [
        SOURCE.replace("row.active = true", "row.active = false"),
        SOURCE.replace("old: false", "old: true"),
        SOURCE.replace("Error::Full", "Error::Other"),
    ] {
        fs::write(work.0.join("source.rs"), source).unwrap();
        let error = provium::methods::verify(&project, &out).unwrap_err();
        assert!(error.contains("Lean rejected Proofs.lean"), "{error}");
        assert!(!out.join("verified.json").exists());
    }
}
