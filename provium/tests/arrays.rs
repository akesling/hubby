use provium::methods::{Condition, Crate, Literal, Statement};
use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
    process::Command,
    sync::atomic::{AtomicUsize, Ordering},
};
static NEXT: AtomicUsize = AtomicUsize::new(0);
struct Work(PathBuf);
impl Work {
    fn new() -> Self {
        let p = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("artifacts")
            .join(format!(
                "array-tests-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
        fs::create_dir_all(&p).unwrap();
        Self(p)
    }
    fn source(&self, s: &str) -> PathBuf {
        let p = self.0.join("lib.rs");
        fs::write(&p, s).unwrap();
        p
    }
}
impl Drop for Work {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
const SOURCE: &str = r#"
#[derive(Clone,Copy)] struct Member {old:bool,voter:bool,learner:bool}
#[derive(Clone,Copy)] struct Membership<const N:usize> {members:[Option<Member>;N]}
impl<const N:usize> Membership<N>{
 fn finalized(mut self)->Self {
  for slot in &mut self.members {if let Some(member)=slot {member.old=false;if !member.voter && !member.learner {*slot=None;}}}
  self
 }
 fn is_joint(&self)->bool {self.members.iter().flatten().any(|m| m.old)}
}
"#;
#[test]
fn arrays_require_complete_traversals_and_resolved_builtin_operations() {
    let w = Work::new();
    let krate = Crate::load(&w.source(SOURCE)).unwrap();
    let update = krate.lower("Membership::finalized").unwrap();
    assert_eq!(update.writes.len(), 2);
    assert_eq!(update.array.as_ref().unwrap().capacity, "N");
    assert!(krate
        .lower("Membership::is_joint")
        .unwrap()
        .array
        .unwrap()
        .predicate
        .is_some());
    for bad in [
        SOURCE.replace("member.old=false;", "member.old=false;external();"),
        SOURCE.replace("{*slot=None;}", "{*slot=None;} break;"),
        SOURCE.replace("&mut self.members", "&self.members"),
        SOURCE.replace(
            "member.old=false;",
            "member.old=false; self.members[0]=None;",
        ),
        SOURCE.replace("#[derive(Clone,Copy)] struct Member", "struct Member"),
        SOURCE.replace("self\n }", "self.members[0]=None; self\n }"),
        SOURCE.replace(
            "{*slot=None;}",
            "{*slot=Some(Member{old:false,voter:false,learner:false});}",
        ),
    ] {
        assert!(
            Crate::load(&w.source(&bad))
                .and_then(|c| c.lower("Membership::finalized"))
                .is_err(),
            "accepted {bad}"
        );
    }
    for bad in [SOURCE.replace(".iter()",".into_iter()"),SOURCE.replace("|m| m.old","|m| check(m)"),format!("{SOURCE} trait Shadow {{fn iter(&self)->std::iter::Empty<&Member>{{std::iter::empty()}}}} impl<T> Shadow for T {{}}") ] {
        assert!(Crate::load(&w.source(&bad)).and_then(|c|c.lower("Membership::is_joint")).is_err(),"accepted {bad}");
    }
}
fn condition(c: &Condition, s: &BTreeMap<String, bool>) -> bool {
    match c {
        Condition::Boolean(b) => *b,
        Condition::Field(p) => s[&p.join(".")],
        Condition::Not(c) => !condition(c, s),
        Condition::And(a, b) => condition(a, s) && condition(b, s),
        Condition::Or(a, b) => condition(a, s) || condition(b, s),
    }
}
fn execute(body: &[Statement], s: &mut BTreeMap<String, bool>) {
    for stmt in body {
        match stmt {
            Statement::Write(w) => {
                let Literal::Boolean(b) = w.literal else {
                    panic!("unexpected literal")
                };
                s.insert(w.path.join("."), b);
            }
            Statement::Branch {
                condition: c,
                yes,
                no,
            } => {
                let selected = if condition(c, s) { yes } else { no };
                execute(selected, s);
            }
            Statement::Call { body, .. } => execute(body, s),
        }
    }
}
#[test]
fn original_membership_methods_agree_with_translation_across_array_capacities() {
    let w = Work::new();
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let krate = Crate::load(&root.join("../jarl/src/lib.rs")).unwrap();
    let update = krate.lower("membership::Membership::finalized").unwrap();
    let query = krate.lower("membership::Membership::is_joint").unwrap();
    let native = format!(
        r#"
#[derive(Clone,Copy)] struct Member {{id:usize,old:bool,voter:bool,learner:bool}}
#[derive(Clone,Copy)] struct Membership<const MAX:usize>{{members:[Option<Member>;MAX]}}
impl<const MAX:usize> Membership<MAX>{{{} {}}}
fn cases<const N:usize>(){{
 for code in 0..9usize.pow(N as u32) {{
  let mut rest=code;
  let members=core::array::from_fn(|i|{{let digit=rest%9;rest/=9;if digit==0{{None}}else{{let bits=digit-1;Some(Member{{id:i,old:bits&1!=0,voter:bits&2!=0,learner:bits&4!=0}})}}}});
  let initial=Membership::<N>{{members}};let result=initial.finalized();
  print!("{{}} {{}}",initial.is_joint(),result.is_joint());
  for slot in result.members {{match slot {{None=>print!(" -"),Some(m)=>print!(" {{}}:{{}}:{{}}:{{}}",m.id,m.old,m.voter,m.learner)}}}}
  println!();
 }}
}}
fn main(){{cases::<0>();cases::<1>();cases::<2>();cases::<3>();}}
"#,
        update.rust, query.rust
    );
    let source = w.source(&native);
    let binary = w.0.join("native");
    let built = Command::new("rustc")
        .args(["--edition=2021", "-C", "overflow-checks=yes"])
        .arg(source)
        .arg("-o")
        .arg(&binary)
        .output()
        .unwrap();
    assert!(
        built.status.success(),
        "{}",
        String::from_utf8_lossy(&built.stderr)
    );
    let actual = Command::new(binary).output().unwrap();
    assert!(actual.status.success());
    let predicate = query.array.as_ref().unwrap().predicate.as_ref().unwrap();
    let mut expected = String::new();
    for n in 0..=3 {
        for mut code in 0..9usize.pow(n) {
            let mut before = false;
            let mut after = false;
            let mut slots = String::new();
            for id in 0..n {
                let digit = code % 9;
                code /= 9;
                if digit == 0 {
                    slots.push_str(" -");
                    continue;
                }
                let bits = digit - 1;
                let mut state = BTreeMap::from([
                    ("old".into(), bits & 1 != 0),
                    ("voter".into(), bits & 2 != 0),
                    ("learner".into(), bits & 4 != 0),
                    ("$present".into(), true),
                ]);
                before |= condition(predicate, &state);
                execute(&update.body, &mut state);
                if state["$present"] {
                    after |= condition(predicate, &state);
                    slots.push_str(&format!(
                        " {id}:{}:{}:{}",
                        state["old"], state["voter"], state["learner"]
                    ));
                } else {
                    slots.push_str(" -");
                }
            }
            expected.push_str(&format!("{before} {after}{slots}\n"));
        }
    }
    assert_eq!(String::from_utf8(actual.stdout).unwrap(), expected);
}

#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn original_membership_mutations_break_the_array_contracts() {
    let w = Work::new();
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    fs::create_dir(w.0.join("src")).unwrap();
    for entry in fs::read_dir(root.join("../jarl/src")).unwrap() {
        let entry = entry.unwrap();
        if entry.path().is_file() {
            fs::copy(entry.path(), w.0.join("src").join(entry.file_name())).unwrap();
        }
    }
    fs::copy(root.join("../jarl/README.md"), w.0.join("README.md")).unwrap();
    fs::copy(
        root.join("examples/jarl-membership/Proofs.lean"),
        w.0.join("Proofs.lean"),
    )
    .unwrap();
    let mut config: serde_json::Value = serde_json::from_slice(
        &fs::read(root.join("examples/jarl-membership/project.json")).unwrap(),
    )
    .unwrap();
    config["crate_root"] = "src/lib.rs".into();
    let path = w.0.join("project.json");
    fs::write(&path, config.to_string()).unwrap();
    let out = w.0.join("out");
    provium::methods::verify(&path, &out).unwrap();
    let source = w.0.join("src/membership.rs");
    let original = fs::read_to_string(&source).unwrap();
    for (from, to) in [
        ("member.old = false;", "member.old = true;"),
        (
            "!member.voter && !member.learner",
            "!member.voter || !member.learner",
        ),
        ("any(|m| m.old)", "any(|m| m.voter)"),
    ] {
        assert!(original.contains(from));
        fs::write(&source, original.replace(from, to)).unwrap();
        let error = provium::methods::verify(&path, &out).unwrap_err();
        assert!(
            error.contains("Lean rejected Proofs.lean"),
            "{from} -> {to}: {error}"
        );
        assert!(!out.join("verified.json").exists());
    }
}
