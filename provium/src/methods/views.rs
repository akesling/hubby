//! Shared suffix-view primitives. Offset inspection is component evidence only:
//! the surrounding record construction and all returned borrows still need lowering.
use super::lookups::{ident, method, named};
use super::*;

#[derive(Debug, Serialize)]
pub struct SuffixOffset {
    pub argument: String,
    pub local: String,
    pub length: Vec<String>,
    pub base_method: String,
    pub base_rust: String,
    pub base: selectors::Selection,
    pub base_field: String,
    pub bias: u64,
    pub rust: String,
}

fn closure(expression: &Expr) -> Result<&syn::ExprClosure, String> {
    let Expr::Closure(c) = expression else {
        return Err("suffix offset needs an explicit closure".into());
    };
    attrs(&c.attrs)?;
    if c.asyncness.is_some()
        || c.constness.is_some()
        || c.movability.is_some()
        || c.capture.is_some()
        || c.lifetimes.is_some()
        || !matches!(c.output, syn::ReturnType::Default)
        || c.inputs.len() != 1
    {
        return Err("suffix offset requires a plain one-parameter closure".into());
    }
    Ok(c)
}

impl Crate {
    /// Inspect the first local's complete optional-index offset pipeline.
    /// This does not lower or certify the enclosing method's remaining body.
    pub fn inspect_suffix_offset(&self, name: &str) -> Result<SuffixOffset, String> {
        let def = self.methods.get(name).ok_or("unknown suffix-view method")?;
        let sig = &def.item.sig;
        attrs(&def.item.attrs)?;
        if sig.asyncness.is_some()
            || sig.constness.is_some()
            || sig.unsafety.is_some()
            || sig.abi.is_some()
            || !sig.generics.params.is_empty()
            || sig.generics.where_clause.is_some()
        {
            return Err("suffix view needs a plain shared method".into());
        }
        let Some(syn::FnArg::Receiver(receiver)) = sig.inputs.first() else {
            return Err("suffix view needs &self".into());
        };
        attrs(&receiver.attrs)?;
        if receiver.reference.is_none()
            || receiver.mutability.is_some()
            || receiver.colon_token.is_some()
        {
            return Err("suffix view needs &self".into());
        }
        if self.imports.keys().any(|(_, n)| n == "TryFrom")
            || self.struct_modules.contains_key("TryFrom")
            || def
                .impl_generics
                .type_params()
                .any(|p| p.ident == "TryFrom")
        {
            return Err("suffix-view TryFrom namespace is shadowed".into());
        }
        // All accepted receiver operations are builtin. Fail closed if source
        // traits could intervene in standard method/associated-item resolution.
        for source in self.files.values() {
            for item in syn::parse_file(source).map_err(|e| e.to_string())?.items {
                let reserved = |name: &syn::Ident| {
                    ["map_or", "saturating_sub", "try_from", "unwrap_or", "min"]
                        .iter()
                        .any(|n| name == *n)
                };
                let shadows =
                    match item {
                        Item::Trait(t) => t.ident == "TryFrom"
                            || t.items.iter().any(
                                |i| matches!(i, syn::TraitItem::Fn(f) if reserved(&f.sig.ident)),
                            ),
                        Item::Impl(i) if i.trait_.is_some() => i
                            .items
                            .iter()
                            .any(|i| matches!(i, syn::ImplItem::Fn(f) if reserved(&f.sig.ident))),
                        _ => false,
                    };
                if shadows {
                    return Err("suffix-view standard operations may resolve to user code".into());
                }
            }
        }
        let Some(syn::Stmt::Local(local)) = def.item.block.stmts.first() else {
            return Err("suffix view must start with its offset local".into());
        };
        attrs(&local.attrs)?;
        let local_name = ident(&local.pat)?;
        let initializer = local
            .init
            .as_ref()
            .ok_or("suffix offset needs initializer")?;
        if initializer.diverge.is_some() {
            return Err("suffix offset let-else unsupported".into());
        }
        let map = method(&initializer.expr, "map_or", 2)?;
        let Expr::Path(input) = &*map.receiver else {
            return Err("suffix offset must select its optional argument".into());
        };
        let Some(argument) = input.path.get_ident() else {
            return Err("suffix offset requires a plain optional argument".into());
        };
        if !named(&map.receiver, &argument.to_string()) {
            return Err("suffix offset requires a plain optional argument".into());
        }
        let input = sig
            .inputs
            .iter()
            .find_map(|a| match a {
                syn::FnArg::Typed(p)
                    if ident(&p.pat).ok().as_deref() == Some(&argument.to_string()) =>
                {
                    Some(p)
                }
                _ => None,
            })
            .ok_or("suffix offset argument is not a method input")?;
        attrs(&input.attrs)?;
        if tokens(&input.ty) != "Option < u64 >" {
            return Err("suffix offset requires builtin Option<u64>".into());
        }
        let length = path(&map.args[0])?;
        if tokens(self.field_type(def, &length)?) != "usize" {
            return Err("suffix length must be builtin usize".into());
        }
        let callback = closure(&map.args[1])?;
        let index = ident(&callback.inputs[0])?;
        let body = match &*callback.body {
            Expr::Block(b) if b.label.is_none() => {
                attrs(&b.attrs)?;
                let [syn::Stmt::Expr(e, None)] = b.block.stmts.as_slice() else {
                    return Err("suffix callback must retain its entire expression".into());
                };
                e
            }
            e => e,
        };
        let clamp = method(body, "min", 1)?;
        let fallback = method(&clamp.receiver, "unwrap_or", 1)?;
        if path(&clamp.args[0])? != length || path(&fallback.args[0])? != length {
            return Err("suffix conversion fallback and clamp must use its default length".into());
        }
        let Expr::Call(convert) = &*fallback.receiver else {
            return Err("suffix requires checked usize conversion".into());
        };
        attrs(&convert.attrs)?;
        if convert.args.len() != 1
            || !matches!(&*convert.func, Expr::Path(p) if p.attrs.is_empty() && p.qself.is_none() && tokens(&p.path) == "usize :: try_from")
        {
            return Err("suffix requires builtin usize::try_from".into());
        }
        let shift = method(&convert.args[0], "saturating_sub", 1)?;
        let Expr::Lit(literal) = &shift.args[0] else {
            return Err("suffix bias must be a u64 literal".into());
        };
        attrs(&literal.attrs)?;
        let syn::Lit::Int(bias) = &literal.lit else {
            return Err("suffix bias must be a u64 literal".into());
        };
        if !["", "u64"].contains(&bias.suffix()) {
            return Err("suffix bias must have u64 type".into());
        }
        let bias = bias.base10_parse().map_err(|e| format!("{e}"))?;
        let subtract = method(&shift.receiver, "saturating_sub", 1)?;
        if !named(&subtract.receiver, &index) {
            return Err("suffix subtraction must use its closure parameter".into());
        }
        let Expr::Field(field) = &subtract.args[0] else {
            return Err("suffix base requires a helper record field".into());
        };
        attrs(&field.attrs)?;
        let syn::Member::Named(member) = &field.member else {
            return Err("suffix base field must be named".into());
        };
        let Expr::MethodCall(call) = &*field.base else {
            return Err("suffix base requires its original helper".into());
        };
        attrs(&call.attrs)?;
        if !path(&call.receiver)?.is_empty() || !call.args.is_empty() || call.turbofish.is_some() {
            return Err("suffix base helper must be receiver-only".into());
        }
        let base_method = format!("{}::{}::{}", def.module, def.receiver, call.method)
            .trim_start_matches("::")
            .to_owned();
        let helper = self.lower_selection(&base_method)?;
        let base = helper
            .selection
            .ok_or("suffix base must select a copied record")?;
        let record = self
            .structs
            .get(&base.record_type)
            .ok_or("unknown suffix base record")?;
        let field = record
            .fields
            .iter()
            .find(|f| f.ident.as_ref() == Some(member))
            .ok_or("unknown suffix base field")?;
        attrs(&field.attrs)?;
        if tokens(&field.ty) != "u64" {
            return Err("suffix base field must be builtin u64".into());
        }
        Ok(SuffixOffset {
            argument: argument.to_string(),
            local: local_name,
            length,
            base_method,
            base_rust: helper.rust,
            base,
            base_field: member.to_string(),
            bias,
            rust: tokens(local),
        })
    }
}

impl SuffixOffset {
    /// Emit a component definition only; no enclosing-method correspondence or
    /// proof-success artifact is produced by offset inspection.
    pub fn lean_definition(&self, symbol: &str) -> Result<String, String> {
        if !super::identifier(symbol) {
            return Err("invalid suffix component symbol".into());
        }
        Ok(format!(
            "def {symbol} : Provium.State.SuffixOffsetProgram := ⟨{}, {}, {}, {}⟩\n",
            selectors::program(&self.base),
            lean_path(std::slice::from_ref(&self.base_field)),
            self.bias,
            lean_path(&self.length),
        ))
    }

    /// Evaluate the accepted pipeline without host-width-dependent casts.
    pub fn evaluate(
        &self,
        bits: u32,
        length: u64,
        base: u64,
        from: Option<u64>,
    ) -> Result<u64, String> {
        if ![32, 64].contains(&bits) || u128::from(length) >= (1u128 << bits) {
            return Err("invalid target word or length".into());
        }
        Ok(from.map_or(length, |index| {
            let relative = index.saturating_sub(base).saturating_sub(self.bias);
            if u128::from(relative) < (1u128 << bits) {
                relative.min(length)
            } else {
                length
            }
        }))
    }
}

#[derive(Debug, Serialize)]
pub struct SharedView {
    pub offset: SuffixOffset,
    pub copied: Vec<String>,
    pub optional: Vec<String>,
    pub slots: Vec<String>,
    pub output_type: String,
    /// Rust field names in semantic order: copied, optional, input, slice.
    pub output_fields: [String; 4],
    pub scope: &'static str,
}

pub(super) fn candidate(item: &syn::ImplItemFn) -> bool {
    matches!(
        item.block.stmts.as_slice(),
        [syn::Stmt::Local(_), syn::Stmt::Expr(Expr::Struct(_), None)]
    ) && matches!(item.sig.inputs.first(), Some(syn::FnArg::Receiver(r)) if r.reference.is_some() && r.mutability.is_none())
}

impl Crate {
    pub(super) fn lower_shared_view(&self, name: &str) -> Result<Method, String> {
        let offset = self.inspect_suffix_offset(name)?;
        let def = &self.methods[name];
        let inputs: Vec<_> = def.item.sig.inputs.iter().collect();
        let [_, syn::FnArg::Typed(first), syn::FnArg::Typed(changed)] = inputs.as_slice() else {
            return Err("shared suffix view needs an optional u64 and a boolean input".into());
        };
        attrs(&first.attrs)?;
        attrs(&changed.attrs)?;
        if ident(&first.pat)? != offset.argument || tokens(&changed.ty) != "bool" {
            return Err("shared suffix view needs its offset input followed by a boolean".into());
        }
        let changed = ident(&changed.pat)?;
        let syn::ReturnType::Type(_, output) = &def.item.sig.output else {
            return Err("shared suffix view must return a source record".into());
        };
        let output_type = self.resolve(&def.module, &base_type(output)?, 0)?;
        let record = self
            .structs
            .get(&output_type)
            .ok_or("unknown view record")?;
        let [syn::Stmt::Local(_), syn::Stmt::Expr(Expr::Struct(result), None)] =
            def.item.block.stmts.as_slice()
        else {
            return Err(
                "shared view must retain the complete offset and result construction".into(),
            );
        };
        attrs(&result.attrs)?;
        let Some(result_name) = result.path.get_ident() else {
            return Err("shared view needs an unqualified source record constructor".into());
        };
        if result.qself.is_some()
            || result.rest.is_some()
            || self.resolve(&def.module, &result_name.to_string(), 0)? != output_type
            || result.fields.len() != 4
            || record.fields.len() != 4
        {
            return Err("shared view must construct all four output fields explicitly".into());
        }
        let mut copied = None;
        let mut optional = None;
        let mut slots = None;
        let mut output_fields: [String; 4] = Default::default();
        let mut seen = std::collections::BTreeSet::new();
        for field in &result.fields {
            attrs(&field.attrs)?;
            let syn::Member::Named(member) = &field.member else {
                return Err("shared view output fields must be named".into());
            };
            if !seen.insert(member.to_string()) {
                return Err("duplicate view field".into());
            }
            let declared = record
                .fields
                .iter()
                .find(|f| f.ident.as_ref() == Some(member))
                .ok_or("unknown view output field")?;
            attrs(&declared.attrs)?;
            let role = match &field.expr {
                Expr::Field(_) => {
                    let input = path(&field.expr)?;
                    self.field_type(def, &input)?;
                    if copied.replace(input).is_some() {
                        return Err("duplicate copied view field".into());
                    }
                    0
                }
                Expr::MethodCall(_) => {
                    let filter = method(&field.expr, "filter", 1)?;
                    let borrow = method(&filter.receiver, "as_ref", 0)?;
                    let input = path(&borrow.receiver)?;
                    let Type::Path(ty) = self.field_type(def, &input)? else {
                        return Err("filtered view field must be a builtin Option".into());
                    };
                    if ty.qself.is_some()
                        || ty.path.leading_colon.is_some()
                        || ty.path.segments.len() != 1
                        || ty.path.segments[0].ident != "Option"
                    {
                        return Err("filtered view field must be a builtin Option".into());
                    }
                    let callback = closure(&filter.args[0])?;
                    if !matches!(&callback.inputs[0], syn::Pat::Wild(p) if p.attrs.is_empty())
                        || !named(&callback.body, &changed)
                    {
                        return Err("view filter must test its boolean input without inspecting the payload".into());
                    }
                    if optional.replace(input).is_some() {
                        return Err("duplicate optional view field".into());
                    }
                    1
                }
                Expr::Path(_) if named(&field.expr, &offset.argument) => 2,
                Expr::Reference(borrow) => {
                    attrs(&borrow.attrs)?;
                    if borrow.mutability.is_some() {
                        return Err("view slice must be shared".into());
                    }
                    let Expr::Index(slice) = &*borrow.expr else {
                        return Err("view must borrow an explicit slice".into());
                    };
                    attrs(&slice.attrs)?;
                    let input = path(&slice.expr)?;
                    if !matches!(self.field_type(def, &input)?, Type::Array(_)) {
                        return Err("view slice must originate in a builtin array".into());
                    }
                    let Expr::Range(range) = &*slice.index else {
                        return Err("view slice requires an explicit range".into());
                    };
                    attrs(&range.attrs)?;
                    if !matches!(range.limits, syn::RangeLimits::HalfOpen(_))
                        || !range
                            .start
                            .as_deref()
                            .is_some_and(|e| named(e, &offset.local))
                        || path(
                            range
                                .end
                                .as_deref()
                                .ok_or("view slice needs its length endpoint")?,
                        )? != offset.length
                    {
                        return Err("view must borrow offset..length".into());
                    }
                    if slots.replace(input).is_some() {
                        return Err("duplicate slice view field".into());
                    }
                    3
                }
                _ => return Err("unsupported shared view field expression".into()),
            };
            if !output_fields[role].is_empty() {
                return Err("duplicate shared view field role".into());
            }
            output_fields[role] = member.to_string();
        }
        if output_fields.iter().any(String::is_empty) {
            return Err("missing shared view field role".into());
        }
        let f = &def.item;
        Ok(Method {
            name: name.into(), symbol: name.replace("::", "_"), source: def.file.clone(),
            first_line: f.span().start().line, last_line: f.span().end().line, rust: tokens(f),
            writes: vec![], body: vec![], array: None, query: None, constructor: None,
            buffer: None, relocation: None, selection: None, lookup: None, record_at: None,
            iteration: None, last: None, truncation: None, installation: None, restoration: None,
            enum_projection: None, validator: None,
            view: Some(SharedView { offset, copied: copied.unwrap(), optional: optional.unwrap(), slots: slots.unwrap(), output_type, output_fields,
                scope: "complete shared suffix record construction and source-resolved base helper; copied metadata and borrowed optional/slice places; bounds faults retained; source layout, borrow lifetimes, and Rust-to-IR preservation remain open" }),
        })
    }
}

pub(super) fn generate(method: &Method) -> String {
    let view = method.view.as_ref().unwrap();
    let name = &method.symbol;
    let offset = view
        .offset
        .lean_definition(&format!("{name}_offset"))
        .unwrap();
    format!("{offset}def {name}_ir : SharedSuffixProgram := ⟨{name}_offset, {}, {}, {}, {}⟩\ndef {name} (bits : Nat) (state : SharedSuffixStore α) (first : Option Nat) (changed : Bool) : Except ViewFault (SharedSuffixResult α) :=\n  sharedSuffix {name}_ir bits state first changed\ntheorem {name}_correspondence (bits : Nat) (state : SharedSuffixStore α) (first : Option Nat) (changed : Bool) :\n  sharedSuffix {name}_ir bits state first changed = {name} bits state first changed := by rfl\n", lean_path(&view.copied), lean_path(&view.optional), lean_path(&view.slots), lean_path(&view.output_fields))
}
