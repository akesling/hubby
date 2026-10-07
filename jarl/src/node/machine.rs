//! Differential check of Provium's imperative lowering of `Node::tick` and
//! `Node::step`: native runs over random three-node schedules are compared
//! with Lean's evaluation of the generated machine programs on the same
//! serialized states and inputs. A test, not a proof: it catches frontend
//! lowering defects the proofs would otherwise silently inherit. Only the fixed
//! engine is exercised: the dynamic engine's membership hooks are function
//! pointers, which the machine hands to its oracle and this test cannot run.
use super::*;
use std::{format, fs, path::Path, process::Command, string::{String, ToString}, vec, vec::Vec};

/// The machine's value syntax for a Rust value, field by field in
/// declaration order.
trait Value {
    fn value(&self) -> String;
}

fn record(name: &str, fields: &[(&str, String)]) -> String {
    let fields = fields
        .iter()
        .map(|(n, v)| format!("(\"{n}\", {v})"))
        .collect::<Vec<_>>();
    format!(".record \"{name}\" [{}]", fields.join(", "))
}
fn variant(owner: &str, tag: &str, fields: &[(&str, String)]) -> String {
    let fields = fields
        .iter()
        .map(|(n, v)| format!("(\"{n}\", {v})"))
        .collect::<Vec<_>>();
    format!(".variant \"{owner}\" \"{tag}\" [{}]", fields.join(", "))
}

impl Value for u64 {
    fn value(&self) -> String {
        format!("(.number \"u64\" {self})")
    }
}
impl Value for usize {
    fn value(&self) -> String {
        format!("(.number \"usize\" {self})")
    }
}
impl Value for bool {
    fn value(&self) -> String {
        format!("(.boolean {self})")
    }
}
impl Value for () {
    fn value(&self) -> String {
        ".unit".into()
    }
}
impl<T: Value> Value for Option<T> {
    fn value(&self) -> String {
        match self {
            None => ".absent".into(),
            Some(v) => format!("(.present ({}))", v.value()),
        }
    }
}
impl<T: Value, const K: usize> Value for [T; K] {
    fn value(&self) -> String {
        let items = self.iter().map(Value::value).collect::<Vec<_>>();
        format!("(.array [{}])", items.join(", "))
    }
}
impl<A: Value, B: Value> Value for (A, B) {
    fn value(&self) -> String {
        record("()", &[("0", self.0.value()), ("1", self.1.value())])
    }
}
impl Value for Id {
    fn value(&self) -> String {
        record("Id", &[("0", self.0.value())])
    }
}
impl Value for LogId {
    fn value(&self) -> String {
        record(
            "LogId",
            &[("index", self.index.value()), ("term", self.term.value())],
        )
    }
}
impl<V: Value> Value for Entry<V> {
    fn value(&self) -> String {
        record("Entry", &[("id", self.id.value()), ("value", self.value.value())])
    }
}
impl<S: Value> Value for Snapshot<S> {
    fn value(&self) -> String {
        record(
            "Snapshot",
            &[("last", self.last.value()), ("value", self.value.value())],
        )
    }
}
impl Value for Role {
    fn value(&self) -> String {
        variant("Role", &format!("{self:?}"), &[])
    }
}
impl Value for Rejection {
    fn value(&self) -> String {
        match self {
            Rejection::Conflict { next } => variant("Rejection", "Conflict", &[("next", next.value())]),
            Rejection::Full => variant("Rejection", "Full", &[]),
        }
    }
}
impl Value for Error {
    fn value(&self) -> String {
        match self {
            Error::NotLeader(id) => variant("Error", "NotLeader", &[("0", id.value())]),
            other => variant("Error", &format!("{other:?}"), &[]),
        }
    }
}
impl Value for Outbound {
    fn value(&self) -> String {
        match self {
            Outbound::PreVote(t) => variant("Outbound", "PreVote", &[("0", t.value())]),
            Outbound::PreVoted(t, g) => {
                variant("Outbound", "PreVoted", &[("0", t.value()), ("1", g.value())])
            }
            Outbound::Vote => variant("Outbound", "Vote", &[]),
            Outbound::Voted(g) => variant("Outbound", "Voted", &[("0", g.value())]),
            Outbound::Replicate => variant("Outbound", "Replicate", &[]),
            Outbound::Replicated(i, r) => {
                variant("Outbound", "Replicated", &[("0", i.value()), ("1", r.value())])
            }
        }
    }
}
impl Value for crate::state::HardState {
    fn value(&self) -> String {
        record(
            "HardState",
            &[
                ("term", self.term.value()),
                ("voted_for", self.voted_for.value()),
                ("commit", self.commit.value()),
            ],
        )
    }
}
impl<V: Value, S: Value, const CAP: usize> Value for State<V, S, CAP> {
    fn value(&self) -> String {
        let (hard, snapshot, entries, len) = self.parts();
        record(
            "State",
            &[
                ("hard", hard.value()),
                ("snapshot", snapshot.value()),
                ("entries", entries.value()),
                ("len", len.value()),
            ],
        )
    }
}
impl<const MAX: usize> Value for Membership<MAX> {
    fn value(&self) -> String {
        let members = self.members().map(|m| {
            m.map(|(id, voter, old, learner)| {
                record(
                    "Member",
                    &[
                        ("id", id.value()),
                        ("voter", voter.value()),
                        ("old", old.value()),
                        ("learner", learner.value()),
                    ],
                )
            })
        });
        let items = members
            .iter()
            .map(|m| m.as_ref().map_or(".absent".into(), |r| format!("(.present ({r}))")))
            .collect::<Vec<String>>();
        record("Membership", &[("members", format!("(.array [{}])", items.join(", ")))])
    }
}
impl<const N: usize> Value for Config<N> {
    fn value(&self) -> String {
        record(
            "Config",
            &[
                ("id", self.id.value()),
                ("members", self.members.value()),
                ("heartbeat_ticks", self.heartbeat_ticks.value()),
                ("election_ticks", self.election_ticks.value()),
                ("seed", self.seed.value()),
            ],
        )
    }
}
impl<V, S, const N: usize> Value for MembershipHooks<V, S, N> {
    fn value(&self) -> String {
        panic!("the fixed engine has no membership hooks")
    }
}
impl<V: Value, S: Value> Value for Message<V, S> {
    fn value(&self) -> String {
        match self {
            Message::PreVote { term, last } => variant(
                "Message",
                "PreVote",
                &[("term", term.value()), ("last", last.value())],
            ),
            Message::PreVoted {
                term,
                campaign,
                granted,
            } => variant(
                "Message",
                "PreVoted",
                &[
                    ("term", term.value()),
                    ("campaign", campaign.value()),
                    ("granted", granted.value()),
                ],
            ),
            Message::Vote { term, last } => variant(
                "Message",
                "Vote",
                &[("term", term.value()), ("last", last.value())],
            ),
            Message::Voted { term, granted } => variant(
                "Message",
                "Voted",
                &[("term", term.value()), ("granted", granted.value())],
            ),
            Message::Append {
                term,
                previous,
                entry,
                commit,
            } => variant(
                "Message",
                "Append",
                &[
                    ("term", term.value()),
                    ("previous", previous.value()),
                    ("entry", entry.value()),
                    ("commit", commit.value()),
                ],
            ),
            Message::AppendBatch {
                term,
                previous,
                entries,
                commit,
            } => variant(
                "Message",
                "AppendBatch",
                &[
                    ("term", term.value()),
                    ("previous", previous.value()),
                    ("entries", entries.value()),
                    ("commit", commit.value()),
                ],
            ),
            Message::Install { term, snapshot } => variant(
                "Message",
                "Install",
                &[("term", term.value()), ("snapshot", snapshot.value())],
            ),
            Message::Replicated {
                term,
                index,
                rejection,
            } => variant(
                "Message",
                "Replicated",
                &[
                    ("term", term.value()),
                    ("index", index.value()),
                    ("rejection", rejection.value()),
                ],
            ),
        }
    }
}
impl<V: Value, S: Value> Value for Envelope<V, S> {
    fn value(&self) -> String {
        record(
            "Envelope",
            &[
                ("from", self.from.value()),
                ("to", self.to.value()),
                ("message", self.message.value()),
            ],
        )
    }
}
impl<V: Value, S: Value, const N: usize, const CAP: usize> Value for Node<V, S, N, CAP> {
    fn value(&self) -> String {
        record(
            "Node",
            &[
                ("config", self.config.value()),
                ("state", self.state.value()),
                ("role", self.role.value()),
                ("leader", self.leader.value()),
                ("local", self.local.value()),
                ("membership", self.membership.value()),
                ("bootstrap", self.bootstrap.value()),
                ("hooks", self.hooks.value()),
                ("peers", self.peers.value()),
                ("votes", self.votes.value()),
                ("next", self.next.value()),
                ("matched", self.matched.value()),
                ("outbox", self.outbox.value()),
                ("dirty", self.dirty.value()),
                ("log_from", self.log_from.value()),
                ("snapshot_changed", self.snapshot_changed.value()),
                ("elapsed", self.elapsed.value()),
                ("election_deadline", self.election_deadline.value()),
                ("random", self.random.value()),
                ("prevoting", self.prevoting.value()),
                ("leader_age", self.leader_age.value()),
                ("quorum_elapsed", self.quorum_elapsed.value()),
                ("active", self.active.value()),
                ("extra_reply", self.extra_reply.value()),
                ("request_from", self.request_from.value()),
            ],
        )
    }
}
fn result(r: &Result<(), Error>) -> String {
    match r {
        Ok(()) => variant("Result", "Ok", &[("0", ".unit".into())]),
        Err(e) => variant("Result", "Err", &[("0", e.value())]),
    }
}

/// One recorded call: generated function, receiver before, arguments, and
/// the native result and receiver after.
struct Case {
    function: &'static str,
    before: String,
    arguments: String,
    result: String,
    after: String,
}

type TestNode = Node<u64, (), 3, 4>;

/// A small linear congruential generator, so schedules are reproducible.
struct Random(u64);
impl Random {
    fn below(&mut self, n: usize) -> usize {
        self.0 = self
            .0
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        ((self.0 >> 33) % n as u64) as usize
    }
}

fn schedules(count: usize) -> Vec<Case> {
    let config = |i: usize| Config::new(Id(i as u64), [Id(0), Id(1), Id(2)]);
    let mut cases = vec![];
    for seed in 0..count as u64 {
        let mut random = Random(seed);
        let mut nodes: Vec<TestNode> = (0..3)
            .map(|i| Node::new(config(i), State::new()).unwrap())
            .collect();
        let mut network: Vec<Envelope<u64, ()>> = vec![];
        let mut disk: Vec<State<u64, (), 4>> = (0..3).map(|_| State::new()).collect();
        for _ in 0..240 {
            let i = random.below(3);
            match random.below(8) {
                0 | 1 => {
                    let before = nodes[i].value();
                    let r = nodes[i].tick();
                    cases.push(Case {
                        function: "node_Node_tick",
                        before,
                        arguments: String::new(),
                        result: result(&r),
                        after: nodes[i].value(),
                    });
                }
                2 | 3 if !network.is_empty() => {
                    let message = network.remove(random.below(network.len()));
                    let to = message.to.0 as usize;
                    let before = nodes[to].value();
                    let r = nodes[to].step(&message);
                    cases.push(Case {
                        function: "node_Node_step",
                        before,
                        arguments: message.value(),
                        result: result(&r),
                        after: nodes[to].value(),
                    });
                }
                4 => {
                    if let Some(ready) = nodes[i].ready() {
                        disk[i] = ready.state().clone();
                        ready.persisted();
                    }
                }
                5 if !network.is_empty() => {
                    network.remove(random.below(network.len()));
                }
                6 if random.below(4) == 0 => {
                    nodes[i] = Node::new(config(i), disk[i].clone()).unwrap();
                }
                _ => {
                    if nodes[i].role() == Role::Leader && nodes[i].ready().is_none() {
                        let _ = nodes[i].propose(&(seed * 100 + random.below(50) as u64));
                    }
                }
            }
            for node in nodes.iter_mut() {
                while let Some(message) = node.next_message() {
                    network.push(message.cloned());
                }
            }
        }
    }
    cases
}

#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn generated_tick_and_step_agree_with_native_runs() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let work = root.join("artifacts").join(format!("machine-{}", std::process::id()));
    let _ = fs::remove_dir_all(&work);
    fs::create_dir_all(&work).unwrap();
    let project = serde_json::json!({
        "cargo_build": root.join("proofs/builds.json"),
        "crate_root": root.join("src/lib.rs"),
        "namespace": "Jarl",
        "methods": [],
        "imperative_methods": ["node::Node::tick", "node::Node::step"],
        "proofs": "Proofs.lean",
        "obligations": [
            {"theorem": "Diff.tick", "function": "node_Node_tick"},
            {"theorem": "Diff.step", "function": "node_Node_step"}
        ]
    });
    fs::write(work.join("project.json"), project.to_string()).unwrap();
    fs::write(
        work.join("Proofs.lean"),
        "import Generated\nnamespace Diff\ntheorem tick : Jarl.node_Node_tick = Jarl.node_Node_tick := rfl\ntheorem step : Jarl.node_Node_step = Jarl.node_Node_step := rfl\nend Diff\n",
    )
    .unwrap();
    let out = work.join("out");
    provium::methods::verify(&work.join("project.json"), &out).unwrap();
    let cases = schedules(12);
    assert!(cases.len() > 200, "{}", cases.len());
    // The schedules must exercise every fixed-engine message kind, failed
    // calls, and elections that a leader wins.
    for kind in ["\"Vote\"", "\"Voted\"", "\"Append\"", "\"Replicated\""] {
        let n = cases.iter().filter(|c| c.arguments.contains(kind)).count();
        assert!(n >= 5, "{kind}: {n}");
    }
    assert!(cases.iter().any(|c| c.result.contains("\"Err\"")));
    assert!(cases.iter().any(|c| c.after.contains("\"Leader\"")));
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
         def target : Target := ⟨64, true, fun name arguments => match name, arguments with\n\
         | \"clone\", [v] => .ok v\n\
         | _, _ => .error .representation⟩\n\
         def check (i : Nat) (actual : Except Fault (PureValue × PureValue)) (result after : PureValue) : IO Unit :=\n\
         match actual with\n\
         | .ok (r, a) => if same r result && same a after then IO.println s!\"PROVIUM_DIFF ok {i}\" else IO.println s!\"PROVIUM_DIFF mismatch {i} {repr r} {repr a}\"\n\
         | .error f => IO.println s!\"PROVIUM_DIFF fault {i} {repr f}\"\n",
    );
    for (i, c) in cases.iter().enumerate() {
        // Impl const parameters N and CAP follow the ordinary arguments.
        let constants = "(.number \"usize\" 3), (.number \"usize\" 4)";
        let arguments = if c.arguments.is_empty() {
            constants.to_string()
        } else {
            format!("({}), {constants}", c.arguments)
        };
        lean.push_str(&format!(
            "#eval check {i} (Jarl.{} target 100000 ({}) [{arguments}]) ({}) ({})\n",
            c.function, c.before, c.result, c.after
        ));
    }
    fs::write(out.join("Diff.lean"), lean).unwrap();
    let run = Command::new("elan")
        .args(["run", "leanprover/lean4:v4.33.1", "lean", "Diff.lean"])
        .current_dir(&out)
        .env("LEAN_PATH", &out)
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&run.stdout);
    assert!(
        run.status.success(),
        "{}{}",
        stdout,
        String::from_utf8_lossy(&run.stderr)
    );
    let ok = stdout.lines().filter(|l| l.starts_with("PROVIUM_DIFF ok")).count();
    let bad = stdout
        .lines()
        .filter(|l| l.starts_with("PROVIUM_DIFF") && !l.starts_with("PROVIUM_DIFF ok"))
        .take(3)
        .collect::<Vec<_>>();
    assert!(bad.is_empty(), "{} of {} differ: {bad:?}", cases.len() - ok, cases.len());
    assert_eq!(ok, cases.len());
    let _ = fs::remove_dir_all(&work);
}
