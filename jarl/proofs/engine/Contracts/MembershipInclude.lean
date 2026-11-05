import Contracts.MembershipBase

/-!
# Membership contracts: `include`

`Membership::include` is translated to a monadic function that, for a slot
array of fewer than `2 ^ usizeBits` entries (`usize` positions), always returns. Its effect
is the pure `incSpec` below: the first slot already holding the identity, else
the first empty slot, gets the requested flag; with neither, it returns
`Err(Config)` and leaves the configuration unchanged.
-/

namespace Jarl.Contracts.Membership
open Jarl

variable {MAX : Nat}

/-- The record `include` creates in an empty slot. -/
def blank (id : Id) : Member := { id := id, voter := false, old := false, learner := false }

/-- The flag update `include(_, kind)` applies to the selected record. -/
def setFlag (k : Rust.u8) (s : Member) : Member :=
  if k = 0 then { s with voter := true } else if k = 1 then { s with learner := true } else { s with old := true }

/-- The slot `include` selects: the first slot holding `id`, else the first empty slot. -/
def findSlot (l : List (Option Member)) (id : Id) : Option Nat :=
  (l.findIdx? (fun o => Rust.Option.is_some_and o (fun s => s.id == id))).orElse
    (fun _ => l.findIdx? (fun o => o.isNone))

/-- The pure effect of `include`: `none` is the `Err(Config)` outcome. -/
def incSpec (m : Jarl.Membership MAX) (id : Id) (k : Rust.u8) : Option (Jarl.Membership MAX) :=
  match findSlot m.members.toList id with
  | none => none
  | some i => if h : i < MAX then some ⟨m.members.set i (some (setFlag k (m.members[i].getD (blank id)))) h⟩ else none

theorem setFlag_id (k : Rust.u8) (s : Member) : (setFlag k s).id = s.id := by
  unfold setFlag; split
  · rfl
  · split <;> rfl

theorem setFlag_get (F : Flag) (k : Rust.u8) (s : Member) :
    F.get (setFlag k s) = (F.get s || decide (F = Flag.ofKind k)) := by
  unfold setFlag Flag.ofKind
  by_cases h0 : k = 0
  · cases F <;> simp [h0, Flag.get]
  · by_cases h1 : k = 1
    · cases F <;> simp [h1, Flag.get]
    · cases F <;> simp [h0, h1, Flag.get]

theorem blank_get (F : Flag) (id : Id) : F.get (blank id) = false := by cases F <;> rfl

theorem findSlot_some (l : List (Option Member)) (id : Id) (i : Nat) (h : findSlot l id = some i) :
    ∃ hi : i < l.length, (∃ s, l[i] = some s ∧ s.id = id) ∨
      (l[i] = none ∧ ∀ s, some s ∈ l → s.id ≠ id) := by
  unfold findSlot at h
  cases h1 : l.findIdx? (fun o => Rust.Option.is_some_and o (fun s => s.id == id)) with
  | some j =>
    rw [h1] at h
    cases h
    obtain ⟨hj, hp, _⟩ := List.findIdx?_eq_some_iff_getElem.mp h1
    refine ⟨hj, Or.inl ?_⟩
    cases hl : l[i] with
    | none => rw [hl] at hp; cases hp
    | some s =>
      rw [hl] at hp
      exact ⟨s, rfl, by simpa using hp⟩
  | none =>
    rw [h1] at h
    simp only [Option.orElse] at h
    obtain ⟨hj, hp, _⟩ := List.findIdx?_eq_some_iff_getElem.mp h
    refine ⟨hj, Or.inr ⟨by simpa using hp, ?_⟩⟩
    intro s hs heq
    have := List.findIdx?_eq_none_iff.mp h1 (some s) hs
    simp [heq] at this

theorem findSlot_none (l : List (Option Member)) (id : Id) :
    findSlot l id = none ↔ (∀ s, some s ∈ l → s.id ≠ id) ∧ none ∉ l := by
  unfold findSlot
  cases h1 : l.findIdx? (fun o => Rust.Option.is_some_and o (fun s => s.id == id)) with
  | some j =>
    simp only [Option.orElse, reduceCtorEq, false_iff]
    obtain ⟨hj, hp, _⟩ := List.findIdx?_eq_some_iff_getElem.mp h1
    intro ⟨hno, _⟩
    cases hl : l[j] with
    | none => rw [hl] at hp; cases hp
    | some s =>
      rw [hl] at hp
      exact hno s (by rw [← hl]; exact List.getElem_mem hj) (by simpa using hp)
  | none =>
    simp only [Option.orElse, List.findIdx?_eq_none_iff]
    have hno := List.findIdx?_eq_none_iff.mp h1
    constructor
    · intro h
      refine ⟨fun s hs heq => ?_, fun hn => ?_⟩
      · have := hno (some s) hs; simp [heq] at this
      · have := h none hn; simp at this
    · rintro ⟨_, hn⟩ x hx
      cases x with
      | none => exact absurd hx hn
      | some _ => rfl

theorem findSlot_lt (m : Jarl.Membership MAX) (id : Id) (i : Nat) (h : findSlot m.members.toList id = some i) :
    i < MAX := by
  obtain ⟨hi, _⟩ := findSlot_some _ _ _ h
  simpa using hi

private theorem orElse_map {α β : Type} (a b : Option α) (g : α → β) :
    (a.map g).orElse (fun _ => b.map g) = (a.orElse fun _ => b).map g := by
  cases a <;> rfl

/-- `include` always returns, with exactly the effect `incSpec`. -/
theorem include_eq (m : Jarl.Membership MAX) (id : Id) (k : Rust.u8) (hMAX : MAX < 2 ^ Rust.usizeBits) :
    m.include id k = pure (match incSpec m id k with
      | some m' => (.Ok (), m')
      | none => (.Err .Config, m)) := by
  unfold Jarl.Membership.include
  have hpos : ((Rust.Iter.position m.members.toList fun m_1 => Rust.Option.is_some_and m_1 fun m_2 => m_2.id == id).orElse
      fun _ => Rust.Iter.position m.members.toList fun o => o.isNone) = (findSlot m.members.toList id).map Rust.ofNat := by
    simp only [Rust.Iter.position, findSlot, orElse_map]
  dsimp only
  rw [hpos]
  cases hf : findSlot m.members.toList id with
  | none => simp [Rust.Option.ok_or, incSpec, hf]
  | some i =>
    have hi := findSlot_lt m id i hf
    have hv : (Rust.ofNat i : Rust.usize).val = i := by simp [Rust.ofNat] at hMAX ⊢; omega
    have hlt : (Rust.ofNat i : Rust.usize).val < MAX := by omega
    simp only [Option.map_some, Rust.Option.ok_or, pure_bind, Rust.Slice.index_ok _ _ hlt,
      Rust.Slice.set_ok _ _ _ hlt, incSpec, hf, hv, hi, dif_pos]
    unfold setFlag
    by_cases h0 : k = 0
    · subst h0; simp [Vector.set_set, blank]
    · by_cases h1 : k = 1
      · subst h1; simp [Vector.set_set, blank]
      · have h0' : (k == 0) = false := by simpa using h0
        have h1' : (k == 1) = false := by simpa using h1
        simp [h0, h1, h0', h1', Vector.set_set, blank]

/-! ## The list-level effect of one successful `include` -/

/-- Decomposition of a successful `include`. -/
theorem incSpec_some (m m' : Jarl.Membership MAX) (id : Id) (k : Rust.u8) (h : incSpec m id k = some m') :
    ∃ i, ∃ hi : i < MAX, findSlot m.members.toList id = some i ∧
      ((∃ s, m.members[i] = some s ∧ s.id = id) ∨
        (m.members[i] = none ∧ ∀ s, some s ∈ m.members.toList → s.id ≠ id)) ∧
      m' = ⟨m.members.set i (some (setFlag k (m.members[i].getD (blank id)))) hi⟩ := by
  unfold incSpec at h
  cases hf : findSlot m.members.toList id with
  | none => rw [hf] at h; cases h
  | some i =>
    rw [hf] at h
    have hi := findSlot_lt m id i hf
    dsimp only at h
    rw [dif_pos hi] at h
    cases h
    obtain ⟨_, hc⟩ := findSlot_some _ _ _ hf
    simp only [Vector.getElem_toList] at hc
    exact ⟨i, hi, rfl, hc, rfl⟩

theorem incSpec_none (m : Jarl.Membership MAX) (id : Id) (k : Rust.u8) :
    incSpec m id k = none ↔ findSlot m.members.toList id = none := by
  unfold incSpec
  cases hf : findSlot m.members.toList id with
  | none => simp
  | some i => simp [findSlot_lt m id i hf]

private theorem exists_set_iff (L : List (Option Member)) (i : Nat) (hi : i < L.length) (a : Member)
    (P : Member → Prop) :
    (∃ s, some s ∈ L.set i (some a) ∧ P s) ↔
      (∃ j, ∃ hj : j < L.length, j ≠ i ∧ ∃ s, L[j] = some s ∧ P s) ∨ P a := by
  constructor
  · rintro ⟨s, hs, hp⟩
    obtain ⟨j, hj, hjs⟩ := List.mem_iff_getElem.mp hs
    rw [List.getElem_set] at hjs
    by_cases hij : i = j
    · rw [if_pos hij] at hjs; cases hjs; exact Or.inr hp
    · rw [if_neg hij] at hjs
      exact Or.inl ⟨j, by simpa using hj, Ne.symm hij, s, hjs, hp⟩
  · rintro (⟨j, hj, hji, s, hjs, hp⟩ | hp)
    · refine ⟨s, ?_, hp⟩
      apply List.mem_iff_getElem.mpr
      refine ⟨j, by simpa using hj, ?_⟩
      rw [List.getElem_set, if_neg (Ne.symm hji), hjs]
    · exact ⟨a, List.mem_iff_getElem.mpr ⟨i, by simpa using hi, by simp⟩, hp⟩

private theorem exists_iff (L : List (Option Member)) (i : Nat) (hi : i < L.length) (P : Member → Prop) :
    (∃ s, some s ∈ L ∧ P s) ↔
      (∃ j, ∃ hj : j < L.length, j ≠ i ∧ ∃ s, L[j] = some s ∧ P s) ∨ (∃ s, L[i] = some s ∧ P s) := by
  constructor
  · rintro ⟨s, hs, hp⟩
    obtain ⟨j, hj, hjs⟩ := List.mem_iff_getElem.mp hs
    by_cases hij : j = i
    · subst hij; exact Or.inr ⟨s, hjs, hp⟩
    · exact Or.inl ⟨j, hj, hij, s, hjs, hp⟩
  · rintro (⟨j, hj, _, s, hjs, hp⟩ | ⟨s, hs, hp⟩)
    · exact ⟨s, hjs ▸ List.getElem_mem hj, hp⟩
    · exact ⟨s, hs ▸ List.getElem_mem hi, hp⟩

/-- A predicate on the updated slot: it holds of the new record exactly when it
    held of the previous record or of the fresh contribution `fresh`. -/
private theorem include_observe (m m' : Jarl.Membership MAX) (id : Id) (k : Rust.u8)
    (h : incSpec m id k = some m') (P : Member → Prop) (fresh : Prop)
    (hold : ∀ s, s.id = id → (P (setFlag k s) ↔ P s ∨ fresh))
    (hblank : P (setFlag k (blank id)) ↔ fresh) :
    (∃ s, some s ∈ m'.members.toList ∧ P s) ↔ (∃ s, some s ∈ m.members.toList ∧ P s) ∨ fresh := by
  obtain ⟨i, hi, _, hc, rfl⟩ := incSpec_some m m' id k h
  have hl : i < m.members.toList.length := by simpa using hi
  simp only [Vector.toList_set]
  rw [exists_set_iff _ i hl, exists_iff _ i hl]
  simp only [Vector.getElem_toList]
  rcases hc with ⟨s, hs, hsid⟩ | ⟨hs, _⟩
  · rw [hs, Option.getD_some, hold s hsid]
    constructor
    · rintro (h | h | h)
      · exact Or.inl (Or.inl h)
      · exact Or.inl (Or.inr ⟨s, rfl, h⟩)
      · exact Or.inr h
    · rintro ((h | ⟨s', hs', h⟩) | h)
      · exact Or.inl h
      · cases hs'; exact Or.inr (Or.inl h)
      · exact Or.inr (Or.inr h)
  · rw [hs, Option.getD_none, hblank]
    constructor
    · rintro (h | h)
      · exact Or.inl (Or.inl h)
      · exact Or.inr h
    · rintro ((h | ⟨s', hs', _⟩) | h)
      · exact Or.inl h
      · cases hs'
      · exact Or.inr h

theorem include_flag (F : Flag) (m m' : Jarl.Membership MAX) (q id : Id) (k : Rust.u8)
    (h : incSpec m id k = some m') :
    FlagMember F m' q ↔ FlagMember F m q ∨ (id = q ∧ F = Flag.ofKind k) := by
  unfold FlagMember
  refine include_observe m m' id k h (fun s => s.id = q ∧ F.get s = true) _ ?_ ?_
  · intro s hs
    rw [setFlag_id, setFlag_get, hs]
    cases hF : F.get s <;> by_cases e : F = Flag.ofKind k <;> simp [e]
  · rw [setFlag_id, setFlag_get, blank_get]
    simp [blank]

theorem include_identity (m m' : Jarl.Membership MAX) (q id : Id) (k : Rust.u8)
    (h : incSpec m id k = some m') :
    HasIdentity m' q ↔ HasIdentity m q ∨ id = q := by
  unfold HasIdentity
  refine include_observe m m' id k h (fun s => s.id = q) _ ?_ ?_
  · intro s hs
    rw [setFlag_id, hs]
    exact ⟨Or.inl, fun h => h.elim (fun x => x) (fun x => x)⟩
  · rw [setFlag_id]; rfl

private theorem keys_split (L : List (Option Member)) (i : Nat) (hi : i < L.length) :
    ((L.filterMap _root_.id).map Member.id) =
      ((L.take i).filterMap _root_.id).map Member.id ++ (L[i].map Member.id).toList ++
        ((L.drop (i + 1)).filterMap _root_.id).map Member.id := by
  conv => lhs; rw [← List.take_append_drop i L, ← List.getElem_cons_drop (by simpa using hi)]
  cases L[i] <;> simp

theorem include_unique (m m' : Jarl.Membership MAX) (id : Id) (k : Rust.u8)
    (h : incSpec m id k = some m') (unique : UniqueIdentities m) : UniqueIdentities m' := by
  obtain ⟨i, hi, _, hc, rfl⟩ := incSpec_some m m' id k h
  have hl : i < m.members.toList.length := by simpa using hi
  have hK : Keys m = ((m.members.toList.take i).filterMap _root_.id).map Member.id ++
      (m.members[i].map Member.id).toList ++ ((m.members.toList.drop (i + 1)).filterMap _root_.id).map Member.id := by
    have hg : m.members[i] = m.members.toList[i]'hl := by simp
    rw [hg]
    exact keys_split _ i hl
  have hK' : ∀ a : Member, Keys (⟨m.members.set i (some a) hi⟩ : Jarl.Membership MAX) =
      ((m.members.toList.take i).filterMap _root_.id).map Member.id ++
        a.id :: ((m.members.toList.drop (i + 1)).filterMap _root_.id).map Member.id := by
    intro a
    unfold Keys occ Rust.Iter.flatten
    simp only [Vector.toList_set]
    rw [List.set_eq_take_append_cons_drop, if_pos hl]
    simp
  unfold UniqueIdentities at *
  rw [hK']
  rw [hK] at unique
  rcases hc with ⟨s, hs, hsid⟩ | ⟨hs, habs⟩
  · rw [hs] at unique ⊢
    simpa [setFlag_id, hsid] using unique
  · rw [hs] at unique ⊢
    have hK0 := hK
    rw [hs] at hK0
    simp only [Option.getD_none, Option.map_none, Option.toList_none, List.append_nil, setFlag_id] at unique hK0 ⊢
    apply (List.perm_middle).nodup_iff.mpr
    refine List.nodup_cons.mpr ⟨?_, unique⟩
    intro hmem
    rw [← hK0] at hmem
    obtain ⟨s, hs', hsid⟩ := (keys_member m _).mp hmem
    exact habs s hs' hsid

theorem keys_length_full (m : Jarl.Membership MAX) (full : none ∉ m.members.toList) : (Keys m).length = MAX := by
  have : ∀ L : List (Option Member), none ∉ L → (L.filterMap _root_.id).length = L.length := by
    intro L
    induction L with
    | nil => intro; rfl
    | cons e rest ih =>
      intro hn
      cases e with
      | none => exact absurd (List.mem_cons_self) hn
      | some s =>
        simp only [List.filterMap_cons, _root_.id, List.length_cons]
        rw [ih (fun h => hn (List.mem_cons_of_mem _ h))]
  simp only [Keys, occ, Rust.Iter.flatten, List.length_map]
  rw [this _ full]; simp

/-- Covering: `include` of an identity in a cover of size at most `MAX`
    always finds a slot when the stored identities are unique and covered. -/
theorem include_available (m : Jarl.Membership MAX) (D : List Id) (fits : D.length ≤ MAX)
    (unique : UniqueIdentities m) (covered : ∀ q, HasIdentity m q → q ∈ D) (id : Id) (admitted : id ∈ D)
    (k : Rust.u8) : ∃ m', incSpec m id k = some m' := by
  cases h : incSpec m id k with
  | some m' => exact ⟨m', rfl⟩
  | none =>
    exfalso
    obtain ⟨absent, full⟩ := (findSlot_none _ _).mp ((incSpec_none m id k).mp h)
    have missing : id ∉ Keys m := by
      intro hm
      obtain ⟨s, hs, hsid⟩ := (keys_member m id).mp hm
      exact absent s hs hsid
    have distinct : (id :: Keys m).Nodup := List.nodup_cons.mpr ⟨missing, unique⟩
    have subset : id :: Keys m ⊆ D := by
      intro q hq
      rcases List.mem_cons.mp hq with rfl | hq
      · exact admitted
      · exact covered q ((keys_member m q).mp hq)
    have bound := distinct.length_le_of_subset subset
    rw [List.length_cons, keys_length_full m full] at bound
    omega

/-! ## The old `Inclusion` obligations, over the translated `include` -/

namespace Inclusion

theorem capacity_preserved (m : Jarl.Membership MAX) (id : Id) (k : Rust.u8) (r : Rust.Result Unit Error)
    (m' : Jarl.Membership MAX) (_ : m.include id k = pure (r, m')) :
    m'.members.toList.length = m.members.toList.length := by simp

theorem selected_slot (m : Jarl.Membership MAX) (id : Id) (k : Rust.u8) (i : Nat) (hMAX : MAX < 2 ^ Rust.usizeBits)
    (selected : findSlot m.members.toList id = some i) :
    ∃ hi : i < MAX, m.include id k =
      pure (.Ok (), ⟨m.members.set i (some (setFlag k (m.members[i].getD (blank id)))) hi⟩) := by
  have hi := findSlot_lt m id i selected
  refine ⟨hi, ?_⟩
  rw [include_eq m id k hMAX]
  simp [incSpec, selected, hi]

theorem full_error (m : Jarl.Membership MAX) (id : Id) (k : Rust.u8) (hMAX : MAX < 2 ^ Rust.usizeBits) :
    (∃ m', m.include id k = pure (.Err .Config, m')) ↔ findSlot m.members.toList id = none := by
  rw [include_eq m id k hMAX, ← incSpec_none]
  cases incSpec m id k with
  | none => simp only [iff_true]; exact ⟨m, rfl⟩
  | some m' =>
    simp only [reduceCtorEq, iff_false, not_exists]
    intro m'' h
    have := Rust.pure_inj h
    simp at this

theorem full_exact (m : Jarl.Membership MAX) (id : Id) (k : Rust.u8) (hMAX : MAX < 2 ^ Rust.usizeBits) :
    (∃ m', m.include id k = pure (.Err .Config, m')) ↔
      (∀ s, some s ∈ m.members.toList → s.id ≠ id) ∧ none ∉ m.members.toList := by
  rw [full_error m id k hMAX, findSlot_none]

theorem other_slots_unchanged (m : Jarl.Membership MAX) (id : Id) (k : Rust.u8) (i : Nat) (hMAX : MAX < 2 ^ Rust.usizeBits)
    (selected : findSlot m.members.toList id = some i) (r : Rust.Result Unit Error) (m' : Jarl.Membership MAX)
    (result : m.include id k = pure (r, m')) (j : Nat) (hj : j < MAX) (different : j ≠ i) :
    m'.members[j] = m.members[j] := by
  obtain ⟨hi, he⟩ := selected_slot m id k i hMAX selected
  rw [he] at result
  have := Rust.pure_inj result
  cases this
  simp [Ne.symm different]

theorem selected_identity (m : Jarl.Membership MAX) (id : Id) (k : Rust.u8) (i : Nat) (hMAX : MAX < 2 ^ Rust.usizeBits)
    (selected : findSlot m.members.toList id = some i) (r : Rust.Result Unit Error) (m' : Jarl.Membership MAX)
    (result : m.include id k = pure (r, m')) :
    ∃ hi : i < MAX, ∃ s, m'.members[i] = some s ∧ s.id = id := by
  obtain ⟨hi, he⟩ := selected_slot m id k i hMAX selected
  rw [he] at result
  have := Rust.pure_inj result
  cases this
  refine ⟨hi, setFlag k (m.members[i].getD (blank id)), by simp, ?_⟩
  rw [setFlag_id]
  obtain ⟨_, hc⟩ := findSlot_some _ _ _ selected
  simp only [Vector.getElem_toList] at hc
  rcases hc with ⟨s, hs, hsid⟩ | ⟨hs, _⟩
  · rw [hs]; exact hsid
  · rw [hs]; rfl

/-- The selected slot held `id` or was empty, and receives exactly the
    previous record (or a fresh all-false record) with the requested flag set. -/
theorem selected_effect (m : Jarl.Membership MAX) (id : Id) (k : Rust.u8) (i : Nat) (hMAX : MAX < 2 ^ Rust.usizeBits)
    (selected : findSlot m.members.toList id = some i) :
    ∃ hi : i < MAX,
      ((∃ s, m.members[i] = some s ∧ s.id = id) ∨
        (m.members[i] = none ∧ ∀ s, some s ∈ m.members.toList → s.id ≠ id)) ∧
      m.include id k = pure (.Ok (), ⟨m.members.set i (some (setFlag k (m.members[i].getD (blank id)))) hi⟩) := by
  obtain ⟨hi, he⟩ := selected_slot m id k i hMAX selected
  obtain ⟨_, hc⟩ := findSlot_some _ _ _ selected
  simp only [Vector.getElem_toList] at hc
  exact ⟨hi, hc, he⟩

theorem full_unchanged (m : Jarl.Membership MAX) (id : Id) (k : Rust.u8) (hMAX : MAX < 2 ^ Rust.usizeBits)
    (e : Error) (m' : Jarl.Membership MAX) (full : m.include id k = pure (.Err e, m')) : m' = m := by
  rw [include_eq m id k hMAX] at full
  cases h : incSpec m id k with
  | none =>
    simp only [h] at full
    have := Rust.pure_inj full; simp at this; exact this.2.symm
  | some _ =>
    simp only [h] at full
    have := Rust.pure_inj full; simp at this

theorem preserves_unique (m : Jarl.Membership MAX) (id : Id) (k : Rust.u8) (hMAX : MAX < 2 ^ Rust.usizeBits)
    (r : Rust.Result Unit Error) (m' : Jarl.Membership MAX) (result : m.include id k = pure (r, m'))
    (unique : UniqueIdentities m) : UniqueIdentities m' := by
  rw [include_eq m id k hMAX] at result
  cases h : incSpec m id k with
  | none =>
    simp only [h] at result
    have := Rust.pure_inj result; simp at this; rw [← this.2]; exact unique
  | some m'' =>
    simp only [h] at result
    have := Rust.pure_inj result; simp at this; rw [← this.2]
    exact include_unique m m'' id k h unique

end Inclusion

end Jarl.Contracts.Membership
