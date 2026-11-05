//! Crate loading and name resolution for the typed backend.
//!
//! Files are read by following `mod` declarations from the crate root, with
//! conditional compilation decided by the build's `rustc --print cfg` output.
//! Paths resolve through each module's own items and `use` declarations; any
//! name this resolver cannot place is rejected rather than guessed.
use crate::cfg::Configuration;
use quote::ToTokens;
use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
};
use syn::{Item, Type};

pub fn tokens(t: &impl ToTokens) -> String {
    t.to_token_stream().to_string()
}

#[derive(Clone, Debug)]
pub struct Struct {
    pub path: String,
    pub module: String,
    pub generics: syn::Generics,
    /// Field names in declaration order; tuple fields are named `_0`, `_1`, ...
    pub fields: Vec<(String, Type)>,
    pub tuple: bool,
    pub derives: Vec<String>,
}

#[derive(Clone, Debug)]
pub struct Variant {
    pub name: String,
    /// Named fields keep their names; tuple fields are named `_0`, `_1`, ...
    pub fields: Vec<(String, Type)>,
    pub named: bool,
}

#[derive(Clone, Debug)]
pub struct Enum {
    pub path: String,
    pub module: String,
    pub generics: syn::Generics,
    pub variants: Vec<Variant>,
    pub derives: Vec<String>,
}

#[derive(Clone, Debug)]
pub struct Function {
    /// `module::Type::name` for associated functions, `module::name` otherwise.
    pub path: String,
    pub module: String,
    pub name: String,
    /// The resolved path of the implementing type, for associated functions.
    pub owner: Option<String>,
    /// The impl block's self type and generics.
    pub self_ty: Option<Type>,
    pub impl_generics: syn::Generics,
    /// The implemented trait's last path segment, for trait impls.
    pub trait_name: Option<String>,
    pub sig: syn::Signature,
    pub block: syn::Block,
    pub file: PathBuf,
    /// The line of the enclosing `impl` keyword, which rustc's MIR names
    /// associated functions by.
    pub impl_line: Option<usize>,
}

#[derive(Clone, Debug)]
pub struct Const {
    pub path: String,
    pub module: String,
    pub ty: Type,
    pub expr: syn::Expr,
}

/// A type alias, expanded where it is named.
#[derive(Clone, Debug)]
pub struct Alias {
    pub module: String,
    pub generics: syn::Generics,
    pub ty: Type,
}

#[derive(Default)]
pub struct Krate {
    pub aliases: BTreeMap<String, Alias>,
    pub files: BTreeMap<PathBuf, String>,
    pub structs: BTreeMap<String, Struct>,
    pub enums: BTreeMap<String, Enum>,
    pub functions: BTreeMap<String, Function>,
    pub consts: BTreeMap<String, Const>,
    /// For each module, the names in scope and the crate paths they denote.
    pub scopes: BTreeMap<String, BTreeMap<String, String>>,
    /// Glob imports (`use path::*`) per module.
    globs: BTreeMap<String, Vec<String>>,
    imports: Vec<(String, String, String)>,
    pending_impls: Vec<(String, PathBuf, syn::ItemImpl)>,
    cfg: Option<Configuration>,
    /// The crate's own name, which mounted modules use like `crate`.
    crate_name: Option<String>,
}

fn join(module: &str, name: &str) -> String {
    if module.is_empty() {
        name.to_owned()
    } else {
        format!("{module}::{name}")
    }
}

fn derives(attrs: &[syn::Attribute]) -> Result<Vec<String>, String> {
    let mut out = vec![];
    for a in attrs {
        if a.path().is_ident("derive") {
            let list = a
                .parse_args_with(
                    syn::punctuated::Punctuated::<syn::Path, syn::Token![,]>::parse_terminated,
                )
                .map_err(|e| e.to_string())?;
            for p in list {
                out.push(tokens(&p).replace(' ', ""));
            }
        }
    }
    Ok(out)
}

fn fields(f: &syn::Fields) -> (Vec<(String, Type)>, bool) {
    match f {
        syn::Fields::Named(n) => (
            n.named
                .iter()
                .map(|f| (f.ident.as_ref().unwrap().to_string(), f.ty.clone()))
                .collect(),
            true,
        ),
        syn::Fields::Unnamed(u) => (
            u.unnamed
                .iter()
                .enumerate()
                .map(|(i, f)| (format!("_{i}"), f.ty.clone()))
                .collect(),
            false,
        ),
        syn::Fields::Unit => (vec![], true),
    }
}

impl Krate {
    pub fn load(root: &Path, cfg: Option<Configuration>) -> Result<Self, String> {
        Self::load_with(root, cfg, &[], None)
    }

    /// Load a crate plus extra module files mounted at top-level module names,
    /// which may name the crate as `crate_name` (as an external user would).
    pub fn load_with(
        root: &Path,
        cfg: Option<Configuration>,
        extras: &[(String, PathBuf)],
        crate_name: Option<&str>,
    ) -> Result<Self, String> {
        let mut k = Krate {
            cfg,
            crate_name: crate_name.map(str::to_owned),
            ..Default::default()
        };
        let root = root
            .canonicalize()
            .map_err(|e| format!("{}: {e}", root.display()))?;
        let text = fs::read_to_string(&root).map_err(|e| e.to_string())?;
        let file = syn::parse_file(&text).map_err(|e| format!("{}: {e}", root.display()))?;
        k.files.insert(root.clone(), text);
        let dir = root.parent().unwrap().to_owned();
        k.items(file.items, "", &dir, &root)?;
        for (module, path) in extras {
            let path = path
                .canonicalize()
                .map_err(|e| format!("{}: {e}", path.display()))?;
            let text = fs::read_to_string(&path).map_err(|e| e.to_string())?;
            let parsed = syn::parse_file(&text).map_err(|e| format!("{}: {e}", path.display()))?;
            if k.scopes.get("").is_some_and(|s| s.contains_key(module)) {
                return Err(format!(
                    "mounted module {module} collides with a crate item"
                ));
            }
            k.files.insert(path.clone(), text);
            k.declare("", module, module)?;
            let parent = path.parent().unwrap().to_owned();
            k.items(parsed.items, module, &parent, &path)?;
        }
        // Re-exports may be imported before they are declared: resolve to a fixed point.
        let mut pending = std::mem::take(&mut k.imports);
        loop {
            let before = pending.len();
            let mut rest = vec![];
            for (module, name, path) in pending {
                let segments: Vec<String> = path.split("::").map(str::to_owned).collect();
                match k.resolve_from(&module, &segments, false) {
                    Some(target) => k.declare(&module, &name, &target)?,
                    None => rest.push((module, name, path)),
                }
            }
            if rest.is_empty() {
                break;
            }
            if rest.len() == before {
                // Imports of items outside the crate (core, alloc) are left to
                // the library table, which names every standard path it supports.
                for (module, name, path) in rest {
                    k.scopes
                        .get_mut(&module)
                        .unwrap()
                        .insert(name, format!("::{path}"));
                }
                break;
            }
            pending = rest;
        }
        for (module, file, i) in std::mem::take(&mut k.pending_impls) {
            k.implementation(&module, &file, i)?;
        }
        Ok(k)
    }

    /// Resolve a path written in `module`. `crate`, `self` and `super` are
    /// honoured; the first plain segment is looked up in the module's scope and
    /// glob imports. Returns a crate path, or `::`-prefixed external path.
    pub fn resolve(&self, module: &str, segments: &[String]) -> Option<String> {
        self.resolve_from(module, segments, true)
    }

    fn resolve_from(&self, module: &str, segments: &[String], globs: bool) -> Option<String> {
        let (mut current, rest) = match segments.first()?.as_str() {
            "crate" => (String::new(), &segments[1..]),
            first if self.crate_name.as_deref() == Some(first) => (String::new(), &segments[1..]),
            "self" => (module.to_owned(), &segments[1..]),
            "super" => (
                module
                    .rsplit_once("::")
                    .map_or(String::new(), |(p, _)| p.to_owned()),
                &segments[1..],
            ),
            "core" | "alloc" | "std" => return Some(format!("::{}", segments.join("::"))),
            first => {
                let found = self.lookup(module, first, globs)?;
                if found.starts_with("::") {
                    let mut p = found;
                    for s in &segments[1..] {
                        p.push_str("::");
                        p.push_str(s);
                    }
                    return Some(p);
                }
                (found, &segments[1..])
            }
        };
        for (i, s) in rest.iter().enumerate() {
            if self.structs.contains_key(&current) || self.enums.contains_key(&current) {
                // An associated item or variant: keep the remaining path.
                let mut p = current;
                for s in &rest[i..] {
                    p.push_str("::");
                    p.push_str(s);
                }
                return Some(p);
            }
            current = self.lookup(&current, s, globs)?;
        }
        Some(current)
    }

    fn lookup(&self, module: &str, name: &str, globs: bool) -> Option<String> {
        if let Some(p) = self.scopes.get(module).and_then(|s| s.get(name)) {
            return Some(p.clone());
        }
        if globs {
            for g in self.globs.get(module).into_iter().flatten() {
                let segments: Vec<String> = g.split("::").map(str::to_owned).collect();
                if let Some(target) = self.resolve_from(module, &segments, false) {
                    if let Some(p) = self.scopes.get(&target).and_then(|s| s.get(name)) {
                        return Some(p.clone());
                    }
                }
            }
        }
        None
    }

    fn implementation(
        &mut self,
        module: &str,
        file: &Path,
        i: syn::ItemImpl,
    ) -> Result<(), String> {
        let Type::Path(tp) = &*i.self_ty else {
            return Err(format!("impl for unsupported type {}", tokens(&i.self_ty)));
        };
        let segments: Vec<String> = tp
            .path
            .segments
            .iter()
            .map(|s| s.ident.to_string())
            .collect();
        let owner = self
            .resolve(module, &segments)
            .filter(|p| self.structs.contains_key(p) || self.enums.contains_key(p))
            .ok_or_else(|| format!("impl for type outside the crate: {}", tokens(&i.self_ty)))?;
        let trait_name = i
            .trait_
            .as_ref()
            .map(|(_, p, _)| p.segments.last().unwrap().ident.to_string());
        let impl_line = i.impl_token.span.start().line;
        for item in i.items {
            match item {
                syn::ImplItem::Fn(f) => {
                    let name = f.sig.ident.to_string();
                    let mut path = format!("{owner}::{name}");
                    // A second inherent impl for a differently instantiated self
                    // type (`impl Envelope<&V, &S>`) gets its own name.
                    if self.functions.contains_key(&path) {
                        path = format!("{owner}::{name}#{}", self.functions.len());
                    }
                    self.functions.insert(
                        path.clone(),
                        Function {
                            path,
                            module: module.to_owned(),
                            name,
                            owner: Some(owner.clone()),
                            self_ty: Some((*i.self_ty).clone()),
                            impl_generics: i.generics.clone(),
                            trait_name: trait_name.clone(),
                            sig: f.sig,
                            block: f.block,
                            file: file.to_owned(),
                            impl_line: Some(impl_line),
                        },
                    );
                }
                syn::ImplItem::Type(_) | syn::ImplItem::Const(_) => {
                    return Err(format!(
                        "associated types and consts are unsupported in impl for {owner}"
                    ))
                }
                _ => {}
            }
        }
        Ok(())
    }

    fn items(
        &mut self,
        items: Vec<Item>,
        module: &str,
        dir: &Path,
        file: &Path,
    ) -> Result<(), String> {
        self.scopes.entry(module.to_owned()).or_default();
        for item in items {
            let item = match &self.cfg {
                Some(cfg) => match crate::methods::configured::item(cfg, item)
                    .map_err(|e| format!("{}: {e}", file.display()))?
                {
                    Some(item) => item,
                    None => continue,
                },
                None => item,
            };
            match item {
                Item::Mod(m) => {
                    let name = m.ident.to_string();
                    let child = join(module, &name);
                    self.declare(module, &name, &child)?;
                    if let Some((_, items)) = m.content {
                        self.items(items, &child, &dir.join(&name), file)?;
                    } else {
                        let candidates = [
                            dir.join(format!("{name}.rs")),
                            dir.join(&name).join("mod.rs"),
                        ];
                        let path = candidates
                            .iter()
                            .find(|p| p.exists())
                            .ok_or_else(|| format!("module file for {child} not found"))?
                            .canonicalize()
                            .map_err(|e| e.to_string())?;
                        let text = fs::read_to_string(&path).map_err(|e| e.to_string())?;
                        let parsed = syn::parse_file(&text)
                            .map_err(|e| format!("{}: {e}", path.display()))?;
                        if self.files.insert(path.clone(), text).is_some() {
                            return Err(format!("{}: module loaded twice", path.display()));
                        }
                        let child_dir = if path.file_name().is_some_and(|f| f == "mod.rs") {
                            path.parent().unwrap().to_owned()
                        } else {
                            dir.join(&name)
                        };
                        self.items(parsed.items, &child, &child_dir, &path)?;
                    }
                }
                Item::Use(u) => self.import(module, &u.tree, String::new())?,
                Item::Struct(s) => {
                    let path = join(module, &s.ident.to_string());
                    self.declare(module, &s.ident.to_string(), &path)?;
                    let (fields, named) = fields(&s.fields);
                    self.structs.insert(
                        path.clone(),
                        Struct {
                            path,
                            module: module.to_owned(),
                            generics: s.generics.clone(),
                            fields,
                            tuple: !named,
                            derives: derives(&s.attrs)?,
                        },
                    );
                }
                Item::Enum(e) => {
                    let path = join(module, &e.ident.to_string());
                    self.declare(module, &e.ident.to_string(), &path)?;
                    let variants = e
                        .variants
                        .iter()
                        .map(|v| {
                            if v.discriminant.is_some() {
                                return Err(format!(
                                    "explicit discriminant on {path}::{}",
                                    v.ident
                                ));
                            }
                            let (fields, named) = fields(&v.fields);
                            Ok(Variant {
                                name: v.ident.to_string(),
                                fields,
                                named,
                            })
                        })
                        .collect::<Result<_, String>>()?;
                    self.enums.insert(
                        path.clone(),
                        Enum {
                            path,
                            module: module.to_owned(),
                            generics: e.generics.clone(),
                            variants,
                            derives: derives(&e.attrs)?,
                        },
                    );
                }
                Item::Fn(f) => {
                    let name = f.sig.ident.to_string();
                    let path = join(module, &name);
                    self.declare(module, &name, &path)?;
                    self.functions.insert(
                        path.clone(),
                        Function {
                            path,
                            module: module.to_owned(),
                            name,
                            owner: None,
                            self_ty: None,
                            impl_generics: syn::Generics::default(),
                            trait_name: None,
                            sig: f.sig,
                            block: *f.block,
                            file: file.to_owned(),
                            impl_line: None,
                        },
                    );
                }
                Item::Const(c) => {
                    let path = join(module, &c.ident.to_string());
                    self.declare(module, &c.ident.to_string(), &path)?;
                    self.consts.insert(
                        path.clone(),
                        Const {
                            path,
                            module: module.to_owned(),
                            ty: *c.ty,
                            expr: *c.expr,
                        },
                    );
                }
                Item::Impl(i) => {
                    // Resolved after all declarations are known.
                    self.pending_impls
                        .push((module.to_owned(), file.to_owned(), i));
                }
                Item::Type(t) => {
                    let path = join(module, &t.ident.to_string());
                    self.declare(module, &t.ident.to_string(), &path)?;
                    self.aliases.insert(
                        path,
                        Alias {
                            module: module.to_owned(),
                            generics: t.generics.clone(),
                            ty: *t.ty,
                        },
                    );
                }
                // Traits and macros are not translated; a use of one fails to
                // resolve with a diagnostic naming it.
                Item::Trait(_) | Item::Macro(_) | Item::ExternCrate(_) => {}
                other => {
                    return Err(format!(
                        "{}: unsupported item {}",
                        file.display(),
                        tokens(&other).chars().take(80).collect::<String>()
                    ))
                }
            }
        }
        Ok(())
    }

    fn declare(&mut self, module: &str, name: &str, path: &str) -> Result<(), String> {
        let scope = self.scopes.entry(module.to_owned()).or_default();
        if let Some(previous) = scope.insert(name.to_owned(), path.to_owned()) {
            if previous != path {
                return Err(format!("{name} declared twice in module {module:?}"));
            }
        }
        Ok(())
    }

    fn import(&mut self, module: &str, tree: &syn::UseTree, prefix: String) -> Result<(), String> {
        let extend = |p: &str, s: &str| {
            if p.is_empty() {
                s.to_owned()
            } else {
                format!("{p}::{s}")
            }
        };
        match tree {
            syn::UseTree::Path(p) => {
                self.import(module, &p.tree, extend(&prefix, &p.ident.to_string()))
            }
            syn::UseTree::Name(n) => {
                let name = n.ident.to_string();
                let full = extend(&prefix, &name);
                if name == "self" {
                    let last = prefix.rsplit("::").next().unwrap_or("").to_owned();
                    self.imports.push((module.to_owned(), last, prefix));
                } else {
                    self.imports.push((module.to_owned(), name, full));
                }
                Ok(())
            }
            syn::UseTree::Rename(r) => {
                self.imports.push((
                    module.to_owned(),
                    r.rename.to_string(),
                    extend(&prefix, &r.ident.to_string()),
                ));
                Ok(())
            }
            syn::UseTree::Glob(_) => {
                self.globs
                    .entry(module.to_owned())
                    .or_default()
                    .push(prefix);
                Ok(())
            }
            syn::UseTree::Group(g) => {
                for t in &g.items {
                    self.import(module, t, prefix.clone())?;
                }
                Ok(())
            }
        }
    }
}
