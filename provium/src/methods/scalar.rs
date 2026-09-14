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
        impl VisitMut for Flatten<'_> {
            fn visit_ident_mut(&mut self, id: &mut syn::Ident) {
                if id.to_string().starts_with("provium_field_") {
                    self.error = Some(
                        "source identifier collides with reserved field parameter prefix".into(),
                    );
                }
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
            rust:tokens(f),fields,projections,
            scope:"successful-state projections of the complete explicit scalar method body; all statements execute in every projection; panic-store effects, frontend/field/borrow refinement and whole-Raft correctness are not proved",
        }})
    }
}
