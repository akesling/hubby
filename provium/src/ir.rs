use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Ty {
    Bool,
    U8,
    U16,
    U32,
    U64,
    Usize,
}
impl Ty {
    pub fn bits(self, usize_bits: u32) -> Option<u32> {
        match self {
            Self::Bool => None,
            Self::U8 => Some(8),
            Self::U16 => Some(16),
            Self::U32 => Some(32),
            Self::U64 => Some(64),
            Self::Usize => Some(usize_bits),
        }
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Op {
    Add,
    Sub,
    Mul,
    Div,
    Rem,
    Eq,
    Ne,
    Lt,
    Le,
    Gt,
    Ge,
    Min,
    Max,
    SaturatingAdd,
    SaturatingSub,
    WrappingAdd,
    WrappingSub,
    WrappingMul,
    BitAnd,
    BitOr,
    BitXor,
    Shl,
    Shr,
}
impl Op {
    pub fn lean(self) -> &'static str {
        match self {
            Self::Add => "add",
            Self::Sub => "sub",
            Self::Mul => "mul",
            Self::Div => "div",
            Self::Rem => "rem",
            Self::Eq => "eq",
            Self::Ne => "ne",
            Self::Lt => "lt",
            Self::Le => "le",
            Self::Gt => "gt",
            Self::Ge => "ge",
            Self::Min => "min",
            Self::Max => "max",
            Self::SaturatingAdd => "saturatingAdd",
            Self::SaturatingSub => "saturatingSub",
            Self::WrappingAdd => "wrappingAdd",
            Self::WrappingSub => "wrappingSub",
            Self::WrappingMul => "wrappingMul",
            Self::BitAnd => "bitAnd",
            Self::BitOr => "bitOr",
            Self::BitXor => "bitXor",
            Self::Shl => "shl",
            Self::Shr => "shr",
        }
    }
    pub fn comparison(self) -> bool {
        matches!(
            self,
            Self::Eq | Self::Ne | Self::Lt | Self::Le | Self::Gt | Self::Ge
        )
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Expr {
    pub ty: Ty,
    pub kind: Kind,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub enum Kind {
    Bool(bool),
    UInt {
        bits: u32,
        value: u64,
    },
    Var(usize),
    Not(Box<Expr>),
    Binary {
        op: Op,
        left: Box<Expr>,
        right: Box<Expr>,
    },
    If {
        condition: Box<Expr>,
        yes: Box<Expr>,
        no: Box<Expr>,
    },
    Let {
        value: Box<Expr>,
        body: Box<Expr>,
    },
    Assert {
        condition: Box<Expr>,
        body: Box<Expr>,
    },
}
impl Expr {
    pub fn size(&self) -> usize {
        1 + match &self.kind {
            Kind::Not(x) => x.size(),
            Kind::Binary { left, right, .. } => left.size() + right.size(),
            Kind::If { condition, yes, no } => condition.size() + yes.size() + no.size(),
            Kind::Let { value, body } => value.size() + body.size(),
            Kind::Assert { condition, body } => condition.size() + body.size(),
            _ => 0,
        }
    }
    pub fn map_free(&self, depth: usize, f: &impl Fn(usize) -> usize) -> Self {
        let map = |e: &Expr| Box::new(e.map_free(depth, f));
        let kind = match &self.kind {
            Kind::Var(i) if *i >= depth => Kind::Var(f(*i - depth) + depth),
            Kind::Not(x) => Kind::Not(map(x)),
            Kind::Binary { op, left, right } => Kind::Binary {
                op: *op,
                left: map(left),
                right: map(right),
            },
            Kind::If { condition, yes, no } => Kind::If {
                condition: map(condition),
                yes: map(yes),
                no: map(no),
            },
            Kind::Let { value, body } => Kind::Let {
                value: map(value),
                body: Box::new(body.map_free(depth + 1, f)),
            },
            Kind::Assert { condition, body } => Kind::Assert {
                condition: map(condition),
                body: map(body),
            },
            other => other.clone(),
        };
        Self { ty: self.ty, kind }
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Parameter {
    pub name: String,
    pub ty: Ty,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Function {
    pub name: String,
    pub parameters: Vec<Parameter>,
    pub result: Ty,
    pub body: Expr,
    pub start_line: usize,
    pub end_line: usize,
    pub rust: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Value {
    Bool(bool),
    UInt { bits: u32, value: u64 },
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Fault {
    Type,
    Overflow,
    DivisionByZero,
    Assertion,
    Input,
}
pub type Outcome = Result<Value, Fault>;
fn word(bits: u32, value: u128) -> Outcome {
    if !matches!(bits, 8 | 16 | 32 | 64) {
        return Err(Fault::Type);
    }
    if value >= 1u128 << bits {
        Err(Fault::Overflow)
    } else {
        Ok(Value::UInt {
            bits,
            value: value as u64,
        })
    }
}
pub fn binary(op: Op, a: Value, b: Value) -> Outcome {
    if let (Value::Bool(a), Value::Bool(b)) = (&a, &b) {
        return match op {
            Op::Eq => Ok(Value::Bool(a == b)),
            Op::Ne => Ok(Value::Bool(a != b)),
            _ => Err(Fault::Type),
        };
    }
    let (
        Value::UInt { bits, value: a },
        Value::UInt {
            bits: other,
            value: b,
        },
    ) = (a, b)
    else {
        return Err(Fault::Type);
    };
    if bits != other {
        return Err(Fault::Type);
    }
    word(bits, a as u128)?;
    word(bits, b as u128)?;
    let (a, b) = (a as u128, b as u128);
    let bound = 1u128 << bits;
    match op {
        Op::Eq => Ok(Value::Bool(a == b)),
        Op::Ne => Ok(Value::Bool(a != b)),
        Op::Lt => Ok(Value::Bool(a < b)),
        Op::Le => Ok(Value::Bool(a <= b)),
        Op::Gt => Ok(Value::Bool(a > b)),
        Op::Ge => Ok(Value::Bool(a >= b)),
        Op::Add => word(bits, a + b),
        Op::Mul => word(bits, a * b),
        Op::Sub => {
            if a < b {
                Err(Fault::Overflow)
            } else {
                word(bits, a - b)
            }
        }
        Op::Div | Op::Rem if b == 0 => Err(Fault::DivisionByZero),
        Op::Div => word(bits, a / b),
        Op::Rem => word(bits, a % b),
        Op::Min => word(bits, a.min(b)),
        Op::Max => word(bits, a.max(b)),
        Op::SaturatingAdd => word(bits, (a + b).min(bound - 1)),
        Op::SaturatingSub => word(bits, a.saturating_sub(b)),
        Op::WrappingAdd => word(bits, (a + b) % bound),
        Op::WrappingSub => word(bits, (a + bound - b) % bound),
        Op::WrappingMul => word(bits, (a * b) % bound),
        Op::BitAnd => word(bits, a & b),
        Op::BitOr => word(bits, a | b),
        Op::BitXor => word(bits, a ^ b),
        Op::Shl | Op::Shr if b >= bits as u128 => Err(Fault::Overflow),
        // A valid left shift discards high bits even with overflow checks on.
        Op::Shl => word(bits, (a << b) % bound),
        Op::Shr => word(bits, a >> b),
    }
}
pub fn evaluate(expr: &Expr, env: &[Value]) -> Outcome {
    match &expr.kind {
        Kind::Bool(value) => Ok(Value::Bool(*value)),
        Kind::UInt { bits, value } => word(*bits, *value as u128),
        Kind::Var(i) => env.get(*i).cloned().ok_or(Fault::Input),
        Kind::Not(x) => match evaluate(x, env)? {
            Value::Bool(b) => Ok(Value::Bool(!b)),
            _ => Err(Fault::Type),
        },
        Kind::Binary { op, left, right } => {
            binary(*op, evaluate(left, env)?, evaluate(right, env)?)
        }
        Kind::If { condition, yes, no } => match evaluate(condition, env)? {
            Value::Bool(true) => evaluate(yes, env),
            Value::Bool(false) => evaluate(no, env),
            _ => Err(Fault::Type),
        },
        Kind::Let { value, body } => {
            let mut inner = vec![evaluate(value, env)?];
            inner.extend_from_slice(env);
            evaluate(body, &inner)
        }
        Kind::Assert { condition, body } => match evaluate(condition, env)? {
            Value::Bool(true) => evaluate(body, env),
            Value::Bool(false) => Err(Fault::Assertion),
            _ => Err(Fault::Type),
        },
    }
}
pub fn run(function: &Function, args: &[Value], usize_bits: u32) -> Outcome {
    if function.parameters.len() != args.len() {
        return Err(Fault::Input);
    }
    for (p, arg) in function.parameters.iter().zip(args) {
        match (p.ty.bits(usize_bits), arg) {
            (None, Value::Bool(_)) => {}
            (Some(w), Value::UInt { bits, value })
                if w == *bits && (*value as u128) < 1u128 << w => {}
            _ => return Err(Fault::Input),
        }
    }
    evaluate(&function.body, args)
}
