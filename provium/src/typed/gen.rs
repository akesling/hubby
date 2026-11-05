//! Lean module generation: types, constants and functions in dependency order.
use super::emit::{function_generics, Body, Ctx, R};
use super::lean::{ident, Names};
use super::load::{tokens, Function, Krate};
use super::types::{Generics, Len, Scope as TyScope, Ty};
use std::collections::{BTreeMap, BTreeSet};

pub struct Options {
    pub namespace: String,
    pub overflow_checks: bool,
    pub debug_assertions: bool,
}

pub struct Generated {
    /// Per translated function, the facts the rustc cross-check compares.
    pub facts: BTreeMap<String, Facts>,
    pub lean: String,
    /// Crate function path to Lean name, for every translated function.
    pub functions: BTreeMap<String, String>,
    pub pure: BTreeSet<String>,
}

struct Emitted {
    text: String,
    calls: BTreeSet<String>,
    impure: bool,
    lent: Option<Vec<String>>,
    facts: Facts,
}

/// What the translation decided about a function, for checking against rustc.
#[derive(Clone, Debug, Default)]
pub struct Facts {
    /// Crate functions it calls.
    pub calls: BTreeSet<String>,
    /// Source-named locals (parameters, bindings, patterns) and their types.
    pub locals: Vec<(String, Ty)>,
}

fn generic_binders(g: &Generics, bounds: &[(String, String)]) -> String {
    let mut s = String::new();
    if !g.types.is_empty() {
        s.push_str(&format!(
            " {{{} : Type}}",
            g.types
                .iter()
                .map(|t| ident(t))
                .collect::<Vec<_>>()
                .join(" ")
        ));
    }
    if !g.consts.is_empty() {
        s.push_str(&format!(
            " {{{} : Nat}}",
            g.consts
                .iter()
                .map(|t| ident(t))
                .collect::<Vec<_>>()
                .join(" ")
        ));
    }
    for (t, class) in bounds {
        s.push_str(&format!(" [{class} {}]", ident(t)));
    }
    s
}

/// Lean instance requirements for Rust trait bounds on type parameters.
fn bounds(generics: &[&syn::Generics]) -> Vec<(String, String)> {
    let mut out = vec![];
    let mut add = |t: String, b: &syn::TypeParamBound| {
        if let syn::TypeParamBound::Trait(tb) = b {
            let name = tb.path.segments.last().unwrap().ident.to_string();
            let class = match name.as_str() {
                "PartialEq" | "Eq" => "DecidableEq",
                "Clone" => "Rust.Clone",
                _ => return,
            };
            if !out.iter().any(|(x, c)| *x == t && c == class) {
                out.push((t, class.to_owned()));
            }
        }
    };
    for g in generics {
        for p in &g.params {
            if let syn::GenericParam::Type(tp) = p {
                for b in &tp.bounds {
                    add(tp.ident.to_string(), b);
                }
            }
        }
        if let Some(w) = &g.where_clause {
            for pred in &w.predicates {
                if let syn::WherePredicate::Type(pt) = pred {
                    for b in &pt.bounds {
                        add(tokens(&pt.bounded_ty), b);
                    }
                }
            }
        }
    }
    out
}

/// Whether a type contains a function, which blocks derived equality and printing.
fn has_fn(k: &Krate, t: &Ty, seen: &mut BTreeSet<String>) -> bool {
    match t {
        Ty::Fn(..) => true,
        Ty::Tuple(v) => v.iter().any(|t| has_fn(k, t, seen)),
        Ty::Array(t, _) | Ty::Slice(t) | Ty::Ref(_, t) | Ty::Option(t) | Ty::Iter(t) => {
            has_fn(k, t, seen)
        }
        Ty::Result(a, b) => has_fn(k, a, seen) || has_fn(k, b, seen),
        Ty::Adt(p, a, _) => {
            if a.iter().any(|t| has_fn(k, t, seen)) {
                return true;
            }
            if !seen.insert(p.clone()) {
                return false;
            }
            field_types(k, p)
                .unwrap_or_default()
                .iter()
                .any(|t| has_fn(k, t, seen))
        }
        _ => false,
    }
}

/// The hand-written `PartialEq::eq` of a crate type, if any.
fn manual_eq(k: &Krate, p: &str) -> Option<String> {
    k.functions
        .values()
        .find(|f| {
            f.owner.as_deref() == Some(p)
                && f.name == "eq"
                && f.trait_name.as_deref() == Some("PartialEq")
        })
        .map(|f| f.path.clone())
}

/// Whether a type's Rust equality reaches a hand-written `PartialEq`, so Lean's
/// structural equality is not its meaning.
fn has_manual_eq(k: &Krate, t: &Ty, seen: &mut BTreeSet<String>) -> bool {
    match t {
        Ty::Tuple(v) => v.iter().any(|t| has_manual_eq(k, t, seen)),
        Ty::Array(t, _) | Ty::Slice(t) | Ty::Ref(_, t) | Ty::Option(t) | Ty::Iter(t) => {
            has_manual_eq(k, t, seen)
        }
        Ty::Result(a, b) => has_manual_eq(k, a, seen) || has_manual_eq(k, b, seen),
        Ty::Adt(p, a, _) => {
            if a.iter().any(|t| has_manual_eq(k, t, seen)) {
                return true;
            }
            if !seen.insert(p.clone()) {
                return false;
            }
            manual_eq(k, p).is_some()
                || field_types(k, p)
                    .unwrap_or_default()
                    .iter()
                    .any(|t| has_manual_eq(k, t, seen))
        }
        _ => false,
    }
}

/// Every crate type reachable from `needed` through field types.
fn type_closure(k: &Krate, needed: &BTreeSet<String>) -> R<BTreeSet<String>> {
    let mut all = needed.clone();
    let mut work: Vec<String> = needed.iter().cloned().collect();
    while let Some(p) = work.pop() {
        let mut d = BTreeSet::new();
        for t in field_types(k, &p)? {
            adt_deps(&t, &mut d);
        }
        for q in d {
            if all.insert(q.clone()) {
                work.push(q);
            }
        }
    }
    Ok(all)
}

fn field_types(k: &Krate, p: &str) -> R<Vec<Ty>> {
    let (generics, module, fields): (&syn::Generics, &str, Vec<&syn::Type>) =
        if let Some(s) = k.structs.get(p) {
            (
                &s.generics,
                &s.module,
                s.fields.iter().map(|(_, t)| t).collect(),
            )
        } else if let Some(e) = k.enums.get(p) {
            (
                &e.generics,
                &e.module,
                e.variants
                    .iter()
                    .flat_map(|v| v.fields.iter().map(|(_, t)| t))
                    .collect(),
            )
        } else {
            return Err(format!("unknown type {p}"));
        };
    let mut g = Generics::default();
    g.extend(generics)?;
    let scope = TyScope {
        krate: k,
        module,
        generics: &g,
        self_ty: None,
    };
    fields.into_iter().map(|t| scope.ty(t)).collect()
}

fn adt_deps(t: &Ty, out: &mut BTreeSet<String>) {
    match t {
        Ty::Adt(p, a, _) => {
            out.insert(p.clone());
            for t in a {
                adt_deps(t, out)
            }
        }
        Ty::Tuple(v) => v.iter().for_each(|t| adt_deps(t, out)),
        Ty::Array(t, _) | Ty::Slice(t) | Ty::Ref(_, t) | Ty::Option(t) | Ty::Iter(t) => {
            adt_deps(t, out)
        }
        Ty::Result(a, b) => {
            adt_deps(a, out);
            adt_deps(b, out)
        }
        Ty::Fn(a, r) => {
            a.iter().for_each(|t| adt_deps(t, out));
            adt_deps(r, out)
        }
        _ => {}
    }
}

fn len_deps(t: &Ty, out: &mut BTreeSet<String>) {
    match t {
        Ty::Array(t, l) => {
            if let Len::Const(c) = l {
                out.insert(c.clone());
            }
            len_deps(t, out)
        }
        Ty::Adt(_, a, l) => {
            for l in l {
                if let Len::Const(c) = l {
                    out.insert(c.clone());
                }
            }
            a.iter().for_each(|t| len_deps(t, out))
        }
        Ty::Tuple(v) => v.iter().for_each(|t| len_deps(t, out)),
        Ty::Slice(t) | Ty::Ref(_, t) | Ty::Option(t) | Ty::Iter(t) => len_deps(t, out),
        Ty::Result(a, b) => {
            len_deps(a, out);
            len_deps(b, out)
        }
        _ => {}
    }
}

fn emit_types(
    k: &Krate,
    names: &Names,
    needed: &BTreeSet<String>,
    manual_eqs: &BTreeMap<String, String>,
) -> R<(String, BTreeSet<String>)> {
    // Close over field types.
    let mut all = needed.clone();
    let mut work: Vec<String> = needed.iter().cloned().collect();
    let mut consts = BTreeSet::new();
    let mut deps: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    while let Some(p) = work.pop() {
        let fts = field_types(k, &p)?;
        let mut d = BTreeSet::new();
        for t in &fts {
            adt_deps(t, &mut d);
            len_deps(t, &mut consts);
        }
        d.remove(&p);
        for q in &d {
            if all.insert(q.clone()) {
                work.push(q.clone());
            }
        }
        deps.insert(p, d);
    }
    // Topological order.
    let mut order = vec![];
    let mut done = BTreeSet::new();
    fn visit(
        p: &str,
        deps: &BTreeMap<String, BTreeSet<String>>,
        done: &mut BTreeSet<String>,
        stack: &mut Vec<String>,
        order: &mut Vec<String>,
    ) -> R<()> {
        if done.contains(p) {
            return Ok(());
        }
        if stack.iter().any(|s| s == p) {
            return Err(format!("recursive type {p} is unsupported"));
        }
        stack.push(p.to_owned());
        for q in &deps[p] {
            visit(q, deps, done, stack, order)?;
        }
        stack.pop();
        done.insert(p.to_owned());
        order.push(p.to_owned());
        Ok(())
    }
    for p in deps.keys() {
        visit(p, &deps, &mut done, &mut vec![], &mut order)?;
    }
    let mut out = String::new();
    for p in &order {
        let mut g = Generics::default();
        let (generics, module, derives) = if let Some(s) = k.structs.get(p) {
            (&s.generics, &s.module, &s.derives)
        } else {
            let e = &k.enums[p];
            (&e.generics, &e.module, &e.derives)
        };
        g.extend(generics)?;
        let scope = TyScope {
            krate: k,
            module,
            generics: &g,
            self_ty: None,
        };
        let mut params = String::new();
        if !g.types.is_empty() {
            params.push_str(&format!(
                " ({} : Type)",
                g.types
                    .iter()
                    .map(|t| ident(t))
                    .collect::<Vec<_>>()
                    .join(" ")
            ));
        }
        if !g.consts.is_empty() {
            params.push_str(&format!(
                " ({} : Nat)",
                g.consts
                    .iter()
                    .map(|t| ident(t))
                    .collect::<Vec<_>>()
                    .join(" ")
            ));
        }
        let lean = &names.types[p];
        let self_ty = Ty::Adt(
            p.clone(),
            g.types.iter().map(|t| Ty::Param(t.clone())).collect(),
            g.consts.iter().map(|c| Len::Param(c.clone())).collect(),
        );
        let fns = has_fn(k, &self_ty, &mut BTreeSet::new());
        let mut deriving = vec![];
        // Rust's derived equality is structural unless a field's type has a
        // hand-written `PartialEq`; then it is that equality, field-wise.
        let derived_eq = !fns && derives.iter().any(|d| d.ends_with("PartialEq"));
        let manual_inside = derived_eq && has_manual_eq(k, &self_ty, &mut BTreeSet::new());
        if derived_eq {
            deriving.push(if manual_inside { "BEq" } else { "DecidableEq" });
        }
        if !fns {
            deriving.push("Repr");
        }
        if let Some(s) = k.structs.get(p) {
            out.push_str(&format!(
                "/-- Rust `{p}`. -/\nstructure {lean}{params} where\n"
            ));
            if s.fields.is_empty() {
                out.push_str("  mk ::\n");
            }
            for (n, t) in &s.fields {
                let ty = scope.ty(t)?;
                let field = if s.tuple {
                    format!("f{}", &n[1..])
                } else {
                    ident(n)
                };
                out.push_str(&format!("  {field} : {}\n", names.ty(&ty)));
            }
        } else {
            let e = &k.enums[p];
            out.push_str(&format!(
                "/-- Rust `{p}`. -/\ninductive {lean}{params} where\n"
            ));
            for v in &e.variants {
                out.push_str(&format!("  | {}", ident(&v.name)));
                for (n, t) in &v.fields {
                    let ty = scope.ty(t)?;
                    let field = if v.named {
                        ident(n)
                    } else {
                        format!("f{}", &n[1..])
                    };
                    out.push_str(&format!(" ({field} : {})", names.ty(&ty)));
                }
                out.push('\n');
            }
        }
        if !deriving.is_empty() {
            out.push_str(&format!("  deriving {}\n", deriving.join(", ")));
        }
        out.push('\n');
        if derives.iter().any(|d| d.ends_with("Clone")) {
            out.push_str(&clone_instances(k, names, p, &g, &scope, &self_ty)?);
        }
        // A generic type's derived equality at arguments that only have Rust's
        // `==` (a hand-written `PartialEq` inside): field-wise, below the
        // decidable equality used whenever the arguments have one.
        if derived_eq && !manual_inside && !g.types.is_empty() {
            out.push_str(&structural_beq(k, names, p, &g, &self_ty)?);
        }
        // A hand-written `PartialEq`: its translated `eq` is the type's `==`.
        if let Some(eq) = manual_eqs.get(p) {
            out.push_str(eq);
            out.push_str(&format!(
                "instance{} : BEq {} := ⟨{}.eq⟩\n\n",
                generic_binders(&g, &[]),
                paren_ty(&names.ty(&self_ty)),
                lean
            ));
        }
        // A derived `Default`: every field's default value.
        if derives.iter().any(|d| d.ends_with("Default")) {
            let s = k
                .structs
                .get(p)
                .ok_or_else(|| format!("derived Default on enum {p}"))?;
            let mut fields = vec![];
            for (n, t) in &s.fields {
                let ty = scope.ty(t)?;
                fields.push(format!("{} := {}", ident(n), default_value(names, &ty)?));
            }
            out.push_str(&format!(
                "/-- Derived `Default` for `{p}`. -/\ndef {lean}.default{} : {} :=\n  {{ {} }}\n\n",
                generic_binders(&g, &[]),
                names.ty(&self_ty),
                fields.join(", ")
            ));
        }
    }
    Ok((out, consts))
}

/// A low-priority field-wise `BEq`, as Rust derives `PartialEq`.
fn structural_beq(k: &Krate, names: &Names, p: &str, g: &Generics, self_ty: &Ty) -> R<String> {
    let lean = &names.types[p];
    let beqs = g
        .types
        .iter()
        .map(|t| (t.clone(), "BEq".to_owned()))
        .collect::<Vec<_>>();
    let mut out = format!(
        "/-- Derived `PartialEq` for `{p}` at arguments with only `==`. -/\ninstance (priority := low){} : BEq {} where\n",
        generic_binders(g, &beqs),
        paren_ty(&names.ty(self_ty))
    );
    let all = |n: usize, a: &str, b: &str| {
        if n == 0 {
            "true".to_owned()
        } else {
            (0..n)
                .map(|i| format!("{a}{i} == {b}{i}"))
                .collect::<Vec<_>>()
                .join(" && ")
        }
    };
    if let Some(s) = k.structs.get(p) {
        let fields: Vec<String> = s
            .fields
            .iter()
            .map(|(n, _)| {
                if s.tuple {
                    format!("f{}", &n[1..])
                } else {
                    ident(n)
                }
            })
            .collect();
        let body = if fields.is_empty() {
            "true".to_owned()
        } else {
            fields
                .iter()
                .map(|f| format!("a.{f} == b.{f}"))
                .collect::<Vec<_>>()
                .join(" && ")
        };
        out.push_str(&format!("  beq a b := {body}\n\n"));
        return Ok(out);
    }
    let e = &k.enums[p];
    out.push_str("  beq\n");
    for v in &e.variants {
        let c = format!("{lean}.{}", ident(&v.name));
        let n = v.fields.len();
        let xs = |x: &str| (0..n).map(|i| format!(" {x}{i}")).collect::<String>();
        out.push_str(&format!(
            "    | {c}{}, {c}{} => {}\n",
            xs("a"),
            xs("b"),
            all(n, "a", "b")
        ));
    }
    if e.variants.len() > 1 {
        out.push_str("    | _, _ => false\n");
    }
    out.push('\n');
    Ok(out)
}

/// Instances for a derived `Clone`. Without type parameters it copies; with
/// them, each field that reaches a parameter is cloned with the consumer's
/// `Clone`, and the instance is lawful when the parameters' instances are.
fn clone_instances(
    k: &Krate,
    names: &Names,
    p: &str,
    g: &Generics,
    scope: &TyScope,
    self_ty: &Ty,
) -> R<String> {
    let t = paren_ty(&names.ty(self_ty));
    if g.types.is_empty() {
        let b = generic_binders(g, &[]);
        return Ok(format!(
            "instance{b} : Rust.Clone {t} := ⟨pure⟩\ninstance{b} : Rust.LawfulClone {t} := ⟨Rust.pure_clone_eq⟩\n\n"
        ));
    }
    let lean = &names.types[p];
    let class = |classes: &[&str]| {
        g.types
            .iter()
            .flat_map(|t| classes.iter().map(|c| (t.clone(), (*c).to_owned())))
            .collect::<Vec<_>>()
    };
    let field = |v: String, t: &Ty| {
        if t.has_param() {
            format!("(← Rust.Clone.clone {v})")
        } else {
            v
        }
    };
    let mut out = format!(
        "/-- Derived `Clone` for `{p}`. -/\ninstance{} : Rust.Clone {t} where\n",
        generic_binders(g, &class(&["Rust.Clone"]))
    );
    if let Some(s) = k.structs.get(p) {
        let mut fields = vec![];
        for (n, ft) in &s.fields {
            let f = if s.tuple {
                format!("f{}", &n[1..])
            } else {
                ident(n)
            };
            fields.push(format!(
                "{f} := {}",
                field(format!("x.{f}"), &scope.ty(ft)?)
            ));
        }
        out.push_str(&format!(
            "  clone x := do pure {{ {} }}\n",
            fields.join(", ")
        ));
    } else {
        out.push_str("  clone\n");
        for v in &k.enums[p].variants {
            let c = format!("{lean}.{}", ident(&v.name));
            if v.fields.is_empty() {
                out.push_str(&format!("    | {c} => pure {c}\n"));
                continue;
            }
            let mut binds = vec![];
            let mut args = vec![];
            for (i, (_, ft)) in v.fields.iter().enumerate() {
                let b = format!("a{i}");
                args.push(field(b.clone(), &scope.ty(ft)?));
                binds.push(b);
            }
            out.push_str(&format!(
                "    | {c} {} => do pure ({c} {})\n",
                binds.join(" "),
                args.join(" ")
            ));
        }
    }
    out.push_str(&format!(
        "\ninstance{} : Rust.LawfulClone {t} := ⟨by rust_lawful_clone⟩\n\n",
        generic_binders(g, &class(&["Rust.Clone", "Rust.LawfulClone"]))
    ));
    Ok(out)
}

fn default_value(names: &Names, t: &Ty) -> R<String> {
    Ok(match t {
        Ty::Uint(..) => "0".into(),
        Ty::Bool => "false".into(),
        Ty::Option(_) => "none".into(),
        Ty::Unit => "()".into(),
        Ty::Adt(p, ..) => format!("{}.default", names.types[p]),
        Ty::Array(t, l) => format!(
            "Vector.replicate {} {}",
            names.len(l),
            default_value(names, t)?
        ),
        Ty::Tuple(v) => format!(
            "({})",
            v.iter()
                .map(|t| default_value(names, t))
                .collect::<R<Vec<_>>>()?
                .join(", ")
        ),
        _ => return Err(format!("no derived default for {t:?}")),
    })
}

/// Translate one function under the current purity assumptions.
fn emit_function(cx: &Ctx, f: &Function) -> R<Emitted> {
    let generics = function_generics(f)?;
    let self_ty = match &f.self_ty {
        Some(t) => {
            let mut g = Generics::default();
            g.extend(&f.impl_generics)?;
            let scope = TyScope {
                krate: cx.k,
                module: &f.module,
                generics: &g,
                self_ty: None,
            };
            Some(scope.ty(t)?)
        }
        None => None,
    };
    let scope = TyScope {
        krate: cx.k,
        module: &f.module,
        generics: &generics,
        self_ty: self_ty.as_ref(),
    };
    let ret = match &f.sig.output {
        syn::ReturnType::Default => Ty::Unit,
        syn::ReturnType::Type(_, t) => scope.ty(t)?,
    };
    if let Ty::Ref(true, _) = ret {
        return Err(format!(
            "{}: functions returning &mut are unsupported",
            f.path
        ));
    }
    let mut body = Body::new(
        cx,
        &f.module,
        generics.clone(),
        self_ty.clone(),
        ret.clone(),
    );
    // Reserve every identifier of the body, so temporaries never capture one.
    let mut idents = BTreeSet::new();
    collect_idents(&f.block, &mut idents);
    body.reserve(
        idents
            .iter()
            .filter(|s| s.starts_with('t') || s.starts_with('r') || s.starts_with('m'))
            .cloned(),
    );
    let mut names = idents.clone();
    for input in &f.sig.inputs {
        match input {
            syn::FnArg::Receiver(_) => {
                names.insert("self".to_owned());
            }
            syn::FnArg::Typed(t) => {
                if let syn::Pat::Ident(pi) = &*t.pat {
                    names.insert(pi.ident.to_string());
                }
            }
        }
    }
    body.set_source_names(names);
    let mut params = vec![];
    let mut lent_param = None;
    let mut prologue = vec![];
    let mut out_tys = vec![];
    for input in &f.sig.inputs {
        let (rust, ty, by_mut_pat) = match input {
            syn::FnArg::Receiver(r) => {
                let st = self_ty.clone().ok_or("receiver outside impl")?;
                let ty = if r.reference.is_some() {
                    Ty::Ref(r.mutability.is_some(), Box::new(st))
                } else {
                    st
                };
                (
                    "self".to_owned(),
                    ty,
                    r.reference.is_none() && r.mutability.is_some(),
                )
            }
            syn::FnArg::Typed(t) => {
                let ty = scope.ty(&t.ty)?.param_iter();
                match &*t.pat {
                    syn::Pat::Ident(pi) => (pi.ident.to_string(), ty, pi.mutability.is_some()),
                    syn::Pat::Wild(_) => ("_".to_owned(), ty, false),
                    p => {
                        return Err(format!(
                            "{}: unsupported parameter pattern {}",
                            f.path,
                            tokens(p)
                        ))
                    }
                }
            }
        };
        let lean = body.fresh(&rust);
        // A `&mut` argument lent to a returned borrowing struct is not returned.
        let lent = ty.mut_ref() && body.returns_borrow(&ret);
        let output = !lent
            && (ty.mut_ref()
                || (ty.peel().holds_mut_borrow(cx.k) && !matches!(ty, Ty::Ref(false, _))));
        let mutable = output || by_mut_pat;
        params.push(format!("({lean} : {})", cx.names.ty(&ty)));
        if mutable {
            prologue.push(format!("let mut {lean} := {lean}"));
        }
        let id = body.declare(&rust, Body::local(lean.clone(), ty.peel().clone(), mutable));
        if lent {
            lent_param = Some(id);
        }
        if output {
            body.outputs.push(id);
            out_tys.push(ty.peel().clone());
        }
    }
    let mut rets = vec![];
    if !ret.is_unit() {
        rets.push(cx.names.ty(&ret));
    }
    rets.extend(out_tys.iter().map(|t| cx.names.ty(t)));
    let ret_lean = match rets.len() {
        0 => "Unit".to_owned(),
        1 => rets[0].clone(),
        _ => format!("({})", rets.join(" × ")),
    };
    body.body(&f.block)
        .map_err(|e| format!("{}: {e}", f.path))?;
    let mut lines = std::mem::take(&mut body.out);
    body.finish_lines(&mut lines)
        .map_err(|e| format!("{}: {e}", f.path))?;
    let impure = body.impure;
    // A borrow of the lent receiver still pending at the end is the result's.
    let lent = match &body.pending_borrow {
        Some((_, place)) if lent_param.is_some_and(|id| id == place.root) => Some(
            place
                .projs
                .iter()
                .map(|p| match p {
                    super::emit::Proj::Field(f) => Ok(f.clone()),
                    other => Err(format!(
                        "{}: returned borrow of a non-field projection {other:?}",
                        f.path
                    )),
                })
                .collect::<R<Vec<_>>>()?,
        ),
        _ => None,
    };
    let name = &cx.names.functions[&f.path];
    let ib = bounds(&[&f.impl_generics, &f.sig.generics]);
    let sig = format!(
        "def {name}{} {} : {}",
        generic_binders(&generics, &ib),
        params.join(" "),
        if impure {
            format!("Rust.M {}", paren_ty(&ret_lean))
        } else {
            ret_lean.clone()
        }
    );
    let mut text = format!(
        "/-- Rust `{}`. -/\n{}",
        f.path.split('#').next().unwrap(),
        sig.replace("  :", " :")
    );
    let only_pure = prologue.is_empty()
        && lines.len() == 1
        && lines[0].0 == 0
        && lines[0].1.starts_with("pure ");
    if only_pure && !impure {
        text.push_str(&format!(" :=\n  {}\n", &lines[0].1[5..]));
    } else {
        text.push_str(if impure {
            " := do\n"
        } else {
            " := Id.run do\n"
        });
        for l in &prologue {
            text.push_str(&format!("  {l}\n"));
        }
        for (i, l) in &lines {
            text.push_str(&" ".repeat(2 + i));
            text.push_str(l);
            text.push('\n');
        }
    }
    text.push('\n');
    let facts = Facts {
        calls: body.calls.clone(),
        locals: body
            .declared
            .iter()
            .map(|(n, id)| (n.clone(), body.resolve(&body.locals[*id].ty)))
            .collect(),
    };
    Ok(Emitted {
        text,
        calls: body.calls.clone(),
        impure,
        lent,
        facts,
    })
}

fn paren_ty(t: &str) -> String {
    if t.starts_with('(') || !t.contains(' ') {
        t.to_owned()
    } else {
        format!("({t})")
    }
}

fn collect_idents(b: &syn::Block, out: &mut BTreeSet<String>) {
    struct V<'a>(&'a mut BTreeSet<String>);
    impl<'ast> syn::visit::Visit<'ast> for V<'_> {
        fn visit_ident(&mut self, i: &'ast proc_macro2::Ident) {
            self.0.insert(i.to_string());
        }
    }
    syn::visit::Visit::visit_block(&mut V(out), b);
}

/// Generate the Lean module for `roots` and everything they reach.
pub fn generate(k: &Krate, roots: &[String], opts: &Options) -> R<Generated> {
    let names = Names::new(k);
    for r in roots {
        if !k.functions.contains_key(r) {
            return Err(format!("unknown root function {r}"));
        }
    }
    let mut roots: Vec<String> = roots.to_vec();
    let mut lent_fields: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut pure: BTreeSet<String> = k.functions.keys().cloned().collect();
    let mut emitted: BTreeMap<String, Emitted>;
    let mut needed;
    let mut manual: BTreeMap<String, String>;
    loop {
        loop {
            let cx = Ctx {
                k,
                names: &names,
                pure_fns: &pure,
                overflow_checks: opts.overflow_checks,
                debug_assertions: opts.debug_assertions,
                lent_fields: &lent_fields,
            };
            emitted = BTreeMap::new();
            let mut work: Vec<String> = roots.clone();
            while let Some(p) = work.pop() {
                if emitted.contains_key(&p) {
                    continue;
                }
                let e = emit_function(&cx, &k.functions[&p])?;
                for c in &e.calls {
                    if !emitted.contains_key(c) {
                        work.push(c.clone());
                    }
                }
                emitted.insert(p, e);
            }
            let before = pure.len();
            for (p, e) in &emitted {
                if e.impure {
                    pure.remove(p);
                }
            }
            let lent: BTreeMap<String, Vec<String>> = emitted
                .iter()
                .filter_map(|(p, e)| e.lent.clone().map(|l| (p.clone(), l)))
                .collect();
            let lent_changed = lent != lent_fields;
            lent_fields = lent;
            if pure.len() == before && !lent_changed {
                break;
            }
        }
        // Types: everything named in the translated functions' signatures and
        // bodies. A needed type's hand-written `eq` is translated too.
        needed = BTreeSet::new();
        for e in emitted.values() {
            for (path, lean) in &names.types {
                if mentions(&e.text, lean) {
                    needed.insert(path.clone());
                }
            }
        }
        manual = BTreeMap::new();
        for t in type_closure(k, &needed)? {
            if let Some(f) = manual_eq(k, &t) {
                manual.insert(t, f);
            }
        }
        let missing: Vec<String> = manual
            .values()
            .filter(|f| !roots.contains(f))
            .cloned()
            .collect();
        if missing.is_empty() {
            break;
        }
        roots.extend(missing);
    }
    // Functions in call order.
    let mut order = vec![];
    let mut done = BTreeSet::new();
    fn visit(
        p: &str,
        emitted: &BTreeMap<String, Emitted>,
        done: &mut BTreeSet<String>,
        stack: &mut Vec<String>,
        order: &mut Vec<String>,
    ) -> R<()> {
        if done.contains(p) {
            return Ok(());
        }
        if stack.iter().any(|s| s == p) {
            return Err(format!("recursive function {p} is unsupported"));
        }
        stack.push(p.to_owned());
        for c in &emitted[p].calls {
            visit(c, emitted, done, stack, order)?;
        }
        stack.pop();
        done.insert(p.to_owned());
        order.push(p.to_owned());
        Ok(())
    }
    for p in emitted.keys() {
        visit(p, &emitted, &mut done, &mut vec![], &mut order)?;
    }
    // A hand-written `eq` is placed after its type, so later types can derive
    // equality from it; it may call no other crate function.
    let mut eq_texts = BTreeMap::new();
    for (t, f) in &manual {
        let e = &emitted[f];
        if !e.calls.is_empty() || e.impure {
            return Err(format!(
                "{f}: a hand-written PartialEq must be pure and call no crate function"
            ));
        }
        eq_texts.insert(t.clone(), e.text.clone());
    }
    order.retain(|p| !manual.values().any(|f| f == p));
    let (types, mut consts) = emit_types(k, &names, &needed, &eq_texts)?;
    for p in &order {
        for (path, lean) in &names.consts {
            if mentions(&emitted[p].text, lean) {
                consts.insert(path.clone());
            }
        }
    }
    let mut out = String::new();
    out.push_str(&format!(
        "/-\nGenerated by Provium's typed backend. Do not edit.\n-/\nimport Provium.Rust\n\nset_option linter.unusedVariables false\nset_option maxHeartbeats 1000000\n\nnamespace {}\n\n",
        opts.namespace
    ));
    for c in &consts {
        let k_ = &k.consts[c];
        let scope = TyScope {
            krate: k,
            module: &k_.module,
            generics: &Generics::default(),
            self_ty: None,
        };
        let ty = scope.ty(&k_.ty)?;
        let syn::Expr::Lit(syn::ExprLit {
            lit: syn::Lit::Int(i),
            ..
        }) = &k_.expr
        else {
            return Err(format!("constant {c} must be an integer literal"));
        };
        let lean = &names.consts[c];
        if ty == Ty::usize() {
            out.push_str(&format!("/-- Rust `{c}` (a `usize`, also used as an array length). -/\ndef {lean} : Nat := {}\n\n", i.base10_digits()));
        } else {
            out.push_str(&format!(
                "/-- Rust `{c}`. -/\ndef {lean} : {} := {}\n\n",
                names.ty(&ty),
                i.base10_digits()
            ));
        }
    }
    out.push_str(&types);
    for p in &order {
        out.push_str(&emitted[p].text);
    }
    out.push_str(&format!("end {}\n", opts.namespace));
    Ok(Generated {
        facts: emitted
            .iter()
            .map(|(p, e)| (p.clone(), e.facts.clone()))
            .collect(),
        lean: out,
        functions: order
            .iter()
            .map(|p| (p.clone(), names.functions[p].clone()))
            .collect(),
        pure: pure
            .into_iter()
            .filter(|p| emitted.contains_key(p))
            .collect(),
    })
}

fn mentions(text: &str, name: &str) -> bool {
    let bytes = text.as_bytes();
    let mut start = 0;
    while let Some(i) = text[start..].find(name) {
        let a = start + i;
        let b = a + name.len();
        let before = a == 0
            || !(bytes[a - 1].is_ascii_alphanumeric()
                || bytes[a - 1] == b'_'
                || bytes[a - 1] == b'.');
        let after = b >= bytes.len() || !(bytes[b].is_ascii_alphanumeric() || bytes[b] == b'_');
        if before && after {
            return true;
        }
        start = b;
    }
    false
}
