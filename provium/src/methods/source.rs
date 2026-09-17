//! An independent walk of selected Rust syntax, not of the lowered effects.
//! Parsing, configured declaration selection, and name/type resolution remain
//! trusted. Lean checks the resulting source-language program's lowering.
use super::{attrs, initialized, tokens, Crate, Definition, Method};
use serde::Serialize;
use std::collections::BTreeMap;
use syn::{spanned::Spanned, Expr, Stmt};

#[derive(Clone, Serialize)]
pub(super) struct DefinitionEvidence {
    name: String,
    source: std::path::PathBuf,
    first_line: usize,
    last_line: usize,
    rust: String,
    source_ast: String,
    fuel: usize,
}

#[derive(Serialize)]
pub(super) struct Evidence {
    method: String,
    fuel: usize,
    definitions: Vec<DefinitionEvidence>,
    scope: &'static str,
}

struct Walk<'a> {
    krate: &'a Crate,
    definitions: BTreeMap<String, DefinitionEvidence>,
    stack: Vec<String>,
    visited: usize,
}

fn place(expr: &Expr) -> Result<String, String> {
    match expr {
        Expr::Path(p) if p.qself.is_none() && p.path.is_ident("self") => {
            attrs(&p.attrs)?;
            Ok(".receiver".into())
        }
        Expr::Field(field) => {
            attrs(&field.attrs)?;
            let syn::Member::Named(name) = &field.member else {
                return Err("source witness requires named fields".into());
            };
            Ok(format!(
                ".field ({}) {:?}",
                place(&field.base)?,
                name.to_string()
            ))
        }
        _ => Err("source witness requires a receiver-rooted place".into()),
    }
}

fn boolean(expr: &Expr) -> Result<String, String> {
    match expr {
        Expr::Lit(lit) => {
            attrs(&lit.attrs)?;
            let syn::Lit::Bool(value) = &lit.lit else {
                return Err("source boolean witness requires a bool literal".into());
            };
            Ok(format!(".literal {}", value.value))
        }
        Expr::Field(_) => Ok(format!(".load ({})", place(expr)?)),
        Expr::Paren(paren) => {
            attrs(&paren.attrs)?;
            boolean(&paren.expr)
        }
        Expr::Unary(unary) if matches!(unary.op, syn::UnOp::Not(_)) => {
            attrs(&unary.attrs)?;
            Ok(format!(".not ({})", boolean(&unary.expr)?))
        }
        Expr::Binary(binary) => {
            attrs(&binary.attrs)?;
            let operation = match binary.op {
                syn::BinOp::And(_) => "and",
                syn::BinOp::Or(_) => "or",
                _ => return Err("unsupported source boolean operator".into()),
            };
            Ok(format!(
                ".{operation} ({}) ({})",
                boolean(&binary.left)?,
                boolean(&binary.right)?
            ))
        }
        _ => Err("unsupported source boolean expression".into()),
    }
}

impl Walk<'_> {
    fn method(&mut self, name: &str) -> Result<DefinitionEvidence, String> {
        if let Some(found) = self.definitions.get(name) {
            return Ok(found.clone());
        }
        if self.stack.len() >= 32 || self.stack.iter().any(|item| item == name) {
            return Err("source witness rejects recursive/deep calls".into());
        }
        let def = self
            .krate
            .methods
            .get(name)
            .ok_or("source callee unresolved")?;
        self.stack.push(name.into());
        let (source_ast, fuel) = self.statements(def, &def.item.block.stmts)?;
        self.stack.pop();
        let evidence = DefinitionEvidence {
            name: name.into(),
            source: def.file.clone(),
            first_line: def.item.span().start().line,
            last_line: def.item.span().end().line,
            rust: tokens(&def.item),
            source_ast,
            fuel,
        };
        self.definitions.insert(name.into(), evidence.clone());
        Ok(evidence)
    }

    fn statements(&mut self, def: &Definition, stmts: &[Stmt]) -> Result<(String, usize), String> {
        let mut body = ".empty".to_owned();
        let mut fuel = 1;
        for statement in stmts.iter().rev() {
            self.visited += 1;
            if self.visited > 100_000 {
                return Err("source witness exceeds statement budget".into());
            }
            let (first, depth) = self.statement(def, statement)?;
            body = format!(".sequence ({first}) ({body})");
            fuel = 1 + depth.max(fuel);
        }
        Ok((body, fuel))
    }

    fn statement(&mut self, def: &Definition, stmt: &Stmt) -> Result<(String, usize), String> {
        match stmt {
            Stmt::Expr(Expr::Assign(assign), Some(_)) => {
                attrs(&assign.attrs)?;
                let literal = match &*assign.right {
                    Expr::Lit(lit) => {
                        attrs(&lit.attrs)?;
                        let syn::Lit::Bool(value) = &lit.lit else {
                            return Err("unsupported source assignment literal".into());
                        };
                        format!(".boolean {}", value.value)
                    }
                    Expr::Path(p) if p.qself.is_none() && p.path.is_ident("None") => {
                        attrs(&p.attrs)?;
                        ".absent".into()
                    }
                    _ => return Err("unsupported source assignment value".into()),
                };
                Ok((
                    format!(".assignment ({}) ({literal})", place(&assign.left)?),
                    1,
                ))
            }
            Stmt::Expr(Expr::If(branch), _) => {
                attrs(&branch.attrs)?;
                let condition = boolean(&branch.cond)?;
                let (yes, yes_depth) = self.statements(def, &branch.then_branch.stmts)?;
                let (no, no_depth) = match &branch.else_branch {
                    None => (".empty".into(), 1),
                    Some((_, expr)) => match &**expr {
                        Expr::Block(block) if block.label.is_none() => {
                            attrs(&block.attrs)?;
                            self.statements(def, &block.block.stmts)?
                        }
                        Expr::If(_) => self.statements(def, &[Stmt::Expr(*expr.clone(), None)])?,
                        _ => return Err("unsupported source else expression".into()),
                    },
                };
                Ok((
                    format!(".conditional ({condition}) ({yes}) ({no})"),
                    1 + yes_depth.max(no_depth),
                ))
            }
            Stmt::Expr(Expr::MethodCall(call), Some(_)) => {
                attrs(&call.attrs)?;
                if place(&call.receiver)? != ".receiver"
                    || !call.args.is_empty()
                    || call.turbofish.is_some()
                {
                    return Err("source witness requires receiver-local parameterless calls".into());
                }
                let name = format!("{}::{}::{}", def.module, def.receiver, call.method)
                    .trim_start_matches("::")
                    .to_owned();
                let callee = self.method(&name)?;
                Ok((format!(".call {name:?}"), 1 + callee.fuel))
            }
            _ => Err("unsupported statement in independent source witness".into()),
        }
    }
}

pub(super) fn generate(
    krate: &Crate,
    methods: &[Method],
    namespace: &str,
) -> Result<(String, Vec<Evidence>), String> {
    let mut code = format!("\nnamespace {namespace}\nopen Provium.State\n");
    let mut evidence = vec![];
    for method in methods
        .iter()
        .filter(|method| initialized::supported(method))
    {
        let mut walk = Walk {
            krate,
            definitions: BTreeMap::new(),
            stack: vec![],
            visited: 0,
        };
        let root = walk.method(&method.name)?;
        let name = &method.symbol;
        let mut environment = "none".to_owned();
        for definition in walk.definitions.values().rev() {
            environment = format!(
                "if callee = {:?} then some ({}) else {environment}",
                definition.name, definition.source_ast
            );
        }
        let fuel = root.fuel;
        code.push_str(&format!(
            r#"def {name}_source : Provium.ScalarSource.Statement := {}
def {name}_source_environment : Provium.ScalarSource.Environment := fun callee => {environment}
theorem {name}_source_compiles :
    Provium.ScalarSource.lower {fuel} {name}_source_environment {name}_source = some {name}_ir := by rfl
def {name}_source_run (layout : Initialized.Layout) (heap : Initialized.Heap α) :=
  Provium.ScalarSource.run {fuel} {name}_source_environment layout {name}_source heap
theorem {name}_source_outcomes (layout : Initialized.Layout) (heap : Initialized.Heap α) :
    {name}_source_run layout heap =
      (Initialized.execute layout {name}_ir heap).mapError Provium.ScalarSource.Fault.memory :=
  Provium.ScalarSource.lower_correct {fuel} {name}_source_compiles
theorem {name}_source_refinement (heap : Initialized.Heap α) (state : Store α)
    (related : Initialized.Relates {name}_layout heap state) :
    ∃ result, {name}_source_run {name}_layout heap = .ok result ∧
      Initialized.Relates {name}_layout result ({name} state) := by
  simpa only [{name}_source_run, {name}_correspondence] using
    Provium.ScalarSource.initialized_refinement {name}_source_compiles related {name}_well_typed
"#,
            root.source_ast
        ));
        evidence.push(Evidence {
            method: method.name.clone(),
            fuel,
            definitions: walk.definitions.into_values().collect(),
            scope: "independent syntax walk and kernel-checked source-language lowering; Rust parsing, declaration/name/type/place resolution and physical source semantics remain trusted",
        });
    }
    code.push_str(&format!("end {namespace}\n"));
    Ok((code, evidence))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::methods::{proof_modules::Workspace, Statement};
    use std::{fs, path::PathBuf};

    struct Work(PathBuf);
    impl Drop for Work {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    #[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
    fn independent_source_witness_rejects_corrupted_lowering() {
        let work = Work(
            PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("artifacts")
                .join(format!("source-witness-{}", std::process::id())),
        );
        fs::create_dir_all(&work.0).unwrap();
        let source = work.0.join("lib.rs");
        fs::write(&source, "struct State {flag:bool, other:bool} impl State {fn helper(&mut self){self.flag=false;} fn update(&mut self){self.helper(); if self.flag {self.other=false;} else {self.other=true;}}}").unwrap();
        let krate = Crate::load(&source).unwrap();
        let original = krate.lower("State::update").unwrap();
        let (witness, evidence) = generate(&krate, &[original], "Subject").unwrap();
        assert_eq!(evidence[0].definitions.len(), 2);
        assert!(evidence[0]
            .definitions
            .iter()
            .any(|def| def.name == "State::helper"));
        assert!(witness.contains(r#".call "State::helper""#));
        let workspace = Workspace::new(&work.0).unwrap();
        for (name, text) in [
            ("State", super::super::SEMANTICS),
            ("Loans", super::super::LOANS),
            ("ArrayMoves", super::super::ARRAY_MOVES),
            ("ScalarSource", super::super::SCALAR_SOURCE),
            ("FieldReads", super::super::FIELD_READS),
            ("ConstructorSource", super::super::CONSTRUCTOR_SOURCE),
            ("Audit", super::super::AUDIT),
        ] {
            workspace
                .write(&format!("Provium/{name}.lean"), text)
                .unwrap();
            workspace
                .check(
                    &format!("Provium/{name}.lean"),
                    Some(&format!("Provium/{name}.olean")),
                )
                .unwrap();
        }
        workspace.write("SourceChecks.lean", r#"import Provium.ScalarSource
import Provium.Audit
open Provium.State
open Provium.ScalarSource
def nowhere : Environment := fun _ => none
def heap : Initialized.Heap Unit := fun _ => none
def layout : Initialized.Layout := fun _ => some .boolean
theorem fuel_fault : Provium.ScalarSource.run 0 nowhere layout .empty heap = .error .exhausted := rfl
theorem unresolved_call : Provium.ScalarSource.run 1 nowhere layout (.call "missing") heap = .error .unresolved := rfl
theorem missing_read : readBoolean layout heap (.load (.field .receiver "flag")) = .error .uninitialized := rfl
theorem short_circuit : readBoolean layout heap (.and (.literal false) (.load (.field .receiver "flag"))) = .ok false := rfl
theorem wrong_type : Provium.ScalarSource.run 1 nowhere layout (.assignment (.field .receiver "flag") .absent) heap = .error (.memory .wrongType) := rfl
theorem hidden_call_rejected : lower 8 nowhere (.conditional (.literal false) (.call "missing") .empty) = none := rfl
theorem recursive_call_rejected : lower 8 (fun _ => some (.call "again")) (.call "again") = none := rfl
#provium_check Provium.ScalarSource.boolean_correct references Provium.ScalarSource.readBoolean
#provium_check Provium.ScalarSource.lower_correct references Provium.ScalarSource.run
#provium_check Provium.ScalarSource.initialized_refinement references Provium.ScalarSource.run
#provium_check fuel_fault references Provium.ScalarSource.run
#provium_check unresolved_call references Provium.ScalarSource.run
#provium_check missing_read references Provium.ScalarSource.readBoolean
#provium_check short_circuit references Provium.ScalarSource.readBoolean
#provium_check wrong_type references Provium.ScalarSource.run
#provium_check hidden_call_rejected references Provium.ScalarSource.lower
#provium_check recursive_call_rejected references Provium.ScalarSource.lower
"#).unwrap();
        let audit = workspace.check("SourceChecks.lean", None).unwrap();
        assert_eq!(audit.matches("PROVIUM_VERIFIED ").count(), 10);

        for mutation in 0..4 {
            let mut method = krate.lower("State::update").unwrap();
            match mutation {
                0 => {}
                1 => {
                    let Statement::Call { body, .. } = &mut method.body[0] else {
                        panic!()
                    };
                    let Statement::Write(write) = &mut body[0] else {
                        panic!()
                    };
                    write.literal = crate::methods::Literal::Boolean(true);
                }
                2 => method.body.reverse(),
                3 => {
                    method.body.remove(0);
                }
                _ => unreachable!(),
            }
            // Re-reading the source yields exactly the same witness even when
            // the effect tree is wrong. Its checked equality must catch that.
            let (unchanged, _) =
                generate(&krate, std::slice::from_ref(&method), "Subject").unwrap();
            assert_eq!(unchanged, witness);
            // These scalar methods use none of the numeric runtime. Omit that
            // unused import from this isolated kernel test.
            let mut generated = crate::methods::generate(&[method], "Subject").replace(
                "import Provium.NumericFolds
",
                "",
            );
            generated.push_str(&witness);
            workspace.write("Generated.lean", &generated).unwrap();
            let result = workspace.check("Generated.lean", None);
            if mutation == 0 {
                result.unwrap();
            } else {
                let error = result.unwrap_err();
                assert!(error.contains("Lean rejected Generated.lean"), "{error}");
            }
        }
    }
}
