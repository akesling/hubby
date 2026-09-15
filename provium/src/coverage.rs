//! Conservative source inventory and consumer-owned coverage accounting.
//!
//! This is a syntactic change detector, not name resolution or a proof of call
//! closure. Calls, macros, attributes and derives remain explicit review inputs.
use crate::project::hash;
use quote::ToTokens;
use serde::{Deserialize, Serialize};
use std::{collections::BTreeMap, fs, path::Path};
use syn::{spanned::Spanned, visit::Visit};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Source {
    pub path: String,
    pub sha256: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Item {
    pub id: String,
    pub kind: String,
    pub source: String,
    pub line: usize,
    pub public: bool,
    pub syntax_sha256: String,
    pub calls: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Inventory {
    pub schema: u32,
    pub sources: Vec<Source>,
    pub items: Vec<Item>,
    /// These limitations cannot be discharged by editing the ledger.
    pub limitations: Vec<String>,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Entry {
    pub requirements: Vec<String>,
    pub status: Status,
    pub note: String,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Status {
    Planned,
    ComponentEvidence,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Ledger {
    pub schema: u32,
    pub inventory: Inventory,
    pub entries: BTreeMap<String, Entry>,
}

#[derive(Debug)]
pub struct Report {
    pub items: usize,
    pub component_items: usize,
}

fn tokens(value: &impl ToTokens) -> String {
    value.to_token_stream().to_string()
}

struct Calls(Vec<String>);
impl<'ast> Visit<'ast> for Calls {
    fn visit_expr_call(&mut self, call: &'ast syn::ExprCall) {
        self.0.push(format!("call {}", tokens(&call.func)));
        syn::visit::visit_expr_call(self, call);
    }
    fn visit_expr_method_call(&mut self, call: &'ast syn::ExprMethodCall) {
        self.0.push(format!("method {}", call.method));
        syn::visit::visit_expr_method_call(self, call);
    }
    fn visit_macro(&mut self, mac: &'ast syn::Macro) {
        self.0.push(format!("macro {}", tokens(&mac.path)));
        syn::visit::visit_macro(self, mac);
    }
}

struct Collector<'a> {
    root: &'a Path,
    inventory: Inventory,
}
impl Collector<'_> {
    fn record(
        &mut self,
        id: String,
        kind: &str,
        source: &str,
        node: &impl ToTokens,
        public: bool,
        mut calls: Vec<String>,
    ) {
        calls.sort();
        calls.dedup();
        self.inventory.items.push(Item {
            id,
            kind: kind.into(),
            source: source.into(),
            line: node.span().start().line,
            public,
            syntax_sha256: hash(tokens(node)),
            calls,
        });
    }

    fn file(&mut self, path: &Path, module: &str, directory: &Path) -> Result<(), String> {
        let path = path
            .canonicalize()
            .map_err(|e| format!("{}: {e}", path.display()))?;
        let relative = path
            .strip_prefix(self.root)
            .map_err(|_| "module outside consumer crate")?;
        let relative = relative.to_str().ok_or("non-UTF8 source path")?.to_owned();
        if self.inventory.sources.iter().any(|s| s.path == relative) {
            return Err(format!("duplicate/cyclic module source: {relative}"));
        }
        let source = fs::read_to_string(&path).map_err(|e| e.to_string())?;
        let parsed = syn::parse_file(&source).map_err(|e| format!("{relative}: {e}"))?;
        self.inventory.sources.push(Source {
            path: relative.clone(),
            sha256: hash(source),
        });
        self.items(&parsed.items, module, &relative, directory)
    }

    fn items(
        &mut self,
        items: &[syn::Item],
        module: &str,
        source: &str,
        directory: &Path,
    ) -> Result<(), String> {
        for (ordinal, item) in items.iter().enumerate() {
            let anonymous = format!("{module}::<item:{ordinal}>");
            let mut calls = Calls(vec![]);
            calls.visit_item(item);
            match item {
                syn::Item::Mod(m) => {
                    let name = format!("{module}::{}", m.ident);
                    self.record(
                        name.clone(),
                        "module",
                        source,
                        m,
                        matches!(m.vis, syn::Visibility::Public(_)),
                        calls.0,
                    );
                    // Exact #[cfg(test)] modules are recorded but not traversed.
                    // Other cfgs are conservatively included, never evaluated away.
                    if m.attrs.iter().any(|a| {
                        a.path().is_ident("cfg")
                            && a.parse_args::<syn::Ident>().is_ok_and(|i| i == "test")
                    }) {
                        continue;
                    }
                    if m.attrs.iter().any(|a| a.path().is_ident("path")) {
                        return Err(format!(
                            "{name}: #[path] module resolution is not supported"
                        ));
                    }
                    if let Some((_, children)) = &m.content {
                        self.items(
                            children,
                            &name,
                            source,
                            &directory.join(m.ident.to_string()),
                        )?;
                    } else {
                        let flat = directory.join(format!("{}.rs", m.ident));
                        let nested = directory.join(m.ident.to_string()).join("mod.rs");
                        if flat.exists() == nested.exists() {
                            return Err(format!("{name}: missing or ambiguous module source"));
                        }
                        let file = if flat.exists() { flat } else { nested };
                        self.file(&file, &name, &directory.join(m.ident.to_string()))?;
                    }
                }
                syn::Item::Impl(i) => {
                    let owner = match &i.trait_ {
                        Some((neg, t, _)) => {
                            format!("<{} as {}{}>", tokens(&i.self_ty), tokens(neg), tokens(t))
                        }
                        None => format!("<{}>", tokens(&i.self_ty)),
                    };
                    self.record(anonymous, "impl", source, i, false, vec![]);
                    for member in &i.items {
                        let (ident, kind, public) = match member {
                            syn::ImplItem::Fn(f) => (
                                &f.sig.ident,
                                "method",
                                matches!(f.vis, syn::Visibility::Public(_)),
                            ),
                            syn::ImplItem::Const(c) => (
                                &c.ident,
                                "associated_const",
                                matches!(c.vis, syn::Visibility::Public(_)),
                            ),
                            syn::ImplItem::Type(t) => (
                                &t.ident,
                                "associated_type",
                                matches!(t.vis, syn::Visibility::Public(_)),
                            ),
                            _ => {
                                return Err(format!(
                                    "{module}: unsupported impl inventory item {}",
                                    tokens(member)
                                ))
                            }
                        };
                        let mut calls = Calls(vec![]);
                        calls.visit_impl_item(member);
                        self.record(
                            format!("{module}::{owner}::{ident}"),
                            kind,
                            source,
                            member,
                            public,
                            calls.0,
                        );
                    }
                }
                syn::Item::Fn(f) => self.record(
                    format!("{module}::{}", f.sig.ident),
                    "function",
                    source,
                    f,
                    matches!(f.vis, syn::Visibility::Public(_)),
                    calls.0,
                ),
                syn::Item::Struct(s) => self.record(
                    format!("{module}::{}", s.ident),
                    "struct",
                    source,
                    s,
                    matches!(s.vis, syn::Visibility::Public(_)),
                    calls.0,
                ),
                syn::Item::Enum(e) => self.record(
                    format!("{module}::{}", e.ident),
                    "enum",
                    source,
                    e,
                    matches!(e.vis, syn::Visibility::Public(_)),
                    calls.0,
                ),
                syn::Item::Trait(t) => {
                    self.record(
                        format!("{module}::{}", t.ident),
                        "trait",
                        source,
                        t,
                        matches!(t.vis, syn::Visibility::Public(_)),
                        calls.0,
                    );
                    for member in &t.items {
                        if let syn::TraitItem::Fn(f) = member {
                            let mut calls = Calls(vec![]);
                            calls.visit_trait_item_fn(f);
                            self.record(
                                format!("{module}::{}::{}", t.ident, f.sig.ident),
                                "trait_method",
                                source,
                                f,
                                true,
                                calls.0,
                            );
                        }
                    }
                }
                // Imports, derives, fields, variants, attributes and anonymous
                // items stay in hashed syntax. They are not resolved by this pass.
                _ => self.record(anonymous, "other", source, item, false, calls.0),
            }
        }
        Ok(())
    }
}

/// Inventory a library's original source without compiling or installing tools.
/// Every source item is included conservatively; this is not a reachable-code proof.
pub fn inventory(crate_root: &Path, library: &Path) -> Result<Inventory, String> {
    let root = crate_root.canonicalize().map_err(|e| e.to_string())?;
    let library = root.join(library);
    let mut collector = Collector {
        root: &root,
        inventory: Inventory {
            schema: 1,
            sources: vec![],
            items: vec![],
            limitations: vec![
                "syntactic inventory; call/type/trait/derive resolution is not proved".into(),
                "cfg other than exact cfg(test) modules is conservatively included".into(),
                "no Cargo build/dependency identity or macro expansion is established".into(),
                "source-to-IR preservation and composed safety/progress roots remain required"
                    .into(),
            ],
        },
    };
    collector.file(
        &library,
        "crate",
        library.parent().ok_or("library path has no parent")?,
    )?;
    collector
        .inventory
        .sources
        .sort_by(|a, b| a.path.cmp(&b.path));
    collector.inventory.items.sort_by(|a, b| a.id.cmp(&b.id));
    for pair in collector.inventory.items.windows(2) {
        if pair[0].id == pair[1].id {
            return Err(format!("ambiguous inventory identity: {}", pair[0].id));
        }
    }
    Ok(collector.inventory)
}

/// Check that a consumer has reviewed every inventoried item of the current source.
/// A successful audit is accounting evidence, never a correctness certificate.
pub fn audit(crate_root: &Path, library: &Path, ledger: &Path) -> Result<Report, String> {
    let actual = inventory(crate_root, library)?;
    let ledger: Ledger = serde_json::from_slice(&fs::read(ledger).map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())?;
    if ledger.schema != 1 || ledger.inventory != actual {
        return Err("coverage inventory is stale or unsupported; review the changed source before updating the ledger".into());
    }
    if ledger.entries.len() != actual.items.len() {
        return Err("coverage ledger must classify exactly every inventoried item".into());
    }
    let mut component_items = 0;
    for item in &actual.items {
        let entry = ledger
            .entries
            .get(&item.id)
            .ok_or_else(|| format!("unclassified item {}", item.id))?;
        if entry.requirements.is_empty()
            || entry.requirements.iter().any(|r| r.trim().is_empty())
            || entry.note.trim().is_empty()
        {
            return Err(format!(
                "{} requires obligation IDs and a review note",
                item.id
            ));
        }
        component_items += usize::from(matches!(entry.status, Status::ComponentEvidence));
    }
    Ok(Report {
        items: actual.items.len(),
        component_items,
    })
}

/// Fail closed until Provium implements complete source correspondence and root
/// theorem verification. Ledger status strings can never authorize this claim.
pub fn require_complete(crate_root: &Path, library: &Path, ledger: &Path) -> Result<(), String> {
    let report = audit(crate_root, library, ledger)?;
    Err(format!("full proof unavailable: {} inventoried items, {} with declared component evidence; source correspondence, resolved closure, and composed safety/progress certificates are not implemented", report.items, report.component_items))
}

/// Write an inventory report outside Cargo's target directory. No certificate is issued.
pub fn write_inventory(
    crate_root: &Path,
    library: &Path,
    output: &Path,
) -> Result<Inventory, String> {
    let report = inventory(crate_root, library)?;
    crate::project::prepare_output(output)?;
    fs::create_dir_all(output).map_err(|e| e.to_string())?;
    let absolute_output = output.canonicalize().map_err(|e| e.to_string())?;
    let root = crate_root.canonicalize().map_err(|e| e.to_string())?;
    if report
        .sources
        .iter()
        .any(|source| root.join(&source.path).starts_with(&absolute_output))
    {
        return Err("inventory output must not contain source inputs".into());
    }
    fs::write(
        output.join("inventory.json"),
        serde_json::to_vec_pretty(&report).map_err(|e| e.to_string())?,
    )
    .map_err(|e| e.to_string())?;
    Ok(report)
}
