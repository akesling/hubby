import Lean
open Lean Elab Command

namespace Provium.Audit
private def mentions (expr : Lean.Expr) (name : Name) : Bool :=
  match expr with
  | .const n _ => n == name
  | .app f a => mentions f name || mentions a name
  | .lam _ t b _ | .forallE _ t b _ => mentions t name || mentions b name
  | .letE _ t v b _ => mentions t name || mentions v name || mentions b name
  | .mdata _ e | .proj _ _ e => mentions e name
  | _ => false

/-- Accept only actual theorem declarations mentioning the designated generated
    function in their statement. Audit transitive axioms, including sorryAx and
    native_decide/bv_decide admissions, rather than searching proof source text. -/
elab "#provium_check " theoremName:ident " references " functionName:ident : command => do
  let name := theoremName.getId
  let fnName := functionName.getId
  let info ← getConstInfo name
  match info with
  | .thmInfo _ => pure ()
  | _ => throwError "Provium requires a theorem declaration: {name}"
  if !mentions info.type fnName then
    throwError "theorem {name} does not mention generated function {fnName} in its statement"
  let axioms ← collectAxioms name
  for axiomName in axioms do
    if axiomName != ``propext && axiomName != ``Quot.sound && axiomName != ``Classical.choice then
      throwError "unapproved axiom {axiomName} in {name}"
  logInfo m!"PROVIUM_VERIFIED {name}; axioms: {axioms}"
end Provium.Audit
