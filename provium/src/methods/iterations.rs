//! Denotations of complete borrowed, builtin double-ended iterator construction
//! and last-record selection. This does not turn Rust's lazy iterator into an
//! eager allocation: the list denotes the sequence of borrowed locations.
use super::lookups::{ident, method, named};
use super::*;
#[derive(Debug, Serialize)]
pub struct Iteration {
    pub slots: Vec<String>,
    pub length: Vec<String>,
    pub payload_type: String,
    pub inclusive: bool,
    pub scope: &'static str,
}
#[derive(Debug, Serialize)]
pub struct Last {
    pub iteration: Iteration,
    pub iterator_method: String,
    pub iterator_rust: String,
    pub base: selectors::Selection,
    pub base_method: String,
    pub base_rust: String,
    pub record_field: String,
    pub from_back: bool,
    pub scope: &'static str,
}
fn tail(block: &syn::Block) -> Result<&Expr, String> {
    match block.stmts.as_slice() {
        [syn::Stmt::Expr(e, None)] => Ok(e),
        _ => Err("iterator method must retain its complete expression body".into()),
    }
}
pub(super) fn last_expression(block: &syn::Block) -> bool {
    matches!(tail(block),Ok(Expr::MethodCall(c)) if c.method=="map_or" && matches!(&*c.receiver,Expr::MethodCall(n) if (n.method=="next_back" || n.method=="next")))
}
fn shared(def: &Definition) -> Result<(), String> {
    let sig = &def.item.sig;
    attrs(&def.item.attrs)?;
    if sig.asyncness.is_some()
        || sig.constness.is_some()
        || sig.unsafety.is_some()
        || sig.abi.is_some()
        || !sig.generics.params.is_empty()
        || sig.generics.where_clause.is_some()
        || sig.inputs.len() != 1
    {
        return Err("iterator method requires a plain shared receiver-only signature".into());
    }
    let Some(syn::FnArg::Receiver(r)) = sig.inputs.first() else {
        return Err("iterator method requires &self".into());
    };
    attrs(&r.attrs)?;
    if r.reference.is_none() || r.mutability.is_some() || r.colon_token.is_some() {
        return Err("iterator method requires &self".into());
    }
    Ok(())
}
fn receiver_call(c: &syn::ExprMethodCall, def: &Definition) -> Result<String, String> {
    attrs(&c.attrs)?;
    if !path(&c.receiver)?.is_empty() || !c.args.is_empty() || c.turbofish.is_some() {
        return Err("iterator helper must be a plain receiver-only call".into());
    }
    Ok(format!("{}::{}::{}", def.module, def.receiver, c.method)
        .trim_start_matches("::")
        .to_owned())
}
impl Crate {
    fn iterator_traits(&self) -> Result<(), String> {
        if self.array_iterator_shadow {
            return Err("iterator standard traits require unambiguous source resolution".into());
        }
        for ((_, name), path) in &self.imports {
            if ["Iterator", "DoubleEndedIterator"].contains(&name.as_str()) {
                if path.len() != 3
                    || !["core", "std"].contains(&path[0].as_str())
                    || path[1] != "iter"
                    || path[2] != *name
                {
                    return Err("iterator trait import is not a canonical standard trait".into());
                }
                if self.imports.keys().any(|(_, n)| n == &path[0])
                    || self.struct_modules.contains_key(&path[0])
                {
                    return Err("iterator standard namespace is shadowed".into());
                }
                for source in self.files.values() {
                    for item in syn::parse_file(source).map_err(|e| e.to_string())?.items {
                        if matches!(&item,Item::Mod(m) if !test_only(&m.attrs) && m.ident==path[0])
                            || matches!(&item,Item::ExternCrate(e) if e.rename.as_ref().is_some_and(|(_,n)|n==&path[0]))
                        {
                            return Err("iterator standard namespace is shadowed".into());
                        }
                    }
                }
            }
        }
        for source in self.files.values() {
            for item in syn::parse_file(source).map_err(|e| e.to_string())?.items {
                let shadows=match item{
                Item::Trait(t) if !test_only(&t.attrs)=>["Iterator","DoubleEndedIterator"].iter().any(|n|t.ident==*n) || t.items.iter().any(|i|matches!(i,syn::TraitItem::Fn(f) if ["iter","flatten","next_back","next","map_or"].iter().any(|n|f.sig.ident==*n))),
                Item::Impl(i) if i.trait_.is_some() && !test_only(&i.attrs)=>i.items.iter().any(|i|matches!(i,syn::ImplItem::Fn(f) if ["iter","flatten","next_back","next","map_or"].iter().any(|n|f.sig.ident==*n))),
                _=>false,
            };
                if shadows {
                    return Err("iterator standard operations may resolve to user code".into());
                }
            }
        }
        Ok(())
    }
    pub(super) fn lower_iteration(&self, name: &str) -> Result<Method, String> {
        let def = self.methods.get(name).ok_or("unknown iterator method")?;
        let f = &def.item;
        shared(def)?;
        self.iterator_traits()?;
        self.resolve(&def.module, &def.receiver, 0)?;
        let syn::ReturnType::Type(_, output) = &f.sig.output else {
            return Err("iterator must return an opaque double-ended borrow iterator".into());
        };
        let Type::ImplTrait(output) = &**output else {
            return Err("iterator must return impl DoubleEndedIterator".into());
        };
        let bounds = output.bounds.iter().collect::<Vec<_>>();
        let [syn::TypeParamBound::Trait(bound)] = bounds.as_slice() else {
            return Err("iterator requires one explicit DoubleEndedIterator bound".into());
        };
        if bound.lifetimes.is_some()
            || !matches!(bound.modifier, syn::TraitBoundModifier::None)
            || bound.path.leading_colon.is_some()
            || bound.path.segments.len() != 1
            || bound.path.segments[0].ident != "DoubleEndedIterator"
        {
            return Err("iterator must use the builtin DoubleEndedIterator trait".into());
        }
        let syn::PathArguments::AngleBracketed(args) = &bound.path.segments[0].arguments else {
            return Err("iterator Item must be explicit".into());
        };
        let args = args.args.iter().collect::<Vec<_>>();
        let [syn::GenericArgument::AssocType(item)] = args.as_slice() else {
            return Err("iterator must bind its Item type".into());
        };
        if item.ident != "Item" || item.generics.is_some() {
            return Err("iterator must bind Item".into());
        }
        let Type::Reference(reference) = &item.ty else {
            return Err("iterator Item must be a shared borrow".into());
        };
        if reference.mutability.is_some() || reference.lifetime.is_some() {
            return Err("iterator Item must use an elided shared borrow".into());
        }
        let flatten = method(tail(&f.block)?, "flatten", 0)?;
        let iter = method(&flatten.receiver, "iter", 0)?;
        let Expr::Index(slice) = &*iter.receiver else {
            return Err("iterator must borrow its complete prefix slice".into());
        };
        attrs(&slice.attrs)?;
        let Expr::Range(range) = &*slice.index else {
            return Err("iterator prefix must be an explicit range".into());
        };
        attrs(&range.attrs)?;
        if range.start.is_some() {
            return Err("iterator prefix must start at zero".into());
        }
        let length = path(
            range
                .end
                .as_deref()
                .ok_or("iterator prefix needs a length field")?,
        )?;
        if tokens(self.field_type(def, &length)?) != "usize" {
            return Err("iterator prefix length must be builtin usize".into());
        }
        let slots = path(&slice.expr)?;
        let Type::Array(array) = self.field_type(def, &slots)? else {
            return Err("iterator requires a builtin optional array".into());
        };
        if tokens(&array.elem) != format!("Option < {} >", tokens(&reference.elem)) {
            return Err("iterator Item and optional array payload types must agree".into());
        }
        let inclusive = matches!(range.limits, syn::RangeLimits::Closed(_));
        Ok(Method{name:name.into(),symbol:name.replace("::","_"),source:def.file.clone(),first_line:f.span().start().line,last_line:f.span().end().line,rust:tokens(f),writes:vec![],body:vec![],array:None,query:None,constructor:None,buffer:None,relocation:None,selection:None,lookup:None,record_at:None,last:None,truncation:None,installation:None,restoration:None,enum_projection:None,validator:None,view:None,iteration:Some(Iteration{slots,length,payload_type:tokens(&reference.elem),inclusive,scope:"complete builtin double-ended iterator construction; denotation is a lazy sequence of borrowed places, not eager Rust allocation; prefix bounds retained; source/layout/lifetime and panic-hook refinement remain open"})})
    }
    pub(super) fn lower_last(&self, name: &str) -> Result<Method, String> {
        let def = self.methods.get(name).ok_or("unknown last-record method")?;
        let f = &def.item;
        shared(def)?;
        self.iterator_traits()?;
        let syn::ReturnType::Type(_, output) = &f.sig.output else {
            return Err("last-record method needs an output record".into());
        };
        let output_name = base_type(output)?;
        if tokens(output) != output_name
            || def
                .impl_generics
                .type_params()
                .any(|p| p.ident == output_name)
        {
            return Err("last-record output must be an unshadowed concrete record".into());
        }
        let output_name = self.resolve(&def.module, &output_name, 0)?;
        let select = method(tail(&f.block)?, "map_or", 2)?;
        let Expr::MethodCall(next) = &*select.receiver else {
            return Err("last-record must select an iterator end".into());
        };
        let from_back = next.method == "next_back";
        let next = method(
            &select.receiver,
            if from_back { "next_back" } else { "next" },
            0,
        )?;
        let Expr::MethodCall(iterator) = &*next.receiver else {
            return Err("last-record must use its original iterator helper".into());
        };
        let iterator_method = receiver_call(iterator, def)?;
        let iterator = self.lower_iteration(&iterator_method)?;
        let iterator_rust = iterator.rust;
        let iteration = iterator.iteration.ok_or("missing iterator denotation")?;
        let Expr::MethodCall(base_call) = &select.args[0] else {
            return Err("last-record must retain its eager base helper".into());
        };
        let base_method = receiver_call(base_call, def)?;
        let base = self.lower_selection(&base_method)?;
        let base_rust = base.rust;
        let base = base.selection.ok_or("missing base selector")?;
        if base.record_type != output_name {
            return Err("last-record fallback and output record types disagree".into());
        }
        let Expr::Closure(callback) = &select.args[1] else {
            return Err("last-record needs an explicit entry-field projection".into());
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
            return Err("last-record projection must be a plain closure".into());
        }
        let binding = ident(&callback.inputs[0])?;
        let Expr::Field(field) = &*callback.body else {
            return Err("last-record projection must read one entry field".into());
        };
        attrs(&field.attrs)?;
        if !named(&field.base, &binding) {
            return Err("last-record projection must read its entry parameter".into());
        }
        let syn::Member::Named(member) = &field.member else {
            return Err("last-record projection needs a named field".into());
        };
        let payload: syn::Type =
            syn::parse_str(&iteration.payload_type).map_err(|e| e.to_string())?;
        let entry_name = base_type(&payload)?;
        let receiver = self
            .structs
            .get(&def.receiver)
            .ok_or("unresolved receiver")?;
        if receiver
            .generics
            .type_params()
            .any(|p| p.ident == entry_name)
        {
            return Err("generic iterator payload needs field substitution".into());
        }
        let entry_name = self.resolve(&self.struct_modules[&def.receiver], &entry_name, 0)?;
        let entry = self
            .structs
            .get(&entry_name)
            .ok_or("iterator entry must be a source record")?;
        let record = entry
            .fields
            .iter()
            .find(|f| f.ident.as_ref() == Some(member))
            .ok_or("unknown last-record field")?;
        attrs(&record.attrs)?;
        let leaf = base_type(&record.ty)?;
        if tokens(&record.ty) != leaf
            || entry.generics.type_params().any(|p| p.ident == leaf)
            || self.resolve(&self.struct_modules[&entry_name], &leaf, 0)? != output_name
        {
            return Err("last-entry field must resolve to the output record".into());
        }
        Ok(Method{name:name.into(),symbol:name.replace("::","_"),source:def.file.clone(),first_line:f.span().start().line,last_line:f.span().end().line,rust:tokens(f),writes:vec![],body:vec![],array:None,query:None,constructor:None,buffer:None,relocation:None,selection:None,lookup:None,record_at:None,iteration:None,truncation:None,installation:None,restoration:None,enum_projection:None,validator:None,view:None,last:Some(Last{iteration,iterator_method,iterator_rust,base,base_method,base_rust,record_field:member.to_string(),from_back,scope:"complete last-record method with full iterator/base helpers; eager default and selected iterator end preserved in pure iterator denotation; source/layout/lifetime and panic-hook refinement remain open"})})
    }
}
fn program(i: &Iteration) -> String {
    format!(
        "⟨{}, {}, {}⟩",
        lean_path(&i.slots),
        lean_path(&i.length),
        i.inclusive
    )
}
pub(super) fn generate(method: &Method) -> String {
    let name = &method.symbol;
    if let Some(i) = &method.iteration {
        format!("def {name}_ir : Iteration := {}\ndef {name} (state : TraversalStore α) : Except TraversalFault (List ReadPlace) :=\n  iterateRecords {name}_ir state\ntheorem {name}_correspondence (state : TraversalStore α) :\n  iterateRecords {name}_ir state = {name} state := by rfl\n",program(i))
    } else {
        let l = method.last.as_ref().unwrap();
        format!("def {name}_ir : LastRecord := ⟨{}, {}, {}, {}⟩\ndef {name} (state : TraversalStore (Path → InitStore)) : Except TraversalFault InitStore :=\n  lastRecord {name}_ir state\ntheorem {name}_correspondence (state : TraversalStore (Path → InitStore)) :\n  lastRecord {name}_ir state = {name} state := by rfl\n",program(&l.iteration),selectors::program(&l.base),lean_path(std::slice::from_ref(&l.record_field)),l.from_back)
    }
}
impl Iteration {
    /// The finite denotation of the returned builtin iterator. Constructing the
    /// original Rust iterator remains lazy and does not allocate this vector.
    pub fn locations<T>(&self, length: usize, slots: &[Option<T>]) -> Result<Vec<usize>, String> {
        let count = length
            .checked_add(usize::from(self.inclusive))
            .ok_or("prefix bounds")?;
        let prefix = slots.get(..count).ok_or("prefix bounds")?;
        Ok(prefix
            .iter()
            .enumerate()
            .filter_map(|(i, e)| e.as_ref().map(|_| i))
            .collect())
    }
}

pub(super) fn last_program(l: &Last) -> String {
    format!(
        "⟨{}, {}, {}, {}⟩",
        program(&l.iteration),
        selectors::program(&l.base),
        lean_path(std::slice::from_ref(&l.record_field)),
        l.from_back
    )
}
