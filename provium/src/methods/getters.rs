//! Complete copied-field and borrowed Option getters. Copy admission uses source
//! declarations and the original Rust build; lifetime adequacy remains separate.
use super::*;

#[derive(Debug, Serialize)]
pub struct Getter {
    pub path: Vec<String>,
    pub borrowed: bool,
    pub rust_type: String,
    pub kind: String,
    pub source_place: String,
    pub copy_declarations: BTreeMap<String, String>,
    pub scope: &'static str,
}

pub(super) fn candidate(item: &syn::ImplItemFn) -> bool {
    matches!(
        item.block.stmts.last(),
        Some(syn::Stmt::Expr(Expr::Field(_), None))
    ) || matches!(item.block.stmts.last(), Some(syn::Stmt::Expr(Expr::MethodCall(call), None)) if call.method == "as_ref" && matches!(call.receiver.as_ref(), Expr::Field(_))
    )
}

// Read the nested syntax independently of the flat `path` helper used by the IR.
fn source_place(expr: &Expr) -> Result<String, String> {
    match expr {
        Expr::Path(p) if p.attrs.is_empty() && p.qself.is_none() && p.path.is_ident("self") => {
            Ok(".receiver".into())
        }
        Expr::Field(field) => {
            attrs(&field.attrs)?;
            let syn::Member::Named(name) = &field.member else {
                return Err("copied field requires named projections".into());
            };
            Ok(format!(
                ".field ({}) {:?}",
                source_place(&field.base)?,
                name.to_string()
            ))
        }
        _ => Err("copied source place must be rooted at self".into()),
    }
}

fn option_payload(ty: &Type) -> Result<&Type, String> {
    let Type::Path(p) = ty else {
        return Err("expected builtin Option".into());
    };
    if p.qself.is_some()
        || p.path.leading_colon.is_some()
        || p.path.segments.len() != 1
        || p.path.segments[0].ident != "Option"
    {
        return Err("expected builtin Option".into());
    }
    let syn::PathArguments::AngleBracketed(args) = &p.path.segments[0].arguments else {
        return Err("Option requires one payload".into());
    };
    match args.args.first() {
        Some(syn::GenericArgument::Type(inner)) if args.args.len() == 1 => Ok(inner),
        _ => Err("Option requires one payload".into()),
    }
}

fn derived_copy(attributes: &[syn::Attribute]) -> bool {
    attributes.iter().any(|a| {
        a.path().is_ident("derive")
            && a.parse_args_with(
                syn::punctuated::Punctuated::<syn::Ident, syn::Token![,]>::parse_terminated,
            )
            .is_ok_and(|names| names.iter().any(|name| name == "Copy"))
    })
}

impl Crate {
    fn copied_kind(
        &self,
        def: &Definition,
        ty: &Type,
        declarations: &mut BTreeMap<String, String>,
        depth: usize,
    ) -> Result<&'static str, String> {
        if depth > 32 {
            return Err("copied field type exceeds supported depth".into());
        }
        let Type::Path(p) = ty else {
            return Err("copied field requires a named Copy type".into());
        };
        if p.qself.is_some() || p.path.segments.len() != 1 {
            return Err("copied field type qualification requires further resolution".into());
        }
        let segment = &p.path.segments[0];
        if def
            .impl_generics
            .type_params()
            .any(|param| param.ident == segment.ident)
        {
            return Err("generic copied fields require trait-bound resolution".into());
        }
        if segment.ident == "Option" {
            let syn::PathArguments::AngleBracketed(args) = &segment.arguments else {
                return Err("copied Option requires one concrete payload type".into());
            };
            if args.args.len() != 1 {
                return Err("copied Option requires one concrete payload type".into());
            }
            let syn::GenericArgument::Type(inner) = &args.args[0] else {
                return Err("copied Option requires one concrete payload type".into());
            };
            self.copied_kind(def, inner, declarations, depth + 1)?;
            return Ok("optional");
        }
        if !matches!(segment.arguments, syn::PathArguments::None) {
            return Err("generic copied records require trait-bound resolution".into());
        }
        let name = segment.ident.to_string();
        if [
            "bool", "u8", "u16", "u32", "u64", "u128", "usize", "i8", "i16", "i32", "i64", "i128",
            "isize", "char",
        ]
        .contains(&name.as_str())
        {
            if self.struct_modules.contains_key(&name)
                || self.imports.keys().any(|(_, imported)| imported == &name)
            {
                return Err("copied primitive type is shadowed".into());
            }
            return Ok(if name == "bool" { "boolean" } else { "payload" });
        }
        let resolved = self.resolve(&def.module, &name, 0)?;
        if self.drops.contains(&resolved) {
            return Err("copied field type cannot have Drop".into());
        }
        let declaration = if let Some(record) = self.structs.get(&resolved) {
            if !record.generics.params.is_empty() || !derived_copy(&record.attrs) {
                return Err(
                    "copied record requires a concrete source-derived Copy declaration".into(),
                );
            }
            tokens(record)
        } else if let Some(enumeration) = self.enums.get(&resolved) {
            if !enumeration.generics.params.is_empty() || !derived_copy(&enumeration.attrs) {
                return Err(
                    "copied enum requires a concrete source-derived Copy declaration".into(),
                );
            }
            tokens(enumeration)
        } else {
            return Err("copied field type has no admitted source declaration".into());
        };
        declarations.insert(resolved, declaration);
        Ok("payload")
    }

    pub(super) fn lower_getter(&self, name: &str) -> Result<Method, String> {
        let def = self
            .methods
            .get(name)
            .ok_or("unknown copied-field method")?;
        let f = &def.item;
        attrs(&f.attrs)?;
        let sig = &f.sig;
        if sig.asyncness.is_some()
            || sig.constness.is_some()
            || sig.unsafety.is_some()
            || sig.abi.is_some()
            || !sig.generics.params.is_empty()
            || sig.generics.where_clause.is_some()
            || sig.inputs.len() != 1
        {
            return Err("copied-field method requires a plain shared receiver only".into());
        }
        let Some(syn::FnArg::Receiver(receiver)) = sig.inputs.first() else {
            return Err("copied-field method requires &self".into());
        };
        attrs(&receiver.attrs)?;
        if receiver.reference.is_none()
            || receiver.mutability.is_some()
            || receiver.colon_token.is_some()
        {
            return Err("copied-field method requires an ordinary shared borrow".into());
        }
        self.constructor_namespaces(def)?;
        if def.impl_generics.type_params().any(|p| p.ident == "Option") {
            return Err("field getter builtin Option is shadowed".into());
        }
        let [syn::Stmt::Expr(body, None)] = f.block.stmts.as_slice() else {
            return Err("field getter cannot omit any statement or effect".into());
        };
        let (expr, borrowed) = match body {
            Expr::Field(_) => (body, false),
            Expr::MethodCall(call)
                if call.method == "as_ref" && call.args.is_empty() && call.turbofish.is_none() =>
            {
                attrs(&call.attrs)?;
                (call.receiver.as_ref(), true)
            }
            _ => return Err("field getter requires a field or builtin Option::as_ref".into()),
        };
        let path = path(expr)?;
        let ty = self.field_type(def, &path)?;
        let syn::ReturnType::Type(_, result) = &sig.output else {
            return Err("field getter requires an explicit result type".into());
        };
        let mut declarations = BTreeMap::new();
        let kind = if borrowed {
            let inner = option_payload(ty)?;
            let Type::Reference(reference) = option_payload(result)? else {
                return Err("borrowed field result requires Option<&Payload>".into());
            };
            if reference.mutability.is_some()
                || reference.lifetime.is_some()
                || tokens(inner) != tokens(&reference.elem)
                || receiver
                    .reference
                    .as_ref()
                    .is_some_and(|(_, lifetime)| lifetime.is_some())
            {
                return Err(
                    "borrowed field requires the same payload and elided shared receiver lifetime"
                        .into(),
                );
            }
            "optional"
        } else {
            if tokens(ty) != tokens(result) {
                return Err("copied-field result requires the exact declared field type".into());
            }
            self.copied_kind(def, ty, &mut declarations, 0)?
        };
        Ok(Method {
            name: name.into(), symbol: name.replace("::", "_"), source: def.file.clone(),
            first_line: f.span().start().line, last_line: f.span().end().line, rust: tokens(f),
            writes: vec![], body: vec![],
            getter: Some(Getter { path, borrowed, rust_type: tokens(ty), kind: kind.into(),
                source_place: source_place(expr)?, copy_declarations: declarations,
                scope: "complete field getter with separate nested source place, initialized reads and loan admission; borrowed Option results retain an active shared receiver ticket; Rust parsing/type/Copy resolution, lifetimes and physical representation remain trusted" }),
            array: None, query: None, constructor: None, buffer: None, relocation: None,
            selection: None, lookup: None, record_at: None, iteration: None, last: None,
            truncation: None, installation: None, restoration: None, validator: None,
            view: None, enum_projection: None,
        })
    }
}

pub(super) fn generate(method: &Method) -> String {
    let getter = method.getter.as_ref().unwrap();
    if getter.borrowed {
        return generate_borrowed(method, getter);
    }
    let name = &method.symbol;
    let path = lean_path(&getter.path);
    let kind = &getter.kind;
    let place = &getter.source_place;
    format!(
        r#"def {name}_ir : FieldReads.Program := ⟨{path}, .{kind}⟩
def {name} (state : Store α) : Cell α := state {name}_ir.path
theorem {name}_correspondence (state : Store α) : FieldReads.readValue {name}_ir state = {name} state := rfl
def {name}_source_place : Provium.ScalarSource.Place := {place}
theorem {name}_source_compiles : {name}_source_place.path = {name}_ir.path := rfl
def {name}_heap (layout : Initialized.Layout) (heap : Initialized.Heap α) : Except Initialized.Fault (Cell α) :=
  FieldReads.readMemory {name}_ir layout heap
theorem {name}_heap_refinement (layout : Initialized.Layout) (heap : Initialized.Heap α) (state : Store α)
    (related : Initialized.Relates layout heap state) (declared : layout {name}_ir.path = some {name}_ir.kind) :
    {name}_heap layout heap = .ok ({name} state) := FieldReads.memory_refines related declared
theorem {name}_source_outcomes (layout : Initialized.Layout) (heap : Initialized.Heap α) :
    FieldReads.readSourceMemory {name}_ir.kind {name}_source_place layout heap = {name}_heap layout heap := by
  simpa only [{name}_source_compiles, {name}_heap, {name}_ir] using FieldReads.source_memory_refines {name}_ir.kind {name}_source_place layout heap
theorem {name}_source_refinement (layout : Initialized.Layout) (heap : Initialized.Heap α) (state : Store α)
    (related : Initialized.Relates layout heap state) (declared : layout {name}_ir.path = some {name}_ir.kind) :
    FieldReads.readSourceMemory {name}_ir.kind {name}_source_place layout heap = .ok ({name} state) := by
  rw [{name}_source_outcomes]
  exact {name}_heap_refinement layout heap state related declared
def {name}_loan (world : Loans.World) (owner ticket : Nat) (layout : Initialized.Layout) (heap : Initialized.Heap α) :=
  FieldReads.readLoan world owner ticket {name}_ir layout heap
theorem {name}_loan_refinement (world : Loans.World) (owner ticket : Nat)
    (layout : Initialized.Layout) (heap : Initialized.Heap α) (state : Store α)
    (related : Initialized.Relates layout heap state) (declared : layout {name}_ir.path = some {name}_ir.kind)
    (allowed : Loans.Allowed world owner ticket ⟨{name}_ir.path, .shared⟩) :
    {name}_loan world owner ticket layout heap = .ok ({name} state) :=
  FieldReads.loan_refines related declared allowed
"#
    )
}

fn generate_borrowed(method: &Method, getter: &Getter) -> String {
    let name = &method.symbol;
    let path = lean_path(&getter.path);
    let place = &getter.source_place;
    format!(
        r#"def {name}_ir : FieldReads.Program := ⟨{path}, .optional⟩
def {name} (owner ticket : Nat) (state : Store α) : Except Initialized.Fault (Option FieldReads.Borrowed.Reference) :=
  FieldReads.Borrowed.select ⟨owner, ticket, {name}_ir.path⟩ (state {name}_ir.path)
theorem {name}_correspondence (owner ticket : Nat) (state : Store α) :
    FieldReads.Borrowed.select ⟨owner, ticket, {name}_ir.path⟩ (FieldReads.readValue {name}_ir state) = {name} owner ticket state := rfl
def {name}_source_place : Provium.ScalarSource.Place := {place}
theorem {name}_source_compiles : {name}_source_place.path = {name}_ir.path := rfl
def {name}_heap (owner ticket : Nat) (layout : Initialized.Layout) (heap : Initialized.Heap α) :=
  (FieldReads.readMemory {name}_ir layout heap).bind (FieldReads.Borrowed.select ⟨owner, ticket, {name}_ir.path⟩)
theorem {name}_heap_refinement (owner ticket : Nat) (layout : Initialized.Layout) (heap : Initialized.Heap α) (state : Store α)
    (related : Initialized.Relates layout heap state) (declared : layout {name}_ir.path = some .optional) :
    {name}_heap owner ticket layout heap = {name} owner ticket state := by
  rw [{name}_heap, FieldReads.memory_refines (program := {name}_ir) related declared]
  rfl
theorem {name}_source_outcomes (owner ticket : Nat) (layout : Initialized.Layout) (heap : Initialized.Heap α) :
    (FieldReads.readSourceMemory {name}_ir.kind {name}_source_place layout heap).bind
      (FieldReads.Borrowed.select ⟨owner, ticket, {name}_ir.path⟩) = {name}_heap owner ticket layout heap := by
  rw [FieldReads.source_memory_refines, {name}_source_compiles]
  rfl
theorem {name}_source_refinement (owner ticket : Nat) (layout : Initialized.Layout) (heap : Initialized.Heap α) (state : Store α)
    (related : Initialized.Relates layout heap state) (declared : layout {name}_ir.path = some .optional) :
    (FieldReads.readSourceMemory {name}_ir.kind {name}_source_place layout heap).bind
      (FieldReads.Borrowed.select ⟨owner, ticket, {name}_ir.path⟩) = {name} owner ticket state := by
  rw [{name}_source_outcomes]
  exact {name}_heap_refinement owner ticket layout heap state related declared
def {name}_loan (world : Loans.World) (owner ticket : Nat) (layout : Initialized.Layout) (heap : Initialized.Heap α) :=
  FieldReads.Borrowed.read world ⟨owner, ticket, {name}_ir.path⟩ layout heap
theorem {name}_loan_refinement (world : Loans.World) (owner ticket : Nat)
    (layout : Initialized.Layout) (heap : Initialized.Heap α) (state : Store α)
    (related : Initialized.Relates layout heap state) (declared : layout {name}_ir.path = some .optional)
    (live : FieldReads.Borrowed.Live world ⟨owner, ticket, {name}_ir.path⟩) :
    {name}_loan world owner ticket layout heap = ({name} owner ticket state).mapError Sum.inr :=
  FieldReads.Borrowed.read_refines related declared live
"#
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::methods::proof_modules::Workspace;

    #[test]
    #[ignore = "requires pinned Lean; scripts/verify.sh runs this"]
    fn source_paths_and_read_faults_reject_corrupted_lowering() {
        struct Work(PathBuf);
        impl Drop for Work {
            fn drop(&mut self) {
                let _ = fs::remove_dir_all(&self.0);
            }
        }
        let work = Work(
            PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("artifacts")
                .join(format!("getter-controls-{}", std::process::id())),
        );
        fs::create_dir_all(&work.0).unwrap();
        let source = work.0.join("lib.rs");
        fs::write(&source, "struct Inner {flag:bool} struct State {inner:Inner} impl State {fn flag(&self)->bool{self.inner.flag}}" ).unwrap();
        let krate = Crate::load(&source).unwrap();
        let workspace = Workspace::new(&work.0).unwrap();
        for (name, text) in [
            ("State", super::super::SEMANTICS),
            ("Loans", super::super::LOANS),
            ("ArrayMoves", super::super::ARRAY_MOVES),
            ("ScalarSource", super::super::SCALAR_SOURCE),
            ("FieldReads", super::super::FIELD_READS),
            ("ConstructorSource", super::super::CONSTRUCTOR_SOURCE),
            ("Audit", crate::project::AUDIT),
        ] {
            workspace
                .write(&format!("Provium/{name}.lean"), text)
                .unwrap();
            workspace
                .check(
                    &format!("Provium/{name}.lean"),
                    Some(&format!("Provium/{name}.olean")),
                )
                .unwrap();
        }
        for changed in [
            None,
            Some(vec!["flag".into()]),
            Some(vec!["inner".into(), "other".into()]),
        ] {
            let mut method = krate.lower("State::flag").unwrap();
            let corrupted = changed.is_some();
            if let Some(path) = changed {
                method.getter.as_mut().unwrap().path = path;
            }
            // This isolated copied-field fixture does not use numeric folds.
            let generated = crate::methods::generate(&[method], "Subject")
                .replace("import Provium.NumericFolds\n", "");
            workspace.write("Generated.lean", &generated).unwrap();
            let result = workspace.check("Generated.lean", Some("Generated.olean"));
            if corrupted {
                let error = result.unwrap_err();
                assert!(error.contains("Lean rejected Generated.lean"), "{error}");
            } else {
                result.unwrap();
                workspace.write("Checks.lean", r#"import Generated
import Provium.Audit
open Provium.State
def program : FieldReads.Program := ⟨["inner", "flag"], .boolean⟩
def layout : Initialized.Layout := fun path => if path = ["inner", "flag"] then some .boolean else none
def heap : Initialized.Heap Nat := fun path => if path = ["inner", "flag"] then some (.boolean true) else none
theorem normal : FieldReads.readMemory program layout heap = .ok (.boolean true) := rfl
theorem undeclared : FieldReads.readMemory program (fun _ => none) heap = .error .invalidPlace := rfl
theorem uninitialized : FieldReads.readMemory program layout (fun _ => none : Initialized.Heap Nat) = .error .uninitialized := rfl
theorem wrong_kind : FieldReads.readMemory program (fun _ => some .payload) heap = .error .wrongType := rfl
theorem wrong_value : FieldReads.readMemory program layout (fun _ => some (.other 7)) = .error .wrongType := rfl
theorem source_fault : FieldReads.readSourceMemory .boolean Subject.State_flag_source_place layout
    (fun _ => none : Initialized.Heap Nat) = .error .uninitialized := rfl
def parent : Loans.Loan := Loans.initial ⟨[], .exclusive⟩
def child : Loans.Loan := Loans.childLoan parent ⟨["inner"], .shared⟩ (by decide)
def world : Loans.World := Loans.set (fun _ => none) 0 (some child)
theorem suspended : FieldReads.readLoan world 0 0 program layout heap = .error (.inl .denied) := rfl
theorem active : FieldReads.readLoan world 0 1 program layout heap = .ok (.boolean true) := rfl
#provium_check Provium.State.FieldReads.memory_refines references Provium.State.FieldReads.readMemory
#provium_check Provium.State.FieldReads.source_memory_refines references Provium.State.FieldReads.readSourceMemory
#provium_check Provium.State.FieldReads.loan_refines references Provium.State.FieldReads.readLoan
#provium_check Subject.State_flag_source_refinement references Subject.State_flag
#provium_check normal references Provium.State.FieldReads.readMemory
#provium_check undeclared references Provium.State.FieldReads.readMemory
#provium_check uninitialized references Provium.State.FieldReads.readMemory
#provium_check wrong_kind references Provium.State.FieldReads.readMemory
#provium_check wrong_value references Provium.State.FieldReads.readMemory
#provium_check source_fault references Provium.State.FieldReads.readSourceMemory
#provium_check suspended references Provium.State.FieldReads.readLoan
#provium_check active references Provium.State.FieldReads.readLoan
"#).unwrap();
                let checked = workspace.check("Checks.lean", None).unwrap();
                assert_eq!(checked.matches("PROVIUM_VERIFIED ").count(), 12);
            }
        }
    }
}
