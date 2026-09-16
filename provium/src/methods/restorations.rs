//! Recovery from a consumer-owned iterator. External calls and destruction are
//! explicit interactions, rather than an assumed infallible list traversal.
use super::lookups::{ident, method, named};
use super::*;
#[derive(Debug, Serialize)]
pub enum Value {
    Constant(u64),
    Hard(Vec<String>),
    Base(String),
    Last(String),
    Entry(String),
    CallLast(String),
}
#[derive(Debug, Serialize)]
pub enum Predicate {
    Boolean(bool),
    And(Box<Predicate>, Box<Predicate>),
    Or(Box<Predicate>, Box<Predicate>),
    Compare(String, Value, Value),
    CheckedCompare {
        equal: bool,
        left: Value,
        increment: u64,
        right: Value,
    },
    SnapshotPresent,
    HardPresent(Vec<String>),
}
#[derive(Debug, Serialize)]
pub struct Restoration {
    pub constructor_method: String,
    pub constructor_rust: String,
    pub constructor: constructors::Constructor,
    pub append_method: String,
    pub append_rust: String,
    pub append: buffers::Append,
    pub last_method: String,
    pub last_rust: String,
    pub last: iterations::Last,
    pub hard: Vec<String>,
    pub snapshot: Vec<String>,
    pub initial_guard: Predicate,
    pub entry_guard: Predicate,
    pub final_guard: Predicate,
    pub error: String,
    pub snapshot_first: bool,
    pub scope: &'static str,
}
struct Context<'a> {
    krate: &'a Crate,
    def: &'a Definition,
    state: String,
    hard: String,
    base: String,
    last: String,
    entry: String,
    hard_path: Vec<String>,
    snapshot_path: Vec<String>,
    record_field: String,
    record_type: String,
    last_method: String,
}
fn local_path(e: &Expr, root: &str) -> Result<Vec<String>, String> {
    match e {
        Expr::Path(p) if p.attrs.is_empty() && p.qself.is_none() && p.path.is_ident(root) => {
            Ok(vec![])
        }
        Expr::Field(f) => {
            attrs(&f.attrs)?;
            let mut p = local_path(&f.base, root)?;
            let syn::Member::Named(n) = &f.member else {
                return Err("recovery requires named fields".into());
            };
            p.push(n.to_string());
            Ok(p)
        }
        _ => Err("recovery field must use its original local binding".into()),
    }
}
fn literal(e: &Expr) -> Result<u64, String> {
    let Expr::Lit(l) = e else {
        return Err("recovery arithmetic needs a u64 literal".into());
    };
    attrs(&l.attrs)?;
    let syn::Lit::Int(n) = &l.lit else {
        return Err("recovery arithmetic needs an integer literal".into());
    };
    if !["", "u64"].contains(&n.suffix()) {
        return Err("recovery arithmetic literal must be u64".into());
    }
    n.base10_parse().map_err(|e| e.to_string())
}
fn tail_guard(branch: &syn::ExprIf) -> Result<&Expr, String> {
    attrs(&branch.attrs)?;
    if branch.else_branch.is_some() {
        return Err("recovery error guards cannot discard an else branch".into());
    }
    let [syn::Stmt::Expr(Expr::Return(ret), Some(_))] = branch.then_branch.stmts.as_slice() else {
        return Err("recovery guard must return its complete error".into());
    };
    attrs(&ret.attrs)?;
    ret.expr
        .as_deref()
        .ok_or_else(|| "recovery guard needs an error return".into())
}
impl Context<'_> {
    fn record_field(&self, field: &str) -> Result<(), String> {
        let record = self
            .krate
            .structs
            .get(&self.record_type)
            .ok_or("unknown recovery record")?;
        let f = record
            .fields
            .iter()
            .find(|f| f.ident.as_ref().is_some_and(|n| n == field))
            .ok_or("unknown recovery record field")?;
        attrs(&f.attrs)?;
        if tokens(&f.ty) != "u64" {
            return Err("recovery record arithmetic requires builtin u64".into());
        }
        Ok(())
    }
    fn value(&self, e: &Expr) -> Result<Value, String> {
        if let Expr::Paren(p) = e {
            attrs(&p.attrs)?;
            return self.value(&p.expr);
        }
        if matches!(e, Expr::Lit(_)) {
            return Ok(Value::Constant(literal(e)?));
        }
        if let Ok(p) = local_path(e, &self.hard) {
            let mut place = self.hard_path.clone();
            place.extend(p.clone());
            if tokens(self.krate.field_type(self.def, &place)?) != "u64" {
                return Err("recovery hard metadata arithmetic requires u64".into());
            }
            return Ok(Value::Hard(p));
        }
        for (root, kind) in [(&self.base, 0), (&self.last, 1), (&self.entry, 2)] {
            if let Ok(p) = local_path(e, root) {
                let field = if kind == 2 {
                    let [record, field] = p.as_slice() else {
                        return Err("recovery entry must project its copied record".into());
                    };
                    if record != &self.record_field {
                        return Err(
                            "recovery entry record must match the complete last helper".into()
                        );
                    }
                    field
                } else {
                    let [field] = p.as_slice() else {
                        return Err("recovery uses scalar copied-record fields".into());
                    };
                    field
                };
                self.record_field(field)?;
                return Ok(match kind {
                    0 => Value::Base(field.clone()),
                    1 => Value::Last(field.clone()),
                    _ => Value::Entry(field.clone()),
                });
            }
        }
        if let Expr::Field(f) = e {
            attrs(&f.attrs)?;
            let syn::Member::Named(field) = &f.member else {
                return Err("recovery call projection needs a named field".into());
            };
            let Expr::MethodCall(c) = &*f.base else {
                return Err("unsupported recovery scalar read".into());
            };
            method(&f.base, &self.last_method, 0)?;
            if !named(&c.receiver, &self.state) {
                return Err("recovery last call must read its owned state".into());
            }
            self.record_field(&field.to_string())?;
            return Ok(Value::CallLast(field.to_string()));
        }
        Err("unsupported recovery scalar expression".into())
    }
    fn predicate(&self, e: &Expr) -> Result<Predicate, String> {
        if let Expr::Paren(p) = e {
            attrs(&p.attrs)?;
            return self.predicate(&p.expr);
        }
        if let Expr::Lit(l) = e {
            attrs(&l.attrs)?;
            if let syn::Lit::Bool(b) = &l.lit {
                return Ok(Predicate::Boolean(b.value));
            }
        }
        if let Expr::MethodCall(c) = e {
            method(e, "is_some", 0)?;
            if let Ok(p) = local_path(&c.receiver, &self.state) {
                if p == self.snapshot_path {
                    return Ok(Predicate::SnapshotPresent);
                }
            }
            if let Ok(p) = local_path(&c.receiver, &self.hard) {
                let mut place = self.hard_path.clone();
                place.extend(p.clone());
                let ty = self.krate.field_type(self.def, &place)?;
                if matches!(ty,Type::Path(t) if t.qself.is_none() && t.path.segments.len()==1 && t.path.segments[0].ident=="Option")
                {
                    return Ok(Predicate::HardPresent(p));
                }
            }
            return Err("recovery presence query needs a source-resolved builtin Option".into());
        }
        let Expr::Binary(b) = e else {
            return Err("unsupported recovery predicate".into());
        };
        attrs(&b.attrs)?;
        match b.op {
            syn::BinOp::And(_) => {
                return Ok(Predicate::And(
                    Box::new(self.predicate(&b.left)?),
                    Box::new(self.predicate(&b.right)?),
                ))
            }
            syn::BinOp::Or(_) => {
                return Ok(Predicate::Or(
                    Box::new(self.predicate(&b.left)?),
                    Box::new(self.predicate(&b.right)?),
                ))
            }
            _ => {}
        }
        if let Expr::MethodCall(c) = &*b.left {
            method(&b.left, "checked_add", 1)?;
            let equal = match b.op {
                syn::BinOp::Eq(_) => true,
                syn::BinOp::Ne(_) => false,
                _ => return Err("checked recovery addition needs an Option equality".into()),
            };
            let Expr::Call(some) = &*b.right else {
                return Err("checked recovery addition must compare Some(index)".into());
            };
            attrs(&some.attrs)?;
            if !named(&some.func, "Some") || some.args.len() != 1 {
                return Err("recovery checked comparison requires builtin Some".into());
            }
            return Ok(Predicate::CheckedCompare {
                equal,
                left: self.value(&c.receiver)?,
                increment: literal(&c.args[0])?,
                right: self.value(&some.args[0])?,
            });
        }
        let op = match b.op {
            syn::BinOp::Eq(_) => "eq",
            syn::BinOp::Ne(_) => "ne",
            syn::BinOp::Lt(_) => "lt",
            syn::BinOp::Le(_) => "le",
            syn::BinOp::Gt(_) => "gt",
            syn::BinOp::Ge(_) => "ge",
            _ => return Err("unsupported recovery comparison".into()),
        };
        Ok(Predicate::Compare(
            op.into(),
            self.value(&b.left)?,
            self.value(&b.right)?,
        ))
    }
}
fn mutable_local(local: &syn::Local) -> Result<String, String> {
    attrs(&local.attrs)?;
    let syn::Pat::Ident(p) = &local.pat else {
        return Err("recovery state needs a plain mutable local".into());
    };
    attrs(&p.attrs)?;
    if p.mutability.is_none() || p.by_ref.is_some() || p.subpat.is_some() {
        return Err("recovery state needs a mutable owned binding".into());
    }
    Ok(p.ident.to_string())
}
impl Crate {
    pub(super) fn lower_restoration(&self, name: &str) -> Result<Method, String> {
        let def = self.methods.get(name).ok_or("unknown restoration method")?;
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
            return Err("restoration requires a plain associated function".into());
        }
        if self.drops.contains(&def.receiver) {
            return Err(
                "restoration receiver Drop requires an explicit external destruction boundary"
                    .into(),
            );
        }
        self.constructor_namespaces(def)?;
        let inputs = sig.inputs.iter().collect::<Vec<_>>();
        let [syn::FnArg::Typed(hard), syn::FnArg::Typed(snapshot), syn::FnArg::Typed(source)] =
            inputs.as_slice()
        else {
            return Err(
                "restoration needs hard metadata, optional snapshot and owned IntoIterator".into(),
            );
        };
        for input in [hard, snapshot, source] {
            attrs(&input.attrs)?;
        }
        let hard_name = ident(&hard.pat)?;
        let snapshot_name = ident(&snapshot.pat)?;
        let source_name = ident(&source.pat)?;
        let [syn::Stmt::Local(new), syn::Stmt::Expr(Expr::Assign(hard_assign), Some(_)), syn::Stmt::Expr(Expr::Assign(snapshot_assign), Some(_)), syn::Stmt::Local(base), syn::Stmt::Expr(Expr::If(initial_guard), None), syn::Stmt::Expr(Expr::ForLoop(iterate), None), syn::Stmt::Expr(Expr::If(final_guard), None), syn::Stmt::Expr(_, None)] =
            f.block.stmts.as_slice()
        else {
            return Err("restoration must retain its full initialization, validation, iteration and final validation".into());
        };
        let state_name = mutable_local(new)?;
        let hard_path = local_path(&hard_assign.left, &state_name)?;
        let snapshot_path = local_path(&snapshot_assign.left, &state_name)?;
        if tokens(self.field_type(def, &hard_path)?) != tokens(&hard.ty)
            || tokens(self.field_type(def, &snapshot_path)?) != tokens(&snapshot.ty)
        {
            return Err("restoration inputs must match the original state field types".into());
        }
        let hard_type = base_type(&hard.ty)?;
        let hard_type = self.resolve(&def.module, &hard_type, 0)?;
        let hard_record = self
            .structs
            .get(&hard_type)
            .ok_or("recovery metadata must be a source record")?;
        if self.drops.contains(&hard_type)
            || !hard_record.attrs.iter().any(|a| {
                a.path().is_ident("derive")
                    && a.parse_args_with(
                        syn::punctuated::Punctuated::<syn::Ident, syn::Token![,]>::parse_terminated,
                    )
                    .is_ok_and(|d| d.iter().any(|n| n == "Copy"))
            })
        {
            return Err("restoration metadata must be builtin derived Copy".into());
        }
        let Expr::Call(new_call) = &*new
            .init
            .as_ref()
            .ok_or("recovery state needs initialization")?
            .expr
        else {
            return Err("recovery state must call its original constructor".into());
        };
        let Expr::Path(new_path) = &*new_call.func else {
            return Err("recovery constructor must be associated with Self".into());
        };
        if new_path.path.segments.len() != 2 {
            return Err("recovery constructor needs Self::method".into());
        }
        let constructor_ident = new_path.path.segments[1].ident.to_string();
        let qualify = |method: &str| {
            format!("{}::{}::{method}", def.module, def.receiver)
                .trim_start_matches("::")
                .to_owned()
        };
        let constructor_method = qualify(&constructor_ident);
        let constructor = self.lower_constructor(&constructor_method)?;
        let constructor_rust = constructor.rust;
        let constructor = constructor
            .constructor
            .ok_or("missing complete constructor")?;
        if !constructor
            .fields
            .iter()
            .any(|f| f.path == snapshot_path && matches!(f.value, constructors::Initial::Absent))
        {
            return Err(
                "recovery replacement currently requires the constructor's absent snapshot".into(),
            );
        }
        let base_name = ident(&base.pat)?;
        let Expr::MethodCall(base_call) = &*base
            .init
            .as_ref()
            .ok_or("recovery base needs initialization")?
            .expr
        else {
            return Err("recovery must call its original base helper".into());
        };
        let entry_name = ident(&iterate.pat)?;
        let [syn::Stmt::Local(last), syn::Stmt::Expr(Expr::If(entry_guard), None), syn::Stmt::Expr(Expr::Try(append_call), Some(_))] =
            iterate.body.stmts.as_slice()
        else {
            return Err(
                "recovery loop must retain last read, validation and checked append".into(),
            );
        };
        let last_name = ident(&last.pat)?;
        let Expr::MethodCall(last_call) = &*last
            .init
            .as_ref()
            .ok_or("recovery last needs initialization")?
            .expr
        else {
            return Err("recovery loop must call its complete last helper".into());
        };
        let last_method = qualify(&last_call.method.to_string());
        let lowered = self.lower_last(&last_method)?;
        let last_rust = lowered.rust;
        let last = lowered.last.ok_or("missing last helper")?;
        if qualify(&base_call.method.to_string()) != last.base_method
            || last.base.optional != snapshot_path
        {
            return Err("recovery must share its complete base and snapshot places".into());
        }
        let Expr::MethodCall(append) = &*append_call.expr else {
            return Err("recovery must call its complete append helper".into());
        };
        let append_method = qualify(&append.method.to_string());
        let lowered = self.lower_buffer(&append_method)?;
        let append_rust = lowered.rust;
        let append = lowered.buffer.ok_or("missing complete append helper")?;
        if append.slots != last.iteration.slots
            || append.length != last.iteration.length
            || append.increment == 0
        {
            return Err(
                "recovery requires shared storage and strictly advancing append lengths".into(),
            );
        }
        let expected_source_type: Type = syn::parse_str(&format!(
            "impl IntoIterator<Item={}>",
            last.iteration.payload_type
        ))
        .map_err(|e| e.to_string())?;
        if tokens(&source.ty) != tokens(&expected_source_type) {
            return Err(
                "recovery requires builtin IntoIterator over the original entry payload".into(),
            );
        }
        let structure = self
            .structs
            .get(&def.receiver)
            .ok_or("unknown recovery state")?;
        let required = [&hard_path, &snapshot_path, &append.slots, &append.length];
        if required.iter().any(|p| p.len() != 1)
            || structure.fields.len() != 4
            || structure.fields.iter().any(|f| {
                !required
                    .iter()
                    .any(|p| f.ident.as_ref().is_some_and(|n| n == &p[0]))
            })
        {
            return Err("recovery destruction currently requires exactly the metadata, snapshot, array and length fields".into());
        }
        let snapshot_position = structure
            .fields
            .iter()
            .position(|f| f.ident.as_ref().is_some_and(|n| n == &snapshot_path[0]))
            .unwrap();
        let slots_position = structure
            .fields
            .iter()
            .position(|f| f.ident.as_ref().is_some_and(|n| n == &append.slots[0]))
            .unwrap();
        let snapshot_first = snapshot_position < slots_position;
        let bindings = [
            &hard_name,
            &snapshot_name,
            &source_name,
            &state_name,
            &base_name,
            &last_name,
            &entry_name,
        ];
        if bindings
            .iter()
            .collect::<std::collections::BTreeSet<_>>()
            .len()
            != bindings.len()
        {
            return Err("recovery local shadowing requires scoped name resolution".into());
        }
        let ctx = Context {
            krate: self,
            def,
            state: state_name.clone(),
            hard: hard_name.clone(),
            base: base_name.clone(),
            last: last_name.clone(),
            entry: entry_name.clone(),
            hard_path: hard_path.clone(),
            snapshot_path: snapshot_path.clone(),
            record_field: last.record_field.clone(),
            record_type: last.base.record_type.clone(),
            last_method: last_call.method.to_string(),
        };
        let initial = ctx.predicate(&initial_guard.cond)?;
        let per_entry = ctx.predicate(&entry_guard.cond)?;
        let final_ = ctx.predicate(&final_guard.cond)?;
        if !initial.valid_scope(false) || !per_entry.valid_scope(true) || !final_.valid_scope(false)
        {
            return Err("recovery guard reads a binding outside its Rust scope".into());
        }
        // Base is cached before initial validation, last before each entry check.
        // Final last calls remain lazy leaves of the short-circuit predicate.
        let error = tail_guard(initial_guard)?;
        if tokens(tail_guard(entry_guard)?) != tokens(error)
            || tokens(tail_guard(final_guard)?) != tokens(error)
        {
            return Err("recovery guards must return the same typed unit error".into());
        }
        let Expr::Call(error_call) = error else {
            return Err("recovery errors require builtin Err".into());
        };
        attrs(&error_call.attrs)?;
        if !named(&error_call.func, "Err") || error_call.args.len() != 1 {
            return Err("recovery errors require Err(unit variant)".into());
        }
        let Expr::Path(error_path) = &error_call.args[0] else {
            return Err("recovery needs a resolved error variant".into());
        };
        attrs(&error_path.attrs)?;
        if error_path.path.segments.len() != 2 {
            return Err("recovery needs a source error type and variant".into());
        }
        let error_type = error_path.path.segments[0].ident.to_string();
        let variant = error_path.path.segments[1].ident.to_string();
        let error_resolved = self.resolve(&def.module, &error_type, 0)?;
        let enumeration = self
            .enums
            .get(&error_resolved)
            .ok_or("unresolved recovery error enum")?;
        if !enumeration
            .variants
            .iter()
            .any(|v| v.ident == variant && matches!(v.fields, syn::Fields::Unit))
        {
            return Err("recovery error must be a source unit variant".into());
        }
        if tokens(&sig.output) != format!("-> Result < Self , {error_type} >") {
            return Err("recovery result must be Result<Self, Error>".into());
        }
        let hard_expr = tokens(&hard_assign.left);
        let snapshot_expr = tokens(&snapshot_assign.left);
        let expected=format!("{{let mut {state_name}=Self::{constructor_ident}();{hard_expr}={hard_name};{snapshot_expr}={snapshot_name};let {base_name}={state_name}.{}();if {}{{return {};}}for {entry_name} in {source_name}{{let {last_name}={state_name}.{}();if {}{{return {};}}{state_name}.{}({entry_name})?;}}if {}{{return {};}}Ok({state_name})}}",base_call.method,tokens(&initial_guard.cond),tokens(error),last_call.method,tokens(&entry_guard.cond),tokens(error),self.methods[&append_method].item.sig.ident,tokens(&final_guard.cond),tokens(error));
        let expected: syn::Block = syn::parse_str(&expected).map_err(|e| e.to_string())?;
        if tokens(&expected) != tokens(&f.block) {
            return Err("unsupported complete restoration body: initialization, loop or cleanup ordering differs".into());
        }
        Ok(Method{name:name.into(),symbol:name.replace("::","_"),source:def.file.clone(),first_line:f.span().start().line,last_line:f.span().end().line,rust:tokens(f),writes:vec![],body:vec![],array:None,query:None,constructor:None,buffer:None,relocation:None,selection:None,lookup:None,record_at:None,iteration:None,last:None,truncation:None,installation:None,enum_projection:None,validator:None,view:None,restoration:Some(Restoration{constructor_method,constructor_rust,constructor,append_method,append_rust,append,last_method,last_rust,last,hard:hard_path,snapshot:snapshot_path,initial_guard:initial,entry_guard:per_entry,final_guard:final_,error:format!("{error_type}::{variant}"),snapshot_first,scope:"complete restoration with original constructor/append/last/iterator/base helpers; explicit IntoIterator/next and source/iterator/entry/snapshot destruction interactions; normally returning callbacks only; field-view, ownership/unwinding and persistent/protocol reachability refinement remain open"})})
    }
}
pub(super) fn candidate(f: &syn::ImplItemFn) -> bool {
    f.sig.inputs.len() == 3
        && f.sig.receiver().is_none()
        && tokens(&f.sig.output).starts_with("-> Result < Self ,")
}
fn value(v: &Value) -> String {
    match v {
        Value::Constant(n) => format!(".constant {n}"),
        Value::Hard(p) => format!(".hard {}", lean_path(p)),
        Value::Base(p) => format!(".base {}", lean_path(std::slice::from_ref(p))),
        Value::Last(p) => format!(".last {}", lean_path(std::slice::from_ref(p))),
        Value::Entry(p) => format!(".entry {}", lean_path(std::slice::from_ref(p))),
        Value::CallLast(p) => format!(".callLast {}", lean_path(std::slice::from_ref(p))),
    }
}
fn predicate(p: &Predicate) -> String {
    match p {
        Predicate::Boolean(b) => format!(".boolean {b}"),
        Predicate::And(a, b) => format!(".and ({}) ({})", predicate(a), predicate(b)),
        Predicate::Or(a, b) => format!(".or ({}) ({})", predicate(a), predicate(b)),
        Predicate::Compare(op, a, b) => format!(".compare {op:?} ({}) ({})", value(a), value(b)),
        Predicate::CheckedCompare {
            equal,
            left,
            increment,
            right,
        } => format!(
            ".checkedCompare {equal} ({}) {increment} ({})",
            value(left),
            value(right)
        ),
        Predicate::SnapshotPresent => ".snapshotPresent".into(),
        Predicate::HardPresent(p) => format!(".hardPresent {}", lean_path(p)),
    }
}
pub(super) fn generate(method: &Method) -> String {
    let r = method.restoration.as_ref().unwrap();
    let name = &method.symbol;
    let fields = r
        .constructor
        .fields
        .iter()
        .map(|f| {
            format!(
                "⟨{}, {}⟩",
                lean_path(&f.path),
                constructors::initial(&f.value)
            )
        })
        .collect::<Vec<_>>()
        .join(", ");
    let a = &r.append;
    let append = format!(
        "⟨{}, {}, {:?}, {}, {}, {:?}⟩",
        lean_path(&a.slots),
        lean_path(&a.length),
        a.capacity,
        a.equal,
        a.increment,
        a.error
    );
    format!("def {name}_ir : Restoration := ⟨[{fields}], {append}, {}, {}, {}, {}, {}, {}, {:?}, {}⟩\ndef {name} (bits : Nat) (sizes : String → Nat) (view : α → Path → InitStore) (snapshotView : β → Path → InitStore) (hardView : δ → InitStore) (hardPresence : δ → Path → Bool) (hard : δ) (snapshot : Option β) (source : σ) : RecoveryRun α β δ σ ι :=\n  restoreState {name}_ir bits sizes view snapshotView hardView hardPresence hard snapshot source\ntheorem {name}_correspondence (bits : Nat) (sizes : String → Nat) (view : α → Path → InitStore) (snapshotView : β → Path → InitStore) (hardView : δ → InitStore) (hardPresence : δ → Path → Bool) (hard : δ) (snapshot : Option β) (source : σ) :\n  restoreState {name}_ir bits sizes view snapshotView hardView hardPresence hard snapshot source = ({name} bits sizes view snapshotView hardView hardPresence hard snapshot source : RecoveryRun α β δ σ ι) := by rfl\n",iterations::last_program(&r.last),lean_path(&r.hard),lean_path(&r.snapshot),predicate(&r.initial_guard),predicate(&r.entry_guard),predicate(&r.final_guard),r.error,r.snapshot_first)
}

impl Predicate {
    fn valid_scope(&self, in_loop: bool) -> bool {
        let value = |v: &Value| in_loop || !matches!(v, Value::Last(_) | Value::Entry(_));
        match self {
            Self::And(a, b) | Self::Or(a, b) => a.valid_scope(in_loop) && b.valid_scope(in_loop),
            Self::Compare(_, a, b) => value(a) && value(b),
            Self::CheckedCompare { left, right, .. } => value(left) && value(right),
            _ => true,
        }
    }
}
