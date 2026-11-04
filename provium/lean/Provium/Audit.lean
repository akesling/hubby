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

/-- Constants of an expression. -/
private def consts (e : Lean.Expr) : Array Name :=
  e.foldConsts #[] fun n acc => acc.push n

/-- A declaration owned by a consumer module: neither generated, Provium's, nor the toolchain's. -/
private def consumerOwned (env : Environment) (n : Name) : Bool :=
  match env.getModuleIdxFor? n with
  | none => true
  | some i =>
    let m := env.header.moduleNames[i.toNat]!
    !(m == `Generated || (`Provium).isPrefixOf m || (`Init).isPrefixOf m || (`Lean).isPrefixOf m ||
      (`Std).isPrefixOf m)

/-- Whether `fnName` occurs in `e`, directly or through the types, bodies and
    constructors of consumer-owned definitions `e` refers to. A statement about
    a consumer's execution relation (say, an inductive whose constructors run
    the generated function) is a statement about that function. -/
private partial def reaches (env : Environment) (fnName : Name) (e : Lean.Expr) : Bool := Id.run do
  let mut seen : NameSet := {}
  let mut work : Array Name := consts e
  while !work.isEmpty do
    let n := work.back!
    work := work.pop
    if n == fnName then return true
    if seen.contains n || !consumerOwned env n then continue
    seen := seen.insert n
    match env.find? n with
    | some (.defnInfo d) => work := work ++ consts d.type ++ consts d.value
    | some (.thmInfo _) => pure ()
    | some (.inductInfo i) =>
      work := work ++ consts i.type
      for c in i.ctors do
        if let some info := env.find? c then work := work ++ consts info.type
    | some (.ctorInfo c) => work := work ++ consts c.type
    | some info => work := work ++ consts info.type
    | none => pure ()
  return false

/-- Accept only actual theorem declarations mentioning the designated generated
    function in their statement. Audit transitive axioms, including sorryAx and
    native_decide/bv_decide admissions, rather than searching proof source text. -/
private def checkTheorem (name fnName : Name) : CommandElabM Unit := do
  let info ← getConstInfo name
  match info with
  | .thmInfo _ => pure ()
  | _ => throwError "Provium requires a theorem declaration: {name}"
  if !mentions info.type fnName && !reaches (← getEnv) fnName info.type then
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
