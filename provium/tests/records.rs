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
                "records-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
        fs::create_dir_all(&p).unwrap();
        fs::write(p.join("lib.rs"), source).unwrap();
        Self(p)
    }
    fn lower(&self) -> Result<provium::methods::Method, String> {
        Crate::load(&self.0.join("lib.rs"))?.lower("State::at")
    }
}
impl Drop for Work {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
const SOURCE: &str = r#"
#[derive(Clone,Copy,Default)] struct Position{index:u64,term:u64}
struct Saved{position:Position}
struct Entry{first:Position,second:Position}
struct State<const N:usize>{saved:Option<Saved>,slots:[Option<Entry>;N]}
impl<const N:usize> State<N>{
 fn base(&self)->Position{self.saved.as_ref().map_or(Position::default(),|s|s.position)}
 fn get(&self,index:u64)->Option<&Entry>{
  let offset=index.checked_sub(self.base().index)?.checked_sub(1)?;
  let offset=usize::try_from(offset).ok()?;
  self.slots.get(offset)?.as_ref()
 }
 fn at(&self,index:u64)->Option<Position>{
  if index==self.base().index{Some(self.base())}else{self.get(index).map(|e|e.first)}
 }
}
"#;
#[test]
fn record_lookup_includes_both_complete_helpers_and_rejects_hidden_effects() {
    let w = Work::new(SOURCE);
    let at = w.lower().unwrap().record_at.unwrap();
    assert_eq!(at.lookup_method, "State::get");
    assert_eq!(at.lookup.base_method, "State::base");
    assert_eq!(at.record_field, "first");
    assert!(at.equal);
    for source in [
        SOURCE.replace("Some(self.base())", "Some(external())"),
        SOURCE.replace("self.get(index).map", "self.get(0).map"),
        SOURCE.replace("|e|e.first", "|e|{external();e.first}"),
        SOURCE.replace("self.get(index).map(|e|e.first)", "None"),
        SOURCE.replace("|e|e.first", "|e|e.unknown"),
        SOURCE.replace(
            "let offset=usize::try_from(offset).ok()?;",
            "external();let offset=usize::try_from(offset).ok()?;",
        ),
    ] {
        let w = Work::new(&source);
        assert!(w.lower().is_err(), "accepted {source}");
    }
}
#[test]
fn native_optional_records_match_boundary_and_entry_projection() {
    for record_field in ["first", "second"] {
        let source = SOURCE.replace("|e|e.first", &format!("|e|e.{record_field}"));
        let w = Work::new(&source);
        let at = w.lower().unwrap().record_at.unwrap();
        let main = format!(
            r#"{source}
fn main(){{
 for present in [false,true]{{for base in [0,1,u64::MAX]{{for index in [0,1,2,3,u64::MAX]{{for mask in 0..4usize{{
  let state:State<2>=State{{saved:if present{{Some(Saved{{position:Position{{index:base,term:7}}}})}}else{{None}},slots:core::array::from_fn(|i|if mask&(1<<i)==0{{None}}else{{Some(Entry{{first:Position{{index:i as u64+101,term:2}},second:Position{{index:i as u64+201,term:3}}}})}})}};
  println!("{{:?}}",state.at(index).map(|p|(p.index,p.term)));
 }}}}}}}}
}}
"#
        );
        let file = w.0.join("main.rs");
        fs::write(&file, main).unwrap();
        let binary = w.0.join("native");
        let built = std::process::Command::new("rustc")
            .args(["--edition=2021", "-C", "overflow-checks=yes"])
            .arg(file)
            .arg("-o")
            .arg(&binary)
            .output()
            .unwrap();
        assert!(
            built.status.success(),
            "{}",
            String::from_utf8_lossy(&built.stderr)
        );
        let native = std::process::Command::new(binary).output().unwrap();
        assert!(native.status.success());
        let mut expected = String::new();
        for present in [false, true] {
            for base in [0, 1, u64::MAX] {
                for index in [0, 1, 2, 3, u64::MAX] {
                    for mask in 0..4usize {
                        let boundary = if present { (base, 7) } else { (0, 0) };
                        let slots: Vec<_> = (0..2)
                            .map(|i| if mask & (1 << i) == 0 { None } else { Some(i) })
                            .collect();
                        let output = if (index == boundary.0) == at.equal {
                            Some(boundary)
                        } else {
                            at.lookup
                                .evaluate(usize::BITS, boundary.0, index, &slots)
                                .unwrap()
                                .map(|i| match at.record_field.as_str() {
                                    "first" => (i as u64 + 101, 2),
                                    "second" => (i as u64 + 201, 3),
                                    _ => panic!(),
                                })
                        };
                        expected.push_str(&format!("{output:?}\n"));
                    }
                }
            }
        }
        assert_eq!(String::from_utf8(native.stdout).unwrap(), expected);
    }
}
#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn branch_projection_and_helper_mutations_fail_the_record_contract() {
    let w = Work::new(SOURCE);
    fs::write(w.0.join("Proofs.lean"),r#"import Generated
open Provium.State
def boundary : InitStore := fun _ => .unsigned "u64" 5
def entry : Path → InitStore := fun key _ => if key = ["first"] then .unsigned "u64" 17 else .unsigned "u64" 29
def state : LookupStore (Path → InitStore) := ⟨fun _ => some (fun _ => boundary), fun _ => [some entry]⟩
theorem result : Subject.State_at 64 state 5 = .ok (some boundary) ∧
    Subject.State_at 64 state 6 = .ok (some (entry ["first"])) := by
  simp [Subject.State_at,Subject.State_at_ir,recordAt,lookupRecord,selectRecord,state,boundary]
"#).unwrap();
    let config = w.0.join("project.json");
    fs::write(&config,r#"{"crate_root":"lib.rs","namespace":"Subject","methods":["State::at"],"proofs":"Proofs.lean","obligations":[{"theorem":"result","function":"State_at"}]}"#).unwrap();
    let out = w.0.join("out");
    provium::methods::verify(&config, &out).unwrap();
    for source in [
        SOURCE.replace("index==self.base().index", "index!=self.base().index"),
        SOURCE.replace("|e|e.first", "|e|e.second"),
        SOURCE.replace("checked_sub(1)", "checked_sub(0)"),
    ] {
        fs::write(w.0.join("lib.rs"), source).unwrap();
        let error = provium::methods::verify(&config, &out).unwrap_err();
        assert!(error.contains("Lean rejected Proofs.lean"), "{error}");
        assert!(!out.join("verified.json").exists());
    }
}
