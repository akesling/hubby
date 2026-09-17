//! Constructor source witnesses read original initializers and declarations.
//! They do not use the flattened constructor fields or their const substitution.
use super::{attrs, tokens, Crate, Definition, Method};
use serde::Serialize;
use std::collections::BTreeMap;
use syn::{spanned::Spanned, Expr, GenericArgument, GenericParam, Type};

#[derive(Serialize)]
struct DefaultEvidence {
    name: String,
    module: String,
    declaration: String,
    schema: String,
    fuel: usize,
}

#[derive(Serialize)]
pub(super) struct Evidence {
    method: String,
    source: std::path::PathBuf,
    first_line: usize,
    last_line: usize,
    rust: String,
    self_type: String,
    constants: BTreeMap<String, String>,
    defaults: Vec<DefaultEvidence>,
    expression: String,
    fuel: usize,
    scope: &'static str,
}

fn name(ty: &Type) -> Result<String, String> {
    let Type::Path(path) = ty else {
        return Err("constructor source type is not a named type".into());
    };
    if path.qself.is_some() || path.path.segments.len() != 1 {
        return Err("constructor source needs a resolved unqualified type".into());
    }
    Ok(path.path.segments[0].ident.to_string())
}

fn optional(ty: &Type) -> bool {
    matches!(ty, Type::Path(p) if p.qself.is_none() && p.path.segments.len() == 1
        && p.path.segments[0].ident == "Option"
        && matches!(&p.path.segments[0].arguments, syn::PathArguments::AngleBracketed(a)
            if a.args.len() == 1 && matches!(a.args[0], GenericArgument::Type(_))))
}

fn unsigned(ty: &Type) -> bool {
    ["u8", "u16", "u32", "u64", "usize"].contains(&tokens(ty).as_str())
}

fn none(expr: &Expr) -> bool {
    matches!(expr, Expr::Path(p) if p.qself.is_none() && p.attrs.is_empty() && p.path.is_ident("None"))
}

fn capacity(expr: &Expr) -> Result<String, String> {
    match expr {
        Expr::Lit(lit) if lit.attrs.is_empty() => {
            let syn::Lit::Int(value) = &lit.lit else {
                return Err("source array capacity must be an integer".into());
            };
            Ok(format!(
                ".fixed {}",
                value.base10_parse::<u64>().map_err(|e| e.to_string())?
            ))
        }
        Expr::Path(p)
            if p.attrs.is_empty()
                && p.qself.is_none()
                && p.path.segments.len() == 1
                && matches!(p.path.segments[0].arguments, syn::PathArguments::None) =>
        {
            Ok(format!(
                ".parameter {:?}",
                p.path.segments[0].ident.to_string()
            ))
        }
        _ => Err("unsupported source array capacity".into()),
    }
}

fn fields(values: Vec<(String, String, usize)>) -> (String, usize) {
    let mut expression = ".emptyRecord".to_owned();
    let mut fuel = 1;
    for (name, value, depth) in values.into_iter().rev() {
        expression = format!(".field {name:?} ({value}) ({expression})");
        fuel = 1 + depth.max(fuel);
    }
    (expression, fuel)
}

struct Walk<'a> {
    krate: &'a Crate,
    defaults: BTreeMap<String, DefaultEvidence>,
}

impl Walk<'_> {
    fn value(&mut self, module: &str, ty: &Type, expr: &Expr) -> Result<(String, usize), String> {
        if none(expr) && optional(ty) {
            return Ok((".atom .absent".into(), 1));
        }
        if let Expr::Lit(lit) = expr {
            attrs(&lit.attrs)?;
            return match &lit.lit {
                syn::Lit::Bool(value) if tokens(ty) == "bool" => {
                    Ok((format!(".atom (.boolean {})", value.value), 1))
                }
                syn::Lit::Int(value) if unsigned(ty) => Ok((
                    format!(
                        ".atom (.unsigned {:?} {})",
                        tokens(ty),
                        value.base10_parse::<u64>().map_err(|e| e.to_string())?
                    ),
                    1,
                )),
                _ => Err("unsupported source constructor literal".into()),
            };
        }
        let Expr::Call(call) = expr else {
            return Err("unsupported source constructor expression".into());
        };
        attrs(&call.attrs)?;
        let Expr::Path(callee) = &*call.func else {
            return Err("source constructor callee must be named".into());
        };
        attrs(&callee.attrs)?;
        if callee.qself.is_some()
            || callee
                .path
                .segments
                .iter()
                .any(|s| !matches!(s.arguments, syn::PathArguments::None))
        {
            return Err("source constructor callee qualification unsupported".into());
        }
        let names = callee
            .path
            .segments
            .iter()
            .map(|s| s.ident.to_string())
            .collect::<Vec<_>>();
        if names == ["core", "array", "from_fn"] && call.args.len() == 1 {
            let Type::Array(array) = ty else {
                return Err("source from_fn requires an array declaration".into());
            };
            let Expr::Closure(closure) = &call.args[0] else {
                return Err("source from_fn requires an explicit closure".into());
            };
            attrs(&closure.attrs)?;
            if !optional(&array.elem)
                || closure.asyncness.is_some()
                || closure.constness.is_some()
                || closure.inputs.len() != 1
                || !matches!(&closure.inputs[0], syn::Pat::Wild(p) if p.attrs.is_empty())
                || !matches!(closure.output, syn::ReturnType::Default)
                || !none(&closure.body)
            {
                return Err("source array initializer must be exactly |_| None".into());
            }
            return Ok((format!(".emptyArray ({})", capacity(&array.len)?), 1));
        }
        if names.len() != 2 || names[1] != "default" || !call.args.is_empty() {
            return Err("source constructor only supports derived Default here".into());
        }
        let record = self.krate.resolve(module, &name(ty)?, 0)?;
        if self.krate.resolve(module, &names[0], 0)? != record {
            return Err("source Default receiver differs from declared field".into());
        }
        let declaration = self
            .krate
            .structs
            .get(&record)
            .ok_or("source Default record missing")?;
        let record_module = &self.krate.struct_modules[&record];
        let key = format!("{record_module}::{record}")
            .trim_start_matches("::")
            .to_owned();
        if let Some(found) = self.defaults.get(&key) {
            return Ok((format!(".derivedDefault {key:?}"), found.fuel + 1));
        }
        let derived = declaration.attrs.iter().any(|attr| {
            attr.path().is_ident("derive")
                && attr
                    .parse_args_with(
                        syn::punctuated::Punctuated::<syn::Ident, syn::Token![,]>::parse_terminated,
                    )
                    .is_ok_and(|derives| derives.iter().any(|d| d == "Default"))
        });
        if !derived || !declaration.generics.params.is_empty() {
            return Err("source Default requires a nongeneric derived record".into());
        }
        let mut declared_fields = vec![];
        for field in &declaration.fields {
            attrs(&field.attrs)?;
            let label = field
                .ident
                .as_ref()
                .ok_or("source Default requires named fields")?
                .to_string();
            let field_type = if optional(&field.ty) {
                ".optional".into()
            } else if tokens(&field.ty) == "bool" {
                ".boolean".into()
            } else if unsigned(&field.ty) {
                format!(".unsigned {:?}", tokens(&field.ty))
            } else {
                return Err("source Default field needs another semantic contract".into());
            };
            declared_fields.push(format!("⟨{label:?}, {field_type}⟩"));
        }
        let fuel = declared_fields.len() + 1;
        let schema = format!("[{}]", declared_fields.join(", "));
        self.defaults.insert(
            key.clone(),
            DefaultEvidence {
                name: key.clone(),
                module: record_module.clone(),
                declaration: tokens(declaration),
                schema,
                fuel,
            },
        );
        Ok((format!(".derivedDefault {key:?}"), fuel + 1))
    }
}

fn substitutions(krate: &Crate, def: &Definition) -> Result<BTreeMap<String, String>, String> {
    let declaration = krate
        .structs
        .get(&def.receiver)
        .ok_or("source constructor record missing")?;
    let Some(Type::Path(ty)) = &def.self_type else {
        return Err("source constructor self type missing".into());
    };
    let arguments = match &ty.path.segments.last().ok_or("empty self type")?.arguments {
        syn::PathArguments::None => vec![],
        syn::PathArguments::AngleBracketed(a) => a.args.iter().collect(),
        _ => return Err("source constructor type arguments unsupported".into()),
    };
    if arguments.len() != declaration.generics.params.len() {
        return Err("source constructor substitution arity mismatch".into());
    }
    let mut constants = BTreeMap::new();
    for (parameter, argument) in declaration.generics.params.iter().zip(arguments) {
        if let GenericParam::Const(parameter) = parameter {
            let expression = match argument {
                GenericArgument::Const(expr) => capacity(expr)?,
                GenericArgument::Type(Type::Path(p))
                    if p.qself.is_none()
                        && p.path.segments.len() == 1
                        && matches!(p.path.segments[0].arguments, syn::PathArguments::None) =>
                {
                    format!(".parameter {:?}", p.path.segments[0].ident.to_string())
                }
                _ => return Err("source const argument is not a literal/parameter".into()),
            };
            constants.insert(parameter.ident.to_string(), expression);
        }
    }
    Ok(constants)
}

pub(super) fn generate(
    krate: &Crate,
    methods: &[Method],
    namespace: &str,
) -> Result<(String, Vec<Evidence>), String> {
    let mut code = format!("\nnamespace {namespace}\nopen Provium.State\n");
    let mut evidence = vec![];
    for method in methods.iter().filter(|method| method.constructor.is_some()) {
        let def = krate
            .methods
            .get(&method.name)
            .ok_or("source constructor missing")?;
        let [syn::Stmt::Expr(Expr::Struct(value), None)] = def.item.block.stmts.as_slice() else {
            return Err("source constructor must retain its entire Self initializer".into());
        };
        attrs(&value.attrs)?;
        if value.qself.is_some() || !value.path.is_ident("Self") || value.rest.is_some() {
            return Err("source constructor must initialize explicit Self fields".into());
        }
        let declaration = &krate.structs[&def.receiver];
        let mut walk = Walk {
            krate,
            defaults: BTreeMap::new(),
        };
        let mut values = vec![];
        for field in &value.fields {
            attrs(&field.attrs)?;
            let syn::Member::Named(label) = &field.member else {
                return Err("source constructor field must be named".into());
            };
            let declared = declaration
                .fields
                .iter()
                .find(|f| f.ident.as_ref() == Some(label))
                .ok_or("source initializer field is undeclared")?;
            let (expression, fuel) = walk.value(&def.module, &declared.ty, &field.expr)?;
            values.push((label.to_string(), expression, fuel));
        }
        let (expression, fuel) = fields(values);
        let constants = substitutions(krate, def)?;
        let mut bindings = "none".to_owned();
        for (formal, actual) in constants.iter().rev() {
            bindings = format!("if parameter = {formal:?} then some ({actual}) else {bindings}");
        }
        let binder = if constants.is_empty() {
            "_"
        } else {
            "parameter"
        };
        let mut defaults = "none".to_owned();
        for record in walk.defaults.values().rev() {
            defaults = format!(
                "if name = {:?} then some ({}) else {defaults}",
                record.name, record.schema
            );
        }
        let default_binder = if walk.defaults.is_empty() {
            "_"
        } else {
            "name"
        };
        let name = &method.symbol;
        code.push_str(&format!(
            r#"def {name}_source : Provium.ConstructorSource.Expression := {expression}
def {name}_source_constants : Provium.ConstructorSource.Constants := fun {binder} => {bindings}
def {name}_source_defaults : Provium.ConstructorSource.Defaults := fun {default_binder} => {defaults}
theorem {name}_source_compiles :
    Provium.ConstructorSource.lower {fuel} {name}_source_defaults {name}_source_constants [] {name}_source = some {name}_ir := by rfl
def {name}_source_run (sizes : String → Nat) :=
  Provium.ConstructorSource.run {fuel} {name}_source_defaults {name}_source_constants sizes [] {name}_source (fun _ => .absent)
theorem {name}_source_refinement (sizes : String → Nat) :
    {name}_source_run sizes = .ok ({name} sizes) :=
  Provium.ConstructorSource.constructor_refinement {name}_source_compiles
"#
        ));
        evidence.push(Evidence {
            method: method.name.clone(), source: def.file.clone(),
            first_line: def.item.span().start().line, last_line: def.item.span().end().line,
            rust: tokens(&def.item), self_type: tokens(def.self_type.as_ref().unwrap()),
            constants, defaults: walk.defaults.into_values().collect(), expression, fuel,
            scope: "independent initializer/declaration walk and checked source-language lowering; Rust parsing, trait/const/type/place resolution, builtin contracts and physical initialization remain trusted",
        });
    }
    code.push_str(&format!("end {namespace}\n"));
    Ok((code, evidence))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::methods::{
        constructors::{Capacity, Initial},
        proof_modules::Workspace,
    };
    use std::{fs, path::PathBuf};

    struct Work(PathBuf);
    impl Drop for Work {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    #[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
    fn constructor_witness_checks_defaults_const_substitution_and_field_paths() {
        let work = Work(
            PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("artifacts")
                .join(format!("constructor-source-{}", std::process::id())),
        );
        fs::create_dir_all(&work.0).unwrap();
        let path = work.0.join("lib.rs");
        fs::write(&path, "#[derive(Default)] struct Header{term:u64,flag:bool,vote:Option<u64>} struct State<T,const N:usize>{header:Header,slots:[Option<T>;N],len:usize} impl<T,const CAP:usize> State<T,CAP>{fn new()->Self{Self{header:Header::default(),slots:core::array::from_fn(|_|None),len:0}}}").unwrap();
        let krate = Crate::load(&path).unwrap();
        let method = krate.lower("State::new").unwrap();
        let (witness, evidence) = generate(&krate, &[method], "Subject").unwrap();
        assert_eq!(evidence[0].constants["N"], r#".parameter "CAP""#);
        assert_eq!(evidence[0].defaults.len(), 1);
        assert_eq!(evidence[0].defaults[0].name, "Header");
        let workspace = Workspace::new(&work.0).unwrap();
        for (name, text) in [
            ("State", super::super::SEMANTICS),
            ("Loans", super::super::LOANS),
            ("ScalarSource", super::super::SCALAR_SOURCE),
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
        workspace.write("SourceChecks.lean", r#"import Provium.ConstructorSource
import Provium.Audit
open Provium.State
open Provium.ConstructorSource

def noDefaults : Defaults := fun _ => none
def noConstants : Constants := fun _ => none
def heap : InitStore := fun _ => .absent
def sizes : String → Nat := fun _ => 3
def bound : Constants := fun name => if name = "N" then some (.parameter "CAP") else none
theorem exhausted : run 0 noDefaults noConstants sizes [] .emptyRecord heap = .error .exhausted := rfl
theorem unbound : run 2 noDefaults noConstants sizes [] (.emptyArray (.parameter "N")) heap = .error .unboundCapacity := rfl
theorem unknown_default : run 2 noDefaults noConstants sizes [] (.derivedDefault "Missing") heap = .error .unresolvedDefault := rfl
theorem substitution : substitute bound (.parameter "N") = some (.parameter "CAP") := rfl
theorem zero_array : run 2 noDefaults (fun _ => some (.fixed 0)) sizes ["slots"]
    (.emptyArray (.parameter "N")) heap = .ok (Provium.ConstructorSource.put heap ["slots"] (.slots [])) := rfl
theorem missing_default_rejects_lowering : lower 8 noDefaults bound [] (.derivedDefault "Missing") = none := rfl
theorem missing_capacity_rejects_lowering : lower 8 noDefaults noConstants [] (.emptyArray (.parameter "N")) = none := rfl
theorem typed_defaults :
    lower 8 (fun _ => some [("flag", .boolean), ("term", .unsigned "u64"), ("vote", .optional)])
      noConstants ["header"] (.derivedDefault "Header") =
      some [⟨["header", "flag"], .boolean false⟩, ⟨["header", "term"], .unsigned "u64" 0⟩,
        ⟨["header", "vote"], .absent⟩] := rfl
#provium_check typed_defaults references Provium.ConstructorSource.lower
#provium_check Provium.ConstructorSource.lower_correct references Provium.ConstructorSource.run
#provium_check Provium.ConstructorSource.constructor_refinement references Provium.ConstructorSource.run
#provium_check exhausted references Provium.ConstructorSource.run
#provium_check unbound references Provium.ConstructorSource.run
#provium_check unknown_default references Provium.ConstructorSource.run
#provium_check substitution references Provium.ConstructorSource.substitute
#provium_check zero_array references Provium.ConstructorSource.run
#provium_check missing_default_rejects_lowering references Provium.ConstructorSource.lower
#provium_check missing_capacity_rejects_lowering references Provium.ConstructorSource.lower
"#).unwrap();
        let audited = workspace.check("SourceChecks.lean", None).unwrap();
        assert_eq!(audited.matches("PROVIUM_VERIFIED ").count(), 10);
        for mutation in 0..5 {
            let mut method = krate.lower("State::new").unwrap();
            let constructor = method.constructor.as_mut().unwrap();
            match mutation {
                0 => {}
                1 => {
                    let Initial::Unsigned { value, .. } = &mut constructor.fields[0].value else {
                        panic!()
                    };
                    *value = 1;
                }
                2 => {
                    let field = constructor
                        .fields
                        .iter_mut()
                        .find(|f| f.path == ["slots"])
                        .unwrap();
                    field.value = Initial::EmptySlots(Capacity::Fixed(0));
                }
                3 => constructor.fields[0].path = vec!["term".into()],
                4 => {
                    constructor.fields.remove(0);
                }
                _ => unreachable!(),
            }
            let (unchanged, _) =
                generate(&krate, std::slice::from_ref(&method), "Subject").unwrap();
            assert_eq!(unchanged, witness);
            let mut generated = crate::methods::generate(&[method], "Subject").replace(
                "import Provium.NumericFolds
",
                "",
            );
            generated.push_str(&witness);
            workspace.write("Generated.lean", &generated).unwrap();
            let checked = workspace.check("Generated.lean", None);
            if mutation == 0 {
                checked.unwrap();
            } else {
                let error = checked.unwrap_err();
                assert!(error.contains("Lean rejected Generated.lean"), "{error}");
            }
        }
    }
}
