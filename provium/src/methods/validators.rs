//! Complete pure, borrowed validators. Unsupported Rust is rejected; callbacks,
//! overloaded operators and mutation of the input are never opaque operations.
use super::*;
#[derive(Clone, Debug, PartialEq)]
enum Ty {
    Unit,
    Bool,
    Number(&'static str),
    Named(String),
    Ref(Box<Ty>),
    Option(Box<Ty>),
    Array(Box<Ty>),
}
impl Ty {
    fn value(&self) -> &Self {
        if let Self::Ref(t) = self {
            t.value()
        } else {
            self
        }
    }
}
#[derive(Clone)]
struct Binding {
    slot: usize,
    ty: Ty,
    mutable: bool,
}
#[derive(Clone)]
struct Closure {
    syntax: syn::ExprClosure,
    captures: BTreeMap<String, Binding>,
    closures: BTreeMap<String, Closure>,
}
#[derive(Debug, Serialize)]
pub struct Validator {
    pub input: String,
    pub expression: String,
    pub helpers: Vec<Method>,
    pub scope: &'static str,
}
struct Compiler<'a> {
    krate: &'a Crate,
    def: &'a Definition,
    env: BTreeMap<String, Binding>,
    closures: BTreeMap<String, Closure>,
    next: usize,
    helpers: Vec<Method>,
    call_depth: usize,
}
fn q(s: &str) -> String {
    serde_json::to_string(s).unwrap()
}
fn unit() -> String {
    ".literal .unit".into()
}
fn seq(a: String, b: String) -> String {
    format!(".sequence ({a}) ({b})")
}
fn path_name(e: &Expr) -> Result<String, String> {
    if let Expr::Path(p) = e {
        attrs(&p.attrs)?;
        if p.qself.is_none()
            && p.path.segments.len() == 1
            && matches!(p.path.segments[0].arguments, syn::PathArguments::None)
        {
            return Ok(p.path.segments[0].ident.to_string());
        }
    }
    Err("validator requires an unqualified local binding".into())
}
fn ident(p: &syn::Pat) -> Result<(String, bool), String> {
    if let syn::Pat::Ident(p) = p {
        attrs(&p.attrs)?;
        if ["Some", "None", "Ok", "Err"]
            .iter()
            .any(|name| p.ident == *name)
        {
            return Err("local binding shadows a builtin constructor".into());
        }
        if p.by_ref.is_none() && p.subpat.is_none() {
            return Ok((p.ident.to_string(), p.mutability.is_some()));
        }
    }
    Err("validator requires a plain local binding".into())
}
pub(super) fn candidate(f: &syn::ImplItemFn) -> bool {
    f.sig.inputs.len() == 1
        && matches!(f.sig.inputs.first(), Some(syn::FnArg::Typed(_)))
        && matches!(&f.sig.output,syn::ReturnType::Type(_,t) if tokens(t)=="bool")
}
impl Compiler<'_> {
    fn ty(&self, t: &Type) -> Result<Ty, String> {
        self.ty_in(t, &self.def.impl_generics, &self.def.module)
    }
    fn ty_in(&self, t: &Type, generics: &syn::Generics, module: &str) -> Result<Ty, String> {
        Ok(match t {
            Type::Reference(r) if r.mutability.is_none() => {
                Ty::Ref(Box::new(self.ty_in(&r.elem, generics, module)?))
            }
            Type::Array(a) => Ty::Array(Box::new(self.ty_in(&a.elem, generics, module)?)),
            Type::Path(p)
                if p.qself.is_none()
                    && p.path.leading_colon.is_none()
                    && p.path.segments.len() == 1 =>
            {
                let s = &p.path.segments[0];
                let name = s.ident.to_string();
                if generics
                    .type_params()
                    .any(|parameter| parameter.ident == name)
                {
                    return Err(format!("opaque generic validator type {name}"));
                }
                match name.as_str() {
                    "bool" => Ty::Bool,
                    "u64" => Ty::Number("u64"),
                    "i32" => return Err("signed source values are not modeled; i32 is reserved for inferred nonnegative locals".into()),
                    "Option" => {
                        let syn::PathArguments::AngleBracketed(a) = &s.arguments else {
                            return Err("invalid Option type".into());
                        };
                        if a.args.len() != 1 {
                            return Err("invalid Option arguments".into());
                        }
                        let syn::GenericArgument::Type(t) = &a.args[0] else {
                            return Err("invalid Option arguments".into());
                        };
                        Ty::Option(Box::new(self.ty_in(t, generics, module)?))
                    }
                    _ => Ty::Named(self.krate.resolve(module, &name, 0)?),
                }
            }
            _ => return Err(format!("unsupported validator type {}", tokens(t))),
        })
    }
    fn bind(&mut self, name: String, ty: Ty, mutable: bool) -> usize {
        let slot = self.next;
        self.next += 1;
        self.env.insert(name, Binding { slot, ty, mutable });
        slot
    }
    fn require(actual: &Ty, expected: &Ty) -> Result<(), String> {
        if actual == expected {
            Ok(())
        } else {
            Err(format!(
                "validator type mismatch: {actual:?} versus {expected:?}"
            ))
        }
    }
    fn copyable(&self, ty: &Ty) -> Result<(), String> {
        match ty {
            Ty::Bool | Ty::Number(_) | Ty::Ref(_) => Ok(()),
            Ty::Option(inner) => self.copyable(inner),
            Ty::Named(name) => {
                let s = self
                    .krate
                    .structs
                    .get(name)
                    .ok_or("copy requires a source record")?;
                self.derived(s, "Copy")?;
                for f in &s.fields {
                    let t = self.ty_in(&f.ty, &s.generics, &self.krate.struct_modules[name])?;
                    if !matches!(t, Ty::Bool | Ty::Number(_)) {
                        return Err("copied records require primitive fields".into());
                    }
                }
                Ok(())
            }
            _ => Err("moving a non-Copy validator value is not modeled".into()),
        }
    }
    fn derived(&self, s: &syn::ItemStruct, required: &str) -> Result<(), String> {
        let mut found = false;
        for a in &s.attrs {
            if a.path().is_ident("derive") {
                let names = a
                    .parse_args_with(
                        syn::punctuated::Punctuated::<syn::Ident, syn::Token![,]>::parse_terminated,
                    )
                    .map_err(|_| "unresolved derive")?;
                for n in names {
                    if n == required {
                        found = true
                    }
                    if ![
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
                    .any(|v| n == *v)
                    {
                        return Err("unresolved record derive".into());
                    }
                }
            } else {
                attrs(std::slice::from_ref(a))?
            }
        }
        if found {
            Ok(())
        } else {
            Err(format!("validator requires derived {required}"))
        }
    }
    fn field(&self, ty: &Ty, member: &syn::Member) -> Result<Ty, String> {
        let Ty::Named(name) = ty.value() else {
            return Err("field receiver is not a record".into());
        };
        let s = self.krate.structs.get(name).ok_or("unknown record")?;
        let syn::Member::Named(member) = member else {
            return Err("unnamed fields are unsupported".into());
        };
        let f = s
            .fields
            .iter()
            .find(|f| f.ident.as_ref() == Some(member))
            .ok_or("unknown record field")?;
        attrs(&f.attrs)?;
        let ty = self.ty_in(&f.ty, &s.generics, &self.krate.struct_modules[name])?;
        self.copyable(&ty)?;
        Ok(ty)
    }
    fn record_equality(
        &mut self,
        left: String,
        right: String,
        name: &str,
    ) -> Result<String, String> {
        let s = self
            .krate
            .structs
            .get(name)
            .ok_or("equality requires a source record")?;
        self.derived(s, "PartialEq")?;
        self.copyable(&Ty::Named(name.to_owned()))?;
        let left_slot = self.next;
        let right_slot = self.next + 1;
        self.next += 2;
        let mut expression = ".literal (.boolean true)".to_string();
        for field in s.fields.iter().rev() {
            let member = field
                .ident
                .as_ref()
                .ok_or("unnamed equality field")?
                .to_string();
            expression = format!(".binary \"&&\" (.binary \"==\" (.field (.read {left_slot}) {}) (.field (.read {right_slot}) {})) ({expression})", q(&member), q(&member));
        }
        Ok(seq(
            format!(".write {left_slot} ({left})"),
            seq(format!(".write {right_slot} ({right})"), expression),
        ))
    }
    fn optional_record_equality(
        &mut self,
        left: String,
        right: String,
        name: &str,
    ) -> Result<String, String> {
        let left_slot = self.next;
        let right_slot = self.next + 1;
        let left_inner = self.next + 2;
        let right_inner = self.next + 3;
        self.next += 4;
        let equal = self.record_equality(
            format!(".read {left_inner}"),
            format!(".read {right_inner}"),
            name,
        )?;
        // Store both operands before inspecting their discriminants: an absent
        // left operand must not suppress evaluation of the right operand.
        let both_present = format!(".choose (.read {right_slot}) [(.present (.bind {right_inner}), {equal}), (.any, .literal (.boolean false))]");
        let left_absent = format!(".choose (.read {right_slot}) [(.present .any, .literal (.boolean false)), (.any, .literal (.boolean true))]");
        Ok(seq(format!(".write {left_slot} ({left})"), seq(format!(".write {right_slot} ({right})"), format!(".choose (.read {left_slot}) [(.present (.bind {left_inner}), {both_present}), (.any, {left_absent})]"))))
    }
    fn block(&mut self, b: &syn::Block) -> Result<(String, Ty), String> {
        let saved = self.env.clone();
        let saved_closures = self.closures.clone();
        let mut expressions = Vec::new();
        let mut result = Ty::Unit;
        for (i, s) in b.stmts.iter().enumerate() {
            match s {
                syn::Stmt::Local(l) => {
                    attrs(&l.attrs)?;
                    let (name, mutable) = ident(&l.pat)?;
                    let init = l.init.as_ref().ok_or("uninitialized validator local")?;
                    if init.diverge.is_some() {
                        return Err("let-else is not modeled".into());
                    }
                    if let Expr::Closure(c) = &*init.expr {
                        if mutable || self.env.values().any(|b| b.mutable) {
                            return Err("closures require immutable captures".into());
                        }
                        self.closures.insert(
                            name,
                            Closure {
                                syntax: c.clone(),
                                captures: self.env.clone(),
                                closures: self.closures.clone(),
                            },
                        );
                    } else {
                        let (expr, ty) = self.expr(&init.expr, None)?;
                        self.copyable(&ty)?;
                        let slot = self.bind(name, ty, mutable);
                        expressions.push(format!(".write {slot} ({expr})"));
                    }
                    result = Ty::Unit;
                }
                syn::Stmt::Expr(e, semi) => {
                    let (expr, ty) = self.expr(e, None)?;
                    expressions.push(expr);
                    result = if semi.is_none() && i + 1 == b.stmts.len() {
                        ty
                    } else {
                        Ty::Unit
                    };
                }
                _ => return Err("validator statement is not modeled".into()),
            }
        }
        if result == Ty::Unit {
            expressions.push(unit())
        }
        let expression = expressions
            .into_iter()
            .rev()
            .reduce(|tail, head| seq(head, tail))
            .unwrap_or_else(unit);
        self.env = saved;
        self.closures = saved_closures;
        Ok((expression, result))
    }
    fn closure(&mut self, c: &Closure, arg: (String, Ty)) -> Result<(String, Ty), String> {
        self.call_depth += 1;
        if self.call_depth > 64 {
            return Err("recursive or excessively deep validator closure".into());
        }
        let f = &c.syntax;
        attrs(&f.attrs)?;
        if f.asyncness.is_some()
            || f.movability.is_some()
            || f.capture.is_some()
            || f.constness.is_some()
            || f.inputs.len() != 1
            || !matches!(f.output, syn::ReturnType::Default)
        {
            return Err("unsupported pure closure".into());
        }
        // An explicit return in a closure has a different destination. Reject it
        // instead of treating it as a return from the enclosing validator.
        struct Returns(bool);
        impl<'ast> syn::visit::Visit<'ast> for Returns {
            fn visit_expr_return(&mut self, _: &'ast syn::ExprReturn) {
                self.0 = true
            }
        }
        let mut returns = Returns(false);
        syn::visit::Visit::visit_expr(&mut returns, &f.body);
        if returns.0 {
            return Err("closure return is not modeled".into());
        }
        let (pat, ty) = match &f.inputs[0] {
            syn::Pat::Type(t) => (&*t.pat, self.ty(&t.ty)?),
            p => (p, arg.1.clone()),
        };
        Self::require(&arg.1, &ty)?;
        let (name, mutable) = ident(pat)?;
        if mutable {
            return Err("mutable closure arguments are not modeled".into());
        }
        let saved = self.env.clone();
        let saved_closures = self.closures.clone();
        self.env = c.captures.clone();
        self.closures = c.closures.clone();
        let slot = self.bind(name, ty, false);
        let (body, result) = self.expr(&f.body, None)?;
        self.env = saved;
        self.closures = saved_closures;
        self.call_depth -= 1;
        Ok((seq(format!(".write {slot} ({})", arg.0), body), result))
    }
    fn pattern(&mut self, p: &syn::Pat, ty: &Ty) -> Result<String, String> {
        Ok(match p {
            syn::Pat::Wild(p) => {
                attrs(&p.attrs)?;
                ".any".into()
            }
            syn::Pat::Ident(_) => {
                let (name, mutable) = ident(p)?;
                if mutable {
                    return Err("mutable match binding is unsupported".into());
                }
                // An identifier naming a const, static, unit struct or import
                // is a value comparison in Rust, not a fresh catch-all binding.
                if self.krate.value_names.contains(&name)
                    || self
                        .krate
                        .imports
                        .keys()
                        .any(|(_, imported)| *imported == name)
                {
                    return Err(format!(
                        "identifier pattern {name} names a value in scope; constant patterns are unsupported"
                    ));
                }
                let slot = self.bind(name, ty.clone(), false);
                format!(".bind {slot}")
            }
            syn::Pat::TupleStruct(p) => {
                attrs(&p.attrs)?;
                if p.qself.is_some() || !p.path.is_ident("Some") || p.elems.len() != 1 {
                    return Err("unsupported tuple pattern".into());
                }
                let Ty::Option(inner) = ty.value() else {
                    return Err("Some pattern needs Option".into());
                };
                let inner = if matches!(ty, Ty::Ref(_)) {
                    Ty::Ref(inner.clone())
                } else {
                    *inner.clone()
                };
                format!(".present ({})", self.pattern(&p.elems[0], &inner)?)
            }
            syn::Pat::Struct(p) => {
                attrs(&p.attrs)?;
                if p.qself.is_some()
                    || p.path.leading_colon.is_some()
                    || p.path.segments.len() != 2
                    || p.path
                        .segments
                        .iter()
                        .any(|s| !matches!(s.arguments, syn::PathArguments::None))
                {
                    return Err("unresolved enum pattern".into());
                }
                let owner = self.krate.resolve(
                    &self.def.module,
                    &p.path.segments[0].ident.to_string(),
                    0,
                )?;
                Self::require(ty.value(), &Ty::Named(owner.clone()))?;
                let tag = p.path.segments[1].ident.to_string();
                let enumeration = self
                    .krate
                    .enums
                    .get(&owner)
                    .ok_or("pattern owner is not an enum")?;
                let variant = enumeration
                    .variants
                    .iter()
                    .find(|v| v.ident == tag)
                    .ok_or("unknown variant")?;
                attrs(&variant.attrs)?;
                let mut fields = Vec::new();
                for f in &p.fields {
                    attrs(&f.attrs)?;
                    let syn::Member::Named(member) = &f.member else {
                        return Err("unnamed pattern field".into());
                    };
                    let source = variant
                        .fields
                        .iter()
                        .find(|f| f.ident.as_ref() == Some(member))
                        .ok_or("unknown variant field")?;
                    attrs(&source.attrs)?;
                    let mut ty_field = self.ty_in(
                        &source.ty,
                        &enumeration.generics,
                        &self.krate.struct_modules[&owner],
                    )?;
                    if matches!(ty, Ty::Ref(_)) {
                        ty_field = Ty::Ref(Box::new(ty_field))
                    }
                    fields.push(format!(
                        "({}, {})",
                        q(&member.to_string()),
                        self.pattern(&f.pat, &ty_field)?
                    ));
                }
                if let Some(rest) = &p.rest {
                    attrs(&rest.attrs)?
                } else if p.fields.len() != variant.fields.len() {
                    return Err("incomplete pattern without rest".into());
                }
                format!(".variant {} {} [{}]", q(&owner), q(&tag), fields.join(", "))
            }
            _ => return Err("unsupported validator pattern".into()),
        })
    }
    fn arm(
        &mut self,
        p: &syn::Pat,
        ty: &Ty,
        body: &Expr,
    ) -> Result<Vec<(String, String, Ty)>, String> {
        if let syn::Pat::Or(p) = p {
            attrs(&p.attrs)?;
            let mut arms = Vec::new();
            for p in &p.cases {
                arms.extend(self.arm(p, ty, body)?)
            }
            return Ok(arms);
        }
        let saved = self.env.clone();
        let pattern = self.pattern(p, ty)?;
        let (body, result) = self.expr(body, None)?;
        self.env = saved;
        Ok(vec![(pattern, body, result)])
    }
    fn expr(&mut self, e: &Expr, expected: Option<&Ty>) -> Result<(String, Ty), String> {
        let out = match e {
            Expr::Paren(p) => {
                attrs(&p.attrs)?;
                self.expr(&p.expr, expected)?
            }
            Expr::Block(b) => {
                attrs(&b.attrs)?;
                if b.label.is_some() {
                    return Err("labeled block is unsupported".into());
                }
                self.block(&b.block)?
            }
            Expr::Path(_) => {
                let name = path_name(e)?;
                if name == "None" {
                    if self.krate.struct_modules.contains_key("None") {
                        return Err("shadowed None constructor".into());
                    }
                    let Some(ty @ Ty::Option(_)) = expected else {
                        return Err("None requires a known Option type".into());
                    };
                    return Ok((".literal .absent".into(), ty.clone()));
                }
                let b = self.env.get(&name).ok_or("unknown local")?;
                (format!(".read {}", b.slot), b.ty.clone())
            }
            Expr::Lit(l) => {
                attrs(&l.attrs)?;
                match &l.lit {
                    syn::Lit::Bool(b) => (format!(".literal (.boolean {})", b.value), Ty::Bool),
                    syn::Lit::Int(n) => {
                        let kind = if n.suffix().is_empty() {
                            match expected {
                                Some(Ty::Number(k)) => *k,
                                _ => "i32",
                            }
                        } else {
                            match n.suffix() {
                                "u64" => "u64",
                                "i32" => "i32",
                                _ => return Err("unsupported integer literal".into()),
                            }
                        };
                        let value = n
                            .base10_parse::<u64>()
                            .map_err(|_| "invalid integer literal")?;
                        if kind == "i32" && value > i32::MAX as u64 {
                            return Err("i32 literal overflow".into());
                        }
                        (
                            format!(".literal (.number {} {value})", q(kind)),
                            Ty::Number(kind),
                        )
                    }
                    _ => return Err("unsupported validator literal".into()),
                }
            }
            Expr::Field(f) => {
                attrs(&f.attrs)?;
                let (value, ty) = self.expr(&f.base, None)?;
                let result = self.field(&ty, &f.member)?;
                (
                    format!(".field ({value}) {}", q(&tokens(&f.member))),
                    result,
                )
            }
            Expr::Unary(u) => {
                attrs(&u.attrs)?;
                let (value, ty) = self.expr(&u.expr, None)?;
                match u.op {
                    syn::UnOp::Deref(_) => {
                        let Ty::Ref(inner) = ty else {
                            return Err("deref requires a borrow".into());
                        };
                        self.copyable(&inner)?;
                        (format!(".copy ({value})"), *inner)
                    }
                    syn::UnOp::Not(_) => {
                        Self::require(&ty, &Ty::Bool)?;
                        (format!(".negate ({value})"), Ty::Bool)
                    }
                    _ => return Err("unsupported unary operator".into()),
                }
            }
            Expr::Binary(b) => {
                attrs(&b.attrs)?;
                let op = tokens(&b.op);
                if op == "+=" {
                    let name = path_name(&b.left)?;
                    let binding = self
                        .env
                        .get(&name)
                        .ok_or("unknown assignment local")?
                        .clone();
                    if !binding.mutable || !matches!(binding.ty, Ty::Number(_)) {
                        return Err("add-assign needs a mutable integer local".into());
                    }
                    let (rhs, ty) = self.expr(&b.right, Some(&binding.ty))?;
                    Self::require(&ty, &binding.ty)?;
                    (
                        format!(
                            ".write {} (.binary \"+\" (.read {}) ({rhs}))",
                            binding.slot, binding.slot
                        ),
                        Ty::Unit,
                    )
                } else {
                    let (left, ty) = self.expr(&b.left, None)?;
                    let (right, other) = self.expr(&b.right, Some(&ty))?;
                    Self::require(&ty, &other)?;
                    if op == "&&" || op == "||" {
                        Self::require(&ty, &Ty::Bool)?
                    } else if matches!(op.as_str(), "==" | "!=") {
                        match &ty {
                            Ty::Number(_) | Ty::Bool => {}
                            Ty::Option(t) if matches!(&**t, Ty::Number(_)) => {}
                            Ty::Named(name) => {
                                let equal = self.record_equality(left, right, name)?;
                                return Ok((
                                    if op == "!=" {
                                        format!(".negate ({equal})")
                                    } else {
                                        equal
                                    },
                                    Ty::Bool,
                                ));
                            }
                            Ty::Option(inner) if matches!(&**inner, Ty::Named(_)) => {
                                let Ty::Named(name) = &**inner else {
                                    unreachable!()
                                };
                                let equal = self.optional_record_equality(left, right, name)?;
                                return Ok((
                                    if op == "!=" {
                                        format!(".negate ({equal})")
                                    } else {
                                        equal
                                    },
                                    Ty::Bool,
                                ));
                            }
                            _ => return Err("overloaded equality is not modeled".into()),
                        }
                    } else if !matches!(op.as_str(), ">" | "<" | ">=" | "<=")
                        || !matches!(ty, Ty::Number(_))
                    {
                        return Err("overloaded binary operator is not modeled".into());
                    }
                    (format!(".binary {} ({left}) ({right})", q(&op)), Ty::Bool)
                }
            }
            Expr::Assign(a) => {
                attrs(&a.attrs)?;
                let name = path_name(&a.left)?;
                let b = self
                    .env
                    .get(&name)
                    .ok_or("unknown assignment local")?
                    .clone();
                if !b.mutable {
                    return Err("assignment to immutable local".into());
                }
                let (value, ty) = self.expr(&a.right, Some(&b.ty))?;
                Self::require(&ty, &b.ty)?;
                self.copyable(&ty)?;
                (format!(".write {} ({value})", b.slot), Ty::Unit)
            }
            Expr::Return(r) => {
                attrs(&r.attrs)?;
                let (value, ty) =
                    self.expr(r.expr.as_ref().ok_or("bare return")?, Some(&Ty::Bool))?;
                Self::require(&ty, &Ty::Bool)?;
                (format!(".ret ({value})"), Ty::Unit)
            }
            Expr::If(i) => {
                attrs(&i.attrs)?;
                let no = if let Some((_, e)) = &i.else_branch {
                    Some(&**e)
                } else {
                    None
                };
                if let Expr::Let(l) = &*i.cond {
                    attrs(&l.attrs)?;
                    let (value, ty) = self.expr(&l.expr, None)?;
                    let saved = self.env.clone();
                    let pat = self.pattern(&l.pat, &ty)?;
                    let (yes, yt) = self.block(&i.then_branch)?;
                    self.env = saved;
                    let (no, nt) = if let Some(e) = no {
                        self.expr(e, None)?
                    } else {
                        (unit(), Ty::Unit)
                    };
                    Self::require(&yt, &nt)?;
                    (
                        format!(".choose ({value}) [({pat}, {yes}), (.any, {no})]"),
                        yt,
                    )
                } else {
                    let (condition, ct) = self.expr(&i.cond, Some(&Ty::Bool))?;
                    Self::require(&ct, &Ty::Bool)?;
                    let (yes, yt) = self.block(&i.then_branch)?;
                    let (no, nt) = if let Some(e) = no {
                        self.expr(e, None)?
                    } else {
                        (unit(), Ty::Unit)
                    };
                    Self::require(&yt, &nt)?;
                    (format!(".branch ({condition}) ({yes}) ({no})"), yt)
                }
            }
            Expr::Match(m) => {
                attrs(&m.attrs)?;
                let (value, ty) = self.expr(&m.expr, None)?;
                let mut result = None;
                let mut arms = Vec::new();
                for a in &m.arms {
                    attrs(&a.attrs)?;
                    if a.guard.is_some() {
                        return Err("guarded match is unsupported".into());
                    }
                    for (p, b, t) in self.arm(&a.pat, &ty, &a.body)? {
                        if let Some(r) = &result {
                            Self::require(&t, r)?
                        } else {
                            result = Some(t)
                        }
                        arms.push(format!("({p}, {b})"));
                    }
                }
                (
                    format!(".choose ({value}) [{}]", arms.join(", ")),
                    result.ok_or("empty validator match")?,
                )
            }
            Expr::ForLoop(f) => {
                attrs(&f.attrs)?;
                if f.label.is_some() {
                    return Err("labeled loop is unsupported".into());
                }
                let (value, ty) = self.expr(&f.expr, None)?;
                let Ty::Ref(inner) = ty else {
                    return Err("iteration requires a borrowed builtin array".into());
                };
                let Ty::Array(element) = *inner else {
                    return Err("custom IntoIterator is unsupported".into());
                };
                let (name, mutable) = ident(&f.pat)?;
                if mutable {
                    return Err("mutable loop binding is unsupported".into());
                }
                let saved = self.env.clone();
                let slot = self.bind(name, Ty::Ref(element), false);
                let (body, ty) = self.block(&f.body)?;
                Self::require(&ty, &Ty::Unit)?;
                self.env = saved;
                (format!(".each ({value}) {slot} ({body})"), Ty::Unit)
            }
            Expr::Call(c) => {
                attrs(&c.attrs)?;
                if let Ok(name) = path_name(&c.func) {
                    if name == "Some" && c.args.len() == 1 {
                        let expected = match expected {
                            Some(Ty::Option(t)) => Some(&**t),
                            _ => None,
                        };
                        let (value, ty) = self.expr(&c.args[0], expected)?;
                        (format!(".present ({value})"), Ty::Option(Box::new(ty)))
                    } else {
                        let closure = self
                            .closures
                            .get(&name)
                            .ok_or("opaque validator call")?
                            .clone();
                        if c.args.len() != 1 {
                            return Err("closure arity mismatch".into());
                        }
                        let arg = self.expr(&c.args[0], None)?;
                        self.closure(&closure, arg)?
                    }
                } else {
                    let Expr::Path(p) = &*c.func else {
                        return Err("unsupported call target".into());
                    };
                    if p.qself.is_some()
                        || p.path.leading_colon.is_some()
                        || p.path.segments.len() != 2
                        || p.path.segments[1].ident != "default"
                        || !c.args.is_empty()
                        || p.path
                            .segments
                            .iter()
                            .any(|s| !matches!(s.arguments, syn::PathArguments::None))
                    {
                        return Err("opaque associated call".into());
                    }
                    let name = self.krate.resolve(
                        &self.def.module,
                        &p.path.segments[0].ident.to_string(),
                        0,
                    )?;
                    if self
                        .krate
                        .methods
                        .values()
                        .any(|d| d.receiver == name && d.item.sig.ident == "default")
                    {
                        return Err("inherent default is not builtin derived Default".into());
                    }
                    let s = self
                        .krate
                        .structs
                        .get(&name)
                        .ok_or("default requires source record")?;
                    self.derived(s, "Default")?;
                    self.copyable(&Ty::Named(name.clone()))?;
                    let mut fields = Vec::new();
                    for f in &s.fields {
                        attrs(&f.attrs)?;
                        let value = match self.ty_in(
                            &f.ty,
                            &s.generics,
                            &self.krate.struct_modules[&name],
                        )? {
                            Ty::Number(k) => format!(".number {} 0", q(k)),
                            Ty::Bool => ".boolean false".into(),
                            _ => return Err("unsupported default field".into()),
                        };
                        fields.push(format!(
                            "({}, {value})",
                            q(&f.ident.as_ref().ok_or("unnamed default field")?.to_string())
                        ))
                    }
                    (
                        format!(".literal (.record {} [{}])", q(&name), fields.join(", ")),
                        Ty::Named(name),
                    )
                }
            }
            Expr::MethodCall(c) => {
                attrs(&c.attrs)?;
                if c.turbofish.is_some() {
                    return Err("method type arguments unsupported".into());
                }
                let (value, ty) = self.expr(&c.receiver, None)?;
                match c.method.to_string().as_str() {
                    "as_ref" if c.args.is_empty() => {
                        let Ty::Option(t) = ty.value() else {
                            return Err("as_ref requires Option".into());
                        };
                        (
                            format!(".copy ({value})"),
                            Ty::Option(Box::new(Ty::Ref(t.clone()))),
                        )
                    }
                    "is_none_or" if c.args.len() == 1 => {
                        let Ty::Option(t) = ty else {
                            return Err("is_none_or requires Option".into());
                        };
                        let Expr::Closure(c) = &c.args[0] else {
                            return Err("is_none_or needs a pure closure".into());
                        };
                        let slot = self.next;
                        self.next += 1;
                        let closure = Closure {
                            syntax: c.clone(),
                            captures: self.env.clone(),
                            closures: self.closures.clone(),
                        };
                        let (body, result) =
                            self.closure(&closure, (format!(".read {slot}"), *t))?;
                        Self::require(&result, &Ty::Bool)?;
                        (format!(".choose ({value}) [(.present (.bind {slot}), {body}), (.any, .literal (.boolean true))]"),Ty::Bool)
                    }
                    "checked_add" if c.args.len() == 1 => {
                        if !matches!(ty, Ty::Number(_)) {
                            return Err("checked_add requires builtin number".into());
                        }
                        let (rhs, rt) = self.expr(&c.args[0], Some(&ty))?;
                        Self::require(&rt, &ty)?;
                        (
                            format!(".binary \"checked_add\" ({value}) ({rhs})"),
                            Ty::Option(Box::new(ty)),
                        )
                    }
                    method @ ("min" | "max" | "saturating_add" | "saturating_sub"
                    | "checked_sub")
                        if c.args.len() == 1 =>
                    {
                        // Require a builtin value receiver. Automatically dereferencing
                        // a borrowed receiver needs additional trait-resolution evidence.
                        if matches!(method, "min" | "max")
                            && self.krate.trait_methods.contains(method)
                        {
                            return Err("unresolved trait method shadows builtin ordering".into());
                        }
                        Self::require(&ty, &Ty::Number("u64"))?;
                        let (rhs, rhs_type) = self.expr(&c.args[0], Some(&ty))?;
                        Self::require(&rhs_type, &ty)?;
                        let result = if method == "checked_sub" {
                            Ty::Option(Box::new(ty))
                        } else {
                            ty
                        };
                        (format!(".binary {} ({value}) ({rhs})", q(method)), result)
                    }
                    method if c.args.is_empty() => {
                        let Ty::Named(owner) = ty.value() else {
                            return Err("unknown borrowed helper receiver".into());
                        };
                        if !matches!(ty, Ty::Ref(_)) {
                            return Err("enum helper requires shared borrow".into());
                        }
                        let module = self
                            .krate
                            .struct_modules
                            .get(owner)
                            .ok_or("unknown helper module")?;
                        let helper_name = format!("{module}::{owner}::{method}");
                        let helper = self
                            .krate
                            .lower_enum_projection(helper_name.trim_start_matches("::"))?;
                        let projection = helper.enum_projection.as_ref().unwrap();
                        let mut arms = Vec::new();
                        for b in &projection.branches {
                            let slot = self.next;
                            self.next += 1;
                            arms.push(format!(
                                "(.variant {} {} [({}, .bind {slot})], .read {slot})",
                                q(owner),
                                q(&b.variant),
                                q(&b.field)
                            ))
                        }
                        self.helpers.push(helper);
                        (
                            format!(".choose ({value}) [{}]", arms.join(", ")),
                            Ty::Number("u64"),
                        )
                    }
                    _ => return Err("opaque validator method call".into()),
                }
            }
            _ => return Err(format!("unsupported validator expression {}", tokens(e))),
        };
        if let Some(expected) = expected {
            Self::require(&out.1, expected)?
        }
        Ok(out)
    }
}
impl Crate {
    pub(super) fn lower_validator(&self, name: &str) -> Result<Method, String> {
        let def = self.methods.get(name).ok_or("unknown validator")?;
        let f = &def.item;
        attrs(&f.attrs)?;
        if !candidate(f)
            || f.sig.asyncness.is_some()
            || f.sig.constness.is_some()
            || f.sig.unsafety.is_some()
            || f.sig.abi.is_some()
            || !f.sig.generics.params.is_empty()
            || f.sig.generics.where_clause.is_some()
        {
            return Err("validator requires a plain borrowed static function".into());
        }
        self.constructor_namespaces(def)?;
        if def.impl_generics.type_params().any(|p| {
            ["bool", "u64", "i32", "Option"]
                .iter()
                .any(|n| p.ident == *n)
        }) {
            return Err("shadowed validator primitive".into());
        }
        for generics in self
            .structs
            .values()
            .map(|s| &s.generics)
            .chain(self.enums.values().map(|e| &e.generics))
        {
            if generics.type_params().any(|p| {
                ["bool", "u64", "i32", "Option"]
                    .iter()
                    .any(|name| p.ident == *name)
            }) {
                return Err("source generic shadows a validator primitive".into());
            }
        }
        let syn::FnArg::Typed(arg) = &f.sig.inputs[0] else {
            unreachable!()
        };
        attrs(&arg.attrs)?;
        let mut compiler = Compiler {
            krate: self,
            def,
            env: BTreeMap::new(),
            closures: BTreeMap::new(),
            next: 0,
            helpers: Vec::new(),
            call_depth: 0,
        };
        let ty = compiler.ty(&arg.ty)?;
        let Ty::Ref(inner) = &ty else {
            return Err("validator input requires shared borrow".into());
        };
        let Ty::Named(input) = &**inner else {
            return Err("validator input requires named source enum".into());
        };
        if !self.enums.contains_key(input) {
            return Err("validator input must be an enum".into());
        }
        let input = input.clone();
        let (binding, mutable) = ident(&arg.pat)?;
        if mutable {
            return Err("mutable validator input binding".into());
        }
        compiler.bind(binding, ty, false);
        let (expression, result) = compiler.block(&f.block)?;
        Compiler::require(&result, &Ty::Bool)?;
        Ok(Method{name:name.into(),symbol:name.replace("::","_"),source:def.file.clone(),first_line:f.span().start().line,last_line:f.span().end().line,rust:tokens(f),writes:vec![],body:vec![],array:None,query:None,constructor:None,buffer:None,relocation:None,iteration:None,last:None,truncation:None,installation:None,restoration:None,record_at:None,lookup:None,selection:None,getter: None, enum_projection:None,view:None,validator:Some(Validator{input,expression,helpers:compiler.helpers,scope:"complete restricted pure borrowed body with explicit fuel and structural inputs; frontend, borrow/layout preservation and totality remain unproved"})})
    }
}
pub(super) fn generate(method: &Method) -> String {
    let v = method.validator.as_ref().unwrap();
    let name = &method.symbol;
    format!("def {name}_ir : PureExpr := {}\ndef {name} (fuel : Nat) (input : PureValue) : Except PureFault Bool := pureValidate fuel {name}_ir input\ntheorem {name}_correspondence (fuel : Nat) (input : PureValue) : pureValidate fuel {name}_ir input = {name} fuel input := by rfl\n",v.expression)
}
