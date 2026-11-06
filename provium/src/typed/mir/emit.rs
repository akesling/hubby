//! [`Body`]s as a Lean file of `Provium.Mir` values.
use super::{
    AggKind, BinOp, Body, Callee, Const, IntTy, Operand, PElem, Place, Rvalue, Stmt, Term, Ty, UnOp,
};
use std::collections::BTreeSet;
use std::fmt::Write;

const WIDTH: usize = 140;

/// One Lean file defining every body and its blocks, with `@[mir_body]`
/// lemmas for block lookup and the locals, in namespace
/// `<namespace>.Mir`.
pub fn emit(bodies: &[Body], namespace: &str) -> String {
    let mut out = String::new();
    out.push_str("import Provium.Mir.Syntax\nimport Provium.Mir.Attr\n\n");
    let _ = writeln!(out, "namespace {namespace}.Mir\nopen Provium.Mir\n");
    let mut used = BTreeSet::new();
    let mut index = vec![];
    for b in bodies {
        let id = unique_ident(&ident(&b.name, b.owner.as_deref()), &mut used);
        let header = b.name.replace("-/", "- /");
        let mut first = true;
        for (k, blk) in b.blocks.iter().enumerate() {
            let Some(blk) = blk else { continue };
            if first {
                let _ = writeln!(out, "/-- `{header}` -/");
                first = false;
            }
            let _ = writeln!(out, "def {id}_bb{k} : Block where");
            field(
                &mut out,
                "stmts",
                &list(blk.stmts.iter().map(stmt).collect()),
            );
            field(&mut out, "term", &term(&blk.term));
            out.push('\n');
        }
        if first {
            let _ = writeln!(out, "/-- `{header}` -/");
        }
        let locals = list(b.locals.iter().map(ty).collect());
        let _ = writeln!(out, "def {id} : Body where");
        field(&mut out, "name", &Doc::Atom(lean_str(&b.name)));
        field(
            &mut out,
            "tparams",
            &list(
                b.tparams
                    .iter()
                    .map(|(t, c)| Doc::Tuple(vec![Doc::Atom(lean_str(t)), n(c)]))
                    .collect(),
            ),
        );
        field(&mut out, "locals", &locals);
        field(&mut out, "nargs", &Doc::Atom(b.nargs.to_string()));
        field(
            &mut out,
            "vars",
            &list(
                b.vars
                    .iter()
                    .map(|(v, k)| Doc::Tuple(vec![Doc::Atom(lean_str(v)), n(k)]))
                    .collect(),
            ),
        );
        out.push_str("  blocks\n");
        for (k, blk) in b.blocks.iter().enumerate() {
            if blk.is_some() {
                let _ = writeln!(out, "    | {k} => some {id}_bb{k}");
            }
        }
        out.push_str("    | _ => none\n\n");
        for (k, blk) in b.blocks.iter().enumerate() {
            if blk.is_some() {
                let head = format!("@[mir_body] theorem {id}_blocks_{k} :");
                let stmt = format!("{id}.blocks {k} = some {id}_bb{k} := rfl");
                if head.len() + 1 + stmt.len() <= WIDTH {
                    let _ = writeln!(out, "{head} {stmt}");
                } else {
                    let _ = writeln!(out, "{head}\n    {stmt}");
                }
            }
        }
        let head = format!("    {id}.locals = ");
        let _ = writeln!(
            out,
            "@[mir_body] theorem {id}_locals :\n{head}{} := rfl\n",
            render(&locals, head.len(), 4, " := rfl".len())
        );
        index.push(Doc::Tuple(vec![
            Doc::Atom(lean_str(&b.name)),
            Doc::Atom(id),
        ]));
    }
    out.push_str("/-- Every body, by name. -/\ndef bodies : List (String × Body) :=\n  ");
    out.push_str(&render(&list(index), 2, 0, 0));
    let impls: Vec<Doc> = bodies
        .iter()
        .filter_map(|b| {
            let (t, m, ty) = b.trait_impl.as_ref()?;
            Some(Doc::Tuple(vec![
                Doc::Tuple(vec![s(t), s(m), s(ty)]),
                s(&b.name),
            ]))
        })
        .collect();
    out.push_str(
        "\n\n/-- Crate trait method bodies: ((trait, method, self type path), body name). -/\n\
         def traitImpls : List ((String × String × String) × String) :=\n  ",
    );
    out.push_str(&render(&list(impls), 2, 0, 0));
    let closures: Vec<Doc> = bodies
        .iter()
        .filter_map(|b| {
            let (span, by_ref) = b.closure.as_ref()?;
            Some(Doc::Tuple(vec![s(span), s(&b.name), n(by_ref)]))
        })
        .collect();
    out.push_str(
        "\n\n/-- Closure bodies: (span, body name, whether `_1` is a reference to the closure). -/\n\
         def closureBodies : List (String × String × Bool) :=\n  ",
    );
    out.push_str(&render(&list(closures), 2, 0, 0));
    let _ = writeln!(out, "\n\nend {namespace}.Mir");
    out
}

fn field(out: &mut String, name: &str, d: &Doc) {
    let head = format!("  {name} := ");
    out.push_str(&head);
    out.push_str(&render(d, head.len(), 2, 0));
    out.push('\n');
}

// ---------------------------------------------------------------------------
// Identifiers.

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
    "mut",
    "break",
    "continue",
    "bodies",
    "Id",
    "Type",
    "Prop",
    "Sort",
];

/// A Lean identifier for a header: module path, self type, trait, method,
/// closure, constant and promoted indices, joined with `_`.
fn ident(name: &str, owner: Option<&str>) -> String {
    let mut parts = vec![];
    for seg in name.split("::") {
        if seg.starts_with("<impl at ") {
            parts.extend(owner.map(str::to_owned));
            continue;
        }
        let seg = seg
            .replace("{closure#", "closure")
            .replace("{constant#", "constant")
            .replace("promoted[", "promoted");
        parts.push(seg);
    }
    let raw = parts.join("_");
    let mut s: String = raw
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '_' })
        .collect();
    while s.contains("__") {
        s = s.replace("__", "_");
    }
    let s = s.trim_matches('_').to_owned();
    if s.is_empty() || s.starts_with(|c: char| c.is_ascii_digit()) || KEYWORDS.contains(&s.as_str())
    {
        format!("mir_{s}")
    } else {
        s
    }
}

fn unique_ident(base: &str, used: &mut BTreeSet<String>) -> String {
    let base = base.to_owned();
    let mut id = base.clone();
    let mut n = 2;
    while used.contains(&id) {
        id = format!("{base}_{n}");
        n += 1;
    }
    used.insert(id.clone());
    id
}

// ---------------------------------------------------------------------------
// Terms.

/// A Lean term, laid out by [`render`].
enum Doc {
    Atom(String),
    /// `head a b c`, parenthesised as an argument.
    App(String, Vec<Doc>),
    List(Vec<Doc>),
    /// `(a, b)`
    Tuple(Vec<Doc>),
    /// `⟨a, b⟩`
    Anon(Vec<Doc>),
}

fn app(head: &str, args: Vec<Doc>) -> Doc {
    if args.is_empty() {
        Doc::Atom(head.to_owned())
    } else {
        Doc::App(head.to_owned(), args)
    }
}

fn atom(s: impl Into<String>) -> Doc {
    Doc::Atom(s.into())
}

fn list(items: Vec<Doc>) -> Doc {
    Doc::List(items)
}

fn flat(d: &Doc, arg: bool) -> String {
    match d {
        Doc::Atom(s) => s.clone(),
        Doc::App(h, a) => {
            let inner = std::iter::once(h.clone())
                .chain(a.iter().map(|x| flat(x, true)))
                .collect::<Vec<_>>()
                .join(" ");
            if arg {
                format!("({inner})")
            } else {
                inner
            }
        }
        Doc::List(v) => format!(
            "[{}]",
            v.iter()
                .map(|x| flat(x, false))
                .collect::<Vec<_>>()
                .join(", ")
        ),
        Doc::Tuple(v) => format!(
            "({})",
            v.iter()
                .map(|x| flat(x, false))
                .collect::<Vec<_>>()
                .join(", ")
        ),
        Doc::Anon(v) => format!(
            "⟨{}⟩",
            v.iter()
                .map(|x| flat(x, false))
                .collect::<Vec<_>>()
                .join(", ")
        ),
    }
}

/// Lay out `d` starting at column `col`, followed on its last line by
/// `tail` more characters; continuation lines are indented two columns past
/// `ind`.
fn render(d: &Doc, col: usize, ind: usize, tail: usize) -> String {
    layout(d, col, ind, false, tail)
}

fn layout(d: &Doc, col: usize, ind: usize, arg: bool, tail: usize) -> String {
    let f = flat(d, arg);
    if col + f.chars().count() + tail <= WIDTH {
        return f;
    }
    let inner = ind + 2;
    let pad = " ".repeat(inner);
    match d {
        Doc::Atom(s) => s.clone(),
        Doc::App(h, a) => {
            let mut s = String::new();
            if arg {
                s.push('(');
            }
            s.push_str(h);
            for (i, x) in a.iter().enumerate() {
                let t = if i + 1 == a.len() {
                    tail + usize::from(arg)
                } else {
                    0
                };
                s.push('\n');
                s.push_str(&pad);
                s.push_str(&layout(x, inner, inner, true, t));
            }
            if arg {
                s.push(')');
            }
            s
        }
        Doc::List(v) => seq(v, "[", "]", inner, tail),
        Doc::Tuple(v) => seq(v, "(", ")", inner, tail),
        Doc::Anon(v) => seq(v, "⟨", "⟩", inner, tail),
    }
}

fn seq(v: &[Doc], open: &str, close: &str, inner: usize, tail: usize) -> String {
    let pad = " ".repeat(inner);
    let mut s = String::from(open);
    for (i, x) in v.iter().enumerate() {
        if i > 0 {
            s.push(',');
        }
        let t = if i + 1 == v.len() { tail + 1 } else { 1 };
        s.push('\n');
        s.push_str(&pad);
        s.push_str(&layout(x, inner, inner, false, t));
    }
    s.push_str(close);
    s
}

/// A Lean string literal.
pub(crate) fn lean_str(s: &str) -> String {
    let mut out = String::from("\"");
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            '\r' => out.push_str("\\r"),
            c if (c as u32) < 0x20 || c as u32 == 0x7f => {
                let _ = write!(out, "\\x{:02x}", c as u32);
            }
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn lean_char(c: char) -> String {
    match c {
        '\'' => "'\\''".into(),
        '\\' => "'\\\\'".into(),
        '\n' => "'\\n'".into(),
        '\t' => "'\\t'".into(),
        '\r' => "'\\r'".into(),
        c if (c as u32) < 0x20 || c as u32 == 0x7f => format!("'\\x{:02x}'", c as u32),
        c => format!("'{c}'"),
    }
}

fn int_ty(t: IntTy) -> Doc {
    atom(format!(".{}", t.name()))
}

fn s(x: &str) -> Doc {
    atom(lean_str(x))
}

fn n(x: impl ToString) -> Doc {
    atom(x.to_string())
}

fn ty(t: &Ty) -> Doc {
    match t {
        Ty::Bool => atom("Ty.bool"),
        Ty::Char => atom("Ty.char"),
        Ty::Str => atom("Ty.str"),
        Ty::Never => atom("Ty.never"),
        Ty::Int(i) => app("Ty.int", vec![int_ty(*i)]),
        Ty::Tuple(v) => app("Ty.tuple", vec![list(v.iter().map(ty).collect())]),
        Ty::Adt(p, a) => app("Ty.adt", vec![s(p), list(a.iter().map(ty).collect())]),
        Ty::Cnst(k) => app("Ty.cnst", vec![n(k)]),
        Ty::Cparam(p) => app("Ty.cparam", vec![s(p)]),
        Ty::Array(t, l) => app("Ty.array", vec![ty(t), ty(l)]),
        Ty::Slice(t) => app("Ty.slice", vec![ty(t)]),
        Ty::Ref(m, t) => app("Ty.ref", vec![n(m), ty(t)]),
        Ty::Param(p) => app("Ty.param", vec![s(p)]),
        Ty::Closure(p, a) => app("Ty.closure", vec![s(p), list(a.iter().map(ty).collect())]),
        Ty::FnPtr(a, r) => app("Ty.fnPtr", vec![list(a.iter().map(ty).collect()), ty(r)]),
        Ty::Assoc(t, tr, nm) => app("Ty.assoc", vec![ty(t), s(tr), s(nm)]),
        Ty::Other(x) => app("Ty.other", vec![s(x)]),
    }
}

fn place(p: &Place) -> Doc {
    let proj = p
        .proj
        .iter()
        .map(|e| match e {
            PElem::Deref => atom("PElem.deref"),
            PElem::Field(i, t) => app("PElem.field", vec![n(i), ty(t)]),
            PElem::Index(l) => app("PElem.index", vec![n(l)]),
            PElem::Cindex(k) => app("PElem.cindex", vec![n(k)]),
            PElem::Down(v) => app("PElem.down", vec![n(v)]),
        })
        .collect();
    Doc::Anon(vec![n(p.loc), list(proj)])
}

fn constant(c: &Const) -> Doc {
    match c {
        Const::Int(neg, m, t) => {
            let v = if *neg { atom(format!("(-{m})")) } else { n(m) };
            app("Const.int", vec![v, int_ty(*t)])
        }
        Const::Bool(b) => app("Const.bool", vec![n(b)]),
        Const::Char(ch) => app("Const.char", vec![atom(lean_char(*ch))]),
        Const::Unit => atom("Const.unit"),
        Const::Str(x) => app("Const.str", vec![s(x)]),
        Const::Cparam(p) => app("Const.cparam", vec![s(p)]),
        Const::Zst(t) => app("Const.zst", vec![ty(t)]),
        Const::Adt(p, v) => app("Const.adt", vec![s(p), n(v)]),
        Const::Bytes(bs) => app("Const.bytes", vec![list(bs.iter().map(n).collect())]),
        Const::Promoted(b) => app("Const.promoted", vec![s(b)]),
    }
}

fn operand(o: &Operand) -> Doc {
    match o {
        Operand::Copy(p) => app("Operand.copy", vec![place(p)]),
        Operand::Move(p) => app("Operand.move", vec![place(p)]),
        Operand::Const(c) => app("Operand.const", vec![constant(c)]),
    }
}

fn binop(b: BinOp) -> Doc {
    atom(match b {
        BinOp::Add => ".add",
        BinOp::Sub => ".sub",
        BinOp::Mul => ".mul",
        BinOp::Div => ".div",
        BinOp::Rem => ".rem",
        BinOp::BitAnd => ".bitAnd",
        BinOp::BitOr => ".bitOr",
        BinOp::BitXor => ".bitXor",
        BinOp::Shl => ".shl",
        BinOp::Shr => ".shr",
        BinOp::Eq => ".eq",
        BinOp::Ne => ".ne",
        BinOp::Lt => ".lt",
        BinOp::Le => ".le",
        BinOp::Gt => ".gt",
        BinOp::Ge => ".ge",
    })
}

fn rvalue(r: &Rvalue) -> Doc {
    let ops = |v: &[Operand]| list(v.iter().map(operand).collect());
    match r {
        Rvalue::Use(o) => app("Rvalue.use", vec![operand(o)]),
        Rvalue::Ref(m, p) => app("Rvalue.ref", vec![n(m), place(p)]),
        Rvalue::Binop(b, x, y) => app("Rvalue.binop", vec![binop(*b), operand(x), operand(y)]),
        Rvalue::Checked(b, x, y) => app("Rvalue.checked", vec![binop(*b), operand(x), operand(y)]),
        Rvalue::Unop(u, x) => app(
            "Rvalue.unop",
            vec![
                atom(match u {
                    UnOp::Not => ".not",
                    UnOp::Neg => ".neg",
                }),
                operand(x),
            ],
        ),
        Rvalue::Discr(p) => app("Rvalue.discr", vec![place(p)]),
        Rvalue::Aggr(k, v) => {
            let k = match k {
                AggKind::Tuple => atom("AggKind.tuple"),
                AggKind::Array => atom("AggKind.array"),
                AggKind::Adt(p, i) => app("AggKind.adt", vec![s(p), n(i)]),
                AggKind::Closure(sp) => app("AggKind.closure", vec![s(sp)]),
                AggKind::Coroutine(sp) => app("AggKind.coroutine", vec![s(sp)]),
            };
            app("Rvalue.aggr", vec![k, ops(v)])
        }
        Rvalue::Rep(o, c) => app("Rvalue.rep", vec![operand(o), constant(c)]),
        Rvalue::Cast(o, t) => app("Rvalue.cast", vec![operand(o), int_ty(*t)]),
        Rvalue::Coerce(k, o, t) => app("Rvalue.coerce", vec![s(k), operand(o), ty(t)]),
        Rvalue::PtrMeta(o) => app("Rvalue.ptrMeta", vec![operand(o)]),
    }
}

fn stmt(st: &Stmt) -> Doc {
    match st {
        Stmt::Assign(p, r) => app("Stmt.assign", vec![place(p), rvalue(r)]),
        Stmt::SetDiscr(p, v) => app("Stmt.setDiscr", vec![place(p), n(v)]),
        Stmt::Nop => atom("Stmt.nop"),
    }
}

fn callee(c: &Callee) -> Doc {
    match c {
        Callee::Fn(p, a) => app("Callee.fn", vec![s(p), list(a.iter().map(ty).collect())]),
        Callee::Trait(t, m, a) => app(
            "Callee.trait",
            vec![s(t), s(m), list(a.iter().map(ty).collect())],
        ),
        Callee::Ptr(o) => app("Callee.ptr", vec![operand(o)]),
    }
}

fn term(t: &Term) -> Doc {
    match t {
        Term::Goto(b) => app("Term.goto", vec![n(b)]),
        Term::Switch(o, cs, d) => app(
            "Term.switch",
            vec![
                operand(o),
                list(
                    cs.iter()
                        .map(|(v, b)| Doc::Tuple(vec![n(v), n(b)]))
                        .collect(),
                ),
                n(d),
            ],
        ),
        Term::Ret => atom("Term.ret"),
        Term::Unreachable => atom("Term.unreachable"),
        Term::Drop(p, b) => app("Term.drop", vec![place(p), n(b)]),
        Term::Call(f, a, d, b) => app(
            "Term.call",
            vec![
                callee(f),
                list(a.iter().map(operand).collect()),
                place(d),
                match b {
                    Some(b) => app("some", vec![n(b)]),
                    None => atom("none"),
                },
            ],
        ),
        Term::Assert(o, e, b) => app("Term.assert", vec![operand(o), n(e), n(b)]),
    }
}
