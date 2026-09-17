import Provium.State

/- A conservative loan machine for the initialized scalar backend. Root loans
reserve their entire region until release. Reborrowing suspends the parent;
returning the child restores it. Paths name logical fields, not byte addresses.
Rust place resolution, actual lifetime validation, interior mutability and
dropping values remain separate source-refinement obligations. -/
namespace Provium.State.Loans

inductive Mode where
  | shared
  | exclusive
  deriving DecidableEq

structure Frame where
  path : Path
  mode : Mode
  deriving DecidableEq

def Nested (parent child : Frame) : Prop :=
  parent.path <+: child.path ∧ (parent.mode = .exclusive ∨ child.mode = .shared)

instance (parent child : Frame) : Decidable (Nested parent child) :=
  inferInstanceAs (Decidable (_ ∧ _))

theorem nested_refl (frame : Frame) : Nested frame frame := by
  refine ⟨List.prefix_refl _, ?_⟩
  cases frame.mode <;> simp

theorem nested_trans (ab : Nested a b) (bc : Nested b c) : Nested a c := by
  refine ⟨ab.1.trans bc.1, ?_⟩
  rcases ab.2 with exclusive | shared
  · exact Or.inl exclusive
  · rcases bc.2 with exclusive | shared'
    · cases shared.symm.trans exclusive
    · exact Or.inr shared'

-- The proof index prevents constructing a child that escapes or strengthens
-- its parent's authority. It does not establish that a Rust borrow has this path.
inductive Stack : Frame → Frame → Type where
  | root (frame : Frame) : Stack frame frame
  | child {root parent : Frame} (stack : Stack root parent)
      (frame : Frame) (ticket : Nat) (within : Nested parent frame) : Stack root frame

theorem Stack.nested {origin active : Frame} (stack : Stack origin active) : Nested origin active := by
  induction stack with
  | root => exact nested_refl _
  | child stack frame ticket within ih => exact nested_trans ih within

def Stack.ticket : Stack origin active → Nat
  | .root _ => 0
  | .child _ _ ticket _ => ticket

def Stack.Below : Stack origin active → Nat → Prop
  | .root _, limit => 0 < limit
  | .child parent _ ticket _, limit => parent.Below limit ∧ ticket < limit

theorem Stack.below_mono (stack : Stack origin active)
    (bounded : stack.Below first) (increase : first ≤ second) : stack.Below second := by
  induction stack with
  | root => exact Nat.lt_of_lt_of_le bounded increase
  | child parent frame ticket within ih =>
    exact ⟨ih bounded.1, Nat.lt_of_lt_of_le bounded.2 increase⟩

theorem Stack.ticket_below (stack : Stack origin active) (bounded : stack.Below limit) :
    stack.ticket < limit := by
  cases stack with
  | root => exact bounded
  | child => exact bounded.2

structure Loan where
  root : Frame
  active : Frame
  stack : Stack root active
  nextTicket : Nat
  bounded : stack.Below nextTicket

def initial (frame : Frame) : Loan := ⟨frame, frame, .root frame, 1, Nat.zero_lt_succ _⟩

-- The counter is retained when returning a child, so an old child ticket cannot
-- become valid again when a later sibling is borrowed.
def advance (loan : Loan) : Loan :=
  ⟨loan.root, loan.active, loan.stack, loan.nextTicket + 1,
    loan.stack.below_mono loan.bounded (Nat.le_succ _)⟩

def childLoan (loan : Loan) (child : Frame) (within : Nested loan.active child) : Loan :=
  ⟨loan.root, child, .child loan.stack child loan.nextTicket within, loan.nextTicket + 1,
    ⟨loan.stack.below_mono loan.bounded (Nat.le_succ _), Nat.lt_succ_self _⟩⟩

inductive Fault where
  | missing
  | denied
  | rootRelease
  deriving DecidableEq

def reborrow (loan : Loan) (ticket : Nat) (child : Frame) : Except Fault Loan :=
  if ticket = loan.stack.ticket then
    if within : Nested loan.active child then .ok (childLoan loan child within)
    else .error .denied
  else .error .denied

def pop : Loan → Except Fault Loan
  | ⟨_, _, .root _, _, _⟩ => .error .rootRelease
  | ⟨origin, _, .child (parent := parent) stack _ _ _, next, bounded⟩ =>
      .ok ⟨origin, parent, stack, next, bounded.1⟩

def endBorrow (loan : Loan) (ticket : Nat) : Except Fault Loan :=
  if ticket = loan.stack.ticket then pop loan else .error .denied

theorem reborrow_restores (within : Nested loan.active child) :
    (reborrow loan loan.stack.ticket child).bind (fun result => endBorrow result result.stack.ticket) = .ok (advance loan) := by
  cases loan
  simp [reborrow, within, Except.bind, endBorrow, pop, childLoan, advance]

theorem reborrow_reserves (success : reborrow loan ticket child = .ok result) :
    result.root = loan.root ∧ result.active = child ∧
      result.stack.ticket = loan.nextTicket := by
  unfold reborrow at success
  split at success
  · split at success
    · cases success
      exact ⟨rfl, rfl, rfl⟩
    · cases success
  · cases success

theorem endBorrow_reserves (success : endBorrow loan ticket = .ok result) :
    result.root = loan.root ∧ result.nextTicket = loan.nextTicket := by
  unfold endBorrow at success
  split at success
  · cases loan with
    | mk root active stack next bounded =>
      cases stack <;> simp [pop] at success
      subst result
      exact ⟨rfl, rfl⟩
  · cases success

def Overlap (a b : Path) : Prop := a <+: b ∨ b <+: a

instance (a b : Path) : Decidable (Overlap a b) :=
  inferInstanceAs (Decidable (_ ∨ _))

def Compatible (a b : Frame) : Prop :=
  ¬ Overlap a.path b.path ∨ (a.mode = .shared ∧ b.mode = .shared)

instance (a b : Frame) : Decidable (Compatible a b) :=
  inferInstanceAs (Decidable (_ ∨ _))

theorem compatible_symm (h : Compatible a b) : Compatible b a := by
  rcases h with separate | shared
  · exact Or.inl (fun overlap => separate overlap.symm)
  · exact Or.inr shared.symm

-- Root identifiers must be globally fresh across lifetimes; the caller must
-- discharge that allocation premise. They are not positions in a list.
abbrev World := Nat → Option Loan

def Valid (world : World) : Prop :=
  ∀ i a j b, world i = some a → world j = some b → i ≠ j →
    Compatible a.root b.root

def set (world : World) (owner : Nat) (loan : Option Loan) : World :=
  fun i => if i = owner then loan else world i

theorem empty_valid : Valid (fun _ => none) := by
  intro i a j b impossible
  cases impossible

-- Root acquisition must check all outstanding reservations, including suspended
-- parents. Looking only at the active child would allow aliasing after return.
theorem acquire_valid (frame : Frame) (valid : Valid world) (_fresh : world owner = none)
    (separate : ∀ j other, world j = some other → Compatible frame other.root) :
    Valid (set world owner (some (initial frame))) := by
  intro i a j b first second different
  by_cases hi : i = owner
  · subst i
    simp only [set, ite_true, Option.some.injEq] at first
    subst a
    have hj : j ≠ owner := Ne.symm different
    simp only [set, if_neg hj] at second
    exact separate j b second
  · simp only [set, if_neg hi] at first
    by_cases hj : j = owner
    · subst j
      simp only [set, ite_true, Option.some.injEq] at second
      subst b
      exact compatible_symm (separate i a first)
    · simp only [set, if_neg hj] at second
      exact valid i a j b first second different

-- A replacement preserves the reservation; reborrow/endBorrow satisfy this
-- premise. Access uses only the active frame, so suspended parents cannot act.
theorem replace_valid (valid : Valid world) (present : world owner = some old)
    (reserved : replacement.root = old.root) :
    Valid (set world owner (some replacement)) := by
  intro i a j b first second different
  by_cases hi : i = owner
  · subst i
    simp only [set, ite_true, Option.some.injEq] at first
    subst a
    have hj : j ≠ owner := Ne.symm different
    simp only [set, if_neg hj] at second
    rw [reserved]
    exact valid owner old j b present second different
  · simp only [set, if_neg hi] at first
    by_cases hj : j = owner
    · subst j
      simp only [set, ite_true, Option.some.injEq] at second
      subst b
      rw [reserved]
      exact valid i a owner old first present different
    · simp only [set, if_neg hj] at second
      exact valid i a j b first second different

theorem release_valid (valid : Valid world) : Valid (set world owner none) := by
  intro i a j b first second different
  by_cases hi : i = owner
  · simp [set, hi] at first
  · by_cases hj : j = owner
    · simp [set, hj] at second
    · exact valid i a j b (by simpa [set, hi] using first)
        (by simpa [set, hj] using second) different

def Allowed (world : World) (owner ticket : Nat) (frame : Frame) : Prop :=
  match world owner with
  | none => False
  | some loan => ticket = loan.stack.ticket ∧ Nested loan.active frame

instance (world : World) (owner ticket : Nat) (frame : Frame) :
    Decidable (Allowed world owner ticket frame) := by
  unfold Allowed
  cases world owner <;> infer_instance

theorem reborrow_rejects_old_ticket {frame : Frame}
    (success : reborrow loan ticket child = .ok result)
    (old : oldTicket < loan.nextTicket) :
    ¬ Allowed (set world owner (some result)) owner oldTicket frame := by
  have fresh := (reborrow_reserves success).2.2
  simp only [Allowed, set, ite_true]
  intro access
  have equal : oldTicket = loan.nextTicket := access.1.trans fresh
  omega

theorem reborrow_suspends_parent {frame : Frame}
    (success : reborrow loan ticket child = .ok result) :
    ¬ Allowed (set world owner (some result)) owner loan.stack.ticket frame :=
  reborrow_rejects_old_ticket success (loan.stack.ticket_below loan.bounded)

theorem allowed_root {frame : Frame} (allowed : Allowed world owner ticket frame) :
    ∃ loan, world owner = some loan ∧ Nested loan.root frame := by
  cases found : world owner with
  | none => simp [Allowed, found] at allowed
  | some loan =>
    have access : ticket = loan.stack.ticket ∧ Nested loan.active frame := by
      simpa [Allowed, found] using allowed
    exact ⟨loan, rfl, nested_trans loan.stack.nested access.2⟩

theorem overlap_roots (a : outerA <+: innerA) (b : outerB <+: innerB)
    (overlap : Overlap innerA innerB) : Overlap outerA outerB := by
  rcases overlap with forward | backward
  · exact List.prefix_or_prefix_of_prefix (a.trans forward) b
  · exact List.prefix_or_prefix_of_prefix a (b.trans backward)

-- The key exclusion property is derived from reservations and scoped access.
-- It is not an assumption that two active aliases cannot conflict.
theorem exclusive_excludes (valid : Valid world) (different : i ≠ j)
    (write : Allowed world i ti ⟨p, .exclusive⟩)
    (other : Allowed world j tj ⟨q, mode⟩) : ¬ Overlap p q := by
  obtain ⟨a, ha, pa, ma⟩ := allowed_root write
  obtain ⟨b, hb, pb, _⟩ := allowed_root other
  intro overlap
  rcases valid i a j b ha hb different with separate | shared
  · exact separate (overlap_roots pa pb overlap)
  · rcases ma with exclusive | impossible
    · cases shared.1.symm.trans exclusive
    · cases impossible

def ConditionAllowed (world : World) (owner ticket : Nat) : Condition → Prop
  | .boolean _ => True
  | .field p => Allowed world owner ticket ⟨p, .shared⟩
  | .not c => ConditionAllowed world owner ticket c
  | .and a b | .or a b => ConditionAllowed world owner ticket a ∧ ConditionAllowed world owner ticket b

def ProgramAllowed (world : World) (owner ticket : Nat) : Program → Prop
  | .done => True
  | .write w => Allowed world owner ticket ⟨w.path, .exclusive⟩
  | .seq a b => ProgramAllowed world owner ticket a ∧ ProgramAllowed world owner ticket b
  | .branch c a b =>
      ConditionAllowed world owner ticket c ∧ ProgramAllowed world owner ticket a ∧ ProgramAllowed world owner ticket b

theorem writes_allowed (program : Program)
    (allowed : ProgramAllowed world owner ticket program) (written : path ∈ writes program) :
    Allowed world owner ticket ⟨path, .exclusive⟩ := by
  induction program with
  | done => simp [writes] at written
  | write effect =>
    have same : path = effect.path := by simpa [writes] using written
    simpa [same, ProgramAllowed] using allowed
  | seq first rest ihFirst ihRest =>
    rcases List.mem_append.mp written with first | rest
    · exact ihFirst allowed.1 first
    · exact ihRest allowed.2 rest
  | branch condition yes no ihYes ihNo =>
    rcases List.mem_append.mp written with yes | no
    · exact ihYes allowed.2.1 yes
    · exact ihNo allowed.2.2 no

theorem other_loan_untouched (valid : Valid world) (different : owner ≠ otherOwner)
    (allowed : ProgramAllowed world owner ticket program)
    (other : Allowed world otherOwner otherTicket ⟨path, mode⟩) : path ∉ writes program := by
  intro written
  have cannotOverlap := exclusive_excludes valid different (writes_allowed program allowed written) other
  exact cannotOverlap (Or.inl (List.prefix_refl _))

theorem execute_other_loan_frame (valid : Valid world) (different : owner ≠ otherOwner)
    (allowed : ProgramAllowed world owner ticket program)
    (other : Allowed world otherOwner otherTicket ⟨path, mode⟩) :
    Provium.State.execute program state path = state path :=
  execute_frame program state path (other_loan_untouched valid different allowed other)

def conditionAllowedDec (world : World) (owner ticket : Nat) :
    (c : Condition) → Decidable (ConditionAllowed world owner ticket c)
  | .boolean _ => inferInstanceAs (Decidable True)
  | .field p => inferInstanceAs (Decidable (Allowed world owner ticket ⟨p, .shared⟩))
  | .not c => conditionAllowedDec world owner ticket c
  | .and a b | .or a b =>
    letI := conditionAllowedDec world owner ticket a
    letI := conditionAllowedDec world owner ticket b
    inferInstanceAs (Decidable (_ ∧ _))

instance (world : World) (owner ticket : Nat) (c : Condition) :
    Decidable (ConditionAllowed world owner ticket c) := conditionAllowedDec world owner ticket c

def programAllowedDec (world : World) (owner ticket : Nat) :
    (p : Program) → Decidable (ProgramAllowed world owner ticket p)
  | .done => inferInstanceAs (Decidable True)
  | .write w => inferInstanceAs (Decidable (Allowed world owner ticket ⟨w.path, .exclusive⟩))
  | .seq a b =>
    letI := programAllowedDec world owner ticket a
    letI := programAllowedDec world owner ticket b
    inferInstanceAs (Decidable (_ ∧ _))
  | .branch _c a b =>
    letI := programAllowedDec world owner ticket a
    letI := programAllowedDec world owner ticket b
    inferInstanceAs (Decidable (_ ∧ _ ∧ _))

instance (world : World) (owner ticket : Nat) (p : Program) :
    Decidable (ProgramAllowed world owner ticket p) := programAllowedDec world owner ticket p

-- Static footprint admission is deliberately conservative about untaken
-- branches. Once admitted, initialized execution retains short-circuit behavior.
def execute (world : World) (owner ticket : Nat) (layout : Initialized.Layout)
    (program : Program) (heap : Initialized.Heap α) :
    Except (Fault ⊕ Initialized.Fault) (Initialized.Heap α) :=
  if ProgramAllowed world owner ticket program then
    (Initialized.execute layout program heap).mapError Sum.inr
  else .error (.inl .denied)

theorem execute_refines (program : Program)
    (related : Initialized.Relates layout heap state)
    (typed : Initialized.ProgramTyped layout program)
    (allowed : ProgramAllowed world owner ticket program) :
    ∃ result, execute world owner ticket layout program heap = .ok result ∧
      Initialized.Relates layout result (Provium.State.execute program state) := by
  obtain ⟨result, completed, related'⟩ := Initialized.execute_refines program related typed
  exact ⟨result, by simp [execute, allowed, completed, Except.mapError], related'⟩

-- The arena discharges root-identity freshness. Invalidating a lifetime leaves
-- the allocation counter unchanged; no later reservation can recycle that ID.
-- Compatibility is an explicit proof obligation of reservation, not a promise
-- that an arbitrary Rust borrow checker result already establishes it.
structure Arena where
  nextOwner : Nat
  world : World
  allocated : ∀ owner loan, world owner = some loan → owner < nextOwner
  valid : Valid world

def Arena.empty : Arena :=
  ⟨0, fun _ => none, (by intro owner loan impossible; cases impossible), empty_valid⟩

theorem Arena.fresh (arena : Arena) : arena.world arena.nextOwner = none := by
  cases found : arena.world arena.nextOwner with
  | none => rfl
  | some loan => have impossible := arena.allocated _ _ found; omega

def Arena.reserve (arena : Arena) (frame : Frame)
    (separate : ∀ j other, arena.world j = some other → Compatible frame other.root) : Arena :=
  ⟨arena.nextOwner + 1, set arena.world arena.nextOwner (some (initial frame)),
    by
      intro owner loan present
      by_cases same : owner = arena.nextOwner
      · omega
      · have old : arena.world owner = some loan := by simpa [set, same] using present
        have before := arena.allocated owner loan old
        omega,
    acquire_valid frame arena.valid arena.fresh separate⟩

-- Lifetime invalidation removes every outstanding child along with its root.
-- Destruction of the referent and Rust legality of ending that lifetime are
-- not established by this reservation operation.
def Arena.invalidate (arena : Arena) (owner : Nat) : Arena :=
  ⟨arena.nextOwner, set arena.world owner none,
    by
      intro other loan present
      by_cases same : other = owner
      · simp [set, same] at present
      · exact arena.allocated other loan (by simpa [set, same] using present),
    release_valid arena.valid⟩

def Arena.replace (arena : Arena) (owner : Nat) (old replacement : Loan)
    (present : arena.world owner = some old) (reserved : replacement.root = old.root) : Arena :=
  ⟨arena.nextOwner, set arena.world owner (some replacement),
    by
      intro other loan found
      by_cases same : other = owner
      · subst other
        exact arena.allocated owner old present
      · exact arena.allocated other loan (by simpa [set, same] using found),
    replace_valid arena.valid present reserved⟩

def Arena.reborrow (arena : Arena) (owner ticket : Nat) (frame : Frame) :
    Except Fault Arena :=
  match present : arena.world owner with
  | none => .error .missing
  | some old =>
    match changed : Loans.reborrow old ticket frame with
    | .error fault => .error fault
    | .ok replacement =>
      .ok (arena.replace owner old replacement present (reborrow_reserves changed).1)

def Arena.endBorrow (arena : Arena) (owner ticket : Nat) : Except Fault Arena :=
  match present : arena.world owner with
  | none => .error .missing
  | some old =>
    match changed : Loans.endBorrow old ticket with
    | .error fault => .error fault
    | .ok replacement =>
      .ok (arena.replace owner old replacement present (endBorrow_reserves changed).1)

def Stack.isRoot : Stack origin active → Bool
  | .root _ => true
  | .child _ _ _ _ => false

def Arena.endLifetime (arena : Arena) (owner ticket : Nat) : Except Fault Arena :=
  match arena.world owner with
  | none => .error .missing
  | some loan =>
    if ticket = loan.stack.ticket ∧ loan.stack.isRoot = true then
      .ok (arena.invalidate owner)
    else .error .denied

theorem Arena.reserve_next (arena : Arena) (frame : Frame) (separate) :
    (arena.reserve frame separate).nextOwner = arena.nextOwner + 1 := rfl

theorem Arena.invalidate_next (arena : Arena) (owner : Nat) :
    (arena.invalidate owner).nextOwner = arena.nextOwner := rfl

theorem Arena.retired_not_revived (arena : Arena) (oldOwner : Nat)
    (issued : oldOwner < arena.nextOwner) (frame : Frame) (separate) :
    ((arena.invalidate oldOwner).reserve frame separate).world oldOwner = none := by
  have different : oldOwner ≠ arena.nextOwner := by omega
  simp [Arena.reserve, Arena.invalidate, set, different]

end Provium.State.Loans
