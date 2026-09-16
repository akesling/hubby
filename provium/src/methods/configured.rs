//! Declaration selection for the method frontend. Original source bytes remain
//! in Crate::files; this transformation is still part of the trusted frontend.
use crate::cfg::Configuration;
use quote::{quote, ToTokens};
use syn::{
    parse::{Parse, Parser},
    Attribute, Fields, Item,
};

fn declaration<T: Parse + ToTokens>(cfg: &Configuration, node: T) -> Result<Option<T>, String> {
    let parse = |input: syn::parse::ParseStream<'_>| {
        let attributes = Attribute::parse_outer(input)?;
        let rest: proc_macro2::TokenStream = input.parse()?;
        Ok((attributes, rest))
    };
    let (attributes, rest) = parse
        .parse2(node.to_token_stream())
        .map_err(|e| e.to_string())?;
    let Some(attributes) = cfg.attributes(&attributes)? else {
        return Ok(None);
    };
    syn::parse2(quote!(#(#[#attributes])* #rest))
        .map(Some)
        .map_err(|e| e.to_string())
}
fn fields(cfg: &Configuration, fields: &mut Fields) -> Result<(), String> {
    let list = match fields {
        Fields::Named(named) => &mut named.named,
        Fields::Unnamed(unnamed) => &mut unnamed.unnamed,
        Fields::Unit => return Ok(()),
    };
    let mut kept = syn::punctuated::Punctuated::new();
    for mut field in std::mem::take(list) {
        if let Some(attributes) = cfg.attributes(&field.attrs)? {
            field.attrs = attributes
                .iter()
                .map(|meta| syn::parse_quote!(#[#meta]))
                .collect();
            kept.push(field);
        }
    }
    *list = kept;
    Ok(())
}
pub(super) fn item(cfg: &Configuration, node: Item) -> Result<Option<Item>, String> {
    let Some(mut node) = declaration(cfg, node)? else {
        return Ok(None);
    };
    match &mut node {
        Item::Struct(s) => fields(cfg, &mut s.fields)?,
        Item::Enum(e) => {
            let mut kept = syn::punctuated::Punctuated::new();
            for variant in std::mem::take(&mut e.variants) {
                if let Some(mut variant) = declaration(cfg, variant)? {
                    fields(cfg, &mut variant.fields)?;
                    kept.push(variant);
                }
            }
            e.variants = kept;
        }
        Item::Impl(i) => {
            i.items = std::mem::take(&mut i.items)
                .into_iter()
                .map(|member| declaration(cfg, member))
                .collect::<Result<Vec<_>, _>>()?
                .into_iter()
                .flatten()
                .collect();
        }
        Item::Trait(t) => {
            t.items = std::mem::take(&mut t.items)
                .into_iter()
                .map(|member| declaration(cfg, member))
                .collect::<Result<Vec<_>, _>>()?
                .into_iter()
                .flatten()
                .collect();
        }
        // Inline production modules and unsupported item kinds still go through
        // the frontend's existing rejection/coverage rules.
        _ => {}
    }
    struct Remaining(Option<String>);
    impl<'ast> syn::visit::Visit<'ast> for Remaining {
        fn visit_attribute(&mut self, attr: &'ast Attribute) {
            if attr.path().is_ident("cfg") || attr.path().is_ident("cfg_attr") {
                self.0 = Some(format!(
                    "conditional compilation at this nested location is unsupported: {}",
                    attr.to_token_stream()
                ));
            }
            syn::visit::visit_attribute(self, attr);
        }
    }
    let mut remaining = Remaining(None);
    syn::visit::Visit::visit_item(&mut remaining, &node);
    if let Some(error) = remaining.0 {
        return Err(error);
    }
    Ok(Some(node))
}
