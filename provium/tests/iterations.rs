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
                "iterations-{}-{}",
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
}
"#;
#[test]
fn prefix_bounds_and_every_helper_are_retained() {
    for namespace in ["core", "std"] {
        let w = Work::new(&format!(
            "use {namespace}::iter::DoubleEndedIterator;{SOURCE}"
        ));
        w.lower("State::last").unwrap();
    }
    let w = Work::new(SOURCE);
    let iter = w.lower("State::entries").unwrap().iteration.unwrap();
    assert_eq!(iter.slots, ["slots"]);
    assert_eq!(iter.length, ["len"]);
    assert!(!iter.inclusive);
    assert_eq!(
        iter.locations(3, &[Some(7), None, Some(9), Some(10)])
            .unwrap(),
        [0, 2]
    );
    assert!(iter.locations(2, &[Some(7)]).is_err());
    let last = w.lower("State::last").unwrap().last.unwrap();
    assert_eq!(last.iterator_method, "State::entries");
    assert_eq!(last.base_method, "State::base");
    assert_eq!(last.record_field, "first");
    assert!(last.from_back);
    for source in [
        SOURCE.replace("[..self.len]", "[1..self.len]"),
        SOURCE.replace(".iter().flatten()", ".iter().flatten().filter(|_|true)"),
        SOURCE.replace(
            "self.slots[..self.len].iter()",
            "external();self.slots[..self.len].iter()",
        ),
        SOURCE.replace("|e|e.first", "|e|{external();e.first}"),
        SOURCE.replace("map_or(self.base()", "map_or(external()"),
        format!("{SOURCE} trait Sneaky{{fn next_back(&mut self);}}"),
        SOURCE.replace("Item=&Entry", "Item=Entry"),
    ] {
        let w = Work::new(&source);
        assert!(w.lower("State::last").is_err(), "accepted {source}");
    }
}
#[test]
fn native_mixed_end_consumption_and_last_records_agree_with_denotation() {
    for (from_back, whole) in [(false, false), (true, false), (false, true), (true, true)] {
        let source = if from_back {
            SOURCE.to_owned()
        } else {
            SOURCE.replace(".next_back().map_or", ".next().map_or")
        };
        let source = if whole {
            source.replace("[..self.len]", "")
        } else {
            source
        };
        let source=format!("{source}\nstatic DROPS:std::sync::atomic::AtomicUsize=std::sync::atomic::AtomicUsize::new(0);\nimpl Drop for Entry{{fn drop(&mut self){{DROPS.fetch_add(1,std::sync::atomic::Ordering::Relaxed);}}}}\n");
        let w = Work::new(&source);
        let last = w.lower("State::last").unwrap().last.unwrap();
        let main = format!(
            r#"{source}
fn check<const N:usize>(){{
 for present in [false,true]{{for len in 0..=N+1{{for mask in 0..1usize<<N{{
  let state:State<N>=State{{saved:if present{{Some(Saved{{position:Position{{index:97}}}})}}else{{None}},slots:core::array::from_fn(|i|if mask&(1<<i)==0{{None}}else{{Some(Entry{{first:Position{{index:i as u64+11}},second:Position{{index:i as u64+21}}}})}}),len}};
  let drops=DROPS.load(std::sync::atomic::Ordering::Relaxed);
  let result=std::panic::catch_unwind(||{{
   let last=state.last().index;let mut iter=state.entries();let mut places=Vec::new();
   for step in 0..6{{let value=if step%2==0{{iter.next()}}else{{iter.next_back()}};
    places.push(value.and_then(|entry|state.slots.iter().position(|slot|slot.as_ref().is_some_and(|v|std::ptr::eq(v,entry)))));
   }}
   (last,places)
  }});
  assert_eq!(DROPS.load(std::sync::atomic::Ordering::Relaxed),drops);
  match result{{Ok((last,places))=>println!("{{}} {{:?}}",last,places),Err(_)=>println!("panic")}}
 }}}}}}
}}
fn main(){{check::<0>();check::<1>();check::<3>();}}
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
        for capacity in [0, 1, 3] {
            for present in [false, true] {
                for len in 0..=capacity + 1 {
                    for mask in 0..1usize << capacity {
                        let slots: Vec<_> = (0..capacity)
                            .map(|i| if mask & (1 << i) == 0 { None } else { Some(i) })
                            .collect();
                        let Ok(mut locations) = last.iteration.locations(len, &slots) else {
                            expected.push_str("panic\n");
                            continue;
                        };
                        let selected = if last.from_back {
                            locations.last()
                        } else {
                            locations.first()
                        };
                        let value = selected.map(|i| *i as u64 + 11).unwrap_or(if present {
                            97
                        } else {
                            0
                        });
                        let mut places = vec![];
                        for step in 0..6 {
                            places.push(if locations.is_empty() {
                                None
                            } else if step % 2 == 0 {
                                Some(locations.remove(0))
                            } else {
                                locations.pop()
                            });
                        }
                        expected.push_str(&format!("{value} {places:?}\n"));
                    }
                }
            }
        }
        assert_eq!(String::from_utf8(native.stdout).unwrap(), expected);
    }
}
#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn inclusive_range_wrong_end_and_wrong_record_break_the_contract() {
    let w = Work::new(SOURCE);
    fs::write(w.0.join("Proofs.lean"),r#"import Generated
open Provium.State
def entry (n : Nat) : Path → InitStore := fun key _ => if key = ["first"] then .unsigned "u64" n else .unsigned "u64" 99
def state : TraversalStore (Path → InitStore) := ⟨⟨fun _ => none,fun _ => [some (entry 11),none,some (entry 13)]⟩,fun _ => 3⟩
theorem entries : Subject.State_entries state = .ok [⟨["slots"],0⟩,⟨["slots"],2⟩] := by
  simp [Subject.State_entries,Subject.State_entries_ir,iterateRecords,state,presentPlaces]
theorem last : Subject.State_last state = .ok (entry 13 ["first"]) := by
  simp [Subject.State_last,Subject.State_last_ir,lastRecord,iterateRecords,state,presentPlaces]
"#).unwrap();
    let config = w.0.join("project.json");
    fs::write(&config,r#"{"crate_root":"lib.rs","namespace":"Subject","methods":["State::entries","State::last"],"proofs":"Proofs.lean","obligations":[{"theorem":"entries","function":"State_entries"},{"theorem":"last","function":"State_last"}]}"#).unwrap();
    let out = w.0.join("out");
    provium::methods::verify(&config, &out).unwrap();
    for source in [
        SOURCE.replace("[..self.len]", "[..=self.len]"),
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

const BORROWED: &str = r#"
struct View<'a, T> { cells: &'a [Option<T>] }
impl<T> View<'_, T> {
    fn entries(&self) -> impl DoubleEndedIterator<Item = &T> { self.cells.iter().flatten() }
}
"#;

#[test]
fn whole_borrowed_slices_preserve_holes_without_a_length_field() {
    let work = Work::new(BORROWED);
    let iteration = work.lower("View::entries").unwrap().iteration.unwrap();
    assert!(iteration.whole);
    assert!(iteration.length.is_empty());
    assert_eq!(
        iteration
            .locations(usize::MAX, &[Some(1), None, Some(2)])
            .unwrap(),
        [0, 2]
    );
    assert!(iteration
        .locations::<u8>(usize::MAX, &[])
        .unwrap()
        .is_empty());
    for changed in [
        BORROWED.replace("&'a [Option<T>]", "&'a mut [Option<T>]"),
        BORROWED.replace("iter().flatten()", "iter().flatten().rev()"),
        BORROWED.replace("self.cells.iter()", "self.cells[1..].iter()"),
        BORROWED.replace("self.cells.iter()", "self.touch(); self.cells.iter()"),
        BORROWED.replace("Item = &T", "Item = &u8"),
    ] {
        assert!(Work::new(&changed).lower("View::entries").is_err());
    }
}

#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn whole_slice_iterator_rebases_to_original_array_locations() {
    let work = Work::new(BORROWED);
    fs::write(
        work.0.join("Proofs.lean"),
        r#"import Generated
open Provium.State
 theorem exact (place : SlicePlace) (slots : List (Option α)) :
    Subject.View_entries (sliceTraversal ["cells"] place slots) =
      .ok (presentPlaces ["cells"] 0 (sliceContents place slots)) :=
  iterateWholeSlice ["cells"] place slots
 theorem origin (place : SlicePlace) (slots : List (Option α)) :
    (Subject.View_entries (sliceTraversal ["cells"] place slots)).map
      (List.map (rebasePlace place)) =
      .ok (presentPlaces place.path place.start (sliceContents place slots)) :=
  iterateWholeSlice_rebased ["cells"] place slots
example : loadPlaces (loadFrom ["cells"] [some 7]) [⟨["other"], 0⟩] = none := rfl
example : loadPlaces (loadFrom ["cells"] [some 7]) [⟨["cells"], 1⟩] = none := rfl
example : loadPlaces (loadFrom ["cells"] [none, some 7]) [⟨["cells"], 0⟩] = none := rfl
"#,
    )
    .unwrap();
    let project = work.0.join("project.json");
    fs::write(&project, r#"{"crate_root":"lib.rs","namespace":"Subject","methods":["View::entries"],"proofs":"Proofs.lean","obligations":[{"theorem":"exact","function":"View_entries"},{"theorem":"origin","function":"View_entries"}]}"#).unwrap();
    provium::methods::verify(&project, &work.0.join("out")).unwrap();
}

#[test]
fn native_borrowed_slice_iteration_preserves_addresses_and_drops_no_payloads() {
    use std::process::Command;
    let work = Work::new(BORROWED);
    let iteration = work.lower("View::entries").unwrap().iteration.unwrap();
    let source = format!(
        "{BORROWED}\n{}",
        r#"
use std::sync::atomic::{AtomicUsize, Ordering};
static DROPS: AtomicUsize = AtomicUsize::new(0);
struct Payload(usize);
impl Drop for Payload { fn drop(&mut self) { DROPS.fetch_add(1, Ordering::Relaxed); } }
fn main() {
 for mask in 0usize..16 {
  DROPS.store(0, Ordering::Relaxed);
  {
   let slots: [Option<Payload>; 4] = core::array::from_fn(|i| if mask & (1 << i) != 0 { Some(Payload(i)) } else { None });
   for start in 0..=4 { for stop in start..=4 {
    let view = View { cells: &slots[start..stop] };
    let mut iterator = view.entries();
    let mut found = Vec::new();
    for step in 0..6 {
     let value = if step % 2 == 0 { iterator.next() } else { iterator.next_back() };
     if let Some(value) = value { assert!(core::ptr::eq(value, slots[value.0].as_ref().unwrap())); }
     found.push(value.map(|value| value.0));
    }
    println!("{found:?}");
    assert_eq!(DROPS.load(Ordering::Relaxed), 0);
   }}
  }
  assert_eq!(DROPS.load(Ordering::Relaxed), mask.count_ones() as usize);
 }
}
"#
    );
    fs::write(work.0.join("native.rs"), source).unwrap();
    let binary = work.0.join("native");
    let compiled = Command::new("rustc")
        .args(["--edition=2021", "-Dwarnings"])
        .arg(work.0.join("native.rs"))
        .arg("-o")
        .arg(&binary)
        .output()
        .unwrap();
    assert!(
        compiled.status.success(),
        "{}",
        String::from_utf8_lossy(&compiled.stderr)
    );
    let actual = Command::new(binary).output().unwrap();
    assert!(
        actual.status.success(),
        "{}",
        String::from_utf8_lossy(&actual.stderr)
    );
    let mut expected = String::new();
    for mask in 0usize..16 {
        let slots: Vec<_> = (0..4)
            .map(|i| (mask & (1 << i) != 0).then_some(i))
            .collect();
        for start in 0..=4 {
            for stop in start..=4 {
                let mut locations = iteration
                    .locations(usize::MAX, &slots[start..stop])
                    .unwrap();
                let found: Vec<_> = (0..6)
                    .map(|step| {
                        if locations.is_empty() {
                            None
                        } else if step % 2 == 0 {
                            Some(start + locations.remove(0))
                        } else {
                            locations.pop().map(|index| start + index)
                        }
                    })
                    .collect();
                expected.push_str(&format!("{found:?}\n"));
            }
        }
    }
    assert_eq!(String::from_utf8(actual.stdout).unwrap(), expected);
}
