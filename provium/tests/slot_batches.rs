use provium::methods::Crate;
use std::{
    fs,
    path::PathBuf,
    process::Command,
    sync::atomic::{AtomicUsize, Ordering},
};
static NEXT: AtomicUsize = AtomicUsize::new(0);
const SOURCE: &str = include_str!("fixtures/slot_batch.rs");
struct Work(PathBuf);
impl Work {
    fn new(source: &str) -> Self {
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("artifacts")
            .join(format!(
                "slot-batch-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
        fs::create_dir_all(&path).unwrap();
        fs::write(path.join("source.rs"), source).unwrap();
        Self(path)
    }
    fn lower(&self) -> Result<provium::methods::Method, String> {
        Crate::load(&self.0.join("source.rs"))?.lower("Table::from_sets")
    }
}
impl Drop for Work {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
#[test]
fn batch_retains_complete_pass_order_checks_and_callee() {
    let method = Work::new(SOURCE).lower().unwrap();
    let batch = method.array.unwrap().batch.unwrap();
    assert_eq!(batch.inputs, ["active", "old", "learners"]);
    assert_eq!(batch.passes, [(0, 0), (2, 1), (1, 2)]);
    assert_eq!(batch.required, 0);
    assert_eq!(batch.exclusion_input, 0);
    assert_eq!(batch.exclusion_tag, 1);
    assert_eq!(batch.error, "Invalid");
    assert_eq!(batch.insert.error, "Full");
    assert!(batch.insert_rust.contains("get_or_insert"));
    for source in [
        SOURCE.replace("set[..i]", "set[..=i]"),
        SOURCE.replace("set[..i]", "active[..i]"),
        SOURCE.replace("set[..i].contains(key) ||", "set[..i].contains(key) &&"),
        SOURCE.replace("result.include(*key, tag)?;", "result.include(*key, 0)?;"),
        SOURCE.replace("result.include(*key, tag)?;", "result.include(*key, tag);"),
        SOURCE.replace("Ok(result)", "panic!(); Ok(result)"),
        SOURCE.replace("row.active = true", "side_effect()"),
        SOURCE.replace("rows: [None; N]", "rows: [None; 0]"),
        SOURCE.replace("let mut result", "let result"),
        SOURCE.replace("for (i, key)", "for (i, active)"),
        SOURCE.replace("row.key == key", "row.key != key"),
        format!("{SOURCE}\ntrait Foreign {{ fn enumerate(self); }}"),
    ] {
        assert!(Work::new(&source).lower().is_err(), "accepted {source}");
    }
}
#[test]
fn forwarding_retains_arguments_empty_slices_and_complete_constructor() {
    let work = Work::new(SOURCE);
    let krate = Crate::load(&work.0.join("source.rs")).unwrap();
    let stable = krate.lower("Table::stable").unwrap();
    let batch = stable.array.unwrap().batch.unwrap();
    assert_eq!(batch.arguments, [Some(0), None, Some(1)]);
    assert_eq!(
        batch.constructor_method.as_deref(),
        Some("Table::from_sets")
    );
    assert!(batch.constructor_rust.unwrap().contains("enumerate"));
    for source in [
        SOURCE.replace(
            "Self::from_sets(active, &[], learners)",
            "Self::from_sets(active, &[Key(0)], learners)",
        ),
        SOURCE.replace(
            "Self::from_sets(active, &[], learners)",
            "Self::stable(active, learners)",
        ),
        SOURCE.replace(
            "Self::from_sets(active, &[], learners)",
            "panic!(); Self::from_sets(active, &[], learners)",
        ),
    ] {
        let work = Work::new(&source);
        assert!(Crate::load(&work.0.join("source.rs"))
            .unwrap()
            .lower("Table::stable")
            .is_err());
    }
}
#[test]
fn native_constructor_matches_sets_order_capacity_and_early_errors() {
    let work = Work::new(SOURCE);
    let native = format!(
        "{SOURCE}\n{}",
        r#"
fn lists() -> Vec<Vec<Key>> {
 let mut lists=vec![vec![]];
 for len in 1..=3 { for mut code in 0..3usize.pow(len) {
  lists.push((0..len).map(|_|{let id=code%3;code/=3;Key(id as u64)}).collect());
 } }
 lists
}
fn cases<const N:usize>(lists:&[Vec<Key>]) {
 for active in lists { for old in lists { for learners in lists {
  let mut union=Vec::new();
  for key in active.iter().chain(learners).chain(old) { if !union.contains(key) { union.push(*key); } }
  let distinct=|xs:&[Key]|(0..3).all(|key|xs.iter().filter(|x|x.0==key).count()<=1);
  let valid=!active.is_empty() && distinct(active) && distinct(old) && distinct(learners)
    && learners.iter().all(|k|!active.contains(k)) && union.len()<=N;
  let result=Table::<N>::from_sets(active,old,learners);
  assert_eq!(result.is_ok(),valid);
  if old.is_empty() { assert_eq!(Table::<N>::stable(active,learners),result); }
  if let Ok(table)=result {
   let keys:Vec<_>=table.rows.iter().flatten().map(|r|r.key).collect();
   assert_eq!(keys,union);
   for row in table.rows.iter().flatten() {
    assert_eq!(row.active,active.contains(&row.key));
    assert_eq!(row.old,old.contains(&row.key));
    assert_eq!(row.learner,learners.contains(&row.key));
   }
  }
 } } }
}
fn main() {
 let lists=lists(); cases::<0>(&lists); cases::<1>(&lists); cases::<3>(&lists); cases::<5>(&lists);
 assert_eq!(Table::<0>::from_sets(&[Key(0),Key(0)],&[],&[]),Err(Error::Full));
 assert_eq!(Table::<1>::from_sets(&[Key(0),Key(0)],&[],&[]),Err(Error::Invalid));
 assert_eq!(Table::<1>::from_sets(&[Key(0)],&[Key(1),Key(1)],&[]),Err(Error::Full));
 assert_eq!(Table::<1>::from_sets(&[Key(0)],&[],&[Key(0)]),Err(Error::Invalid));
}
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
fn kernel_batch_rejects_changed_order_validation_and_insert_flags() {
    let work = Work::new(SOURCE);
    fs::write(work.0.join("Proofs.lean"),r#"import Generated
open Provium.State
 theorem capacity [DecidableEq α] (capacity : Nat) (a b c : List (Cell α)) (result : ArrayStore α)
    (success : Subject.Table_from_sets capacity a b c = .ok result) : result.length = capacity :=
  runSlotBatch_length Subject.Table_from_sets_ir capacity [a,b,c] result success
 theorem stable [DecidableEq α] (capacity : Nat) (active learners : List (Cell α)) :
    Subject.Table_stable capacity active learners = Subject.Table_from_sets capacity active [] learners := rfl
 def keys (entries : ArrayStore Nat) : List (Cell Nat) := projectArray ⟨.boolean true, ["key"]⟩ entries
 theorem ordered : (Subject.Table_from_sets 2 [.other 0] [] [.other 1]).map keys = .ok [.other 0, .other 1] := rfl
 theorem flag : ((Subject.Table_from_sets 1 [.other (0 : Nat)] [] []).map
    (fun entries => entries[0]?.bind (fun entry => entry.map (fun state => state ["active"])))) = .ok (some (.boolean true)) := rfl
 theorem duplicate : Subject.Table_from_sets 2 [.other (0 : Nat), .other 0] [] [] = .error "Invalid" := rfl
 theorem overlap : Subject.Table_from_sets 2 [.other (0 : Nat)] [] [.other 0] = .error "Invalid" := rfl
 theorem early_full : Subject.Table_from_sets 0 [.other (0 : Nat), .other 0] [] [] = .error "Full" := rfl
"#).unwrap();
    let project = work.0.join("project.json");
    let obligations: Vec<_> = [
        "capacity",
        "stable",
        "ordered",
        "flag",
        "duplicate",
        "overlap",
        "early_full",
    ]
    .into_iter()
    .map(|theorem| serde_json::json!({"theorem":theorem,"function":if theorem == "stable" {"Table_stable"} else {"Table_from_sets"}}))
    .collect();
    fs::write(&project,serde_json::json!({"crate_root":"source.rs","namespace":"Subject","methods":["Table::from_sets","Table::stable"],"proofs":"Proofs.lean","obligations":obligations}).to_string()).unwrap();
    let out = work.0.join("out");
    provium::methods::verify(&project, &out).unwrap();
    for source in [
        SOURCE.replace("[(active, 0), (learners, 1)", "[(learners, 1), (active, 0)"),
        SOURCE.replace("if active.is_empty()", "if old.is_empty()"),
        SOURCE.replace(
            "tag == 1 && active.contains(key)",
            "tag == 2 && active.contains(key)",
        ),
        SOURCE.replace("row.active = true", "row.active = false"),
        SOURCE.replace(
            "Self::from_sets(active, &[], learners)",
            "Self::from_sets(learners, &[], active)",
        ),
    ] {
        fs::write(work.0.join("source.rs"), source).unwrap();
        let error = provium::methods::verify(&project, &out).unwrap_err();
        assert!(error.contains("Lean rejected Proofs.lean"), "{error}");
        assert!(!out.join("verified.json").exists());
    }
}
