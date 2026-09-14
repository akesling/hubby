import Lean

/- Operational semantics for Provium's supported, checked unsigned Rust subset.
   This file is part of the trusted semantic specification, not generated proof
   evidence of equivalence to all of Rust. Errors distinguish overflow,
   division by zero, assertion failure, and invalid inputs. -/
namespace Provium
inductive Ty where
  | boolean
  | uint (bits : Nat)
  deriving Repr, DecidableEq
inductive Value where
  | boolean (value : Bool)
  | uint (bits value : Nat)
  deriving Repr, DecidableEq
inductive Fault where
  | typeMismatch | overflow | divisionByZero | assertion | input
  deriving Repr, DecidableEq
abbrev Result := Except Fault Value
abbrev Env := List Value
inductive Op where
  | add | sub | mul | div | rem | eq | ne | lt | le | gt | ge | min | max
  | saturatingAdd | saturatingSub | wrappingAdd | wrappingSub | wrappingMul
  | bitAnd | bitOr | bitXor | shl | shr
  deriving Repr, DecidableEq

def validWidth (w : Nat) : Bool := w == 8 || w == 16 || w == 32 || w == 64

def word (w n : Nat) : Result :=
  if !validWidth w then .error .typeMismatch
  else if n < 2^w then .ok (.uint w n) else .error .overflow

def bind (result : Result) (next : Value → Result) : Result :=
  match result with
  | .ok value => next value
  | .error fault => .error fault

def get (env : Env) (index : Nat) : Result :=
  match env[index]? with
  | some value => .ok value
  | none => .error .input

def negate (value : Value) : Result :=
  match value with
  | .boolean b => .ok (.boolean (!b))
  | _ => .error .typeMismatch

def branch (condition : Value) (yes no : Unit → Result) : Result :=
  match condition with
  | .boolean true => yes ()
  | .boolean false => no ()
  | _ => .error .typeMismatch

def guard (condition : Value) (next : Unit → Result) : Result :=
  match condition with
  | .boolean true => next ()
  | .boolean false => .error .assertion
  | _ => .error .typeMismatch

def uintOp (op : Op) (w a b : Nat) : Result :=
  match op with
  | .add => word w (a + b)
  | .sub => if a < b then .error .overflow else word w (a - b)
  | .mul => word w (a * b)
  | .div => if b == 0 then .error .divisionByZero else word w (a / b)
  | .rem => if b == 0 then .error .divisionByZero else word w (a % b)
  | .eq => .ok (.boolean (decide (a = b)))
  | .ne => .ok (.boolean (decide (a ≠ b)))
  | .lt => .ok (.boolean (decide (a < b)))
  | .le => .ok (.boolean (decide (a ≤ b)))
  | .gt => .ok (.boolean (decide (a > b)))
  | .ge => .ok (.boolean (decide (a ≥ b)))
  | .min => word w (Nat.min a b)
  | .max => word w (Nat.max a b)
  | .saturatingAdd => word w (Nat.min (a + b) (2^w - 1))
  | .saturatingSub => word w (a - b)
  | .wrappingAdd => word w ((a + b) % 2^w)
  | .wrappingSub => word w ((a + 2^w - b) % 2^w)
  | .wrappingMul => word w ((a * b) % 2^w)
  | .bitAnd => word w (Nat.land a b)
  | .bitOr => word w (Nat.lor a b)
  | .bitXor => word w (Nat.xor a b)
  | .shl => if b < w then word w ((a * 2^b) % 2^w) else .error .overflow
  | .shr => if b < w then word w (a / 2^b) else .error .overflow

def binary (op : Op) (left right : Value) : Result :=
  match left, right with
  | .boolean a, .boolean b =>
    match op with
    | .eq => .ok (.boolean (a == b))
    | .ne => .ok (.boolean (a != b))
    | _ => .error .typeMismatch
  | .uint w a, .uint v b =>
    if w != v || !validWidth w then .error .typeMismatch
    else if a < 2^w ∧ b < 2^w then uintOp op w a b
    else .error .overflow
  | _, _ => .error .typeMismatch

inductive Expr where
  | boolean (b : Bool)
  | uint (bits value : Nat)
  | var (index : Nat)
  | negate (arg : Expr)
  | binary (op : Op) (left right : Expr)
  | ite (condition yes no : Expr)
  | letE (value body : Expr)
  | guard (condition body : Expr)
  deriving Repr

def eval (expr : Expr) (env : Env) : Result :=
  match expr with
  | .boolean b => .ok (.boolean b)
  | .uint w n => word w n
  | .var i => get env i
  | .negate arg => bind (eval arg env) negate
  | .binary op left right => bind (eval left env) (fun a => bind (eval right env) (fun b => binary op a b))
  | .ite condition yes no => bind (eval condition env) (fun c => branch c (fun _ => eval yes env) (fun _ => eval no env))
  | .letE value body => bind (eval value env) (fun x => eval body (x :: env))
  | .guard condition body => bind (eval condition env) (fun c => guard c (fun _ => eval body env))

def validArgs : List Ty → Env → Bool
  | [], [] => true
  | .boolean :: types, .boolean _ :: values => validArgs types values
  | .uint w :: types, .uint v n :: values => w == v && validWidth w && decide (n < 2^w) && validArgs types values
  | _, _ => false

def run (types : List Ty) (expr : Expr) (env : Env) : Result :=
  if validArgs types env then eval expr env else .error .input
/-- Total correctness for a terminating scalar program: every input satisfying
    pre returns successfully and satisfies post. An assertion or arithmetic
    fault cannot establish this contract. -/
def Ensures (program : Env → Result) (pre : Env → Prop)
    (post : Env → Value → Prop) : Prop :=
  ∀ env, pre env → ∃ value, program env = .ok value ∧ post env value
end Provium
