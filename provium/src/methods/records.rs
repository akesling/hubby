//! Whole optional-record lookup with a source-checked boundary case and a
//! source-checked borrowed-entry projection. Both helpers are lowered in full.
use super::lookups::{ident, method, named};
use super::*;
#[derive(Debug, Serialize)]
pub struct At {
    pub lookup: lookups::Lookup,
    pub lookup_method: String,
    pub lookup_rust: String,
    pub equal: bool,
    pub guard_field: String,
    pub record_field: String,
    pub scope: &'static str,
}
pub(super) fn output_record(output: &syn::ReturnType) -> Result<String, String> {
    let syn::ReturnType::Type(_, ty) = output else {
        return Err("expected optional record".into());
    };
    let Type::Path(p) = &**ty else {
        return Err("expected optional record".into());
    };
    if p.qself.is_some()
        || p.path.leading_colon.is_some()
        || p.path.segments.len() != 1
        || p.path.segments[0].ident != "Option"
    {
        return Err("expected builtin Option record".into());
    }
    let syn::PathArguments::AngleBracketed(args) = &p.path.segments[0].arguments else {
        return Err("missing Option type argument".into());
    };
    let args = args.args.iter().collect::<Vec<_>>();
    let [syn::GenericArgument::Type(Type::Path(record))] = args.as_slice() else {
        return Err("expected Option<ConcreteRecord>".into());
    };
    if record.qself.is_some()
        || record.path.leading_colon.is_some()
        || record.path.segments.len() != 1
        || !matches!(record.path.segments[0].arguments, syn::PathArguments::None)
    {
        return Err("expected an unqualified concrete record".into());
    }
    Ok(record.path.segments[0].ident.to_string())
}
fn tail(block: &syn::Block) -> Result<&Expr, String> {
    match block.stmts.as_slice() {
        [syn::Stmt::Expr(e, None)] => Ok(e),
        _ => Err("record lookup must retain every branch statement".into()),
    }
}
fn receiver_call(c: &syn::ExprMethodCall, def: &Definition) -> Result<String, String> {
    attrs(&c.attrs)?;
    if !path(&c.receiver)?.is_empty() || c.turbofish.is_some() {
        return Err("record lookup requires receiver-local helpers".into());
    }
    Ok(format!("{}::{}::{}", def.module, def.receiver, c.method)
        .trim_start_matches("::")
        .to_owned())
}
impl Crate {
    pub(super) fn lower_record_at(&self, name: &str) -> Result<Method, String> {
        let def = self.methods.get(name).ok_or("unknown record lookup")?;
        let f = &def.item;
        let sig = &f.sig;
        attrs(&f.attrs)?;
        if sig.asyncness.is_some()
            || sig.constness.is_some()
            || sig.unsafety.is_some()
            || sig.abi.is_some()
            || !sig.generics.params.is_empty()
            || sig.generics.where_clause.is_some()
        {
            return Err("record lookup requires a plain shared method".into());
        }
        let inputs = sig.inputs.iter().collect::<Vec<_>>();
        let [syn::FnArg::Receiver(r), syn::FnArg::Typed(input)] = inputs.as_slice() else {
            return Err("record lookup needs &self and one u64 index".into());
        };
        attrs(&r.attrs)?;
        attrs(&input.attrs)?;
        if r.reference.is_none()
            || r.mutability.is_some()
            || r.colon_token.is_some()
            || tokens(&input.ty) != "u64"
        {
            return Err("record lookup needs &self and one u64 index".into());
        }
        let input_name = ident(&input.pat)?;
        let output = output_record(&sig.output)?;
        if def.impl_generics.type_params().any(|p| p.ident == output) {
            return Err("record lookup output is shadowed by a generic parameter".into());
        }
        let output = self.resolve(&def.module, &output, 0)?;
        let Expr::If(branch) = tail(&f.block)? else {
            return Err("record lookup must retain its complete boundary branch".into());
        };
        attrs(&branch.attrs)?;
        let Expr::Binary(compare) = &*branch.cond else {
            return Err("record lookup requires an explicit index comparison".into());
        };
        attrs(&compare.attrs)?;
        if !named(&compare.left, &input_name) {
            return Err("record boundary must compare its input index".into());
        }
        let equal = match compare.op {
            syn::BinOp::Eq(_) => true,
            syn::BinOp::Ne(_) => false,
            _ => return Err("unsupported record boundary comparison".into()),
        };
        let Expr::Field(base_field) = &*compare.right else {
            return Err("record boundary must use a source-resolved base field".into());
        };
        attrs(&base_field.attrs)?;
        let syn::Member::Named(base_member) = &base_field.member else {
            return Err("record boundary needs a named base field".into());
        };
        let Expr::MethodCall(base_call) = &*base_field.base else {
            return Err("record boundary must invoke its base helper".into());
        };
        let base_name = receiver_call(base_call, def)?;
        if !base_call.args.is_empty() {
            return Err("record base helper must be receiver-only".into());
        }
        let Expr::Call(some) = tail(&branch.then_branch)? else {
            return Err("record boundary must return Some(base())".into());
        };
        attrs(&some.attrs)?;
        if some.args.len() != 1 || !named(&some.func, "Some") {
            return Err("record boundary requires builtin Some".into());
        }
        let Expr::MethodCall(yes) = &some.args[0] else {
            return Err("record boundary must return its base helper".into());
        };
        if !yes.args.is_empty() || receiver_call(yes, def)? != base_name {
            return Err("record boundary must return the same base helper".into());
        }
        let Some((_, otherwise)) = &branch.else_branch else {
            return Err("record lookup needs its non-boundary branch".into());
        };
        let Expr::Block(otherwise) = &**otherwise else {
            return Err("record lookup else must be a full block".into());
        };
        attrs(&otherwise.attrs)?;
        if otherwise.label.is_some() {
            return Err("labelled record lookup unsupported".into());
        }
        let map = method(tail(&otherwise.block)?, "map", 1)?;
        let Expr::MethodCall(get) = &*map.receiver else {
            return Err("record lookup must invoke the original borrowed lookup".into());
        };
        let lookup_method = receiver_call(get, def)?;
        if get.args.len() != 1 || !named(&get.args[0], &input_name) {
            return Err("record lookup must pass its original index".into());
        }
        let lowered = self.lower_lookup(&lookup_method)?;
        let lookup_rust = lowered.rust;
        let lookup = lowered.lookup.ok_or("missing checked lookup")?;
        if lookup.base_method != base_name || lookup.base.record_type != output {
            return Err("record lookup must compose matching base and lookup records".into());
        }
        let base_record = self
            .structs
            .get(&output)
            .ok_or("unresolved boundary record")?;
        let guard_field = base_record
            .fields
            .iter()
            .find(|f| f.ident.as_ref() == Some(base_member))
            .ok_or("unknown record boundary field")?;
        attrs(&guard_field.attrs)?;
        if tokens(&guard_field.ty) != "u64" {
            return Err("record boundary field must be builtin u64".into());
        }
        let Expr::Closure(callback) = &map.args[0] else {
            return Err("record lookup map requires explicit entry projection".into());
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
            return Err("record lookup projection must be a plain closure".into());
        }
        let binding = ident(&callback.inputs[0])?;
        let Expr::Field(field) = &*callback.body else {
            return Err("record lookup projection must read exactly one field".into());
        };
        attrs(&field.attrs)?;
        if !named(&field.base, &binding) {
            return Err("record lookup projection must read its entry parameter".into());
        }
        let syn::Member::Named(member) = &field.member else {
            return Err("record lookup projection needs a named field".into());
        };
        let Type::Array(array) = self.field_type(def, &lookup.slots)? else {
            return Err("unresolved entry array".into());
        };
        let Type::Path(option) = &*array.elem else {
            return Err("unresolved optional entry".into());
        };
        let syn::PathArguments::AngleBracketed(args) = &option.path.segments[0].arguments else {
            return Err("unresolved entry argument".into());
        };
        let Some(syn::GenericArgument::Type(entry_type)) = args.args.first() else {
            return Err("unresolved entry type".into());
        };
        let entry_name = base_type(entry_type)?;
        let receiver = self
            .structs
            .get(&def.receiver)
            .ok_or("unresolved record lookup receiver")?;
        if receiver
            .generics
            .type_params()
            .any(|p| p.ident == entry_name)
        {
            return Err("generic entry field access needs substitution".into());
        }
        let entry_name = self.resolve(&self.struct_modules[&def.receiver], &entry_name, 0)?;
        let entry = self
            .structs
            .get(&entry_name)
            .ok_or("entry must be a source-resolved record")?;
        let field = entry
            .fields
            .iter()
            .find(|f| f.ident.as_ref() == Some(member))
            .ok_or("unknown entry record field")?;
        attrs(&field.attrs)?;
        let leaf = base_type(&field.ty)?;
        if tokens(&field.ty) != leaf
            || entry.generics.type_params().any(|p| p.ident == leaf)
            || self.resolve(&self.struct_modules[&entry_name], &leaf, 0)? != output
        {
            return Err("entry projection must resolve to the output record type".into());
        }
        Ok(Method{name:name.into(),symbol:name.replace("::","_"),source:def.file.clone(),first_line:f.span().start().line,last_line:f.span().end().line,rust:tokens(f),writes:vec![],body:vec![],array:None,query:None,constructor:None,buffer:None,relocation:None,selection:None,lookup:None,iteration:None,last:None,truncation:None,installation:None,restoration:None,record_at:Some(At{lookup,lookup_method,lookup_rust,equal,guard_field:base_member.to_string(),record_field:member.to_string(),scope:"complete optional record lookup composed with both complete source helpers; copied base/entry records and source paths retained; source/layout/borrow correspondence remains unproved"})})
    }
}
pub(super) fn generate(method: &Method) -> String {
    let a = method.record_at.as_ref().unwrap();
    let name = &method.symbol;
    format!("def {name}_ir : RecordAt := ⟨{}, {}, {}, {}⟩\ndef {name} (bits : Nat) (state : LookupStore (Path → InitStore)) (index : Nat) : Except LookupFault (Option InitStore) :=\n  recordAt {name}_ir bits state index\ntheorem {name}_correspondence (bits : Nat) (state : LookupStore (Path → InitStore)) (index : Nat) :\n  recordAt {name}_ir bits state index = {name} bits state index := by rfl\n",lookups::program(&a.lookup),lean_path(std::slice::from_ref(&a.guard_field)),a.equal,lean_path(std::slice::from_ref(&a.record_field)))
}
