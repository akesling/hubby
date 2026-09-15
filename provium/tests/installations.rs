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
                "installations-{}-{}",
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
#[derive(Clone,Copy,Default,PartialEq)] struct Position{index:u64,term:u64}
struct Saved{position:Position,serial:u64}
struct Entry{position:Position,serial:u64}
struct Hard{durable:u64}
struct State<const N:usize>{hard:Hard,saved:Option<Saved>,slots:[Option<Entry>;N],len:usize}
impl<const N:usize> State<N>{
 fn base(&self)->Position{self.saved.as_ref().map_or(Position::default(),|s|s.position)}
 fn get(&self,index:u64)->Option<&Entry>{let offset=index.checked_sub(self.base().index)?.checked_sub(1)?;let offset=usize::try_from(offset).ok()?;self.slots.get(offset)?.as_ref()}
 fn id_at(&self,index:u64)->Option<Position>{if index==self.base().index{Some(self.base())}else{self.get(index).map(|e|e.position)}}
 fn install(&mut self,incoming:Saved){
  if self.id_at(incoming.position.index)==Some(incoming.position){
   let remove=(incoming.position.index-self.base().index) as usize;
   self.slots[..self.len].rotate_left(remove);
   self.len-=remove;
   for entry in &mut self.slots[self.len..]{*entry=None;}
  }else{
   for entry in &mut self.slots[..self.len]{*entry=None;}
   self.len=0;
  }
  self.hard.durable=self.hard.durable.max(incoming.position.index);
  self.saved=Some(incoming);
 }
}
"#;
#[test]
fn complete_installation_keeps_places_equality_and_source_order() {
    let w = Work::new(SOURCE);
    let i = w.lower("State::install").unwrap().installation.unwrap();
    assert_eq!(i.equality_fields, ["index", "term"]);
    assert_eq!(i.record_at_method, "State::id_at");
    assert_eq!(i.commit, ["hard", "durable"]);
    for source in [
        SOURCE.replace("self.len-=remove;", "self.len-=remove;external();"),
        SOURCE.replace("*entry=None;", "external();*entry=None;"),
        SOURCE.replace(
            "self.hard.durable.max(incoming.position.index)",
            "external()",
        ),
        SOURCE.replace("self.slots[self.len..]", "self.slots[..self.len]"),
        SOURCE.replace("self.len-=remove;", "self.len-=1;"),
        SOURCE.replace("PartialEq)]", "Eq)]"),
    ] {
        assert!(
            Work::new(&source).lower("State::install").is_err(),
            "accepted {source}"
        );
    }
}
#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn original_installation_and_mutations_are_kernel_checked() {
    let w = Work::new(SOURCE);
    fs::write(w.0.join("Proofs.lean"),r#"import Generated
open Provium.State
def entry (n : Nat) : Path → InitStore := fun _ key => if key = ["index"] then .unsigned "u64" n else .unsigned "u64" 1
def before : InstallationState Nat Nat := ⟨⟨[some 1,some 2,some 3],3⟩,0,none⟩
theorem matching : resumeInstallation (Subject.State_install 64 entry entry before 2) = .returned ⟨⟨[some 3,none,none],1⟩,2,some 2⟩ := by
  simp [Subject.State_install,Subject.State_install_ir,installSnapshot,installationView,recordWord,recordWords,recordEquality,recordAt,lookupRecord,selectRecord,initializeFields,initialCell,entry,before,clearInstallation,finishInstallation,resumeInstallation]
def changedTerm (n : Nat) : Path → InitStore := fun _ key => if key = ["index"] then .unsigned "u64" n else .unsigned "u64" 2
theorem term_mismatch : resumeInstallation (Subject.State_install 64 entry changedTerm before 2) = .returned ⟨⟨[none,none,none],0⟩,2,some 2⟩ := by
  simp [Subject.State_install,Subject.State_install_ir,installSnapshot,installationView,recordWord,recordWords,recordEquality,recordAt,lookupRecord,selectRecord,initializeFields,initialCell,entry,changedTerm,before,clearInstallation,finishInstallation,resumeInstallation]
theorem missing : resumeInstallation (Subject.State_install 64 entry entry before 7) = .returned ⟨⟨[none,none,none],0⟩,7,some 7⟩ := by
  simp [Subject.State_install,Subject.State_install_ir,installSnapshot,installationView,recordWord,recordEquality,recordAt,lookupRecord,selectRecord,initializeFields,initialCell,entry,before,clearInstallation,finishInstallation,resumeInstallation]
"#).unwrap();
    let config = w.0.join("project.json");
    fs::write(&config,r#"{"crate_root":"lib.rs","namespace":"Subject","methods":["State::install"],"proofs":"Proofs.lean","obligations":[{"theorem":"matching","function":"State_install"},{"theorem":"missing","function":"State_install"},{"theorem":"term_mismatch","function":"State_install"}]}"#).unwrap();
    let out = w.0.join("out");
    provium::methods::verify(&config, &out).unwrap();
    for source in [
        SOURCE.replace("==Some(incoming.position)", "!=Some(incoming.position)"),
        SOURCE.replace("rotate_left(remove)", "rotate_right(remove)"),
        SOURCE.replace(
            ".max(incoming.position.index)",
            ".min(incoming.position.index)",
        ),
    ] {
        fs::write(w.0.join("lib.rs"), source).unwrap();
        let error = provium::methods::verify(&config, &out).unwrap_err();
        assert!(error.contains("Lean rejected Proofs.lean"), "{error}");
        assert!(!out.join("verified.json").exists());
    }
}
#[test]
fn native_installation_matches_payloads_commit_partial_states_and_destructors() {
    use provium::methods::{
        buffers,
        installations::{Run, State},
    };
    for source in [
        SOURCE.to_owned(),
        SOURCE.replace("rotate_left(remove)", "rotate_right(remove)"),
        SOURCE.replace("==Some(incoming.position)", "!=Some(incoming.position)"),
        SOURCE.replace(
            ".max(incoming.position.index)",
            ".min(incoming.position.index)",
        ),
    ] {
        let w = Work::new(&source);
        let installation = w.lower("State::install").unwrap().installation.unwrap();
        let main = format!(
            r#"{source}
static DROPS:std::sync::Mutex<Vec<String>>=std::sync::Mutex::new(Vec::new());
impl Drop for Entry{{fn drop(&mut self){{DROPS.lock().unwrap().push(format!("e{{}}",self.serial));}}}}
impl Drop for Saved{{fn drop(&mut self){{DROPS.lock().unwrap().push(format!("s{{}}",self.serial));}}}}
fn check<const N:usize>(){{
 for base in [0,2]{{for len in 0..=N+1{{for mask in 0..1usize<<N{{for commit in [0,9]{{for index in [0,1,2,3,4,7,u64::MAX]{{for term in [0,1,2]{{
 let mut state:State<N>=State{{hard:Hard{{durable:commit}},saved:if base==0{{None}}else{{Some(Saved{{position:Position{{index:base,term:1}},serial:50}})}},slots:core::array::from_fn(|i|if mask&(1<<i)==0{{None}}else{{Some(Entry{{position:Position{{index:base+1+i as u64,term:1}},serial:i as u64}})}}),len}};
 DROPS.lock().unwrap().clear();
 let ok=std::panic::catch_unwind(std::panic::AssertUnwindSafe(||state.install(Saved{{position:Position{{index,term}},serial:99}}))).is_ok();
 // The IR fault stops before unwinding and retains the owned input. In this
 // test its normal destructor runs during unwind; account for it separately.
 if !ok{{assert_eq!(DROPS.lock().unwrap().pop().as_deref(),Some("s99"));}}
 println!("{{}} {{}} {{:?}} {{}} {{:?}} {{:?}}",ok,state.len,state.slots.iter().map(|e|e.as_ref().map(|e|e.serial)).collect::<Vec<_>>(),state.hard.durable,state.saved.as_ref().map(|s|(s.position.index,s.position.term,s.serial)),*DROPS.lock().unwrap());
 }}}}}}}}}}}}
}}
fn main(){{std::panic::set_hook(Box::new(|_|{{}}));check::<0>();check::<1>();check::<3>();}}
"#
        );
        fs::write(w.0.join("main.rs"), main).unwrap();
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
        let mut expected = String::new();
        for capacity in [0, 1, 3] {
            for base in [0, 2] {
                for len in 0..=capacity + 1 {
                    for mask in 0..1usize << capacity {
                        for commit in [0, 9] {
                            for index in [0, 1, 2, 3, 4, 7, u64::MAX] {
                                for term in [0, 1, 2] {
                                    let state = State {
                                        buffer: buffers::State {
                                            slots: (0..capacity)
                                                .map(|i| {
                                                    if mask & (1 << i) == 0 {
                                                        None
                                                    } else {
                                                        Some((base + 1 + i as u64, 1, i as u64))
                                                    }
                                                })
                                                .collect(),
                                            len: len as u64,
                                        },
                                        commit,
                                        snapshot: if base == 0 {
                                            None
                                        } else {
                                            Some((base, 1, 50))
                                        },
                                    };
                                    let read = |v: &(u64, u64, u64), _: &str, field: &str| {
                                        if field == "index" {
                                            v.0
                                        } else {
                                            v.1
                                        }
                                    };
                                    let mut run = installation
                                        .evaluate(64, state, (index, term, 99), read, read)
                                        .unwrap();
                                    let mut drops = Vec::new();
                                    loop {
                                        match run {
                                            Run::DropEntry(payload, _, _, next) => {
                                                drops.push(format!("e{}", payload.2));
                                                run = *next;
                                            }
                                            Run::DropSnapshot(payload, before, _, next) => {
                                                assert_eq!(before.snapshot, Some(payload));
                                                drops.push(format!("s{}", payload.2));
                                                run = *next;
                                            }
                                            Run::Returned(state) => {
                                                expected.push_str(&format!(
                                                    "true {} {:?} {} {:?} {:?}\n",
                                                    state.buffer.len,
                                                    state
                                                        .buffer
                                                        .slots
                                                        .iter()
                                                        .map(|e| e.map(|e| e.2))
                                                        .collect::<Vec<_>>(),
                                                    state.commit,
                                                    state.snapshot,
                                                    drops
                                                ));
                                                break;
                                            }
                                            Run::Bounds(state, _) | Run::Subtraction(state, _) => {
                                                expected.push_str(&format!(
                                                    "false {} {:?} {} {:?} {:?}\n",
                                                    state.buffer.len,
                                                    state
                                                        .buffer
                                                        .slots
                                                        .iter()
                                                        .map(|e| e.map(|e| e.2))
                                                        .collect::<Vec<_>>(),
                                                    state.commit,
                                                    state.snapshot,
                                                    drops
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
            }
        }
        assert_eq!(String::from_utf8(actual.stdout).unwrap(), expected);
    }
}
