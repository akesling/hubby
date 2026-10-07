//! Exhaustive borrowed enum matches that copy a primitive field. Every variant
//! and selected field is retained; this does not prove the Rust memory view.
use super::*;
#[derive(Clone, Debug, Serialize)]
pub struct Branch {
    pub variant: String,
    pub field: String,
}
#[derive(Debug, Serialize)]
pub struct Projection {
    pub receiver: String,
    pub branches: Vec<Branch>,
    pub arms: Vec<Vec<Branch>>,
    pub scope: &'static str,
}
fn alternatives(pattern: &syn::Pat) -> Result<Vec<&syn::PatStruct>, String> {
    match pattern {
        syn::Pat::Struct(p) => Ok(vec![p]),
        syn::Pat::Or(p) => {
            attrs(&p.attrs)?;
            p.cases
                .iter()
                .map(alternatives)
                .collect::<Result<Vec<_>, _>>()
                .map(|v| v.into_iter().flatten().collect())
        }
        _ => Err("enum projection requires explicit struct-variant patterns".into()),
    }
}
impl Crate {
    pub(super) fn lower_enum_projection(&self, name: &str) -> Result<Method, String> {
        let def = self.methods.get(name).ok_or("unknown enum projection")?;
        let f = &def.item;
        let sig = &f.sig;
        attrs(&f.attrs)?;
        if sig.asyncness.is_some()
            || sig.unsafety.is_some()
            || sig.constness.is_some()
            || sig.abi.is_some()
            || !sig.generics.params.is_empty()
            || sig.generics.where_clause.is_some()
            || sig.inputs.len() != 1
            || !matches!(&sig.output,syn::ReturnType::Type(_,t) if tokens(t)=="u64")
        {
            return Err("enum projection requires a plain shared receiver and u64 result".into());
        }
        let Some(syn::FnArg::Receiver(receiver)) = sig.inputs.first() else {
            return Err("enum projection requires &self".into());
        };
        attrs(&receiver.attrs)?;
        if receiver.reference.is_none()
            || receiver.mutability.is_some()
            || receiver.colon_token.is_some()
        {
            return Err("enum projection requires an ordinary shared borrow".into());
        }
        self.constructor_namespaces(def)?;
        let enumeration = self
            .enums
            .get(&def.receiver)
            .ok_or("projection receiver must be a source enum")?;
        if def.impl_generics.type_params().any(|p| p.ident == "u64")
            || enumeration.generics.type_params().any(|p| p.ident == "u64")
        {
            return Err("enum projection requires an unshadowed primitive".into());
        }
        for a in &enumeration.attrs {
            if a.path().is_ident("derive") {
                let derives = a
                    .parse_args_with(
                        syn::punctuated::Punctuated::<syn::Ident, syn::Token![,]>::parse_terminated,
                    )
                    .map_err(|_| "unresolved enum derive")?;
                if derives.iter().any(|d| {
                    ![
                        "Clone",
                        "Copy",
                        "Debug",
                        "Default",
                        "Eq",
                        "PartialEq",
                        "Ord",
                        "PartialOrd",
                        "Hash",
                    ]
                    .iter()
                    .any(|n| d == *n)
                }) {
                    return Err("enum projection rejects unresolved derive macros".into());
                }
            } else {
                attrs(std::slice::from_ref(a))?;
            }
        }
        for variant in &enumeration.variants {
            attrs(&variant.attrs)?;
            if variant.discriminant.is_some() {
                return Err("explicit enum discriminants are not modeled".into());
            }
            for field in &variant.fields {
                attrs(&field.attrs)?;
            }
        }
        let [syn::Stmt::Expr(Expr::Match(m), None)] = f.block.stmts.as_slice() else {
            return Err("enum projection must retain one complete match expression".into());
        };
        attrs(&m.attrs)?;
        if !matches!(&*m.expr,Expr::Path(p) if p.attrs.is_empty() && p.qself.is_none() && p.path.is_ident("self"))
        {
            return Err("enum projection must match its shared receiver".into());
        }
        let mut branches = Vec::new();
        let mut arms = Vec::new();
        for arm in &m.arms {
            let first = branches.len();
            attrs(&arm.attrs)?;
            if arm.guard.is_some() {
                return Err("guarded enum projections are not modeled".into());
            }
            let Expr::Unary(deref) = &*arm.body else {
                return Err("enum projection must copy a bound primitive field".into());
            };
            attrs(&deref.attrs)?;
            if !matches!(deref.op, syn::UnOp::Deref(_)) {
                return Err("enum projection requires a field dereference".into());
            }
            let Expr::Path(returned) = &*deref.expr else {
                return Err("enum projection must return its binding".into());
            };
            attrs(&returned.attrs)?;
            for pattern in alternatives(&arm.pat)? {
                attrs(&pattern.attrs)?;
                if pattern.qself.is_some()
                    || pattern.path.leading_colon.is_some()
                    || pattern.path.segments.len() != 2
                    || pattern
                        .path
                        .segments
                        .iter()
                        .any(|s| !matches!(s.arguments, syn::PathArguments::None))
                {
                    return Err("enum variant path must resolve directly".into());
                }
                let owner = pattern.path.segments[0].ident.to_string();
                if owner != "Self" && self.resolve(&def.module, &owner, 0)? != def.receiver {
                    return Err("enum pattern uses a different receiver type".into());
                }
                let variant = pattern.path.segments[1].ident.to_string();
                let declaration = enumeration
                    .variants
                    .iter()
                    .find(|v| v.ident == variant)
                    .ok_or("unknown enum variant")?;
                if pattern.fields.len() != 1
                    || pattern.rest.is_none()
                    || !matches!(declaration.fields, syn::Fields::Named(_))
                {
                    return Err(
                        "enum projection requires one named field and a rest pattern".into(),
                    );
                }
                attrs(&pattern.rest.as_ref().unwrap().attrs)?;
                let field = &pattern.fields[0];
                attrs(&field.attrs)?;
                let syn::Member::Named(member) = &field.member else {
                    return Err("enum projection requires a named field".into());
                };
                let syn::Pat::Ident(binding) = &*field.pat else {
                    return Err("enum projection requires a plain field binding".into());
                };
                attrs(&binding.attrs)?;
                if binding.by_ref.is_some()
                    || binding.mutability.is_some()
                    || binding.subpat.is_some()
                    || returned.qself.is_some()
                    || !returned.path.is_ident(&binding.ident.to_string())
                {
                    return Err("enum projection must copy the exact borrowed field binding".into());
                }
                let source_field = declaration
                    .fields
                    .iter()
                    .find(|f| f.ident.as_ref() == Some(member))
                    .ok_or("unknown enum field")?;
                if tokens(&source_field.ty) != "u64" {
                    return Err("enum projection requires a builtin u64 field".into());
                }
                if branches.iter().any(|b: &Branch| b.variant == variant) {
                    return Err("overlapping enum alternatives are not modeled".into());
                }
                branches.push(Branch {
                    variant,
                    field: member.to_string(),
                });
            }
            arms.push(branches[first..].to_vec());
        }
        if branches.len() != enumeration.variants.len() || branches.is_empty() {
            return Err("enum projection must explicitly cover every source variant".into());
        }
        Ok(Method{name:name.into(),symbol:name.replace("::","_"),source:def.file.clone(),first_line:f.span().start().line,last_line:f.span().end().line,rust:tokens(f),writes:vec![],body:vec![],array:None,query:None,constructor:None,buffer:None,relocation:None,iteration:None,last:None,truncation:None,installation:None,restoration:None,record_at:None,lookup:None,selection:None,imperative:None,validator:None,view:None,getter: None, enum_projection:Some(Projection{receiver:def.receiver.clone(),branches,arms,scope:"complete exhaustive borrowed enum field projection; physical discriminants, Rust borrows and frontend preservation remain unproved"})})
    }
}
pub(super) fn generate(method: &Method) -> String {
    let p = method.enum_projection.as_ref().unwrap();
    let branches = p
        .branches
        .iter()
        .map(|b| {
            format!(
                "({}, {})",
                serde_json::to_string(&b.variant).unwrap(),
                lean_path(std::slice::from_ref(&b.field))
            )
        })
        .collect::<Vec<_>>()
        .join(", ");
    let arms = p
        .arms
        .iter()
        .map(|arm| {
            let alternatives = arm
                .iter()
                .map(|b| {
                    format!(
                        "({}, {})",
                        serde_json::to_string(&b.variant).unwrap(),
                        lean_path(std::slice::from_ref(&b.field))
                    )
                })
                .collect::<Vec<_>>()
                .join(", ");
            format!("[{alternatives}]")
        })
        .collect::<Vec<_>>()
        .join(", ");
    let name = &method.symbol;
    format!("def {name}_source : List (List (String × Path)) := [{arms}]\ndef {name}_ir : List (String × Path) := [{branches}]\ndef {name} (state : EnumStore) : Option Nat := enumProjection {name}_ir state\ntheorem {name}_correspondence (state : EnumStore) :\n  enumMatch {name}_source state = {name} state := by\n  rw [enum_match_flatten]\n  rfl\n")
}
