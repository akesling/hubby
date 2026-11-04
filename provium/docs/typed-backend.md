# Typed backend: Rust to typed, shallow Lean

Provium's typed backend compiles Rust items to ordinary Lean definitions:
structs become `structure`s, enums `inductive`s, and functions `def`s in a
result monad. Consumers prove theorems about those definitions with standard
Lean tactics. Nothing here is specific to any consuming crate.

Select it with `"kind": "typed"` in a project file; `assert_proofs!` and
`provium verify-typed <project.json> --out <dir>` verify such projects.
`examples/typed` is a complete small example.

## Why

The earlier backends translate Rust into a deep embedding: an `Expr` tree run
by an interpreter over untyped values. Proofs over it restate what the type
checker already knows (record layouts, enum payloads, integer kinds), walk the
interpreter construct by construct, and pay for it in time and memory. Over a
shallow, typed translation the same facts are Lean's own: `n.state.hard.term`
is a field access, and `simp [Node.step]` unfolds the code.

## Pipeline

```text
Cargo build (captured) ──► cfg, overflow checks, debug assertions
crate sources (syn) ──► name resolution ──► typed translation ──► Generated.lean
                                                                    ▲
consumer proofs, proof modules ─────────────────────────────────────┘
differential scenario ──► native run (Cargo) ══ Lean #eval ──► must agree
```

1. **Front end.** Sources are parsed with `syn`, following `mod` declarations
   with conditional compilation decided by the captured build's
   `rustc --print cfg`. Paths resolve through each module's items and `use`
   declarations (including re-exports); a name that does not resolve is an
   error. Types of locals are inferred from annotations, field and signature
   types, and the operations applied to them; Lean's elaborator then checks
   every generated definition again.
2. **Types.**

   | Rust | Lean |
   | --- | --- |
   | `struct` | `structure`, fields in order (tuple fields `f0`, `f1`, ...) |
   | `enum` | `inductive`, one constructor per variant |
   | `u8` ... `u64`, `usize` | `Rust.u8` ... (`Fin (2 ^ bits)`); 64-bit targets only |
   | `i8` ... `i64` | `Rust.IntN bits` |
   | `[T; N]` | `Vector T N`; const generics are `Nat` parameters |
   | `&[T]` | `Array T` |
   | `Option`, `Result` | `Option`, `Rust.Result` |
   | iterators | `List` of the items they yield |
   | closures, `fn` pointers, `impl Fn` | `A → Rust.M B` (pure closures stay pure) |
   | `&T`, `&mut T` | `T` (see borrows) |

   Derived `PartialEq` becomes `DecidableEq`; derived `Default` a `default`
   definition.
3. **Functions.** A function that cannot panic or diverge is a pure `def`.
   Otherwise it returns `Rust.M α := ExceptT Rust.Panic Option α`: a panic
   is `throw`, divergence is `none`. Purity is computed as a fixed point over
   the call graph. Bodies become `do` blocks that follow the Rust source
   statement by statement: `let mut`, `for`, `while` (via Lean's `MonadTail`
   loops, so no fuel appears), `return`, `break`, `continue`, `?`, `match`
   with guards and or-patterns, and `if let`/`while let`/`let ... else`.
4. **Borrows.** A function returns the final values of its `&mut`
   parameters alongside its result. A local `&mut` borrow (`let x = &mut p`,
   `for x in &mut a`, `if let Some(x) = slot` on a `&mut` scrutinee,
   `get_or_insert`, struct literals holding `&mut` fields) is a local copy
   plus the place it borrows; every write to the copy is written through to the
   place at once. The borrow checker guarantees the place is not otherwise used
   while the borrow lives, so eager write-through is exact. `Drop`
   implementations run at scope exits, early returns and `drop(x)`.
   A function returning a struct that borrows its `&mut` receiver (such as
   `Node::ready`) leaves the receiver to the struct, whose binding writes
   through. Functions returning `&mut T` are rejected.
5. **Core library.** `provium/lean/Provium/Rust.lean` defines every
   operation the translation uses: checked and wrapping arithmetic under the
   build's overflow-check setting, slices and arrays, `Option`/`Result`
   combinators, and iterator adaptors. An iterator pipeline may contain at
   most one stage whose closure can panic, and that stage may not be followed
   by a short-circuiting stage; this keeps eager list evaluation equal to
   Rust's lazy evaluation.

## Evidence and trust

- **Kernel checking.** Generated code, consumer proofs and proof modules are
  checked by the pinned Lean with `--trust=0`; each obligation's theorem must
  mention its generated function and use only `propext`, `Quot.sound` and
  `Classical.choice`.
- **Source binding.** The manifest records hashes of every source, the
  captured build and every artifact; sources are rechecked after verification.
- **Differential testing.** A project may name a scenario module written
  against the crate's public API (`use <crate>::...`) exporting
  `pub fn run(seed: u64) -> u64`. Provium translates it with the crate, runs
  it natively through Cargo with the same overflow-check setting and in Lean
  with `#eval`, and requires identical results (or identical panics) for every
  seed. A deliberately wrong `wrapping_mul` in `Rust.lean` is caught by
  Jarl's scenario; a wrong `saturating_sub` is not, because the scenario never
  reaches it. Differential tests support, but do not replace, a proof of
  source correspondence.
- **Trusted.** The `syn` front end's name resolution and type inference, the
  interpretation of each core-library operation in `Rust.lean`, and these
  modelling assumptions: application `Clone` returns an equal value without
  panicking; a panic ends the execution (no unwinding observed); a failed
  `const` assertion, which rustc would reject at compile time, is a panic.

## Alternatives considered

- **Compiler MIR** (via Charon's LLBC or a `rustc_public` driver) would make
  rustc the front end, removing name resolution and type inference from the
  trusted base, but needs a pinned nightly toolchain and either a third-party
  extractor or a reimplementation of control-flow reconstruction. Its output
  is also further from the source: iterators become `next()` loops and control
  flow becomes basic blocks. It remains the route to closing the front-end trust
  gap (CORRECTNESS_PLAN P10).
- **The deep embedding** stays available for existing projects. New proof
  work should use the typed backend.

## Status

Implemented: everything above. Jarl's fixed `Node` engine (`node.rs`,
`state.rs`, `membership.rs`, `ready.rs`) translates completely
(`jarl/proofs/engine`).
