//! Whole-body translation of typed field assignments and boolean control flow.
//! No statement is sliced away or accepted as an opaque call.
mod build;
mod configured;

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
const LOANS: &str = include_str!("../lean/Provium/Loans.lean");
const SEMANTICS: &str = include_str!("../lean/Provium/State.lean");
const SCALAR_SEMANTICS: &str = include_str!("../lean/Provium/Semantics.lean");
const RANK_ARITHMETIC: &str = include_str!("../lean/Provium/RankArithmetic.lean");
const NUMERIC_FOLDS: &str = include_str!("../lean/Provium/NumericFolds.lean");
const ORDER_STATISTICS: &str = include_str!("../lean/Provium/OrderStatistics.lean");
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Project {
    pub crate_root: PathBuf,
    #[serde(default)]
    pub rust_target: Option<String>,
    #[serde(default)]
    pub cargo_build: Option<PathBuf>,
    pub namespace: String,
    pub methods: Vec<String>,
    pub proofs: PathBuf,
    #[serde(default)]
    pub proof_modules: Vec<ProofModule>,
    pub obligations: Vec<Obligation>,
}
/// Source libraries compiled in dependency order before the root proof module.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProofModule {
    pub name: String,
    pub path: PathBuf,
}
mod initialized;
mod proof_modules;
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
#[derive(Clone, Debug, Serialize)]
pub enum Condition {
    Boolean(bool),
    Field(Vec<String>),
    Not(Box<Condition>),
    And(Box<Condition>, Box<Condition>),
    Or(Box<Condition>, Box<Condition>),
}
#[derive(Clone, Debug, Serialize)]
pub enum Statement {
    Write(Write),
    Call {
        method: String,
        body: Vec<Statement>,
    },
    Branch {
        condition: Condition,
        yes: Vec<Statement>,
        no: Vec<Statement>,
    },
}
#[derive(Debug, Serialize)]
pub struct Method {
    pub name: String,
    pub symbol: String,
    pub source: PathBuf,
    pub first_line: usize,
    pub last_line: usize,
    pub rust: String,
    /// All possible writes; execution order and guards live in `body`.
    pub writes: Vec<Write>,
    pub body: Vec<Statement>,
    pub array: Option<arrays::Shape>,
    pub query: Option<queries::Query>,
    pub constructor: Option<constructors::Constructor>,
    pub buffer: Option<buffers::Append>,
    pub relocation: Option<relocations::Relocation>,
    pub selection: Option<selectors::Selection>,
    pub lookup: Option<lookups::Lookup>,
    pub record_at: Option<records::At>,
    pub iteration: Option<iterations::Iteration>,
    pub last: Option<iterations::Last>,
    pub truncation: Option<truncations::Truncation>,
    pub installation: Option<installations::Installation>,
    pub restoration: Option<restorations::Restoration>,
    pub validator: Option<validators::Validator>,
    pub view: Option<views::SharedView>,
    pub enum_projection: Option<enum_projections::Projection>,
}
struct Definition {
    module: String,
    file: PathBuf,
    item: syn::ImplItemFn,
    receiver: String,
    impl_generics: syn::Generics,
    self_type: Option<Type>,
}
pub struct Crate {
    cfg: Option<crate::cfg::Configuration>,
    files: BTreeMap<PathBuf, String>,
    structs: BTreeMap<String, syn::ItemStruct>,
    enums: BTreeMap<String, syn::ItemEnum>,
    struct_modules: BTreeMap<String, String>,
    imports: BTreeMap<(String, String), Vec<String>>,
    methods: BTreeMap<String, Definition>,
    drops: Vec<String>,
    array_iterator_shadow: bool,
    trait_methods: std::collections::BTreeSet<String>,
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
        Self::load_inner(root, None)
    }
    /// Select declarations using an explicit compilation configuration. This
    /// does not resolve expression cfg, macros or the complete call/type graph.
    pub fn load_configured(root: &Path, cfg: crate::cfg::Configuration) -> Result<Self, String> {
        Self::load_inner(root, Some(cfg))
    }
    fn load_inner(root: &Path, cfg: Option<crate::cfg::Configuration>) -> Result<Self, String> {
        let mut krate = Self {
            cfg,
            files: BTreeMap::new(),
            structs: BTreeMap::new(),
            enums: BTreeMap::new(),
            struct_modules: BTreeMap::new(),
            imports: BTreeMap::new(),
            methods: BTreeMap::new(),
            drops: vec![],
            array_iterator_shadow: false,
            trait_methods: std::collections::BTreeSet::new(),
        };
        krate.file(root, "", true)?;
        Ok(krate)
    }
    fn file(&mut self, path: &Path, module: &str, root: bool) -> Result<(), String> {
        let path = path.canonicalize().map_err(|e| e.to_string())?;
        let text = fs::read_to_string(&path).map_err(|e| e.to_string())?;
        let mut file = syn::parse_file(&text).map_err(|e| e.to_string())?;
        if let Some(cfg) = &self.cfg {
            let Some(attributes) = cfg.attributes(&file.attrs)? else {
                if self.files.insert(path, text).is_some() {
                    return Err("duplicate/cyclic module file".into());
                }
                return Ok(());
            };
            file.attrs = attributes
                .iter()
                .map(|meta| syn::parse_quote!(#[#meta]))
                .collect();
        }
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
            let item = if let Some(cfg) = &self.cfg {
                let Some(item) =
                    configured::item(cfg, item).map_err(|e| format!("{}: {e}", path.display()))?
                else {
                    continue;
                };
                item
            } else {
                item
            };
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
                                if [
                                    "None", "Option", "bool", "u8", "u16", "u32", "u64", "i32",
                                    "usize", "Result", "Ok", "Err", "Some",
                                ]
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
                Item::Enum(e)
                    if [
                        "Option", "bool", "u8", "u16", "u32", "u64", "i32", "usize", "Result",
                        "Ok", "Err", "Some",
                    ]
                    .iter()
                    .any(|n| e.ident == *n) =>
                {
                    return Err("shadowed primitive/prelude type".into())
                }
                Item::Enum(e) if !test_only(&e.attrs) => {
                    if self.structs.contains_key(&e.ident.to_string()) {
                        return Err("ambiguous enum/struct type name".into());
                    }
                    self.struct_modules
                        .insert(e.ident.to_string(), module.to_owned());
                    if self.enums.insert(e.ident.to_string(), e).is_some() {
                        return Err("ambiguous enum type".into());
                    }
                }
                Item::Fn(f) if ["Ok", "Err", "Some"].iter().any(|n| f.sig.ident == *n) => {
                    return Err("shadowed Result constructor".into());
                }
                Item::Const(c) if ["None", "Ok", "Err", "Some"].iter().any(|n| c.ident == *n) => {
                    return Err("shadowed None constructor".into())
                }
                Item::Static(c) if ["None", "Ok", "Err", "Some"].iter().any(|n| c.ident == *n) => {
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
                    if self.enums.contains_key(&s.ident.to_string()) {
                        return Err("ambiguous enum/struct type name".into());
                    }
                    if [
                        "Option", "bool", "u8", "u16", "u32", "u64", "i32", "usize", "Result",
                        "Ok", "Err", "Some",
                    ]
                    .iter()
                    .any(|n| s.ident == *n)
                    {
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
                Item::Trait(t) if !test_only(&t.attrs) => {
                    for item in &t.items {
                        if let syn::TraitItem::Fn(method) = item {
                            self.trait_methods.insert(method.sig.ident.to_string());
                        }
                    }
                    if t.items.iter().any(|i| matches!(i,syn::TraitItem::Fn(f) if ["iter","flatten","any"].iter().any(|n|f.sig.ident==*n))) {
                        self.array_iterator_shadow = true;
                    }
                }
                Item::Impl(i) if !test_only(&i.attrs) => {
                    if i.generics.type_params().any(|p| {
                        [
                            "Option", "Result", "bool", "u8", "u16", "u32", "u64", "i32", "usize",
                            "Ok", "Err", "Some",
                        ]
                        .iter()
                        .any(|n| p.ident == *n)
                    }) {
                        return Err(
                            "impl generic parameter shadows a primitive/prelude type".into()
                        );
                    }
                    let receiver = base_type(&i.self_ty)?;
                    attrs(&i.attrs)?;
                    if let Some((_, trait_path, _)) = &i.trait_ {
                        for item in &i.items {
                            if let syn::ImplItem::Fn(method) = item {
                                self.trait_methods.insert(method.sig.ident.to_string());
                            }
                        }
                        if i.items.iter().any(|i| matches!(i,syn::ImplItem::Fn(f) if ["iter","flatten","any"].iter().any(|n|f.sig.ident==*n))) {
                            self.array_iterator_shadow = true;
                        }
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
                                        impl_generics: i.generics.clone(),
                                        self_type: Some(*i.self_ty.clone()),
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
        if let Some(def) = self.methods.get(name) {
            if self.enums.contains_key(&def.receiver) {
                return self.lower_enum_projection(name);
            }
            if upserts::candidate(&def.item) {
                return self.lower_upsert(name);
            }
            if validators::candidate(&def.item) {
                return self.lower_validator(name);
            }
            if views::candidate(&def.item) {
                return self.lower_shared_view(name);
            }
            if numeric_folds::candidate(&def.item) {
                return self.lower_numeric_fold(name);
            }
            if predicate_folds::candidate(&def.item) {
                return self.lower_predicate_fold(name);
            }
            if merges::candidate(&def.item) {
                return self.lower_merge(name);
            }
            if rebuilds::candidate(&def.item) {
                return self.lower_rebuild(name);
            }
            if slot_batches::candidate(&def.item) {
                return self.lower_slot_batch(name);
            }
            if matches!(&def.item.sig.output, syn::ReturnType::Type(_, ty) if matches!(&**ty, Type::Array(_)))
            {
                return self.lower_projection(name);
            }
            if restorations::candidate(&def.item) {
                return self.lower_restoration(name);
            }
            if def.item.sig.generics.const_params().next().is_some()
                && matches!(def.item.sig.inputs.first(), Some(syn::FnArg::Receiver(r)) if r.reference.is_none())
            {
                return self.lower_relocation(name);
            }
            if def.item.sig.inputs.is_empty()
                && matches!(&def.item.sig.output,syn::ReturnType::Type(_,ty) if matches!(&**ty,Type::Path(p) if p.path.is_ident("Self")))
            {
                return self.lower_constructor(name);
            }
            if matches!(&def.item.sig.output,syn::ReturnType::Type(_,ty) if matches!(&**ty,Type::Path(p) if p.path.segments.first().is_some_and(|s|s.ident=="Option")))
            {
                if records::output_record(&def.item.sig.output).is_ok() {
                    return self.lower_record_at(name);
                }
                return self.lower_lookup(name);
            }
            if matches!(&def.item.sig.output,syn::ReturnType::Type(_,ty) if matches!(&**ty,Type::ImplTrait(_)))
            {
                if projections::candidate(&def.item.sig.output) {
                    return self.lower_projection(name);
                }
                return self.lower_iteration(name);
            }
            if matches!(
                def.item.block.stmts.first(),
                Some(syn::Stmt::Expr(Expr::While(_), _))
            ) {
                return self.lower_truncation(name);
            }
            if installations::candidate(&def.item) {
                return self.lower_installation(name);
            }
            if iterations::last_expression(&def.item.block) {
                return self.lower_last(name);
            }
            if queries::result_error(&def.item.sig.output).is_ok() {
                if matches!(def.item.sig.inputs.first(), Some(syn::FnArg::Receiver(r)) if r.mutability.is_some())
                {
                    return self.lower_buffer(name);
                }
                return self.lower_query(name, &[]);
            }
            if matches!(&def.item.sig.output, syn::ReturnType::Type(_,ty) if matches!(&**ty, Type::Path(p) if p.path.is_ident("bool")))
            {
                return self.lower_array_query(name);
            }
            if matches!(&def.item.sig.output, syn::ReturnType::Type(_,ty) if matches!(&**ty, Type::Path(p) if p.path.is_ident("Self")))
            {
                return self.lower_array(name);
            }
            if matches!(&def.item.sig.output, syn::ReturnType::Type(_,ty) if matches!(&**ty, Type::Path(p) if p.qself.is_none() && p.path.segments.len()==1 && matches!(p.path.segments[0].arguments,syn::PathArguments::None)))
            {
                return self.lower_selection(name);
            }
        }
        self.lower_inner(name, &[], &std::cell::Cell::new(0))
    }
    fn lower_inner(
        &self,
        name: &str,
        stack: &[String],
        budget: &std::cell::Cell<usize>,
    ) -> Result<Method, String> {
        if stack.len() >= 32 || stack.iter().any(|n| n == name) {
            return Err("recursive/deep method calls require termination semantics".into());
        }
        let mut stack = stack.to_vec();
        stack.push(name.to_owned());
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
        if structure.generics.type_params().any(|p| {
            ["Option", "bool", "u8", "u16", "u32", "u64", "i32", "usize"]
                .iter()
                .any(|n| p.ident == *n)
        }) {
            return Err("generic parameter shadows a primitive/prelude type".into());
        }
        let mut writes = vec![];
        let body = self.statements(def, &f.block.stmts, &mut writes, &stack, budget)?;
        Ok(Method {
            name: name.into(),
            symbol: name.replace("::", "_"),
            source: def.file.clone(),
            first_line: f.span().start().line,
            last_line: f.span().end().line,
            rust: tokens(f),
            writes,
            body,
            array: None,
            query: None,
            constructor: None,
            buffer: None,
            relocation: None,
            selection: None,
            lookup: None,
            record_at: None,
            iteration: None,
            last: None,
            truncation: None,
            installation: None,
            restoration: None,
            enum_projection: None,
            validator: None,
            view: None,
        })
    }
    fn field_type<'a>(&'a self, def: &Definition, p: &[String]) -> Result<&'a Type, String> {
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
            if structure.generics.type_params().any(|p| {
                ["Option", "bool", "u8", "u16", "u32", "u64", "i32", "usize"]
                    .iter()
                    .any(|n| p.ident == *n)
            }) {
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
        Ok(field_type.unwrap())
    }
    fn condition(&self, def: &Definition, expr: &Expr) -> Result<Condition, String> {
        Ok(match expr {
            Expr::Lit(l) => {
                attrs(&l.attrs)?;
                let syn::Lit::Bool(b) = &l.lit else {
                    return Err("expected boolean condition".into());
                };
                Condition::Boolean(b.value)
            }
            Expr::Field(_) => {
                let p = path(expr)?;
                if tokens(self.field_type(def, &p)?) != "bool" {
                    return Err("condition field must have builtin bool type".into());
                }
                Condition::Field(p)
            }
            Expr::Paren(p) => {
                attrs(&p.attrs)?;
                return self.condition(def, &p.expr);
            }
            Expr::Unary(u) if matches!(u.op, syn::UnOp::Not(_)) => {
                attrs(&u.attrs)?;
                Condition::Not(Box::new(self.condition(def, &u.expr)?))
            }
            Expr::Binary(b) => {
                attrs(&b.attrs)?;
                let left = Box::new(self.condition(def, &b.left)?);
                let right = Box::new(self.condition(def, &b.right)?);
                match b.op {
                    syn::BinOp::And(_) => Condition::And(left, right),
                    syn::BinOp::Or(_) => Condition::Or(left, right),
                    _ => return Err("unsupported condition operator".into()),
                }
            }
            _ => {
                return Err(format!(
                    "unsupported complete-method condition {}",
                    tokens(expr)
                ))
            }
        })
    }
    fn statements(
        &self,
        def: &Definition,
        stmts: &[syn::Stmt],
        writes: &mut Vec<Write>,
        stack: &[String],
        budget: &std::cell::Cell<usize>,
    ) -> Result<Vec<Statement>, String> {
        let mut body = vec![];
        for stmt in stmts {
            budget.set(budget.get() + 1);
            if budget.get() > 100_000 {
                return Err("method effect expansion exceeds budget".into());
            }
            if let syn::Stmt::Expr(Expr::MethodCall(call), Some(_)) = stmt {
                attrs(&call.attrs)?;
                if !path(&call.receiver)?.is_empty()
                    || !call.args.is_empty()
                    || call.turbofish.is_some()
                {
                    return Err("only receiver-local calls without arguments are supported".into());
                }
                let name = format!("{}::{}::{}", def.module, def.receiver, call.method)
                    .trim_start_matches("::")
                    .to_owned();
                let callee = self.methods.get(&name).ok_or_else(|| {
                    format!("unsupported complete-method statement: unresolved call {name}")
                })?;
                let Some(syn::FnArg::Receiver(receiver)) = callee.item.sig.inputs.first() else {
                    return Err("call target is not an inherent receiver method".into());
                };
                if receiver.reference.is_none() || receiver.mutability.is_none() {
                    return Err("inlined call requires a mutable borrowed receiver".into());
                }
                let lowered = self.lower_inner(&name, stack, budget)?;
                writes.extend(lowered.writes);
                body.push(Statement::Call {
                    method: name,
                    body: lowered.body,
                });
                if writes.len() > 100_000 {
                    return Err("method effect expansion exceeds budget".into());
                }
                continue;
            }
            if let syn::Stmt::Expr(Expr::If(branch), _) = stmt {
                attrs(&branch.attrs)?;
                let condition = self.condition(def, &branch.cond)?;
                let yes = self.statements(def, &branch.then_branch.stmts, writes, stack, budget)?;
                let no = match &branch.else_branch {
                    None => vec![],
                    Some((_, expr)) => match &**expr {
                        Expr::Block(b) if b.label.is_none() => {
                            attrs(&b.attrs)?;
                            self.statements(def, &b.block.stmts, writes, stack, budget)?
                        }
                        Expr::If(_) => self.statements(
                            def,
                            &[syn::Stmt::Expr(*expr.clone(), None)],
                            writes,
                            stack,
                            budget,
                        )?,
                        _ => return Err("unsupported else expression".into()),
                    },
                };
                body.push(Statement::Branch { condition, yes, no });
                continue;
            }
            let syn::Stmt::Expr(Expr::Assign(assign), Some(_)) = stmt else {
                return Err(format!(
                    "unsupported complete-method statement at line {}: {}",
                    stmt.span().start().line,
                    tokens(stmt)
                ));
            };
            attrs(&assign.attrs)?;
            let p = path(&assign.left)?;
            let ty = self.field_type(def, &p)?;
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
            let write = Write {
                path: p,
                rust_type: tokens(ty),
                literal,
                line: assign.span().start().line,
            };
            writes.push(write.clone());
            body.push(Statement::Write(write));
        }
        Ok(body)
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
fn condition(c: &Condition) -> String {
    match c {
        Condition::Boolean(b) => format!(".boolean {b}"),
        Condition::Field(p) => format!(".field {}", lean_path(p)),
        Condition::Not(c) => format!(".not ({})", condition(c)),
        Condition::And(a, b) => format!(".and ({}) ({})", condition(a), condition(b)),
        Condition::Or(a, b) => format!(".or ({}) ({})", condition(a), condition(b)),
    }
}
fn program(body: &[Statement]) -> String {
    match body.split_first() {
        None => ".done".into(),
        Some((stmt, rest)) => {
            let first = match stmt {
                Statement::Call { body, .. } => program(body),
                Statement::Write(w) => {
                    format!(".write ⟨{}, {}⟩", lean_path(&w.path), literal(&w.literal))
                }
                Statement::Branch {
                    condition: c,
                    yes,
                    no,
                } => format!(
                    ".branch ({}) ({}) ({})",
                    condition(c),
                    program(yes),
                    program(no)
                ),
            };
            format!(".seq ({first}) ({})", program(rest))
        }
    }
}
fn executable(body: &[Statement], indent: usize) -> String {
    let pad = " ".repeat(indent);
    let mut text = String::new();
    for stmt in body {
        match stmt {
            Statement::Call { body, .. } => {
                text.push_str(&format!(
                    "{pad}let state :=\n{}",
                    executable(body, indent + 2)
                ));
            }
            Statement::Write(w) => text.push_str(&format!(
                "{pad}let state := put state {} ({})\n",
                lean_path(&w.path),
                literal(&w.literal)
            )),
            Statement::Branch {
                condition: c,
                yes,
                no,
            } => text.push_str(&format!(
                "{pad}let state := if evalCondition ({}) state then\n{}{pad}else\n{}",
                condition(c),
                executable(yes, indent + 2),
                executable(no, indent + 2)
            )),
        }
    }
    text.push_str(&format!("{pad}state\n"));
    text
}
pub fn generate(methods: &[Method], namespace: &str) -> String {
    let mut text=format!("-- Generated from complete Rust method bodies; no sliced statements.\nimport Provium.State\nimport Provium.Loans\nimport Provium.NumericFolds\nnamespace {namespace}\nopen Provium.State\n");
    for method in methods {
        let name = &method.symbol;
        if method.validator.is_some() {
            text.push_str(&validators::generate(method));
            continue;
        }
        if method.enum_projection.is_some() {
            text.push_str(&enum_projections::generate(method));
            continue;
        }
        if method.restoration.is_some() {
            text.push_str(&restorations::generate(method));
            continue;
        }
        if method.installation.is_some() {
            text.push_str(&installations::generate(method));
            continue;
        }
        if method.truncation.is_some() {
            text.push_str(&truncations::generate(method));
            continue;
        }
        if method.iteration.is_some() || method.last.is_some() {
            text.push_str(&iterations::generate(method));
            continue;
        }
        if method.record_at.is_some() {
            text.push_str(&records::generate(method));
            continue;
        }
        if method.lookup.is_some() {
            text.push_str(&lookups::generate(method));
            continue;
        }
        if method.selection.is_some() {
            text.push_str(&selectors::generate(method));
            continue;
        }
        if method.relocation.is_some() {
            text.push_str(&relocations::generate(method));
            continue;
        }
        if method.buffer.is_some() {
            text.push_str(&buffers::generate(method));
            continue;
        }
        if method.constructor.is_some() {
            text.push_str(&constructors::generate(method));
            continue;
        }
        if method.view.is_some() {
            text.push_str(&views::generate(method));
            continue;
        }
        if method.query.is_some() {
            text.push_str(&queries::generate(method));
            continue;
        }
        if method.array.is_some() {
            text.push_str(&arrays::generate(method));
            continue;
        }
        text.push_str(&format!(
            "def {name}_ir : Program := {}\ndef {name} (state : Store α) : Store α :=\n{}",
            program(&method.body),
            executable(&method.body, 2)
        ));
        text.push_str(&format!("theorem {name}_correspondence (state : Store α) : execute {name}_ir state = {name} state := by rfl\n"));
        text.push_str(&initialized::generate(method));
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
    let cargo_build = build::Build::capture(&project, config, out)?;
    let cfg_text = if let Some(build) = &cargo_build {
        build.cfg()?.to_owned()
    } else {
        let mut cfg_command = Command::new("rustc");
        cfg_command.args([
            "--print",
            "cfg",
            "--edition=2021",
            "-C",
            "overflow-checks=yes",
        ]);
        if let Some(target) = &project.rust_target {
            cfg_command.args(["--target", target]);
        }
        let cfg = cfg_command.output().map_err(|e| e.to_string())?;
        if !cfg.status.success() {
            return Err(format!(
                "rustc target configuration unavailable: {}",
                String::from_utf8_lossy(&cfg.stderr)
            ));
        }
        String::from_utf8(cfg.stdout).map_err(|e| e.to_string())?
    };
    let configuration = crate::cfg::Configuration::parse(&cfg_text)?;
    let krate = Crate::load_configured(&base.join(&project.crate_root), configuration)?;
    if let Some(build) = &cargo_build {
        build.bind_sources(&krate)?;
    }
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
            format!("{}_slot", m.symbol),
            format!("{}_correspondence", m.symbol),
            format!("{}_offset", m.symbol),
            format!("{}_layout", m.symbol),
            format!("{}_well_typed", m.symbol),
            format!("{}_initialized_refinement", m.symbol),
            format!("{}_loan_refinement", m.symbol),
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
    let libraries = proof_modules::load(base, &project.proof_modules)?;
    fs::create_dir_all(out).map_err(|e| e.to_string())?;
    let out = out.canonicalize().map_err(|e| e.to_string())?;
    if krate
        .files
        .keys()
        .chain(libraries.iter().map(|library| &library.path))
        .chain([
            &proofs_path,
            &config.canonicalize().map_err(|e| e.to_string())?,
        ])
        .any(|p| p.starts_with(&out))
    {
        return Err("inputs must be outside output directory".into());
    }
    let typecheck_args = if let Some(build) = &cargo_build {
        build.capture.invocations[build.capture.configured_root_invocation]
            .arguments
            .clone()
    } else {
        // Type-check the actual crate, not a hand-written stand-in for its methods.
        let mut rust_check = Command::new("rustc");
        rust_check
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
            .arg(out.join("subject.rmeta"));
        if let Some(target) = &project.rust_target {
            rust_check.args(["--target", target]);
        }
        let typecheck_args = rust_check
            .get_args()
            .map(|a| a.to_string_lossy().into_owned())
            .collect::<Vec<_>>();
        let checked = rust_check.output().map_err(|e| e.to_string())?;
        if !checked.status.success() {
            return Err(format!(
                "rustc rejected original crate: {}",
                String::from_utf8_lossy(&checked.stderr)
            ));
        }
        typecheck_args
    };
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
        ));
        if initialized::supported(m) {
            audit.push_str(&format!(
                "#provium_check {}.{}_initialized_refinement references {}.{}\n",
                project.namespace, m.symbol, project.namespace, m.symbol
            ));
            audit.push_str(&format!(
                "#provium_check {}.{}_loan_refinement references {}.{}\n",
                project.namespace, m.symbol, project.namespace, m.symbol
            ));
        }
    }
    for o in &project.obligations {
        audit.push_str(&format!(
            "#provium_check {} references {}.{}\n",
            o.theorem, project.namespace, o.function
        ))
    }
    let toolchain_file = format!("{TOOLCHAIN}\n");
    let mut artifacts = vec![
        ("lean-toolchain", toolchain_file.as_str()),
        ("Provium/State.lean", SEMANTICS),
        ("Provium/Loans.lean", LOANS),
        ("Provium/OrderStatistics.lean", ORDER_STATISTICS),
        ("Provium/Semantics.lean", SCALAR_SEMANTICS),
        ("Provium/RankArithmetic.lean", RANK_ARITHMETIC),
        ("Provium/NumericFolds.lean", NUMERIC_FOLDS),
        ("Provium/Audit.lean", AUDIT),
        ("Generated.lean", &generated),
        ("Proofs.lean", &proofs),
        ("Check.lean", &audit),
    ];
    artifacts.extend(
        libraries
            .iter()
            .map(|library| (library.artifact.as_str(), library.source.as_str())),
    );
    let workspace = proof_modules::Workspace::new(&out)?;
    for (file, text) in &artifacts {
        let path = out.join(file);
        fs::create_dir_all(path.parent().unwrap()).map_err(|e| e.to_string())?;
        fs::write(path, text).map_err(|e| e.to_string())?;
        workspace.write(file, text)?;
    }
    let mut report = String::new();
    for (file, object) in [
        ("Provium/State.lean", Some("Provium/State.olean")),
        ("Provium/Loans.lean", Some("Provium/Loans.olean")),
        (
            "Provium/OrderStatistics.lean",
            Some("Provium/OrderStatistics.olean"),
        ),
        ("Provium/Semantics.lean", Some("Provium/Semantics.olean")),
        (
            "Provium/RankArithmetic.lean",
            Some("Provium/RankArithmetic.olean"),
        ),
        (
            "Provium/NumericFolds.lean",
            Some("Provium/NumericFolds.olean"),
        ),
        ("Provium/Audit.lean", Some("Provium/Audit.olean")),
        ("Generated.lean", Some("Generated.olean")),
    ] {
        report.push_str(&workspace.check(file, object)?);
    }
    for library in &libraries {
        report.push_str(&workspace.check(
            &library.artifact,
            Some(&library.artifact.replace(".lean", ".olean")),
        )?);
    }
    report.push_str(&workspace.check("Proofs.lean", Some("Proofs.olean"))?);
    report.push_str(&workspace.check("Check.lean", None)?);
    let initialized_refinements = methods.iter().filter(|m| initialized::supported(m)).count();
    if report.matches("PROVIUM_VERIFIED ").count()
        != methods.len() + 2 * initialized_refinements + project.obligations.len()
    {
        return Err("incomplete method axiom audit".into());
    }
    for (file, text) in &artifacts {
        workspace.source_unchanged(file, text)?;
        if fs::read_to_string(out.join(file)).map_err(|e| e.to_string())? != *text {
            return Err("artifact changed during method verification".into());
        }
    }
    if fs::read(config).map_err(|e| e.to_string())? != config_bytes
        || fs::read_to_string(&proofs_path).map_err(|e| e.to_string())? != proofs
    {
        return Err("proof/config changed during verification".into());
    }
    for library in &libraries {
        if fs::read_to_string(&library.path).map_err(|e| e.to_string())? != library.source {
            return Err("proof module changed during verification".into());
        }
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
        .arg("-vV")
        .output()
        .map_err(|e| e.to_string())?;
    if !rustc.status.success() {
        return Err("rustc unavailable".into());
    }
    if let Some(build) = &cargo_build {
        build.revalidate()?;
    }
    for object in [
        "Provium/State.olean",
        "Provium/Loans.olean",
        "Provium/Audit.olean",
        "Generated.olean",
        "Proofs.olean",
    ] {
        workspace.publish(object, &out)?;
    }
    for library in &libraries {
        workspace.publish(&library.artifact.replace(".lean", ".olean"), &out)?;
    }
    let manifest = serde_json::json!({"format":1,"compiler_sha256":hash(fs::read(std::env::current_exe().map_err(|e|e.to_string())?).map_err(|e|e.to_string())?),"scope":"complete explicit method bodies in supported Lean semantics; frontend, field resolution, borrowing/layout refinement and host durability remain trusted; not whole-program correctness", "lean_toolchain":TOOLCHAIN,"rustc":String::from_utf8_lossy(&rustc.stdout).trim(),"rust_target":cargo_build.as_ref().map(|b| b.capture.subject.request.target.clone()).or(project.rust_target),"rust_target_cfg":cfg_text,"cargo_build":cargo_build.as_ref().map(build::Build::evidence),"typecheck_args":typecheck_args,"config_sha256":hash(config_bytes),"sources":inputs,"proof_modules":libraries.iter().map(|library| serde_json::json!({"name":library.module,"path":library.path,"artifact":library.artifact,"sha256":hash(&library.source)})).collect::<Vec<_>>(),"methods":methods,"unproved_methods":krate.inventory().into_iter().filter(|n|!project.methods.contains(n)).collect::<Vec<_>>(),"artifacts":artifacts.iter().map(|(p,t)|(p,hash(t))).collect::<BTreeMap<_,_>>(),"obligations":project.obligations,"audit":report});
    let bytes = serde_json::to_vec_pretty(&manifest).map_err(|e| e.to_string())?;
    fs::write(out.join("manifest.json"), &bytes).map_err(|e| e.to_string())?;
    fs::write(out.join("verified.json"),serde_json::to_vec_pretty(&serde_json::json!({"manifest_sha256":hash(bytes),"whole_program_proved":false,"complete_method_bodies":methods.len(),"initialized_slot_refinements":initialized_refinements,"loan_refinements":initialized_refinements,"obligations":project.obligations.len()})).map_err(|e|e.to_string())?).map_err(|e|e.to_string())?;
    Ok(format!("Verified {} complete method bodies and {} obligations in supported Lean semantics. Whole-program proof remains incomplete.\n{report}",methods.len(),project.obligations.len()))
}

pub mod scalar;

mod arrays;
pub mod constructors;
pub mod queries;

pub mod buffers;

pub mod relocations;

pub mod selectors;

pub mod lookups;

pub mod records;

pub mod iterations;

pub mod truncations;

pub mod installations;

pub mod restorations;

pub mod enum_projections;

pub mod validators;

pub mod views;

mod merges;
mod numeric_folds;
mod predicate_folds;
mod projections;
mod rebuilds;

mod key_queries;

mod upserts;

mod slot_batches;
