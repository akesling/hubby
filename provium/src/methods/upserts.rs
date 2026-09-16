//! Existing-key-first insertion into optional record arrays. Every initializer,
//! search, branch and error must be retained; general callbacks are unsupported.
use super::arrays::{binding, copy_derived, named, relative};
use super::lookups::method;
use super::*;

#[derive(Debug, Serialize)]
pub struct Upsert {
    pub key: Vec<String>,
    pub initial: Vec<Write>,
    pub cases: Vec<(u8, Write)>,
    pub fallback: Write,
    pub error: String,
}

pub(super) fn candidate(item: &syn::ImplItemFn) -> bool {
    use syn::visit::Visit;
    struct Find(bool);
    impl<'ast> Visit<'ast> for Find {
        fn visit_expr_method_call(&mut self, call: &'ast syn::ExprMethodCall) {
            self.0 |= call.method == "get_or_insert";
            syn::visit::visit_expr_method_call(self, call);
        }
    }
    let mut find = Find(false);
    find.visit_block(&item.block);
    find.0
}
fn local(stmt: &syn::Stmt) -> Result<(String, &Expr), String> {
    let syn::Stmt::Local(local) = stmt else {
        return Err("upsert requires a bound intermediate value".into());
    };
    attrs(&local.attrs)?;
    let name = binding(&local.pat)?;
    let init = local.init.as_ref().ok_or("missing upsert initializer")?;
    if init.diverge.is_some() {
        return Err("upsert let-else unsupported".into());
    }
    Ok((name, &init.expr))
}
fn closure(expr: &Expr, count: usize) -> Result<&syn::ExprClosure, String> {
    let Expr::Closure(c) = expr else {
        return Err("upsert requires an explicit closure".into());
    };
    attrs(&c.attrs)?;
    if c.inputs.len() != count
        || c.asyncness.is_some()
        || c.constness.is_some()
        || c.movability.is_some()
        || c.capture.is_some()
        || c.lifetimes.is_some()
        || !matches!(c.output, syn::ReturnType::Default)
    {
        return Err("upsert closure effects/capture unsupported".into());
    }
    Ok(c)
}
fn flag_write(def: &Definition, krate: &Crate, expr: &Expr, member: &str) -> Result<Write, String> {
    let Expr::Assign(a) = expr else {
        return Err("upsert arm must assign one boolean field".into());
    };
    attrs(&a.attrs)?;
    if !matches!(&*a.left, Expr::Field(f) if named(&f.base, member)) {
        return Err("upsert assignment must target its selected record binding".into());
    }
    let p = path(&relative(&a.left, member))?;
    if p.len() != 1 || tokens(krate.field_type(def, &p)?) != "bool" {
        return Err("upsert assignment needs a direct boolean field".into());
    }
    let Expr::Lit(lit) = &*a.right else {
        return Err("upsert flag must be a boolean literal".into());
    };
    attrs(&lit.attrs)?;
    let syn::Lit::Bool(value) = &lit.lit else {
        return Err("upsert flag must be boolean".into());
    };
    Ok(Write {
        rust_type: "bool".into(),
        line: a.span().start().line,
        path: p,
        literal: Literal::Boolean(value.value),
    })
}
impl Crate {
    pub(super) fn lower_upsert(&self, name: &str) -> Result<Method, String> {
        let def = self.methods.get(name).ok_or("unknown upsert")?;
        let f = &def.item;
        let sig = &f.sig;
        attrs(&f.attrs)?;
        self.iterator_traits()?;
        if sig.asyncness.is_some()
            || sig.unsafety.is_some()
            || sig.constness.is_some()
            || sig.abi.is_some()
            || !sig.generics.params.is_empty()
            || sig.generics.where_clause.is_some()
        {
            return Err("upsert requires a plain method".into());
        }
        let args: Vec<_> = sig.inputs.iter().collect();
        let [syn::FnArg::Receiver(receiver), syn::FnArg::Typed(key), syn::FnArg::Typed(tag)] =
            args.as_slice()
        else {
            return Err("upsert needs &mut self, key and u8 tag".into());
        };
        attrs(&receiver.attrs)?;
        attrs(&key.attrs)?;
        attrs(&tag.attrs)?;
        if receiver.reference.is_none()
            || receiver.mutability.is_none()
            || receiver.colon_token.is_some()
            || tokens(&tag.ty) != "u8"
        {
            return Err("upsert needs &mut self and a u8 tag".into());
        }
        let key_name = binding(&key.pat)?;
        let tag_name = binding(&tag.pat)?;
        if def.impl_generics.type_params().next().is_some() {
            return Err("upsert generic type substitution unsupported".into());
        }
        let key_type = self.equality_value(&def.module, &key.ty)?;
        let error_type = self.resolve(&def.module, &queries::result_error(&sig.output)?, 0)?;
        if self.drops.contains(&error_type) {
            return Err(
                "upsert eager error construction requires a non-dropping error variant".into(),
            );
        }
        let [first, second, syn::Stmt::Expr(Expr::Match(branches), _), syn::Stmt::Expr(success, None)] =
            f.block.stmts.as_slice()
        else {
            return Err(
                "upsert requires complete search, insertion, flag dispatch and success".into(),
            );
        };
        if tokens(success) != "Ok (())" {
            return Err("upsert must return unit success".into());
        }
        let (slot_name, search) = local(first)?;
        let Expr::Try(search) = search else {
            return Err("upsert must propagate a full-array error".into());
        };
        attrs(&search.attrs)?;
        let or_error = method(&search.expr, "ok_or", 1)?;
        let error_path = match &or_error.args[0] {
            Expr::Path(p) if p.qself.is_none() => {
                attrs(&p.attrs)?;
                &p.path
            }
            _ => return Err("upsert requires a unit error variant".into()),
        };
        if error_path.segments.len() != 2
            || error_path.leading_colon.is_some()
            || error_path
                .segments
                .iter()
                .any(|s| !matches!(s.arguments, syn::PathArguments::None))
        {
            return Err("upsert requires a resolved error enum variant".into());
        }
        if self.resolve(&def.module, &error_path.segments[0].ident.to_string(), 0)? != error_type {
            return Err("upsert error type mismatch".into());
        }
        let error = error_path.segments[1].ident.to_string();
        let variant = self
            .enums
            .get(&error_type)
            .and_then(|e| e.variants.iter().find(|v| v.ident == error))
            .ok_or("unknown upsert error variant")?;
        attrs(&variant.attrs)?;
        if !matches!(variant.fields, syn::Fields::Unit) {
            return Err("upsert error must be a unit variant".into());
        }
        let fallback = method(&or_error.receiver, "or_else", 1)?;
        let position = method(&fallback.receiver, "position", 1)?;
        let iter = method(&position.receiver, "iter", 0)?;
        let field = path(&iter.receiver)?;
        if field.len() != 1 {
            return Err("upsert needs a direct array field".into());
        }
        let Type::Array(array) = self.field_type(def, &field)? else {
            return Err("upsert needs a builtin array".into());
        };
        let record_name = records::output_record(&syn::ReturnType::Type(
            Default::default(),
            array.elem.clone(),
        ))?;
        let record = self.resolve(&def.module, &record_name, 0)?;
        let structure = self
            .structs
            .get(&record)
            .ok_or("upsert slot must be a record")?;
        if !structure.generics.params.is_empty()
            || !copy_derived(structure)
            || self.drops.contains(&record)
        {
            return Err("upsert requires a concrete Copy record without Drop".into());
        }
        let record_def = Definition {
            module: self.struct_modules[&record].clone(),
            file: def.file.clone(),
            item: f.clone(),
            receiver: record.clone(),
            impl_generics: syn::Generics::default(),
            self_type: None,
        };
        let predicate = closure(&position.args[0], 1)?;
        let slot_binding = binding(&predicate.inputs[0])?;
        let some = method(&predicate.body, "is_some_and", 1)?;
        if !named(&some.receiver, &slot_binding) {
            return Err("upsert search must inspect its current slot".into());
        }
        let equal = closure(&some.args[0], 1)?;
        let member_binding = binding(&equal.inputs[0])?;
        if [slot_binding.as_str(), member_binding.as_str()].contains(&key_name.as_str()) {
            return Err("upsert key is shadowed".into());
        }
        let Expr::Binary(eq) = &*equal.body else {
            return Err("upsert search needs structural equality".into());
        };
        attrs(&eq.attrs)?;
        if !matches!(&*eq.left, Expr::Field(f) if named(&f.base, &member_binding)) {
            return Err("upsert equality must read its current record binding".into());
        }
        if !matches!(eq.op, syn::BinOp::Eq(_)) || !named(&eq.right, &key_name) {
            return Err("upsert search must compare key equality".into());
        }
        let key_field = path(&relative(&eq.left, &member_binding))?;
        if key_field.len() != 1
            || self.equality_value(
                &record_def.module,
                self.field_type(&record_def, &key_field)?,
            )? != key_type
        {
            return Err("upsert record key type mismatch".into());
        }
        let empty = closure(&fallback.args[0], 0)?;
        let empty_position = method(&empty.body, "position", 1)?;
        if tokens(&empty_position.args[0]) != "Option :: is_none" {
            return Err("upsert fallback must find an empty slot".into());
        }
        let empty_iter = method(&empty_position.receiver, "iter", 0)?;
        if path(&empty_iter.receiver)? != field {
            return Err("upsert searches must use the same array".into());
        }
        let (member_name, insert) = local(second)?;
        if [key_name.as_str(), tag_name.as_str(), slot_name.as_str()]
            .contains(&member_name.as_str())
            || slot_name == key_name
            || slot_name == tag_name
        {
            return Err("upsert locals shadow inputs".into());
        }
        let insert = method(insert, "get_or_insert", 1)?;
        let Expr::Index(index) = &*insert.receiver else {
            return Err("upsert must index its selected slot".into());
        };
        attrs(&index.attrs)?;
        if path(&index.expr)? != field || !named(&index.index, &slot_name) {
            return Err("upsert must update the selected array slot".into());
        }
        let Expr::Struct(initial) = &insert.args[0] else {
            return Err("upsert requires an explicit record initializer".into());
        };
        attrs(&initial.attrs)?;
        if initial.qself.is_some() || initial.rest.is_some() || !initial.path.is_ident(&record_name)
        {
            return Err("upsert must initialize the declared slot record".into());
        }
        let mut initialized = std::collections::BTreeSet::new();
        let mut writes = Vec::new();
        for value in &initial.fields {
            attrs(&value.attrs)?;
            let syn::Member::Named(field_name) = &value.member else {
                return Err("upsert needs named record fields".into());
            };
            let field_name = field_name.to_string();
            if !initialized.insert(field_name.clone()) {
                return Err("duplicate upsert field".into());
            }
            if key_field == [field_name.clone()] {
                if !named(&value.expr, &key_name) {
                    return Err("upsert initializer must retain input key".into());
                }
            } else {
                let target: Expr = syn::parse_str(&format!("{member_name}.{field_name}"))
                    .map_err(|e| e.to_string())?;
                let rhs = &value.expr;
                let assignment: Expr = syn::parse_quote!(#target = #rhs);
                writes.push(flag_write(&record_def, self, &assignment, &member_name)?);
            }
        }
        if initialized.len() != structure.fields.len() || !initialized.contains(&key_field[0]) {
            return Err("upsert initializer must cover every record field".into());
        }
        attrs(&branches.attrs)?;
        if !named(&branches.expr, &tag_name) {
            return Err("upsert must dispatch its input tag".into());
        }
        let mut cases = Vec::new();
        let mut default = None;
        for arm in &branches.arms {
            attrs(&arm.attrs)?;
            if arm.guard.is_some() || default.is_some() {
                return Err("upsert needs unguarded tag cases and final wildcard".into());
            }
            let write = flag_write(&record_def, self, &arm.body, &member_name)?;
            if write.path == key_field {
                return Err("upsert must preserve identity".into());
            }
            match &arm.pat {
                syn::Pat::Lit(lit) => {
                    attrs(&lit.attrs)?;
                    let syn::Lit::Int(tag) = &lit.lit else {
                        return Err("upsert tag must be u8".into());
                    };
                    if !tag.suffix().is_empty() && tag.suffix() != "u8" {
                        return Err("upsert tag must be u8".into());
                    }
                    let tag = tag.base10_parse::<u8>().map_err(|e| e.to_string())?;
                    if cases.iter().any(|(n, _)| *n == tag) {
                        return Err("duplicate upsert tag".into());
                    }
                    cases.push((tag, write));
                }
                syn::Pat::Wild(w) => {
                    attrs(&w.attrs)?;
                    default = Some(write);
                }
                _ => return Err("upsert supports literal tags and a wildcard".into()),
            }
        }
        let upsert = Upsert {
            key: key_field,
            initial: writes,
            cases,
            fallback: default.ok_or("upsert requires a fallback arm")?,
            error,
        };
        Ok(Method { name:name.into(),symbol:name.replace("::","_"),source:def.file.clone(),first_line:f.span().start().line,last_line:f.span().end().line,rust:tokens(f),writes:vec![],body:vec![],
            iteration:None,last:None,truncation:None,installation:None,restoration:None,enum_projection:None,validator:None,view:None,record_at:None,lookup:None,selection:None,relocation:None,buffer:None,constructor:None,query:None,
            array:Some(arrays::Shape{field:field[0].clone(),capacity:tokens(&array.len),record,predicate:None,projection:None,preserve_slots:false,key:None,upsert:Some(upsert),batch:None,rebuild:None,scope:"complete existing-key-first optional Copy-record upsert; structural equality and indexed update denotation; Rust source/ownership/layout refinement remains open"}) })
    }
}
pub(super) fn generate(name: &str, ir: &Upsert) -> String {
    let initial = ir.initial.iter().map(write).collect::<Vec<_>>().join(", ");
    let cases = ir
        .cases
        .iter()
        .map(|(n, w)| format!("({n}, {})", write(w)))
        .collect::<Vec<_>>()
        .join(", ");
    format!("def {name}_ir : Upsert := ⟨{}, [{initial}], [{cases}], {}, {}⟩\ndef {name} [DecidableEq α] (entries : ArrayStore α) (key : Cell α) (tag : Nat) : ArrayStore α × Option String :=\n  runUpsert {name}_ir entries key tag\ntheorem {name}_correspondence [DecidableEq α] (entries : ArrayStore α) (key : Cell α) (tag : Nat) : runUpsert {name}_ir entries key tag = {name} entries key tag := by rfl\n",lean_path(&ir.key),write(&ir.fallback),serde_json::to_string(&ir.error).unwrap())
}

fn write(w: &Write) -> String {
    format!("⟨{}, {}⟩", lean_path(&w.path), literal(&w.literal))
}
