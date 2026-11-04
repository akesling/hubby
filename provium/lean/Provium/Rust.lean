/-
Runtime library for Provium's typed backend.

Rust items translate to ordinary Lean definitions over the types below. Every
possibly failing operation lives in `Rust.M`: `throw` is a panic and the
`Option` layer's `none` is non-termination, so a translated function is total
and its failures stay visible to proofs. Operations that cannot fail are pure.

Scalars are `Fin (2 ^ bits)`, so `omega` and `simp [Fin.ext_iff]` reason about
them directly. `usize` is 64 bits wide; the code generator rejects other targets.
-/

namespace Rust

/-- A Rust panic. The message is diagnostic only. -/
structure Panic where
  msg : String
  deriving Repr, DecidableEq, Inhabited

/-- Results of translated code: `none` is divergence, `some (.error p)` a panic. -/
abbrev M := ExceptT Panic Option

/-- Panic with a diagnostic message. -/
def fail {α : Type} (msg : String) : M α := throw ⟨msg⟩

/-- `core::result::Result`. -/
inductive Result (T E : Type) where
  | Ok (v : T)
  | Err (e : E)
  deriving Repr, DecidableEq, Inhabited

/-- `core::num::TryFromIntError`. -/
structure TryFromIntError where
  deriving Repr, DecidableEq, Inhabited

abbrev u8 := Fin (2 ^ 8)
abbrev u16 := Fin (2 ^ 16)
abbrev u32 := Fin (2 ^ 32)
abbrev u64 := Fin (2 ^ 64)
abbrev usize := Fin (2 ^ 64)

/-! ## Unsigned arithmetic -/

section Arith
variable {n : Nat}

/-- The largest value of an unsigned type. -/
def umax (n : Nat) : Fin (2 ^ n) := ⟨2 ^ n - 1, by have := Nat.two_pow_pos n; omega⟩

/-- Checked `+`: panics on overflow (`overflow-checks = on`). -/
def add (a b : Fin (2 ^ n)) : M (Fin (2 ^ n)) :=
  if h : a.val + b.val < 2 ^ n then pure ⟨a.val + b.val, h⟩ else fail "attempt to add with overflow"
/-- Checked `-`. -/
def sub (a b : Fin (2 ^ n)) : M (Fin (2 ^ n)) :=
  if h : b.val ≤ a.val then pure ⟨a.val - b.val, by omega⟩ else fail "attempt to subtract with overflow"
/-- Checked `*`. -/
def mul (a b : Fin (2 ^ n)) : M (Fin (2 ^ n)) :=
  if h : a.val * b.val < 2 ^ n then pure ⟨a.val * b.val, h⟩ else fail "attempt to multiply with overflow"
/-- `/`: panics on division by zero. -/
def div (a b : Fin (2 ^ n)) : M (Fin (2 ^ n)) :=
  if b.val = 0 then fail "attempt to divide by zero"
  else pure ⟨a.val / b.val, Nat.lt_of_le_of_lt (Nat.div_le_self _ _) a.isLt⟩
/-- `%`: panics on division by zero. -/
def rem (a b : Fin (2 ^ n)) : M (Fin (2 ^ n)) :=
  if b.val = 0 then fail "attempt to calculate the remainder with a divisor of zero"
  else pure ⟨a.val % b.val, Nat.lt_of_le_of_lt (Nat.mod_le _ _) a.isLt⟩

/-- Wrapping arithmetic (`wrapping_*`, and `+ - *` without overflow checks). -/
def wrapping_add (a b : Fin (2 ^ n)) : Fin (2 ^ n) :=
  ⟨(a.val + b.val) % 2 ^ n, Nat.mod_lt _ (Nat.two_pow_pos n)⟩
def wrapping_sub (a b : Fin (2 ^ n)) : Fin (2 ^ n) :=
  ⟨(a.val + (2 ^ n - b.val)) % 2 ^ n, Nat.mod_lt _ (Nat.two_pow_pos n)⟩
def wrapping_mul (a b : Fin (2 ^ n)) : Fin (2 ^ n) :=
  ⟨(a.val * b.val) % 2 ^ n, Nat.mod_lt _ (Nat.two_pow_pos n)⟩

def checked_add (a b : Fin (2 ^ n)) : Option (Fin (2 ^ n)) :=
  if h : a.val + b.val < 2 ^ n then some ⟨a.val + b.val, h⟩ else none
def checked_sub (a b : Fin (2 ^ n)) : Option (Fin (2 ^ n)) :=
  if h : b.val ≤ a.val then some ⟨a.val - b.val, by omega⟩ else none
def checked_mul (a b : Fin (2 ^ n)) : Option (Fin (2 ^ n)) :=
  if h : a.val * b.val < 2 ^ n then some ⟨a.val * b.val, h⟩ else none

def saturating_add (a b : Fin (2 ^ n)) : Fin (2 ^ n) :=
  if h : a.val + b.val < 2 ^ n then ⟨a.val + b.val, h⟩ else umax n
def saturating_sub (a b : Fin (2 ^ n)) : Fin (2 ^ n) :=
  ⟨a.val - b.val, by omega⟩

def min (a b : Fin (2 ^ n)) : Fin (2 ^ n) := if a.val ≤ b.val then a else b
def max (a b : Fin (2 ^ n)) : Fin (2 ^ n) := if a.val ≤ b.val then b else a
/-- `Ord::clamp`: panics unless `lo ≤ hi`. -/
def clamp (x lo hi : Fin (2 ^ n)) : M (Fin (2 ^ n)) :=
  if lo.val ≤ hi.val then pure (min (max x lo) hi) else fail "assertion failed: min <= max"

def xor (a b : Fin (2 ^ n)) : Fin (2 ^ n) :=
  ⟨(a.val ^^^ b.val) % 2 ^ n, Nat.mod_lt _ (Nat.two_pow_pos n)⟩
def band (a b : Fin (2 ^ n)) : Fin (2 ^ n) :=
  ⟨(a.val &&& b.val) % 2 ^ n, Nat.mod_lt _ (Nat.two_pow_pos n)⟩
def bor (a b : Fin (2 ^ n)) : Fin (2 ^ n) :=
  ⟨(a.val ||| b.val) % 2 ^ n, Nat.mod_lt _ (Nat.two_pow_pos n)⟩
/-- `>>` by a shift amount: panics when the amount is at least the width. -/
def shr {k : Nat} (a : Fin (2 ^ n)) (s : Fin (2 ^ k)) : M (Fin (2 ^ n)) :=
  if s.val < n then pure ⟨a.val >>> s.val, Nat.lt_of_le_of_lt (Nat.shiftRight_le _ _) a.isLt⟩
  else fail "attempt to shift right with overflow"
/-- `<<` by a shift amount: panics when the amount is at least the width. -/
def shl {k : Nat} (a : Fin (2 ^ n)) (s : Fin (2 ^ k)) : M (Fin (2 ^ n)) :=
  if s.val < n then pure ⟨(a.val <<< s.val) % 2 ^ n, Nat.mod_lt _ (Nat.two_pow_pos n)⟩
  else fail "attempt to shift left with overflow"

/-- `as` between unsigned types: truncation or zero extension. -/
def cast {m : Nat} (a : Fin (2 ^ n)) : Fin (2 ^ m) :=
  ⟨a.val % 2 ^ m, Nat.mod_lt _ (Nat.two_pow_pos m)⟩
/-- `bool as uN` and `uN::from(bool)`. -/
def ofBool (b : Bool) : Fin (2 ^ n) :=
  ⟨(if b then 1 else 0) % 2 ^ n, Nat.mod_lt _ (Nat.two_pow_pos n)⟩
/-- `TryFrom` between unsigned types. -/
def try_from {m : Nat} (a : Fin (2 ^ n)) : Result (Fin (2 ^ m)) TryFromIntError :=
  if h : a.val < 2 ^ m then .Ok ⟨a.val, h⟩ else .Err {}
/-- A const generic or other mathematical value used as a `usize`. -/
def ofNat (k : Nat) : Fin (2 ^ n) := ⟨k % 2 ^ n, Nat.mod_lt _ (Nat.two_pow_pos n)⟩

/-- A const generic, constant or length as a `usize`. -/
def usizeOf (k : Nat) : usize := ofNat k

end Arith

/-! ## Signed integers

`iN` is an integer in `[-2^(N-1), 2^(N-1))`. Rust's default literal type `i32`
appears whenever a literal's type is fixed by nothing else.
-/

structure IntN (n : Nat) where
  val : Int
  lo : -(2 ^ (n - 1) : Int) ≤ val
  hi : val < (2 ^ (n - 1) : Int)
  deriving DecidableEq

instance {n : Nat} : Repr (IntN n) := ⟨fun a p => reprPrec a.val p⟩

abbrev i8 := IntN 8
abbrev i16 := IntN 16
abbrev i32 := IntN 32
abbrev i64 := IntN 64
abbrev isize := IntN 64

namespace IntN
variable {n : Nat}
instance : LT (IntN n) := ⟨fun a b => a.val < b.val⟩
instance : LE (IntN n) := ⟨fun a b => a.val ≤ b.val⟩
instance (a b : IntN n) : Decidable (a < b) := Int.decLt _ _
instance (a b : IntN n) : Decidable (a ≤ b) := Int.decLe _ _

/-- Two's complement wrapping of an integer into `iN`. -/
def wrap (n : Nat) (x : Int) : IntN n :=
  let m : Int := 2 ^ (n - 1)
  have hm : 0 < m := Int.pow_pos (by decide)
  let r := (x + m) % (2 * m)
  have h0 : 0 ≤ r := Int.emod_nonneg _ (by omega)
  have h1 : r < 2 * m := Int.emod_lt_of_pos _ (by omega)
  ⟨r - m, by omega, by omega⟩

instance {k : Nat} : OfNat (IntN n) k := ⟨wrap n k⟩
end IntN

/-- Checked signed arithmetic. -/
def iadd {n : Nat} (a b : IntN n) : M (IntN n) :=
  if h : -(2 ^ (n - 1) : Int) ≤ a.val + b.val ∧ a.val + b.val < 2 ^ (n - 1) then pure ⟨_, h.1, h.2⟩
  else fail "attempt to add with overflow"
def isub {n : Nat} (a b : IntN n) : M (IntN n) :=
  if h : -(2 ^ (n - 1) : Int) ≤ a.val - b.val ∧ a.val - b.val < 2 ^ (n - 1) then pure ⟨_, h.1, h.2⟩
  else fail "attempt to subtract with overflow"
def imul {n : Nat} (a b : IntN n) : M (IntN n) :=
  if h : -(2 ^ (n - 1) : Int) ≤ a.val * b.val ∧ a.val * b.val < 2 ^ (n - 1) then pure ⟨_, h.1, h.2⟩
  else fail "attempt to multiply with overflow"

/-! ## Option and Result -/

namespace Option
variable {α β : Type}

def is_some_and (o : Option α) (f : α → Bool) : Bool := match o with
  | some a => f a | none => false
def is_none_or (o : Option α) (f : α → Bool) : Bool := match o with
  | some a => f a | none => true
def map_or (o : Option α) (d : β) (f : α → β) : β := match o with
  | some a => f a | none => d
def ok_or {E : Type} (o : Option α) (e : E) : Result α E := match o with
  | some a => .Ok a | none => .Err e
def expect (o : Option α) (msg : String) : M α := match o with
  | some a => pure a | none => fail msg
def unwrap (o : Option α) : M α := expect o "called `Option::unwrap()` on a `None` value"
/-- `bool::then_some`. -/
def then_some (b : Bool) (a : α) : Option α := if b then some a else none

/-- Monadic forms for closures that may panic. -/
def is_some_andM (o : Option α) (f : α → M Bool) : M Bool := match o with
  | some a => f a | none => pure false
def is_none_orM (o : Option α) (f : α → M Bool) : M Bool := match o with
  | some a => f a | none => pure true
def map_orM (o : Option α) (d : β) (f : α → M β) : M β := match o with
  | some a => f a | none => pure d
def mapM (o : Option α) (f : α → M β) : M (Option β) := match o with
  | some a => some <$> f a | none => pure none
def and_thenM (o : Option α) (f : α → M (Option β)) : M (Option β) := match o with
  | some a => f a | none => pure none
def filterM (o : Option α) (f : α → M Bool) : M (Option α) := match o with
  | some a => do if ← f a then pure (some a) else pure none
  | none => pure none
def or_elseM (o : Option α) (f : Unit → M (Option α)) : M (Option α) := match o with
  | some a => pure (some a) | none => f ()
end Option

namespace Result
variable {T E F : Type}
def is_ok : Result T E → Bool | .Ok _ => true | .Err _ => false
def is_err : Result T E → Bool | .Ok _ => false | .Err _ => true
def ok : Result T E → Option T | .Ok v => some v | .Err _ => none
def map_err (r : Result T E) (f : E → F) : Result T F := match r with
  | .Ok v => .Ok v | .Err e => .Err (f e)
def unwrap (r : Result T E) : M T := match r with
  | .Ok v => pure v | .Err _ => fail "called `Result::unwrap()` on an `Err` value"
def expect (r : Result T E) (msg : String) : M T := match r with
  | .Ok v => pure v | .Err _ => fail msg
def unwrap_or (r : Result T E) (d : T) : T := match r with
  | .Ok v => v | .Err _ => d
def map_errM (r : Result T E) (f : E → M F) : M (Result T F) := match r with
  | .Ok v => pure (.Ok v) | .Err e => .Err <$> f e
end Result

/-! ## Arrays, slices and iterators

Fixed arrays `[T; N]` are `Vector T N`; slices are `Array T`; iterators are the
`List` of the items they yield. Iterator adaptors whose closures may panic are
fused into explicit loops by the code generator, so eager list evaluation here
never runs a closure that the lazy Rust iterator would not.
-/

namespace Slice
variable {α : Type}

def index {n : Nat} (a : Vector α n) (i : usize) : M α :=
  if h : i.val < n then pure a[i.val] else fail "index out of bounds"
def set {n : Nat} (a : Vector α n) (i : usize) (v : α) : M (Vector α n) :=
  if h : i.val < n then pure (a.set i.val v) else fail "index out of bounds"
/-- `<[T]>::get`. -/
def get {n : Nat} (a : Vector α n) (i : usize) : Option α := a.toArray[i.val]?
def len {n : Nat} (_ : Vector α n) : usize := ofNat n

/-- `a[lo..hi]`, panicking like Rust on an invalid range. -/
def range {n : Nat} (a : Vector α n) (lo hi : usize) : M (Array α) :=
  if lo.val ≤ hi.val ∧ hi.val ≤ n then pure (a.toArray.extract lo.val hi.val)
  else fail "range out of bounds"
/-- Write back a mutably borrowed `a[lo..hi]` of unchanged length. -/
def setRange {n : Nat} (a : Vector α n) (lo : usize) (s : Array α) : Vector α n :=
  Vector.ofFn fun i =>
    if h : lo.val ≤ i.val ∧ i.val - lo.val < s.size then s[i.val - lo.val] else a[i]

/-- Slice (`Array`) forms of indexing and ranges. -/
def indexA (a : Array α) (i : usize) : M α :=
  if h : i.val < a.size then pure a[i.val] else fail "index out of bounds"
def setA (a : Array α) (i : usize) (v : α) : M (Array α) :=
  if h : i.val < a.size then pure (a.set i.val v) else fail "index out of bounds"
def rangeA (a : Array α) (lo hi : usize) : M (Array α) :=
  if lo.val ≤ hi.val ∧ hi.val ≤ a.size then pure (a.extract lo.val hi.val)
  else fail "range out of bounds"
def setRangeA (a : Array α) (lo : usize) (s : Array α) : Array α :=
  Array.ofFn fun (i : Fin a.size) =>
    if h : lo.val ≤ i.val ∧ i.val - lo.val < s.size then s[i.val - lo.val] else a[i]

def fill {n : Nat} (_ : Vector α n) (v : α) : Vector α n := Vector.replicate n v
def rotate_left (s : Array α) (k : usize) : M (Array α) :=
  if k.val ≤ s.size then pure (s.extract k.val s.size ++ s.extract 0 k.val)
  else fail "assertion failed: mid <= self.len()"
/-- `sort_unstable` on a slice of unsigned values: its result is the unique sorted permutation. -/
def sort_unstable {n : Nat} (s : Array (Fin n)) : Array (Fin n) :=
  (s.toList.mergeSort (fun a b => a.val ≤ b.val)).toArray
def contains [DecidableEq α] {n : Nat} (a : Vector α n) (x : α) : Bool := a.toList.contains x
def iter {n : Nat} (a : Vector α n) : List α := a.toList
/-- `core::array::from_fn`. -/
def from_fn (n : Nat) (f : usize → α) : Vector α n := Vector.ofFn fun i => f (ofNat i.val)
def from_fnM (n : Nat) (f : usize → M α) : M (Vector α n) :=
  (Vector.ofFn fun i : Fin n => f (ofNat i.val)).mapM id
end Slice

namespace Iter
variable {α β : Type}
/-- Positions are counted in `usize`; an iterator over at most `2^64` items. -/
def enumerate (l : List α) : List (usize × α) := (l.zipIdx).map fun (a, i) => (ofNat i, a)
def position (l : List α) (p : α → Bool) : Option usize := (l.findIdx? p).map ofNat
def count (l : List α) : usize := ofNat l.length
def flatten (l : List (Option α)) : List α := l.filterMap id
def next_back (l : List α) : Option α := l.getLast?
def next (l : List α) : Option α := l.head?
def take_while (l : List α) (p : α → Bool) : List α := l.takeWhile p
def range (lo hi : usize) : List usize :=
  (List.range (hi.val - lo.val)).map fun i => ofNat (lo.val + i)
end Iter

/-! ## Traits

`Clone` translates to the identity: values have no identity in Lean, and
application `Clone` implementations are assumed to return an equal value
without panicking. Derived `PartialEq` translates to Lean's decidable equality.
-/

end Rust
