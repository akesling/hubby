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
        let path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("artifacts")
            .join(format!(
                "validator-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
        fs::create_dir_all(&path).unwrap();
        fs::write(path.join("lib.rs"), source).unwrap();
        Self(path)
    }
    fn lower(&self) -> Result<provium::methods::Method, String> {
        Crate::load(&self.0.join("lib.rs"))?.lower("Checker::check")
    }
}
impl Drop for Work {
    fn drop(&mut self) {
        if !std::thread::panicking() {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
}
const SOURCE: &str = r#"
#[derive(Clone,Copy,Default,PartialEq)]
struct Position { offset:u64, epoch:u64 }
struct Item { position:Position }
enum Packet { Data { epoch:u64, base:Position, items:[Option<Item>;3], single:Option<Item> }, Ack { epoch:u64, probe:u64 } }
impl Packet { fn epoch(&self)->u64{match self{Self::Data{epoch,..}|Self::Ack{epoch,..}=>*epoch}} }
struct Checker;
impl Checker { fn check(packet:&Packet)->bool {
    if let Packet::Ack { probe,.. } = packet { return *probe>0; }
    let epoch=packet.epoch();
    let good=|position:Position|{position==Position::default() || (position.offset>0 && position.epoch>0 && position.epoch<=epoch)};
    epoch>0 && match packet {
        Packet::Data { base,items,single,.. } => {
            let mut prior=*base;
            let mut ended=false;
            let mut count=0;
            if !good(prior){return false;}
            for item in items {
                if let Some(item)=item {
                    if ended || !good(item.position) || prior.offset.checked_add(1)!=Some(item.position.offset) || item.position.epoch<prior.epoch {return false;}
                    prior=item.position;
                    count+=1;
                } else { ended=true; }
            }
            count>0 && single.as_ref().is_none_or(|item|good(item.position))
        }
        _=>true,
    }
} }
"#;
#[test]
fn complete_pure_body_and_helper_are_retained_and_unsupported_rust_rejected() {
    let w = Work::new(SOURCE);
    let v = w.lower().unwrap().validator.unwrap();
    assert_eq!(v.input, "Packet");
    assert_eq!(v.helpers.len(), 1);
    for op in [
        ".each",
        ".ret",
        ".choose",
        "checked_add",
        "\"i32\"",
        ".write",
        ".negate",
    ] {
        assert!(v.expression.contains(op), "missing {op}")
    }
    let changed = Work::new(&SOURCE.replace("count>0", "count>=0"))
        .lower()
        .unwrap()
        .validator
        .unwrap();
    assert_ne!(changed.expression, v.expression);
    for source in [
        SOURCE.replace("count+=1;", "external();count+=1;"),
        SOURCE.replace("for item in items", "for item in custom(items)"),
        SOURCE.replace("let good=|position", "let good=move |position"),
        SOURCE.replace(
            "position==Position::default()",
            "return position==Position::default()",
        ),
        SOURCE.replace("prior=item.position;", "prior=item.position.clone();"),
        SOURCE.replace("epoch>0 && match", "epoch.wrapping_add(1)>0 && match"),
        SOURCE.replace(
            "struct Checker;",
            "impl Position {fn default()->Self{Self{offset:1,epoch:1}}} struct Checker;",
        ),
        "enum Packet { Data { value: i32 } } struct Checker; impl Checker { fn check(packet: &Packet) -> bool { match packet { Packet::Data{value} => *value > 0 } } }".to_owned(),
        // A declaration's type parameter must not resolve to a same-named
        // module record, even when the instantiated argument is concrete.
        "struct Value { offset:u64 } struct Other { offset:u32 } enum Packet<Value> { Data { value:Value } } struct Checker; impl Checker { fn check(packet:&Packet<Other>)->bool { match packet { Packet::Data {value} => value.offset>0 } } }".to_owned(),
        "struct Value { offset:u64 } struct Other { offset:u32 } struct Holder<Value> { value:Value } enum Packet { Data { holder:Holder<Other> } } struct Checker; impl Checker { fn check(packet:&Packet)->bool { match packet { Packet::Data {holder} => holder.value.offset>0 } } }".to_owned(),
        format!("struct i32;{SOURCE}"),
        format!("struct Other<i32>{{value:i32}}{SOURCE}"),
        SOURCE.replace("let good=", "let Some=|value:u64|value;let good="),
    ] {
        assert!(Work::new(&source).lower().is_err(), "accepted {source}")
    }
}
fn position(index: u64, term: u64) -> String {
    format!(".record \"Position\" [(\"offset\",.number \"u64\" {index}),(\"epoch\",.number \"u64\" {term})]")
}
#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn native_validator_results_are_kernel_checked() {
    let w = Work::new(SOURCE);
    let mut main = format!("{SOURCE}\nfn main(){{\n");
    let mut inputs = Vec::new();
    for (epoch, base_index, base_term, items) in [
        (0, 0, 0, vec![(1, 1)]),
        (1, 0, 0, vec![]),
        (1, 0, 0, vec![(1, 1)]),
        (2, 0, 0, vec![(1, 1), (2, 2), (3, 2)]),
        (2, 0, 0, vec![(1, 1), (0, 0), (2, 2)]),
        (2, 0, 0, vec![(2, 1)]),
        (2, 1, 2, vec![(2, 1)]),
        (2, 0, 1, vec![(1, 1)]),
        (2, 0, 0, vec![(1, 3)]),
        (2, u64::MAX, 2, vec![(0, 2)]),
        (u64::MAX, u64::MAX - 1, u64::MAX, vec![(u64::MAX, u64::MAX)]),
    ] {
        for single in [None, Some((0, 1)), Some((1, 1))] {
            let mut native = Vec::new();
            let mut lean = Vec::new();
            for i in 0..3 {
                match items.get(i).copied().filter(|p| *p != (0, 0)) {
                    Some((index, term)) => {
                        native.push(format!(
                            "Some(Item{{position:Position{{offset:{index},epoch:{term}}}}})"
                        ));
                        lean.push(format!(
                            ".present (.record \"Item\" [(\"position\",{})])",
                            position(index, term)
                        ));
                    }
                    None => {
                        native.push("None".into());
                        lean.push(".absent".into());
                    }
                }
            }
            let (ns, ls) = match single {
                None => ("None".into(), ".absent".into()),
                Some((i, t)) => (
                    format!("Some(Item{{position:Position{{offset:{i},epoch:{t}}}}})"),
                    format!(
                        ".present (.record \"Item\" [(\"position\",{})])",
                        position(i, t)
                    ),
                ),
            };
            main.push_str(&format!("println!(\"{{}}\",Checker::check(&Packet::Data{{epoch:{epoch},base:Position{{offset:{base_index},epoch:{base_term}}},items:[{}],single:{ns}}}));\n",native.join(",")));
            inputs.push(format!(".variant \"Packet\" \"Data\" [(\"epoch\",.number \"u64\" {epoch}),(\"base\",{}),(\"items\",.array [{}]),(\"single\",{ls})]",position(base_index,base_term),lean.join(",")));
        }
    }
    for epoch in [0, 1, u64::MAX] {
        for probe in [0, 1, u64::MAX] {
            main.push_str(&format!(
                "println!(\"{{}}\",Checker::check(&Packet::Ack{{epoch:{epoch},probe:{probe}}}));\n"
            ));
            inputs.push(format!(".variant \"Packet\" \"Ack\" [(\"epoch\",.number \"u64\" {epoch}),(\"probe\",.number \"u64\" {probe})]"));
        }
    }
    main.push('}');
    fs::write(w.0.join("native.rs"), main).unwrap();
    let binary = w.0.join("native");
    let compiled = std::process::Command::new("rustc")
        .args(["--edition=2021", "-C", "overflow-checks=yes"])
        .arg(w.0.join("native.rs"))
        .arg("-o")
        .arg(&binary)
        .output()
        .unwrap();
    assert!(
        compiled.status.success(),
        "{}",
        String::from_utf8_lossy(&compiled.stderr)
    );
    let native = std::process::Command::new(binary).output().unwrap();
    assert!(native.status.success());
    let results = String::from_utf8(native.stdout).unwrap();
    assert_eq!(results.lines().count(), inputs.len());
    let mut proofs="import Generated\nopen Provium.State\nset_option maxRecDepth 10000\nset_option maxHeartbeats 4000000\n".to_string();
    let mut obligations = Vec::new();
    for (i, (input, result)) in inputs.iter().zip(results.lines()).enumerate() {
        assert!(matches!(result, "true" | "false"));
        proofs.push_str(&format!(
            "theorem native_{i} : Subject.Checker_check 256 ({input}) = .ok {result} := by rfl\n"
        ));
        obligations
            .push(serde_json::json!({"theorem":format!("native_{i}"),"function":"Checker_check"}));
    }
    fs::write(w.0.join("Proofs.lean"), proofs).unwrap();
    let config = w.0.join("project.json");
    fs::write(&config,serde_json::to_vec(&serde_json::json!({"crate_root":"lib.rs","namespace":"Subject","methods":["Checker::check"],"proofs":"Proofs.lean","obligations":obligations})).unwrap()).unwrap();
    provium::methods::verify(&config, &w.0.join("out")).unwrap();
    fs::write(
        w.0.join("lib.rs"),
        SOURCE.replace("if ended ||", "if false ||"),
    )
    .unwrap();
    let error = provium::methods::verify(&config, &w.0.join("out")).unwrap_err();
    assert!(error.contains("Lean rejected Proofs.lean"), "{error}");
    assert!(!w.0.join("out/verified.json").exists());
}

#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn record_equality_evaluates_operands_once_and_loop_rules_are_audited() {
    let declarations = SOURCE.split("impl Checker {").next().unwrap();
    let source = format!(
        r#"{declarations}
impl Checker {{ fn check(_packet:&Packet)->bool {{
    let mut count=0;
    let equal=({{count+=1;Position::default()}} == {{count+=1;Position::default()}});
    equal && count==2
}} }}
"#
    );
    let w = Work::new(&source);
    fs::write(
        w.0.join("Proofs.lean"),
        r#"import Generated
open Provium.State
set_option maxRecDepth 10000
theorem once (input : PureValue) : Subject.Checker_check 256 input = .ok true := by rfl
"#,
    )
    .unwrap();
    let config = w.0.join("project.json");
    fs::write(
        &config,
        serde_json::to_vec(&serde_json::json!({
            "crate_root":"lib.rs","namespace":"Subject","methods":["Checker::check"],
            "proofs":"Proofs.lean","obligations":[{"theorem":"once","function":"Checker_check"}]
        }))
        .unwrap(),
    )
    .unwrap();
    let out = w.0.join("out");
    provium::methods::verify(&config, &out).unwrap();
    fs::write(
        out.join("Rules.lean"),
        r#"import Provium.State
import Provium.Audit
#provium_check Provium.State.pure_sequence_error references Provium.State.pureEval
#provium_check Provium.State.pure_binary_left_error references Provium.State.pureEval
#provium_check Provium.State.pure_fold_invariant references Provium.State.pureEval
#provium_check Provium.State.pure_each_invariant references Provium.State.pureEval
#provium_check Provium.State.pure_fold_history references Provium.State.pureEval
#provium_check Provium.State.pure_eval_step references Provium.State.pureEval
open Provium.State
theorem symbolic_literal (env : PureEnv) :
    pureEval 256 (.literal (.boolean true)) env = .ok (.boolean true,env) := by
  simp (disch := decide) [pure_eval_step]
#provium_check symbolic_literal references Provium.State.pureEval
"#,
    )
    .unwrap();
    let toolchain =
        fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join("lean-toolchain")).unwrap();
    let checked = std::process::Command::new("elan")
        .args([
            "run",
            toolchain.trim(),
            "lean",
            "--trust=0",
            "-DwarningAsError=true",
            "Rules.lean",
        ])
        .current_dir(&out)
        .env("LEAN_PATH", &out)
        .output()
        .unwrap();
    assert!(
        checked.status.success(),
        "{}\n{}",
        String::from_utf8_lossy(&checked.stdout),
        String::from_utf8_lossy(&checked.stderr)
    );
    assert_eq!(
        String::from_utf8_lossy(&checked.stdout)
            .matches("PROVIUM_VERIFIED ")
            .count(),
        7
    );
}

#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn closures_preserve_lexical_closure_captures() {
    let source = r#"
#[derive(Clone,Copy)]
struct Position { offset:u64, epoch:u64 }
enum Packet { Data { position:Position } }
struct Checker;
impl Checker { fn check(packet:&Packet)->bool {
    let check=|position:Position|position.offset>0;
    let wrapper=|position:Position|check(position);
    let check=|position:Position|position.epoch>0;
    match packet { Packet::Data {position} => wrapper(*position) && !check(*position) }
} }
"#;
    let w = Work::new(source);
    fs::write(
        w.0.join("Proofs.lean"),
        r#"import Generated
open Provium.State
set_option maxRecDepth 10000
theorem captured : Subject.Checker_check 256
  (.variant "Packet" "Data" [("position", .record "Position"
    [("offset", .number "u64" 1), ("epoch", .number "u64" 0)])]) = .ok true := by rfl
"#,
    )
    .unwrap();
    let config = w.0.join("project.json");
    fs::write(
        &config,
        serde_json::to_vec(&serde_json::json!({
            "crate_root":"lib.rs","namespace":"Subject","methods":["Checker::check"],
            "proofs":"Proofs.lean","obligations":[{"theorem":"captured","function":"Checker_check"}]
        }))
        .unwrap(),
    )
    .unwrap();
    provium::methods::verify(&config, &w.0.join("out")).unwrap();
    fs::write(w.0.join("main.rs"),format!("{source}\nfn main() {{ assert!(Checker::check(&Packet::Data {{ position:Position {{offset:1,epoch:0}} }})); }}")).unwrap();
    let binary = w.0.join("native");
    let compiled = std::process::Command::new("rustc")
        .arg(w.0.join("main.rs"))
        .arg("-o")
        .arg(&binary)
        .output()
        .unwrap();
    assert!(
        compiled.status.success(),
        "{}",
        String::from_utf8_lossy(&compiled.stderr)
    );
    assert!(std::process::Command::new(binary)
        .status()
        .unwrap()
        .success());
}

#[test]
fn record_fields_resolve_in_their_declaration_module() {
    let source = r#"
mod records;
use records::Item;
enum Packet { Data { item:Item } }
struct Checker;
impl Checker { fn check(packet:&Packet)->bool {
    match packet { Packet::Data {item} => item.position.offset>0 }
} }
"#;
    let w = Work::new(source);
    fs::write(
        w.0.join("records.rs"),
        "#[derive(Clone,Copy)] pub struct Position { pub offset:u64, pub epoch:u64 } pub struct Item { pub position:Position }",
    )
    .unwrap();
    assert!(w.lower().unwrap().validator.is_some());
}
