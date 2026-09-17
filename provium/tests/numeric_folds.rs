use provium::methods::Crate;
use std::{
    fs,
    path::PathBuf,
    sync::atomic::{AtomicUsize, Ordering},
};
static NEXT: AtomicUsize = AtomicUsize::new(0);
struct Work(PathBuf);
impl Work {
    fn new(source: &str) -> Self {
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("artifacts")
            .join(format!(
                "numeric-fold-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
        fs::create_dir_all(&path).unwrap();
        fs::write(path.join("source.rs"), source).unwrap();
        Self(path)
    }
    fn lower(&self) -> Result<provium::methods::Method, String> {
        Crate::load(&self.0.join("source.rs"))?.lower("Table::threshold")
    }
}
impl Drop for Work {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
const SOURCE: &str = r#"
#[derive(Clone,Copy)]struct Row{key:u64,active:bool,old:bool}
struct Table<const N:usize>{rows:[Option<Row>;N]}
impl<const N:usize> Table<N>{
 fn active(&self)->impl Iterator<Item=u64>+'_ {self.rows.iter().flatten().filter(|r|r.active).map(|r|r.key)}
 fn previous(&self)->impl Iterator<Item=u64>+'_ {self.rows.iter().flatten().filter(|r|r.old).map(|r|r.key)}
 fn joint(&self)->bool {self.rows.iter().flatten().any(|r|r.old)}
 fn threshold(&self,mut progress:impl FnMut(u64)->u64)->u64{
  let mut buffer=[0;N];
  let mut count=0;
  for key in self.active(){buffer[count]=progress(key);count+=1;}
  buffer[..count].sort_unstable();
  let first=buffer[count-(count/2+1)];
  if !self.joint(){return first;}
  count=0;
  for key in self.previous(){buffer[count]=progress(key);count+=1;}
  buffer[..count].sort_unstable();
  let second=buffer[count-(count/2+1)];
  first.min(second)
 }
}
"#;
#[test]
fn numeric_fold_checks_complete_loops_prefixes_and_rank_control_flow() {
    let lowered = Work::new(SOURCE).lower().unwrap();
    let fold = lowered.array.unwrap().numeric.unwrap();
    assert_eq!(fold.divisor, 2);
    assert_eq!(fold.callback, "progress");
    assert!(fold.first.rust.contains("active"));
    assert!(fold.second.rust.contains("old"));
    for (from, to) in [
        ("[0;N]", "[0;1]"),
        ("[0;N]", "[1;N]"),
        ("let mut count=0", "let mut count=1"),
        ("buffer[count]=progress(key)", "buffer[0]=progress(key)"),
        ("progress(key)", "progress(0)"),
        ("count+=1", "count+=2"),
        ("buffer[..count]", "buffer[..]"),
        ("buffer[..count]", "buffer[1..count]"),
        ("sort_unstable()", "sort()"),
        ("count/2+1", "count/2+2"),
        ("count/2+1", "count/0+1"),
        ("return first", "return 0"),
        ("count=0;\n  for", "count=1;\n  for"),
        ("first.min(second)", "first.max(second)"),
        ("first.min(second)", "first.min(first)"),
        ("let second=", "let first="),
        ("for key in self.active()", "for count in self.active()"),
        ("count+=1;}", "count+=1;panic!();}"),
        ("if !self.joint()", "if self.joint()"),
    ] {
        let changed = SOURCE.replace(from, to);
        assert_ne!(changed, SOURCE);
        assert!(Work::new(&changed).lower().is_err(), "accepted {changed}");
    }
    let changed = SOURCE.replace("count/2+1", "count/3+1");
    assert_eq!(
        Work::new(&changed)
            .lower()
            .unwrap()
            .array
            .unwrap()
            .numeric
            .unwrap()
            .divisor,
        3
    );
}
#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn kernel_numeric_source_preserves_both_rounds_and_rejects_projection_rank_mutations() {
    let w = Work::new(SOURCE);
    fs::write(w.0.join("Proofs.lean"),r#"import Generated
open Provium.State
 theorem execution (entries:ArrayStore α) (callback:σ) (abortOnPanic:Bool) :
   Subject.Table_threshold entries callback abortOnPanic =
   collectCallbacks (projectArray ⟨.field ["active"],["key"]⟩ entries) callback (fun values advanced =>
     match numericRank values 2 with
     | none => finishNumericPanic advanced abortOnPanic
     | some first => if queryArray (.field ["old"]) entries then
         collectCallbacks (projectArray ⟨.field ["old"],["key"]⟩ entries) advanced (fun values advanced =>
           match numericRank values 2 with
           | none => finishNumericPanic advanced abortOnPanic
           | some second => finishCallback advanced (.value (min first second)))
       else finishCallback advanced (.value first)) := runNumericFold_refines _ entries callback abortOnPanic
 def only : Store Nat := fun field => if field=["active"] then .boolean true else if field=["key"] then .other 7 else .boolean false
 theorem singleton : observeCallback 3 (fun (_:Cell Nat) (state:Nat)=>.value (9:UInt64) (state+1)) (fun _=>.returned)
    (Subject.Table_threshold [some only] 0 false) =
      some (.value 9,[.called (.other 7) 0 (.value 9 1),.dropped 1 .returned]) := by
   have ranked : numericRank [(9:UInt64)] 2 = some 9 := by
     apply numericRank_eq_of_counts _ _ _ (by decide) <;> decide
   rw [execution]
   change (observeCallback 2 (fun (_:Cell Nat) (state:Nat)=>.value (9:UInt64) (state+1)) (fun _=>.returned)
     (match numericRank [(9:UInt64)] 2 with
      | none => finishNumericPanic 1 false
      | some value => finishCallback 1 (.value value))).map
       (fun result => (result.1, .called (.other 7) 0 (.value 9 1) :: result.2)) = _
   rw [ranked]
   rfl
 theorem empty : observeCallback 2 (fun (_:Cell Nat) (state:Nat)=>.value (9:UInt64) (state+1)) (fun _=>.returned)
    (Subject.Table_threshold [] 0 false) = some (.unwind,[.dropped 0 .returned]) := rfl
 theorem empty_abort : observeCallback 1 (fun (_:Cell Nat) (state:Nat)=>.value (9:UInt64) (state+1)) (fun _=>.returned)
    (Subject.Table_threshold [] 0 true) = some (.abort,[]) := rfl
"#).unwrap();
    let project = w.0.join("project.json");
    let obligations: Vec<_> = ["execution", "singleton", "empty", "empty_abort"]
        .into_iter()
        .map(|theorem| serde_json::json!({"theorem":theorem,"function":"Table_threshold"}))
        .collect();
    fs::write(&project,serde_json::json!({"crate_root":"source.rs","namespace":"Subject","methods":["Table::threshold"],"proofs":"Proofs.lean","obligations":obligations}).to_string()).unwrap();
    let out = w.0.join("out");
    provium::methods::verify(&project, &out).unwrap();
    for (from, to) in [
        ("count/2+1", "count/3+1"),
        ("filter(|r|r.active)", "filter(|r|r.old)"),
        ("any(|r|r.old)", "any(|r|r.active)"),
    ] {
        fs::write(w.0.join("source.rs"), SOURCE.replace(from, to)).unwrap();
        let error = provium::methods::verify(&project, &out).unwrap_err();
        assert!(error.contains("Lean rejected Proofs.lean"), "{error}");
        assert!(!out.join("verified.json").exists());
    }
}

#[test]
#[ignore = "requires pinned Lean and installed wasm32 target; scripts/verify.sh runs this"]
fn numeric_words_use_the_checked_target_and_reject_a_wrong_width_contract() {
    let w = Work::new(&format!("#![no_std]\n{SOURCE}"));
    let project = w.0.join("project.json");
    let out = w.0.join("out");
    for (target, bits) in [(None, usize::BITS), (Some("wasm32-unknown-unknown"), 32)] {
        let proofs = format!(
            r#"import Generated
open Provium.State
theorem target_width : Subject.target_usize_bits = {bits} := by rfl
theorem target_execution (entries : ArrayStore α) (callback : σ) (checked abortOnPanic : Bool)
    (capacity : entries.length < 2^Subject.target_usize_bits) :
    Subject.Table_threshold_target_words entries callback checked abortOnPanic =
      Subject.Table_threshold entries callback abortOnPanic := by
  have fits : Subject.Table_threshold_ir.divisor < 2^Subject.target_usize_bits := by
    rw [target_width]
    decide
  exact Subject.Table_threshold_target_refinement entries callback checked abortOnPanic capacity fits
"#
        );
        fs::write(w.0.join("Proofs.lean"), &proofs).unwrap();
        fs::write(
            &project,
            serde_json::json!({
                "crate_root":"source.rs", "namespace":"Subject", "rust_target":target,
                "methods":["Table::threshold"], "proofs":"Proofs.lean",
                "obligations":[{"theorem":"target_execution","function":"Table_threshold"}]
            })
            .to_string(),
        )
        .unwrap();
        provium::methods::verify(&project, &out).unwrap();
        let manifest: serde_json::Value =
            serde_json::from_slice(&fs::read(out.join("manifest.json")).unwrap()).unwrap();
        assert_eq!(manifest["target_usize_bits"], bits);
        let report: serde_json::Value =
            serde_json::from_slice(&fs::read(out.join("verified.json")).unwrap()).unwrap();
        assert_eq!(report["target_word_refinements"], 1);
        fs::write(
            w.0.join("Proofs.lean"),
            proofs.replace(&format!("= {bits} :="), &format!("= {} :=", bits + 1)),
        )
        .unwrap();
        let error = provium::methods::verify(&project, &out).unwrap_err();
        assert!(error.contains("Lean rejected Proofs.lean"), "{error}");
        assert!(!out.join("verified.json").exists());
    }
}
