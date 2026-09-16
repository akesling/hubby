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
                "predicate-fold-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
        fs::create_dir_all(&path).unwrap();
        fs::write(path.join("source.rs"), source).unwrap();
        Self(path)
    }
    fn lower(&self) -> Result<provium::methods::Method, String> {
        Crate::load(&self.0.join("source.rs"))?.lower("Table::accepted")
    }
}
impl Drop for Work {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
const SOURCE: &str = r#"
#[derive(Clone, Copy)]
struct Row { key: u64, active: bool, old: bool }
struct Table<const N:usize> { rows: [Option<Row>;N] }
impl<const N:usize> Table<N> {
 fn locked(&self)->bool { self.rows.iter().flatten().any(|r|r.old) }
 fn accepted(&self, mut answer: impl FnMut(u64)->bool)->bool {
  let round = |prior:bool, test:&mut dyn FnMut(u64)->bool| {
   let selected = self.rows.iter().flatten().filter(|r|if prior {r.old} else {r.active});
   let total = selected.clone().count();
   let count = selected.filter(|r|test(r.key)).count();
   count > total / 2
  };
  round(false, &mut answer) && (!self.locked() || round(true, &mut answer))
 }
}
"#;
#[test]
fn predicate_fold_retains_source_structure_and_rejects_hidden_effects() {
    let lowered = Work::new(SOURCE).lower().unwrap();
    let fold = lowered.array.unwrap().fold.unwrap();
    assert_eq!(fold.divisor, 2);
    assert!(!fold.inclusive);
    assert_eq!(fold.key, ["key"]);
    assert_eq!(fold.callback, "answer");
    assert!(fold.guard.rust.contains("any"));
    for (from, to) in [
        ("selected.clone().count()", "selected.count()"),
        ("selected.clone().count()", "other.clone().count()"),
        ("|r|test(r.key)", "|r|{test(r.key);test(r.key)}"),
        ("|r|test(r.key)", "|test|test(test.key)"),
        ("test(r.key)", "answer(r.key)"),
        ("count > total / 2", "count > total / 0"),
        ("let count =", "let total ="),
        ("round(false, &mut answer)", "round(true, &mut answer)"),
        ("&& (!self.locked()", "|| (!self.locked()"),
        ("|| round(true", "&& round(true"),
        ("{r.old}", "{panic!();r.old}"),
        ("let round =", "let round = move"),
        ("&mut dyn FnMut", "&dyn FnMut"),
    ] {
        let changed = SOURCE.replace(from, to);
        assert_ne!(changed, SOURCE);
        assert!(Work::new(&changed).lower().is_err(), "accepted {changed}");
    }
}
#[test]
fn predicate_threshold_changes_are_retained_in_ir() {
    for (operator, inclusive) in [(">", false), (">=", true)] {
        let source = SOURCE.replace("count > total / 2", &format!("count {operator} total / 3"));
        let fold = Work::new(&source)
            .lower()
            .unwrap()
            .array
            .unwrap()
            .fold
            .unwrap();
        assert_eq!(fold.divisor, 3);
        assert_eq!(fold.inclusive, inclusive);
    }
}
#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn kernel_source_fold_preserves_trace_and_rejects_threshold_mutations() {
    let w = Work::new(SOURCE);
    fs::write(w.0.join("Proofs.lean"),r#"import Generated
open Provium.State
 def row (key:Nat) (active old:Bool):Store Nat := fun field=>
   if field=["key"] then .other key else if field=["active"] then .boolean active
   else if field=["old"] then .boolean old else .absent
 def entries:ArrayStore Nat := [some (row 1 true false),some (row 2 true true),some (row 3 false true)]
 theorem threshold:
   observePredicate 4 (fun _ (n:Nat)=>.value (n=0) (n+1)) (fun _=>.returned)
     (Subject.Table_accepted [some (row 1 true false),some (row 2 true false)] 0) =
   some (.value false,[.called (.other 1) 0 (.value true 1),.called (.other 2) 1 (.value false 2),.dropped 2 .returned]) := rfl
 theorem ordered:
   observePredicate 6 (fun _ (n:Nat)=>.value (n<2) (n+1)) (fun _=>.returned) (Subject.Table_accepted entries 0) =
   some (.value false,[.called (.other 1) 0 (.value true 1),.called (.other 2) 1 (.value true 2),
     .called (.other 2) 2 (.value false 3),.called (.other 3) 3 (.value false 4),.dropped 4 .returned]) := rfl
 theorem empty:
   observePredicate 2 (fun _ (n:Nat)=>.value true (n+1)) (fun _=>.returned) (Subject.Table_accepted ([]:ArrayStore Nat) 0) =
   some (.value false,[.dropped 0 .returned]) := rfl
"#).unwrap();
    let project = w.0.join("project.json");
    let obligations: Vec<_> = ["threshold", "ordered", "empty"]
        .into_iter()
        .map(|theorem| serde_json::json!({"theorem":theorem,"function":"Table_accepted"}))
        .collect();
    fs::write(&project,serde_json::json!({"crate_root":"source.rs","namespace":"Subject","methods":["Table::accepted"],"proofs":"Proofs.lean","obligations":obligations}).to_string()).unwrap();
    let out = w.0.join("out");
    provium::methods::verify(&project, &out).unwrap();
    for (from, to) in [
        ("count > total / 2", "count >= total / 2"),
        ("count > total / 2", "count > total / 3"),
        (
            "if prior {r.old} else {r.active}",
            "if prior {r.active} else {r.old}",
        ),
    ] {
        fs::write(w.0.join("source.rs"), SOURCE.replace(from, to)).unwrap();
        let error = provium::methods::verify(&project, &out).unwrap_err();
        assert!(error.contains("Lean rejected Proofs.lean"), "{error}");
        assert!(!out.join("verified.json").exists());
    }
}
