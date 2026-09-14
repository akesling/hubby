#!/usr/bin/env python3
"""Check that independent oracles reject deliberately broken protocol rules.

Only a temporary checkout is edited. A compile failure does not count as a
detected mutation; the selected test must run and fail.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile


CRATE = Path(__file__).resolve().parents[1]
MUTATIONS = [
    ("joint election ignores old voters", "src/membership.rs",
     "(!self.is_joint() || majority(true, &mut acknowledged))", "true",
     ["--lib", "quorums_match_independent_counts"]),
    ("batch forgets earliest changed entry", "src/node.rs",
     "from.min(entry.id.index)", "from.max(entry.id.index)",
     ["--test", "reconfiguration", "rejected_batch_does_not_admit_a_prefix_or_clone_payloads"]),
    ("isolated voter bypasses pre-vote", "src/node.rs",
     "if self.hooks.is_some() {", "if false && self.hooks.is_some() {",
     ["--test", "reconfiguration", "isolated_follower_does_not_inflate_terms_and_isolated_leader_steps_down"]),
    ("leader ignores lost quorum", "src/node.rs",
     "if !quorum {", "if false && !quorum {",
     ["--test", "reconfiguration", "isolated_follower_does_not_inflate_terms_and_isolated_leader_steps_down"]),
    ("joint commitment accepts either quorum", "src/membership.rs",
     "new.min(old)", "new.max(old)",
     ["--test", "reconfiguration", "joint_commit_requires_both_majorities"]),
    ("snapshot uses latest configuration", "src/cluster.rs",
     "let membership = self.node.membership_at(index).1;", "let membership = self.membership();",
     ["--test", "reconfiguration", "snapshot_carries_configuration_at_its_boundary_and_recovers_joiner"]),
    ("finalize uncommitted joint configuration", "src/cluster.rs",
     "!membership.is_joint() || index > self.state().hard().commit", "!membership.is_joint()",
     ["--test", "reconfiguration", "joint_commit_requires_both_majorities"]),
    ("non-majority election", "src/membership.rs", "count > total / 2", "count >= total / 2",
     ["--lib", "exhaustive_election_and_persistence_schedules"]),
    ("forgotten higher term", "src/node.rs", "if term > self.state.hard.term {",
     "if false && term > self.state.hard.term {", ["--test", "model"]),
    ("prior-term commitment", "src/node.rs",
     ".is_some_and(|id| id.term == self.state.hard.term)", ".is_some()",
     ["--test", "protocol", "prior_term_entries_need_a_current_term_majority"]),
    ("unbounded follower commitment", "src/node.rs",
     "self.commit_to(commit.min(matched));", "self.commit_to(commit);",
     ["--test", "model"]),
    ("lost snapshot suffix", "src/state.rs",
     "if self.id_at(snapshot.last.index) == Some(snapshot.last) {",
     "if false && self.id_at(snapshot.last.index) == Some(snapshot.last) {",
     ["--test", "protocol", "snapshots_preserve_matching_suffixes_and_replace_conflicting_ones"]),
    ("output before persistence", "src/node.rs",
     "if self.dirty {\n            return None;\n        }",
     "if false && self.dirty {\n            return None;\n        }",
     ["--lib", "exhaustive_commit_and_crash_schedules"]),
]


def main():
    with tempfile.TemporaryDirectory(prefix="jarl-mutations-") as directory:
        root = Path(directory)
        crate = root / "jarl"
        shutil.copytree(CRATE, crate)
        (root / "Cargo.toml").write_text('[workspace]\nmembers = ["jarl"]\nresolver = "2"\n')
        for name, relative, original, replacement, selection in MUTATIONS:
            path = crate / relative
            source = path.read_text()
            if original not in source:
                raise SystemExit(f"Mutation needs updating: {name}")
            path.write_text(source.replace(original, replacement))
            try:
                result = subprocess.run(
                    ["cargo", "+stable", "test", "--offline", *selection],
                    cwd=crate, capture_output=True, text=True, timeout=60,
                )
                output = result.stdout + result.stderr
                if result.returncode == 0 or "test result: FAILED" not in output:
                    raise SystemExit(f"Mutation was not caught by a test: {name}\n{output}")
                print(f"Detected: {name}", flush=True)
            finally:
                path.write_text(source)
    print(f"Detected all {len(MUTATIONS)} deliberate faults.")


if __name__ == "__main__":
    main()
