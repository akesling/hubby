//! Complete snapshot replacement idiom: original equality/lookup/base helpers,
//! prefix rotation, source-ordered clearing, monotonic commit and owned transfer.
use super::lookups::{ident, method, named};
use super::*;
#[derive(Debug, Serialize)]
pub struct Installation {
    pub slots: Vec<String>,
    pub length: Vec<String>,
    pub snapshot: Vec<String>,
    pub commit: Vec<String>,
    pub record_at_method: String,
    pub record_at_rust: String,
    pub record_at: records::At,
    pub record_field: String,
    pub index_field: String,
    pub base_index_field: String,
    pub commit_index_field: String,
    pub equality_fields: Vec<String>,
    pub equal: bool,
    pub rotate_left: bool,
    pub maximum: bool,
    pub scope: &'static str,
}
fn input_field(e: &Expr, input: &str) -> Result<String, String> {
    let Expr::Field(f) = e else {
        return Err("installation needs a named input field".into());
    };
    attrs(&f.attrs)?;
    if !named(&f.base, input) {
        return Err("installation field must read its owned input".into());
    }
    let syn::Member::Named(n) = &f.member else {
        return Err("installation needs named record fields".into());
    };
    Ok(n.to_string())
}
fn leaf(e: &Expr) -> Result<(&Expr, String), String> {
    let Expr::Field(f) = e else {
        return Err("installation needs a scalar record field".into());
    };
    attrs(&f.attrs)?;
    let syn::Member::Named(n) = &f.member else {
        return Err("installation needs named scalar fields".into());
    };
    Ok((&f.base, n.to_string()))
}
impl Crate {
    pub(super) fn lower_installation(&self, name: &str) -> Result<Method, String> {
        let def = self
            .methods
            .get(name)
            .ok_or("unknown installation method")?;
        let f = &def.item;
        let sig = &f.sig;
        attrs(&f.attrs)?;
        if sig.asyncness.is_some()
            || sig.constness.is_some()
            || sig.unsafety.is_some()
            || sig.abi.is_some()
            || !sig.generics.params.is_empty()
            || sig.generics.where_clause.is_some()
            || !matches!(sig.output, syn::ReturnType::Default)
        {
            return Err("installation requires a plain unit-returning signature".into());
        }
        let inputs = sig.inputs.iter().collect::<Vec<_>>();
        let [syn::FnArg::Receiver(r), syn::FnArg::Typed(input)] = inputs.as_slice() else {
            return Err("installation needs &mut self and an owned snapshot".into());
        };
        attrs(&r.attrs)?;
        attrs(&input.attrs)?;
        if r.reference.is_none() || r.mutability.is_none() || r.colon_token.is_some() {
            return Err("installation needs &mut self".into());
        }
        let argument = ident(&input.pat)?;
        let [syn::Stmt::Expr(Expr::If(branch), None), syn::Stmt::Expr(Expr::Assign(commit), Some(_)), syn::Stmt::Expr(Expr::Assign(replace), Some(_))] =
            f.block.stmts.as_slice()
        else {
            return Err("installation must retain its complete branch, commit update and snapshot replacement".into());
        };
        let Expr::Binary(compare) = &*branch.cond else {
            return Err("installation needs its original record equality".into());
        };
        let equal = match compare.op {
            syn::BinOp::Eq(_) => true,
            syn::BinOp::Ne(_) => false,
            _ => return Err("unsupported installation equality".into()),
        };
        let Expr::Call(some) = &*compare.right else {
            return Err("installation must compare Some(input record)".into());
        };
        if !named(&some.func, "Some") || some.args.len() != 1 {
            return Err("installation requires builtin Some".into());
        }
        let record_field = input_field(&some.args[0], &argument)?;
        let Expr::MethodCall(at) = &*compare.left else {
            return Err("installation must call its original record lookup".into());
        };
        method(&compare.left, &at.method.to_string(), 1)?;
        if !path(&at.receiver)?.is_empty() {
            return Err("installation lookup must read self".into());
        }
        let (at_record, index_field) = leaf(&at.args[0])?;
        if input_field(at_record, &argument)? != record_field {
            return Err("installation lookup needs the compared input record".into());
        }
        let record_at_method = format!("{}::{}::{}", def.module, def.receiver, at.method)
            .trim_start_matches("::")
            .to_owned();
        let lowered = self.lower_record_at(&record_at_method)?;
        let record_at_rust = lowered.rust;
        let record_at = lowered.record_at.ok_or("missing complete record lookup")?;
        let snapshot = path(&replace.left)?;
        if snapshot != record_at.lookup.base.optional
            || tokens(self.field_type(def, &snapshot)?)
                != format!("Option < {} >", tokens(&input.ty))
        {
            return Err(
                "installation input and existing snapshot must share their source type/place"
                    .into(),
            );
        }
        let payload_name = base_type(&input.ty)?;
        let payload_name = self.resolve(&def.module, &payload_name, 0)?;
        let payload = self
            .structs
            .get(&payload_name)
            .ok_or("snapshot payload must be a source record")?;
        let field = payload
            .fields
            .iter()
            .find(|f| f.ident.as_ref().is_some_and(|n| n == &record_field))
            .ok_or("unknown snapshot record field")?;
        attrs(&field.attrs)?;
        let ty = base_type(&field.ty)?;
        if tokens(&field.ty) != ty
            || payload.generics.type_params().any(|p| p.ident == ty)
            || self.resolve(&self.struct_modules[&payload_name], &ty, 0)?
                != record_at.lookup.base.record_type
        {
            return Err("snapshot record must match lookup's concrete copied record".into());
        }
        let record = self
            .structs
            .get(&record_at.lookup.base.record_type)
            .ok_or("unknown equality record")?;
        if !record.attrs.iter().any(|a| {
            a.path().is_ident("derive")
                && a.parse_args_with(
                    syn::punctuated::Punctuated::<syn::Ident, syn::Token![,]>::parse_terminated,
                )
                .is_ok_and(|d| d.iter().any(|n| n == "PartialEq"))
        }) {
            return Err("installation equality requires builtin derived PartialEq".into());
        }
        let equality_fields = record
            .fields
            .iter()
            .map(|f| {
                attrs(&f.attrs)?;
                if tokens(&f.ty) != "u64" {
                    return Err(
                        "installation equality currently requires builtin u64 record fields".into(),
                    );
                }
                Ok(f.ident
                    .as_ref()
                    .ok_or("equality needs named fields")?
                    .to_string())
            })
            .collect::<Result<Vec<_>, String>>()?;
        let [syn::Stmt::Local(remove), syn::Stmt::Expr(Expr::MethodCall(rotate), Some(_)), syn::Stmt::Expr(Expr::Binary(decrease), Some(_)), syn::Stmt::Expr(Expr::ForLoop(clear), None)] =
            branch.then_branch.stmts.as_slice()
        else {
            return Err(
                "installation matching branch needs offset, rotation, decrement and suffix clear"
                    .into(),
            );
        };
        let removed = ident(&remove.pat)?;
        let remove_expr = &remove
            .init
            .as_ref()
            .ok_or("installation offset needs initializer")?
            .expr;
        let Expr::Cast(cast) = &**remove_expr else {
            return Err("installation must retain its target-word cast".into());
        };
        let Expr::Paren(paren) = &*cast.expr else {
            return Err("installation offset must retain subtraction grouping".into());
        };
        let Expr::Binary(sub) = &*paren.expr else {
            return Err("installation offset requires subtraction".into());
        };
        let (base_call, base_index_field) = leaf(&sub.right)?;
        let Expr::MethodCall(base) = base_call else {
            return Err("installation offset must call its base helper".into());
        };
        let base_method = format!("{}::{}::{}", def.module, def.receiver, base.method)
            .trim_start_matches("::")
            .to_owned();
        if base_method != record_at.lookup.base_method {
            return Err(
                "installation lookup and subtraction must compose the same complete base helper"
                    .into(),
            );
        }
        let rotate_left = match rotate.method.to_string().as_str() {
            "rotate_left" => true,
            "rotate_right" => false,
            _ => return Err("installation requires builtin prefix rotation".into()),
        };
        let Expr::Index(slice) = &*rotate.receiver else {
            return Err("installation must rotate its prefix slice".into());
        };
        let slots = path(&slice.expr)?;
        let length = path(&decrease.left)?;
        if slots != record_at.lookup.slots || tokens(self.field_type(def, &length)?) != "usize" {
            return Err(
                "installation rotation must share lookup storage and a usize length".into(),
            );
        }
        let clear_name = ident(&clear.pat)?;
        let Some((_, otherwise)) = &branch.else_branch else {
            return Err("installation needs its complete mismatch branch".into());
        };
        let Expr::Block(otherwise) = &**otherwise else {
            return Err("installation mismatch needs a full block".into());
        };
        let [syn::Stmt::Expr(Expr::ForLoop(discard), None), syn::Stmt::Expr(Expr::Assign(_), Some(_))] =
            otherwise.block.stmts.as_slice()
        else {
            return Err("installation mismatch must clear prefix before resetting length".into());
        };
        let discard_name = ident(&discard.pat)?;
        let commit_path = path(&commit.left)?;
        if tokens(self.field_type(def, &commit_path)?) != "u64" {
            return Err("installation commit must be builtin u64".into());
        }
        let Expr::MethodCall(extremum) = &*commit.right else {
            return Err("installation commit must retain its extremum".into());
        };
        let maximum = match extremum.method.to_string().as_str() {
            "max" => true,
            "min" => false,
            _ => return Err("installation requires builtin commit max/min".into()),
        };
        if extremum.args.len() != 1 {
            return Err("installation commit needs one input index".into());
        }
        let (commit_record, commit_index_field) = leaf(&extremum.args[0])?;
        if input_field(commit_record, &argument)? != record_field {
            return Err("installation commit must read its input record".into());
        }
        for field in [&index_field, &base_index_field, &commit_index_field] {
            if !equality_fields.contains(field) {
                return Err("unknown installation index field".into());
            }
        }
        // Reparse a parameterized syntax template and compare the complete AST
        // token stream. All placeholders above are resolved source places/names;
        // no trailing statement, callback, attribute or arithmetic is discarded.
        let slots_expr = tokens(&slice.expr);
        let len_expr = tokens(&decrease.left);
        let commit_expr = tokens(&commit.left);
        let snapshot_expr = tokens(&replace.left);
        let expected=format!("{{if self.{}({argument}.{record_field}.{index_field}) {} Some({argument}.{record_field}) {{let {removed}=({argument}.{record_field}.{index_field}-self.{}().{base_index_field}) as usize;{slots_expr}[..{len_expr}].{}({removed});{len_expr}-={removed};for {clear_name} in &mut {slots_expr}[{len_expr}..]{{*{clear_name}=None;}}}}else{{for {discard_name} in &mut {slots_expr}[..{len_expr}]{{*{discard_name}=None;}}{len_expr}=0;}}{commit_expr}={commit_expr}.{}({argument}.{record_field}.{commit_index_field});{snapshot_expr}=Some({argument});}}",at.method,if equal{"=="}else{"!="},base.method,rotate.method,extremum.method);
        let expected: syn::Block = syn::parse_str(&expected).map_err(|e| e.to_string())?;
        if tokens(&expected) != tokens(&f.block) {
            return Err("unsupported complete installation body: source ordering/effects differ from the checked idiom".into());
        }
        for source in self.files.values() {
            for item in syn::parse_file(source).map_err(|e| e.to_string())?.items {
                if matches!(item,Item::Trait(t) if t.items.iter().any(|i|matches!(i,syn::TraitItem::Fn(f) if ["rotate_left","rotate_right","max","min"].iter().any(|n|f.sig.ident==*n))))
                {
                    return Err("installation builtin operations may resolve to user traits".into());
                }
            }
        }
        Ok(Method{name:name.into(),symbol:name.replace("::","_"),source:def.file.clone(),first_line:f.span().start().line,last_line:f.span().end().line,rust:tokens(f),writes:vec![],body:vec![],array:None,query:None,constructor:None,buffer:None,relocation:None,selection:None,lookup:None,record_at:None,iteration:None,last:None,truncation:None,installation:Some(Installation{slots,length,snapshot,commit:commit_path,record_at_method,record_at_rust,record_at,record_field,index_field,base_index_field,commit_index_field,equality_fields,equal,rotate_left,maximum,scope:"complete snapshot installation with original record-at/lookup/base helpers and derived scalar record equality; rotation/cast/bounds and ordered entry/snapshot Drop suspensions retained; no payload Clone imposed; physical projection, unwinding, destructor side effects and protocol caller invariants remain open"})})
    }
}
pub(super) fn candidate(f: &syn::ImplItemFn) -> bool {
    matches!(f.sig.output, syn::ReturnType::Default)
        && f.sig.inputs.len() == 2
        && matches!(f.block.stmts.last(),Some(syn::Stmt::Expr(Expr::Assign(a),_)) if matches!(&*a.right,Expr::Call(c) if named(&c.func,"Some")))
}
pub(super) fn generate(method: &Method) -> String {
    let i = method.installation.as_ref().unwrap();
    let name = &method.symbol;
    let at = &i.record_at;
    let lookup = lookups::program(&at.lookup);
    let at = format!(
        "⟨{}, {}, {}, {}⟩",
        lookup,
        lean_path(std::slice::from_ref(&at.guard_field)),
        at.equal,
        lean_path(std::slice::from_ref(&at.record_field))
    );
    format!("def {name}_ir : Installation := ⟨{}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}⟩\ndef {name} (bits : Nat) (view : α → Path → InitStore) (snapshotView : β → Path → InitStore) (state : InstallationState α β) (input : β) : InstallationRun α β :=\n  installSnapshot {name}_ir bits view snapshotView state input\ntheorem {name}_correspondence (bits : Nat) (view : α → Path → InitStore) (snapshotView : β → Path → InitStore) (state : InstallationState α β) (input : β) :\n  installSnapshot {name}_ir bits view snapshotView state input = {name} bits view snapshotView state input := by rfl\n",lean_path(&i.slots),lean_path(&i.length),lean_path(&i.snapshot),lean_path(&i.commit),at,lean_path(std::slice::from_ref(&i.record_field)),lean_path(std::slice::from_ref(&i.index_field)),lean_path(std::slice::from_ref(&i.base_index_field)),lean_path(std::slice::from_ref(&i.commit_index_field)),format_args!("[{}]",i.equality_fields.iter().map(|s|lean_path(std::slice::from_ref(s))).collect::<Vec<_>>().join(", ")),i.equal,i.rotate_left,i.maximum)
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct State<T, S> {
    pub buffer: buffers::State<T>,
    pub commit: u64,
    pub snapshot: Option<S>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Run<T, S> {
    Returned(State<T, S>),
    Bounds(State<T, S>, S),
    Subtraction(State<T, S>, S),
    DropEntry(T, State<T, S>, S, Box<Run<T, S>>),
    DropSnapshot(S, State<T, S>, S, Box<Run<T, S>>),
}
impl Installation {
    /// Evaluate with immutable scalar views and abstract payload identities.
    /// Clone records observations; it is not imposed on the translated subject.
    pub fn evaluate<T: Clone, S: Clone>(
        &self,
        bits: u32,
        mut state: State<T, S>,
        input: S,
        entry_view: impl Fn(&T, &str, &str) -> u64,
        snapshot_view: impl Fn(&S, &str, &str) -> u64,
    ) -> Result<Run<T, S>, String> {
        if !matches!(bits, 32 | 64) || u128::from(state.buffer.len) >= 1u128 << bits {
            return Err("installation inputs require a supported target word".into());
        }
        let at = &self.record_at;
        let base = |field: &str| {
            state
                .snapshot
                .as_ref()
                .map(|s| snapshot_view(s, &at.lookup.base.record_field, field))
                .unwrap_or(0)
        };
        let index = snapshot_view(&input, &self.record_field, &self.index_field);
        let record = if (index == base(&at.guard_field)) == at.equal {
            Some(
                self.equality_fields
                    .iter()
                    .map(|f| (f.clone(), base(f)))
                    .collect::<BTreeMap<_, _>>(),
            )
        } else {
            at.lookup
                .evaluate(
                    bits,
                    base(&at.lookup.base_field),
                    index,
                    &state.buffer.slots,
                )?
                .map(|place| {
                    let entry = state.buffer.slots[place].as_ref().unwrap();
                    self.equality_fields
                        .iter()
                        .map(|f| (f.clone(), entry_view(entry, &at.record_field, f)))
                        .collect::<BTreeMap<_, _>>()
                })
        };
        let equal = record.is_some_and(|r| {
            self.equality_fields
                .iter()
                .all(|f| r[f] == snapshot_view(&input, &self.record_field, f))
        });
        let (start, end, reset) = if equal == self.equal {
            let Some(remove) = index.checked_sub(base(&self.base_index_field)) else {
                return Ok(Run::Subtraction(state, input));
            };
            let remove = if bits == 32 {
                remove & u64::from(u32::MAX)
            } else {
                remove
            };
            if state.buffer.len > state.buffer.slots.len() as u64 || remove > state.buffer.len {
                return Ok(Run::Bounds(state, input));
            }
            let length = state.buffer.len as usize;
            if self.rotate_left {
                state.buffer.slots[..length].rotate_left(remove as usize);
            } else {
                state.buffer.slots[..length].rotate_right(remove as usize);
            }
            state.buffer.len -= remove;
            (state.buffer.len as usize, state.buffer.slots.len(), false)
        } else {
            if state.buffer.len > state.buffer.slots.len() as u64 {
                return Ok(Run::Bounds(state, input));
            }
            (0, state.buffer.len as usize, true)
        };
        let mut drops = Vec::new();
        for index in start..end {
            let before = state.clone();
            if let Some(payload) = state.buffer.slots[index].take() {
                drops.push((payload, before));
            }
        }
        if reset {
            state.buffer.len = 0;
        }
        let index = snapshot_view(&input, &self.record_field, &self.commit_index_field);
        state.commit = if self.maximum {
            state.commit.max(index)
        } else {
            state.commit.min(index)
        };
        let old = state.snapshot.clone();
        let before = state.clone();
        state.snapshot = Some(input.clone());
        let mut run = Run::Returned(state);
        if let Some(old) = old {
            run = Run::DropSnapshot(old, before, input.clone(), Box::new(run));
        }
        for (payload, before) in drops.into_iter().rev() {
            run = Run::DropEntry(payload, before, input.clone(), Box::new(run));
        }
        Ok(run)
    }
}
