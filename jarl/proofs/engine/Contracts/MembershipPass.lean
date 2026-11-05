import Contracts.MembershipInclude

/-!
# Membership contracts: insertion passes

`restore`, `with_learners` and `joint` each run loops of `include` with early
`return Err(..)`. `pass` is the pure meaning of one such loop; the lemmas here
connect the translated `for` loops to it and characterize its outcome.
-/

namespace Jarl.Contracts.Membership
open Jarl

variable {MAX : Nat}

/-- One loop step: the input check (`seen` is the prefix already visited), then `include`. -/
def stepOk (dup : Bool) (extra : Id → Bool) (k : Rust.u8) (seen : List Id) (x : Id) (m : Jarl.Membership MAX) :
    Option (Jarl.Membership MAX) :=
  if ((dup && seen.contains x) || extra x) = true then none else incSpec m x k

/-- The pure meaning of an insertion loop; `.error m` is an early return at state `m`. -/
def pass (dup : Bool) (extra : Id → Bool) (k : Rust.u8) :
    List Id → List Id → Jarl.Membership MAX → Except (Jarl.Membership MAX) (Jarl.Membership MAX)
  | _, [], m => .ok m
  | seen, x :: xs, m =>
    match stepOk dup extra k seen x m with
    | none => .error m
    | some m' => pass dup extra k (seen ++ [x]) xs m'

/-- The loop state a translated insertion loop ends in. -/
def out {ρ : Type} (e : ρ) (r : Except (Jarl.Membership MAX) (Jarl.Membership MAX)) :
    Option ρ × Jarl.Membership MAX :=
  match r with
  | .ok m => (none, m)
  | .error m => (some e, m)

/-- An insertion loop over `enumerate(set)` is `pass`. -/
theorem forIn_enum {ρ : Type} (set : List Id) (dup : Bool) (extra : Id → Bool)
    (k : Rust.u8) (e : ρ)
    (f : Rust.usize × Id → Option ρ × Jarl.Membership MAX → Rust.M (ForInStep (Option ρ × Jarl.Membership MAX)))
    (hf : ∀ (j : Nat) (hj : j < set.length) (m : Jarl.Membership MAX), f (Rust.ofNat j, set[j]) (none, m) =
      pure (match stepOk dup extra k (set.take j) set[j] m with
        | some m' => .yield (none, m')
        | none => .done (some e, m)))
    (m : Jarl.Membership MAX) :
    forIn (Rust.Iter.enumerate set) (none, m) f = pure (out e (pass dup extra k [] set m)) := by
  have gen : ∀ (xs : List Id) (n : Nat) (m : Jarl.Membership MAX), n + xs.length = set.length → set.drop n = xs →
      forIn ((xs.zipIdx n).map (fun (a, i) => ((Rust.ofNat i : Rust.usize), a))) (none, m) f =
        pure (out e (pass dup extra k (set.take n) xs m)) := by
    intro xs
    induction xs with
    | nil => intro n m _ _; rfl
    | cons x xs ih =>
      intro n m hlen hdrop
      have hn : n < set.length := by simp at hlen; omega
      have hx : set[n] = x := by
        have := congrArg List.head? hdrop
        rw [List.head?_drop, List.getElem?_eq_getElem hn] at this
        simpa using this
      rw [List.zipIdx_cons, List.map_cons, List.forIn_cons]
      have hfn := hf n hn m
      rw [hx] at hfn
      simp only [hfn, pure_bind, pass]
      cases stepOk dup extra k (set.take n) x m with
      | none => rfl
      | some m' =>
        simp only
        have htake : set.take n ++ [x] = set.take (n + 1) := by
          rw [List.take_add_one, List.getElem?_eq_getElem hn, hx]; rfl
        rw [htake]
        apply ih (n + 1) m'
        · simp at hlen; omega
        · rw [← List.drop_drop, hdrop]; rfl
  have := gen set 0 m (by simp) rfl
  simpa [Rust.Iter.enumerate] using this

/-- An insertion loop over a plain list with no input check is `pass`. -/
theorem forIn_list {ρ : Type} (l : List Id) (k : Rust.u8) (e : ρ)
    (f : Id → Option ρ × Jarl.Membership MAX → Rust.M (ForInStep (Option ρ × Jarl.Membership MAX)))
    (hf : ∀ x ∈ l, ∀ m : Jarl.Membership MAX, f x (none, m) =
      pure (match incSpec m x k with
        | some m' => .yield (none, m')
        | none => .done (some e, m)))
    (seen : List Id) (m : Jarl.Membership MAX) :
    forIn l (none, m) f = pure (out e (pass false (fun _ => false) k seen l m)) := by
  induction l generalizing seen m with
  | nil => rfl
  | cons x xs ih =>
    rw [List.forIn_cons, hf x (by simp) m]
    simp only [pure_bind, pass, stepOk, Bool.false_and, Bool.or_false, Bool.false_eq_true, if_false]
    cases incSpec m x k with
    | none => rfl
    | some m' =>
      simp only
      exact ih (fun y hy => hf y (by simp [hy])) _ _

/-! ## What a pass establishes -/

/-- The input checks a successful pass has passed. -/
def Valid (dup : Bool) (extra : Id → Bool) : List Id → List Id → Prop
  | _, [] => True
  | seen, x :: xs => ((dup && seen.contains x) || extra x) = false ∧ Valid dup extra (seen ++ [x]) xs

theorem valid_iff (dup : Bool) (extra : Id → Bool) (seen l : List Id) :
    Valid dup extra seen l ↔ (dup = true → l.Nodup ∧ ∀ x ∈ l, x ∉ seen) ∧ ∀ x ∈ l, extra x = false := by
  induction l generalizing seen with
  | nil => simp [Valid]
  | cons x xs ih =>
    have hc : ((dup && seen.contains x) || extra x) = false ↔ (dup = true → x ∉ seen) ∧ extra x = false := by
      cases dup <;> cases extra x <;> simp
    simp only [Valid, ih, hc]
    constructor
    · rintro ⟨⟨c1, c2⟩, v1, v2⟩
      refine ⟨fun hd => ⟨List.nodup_cons.mpr ⟨fun hx => ((v1 hd).2 x hx) (by simp), (v1 hd).1⟩, ?_⟩, ?_⟩
      · intro y hy
        rcases List.mem_cons.mp hy with rfl | hy
        · exact c1 hd
        · exact fun hs => (v1 hd).2 y hy (List.mem_append_left _ hs)
      · intro y hy
        rcases List.mem_cons.mp hy with rfl | hy
        · exact c2
        · exact v2 y hy
    · rintro ⟨d, e⟩
      refine ⟨⟨fun hd => (d hd).2 x (by simp), e x (by simp)⟩, fun hd => ⟨(List.nodup_cons.mp (d hd).1).2, ?_⟩,
        fun y hy => e y (List.mem_cons_of_mem _ hy)⟩
      intro y hy hs
      rcases List.mem_append.mp hs with hs | hs
      · exact (d hd).2 y (List.mem_cons_of_mem _ hy) hs
      · rw [List.mem_singleton] at hs
        subst hs
        exact (List.nodup_cons.mp (d hd).1).1 hy

theorem pass_valid (dup : Bool) (extra : Id → Bool) (k : Rust.u8) (seen l : List Id) (m r : Jarl.Membership MAX)
    (h : pass dup extra k seen l m = .ok r) : Valid dup extra seen l := by
  induction l generalizing seen m with
  | nil => trivial
  | cons x xs ih =>
    simp only [pass] at h
    unfold stepOk at h
    by_cases c : ((dup && seen.contains x) || extra x) = true
    · simp only [c, if_true] at h; cases h
    · simp only [c] at h
      refine ⟨by simpa using c, ?_⟩
      cases hm : incSpec m x k with
      | none => rw [hm] at h; cases h
      | some m' => rw [hm] at h; exact ih _ _ h

/-- A property observed through every successful `include` step is observed through the pass. -/
theorem pass_observe (dup : Bool) (extra : Id → Bool) (k : Rust.u8) (Φ : Jarl.Membership MAX → Prop)
    (R : Id → Prop) (step : ∀ m m' x, incSpec m x k = some m' → (Φ m' ↔ Φ m ∨ R x))
    (seen l : List Id) (m r : Jarl.Membership MAX) (h : pass dup extra k seen l m = .ok r) :
    Φ r ↔ Φ m ∨ ∃ x ∈ l, R x := by
  induction l generalizing seen m with
  | nil => simp only [pass] at h; cases h; simp
  | cons x xs ih =>
    simp only [pass] at h
    unfold stepOk at h
    by_cases c : ((dup && seen.contains x) || extra x) = true
    · simp only [c, if_true] at h; cases h
    · simp only [c] at h
      cases hm : incSpec m x k with
      | none => rw [hm] at h; cases h
      | some m' =>
        rw [hm] at h
        rw [ih _ _ h, step m m' x hm]
        simp only [List.mem_cons, exists_eq_or_imp]
        constructor
        · rintro ((h1 | h1) | h1)
          · exact Or.inl h1
          · exact Or.inr (Or.inl h1)
          · exact Or.inr (Or.inr h1)
        · rintro (h1 | h1 | h1)
          · exact Or.inl (Or.inl h1)
          · exact Or.inl (Or.inr h1)
          · exact Or.inr h1

theorem pass_preserves (dup : Bool) (extra : Id → Bool) (k : Rust.u8) (I : Jarl.Membership MAX → Prop)
    (step : ∀ m m' x, I m → incSpec m x k = some m' → I m')
    (seen l : List Id) (m r : Jarl.Membership MAX) (h : pass dup extra k seen l m = .ok r) (hm : I m) : I r := by
  induction l generalizing seen m with
  | nil => simp only [pass] at h; cases h; exact hm
  | cons x xs ih =>
    simp only [pass] at h
    unfold stepOk at h
    by_cases c : ((dup && seen.contains x) || extra x) = true
    · simp only [c, if_true] at h; cases h
    · simp only [c] at h
      cases hx : incSpec m x k with
      | none => rw [hx] at h; cases h
      | some m' => rw [hx] at h; exact ih _ _ h (step m m' x hm hx)

theorem pass_flags (F : Flag) (dup : Bool) (extra : Id → Bool) (k : Rust.u8) (seen l : List Id)
    (m r : Jarl.Membership MAX) (h : pass dup extra k seen l m = .ok r) (q : Id) :
    FlagMember F r q ↔ FlagMember F m q ∨ (q ∈ l ∧ F = Flag.ofKind k) := by
  rw [pass_observe dup extra k (fun m => FlagMember F m q) (fun x => x = q ∧ F = Flag.ofKind k)
    (fun m m' x hx => include_flag F m m' q x k hx) seen l m r h]
  constructor
  · rintro (h1 | ⟨x, hx, rfl, h2⟩)
    · exact Or.inl h1
    · exact Or.inr ⟨hx, h2⟩
  · rintro (h1 | ⟨hx, h2⟩)
    · exact Or.inl h1
    · exact Or.inr ⟨q, hx, rfl, h2⟩

theorem pass_identities (dup : Bool) (extra : Id → Bool) (k : Rust.u8) (seen l : List Id)
    (m r : Jarl.Membership MAX) (h : pass dup extra k seen l m = .ok r) (q : Id) :
    HasIdentity r q ↔ HasIdentity m q ∨ q ∈ l := by
  rw [pass_observe dup extra k (fun m => HasIdentity m q) (fun x => x = q)
    (fun m m' x hx => include_identity m m' q x k hx) seen l m r h]
  simp

theorem pass_unique (dup : Bool) (extra : Id → Bool) (k : Rust.u8) (seen l : List Id)
    (m r : Jarl.Membership MAX) (h : pass dup extra k seen l m = .ok r) (hm : UniqueIdentities m) :
    UniqueIdentities r :=
  pass_preserves dup extra k UniqueIdentities (fun m m' x hu hx => include_unique m m' x k hx hu) seen l m r h hm

/-- A pass whose input checks succeed and whose identities fit a cover of size
    at most `MAX` succeeds. -/
theorem pass_accepts (dup : Bool) (extra : Id → Bool) (k : Rust.u8) (D : List Id) (fits : D.length ≤ MAX)
    (seen l : List Id) (valid : Valid dup extra seen l) (admitted : ∀ x ∈ l, x ∈ D)
    (m : Jarl.Membership MAX) (unique : UniqueIdentities m) (covered : ∀ q, HasIdentity m q → q ∈ D) :
    ∃ r, pass dup extra k seen l m = .ok r := by
  induction l generalizing seen m with
  | nil => exact ⟨m, rfl⟩
  | cons x xs ih =>
    obtain ⟨c, vrest⟩ := valid
    obtain ⟨m', hm'⟩ := include_available m D fits unique covered x (admitted x (by simp)) k
    simp only [pass, stepOk, c, Bool.false_eq_true, if_false, hm']
    refine ih _ vrest (fun y hy => admitted y (by simp [hy])) m' (include_unique m m' x k hm' unique) ?_
    intro q hq
    rcases (include_identity m m' q x k hm').mp hq with h1 | rfl
    · exact covered q h1
    · exact admitted _ (by simp)

/-! ## Cover counting -/

/-- Specification-only enumeration of a list's distinct elements. -/
def uniqueKeys : List Id → List Id
  | [] => []
  | key :: rest => if key ∈ uniqueKeys rest then uniqueKeys rest else key :: uniqueKeys rest

theorem uniqueKeys_member (keys : List Id) (q : Id) : q ∈ uniqueKeys keys ↔ q ∈ keys := by
  induction keys with
  | nil => rfl
  | cons key rest ih =>
    by_cases present : key ∈ uniqueKeys rest
    · rw [uniqueKeys, if_pos present, ih]
      constructor
      · exact List.mem_cons_of_mem _
      · intro member
        rcases List.mem_cons.mp member with rfl | member
        · exact ih.mp present
        · exact member
    · simp only [uniqueKeys, if_neg present, List.mem_cons, ih]

theorem uniqueKeys_nodup (keys : List Id) : (uniqueKeys keys).Nodup := by
  induction keys with
  | nil => simp [uniqueKeys]
  | cons key rest ih =>
    by_cases present : key ∈ uniqueKeys rest
    · simpa only [uniqueKeys, if_pos present] using ih
    · simpa only [uniqueKeys, if_neg present, List.nodup_cons] using And.intro present ih

/-- A finite cover of size at most `capacity` for the identities in `keys`. -/
def Fits (capacity : Nat) (keys : List Id) : Prop :=
  ∃ D : List Id, D.length ≤ capacity ∧ ∀ q ∈ keys, q ∈ D

theorem fits_iff_count (capacity : Nat) (keys : List Id) :
    Fits capacity keys ↔ (uniqueKeys keys).length ≤ capacity := by
  constructor
  · rintro ⟨D, bound, covers⟩
    have subset : uniqueKeys keys ⊆ D := fun q hq => covers q ((uniqueKeys_member _ q).mp hq)
    exact Nat.le_trans ((uniqueKeys_nodup _).length_le_of_subset subset) bound
  · intro bound
    exact ⟨uniqueKeys keys, bound, fun q hq => (uniqueKeys_member _ q).mpr hq⟩

/-- The stored identities of a configuration are a cover of size at most `MAX`. -/
theorem keys_fit (m : Jarl.Membership MAX) (keys : List Id) (covered : ∀ q ∈ keys, HasIdentity m q) :
    Fits MAX keys :=
  ⟨Keys m, keys_length m, fun q hq => (keys_member m q).mpr (covered q hq)⟩

/-- The empty configuration. -/
def empty (MAX : Nat) : Jarl.Membership MAX := ⟨Vector.replicate MAX none⟩

theorem empty_unique : UniqueIdentities (empty MAX) := by
  simp [UniqueIdentities, Keys, occ, empty, Rust.Iter.flatten]

theorem empty_no_identity (q : Id) : ¬HasIdentity (empty MAX) q := by
  rintro ⟨s, hs, _⟩
  simp [empty] at hs

theorem empty_no_flag (F : Flag) (q : Id) : ¬FlagMember F (empty MAX) q := by
  rintro ⟨s, hs, _⟩
  simp [empty] at hs

/-- `Keys` of a unique configuration counts exactly its distinct identities. -/
theorem keys_count (m : Jarl.Membership MAX) (unique : UniqueIdentities m) (keys : List Id)
    (same : ∀ q, HasIdentity m q ↔ q ∈ keys) : (Keys m).length = (uniqueKeys keys).length := by
  have membership : ∀ q, q ∈ Keys m ↔ q ∈ uniqueKeys keys := by
    intro q; rw [keys_member, same, uniqueKeys_member]
  apply Nat.le_antisymm
  · exact unique.length_le_of_subset (fun q hq => (membership q).mp hq)
  · exact (uniqueKeys_nodup _).length_le_of_subset (fun q hq => (membership q).mpr hq)

end Jarl.Contracts.Membership
