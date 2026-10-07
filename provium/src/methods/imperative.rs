//! Complete method bodies that read and mutate their receiver, lowered to the
//! value-semantics machine in `Provium.Imperative`. The receiver is one value
//! in slot 0 and parameters follow it; same-type method calls on `self` are
//! inlined. Fields the body never reads may have any type, so a receiver with
//! generic payloads is still a single record value whose untouched fields are
//! carried unchanged. Unsupported Rust is rejected: closures, loops, traits,
//! references, `?` and calls outside the receiver's own methods.
use super::*;

#[derive(Clone, Debug, PartialEq)]
enum Ty {
    Unit,
    Bool,
    Number(&'static str),
    Named(String),
    Option(Box<Ty>),
    Array(Box<Ty>),
    /// A type the machine never inspects: generic parameters, function
    /// pointers, tuples and references. Values of it can only be carried.
    Opaque,
}

#[derive(Debug, Serialize)]
pub struct Imperative {
    pub expression: String,
    pub parameters: usize,
    pub mutable_receiver: bool,
    pub inlined: Vec<String>,
    pub scope: &'static str,
}

#[derive(Clone)]
struct Binding {
    slot: usize,
    ty: Ty,
    mutable: bool,
}

/// An assignable place: the slot it is rooted in, the access path within
/// that slot's value, its type, the index evaluations that must run before the
/// path is used, and whether it may be written.
struct Place {
    slot: usize,
    path: Vec<String>,
    ty: Ty,
    setup: Vec<String>,
    mutable: bool,
}

/// One method body being compiled: its definition supplies the module and
/// generics against which its syntax is resolved.
#[derive(Clone, Copy)]
struct Frame<'a> {
    def: &'a Definition,
    mutable_receiver: bool,
    output: &'a Ty,
}

struct Compiler<'a> {
    krate: &'a Crate,
    env: BTreeMap<String, Binding>,
    next: usize,
    inlined: Vec<String>,
    stack: Vec<String>,
}

const NUMBERS: &[&str] = &["u8", "u16", "u32", "u64", "usize"];
const BUILTIN_METHODS: &[&str] = &[
    "wrapping_add",
    "wrapping_sub",
    "wrapping_mul",
    "saturating_add",
    "saturating_sub",
    "checked_add",
    "checked_sub",
    "min",
    "max",
    "is_some",
    "is_none",
];

fn q(s: &str) -> String {
    serde_json::to_string(s).unwrap()
}
fn unit() -> String {
    ".literal .unit".into()
}
fn seq(a: String, b: String) -> String {
    format!(".sequence ({a}) ({b})")
}
fn number(name: &str) -> Option<&'static str> {
    NUMBERS.iter().copied().find(|n| *n == name)
}
fn untyped(e: &Expr) -> bool {
    match e {
        Expr::Paren(p) => untyped(&p.expr),
        Expr::Lit(l) => matches!(&l.lit, syn::Lit::Int(n) if n.suffix().is_empty()),
        _ => false,
    }
}
fn ident(p: &syn::Pat) -> Result<(String, bool), String> {
    let syn::Pat::Ident(i) = p else {
        return Err("binding must be a plain identifier".into());
    };
    attrs(&i.attrs)?;
    if i.by_ref.is_some() || i.subpat.is_some() {
        return Err("binding must be a plain identifier".into());
    }
    Ok((i.ident.to_string(), i.mutability.is_some()))
}
fn single(p: &syn::Path) -> Option<String> {
    (p.leading_colon.is_none()
        && p.segments.len() == 1
        && matches!(p.segments[0].arguments, syn::PathArguments::None))
    .then(|| p.segments[0].ident.to_string())
}

pub(super) fn candidate(f: &syn::ImplItemFn) -> bool {
    matches!(f.sig.inputs.first(), Some(syn::FnArg::Receiver(r)) if r.reference.is_some())
}

impl Compiler<'_> {
    fn ty_in(
        &self,
        t: &Type,
        generics: &syn::Generics,
        module: &str,
        receiver: &str,
    ) -> Result<Ty, String> {
        Ok(match t {
            Type::Paren(p) => self.ty_in(&p.elem, generics, module, receiver)?,
            Type::Array(a) => Ty::Array(Box::new(self.ty_in(&a.elem, generics, module, receiver)?)),
            Type::Path(p)
                if p.qself.is_none()
                    && p.path.leading_colon.is_none()
                    && p.path.segments.len() == 1 =>
            {
                let s = &p.path.segments[0];
                let name = s.ident.to_string();
                if generics.type_params().any(|g| g.ident == name) {
                    return Ok(Ty::Opaque);
                }
                if name == "Self" {
                    return Ok(Ty::Named(receiver.to_owned()));
                }
                if let Some(kind) = number(&name) {
                    return Ok(Ty::Number(kind));
                }
                match name.as_str() {
                    "bool" => Ty::Bool,
                    "Option" => {
                        let syn::PathArguments::AngleBracketed(a) = &s.arguments else {
                            return Err("Option requires one type argument".into());
                        };
                        let [syn::GenericArgument::Type(inner)] =
                            a.args.iter().collect::<Vec<_>>()[..]
                        else {
                            return Err("Option requires one type argument".into());
                        };
                        Ty::Option(Box::new(self.ty_in(inner, generics, module, receiver)?))
                    }
                    _ => {
                        let resolved = self.krate.resolve(module, &name, 0)?;
                        if self.krate.structs.contains_key(&resolved)
                            || self.krate.enums.contains_key(&resolved)
                        {
                            Ty::Named(resolved)
                        } else {
                            Ty::Opaque
                        }
                    }
                }
            }
            _ => Ty::Opaque,
        })
    }
    fn ty(&self, frame: Frame, t: &Type) -> Result<Ty, String> {
        self.ty_in(
            t,
            &frame.def.impl_generics,
            &frame.def.module,
            &frame.def.receiver,
        )
    }
    fn bind(&mut self, name: String, ty: Ty, mutable: bool) -> usize {
        let slot = self.fresh();
        self.env.insert(name, Binding { slot, ty, mutable });
        slot
    }
    fn fresh(&mut self) -> usize {
        let slot = self.next;
        self.next += 1;
        slot
    }
    fn require(actual: &Ty, expected: &Ty) -> Result<(), String> {
        if actual == expected {
            Ok(())
        } else {
            Err(format!(
                "imperative type mismatch: {actual:?} versus {expected:?}"
            ))
        }
    }
    fn derives(attrs_list: &[syn::Attribute], required: &str) -> Result<bool, String> {
        let mut found = false;
        for a in attrs_list {
            if a.path().is_ident("derive") {
                let names = a
                    .parse_args_with(
                        syn::punctuated::Punctuated::<syn::Path, syn::Token![,]>::parse_terminated,
                    )
                    .map_err(|_| "unresolved derive")?;
                for n in names {
                    let Some(n) = single(&n) else {
                        return Err("qualified derive paths are unsupported".into());
                    };
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
                    .contains(&n.as_str())
                    {
                        return Err(format!("unresolved derive {n}"));
                    }
                    found |= n == required;
                }
            }
        }
        Ok(found)
    }
    /// Field types of a named record, or of one enum variant.
    fn members(&self, owner: &str, variant: Option<&str>) -> Result<Vec<(String, Ty)>, String> {
        let module = self
            .krate
            .struct_modules
            .get(owner)
            .ok_or("unknown type module")?;
        let (fields, generics) = if let Some(tag) = variant {
            let e = self
                .krate
                .enums
                .get(owner)
                .ok_or("variant owner is not an enum")?;
            let v = e
                .variants
                .iter()
                .find(|v| v.ident == tag)
                .ok_or("unknown variant")?;
            attrs(&v.attrs)?;
            if v.discriminant.is_some() {
                return Err("explicit discriminants are unsupported".into());
            }
            (&v.fields, &e.generics)
        } else {
            let s = self.krate.structs.get(owner).ok_or("unknown record")?;
            (&s.fields, &s.generics)
        };
        let mut out = vec![];
        for (i, f) in fields.iter().enumerate() {
            attrs(&f.attrs)?;
            let name = f
                .ident
                .as_ref()
                .map_or_else(|| i.to_string(), ToString::to_string);
            out.push((name, self.ty_in(&f.ty, generics, module, owner)?));
        }
        Ok(out)
    }
    /// A derived trait holds for the type and, structurally, for every part of
    /// it the derived implementation inspects.
    fn derived(&self, ty: &Ty, required: &str, depth: usize) -> Result<(), String> {
        if depth > 32 {
            return Err("recursive type in derived check".into());
        }
        match ty {
            Ty::Unit | Ty::Bool | Ty::Number(_) => Ok(()),
            Ty::Option(inner) => self.derived(inner, required, depth + 1),
            Ty::Array(inner) if required == "Copy" => self.derived(inner, required, depth + 1),
            Ty::Named(name) => {
                let (attributes, variants) = if let Some(s) = self.krate.structs.get(name) {
                    (&s.attrs, vec![None])
                } else {
                    let e = self.krate.enums.get(name).ok_or("unknown named type")?;
                    (
                        &e.attrs,
                        e.variants
                            .iter()
                            .map(|v| Some(v.ident.to_string()))
                            .collect(),
                    )
                };
                if !Self::derives(attributes, required)? {
                    return Err(format!("{name} must derive {required}"));
                }
                for variant in variants {
                    for (_, field) in self.members(name, variant.as_deref())? {
                        self.derived(&field, required, depth + 1)?;
                    }
                }
                Ok(())
            }
            _ => Err(format!("{required} is not modeled for {ty:?}")),
        }
    }
    fn field(&self, ty: &Ty, member: &syn::Member) -> Result<(String, Ty), String> {
        let Ty::Named(owner) = ty else {
            return Err("field access requires a named record".into());
        };
        let name = match member {
            syn::Member::Named(n) => n.to_string(),
            syn::Member::Unnamed(i) => i.index.to_string(),
        };
        let (_, field) = self
            .members(owner, None)?
            .into_iter()
            .find(|(n, _)| *n == name)
            .ok_or_else(|| format!("unknown field {name}"))?;
        Ok((name, field))
    }
    fn literal(&self, value: u64, kind: &'static str) -> Result<String, String> {
        let width = match kind {
            "u8" => 8,
            "u16" => 16,
            "u32" => 32,
            "u64" => 64,
            _ => self
                .krate
                .cfg
                .as_ref()
                .and_then(|c| c.pointer_width())
                .ok_or("usize literal requires the configured pointer width")?,
        };
        if width < 64 && value >> width != 0 {
            return Err("integer literal exceeds its type".into());
        }
        Ok(format!(".literal (.number {} {value})", q(kind)))
    }
    /// A place rooted at `self` or a local.
    fn place(&mut self, frame: Frame, e: &Expr) -> Result<Place, String> {
        match e {
            Expr::Paren(p) => {
                attrs(&p.attrs)?;
                self.place(frame, &p.expr)
            }
            Expr::Path(p) => {
                attrs(&p.attrs)?;
                let name = single(&p.path)
                    .filter(|_| p.qself.is_none())
                    .ok_or("unsupported place")?;
                if name == "self" {
                    return Ok(Place {
                        slot: 0,
                        path: vec![],
                        ty: Ty::Named(frame.def.receiver.clone()),
                        setup: vec![],
                        mutable: frame.mutable_receiver,
                    });
                }
                let b = self
                    .env
                    .get(&name)
                    .ok_or_else(|| format!("unknown local {name}"))?;
                Ok(Place {
                    slot: b.slot,
                    path: vec![],
                    ty: b.ty.clone(),
                    setup: vec![],
                    mutable: b.mutable,
                })
            }
            Expr::Field(f) => {
                attrs(&f.attrs)?;
                let mut place = self.place(frame, &f.base)?;
                let (name, field) = self.field(&place.ty, &f.member)?;
                place.path.push(format!(".field {}", q(&name)));
                place.ty = field;
                Ok(place)
            }
            Expr::Index(i) => {
                attrs(&i.attrs)?;
                let mut place = self.place(frame, &i.expr)?;
                let Ty::Array(element) = place.ty.clone() else {
                    return Err("indexing requires a builtin array".into());
                };
                let (index, index_ty) = self.expr(frame, &i.index, Some(&Ty::Number("usize")))?;
                Self::require(&index_ty, &Ty::Number("usize"))?;
                let position = self.fresh();
                place.setup.push(format!(".write {position} ({index})"));
                place.path.push(format!(".index {position}"));
                place.ty = *element;
                Ok(place)
            }
            _ => Err(format!("unsupported place {}", tokens(e))),
        }
    }
    fn store(
        &mut self,
        frame: Frame,
        target: &Expr,
        value: String,
        ty: &Ty,
    ) -> Result<String, String> {
        let Place {
            slot,
            path,
            ty: place_ty,
            setup,
            mutable,
        } = self.place(frame, target)?;
        if !mutable {
            return Err("assignment through an immutable place".into());
        }
        Self::require(ty, &place_ty)?;
        // Rust evaluates the assigned value before the place's index operands.
        let value_slot = self.fresh();
        let mut parts = vec![format!(".write {value_slot} ({value})")];
        parts.extend(setup);
        parts.push(if path.is_empty() {
            format!(".write {slot} (.read {value_slot})")
        } else {
            format!(".assign {slot} [{}] (.read {value_slot})", path.join(", "))
        });
        Ok(parts
            .into_iter()
            .rev()
            .reduce(|tail, head| seq(head, tail))
            .unwrap())
    }
    fn block(&mut self, frame: Frame, b: &syn::Block) -> Result<(String, Ty), String> {
        let saved = self.env.clone();
        let mut parts = vec![];
        let mut result = Ty::Unit;
        for (i, s) in b.stmts.iter().enumerate() {
            result = Ty::Unit;
            match s {
                syn::Stmt::Local(l) => {
                    attrs(&l.attrs)?;
                    let (pat, annotated) = match &l.pat {
                        syn::Pat::Type(t) => {
                            attrs(&t.attrs)?;
                            (&*t.pat, Some(self.ty(frame, &t.ty)?))
                        }
                        p => (p, None),
                    };
                    let (name, mutable) = ident(pat)?;
                    let init = l.init.as_ref().ok_or("uninitialized local")?;
                    if init.diverge.is_some() {
                        return Err("let-else is unsupported".into());
                    }
                    let (value, ty) = self.expr(frame, &init.expr, annotated.as_ref())?;
                    if let Some(a) = &annotated {
                        Self::require(&ty, a)?;
                    }
                    self.derived(&ty, "Copy", 0)?;
                    let slot = self.bind(name, ty, mutable);
                    parts.push(format!(".write {slot} ({value})"));
                }
                syn::Stmt::Expr(e, semi) => {
                    let (value, ty) = self.expr(frame, e, None)?;
                    parts.push(value);
                    if semi.is_none() && i + 1 == b.stmts.len() {
                        result = ty;
                    } else if semi.is_none() && ty != Ty::Unit {
                        return Err("non-unit expression statement without semicolon".into());
                    }
                }
                _ => return Err("unsupported statement".into()),
            }
        }
        if result == Ty::Unit {
            parts.push(unit());
        }
        self.env = saved;
        Ok((
            parts
                .into_iter()
                .rev()
                .reduce(|tail, head| seq(head, tail))
                .unwrap(),
            result,
        ))
    }
    fn pattern(&mut self, frame: Frame, p: &syn::Pat, ty: &Ty) -> Result<String, String> {
        Ok(match p {
            syn::Pat::Wild(w) => {
                attrs(&w.attrs)?;
                ".any".into()
            }
            syn::Pat::Ident(_) => {
                let (name, mutable) = ident(p)?;
                // `None` parses as an identifier pattern; RESERVED_NAMES keeps
                // the crate from declaring an item that would rebind it.
                if name == "None" && !mutable {
                    let Ty::Option(_) = ty else {
                        return Err("None pattern needs Option".into());
                    };
                    return Ok(".absent".into());
                }
                if self.krate.value_names.contains(&name)
                    || self
                        .krate
                        .imports
                        .keys()
                        .any(|(_, imported)| *imported == name)
                {
                    return Err(format!("identifier pattern {name} names a value; constant patterns are unsupported"));
                }
                self.derived(ty, "Copy", 0)?;
                format!(".bind {}", self.bind(name, ty.clone(), mutable))
            }
            syn::Pat::Path(path) => {
                attrs(&path.attrs)?;
                if path.qself.is_none() && path.path.is_ident("None") {
                    let Ty::Option(_) = ty else {
                        return Err("None pattern needs Option".into());
                    };
                    return Ok(".absent".into());
                }
                let (owner, tag) = self.variant_path(frame, &path.path)?;
                Self::require(ty, &Ty::Named(owner.clone()))?;
                if !self.members(&owner, Some(&tag))?.is_empty() {
                    return Err("unit pattern for a variant with fields".into());
                }
                format!(".variant {} {} []", q(&owner), q(&tag))
            }
            syn::Pat::TupleStruct(t) => {
                attrs(&t.attrs)?;
                if t.qself.is_none() && t.path.is_ident("Some") {
                    let Ty::Option(inner) = ty else {
                        return Err("Some pattern needs Option".into());
                    };
                    let [element] = t.elems.iter().collect::<Vec<_>>()[..] else {
                        return Err("Some pattern takes one element".into());
                    };
                    return Ok(format!(
                        ".present ({})",
                        self.pattern(frame, element, inner)?
                    ));
                }
                let (owner, tag) = self.variant_path(frame, &t.path)?;
                Self::require(ty, &Ty::Named(owner.clone()))?;
                let members = self.members(&owner, Some(&tag))?;
                if members.len() != t.elems.len()
                    || members.iter().any(|(n, _)| n.parse::<usize>().is_err())
                {
                    return Err("tuple pattern must name every positional field".into());
                }
                let mut fields = vec![];
                for ((name, field), element) in members.iter().zip(&t.elems) {
                    fields.push(format!(
                        "({}, {})",
                        q(name),
                        self.pattern(frame, element, field)?
                    ));
                }
                format!(".variant {} {} [{}]", q(&owner), q(&tag), fields.join(", "))
            }
            _ => return Err(format!("unsupported pattern {}", tokens(p))),
        })
    }
    fn variant_path(&self, frame: Frame, p: &syn::Path) -> Result<(String, String), String> {
        if p.leading_colon.is_some()
            || p.segments.len() != 2
            || p.segments
                .iter()
                .any(|s| !matches!(s.arguments, syn::PathArguments::None))
        {
            return Err(format!("unresolved variant path {}", tokens(p)));
        }
        let first = p.segments[0].ident.to_string();
        let owner = if first == "Self" {
            frame.def.receiver.clone()
        } else {
            self.krate.resolve(&frame.def.module, &first, 0)?
        };
        let e = self
            .krate
            .enums
            .get(&owner)
            .ok_or("variant owner is not an enum")?;
        let tag = p.segments[1].ident.to_string();
        if !e.variants.iter().any(|v| v.ident == tag) {
            return Err("unknown variant".into());
        }
        Ok((owner, tag))
    }
    fn arms(
        &mut self,
        frame: Frame,
        value: String,
        ty: &Ty,
        arms: &[(syn::Pat, &Expr)],
    ) -> Result<(String, Ty), String> {
        let mut result: Option<Ty> = None;
        let mut out = vec![];
        for (pattern, body) in arms {
            let cases: Vec<&syn::Pat> = if let syn::Pat::Or(o) = pattern {
                attrs(&o.attrs)?;
                o.cases.iter().collect()
            } else {
                vec![pattern]
            };
            for case in cases {
                let saved = self.env.clone();
                let p = self.pattern(frame, case, ty)?;
                let (b, t) = self.expr(frame, body, result.as_ref())?;
                self.env = saved;
                if let Some(r) = &result {
                    Self::require(&t, r)?;
                } else {
                    result = Some(t);
                }
                out.push(format!("({p}, {b})"));
            }
        }
        // Rust requires exhaustive matches; a value no arm matches is a
        // representation fault in the machine, never a skipped statement.
        Ok((
            format!(".choose ({value}) [{}]", out.join(", ")),
            result.ok_or("empty match")?,
        ))
    }
    fn binary(&self, op: &str, left: &Ty) -> Result<Ty, String> {
        match (op, left) {
            ("&&" | "||", Ty::Bool) => Ok(Ty::Bool),
            ("^" | "&" | "|", Ty::Bool) => Ok(Ty::Bool),
            ("+" | "-" | "*" | "/" | "%" | "^" | "&" | "|" | "<<" | ">>", Ty::Number(_)) => {
                Ok(left.clone())
            }
            ("<" | "<=" | ">" | ">=", Ty::Number(_)) => Ok(Ty::Bool),
            ("==" | "!=", _) => {
                self.derived(left, "PartialEq", 0)?;
                if matches!(left, Ty::Array(_)) {
                    return Err("array equality is not modeled".into());
                }
                Ok(Ty::Bool)
            }
            _ => Err(format!("operator {op} is not modeled for {left:?}")),
        }
    }
    fn operands(
        &mut self,
        frame: Frame,
        op: &str,
        left: &Expr,
        right: &Expr,
        expected: Option<&Ty>,
    ) -> Result<(String, String, Ty), String> {
        // Arithmetic operands take the result type from context; comparison
        // operands do not. An unsuffixed literal on the left otherwise takes
        // the right operand's type, as Rust's inference would give it.
        let context = expected.filter(|_| {
            matches!(
                op,
                "+" | "-" | "*" | "/" | "%" | "^" | "&" | "|" | "<<" | ">>"
            )
        });
        if context.is_none() && untyped(left) {
            let (r, rt) = self.expr(frame, right, None)?;
            let (l, lt) = self.expr(frame, left, Some(&rt))?;
            Self::require(&lt, &rt)?;
            return Ok((l, r, lt));
        }
        let (l, lt) = self.expr(frame, left, context)?;
        // Shift amounts may have any integer type in Rust; an unsuffixed
        // literal amount is given the shifted operand's type, which preserves
        // its value. Other amount types must match exactly.
        let (r, rt) = self.expr(frame, right, Some(&lt))?;
        Self::require(&rt, &lt)?;
        Ok((l, r, lt))
    }
    fn self_call(
        &mut self,
        frame: Frame,
        method: &str,
        args: &[&Expr],
    ) -> Result<(String, Ty), String> {
        // Inherent methods are keyed by module, receiver and name; Rust allows
        // one inherent method of a name per type. A trait method of the same
        // name could take part in resolution, so it is rejected.
        if self.krate.trait_methods.contains(method) {
            return Err(format!(
                "a crate trait method shares the receiver method name {method}"
            ));
        }
        let candidates = self
            .krate
            .methods
            .iter()
            .filter(|(_, d)| d.receiver == frame.def.receiver && d.item.sig.ident == method)
            .collect::<Vec<_>>();
        let [(key, def)] = candidates[..] else {
            return Err(format!("receiver method {method} is unknown or ambiguous"));
        };
        let callee = (key.clone(), def);
        if self.stack.contains(&callee.0) || self.stack.len() > 32 {
            return Err("recursive receiver call".into());
        }
        let def = callee.1;
        let sig = &def.item.sig;
        attrs(&def.item.attrs)?;
        if sig.asyncness.is_some()
            || sig.unsafety.is_some()
            || sig.abi.is_some()
            || !sig.generics.params.is_empty()
            || sig.generics.where_clause.is_some()
        {
            return Err("inlined method must be plain and nongeneric".into());
        }
        let Some(syn::FnArg::Receiver(r)) = sig.inputs.first() else {
            return Err("inlined method requires a receiver".into());
        };
        attrs(&r.attrs)?;
        if r.reference.is_none() || r.colon_token.is_some() {
            return Err("inlined method requires &self or &mut self".into());
        }
        let mutable = r.mutability.is_some();
        if mutable && !frame.mutable_receiver {
            return Err("&mut self call from a shared receiver".into());
        }
        if sig.inputs.len() != args.len() + 1 {
            return Err("argument count mismatch".into());
        }
        let output = match &sig.output {
            syn::ReturnType::Default => Ty::Unit,
            syn::ReturnType::Type(_, t) => {
                self.ty_in(t, &def.impl_generics, &def.module, &def.receiver)?
            }
        };
        let mut parts = vec![];
        let mut bindings = vec![];
        for (input, arg) in sig.inputs.iter().skip(1).zip(args) {
            let syn::FnArg::Typed(t) = input else {
                return Err("unexpected receiver".into());
            };
            attrs(&t.attrs)?;
            let ty = self.ty_in(&t.ty, &def.impl_generics, &def.module, &def.receiver)?;
            let (value, actual) = self.expr(frame, arg, Some(&ty))?;
            Self::require(&actual, &ty)?;
            self.derived(&ty, "Copy", 0)?;
            let (name, mutable) = ident(&t.pat)?;
            let slot = self.fresh();
            parts.push(format!(".write {slot} ({value})"));
            bindings.push((name, Binding { slot, ty, mutable }));
        }
        let saved = std::mem::take(&mut self.env);
        self.env.extend(bindings);
        self.stack.push(callee.0.clone());
        let inner = Frame {
            def,
            mutable_receiver: mutable,
            output: &output,
        };
        let body = self.block(inner, &def.item.block);
        self.stack.pop();
        self.env = saved;
        let (body, ty) = body?;
        Self::require(&ty, &output).or_else(|e| if ty == Ty::Unit { Ok(()) } else { Err(e) })?;
        if !self.inlined.contains(&callee.0) {
            self.inlined.push(callee.0);
        }
        parts.push(format!(".scope ({body})"));
        Ok((
            parts
                .into_iter()
                .rev()
                .reduce(|tail, head| seq(head, tail))
                .unwrap(),
            output,
        ))
    }
    fn expr(
        &mut self,
        frame: Frame,
        e: &Expr,
        expected: Option<&Ty>,
    ) -> Result<(String, Ty), String> {
        let out = match e {
            Expr::Paren(p) => {
                attrs(&p.attrs)?;
                self.expr(frame, &p.expr, expected)?
            }
            Expr::Block(b) => {
                attrs(&b.attrs)?;
                if b.label.is_some() {
                    return Err("labeled block is unsupported".into());
                }
                self.block(frame, &b.block)?
            }
            Expr::Lit(l) => {
                attrs(&l.attrs)?;
                match &l.lit {
                    syn::Lit::Bool(b) => (format!(".literal (.boolean {})", b.value), Ty::Bool),
                    syn::Lit::Int(n) => {
                        let kind = if n.suffix().is_empty() {
                            match expected {
                                Some(Ty::Number(k)) => *k,
                                _ => {
                                    return Err("integer literal needs a known unsigned type".into())
                                }
                            }
                        } else {
                            number(n.suffix()).ok_or("unsupported integer literal suffix")?
                        };
                        let value = n
                            .base10_parse::<u64>()
                            .map_err(|_| "invalid integer literal")?;
                        (self.literal(value, kind)?, Ty::Number(kind))
                    }
                    _ => return Err("unsupported literal".into()),
                }
            }
            Expr::Path(p) => {
                attrs(&p.attrs)?;
                if p.qself.is_some() {
                    return Err("qualified paths are unsupported".into());
                }
                if let Some(name) = single(&p.path) {
                    if name == "None" {
                        let Some(ty @ Ty::Option(_)) = expected else {
                            return Err("None requires a known Option type".into());
                        };
                        return Ok((".literal .absent".into(), ty.clone()));
                    }
                    if name == "self" {
                        (".read 0".into(), Ty::Named(frame.def.receiver.clone()))
                    } else {
                        let b = self
                            .env
                            .get(&name)
                            .ok_or_else(|| format!("unknown local {name}"))?;
                        (format!(".read {}", b.slot), b.ty.clone())
                    }
                } else {
                    let (owner, tag) = self.variant_path(frame, &p.path)?;
                    if !self.members(&owner, Some(&tag))?.is_empty() {
                        return Err("variant with fields used as a value".into());
                    }
                    (
                        format!(".literal (.variant {} {} [])", q(&owner), q(&tag)),
                        Ty::Named(owner),
                    )
                }
            }
            Expr::Field(f) => {
                attrs(&f.attrs)?;
                let (value, ty) = self.expr(frame, &f.base, None)?;
                let (name, field) = self.field(&ty, &f.member)?;
                (format!(".field ({value}) {}", q(&name)), field)
            }
            Expr::Index(i) => {
                attrs(&i.attrs)?;
                let (array, ty) = self.expr(frame, &i.expr, None)?;
                let Ty::Array(element) = ty else {
                    return Err("indexing requires a builtin array".into());
                };
                let (index, index_ty) = self.expr(frame, &i.index, Some(&Ty::Number("usize")))?;
                Self::require(&index_ty, &Ty::Number("usize"))?;
                (format!(".index ({array}) ({index})"), *element)
            }
            Expr::Unary(u) => {
                attrs(&u.attrs)?;
                let syn::UnOp::Not(_) = u.op else {
                    return Err("unsupported unary operator".into());
                };
                let (value, ty) = self.expr(frame, &u.expr, Some(&Ty::Bool))?;
                Self::require(&ty, &Ty::Bool)?;
                (format!(".negate ({value})"), Ty::Bool)
            }
            Expr::Binary(b) => {
                attrs(&b.attrs)?;
                let op = tokens(&b.op);
                if let Some(base) = op.strip_suffix('=').filter(|o| {
                    matches!(
                        *o,
                        "+" | "-" | "*" | "/" | "%" | "^" | "&" | "|" | "<<" | ">>"
                    )
                }) {
                    let (current, right, ty) =
                        self.operands(frame, base, &b.left, &b.right, None)?;
                    let result = self.binary(base, &ty)?;
                    Self::require(&result, &ty)?;
                    // Compound assignment evaluates the right operand first for
                    // primitive types, then reads and writes the place.
                    let operand = self.fresh();
                    let update = self.store(
                        frame,
                        &b.left,
                        format!(".binary {} ({current}) (.read {operand})", q(base)),
                        &ty,
                    )?;
                    (seq(format!(".write {operand} ({right})"), update), Ty::Unit)
                } else {
                    let (left, right, ty) =
                        self.operands(frame, &op, &b.left, &b.right, expected)?;
                    let result = self.binary(&op, &ty)?;
                    (format!(".binary {} ({left}) ({right})", q(&op)), result)
                }
            }
            Expr::Assign(a) => {
                attrs(&a.attrs)?;
                let ty = {
                    // Type the place without emitting its setup twice.
                    let saved = self.next;
                    let place = self.place(frame, &a.left)?;
                    self.next = saved;
                    place.ty
                };
                let (value, actual) = self.expr(frame, &a.right, Some(&ty))?;
                self.derived(&actual, "Copy", 0)?;
                (self.store(frame, &a.left, value, &actual)?, Ty::Unit)
            }
            Expr::If(i) => {
                attrs(&i.attrs)?;
                let otherwise = i.else_branch.as_ref().map(|(_, e)| &**e);
                if let Expr::Let(l) = &*i.cond {
                    attrs(&l.attrs)?;
                    let (value, ty) = self.expr(frame, &l.expr, None)?;
                    let then: Expr = Expr::Block(syn::ExprBlock {
                        attrs: vec![],
                        label: None,
                        block: i.then_branch.clone(),
                    });
                    let unit_block: Expr = syn::parse_quote!({});
                    let wild: syn::Pat = syn::parse_quote!(_);
                    let arms = [
                        ((*l.pat).clone(), &then),
                        (wild, otherwise.unwrap_or(&unit_block)),
                    ];
                    self.arms(frame, value, &ty, &arms)?
                } else {
                    let (condition, ct) = self.expr(frame, &i.cond, Some(&Ty::Bool))?;
                    Self::require(&ct, &Ty::Bool)?;
                    let (yes, yt) = self.block(frame, &i.then_branch)?;
                    let (no, nt) = match otherwise {
                        Some(e) => self.expr(frame, e, Some(&yt))?,
                        None => (unit(), Ty::Unit),
                    };
                    Self::require(&nt, &yt)?;
                    (format!(".branch ({condition}) ({yes}) ({no})"), yt)
                }
            }
            Expr::Match(m) => {
                attrs(&m.attrs)?;
                let (value, ty) = self.expr(frame, &m.expr, None)?;
                let mut arms = vec![];
                for a in &m.arms {
                    attrs(&a.attrs)?;
                    if a.guard.is_some() {
                        return Err("guarded match arms are unsupported".into());
                    }
                    arms.push((a.pat.clone(), &*a.body));
                }
                self.arms(frame, value, &ty, &arms)?
            }
            Expr::Return(r) => {
                attrs(&r.attrs)?;
                let (value, ty) = match &r.expr {
                    Some(v) => self.expr(frame, v, Some(frame.output))?,
                    None => (unit(), Ty::Unit),
                };
                Self::require(&ty, frame.output)?;
                (format!(".ret ({value})"), Ty::Unit)
            }
            Expr::Call(c) => {
                attrs(&c.attrs)?;
                let Expr::Path(p) = &*c.func else {
                    return Err("unsupported call target".into());
                };
                attrs(&p.attrs)?;
                if p.qself.is_none() && p.path.is_ident("Some") {
                    let [arg] = c.args.iter().collect::<Vec<_>>()[..] else {
                        return Err("Some takes one argument".into());
                    };
                    let inner = match expected {
                        Some(Ty::Option(t)) => Some(&**t),
                        _ => None,
                    };
                    let (value, ty) = self.expr(frame, arg, inner)?;
                    (format!(".present ({value})"), Ty::Option(Box::new(ty)))
                } else if p.qself.is_none() {
                    let (owner, tag) = self.variant_path(frame, &p.path)?;
                    let members = self.members(&owner, Some(&tag))?;
                    if members.len() != c.args.len()
                        || members.iter().any(|(n, _)| n.parse::<usize>().is_err())
                    {
                        return Err("tuple variant arity mismatch".into());
                    }
                    let mut fields = vec![];
                    for ((name, ty), arg) in members.iter().zip(&c.args) {
                        let (value, actual) = self.expr(frame, arg, Some(ty))?;
                        Self::require(&actual, ty)?;
                        fields.push(format!("({}, {value})", q(name)));
                    }
                    (
                        format!(".variant {} {} [{}]", q(&owner), q(&tag), fields.join(", ")),
                        Ty::Named(owner),
                    )
                } else {
                    return Err("qualified call is unsupported".into());
                }
            }
            Expr::Struct(s) => {
                attrs(&s.attrs)?;
                if s.qself.is_some() || s.rest.is_some() || s.dot2_token.is_some() {
                    return Err("struct update syntax is unsupported".into());
                }
                let name = single(&s.path).ok_or("unresolved struct path")?;
                let owner = if name == "Self" {
                    frame.def.receiver.clone()
                } else {
                    self.krate.resolve(&frame.def.module, &name, 0)?
                };
                let members = self.members(&owner, None)?;
                if members.len() != s.fields.len() {
                    return Err("struct literal must initialize every field".into());
                }
                // Fields are evaluated in source order and stored in
                // declaration order, as the record value is laid out.
                let mut evaluated = vec![];
                let mut parts = vec![];
                for f in &s.fields {
                    attrs(&f.attrs)?;
                    let syn::Member::Named(member) = &f.member else {
                        return Err("unnamed struct literal field".into());
                    };
                    let (_, ty) = members
                        .iter()
                        .find(|(n, _)| member == n)
                        .ok_or("unknown struct field")?;
                    let (value, actual) = self.expr(frame, &f.expr, Some(ty))?;
                    Self::require(&actual, ty)?;
                    let slot = self.fresh();
                    parts.push(format!(".write {slot} ({value})"));
                    evaluated.push((member.to_string(), slot));
                }
                let fields = members
                    .iter()
                    .map(|(n, _)| {
                        let slot = evaluated
                            .iter()
                            .find(|(m, _)| m == n)
                            .map(|(_, s)| *s)
                            .ok_or("missing struct field")?;
                        Ok(format!("({}, .read {slot})", q(n)))
                    })
                    .collect::<Result<Vec<_>, String>>()?;
                parts.push(format!(".record {} [{}]", q(&owner), fields.join(", ")));
                (
                    parts
                        .into_iter()
                        .rev()
                        .reduce(|tail, head| seq(head, tail))
                        .unwrap(),
                    Ty::Named(owner),
                )
            }
            Expr::MethodCall(c) => {
                attrs(&c.attrs)?;
                if c.turbofish.is_some() {
                    return Err("method type arguments are unsupported".into());
                }
                let method = c.method.to_string();
                let args = c.args.iter().collect::<Vec<_>>();
                if matches!(&*c.receiver, Expr::Path(p) if p.attrs.is_empty() && p.qself.is_none() && p.path.is_ident("self"))
                {
                    return self.self_call(frame, &method, &args);
                }
                if BUILTIN_METHODS.contains(&method.as_str())
                    && self.krate.trait_methods.contains(&method)
                {
                    return Err(format!("a crate trait method shadows builtin {method}"));
                }
                let (value, ty) = self.expr(frame, &c.receiver, None)?;
                match (method.as_str(), &ty, args.as_slice()) {
                    ("is_some" | "is_none", Ty::Option(_), []) => {
                        let some = method == "is_some";
                        (format!(".choose ({value}) [(.present .any, .literal (.boolean {some})), (.any, .literal (.boolean {}))]", !some), Ty::Bool)
                    }
                    (
                        "wrapping_add" | "wrapping_sub" | "wrapping_mul" | "saturating_add"
                        | "saturating_sub" | "min" | "max" | "checked_add" | "checked_sub",
                        Ty::Number(_),
                        [arg],
                    ) => {
                        let (rhs, rt) = self.expr(frame, arg, Some(&ty))?;
                        Self::require(&rt, &ty)?;
                        let result = if method.starts_with("checked_") {
                            Ty::Option(Box::new(ty.clone()))
                        } else {
                            ty.clone()
                        };
                        (format!(".binary {} ({value}) ({rhs})", q(&method)), result)
                    }
                    _ => return Err(format!("opaque method call {method}")),
                }
            }
            _ => return Err(format!("unsupported expression {}", tokens(e))),
        };
        Ok(out)
    }
}

impl Crate {
    pub fn lower_imperative(&self, name: &str) -> Result<Method, String> {
        let def = self.methods.get(name).ok_or("unknown imperative method")?;
        let f = &def.item;
        attrs(&f.attrs)?;
        let sig = &f.sig;
        if !candidate(f)
            || sig.asyncness.is_some()
            || sig.constness.is_some()
            || sig.unsafety.is_some()
            || sig.abi.is_some()
            || !sig.generics.params.is_empty()
            || sig.generics.where_clause.is_some()
        {
            return Err(
                "imperative method requires a plain nongeneric &self or &mut self method".into(),
            );
        }
        if !self.structs.contains_key(&def.receiver) {
            return Err("imperative receiver must be a source record".into());
        }
        for primitive in NUMBERS.iter().chain(&["bool", "Option", "Some", "None"]) {
            if self
                .structs
                .keys()
                .chain(self.enums.keys())
                .any(|k| k == primitive)
                || def
                    .impl_generics
                    .type_params()
                    .any(|p| p.ident == primitive)
            {
                return Err(format!("source item shadows builtin {primitive}"));
            }
        }
        let Some(syn::FnArg::Receiver(r)) = sig.inputs.first() else {
            unreachable!()
        };
        attrs(&r.attrs)?;
        if r.colon_token.is_some() {
            return Err("typed receivers are unsupported".into());
        }
        let mut compiler = Compiler {
            krate: self,
            env: BTreeMap::new(),
            next: 1,
            inlined: vec![],
            stack: vec![name.to_owned()],
        };
        let output = match &sig.output {
            syn::ReturnType::Default => Ty::Unit,
            syn::ReturnType::Type(_, t) => {
                compiler.ty_in(t, &def.impl_generics, &def.module, &def.receiver)?
            }
        };
        if output != Ty::Unit {
            compiler.derived(&output, "Copy", 0)?;
        }
        for input in sig.inputs.iter().skip(1) {
            let syn::FnArg::Typed(t) = input else {
                return Err("unexpected receiver".into());
            };
            attrs(&t.attrs)?;
            let ty = compiler.ty_in(&t.ty, &def.impl_generics, &def.module, &def.receiver)?;
            compiler.derived(&ty, "Copy", 0)?;
            let (binding, mutable) = ident(&t.pat)?;
            compiler.bind(binding, ty, mutable);
        }
        let parameters = sig.inputs.len() - 1;
        let mutable_receiver = r.mutability.is_some();
        let frame = Frame {
            def,
            mutable_receiver,
            output: &output,
        };
        let (expression, ty) = compiler.block(frame, &f.block)?;
        if ty != output {
            return Err(format!("method body type {ty:?} does not match {output:?}"));
        }
        let mut method = Method {
            name: name.into(),
            symbol: name.replace("::", "_"),
            source: def.file.clone(),
            first_line: f.span().start().line,
            last_line: f.span().end().line,
            rust: tokens(f),
            writes: vec![],
            body: vec![],
            array: None,
            query: None,
            constructor: None,
            buffer: None,
            relocation: None,
            iteration: None,
            last: None,
            truncation: None,
            installation: None,
            restoration: None,
            record_at: None,
            lookup: None,
            selection: None,
            getter: None,
            enum_projection: None,
            view: None,
            validator: None,
            imperative: None,
        };
        method.imperative = Some(Imperative {
            expression,
            parameters,
            mutable_receiver,
            inlined: compiler.inlined,
            scope: "complete receiver-method body over a value-semantics record with inlined same-receiver calls; frontend typing, field layout, aliasing and unwinding state remain unproved",
        });
        Ok(method)
    }
}

pub(super) fn generate(method: &Method) -> String {
    let m = method.imperative.as_ref().unwrap();
    let name = &method.symbol;
    format!("def {name}_ir : Provium.Imperative.Expr := {}\ndef {name} (bits : Nat) (checked : Bool) (fuel : Nat) (receiver : PureValue) (arguments : List PureValue) : Except Provium.Imperative.Fault (PureValue × PureValue) :=\n  Provium.Imperative.run bits checked fuel {name}_ir receiver arguments\ntheorem {name}_correspondence (bits : Nat) (checked : Bool) (fuel : Nat) (receiver : PureValue) (arguments : List PureValue) :\n  Provium.Imperative.run bits checked fuel {name}_ir receiver arguments = {name} bits checked fuel receiver arguments := by rfl\n", m.expression)
}
