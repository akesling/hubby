//! Parser and emitter tests on small hand-written MIR, and the whole of a
//! real dump when `PROVIUM_MIR_SAMPLE` names one.
use super::*;

const LIB: &str = "pub mod m;
#[derive(Clone, Debug)]
pub struct Id(pub u64);
pub enum E { A, B(u64), C { x: u64, y: bool } }
pub enum D { P = 1, Q }
pub struct S<T, const N: usize> { a: [T; N], b: u64 }
impl<T: Clone, const N: usize> S<T, N> {
    pub fn get<U>(&self, f: impl Fn(u64) -> u64) -> u64 { 0 }
    pub fn len(&self) -> usize { N }
}
pub fn free(x: u64) -> u64 { x }
pub struct Unit;
pub fn user() {}
";

const M: &str = "pub fn helper() {}\npub struct Q;\n";

fn src() -> SourceMap {
    SourceMap::from_files(
        "/w/src/lib.rs",
        vec![
            ("/w/src/lib.rs".into(), LIB.into()),
            ("/w/src/m.rs".into(), M.into()),
        ],
    )
}

const GET: &str = "<impl at src/lib.rs:7:1: 7:39>::get";
const LEN: &str = "<impl at src/lib.rs:7:1: 7:39>::len";

/// Bodies every test can call into, plus `extra`.
fn mir(extra: &str) -> String {
    format!(
        "// WARNING: This output format is intended for human consumers only
fn {LEN}(_1: &S<T, N>) -> usize {{
    debug self => _1;
    let mut _0: usize;

    bb0: {{
        _0 = const N;
        return;
    }}
}}

fn free(_1: u64) -> u64 {{
    let mut _0: u64;

    bb0: {{
        _0 = copy _1;
        return;
    }}
}}

fn m::helper() -> () {{
    let mut _0: ();

    bb0: {{
        return;
    }}
}}

alloc3 (size: 7, align: 1) {{
    43 6f 6d 6d 61 6e 64                            │ Command
}}

const MAX_X: usize = const 16_usize;

fn E::B(_1: u64) -> E {{
    let mut _0: E;

    bb0: {{
        _0 = E::B(move _1);
        return;
    }}
}}

// MIR FOR CTFE
fn E::B(_1: u64) -> E {{
    let mut _0: E;

    bb0: {{
        _0 = E::B(move _1);
        return;
    }}
}}

const {GET}::promoted[0]: &E = {{
    let mut _0: &E;
    let mut _1: E;

    bb0: {{
        _1 = E::A;
        _0 = &_1;
        return;
    }}
}}

{GET}::{{constant#0}}: () = {{
    let mut _0: ();

    bb0: {{
        ConstEvalCounter;
        _0 = const ();
        return;
    }}
}}

fn {GET}::{{closure#0}}(_1: &{{closure@src/lib.rs:8:5: 8:10}}, _2: u64) -> u64 {{
    debug x => _2;
    debug cap => (*((*_1).0: &u64));
    let mut _0: u64;

    bb0: {{
        _0 = copy (*((*_1).0: &u64));
        return;
    }}
}}

{extra}"
    )
}

/// A body for `get` with the given locals (after `_0: u64`) and blocks.
fn get_body(lets: &str, blocks: &str) -> String {
    format!(
        "fn {GET}(_1: &S<T, N>, _2: impl Fn(u64) -> u64) -> u64 {{
    let mut _0: u64;
{lets}
{blocks}
}}
"
    )
}

fn parse_get(lets: &str, blocks: &str) -> Result<Body, String> {
    let text = mir(&get_body(lets, blocks));
    let bodies = parse(&text, &src())?;
    Ok(bodies.into_iter().find(|b| b.name == GET).expect("get"))
}

fn local(n: usize) -> Place {
    Place {
        loc: n,
        proj: vec![],
    }
}

fn block(b: &Body, k: usize) -> &Block {
    b.blocks[k].as_ref().expect("block")
}

#[test]
fn items_headers_and_generics() {
    let text = mir(&get_body("", "    bb0: {\n        return;\n    }"));
    let bodies = parse(&text, &src()).unwrap();
    let names: Vec<&str> = bodies.iter().map(|b| b.name.as_str()).collect();
    // The CTFE copy, the allocation and the evaluated constant are skipped.
    assert_eq!(
        names,
        [
            LEN,
            "free",
            "m::helper",
            "E::B",
            &format!("{GET}::promoted[0]"),
            &format!("{GET}::{{constant#0}}"),
            &format!("{GET}::{{closure#0}}"),
            GET,
        ]
    );
    let by = |n: &str| bodies.iter().find(|b| b.name == n).unwrap();
    let tp = |v: &[(&str, bool)]| {
        v.iter()
            .map(|(n, c)| ((*n).to_owned(), *c))
            .collect::<Vec<_>>()
    };
    let get_tp = tp(&[
        ("T", false),
        ("N", true),
        ("U", false),
        ("impl Fn(u64) -> u64", false),
    ]);
    assert_eq!(by(GET).tparams, get_tp);
    assert_eq!(by(&format!("{GET}::{{closure#0}}")).tparams, get_tp);
    assert_eq!(by(&format!("{GET}::promoted[0]")).tparams, get_tp);
    assert_eq!(by(LEN).tparams, tp(&[("T", false), ("N", true)]));
    assert_eq!(by("free").tparams, vec![]);
    assert_eq!(by("E::B").tparams, vec![]);
    assert_eq!(by(GET).nargs, 2);
    assert_eq!(
        by(GET).locals,
        vec![
            Ty::Int(IntTy::U64),
            Ty::Ref(
                false,
                Box::new(Ty::Adt(
                    "S".into(),
                    vec![Ty::Param("T".into()), Ty::Cparam("N".into())]
                ))
            ),
            Ty::Param("impl Fn(u64) -> u64".into()),
        ]
    );
    assert_eq!(by(LEN).owner.as_deref(), Some("S"));
    assert_eq!(
        block(by(LEN), 0).stmts,
        vec![Stmt::Assign(
            local(0),
            Rvalue::Use(Operand::Const(Const::Cparam("N".into())))
        )]
    );
    let closure = by(&format!("{GET}::{{closure#0}}"));
    assert_eq!(
        closure.locals[1],
        Ty::Ref(
            false,
            Box::new(Ty::Closure(
                "src/lib.rs:8:5: 8:10".into(),
                vec![
                    Ty::Param("T".into()),
                    Ty::Cparam("N".into()),
                    Ty::Param("U".into()),
                    Ty::Param("impl Fn(u64) -> u64".into())
                ]
            ))
        )
    );
    assert_eq!(
        block(by(&format!("{GET}::{{constant#0}}")), 0).stmts[0],
        Stmt::Nop
    );
}

#[test]
fn derive_impls() {
    let get = get_body("", "    bb0: {\n        return;\n    }");
    let text = mir(&(get
        + "fn <impl at src/lib.rs:2:10: 2:15>::clone(_1: &Id) -> Id {
    debug self => _1;
    let mut _0: Id;
    let mut _2: u64;
    scope 1 {
        debug x => _2;
    }

    bb0: {
        _2 = copy ((*_1).0: u64);
        _0 = Id(move _2);
        return;
    }
}
"));
    let bodies = parse(&text, &src()).unwrap();
    let b = bodies.iter().find(|b| b.name.ends_with("::clone")).unwrap();
    assert_eq!(b.owner.as_deref(), Some("Id_Clone"));
    assert_eq!(
        b.trait_impl,
        Some(("Clone".to_owned(), "clone".to_owned(), "Id".to_owned()))
    );
    let get = bodies.iter().find(|b| b.name == GET).unwrap();
    assert_eq!(get.trait_impl, None);
    let closure = bodies
        .iter()
        .find(|b| b.name.ends_with("{closure#0}"))
        .unwrap();
    assert_eq!(
        closure.closure,
        Some(("src/lib.rs:8:5: 8:10".to_owned(), true))
    );
    let lean = emit(&bodies, "T");
    assert!(lean.contains(
        "def traitImpls : List ((String × String × String) × String) :=\n  [((\"Clone\", \"clone\", \"Id\"), \"<impl at src/lib.rs:2:10: 2:15>::clone\")]"
    ), "{lean}");
    assert!(lean.contains(
        "def closureBodies : List (String × String × Bool) :=\n  [(\"src/lib.rs:8:5: 8:10\", \"<impl at src/lib.rs:7:1: 7:39>::get::{closure#0}\", true)]"
    ));
    assert!(b.tparams.is_empty());
    assert_eq!(
        block(b, 0).stmts,
        vec![
            Stmt::Assign(
                local(2),
                Rvalue::Use(Operand::Copy(Place {
                    loc: 1,
                    proj: vec![PElem::Deref, PElem::Field(0, Ty::Int(IntTy::U64))]
                }))
            ),
            Stmt::Assign(
                local(0),
                Rvalue::Aggr(AggKind::Adt("Id".into(), 0), vec![Operand::Move(local(2))])
            ),
        ]
    );
}

#[test]
fn types() {
    let lets = "    let mut _3: (u64, bool);
    let mut _4: [T; N];
    let mut _5: &mut [Option<u64>];
    let mut _6: [u8; 16];
    let _7: &'a str;
    let _8: !;
    let _9: ();
    let _10: for<'a> fn(&'a u64) -> bool;
    let _11: fn(u64);
    let _12: <T as core::iter::Iterator>::Item;
    let _13: &dyn core::fmt::Debug;
    let _14: core::fmt::Formatter<'_>;
    let _15: fn(u64) -> E {E::B};
    let _16: (char,);
    let _17: core::array::IntoIter<(&[u64], u8), 3>;";
    let b = parse_get(lets, "    bb0: {\n        return;\n    }").unwrap();
    let u64t = Ty::Int(IntTy::U64);
    let opt = |t: Ty| Ty::Adt("core::option::Option".into(), vec![t]);
    assert_eq!(
        b.locals[3..],
        [
            Ty::Tuple(vec![u64t.clone(), Ty::Bool]),
            Ty::Array(
                Box::new(Ty::Param("T".into())),
                Box::new(Ty::Cparam("N".into()))
            ),
            Ty::Ref(true, Box::new(Ty::Slice(Box::new(opt(u64t.clone()))))),
            Ty::Array(Box::new(Ty::Int(IntTy::U8)), Box::new(Ty::Cnst(16))),
            Ty::Ref(false, Box::new(Ty::Str)),
            Ty::Never,
            Ty::Tuple(vec![]),
            Ty::FnPtr(
                vec![Ty::Ref(false, Box::new(u64t.clone()))],
                Box::new(Ty::Bool)
            ),
            Ty::FnPtr(vec![u64t.clone()], Box::new(Ty::Tuple(vec![]))),
            Ty::Assoc(
                Box::new(Ty::Param("T".into())),
                "core::iter::Iterator".into(),
                "Item".into()
            ),
            Ty::Ref(false, Box::new(Ty::Other("dyn core::fmt::Debug".into()))),
            Ty::Adt("core::fmt::Formatter".into(), vec![]),
            Ty::Other("fn(u64) -> E {E::B}".into()),
            Ty::Tuple(vec![Ty::Char]),
            Ty::Adt(
                "core::array::IntoIter".into(),
                vec![
                    Ty::Tuple(vec![
                        Ty::Ref(false, Box::new(Ty::Slice(Box::new(u64t)))),
                        Ty::Int(IntTy::U8)
                    ]),
                    Ty::Cnst(3)
                ]
            ),
        ]
    );
    assert!(parse_get("    let _3: f64;", "    bb0: {\n        return;\n    }").is_err());
    assert!(parse_get(
        "    let _3: *const u8;",
        "    bb0: {\n        return;\n    }"
    )
    .is_err());
}

#[test]
fn places_operands_and_rvalues() {
    let lets = "    let mut _3: (u64, bool);
    let mut _4: &[T; N];
    let mut _5: &[T];
    let mut _6: usize;
    let mut _7: bool;
    let mut _8: T;
    let mut _9: E;
    let mut _10: isize;
    let mut _11: [u64; 2];
    let mut _12: u32;
    let mut _13: &str;
    let mut _14: char;
    let mut _15: &E;
    let mut _16: core::option::Option<u64>;
    let mut _17: S<T, N>;
    let mut _18: {closure@src/lib.rs:8:5: 8:10};
    let mut _19: &u64;
    let mut _20: u64;
    let mut _21: [T; N];
    let mut _22: i64;
    let mut _23: &mut u64;
    let mut _24: fn(&u64) -> u64;
    let mut _25: Unit;
    let mut _26: (u64, u64);
    let mut _27: i32;";
    let blocks = "    bb0: {
        _3 = AddWithOverflow(const 1_u64, const core::num::<impl u64>::MAX);
        _4 = &((*_1).0: [T; N]);
        _5 = move _4 as &[T] (PointerCoercion(Unsize, Implicit));
        _6 = PtrMetadata(copy _5);
        _7 = Lt(const 0_usize, copy _6);
        _8 = copy (*_5)[0 of 1];
        _8 = copy (*_5)[_6];
        _9 = E::C { x: const 1_u64, y: const true };
        _9 = E::A;
        _10 = discriminant(_9);
        _20 = copy ((_9 as B).0: u64);
        _11 = [const 5_u64; 2];
        _11 = [copy _20, const 6_u64];
        _12 = const 30_i32 as u32 (IntToInt);
        _13 = const \"a\\\"b\\n\\u{e9}, (x)\";
        _14 = const '\\'';
        _15 = const S::<T, N>::get::promoted[0];
        _16 = const Option::<u64>::None;
        _16 = core::option::Option::<u64>::Some(copy _20);
        _18 = {closure@src/lib.rs:8:5: 8:10} { cap: copy _19 };
        _7 = Not(move _7);
        _22 = Neg(const -5_i64);
        _22 = const core::num::<impl i64>::MIN;
        _23 = &mut _20;
        _24 = const ZeroSized: {closure@src/lib.rs:8:5: 8:10} as for<'a> fn(&'a u64) -> u64 (PointerCoercion(ClosureFnPointer(Safe), Implicit));
        _21 = [move _8; N];
        _25 = const Unit;
        _26 = (copy _20, const 2_u64);
        _27 = const 7_i32;
        _20 = Shl(copy _20, const 3_i32);
        _9 = E::B(copy _20);
        discriminant(_9) = 1;
        StorageDead(_3);
        FakeRead(ForLet(None), _3);
        return;
    }";
    let b = parse_get(lets, blocks).unwrap();
    let st = &block(&b, 0).stmts;
    let u = |n: u128, t| Operand::Const(Const::Int(false, n, t));
    let p = |l, proj| Place { loc: l, proj };
    let a = |l, r| Stmt::Assign(local(l), r);
    assert_eq!(
        st[0],
        a(
            3,
            Rvalue::Checked(
                BinOp::Add,
                u(1, IntTy::U64),
                u(u64::MAX as u128, IntTy::U64)
            )
        )
    );
    let arr = Ty::Array(
        Box::new(Ty::Param("T".into())),
        Box::new(Ty::Cparam("N".into())),
    );
    assert_eq!(
        st[1],
        a(
            4,
            Rvalue::Ref(false, p(1, vec![PElem::Deref, PElem::Field(0, arr)]))
        )
    );
    let slice_ref = Ty::Ref(false, Box::new(Ty::Slice(Box::new(Ty::Param("T".into())))));
    assert_eq!(
        st[2],
        a(
            5,
            Rvalue::Coerce("Unsize".into(), Operand::Move(local(4)), slice_ref)
        )
    );
    assert_eq!(st[3], a(6, Rvalue::PtrMeta(Operand::Copy(local(5)))));
    assert_eq!(
        st[4],
        a(
            7,
            Rvalue::Binop(BinOp::Lt, u(0, IntTy::Usize), Operand::Copy(local(6)))
        )
    );
    assert_eq!(
        st[5],
        a(
            8,
            Rvalue::Use(Operand::Copy(p(5, vec![PElem::Deref, PElem::Cindex(0)])))
        )
    );
    assert_eq!(
        st[6],
        a(
            8,
            Rvalue::Use(Operand::Copy(p(5, vec![PElem::Deref, PElem::Index(6)])))
        )
    );
    assert_eq!(
        st[7],
        a(
            9,
            Rvalue::Aggr(
                AggKind::Adt("E".into(), 2),
                vec![u(1, IntTy::U64), Operand::Const(Const::Bool(true))]
            )
        )
    );
    assert_eq!(
        st[8],
        a(9, Rvalue::Aggr(AggKind::Adt("E".into(), 0), vec![]))
    );
    assert_eq!(st[9], a(10, Rvalue::Discr(local(9))));
    assert_eq!(
        st[10],
        a(
            20,
            Rvalue::Use(Operand::Copy(p(
                9,
                vec![PElem::Down(1), PElem::Field(0, Ty::Int(IntTy::U64))]
            )))
        )
    );
    assert_eq!(
        st[11],
        a(
            11,
            Rvalue::Rep(u(5, IntTy::U64), Const::Int(false, 2, IntTy::Usize))
        )
    );
    assert_eq!(
        st[12],
        a(
            11,
            Rvalue::Aggr(
                AggKind::Array,
                vec![Operand::Copy(local(20)), u(6, IntTy::U64)]
            )
        )
    );
    assert_eq!(st[13], a(12, Rvalue::Cast(u(30, IntTy::I32), IntTy::U32)));
    assert_eq!(
        st[14],
        a(
            13,
            Rvalue::Use(Operand::Const(Const::Str("a\"b\n\u{e9}, (x)".into())))
        )
    );
    assert_eq!(
        st[15],
        a(14, Rvalue::Use(Operand::Const(Const::Char('\''))))
    );
    assert_eq!(
        st[16],
        a(
            15,
            Rvalue::Use(Operand::Const(Const::Promoted(format!(
                "{GET}::promoted[0]"
            ))))
        )
    );
    assert_eq!(
        st[17],
        a(
            16,
            Rvalue::Use(Operand::Const(Const::Adt("core::option::Option".into(), 0)))
        )
    );
    assert_eq!(
        st[18],
        a(
            16,
            Rvalue::Aggr(
                AggKind::Adt("core::option::Option".into(), 1),
                vec![Operand::Copy(local(20))]
            )
        )
    );
    assert_eq!(
        st[19],
        a(
            18,
            Rvalue::Aggr(
                AggKind::Closure("src/lib.rs:8:5: 8:10".into()),
                vec![Operand::Copy(local(19))]
            )
        )
    );
    assert_eq!(
        st[20],
        a(7, Rvalue::Unop(UnOp::Not, Operand::Move(local(7))))
    );
    assert_eq!(
        st[21],
        a(
            22,
            Rvalue::Unop(UnOp::Neg, Operand::Const(Const::Int(true, 5, IntTy::I64)))
        )
    );
    assert_eq!(
        st[22],
        a(
            22,
            Rvalue::Use(Operand::Const(Const::Int(true, 1 << 63, IntTy::I64)))
        )
    );
    assert_eq!(st[23], a(23, Rvalue::Ref(true, local(20))));
    assert!(
        matches!(&st[24], Stmt::Assign(_, Rvalue::Coerce(k, Operand::Const(Const::Zst(Ty::Closure(..))), Ty::FnPtr(..))) if k == "ClosureFnPointer")
    );
    assert_eq!(
        st[25],
        a(
            21,
            Rvalue::Rep(Operand::Move(local(8)), Const::Cparam("N".into()))
        )
    );
    assert_eq!(
        st[26],
        a(
            25,
            Rvalue::Use(Operand::Const(Const::Adt("Unit".into(), 0)))
        )
    );
    assert_eq!(
        st[27],
        a(
            26,
            Rvalue::Aggr(
                AggKind::Tuple,
                vec![Operand::Copy(local(20)), u(2, IntTy::U64)]
            )
        )
    );
    assert_eq!(st[28], a(27, Rvalue::Use(u(7, IntTy::I32))));
    assert_eq!(
        st[29],
        a(
            20,
            Rvalue::Binop(BinOp::Shl, Operand::Copy(local(20)), u(3, IntTy::I32))
        )
    );
    assert_eq!(
        st[30],
        a(
            9,
            Rvalue::Aggr(AggKind::Adt("E".into(), 1), vec![Operand::Copy(local(20))])
        )
    );
    assert_eq!(st[31], Stmt::SetDiscr(local(9), 1));
    assert_eq!(st[32..], [Stmt::Nop, Stmt::Nop]);
}

#[test]
fn terminators_and_callees() {
    let lets = "    let mut _3: (u64, bool);
    let mut _4: &S<T, N>;
    let mut _5: usize;
    let mut _6: &impl Fn(u64) -> u64;
    let mut _7: (u64,);
    let mut _8: fn(u64) -> u64;
    let mut _9: !;
    let mut _10: core::slice::Iter<'_, u64>;
    let mut _11: &[u64];
    let mut _12: [u64; 2];
    let mut _13: u64;
    let mut _14: ();
    let mut _15: E;
    let mut _16: core::option::Option<usize>;
    let mut _17: core::slice::Iter<'_, core::option::Option<u64>>;";
    let blocks = "    bb0: {
        _3 = AddWithOverflow(const 1_u64, const 2_u64);
        assert(!move (_3.1: bool), \"attempt to compute `{} + {}`, which would overflow\", const 1_u64, const 2_u64) -> [success: bb1, unwind continue];
    }

    bb1: {
        _5 = S::<T, N>::len(move _4) -> [return: bb2, unwind: bb12];
    }

    bb2: {
        _0 = <impl Fn(u64) -> u64 as Fn<(u64,)>>::call(move _6, move _7) -> [return: bb3, unwind continue];
    }

    bb3: {
        _0 = move _8(const 1_u64) -> [return: bb4, unwind continue];
    }

    bb4: {
        _10 = slice::<impl [u64]>::iter(move _11) -> [return: bb5, unwind continue];
    }

    bb5: {
        _13 = free(const 1_u64) -> [return: bb6, unwind continue];
    }

    bb6: {
        _14 = m::helper() -> [return: bb7, unwind continue];
    }

    bb7: {
        _15 = E::B(const 2_u64) -> [return: bb8, unwind continue];
    }

    bb8: {
        _16 = <core::slice::Iter<'_, Option<u64>> as Iterator>::position::<for<'a> fn(&'a Option<u64>) -> bool {Option::<u64>::is_some}>(move _17, Option::<u64>::is_some) -> [return: bb9, unwind continue];
    }

    bb9: {
        switchInt(copy _13) -> [0: bb10, 18446744073709551615: bb11, otherwise: bb13];
    }

    bb10: {
        drop(_12) -> [return: bb11, unwind: bb12];
    }

    bb11: {
        _9 = core::panicking::panic(const \"x\") -> unwind continue;
    }

    bb12 (cleanup): {
        resume;
    }

    bb13: {
        _14 = core::array::from_fn::<u64, 2, {closure@src/lib.rs:8:5: 8:10}>(const ZeroSized: {closure@src/lib.rs:8:5: 8:10}) -> bb14;
    }

    bb14: {
        assert(const false, \"never\") -> bb15;
    }

    bb15: {
        goto -> bb16;
    }

    bb16: {
        unreachable;
    }";
    let b = parse_get(lets, blocks).unwrap();
    let t = |k| &block(&b, k).term;
    let u64t = Ty::Int(IntTy::U64);
    assert_eq!(
        *t(0),
        Term::Assert(
            Operand::Move(Place {
                loc: 3,
                proj: vec![PElem::Field(1, Ty::Bool)]
            }),
            false,
            1
        )
    );
    assert_eq!(
        *t(1),
        Term::Call(
            Callee::Fn(
                LEN.into(),
                vec![Ty::Param("T".into()), Ty::Cparam("N".into())]
            ),
            vec![Operand::Move(local(4))],
            local(5),
            Some(2)
        )
    );
    assert_eq!(
        *t(2),
        Term::Call(
            Callee::Trait(
                "Fn".into(),
                "call".into(),
                vec![
                    Ty::Param("impl Fn(u64) -> u64".into()),
                    Ty::Tuple(vec![u64t.clone()])
                ]
            ),
            vec![Operand::Move(local(6)), Operand::Move(local(7))],
            local(0),
            Some(3)
        )
    );
    assert!(matches!(t(3), Term::Call(Callee::Ptr(Operand::Move(p)), _, _, Some(4)) if p.loc == 8));
    assert!(
        matches!(t(4), Term::Call(Callee::Fn(k, a), ..) if k == "slice::<impl [T]>::iter" && *a == [u64t.clone()])
    );
    assert!(matches!(t(5), Term::Call(Callee::Fn(k, a), ..) if k == "free" && a.is_empty()));
    assert!(matches!(t(6), Term::Call(Callee::Fn(k, _), ..) if k == "m::helper"));
    assert!(matches!(t(7), Term::Call(Callee::Fn(k, _), ..) if k == "E::B"));
    let Term::Call(Callee::Trait(tr, m, _), args, _, _) = t(8) else {
        panic!()
    };
    assert_eq!((tr.as_str(), m.as_str()), ("Iterator", "position"));
    assert!(
        matches!(&args[1], Operand::Const(Const::Zst(Ty::Other(s))) if s.ends_with("{Option::<u64>::is_some}"))
    );
    assert_eq!(
        *t(9),
        Term::Switch(
            Operand::Copy(local(13)),
            vec![(0, 10), (u64::MAX as u128, 11)],
            13
        )
    );
    assert_eq!(*t(10), Term::Drop(local(12), 11));
    assert!(
        matches!(t(11), Term::Call(Callee::Fn(k, _), _, _, None) if k == "core::panicking::panic")
    );
    assert!(b.blocks[12].is_none());
    assert!(
        matches!(t(13), Term::Call(Callee::Fn(k, a), _, _, Some(14)) if k == "core::array::from_fn" && a.len() == 3 && a[1] == Ty::Cnst(2))
    );
    assert_eq!(
        *t(14),
        Term::Assert(Operand::Const(Const::Bool(false)), true, 15)
    );
    assert_eq!(*t(15), Term::Goto(16));
    assert_eq!(*t(16), Term::Unreachable);
}

fn get_err(lets: &str, stmts: &str) -> String {
    let blocks = format!("    bb0: {{\n{stmts}\n        return;\n    }}\n\n    bb1 (cleanup): {{\n        resume;\n    }}");
    parse_get(lets, &blocks).unwrap_err()
}

#[test]
fn unsupported_is_an_error() {
    let has = |e: String, what: &str| {
        assert!(
            e.contains(what) && e.contains(GET) && e.contains("line "),
            "{e}"
        )
    };
    has(
        get_err(
            "    let _3: &u64;\n    let _4: u64;",
            "        _3 = &raw const _4;",
        ),
        "unsupported reference",
    );
    has(
        get_err("    let _3: u64;", "        Deinit(_3);"),
        "unsupported statement",
    );
    has(
        get_err("    let _3: D;", "        _3 = D::Q;"),
        "explicit discriminants",
    );
    has(
        get_err(
            "    let _3: E;",
            "        _3 = E::C { y: const true, x: const 1_u64 };",
        ),
        "declaration order",
    );
    has(
        get_err("    let _3: u64;", "        _3 = const MAX_X;"),
        "unsupported constant",
    );
    has(
        get_err(
            "    let _3: u64;",
            "        _3 = copy _3 as u64 (Transmute);",
        ),
        "unsupported cast kind",
    );
    has(
        get_err("    let _3: u64;", "        _3 = Offset(copy _3, copy _3);"),
        "unsupported rvalue",
    );
    let e = parse_get(
        "",
        "    bb0: {\n        goto -> bb1;\n    }\n\n    bb1 (cleanup): {\n        resume;\n    }",
    )
    .unwrap_err();
    assert!(e.contains("cleanup"), "{e}");
    let e = parse_get("", "    bb0: {\n        resume;\n    }").unwrap_err();
    assert!(e.contains("outside a cleanup block"), "{e}");
    let e = parse_get("    let _4: u64;", "    bb0: {\n        return;\n    }").unwrap_err();
    assert!(e.contains("_3 is not declared"), "{e}");
    let e = parse(&mir("static X: u64 = 1;\n"), &src()).unwrap_err();
    assert!(e.contains("unrecognised top-level line"), "{e}");
}

#[test]
fn ordering_is_a_library_enum() {
    let b = parse_get(
        "    let _3: core::cmp::Ordering;",
        "    bb0: {\n        _3 = core::cmp::Ordering::Equal;\n        return;\n    }",
    )
    .unwrap();
    assert_eq!(
        block(&b, 0).stmts[0],
        Stmt::Assign(
            local(3),
            Rvalue::Aggr(AggKind::Adt("core::cmp::Ordering".into(), 1), vec![])
        )
    );
}

#[test]
fn lenient_parse_leaves_out_failing_bodies() {
    let text = mir(&get_body(
        "    let _3: u64;",
        "    bb0: {\n        Deinit(_3);\n        return;\n    }",
    ));
    let (bodies, errors) = parse_lenient(&text, &src()).unwrap();
    assert_eq!(bodies.len(), 7);
    assert_eq!(errors.len(), 1);
}

#[test]
fn emission() {
    let text = mir(&get_body(
        "    let mut _3: &str;\n    let mut _4: i64;",
        "    bb0: {\n        _3 = const \"q\\\"\";\n        _4 = const -2_i64;\n        return;\n    }\n\n    bb1 (cleanup): {\n        resume;\n    }",
    ));
    let bodies = parse(&text, &src()).unwrap();
    let lean = emit(&bodies, "T");
    assert!(lean.starts_with(
        "import Provium.Mir.Syntax\nimport Provium.Mir.Attr\n\nnamespace T.Mir\nopen Provium.Mir\n"
    ));
    assert!(lean.contains("def S_get_bb0 : Block where"));
    assert!(lean
        .contains("def S_get : Body where\n  name := \"<impl at src/lib.rs:7:1: 7:39>::get\"\n"));
    assert!(lean.contains("  tparams := [(\"T\", false), (\"N\", true), (\"U\", false), (\"impl Fn(u64) -> u64\", false)]\n"));
    assert!(lean.contains("    | 0 => some S_get_bb0\n    | _ => none\n"));
    assert!(!lean.contains("S_get_bb1"));
    assert!(lean
        .contains("@[mir_body] theorem S_get_blocks_0 : S_get.blocks 0 = some S_get_bb0 := rfl"));
    assert!(lean.contains("@[mir_body] theorem S_get_locals :\n    S_get.locals = ["));
    assert!(lean.contains("Const.str \"q\\\"\""));
    assert!(lean.contains("Const.int (-2) .i64"));
    assert!(lean.contains("S_get_closure0"));
    assert!(lean.contains("S_get_promoted0"));
    assert!(lean.contains("mir_E_B") || lean.contains("def E_B "));
    assert!(lean.contains("(\"m::helper\", m_helper)"));
    assert!(lean.contains("end T.Mir"));
    assert!(lean.lines().all(|l| l.chars().count() <= 140));
}

/// The whole of a real dump (`PROVIUM_MIR_SAMPLE`, Jarl's by default crate
/// root `../jarl/src/lib.rs`, or `PROVIUM_MIR_CRATE_ROOT`).
#[test]
fn whole_sample() {
    let Ok(path) = std::env::var("PROVIUM_MIR_SAMPLE") else {
        return;
    };
    let root = std::env::var("PROVIUM_MIR_CRATE_ROOT")
        .unwrap_or_else(|_| concat!(env!("CARGO_MANIFEST_DIR"), "/../jarl/src/lib.rs").to_owned());
    let text = std::fs::read_to_string(&path).unwrap();
    let src = SourceMap::load(std::path::Path::new(&root)).unwrap();
    let (bodies, errors) = parse_lenient(&text, &src).unwrap();
    assert!(errors.is_empty(), "{errors:?}");
    assert!(!bodies.is_empty());
    let lean = emit(&bodies, "Sample");
    assert!(lean.lines().all(|l| l.chars().count() <= 140));
}

#[test]
fn bytes_coroutines_and_vars() {
    let b = parse_get(
        "    let _3: &[u8; 3];\n    let _4: E;\n    scope 1 {\n        debug x => _3;\n        debug y => (*_3);\n        debug z => const 1_u64;\n        debug w => _4;\n    }",
        "    bb0: {\n        _3 = const b\"a\\xc0\\x00\";\n        _4 = {coroutine@src/lib.rs:1:1: 1:2 (#0)} { a: const 1_u64 };\n        return;\n    }",
    )
    .unwrap();
    let st = &block(&b, 0).stmts;
    assert_eq!(
        st[0],
        Stmt::Assign(
            local(3),
            Rvalue::Use(Operand::Const(Const::Bytes(vec![b'a', 0xc0, 0])))
        )
    );
    assert_eq!(
        st[1],
        Stmt::Assign(
            local(4),
            Rvalue::Aggr(
                AggKind::Coroutine("src/lib.rs:1:1: 1:2".into()),
                vec![Operand::Const(Const::Int(false, 1, IntTy::U64))]
            )
        )
    );
    assert_eq!(b.vars, vec![("x".to_owned(), 3), ("w".to_owned(), 4)]);
    let lean = emit(&[b], "T");
    assert!(lean.contains("Const.bytes [97, 192, 0]"), "{lean}");
    assert!(lean.contains("AggKind.coroutine \"src/lib.rs:1:1: 1:2\""));
    assert!(lean.contains("  vars := [(\"x\", 3), (\"w\", 4)]\n"));
}

/// A closure of `get` seen from `user` (through `get`'s result) carries
/// `user`'s instantiation of `get`.
#[test]
fn foreign_closures_are_instantiated() {
    let text = mir("fn user() -> () {
    let mut _0: ();
    let mut _1: &S<u64, 3>;
    let mut _2: fn(u64) -> u64;
    let mut _3: u64;
    let mut _4: core::option::Option<{closure@src/lib.rs:8:5: 8:10}>;

    bb0: {
        _3 = S::<u64, 3>::get::<bool, fn(u64) -> u64>(move _1, move _2) -> [return: bb1, unwind continue];
    }

    bb1: {
        return;
    }
}
");
    let text = text + &get_body("", "    bb0: {\n        return;\n    }");
    let bodies = parse(&text, &src()).unwrap();
    let user = bodies.iter().find(|b| b.name == "user").unwrap();
    let u64t = Ty::Int(IntTy::U64);
    assert_eq!(
        user.locals[4],
        Ty::Adt(
            "core::option::Option".into(),
            vec![Ty::Closure(
                "src/lib.rs:8:5: 8:10".into(),
                vec![
                    u64t.clone(),
                    Ty::Cnst(3),
                    Ty::Bool,
                    Ty::FnPtr(vec![u64t.clone()], Box::new(u64t))
                ]
            )]
        )
    );
    // Without a call to `get` the instantiation is unknown.
    let text = mir("fn user() -> () {
    let mut _0: ();
    let mut _1: core::option::Option<{closure@src/lib.rs:8:5: 8:10}>;

    bb0: {
        return;
    }
}
") + &get_body("", "    bb0: {\n        return;\n    }");
    let e = parse(&text, &src()).unwrap_err();
    assert!(e.contains("without a call"), "{e}");
}

#[test]
fn canonical_paths() {
    let text = mir("fn user() -> () {
    let mut _0: ();
    let mut _1: m::Q;
    let mut _2: (Q, core::option::Option<Q>);
    let mut _3: RangeTo<usize>;

    bb0: {
        _1 = Q;
        _3 = RangeTo::<usize> { end: const 1_usize };
        return;
    }
}
") + &get_body("", "    bb0: {\n        return;\n    }");
    let bodies = parse(&text, &src()).unwrap();
    let user = bodies.iter().find(|b| b.name == "user").unwrap();
    let q = Ty::Adt("m::Q".into(), vec![]);
    assert_eq!(user.locals[1], q);
    assert_eq!(
        user.locals[2],
        Ty::Tuple(vec![
            q.clone(),
            Ty::Adt("core::option::Option".into(), vec![q])
        ])
    );
    assert_eq!(
        block(user, 0).stmts,
        vec![
            Stmt::Assign(
                local(1),
                Rvalue::Aggr(AggKind::Adt("m::Q".into(), 0), vec![])
            ),
            Stmt::Assign(
                local(3),
                Rvalue::Aggr(
                    AggKind::Adt("core::ops::RangeTo".into(), 0),
                    vec![Operand::Const(Const::Int(false, 1, IntTy::Usize))]
                )
            ),
        ]
    );
    // An unlisted library type printed both bare and qualified.
    let text = mir("fn user() -> () {
    let mut _0: ();
    let mut _1: core::cell::Cell<u64>;
    let mut _2: &Cell<u64>;

    bb0: {
        return;
    }
}
") + &get_body("", "    bb0: {\n        return;\n    }");
    let e = parse(&text, &src()).unwrap_err();
    assert!(
        e.contains("printed both bare and as `core::cell::Cell`"),
        "{e}"
    );
    // A crate type printed under a module it is not declared in.
    let text = mir("fn user() -> () {
    let mut _0: ();
    let mut _1: n::Q;

    bb0: {
        return;
    }
}
") + &get_body("", "    bb0: {\n        return;\n    }");
    let e = parse(&text, &src()).unwrap_err();
    assert!(e.contains("does not match the module"), "{e}");
}
