use provium::{
    extract::{extract, Binding, Slice},
    frontend::Compiler,
    ir::{run, Value},
};
fn selection() -> Slice {
    Slice {
        source: "node.rs".into(),
        method: "Node::update".into(),
        name: "transition".into(),
        select: vec!["stmt:0".into()],
        bindings: vec![
            Binding {
                rust: "self.commit".into(),
                name: "current".into(),
                ty: "u64".into(),
            },
            Binding {
                rust: "index".into(),
                name: "incoming".into(),
                ty: "u64".into(),
            },
        ],
        result: "u64".into(),
        guarded_assignment_prefix: true,
    }
}
#[test]
fn assignment_prefix_comes_from_the_source_and_records_excluded_context() {
    let original="impl Node { fn update(&mut self,index:u64) { if index > self.commit { self.commit=index; self.refresh(); } } }";
    let slice = selection();
    let a = extract(original, "node.rs", &slice).unwrap();
    let b = extract(
        &original.replace("self.commit=index", "self.commit=0"),
        "node.rs",
        &slice,
    )
    .unwrap();
    assert_ne!(a.source_sha256, b.source_sha256);
    assert!(a.selected_rust[0].contains("refresh"));
    assert!(a.scope.contains("subsequent effects"));
    for (e, expected) in [(a, 9), (b, 0)] {
        let f = Compiler::parse(&e.abstracted_rust, 64)
            .unwrap()
            .compile()
            .unwrap()
            .remove(0);
        assert_eq!(
            run(
                &f,
                &[
                    Value::UInt { bits: 64, value: 5 },
                    Value::UInt { bits: 64, value: 9 }
                ],
                64
            ),
            Ok(Value::UInt {
                bits: 64,
                value: expected
            })
        );
    }
}
#[test]
fn structural_drift_is_rejected_instead_of_silently_changing_scope() {
    for source in [
        "impl Node { fn update(&mut self,index:u64) { self.before(); if index>self.commit { self.commit=index; } } }",
        "impl Node { fn update(&mut self,index:u64) { if index>self.commit { self.before(); self.commit=index; } } }",
        "impl Node { fn update(&mut self,index:u64) { if index>self.commit { self.commit=index; } else { self.commit=0; } } }",
        "impl Node { #[cfg(any())] fn update(&mut self,index:u64) { if index>self.commit { self.commit=index; } } }",
        "impl Node { fn update(&mut self,index:u64) { if index>self.commit { self.commit={let incoming=0;index}; } } }",
    ] { assert!(extract(source,"node.rs",&selection()).is_err(),"accepted {source}"); }
    let mut slice = selection();
    slice.guarded_assignment_prefix = false;
    slice.select = vec!["calls:accept:0:2".into()];
    let same="impl Node { fn update(&mut self,index:u64) { self.accept(index.min(self.commit)); self.accept(index.min(self.commit)); } }";
    assert_eq!(
        extract(same, "node.rs", &slice)
            .unwrap()
            .selected_rust
            .len(),
        2
    );
    let different = same.replacen("index.min(self.commit)", "index.max(self.commit)", 1);
    assert!(extract(&different, "node.rs", &slice)
        .unwrap_err()
        .contains("occurrences differ"));
    assert!(extract(
        &same.replace("self.accept", "self.other"),
        "node.rs",
        &slice
    )
    .is_err());
}
