//! Rebuild an optional-record array from a pure source projection and checked
//! input slice. Both loops and all three source-local callees remain explicit.
use super::arrays::{binding, copy_derived, named};
use super::lookups::method;
use super::slot_batches::{binary, error_return, output_error, tag, tuple_binding};
use super::*;

#[derive(Debug, Serialize)]
pub struct Rebuild {
    pub projection: Box<Method>,
    pub exclusion: Box<Method>,
    pub insert: Box<Method>,
    pub first_tag: u8,
    pub input_tag: u8,
    pub input: String,
    pub error: String,
    pub capacity: constructors::Capacity,
}

pub(super) fn candidate(item: &syn::ImplItemFn) -> bool {
    matches!(item.sig.inputs.first(), Some(syn::FnArg::Receiver(_)))
        && output_error(&item.sig.output).is_ok()
        && item
            .block
            .stmts
            .iter()
            .filter(|s| matches!(s, syn::Stmt::Expr(Expr::ForLoop(_), _)))
            .count()
            == 2
}

fn copied(expr: &Expr, key: &str) -> Result<(), String> {
    let Expr::Unary(deref) = expr else {
        return Err("rebuild must copy its slice key".into());
    };
    attrs(&deref.attrs)?;
    if !matches!(deref.op, syn::UnOp::Deref(_)) || !named(&deref.expr, key) {
        return Err("rebuild must dereference its current slice key".into());
    }
    Ok(())
}
fn insertion<'a>(
    stmt: &'a syn::Stmt,
    output: &str,
    key: &str,
    dereference: bool,
) -> Result<(&'a syn::ExprMethodCall, u8), String> {
    let syn::Stmt::Expr(Expr::Try(attempt), Some(_)) = stmt else {
        return Err("rebuild must propagate its insertion error".into());
    };
    attrs(&attempt.attrs)?;
    let Expr::MethodCall(call) = &*attempt.expr else {
        return Err("rebuild needs a local insertion method".into());
    };
    attrs(&call.attrs)?;
    if !named(&call.receiver, output) || call.turbofish.is_some() || call.args.len() != 2 {
        return Err("rebuild insertion must update its output".into());
    }
    if dereference {
        copied(&call.args[0], key)?;
    } else if !named(&call.args[0], key) {
        return Err("rebuild insertion must use its projected key".into());
    }
    Ok((call, tag(&call.args[1])?))
}

impl Crate {
    pub(super) fn lower_rebuild(&self, name: &str) -> Result<Method, String> {
        let def = self.methods.get(name).ok_or("unknown rebuild method")?;
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
            return Err("rebuild requires concrete shared source and slice inputs".into());
        }
        let args: Vec<_> = sig.inputs.iter().collect();
        let [syn::FnArg::Receiver(receiver), syn::FnArg::Typed(input)] = args.as_slice() else {
            return Err("rebuild requires one receiver and one slice".into());
        };
        attrs(&receiver.attrs)?;
        attrs(&input.attrs)?;
        if receiver.reference.is_none()
            || receiver.mutability.is_some()
            || receiver.colon_token.is_some()
        {
            return Err("rebuild requires &self".into());
        }
        let input_name = binding(&input.pat)?;
        let Type::Reference(reference) = &*input.ty else {
            return Err("rebuild input must be a shared slice".into());
        };
        let Type::Slice(slice) = &*reference.elem else {
            return Err("rebuild input must be a slice".into());
        };
        if reference.mutability.is_some() {
            return Err("rebuild input must be shared".into());
        }
        let key_type = self.equality_value(&def.module, &slice.elem)?;
        let error_type = self.resolve(&def.module, &output_error(&sig.output)?, 0)?;
        if self.drops.contains(&error_type) {
            return Err("rebuild error Drop requires explicit semantics".into());
        }
        let record = self
            .structs
            .get(&def.receiver)
            .ok_or("rebuild receiver must be a record")?;
        if record.fields.len() != 1 || !copy_derived(record) || self.drops.contains(&def.receiver) {
            return Err("rebuild receiver must be a one-array Copy record".into());
        }
        let [syn::Stmt::Local(initial), syn::Stmt::Expr(Expr::ForLoop(first), _), syn::Stmt::Expr(Expr::ForLoop(second), _), syn::Stmt::Expr(Expr::Call(ret), None)] =
            f.block.stmts.as_slice()
        else {
            return Err("rebuild must retain initialization, both loops and its return".into());
        };
        attrs(&initial.attrs)?;
        let syn::Pat::Ident(local) = &initial.pat else {
            return Err("rebuild output needs a mutable binding".into());
        };
        attrs(&local.attrs)?;
        if local.by_ref.is_some() || local.mutability.is_none() || local.subpat.is_some() {
            return Err("rebuild output needs a plain mutable binding".into());
        }
        let output = local.ident.to_string();
        let init = initial
            .init
            .as_ref()
            .ok_or("missing rebuild initialization")?;
        if init.diverge.is_some() {
            return Err("rebuild let-else unsupported".into());
        }
        let Expr::Struct(value) = &*init.expr else {
            return Err("rebuild must initialize Self explicitly".into());
        };
        attrs(&value.attrs)?;
        if value.qself.is_some()
            || !value.path.is_ident("Self")
            || value.rest.is_some()
            || value.fields.len() != 1
        {
            return Err("rebuild must initialize its complete record".into());
        }
        let field = &value.fields[0];
        attrs(&field.attrs)?;
        let syn::Member::Named(field_name) = &field.member else {
            return Err("rebuild needs a named field".into());
        };
        let field_name = field_name.to_string();
        let Type::Array(array) = self.field_type(def, std::slice::from_ref(&field_name))? else {
            return Err("rebuild field must be an array".into());
        };
        let Expr::Repeat(repeat) = &field.expr else {
            return Err("rebuild needs an empty repeat initializer".into());
        };
        attrs(&repeat.attrs)?;
        if !named(&repeat.expr, "None") || tokens(&repeat.len) != tokens(&array.len) {
            return Err("rebuild must initialize all slots to None".into());
        }
        let capacity = match &*repeat.len {
            Expr::Path(p) if p.qself.is_none() && p.path.get_ident().is_some() => {
                attrs(&p.attrs)?;
                let n = p.path.get_ident().unwrap().to_string();
                if !def
                    .impl_generics
                    .const_params()
                    .any(|p| p.ident == n && tokens(&p.ty) == "usize")
                {
                    return Err("rebuild capacity must be a usize const parameter".into());
                }
                constructors::Capacity::Parameter(n)
            }
            Expr::Lit(l) => {
                attrs(&l.attrs)?;
                let syn::Lit::Int(n) = &l.lit else {
                    return Err("rebuild capacity must be an integer".into());
                };
                if !n.suffix().is_empty() && n.suffix() != "usize" {
                    return Err("rebuild capacity must be usize".into());
                }
                constructors::Capacity::Fixed(n.base10_parse().map_err(|e| e.to_string())?)
            }
            _ => return Err("rebuild capacity expression unsupported".into()),
        };
        attrs(&first.attrs)?;
        attrs(&second.attrs)?;
        if first.label.is_some() || second.label.is_some() {
            return Err("rebuild labeled loops unsupported".into());
        }
        let first_key = binding(&first.pat)?;
        let (index, key) = tuple_binding(&second.pat)?;
        if input_name == output
            || [&first_key, &index, &key]
                .iter()
                .any(|name| *name == &input_name || *name == &output)
        {
            return Err("rebuild loop bindings shadow an input or the output".into());
        }
        let Expr::MethodCall(projection_call) = &*first.expr else {
            return Err("rebuild first loop must use a source projection".into());
        };
        let projection_call = method(&first.expr, &projection_call.method.to_string(), 0)?;
        if !named(&projection_call.receiver, "self") {
            return Err("rebuild projection must borrow the original receiver".into());
        }
        let helper_name = |method: &syn::Ident| {
            format!("{}::{}::{}", def.module, def.receiver, method)
                .trim_start_matches("::")
                .to_string()
        };
        let projection = self.lower_projection(&helper_name(&projection_call.method))?;
        let projection_shape = projection.array.as_ref().ok_or("missing projection IR")?;
        if projection_shape.preserve_slots || projection_shape.field != field_name {
            return Err("rebuild must iterate its source array values".into());
        }
        let [first_insert] = first.body.stmts.as_slice() else {
            return Err("rebuild first loop must contain only insertion".into());
        };
        let (first_insert, first_tag) = insertion(first_insert, &output, &first_key, false)?;
        let enumeration = method(&second.expr, "enumerate", 0)?;
        let iter = method(&enumeration.receiver, "iter", 0)?;
        if !named(&iter.receiver, &input_name) {
            return Err("rebuild must enumerate its input slice".into());
        }
        let [syn::Stmt::Expr(Expr::If(validation), _), second_insert] =
            second.body.stmts.as_slice()
        else {
            return Err("rebuild second loop must validate then insert".into());
        };
        let (excluded, duplicate) = binary(&validation.cond, "||")?;
        let Expr::MethodCall(excluded_call) = excluded else {
            return Err("rebuild validation needs a source identity query".into());
        };
        let excluded_call = method(excluded, &excluded_call.method.to_string(), 1)?;
        if !named(&excluded_call.receiver, "self") {
            return Err("rebuild exclusion must query its original receiver".into());
        }
        copied(&excluded_call.args[0], &key)?;
        let exclusion = self.lower_array_query(&helper_name(&excluded_call.method))?;
        let exclusion_shape = exclusion.array.as_ref().ok_or("missing exclusion IR")?;
        let equality = exclusion_shape
            .key
            .as_ref()
            .ok_or("rebuild exclusion requires a pure key query")?;
        if exclusion_shape.field != field_name || equality.value_type != key_type {
            return Err("rebuild exclusion must use the same array and key type".into());
        }
        let duplicate = method(duplicate, "contains", 1)?;
        if !named(&duplicate.args[0], &key) {
            return Err("rebuild duplicate test must use its current key".into());
        }
        let Expr::Index(prefix) = &*duplicate.receiver else {
            return Err("rebuild duplicate check needs its prior prefix".into());
        };
        attrs(&prefix.attrs)?;
        let Expr::Range(range) = &*prefix.index else {
            return Err("rebuild duplicate check needs a range".into());
        };
        attrs(&range.attrs)?;
        if !named(&prefix.expr, &input_name)
            || range.start.is_some()
            || !matches!(range.limits, syn::RangeLimits::HalfOpen(_))
            || !range.end.as_deref().is_some_and(|e| named(e, &index))
        {
            return Err("rebuild duplicate prefix must end before its current index".into());
        }
        let error_expr = error_return(validation)?;
        let Expr::Path(error_path) = error_expr else {
            return Err("rebuild error must be a unit variant".into());
        };
        attrs(&error_path.attrs)?;
        if error_path.qself.is_some()
            || error_path.path.leading_colon.is_some()
            || error_path.path.segments.len() != 2
            || error_path
                .path
                .segments
                .iter()
                .any(|p| !matches!(p.arguments, syn::PathArguments::None))
        {
            return Err("rebuild error must resolve to a unit enum variant".into());
        }
        if self.resolve(
            &def.module,
            &error_path.path.segments[0].ident.to_string(),
            0,
        )? != error_type
        {
            return Err("rebuild error type mismatch".into());
        }
        let error = error_path.path.segments[1].ident.to_string();
        let variant = self
            .enums
            .get(&error_type)
            .and_then(|e| e.variants.iter().find(|v| v.ident == error))
            .ok_or("unknown rebuild error")?;
        attrs(&variant.attrs)?;
        if !matches!(variant.fields, syn::Fields::Unit) {
            return Err("rebuild error must be unit".into());
        }
        let (second_insert, input_tag) = insertion(second_insert, &output, &key, true)?;
        if first_insert.method != second_insert.method {
            return Err("rebuild insertion helpers disagree".into());
        }
        let insert_name = helper_name(&first_insert.method);
        let insert_def = self
            .methods
            .get(&insert_name)
            .ok_or("unresolved rebuild insertion")?;
        let Some(syn::FnArg::Typed(insert_key)) = insert_def.item.sig.inputs.iter().nth(1) else {
            return Err("rebuild insertion needs a key".into());
        };
        if self.equality_value(&insert_def.module, &insert_key.ty)? != key_type
            || self.resolve(
                &insert_def.module,
                &queries::result_error(&insert_def.item.sig.output)?,
                0,
            )? != error_type
        {
            return Err("rebuild insertion key/error mismatch".into());
        }
        let insert = self.lower_upsert(&insert_name)?;
        let shape = insert.array.as_ref().ok_or("missing insertion shape")?;
        if shape.field != field_name || shape.capacity != tokens(&array.len) {
            return Err("rebuild insertion must update the initialized array".into());
        }
        // The projected field must have the exact insertion key type.
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
                    .ok_or("missing projected field")?,
            )?,
        )? != key_type
        {
            return Err("rebuild projection key mismatch".into());
        }
        attrs(&ret.attrs)?;
        if !named(&ret.func, "Ok") || ret.args.len() != 1 || !named(&ret.args[0], &output) {
            return Err("rebuild must return its completed output".into());
        }
        let record = shape.record.clone();
        let rebuild = Rebuild {
            projection: Box::new(projection),
            exclusion: Box::new(exclusion),
            insert: Box::new(insert),
            first_tag,
            input_tag,
            input: input_name,
            error,
            capacity,
        };
        Ok(Method {name:name.into(),symbol:name.replace("::","_"),source:def.file.clone(),first_line:f.span().start().line,last_line:f.span().end().line,rust:tokens(f),writes:vec![],body:vec![],iteration:None,last:None,truncation:None,installation:None,restoration:None,enum_projection:None,validator:None,view:None,record_at:None,lookup:None,selection:None,relocation:None,buffer:None,constructor:None,query:None,array:Some(arrays::Shape {field:field_name,capacity:tokens(&array.len),record,scope:"complete two-pass rebuild with source projection, exclusion query and insertion bodies; source/ownership refinement remains open",predicate:None,projection:None,preserve_slots:false,key:None,upsert:None,batch:None,rebuild:Some(Box::new(rebuild)),merge:None,fold:None})})
    }
}

pub(super) fn generate(name: &str, rebuild: &Rebuild) -> String {
    let mut output = String::new();
    for (suffix, helper) in [
        ("projection", &rebuild.projection),
        ("exclusion", &rebuild.exclusion),
        ("insert", &rebuild.insert),
    ] {
        output.push_str(
            &arrays::generate(helper).replace(&helper.symbol, &format!("{name}_{suffix}")),
        );
    }
    let error = serde_json::to_string(&rebuild.error).unwrap();
    let parameter = matches!(rebuild.capacity, constructors::Capacity::Parameter(_));
    let capacity = match &rebuild.capacity {
        constructors::Capacity::Parameter(_) => "capacity".into(),
        constructors::Capacity::Fixed(n) => n.to_string(),
    };
    let binder = if parameter { " (capacity : Nat)" } else { "" };
    output.push_str(&format!("def {name}_ir : Rebuild := ⟨{name}_projection_ir, {name}_exclusion_ir, {name}_insert_ir, {}, {}, {error}⟩\ndef {name} [DecidableEq α]{binder} (entries : ArrayStore α) (keys : List (Cell α)) : Except String (ArrayStore α) := runRebuild {name}_ir {capacity} entries keys\ntheorem {name}_correspondence [DecidableEq α]{binder} (entries : ArrayStore α) (keys : List (Cell α)) : runRebuild {name}_ir {capacity} entries keys = {name}{} entries keys := by rfl\n",rebuild.first_tag,rebuild.input_tag,if parameter {" capacity"} else {""}));
    output
}
