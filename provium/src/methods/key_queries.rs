//! Pure identity queries over optional records. Custom equality is not inferred.
use super::arrays::{binding, named, relative};
use super::*;

#[derive(Debug, Serialize)]
pub struct KeyQuery {
    pub argument: String,
    pub path: Vec<String>,
    pub value_type: String,
}

impl Crate {
    fn equality_value(&self, module: &str, ty: &Type) -> Result<String, String> {
        let name = self.projection_value_type(module, ty)?;
        if let Some(record) = self.structs.get(&name) {
            let derived =
                record.attrs.iter().any(|a| {
                    a.path().is_ident("derive") && a.parse_args_with(
                    syn::punctuated::Punctuated::<syn::Ident, syn::Token![,]>::parse_terminated,
                ).is_ok_and(|ds| ds.iter().any(|d| d == "PartialEq"))
                });
            if !derived {
                return Err("identity query requires derived structural PartialEq".into());
            }
            // This first contract covers scalar records, not recursive, generic,
            // floating-point or user-defined field equality.
            for field in &record.fields {
                let scalar = tokens(&field.ty);
                if !["bool", "u8", "u16", "u32", "u64", "usize"].contains(&scalar.as_str()) {
                    return Err("identity record equality requires builtin scalar fields".into());
                }
            }
        }
        Ok(name)
    }

    pub(super) fn key_query(
        &self,
        def: &Definition,
        record: &Definition,
        body: &Expr,
        member: &str,
    ) -> Result<(KeyQuery, Condition), String> {
        let Some(syn::FnArg::Typed(argument)) = def.item.sig.inputs.iter().nth(1) else {
            return Err("identity query needs one typed value argument".into());
        };
        attrs(&argument.attrs)?;
        let argument_name = binding(&argument.pat)?;
        if argument_name == member {
            return Err("identity argument is shadowed by its predicate binding".into());
        }
        if def
            .impl_generics
            .type_params()
            .any(|p| p.ident == base_type(&argument.ty).unwrap_or_default())
        {
            return Err("identity query needs a resolved concrete equality type".into());
        }
        let expected = self.equality_value(&def.module, &argument.ty)?;
        let (equality, predicate) = match body {
            Expr::Binary(b) if matches!(b.op, syn::BinOp::And(_)) => {
                attrs(&b.attrs)?;
                (
                    &*b.left,
                    self.condition(record, &relative(&b.right, member))?,
                )
            }
            _ => (body, Condition::Boolean(true)),
        };
        let Expr::Binary(equality) = equality else {
            return Err(
                "identity query needs a field equality, optionally followed by boolean flags"
                    .into(),
            );
        };
        attrs(&equality.attrs)?;
        if !matches!(equality.op, syn::BinOp::Eq(_)) || !named(&equality.right, &argument_name) {
            return Err("identity query must compare a record field to its argument".into());
        }
        let projected = path(&relative(&equality.left, member))?;
        if projected.is_empty() {
            return Err("identity query requires an explicit record field".into());
        }
        let actual = self.equality_value(&record.module, self.field_type(record, &projected)?)?;
        if actual != expected {
            return Err("identity field and argument types disagree".into());
        }
        Ok((
            KeyQuery {
                argument: argument_name,
                path: projected,
                value_type: actual,
            },
            predicate,
        ))
    }
}
