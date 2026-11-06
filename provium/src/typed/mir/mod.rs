//! rustc's MIR text (`--emit=mir`) as a deep embedding in Lean.
//!
//! [`parse`] reads the MIR the captured build prints into an AST that mirrors
//! `Provium/Mir/Syntax.lean` one to one, and [`emit`] prints it as a Lean file
//! of `Provium.Mir.Body` values. The parser is fail-closed: anything it does
//! not recognise is an error naming the body and the line. The few facts it
//! needs that MIR does not print (generic parameter names, enum variant
//! orders, the self type of an `<impl at ..>`) come from the crate's sources
//! through a [`SourceMap`].
mod emit;
mod parse;
mod source;
#[cfg(test)]
mod tests;

pub use emit::emit;
pub use parse::{parse, parse_lenient};
pub use source::SourceMap;

/// Integer types (`Provium.Mir.IntTy`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum IntTy {
    U8,
    U16,
    U32,
    U64,
    U128,
    Usize,
    I8,
    I16,
    I32,
    I64,
    I128,
    Isize,
}

impl IntTy {
    pub fn from_name(s: &str) -> Option<IntTy> {
        Some(match s {
            "u8" => IntTy::U8,
            "u16" => IntTy::U16,
            "u32" => IntTy::U32,
            "u64" => IntTy::U64,
            "u128" => IntTy::U128,
            "usize" => IntTy::Usize,
            "i8" => IntTy::I8,
            "i16" => IntTy::I16,
            "i32" => IntTy::I32,
            "i64" => IntTy::I64,
            "i128" => IntTy::I128,
            "isize" => IntTy::Isize,
            _ => return None,
        })
    }

    pub fn name(self) -> &'static str {
        match self {
            IntTy::U8 => "u8",
            IntTy::U16 => "u16",
            IntTy::U32 => "u32",
            IntTy::U64 => "u64",
            IntTy::U128 => "u128",
            IntTy::Usize => "usize",
            IntTy::I8 => "i8",
            IntTy::I16 => "i16",
            IntTy::I32 => "i32",
            IntTy::I64 => "i64",
            IntTy::I128 => "i128",
            IntTy::Isize => "isize",
        }
    }

    pub fn signed(self) -> bool {
        self.name().starts_with('i')
    }

    /// Bits, with `usize`/`isize` at `pointer_width`.
    pub fn bits(self, pointer_width: u32) -> u32 {
        match self {
            IntTy::U8 | IntTy::I8 => 8,
            IntTy::U16 | IntTy::I16 => 16,
            IntTy::U32 | IntTy::I32 => 32,
            IntTy::U64 | IntTy::I64 => 64,
            IntTy::U128 | IntTy::I128 => 128,
            IntTy::Usize | IntTy::Isize => pointer_width,
        }
    }
}

/// `Provium.Mir.Ty`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Ty {
    Bool,
    Char,
    Str,
    Never,
    Int(IntTy),
    Tuple(Vec<Ty>),
    Adt(String, Vec<Ty>),
    Cnst(u128),
    Cparam(String),
    Array(Box<Ty>, Box<Ty>),
    Slice(Box<Ty>),
    Ref(bool, Box<Ty>),
    Param(String),
    /// A closure by span, with its defining function's generic parameters.
    Closure(String, Vec<Ty>),
    FnPtr(Vec<Ty>, Box<Ty>),
    Assoc(Box<Ty>, String, String),
    Other(String),
}

/// `Provium.Mir.PElem`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PElem {
    Deref,
    Field(usize, Ty),
    Index(usize),
    Cindex(u128),
    Down(usize),
}

/// `Provium.Mir.Place`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Place {
    pub loc: usize,
    pub proj: Vec<PElem>,
}

/// `Provium.Mir.Const`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Const {
    /// An integer: negated when the flag is set, its magnitude and type.
    Int(bool, u128, IntTy),
    Bool(bool),
    Char(char),
    Unit,
    Str(String),
    Cparam(String),
    Zst(Ty),
    Adt(String, usize),
    /// A byte string literal's bytes.
    Bytes(Vec<u8>),
    Promoted(String),
}

/// `Provium.Mir.Operand`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Operand {
    Copy(Place),
    Move(Place),
    Const(Const),
}

/// `Provium.Mir.BinOp`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BinOp {
    Add,
    Sub,
    Mul,
    Div,
    Rem,
    BitAnd,
    BitOr,
    BitXor,
    Shl,
    Shr,
    Eq,
    Ne,
    Lt,
    Le,
    Gt,
    Ge,
}

/// `Provium.Mir.UnOp`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UnOp {
    Not,
    Neg,
}

/// `Provium.Mir.AggKind`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AggKind {
    Tuple,
    Array,
    Adt(String, usize),
    Closure(String),
    /// An `async fn`'s coroutine, by span.
    Coroutine(String),
}

/// `Provium.Mir.Rvalue`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Rvalue {
    Use(Operand),
    Ref(bool, Place),
    Binop(BinOp, Operand, Operand),
    Checked(BinOp, Operand, Operand),
    Unop(UnOp, Operand),
    Discr(Place),
    Aggr(AggKind, Vec<Operand>),
    Rep(Operand, Const),
    Cast(Operand, IntTy),
    Coerce(String, Operand, Ty),
    PtrMeta(Operand),
}

/// `Provium.Mir.Stmt`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Stmt {
    Assign(Place, Rvalue),
    SetDiscr(Place, usize),
    Nop,
}

/// `Provium.Mir.Callee`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Callee {
    Fn(String, Vec<Ty>),
    Trait(String, String, Vec<Ty>),
    Ptr(Operand),
}

/// `Provium.Mir.Term`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Term {
    Goto(usize),
    /// Cases are the values as printed (the `u128` bit pattern of the
    /// discriminant), with their targets.
    Switch(Operand, Vec<(u128, usize)>, usize),
    Ret,
    Unreachable,
    Drop(Place, usize),
    Call(Callee, Vec<Operand>, Place, Option<usize>),
    Assert(Operand, bool, usize),
}

/// `Provium.Mir.Block`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Block {
    pub stmts: Vec<Stmt>,
    pub term: Term,
}

/// `Provium.Mir.Body`. `blocks[i]` is `bbi`; cleanup blocks are `None`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Body {
    pub name: String,
    /// Generic parameter names, with `true` for a const parameter.
    pub tparams: Vec<(String, bool)>,
    pub locals: Vec<Ty>,
    pub nargs: usize,
    pub blocks: Vec<Option<Block>>,
    /// `debug name => _n` bindings to plain locals, in order.
    pub vars: Vec<(String, usize)>,
    /// Not part of the Lean `Body`: the self type and trait of the body's
    /// `<impl at ..>` (`State`, `Record_Clone`), used only to name the Lean
    /// definitions.
    pub owner: Option<String>,
    /// Not part of the Lean `Body`: for a trait method, `(trait as printed
    /// at call sites, method, canonical self type path)`.
    pub trait_impl: Option<(String, String, String)>,
    /// Not part of the Lean `Body`: for a closure body, its span and whether
    /// `_1` is a reference to the closure.
    pub closure: Option<(String, bool)>,
}
