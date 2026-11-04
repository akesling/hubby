//! Rust types of the supported subset and their Lean renderings.
use super::load::{tokens, Krate};
use syn::Type;

/// A compile-time length: a literal, a const generic, or a crate constant.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Len {
    Lit(u64),
    Param(String),
    Const(String),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Ty {
    Bool,
    /// Unsigned integers: bit width and Rust name (`usize` is 64 bits).
    Uint(u32, &'static str),
    /// Signed integers: bit width and Rust name.
    Int(u32, &'static str),
    /// An integer literal whose type is not yet known.
    IntLit,
    /// A local bound to an integer literal, typed by its later uses.
    IntVar(usize),
    Unit,
    Never,
    Str,
    Tuple(Vec<Ty>),
    Array(Box<Ty>, Len),
    Slice(Box<Ty>),
    Ref(bool, Box<Ty>),
    /// A crate struct or enum with type and const arguments.
    Adt(String, Vec<Ty>, Vec<Len>),
    Option(Box<Ty>),
    Result(Box<Ty>, Box<Ty>),
    Param(String),
    /// Any iterator, represented by the list of items it yields.
    Iter(Box<Ty>),
    /// Closures, function pointers and `impl Fn*` arguments.
    Fn(Vec<Ty>, Box<Ty>),
    TryFromIntError,
}

impl Ty {
    pub fn usize() -> Ty {
        Ty::Uint(64, "usize")
    }
    pub fn u64() -> Ty {
        Ty::Uint(64, "u64")
    }
    /// The type with outer references removed.
    pub fn peel(&self) -> &Ty {
        match self {
            Ty::Ref(_, t) => t.peel(),
            t => t,
        }
    }
    pub fn is_unit(&self) -> bool {
        matches!(self, Ty::Unit)
    }
    pub fn mut_ref(&self) -> bool {
        matches!(self, Ty::Ref(true, _))
    }
    /// Whether values of this type may contain a mutable borrow.
    pub fn holds_mut_borrow(&self, k: &Krate) -> bool {
        match self {
            Ty::Ref(true, _) => true,
            Ty::Adt(p, ..) => k.structs.get(p).is_some_and(|s| {
                s.fields
                    .iter()
                    .any(|(_, t)| matches!(t, Type::Reference(r) if r.mutability.is_some()))
            }),
            _ => false,
        }
    }
    /// Substitute generic parameters.
    pub fn subst(&self, tys: &[(String, Ty)], lens: &[(String, Len)]) -> Ty {
        let sub_len = |l: &Len| match l {
            Len::Param(p) => lens
                .iter()
                .find(|(n, _)| n == p)
                .map_or(l.clone(), |(_, v)| v.clone()),
            l => l.clone(),
        };
        let s = |t: &Ty| t.subst(tys, lens);
        match self {
            Ty::Param(p) => tys
                .iter()
                .find(|(n, _)| n == p)
                .map_or(self.clone(), |(_, v)| v.clone()),
            Ty::Tuple(v) => Ty::Tuple(v.iter().map(s).collect()),
            Ty::Array(t, l) => Ty::Array(Box::new(s(t)), sub_len(l)),
            Ty::Slice(t) => Ty::Slice(Box::new(s(t))),
            Ty::Ref(m, t) => Ty::Ref(*m, Box::new(s(t))),
            Ty::Adt(p, a, l) => Ty::Adt(
                p.clone(),
                a.iter().map(s).collect(),
                l.iter().map(sub_len).collect(),
            ),
            Ty::Option(t) => Ty::Option(Box::new(s(t))),
            Ty::Result(a, b) => Ty::Result(Box::new(s(a)), Box::new(s(b))),
            Ty::Iter(t) => Ty::Iter(Box::new(s(t))),
            Ty::Fn(a, r) => Ty::Fn(a.iter().map(s).collect(), Box::new(s(r))),
            t => t.clone(),
        }
    }
}

/// Generic parameters in scope while converting types.
#[derive(Clone, Default, Debug)]
pub struct Generics {
    pub types: Vec<String>,
    pub consts: Vec<String>,
}

impl Generics {
    pub fn extend(&mut self, g: &syn::Generics) -> Result<(), String> {
        for p in &g.params {
            match p {
                syn::GenericParam::Type(t) => self.types.push(t.ident.to_string()),
                syn::GenericParam::Const(c) => {
                    if tokens(&c.ty) != "usize" {
                        return Err(format!("const generic {} must be usize", c.ident));
                    }
                    self.consts.push(c.ident.to_string())
                }
                syn::GenericParam::Lifetime(_) => {}
            }
        }
        Ok(())
    }
}

pub struct Scope<'a> {
    pub krate: &'a Krate,
    pub module: &'a str,
    pub generics: &'a Generics,
    pub self_ty: Option<&'a Ty>,
}

impl Scope<'_> {
    pub fn len(&self, e: &syn::Expr) -> Result<Len, String> {
        match e {
            syn::Expr::Lit(syn::ExprLit {
                lit: syn::Lit::Int(i),
                ..
            }) => Ok(Len::Lit(i.base10_parse().map_err(|e| e.to_string())?)),
            syn::Expr::Path(p) if p.path.segments.len() == 1 => {
                let name = p.path.segments[0].ident.to_string();
                if self.generics.consts.contains(&name) {
                    return Ok(Len::Param(name));
                }
                let path = self
                    .krate
                    .resolve(self.module, std::slice::from_ref(&name))
                    .filter(|p| self.krate.consts.contains_key(p))
                    .ok_or_else(|| format!("unknown array length {name}"))?;
                Ok(Len::Const(path))
            }
            syn::Expr::Block(b) if b.block.stmts.len() == 1 => match &b.block.stmts[0] {
                syn::Stmt::Expr(e, None) => self.len(e),
                _ => Err(format!("unsupported array length {}", tokens(e))),
            },
            _ => Err(format!("unsupported array length {}", tokens(e))),
        }
    }

    pub fn ty(&self, t: &Type) -> Result<Ty, String> {
        match t {
            Type::Paren(p) => self.ty(&p.elem),
            Type::Tuple(t) if t.elems.is_empty() => Ok(Ty::Unit),
            Type::Tuple(t) => Ok(Ty::Tuple(
                t.elems
                    .iter()
                    .map(|e| self.ty(e))
                    .collect::<Result<_, _>>()?,
            )),
            Type::Never(_) => Ok(Ty::Never),
            Type::Reference(r) => Ok(Ty::Ref(r.mutability.is_some(), Box::new(self.ty(&r.elem)?))),
            Type::Array(a) => Ok(Ty::Array(Box::new(self.ty(&a.elem)?), self.len(&a.len)?)),
            Type::Slice(s) => Ok(Ty::Slice(Box::new(self.ty(&s.elem)?))),
            Type::BareFn(f) => {
                let args = f
                    .inputs
                    .iter()
                    .map(|a| self.ty(&a.ty))
                    .collect::<Result<_, _>>()?;
                let ret = match &f.output {
                    syn::ReturnType::Default => Ty::Unit,
                    syn::ReturnType::Type(_, t) => self.ty(t)?,
                };
                Ok(Ty::Fn(args, Box::new(ret)))
            }
            Type::ImplTrait(i) => self.bounds(&i.bounds, t),
            Type::TraitObject(o) => self.bounds(&o.bounds, t),
            Type::Path(p) if p.qself.is_none() => self.path(&p.path),
            _ => Err(format!("unsupported type {}", tokens(t))),
        }
    }

    fn bounds(
        &self,
        bounds: &syn::punctuated::Punctuated<syn::TypeParamBound, syn::Token![+]>,
        t: &Type,
    ) -> Result<Ty, String> {
        for b in bounds {
            let syn::TypeParamBound::Trait(tb) = b else {
                continue;
            };
            let last = tb.path.segments.last().unwrap();
            let name = last.ident.to_string();
            match (name.as_str(), &last.arguments) {
                (
                    "Iterator" | "DoubleEndedIterator" | "IntoIterator",
                    syn::PathArguments::AngleBracketed(a),
                ) => {
                    for arg in &a.args {
                        if let syn::GenericArgument::AssocType(at) = arg {
                            if at.ident == "Item" {
                                return Ok(Ty::Iter(Box::new(self.ty(&at.ty)?)));
                            }
                        }
                    }
                }
                ("Fn" | "FnMut" | "FnOnce", syn::PathArguments::Parenthesized(p)) => {
                    let args = p
                        .inputs
                        .iter()
                        .map(|a| self.ty(a))
                        .collect::<Result<_, _>>()?;
                    let ret = match &p.output {
                        syn::ReturnType::Default => Ty::Unit,
                        syn::ReturnType::Type(_, t) => self.ty(t)?,
                    };
                    return Ok(Ty::Fn(args, Box::new(ret)));
                }
                _ => {}
            }
        }
        Err(format!("unsupported trait type {}", tokens(t)))
    }

    fn args(&self, seg: &syn::PathSegment) -> Result<(Vec<Ty>, Vec<Len>), String> {
        let mut tys = vec![];
        let mut lens = vec![];
        if let syn::PathArguments::AngleBracketed(a) = &seg.arguments {
            for arg in &a.args {
                match arg {
                    syn::GenericArgument::Type(Type::Path(p))
                        if p.path.segments.len() == 1
                            && self
                                .generics
                                .consts
                                .contains(&p.path.segments[0].ident.to_string()) =>
                    {
                        lens.push(Len::Param(p.path.segments[0].ident.to_string()))
                    }
                    syn::GenericArgument::Type(Type::Path(p))
                        if p.path.segments.len() == 1
                            && self
                                .krate
                                .resolve(self.module, &[p.path.segments[0].ident.to_string()])
                                .is_some_and(|c| self.krate.consts.contains_key(&c)) =>
                    {
                        lens.push(Len::Const(
                            self.krate
                                .resolve(self.module, &[p.path.segments[0].ident.to_string()])
                                .unwrap(),
                        ))
                    }
                    syn::GenericArgument::Type(t) => tys.push(self.ty(t)?),
                    syn::GenericArgument::Const(e) => lens.push(self.len(e)?),
                    syn::GenericArgument::Lifetime(_) => {}
                    other => return Err(format!("unsupported generic argument {}", tokens(other))),
                }
            }
        }
        Ok((tys, lens))
    }

    fn path(&self, p: &syn::Path) -> Result<Ty, String> {
        let names: Vec<String> = p.segments.iter().map(|s| s.ident.to_string()).collect();
        let last = p.segments.last().unwrap();
        if names.len() == 1 {
            let n = names[0].as_str();
            if self.generics.types.iter().any(|g| g == n) {
                return Ok(Ty::Param(n.to_owned()));
            }
            match n {
                "bool" => return Ok(Ty::Bool),
                "u8" => return Ok(Ty::Uint(8, "u8")),
                "u16" => return Ok(Ty::Uint(16, "u16")),
                "u32" => return Ok(Ty::Uint(32, "u32")),
                "u64" => return Ok(Ty::Uint(64, "u64")),
                "usize" => return Ok(Ty::usize()),
                "i8" => return Ok(Ty::Int(8, "i8")),
                "i16" => return Ok(Ty::Int(16, "i16")),
                "i32" => return Ok(Ty::Int(32, "i32")),
                "i64" => return Ok(Ty::Int(64, "i64")),
                "isize" => return Ok(Ty::Int(64, "isize")),
                "str" => return Ok(Ty::Str),
                "Self" => {
                    return self
                        .self_ty
                        .cloned()
                        .ok_or_else(|| "Self outside an impl".to_owned());
                }
                _ => {}
            }
        }
        let (tys, lens) = self.args(last)?;
        let resolved = if names.len() == 1 && matches!(names[0].as_str(), "Option" | "Result") {
            format!("::core::{}", names[0])
        } else {
            self.krate
                .resolve(self.module, &names)
                .ok_or_else(|| format!("unresolved type {}", tokens(p)))?
        };
        match resolved.as_str() {
            "::core::Option" | "::core::option::Option" if tys.len() == 1 => {
                Ok(Ty::Option(Box::new(tys[0].clone())))
            }
            "::core::Result" | "::core::result::Result" if tys.len() == 2 => Ok(Ty::Result(
                Box::new(tys[0].clone()),
                Box::new(tys[1].clone()),
            )),
            "::core::num::TryFromIntError" => Ok(Ty::TryFromIntError),
            p if self.krate.structs.contains_key(p) || self.krate.enums.contains_key(p) => {
                Ok(Ty::Adt(p.to_owned(), tys, lens))
            }
            _ => Err(format!("unsupported type {}", tokens(p))),
        }
    }
}
