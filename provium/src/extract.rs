//! Structural extraction of explicitly scoped expressions from ordinary Rust.
//! Bindings are abstraction assumptions, not inferred whole-program types.
use quote::{quote, ToTokens};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use syn::{spanned::Spanned, visit::Visit, visit_mut::VisitMut, Expr, Item, Stmt};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Binding {
    pub rust: String,
    pub name: String,
    pub ty: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Slice {
    pub source: PathBuf,
    pub method: String,
    pub name: String,
    /// Structural navigation, never a textual copy of the expression to prove.
    pub select: Vec<String>,
    pub bindings: Vec<Binding>,
    pub result: String,
    #[serde(default)]
    pub guarded_assignment_prefix: bool,
}
#[derive(Clone, Debug, Serialize)]
pub struct Evidence {
    pub selection: Slice,
    pub source_path: String,
    pub source_sha256: String,
    pub method_start_line: usize,
    pub method_end_line: usize,
    pub selected_lines: Vec<usize>,
    pub selected_rust: Vec<String>,
    pub abstracted_rust: String,
    pub scope: &'static str,
}
fn tokens(value: &impl ToTokens) -> String {
    value.to_token_stream().to_string()
}
fn block_tail(block: &syn::Block) -> Result<Expr, String> {
    match block.stmts.last() {
        Some(Stmt::Expr(e, None)) => Ok(e.clone()),
        _ => Err("selection requires a tail expression".into()),
    }
}
fn navigate(expr: Expr, step: &str) -> Result<Vec<Expr>, String> {
    let parts: Vec<_> = step.split(':').collect();
    let index = |i: usize| {
        parts
            .get(i)
            .ok_or("missing selector index")?
            .parse::<usize>()
            .map_err(|_| "invalid selector index")
    };
    match parts[0] {
        "tail" => {
            if let Expr::Block(b) = expr {
                return Ok(vec![block_tail(&b.block)?]);
            }
        }
        "let" => {
            if let Expr::Block(b) = expr {
                let matches = b
                    .block
                    .stmts
                    .iter()
                    .filter_map(|s| match s {
                        Stmt::Local(l) => match &l.pat {
                            syn::Pat::Ident(p)
                                if parts[1..].contains(&p.ident.to_string().as_str()) =>
                            {
                                l.init.as_ref().map(|i| *i.expr.clone())
                            }
                            _ => None,
                        },
                        _ => None,
                    })
                    .collect::<Vec<_>>();
                if parts.len() > 1 && matches.len() == parts.len() - 1 {
                    return Ok(matches);
                }
            }
        }
        "stmt" => {
            if let Expr::Block(b) = expr {
                if let Some(Stmt::Expr(e, _)) = b.block.stmts.get(index(1)?) {
                    return Ok(vec![e.clone()]);
                }
            }
        }
        "closure" => {
            if let Expr::Closure(c) = expr {
                return Ok(vec![*c.body]);
            }
        }
        "index" => {
            if let Expr::Index(i) = expr {
                return Ok(vec![*i.index]);
            }
        }
        "condition" => {
            if let Expr::If(i) = expr {
                return Ok(vec![*i.cond]);
            }
        }
        "right" => {
            if let Expr::Binary(b) = expr {
                return Ok(vec![*b.right]);
            }
        }
        "arg" => {
            if let Expr::MethodCall(c) = expr {
                if let Some(arg) = c.args.iter().nth(index(1)?) {
                    return Ok(vec![arg.clone()]);
                }
            }
        }
        "calls" => {
            struct Calls<'a> {
                name: &'a str,
                index: usize,
                found: Vec<Expr>,
                missing: bool,
            }
            impl<'ast> Visit<'ast> for Calls<'_> {
                fn visit_expr_method_call(&mut self, call: &'ast syn::ExprMethodCall) {
                    if call.method == self.name {
                        if let Some(arg) = call.args.iter().nth(self.index) {
                            self.found.push(arg.clone());
                        } else {
                            self.missing = true;
                        }
                    }
                    syn::visit::visit_expr_method_call(self, call);
                }
            }
            let mut calls = Calls {
                name: parts.get(1).ok_or("missing method selector")?,
                index: index(2)?,
                found: vec![],
                missing: false,
            };
            calls.visit_expr(&expr);
            if !calls.missing && calls.found.len() == index(3)? && !calls.found.is_empty() {
                return Ok(calls.found);
            }
        }
        _ => {}
    }
    Err(format!(
        "structural selector {step:?} did not match uniquely or had the wrong shape/count"
    ))
}
fn location(expr: &Expr) -> bool {
    match expr {
        Expr::Path(p) => {
            p.attrs.is_empty()
                && p.qself.is_none()
                && p.path.segments.len() == 1
                && matches!(p.path.segments[0].arguments, syn::PathArguments::None)
        }
        Expr::Field(f) => f.attrs.is_empty() && location(&f.base),
        _ => false,
    }
}
pub fn extract(source: &str, path: &str, slice: &Slice) -> Result<Evidence, String> {
    let file = syn::parse_file(source).map_err(|e| e.to_string())?;
    let parts = slice.method.split("::").collect::<Vec<_>>();
    if parts.len() != 2 {
        return Err("method must be Type::method".into());
    }
    let mut found = vec![];
    for item in &file.items {
        if let Item::Impl(implementation) = item {
            if implementation.trait_.is_some() {
                continue;
            }
            let syn::Type::Path(ty) = &*implementation.self_ty else {
                continue;
            };
            if ty.path.segments.last().is_none_or(|s| s.ident != parts[0]) {
                continue;
            }
            for member in &implementation.items {
                if let syn::ImplItem::Fn(method) = member {
                    if method.sig.ident == parts[1] {
                        if implementation
                            .attrs
                            .iter()
                            .chain(&method.attrs)
                            .any(|a| !a.path().is_ident("doc"))
                        {
                            return Err(
                                "conditional/attributed method extraction is unsupported".into()
                            );
                        }
                        found.push(method);
                    }
                }
            }
        }
    }
    if found.len() != 1 {
        return Err(format!(
            "{} must identify exactly one inherent method",
            slice.method
        ));
    }
    let method = found[0];
    struct Attributes {
        unsupported: bool,
    }
    impl<'ast> Visit<'ast> for Attributes {
        fn visit_attribute(&mut self, attr: &'ast syn::Attribute) {
            self.unsupported |= !attr.path().is_ident("doc");
        }
    }
    let mut attrs = Attributes { unsupported: false };
    attrs.visit_impl_item_fn(method);
    if attrs.unsupported {
        return Err("selected method contains unsupported attributes".into());
    }

    let block = &method.block;
    let mut selected = vec![syn::parse2::<Expr>(quote!(#block)).map_err(|e| e.to_string())?];
    for step in &slice.select {
        selected = selected
            .into_iter()
            .map(|e| navigate(e, step))
            .collect::<Result<Vec<_>, _>>()?
            .into_iter()
            .flatten()
            .collect();
    }
    let selected_lines = selected.iter().map(|e| e.span().start().line).collect();
    let selected_rust = selected.iter().map(tokens).collect();
    let mut mappings = vec![];
    let mut params = vec![];
    let mut names = std::collections::BTreeSet::new();
    let mut locations = std::collections::BTreeSet::new();
    for binding in &slice.bindings {
        let expression: Expr = syn::parse_str(&binding.rust).map_err(|e| e.to_string())?;
        if !location(&expression) {
            return Err("abstraction bindings must be simple variables or field paths".into());
        }
        let name: syn::Ident = syn::parse_str(&binding.name).map_err(|e| e.to_string())?;
        if !names.insert(binding.name.clone()) || !locations.insert(tokens(&expression)) {
            return Err("duplicate abstraction binding".into());
        }
        let ty: syn::Type = syn::parse_str(&binding.ty).map_err(|e| e.to_string())?;
        mappings.push((
            tokens(&expression),
            syn::parse2::<Expr>(quote!(#name)).map_err(|e| e.to_string())?,
        ));
        params.push(quote!(#name: #ty));
    }
    struct Abstract {
        mappings: Vec<(String, Expr)>,
    }
    impl VisitMut for Abstract {
        fn visit_expr_mut(&mut self, expr: &mut Expr) {
            if let Some((_, replacement)) = self.mappings.iter().find(|(s, _)| *s == tokens(expr)) {
                *expr = replacement.clone();
            } else {
                syn::visit_mut::visit_expr_mut(self, expr);
            }
        }
    }
    let mut abstractor = Abstract { mappings };
    let mut bodies = vec![];
    for mut expression in selected {
        if slice.guarded_assignment_prefix {
            let Expr::If(condition) = expression else {
                return Err("guarded assignment requires an if statement".into());
            };
            if condition.else_branch.is_some() {
                return Err("guarded assignment prefix with else is unsupported".into());
            }
            let Some(Stmt::Expr(Expr::Assign(assignment), Some(_))) =
                condition.then_branch.stmts.first()
            else {
                return Err("then branch must begin with the tracked assignment".into());
            };
            if !assignment.attrs.is_empty()
                || !condition.attrs.is_empty()
                || !locations.contains(&tokens(&assignment.left))
            {
                return Err(
                    "guarded target must be an explicit abstraction binding without attributes"
                        .into(),
                );
            }
            let (test, target, value) = (&condition.cond, &assignment.left, &assignment.right);
            // Semantics at this assignment point only. Subsequent method effects
            // remain outside the theorem, and are retained in source evidence.
            expression = syn::parse2(quote!(if #test { #value } else { #target }))
                .map_err(|e| e.to_string())?;
        }
        // A slice abstracts free scalar locations, never lexical binders or
        // macros whose names might have different meanings in the host crate.
        struct Binders {
            found: bool,
        }
        impl<'ast> Visit<'ast> for Binders {
            fn visit_pat(&mut self, _: &'ast syn::Pat) {
                self.found = true;
            }
            fn visit_macro(&mut self, _: &'ast syn::Macro) {
                self.found = true;
            }
        }
        let mut binders = Binders { found: false };
        binders.visit_expr(&expression);
        if binders.found {
            return Err("slices cannot contain binding patterns or macros; translate a closed function instead".into());
        }
        abstractor.visit_expr_mut(&mut expression);
        bodies.push(tokens(&expression));
    }
    if bodies.is_empty() || bodies.iter().any(|b| b != &bodies[0]) {
        return Err("selected occurrences differ; give each a separate slice and proof".into());
    }
    let name: syn::Ident = syn::parse_str(&slice.name).map_err(|e| e.to_string())?;
    let result: syn::Type = syn::parse_str(&slice.result).map_err(|e| e.to_string())?;
    let body: Expr = syn::parse_str(&bodies[0]).map_err(|e| e.to_string())?;
    Ok(Evidence {
        selection: slice.clone(),
        source_path: path.into(),
        source_sha256: crate::project::hash(source),
        method_start_line: method.span().start().line,
        method_end_line: method.span().end().line,
        selected_lines,
        selected_rust,
        abstracted_rust: quote!(fn #name(#(#params),*) -> #result { #body }).to_string(),
        scope: if slice.guarded_assignment_prefix {
            "value at the first guarded assignment; subsequent effects and whole-method behavior are not proved"
        } else {
            "selected scalar expression under explicitly declared binding types; enclosing control flow, provenance, and effects are not proved"
        },
    })
}
