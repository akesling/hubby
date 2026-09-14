//! Whole-body translation for methods made exclusively of literal assignments.
//! No statement is sliced away or accepted as an opaque call.
use crate::project::{hash, Obligation, AUDIT, TOOLCHAIN};
use quote::ToTokens;
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
    process::Command,
};
use syn::{spanned::Spanned, Expr, Item, Type};
const SEMANTICS: &str = include_str!("../lean/Provium/State.lean");
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Project {
    pub crate_root: PathBuf,
    pub namespace: String,
    pub methods: Vec<String>,
    pub proofs: PathBuf,
    pub obligations: Vec<Obligation>,
}
#[derive(Serialize)]
pub struct Input {
    pub path: PathBuf,
    pub sha256: String,
    pub snapshot: String,
}
#[derive(Clone, Debug, Serialize)]
pub struct Write {
    pub path: Vec<String>,
    pub rust_type: String,
    pub literal: Literal,
    pub line: usize,
}
#[derive(Clone, Debug, Serialize)]
pub enum Literal {
    Boolean(bool),
    Absent,
}
#[derive(Debug, Serialize)]
pub struct Method {
    pub name: String,
    pub symbol: String,
    pub source: PathBuf,
    pub first_line: usize,
    pub last_line: usize,
    pub rust: String,
    pub writes: Vec<Write>,
}
struct Definition {
    module: String,
    file: PathBuf,
    item: syn::ImplItemFn,
    receiver: String,
}
pub struct Crate {
    files: BTreeMap<PathBuf, String>,
    structs: BTreeMap<String, syn::ItemStruct>,
    struct_modules: BTreeMap<String, String>,
    imports: BTreeMap<(String, String), Vec<String>>,
    methods: BTreeMap<String, Definition>,
    drops: Vec<String>,
}
fn tokens(t: &impl ToTokens) -> String {
    t.to_token_stream().to_string()
}
fn test_only(attrs: &[syn::Attribute]) -> bool {
    attrs.iter().any(|a| {
        a.path().is_ident("cfg") && a.parse_args::<syn::Ident>().is_ok_and(|i| i == "test")
    })
}
fn attrs(attrs: &[syn::Attribute]) -> Result<(), String> {
    for a in attrs {
        if !a.path().is_ident("doc") {
            return Err(format!("unsupported method/field attribute {}", tokens(a)));
        }
    }
    Ok(())
}
fn base_type(ty: &Type) -> Result<String, String> {
    match ty {
        Type::Reference(r) if r.mutability.is_some() => base_type(&r.elem),
        Type::Path(p) if p.qself.is_none() && p.path.segments.len() == 1 => {
            Ok(p.path.segments[0].ident.to_string())
        }
        _ => Err(format!(
            "unresolved or unsupported field type {}",
            tokens(ty)
        )),
    }
}
fn path(e: &Expr) -> Result<Vec<String>, String> {
    match e {
        Expr::Path(p) if p.path.is_ident("self") && p.qself.is_none() => {
            attrs(&p.attrs)?;
            Ok(vec![])
        }
        Expr::Field(f) => {
            attrs(&f.attrs)?;
            let mut p = path(&f.base)?;
            let syn::Member::Named(name) = &f.member else {
                return Err("tuple fields unsupported".into());
            };
            p.push(name.to_string());
            Ok(p)
        }
        _ => Err("assignment target must be a named field rooted at self".into()),
    }
}
impl Crate {
    pub fn load(root: &Path) -> Result<Self, String> {
        let mut krate = Self {
            files: BTreeMap::new(),
            structs: BTreeMap::new(),
            struct_modules: BTreeMap::new(),
            imports: BTreeMap::new(),
            methods: BTreeMap::new(),
            drops: vec![],
        };
        krate.file(root, "", true)?;
        Ok(krate)
    }
    fn file(&mut self, path: &Path, module: &str, root: bool) -> Result<(), String> {
        let path = path.canonicalize().map_err(|e| e.to_string())?;
        let text = fs::read_to_string(&path).map_err(|e| e.to_string())?;
        let file = syn::parse_file(&text).map_err(|e| e.to_string())?;
        for attr in &file.attrs {
            if !["no_std", "forbid", "deny", "warn", "allow", "doc"]
                .iter()
                .any(|n| attr.path().is_ident(n))
            {
                return Err(format!("unsupported file attribute {}", tokens(attr)));
            }
        }
        if self.files.insert(path.clone(), text).is_some() {
            return Err("duplicate/cyclic module file".into());
        }
        let dir = if root || path.file_name().is_some_and(|p| p == "mod.rs") {
            path.parent().unwrap().to_owned()
        } else {
            path.with_extension("")
        };
        for item in file.items {
            match item {
                Item::Mod(m) if !test_only(&m.attrs) => {
                    attrs(&m.attrs)?;
                    if m.content.is_some() {
                        return Err("inline production modules are not supported yet".into());
                    }
                    let child = if module.is_empty() {
                        m.ident.to_string()
                    } else {
                        format!("{module}::{}", m.ident)
                    };
                    let flat = dir.join(format!("{}.rs", m.ident));
                    let nested = dir.join(m.ident.to_string()).join("mod.rs");
                    if flat.exists() == nested.exists() {
                        return Err(format!("module {child} has ambiguous/missing source"));
                    }
                    self.file(if flat.exists() { &flat } else { &nested }, &child, false)?;
                }
                Item::Use(u) if !test_only(&u.attrs) => {
                    fn check(tree: &syn::UseTree) -> Result<(), String> {
                        match tree {
                            syn::UseTree::Rename(_) | syn::UseTree::Glob(_) => {
                                Err("renamed/glob imports require qualified resolution".into())
                            }
                            syn::UseTree::Name(n)
                                if ["None", "Option", "bool", "u64"]
                                    .iter()
                                    .any(|s| n.ident == *s) =>
                            {
                                Err("shadowed primitive/prelude names are unsupported".into())
                            }
                            syn::UseTree::Path(p) => check(&p.tree),
                            syn::UseTree::Group(g) => {
                                for t in &g.items {
                                    check(t)?
                                }
                                Ok(())
                            }
                            _ => Ok(()),
                        }
                    }
                    check(&u.tree)?;
                    fn imports(
                        tree: &syn::UseTree,
                        prefix: &[String],
                        out: &mut Vec<(String, Vec<String>)>,
                    ) {
                        match tree {
                            syn::UseTree::Path(p) => {
                                let mut path = prefix.to_vec();
                                path.push(p.ident.to_string());
                                imports(&p.tree, &path, out)
                            }
                            syn::UseTree::Name(n) => {
                                let mut path = prefix.to_vec();
                                path.push(n.ident.to_string());
                                out.push((n.ident.to_string(), path))
                            }
                            syn::UseTree::Group(g) => {
                                for t in &g.items {
                                    imports(t, prefix, out)
                                }
                            }
                            _ => {}
                        }
                    }
                    let mut entries = vec![];
                    imports(&u.tree, &[], &mut entries);
                    for (name, path) in entries {
                        if self
                            .imports
                            .insert((module.to_owned(), name), path)
                            .is_some()
                        {
                            return Err(
                                "duplicate import binding requires qualified resolution".into()
                            );
                        }
                    }
                }
                Item::Enum(e) if ["Option", "bool", "u64"].iter().any(|n| e.ident == *n) => {
                    return Err("shadowed primitive/prelude type".into())
                }
                Item::Const(c) if c.ident == "None" => {
                    return Err("shadowed None constructor".into())
                }
                Item::Static(c) if c.ident == "None" => {
                    return Err("shadowed None constructor".into())
                }
                Item::Macro(_) => {
                    return Err("item macros require expansion before method verification".into())
                }
                Item::Type(t) if !test_only(&t.attrs) => {
                    return Err(format!(
                        "type alias {} requires qualified type resolution",
                        t.ident
                    ))
                }
                Item::Struct(s) if !test_only(&s.attrs) => {
                    if ["Option", "bool", "u64"].iter().any(|n| s.ident == *n) {
                        return Err("shadowed primitive/prelude type".into());
                    }
                    for attr in &s.attrs {
                        if attr.path().is_ident("doc") || attr.path().is_ident("must_use") {
                            continue;
                        }
                        if attr.path().is_ident("cfg_attr")
                            && tokens(attr) == "# [cfg_attr (test , derive (Clone))]"
                        {
                            continue;
                        }
                        if attr.path().is_ident("derive") {
                            let derives=attr.parse_args_with(syn::punctuated::Punctuated::<syn::Ident,syn::Token![,]>::parse_terminated).map_err(|e|e.to_string())?;
                            if derives.iter().all(|i| {
                                ["Clone", "Copy", "Debug", "Default", "Eq", "PartialEq"]
                                    .iter()
                                    .any(|s| i == *s)
                            }) {
                                continue;
                            }
                        }
                        return Err(format!("unsupported struct attribute {}", tokens(attr)));
                    }
                    self.struct_modules
                        .insert(s.ident.to_string(), module.to_owned());
                    if self.structs.insert(s.ident.to_string(), s).is_some() {
                        return Err(
                            "ambiguous struct name; qualified type resolution required".into()
                        );
                    }
                }
                Item::Impl(i) if !test_only(&i.attrs) => {
                    let receiver = base_type(&i.self_ty)?;
                    attrs(&i.attrs)?;
                    if let Some((_, trait_path, _)) = &i.trait_ {
                        if trait_path
                            .segments
                            .last()
                            .is_some_and(|s| s.ident == "Drop")
                        {
                            self.drops.push(receiver)
                        }
                        continue;
                    }
                    for member in i.items {
                        if let syn::ImplItem::Fn(method) = member {
                            if test_only(&method.attrs) {
                                continue;
                            }
                            let name = format!("{module}::{receiver}::{}", method.sig.ident)
                                .trim_start_matches("::")
                                .to_string();
                            if self
                                .methods
                                .insert(
                                    name,
                                    Definition {
                                        module: module.to_owned(),
                                        file: path.clone(),
                                        item: method,
                                        receiver: receiver.clone(),
                                    },
                                )
                                .is_some()
                            {
                                return Err("ambiguous method".into());
                            }
                        }
                    }
                }
                _ => {}
            }
        }
        Ok(())
    }
    fn resolve(&self, module: &str, name: &str, depth: usize) -> Result<String, String> {
        if depth > 32 {
            return Err("cyclic type re-export".into());
        }
        if self.struct_modules.get(name).is_some_and(|m| m == module) {
            return Ok(name.into());
        }
        let path = self
            .imports
            .get(&(module.to_owned(), name.to_owned()))
            .ok_or_else(|| format!("type {name} is not resolved in module {module}"))?;
        let (base, parts) = match path.first().map(String::as_str) {
            Some("crate") => (String::new(), &path[1..]),
            Some("self") => (module.to_owned(), &path[1..]),
            Some("super") => (
                module.rsplit_once("::").map_or("", |p| p.0).to_owned(),
                &path[1..],
            ),
            _ => (module.to_owned(), path.as_slice()),
        };
        let (last, parents) = parts.split_last().ok_or("empty import path")?;
        let mut target = base;
        for parent in parents {
            if !target.is_empty() {
                target.push_str("::")
            }
            target.push_str(parent)
        }
        self.resolve(&target, last, depth + 1)
    }
    pub fn inventory(&self) -> Vec<String> {
        self.methods.keys().cloned().collect()
    }
    pub fn lower(&self, name: &str) -> Result<Method, String> {
        let def = self
            .methods
            .get(name)
            .ok_or_else(|| format!("unknown method {name}"))?;
        let f = &def.item;
        attrs(&f.attrs)?;
        let sig = &f.sig;
        if sig.asyncness.is_some()
            || sig.unsafety.is_some()
            || sig.constness.is_some()
            || sig.abi.is_some()
            || !sig.generics.params.is_empty()
            || sig.generics.where_clause.is_some()
            || sig.inputs.len() != 1
            || !matches!(sig.output, syn::ReturnType::Default)
        {
            return Err(
                "only unit-returning receiver-only methods are supported by the assignment backend"
                    .into(),
            );
        }
        let Some(syn::FnArg::Receiver(receiver)) = sig.inputs.first() else {
            return Err("method requires a receiver".into());
        };
        if receiver.colon_token.is_some() {
            return Err("explicit receiver types unsupported".into());
        }
        attrs(&receiver.attrs)?;
        if receiver.reference.is_some() && receiver.mutability.is_none() {
            return Err("shared receiver unsupported".into());
        }
        self.resolve(&def.module, &def.receiver, 0)?;
        let structure = self
            .structs
            .get(&def.receiver)
            .ok_or("receiver is not a resolved struct")?;
        if self.drops.contains(&def.receiver) {
            return Err("custom receiver destructor requires effect semantics".into());
        }
        // Consuming a wrapper may implicitly drop its fields. Admit only wrappers
        // consisting entirely of mutable references (which have no destructor).
        if receiver.reference.is_none()
            && !structure
                .fields
                .iter()
                .all(|f| matches!(&f.ty,Type::Reference(r) if r.mutability.is_some()))
        {
            return Err("consumed receiver has potentially dropping fields".into());
        }
        if structure
            .generics
            .type_params()
            .any(|p| ["Option", "bool", "u64"].iter().any(|n| p.ident == *n))
        {
            return Err("generic parameter shadows a primitive/prelude type".into());
        }
        let mut writes = vec![];
        for stmt in &f.block.stmts {
            let syn::Stmt::Expr(Expr::Assign(assign), Some(_)) = stmt else {
                return Err(format!(
                    "unsupported complete-method statement at line {}: {}",
                    stmt.span().start().line,
                    tokens(stmt)
                ));
            };
            attrs(&assign.attrs)?;
            let p = path(&assign.left)?;
            if p.is_empty() {
                return Err("receiver replacement unsupported".into());
            }
            let mut current = def.receiver.clone();
            let mut field_type = None;
            for (index, part) in p.iter().enumerate() {
                let structure = self
                    .structs
                    .get(&current)
                    .ok_or_else(|| format!("unresolved struct {current}"))?;
                if structure
                    .generics
                    .type_params()
                    .any(|p| ["Option", "bool", "u64"].iter().any(|n| p.ident == *n))
                {
                    return Err("generic parameter shadows a primitive/prelude type".into());
                }
                let field = structure
                    .fields
                    .iter()
                    .find(|f| f.ident.as_ref().is_some_and(|n| n == part))
                    .ok_or_else(|| format!("unknown field {current}.{part}"))?;
                attrs(&field.attrs)?;
                if index + 1 < p.len() {
                    let named = base_type(&field.ty)?;
                    if structure.generics.type_params().any(|p| p.ident == named) {
                        return Err("generic field traversal requires type substitution".into());
                    }
                    current = self.resolve(&self.struct_modules[&current], &named, 0)?;
                    if structure.generics.type_params().any(|p| p.ident == current) {
                        return Err("generic field traversal requires type substitution".into());
                    }
                } else {
                    field_type = Some(&field.ty)
                }
            }
            let ty = field_type.unwrap();
            let literal = match (&*assign.right, tokens(ty).as_str()) {
                (Expr::Lit(lit), "bool") => {
                    attrs(&lit.attrs)?;
                    let syn::Lit::Bool(b) = &lit.lit else {
                        return Err("expected bool literal".into());
                    };
                    Literal::Boolean(b.value)
                }
                (Expr::Path(p), "Option < u64 >")
                    if p.qself.is_none() && p.path.is_ident("None") =>
                {
                    attrs(&p.attrs)?;
                    Literal::Absent
                }
                _ => {
                    return Err(format!(
                        "unsupported typed assignment {} = {}",
                        tokens(ty),
                        tokens(&assign.right)
                    ))
                }
            };
            writes.push(Write {
                path: p,
                rust_type: tokens(ty),
                literal,
                line: assign.span().start().line,
            });
        }
        Ok(Method {
            name: name.into(),
            symbol: name.replace("::", "_"),
            source: def.file.clone(),
            first_line: f.span().start().line,
            last_line: f.span().end().line,
            rust: tokens(f),
            writes,
        })
    }
}
fn lean_path(path: &[String]) -> String {
    format!(
        "[{}]",
        path.iter()
            .map(|p| format!("\"{p}\""))
            .collect::<Vec<_>>()
            .join(", ")
    )
}
fn literal(lit: &Literal) -> String {
    match lit {
        Literal::Boolean(b) => format!(".boolean {b}"),
        Literal::Absent => ".absent".into(),
    }
}
pub fn generate(methods: &[Method], namespace: &str) -> String {
    let mut text=format!("-- Generated from complete Rust method bodies; no sliced statements.\nimport Provium.State\nnamespace {namespace}\nopen Provium.State\n");
    for method in methods {
        let name = &method.symbol;
        let writes = method
            .writes
            .iter()
            .map(|w| format!("⟨{}, {}⟩", lean_path(&w.path), literal(&w.literal)))
            .collect::<Vec<_>>()
            .join(", ");
        text.push_str(&format!(
            "def {name}_ir : List Write := [{writes}]\ndef {name} (state : Store α) : Store α :=\n"
        ));
        for w in &method.writes {
            text.push_str(&format!(
                "  let state := put state {} ({})\n",
                lean_path(&w.path),
                literal(&w.literal)
            ))
        }
        text.push_str(&format!("  state\ntheorem {name}_correspondence (state : Store α) : run {name}_ir state = {name} state := by rfl\n"));
    }
    text.push_str(&format!("end {namespace}\n"));
    text
}
fn identifier(s: &str) -> bool {
    !s.is_empty()
        && s.bytes()
            .enumerate()
            .all(|(i, c)| c.is_ascii_alphabetic() || c == b'_' || (i > 0 && c.is_ascii_digit()))
}
pub fn verify(config: &Path, out: &Path) -> Result<String, String> {
    crate::project::prepare_output(out)?;
    let config_bytes = fs::read(config).map_err(|e| e.to_string())?;
    let project: Project = serde_json::from_slice(&config_bytes).map_err(|e| e.to_string())?;
    if !identifier(&project.namespace)
        || project.methods.is_empty()
        || project.obligations.is_empty()
    {
        return Err("valid namespace, selected methods, and obligations required".into());
    }
    let base = config.parent().unwrap_or(Path::new("."));
    let krate = Crate::load(&base.join(&project.crate_root))?;
    let methods = project
        .methods
        .iter()
        .map(|m| krate.lower(m))
        .collect::<Result<Vec<_>, _>>()?;
    let mut symbols = std::collections::BTreeSet::new();
    for m in &methods {
        for name in [
            m.symbol.clone(),
            format!("{}_ir", m.symbol),
            format!("{}_correspondence", m.symbol),
        ] {
            if !identifier(&name) || !symbols.insert(name) {
                return Err("invalid/colliding generated method symbol".into());
            }
        }
    }
    for o in &project.obligations {
        if !o.theorem.split('.').all(identifier) || !methods.iter().any(|m| m.symbol == o.function)
        {
            return Err("obligation names invalid theorem or unknown method".into());
        }
    }
    let proofs_path = base
        .join(&project.proofs)
        .canonicalize()
        .map_err(|e| e.to_string())?;
    let proofs = fs::read_to_string(&proofs_path).map_err(|e| e.to_string())?;
    fs::create_dir_all(out).map_err(|e| e.to_string())?;
    let out = out.canonicalize().map_err(|e| e.to_string())?;
    if krate
        .files
        .keys()
        .chain([
            &proofs_path,
            &config.canonicalize().map_err(|e| e.to_string())?,
        ])
        .any(|p| p.starts_with(&out))
    {
        return Err("inputs must be outside output directory".into());
    }
    // Type-check the actual crate, not a hand-written stand-in for its methods.
    let checked = Command::new("rustc")
        .args([
            "--crate-name",
            "provium_subject",
            "--crate-type",
            "lib",
            "--emit=metadata",
            "--edition=2021",
            "-C",
            "overflow-checks=yes",
        ])
        .arg(base.join(&project.crate_root))
        .arg("-o")
        .arg(out.join("subject.rmeta"))
        .output()
        .map_err(|e| e.to_string())?;
    if !checked.status.success() {
        return Err(format!(
            "rustc rejected original crate: {}",
            String::from_utf8_lossy(&checked.stderr)
        ));
    }
    fs::create_dir_all(out.join("Provium")).map_err(|e| e.to_string())?;
    fs::create_dir_all(out.join("Inputs")).map_err(|e| e.to_string())?;
    let mut inputs = vec![];
    for (i, (path, text)) in krate.files.iter().enumerate() {
        let snapshot = format!("Inputs/{i}.rs");
        fs::write(out.join(&snapshot), text).map_err(|e| e.to_string())?;
        inputs.push(Input {
            path: path.clone(),
            sha256: hash(text),
            snapshot,
        });
    }
    let generated = generate(&methods, &project.namespace);
    let mut audit = "import Provium.Audit\nimport Proofs\n".to_string();
    for m in &methods {
        audit.push_str(&format!(
            "#provium_check {}.{}_correspondence references {}.{}\n",
            project.namespace, m.symbol, project.namespace, m.symbol
        ))
    }
    for o in &project.obligations {
        audit.push_str(&format!(
            "#provium_check {} references {}.{}\n",
            o.theorem, project.namespace, o.function
        ))
    }
    let toolchain_file = format!("{TOOLCHAIN}\n");
    let artifacts = [
        ("lean-toolchain", toolchain_file.as_str()),
        ("Provium/State.lean", SEMANTICS),
        ("Provium/Audit.lean", AUDIT),
        ("Generated.lean", &generated),
        ("Proofs.lean", &proofs),
        ("Check.lean", &audit),
    ];
    for (file, text) in artifacts {
        fs::write(out.join(file), text).map_err(|e| e.to_string())?
    }
    let mut report = String::new();
    for (file, object) in [
        ("Provium/State.lean", Some("Provium/State.olean")),
        ("Provium/Audit.lean", Some("Provium/Audit.olean")),
        ("Generated.lean", Some("Generated.olean")),
        ("Proofs.lean", Some("Proofs.olean")),
        ("Check.lean", None),
    ] {
        report.push_str(&crate::project::lean_file(&out, file, object)?)
    }
    if report.matches("PROVIUM_VERIFIED ").count() != methods.len() + project.obligations.len() {
        return Err("incomplete method axiom audit".into());
    }
    for (file, text) in artifacts {
        if fs::read_to_string(out.join(file)).map_err(|e| e.to_string())? != text {
            return Err("artifact changed during method verification".into());
        }
    }
    if fs::read(config).map_err(|e| e.to_string())? != config_bytes
        || fs::read_to_string(&proofs_path).map_err(|e| e.to_string())? != proofs
    {
        return Err("proof/config changed during verification".into());
    }
    for (path, text) in &krate.files {
        if fs::read_to_string(path).map_err(|e| e.to_string())? != *text {
            return Err("Rust source changed during verification".into());
        }
    }
    for input in &inputs {
        if hash(fs::read(out.join(&input.snapshot)).map_err(|e| e.to_string())?) != input.sha256 {
            return Err("Rust snapshot changed during verification".into());
        }
    }
    let rustc = Command::new("rustc")
        .arg("--version")
        .output()
        .map_err(|e| e.to_string())?;
    if !rustc.status.success() {
        return Err("rustc unavailable".into());
    }
    let manifest = serde_json::json!({"format":1,"compiler_sha256":hash(fs::read(std::env::current_exe().map_err(|e|e.to_string())?).map_err(|e|e.to_string())?),"scope":"complete explicit method bodies in field-store semantics; frontend, field resolution, borrowing/layout refinement and host durability remain trusted; not whole-Raft correctness", "lean_toolchain":TOOLCHAIN,"rustc":String::from_utf8_lossy(&rustc.stdout).trim(),"config_sha256":hash(config_bytes),"sources":inputs,"methods":methods,"unproved_methods":krate.inventory().into_iter().filter(|n|!project.methods.contains(n)).collect::<Vec<_>>(),"artifacts":artifacts.iter().map(|(p,t)|(p,hash(t))).collect::<BTreeMap<_,_>>(),"obligations":project.obligations,"audit":report});
    let bytes = serde_json::to_vec_pretty(&manifest).map_err(|e| e.to_string())?;
    fs::write(out.join("manifest.json"), &bytes).map_err(|e| e.to_string())?;
    fs::write(out.join("verified.json"),serde_json::to_vec_pretty(&serde_json::json!({"manifest_sha256":hash(bytes),"whole_raft_proved":false,"complete_method_bodies":methods.len(),"obligations":project.obligations.len()})).map_err(|e|e.to_string())?).map_err(|e|e.to_string())?;
    Ok(format!("Verified {} complete method bodies and {} obligations in field-store semantics. Whole-Raft proof remains incomplete.\n{report}",methods.len(),project.obligations.len()))
}
