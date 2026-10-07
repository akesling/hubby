import Provium.State
/- An imperative extension of the pure expression machine for complete method
   bodies that mutate their receiver. Receivers, parameters and locals are
   values in slots; `assign` replaces one place inside a slot, so a `&mut self`
   method denotes a function from the old receiver value to the new one. This
   value semantics is adequate only for bodies without interior mutability,
   raw pointers or aliasing between distinct places, which the frontend must
   establish; physical layout and borrow refinement remain separate. -/
namespace Provium.Imperative
open Provium.State

/-- One step of a place path. Index positions are read from a slot so that
    paths stay first-order; the frontend evaluates index expressions first. -/
inductive Access where
  | field (name : String)
  | index (slot : Nat)
  deriving Repr, DecidableEq

inductive Expr where
  | literal (value : PureValue)
  | read (slot : Nat)
  | field (value : Expr) (name : String)
  | index (array position : Expr)
  | present (value : Expr)
  | record (name : String) (fields : List (String × Expr))
  | variant (name tag : String) (fields : List (String × Expr))
  | binary (op : String) (left right : Expr)
  | negate (value : Expr)
  | sequence (first second : Expr)
  | write (slot : Nat) (value : Expr)
  | assign (slot : Nat) (path : List Access) (value : Expr)
  | branch (condition yes no : Expr)
  | choose (value : Expr) (arms : List (PurePattern × Expr))
  | range (slot : Nat) (start stop : Expr) (body : Expr)
  | ret (value : Expr)
  | scope (body : Expr)
  | panic (reason : String)
  deriving Repr

inductive Fault where
  | exhausted | representation | overflow | bounds | division
  | panic (reason : String)
  deriving Repr, DecidableEq

/-- An early return keeps the environment, so the receiver's mutations up to
    the `return` are retained. -/
inductive Exit where
  | returned (value : PureValue) (env : PureEnv)
  | fault (reason : Fault)

abbrev Result := Except Exit (PureValue × PureEnv)

/-- Unsigned word widths by Rust type; `usize` has the target's pointer width
    `bits`, taken from the effective compiler configuration. -/
def width (bits : Nat) : String → Nat
  | "u8" => 8
  | "u16" => 16
  | "u32" => 32
  | "u64" => 64
  | "usize" => bits
  | _ => 0

def bound (bits : Nat) (kind : String) : Nat := 2 ^ width bits kind

def word (bits : Nat) (kind : String) (value : Nat) : Except Exit PureValue :=
  if value < bound bits kind then .ok (.number kind value) else .error (.fault .overflow)

/-- Unsigned operations. With `checked` (overflow checks enabled), `+`, `-`,
    `*` and out-of-range shift amounts panic as Rust's debug arithmetic does;
    otherwise they wrap and shift amounts are masked to the width. Division by
    zero panics in both profiles. Explicit wrapping, saturating and checked
    methods ignore the profile. -/
def arithmetic (bits : Nat) (checked : Bool) (op : String) (kind : String) (a b : Nat) :
    Except Exit PureValue :=
  let size := bound bits kind
  let shift := if checked then (if b < width bits kind then some b else none)
    else some (b % width bits kind)
  if width bits kind = 0 ∨ a ≥ size ∨ b ≥ size then .error (.fault .representation)
  else if op = "+" then if checked then word bits kind (a + b) else .ok (.number kind ((a + b) % size))
  else if op = "-" then
    if b ≤ a then .ok (.number kind (a - b))
    else if checked then .error (.fault .overflow) else .ok (.number kind (a + size - b))
  else if op = "*" then if checked then word bits kind (a * b) else .ok (.number kind ((a * b) % size))
  else if op = "/" then if b = 0 then .error (.fault .division) else .ok (.number kind (a / b))
  else if op = "%" then if b = 0 then .error (.fault .division) else .ok (.number kind (a % b))
  else if op = "wrapping_add" then .ok (.number kind ((a + b) % size))
  else if op = "wrapping_sub" then .ok (.number kind ((a + size - b) % size))
  else if op = "wrapping_mul" then .ok (.number kind ((a * b) % size))
  else if op = "^" then .ok (.number kind (a ^^^ b))
  else if op = "&" then .ok (.number kind (a &&& b))
  else if op = "|" then .ok (.number kind (a ||| b))
  else if op = ">>" then match shift with
    | some s => .ok (.number kind (a >>> s))
    | none => .error (.fault .overflow)
  else if op = "<<" then match shift with
    | some s => .ok (.number kind ((a <<< s) % size))
    | none => .error (.fault .overflow)
  else if op = "checked_add" then
    .ok (if a + b < size then .present (.number kind (a + b)) else .absent)
  else if op = "checked_sub" then
    .ok (if b ≤ a then .present (.number kind (a - b)) else .absent)
  else if op = "saturating_add" then .ok (.number kind (min (a + b) (size - 1)))
  else if op = "saturating_sub" then .ok (.number kind (a - b))
  else if op = "min" then .ok (.number kind (min a b))
  else if op = "max" then .ok (.number kind (max a b))
  else if op = "==" then .ok (.boolean (a == b))
  else if op = "!=" then .ok (.boolean (a != b))
  else if op = "<" then .ok (.boolean (decide (a < b)))
  else if op = "<=" then .ok (.boolean (decide (a ≤ b)))
  else if op = ">" then .ok (.boolean (decide (a > b)))
  else if op = ">=" then .ok (.boolean (decide (a ≥ b)))
  else .error (.fault .representation)

/-- Structural equality of values for `==` on enums, options and records with
    derived equality. Opaque or malformed operands, and values nested deeper
    than `fuel`, have no equality. Recursion is on `fuel` so that kernel
    reduction can evaluate it. -/
def equal : Nat → PureValue → PureValue → Option Bool
  | 0, _, _ => none
  | fuel + 1, left, right => match left, right with
    | .unit, .unit => some true
    | .boolean a, .boolean b => some (a == b)
    | .number kind a, .number other b => if kind = other then some (a == b) else none
    | .absent, .absent => some true
    | .absent, .present _ | .present _, .absent => some false
    | .present a, .present b => equal fuel a b
    | .variant owner tag fields, .variant other tag' fields' =>
      if owner ≠ other then none
      else if tag ≠ tag' then some false
      else fields.zip fields' |>.foldl (fun result (a, b) => match result with
        | some x => if a.1 ≠ b.1 then none else (equal fuel a.2 b.2).map (x && ·)
        | none => none) (if fields.length = fields'.length then some true else none)
    | .record name fields, .record other fields' =>
      if name ≠ other then none
      else fields.zip fields' |>.foldl (fun result (a, b) => match result with
        | some x => if a.1 ≠ b.1 then none else (equal fuel a.2 b.2).map (x && ·)
        | none => none) (if fields.length = fields'.length then some true else none)
    | _, _ => none

def binary (bits : Nat) (checked : Bool) (fuel : Nat) (op : String) (left right : PureValue) : Except Exit PureValue :=
  match left, right with
  | .number kind a, .number other b =>
    if kind ≠ other then .error (.fault .representation)
    else arithmetic bits checked op kind a b
  | .boolean a, .boolean b =>
    if op = "==" then .ok (.boolean (a == b))
    else if op = "!=" then .ok (.boolean (a != b))
    else if op = "^" then .ok (.boolean (a != b))
    else if op = "&" then .ok (.boolean (a && b))
    else if op = "|" then .ok (.boolean (a || b))
    else .error (.fault .representation)
  | _, _ => match equal fuel left right with
    | some value =>
      if op = "==" then .ok (.boolean value)
      else if op = "!=" then .ok (.boolean (!value))
      else .error (.fault .representation)
    | none => .error (.fault .representation)

def indexValue (values : List PureValue) (position : PureValue) : Except Exit PureValue :=
  match position with
  | .number _ i => match values[i]? with
    | some value => .ok value
    | none => .error (.fault .bounds)
  | _ => .error (.fault .representation)

/-- Replace the field `name` using `change`; a missing field is a
    representation fault. -/
def replaceField (change : PureValue → Except Exit PureValue) (name : String) :
    List (String × PureValue) → Except Exit (List (String × PureValue))
  | [] => .error (.fault .representation)
  | (n, old) :: rest =>
    if n = name then do
      let updated ← change old
      return (n, updated) :: rest
    else do
      let rest ← replaceField change name rest
      return (n, old) :: rest

/-- Replace the place at `path` inside `value`. Missing fields and wrong shapes
    are representation faults; out-of-range indices are bounds faults.
    Recursion is on the path, so kernel reduction can evaluate it. -/
def update (env : PureEnv) : List Access → PureValue → PureValue → Except Exit PureValue
  | [], _, replacement => .ok replacement
  | .field n :: rest, .record name fields, replacement => do
    let fields ← replaceField (fun old => update env rest old replacement) n fields
    return .record name fields
  | .field n :: rest, .variant owner tag fields, replacement => do
    let fields ← replaceField (fun old => update env rest old replacement) n fields
    return .variant owner tag fields
  | .index slot :: rest, .array values, replacement =>
    match env slot with
    | some (.number _ i) => match values[i]? with
      | some old => do
        let updated ← update env rest old replacement
        return .array (values.set i updated)
      | none => .error (.fault .bounds)
    | _ => .error (.fault .representation)
  | _, _, _ => .error (.fault .representation)

/-- Ordered arm selection with the same three-valued matching as `pureSelect`:
    a fault in any arm tried before a match is propagated, never skipped. -/
def select (fuel : Nat) (arms : List (PurePattern × Expr)) (value : PureValue) (env : PureEnv) :
    Except PureFault (Option (Expr × PureEnv)) :=
  arms.foldlM (fun found arm => match found with
    | some hit => .ok (some hit)
    | none => match pureMatch fuel arm.1 value env with
      | .ok (some env) => .ok (some (arm.2, env))
      | .ok none => .ok none
      | .error reason => .error reason) none

def eval (bits : Nat) (checked : Bool) : Nat → Expr → PureEnv → Result
  | 0, _, _ => .error (.fault .exhausted)
  | fuel + 1, expression, env => match expression with
    | .literal value => .ok (value, env)
    | .read slot => match env slot with
      | some value => .ok (value, env)
      | none => .error (.fault .representation)
    | .field value name => do
      let (value, env) ← eval bits checked fuel value env
      match pureField value name with
      | some value => return (value, env)
      | none => .error (.fault .representation)
    | .index array position => do
      let (array, env) ← eval bits checked fuel array env
      let (position, env) ← eval bits checked fuel position env
      match array with
      | .array values => do
        let value ← indexValue values position
        return (value, env)
      | _ => .error (.fault .representation)
    | .present value => do
      let (value, env) ← eval bits checked fuel value env
      return (.present value, env)
    | .record name fields => do
      let (values, env) ← fields.foldlM (fun (values, env) (field, value) => do
        let (value, env) ← eval bits checked fuel value env
        return (values ++ [(field, value)], env)) ([], env)
      return (.record name values, env)
    | .variant name tag fields => do
      let (values, env) ← fields.foldlM (fun (values, env) (field, value) => do
        let (value, env) ← eval bits checked fuel value env
        return (values ++ [(field, value)], env)) ([], env)
      return (.variant name tag values, env)
    | .negate value => do
      let (.boolean value, env) ← eval bits checked fuel value env
        | .error (.fault .representation)
      return (.boolean (!value), env)
    | .binary op left right => do
      let (left, env) ← eval bits checked fuel left env
      if op = "&&" || op = "||" then
        let .boolean value := left | .error (.fault .representation)
        if (op = "&&" && !value) || (op = "||" && value) then
          return (.boolean value, env)
        else
          let (.boolean value, env) ← eval bits checked fuel right env
            | .error (.fault .representation)
          return (.boolean value, env)
      else
        let (right, env) ← eval bits checked fuel right env
        let value ← binary bits checked fuel op left right
        return (value, env)
    | .sequence first second => do
      let (_, env) ← eval bits checked fuel first env
      eval bits checked fuel second env
    | .write slot value => do
      let (value, env) ← eval bits checked fuel value env
      return (.unit, pureSet env slot value)
    | .assign slot path value => do
      let (value, env) ← eval bits checked fuel value env
      match env slot with
      | none => .error (.fault .representation)
      | some current => do
        let updated ← update env path current value
        return (.unit, pureSet env slot updated)
    | .branch condition yes no => do
      let (.boolean condition, env) ← eval bits checked fuel condition env
        | .error (.fault .representation)
      eval bits checked fuel (if condition then yes else no) env
    | .choose value arms => do
      let (value, env) ← eval bits checked fuel value env
      match select fuel arms value env with
      | .ok (some (body, env)) => eval bits checked fuel body env
      | .ok none => .error (.fault .representation)
      | .error .exhausted => .error (.fault .exhausted)
      | .error _ => .error (.fault .representation)
    | .range slot start stop body => do
      let (.number kind first, env) ← eval bits checked fuel start env
        | .error (.fault .representation)
      let (.number other last, env) ← eval bits checked fuel stop env
        | .error (.fault .representation)
      if kind ≠ other then .error (.fault .representation) else
      (List.range' first (last - first)).foldlM (fun (_, env) i =>
        eval bits checked fuel body (pureSet env slot (.number kind i))) (.unit, env)
    | .ret value => do
      let (value, env) ← eval bits checked fuel value env
      .error (.returned value env)
    | .scope body => match eval bits checked fuel body env with
      | .error (.returned value env) => .ok (value, env)
      | result => result
    | .panic reason => .error (.fault (.panic reason))

/-- Run a method body with its receiver in slot 0 and parameters in slots
    1, 2, ... The result is the returned value and the final receiver; a fault
    carries no state, since partially mutated receivers are not modeled here. -/
def run (bits : Nat) (checked : Bool) (fuel : Nat) (body : Expr) (receiver : PureValue) (arguments : List PureValue) :
    Except Fault (PureValue × PureValue) :=
  let env := (arguments.zipIdx 1).foldl (fun env (value, slot) => pureSet env slot value)
    (pureSet (fun _ => none) 0 receiver)
  match eval bits checked fuel body env with
  | .ok (value, env) => match env 0 with
    | some receiver => .ok (value, receiver)
    | none => .error .representation
  | .error (.returned value final) => match final 0 with
    | some receiver => .ok (value, receiver)
    | none => .error .representation
  | .error (.fault reason) => .error reason

/-! Evaluation lemmas for unsigned 64-bit operands. Each states the result of
    one operation under the operand ranges that every well-typed `u64` value
    meets, independently of the target width and overflow profile where Rust's
    result is profile-independent. -/
section Lemmas
variable {bits : Nat} {checked : Bool} {a b : Nat}

@[simp] theorem width_u64 : width bits "u64" = 64 := rfl
@[simp] theorem bound_u64 : bound bits "u64" = 2^64 := rfl

/- Wrapping results put the second operand first. The kernel reduces `x + c`
   and `x * c` by recursion on `c`, so a symbolic receiver combined with a
   large literal argument (`x.wrapping_mul(CONST)`) must not appear in that
   order in any term the kernel may need to reduce. -/
theorem wrapping_add_u64 (ha : a < 2^64) (hb : b < 2^64) :
    arithmetic bits checked "wrapping_add" "u64" a b = .ok (.number "u64" ((b + a) % 2^64)) := by
  simp [arithmetic, Nat.not_le.mpr ha, Nat.not_le.mpr hb, Nat.add_comm]

theorem wrapping_mul_u64 (ha : a < 2^64) (hb : b < 2^64) :
    arithmetic bits checked "wrapping_mul" "u64" a b = .ok (.number "u64" ((b * a) % 2^64)) := by
  simp [arithmetic, Nat.not_le.mpr ha, Nat.not_le.mpr hb, Nat.mul_comm]

theorem xor_u64 (ha : a < 2^64) (hb : b < 2^64) :
    arithmetic bits checked "^" "u64" a b = .ok (.number "u64" (a ^^^ b)) := by
  simp [arithmetic, Nat.not_le.mpr ha, Nat.not_le.mpr hb]

theorem shift_right_u64 (ha : a < 2^64) (hb : b < 64) :
    arithmetic bits checked ">>" "u64" a b = .ok (.number "u64" (a >>> b)) := by
  have hb' : b < 2^64 := Nat.lt_trans hb (by decide)
  have hm : b % 64 = b := Nat.mod_eq_of_lt hb
  cases checked <;> simp [arithmetic, hb, hm, Nat.not_le.mpr ha, Nat.not_le.mpr hb']

theorem rem_u64 (ha : a < 2^64) (hb : b < 2^64) (positive : 0 < b) :
    arithmetic bits checked "%" "u64" a b = .ok (.number "u64" (a % b)) := by
  simp [arithmetic, Nat.not_le.mpr ha, Nat.not_le.mpr hb, Nat.ne_of_gt positive]

theorem add_u64 (h : a + b < 2^64) :
    arithmetic bits checked "+" "u64" a b = .ok (.number "u64" (a + b)) := by
  have ha : a < 2^64 := by omega
  have hb : b < 2^64 := by omega
  cases checked <;> simp [arithmetic, word, h, Nat.not_le.mpr ha, Nat.not_le.mpr hb, Nat.mod_eq_of_lt h]

/-! Lemmas for symbolic evaluation with `simp`: environment lookups that keep
    the environment as nested `pureSet` terms, field reads of record literals
    that leave reads of opaque values for hypotheses, and `u64` range facts.
    The range facts are stated at the literal bound because `simp` normalizes
    `2^64` to it before discharging side conditions. -/
theorem set_same (env : PureEnv) (k : Nat) (v : PureValue) : pureSet env k v k = some v := by
  simp [pureSet]

theorem set_other (env : PureEnv) {j k : Nat} (v : PureValue) (h : k ≠ j) : pureSet env j v k = env k := by
  simp [pureSet, h]

theorem field_record (name key : String) (fields : List (String × PureValue)) :
    pureField (.record name fields) key = (fields.find? (fun pair => pair.1 == key)).map (·.2) := by
  simp [pureField, pureFields]
  cases fields.find? (fun pair => pair.1 == key) <;> rfl

theorem mod_word (x : Nat) : x % 18446744073709551616 < 18446744073709551616 := Nat.mod_lt _ (by decide)

theorem xor_word {a b : Nat} (ha : a < 18446744073709551616) (hb : b < 18446744073709551616) :
    a ^^^ b < 18446744073709551616 := Nat.xor_lt_two_pow (n := 64) ha hb

theorem shift_word {a : Nat} (k : Nat) (ha : a < 18446744073709551616) : a >>> k < 18446744073709551616 :=
  Nat.lt_of_le_of_lt (by rw [Nat.shiftRight_eq_div_pow]; exact Nat.div_le_self _ _) ha

end Lemmas

end Provium.Imperative
