//! Calls: crate functions, constructors, closures, macros and the core library
//! operations the typed backend interprets.
use super::emit::{function_generics, Body, Place, R, V};
use super::lean::ident;
use super::load::{tokens, Function};
use super::types::{Generics, Len, Scope as TyScope, Ty};
use syn::Expr;

fn strip(e: &Expr) -> &Expr {
    match e {
        Expr::Paren(p) => strip(&p.expr),
        Expr::Group(g) => strip(&g.expr),
        e => e,
    }
}

fn p(s: &str) -> String {
    let simple = s
        .chars()
        .all(|c| c.is_alphanumeric() || c == '_' || c == '.' || c == '«' || c == '»' || c == '\'');
    if simple || (s.starts_with('(') && s.ends_with(')') && balanced(s)) {
        s.to_owned()
    } else {
        format!("({s})")
    }
}

fn balanced(s: &str) -> bool {
    let mut d = 0;
    for (i, c) in s.char_indices() {
        if c == '(' {
            d += 1
        } else if c == ')' {
            d -= 1;
            if d == 0 && i + 1 != s.len() {
                return false;
            }
        }
    }
    d == 0
}

/// A closure argument after translation.
pub struct FnArg {
    pub term: String,
    pub pure: bool,
    pub arity: usize,
    pub ret: Ty,
}

impl FnArg {
    /// The closure as a monadic function `A → Rust.M B`.
    pub fn monadic(&self) -> String {
        if !self.pure {
            return self.term.clone();
        }
        let xs: Vec<String> = (0..self.arity.max(1)).map(|i| format!("x{i}")).collect();
        let app = if self.arity == 0 {
            format!("{} ()", p(&self.term))
        } else {
            format!("{} {}", p(&self.term), xs.join(" "))
        };
        format!("(fun {} => pure ({app}))", xs.join(" "))
    }
}

/// Short-circuiting iterator stages pull items lazily.
const SHORT_CIRCUIT: &[&str] = &[
    "any",
    "all",
    "position",
    "find",
    "take_while",
    "next",
    "find_map",
];

impl Body<'_> {
    /// Translate an argument expected to be a function of `args` returning `ret`.
    pub fn fn_arg(&mut self, e: &Expr, args: &[Ty], ret: Option<Ty>) -> R<FnArg> {
        match strip(e) {
            Expr::Closure(c) => {
                let v = self.closure_with(c, args, ret)?;
                let pure = self.last_closure_pure.get().unwrap_or(false);
                let Ty::Fn(a, r) = v.ty else { unreachable!() };
                Ok(FnArg {
                    term: v.term.unwrap(),
                    pure,
                    arity: a.len(),
                    ret: *r,
                })
            }
            Expr::Reference(r) => self.fn_arg(&r.expr, args, ret),
            other => {
                let (t, ty) = self.value(other, None)?;
                let pure_local = match strip(other) {
                    Expr::Path(pp) if pp.path.segments.len() == 1 => self
                        .locals
                        .iter()
                        .rev()
                        .find(|l| l.lean == t)
                        .and_then(|l| l.pure_fn),
                    _ => None,
                };
                let (arity, r, pure) = match self.resolve(&ty).peel() {
                    Ty::Fn(a, r) => (
                        a.len().max(args.len()),
                        (**r).clone(),
                        pure_local.unwrap_or(t.starts_with("(fun o =>")),
                    ),
                    other => return Err(format!("expected a function, found {other:?}")),
                };
                Ok(FnArg {
                    term: t,
                    pure,
                    arity,
                    ret: if matches!(r, Ty::Unit) {
                        ret.unwrap_or(r)
                    } else {
                        r
                    },
                })
            }
        }
    }

    // ---------------------------------------------------------------- calls

    pub fn call(&mut self, c: &syn::ExprCall, expect: Option<&Ty>) -> R<V> {
        let Expr::Path(fp) = strip(&c.func) else {
            // A call of a function-valued expression, such as a field.
            let (f, ft) = self.value(&c.func, None)?;
            let Ty::Fn(args, ret) = self.resolve(&ft).peel().clone() else {
                return Err("call of a non-function".into());
            };
            let mut terms = vec![];
            for (a, t) in c.args.iter().zip(args.iter()) {
                terms.push(p(&self.value(a, Some(t))?.0));
            }
            let t = self.bind(format!("{} {}", p(&f), terms.join(" ")));
            return Ok(V {
                term: Some(t),
                ty: *ret,
            });
        };
        let names: Vec<String> = fp
            .path
            .segments
            .iter()
            .map(|s| s.ident.to_string())
            .collect();
        // Local closures and function-typed parameters.
        if names.len() == 1 {
            if let Some(id) = self.lookup_local(&names[0]) {
                let l = self.locals[id].clone();
                let Ty::Fn(args, ret) = self.resolve(&l.ty).peel().clone() else {
                    return Err(format!("{} is not callable", names[0]));
                };
                let mut terms = vec![];
                for (i, a) in c.args.iter().enumerate() {
                    let at = args.get(i).cloned();
                    let v = self.value(a, at.as_ref())?;
                    terms.push(p(&v.0));
                }
                let call = format!(
                    "{} {}",
                    l.lean,
                    if terms.is_empty() {
                        "()".into()
                    } else {
                        terms.join(" ")
                    }
                );
                if l.pure_fn == Some(true) {
                    return Ok(V {
                        term: Some(call),
                        ty: *ret,
                    });
                }
                let t = self.bind(call);
                return Ok(V {
                    term: Some(t),
                    ty: *ret,
                });
            }
        }
        let last = names.last().unwrap().as_str();
        match (names.len(), last) {
            (1, "Some") => {
                let inner = match expect.map(|t| self.resolve(t)) {
                    Some(Ty::Option(t)) => Some(*t),
                    _ => None,
                };
                let (t, ty) = self.value(&c.args[0], inner.as_ref())?;
                return Ok(V {
                    term: Some(format!("some {}", p(&t))),
                    ty: Ty::Option(Box::new(ty)),
                });
            }
            (1, "Ok") | (1, "Err") => {
                let (a, b) = match expect.map(|t| self.resolve(t)) {
                    Some(Ty::Result(a, b)) => (Some(*a), Some(*b)),
                    _ => match self.resolve(&self.ret_ty.clone()) {
                        Ty::Result(a, b) => (Some(*a), Some(*b)),
                        _ => (None, None),
                    },
                };
                let ok = last == "Ok";
                let (t, ty) = self.value(&c.args[0], if ok { a.as_ref() } else { b.as_ref() })?;
                let rty = if ok {
                    Ty::Result(Box::new(ty), Box::new(b.unwrap_or(Ty::Unit)))
                } else {
                    Ty::Result(Box::new(a.unwrap_or(Ty::Unit)), Box::new(ty))
                };
                return Ok(V {
                    term: Some(format!("Rust.Result.{last} {}", p(&t))),
                    ty: rty,
                });
            }
            (1, "drop") => {
                let Expr::Path(lp) = strip(&c.args[0]) else {
                    return Err("drop of a non-local".into());
                };
                let id = self
                    .lookup_local(&lp.path.segments[0].ident.to_string())
                    .ok_or("drop of an unknown local")?;
                self.drop_now(id)?;
                return Ok(V {
                    term: Some("()".into()),
                    ty: Ty::Unit,
                });
            }
            _ => {}
        }
        let joined = names.join("::");
        match joined.as_str() {
            "core::array::from_fn" | "array::from_fn" | "std::array::from_fn" => {
                let Some(Ty::Array(et, len)) = expect.map(|t| self.resolve(t)) else {
                    return Err("array::from_fn needs a known array type".into());
                };
                let f = self.fn_arg(&c.args[0], &[Ty::usize()], Some((*et).clone()))?;
                let l = self.cx.names.len(&len);
                if f.pure {
                    return Ok(V {
                        term: Some(format!("Rust.Slice.from_fn {l} {}", p(&f.term))),
                        ty: Ty::Array(et, len),
                    });
                }
                let t = self.bind(format!("Rust.Slice.from_fnM {l} {}", p(&f.term)));
                return Ok(V {
                    term: Some(t),
                    ty: Ty::Array(et, len),
                });
            }
            "core::iter::once_with" | "iter::once_with" => {
                let f = self.fn_arg(&c.args[0], &[], None)?;
                if !f.pure {
                    return Err("once_with of a closure that may panic".into());
                }
                return Ok(V {
                    term: Some(format!("[{} ()]", p(&f.term))),
                    ty: Ty::Iter(Box::new(f.ret)),
                });
            }
            "core::iter::once" | "iter::once" => {
                let (t, ty) = self.value(&c.args[0], None)?;
                return Ok(V {
                    term: Some(format!("[{t}]")),
                    ty: Ty::Iter(Box::new(ty)),
                });
            }
            _ => {}
        }
        if names.len() == 2 {
            let to = match names[0].as_str() {
                "u8" => Some(Ty::Uint(8, "u8")),
                "u16" => Some(Ty::Uint(16, "u16")),
                "u32" => Some(Ty::Uint(32, "u32")),
                "u64" => Some(Ty::u64()),
                "usize" => Some(Ty::usize()),
                _ => None,
            };
            if let Some(to) = to {
                let Ty::Uint(bits, _) = to else {
                    unreachable!()
                };
                let (t, from) = self.value(&c.args[0], None)?;
                let lt = self.lean_ty(&to);
                return match (names[1].as_str(), self.resolve(&from)) {
                    ("from", Ty::Bool) => Ok(V {
                        term: Some(format!("(Rust.ofBool {} : {lt})", p(&t))),
                        ty: to,
                    }),
                    ("from", Ty::Uint(b, _)) if b <= bits => Ok(V {
                        term: Some(format!("(Rust.cast {} : {lt})", p(&t))),
                        ty: to,
                    }),
                    ("try_from", Ty::Uint(..)) => Ok(V {
                        term: Some(format!("(Rust.try_from (m := {bits}) {})", p(&t))),
                        ty: Ty::Result(Box::new(to), Box::new(Ty::TryFromIntError)),
                    }),
                    _ => Err(format!("unsupported conversion {joined}")),
                };
            }
        }
        // Crate functions, associated functions and constructors.
        let resolved = if names[0] == "Self" {
            let Some(Ty::Adt(sp, ..)) = &self.self_ty else {
                return Err("Self outside impl".into());
            };
            format!("{sp}::{}", names[1..].join("::"))
        } else {
            self.cx
                .k
                .resolve(&self.module, &names)
                .ok_or_else(|| format!("unresolved function {joined}"))?
        };
        if let Some(f) = self.function_at(&resolved, None) {
            let f = f.clone();
            let turbofish = fp.path.segments.last().unwrap().arguments.clone();
            let args: Vec<Expr> = c.args.iter().cloned().collect();
            let inst = if names[0] == "Self" {
                self.self_ty.clone()
            } else {
                None
            };
            return self.crate_call_in(&f, None, &args, &turbofish, expect, inst);
        }
        // `Type::default()` for a derived `Default`.
        if last == "default" && c.args.is_empty() {
            let (tp, _) = resolved.rsplit_once("::").unwrap_or(("", ""));
            if self.cx.k.structs.contains_key(tp) || self.cx.k.enums.contains_key(tp) {
                let ty = self.adt_ty(tp, expect)?;
                return Ok(V {
                    term: Some(format!("{}.default", self.cx.names.types[tp])),
                    ty,
                });
            }
        }
        // Tuple struct or tuple variant constructors.
        let ty = self.ctor_ty(&resolved, expect)?;
        let (ctor, decl, fields) = self.ctor(&fp.path, &ty)?;
        let mut terms = vec![];
        for (a, (_, ft)) in c.args.iter().zip(fields.iter()) {
            let (t, at) = self.value(a, Some(ft))?;
            self.unify(ft, &at);
            terms.push(p(&t));
        }
        if decl {
            return Ok(V {
                term: Some(format!("⟨{}⟩", terms.join(", "))),
                ty,
            });
        }
        Ok(V {
            term: Some(format!("{ctor} {}", terms.join(" "))),
            ty,
        })
    }

    fn lookup_local(&self, name: &str) -> Option<usize> {
        self.lookup(name)
    }

    /// The crate function at `path`, optionally the one whose impl self type
    /// matches a receiver with or without references.
    fn function_at(&self, path: &str, receiver_refs: Option<bool>) -> Option<&Function> {
        let _ = receiver_refs;
        if let Some(f) = self.cx.k.functions.get(path) {
            return Some(f);
        }
        self.cx
            .k
            .functions
            .iter()
            .find(|(k, _)| k.split('#').next() == Some(path))
            .map(|(_, f)| f)
    }

    /// Call a crate function. `recv` is the receiver expression for method calls.
    pub fn crate_call(
        &mut self,
        f: &Function,
        recv: Option<&Expr>,
        args: &[Expr],
        turbofish: &syn::PathArguments,
        expect: Option<&Ty>,
    ) -> R<V> {
        self.crate_call_in(f, recv, args, turbofish, expect, None)
    }

    /// `inst`: the impl's self type instance when known (calls through `Self::`).
    pub fn crate_call_in(
        &mut self,
        f: &Function,
        recv: Option<&Expr>,
        args: &[Expr],
        turbofish: &syn::PathArguments,
        expect: Option<&Ty>,
        inst: Option<Ty>,
    ) -> R<V> {
        let generics = function_generics(f)?;
        let impl_self = match &f.self_ty {
            Some(t) => {
                let mut g = Generics::default();
                g.extend(&f.impl_generics)?;
                let scope = TyScope {
                    krate: self.cx.k,
                    module: &f.module,
                    generics: &g,
                    self_ty: None,
                };
                Some(scope.ty(t)?)
            }
            None => None,
        };
        let scope = TyScope {
            krate: self.cx.k,
            module: &f.module,
            generics: &generics,
            self_ty: impl_self.as_ref(),
        };
        let mut params: Vec<(bool, Ty)> = vec![];
        let mut receiver = None;
        for input in &f.sig.inputs {
            match input {
                syn::FnArg::Receiver(r) => {
                    let mutable = r.reference.is_some() && r.mutability.is_some();
                    receiver = Some(mutable);
                    params.push((mutable, impl_self.clone().unwrap()));
                }
                syn::FnArg::Typed(t) => {
                    let ty = scope.ty(&t.ty)?;
                    params.push((ty.mut_ref(), ty));
                }
            }
        }
        let ret = match &f.sig.output {
            syn::ReturnType::Default => Ty::Unit,
            syn::ReturnType::Type(_, t) => scope.ty(t)?,
        };
        // Instantiate the impl's generics from the receiver or expected type.
        let mut sub_t: Vec<(String, Ty)> = vec![];
        let mut sub_l: Vec<(String, Len)> = vec![];
        let mut g = Generics::default();
        g.extend(&f.impl_generics)?;
        if let Some(t) = &inst {
            self.instantiate(&g, t, &mut sub_t, &mut sub_l);
        }
        let mut all = vec![];
        let mut arg_exprs: Vec<&Expr> = vec![];
        if let Some(r) = recv {
            arg_exprs.push(r);
        }
        arg_exprs.extend(args.iter());
        if arg_exprs.len() != params.len() {
            return Err(format!("{} takes {} arguments", f.path, params.len()));
        }
        // Receiver first: its type fixes the impl generics.
        let mut write_backs: Vec<Place> = vec![];
        for (i, ((mutable, pty), arg)) in params.iter().zip(arg_exprs.iter()).enumerate() {
            let pty_s = pty.subst(&sub_t, &sub_l);
            let holds =
                pty_s.peel().holds_mut_borrow(self.cx.k) && !matches!(pty_s.peel(), Ty::Fn(..));
            let is_fn = matches!(pty_s.peel(), Ty::Fn(..));
            if is_fn {
                let Ty::Fn(a, r) = pty_s.peel().clone() else {
                    unreachable!()
                };
                let fa = self.fn_arg(arg, &a, Some(*r))?;
                all.push(p(&fa.monadic()));
                continue;
            }
            if *mutable || holds {
                let target = match strip(arg) {
                    Expr::Reference(r) => &*r.expr,
                    e => e,
                };
                let place = self
                    .place(target)?
                    .ok_or_else(|| format!("&mut argument is not a place: {}", tokens(*arg)))?;
                let cur = self.read_place(&place)?;
                if i == 0 && receiver.is_some() {
                    self.instantiate(&g, &place.ty, &mut sub_t, &mut sub_l);
                }
                all.push(p(&cur));
                write_backs.push(place);
                continue;
            }
            let (t, at) = self.value(arg, Some(&pty_s))?;
            // Unsizing: an array reference passed as a slice.
            let t = match (self.resolve(&pty_s).peel(), self.resolve(&at).peel()) {
                (Ty::Slice(_), Ty::Array(..)) if t.starts_with("#v[") => format!("#[{}", &t[3..]),
                (Ty::Slice(_), Ty::Array(..)) => format!("{}.toArray", p(&t)),
                _ => t,
            };
            if i == 0 && receiver.is_some() {
                self.instantiate(&g, &at, &mut sub_t, &mut sub_l);
            }
            self.unify(&pty_s, &at);
            all.push(p(&t));
        }
        // A result that borrows a `&mut` argument (`fn ready(&mut self) ->
        // Option<Ready<'_>>`): the argument is not returned; the result's
        // binding writes through to it instead.
        let borrows = self.returns_borrow(&ret);
        let lent = if borrows {
            write_backs.drain(..).next()
        } else {
            None
        };
        let mut ret = ret.subst(&sub_t, &sub_l);
        if let (Some(x), Ty::Adt(..)) = (expect, &ret) {
            if !ret_known(&ret) {
                ret = x.clone();
            }
        }
        let name = self.cx.names.functions[&f.path].clone();
        self.calls.insert(f.path.clone());
        let mut call = name;
        // Impl generics no parameter mentions cannot be inferred by Lean: pass them.
        let mentioned = params
            .iter()
            .map(|(_, t)| format!("{t:?}"))
            .collect::<String>();
        for (n, t) in &sub_t {
            if !mentioned.contains(&format!("Param(\"{n}\")"))
                && !matches!(t, Ty::Param(x) if x.starts_with('?'))
            {
                call.push_str(&format!(" ({} := {})", ident(n), self.lean_ty(t)));
            }
        }
        for (n, l) in &sub_l {
            if !mentioned.contains(&format!("Param(\"{n}\")"))
                && !matches!(l, Len::Param(x) if x.starts_with('?'))
            {
                call.push_str(&format!(" ({} := {})", ident(n), self.cx.names.len(l)));
            }
        }
        // Turbofish const arguments.
        if let syn::PathArguments::AngleBracketed(a) = turbofish {
            let mut fg = Generics::default();
            fg.extend(&f.sig.generics)?;
            for (arg, nm) in a.args.iter().zip(fg.consts.iter().chain(fg.types.iter())) {
                let s = match arg {
                    syn::GenericArgument::Const(e) => self.cx.names.len(&self.tys().len(e)?),
                    syn::GenericArgument::Type(t) => match self.tys().ty(t) {
                        Ok(t) => self.lean_ty(&t),
                        Err(_) => tokens(t),
                    },
                    other => return Err(format!("unsupported generic argument {}", tokens(other))),
                };
                call.push_str(&format!(" ({} := {s})", ident(nm)));
            }
        }
        for a in &all {
            call.push(' ');
            call.push_str(a);
        }
        if all.is_empty() {
            // Lean definitions without explicit parameters are values.
        }
        let pure = self.cx.pure_fns.contains(&f.path);
        let ret_unit = matches!(self.resolve(&ret).peel(), Ty::Unit);
        let n_out = usize::from(!ret_unit) + write_backs.len();
        if write_backs.is_empty() {
            let t = if pure { call } else { self.bind(call) };
            if let Some(place) = lent {
                self.pending_borrow = Some((t.clone(), place));
            }
            return Ok(V {
                term: Some(t),
                ty: ret,
            });
        }
        let mut names = vec![];
        let result = if ret_unit {
            None
        } else {
            let t = self.synthetic("r");
            names.push(t.clone());
            Some(t)
        };
        for _ in &write_backs {
            names.push(self.synthetic("m"));
        }
        let pat = if n_out == 1 {
            names[0].clone()
        } else {
            format!("({})", names.join(", "))
        };
        if pure {
            self.emit(format!("let {pat} := {call}"));
        } else {
            self.impure = true;
            self.emit(format!("let {pat} ← {call}"));
        }
        let offset = usize::from(result.is_some());
        for (i, place) in write_backs.iter().enumerate() {
            self.write_place(place, names[offset + i].clone())?;
        }
        Ok(V {
            term: Some(result.unwrap_or_else(|| "()".into())),
            ty: ret,
        })
    }

    /// Whether a type is, or optionally holds, a struct borrowing a place mutably.
    pub fn returns_borrow(&self, t: &Ty) -> bool {
        match self.resolve(t).peel() {
            Ty::Option(i) => self.returns_borrow(i),
            t @ Ty::Adt(..) => self.borrow_field(t).is_some(),
            _ => false,
        }
    }

    fn instantiate(
        &self,
        g: &Generics,
        actual: &Ty,
        sub_t: &mut Vec<(String, Ty)>,
        sub_l: &mut Vec<(String, Len)>,
    ) {
        if let Ty::Adt(_, tys, lens) = self.resolve(actual).peel() {
            sub_t.extend(g.types.iter().cloned().zip(tys.iter().cloned()));
            sub_l.extend(g.consts.iter().cloned().zip(lens.iter().cloned()));
        }
    }

    // --------------------------------------------------------- method calls

    pub fn method_call(&mut self, m: &syn::ExprMethodCall, expect: Option<&Ty>) -> R<V> {
        let name = m.method.to_string();
        let args: Vec<Expr> = m.args.iter().cloned().collect();
        // The receiver as a place when it is one, so `&mut self` methods write back.
        let place = self.place(&m.receiver)?;
        let rty = match &place {
            Some(pl) => pl.ty.clone(),
            None => {
                // Evaluate below; peek at the type by translating once.
                Ty::Unit
            }
        };
        let (place, rty, value) = if place.is_some() {
            (place, self.resolve(&rty), None)
        } else {
            let v = self.value(&m.receiver, None)?;
            (None, self.resolve(&v.1), Some(v.0))
        };
        let base = rty.peel().clone();
        if let Ty::Adt(owner, ..) = &base {
            let path = format!("{owner}::{name}");
            if let Some(f) = self.function_at(&path, None).cloned() {
                let turbofish = m
                    .turbofish
                    .as_ref()
                    .map(|t| syn::PathArguments::AngleBracketed(t.clone()));
                let turbofish = turbofish.unwrap_or(syn::PathArguments::None);
                if let Some(v) = value {
                    // A receiver that is not a place: bind it first.
                    let tmp = self.synthetic("recv");
                    self.emit(format!("let mut {tmp} := {v}"));
                    let id = self.declare(&tmp, Body::local(tmp.clone(), rty.clone(), true));
                    let e: Expr = syn::parse_str(&tmp).map_err(|e| e.to_string())?;
                    let _ = id;
                    return self.crate_call(&f, Some(&e), &args, &turbofish, expect);
                }
                return self.crate_call(&f, Some(&m.receiver), &args, &turbofish, expect);
            }
        }
        let recv = match value {
            Some(v) => v,
            None => self.read_place(place.as_ref().unwrap())?,
        };
        let r = p(&recv);
        let ty = |t: Ty| t;
        // Methods every type shares.
        match name.as_str() {
            "clone" | "cloned" | "copied" | "as_ref" | "as_slice" | "into_iter" | "by_ref"
                if args.is_empty() =>
            {
                let t = match (&base, name.as_str()) {
                    (Ty::Option(i), "cloned" | "copied") => Ty::Option(Box::new(i.peel().clone())),
                    (Ty::Iter(i), "cloned" | "copied") => Ty::Iter(Box::new(i.peel().clone())),
                    (Ty::Array(i, _), "into_iter") => Ty::Iter(i.clone()),
                    (Ty::Option(i), "as_ref") => Ty::Option(Box::new(Ty::Ref(false, i.clone()))),
                    _ => base.clone(),
                };
                if name == "into_iter" {
                    let (l, it) = self.as_list(recv, &base)?;
                    return Ok(V {
                        term: Some(l),
                        ty: Ty::Iter(Box::new(it)),
                    });
                }
                if self.effectful_iters.contains(&recv) {
                    self.effectful_iters.insert(recv.clone());
                }
                return Ok(V {
                    term: Some(recv),
                    ty: t,
                });
            }
            _ => {}
        }
        match &base {
            Ty::Uint(bits, _) => {
                let bits = *bits;
                let one =
                    |s: &mut Self, e: &Expr| -> R<String> { Ok(p(&s.value(e, Some(&base))?.0)) };
                let t = match name.as_str() {
                    "checked_add" | "checked_sub" | "checked_mul" => {
                        let a = one(self, &args[0])?;
                        return Ok(V {
                            term: Some(format!("Rust.{name} {r} {a}")),
                            ty: Ty::Option(Box::new(base.clone())),
                        });
                    }
                    "saturating_add" | "saturating_sub" | "wrapping_add" | "wrapping_sub"
                    | "wrapping_mul" | "min" | "max" => {
                        let a = one(self, &args[0])?;
                        format!("Rust.{name} {r} {a}")
                    }
                    "clamp" => {
                        let a = one(self, &args[0])?;
                        let b = one(self, &args[1])?;
                        self.bind(format!("Rust.clamp {r} {a} {b}"))
                    }
                    "pow" | "count_ones" | "leading_zeros" => {
                        return Err(format!("unsupported integer method {name}"))
                    }
                    _ => return Err(format!("unsupported u{bits} method {name}")),
                };
                Ok(V {
                    term: Some(t),
                    ty: ty(base.clone()),
                })
            }
            Ty::Bool => match name.as_str() {
                "then_some" => {
                    let (a, at) = self.value(
                        &args[0],
                        expect
                            .and_then(|t| match self.resolve(t) {
                                Ty::Option(i) => Some(*i),
                                _ => None,
                            })
                            .as_ref(),
                    )?;
                    Ok(V {
                        term: Some(format!("Rust.Option.then_some {r} {}", p(&a))),
                        ty: Ty::Option(Box::new(at)),
                    })
                }
                "then" => {
                    let f = self.fn_arg(&args[0], &[], None)?;
                    if f.pure {
                        return Ok(V {
                            term: Some(format!("(if {r} then some ({} ()) else none)", p(&f.term))),
                            ty: Ty::Option(Box::new(f.ret)),
                        });
                    }
                    let t = self.bind(format!(
                        "if {r} then some <$> {} () else pure none",
                        p(&f.term)
                    ));
                    Ok(V {
                        term: Some(t),
                        ty: Ty::Option(Box::new(f.ret)),
                    })
                }
                _ => Err(format!("unsupported bool method {name}")),
            },
            Ty::Option(inner) => self.option_method(&name, &args, r, place.as_ref(), inner, expect),
            Ty::Result(a, b) => {
                let (a, b) = ((**a).clone(), (**b).clone());
                match name.as_str() {
                    "is_ok" => Ok(V {
                        term: Some(format!("{r}.is_ok")),
                        ty: Ty::Bool,
                    }),
                    "is_err" => Ok(V {
                        term: Some(format!("{r}.is_err")),
                        ty: Ty::Bool,
                    }),
                    "ok" => Ok(V {
                        term: Some(format!("{r}.ok")),
                        ty: Ty::Option(Box::new(a)),
                    }),
                    "unwrap" => {
                        let t = self.bind(format!("Rust.Result.unwrap {r}"));
                        Ok(V {
                            term: Some(t),
                            ty: a,
                        })
                    }
                    "expect" => {
                        let (msg, _) = self.value(&args[0], None)?;
                        let t = self.bind(format!("Rust.Result.expect {r} {msg}"));
                        Ok(V {
                            term: Some(t),
                            ty: a,
                        })
                    }
                    "unwrap_or" => {
                        let (d, _) = self.value(&args[0], Some(&a))?;
                        Ok(V {
                            term: Some(format!("Rust.Result.unwrap_or {r} {}", p(&d))),
                            ty: a,
                        })
                    }
                    "map_err" => {
                        let f = self.fn_arg(&args[0], &[b], None)?;
                        if f.pure {
                            return Ok(V {
                                term: Some(format!("Rust.Result.map_err {r} {}", p(&f.term))),
                                ty: Ty::Result(Box::new(a), Box::new(f.ret)),
                            });
                        }
                        let t = self.bind(format!("Rust.Result.map_errM {r} {}", p(&f.term)));
                        Ok(V {
                            term: Some(t),
                            ty: Ty::Result(Box::new(a), Box::new(f.ret)),
                        })
                    }
                    _ => Err(format!("unsupported Result method {name}")),
                }
            }
            Ty::Array(e, len) => self.array_method(
                &name,
                &args,
                r,
                place.as_ref(),
                e,
                Some(len.clone()),
                expect,
            ),
            Ty::Slice(e) => self.array_method(&name, &args, r, place.as_ref(), e, None, expect),
            Ty::Iter(e) => self.iter_method(&name, &args, recv, e, expect),
            other => Err(format!("unsupported method {name} on {other:?}")),
        }
    }

    fn option_method(
        &mut self,
        name: &str,
        args: &[Expr],
        r: String,
        place: Option<&Place>,
        inner: &Ty,
        expect: Option<&Ty>,
    ) -> R<V> {
        let inner = inner.peel().clone();
        let opt = |t: Ty| Ty::Option(Box::new(t));
        match name {
            "is_some" => Ok(V {
                term: Some(format!("{r}.isSome")),
                ty: Ty::Bool,
            }),
            "is_none" => Ok(V {
                term: Some(format!("{r}.isNone")),
                ty: Ty::Bool,
            }),
            "is_some_and" | "is_none_or" => {
                let f = self.fn_arg(&args[0], std::slice::from_ref(&inner), Some(Ty::Bool))?;
                if f.pure {
                    return Ok(V {
                        term: Some(format!("Rust.Option.{name} {r} {}", p(&f.term))),
                        ty: Ty::Bool,
                    });
                }
                let t = self.bind(format!("Rust.Option.{name}M {r} {}", p(&f.term)));
                Ok(V {
                    term: Some(t),
                    ty: Ty::Bool,
                })
            }
            "map" => {
                let f = self.fn_arg(&args[0], std::slice::from_ref(&inner), None)?;
                if f.pure {
                    return Ok(V {
                        term: Some(format!("{r}.map {}", p(&f.term))),
                        ty: opt(f.ret),
                    });
                }
                let t = self.bind(format!("Rust.Option.mapM {r} {}", p(&f.term)));
                Ok(V {
                    term: Some(t),
                    ty: opt(f.ret),
                })
            }
            "and_then" => {
                let f = self.fn_arg(&args[0], std::slice::from_ref(&inner), None)?;
                let ret = match self.resolve(&f.ret) {
                    Ty::Option(_) => f.ret.clone(),
                    t => opt(t),
                };
                if f.pure {
                    return Ok(V {
                        term: Some(format!("{r}.bind {}", p(&f.term))),
                        ty: ret,
                    });
                }
                let t = self.bind(format!("Rust.Option.and_thenM {r} {}", p(&f.term)));
                Ok(V {
                    term: Some(t),
                    ty: ret,
                })
            }
            "filter" => {
                let f = self.fn_arg(&args[0], std::slice::from_ref(&inner), Some(Ty::Bool))?;
                if f.pure {
                    return Ok(V {
                        term: Some(format!("{r}.filter {}", p(&f.term))),
                        ty: opt(inner),
                    });
                }
                let t = self.bind(format!("Rust.Option.filterM {r} {}", p(&f.term)));
                Ok(V {
                    term: Some(t),
                    ty: opt(inner),
                })
            }
            "or_else" => {
                let f = self.fn_arg(&args[0], &[], Some(opt(inner.clone())))?;
                if f.pure {
                    return Ok(V {
                        term: Some(format!("({r}.orElse {})", p(&f.term))),
                        ty: opt(inner),
                    });
                }
                let t = self.bind(format!("Rust.Option.or_elseM {r} {}", p(&f.term)));
                Ok(V {
                    term: Some(t),
                    ty: opt(inner),
                })
            }
            "map_or" => {
                let (d, dt) = self.value(&args[0], expect)?;
                let f = self.fn_arg(&args[1], std::slice::from_ref(&inner), Some(dt.clone()))?;
                self.unify(&dt, &f.ret);
                if f.pure {
                    return Ok(V {
                        term: Some(format!("Rust.Option.map_or {r} {} {}", p(&d), p(&f.term))),
                        ty: dt,
                    });
                }
                let t = self.bind(format!("Rust.Option.map_orM {r} {} {}", p(&d), p(&f.term)));
                Ok(V {
                    term: Some(t),
                    ty: dt,
                })
            }
            "ok_or" => {
                let (e, et) = self.value(&args[0], None)?;
                Ok(V {
                    term: Some(format!("Rust.Option.ok_or {r} {}", p(&e))),
                    ty: Ty::Result(Box::new(inner), Box::new(et)),
                })
            }
            "unwrap_or" => {
                let (d, _) = self.value(&args[0], Some(&inner))?;
                Ok(V {
                    term: Some(format!("{r}.getD {}", p(&d))),
                    ty: inner,
                })
            }
            "unwrap" => {
                let t = self.bind(format!("Rust.Option.unwrap {r}"));
                Ok(V {
                    term: Some(t),
                    ty: inner,
                })
            }
            "expect" => {
                let (msg, _) = self.value(&args[0], None)?;
                let t = self.bind(format!("Rust.Option.expect {r} {msg}"));
                Ok(V {
                    term: Some(t),
                    ty: inner,
                })
            }
            "iter" => Ok(V {
                term: Some(format!("{r}.toList")),
                ty: Ty::Iter(Box::new(inner)),
            }),
            "take" => {
                let place = place.ok_or("Option::take on a non-place")?.clone();
                let t = self.synthetic("taken");
                self.emit(format!("let {t} := {r}"));
                self.write_place(&place, "none".into())?;
                Ok(V {
                    term: Some(t),
                    ty: opt(inner),
                })
            }
            _ => Err(format!("unsupported Option method {name}")),
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn array_method(
        &mut self,
        name: &str,
        args: &[Expr],
        r: String,
        place: Option<&Place>,
        e: &Ty,
        len: Option<Len>,
        expect: Option<&Ty>,
    ) -> R<V> {
        let e = e.clone();
        let vector = len.is_some();
        let list = format!("{r}.toList");
        match name {
            "iter" => Ok(V {
                term: Some(list),
                ty: Ty::Iter(Box::new(e)),
            }),
            "len" => Ok(V {
                term: Some(if vector {
                    format!("Rust.Slice.len {r}")
                } else {
                    format!("(Rust.usizeOf {r}.size)")
                }),
                ty: Ty::usize(),
            }),
            "is_empty" => Ok(V {
                term: Some(if vector {
                    format!("Rust.Slice.len {r} == 0")
                } else {
                    format!("{r}.isEmpty")
                }),
                ty: Ty::Bool,
            }),
            "contains" => {
                let (x, _) = self.value(&args[0], Some(&Ty::Ref(false, Box::new(e.clone()))))?;
                Ok(V {
                    term: Some(format!("{list}.contains {}", p(&x))),
                    ty: Ty::Bool,
                })
            }
            "get" => {
                let (i, _) = self.value(&args[0], Some(&Ty::usize()))?;
                let term = if vector {
                    format!("Rust.Slice.get {r} {}", p(&i))
                } else {
                    format!("{r}[{}.val]?", p(&i))
                };
                Ok(V {
                    term: Some(term),
                    ty: Ty::Option(Box::new(e)),
                })
            }
            "map" if vector => {
                let f = self.fn_arg(&args[0], std::slice::from_ref(&e), None)?;
                let l = len.unwrap();
                if f.pure {
                    return Ok(V {
                        term: Some(format!("{r}.map {}", p(&f.term))),
                        ty: Ty::Array(Box::new(f.ret), l),
                    });
                }
                let t = self.bind(format!("{r}.mapM {}", p(&f.term)));
                Ok(V {
                    term: Some(t),
                    ty: Ty::Array(Box::new(f.ret), l),
                })
            }
            "fill" => {
                let place = place.ok_or("fill on a non-place")?.clone();
                let (v, _) = self.value(&args[0], Some(&e))?;
                let new = if vector {
                    format!("Rust.Slice.fill {r} {}", p(&v))
                } else {
                    format!("Array.replicate {r}.size {}", p(&v))
                };
                self.write_place(&place, new)?;
                Ok(V {
                    term: Some("()".into()),
                    ty: Ty::Unit,
                })
            }
            "sort_unstable" => {
                let place = place.ok_or("sort_unstable on a non-place")?.clone();
                if !matches!(self.resolve(&e), Ty::Uint(..)) {
                    return Err("sort_unstable is supported for unsigned integers only".into());
                }
                let new = if vector {
                    format!("⟨Rust.Slice.sort_unstable {r}.toArray, by simp [Rust.Slice.sort_unstable]⟩")
                } else {
                    format!("Rust.Slice.sort_unstable {r}")
                };
                self.write_place(&place, new)?;
                Ok(V {
                    term: Some("()".into()),
                    ty: Ty::Unit,
                })
            }
            "rotate_left" => {
                let place = place.ok_or("rotate_left on a non-place")?.clone();
                if vector {
                    return Err("rotate_left on a whole array is unsupported".into());
                }
                let (k, _) = self.value(&args[0], Some(&Ty::usize()))?;
                let t = self.bind(format!("Rust.Slice.rotate_left {r} {}", p(&k)));
                self.write_place(&place, t)?;
                Ok(V {
                    term: Some("()".into()),
                    ty: Ty::Unit,
                })
            }
            _ => {
                let _ = expect;
                Err(format!("unsupported array/slice method {name}"))
            }
        }
    }

    fn iter_method(
        &mut self,
        name: &str,
        args: &[Expr],
        recv: String,
        e: &Ty,
        expect: Option<&Ty>,
    ) -> R<V> {
        let e = e.peel().clone();
        let r = p(&recv);
        let upstream_effects = self.effectful_iters.contains(&recv);
        if upstream_effects && SHORT_CIRCUIT.contains(&name) {
            return Err(format!(
                "iterator stage {name} would stop a lazy pipeline early after a stage that may panic; unsupported"
            ));
        }
        let stage =
            |s: &mut Self, f_pure: bool, pure_term: String, monadic: String, ty: Ty| -> R<V> {
                if f_pure {
                    if upstream_effects {
                        s.effectful_iters.insert(pure_term.clone());
                    }
                    return Ok(V {
                        term: Some(pure_term),
                        ty,
                    });
                }
                if upstream_effects {
                    return Err(
                        "two iterator stages that may panic in one pipeline are unsupported".into(),
                    );
                }
                let t = s.bind(monadic);
                s.effectful_iters.insert(t.clone());
                Ok(V { term: Some(t), ty })
            };
        let item = e.clone();
        match name {
            "flatten" => {
                let inner = match self.resolve(&item) {
                    Ty::Option(i) => (*i).clone(),
                    Ty::Ref(_, i) => match *i {
                        Ty::Option(i) => *i,
                        _ => return Err("flatten of non-Option items".into()),
                    },
                    _ => return Err("flatten of non-Option items".into()),
                };
                stage(
                    self,
                    true,
                    format!("Rust.Iter.flatten {r}"),
                    String::new(),
                    Ty::Iter(Box::new(inner)),
                )
            }
            "enumerate" => stage(
                self,
                true,
                format!("Rust.Iter.enumerate {r}"),
                String::new(),
                Ty::Iter(Box::new(Ty::Tuple(vec![Ty::usize(), item]))),
            ),
            "rev" => stage(
                self,
                true,
                format!("{r}.reverse"),
                String::new(),
                Ty::Iter(Box::new(item)),
            ),
            "filter" => {
                let f = self.fn_arg(
                    &args[0],
                    &[Ty::Ref(false, Box::new(item.clone()))],
                    Some(Ty::Bool),
                )?;
                let (pt, mt) = (
                    format!("{r}.filter {}", p(&f.term)),
                    format!("{r}.filterM {}", p(&f.term)),
                );
                stage(self, f.pure, pt, mt, Ty::Iter(Box::new(item)))
            }
            "map" => {
                let f = self.fn_arg(&args[0], std::slice::from_ref(&item), None)?;
                let (pt, mt) = (
                    format!("{r}.map {}", p(&f.term)),
                    format!("{r}.mapM {}", p(&f.term)),
                );
                stage(self, f.pure, pt, mt, Ty::Iter(Box::new(f.ret)))
            }
            "filter_map" => {
                let f = self.fn_arg(&args[0], std::slice::from_ref(&item), None)?;
                let out = match self.resolve(&f.ret) {
                    Ty::Option(i) => *i,
                    _ => return Err("filter_map closure must return an Option".into()),
                };
                let (pt, mt) = (
                    format!("{r}.filterMap {}", p(&f.term)),
                    format!("{r}.filterMapM {}", p(&f.term)),
                );
                stage(self, f.pure, pt, mt, Ty::Iter(Box::new(out)))
            }
            "take_while" => {
                let f = self.fn_arg(
                    &args[0],
                    &[Ty::Ref(false, Box::new(item.clone()))],
                    Some(Ty::Bool),
                )?;
                let (pt, mt) = (
                    format!("{r}.takeWhile {}", p(&f.term)),
                    format!("Rust.Iter.take_whileM {r} {}", p(&f.term)),
                );
                stage(self, f.pure, pt, mt, Ty::Iter(Box::new(item)))
            }
            "count" => Ok(V {
                term: Some(format!("Rust.Iter.count {r}")),
                ty: Ty::usize(),
            }),
            "next_back" | "last" => Ok(V {
                term: Some(format!("{r}.getLast?")),
                ty: Ty::Option(Box::new(item)),
            }),
            "next" => Ok(V {
                term: Some(format!("{r}.head?")),
                ty: Ty::Option(Box::new(item)),
            }),
            "any" | "all" | "position" | "find" => {
                let arg = if name == "find" {
                    Ty::Ref(false, Box::new(item.clone()))
                } else {
                    item.clone()
                };
                let f = self.fn_arg(&args[0], &[arg], Some(Ty::Bool))?;
                let ty = match name {
                    "position" => Ty::Option(Box::new(Ty::usize())),
                    "find" => Ty::Option(Box::new(item)),
                    _ => Ty::Bool,
                };
                let (pt, mt) = match name {
                    "any" => (
                        format!("{r}.any {}", p(&f.term)),
                        format!("{r}.anyM {}", p(&f.term)),
                    ),
                    "all" => (
                        format!("{r}.all {}", p(&f.term)),
                        format!("{r}.allM {}", p(&f.term)),
                    ),
                    "position" => (
                        format!("Rust.Iter.position {r} {}", p(&f.term)),
                        format!("Rust.Iter.positionM {r} {}", p(&f.term)),
                    ),
                    _ => (
                        format!("{r}.find? {}", p(&f.term)),
                        format!("{r}.findM? {}", p(&f.term)),
                    ),
                };
                if f.pure {
                    return Ok(V { term: Some(pt), ty });
                }
                let t = self.bind(mt);
                Ok(V { term: Some(t), ty })
            }
            _ => {
                let _ = expect;
                Err(format!("unsupported iterator method {name}"))
            }
        }
    }

    // --------------------------------------------------------------- macros

    pub fn macro_(&mut self, mac: &syn::Macro, expect: Option<&Ty>) -> R<V> {
        let name = mac
            .path
            .segments
            .last()
            .map(|s| s.ident.to_string())
            .unwrap_or_default();
        let fail = |s: &mut Self, msg: &str| {
            s.impure = true;
            s.emit(format!("Rust.fail {msg:?}"));
            Ok(V {
                term: None,
                ty: Ty::Never,
            })
        };
        match name.as_str() {
            "unreachable" => fail(self, "internal error: entered unreachable code"),
            "panic" | "todo" | "unimplemented" => fail(self, &format!("{name}: {}", mac.tokens)),
            "assert" | "debug_assert" => {
                if name == "debug_assert" && !self.cx.debug_assertions {
                    return Ok(V {
                        term: Some("()".into()),
                        ty: Ty::Unit,
                    });
                }
                let args = mac
                    .parse_body_with(
                        syn::punctuated::Punctuated::<Expr, syn::Token![,]>::parse_terminated,
                    )
                    .map_err(|e| e.to_string())?;
                let (c, _) = self.value(&args[0], Some(&Ty::Bool))?;
                self.impure = true;
                self.emit(format!("if !{} then Rust.fail \"assertion failed\"", p(&c)));
                Ok(V {
                    term: Some("()".into()),
                    ty: Ty::Unit,
                })
            }
            "matches" => {
                let (e, pat, guard) = mac
                    .parse_body_with(|input: syn::parse::ParseStream| {
                        let e: Expr = input.parse()?;
                        input.parse::<syn::Token![,]>()?;
                        let pat = syn::Pat::parse_multi_with_leading_vert(input)?;
                        let guard = if input.peek(syn::Token![if]) {
                            input.parse::<syn::Token![if]>()?;
                            Some(input.parse::<Expr>()?)
                        } else {
                            None
                        };
                        let _ = input.parse::<Option<syn::Token![,]>>()?;
                        Ok((e, pat, guard))
                    })
                    .map_err(|e| e.to_string())?;
                let guard = guard.map(|g| quote::quote!(if #g));
                let m: syn::ExprMatch =
                    syn::parse2(quote::quote!(match #e { #pat #guard => true, _ => false }))
                        .map_err(|e| e.to_string())?;
                let _ = expect;
                self.expr(&Expr::Match(m), Some(&Ty::Bool))
            }
            _ => Err(format!("unsupported macro {name}!")),
        }
    }
}

fn ret_known(t: &Ty) -> bool {
    match t {
        Ty::Param(p) => !p.starts_with('?'),
        Ty::Adt(_, a, l) => {
            a.iter().all(ret_known)
                && l.iter()
                    .all(|l| !matches!(l, Len::Param(p) if p.starts_with('?')))
        }
        _ => true,
    }
}
