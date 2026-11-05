//! Translation of Rust function bodies into Lean `do` blocks.
//!
//! Locals become Lean locals (`let mut` when Rust mutates them). A `&mut`
//! borrow becomes a local copy plus the place it borrows: every write to the
//! copy is written through to that place at once. Rust's borrow checker
//! guarantees the place is not otherwise used while the borrow lives, so the
//! eager write-through observes exactly what the borrow's owner would.
//! Functions take `&mut` arguments by value and return their final values.
use super::lean::{ident, Names};
use super::load::{tokens, Function, Krate};
use super::types::{Generics, Len, Scope as TyScope, Ty};
use std::collections::{BTreeMap, BTreeSet};
use syn::{Expr, Pat, Stmt};

pub type R<T> = Result<T, String>;
/// Emitted do-block lines with their relative indentation.
pub type Lines = Vec<(usize, String)>;
/// A constructor: its Lean name, whether it is a structure, and its fields.
pub type Ctor = (String, bool, Vec<(String, Ty)>);

/// Crate-wide facts shared by every body.
pub struct Ctx<'a> {
    pub k: &'a Krate,
    pub names: &'a Names,
    /// Crate functions currently believed pure (no panic or divergence).
    pub pure_fns: &'a BTreeSet<String>,
    pub overflow_checks: bool,
    pub debug_assertions: bool,
    /// For a function returning a struct that borrows its `&mut` receiver:
    /// the fields of the receiver the struct borrows (empty: the receiver).
    pub lent_fields: &'a BTreeMap<String, Vec<String>>,
}

#[derive(Clone, Debug)]
pub enum Proj {
    Field(String),
    Tuple(usize, usize),
    Index(String),
    Range(String, String),
    Some_,
}

#[derive(Clone, Debug)]
pub struct Place {
    pub root: usize,
    pub projs: Vec<Proj>,
    pub ty: Ty,
}

#[derive(Clone, Debug)]
pub struct Local {
    pub lean: String,
    pub ty: Ty,
    pub mutable: bool,
    /// The place this local's value is written through to.
    pub alias: Option<Place>,
    /// Fields of this local that are borrows of other places.
    pub field_aliases: Vec<(String, Place)>,
    /// For closures bound to locals: whether calling them is pure.
    pub pure_fn: Option<bool>,
    /// A `Drop` implementation to run when the local goes out of scope.
    pub drop: Option<String>,
    /// The local is itself a `&mut` borrow (matching it binds by reference).
    pub mut_ref: bool,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ScopeKind {
    Block,
    Loop,
    Function,
    Closure,
}

struct Scope {
    kind: ScopeKind,
    names: Vec<(String, usize)>,
    drops: Vec<usize>,
}

/// A translated expression: its Lean term (`None` when control never reaches
/// the end of the expression) and Rust type.
#[derive(Clone, Debug)]
pub struct V {
    pub term: Option<String>,
    pub ty: Ty,
}

impl V {
    fn of(term: impl Into<String>, ty: Ty) -> V {
        V {
            term: Some(term.into()),
            ty,
        }
    }
    fn never() -> V {
        V {
            term: None,
            ty: Ty::Never,
        }
    }
}

pub struct Body<'a> {
    pub cx: &'a Ctx<'a>,
    pub module: String,
    pub generics: Generics,
    pub self_ty: Option<Ty>,
    pub locals: Vec<Local>,
    scopes: Vec<Scope>,
    used: BTreeSet<String>,
    source_idents: BTreeSet<String>,
    /// Every identifier of the source body, to tell its locals from temporaries.
    source_names: BTreeSet<String>,
    /// Source-named locals as declared, for the rustc cross-check.
    pub declared: Vec<(String, usize)>,
    /// Trait implementations a call needs, by their methods: translated and
    /// ordered first, but not calls rustc would show.
    pub instance_deps: BTreeSet<String>,
    /// Whether this is an `async fn`: results are `Rust.Run.ready`.
    pub async_fn: bool,
    /// Whether the expression being translated is the operand of `.await`.
    pub awaiting: bool,
    pub out: Lines,
    pub(super) indent: usize,
    pub impure: bool,
    /// Locals returned alongside the result: the function's `&mut` parameters.
    pub outputs: Vec<usize>,
    pub ret_ty: Ty,
    closure_rets: Vec<Ty>,
    pub calls: BTreeSet<String>,
    tmp: usize,
    int_vars: BTreeMap<usize, Ty>,
    next_var: usize,
    pub last_closure_pure: std::cell::Cell<Option<bool>>,
    /// The result of the latest call returning a struct that borrows a place,
    /// with that place: a binding of the result writes through to it.
    pub pending_borrow: Option<(String, Place)>,
    /// While translating arms of a match on such a result: the borrowed place.
    result_borrow: Option<Place>,
    /// Iterator terms produced by a stage whose closure may panic.
    pub effectful_iters: BTreeSet<String>,
}

fn paren(s: &str) -> String {
    let simple = s
        .chars()
        .all(|c| c.is_alphanumeric() || c == '_' || c == '.' || c == '«' || c == '»' || c == '\'');
    if simple || (s.starts_with('(') && balanced_outer(s)) {
        s.to_owned()
    } else {
        format!("({s})")
    }
}

fn balanced_outer(s: &str) -> bool {
    let mut depth = 0i32;
    for (i, c) in s.char_indices() {
        match c {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if depth == 0 && i != s.len() - 1 {
                    return false;
                }
            }
            _ => {}
        }
    }
    depth == 0 && s.ends_with(')')
}

fn path_names(p: &syn::Path) -> Vec<String> {
    p.segments.iter().map(|s| s.ident.to_string()).collect()
}

impl<'a> Body<'a> {
    pub fn new(
        cx: &'a Ctx<'a>,
        module: &str,
        generics: Generics,
        self_ty: Option<Ty>,
        ret_ty: Ty,
    ) -> Self {
        Body {
            cx,
            module: module.to_owned(),
            generics,
            self_ty,
            locals: vec![],
            scopes: vec![Scope {
                kind: ScopeKind::Function,
                names: vec![],
                drops: vec![],
            }],
            used: BTreeSet::new(),
            source_idents: BTreeSet::new(),
            source_names: BTreeSet::new(),
            declared: Vec::new(),
            instance_deps: BTreeSet::new(),
            async_fn: false,
            awaiting: false,
            out: vec![],
            indent: 0,
            impure: false,
            outputs: vec![],
            ret_ty,
            closure_rets: vec![],
            calls: BTreeSet::new(),
            tmp: 0,
            int_vars: BTreeMap::new(),
            next_var: 0,
            last_closure_pure: std::cell::Cell::new(None),
            pending_borrow: None,
            result_borrow: None,
            effectful_iters: BTreeSet::new(),
        }
    }

    pub(super) fn tys(&self) -> TyScope<'_> {
        TyScope {
            krate: self.cx.k,
            module: &self.module,
            generics: &self.generics,
            self_ty: self.self_ty.as_ref(),
        }
    }

    pub fn emit(&mut self, line: impl Into<String>) {
        self.out.push((self.indent, line.into()));
    }

    /// Run `f` with output captured into a separate buffer.
    fn capture<T>(&mut self, f: impl FnOnce(&mut Self) -> R<T>) -> R<(T, Lines)> {
        let saved = std::mem::take(&mut self.out);
        let indent = std::mem::replace(&mut self.indent, 0);
        let r = f(self);
        let lines = std::mem::replace(&mut self.out, saved);
        self.indent = indent;
        Ok((r?, lines))
    }

    fn splice(&mut self, lines: Lines, extra: usize) {
        for (i, l) in lines {
            self.out.push((self.indent + extra + i, l));
        }
    }

    /// A fresh Lean name based on a Rust name, never reused in this body.
    pub fn fresh(&mut self, base: &str) -> String {
        let base = if base.is_empty() { "t" } else { base };
        let mut name = ident(base);
        let mut i = 1;
        while self.used.contains(&name) {
            name = ident(&format!("{base}_{i}"));
            i += 1;
        }
        self.used.insert(name.clone());
        name
    }

    fn temp(&mut self) -> String {
        loop {
            self.tmp += 1;
            let t = format!("t{}", self.tmp);
            if !self.used.contains(&t) && !self.source_idents.contains(&t) {
                self.used.insert(t.clone());
                return t;
            }
        }
    }

    /// A fresh name for a value the translation introduces, avoiding every
    /// identifier of the Rust body (which may name functions in scope).
    pub fn synthetic(&mut self, base: &str) -> String {
        let mut name = base.to_owned();
        let mut i = 1;
        while self.used.contains(&name) || self.source_idents.contains(&name) {
            name = format!("{base}_{i}");
            i += 1;
        }
        self.used.insert(name.clone());
        name
    }

    /// Names temporaries must avoid: every identifier of the Rust body.
    pub fn reserve(&mut self, names: impl IntoIterator<Item = String>) {
        self.source_idents.extend(names);
    }

    /// The identifiers the source body uses.
    pub fn set_source_names(&mut self, names: BTreeSet<String>) {
        self.source_names = names;
    }

    pub fn declare(&mut self, rust: &str, local: Local) -> usize {
        let id = self.locals.len();
        if local.drop.is_some() {
            self.scopes.last_mut().unwrap().drops.push(id);
        }
        if self.source_names.contains(rust) {
            self.declared.push((rust.to_owned(), id));
        }
        self.locals.push(local);
        self.scopes
            .last_mut()
            .unwrap()
            .names
            .push((rust.to_owned(), id));
        id
    }

    pub fn local(lean: String, ty: Ty, mutable: bool) -> Local {
        Local {
            lean,
            ty,
            mutable,
            alias: None,
            field_aliases: vec![],
            pure_fn: None,
            drop: None,
            mut_ref: false,
        }
    }

    pub(super) fn lookup(&self, rust: &str) -> Option<usize> {
        for s in self.scopes.iter().rev() {
            if let Some((_, id)) = s.names.iter().rev().find(|(n, _)| n == rust) {
                return Some(*id);
            }
        }
        None
    }

    /// Whether a local was declared outside the innermost closure.
    fn captured(&self, id: usize) -> bool {
        let mut inside = true;
        for s in self.scopes.iter().rev() {
            if s.names.iter().any(|(_, i)| *i == id) {
                return !inside;
            }
            if s.kind == ScopeKind::Closure {
                inside = false;
            }
        }
        false
    }

    pub(super) fn drop_scope(&mut self) {
        self.scopes.pop();
    }

    pub(super) fn push_scope(&mut self, kind: ScopeKind) {
        self.scopes.push(Scope {
            kind,
            names: vec![],
            drops: vec![],
        });
    }

    /// Leave a scope normally, running its locals' destructors.
    fn pop_scope(&mut self, reachable: bool) -> R<()> {
        if reachable {
            let drops = self.scopes.last().unwrap().drops.clone();
            for id in drops.into_iter().rev() {
                self.run_drop(id)?;
            }
        }
        self.scopes.pop();
        Ok(())
    }

    /// Run destructors of every scope exited by a jump to the nearest scope of `kind`.
    /// Locals whose destructors would run on leaving the function now.
    pub(super) fn pending_drops(&self) -> Vec<usize> {
        self.scopes
            .iter()
            .flat_map(|s| s.drops.iter().copied())
            .collect()
    }

    fn unwind_to(&mut self, kinds: &[ScopeKind]) -> R<()> {
        let mut ids = vec![];
        for s in self.scopes.iter().rev() {
            ids.extend(s.drops.iter().rev().copied());
            if kinds.contains(&s.kind) {
                break;
            }
        }
        for id in ids {
            self.run_drop(id)?;
        }
        Ok(())
    }

    // ---------------------------------------------------------------- types

    pub fn resolve(&self, t: &Ty) -> Ty {
        match t {
            // Follow the whole chain of unified literal variables.
            Ty::IntVar(v) => match self.int_vars.get(v) {
                Some(t) => self.resolve(t),
                None => Ty::IntVar(*v),
            },
            Ty::Ref(m, t) => Ty::Ref(*m, Box::new(self.resolve(t))),
            Ty::Tuple(v) => Ty::Tuple(v.iter().map(|t| self.resolve(t)).collect()),
            Ty::Option(t) => Ty::Option(Box::new(self.resolve(t))),
            Ty::Array(t, l) => Ty::Array(Box::new(self.resolve(t)), l.clone()),
            Ty::Slice(t) => Ty::Slice(Box::new(self.resolve(t))),
            Ty::Iter(t) => Ty::Iter(Box::new(self.resolve(t))),
            t => t.clone(),
        }
    }

    /// Record that two types are equal, fixing integer literal variables.
    pub(super) fn unify(&mut self, a: &Ty, b: &Ty) {
        let (a, b) = (self.resolve(a), self.resolve(b));
        match (a.peel(), b.peel()) {
            (Ty::IntVar(v), t @ (Ty::Uint(..) | Ty::Int(..)))
            | (t @ (Ty::Uint(..) | Ty::Int(..)), Ty::IntVar(v)) => {
                self.int_vars.insert(*v, t.clone());
            }
            (Ty::IntVar(v), Ty::IntVar(w)) if v != w => {
                self.int_vars.insert(*v, Ty::IntVar(*w));
            }
            (Ty::Option(x), Ty::Option(y))
            | (Ty::Iter(x), Ty::Iter(y))
            | (Ty::Array(x, _), Ty::Array(y, _)) => {
                let (x, y) = ((**x).clone(), (**y).clone());
                self.unify(&x, &y)
            }
            (Ty::Tuple(x), Ty::Tuple(y)) if x.len() == y.len() => {
                for (x, y) in x.clone().iter().zip(y.clone().iter()) {
                    self.unify(x, y)
                }
            }
            _ => {}
        }
    }

    fn int_var(&mut self) -> Ty {
        self.next_var += 1;
        Ty::IntVar(self.next_var)
    }

    /// The Lean type of a Rust type, with a placeholder for unresolved literals.
    pub fn lean_ty(&self, t: &Ty) -> String {
        fn mark(t: &Ty) -> Ty {
            match t {
                Ty::IntVar(v) => Ty::Param(format!("⁇INT{v}⁇")),
                Ty::Ref(m, t) => Ty::Ref(*m, Box::new(mark(t))),
                Ty::Tuple(v) => Ty::Tuple(v.iter().map(mark).collect()),
                Ty::Option(t) => Ty::Option(Box::new(mark(t))),
                Ty::Array(t, l) => Ty::Array(Box::new(mark(t)), l.clone()),
                Ty::Slice(t) => Ty::Slice(Box::new(mark(t))),
                Ty::Iter(t) => Ty::Iter(Box::new(mark(t))),
                t => t.clone(),
            }
        }
        self.cx.names.ty(&mark(&self.resolve(t)))
    }

    /// Replace integer literal types with fresh variables fixed by later uses.
    fn fresh_lits(&mut self, t: &Ty) -> Ty {
        match t {
            Ty::IntLit => self.int_var(),
            Ty::Tuple(v) => Ty::Tuple(v.iter().map(|t| self.fresh_lits(t)).collect()),
            Ty::Option(t) => Ty::Option(Box::new(self.fresh_lits(t))),
            Ty::Array(t, l) => Ty::Array(Box::new(self.fresh_lits(t)), l.clone()),
            Ty::Slice(t) => Ty::Slice(Box::new(self.fresh_lits(t))),
            Ty::Iter(t) => Ty::Iter(Box::new(self.fresh_lits(t))),
            t => t.clone(),
        }
    }

    fn has_int_var(&self, t: &Ty) -> bool {
        match self.resolve(t) {
            Ty::IntVar(_) => true,
            Ty::Tuple(v) => v.iter().any(|t| self.has_int_var(t)),
            Ty::Option(t) | Ty::Array(t, _) | Ty::Slice(t) | Ty::Iter(t) | Ty::Ref(_, t) => {
                self.has_int_var(&t)
            }
            _ => false,
        }
    }

    /// Replace resolved literal placeholders in the emitted lines.
    pub fn finish_lines(&self, lines: &mut [(usize, String)]) -> R<()> {
        for (_, l) in lines.iter_mut() {
            while let Some(start) = l.find("⁇INT") {
                let body = start + "⁇INT".len();
                let end = body + l[body..].find('⁇').unwrap();
                let v: usize = l[body..end].parse().unwrap();
                let end = end + '⁇'.len_utf8() - 1;
                let t = match self.resolve(&Ty::IntVar(v)) {
                    // Rust's fallback type for an otherwise unconstrained literal.
                    Ty::IntVar(_) => "Rust.i32".to_owned(),
                    t => self.cx.names.ty(&t),
                };
                l.replace_range(start..=end, &t);
            }
            while let Some(start) = l.find("⁇S") {
                let body = start + "⁇S".len();
                let end = body + l[body..].find('⁇').unwrap();
                let v: usize = l[body..end].parse().unwrap();
                let end = end + '⁇'.len_utf8() - 1;
                let signed = matches!(self.resolve(&Ty::IntVar(v)), Ty::IntVar(_) | Ty::Int(..));
                l.replace_range(start..=end, if signed { "i" } else { "" });
            }
        }
        Ok(())
    }

    pub(super) fn field_ty(&self, ty: &Ty, field: &str) -> R<(String, Ty)> {
        match self.resolve(ty).peel() {
            Ty::Adt(p, tys, lens) => {
                let s = self
                    .cx
                    .k
                    .structs
                    .get(p)
                    .ok_or_else(|| format!("field {field} of non-struct {p}"))?;
                let (_, fty) = s
                    .fields
                    .iter()
                    .find(|(n, _)| n == field)
                    .ok_or_else(|| format!("no field {field} on {p}"))?;
                let mut g = Generics::default();
                g.extend(&s.generics)?;
                let scope = TyScope {
                    krate: self.cx.k,
                    module: &s.module,
                    generics: &g,
                    self_ty: None,
                };
                let raw = scope.ty(fty)?;
                let sub_t: Vec<(String, Ty)> =
                    g.types.iter().cloned().zip(tys.iter().cloned()).collect();
                let sub_l: Vec<(String, Len)> =
                    g.consts.iter().cloned().zip(lens.iter().cloned()).collect();
                let lean = if s.tuple {
                    format!("f{}", &field[1..])
                } else {
                    ident(field)
                };
                Ok((lean, raw.subst(&sub_t, &sub_l)))
            }
            Ty::Tuple(v) => {
                let i: usize = field
                    .trim_start_matches('_')
                    .parse()
                    .map_err(|_| format!("bad tuple field {field}"))?;
                Ok((
                    format!("{i}"),
                    v.get(i).cloned().ok_or("tuple index out of range")?,
                ))
            }
            t => Err(format!("field {field} on non-struct type {t:?}")),
        }
    }

    // --------------------------------------------------------------- places

    pub(super) fn read_place(&mut self, p: &Place) -> R<String> {
        let mut term = self.locals[p.root].lean.clone();
        let mut ty = self.locals[p.root].ty.clone();
        for proj in &p.projs {
            match proj {
                Proj::Field(f) => {
                    let (lean, fty) = self.field_ty(&ty, f)?;
                    term = match self.resolve(&ty).peel() {
                        Ty::Tuple(v) => tuple_get(&term, lean.parse().unwrap(), v.len()),
                        _ => format!("{}.{lean}", paren(&term)),
                    };
                    ty = fty;
                }
                Proj::Tuple(i, n) => {
                    term = tuple_get(&term, *i, *n);
                    ty = match self.resolve(&ty).peel() {
                        Ty::Tuple(v) => v[*i].clone(),
                        _ => return Err("tuple projection on non-tuple".into()),
                    };
                }
                Proj::Index(i) => {
                    let t = self.temp();
                    self.impure = true;
                    let f = if matches!(self.resolve(&ty).peel(), Ty::Slice(_)) {
                        "indexA"
                    } else {
                        "index"
                    };
                    self.emit(format!("let {t} ← Rust.Slice.{f} {} {i}", paren(&term)));
                    term = t;
                    ty = elem_ty(&self.resolve(&ty))?;
                }
                Proj::Range(lo, hi) => {
                    let t = self.temp();
                    self.impure = true;
                    let f = if matches!(self.resolve(&ty).peel(), Ty::Slice(_)) {
                        "rangeA"
                    } else {
                        "range"
                    };
                    self.emit(format!(
                        "let {t} ← Rust.Slice.{f} {} {} {}",
                        paren(&term),
                        paren(lo),
                        paren(hi)
                    ));
                    term = t;
                    ty = Ty::Slice(Box::new(elem_ty(&self.resolve(&ty))?));
                }
                Proj::Some_ => return Err("read through an Option payload borrow".into()),
            }
        }
        Ok(term)
    }

    /// Assign `value` to a place, writing through any borrow aliases.
    pub(super) fn write_place(&mut self, p: &Place, value: String) -> R<()> {
        let root = p.root;
        if !self.locals[root].mutable {
            return Err(format!(
                "assignment to immutable local {}",
                self.locals[root].lean
            ));
        }
        if self.captured(root) {
            return Err("closures that mutate captured state are unsupported".into());
        }
        let base = self.locals[root].lean.clone();
        let ty = self.locals[root].ty.clone();
        let new = self.update(&base, &ty, &p.projs, value)?;
        self.emit(format!("{base} := {new}"));
        self.propagate(
            root,
            p.projs.first().map(|q| match q {
                Proj::Field(f) => f.clone(),
                _ => String::new(),
            }),
        )
    }

    /// After local `id` changed, write its value through to the places it borrows.
    fn propagate(&mut self, id: usize, field: Option<String>) -> R<()> {
        if let Some(alias) = self.locals[id].alias.clone() {
            let v = self.locals[id].lean.clone();
            let mut target = alias.clone();
            let value = if matches!(target.projs.last(), Some(Proj::Some_)) {
                target.projs.pop();
                format!("(some {v})")
            } else {
                v
            };
            self.write_place(&target, value)?;
        }
        for (f, place) in self.locals[id].field_aliases.clone() {
            if field.as_ref().is_none_or(|g| g.is_empty() || *g == f) {
                let v = format!("{}.{}", self.locals[id].lean, ident(&f));
                self.write_place(&place, v)?;
            }
        }
        Ok(())
    }

    fn update(&mut self, base: &str, ty: &Ty, projs: &[Proj], value: String) -> R<String> {
        let Some((first, rest)) = projs.split_first() else {
            return Ok(value);
        };
        match first {
            Proj::Field(f) => {
                let (lean, fty) = self.field_ty(ty, f)?;
                if let Ty::Tuple(v) = self.resolve(ty).peel() {
                    let n = v.len();
                    let i: usize = lean.parse().unwrap();
                    let cur = tuple_get(base, i, n);
                    let inner = self.update(&cur, &v[i].clone(), rest, value)?;
                    let parts: Vec<String> = (0..n)
                        .map(|j| {
                            if j == i {
                                inner.clone()
                            } else {
                                tuple_get(base, j, n)
                            }
                        })
                        .collect();
                    return Ok(format!("({})", parts.join(", ")));
                }
                let cur = format!("{}.{lean}", paren(base));
                let inner = self.update(&cur, &fty, rest, value)?;
                Ok(format!("{{ {base} with {lean} := {inner} }}"))
            }
            Proj::Tuple(i, n) => {
                let cur = tuple_get(base, *i, *n);
                let et = match self.resolve(ty).peel() {
                    Ty::Tuple(v) => v[*i].clone(),
                    _ => return Err("tuple projection on non-tuple".into()),
                };
                let inner = self.update(&cur, &et, rest, value)?;
                let parts: Vec<String> = (0..*n)
                    .map(|j| {
                        if j == *i {
                            inner.clone()
                        } else {
                            tuple_get(base, j, *n)
                        }
                    })
                    .collect();
                Ok(format!("({})", parts.join(", ")))
            }
            Proj::Index(i) => {
                let et = elem_ty(&self.resolve(ty))?;
                let slice = matches!(self.resolve(ty).peel(), Ty::Slice(_));
                let inner = if rest.is_empty() {
                    value
                } else {
                    let cur = self.temp();
                    self.impure = true;
                    let f = if slice { "indexA" } else { "index" };
                    self.emit(format!("let {cur} ← Rust.Slice.{f} {} {i}", paren(base)));
                    self.update(&cur, &et, rest, value)?
                };
                let t = self.temp();
                self.impure = true;
                let f = if slice { "setA" } else { "set" };
                self.emit(format!(
                    "let {t} ← Rust.Slice.{f} {} {i} {}",
                    paren(base),
                    paren(&inner)
                ));
                Ok(t)
            }
            Proj::Range(lo, hi) => {
                let slice = matches!(self.resolve(ty).peel(), Ty::Slice(_));
                let (get, set) = if slice {
                    ("rangeA", "setRangeA")
                } else {
                    ("range", "setRange")
                };
                let value = if !rest.is_empty() {
                    let cur = self.temp();
                    self.impure = true;
                    self.emit(format!(
                        "let {cur} ← Rust.Slice.{get} {} {} {}",
                        paren(base),
                        paren(lo),
                        paren(hi)
                    ));
                    let st = Ty::Slice(Box::new(elem_ty(&self.resolve(ty))?));
                    self.update(&cur, &st, rest, value)?
                } else {
                    value
                };
                Ok(format!(
                    "(Rust.Slice.{set} {} {} {})",
                    paren(base),
                    paren(lo),
                    paren(&value)
                ))
            }
            Proj::Some_ => Err("nested Option payload borrow".into()),
        }
    }

    /// The place an expression denotes, if it is one.
    pub(super) fn place(&mut self, e: &Expr) -> R<Option<Place>> {
        match e {
            Expr::Paren(p) => self.place(&p.expr),
            Expr::Unary(u) if matches!(u.op, syn::UnOp::Deref(_)) => self.place(&u.expr),
            Expr::Reference(r) => self.place(&r.expr),
            Expr::Path(p) if p.qself.is_none() && p.path.segments.len() == 1 => {
                let name = p.path.segments[0].ident.to_string();
                Ok(self.lookup(&name).map(|id| Place {
                    root: id,
                    projs: vec![],
                    ty: self.locals[id].ty.clone(),
                }))
            }
            Expr::Field(f) => {
                let Some(mut base) = self.place(&f.base)? else {
                    return Ok(None);
                };
                let name = match &f.member {
                    syn::Member::Named(n) => n.to_string(),
                    syn::Member::Unnamed(i) => format!("_{}", i.index),
                };
                // A borrowed field is the local's own copy; writes to it are
                // written through to the borrowed place by `propagate`.
                let (_, fty) = self.field_ty(&base.ty, &name)?;
                base.projs.push(Proj::Field(name));
                base.ty = fty;
                Ok(Some(base))
            }
            Expr::Index(i) => {
                let Some(mut base) = self.place(&i.expr)? else {
                    return Ok(None);
                };
                let et = elem_ty(&self.resolve(&base.ty))?;
                if let Expr::Range(r) = &*i.index {
                    let lo = match &r.start {
                        Some(s) => self.value(s, Some(&Ty::usize()))?.0,
                        None => "0".into(),
                    };
                    let hi = match self.range_end(r)? {
                        Some(hi) => hi,
                        None => format!("(Rust.Slice.len {})", paren(&self.read_place(&base)?)),
                    };
                    base.projs.push(Proj::Range(lo, hi));
                    base.ty = Ty::Slice(Box::new(et));
                } else {
                    let idx = self.value(&i.index, Some(&Ty::usize()))?.0;
                    base.projs.push(Proj::Index(idx));
                    base.ty = et;
                }
                Ok(Some(base))
            }
            _ => Ok(None),
        }
    }

    // ------------------------------------------------------------ functions

    /// Pack a result with the current values of the `&mut` parameters.
    pub fn pack(&self, term: Option<&str>) -> String {
        let mut parts: Vec<String> = term.map(|t| vec![t.to_owned()]).unwrap_or_default();
        parts.extend(self.outputs.iter().map(|id| self.locals[*id].lean.clone()));
        match parts.len() {
            0 => "()".into(),
            1 => parts.pop().unwrap(),
            _ => format!("({})", parts.join(", ")),
        }
    }

    fn ret_term(&self, term: &str) -> String {
        if self.closure_rets.is_empty() && self.async_fn {
            let v = if self.resolve(&self.ret_ty).is_unit() {
                "()"
            } else {
                term
            };
            return self.pack(Some(&format!("Rust.Run.ready {}", paren(v))));
        }
        if self.closure_rets.is_empty() {
            if self.resolve(&self.ret_ty).is_unit() {
                self.pack(None)
            } else {
                self.pack(Some(term))
            }
        } else {
            term.to_owned()
        }
    }

    fn do_return(&mut self, term: &str) -> R<()> {
        let kinds = [ScopeKind::Function, ScopeKind::Closure];
        self.unwind_to(&kinds)?;
        let packed = self.ret_term(term);
        self.emit(format!("return {}", paren(&packed)));
        Ok(())
    }

    /// Translate a function body as the final do-sequence.
    pub fn body(&mut self, block: &syn::Block) -> R<()> {
        let ret = self.ret_ty.clone();
        let v = self.block(block, Some(&ret))?;
        if let Some(t) = v.term {
            self.unify(&v.ty, &ret);
            self.pop_scope(true)?;
            let packed = self.ret_term(&t);
            self.emit(format!("pure {}", paren(&packed)));
        }
        Ok(())
    }

    // --------------------------------------------------------------- blocks

    pub fn block(&mut self, b: &syn::Block, expect: Option<&Ty>) -> R<V> {
        self.push_scope(ScopeKind::Block);
        let r = self.stmts(&b.stmts, expect);
        let v = match r {
            Ok(v) => v,
            Err(e) => {
                self.scopes.pop();
                return Err(e);
            }
        };
        self.pop_scope(v.term.is_some())?;
        Ok(v)
    }

    fn stmts(&mut self, stmts: &[Stmt], expect: Option<&Ty>) -> R<V> {
        let mut last = V::of("()", Ty::Unit);
        for (i, s) in stmts.iter().enumerate() {
            let tail = i + 1 == stmts.len();
            match s {
                Stmt::Local(l) => {
                    self.let_stmt(l)?;
                    last = V::of("()", Ty::Unit);
                }
                Stmt::Expr(e, semi) => {
                    let v = if tail && semi.is_none() {
                        self.expr(e, expect)?
                    } else {
                        self.stmt_expr(e)?
                    };
                    last = if semi.is_some() && v.term.is_some() {
                        V::of("()", Ty::Unit)
                    } else {
                        v
                    };
                }
                Stmt::Macro(m) => {
                    let v = self.macro_(&m.mac, None)?;
                    last = if v.term.is_some() {
                        V::of("()", Ty::Unit)
                    } else {
                        v
                    };
                }
                Stmt::Item(_) => return Err("nested items are unsupported".into()),
            }
            if last.term.is_none() {
                // Code after a diverging statement is unreachable.
                return Ok(last);
            }
        }
        Ok(last)
    }

    /// An expression in statement position: its value is discarded.
    fn stmt_expr(&mut self, e: &Expr) -> R<V> {
        match e {
            Expr::If(i) => self.if_(i, None, false),
            Expr::Match(m) => self.match_(m, None, false),
            Expr::ForLoop(f) => self.for_(f),
            Expr::While(w) => self.while_(w),
            Expr::Loop(l) => self.loop_(l),
            Expr::Block(b) if b.label.is_none() => self.block(&b.block, None),
            _ => {
                let v = self.expr(e, None)?;
                Ok(v)
            }
        }
    }

    fn let_stmt(&mut self, l: &syn::Local) -> R<()> {
        let (pat, annot) = match &l.pat {
            Pat::Type(t) => (&*t.pat, Some(self.tys().ty(&t.ty)?)),
            p => (p, None),
        };
        let Some(init) = &l.init else {
            return Err("uninitialized let is unsupported".into());
        };
        if let Some((_, diverge)) = &init.diverge {
            // let-else: bind on a match whose fallback must diverge.
            let v = self.value_v(&init.expr, annot.as_ref())?;
            let (lean_pat, binds) = self.pattern(pat, &v.ty, false)?;
            let (term, tuple_pat) = binding_tuple(&binds);
            let t = self.temp();
            self.emit(format!("let {t} ← match {} with", paren(&v.term.unwrap())));
            self.indent += 2;
            self.emit(format!("| {lean_pat} => pure {term}"));
            self.emit("| _ =>");
            self.indent += 2;
            let (dv, lines) = self.capture(|s| s.expr(diverge, None))?;
            if dv.term.is_some() {
                return Err("let-else fallback must diverge".into());
            }
            self.splice(lines, 0);
            self.indent -= 4;
            self.emit(format!("let {tuple_pat} := {t}"));
            self.bind_all(binds);
            return Ok(());
        }
        // `let x = &mut place;` borrows the place.
        if let (Pat::Ident(pi), Expr::Reference(r)) = (pat, &*init.expr) {
            if r.mutability.is_some() {
                if let Some(place) = self.place(&r.expr)? {
                    let cur = self.read_place(&place)?;
                    let name = self.fresh(&pi.ident.to_string());
                    self.emit(format!("let mut {name} := {cur}"));
                    let mut local = Body::local(name, place.ty.clone(), true);
                    local.alias = Some(place);
                    self.declare(&pi.ident.to_string(), local);
                    return Ok(());
                }
            }
        }
        // `let x = place.get_or_insert(v);` borrows the (now present) payload.
        if let (Pat::Ident(pi), Expr::MethodCall(m)) = (pat, strip(&init.expr)) {
            if m.method == "get_or_insert" {
                let place = self
                    .place(&m.receiver)?
                    .ok_or("get_or_insert on a non-place")?;
                let inner = match self.resolve(&place.ty).peel() {
                    Ty::Option(i) => (**i).clone(),
                    _ => return Err("get_or_insert on a non-Option".into()),
                };
                let cur = self.read_place(&place)?;
                let (d, _) = self.value(&m.args[0], Some(&inner))?;
                let name = self.fresh(&pi.ident.to_string());
                self.emit(format!(
                    "let mut {name} := {}.getD {}",
                    paren(&cur),
                    paren(&d)
                ));
                let mut target = place.clone();
                target.projs.push(Proj::Some_);
                let mut local = Body::local(name, inner, true);
                local.alias = Some(target);
                let id = self.declare(&pi.ident.to_string(), local);
                self.propagate(id, None)?;
                return Ok(());
            }
        }
        // A struct literal holding `&mut` borrows of places.
        if let (Pat::Ident(pi), Expr::Struct(s)) = (pat, &*init.expr) {
            if s.fields
                .iter()
                .any(|f| matches!(&f.expr, Expr::Reference(r) if r.mutability.is_some()))
            {
                return self.borrowing_struct(pi, s);
            }
        }
        let v = self.value_v(&init.expr, annot.as_ref())?;
        let Some(term) = v.term.clone() else {
            return Err("diverging let initializer".into());
        };
        let mut ty = annot.clone().unwrap_or(v.ty.clone());
        if let Some(a) = &annot {
            self.unify(a, &v.ty);
        }
        ty = self.fresh_lits(&ty);
        match pat {
            Pat::Ident(pi) if pi.subpat.is_none() => {
                let rust = pi.ident.to_string();
                let name = self.fresh(&rust);
                let mutable = pi.mutability.is_some();
                let kw = if mutable { "let mut" } else { "let" };
                let needs_annot = self.has_int_var(&ty) || annot.is_some();
                if needs_annot {
                    let lt = self.lean_ty(&ty);
                    self.emit(format!("{kw} {name} : {lt} := {term}"));
                } else {
                    self.emit(format!("{kw} {name} := {term}"));
                }
                let mut local = Body::local(name, ty.clone(), mutable);
                local.drop = self.drop_impl(&ty);
                if let Some(pf) = self.closure_purity(&init.expr) {
                    local.pure_fn = Some(pf);
                }
                self.declare(&rust, local);
            }
            Pat::Wild(_) => {
                self.emit(format!("let _ := {term}"));
            }
            _ => {
                let (lean_pat, binds) = self.pattern(pat, &ty, false)?;
                if binds.iter().any(|b| b.mutable) {
                    let t = self.temp();
                    self.emit(format!("let {t} := {term}"));
                    self.emit(format!("let {lean_pat} := {t}"));
                    for b in &binds {
                        if b.mutable {
                            self.emit(format!("let mut {} := {}", b.lean, b.lean));
                        }
                    }
                } else {
                    self.emit(format!("let {lean_pat} := {term}"));
                }
                self.bind_all(binds);
            }
        }
        Ok(())
    }

    fn closure_purity(&self, e: &Expr) -> Option<bool> {
        if let Expr::Closure(_) = e {
            self.last_closure_pure.get()
        } else {
            None
        }
    }

    fn borrowing_struct(&mut self, pi: &syn::PatIdent, s: &syn::ExprStruct) -> R<()> {
        let ty = self.struct_ty(&s.path)?;
        let mut fields = vec![];
        let mut aliases = vec![];
        for f in &s.fields {
            let syn::Member::Named(n) = &f.member else {
                return Err("tuple struct literal with borrows".into());
            };
            let name = n.to_string();
            let (lean, fty) = self.field_ty(&ty, &name)?;
            match &f.expr {
                Expr::Reference(r) if r.mutability.is_some() => {
                    let place = self
                        .place(&r.expr)?
                        .ok_or("a borrowed struct field must borrow a place")?;
                    let cur = self.read_place(&place)?;
                    fields.push(format!("{lean} := {cur}"));
                    aliases.push((name, place));
                }
                e => {
                    let (t, _) = self.value(e, Some(&fty))?;
                    fields.push(format!("{lean} := {t}"));
                }
            }
        }
        let rust = pi.ident.to_string();
        let lean = self.fresh(&rust);
        let lt = self.lean_ty(&ty);
        self.emit(format!(
            "let mut {lean} : {lt} := {{ {} }}",
            fields.join(", ")
        ));
        // Type arguments are fixed by the borrowed fields.
        let mut local = Body::local(lean, ty.clone(), true);
        local.field_aliases = aliases;
        local.drop = self.drop_impl(&ty);
        self.declare(&rust, local);
        Ok(())
    }

    /// The field of a crate struct that holds a `&mut` borrow, if any.
    pub fn borrow_field(&self, ty: &Ty) -> Option<String> {
        let Ty::Adt(p, ..) = self.resolve(ty).peel().clone() else {
            return None;
        };
        self.cx.k.structs.get(&p).and_then(|s| {
            s.fields
                .iter()
                .find(|(_, t)| matches!(t, syn::Type::Reference(r) if r.mutability.is_some()))
                .map(|(n, _)| n.clone())
        })
    }

    fn drop_impl(&self, ty: &Ty) -> Option<String> {
        let Ty::Adt(p, ..) = self.resolve(ty) else {
            return None;
        };
        self.cx
            .k
            .functions
            .values()
            .find(|f| {
                f.owner.as_deref() == Some(p.as_str()) && f.trait_name.as_deref() == Some("Drop")
            })
            .map(|f| f.path.clone())
    }

    /// `drop(x)`: run the destructor now; the local is no longer dropped at scope end.
    pub(super) fn drop_now(&mut self, id: usize) -> R<()> {
        self.run_drop(id)?;
        for s in &mut self.scopes {
            s.drops.retain(|d| *d != id);
        }
        Ok(())
    }

    /// The type a constructor path builds, using the expected type's arguments.
    pub(super) fn ctor_ty(&self, resolved: &str, expect: Option<&Ty>) -> R<Ty> {
        let adt = if self.cx.k.structs.contains_key(resolved) {
            resolved.to_owned()
        } else {
            resolved
                .rsplit_once("::")
                .map(|(e, _)| e.to_owned())
                .unwrap_or_default()
        };
        self.adt_ty(&adt, expect)
    }

    /// A crate type with arguments from the expected or Self type, else unknown.
    pub(super) fn adt_ty(&self, adt: &str, expect: Option<&Ty>) -> R<Ty> {
        if let Some(Ty::Adt(p, t, l)) = expect.map(|t| self.resolve(t).peel().clone()) {
            if p == adt {
                return Ok(Ty::Adt(p, t, l));
            }
        }
        if let Some(Ty::Adt(p, t, l)) = &self.self_ty {
            if p == adt {
                return Ok(Ty::Adt(p.clone(), t.clone(), l.clone()));
            }
        }
        let generics = self
            .cx
            .k
            .structs
            .get(adt)
            .map(|s| s.generics.clone())
            .or_else(|| self.cx.k.enums.get(adt).map(|e| e.generics.clone()))
            .ok_or_else(|| format!("{adt} is not a type"))?;
        let mut g = Generics::default();
        g.extend(&generics)?;
        Ok(Ty::Adt(
            adt.to_owned(),
            g.types.iter().map(|t| Ty::Param(format!("?{t}"))).collect(),
            g.consts
                .iter()
                .map(|c| Len::Param(format!("?{c}")))
                .collect(),
        ))
    }

    fn run_drop(&mut self, id: usize) -> R<()> {
        let Some(path) = self.locals[id].drop.clone() else {
            return Ok(());
        };
        let f = self.cx.names.functions[&path].clone();
        self.calls.insert(path.clone());
        let lean = self.locals[id].lean.clone();
        let call = format!("{f} {lean}");
        if self.cx.pure_fns.contains(&path) {
            self.emit(format!("{lean} := {call}"));
        } else {
            self.impure = true;
            self.emit(format!("{lean} ← {call}"));
        }
        self.propagate(id, None)
    }

    // ------------------------------------------------------------- patterns

    /// Bind a match arm's pattern variables; mutable ones are rebound with `let mut`.
    fn bind_arm(&mut self, binds: Vec<Binding>) {
        for b in &binds {
            if b.mutable {
                self.emit(format!("let mut {} := {}", b.lean, b.lean));
            }
        }
        self.bind_all(binds);
    }

    fn bind_all(&mut self, binds: Vec<Binding>) {
        for b in binds {
            let mut l = Body::local(b.lean, b.ty, b.mutable);
            l.alias = b.alias;
            l.field_aliases = b.field_aliases;
            self.declare(&b.rust, l);
        }
    }

    /// Translate a pattern against a value of type `ty`. With `by_mut`, the
    /// scrutinee is a `&mut` place and `Some(x)` binds a borrow of its payload.
    fn pattern(&mut self, p: &Pat, ty: &Ty, by_mut: bool) -> R<(String, Vec<Binding>)> {
        let mut binds = vec![];
        let s = self.pat(p, &self.resolve(ty), &mut binds)?;
        let _ = by_mut;
        Ok((s, binds))
    }

    fn pat(&mut self, p: &Pat, ty: &Ty, binds: &mut Vec<Binding>) -> R<String> {
        let ty = self.resolve(ty);
        let ty = ty.peel().clone();
        match p {
            Pat::Wild(_) => Ok("_".into()),
            Pat::Paren(p) => self.pat(&p.pat, &ty, binds),
            Pat::Reference(r) => self.pat(&r.pat, &ty, binds),
            Pat::Type(t) => self.pat(&t.pat, &ty, binds),
            Pat::Ident(i) => {
                if i.subpat.is_some() {
                    return Err("@ patterns are unsupported".into());
                }
                let rust = i.ident.to_string();
                // A unit variant or constant named by a bare identifier.
                if rust == "None" {
                    return Ok("none".into());
                }
                if let Some(path) = self.cx.k.resolve(&self.module, std::slice::from_ref(&rust)) {
                    if self.cx.k.consts.contains_key(&path) {
                        return Err(format!("constant pattern {rust} is unsupported"));
                    }
                }
                if let Some(b) = binds.iter().find(|b| b.rust == rust) {
                    return Ok(b.lean.clone());
                }
                let lean = self.fresh(&rust);
                binds.push(Binding {
                    rust,
                    lean: lean.clone(),
                    ty: ty.clone(),
                    mutable: i.mutability.is_some(),
                    alias: None,
                    field_aliases: vec![],
                });
                Ok(lean)
            }
            Pat::Tuple(t) if t.elems.is_empty() => Ok("()".into()),
            Pat::Tuple(t) => {
                let Ty::Tuple(tys) = &ty else {
                    return Err(format!("tuple pattern against {ty:?}"));
                };
                let mut parts = vec![];
                let mut i = 0;
                for e in &t.elems {
                    if let Pat::Rest(_) = e {
                        let skip = tys.len() - (t.elems.len() - 1);
                        for _ in 0..skip {
                            parts.push("_".to_owned());
                            i += 1;
                        }
                        continue;
                    }
                    parts.push(self.pat(e, &tys[i], binds)?);
                    i += 1;
                }
                Ok(format!("({})", parts.join(", ")))
            }
            Pat::TupleStruct(ts) => {
                let names = path_names(&ts.path);
                let last = names.last().unwrap().as_str();
                match (last, &ty) {
                    ("Some", Ty::Option(inner)) => {
                        let s = self.pat(&ts.elems[0], inner, binds)?;
                        Ok(format!("some {}", paren(&s)))
                    }
                    ("Ok", Ty::Result(a, _)) => {
                        let s = self.pat(&ts.elems[0], a, binds)?;
                        Ok(format!("Rust.Result.Ok {}", paren(&s)))
                    }
                    ("Err", Ty::Result(_, b)) => {
                        let s = self.pat(&ts.elems[0], b, binds)?;
                        Ok(format!("Rust.Result.Err {}", paren(&s)))
                    }
                    _ => {
                        let elems: Vec<Pat> = ts.elems.iter().cloned().collect();
                        self.ctor_pat(&ts.path, &ty, Fields::Positional(elems), binds)
                    }
                }
            }
            Pat::Struct(ps) => {
                let fields = ps
                    .fields
                    .iter()
                    .map(|f| {
                        let n = match &f.member {
                            syn::Member::Named(n) => n.to_string(),
                            syn::Member::Unnamed(i) => format!("_{}", i.index),
                        };
                        (n, (*f.pat).clone())
                    })
                    .collect();
                self.ctor_pat(&ps.path, &ty, Fields::Named(fields), binds)
            }
            Pat::Path(pp) => {
                let names = path_names(&pp.path);
                if names == ["None"] {
                    return Ok("none".into());
                }
                self.ctor_pat(&pp.path, &ty, Fields::Positional(vec![]), binds)
            }
            Pat::Lit(l) => match &l.lit {
                syn::Lit::Bool(b) => Ok(b.value.to_string()),
                syn::Lit::Int(i) => Ok(i.base10_digits().to_owned()),
                _ => Err("unsupported literal pattern".into()),
            },
            _ => Err(format!("unsupported pattern {}", tokens(p))),
        }
    }

    fn ctor_pat(
        &mut self,
        path: &syn::Path,
        ty: &Ty,
        fields: Fields,
        binds: &mut Vec<Binding>,
    ) -> R<String> {
        let (lean_ctor, decl, field_tys) = self.ctor(path, ty)?;
        let mut parts = vec![];
        match fields {
            Fields::Positional(pats) => {
                for (i, (_, fty)) in field_tys.iter().enumerate() {
                    match pats.get(i) {
                        Some(Pat::Rest(_)) | None => parts.push("_".to_owned()),
                        Some(p) => parts.push(paren(&self.pat(p, fty, binds)?)),
                    }
                }
            }
            Fields::Named(named) => {
                for (n, fty) in &field_tys {
                    match named.iter().find(|(m, _)| m == n) {
                        Some((_, p)) => parts.push(paren(&self.pat(p, fty, binds)?)),
                        None => parts.push("_".into()),
                    }
                }
            }
        }
        if decl {
            Ok(format!("⟨{}⟩", parts.join(", ")))
        } else if parts.is_empty() {
            Ok(lean_ctor)
        } else {
            Ok(format!("{lean_ctor} {}", parts.join(" ")))
        }
    }

    /// The Lean constructor, whether it is a structure (anonymous constructor),
    /// and the instantiated field types, for a struct or enum variant path.
    pub(super) fn ctor(&self, path: &syn::Path, ty: &Ty) -> R<Ctor> {
        let names = path_names(path);
        let resolved = if names[0] == "Self" {
            let Some(Ty::Adt(p, ..)) = &self.self_ty else {
                return Err("Self outside impl".into());
            };
            let mut s = p.clone();
            for n in &names[1..] {
                s.push_str("::");
                s.push_str(n);
            }
            s
        } else {
            self.cx
                .k
                .resolve(&self.module, &names)
                .ok_or_else(|| format!("unresolved constructor {}", tokens(path)))?
        };
        let (tys, lens) = match self.resolve(ty).peel() {
            Ty::Adt(_, t, l) => (t.clone(), l.clone()),
            _ => (vec![], vec![]),
        };
        if let Some(s) = self.cx.k.structs.get(&resolved) {
            let mut g = Generics::default();
            g.extend(&s.generics)?;
            let scope = TyScope {
                krate: self.cx.k,
                module: &s.module,
                generics: &g,
                self_ty: None,
            };
            let sub_t: Vec<(String, Ty)> = g.types.iter().cloned().zip(tys).collect();
            let sub_l: Vec<(String, Len)> = g.consts.iter().cloned().zip(lens).collect();
            let fields = s
                .fields
                .iter()
                .map(|(n, t)| Ok((n.clone(), scope.ty(t)?.subst(&sub_t, &sub_l))))
                .collect::<R<Vec<_>>>()?;
            return Ok((self.cx.names.types[&resolved].clone(), true, fields));
        }
        let (enum_path, variant) = resolved
            .rsplit_once("::")
            .ok_or_else(|| format!("not a constructor: {resolved}"))?;
        let e = self
            .cx
            .k
            .enums
            .get(enum_path)
            .ok_or_else(|| format!("not a constructor: {resolved}"))?;
        let v = e
            .variants
            .iter()
            .find(|v| v.name == variant)
            .ok_or_else(|| format!("no variant {resolved}"))?;
        let mut g = Generics::default();
        g.extend(&e.generics)?;
        let scope = TyScope {
            krate: self.cx.k,
            module: &e.module,
            generics: &g,
            self_ty: None,
        };
        let sub_t: Vec<(String, Ty)> = g.types.iter().cloned().zip(tys).collect();
        let sub_l: Vec<(String, Len)> = g.consts.iter().cloned().zip(lens).collect();
        let fields = v
            .fields
            .iter()
            .map(|(n, t)| Ok((n.clone(), scope.ty(t)?.subst(&sub_t, &sub_l))))
            .collect::<R<Vec<_>>>()?;
        Ok((
            format!("{}.{}", self.cx.names.types[enum_path], ident(variant)),
            false,
            fields,
        ))
    }

    fn struct_ty(&self, path: &syn::Path) -> R<Ty> {
        let names = path_names(path);
        if names == ["Self"] {
            return self
                .self_ty
                .clone()
                .ok_or_else(|| "Self outside impl".into());
        }
        let p = self
            .cx
            .k
            .resolve(&self.module, &names)
            .ok_or_else(|| format!("unresolved struct {}", tokens(path)))?;
        if let Some(Ty::Adt(sp, t, l)) = &self.self_ty {
            if *sp == p {
                return Ok(Ty::Adt(p, t.clone(), l.clone()));
            }
        }
        let s = self
            .cx
            .k
            .structs
            .get(&p)
            .ok_or_else(|| format!("{p} is not a struct"))?;
        let mut g = Generics::default();
        g.extend(&s.generics)?;
        // Unknown instantiation: Lean infers the arguments.
        Ok(Ty::Adt(
            p,
            g.types.iter().map(|t| Ty::Param(format!("?{t}"))).collect(),
            g.consts
                .iter()
                .map(|c| Len::Param(format!("?{c}")))
                .collect(),
        ))
    }

    // ----------------------------------------------------------- expressions

    /// A non-diverging value.
    pub fn value(&mut self, e: &Expr, expect: Option<&Ty>) -> R<(String, Ty)> {
        let v = self.value_v(e, expect)?;
        match v.term {
            Some(t) => Ok((t, v.ty)),
            None => Err(format!(
                "diverging expression in value position: {}",
                tokens(e)
            )),
        }
    }

    pub(super) fn value_v(&mut self, e: &Expr, expect: Option<&Ty>) -> R<V> {
        let v = self.expr(e, expect)?;
        if let (Some(x), Some(_)) = (expect, &v.term) {
            self.unify(x, &v.ty);
        }
        Ok(v)
    }

    /// Bind a monadic computation to a temporary.
    pub fn bind(&mut self, comp: String) -> String {
        self.impure = true;
        let t = self.temp();
        self.emit(format!("let {t} ← {comp}"));
        t
    }

    pub fn expr(&mut self, e: &Expr, expect: Option<&Ty>) -> R<V> {
        match e {
            Expr::Paren(p) => self.expr(&p.expr, expect),
            Expr::Group(g) => self.expr(&g.expr, expect),
            Expr::Lit(l) => self.lit(&l.lit, expect),
            Expr::Path(p) => self.path_expr(p, expect),
            Expr::Reference(r) => {
                let v = self.expr(&r.expr, expect.map(|t| t.peel()))?;
                Ok(V {
                    term: v.term,
                    ty: Ty::Ref(r.mutability.is_some(), Box::new(v.ty)),
                })
            }
            Expr::Unary(u) => self.unary(u, expect),
            Expr::Binary(b) => self.binary(b, expect),
            Expr::Assign(a) => {
                let place = self.place(&a.left)?.ok_or("assignment to a non-place")?;
                let pt = place.ty.clone();
                let (t, vt) = self.value(&a.right, Some(&pt))?;
                self.unify(&pt, &vt);
                self.write_place(&place, t)?;
                Ok(V::of("()", Ty::Unit))
            }
            Expr::Field(f) => {
                if let Some(p) = self.place(e)? {
                    let t = self.read_place(&p)?;
                    return Ok(V::of(t, p.ty));
                }
                let (base, bt) = self.value(&f.base, None)?;
                let name = match &f.member {
                    syn::Member::Named(n) => n.to_string(),
                    syn::Member::Unnamed(i) => format!("_{}", i.index),
                };
                let (lean, fty) = self.field_ty(&bt, &name)?;
                if let Ty::Tuple(v) = self.resolve(&bt).peel() {
                    return Ok(V::of(tuple_get(&base, lean.parse().unwrap(), v.len()), fty));
                }
                Ok(V::of(format!("{}.{lean}", paren(&base)), fty))
            }
            Expr::Index(i) => {
                if let Some(p) = self.place(e)? {
                    let t = self.read_place(&p)?;
                    return Ok(V::of(t, p.ty));
                }
                let (base, bt) = self.value(&i.expr, None)?;
                let et = elem_ty(&self.resolve(&bt))?;
                let (idx, _) = self.value(&i.index, Some(&Ty::usize()))?;
                let t = self.bind(format!("Rust.Slice.index {} {}", paren(&base), paren(&idx)));
                Ok(V::of(t, et))
            }
            Expr::Tuple(t) => {
                if t.elems.is_empty() {
                    return Ok(V::of("()", Ty::Unit));
                }
                let exp: Vec<Option<Ty>> = match expect.map(|t| self.resolve(t)) {
                    Some(Ty::Tuple(v)) if v.len() == t.elems.len() => {
                        v.into_iter().map(Some).collect()
                    }
                    _ => vec![None; t.elems.len()],
                };
                let mut terms = vec![];
                let mut tys = vec![];
                for (e, x) in t.elems.iter().zip(exp) {
                    let (term, ty) = self.value(e, x.as_ref())?;
                    terms.push(term);
                    tys.push(ty);
                }
                Ok(V::of(format!("({})", terms.join(", ")), Ty::Tuple(tys)))
            }
            Expr::Block(b) if b.label.is_none() => {
                let v = self.capture(|s| s.block(&b.block, expect))?;
                self.inline_block(v)
            }
            Expr::If(i) => self.if_(i, expect, true),
            Expr::Match(m) => self.match_(m, expect, true),
            Expr::Return(r) => {
                let term = match &r.expr {
                    Some(e) => {
                        let rt = self
                            .closure_rets
                            .last()
                            .cloned()
                            .unwrap_or(self.ret_ty.clone());
                        let v = self.value_v(e, Some(&rt))?;
                        match v.term {
                            Some(t) => t,
                            None => return Ok(V::never()),
                        }
                    }
                    None => "()".into(),
                };
                self.do_return(&term)?;
                Ok(V::never())
            }
            Expr::Break(b) => {
                if b.expr.is_some() || b.label.is_some() {
                    return Err("labeled breaks and break values are unsupported".into());
                }
                self.unwind_to(&[ScopeKind::Loop])?;
                self.emit("break");
                Ok(V::never())
            }
            Expr::Continue(c) => {
                if c.label.is_some() {
                    return Err("labeled continue is unsupported".into());
                }
                self.unwind_to(&[ScopeKind::Loop])?;
                self.emit("continue");
                Ok(V::never())
            }
            Expr::Try(t) => self.try_(t),
            Expr::Call(c) => self.call(c, expect),
            Expr::MethodCall(m) => self.method_call(m, expect),
            Expr::Struct(s) => self.struct_lit(s, expect),
            Expr::Repeat(r) => {
                let et = match expect.map(|t| self.resolve(t)) {
                    Some(Ty::Array(t, _)) => Some(*t),
                    _ => None,
                };
                let (v, vt) = self.value(&r.expr, et.as_ref())?;
                let len = self.tys().len(&r.len)?;
                let l = self.cx.names.len(&len);
                Ok(V::of(
                    format!("(Vector.replicate {l} {})", paren(&v)),
                    Ty::Array(Box::new(vt), len),
                ))
            }
            Expr::Array(a) => {
                let et = match expect.map(|t| self.resolve(t)) {
                    Some(Ty::Array(t, _)) | Some(Ty::Slice(t)) => Some(*t),
                    _ => None,
                };
                let mut terms = vec![];
                let mut ty = et.clone().unwrap_or(Ty::Unit);
                for e in &a.elems {
                    let (t, tt) = self.value(e, et.as_ref())?;
                    terms.push(t);
                    ty = tt;
                }
                Ok(V::of(
                    format!("#v[{}]", terms.join(", ")),
                    Ty::Array(Box::new(ty), Len::Lit(a.elems.len() as u64)),
                ))
            }
            Expr::Cast(c) => self.cast(c),
            Expr::Closure(c) => self.closure(c, expect),
            Expr::Macro(m) => self.macro_(&m.mac, expect),
            Expr::Await(a) => self.await_(a, expect),
            Expr::ForLoop(f) => self.for_(f),
            Expr::While(w) => self.while_(w),
            Expr::Loop(l) => self.loop_(l),
            Expr::Let(_) => Err("let expressions outside if conditions are unsupported".into()),
            Expr::Const(c) => {
                // A const block is evaluated at compile time; a failed assertion
                // would have rejected the program, which a panic here models.
                let v = self.capture(|s| s.block(&c.block, expect))?;
                self.inline_block(v)
            }
            Expr::Range(_) => Err("range outside a for loop or slice index is unsupported".into()),
            _ => Err(format!("unsupported expression {}", tokens(e))),
        }
    }

    /// Emit a captured block in the current sequence and yield its value.
    fn inline_block(&mut self, (v, lines): (V, Lines)) -> R<V> {
        if lines.is_empty() {
            return Ok(v);
        }
        // Statements of an inner block run in sequence; Lean scoping of its
        // fresh names is harmless because every name is unique in the body.
        self.splice(lines, 0);
        Ok(v)
    }

    fn lit(&mut self, l: &syn::Lit, expect: Option<&Ty>) -> R<V> {
        match l {
            syn::Lit::Bool(b) => Ok(V::of(b.value.to_string(), Ty::Bool)),
            syn::Lit::Int(i) => {
                let ty = match i.suffix() {
                    "" => match expect.map(|t| self.resolve(t)) {
                        Some(t @ (Ty::Uint(..) | Ty::Int(..) | Ty::IntVar(_))) => t,
                        _ => Ty::IntLit,
                    },
                    "u8" => Ty::Uint(8, "u8"),
                    "u16" => Ty::Uint(16, "u16"),
                    "u32" => Ty::Uint(32, "u32"),
                    "u64" => Ty::u64(),
                    "usize" => Ty::usize(),
                    "i32" => Ty::Int(32, "i32"),
                    "i64" => Ty::Int(64, "i64"),
                    s => return Err(format!("unsupported integer suffix {s}")),
                };
                let n: u128 = i.base10_parse().map_err(|e| e.to_string())?;
                Ok(V::of(n.to_string(), ty))
            }
            syn::Lit::Str(s) => Ok(V::of(format!("{:?}", s.value()), Ty::Str)),
            _ => Err("unsupported literal".into()),
        }
    }

    fn path_expr(&mut self, p: &syn::ExprPath, expect: Option<&Ty>) -> R<V> {
        if p.qself.is_some() {
            return Err("qualified paths are unsupported".into());
        }
        let names = path_names(&p.path);
        if names.len() == 1 {
            let n = &names[0];
            if let Some(id) = self.lookup(n) {
                let l = &self.locals[id];
                return Ok(V::of(l.lean.clone(), l.ty.clone()));
            }
            if n == "None" {
                return Ok(V::of(
                    "none",
                    expect
                        .cloned()
                        .unwrap_or_else(|| Ty::Option(Box::new(Ty::Param("?None".into())))),
                ));
            }
            if self.generics.consts.contains(n) {
                return Ok(V::of(format!("(Rust.usizeOf {})", ident(n)), Ty::usize()));
            }
        }
        // Primitive associated constants.
        if names.len() == 2 && names[1] == "MAX" {
            let ty = match names[0].as_str() {
                "u8" => Ty::Uint(8, "u8"),
                "u16" => Ty::Uint(16, "u16"),
                "u32" => Ty::Uint(32, "u32"),
                "u64" => Ty::u64(),
                "usize" => Ty::usize(),
                _ => return Err(format!("unsupported constant {}", names.join("::"))),
            };
            let Ty::Uint(bits, name) = ty else {
                unreachable!()
            };
            let bits = if name == "usize" {
                "Rust.usizeBits".to_owned()
            } else {
                bits.to_string()
            };
            return Ok(V::of(format!("(Rust.umax {bits})"), ty));
        }
        if names == ["Option", "is_some"] {
            return Ok(V::of(
                "(fun o => o.isSome)",
                Ty::Fn(vec![], Box::new(Ty::Bool)),
            ));
        }
        if names == ["Option", "is_none"] {
            return Ok(V::of(
                "(fun o => o.isNone)",
                Ty::Fn(vec![], Box::new(Ty::Bool)),
            ));
        }
        let resolved = if names[0] == "Self" {
            let Some(Ty::Adt(sp, ..)) = &self.self_ty else {
                return Err("Self outside impl".into());
            };
            let mut s = sp.clone();
            for n in &names[1..] {
                s.push_str("::");
                s.push_str(n);
            }
            s
        } else {
            self.cx
                .k
                .resolve(&self.module, &names)
                .ok_or_else(|| format!("unresolved path {}", names.join("::")))?
        };
        if let Some(c) = self.cx.k.consts.get(&resolved) {
            let scope = TyScope {
                krate: self.cx.k,
                module: &c.module,
                generics: &Generics::default(),
                self_ty: None,
            };
            let ty = scope.ty(&c.ty)?;
            let name = self.cx.names.consts[&resolved].clone();
            if ty == Ty::usize() {
                return Ok(V::of(format!("(Rust.usizeOf {name})"), ty));
            }
            return Ok(V::of(name, ty));
        }
        // A unit variant or unit struct.
        let ty = match expect.map(|t| self.resolve(t)) {
            Some(t @ Ty::Adt(..)) => t,
            _ => {
                let (enum_path, _) = resolved.rsplit_once("::").unwrap_or(("", ""));
                if self.cx.k.enums.contains_key(enum_path) {
                    let e = &self.cx.k.enums[enum_path];
                    let mut g = Generics::default();
                    g.extend(&e.generics)?;
                    Ty::Adt(
                        enum_path.to_owned(),
                        g.types.iter().map(|t| Ty::Param(format!("?{t}"))).collect(),
                        g.consts
                            .iter()
                            .map(|c| Len::Param(format!("?{c}")))
                            .collect(),
                    )
                } else {
                    return Err(format!("unsupported path {resolved}"));
                }
            }
        };
        let (ctor, decl, fields) = self.ctor(&p.path, &ty)?;
        if !fields.is_empty() {
            return Err(format!("constructor {resolved} used as a value"));
        }
        if decl {
            return Ok(V::of(format!("({{}} : {})", self.lean_ty(&ty)), ty));
        }
        Ok(V::of(ctor, ty))
    }

    fn unary(&mut self, u: &syn::ExprUnary, expect: Option<&Ty>) -> R<V> {
        match u.op {
            syn::UnOp::Not(_) => {
                let (t, ty) = self.value(&u.expr, expect)?;
                match self.resolve(&ty) {
                    Ty::Bool => Ok(V::of(format!("!{}", paren(&t)), Ty::Bool)),
                    _ => Err("bitwise not is unsupported".into()),
                }
            }
            syn::UnOp::Deref(_) => {
                let (t, ty) = self.value(&u.expr, None)?;
                Ok(V::of(t, ty.peel().clone()))
            }
            _ => Err("negation is unsupported for unsigned integers".into()),
        }
    }

    fn binary(&mut self, b: &syn::ExprBinary, expect: Option<&Ty>) -> R<V> {
        use syn::BinOp::*;
        let compound = match b.op {
            AddAssign(_) => Some("+"),
            SubAssign(_) => Some("-"),
            MulAssign(_) => Some("*"),
            DivAssign(_) => Some("/"),
            RemAssign(_) => Some("%"),
            BitXorAssign(_) => Some("^"),
            BitAndAssign(_) => Some("&"),
            BitOrAssign(_) => Some("|"),
            ShrAssign(_) => Some(">>"),
            ShlAssign(_) => Some("<<"),
            _ => None,
        };
        if let Some(op) = compound {
            let place = self
                .place(&b.left)?
                .ok_or("compound assignment to a non-place")?;
            let cur = self.read_place(&place)?;
            let (r, rt) = self.value(&b.right, Some(&place.ty.clone()))?;
            let pt = place.ty.clone();
            self.unify(&pt, &rt);
            let v = self.arith(op, cur, r, &pt)?;
            self.write_place(&place, v)?;
            return Ok(V::of("()", Ty::Unit));
        }
        match b.op {
            And(_) | Or(_) => {
                let (l, _) = self.value(&b.left, Some(&Ty::Bool))?;
                let ((r, _), lines) = self.capture(|s| s.value(&b.right, Some(&Ty::Bool)))?;
                let op = if matches!(b.op, And(_)) { "&&" } else { "||" };
                if lines.is_empty() {
                    return Ok(V::of(format!("{} {op} {}", paren(&l), paren(&r)), Ty::Bool));
                }
                // The right operand has effects: evaluate it only when needed.
                let t = self.temp();
                let cond = if op == "&&" {
                    paren(&l)
                } else {
                    format!("!{}", paren(&l))
                };
                let short = if op == "&&" { "false" } else { "true" };
                self.emit(format!("let {t} ← if {cond} then"));
                self.splice(lines, 4);
                self.indent += 4;
                self.emit(format!("pure {}", paren(&r)));
                self.indent -= 2;
                self.emit("else");
                self.indent += 2;
                self.emit(format!("pure {short}"));
                self.indent -= 4;
                Ok(V::of(t, Ty::Bool))
            }
            Eq(_) | Ne(_) | Lt(_) | Le(_) | Gt(_) | Ge(_) => {
                // Lexicographic tuple comparisons expand to their definition.
                if let (Expr::Tuple(l), Expr::Tuple(r)) = (strip(&b.left), strip(&b.right)) {
                    if !matches!(b.op, Eq(_) | Ne(_)) && l.elems.len() == r.elems.len() {
                        let mut ls = vec![];
                        let mut rs = vec![];
                        for (x, y) in l.elems.iter().zip(&r.elems) {
                            let (a, at) = self.value(x, None)?;
                            let (c, ct) = self.value(y, Some(&at))?;
                            self.unify(&at, &ct);
                            ls.push(a);
                            rs.push(c);
                        }
                        return Ok(V::of(lex(&b.op, &ls, &rs), Ty::Bool));
                    }
                }
                let (l, lt) = self.value(&b.left, None)?;
                let (r, rt) = self.value(&b.right, Some(&lt))?;
                self.unify(&lt, &rt);
                let s = match b.op {
                    Eq(_) => format!("{} == {}", paren(&l), paren(&r)),
                    Ne(_) => format!("{} != {}", paren(&l), paren(&r)),
                    Lt(_) => format!("decide ({} < {})", paren(&l), paren(&r)),
                    Le(_) => format!("decide ({} ≤ {})", paren(&l), paren(&r)),
                    Gt(_) => format!("decide ({} > {})", paren(&l), paren(&r)),
                    _ => format!("decide ({} ≥ {})", paren(&l), paren(&r)),
                };
                Ok(V::of(s, Ty::Bool))
            }
            BitAnd(_) | BitOr(_) | BitXor(_) | Add(_) | Sub(_) | Mul(_) | Div(_) | Rem(_)
            | Shr(_) | Shl(_) => {
                let shift = matches!(b.op, Shr(_) | Shl(_));
                let (l, lt) = self.value(&b.left, expect)?;
                let (r, rt) = self.value(&b.right, if shift { None } else { Some(&lt) })?;
                let literal = r.chars().all(|c| c.is_ascii_digit());
                let r = if shift && !literal && matches!(self.resolve(&rt), Ty::IntLit) {
                    format!("({r} : Rust.u32)")
                } else {
                    r
                };
                if !shift {
                    self.unify(&lt, &rt);
                }
                let mut ty = self.resolve(&lt);
                if matches!(ty, Ty::IntLit) {
                    ty = self.resolve(&rt);
                }
                if matches!(ty, Ty::IntLit) {
                    if let Some(x) = expect {
                        ty = self.resolve(x);
                    }
                }
                let op = match b.op {
                    BitAnd(_) => "&",
                    BitOr(_) => "|",
                    BitXor(_) => "^",
                    Add(_) => "+",
                    Sub(_) => "-",
                    Mul(_) => "*",
                    Div(_) => "/",
                    Rem(_) => "%",
                    Shr(_) => ">>",
                    _ => "<<",
                };
                if ty == Ty::Bool {
                    return match op {
                        "&" => Ok(V::of(format!("{} && {}", paren(&l), paren(&r)), Ty::Bool)),
                        "|" => Ok(V::of(format!("{} || {}", paren(&l), paren(&r)), Ty::Bool)),
                        "^" => Ok(V::of(format!("{} != {}", paren(&l), paren(&r)), Ty::Bool)),
                        _ => Err("arithmetic on bool".into()),
                    };
                }
                let t = self.arith(op, l, r, &ty)?;
                Ok(V::of(t, ty))
            }
            _ => Err(format!("unsupported operator {}", tokens(&b.op))),
        }
    }

    /// Unsigned arithmetic under the build's overflow-check setting.
    fn arith(&mut self, op: &str, l: String, r: String, ty: &Ty) -> R<String> {
        let (l, r) = (paren(&l), paren(&r));
        let checked = self.cx.overflow_checks;
        // Signed operations are prefixed `i`; a literal variable decides later.
        let prefix = match self.resolve(ty) {
            Ty::Int(..) => "i".to_owned(),
            Ty::IntVar(v) => format!("⁇S{v}⁇"),
            _ => String::new(),
        };
        let pure = |f: &str| format!("Rust.{prefix}{f} {l} {r}");
        // A literal shift amount below the width, or a nonzero literal divisor,
        // cannot panic: the operation is pure.
        let literal = r.parse::<u128>().ok();
        let bits = match self.resolve(ty) {
            Ty::Uint(b, _) => Some(b as u128),
            _ => None,
        };
        match (op, literal, bits) {
            (">>", Some(k), Some(b)) if k < b => return Ok(format!("Rust.shrK {l} {k}")),
            ("<<", Some(k), Some(b)) if k < b => return Ok(format!("Rust.shlK {l} {k}")),
            ("/", Some(k), Some(_)) if k > 0 => return Ok(format!("Rust.divK {l} {k}")),
            ("%", Some(k), Some(_)) if k > 0 => return Ok(format!("Rust.remK {l} {k}")),
            _ => {}
        }
        Ok(match op {
            "+" if checked => self.bind(pure("add")),
            "-" if checked => self.bind(pure("sub")),
            "*" if checked => self.bind(pure("mul")),
            "+" => pure("wrapping_add"),
            "-" => pure("wrapping_sub"),
            "*" => pure("wrapping_mul"),
            "/" => self.bind(pure("div")),
            "%" => self.bind(pure("rem")),
            "^" => pure("xor"),
            "&" => pure("band"),
            "|" => pure("bor"),
            ">>" if checked => self.bind(pure("shr")),
            "<<" if checked => self.bind(pure("shl")),
            _ => {
                let _ = ty;
                return Err(format!("unsupported unchecked operator {op}"));
            }
        })
    }

    fn cast(&mut self, c: &syn::ExprCast) -> R<V> {
        let to = self.tys().ty(&c.ty)?;
        let (t, from) = self.value(&c.expr, None)?;
        let from = self.resolve(&from);
        match (&from, &to) {
            (Ty::Bool, Ty::Uint(..)) => Ok(V::of(
                format!("(Rust.ofBool {} : {})", paren(&t), self.lean_ty(&to)),
                to,
            )),
            (Ty::Uint(a, _), Ty::Uint(b, _)) if a == b => Ok(V::of(t, to)),
            (Ty::Uint(..) | Ty::IntLit | Ty::IntVar(_), Ty::Uint(..)) => Ok(V::of(
                format!("(Rust.cast {} : {})", paren(&t), self.lean_ty(&to)),
                to,
            )),
            _ => Err(format!("unsupported cast {}", tokens(c))),
        }
    }

    fn try_(&mut self, t: &syn::ExprTry) -> R<V> {
        let (term, ty) = self.value(&t.expr, None)?;
        let ty = self.resolve(&ty);
        let out = self.temp();
        let ok = self.synthetic("v");
        let err = self.synthetic("e");
        self.emit(format!("let {out} ← match {} with", paren(&term)));
        self.indent += 2;
        let inner = match &ty {
            Ty::Option(inner) => {
                self.emit(format!("| some {ok} => pure {ok}"));
                self.emit("| none =>");
                self.indent += 2;
                self.do_return("none")?;
                self.indent -= 2;
                (**inner).clone()
            }
            Ty::Result(a, _) => {
                self.emit(format!("| Rust.Result.Ok {ok} => pure {ok}"));
                self.emit(format!("| Rust.Result.Err {err} =>"));
                self.indent += 2;
                self.do_return(&format!("(Rust.Result.Err {err})"))?;
                self.indent -= 2;
                (**a).clone()
            }
            _ => return Err("? on a non-Option, non-Result value".into()),
        };
        self.indent -= 2;
        Ok(V::of(out, inner))
    }

    // --------------------------------------------------------- control flow

    fn branch(&mut self, f: impl FnOnce(&mut Self) -> R<V>) -> R<(V, Lines)> {
        self.capture(f)
    }

    /// Emit a branch body at the current indentation plus `extra`, ending in its value.
    fn emit_branch(&mut self, v: &V, lines: Lines, extra: usize, value: bool) {
        let empty = lines.is_empty();
        self.splice(lines, extra);
        if let Some(t) = &v.term {
            self.indent += extra;
            if value {
                self.emit(format!("pure {}", paren(t)));
            } else if empty {
                self.emit("pure ()");
            }
            self.indent -= extra;
        }
    }

    fn if_(&mut self, i: &syn::ExprIf, expect: Option<&Ty>, want: bool) -> R<V> {
        if let Expr::Let(l) = &*i.cond {
            return self.if_let(
                l,
                &i.then_branch,
                i.else_branch.as_ref().map(|(_, e)| &**e),
                expect,
                want,
            );
        }
        let (c, _) = self.value(&i.cond, Some(&Ty::Bool))?;
        let (tv, tl) = self.branch(|s| s.block(&i.then_branch, expect))?;
        let (ev, el) = match &i.else_branch {
            Some((_, e)) => self.branch(|s| s.expr(e, expect.or(Some(&tv.ty))))?,
            None => (V::of("()", Ty::Unit), vec![]),
        };
        let ty = if tv.term.is_some() {
            tv.ty.clone()
        } else {
            ev.ty.clone()
        };
        self.unify(&tv.ty, &ev.ty);
        let has_value =
            want && !self.resolve(&ty).is_unit() && (tv.term.is_some() || ev.term.is_some());
        if has_value && tl.is_empty() && el.is_empty() {
            if let (Some(a), Some(b)) = (&tv.term, &ev.term) {
                return Ok(V::of(
                    format!("if {c} then {} else {}", paren(a), paren(b)),
                    ty,
                ));
            }
        }
        let diverges = tv.term.is_none() && ev.term.is_none();
        if has_value {
            let t = self.temp();
            self.emit(format!("let {t} ← if {c} then"));
            self.emit_branch(&tv, tl, 4, true);
            self.indent += 2;
            self.emit("else");
            self.indent -= 2;
            self.emit_branch(&ev, el, 4, true);
            return Ok(V::of(t, ty));
        }
        self.emit(format!("if {c} then"));
        self.emit_branch(&tv, tl, 2, false);
        if !el.is_empty() || ev.term.is_none() {
            self.emit("else");
            self.emit_branch(&ev, el, 2, false);
        }
        if diverges {
            Ok(V::never())
        } else {
            Ok(V::of("()", Ty::Unit))
        }
    }

    fn if_let(
        &mut self,
        l: &syn::ExprLet,
        then: &syn::Block,
        els: Option<&Expr>,
        expect: Option<&Ty>,
        want: bool,
    ) -> R<V> {
        let arms = vec![
            Arm {
                pat: (*l.pat).clone(),
                guard: None,
                body: Expr::Block(syn::ExprBlock {
                    attrs: vec![],
                    label: None,
                    block: then.clone(),
                }),
            },
            Arm {
                pat: Pat::Wild(syn::PatWild {
                    attrs: vec![],
                    underscore_token: Default::default(),
                }),
                guard: None,
                body: els.cloned().unwrap_or_else(|| syn::parse_quote!({})),
            },
        ];
        self.match_arms(&l.expr, &arms, expect, want)
    }

    fn match_(&mut self, m: &syn::ExprMatch, expect: Option<&Ty>, want: bool) -> R<V> {
        let arms: Vec<Arm> = m
            .arms
            .iter()
            .map(|a| Arm {
                pat: a.pat.clone(),
                guard: a.guard.as_ref().map(|(_, g)| (**g).clone()),
                body: (*a.body).clone(),
            })
            .collect();
        self.match_arms(&m.expr, &arms, expect, want)
    }

    fn match_arms(&mut self, scrut: &Expr, arms: &[Arm], expect: Option<&Ty>, want: bool) -> R<V> {
        // A `&mut` scrutinee binds borrows of its payload.
        let e = strip(scrut);
        // Locals that are themselves `&mut` borrows: aliases and `&mut` parameters.
        let borrowed_local = match e {
            Expr::Path(p) if p.path.segments.len() == 1 => self
                .lookup(&p.path.segments[0].ident.to_string())
                .is_some_and(|id| {
                    self.locals[id].alias.is_some()
                        || self.locals[id].mut_ref
                        || self.outputs.contains(&id)
                }),
            _ => false,
        };
        let is_mut_ref =
            matches!(e, Expr::Reference(r) if r.mutability.is_some()) || borrowed_local;
        let v = self.value_v(scrut, None)?;
        let sty = self.resolve(&v.ty);
        let by_mut = is_mut_ref || sty.mut_ref();
        let place = if by_mut { self.place(scrut)? } else { None };
        let s = v.term.ok_or("diverging match scrutinee")?;
        let borrow = self
            .pending_borrow
            .take()
            .filter(|(t, _)| *t == s)
            .map(|(_, p)| p);
        let s = if s
            .chars()
            .all(|c| c.is_alphanumeric() || c == '_' || c == '.')
        {
            s
        } else {
            let t = self.temp();
            self.emit(format!("let {t} := {s}"));
            t
        };
        let saved = std::mem::replace(&mut self.result_borrow, borrow);
        let r = self.arms_from(&s, &sty, place.as_ref(), arms, expect, want);
        self.result_borrow = saved;
        r
    }

    fn arms_from(
        &mut self,
        s: &str,
        sty: &Ty,
        place: Option<&Place>,
        arms: &[Arm],
        expect: Option<&Ty>,
        want: bool,
    ) -> R<V> {
        // Literal patterns and guards translate to conditionals.
        let literal = arms.iter().any(|a| matches!(&a.pat, Pat::Lit(_)));
        let guarded = arms.iter().position(|a| a.guard.is_some());
        let mut translated = vec![];
        for (i, arm) in arms.iter().enumerate() {
            if literal || guarded == Some(i) {
                break;
            }
            let _ = i;
            translated.push(arm);
        }
        let mut results = vec![];
        let mut ty: Option<Ty> = expect.cloned();
        for arm in &translated {
            self.push_scope(ScopeKind::Block);
            let (pats, binds) = self.arm_patterns(&arm.pat, sty, place)?;
            let r = self.branch(|s| {
                s.bind_arm(binds);
                s.expr(&arm.body, ty.as_ref())
            });
            self.scopes.pop();
            let (v, lines) = r?;
            if v.term.is_some() {
                if let Some(t) = &ty {
                    let t = t.clone();
                    self.unify(&t, &v.ty);
                }
                if ty
                    .as_ref()
                    .is_none_or(|t| matches!(self.resolve(t), Ty::IntLit | Ty::Never))
                {
                    ty = Some(v.ty.clone());
                }
            }
            results.push((pats, v, lines));
        }
        let rest = &arms[translated.len()..];
        let rest_result = if rest.is_empty() {
            None
        } else {
            Some(self.branch(|b| b.arms_rest(s, sty, place, rest, ty.as_ref(), want))?)
        };
        if let Some((v, _)) = &rest_result {
            if v.term.is_some()
                && ty
                    .as_ref()
                    .is_none_or(|t| matches!(self.resolve(t), Ty::IntLit | Ty::Never))
            {
                ty = Some(v.ty.clone());
            }
        }
        let ty = ty.unwrap_or(Ty::Unit);
        let has_value = want && !self.resolve(&ty).is_unit() && !matches!(ty, Ty::Never);
        let reaches = results.iter().any(|(_, v, _)| v.term.is_some())
            || rest_result.as_ref().is_some_and(|(v, _)| v.term.is_some());
        if results.is_empty() {
            let (v, lines) = rest_result.unwrap();
            self.splice(lines, 0);
            return Ok(v);
        }
        // Simple value matches stay terms.
        if has_value
            && results
                .iter()
                .all(|(_, v, l)| l.is_empty() && v.term.is_some())
            && rest_result.is_none()
        {
            let mut s_ = format!("match {s} with");
            for (pats, v, _) in &results {
                s_.push_str(&format!(
                    " | {} => {}",
                    pats.join(" | "),
                    v.term.as_ref().unwrap()
                ));
            }
            return Ok(V::of(format!("({s_})"), ty));
        }
        let (head, extra) = if has_value {
            let t = self.temp();
            (Some(t), 4)
        } else {
            (None, 2)
        };
        match &head {
            Some(t) => self.emit(format!("let {t} ← match {s} with")),
            None => self.emit(format!("match {s} with")),
        }
        self.indent += extra - 2;
        for (pats, v, lines) in results {
            self.emit(format!("| {} =>", pats.join(" | ")));
            self.emit_branch(&v, lines, 2, has_value);
        }
        if let Some((v, lines)) = rest_result {
            self.emit("| _ =>");
            self.emit_branch(&v, lines, 2, has_value);
        }
        self.indent -= extra - 2;
        match head {
            Some(t) if reaches => Ok(V::of(t, ty)),
            _ if reaches => Ok(V::of("()", Ty::Unit)),
            _ => Ok(V::never()),
        }
    }

    /// Arms after the first guard or literal pattern: a conditional chain.
    fn arms_rest(
        &mut self,
        s: &str,
        sty: &Ty,
        place: Option<&Place>,
        arms: &[Arm],
        expect: Option<&Ty>,
        want: bool,
    ) -> R<V> {
        let Some((arm, rest)) = arms.split_first() else {
            self.impure = true;
            self.emit("Rust.fail \"non-exhaustive match\"");
            return Ok(V::never());
        };
        if let Pat::Lit(_) | Pat::Wild(_) = &arm.pat {
            if matches!(arm.pat, Pat::Wild(_)) && arm.guard.is_none() {
                return self.expr(&arm.body, expect);
            }
        }
        if let Some(g) = &arm.guard {
            return self.guarded_arm(s, sty, place, arm, g, rest, expect, want);
        }
        // Test the pattern (and guard); otherwise continue with the rest.
        self.push_scope(ScopeKind::Block);
        let (pats, binds) = self.arm_patterns(&arm.pat, sty, place)?;
        let lit = matches!(arm.pat, Pat::Lit(_));
        let r = self.branch(|b| {
            b.bind_arm(binds);
            match &arm.guard {
                Some(g) => {
                    let (c, _) = b.value(g, Some(&Ty::Bool))?;
                    let (tv, tl) = b.branch(|b2| b2.expr(&arm.body, expect))?;
                    let (ev, el) = b.branch(|b2| {
                        b2.arms_rest(s, sty, place, rest, expect.or(Some(&tv.ty)), want)
                    })?;
                    let ty = if tv.term.is_some() {
                        tv.ty.clone()
                    } else {
                        ev.ty.clone()
                    };
                    let has_value = want && !b.resolve(&ty).is_unit() && !matches!(ty, Ty::Never);
                    if has_value {
                        let t = b.temp();
                        b.emit(format!("let {t} ← if {c} then"));
                        b.emit_branch(&tv, tl, 4, true);
                        b.indent += 2;
                        b.emit("else");
                        b.indent -= 2;
                        b.emit_branch(&ev, el, 4, true);
                        if tv.term.is_none() && ev.term.is_none() {
                            return Ok(V::never());
                        }
                        Ok(V::of(t, ty))
                    } else {
                        b.emit(format!("if {c} then"));
                        b.emit_branch(&tv, tl, 2, false);
                        b.emit("else");
                        b.emit_branch(&ev, el, 2, false);
                        if tv.term.is_none() && ev.term.is_none() {
                            Ok(V::never())
                        } else {
                            Ok(V::of("()", Ty::Unit))
                        }
                    }
                }
                None => b.expr(&arm.body, expect),
            }
        });
        self.scopes.pop();
        let (v, lines) = r?;
        let (ev, el) = if arm.guard.is_some() {
            // The guard's else-branch already covers the remaining arms when
            // the pattern matches; a non-matching pattern also continues there.
            self.branch(|b| b.arms_rest(s, sty, place, rest, expect.or(Some(&v.ty)), want))?
        } else {
            self.branch(|b| b.arms_rest(s, sty, place, rest, expect.or(Some(&v.ty)), want))?
        };
        let ty = if v.term.is_some() {
            v.ty.clone()
        } else {
            ev.ty.clone()
        };
        let has_value = want && !self.resolve(&ty).is_unit() && !matches!(ty, Ty::Never);
        let t = if has_value { Some(self.temp()) } else { None };
        if lit {
            let cond = format!("{s} == {}", pats[0]);
            match &t {
                Some(t) => self.emit(format!("let {t} ← if {cond} then")),
                None => self.emit(format!("if {cond} then")),
            }
            let extra = if t.is_some() { 4 } else { 2 };
            self.emit_branch(&v, lines, extra, has_value);
            self.indent += extra - 2;
            self.emit("else");
            self.indent -= extra - 2;
            self.emit_branch(&ev, el, extra, has_value);
        } else {
            match &t {
                Some(t) => self.emit(format!("let {t} ← match {s} with")),
                None => self.emit(format!("match {s} with")),
            }
            let extra = if t.is_some() { 2 } else { 0 };
            self.indent += extra;
            self.emit(format!("| {} =>", pats.join(" | ")));
            self.emit_branch(&v, lines, 2, has_value);
            self.emit("| _ =>");
            self.emit_branch(&ev, el, 2, has_value);
            self.indent -= extra;
        }
        let reaches = v.term.is_some() || ev.term.is_some();
        match t {
            Some(t) if reaches => Ok(V::of(t, ty)),
            _ if reaches => Ok(V::of("()", Ty::Unit)),
            _ => Ok(V::never()),
        }
    }

    /// A guarded arm: evaluate the pattern and guard once into an `Option` of
    /// the arm's bindings, then run the body or the remaining arms.
    #[allow(clippy::too_many_arguments)]
    fn guarded_arm(
        &mut self,
        s: &str,
        sty: &Ty,
        place: Option<&Place>,
        arm: &Arm,
        guard: &Expr,
        rest: &[Arm],
        expect: Option<&Ty>,
        want: bool,
    ) -> R<V> {
        self.push_scope(ScopeKind::Block);
        let (pats, binds) = self.arm_patterns(&arm.pat, sty, place)?;
        let r = self.branch(|b| {
            b.bind_all(binds.clone());
            b.value(guard, Some(&Ty::Bool)).map(|(t, ty)| V::of(t, ty))
        });
        self.scopes.pop();
        let (gv, gl) = r?;
        let gt = gv.term.unwrap_or_default();
        let (tuple, tuple_pat) = binding_tuple(&binds);
        let g = self.temp();
        self.emit(format!("let {g} ← match {s} with"));
        self.indent += 2;
        self.emit(format!("| {} =>", pats.join(" | ")));
        self.splice(gl, 2);
        self.indent += 2;
        self.emit(format!(
            "pure (if {} then some {tuple} else none)",
            paren(&gt)
        ));
        self.indent -= 2;
        self.emit("| _ => pure none");
        self.indent -= 2;
        // The body with the arm's bindings, or the remaining arms.
        self.push_scope(ScopeKind::Block);
        let body = self.branch(|b| {
            b.bind_arm(binds.clone());
            b.expr(&arm.body, expect)
        });
        self.scopes.pop();
        let (v, lines) = body?;
        let (ev, el) =
            self.branch(|b| b.arms_rest(s, sty, place, rest, expect.or(Some(&v.ty)), want))?;
        let ty = if v.term.is_some() {
            v.ty.clone()
        } else {
            ev.ty.clone()
        };
        let has_value = want && !self.resolve(&ty).is_unit() && !matches!(ty, Ty::Never);
        let t = if has_value { Some(self.temp()) } else { None };
        match &t {
            Some(t) => self.emit(format!("let {t} ← match {g} with")),
            None => self.emit(format!("match {g} with")),
        }
        let extra = if t.is_some() { 2 } else { 0 };
        self.indent += extra;
        self.emit(format!("| some {} =>", paren(&tuple_pat)));
        self.emit_branch(&v, lines, 2, has_value);
        self.emit("| none =>");
        self.emit_branch(&ev, el, 2, has_value);
        self.indent -= extra;
        let reaches = v.term.is_some() || ev.term.is_some();
        match t {
            Some(t) if reaches => Ok(V::of(t, ty)),
            _ if reaches => Ok(V::of("()", Ty::Unit)),
            _ => Ok(V::never()),
        }
    }

    /// Patterns of one arm (or-patterns become alternatives sharing bindings).
    fn arm_patterns(
        &mut self,
        p: &Pat,
        ty: &Ty,
        place: Option<&Place>,
    ) -> R<(Vec<String>, Vec<Binding>)> {
        let alts: Vec<&Pat> = match p {
            Pat::Or(o) => o.cases.iter().collect(),
            p => vec![p],
        };
        let mut binds = vec![];
        let mut pats = vec![];
        for a in alts {
            pats.push(self.pat(a, ty, &mut binds)?);
        }
        if let Some(place) = place {
            // `Some(x)` against a `&mut Option<T>` borrows the payload.
            if let (Pat::TupleStruct(ts), Ty::Option(_)) = (p, self.resolve(ty).peel()) {
                if path_names(&ts.path).last().is_some_and(|n| n == "Some") {
                    if let Some(b) = binds.first_mut() {
                        let mut target = place.clone();
                        target.projs.push(Proj::Some_);
                        b.alias = Some(target);
                        b.mutable = true;
                    }
                }
            }
        }
        // A binding of a struct that borrows the matched call's place.
        if let Some(target) = self.result_borrow.clone() {
            for b in &mut binds {
                if let Some(f) = self.borrow_field(&b.ty) {
                    b.field_aliases = vec![(f, target.clone())];
                    b.mutable = true;
                }
            }
        }
        // Bindings that are borrowed mutably must be mutable Lean locals.
        for b in &mut binds {
            if b.alias.is_some() {
                b.mutable = true;
            }
        }
        // Mutable bindings are rebound with `let mut` at the start of the arm.
        Ok((pats, binds))
    }

    fn for_(&mut self, f: &syn::ExprForLoop) -> R<V> {
        if f.label.is_some() {
            return Err("labeled loops are unsupported".into());
        }
        // `for x in &mut place` and `for x in place.iter_mut()` borrow each element.
        let mut_source = match strip(&f.expr) {
            Expr::Reference(r) if r.mutability.is_some() => Some((*r.expr).clone()),
            Expr::MethodCall(m) if m.method == "iter_mut" && m.args.is_empty() => {
                Some((*m.receiver).clone())
            }
            _ => None,
        };
        if let Some(src) = &mut_source {
            if !has_jump(&f.body) {
                return self.for_map(f, src);
            }
        }
        if let Some(src) = mut_source {
            let place = self.place(&src)?.ok_or("iter_mut over a non-place")?;
            let Pat::Ident(pi) = &*f.pat else {
                return Err("for over borrowed elements needs a simple binding".into());
            };
            let cur = self.read_place(&place)?;
            let et = elem_ty(&self.resolve(&place.ty))?;
            let i = self.synthetic("i");
            let (lo, len) = match place.projs.last() {
                Some(Proj::Range(lo, hi)) => (
                    lo.clone(),
                    if lo == "0" {
                        format!("({} : Rust.usize).val", paren(hi))
                    } else {
                        format!(
                            "(({} : Rust.usize).val - ({} : Rust.usize).val)",
                            paren(hi),
                            paren(lo)
                        )
                    },
                ),
                _ => ("0".to_owned(), format!("{}.size", paren(&cur))),
            };
            let len = if matches!(place.projs.last(), Some(Proj::Range(..))) {
                len
            } else {
                match self.resolve(&place.ty) {
                    Ty::Array(_, l) => self.cx.names.len(&l),
                    _ => len,
                }
            };
            let mut base = place.clone();
            if matches!(base.projs.last(), Some(Proj::Range(..))) {
                base.projs.pop();
            }
            self.emit(format!("for {i} in List.range {len} do"));
            self.indent += 2;
            self.push_scope(ScopeKind::Loop);
            let idx = if lo == "0" {
                format!("(Rust.usizeOf {i})")
            } else {
                format!("(Rust.usizeOf (({} : Rust.usize).val + {i}))", paren(&lo))
            };
            let mut elem = base.clone();
            elem.projs.push(Proj::Index(idx));
            elem.ty = et.clone();
            let curv = self.read_place(&elem)?;
            let name = self.fresh(&pi.ident.to_string());
            self.emit(format!("let mut {name} := {curv}"));
            let mut l = Body::local(name, et, true);
            l.alias = Some(elem);
            self.declare(&pi.ident.to_string(), l);
            let v = self.block(&f.body, None)?;
            if v.term.is_some() && self.out.last().is_some_and(|(_, l)| l.ends_with(" do")) {
                self.emit("pure ()");
            }
            self.scopes.pop();
            self.indent -= 2;
            return Ok(V::of("()", Ty::Unit));
        }
        let (src, item) = self.iterable(&f.expr)?;
        // Literal items are typed by their uses in the body, as for `let`.
        let item = self.fresh_lits(&item);
        let (lean_pat, mut binds) = self.pattern(&f.pat, &item, false)?;
        self.emit(format!("for {lean_pat} in {} do", paren(&src)));
        self.indent += 2;
        self.push_scope(ScopeKind::Loop);
        for b in &mut binds {
            // A deferred item is produced when the loop pulls it.
            if let Ty::Lazy(t) = self.resolve(&b.ty) {
                self.impure = true;
                let m = if b.mutable { "mut " } else { "" };
                self.emit(format!("let {m}{} ← {}", b.lean, b.lean));
                b.ty = *t;
            } else if b.mutable {
                self.emit(format!("let mut {} := {}", b.lean, b.lean));
            }
        }
        self.bind_all(binds);
        let start = self.out.len();
        let v = self.block(&f.body, None)?;
        if self.out.len() == start && v.term.is_some() {
            self.emit("pure ()");
        }
        self.scopes.pop();
        self.indent -= 2;
        Ok(V::of("()", Ty::Unit))
    }

    /// `for x in &mut place { body }` whose body only updates `x` (no jumps):
    /// a map of the body over the borrowed elements, in order.
    fn for_map(&mut self, f: &syn::ExprForLoop, src: &Expr) -> R<V> {
        let Pat::Ident(pi) = &*f.pat else {
            return Err("for over borrowed elements needs a simple binding".into());
        };
        let (base, range) = match strip(src) {
            Expr::Index(ix) if matches!(&*ix.index, Expr::Range(_)) => {
                let base = self.place(&ix.expr)?.ok_or("iter_mut over a non-place")?;
                let Expr::Range(r) = &*ix.index else {
                    unreachable!()
                };
                let lo = match &r.start {
                    Some(e) => self.value(e, Some(&Ty::usize()))?.0,
                    None => "0".into(),
                };
                let cur = self.read_place(&base)?;
                let hi = match self.range_end(r)? {
                    Some(hi) => hi,
                    None => match self.resolve(&base.ty).peel() {
                        Ty::Slice(_) => format!("(Rust.usizeOf {}.size)", paren(&cur)),
                        _ => format!("(Rust.Slice.len {})", paren(&cur)),
                    },
                };
                (base, Some((lo, hi)))
            }
            _ => (self.place(src)?.ok_or("iter_mut over a non-place")?, None),
        };
        let vector = self.read_place(&base)?;
        let bt = self.resolve(&base.ty);
        let et = elem_ty(&bt)?;
        // The body as a closure from the element's old value to its new one.
        self.push_scope(ScopeKind::Closure);
        let rust = pi.ident.to_string();
        let x = self.fresh(&rust);
        let mut xl = Body::local(x.clone(), et.clone(), true);
        xl.mut_ref = true;
        self.declare(&rust, xl);
        self.closure_rets.push(Ty::Unit);
        let saved = std::mem::replace(&mut self.impure, false);
        let r = self.capture(|s| s.block(&f.body, None));
        let impure = std::mem::replace(&mut self.impure, saved);
        self.closure_rets.pop();
        self.scopes.pop();
        let (_, lines) = r?;
        let g = self.synthetic("f");
        let run = if impure { "" } else { "Id.run " };
        self.emit(format!("let {g} := fun {x} => {run}do"));
        self.indent += 2;
        self.emit(format!("let mut {x} := {x}"));
        self.splice(lines, 0);
        self.emit(format!("pure {x}"));
        self.indent -= 2;
        let monadic = if impure {
            g.clone()
        } else {
            format!("(fun e => pure ({g} e))")
        };
        let slice = matches!(bt.peel(), Ty::Slice(_));
        let new = match (&range, slice, impure) {
            (None, false, false) => format!("{}.map {g}", paren(&vector)),
            (None, _, _) => self.bind(format!("{}.mapM {monadic}", paren(&vector))),
            (Some((lo, hi)), false, _) => self.bind(format!(
                "Rust.Slice.mapRangeM {} {} {} {monadic}",
                paren(&vector),
                paren(lo),
                paren(hi)
            )),
            (Some((lo, hi)), true, _) => self.bind(format!(
                "Rust.Slice.mapRangeMA {} {} {} {monadic}",
                paren(&vector),
                paren(lo),
                paren(hi)
            )),
        };
        self.write_place(&base, new)?;
        Ok(V::of("()", Ty::Unit))
    }

    /// The exclusive end of a slice-index range, if bounded: `..hi` is `hi`,
    /// and `..=hi` is `hi + 1`, which panics at `usize::MAX` as Rust's
    /// slice indexing does.
    fn range_end(&mut self, r: &syn::ExprRange) -> R<Option<String>> {
        let Some(e) = &r.end else {
            return Ok(None);
        };
        let hi = self.value(e, Some(&Ty::usize()))?.0;
        Ok(Some(match r.limits {
            syn::RangeLimits::HalfOpen(_) => hi,
            syn::RangeLimits::Closed(_) => self.bind(format!("Rust.add {} 1", paren(&hi))),
        }))
    }

    /// The list a `for` loop iterates and its item type.
    fn iterable(&mut self, e: &Expr) -> R<(String, Ty)> {
        if let Expr::Range(r) = strip(e) {
            let lo = match &r.start {
                Some(s) => self.value(s, Some(&Ty::usize()))?,
                None => return Err("open range in for loop".into()),
            };
            let hi = match &r.end {
                Some(s) => self.value(s, Some(&lo.1))?,
                None => return Err("unbounded range in for loop".into()),
            };
            self.unify(&lo.1, &hi.1);
            let mut ty = self.resolve(&lo.1);
            if matches!(ty, Ty::IntLit) {
                ty = self.resolve(&hi.1);
            }
            if matches!(r.limits, syn::RangeLimits::Closed(_)) {
                return Err("inclusive ranges are unsupported".into());
            }
            return Ok((
                format!("Rust.Iter.range {} {}", paren(&lo.0), paren(&hi.0)),
                ty,
            ));
        }
        let (t, ty) = self.value(e, None)?;
        self.as_list(t, &ty)
    }

    /// View a value as the list of items it yields when iterated.
    pub fn as_list(&mut self, t: String, ty: &Ty) -> R<(String, Ty)> {
        match self.resolve(ty).peel() {
            Ty::Iter(i) => Ok((t, (**i).clone())),
            Ty::Array(i, _) => Ok((format!("{}.toList", paren(&t)), (**i).clone())),
            Ty::Slice(i) => Ok((format!("{}.toList", paren(&t)), (**i).clone())),
            Ty::Option(i) => Ok((format!("{}.toList", paren(&t)), (**i).clone())),
            other => Err(format!("not iterable: {other:?}")),
        }
    }

    fn while_(&mut self, w: &syn::ExprWhile) -> R<V> {
        if w.label.is_some() {
            return Err("labeled loops are unsupported".into());
        }
        if let Expr::Let(l) = &*w.cond {
            // `while let p = e { body }`: loop { match e { p => body, _ => break } }.
            self.impure = true;
            self.emit("repeat");
            self.indent += 2;
            self.push_scope(ScopeKind::Loop);
            let arms = vec![
                Arm {
                    pat: (*l.pat).clone(),
                    guard: None,
                    body: Expr::Block(syn::ExprBlock {
                        attrs: vec![],
                        label: None,
                        block: w.body.clone(),
                    }),
                },
                Arm {
                    pat: syn::parse_quote!(_),
                    guard: None,
                    body: syn::parse_quote!(break),
                },
            ];
            self.match_arms(&l.expr, &arms, None, false)?;
            self.scopes.pop();
            self.indent -= 2;
            return Ok(V::of("()", Ty::Unit));
        }
        // Loops can diverge: the function runs in Rust.M.
        self.impure = true;
        let ((c, _), lines) = self.capture(|s| s.value(&w.cond, Some(&Ty::Bool)))?;
        if lines.is_empty() {
            self.emit(format!("while {c} do"));
            self.indent += 2;
        } else {
            self.emit("repeat");
            self.indent += 2;
            self.splice(lines, 0);
            self.emit(format!("if !{} then break", paren(&c)));
        }
        self.push_scope(ScopeKind::Loop);
        let start = self.out.len();
        let v = self.block(&w.body, None)?;
        if self.out.len() == start && v.term.is_some() {
            self.emit("pure ()");
        }
        self.scopes.pop();
        self.indent -= 2;
        Ok(V::of("()", Ty::Unit))
    }

    fn loop_(&mut self, l: &syn::ExprLoop) -> R<V> {
        if l.label.is_some() {
            return Err("labeled loops are unsupported".into());
        }
        self.impure = true;
        self.emit("repeat");
        self.indent += 2;
        self.push_scope(ScopeKind::Loop);
        self.block(&l.body, None)?;
        self.scopes.pop();
        self.indent -= 2;
        Ok(V::of("()", Ty::Unit))
    }

    // -------------------------------------------------------------- literals

    fn struct_lit(&mut self, s: &syn::ExprStruct, expect: Option<&Ty>) -> R<V> {
        let names = path_names(&s.path);
        let mut ty = self.struct_or_variant_ty(&s.path, expect)?;
        let (ctor, decl, fields) = self.ctor(&s.path, &ty)?;
        let mut terms: Vec<(String, String)> = vec![];
        for f in &s.fields {
            let n = match &f.member {
                syn::Member::Named(n) => n.to_string(),
                syn::Member::Unnamed(i) => format!("_{}", i.index),
            };
            let fty = fields
                .iter()
                .find(|(m, _)| *m == n)
                .map(|(_, t)| t.clone())
                .ok_or_else(|| format!("no field {n} in {}", names.join("::")))?;
            if matches!(&f.expr, Expr::Reference(r) if r.mutability.is_some()) {
                return Err("struct literals holding &mut borrows must be bound by let".into());
            }
            // A function-typed field holds the monadic form of its closure.
            if let Ty::Fn(a, r) = self.resolve(&fty).peel().clone() {
                let fa = self.fn_arg(&f.expr, &a, Some(*r))?;
                terms.push((n, paren(&fa.monadic())));
                continue;
            }
            let (t, vt) = self.value(&f.expr, Some(&fty))?;
            self.unify(&fty, &vt);
            terms.push((n, t));
        }
        if decl {
            let tyname = self.lean_ty(&ty);
            if let Some(base) = &s.rest {
                let (b, bt) = self.value(base, Some(&ty))?;
                ty = bt;
                let parts: Vec<String> = terms
                    .iter()
                    .map(|(n, t)| format!("{} := {t}", self.field_lean(&ty, n)))
                    .collect();
                return Ok(V::of(format!("{{ {b} with {} }}", parts.join(", ")), ty));
            }
            let parts: Vec<String> = fields
                .iter()
                .map(|(n, _)| {
                    let t = terms
                        .iter()
                        .find(|(m, _)| m == n)
                        .map(|(_, t)| t.clone())
                        .ok_or_else(|| format!("missing field {n}"))?;
                    Ok(format!("{} := {t}", self.field_lean(&ty, n)))
                })
                .collect::<R<_>>()?;
            if tyname.contains('?') {
                return Ok(V::of(format!("{{ {} }}", parts.join(", ")), ty));
            }
            return Ok(V::of(
                format!("({{ {} }} : {tyname})", parts.join(", ")),
                ty,
            ));
        }
        // Enum variant with named fields: positional constructor arguments.
        let args: Vec<String> = fields
            .iter()
            .map(|(n, _)| {
                terms
                    .iter()
                    .find(|(m, _)| m == n)
                    .map(|(_, t)| paren(t))
                    .ok_or_else(|| format!("missing field {n}"))
            })
            .collect::<R<_>>()?;
        Ok(V::of(format!("{ctor} {}", args.join(" ")), ty))
    }

    fn field_lean(&self, ty: &Ty, n: &str) -> String {
        match self.resolve(ty).peel() {
            Ty::Adt(p, ..) if self.cx.k.structs.get(p).is_some_and(|s| s.tuple) => {
                format!("f{}", &n[1..])
            }
            _ => ident(n),
        }
    }

    pub(super) fn struct_or_variant_ty(&self, path: &syn::Path, expect: Option<&Ty>) -> R<Ty> {
        let names = path_names(path);
        if names == ["Self"] {
            return self
                .self_ty
                .clone()
                .ok_or_else(|| "Self outside impl".into());
        }
        let resolved = if names[0] == "Self" {
            let Some(Ty::Adt(p, ..)) = &self.self_ty else {
                return Err("Self outside impl".into());
            };
            format!("{p}::{}", names[1..].join("::"))
        } else {
            self.cx
                .k
                .resolve(&self.module, &names)
                .ok_or_else(|| format!("unresolved {}", names.join("::")))?
        };
        let adt = if self.cx.k.structs.contains_key(&resolved) {
            resolved.clone()
        } else {
            resolved
                .rsplit_once("::")
                .map(|(e, _)| e.to_owned())
                .unwrap_or_default()
        };
        if let Some(Ty::Adt(p, t, l)) = expect
            .map(|t| self.resolve(t))
            .as_ref()
            .map(|t| t.peel().clone())
        {
            if p == adt {
                return Ok(Ty::Adt(p, t, l));
            }
        }
        if let Some(Ty::Adt(p, t, l)) = &self.self_ty {
            if *p == adt {
                return Ok(Ty::Adt(p.clone(), t.clone(), l.clone()));
            }
        }
        let generics = self
            .cx
            .k
            .structs
            .get(&adt)
            .map(|s| s.generics.clone())
            .or_else(|| self.cx.k.enums.get(&adt).map(|e| e.generics.clone()))
            .ok_or_else(|| format!("{adt} is not a type"))?;
        let mut g = Generics::default();
        g.extend(&generics)?;
        Ok(Ty::Adt(
            adt,
            g.types.iter().map(|t| Ty::Param(format!("?{t}"))).collect(),
            g.consts
                .iter()
                .map(|c| Len::Param(format!("?{c}")))
                .collect(),
        ))
    }

    // ------------------------------------------------------------- closures

    /// Translate a closure. Its purity is recorded in `last_closure_pure`.
    pub fn closure(&mut self, c: &syn::ExprClosure, expect: Option<&Ty>) -> R<V> {
        let (arg_tys, ret_hint) = match expect.map(|t| self.resolve(t)) {
            Some(Ty::Fn(a, r)) => (a, Some(*r)),
            _ => (vec![], None),
        };
        self.closure_with(c, &arg_tys, ret_hint)
    }

    pub fn closure_with(
        &mut self,
        c: &syn::ExprClosure,
        arg_tys: &[Ty],
        ret_hint: Option<Ty>,
    ) -> R<V> {
        self.push_scope(ScopeKind::Closure);
        let mut params = vec![];
        let mut tys = vec![];
        for (i, p) in c.inputs.iter().enumerate() {
            let ty = match p {
                Pat::Type(t) => self.tys().ty(&t.ty)?,
                _ => arg_tys
                    .get(i)
                    .cloned()
                    .ok_or("closure parameter type unknown")?,
            };
            let inner = match p {
                Pat::Type(t) => &*t.pat,
                p => p,
            };
            let (lp, binds) = self.pattern(inner, &ty, false)?;
            params.push(lp);
            tys.push(ty);
            self.bind_all(binds);
        }
        let ret = match &c.output {
            syn::ReturnType::Type(_, t) => Some(self.tys().ty(t)?),
            _ => ret_hint,
        };
        self.closure_rets.push(ret.clone().unwrap_or(Ty::Unit));
        let saved_impure = std::mem::replace(&mut self.impure, false);
        let r = self.capture(|s| s.value_v(&c.body, ret.as_ref()));
        let body_impure = std::mem::replace(&mut self.impure, saved_impure);
        self.closure_rets.pop();
        self.scopes.pop();
        let (v, lines) = r?;
        let rt = v.ty.clone();
        let binders = if params.is_empty() {
            "_".to_owned()
        } else {
            params
                .iter()
                .map(|p| paren(p))
                .collect::<Vec<_>>()
                .join(" ")
        };
        let term = match (&v.term, body_impure, lines.is_empty()) {
            (Some(t), false, true) => format!("(fun {binders} => {t})"),
            _ => {
                // A closure with statements is bound to a name first, so its
                // do-block has a fixed layout.
                let name = self.synthetic("f");
                let run = if body_impure { "" } else { "Id.run " };
                self.emit(format!("let {name} := fun {binders} => {run}do"));
                self.splice(lines, 2);
                if let Some(t) = &v.term {
                    self.indent += 2;
                    self.emit(format!("pure {}", paren(t)));
                    self.indent -= 2;
                }
                name
            }
        };
        self.last_closure_pure.set(Some(!body_impure));
        Ok(V::of(term, Ty::Fn(tys, Box::new(rt))))
    }
}

#[derive(Clone)]
pub struct Binding {
    pub rust: String,
    pub lean: String,
    pub ty: Ty,
    pub mutable: bool,
    pub alias: Option<Place>,
    pub field_aliases: Vec<(String, Place)>,
}

struct Arm {
    pat: Pat,
    guard: Option<Expr>,
    body: Expr,
}

enum Fields {
    Positional(Vec<Pat>),
    Named(Vec<(String, Pat)>),
}

/// Whether a block contains `break`, `continue`, `return` or `?` (outside closures).
pub(super) fn has_jump(b: &syn::Block) -> bool {
    struct J(bool);
    impl<'ast> syn::visit::Visit<'ast> for J {
        fn visit_expr_break(&mut self, _: &'ast syn::ExprBreak) {
            self.0 = true;
        }
        fn visit_expr_continue(&mut self, _: &'ast syn::ExprContinue) {
            self.0 = true;
        }
        fn visit_expr_return(&mut self, _: &'ast syn::ExprReturn) {
            self.0 = true;
        }
        fn visit_expr_try(&mut self, _: &'ast syn::ExprTry) {
            self.0 = true;
        }
        fn visit_expr_closure(&mut self, _: &'ast syn::ExprClosure) {}
    }
    let mut j = J(false);
    syn::visit::Visit::visit_block(&mut j, b);
    j.0
}

fn strip(e: &Expr) -> &Expr {
    match e {
        Expr::Paren(p) => strip(&p.expr),
        Expr::Group(g) => strip(&g.expr),
        e => e,
    }
}

pub fn elem_ty(t: &Ty) -> R<Ty> {
    match t.peel() {
        Ty::Array(e, _) | Ty::Slice(e) => Ok((**e).clone()),
        t => Err(format!("indexing non-array {t:?}")),
    }
}

/// Component `i` of an `n`-tuple, which Lean nests to the right.
pub fn tuple_get(t: &str, i: usize, n: usize) -> String {
    let mut s = paren(t);
    for _ in 0..i {
        s = format!("{s}.2");
    }
    if i + 1 < n {
        s = format!("{s}.1");
    }
    s
}

fn binding_tuple(binds: &[Binding]) -> (String, String) {
    match binds.len() {
        0 => ("()".into(), "()".into()),
        1 => (binds[0].lean.clone(), binds[0].lean.clone()),
        _ => {
            let names: Vec<String> = binds.iter().map(|b| b.lean.clone()).collect();
            (
                format!("({})", names.join(", ")),
                format!("({})", names.join(", ")),
            )
        }
    }
}

/// Lexicographic comparison of equal-length tuples.
fn lex(op: &syn::BinOp, l: &[String], r: &[String]) -> String {
    use syn::BinOp::*;
    let (strict, last) = match op {
        Lt(_) => ("<", "<"),
        Le(_) => ("<", "≤"),
        Gt(_) => (">", ">"),
        _ => (">", "≥"),
    };
    let mut s = format!(
        "decide ({} {last} {})",
        paren(&l[l.len() - 1]),
        paren(&r[r.len() - 1])
    );
    for i in (0..l.len() - 1).rev() {
        s = format!(
            "(decide ({a} {strict} {b}) || ({a} == {b} && {s}))",
            a = paren(&l[i]),
            b = paren(&r[i])
        );
    }
    s
}

pub fn function_generics(f: &Function) -> R<Generics> {
    let mut g = Generics::default();
    g.extend(&f.impl_generics)?;
    g.extend(&f.sig.generics)?;
    Ok(g)
}
