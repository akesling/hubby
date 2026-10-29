"""Generate one Lean file per message kind for the `step` refinement proof.

Usage: step_cases.py <fp-ws dir> <case|all> <tail-file-or-->
The tail file holds the case-specific proof text that follows the shared
prefix; '-' keeps the default tail (handlers then trace/sorry)."""
import sys, re
ws, which, tailfile = sys.argv[1], sys.argv[2], sys.argv[3]
tpl = open(f"{ws}/step_proof_template.txt").read()
cases = {
  "prevote": ("(T : Nat) (last : PureValue)", "(Msg.prevote T last)"),
  "prevoted": ("(T camp : Nat) (g : Bool)", "(Msg.prevoted T camp g)"),
  "vote": ("(T : Nat) (last : PureValue)", "(Msg.vote T last)"),
  "voted": ("(T : Nat) (g : Bool)", "(Msg.voted T g)"),
  "append": ("(T : Nat) (prev entry commit : PureValue)", "(Msg.append T prev entry commit)"),
  "batch": ("(T : Nat) (prev entries commit : PureValue)", "(Msg.batch T prev entries commit)"),
  "install": ("(T : Nat) (snap : PureValue)", "(Msg.install T snap)"),
  "replicated": ("(T : Nat) (index : PureValue) (rej : Rej)", "(Msg.replicated T index rej)"),
}
names = list(cases) if which == "all" else [which]
for name in names:
    binders, msg = cases[name]
    body = tpl.replace("end Refine", "")
    body = body.replace("theorem step_spec", f"theorem step_{name}")
    body = body.replace("(src dst : Nat) (m : Msg) (cap : PureValue)", f"(src dst : Nat) {binders} (cap : PureValue)")
    body = body.replace("envelopev src dst m", f"envelopev src dst {msg}")
    body = body.replace("StepOut ids n t vf c sn en ln os bs src m n'", f"StepOut ids n t vf c sn en ln os bs src {msg} n'")
    body = body.replace("(cases m <;> wp_walk [", "(wp_walk [")
    body = body.replace("message_term_spec target MSG", f"message_term_spec target {msg}")
    if name == "vote":
        body = body.replace("(hs : n.state = statev (hardv t vf c) sn en ln)",
            "(hs : n.state = statev (hardv t vf c) sn en ln)\n    (hvf : vf = .absent ∨ ∃ x, vf = .present (idv x))")
    if tailfile != "-":
        tail = open(tailfile).read()
        i = body.index("         all_goals trace_state\n         all_goals sorry)")
        body = body[:i] + tail + body[i + len("         all_goals trace_state\n         all_goals sorry)"):]
    out = "import StepDefs\nopen Provium.State Provium.Imperative\nset_option linter.unusedSimpArgs false\nnamespace Refine\n\n" + body + "\nend Refine\n"
    open(f"{ws}/StepCase_{name}.lean", "w").write(out)
    print("wrote", name)
