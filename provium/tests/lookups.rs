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
                "lookups-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
        fs::create_dir_all(&p).unwrap();
        fs::write(p.join("lib.rs"), source).unwrap();
        Self(p)
    }
    fn lower(&self) -> Result<provium::methods::Method, String> {
        Crate::load(&self.0.join("lib.rs"))?.lower("State::get")
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
struct State<T,const N:usize>{saved:Option<Saved>,slots:[Option<T>;N]}
impl<T,const N:usize> State<T,N>{
 fn base(&self)->Position{self.saved.as_ref().map_or(Position::default(),|s|s.position)}
 fn get(&self,index:u64)->Option<&T>{
  let offset=index.checked_sub(self.base().index)?.checked_sub(1)?;
  let offset=usize::try_from(offset).ok()?;
  self.slots.get(offset)?.as_ref()
 }
}
"#;
#[test]
fn lookup_retains_helper_paths_checked_bias_and_target_conversion() {
    let w = Work::new(SOURCE);
    let lookup = w.lower().unwrap().lookup.unwrap();
    assert_eq!(lookup.slots, ["slots"]);
    assert_eq!(lookup.base.optional, ["saved"]);
    assert_eq!(lookup.base.record_field, "position");
    assert_eq!(lookup.base_field, "index");
    assert_eq!(lookup.bias, 1);
    for bits in [32, 64] {
        assert_eq!(
            lookup.evaluate(bits, 3, 4, &[Some(7), None]).unwrap(),
            Some(0)
        );
        assert_eq!(lookup.evaluate(bits, 3, 3, &[Some(7)]).unwrap(), None);
        assert_eq!(lookup.evaluate(bits, 3, 2, &[Some(7)]).unwrap(), None);
        assert_eq!(lookup.evaluate(bits, 3, 5, &[Some(7), None]).unwrap(), None);
        assert_eq!(
            lookup.evaluate(bits, 3, u64::MAX, &[Some(7)]).unwrap(),
            None
        );
    }
}
#[test]
fn hidden_effects_and_overridden_standard_traits_are_rejected() {
    for source in [
        SOURCE.replace("let offset=usize::try_from(offset).ok()?;","let offset=offset as usize;"),
        SOURCE.replace("self.slots.get(offset)?.as_ref()","external();self.slots.get(offset)?.as_ref()"),
        SOURCE.replace("self.base().index","self.base().unknown"),
        SOURCE.replace("checked_sub(1)","wrapping_sub(1)"),
        SOURCE.replace("|s|s.position","|s|{external();s.position}"),
        format!("{SOURCE} trait TryFrom{{fn try_from(n:u64)->Result<usize,()>;}} impl TryFrom for usize{{fn try_from(_:u64)->Result<usize,()>{{Ok(0)}}}}"),
        format!("{SOURCE} trait Sneaky{{fn get(&self,n:usize)->Option<&Option<u64>>;}} impl Sneaky for [Option<u64>;2]{{fn get(&self,_:usize)->Option<&Option<u64>>{{None}}}}"),
    ]{let w=Work::new(&source);assert!(w.lower().is_err(),"accepted {source}");}
}
#[test]
fn native_lookup_returns_the_same_borrowed_location_at_word_boundaries() {
    let w = Work::new(SOURCE);
    let lookup = w.lower().unwrap().lookup.unwrap();
    let main = format!(
        r#"{SOURCE}
fn main(){{
 for present in [false,true]{{for base in [0,1,u32::MAX as u64,u64::MAX]{{for index in [0,1,2,3,4,u32::MAX as u64,u64::MAX]{{for mask in 0..16usize{{
  let state:State<u64,4>=State{{saved:if present{{Some(Saved{{position:Position{{index:base,term:13}}}})}}else{{None}},slots:core::array::from_fn(|i|if mask&(1<<i)==0{{None}}else{{Some(7)}})}};
  let got=state.get(index);
  let location=got.and_then(|reference|state.slots.iter().position(|slot|slot.as_ref().is_some_and(|value|std::ptr::eq(value,reference))));
  println!("{{:?}}",location);
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
        for base in [0, 1, u32::MAX as u64, u64::MAX] {
            for index in [0, 1, 2, 3, 4, u32::MAX as u64, u64::MAX] {
                for mask in 0..16usize {
                    let slots: Vec<_> = (0..4)
                        .map(|i| if mask & (1 << i) == 0 { None } else { Some(7) })
                        .collect();
                    let location = lookup
                        .evaluate(usize::BITS, if present { base } else { 0 }, index, &slots)
                        .unwrap();
                    expected.push_str(&format!("{location:?}\n"));
                }
            }
        }
    }
    assert_eq!(String::from_utf8(native.stdout).unwrap(), expected);
}
#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn source_bias_field_and_array_changes_fail_the_contract() {
    let w = Work::new(SOURCE);
    fs::write(w.0.join("Proofs.lean"),r#"import Generated
open Provium.State
def record : InitStore := fun key => if key = ["index"] then .unsigned "u64" 5 else .unsigned "u64" 13
def state : LookupStore Nat := ⟨fun _ => some (fun _ => record), fun _ => [some 7, some 7]⟩
theorem position : Subject.State_get 64 state 6 = .ok (some ⟨["slots"],0⟩) := by
  simp [Subject.State_get,Subject.State_get_ir,lookupRecord,selectRecord,state,record]
"#).unwrap();
    let config = w.0.join("project.json");
    fs::write(&config,r#"{"crate_root":"lib.rs","namespace":"Subject","methods":["State::get"],"proofs":"Proofs.lean","obligations":[{"theorem":"position","function":"State_get"}]}"#).unwrap();
    let out = w.0.join("out");
    provium::methods::verify(&config, &out).unwrap();
    for source in [
        SOURCE.replace("checked_sub(1)", "checked_sub(0)"),
        SOURCE.replace("self.base().index", "self.base().term"),
        SOURCE.replace("slots", "other"),
    ] {
        fs::write(w.0.join("lib.rs"), source).unwrap();
        let error = provium::methods::verify(&config, &out).unwrap_err();
        assert!(error.contains("Lean rejected Proofs.lean"), "{error}");
        assert!(!out.join("verified.json").exists());
    }
}
