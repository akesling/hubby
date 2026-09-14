use crate::ir::*;
use quote::ToTokens;
use std::collections::BTreeMap;
use syn::{
    spanned::Spanned, BinOp, Expr as RustExpr, FnArg, Item, ItemFn, Pat, ReturnType, Stmt, Type,
};

#[derive(Clone)]
struct Binding {
    name: String,
    ty: Ty,
    mutable: bool,
}
type Env = Vec<Binding>;
type Result<T> = std::result::Result<T, String>;
fn fail<T>(at: &impl Spanned, message: impl std::fmt::Display) -> Result<T> {
    let pos = at.span().start();
    Err(format!("{}:{}: {message}", pos.line, pos.column + 1))
}
fn attributes(attrs: &[syn::Attribute]) -> Result<()> {
    for attr in attrs {
        if !attr.path().is_ident("doc") {
            return fail(
                attr,
                "attributes other than doc comments are unsupported (including cfg)",
            );
        }
    }
    Ok(())
}
fn ty(value: &Type) -> Result<Ty> {
    if let Type::Path(path) = value {
        if path.qself.is_none()
            && path.path.leading_colon.is_none()
            && path.path.segments.len() == 1
            && matches!(path.path.segments[0].arguments, syn::PathArguments::None)
        {
            return match path.path.segments[0].ident.to_string().as_str() {
                "bool" => Ok(Ty::Bool),
                "u8" => Ok(Ty::U8),
                "u16" => Ok(Ty::U16),
                "u32" => Ok(Ty::U32),
                "u64" => Ok(Ty::U64),
                "usize" => Ok(Ty::Usize),
                _ => fail(
                    value,
                    "unsupported type: expected bool, u8/u16/u32/u64, or usize",
                ),
            };
        }
    }
    fail(value, "unsupported type: references, generics, aliases, and aggregates require additional semantics")
}
fn pattern(p: &Pat) -> Result<(String, bool, Option<Ty>)> {
    match p {
        Pat::Ident(p) if p.by_ref.is_none() && p.subpat.is_none() => {
            attributes(&p.attrs)?;
            Ok((p.ident.to_string(), p.mutability.is_some(), None))
        }
        Pat::Type(p) => {
            attributes(&p.attrs)?;
            let (name, mutable, _) = pattern(&p.pat)?;
            Ok((name, mutable, Some(ty(&p.ty)?)))
        }
        _ => fail(p, "only identifier bindings are supported"),
    }
}
fn path_name(e: &RustExpr) -> Option<String> {
    if let RustExpr::Path(p) = e {
        if p.qself.is_none()
            && p.path.leading_colon.is_none()
            && p.path.segments.len() == 1
            && matches!(p.path.segments[0].arguments, syn::PathArguments::None)
        {
            return Some(p.path.segments[0].ident.to_string());
        }
    }
    None
}
fn lookup<'a>(env: &'a Env, name: &str) -> Option<(usize, &'a Binding)> {
    env.iter().rev().enumerate().find(|(_, b)| b.name == name)
}

pub struct Compiler {
    functions: BTreeMap<String, ItemFn>,
    cache: BTreeMap<String, Function>,
    active: Vec<String>,
    pub usize_bits: u32,
}
impl Compiler {
    pub fn parse(source: &str, usize_bits: u32) -> Result<Self> {
        if !matches!(usize_bits, 32 | 64) {
            return Err("usize width must explicitly be 32 or 64".into());
        }
        let file = syn::parse_file(source).map_err(|e| format!("Rust parse error: {e}"))?;
        attributes(&file.attrs)?;
        let mut functions = BTreeMap::new();
        for item in file.items {
            let Item::Fn(function) = item else {
                return fail(&item, "only closed top-level functions are supported; imports, macros, modules, and impls are not silently skipped");
            };
            attributes(&function.attrs)?;
            let sig = &function.sig;
            if sig.asyncness.is_some()
                || sig.unsafety.is_some()
                || sig.abi.is_some()
                || sig.variadic.is_some()
                || !sig.generics.params.is_empty()
                || sig.generics.where_clause.is_some()
            {
                return fail(
                    sig,
                    "async, unsafe, ABI, variadic, and generic functions are unsupported",
                );
            }
            if functions
                .insert(sig.ident.to_string(), function.clone())
                .is_some()
            {
                return fail(sig, "duplicate function name");
            }
        }
        if functions.is_empty() {
            return Err("source contains no functions".into());
        }
        Ok(Self {
            functions,
            cache: BTreeMap::new(),
            active: vec![],
            usize_bits,
        })
    }
    pub fn compile(mut self) -> Result<Vec<Function>> {
        let names = self.functions.keys().cloned().collect::<Vec<_>>();
        for name in names {
            self.function(&name)?;
        }
        Ok(self.cache.into_values().collect())
    }
    fn signature(&self, item: &ItemFn) -> Result<(Vec<Parameter>, Env, Ty)> {
        let mut parameters = vec![];
        let mut env = vec![];
        for input in &item.sig.inputs {
            let FnArg::Typed(arg) = input else {
                return fail(input, "method receivers are unsupported");
            };
            attributes(&arg.attrs)?;
            let (name, mutable, _) = pattern(&arg.pat)?;
            if parameters.iter().any(|p: &Parameter| p.name == name) {
                return fail(input, "duplicate parameter");
            }
            let ty = ty(&arg.ty)?;
            parameters.push(Parameter {
                name: name.clone(),
                ty,
            });
            env.push(Binding { name, ty, mutable });
        }
        env.reverse();
        let ReturnType::Type(_, result) = &item.sig.output else {
            return fail(&item.sig, "explicit scalar return type required");
        };
        Ok((parameters, env, ty(result)?))
    }
    fn function(&mut self, name: &str) -> Result<Function> {
        if let Some(function) = self.cache.get(name) {
            return Ok(function.clone());
        }
        if self.active.iter().any(|n| n == name) {
            return Err(format!(
                "recursive call cycle involving {name} is unsupported"
            ));
        }
        if self.active.len() >= 32 {
            return Err("call expansion exceeds 32 functions".into());
        }
        let item = self.functions.get(name).cloned().ok_or_else(|| {
            format!("unresolved function {name}; external calls cannot be assumed pure")
        })?;
        let (parameters, env, result) = self.signature(&item)?;
        self.active.push(name.to_owned());
        let body = self.stmts(&item.block.stmts, &env, result, true)?;
        self.active.pop();
        if body.size() > 100_000 {
            return fail(&item, "expanded program exceeds 100,000 IR nodes");
        }
        let function = Function {
            name: name.into(),
            parameters,
            result,
            body,
            start_line: item.span().start().line,
            end_line: item.span().end().line,
            rust: item.to_token_stream().to_string(),
        };
        self.cache.insert(name.into(), function.clone());
        Ok(function)
    }
    fn stmts(&mut self, stmts: &[Stmt], env: &Env, result: Ty, assignments: bool) -> Result<Expr> {
        let Some((first, rest)) = stmts.split_first() else {
            return Err("scalar block must return an expression".into());
        };
        match first {
            Stmt::Local(local) => {
                attributes(&local.attrs)?;
                let (name, mutable, annotation) = pattern(&local.pat)?;
                let init = local.init.as_ref().ok_or_else(|| "uninitialized locals are unsupported".to_string())?;
                if init.diverge.is_some() { return fail(local, "let-else is unsupported"); }
                let value = self.expr(&init.expr, env, annotation)?;
                let mut inner = env.clone(); inner.push(Binding { name, ty: value.ty, mutable });
                let body = self.stmts(rest, &inner, result, assignments)?;
                Ok(Expr { ty: result, kind: Kind::Let { value: Box::new(value), body: Box::new(body) } })
            }
            Stmt::Expr(RustExpr::Binary(binary), Some(semi)) if matches!(binary.op, BinOp::BitXorAssign(_)) => {
                attributes(&binary.attrs)?;
                if path_name(&binary.left).is_none() { return fail(binary, "compound assignment requires a local variable"); }
                let left = &binary.left;
                let right = &binary.right;
                let assign: RustExpr = syn::parse_quote!(#left = #left ^ (#right));
                let mut normalized = vec![Stmt::Expr(assign, Some(*semi))];
                normalized.extend_from_slice(rest);
                self.stmts(&normalized, env, result, assignments)
            }
            Stmt::Expr(RustExpr::Assign(assign), Some(_)) => {
                attributes(&assign.attrs)?;
                if !assignments { return fail(assign, "assignments inside nested blocks require state-threading semantics"); }
                if let RustExpr::Path(p) = &*assign.left { attributes(&p.attrs)?; }
                let name = path_name(&assign.left).ok_or_else(|| "only local-variable assignment is supported".to_string())?;
                let (_, binding) = lookup(env, &name).ok_or_else(|| format!("unbound assignment target {name}"))?;
                if !binding.mutable { return fail(assign, "assignment to immutable local"); }
                let value = self.expr(&assign.right, env, Some(binding.ty))?;
                let mut inner = env.clone(); inner.push(Binding { name, ty: binding.ty, mutable: true });
                let body = self.stmts(rest, &inner, result, assignments)?;
                Ok(Expr { ty: result, kind: Kind::Let { value: Box::new(value), body: Box::new(body) } })
            }
            Stmt::Macro(stmt) => {
                attributes(&stmt.attrs)?;
                if !stmt.mac.path.is_ident("assert") { return fail(stmt, "only the builtin assert! macro is supported"); }
                let condition: RustExpr = syn::parse2(stmt.mac.tokens.clone()).map_err(|_| "assert! requires one condition without formatting arguments")?;
                let condition = self.expr(&condition, env, Some(Ty::Bool))?;
                let body = self.stmts(rest, env, result, assignments)?;
                Ok(Expr { ty: result, kind: Kind::Assert { condition: Box::new(condition), body: Box::new(body) } })
            }
            Stmt::Expr(expr, None) if rest.is_empty() => self.expr(expr, env, Some(result)),
            _ => fail(first, "unsupported statement; early returns, loops, branch mutations, nested items, and ignored expressions are rejected"),
        }
    }
    fn hint(&self, e: &RustExpr, env: &Env) -> Option<Ty> {
        match e {
            RustExpr::Path(_) => lookup(env, &path_name(e)?).map(|(_, b)| b.ty),
            RustExpr::Lit(e) => match &e.lit {
                syn::Lit::Bool(_) => Some(Ty::Bool),
                syn::Lit::Int(i) if !i.suffix().is_empty() => syn::parse_str::<Type>(i.suffix())
                    .ok()
                    .and_then(|t| ty(&t).ok()),
                _ => None,
            },
            RustExpr::Paren(e) => self.hint(&e.expr, env),
            RustExpr::Group(e) => self.hint(&e.expr, env),
            RustExpr::MethodCall(e) => self.hint(&e.receiver, env),
            RustExpr::Call(e) => {
                self.functions
                    .get(&path_name(&e.func)?)
                    .and_then(|f| match &f.sig.output {
                        ReturnType::Type(_, t) => ty(t).ok(),
                        _ => None,
                    })
            }
            RustExpr::Binary(e) => match e.op {
                BinOp::Eq(_)
                | BinOp::Ne(_)
                | BinOp::Lt(_)
                | BinOp::Le(_)
                | BinOp::Gt(_)
                | BinOp::Ge(_)
                | BinOp::And(_)
                | BinOp::Or(_) => Some(Ty::Bool),
                _ => self.hint(&e.left, env).or_else(|| self.hint(&e.right, env)),
            },
            _ => None,
        }
    }
    fn expr(&mut self, e: &RustExpr, env: &Env, expected: Option<Ty>) -> Result<Expr> {
        // Every supported expression checks its own attributes; all other syntax
        // is rejected, never translated as an opaque or assumed-pure operation.
        let output = match e {
            RustExpr::Path(p) => {
                attributes(&p.attrs)?;
                let name =
                    path_name(e).ok_or_else(|| "qualified paths are unsupported".to_string())?;
                let (index, binding) =
                    lookup(env, &name).ok_or_else(|| format!("unresolved value {name}"))?;
                Expr {
                    ty: binding.ty,
                    kind: Kind::Var(index),
                }
            }
            RustExpr::Lit(lit) => {
                attributes(&lit.attrs)?;
                match &lit.lit {
                    syn::Lit::Bool(b) => Expr {
                        ty: Ty::Bool,
                        kind: Kind::Bool(b.value),
                    },
                    syn::Lit::Int(i) => {
                        let annotation = if i.suffix().is_empty() {
                            None
                        } else {
                            Some(ty(&syn::parse_str::<Type>(i.suffix())
                                .map_err(|_| "invalid integer suffix")?)?)
                        };
                        let ty = annotation.or(expected).ok_or_else(|| "integer type cannot be inferred; add a supported unsigned suffix or annotation".to_string())?;
                        let bits = ty
                            .bits(self.usize_bits)
                            .ok_or_else(|| "integer literal in boolean context".to_string())?;
                        let value = i
                            .base10_parse::<u64>()
                            .map_err(|_| "literal exceeds supported unsigned range")?;
                        if value as u128 >= 1u128 << bits {
                            return fail(i, "integer literal overflows its Rust type");
                        }
                        Expr {
                            ty,
                            kind: Kind::UInt { bits, value },
                        }
                    }
                    _ => return fail(lit, "unsupported literal"),
                }
            }
            RustExpr::Paren(p) => {
                attributes(&p.attrs)?;
                self.expr(&p.expr, env, expected)?
            }
            RustExpr::Group(p) => {
                attributes(&p.attrs)?;
                self.expr(&p.expr, env, expected)?
            }
            RustExpr::Block(b) if b.label.is_none() => {
                attributes(&b.attrs)?;
                self.stmts(
                    &b.block.stmts,
                    env,
                    expected.ok_or_else(|| "block requires a known result type".to_string())?,
                    false,
                )?
            }
            RustExpr::Unary(u) if matches!(u.op, syn::UnOp::Not(_)) => {
                attributes(&u.attrs)?;
                let arg = self.expr(&u.expr, env, Some(Ty::Bool))?;
                Expr {
                    ty: Ty::Bool,
                    kind: Kind::Not(Box::new(arg)),
                }
            }
            RustExpr::Binary(b) => {
                attributes(&b.attrs)?;
                if matches!(b.op, BinOp::And(_) | BinOp::Or(_)) {
                    let left = self.expr(&b.left, env, Some(Ty::Bool))?;
                    let right = self.expr(&b.right, env, Some(Ty::Bool))?;
                    let lit = Expr {
                        ty: Ty::Bool,
                        kind: Kind::Bool(matches!(b.op, BinOp::Or(_))),
                    };
                    let (yes, no) = if matches!(b.op, BinOp::And(_)) {
                        (right, lit)
                    } else {
                        (lit, right)
                    };
                    Expr {
                        ty: Ty::Bool,
                        kind: Kind::If {
                            condition: Box::new(left),
                            yes: Box::new(yes),
                            no: Box::new(no),
                        },
                    }
                } else {
                    let op = match b.op {
                        BinOp::Add(_) => Op::Add,
                        BinOp::Sub(_) => Op::Sub,
                        BinOp::Mul(_) => Op::Mul,
                        BinOp::Div(_) => Op::Div,
                        BinOp::Rem(_) => Op::Rem,
                        BinOp::BitAnd(_) => Op::BitAnd,
                        BinOp::BitOr(_) => Op::BitOr,
                        BinOp::BitXor(_) => Op::BitXor,
                        BinOp::Shl(_) => Op::Shl,
                        BinOp::Shr(_) => Op::Shr,
                        BinOp::Eq(_) => Op::Eq,
                        BinOp::Ne(_) => Op::Ne,
                        BinOp::Lt(_) => Op::Lt,
                        BinOp::Le(_) => Op::Le,
                        BinOp::Gt(_) => Op::Gt,
                        BinOp::Ge(_) => Op::Ge,
                        _ => return fail(b, "unsupported binary operator"),
                    };
                    let operand = self
                        .hint(&b.left, env)
                        .or_else(|| self.hint(&b.right, env))
                        .or(if op.comparison() { None } else { expected });
                    let left = self.expr(&b.left, env, operand)?;
                    let right = self.expr(&b.right, env, Some(left.ty))?;
                    if left.ty == Ty::Bool && !matches!(op, Op::Eq | Op::Ne) {
                        return fail(b, "operator requires unsigned operands");
                    }
                    Expr {
                        ty: if op.comparison() { Ty::Bool } else { left.ty },
                        kind: Kind::Binary {
                            op,
                            left: Box::new(left),
                            right: Box::new(right),
                        },
                    }
                }
            }
            RustExpr::If(i) => {
                attributes(&i.attrs)?;
                let condition = self.expr(&i.cond, env, Some(Ty::Bool))?;
                let result = expected
                    .ok_or_else(|| "if expression needs an explicit result type".to_string())?;
                let yes = self.stmts(&i.then_branch.stmts, env, result, false)?;
                let no = self.expr(
                    &i.else_branch
                        .as_ref()
                        .ok_or_else(|| "if expression requires else".to_string())?
                        .1,
                    env,
                    Some(result),
                )?;
                Expr {
                    ty: result,
                    kind: Kind::If {
                        condition: Box::new(condition),
                        yes: Box::new(yes),
                        no: Box::new(no),
                    },
                }
            }
            RustExpr::MethodCall(m) => {
                attributes(&m.attrs)?;
                if m.args.len() != 1 || m.turbofish.is_some() {
                    return fail(
                        m,
                        "only supported unsigned intrinsic methods with one argument are allowed",
                    );
                }
                let op = match m.method.to_string().as_str() {
                    "min" => Op::Min,
                    "max" => Op::Max,
                    "saturating_add" => Op::SaturatingAdd,
                    "saturating_sub" => Op::SaturatingSub,
                    "wrapping_add" => Op::WrappingAdd,
                    "wrapping_sub" => Op::WrappingSub,
                    "wrapping_mul" => Op::WrappingMul,
                    _ => {
                        return fail(
                            m,
                            "unsupported method: no opaque call assumptions are generated",
                        )
                    }
                };
                let hint = self.hint(&m.receiver, env).or(expected);
                let left = self.expr(&m.receiver, env, hint)?;
                if left.ty == Ty::Bool {
                    return fail(m, "unsigned intrinsic on bool");
                }
                let right = self.expr(&m.args[0], env, Some(left.ty))?;
                Expr {
                    ty: left.ty,
                    kind: Kind::Binary {
                        op,
                        left: Box::new(left),
                        right: Box::new(right),
                    },
                }
            }
            RustExpr::Call(call) => {
                attributes(&call.attrs)?;
                let name = path_name(&call.func).ok_or_else(|| {
                    "only direct calls to source-local functions are supported".to_string()
                })?;
                if lookup(env, &name).is_some() {
                    return fail(call, "function name is shadowed by a local binding");
                }
                if let RustExpr::Path(p) = &*call.func {
                    attributes(&p.attrs)?;
                }
                let function = self.function(&name)?;
                if call.args.len() != function.parameters.len() {
                    return fail(call, "argument count mismatch");
                }
                let mut args = vec![];
                for (arg, p) in call.args.iter().zip(&function.parameters) {
                    args.push(self.expr(arg, env, Some(p.ty))?);
                }
                let count = args.len();
                let mut body = function.body.map_free(0, &|i| count - 1 - i);
                for (i, arg) in args.into_iter().enumerate().rev() {
                    body = Expr {
                        ty: function.result,
                        kind: Kind::Let {
                            value: Box::new(arg.map_free(0, &|v| v + i)),
                            body: Box::new(body),
                        },
                    };
                }
                body
            }
            _ => {
                return fail(
                    e,
                    format!("unsupported Rust expression: {}", e.to_token_stream()),
                )
            }
        };
        if expected.is_some_and(|ty| ty != output.ty) {
            return fail(
                e,
                format!(
                    "type mismatch: expected {expected:?}, found {:?}",
                    output.ty
                ),
            );
        }
        Ok(output)
    }
}
