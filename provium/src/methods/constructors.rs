//! Closed record construction from literals, builtin derived Default and empty
//! Option arrays. No source statement or initializer callback is skipped.
use super::*;

#[derive(Debug, Serialize, Clone)]
pub enum Capacity {
    Fixed(u64),
    Parameter(String),
}
#[derive(Debug, Serialize)]
pub enum Initial {
    Boolean(bool),
    Unsigned { rust_type: String, value: u64 },
    Absent,
    EmptySlots(Capacity),
}
#[derive(Debug, Serialize)]
pub struct Field {
    pub path: Vec<String>,
    pub value: Initial,
}
#[derive(Debug, Serialize)]
pub struct Constructor {
    pub fields: Vec<Field>,
    pub constants: Vec<String>,
}

fn optional(ty: &Type) -> bool {
    matches!(ty,Type::Path(p) if p.qself.is_none() && p.path.segments.len()==1 && p.path.segments[0].ident=="Option" && matches!(&p.path.segments[0].arguments,syn::PathArguments::AngleBracketed(a) if a.args.len()==1 && matches!(a.args[0],syn::GenericArgument::Type(_))))
}
fn unsigned(ty: &Type) -> bool {
    ["u8", "u16", "u32", "u64", "usize"].contains(&tokens(ty).as_str())
}
fn none(e: &Expr) -> bool {
    matches!(e,Expr::Path(p) if p.qself.is_none() && p.attrs.is_empty() && p.path.is_ident("None"))
}

impl Crate {
    pub(super) fn lower_constructor(&self, name: &str) -> Result<Method, String> {
        let def = self.methods.get(name).ok_or("unknown constructor")?;
        let f = &def.item;
        let sig = &f.sig;
        attrs(&f.attrs)?;
        if !sig.inputs.is_empty()
            || sig.asyncness.is_some()
            || sig.unsafety.is_some()
            || sig.constness.is_some()
            || sig.abi.is_some()
            || !sig.generics.params.is_empty()
            || sig.generics.where_clause.is_some()
            || !matches!(&sig.output,syn::ReturnType::Type(_,ty) if matches!(&**ty,Type::Path(p) if p.path.is_ident("Self")))
        {
            return Err(
                "constructor requires a plain argument-free Self-returning function".into(),
            );
        }
        // The accepted standard operations must not resolve to local names.
        if self
            .imports
            .keys()
            .any(|(_, n)| ["core", "Default"].contains(&n.as_str()))
            || self
                .struct_modules
                .keys()
                .any(|n| ["core", "Default"].contains(&n.as_str()))
            || def
                .impl_generics
                .type_params()
                .any(|p| p.ident == "core" || p.ident == "Default")
        {
            return Err("constructor builtin namespace is shadowed".into());
        }
        for source in self.files.values() {
            for item in syn::parse_file(source).map_err(|e| e.to_string())?.items {
                match item {
                    Item::Mod(m) if m.ident == "core" || m.ident == "Default" => {
                        return Err("constructor builtin namespace is shadowed".into())
                    }
                    Item::Trait(t) if t.ident == "Default" => {
                        return Err("constructor Default trait is shadowed".into())
                    }
                    Item::ExternCrate(e)
                        if e.rename.as_ref().is_some_and(|(_, id)| id == "core") =>
                    {
                        return Err("constructor core crate is shadowed".into())
                    }
                    _ => {}
                }
            }
        }
        let structure = self
            .structs
            .get(&def.receiver)
            .ok_or("constructor receiver is not a struct")?;
        if structure.generics.type_params().any(|p| {
            [
                "Option", "Result", "bool", "u8", "u16", "u32", "u64", "usize", "Default", "core",
            ]
            .iter()
            .any(|n| p.ident == *n)
        }) {
            return Err("constructor generic parameter shadows a builtin type".into());
        }
        self.resolve(&def.module, &def.receiver, 0)?;
        let [syn::Stmt::Expr(Expr::Struct(value), None)] = f.block.stmts.as_slice() else {
            return Err("constructor must translate its complete record initializer".into());
        };
        attrs(&value.attrs)?;
        if value.qself.is_some() || !value.path.is_ident("Self") || value.rest.is_some() {
            return Err("constructor requires explicit Self fields without update syntax".into());
        }
        let mut constants = BTreeMap::new();
        for c in def.impl_generics.const_params() {
            attrs(&c.attrs)?;
            if tokens(&c.ty) != "usize" {
                return Err("constructor capacities must be usize const parameters".into());
            }
            constants.insert(
                c.ident.to_string(),
                Capacity::Parameter(c.ident.to_string()),
            );
        }
        let Some(Type::Path(self_ty)) = &def.self_type else {
            return Err("unresolved constructor self type".into());
        };
        let arguments = match &self_ty
            .path
            .segments
            .last()
            .ok_or("missing self type")?
            .arguments
        {
            syn::PathArguments::None => vec![],
            syn::PathArguments::AngleBracketed(a) => a.args.iter().collect(),
            _ => return Err("unsupported constructor type arguments".into()),
        };
        if arguments.len() != structure.generics.params.len() {
            return Err("constructor generic substitution requires explicit arguments".into());
        }
        let mut substitutions = BTreeMap::new();
        for (parameter, argument) in structure.generics.params.iter().zip(arguments) {
            if let syn::GenericParam::Const(c) = parameter {
                let expression = match argument {
                    syn::GenericArgument::Const(e) => e.clone(),
                    syn::GenericArgument::Type(Type::Path(p)) if p.qself.is_none() => {
                        syn::parse2(p.to_token_stream()).map_err(|e| e.to_string())?
                    }
                    _ => return Err("unresolved constructor const argument".into()),
                };
                substitutions.insert(
                    c.ident.to_string(),
                    Self::capacity(&expression, &constants)?,
                );
            }
        }
        let mut fields = vec![];
        let mut names = std::collections::BTreeSet::new();
        for field in &value.fields {
            attrs(&field.attrs)?;
            let syn::Member::Named(name) = &field.member else {
                return Err("constructor requires named fields".into());
            };
            if !names.insert(name.to_string()) {
                return Err("duplicate constructor field".into());
            }
            let declaration = structure
                .fields
                .iter()
                .find(|f| f.ident.as_ref() == Some(name))
                .ok_or("unknown constructor field")?;
            attrs(&declaration.attrs)?;
            self.initial(
                &def.module,
                &declaration.ty,
                &field.expr,
                vec![name.to_string()],
                &substitutions,
                &mut fields,
            )?;
        }
        if names.len() != structure.fields.len() {
            return Err("constructor must initialize every source field".into());
        }
        Ok(Method {
            name: name.into(),
            symbol: name.replace("::", "_"),
            source: def.file.clone(),
            first_line: f.span().start().line,
            last_line: f.span().end().line,
            rust: tokens(f),
            writes: vec![],
            body: vec![],
            array: None,
            query: None,
            relocation: None,
            buffer: None,
            constructor: Some(Constructor {
                fields,
                constants: constants.into_keys().collect(),
            }),
        })
    }
    fn capacity(expr: &Expr, constants: &BTreeMap<String, Capacity>) -> Result<Capacity, String> {
        match expr {
            Expr::Lit(l) if l.attrs.is_empty() => {
                if let syn::Lit::Int(i) = &l.lit {
                    Ok(Capacity::Fixed(
                        i.base10_parse().map_err(|e| e.to_string())?,
                    ))
                } else {
                    Err("invalid capacity literal".into())
                }
            }
            Expr::Path(p)
                if p.qself.is_none()
                    && p.attrs.is_empty()
                    && p.path.segments.len() == 1
                    && matches!(p.path.segments[0].arguments, syn::PathArguments::None) =>
            {
                constants
                    .get(&p.path.segments[0].ident.to_string())
                    .cloned()
                    .ok_or("unresolved constructor capacity".into())
            }
            _ => Err("unsupported constructor capacity expression".into()),
        }
    }
    fn initial(
        &self,
        module: &str,
        ty: &Type,
        expr: &Expr,
        path: Vec<String>,
        constants: &BTreeMap<String, Capacity>,
        fields: &mut Vec<Field>,
    ) -> Result<(), String> {
        if none(expr) && optional(ty) {
            fields.push(Field {
                path,
                value: Initial::Absent,
            });
            return Ok(());
        }
        if let Expr::Lit(l) = expr {
            attrs(&l.attrs)?;
            let value = match &l.lit {
                syn::Lit::Int(i) if unsigned(ty) => Initial::Unsigned {
                    rust_type: tokens(ty),
                    value: i.base10_parse().map_err(|e| e.to_string())?,
                },
                syn::Lit::Bool(b) if tokens(ty) == "bool" => Initial::Boolean(b.value),
                _ => return Err("constructor literal does not match a builtin field".into()),
            };
            fields.push(Field { path, value });
            return Ok(());
        }
        if let Expr::Call(call) = expr {
            attrs(&call.attrs)?;
            let Expr::Path(callee) = &*call.func else {
                return Err("unresolved constructor callee".into());
            };
            attrs(&callee.attrs)?;
            if callee.qself.is_some() {
                return Err("qualified constructor call unsupported".into());
            }
            if tokens(&callee.path) == "core :: array :: from_fn" && call.args.len() == 1 {
                let Type::Array(array) = ty else {
                    return Err("from_fn initializer requires array field".into());
                };
                if !optional(&array.elem) {
                    return Err("constructor array requires Option slots".into());
                }
                let Expr::Closure(closure) = &call.args[0] else {
                    return Err("from_fn requires explicit closure".into());
                };
                attrs(&closure.attrs)?;
                if closure.asyncness.is_some()
                    || closure.constness.is_some()
                    || closure.inputs.len() != 1
                    || !matches!(&closure.inputs[0],syn::Pat::Wild(p) if p.attrs.is_empty())
                    || !matches!(closure.output, syn::ReturnType::Default)
                    || !none(&closure.body)
                {
                    return Err("constructor array closure must be exactly |_| None".into());
                }
                fields.push(Field {
                    path,
                    value: Initial::EmptySlots(Self::capacity(&array.len, constants)?),
                });
                return Ok(());
            }
            if call.args.is_empty()
                && callee.path.segments.len() == 2
                && callee
                    .path
                    .segments
                    .iter()
                    .all(|s| matches!(s.arguments, syn::PathArguments::None))
                && callee.path.segments[1].ident == "default"
            {
                let named = base_type(ty)?;
                let resolved = self.resolve(module, &named, 0)?;
                if self.resolve(module, &callee.path.segments[0].ident.to_string(), 0)? != resolved
                {
                    return Err("constructor Default type mismatch".into());
                }
                let record = self
                    .structs
                    .get(&resolved)
                    .ok_or("Default requires resolved struct")?;
                if !record.generics.params.is_empty() {
                    return Err("generic Default requires further trait substitution".into());
                }
                let record_module = &self.struct_modules[&resolved];
                let default_name = format!("{record_module}::{resolved}::default")
                    .trim_start_matches("::")
                    .to_owned();
                if self.methods.contains_key(&default_name) {
                    return Err("inherent default must be translated explicitly".into());
                }
                let derived=record.attrs.iter().any(|a|a.path().is_ident("derive") && a.parse_args_with(syn::punctuated::Punctuated::<syn::Ident,syn::Token![,]>::parse_terminated).is_ok_and(|ds|ds.iter().any(|d|d=="Default")));
                if !derived {
                    return Err("constructor requires builtin derived Default".into());
                }
                for field in &record.fields {
                    attrs(&field.attrs)?;
                    let name = field
                        .ident
                        .as_ref()
                        .ok_or("Default requires named fields")?;
                    let mut path = path.clone();
                    path.push(name.to_string());
                    let value = if optional(&field.ty) {
                        Initial::Absent
                    } else if unsigned(&field.ty) {
                        Initial::Unsigned {
                            rust_type: tokens(&field.ty),
                            value: 0,
                        }
                    } else if tokens(&field.ty) == "bool" {
                        Initial::Boolean(false)
                    } else {
                        return Err("derived Default field has unsupported effects".into());
                    };
                    fields.push(Field { path, value });
                }
                return Ok(());
            }
        }
        Err(format!(
            "unsupported complete constructor initializer {}",
            tokens(expr)
        ))
    }
}
fn initial(i: &Initial) -> String {
    match i {
        Initial::Boolean(b) => format!(".boolean {b}"),
        Initial::Unsigned { rust_type, value } => format!(".unsigned {rust_type:?} {value}"),
        Initial::Absent => ".absent".into(),
        Initial::EmptySlots(Capacity::Fixed(n)) => format!(".emptySlots (.fixed {n})"),
        Initial::EmptySlots(Capacity::Parameter(p)) => format!(".emptySlots (.parameter {p:?})"),
    }
}
pub(super) fn generate(method: &Method) -> String {
    let c = method.constructor.as_ref().unwrap();
    let name = &method.symbol;
    let fields = c
        .fields
        .iter()
        .map(|f| format!("⟨{}, {}⟩", lean_path(&f.path), initial(&f.value)))
        .collect::<Vec<_>>()
        .join(", ");
    format!("def {name}_ir : List InitField := [{fields}]\ndef {name} (sizes : String → Nat) : InitStore := initializeFields {name}_ir sizes\ntheorem {name}_correspondence (sizes : String → Nat) : initializeFields {name}_ir sizes = {name} sizes := by rfl\n")
}
