//! Lean naming and type rendering for the typed backend.
use super::load::Krate;
use super::types::{Len, Ty};
use std::collections::BTreeMap;

const KEYWORDS: &[&str] = &[
    "at",
    "by",
    "do",
    "else",
    "end",
    "fun",
    "if",
    "in",
    "let",
    "match",
    "then",
    "with",
    "from",
    "have",
    "show",
    "where",
    "deriving",
    "instance",
    "structure",
    "class",
    "inductive",
    "theorem",
    "def",
    "namespace",
    "section",
    "open",
    "import",
    "export",
    "local",
    "private",
    "protected",
    "partial",
    "unsafe",
    "macro",
    "syntax",
    "notation",
    "infix",
    "infixl",
    "infixr",
    "prefix",
    "postfix",
    "mutual",
    "variable",
    "universe",
    "example",
    "abbrev",
    "opaque",
    "axiom",
    "calc",
    "for",
    "unless",
    "return",
    "try",
    "catch",
    "finally",
    "break",
    "continue",
    "mut",
    "Type",
    "Prop",
    "Sort",
    "forall",
    "exists",
    "this",
    "omit",
    "include",
    "termination_by",
    "decreasing_by",
    "nomatch",
    "nofun",
    "suffices",
    "obtain",
    "fun",
    "λ",
    "rec",
    "ext",
];

/// A Lean identifier for a Rust identifier.
pub fn ident(s: &str) -> String {
    if KEYWORDS.contains(&s) {
        format!("«{s}»")
    } else {
        s.to_owned()
    }
}

/// Lean names for every crate item, chosen once per crate.
pub struct Names {
    /// Crate type path to Lean type name.
    pub types: BTreeMap<String, String>,
    /// Crate function path to Lean function name.
    pub functions: BTreeMap<String, String>,
    /// Crate const path to Lean name.
    pub consts: BTreeMap<String, String>,
    /// Consumer trait path to its Lean class name.
    pub traits: BTreeMap<String, String>,
}

/// The module path a differential scenario is mounted at.
pub const MOUNT: &str = "provium_differential";

impl Names {
    pub fn new(k: &Krate) -> Self {
        // Items of a mounted differential scenario live in `Differential`, so
        // they never shadow the crate's or a consumer's names.
        let scoped = |p: &str, n: String| {
            if p.starts_with(&format!("{MOUNT}::")) {
                format!("Differential.{n}")
            } else {
                n
            }
        };
        let mut counts: BTreeMap<String, usize> = BTreeMap::new();
        let short = |p: &str| p.rsplit("::").next().unwrap().to_owned();
        for p in k
            .structs
            .keys()
            .chain(k.enums.keys())
            .chain(k.consts.keys())
        {
            *counts.entry(short(p)).or_default() += 1;
        }
        let name = |p: &str| {
            scoped(
                p,
                if counts[&short(p)] == 1 {
                    short(p)
                } else {
                    p.replace("::", "_")
                },
            )
        };
        let types: BTreeMap<_, _> = k
            .structs
            .keys()
            .chain(k.enums.keys())
            .map(|p| (p.clone(), name(p)))
            .collect();
        let consts = k.consts.keys().map(|p| (p.clone(), name(p))).collect();
        let mut functions = BTreeMap::new();
        let mut free: BTreeMap<String, usize> = BTreeMap::new();
        for f in k.functions.values() {
            if f.owner.is_none() {
                *free.entry(f.name.clone()).or_default() += 1;
            }
        }
        let mut taken = std::collections::BTreeSet::new();
        for (path, f) in &k.functions {
            let lean = match &f.owner {
                Some(owner) => {
                    let ty = &types[owner];
                    let fields = k
                        .structs
                        .get(owner)
                        .map(|s| s.fields.iter().any(|(n, _)| n == &f.name));
                    let mut method = ident(&f.name);
                    if fields == Some(true) {
                        method = format!("{}_fn", f.name);
                    }
                    let mut candidate = format!("{ty}.{method}");
                    let mut i = 2;
                    while taken.contains(&candidate) {
                        candidate = format!("{ty}.{}_{i}", f.name);
                        i += 1;
                    }
                    candidate
                }
                None if free[&f.name] == 1 => scoped(path, ident(&f.name)),
                None => scoped(path, path.replace("::", "_")),
            };
            taken.insert(lean.clone());
            functions.insert(path.clone(), lean);
        }
        let traits = k
            .traits
            .keys()
            .map(|p| {
                (
                    p.clone(),
                    scoped(p, p.rsplit("::").next().unwrap().to_owned()),
                )
            })
            .collect();
        Names {
            types,
            functions,
            consts,
            traits,
        }
    }

    pub fn len(&self, l: &Len) -> String {
        match l {
            Len::Lit(n) => n.to_string(),
            Len::Param(p) if p.starts_with('?') => "_".into(),
            Len::Param(p) => ident(p),
            Len::Const(c) => self.consts[c].clone(),
        }
    }

    pub fn ty(&self, t: &Ty) -> String {
        match t {
            Ty::Bool => "Bool".into(),
            Ty::Uint(_, n) | Ty::Int(_, n) => format!("Rust.{n}"),
            Ty::IntLit | Ty::IntVar(_) => "Rust.usize".into(),
            Ty::Unit | Ty::Never => "Unit".into(),
            Ty::Str => "String".into(),
            Ty::Tuple(v) => format!(
                "({})",
                v.iter().map(|t| self.ty(t)).collect::<Vec<_>>().join(" × ")
            ),
            Ty::Array(t, l) => format!("(Vector {} {})", self.ty(t), self.len(l)),
            Ty::Slice(t) => format!("(Array {})", self.ty(t)),
            Ty::Ref(_, t) => self.ty(t),
            Ty::Adt(p, a, l) => {
                let mut s = self.types[p].clone();
                if a.is_empty() && l.is_empty() {
                    return s;
                }
                for t in a {
                    s.push(' ');
                    s.push_str(&self.ty(t));
                }
                for l in l {
                    s.push(' ');
                    s.push_str(&self.len(l));
                }
                format!("({s})")
            }
            Ty::Option(t) => format!("(Option {})", self.ty(t)),
            Ty::Result(a, b) => format!("(Rust.Result {} {})", self.ty(a), self.ty(b)),
            Ty::Param(p) if p.starts_with('?') && !p.starts_with("?INT") => "_".into(),
            Ty::Param(p) => ident(p),
            Ty::Iter(t) => format!("(List {})", self.ty(t)),
            Ty::Lazy(t) => format!("(Rust.M {})", self.ty(t)),
            Ty::Fn(a, r) => {
                let mut s = String::from("(");
                for t in a {
                    s.push_str(&self.ty(t));
                    s.push_str(" → ");
                }
                if a.is_empty() {
                    s.push_str("Unit → ");
                }
                s.push_str(&format!("Rust.M {})", self.ty(r)));
                s
            }
            Ty::TryFromIntError => "Rust.TryFromIntError".into(),
            Ty::Formatter => "Rust.Formatter".into(),
            Ty::Assoc(param, tr, args, name) => {
                let mut s = format!("({}.{name}", self.traits[tr]);
                for (n, t) in args {
                    s.push_str(&format!(" ({} := {})", ident(n), self.ty(t)));
                }
                s.push_str(&format!(" (Self := {}))", ident(param)));
                s
            }
            Ty::Future(t) => format!("(Rust.M {})", self.ty(t)),
            Ty::Budget => "Nat".into(),
            Ty::Run(t) => format!("(Rust.Run {})", self.ty(t)),
            Ty::FmtError => "Rust.FmtError".into(),
        }
    }
}
