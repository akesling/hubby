//! Shared selection of a copied record from an Option, with a fully checked
//! builtin-derived default. The eager default is checked even on the Some path.
use super::*;
#[derive(Debug, Serialize)]
pub struct Selection {
    pub optional: Vec<String>,
    pub record_field: String,
    pub record_type: String,
    pub fallback: Vec<constructors::Field>,
    pub scope: &'static str,
}
impl Crate {
    pub(super) fn lower_selection(&self, name: &str) -> Result<Method, String> {
        let def = self.methods.get(name).ok_or("unknown record selector")?;
        let f = &def.item;
        let sig = &f.sig;
        attrs(&f.attrs)?;
        if sig.asyncness.is_some()
            || sig.unsafety.is_some()
            || sig.constness.is_some()
            || sig.abi.is_some()
            || !sig.generics.params.is_empty()
            || sig.generics.where_clause.is_some()
            || sig.inputs.len() != 1
        {
            return Err("record selector requires a plain shared receiver-only method".into());
        }
        let Some(syn::FnArg::Receiver(r)) = sig.inputs.first() else {
            return Err("record selector requires &self".into());
        };
        attrs(&r.attrs)?;
        if r.reference.is_none() || r.mutability.is_some() || r.colon_token.is_some() {
            return Err("record selector requires &self".into());
        }
        self.constructor_namespaces(def)?;
        self.resolve(&def.module, &def.receiver, 0)?;
        let syn::ReturnType::Type(_, output) = &sig.output else {
            return Err("missing record result".into());
        };
        let named = base_type(output)?;
        if tokens(output) != named || def.impl_generics.type_params().any(|p| p.ident == named) {
            return Err("record selector output requires an unshadowed concrete record".into());
        }
        let record_type = self.resolve(&def.module, &named, 0)?;
        let record = self
            .structs
            .get(&record_type)
            .ok_or("selector output must be a source record")?;
        if !record.generics.params.is_empty()
            || self.drops.contains(&record_type)
            || !record.attrs.iter().any(|a| {
                a.path().is_ident("derive")
                    && a.parse_args_with(
                        syn::punctuated::Punctuated::<syn::Ident, syn::Token![,]>::parse_terminated,
                    )
                    .is_ok_and(|d| d.iter().any(|n| n == "Copy"))
            })
        {
            return Err("selector result requires a nongeneric builtin Copy record".into());
        }
        let [syn::Stmt::Expr(Expr::MethodCall(select), None)] = f.block.stmts.as_slice() else {
            return Err("record selector must retain its entire map_or expression".into());
        };
        attrs(&select.attrs)?;
        if select.method != "map_or" || select.args.len() != 2 || select.turbofish.is_some() {
            return Err("record selector requires builtin Option::map_or".into());
        }
        let Expr::MethodCall(borrow) = &*select.receiver else {
            return Err("record selection requires an Option borrow".into());
        };
        attrs(&borrow.attrs)?;
        if borrow.method != "as_ref" || !borrow.args.is_empty() || borrow.turbofish.is_some() {
            return Err("record selector must use builtin Option::as_ref".into());
        }
        let optional = path(&borrow.receiver)?;
        if optional.len() != 1 {
            return Err("record selector currently requires a direct Option field".into());
        }
        let Type::Path(option) = self.field_type(def, &optional)? else {
            return Err("selector field must be builtin Option".into());
        };
        if option.qself.is_some()
            || option.path.segments.len() != 1
            || option.path.segments[0].ident != "Option"
        {
            return Err("selector field must be builtin Option".into());
        }
        let syn::PathArguments::AngleBracketed(arguments) = &option.path.segments[0].arguments
        else {
            return Err("Option payload unresolved".into());
        };
        let args = arguments.args.iter().collect::<Vec<_>>();
        let [syn::GenericArgument::Type(payload)] = args.as_slice() else {
            return Err("Option requires one concrete payload type".into());
        };
        let payload_name = base_type(payload)?;
        let receiver = self
            .structs
            .get(&def.receiver)
            .ok_or("unresolved receiver")?;
        if receiver
            .generics
            .type_params()
            .any(|p| p.ident == payload_name)
        {
            return Err("generic Option payload requires type substitution".into());
        }
        let payload_name = self.resolve(&self.struct_modules[&def.receiver], &payload_name, 0)?;
        let payload = self
            .structs
            .get(&payload_name)
            .ok_or("Option payload must be a source record")?;
        let Expr::Closure(callback) = &select.args[1] else {
            return Err("record selection requires an explicit field projection".into());
        };
        attrs(&callback.attrs)?;
        if callback.asyncness.is_some()
            || callback.constness.is_some()
            || callback.movability.is_some()
            || callback.capture.is_some()
            || callback.lifetimes.is_some()
            || !matches!(callback.output, syn::ReturnType::Default)
            || callback.inputs.len() != 1
        {
            return Err("record projection callback must be plain".into());
        }
        let syn::Pat::Ident(binding) = &callback.inputs[0] else {
            return Err("record projection needs a plain binding".into());
        };
        attrs(&binding.attrs)?;
        if binding.by_ref.is_some() || binding.subpat.is_some() || binding.mutability.is_some() {
            return Err("record projection needs a plain binding".into());
        }
        let Expr::Field(field) = &*callback.body else {
            return Err("record projection must return exactly one field".into());
        };
        attrs(&field.attrs)?;
        if !matches!(&*field.base,Expr::Path(p) if p.attrs.is_empty() && p.qself.is_none() && p.path.is_ident(&binding.ident.to_string()))
        {
            return Err("record projection must read its closure parameter".into());
        }
        let syn::Member::Named(member) = &field.member else {
            return Err("record projection requires a named field".into());
        };
        let declaration = payload
            .fields
            .iter()
            .find(|f| f.ident.as_ref() == Some(member))
            .ok_or("unknown projected record field")?;
        attrs(&declaration.attrs)?;
        let leaf = base_type(&declaration.ty)?;
        if payload.generics.type_params().any(|p| p.ident == leaf)
            || tokens(&declaration.ty) != leaf
            || self.resolve(&self.struct_modules[&payload_name], &leaf, 0)? != record_type
        {
            return Err("record projection type must resolve to its concrete output".into());
        }
        let mut fallback = vec![];
        self.initial(
            &def.module,
            output,
            &select.args[0],
            vec![],
            &BTreeMap::new(),
            &mut fallback,
        )?;
        Ok(Method{name:name.into(),symbol:name.replace("::","_"),source:def.file.clone(),first_line:f.span().start().line,last_line:f.span().end().line,rust:tokens(f),writes:vec![],body:vec![],array:None,query:None,constructor:None,buffer:None,relocation:None,record_at:None,lookup:None,selection:Some(Selection{optional,record_field:member.to_string(),record_type,fallback,scope:"complete shared Option record selection with checked eager derived Default; Rust field/type/borrow and frontend correspondence remain unproved"})})
    }
}
pub(super) fn program(s: &Selection) -> String {
    let fields = s
        .fallback
        .iter()
        .map(|f| {
            format!(
                "⟨{}, {}⟩",
                lean_path(&f.path),
                constructors::initial(&f.value)
            )
        })
        .collect::<Vec<_>>()
        .join(", ");
    format!(
        "⟨{}, {}, [{fields}]⟩",
        lean_path(&s.optional),
        lean_path(std::slice::from_ref(&s.record_field))
    )
}
pub(super) fn generate(method: &Method) -> String {
    let s = method.selection.as_ref().unwrap();
    let name = &method.symbol;
    format!("def {name}_ir : RecordSelection := {}\ndef {name} (state : SelectionStore) : InitStore :=\n  selectRecord {name}_ir state\ntheorem {name}_correspondence (state : SelectionStore) :\n  selectRecord {name}_ir state = {name} state := by rfl\n",program(s))
}
