//! Successful-state projections of complete scalar method bodies.
//! Every projection executes every statement before returning one written field.
//! Faults retain their order but do not describe the partially mutated Rust store.
use super::{attrs, path, tokens, Crate};
use quote::{format_ident, quote};
use serde::{Deserialize, Serialize};
use std::{collections::BTreeMap, path::PathBuf};
use syn::{spanned::Spanned, visit_mut::VisitMut, Expr, FnArg, ReturnType};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    pub crate_root: PathBuf,
    pub method: String,
}
#[derive(Clone, Debug, Serialize)]
pub struct Field {
    pub path: Vec<String>,
    pub rust_type: String,
    pub parameter: String,
    pub written: bool,
}
#[derive(Clone, Debug, Serialize)]
pub struct Evidence {
    pub method: String,
    pub source: PathBuf,
    pub first_line: usize,
    pub last_line: usize,
    pub rust: String,
    pub fields: Vec<Field>,
    pub projections: Vec<String>,
    pub constants: Vec<(String, String)>,
    pub scope: &'static str,
}
pub struct Translation {
    pub source: String,
    pub files: BTreeMap<PathBuf, String>,
    pub evidence: Evidence,
}
impl Crate {
    pub fn scalar_projections(&self, name: &str) -> Result<Translation, String> {
        let def = self.methods.get(name).ok_or("unknown scalar method")?;
        if !matches!(def.item.sig.output, ReturnType::Default) {
            return self.scalar_query(name);
        }
        let f = &def.item;
        attrs(&f.attrs)?;
        let sig = &f.sig;
        if sig.asyncness.is_some()
            || sig.unsafety.is_some()
            || sig.constness.is_some()
            || sig.abi.is_some()
            || !sig.generics.params.is_empty()
            || sig.generics.where_clause.is_some()
            || sig.inputs.len() != 1
            || !matches!(sig.output, ReturnType::Default)
        {
            return Err(
                "scalar method requires a synchronous unit-returning receiver-only signature"
                    .into(),
            );
        }
        let Some(FnArg::Receiver(receiver)) = sig.inputs.first() else {
            return Err("method requires receiver".into());
        };
        attrs(&receiver.attrs)?;
        if receiver.reference.is_none()
            || receiver.mutability.is_none()
            || receiver.colon_token.is_some()
        {
            return Err("scalar projections require &mut self".into());
        }
        self.resolve(&def.module, &def.receiver, 0)?;
        struct Flatten<'a> {
            krate: &'a Crate,
            def: &'a super::Definition,
            fields: BTreeMap<Vec<String>, Field>,
            error: Option<String>,
        }
        // Macro arguments are token streams that syn does not visit as syntax;
        // scan them too, or a reserved name inside `assert!` would be rebound.
        fn reserved_token(tokens: proc_macro2::TokenStream) -> bool {
            tokens.into_iter().any(|token| match token {
                proc_macro2::TokenTree::Ident(id) => id.to_string().starts_with("provium_field_"),
                proc_macro2::TokenTree::Group(group) => reserved_token(group.stream()),
                _ => false,
            })
        }
        impl VisitMut for Flatten<'_> {
            fn visit_ident_mut(&mut self, id: &mut syn::Ident) {
                if id.to_string().starts_with("provium_field_") {
                    self.error = Some(
                        "source identifier collides with reserved field parameter prefix".into(),
                    );
                }
            }
            fn visit_macro_mut(&mut self, mac: &mut syn::Macro) {
                if reserved_token(mac.tokens.clone()) {
                    self.error = Some(
                        "source identifier collides with reserved field parameter prefix".into(),
                    );
                }
                syn::visit_mut::visit_macro_mut(self, mac);
            }
            fn visit_expr_mut(&mut self, expr: &mut Expr) {
                if matches!(expr, Expr::Field(_)) {
                    let result = (|| {
                        let p = path(expr)?;
                        let ty = tokens(self.krate.field_type(self.def, &p)?);
                        if ty != "u64" {
                            return Err(
                                "scalar method fields currently require builtin u64".to_owned()
                            );
                        }
                        let parameter = format!("provium_field_{}", p.join("_"));
                        let field = self.fields.entry(p.clone()).or_insert_with(|| Field {
                            path: p,
                            rust_type: ty,
                            parameter,
                            written: false,
                        });
                        let id = format_ident!("{}", field.parameter);
                        *expr = syn::parse_quote!(#id);
                        Ok(())
                    })();
                    if let Err(error) = result {
                        self.error = Some(error);
                    }
                    return;
                }
                syn::visit_mut::visit_expr_mut(self, expr);
            }
        }
        let mut flat = Flatten {
            krate: self,
            def,
            fields: BTreeMap::new(),
            error: None,
        };
        // Record exact destinations before replacing field expressions. All other
        // syntax must subsequently pass the existing closed scalar frontend.
        let mut destinations = vec![];
        for stmt in &f.block.stmts {
            if let syn::Stmt::Expr(Expr::Assign(assign), Some(_)) = stmt {
                if matches!(&*assign.left, Expr::Field(_)) {
                    destinations.push(path(&assign.left)?);
                }
            }
        }
        for stmt in &f.block.stmts {
            if let syn::Stmt::Expr(Expr::Binary(binary), Some(_)) = stmt {
                if matches!(binary.op, syn::BinOp::BitXorAssign(_))
                    && matches!(&*binary.left, Expr::Field(_))
                {
                    destinations.push(path(&binary.left)?);
                }
            }
        }
        let mut body = f.block.clone();
        flat.visit_block_mut(&mut body);
        if let Some(error) = flat.error {
            return Err(error);
        }
        for p in destinations {
            flat.fields
                .get_mut(&p)
                .ok_or("unresolved destination")?
                .written = true;
        }
        if !flat.fields.values().any(|f| f.written) {
            return Err("scalar method must write at least one field".into());
        }
        let fields = flat.fields.into_values().collect::<Vec<_>>();
        unique_parameters(&fields)?;
        let parameters = fields
            .iter()
            .map(|f| {
                let id = format_ident!("{}", f.parameter);
                quote!(mut #id : u64)
            })
            .collect::<Vec<_>>();
        let mut source = String::new();
        let mut projections = vec![];
        for field in fields.iter().filter(|f| f.written) {
            let symbol = format!("{}_{}", name.replace("::", "_"), field.path.join("_"));
            let function = format_ident!("{symbol}");
            let result = format_ident!("{}", field.parameter);
            let stmts = &body.stmts;
            source.push_str(&tokens(
                &quote!(fn #function (#(#parameters),*) -> u64 { #(#stmts)* #result }),
            ));
            source.push('\n');
            projections.push(symbol);
        }
        Ok(Translation {source,files:self.files.clone(),evidence:Evidence {
            method:name.into(),source:def.file.clone(),first_line:f.span().start().line,last_line:f.span().end().line,
            rust:tokens(f),fields,projections,constants:vec![],
            scope:"successful-state projections of the complete explicit scalar method body; all statements execute in every projection; panic-store effects, frontend/field/borrow refinement and whole-program correctness are not proved",
        }})
    }

    fn scalar_query(&self, name: &str) -> Result<Translation, String> {
        let def = self.methods.get(name).ok_or("unknown scalar query")?;
        let f = &def.item;
        attrs(&f.attrs)?;
        let sig = &f.sig;
        if sig.asyncness.is_some()
            || sig.unsafety.is_some()
            || sig.constness.is_some()
            || sig.abi.is_some()
            || !sig.generics.params.is_empty()
            || sig.generics.where_clause.is_some()
            || sig.inputs.len() != 1
        {
            return Err("scalar query requires a plain receiver-only signature".into());
        }
        let Some(FnArg::Receiver(receiver)) = sig.inputs.first() else {
            return Err("scalar query needs &self".into());
        };
        attrs(&receiver.attrs)?;
        if receiver.reference.is_none()
            || receiver.mutability.is_some()
            || receiver.colon_token.is_some()
        {
            return Err("scalar query needs &self".into());
        }
        let ReturnType::Type(_, output) = &sig.output else {
            return Err("scalar query needs a return type".into());
        };
        fn builtin(ty: &syn::Type) -> bool {
            ["bool", "u8", "u16", "u32", "u64", "usize"].contains(&tokens(ty).as_str())
        }
        if !builtin(output) {
            return Err("scalar query must return a builtin scalar".into());
        }
        self.resolve(&def.module, &def.receiver, 0)?;
        let mut constants = BTreeMap::new();
        for constant in def.impl_generics.const_params() {
            attrs(&constant.attrs)?;
            if !builtin(&constant.ty) {
                return Err("scalar query const parameter must have builtin scalar type".into());
            }
            constants.insert(constant.ident.to_string(), constant.ty.clone());
        }
        struct Flatten<'a> {
            krate: &'a Crate,
            def: &'a super::Definition,
            constants: &'a BTreeMap<String, syn::Type>,
            fields: BTreeMap<Vec<String>, Field>,
            error: Option<String>,
        }
        impl VisitMut for Flatten<'_> {
            fn visit_ident_mut(&mut self, id: &mut syn::Ident) {
                if id.to_string().starts_with("provium_") {
                    self.error =
                        Some("source collides with reserved scalar query parameter prefix".into());
                }
            }
            fn visit_pat_ident_mut(&mut self, pat: &mut syn::PatIdent) {
                if self.constants.contains_key(&pat.ident.to_string()) {
                    self.error = Some("local pattern shadows a const parameter".into());
                }
                syn::visit_mut::visit_pat_ident_mut(self, pat);
            }
            fn visit_expr_mut(&mut self, expr: &mut Expr) {
                if matches!(expr, Expr::Field(_)) {
                    let result = (|| {
                        let path = path(expr)?;
                        let ty = self.krate.field_type(self.def, &path)?;
                        if !builtin(ty) {
                            return Err(
                                "scalar query reads require builtin scalar fields".to_owned()
                            );
                        }
                        let parameter = format!("provium_field_{}", path.join("_"));
                        self.fields.entry(path.clone()).or_insert(Field {
                            path,
                            rust_type: tokens(ty),
                            parameter: parameter.clone(),
                            written: false,
                        });
                        let id = format_ident!("{parameter}");
                        *expr = syn::parse_quote!(#id);
                        Ok(())
                    })();
                    if let Err(error) = result {
                        self.error = Some(error);
                    }
                    return;
                }
                if let Expr::Path(p) = expr {
                    if p.qself.is_none()
                        && p.path.segments.len() == 1
                        && matches!(p.path.segments[0].arguments, syn::PathArguments::None)
                        && self
                            .constants
                            .contains_key(&p.path.segments[0].ident.to_string())
                    {
                        if let Err(error) = attrs(&p.attrs) {
                            self.error = Some(error);
                            return;
                        }
                        let id = format_ident!("provium_const_{}", p.path.segments[0].ident);
                        *expr = syn::parse_quote!(#id);
                        return;
                    }
                }
                syn::visit_mut::visit_expr_mut(self, expr);
            }
        }
        let mut flat = Flatten {
            krate: self,
            def,
            constants: &constants,
            fields: BTreeMap::new(),
            error: None,
        };
        let mut body = f.block.clone();
        flat.visit_block_mut(&mut body);
        if let Some(error) = flat.error {
            return Err(error);
        }
        let fields = flat.fields.into_values().collect::<Vec<_>>();
        unique_parameters(&fields)?;
        let mut parameters = vec![];
        for field in &fields {
            let id = format_ident!("{}", field.parameter);
            let ty: syn::Type = syn::parse_str(&field.rust_type).map_err(|e| e.to_string())?;
            parameters.push(quote!(#id:#ty));
        }
        for (name, ty) in &constants {
            let id = format_ident!("provium_const_{name}");
            parameters.push(quote!(#id:#ty));
        }
        let symbol = name.replace("::", "_");
        let function = format_ident!("{symbol}");
        let source = tokens(&quote!(fn #function(#(#parameters),*) -> #output #body));
        Ok(Translation {source, files:self.files.clone(),evidence:Evidence {
            method:name.into(),source:def.file.clone(),first_line:f.span().start().line,last_line:f.span().end().line,rust:tokens(f),fields,projections:vec![symbol],constants:constants.into_iter().map(|(name,ty)|(name,tokens(&ty))).collect(),
            scope:"complete shared scalar method body with explicit original const parameters; all statements and scalar failure outcomes retained; source/field/borrow refinement remains trusted",
        }})
    }
}

// Keep the readable spelling used in proof statements, but reject ambiguity at
// the source boundary rather than emitting duplicate Rust parameter names.
fn unique_parameters(fields: &[Field]) -> Result<(), String> {
    let mut names = BTreeMap::new();
    for field in fields {
        if let Some(previous) = names.insert(&field.parameter, &field.path) {
            return Err(format!(
                "scalar field paths {} and {} collide as {}; unambiguous field encoding required",
                previous.join("."),
                field.path.join("."),
                field.parameter
            ));
        }
    }
    Ok(())
}
