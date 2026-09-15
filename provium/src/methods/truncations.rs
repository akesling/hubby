//! Complete suffix-removal loops, with source-ordered reads and explicit Drop
//! suspensions. Metadata projection and Rust unwinding refinement remain open.
use super::lookups::{ident, method, named};
use super::*;
#[derive(Debug, Serialize)]
pub struct Truncation {
    pub slots: Vec<String>,
    pub length: Vec<String>,
    pub last_method: String,
    pub last_rust: String,
    pub last: iterations::Last,
    pub index_field: String,
    pub inclusive: bool,
    pub scope: &'static str,
}
impl Crate {
    pub(super) fn lower_truncation(&self, name: &str) -> Result<Method, String> {
        let def = self.methods.get(name).ok_or("unknown truncation method")?;
        let f = &def.item;
        attrs(&f.attrs)?;
        let sig = &f.sig;
        if sig.asyncness.is_some()
            || sig.constness.is_some()
            || sig.unsafety.is_some()
            || sig.abi.is_some()
            || !sig.generics.params.is_empty()
            || sig.generics.where_clause.is_some()
            || !matches!(sig.output, syn::ReturnType::Default)
        {
            return Err("truncation requires a plain unit-returning signature".into());
        }
        let inputs = sig.inputs.iter().collect::<Vec<_>>();
        let [syn::FnArg::Receiver(r), syn::FnArg::Typed(input)] = inputs.as_slice() else {
            return Err("truncation requires &mut self and a u64 boundary".into());
        };
        attrs(&r.attrs)?;
        attrs(&input.attrs)?;
        if r.reference.is_none()
            || r.mutability.is_none()
            || r.colon_token.is_some()
            || tokens(&input.ty) != "u64"
        {
            return Err("truncation requires &mut self and builtin u64".into());
        }
        let argument = ident(&input.pat)?;
        let [syn::Stmt::Expr(Expr::While(loop_), None)] = f.block.stmts.as_slice() else {
            return Err("truncation must retain exactly its complete while loop".into());
        };
        attrs(&loop_.attrs)?;
        if loop_.label.is_some() {
            return Err("labelled truncation loops are unsupported".into());
        }
        let Expr::Binary(and) = &*loop_.cond else {
            return Err("truncation needs ordered short circuit guards".into());
        };
        attrs(&and.attrs)?;
        if !matches!(and.op, syn::BinOp::And(_)) {
            return Err("truncation guard must short circuit with &&".into());
        }
        let Expr::Binary(compare) = &*and.left else {
            return Err("truncation must compare the complete last helper first".into());
        };
        attrs(&compare.attrs)?;
        let inclusive = match compare.op {
            syn::BinOp::Ge(_) => true,
            syn::BinOp::Gt(_) => false,
            _ => return Err("unsupported truncation comparison".into()),
        };
        if !named(&compare.right, &argument) {
            return Err("truncation must compare its input boundary".into());
        }
        let Expr::Field(field) = &*compare.left else {
            return Err("truncation must read a last-record field".into());
        };
        attrs(&field.attrs)?;
        let syn::Member::Named(index_field) = &field.member else {
            return Err("truncation needs a named index field".into());
        };
        let Expr::MethodCall(helper) = &*field.base else {
            return Err("truncation must call the original last helper".into());
        };
        method(&field.base, &helper.method.to_string(), 0)?;
        if !path(&helper.receiver)?.is_empty() {
            return Err("last helper needs self receiver".into());
        }
        let last_method = format!("{}::{}::{}", def.module, def.receiver, helper.method)
            .trim_start_matches("::")
            .to_owned();
        let last_def = self
            .methods
            .get(&last_method)
            .ok_or("unknown last helper")?;
        let syn::ReturnType::Type(_, output) = &last_def.item.sig.output else {
            return Err("last helper needs a concrete record".into());
        };
        let output = self.resolve(&def.module, &base_type(output)?, 0)?;
        let record = self.structs.get(&output).ok_or("unresolved last record")?;
        let leaf = record
            .fields
            .iter()
            .find(|f| f.ident.as_ref() == Some(index_field))
            .ok_or("unknown last index field")?;
        attrs(&leaf.attrs)?;
        if tokens(&leaf.ty) != "u64" {
            return Err("truncation index must be builtin u64".into());
        }
        let lowered = self.lower_last(&last_method)?;
        let last_rust = lowered.rust;
        let last = lowered.last.ok_or("missing last helper translation")?;
        let Expr::Binary(nonempty) = &*and.right else {
            return Err("truncation must test its length after last".into());
        };
        attrs(&nonempty.attrs)?;
        if !matches!(nonempty.op, syn::BinOp::Gt(_)) || !literal(&nonempty.right, 0)? {
            return Err("truncation needs length > 0".into());
        }
        let length = path(&nonempty.left)?;
        if tokens(self.field_type(def, &length)?) != "usize" {
            return Err("truncation length must be builtin usize".into());
        }
        let [syn::Stmt::Expr(Expr::Binary(sub), Some(_)), syn::Stmt::Expr(Expr::Assign(clear), Some(_))] =
            loop_.body.stmts.as_slice()
        else {
            return Err("truncation body must decrement before clearing one slot".into());
        };
        attrs(&sub.attrs)?;
        attrs(&clear.attrs)?;
        if !matches!(sub.op, syn::BinOp::SubAssign(_))
            || path(&sub.left)? != length
            || !literal(&sub.right, 1)?
        {
            return Err("truncation must decrement length by one".into());
        }
        let Expr::Index(slot) = &*clear.left else {
            return Err("truncation must clear its indexed array slot".into());
        };
        attrs(&slot.attrs)?;
        let slots = path(&slot.expr)?;
        if path(&slot.index)? != length || !named(&clear.right, "None") {
            return Err("truncation must assign builtin None at the decremented length".into());
        }
        if slots != last.iteration.slots || length != last.iteration.length {
            return Err(
                "truncation and complete last helper must share their array and length places"
                    .into(),
            );
        }
        // Full last lowering validates the array element, iterator traits, eager
        // default and copied record. No payload Clone or infallible Drop assumed.
        Ok(Method{name:name.into(),symbol:name.replace("::","_"),source:def.file.clone(),first_line:f.span().start().line,last_line:f.span().end().line,rust:tokens(f),writes:vec![],body:vec![],array:None,query:None,constructor:None,buffer:None,relocation:None,selection:None,lookup:None,record_at:None,iteration:None,last:None,installation:None,truncation:Some(Truncation{slots,length,last_method,last_rust,last,index_field:index_field.to_string(),inclusive,scope:"complete suffix-removal loop and original last/iterator/base helpers; length decrement precedes slot Drop suspension; continuations require normally returning destructors; opaque payloads retained separately from record views; projection/layout, borrowing, destructor panic/unwinding refinement remain open"})})
    }
}
fn literal(e: &Expr, value: u64) -> Result<bool, String> {
    let Expr::Lit(l) = e else {
        return Ok(false);
    };
    attrs(&l.attrs)?;
    let syn::Lit::Int(n) = &l.lit else {
        return Ok(false);
    };
    Ok(["", "usize"].contains(&n.suffix())
        && n.base10_parse::<u64>().map_err(|e| e.to_string())? == value)
}
pub(super) fn generate(method: &Method) -> String {
    let t = method.truncation.as_ref().unwrap();
    let name = &method.symbol;
    format!("def {name}_ir : Truncation := ⟨{}, {}, {}, {}, {}⟩\ndef {name} (view : α → Path → InitStore) (records : SelectionStore) (state : BufferState α) (boundary : Nat) : TruncationRun α :=\n  truncateBuffer {name}_ir view records state boundary\ntheorem {name}_correspondence (view : α → Path → InitStore) (records : SelectionStore) (state : BufferState α) (boundary : Nat) :\n  truncateBuffer {name}_ir view records state boundary = {name} view records state boundary := by rfl\n",lean_path(&t.slots),lean_path(&t.length),iterations::last_program(&t.last),lean_path(std::slice::from_ref(&t.index_field)),t.inclusive)
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Run<T> {
    Returned(buffers::State<T>),
    Bounds(buffers::State<T>),
    Drop(T, buffers::State<T>, Box<Run<T>>),
}
impl Truncation {
    /// Evaluate over abstract payload identities. Cloning here records projected
    /// states for inspection; the translated Rust requires no payload Clone.
    /// The reader supplies the immutable metadata projection, not a Rust call.
    pub fn evaluate<T: Clone>(
        &self,
        mut state: buffers::State<T>,
        boundary: u64,
        base: u64,
        read: impl Fn(&T, &str) -> u64,
    ) -> Run<T> {
        let mut drops = Vec::new();
        let mut result = loop {
            let Ok(length) = usize::try_from(state.len) else {
                break Run::Bounds(state);
            };
            let Ok(places) = self.last.iteration.locations(length, &state.slots) else {
                break Run::Bounds(state);
            };
            let place = if self.last.from_back {
                places.last()
            } else {
                places.first()
            };
            let index = place
                .map(|i| read(state.slots[*i].as_ref().unwrap(), &self.index_field))
                .unwrap_or(base);
            if !(if self.inclusive {
                index >= boundary
            } else {
                index > boundary
            }) || state.len == 0
            {
                break Run::Returned(state);
            }
            state.len -= 1;
            let before = state.clone();
            let Some(slot) = state.slots.get_mut(state.len as usize) else {
                break Run::Bounds(state);
            };
            if let Some(payload) = slot.take() {
                drops.push((payload, before));
            }
        };
        for (payload, before) in drops.into_iter().rev() {
            result = Run::Drop(payload, before, Box::new(result));
        }
        result
    }
}
