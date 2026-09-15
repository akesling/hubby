use provium::methods::Crate;
use std::{
    fs,
    path::{Path, PathBuf},
    sync::atomic::{AtomicUsize, Ordering},
};
static NEXT: AtomicUsize = AtomicUsize::new(0);
struct Source(PathBuf);
impl Source {
    fn new(text: &str) -> Self {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("artifacts")
            .join(format!(
                "query-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("lib.rs"), text).unwrap();
        Self(dir)
    }
    fn load(&self) -> Crate {
        Crate::load(&self.0.join("lib.rs")).unwrap()
    }
}
impl Drop for Source {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
const SUBJECT: &str = r#"
enum Failure { Pending }
struct State<T, const N: usize> { dirty: bool, reply: Option<T>, queue: [Option<T>;N] }
impl<T,const N:usize> State<T,N> {
fn available(&self)->Result<(),Failure> {
    if self.dirty || self.reply.is_some() || self.queue.iter().any(Option::is_some) {
        Err(Failure::Pending)
    } else { Ok(()) }
}
fn idle(&self)->Result<(),Failure> { self.available() }
}
"#;
#[test]
fn complete_query_records_reads_results_and_inlined_calls() {
    let source = Source::new(SUBJECT);
    let krate = source.load();
    let methods = [
        krate.lower("State::available").unwrap(),
        krate.lower("State::idle").unwrap(),
    ];
    let ir = serde_json::to_string(&methods).unwrap();
    assert!(ir.contains("AnyPresent"));
    assert!(ir.contains("Failure::Pending"));
    assert!(ir.contains("Call"));
    let lean = provium::methods::generate(&methods, "Subject");
    assert!(lean.contains("QueryStore"));
    assert!(lean.contains("State_idle_correspondence"));
}
#[test]
fn effects_unresolved_constructors_and_recursion_are_not_sliced_away() {
    for text in [
        SUBJECT.replace("if self.dirty", "panic!(\"side effect\"); if self.dirty"),
        SUBJECT.replace("self.available()", "self.idle()"),
        SUBJECT.replace("Err(Failure::Pending)", "Err(Failure::Missing)"),
        SUBJECT.replace(
            "self.queue.iter().any(Option::is_some)",
            "self.queue.iter().any(|_| true)",
        ),
        SUBJECT.replace("self.reply.is_some()", "self.dirty.is_some()"),
        SUBJECT.replace("else { Ok(()) }", "else { Ok(()); panic!(\"late fault\") }"),
    ] {
        let source = Source::new(&text);
        let krate = source.load();
        assert!(
            krate.lower("State::available").is_err() || krate.lower("State::idle").is_err(),
            "accepted {text}"
        );
    }
}

#[test]
fn original_query_execution_matches_ir_for_all_small_optional_arrays() {
    use provium::methods::queries::{Query, Test};
    fn evaluate(t: &Test, dirty: bool, extra: bool, queue: &[bool]) -> bool {
        match t {
            Test::Boolean(b) => *b,
            Test::Field(p) => {
                assert_eq!(p, &["dirty"]);
                dirty
            }
            Test::Present(p) => {
                assert_eq!(p, &["reply"]);
                extra
            }
            Test::AnyPresent(p) => {
                assert_eq!(p, &["queue"]);
                queue.iter().any(|p| *p)
            }
            Test::Not(t) => !evaluate(t, dirty, extra, queue),
            Test::And(a, b) => evaluate(a, dirty, extra, queue) && evaluate(b, dirty, extra, queue),
            Test::Or(a, b) => evaluate(a, dirty, extra, queue) || evaluate(b, dirty, extra, queue),
        }
    }
    fn run(q: &Query, dirty: bool, extra: bool, queue: &[bool]) -> bool {
        match q {
            Query::Success => true,
            Query::Failure(error) => {
                assert_eq!(error, "Failure::Pending");
                false
            }
            Query::Branch { condition, yes, no } => run(
                if evaluate(condition, dirty, extra, queue) {
                    yes
                } else {
                    no
                },
                dirty,
                extra,
                queue,
            ),
            Query::Call { body, .. } => run(body, dirty, extra, queue),
        }
    }
    let source = Source::new(SUBJECT);
    let method = source.load().lower("State::idle").unwrap();
    let mut expected = String::new();
    for n in 0..=4 {
        for dirty in [false, true] {
            for extra in [false, true] {
                for mask in 0..(1 << n) {
                    let queue = (0..n).map(|i| mask & (1 << i) != 0).collect::<Vec<_>>();
                    expected.push_str(
                        if run(method.query.as_ref().unwrap(), dirty, extra, &queue) {
                            "true\n"
                        } else {
                            "false\n"
                        },
                    );
                }
            }
        }
    }
    let runner = format!(
        r#"{SUBJECT}
fn cases<const N:usize>() {{
    for dirty in [false,true] {{ for extra in [false,true] {{ for mask in 0..(1u32<<N) {{
        let state=State {{ dirty,reply:extra.then_some(7u64),queue:core::array::from_fn::<_,N,_>(|i|(mask&(1<<i)!=0).then_some(42u64)) }};
        assert_eq!(state.idle().is_ok(),state.available().is_ok());
        println!("{{}}",state.idle().is_ok());
    }} }} }}
}}
fn main() {{ cases::<0>(); cases::<1>(); cases::<2>(); cases::<3>(); cases::<4>(); }}
"#
    );
    fs::write(source.0.join("main.rs"), runner).unwrap();
    let binary = source.0.join("native");
    let output = std::process::Command::new("rustc")
        .args(["--edition=2021"])
        .arg(source.0.join("main.rs"))
        .arg("-o")
        .arg(&binary)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let output = std::process::Command::new(binary).output().unwrap();
    assert!(output.status.success());
    assert_eq!(String::from_utf8(output.stdout).unwrap(), expected);
}

#[test]
fn constructor_and_type_shadowing_are_rejected() {
    for prefix in [
        "fn Ok(_: ()) -> Result<(),Failure> { Err(Failure::Pending) }",
        "const Err: fn(Failure) -> Result<(),Failure> = |_| Ok(());",
        "mod shadow { struct Failure; }",
        "enum Result { Hidden }",
    ] {
        let source = Source::new(&format!("{prefix}\n{SUBJECT}"));
        assert!(Crate::load(&source.0.join("lib.rs")).is_err());
    }
    let source = Source::new(&SUBJECT.replace(
        "impl<T,const N:usize> State<T,N>",
        "impl<Option,const N:usize> State<Option,N>",
    ));
    assert!(Crate::load(&source.0.join("lib.rs"))
        .err()
        .unwrap()
        .contains("impl generic parameter"));
}

#[test]
fn exponential_query_expansion_is_bounded() {
    let mut source = String::from("enum Failure { Pending } struct State { dirty: bool } impl State { fn f0(&self)->Result<(),Failure>{ Ok(()) }");
    for i in 1..20 {
        source.push_str(&format!("fn f{i}(&self)->Result<(),Failure>{{ if self.dirty {{ self.f{}() }} else {{ self.f{}() }} }}",i-1,i-1));
    }
    source.push('}');
    let subject = Source::new(&source);
    assert!(subject
        .load()
        .lower("State::f19")
        .unwrap_err()
        .contains("expansion exceeds budget"));
}

#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn independent_consumer_query_contract_is_kernel_checked_and_source_sensitive() {
    let subject = Source::new(SUBJECT);
    fs::write(
        subject.0.join("Proofs.lean"),
        r#"import Generated
open Provium.State
theorem blocked (s : QueryStore α) (h : s ["dirty"] = .boolean true) :
  Subject.State_available s = .error "Failure::Pending" := by
  simp [Subject.State_available, Subject.State_available_ir, runQuery, evalQueryTest, h]
theorem wrapper (s : QueryStore α) : Subject.State_idle s = Subject.State_available s := by rfl
"#,
    )
    .unwrap();
    let config = subject.0.join("project.json");
    fs::write(&config,r#"{"crate_root":"lib.rs","namespace":"Subject","methods":["State::available","State::idle"],"proofs":"Proofs.lean","obligations":[{"theorem":"blocked","function":"State_available"},{"theorem":"wrapper","function":"State_idle"}]}"#).unwrap();
    let out = subject.0.join("out");
    provium::methods::verify(&config, &out).unwrap();
    let certificate: serde_json::Value =
        serde_json::from_slice(&fs::read(out.join("verified.json")).unwrap()).unwrap();
    assert_eq!(certificate["whole_program_proved"], false);
    fs::write(
        subject.0.join("lib.rs"),
        SUBJECT.replace("self.dirty || ", ""),
    )
    .unwrap();
    let error = provium::methods::verify(&config, &out).unwrap_err();
    assert!(error.contains("Lean rejected Proofs.lean"), "{error}");
    assert!(!out.join("verified.json").exists());
}
