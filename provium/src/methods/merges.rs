//! Guarded by-value array merges with source projection and mapped insertion
//! errors. All local callees are checked, including both original guards.
use super::arrays::{binding, copy_derived, named};
use super::lookups::method;
use super::slot_batches::{binary, error_return, output_error, tag};
use super::*;

#[derive(Debug, Serialize)]
pub struct Merge {
    pub source_guard: Box<Method>,
    pub target_guard: Box<Method>,
    pub projection: Box<Method>,
    pub insert: Box<Method>,
    pub tag: u8,
    pub guard_error: String,
    pub insert_error: String,
    pub target: String,
}
pub(super) fn candidate(item: &syn::ImplItemFn) -> bool {
    output_error(&item.sig.output).is_ok()
        && matches!(item.sig.inputs.first(), Some(syn::FnArg::Receiver(r)) if r.reference.is_none())
        && item
            .block
            .stmts
            .iter()
            .any(|s| matches!(s, syn::Stmt::Expr(Expr::ForLoop(_), _)))
}
impl Crate {
    fn merge_error(
        &self,
        def: &Definition,
        error_type: &str,
        expr: &Expr,
    ) -> Result<String, String> {
        let Expr::Path(p) = expr else {
            return Err("merge error must be a unit enum variant".into());
        };
        attrs(&p.attrs)?;
        if p.qself.is_some()
            || p.path.leading_colon.is_some()
            || p.path.segments.len() != 2
            || p.path
                .segments
                .iter()
                .any(|s| !matches!(s.arguments, syn::PathArguments::None))
        {
            return Err("merge error must resolve to a unit enum variant".into());
        }
        if self.resolve(&def.module, &p.path.segments[0].ident.to_string(), 0)? != error_type {
            return Err("merge error type mismatch".into());
        }
        let name = p.path.segments[1].ident.to_string();
        let variant = self
            .enums
            .get(error_type)
            .and_then(|e| e.variants.iter().find(|v| v.ident == name))
            .ok_or("unknown merge error")?;
        attrs(&variant.attrs)?;
        if !matches!(variant.fields, syn::Fields::Unit) {
            return Err("merge error must have no payload".into());
        }
        Ok(name)
    }
    pub(super) fn lower_merge(&self, name: &str) -> Result<Method, String> {
        let def = self.methods.get(name).ok_or("unknown merge method")?;
        let f = &def.item;
        let sig = &f.sig;
        attrs(&f.attrs)?;
        self.iterator_traits()?;
        self.constructor_namespaces(def)?;
        if sig.asyncness.is_some()
            || sig.constness.is_some()
            || sig.unsafety.is_some()
            || sig.abi.is_some()
            || !sig.generics.params.is_empty()
            || sig.generics.where_clause.is_some()
            || def.impl_generics.type_params().next().is_some()
            || def.impl_generics.lifetimes().next().is_some()
        {
            return Err("merge requires concrete by-value inputs".into());
        }
        let args: Vec<_> = sig.inputs.iter().collect();
        let [syn::FnArg::Receiver(receiver), syn::FnArg::Typed(target)] = args.as_slice() else {
            return Err("merge requires self and one mutable target value".into());
        };
        attrs(&receiver.attrs)?;
        attrs(&target.attrs)?;
        if receiver.reference.is_some()
            || receiver.mutability.is_some()
            || receiver.colon_token.is_some()
        {
            return Err("merge requires plain by-value self".into());
        }
        if !matches!(&*target.ty,Type::Path(p) if p.qself.is_none() && p.path.is_ident("Self")) {
            return Err("merge target must have type Self".into());
        }
        let syn::Pat::Ident(target_binding) = &*target.pat else {
            return Err("merge target must be a mutable identifier".into());
        };
        attrs(&target_binding.attrs)?;
        if target_binding.by_ref.is_some()
            || target_binding.mutability.is_none()
            || target_binding.subpat.is_some()
        {
            return Err("merge target requires a plain mutable binding".into());
        }
        let target = target_binding.ident.to_string();
        let receiver_record = self
            .structs
            .get(&def.receiver)
            .ok_or("merge receiver must be a struct")?;
        if receiver_record.fields.len() != 1
            || !copy_derived(receiver_record)
            || self.drops.contains(&def.receiver)
        {
            return Err("merge receiver must be a one-array Copy record".into());
        }
        let error_type = self.resolve(&def.module, &output_error(&sig.output)?, 0)?;
        if self.drops.contains(&error_type) {
            return Err("mapped merge errors require explicit Drop semantics".into());
        }
        let [syn::Stmt::Expr(Expr::If(guard), _), syn::Stmt::Expr(Expr::ForLoop(pass), _), syn::Stmt::Expr(Expr::Call(ret), None)] =
            f.block.stmts.as_slice()
        else {
            return Err("merge must retain its guards, whole insertion loop and return".into());
        };
        let (source_test, target_test) = binary(&guard.cond, "||")?;
        let helper_name = |method: &syn::Ident| {
            format!("{}::{}::{}", def.module, def.receiver, method)
                .trim_start_matches("::")
                .to_string()
        };
        let guard_method = |expr: &Expr, receiver: &str| -> Result<Method, String> {
            let Expr::MethodCall(call) = expr else {
                return Err("merge guard needs a source-local query".into());
            };
            let call = method(expr, &call.method.to_string(), 0)?;
            if !named(&call.receiver, receiver) {
                return Err("merge guard must query its declared input".into());
            }
            let lowered = self.lower_array_query(&helper_name(&call.method))?;
            let shape = lowered
                .array
                .as_ref()
                .ok_or("merge guard requires a pure array query")?;
            if shape.key.is_some() || shape.predicate.is_none() {
                return Err("merge guard must be a receiver-only boolean query".into());
            }
            Ok(lowered)
        };
        let source_guard = guard_method(source_test, "self")?;
        let target_guard = guard_method(target_test, &target)?;
        let guard_error = self.merge_error(def, &error_type, error_return(guard)?)?;
        attrs(&pass.attrs)?;
        if pass.label.is_some() {
            return Err("merge labeled loop unsupported".into());
        }
        let key = binding(&pass.pat)?;
        if key == target {
            return Err("merge projected key shadows its target".into());
        }
        let Expr::MethodCall(project) = &*pass.expr else {
            return Err("merge must iterate a source projection".into());
        };
        let project = method(&pass.expr, &project.method.to_string(), 0)?;
        if !named(&project.receiver, "self") {
            return Err("merge projection must read its original source".into());
        }
        let projection = self.lower_projection(&helper_name(&project.method))?;
        let projection_shape = projection
            .array
            .as_ref()
            .ok_or("missing merge projection shape")?;
        if projection_shape.preserve_slots {
            return Err("merge projection must yield copied keys".into());
        }
        let [syn::Stmt::Expr(Expr::Try(attempt), Some(_))] = pass.body.stmts.as_slice() else {
            return Err("merge loop must propagate exactly its mapped insertion call".into());
        };
        attrs(&attempt.attrs)?;
        let mapped = method(&attempt.expr, "map_err", 1)?;
        let Expr::Closure(mapper) = &mapped.args[0] else {
            return Err("merge error mapper must be explicit".into());
        };
        attrs(&mapper.attrs)?;
        if mapper.asyncness.is_some()
            || mapper.constness.is_some()
            || mapper.movability.is_some()
            || mapper.capture.is_some()
            || mapper.lifetimes.is_some()
            || !matches!(mapper.output, syn::ReturnType::Default)
            || mapper.inputs.len() != 1
            || !matches!(&mapper.inputs[0],syn::Pat::Wild(w) if w.attrs.is_empty())
        {
            return Err(
                "merge error mapper must discard one error without effects or capture".into(),
            );
        }
        let insert_error = self.merge_error(def, &error_type, &mapper.body)?;
        let Expr::MethodCall(call) = &*mapped.receiver else {
            return Err("merge must map a local insertion error".into());
        };
        let call = method(&mapped.receiver, &call.method.to_string(), 2)?;
        if !named(&call.receiver, &target) || !named(&call.args[0], &key) {
            return Err("merge must insert each source key into its target".into());
        }
        let tag = tag(&call.args[1])?;
        let insert_name = helper_name(&call.method);
        let insert_def = self
            .methods
            .get(&insert_name)
            .ok_or("unresolved merge insertion")?;
        if self.resolve(
            &insert_def.module,
            &queries::result_error(&insert_def.item.sig.output)?,
            0,
        )? != error_type
        {
            return Err("merge insertion error type mismatch".into());
        }
        let Some(syn::FnArg::Typed(insert_key)) = insert_def.item.sig.inputs.iter().nth(1) else {
            return Err("merge insertion must take a key".into());
        };
        let key_type = self.equality_value(&insert_def.module, &insert_key.ty)?;
        let insert = self.lower_upsert(&insert_name)?;
        let shape = insert
            .array
            .as_ref()
            .ok_or("missing merge insertion shape")?;
        for helper in [&source_guard, &target_guard, &projection] {
            let other = helper.array.as_ref().ok_or("missing merge helper array")?;
            if other.field != shape.field
                || other.capacity != shape.capacity
                || other.record != shape.record
            {
                return Err("merge helpers must operate on the same array representation".into());
            }
        }
        let record_def = Definition {
            module: self.struct_modules[&shape.record].clone(),
            file: def.file.clone(),
            item: f.clone(),
            receiver: shape.record.clone(),
            impl_generics: syn::Generics::default(),
            self_type: None,
        };
        if self.equality_value(
            &record_def.module,
            self.field_type(
                &record_def,
                projection_shape
                    .projection
                    .as_ref()
                    .ok_or("missing merge projected field")?,
            )?,
        )? != key_type
        {
            return Err("merge projection and insertion key types disagree".into());
        }
        attrs(&ret.attrs)?;
        if !named(&ret.func, "Ok") || ret.args.len() != 1 || !named(&ret.args[0], &target) {
            return Err("merge must return its completed target".into());
        }
        let field = shape.field.clone();
        let capacity = shape.capacity.clone();
        let record = shape.record.clone();
        let merge = Merge {
            source_guard: Box::new(source_guard),
            target_guard: Box::new(target_guard),
            projection: Box::new(projection),
            insert: Box::new(insert),
            tag,
            guard_error,
            insert_error,
            target,
        };
        Ok(Method {name:name.into(),symbol:name.replace("::","_"),source:def.file.clone(),first_line:f.span().start().line,last_line:f.span().end().line,rust:tokens(f),writes:vec![],body:vec![],iteration:None,last:None,truncation:None,installation:None,restoration:None,getter: None, enum_projection:None,validator:None,view:None,record_at:None,lookup:None,selection:None,relocation:None,buffer:None,constructor:None,query:None,array:Some(arrays::Shape{field,capacity,record,predicate:None,projection:None,preserve_slots:false,key:None,upsert:None,batch:None,rebuild:None,merge:Some(Box::new(merge)),fold:None,numeric:None,scope:"complete guarded Copy-array merge with source projection and mapped insertion errors; Rust source/ownership refinement remains open"})})
    }
}
pub(super) fn generate(name: &str, merge: &Merge) -> String {
    let mut output = String::new();
    for (suffix, helper) in [
        ("source_guard", &merge.source_guard),
        ("target_guard", &merge.target_guard),
        ("projection", &merge.projection),
        ("insert", &merge.insert),
    ] {
        output.push_str(
            &arrays::generate(helper).replace(&helper.symbol, &format!("{name}_{suffix}")),
        );
    }
    let guard_error = serde_json::to_string(&merge.guard_error).unwrap();
    let insert_error = serde_json::to_string(&merge.insert_error).unwrap();
    output.push_str(&format!("def {name}_ir : ArrayMerge := ⟨{name}_source_guard_ir, {name}_target_guard_ir, {name}_projection_ir, {name}_insert_ir, {}, {guard_error}, {insert_error}⟩\ndef {name} [DecidableEq α] (source target : ArrayStore α) : Except String (ArrayStore α) := runArrayMerge {name}_ir source target\ntheorem {name}_correspondence [DecidableEq α] (source target : ArrayStore α) : runArrayMerge {name}_ir source target = {name} source target := by rfl\n",merge.tag));
    output
}
