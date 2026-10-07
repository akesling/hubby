//! Complete method bodies lowered to the value-semantics machine in
//! `Provium.Imperative`. Every value, including the receiver, lives in a slot;
//! an assignment replaces a field or array element of a slot's value. Calls to
//! the crate's own functions and methods on any crate type are inlined, with a
//! `&mut self` callee's receiver written back to its place after the call.
//! Closures are inlined where they are called. Iterator chains over arrays,
//! slices and integer ranges lower to explicit loops. Fields a body never reads
//! may have any type, so values with generic payloads are carried unchanged;
//! `Clone` of a generic payload and function-pointer calls go to the machine's
//! oracle. Payload destructors are not modeled: the lowering assumes they
//! return normally and have no effect on the values the machine tracks.
//! Unsupported Rust is rejected.
use super::*;

/// A const-generic value: a slot holding it at run time, a literal, or a
/// value the lowering cannot name (only usable where it is never read).
#[derive(Clone, Debug)]
enum Konst {
    Slot(usize),
    Value(u64),
    Unknown,
}

#[derive(Clone, Debug)]
enum Ty {
    Unit,
    Bool,
    Number(&'static str),
    Named {
        name: String,
        types: Vec<Ty>,
        consts: Vec<Konst>,
    },
    Option(Box<Ty>),
    Result(Box<Ty>, Box<Ty>),
    Array(Box<Ty>),
    Tuple(Vec<Ty>),
    /// A function pointer; calls go to the oracle and return `output`.
    Function(Box<Ty>),
    /// The payload type of a `None` written without context, refined by a
    /// later assignment; it matches any type.
    Infer,
    /// A type the machine never inspects: generic parameters, function
    /// pointers and other unsupported types. Values of it can only be carried,
    /// cloned through the oracle or passed to the oracle.
    Opaque(String),
}

impl PartialEq for Ty {
    fn eq(&self, other: &Self) -> bool {
        match (self, other) {
            (Ty::Infer, _) | (_, Ty::Infer) => true,
            (Ty::Unit, Ty::Unit) | (Ty::Bool, Ty::Bool) => true,
            (Ty::Number(a), Ty::Number(b)) => a == b,
            (
                Ty::Named {
                    name: a, types: x, ..
                },
                Ty::Named {
                    name: b, types: y, ..
                },
            ) => a == b && x == y,
            (Ty::Option(a), Ty::Option(b)) => a == b,
            (Ty::Result(a, e), Ty::Result(b, f)) => a == b && e == f,
            (Ty::Array(a), Ty::Array(b)) => a == b,
            (Ty::Tuple(a), Ty::Tuple(b)) => a == b,
            (Ty::Function(a), Ty::Function(b)) => a == b,
            (Ty::Opaque(a), Ty::Opaque(b)) => a == b,
            _ => false,
        }
    }
}

#[derive(Debug, Serialize)]
pub struct Imperative {
    pub expression: String,
    pub parameters: usize,
    /// Impl const parameters, passed after the ordinary parameters.
    pub constants: Vec<String>,
    pub receiver: bool,
    pub mutable_receiver: bool,
    pub inlined: Vec<String>,
    /// Bodies of called functions, by qualified name, for the function table.
    pub functions: Vec<(String, String)>,
    pub scope: &'static str,
}

#[derive(Clone)]
struct Binding {
    slot: usize,
    ty: Ty,
    mutable: bool,
    /// A `&mut` iteration binding: writes through `*name` go to this place.
    alias: Option<(usize, Vec<String>)>,
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

#[derive(Clone, Default)]
struct Generics {
    types: BTreeMap<String, Ty>,
    consts: BTreeMap<String, Konst>,
}

#[derive(Clone)]
struct Loop {
    label: Option<String>,
    exit: usize,
    next: usize,
    result: Option<(usize, Ty)>,
}

/// One body being compiled: the definition supplies the module and declared
/// generics, `generics` their instantiation, and `receiver` the slot, type and
/// mutability of `self`.
#[derive(Clone)]
struct Frame<'a> {
    def: &'a Definition,
    generics: Generics,
    receiver: Option<(usize, Ty, bool)>,
    output: Option<Ty>,
    loops: Vec<Loop>,
}

/// A closure with everything visible where it was written: its bindings,
/// the closures in scope, and the frame whose `self` and generics it uses.
#[derive(Clone)]
struct Closure<'a> {
    syntax: syn::ExprClosure,
    env: BTreeMap<String, Binding>,
    closures: BTreeMap<String, Closure<'a>>,
    frame: Frame<'a>,
}

/// A lazily re-instantiated iterator-valued local: Rust's borrow rules keep
/// the iterated data unchanged while the iterator is alive.
#[derive(Clone)]
struct Lazy<'a> {
    expression: Expr,
    env: BTreeMap<String, Binding>,
    closures: BTreeMap<String, Closure<'a>>,
    frame: Frame<'a>,
}

/// A closure argument is passed as a closure, any other argument as a value.
enum Input<'a> {
    Value(Ty),
    Closure(Box<Closure<'a>>),
}

/// A compiled closure applied to fresh input slots: write the inputs, then
/// evaluate `code`.
struct Applied {
    inputs: Vec<usize>,
    code: String,
    ty: Ty,
}

#[derive(Clone)]
enum Source {
    Elements {
        array: usize,
        lo: usize,
        hi: usize,
        places: Option<(usize, Vec<String>)>,
    },
    Numbers {
        lo: usize,
        hi: usize,
        kind: &'static str,
    },
}

enum Stage {
    Flatten,
    Map(Applied),
    Filter(Applied),
    FilterMap(Applied),
    Enumerate(usize),
    TakeWhile(Applied),
    Clone(Ty),
}

/// A lazily consumed iterator: setup evaluated once, a source walked forward
/// or backward, and element-wise stages applied in order.
struct Pipeline {
    setup: Vec<String>,
    source: Source,
    reverse: bool,
    stages: Vec<Stage>,
    item: Ty,
}

struct Compiler<'a> {
    krate: &'a Crate,
    env: BTreeMap<String, Binding>,
    closures: BTreeMap<String, Closure<'a>>,
    iterators: BTreeMap<String, Lazy<'a>>,
    /// While compiling the later cases of an or-pattern, the bindings the
    /// first case made, which every case must bind to the same slots.
    rebind: Option<BTreeMap<String, Binding>>,
    next: usize,
    labels: usize,
    inlined: Vec<String>,
    stack: Vec<String>,
    functions: BTreeMap<String, String>,
}

/// A body compiled as a function: receiver in slot 0, ordinary parameters
/// from slot 1, impl const parameters after them.
struct Function {
    body: String,
    parameters: usize,
    constants: Vec<String>,
    receiver: bool,
    mutable_receiver: bool,
}

const NUMBERS: &[&str] = &["u8", "u16", "u32", "u64", "usize"];
/// Names whose builtin meaning a crate trait method could shadow.
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
    "is_some_and",
    "is_none_or",
    "map",
    "map_or",
    "and_then",
    "or_else",
    "ok_or",
    "ok",
    "unwrap_or",
    "unwrap",
    "expect",
    "filter",
    "take",
    "as_ref",
    "as_mut",
    "copied",
    "cloned",
    "clone",
    "then_some",
    "then",
    "iter",
    "flatten",
    "rev",
    "filter_map",
    "enumerate",
    "take_while",
    "position",
    "any",
    "all",
    "find",
    "count",
    "next",
    "next_back",
    "last",
    "contains",
    "get",
    "len",
    "fill",
    "rotate_left",
    "clamp",
    "default",
    "try_from",
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
fn chain(parts: Vec<String>) -> String {
    parts
        .into_iter()
        .rev()
        .reduce(|tail, head| seq(head, tail))
        .unwrap_or_else(unit)
}
fn boolean(b: bool) -> String {
    format!(".literal (.boolean {b})")
}
fn usize_literal(n: usize) -> String {
    format!(".literal (.number \"usize\" {n})")
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
        return Err(format!("binding must be a plain identifier: {}", tokens(p)));
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
fn is_self(e: &Expr) -> bool {
    matches!(e, Expr::Path(p) if p.attrs.is_empty() && p.qself.is_none() && p.path.is_ident("self"))
}
fn strip(e: &Expr) -> &Expr {
    match e {
        Expr::Paren(p) if p.attrs.is_empty() => strip(&p.expr),
        Expr::Reference(r) if r.attrs.is_empty() && r.mutability.is_none() => strip(&r.expr),
        _ => e,
    }
}
fn tuple_name() -> String {
    q("()")
}

impl<'a> Compiler<'a> {
    fn fresh(&mut self) -> usize {
        let slot = self.next;
        self.next += 1;
        slot
    }
    fn label(&mut self) -> usize {
        self.labels += 1;
        self.labels
    }
    fn bind(&mut self, name: String, ty: Ty, mutable: bool) -> usize {
        let slot = self.fresh();
        self.env.insert(
            name,
            Binding {
                slot,
                ty,
                mutable,
                alias: None,
            },
        );
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

    // ---- types ----------------------------------------------------------

    fn konst(&self, e: &Expr, generics: &Generics) -> Konst {
        match e {
            Expr::Lit(syn::ExprLit {
                lit: syn::Lit::Int(n),
                ..
            }) => n.base10_parse::<u64>().map_or(Konst::Unknown, Konst::Value),
            Expr::Path(p) => single(&p.path)
                .and_then(|n| generics.consts.get(&n).cloned())
                .unwrap_or(Konst::Unknown),
            Expr::Block(b) if b.block.stmts.len() == 1 => match &b.block.stmts[0] {
                syn::Stmt::Expr(e, None) => self.konst(e, generics),
                _ => Konst::Unknown,
            },
            _ => Konst::Unknown,
        }
    }
    /// Resolve `t` written in `module` under declared `declared` generics
    /// instantiated by `generics`; `self_ty` interprets `Self`.
    fn ty_in(
        &self,
        t: &Type,
        declared: &syn::Generics,
        generics: &Generics,
        module: &str,
        self_ty: Option<&Ty>,
    ) -> Result<Ty, String> {
        Ok(match t {
            Type::Paren(p) => self.ty_in(&p.elem, declared, generics, module, self_ty)?,
            Type::Group(g) => self.ty_in(&g.elem, declared, generics, module, self_ty)?,
            Type::Reference(r) => self.ty_in(&r.elem, declared, generics, module, self_ty)?,
            Type::Array(a) => Ty::Array(Box::new(
                self.ty_in(&a.elem, declared, generics, module, self_ty)?,
            )),
            Type::Tuple(t) if t.elems.is_empty() => Ty::Unit,
            Type::Tuple(t) => Ty::Tuple(
                t.elems
                    .iter()
                    .map(|e| self.ty_in(e, declared, generics, module, self_ty))
                    .collect::<Result<_, _>>()?,
            ),
            Type::Path(p)
                if p.qself.is_none()
                    && p.path.leading_colon.is_none()
                    && p.path.segments.len() == 1 =>
            {
                let s = &p.path.segments[0];
                let name = s.ident.to_string();
                if let Some(ty) = generics.types.get(&name) {
                    return Ok(ty.clone());
                }
                if declared.type_params().any(|g| g.ident == name) {
                    return Ok(Ty::Opaque(name));
                }
                if name == "Self" {
                    return self_ty
                        .cloned()
                        .ok_or_else(|| "Self outside an impl".into());
                }
                if let Some(kind) = number(&name) {
                    return Ok(Ty::Number(kind));
                }
                let arguments = match &s.arguments {
                    syn::PathArguments::None => vec![],
                    syn::PathArguments::AngleBracketed(a) => a.args.iter().collect(),
                    syn::PathArguments::Parenthesized(_) => return Ok(Ty::Opaque(name)),
                };
                let argument = |i: usize| -> Result<Ty, String> {
                    let Some(syn::GenericArgument::Type(t)) = arguments.get(i) else {
                        return Err(format!("{name} requires type arguments"));
                    };
                    self.ty_in(t, declared, generics, module, self_ty)
                };
                match name.as_str() {
                    "bool" => Ty::Bool,
                    "Option" => Ty::Option(Box::new(argument(0)?)),
                    "Result" => Ty::Result(Box::new(argument(0)?), Box::new(argument(1)?)),
                    _ => {
                        let Ok(resolved) = self.krate.resolve(module, &name, 0) else {
                            return Ok(Ty::Opaque(name));
                        };
                        let decl = if let Some(s) = self.krate.structs.get(&resolved) {
                            &s.generics
                        } else if let Some(e) = self.krate.enums.get(&resolved) {
                            &e.generics
                        } else {
                            return Ok(Ty::Opaque(resolved));
                        };
                        let mut types = vec![];
                        let mut consts = vec![];
                        for (i, param) in decl.params.iter().enumerate() {
                            let arg = arguments.get(i);
                            match param {
                                syn::GenericParam::Type(_) => types.push(match arg {
                                    Some(syn::GenericArgument::Type(t)) => {
                                        self.ty_in(t, declared, generics, module, self_ty)?
                                    }
                                    _ => Ty::Opaque("_".into()),
                                }),
                                syn::GenericParam::Const(_) => consts.push(match arg {
                                    Some(syn::GenericArgument::Const(e)) => self.konst(e, generics),
                                    Some(syn::GenericArgument::Type(Type::Path(p))) => {
                                        single(&p.path)
                                            .and_then(|n| generics.consts.get(&n).cloned())
                                            .unwrap_or(Konst::Unknown)
                                    }
                                    _ => Konst::Unknown,
                                }),
                                syn::GenericParam::Lifetime(_) => {}
                            }
                        }
                        Ty::Named {
                            name: resolved,
                            types,
                            consts,
                        }
                    }
                }
            }
            Type::BareFn(f) => Ty::Function(Box::new(match &f.output {
                syn::ReturnType::Default => Ty::Unit,
                syn::ReturnType::Type(_, t) => {
                    self.ty_in(t, declared, generics, module, self_ty)?
                }
            })),
            _ => Ty::Opaque(tokens(t)),
        })
    }
    fn ty(&self, frame: &Frame<'a>, t: &Type) -> Result<Ty, String> {
        self.ty_in(
            t,
            &frame.def.impl_generics,
            &frame.generics,
            &frame.def.module,
            frame
                .receiver
                .as_ref()
                .map(|r| &r.1)
                .or(frame_self(frame).as_ref()),
        )
    }
    /// The instantiation a declaration's generics receive from `ty`.
    fn instance(&self, declared: &syn::Generics, ty: &Ty) -> Generics {
        let mut out = Generics::default();
        if let Ty::Named { types, consts, .. } = ty {
            let mut t = types.iter();
            let mut c = consts.iter();
            for param in &declared.params {
                match param {
                    syn::GenericParam::Type(p) => {
                        out.types.insert(
                            p.ident.to_string(),
                            t.next().cloned().unwrap_or(Ty::Opaque(p.ident.to_string())),
                        );
                    }
                    syn::GenericParam::Const(p) => {
                        out.consts.insert(
                            p.ident.to_string(),
                            c.next().cloned().unwrap_or(Konst::Unknown),
                        );
                    }
                    syn::GenericParam::Lifetime(_) => {}
                }
            }
        }
        out
    }
    /// Field types of a named record, or of one enum variant.
    fn members(&self, owner: &Ty, variant: Option<&str>) -> Result<Vec<(String, Ty)>, String> {
        let Ty::Named { name, .. } = owner else {
            return Err(format!("{owner:?} has no fields"));
        };
        let module = self
            .krate
            .struct_modules
            .get(name)
            .ok_or("unknown type module")?;
        let (fields, declared) = if let Some(tag) = variant {
            let e = self
                .krate
                .enums
                .get(name)
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
            let s = self.krate.structs.get(name).ok_or("unknown record")?;
            (&s.fields, &s.generics)
        };
        let generics = self.instance(declared, owner);
        let mut out = vec![];
        for (i, f) in fields.iter().enumerate() {
            attrs(&f.attrs)?;
            let field = f
                .ident
                .as_ref()
                .map_or_else(|| i.to_string(), ToString::to_string);
            out.push((
                field,
                self.ty_in(&f.ty, declared, &generics, module, Some(owner))?,
            ));
        }
        Ok(out)
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
    fn variants(&self, ty: &Ty) -> Vec<Option<String>> {
        match ty {
            Ty::Named { name, .. } => self.krate.enums.get(name).map_or(vec![None], |e| {
                e.variants
                    .iter()
                    .map(|v| Some(v.ident.to_string()))
                    .collect()
            }),
            _ => vec![],
        }
    }
    /// A derived trait holds for the type and, structurally, for every part of
    /// it the derived implementation inspects.
    fn derived(&self, ty: &Ty, required: &str, depth: usize) -> Result<(), String> {
        if depth > 32 {
            return Err("recursive type in derived check".into());
        }
        match ty {
            Ty::Unit | Ty::Bool | Ty::Number(_) | Ty::Infer => Ok(()),
            Ty::Function(_) if matches!(required, "Copy" | "Clone") => Ok(()),
            Ty::Option(inner) => self.derived(inner, required, depth + 1),
            Ty::Result(a, e) => {
                self.derived(a, required, depth + 1)?;
                self.derived(e, required, depth + 1)
            }
            Ty::Tuple(items) => items
                .iter()
                .try_for_each(|t| self.derived(t, required, depth + 1)),
            Ty::Array(inner) if required != "PartialOrd" => {
                self.derived(inner, required, depth + 1)
            }
            Ty::Named { name, .. } => {
                let attributes = if let Some(s) = self.krate.structs.get(name) {
                    &s.attrs
                } else {
                    &self
                        .krate
                        .enums
                        .get(name)
                        .ok_or("unknown named type")?
                        .attrs
                };
                if !Self::derives(attributes, required)? {
                    return Err(format!("{name} must derive {required}"));
                }
                for variant in self.variants(ty) {
                    for (_, field) in self.members(ty, variant.as_deref())? {
                        self.derived(&field, required, depth + 1)?;
                    }
                }
                Ok(())
            }
            _ => Err(format!("{required} is not modeled for {ty:?}")),
        }
    }
    /// Values of crate types with their own `Drop` implementation run user
    /// code when they go out of scope, which the machine does not model.
    fn droppable(&self, ty: &Ty) -> Result<(), String> {
        match ty {
            Ty::Named { name, types, .. } => {
                if self.krate.drops.contains(name) {
                    return Err(format!(
                        "values of {name}, which implements Drop, are not modeled"
                    ));
                }
                types.iter().try_for_each(|t| self.droppable(t))
            }
            Ty::Option(t) | Ty::Array(t) => self.droppable(t),
            Ty::Result(a, b) => {
                self.droppable(a)?;
                self.droppable(b)
            }
            Ty::Tuple(items) => items.iter().try_for_each(|t| self.droppable(t)),
            _ => Ok(()),
        }
    }
    fn copy(&self, ty: &Ty) -> Result<(), String> {
        self.derived(ty, "Copy", 0)
    }
    fn field(&self, ty: &Ty, member: &syn::Member) -> Result<(String, Ty), String> {
        let name = match member {
            syn::Member::Named(n) => n.to_string(),
            syn::Member::Unnamed(i) => i.index.to_string(),
        };
        if let Ty::Tuple(items) = ty {
            let i: usize = name.parse().map_err(|_| "named field of a tuple")?;
            return Ok((
                name,
                items.get(i).cloned().ok_or("tuple index out of range")?,
            ));
        }
        let (_, field) = self
            .members(ty, None)?
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
            "i32" => 31,
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
    fn konst_code(k: &Konst) -> Result<String, String> {
        match k {
            Konst::Slot(s) => Ok(format!(".read {s}")),
            Konst::Value(v) => Ok(format!(".literal (.number \"usize\" {v})")),
            Konst::Unknown => Err("const generic value is not available here".into()),
        }
    }

    // ---- places and statements -----------------------------------------

    fn place(&mut self, frame: &Frame<'a>, e: &Expr) -> Result<Place, String> {
        match e {
            Expr::Paren(p) => {
                attrs(&p.attrs)?;
                self.place(frame, &p.expr)
            }
            Expr::Unary(u) if matches!(u.op, syn::UnOp::Deref(_)) => {
                attrs(&u.attrs)?;
                if let Expr::Path(p) = &*u.expr {
                    if let Some(name) = single(&p.path) {
                        if let Some(Binding {
                            alias: Some((slot, path)),
                            ty,
                            ..
                        }) = self.env.get(&name).cloned()
                        {
                            return Ok(Place {
                                slot,
                                path,
                                ty,
                                setup: vec![],
                                mutable: true,
                            });
                        }
                    }
                }
                self.place(frame, &u.expr)
            }
            Expr::Path(p) => {
                attrs(&p.attrs)?;
                let name = single(&p.path)
                    .filter(|_| p.qself.is_none())
                    .ok_or("unsupported place")?;
                if name == "self" {
                    let (slot, ty, mutable) =
                        frame.receiver.clone().ok_or("self outside a method")?;
                    return Ok(Place {
                        slot,
                        path: vec![],
                        ty,
                        setup: vec![],
                        mutable,
                    });
                }
                let b = self
                    .env
                    .get(&name)
                    .ok_or_else(|| format!("unknown local {name}"))?;
                if let Some((slot, path)) = &b.alias {
                    return Ok(Place {
                        slot: *slot,
                        path: path.clone(),
                        ty: b.ty.clone(),
                        setup: vec![],
                        mutable: true,
                    });
                }
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
    fn place_read(place: &Place) -> String {
        let mut code = format!(".read {}", place.slot);
        for step in &place.path {
            if let Some(name) = step.strip_prefix(".field ") {
                code = format!(".field ({code}) {name}");
            } else if let Some(slot) = step.strip_prefix(".index ") {
                code = format!(".index ({code}) (.read {slot})");
            }
        }
        code
    }
    fn place_write(place: &Place, value: String) -> String {
        if place.path.is_empty() {
            format!(".write {} ({value})", place.slot)
        } else {
            format!(
                ".assign {} [{}] ({value})",
                place.slot,
                place.path.join(", ")
            )
        }
    }
    fn store(
        &mut self,
        frame: &Frame<'a>,
        target: &Expr,
        value: String,
        ty: &Ty,
    ) -> Result<String, String> {
        let place = self.place(frame, target)?;
        if !place.mutable {
            return Err("assignment through an immutable place".into());
        }
        Self::require(ty, &place.ty)?;
        // Rust evaluates the assigned value before the place's index operands.
        let value_slot = self.fresh();
        let mut parts = vec![format!(".write {value_slot} ({value})")];
        parts.extend(place.setup.iter().cloned());
        parts.push(Self::place_write(&place, format!(".read {value_slot}")));
        Ok(chain(parts))
    }
    /// Bind an irrefutable `let` pattern to the value in `slot`.
    fn destructure(
        &mut self,
        frame: &Frame<'a>,
        pat: &syn::Pat,
        slot: usize,
        ty: &Ty,
    ) -> Result<Vec<String>, String> {
        match pat {
            syn::Pat::Ident(_) => {
                self.droppable(ty)?;
                let (name, mutable) = ident(pat)?;
                let target = self.bind(name, ty.clone(), mutable);
                Ok(vec![format!(".write {target} (.read {slot})")])
            }
            syn::Pat::Wild(w) => {
                attrs(&w.attrs)?;
                Ok(vec![])
            }
            syn::Pat::Reference(r) => {
                attrs(&r.attrs)?;
                self.destructure(frame, &r.pat, slot, ty)
            }
            syn::Pat::Tuple(t) => {
                attrs(&t.attrs)?;
                let Ty::Tuple(items) = ty else {
                    return Err("tuple pattern needs a tuple".into());
                };
                if items.len() != t.elems.len() {
                    return Err("tuple pattern arity".into());
                }
                let mut out = vec![];
                for (i, (p, item)) in t.elems.iter().zip(items).enumerate() {
                    let part = self.fresh();
                    out.push(format!(
                        ".write {part} (.field (.read {slot}) {})",
                        q(&i.to_string())
                    ));
                    out.extend(self.destructure(frame, p, part, item)?);
                }
                Ok(out)
            }
            syn::Pat::Type(t) => {
                attrs(&t.attrs)?;
                let annotated = self.ty(frame, &t.ty)?;
                Self::require(ty, &annotated)?;
                self.destructure(frame, &t.pat, slot, ty)
            }
            _ => Err(format!("unsupported let pattern {}", tokens(pat))),
        }
    }
    fn block(
        &mut self,
        frame: &Frame<'a>,
        b: &syn::Block,
        expected: Option<&Ty>,
    ) -> Result<(String, Ty), String> {
        let saved = self.env.clone();
        let saved_closures = self.closures.clone();
        let saved_iterators = self.iterators.clone();
        let mut parts = vec![];
        let mut result = Ty::Unit;
        for (i, s) in b.stmts.iter().enumerate() {
            result = Ty::Unit;
            let last = i + 1 == b.stmts.len();
            match s {
                syn::Stmt::Local(l) => {
                    attrs(&l.attrs)?;
                    let init = l.init.as_ref().ok_or("uninitialized local")?;
                    if let Some((_, otherwise)) = &init.diverge {
                        // `let pattern = value else { diverge };` keeps the
                        // pattern's bindings for the rest of the block.
                        if !diverges(otherwise) {
                            return Err("let-else branch must diverge".into());
                        }
                        let (value, ty) = self.expr(frame, &init.expr, None)?;
                        let (otherwise, _) = self.expr(frame, otherwise, None)?;
                        let pattern = self.pattern(frame, &l.pat, &ty)?;
                        parts.push(format!(
                            ".choose ({value}) [({pattern}, {}), (.any, {otherwise})]",
                            unit()
                        ));
                        continue;
                    }
                    if let (syn::Pat::Ident(_), Expr::Closure(c)) = (&l.pat, &*init.expr) {
                        let (name, _) = ident(&l.pat)?;
                        let closure = Closure {
                            syntax: c.clone(),
                            env: self.env.clone(),
                            closures: self.closures.clone(),
                            frame: frame.clone(),
                        };
                        self.closures.insert(name, closure);
                        continue;
                    }
                    if let syn::Pat::Ident(_) = &l.pat {
                        if self.is_iterator(frame, &init.expr) {
                            let (name, _) = ident(&l.pat)?;
                            let lazy = Lazy {
                                expression: (*init.expr).clone(),
                                env: self.env.clone(),
                                closures: self.closures.clone(),
                                frame: frame.clone(),
                            };
                            self.iterators.insert(name, lazy);
                            continue;
                        }
                    }
                    let mut annotated = match &l.pat {
                        syn::Pat::Type(t) => Some(self.ty(frame, &t.ty)?),
                        _ => None,
                    };
                    if annotated.is_none() {
                        let rest = &b.stmts[i + 1..];
                        match &*init.expr {
                            Expr::Repeat(r) if untyped(&r.expr) => {
                                let kind =
                                    self.infer_local(frame, &l.pat, rest, expected, |k| {
                                        Ty::Array(Box::new(Ty::Number(k)))
                                    })?;
                                annotated = Some(Ty::Array(Box::new(Ty::Number(kind))));
                            }
                            e if untyped(e) => {
                                let kind =
                                    self.infer_local(frame, &l.pat, rest, expected, Ty::Number)?;
                                annotated = Some(Ty::Number(kind));
                            }
                            _ => {}
                        }
                    }
                    let (value, ty) = self.expr(frame, &init.expr, annotated.as_ref())?;
                    let slot = self.fresh();
                    parts.push(format!(".write {slot} ({value})"));
                    parts.extend(self.destructure(frame, &l.pat, slot, &ty)?);
                }
                syn::Stmt::Expr(e, semi) => {
                    let (value, ty) = self.expr(
                        frame,
                        e,
                        if last && semi.is_none() {
                            expected
                        } else {
                            None
                        },
                    )?;
                    parts.push(value);
                    if semi.is_none() && last {
                        result = ty;
                    }
                }
                syn::Stmt::Macro(m) => {
                    attrs(&m.attrs)?;
                    parts.push(self.statement_macro(frame, &m.mac)?.0);
                }
                syn::Stmt::Item(_) => return Err("nested items are unsupported".into()),
            }
        }
        if result == Ty::Unit {
            parts.push(unit());
        }
        self.env = saved;
        self.closures = saved_closures;
        self.iterators = saved_iterators;
        Ok((chain(parts), result))
    }
    /// The unique unsigned type with which the rest of the block type-checks,
    /// for an unannotated local initialized by an untyped integer literal (or
    /// an array of one); Rust's inference picks the same type from later uses.
    fn infer_local(
        &mut self,
        frame: &Frame<'a>,
        pat: &syn::Pat,
        rest: &[syn::Stmt],
        expected: Option<&Ty>,
        make: impl Fn(&'static str) -> Ty,
    ) -> Result<&'static str, String> {
        let rest = syn::Block {
            brace_token: Default::default(),
            stmts: rest.to_vec(),
        };
        let mut found = vec![];
        let mut errors = vec![];
        for kind in NUMBERS {
            let snapshot = (
                self.env.clone(),
                self.closures.clone(),
                self.iterators.clone(),
                self.next,
                self.labels,
                self.inlined.clone(),
                self.stack.clone(),
            );
            let ty = make(kind);
            let slot = self.fresh();
            let outcome = self
                .destructure(frame, pat, slot, &ty)
                .and_then(|_| self.block(frame, &rest, expected))
                .and_then(|(_, result)| match expected {
                    // The rest's value must also have the type the context needs.
                    Some(e) if !block_diverges(&rest) => Self::require(&result, e),
                    _ => Ok(()),
                });
            (
                self.env,
                self.closures,
                self.iterators,
                self.next,
                self.labels,
                self.inlined,
                self.stack,
            ) = snapshot;
            match outcome {
                Ok(_) => found.push(*kind),
                Err(e) => errors.push(format!("{kind}: {e}")),
            }
        }
        match found[..] {
            [kind] => Ok(kind),
            [] => Err(format!(
                "no unsigned type fits the local's uses ({})",
                errors.join("; ")
            )),
            // No use constrains the type: Rust falls back to i32.
            _ => Ok("i32"),
        }
    }
    fn statement_macro(
        &mut self,
        frame: &Frame<'a>,
        mac: &syn::Macro,
    ) -> Result<(String, Ty), String> {
        let name = single(&mac.path).ok_or("qualified macro path")?;
        match name.as_str() {
            "unreachable" | "panic" | "todo" | "unimplemented" => {
                Ok((format!(".panic {}", q(&name)), Ty::Unit))
            }
            "assert" => {
                let args = mac
                    .parse_body_with(
                        syn::punctuated::Punctuated::<Expr, syn::Token![,]>::parse_terminated,
                    )
                    .map_err(|e| e.to_string())?;
                let condition = args.first().ok_or("assert without condition")?;
                let (code, ty) = self.expr(frame, condition, Some(&Ty::Bool))?;
                Self::require(&ty, &Ty::Bool)?;
                Ok((
                    format!(".branch ({code}) ({}) (.panic \"assert\")", unit()),
                    Ty::Unit,
                ))
            }
            "matches" => {
                let (value, pattern) = mac
                    .parse_body_with(|input: syn::parse::ParseStream| {
                        let value: Expr = input.parse()?;
                        input.parse::<syn::Token![,]>()?;
                        let pattern = syn::Pat::parse_multi_with_leading_vert(input)?;
                        let _ = input.parse::<Option<syn::Token![,]>>()?;
                        Ok((value, pattern))
                    })
                    .map_err(|e| e.to_string())?;
                let (code, ty) = self.expr(frame, &value, None)?;
                let yes: Expr = syn::parse_quote!(true);
                let no: Expr = syn::parse_quote!(false);
                let wild: syn::Pat = syn::parse_quote!(_);
                self.arms(
                    frame,
                    code,
                    &ty,
                    &[(pattern, &yes), (wild, &no)],
                    Some(&Ty::Bool),
                )
            }
            _ => Err(format!("unsupported macro {name}!")),
        }
    }

    // ---- patterns -------------------------------------------------------

    fn pattern(&mut self, frame: &Frame<'a>, p: &syn::Pat, ty: &Ty) -> Result<String, String> {
        Ok(match p {
            syn::Pat::Wild(w) => {
                attrs(&w.attrs)?;
                ".any".into()
            }
            syn::Pat::Reference(r) => {
                attrs(&r.attrs)?;
                self.pattern(frame, &r.pat, ty)?
            }
            syn::Pat::Paren(r) => {
                attrs(&r.attrs)?;
                self.pattern(frame, &r.pat, ty)?
            }
            syn::Pat::Or(o) => {
                attrs(&o.attrs)?;
                // Every case binds the same names, of the same types, into the
                // same slots, so the arm body sees one environment.
                let before = self.env.clone();
                let mut cases = o.cases.iter();
                let first = self.pattern(frame, cases.next().ok_or("empty or-pattern")?, ty)?;
                let bound = self
                    .env
                    .iter()
                    .filter(|(n, b)| before.get(*n).is_none_or(|old| old.slot != b.slot))
                    .map(|(n, b)| (n.clone(), b.clone()))
                    .collect::<BTreeMap<_, _>>();
                let mut out = vec![first];
                for case in cases {
                    let outer = self.rebind.replace(bound.clone());
                    let used_before = self.env.clone();
                    let compiled = self.pattern(frame, case, ty);
                    self.rebind = outer;
                    let compiled = compiled?;
                    if self.env.len() != used_before.len() {
                        return Err("or-pattern cases bind different names".into());
                    }
                    out.push(compiled);
                }
                format!(".alternatives [{}]", out.join(", "))
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
                    return Err(format!(
                        "identifier pattern {name} names a value; constant patterns are unsupported"
                    ));
                }
                if let Some(rebind) = &self.rebind {
                    let b = rebind
                        .get(&name)
                        .cloned()
                        .ok_or("or-pattern cases bind different names")?;
                    Self::require(&b.ty, ty)?;
                    return Ok(format!(".bind {}", b.slot));
                }
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
                let (owner, tag) = self.variant_path(frame, &path.path, ty)?;
                if !self.members(&owner, Some(&tag))?.is_empty() {
                    return Err("unit pattern for a variant with fields".into());
                }
                format!(".variant {} {} []", q(&name_of(&owner)), q(&tag))
            }
            syn::Pat::TupleStruct(t) => {
                attrs(&t.attrs)?;
                if t.qself.is_none()
                    && (t.path.is_ident("Some") || t.path.is_ident("Ok") || t.path.is_ident("Err"))
                {
                    let [element] = t.elems.iter().collect::<Vec<_>>()[..] else {
                        return Err("constructor pattern takes one element".into());
                    };
                    let name = single(&t.path).unwrap();
                    return Ok(match (name.as_str(), ty) {
                        ("Some", Ty::Option(inner)) => {
                            format!(".present ({})", self.pattern(frame, element, inner)?)
                        }
                        ("Ok", Ty::Result(inner, _)) => format!(
                            ".variant \"Result\" \"Ok\" [(\"0\", {})]",
                            self.pattern(frame, element, inner)?
                        ),
                        ("Err", Ty::Result(_, inner)) => format!(
                            ".variant \"Result\" \"Err\" [(\"0\", {})]",
                            self.pattern(frame, element, inner)?
                        ),
                        _ => return Err(format!("{name} pattern does not match {ty:?}")),
                    });
                }
                let (owner, tag) = self.variant_path(frame, &t.path, ty)?;
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
                format!(
                    ".variant {} {} [{}]",
                    q(&name_of(&owner)),
                    q(&tag),
                    fields.join(", ")
                )
            }
            syn::Pat::Struct(s) => {
                attrs(&s.attrs)?;
                if s.qself.is_some() {
                    return Err("qualified struct pattern".into());
                }
                let (owner, tag) = if s.path.segments.len() == 2 {
                    let (o, t) = self.variant_path(frame, &s.path, ty)?;
                    (o, Some(t))
                } else {
                    Self::require(ty, ty)?;
                    (ty.clone(), None)
                };
                let members = self.members(&owner, tag.as_deref())?;
                let mut fields = vec![];
                for f in &s.fields {
                    attrs(&f.attrs)?;
                    let syn::Member::Named(member) = &f.member else {
                        return Err("unnamed struct pattern field".into());
                    };
                    let (_, field) = members
                        .iter()
                        .find(|(n, _)| member == n)
                        .ok_or("unknown pattern field")?;
                    fields.push(format!(
                        "({}, {})",
                        q(&member.to_string()),
                        self.pattern(frame, &f.pat, field)?
                    ));
                }
                if s.rest.is_none() && s.fields.len() != members.len() {
                    return Err("incomplete struct pattern without rest".into());
                }
                match tag {
                    Some(tag) => format!(
                        ".variant {} {} [{}]",
                        q(&name_of(&owner)),
                        q(&tag),
                        fields.join(", ")
                    ),
                    None => format!(".record {} [{}]", q(&name_of(&owner)), fields.join(", ")),
                }
            }
            syn::Pat::Tuple(t) => {
                attrs(&t.attrs)?;
                let Ty::Tuple(items) = ty else {
                    return Err("tuple pattern needs a tuple".into());
                };
                if items.len() != t.elems.len() {
                    return Err("tuple pattern arity".into());
                }
                let mut fields = vec![];
                for (i, (p, item)) in t.elems.iter().zip(items).enumerate() {
                    fields.push(format!(
                        "({}, {})",
                        q(&i.to_string()),
                        self.pattern(frame, p, item)?
                    ));
                }
                format!(".record {} [{}]", tuple_name(), fields.join(", "))
            }
            _ => return Err(format!("unsupported pattern {}", tokens(p))),
        })
    }
    fn variant_path(
        &self,
        frame: &Frame<'a>,
        p: &syn::Path,
        expected: &Ty,
    ) -> Result<(Ty, String), String> {
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
            frame_self(frame).ok_or("Self outside an impl")?
        } else {
            let resolved = self.krate.resolve(&frame.def.module, &first, 0)?;
            match expected {
                Ty::Named { name, .. } if *name == resolved => expected.clone(),
                _ => Ty::Named {
                    name: resolved,
                    types: vec![],
                    consts: vec![],
                },
            }
        };
        let Ty::Named { name, .. } = &owner else {
            return Err("variant owner is not named".into());
        };
        let e = self
            .krate
            .enums
            .get(name)
            .ok_or("variant owner is not an enum")?;
        let tag = p.segments[1].ident.to_string();
        if !e.variants.iter().any(|v| v.ident == tag) {
            return Err("unknown variant".into());
        }
        Ok((owner, tag))
    }
    fn arms(
        &mut self,
        frame: &Frame<'a>,
        value: String,
        ty: &Ty,
        arms: &[(syn::Pat, &Expr)],
        expected: Option<&Ty>,
    ) -> Result<(String, Ty), String> {
        let mut result: Option<Ty> = expected.cloned();
        let mut out = vec![];
        for (pattern, body) in arms {
            let saved = self.env.clone();
            let p = self.pattern(frame, pattern, ty)?;
            let (b, t) = self.expr(frame, body, result.as_ref())?;
            self.env = saved;
            match &result {
                Some(r) if !diverges(body) && t != Ty::Unit || matches!(r, Ty::Unit) => {
                    if !diverges(body) {
                        Self::require(&t, r)?
                    }
                }
                Some(_) => {}
                None => {
                    if !diverges(body) {
                        result = Some(t)
                    }
                }
            }
            out.push(format!("({p}, {b})"));
        }
        // Rust requires exhaustive matches; a value no arm matches is a
        // representation fault in the machine, never a skipped statement.
        Ok((
            format!(".choose ({value}) [{}]", out.join(", ")),
            result.unwrap_or(Ty::Unit),
        ))
    }

    // ---- closures -------------------------------------------------------

    fn closure_syntax(&self, frame: &Frame<'a>, e: &Expr) -> Result<Closure<'a>, String> {
        let e = match strip(e) {
            Expr::Reference(r) => strip(&r.expr),
            other => other,
        };
        let here = |syntax: syn::ExprClosure| Closure {
            syntax,
            env: self.env.clone(),
            closures: self.closures.clone(),
            frame: frame.clone(),
        };
        match e {
            Expr::Closure(c) => Ok(here(c.clone())),
            Expr::Path(p) if p.qself.is_none() => {
                if let Some(name) = single(&p.path) {
                    if name == "Some" {
                        return Ok(here(syn::parse_quote!(|__provium_x| Some(__provium_x))));
                    }
                    return self
                        .closures
                        .get(&name)
                        .cloned()
                        .ok_or_else(|| format!("unknown closure {name}"));
                }
                // `Type::method` as a callback applies the method to its argument.
                if p.path.segments.len() == 2
                    && p.path
                        .segments
                        .iter()
                        .all(|s| matches!(s.arguments, syn::PathArguments::None))
                {
                    let method = &p.path.segments[1].ident;
                    return Ok(here(syn::parse_quote!(|__provium_x| __provium_x.#method())));
                }
                Err(format!("unsupported callback {}", tokens(e)))
            }
            // Any other value used as a callback is a function pointer: call it.
            other => {
                let callee = other.clone();
                Ok(here(
                    syn::parse_quote!(|__provium_x| (#callee)(__provium_x)),
                ))
            }
        }
    }
    /// Whether an argument expression denotes a closure rather than a value.
    fn closure_argument(&self, e: &Expr) -> bool {
        let e = match strip(e) {
            Expr::Reference(r) => strip(&r.expr),
            other => other,
        };
        match e {
            Expr::Closure(_) => true,
            Expr::Path(p) => single(&p.path).is_some_and(|n| self.closures.contains_key(&n)),
            _ => false,
        }
    }
    fn apply(
        &mut self,
        closure: &Closure<'a>,
        inputs: &[Ty],
        expected: Option<&Ty>,
    ) -> Result<Applied, String> {
        let inputs = inputs.iter().cloned().map(Input::Value).collect::<Vec<_>>();
        self.apply_inputs(closure, inputs, expected)
    }
    /// Compile `closure` applied to inputs of the given types. Its body is
    /// compiled in the environment where it was written, with `return`
    /// returning from the closure.
    fn apply_inputs(
        &mut self,
        closure: &Closure<'a>,
        inputs: Vec<Input<'a>>,
        expected: Option<&Ty>,
    ) -> Result<Applied, String> {
        let frame = &closure.frame;
        let c = &closure.syntax;
        attrs(&c.attrs)?;
        if c.asyncness.is_some()
            || c.constness.is_some()
            || c.movability.is_some()
            || c.lifetimes.is_some()
        {
            return Err("closure must be plain".into());
        }
        if c.inputs.len() != inputs.len() {
            return Err("closure arity mismatch".into());
        }
        let saved = std::mem::replace(&mut self.env, closure.env.clone());
        let saved_closures = std::mem::replace(&mut self.closures, closure.closures.clone());
        let mut slots = vec![];
        let mut setup = vec![];
        let result = (|| {
            for (p, input) in c.inputs.iter().zip(inputs) {
                match input {
                    Input::Value(ty) => {
                        let slot = self.fresh();
                        slots.push(slot);
                        setup.extend(self.destructure(frame, p, slot, &ty)?);
                    }
                    Input::Closure(f) => {
                        let p = match p {
                            syn::Pat::Type(t) => &*t.pat,
                            p => p,
                        };
                        let (name, _) = ident(p)?;
                        self.closures.insert(name, *f);
                    }
                }
            }
            let output = match &c.output {
                syn::ReturnType::Default => expected.cloned(),
                syn::ReturnType::Type(_, t) => Some(self.ty(frame, t)?),
            };
            let inner = Frame {
                def: frame.def,
                generics: frame.generics.clone(),
                receiver: frame.receiver.clone(),
                output: output.clone(),
                loops: vec![],
            };
            let (body, ty) = self.expr(&inner, &c.body, output.as_ref())?;
            setup.push(format!(".scope ({body})"));
            Ok::<_, String>(ty)
        })();
        // Writes a closure makes to captured locals stay in their slots; only
        // the binding scope is restored.
        self.env = saved;
        self.closures = saved_closures;
        let ty = result?;
        Ok(Applied {
            inputs: slots,
            code: chain(setup),
            ty,
        })
    }
    fn call_applied(applied: &Applied, arguments: &[String]) -> String {
        let mut parts = applied
            .inputs
            .iter()
            .zip(arguments)
            .map(|(slot, a)| format!(".write {slot} ({a})"))
            .collect::<Vec<_>>();
        parts.push(applied.code.clone());
        chain(parts)
    }

    // ---- iterators ------------------------------------------------------

    /// The pipeline an iterator-valued expression denotes.
    fn pipeline(&mut self, frame: &Frame<'a>, e: &Expr) -> Result<Pipeline, String> {
        match strip(e) {
            Expr::Range(r) => {
                attrs(&r.attrs)?;
                if !matches!(r.limits, syn::RangeLimits::HalfOpen(_)) {
                    return Err("inclusive ranges are unsupported".into());
                }
                let start = r.start.as_ref().ok_or("unbounded range")?;
                let end = r.end.as_ref().ok_or("unbounded range")?;
                let (hi_code, hi_ty) = self.expr(frame, end, None)?;
                let (lo_code, lo_ty) = self.expr(frame, start, Some(&hi_ty))?;
                Self::require(&lo_ty, &hi_ty)?;
                let Ty::Number(kind) = lo_ty else {
                    return Err("range bounds must be integers".into());
                };
                let lo = self.fresh();
                let hi = self.fresh();
                Ok(Pipeline {
                    setup: vec![
                        format!(".write {lo} ({lo_code})"),
                        format!(".write {hi} ({hi_code})"),
                    ],
                    source: Source::Numbers { lo, hi, kind },
                    reverse: false,
                    stages: vec![],
                    item: Ty::Number(kind),
                })
            }
            Expr::Reference(r) if r.mutability.is_some() => {
                attrs(&r.attrs)?;
                self.elements(frame, &r.expr, true)
            }
            Expr::MethodCall(c) => {
                attrs(&c.attrs)?;
                let method = c.method.to_string();
                let args = c.args.iter().collect::<Vec<_>>();
                match (method.as_str(), args.as_slice()) {
                    ("iter", []) => self.elements(frame, &c.receiver, false),
                    ("into_iter", []) => self.pipeline(frame, &c.receiver),
                    ("clone", []) if self.is_iterator(frame, &c.receiver) => {
                        self.pipeline(frame, &c.receiver)
                    }
                    ("rev", []) => {
                        let mut p = self.pipeline(frame, &c.receiver)?;
                        if p.stages
                            .iter()
                            .any(|s| matches!(s, Stage::Enumerate(_) | Stage::TakeWhile(_)))
                        {
                            return Err(
                                "rev after an order-dependent adapter is unsupported".into()
                            );
                        }
                        p.reverse = !p.reverse;
                        Ok(p)
                    }
                    ("flatten", []) => {
                        let mut p = self.pipeline(frame, &c.receiver)?;
                        let Ty::Option(inner) = p.item.clone() else {
                            return Err("flatten requires Option items".into());
                        };
                        p.stages.push(Stage::Flatten);
                        p.item = *inner;
                        Ok(p)
                    }
                    ("copied" | "cloned", []) => {
                        let mut p = self.pipeline(frame, &c.receiver)?;
                        if method == "copied" {
                            self.copy(&p.item)?;
                        } else {
                            p.stages.push(Stage::Clone(p.item.clone()));
                        }
                        Ok(p)
                    }
                    ("enumerate", []) => {
                        let mut p = self.pipeline(frame, &c.receiver)?;
                        let count = self.fresh();
                        p.setup
                            .push(format!(".write {count} ({})", usize_literal(0)));
                        p.stages.push(Stage::Enumerate(count));
                        p.item = Ty::Tuple(vec![Ty::Number("usize"), p.item]);
                        Ok(p)
                    }
                    ("map" | "filter" | "filter_map" | "take_while", [f]) => {
                        let mut p = self.pipeline(frame, &c.receiver)?;
                        let closure = self.closure_syntax(frame, f)?;
                        let expected = match method.as_str() {
                            "filter" | "take_while" => Some(Ty::Bool),
                            _ => None,
                        };
                        let applied =
                            self.apply(&closure, std::slice::from_ref(&p.item), expected.as_ref())?;
                        match method.as_str() {
                            "map" => {
                                p.item = applied.ty.clone();
                                p.stages.push(Stage::Map(applied));
                            }
                            "filter" => {
                                Self::require(&applied.ty, &Ty::Bool)?;
                                p.stages.push(Stage::Filter(applied));
                            }
                            "take_while" => {
                                Self::require(&applied.ty, &Ty::Bool)?;
                                p.stages.push(Stage::TakeWhile(applied));
                            }
                            _ => {
                                let Ty::Option(inner) = applied.ty.clone() else {
                                    return Err("filter_map callback must return Option".into());
                                };
                                p.item = *inner;
                                p.stages.push(Stage::FilterMap(applied));
                            }
                        }
                        Ok(p)
                    }
                    _ => {
                        // A crate method returning `impl Iterator`: inline its
                        // tail expression as the pipeline.
                        self.iterator_method(frame, c)
                    }
                }
            }
            Expr::Path(p) if single(&p.path).is_some_and(|n| self.iterators.contains_key(&n)) => {
                let lazy = self.iterators[&single(&p.path).unwrap()].clone();
                let saved = std::mem::replace(&mut self.env, lazy.env.clone());
                let saved_closures = std::mem::replace(&mut self.closures, lazy.closures.clone());
                let result = self.pipeline(&lazy.frame, &lazy.expression);
                self.env = saved;
                self.closures = saved_closures;
                result
            }
            other => self.elements(frame, other, false),
        }
    }
    /// Elements of an array or of a range-indexed slice of one.
    fn elements(&mut self, frame: &Frame<'a>, e: &Expr, mutable: bool) -> Result<Pipeline, String> {
        let e = match e {
            Expr::Paren(p) => &*p.expr,
            _ => e,
        };
        let (base, range) = match e {
            Expr::Index(i) if matches!(&*i.index, Expr::Range(_)) => {
                attrs(&i.attrs)?;
                let Expr::Range(r) = &*i.index else {
                    unreachable!()
                };
                (&*i.expr, Some(r))
            }
            _ => (e, None),
        };
        let array = self.fresh();
        let lo = self.fresh();
        let hi = self.fresh();
        let mut setup = vec![];
        let (element, places) = if mutable {
            let place = self.place(frame, base)?;
            if !place.mutable {
                return Err("mutable iteration over an immutable place".into());
            }
            let Ty::Array(element) = place.ty.clone() else {
                return Err("mutable iteration requires an array".into());
            };
            setup.extend(place.setup.iter().cloned());
            setup.push(format!(".write {array} ({})", Self::place_read(&place)));
            (*element, Some((place.slot, place.path)))
        } else {
            let (code, ty) = self.expr(frame, base, None)?;
            let Ty::Array(element) = ty else {
                return Err(format!("iteration requires a builtin array, found {ty:?}"));
            };
            setup.push(format!(".write {array} ({code})"));
            (*element, None)
        };
        let usize_ty = Ty::Number("usize");
        let start = match range.and_then(|r| r.start.as_ref()) {
            Some(s) => {
                let (code, ty) = self.expr(frame, s, Some(&usize_ty))?;
                Self::require(&ty, &usize_ty)?;
                code
            }
            None => usize_literal(0),
        };
        let end = match range.and_then(|r| r.end.as_ref()) {
            Some(s) => {
                let (code, ty) = self.expr(frame, s, Some(&usize_ty))?;
                Self::require(&ty, &usize_ty)?;
                code
            }
            None => format!(".length (.read {array})"),
        };
        if range.is_some_and(|r| !matches!(r.limits, syn::RangeLimits::HalfOpen(_))) {
            return Err("inclusive slice ranges are unsupported".into());
        }
        setup.push(format!(".write {lo} ({start})"));
        setup.push(format!(".write {hi} ({end})"));
        // Slicing panics unless lo <= hi <= len.
        setup.push(format!(
            ".branch (.binary \"&&\" (.binary \"<=\" (.read {lo}) (.read {hi})) (.binary \"<=\" (.read {hi}) (.length (.read {array})))) ({}) (.panic \"slice index\")",
            unit()
        ));
        Ok(Pipeline {
            setup,
            source: Source::Elements {
                array,
                lo,
                hi,
                places,
            },
            reverse: false,
            stages: vec![],
            item: element,
        })
    }
    fn iterator_method(
        &mut self,
        frame: &Frame<'a>,
        c: &syn::ExprMethodCall,
    ) -> Result<Pipeline, String> {
        let (receiver_code, receiver_ty, place) = self.receiver(frame, &c.receiver)?;
        let (key, def) = self.method_definition(&receiver_ty, &c.method.to_string())?;
        if !c.args.is_empty() {
            return Err("iterator methods with arguments are unsupported".into());
        }
        let syn::ReturnType::Type(_, output) = &def.item.sig.output else {
            return Err("iterator method without result".into());
        };
        if !matches!(&**output, Type::ImplTrait(_)) {
            return Err(format!("opaque iterator source {}", c.method));
        }
        let [syn::Stmt::Expr(tail, None)] = def.item.block.stmts.as_slice() else {
            return Err("iterator method must be a single expression".into());
        };
        drop(place);
        let slot = self.fresh();
        let generics = self.instance(&self.impl_generics_of(def), &receiver_ty);
        let inner = Frame {
            def,
            generics,
            receiver: Some((slot, receiver_ty, false)),
            output: None,
            loops: vec![],
        };
        self.enter(&key)?;
        let saved = std::mem::take(&mut self.env);
        let pipeline = self.pipeline(&inner, tail);
        self.env = saved;
        self.stack.pop();
        let mut pipeline = pipeline?;
        pipeline
            .setup
            .insert(0, format!(".write {slot} ({receiver_code})"));
        Ok(pipeline)
    }
    /// Lower a loop over `p`: `body` receives the item slot and the break and
    /// continue labels, and returns the per-item code.
    fn iterate(
        &mut self,
        p: Pipeline,
        body: impl FnOnce(
            &mut Self,
            usize,
            usize,
            usize,
            Option<(usize, Vec<String>)>,
        ) -> Result<String, String>,
    ) -> Result<String, String> {
        let exit = self.label();
        let next = self.label();
        let item = self.fresh();
        let cursor = self.fresh();
        let mut parts = p.setup;
        let (lo, hi, fetch, places) = match &p.source {
            Source::Elements {
                array,
                lo,
                hi,
                places,
            } => (
                *lo,
                *hi,
                format!(".index (.read {array}) (.read {cursor})"),
                places.clone(),
            ),
            Source::Numbers { lo, hi, .. } => (*lo, *hi, format!(".read {cursor}"), None),
        };
        let kind = match &p.source {
            Source::Elements { .. } => "usize",
            Source::Numbers { kind, .. } => kind,
        };
        let one = format!(".literal (.number {} 1)", q(kind));
        let (start, end) = if p.reverse { (hi, lo) } else { (lo, hi) };
        parts.push(format!(".write {cursor} (.read {start})"));
        let advance = if p.reverse {
            vec![
                format!(".write {cursor} (.binary \"-\" (.read {cursor}) ({one}))"),
                format!(".write {item} ({fetch})"),
            ]
        } else {
            vec![
                format!(".write {item} ({fetch})"),
                format!(".write {cursor} (.binary \"+\" (.read {cursor}) ({one}))"),
            ]
        };
        let mut per_item = vec![];
        let mut alias_slot = None;
        if let Some((slot, path)) = &places {
            // Remember the element's index for writes through the binding: the
            // cursor after a reversed step, or one below it after a forward one.
            let position = self.fresh();
            per_item.push(format!(
                ".write {position} ({})",
                if p.reverse {
                    format!(".read {cursor}")
                } else {
                    format!(".binary \"-\" (.read {cursor}) ({one})")
                }
            ));
            let mut path = path.clone();
            path.push(format!(".index {position}"));
            alias_slot = Some((*slot, path));
        }
        for stage in p.stages {
            match stage {
                Stage::Flatten => per_item.push(format!(
                    ".choose (.read {item}) [(.present (.bind {item}), {}), (.any, .exit {next} ({}))]",
                    unit(),
                    unit()
                )),
                Stage::Map(f) => per_item.push(format!(
                    ".write {item} ({})",
                    Self::call_applied(&f, &[format!(".read {item}")])
                )),
                Stage::Filter(f) => per_item.push(format!(
                    ".branch ({}) ({}) (.exit {next} ({}))",
                    Self::call_applied(&f, &[format!(".read {item}")]),
                    unit(),
                    unit()
                )),
                Stage::TakeWhile(f) => per_item.push(format!(
                    ".branch ({}) ({}) (.exit {exit} ({}))",
                    Self::call_applied(&f, &[format!(".read {item}")]),
                    unit(),
                    unit()
                )),
                Stage::FilterMap(f) => per_item.push(format!(
                    ".choose ({}) [(.present (.bind {item}), {}), (.any, .exit {next} ({}))]",
                    Self::call_applied(&f, &[format!(".read {item}")]),
                    unit(),
                    unit()
                )),
                Stage::Enumerate(count) => {
                    per_item.push(format!(
                        ".write {item} (.record {} [(\"0\", .read {count}), (\"1\", .read {item})])",
                        tuple_name()
                    ));
                    per_item.push(format!(
                        ".write {count} (.binary \"+\" (.read {count}) ({}))",
                        usize_literal(1)
                    ));
                }
                Stage::Clone(ty) => {
                    let code = self.clone_value(format!(".read {item}"), &ty)?;
                    per_item.push(format!(".write {item} ({code})"));
                }
            }
        }
        per_item.push(body(self, item, exit, next, alias_slot)?);
        let mut step = vec![format!(
            ".branch (.binary \"==\" (.read {cursor}) (.read {end})) (.exit {exit} ({})) ({})",
            unit(),
            unit()
        )];
        step.extend(advance);
        step.push(format!(".block {next} ({})", chain(per_item)));
        parts.push(format!(".block {exit} (.loop ({}))", chain(step)));
        Ok(chain(parts))
    }
    /// Consume `p` with an iterator method returning a value.
    fn consume(
        &mut self,
        frame: &Frame<'a>,
        p: Pipeline,
        method: &str,
        args: &[&Expr],
    ) -> Result<(String, Ty), String> {
        let result = self.fresh();
        let item_ty = p.item.clone();
        match (method, args) {
            ("next", []) | ("next_back", []) | ("last", []) => {
                let mut p = p;
                if method == "next_back" {
                    if p.stages
                        .iter()
                        .any(|s| matches!(s, Stage::Enumerate(_) | Stage::TakeWhile(_)))
                    {
                        return Err("next_back after an order-dependent adapter".into());
                    }
                    p.reverse = !p.reverse;
                }
                let stop = method != "last";
                let code = self.iterate(p, |_, item, exit, _, _| {
                    Ok(if stop {
                        seq(
                            format!(".write {result} (.present (.read {item}))"),
                            format!(".exit {exit} ({})", unit()),
                        )
                    } else {
                        format!(".write {result} (.present (.read {item}))")
                    })
                })?;
                Ok((
                    chain(vec![
                        format!(".write {result} (.literal .absent)"),
                        code,
                        format!(".read {result}"),
                    ]),
                    Ty::Option(Box::new(item_ty)),
                ))
            }
            ("count", []) => {
                let code = self.iterate(p, |_, _, _, _, _| {
                    Ok(format!(
                        ".write {result} (.binary \"+\" (.read {result}) ({}))",
                        usize_literal(1)
                    ))
                })?;
                Ok((
                    chain(vec![
                        format!(".write {result} ({})", usize_literal(0)),
                        code,
                        format!(".read {result}"),
                    ]),
                    Ty::Number("usize"),
                ))
            }
            ("max" | "min", []) => {
                let Ty::Number(_) = item_ty else {
                    return Err("max/min require integer items".into());
                };
                let pick = if method == "max" { ">=" } else { "<" };
                let code = self.iterate(p, |_, item, _, _, _| {
                    Ok(format!(
                        ".choose (.read {result}) [(.present (.bind {result}), .branch (.binary {} (.read {item}) (.read {result})) (.write {result} (.present (.read {item}))) (.write {result} (.present (.read {result})))), (.any, .write {result} (.present (.read {item})))]",
                        q(pick)
                    ))
                })?;
                Ok((
                    chain(vec![
                        format!(".write {result} (.literal .absent)"),
                        code,
                        format!(".read {result}"),
                    ]),
                    Ty::Option(Box::new(item_ty)),
                ))
            }
            ("any" | "all" | "position" | "find", [f]) => {
                let closure = self.closure_syntax(frame, f)?;
                let applied =
                    self.apply(&closure, std::slice::from_ref(&item_ty), Some(&Ty::Bool))?;
                Self::require(&applied.ty, &Ty::Bool)?;
                let index = self.fresh();
                let initial = match method {
                    "any" => boolean(false),
                    "all" => boolean(true),
                    _ => ".literal .absent".into(),
                };
                let code = self.iterate(p, |_, item, exit, _, _| {
                    let test = Self::call_applied(&applied, &[format!(".read {item}")]);
                    let done = format!(".exit {exit} ({})", unit());
                    Ok(match method {
                        "any" => format!(".branch ({test}) ({}) ({})", seq(format!(".write {result} ({})", boolean(true)), done), unit()),
                        "all" => format!(".branch ({test}) ({}) ({})", unit(), seq(format!(".write {result} ({})", boolean(false)), done)),
                        "find" => format!(".branch ({test}) ({}) ({})", seq(format!(".write {result} (.present (.read {item}))"), done), unit()),
                        _ => format!(
                            ".branch ({test}) ({}) (.write {index} (.binary \"+\" (.read {index}) ({})))",
                            seq(format!(".write {result} (.present (.read {index}))"), done),
                            usize_literal(1)
                        ),
                    })
                })?;
                let ty = match method {
                    "any" | "all" => Ty::Bool,
                    "position" => Ty::Option(Box::new(Ty::Number("usize"))),
                    _ => Ty::Option(Box::new(item_ty)),
                };
                Ok((
                    chain(vec![
                        format!(".write {result} ({initial})"),
                        format!(".write {index} ({})", usize_literal(0)),
                        code,
                        format!(".read {result}"),
                    ]),
                    ty,
                ))
            }
            _ => Err(format!("unsupported iterator consumer {method}")),
        }
    }

    // ---- calls ----------------------------------------------------------

    fn impl_generics_of(&self, def: &Definition) -> syn::Generics {
        def.impl_generics.clone()
    }
    fn enter(&mut self, key: &str) -> Result<(), String> {
        if self.stack.iter().any(|k| k == key) || self.stack.len() > 48 {
            return Err(format!("recursive call to {key}"));
        }
        self.stack.push(key.to_owned());
        if !self.inlined.iter().any(|k| k == key) {
            self.inlined.push(key.to_owned());
        }
        Ok(())
    }
    /// The unique inherent method `name` of the receiver type.
    fn method_definition(
        &self,
        receiver: &Ty,
        name: &str,
    ) -> Result<(String, &'a Definition), String> {
        let Ty::Named { name: owner, .. } = receiver else {
            return Err(format!("method {name} on {receiver:?}"));
        };
        if self
            .krate
            .crate_trait_methods
            .iter()
            .any(|(m, _)| m == name)
        {
            return Err(format!(
                "a crate trait method shares the method name {name}"
            ));
        }
        let candidates = self
            .krate
            .methods
            .iter()
            .filter(|(_, d)| d.receiver == *owner && d.item.sig.ident == name)
            .collect::<Vec<_>>();
        let [(key, def)] = candidates[..] else {
            return Err(format!("method {owner}::{name} is unknown or ambiguous"));
        };
        Ok((key.clone(), def))
    }
    /// Evaluate a method-call receiver: its value, type, and its place when it
    /// can be written back.
    fn receiver(
        &mut self,
        frame: &Frame<'a>,
        e: &Expr,
    ) -> Result<(String, Ty, Option<Place>), String> {
        let e = strip(e);
        if let Ok(place) = {
            let saved = self.next;
            let attempt = self.place(frame, e);
            if attempt.is_err() {
                self.next = saved;
            }
            attempt
        } {
            let mut parts = place.setup.clone();
            parts.push(Self::place_read(&place));
            let ty = place.ty.clone();
            return Ok((chain(parts), ty, Some(place)));
        }
        let (code, ty) = self.expr(frame, e, None)?;
        Ok((code, ty, None))
    }
    /// Inline a call of `def` with an optional receiver and argument values.
    #[allow(clippy::too_many_arguments)]
    fn inline(
        &mut self,
        frame: &Frame<'a>,
        key: &str,
        def: &'a Definition,
        receiver: Option<(String, Ty, Option<Place>)>,
        args: &[&Expr],
        generics: Generics,
    ) -> Result<(String, Ty), String> {
        let sig = &def.item.sig;
        let closure_free = !sig
            .inputs
            .iter()
            .any(|i| matches!(i, syn::FnArg::Typed(t) if callable(&t.ty)))
            && !matches!(&sig.output, syn::ReturnType::Type(_, t) if matches!(&**t, Type::ImplTrait(_)));
        if closure_free && sig.generics.params.is_empty() {
            return self.invoke(frame, key, def, receiver, args, generics);
        }
        attrs(&def.item.attrs)?;
        if sig.asyncness.is_some()
            || sig.unsafety.is_some()
            || sig.abi.is_some()
            || sig.constness.is_some()
        {
            return Err("inlined function must be plain".into());
        }
        if !sig.generics.params.is_empty() || sig.generics.where_clause.is_some() {
            return Err(format!("generic function {key} is unsupported"));
        }
        let mut inputs = sig.inputs.iter();
        let mut parts = vec![];
        let mut receiver_frame = None;
        let mut write_back = None;
        match (sig.inputs.first(), receiver) {
            (Some(syn::FnArg::Receiver(r)), Some((code, ty, place))) => {
                inputs.next();
                attrs(&r.attrs)?;
                if r.reference.is_none() || r.colon_token.is_some() {
                    return Err("inlined method requires &self or &mut self".into());
                }
                let mutable = r.mutability.is_some();
                // A receiver already in its own slot (`self`) is used in place.
                let in_place = place.as_ref().filter(|p| p.path.is_empty()).map(|p| p.slot);
                let slot = match in_place {
                    Some(slot) => {
                        if mutable && !place.as_ref().unwrap().mutable {
                            return Err("&mut self call through an immutable place".into());
                        }
                        slot
                    }
                    None => {
                        let slot = self.fresh();
                        parts.push(format!(".write {slot} ({code})"));
                        if mutable {
                            let place = place.ok_or("&mut self call on a temporary")?;
                            if !place.mutable {
                                return Err("&mut self call through an immutable place".into());
                            }
                            write_back = Some(place);
                        }
                        slot
                    }
                };
                receiver_frame = Some((slot, ty, mutable));
            }
            (Some(syn::FnArg::Receiver(_)), None) => return Err(format!("{key} needs a receiver")),
            (_, Some(_)) => return Err(format!("{key} is not a method")),
            _ => {}
        }
        let self_ty = receiver_frame
            .as_ref()
            .map(|r| r.1.clone())
            .or_else(|| frame_self_of(def, &generics, self));
        let output = match &sig.output {
            syn::ReturnType::Default => Ty::Unit,
            syn::ReturnType::Type(_, t) => self.ty_in(
                t,
                &def.impl_generics,
                &generics,
                &def.module,
                self_ty.as_ref(),
            )?,
        };
        let inputs = inputs.collect::<Vec<_>>();
        if inputs.len() != args.len() {
            return Err(format!("argument count mismatch calling {key}"));
        }
        let mut bindings = vec![];
        let mut closure_params = vec![];
        for (input, arg) in inputs.iter().zip(args) {
            let syn::FnArg::Typed(t) = input else {
                return Err("unexpected receiver".into());
            };
            attrs(&t.attrs)?;
            if callable(&t.ty) {
                let (name, _) = ident(&t.pat)?;
                closure_params.push((name, self.closure_syntax(frame, arg)?));
                continue;
            }
            if matches!(&*t.ty, Type::Reference(r) if r.mutability.is_some()) {
                return Err("&mut parameters are unsupported".into());
            }
            let ty = self.ty_in(
                &t.ty,
                &def.impl_generics,
                &generics,
                &def.module,
                self_ty.as_ref(),
            )?;
            let (value, actual) = self.expr(frame, arg, Some(&ty))?;
            Self::require(&actual, &ty)?;
            let slot = self.fresh();
            parts.push(format!(".write {slot} ({value})"));
            bindings.push((t.pat.clone(), slot, ty));
        }
        self.enter(key)?;
        let saved = std::mem::take(&mut self.env);
        let saved_closures =
            std::mem::replace(&mut self.closures, closure_params.into_iter().collect());
        let saved_iterators = std::mem::take(&mut self.iterators);
        let inner = Frame {
            def,
            generics,
            receiver: receiver_frame.clone(),
            output: Some(output.clone()),
            loops: vec![],
        };
        let body = (|| {
            let mut setup = vec![];
            for (pat, slot, ty) in &bindings {
                setup.extend(self.destructure(&inner, pat, *slot, ty)?);
            }
            let (body, ty) = self.block(&inner, &def.item.block, Some(&output))?;
            if ty != output && !(ty == Ty::Unit && block_diverges(&def.item.block)) {
                Self::require(&ty, &output)?;
            }
            setup.push(body);
            Ok::<_, String>(chain(setup))
        })();
        self.stack.pop();
        self.env = saved;
        self.closures = saved_closures;
        self.iterators = saved_iterators;
        let body = body.map_err(|e| format!("{e} (in {key})"))?;
        let result = self.fresh();
        parts.push(format!(".write {result} (.scope ({body}))"));
        if let (Some(place), Some((slot, _, _))) = (write_back, receiver_frame) {
            parts.extend(place.setup.iter().cloned());
            parts.push(Self::place_write(&place, format!(".read {slot}")));
        }
        parts.push(format!(".read {result}"));
        Ok((chain(parts), output))
    }
    fn method_call(
        &mut self,
        frame: &Frame<'a>,
        c: &syn::ExprMethodCall,
        expected: Option<&Ty>,
    ) -> Result<(String, Ty), String> {
        attrs(&c.attrs)?;
        if c.turbofish.is_some() {
            return Err("method type arguments are unsupported".into());
        }
        let method = c.method.to_string();
        let args = c.args.iter().collect::<Vec<_>>();
        if BUILTIN_METHODS.contains(&method.as_str())
            && self
                .krate
                .crate_trait_methods
                .iter()
                .any(|(m, _)| *m == method)
        {
            return Err(format!("a crate trait method shadows builtin {method}"));
        }
        // Iterator consumers over a pipeline.
        if matches!(
            method.as_str(),
            "next"
                | "next_back"
                | "last"
                | "count"
                | "any"
                | "all"
                | "position"
                | "find"
                | "max"
                | "min"
        ) && self.is_iterator(frame, &c.receiver)
        {
            let p = self.pipeline(frame, &c.receiver)?;
            return self.consume(frame, p, &method, &args);
        }
        if let Expr::Index(i) = strip(&c.receiver) {
            if let Expr::Range(range) = &*i.index {
                return self.slice_method(frame, &i.expr, range, &method, &args);
            }
        }
        let (receiver_code, receiver_ty, place) = self.receiver(frame, &c.receiver)?;
        if let Ty::Named { .. } = &receiver_ty {
            if method != "clone" || self.method_definition(&receiver_ty, "clone").is_ok() {
                let (key, def) = self.method_definition(&receiver_ty, &method)?;
                let generics = self.instance(&def.impl_generics, &receiver_ty);
                // Map the impl's generics through its self type onto the instance.
                let generics = self.impl_instance(def, &receiver_ty).unwrap_or(generics);
                return self.inline(
                    frame,
                    &key,
                    def,
                    Some((receiver_code, receiver_ty, place)),
                    &args,
                    generics,
                );
            }
        }
        self.builtin_method(
            frame,
            &method,
            receiver_code,
            receiver_ty,
            place,
            &args,
            expected,
        )
    }
    fn is_iterator(&self, frame: &Frame<'a>, e: &Expr) -> bool {
        match strip(e) {
            Expr::MethodCall(c) => {
                matches!(
                    c.method.to_string().as_str(),
                    "iter"
                        | "into_iter"
                        | "rev"
                        | "flatten"
                        | "copied"
                        | "cloned"
                        | "enumerate"
                        | "map"
                        | "filter"
                        | "filter_map"
                        | "take_while"
                ) && (c.method != "map"
                    && c.method != "filter"
                    && c.method != "cloned"
                    && c.method != "copied"
                    || self.is_iterator(frame, &c.receiver))
                    || self.returns_iterator(frame, c)
                    || c.method == "clone" && self.is_iterator(frame, &c.receiver)
            }
            Expr::Range(_) => true,
            Expr::Path(p) => single(&p.path).is_some_and(|n| self.iterators.contains_key(&n)),
            _ => false,
        }
    }
    fn returns_iterator(&self, frame: &Frame<'a>, c: &syn::ExprMethodCall) -> bool {
        let receiver_ty = match strip(&c.receiver) {
            e if is_self(e) => frame.receiver.as_ref().map(|r| r.1.clone()),
            Expr::Field(f) if is_self(&f.base) => frame
                .receiver
                .as_ref()
                .and_then(|r| self.field(&r.1, &f.member).ok().map(|x| x.1)),
            _ => None,
        };
        receiver_ty
            .and_then(|t| self.method_definition(&t, &c.method.to_string()).ok())
            .is_some_and(|(_, d)| matches!(&d.item.sig.output, syn::ReturnType::Type(_, t) if matches!(&**t, Type::ImplTrait(_))))
    }
    /// The impl's generics instantiated by matching its self type's arguments
    /// against the receiver instance.
    fn impl_instance(&self, def: &Definition, receiver: &Ty) -> Option<Generics> {
        let Type::Path(p) = def.self_type.as_ref()? else {
            return None;
        };
        let segment = p.path.segments.last()?;
        let Ty::Named {
            name,
            types,
            consts,
        } = receiver
        else {
            return None;
        };
        let decl = self
            .krate
            .structs
            .get(name)
            .map(|s| &s.generics)
            .or_else(|| self.krate.enums.get(name).map(|e| &e.generics))?;
        let syn::PathArguments::AngleBracketed(a) = &segment.arguments else {
            return Some(Generics::default());
        };
        let mut out = Generics::default();
        let mut t = types.iter();
        let mut c = consts.iter();
        for (param, arg) in decl
            .params
            .iter()
            .filter(|p| !matches!(p, syn::GenericParam::Lifetime(_)))
            .zip(
                a.args
                    .iter()
                    .filter(|a| !matches!(a, syn::GenericArgument::Lifetime(_))),
            )
        {
            let name = match arg {
                syn::GenericArgument::Type(Type::Path(p)) => single(&p.path),
                syn::GenericArgument::Const(Expr::Path(p)) => single(&p.path),
                _ => None,
            };
            match param {
                syn::GenericParam::Type(_) => {
                    let value = t.next().cloned()?;
                    if let Some(n) = name {
                        out.types.insert(n, value);
                    }
                }
                syn::GenericParam::Const(_) => {
                    let value = c.next().cloned()?;
                    if let Some(n) = name {
                        out.consts.insert(n, value);
                    }
                }
                syn::GenericParam::Lifetime(_) => {}
            }
        }
        Some(out)
    }
    /// `array[lo..hi].method(args)` for in-place slice methods and `len`.
    fn slice_method(
        &mut self,
        frame: &Frame<'a>,
        base: &Expr,
        range: &syn::ExprRange,
        method: &str,
        args: &[&Expr],
    ) -> Result<(String, Ty), String> {
        if !matches!(range.limits, syn::RangeLimits::HalfOpen(_)) {
            return Err("inclusive slice ranges are unsupported".into());
        }
        let place = self.place(frame, base)?;
        let Ty::Array(element) = place.ty.clone() else {
            return Err("slicing requires a builtin array".into());
        };
        let usize_ty = Ty::Number("usize");
        let array = self.fresh();
        let lo = self.fresh();
        let hi = self.fresh();
        let mut parts = place.setup.clone();
        parts.push(format!(".write {array} ({})", Self::place_read(&place)));
        let start = match &range.start {
            Some(e) => {
                let (c, t) = self.expr(frame, e, Some(&usize_ty))?;
                Self::require(&t, &usize_ty)?;
                c
            }
            None => usize_literal(0),
        };
        let end = match &range.end {
            Some(e) => {
                let (c, t) = self.expr(frame, e, Some(&usize_ty))?;
                Self::require(&t, &usize_ty)?;
                c
            }
            None => format!(".length (.read {array})"),
        };
        parts.push(format!(".write {lo} ({start})"));
        parts.push(format!(".write {hi} ({end})"));
        parts.push(format!(
            ".branch (.binary \"&&\" (.binary \"<=\" (.read {lo}) (.read {hi})) (.binary \"<=\" (.read {hi}) (.length (.read {array})))) ({}) (.panic \"slice index\")",
            unit()
        ));
        let updated = match (method, args) {
            ("len", []) => {
                parts.push(format!(".binary \"-\" (.read {hi}) (.read {lo})"));
                return Ok((chain(parts), usize_ty));
            }
            ("sort_unstable", []) => {
                let Ty::Number(_) = *element else {
                    return Err("sort_unstable is modeled for integer slices only".into());
                };
                format!(".sort (.read {array}) (.read {lo}) (.read {hi})")
            }
            ("rotate_left", [amount]) => {
                let (code, t) = self.expr(frame, amount, Some(&usize_ty))?;
                Self::require(&t, &usize_ty)?;
                format!(".rotate (.read {array}) (.read {lo}) (.read {hi}) ({code})")
            }
            _ => return Err(format!("unsupported slice method {method}")),
        };
        if !place.mutable {
            return Err(format!("{method} through an immutable place"));
        }
        parts.push(Self::place_write(
            &Place {
                setup: vec![],
                ..place
            },
            updated,
        ));
        parts.push(unit());
        Ok((chain(parts), Ty::Unit))
    }
    fn clone_value(&mut self, code: String, ty: &Ty) -> Result<String, String> {
        if self.copy(ty).is_ok() {
            return Ok(code);
        }
        match ty {
            Ty::Opaque(_) => Ok(format!(".external \"clone\" [{code}]")),
            Ty::Option(inner) => {
                let slot = self.fresh();
                let cloned = self.clone_value(format!(".read {slot}"), inner)?;
                Ok(format!(".choose ({code}) [(.present (.bind {slot}), .present ({cloned})), (.any, .literal .absent)]"))
            }
            Ty::Named { name, .. } if self.krate.structs.contains_key(name) => {
                let s = &self.krate.structs[name];
                if !Self::derives(&s.attrs, "Clone")? {
                    return Err(format!("{name} must derive Clone"));
                }
                let value = self.fresh();
                let mut fields = vec![];
                for (field, field_ty) in self.members(ty, None)? {
                    let cloned = self
                        .clone_value(format!(".field (.read {value}) {}", q(&field)), &field_ty)?;
                    fields.push(format!("({}, {cloned})", q(&field)));
                }
                Ok(seq(
                    format!(".write {value} ({code})"),
                    format!(".record {} [{}]", q(name), fields.join(", ")),
                ))
            }
            _ => Err(format!("Clone is not modeled for {ty:?}")),
        }
    }
    #[allow(clippy::too_many_arguments)]
    fn builtin_method(
        &mut self,
        frame: &Frame<'a>,
        method: &str,
        value: String,
        ty: Ty,
        place: Option<Place>,
        args: &[&Expr],
        expected: Option<&Ty>,
    ) -> Result<(String, Ty), String> {
        let stored = self.fresh();
        let store = format!(".write {stored} ({value})");
        let read = format!(".read {stored}");
        let absent = ".literal .absent".to_string();
        let out = match (method, &ty, args) {
            ("clone", _, []) => (self.clone_value(value, &ty)?, ty.clone()),
            ("is_some" | "is_none", Ty::Option(_), []) => {
                let some = method == "is_some";
                (
                    format!(
                        ".choose ({value}) [(.present .any, {}), (.any, {})]",
                        boolean(some),
                        boolean(!some)
                    ),
                    Ty::Bool,
                )
            }
            ("as_ref" | "as_mut" | "copied", Ty::Option(_), []) => (value, ty.clone()),
            ("is_ok" | "is_err", Ty::Result(..), []) => {
                let ok = method == "is_ok";
                (format!(".choose ({value}) [(.variant \"Result\" \"Ok\" [(\"0\", .any)], {}), (.any, {})]", boolean(ok), boolean(!ok)), Ty::Bool)
            }
            ("cloned", Ty::Option(inner), []) => {
                let x = self.fresh();
                let cloned = self.clone_value(format!(".read {x}"), inner)?;
                (format!(".choose ({value}) [(.present (.bind {x}), .present ({cloned})), (.any, {absent})]"), ty.clone())
            }
            (
                "is_some_and" | "is_none_or" | "map" | "and_then" | "filter",
                Ty::Option(inner),
                [f],
            ) => {
                let closure = self.closure_syntax(frame, f)?;
                let want = match method {
                    "is_some_and" | "is_none_or" | "filter" => Some(Ty::Bool),
                    "and_then" => expected.cloned(),
                    _ => expected.and_then(|e| {
                        if let Ty::Option(i) = e {
                            Some((**i).clone())
                        } else {
                            None
                        }
                    }),
                };
                let applied = self.apply(&closure, std::slice::from_ref(inner), want.as_ref())?;
                let x = self.fresh();
                let call = Self::call_applied(&applied, &[format!(".read {x}")]);
                match method {
                    "is_some_and" | "is_none_or" => {
                        Self::require(&applied.ty, &Ty::Bool)?;
                        (format!(".choose ({value}) [(.present (.bind {x}), {call}), (.any, {})]", boolean(method == "is_none_or")), Ty::Bool)
                    }
                    "map" => (format!(".choose ({value}) [(.present (.bind {x}), .present ({call})), (.any, {absent})]"), Ty::Option(Box::new(applied.ty))),
                    "filter" => {
                        Self::require(&applied.ty, &Ty::Bool)?;
                        (format!(".choose ({value}) [(.present (.bind {x}), .branch ({call}) (.present (.read {x})) ({absent})), (.any, {absent})]"), ty.clone())
                    }
                    _ => {
                        let Ty::Option(_) = applied.ty else {
                            return Err("and_then callback must return Option".into());
                        };
                        (format!(".choose ({value}) [(.present (.bind {x}), {call}), (.any, {absent})]"), applied.ty)
                    }
                }
            }
            ("map_or", Ty::Option(inner), [default, f]) => {
                let closure = self.closure_syntax(frame, f)?;
                // The default fixes the result type unless it is untyped (an
                // integer literal inside it); then the callback's type does.
                let (d, dt) = match self.expr(frame, default, expected) {
                    Ok(typed) => typed,
                    Err(_) if expected.is_none() => {
                        let saved = self.next;
                        let probe = self.apply(&closure, std::slice::from_ref(inner), None)?;
                        self.next = saved;
                        self.expr(frame, default, Some(&probe.ty))?
                    }
                    Err(e) => return Err(e),
                };

                let applied = self.apply(&closure, std::slice::from_ref(inner), Some(&dt))?;
                Self::require(&applied.ty, &dt)?;
                let x = self.fresh();
                let call = Self::call_applied(&applied, &[format!(".read {x}")]);
                let ds = self.fresh();
                (
                    chain(vec![
                        store,
                        format!(".write {ds} ({d})"),
                        format!(
                            ".choose ({read}) [(.present (.bind {x}), {call}), (.any, .read {ds})]"
                        ),
                    ]),
                    dt,
                )
            }
            ("or_else", Ty::Option(_), [f]) => {
                let closure = self.closure_syntax(frame, f)?;
                let applied = self.apply(&closure, &[], Some(&ty))?;
                Self::require(&applied.ty, &ty)?;
                let call = Self::call_applied(&applied, &[]);
                (
                    seq(
                        store,
                        format!(".choose ({read}) [(.present .any, {read}), (.any, {call})]"),
                    ),
                    ty.clone(),
                )
            }
            ("ok_or", Ty::Option(inner), [e]) => {
                let (code, et) = self.expr(frame, e, None)?;
                let es = self.fresh();
                let x = self.fresh();
                (chain(vec![store, format!(".write {es} ({code})"), format!(".choose ({read}) [(.present (.bind {x}), .variant \"Result\" \"Ok\" [(\"0\", .read {x})]), (.any, .variant \"Result\" \"Err\" [(\"0\", .read {es})])]")]), Ty::Result(inner.clone(), Box::new(et)))
            }
            ("unwrap_or", Ty::Option(inner), [d]) => {
                let (code, dt) = self.expr(frame, d, Some(inner))?;
                Self::require(&dt, inner)?;
                let ds = self.fresh();
                let x = self.fresh();
                (chain(vec![store, format!(".write {ds} ({code})"), format!(".choose ({read}) [(.present (.bind {x}), .read {x}), (.any, .read {ds})]")]), dt)
            }
            ("unwrap_or", Ty::Result(inner, _), [d]) => {
                let (code, dt) = self.expr(frame, d, Some(inner))?;
                Self::require(&dt, inner)?;
                let ds = self.fresh();
                let x = self.fresh();
                (chain(vec![store, format!(".write {ds} ({code})"), format!(".choose ({read}) [(.variant \"Result\" \"Ok\" [(\"0\", .bind {x})], .read {x}), (.any, .read {ds})]")]), dt)
            }
            ("ok", Ty::Result(inner, _), []) => {
                let x = self.fresh();
                (format!(".choose ({value}) [(.variant \"Result\" \"Ok\" [(\"0\", .bind {x})], .present (.read {x})), (.any, {absent})]"), Ty::Option(inner.clone()))
            }
            ("unwrap" | "expect", Ty::Option(inner), _) => {
                let x = self.fresh();
                (
                    format!(
                        ".choose ({value}) [(.present (.bind {x}), .read {x}), (.any, .panic {})]",
                        q(method)
                    ),
                    (**inner).clone(),
                )
            }
            ("take", Ty::Option(_), []) => {
                let place = place.ok_or("take requires a place")?;
                if !place.mutable {
                    return Err("take through an immutable place".into());
                }
                let mut parts = vec![store];
                parts.extend(place.setup.iter().cloned());
                parts.push(Self::place_write(&place, absent));
                parts.push(read);
                (chain(parts), ty.clone())
            }
            ("then_some", Ty::Bool, [v]) => {
                let (code, vt) = self.expr(frame, v, None)?;
                let vs = self.fresh();
                (
                    chain(vec![
                        store,
                        format!(".write {vs} ({code})"),
                        format!(".branch ({read}) (.present (.read {vs})) ({absent})"),
                    ]),
                    Ty::Option(Box::new(vt)),
                )
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
                (format!(".binary {} ({value}) ({rhs})", q(method)), result)
            }
            ("clamp", Ty::Number(_), [lo, hi]) => {
                let (lo, lt) = self.expr(frame, lo, Some(&ty))?;
                Self::require(&lt, &ty)?;
                let (hi, ht) = self.expr(frame, hi, Some(&ty))?;
                Self::require(&ht, &ty)?;
                let l = self.fresh();
                let h = self.fresh();
                (
                    chain(vec![
                        store,
                        format!(".write {l} ({lo})"),
                        format!(".write {h} ({hi})"),
                        format!(".branch (.binary \">\" (.read {l}) (.read {h})) (.panic \"clamp\") (.branch (.binary \"<\" ({read}) (.read {l})) (.read {l}) (.branch (.binary \">\" ({read}) (.read {h})) (.read {h}) ({read})))"),
                    ]),
                    ty.clone(),
                )
            }
            ("map", Ty::Array(element), [f]) => {
                // `array.map(f)` applies `f` to each element in order.
                let closure = self.closure_syntax(frame, f)?;
                let applied = self.apply(&closure, std::slice::from_ref(element), None)?;
                let index = self.fresh();
                let result = self.fresh();
                let call =
                    Self::call_applied(&applied, &[format!(".index ({read}) (.read {index})")]);
                (
                    chain(vec![
                        store,
                        format!(".write {result} ({read})"),
                        format!(".range {index} ({}) (.length ({read})) (.assign {result} [.index {index}] ({call}))", usize_literal(0)),
                        format!(".read {result}"),
                    ]),
                    Ty::Array(Box::new(applied.ty)),
                )
            }
            ("len", Ty::Array(_), []) => (format!(".length ({value})"), Ty::Number("usize")),
            ("get", Ty::Array(element), [i]) => {
                let (index, it) = self.expr(frame, i, Some(&Ty::Number("usize")))?;
                Self::require(&it, &Ty::Number("usize"))?;
                let is = self.fresh();
                (chain(vec![store, format!(".write {is} ({index})"), format!(".branch (.binary \"<\" (.read {is}) (.length ({read}))) (.present (.index ({read}) (.read {is}))) ({absent})")]), Ty::Option(element.clone()))
            }
            ("contains", Ty::Array(element), [v]) => {
                self.derived(element, "PartialEq", 0)?;
                let (needle, nt) = self.expr(frame, strip(v), Some(element))?;
                Self::require(&nt, element)?;
                let ns = self.fresh();
                let p = Pipeline {
                    setup: vec![store, format!(".write {ns} ({needle})")],
                    source: Source::Elements {
                        array: stored,
                        lo: self.fresh(),
                        hi: self.fresh(),
                        places: None,
                    },
                    reverse: false,
                    stages: vec![],
                    item: (**element).clone(),
                };
                let (lo, hi) = match &p.source {
                    Source::Elements { lo, hi, .. } => (*lo, *hi),
                    _ => unreachable!(),
                };
                let mut p = p;
                p.setup.push(format!(".write {lo} ({})", usize_literal(0)));
                p.setup
                    .push(format!(".write {hi} (.length (.read {stored}))"));
                let result = self.fresh();
                let code = self.iterate(p, |_, item, exit, _, _| {
                    Ok(format!(
                        ".branch (.binary \"==\" (.read {item}) (.read {ns})) ({}) ({})",
                        seq(
                            format!(".write {result} ({})", boolean(true)),
                            format!(".exit {exit} ({})", unit())
                        ),
                        unit()
                    ))
                })?;
                (
                    chain(vec![
                        format!(".write {result} ({})", boolean(false)),
                        code,
                        format!(".read {result}"),
                    ]),
                    Ty::Bool,
                )
            }
            ("fill", Ty::Array(element), [v]) => {
                let place = place.ok_or("fill requires a place")?;
                if !place.mutable {
                    return Err("fill through an immutable place".into());
                }
                self.clone_value(".literal .unit".into(), element).ok();
                let (fill, ft) = self.expr(frame, v, Some(element))?;
                Self::require(&ft, element)?;
                self.copy(element)?;
                let vs = self.fresh();
                let index = self.fresh();
                let mut path = place.path.clone();
                path.push(format!(".index {index}"));
                let target = Place {
                    slot: place.slot,
                    path,
                    ty: (**element).clone(),
                    setup: vec![],
                    mutable: true,
                };
                let mut parts = vec![format!(".write {vs} ({fill})")];
                parts.extend(place.setup.iter().cloned());
                parts.push(format!(
                    ".range {index} ({}) (.length ({})) ({})",
                    usize_literal(0),
                    Self::place_read(&place),
                    Self::place_write(&target, format!(".read {vs}"))
                ));
                parts.push(unit());
                (chain(parts), Ty::Unit)
            }
            _ => return Err(format!("opaque method call {method} on {ty:?}")),
        };
        Ok(out)
    }
    fn call(
        &mut self,
        frame: &Frame<'a>,
        c: &syn::ExprCall,
        expected: Option<&Ty>,
    ) -> Result<(String, Ty), String> {
        attrs(&c.attrs)?;
        let args = c.args.iter().collect::<Vec<_>>();
        let Expr::Path(p) = &*c.func else {
            // A call through a function-pointer value.
            let (f, fty) = self.expr(frame, &c.func, None)?;
            let Ty::Function(output) = fty else {
                return Err(format!("call through a non-function value {fty:?}"));
            };
            let mut values = vec![f];
            for a in &args {
                values.push(self.expr(frame, a, None)?.0);
            }
            return Ok((
                format!(".external \"call\" [{}]", values.join(", ")),
                *output,
            ));
        };
        attrs(&p.attrs)?;
        if p.qself.is_some() {
            return Err("qualified call is unsupported".into());
        }
        if let Some(name) = single(&p.path) {
            match (name.as_str(), args.as_slice()) {
                ("Some", [arg]) => {
                    let inner = match expected {
                        Some(Ty::Option(t)) => Some(&**t),
                        _ => None,
                    };
                    let (value, ty) = self.expr(frame, arg, inner)?;
                    return Ok((format!(".present ({value})"), Ty::Option(Box::new(ty))));
                }
                ("Ok" | "Err", [arg]) => {
                    let (want, other) = match (name.as_str(), expected) {
                        ("Ok", Some(Ty::Result(a, e))) => (Some(&**a), Some((**e).clone())),
                        ("Err", Some(Ty::Result(a, e))) => (Some(&**e), Some((**a).clone())),
                        _ => (None, None),
                    };
                    let (value, ty) = self.expr(frame, arg, want)?;
                    let other =
                        other.ok_or("Result constructor type must be known from context")?;
                    let result = if name == "Ok" {
                        Ty::Result(Box::new(ty), Box::new(other))
                    } else {
                        Ty::Result(Box::new(other), Box::new(ty))
                    };
                    return Ok((
                        format!(".variant \"Result\" {} [(\"0\", {value})]", q(&name)),
                        result,
                    ));
                }
                _ => {}
            }
            if let Some(closure) = self.closures.get(&name).cloned() {
                let mut values = vec![];
                let mut inputs = vec![];
                for a in &args {
                    if self.closure_argument(a) {
                        inputs.push(Input::Closure(Box::new(self.closure_syntax(frame, a)?)));
                    } else {
                        let (v, t) = self.expr(frame, a, None)?;
                        values.push(v);
                        inputs.push(Input::Value(t));
                    }
                }
                let applied = self.apply_inputs(&closure, inputs, expected)?;
                return Ok((Self::call_applied(&applied, &values), applied.ty));
            }
        }
        // `Type::function(args)`, `Self::function(args)` or `Variant(args)`.
        if p.path.segments.len() == 2 {
            let first = p.path.segments[0].ident.to_string();
            let second = p.path.segments[1].ident.to_string();
            if let Some(kind) = number(&first) {
                if second == "try_from" {
                    let [arg] = args[..] else {
                        return Err("try_from takes one argument".into());
                    };
                    let (value, ty) = self.expr(frame, arg, None)?;
                    let Ty::Number(_) = ty else {
                        return Err("try_from requires an integer".into());
                    };
                    let x = self.fresh();
                    return Ok((format!(".choose (.convert {} true ({value})) [(.present (.bind {x}), .variant \"Result\" \"Ok\" [(\"0\", .read {x})]), (.any, .variant \"Result\" \"Err\" [(\"0\", .literal .unit)])]", q(kind)), Ty::Result(Box::new(Ty::Number(kind)), Box::new(Ty::Unit))));
                }
            }
            let owner_ty = if first == "Self" {
                frame_self(frame).ok_or("Self outside an impl")?
            } else {
                let resolved = self.krate.resolve(&frame.def.module, &first, 0)?;
                match expected {
                    Some(t @ Ty::Named { name, .. }) if *name == resolved => t.clone(),
                    _ => Ty::Named {
                        name: resolved,
                        types: vec![],
                        consts: vec![],
                    },
                }
            };
            let Ty::Named { name: owner, .. } = &owner_ty else {
                unreachable!()
            };
            if let Some(e) = self.krate.enums.get(owner) {
                if e.variants.iter().any(|v| v.ident == second) {
                    let members = self.members(&owner_ty, Some(&second))?;
                    if members.len() != args.len()
                        || members.iter().any(|(n, _)| n.parse::<usize>().is_err())
                    {
                        return Err("tuple variant arity mismatch".into());
                    }
                    let mut fields = vec![];
                    for ((field, ty), arg) in members.iter().zip(&args) {
                        let (value, actual) = self.expr(frame, arg, Some(ty))?;
                        Self::require(&actual, ty)?;
                        fields.push(format!("({}, {value})", q(field)));
                    }
                    return Ok((
                        format!(
                            ".variant {} {} [{}]",
                            q(owner),
                            q(&second),
                            fields.join(", ")
                        ),
                        owner_ty,
                    ));
                }
            }
            if second == "default"
                && args.is_empty()
                && self.method_definition(&owner_ty, "default").is_err()
            {
                return Ok((self.default_value(&owner_ty)?, owner_ty));
            }
            let (key, def) = self.method_definition(&owner_ty, &second)?;
            let generics = if first == "Self" {
                frame.generics.clone()
            } else {
                self.impl_instance(def, &owner_ty).unwrap_or_default()
            };
            return self.inline(frame, &key, def, None, &args, generics);
        }
        Err(format!("unsupported call {}", tokens(c)))
    }
    fn default_value(&self, ty: &Ty) -> Result<String, String> {
        Ok(match ty {
            Ty::Bool => boolean(false),
            Ty::Number(k) => format!(".literal (.number {} 0)", q(k)),
            Ty::Option(_) => ".literal .absent".into(),
            Ty::Named { name, .. } if self.krate.structs.contains_key(name) => {
                if !Self::derives(&self.krate.structs[name].attrs, "Default")? {
                    return Err(format!("{name} must derive Default"));
                }
                let mut fields = vec![];
                for (field, field_ty) in self.members(ty, None)? {
                    fields.push(format!(
                        "({}, {})",
                        q(&field),
                        self.default_value(&field_ty)?
                    ));
                }
                format!(".record {} [{}]", q(name), fields.join(", "))
            }
            _ => return Err(format!("Default is not modeled for {ty:?}")),
        })
    }

    /// Compile `def`'s complete body as a function of its own frame.
    fn function(&mut self, def: &'a Definition) -> Result<Function, String> {
        let sig = &def.item.sig;
        attrs(&def.item.attrs)?;
        if sig.asyncness.is_some()
            || sig.constness.is_some()
            || sig.unsafety.is_some()
            || sig.abi.is_some()
            || !sig.generics.params.is_empty()
            || sig.generics.where_clause.is_some()
        {
            return Err("compiled function must be plain and nongeneric".into());
        }
        let ordinary = sig
            .inputs
            .iter()
            .filter(|i| matches!(i, syn::FnArg::Typed(_)))
            .count();
        let mut generics = Generics::default();
        let mut constants = vec![];
        for (i, p) in def.impl_generics.const_params().enumerate() {
            generics
                .consts
                .insert(p.ident.to_string(), Konst::Slot(1 + ordinary + i));
            constants.push(p.ident.to_string());
        }
        for p in def.impl_generics.type_params() {
            generics
                .types
                .insert(p.ident.to_string(), Ty::Opaque(p.ident.to_string()));
        }
        let self_ty = match &def.self_type {
            Some(t) => self.ty_in(t, &def.impl_generics, &generics, &def.module, None)?,
            None => Ty::Named {
                name: def.receiver.clone(),
                types: vec![],
                consts: vec![],
            },
        };
        let (receiver, mutable_receiver) = match sig.inputs.first() {
            Some(syn::FnArg::Receiver(r)) => {
                attrs(&r.attrs)?;
                if r.reference.is_none() || r.colon_token.is_some() {
                    return Err("receiver must be &self or &mut self".into());
                }
                (true, r.mutability.is_some())
            }
            _ => (false, false),
        };
        let mut frame = Frame {
            def,
            generics,
            receiver: receiver.then(|| (0, self_ty.clone(), mutable_receiver)),
            output: None,
            loops: vec![],
        };
        if !receiver {
            frame.receiver = None;
        }
        let output = match &sig.output {
            syn::ReturnType::Default => Ty::Unit,
            syn::ReturnType::Type(_, t) => self.ty_in(
                t,
                &def.impl_generics,
                &frame.generics,
                &def.module,
                Some(&self_ty),
            )?,
        };
        frame.output = Some(output.clone());
        let saved = (
            std::mem::take(&mut self.env),
            std::mem::take(&mut self.closures),
            std::mem::take(&mut self.iterators),
            self.rebind.take(),
            self.next,
            self.labels,
        );
        self.next = 1 + ordinary + constants.len();
        // Labels are local to a body, so its text does not depend on which
        // root compiled it first.
        self.labels = 0;
        let result = (|| {
            let mut slot = 1;
            let mut setup = vec![];
            for input in sig.inputs.iter() {
                let syn::FnArg::Typed(t) = input else {
                    continue;
                };
                attrs(&t.attrs)?;
                if matches!(&*t.ty, Type::Reference(r) if r.mutability.is_some()) || callable(&t.ty)
                {
                    return Err("&mut and closure parameters need inlining".into());
                }
                let ty = self.ty_in(
                    &t.ty,
                    &def.impl_generics,
                    &frame.generics,
                    &def.module,
                    Some(&self_ty),
                )?;
                setup.extend(self.destructure(&frame, &t.pat, slot, &ty)?);
                slot += 1;
            }
            let (body, ty) = self.block(&frame, &def.item.block, Some(&output))?;
            if ty != output && !(ty == Ty::Unit && block_diverges(&def.item.block)) {
                return Err(format!("body type {ty:?} does not match {output:?}"));
            }
            setup.push(body);
            Ok::<_, String>(chain(setup))
        })();
        (
            self.env,
            self.closures,
            self.iterators,
            self.rebind,
            self.next,
            self.labels,
        ) = saved;
        Ok(Function {
            body: result?,
            parameters: ordinary,
            constants,
            receiver,
            mutable_receiver,
        })
    }
    /// Call `def` through the function table, compiling it on first use.
    fn invoke(
        &mut self,
        frame: &Frame<'a>,
        key: &str,
        def: &'a Definition,
        receiver: Option<(String, Ty, Option<Place>)>,
        args: &[&Expr],
        generics: Generics,
    ) -> Result<(String, Ty), String> {
        let sig = &def.item.sig;
        let self_ty = receiver
            .as_ref()
            .map(|r| r.1.clone())
            .or_else(|| frame_self_of(def, &generics, self));
        let output = match &sig.output {
            syn::ReturnType::Default => Ty::Unit,
            syn::ReturnType::Type(_, t) => self.ty_in(
                t,
                &def.impl_generics,
                &generics,
                &def.module,
                self_ty.as_ref(),
            )?,
        };
        let mut parts = vec![];
        let (receiver_code, write_back) = match (sig.inputs.first(), receiver) {
            (Some(syn::FnArg::Receiver(r)), Some((code, _, place))) => {
                if r.mutability.is_some() {
                    let place = place.ok_or("&mut self call on a temporary")?;
                    if !place.mutable {
                        return Err("&mut self call through an immutable place".into());
                    }
                    parts.extend(place.setup.iter().cloned());
                    let read = Self::place_read(&place);
                    (
                        read,
                        Some(format!(
                            "some ({}, [{}])",
                            place.slot,
                            place.path.join(", ")
                        )),
                    )
                } else {
                    (code, None)
                }
            }
            (Some(syn::FnArg::Receiver(_)), None) => return Err(format!("{key} needs a receiver")),
            (_, Some(_)) => return Err(format!("{key} is not a method")),
            _ => (unit(), None),
        };
        let inputs = sig
            .inputs
            .iter()
            .filter(|i| matches!(i, syn::FnArg::Typed(_)))
            .collect::<Vec<_>>();
        if inputs.len() != args.len() {
            return Err(format!("argument count mismatch calling {key}"));
        }
        let mut values = vec![];
        for (input, arg) in inputs.iter().zip(args) {
            let syn::FnArg::Typed(t) = input else {
                unreachable!()
            };
            let ty = self.ty_in(
                &t.ty,
                &def.impl_generics,
                &generics,
                &def.module,
                self_ty.as_ref(),
            )?;
            let (value, actual) = self.expr(frame, arg, Some(&ty))?;
            Self::require(&actual, &ty)?;
            values.push(value);
        }
        for p in def.impl_generics.const_params() {
            let k = generics
                .consts
                .get(&p.ident.to_string())
                .cloned()
                .unwrap_or(Konst::Unknown);
            values.push(Self::konst_code(&k).map_err(|e| format!("{e} (calling {key})"))?);
        }
        if !self.functions.contains_key(key) {
            self.enter(key)?;
            let compiled = self.function(def);
            self.stack.pop();
            let compiled = compiled.map_err(|e| format!("{e} (in {key})"))?;
            self.functions.insert(key.to_owned(), compiled.body);
        }
        parts.push(format!(
            ".invoke {} ({receiver_code}) {} [{}]",
            q(key),
            write_back.map_or("none".to_string(), |w| format!("({w})")),
            values.join(", ")
        ));
        Ok((chain(parts), output))
    }

    // ---- expressions ----------------------------------------------------

    fn binary_type(&self, op: &str, left: &Ty) -> Result<Ty, String> {
        match (op, left) {
            ("&&" | "||" | "^" | "&" | "|", Ty::Bool) => Ok(Ty::Bool),
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
        frame: &Frame<'a>,
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
        let (r, rt) = self.expr(frame, right, Some(&lt))?;
        Self::require(&rt, &lt)?;
        Ok((l, r, lt))
    }
    /// Lexicographic comparison of two tuples of integers (derived `PartialOrd`).
    fn tuple_compare(
        &mut self,
        op: &str,
        left: String,
        right: String,
        items: &[Ty],
    ) -> Result<String, String> {
        for item in items {
            if !matches!(item, Ty::Number(_)) {
                return Err("tuple ordering is modeled for integer components only".into());
            }
        }
        let l = self.fresh();
        let r = self.fresh();
        let field = |s: usize, i: usize| format!(".field (.read {s}) {}", q(&i.to_string()));
        // Equal on all components gives the reflexive result.
        let mut code = boolean(matches!(op, "<=" | ">="));
        let strict = if op.starts_with('<') { "<" } else { ">" };
        for i in (0..items.len()).rev() {
            code = format!(
                ".binary \"||\" (.binary {} ({}) ({})) (.binary \"&&\" (.binary \"==\" ({}) ({})) ({code}))",
                q(strict),
                field(l, i),
                field(r, i),
                field(l, i),
                field(r, i)
            );
        }
        Ok(chain(vec![
            format!(".write {l} ({left})"),
            format!(".write {r} ({right})"),
            code,
        ]))
    }
    fn expr(
        &mut self,
        frame: &Frame<'a>,
        e: &Expr,
        expected: Option<&Ty>,
    ) -> Result<(String, Ty), String> {
        let out = match e {
            Expr::Paren(p) => {
                attrs(&p.attrs)?;
                self.expr(frame, &p.expr, expected)?
            }
            Expr::Group(g) => {
                attrs(&g.attrs)?;
                self.expr(frame, &g.expr, expected)?
            }
            Expr::Reference(r) => {
                attrs(&r.attrs)?;
                if r.mutability.is_some() {
                    return Err("&mut expressions are unsupported outside iteration".into());
                }
                self.expr(frame, &r.expr, expected)?
            }
            Expr::Block(b) => {
                attrs(&b.attrs)?;
                if b.label.is_some() {
                    return Err("labeled blocks are unsupported".into());
                }
                self.block(frame, &b.block, expected)?
            }
            Expr::Lit(l) => {
                attrs(&l.attrs)?;
                match &l.lit {
                    syn::Lit::Bool(b) => (boolean(b.value), Ty::Bool),
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
            Expr::Tuple(t) => {
                attrs(&t.attrs)?;
                if t.elems.is_empty() {
                    (unit(), Ty::Unit)
                } else {
                    let wanted = match expected {
                        Some(Ty::Tuple(items)) if items.len() == t.elems.len() => {
                            items.iter().map(Some).collect()
                        }
                        _ => vec![None; t.elems.len()],
                    };
                    let mut fields = vec![];
                    let mut types = vec![];
                    for (i, (e, want)) in t.elems.iter().zip(wanted).enumerate() {
                        let (v, ty) = self.expr(frame, e, want)?;
                        fields.push(format!("({}, {v})", q(&i.to_string())));
                        types.push(ty);
                    }
                    (
                        format!(".record {} [{}]", tuple_name(), fields.join(", ")),
                        Ty::Tuple(types),
                    )
                }
            }
            Expr::Path(p) => {
                attrs(&p.attrs)?;
                if p.qself.is_some() {
                    return Err("qualified paths are unsupported".into());
                }
                if let Some(name) = single(&p.path) {
                    if name == "None" {
                        return Ok((
                            ".literal .absent".into(),
                            match expected {
                                Some(ty @ Ty::Option(_)) => ty.clone(),
                                _ => Ty::Option(Box::new(Ty::Infer)),
                            },
                        ));
                    }
                    if name == "self" {
                        let (slot, ty, _) =
                            frame.receiver.clone().ok_or("self outside a method")?;
                        (format!(".read {slot}"), ty)
                    } else if let Some(b) = self.env.get(&name) {
                        if let Some((slot, path)) = &b.alias {
                            let place = Place {
                                slot: *slot,
                                path: path.clone(),
                                ty: b.ty.clone(),
                                setup: vec![],
                                mutable: true,
                            };
                            (Self::place_read(&place), b.ty.clone())
                        } else {
                            (format!(".read {}", b.slot), b.ty.clone())
                        }
                    } else if let Some(k) = frame.generics.consts.get(&name) {
                        (Self::konst_code(k)?, Ty::Number("usize"))
                    } else {
                        return Err(format!("unknown local {name}"));
                    }
                } else if p.path.segments.len() == 2
                    && number(&p.path.segments[0].ident.to_string()).is_some()
                    && p.path.segments[1].ident == "MAX"
                {
                    let kind = number(&p.path.segments[0].ident.to_string()).unwrap();
                    let value = match kind {
                        "u8" => u8::MAX as u64,
                        "u16" => u16::MAX as u64,
                        "u32" => u32::MAX as u64,
                        "u64" => u64::MAX,
                        _ => {
                            let w = self
                                .krate
                                .cfg
                                .as_ref()
                                .and_then(|c| c.pointer_width())
                                .ok_or("usize::MAX requires the pointer width")?;
                            if w == 64 {
                                u64::MAX
                            } else {
                                (1u64 << w) - 1
                            }
                        }
                    };
                    (
                        format!(".literal (.number {} {value})", q(kind)),
                        Ty::Number(kind),
                    )
                } else {
                    let want = expected.cloned().unwrap_or(Ty::Unit);
                    let (owner, tag) = self.variant_path(frame, &p.path, &want)?;
                    if !self.members(&owner, Some(&tag))?.is_empty() {
                        return Err("variant with fields used as a value".into());
                    }
                    (
                        format!(".literal (.variant {} {} [])", q(&name_of(&owner)), q(&tag)),
                        owner,
                    )
                }
            }
            Expr::Repeat(r) => {
                attrs(&r.attrs)?;
                let element = match expected {
                    Some(Ty::Array(e)) => Some((**e).clone()),
                    _ => None,
                };
                let (value, ty) = self.expr(frame, &r.expr, element.as_ref())?;
                self.copy(&ty)?;
                let count = match self.konst(&r.len, &frame.generics) {
                    Konst::Unknown => return Err("array length is not available".into()),
                    k => Self::konst_code(&k)?,
                };
                (
                    format!(".replicate ({value}) ({count})"),
                    Ty::Array(Box::new(ty)),
                )
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
                match u.op {
                    syn::UnOp::Not(_) => {
                        let (value, ty) = self.expr(frame, &u.expr, Some(&Ty::Bool))?;
                        Self::require(&ty, &Ty::Bool)?;
                        (format!(".negate ({value})"), Ty::Bool)
                    }
                    // Values are copies; a dereference reads the same value.
                    syn::UnOp::Deref(_) => self.expr(frame, &u.expr, expected)?,
                    _ => return Err("unsupported unary operator".into()),
                }
            }
            Expr::Cast(c) => {
                attrs(&c.attrs)?;
                let target = self.ty(frame, &c.ty)?;
                let Ty::Number(kind) = target else {
                    return Err("casts are modeled to integers only".into());
                };
                let (value, ty) = self.expr(frame, &c.expr, None)?;
                let Ty::Number(_) = ty else {
                    return Err("casts are modeled from integers only".into());
                };
                (
                    format!(".convert {} false ({value})", q(kind)),
                    Ty::Number(kind),
                )
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
                    let result = self.binary_type(base, &ty)?;
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
                    if let (Ty::Tuple(items), "<" | "<=" | ">" | ">=") = (&ty, op.as_str()) {
                        let items = items.clone();
                        (self.tuple_compare(&op, left, right, &items)?, Ty::Bool)
                    } else {
                        let result = self.binary_type(&op, &ty)?;
                        (format!(".binary {} ({left}) ({right})", q(&op)), result)
                    }
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
                // A local typed with an unconstrained `None` takes the type
                // of its first assignment.
                if let Expr::Path(p) = &*a.left {
                    if let Some(name) = single(&p.path) {
                        if let Some(b) = self.env.get_mut(&name) {
                            if contains_infer(&b.ty) && b.ty == actual {
                                b.ty = actual.clone();
                            }
                        }
                    }
                }
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
                    self.arms(frame, value, &ty, &arms, expected)?
                } else {
                    let (condition, ct) = self.expr(frame, &i.cond, Some(&Ty::Bool))?;
                    Self::require(&ct, &Ty::Bool)?;
                    let (yes, yt) = self.block(frame, &i.then_branch, expected)?;
                    let (no, nt) = match otherwise {
                        Some(e) => {
                            self.expr(frame, e, Some(&yt).filter(|t| **t != Ty::Unit).or(expected))?
                        }
                        None => (unit(), Ty::Unit),
                    };
                    let ty = if block_diverges(&i.then_branch) {
                        nt.clone()
                    } else {
                        yt.clone()
                    };
                    if !block_diverges(&i.then_branch) && !otherwise.is_some_and(diverges) {
                        Self::require(&nt, &yt)?;
                    }
                    (format!(".branch ({condition}) ({yes}) ({no})"), ty)
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
                self.arms(frame, value, &ty, &arms, expected)?
            }
            Expr::Return(r) => {
                attrs(&r.attrs)?;
                let output = frame
                    .output
                    .clone()
                    .ok_or("return needs a known result type")?;
                let (value, ty) = match &r.expr {
                    Some(v) => self.expr(frame, v, Some(&output))?,
                    None => (unit(), Ty::Unit),
                };
                Self::require(&ty, &output)?;
                (format!(".ret ({value})"), Ty::Unit)
            }
            Expr::Try(t) => {
                attrs(&t.attrs)?;
                let (value, ty) = self.expr(frame, &t.expr, None)?;
                let output = frame.output.clone().ok_or("? needs a known result type")?;
                let x = self.fresh();
                match (&ty, &output) {
                    (Ty::Option(inner), Ty::Option(_)) => (format!(".choose ({value}) [(.present (.bind {x}), .read {x}), (.any, .ret (.literal .absent))]"), (**inner).clone()),
                    (Ty::Result(inner, error), Ty::Result(_, out_error)) => {
                        // `From` conversion is identity only for the same error type.
                        Self::require(error, out_error)?;
                        let err = self.fresh();
                        (format!(".choose ({value}) [(.variant \"Result\" \"Ok\" [(\"0\", .bind {x})], .read {x}), (.variant \"Result\" \"Err\" [(\"0\", .bind {err})], .ret (.variant \"Result\" \"Err\" [(\"0\", .read {err})]))]"), (**inner).clone())
                    }
                    _ => return Err(format!("? on {ty:?} in a function returning {output:?}")),
                }
            }
            Expr::Call(c) => self.call(frame, c, expected)?,
            Expr::MethodCall(c) => self.method_call(frame, c, expected)?,
            Expr::Macro(m) => {
                attrs(&m.attrs)?;
                self.statement_macro(frame, &m.mac)?
            }
            Expr::Struct(s) => {
                attrs(&s.attrs)?;
                if s.qself.is_some() || s.rest.is_some() || s.dot2_token.is_some() {
                    return Err("struct update syntax is unsupported".into());
                }
                let (owner, tag) = if s.path.segments.len() == 2 {
                    let want = expected.cloned().unwrap_or(Ty::Unit);
                    let (o, t) = self.variant_path(frame, &s.path, &want)?;
                    (o, Some(t))
                } else {
                    let name = single(&s.path).ok_or("unresolved struct path")?;
                    let owner = if name == "Self" {
                        frame_self(frame).ok_or("Self outside an impl")?
                    } else {
                        let resolved = self.krate.resolve(&frame.def.module, &name, 0)?;
                        match expected {
                            Some(t @ Ty::Named { name, .. }) if *name == resolved => t.clone(),
                            _ => Ty::Named {
                                name: resolved,
                                types: vec![],
                                consts: vec![],
                            },
                        }
                    };
                    (owner, None)
                };
                self.droppable(&owner)?;
                let members = self.members(&owner, tag.as_deref())?;
                if members.len() != s.fields.len() {
                    return Err("struct literal must initialize every field".into());
                }
                // Fields are evaluated in source order and stored in
                // declaration order, as the value is laid out.
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
                parts.push(match &tag {
                    Some(tag) => format!(
                        ".variant {} {} [{}]",
                        q(&name_of(&owner)),
                        q(tag),
                        fields.join(", ")
                    ),
                    None => format!(".record {} [{}]", q(&name_of(&owner)), fields.join(", ")),
                });
                (chain(parts), owner)
            }
            Expr::ForLoop(f) => {
                attrs(&f.attrs)?;
                let label = f.label.as_ref().map(|l| l.name.ident.to_string());
                let p = self.pipeline(frame, &f.expr)?;
                let item_ty = p.item.clone();
                let pat = (*f.pat).clone();
                let body_block = f.body.clone();
                let code = self.iterate(p, |this, item, exit, next, alias| {
                    let saved = this.env.clone();
                    let mut parts = vec![];
                    if let (Some((slot, path)), syn::Pat::Ident(_)) = (alias, &pat) {
                        let (name, _) = ident(&pat)?;
                        this.env.insert(
                            name,
                            Binding {
                                slot: item,
                                ty: item_ty.clone(),
                                mutable: false,
                                alias: Some((slot, path)),
                            },
                        );
                    } else {
                        parts.extend(this.destructure(frame, &pat, item, &item_ty)?);
                    }
                    let mut inner = frame.clone();
                    inner.loops.push(Loop {
                        label: label.clone(),
                        exit,
                        next,
                        result: None,
                    });
                    let (body, ty) = this.block(&inner, &body_block, Some(&Ty::Unit))?;
                    Self::require(&ty, &Ty::Unit)?;
                    parts.push(body);
                    this.env = saved;
                    Ok(chain(parts))
                })?;
                (code, Ty::Unit)
            }
            Expr::While(w) => {
                attrs(&w.attrs)?;
                if matches!(&*w.cond, Expr::Let(_)) {
                    return Err("while let is unsupported".into());
                }
                let exit = self.label();
                let next = self.label();
                let (condition, ct) = self.expr(frame, &w.cond, Some(&Ty::Bool))?;
                Self::require(&ct, &Ty::Bool)?;
                let mut inner = frame.clone();
                inner.loops.push(Loop {
                    label: w.label.as_ref().map(|l| l.name.ident.to_string()),
                    exit,
                    next,
                    result: None,
                });
                let (body, ty) = self.block(&inner, &w.body, Some(&Ty::Unit))?;
                Self::require(&ty, &Ty::Unit)?;
                (format!(".block {exit} (.loop (.sequence (.branch ({condition}) ({}) (.exit {exit} ({}))) (.block {next} ({body}))))", unit(), unit()), Ty::Unit)
            }
            Expr::Loop(l) => {
                attrs(&l.attrs)?;
                let exit = self.label();
                let next = self.label();
                let result = self.fresh();
                let mut inner = frame.clone();
                inner.loops.push(Loop {
                    label: l.label.as_ref().map(|l| l.name.ident.to_string()),
                    exit,
                    next,
                    result: Some((result, expected.cloned().unwrap_or(Ty::Unit))),
                });
                let (body, _) = self.block(&inner, &l.body, Some(&Ty::Unit))?;
                (
                    format!(".block {exit} (.loop (.block {next} ({body})))"),
                    expected.cloned().unwrap_or(Ty::Unit),
                )
            }
            Expr::Break(b) => {
                attrs(&b.attrs)?;
                let target = self.loop_target(frame, b.label.as_ref())?;
                let value = match &b.expr {
                    Some(v) => {
                        let want = target.result.as_ref().map(|r| r.1.clone());
                        self.expr(frame, v, want.as_ref())?.0
                    }
                    None => unit(),
                };
                (format!(".exit {} ({value})", target.exit), Ty::Unit)
            }
            Expr::Continue(c) => {
                attrs(&c.attrs)?;
                let target = self.loop_target(frame, c.label.as_ref())?;
                (format!(".exit {} ({})", target.next, unit()), Ty::Unit)
            }
            _ => return Err(format!("unsupported expression {}", tokens(e))),
        };
        Ok(out)
    }
    fn loop_target(
        &self,
        frame: &Frame<'a>,
        label: Option<&syn::Lifetime>,
    ) -> Result<Loop, String> {
        match label {
            None => frame
                .loops
                .last()
                .cloned()
                .ok_or_else(|| "break outside a loop".into()),
            Some(l) => frame
                .loops
                .iter()
                .rev()
                .find(|x| x.label.as_deref() == Some(&l.ident.to_string()))
                .cloned()
                .ok_or_else(|| "unknown loop label".into()),
        }
    }
}

fn contains_infer(ty: &Ty) -> bool {
    match ty {
        Ty::Infer => true,
        Ty::Option(t) | Ty::Array(t) | Ty::Function(t) => contains_infer(t),
        Ty::Result(a, b) => contains_infer(a) || contains_infer(b),
        Ty::Tuple(items) => items.iter().any(contains_infer),
        Ty::Named { types, .. } => types.iter().any(contains_infer),
        _ => false,
    }
}
/// A parameter type that takes a closure: `impl Fn*`, `&dyn Fn*` or `&mut dyn Fn*`.
fn callable(t: &Type) -> bool {
    let bounds = match t {
        Type::ImplTrait(i) => &i.bounds,
        Type::Reference(r) => match &*r.elem {
            Type::TraitObject(o) => &o.bounds,
            _ => return false,
        },
        _ => return false,
    };
    bounds.iter().any(|b| {
        matches!(b, syn::TypeParamBound::Trait(t) if t.path.segments.last().is_some_and(|s| matches!(s.ident.to_string().as_str(), "Fn" | "FnMut" | "FnOnce")))
    })
}
fn name_of(ty: &Ty) -> String {
    match ty {
        Ty::Named { name, .. } => name.clone(),
        _ => String::new(),
    }
}
fn frame_self(frame: &Frame) -> Option<Ty> {
    frame.receiver.as_ref().map(|r| r.1.clone()).or_else(|| {
        Some(Ty::Named {
            name: frame.def.receiver.clone(),
            types: vec![],
            consts: vec![],
        })
    })
}
fn frame_self_of(def: &Definition, _generics: &Generics, _c: &Compiler) -> Option<Ty> {
    Some(Ty::Named {
        name: def.receiver.clone(),
        types: vec![],
        consts: vec![],
    })
}
/// Whether evaluating `e` never completes normally (so its type does not
/// constrain the enclosing expression).
fn diverges(e: &Expr) -> bool {
    match e {
        Expr::Return(_) | Expr::Break(_) | Expr::Continue(_) => true,
        Expr::Macro(m) => m.mac.path.is_ident("unreachable") || m.mac.path.is_ident("panic"),
        Expr::Block(b) => block_diverges(&b.block),
        Expr::Paren(p) => diverges(&p.expr),
        _ => false,
    }
}
fn block_diverges(b: &syn::Block) -> bool {
    b.stmts.iter().any(|s| match s {
        syn::Stmt::Expr(e, _) => diverges(e),
        syn::Stmt::Macro(m) => m.mac.path.is_ident("unreachable") || m.mac.path.is_ident("panic"),
        _ => false,
    })
}

impl Crate {
    pub fn lower_imperative(&self, name: &str) -> Result<Method, String> {
        let def = self.methods.get(name).ok_or("unknown imperative method")?;
        let f = &def.item;
        attrs(&f.attrs)?;
        let sig = &f.sig;
        if sig.asyncness.is_some()
            || sig.constness.is_some()
            || sig.unsafety.is_some()
            || sig.abi.is_some()
            || !sig.generics.params.is_empty()
            || sig.generics.where_clause.is_some()
        {
            return Err("imperative method requires a plain nongeneric function".into());
        }
        if !self.structs.contains_key(&def.receiver) && !self.enums.contains_key(&def.receiver) {
            return Err("imperative receiver must be a source type".into());
        }
        for primitive in NUMBERS
            .iter()
            .chain(&["bool", "Option", "Some", "None", "Result", "Ok", "Err"])
        {
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
        let mut compiler = Compiler {
            krate: self,
            env: BTreeMap::new(),
            closures: BTreeMap::new(),
            iterators: BTreeMap::new(),
            rebind: None,
            next: 1,
            labels: 0,
            inlined: vec![],
            stack: vec![name.to_owned()],
            functions: BTreeMap::new(),
        };
        let function = compiler.function(def)?;
        let expression = function.body;
        let (ordinary, constants, receiver, mutable_receiver) = (
            function.parameters,
            function.constants,
            function.receiver,
            function.mutable_receiver,
        );
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
            parameters: ordinary,
            constants,
            receiver,
            mutable_receiver,
            inlined: compiler.inlined,
            functions: compiler.functions.into_iter().collect(),
            scope: "complete body over value-semantics slots with inlined crate calls, closures and iterator chains; payload destructors assumed to return normally; frontend typing, layout, aliasing and unwinding state remain unproved",
        });
        Ok(method)
    }
}

/// The project's function table: every function an imperative method calls,
/// once, by qualified name. Two roots compiling the same function to different
/// text would be a frontend defect; the table then fails to elaborate.
pub(super) fn table(methods: &[Method]) -> String {
    let mut functions: BTreeMap<&str, &str> = BTreeMap::new();
    let mut text = String::new();
    for m in methods.iter().filter_map(|m| m.imperative.as_ref()) {
        for (name, body) in &m.functions {
            match functions.get(name.as_str()) {
                Some(existing) if existing != body => {
                    text.push_str(&format!(
                        "theorem imperative_conflict_{} : False := by decide\n",
                        symbol(name)
                    ));
                }
                Some(_) => {}
                None => {
                    functions.insert(name, body);
                }
            }
        }
    }
    if methods.iter().all(|m| m.imperative.is_none()) {
        return text;
    }
    for (name, body) in &functions {
        text.push_str(&format!(
            "def {} : Provium.Imperative.Expr := {body}\n",
            symbol(name)
        ));
    }
    text.push_str("def imperative_functions : String → Option Provium.Imperative.Expr\n");
    for name in functions.keys() {
        text.push_str(&format!("  | {} => some {}\n", q(name), symbol(name)));
    }
    text.push_str("  | _ => none\n");
    text
}
fn symbol(name: &str) -> String {
    format!("function_{}", name.replace("::", "_"))
}

pub(super) fn generate(method: &Method) -> String {
    let m = method.imperative.as_ref().unwrap();
    let name = &method.symbol;
    format!("def {name}_ir : Provium.Imperative.Expr := {}\ndef {name} (target : Provium.Imperative.Target) (fuel : Nat) (receiver : PureValue) (arguments : List PureValue) : Except Provium.Imperative.Fault (PureValue × PureValue) :=\n  Provium.Imperative.run {{ toTarget := target, functions := imperative_functions }} fuel {name}_ir receiver arguments\ntheorem {name}_correspondence (target : Provium.Imperative.Target) (fuel : Nat) (receiver : PureValue) (arguments : List PureValue) :\n  Provium.Imperative.run {{ toTarget := target, functions := imperative_functions }} fuel {name}_ir receiver arguments = {name} target fuel receiver arguments := by rfl\n", m.expression)
}
