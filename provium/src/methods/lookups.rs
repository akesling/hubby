//! Whole shared lookup: checked subtraction, checked target-word conversion,
//! bounds-checked optional-array access, and a borrowed result location.
use super::*;
#[derive(Debug, Serialize)]
pub struct Lookup {
    pub slots: Vec<String>,
    pub base_method: String,
    pub base_rust: String,
    pub base: selectors::Selection,
    pub base_field: String,
    pub bias: u64,
    pub scope: &'static str,
}
fn try_expr(e: &Expr) -> Result<&Expr, String> {
    let Expr::Try(t) = e else {
        return Err("lookup must retain Option/Result short-circuiting".into());
    };
    attrs(&t.attrs)?;
    Ok(&t.expr)
}
pub(super) fn method<'a>(
    e: &'a Expr,
    name: &str,
    count: usize,
) -> Result<&'a syn::ExprMethodCall, String> {
    let Expr::MethodCall(c) = e else {
        return Err(format!("expected lookup {name}"));
    };
    attrs(&c.attrs)?;
    if c.method != name || c.args.len() != count || c.turbofish.is_some() {
        return Err(format!("expected builtin lookup {name}"));
    }
    Ok(c)
}
pub(super) fn ident(p: &syn::Pat) -> Result<String, String> {
    let syn::Pat::Ident(p) = p else {
        return Err("lookup locals must be plain identifiers".into());
    };
    attrs(&p.attrs)?;
    if p.by_ref.is_some() || p.subpat.is_some() || p.mutability.is_some() {
        return Err("lookup locals must be plain identifiers".into());
    }
    Ok(p.ident.to_string())
}
pub(super) fn named(e: &Expr, name: &str) -> bool {
    matches!(e,Expr::Path(p) if p.attrs.is_empty() && p.qself.is_none() && p.path.is_ident(name))
}
fn local(l: &syn::Local) -> Result<(String, &Expr), String> {
    attrs(&l.attrs)?;
    let name = ident(&l.pat)?;
    let init = l.init.as_ref().ok_or("lookup local needs initializer")?;
    if init.diverge.is_some() {
        return Err("lookup let-else unsupported".into());
    }
    Ok((name, &init.expr))
}
impl Crate {
    pub(super) fn lower_lookup(&self, name: &str) -> Result<Method, String> {
        let def = self.methods.get(name).ok_or("unknown lookup")?;
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
            return Err("lookup requires a plain shared method".into());
        }
        let inputs = sig.inputs.iter().collect::<Vec<_>>();
        let [syn::FnArg::Receiver(r), syn::FnArg::Typed(input)] = inputs.as_slice() else {
            return Err("lookup requires &self and a u64 index".into());
        };
        attrs(&r.attrs)?;
        attrs(&input.attrs)?;
        if r.reference.is_none()
            || r.mutability.is_some()
            || r.colon_token.is_some()
            || tokens(&input.ty) != "u64"
        {
            return Err("lookup requires &self and a u64 index".into());
        }
        let input_name = ident(&input.pat)?;
        self.resolve(&def.module, &def.receiver, 0)?;
        // Array.get uses slice method resolution; a local trait can intervene.
        // TryFrom is a trait-associated call and must not resolve to user code.
        if self.imports.keys().any(|(_, n)| n == "TryFrom")
            || self.struct_modules.contains_key("TryFrom")
        {
            return Err("lookup TryFrom namespace is shadowed".into());
        }
        for source in self.files.values() {
            for item in syn::parse_file(source).map_err(|e| e.to_string())?.items {
                let shadows=match item {
                Item::Trait(t)=>t.ident=="TryFrom" || t.items.iter().any(|i|matches!(i,syn::TraitItem::Fn(f) if ["get","as_ref","try_from"].iter().any(|n|f.sig.ident==*n))),
                Item::Impl(i) if i.trait_.is_some()=>i.items.iter().any(|i|matches!(i,syn::ImplItem::Fn(f) if ["get","as_ref","try_from"].iter().any(|n|f.sig.ident==*n))),
                _=>false,
            };
                if shadows {
                    return Err(
                        "lookup standard methods require unambiguous trait resolution".into(),
                    );
                }
            }
        }
        let syn::ReturnType::Type(_, output) = &sig.output else {
            return Err("lookup must return Option<&Payload>".into());
        };
        let Type::Path(option) = &**output else {
            return Err("lookup must return Option<&Payload>".into());
        };
        if option.qself.is_some()
            || option.path.leading_colon.is_some()
            || option.path.segments.len() != 1
            || option.path.segments[0].ident != "Option"
        {
            return Err("lookup requires builtin Option result".into());
        }
        let syn::PathArguments::AngleBracketed(args) = &option.path.segments[0].arguments else {
            return Err("missing Option result argument".into());
        };
        let args = args.args.iter().collect::<Vec<_>>();
        let [syn::GenericArgument::Type(Type::Reference(reference))] = args.as_slice() else {
            return Err("lookup returns exactly one borrowed payload".into());
        };
        if reference.mutability.is_some() || reference.lifetime.is_some() {
            return Err("lookup requires an elided shared result borrow".into());
        }
        let [syn::Stmt::Local(relative), syn::Stmt::Local(converted), syn::Stmt::Expr(result, None)] =
            f.block.stmts.as_slice()
        else {
            return Err("lookup must retain its complete two-local checked pipeline".into());
        };
        let (relative_name, relative) = local(relative)?;
        let shifted = method(try_expr(relative)?, "checked_sub", 1)?;
        let Expr::Lit(literal) = &shifted.args[0] else {
            return Err("lookup offset bias must be a u64 literal".into());
        };
        attrs(&literal.attrs)?;
        let syn::Lit::Int(n) = &literal.lit else {
            return Err("lookup bias must be unsigned".into());
        };
        if !["", "u64"].contains(&n.suffix()) {
            return Err("lookup bias must be u64".into());
        }
        let bias = n.base10_parse().map_err(|e| format!("{e}"))?;
        let subtract = method(try_expr(&shifted.receiver)?, "checked_sub", 1)?;
        if !named(&subtract.receiver, &input_name) {
            return Err("lookup must subtract from its input index".into());
        }
        let Expr::Field(base_field) = &subtract.args[0] else {
            return Err("lookup base must be a source-resolved record field".into());
        };
        attrs(&base_field.attrs)?;
        let syn::Member::Named(base_member) = &base_field.member else {
            return Err("lookup base must be named".into());
        };
        let Expr::MethodCall(base_call) = &*base_field.base else {
            return Err("lookup base must invoke its original helper".into());
        };
        attrs(&base_call.attrs)?;
        if !path(&base_call.receiver)?.is_empty()
            || !base_call.args.is_empty()
            || base_call.turbofish.is_some()
        {
            return Err("lookup base helper must be receiver-only".into());
        }
        let base_method = format!("{}::{}::{}", def.module, def.receiver, base_call.method)
            .trim_start_matches("::")
            .to_owned();
        let helper = self.lower_selection(&base_method)?;
        let base_rust = helper.rust;
        let base = helper
            .selection
            .ok_or("lookup helper is not a record selection")?;
        let record = self
            .structs
            .get(&base.record_type)
            .ok_or("unknown lookup base record")?;
        let field = record
            .fields
            .iter()
            .find(|f| f.ident.as_ref() == Some(base_member))
            .ok_or("unknown lookup base field")?;
        attrs(&field.attrs)?;
        if tokens(&field.ty) != "u64" {
            return Err("lookup base index must be builtin u64".into());
        }
        let (converted_name, converted) = local(converted)?;
        let convert = method(try_expr(converted)?, "ok", 0)?;
        let Expr::Call(convert) = &*convert.receiver else {
            return Err("lookup requires usize::try_from".into());
        };
        attrs(&convert.attrs)?;
        if convert.args.len() != 1
            || !named(&convert.args[0], &relative_name)
            || !matches!(&*convert.func,Expr::Path(p) if p.attrs.is_empty() && p.qself.is_none() && tokens(&p.path)=="usize :: try_from")
        {
            return Err(
                "lookup conversion must check the relative index against target usize".into(),
            );
        }
        let borrowed = method(result, "as_ref", 0)?;
        let access = method(try_expr(&borrowed.receiver)?, "get", 1)?;
        if !named(&access.args[0], &converted_name) {
            return Err("lookup must use its converted index".into());
        }
        let slots = path(&access.receiver)?;
        let Type::Array(array) = self.field_type(def, &slots)? else {
            return Err("lookup requires builtin array storage".into());
        };
        if tokens(&array.elem) != format!("Option < {} >", tokens(&reference.elem)) {
            return Err("lookup array slot and borrowed result types must agree".into());
        }
        Ok(Method{name:name.into(),symbol:name.replace("::","_"),source:def.file.clone(),first_line:f.span().start().line,last_line:f.span().end().line,rust:tokens(f),writes:vec![],body:vec![],array:None,query:None,constructor:None,buffer:None,relocation:None,selection:None,iteration:None,last:None,truncation:None,installation:None,restoration:None,getter: None, enum_projection:None,imperative:None,validator:None,view:None,record_at:None,lookup:Some(Lookup{slots,base_method,base_rust,base,base_field:base_member.to_string(),bias,scope:"complete shared checked lookup and source-resolved base helper; returns an abstract borrowed place; physical reference validity, Rust layout/borrow and frontend correspondence remain unproved"})})
    }
}
pub(super) fn program(l: &Lookup) -> String {
    format!(
        "⟨{}, {}, {}, {}⟩",
        lean_path(&l.slots),
        selectors::program(&l.base),
        lean_path(std::slice::from_ref(&l.base_field)),
        l.bias
    )
}
pub(super) fn generate(method: &Method) -> String {
    let l = method.lookup.as_ref().unwrap();
    let name = &method.symbol;
    format!("def {name}_ir : RecordLookup := {}\ndef {name} (bits : Nat) (state : LookupStore α) (index : Nat) : Except LookupFault (Option ReadPlace) :=\n  lookupRecord {name}_ir bits state index\ntheorem {name}_correspondence (bits : Nat) (state : LookupStore α) (index : Nat) :\n  lookupRecord {name}_ir bits state index = {name} bits state index := by rfl\n",program(l))
}

impl Lookup {
    /// Evaluate the checked-index pipeline after the source-selected base record
    /// has been read. The result is the borrowed slot location, not an owned T.
    pub fn evaluate<T>(
        &self,
        bits: u32,
        base: u64,
        index: u64,
        slots: &[Option<T>],
    ) -> Result<Option<usize>, String> {
        if !matches!(bits, 32 | 64) {
            return Err("lookup requires a supported target width".into());
        }
        let Some(relative) = index
            .checked_sub(base)
            .and_then(|n| n.checked_sub(self.bias))
        else {
            return Ok(None);
        };
        if u128::from(relative) >= 1u128 << bits {
            return Ok(None);
        }
        let Ok(offset) = usize::try_from(relative) else {
            return Ok(None);
        };
        Ok(slots.get(offset).and_then(Option::as_ref).map(|_| offset))
    }
}
