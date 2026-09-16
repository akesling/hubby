//! Two-stage predicate counts with an owned FnMut callback. The local closure,
//! cloned iterator, borrowed dynamic callback and final short circuit are checked.
use super::arrays::{binding, named, relative};
use super::lookups::method;
use super::slot_batches::binary;
use super::*;
#[derive(Debug, Serialize)]
pub struct Fold {
    pub first: Condition,
    pub second: Condition,
    pub key: Vec<String>,
    pub divisor: u64,
    pub inclusive: bool,
    pub callback: String,
    pub key_type: String,
    pub guard: Box<Method>,
}
pub(super) fn candidate(item: &syn::ImplItemFn) -> bool {
    matches!(&item.sig.output,syn::ReturnType::Type(_,ty) if tokens(ty)=="bool") && item.sig.inputs.iter().any(|arg|matches!(arg,syn::FnArg::Typed(a) if matches!(&*a.ty,Type::ImplTrait(t) if t.bounds.iter().any(|b|matches!(b,syn::TypeParamBound::Trait(t) if t.path.segments.last().is_some_and(|s|s.ident=="FnMut"))))))
}
fn callback_type(ty: &Type, dynamic: bool) -> Result<&Type, String> {
    let bounds = if dynamic {
        let Type::Reference(r) = ty else {
            return Err("local callback must be &mut dyn FnMut".into());
        };
        if r.mutability.is_none() || r.lifetime.is_some() {
            return Err("local callback needs an elided mutable reborrow".into());
        }
        let Type::TraitObject(t) = &*r.elem else {
            return Err("local callback must use dyn FnMut".into());
        };
        if t.dyn_token.is_none() {
            return Err("local callback must use explicit dyn".into());
        }
        &t.bounds
    } else {
        let Type::ImplTrait(t) = ty else {
            return Err("owned callback must use impl FnMut".into());
        };
        &t.bounds
    };
    let bounds: Vec<_> = bounds.iter().collect();
    let [syn::TypeParamBound::Trait(t)] = bounds.as_slice() else {
        return Err("callback needs exactly one FnMut bound".into());
    };
    if t.lifetimes.is_some()
        || !matches!(t.modifier, syn::TraitBoundModifier::None)
        || t.path.leading_colon.is_some()
        || t.path.segments.len() != 1
        || t.path.segments[0].ident != "FnMut"
    {
        return Err("callback needs builtin FnMut".into());
    }
    let syn::PathArguments::Parenthesized(a) = &t.path.segments[0].arguments else {
        return Err("callback needs a concrete argument and bool output".into());
    };
    if a.inputs.len() != 1 || !matches!(&a.output,syn::ReturnType::Type(_,ty) if tokens(ty)=="bool")
    {
        return Err("callback must take one key and return bool".into());
    }
    Ok(&a.inputs[0])
}
fn local(stmt: &syn::Stmt) -> Result<(String, &Expr), String> {
    let syn::Stmt::Local(local) = stmt else {
        return Err("predicate fold needs its original local binding".into());
    };
    attrs(&local.attrs)?;
    let name = binding(&local.pat)?;
    let init = local
        .init
        .as_ref()
        .ok_or("missing predicate local initializer")?;
    if init.diverge.is_some() {
        return Err("predicate let-else unsupported".into());
    }
    Ok((name, &init.expr))
}
fn block_value(block: &syn::Block) -> Result<&Expr, String> {
    let [syn::Stmt::Expr(value, None)] = block.stmts.as_slice() else {
        return Err("predicate branch must be a pure expression".into());
    };
    Ok(value)
}
fn typed_binding(pat: &syn::Pat) -> Result<(String, &Type), String> {
    let syn::Pat::Type(p) = pat else {
        return Err("local fold parameters need explicit types".into());
    };
    attrs(&p.attrs)?;
    Ok((binding(&p.pat)?, &p.ty))
}
fn round_call(expr: &Expr, round: &str, callback: &str, selector: bool) -> Result<(), String> {
    let Expr::Call(c) = expr else {
        return Err("fold must call its local round".into());
    };
    attrs(&c.attrs)?;
    if !named(&c.func, round)
        || c.args.len() != 2
        || !matches!(&c.args[0],Expr::Lit(l) if l.attrs.is_empty() && matches!(&l.lit,syn::Lit::Bool(b) if b.value==selector))
    {
        return Err("fold round selector or local callee changed".into());
    }
    let Expr::Reference(r) = &c.args[1] else {
        return Err("fold must reborrow the owned callback".into());
    };
    attrs(&r.attrs)?;
    if r.mutability.is_none() || !named(&r.expr, callback) {
        return Err("fold must mutably reborrow its callback".into());
    }
    Ok(())
}
impl Crate {
    fn predicate_namespaces(&self) -> Result<(), String> {
        self.iterator_traits()?;
        for ((_, name), path) in &self.imports {
            if ["FnMut", "Clone"].contains(&name.as_str()) {
                let module = if name == "FnMut" { "ops" } else { "clone" };
                if path.len() != 3
                    || !["core", "std"].contains(&path[0].as_str())
                    || path[1] != module
                    || path[2] != *name
                {
                    return Err("predicate callback/clone trait import is not canonical".into());
                }
            }
        }
        for source in self.files.values() {
            for item in syn::parse_file(source).map_err(|e| e.to_string())?.items {
                match item {
                Item::Trait(t) if !test_only(&t.attrs) && (["FnMut","Clone"].iter().any(|n|t.ident==*n) || t.items.iter().any(|i|matches!(i,syn::TraitItem::Fn(f) if ["clone","count"].iter().any(|n|f.sig.ident==*n))))=>return Err("predicate iterator/callback traits are shadowed".into()),
                Item::Impl(i) if !test_only(&i.attrs) && i.trait_.is_some()=>{
                    let canonical_clone=i.trait_.as_ref().is_some_and(|(_,p,_)|p.is_ident("Clone") || tokens(p)=="core :: clone :: Clone" || tokens(p)=="std :: clone :: Clone");
                    if i.items.iter().any(|i|matches!(i,syn::ImplItem::Fn(f) if f.sig.ident=="count" || (f.sig.ident=="clone" && !canonical_clone))){return Err("predicate standard operations may resolve to user code".into());}
                }
                _=>{}
            }
            }
        }
        Ok(())
    }
    pub(super) fn lower_predicate_fold(&self, name: &str) -> Result<Method, String> {
        let def = self.methods.get(name).ok_or("unknown predicate fold")?;
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
            return Err("predicate fold requires concrete shared array and owned callback".into());
        }
        let args: Vec<_> = sig.inputs.iter().collect();
        let [syn::FnArg::Receiver(receiver), syn::FnArg::Typed(callback)] = args.as_slice() else {
            return Err("predicate fold needs &self and one owned callback".into());
        };
        attrs(&receiver.attrs)?;
        attrs(&callback.attrs)?;
        if receiver.reference.is_none()
            || receiver.mutability.is_some()
            || receiver.colon_token.is_some()
        {
            return Err("predicate fold needs &self".into());
        }
        let syn::Pat::Ident(cb) = &*callback.pat else {
            return Err("predicate callback needs a mutable binding".into());
        };
        attrs(&cb.attrs)?;
        if cb.mutability.is_none() || cb.by_ref.is_some() || cb.subpat.is_some() {
            return Err("predicate callback must be a plain mutable owned parameter".into());
        }
        let callback_name = cb.ident.to_string();
        let key_type =
            self.projection_value_type(&def.module, callback_type(&callback.ty, false)?)?;
        let [round, syn::Stmt::Expr(result, None)] = f.block.stmts.as_slice() else {
            return Err("predicate fold must retain local closure and final expression".into());
        };
        let (round_name, round) = local(round)?;
        if round_name == callback_name {
            return Err("predicate round shadows callback".into());
        }
        let Expr::Closure(round) = round else {
            return Err("predicate round must be an explicit local closure".into());
        };
        attrs(&round.attrs)?;
        if round.asyncness.is_some()
            || round.constness.is_some()
            || round.capture.is_some()
            || round.movability.is_some()
            || round.lifetimes.is_some()
            || round.inputs.len() != 2
            || !matches!(round.output, syn::ReturnType::Default)
        {
            return Err("predicate round must retain two plain typed parameters".into());
        }
        let (selector, selector_type) = typed_binding(&round.inputs[0])?;
        let (local_callback, local_callback_type) = typed_binding(&round.inputs[1])?;
        if tokens(selector_type) != "bool"
            || selector == local_callback
            || self.projection_value_type(&def.module, callback_type(local_callback_type, true)?)?
                != key_type
        {
            return Err("predicate round selector or callback types disagree".into());
        }
        let Expr::Block(block) = &*round.body else {
            return Err("predicate round needs its complete block".into());
        };
        attrs(&block.attrs)?;
        if block.label.is_some() {
            return Err("predicate labeled block unsupported".into());
        }
        let [iter, total, count, syn::Stmt::Expr(comparison, None)] = block.block.stmts.as_slice()
        else {
            return Err("predicate round must retain projection, cloned total, callback count and comparison".into());
        };
        let (iter_name, iter) = local(iter)?;
        let (total_name, total) = local(total)?;
        let (count_name, count) = local(count)?;
        let mut bindings = vec![selector.clone(), local_callback.clone()];
        for name in [&iter_name, &total_name, &count_name] {
            if bindings.contains(name) {
                return Err("predicate locals shadow an enclosing binding".into());
            }
            bindings.push(name.clone());
        }
        let filter = method(iter, "filter", 1)?;
        let flatten = method(&filter.receiver, "flatten", 0)?;
        let iter = method(&flatten.receiver, "iter", 0)?;
        let field = path(&iter.receiver)?;
        if field.len() != 1 {
            return Err("predicate fold must use a direct array field".into());
        }
        let Type::Array(array) = self.field_type(def, &field)? else {
            return Err("predicate fold requires a builtin array".into());
        };
        let record_type = projections::option_payload(&array.elem)?;
        let record_name = base_type(record_type)?;
        if tokens(record_type) != record_name {
            return Err("predicate slots need a concrete source record".into());
        }
        let record = self.resolve(&def.module, &record_name, 0)?;
        let record_struct = self
            .structs
            .get(&record)
            .ok_or("predicate slot must be a source struct")?;
        if !record_struct.generics.params.is_empty() {
            return Err("predicate record generics require substitution".into());
        }
        let record_def = Definition {
            module: self.struct_modules[&record].clone(),
            file: def.file.clone(),
            item: f.clone(),
            receiver: record.clone(),
            impl_generics: syn::Generics::default(),
            self_type: None,
        };
        let filter = projections::closure(&filter.args[0])?;
        let member = binding(&filter.inputs[0])?;
        if member == selector {
            return Err("predicate member shadows selector".into());
        }
        let Expr::If(choice) = &*filter.body else {
            return Err("predicate filter needs the original selector branch".into());
        };
        attrs(&choice.attrs)?;
        if !named(&choice.cond, &selector) {
            return Err("predicate filter must use its selector".into());
        }
        let (_, otherwise) = choice
            .else_branch
            .as_ref()
            .ok_or("predicate selection needs both branches")?;
        let Expr::Block(otherwise) = &**otherwise else {
            return Err("predicate else must be a plain block".into());
        };
        attrs(&otherwise.attrs)?;
        if otherwise.label.is_some() {
            return Err("predicate branch label unsupported".into());
        }
        let second = self.condition(
            &record_def,
            &relative(block_value(&choice.then_branch)?, &member),
        )?;
        let first = self.condition(
            &record_def,
            &relative(block_value(&otherwise.block)?, &member),
        )?;
        let total = method(total, "count", 0)?;
        let cloned = method(&total.receiver, "clone", 0)?;
        if !named(&cloned.receiver, &iter_name) {
            return Err("predicate total must count a clone of the selected iterator".into());
        }
        let count = method(count, "count", 0)?;
        let accepted = method(&count.receiver, "filter", 1)?;
        if !named(&accepted.receiver, &iter_name) {
            return Err("predicate callback count must consume the original iterator".into());
        }
        let accepted = projections::closure(&accepted.args[0])?;
        let member = binding(&accepted.inputs[0])?;
        if member == local_callback {
            return Err("predicate member shadows callback".into());
        }
        let Expr::Call(call) = &*accepted.body else {
            return Err("predicate filter must invoke its callback".into());
        };
        attrs(&call.attrs)?;
        if !named(&call.func, &local_callback) || call.args.len() != 1 {
            return Err("predicate must invoke the local callback once per key".into());
        }
        let key = path(&relative(&call.args[0], &member))?;
        if key.is_empty()
            || self
                .projection_value_type(&record_def.module, self.field_type(&record_def, &key)?)?
                != key_type
        {
            return Err("predicate callback key type mismatch".into());
        }
        let Expr::Binary(compare) = comparison else {
            return Err("predicate round must compare count and threshold".into());
        };
        attrs(&compare.attrs)?;
        let inclusive = match compare.op {
            syn::BinOp::Gt(_) => false,
            syn::BinOp::Ge(_) => true,
            _ => return Err("predicate comparison must be > or >=".into()),
        };
        if !named(&compare.left, &count_name) {
            return Err("predicate comparison must inspect its callback count".into());
        }
        let (total, divisor) = binary(&compare.right, "/")?;
        if !named(total, &total_name) {
            return Err("predicate threshold must divide its cloned total".into());
        }
        let Expr::Lit(divisor) = divisor else {
            return Err("predicate divisor must be a positive usize constant".into());
        };
        attrs(&divisor.attrs)?;
        let syn::Lit::Int(divisor) = &divisor.lit else {
            return Err("predicate divisor must be an integer".into());
        };
        if !divisor.suffix().is_empty() && divisor.suffix() != "usize" {
            return Err("predicate divisor must be usize".into());
        }
        let divisor: u64 = divisor.base10_parse().map_err(|e| e.to_string())?;
        if divisor == 0 {
            return Err("zero predicate divisor requires division-panic semantics".into());
        }
        let (first_call, rest) = binary(result, "&&")?;
        round_call(first_call, &round_name, &callback_name, false)?;
        let Expr::Paren(rest) = rest else {
            return Err(
                "predicate second round needs its original parenthesized short circuit".into(),
            );
        };
        attrs(&rest.attrs)?;
        let (guard, second_call) = binary(&rest.expr, "||")?;
        round_call(second_call, &round_name, &callback_name, true)?;
        let Expr::Unary(negation) = guard else {
            return Err("predicate gate must negate its source query".into());
        };
        attrs(&negation.attrs)?;
        if !matches!(negation.op, syn::UnOp::Not(_)) {
            return Err("predicate gate must negate its source query".into());
        }
        let Expr::MethodCall(gate) = &*negation.expr else {
            return Err("predicate gate must call a source-local query".into());
        };
        let gate = method(&negation.expr, &gate.method.to_string(), 0)?;
        if !named(&gate.receiver, "self") {
            return Err("predicate gate must read its receiver".into());
        }
        let guard_name = format!("{}::{}::{}", def.module, def.receiver, gate.method)
            .trim_start_matches("::")
            .to_string();
        let guard = self.lower_array_query(&guard_name)?;
        let shape = guard.array.as_ref().ok_or("missing predicate gate shape")?;
        if shape.key.is_some()
            || shape.field != field[0]
            || shape.record != record
            || shape.capacity != tokens(&array.len)
        {
            return Err("predicate gate must be a pure query over the same array".into());
        }
        let fold = Fold {
            first,
            second,
            key,
            divisor,
            inclusive,
            callback: callback_name,
            key_type,
            guard: Box::new(guard),
        };
        Ok(Method{name:name.into(),symbol:name.replace("::","_"),source:def.file.clone(),first_line:f.span().start().line,last_line:f.span().end().line,rust:tokens(f),writes:vec![],body:vec![],iteration:None,last:None,truncation:None,installation:None,restoration:None,enum_projection:None,validator:None,view:None,record_at:None,lookup:None,selection:None,relocation:None,buffer:None,constructor:None,query:None,array:Some(arrays::Shape{field:field[0].clone(),capacity:tokens(&array.len),record,predicate:None,projection:None,preserve_slots:false,key:None,upsert:None,batch:None,rebuild:None,merge:None,fold:Some(Box::new(fold)),scope:"complete owned FnMut predicate fold with cloned total, ordered calls, shared reborrows and drop/unwind/abort protocol; Rust ownership, target-width and source refinement remain open"})})
    }
}
pub(super) fn generate(name: &str, fold: &Fold) -> String {
    let mut output =
        arrays::generate(&fold.guard).replace(&fold.guard.symbol, &format!("{name}_guard"));
    let first = condition(&fold.first);
    let second = condition(&fold.second);
    let key = lean_path(&fold.key);
    output.push_str(&format!("def {name}_ir : PredicateFold := {{ first := ⟨{first}, {key}⟩, second := ⟨{second}, {key}⟩, secondRequired := {name}_guard_ir, divisor := {}, divisorPositive := (by decide), inclusive := {} }}\ndef {name} (entries : ArrayStore α) (callback : σ) : PredicateRun α σ := runPredicateFold {name}_ir entries callback\ntheorem {name}_correspondence (entries : ArrayStore α) (callback : σ) : runPredicateFold {name}_ir entries callback = {name} entries callback := by rfl\n",fold.divisor,fold.inclusive));
    output
}
