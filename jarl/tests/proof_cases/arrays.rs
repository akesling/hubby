use super::Work;
use provium::methods::{Condition, Crate, Literal, Statement};
use std::{collections::BTreeMap, fs, path::Path, process::Command};
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
    let krate = Crate::load(&root.join("src/lib.rs")).unwrap();
    let update = krate.lower("membership::Membership::finalized").unwrap();
    let query = krate.lower("membership::Membership::is_joint").unwrap();
    let peers = krate.lower("membership::Membership::peers").unwrap();
    assert!(peers.array.as_ref().unwrap().preserve_slots);
    let native = format!(
        r#"
type Id = usize;
#[derive(Clone,Copy)] struct Member {{id:usize,old:bool,voter:bool,learner:bool}}
#[derive(Clone,Copy)] struct Membership<const MAX:usize>{{members:[Option<Member>;MAX]}}
impl<const MAX:usize> Membership<MAX>{{{} {} {}}}
fn cases<const N:usize>(){{
 for code in 0..9usize.pow(N as u32) {{
  let mut rest=code;
  let members=core::array::from_fn(|i|{{let digit=rest%9;rest/=9;if digit==0{{None}}else{{let bits=digit-1;Some(Member{{id:i,old:bits&1!=0,voter:bits&2!=0,learner:bits&4!=0}})}}}});
  let initial=Membership::<N>{{members}};let result=initial.finalized();
  print!("{{}} {{}}",initial.is_joint(),result.is_joint());
  for slot in result.members {{match slot {{None=>print!(" -"),Some(m)=>print!(" {{}}:{{}}:{{}}:{{}}",m.id,m.old,m.voter,m.learner)}}}}
  for slot in initial.peers() {{match slot {{None=>print!(" p:-"),Some(id)=>print!(" p:{{}}",id)}}}}
  println!();
 }}
}}
fn main(){{cases::<0>();cases::<1>();cases::<2>();cases::<3>();}}
"#,
        update.rust, query.rust, peers.rust
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
            let mut peer_slots = String::new();
            for id in 0..n {
                let digit = code % 9;
                code /= 9;
                if digit == 0 {
                    peer_slots.push_str(" p:-");
                    slots.push_str(" -");
                    continue;
                }
                peer_slots.push_str(&format!(" p:{id}"));
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
            expected.push_str(&format!("{before} {after}{slots}{peer_slots}\n"));
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
    for entry in fs::read_dir(root.join("src")).unwrap() {
        let entry = entry.unwrap();
        if entry.path().is_file() {
            fs::copy(entry.path(), w.0.join("src").join(entry.file_name())).unwrap();
        }
    }
    fs::copy(root.join("README.md"), w.0.join("README.md")).unwrap();
    fs::copy(
        root.join("proofs/membership/Proofs.lean"),
        w.0.join("Proofs.lean"),
    )
    .unwrap();
    let mut config: serde_json::Value =
        serde_json::from_slice(&fs::read(root.join("proofs/membership/project.json")).unwrap())
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
        ("filter(|m| m.voter)", "filter(|m| m.old)"),
        ("filter(|m| m.old)", "filter(|m| m.learner)"),
        ("filter(|m| m.learner)", "filter(|m| m.voter)"),
        ("m.voter || m.old", "m.voter && m.old"),
        ("any(|m| m.id == id)", "any(|m| m.id == id && m.voter)"),
        ("0 => member.voter = true", "0 => member.voter = false"),
        ("old: false,", "old: true,"),
        ("if voters.is_empty()", "if old_voters.is_empty()"),
        (
            "kind == 1 && voters.contains(id)",
            "kind == 2 && voters.contains(id)",
        ),
        (
            "Self::restore(voters, &[], learners)",
            "Self::restore(learners, &[], voters)",
        ),
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
