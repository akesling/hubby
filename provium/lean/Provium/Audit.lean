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
private def checkTheorem (name fnName : Name) : CommandElabM Unit := do
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

elab "#provium_check " theoremName:ident " references " functionName:ident : command =>
  checkTheorem theoremName.getId functionName.getId

/-- A consumer obligation must be proved by the consumer: its theorem has to be
    declared in an imported proof module, never in `Generated` or a `Provium`
    library module, so a generated correspondence/refinement theorem cannot be
    listed as an invariant obligation that nobody proved. -/
elab "#provium_obligation " theoremName:ident " references " functionName:ident : command => do
  let name := theoremName.getId
  let env ← getEnv
  let some index := env.getModuleIdxFor? name
    | throwError "obligation {name} must be declared in an imported consumer proof module"
  let module := env.header.moduleNames[index.toNat]!
  if module == `Generated || (`Provium).isPrefixOf module then
    throwError "obligation {name} is declared by Provium-owned module {module}; prove it in a consumer proof module"
  checkTheorem name functionName.getId
end Provium.Audit
