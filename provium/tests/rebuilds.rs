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
                "rebuild-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
        fs::create_dir_all(&path).unwrap();
        fs::write(path.join("source.rs"), source).unwrap();
        Self(path)
    }
    fn lower(&self) -> Result<provium::methods::Method, String> {
        Crate::load(&self.0.join("source.rs"))?.lower("Table::rebuild")
    }
}
impl Drop for Work {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
const METHODS: &str = r#"
impl<const N: usize> Table<N> {
    fn active(&self) -> impl Iterator<Item = Key> + '_ {
        self.rows.iter().flatten().filter(|r| r.active).map(|r| r.key)
    }
    fn excluded(&self, key: Key) -> bool {
        self.rows.iter().flatten().any(|r| r.key == key && (r.active || r.old))
    }
    fn rebuild(&self, additions: &[Key]) -> Result<Self, Error> {
        let mut next = Self { rows: [None; N] };
        for key in self.active() {
            next.include(key, 0)?;
        }
        for (i, key) in additions.iter().enumerate() {
            if self.excluded(*key) || additions[..i].contains(key) {
                return Err(Error::Invalid);
            }
            next.include(*key, 1)?;
        }
        Ok(next)
    }
}
"#;
fn source() -> String {
    format!("{}\n{METHODS}", include_str!("fixtures/slot_batch.rs"))
}
#[test]
fn rebuild_retains_all_helpers_and_rejects_hidden_loop_effects() {
    let source = source();
    let method = Work::new(&source).lower().unwrap();
    let rebuild = method.array.unwrap().rebuild.unwrap();
    assert_eq!((rebuild.first_tag, rebuild.input_tag), (0, 1));
    assert!(rebuild.projection.rust.contains("filter"));
    assert!(rebuild.exclusion.rust.contains("any"));
    assert!(rebuild.insert.rust.contains("get_or_insert"));
    for changed in [
        source.replace("additions[..i]", "additions[..=i]"),
        source.replace("self.excluded(*key) ||", "self.excluded(*key) &&"),
        source.replace("self.active()", "next.active()"),
        source.replace("self.excluded(*key)", "next.excluded(*key)"),
        source.replace("next.include(key, 0)?;", "next.include(key, 0)?; panic!();"),
        source.replace("next.include(*key, 1)?;", "next.include(*key, 1);"),
        source.replace(
            "next.include(*key, 1)?;",
            "next.include(*key, 1)?; panic!();",
        ),
        source.replace("let mut next", "let next"),
        source.replace("Ok(next)", "panic!(); Ok(next)"),
        source.replace("filter(|r| r.active)", "filter(|r| external(r))"),
        source.replace("for (i, key)", "for (additions, key)"),
        source.replace("for key in self.active()", "for next in self.active()"),
    ] {
        assert_ne!(changed, source);
        assert!(Work::new(&changed).lower().is_err(), "accepted {changed}");
    }
}
#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn kernel_rebuild_checks_original_query_and_insertion_tags() {
    let source = source();
    let w = Work::new(&source);
    fs::write(w.0.join("Proofs.lean"),r#"import Generated
open Provium.State
 theorem capacity [DecidableEq α] (capacity : Nat) (entries : ArrayStore α) (keys : List (Cell α))
    (result : ArrayStore α) (success : Subject.Table_rebuild capacity entries keys = .ok result) : result.length = capacity := by
  apply runRebuild_preserves Subject.Table_rebuild_ir (fun entries => entries.length = capacity) _ capacity entries keys result (by simp) success
  intro entries key tag initial _
  simpa only [runUpsert_length] using initial
 def old : Store Nat := fun field => if field = ["key"] then .other 1 else if field = ["old"] then .boolean true else .boolean false
 theorem excluded : Subject.Table_rebuild 1 [some old] [.other 1] = .error "Invalid" := rfl
 def active : Store Nat := fun field => if field = ["key"] then .other 2 else if field = ["active"] then .boolean true else .boolean false
 theorem retained : (Subject.Table_rebuild 1 [some active] []).map (projectArray ⟨.field ["active"], ["key"]⟩) = .ok [.other 2] := rfl
 theorem duplicate : Subject.Table_rebuild 2 ([] : ArrayStore Nat) [.other 1, .other 1] = .error "Invalid" := rfl
 theorem first_duplicates : (Subject.Table_rebuild 1 [some active, some active] []).map (projectArray ⟨.field ["active"], ["key"]⟩) = .ok [.other 2] := rfl
"#).unwrap();
    let project = w.0.join("project.json");
    let obligations: Vec<_> = [
        "capacity",
        "excluded",
        "retained",
        "duplicate",
        "first_duplicates",
    ]
    .into_iter()
    .map(|theorem| serde_json::json!({"theorem":theorem,"function":"Table_rebuild"}))
    .collect();
    fs::write(&project,serde_json::json!({"crate_root":"source.rs","namespace":"Subject","methods":["Table::rebuild"],"proofs":"Proofs.lean","obligations":obligations}).to_string()).unwrap();
    let out = w.0.join("out");
    provium::methods::verify(&project, &out).unwrap();
    for changed in [
        source.replace("next.include(key, 0)?;", "next.include(key, 2)?;"),
        source.replace("r.active || r.old", "r.active"),
        source.replace("filter(|r| r.active)", "filter(|r| r.old)"),
    ] {
        fs::write(w.0.join("source.rs"), changed).unwrap();
        let error = provium::methods::verify(&project, &out).unwrap_err();
        assert!(error.contains("Lean rejected Proofs.lean"), "{error}");
        assert!(!out.join("verified.json").exists());
    }
}
#[test]
fn native_rebuild_preserves_source_and_matches_ordered_union() {
    let w = Work::new(&source());
    let native = format!(
        "{}\n{}",
        source(),
        r#"
fn check<const N: usize>() {
 for code in 0..9usize.pow(N as u32) {
  let mut digits=code;
  let original=Table::<N> { rows:core::array::from_fn(|i| { let d=digits%9;digits/=9;
   (d!=0).then_some(Row {key:Key((i%2) as u64),active:d&1!=0,old:d&2!=0,learner:d&4!=0}) }) };
  for keys in [vec![],vec![Key(0)],vec![Key(1)],vec![Key(2)],vec![Key(2),Key(2)],vec![Key(2),Key(3)]] {
   let mut expected:Vec<Row>=vec![]; let mut error=None;
   for key in original.active() {
    if let Some(row)=expected.iter_mut().find(|r|r.key==key) { row.active=true; }
    else if expected.len()==N {error=Some(Error::Full);break;}
    else {expected.push(Row{key,active:true,old:false,learner:false});}
   }
   if error.is_none() { for (i,key) in keys.iter().enumerate() {
    if original.excluded(*key) || keys[..i].contains(key) {error=Some(Error::Invalid);break;}
    if expected.len()==N {error=Some(Error::Full);break;}
    expected.push(Row{key:*key,active:false,old:false,learner:true});
   }}
   let before=original;
   match (original.rebuild(&keys),error) {
    (Err(actual),Some(expected))=>assert_eq!(actual,expected),
    (Ok(actual),None)=>assert_eq!(actual.rows.into_iter().flatten().collect::<Vec<_>>(),expected),
    pair=>panic!("mismatch {pair:?}"),
   }
   assert_eq!(original,before);
  }
 }
}
fn main(){check::<0>();check::<1>();check::<3>();}
"#
    );
    fs::write(w.0.join("native.rs"), native).unwrap();
    let binary = w.0.join("native");
    let built = Command::new("rustc")
        .args(["--edition=2021", "-Adead_code"])
        .arg(w.0.join("native.rs"))
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
