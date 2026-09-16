//! Whole traversal of a Copy record array with optional entries.
//! The reserved `$present` leaf cannot collide with a Rust field identifier.
use super::key_queries::KeyQuery;
use super::*;
use syn::{visit_mut::VisitMut, Pat, Stmt};
#[derive(Debug, Serialize)]
pub struct Shape {
    pub field: String,
    pub capacity: String,
    pub record: String,
    pub scope: &'static str,
    pub predicate: Option<Condition>,
    pub projection: Option<Vec<String>>,
    pub preserve_slots: bool,
    pub key: Option<KeyQuery>,
    pub upsert: Option<super::upserts::Upsert>,
    pub batch: Option<super::slot_batches::Batch>,
    pub rebuild: Option<Box<super::rebuilds::Rebuild>>,
    pub merge: Option<Box<super::merges::Merge>>,
}
pub(super) fn copy_derived(item: &syn::ItemStruct) -> bool {
    item.attrs.iter().any(|a| {
        a.path().is_ident("derive")
            && a.parse_args_with(
                syn::punctuated::Punctuated::<syn::Ident, syn::Token![,]>::parse_terminated,
            )
            .is_ok_and(|ds| ds.iter().any(|d| d == "Copy"))
    })
}
pub(super) fn binding(p: &Pat) -> Result<String, String> {
    let Pat::Ident(p) = p else {
        return Err("array traversal requires identifier bindings".into());
    };
    attrs(&p.attrs)?;
    if p.by_ref.is_some() || p.mutability.is_some() || p.subpat.is_some() {
        return Err("unsupported array binding pattern".into());
    }
    Ok(p.ident.to_string())
}
pub(super) fn named(expr: &Expr, name: &str) -> bool {
    matches!(expr,Expr::Path(p) if p.qself.is_none() && p.path.is_ident(name) && p.attrs.is_empty())
}
pub(super) fn relative(expr: &Expr, name: &str) -> Expr {
    struct Rename<'a>(&'a str);
    impl VisitMut for Rename<'_> {
        fn visit_expr_mut(&mut self, e: &mut Expr) {
            if named(e, self.0) {
                *e = syn::parse_quote!(self);
            } else if named(e, "self") {
                // The closure's captured receiver is not its record parameter.
                // Preserve that distinction by making it ineligible as a
                // record-store path after rebasing the parameter above.
                *e = syn::parse_quote!(__provium_captured_receiver);
            } else {
                syn::visit_mut::visit_expr_mut(self, e);
            }
        }
    }
    let mut e = expr.clone();
    Rename(name).visit_expr_mut(&mut e);
    e
}
impl Crate {
    pub(super) fn lower_array_query(&self, name: &str) -> Result<Method, String> {
        if self.array_iterator_shadow {
            return Err("custom iterator methods require trait resolution".into());
        }
        self.iterator_traits()?;
        let def = self.methods.get(name).ok_or("unknown array query")?;
        let f = &def.item;
        attrs(&f.attrs)?;
        let sig = &f.sig;
        if sig.asyncness.is_some()
            || sig.unsafety.is_some()
            || sig.constness.is_some()
            || sig.abi.is_some()
            || !sig.generics.params.is_empty()
            || sig.generics.where_clause.is_some()
            || !(1..=2).contains(&sig.inputs.len())
            || !matches!(&sig.output,syn::ReturnType::Type(_,ty) if matches!(&**ty,Type::Path(p) if p.path.is_ident("bool")))
        {
            return Err("array query requires a boolean method with &self and at most one identity argument".into());
        }
        let Some(syn::FnArg::Receiver(receiver)) = sig.inputs.first() else {
            return Err("missing receiver".into());
        };
        attrs(&receiver.attrs)?;
        if receiver.reference.is_none()
            || receiver.mutability.is_some()
            || receiver.colon_token.is_some()
        {
            return Err("array query requires &self".into());
        }
        let [Stmt::Expr(Expr::MethodCall(any), None)] = f.block.stmts.as_slice() else {
            return Err("array query requires a complete iterator any expression".into());
        };
        fn call(call: &syn::ExprMethodCall, name: &str, args: usize) -> Result<(), String> {
            attrs(&call.attrs)?;
            if call.method != name || call.args.len() != args || call.turbofish.is_some() {
                return Err("unsupported array iterator chain".into());
            }
            Ok(())
        }
        call(any, "any", 1)?;
        let Expr::MethodCall(flatten) = &*any.receiver else {
            return Err("expected flatten".into());
        };
        call(flatten, "flatten", 0)?;
        let Expr::MethodCall(iter) = &*flatten.receiver else {
            return Err("expected iter".into());
        };
        call(iter, "iter", 0)?;
        let p = path(&iter.receiver)?;
        if p.len() != 1 {
            return Err("query requires a direct receiver array field".into());
        }
        let resolved = self.resolve(&def.module, &def.receiver, 0)?;
        let structure = &self.structs[&resolved];
        if structure.fields.len() != 1 {
            return Err("array receiver must have one field".into());
        }
        let Type::Array(array) = self.field_type(def, &p)? else {
            return Err("query requires array".into());
        };
        let Type::Path(option) = &*array.elem else {
            return Err("query requires Option<Record>".into());
        };
        if option.qself.is_some()
            || option.path.leading_colon.is_some()
            || option.path.segments.len() != 1
            || option.path.segments[0].ident != "Option"
        {
            return Err("query requires builtin Option".into());
        }
        let syn::PathArguments::AngleBracketed(args) = &option.path.segments[0].arguments else {
            return Err("missing record type".into());
        };
        let arguments = args.args.iter().collect::<Vec<_>>();
        let [syn::GenericArgument::Type(ty)] = arguments.as_slice() else {
            return Err("expected one record type".into());
        };
        let record = self.resolve(&def.module, &base_type(ty)?, 0)?;
        let record_type = self
            .structs
            .get(&record)
            .ok_or("array query needs a source record struct")?;
        if !record_type.generics.params.is_empty() {
            return Err("generic record queries unsupported".into());
        }
        let Expr::Closure(closure) = &any.args[0] else {
            return Err("query requires a record predicate closure".into());
        };
        attrs(&closure.attrs)?;
        if closure.asyncness.is_some()
            || closure.constness.is_some()
            || closure.movability.is_some()
            || closure.capture.is_some()
            || closure.lifetimes.is_some()
            || closure.inputs.len() != 1
            || !matches!(closure.output, syn::ReturnType::Default)
        {
            return Err("unsupported query closure".into());
        }
        let member = binding(&closure.inputs[0])?;
        let record_def = Definition {
            module: self.struct_modules[&record].clone(),
            file: def.file.clone(),
            item: f.clone(),
            receiver: record.clone(),
            impl_generics: syn::Generics::default(),
            self_type: None,
        };
        let (key, predicate) = if sig.inputs.len() == 2 {
            let (key, predicate) = self.key_query(def, &record_def, &closure.body, &member)?;
            (Some(key), predicate)
        } else {
            (
                None,
                self.condition(&record_def, &relative(&closure.body, &member))?,
            )
        };
        Ok(Method{name:name.into(),symbol:name.replace("::","_"),source:def.file.clone(),first_line:f.span().start().line,last_line:f.span().end().line,rust:tokens(f),writes:vec![],body:vec![],
            iteration:None,last:None,truncation:None,installation:None,restoration:None,enum_projection:None,validator:None,view:None,record_at:None,lookup:None,selection:None,relocation:None,buffer:None,constructor:None,query:None,array:Some(Shape{field:p[0].clone(),capacity:tokens(&array.len),record,predicate:Some(predicate),projection:None,preserve_slots:false,key,upsert:None,batch:None,rebuild:None,merge:None,scope:"complete shared optional-record array iterator query; Rust layout/borrowing and frontend refinement remain trusted"})})
    }
    pub(super) fn lower_array(&self, name: &str) -> Result<Method, String> {
        let def = self.methods.get(name).ok_or("unknown array method")?;
        let f = &def.item;
        attrs(&f.attrs)?;
        let sig = &f.sig;
        if sig.asyncness.is_some()
            || sig.unsafety.is_some()
            || sig.constness.is_some()
            || sig.abi.is_some()
            || !sig.generics.params.is_empty()
            || sig.generics.where_clause.is_some()
            || sig.inputs.len() != 1
            || !matches!(&sig.output,syn::ReturnType::Type(_,ty) if matches!(&**ty,Type::Path(p) if p.path.is_ident("Self")))
        {
            return Err("array traversal requires a receiver-only method returning Self".into());
        }
        let Some(syn::FnArg::Receiver(receiver)) = sig.inputs.first() else {
            return Err("missing receiver".into());
        };
        attrs(&receiver.attrs)?;
        if receiver.reference.is_some()
            || receiver.mutability.is_none()
            || receiver.colon_token.is_some()
        {
            return Err("array traversal requires mut self".into());
        }
        let resolved = self.resolve(&def.module, &def.receiver, 0)?;
        let structure = &self.structs[&resolved];
        if structure.fields.len() != 1 || !copy_derived(structure) || self.drops.contains(&resolved)
        {
            return Err("array receiver must have one field and derive builtin Copy".into());
        }
        let [Stmt::Expr(Expr::ForLoop(loop_), _), Stmt::Expr(result, None)] =
            f.block.stmts.as_slice()
        else {
            return Err("array method requires one complete traversal followed by self".into());
        };
        attrs(&loop_.attrs)?;
        if loop_.label.is_some() || !named(result, "self") {
            return Err("unsupported array traversal label/return".into());
        }
        let slot = binding(&loop_.pat)?;
        let Expr::Reference(reference) = &*loop_.expr else {
            return Err("expected mutable array borrow".into());
        };
        attrs(&reference.attrs)?;
        if reference.mutability.is_none() {
            return Err("array traversal needs exclusive access".into());
        }
        let array_path = path(&reference.expr)?;
        if array_path.len() != 1 {
            return Err("expected direct receiver array field".into());
        }
        let array_ty = self.field_type(def, &array_path)?;
        let Type::Array(array) = array_ty else {
            return Err("traversal field must be a fixed-capacity array".into());
        };
        let Type::Path(option) = &*array.elem else {
            return Err("array entries must be Option<Record>".into());
        };
        if option.qself.is_some()
            || option.path.segments.len() != 1
            || option.path.segments[0].ident != "Option"
            || option.path.leading_colon.is_some()
        {
            return Err("expected builtin Option array element".into());
        }
        let syn::PathArguments::AngleBracketed(args) = &option.path.segments[0].arguments else {
            return Err("missing array entry type".into());
        };
        let arguments = args.args.iter().cloned().collect::<Vec<_>>();
        let [syn::GenericArgument::Type(record_ty)] = arguments.as_slice() else {
            return Err("expected one record type argument".into());
        };
        let record = self.resolve(&def.module, &base_type(record_ty)?, 0)?;
        let record_struct = &self.structs[&record];
        if !record_struct.generics.params.is_empty()
            || !copy_derived(record_struct)
            || self.drops.contains(&record)
        {
            return Err("array records must be nongeneric and derive builtin Copy".into());
        }
        let [Stmt::Expr(Expr::If(present), _)] = loop_.body.stmts.as_slice() else {
            return Err("traversal must test every optional slot".into());
        };
        attrs(&present.attrs)?;
        if present.else_branch.is_some() {
            return Err("effects on absent entries are unsupported".into());
        }
        let Expr::Let(test) = &*present.cond else {
            return Err("expected if let Some(record) = slot".into());
        };
        attrs(&test.attrs)?;
        let Pat::TupleStruct(some) = &*test.pat else {
            return Err("expected Some pattern".into());
        };
        attrs(&some.attrs)?;
        if !some.path.is_ident("Some")
            || some.qself.is_some()
            || some.elems.len() != 1
            || !named(&test.expr, &slot)
        {
            return Err("expected builtin Some(record) for this slot".into());
        }
        let member = binding(&some.elems[0])?;
        if member == slot {
            return Err("shadowed slot binding unsupported".into());
        }
        let record_def = Definition {
            module: self.struct_modules[&record].clone(),
            file: def.file.clone(),
            item: f.clone(),
            receiver: record.clone(),
            impl_generics: syn::Generics::default(),
            self_type: None,
        };
        let mut writes = vec![];
        let body = self.array_statements(
            &record_def,
            &present.then_branch.stmts,
            &slot,
            &member,
            &mut writes,
        )?;
        Ok(Method{name:name.into(),symbol:name.replace("::","_"),source:def.file.clone(),first_line:f.span().start().line,last_line:f.span().end().line,rust:tokens(f),writes,body,
            iteration:None,last:None,truncation:None,installation:None,restoration:None,enum_projection:None,validator:None,view:None,record_at:None,lookup:None,selection:None,relocation:None,buffer:None,constructor:None,query:None,array:Some(Shape{field:array_path[0].clone(),capacity:tokens(&array.len),record,predicate:None,projection:None,preserve_slots:false,key:None,upsert:None,batch:None,rebuild:None,merge:None,scope:"complete optional Copy-record array traversal; preserves length and visits each original slot exactly once; Rust layout/borrowing and frontend refinement remain trusted"})})
    }
    fn array_statements(
        &self,
        def: &Definition,
        stmts: &[Stmt],
        slot: &str,
        member: &str,
        writes: &mut Vec<Write>,
    ) -> Result<Vec<Statement>, String> {
        let mut body = vec![];
        for stmt in stmts {
            match stmt {
                Stmt::Expr(Expr::If(branch), _) => {
                    attrs(&branch.attrs)?;
                    let condition = self.condition(def, &relative(&branch.cond, member))?;
                    let yes = self.array_statements(
                        def,
                        &branch.then_branch.stmts,
                        slot,
                        member,
                        writes,
                    )?;
                    let no = match &branch.else_branch {
                        None => vec![],
                        Some((_, expr)) => match &**expr {
                            Expr::Block(b) if b.label.is_none() => {
                                attrs(&b.attrs)?;
                                self.array_statements(def, &b.block.stmts, slot, member, writes)?
                            }
                            Expr::If(_) => self.array_statements(
                                def,
                                &[Stmt::Expr(*expr.clone(), None)],
                                slot,
                                member,
                                writes,
                            )?,
                            _ => return Err("unsupported array else expression".into()),
                        },
                    };
                    body.push(Statement::Branch { condition, yes, no });
                }
                Stmt::Expr(Expr::Assign(a), Some(_)) => {
                    attrs(&a.attrs)?;
                    let clear = matches!(&*a.left,Expr::Unary(u) if matches!(u.op,syn::UnOp::Deref(_)) && u.attrs.is_empty() && named(&u.expr,slot));
                    if clear {
                        if !named(&a.right, "None") {
                            return Err("slot replacement only supports None".into());
                        }
                        let write = Write {
                            path: vec!["$present".into()],
                            rust_type: "Option<CopyRecord>".into(),
                            literal: Literal::Boolean(false),
                            line: a.span().start().line,
                        };
                        writes.push(write.clone());
                        body.push(Statement::Write(write));
                    } else {
                        let expr = relative(&Expr::Assign(a.clone()), member);
                        body.extend(self.statements(
                            def,
                            &[Stmt::Expr(expr, Some(Default::default()))],
                            writes,
                            &[],
                            &std::cell::Cell::new(0),
                        )?);
                    }
                }
                _ => {
                    return Err(format!(
                        "unsupported complete array statement {}",
                        tokens(stmt)
                    ))
                }
            }
        }
        Ok(body)
    }
}
pub(super) fn generate(method: &Method) -> String {
    let name = &method.symbol;
    if let Some(merge) = method.array.as_ref().and_then(|s| s.merge.as_ref()) {
        return super::merges::generate(name, merge);
    }
    if let Some(rebuild) = method.array.as_ref().and_then(|s| s.rebuild.as_ref()) {
        return super::rebuilds::generate(name, rebuild);
    }
    if let Some(batch) = method.array.as_ref().and_then(|s| s.batch.as_ref()) {
        return super::slot_batches::generate(name, batch);
    }
    if let Some(upsert) = method.array.as_ref().and_then(|s| s.upsert.as_ref()) {
        return super::upserts::generate(name, upsert);
    }
    if let Some(shape) = method.array.as_ref().filter(|s| s.key.is_some()) {
        let key = shape.key.as_ref().unwrap();
        let predicate = condition(shape.predicate.as_ref().unwrap());
        let field = lean_path(&key.path);
        return format!("def {name}_ir : RecordProjection := ⟨{predicate}, {field}⟩\ndef {name} [DecidableEq α] (entries : ArrayStore α) (key : Cell α) : Bool :=\n  queryKey {name}_ir entries key\ntheorem {name}_correspondence [DecidableEq α] (entries : ArrayStore α) (key : Cell α) : queryKey {name}_ir entries key = {name} entries key := by rfl\n");
    }
    if let Some(shape) = method.array.as_ref().filter(|s| s.preserve_slots) {
        let field = lean_path(shape.projection.as_ref().unwrap());
        return format!("def {name}_ir : Path := {field}\ndef {name} (entries : ArrayStore α) : List (Option (Cell α)) :=\n  mapArrayField {name}_ir entries\ntheorem {name}_correspondence (entries : ArrayStore α) : mapArrayField {name}_ir entries = {name} entries := by rfl\n");
    }
    if let Some(shape) = method.array.as_ref().filter(|s| s.projection.is_some()) {
        let predicate = condition(shape.predicate.as_ref().unwrap());
        let field = lean_path(shape.projection.as_ref().unwrap());
        return format!("def {name}_ir : RecordProjection := ⟨{predicate}, {field}⟩\ndef {name} (entries : ArrayStore α) : List (Cell α) :=\n  projectArray {name}_ir entries\ntheorem {name}_correspondence (entries : ArrayStore α) : projectArray {name}_ir entries = {name} entries := by rfl\n");
    }
    if let Some(predicate) = method.array.as_ref().and_then(|s| s.predicate.as_ref()) {
        return format!("def {name}_ir : Condition := {}\ndef {name} (entries : ArrayStore α) : Bool :=\n  entries.any (fun entry => match entry with | none => false | some state => evalCondition ({}) state)\ntheorem {name}_correspondence (entries : ArrayStore α) : queryArray {name}_ir entries = {name} entries := by rfl\n",condition(predicate),condition(predicate));
    }
    format!("def {name}_ir : Program := {}\ndef {name}_slot (state : Store α) : Store α :=\n{}def {name} (entries : ArrayStore α) : ArrayStore α :=\n  entries.map (mapSlot {name}_slot)\ntheorem {name}_correspondence (entries : ArrayStore α) : executeArray {name}_ir entries = {name} entries := by rfl\n",program(&method.body),executable(&method.body,2))
}
