//! Negative controls for the typed engine project (`proofs/engine`): each
//! source mutation must be rejected by a named proof module, never by the
//! front end, Cargo or `Generated.lean`.
//!
//! The contract controls are ported from the deep-embedding projects'
//! negative controls (storage, storage-view, message-validation,
//! replication-contract, log-boundary, capacity, initialization,
//! input-gating, persistence, election, node-election, message-dispatch,
//! membership and consensus). They run against the `Contracts/*` modules
//! alone, so the contract that replaced each old project is the one that
//! rejects the mutation; the `Engine/*` modules, checked first in the full
//! project, would otherwise reject most of them earlier through their
//! relational specifications. The engine controls run the full project and
//! must be rejected by an `Engine/*` module.
use super::Work;
use std::{
    fs,
    path::{Path, PathBuf},
};

fn copy_sources(from: &Path, to: &Path) {
    fs::create_dir_all(to).unwrap();
    for entry in fs::read_dir(from).unwrap() {
        let entry = entry.unwrap();
        let destination = to.join(entry.file_name());
        if entry.file_type().unwrap().is_dir() {
            copy_sources(&entry.path(), &destination);
        } else {
            fs::copy(entry.path(), destination).unwrap();
        }
    }
}

/// A copy of the crate, built by Cargo, with the engine project pointed at it
/// and at the original proofs. The differential scenario is omitted: it is
/// not the control under test, and every proof module is checked before it.
struct Subject {
    work: Work,
    project: serde_json::Value,
    config: PathBuf,
}

impl Subject {
    /// The full engine project.
    fn engine() -> Self {
        Self::new(false)
    }

    /// Only the contract modules, their obligations, and `Engine.Log`, which
    /// `Contracts.Storage` imports and which is checked just before it.
    fn contracts() -> Self {
        Self::new(true)
    }

    fn new(contracts_only: bool) -> Self {
        let root = Path::new(env!("CARGO_MANIFEST_DIR"));
        let proofs = root.join("proofs/engine");
        let work = Work::new();
        copy_sources(&root.join("src"), &work.0.join("src"));
        fs::copy(root.join("README.md"), work.0.join("README.md")).unwrap();
        let mut project: serde_json::Value =
            serde_json::from_slice(&fs::read(proofs.join("project.json")).unwrap()).unwrap();
        project.as_object_mut().unwrap().remove("differential");
        project["crate_root"] = "src/lib.rs".into();
        work.cargo_build();
        project["cargo_build"] = "build.json".into();
        project["proofs"] = proofs.join("Proofs.lean").to_str().unwrap().into();
        for module in project["proof_modules"].as_array_mut().unwrap() {
            module["path"] = proofs
                .join(module["path"].as_str().unwrap())
                .to_str()
                .unwrap()
                .into();
        }
        if contracts_only {
            let modules = project["proof_modules"].as_array_mut().unwrap();
            let log = modules
                .iter()
                .position(|m| m["name"] == "Engine.Log")
                .unwrap();
            let log = modules.remove(log);
            modules.retain(|m| m["name"].as_str().unwrap().starts_with("Contracts."));
            let storage = modules
                .iter()
                .position(|m| m["name"] == "Contracts.Storage")
                .unwrap();
            modules.insert(storage, log);
            let mut proofs = String::from("import Generated\n");
            for module in modules.iter() {
                proofs.push_str(&format!("import {}\n", module["name"].as_str().unwrap()));
            }
            project["proofs"] = work.write("Proofs.lean", &proofs).to_str().unwrap().into();
            project["obligations"]
                .as_array_mut()
                .unwrap()
                .retain(|o| !o["theorem"].as_str().unwrap().starts_with("Jarl.Engine."));
        }
        let config = work.write("project.json", &project.to_string());
        // Control: the copied, unmutated crate must verify, or a fixture-level
        // failure would satisfy every mutation below.
        provium::typed::verify::verify(&config, &work.out()).unwrap();
        Self {
            work,
            project,
            config,
        }
    }

    /// Apply each `(from, to, module)` replacement to `file` (relative to the
    /// work directory) on its own, and require that verification fails
    /// because Lean rejected `module`.
    fn reject(&self, file: &Path, mutations: &[(&str, &str, &str)]) {
        let original = fs::read_to_string(file).unwrap();
        let out = self.work.out();
        let mut unexpected = Vec::new();
        for (from, to, module) in mutations {
            assert_eq!(original.matches(from).count(), 1, "{from}");
            fs::write(file, original.replacen(from, to, 1)).unwrap();
            let result = provium::typed::verify::verify(&self.config, &out);
            assert_eq!(result.is_ok(), out.join("verified.json").exists());
            let rejected = match &result {
                Ok(_) => "verified".to_owned(),
                Err(error) => match error.split_once("Lean rejected ") {
                    Some((_, rest)) => rest.split(" (").next().unwrap().to_owned(),
                    None => error.chars().take(400).collect(),
                },
            };
            println!("{from:?} -> {to:?}: {rejected}");
            if rejected != *module {
                unexpected.push(format!(
                    "{from:?} -> {to:?}: expected {module}, got {rejected}"
                ));
            }
        }
        fs::write(file, original).unwrap();
        assert!(unexpected.is_empty(), "{}", unexpected.join("\n"));
    }

    fn source(&self, name: &str) -> PathBuf {
        self.work.0.join("src").join(name)
    }

    /// Point the project at a private copy of one proof module, for
    /// mutations of the model it states its contract against.
    fn module_copy(&mut self, name: &str) -> PathBuf {
        let modules = self.project["proof_modules"].as_array_mut().unwrap();
        let module = modules.iter_mut().find(|m| m["name"] == name).unwrap();
        let copy = self.work.0.join(format!("{name}.lean"));
        fs::copy(module["path"].as_str().unwrap(), &copy).unwrap();
        module["path"] = copy.to_str().unwrap().into();
        fs::write(&self.config, self.project.to_string()).unwrap();
        copy
    }
}

const STORAGE: &str = "Contracts/Storage.lean";
/// `Engine.Log` states push, truncate and install exactly; `Contracts.Storage`
/// imports it, so it is checked first.
const BASE: &str = "Contracts/MembershipBase.lean";
const INCLUDE: &str = "Contracts/MembershipInclude.lean";
const SPEC: &str = "Contracts/MembershipSpec.lean";
const QUORUM: &str = "Contracts/MembershipQuorum.lean";
const LOG: &str = "Engine/Log.lean";
const BOUNDARY: &str = "Contracts/LogBoundary.lean";
const VIEW: &str = "Contracts/StorageView.lean";

#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn state_restoration_and_buffer_mutations_break_storage_contracts() {
    let subject = Subject::contracts();
    subject.reject(
        &subject.source("state.rs"),
        &[
            // proof_cases/storage.rs
            (
                "last.index.checked_add(1)",
                "last.index.checked_add(2)",
                STORAGE,
            ),
            ("entry.id.term == 0", "false", STORAGE),
            ("entry.id.term < last.term", "false", STORAGE),
            ("entry.id.term > hard.term", "false", STORAGE),
            ("base.term > hard.term", "false", STORAGE),
            (
                "hard.term == 0 && hard.voted_for.is_some()",
                "false",
                STORAGE,
            ),
            ("base.index == 0 || base.term == 0", "false", STORAGE),
            ("hard.commit < base.index", "false", STORAGE),
            ("hard.commit > state.last().index", "false", STORAGE),
            // Strengthened guards reject valid checkpoints.
            (
                "entry.id.term < last.term",
                "entry.id.term <= last.term",
                STORAGE,
            ),
            ("base.term > hard.term", "base.term >= hard.term", STORAGE),
            (
                "hard.commit > state.last().index",
                "hard.commit >= state.last().index",
                STORAGE,
            ),
            ("self.len += 1;", "self.len += 2;", LOG),
            // Also proof_cases/capacity.rs.
            (
                "self.len == CAP",
                "self.len != CAP",
                "Contracts/Capacity.lean",
            ),
            ("if i < self.len", "if i <= self.len", STORAGE),
            ("NEW >= CAP", "NEW <= CAP", STORAGE),
            // `rotate_right(remove)` in the old control; the typed front end does
            // not translate `rotate_right`, so rotate left by the complement.
            ("rotate_left(remove)", "rotate_left(self.len - remove)", LOG),
            (
                ".max(snapshot.last.index)",
                ".min(snapshot.last.index)",
                LOG,
            ),
            ("== Some(snapshot.last)", "!= Some(snapshot.last)", LOG),
            // Also proof_cases/replication_contract.rs.
            ("self.last().index >= from", "self.last().index > from", LOG),
            ("self.last().index >= from", "self.last().term >= from", LOG),
            // proof_cases/initialization.rs
            ("len: 0,", "len: 1,", "Contracts/Initialization.lean"),
        ],
    );
}

#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn state_lookup_and_view_mutations_break_boundary_and_view_contracts() {
    let subject = Subject::contracts();
    subject.reject(
        &subject.source("state.rs"),
        &[
            // proof_cases/boundary.rs (the first also replication_contract.rs)
            ("checked_sub(1)?;", "checked_sub(0)?;", BOUNDARY),
            // Panics on a full buffer, which `LogBoundary.iterator_exact`
            // excludes. (This control found that the typed front end once
            // translated `[..=len]` as `[..len]`.)
            (
                "self.entries[..self.len].iter().flatten()",
                "self.entries[..=self.len].iter().flatten()",
                BOUNDARY,
            ),
            (
                "self.entries().next_back()",
                "self.entries().next()",
                BOUNDARY,
            ),
            (
                "index == self.base().index",
                "index != self.base().index",
                BOUNDARY,
            ),
            (
                "self.base().index)?.checked_sub",
                "self.base().term)?.checked_sub",
                BOUNDARY,
            ),
            // proof_cases/storage_view.rs
            (".saturating_sub(1)", ".saturating_sub(0)", VIEW),
            (
                "filter(|_| snapshot_changed)",
                "filter(|_| !snapshot_changed)",
                VIEW,
            ),
            ("truncate_from: from,", "truncate_from: None,", VIEW),
        ],
    );
}

#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn ready_mutations_break_persistence_and_view_contracts() {
    let subject = Subject::contracts();
    subject.reject(
        &subject.source("ready.rs"),
        &[
            // proof_cases/storage_view.rs
            (
                "self.entries.iter().flatten()",
                "self.entries.iter().flatten().rev()",
                VIEW,
            ),
            // proof_cases/methods.rs. `Contracts.InputGating` composes the
            // acknowledgment with the input gate and is checked before
            // `Contracts.Persistence`.
            (
                "self.node.dirty = false;",
                "self.node.dirty = true;",
                "Contracts/InputGating.lean",
            ),
        ],
    );
}

#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn message_term_mutation_breaks_the_dispatch_contract() {
    let subject = Subject::contracts();
    // proof_cases/message_dispatch.rs
    subject.reject(
        &subject.source("lib.rs"),
        &[(
            "Self::PreVoted { term, .. }",
            "Self::PreVoted { campaign: term, .. }",
            "Contracts/MessageDispatch.lean",
        )],
    );
}

#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn node_mutations_break_validation_gating_and_election_contracts() {
    let subject = Subject::contracts();
    let validation = "Contracts/MessageValidation.lean";
    let gating = "Contracts/InputGating.lean";
    let node_election = "Contracts/NodeElection.lean";
    let consensus = "Contracts/Consensus.lean";
    subject.reject(
        &subject.source("node.rs"),
        &[
            // proof_cases/message_validation.rs
            ("if ended\n", "if false\n", validation),
            (
                "snapshot.last.index > 0 && valid_id(snapshot.last)",
                "snapshot.last.index >= 0 && valid_id(snapshot.last)",
                validation,
            ),
            ("return *campaign > 0;", "return *campaign >= 0;", validation),
            (
                "previous.index.checked_add(1) != Some(entry.id.index)",
                "false",
                validation,
            ),
            ("count += 1;", "count += 0;", validation),
            // proof_cases/queries.rs: each missing input gate.
            (
                "self.dirty || self.extra_reply.is_some() || self.outbox.iter().any(Option::is_some)",
                "self.extra_reply.is_some() || self.outbox.iter().any(Option::is_some)",
                gating,
            ),
            (
                "self.dirty || self.extra_reply.is_some() || self.outbox.iter().any(Option::is_some)",
                "self.dirty || self.outbox.iter().any(Option::is_some)",
                gating,
            ),
            (
                "self.dirty || self.extra_reply.is_some() || self.outbox.iter().any(Option::is_some)",
                "self.dirty || self.extra_reply.is_some()",
                gating,
            ),
            // proof_cases/scalar_methods.rs: the election timer reset.
            // `Contracts.Election` imports `Contracts.NodeElection`, which
            // states the same body and is checked first.
            (
                "% self.config.election_ticks;\n        self.elapsed = 0;",
                "% self.config.election_ticks;\n        self.elapsed = 1;",
                node_election,
            ),
            (
                "sample % self.config.election_ticks",
                "sample / self.config.election_ticks",
                node_election,
            ),
            (
                "% self.config.election_ticks;\n        self.elapsed = 0;",
                "% self.config.election_ticks;\n        self.elapsed = 0; self.election_deadline = 0;",
                node_election,
            ),
            // proof_cases/lean.rs (consensus), the source replaced both
            // `commit.min(matched)`; the follower's final commit here.
            (
                "self.commit_to(commit.min(matched));\n        (matched, None)",
                "self.commit_to(commit.max(matched));\n        (matched, None)",
                consensus,
            ),
            (
                "id.term == self.state.hard.term",
                "id.term != self.state.hard.term",
                consensus,
            ),
            (
                "self.state.hard.commit = index;",
                "self.state.hard.commit = 0;",
                consensus,
            ),
            // proof_cases/node_election.rs
            (
                "        self.role = Role::Follower;\n        self.prevoting = None;\n        if leader",
                "        self.role = Role::Candidate;\n        self.prevoting = None;\n        if leader",
                node_election,
            ),
            (
                "        self.prevoting = None;\n        if leader.is_some()",
                "        if leader.is_some()",
                node_election,
            ),
            ("self.leader_age = 0;", "self.leader_age = 1;", node_election),
            ("if leader.is_some() {", "if leader.is_none() {", node_election),
            ("self.leader = leader;", "self.leader = None;", node_election),
            ("sample ^= sample >> 31;", "sample ^= sample >> 30;", node_election),
            (
                "self.config.election_ticks + sample % self.config.election_ticks",
                "self.config.election_ticks + sample % (self.config.election_ticks + 1)",
                node_election,
            ),
        ],
    );
}

#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn storage_delta_model_mutations_break_the_view_contract() {
    let mut subject = Subject::contracts();
    // proof_cases/storage_view.rs: the host-order model the view is proved
    // against, rather than the Rust source.
    let model = subject.module_copy("Contracts.StorageView");
    subject.reject(
        &model,
        &[
            (
                "boundary snapshot < index entry",
                "boundary snapshot <= index entry",
                VIEW,
            ),
            ("index entry < cut", "index entry <= cut", VIEW),
            ("| some snapshot => some snapshot", "| some _ => old", VIEW),
        ],
    );
}

#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn raft_bugs_break_engine_safety() {
    let subject = Subject::engine();
    subject.reject(
        &subject.source("node.rs"),
        &[
            // Grant a vote without the up-to-date log check.
            (
                "is_none_or(|id| id == envelope.from)\n                    && (last.term, last.index) >= (ours.term, ours.index)",
                "is_none_or(|id| id == envelope.from)",
                "Engine/Step.lean",
            ),
            // Compare logs by length before term.
            (
                "is_none_or(|id| id == envelope.from)\n                    && (last.term, last.index) >= (ours.term, ours.index)",
                "is_none_or(|id| id == envelope.from)\n                    && (last.index, last.term) >= (ours.index, ours.term)",
                "Engine/Step.lean",
            ),
            // Vote for a second candidate in the same term.
            (
                "is_none_or(|id| id == envelope.from)",
                "is_none_or(|_| true)",
                "Engine/Step.lean",
            ),
            // Count a rejected vote.
            (
                "if self.role == Role::Candidate && *granted {",
                "if self.role == Role::Candidate {",
                "Engine/Step.lean",
            ),
            // Win an election without a quorum of votes.
            (
                "if self.election_quorum() {\n                        self.become_leader();",
                "if true {\n                        self.become_leader();",
                "Engine/Step.lean",
            ),
            // Keep leading after observing a higher term.
            (
                "self.state.hard.voted_for = None;\n            self.dirty = true;\n            self.follow(None);",
                "self.state.hard.voted_for = None;\n            self.dirty = true;",
                "Engine/Step.lean",
            ),
            // Count votes from an earlier term's election.
            (
                "if term < self.state.hard.term {",
                "if term < self.state.hard.term && !matches!(envelope.message, Message::Voted { .. }) {",
                "Engine/Step.lean",
            ),
            // Follow and append from a deposed leader's stale-term Append.
            (
                "if term < self.state.hard.term {",
                "if term < self.state.hard.term && !matches!(envelope.message, Message::Append { .. }) {",
                "Engine/Step.lean",
            ),
            // Append consistency check on the index alone, ignoring its term.
            (
                "if self.state.id_at(previous.index) != Some(previous) {",
                "if self.state.id_at(previous.index).map(|id| id.index) != Some(previous.index) {",
                "Engine/Append.lean",
            ),
            // Off by one at the truncation boundary: keep the conflicting entry.
            (
                "self.state.truncate(entry.id.index);",
                "self.state.truncate(entry.id.index + 1);",
                "Engine/Append.lean",
            ),
            // Follower commit beyond the prefix the Append verified.
            (
                "self.commit_to(commit.min(matched));\n        (matched, None)",
                "self.commit_to(commit);\n        (matched, None)",
                "Engine/Append.lean",
            ),
            // proof_cases/lean.rs (consensus): the same, through `max`.
            (
                "self.commit_to(commit.min(matched));\n        (matched, None)",
                "self.commit_to(commit.max(matched));\n        (matched, None)",
                "Engine/Append.lean",
            ),
            // Commit an earlier term's entry by quorum alone.
            (
                ".is_some_and(|id| id.term == self.state.hard.term)",
                ".is_some()",
                "Engine/NodeOps.lean",
            ),
            // proof_cases/lean.rs (consensus).
            (
                "id.term == self.state.hard.term",
                "id.term != self.state.hard.term",
                "Engine/NodeOps.lean",
            ),
            // proof_cases/lean.rs (consensus): lose the committed index.
            (
                "self.state.hard.commit = index;",
                "self.state.hard.commit = 0;",
                "Engine/NodeOps.lean",
            ),
            // Leader commits its own log without a quorum.
            (
                "let index = self.membership.quorum_index(|id| self.matched(id));",
                "let index = self.state.last().index;",
                "Engine/NodeOps.lean",
            ),
            // Leader records more than the follower acknowledged.
            (
                "self.matched[peer] = index;",
                "self.matched[peer] = self.state.last().index;",
                "Engine/Replicated.lean",
            ),
            // Leader proposes entries under an earlier term.
            (
                "term: self.state.hard.term,\n        };\n        let mut rollback",
                "term: self.state.hard.term.saturating_sub(1),\n        };\n        let mut rollback",
                "Engine/Host.lean",
            ),
            // Compact past the commit index.
            (
                "index <= self.state.base().index || index > self.state.hard.commit",
                "index <= self.state.base().index",
                "Engine/Host.lean",
            ),
            // A snapshot replaces conflicting committed history.
            (
                "|| self.state.id_at(snapshot.last.index) == Some(snapshot.last))",
                "|| true)",
                "Engine/Step.lean",
            ),
        ],
    );
    subject.reject(
        &subject.source("membership.rs"),
        &[
            // Commit at the highest match instead of a majority's.
            (
                "let new = positions[count - (count / 2 + 1)];",
                "let new = positions[count - 1];",
                "Engine/Fixed.lean",
            ),
        ],
    );
}

#[test]
#[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
fn membership_mutations_break_membership_and_consensus_contracts() {
    let subject = Subject::contracts();
    subject.reject(
        &subject.source("membership.rs"),
        &[
            // proof_cases/arrays.rs (the first replaced both majority sizes).
            (
                "let new = positions[count - (count / 2 + 1)];",
                "let new = positions[count - (count / 3 + 1)];",
                QUORUM,
            ),
            (
                "for id in self.old_voters()",
                "for id in self.voters()",
                QUORUM,
            ),
            // Also proof_cases/lean.rs (consensus): half the voters elect a leader.
            ("count > total / 2", "count >= total / 2", QUORUM),
            ("count > total / 2", "count > total / 3", QUORUM),
            (
                "if old { m.old } else { m.voter }",
                "if old { m.voter } else { m.old }",
                QUORUM,
            ),
            ("member.old = false;", "member.old = true;", BASE),
            (
                "!member.voter && !member.learner",
                "!member.voter || !member.learner",
                BASE,
            ),
            ("any(|m| m.old)", "any(|m| m.voter)", BASE),
            ("filter(|m| m.voter)", "filter(|m| m.old)", BASE),
            ("filter(|m| m.old)", "filter(|m| m.learner)", BASE),
            ("filter(|m| m.learner)", "filter(|m| m.voter)", BASE),
            ("m.voter || m.old", "m.voter && m.old", BASE),
            (
                "any(|m| m.id == id)",
                "any(|m| m.id == id && m.voter)",
                BASE,
            ),
            (
                "0 => member.voter = true",
                "0 => member.voter = false",
                INCLUDE,
            ),
            ("old: false,", "old: true,", INCLUDE),
            ("target.include(id, 2)", "target.include(id, 1)", SPEC),
            (
                "map_err(|_| Error::Full)",
                "map_err(|_| Error::Config)",
                SPEC,
            ),
            ("next.include(id, 0)?;", "next.include(id, 2)?;", SPEC),
            ("next.include(*id, 1)?;", "next.include(*id, 2)?;", SPEC),
            (
                "self.is_voter(*id) || learners[..i].contains(id)",
                "self.contains(*id) || learners[..i].contains(id)",
                SPEC,
            ),
            ("if voters.is_empty()", "if old_voters.is_empty()", SPEC),
            (
                "kind == 1 && voters.contains(id)",
                "kind == 2 && voters.contains(id)",
                SPEC,
            ),
            (
                "Self::restore(voters, &[], learners)",
                "Self::restore(learners, &[], voters)",
                SPEC,
            ),
            // proof_cases/arrays.rs, where the numeric-fold front end
            // rejected both before Lean; the first is also from lean.rs.
            ("new.min(old)", "new.max(old)", QUORUM),
            ("if !self.is_joint() {", "if self.is_joint() {", QUORUM),
        ],
    );
}
