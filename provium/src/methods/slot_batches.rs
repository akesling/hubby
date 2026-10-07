//! Checked batches of slice keys into an initially empty optional-record array.
//! Retains the original nested loops, validation order and full upsert callee.
use super::arrays::{binding, copy_derived, named};
use super::lookups::method;
use super::*;

#[derive(Debug, Serialize)]
pub struct Batch {
    pub inputs: Vec<String>,
    pub arguments: Vec<Option<usize>>,
    pub constructor_method: Option<String>,
    pub constructor_rust: Option<String>,
    pub capacity: constructors::Capacity,
    pub required: usize,
    pub passes: Vec<(usize, u8)>,
    pub exclusion_tag: u8,
    pub exclusion_input: usize,
    pub error: String,
    pub insert_method: String,
    pub insert_rust: String,
    pub insert: upserts::Upsert,
}
pub(super) fn candidate(item: &syn::ImplItemFn) -> bool {
    (output_error(&item.sig.output).is_ok() && matches!(item.block.stmts.as_slice(), [syn::Stmt::Expr(Expr::Call(_), None)])) || item.block.stmts.iter().any(
        |s| matches!(s,syn::Stmt::Expr(Expr::ForLoop(f),_) if matches!(&*f.expr,Expr::Array(_))),
    )
}
pub(super) fn output_error(output: &syn::ReturnType) -> Result<String, String> {
    let syn::ReturnType::Type(_, ty) = output else {
        return Err("batch constructor needs a Result".into());
    };
    let Type::Path(p) = &**ty else {
        return Err("batch constructor needs a Result".into());
    };
    if p.qself.is_some()
        || p.path.leading_colon.is_some()
        || p.path.segments.len() != 1
        || p.path.segments[0].ident != "Result"
    {
        return Err("batch constructor needs builtin Result<Self, Error>".into());
    }
    let syn::PathArguments::AngleBracketed(args) = &p.path.segments[0].arguments else {
        return Err("missing batch output arguments".into());
    };
    let args: Vec<_> = args.args.iter().collect();
    let [syn::GenericArgument::Type(Type::Path(s)), syn::GenericArgument::Type(Type::Path(e))] =
        args.as_slice()
    else {
        return Err("batch constructor needs Result<Self, Error>".into());
    };
    if s.qself.is_some()
        || !s.path.is_ident("Self")
        || e.qself.is_some()
        || e.path.leading_colon.is_some()
        || e.path.segments.len() != 1
        || !matches!(e.path.segments[0].arguments, syn::PathArguments::None)
    {
        return Err("batch needs plain Self and concrete error enum".into());
    }
    Ok(e.path.segments[0].ident.to_string())
}
pub(super) fn tuple_binding(p: &syn::Pat) -> Result<(String, String), String> {
    let syn::Pat::Tuple(p) = p else {
        return Err("batch loop needs two plain bindings".into());
    };
    attrs(&p.attrs)?;
    if p.elems.len() != 2 {
        return Err("batch loop needs two bindings".into());
    }
    let a = binding(&p.elems[0])?;
    let b = binding(&p.elems[1])?;
    if a == b {
        return Err("duplicate batch loop binding".into());
    }
    Ok((a, b))
}
pub(super) fn tag(expr: &Expr) -> Result<u8, String> {
    let Expr::Lit(l) = expr else {
        return Err("batch tag must be a u8 literal".into());
    };
    attrs(&l.attrs)?;
    let syn::Lit::Int(n) = &l.lit else {
        return Err("batch tag must be an integer".into());
    };
    if !n.suffix().is_empty() && n.suffix() != "u8" {
        return Err("batch tag must be u8".into());
    }
    n.base10_parse().map_err(|e| e.to_string())
}
pub(super) fn binary<'a>(expr: &'a Expr, operation: &str) -> Result<(&'a Expr, &'a Expr), String> {
    let Expr::Binary(b) = expr else {
        return Err("batch validation requires the original binary expression".into());
    };
    attrs(&b.attrs)?;
    if tokens(&b.op) != operation {
        return Err(format!("batch validation requires {operation}"));
    }
    Ok((&b.left, &b.right))
}
fn unparen(expr: &Expr) -> Result<&Expr, String> {
    if let Expr::Paren(p) = expr {
        attrs(&p.attrs)?;
        Ok(&p.expr)
    } else {
        Ok(expr)
    }
}
pub(super) fn error_return(branch: &syn::ExprIf) -> Result<&Expr, String> {
    attrs(&branch.attrs)?;
    if branch.else_branch.is_some() {
        return Err("batch validation cannot hide an else effect".into());
    }
    let [syn::Stmt::Expr(Expr::Return(r), Some(_))] = branch.then_branch.stmts.as_slice() else {
        return Err("batch validation must immediately return an error".into());
    };
    attrs(&r.attrs)?;
    let Some(expr) = &r.expr else {
        return Err("missing batch error value".into());
    };
    let Expr::Call(c) = &**expr else {
        return Err("batch error requires Err(variant)".into());
    };
    attrs(&c.attrs)?;
    if !named(&c.func, "Err") || c.args.len() != 1 {
        return Err("batch error requires builtin Err".into());
    }
    Ok(&c.args[0])
}
impl Crate {
    pub(super) fn lower_slot_batch(&self, name: &str) -> Result<Method, String> {
        let def = self.methods.get(name).ok_or("unknown batch constructor")?;
        let f = &def.item;
        let sig = &f.sig;
        attrs(&f.attrs)?;
        self.iterator_traits()?;
        self.constructor_namespaces(def)?;
        if sig.asyncness.is_some()
            || sig.unsafety.is_some()
            || sig.constness.is_some()
            || sig.abi.is_some()
            || !sig.generics.params.is_empty()
            || sig.generics.where_clause.is_some()
            || sig.inputs.is_empty()
            || def.impl_generics.type_params().next().is_some()
            || def.impl_generics.lifetimes().next().is_some()
        {
            return Err("batch constructor requires plain concrete slice inputs".into());
        }
        let mut inputs = Vec::new();
        let mut key_type = None;
        for argument in &sig.inputs {
            let syn::FnArg::Typed(a) = argument else {
                return Err("batch construction cannot have a receiver".into());
            };
            attrs(&a.attrs)?;
            let input = binding(&a.pat)?;
            if inputs.contains(&input) {
                return Err("duplicate batch input".into());
            }
            let Type::Reference(r) = &*a.ty else {
                return Err("batch input must be a shared slice".into());
            };
            let Type::Slice(s) = &*r.elem else {
                return Err("batch input must be a slice".into());
            };
            if r.mutability.is_some() {
                return Err("batch input slices must be shared".into());
            }
            let actual = self.equality_value(&def.module, &s.elem)?;
            if key_type.as_ref().is_some_and(|k| k != &actual) {
                return Err("batch key types disagree".into());
            }
            key_type = Some(actual);
            inputs.push(input);
        }
        let input_index = |e: &Expr| {
            inputs
                .iter()
                .position(|n| named(e, n))
                .ok_or("batch slice is not an input".to_string())
        };
        let error_type = self.resolve(&def.module, &output_error(&sig.output)?, 0)?;
        if self.drops.contains(&error_type) {
            return Err("batch error requires destructor semantics".into());
        }
        let receiver = self
            .structs
            .get(&def.receiver)
            .ok_or("batch receiver must be a struct")?;
        if receiver.fields.len() != 1
            || !copy_derived(receiver)
            || self.drops.contains(&def.receiver)
        {
            return Err("batch receiver must be a one-array Copy record without Drop".into());
        }
        if let [syn::Stmt::Expr(Expr::Call(call), None)] = f.block.stmts.as_slice() {
            return self.lower_slot_forward(
                name,
                def,
                call,
                inputs,
                key_type.as_deref().unwrap(),
                &error_type,
            );
        }
        let [syn::Stmt::Expr(Expr::If(nonempty), _), syn::Stmt::Local(initial), syn::Stmt::Expr(Expr::ForLoop(outer), _), syn::Stmt::Expr(success, None)] =
            f.block.stmts.as_slice()
        else {
            return Err(
                "batch constructor must retain validation, initialization, both loops and return"
                    .into(),
            );
        };
        let empty = method(&nonempty.cond, "is_empty", 0)?;
        let required = input_index(&empty.receiver)?;
        let first_error = error_return(nonempty)?;
        let Expr::Path(error_path) = first_error else {
            return Err("batch error must be a unit variant".into());
        };
        attrs(&error_path.attrs)?;
        if error_path.qself.is_some()
            || error_path.path.leading_colon.is_some()
            || error_path.path.segments.len() != 2
            || error_path
                .path
                .segments
                .iter()
                .any(|s| !matches!(s.arguments, syn::PathArguments::None))
        {
            return Err("batch error must resolve to an enum variant".into());
        }
        if self.resolve(
            &def.module,
            &error_path.path.segments[0].ident.to_string(),
            0,
        )? != error_type
        {
            return Err("batch error type mismatch".into());
        }
        let error = error_path.path.segments[1].ident.to_string();
        let variant = self
            .enums
            .get(&error_type)
            .and_then(|e| e.variants.iter().find(|v| v.ident == error))
            .ok_or("unknown batch error")?;
        attrs(&variant.attrs)?;
        if !matches!(variant.fields, syn::Fields::Unit) {
            return Err("batch error must have no fields".into());
        }
        attrs(&initial.attrs)?;
        let syn::Pat::Ident(local) = &initial.pat else {
            return Err("batch output needs a mutable binding".into());
        };
        attrs(&local.attrs)?;
        if local.by_ref.is_some() || local.mutability.is_none() || local.subpat.is_some() {
            return Err("batch output must be a plain mutable local".into());
        }
        let output = local.ident.to_string();
        let init = initial
            .init
            .as_ref()
            .ok_or("batch output needs initialization")?;
        if init.diverge.is_some() {
            return Err("batch cannot use let-else".into());
        }
        let Expr::Struct(value) = &*init.expr else {
            return Err("batch must initialize Self explicitly".into());
        };
        attrs(&value.attrs)?;
        if value.qself.is_some()
            || !value.path.is_ident("Self")
            || value.rest.is_some()
            || value.fields.len() != 1
        {
            return Err("batch must initialize its entire array record".into());
        }
        let field = &value.fields[0];
        attrs(&field.attrs)?;
        let syn::Member::Named(field_name) = &field.member else {
            return Err("batch needs a named array field".into());
        };
        let field_name = field_name.to_string();
        let Expr::Repeat(repeat) = &field.expr else {
            return Err("batch array must use a complete repeat initializer".into());
        };
        attrs(&repeat.attrs)?;
        if !named(&repeat.expr, "None") {
            return Err("batch must start with empty slots".into());
        }
        let Type::Array(array) = self.field_type(def, std::slice::from_ref(&field_name))? else {
            return Err("batch field must be a builtin array".into());
        };
        if tokens(&array.len) != tokens(&repeat.len) {
            return Err("batch capacity substitution unsupported".into());
        }
        let capacity = match &*repeat.len {
            Expr::Lit(l) if matches!(l.lit, syn::Lit::Int(_)) => {
                attrs(&l.attrs)?;
                let syn::Lit::Int(n) = &l.lit else {
                    unreachable!()
                };
                if !n.suffix().is_empty() && n.suffix() != "usize" {
                    return Err("batch capacity must be usize".into());
                }
                constructors::Capacity::Fixed(n.base10_parse().map_err(|e| e.to_string())?)
            }
            Expr::Path(p) if p.qself.is_none() && p.path.get_ident().is_some() => {
                attrs(&p.attrs)?;
                let n = p.path.get_ident().unwrap().to_string();
                if !def
                    .impl_generics
                    .const_params()
                    .any(|p| p.ident == n && tokens(&p.ty) == "usize")
                {
                    return Err("batch capacity must be a usize const parameter".into());
                }
                constructors::Capacity::Parameter(n)
            }
            _ => return Err("batch capacity expressions require arithmetic semantics".into()),
        };
        attrs(&outer.attrs)?;
        if outer.label.is_some() {
            return Err("batch labeled loops unsupported".into());
        }
        let (set, kind) = tuple_binding(&outer.pat)?;
        let Expr::Array(passes) = &*outer.expr else {
            return Err("batch outer loop needs an explicit array of slice/tag pairs".into());
        };
        attrs(&passes.attrs)?;
        let mut schedule = Vec::new();
        for pass in &passes.elems {
            let Expr::Tuple(pass) = pass else {
                return Err("batch pass needs a slice/tag pair".into());
            };
            attrs(&pass.attrs)?;
            if pass.elems.len() != 2 {
                return Err("batch pass needs two values".into());
            }
            schedule.push((input_index(&pass.elems[0])?, tag(&pass.elems[1])?));
        }
        let [syn::Stmt::Expr(Expr::ForLoop(inner), _)] = outer.body.stmts.as_slice() else {
            return Err("batch outer loop must retain exactly its nested key loop".into());
        };
        attrs(&inner.attrs)?;
        if inner.label.is_some() {
            return Err("batch labeled key loop unsupported".into());
        }
        let (index, key) = tuple_binding(&inner.pat)?;
        let enumeration = method(&inner.expr, "enumerate", 0)?;
        let iter = method(&enumeration.receiver, "iter", 0)?;
        if !named(&iter.receiver, &set) {
            return Err("batch must enumerate its current slice".into());
        }
        let mut bindings = inputs.clone();
        for n in [&output, &set, &kind, &index, &key] {
            if bindings.contains(n) {
                return Err("batch bindings shadow input or enclosing locals".into());
            }
            bindings.push(n.clone());
        }
        let [syn::Stmt::Expr(Expr::If(validation), _), syn::Stmt::Expr(Expr::Try(insert), Some(_))] =
            inner.body.stmts.as_slice()
        else {
            return Err("batch key loop must retain validation then insertion".into());
        };
        if tokens(error_return(validation)?) != tokens(first_error) {
            return Err("batch validation error variants disagree".into());
        }
        let (duplicates, exclusion) = binary(&validation.cond, "||")?;
        let contains = method(duplicates, "contains", 1)?;
        if !named(&contains.args[0], &key) {
            return Err("batch duplicate check must inspect the current key".into());
        }
        let Expr::Index(prefix) = &*contains.receiver else {
            return Err("batch duplicate check must use its prior prefix".into());
        };
        attrs(&prefix.attrs)?;
        if !named(&prefix.expr, &set) {
            return Err("batch duplicate prefix must use the current slice".into());
        }
        let Expr::Range(range) = &*prefix.index else {
            return Err("batch duplicate check needs a slice prefix".into());
        };
        attrs(&range.attrs)?;
        if range.start.is_some()
            || !matches!(range.limits, syn::RangeLimits::HalfOpen(_))
            || !range.end.as_deref().is_some_and(|e| named(e, &index))
        {
            return Err("batch prefix must end before its enumerated index".into());
        }
        let (kind_test, excluded) = binary(unparen(exclusion)?, "&&")?;
        let (tested_kind, excluded_tag) = binary(kind_test, "==")?;
        if !named(tested_kind, &kind) {
            return Err("batch exclusion must use the current tag".into());
        }
        let exclusion_tag = tag(excluded_tag)?;
        let excluded = method(excluded, "contains", 1)?;
        if !named(&excluded.args[0], &key) {
            return Err("batch exclusion must check its current key".into());
        }
        let exclusion_input = input_index(&excluded.receiver)?;
        attrs(&insert.attrs)?;
        let Expr::MethodCall(call) = &*insert.expr else {
            return Err("batch insertion must call a source-local helper".into());
        };
        attrs(&call.attrs)?;
        if !named(&call.receiver, &output)
            || call.turbofish.is_some()
            || call.args.len() != 2
            || !named(&call.args[1], &kind)
        {
            return Err("batch insertion must update its output with the current key/tag".into());
        }
        let Expr::Unary(deref) = &call.args[0] else {
            return Err("batch insertion must copy the current slice key".into());
        };
        attrs(&deref.attrs)?;
        if !matches!(deref.op, syn::UnOp::Deref(_)) || !named(&deref.expr, &key) {
            return Err("batch insertion must dereference its current key".into());
        }
        let insert_method = format!("{}::{}::{}", def.module, def.receiver, call.method)
            .trim_start_matches("::")
            .to_string();
        let insert_def = self
            .methods
            .get(&insert_method)
            .ok_or("unresolved batch insertion helper")?;
        let insert_error = self.resolve(
            &insert_def.module,
            &queries::result_error(&insert_def.item.sig.output)?,
            0,
        )?;
        if insert_error != error_type {
            return Err("batch insertion error type mismatch".into());
        }
        let Some(syn::FnArg::Typed(insert_key)) = insert_def.item.sig.inputs.iter().nth(1) else {
            return Err("batch insertion requires a key input".into());
        };
        if Some(self.equality_value(&insert_def.module, &insert_key.ty)?) != key_type {
            return Err("batch insertion key type mismatch".into());
        }
        let helper = self.lower_upsert(&insert_method)?;
        let shape = helper
            .array
            .ok_or("batch insertion must update optional records")?;
        if shape.field != field_name || shape.capacity != tokens(&array.len) {
            return Err("batch insertion must use its initialized array".into());
        }
        let Expr::Call(ret) = success else {
            return Err("batch must return its completed record".into());
        };
        attrs(&ret.attrs)?;
        if !named(&ret.func, "Ok") || ret.args.len() != 1 || !named(&ret.args[0], &output) {
            return Err("batch must return Ok(output)".into());
        }
        let batch = Batch {
            arguments: (0..inputs.len()).map(Some).collect(),
            constructor_method: None,
            constructor_rust: None,
            inputs,
            capacity,
            required,
            passes: schedule,
            exclusion_tag,
            exclusion_input,
            error,
            insert_method,
            insert_rust: helper.rust,
            insert: shape.upsert.ok_or("missing insertion IR")?,
        };
        Ok(Method{name:name.into(),symbol:name.replace("::","_"),source:def.file.clone(),first_line:f.span().start().line,last_line:f.span().end().line,rust:tokens(f),writes:vec![],body:vec![],iteration:None,last:None,truncation:None,installation:None,restoration:None,getter: None, enum_projection:None,validator:None,view:None,record_at:None,lookup:None,selection:None,relocation:None,buffer:None,constructor:None,query:None,array:Some(arrays::Shape{field:field_name,capacity:tokens(&array.len),record:shape.record,predicate:None,projection:None,preserve_slots:false,key:None,upsert:None,batch:Some(batch),rebuild:None,merge:None,fold:None,numeric:None,scope:"complete checked slice batches and insertion callee; prefix enumeration, early errors and pass order retained; Rust source/ownership/layout refinement remains open"})})
    }
}
impl Crate {
    fn lower_slot_forward(
        &self,
        name: &str,
        def: &Definition,
        call: &syn::ExprCall,
        inputs: Vec<String>,
        key_type: &str,
        error_type: &str,
    ) -> Result<Method, String> {
        attrs(&call.attrs)?;
        let Expr::Path(callee) = &*call.func else {
            return Err("batch forwarding requires Self::constructor".into());
        };
        attrs(&callee.attrs)?;
        if callee.qself.is_some()
            || callee.path.leading_colon.is_some()
            || callee.path.segments.len() != 2
            || callee.path.segments[0].ident != "Self"
            || callee
                .path
                .segments
                .iter()
                .any(|s| !matches!(s.arguments, syn::PathArguments::None))
        {
            return Err(
                "batch forwarding needs a source-local constructor without generic arguments"
                    .into(),
            );
        }
        let callee_name = format!(
            "{}::{}::{}",
            def.module, def.receiver, callee.path.segments[1].ident
        )
        .trim_start_matches("::")
        .to_string();
        let callee_def = self
            .methods
            .get(&callee_name)
            .ok_or("unresolved batch constructor")?;
        if !callee_def.item.block.stmts.iter().any(|s|matches!(s,syn::Stmt::Expr(Expr::ForLoop(f),_) if matches!(&*f.expr,Expr::Array(_)))) {
            return Err("batch forwarding requires a complete batch body; recursive or nested forwarding unsupported".into());
        }
        if self.resolve(
            &callee_def.module,
            &output_error(&callee_def.item.sig.output)?,
            0,
        )? != error_type
        {
            return Err("batch forwarding error types disagree".into());
        }
        let mut lowered = self.lower_slot_batch(&callee_name)?;
        let batch = lowered
            .array
            .as_mut()
            .and_then(|s| s.batch.as_mut())
            .ok_or("forwarded method is not a batch")?;
        if call.args.len() != batch.inputs.len() {
            return Err("batch forwarding must supply every slice input".into());
        }
        // The callee has already checked that all its inputs share this concrete key type.
        let Some(syn::FnArg::Typed(input)) = callee_def.item.sig.inputs.first() else {
            return Err("missing forwarded slice input".into());
        };
        let Type::Reference(reference) = &*input.ty else {
            return Err("forwarded input is not a slice".into());
        };
        let Type::Slice(slice) = &*reference.elem else {
            return Err("forwarded input is not a slice".into());
        };
        if self.equality_value(&callee_def.module, &slice.elem)? != key_type {
            return Err("batch forwarding key types disagree".into());
        }
        let mut arguments = Vec::new();
        for argument in &call.args {
            if let Some(index) = inputs.iter().position(|n| named(argument, n)) {
                arguments.push(Some(index));
            } else {
                let Expr::Reference(reference) = argument else {
                    return Err(
                        "batch forwarding permits only input slices and borrowed empty arrays"
                            .into(),
                    );
                };
                attrs(&reference.attrs)?;
                let Expr::Array(array) = &*reference.expr else {
                    return Err("batch forwarding needs a borrowed empty array".into());
                };
                attrs(&array.attrs)?;
                if reference.mutability.is_some() || !array.elems.is_empty() {
                    return Err("batch forwarding constant must be an empty shared slice".into());
                }
                arguments.push(None);
            }
        }
        batch.inputs = inputs;
        batch.arguments = arguments;
        batch.constructor_method = Some(callee_name);
        batch.constructor_rust = Some(lowered.rust.clone());
        lowered.name = name.into();
        lowered.symbol = name.replace("::", "_");
        lowered.source = def.file.clone();
        lowered.first_line = def.item.span().start().line;
        lowered.last_line = def.item.span().end().line;
        lowered.rust = tokens(&def.item);
        Ok(lowered)
    }
}

pub(super) fn generate(name: &str, batch: &Batch) -> String {
    let helper = format!("{name}_insert");
    let mut text = upserts::generate(&helper, &batch.insert);
    let schedule = batch
        .passes
        .iter()
        .map(|(i, t)| format!("({i}, {t})"))
        .collect::<Vec<_>>()
        .join(", ");
    let inputs = (0..batch.inputs.len())
        .map(|i| format!("input{i}"))
        .collect::<Vec<_>>();
    let input_parameters = inputs.join(" ");
    let values = batch
        .arguments
        .iter()
        .map(|i| i.map_or_else(|| "[]".into(), |i| inputs[i].clone()))
        .collect::<Vec<_>>()
        .join(", ");
    let (capacity_parameter, capacity) = match &batch.capacity {
        constructors::Capacity::Fixed(n) => (String::new(), n.to_string()),
        constructors::Capacity::Parameter(_) => ("(capacity : Nat) ".into(), "capacity".into()),
    };
    let error = serde_json::to_string(&batch.error).unwrap();
    text+=&format!("def {name}_ir : SlotBatch := ⟨{helper}_ir, {}, [{schedule}], {}, {}, {error}⟩\ndef {name} [DecidableEq α] {capacity_parameter}({input_parameters} : List (Cell α)) : Except String (ArrayStore α) :=\n  runSlotBatch {name}_ir {capacity} [{values}]\ntheorem {name}_correspondence [DecidableEq α] {capacity_parameter}({input_parameters} : List (Cell α)) : runSlotBatch {name}_ir {capacity} [{values}] = {name} {}{input_parameters} := by rfl\n",batch.required,batch.exclusion_tag,batch.exclusion_input,if capacity_parameter.is_empty(){""}else{"capacity "});
    // runSlotBatch reads inputs with a total `getD []`, so an index past the
    // argument list would silently become an empty slice. Prove, per generated
    // program, that every index names one of its actual arguments.
    let arity = batch.arguments.len();
    text += &format!(
        "theorem {name}_indices : {name}_ir.required < {arity} ∧ {name}_ir.exclusionInput < {arity} ∧ ∀ pass ∈ {name}_ir.passes, pass.1 < {arity} := by decide\n"
    );
    text
}
