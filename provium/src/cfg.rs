//! Declaration-level conditional compilation accounting. This is not macro
//! expansion, Rust name resolution, or a source-preservation proof.
use std::collections::BTreeSet;
use syn::{ext::IdentExt, parse::Parser, punctuated::Punctuated, Attribute, Meta, Token};

#[derive(Debug, Clone)]
pub struct Configuration {
    flags: BTreeSet<String>,
    values: BTreeSet<(String, String)>,
}
impl Configuration {
    /// Parse the effective `rustc --print cfg` output, retaining repeated keys.
    pub fn parse(output: &str) -> Result<Self, String> {
        let mut cfg = Self {
            flags: BTreeSet::new(),
            values: BTreeSet::new(),
        };
        for line in output.lines().filter(|line| !line.trim().is_empty()) {
            match syn::parse_str::<Meta>(line).map_err(|e| format!("invalid compiler cfg: {e}"))? {
                Meta::Path(path) => {
                    cfg.flags.insert(name(&path)?);
                }
                Meta::NameValue(pair) => {
                    cfg.values.insert((name(&pair.path)?, value(&pair.value)?));
                }
                _ => return Err("compiler cfg must contain flags or string-valued keys".into()),
            }
        }
        Ok(cfg)
    }
    pub fn evaluate(&self, predicate: &Meta) -> Result<bool, String> {
        self.evaluate_at(predicate, 0)
    }
    fn evaluate_at(&self, predicate: &Meta, depth: usize) -> Result<bool, String> {
        if depth > 64 {
            return Err("cfg nesting exceeds supported depth".into());
        }
        match predicate {
            Meta::Path(path) => Ok(self.flags.contains(&name(path)?)),
            Meta::NameValue(pair) => Ok(self
                .values
                .contains(&(name(&pair.path)?, value(&pair.value)?))),
            Meta::List(list) => {
                let predicates = list
                    .parse_args_with(Punctuated::<Meta, Token![,]>::parse_terminated)
                    .map_err(|e| format!("invalid cfg predicate: {e}"))?;
                // Validate every operand, including those a Boolean evaluation
                // could short-circuit, so unsupported syntax cannot disappear.
                let results = predicates
                    .iter()
                    .map(|p| self.evaluate_at(p, depth + 1))
                    .collect::<Result<Vec<_>, _>>()?;
                match name(&list.path)?.as_str() {
                    "all" => Ok(results.iter().all(|v| *v)),
                    "any" => Ok(results.iter().any(|v| *v)),
                    "not" if results.len() == 1 => Ok(!results[0]),
                    _ => Err("unsupported cfg operator or arity".into()),
                }
            }
        }
    }
    /// Expand cfg_attr and test all cfg attributes. Remaining attributes are
    /// returned for consumers to handle; no macro or path semantics are assumed.
    pub fn attributes(&self, attributes: &[Attribute]) -> Result<Option<Vec<Meta>>, String> {
        let mut expanded = vec![];
        for attribute in attributes {
            self.expand(&attribute.meta, &mut expanded, 0)?;
        }
        let mut enabled = true;
        let mut remaining = vec![];
        for attribute in expanded {
            if attribute.path().is_ident("cfg") {
                let Meta::List(list) = attribute else {
                    return Err("cfg requires a predicate".into());
                };
                let predicate = list
                    .parse_args::<Meta>()
                    .map_err(|e| format!("invalid cfg attribute: {e}"))?;
                enabled &= self.evaluate(&predicate)?;
            } else {
                remaining.push(attribute);
            }
        }
        Ok(enabled.then_some(remaining))
    }
    fn expand(&self, attribute: &Meta, output: &mut Vec<Meta>, depth: usize) -> Result<(), String> {
        if depth > 64 {
            return Err("cfg_attr nesting exceeds supported depth".into());
        }
        if !attribute.path().is_ident("cfg_attr") {
            output.push(attribute.clone());
            return Ok(());
        }
        let Meta::List(list) = attribute else {
            return Err("cfg_attr requires arguments".into());
        };
        let args = list
            .parse_args_with(Punctuated::<Meta, Token![,]>::parse_terminated)
            .map_err(|e| format!("invalid cfg_attr: {e}"))?;
        let mut args = args.iter();
        let condition = args.next().ok_or("cfg_attr requires a predicate")?;
        if self.evaluate(condition)? {
            for attribute in args {
                self.expand(attribute, output, depth + 1)?;
            }
        }
        Ok(())
    }
    pub(crate) fn declaration(
        &self,
        node: &impl quote::ToTokens,
    ) -> Result<Option<Vec<Meta>>, String> {
        let parse = |input: syn::parse::ParseStream<'_>| {
            let attributes = Attribute::parse_outer(input)?;
            let _: proc_macro2::TokenStream = input.parse()?;
            Ok(attributes)
        };
        self.attributes(
            &parse
                .parse2(node.to_token_stream())
                .map_err(|e| e.to_string())?,
        )
    }
}
fn name(path: &syn::Path) -> Result<String, String> {
    path.get_ident()
        .map(|ident| ident.unraw().to_string())
        .ok_or("cfg names must be single identifiers".into())
}
fn value(expr: &syn::Expr) -> Result<String, String> {
    if let syn::Expr::Lit(syn::ExprLit {
        lit: syn::Lit::Str(s),
        ..
    }) = expr
    {
        Ok(s.value())
    } else {
        Err("cfg values must be string literals".into())
    }
}
