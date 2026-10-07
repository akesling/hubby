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
    // `reset_election` is compiled once into the function table and called.
    for op in [
        ".invoke \"Node::reset_election\" (.read 0) (some (0, []))",
        ".assign 0 [.field \"role\"]",
        ".variant \"Role\" \"Follower\" []",
    ] {
        assert!(
            imperative.expression.contains(op),
            "missing {op}: {}",
            imperative.expression
        );
    }
    let [(name, body)] = imperative.functions.as_slice() else {
        panic!("{:?}", imperative.functions)
    };
    assert_eq!(name, "Node::reset_election");
    for op in ["wrapping_mul", "\">>\"", ".assign 0 [.field \"elapsed\"]"] {
        assert!(body.contains(op), "missing {op}: {body}");
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
            "unsupported expression",
        ),
        (
            "self.elapsed = 0;",
            "while let Some(_) = self.prevoting {}",
            "while let is unsupported",
        ),
        (
            "self.elapsed = 0;",
            "let r = &mut self.elapsed;",
            "&mut expressions are unsupported",
        ),
        (
            "self.leader = leader;",
            "self.leader = leader.map_or_else(|| None, Some);",
            "opaque method call map_or_else",
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
            "theorem native_{i} : Subject.{function} ⟨64, true, fun _ _ => .error .representation⟩ 64 ({receiver}) [{arguments}] = .ok ({value}, {after}) := by rfl\n"
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

const TABLE: &str = r#"
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Item { pub key: u64, pub live: bool }
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Fail { Empty, Full }
pub struct Table<const K: usize> { items: [Option<Item>; K], len: usize, total: u64 }
impl<const K: usize> Table<K> {
    fn keys(&self) -> impl Iterator<Item = &Item> { self.items[..self.len].iter().flatten() }
    fn find(&self, key: u64) -> Option<usize> {
        self.items.iter().position(|i| i.is_some_and(|i| i.key == key))
    }
    fn insert(&mut self, key: u64) -> Result<usize, Fail> {
        if self.len == K { return Err(Fail::Full); }
        if let Some(at) = self.find(key) { return Ok(at); }
        self.items[self.len] = Some(Item { key, live: true });
        self.len += 1;
        self.total = self.total.saturating_add(key);
        Ok(self.len - 1)
    }
    fn largest(&self) -> Result<u64, Fail> {
        let best = self.keys().filter(|i| i.live).map(|i| i.key).max().ok_or(Fail::Empty)?;
        Ok(best)
    }
    fn retire(&mut self, below: u64) -> usize {
        let mut count = 0;
        for item in &mut self.items[..self.len] {
            if item.is_some_and(|i| i.key < below) {
                *item = None;
                count += 1;
            }
        }
        count
    }
    fn summary(&self) -> (u64, usize) {
        let mut n = 0;
        let mut sum = 0u64;
        for (index, item) in self.items.iter().enumerate() {
            if index >= self.len { break; }
            if let Some(i) = item {
                if !i.live { continue; }
                sum = sum.wrapping_add(i.key);
                n += 1;
            }
        }
        (sum, n)
    }
    fn median(&mut self) -> Option<u64> {
        let mut keys = [0; K];
        let mut c = 0;
        for i in self.keys() {
            keys[c] = i.key;
            c += 1;
        }
        if c == 0 { return None; }
        keys[..c].sort_unstable();
        let (low, high) = (keys[0], keys[c - 1]);
        if (low, c) >= (high, 2) { self.total = 0; }
        Some(keys[c / 2])
    }
    fn step(&mut self, key: u64) -> Result<u64, Fail> {
        let slot = self.insert(key)?;
        let flip = |i: Option<Item>| i.map(|mut x| { x.live = !x.live; x });
        if key % 3 == 0 { self.items[slot] = flip(self.items[slot]); }
        let (sum, n) = self.summary();
        let retired = if key % 5 == 0 { self.retire(key / 2) } else { 0 };
        let median = self.median().unwrap_or(0);
        Ok(sum.wrapping_add(n as u64).wrapping_add(retired as u64).wrapping_add(median))
    }
}
"#;

#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn loops_iterators_closures_and_errors_agree_with_native_runs() {
    let w = Work::new(TABLE);
    let main = format!(
        "{TABLE}\n{}",
        r#"
fn show(t: &Table<4>) -> String {
    let item = |i: &Option<Item>| match i {
        None => ".absent".to_string(),
        Some(i) => format!("(.present (.record \"Item\" [(\"key\", .number \"u64\" {}), (\"live\", .boolean {})]))", i.key, i.live),
    };
    format!(".record \"Table\" [(\"items\", .array [{}]), (\"len\", .number \"usize\" {}), (\"total\", .number \"u64\" {})]",
        t.items.iter().map(item).collect::<Vec<_>>().join(", "), t.len, t.total)
}
fn main() {
    let mut seed = 7u64;
    for _ in 0..8 {
        let mut t = Table::<4> { items: [None; 4], len: 0, total: 0 };
        for _ in 0..7 {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            let key = (seed >> 33) % 20;
            let before = show(&t);
            let r = t.step(key);
            let result = match r {
                Ok(v) => format!(".variant \"Result\" \"Ok\" [(\"0\", .number \"u64\" {v})]"),
                Err(e) => format!(".variant \"Result\" \"Err\" [(\"0\", .variant \"Fail\" \"{e:?}\" [])]"),
            };
            println!("{before}|{key}|{result}|{}", show(&t));
        }
    }
}
"#
    );
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
    let lines = String::from_utf8(native.stdout).unwrap();
    let mut lean = String::from(
        "import Generated\nopen Provium.State Provium.Imperative\n\
         partial def same : PureValue → PureValue → Bool\n\
         | .unit, .unit => true\n\
         | .boolean a, .boolean b => a == b\n\
         | .number k a, .number l b => k == l && a == b\n\
         | .absent, .absent => true\n\
         | .present a, .present b => same a b\n\
         | .array a, .array b => a.length == b.length && (a.zip b).all (fun (x, y) => same x y)\n\
         | .record n a, .record m b => n == m && a.length == b.length && (a.zip b).all (fun (x, y) => x.1 == y.1 && same x.2 y.2)\n\
         | .variant o t a, .variant p u b => o == p && t == u && a.length == b.length && (a.zip b).all (fun (x, y) => x.1 == y.1 && same x.2 y.2)\n\
         | _, _ => false\n\
         def target : Target := ⟨64, true, fun _ _ => .error .representation⟩\n\
         def check (i : Nat) (actual : Except Fault (PureValue × PureValue)) (result after : PureValue) : IO Unit :=\n\
         match actual with\n\
         | .ok (r, a) => if same r result && same a after then IO.println s!\"DIFF ok {i}\" else IO.println s!\"DIFF mismatch {i} {repr r} {repr a}\"\n\
         | .error f => IO.println s!\"DIFF fault {i} {repr f}\"\n",
    );
    let mut count = 0;
    for (i, line) in lines.lines().enumerate() {
        let [before, key, result, after] = line.split('|').collect::<Vec<_>>()[..] else {
            panic!("{line}")
        };
        lean.push_str(&format!(
            "#eval check {i} (Subject.Table_step target 100000 ({before}) [.number \"u64\" {key}, .number \"usize\" 4]) ({result}) ({after})\n"
        ));
        count += 1;
    }
    assert_eq!(count, 56);
    fs::write(
        w.0.join("Proofs.lean"),
        "import Generated\ntheorem mentions : Subject.Table_step = Subject.Table_step := rfl\n",
    )
    .unwrap();
    let config = w.0.join("project.json");
    fs::write(&config, serde_json::to_vec(&serde_json::json!({"crate_root": "lib.rs", "namespace": "Subject", "methods": [], "imperative_methods": ["Table::step"], "proofs": "Proofs.lean", "obligations": [{"theorem": "mentions", "function": "Table_step"}]})).unwrap()).unwrap();
    let out = w.0.join("out");
    provium::methods::verify(&config, &out).unwrap();
    fs::write(out.join("Diff.lean"), lean).unwrap();
    let run = std::process::Command::new("elan")
        .args(["run", "leanprover/lean4:v4.33.1", "lean", "Diff.lean"])
        .current_dir(&out)
        .env("LEAN_PATH", &out)
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&run.stdout);
    assert!(
        run.status.success(),
        "{stdout}{}",
        String::from_utf8_lossy(&run.stderr)
    );
    let bad = stdout
        .lines()
        .filter(|l| l.starts_with("DIFF") && !l.starts_with("DIFF ok"))
        .take(3)
        .collect::<Vec<_>>();
    assert!(bad.is_empty(), "{bad:?}");
    assert_eq!(
        stdout.lines().filter(|l| l.starts_with("DIFF ok")).count(),
        count
    );
}
