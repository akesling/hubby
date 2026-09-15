use provium::methods::{constructors::Initial, Crate};
use std::{
    fs,
    path::{Path, PathBuf},
    sync::atomic::{AtomicUsize, Ordering},
};
static NEXT: AtomicUsize = AtomicUsize::new(0);
struct Work(PathBuf);
impl Work {
    fn new(source: &str) -> Self {
        let path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("artifacts")
            .join(format!(
                "selectors-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
        fs::create_dir_all(&path).unwrap();
        fs::write(path.join("lib.rs"), source).unwrap();
        Self(path)
    }
    fn lower(&self) -> Result<provium::methods::Method, String> {
        Crate::load(&self.0.join("lib.rs"))?.lower("State::select")
    }
}
impl Drop for Work {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
const SOURCE: &str = r#"
#[derive(Clone,Copy,Default)] struct Position{index:u64,term:u64}
struct Saved{first:Position,second:Position}
struct State{saved:Option<Saved>}
impl State{fn select(&self)->Position{self.saved.as_ref().map_or(Position::default(),|s|s.first)}}
"#;
#[test]
fn selector_keeps_field_paths_and_checks_the_eager_default() {
    let w = Work::new(SOURCE);
    let s = w.lower().unwrap().selection.unwrap();
    assert_eq!(s.optional, ["saved"]);
    assert_eq!(s.record_field, "first");
    assert_eq!(s.record_type, "Position");
    assert_eq!(s.fallback.len(), 2);
    for field in s.fallback {
        assert!(matches!(field.value, Initial::Unsigned { value: 0, .. }));
    }
    for source in [
        SOURCE.replace("|s|s.first", "|s|{external();s.first}"),
        SOURCE.replace("Position::default()", "external()"),
        SOURCE.replace("impl State{", "impl<Position:Default> State{"),
        format!("{SOURCE} impl Position{{fn default()->Self{{panic!()}}}}"),
        format!("{SOURCE} trait Default{{}}"),
        SOURCE
            .replace(
                "struct State{saved:Option<Saved>}",
                "struct State<Saved>{saved:Option<Saved>}",
            )
            .replace("impl State{", "impl<Saved> State<Saved>{"),
        SOURCE.replace("|s|s.first", "|s|s.unknown"),
    ] {
        let w = Work::new(&source);
        assert!(w.lower().is_err(), "accepted {source}");
    }
}
#[test]
fn native_record_selection_agrees_with_both_projected_fields() {
    for selected in ["first", "second"] {
        let source = SOURCE.replace("|s|s.first", &format!("|s|s.{selected}"));
        let w = Work::new(&source);
        let selection = w.lower().unwrap().selection.unwrap();
        let main = format!(
            r#"{source}
fn main(){{
 for present in [false,true]{{for index in [0,1,u64::MAX]{{for term in [0,2,u64::MAX]{{
  let saved=if present{{Some(Saved{{first:Position{{index,term}},second:Position{{index:term,term:index}}}})}}else{{None}};
  let value=State{{saved}}.select();println!("{{}} {{}}",value.index,value.term);
 }}}}}}
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
            for index in [0, 1, u64::MAX] {
                for term in [0, 2, u64::MAX] {
                    let (index, term) = if present {
                        match selection.record_field.as_str() {
                            "first" => (index, term),
                            "second" => (term, index),
                            _ => panic!(),
                        }
                    } else {
                        (0, 0)
                    };
                    expected.push_str(&format!("{index} {term}\n"));
                }
            }
        }
        assert_eq!(String::from_utf8(native.stdout).unwrap(), expected);
    }
}
#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn changing_selected_source_field_fails_the_contract() {
    let w = Work::new(SOURCE);
    fs::write(
        w.0.join("Proofs.lean"),
        r#"import Generated
open Provium.State
theorem selected (state : SelectionStore) (saved : Path → InitStore)
    (present : state ["saved"] = some saved) : Subject.State_select state = saved ["first"] := by
  simp [Subject.State_select,Subject.State_select_ir,selectRecord,present]
"#,
    )
    .unwrap();
    let config = w.0.join("project.json");
    fs::write(&config,r#"{"crate_root":"lib.rs","namespace":"Subject","methods":["State::select"],"proofs":"Proofs.lean","obligations":[{"theorem":"selected","function":"State_select"}]}"#).unwrap();
    let out = w.0.join("out");
    provium::methods::verify(&config, &out).unwrap();
    fs::write(
        w.0.join("lib.rs"),
        SOURCE.replace("|s|s.first", "|s|s.second"),
    )
    .unwrap();
    let error = provium::methods::verify(&config, &out).unwrap_err();
    assert!(error.contains("Lean rejected Proofs.lean"), "{error}");
    assert!(!out.join("verified.json").exists());
}
