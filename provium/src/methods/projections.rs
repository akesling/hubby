//! Pure optional-record filtering and copied-field projection. The resulting
//! list denotes the lazy iterator's value sequence, not an allocation in Rust.
use super::arrays::{binding, copy_derived, relative};
use super::lookups::method;
use super::*;

pub(super) fn candidate(output: &syn::ReturnType) -> bool {
    matches!(output, syn::ReturnType::Type(_, ty) if matches!(&**ty, Type::ImplTrait(t) if t.bounds.iter().any(|b| matches!(b, syn::TypeParamBound::Trait(b) if b.path.segments.first().is_some_and(|s| s.ident == "Iterator")))))
}

fn closure(expression: &Expr) -> Result<&syn::ExprClosure, String> {
    let Expr::Closure(c) = expression else {
        return Err("record projection requires an explicit closure".into());
    };
    attrs(&c.attrs)?;
    if c.asyncness.is_some()
        || c.constness.is_some()
        || c.movability.is_some()
        || c.capture.is_some()
        || c.lifetimes.is_some()
        || c.inputs.len() != 1
        || !matches!(c.output, syn::ReturnType::Default)
    {
        return Err("record projection needs a plain one-parameter closure".into());
    }
    Ok(c)
}

impl Crate {
    pub(super) fn projection_value_type(&self, module: &str, ty: &Type) -> Result<String, String> {
        let name = base_type(ty)?;
        if tokens(ty) != name {
            return Err("projection requires a concrete Copy scalar or record value".into());
        }
        if ["bool", "u8", "u16", "u32", "u64", "usize"].contains(&name.as_str()) {
            return Ok(name);
        }
        let name = self.resolve(module, &name, 0)?;
        let record = self
            .structs
            .get(&name)
            .ok_or("unknown projected value type")?;
        if !record.generics.params.is_empty() || !copy_derived(record) || self.drops.contains(&name)
        {
            return Err("projected record must be nongeneric and derive Copy".into());
        }
        Ok(name)
    }

    pub(super) fn lower_projection(&self, name: &str) -> Result<Method, String> {
        let def = self.methods.get(name).ok_or("unknown projection method")?;
        let f = &def.item;
        let sig = &f.sig;
        attrs(&f.attrs)?;
        if sig.asyncness.is_some()
            || sig.constness.is_some()
            || sig.unsafety.is_some()
            || sig.abi.is_some()
            || !sig.generics.params.is_empty()
            || sig.generics.where_clause.is_some()
            || sig.inputs.len() != 1
        {
            return Err("projection requires a plain receiver-only method".into());
        }
        let Some(syn::FnArg::Receiver(receiver)) = sig.inputs.first() else {
            return Err("projection requires &self".into());
        };
        attrs(&receiver.attrs)?;
        if receiver.reference.is_none()
            || receiver.mutability.is_some()
            || receiver.colon_token.is_some()
        {
            return Err("projection requires &self".into());
        }
        self.iterator_traits()?;
        let syn::ReturnType::Type(_, output) = &sig.output else {
            return Err("missing iterator output".into());
        };
        let Type::ImplTrait(output) = &**output else {
            return Err("projection must return impl Iterator".into());
        };
        let mut iterator = None;
        let mut lifetime = false;
        for bound in &output.bounds {
            match bound {
                syn::TypeParamBound::Trait(t) if iterator.is_none() => iterator = Some(t),
                syn::TypeParamBound::Lifetime(l) if l.ident == "_" && !lifetime => lifetime = true,
                _ => {
                    return Err(
                        "projection permits only Iterator and an optional elided capture lifetime"
                            .into(),
                    )
                }
            }
        }
        let iterator = iterator.ok_or("projection needs an Iterator bound")?;
        if iterator.lifetimes.is_some()
            || !matches!(iterator.modifier, syn::TraitBoundModifier::None)
            || iterator.path.leading_colon.is_some()
            || iterator.path.segments.len() != 1
            || iterator.path.segments[0].ident != "Iterator"
        {
            return Err("projection must use the builtin Iterator trait".into());
        }
        let syn::PathArguments::AngleBracketed(arguments) = &iterator.path.segments[0].arguments
        else {
            return Err("projection needs its Item type".into());
        };
        let arguments: Vec<_> = arguments.args.iter().collect();
        let [syn::GenericArgument::AssocType(item)] = arguments.as_slice() else {
            return Err("projection needs one Item type".into());
        };
        if item.ident != "Item" || item.generics.is_some() {
            return Err("unsupported iterator type binding".into());
        }
        if def
            .impl_generics
            .type_params()
            .any(|p| p.ident == base_type(&item.ty).unwrap_or_default())
        {
            return Err("generic projected values require resolved Copy bounds".into());
        }
        let output_type = self.projection_value_type(&def.module, &item.ty)?;
        let [syn::Stmt::Expr(expression, None)] = f.block.stmts.as_slice() else {
            return Err("projection must retain its complete iterator expression".into());
        };
        let map = method(expression, "map", 1)?;
        let filter = method(&map.receiver, "filter", 1)?;
        let flatten = method(&filter.receiver, "flatten", 0)?;
        let iter = method(&flatten.receiver, "iter", 0)?;
        let field = path(&iter.receiver)?;
        if field.len() != 1 {
            return Err("projection requires a direct array field".into());
        }
        self.resolve(&def.module, &def.receiver, 0)?;
        let Type::Array(array) = self.field_type(def, &field)? else {
            return Err("projection requires a builtin array".into());
        };
        let Type::Path(option) = &*array.elem else {
            return Err("projection needs Option<Record> slots".into());
        };
        if option.qself.is_some()
            || option.path.leading_colon.is_some()
            || option.path.segments.len() != 1
            || option.path.segments[0].ident != "Option"
        {
            return Err("projection needs builtin Option slots".into());
        }
        let syn::PathArguments::AngleBracketed(arguments) = &option.path.segments[0].arguments
        else {
            return Err("missing slot type".into());
        };
        let arguments: Vec<_> = arguments.args.iter().collect();
        let [syn::GenericArgument::Type(record_type)] = arguments.as_slice() else {
            return Err("projection needs one slot payload".into());
        };
        let record_name = base_type(record_type)?;
        if tokens(record_type) != record_name
            || def
                .impl_generics
                .type_params()
                .any(|p| p.ident == record_name)
        {
            return Err("projection requires a concrete record slot".into());
        }
        let record = self.resolve(&def.module, &record_name, 0)?;
        let slot_record = self
            .structs
            .get(&record)
            .ok_or("projection slot must be a source struct")?;
        if !slot_record.generics.params.is_empty() {
            return Err("generic record slots need substitution".into());
        }
        let record_def = Definition {
            module: self.struct_modules[&record].clone(),
            file: def.file.clone(),
            item: f.clone(),
            receiver: record.clone(),
            impl_generics: syn::Generics::default(),
            self_type: None,
        };
        let filter = closure(&filter.args[0])?;
        let parameter = binding(&filter.inputs[0])?;
        let predicate = self.condition(&record_def, &relative(&filter.body, &parameter))?;
        let map = closure(&map.args[0])?;
        let parameter = binding(&map.inputs[0])?;
        let projected = path(&relative(&map.body, &parameter))?;
        if projected.is_empty() {
            return Err("projection must copy an explicit field".into());
        }
        let actual = self.projection_value_type(
            &record_def.module,
            self.field_type(&record_def, &projected)?,
        )?;
        if actual != output_type {
            return Err("projected field and iterator Item types disagree".into());
        }
        Ok(Method { name: name.into(), symbol: name.replace("::", "_"), source: def.file.clone(),
            first_line: f.span().start().line, last_line: f.span().end().line, rust: tokens(f), writes: vec![], body: vec![],
            iteration: None, last: None, truncation: None, installation: None, restoration: None, enum_projection: None,
            validator: None, view: None, record_at: None, lookup: None, selection: None, relocation: None,
            buffer: None, constructor: None, query: None,
            array: Some(arrays::Shape { field: field[0].clone(), capacity: tokens(&array.len), record,
                predicate: Some(predicate), projection: Some(projected), key: None, upsert: None,
                scope: "complete pure optional-record filter and copied-field iterator projection; ordered lazy value denotation; source/type/layout/lifetime refinement remains open" }),
        })
    }
}
