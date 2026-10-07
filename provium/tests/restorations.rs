use provium::methods::Crate;
use std::{
    fs,
    path::{Path, PathBuf},
    sync::atomic::{AtomicUsize, Ordering},
};
static NEXT: AtomicUsize = AtomicUsize::new(0);
struct Work(PathBuf);
impl Work {
    fn new(source: &str) -> Self {
        let p = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("artifacts")
            .join(format!(
                "restorations-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
        fs::create_dir_all(&p).unwrap();
        fs::write(p.join("lib.rs"), source).unwrap();
        Self(p)
    }
    fn lower(&self, name: &str) -> Result<provium::methods::Method, String> {
        Crate::load(&self.0.join("lib.rs"))?.lower(name)
    }
}
impl Drop for Work {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
const SOURCE: &str = r#"
#[derive(Clone,Copy,Default)] struct Position{index:u64,term:u64}
#[derive(Clone,Copy,Default)] struct Hard{term:u64,voted:Option<u64>,commit:u64}
struct Saved<S>{position:Position,value:S}
struct Entry<T>{id:Position,value:T}
#[derive(Clone,Copy)] enum Error{State,Full}
struct State<T,S,const N:usize>{hard:Hard,saved:Option<Saved<S>>,slots:[Option<Entry<T>>;N],len:usize}
impl<T,S,const N:usize> State<T,S,N>{
 fn new()->Self{Self{hard:Hard::default(),saved:None,slots:core::array::from_fn(|_|None),len:0}}
 fn base(&self)->Position{self.saved.as_ref().map_or(Position::default(),|s|s.position)}
 fn entries(&self)->impl DoubleEndedIterator<Item=&Entry<T>>{self.slots[..self.len].iter().flatten()}
 fn last(&self)->Position{self.entries().next_back().map_or(self.base(),|e|e.id)}
 fn full(&self)->bool{self.len==N}
 fn push(&mut self,entry:Entry<T>)->Result<(),Error>{if self.full(){return Err(Error::Full);}self.slots[self.len]=Some(entry);self.len+=1;Ok(())}
 fn restore(hard:Hard,snapshot:Option<Saved<S>>,entries:impl IntoIterator<Item=Entry<T>>)->Result<Self,Error>{
  let mut state=Self::new();state.hard=hard;state.saved=snapshot;let base=state.base();
  if (state.saved.is_some() && (base.index==0 || base.term==0)) || base.term>hard.term || (hard.term==0 && hard.voted.is_some()){return Err(Error::State);}
  for entry in entries{
   let last=state.last();
   if last.index.checked_add(1)!=Some(entry.id.index) || entry.id.term==0 || entry.id.term<last.term || entry.id.term>hard.term{return Err(Error::State);}
   state.push(entry)?;
  }
  if hard.commit<base.index || hard.commit>state.last().index{return Err(Error::State);}
  Ok(state)
 }
}
"#;
#[test]
fn original_recovery_retains_predicates_helpers_and_owned_cleanup() {
    let w = Work::new(SOURCE);
    let r = w.lower("State::restore").unwrap().restoration.unwrap();
    assert_eq!(r.constructor_method, "State::new");
    assert_eq!(r.last_method, "State::last");
    assert_eq!(r.append_method, "State::push");
    assert!(r.snapshot_first);
    assert_eq!(r.hard, ["hard"]);
    assert_eq!(r.snapshot, ["saved"]);
    let reversed = SOURCE.replace(
        "hard:Hard,saved:Option<Saved<S>>,slots:[Option<Entry<T>>;N],len:usize",
        "hard:Hard,slots:[Option<Entry<T>>;N],saved:Option<Saved<S>>,len:usize",
    );
    assert!(
        !Work::new(&reversed)
            .lower("State::restore")
            .unwrap()
            .restoration
            .unwrap()
            .snapshot_first
    );
    let shadow = format!(
        "const entry:Entry<u8>=Entry{{id:Position{{index:0,term:0}},value:0}};{}",
        SOURCE.replace("hard.commit>state.last().index", "entry.id.term==0")
    );
    assert!(Work::new(&shadow).lower("State::restore").is_err());

    for source in [
        SOURCE.replace("state.push(entry)?;", "state.push(entry)?;external();"),
        SOURCE.replace(
            "let last=state.last();",
            "let last=state.last();external();",
        ),
        SOURCE.replace("self.len+=1;", "self.len+=0;"),
        SOURCE.replace("entry.id.term<last.term", "entry.id.term<external()"),
        SOURCE.replace(
            "slots:[Option<Entry<T>>;N],len:usize",
            "slots:[Option<Entry<T>>;N],len:usize,extra:Option<T>",
        ),
        SOURCE
            .replace("let last=state.last();", "let base=state.last();")
            .replace("last.index.checked_add", "base.index.checked_add")
            .replace("entry.id.term<last.term", "entry.id.term<base.term"),
        // `?` would call a user From conversion between distinct error enums.
        format!(
            "enum PushError{{Full}} impl From<PushError> for Error{{fn from(_:PushError)->Error{{panic!(\"converted\")}}}}{}",
            SOURCE
                .replace("->Result<(),Error>{if self.full()", "->Result<(),PushError>{if self.full()")
                .replace("return Err(Error::Full);}self.slots", "return Err(PushError::Full);}self.slots")
        ),
    ] {
        assert!(
            Work::new(&source).lower("State::restore").is_err(),
            "accepted {source}"
        );
    }
}
#[derive(Clone)]
struct Case {
    capacity: usize,
    hard: (u64, bool, u64),
    snapshot: Option<(u64, u64, u64)>,
    entries: Vec<(u64, u64, u64)>,
}
fn datum(d: (u64, u64, u64)) -> String {
    format!("⟨{},{},{}⟩", d.0, d.1, d.2)
}
fn cases() -> Vec<Case> {
    let mut cases = Vec::new();
    for capacity in [0, 1, 3] {
        for (hard, snapshot, entries) in [
            ((0, false, 0), None, vec![]),
            ((1, false, 0), None, vec![(1, 1, 1)]),
            ((1, false, 1), None, vec![(1, 1, 1)]),
            (
                (1, false, 1),
                Some((1, 1, 50)),
                vec![(2, 1, 1), (3, 1, 2), (4, 1, 3)],
            ),
            (
                (1, false, 1),
                Some((1, 1, 50)),
                vec![(2, 1, 1), (9, 1, 2), (4, 1, 3)],
            ),
            (
                (1, false, 99),
                Some((1, 1, 50)),
                vec![(2, 1, 1), (3, 1, 2), (4, 1, 3)],
            ),
            ((1, false, 0), Some((0, 1, 50)), vec![(1, 1, 1), (2, 1, 2)]),
            ((1, false, 1), Some((1, 0, 50)), vec![]),
            ((0, true, 0), None, vec![(1, 1, 1)]),
            ((1, false, 1), Some((1, 2, 50)), vec![]),
            ((2, false, 0), None, vec![(1, 2, 1), (2, 1, 2)]),
            ((1, false, 0), None, vec![(1, 0, 1)]),
            ((1, false, 0), None, vec![(1, 2, 1)]),
            ((1, false, 1), Some((2, 1, 50)), vec![]),
            (
                (1, false, u64::MAX),
                Some((u64::MAX, 1, 50)),
                vec![(0, 1, 1)],
            ),
            ((1, false, u64::MAX), Some((u64::MAX, 1, 50)), vec![]),
        ] {
            cases.push(Case {
                capacity,
                hard,
                snapshot,
                entries,
            });
        }
    }
    cases
}
#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn kernel_computes_the_native_recovery_results_and_cleanup_traces() {
    let w = Work::new(SOURCE);
    let cases = cases();
    let mut native = format!(
        r#"{SOURCE}
use std::{{collections::VecDeque,sync::Mutex}};
static TRACE:Mutex<Vec<String>>=Mutex::new(Vec::new());
struct Value(String);impl Drop for Value{{fn drop(&mut self){{TRACE.lock().unwrap().push(self.0.clone());}}}}
struct Source(Option<VecDeque<Entry<Value>>>);impl Drop for Source{{fn drop(&mut self){{TRACE.lock().unwrap().push("source-drop".into());}}}}
struct Iter(VecDeque<Entry<Value>>);impl Drop for Iter{{fn drop(&mut self){{TRACE.lock().unwrap().push("iterator-drop".into());}}}}
impl Iterator for Iter{{type Item=Entry<Value>;fn next(&mut self)->Option<Self::Item>{{TRACE.lock().unwrap().push("next".into());self.0.pop_front()}}}}
impl IntoIterator for Source{{type Item=Entry<Value>;type IntoIter=Iter;fn into_iter(mut self)->Iter{{TRACE.lock().unwrap().push("into-iterator".into());Iter(self.0.take().unwrap())}}}}
fn run<const N:usize>(hard:Hard,snapshot:Option<(u64,u64,u64)>,entries:&[(u64,u64,u64)]){{
 TRACE.lock().unwrap().clear();
 let snapshot=snapshot.map(|(index,term,id)|Saved{{position:Position{{index,term}},value:Value(format!("s{{id}}"))}});
 let source=Source(Some(entries.iter().map(|&(index,term,id)|Entry{{id:Position{{index,term}},value:Value(format!("e{{id}}"))}}).collect()));
 let result=State::<Value,Value,N>::restore(hard,snapshot,source);
 match &result{{
  Err(error)=>println!("{{}}|0||0|false|0|none|{{}}",match error{{Error::State=>"Error::State",Error::Full=>"Error::Full"}},TRACE.lock().unwrap().join(",")),
  Ok(state)=>println!("ok|{{}}|{{}}|{{}}|{{}}|{{}}|{{}}|{{}}",state.len,state.slots.iter().map(|e|e.as_ref().map(|e|e.value.0[1..].to_owned()).unwrap_or("none".into())).collect::<Vec<_>>().join(","),state.hard.term,state.hard.voted.is_some(),state.hard.commit,state.saved.as_ref().map(|s|format!("{{}},{{}},{{}}",s.position.index,s.position.term,&s.value.0[1..])).unwrap_or("none".into()),TRACE.lock().unwrap().join(","))
 }}
 drop(result);
}}
fn main(){{
"#
    );
    for c in &cases {
        native.push_str(&format!(
            "run::<{}>(Hard{{term:{},voted:{},commit:{}}},{:?},&{:?});\n",
            c.capacity,
            c.hard.0,
            if c.hard.1 { "Some(7)" } else { "None" },
            c.hard.2,
            c.snapshot,
            c.entries
        ));
    }
    native.push_str("}\n");
    fs::write(w.0.join("main.rs"), native).unwrap();
    let binary = w.0.join("native");
    let built = std::process::Command::new("rustc")
        .args(["--edition=2021", "-C", "overflow-checks=yes"])
        .arg(w.0.join("main.rs"))
        .arg("-o")
        .arg(&binary)
        .output()
        .unwrap();
    assert!(
        built.status.success(),
        "{}",
        String::from_utf8_lossy(&built.stderr)
    );
    let actual = std::process::Command::new(binary).output().unwrap();
    assert!(
        actual.status.success(),
        "{}",
        String::from_utf8_lossy(&actual.stderr)
    );
    let actual = String::from_utf8(actual.stdout).unwrap();
    let lines = actual.lines().collect::<Vec<_>>();
    assert_eq!(lines.len(), cases.len());
    let mut proof = include_str!("fixtures/recovery_trace.lean").to_owned();
    proof.push_str("\nopen RecoveryTrace\n");
    let mut obligations = Vec::new();
    for (i, (c, line)) in cases.iter().zip(lines).enumerate() {
        let parts = line.split('|').collect::<Vec<_>>();
        assert_eq!(parts.len(), 8);
        let slots = if parts[2].is_empty() {
            String::new()
        } else {
            parts[2]
                .split(',')
                .map(|s| {
                    if s == "none" {
                        "none".into()
                    } else {
                        format!("some {s}")
                    }
                })
                .collect::<Vec<_>>()
                .join(",")
        };
        let snapshot = if parts[6] == "none" {
            "none".into()
        } else {
            format!("some ⟨{}⟩", parts[6])
        };
        let events = parts[7]
            .split(',')
            .filter(|s| !s.is_empty())
            .map(|s| format!("{s:?}"))
            .collect::<Vec<_>>()
            .join(",");
        let expected = format!(
            "⟨{:?},{},[{slots}],⟨{},{},{}⟩,{snapshot},[{events}]⟩",
            parts[0], parts[1], parts[3], parts[4], parts[5]
        );
        let saved = c
            .snapshot
            .map(|s| format!("some {}", datum(s)))
            .unwrap_or("none".into());
        let entries = c
            .entries
            .iter()
            .copied()
            .map(datum)
            .collect::<Vec<_>>()
            .join(",");
        proof.push_str(&format!("theorem native_{i} : drive 128 (Subject.State_restore 64 (fun _ => {}) dataView dataView hardView hardPresence ⟨{},{},{}⟩ ({saved}) [{entries}]) = {expected} := by rfl\n",c.capacity,c.hard.0,c.hard.1,c.hard.2));
        obligations
            .push(serde_json::json!({"theorem":format!("native_{i}"),"function":"State_restore"}));
    }
    fs::write(w.0.join("Proofs.lean"), proof).unwrap();
    let config = w.0.join("project.json");
    fs::write(&config,serde_json::json!({"crate_root":"lib.rs","namespace":"Subject","methods":["State::restore"],"proofs":"Proofs.lean","obligations":obligations}).to_string()).unwrap();
    let out = w.0.join("out");
    provium::methods::verify(&config, &out).unwrap();
    for source in [
        SOURCE.replace("checked_add(1)", "checked_add(2)"),
        SOURCE.replace("entry.id.term==0", "false"),
        SOURCE.replace("hard.commit>state.last().index", "false"),
        SOURCE.replace("base.term>hard.term", "false"),
        SOURCE.replace(
            "hard:Hard,saved:Option<Saved<S>>,slots:[Option<Entry<T>>;N],len:usize",
            "hard:Hard,slots:[Option<Entry<T>>;N],saved:Option<Saved<S>>,len:usize",
        ),
    ] {
        fs::write(w.0.join("lib.rs"), source).unwrap();
        let error = provium::methods::verify(&config, &out).unwrap_err();
        assert!(error.contains("Lean rejected Proofs.lean"), "{error}");
        assert!(!out.join("verified.json").exists());
    }
}
