//! Cross-check the typed front end against rustc. The front end resolves
//! names and infers local types itself (with `syn`); rustc's MIR for the same
//! build records both. For every translated function this compares the crate
//! functions it calls and the type of every source-named local with the MIR.
use super::gen::Facts;
use super::load::{Function, Krate};
use super::types::{Len, Ty};
use std::collections::{BTreeMap, BTreeSet};

/// One MIR body, with its closures' bodies folded in.
#[derive(Default, Debug)]
pub struct MirFn {
    /// `debug name => _n` bindings with rustc's (normalized) type.
    pub locals: BTreeMap<String, BTreeSet<String>>,
    /// Callee paths as rustc prints them.
    pub callees: BTreeSet<String>,
}

/// MIR functions keyed by `(file, impl line or 0, function name)` for
/// associated functions and `(module path, 0, name)` for free functions.
pub type MirKey = (String, usize, String);

/// Parse `--emit=mir` output.
pub fn parse(mir: &str) -> BTreeMap<MirKey, MirFn> {
    let mut out: BTreeMap<MirKey, MirFn> = BTreeMap::new();
    let mut lines = mir.lines().peekable();
    while let Some(line) = lines.next() {
        let Some(header) = line.strip_prefix("fn ") else {
            continue;
        };
        let Some(key) = header_key(header) else {
            continue;
        };
        let mut lets: BTreeMap<String, String> = BTreeMap::new();
        let mut debugs: Vec<(String, String)> = vec![];
        let mut callees = BTreeSet::new();
        // Parameters: `_1: T, _2: U`.
        if let Some(params) = header.find('(').map(|i| &header[i + 1..]) {
            let params = &params[..matching_close(params).unwrap_or(params.len())];
            for p in split_top(params, ',') {
                if let Some((slot, ty)) = p.trim().split_once(": ") {
                    lets.insert(slot.trim().to_owned(), ty.trim().to_owned());
                }
            }
        }
        for body in lines.by_ref() {
            if body == "}" {
                break;
            }
            let t = body.trim();
            if let Some(rest) = t.strip_prefix("debug ") {
                if let Some((name, slot)) = rest.trim_end_matches(';').split_once(" => ") {
                    if slot.starts_with('_') && !slot.contains('.') && !slot.contains('(') {
                        debugs.push((name.to_owned(), slot.to_owned()));
                    }
                }
            } else if let Some(rest) = t.strip_prefix("let ") {
                let rest = rest.trim_start_matches("mut ").trim_end_matches(';');
                if let Some((slot, ty)) = rest.split_once(": ") {
                    lets.insert(slot.to_owned(), ty.to_owned());
                }
            } else if let Some(callee) = call_target(t) {
                callees.insert(callee);
            }
        }
        let f = out.entry(key).or_default();
        for (name, slot) in debugs {
            if let Some(ty) = lets.get(&slot) {
                f.locals.entry(name).or_default().insert(normalize(ty));
            }
        }
        f.callees.extend(callees);
    }
    out
}

/// `state::<impl at jarl/src/state.rs:33:1: 33:46>::get(...)`, or a closure
/// `...::get::{closure#0}(...)` (keyed by its enclosing function), or a free
/// function `node::helper(...)`.
fn header_key(header: &str) -> Option<MirKey> {
    let name_end = header.find('(')?;
    let path = &header[..name_end];
    let path = match path.find("::{closure") {
        Some(i) => &path[..i],
        None => path,
    };
    if let Some(start) = path.find("<impl at ") {
        let rest = &path[start + "<impl at ".len()..];
        let close = rest.find('>')?;
        let loc = &rest[..close];
        let mut parts = loc.split(':');
        let file = parts.next()?.to_owned();
        let line: usize = parts.next()?.parse().ok()?;
        let name = rest[close + 1..].trim_start_matches("::");
        if name.contains("::") || name.is_empty() {
            return None;
        }
        return Some((file, line, name.to_owned()));
    }
    let (module, name) = path.rsplit_once("::").unwrap_or(("", path));
    Some((module.to_owned(), 0, name.to_owned()))
}

/// The index of the `)` closing an argument list whose `(` was just consumed.
fn matching_close(s: &str) -> Option<usize> {
    let mut depth = 0i32;
    let mut prev = ' ';
    for (i, c) in s.char_indices() {
        match c {
            '(' | '<' | '[' => depth += 1,
            ')' if depth == 0 => return Some(i),
            '>' if prev == '-' => {}
            ')' | '>' | ']' => depth -= 1,
            _ => {}
        }
        prev = c;
    }
    None
}

/// Split at `sep` outside brackets.
fn split_top(s: &str, sep: char) -> Vec<&str> {
    let mut out = vec![];
    let mut depth = 0i32;
    let mut start = 0;
    let mut prev = ' ';
    for (i, c) in s.char_indices() {
        let arrow = c == '>' && prev == '-';
        prev = c;
        match c {
            '>' if arrow => {}
            '(' | '<' | '[' => depth += 1,
            ')' | '>' | ']' => depth -= 1,
            c if c == sep && depth == 0 => {
                out.push(&s[start..i]);
                start = i + c.len_utf8();
            }
            _ => {}
        }
    }
    out.push(&s[start..]);
    out
}

/// The callee of a call terminator: `_5 = Type::<A>::m(move _6) -> [return: ...]`.
fn call_target(t: &str) -> Option<String> {
    let arrow = [") -> [", ") -> unwind", ") -> bb"]
        .iter()
        .filter_map(|m| t.rfind(m))
        .max()?;
    let lhs = match t.split_once(" = ") {
        Some((l, r)) if l.starts_with('_') && !l.contains(' ') => r,
        _ => t,
    };
    let end = arrow - (t.len() - lhs.len());
    let head = &lhs[..=end];
    // Walk back from the closing `)` to its `(`.
    let mut depth = 0i32;
    for (i, c) in head.char_indices().rev() {
        match c {
            ')' => depth += 1,
            '(' => {
                depth -= 1;
                if depth == 0 {
                    let callee = head[..i].trim();
                    if callee.is_empty() || callee.starts_with("move ") || callee.starts_with('_') {
                        return None;
                    }
                    return Some(callee.to_owned());
                }
            }
            _ => {}
        }
    }
    None
}

/// rustc's type text with references, lifetimes and module paths removed.
pub fn normalize(ty: &str) -> String {
    let mut s = String::new();
    let mut chars = ty.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '&' => {
                // `&'a mut T` / `&mut T` / `&T`: drop the reference.
                while chars.peek() == Some(&' ') {
                    chars.next();
                }
                if chars.peek() == Some(&'\'') {
                    while chars.peek().is_some_and(|c| *c != ' ') {
                        chars.next();
                    }
                    chars.next();
                }
                let rest: String = chars.clone().take(4).collect();
                if rest == "mut " {
                    for _ in 0..4 {
                        chars.next();
                    }
                }
            }
            '\'' => {
                // A lifetime argument `'_, ` or `'a`.
                while chars
                    .peek()
                    .is_some_and(|c| c.is_alphanumeric() || *c == '_')
                {
                    chars.next();
                }
                if chars.peek() == Some(&',') {
                    chars.next();
                }
            }
            _ => s.push(c),
        }
    }
    // Drop module paths: keep the last segment of each `a::b::C`.
    let mut out = String::new();
    let mut ident = String::new();
    let bytes: Vec<char> = s.chars().collect();
    let mut i = 0;
    while i < bytes.len() {
        let c = bytes[i];
        if c.is_alphanumeric() || c == '_' {
            ident.push(c);
            i += 1;
            continue;
        }
        if c == ':' && bytes.get(i + 1) == Some(&':') {
            ident.clear();
            i += 2;
            continue;
        }
        out.push_str(&ident);
        ident.clear();
        out.push(c);
        i += 1;
    }
    out.push_str(&ident);
    let out = out.replace(' ', "").replace("<>", "");
    // Array lengths print as `16_usize`.
    strip_usize_suffix(&out)
}

fn strip_usize_suffix(s: &str) -> String {
    let mut out = s.to_owned();
    while let Some(i) = out.find("_usize") {
        let digits = out[..i]
            .chars()
            .rev()
            .take_while(|c| c.is_ascii_digit())
            .count();
        if digits == 0 {
            break;
        }
        out.replace_range(i..i + "_usize".len(), "");
    }
    out
}

/// The translation's type in the same normal form, or `None` where the
/// translation's representation has no rustc counterpart to compare
/// (iterators, closures, deferred items).
pub fn rust_form(k: &Krate, t: &Ty) -> Option<String> {
    if format!("{t:?}").contains("\"?") {
        // An inference variable the translation left to Lean's elaborator.
        return None;
    }
    let len = |l: &Len| match l {
        Len::Lit(n) => n.to_string(),
        Len::Param(p) => p.clone(),
        Len::Const(c) => match &k.consts.get(c).map(|c| &c.expr) {
            Some(syn::Expr::Lit(syn::ExprLit {
                lit: syn::Lit::Int(i),
                ..
            })) => i.base10_digits().to_owned(),
            _ => c.rsplit("::").next().unwrap().to_owned(),
        },
    };
    Some(match t {
        Ty::Bool => "bool".into(),
        Ty::Uint(_, n) | Ty::Int(_, n) => (*n).to_owned(),
        Ty::Unit => "()".into(),
        Ty::Never => "!".into(),
        Ty::Str => "str".into(),
        Ty::Tuple(v) => {
            let parts = v
                .iter()
                .map(|t| rust_form(k, t))
                .collect::<Option<Vec<_>>>()?;
            if parts.len() == 1 {
                format!("({},)", parts[0])
            } else {
                format!("({})", parts.join(","))
            }
        }
        Ty::Array(t, l) => format!("[{};{}]", rust_form(k, t)?, len(l)),
        Ty::Slice(t) => format!("[{}]", rust_form(k, t)?),
        Ty::Ref(_, t) => rust_form(k, t)?,
        Ty::Adt(p, a, l) => {
            let short = p.rsplit("::").next().unwrap();
            let mut args = a
                .iter()
                .map(|t| rust_form(k, t))
                .collect::<Option<Vec<_>>>()?;
            args.extend(l.iter().map(len));
            if args.is_empty() {
                short.to_owned()
            } else {
                format!("{short}<{}>", args.join(","))
            }
        }
        Ty::Option(t) => format!("Option<{}>", rust_form(k, t)?),
        Ty::Result(a, b) => format!("Result<{},{}>", rust_form(k, a)?, rust_form(k, b)?),
        Ty::Param(p) if !p.starts_with('?') => p.clone(),
        Ty::TryFromIntError => "TryFromIntError".into(),
        // Unresolved literals default to i32, as in Rust.
        Ty::IntLit | Ty::IntVar(_) => "i32".into(),
        Ty::Param(_) | Ty::Iter(_) | Ty::Fn(..) | Ty::Lazy(_) => return None,
    })
}

/// The MIR key of a translated function.
fn key_of(f: &Function, crate_dir: &str) -> Option<MirKey> {
    match f.impl_line {
        Some(line) => {
            let file = f.file.to_string_lossy();
            let rel = file
                .strip_prefix(crate_dir)
                .map(|r| r.trim_start_matches('/').to_owned())
                .unwrap_or_else(|| file.into_owned());
            Some((rel, line, f.name.clone()))
        }
        None => {
            let module = f
                .module
                .trim_start_matches("crate")
                .trim_start_matches("::");
            Some((module.to_owned(), 0, f.name.clone()))
        }
    }
}

/// The crate function a MIR callee names, if any.
fn crate_callee(k: &Krate, callee: &str) -> Option<String> {
    // Remove turbofish generic arguments: `State::<V, S, CAP>::base` -> `State::base`.
    let mut plain = String::new();
    let mut depth = 0;
    let chars: Vec<char> = callee.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        if depth == 0
            && chars[i] == ':'
            && chars.get(i + 2) == Some(&'<')
            && chars.get(i + 1) == Some(&':')
        {
            depth = 1;
            i += 3;
            continue;
        }
        if depth > 0 {
            match chars[i] {
                '<' => depth += 1,
                '>' if i > 0 && chars[i - 1] == '-' => {}
                '>' => depth -= 1,
                _ => {}
            }
            i += 1;
            continue;
        }
        plain.push(chars[i]);
        i += 1;
    }
    if let Some(rest) = plain.strip_prefix('<') {
        // `<Type<A> as Trait<B>>::method`
        let (inner, method) = rest.rsplit_once(">::")?;
        let (ty, tr) = inner.split_once(" as ")?;
        let ty_short = normalize(ty);
        let ty_short = ty_short.split('<').next().unwrap();
        let tr_short = normalize(tr);
        let tr_short = tr_short.split('<').next().unwrap();
        return k
            .functions
            .values()
            .find(|f| {
                f.owner.as_deref().and_then(|o| o.rsplit("::").next()) == Some(ty_short)
                    && f.name == method
                    && f.trait_name.as_deref() == Some(tr_short)
            })
            .map(|f| f.path.clone());
    }
    let segs: Vec<&str> = plain.split("::").collect();
    let (method, owner) = (segs.last()?, segs.get(segs.len().wrapping_sub(2)));
    if let Some(owner) = owner {
        if let Some(f) = k.functions.values().find(|f| {
            f.owner.as_deref().and_then(|o| o.rsplit("::").next()) == Some(owner)
                && f.name == *method
                && f.trait_name.is_none()
        }) {
            return Some(f.path.clone());
        }
    }
    let module = segs[..segs.len() - 1].join("::");
    k.functions
        .values()
        .find(|f| {
            f.owner.is_none()
                && f.name == *method
                && f.module
                    .trim_start_matches("crate")
                    .trim_start_matches("::")
                    == module
        })
        .map(|f| f.path.clone())
}

/// What the cross-check compared, and what it found.
#[derive(Debug, Default)]
pub struct Outcome {
    pub problems: Vec<String>,
    /// Source-named locals whose types were compared.
    pub locals: usize,
    /// Locals whose translated type has no rustc counterpart (iterators,
    /// closures, deferred items, types left to Lean's elaborator).
    pub unchecked: usize,
    /// Crate calls compared.
    pub calls: usize,
}

/// Compare every translated function's facts with rustc's MIR.
pub fn check(
    k: &Krate,
    facts: &BTreeMap<String, Facts>,
    mir: &BTreeMap<MirKey, MirFn>,
    crate_dir: &str,
) -> Outcome {
    let mut out = Outcome::default();
    let mut problems = vec![];
    let base = |p: &str| p.split('#').next().unwrap().to_owned();
    for (path, fact) in facts {
        let Some(f) = k.functions.get(path) else {
            continue;
        };
        let Some(key) = key_of(f, crate_dir) else {
            problems.push(format!("{path}: no MIR key"));
            continue;
        };
        let Some(m) = mir.get(&key) else {
            problems.push(format!("{path}: no MIR body for {key:?}"));
            continue;
        };
        for (name, ty) in &fact.locals {
            let Some(ours) = rust_form(k, ty) else {
                out.unchecked += 1;
                continue;
            };
            out.locals += 1;
            match m.locals.get(name) {
                Some(theirs) if theirs.contains(&ours) => {}
                Some(theirs) => problems.push(format!(
                    "{path}: local `{name}` is {ours} in the translation but {theirs:?} in rustc"
                )),
                None => problems.push(format!("{path}: local `{name}` has no rustc counterpart")),
            }
        }
        let theirs: BTreeSet<String> = m
            .callees
            .iter()
            .filter_map(|c| crate_callee(k, c))
            .map(|p| base(&p))
            .collect();
        let ours: BTreeSet<String> = fact.calls.iter().map(|p| base(p)).collect();
        out.calls += theirs.union(&ours).count();
        for c in theirs.difference(&ours) {
            // Trait methods the translation reaches through an instance (a
            // hand-written `eq` or `clone`) are translated, just not called by
            // name.
            let via_instance =
                k.functions.get(c).is_some_and(|f| f.trait_name.is_some()) && facts.contains_key(c);
            if !via_instance {
                problems.push(format!("{path}: rustc calls {c}, the translation does not"));
            }
        }
        for c in ours.difference(&theirs) {
            // Destructors run as drop glue, not as calls.
            let drop = k
                .functions
                .get(c)
                .is_some_and(|f| f.trait_name.as_deref() == Some("Drop"));
            if !drop {
                problems.push(format!("{path}: the translation calls {c}, rustc does not"));
            }
        }
    }
    out.problems = problems;
    out
}
