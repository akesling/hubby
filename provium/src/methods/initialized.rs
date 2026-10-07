//! Typed initialized-slot refinement of the non-dropping assignment backend.
//! The footprint is checked in Lean against the generated program. Resolving
//! source places to this layout and establishing exclusive access remain open.
use super::*;

pub(super) fn supported(m: &Method) -> bool {
    m.getter.is_none()
        && m.view.is_none()
        && m.array.is_none()
        && m.query.is_none()
        && m.constructor.is_none()
        && m.buffer.is_none()
        && m.relocation.is_none()
        && m.selection.is_none()
        && m.lookup.is_none()
        && m.record_at.is_none()
        && m.iteration.is_none()
        && m.last.is_none()
        && m.truncation.is_none()
        && m.installation.is_none()
        && m.restoration.is_none()
        && m.validator.is_none()
        && m.enum_projection.is_none()
        && m.imperative.is_none()
}

fn condition(c: &Condition, fields: &mut BTreeMap<Vec<String>, &'static str>) {
    match c {
        Condition::Boolean(_) => {}
        Condition::Field(path) => {
            fields.insert(path.clone(), "boolean");
        }
        Condition::Not(c) => condition(c, fields),
        Condition::And(a, b) | Condition::Or(a, b) => {
            condition(a, fields);
            condition(b, fields);
        }
    }
}

fn statements(body: &[Statement], fields: &mut BTreeMap<Vec<String>, &'static str>) {
    for statement in body {
        match statement {
            Statement::Write(w) => {
                fields.insert(
                    w.path.clone(),
                    match w.literal {
                        Literal::Boolean(_) => "boolean",
                        Literal::Absent => "optional",
                    },
                );
            }
            Statement::Call { body, .. } => statements(body, fields),
            Statement::Branch {
                condition: c,
                yes,
                no,
            } => {
                condition(c, fields);
                statements(yes, fields);
                statements(no, fields);
            }
        }
    }
}

pub(super) fn generate(method: &Method) -> String {
    let name = &method.symbol;
    let mut fields = BTreeMap::new();
    statements(&method.body, &mut fields);
    let binder = if fields.is_empty() { "_" } else { "path" };
    let mut layout = String::from("none");
    for (path, kind) in fields.iter().rev() {
        layout = format!(
            "if path = {} then some .{kind} else {layout}",
            lean_path(path)
        );
    }
    // A conflicting footprint cannot pass the kernel's ProgramTyped check.
    let initialized = format!(
        "def {name}_layout : Initialized.Layout := fun {binder} => {layout}\n\
         set_option linter.unusedSimpArgs false in\n\
         theorem {name}_well_typed : Initialized.ProgramTyped {name}_layout {name}_ir := by\n  simp [Initialized.ProgramTyped, Initialized.ConditionTyped, Initialized.literalKind, {name}_layout, {name}_ir]\n\
         theorem {name}_initialized_refinement (heap : Initialized.Heap α) (state : Store α)\n    (related : Initialized.Relates {name}_layout heap state) :\n    ∃ result, Initialized.execute {name}_layout {name}_ir heap = .ok result ∧\n      Initialized.Relates {name}_layout result ({name} state) := by\n  simpa only [{name}_correspondence] using\n    Initialized.execute_refines {name}_ir related {name}_well_typed\n"
    );
    format!(
        r#"{initialized}
theorem {name}_loan_refinement (world : Loans.World) (owner ticket : Nat)
    (heap : Initialized.Heap α) (state : Store α)
    (related : Initialized.Relates {name}_layout heap state)
    (allowed : Loans.ProgramAllowed world owner ticket {name}_ir) :
    ∃ result, Loans.execute world owner ticket {name}_layout {name}_ir heap = .ok result ∧
      Initialized.Relates {name}_layout result ({name} state) := by
  simpa only [{name}_correspondence] using
    Loans.execute_refines {name}_ir related {name}_well_typed allowed
"#
    )
}
