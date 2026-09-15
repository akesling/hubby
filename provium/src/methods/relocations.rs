//! Consuming record growth through a complete indexed Option::take traversal.
//! Every metadata field is transferred once; custom receiver Drop is rejected.
use super::*;
#[derive(Debug, Serialize)]
pub struct Relocation {
    pub slots: String,
    pub length: String,
    pub old_capacity: String,
    pub new_capacity: String,
    pub metadata: Vec<(String, String)>,
    pub ascending: bool,
    pub inclusive: bool,
    pub scope: &'static str,
}
fn tail(block: &syn::Block) -> Result<&Expr, String> {
    match block.stmts.as_slice() {
        [syn::Stmt::Expr(e, None)] => Ok(e),
        _ => Err("relocation must retain the complete expression block".into()),
    }
}
fn field(e: &Expr) -> Result<String, String> {
    let p = path(e)?;
    match p.as_slice() {
        [name] => Ok(name.clone()),
        _ => Err("relocation requires a direct receiver field".into()),
    }
}
fn take(e: &Expr) -> Result<&Expr, String> {
    let Expr::MethodCall(c) = e else {
        return Err("expected builtin Option::take".into());
    };
    attrs(&c.attrs)?;
    if c.method != "take" || !c.args.is_empty() || c.turbofish.is_some() {
        return Err("expected builtin Option::take".into());
    }
    Ok(&c.receiver)
}
fn optional(ty: &Type) -> bool {
    matches!(ty,Type::Path(p) if p.qself.is_none() && p.path.segments.len()==1 && p.path.segments[0].ident=="Option" && matches!(&p.path.segments[0].arguments,syn::PathArguments::AngleBracketed(a) if a.args.len()==1 && matches!(a.args[0],syn::GenericArgument::Type(_))))
}
impl Crate {
    pub(super) fn lower_relocation(&self, name: &str) -> Result<Method, String> {
        let def = self.methods.get(name).ok_or("unknown relocation method")?;
        let f = &def.item;
        let sig = &f.sig;
        attrs(&f.attrs)?;
        if sig.asyncness.is_some()
            || sig.constness.is_some()
            || sig.unsafety.is_some()
            || sig.abi.is_some()
            || sig.generics.where_clause.is_some()
            || sig.inputs.len() != 1
        {
            return Err("relocation requires a plain owned-receiver signature".into());
        }
        let Some(syn::FnArg::Receiver(r)) = sig.inputs.first() else {
            return Err("relocation requires mut self".into());
        };
        attrs(&r.attrs)?;
        if r.reference.is_some() || r.mutability.is_none() || r.colon_token.is_some() {
            return Err("relocation requires mut self".into());
        }
        let parameters = sig.generics.params.iter().collect::<Vec<_>>();
        let [syn::GenericParam::Const(new)] = parameters.as_slice() else {
            return Err("relocation requires one new usize capacity".into());
        };
        attrs(&new.attrs)?;
        if tokens(&new.ty) != "usize" || new.default.is_some() {
            return Err("new capacity must be usize".into());
        }
        if self.drops.contains(&def.receiver) {
            return Err("custom receiver Drop requires explicit effect semantics".into());
        }
        // No builtin operation may be replaced by a source namespace or import.
        if self.imports.keys().any(|(_, n)| n == "core")
            || self.struct_modules.keys().any(|n| n == "core")
            || def.impl_generics.type_params().any(|p| p.ident == "core")
        {
            return Err("relocation builtin namespace is shadowed".into());
        }
        for source in self.files.values() {
            for item in syn::parse_file(source).map_err(|e| e.to_string())?.items {
                if matches!(&item,Item::Mod(m) if m.ident=="core")
                    || matches!(&item,Item::ExternCrate(e) if e.rename.as_ref().is_some_and(|(_,n)|n=="core"))
                {
                    return Err("relocation builtin namespace is shadowed".into());
                }
            }
        }
        let [syn::Stmt::Expr(Expr::Const(check), None), syn::Stmt::Expr(Expr::Struct(result), None)] =
            f.block.stmts.as_slice()
        else {
            return Err(
                "relocation requires the entire const-check and record-construction body".into(),
            );
        };
        attrs(&check.attrs)?;
        attrs(&result.attrs)?;
        if result.qself.is_some() || !result.path.is_ident(&def.receiver) || result.rest.is_some() {
            return Err("relocation must explicitly construct the receiver record".into());
        }
        let [syn::Stmt::Macro(assertion)] = check.block.stmts.as_slice() else {
            return Err("relocation needs a builtin const assert".into());
        };
        attrs(&assertion.attrs)?;
        if !assertion.mac.path.is_ident("assert") {
            return Err("relocation needs builtin assert!".into());
        }
        let args = assertion
            .mac
            .parse_body_with(syn::punctuated::Punctuated::<Expr, syn::Token![,]>::parse_terminated)
            .map_err(|e| e.to_string())?;
        if args.is_empty() || args.len()>2 || args.get(1).is_some_and(|e|!matches!(e,Expr::Lit(l) if l.attrs.is_empty() && matches!(l.lit,syn::Lit::Str(_)))) {return Err("const assertion only accepts a capacity comparison and literal message".into());}
        let Expr::Binary(compare) = &args[0] else {
            return Err("const assertion must compare capacities".into());
        };
        attrs(&compare.attrs)?;
        if !matches!(&*compare.left,Expr::Path(p) if p.attrs.is_empty() && p.qself.is_none() && p.path.is_ident(&new.ident.to_string()))
        {
            return Err("const assertion must start with new capacity".into());
        }
        let Expr::Path(old) = &*compare.right else {
            return Err("old capacity must be an impl const parameter".into());
        };
        attrs(&old.attrs)?;
        let old_capacity = tokens(&old.path);
        if old.qself.is_some()
            || !def
                .impl_generics
                .const_params()
                .any(|c| c.ident == old_capacity && tokens(&c.ty) == "usize")
        {
            return Err("old capacity must be an impl usize parameter".into());
        }
        let ascending = match compare.op {
            syn::BinOp::Ge(_) => true,
            syn::BinOp::Le(_) => false,
            _ => return Err("unsupported static capacity relation".into()),
        };
        let structure = self
            .structs
            .get(&def.receiver)
            .ok_or("unknown relocation receiver")?;
        let Some(Type::Path(source_type)) = &def.self_type else {
            return Err("unresolved source type".into());
        };
        let syn::ReturnType::Type(_, output) = &sig.output else {
            return Err("missing relocation output type".into());
        };
        let Type::Path(output) = &**output else {
            return Err("unresolved relocation output type".into());
        };
        if output.qself.is_some()
            || output.path.segments.len() != 1
            || output.path.segments[0].ident != def.receiver
        {
            return Err("relocation must return the same record type".into());
        }
        let syn::PathArguments::AngleBracketed(src) = &source_type
            .path
            .segments
            .last()
            .ok_or("missing source type")?
            .arguments
        else {
            return Err("missing source generic arguments".into());
        };
        let syn::PathArguments::AngleBracketed(dst) = &output.path.segments[0].arguments else {
            return Err("missing destination generic arguments".into());
        };
        if src.args.len() != structure.generics.params.len() || src.args.len() != dst.args.len() {
            return Err("incomplete relocation type substitution".into());
        }
        let mut array_parameter = None;
        for ((parameter, source), dest) in structure
            .generics
            .params
            .iter()
            .zip(&src.args)
            .zip(&dst.args)
        {
            match parameter {
                syn::GenericParam::Const(c) if tokens(source) == old_capacity => {
                    attrs(&c.attrs)?;
                    if tokens(&c.ty) != "usize" || new.ident != tokens(dest) {
                        return Err("output must substitute exactly the new capacity".into());
                    }
                    array_parameter = Some(c.ident.to_string());
                }
                syn::GenericParam::Type(t)
                    if t.ident == tokens(source) && tokens(source) == tokens(dest) => {}
                syn::GenericParam::Const(c)
                    if c.ident == tokens(source) && tokens(source) == tokens(dest) => {}
                _ => return Err("unsupported relocation generic substitution".into()),
            }
        }
        let array_parameter = array_parameter.ok_or("no relocated array capacity")?;
        let mut slots = None;
        let mut length = None;
        let mut inclusive = false;
        let mut metadata = vec![];
        let mut seen = std::collections::BTreeSet::new();
        let mut plain_fields = vec![];
        for value in &result.fields {
            attrs(&value.attrs)?;
            let syn::Member::Named(member) = &value.member else {
                return Err("relocation requires named fields".into());
            };
            let name = member.to_string();
            if !seen.insert(name.clone()) {
                return Err("duplicate relocation field".into());
            }
            let ty = self.field_type(def, std::slice::from_ref(&name))?;
            match &value.expr {
                Expr::Field(_) if field(&value.expr)? == name => {
                    plain_fields.push(name.clone());
                    metadata.push((name, "transfer".into()));
                }
                Expr::MethodCall(_) if field(take(&value.expr)?)? == name => {
                    if !optional(ty) {
                        return Err("taken metadata must be builtin Option".into());
                    }
                    metadata.push((name, "take".into()));
                }
                Expr::Call(c) => {
                    attrs(&c.attrs)?;
                    if slots.is_some()
                        || c.args.len() != 1
                        || !matches!(&*c.func,Expr::Path(p) if p.attrs.is_empty() && p.qself.is_none() && tokens(&p.path)=="core :: array :: from_fn")
                    {
                        return Err("relocation requires one builtin array from_fn".into());
                    }
                    let Type::Array(array) = ty else {
                        return Err("from_fn field must be a builtin array".into());
                    };
                    if tokens(&array.len) != array_parameter || !optional(&array.elem) {
                        return Err(
                            "relocated array must have the original capacity and Option slots"
                                .into(),
                        );
                    }
                    let Expr::Closure(callback) = &c.args[0] else {
                        return Err("relocation requires the original indexed closure".into());
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
                        return Err("relocation closure must be plain and indexed".into());
                    }
                    let syn::Pat::Ident(index) = &callback.inputs[0] else {
                        return Err("relocation index must be a plain identifier".into());
                    };
                    attrs(&index.attrs)?;
                    if index.by_ref.is_some()
                        || index.mutability.is_some()
                        || index.subpat.is_some()
                    {
                        return Err("relocation index must be a plain identifier".into());
                    }
                    let Expr::Block(body) = &*callback.body else {
                        return Err("relocation requires a complete closure block".into());
                    };
                    attrs(&body.attrs)?;
                    if body.label.is_some() {
                        return Err("labelled relocation closure unsupported".into());
                    }
                    let Expr::If(branch) = tail(&body.block)? else {
                        return Err("relocation callback must branch on live length".into());
                    };
                    attrs(&branch.attrs)?;
                    let Expr::Binary(test) = &*branch.cond else {
                        return Err("relocation callback must compare index and length".into());
                    };
                    attrs(&test.attrs)?;
                    if !matches!(&*test.left,Expr::Path(p) if p.attrs.is_empty() && p.qself.is_none() && p.path.is_ident(&index.ident.to_string()))
                    {
                        return Err("relocation callback must compare its index".into());
                    }
                    let len = field(&test.right)?;
                    if tokens(self.field_type(def, std::slice::from_ref(&len))?) != "usize" {
                        return Err("relocation length must be usize".into());
                    }
                    inclusive = match test.op {
                        syn::BinOp::Lt(_) => false,
                        syn::BinOp::Le(_) => true,
                        _ => return Err("unsupported relocation index comparison".into()),
                    };
                    let Expr::Index(at) = take(tail(&branch.then_branch)?)? else {
                        return Err("relocation must take the indexed slot".into());
                    };
                    attrs(&at.attrs)?;
                    if field(&at.expr)? != name
                        || !matches!(&*at.index,Expr::Path(p) if p.attrs.is_empty() && p.qself.is_none() && p.path.is_ident(&index.ident.to_string()))
                    {
                        return Err("relocation must take the same indexed source slot".into());
                    }
                    let Some((_, otherwise)) = &branch.else_branch else {
                        return Err("relocation requires the empty-slot branch".into());
                    };
                    let Expr::Block(otherwise) = &**otherwise else {
                        return Err("expected empty-slot block".into());
                    };
                    attrs(&otherwise.attrs)?;
                    if otherwise.label.is_some()
                        || !matches!(tail(&otherwise.block)?,Expr::Path(p) if p.attrs.is_empty() && p.qself.is_none() && p.path.is_ident("None"))
                    {
                        return Err("relocation must initialize unused slots to None".into());
                    }
                    length = Some(len);
                    slots = Some(name);
                }
                _ => {
                    return Err(
                        "unsupported relocation initializer; no fields can be skipped".into(),
                    )
                }
            }
        }
        let slots = slots.ok_or("missing array relocation")?;
        let length = length.ok_or("missing live length")?;
        if seen.len() != structure.fields.len() || !plain_fields.contains(&length) {
            return Err("relocation must preserve every field including length".into());
        }
        Ok(Method{name:name.into(),symbol:name.replace("::","_"),source:def.file.clone(),first_line:f.span().start().line,last_line:f.span().end().line,rust:tokens(f),writes:vec![],body:vec![],array:None,query:None,constructor:None,buffer:None,iteration:None,last:None,truncation:None,installation:None,restoration:None,record_at:None,lookup:None,selection:None,relocation:Some(Relocation{slots,length,old_capacity,new_capacity:new.ident.to_string(),metadata,ascending,inclusive,scope:"complete consuming record relocation; metadata transferred or taken, indexed optional slots moved in order; source/borrow/layout and panic unwinding remain unproved; trailing drops suspend before consumer effects"})})
    }
}
pub(super) fn generate(method: &Method) -> String {
    let r = method.relocation.as_ref().unwrap();
    let name = &method.symbol;
    format!("def {name}_ir : Relocation := ⟨{}, {}, {:?}, {:?}, {}, {}⟩\ndef {name} (oldCapacity newCapacity : Nat) (state : BufferState α) (metadata : β) : RelocationRun α β :=\n  relocate {name}_ir oldCapacity newCapacity state metadata\ntheorem {name}_correspondence (oldCapacity newCapacity : Nat) (state : BufferState α) (metadata : β) :\n  relocate {name}_ir oldCapacity newCapacity state metadata = {name} oldCapacity newCapacity state metadata := by rfl\n",lean_path(std::slice::from_ref(&r.slots)),lean_path(std::slice::from_ref(&r.length)),r.old_capacity,r.new_capacity,r.ascending,r.inclusive)
}

#[derive(Debug, PartialEq, Eq)]
pub enum Outcome<T, M> {
    Returned(super::buffers::State<T>, M),
    InvalidInstantiation,
    Bounds {
        index: usize,
        moved: Vec<Option<T>>,
        remaining: Vec<Option<T>>,
        metadata: M,
    },
    Drop(T, Box<Outcome<T, M>>),
}
impl Relocation {
    /// Execute indexed moves and expose disposal of the old slots. Bounds stops
    /// at the array fault; panic hooks, partial-record ownership and unwinding
    /// through metadata or payload destruction are outside this outcome model.
    pub fn evaluate<T, M>(
        &self,
        old_capacity: usize,
        new_capacity: usize,
        mut state: super::buffers::State<T>,
        metadata: M,
    ) -> Outcome<T, M> {
        if !(if self.ascending {
            new_capacity >= old_capacity
        } else {
            new_capacity <= old_capacity
        }) {
            return Outcome::InvalidInstantiation;
        }
        let mut moved = Vec::with_capacity(new_capacity);
        for i in 0..new_capacity {
            let live = if self.inclusive {
                i as u128 <= u128::from(state.len)
            } else {
                (i as u128) < u128::from(state.len)
            };
            if live {
                let Some(slot) = state.slots.get_mut(i) else {
                    return Outcome::Bounds {
                        index: i,
                        moved,
                        remaining: state.slots,
                        metadata,
                    };
                };
                moved.push(slot.take());
            } else {
                moved.push(None);
            }
        }
        let mut next = Outcome::Returned(
            super::buffers::State {
                slots: moved,
                len: state.len,
            },
            metadata,
        );
        for old in state.slots.into_iter().rev().flatten() {
            next = Outcome::Drop(old, Box::new(next));
        }
        next
    }
}
