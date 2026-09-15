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
                "truncations-{}-{}",
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
#[derive(Clone,Copy,Default)] struct Position{index:u64}
struct Saved{position:Position}
struct Entry{first:Position,second:Position}
struct State<const N:usize>{saved:Option<Saved>,slots:[Option<Entry>;N],len:usize}
impl<const N:usize> State<N>{
 fn base(&self)->Position{self.saved.as_ref().map_or(Position::default(),|s|s.position)}
 fn entries(&self)->impl DoubleEndedIterator<Item=&Entry>{self.slots[..self.len].iter().flatten()}
 fn last(&self)->Position{self.entries().next_back().map_or(self.base(),|e|e.first)}
 fn truncate(&mut self,boundary:u64){while self.last().index>=boundary && self.len>0{self.len-=1;self.slots[self.len]=None;}}
}
"#;
#[test]
fn complete_loop_retains_helpers_and_rejects_hidden_effects() {
    let w = Work::new(SOURCE);
    let t = w.lower("State::truncate").unwrap().truncation.unwrap();
    assert!(t.inclusive);
    assert_eq!(t.last_method, "State::last");
    assert_eq!(t.index_field, "index");
    assert_eq!(t.last.record_field, "first");
    for source in [
        SOURCE.replace("self.len-=1;", "self.len-=1;external();"),
        SOURCE.replace(
            "self.len-=1;self.slots[self.len]=None;",
            "self.slots[self.len]=None;self.len-=1;",
        ),
        SOURCE.replace(
            "self.last().index>=boundary && self.len>0",
            "self.len>0 && self.last().index>=boundary",
        ),
        SOURCE.replace("self.len-=1;", "self.len-=2;"),
        SOURCE.replace("self.slots[self.len]=None;", "self.slots[self.len+1]=None;"),
        SOURCE.replace("|e|e.first", "|e|{external();e.first}"),
    ] {
        assert!(
            Work::new(&source).lower("State::truncate").is_err(),
            "accepted {source}"
        );
    }
}
#[test]
fn native_sparse_truncation_agrees_on_partial_state_and_drop_order() {
    use provium::methods::{buffers::State, truncations::Run};
    for inclusive in [false, true] {
        let source = if inclusive {
            SOURCE.to_owned()
        } else {
            SOURCE.replace(".index>=boundary", ".index>boundary")
        };
        let w = Work::new(&source);
        let t = w.lower("State::truncate").unwrap().truncation.unwrap();
        let native = format!(
            r#"{source}
static DROPS:std::sync::Mutex<Vec<u64>>=std::sync::Mutex::new(Vec::new());
impl Drop for Entry{{fn drop(&mut self){{DROPS.lock().unwrap().push(self.first.index);}}}}
fn check<const N:usize>(){{
 for base in [0,97]{{for len in 0..=N+1{{for mask in 0..1usize<<N{{for boundary in [0,11,12,13,14,98,u64::MAX]{{
 let mut state:State<N>=State{{saved:if base==0{{None}}else{{Some(Saved{{position:Position{{index:base}}}})}},slots:core::array::from_fn(|i|if mask&(1<<i)==0{{None}}else{{Some(Entry{{first:Position{{index:i as u64+11}},second:Position{{index:99}}}})}}),len}};
 DROPS.lock().unwrap().clear();
 let ok=std::panic::catch_unwind(std::panic::AssertUnwindSafe(||state.truncate(boundary))).is_ok();
 println!("{{}} {{}} {{:?}} {{:?}}",ok,state.len,state.slots.iter().map(|e|e.as_ref().map(|e|e.first.index)).collect::<Vec<_>>(),*DROPS.lock().unwrap());
 }}}}}}}}
}}
fn main(){{std::panic::set_hook(Box::new(|_|{{}}));check::<0>();check::<1>();check::<3>();}}
"#
        );
        fs::write(w.0.join("main.rs"), native).unwrap();
        let binary = w.0.join("native");
        let build = std::process::Command::new("rustc")
            .args(["--edition=2021", "-C", "overflow-checks=yes"])
            .arg(w.0.join("main.rs"))
            .arg("-o")
            .arg(&binary)
            .output()
            .unwrap();
        assert!(
            build.status.success(),
            "{}",
            String::from_utf8_lossy(&build.stderr)
        );
        let actual = std::process::Command::new(binary).output().unwrap();
        assert!(actual.status.success());
        let mut expected = String::new();
        for capacity in [0, 1, 3] {
            for base in [0, 97] {
                for len in 0..=capacity + 1 {
                    for mask in 0..1usize << capacity {
                        for boundary in [0, 11, 12, 13, 14, 98, u64::MAX] {
                            let state = State {
                                slots: (0..capacity)
                                    .map(|i| {
                                        if mask & (1 << i) == 0 {
                                            None
                                        } else {
                                            Some(i as u64 + 11)
                                        }
                                    })
                                    .collect(),
                                len: len as u64,
                            };
                            let mut run = t.evaluate(state, boundary, base, |id, _| *id);
                            let mut drops = Vec::new();
                            loop {
                                match run {
                                    Run::Drop(payload, before, next) => {
                                        assert_eq!(
                                            before.slots[before.len as usize],
                                            Some(payload)
                                        );
                                        drops.push(payload);
                                        run = *next;
                                    }
                                    Run::Returned(state) => {
                                        expected.push_str(&format!(
                                            "true {} {:?} {:?}\n",
                                            state.len, state.slots, drops
                                        ));
                                        break;
                                    }
                                    Run::Bounds(state) => {
                                        expected.push_str(&format!(
                                            "false {} {:?} {:?}\n",
                                            state.len, state.slots, drops
                                        ));
                                        break;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        assert_eq!(String::from_utf8(actual.stdout).unwrap(), expected);
    }
}
#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn boundary_and_helper_mutations_break_the_contract() {
    let w = Work::new(SOURCE);
    fs::write(w.0.join("Proofs.lean"),r#"import Generated
open Provium.State
def view (n : Nat) : Path → InitStore := fun key _ => if key = ["first"] then .unsigned "u64" n else .unsigned "u64" 99
def records : SelectionStore := fun _ => none
def before : BufferState Nat := ⟨[some 11,some 12,some 13],3⟩
theorem removes_boundary : resumeTruncation (Subject.State_truncate view records before 12) = .returned ⟨[some 11,none,none],1⟩ := by
  simp [Subject.State_truncate, Subject.State_truncate_ir, truncateBuffer, truncateSteps, truncationCompare, truncationView, lastRecord, iterateRecords, presentPlaces, view, before, resumeTruncation]
theorem places : Subject.State_truncate_ir.slotsPath = ["slots"] ∧ Subject.State_truncate_ir.lengthPath = ["len"] ∧ resumeTruncation (Subject.State_truncate view records before 12) = .returned ⟨[some 11,none,none],1⟩ := by
  exact ⟨rfl,rfl,removes_boundary⟩
"#).unwrap();
    let config = w.0.join("project.json");
    fs::write(&config,r#"{"crate_root":"lib.rs","namespace":"Subject","methods":["State::truncate"],"proofs":"Proofs.lean","obligations":[{"theorem":"removes_boundary","function":"State_truncate"},{"theorem":"places","function":"State_truncate"}]}"#).unwrap();
    let out = w.0.join("out");
    provium::methods::verify(&config, &out).unwrap();
    for source in [
        SOURCE.replace(".index>=boundary", ".index>boundary"),
        SOURCE.replace("next_back()", "next()"),
        SOURCE.replace("|e|e.first", "|e|e.second"),
        SOURCE.replace("slots", "other"),
    ] {
        fs::write(w.0.join("lib.rs"), source).unwrap();
        let error = provium::methods::verify(&config, &out).unwrap_err();
        assert!(error.contains("Lean rejected Proofs.lean"), "{error}");
        assert!(!out.join("verified.json").exists());
    }
}
