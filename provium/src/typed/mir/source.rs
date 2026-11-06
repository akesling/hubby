//! The crate sources the MIR parser consults: impl headers at an
//! `<impl at file:line:col: ..>` span, generic parameter lists, and the
//! declaration order of enum variants and struct fields.
use std::path::{Path, PathBuf};

/// The text of a crate's source files.
#[derive(Clone, Debug, Default)]
pub struct SourceMap {
    /// The crate root (`lib.rs`), as a key of `files`.
    root: String,
    /// `(path, text)`; paths are matched against MIR spans by suffix.
    files: Vec<(String, String)>,
}

impl SourceMap {
    /// Every `.rs` file under the directory of `crate_root`.
    pub fn load(crate_root: &Path) -> Result<SourceMap, String> {
        let dir = crate_root
            .parent()
            .ok_or_else(|| format!("{}: no parent directory", crate_root.display()))?;
        let mut paths = vec![];
        collect(dir, &mut paths)?;
        paths.sort();
        let mut files = vec![];
        for p in paths {
            let text = std::fs::read_to_string(&p).map_err(|e| format!("{}: {e}", p.display()))?;
            files.push((p.to_string_lossy().into_owned(), text));
        }
        let root = crate_root.to_string_lossy().into_owned();
        if !files.iter().any(|(p, _)| *p == root) {
            return Err(format!("{root}: crate root not found"));
        }
        Ok(SourceMap { root, files })
    }

    /// A source map from `(path, text)` pairs; `root` is the crate root's path.
    pub fn from_files(root: &str, files: Vec<(String, String)>) -> SourceMap {
        SourceMap {
            root: root.to_owned(),
            files,
        }
    }

    /// The file a MIR span names (`jarl/src/state.rs`): the unique file whose
    /// path is that path or ends with `/` and it.
    pub fn find(&self, span_file: &str) -> Result<(&str, &str), String> {
        let suffix = format!("/{span_file}");
        let hits: Vec<_> = self
            .files
            .iter()
            .filter(|(p, _)| p == span_file || p.ends_with(&suffix))
            .collect();
        match hits.as_slice() {
            [(p, t)] => Ok((p, t)),
            [] => Err(format!("no source file matches `{span_file}`")),
            _ => Err(format!("several source files match `{span_file}`")),
        }
    }

    /// The module path (`node::machine`) of a file under the crate root's
    /// directory, by the standard layout.
    fn module_of(&self, path: &str) -> String {
        let dir = Path::new(&self.root).parent().unwrap_or(Path::new(""));
        let rel = Path::new(path).strip_prefix(dir).unwrap_or(Path::new(path));
        let mut segs: Vec<String> = rel
            .with_extension("")
            .components()
            .map(|c| c.as_os_str().to_string_lossy().into_owned())
            .collect();
        if segs.last().is_some_and(|s| s == "mod")
            || segs.len() == 1 && (segs[0] == "lib" || segs[0] == "main")
        {
            segs.pop();
        }
        segs.join("::")
    }
}

fn collect(dir: &Path, out: &mut Vec<PathBuf>) -> Result<(), String> {
    for entry in std::fs::read_dir(dir).map_err(|e| format!("{}: {e}", dir.display()))? {
        let path = entry.map_err(|e| e.to_string())?.path();
        if path.is_dir() {
            collect(&path, out)?;
        } else if path.extension().is_some_and(|e| e == "rs") {
            out.push(path);
        }
    }
    Ok(())
}

/// A generic parameter (lifetimes are not recorded).
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Generic {
    pub name: String,
    pub is_const: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Fields {
    Named(Vec<String>),
    Unnamed(usize),
    Unit,
}

#[derive(Clone, Debug)]
pub(crate) struct Variant {
    pub name: String,
    pub fields: Fields,
    pub explicit_discr: bool,
}

#[derive(Clone, Debug)]
pub(crate) enum TypeKind {
    Struct(Fields),
    Enum(Vec<Variant>),
}

#[derive(Clone, Debug)]
pub(crate) struct TypeDecl {
    pub name: String,
    /// The declaring module (`node`, empty at the crate root).
    pub module: String,
    pub generics: Vec<Generic>,
    pub kind: TypeKind,
    pub file: String,
    /// `(line, 1-based column, trait)` of each name in `#[derive(..)]`.
    pub derives: Vec<(usize, usize, String)>,
}

#[derive(Clone, Debug)]
pub(crate) struct FnDecl {
    pub name: String,
    pub module: String,
    pub generics: Vec<Generic>,
    /// Positions (counting a receiver as 0) of parameters whose type is an
    /// `impl Trait` (each one a synthetic generic parameter).
    pub apit: Vec<usize>,
    /// An `impl Trait` nested inside a parameter type (not supported).
    pub nested_apit: bool,
}

#[derive(Clone, Debug)]
pub(crate) struct ImplDecl {
    pub file: String,
    pub line: usize,
    pub col: usize,
    pub self_name: String,
    pub trait_name: Option<String>,
    /// The trait's path as written in the impl (`core::fmt::Display`).
    pub trait_path: Option<String>,
    pub generics: Vec<Generic>,
    pub fns: Vec<FnDecl>,
}

/// What the parser looks up in the sources.
#[derive(Debug, Default)]
pub(crate) struct Index {
    pub types: Vec<TypeDecl>,
    pub impls: Vec<ImplDecl>,
    pub fns: Vec<FnDecl>,
}

impl Index {
    pub fn build(src: &SourceMap) -> Result<Index, String> {
        let mut ix = Index::default();
        for (path, text) in &src.files {
            let file = syn::parse_file(text).map_err(|e| format!("{path}: {e}"))?;
            let module = src.module_of(path);
            ix.items(path, &module, &file.items)?;
        }
        Ok(ix)
    }

    fn items(&mut self, file: &str, module: &str, items: &[syn::Item]) -> Result<(), String> {
        for item in items {
            match item {
                syn::Item::Mod(m) => {
                    if let Some((_, inner)) = &m.content {
                        let sub = if module.is_empty() {
                            m.ident.to_string()
                        } else {
                            format!("{module}::{}", m.ident)
                        };
                        self.items(file, &sub, inner)?;
                    }
                }
                syn::Item::Struct(s) => {
                    let fields = fields(&s.fields);
                    self.types.push(TypeDecl {
                        name: s.ident.to_string(),
                        module: module.to_owned(),
                        generics: generics(&s.generics),
                        kind: TypeKind::Struct(fields),
                        file: file.to_owned(),
                        derives: derives(&s.attrs),
                    });
                }
                syn::Item::Enum(e) => {
                    let variants = e
                        .variants
                        .iter()
                        .map(|v| Variant {
                            name: v.ident.to_string(),
                            fields: fields(&v.fields),
                            explicit_discr: v.discriminant.is_some(),
                        })
                        .collect();
                    self.types.push(TypeDecl {
                        name: e.ident.to_string(),
                        module: module.to_owned(),
                        generics: generics(&e.generics),
                        kind: TypeKind::Enum(variants),
                        file: file.to_owned(),
                        derives: derives(&e.attrs),
                    });
                }
                syn::Item::Fn(f) => self.fns.push(fn_decl(module, &f.sig)),
                syn::Item::Impl(i) => {
                    let start = i.impl_token.span.start();
                    let self_name = match &*i.self_ty {
                        syn::Type::Path(p) if p.qself.is_none() => {
                            p.path.segments.last().map(|s| s.ident.to_string())
                        }
                        _ => None,
                    };
                    let Some(self_name) = self_name else {
                        // Impls on non-path types are recorded with no name;
                        // a MIR body in one is rejected when looked up.
                        self.impls.push(ImplDecl {
                            file: file.to_owned(),
                            line: start.line,
                            col: start.column + 1,
                            self_name: String::new(),
                            trait_name: None,
                            trait_path: None,
                            generics: generics(&i.generics),
                            fns: vec![],
                        });
                        continue;
                    };
                    let trait_name = i
                        .trait_
                        .as_ref()
                        .and_then(|(_, p, _)| p.segments.last().map(|s| s.ident.to_string()));
                    let trait_path = i.trait_.as_ref().map(|(_, p, _)| {
                        p.segments
                            .iter()
                            .map(|s| s.ident.to_string())
                            .collect::<Vec<_>>()
                            .join("::")
                    });
                    let fns = i
                        .items
                        .iter()
                        .filter_map(|it| match it {
                            syn::ImplItem::Fn(f) => Some(fn_decl(module, &f.sig)),
                            _ => None,
                        })
                        .collect();
                    self.impls.push(ImplDecl {
                        file: file.to_owned(),
                        line: start.line,
                        col: start.column + 1,
                        self_name,
                        trait_name,
                        trait_path,
                        generics: generics(&i.generics),
                        fns,
                    });
                }
                _ => {}
            }
        }
        Ok(())
    }

    /// The types named `name`.
    pub fn types_named(&self, name: &str) -> Vec<&TypeDecl> {
        self.types.iter().filter(|t| t.name == name).collect()
    }
}

fn fields(f: &syn::Fields) -> Fields {
    match f {
        syn::Fields::Named(n) => Fields::Named(
            n.named
                .iter()
                .map(|f| f.ident.as_ref().map(|i| i.to_string()).unwrap_or_default())
                .collect(),
        ),
        syn::Fields::Unnamed(u) => Fields::Unnamed(u.unnamed.len()),
        syn::Fields::Unit => Fields::Unit,
    }
}

fn generics(g: &syn::Generics) -> Vec<Generic> {
    g.params
        .iter()
        .filter_map(|p| match p {
            syn::GenericParam::Type(t) => Some(Generic {
                name: t.ident.to_string(),
                is_const: false,
            }),
            syn::GenericParam::Const(c) => Some(Generic {
                name: c.ident.to_string(),
                is_const: true,
            }),
            syn::GenericParam::Lifetime(_) => None,
        })
        .collect()
}

fn derives(attrs: &[syn::Attribute]) -> Vec<(usize, usize, String)> {
    let mut out = vec![];
    for a in attrs {
        if !a.path().is_ident("derive") {
            continue;
        }
        let syn::Meta::List(list) = &a.meta else {
            continue;
        };
        for tt in list.tokens.clone() {
            if let proc_macro2::TokenTree::Ident(i) = tt {
                let s = i.span().start();
                out.push((s.line, s.column + 1, i.to_string()));
            }
        }
    }
    out
}

fn fn_decl(module: &str, sig: &syn::Signature) -> FnDecl {
    let mut apit = vec![];
    let mut nested_apit = false;
    for (i, input) in sig.inputs.iter().enumerate() {
        if let syn::FnArg::Typed(t) = input {
            if matches!(&*t.ty, syn::Type::ImplTrait(_)) {
                apit.push(i);
            } else if contains_impl(&t.ty) {
                nested_apit = true;
            }
        }
    }
    FnDecl {
        name: sig.ident.to_string(),
        module: module.to_owned(),
        generics: generics(&sig.generics),
        apit,
        nested_apit,
    }
}

fn contains_impl(t: &syn::Type) -> bool {
    use syn::visit::Visit;
    struct V(bool);
    impl<'a> Visit<'a> for V {
        fn visit_type_impl_trait(&mut self, _: &'a syn::TypeImplTrait) {
            self.0 = true;
        }
    }
    let mut v = V(false);
    v.visit_type(t);
    v.0
}
