//! `--emit=mir` text to [`Body`]s. See `Provium/Mir/Syntax.lean` for the
//! target and the module documentation for what comes from the sources.
use super::source::{Fields, Generic, Index, SourceMap, TypeKind};
use std::collections::{BTreeMap, BTreeSet};

use super::{
    AggKind, BinOp, Block, Body, Callee, Const, IntTy, Operand, PElem, Place, Rvalue, Stmt, Term,
    Ty, UnOp,
};

/// Parse every body of a MIR dump. Any unsupported construct is an error.
pub fn parse(text: &str, src: &SourceMap) -> Result<Vec<Body>, String> {
    let (bodies, errors) = parse_lenient(text, src)?;
    if errors.is_empty() {
        Ok(bodies)
    } else {
        Err(errors.join("\n"))
    }
}

/// Parse every body; a body with an unsupported construct is left out and
/// its error returned alongside the bodies that parsed. Errors in the dump's
/// structure, or in the sources, fail the whole parse.
pub fn parse_lenient(text: &str, src: &SourceMap) -> Result<(Vec<Body>, Vec<String>), String> {
    let raws = split_items(text)?;
    let ix = Index::build(src)?;
    let mut origins = vec![];
    let mut errors = vec![];
    for r in &raws {
        match origin(r, &raws, &ix, src) {
            Ok(o) => origins.push(Some(o)),
            Err(e) => {
                errors.push(format!("body `{}` (line {}): {e}", r.name, r.line));
                origins.push(None);
            }
        }
    }
    let res = Resolver {
        entries: raws
            .iter()
            .zip(&origins)
            .filter_map(|(r, o)| o.as_ref().map(|o| (r.name.clone(), o.clone())))
            .collect(),
    };
    // Closure types carry their defining function's generic parameters: the
    // closure body's `_1` names its span.
    let mut closures = BTreeMap::new();
    for (r, o) in raws.iter().zip(&origins) {
        let (Some(o), Some(p0)) = (o, r.params.first()) else {
            continue;
        };
        let last = split_top(&r.name, "::").last().copied().unwrap_or("");
        if !last.starts_with("{closure#") {
            continue;
        }
        let Some(i) = p0.find("{closure@") else {
            continue;
        };
        let Some(j) = matching(&p0[i..], 0) else {
            continue;
        };
        let args = o
            .tparams
            .iter()
            .map(|g| {
                if g.is_const {
                    Ty::Cparam(g.name.clone())
                } else {
                    Ty::Param(g.name.clone())
                }
            })
            .collect();
        closures.insert(
            p0[i + "{closure@".len()..i + j].to_owned(),
            (body_base(&r.name), args),
        );
    }
    let mut bodies = vec![];
    for (r, o) in raws.iter().zip(&origins) {
        let Some(o) = o else { continue };
        match body(r, o, &ix, &res, &closures).and_then(|mut b| {
            foreign_closures(&mut b, &closures)?;
            Ok(b)
        }) {
            Ok(b) => bodies.push(b),
            Err(e) => errors.push(format!("body `{}`: {e}", r.name)),
        }
    }
    let mut canon = Canon::new(&ix, &bodies);
    let mut out = vec![];
    for mut b in bodies {
        match canon.body(&mut b) {
            Ok(()) => out.push(b),
            Err(e) => errors.push(format!("body `{}`: {e}", b.name)),
        }
    }
    errors.extend(canon.finish());
    Ok((out, errors))
}

// ---------------------------------------------------------------------------
// Lexical helpers: bracket depth outside string and char literals.

/// For each byte offset, the bracket depth there (`None` inside a literal).
/// An opening bracket records the depth before it, a closing one the depth
/// after it, so a matched pair records the same depth. The `>` of `->` is
/// not a bracket.
fn depths(s: &str) -> Vec<Option<i32>> {
    let b = s.as_bytes();
    let mut out = vec![None; b.len() + 1];
    let mut depth = 0i32;
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'"' => {
                out[i] = Some(depth);
                i += 1;
                while i < b.len() && b[i] != b'"' {
                    if b[i] == b'\\' {
                        i += 1;
                    }
                    i += 1;
                }
                if i < b.len() {
                    out[i] = Some(depth);
                }
            }
            b'\'' if char_lit_len(&s[i..]).is_some() => {
                let n = char_lit_len(&s[i..]).unwrap();
                out[i] = Some(depth);
                i += n - 1;
                out[i] = Some(depth);
            }
            b'(' | b'[' | b'{' | b'<' => {
                out[i] = Some(depth);
                depth += 1;
            }
            b')' | b']' | b'}' => {
                depth -= 1;
                out[i] = Some(depth);
            }
            b'>' if i > 0 && b[i - 1] == b'-' => out[i] = Some(depth),
            b'>' => {
                depth -= 1;
                out[i] = Some(depth);
            }
            _ => out[i] = Some(depth),
        }
        i += 1;
    }
    out[b.len()] = Some(depth);
    out
}

/// The byte length of a char literal at the start of `s`, if it is one (and
/// not a lifetime).
fn char_lit_len(s: &str) -> Option<usize> {
    let rest = s.strip_prefix('\'')?;
    if let Some(esc) = rest.strip_prefix('\\') {
        let close = esc.find('\'')?;
        return Some(2 + close + 1);
    }
    let c = rest.chars().next()?;
    let after = &rest[c.len_utf8()..];
    after.starts_with('\'').then(|| 1 + c.len_utf8() + 1)
}

/// First byte offset of `pat` at depth 0.
fn find_top(s: &str, pat: &str) -> Option<usize> {
    let d = depths(s);
    (0..s.len()).find(|&i| d[i] == Some(0) && s.is_char_boundary(i) && s[i..].starts_with(pat))
}

/// Last byte offset of `pat` at depth 0.
fn rfind_top(s: &str, pat: &str) -> Option<usize> {
    let d = depths(s);
    (0..s.len())
        .rev()
        .find(|&i| d[i] == Some(0) && s.is_char_boundary(i) && s[i..].starts_with(pat))
}

/// Split at depth-0 occurrences of `sep`.
fn split_top<'a>(s: &'a str, sep: &str) -> Vec<&'a str> {
    let d = depths(s);
    let mut out = vec![];
    let mut start = 0;
    let mut i = 0;
    while i < s.len() {
        if d[i] == Some(0) && s.is_char_boundary(i) && s[i..].starts_with(sep) {
            out.push(&s[start..i]);
            i += sep.len();
            start = i;
        } else {
            i += 1;
        }
    }
    out.push(&s[start..]);
    out
}

/// The index of the bracket closing the one opened at `open`.
fn matching(s: &str, open: usize) -> Option<usize> {
    let d = depths(s);
    let b = s.as_bytes();
    let want = d[open]?;
    (open + 1..s.len()).find(|&j| {
        d[j] == Some(want)
            && matches!(b[j], b')' | b']' | b'}' | b'>')
            && !(b[j] == b'>' && j > 0 && b[j - 1] == b'-')
    })
}

/// `s` is one bracketed group starting at its first byte.
fn enclosed(s: &str) -> bool {
    !s.is_empty() && matching(s, 0) == Some(s.len() - 1)
}

/// Comma-separated items at depth 0, without a trailing empty item.
fn list(s: &str) -> Vec<&str> {
    if s.trim().is_empty() {
        return vec![];
    }
    let mut v: Vec<&str> = split_top(s, ",").into_iter().map(str::trim).collect();
    if v.last() == Some(&"") {
        v.pop();
    }
    v
}

fn is_ident(s: &str) -> bool {
    let mut c = s.chars();
    c.next().is_some_and(|c| c.is_alphabetic() || c == '_')
        && c.all(|c| c.is_alphanumeric() || c == '_')
}

fn local_index(s: &str) -> Option<usize> {
    let n = s.strip_prefix('_')?;
    (!n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
        .then(|| n.parse().ok())
        .flatten()
}

fn bb_index(s: &str) -> Result<usize, String> {
    s.strip_prefix("bb")
        .and_then(|n| n.parse().ok())
        .ok_or_else(|| format!("expected a basic block, found `{s}`"))
}

// ---------------------------------------------------------------------------
// Items of the dump.

/// One body's text.
struct RawBody<'a> {
    name: String,
    /// 1-based line of the header.
    line: usize,
    /// Parameter types `_1..` as printed in the header.
    params: Vec<String>,
    lines: Vec<(usize, &'a str)>,
}

fn split_items(text: &str) -> Result<Vec<RawBody<'_>>, String> {
    let lines: Vec<&str> = text.lines().collect();
    let mut out = vec![];
    let mut i = 0;
    let mut skip_next = false;
    while i < lines.len() {
        let line = lines[i].trim_end();
        let ln = i + 1;
        i += 1;
        if line.is_empty() {
            continue;
        }
        if line == "// MIR FOR CTFE" {
            skip_next = true;
            continue;
        }
        if line.starts_with("//") {
            continue;
        }
        // Allocation hex dumps: `alloc12 (size: 4, align: 1) {` .. `}`.
        if line.starts_with("alloc") && line.contains(" (size: ") && line.ends_with('{') {
            while i < lines.len() && lines[i].trim_end() != "}" {
                i += 1;
            }
            i += 1;
            continue;
        }
        let header = if let Some(h) = line.strip_prefix("fn ") {
            Some(fn_header(h).map_err(|e| format!("line {ln}: {e}"))?)
        } else if let Some(h) = line.strip_prefix("const ") {
            if line.ends_with(';') {
                // A constant item already evaluated (`const X: usize = const 16_usize;`):
                // its uses print the value, so there is no body.
                None
            } else {
                Some(const_header(h).map_err(|e| format!("line {ln}: {e}"))?)
            }
        } else if line.ends_with(" = {") && line.contains("::{constant#") {
            // An inline `const { .. }` block.
            Some(const_header(line).map_err(|e| format!("line {ln}: {e}"))?)
        } else {
            return Err(format!("line {ln}: unrecognised top-level line `{line}`"));
        };
        let Some((name, params)) = header else {
            continue;
        };
        let mut body = vec![];
        loop {
            let Some(l) = lines.get(i) else {
                return Err(format!("line {ln}: body `{name}` is not closed"));
            };
            i += 1;
            if l.trim_end() == "}" {
                break;
            }
            body.push((i, *l));
        }
        if std::mem::take(&mut skip_next) {
            continue;
        }
        out.push(RawBody {
            name,
            line: ln,
            params,
            lines: body,
        });
    }
    Ok(out)
}

type Header = (String, Vec<String>);

/// `path(_1: T, ..) -> R {`
fn fn_header(h: &str) -> Result<Header, String> {
    let open = find_top(h, "(").ok_or("no parameter list in header")?;
    let close = matching(h, open).ok_or("unbalanced header")?;
    let name = h[..open].to_owned();
    let mut params = vec![];
    for (k, p) in list(&h[open + 1..close]).into_iter().enumerate() {
        let (slot, ty) = p
            .split_once(": ")
            .ok_or_else(|| format!("parameter `{p}`"))?;
        if local_index(slot) != Some(k + 1) {
            return Err(format!("parameter `{p}` out of order"));
        }
        params.push(ty.to_owned());
    }
    h[close + 1..]
        .strip_prefix(" -> ")
        .and_then(|r| r.strip_suffix(" {"))
        .ok_or("header without `-> T {`")?;
    Ok((name, params))
}

/// `path: T = {`
fn const_header(h: &str) -> Result<Header, String> {
    let colon = find_top(h, ": ").ok_or("constant header without a type")?;
    h[colon + 2..]
        .strip_suffix(" = {")
        .ok_or("constant header without `= {`")?;
    Ok((h[..colon].to_owned(), vec![]))
}

// ---------------------------------------------------------------------------
// Where a body comes from: its impl or free function, and generics.

#[derive(Clone, Debug)]
struct Origin {
    /// Module path printed before the impl segment (`state`), empty otherwise.
    module: String,
    /// The impl's self type and trait (last path segments).
    self_name: Option<String>,
    trait_name: Option<String>,
    /// Segments after the impl segment (`grow`, `{closure#0}`); for a free
    /// function or constructor, all segments.
    rest: Vec<String>,
    /// A closure, promoted constant or inline constant.
    nested: bool,
    tparams: Vec<Generic>,
}

/// Derives whose methods have no generic parameters of their own.
const DERIVES: &[&str] = &[
    "Clone",
    "Copy",
    "Debug",
    "PartialEq",
    "Eq",
    "PartialOrd",
    "Ord",
    "Default",
];

fn is_suffix(seg: &str) -> bool {
    seg.starts_with("{closure#") || seg.starts_with("{constant#") || seg.starts_with("promoted[")
}

fn origin(r: &RawBody, raws: &[RawBody], ix: &Index, src: &SourceMap) -> Result<Origin, String> {
    let segs: Vec<String> = split_top(&r.name, "::")
        .into_iter()
        .map(str::to_owned)
        .collect();
    let first_suffix = segs.iter().position(|s| is_suffix(s)).unwrap_or(segs.len());
    let nested = first_suffix < segs.len();
    // Synthetic parameters of `impl Trait` arguments, named as the enclosing
    // function's header prints their types.
    let apit = |base_len: usize, positions: &[usize]| -> Result<Vec<Generic>, String> {
        if positions.is_empty() {
            return Ok(vec![]);
        }
        let base = segs[..base_len].join("::");
        let raw = raws
            .iter()
            .find(|b| b.name == base)
            .ok_or_else(|| format!("no MIR body for the enclosing function `{base}`"))?;
        positions
            .iter()
            .map(|&p| {
                let t = raw
                    .params
                    .get(p)
                    .ok_or_else(|| format!("`{base}` has no parameter {}", p + 1))?;
                if !t.starts_with("impl ") {
                    return Err(format!("parameter {} of `{base}` prints as `{t}`", p + 1));
                }
                Ok(Generic {
                    name: t.clone(),
                    is_const: false,
                })
            })
            .collect()
    };
    if let Some(k) = segs.iter().position(|s| s.starts_with("<impl at ")) {
        let span = segs[k]
            .strip_prefix("<impl at ")
            .and_then(|s| s.strip_suffix('>'))
            .ok_or("malformed impl segment")?;
        let mut parts = span.split(':');
        let file = parts.next().ok_or("impl span without a file")?;
        let line: usize = parts
            .next()
            .and_then(|l| l.parse().ok())
            .ok_or("impl span line")?;
        let col: usize = parts
            .next()
            .and_then(|c| c.parse().ok())
            .ok_or("impl span column")?;
        let (path, _) = src.find(file)?;
        let rest: Vec<String> = segs[k + 1..].to_vec();
        let method = rest.first().ok_or("impl body without a method name")?;
        let module = segs[..k].join("::");
        if let Some(im) = ix
            .impls
            .iter()
            .find(|i| i.file == path && i.line == line && i.col == col)
        {
            if im.self_name.is_empty() {
                return Err(format!("impl at {span} is not on a named type"));
            }
            let f = im
                .fns
                .iter()
                .find(|f| f.name == *method)
                .ok_or_else(|| format!("impl at {span} has no `fn {method}` in the source"))?;
            if f.nested_apit {
                return Err(format!(
                    "`fn {method}` has an `impl Trait` nested in a parameter type"
                ));
            }
            let mut tparams = im.generics.clone();
            tparams.extend(f.generics.iter().cloned());
            tparams.extend(apit(k + 2, &f.apit)?);
            return Ok(Origin {
                module,
                self_name: Some(im.self_name.clone()),
                trait_name: im.trait_name.clone(),
                rest,
                nested,
                tparams,
            });
        }
        let derived: Vec<_> = ix
            .types
            .iter()
            .filter_map(|t| {
                t.derives
                    .iter()
                    .find(|(l, c, _)| t.file == path && *l == line && *c == col)
                    .map(|(_, _, tr)| (t, tr))
            })
            .collect();
        let [(t, tr)] = derived.as_slice() else {
            return Err(format!("no impl or derive at {span} in the source"));
        };
        if !DERIVES.contains(&tr.as_str()) {
            return Err(format!("`#[derive({tr})]` is not supported"));
        }
        return Ok(Origin {
            module,
            self_name: Some(t.name.clone()),
            trait_name: Some((*tr).clone()),
            rest,
            nested,
            tparams: t.generics.clone(),
        });
    }
    let base = &segs[..first_suffix];
    let last = base.last().ok_or("empty body name")?;
    let module = base[..base.len() - 1].join("::");
    // A constructor shim: `Enum::Variant` or a tuple struct `Name`.
    let owner_ty = if base.len() >= 2 {
        ix.types_named(&base[base.len() - 2])
    } else {
        vec![]
    };
    let as_variant = owner_ty
        .into_iter()
        .filter(|t| matches!(&t.kind, TypeKind::Enum(vs) if vs.iter().any(|v| v.name == *last)))
        .collect::<Vec<_>>();
    let free: Vec<_> = ix
        .fns
        .iter()
        .filter(|f| f.name == *last && (module.is_empty() || f.module == module))
        .collect();
    let as_struct: Vec<_> = ix
        .types_named(last)
        .into_iter()
        .filter(|t| matches!(t.kind, TypeKind::Struct(Fields::Unnamed(_))))
        .collect();
    let tparams = match (as_variant.as_slice(), free.as_slice(), as_struct.as_slice()) {
        ([t], [], _) => t.generics.clone(),
        ([], [], [t]) if module.is_empty() => t.generics.clone(),
        ([], [f], []) => {
            if f.nested_apit {
                return Err(format!(
                    "`fn {last}` has an `impl Trait` nested in a parameter type"
                ));
            }
            let mut g = f.generics.clone();
            g.extend(apit(first_suffix, &f.apit)?);
            g
        }
        ([], [], []) => return Err(format!("no source item for `{}`", base.join("::"))),
        _ => return Err(format!("`{}` names several source items", base.join("::"))),
    };
    Ok(Origin {
        module: String::new(),
        self_name: None,
        trait_name: None,
        rest: segs.clone(),
        nested,
        tparams,
    })
}

/// Body names by origin, to resolve calls and promoted constants.
struct Resolver {
    entries: Vec<(String, Origin)>,
}

// ---------------------------------------------------------------------------
// Paths.

/// A path segment with its generic arguments (`State::<V, S, CAP>` or
/// `Iter<'_, V>`), the arguments' text without brackets.
#[derive(Debug)]
struct Seg<'a> {
    name: &'a str,
    args: Option<&'a str>,
}

/// An inherent impl on a primitive type, as rustc prints it in a path
/// (`<impl u64>`, `<impl [T]>`), as opposed to generic arguments that
/// happen to be an `impl Trait` type (`::<impl Iterator<Item = V>>`).
fn is_impl_seg(s: &str) -> bool {
    let Some(inner) = s.strip_prefix("<impl ").and_then(|s| s.strip_suffix('>')) else {
        return false;
    };
    IntTy::from_name(inner).is_some()
        || matches!(inner, "bool" | "char" | "str" | "f32" | "f64")
        || inner.starts_with('[')
}

fn path_segs(s: &str) -> Result<Vec<Seg<'_>>, String> {
    let mut out: Vec<Seg> = vec![];
    for part in split_top(s, "::") {
        if part.starts_with('<') && enclosed(part) && !is_impl_seg(part) {
            let last = out
                .last_mut()
                .ok_or_else(|| format!("path `{s}` starts with generic arguments"))?;
            if last.args.is_some() {
                return Err(format!(
                    "path `{s}` has two generic argument lists in a segment"
                ));
            }
            last.args = Some(&part[1..part.len() - 1]);
            continue;
        }
        match part.find('<') {
            Some(i) if !part.starts_with('<') => {
                if !part.ends_with('>') || matching(part, i) != Some(part.len() - 1) {
                    return Err(format!("path segment `{part}`"));
                }
                out.push(Seg {
                    name: &part[..i],
                    args: Some(&part[i + 1..part.len() - 1]),
                });
            }
            _ => out.push(Seg {
                name: part,
                args: None,
            }),
        }
    }
    Ok(out)
}

/// Lean-side library enums and their variants in declaration order.
const LIB_ENUMS: &[(&str, &[&str])] = &[
    ("Option", &["None", "Some"]),
    ("Result", &["Ok", "Err"]),
    ("Poll", &["Ready", "Pending"]),
    ("ControlFlow", &["Continue", "Break"]),
    ("Ordering", &["Less", "Equal", "Greater"]),
];

fn is_library_path(path: &str) -> bool {
    ["core::", "alloc::", "std::"]
        .iter()
        .any(|p| path.starts_with(p))
}

fn last_seg(path: &str) -> &str {
    path.rsplit("::").next().unwrap_or(path)
}

// ---------------------------------------------------------------------------
// One body.

/// A block's text: `(cleanup, header line, statement lines)`.
type RawBlock<'a> = (bool, usize, Vec<(usize, &'a str)>);

struct Cx<'a> {
    tparams: &'a [Generic],
    closures: &'a BTreeMap<String, (String, Vec<Ty>)>,
    locals: Vec<Ty>,
    ix: &'a Index,
    res: &'a Resolver,
}

fn body(
    r: &RawBody,
    o: &Origin,
    ix: &Index,
    res: &Resolver,
    closures: &BTreeMap<String, (String, Vec<Ty>)>,
) -> Result<Body, String> {
    let mut vars = vec![];
    let mut cx = Cx {
        tparams: &o.tparams,
        closures,
        locals: vec![],
        ix,
        res,
    };
    let at = |ln: usize, e: String| format!("line {ln}: {e}");
    let mut lets: Vec<Option<Ty>> = vec![];
    fn set(lets: &mut Vec<Option<Ty>>, k: usize, t: Ty) -> Result<(), String> {
        if lets.len() <= k {
            lets.resize(k + 1, None);
        }
        if lets[k].is_some() {
            return Err(format!("_{k} declared twice"));
        }
        lets[k] = Some(t);
        Ok(())
    }
    for (k, p) in r.params.iter().enumerate() {
        let t = cx.ty(p).map_err(|e| at(r.line, e))?;
        set(&mut lets, k + 1, t).map_err(|e| at(r.line, e))?;
    }
    // Blocks: `(cleanup, lines)`.
    let mut blocks: Vec<RawBlock> = vec![];
    let mut current: Option<RawBlock> = None;
    for &(ln, line) in &r.lines {
        let t = line.trim();
        if t.is_empty() {
            continue;
        }
        if let Some(b) = current.as_mut() {
            if t == "}" {
                blocks.push(current.take().unwrap());
            } else {
                b.2.push((ln, t));
            }
            continue;
        }
        if let Some(d) = t.strip_prefix("debug ") {
            // `debug name => _n;` (projections and constants are skipped).
            if let Some((name, slot)) = d.strip_suffix(';').and_then(|d| d.split_once(" => ")) {
                if let Some(k) = local_index(slot) {
                    vars.push((name.to_owned(), k));
                }
            }
            continue;
        }
        if t == "}" || (t.starts_with("scope ") && t.ends_with(" {")) {
            continue;
        }
        if let Some(rest) = t.strip_prefix("let ") {
            let rest = rest.strip_prefix("mut ").unwrap_or(rest);
            let rest = rest
                .strip_suffix(';')
                .ok_or_else(|| at(ln, format!("`{t}`")))?;
            let (slot, ty) = rest
                .split_once(": ")
                .ok_or_else(|| at(ln, format!("`{t}`")))?;
            let k = local_index(slot).ok_or_else(|| at(ln, format!("local `{slot}`")))?;
            let ty = cx.ty(ty).map_err(|e| at(ln, e))?;
            set(&mut lets, k, ty).map_err(|e| at(ln, e))?;
            continue;
        }
        if t.starts_with("bb") && t.ends_with(": {") {
            let head = &t[..t.len() - 3];
            let (name, cleanup) = match head.strip_suffix(" (cleanup)") {
                Some(n) => (n, true),
                None => (head, false),
            };
            let k = bb_index(name).map_err(|e| at(ln, e))?;
            if k != blocks.len() {
                return Err(at(ln, format!("block {name} out of order")));
            }
            current = Some((cleanup, ln, vec![]));
            continue;
        }
        return Err(at(ln, format!("unsupported declaration `{t}`")));
    }
    if current.is_some() {
        return Err(at(r.line, "unterminated block".into()));
    }
    let locals: Vec<Ty> = lets
        .into_iter()
        .enumerate()
        .map(|(k, t)| t.ok_or_else(|| at(r.line, format!("_{k} is not declared"))))
        .collect::<Result<_, _>>()?;
    if locals.is_empty() {
        return Err(at(r.line, "no return place `_0`".into()));
    }
    cx.locals = locals;
    let cleanup: Vec<bool> = blocks.iter().map(|b| b.0).collect();
    let mut out = vec![];
    for (is_cleanup, ln, lines) in &blocks {
        if *is_cleanup {
            out.push(None);
            continue;
        }
        let Some((last, stmts)) = lines.split_last() else {
            return Err(at(*ln, "block without a terminator".into()));
        };
        let stmts = stmts
            .iter()
            .map(|(l, s)| cx.stmt(s).map_err(|e| at(*l, e)))
            .collect::<Result<Vec<_>, _>>()?;
        let term = cx.term(last.1).map_err(|e| at(last.0, e))?;
        for t in targets(&term) {
            match cleanup.get(t) {
                None => return Err(at(last.0, format!("bb{t} does not exist"))),
                Some(true) => {
                    return Err(at(last.0, format!("normal edge to cleanup block bb{t}")))
                }
                Some(false) => {}
            }
        }
        out.push(Some(Block { stmts, term }));
    }
    Ok(Body {
        name: r.name.clone(),
        tparams: o
            .tparams
            .iter()
            .map(|g| (g.name.clone(), g.is_const))
            .collect(),
        locals: cx.locals,
        nargs: r.params.len(),
        blocks: out,
        vars,
        owner: o.self_name.as_ref().map(|t| match &o.trait_name {
            Some(tr) => format!("{t}_{tr}"),
            None => t.clone(),
        }),
    })
}

fn targets(t: &Term) -> Vec<usize> {
    match t {
        Term::Goto(b) | Term::Drop(_, b) | Term::Assert(_, _, b) => vec![*b],
        Term::Switch(_, cs, o) => cs.iter().map(|c| c.1).chain([*o]).collect(),
        Term::Call(_, _, _, b) => b.iter().copied().collect(),
        Term::Ret | Term::Unreachable => vec![],
    }
}

impl Cx<'_> {
    fn tparam(&self, name: &str) -> Option<&Generic> {
        self.tparams.iter().find(|g| g.name == name)
    }

    // -- types --------------------------------------------------------------

    fn ty(&self, s: &str) -> Result<Ty, String> {
        let s = s.trim();
        if let Some(t) = IntTy::from_name(s) {
            return Ok(Ty::Int(t));
        }
        match s {
            "bool" => return Ok(Ty::Bool),
            "char" => return Ok(Ty::Char),
            "str" => return Ok(Ty::Str),
            "!" => return Ok(Ty::Never),
            "f32" | "f64" => return Err(format!("floating-point type `{s}`")),
            _ => {}
        }
        if let Some(r) = s.strip_prefix('&') {
            let mut r = r.trim_start();
            if r.starts_with('\'') {
                r = r
                    .split_once(' ')
                    .map(|x| x.1)
                    .ok_or_else(|| format!("type `{s}`"))?;
            }
            if r.starts_with("raw ") {
                return Err(format!("raw reference type `{s}`"));
            }
            return Ok(match r.strip_prefix("mut ") {
                Some(t) => Ty::Ref(true, Box::new(self.ty(t)?)),
                None => Ty::Ref(false, Box::new(self.ty(r)?)),
            });
        }
        if s.starts_with('*') {
            return Err(format!("raw pointer type `{s}`"));
        }
        if s.starts_with('[') && enclosed(s) {
            let inner = &s[1..s.len() - 1];
            let parts = split_top(inner, ";");
            return match parts.as_slice() {
                [t] => Ok(Ty::Slice(Box::new(self.ty(t)?))),
                [t, n] => Ok(Ty::Array(
                    Box::new(self.ty(t)?),
                    Box::new(self.len_ty(n.trim())?),
                )),
                _ => Err(format!("array type `{s}`")),
            };
        }
        if s.starts_with('(') && enclosed(s) {
            let items = list(&s[1..s.len() - 1]);
            return Ok(Ty::Tuple(
                items.iter().map(|t| self.ty(t)).collect::<Result<_, _>>()?,
            ));
        }
        if let Some(span) = s
            .strip_prefix("{closure@")
            .and_then(|r| r.strip_suffix('}'))
        {
            if enclosed(s) {
                let args = self
                    .closures
                    .get(span)
                    .ok_or_else(|| format!("no MIR body defines the closure `{s}`"))?;
                return Ok(Ty::Closure(span.to_owned(), args.1.clone()));
            }
        }
        if s.starts_with('{') && enclosed(s) {
            return Ok(Ty::Other(s.to_owned()));
        }
        if s.starts_with("for<") || s.starts_with("fn(") {
            return self.fn_ty(s);
        }
        if s.starts_with("unsafe ") || s.starts_with("extern ") {
            return Err(format!("unsafe or foreign function type `{s}`"));
        }
        if s.starts_with("dyn ") || s.starts_with("impl ") {
            return Ok(match self.tparam(s) {
                Some(g) if !g.is_const => Ty::Param(s.to_owned()),
                _ => Ty::Other(s.to_owned()),
            });
        }
        if s.starts_with('<') {
            let m = matching(s, 0).ok_or_else(|| format!("type `{s}`"))?;
            let name = s[m + 1..]
                .strip_prefix("::")
                .filter(|n| is_ident(n))
                .ok_or_else(|| format!("projection type `{s}`"))?;
            let inner = &s[1..m];
            let parts = split_top(inner, " as ");
            let [t, tr] = parts.as_slice() else {
                return Err(format!("projection type `{s}`"));
            };
            return Ok(Ty::Assoc(
                Box::new(self.ty(t)?),
                self.path_text(tr)?,
                name.to_owned(),
            ));
        }
        // A path, with generic arguments on its last segment.
        let segs = path_segs(s)?;
        let (last, init) = segs.split_last().ok_or_else(|| format!("type `{s}`"))?;
        if init.iter().any(|g| g.args.is_some()) || segs.iter().any(|g| !is_ident(g.name)) {
            return Err(format!("unsupported type `{s}`"));
        }
        if segs.len() == 1 && last.args.is_none() {
            if let Some(g) = self.tparam(last.name) {
                return Ok(if g.is_const {
                    Ty::Cparam(g.name.clone())
                } else {
                    Ty::Param(g.name.clone())
                });
            }
        }
        let path = segs.iter().map(|g| g.name).collect::<Vec<_>>().join("::");
        let args = match last.args {
            Some(a) => self.gargs(a)?,
            None => vec![],
        };
        Ok(Ty::Adt(path, args))
    }

    /// `for<'a> fn(A, B) -> R` (a function item type `fn(A) -> R {path}` is `other`).
    fn fn_ty(&self, s: &str) -> Result<Ty, String> {
        if s.ends_with('}') {
            return Ok(Ty::Other(s.to_owned()));
        }
        let mut t = s;
        if t.starts_with("for<") {
            let m = matching(t, 3).ok_or_else(|| format!("type `{s}`"))?;
            t = t[m + 1..].trim_start();
        }
        let t = t.strip_prefix("fn").ok_or_else(|| format!("type `{s}`"))?;
        if !t.starts_with('(') {
            return Err(format!("type `{s}`"));
        }
        let close = matching(t, 0).ok_or_else(|| format!("type `{s}`"))?;
        let args = list(&t[1..close])
            .iter()
            .map(|a| self.ty(a))
            .collect::<Result<Vec<_>, _>>()?;
        let rest = &t[close + 1..];
        let ret = if rest.is_empty() {
            Ty::Tuple(vec![])
        } else {
            self.ty(rest
                .strip_prefix(" -> ")
                .ok_or_else(|| format!("type `{s}`"))?)?
        };
        Ok(Ty::FnPtr(args, Box::new(ret)))
    }

    /// An array length or const generic argument.
    fn len_ty(&self, s: &str) -> Result<Ty, String> {
        if let Some(n) = parse_nat(s) {
            return Ok(Ty::Cnst(n));
        }
        match self.tparam(s) {
            Some(g) if g.is_const => Ok(Ty::Cparam(g.name.clone())),
            _ => Err(format!("array length or const argument `{s}`")),
        }
    }

    /// Generic arguments: lifetimes are dropped, numbers and const
    /// parameters are const arguments, the rest types.
    fn gargs(&self, s: &str) -> Result<Vec<Ty>, String> {
        let mut out = vec![];
        for a in list(s) {
            if a.starts_with('\'') {
                continue;
            }
            if find_top(a, "=").is_some() {
                return Err(format!(
                    "associated type binding `{a}` in generic arguments"
                ));
            }
            if parse_nat(a).is_some() || self.tparam(a).is_some_and(|g| g.is_const) {
                out.push(self.len_ty(a)?);
            } else {
                out.push(self.ty(a)?);
            }
        }
        Ok(out)
    }

    /// A trait or type path as printed, without its generic arguments.
    fn path_text(&self, s: &str) -> Result<String, String> {
        let segs = path_segs(s.trim())?;
        if segs.iter().any(|g| !is_ident(g.name)) {
            return Err(format!("path `{s}`"));
        }
        Ok(segs.iter().map(|g| g.name).collect::<Vec<_>>().join("::"))
    }

    // -- places -------------------------------------------------------------

    fn place(&self, s: &str) -> Result<Place, String> {
        let s = s.trim();
        if let Some(k) = local_index(s) {
            if k >= self.locals.len() {
                return Err(format!("_{k} is not declared"));
            }
            return Ok(Place {
                loc: k,
                proj: vec![],
            });
        }
        if s.ends_with(']') {
            let open = rfind_top(s, "[").ok_or_else(|| format!("place `{s}`"))?;
            if matching(s, open) == Some(s.len() - 1) && open > 0 {
                let mut p = self.place(&s[..open])?;
                let idx = &s[open + 1..s.len() - 1];
                if let Some(k) = local_index(idx) {
                    p.proj.push(PElem::Index(k));
                } else if let Some((k, _n)) = idx.split_once(" of ") {
                    let k = parse_nat(k).ok_or_else(|| format!("constant index `{idx}`"))?;
                    p.proj.push(PElem::Cindex(k));
                } else {
                    return Err(format!("unsupported projection `[{idx}]`"));
                }
                return Ok(p);
            }
        }
        if s.starts_with("(*") && enclosed(s) {
            let mut p = self.place(&s[2..s.len() - 1])?;
            p.proj.push(PElem::Deref);
            return Ok(p);
        }
        if s.starts_with('(') && enclosed(s) {
            let inner = &s[1..s.len() - 1];
            if let Some(i) = find_top(inner, " as ") {
                let mut p = self.place(&inner[..i])?;
                let v = &inner[i + 4..];
                let idx = match v.strip_prefix("variant#") {
                    Some(n) => n.parse().map_err(|_| format!("downcast `{v}`"))?,
                    None => {
                        let ty = self.place_ty(&p)?;
                        let Ty::Adt(path, _) = &ty else {
                            return Err(format!("downcast of non-enum place `{s}`"));
                        };
                        self.variant_index(path, v)?
                    }
                };
                p.proj.push(PElem::Down(idx));
                return Ok(p);
            }
            if let Some(i) = find_top(inner, ": ") {
                let left = &inner[..i];
                let dot = rfind_top(left, ".").ok_or_else(|| format!("place `{s}`"))?;
                let mut p = self.place(&left[..dot])?;
                let f = left[dot + 1..]
                    .parse()
                    .map_err(|_| format!("field `{}`", &left[dot + 1..]))?;
                p.proj.push(PElem::Field(f, self.ty(&inner[i + 2..])?));
                return Ok(p);
            }
        }
        Err(format!("unsupported place `{s}`"))
    }

    fn place_ty(&self, p: &Place) -> Result<Ty, String> {
        let mut t = self.locals[p.loc].clone();
        for e in &p.proj {
            t = match (e, t) {
                (PElem::Deref, Ty::Ref(_, t)) => *t,
                (PElem::Field(_, ft), _) => ft.clone(),
                (PElem::Down(_), t) => t,
                (PElem::Index(_) | PElem::Cindex(_), Ty::Array(t, _) | Ty::Slice(t)) => *t,
                (e, t) => return Err(format!("projection {e:?} of type {t:?}")),
            };
        }
        Ok(t)
    }

    /// The index of `variant` in the enum `path` (declaration order).
    fn variant_index(&self, path: &str, variant: &str) -> Result<usize, String> {
        let names = self
            .enum_variants(path)?
            .ok_or_else(|| format!("`{path}` is not a known enum"))?;
        names
            .iter()
            .position(|v| v == variant)
            .ok_or_else(|| format!("`{path}` has no variant `{variant}`"))
    }

    /// The variants of an enum type path, or `None` if it is not an enum.
    fn enum_variants(&self, path: &str) -> Result<Option<Vec<String>>, String> {
        let name = last_seg(path);
        let lib = LIB_ENUMS.iter().find(|(n, _)| *n == name);
        let krate: Vec<_> = if is_library_path(path) {
            vec![]
        } else {
            self.ix.types_named(name)
        };
        match (krate.as_slice(), lib) {
            ([], Some((_, vs))) => Ok(Some(vs.iter().map(|v| (*v).to_owned()).collect())),
            ([], None) => {
                if is_library_path(path) || !path.contains("::") {
                    Ok(None)
                } else {
                    Err(format!("type `{path}` not found in the crate"))
                }
            }
            ([t], None) => match &t.kind {
                TypeKind::Enum(vs) => {
                    if vs.iter().any(|v| v.explicit_discr) {
                        return Err(format!("enum `{path}` has explicit discriminants"));
                    }
                    Ok(Some(vs.iter().map(|v| v.name.clone()).collect()))
                }
                TypeKind::Struct(_) => Ok(None),
            },
            _ => Err(format!("type name `{name}` is ambiguous")),
        }
    }

    /// The declared fields of a crate struct or enum variant (`None` for a
    /// library type).
    fn crate_fields(&self, path: &str, variant: Option<&str>) -> Result<Option<Fields>, String> {
        if is_library_path(path) {
            return Ok(None);
        }
        let ts = self.ix.types_named(last_seg(path));
        let [t] = ts.as_slice() else {
            return if ts.is_empty() {
                Ok(None)
            } else {
                Err(format!("type name `{path}` is ambiguous"))
            };
        };
        Ok(match (&t.kind, variant) {
            (TypeKind::Struct(f), None) => Some(f.clone()),
            (TypeKind::Enum(vs), Some(v)) => {
                vs.iter().find(|x| x.name == v).map(|x| x.fields.clone())
            }
            _ => None,
        })
    }

    // -- operands -----------------------------------------------------------

    fn operand(&self, s: &str) -> Result<Operand, String> {
        let s = s.trim();
        if let Some(p) = s.strip_prefix("copy ") {
            Ok(Operand::Copy(self.place(p)?))
        } else if let Some(p) = s.strip_prefix("move ") {
            Ok(Operand::Move(self.place(p)?))
        } else if let Some(c) = s.strip_prefix("const ") {
            Ok(Operand::Const(self.constant(c)?))
        } else {
            Err(format!("unsupported operand `{s}`"))
        }
    }

    fn constant(&self, s: &str) -> Result<Const, String> {
        let s = s.trim();
        match s {
            "true" => return Ok(Const::Bool(true)),
            "false" => return Ok(Const::Bool(false)),
            "()" => return Ok(Const::Unit),
            _ => {}
        }
        if let Some(b) = s.strip_prefix('b') {
            if b.starts_with('"') {
                return Ok(Const::Bytes(unescape_bytes(b)?));
            }
        }
        if s.starts_with('"') {
            return Ok(Const::Str(unescape_str(s)?));
        }
        if s.starts_with('\'') {
            return Ok(Const::Char(unescape_char(s)?));
        }
        if let Some(t) = s.strip_prefix("ZeroSized: ") {
            return Ok(Const::Zst(self.ty(t)?));
        }
        if s.starts_with(|c: char| c.is_ascii_digit()) || s.starts_with('-') {
            return int_literal(s);
        }
        if let Some(g) = self.tparam(s).filter(|g| g.is_const) {
            return Ok(Const::Cparam(g.name.clone()));
        }
        if s.ends_with(']') && s.contains("::promoted[") {
            return Ok(Const::Promoted(self.promoted(s)?));
        }
        let segs = path_segs(s)?;
        let names: Vec<&str> = segs.iter().map(|g| g.name).collect();
        if let [.., imp, item] = names.as_slice() {
            if is_impl_seg(imp) {
                return int_assoc_const(imp, item);
            }
        }
        if names.iter().any(|n| !is_ident(n)) {
            return Err(format!("unsupported constant `{s}`"));
        }
        // A fieldless enum variant (`Option::<Infallible>::None`) or unit struct.
        if names.len() >= 2 {
            let ty = names[..names.len() - 1].join("::");
            if let Some(vs) = self.enum_variants(&ty)? {
                let v = names[names.len() - 1];
                let i = vs
                    .iter()
                    .position(|x| x == v)
                    .ok_or_else(|| format!("`{ty}` has no variant `{v}`"))?;
                return Ok(Const::Adt(ty, i));
            }
        }
        let path = names.join("::");
        if let Some(Fields::Unit) = self.crate_fields(&path, None)? {
            return Ok(Const::Adt(path, 0));
        }
        Err(format!("unsupported constant `{s}`"))
    }

    /// The header name of the promoted body a printed path names.
    fn promoted(&self, s: &str) -> Result<String, String> {
        let entries = &self.res.entries;
        let hits: Vec<&String> = if s.starts_with('<') {
            let m = matching(s, 0).ok_or_else(|| format!("constant `{s}`"))?;
            let inner = &s[1..m];
            let parts = split_top(inner, " as ");
            let [t, tr] = parts.as_slice() else {
                return Err(format!("constant `{s}`"));
            };
            let self_name = last_seg(&self.path_text(t.trim_start_matches('&'))?).to_owned();
            let trait_name = last_seg(&self.path_text(tr)?).to_owned();
            let rest = plain_segs(
                s[m + 1..]
                    .strip_prefix("::")
                    .ok_or_else(|| format!("constant `{s}`"))?,
            )?;
            entries
                .iter()
                .filter(|(_, o)| {
                    o.self_name.as_deref() == Some(&self_name)
                        && o.trait_name.as_deref() == Some(&trait_name)
                        && o.rest == rest
                })
                .map(|(n, _)| n)
                .collect()
        } else {
            let names = plain_segs(s)?;
            let joined = names.join("::");
            let exact: Vec<&String> = entries
                .iter()
                .filter(|(n, o)| o.self_name.is_none() && **n == joined)
                .map(|(n, _)| n)
                .collect();
            if !exact.is_empty() {
                exact
            } else {
                let mut hits = vec![];
                for k in 0..names.len() {
                    if self.ix.types_named(&names[k]).is_empty() {
                        continue;
                    }
                    let module = names[..k].join("::");
                    for (n, o) in entries {
                        if o.self_name.as_deref() == Some(names[k].as_str())
                            && o.trait_name.is_none()
                            && o.rest == names[k + 1..]
                            && (module.is_empty() || o.module == module)
                        {
                            hits.push(n);
                        }
                    }
                }
                hits
            }
        };
        match hits.as_slice() {
            [n] => Ok((*n).clone()),
            [] => Err(format!("promoted constant `{s}` matches no body")),
            _ => Err(format!("promoted constant `{s}` matches several bodies")),
        }
    }

    // -- rvalues ------------------------------------------------------------

    fn rvalue(&self, s: &str, dest: &Ty) -> Result<Rvalue, String> {
        let s = s.trim();
        if let Some(i) = find_top(s, " as ") {
            // `op as T (Kind)`
            let open = rfind_top(s, " (").ok_or_else(|| format!("cast `{s}`"))? + 1;
            if !s.ends_with(')') || matching(s, open) != Some(s.len() - 1) || open < i {
                return Err(format!("cast `{s}`"));
            }
            let kind = &s[open + 1..s.len() - 1];
            let op = self.operand(&s[..i])?;
            let ty = self.ty(&s[i + 4..open - 1])?;
            if kind == "IntToInt" {
                let Ty::Int(t) = ty else {
                    return Err(format!("IntToInt cast to `{ty:?}`"));
                };
                return Ok(Rvalue::Cast(op, t));
            }
            if let Some(pc) = kind
                .strip_prefix("PointerCoercion(")
                .and_then(|k| k.strip_suffix(')'))
            {
                let first = list(pc).first().copied().unwrap_or("");
                let name = match first {
                    "Unsize" => "Unsize",
                    "ClosureFnPointer(Safe)" => "ClosureFnPointer",
                    _ => return Err(format!("unsupported pointer coercion `{kind}`")),
                };
                return Ok(Rvalue::Coerce(name.to_owned(), op, ty));
            }
            return Err(format!("unsupported cast kind `{kind}`"));
        }
        if s.starts_with("&raw ") || s.starts_with("&fake ") {
            return Err(format!("unsupported reference `{s}`"));
        }
        if let Some(p) = s.strip_prefix("&mut ") {
            return Ok(Rvalue::Ref(true, self.place(p)?));
        }
        if let Some(p) = s.strip_prefix('&') {
            return Ok(Rvalue::Ref(false, self.place(p)?));
        }
        if s.starts_with("copy ") || s.starts_with("move ") || s.starts_with("const ") {
            return Ok(Rvalue::Use(self.operand(s)?));
        }
        if let Some(open) = s.find('(').filter(|&o| o > 0 && is_ident(&s[..o])) {
            let name = &s[..open];
            let is_adt_dest = matches!(dest, Ty::Adt(p, _) if last_seg(p) == name);
            if !is_adt_dest && matching(s, open) == Some(s.len() - 1) {
                let args = list(&s[open + 1..s.len() - 1]);
                let two =
                    |f: fn(BinOp, Operand, Operand) -> Rvalue, op| -> Result<Rvalue, String> {
                        let [a, b] = args.as_slice() else {
                            return Err(format!("`{s}` needs two operands"));
                        };
                        Ok(f(op, self.operand(a)?, self.operand(b)?))
                    };
                let one = || -> Result<Operand, String> {
                    let [a] = args.as_slice() else {
                        return Err(format!("`{s}` needs one operand"));
                    };
                    self.operand(a)
                };
                if let Some(op) = binop(name) {
                    return two(Rvalue::Binop, op);
                }
                if let Some(op) = name.strip_suffix("WithOverflow").and_then(binop) {
                    if !matches!(op, BinOp::Add | BinOp::Sub | BinOp::Mul) {
                        return Err(format!("unsupported `{name}`"));
                    }
                    return two(Rvalue::Checked, op);
                }
                match name {
                    "Not" => return Ok(Rvalue::Unop(UnOp::Not, one()?)),
                    "Neg" => return Ok(Rvalue::Unop(UnOp::Neg, one()?)),
                    "PtrMetadata" => return Ok(Rvalue::PtrMeta(one()?)),
                    "discriminant" => {
                        let [p] = args.as_slice() else {
                            return Err(format!("`{s}`"));
                        };
                        return Ok(Rvalue::Discr(self.place(p)?));
                    }
                    _ => {}
                }
                if !matches!(dest, Ty::Adt(..)) {
                    return Err(format!("unsupported rvalue `{s}`"));
                }
            }
        }
        if s.starts_with('[') && enclosed(s) {
            let inner = &s[1..s.len() - 1];
            let parts = split_top(inner, ";");
            return match parts.as_slice() {
                [items] => Ok(Rvalue::Aggr(
                    AggKind::Array,
                    list(items)
                        .iter()
                        .map(|o| self.operand(o))
                        .collect::<Result<_, _>>()?,
                )),
                [o, n] => Ok(Rvalue::Rep(self.operand(o)?, self.count(n.trim())?)),
                _ => Err(format!("array `{s}`")),
            };
        }
        if s.starts_with('(') && enclosed(s) {
            return Ok(Rvalue::Aggr(
                AggKind::Tuple,
                list(&s[1..s.len() - 1])
                    .iter()
                    .map(|o| self.operand(o))
                    .collect::<Result<_, _>>()?,
            ));
        }
        if s.starts_with("{closure@") {
            let close = matching(s, 0).ok_or_else(|| format!("closure `{s}`"))?;
            let span = &s["{closure@".len()..close];
            let rest = s[close + 1..].trim();
            let ops = if rest.is_empty() {
                vec![]
            } else {
                self.named_ops(rest)?.into_iter().map(|x| x.1).collect()
            };
            return Ok(Rvalue::Aggr(AggKind::Closure(span.to_owned()), ops));
        }
        if s.starts_with("{coroutine@") {
            // `{coroutine@span (#n)} { upvar: op, .. }`: the syntax-context
            // marker ` (#n)` is not part of the span.
            let close = matching(s, 0).ok_or_else(|| format!("coroutine `{s}`"))?;
            let inner = &s["{coroutine@".len()..close];
            let span = match inner.rfind(" (#") {
                Some(i) if inner.ends_with(')') => &inner[..i],
                _ => inner,
            };
            let rest = s[close + 1..].trim();
            let ops = if rest.is_empty() {
                vec![]
            } else {
                self.named_ops(rest)?.into_iter().map(|x| x.1).collect()
            };
            return Ok(Rvalue::Aggr(AggKind::Coroutine(span.to_owned()), ops));
        }
        if s.starts_with('{') {
            return Err(format!("unsupported aggregate `{s}`"));
        }
        self.adt_aggregate(s, dest)
    }

    /// `[op; n]`'s count.
    fn count(&self, s: &str) -> Result<Const, String> {
        if let Some(n) = parse_nat(s) {
            return Ok(Const::Int(false, n, IntTy::Usize));
        }
        match self.tparam(s) {
            Some(g) if g.is_const => Ok(Const::Cparam(s.to_owned())),
            _ => Err(format!("repeat count `{s}`")),
        }
    }

    /// `{ a: op, b: op }`
    fn named_ops(&self, s: &str) -> Result<Vec<(String, Operand)>, String> {
        let inner = s
            .strip_prefix("{ ")
            .and_then(|r| r.strip_suffix(" }"))
            .ok_or_else(|| format!("field list `{s}`"))?;
        list(inner)
            .into_iter()
            .map(|f| {
                let (n, o) = f.split_once(": ").ok_or_else(|| format!("field `{f}`"))?;
                Ok((n.to_owned(), self.operand(o)?))
            })
            .collect()
    }

    /// `Path::<..>::Variant(ops)`, `Path::<..>::Variant { f: op }`,
    /// `Path::<..> { f: op }`, `Path::<..>(ops)`, `Path::Variant`.
    fn adt_aggregate(&self, s: &str, dest: &Ty) -> Result<Rvalue, String> {
        let Ty::Adt(dpath, _) = dest else {
            return Err(format!(
                "unsupported rvalue `{s}` (destination is not an ADT)"
            ));
        };
        enum Shape<'a> {
            Paren(&'a str),
            Brace(&'a str),
            Bare,
        }
        let (head, shape) = if s.ends_with(')') {
            let open = find_top(s, "(").ok_or_else(|| format!("aggregate `{s}`"))?;
            if matching(s, open) != Some(s.len() - 1) {
                return Err(format!("aggregate `{s}`"));
            }
            (&s[..open], Shape::Paren(&s[open + 1..s.len() - 1]))
        } else if s.ends_with('}') {
            let open = find_top(s, " {").ok_or_else(|| format!("aggregate `{s}`"))?;
            (&s[..open], Shape::Brace(&s[open + 1..]))
        } else {
            (s, Shape::Bare)
        };
        let names = plain_segs(head)?;
        if names.iter().any(|n| !is_ident(n)) {
            return Err(format!("unsupported rvalue `{s}`"));
        }
        let dname = last_seg(dpath);
        let (variant, idx) = match self.enum_variants(dpath)? {
            Some(vs) => {
                let [.., ty, v] = names.as_slice() else {
                    return Err(format!("enum aggregate `{s}` without a variant"));
                };
                if ty != dname {
                    return Err(format!("aggregate `{s}` for a `{dpath}` destination"));
                }
                let i = vs
                    .iter()
                    .position(|x| x == v)
                    .ok_or_else(|| format!("`{dpath}` has no variant `{v}`"))?;
                (Some(v.as_str()), i)
            }
            None => {
                if names.last().map(String::as_str) != Some(dname) {
                    return Err(format!("aggregate `{s}` for a `{dpath}` destination"));
                }
                (None, 0)
            }
        };
        let declared = self.crate_fields(dpath, variant)?;
        let ops = match shape {
            Shape::Paren(a) => {
                let ops: Vec<Operand> = list(a)
                    .iter()
                    .map(|o| self.operand(o))
                    .collect::<Result<_, _>>()?;
                if let Some(f) = &declared {
                    if *f != Fields::Unnamed(ops.len()) {
                        return Err(format!(
                            "aggregate `{s}` does not match the declaration {f:?}"
                        ));
                    }
                }
                ops
            }
            Shape::Brace(b) => {
                let named = self.named_ops(b)?;
                if let Some(f) = &declared {
                    let printed: Vec<String> = named.iter().map(|x| x.0.clone()).collect();
                    if *f != Fields::Named(printed) {
                        return Err(format!(
                            "fields of `{s}` are not in declaration order {f:?}"
                        ));
                    }
                }
                named.into_iter().map(|x| x.1).collect()
            }
            Shape::Bare => {
                if let Some(f) = &declared {
                    if *f != Fields::Unit {
                        return Err(format!(
                            "aggregate `{s}` does not match the declaration {f:?}"
                        ));
                    }
                }
                vec![]
            }
        };
        Ok(Rvalue::Aggr(AggKind::Adt(dpath.clone(), idx), ops))
    }

    // -- statements and terminators ----------------------------------------

    fn stmt(&self, line: &str) -> Result<Stmt, String> {
        let s = line
            .strip_suffix(';')
            .ok_or_else(|| format!("statement `{line}`"))?;
        const NOPS: &[&str] = &[
            "StorageLive(",
            "StorageDead(",
            "FakeRead(",
            "PlaceMention(",
            "AscribeUserType(",
            "Coverage::",
        ];
        if NOPS.iter().any(|p| s.starts_with(p)) || s == "ConstEvalCounter" || s == "Nop" {
            return Ok(Stmt::Nop);
        }
        let eq = find_top(s, " = ").ok_or_else(|| format!("unsupported statement `{s}`"))?;
        let (lhs, rhs) = (&s[..eq], &s[eq + 3..]);
        if let Some(p) = lhs
            .strip_prefix("discriminant(")
            .and_then(|p| p.strip_suffix(')'))
        {
            let v = rhs.parse().map_err(|_| format!("variant index `{rhs}`"))?;
            return Ok(Stmt::SetDiscr(self.place(p)?, v));
        }
        let p = self.place(lhs)?;
        let dest = self.place_ty(&p)?;
        Ok(Stmt::Assign(p, self.rvalue(rhs, &dest)?))
    }

    fn term(&self, line: &str) -> Result<Term, String> {
        let s = line
            .strip_suffix(';')
            .ok_or_else(|| format!("terminator `{line}`"))?;
        match s {
            "return" => return Ok(Term::Ret),
            "unreachable" => return Ok(Term::Unreachable),
            "resume" | "terminate" => return Err(format!("`{s}` outside a cleanup block")),
            _ => {}
        }
        if let Some(b) = s.strip_prefix("goto -> ") {
            return Ok(Term::Goto(bb_index(b)?));
        }
        let arrow = rfind_top(s, " -> ").ok_or_else(|| format!("unsupported terminator `{s}`"))?;
        let (head, tgt) = (&s[..arrow], &s[arrow + 4..]);
        if let Some(a) = head
            .strip_prefix("switchInt(")
            .and_then(|a| a.strip_suffix(')'))
        {
            let op = self.operand(a)?;
            let inner = tgt
                .strip_prefix('[')
                .and_then(|t| t.strip_suffix(']'))
                .ok_or_else(|| format!("switch targets `{tgt}`"))?;
            let mut cases = vec![];
            let mut otherwise = None;
            for c in list(inner) {
                let (v, b) = c
                    .split_once(": ")
                    .ok_or_else(|| format!("switch case `{c}`"))?;
                let b = bb_index(b)?;
                if v == "otherwise" {
                    otherwise = Some(b);
                } else {
                    cases.push((
                        parse_nat(v).ok_or_else(|| format!("switch value `{v}`"))?,
                        b,
                    ));
                }
            }
            let o = otherwise.ok_or_else(|| format!("switch without otherwise `{s}`"))?;
            return Ok(Term::Switch(op, cases, o));
        }
        if let Some(p) = head.strip_prefix("drop(").and_then(|a| a.strip_suffix(')')) {
            let t =
                targets_of(tgt, "return")?.ok_or_else(|| format!("drop without a target `{s}`"))?;
            return Ok(Term::Drop(self.place(p)?, t));
        }
        if let Some(a) = head
            .strip_prefix("assert(")
            .and_then(|a| a.strip_suffix(')'))
        {
            let args = list(a);
            let first = args.first().ok_or_else(|| format!("assert `{s}`"))?;
            let (op, expected) = match first.strip_prefix('!') {
                Some(o) => (o, false),
                None => (*first, true),
            };
            let t = targets_of(tgt, "success")?
                .ok_or_else(|| format!("assert without a target `{s}`"))?;
            return Ok(Term::Assert(self.operand(op)?, expected, t));
        }
        // A call: `dest = f(args)`.
        let eq = find_top(head, " = ").ok_or_else(|| format!("unsupported terminator `{s}`"))?;
        let dest = self.place(&head[..eq])?;
        let call = &head[eq + 3..];
        let open = find_top(call, "(").ok_or_else(|| format!("call `{call}`"))?;
        if matching(call, open) != Some(call.len() - 1) {
            return Err(format!("call `{call}`"));
        }
        let f = self.callee(call[..open].trim())?;
        let args = list(&call[open + 1..call.len() - 1])
            .iter()
            .map(|a| match a.split_once(' ') {
                Some(("copy" | "move" | "const", _)) => self.operand(a),
                _ => fn_item_arg(a, &f),
            })
            .collect::<Result<Vec<_>, _>>()?;
        Ok(Term::Call(f, args, dest, targets_of(tgt, "return")?))
    }

    fn callee(&self, s: &str) -> Result<Callee, String> {
        if s.starts_with("move ") || s.starts_with("copy ") {
            return Ok(Callee::Ptr(self.operand(s)?));
        }
        if s.starts_with('<') {
            let m = matching(s, 0).ok_or_else(|| format!("callee `{s}`"))?;
            let parts = split_top(&s[1..m], " as ");
            let [t, tr] = parts.as_slice() else {
                return Err(format!("callee `{s}`"));
            };
            let mut args = vec![self.ty(t)?];
            let tsegs = path_segs(tr)?;
            if tsegs.iter().any(|g| !is_ident(g.name))
                || tsegs[..tsegs.len() - 1].iter().any(|g| g.args.is_some())
            {
                return Err(format!("trait `{tr}`"));
            }
            if let Some(a) = tsegs.last().and_then(|g| g.args) {
                args.extend(self.gargs(a)?);
            }
            let trait_path = tsegs.iter().map(|g| g.name).collect::<Vec<_>>().join("::");
            let msegs = path_segs(
                s[m + 1..]
                    .strip_prefix("::")
                    .ok_or_else(|| format!("callee `{s}`"))?,
            )?;
            let [method] = msegs.as_slice() else {
                return Err(format!("callee `{s}`"));
            };
            if !is_ident(method.name) {
                return Err(format!("callee `{s}`"));
            }
            if let Some(a) = method.args {
                args.extend(self.gargs(a)?);
            }
            return Ok(Callee::Trait(trait_path, method.name.to_owned(), args));
        }
        let segs = path_segs(s)?;
        let mut names = vec![];
        let mut args = vec![];
        let mut has_impl = false;
        for g in &segs {
            if is_impl_seg(g.name) {
                has_impl = true;
                let inner = &g.name["<impl ".len()..g.name.len() - 1];
                if inner.starts_with('[') {
                    match self.ty(inner)? {
                        Ty::Slice(t) => {
                            names.push("<impl [T]>".to_owned());
                            args.push(*t);
                        }
                        Ty::Array(t, n) => {
                            names.push("<impl [T; N]>".to_owned());
                            args.push(*t);
                            args.push(*n);
                        }
                        _ => return Err(format!("impl segment `{}`", g.name)),
                    }
                } else {
                    names.push(g.name.to_owned());
                }
            } else if is_ident(g.name) {
                names.push(g.name.to_owned());
            } else {
                return Err(format!("callee `{s}`"));
            }
            if let Some(a) = g.args {
                args.extend(self.gargs(a)?);
            }
        }
        let key = match (has_impl, self.crate_callee(&names)?) {
            (false, Some(k)) => k,
            _ => names.join("::"),
        };
        Ok(Callee::Fn(key, args))
    }

    /// The header name of the crate function a generic-free printed path
    /// names, or `None` for a library function.
    fn crate_callee(&self, names: &[String]) -> Result<Option<String>, String> {
        let joined = names.join("::");
        if is_library_path(&joined) {
            return Ok(None);
        }
        let entries = &self.res.entries;
        let exact: Vec<&String> = entries
            .iter()
            .filter(|(n, o)| o.self_name.is_none() && !o.nested && **n == joined)
            .map(|(n, _)| n)
            .collect();
        if let [n] = exact.as_slice() {
            return Ok(Some((*n).clone()));
        }
        let (last, init) = names.split_last().ok_or("empty callee")?;
        if let Some((ty, module)) = init.split_last() {
            if !self.ix.types_named(ty).is_empty() {
                let module = module.join("::");
                let hits: Vec<&String> = entries
                    .iter()
                    .filter(|(_, o)| {
                        o.self_name.as_deref() == Some(ty.as_str())
                            && o.trait_name.is_none()
                            && !o.nested
                            && o.rest == [last.clone()]
                            && (module.is_empty() || o.module == module)
                    })
                    .map(|(n, _)| n)
                    .collect();
                return match hits.as_slice() {
                    [n] => Ok(Some((*n).clone())),
                    [] => Err(format!(
                        "`{joined}`: crate type `{ty}` has no body for `{last}`"
                    )),
                    _ => Err(format!("`{joined}` matches several crate bodies")),
                };
            }
        }
        if entries
            .iter()
            .any(|(_, o)| o.self_name.is_none() && !o.nested && o.rest.last() == Some(last))
        {
            return Err(format!(
                "`{joined}` is printed differently from the crate function of that name"
            ));
        }
        Ok(None)
    }
}

/// A function item passed by value (`Option::<Member>::is_none`), printed
/// as its bare path. Its type is the function item type among the call's
/// generic arguments that names it (`for<'a> fn(&'a Option<Member>) -> bool
/// {Option::<Member>::is_none}`); exactly one must.
fn fn_item_arg(a: &str, f: &Callee) -> Result<Operand, String> {
    fn walk<'t>(t: &'t Ty, want: &str, out: &mut Vec<&'t Ty>) {
        match t {
            Ty::Other(s)
                if (s.starts_with("fn(") || s.starts_with("for<")) && s.ends_with(want) =>
            {
                out.push(t)
            }
            Ty::Tuple(v) | Ty::Adt(_, v) => v.iter().for_each(|x| walk(x, want, out)),
            Ty::Array(x, y) => {
                walk(x, want, out);
                walk(y, want, out);
            }
            Ty::Slice(x) | Ty::Ref(_, x) | Ty::Assoc(x, _, _) => walk(x, want, out),
            Ty::FnPtr(v, r) => {
                v.iter().for_each(|x| walk(x, want, out));
                walk(r, want, out);
            }
            _ => {}
        }
    }
    let args = match f {
        Callee::Fn(_, a) | Callee::Trait(_, _, a) => a.as_slice(),
        Callee::Ptr(_) => &[],
    };
    let want = format!(" {{{a}}}");
    let mut hits = vec![];
    for t in args {
        walk(t, &want, &mut hits);
    }
    match hits.as_slice() {
        [t] => Ok(Operand::Const(Const::Zst((*t).clone()))),
        [] => Err(format!("unsupported operand `{a}`")),
        _ => Err(format!(
            "function item operand `{a}` has several candidate types"
        )),
    }
}

/// `[return: bbN, unwind ..]`, `bbN`, or `unwind ..` (no return).
fn targets_of(t: &str, label: &str) -> Result<Option<usize>, String> {
    if t.starts_with("unwind ") {
        return Ok(None);
    }
    if t.starts_with("bb") {
        return Ok(Some(bb_index(t)?));
    }
    let inner = t
        .strip_prefix('[')
        .and_then(|t| t.strip_suffix(']'))
        .ok_or_else(|| format!("targets `{t}`"))?;
    let items = list(inner);
    let first = items.first().ok_or_else(|| format!("targets `{t}`"))?;
    let b = first
        .strip_prefix(label)
        .and_then(|b| b.strip_prefix(": "))
        .ok_or_else(|| format!("targets `{t}`"))?;
    if items[1..].iter().any(|u| !u.starts_with("unwind")) || items.len() > 2 {
        return Err(format!("targets `{t}`"));
    }
    Ok(Some(bb_index(b)?))
}

/// Segment names of a value path without generic arguments.
fn plain_segs(s: &str) -> Result<Vec<String>, String> {
    Ok(path_segs(s)?
        .into_iter()
        .map(|g| g.name.to_owned())
        .collect())
}

fn binop(name: &str) -> Option<BinOp> {
    Some(match name {
        "Add" => BinOp::Add,
        "Sub" => BinOp::Sub,
        "Mul" => BinOp::Mul,
        "Div" => BinOp::Div,
        "Rem" => BinOp::Rem,
        "BitAnd" => BinOp::BitAnd,
        "BitOr" => BinOp::BitOr,
        "BitXor" => BinOp::BitXor,
        "Shl" => BinOp::Shl,
        "Shr" => BinOp::Shr,
        "Eq" => BinOp::Eq,
        "Ne" => BinOp::Ne,
        "Lt" => BinOp::Lt,
        "Le" => BinOp::Le,
        "Gt" => BinOp::Gt,
        "Ge" => BinOp::Ge,
        _ => return None,
    })
}

/// A decimal natural number, optionally with an integer suffix (`16_usize`).
fn parse_nat(s: &str) -> Option<u128> {
    let digits = match s.split_once('_') {
        Some((d, suffix)) if IntTy::from_name(suffix).is_some() => d,
        Some(_) => return None,
        None => s,
    };
    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    digits.parse().ok()
}

/// `3_u64`, `-1_i32`.
fn int_literal(s: &str) -> Result<Const, String> {
    let (neg, body) = match s.strip_prefix('-') {
        Some(b) => (true, b),
        None => (false, s),
    };
    let (digits, suffix) = body
        .split_once('_')
        .ok_or_else(|| format!("integer constant `{s}` without a type suffix"))?;
    let t = IntTy::from_name(suffix).ok_or_else(|| format!("constant `{s}`"))?;
    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return Err(format!("constant `{s}`"));
    }
    let n: u128 = digits.parse().map_err(|_| format!("constant `{s}`"))?;
    if neg && !t.signed() {
        return Err(format!("negative unsigned constant `{s}`"));
    }
    Ok(Const::Int(neg && n != 0, n, t))
}

/// `core::num::<impl u64>::MAX` and the like, computed. Pointer-sized types
/// are rejected: their range is the target's.
fn int_assoc_const(imp: &str, item: &str) -> Result<Const, String> {
    let inner = &imp["<impl ".len()..imp.len() - 1];
    let t = IntTy::from_name(inner).ok_or_else(|| format!("constant `{imp}::{item}`"))?;
    if matches!(t, IntTy::Usize | IntTy::Isize) {
        return Err(format!("pointer-width constant `{imp}::{item}`"));
    }
    let bits = t.bits(0);
    Ok(match (item, t.signed()) {
        ("MAX", false) => Const::Int(
            false,
            if bits == 128 {
                u128::MAX
            } else {
                (1u128 << bits) - 1
            },
            t,
        ),
        ("MAX", true) => Const::Int(false, (1u128 << (bits - 1)) - 1, t),
        ("MIN", false) => Const::Int(false, 0, t),
        ("MIN", true) => Const::Int(true, 1u128 << (bits - 1), t),
        ("BITS", _) => Const::Int(false, bits.into(), IntTy::U32),
        _ => return Err(format!("unsupported constant `{imp}::{item}`")),
    })
}

/// A Rust-escaped byte string literal without its `b` (`"ab\xc0\x00"`).
fn unescape_bytes(s: &str) -> Result<Vec<u8>, String> {
    let inner = s
        .strip_prefix('"')
        .and_then(|r| r.strip_suffix('"'))
        .ok_or_else(|| format!("byte string constant `b{s}`"))?;
    let bad = || format!("escape in `b{s}`");
    let mut out = vec![];
    let mut cs = inner.chars();
    while let Some(c) = cs.next() {
        if c != '\\' {
            if c == '"' || !c.is_ascii() {
                return Err(bad());
            }
            out.push(c as u8);
            continue;
        }
        out.push(match cs.next().ok_or_else(bad)? {
            'n' => b'\n',
            'r' => b'\r',
            't' => b'\t',
            '0' => 0,
            '\\' => b'\\',
            '"' => b'"',
            '\'' => b'\'',
            'x' => {
                let hex: String = cs.by_ref().take(2).collect();
                u8::from_str_radix(&hex, 16).map_err(|_| bad())?
            }
            _ => return Err(bad()),
        });
    }
    Ok(out)
}

/// A Rust-escaped string literal (`"a\n\"b\""`).
fn unescape_str(s: &str) -> Result<String, String> {
    let inner = s
        .strip_prefix('"')
        .and_then(|r| r.strip_suffix('"'))
        .ok_or_else(|| format!("string constant `{s}`"))?;
    unescape(inner, s)
}

fn unescape_char(s: &str) -> Result<char, String> {
    let inner = s
        .strip_prefix('\'')
        .and_then(|r| r.strip_suffix('\''))
        .ok_or_else(|| format!("char constant `{s}`"))?;
    let u = unescape(inner, s)?;
    let mut cs = u.chars();
    match (cs.next(), cs.next()) {
        (Some(c), None) => Ok(c),
        _ => Err(format!("char constant `{s}`")),
    }
}

fn unescape(inner: &str, whole: &str) -> Result<String, String> {
    let bad = || format!("escape in `{whole}`");
    let mut out = String::new();
    let mut cs = inner.chars();
    while let Some(c) = cs.next() {
        if c != '\\' {
            if c == '"' {
                return Err(bad());
            }
            out.push(c);
            continue;
        }
        match cs.next().ok_or_else(bad)? {
            'n' => out.push('\n'),
            'r' => out.push('\r'),
            't' => out.push('\t'),
            '0' => out.push('\0'),
            '\\' => out.push('\\'),
            '"' => out.push('"'),
            '\'' => out.push('\''),
            'u' => {
                if cs.next() != Some('{') {
                    return Err(bad());
                }
                let hex: String = cs.by_ref().take_while(|c| *c != '}').collect();
                let n = u32::from_str_radix(&hex, 16).map_err(|_| bad())?;
                out.push(char::from_u32(n).ok_or_else(bad)?);
            }
            'x' => {
                let hex: String = cs.by_ref().take(2).collect();
                let n = u8::from_str_radix(&hex, 16).map_err(|_| bad())?;
                if n > 0x7f {
                    return Err(bad());
                }
                out.push(n as char);
            }
            _ => return Err(bad()),
        }
    }
    Ok(out)
}

// ---------------------------------------------------------------------------
// Closures of other functions.

/// The header name of the function a body belongs to (without closure,
/// promoted and inline-constant suffixes).
fn body_base(name: &str) -> String {
    let segs = split_top(name, "::");
    let k = segs.iter().position(|s| is_suffix(s)).unwrap_or(segs.len());
    segs[..k].join("::")
}

/// Visit every type in a body (locals, projections, constants, coercions,
/// call generic arguments); `f` recurses itself.
fn tys_mut(b: &mut Body, f: &mut dyn FnMut(&mut Ty) -> Result<(), String>) -> Result<(), String> {
    fn place(
        p: &mut Place,
        f: &mut dyn FnMut(&mut Ty) -> Result<(), String>,
    ) -> Result<(), String> {
        for e in &mut p.proj {
            if let PElem::Field(_, t) = e {
                f(t)?;
            }
        }
        Ok(())
    }
    fn operand(
        o: &mut Operand,
        f: &mut dyn FnMut(&mut Ty) -> Result<(), String>,
    ) -> Result<(), String> {
        match o {
            Operand::Copy(p) | Operand::Move(p) => place(p, f),
            Operand::Const(Const::Zst(t)) => f(t),
            Operand::Const(_) => Ok(()),
        }
    }
    b.locals.iter_mut().try_for_each(&mut *f)?;
    for blk in b.blocks.iter_mut().flatten() {
        for s in &mut blk.stmts {
            match s {
                Stmt::Assign(p, r) => {
                    place(p, f)?;
                    match r {
                        Rvalue::Use(o)
                        | Rvalue::Unop(_, o)
                        | Rvalue::Cast(o, _)
                        | Rvalue::PtrMeta(o) => operand(o, f)?,
                        Rvalue::Rep(o, _) => operand(o, f)?,
                        Rvalue::Ref(_, p) | Rvalue::Discr(p) => place(p, f)?,
                        Rvalue::Binop(_, a, c) | Rvalue::Checked(_, a, c) => {
                            operand(a, f)?;
                            operand(c, f)?
                        }
                        Rvalue::Aggr(_, ops) => ops.iter_mut().try_for_each(|o| operand(o, f))?,
                        Rvalue::Coerce(_, o, t) => {
                            operand(o, f)?;
                            f(t)?
                        }
                    }
                }
                Stmt::SetDiscr(p, _) => place(p, f)?,
                Stmt::Nop => {}
            }
        }
        match &mut blk.term {
            Term::Switch(o, _, _) | Term::Assert(o, _, _) => operand(o, f)?,
            Term::Drop(p, _) => place(p, f)?,
            Term::Call(c, args, dest, _) => {
                match c {
                    Callee::Fn(_, a) | Callee::Trait(_, _, a) => {
                        a.iter_mut().try_for_each(&mut *f)?
                    }
                    Callee::Ptr(o) => operand(o, f)?,
                }
                args.iter_mut().try_for_each(|o| operand(o, f))?;
                place(dest, f)?;
            }
            Term::Goto(_) | Term::Ret | Term::Unreachable => {}
        }
    }
    Ok(())
}

/// A closure defined in another function `F` (reached through an iterator
/// `F` returned) gets `F`'s generic arguments as this body instantiates
/// them: the generic arguments of its calls to `F`, which must all agree.
fn foreign_closures(
    b: &mut Body,
    closures: &BTreeMap<String, (String, Vec<Ty>)>,
) -> Result<(), String> {
    let base = body_base(&b.name);
    let mut calls: Vec<(String, Vec<Ty>)> = vec![];
    for blk in b.blocks.iter().flatten() {
        if let Term::Call(Callee::Fn(k, a), ..) = &blk.term {
            if !calls.iter().any(|(k2, a2)| k2 == k && a2 == a) {
                calls.push((k.clone(), a.clone()));
            }
        }
    }
    fn fix(
        t: &mut Ty,
        base: &str,
        calls: &[(String, Vec<Ty>)],
        closures: &BTreeMap<String, (String, Vec<Ty>)>,
    ) -> Result<(), String> {
        let rec = |v: &mut [Ty]| v.iter_mut().try_for_each(|x| fix(x, base, calls, closures));
        match t {
            Ty::Closure(span, args) => {
                if let Some((def, _)) = closures.get(span.as_str()) {
                    if def != base {
                        let insts: Vec<&Vec<Ty>> = calls
                            .iter()
                            .filter(|(k, _)| k == def)
                            .map(|x| &x.1)
                            .collect();
                        match insts.as_slice() {
                            [a] if a.len() == args.len() => *args = (*a).clone(),
                            [] => {
                                return Err(format!(
                                    "closure `{span}` of `{def}` appears without a call to `{def}`"
                                ))
                            }
                            _ => {
                                return Err(format!(
                                    "closure `{span}` of `{def}`: `{def}` is called with different generic arguments"
                                ))
                            }
                        }
                    }
                }
                rec(args)
            }
            Ty::Adt(_, v) | Ty::Tuple(v) => rec(v),
            Ty::Array(x, y) => {
                fix(x, base, calls, closures)?;
                fix(y, base, calls, closures)
            }
            Ty::Slice(x) | Ty::Ref(_, x) | Ty::Assoc(x, _, _) => fix(x, base, calls, closures),
            Ty::FnPtr(v, r) => {
                rec(v)?;
                fix(r, base, calls, closures)
            }
            _ => Ok(()),
        }
    }
    tys_mut(b, &mut |t| fix(t, &base, &calls, closures))
}

// ---------------------------------------------------------------------------
// Canonical type paths.

/// Library types always named by these full paths.
const LIB_PATHS: &[&str] = &[
    "core::option::Option",
    "core::result::Result",
    "core::slice::Iter",
    "core::slice::IterMut",
    "core::iter::Flatten",
    "core::iter::Filter",
    "core::iter::Map",
    "core::iter::Enumerate",
    "core::iter::Cloned",
    "core::iter::TakeWhile",
    "core::iter::OnceWith",
    "core::iter::FilterMap",
    "core::ops::Range",
    "core::ops::RangeTo",
    "core::ops::RangeFrom",
    "core::ops::ControlFlow",
    "core::convert::Infallible",
    "core::task::Poll",
    "core::array::IntoIter",
    "core::fmt::Formatter",
    "core::fmt::Arguments",
    // Beyond the coordinator's list: printed both ways in Jarl's MIR.
    "core::task::Context",
    "core::pin::Pin",
    "core::num::TryFromIntError",
];

/// Rewrites every ADT path (`Ty.adt`, `AggKind.adt`, `Const.adt`) to one
/// form per type: a crate type as rustc prints it in `let` declarations
/// (`node::Node`, or bare at the crate root), a listed library type by its
/// full path. Other library paths stay as printed; one printed both bare and
/// qualified is an error.
struct Canon<'a> {
    ix: &'a Index,
    /// Crate type name to its `let` form.
    krate: BTreeMap<String, String>,
    bare: BTreeSet<String>,
    qualified: BTreeMap<String, String>,
    errors: Vec<String>,
}

impl<'a> Canon<'a> {
    fn new(ix: &'a Index, bodies: &[Body]) -> Canon<'a> {
        let mut forms: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
        fn walk(t: &Ty, ix: &Index, forms: &mut BTreeMap<String, BTreeSet<String>>) {
            match t {
                Ty::Adt(p, a) => {
                    let name = last_seg(p);
                    if !is_library_path(p) && !ix.types_named(name).is_empty() {
                        forms.entry(name.to_owned()).or_default().insert(p.clone());
                    }
                    a.iter().for_each(|x| walk(x, ix, forms));
                }
                Ty::Tuple(v) | Ty::Closure(_, v) => v.iter().for_each(|x| walk(x, ix, forms)),
                Ty::Array(x, y) => {
                    walk(x, ix, forms);
                    walk(y, ix, forms);
                }
                Ty::Slice(x) | Ty::Ref(_, x) | Ty::Assoc(x, _, _) => walk(x, ix, forms),
                Ty::FnPtr(v, r) => {
                    v.iter().for_each(|x| walk(x, ix, forms));
                    walk(r, ix, forms);
                }
                _ => {}
            }
        }
        for b in bodies {
            // `let` declarations: `_0` and the locals after the parameters.
            let lets = b
                .locals
                .iter()
                .take(1)
                .chain(b.locals.iter().skip(b.nargs + 1));
            lets.for_each(|t| walk(t, ix, &mut forms));
        }
        let mut errors = vec![];
        let mut krate = BTreeMap::new();
        for (name, fs) in forms {
            let qualified: Vec<&String> = fs.iter().filter(|f| f.contains("::")).collect();
            let form = match qualified.as_slice() {
                [] => name.clone(),
                [q] => (*q).clone(),
                _ => {
                    errors.push(format!("crate type `{name}` is declared as {qualified:?}"));
                    continue;
                }
            };
            let module = form.rsplit_once("::").map(|x| x.0).unwrap_or("");
            let decls = ix.types_named(&name);
            if !module.is_empty() && !decls.iter().any(|t| t.module == module) {
                errors.push(format!(
                    "`{form}` does not match the module of any `{name}` in the source"
                ));
            }
            krate.insert(name, form);
        }
        Canon {
            ix,
            krate,
            bare: BTreeSet::new(),
            qualified: BTreeMap::new(),
            errors,
        }
    }

    fn path(&mut self, p: &mut String) -> Result<(), String> {
        let name = last_seg(p).to_owned();
        if !is_library_path(p) && !self.ix.types_named(&name).is_empty() {
            let form = self
                .krate
                .get(&name)
                .cloned()
                .unwrap_or_else(|| name.clone());
            if p.contains("::") && *p != form {
                return Err(format!(
                    "`{p}` is printed differently from its declaration `{form}`"
                ));
            }
            *p = form;
            return Ok(());
        }
        if let Some(full) = LIB_PATHS.iter().find(|f| last_seg(f) == name) {
            if p.contains("::") && p != full {
                return Err(format!("`{p}` is not the library type `{full}`"));
            }
            *p = (*full).to_owned();
            return Ok(());
        }
        if p.contains("::") {
            self.qualified.insert(name, p.clone());
        } else {
            self.bare.insert(name);
        }
        Ok(())
    }

    fn ty(&mut self, t: &mut Ty) -> Result<(), String> {
        match t {
            Ty::Adt(p, a) => {
                self.path(p)?;
                a.iter_mut().try_for_each(|x| self.ty(x))
            }
            Ty::Tuple(v) | Ty::Closure(_, v) => v.iter_mut().try_for_each(|x| self.ty(x)),
            Ty::Array(x, y) => {
                self.ty(x)?;
                self.ty(y)
            }
            Ty::Slice(x) | Ty::Ref(_, x) | Ty::Assoc(x, _, _) => self.ty(x),
            Ty::FnPtr(v, r) => {
                v.iter_mut().try_for_each(|x| self.ty(x))?;
                self.ty(r)
            }
            _ => Ok(()),
        }
    }

    fn place(&mut self, p: &mut Place) -> Result<(), String> {
        for e in &mut p.proj {
            if let PElem::Field(_, t) = e {
                self.ty(t)?;
            }
        }
        Ok(())
    }

    fn constant(&mut self, c: &mut Const) -> Result<(), String> {
        match c {
            Const::Zst(t) => self.ty(t),
            Const::Adt(p, _) => self.path(p),
            _ => Ok(()),
        }
    }

    fn operand(&mut self, o: &mut Operand) -> Result<(), String> {
        match o {
            Operand::Copy(p) | Operand::Move(p) => self.place(p),
            Operand::Const(c) => self.constant(c),
        }
    }

    fn rvalue(&mut self, r: &mut Rvalue) -> Result<(), String> {
        match r {
            Rvalue::Use(o) | Rvalue::Unop(_, o) | Rvalue::Cast(o, _) | Rvalue::PtrMeta(o) => {
                self.operand(o)
            }
            Rvalue::Ref(_, p) | Rvalue::Discr(p) => self.place(p),
            Rvalue::Binop(_, a, b) | Rvalue::Checked(_, a, b) => {
                self.operand(a)?;
                self.operand(b)
            }
            Rvalue::Aggr(k, ops) => {
                if let AggKind::Adt(p, _) = k {
                    self.path(p)?;
                }
                ops.iter_mut().try_for_each(|o| self.operand(o))
            }
            Rvalue::Rep(o, c) => {
                self.operand(o)?;
                self.constant(c)
            }
            Rvalue::Coerce(_, o, t) => {
                self.operand(o)?;
                self.ty(t)
            }
        }
    }

    fn body(&mut self, b: &mut Body) -> Result<(), String> {
        b.locals.iter_mut().try_for_each(|t| self.ty(t))?;
        for blk in b.blocks.iter_mut().flatten() {
            for s in &mut blk.stmts {
                match s {
                    Stmt::Assign(p, r) => {
                        self.place(p)?;
                        self.rvalue(r)?;
                    }
                    Stmt::SetDiscr(p, _) => self.place(p)?,
                    Stmt::Nop => {}
                }
            }
            match &mut blk.term {
                Term::Switch(o, _, _) | Term::Assert(o, _, _) => self.operand(o)?,
                Term::Drop(p, _) => self.place(p)?,
                Term::Call(f, args, dest, _) => {
                    match f {
                        Callee::Fn(_, a) | Callee::Trait(_, _, a) => {
                            a.iter_mut().try_for_each(|t| self.ty(t))?
                        }
                        Callee::Ptr(o) => self.operand(o)?,
                    }
                    args.iter_mut().try_for_each(|o| self.operand(o))?;
                    self.place(dest)?;
                }
                Term::Goto(_) | Term::Ret | Term::Unreachable => {}
            }
        }
        Ok(())
    }

    /// Errors found across bodies: crate types declared inconsistently, and
    /// unlisted library types printed both bare and qualified.
    fn finish(mut self) -> Vec<String> {
        for (name, q) in &self.qualified {
            if self.bare.contains(name) {
                self.errors.push(format!(
                    "library type `{name}` is printed both bare and as `{q}`; add it to the canonical list"
                ));
            }
        }
        self.errors
    }
}
