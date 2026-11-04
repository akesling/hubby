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

/-- Operations by a literal that cannot panic: a shift amount below the width
or a nonzero divisor. -/
def shrK (a : Fin (2 ^ n)) (k : Nat) : Fin (2 ^ n) :=
  ⟨a.val >>> k, Nat.lt_of_le_of_lt (Nat.shiftRight_le _ _) a.isLt⟩
def shlK (a : Fin (2 ^ n)) (k : Nat) : Fin (2 ^ n) :=
  ⟨(a.val <<< k) % 2 ^ n, Nat.mod_lt _ (Nat.two_pow_pos n)⟩
def divK (a : Fin (2 ^ n)) (k : Nat) : Fin (2 ^ n) :=
  ⟨a.val / k, Nat.lt_of_le_of_lt (Nat.div_le_self _ _) a.isLt⟩
def remK (a : Fin (2 ^ n)) (k : Nat) : Fin (2 ^ n) :=
  if k = 0 then a else ⟨a.val % k, Nat.lt_of_le_of_lt (Nat.mod_le _ _) a.isLt⟩

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

/-- `for x in &mut a[lo..hi] { body }` where the body only updates `x`. -/
def mapRangeM {n : Nat} (a : Vector α n) (lo hi : usize) (f : α → M α) : M (Vector α n) :=
  if lo.val ≤ hi.val ∧ hi.val ≤ n then
    (Vector.ofFn fun i : Fin n => if lo.val ≤ i.val ∧ i.val < hi.val then f a[i] else pure a[i]).mapM id
  else fail "range out of bounds"
def mapRangeMA (a : Array α) (lo hi : usize) (f : α → M α) : M (Array α) :=
  if lo.val ≤ hi.val ∧ hi.val ≤ a.size then
    (Array.ofFn fun i : Fin a.size => if lo.val ≤ i.val ∧ i.val < hi.val then f a[i] else pure a[i]).mapM id
  else fail "range out of bounds"

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

/-! ## Lemmas

Each checked operation equals `pure` of its mathematical result under the
condition that rules out its panic. Use them with `simp (disch := omega)`.
-/

section Lemmas
variable {n k : Nat} {α : Type}

@[simp] theorem add_ok (a b : Fin (2 ^ n)) (h : a.val + b.val < 2 ^ n) :
    add a b = pure ⟨a.val + b.val, h⟩ := by simp [add, h]
@[simp] theorem sub_ok (a b : Fin (2 ^ n)) (h : b.val ≤ a.val) :
    sub a b = pure ⟨a.val - b.val, by omega⟩ := by simp [sub, h]
@[simp] theorem mul_ok (a b : Fin (2 ^ n)) (h : a.val * b.val < 2 ^ n) :
    mul a b = pure ⟨a.val * b.val, h⟩ := by simp [mul, h]
@[simp] theorem div_ok (a b : Fin (2 ^ n)) (h : b.val ≠ 0) :
    div a b = pure ⟨a.val / b.val, Nat.lt_of_le_of_lt (Nat.div_le_self _ _) a.isLt⟩ := by simp [div, h]
@[simp] theorem rem_ok (a b : Fin (2 ^ n)) (h : b.val ≠ 0) :
    rem a b = pure ⟨a.val % b.val, Nat.lt_of_le_of_lt (Nat.mod_le _ _) a.isLt⟩ := by simp [rem, h]
@[simp] theorem shr_ok (a : Fin (2 ^ n)) (s : Fin (2 ^ k)) (h : s.val < n) :
    shr a s = pure ⟨a.val >>> s.val, Nat.lt_of_le_of_lt (Nat.shiftRight_le _ _) a.isLt⟩ := by
  simp [shr, h]
@[simp] theorem clamp_ok (x lo hi : Fin (2 ^ n)) (h : lo.val ≤ hi.val) :
    clamp x lo hi = pure (Rust.min (Rust.max x lo) hi) := by simp [clamp, h]

@[simp] theorem Slice.index_ok {m : Nat} (a : Vector α m) (i : usize) (h : i.val < m) :
    Slice.index a i = pure a[i.val] := by simp [Slice.index, h]
@[simp] theorem Slice.set_ok {m : Nat} (a : Vector α m) (i : usize) (v : α) (h : i.val < m) :
    Slice.set a i v = pure (a.set i.val v) := by simp [Slice.set, h]

@[simp] theorem val_usizeOf (m : Nat) (h : m < 2 ^ 64) : (usizeOf m).val = m := by
  simp [usizeOf, ofNat, Nat.mod_eq_of_lt h]
@[simp] theorem val_umax : (umax n).val = 2 ^ n - 1 := rfl
@[simp] theorem val_wrapping_add (a b : Fin (2 ^ n)) : (wrapping_add a b).val = (a.val + b.val) % 2 ^ n := rfl
@[simp] theorem val_saturating_sub (a b : Fin (2 ^ n)) : (saturating_sub a b).val = a.val - b.val := rfl
theorem val_saturating_add (a b : Fin (2 ^ n)) :
    (saturating_add a b).val = Nat.min (a.val + b.val) (2 ^ n - 1) := by
  unfold saturating_add; split <;> simp [umax, Nat.min_def] <;> omega
@[simp] theorem val_min (a b : Fin (2 ^ n)) : (Rust.min a b).val = Nat.min a.val b.val := by
  unfold Rust.min; split <;> simp [Nat.min_def] <;> omega
@[simp] theorem val_max (a b : Fin (2 ^ n)) : (Rust.max a b).val = Nat.max a.val b.val := by
  unfold Rust.max; split <;> simp [Nat.max_def] <;> omega
@[simp] theorem checked_add_eq (a b : Fin (2 ^ n)) :
    checked_add a b = if h : a.val + b.val < 2 ^ n then some ⟨a.val + b.val, h⟩ else none := rfl
@[simp] theorem checked_sub_eq (a b : Fin (2 ^ n)) :
    checked_sub a b = if h : b.val ≤ a.val then some ⟨a.val - b.val, by omega⟩ else none := rfl

@[simp] theorem Option.is_some_and_some (a : α) (f : α → Bool) : Option.is_some_and (some a) f = f a := rfl
@[simp] theorem Option.is_some_and_none (f : α → Bool) : Option.is_some_and (none : Option α) f = false := rfl
@[simp] theorem Option.is_none_or_some (a : α) (f : α → Bool) : Option.is_none_or (some a) f = f a := rfl
@[simp] theorem Option.is_none_or_none (f : α → Bool) : Option.is_none_or (none : Option α) f = true := rfl
@[simp] theorem Option.map_or_some {β : Type} (a : α) (d : β) (f : α → β) : Option.map_or (some a) d f = f a := rfl
@[simp] theorem Option.map_or_none {β : Type} (d : β) (f : α → β) : Option.map_or (none : Option α) d f = d := rfl
@[simp] theorem Option.then_some_true (a : α) : Option.then_some true a = some a := rfl
@[simp] theorem Option.then_some_false (a : α) : Option.then_some false a = none := rfl

@[simp] theorem Slice.range_ok {m : Nat} (a : Vector α m) (lo hi : usize) (h : lo.val ≤ hi.val ∧ hi.val ≤ m) :
    Slice.range a lo hi = pure (a.toArray.extract lo.val hi.val) := by simp [Slice.range, h]
@[simp] theorem Slice.rotate_left_ok (a : Array α) (k : usize) (h : k.val ≤ a.size) :
    Slice.rotate_left a k = pure (a.extract k.val a.size ++ a.extract 0 k.val) := by
  simp [Slice.rotate_left, h]
@[simp] theorem Slice.len_eq {m : Nat} (a : Vector α m) : Slice.len a = usizeOf m := rfl

theorem Slice.mapRangeM_pure {m : Nat} (a : Vector α m) (lo hi : usize) (g : α → α)
    (h : lo.val ≤ hi.val ∧ hi.val ≤ m) :
    Slice.mapRangeM a lo hi (fun e => pure (g e)) =
      pure (Vector.ofFn fun i : Fin m => if lo.val ≤ i.val ∧ i.val < hi.val then g a[i] else a[i]) := by
  unfold Slice.mapRangeM
  rw [if_pos h]
  have : (Vector.ofFn fun i : Fin m =>
      if lo.val ≤ i.val ∧ i.val < hi.val then (pure (g a[i]) : M α) else pure a[i]) =
      (Vector.ofFn fun i : Fin m => if lo.val ≤ i.val ∧ i.val < hi.val then g a[i] else a[i]).map pure := by
    rw [Vector.map_ofFn]; congr 1; funext i; simp only [Function.comp]; split <;> rfl
  rw [this, Vector.mapM_map]
  have := Vector.mapM_pure (m := M) (xs := Vector.ofFn fun i : Fin m =>
    if lo.val ≤ i.val ∧ i.val < hi.val then g a[i] else a[i]) id
  rw [Vector.map_id] at this
  simpa only [Function.comp_def, id] using this

theorem filterAuxM_pure {β : Type} (l acc : List β) (p : β → M Bool) (q : β → Bool)
    (h : ∀ x ∈ l, p x = pure (q x)) : List.filterAuxM p l acc = pure ((l.filter q).reverse ++ acc) := by
  induction l generalizing acc with
  | nil => simp [List.filterAuxM]
  | cons x xs ih =>
    simp only [List.filterAuxM, h x (by simp), pure_bind]
    rw [ih _ (fun y hy => h y (by simp [hy]))]
    cases hq : q x <;> simp [hq]

/-- `filterM` with a predicate that cannot fail is `filter`. -/
theorem filterM_pure {β : Type} (l : List β) (p : β → M Bool) (q : β → Bool)
    (h : ∀ x ∈ l, p x = pure (q x)) : l.filterM p = pure (l.filter q) := by
  simp [List.filterM, filterAuxM_pure l [] p q h]

/-- A `for` loop over a list whose body always continues, with an invariant
indexed by the number of items processed. -/
theorem forIn_inv {β γ : Type} (l : List γ) (init : β) (f : γ → β → M (ForInStep β))
    (I : Nat → β → Prop) (h0 : I 0 init)
    (hstep : ∀ k (hk : k < l.length) b, I k b → ∃ b', f l[k] b = pure (.yield b') ∧ I (k + 1) b') :
    ∃ b, forIn l init f = pure b ∧ I l.length b := by
  induction l generalizing init I with
  | nil => exact ⟨init, rfl, h0⟩
  | cons x xs ih =>
    obtain ⟨b1, hb1, hi1⟩ := hstep 0 (by simp) init h0
    obtain ⟨b, hb, hi⟩ := ih b1 (fun k => I (k + 1)) hi1
      (fun k hk b hb => by
        have := hstep (k + 1) (by simp; omega) b hb
        simpa only [List.getElem_cons_succ] using this)
    refine ⟨b, ?_, by simpa using hi⟩
    rw [List.forIn_cons]; simp only [List.getElem_cons_zero] at hb1; rw [hb1]; simpa using hb

/-- `forIn_inv` in a form `apply` can match against a loop followed by more code. -/
theorem forIn_bind_inv {β γ δ : Type} (l : List γ) (init : β) (f : γ → β → M (ForInStep β))
    (k : β → M δ) (R : M δ) (I : Nat → β → Prop) (h0 : I 0 init)
    (hstep : ∀ i (hi : i < l.length) b, I i b → ∃ b', f l[i] b = pure (.yield b') ∧ I (i + 1) b')
    (hk : ∀ b, I l.length b → k b = R) : (forIn l init f >>= k) = R := by
  obtain ⟨b, hb, hI⟩ := forIn_inv l init f I h0 hstep
  rw [hb, pure_bind, hk b hI]

/-- `forIn_inv` for a loop that ends the computation. -/
theorem forIn_eq_inv {β γ : Type} (l : List γ) (init : β) (f : γ → β → M (ForInStep β)) (R : β)
    (I : Nat → β → Prop) (h0 : I 0 init)
    (hstep : ∀ i (hi : i < l.length) b, I i b → ∃ b', f l[i] b = pure (.yield b') ∧ I (i + 1) b')
    (hfin : ∀ b, I l.length b → b = R) : forIn l init f = pure R := by
  obtain ⟨b, hb, hI⟩ := forIn_inv l init f I h0 hstep
  rw [hb, hfin b hI]

/-! Loops (`while`, `loop`) unfold one iteration at a time. -/

theorem loop_yield {β : Type} {f : Unit → β → M (ForInStep β)} {b b' : β}
    (h : f () b = pure (.yield b')) : forIn Lean.Loop.mk b f = forIn Lean.Loop.mk b' f := by
  show Lean.Loop.forIn _ b f = Lean.Loop.forIn _ b' f
  rw [Lean.Loop.forIn_eq_of_monadTail, h]; simp

theorem loop_done {β : Type} {f : Unit → β → M (ForInStep β)} {b b' : β}
    (h : f () b = pure (.done b')) : forIn Lean.Loop.mk b f = pure b' := by
  show Lean.Loop.forIn _ b f = _
  rw [Lean.Loop.forIn_eq_of_monadTail, h]; simp

end Lemmas

/-! ## Traits

`Clone` translates to the identity: values have no identity in Lean, and
application `Clone` implementations are assumed to return an equal value
without panicking. Derived `PartialEq` translates to Lean's decidable equality.
-/

end Rust
