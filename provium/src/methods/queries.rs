//! Complete shared queries returning Result<(), a source-resolved enum>.
//! Conditions are total reads of bool, Option and optional-array fields.
use super::*;

#[derive(Debug, Serialize)]
pub enum Test {
    Boolean(bool),
    Field(Vec<String>),
    Present(Vec<String>),
    AnyPresent(Vec<String>),
    Not(Box<Test>),
    And(Box<Test>, Box<Test>),
    Or(Box<Test>, Box<Test>),
}
#[derive(Debug, Serialize)]
pub enum Query {
    Success,
    Failure(String),
    Branch {
        condition: Test,
        yes: Box<Query>,
        no: Box<Query>,
    },
    Call {
        method: String,
        body: Box<Query>,
    },
}

pub(super) fn result_error(output: &syn::ReturnType) -> Result<String, String> {
    let syn::ReturnType::Type(_, ty) = output else {
        return Err("expected Result output".into());
    };
    let Type::Path(p) = &**ty else {
        return Err("expected Result output".into());
    };
    if p.qself.is_some() || p.path.segments.len() != 1 || p.path.segments[0].ident != "Result" {
        return Err("expected builtin Result".into());
    }
    let syn::PathArguments::AngleBracketed(args) = &p.path.segments[0].arguments else {
        return Err("missing Result arguments".into());
    };
    let arguments = args.args.iter().collect::<Vec<_>>();
    let [syn::GenericArgument::Type(Type::Tuple(unit)), syn::GenericArgument::Type(Type::Path(error))] =
        arguments.as_slice()
    else {
        return Err("query requires Result<(), Enum>".into());
    };
    if !unit.elems.is_empty()
        || error.qself.is_some()
        || error.path.segments.len() != 1
        || !matches!(error.path.segments[0].arguments, syn::PathArguments::None)
    {
        return Err("query requires Result<(), Enum>".into());
    }
    Ok(error.path.segments[0].ident.to_string())
}
fn option(ty: &Type) -> bool {
    matches!(ty, Type::Path(p) if p.qself.is_none() && p.path.segments.len()==1 && p.path.segments[0].ident=="Option" && matches!(&p.path.segments[0].arguments, syn::PathArguments::AngleBracketed(a) if a.args.len()==1 && matches!(a.args[0],syn::GenericArgument::Type(_))))
}
impl Crate {
    pub(super) fn lower_query(&self, name: &str, stack: &[String]) -> Result<Method, String> {
        self.lower_query_inner(name, stack, &std::cell::Cell::new(0))
    }
    fn lower_query_inner(
        &self,
        name: &str,
        stack: &[String],
        budget: &std::cell::Cell<usize>,
    ) -> Result<Method, String> {
        if stack.len() >= 32 || stack.iter().any(|s| s == name) {
            return Err("recursive/deep query requires termination semantics".into());
        }
        let mut stack = stack.to_vec();
        stack.push(name.into());
        let def = self.methods.get(name).ok_or("unknown query method")?;
        let sig = &def.item.sig;
        attrs(&def.item.attrs)?;
        if sig.asyncness.is_some()
            || sig.unsafety.is_some()
            || sig.constness.is_some()
            || sig.abi.is_some()
            || !sig.generics.params.is_empty()
            || sig.generics.where_clause.is_some()
            || sig.inputs.len() != 1
        {
            return Err("query requires a plain shared receiver-only signature".into());
        }
        let Some(syn::FnArg::Receiver(r)) = sig.inputs.first() else {
            return Err("missing query receiver".into());
        };
        attrs(&r.attrs)?;
        if r.reference.is_none() || r.mutability.is_some() || r.colon_token.is_some() {
            return Err("query requires &self".into());
        }
        self.resolve(&def.module, &def.receiver, 0)?;
        let structure = self
            .structs
            .get(&def.receiver)
            .ok_or("query receiver must be a struct")?;
        if structure.generics.type_params().any(|p| {
            ["Result", "Option", "bool", "Ok", "Err"]
                .iter()
                .any(|n| p.ident == *n)
        }) {
            return Err("shadowed query prelude type".into());
        }
        let error = result_error(&sig.output)?;
        let error = self.resolve(&def.module, &error, 0)?;
        let enumeration = self
            .enums
            .get(&error)
            .ok_or("query error must resolve to an enum")?;
        if !enumeration.generics.params.is_empty() || enumeration.generics.where_clause.is_some() {
            return Err("generic query error unsupported".into());
        }
        for a in &enumeration.attrs {
            if a.path().is_ident("derive") {
                let derives = a
                    .parse_args_with(
                        syn::punctuated::Punctuated::<syn::Ident, syn::Token![,]>::parse_terminated,
                    )
                    .map_err(|e| e.to_string())?;
                if !derives.iter().all(|d| {
                    ["Clone", "Copy", "Debug", "Default", "Eq", "PartialEq"]
                        .iter()
                        .any(|n| d == *n)
                }) {
                    return Err("query enum requires builtin derives".into());
                }
            }
            if !a.path().is_ident("doc") && !a.path().is_ident("derive") {
                return Err("conditional/attributed query enum unsupported".into());
            }
        }
        let query = self.query_block(def, &def.item.block, &error, &stack, budget)?;
        Ok(Method {
            name: name.into(),
            symbol: name.replace("::", "_"),
            source: def.file.clone(),
            first_line: def.item.span().start().line,
            last_line: def.item.span().end().line,
            rust: tokens(&def.item),
            writes: vec![],
            body: vec![],
            array: None,
            query: Some(query),
            iteration: None,
            last: None,
            truncation: None,
            installation: None,
            restoration: None,
            getter: None,
            enum_projection: None,
            validator: None,
            view: None,
            record_at: None,
            lookup: None,
            selection: None,
            relocation: None,
            buffer: None,
            constructor: None,
        })
    }
    fn query_block(
        &self,
        def: &Definition,
        block: &syn::Block,
        error: &str,
        stack: &[String],
        budget: &std::cell::Cell<usize>,
    ) -> Result<Query, String> {
        let [syn::Stmt::Expr(expr, None)] = block.stmts.as_slice() else {
            return Err(
                "query must translate its complete tail expression without discarded statements"
                    .into(),
            );
        };
        self.query_expr(def, expr, error, stack, budget)
    }
    fn query_expr(
        &self,
        def: &Definition,
        expr: &Expr,
        error: &str,
        stack: &[String],
        budget: &std::cell::Cell<usize>,
    ) -> Result<Query, String> {
        if budget.get() >= 4096 {
            return Err("query effect expansion exceeds budget".into());
        }
        budget.set(budget.get() + 1);
        match expr {
            Expr::If(i) => {
                attrs(&i.attrs)?;
                let (_, no) = i.else_branch.as_ref().ok_or("query branch requires else")?;
                Ok(Query::Branch {
                    condition: self.query_test(def, &i.cond)?,
                    yes: Box::new(self.query_block(def, &i.then_branch, error, stack, budget)?),
                    no: Box::new(self.query_expr(def, no, error, stack, budget)?),
                })
            }
            Expr::Block(b) if b.label.is_none() => {
                attrs(&b.attrs)?;
                self.query_block(def, &b.block, error, stack, budget)
            }
            Expr::Call(c) if c.args.len() == 1 => {
                attrs(&c.attrs)?;
                let Expr::Path(p) = &*c.func else {
                    return Err("query must return builtin Ok or Err".into());
                };
                attrs(&p.attrs)?;
                if p.qself.is_some() {
                    return Err("qualified query constructor unsupported".into());
                }
                if p.path.is_ident("Ok")
                    && matches!(&c.args[0],Expr::Tuple(t) if t.elems.is_empty() && t.attrs.is_empty())
                {
                    return Ok(Query::Success);
                }
                if p.path.is_ident("Err") {
                    let Expr::Path(variant) = &c.args[0] else {
                        return Err("expected unit enum variant".into());
                    };
                    attrs(&variant.attrs)?;
                    if variant.qself.is_some()
                        || variant.path.segments.len() != 2
                        || variant
                            .path
                            .segments
                            .iter()
                            .any(|s| !matches!(s.arguments, syn::PathArguments::None))
                    {
                        return Err("expected Enum::Variant".into());
                    }
                    if self.resolve(&def.module, &variant.path.segments[0].ident.to_string(), 0)?
                        != error
                    {
                        return Err("query error type mismatch".into());
                    }
                    let name = variant.path.segments[1].ident.to_string();
                    let variant = self.enums[error]
                        .variants
                        .iter()
                        .find(|v| v.ident == name)
                        .ok_or("unknown error variant")?;
                    attrs(&variant.attrs)?;
                    if !matches!(variant.fields, syn::Fields::Unit) {
                        return Err("query error variant must be unit".into());
                    }
                    return Ok(Query::Failure(format!("{error}::{name}")));
                }
                Err("unsupported query constructor".into())
            }
            Expr::MethodCall(c) => {
                attrs(&c.attrs)?;
                if !path(&c.receiver)?.is_empty() || !c.args.is_empty() || c.turbofish.is_some() {
                    return Err("query calls must be receiver-local and argument-free".into());
                }
                let name = format!("{}::{}::{}", def.module, def.receiver, c.method)
                    .trim_start_matches("::")
                    .to_owned();
                let callee = self.methods.get(&name).ok_or("unresolved query callee")?;
                let callee_error = result_error(&callee.item.sig.output)?;
                if self.resolve(&callee.module, &callee_error, 0)? != error {
                    return Err("query callee result mismatch".into());
                }
                let lowered = self.lower_query_inner(&name, stack, budget)?;
                Ok(Query::Call {
                    method: name,
                    body: Box::new(lowered.query.ok_or("callee is not a query")?),
                })
            }
            _ => Err(format!(
                "unsupported complete query expression {}",
                tokens(expr)
            )),
        }
    }
    fn query_test(&self, def: &Definition, e: &Expr) -> Result<Test, String> {
        match e {
            Expr::Lit(l) => {
                attrs(&l.attrs)?;
                if let syn::Lit::Bool(b) = &l.lit {
                    Ok(Test::Boolean(b.value))
                } else {
                    Err("expected bool".into())
                }
            }
            Expr::Field(_) => {
                let p = path(e)?;
                if tokens(self.field_type(def, &p)?) != "bool" {
                    return Err("expected boolean field".into());
                }
                Ok(Test::Field(p))
            }
            Expr::Paren(p) => {
                attrs(&p.attrs)?;
                self.query_test(def, &p.expr)
            }
            Expr::Unary(u) if matches!(u.op, syn::UnOp::Not(_)) => {
                attrs(&u.attrs)?;
                Ok(Test::Not(Box::new(self.query_test(def, &u.expr)?)))
            }
            Expr::Binary(b) => {
                attrs(&b.attrs)?;
                let a = Box::new(self.query_test(def, &b.left)?);
                let c = Box::new(self.query_test(def, &b.right)?);
                match b.op {
                    syn::BinOp::And(_) => Ok(Test::And(a, c)),
                    syn::BinOp::Or(_) => Ok(Test::Or(a, c)),
                    _ => Err("unsupported query boolean operator".into()),
                }
            }
            Expr::MethodCall(c)
                if c.method == "is_some" && c.args.is_empty() && c.turbofish.is_none() =>
            {
                attrs(&c.attrs)?;
                let p = path(&c.receiver)?;
                if !option(self.field_type(def, &p)?) {
                    return Err("is_some requires builtin Option field".into());
                }
                Ok(Test::Present(p))
            }
            Expr::MethodCall(c)
                if c.method == "any" && c.args.len() == 1 && c.turbofish.is_none() =>
            {
                attrs(&c.attrs)?;
                if self.array_iterator_shadow {
                    return Err("custom iterator traits require resolution".into());
                }
                let Expr::Path(predicate) = &c.args[0] else {
                    return Err("query any requires Option::is_some".into());
                };
                attrs(&predicate.attrs)?;
                if predicate.qself.is_some() || tokens(&predicate.path) != "Option :: is_some" {
                    return Err("query any requires builtin Option::is_some".into());
                }
                let Expr::MethodCall(iter) = &*c.receiver else {
                    return Err("query any requires array.iter()".into());
                };
                attrs(&iter.attrs)?;
                if iter.method != "iter" || !iter.args.is_empty() || iter.turbofish.is_some() {
                    return Err("query any requires array.iter()".into());
                }
                let p = path(&iter.receiver)?;
                let Type::Array(a) = self.field_type(def, &p)? else {
                    return Err("query requires a fixed array".into());
                };
                if !option(&a.elem) {
                    return Err("query requires optional array slots".into());
                }
                Ok(Test::AnyPresent(p))
            }
            _ => Err(format!(
                "unsupported complete query condition {}",
                tokens(e)
            )),
        }
    }
}
fn test(t: &Test) -> String {
    match t {
        Test::Boolean(b) => format!(".boolean {b}"),
        Test::Field(p) => format!(".field {}", lean_path(p)),
        Test::Present(p) => format!(".present {}", lean_path(p)),
        Test::AnyPresent(p) => format!(".anyPresent {}", lean_path(p)),
        Test::Not(t) => format!(".not ({})", test(t)),
        Test::And(a, b) => format!(".and ({}) ({})", test(a), test(b)),
        Test::Or(a, b) => format!(".or ({}) ({})", test(a), test(b)),
    }
}
fn program(q: &Query) -> String {
    match q {
        Query::Success => ".success".into(),
        Query::Failure(e) => format!(".failure {e:?}"),
        Query::Branch { condition, yes, no } => format!(
            ".branch ({}) ({}) ({})",
            test(condition),
            program(yes),
            program(no)
        ),
        Query::Call { body, .. } => program(body),
    }
}
pub(super) fn generate(method: &Method) -> String {
    let name = &method.symbol;
    let q = method.query.as_ref().unwrap();
    format!("def {name}_ir : Query := {}\ndef {name} (state : QueryStore α) : Except String Unit := runQuery {name}_ir state\ntheorem {name}_correspondence (state : QueryStore α) : runQuery {name}_ir state = {name} state := by rfl\n",program(q))
}
