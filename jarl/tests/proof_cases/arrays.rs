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
#[ignore = "requires pinned Lean and installed wasm32 target; scripts/verify.sh runs this"]
fn membership_word_contract_uses_captured_32_bit_target() {
    let w = Work::new();
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let mut project: serde_json::Value =
        serde_json::from_slice(&fs::read(root.join("proofs/membership/project.json")).unwrap())
            .unwrap();
    project["crate_root"] = root.join("src/lib.rs").to_str().unwrap().into();
    project["proofs"] = root
        .join("proofs/membership/Proofs.lean")
        .to_str()
        .unwrap()
        .into();
    w.build_request(&root.join("Cargo.toml"), "wasm32-unknown-unknown");
    project["cargo_build"] = "build.json".into();
    let config = w.write("project.json", &project.to_string());
    provium::methods::verify(&config, &w.out()).unwrap();
    let manifest: serde_json::Value =
        serde_json::from_slice(&fs::read(w.out().join("manifest.json")).unwrap()).unwrap();
    assert_eq!(manifest["target_usize_bits"], 32);
    assert!(!manifest["cargo_build"].is_null());
    let verified: serde_json::Value =
        serde_json::from_slice(&fs::read(w.out().join("verified.json")).unwrap()).unwrap();
    assert_eq!(verified["target_word_refinements"], 1);
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
    w.cargo_build();
    config["cargo_build"] = "build.json".into();
    let path = w.0.join("project.json");
    fs::write(&path, config.to_string()).unwrap();
    let out = w.0.join("out");
    provium::methods::verify(&path, &out).unwrap();
    let source = w.0.join("src/membership.rs");
    let original = fs::read_to_string(&source).unwrap();
    for (from, to) in [
        ("count / 2 + 1", "count / 3 + 1"),
        ("for id in self.old_voters()", "for id in self.voters()"),
        ("count > total / 2", "count >= total / 2"),
        ("count > total / 2", "count > total / 3"),
        (
            "if old { m.old } else { m.voter }",
            "if old { m.voter } else { m.old }",
        ),
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
        ("target.include(id, 2)", "target.include(id, 1)"),
        ("map_err(|_| Error::Full)", "map_err(|_| Error::Config)"),
        ("next.include(id, 0)?;", "next.include(id, 2)?;"),
        ("next.include(*id, 1)?;", "next.include(*id, 2)?;"),
        (
            "self.is_voter(*id) || learners[..i].contains(id)",
            "self.contains(*id) || learners[..i].contains(id)",
        ),
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
    // quorum_index's final minimum and stable early return admit no other
    // shape: the numeric-fold frontend names each rejected construct, so these
    // mutations never reach Lean (QuorumIndex.result_majority pins the rest).
    for (from, to, expected) in [
        ("new.min(old)", "new.max(old)", "expected builtin lookup min"),
        (
            "if !self.is_joint() {",
            "if self.is_joint() {",
            "numeric early return needs negated source query",
        ),
    ] {
        assert!(original.contains(from));
        fs::write(&source, original.replace(from, to)).unwrap();
        let error = provium::methods::verify(&path, &out).unwrap_err();
        assert!(error.contains(expected), "{from} -> {to}: {error}");
        assert!(!out.join("verified.json").exists());
    }
}

#[test]
fn original_learner_replacement_matches_sets_and_capacity() {
    let w = Work::new();
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let krate = Crate::load(&root.join("src/lib.rs")).unwrap();
    let mut methods = String::new();
    for name in ["with_learners", "include", "voters", "is_voter"] {
        methods.push_str(
            &krate
                .lower(&format!("membership::Membership::{name}"))
                .unwrap()
                .rust,
        );
    }
    let native = format!(
        r#"
type Id = usize;
#[derive(Clone, Copy, Debug, PartialEq)] struct Member {{id: Id, old: bool, voter: bool, learner: bool}}
#[derive(Clone, Copy, Debug, PartialEq)] struct Membership<const MAX: usize> {{members: [Option<Member>; MAX]}}
#[derive(Clone, Copy, Debug, PartialEq)] enum Error {{Config}}
impl<const MAX: usize> Membership<MAX> {{{methods}}}
fn check<const N: usize>() {{
 for code in 0..9usize.pow(N as u32) {{
  let mut digits=code;
  let original=Membership::<N> {{members:core::array::from_fn(|i|{{let d=digits%9;digits/=9;
   (d!=0).then_some(Member{{id:i%2,voter:d&1!=0,old:d&2!=0,learner:d&4!=0}})
  }})}};
  for learners in [vec![],vec![0],vec![1],vec![2],vec![2,2],vec![2,3]] {{
   let mut expected=Vec::<Member>::new();
   for member in original.members.iter().flatten().filter(|m|m.voter) {{
    if !expected.iter().any(|m|m.id==member.id) {{expected.push(Member{{id:member.id,voter:true,old:false,learner:false}});}}
   }}
   let invalid=learners.iter().enumerate().any(|(i,id)|learners[..i].contains(id) || original.members.iter().flatten().any(|m|m.id==*id && (m.voter || m.old)));
   for id in &learners {{expected.push(Member{{id:*id,voter:false,old:false,learner:true}});}}
   let before=original;
   match original.with_learners(&learners) {{
    Err(Error::Config)=>assert!(invalid || expected.len()>N),
    Ok(result)=>{{assert!(!invalid && expected.len()<=N);assert_eq!(result.members.into_iter().flatten().collect::<Vec<_>>(),expected);}}
   }}
   assert_eq!(original,before);
  }}
 }}
}}
fn main(){{check::<0>();check::<1>();check::<3>();}}
"#
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
    assert!(Command::new(binary).status().unwrap().success());
}

#[test]
fn original_joint_construction_matches_union_and_guard_priority() {
    let w = Work::new();
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let krate = Crate::load(&root.join("src/lib.rs")).unwrap();
    let mut methods = String::new();
    for name in ["joint", "include", "voters", "is_joint"] {
        methods.push_str(
            &krate
                .lower(&format!("membership::Membership::{name}"))
                .unwrap()
                .rust,
        );
    }
    let native = format!(
        r#"
type Id=usize;
#[derive(Clone,Copy,Debug,PartialEq)]struct Member{{id:Id,old:bool,voter:bool,learner:bool}}
#[derive(Clone,Copy,Debug,PartialEq)]struct Membership<const MAX:usize>{{members:[Option<Member>;MAX]}}
#[derive(Clone,Copy,Debug,PartialEq)]enum Error{{Config,Reconfiguring,Full}}
impl<const MAX:usize>Membership<MAX>{{{methods}}}
fn check<const N:usize>(){{
 for a in 0..9usize.pow(N as u32){{for b in 0..9usize.pow(N as u32){{
  let build=|mut code:usize,offset:usize|Membership::<N>{{members:core::array::from_fn(|i|{{let d=code%9;code/=9;
   (d!=0).then_some(Member{{id:i+offset,voter:d&1!=0,old:d&2!=0,learner:d&4!=0}})
  }})}};
  let source=build(a,0);let target=build(b,1);let mut expected=target;let mut error=None;
  if source.members.iter().chain(target.members.iter()).flatten().any(|m|m.old){{error=Some(Error::Reconfiguring);}}
  else{{for id in source.members.iter().flatten().filter(|m|m.voter).map(|m|m.id){{
   let slot=expected.members.iter().position(|m|m.is_some_and(|m|m.id==id)).or_else(||expected.members.iter().position(|m|m.is_none()));
   if let Some(i)=slot{{expected.members[i]=Some(Member{{old:true,..expected.members[i].unwrap_or(Member{{id,voter:false,old:false,learner:false}})}});}}
   else{{error=Some(Error::Full);break;}}
  }}}}
  match(source.joint(target),error){{(Ok(actual),None)=>assert_eq!(actual,expected),(Err(actual),Some(expected))=>assert_eq!(actual,expected),pair=>panic!("mismatch {{pair:?}}")}}
 }}}}
}}
fn main(){{check::<0>();check::<1>();check::<2>();}}
"#
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
    assert!(Command::new(binary).status().unwrap().success());
}
