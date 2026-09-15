use provium::{frontend::Compiler, ir, methods::Crate};
use std::{
    fs,
    path::{Path, PathBuf},
    sync::atomic::{AtomicUsize, Ordering},
};
static NEXT: AtomicUsize = AtomicUsize::new(0);
struct Work(PathBuf);
impl Work {
    fn new() -> Self {
        let path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("artifacts")
            .join(format!(
                "scalar-methods-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }
    fn source(&self, text: &str) -> PathBuf {
        let p = self.0.join("lib.rs");
        fs::write(&p, text).unwrap();
        p
    }
}
impl Drop for Work {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
const SOURCE:&str="struct State {a:u64,b:u64} impl State{fn update(&mut self){self.a=self.a.wrapping_add(1);self.b=self.a/ self.b;}}";

#[test]
fn complete_projections_keep_late_faults_and_all_destinations() {
    let w = Work::new();
    let translated = Crate::load(&w.source(SOURCE))
        .unwrap()
        .scalar_projections("State::update")
        .unwrap();
    let functions = Compiler::parse(&translated.source, 64)
        .unwrap()
        .compile()
        .unwrap();
    assert_eq!(functions.len(), 2);
    for f in &functions {
        assert_eq!(
            ir::run(
                f,
                &[
                    ir::Value::UInt { bits: 64, value: 4 },
                    ir::Value::UInt { bits: 64, value: 0 }
                ],
                64
            ),
            Err(ir::Fault::DivisionByZero)
        );
    }
    let src = SOURCE.replace("self.b=self.a/ self.b;", "self.b ^= self.a;");
    let translated = Crate::load(&w.source(&src))
        .unwrap()
        .scalar_projections("State::update")
        .unwrap();
    assert_eq!(
        translated
            .evidence
            .fields
            .iter()
            .filter(|f| f.written)
            .count(),
        2
    );
    for bad in [
        SOURCE.replace("self.b=self.a/ self.b;", "external();"),
        SOURCE.replace("self.b=self.a/ self.b;", "if self.a>0 {self.b=1;}"),
        SOURCE.replace(
            "self.b=self.a/ self.b;",
            "let provium_field_a=2;self.b=provium_field_a;",
        ),
        SOURCE.replace("a:u64", "a:usize"),
        SOURCE.replace("&mut self", "self"),
    ] {
        let result = Crate::load(&w.source(&bad))
            .and_then(|c| c.scalar_projections("State::update"))
            .and_then(|t| Compiler::parse(&t.source, 64)?.compile());
        assert!(result.is_err(), "accepted {bad}");
    }
}

#[test]
fn shared_queries_resolve_const_parameters_and_keep_failure_paths() {
    let w = Work::new();
    let source="struct State<const N:usize>{len:usize} impl<const CAP:usize> State<CAP>{fn full(&self)->bool{self.len==CAP}}";
    let translation = Crate::load(&w.source(source))
        .unwrap()
        .scalar_projections("State::full")
        .unwrap();
    assert_eq!(
        translation.evidence.constants,
        [("CAP".into(), "usize".into())]
    );
    assert!(translation.evidence.fields.iter().all(|f| !f.written));
    for bits in [32, 64] {
        let functions = Compiler::parse(&translation.source, bits)
            .unwrap()
            .compile()
            .unwrap();
        for len in 0..8 {
            for capacity in 0..8 {
                assert_eq!(
                    ir::run(
                        &functions[0],
                        &[
                            ir::Value::UInt { bits, value: len },
                            ir::Value::UInt {
                                bits,
                                value: capacity
                            }
                        ],
                        bits
                    ),
                    Ok(ir::Value::Bool(len == capacity))
                );
            }
        }
    }
    let source = source.replace("self.len==CAP", "let n=CAP/self.len; n>0");
    let translation = Crate::load(&w.source(&source))
        .unwrap()
        .scalar_projections("State::full")
        .unwrap();
    let functions = Compiler::parse(&translation.source, 64)
        .unwrap()
        .compile()
        .unwrap();
    assert_eq!(
        ir::run(
            &functions[0],
            &[
                ir::Value::UInt { bits: 64, value: 0 },
                ir::Value::UInt { bits: 64, value: 8 }
            ],
            64
        ),
        Err(ir::Fault::DivisionByZero)
    );
}
