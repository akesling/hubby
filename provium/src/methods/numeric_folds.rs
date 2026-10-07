//! Complete two-pass scalar callback collection and sorted prefix rank selection.
use super::arrays::{binding, named};
use super::lookups::method;
use super::slot_batches::binary;
use super::*;
#[derive(Debug, Serialize)]
pub struct Fold {
    pub first: Box<Method>,
    pub second: Box<Method>,
    pub guard: Box<Method>,
    pub divisor: u64,
    pub callback: String,
    pub key_type: String,
}
pub(super) fn candidate(item: &syn::ImplItemFn) -> bool {
    matches!(&item.sig.output,syn::ReturnType::Type(_,ty) if tokens(ty)=="u64")
        && item
            .sig
            .inputs
            .iter()
            .any(|arg| matches!(arg,syn::FnArg::Typed(a) if matches!(&*a.ty,Type::ImplTrait(_))))
}
fn local(stmt: &syn::Stmt, mutable: bool) -> Result<(String, &Expr), String> {
    let syn::Stmt::Local(local) = stmt else {
        return Err("numeric fold requires its complete local binding".into());
    };
    attrs(&local.attrs)?;
    let syn::Pat::Ident(p) = &local.pat else {
        return Err("numeric local must be a plain identifier".into());
    };
    attrs(&p.attrs)?;
    if p.mutability.is_some() != mutable || p.by_ref.is_some() || p.subpat.is_some() {
        return Err("numeric local binding mode changed".into());
    }
    let init = local.init.as_ref().ok_or("missing numeric initializer")?;
    if init.diverge.is_some() {
        return Err("numeric let-else unsupported".into());
    }
    Ok((p.ident.to_string(), &init.expr))
}
fn statement(stmt: &syn::Stmt) -> Result<&Expr, String> {
    let syn::Stmt::Expr(expr, Some(_)) = stmt else {
        return Err("numeric operation must retain its statement boundary".into());
    };
    Ok(expr)
}
fn integer(expr: &Expr) -> Result<u64, String> {
    let Expr::Lit(l) = expr else {
        return Err("numeric constant must be a literal".into());
    };
    attrs(&l.attrs)?;
    let syn::Lit::Int(i) = &l.lit else {
        return Err("numeric constant must be unsigned integer".into());
    };
    if !i.suffix().is_empty() && i.suffix() != "usize" {
        return Err("numeric index literal must infer usize".into());
    }
    i.base10_parse().map_err(|e| e.to_string())
}
fn index<'a>(expr: &'a Expr, buffer: &str) -> Result<&'a Expr, String> {
    let Expr::Index(i) = expr else {
        return Err("numeric buffer index missing".into());
    };
    attrs(&i.attrs)?;
    if !named(&i.expr, buffer) {
        return Err("numeric operation uses another buffer".into());
    }
    Ok(&i.index)
}
fn source_call(expr: &Expr) -> Result<String, String> {
    let Expr::MethodCall(c) = expr else {
        return Err("numeric fold requires a source-local projection/query".into());
    };
    let c = method(expr, &c.method.to_string(), 0)?;
    if !named(&c.receiver, "self") {
        return Err("numeric projection/query must read self".into());
    }
    Ok(c.method.to_string())
}
fn collect(
    stmt: &syn::Stmt,
    buffer: &str,
    count: &str,
    callback: &str,
    forbidden: &[&str],
) -> Result<String, String> {
    let syn::Stmt::Expr(Expr::ForLoop(f), None) = stmt else {
        return Err("numeric fold requires its original for loop".into());
    };
    attrs(&f.attrs)?;
    if f.label.is_some() {
        return Err("numeric labeled loop unsupported".into());
    }
    let key = binding(&f.pat)?;
    if forbidden.contains(&key.as_str()) {
        return Err("numeric loop key shadows a live binding".into());
    }
    let projection = source_call(&f.expr)?;
    let [write, increment] = f.body.stmts.as_slice() else {
        return Err("numeric loop must retain assignment and increment only".into());
    };
    let Expr::Assign(write) = statement(write)? else {
        return Err("numeric callback must write its indexed slot".into());
    };
    attrs(&write.attrs)?;
    if !named(index(&write.left, buffer)?, count) {
        return Err("numeric callback write must use current count".into());
    }
    let Expr::Call(call) = &*write.right else {
        return Err("numeric write must invoke the owned callback".into());
    };
    attrs(&call.attrs)?;
    if !named(&call.func, callback) || call.args.len() != 1 || !named(&call.args[0], &key) {
        return Err("numeric callback invocation changed".into());
    }
    let Expr::Binary(add) = statement(increment)? else {
        return Err("numeric loop increment missing".into());
    };
    attrs(&add.attrs)?;
    if !matches!(add.op, syn::BinOp::AddAssign(_))
        || !named(&add.left, count)
        || integer(&add.right)? != 1
    {
        return Err("numeric loop must increment count once".into());
    }
    Ok(projection)
}
fn sorted(stmt: &syn::Stmt, buffer: &str, count: &str) -> Result<(), String> {
    let sort = method(statement(stmt)?, "sort_unstable", 0)?;
    let Expr::Range(range) = index(&sort.receiver, buffer)? else {
        return Err("numeric sort must use initialized prefix".into());
    };
    attrs(&range.attrs)?;
    if range.start.is_some()
        || !matches!(range.limits, syn::RangeLimits::HalfOpen(_))
        || !range.end.as_ref().is_some_and(|e| named(e, count))
    {
        return Err("numeric sort range must be ..count".into());
    }
    Ok(())
}
fn rank(stmt: &syn::Stmt, buffer: &str, count: &str) -> Result<(String, u64), String> {
    let (name, expr) = local(stmt, false)?;
    let (length, offset) = binary(index(expr, buffer)?, "-")?;
    if !named(length, count) {
        return Err("numeric rank must subtract from initialized count".into());
    }
    let Expr::Paren(offset) = offset else {
        return Err("numeric rank requires parenthesized quotient increment".into());
    };
    attrs(&offset.attrs)?;
    let (quotient, one) = binary(&offset.expr, "+")?;
    if integer(one)? != 1 {
        return Err("numeric rank quotient increment must be one".into());
    }
    let (length, divisor) = binary(quotient, "/")?;
    if !named(length, count) {
        return Err("numeric rank quotient uses a different count".into());
    }
    let divisor = integer(divisor)?;
    if divisor <= 1 {
        return Err("numeric rank requires divisor greater than one".into());
    }
    Ok((name, divisor))
}
impl Crate {
    pub(super) fn lower_numeric_fold(&self, name: &str) -> Result<Method, String> {
        let def = self.methods.get(name).ok_or("unknown numeric fold")?;
        let f = &def.item;
        let sig = &f.sig;
        attrs(&f.attrs)?;
        self.predicate_namespaces()?;
        if sig.asyncness.is_some()
            || sig.constness.is_some()
            || sig.unsafety.is_some()
            || sig.abi.is_some()
            || !sig.generics.params.is_empty()
            || sig.generics.where_clause.is_some()
            || def.impl_generics.type_params().next().is_some()
            || def.impl_generics.lifetimes().next().is_some()
        {
            return Err("numeric fold needs a concrete shared receiver and owned callback".into());
        }
        let args: Vec<_> = sig.inputs.iter().collect();
        let [syn::FnArg::Receiver(receiver), syn::FnArg::Typed(callback)] = args.as_slice() else {
            return Err("numeric fold needs &self and one owned callback".into());
        };
        attrs(&receiver.attrs)?;
        attrs(&callback.attrs)?;
        if receiver.reference.is_none()
            || receiver.mutability.is_some()
            || receiver.colon_token.is_some()
        {
            return Err("numeric fold needs &self".into());
        }
        let syn::Pat::Ident(cb) = &*callback.pat else {
            return Err("numeric callback must be a mutable identifier".into());
        };
        attrs(&cb.attrs)?;
        if cb.mutability.is_none() || cb.by_ref.is_some() || cb.subpat.is_some() {
            return Err("numeric callback must be an owned mutable binding".into());
        }
        let callback_name = cb.ident.to_string();
        let key_type = self.projection_value_type(
            &def.module,
            super::predicate_folds::callback_type(&callback.ty, false, "u64")?,
        )?;
        let [buffer, count, first_loop, first_sort, first_rank, guard, reset, second_loop, second_sort, second_rank, syn::Stmt::Expr(result, None)] =
            f.block.stmts.as_slice()
        else {
            return Err(
                "numeric fold must retain both loops, sorts, ranks, early return and minimum"
                    .into(),
            );
        };
        let (buffer_name, buffer) = local(buffer, true)?;
        let (count_name, count) = local(count, true)?;
        if buffer_name == count_name
            || [buffer_name.as_str(), count_name.as_str()].contains(&callback_name.as_str())
        {
            return Err("numeric locals shadow callback or buffer".into());
        }
        let Expr::Repeat(buffer) = buffer else {
            return Err("numeric buffer must retain its zero-filled array initializer".into());
        };
        attrs(&buffer.attrs)?;
        if integer(&buffer.expr)? != 0 || integer(count)? != 0 {
            return Err("numeric buffer and count must start at zero".into());
        }
        let first_name = collect(
            first_loop,
            &buffer_name,
            &count_name,
            &callback_name,
            &[&buffer_name, &count_name, &callback_name],
        )?;
        sorted(first_sort, &buffer_name, &count_name)?;
        let (first_value, divisor) = rank(first_rank, &buffer_name, &count_name)?;
        if [&buffer_name, &count_name, &callback_name].contains(&&first_value) {
            return Err("numeric first rank shadows a live binding".into());
        }
        let syn::Stmt::Expr(Expr::If(guard), None) = guard else {
            return Err("numeric fold requires its source early return".into());
        };
        attrs(&guard.attrs)?;
        if guard.else_branch.is_some() {
            return Err("numeric early return cannot hide else effects".into());
        }
        let Expr::Unary(negated) = &*guard.cond else {
            return Err("numeric early return needs negated source query".into());
        };
        attrs(&negated.attrs)?;
        if !matches!(negated.op, syn::UnOp::Not(_)) {
            return Err("numeric gate must negate its query".into());
        }
        let guard_name = source_call(&negated.expr)?;
        let [return_stmt] = guard.then_branch.stmts.as_slice() else {
            return Err("numeric early return must have one statement".into());
        };
        let Expr::Return(ret) = statement(return_stmt)? else {
            return Err("numeric gate must return first rank".into());
        };
        attrs(&ret.attrs)?;
        if !ret.expr.as_ref().is_some_and(|e| named(e, &first_value)) {
            return Err("numeric gate returns a different value".into());
        }
        let Expr::Assign(reset) = statement(reset)? else {
            return Err("numeric second loop must reset count".into());
        };
        attrs(&reset.attrs)?;
        if !named(&reset.left, &count_name) || integer(&reset.right)? != 0 {
            return Err("numeric second loop must reset count to zero".into());
        }
        let second_name = collect(
            second_loop,
            &buffer_name,
            &count_name,
            &callback_name,
            &[&buffer_name, &count_name, &callback_name, &first_value],
        )?;
        sorted(second_sort, &buffer_name, &count_name)?;
        let (second_value, second_divisor) = rank(second_rank, &buffer_name, &count_name)?;
        if divisor != second_divisor {
            return Err("numeric rounds use different rank formulas".into());
        }
        if [&buffer_name, &count_name, &callback_name, &first_value].contains(&&second_value) {
            return Err("numeric second rank shadows a live binding".into());
        }
        let minimum = method(result, "min", 1)?;
        if !named(&minimum.receiver, &first_value) || !named(&minimum.args[0], &second_value) {
            return Err("numeric final minimum must combine both ranks".into());
        }
        let qualify = |method: &str| {
            format!("{}::{}::{}", def.module, def.receiver, method)
                .trim_start_matches("::")
                .to_string()
        };
        let first = self.lower_projection(&qualify(&first_name))?;
        let second = self.lower_projection(&qualify(&second_name))?;
        let guard = self.lower_array_query(&qualify(&guard_name))?;
        let first_shape = first
            .array
            .as_ref()
            .ok_or("numeric first projection missing")?;
        for shape in [
            second
                .array
                .as_ref()
                .ok_or("numeric second projection missing")?,
            guard.array.as_ref().ok_or("numeric gate missing")?,
        ] {
            if shape.field != first_shape.field
                || shape.capacity != first_shape.capacity
                || shape.record != first_shape.record
                || shape.key.is_some()
            {
                return Err("numeric projections and query must share the source array".into());
            }
        }
        if tokens(&buffer.len) != first_shape.capacity {
            return Err("numeric buffer capacity differs from source array".into());
        }
        for projection in [&first, &second] {
            let shape = projection.array.as_ref().unwrap();
            if shape.preserve_slots {
                return Err("numeric loop requires flattened scalar projection".into());
            }
            let key = shape
                .projection
                .as_ref()
                .ok_or("numeric key projection missing")?;
            let record_def = Definition {
                module: self.struct_modules[&shape.record].clone(),
                file: def.file.clone(),
                item: f.clone(),
                receiver: shape.record.clone(),
                impl_generics: syn::Generics::default(),
                self_type: None,
            };
            if self.projection_value_type(&record_def.module, self.field_type(&record_def, key)?)?
                != key_type
            {
                return Err("numeric projection key differs from callback argument".into());
            }
        }
        let mut lowered = self.lower_projection(&qualify(&first_name))?;
        lowered.name = name.into();
        lowered.symbol = name.replace("::", "_");
        lowered.source = def.file.clone();
        lowered.first_line = f.span().start().line;
        lowered.last_line = f.span().end().line;
        lowered.rust = tokens(f);
        let shape = lowered.array.as_mut().unwrap();
        shape.predicate = None;
        shape.projection = None;
        shape.scope="complete scalar callback loops, initialized-prefix sorting, rank selection and minimum; Rust buffer/usize/sort/ownership/panic/source refinement remains open";
        shape.numeric = Some(Box::new(Fold {
            first: Box::new(first),
            second: Box::new(second),
            guard: Box::new(guard),
            divisor,
            callback: callback_name,
            key_type,
        }));
        Ok(lowered)
    }
}
pub(super) fn generate(name: &str, fold: &Fold) -> String {
    let mut output = String::new();
    for (suffix, method) in [
        ("first", &fold.first),
        ("second", &fold.second),
        ("guard", &fold.guard),
    ] {
        output.push_str(&arrays::generate_named(method, &format!("{name}_{suffix}")));
    }
    output.push_str(&format!("def {name}_ir : NumericFold := {{ first := {name}_first_ir, second := {name}_second_ir, secondRequired := {name}_guard_ir, divisor := {}, divisorProper := (by decide) }}\ndef {name} (entries : ArrayStore α) (callback : σ) (abortOnPanic : Bool) : CallbackRun α σ UInt64 UInt64 := runNumericFold {name}_ir entries callback abortOnPanic\ntheorem {name}_correspondence (entries : ArrayStore α) (callback : σ) (abortOnPanic : Bool) : runNumericFold {name}_ir entries callback abortOnPanic = {name} entries callback abortOnPanic := by rfl\n",fold.divisor));
    output
}
