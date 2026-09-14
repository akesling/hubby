use provium::{
    frontend::Compiler,
    ir::{self, Fault, Value},
};
use std::collections::BTreeMap;
// These shapes deliberately exercise distinct frontend lowering paths.
#[allow(clippy::assign_op_pattern, clippy::nonminimal_bool)]
mod native {
    include!("fixtures/scalars.rs");
    pub fn boolean(name: &str, x: u8, y: u8) -> bool {
        match name {
            "guarded_division" => guarded_division(x, y),
            "short_circuit" => short_circuit(x, y),
            "call_order" => call_order(x, y),
            _ => unreachable!(),
        }
    }
    pub fn byte(name: &str, x: u8, y: u8) -> u8 {
        match name {
            "arithmetic" => arithmetic(x, y),
            "add" => add(x, y),
            "sub" => sub(x, y),
            "mul" => mul(x, y),
            "div" => div(x, y),
            "rem" => rem(x, y),
            "assertion" => assertion(x, y),
            "nested_calls" => nested_calls(x, y),
            "increment" => increment(x),
            _ => unreachable!(),
        }
    }
    pub fn wide(x: u64, y: u64) -> u64 {
        choose(x, y)
    }
    pub fn quorum(x: usize, y: usize) -> bool {
        majority(x, y)
    }
}
fn uint(bits: u32, value: u64) -> Value {
    Value::UInt { bits, value }
}

#[test]
fn lowering_agrees_with_compiled_rust() {
    let functions: BTreeMap<_, _> =
        Compiler::parse(include_str!("fixtures/scalars.rs"), usize::BITS)
            .unwrap()
            .compile()
            .unwrap()
            .into_iter()
            .map(|f| (f.name.clone(), f))
            .collect();
    // Compare all byte pairs on non-panicking paths and boundary combinations
    // on checked arithmetic. catch_unwind compares failure with failure, while
    // separate tests below check the exact modeled fault and evaluation order.
    for x in 0..=255u8 {
        for y in 0..=255u8 {
            let args = [uint(8, x.into()), uint(8, y.into())];
            for name in ["guarded_division", "arithmetic"] {
                let actual = if name == "arithmetic" {
                    uint(8, native::byte(name, x, y).into())
                } else {
                    Value::Bool(native::boolean(name, x, y))
                };
                assert_eq!(
                    ir::run(&functions[name], &args, usize::BITS),
                    Ok(actual),
                    "{name}({x},{y})"
                );
            }
        }
    }
    for x in [0, 1, 2, 7, 127, 128, 254, 255] {
        for y in [0, 1, 2, 7, 127, 128, 254, 255] {
            for name in [
                "add",
                "sub",
                "mul",
                "div",
                "rem",
                "assertion",
                "nested_calls",
                "increment",
                "call_order",
                "short_circuit",
            ] {
                let args = if name == "increment" {
                    vec![uint(8, x.into())]
                } else {
                    vec![uint(8, x.into()), uint(8, y.into())]
                };
                let actual = std::panic::catch_unwind(|| {
                    if ["call_order", "short_circuit"].contains(&name) {
                        Value::Bool(native::boolean(name, x, y))
                    } else {
                        uint(8, native::byte(name, x, y).into())
                    }
                });
                let extracted = ir::run(&functions[name], &args, usize::BITS);
                assert_eq!(extracted.is_ok(), actual.is_ok(), "{name}({x},{y})");
                if let Ok(value) = actual {
                    assert_eq!(extracted, Ok(value), "{name}({x},{y})");
                }
            }
        }
    }
    for x in [0, 1, 2, u64::MAX / 2, u64::MAX] {
        for y in [0, 1, 2, u64::MAX / 2, u64::MAX] {
            assert_eq!(
                ir::run(
                    &functions["choose"],
                    &[uint(64, x), uint(64, y)],
                    usize::BITS
                ),
                Ok(uint(64, native::wide(x, y)))
            );
            let (x, y) = (x as usize, y as usize);
            assert_eq!(
                ir::run(
                    &functions["majority"],
                    &[uint(usize::BITS, x as u64), uint(usize::BITS, y as u64)],
                    usize::BITS
                ),
                Ok(Value::Bool(native::quorum(x, y)))
            );
        }
    }
}

#[test]
fn rejects_unsupported_or_ambiguous_semantics() {
    for source in [
        "use core::cmp::min; fn f(x:u8)->u8{x}",
        "#[cfg(any())] fn f(x:u8)->u8{x}",
        "fn f(x:i32)->i32{x}",
        "fn f(x:&u8)->u8{*x}",
        "fn f(x:u8)->u8{external(x)}",
        "fn f(x:u8)->u8{f(x)}",
        "fn f(x:u8)->u8{g(x)} fn g(x:u8)->u8{f(x)}",
        "fn f(x:u8)->u8{let f=1u8; f(x)}",
        "fn f(x:u8)->u8{let x=0u8; x=1; x}",
        "fn f(x:u8)->u8{let mut y=0u8; let z:u8={y=1; x}; y}",
        "fn f(x:u8)->u8{let y:u8={return x;}; 0}",
        "fn f(x:u8)->u8{if x>0{return x;}else{0}}",
        "fn f(x:u8)->u8{loop{x}}",
        "fn f(x:u8)->u16{x as u16}",
        "fn f(x:usize,y:u64)->bool{x==y}",
        "fn f(x:u8)->u8{x+256}",
        "fn f(x:u8)->u8{x.rotate_left(1)}",
        "fn f(x:u8)->u8{let y=1; x}",
        "fn f(x:u8)->u8{assert!(x>0,\"message\");x}",
    ] {
        assert!(
            Compiler::parse(source, 64)
                .and_then(Compiler::compile)
                .is_err(),
            "accepted {source}"
        );
    }
    assert!(Compiler::parse("fn f()->u8{0}", 16).is_err());
}

#[test]
fn failure_order_and_target_width_are_explicit() {
    let source = "fn pair(x:u8,y:u8)->u8{x} fn f(x:u8,y:u8)->u8{pair(x+1,y/0)} fn a(x:u8)->u8{assert!(x>0);x-1} fn word(x:usize)->usize{x+1}";
    for bits in [32, 64] {
        let fs: BTreeMap<_, _> = Compiler::parse(source, bits)
            .unwrap()
            .compile()
            .unwrap()
            .into_iter()
            .map(|f| (f.name.clone(), f))
            .collect();
        assert_eq!(
            ir::run(&fs["f"], &[uint(8, 255), uint(8, 0)], bits),
            Err(Fault::Overflow)
        );
        assert_eq!(
            ir::run(&fs["f"], &[uint(8, 0), uint(8, 0)], bits),
            Err(Fault::DivisionByZero)
        );
        assert_eq!(
            ir::run(&fs["a"], &[uint(8, 0)], bits),
            Err(Fault::Assertion)
        );
        let max = ((1u128 << bits) - 1) as u64;
        assert_eq!(
            ir::run(&fs["word"], &[uint(bits, max)], bits),
            Err(Fault::Overflow)
        );
        assert_eq!(
            ir::run(&fs["word"], &[uint(bits, 1)], bits),
            Ok(uint(bits, 2))
        );
        assert_eq!(
            ir::run(&fs["word"], &[Value::Bool(true)], bits),
            Err(Fault::Input)
        );
    }
}
