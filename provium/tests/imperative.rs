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
                "imperative-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
        fs::create_dir_all(&path).unwrap();
        fs::write(path.join("lib.rs"), source).unwrap();
        Self(path)
    }
    fn lower(&self, name: &str) -> Result<provium::methods::Method, String> {
        Crate::load(&self.0.join("lib.rs"))?.lower_imperative(name)
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
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Role { Follower, Candidate, Leader }
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Id(pub u64);
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outbound { Vote, PreVote(u64) }
#[derive(Clone, Copy)]
pub struct Config { pub election_ticks: u64 }
pub struct Node<V> {
    config: Config,
    payload: Option<V>,
    role: Role,
    leader: Option<Id>,
    elapsed: u64,
    election_deadline: u64,
    random: u64,
    prevoting: Option<u64>,
    leader_age: u64,
    votes: [bool; 3],
    outbox: [Option<Outbound>; 3],
}
impl<V> Node<V> {
    fn reset_election(&mut self) {
        self.random = self.random.wrapping_add(0x9e3779b97f4a7c15);
        let mut sample = self.random;
        sample = (sample ^ (sample >> 30)).wrapping_mul(0xbf58476d1ce4e5b9);
        sample = (sample ^ (sample >> 27)).wrapping_mul(0x94d049bb133111eb);
        sample ^= sample >> 31;
        self.election_deadline = self.config.election_ticks + sample % self.config.election_ticks;
        self.elapsed = 0;
    }
    fn follow(&mut self, leader: Option<Id>) {
        self.role = Role::Follower;
        self.prevoting = None;
        if leader.is_some() {
            self.leader_age = 0;
        }
        self.leader = leader;
        self.reset_election();
    }
    fn grant(&mut self, peer: usize, term: u64) -> bool {
        if self.votes[peer] {
            return false;
        }
        self.votes[peer] = true;
        self.outbox[peer] = match self.prevoting {
            Some(t) if false => Some(Outbound::PreVote(t)),
            Some(_) => Some(Outbound::PreVote(term)),
            None => Some(Outbound::Vote),
        };
        self.leader_age += 1;
        self.role == Role::Candidate
    }
}
"#;

#[test]
fn receiver_bodies_lower_with_inlined_calls_and_reject_unsupported_rust() {
    let w = Work::new(&SOURCE.replace("Some(t) if false => Some(Outbound::PreVote(t)),\n", ""));
    let follow = w.lower("Node::follow").unwrap();
    let imperative = follow.imperative.unwrap();
    assert_eq!(imperative.parameters, 1);
    assert!(imperative.mutable_receiver);
    assert_eq!(imperative.inlined, ["Node::reset_election"]);
    for op in [
        ".scope",
        "wrapping_mul",
        "\">>\"",
        ".assign 0 [.field \"role\"]",
        ".variant \"Role\" \"Follower\" []",
    ] {
        assert!(
            imperative.expression.contains(op),
            "missing {op}: {}",
            imperative.expression
        );
    }
    let grant = w.lower("Node::grant").unwrap().imperative.unwrap();
    assert!(grant.expression.contains(".index "), "{}", grant.expression);
    // A guard would otherwise be dropped silently.
    assert!(Work::new(SOURCE)
        .lower("Node::grant")
        .unwrap_err()
        .contains("guarded"));
    for (from, to, message) in [
        (
            "self.elapsed = 0;",
            "self.elapsed = (|x: u64| x)(0);",
            "unsupported call target",
        ),
        (
            "self.elapsed = 0;",
            "for _ in 0..3 {}",
            "unsupported expression",
        ),
        (
            "self.elapsed = 0;",
            "self.payload = None;",
            "Copy is not modeled",
        ),
        (
            "self.leader = leader;",
            "self.leader = leader.map(|x| x);",
            "opaque method call map",
        ),
        ("fn follow(&mut self", "fn follow(&self", "immutable place"),
        (
            "self.elapsed = 0;",
            "let small: u8 = 256;",
            "integer literal exceeds",
        ),
    ] {
        let source = SOURCE.replace("Some(t) if false => Some(Outbound::PreVote(t)),\n", "");
        assert_eq!(source.matches(from).count(), 1, "{from}");
        let error = Work::new(&source.replace(from, to))
            .lower("Node::follow")
            .unwrap_err();
        assert!(error.contains(message), "{from} -> {to}: {error}");
    }
    let shadow = format!("{SOURCE}\ntrait Shadow {{ fn wrapping_add(self, other: u64) -> u64; }}\nimpl Shadow for u64 {{ fn wrapping_add(self, _: u64) -> u64 {{ 0 }} }}");
    let error = Work::new(&shadow.replace("Some(t) if false => Some(Outbound::PreVote(t)),\n", ""))
        .lower("Node::follow")
        .unwrap_err();
    assert!(error.contains("trait impl for u64"), "{error}");
}

fn lean_node(
    fields: &[u64],
    role: &str,
    leader: Option<u64>,
    prevoting: Option<u64>,
    votes: [bool; 3],
    outbox: [Option<Option<u64>>; 3],
) -> String {
    let id = |v: Option<u64>| {
        v.map_or(".absent".to_string(), |v| {
            format!(".present (.record \"Id\" [(\"0\", .number \"u64\" {v})])")
        })
    };
    let number = |v: Option<u64>| {
        v.map_or(".absent".to_string(), |v| {
            format!(".present (.number \"u64\" {v})")
        })
    };
    let out = |o: Option<Option<u64>>| match o {
        None => ".absent".to_string(),
        Some(None) => ".present (.variant \"Outbound\" \"Vote\" [])".to_string(),
        Some(Some(t)) => {
            format!(".present (.variant \"Outbound\" \"PreVote\" [(\"0\", .number \"u64\" {t})])")
        }
    };
    format!(
        ".record \"Node\" [(\"config\", .record \"Config\" [(\"election_ticks\", .number \"u64\" {})]), (\"payload\", .unit), (\"role\", .variant \"Role\" {role:?} []), (\"leader\", {}), (\"elapsed\", .number \"u64\" {}), (\"election_deadline\", .number \"u64\" {}), (\"random\", .number \"u64\" {}), (\"prevoting\", {}), (\"leader_age\", .number \"u64\" {}), (\"votes\", .array [{}]), (\"outbox\", .array [{}])]",
        fields[0], id(leader), fields[1], fields[2], fields[3], number(prevoting), fields[4],
        votes.iter().map(|v| format!(".boolean {v}")).collect::<Vec<_>>().join(", "),
        outbox.iter().map(|o| out(*o)).collect::<Vec<_>>().join(", ")
    )
}

#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn native_receiver_effects_are_kernel_checked() {
    let source = SOURCE.replace("Some(t) if false => Some(Outbound::PreVote(t)),\n", "");
    let w = Work::new(&source);
    // Native runs print the final receiver in the machine's value syntax.
    let mut main = format!(
        "{source}\n{}",
        r#"
fn show(n: &Node<u8>) -> String {
    let id = |v: Option<Id>| v.map_or(".absent".to_string(), |v| format!(".present (.record \"Id\" [(\"0\", .number \"u64\" {})])", v.0));
    let number = |v: Option<u64>| v.map_or(".absent".to_string(), |v| format!(".present (.number \"u64\" {v})"));
    let out = |o: Option<Outbound>| match o {
        None => ".absent".to_string(),
        Some(Outbound::Vote) => ".present (.variant \"Outbound\" \"Vote\" [])".to_string(),
        Some(Outbound::PreVote(t)) => format!(".present (.variant \"Outbound\" \"PreVote\" [(\"0\", .number \"u64\" {t})])"),
    };
    format!(
        ".record \"Node\" [(\"config\", .record \"Config\" [(\"election_ticks\", .number \"u64\" {})]), (\"payload\", .unit), (\"role\", .variant \"Role\" {:?} []), (\"leader\", {}), (\"elapsed\", .number \"u64\" {}), (\"election_deadline\", .number \"u64\" {}), (\"random\", .number \"u64\" {}), (\"prevoting\", {}), (\"leader_age\", .number \"u64\" {}), (\"votes\", .array [{}]), (\"outbox\", .array [{}])]",
        n.config.election_ticks, format!("{:?}", n.role), id(n.leader), n.elapsed, n.election_deadline, n.random, number(n.prevoting), n.leader_age,
        n.votes.iter().map(|v| format!(".boolean {v}")).collect::<Vec<_>>().join(", "),
        n.outbox.iter().map(|o| out(*o)).collect::<Vec<_>>().join(", "))
}
fn main() {
"#
    );
    let mut cases = vec![];
    for (ticks, random, role, leader, prevoting) in [
        (10u64, 0u64, "Leader", None, Some(4u64)),
        (10, u64::MAX, "Candidate", Some(3u64), None),
        (1, 0x1234_5678_9abc_def0, "Follower", Some(0), Some(0)),
        (u64::MAX / 2, 7, "Leader", None, None),
    ] {
        let fields = [ticks, 5, 9, random, 6];
        let receiver = lean_node(
            &fields,
            role,
            leader,
            prevoting,
            [false, true, false],
            [None, Some(None), None],
        );
        let native = format!(
            "Node::<u8> {{ config: Config {{ election_ticks: {ticks} }}, payload: None, role: Role::{role}, leader: {}, elapsed: 5, election_deadline: 9, random: {random}, prevoting: {}, leader_age: 6, votes: [false, true, false], outbox: [None, Some(Outbound::Vote), None] }}",
            leader.map_or("None".to_string(), |v| format!("Some(Id({v}))")),
            prevoting.map_or("None".to_string(), |v| format!("Some({v})")),
        );
        for argument in [None, Some(8u64)] {
            main.push_str(&format!(
                "{{ let mut n = {native}; n.follow({}); println!(\"{{}}\", show(&n)); }}\n",
                argument.map_or("None".to_string(), |v| format!("Some(Id({v}))"))
            ));
            cases.push((
                "Node_follow",
                receiver.clone(),
                argument.map_or(".absent".to_string(), |v| {
                    format!(".present (.record \"Id\" [(\"0\", .number \"u64\" {v})])")
                }),
                ".unit".to_string(),
            ));
        }
        for peer in [0usize, 1] {
            main.push_str(&format!(
                "{{ let mut n = {native}; let r = n.grant({peer}, 12); println!(\"{{}} {{}}\", r, show(&n)); }}\n"
            ));
            cases.push((
                "Node_grant",
                receiver.clone(),
                format!(".number \"usize\" {peer}, .number \"u64\" 12"),
                String::new(),
            ));
        }
    }
    main.push('}');
    fs::write(w.0.join("native.rs"), &main).unwrap();
    let binary = w.0.join("native");
    let compiled = std::process::Command::new("rustc")
        .args([
            "--edition=2021",
            "-C",
            "overflow-checks=yes",
            "-A",
            "dead_code",
        ])
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
    assert_eq!(results.lines().count(), cases.len());
    let mut proofs = "import Generated\nopen Provium.State\nset_option maxRecDepth 100000\nset_option maxHeartbeats 0\n".to_string();
    let mut obligations = vec![];
    for (i, ((function, receiver, arguments, value), result)) in
        cases.iter().zip(results.lines()).enumerate()
    {
        let (value, after) = if value.is_empty() {
            let (flag, after) = result.split_once(' ').unwrap();
            (format!(".boolean {flag}"), after)
        } else {
            (value.clone(), result)
        };
        proofs.push_str(&format!(
            "theorem native_{i} : Subject.{function} 64 true 64 ({receiver}) [{arguments}] = .ok ({value}, {after}) := by rfl\n"
        ));
        obligations
            .push(serde_json::json!({"theorem": format!("native_{i}"), "function": function}));
    }
    fs::write(w.0.join("Proofs.lean"), proofs).unwrap();
    let config = w.0.join("project.json");
    fs::write(&config, serde_json::to_vec(&serde_json::json!({"crate_root": "lib.rs", "namespace": "Subject", "methods": [], "imperative_methods": ["Node::follow", "Node::grant"], "proofs": "Proofs.lean", "obligations": obligations})).unwrap()).unwrap();
    provium::methods::verify(&config, &w.0.join("out")).unwrap();
    // A changed constant in the inlined helper must break the native agreement.
    fs::write(
        w.0.join("lib.rs"),
        source.replace("sample >> 31", "sample >> 30"),
    )
    .unwrap();
    let error = provium::methods::verify(&config, &w.0.join("out")).unwrap_err();
    assert!(error.contains("Lean rejected Proofs.lean"), "{error}");
    assert!(!w.0.join("out/verified.json").exists());
}
