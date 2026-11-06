//! MIR encodings of translated types.
//!
//! The typed backend translates crate types to Lean structures and
//! inductives; the MIR semantics (`Provium.Mir`) works on untyped `Val`s. This
//! module prints, for every translated type, its `Enc` instance (the MIR
//! value a shallow value stands for) and the `mir_enc` lemmas symbolic
//! execution uses to keep memory folded: reading a field of `enc x`, writing
//! one and refolding, the variant and scalar views, and folding an aggregate
//! built from encodings (`mkAgg`, keyed by each spelling of the type's MIR
//! path).
//!
//! Structs are `Val.agg 0` of their fields in declaration order and enum
//! variants `Val.agg j` with `j` the variant's declaration index, as in MIR
//! (explicit discriminants are rejected when the crate is loaded). A field of
//! function type is encoded by an `Enc` instance for that function type,
//! taken as an instance argument and carried through every type containing
//! it. Types whose values MIR does not hold inline (reference and slice
//! fields), or whose Lean shape is ambiguous (tuples of three or more
//! elements, which Lean nests as pairs), get no encoding, nor do the types
//! containing them; [`Output::skipped`] says why.
use super::emit::R;
use super::gen::{generic_binders, type_order};
use super::lean::{ident, Names, MOUNT};
use super::load::Krate;
use super::types::{Generics, Len, Scope, Ty};
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

/// Framework names the generated file uses unqualified; a crate item with
/// one of these names would make them ambiguous.
const RESERVED: &[&str] = &[
    "Val", "Path", "Ty", "Enc", "enc", "mkAgg", "AggKind", "Provium",
];

/// Local names the generated declarations bind.
const LOCALS: &[&str] = &["x", "y", "v", "r", "w", "p", "as"];

pub struct Output {
    /// The Lean module.
    pub lean: String,
    /// `example`s re-deriving a read, a write with its refold and an
    /// aggregate fold per encoded type with `simp only [mir_enc]`.
    pub checks: String,
    /// Crate paths of the encoded types, in order.
    pub encoded: Vec<String>,
    /// Crate paths of types given no encoding, with the reason.
    pub skipped: Vec<(String, String)>,
    /// Per encoded type (crate path), the function types whose `Enc`
    /// instances it takes as arguments, as Lean types.
    pub fn_args: Vec<(String, Vec<String>)>,
    /// Constructors (Lean names) whose `mkAgg` folds are plain theorems, not
    /// `mir_enc` lemmas, with the reason.
    pub unfolded: Vec<(String, String)>,
}

struct Ctor {
    /// The Rust variant name (structs: `mk`).
    name: String,
    /// Lean accessor names (structs) and field types.
    fields: Vec<(String, Ty)>,
}

struct Info {
    g: Generics,
    /// Function types (in the type's own parameters) whose `Enc` instances
    /// the encoding needs.
    reqs: Vec<Ty>,
}

/// Read the crate a `project.json` (typed project, with its differential
/// scenario mounted as the verifier does) or a crate root names, translate
/// it, and print the encodings of every type the translation emits. With a
/// crate root, `roots` are the functions to translate; with none, every crate
/// type is encoded. `module` is the Lean module name of the encodings, which
/// the checks import.
pub fn from_input(
    input: &Path,
    roots: &[String],
    namespace: Option<&str>,
    module: &str,
) -> R<Output> {
    let configuration = super::host_configuration()?;
    let is_project = input.extension().is_some_and(|e| e == "json");
    let (krate, roots, project_ns) = if is_project {
        let bytes = std::fs::read(input).map_err(|e| format!("{}: {e}", input.display()))?;
        let project: super::verify::TypedProject =
            serde_json::from_slice(&bytes).map_err(|e| e.to_string())?;
        let base = input.parent().unwrap_or(Path::new("."));
        let extras: Vec<(String, std::path::PathBuf)> = project
            .differential
            .iter()
            .map(|d| (MOUNT.to_owned(), base.join(&d.source)))
            .collect();
        let krate = Krate::load_with(
            &base.join(&project.crate_root),
            Some(configuration),
            &extras,
            project.differential.as_ref().map(|d| d.crate_name.as_str()),
        )?;
        let mut all = project.roots.clone();
        all.extend(roots.iter().cloned());
        if let Some(d) = &project.differential {
            all.push(format!("{MOUNT}::{}", d.function));
        }
        (krate, all, Some(project.namespace))
    } else {
        (
            Krate::load(input, Some(configuration))?,
            roots.to_vec(),
            None,
        )
    };
    let namespace = namespace
        .map(str::to_owned)
        .or(project_ns)
        .ok_or("mir-enc needs --namespace for a crate root")?;
    let types = if roots.is_empty() {
        let all: BTreeSet<String> = krate
            .structs
            .keys()
            .chain(krate.enums.keys())
            .cloned()
            .collect();
        type_order(&krate, &all)?.0
    } else {
        super::gen::generate(
            &krate,
            &roots,
            &super::gen::Options {
                namespace: namespace.clone(),
                overflow_checks: true,
                debug_assertions: true,
            },
        )?
        .types
    };
    generate(&krate, &types, &namespace, "Generated", module)
}

/// The encodings of `types` (crate paths, each after the types its fields
/// name), in the Lean namespace `<namespace>.Mir`, importing the translation
/// as `import`.
pub fn generate(
    k: &Krate,
    types: &[String],
    namespace: &str,
    import: &str,
    module: &str,
) -> R<Output> {
    let names = Names::new(k);
    for lean in names
        .types
        .values()
        .chain(names.consts.values())
        .chain(names.functions.values())
    {
        let root = lean.split('.').next().unwrap_or_default();
        if RESERVED.contains(&root) {
            return Err(format!(
                "crate item `{lean}` would shadow `Provium.Mir.{root}` in the encodings"
            ));
        }
    }
    let mut infos: BTreeMap<String, Info> = BTreeMap::new();
    let mut out = Output {
        lean: String::new(),
        checks: String::new(),
        encoded: vec![],
        skipped: vec![],
        fn_args: vec![],
        unfolded: vec![],
    };
    let mut body = String::new();
    let mut checks = String::new();
    for p in types {
        let (generics, module) = if let Some(s) = k.structs.get(p) {
            (&s.generics, &s.module)
        } else if let Some(e) = k.enums.get(p) {
            (&e.generics, &e.module)
        } else {
            return Err(format!("unknown type {p}"));
        };
        let mut g = Generics::default();
        g.extend(generics)?;
        for t in g.types.iter().chain(&g.consts) {
            if LOCALS.contains(&t.as_str()) || is_arg_name(t) {
                return Err(format!(
                    "{p}: generic parameter `{t}` collides with a name the encodings bind"
                ));
            }
        }
        let scope = Scope {
            krate: k,
            module,
            generics: &g,
            self_ty: None,
        };
        let (ctors, is_struct) = if let Some(s) = k.structs.get(p) {
            let fields = s
                .fields
                .iter()
                .map(|(n, t)| {
                    let name = if s.tuple {
                        format!("f{}", &n[1..])
                    } else {
                        ident(n)
                    };
                    Ok((name, scope.ty(t)?))
                })
                .collect::<R<Vec<_>>>()?;
            (
                vec![Ctor {
                    name: "mk".into(),
                    fields,
                }],
                true,
            )
        } else {
            let mut ctors = vec![];
            for v in &k.enums[p].variants {
                let fields = v
                    .fields
                    .iter()
                    .map(|(n, t)| Ok((n.clone(), scope.ty(t)?)))
                    .collect::<R<Vec<_>>>()?;
                ctors.push(Ctor {
                    name: v.name.clone(),
                    fields,
                });
            }
            (ctors, false)
        };
        if let Some(reason) = ctors
            .iter()
            .flat_map(|c| &c.fields)
            .find_map(|(_, t)| unencodable(t, &infos, &names))
        {
            out.skipped.push((p.clone(), reason));
            continue;
        }
        let mut reqs = vec![];
        for (_, t) in ctors.iter().flat_map(|c| &c.fields) {
            fn_reqs(t, &infos, &mut reqs);
        }
        dedup(&mut reqs, &names);
        let ty = Type {
            names: &names,
            path: p,
            module,
            lean: names.types[p].clone(),
            self_ty: names.ty(&Ty::Adt(
                p.clone(),
                g.types.iter().map(|t| Ty::Param(t.clone())).collect(),
                g.consts.iter().map(|c| Len::Param(c.clone())).collect(),
            )),
            binders: binders(&g, &reqs, &names),
            reqs: &reqs,
            explicit: g
                .types
                .iter()
                .chain(&g.consts)
                .map(|t| format!(" ({} := {})", ident(t), ident(t)))
                .collect(),
            g: &g,
        };
        if is_struct {
            body.push_str(&ty.structure(&ctors[0].fields, &mut out.unfolded));
            checks.push_str(&ty.struct_checks(&ctors[0].fields));
        } else {
            body.push_str(&ty.inductive(&ctors, &mut out.unfolded));
            checks.push_str(&ty.inductive_checks(&ctors));
        }
        out.encoded.push(p.clone());
        out.fn_args
            .push((p.clone(), reqs.iter().map(|t| names.ty(t)).collect()));
        infos.insert(p.clone(), Info { g, reqs });
    }
    let mut notes = String::new();
    for (p, args) in &out.fn_args {
        if !args.is_empty() {
            notes.push_str(&format!(
                "* `{}` takes `Enc` instances for its function fields: {}.\n",
                names.types[p],
                args.iter()
                    .map(|a| format!("`{a}`"))
                    .collect::<Vec<_>>()
                    .join(", ")
            ));
        }
    }
    for (p, why) in &out.skipped {
        notes.push_str(&format!("* `{p}` has no encoding: {why}.\n"));
    }
    for (c, why) in &out.unfolded {
        notes.push_str(&format!("* `{c}`: its `mkAgg` folds are not `mir_enc` lemmas ({why}); use them with the parameters given.\n"));
    }
    if !notes.is_empty() {
        notes.insert(0, '\n');
    }
    out.lean = format!(
        "/-\nGenerated by `provium mir-enc`. Do not edit.\n\nMIR encodings (`Provium.Mir.Enc`) of the types of `{import}`, with the\n`mir_enc` lemmas that read, write and build them.\n{notes}-/\nimport {import}\nimport Provium.Mir.Tactic\n\nopen Provium.Mir\n\nnamespace {namespace}.Mir\n\n{body}end {namespace}.Mir\n"
    );
    out.checks = format!(
        "/-\nGenerated by `provium mir-enc`: each encoding's laws, re-derived with\n`simp only [mir_enc]`.\n-/\nimport {module}\n\nopen Provium.Mir\n\nnamespace {namespace}.Mir\n\n{checks}end {namespace}.Mir\n"
    );
    Ok(out)
}

/// `a0`, `a1`, ...: constructor argument names.
fn is_arg_name(s: &str) -> bool {
    s.strip_prefix('a')
        .is_some_and(|d| !d.is_empty() && d.bytes().all(|b| b.is_ascii_digit()))
}

/// Why a field of this type has no encoding, if it has none.
fn unencodable(t: &Ty, infos: &BTreeMap<String, Info>, names: &Names) -> Option<String> {
    let sub = |t: &Ty| unencodable(t, infos, names);
    match t {
        Ty::Bool | Ty::Unit | Ty::Uint(..) | Ty::Param(_) | Ty::Fn(..) => None,
        Ty::Int(_, n) => Some(format!("a field of signed type `{n}` (no `Enc` instance)")),
        Ty::Tuple(v) if v.len() == 2 => v.iter().find_map(sub),
        Ty::Tuple(v) => Some(format!(
            "a field of a {}-tuple, which Lean nests as pairs (encoded as nested aggregates, not MIR's flat tuple)",
            v.len()
        )),
        Ty::Array(t, _) | Ty::Option(t) => sub(t),
        Ty::Result(a, b) => sub(a).or_else(|| sub(b)),
        Ty::Adt(q, a, _) if infos.contains_key(q) => a.iter().find_map(sub),
        Ty::Adt(q, ..) => Some(format!("a field of type `{q}`, which has no encoding")),
        Ty::Ref(..) => Some(
            "a reference field: MIR holds a pointer (`Val.ref`) to another place there, not the referent's value"
                .into(),
        ),
        Ty::Slice(_) => Some("a slice field (`Array` in Lean), which MIR holds only behind a reference".into()),
        t => Some(format!("a field of type `{}`, which has no value encoding", names.ty(t))),
    }
}

/// The function types inside `t` whose `Enc` instances encoding `t` needs.
fn fn_reqs(t: &Ty, infos: &BTreeMap<String, Info>, out: &mut Vec<Ty>) {
    match t {
        Ty::Fn(..) => out.push(t.clone()),
        Ty::Tuple(v) => v.iter().for_each(|t| fn_reqs(t, infos, out)),
        Ty::Array(t, _) | Ty::Option(t) => fn_reqs(t, infos, out),
        Ty::Result(a, b) => {
            fn_reqs(a, infos, out);
            fn_reqs(b, infos, out)
        }
        Ty::Adt(q, a, l) => {
            a.iter().for_each(|t| fn_reqs(t, infos, out));
            if let Some(i) = infos.get(q) {
                let tys: Vec<(String, Ty)> = i.g.types.iter().cloned().zip(a.clone()).collect();
                let lens: Vec<(String, Len)> = i.g.consts.iter().cloned().zip(l.clone()).collect();
                out.extend(i.reqs.iter().map(|r| r.subst(&tys, &lens)));
            }
        }
        _ => {}
    }
}

fn dedup(v: &mut Vec<Ty>, names: &Names) {
    let mut seen = BTreeSet::new();
    v.retain(|t| seen.insert(names.ty(t)));
}

/// Generic parameter names `t` mentions.
fn params(t: &Ty, out: &mut BTreeSet<String>) {
    let len = |l: &Len, out: &mut BTreeSet<String>| {
        if let Len::Param(p) = l {
            out.insert(p.clone());
        }
    };
    match t {
        Ty::Param(p) => {
            out.insert(p.clone());
        }
        Ty::Tuple(v) => v.iter().for_each(|t| params(t, out)),
        Ty::Array(t, l) => {
            params(t, out);
            len(l, out)
        }
        Ty::Slice(t)
        | Ty::Ref(_, t)
        | Ty::Option(t)
        | Ty::Iter(t)
        | Ty::Lazy(t)
        | Ty::Future(t)
        | Ty::Run(t) => params(t, out),
        Ty::Adt(_, a, l) => {
            a.iter().for_each(|t| params(t, out));
            l.iter().for_each(|l| len(l, out))
        }
        Ty::Result(a, b) => {
            params(a, out);
            params(b, out)
        }
        Ty::Fn(a, r) => {
            a.iter().for_each(|t| params(t, out));
            params(r, out)
        }
        Ty::Assoc(p, _, args, _) => {
            out.insert(p.clone());
            args.iter().for_each(|(_, t)| params(t, out))
        }
        _ => {}
    }
}

/// The implicit, `Enc` and function-instance binders of a type's declarations.
fn binders(g: &Generics, reqs: &[Ty], names: &Names) -> String {
    let encs: Vec<(String, String)> = g
        .types
        .iter()
        .map(|t| (t.clone(), "Enc".to_owned()))
        .collect();
    let mut s = generic_binders(g, &encs);
    for r in reqs {
        s.push_str(&format!(" [Enc {}]", names.ty(r)));
    }
    s
}

/// `simp only` lemmas that rewrite `Val.set` at field `i` of a literal list.
fn set_simp(i: usize) -> &'static str {
    if i == 0 {
        "Val.set, List.getElem?_cons_zero, List.set_cons_zero"
    } else {
        "Val.set, List.getElem?_cons_succ, List.getElem?_cons_zero, List.set_cons_succ, List.set_cons_zero"
    }
}

/// One type being printed.
struct Type<'a> {
    names: &'a Names,
    path: &'a str,
    module: &'a str,
    g: &'a Generics,
    /// Lean name (`State`).
    lean: String,
    /// The type at its own parameters (`(State V S CAP)`).
    self_ty: String,
    binders: String,
    reqs: &'a [Ty],
    /// ` (V := V) ...`: the parameters, for declarations that do not
    /// determine them.
    explicit: String,
}

impl Type<'_> {
    /// The MIR spellings of the type's path, with the lemma-name suffix of
    /// each: the bare name, and `module::Name` outside the crate root (a
    /// mounted scenario's root is its own crate's root).
    fn spellings(&self) -> Vec<(&'static str, String)> {
        let name = self.path.rsplit("::").next().unwrap();
        let module = if self.module == MOUNT {
            ""
        } else {
            self.module
                .strip_prefix(&format!("{MOUNT}::"))
                .unwrap_or(self.module)
        };
        let mut v = vec![("", name.to_owned())];
        if !module.is_empty() {
            v.push(("_q", format!("{module}::{name}")));
        }
        v
    }

    fn header(&self) -> String {
        let spell: Vec<String> = self
            .spellings()
            .iter()
            .map(|(_, s)| format!("`{s}`"))
            .collect();
        format!(
            "/-! ## `{}` (MIR path {}) -/\n\n",
            self.path,
            spell.join(", ")
        )
    }

    /// Why constructor `fields` cannot be folded from `mkAgg`, if so: a
    /// parameter its arguments do not determine.
    fn undetermined(&self, fields: &[(String, Ty)]) -> Option<String> {
        let mut seen = BTreeSet::new();
        fields.iter().for_each(|(_, t)| params(t, &mut seen));
        let missing: Vec<&String> = self
            .g
            .types
            .iter()
            .chain(&self.g.consts)
            .filter(|p| !seen.contains(*p))
            .collect();
        if missing.is_empty() {
            return None;
        }
        Some(format!(
            "its arguments do not determine {}",
            missing
                .iter()
                .map(|m| format!("`{m}`"))
                .collect::<Vec<_>>()
                .join(", ")
        ))
    }

    /// The attribute of a constructor's `mkAgg` folds: `mir_enc` when its
    /// arguments determine every parameter. Otherwise simp could not
    /// instantiate the rest, so the folds are plain theorems, used with the
    /// parameters given (`T.mir_mk_C (V := V)`), and are recorded.
    fn fold_attr(
        &self,
        fields: &[(String, Ty)],
        ctor: &str,
        unfolded: &mut Vec<(String, String)>,
    ) -> &'static str {
        match self.undetermined(fields) {
            Some(why) => {
                unfolded.push((ctor.to_owned(), why));
                ""
            }
            None => "@[mir_enc] ",
        }
    }

    /// The simp set that folds a constructor's aggregate: `mir_enc`, or its
    /// fold lemma at the type's parameters when that is not in `mir_enc`.
    fn fold_simp(&self, fields: &[(String, Ty)], lemma: &str) -> String {
        match self.undetermined(fields) {
            Some(_) => format!("{lemma}{}", self.explicit),
            None => "mir_enc".into(),
        }
    }

    /// Binders of a replacement function over a constructor's arguments,
    /// and the named arguments that apply it at the type's parameters. A
    /// parameter the arguments do not mention is still bound, so the
    /// function's uses name the full type and stay simp-usable, under a
    /// `_` name (it is unused).
    fn with_binders(&self, fields: &[(String, Ty)]) -> (String, String) {
        let mut seen = BTreeSet::new();
        fields.iter().for_each(|(_, t)| params(t, &mut seen));
        let rename = |p: &String| {
            if seen.contains(p) {
                p.clone()
            } else {
                format!("_{p}")
            }
        };
        let g = Generics {
            types: self.g.types.iter().map(rename).collect(),
            consts: self.g.consts.iter().map(rename).collect(),
            bounds: vec![],
        };
        let tys: Vec<(String, Ty)> = self
            .g
            .types
            .iter()
            .map(|p| (p.clone(), Ty::Param(rename(p))))
            .collect();
        let lens: Vec<(String, Len)> = self
            .g
            .consts
            .iter()
            .map(|p| (p.clone(), Len::Param(rename(p))))
            .collect();
        let reqs: Vec<Ty> = self.reqs.iter().map(|r| r.subst(&tys, &lens)).collect();
        let explicit = self
            .g
            .types
            .iter()
            .chain(&self.g.consts)
            .map(|p| format!(" ({} := {})", ident(&rename(p)), ident(p)))
            .collect();
        (binders(&g, &reqs, self.names), explicit)
    }

    fn arg_binders(&self, fields: &[(String, Ty)], skip: Option<usize>) -> String {
        fields
            .iter()
            .enumerate()
            .map(|(i, (_, t))| {
                let n = if Some(i) == skip {
                    "_".to_owned()
                } else {
                    format!("a{i}")
                };
                format!(" ({n} : {})", self.names.ty(t))
            })
            .collect()
    }

    fn args(n: usize) -> String {
        (0..n).map(|i| format!(" a{i}")).collect()
    }

    fn encs(n: usize) -> String {
        (0..n)
            .map(|i| format!("enc a{i}"))
            .collect::<Vec<_>>()
            .join(", ")
    }

    fn structure(&self, fields: &[(String, Ty)], unfolded: &mut Vec<(String, String)>) -> String {
        let (l, b, t) = (&self.lean, &self.binders, &self.self_ty);
        let mut s = self.header();
        let encs: Vec<String> = fields.iter().map(|(f, _)| format!("enc x.{f}")).collect();
        let x = if fields.is_empty() { "_" } else { "x" };
        s.push_str(&format!(
            "instance{b} : Enc {t} := ⟨fun {x} => .agg 0 [{}]⟩\n\n",
            encs.join(", ")
        ));
        for (i, (f, fty)) in fields.iter().enumerate() {
            let mut with = encs.clone();
            with[i] = "v".into();
            let x = if fields.len() == 1 { "_x" } else { "x" };
            s.push_str(&format!(
                "def {l}.with{i}{b} ({x} : {t}) (v : Val) : Val := .agg 0 [{}]\n",
                with.join(", ")
            ));
            s.push_str(&format!(
                "@[mir_enc] theorem {l}.mir_get{i}{b} (x : {t}) (r : Path) :\n    (enc x).get ({i} :: r) = (enc x.{f}).get r := rfl\n"
            ));
            s.push_str(&format!(
                "@[mir_enc] theorem {l}.mir_set{i}{b} (x : {t}) (r : Path) (w : Val) :\n    (enc x).set ({i} :: r) w = ((enc x.{f}).set r w).map ({l}.with{i} x) := by\n  show (Val.agg 0 _).set _ _ = _\n  simp only [{}]; rfl\n",
                set_simp(i)
            ));
            s.push_str(&format!(
                "@[mir_enc] theorem {l}.mir_with{i}{b} (x : {t}) (y : {}) :\n    {l}.with{i} x (enc y) = enc {{ x with {f} := y }} := rfl\n\n",
                self.names.ty(fty)
            ));
        }
        s.push_str(&format!(
            "@[mir_enc] theorem {l}.mir_variant{b} (x : {t}) : (enc x).variantOf = some 0 := rfl\n@[mir_enc] theorem {l}.mir_asInt{b} (x : {t}) : (enc x).asInt = none := rfl\n@[mir_enc] theorem {l}.mir_asBool{b} (x : {t}) : (enc x).asBool = none := rfl\n"
        ));
        let attr = self.fold_attr(fields, &format!("{l}.mk"), unfolded);
        for (suffix, path) in self.spellings() {
            s.push_str(&format!(
                "{attr}theorem {l}.mir_mk{suffix}{b} (as : List Ty) (p : String){} :\n    mkAgg (.adt \"{path}\" as) (.adt p 0) [{}] = enc ({l}.mk{} : {t}) := rfl\n",
                self.arg_binders(fields, None),
                Self::encs(fields.len()),
                Self::args(fields.len()),
            ));
        }
        s.push('\n');
        s
    }

    fn inductive(&self, ctors: &[Ctor], unfolded: &mut Vec<(String, String)>) -> String {
        let (l, b, t) = (&self.lean, &self.binders, &self.self_ty);
        let mut s = self.header();
        s.push_str(&format!("def {l}.mirEnc{b} : {t} → Val"));
        if ctors.is_empty() {
            s.push_str(" := fun x => nomatch x\n");
        } else {
            s.push('\n');
        }
        for (j, c) in ctors.iter().enumerate() {
            s.push_str(&format!(
                "  | .{}{} => .agg {j} [{}]\n",
                ident(&c.name),
                Self::args(c.fields.len()),
                Self::encs(c.fields.len())
            ));
        }
        s.push_str(&format!("instance{b} : Enc {t} := ⟨{l}.mirEnc⟩\n\n"));
        for (j, c) in ctors.iter().enumerate() {
            let n = &c.name;
            let n_fields = c.fields.len();
            let value = format!("({l}.{}{} : {t})", ident(n), Self::args(n_fields));
            let all = self.arg_binders(&c.fields, None);
            let (wb, we) = self.with_binders(&c.fields);
            s.push_str(&format!(
                "@[mir_enc] theorem {l}.mir_variant_{n}{b}{all} :\n    (enc {value}).variantOf = some {j} := rfl\n"
            ));
            for (i, (_, fty)) in c.fields.iter().enumerate() {
                let mut with: Vec<String> = (0..n_fields).map(|k| format!("enc a{k}")).collect();
                with[i] = "v".into();
                let mut replaced: Vec<String> = (0..n_fields).map(|k| format!("a{k}")).collect();
                replaced[i] = "y".into();
                s.push_str(&format!(
                    "@[mir_enc] theorem {l}.mir_get_{n}_{i}{b}{all} (r : Path) :\n    (enc {value}).get ({i} :: r) = (enc a{i}).get r := rfl\n"
                ));
                s.push_str(&format!(
                    "def {l}.with_{n}_{i}{wb}{} (v : Val) : Val := .agg {j} [{}]\n",
                    self.arg_binders(&c.fields, Some(i)),
                    with.join(", ")
                ));
                s.push_str(&format!(
                    "@[mir_enc] theorem {l}.mir_set_{n}_{i}{b}{all} (r : Path) (w : Val) :\n    (enc {value}).set ({i} :: r) w = ((enc a{i}).set r w).map ({l}.with_{n}_{i}{we}{}) := by\n  show (Val.agg {j} _).set _ _ = _\n  simp only [{}]; rfl\n",
                    Self::args(n_fields),
                    set_simp(i)
                ));
                s.push_str(&format!(
                    "@[mir_enc] theorem {l}.mir_with_{n}_{i}{b}{all} (y : {}) :\n    {l}.with_{n}_{i}{we}{} (enc y) = enc ({l}.{} {} : {t}) := rfl\n",
                    self.names.ty(fty),
                    Self::args(n_fields),
                    ident(n),
                    replaced.join(" ")
                ));
            }
            let attr = self.fold_attr(&c.fields, &format!("{l}.{n}"), unfolded);
            for (suffix, path) in self.spellings() {
                s.push_str(&format!(
                    "{attr}theorem {l}.mir_mk_{n}{suffix}{b} (as : List Ty) (p : String){all} :\n    mkAgg (.adt \"{path}\" as) (.adt p {j}) [{}] = enc {value} := rfl\n",
                    Self::encs(n_fields),
                ));
            }
            s.push('\n');
        }
        s.push_str(&format!(
            "@[mir_enc] theorem {l}.mir_asInt{b} (x : {t}) : (enc x).asInt = none := by cases x <;> rfl\n@[mir_enc] theorem {l}.mir_asBool{b} (x : {t}) : (enc x).asBool = none := by cases x <;> rfl\n\n"
        ));
        s
    }

    fn struct_checks(&self, fields: &[(String, Ty)]) -> String {
        let (l, b, t) = (&self.lean, &self.binders, &self.self_ty);
        let mut s = format!("-- `{}`\n", self.path);
        s.push_str(&format!(
            "example{b} (x : {t}) : (enc x).variantOf = some 0 ∧ (enc x).asInt = none := by\n  simp only [mir_enc, and_self]\n"
        ));
        let last = fields.len().saturating_sub(1);
        if let Some((f, fty)) = fields.get(last) {
            s.push_str(&format!(
                "example{b} (x : {t}) : (enc x).get [{last}] = some (enc x.{f}) := by\n  simp only [mir_enc]\n"
            ));
            s.push_str(&format!(
                "example{b} (x : {t}) (y : {}) :\n    (enc x).set [{last}] (enc y) = some (enc {{ x with {f} := y }}) := by\n  simp only [mir_enc, Val.set, Option.map_some]\n",
                self.names.ty(fty)
            ));
        }
        let (suffix, path) = self.spellings().pop().unwrap();
        s.push_str(&format!(
            "example{b}{} :\n    mkAgg (.adt \"{path}\" []) (.adt \"{path}\" 0) [{}] = enc ({l}.mk{} : {t}) := by\n  simp only [{}]\n",
            self.arg_binders(fields, None),
            Self::encs(fields.len()),
            Self::args(fields.len()),
            self.fold_simp(fields, &format!("{l}.mir_mk{suffix}"))
        ));
        s.push('\n');
        s
    }

    fn inductive_checks(&self, ctors: &[Ctor]) -> String {
        let (l, b, t) = (&self.lean, &self.binders, &self.self_ty);
        let mut s = format!("-- `{}`\n", self.path);
        for (j, c) in ctors.iter().enumerate() {
            let n_fields = c.fields.len();
            let all = self.arg_binders(&c.fields, None);
            let value = format!("({l}.{}{} : {t})", ident(&c.name), Self::args(n_fields));
            s.push_str(&format!(
                "example{b}{all} : (enc {value}).variantOf = some {j} ∧ (enc {value}).asBool = none := by\n  simp only [mir_enc, and_self]\n"
            ));
            if let Some(i) = n_fields.checked_sub(1) {
                let mut replaced: Vec<String> = (0..n_fields).map(|k| format!("a{k}")).collect();
                replaced[i] = "y".into();
                s.push_str(&format!(
                    "example{b}{all} : (enc {value}).get [{i}] = some (enc a{i}) := by\n  simp only [mir_enc]\n"
                ));
                s.push_str(&format!(
                    "example{b}{all} (y : {}) :\n    (enc {value}).set [{i}] (enc y) = some (enc ({l}.{} {} : {t})) := by\n  simp only [mir_enc, Val.set, Option.map_some]\n",
                    self.names.ty(&c.fields[i].1),
                    ident(&c.name),
                    replaced.join(" ")
                ));
            }
            let (suffix, path) = self.spellings().pop().unwrap();
            s.push_str(&format!(
                "example{b}{all} :\n    mkAgg (.adt \"{path}\" []) (.adt \"{path}\" {j}) [{}] = enc {value} := by\n  simp only [{}]\n",
                Self::encs(n_fields),
                self.fold_simp(&c.fields, &format!("{l}.mir_mk_{}{suffix}", c.name))
            ));
        }
        s.push('\n');
        s
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const LIB: &str = "pub mod m;
pub struct Id(pub u64);
pub struct Pair<V, const N: usize> { id: Id, from: [Option<V>; N], hook: fn(&V) -> Id }
pub struct Holder<V> { inner: Option<m::Inner<V>> }
pub enum E<V> { A, B(u64, V), C { x: bool } }
pub enum Plain { P, Q(Id) }
pub struct Borrow<'a> { r: &'a Id }
pub struct Outer<'a> { b: Borrow<'a> }
pub struct Triple { t: (u64, u64, u64) }
pub enum G<V, const N: usize> { Only(V), Arr([u64; N]) }
";
    const M: &str = "pub struct Inner<V> { pair: crate::Pair<V, 2>, f: fn(&V) -> u64 }\n";

    fn krate() -> Krate {
        // Tests run in parallel: one directory per call.
        static N: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let n = N.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!("provium-mirenc-{}-{n}", std::process::id()));
        std::fs::create_dir_all(dir.join("src")).unwrap();
        std::fs::write(dir.join("src/lib.rs"), LIB).unwrap();
        std::fs::write(dir.join("src/m.rs"), M).unwrap();
        let k = Krate::load(&dir.join("src/lib.rs"), None).unwrap();
        std::fs::remove_dir_all(&dir).unwrap();
        k
    }

    fn output() -> Output {
        let k = krate();
        let all: BTreeSet<String> = k.structs.keys().chain(k.enums.keys()).cloned().collect();
        let order = type_order(&k, &all).unwrap().0;
        generate(&k, &order, "T", "Generated", "GeneratedEnc").unwrap()
    }

    #[test]
    fn structs_are_aggregates_of_their_fields() {
        let o = output();
        assert!(o
            .lean
            .contains("instance : Enc Id := ⟨fun x => .agg 0 [enc x.f0]⟩\n"));
        assert!(o
            .lean
            .contains("def Id.with0 (_x : Id) (v : Val) : Val := .agg 0 [v]\n"));
        assert!(o.lean.contains(
            "@[mir_enc] theorem Id.mir_set0 (x : Id) (r : Path) (w : Val) :\n    (enc x).set (0 :: r) w = ((enc x.f0).set r w).map (Id.with0 x) := by\n  show (Val.agg 0 _).set _ _ = _\n  simp only [Val.set, List.getElem?_cons_zero, List.set_cons_zero]; rfl\n"
        ));
        assert!(o.lean.contains(
            "@[mir_enc] theorem Id.mir_mk (as : List Ty) (p : String) (a0 : Rust.u64) :\n    mkAgg (.adt \"Id\" as) (.adt p 0) [enc a0] = enc (Id.mk a0 : Id) := rfl\n"
        ));
        // Keyword fields are escaped; later fields use the successor lemmas.
        assert!(o.lean.contains(
            "@[mir_enc] theorem Pair.mir_get1 {V : Type} {N : Nat} [Enc V] [Enc (V → Rust.M Id)] (x : (Pair V N)) (r : Path) :\n    (enc x).get (1 :: r) = (enc x.«from»).get r := rfl\n"
        ));
        assert!(o.lean.contains("simp only [Val.set, List.getElem?_cons_succ, List.getElem?_cons_zero, List.set_cons_succ, List.set_cons_zero]; rfl\n"));
        assert!(o.lean.contains("enc { x with «from» := y } := rfl\n"));
    }

    #[test]
    fn function_instances_are_carried_through_containing_types() {
        let o = output();
        let args: BTreeMap<_, _> = o.fn_args.iter().cloned().collect();
        assert_eq!(args["Pair"], vec!["(V → Rust.M Id)"]);
        assert_eq!(
            args["m::Inner"],
            vec!["(V → Rust.M Id)", "(V → Rust.M Rust.u64)"]
        );
        assert_eq!(args["Holder"], args["m::Inner"]);
        assert!(o.lean.contains(
            "instance {V : Type} [Enc V] [Enc (V → Rust.M Id)] [Enc (V → Rust.M Rust.u64)] : Enc (Holder V) :="
        ));
    }

    #[test]
    fn module_types_fold_from_both_spellings() {
        let o = output();
        assert!(o.lean.contains("theorem Inner.mir_mk {V : Type}"));
        assert!(o.lean.contains("mkAgg (.adt \"Inner\" as) (.adt p 0)"));
        assert!(o.lean.contains("theorem Inner.mir_mk_q {V : Type}"));
        assert!(o.lean.contains("mkAgg (.adt \"m::Inner\" as) (.adt p 0)"));
    }

    #[test]
    fn enums_are_variants_in_declaration_order() {
        let o = output();
        assert!(o.lean.contains(
            "def E.mirEnc {V : Type} [Enc V] : (E V) → Val\n  | .A => .agg 0 []\n  | .B a0 a1 => .agg 1 [enc a0, enc a1]\n  | .C a0 => .agg 2 [enc a0]\n"
        ));
        assert!(o.lean.contains(
            "def E.with_B_1 {V : Type} [Enc V] (a0 : Rust.u64) (_ : V) (v : Val) : Val := .agg 1 [enc a0, v]\n"
        ));
        assert!(o.lean.contains(
            "((enc a1).set r w).map (E.with_B_1 (V := V) a0 a1) := by\n  show (Val.agg 1 _).set _ _ = _\n"
        ));
        assert!(o
            .lean
            .contains("    E.with_B_1 (V := V) a0 a1 (enc y) = enc (E.B a0 y : (E V)) := rfl\n"));
        assert!(o
            .lean
            .contains("mkAgg (.adt \"Plain\" as) (.adt p 0) [] = enc (Plain.P : Plain) := rfl\n"));
        assert!(o
            .lean
            .contains("(enc x).asInt = none := by cases x <;> rfl\n"));
        // Constructors whose arguments do not fix the parameters fold only
        // with the parameters given: plain theorems, outside `mir_enc`.
        assert!(o.lean.contains("\ntheorem E.mir_mk_A {V : Type}"));
        assert!(o.lean.contains("\ntheorem E.mir_mk_C {V : Type}"));
        assert!(o.lean.contains("@[mir_enc] theorem E.mir_mk_B {V : Type}"));
        assert!(o.checks.contains("simp only [E.mir_mk_A (V := V)]\n"));
        // Parameters a replacement function's arguments leave out are bound
        // under `_` names, and given at its uses.
        assert!(o.lean.contains("(G.with_Only_0 (V := V) (_N := N) a0)"));
        assert!(o.lean.contains(
            "def G.with_Only_0 {V : Type} {_N : Nat} [Enc V] (_ : V) (v : Val) : Val := .agg 0 [v]\n"
        ));
        assert!(o.lean.contains(
            "def G.with_Arr_0 {_V : Type} {N : Nat} [Enc _V] (_ : (Vector Rust.u64 N)) (v : Val) : Val := .agg 1 [v]\n"
        ));
        assert_eq!(
            o.unfolded,
            vec![
                (
                    "E.A".to_owned(),
                    "its arguments do not determine `V`".to_owned()
                ),
                (
                    "E.C".to_owned(),
                    "its arguments do not determine `V`".to_owned()
                ),
                (
                    "G.Only".to_owned(),
                    "its arguments do not determine `N`".to_owned()
                ),
                (
                    "G.Arr".to_owned(),
                    "its arguments do not determine `V`".to_owned()
                ),
            ]
        );
    }

    #[test]
    fn references_and_wide_tuples_are_skipped_with_their_containers() {
        let o = output();
        let skipped: BTreeMap<_, _> = o.skipped.iter().cloned().collect();
        assert!(skipped["Borrow"].starts_with("a reference field"));
        assert_eq!(
            skipped["Outer"],
            "a field of type `Borrow`, which has no encoding"
        );
        assert!(skipped["Triple"].starts_with("a field of a 3-tuple"));
        assert!(!o.lean.contains("Enc Borrow"));
        assert!(o
            .lean
            .contains("* `Borrow` has no encoding: a reference field"));
    }

    #[test]
    fn checks_rederive_reads_writes_and_folds() {
        let o = output();
        assert!(o.checks.starts_with("/-\nGenerated by `provium mir-enc`"));
        assert!(o.checks.contains("import GeneratedEnc\n"));
        assert!(o.checks.contains(
            "example (x : Id) (y : Rust.u64) :\n    (enc x).set [0] (enc y) = some (enc { x with f0 := y }) := by\n  simp only [mir_enc, Val.set, Option.map_some]\n"
        ));
        assert!(o.checks.contains(
            "mkAgg (.adt \"m::Inner\" []) (.adt \"m::Inner\" 0) [enc a0, enc a1] = enc (Inner.mk a0 a1 : (Inner V)) := by\n"
        ));
    }

    #[test]
    fn colliding_names_are_rejected() {
        let dir = std::env::temp_dir().join(format!("provium-mirenc-c-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("lib.rs"), "pub struct Val(u64);\n").unwrap();
        let k = Krate::load(&dir.join("lib.rs"), None).unwrap();
        std::fs::remove_dir_all(&dir).unwrap();
        let e = generate(&k, &["Val".to_owned()], "T", "Generated", "GeneratedEnc")
            .err()
            .unwrap();
        assert!(e.contains("shadow `Provium.Mir.Val`"), "{e}");
    }
}
