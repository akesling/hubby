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
#provium_check Provium.State.pure_u64_bounded_arithmetic references Provium.State.pureBinary
#provium_check Provium.State.pure_u64_saturation_bounds references Min.min
#provium_check Provium.State.pure_u64_saturation_exact references Min.min
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
            "--threads=1",
            "-DwarningAsError=true",
        ])
        .arg(format!(
            "--memory={}",
            provium::project::lean_memory_limit_mb().unwrap()
        ))
        .arg("Rules.lean")
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
        10
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

const ARITHMETIC: &str = r#"
enum Packet {
    Minimum { a:u64, b:u64, expected:u64 },
    Maximum { a:u64, b:u64, expected:u64 },
    Add { a:u64, b:u64, expected:u64 },
    Subtract { a:u64, b:u64, expected:u64 },
    Checked { a:u64, b:u64, expected:u64, missing:bool },
}
struct Checker;
impl Checker { fn check(packet:&Packet)->bool {
    match packet {
        Packet::Minimum {a,b,expected} => (*a).min(*b)==*expected,
        Packet::Maximum {a,b,expected} => (*a).max(*b)==*expected,
        Packet::Add {a,b,expected} => {
            let mut trace=0;
            let value=({trace+=1;*a}).saturating_add({trace+=trace;*b});
            trace==2 && value==*expected
        },
        Packet::Subtract {a,b,expected} => (*a).saturating_sub(*b)==*expected,
        Packet::Checked {a,b,expected,missing} => {
            if *missing { (*a).checked_sub(*b)==None } else { (*a).checked_sub(*b)==Some(*expected) }
        }
    }
} }
"#;

#[test]
fn arithmetic_requires_builtin_value_receivers_and_unambiguous_ordering() {
    assert!(Work::new(ARITHMETIC).lower().unwrap().validator.is_some());
    for source in [
        ARITHMETIC.replace("(*a).min(*b)","a.min(b)"),
        ARITHMETIC.replace("trace+=trace;*b","trace+=trace;true"),
        format!("trait Ord {{fn min(self, other:Self)->Self;}} impl Ord for u64 {{fn min(self,_other:Self)->Self{{0}}}} {ARITHMETIC}"),
        ARITHMETIC.replace("a:u64", "a:i32"),
        format!("struct None;{ARITHMETIC}"),
    ] {
        assert!(Work::new(&source).lower().is_err(),"accepted {source}");
    }
}

#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn builtin_arithmetic_agrees_with_native_rust_at_word_boundaries() {
    let w = Work::new(ARITHMETIC);
    let mut native = format!("{ARITHMETIC}\nfn main(){{\n");
    let mut inputs = Vec::new();
    for (a, b) in [
        (0, 0),
        (0, 1),
        (1, 0),
        (1, 1),
        (u64::MAX, 0),
        (u64::MAX, 1),
        (1, u64::MAX),
        (u64::MAX, u64::MAX),
        (u64::MAX - 1, 2),
    ] {
        for expected in [0, 1, u64::MAX] {
            for (tag, missing) in [
                ("Minimum", None),
                ("Maximum", None),
                ("Add", None),
                ("Subtract", None),
                ("Checked", Some(false)),
                ("Checked", Some(true)),
            ] {
                let native_extra =
                    missing.map_or(String::new(), |value| format!(",missing:{value}"));
                let lean_extra = missing.map_or(String::new(), |value| {
                    format!(",(\"missing\",.boolean {value})")
                });
                native.push_str(&format!("println!(\"{{}}\",Checker::check(&Packet::{tag}{{a:{a},b:{b},expected:{expected}{native_extra}}}));\n"));
                inputs.push(format!(".variant \"Packet\" \"{tag}\" [(\"a\",.number \"u64\" {a}),(\"b\",.number \"u64\" {b}),(\"expected\",.number \"u64\" {expected}){lean_extra}]"));
            }
        }
    }
    native.push('}');
    fs::write(w.0.join("native.rs"), native).unwrap();
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
    let ran = std::process::Command::new(binary).output().unwrap();
    assert!(ran.status.success());
    let results = String::from_utf8(ran.stdout).unwrap();
    assert_eq!(results.lines().count(), inputs.len());
    let mut proofs =
        "import Generated\nopen Provium.State\nset_option maxRecDepth 10000\nset_option maxHeartbeats 2000000\n".to_owned();
    let mut obligations = Vec::new();
    for (index, (input, result)) in inputs.iter().zip(results.lines()).enumerate() {
        assert!(matches!(result, "true" | "false"));
        proofs.push_str(&format!("theorem native_{index} : Subject.Checker_check 256 ({input}) = .ok {result} := by rfl\n"));
        obligations.push(
            serde_json::json!({"theorem":format!("native_{index}"),"function":"Checker_check"}),
        );
    }
    proofs.push_str(
        r#"
theorem arbitrary_sum (a b expected : Nat)
    (aBound : a < 2^64) (bBound : b < 2^64) (expectedBound : expected < 2^64) :
    Subject.Checker_check 256 (.variant "Packet" "Add"
      [("a",.number "u64" a),("b",.number "u64" b),("expected",.number "u64" expected)]) =
      .ok (min (a+b) (2^64-1) == expected) := by
  have ha : ¬18446744073709551616 ≤ a := Nat.not_le_of_gt aBound
  have hb : ¬18446744073709551616 ≤ b := Nat.not_le_of_gt bBound
  have he : ¬18446744073709551616 ≤ expected := Nat.not_le_of_gt expectedBound
  have hs : ¬18446744073709551616 ≤ min (a+b) 18446744073709551615 := by omega
  simp [Subject.Checker_check,Subject.Checker_check_ir,pureValidate,pureEval,pureMatch,
    pureSet,pureBinary,pureBound,ha,hb,he,hs,
    List.findSome?,List.find?,List.foldlM,bind,Option.bind,Except.bind,pure,Except.pure]
"#,
    );
    obligations.push(serde_json::json!({"theorem":"arbitrary_sum","function":"Checker_check"}));
    fs::write(w.0.join("Proofs.lean"), proofs).unwrap();
    let config = w.0.join("project.json");
    fs::write(&config,serde_json::to_vec(&serde_json::json!({"crate_root":"lib.rs","namespace":"Subject","methods":["Checker::check"],"proofs":"Proofs.lean","obligations":obligations})).unwrap()).unwrap();
    provium::methods::verify(&config, &w.0.join("out")).unwrap();
    fs::write(
        w.0.join("lib.rs"),
        ARITHMETIC.replace(".saturating_add(", ".saturating_sub("),
    )
    .unwrap();
    let error = provium::methods::verify(&config, &w.0.join("out")).unwrap_err();
    assert!(error.contains("Lean rejected Proofs.lean"), "{error}");
    assert!(!w.0.join("out/verified.json").exists());
}

const OPTIONAL_RECORDS: &str = r#"
#[derive(Clone,Copy,PartialEq)] struct Key { generation:u64, position:u64 }
enum Packet { Compare { left:Option<Key>, right:Option<Key>, negated:bool } }
struct Checker;
impl Checker { fn check(packet:&Packet)->bool {
    match packet {
        Packet::Compare {left,right,negated} => {
            let mut trace=0;
            let equal = if *negated {
                ({trace+=1;*left}) != ({trace+=trace;*right})
            } else {
                ({trace+=1;*left}) == ({trace+=trace;*right})
            };
            trace==2 && equal
        }
    }
} }
"#;

#[test]
fn optional_record_equality_requires_derived_primitive_records() {
    assert!(Work::new(OPTIONAL_RECORDS)
        .lower()
        .unwrap()
        .validator
        .is_some());
    for source in [
        OPTIONAL_RECORDS.replace(",PartialEq", ""),
        format!(
            "{} impl PartialEq for Key {{ fn eq(&self, _other:&Self)->bool {{ false }} }}",
            OPTIONAL_RECORDS.replace(",PartialEq", "")
        ),
        OPTIONAL_RECORDS.replace(",Copy", ""),
        OPTIONAL_RECORDS.replace("generation:u64", "generation:i32"),
        OPTIONAL_RECORDS.replace("generation:u64", "generation:Option<u64>"),
    ] {
        assert!(Work::new(&source).lower().is_err(), "accepted {source}");
    }
}

#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn optional_record_equality_agrees_with_native_rust_and_evaluates_both_operands_once() {
    let w = Work::new(OPTIONAL_RECORDS);
    let values = [
        None,
        Some((0, 0)),
        Some((0, 1)),
        Some((1, 0)),
        Some((u64::MAX, u64::MAX)),
    ];
    let rust_value = |value: Option<(u64, u64)>| {
        value.map_or("None".to_owned(), |(a, b)| {
            format!("Some(Key{{generation:{a},position:{b}}})")
        })
    };
    let lean_value = |value: Option<(u64, u64)>| {
        value.map_or(".absent".to_owned(), |(a,b)|format!(".present (.record \"Key\" [(\"generation\",.number \"u64\" {a}),(\"position\",.number \"u64\" {b})])"))
    };
    let mut native = format!("{OPTIONAL_RECORDS}\nfn main(){{\n");
    let mut inputs = Vec::new();
    for left in values {
        for right in values {
            for negated in [false, true] {
                native.push_str(&format!("println!(\"{{}}\",Checker::check(&Packet::Compare{{left:{},right:{},negated:{negated}}}));\n",rust_value(left),rust_value(right)));
                inputs.push(format!(".variant \"Packet\" \"Compare\" [(\"left\",{}),(\"right\",{}),(\"negated\",.boolean {negated})]",lean_value(left),lean_value(right)));
            }
        }
    }
    native.push('}');
    fs::write(w.0.join("native.rs"), native).unwrap();
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
    let ran = std::process::Command::new(binary).output().unwrap();
    assert!(ran.status.success());
    let results = String::from_utf8(ran.stdout).unwrap();
    assert_eq!(results.lines().count(), inputs.len());
    let mut proofs =
        "import Generated\nopen Provium.State\nset_option maxRecDepth 10000\n".to_owned();
    let mut obligations = Vec::new();
    for (index, (input, result)) in inputs.iter().zip(results.lines()).enumerate() {
        assert!(matches!(result, "true" | "false"));
        proofs.push_str(&format!("theorem native_{index} : Subject.Checker_check 256 ({input}) = .ok {result} := by rfl\n"));
        obligations.push(
            serde_json::json!({"theorem":format!("native_{index}"),"function":"Checker_check"}),
        );
    }
    fs::write(w.0.join("Proofs.lean"), proofs).unwrap();
    let config = w.0.join("project.json");
    fs::write(&config,serde_json::to_vec(&serde_json::json!({"crate_root":"lib.rs","namespace":"Subject","methods":["Checker::check"],"proofs":"Proofs.lean","obligations":obligations})).unwrap()).unwrap();
    provium::methods::verify(&config, &w.0.join("out")).unwrap();
    fs::write(
        w.0.join("lib.rs"),
        OPTIONAL_RECORDS.replace("trace+=trace;*right", "trace+=trace;*left"),
    )
    .unwrap();
    let error = provium::methods::verify(&config, &w.0.join("out")).unwrap_err();
    assert!(error.contains("Lean rejected Proofs.lean"), "{error}");
    assert!(!w.0.join("out/verified.json").exists());
}
