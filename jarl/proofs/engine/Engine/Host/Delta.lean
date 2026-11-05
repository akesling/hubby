import Engine.Main
import Contracts.StorageView

/-!
# Host storage deltas: Jarl's dirty tracking

A real host keeps a durable record (`Delta.Durable`: hard state, snapshot,
entries) and applies the incremental `Write` of each `Ready`, built by
`State::write(log_from, snapshot_changed)`. That write is correct only if the
node's dirty tracking (`log_from`, `snapshot_changed`) describes how its live
state diverged from what was last persisted.

`DeltaOk d n` is that property for a durable record `d` and a live node `n`:
it supplies exactly the premises of `source_checkpoint` for
`s := n.state`, `first := n.log_from`, `changed := n.snapshot_changed`,
`old := d`, and a clean node's record is its materialized state. So applying
the write of any `Ready` yields the durable view of the live state
(`deltaOk_write`).

`DeltaOk` follows from a semantic fact, `Agrees s₀ s changed cut`: the
checkpoint `s₀` (whose view is `d`) and the live state `s` hold the same entry
at every index below `cut` and above the new snapshot boundary (when the
snapshot changed), and the snapshot changed whenever it differs
(`deltaOk_of_agrees`). The rest of this module establishes `Agrees` for every
operation of a fixed node from the per-operation specifications (and, for
`Install`, from the generated code of `step`, whose specification leaves the
new `log_from` existential).
-/

namespace Jarl.Engine.Host
open Jarl Jarl.Engine Jarl.Contracts.StorageView

variable {V S : Type} {N CAP : Nat}

/-- A host's durable record: hard state, snapshot, and the entries after it. -/
abbrev Durable (V S : Type) := Delta.Durable HardState (Snapshot S) (Entry V)

/-- The host contract's snapshot boundary. -/
def snapBoundary (s : Snapshot S) : Nat := s.last.index.val

/-- The host contract's entry index. -/
def entryIndex (e : Entry V) : Nat := e.id.index.val

/-- The durable record holding exactly the checkpoint `s`. -/
def view (s : State V S CAP) : Durable V S := ⟨s.hard, s.snapshot, ret s⟩

/-- Apply the materialized transaction of a `Write` to a durable record, as
    documented in `ready.rs`. -/
abbrev applyWrite (d : Durable V S) (w : Jarl.Write V S) : Durable V S :=
  Delta.apply snapBoundary entryIndex d (materialize w)

/-- The node-local delta invariant: the durable record `d` and the node's dirty
    tracking meet the premises of `source_checkpoint`, and a clean node's
    record is exactly its state. -/
structure DeltaOk (d : Durable V S) (n : Node V S N CAP) : Prop where
  capacity : n.state.len.val ≤ CAP
  unchanged : n.snapshot_changed = false → d.snapshot = n.state.snapshot
  cannotRemove : n.state.snapshot = none → d.snapshot = none
  tracked : Delta.Retains snapBoundary entryIndex d (if n.snapshot_changed then n.state.snapshot else none)
    (n.log_from.map (·.val)) ((n.state.entries.toList.take (writeStart n.state n.log_from)).filterMap id)
  clean : n.dirty = false → d = view n.state

/-- Under `DeltaOk`, applying the node's write reproduces its live state. -/
theorem deltaOk_write (d : Durable V S) (n : Node V S N CAP) (h : DeltaOk d n) (w : Jarl.Write V S)
    (hw : State.write n.state n.log_from n.snapshot_changed = pure w) :
    applyWrite d w = view n.state := by
  obtain ⟨w', hw', happ⟩ := source_checkpoint n.state n.log_from n.snapshot_changed d snapBoundary entryIndex
    h.capacity h.unchanged h.cannotRemove h.tracked
  rw [hw] at hw'
  cases Rust.pure_inj hw'
  exact happ

/-! ## Entries by index -/

/-- The retained entry at index `i`, if any. -/
def entryAt (s : State V S CAP) (i : Nat) : Option (Entry V) :=
  if s.base.index.val < i then (ret s)[i - s.base.index.val - 1]? else none

theorem entryAt_of_mem (s : State V S CAP) (hc : Contig s) (e : Entry V) (he : e ∈ ret s) :
    entryAt s (entryIndex e) = some e := by
  obtain ⟨j, hj, rfl⟩ := List.getElem_of_mem he
  have h := hc j hj
  unfold entryAt entryIndex
  rw [h, if_pos (by omega)]
  rw [show s.base.index.val + j + 1 - s.base.index.val - 1 = j by omega]
  exact List.getElem?_eq_getElem hj

theorem mem_of_entryAt (s : State V S CAP) (i : Nat) (e : Entry V) (h : entryAt s i = some e) : e ∈ ret s := by
  unfold entryAt at h
  split at h
  · exact List.mem_of_getElem? h
  · cases h

theorem base_lt_of_entryAt (s : State V S CAP) (i : Nat) (e : Entry V) (h : entryAt s i = some e) :
    s.base.index.val < i := by
  unfold entryAt at h
  split at h
  · assumption
  · cases h

theorem index_of_entryAt (s : State V S CAP) (hc : Contig s) (i : Nat) (e : Entry V) (h : entryAt s i = some e) :
    entryIndex e = i := by
  have hb := base_lt_of_entryAt s i e h
  unfold entryAt at h
  rw [if_pos hb] at h
  obtain ⟨hj, rfl⟩ := List.getElem?_eq_some_iff.mp h
  have := hc _ hj
  unfold entryIndex; omega

theorem entryAt_congr (s s' : State V S CAP) (hsn : s'.snapshot = s.snapshot) (hr : ret s' = ret s) (i : Nat) :
    entryAt s' i = entryAt s i := by
  have hb : s'.base = s.base := by simp [State.base, hsn]
  simp only [entryAt, hb, hr]

theorem ret_sorted (s : State V S CAP) (hc : Contig s) :
    (ret s).Pairwise (fun a b => entryIndex a < entryIndex b) := by
  rw [List.pairwise_iff_getElem]
  intro i j hi hj hij
  unfold entryIndex
  rw [hc i hi, hc j hj]
  omega

/-! ## Two list facts -/

/-- Two lists strictly sorted by a key with the same members are equal. -/
theorem eq_of_sorted_mem {α : Type} (key : α → Nat) : ∀ (l₁ l₂ : List α),
    l₁.Pairwise (fun a b => key a < key b) → l₂.Pairwise (fun a b => key a < key b) →
    (∀ x, x ∈ l₁ ↔ x ∈ l₂) → l₁ = l₂
  | [], [], _, _, _ => rfl
  | [], y :: _, _, _, h => absurd ((h y).2 (by simp)) (by simp)
  | x :: _, [], _, _, h => absurd ((h x).1 (by simp)) (by simp)
  | x :: xs, y :: ys, h1, h2, h => by
    rw [List.pairwise_cons] at h1 h2
    have hx : x = y := by
      rcases List.mem_cons.mp ((h x).1 (by simp)) with e | hx
      · exact e
      · rcases List.mem_cons.mp ((h y).2 (by simp)) with e | hy
        · exact e.symm
        · have := h2.1 x hx; have := h1.1 y hy; omega
    subst hx
    congr 1
    apply eq_of_sorted_mem key xs ys h1.2 h2.2
    intro z
    constructor
    · intro hz
      have hne : z ≠ x := fun e => by subst e; have := h1.1 z hz; omega
      rcases List.mem_cons.mp ((h z).1 (by simp [hz])) with e | h'
      · exact absurd e hne
      · exact h'
    · intro hz
      have hne : z ≠ x := fun e => by subst e; have := h2.1 z hz; omega
      rcases List.mem_cons.mp ((h z).2 (by simp [hz])) with e | h'
      · exact absurd e hne
      · exact h'

/-- A list sorted by key splits around the members satisfying a key-convex predicate. -/
theorem interval_split {α : Type} (key : α → Nat) (p : α → Bool)
    (hconv : ∀ x y z, p x = true → p z = true → key x ≤ key y → key y ≤ key z → p y = true) :
    ∀ l : List α, l.Pairwise (fun a b => key a < key b) →
      ∃ before mid after, l = before ++ mid ++ after ∧ (∀ e ∈ before, p e = false) ∧
        (∀ e ∈ mid, p e = true) ∧ (∀ e ∈ after, p e = false)
  | [], _ => ⟨[], [], [], rfl, by simp, by simp, by simp⟩
  | x :: xs, hs => by
    rw [List.pairwise_cons] at hs
    obtain ⟨b, m, a, he, hb, hm, ha⟩ := interval_split key p hconv xs hs.2
    cases hp : p x
    · refine ⟨x :: b, m, a, by simp [he], ?_, hm, ha⟩
      intro e he'
      rcases List.mem_cons.mp he' with rfl | h'
      · exact hp
      · exact hb e h'
    · by_cases hbn : b = []
      · subst hbn
        refine ⟨[], x :: m, a, by simp [he], by simp, ?_, ha⟩
        intro e he'
        rcases List.mem_cons.mp he' with rfl | h'
        · exact hp
        · exact hm e h'
      · have hm0 : m = [] := by
          cases m with
          | nil => rfl
          | cons z zs =>
            exfalso
            obtain ⟨y, hy⟩ := List.exists_mem_of_ne_nil b hbn
            have hyx : key x < key y := hs.1 y (by rw [he]; simp [hy])
            have hp2 := hs.2
            rw [he, List.pairwise_append, List.pairwise_append] at hp2
            have hyz : key y < key z := hp2.1.2.2 y hy z (by simp)
            have := hconv x y z hp (hm z (by simp)) (by omega) (by omega)
            rw [hb y hy] at this
            cases this
        subst hm0
        refine ⟨[], [x], b ++ a, by simp [he], by simp, by simp [hp], ?_⟩
        intro e he'
        rcases List.mem_append.mp he' with h' | h'
        · exact hb e h'
        · exact ha e h'

/-! ## Agreement of a live state with a checkpoint -/

/-- The live state `s`, with dirty tracking `changed` and `cut`, agrees with the
    checkpoint `s₀`: an unchanged snapshot is the checkpoint's, a snapshot is
    never removed, and both hold the same entry at every index below `cut` and,
    if the snapshot changed, above the new boundary. -/
structure Agrees (s₀ s : State V S CAP) (changed : Bool) (cut : Option Rust.u64) : Prop where
  same : changed = false → s.snapshot = s₀.snapshot
  keep : s.snapshot = none → s₀.snapshot = none
  agree : ∀ i, (changed = true → s.base.index.val < i) → (∀ c, cut = some c → i < c.val) →
    entryAt s₀ i = entryAt s i

/-- A node's agreement, under its own dirty tracking. -/
abbrev AgreesN (s₀ : State V S CAP) (n : Node V S N CAP) : Prop :=
  Agrees s₀ n.state n.snapshot_changed n.log_from

theorem take_writeStart (s : State V S CAP) (hl : Layout s) (first : Option Rust.u64) :
    (s.entries.toList.take (writeStart s first)).filterMap id = (ret s).take (writeStart s first) := by
  have hw := writeStart_le s first
  have hlen := len_eq s hl
  rw [hl.2, List.take_append_of_le_length (by simp; omega)]
  simp [← List.map_take]

theorem mem_take_writeStart (s : State V S CAP) (hl : Layout s) (hc : Contig s) (first : Option Rust.u64)
    (e : Entry V) :
    e ∈ (ret s).take (writeStart s first) ↔ e ∈ ret s ∧ ∀ c, first = some c → entryIndex e < c.val := by
  have hlen := len_eq s hl
  constructor
  · intro h
    refine ⟨List.mem_of_mem_take h, ?_⟩
    intro c hc'
    obtain ⟨j, hj, he⟩ := List.getElem_of_mem h
    simp only [List.length_take] at hj
    rw [List.getElem_take] at he
    subst he
    have := hc j (by omega)
    unfold entryIndex
    rw [this]
    subst hc'
    simp only [writeStart] at hj
    omega
  · rintro ⟨h, hb⟩
    obtain ⟨j, hj, rfl⟩ := List.getElem_of_mem h
    have hidx := hc j hj
    have hjw : j < writeStart s first := by
      cases first with
      | none => simp only [writeStart]; omega
      | some c =>
        have := hb c rfl
        unfold entryIndex at this
        simp only [writeStart]
        omega
    exact List.mem_iff_getElem.mpr ⟨j, by simp; omega, by simp⟩

/-- Agreement gives `DeltaOk` for the checkpoint's view. -/
theorem deltaOk_of_agrees (s₀ : State V S CAP) (hc₀ : Contig s₀) (n : Node V S N CAP)
    (hl : Layout n.state) (hc : Contig n.state) (ha : AgreesN s₀ n)
    (hclean : n.dirty = false → view s₀ = view n.state) : DeltaOk (view s₀) n := by
  refine ⟨hl.1, fun h => (ha.same h).symm, ha.keep, ?_, hclean⟩
  rw [take_writeStart n.state hl]
  -- The survival predicate of the transaction, on the checkpoint's entries.
  let p : Entry V → Bool := fun e =>
    Delta.beforeTruncation entryIndex (n.log_from.map (·.val)) e &&
      Delta.afterSnapshot snapBoundary entryIndex (if n.snapshot_changed then n.state.snapshot else none) e
  have hp : ∀ e, p e = true ↔ (∀ c, n.log_from = some c → entryIndex e < c.val) ∧
      (n.snapshot_changed = true → ∀ sn, n.state.snapshot = some sn → sn.last.index.val < entryIndex e) := by
    intro e
    simp only [p, Bool.and_eq_true]
    apply and_congr
    · cases n.log_from <;> simp [Delta.beforeTruncation, decide_eq_true_eq]
    · cases n.snapshot_changed <;> cases n.state.snapshot <;>
        simp [Delta.afterSnapshot, snapBoundary] <;> exact decide_eq_true_iff
  have hconv : ∀ x y z, p x = true → p z = true → entryIndex x ≤ entryIndex y → entryIndex y ≤ entryIndex z →
      p y = true := by
    intro x y z hx hz h1 h2
    rw [hp] at hx hz ⊢
    refine ⟨fun c hc' => ?_, fun hch sn hsn => ?_⟩
    · have := hz.1 c hc'; omega
    · have := hx.2 hch sn hsn; omega
  obtain ⟨b, m, a, hsplit, hb, hm, ha'⟩ := interval_split entryIndex p hconv (ret s₀) (ret_sorted s₀ hc₀)
  have hfilter : (ret s₀).filter p = m := by
    have h1 : b.filter p = [] := List.filter_eq_nil_iff.mpr (fun e he => by simp [hb e he])
    have h2 : m.filter p = m := List.filter_eq_self.mpr (fun e he => hm e he)
    have h3 : a.filter p = [] := List.filter_eq_nil_iff.mpr (fun e he => by simp [ha' e he])
    rw [hsplit, List.filter_append, List.filter_append, h1, h2, h3]
    simp
  have hidx₀ : ∀ e ∈ ret s₀, 0 < entryIndex e := by
    intro e he
    obtain ⟨j, hj, rfl⟩ := List.getElem_of_mem he
    unfold entryIndex; rw [hc₀ j hj]; omega
  have hmid : m = (ret n.state).take (writeStart n.state n.log_from) := by
    rw [← hfilter]
    apply eq_of_sorted_mem entryIndex
    · exact (ret_sorted s₀ hc₀).filter p
    · exact (ret_sorted n.state hc).sublist (List.take_sublist _ _)
    intro x
    rw [List.mem_filter, mem_take_writeStart n.state hl hc]
    constructor
    · rintro ⟨hx, hpx⟩
      rw [hp] at hpx
      have hlo : n.snapshot_changed = true → n.state.base.index.val < entryIndex x := by
        intro hch
        cases hsn : n.state.snapshot with
        | none => simp [State.base, hsn, LogId.default]; exact hidx₀ x hx
        | some sn => simp only [State.base, hsn, Rust.Option.map_or]; exact hpx.2 hch sn hsn
      have := ha.agree (entryIndex x) hlo hpx.1
      rw [entryAt_of_mem s₀ hc₀ x hx] at this
      exact ⟨mem_of_entryAt _ _ _ this.symm, hpx.1⟩
    · rintro ⟨hx, hcut⟩
      have hat := entryAt_of_mem n.state hc x hx
      have hlt := base_lt_of_entryAt _ _ _ hat
      have := ha.agree (entryIndex x) (fun _ => hlt) hcut
      rw [hat] at this
      refine ⟨mem_of_entryAt _ _ _ this, ?_⟩
      rw [hp]
      refine ⟨hcut, fun _ sn hsn => ?_⟩
      have : n.state.base = sn.last := by simp [State.base, hsn, Rust.Option.map_or]
      rw [this] at hlt
      exact hlt
  refine ⟨⟨b, a, ?_, hb, ?_, ha'⟩⟩
  · show ret s₀ = _
    rw [hsplit, hmid]
  · rw [← hmid]; exact hm

/-! ## Elementary agreements -/

/-- A live log equal to the checkpoint's agrees under any tracking. -/
theorem agrees_of_log (s₀ s : State V S CAP) (hsn : s.snapshot = s₀.snapshot) (hr : ret s = ret s₀)
    (changed : Bool) (cut : Option Rust.u64) : Agrees s₀ s changed cut :=
  ⟨fun _ => hsn, fun h => hsn ▸ h, fun i _ _ => (entryAt_congr s₀ s hsn hr i).symm⟩

/-- Agreement with no cut gives agreement with any cut. -/
theorem agrees_weaken (s₀ s : State V S CAP) (changed : Bool) (h : Agrees s₀ s changed none)
    (cut : Option Rust.u64) : Agrees s₀ s changed cut :=
  ⟨h.same, h.keep, fun i hch _ => h.agree i hch (by simp)⟩

/-- Keeping the first `m` retained entries and the snapshot, with a cut at most
    one past them, preserves agreement. -/
theorem agrees_prefix (s₀ s s' : State V S CAP) (changed : Bool) (cut : Option Rust.u64)
    (h : Agrees s₀ s changed cut) (hsn : s'.snapshot = s.snapshot) (m : Nat)
    (ht : (ret s').take m = (ret s).take m) (c : Rust.u64) (hc1 : c.val ≤ s.base.index.val + m + 1)
    (hc2 : ∀ c₀, cut = some c₀ → c.val ≤ c₀.val) : Agrees s₀ s' changed (some c) := by
  have hb : s'.base = s.base := by simp [State.base, hsn]
  refine ⟨fun h' => hsn.trans (h.same h'), fun h' => h.keep (hsn ▸ h'), ?_⟩
  intro i hch hcut
  have hic := hcut c rfl
  rw [h.agree i (fun e => hb ▸ hch e) (fun c₀ h₀ => Nat.lt_of_lt_of_le hic (hc2 c₀ h₀))]
  unfold entryAt
  rw [hb]
  split
  · have hlt : i - s.base.index.val - 1 < m := by omega
    rw [← List.getElem?_take_of_lt hlt, ← ht, List.getElem?_take_of_lt hlt]
  · rfl

/-- Installing a snapshot that keeps the suffix after its boundary. -/
theorem agrees_install_keep (s₀ s s' : State V S CAP) (changed : Bool) (h : Agrees s₀ s changed none)
    (snap : Snapshot S) (hsn : s'.snapshot = some snap) (hle : s.base.index.val ≤ snap.last.index.val)
    (hr : ret s' = (ret s).drop (snap.last.index.val - s.base.index.val)) : Agrees s₀ s' true none := by
  have hb : s'.base = snap.last := by simp [State.base, hsn, Rust.Option.map_or]
  refine ⟨(fun h' => by cases h'), (fun h' => by rw [hsn] at h'; cases h'), ?_⟩
  intro i hch _
  have hi := hch rfl
  rw [hb] at hi
  have hlo : changed = true → s.base.index.val < i := fun _ => by omega
  rw [h.agree i hlo (by simp)]
  unfold entryAt
  rw [hb, if_pos hi, if_pos (by omega), hr, List.getElem?_drop]
  congr 1
  omega

/-- Installing a snapshot that resets the log, with the cut just past its boundary. -/
theorem agrees_install_reset (s₀ s' : State V S CAP) (hc₀ : Contig s₀) (snap : Snapshot S)
    (hsn : s'.snapshot = some snap) (hr : ret s' = []) :
    Agrees s₀ s' true (Rust.checked_add snap.last.index 1) := by
  have hb : s'.base = snap.last := by simp [State.base, hsn, Rust.Option.map_or]
  refine ⟨(fun h' => by cases h'), (fun h' => by rw [hsn] at h'; cases h'), ?_⟩
  intro i hch hcut
  have hi := hch rfl
  rw [hb] at hi
  have hnone : entryAt s' i = none := by simp [entryAt, hr]
  rw [hnone]
  by_cases hf : snap.last.index.val + (1 : Rust.u64).val < 2 ^ 64
  · have := hcut ⟨snap.last.index.val + (1 : Rust.u64).val, hf⟩ (by rw [Rust.checked_add_eq, dif_pos hf])
    simp at this; omega
  · cases he : entryAt s₀ i with
    | none => rfl
    | some e =>
      have h1 := index_of_entryAt s₀ hc₀ i e he
      have h2 := e.id.index.isLt
      unfold entryIndex at h1
      simp at hf
      omega

/-- Agreement only depends on the live state's snapshot and retained entries. -/
theorem agrees_congr (s₀ s s' : State V S CAP) (changed : Bool) (cut : Option Rust.u64)
    (h : Agrees s₀ s changed cut) (h1 : s'.snapshot = s.snapshot) (h2 : ret s' = ret s) :
    Agrees s₀ s' changed cut := by
  have hb : s'.base = s.base := by simp [State.base, h1]
  refine ⟨fun h' => h1.trans (h.same h'), fun h' => h.keep (h1 ▸ h'), fun i hch hcut => ?_⟩
  rw [entryAt_congr s s' h1 h2]
  exact h.agree i (fun e => hb ▸ hch e) hcut

theorem contig_congr (s s' : State V S CAP) (h1 : s'.snapshot = s.snapshot) (h2 : ret s' = ret s)
    (hc : Contig s) : Contig s' := by
  have hb : s'.base = s.base := by simp [State.base, h1]
  intro k hk
  rw [hb]
  have hk' : k < (ret s).length := h2 ▸ hk
  rw [List.getElem_of_eq h2 hk]
  exact hc k hk'

/-! ## Operations that keep the log and the tracking -/

/-- `n'` has the log and the dirty tracking of `n`. -/
def Same (n n' : Node V S N CAP) : Prop :=
  n'.state.snapshot = n.state.snapshot ∧ ret n'.state = ret n.state ∧ n'.log_from = n.log_from ∧
    n'.snapshot_changed = n.snapshot_changed

theorem Same.refl (n : Node V S N CAP) : Same n n := ⟨rfl, rfl, rfl, rfl⟩

theorem Same.trans {n n' n'' : Node V S N CAP} (a : Same n n') (b : Same n' n'') : Same n n'' :=
  ⟨b.1.trans a.1, b.2.1.trans a.2.1, b.2.2.1.trans a.2.2.1, b.2.2.2.trans a.2.2.2⟩

theorem agreesN_same (s₀ : State V S CAP) (n n' : Node V S N CAP) (h : AgreesN s₀ n) (hs : Same n n') :
    AgreesN s₀ n' := by
  obtain ⟨h1, h2, h3, h4⟩ := hs
  unfold AgreesN
  rw [h3, h4]
  exact agrees_congr s₀ n.state n'.state _ _ h h1 h2

/-- A node whose log is the checkpoint's agrees with it, under any tracking. -/
theorem agreesN_of_same (n n' : Node V S N CAP) (hs : Same n n') : AgreesN n.state n' :=
  agreesN_same n.state n n' (agrees_of_log _ _ rfl rfl _ _) hs

/-- Full agreement (no cut) of a node with the same log as `n`. -/
theorem full_of_same (n n' : Node V S N CAP) (hs : Same n n') :
    Agrees n.state n'.state n'.snapshot_changed none :=
  agrees_of_log _ _ hs.1 hs.2.1 _ _

theorem same_commitTo (n : Node V S N CAP) (v : Rust.u64) : Same n (commitTo n v) := by
  unfold commitTo; split <;> exact ⟨rfl, rfl, rfl, rfl⟩

theorem same_adv {n n' : Node V S N CAP} (h : Adv n n') : Same n n' := by
  rcases h with rfl | ⟨v, -, -, -, rfl⟩
  · exact Same.refl _
  · exact same_commitTo n v

theorem same_bcast (n : Node V S N CAP) : Same n (bcast n) := ⟨rfl, rfl, rfl, rfl⟩

theorem same_queue (n : Node V S N CAP) (a : Fin N) (o : Outbound) : Same n (queue n a o) := ⟨rfl, rfl, rfl, rfl⟩

theorem same_requestVotes (n : Node V S N CAP) : Same n (requestVotes n) := ⟨rfl, rfl, rfl, rfl⟩

theorem same_leaderInit (n : Node V S N CAP) (h : n.local.val < N) : Same n (leaderInit n h) := ⟨rfl, rfl, rfl, rfl⟩

theorem same_candidate (n : Node V S N CAP) (t : Rust.u64) (h : n.local.val < N) : Same n (candidate n t h) :=
  ⟨rfl, rfl, rfl, rfl⟩

theorem same_timers {n n' : Node V S N CAP} (h : Timers n n') : Same n n' := by
  obtain ⟨r, d, rfl⟩ := h; exact ⟨rfl, rfl, rfl, rfl⟩

theorem same_timeOnly {n n' : Node V S N CAP} (h : TimeOnly n n') : Same n n' := by
  obtain ⟨e, a, rfl⟩ := h; exact ⟨rfl, rfl, rfl, rfl⟩

theorem same_following {n n' : Node V S N CAP} {src : Id} (h : Following n src n') : Same n n' := by
  obtain ⟨r, d, rfl⟩ := h; exact ⟨rfl, rfl, rfl, rfl⟩

theorem same_observed {n n' : Node V S N CAP} {src : Id} {t : Rust.u64} (h : Observed n src t n') : Same n n' := by
  rcases h with ⟨-, rfl⟩ | ⟨-, r, d, rfl⟩
  · exact ⟨rfl, rfl, rfl, rfl⟩
  · exact ⟨rfl, rfl, rfl, rfl⟩

/-! ## Appending at the end of the log -/

/-- `barrier` after a fully agreeing node: its no-op entry starts the cut. -/
theorem agrees_barrier (s₀ : State V S CAP) (m m' : Node V S N CAP)
    (hm : Agrees s₀ m.state m.snapshot_changed none) (hcm : Contig m.state) (hb : Barrier m m') :
    AgreesN s₀ m' := by
  rcases hb with rfl | ⟨s', idx, h, hidx, -, hr, -, hsn, -, -, hA⟩
  · exact agrees_weaken _ _ _ hm _
  · apply agreesN_same s₀ _ _ _ (same_adv hA)
    show Agrees s₀ s' m.snapshot_changed (some idx)
    refine agrees_prefix s₀ m.state s' _ none hm hsn (ret m.state).length (by rw [hr]; simp) idx ?_ (by simp)
    have := lastId_eq m.state hcm
    omega

/-- `become_leader` after a fully agreeing node. -/
theorem agrees_becomeLeader (s₀ : State V S CAP) (m m' : Node V S N CAP)
    (hm : Agrees s₀ m.state m.snapshot_changed none) (hcm : Contig m.state) (hb : BecomeLeader m m') :
    AgreesN s₀ m' := by
  obtain ⟨h, n2, hB, rfl⟩ := hb
  exact agreesN_same s₀ _ _ (agrees_barrier s₀ (leaderInit m h) n2 hm hcm hB) (same_bcast n2)

/-- A campaign from a node with the checkpoint's log. -/
theorem agrees_campaigned (s₀ : State V S CAP) (n0 n' : Node V S N CAP) (t : Rust.u64) (h : n0.local.val < N)
    (hsn : n0.state.snapshot = s₀.snapshot) (hr : ret n0.state = ret s₀) (hc : Contig n0.state)
    (hC : Campaigned n0 t h n') : AgreesN s₀ n' := by
  obtain ⟨n1, hT, hcase⟩ := hC
  have hS : Same n0 n1 := (same_candidate n0 t h).trans (same_timers hT)
  have hfull : Agrees s₀ n1.state n1.snapshot_changed none :=
    agrees_of_log _ _ (hS.1.trans hsn) (hS.2.1.trans hr) _ _
  have hc1 : Contig n1.state := contig_congr _ _ hS.1 hS.2.1 hc
  rcases hcase with ⟨-, hB⟩ | ⟨-, rfl⟩
  · exact agrees_becomeLeader s₀ n1 n' hfull hc1 hB
  · exact agreesN_same s₀ _ _ (agrees_weaken _ _ _ hfull _) (same_requestVotes n1)

end Jarl.Engine.Host
