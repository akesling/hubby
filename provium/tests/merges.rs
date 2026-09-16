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
                "merge-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
        fs::create_dir_all(&path).unwrap();
        fs::write(path.join("source.rs"), source).unwrap();
        Self(path)
    }
    fn lower(&self) -> Result<provium::methods::Method, String> {
        Crate::load(&self.0.join("source.rs"))?.lower("Table::merge")
    }
}
impl Drop for Work {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
const METHODS: &str = r#"
impl<const N:usize> Table<N> {
 fn active(&self)->impl Iterator<Item=Key>+'_ {self.rows.iter().flatten().filter(|r|r.active).map(|r|r.key)}
 fn locked(&self)->bool {self.rows.iter().flatten().any(|r|r.old)}
 fn merge(self,mut target:Self)->Result<Self,Error> {
  if self.locked() || target.locked() {return Err(Error::Invalid);}
  for key in self.active() {target.include(key,2).map_err(|_|Error::Full)?;}
  Ok(target)
 }
}
"#;
fn source() -> String {
    format!("{}\n{METHODS}", include_str!("fixtures/slot_batch.rs"))
}
#[test]
fn merge_retains_guards_projection_insertion_and_error_mapping() {
    let source = source();
    let lowered = Work::new(&source).lower().unwrap();
    let merge = lowered.array.unwrap().merge.unwrap();
    assert_eq!(merge.tag, 2);
    assert_eq!(merge.guard_error, "Invalid");
    assert_eq!(merge.insert_error, "Full");
    assert!(merge.projection.rust.contains("filter"));
    assert!(merge.source_guard.rust.contains("any"));
    assert!(merge.insert.rust.contains("get_or_insert"));
    for changed in [
        source.replace("self.locked() ||", "self.locked() &&"),
        source.replace("target.locked()", "self.locked()"),
        source.replace("for key in self.active()", "for key in target.active()"),
        source.replace("target.include(key,2)", "self.include(key,2)"),
        source.replace("|_|Error::Full", "|_|{panic!();Error::Full}"),
        source.replace("|_|Error::Full", "move |_|Error::Full"),
        source.replace(".map_err(|_|Error::Full)", ""),
        source.replace("?;}", "?;panic!();}"),
        source.replace("mut target:Self", "target:Self"),
        source.replace("Ok(target)", "Ok(self)"),
        source.replace("for key in self.active()", "for target in self.active()"),
        format!("{source}\nimpl Drop for Error{{fn drop(&mut self){{}}}}"),
    ] {
        assert_ne!(changed, source);
        assert!(Work::new(&changed).lower().is_err(), "accepted {changed}");
    }
}
#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn kernel_merge_preserves_target_and_rejects_changed_guards_and_tags() {
    let source = source();
    let w = Work::new(&source);
    fs::write(w.0.join("Proofs.lean"),r#"import Generated
open Provium.State
 theorem capacity [DecidableEq α] (source target result:ArrayStore α) (success:Subject.Table_merge source target = .ok result):result.length=target.length := by
  have pass := (runArrayMerge_success Subject.Table_merge_ir source target result).mp success
  apply runInsertPass_preserves Subject.Table_merge_ir.insert Subject.Table_merge_ir.tag (fun entries=>entries.length=target.length) _ _ target result rfl pass.2.2
  intro entries key initial _
  simpa only [runUpsert_length] using initial
 def active : Store Nat := fun field=> if field=["key"] then .other 1 else if field=["active"] then .boolean true else .boolean false
 def old : Store Nat := fun field=> if field=["old"] then .boolean true else .boolean false
 theorem first_guard: Subject.Table_merge [some old] [none] = .error "Invalid" := rfl
 theorem second_guard: Subject.Table_merge [none] [some old] = .error "Invalid" := rfl
 theorem inserted: (Subject.Table_merge [some active] [none]).map (projectArray ⟨.field ["old"],["key"]⟩) = .ok [.other 1] := rfl
 theorem full: Subject.Table_merge [some active] [] = .error "Full" := rfl
"#).unwrap();
    let project = w.0.join("project.json");
    let obligations: Vec<_> = [
        "capacity",
        "first_guard",
        "second_guard",
        "inserted",
        "full",
    ]
    .into_iter()
    .map(|theorem| serde_json::json!({"theorem":theorem,"function":"Table_merge"}))
    .collect();
    fs::write(&project,serde_json::json!({"crate_root":"source.rs","namespace":"Subject","methods":["Table::merge"],"proofs":"Proofs.lean","obligations":obligations}).to_string()).unwrap();
    let out = w.0.join("out");
    provium::methods::verify(&project, &out).unwrap();
    for changed in [
        source.replace("any(|r|r.old)", "any(|r|r.active)"),
        source.replace("include(key,2)", "include(key,0)"),
        source.replace("map_err(|_|Error::Full)", "map_err(|_|Error::Invalid)"),
    ] {
        fs::write(w.0.join("source.rs"), changed).unwrap();
        let error = provium::methods::verify(&project, &out).unwrap_err();
        assert!(error.contains("Lean rejected Proofs.lean"), "{error}");
        assert!(!out.join("verified.json").exists());
    }
}
#[test]
fn native_merge_matches_union_and_error_priority() {
    let w = Work::new(&source());
    let native = format!(
        "{}\n{}",
        source(),
        r#"
fn check<const N:usize>() {
 for a in 0..9usize.pow(N as u32) {for b in 0..9usize.pow(N as u32) {
  let build=|mut code:usize,offset:u64|Table::<N>{rows:core::array::from_fn(|i|{let d=code%9;code/=9;(d!=0).then_some(Row{key:Key(i as u64+offset),active:d&1!=0,old:d&2!=0,learner:d&4!=0})})};
  let source=build(a,0);let target=build(b,1);let mut expected=target;let mut error=None;
  if source.rows.iter().flatten().any(|r|r.old)||target.rows.iter().flatten().any(|r|r.old){error=Some(Error::Invalid);}
  else {for key in source.rows.iter().flatten().filter(|r|r.active).map(|r|r.key){
   let slot=expected.rows.iter().position(|r|r.is_some_and(|r|r.key==key)).or_else(||expected.rows.iter().position(|r|r.is_none()));
   if let Some(i)=slot{expected.rows[i]=Some(Row{old:true,..expected.rows[i].unwrap_or(Row{key,active:false,old:false,learner:false})});}else{error=Some(Error::Full);break;}
  }}
  match(source.merge(target),error){(Ok(actual),None)=>assert_eq!(actual,expected),(Err(actual),Some(expected))=>assert_eq!(actual,expected),pair=>panic!("mismatch {pair:?}")}
 }}
}
fn main(){check::<0>();check::<1>();check::<2>();}
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
