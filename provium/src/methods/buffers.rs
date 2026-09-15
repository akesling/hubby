//! Complete bounded append bodies. Destruction is an explicit suspension point:
//! a continuation describes execution only if the consumer's destructor returns.
//! This is not a model of unwinding through a panicking destructor.
use super::*;

#[derive(Debug, Serialize)]
pub struct Append {
    pub slots: Vec<String>,
    pub length: Vec<String>,
    pub capacity: String,
    pub guard_method: String,
    pub guard_rust: String,
    pub equal: bool,
    pub increment: u64,
    pub error: String,
    pub scope: &'static str,
}
fn plain(sig: &syn::Signature) -> Result<(), String> {
    if sig.asyncness.is_some()
        || sig.unsafety.is_some()
        || sig.constness.is_some()
        || sig.abi.is_some()
        || !sig.generics.params.is_empty()
        || sig.generics.where_clause.is_some()
    {
        return Err("buffer methods require plain synchronous signatures".into());
    }
    Ok(())
}
fn call<'a>(e: &'a Expr, name: &str) -> Result<&'a Expr, String> {
    let Expr::Call(c) = e else {
        return Err(format!("expected {name} constructor"));
    };
    attrs(&c.attrs)?;
    let Expr::Path(p) = &*c.func else {
        return Err("expected builtin constructor".into());
    };
    attrs(&p.attrs)?;
    if p.qself.is_some() || !p.path.is_ident(name) || c.args.len() != 1 {
        return Err(format!("expected unary builtin {name}"));
    }
    Ok(&c.args[0])
}
impl Crate {
    pub(super) fn lower_buffer(&self, name: &str) -> Result<Method, String> {
        let def = self.methods.get(name).ok_or("unknown buffer method")?;
        let f = &def.item;
        attrs(&f.attrs)?;
        plain(&f.sig)?;
        let inputs = f.sig.inputs.iter().collect::<Vec<_>>();
        let [syn::FnArg::Receiver(r), syn::FnArg::Typed(input)] = inputs.as_slice() else {
            return Err("buffer append requires &mut self and one owned payload".into());
        };
        attrs(&r.attrs)?;
        attrs(&input.attrs)?;
        if r.reference.is_none() || r.mutability.is_none() || r.colon_token.is_some() {
            return Err("buffer append requires &mut self".into());
        }
        let syn::Pat::Ident(arg) = &*input.pat else {
            return Err("buffer payload requires an identifier".into());
        };
        attrs(&arg.attrs)?;
        if arg.by_ref.is_some() || arg.mutability.is_some() || arg.subpat.is_some() {
            return Err("buffer payload must be a plain owned binding".into());
        }
        let [syn::Stmt::Expr(Expr::If(guard), None), syn::Stmt::Expr(Expr::Assign(store), Some(_)), syn::Stmt::Expr(Expr::Binary(add), Some(_)), syn::Stmt::Expr(ok, None)] =
            f.block.stmts.as_slice()
        else {
            return Err("unsupported complete buffer body: expected guard, indexed store, length increment, Ok".into());
        };
        attrs(&guard.attrs)?;
        attrs(&store.attrs)?;
        attrs(&add.attrs)?;
        if guard.else_branch.is_some() {
            return Err("buffer guard cannot have an else branch".into());
        }
        let [syn::Stmt::Expr(Expr::Return(ret), Some(_))] = guard.then_branch.stmts.as_slice()
        else {
            return Err("buffer guard must return its error".into());
        };
        attrs(&ret.attrs)?;
        let error_expr = call(ret.expr.as_deref().ok_or("missing error")?, "Err")?;
        let Expr::Path(error) = error_expr else {
            return Err("expected unit enum variant".into());
        };
        attrs(&error.attrs)?;
        let error_type = queries::result_error(&f.sig.output)?;
        let resolved = self.resolve(&def.module, &error_type, 0)?;
        if error.qself.is_some()
            || error.path.leading_colon.is_some()
            || error.path.segments.len() != 2
            || error.path.segments[0].ident != error_type
            || error
                .path
                .segments
                .iter()
                .any(|s| !matches!(s.arguments, syn::PathArguments::None))
        {
            return Err("buffer error must resolve to its declared enum".into());
        }
        let declaration = self
            .enums
            .get(&resolved)
            .ok_or("unresolved buffer error enum")?;
        let variant = declaration
            .variants
            .iter()
            .find(|v| v.ident == error.path.segments[1].ident)
            .ok_or("unknown error variant")?;
        attrs(&variant.attrs)?;
        if !matches!(variant.fields, syn::Fields::Unit) {
            return Err("buffer error must be a unit variant".into());
        }
        if !matches!(call(ok,"Ok")?,Expr::Tuple(t) if t.elems.is_empty() && t.attrs.is_empty()) {
            return Err("expected Ok(())".into());
        }
        let Expr::Index(index) = &*store.left else {
            return Err("buffer write requires indexed array".into());
        };
        attrs(&index.attrs)?;
        let slots = path(&index.expr)?;
        let length = path(&index.index)?;
        if slots.len() != 1
            || length.len() != 1
            || tokens(self.field_type(def, &length)?) != "usize"
        {
            return Err("buffer fields must be direct array and usize leaves".into());
        }
        let Type::Array(array) = self.field_type(def, &slots)? else {
            return Err("buffer storage must be a builtin array".into());
        };
        let expected = format!("Option < {} >", tokens(&input.ty));
        if tokens(&array.elem) != expected {
            return Err("buffer slot must be builtin Option of the owned input type".into());
        }
        let Expr::Path(value) = call(&store.right, "Some")? else {
            return Err("buffer must store its owned input".into());
        };
        attrs(&value.attrs)?;
        if value.qself.is_some() || !value.path.is_ident(&arg.ident.to_string()) {
            return Err("buffer must store its owned input".into());
        }
        if !matches!(add.op, syn::BinOp::AddAssign(_)) || path(&add.left)? != length {
            return Err("buffer must increment the indexed length".into());
        }
        let Expr::Lit(literal) = &*add.right else {
            return Err("buffer increment must be a usize literal".into());
        };
        attrs(&literal.attrs)?;
        let syn::Lit::Int(n) = &literal.lit else {
            return Err("buffer increment must be a usize literal".into());
        };
        if !["", "usize"].contains(&n.suffix()) {
            return Err("buffer increment must be usize".into());
        }
        let increment = n.base10_parse().map_err(|e| format!("{e}"))?;
        // Resolve the array's declared const parameter through the actual impl.
        let structure = self
            .structs
            .get(&def.receiver)
            .ok_or("unknown buffer receiver")?;
        let Some(Type::Path(receiver)) = &def.self_type else {
            return Err("unresolved buffer self type".into());
        };
        let syn::PathArguments::AngleBracketed(arguments) = &receiver
            .path
            .segments
            .last()
            .ok_or("missing receiver")?
            .arguments
        else {
            return Err("buffer requires explicit generic capacity".into());
        };
        if arguments.args.len() != structure.generics.params.len() {
            return Err("buffer generic substitution is incomplete".into());
        }
        let mut capacity = None;
        for (p, a) in structure.generics.params.iter().zip(&arguments.args) {
            match p {
                syn::GenericParam::Type(t) if t.ident != tokens(a) => {
                    return Err("buffer type substitution requires identity type arguments".into())
                }
                syn::GenericParam::Const(c) if c.ident == tokens(&array.len) => {
                    let name = tokens(a);
                    if tokens(&c.ty) != "usize"
                        || !def
                            .impl_generics
                            .const_params()
                            .any(|c| c.ident == name && tokens(&c.ty) == "usize")
                    {
                        return Err(
                            "buffer capacity must resolve to an impl usize const parameter".into(),
                        );
                    }
                    capacity = Some(name);
                }
                syn::GenericParam::Lifetime(_) => {
                    return Err("buffer lifetime substitution unsupported".into())
                }
                _ => {}
            }
        }
        let capacity = capacity.ok_or("unresolved buffer array capacity")?;
        let Expr::MethodCall(c) = &*guard.cond else {
            return Err("buffer guard requires a source-resolved shared helper".into());
        };
        attrs(&c.attrs)?;
        if !path(&c.receiver)?.is_empty() || !c.args.is_empty() || c.turbofish.is_some() {
            return Err("buffer guard must be receiver-only".into());
        }
        let guard_method = format!("{}::{}::{}", def.module, def.receiver, c.method)
            .trim_start_matches("::")
            .to_owned();
        let helper = self
            .methods
            .get(&guard_method)
            .ok_or("unresolved buffer guard")?;
        // This validates its signature, field types, const inputs and every source statement.
        self.scalar_projections(&guard_method)?;
        if tokens(&helper.self_type) != tokens(&def.self_type)
            || tokens(&helper.impl_generics) != tokens(&def.impl_generics)
        {
            return Err("buffer helper requires identical impl substitutions".into());
        }
        let [syn::Stmt::Expr(Expr::Binary(compare), None)] = helper.item.block.stmts.as_slice()
        else {
            return Err("buffer guard must retain a complete capacity comparison".into());
        };
        attrs(&compare.attrs)?;
        if path(&compare.left)? != length
            || !matches!(&*compare.right,Expr::Path(p) if p.attrs.is_empty() && p.qself.is_none() && p.path.is_ident(&capacity))
        {
            return Err("buffer guard must compare length with its actual capacity".into());
        }
        let equal = match compare.op {
            syn::BinOp::Eq(_) => true,
            syn::BinOp::Ne(_) => false,
            _ => return Err("unsupported buffer comparison".into()),
        };
        Ok(Method{name:name.into(),symbol:name.replace("::","_"),source:def.file.clone(),first_line:f.span().start().line,last_line:f.span().end().line,rust:tokens(f),writes:vec![],body:vec![],array:None,query:None,constructor:None,iteration:None,last:None,truncation:None,installation:None,restoration:None,enum_projection:None,record_at:None,lookup:None,selection:None,relocation:None,buffer:Some(Append{slots,length,capacity,guard_method,guard_rust:tokens(&helper.item),equal,increment,error:format!("{resolved}::{}",variant.ident),scope:"complete bounded append and source-resolved guard; drop suspension resumes only when destruction returns; destructor unwinding, Rust layout/borrow and frontend correspondence remain unproved"})})
    }
}
pub(super) fn generate(method: &Method) -> String {
    let a = method.buffer.as_ref().unwrap();
    let name = &method.symbol;
    format!("def {name}_ir : BufferAppend := ⟨{}, {}, {:?}, {}, {}, {:?}⟩\ndef {name} (bits capacity : Nat) (state : BufferState α) (input : α) : BufferRun α :=\n  appendBuffer {name}_ir bits capacity state input\ntheorem {name}_correspondence (bits capacity : Nat) (state : BufferState α) (input : α) :\n  appendBuffer {name}_ir bits capacity state input = {name} bits capacity state input := by rfl\n",lean_path(&a.slots),lean_path(&a.length),a.capacity,a.equal,a.increment,a.error)
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct State<T> {
    pub slots: Vec<Option<T>>,
    pub len: u64,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Run<T> {
    Returned(Result<(), String>, State<T>),
    Bounds(State<T>),
    Overflow(State<T>),
    Drop(T, State<T>, Box<Run<T>>),
}
impl Append {
    /// Execute the IR on representable word inputs. Drop callbacks are exposed,
    /// never executed or assumed to return by this evaluator.
    pub fn evaluate<T: Clone>(
        &self,
        bits: u32,
        capacity: u64,
        state: State<T>,
        input: T,
    ) -> Result<Run<T>, String> {
        if !matches!(bits, 32 | 64)
            || u128::from(capacity) >= 1u128 << bits
            || u128::from(state.len) >= 1u128 << bits
            || u128::from(self.increment) >= 1u128 << bits
        {
            return Err("buffer input or increment is not a target usize".into());
        }
        if (state.len == capacity) == self.equal {
            return Ok(Run::Drop(
                input,
                state.clone(),
                Box::new(Run::Returned(Err(self.error.clone()), state)),
            ));
        }
        let Some(previous) = usize::try_from(state.len)
            .ok()
            .and_then(|i| state.slots.get(i))
        else {
            return Ok(Run::Drop(
                input,
                state.clone(),
                Box::new(Run::Bounds(state)),
            ));
        };
        let mut stored = state.clone();
        stored.slots[state.len as usize] = Some(input);
        let length = u128::from(state.len) + u128::from(self.increment);
        let next = if length < 1u128 << bits {
            stored.len = length as u64;
            Run::Returned(Ok(()), stored)
        } else {
            Run::Overflow(stored)
        };
        Ok(match previous {
            None => next,
            Some(old) => Run::Drop(old.clone(), state, Box::new(next)),
        })
    }
}
