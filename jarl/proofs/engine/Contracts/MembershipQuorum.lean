import Contracts.MembershipReconfig

/-!
# Membership contracts: `quorum` and `quorum_index`

The deep embedding lowered the `FnMut` callbacks of `quorum`/`quorum_index` to
an interaction protocol. The typed translation takes the callback as a Lean
function `Id → Rust.M _`, so the contracts quantify over it directly: an
arbitrary (possibly panicking or diverging) callback for the execution-shape
and congruence theorems, and a normally returning one (`a id = pure (g id)`)
for the result theorems.
-/

namespace Jarl.Contracts.Membership
open Jarl

variable {MAX : Nat}

theorem bind_congr_pure {α β : Type} (x : Rust.M α) (f g : α → Rust.M β) (h : ∀ a, x = pure a → f a = g a) :
    x >>= f = x >>= g := by
  rcases hx : x.run with _ | (e | a)
  · apply ExceptT.ext; simp [ExceptT.run_bind, hx]
  · apply ExceptT.ext; simp [ExceptT.run_bind, hx]
  · have hp : x = pure a := by apply ExceptT.ext; rw [hx]; rfl
    rw [hp, pure_bind, pure_bind, h a hp]

theorem filterAuxM_sublist {α : Type} (p : α → Rust.M Bool) (l acc r : List α)
    (h : List.filterAuxM p l acc = pure r) : ∃ c : List α, c.Sublist l ∧ r = c.reverse ++ acc := by
  induction l generalizing acc with
  | nil => simp only [List.filterAuxM] at h; exact ⟨[], List.Sublist.slnil, by simpa using (Rust.pure_inj h).symm⟩
  | cons x xs ih =>
    simp only [List.filterAuxM] at h
    obtain ⟨b, _, h2⟩ := Rust.bind_eq_pure h
    obtain ⟨c, hc, hr⟩ := ih _ h2
    cases b
    · exact ⟨c, hc.cons x, by simpa using hr⟩
    · exact ⟨x :: c, hc.cons_cons x, by simp [hr]⟩

theorem filterM_sublist {α : Type} (p : α → Rust.M Bool) (l c : List α) (h : l.filterM p = pure c) :
    c.Sublist l := by
  unfold List.filterM at h
  obtain ⟨r, h1, h2⟩ := Rust.bind_eq_pure h
  obtain ⟨c', hc', hr⟩ := filterAuxM_sublist p l [] r h1
  have := Rust.pure_inj h2
  rw [← this, hr]; simpa using hc'

theorem filterM_congr {α : Type} (l : List α) (p q : α → Rust.M Bool) (h : ∀ x ∈ l, p x = q x) :
    l.filterM p = l.filterM q := by
  have aux : ∀ (l : List α) acc, (∀ x ∈ l, p x = q x) → List.filterAuxM p l acc = List.filterAuxM q l acc := by
    intro l
    induction l with
    | nil => intro acc _; rfl
    | cons x xs ih =>
      intro acc hx
      simp only [List.filterAuxM, hx x (by simp)]
      congr 1; funext b; exact ih _ (fun y hy => hx y (by simp [hy]))
  unfold List.filterM; rw [aux l [] h]

theorem forIn_congr_mem {α β : Type} (l : List α) (b : β) (f g : α → β → Rust.M (ForInStep β))
    (h : ∀ x ∈ l, ∀ c, f x c = g x c) : forIn l b f = forIn l b g := by
  induction l generalizing b with
  | nil => rfl
  | cons x xs ih =>
    rw [List.forIn_cons, List.forIn_cons, h x (by simp) b]
    congr 1; funext r
    cases r with
    | done _ => rfl
    | yield c => exact ih c (fun y hy => h y (by simp [hy]))

def curM (m : Jarl.Membership MAX) : List Member := (occ m).filter (fun s => s.voter)
def oldM (m : Jarl.Membership MAX) : List Member := (occ m).filter (fun s => s.old)

theorem curM_length (m : Jarl.Membership MAX) : (curM m).length ≤ MAX := by
  have h1 : (curM m).length ≤ (occ m).length := List.length_filter_le _ _
  have h2 := keys_length m
  simp only [Keys, List.length_map] at h2
  omega

theorem oldM_length (m : Jarl.Membership MAX) : (oldM m).length ≤ MAX := by
  have h1 : (oldM m).length ≤ (occ m).length := List.length_filter_le _ _
  have h2 := keys_length m
  simp only [Keys, List.length_map] at h2
  omega

theorem count_gt (c l : List Member) (hc : c.length < 2 ^ 64) (hl : l.length < 2 ^ 64) :
    decide (Rust.Iter.count c > Rust.divK (Rust.Iter.count l) 2) = decide (l.length / 2 < c.length) := by
  simp only [Rust.Iter.count, Rust.divK, Rust.ofNat, gt_iff_lt, Fin.lt_def]
  rw [Nat.mod_eq_of_lt hc, Nat.mod_eq_of_lt hl]

theorem quorum_execution (m : Jarl.Membership MAX) (a : Id → Rust.M Bool) (hMAX : MAX < 2 ^ 64) :
    m.quorum a = (do
      let c ← (curM m).filterM (fun s => a s.id)
      if (curM m).length / 2 < c.length then
        if m.is_joint then do
          let c' ← (oldM m).filterM (fun s => a s.id)
          pure (decide ((oldM m).length / 2 < c'.length))
        else pure true
      else pure false) := by
  unfold Jarl.Membership.quorum
  simp only [bind_assoc, pure_bind, Bool.false_eq_true, if_false, if_true, Bool.not_not]
  simp only [show List.filter (fun m => m.voter) (Rust.Iter.flatten m.members.toList) = curM m from rfl,
    show List.filter (fun m => m.old) (Rust.Iter.flatten m.members.toList) = oldM m from rfl]
  apply bind_congr_pure
  intro c hc
  have hcl := (filterM_sublist _ _ _ hc).length_le
  have := curM_length m
  rw [count_gt c (curM m) (by omega) (by omega)]
  simp only [decide_eq_true_eq]
  split
  · split
    · apply bind_congr_pure
      intro c' hc'
      have hcl' := (filterM_sublist _ _ _ hc').length_le
      have := oldM_length m
      rw [count_gt c' (oldM m) (by omega) (by omega)]
    · rfl
  · rfl
def collect (matched : Id → Rust.M Rust.u64) (L : List Id) (P : Vector Rust.u64 MAX) :
    Rust.M (Vector Rust.u64 MAX × Rust.usize) :=
  forIn L (P, (0 : Rust.usize)) fun id s => do
    let t1 ← matched id
    let t2 ← Rust.Slice.set s.1 s.2 t1
    let t3 ← Rust.add s.2 1
    pure (ForInStep.yield (t2, t3))

def select (P : Vector Rust.u64 MAX) (c : Rust.usize) : Rust.M (Vector Rust.u64 MAX × Rust.u64) := do
  let t4 ← Rust.Slice.range P 0 c
  let t5 ← Rust.add (Rust.divK c 2) 1
  let t6 ← Rust.sub c t5
  let t7 ← Rust.Slice.index (Rust.Slice.setRange P 0 (Rust.Slice.sort_unstable t4)) t6
  pure (Rust.Slice.setRange P 0 (Rust.Slice.sort_unstable t4), t7)

theorem quorum_index_structure (m : Jarl.Membership MAX) (matched : Id → Rust.M Rust.u64) :
    m.quorum_index matched = (do
      let s ← collect matched m.voters (Vector.replicate MAX 0)
      let n ← select s.1 s.2
      if !m.is_joint then pure n.2 else do
        let s2 ← collect matched m.old_voters n.1
        let o ← select s2.1 s2.2
        pure (Rust.min n.2 o.2)) := by
  unfold Jarl.Membership.quorum_index collect select
  simp only [bind_assoc, pure_bind]

theorem fail_ne_pure {α : Type} (msg : String) (r : α) : (Rust.fail msg : Rust.M α) ≠ pure r := by
  intro h; have := congrArg ExceptT.run h; simp [Rust.fail] at this

/-! ## `quorum` -/

namespace Quorum

/-- Strict majority of `voters` satisfying `answer`. -/
def Majority (answer : Id → Bool) (voters : List Id) : Prop :=
  voters.length / 2 < voters.countP answer

instance (answer : Id → Bool) (voters : List Id) : Decidable (Majority answer voters) :=
  inferInstanceAs (Decidable (_ < _))

theorem voters_eq (m : Jarl.Membership MAX) : m.voters = (curM m).map Member.id := rfl
theorem old_voters_eq (m : Jarl.Membership MAX) : m.old_voters = (oldM m).map Member.id := rfl

/-- For any callback, `quorum` asks about the current voters (in slot order),
    stops with `false` without a strict current majority, and otherwise, when
    joint, asks about the old voters too and reports their strict majority. -/
theorem execution (m : Jarl.Membership MAX) (a : Id → Rust.M Bool) (hMAX : MAX < 2 ^ 64) :
    m.quorum a = (do
      let c ← (curM m).filterM (fun s => a s.id)
      if (curM m).length / 2 < c.length then
        if m.is_joint then do
          let c' ← (oldM m).filterM (fun s => a s.id)
          pure (decide ((oldM m).length / 2 < c'.length))
        else pure true
      else pure false) :=
  quorum_execution m a hMAX

theorem stable_execution (m : Jarl.Membership MAX) (a : Id → Rust.M Bool) (hMAX : MAX < 2 ^ 64)
    (stable : m.is_joint = false) :
    m.quorum a = (do
      let c ← (curM m).filterM (fun s => a s.id)
      pure (decide ((curM m).length / 2 < c.length))) := by
  rw [execution m a hMAX]
  congr 1; funext c
  by_cases h : (curM m).length / 2 < c.length <;> simp [h, stable]

/-- With no current voters, `quorum` reports `false` without calling the callback. -/
theorem empty_current (m : Jarl.Membership MAX) (a : Id → Rust.M Bool) (hMAX : MAX < 2 ^ 64)
    (empty : m.voters = []) : m.quorum a = pure false := by
  have h : curM m = [] := by simpa [voters_eq] using empty
  rw [execution m a hMAX, h]
  simp [List.filterM, List.filterAuxM]

/-- The callback is consulted only on current and old voters. -/
theorem response_budget (m : Jarl.Membership MAX) (a b : Id → Rust.M Bool) (hMAX : MAX < 2 ^ 64)
    (current : ∀ id ∈ m.voters, a id = b id) (old : ∀ id ∈ m.old_voters, a id = b id) :
    m.quorum a = m.quorum b := by
  rw [execution m a hMAX, execution m b hMAX,
    filterM_congr (curM m) _ (fun s => b s.id) (fun s hs => current s.id (by rw [voters_eq]; exact List.mem_map_of_mem hs)),
    filterM_congr (oldM m) _ (fun s => b s.id) (fun s hs => old s.id (by rw [old_voters_eq]; exact List.mem_map_of_mem hs))]

/-- Under a normally returning callback reporting `answer`, `quorum` reports
    exactly a strict majority of current voters and, when joint, of old voters. -/
theorem result (m : Jarl.Membership MAX) (a : Id → Rust.M Bool) (answer : Id → Bool) (hMAX : MAX < 2 ^ 64)
    (normal : ∀ id, a id = pure (answer id)) :
    m.quorum a = pure (decide (Majority answer m.voters ∧
      (m.is_joint = true → Majority answer m.old_voters))) := by
  rw [execution m a hMAX, Rust.filterM_pure (curM m) _ (fun s => answer s.id) (fun s _ => normal s.id), pure_bind,
    Rust.filterM_pure (oldM m) _ (fun s => answer s.id) (fun s _ => normal s.id)]
  have hc : ((curM m).filter (fun s => answer s.id)).length = m.voters.countP answer := by
    rw [voters_eq, List.countP_map, List.countP_eq_length_filter]; rfl
  have ho : ((oldM m).filter (fun s => answer s.id)).length = m.old_voters.countP answer := by
    rw [old_voters_eq, List.countP_map, List.countP_eq_length_filter]; rfl
  have lc : (curM m).length = m.voters.length := by simp [voters_eq]
  have lo : (oldM m).length = m.old_voters.length := by simp [old_voters_eq]
  simp only [pure_bind]
  rw [hc, ho, lc, lo]
  unfold Majority
  by_cases h1 : m.voters.length / 2 < m.voters.countP answer
  · cases hj : m.is_joint <;> simp [h1]
  · simp [h1]

/-- Under normally returning callbacks, `quorum` completes. -/
theorem observation_complete (m : Jarl.Membership MAX) (a : Id → Rust.M Bool) (hMAX : MAX < 2 ^ 64)
    (normal : ∀ id, ∃ r, a id = pure r) : ∃ r, m.quorum a = pure r :=
  ⟨_, result m a (fun id => Classical.choose (normal id)) hMAX (fun id => Classical.choose_spec (normal id))⟩

private theorem countP_or_and (p q : Id → Bool) (values : List Id) :
    values.countP p + values.countP q =
      values.countP (fun v => p v || q v) + values.countP (fun v => p v && q v) := by
  induction values with
  | nil => rfl
  | cons head rest ih =>
    simp only [List.countP_cons]
    cases p head <;> cases q head <;> simp <;> omega

/-- Two strict majorities of one list share a member. -/
theorem majorities_intersect (first second : Id → Bool) (values : List Id)
    (one : Majority first values) (two : Majority second values) :
    ∃ value ∈ values, first value = true ∧ second value = true := by
  unfold Majority at one two
  have sum := countP_or_and first second values
  have bounded : values.countP (fun v => first v || second v) ≤ values.length := List.countP_le_length
  have shared : 0 < values.countP (fun v => first v && second v) := by omega
  obtain ⟨value, member, both⟩ := List.countP_pos_iff.mp shared
  simp only [Bool.and_eq_true] at both
  exact ⟨value, member, both⟩

/-- Quorum intersection for the translated `Membership::quorum`: any two
    normally returning callbacks that both obtain a quorum agree on some
    current voter and, in a joint configuration, on some old voter. -/
theorem quorums_intersect (m : Jarl.Membership MAX) (a1 a2 : Id → Rust.M Bool) (first second : Id → Bool)
    (hMAX : MAX < 2 ^ 64) (n1 : ∀ id, a1 id = pure (first id)) (n2 : ∀ id, a2 id = pure (second id))
    (q1 : m.quorum a1 = pure true) (q2 : m.quorum a2 = pure true) :
    (∃ voter ∈ m.voters, first voter = true ∧ second voter = true) ∧
      (m.is_joint = true → ∃ voter ∈ m.old_voters, first voter = true ∧ second voter = true) := by
  rw [result m a1 first hMAX n1] at q1
  rw [result m a2 second hMAX n2] at q2
  have h1 := Rust.pure_inj q1
  have h2 := Rust.pure_inj q2
  simp only [decide_eq_true_eq] at h1 h2
  exact ⟨majorities_intersect first second _ h1.1 h2.1,
    fun j => majorities_intersect first second _ (h1.2 j) (h2.2 j)⟩

end Quorum

/-! ## `quorum_index` -/

namespace QuorumIndex

/-- The value `quorum_index` selects from one configuration's positions: the
    element at index `n - (n / 2 + 1)` of their ascending order. -/
def rank (vals : List Rust.u64) : Rust.u64 :=
  (vals.mergeSort (fun a b => decide (a.val ≤ b.val))).getD (vals.length - (vals.length / 2 + 1)) 0

/-- A strict majority of `voters` has acknowledged at least position `x`. -/
def MajorityAt (matched : Id → Rust.u64) (voters : List Id) (x : Rust.u64) : Prop :=
  voters.length / 2 < (voters.map matched).countP (fun v => decide (x.val ≤ v.val))

theorem collect_normal (a : Id → Rust.M Rust.u64) (h : Id → Rust.u64) (L : List Id)
    (normal : ∀ id ∈ L, a id = pure (h id)) (P0 : Vector Rust.u64 MAX) (hL : L.length ≤ MAX) (hMAX : MAX < 2 ^ 64) :
    ∃ P, collect a L P0 = pure (P, Rust.usizeOf L.length) ∧ P.toList.take L.length = L.map h := by
  unfold collect
  obtain ⟨b, hb, hb1, hb2⟩ := Rust.forIn_inv L (P0, (0 : Rust.usize))
    (fun id (s : Vector Rust.u64 MAX × Rust.usize) => do
      let t1 ← a id
      let t2 ← Rust.Slice.set s.1 s.2 t1
      let t3 ← Rust.add s.2 1
      pure (ForInStep.yield (t2, t3)))
    (fun k b => b.2.val = k ∧ b.1.toList.take k = (L.take k).map h) ⟨rfl, by simp⟩ (by
      intro k hk b ⟨hb1, hb2⟩
      have hset : b.2.val < MAX := by omega
      refine ⟨(b.1.set b.2.val (h L[k]) hset, ⟨k + 1, by omega⟩), ?_, rfl, ?_⟩
      · simp only [normal L[k] (List.getElem_mem hk), pure_bind, Rust.Slice.set_ok _ _ _ hset]
        rw [Rust.add_ok _ _ (by show b.2.val + 1 < 2 ^ 64; omega)]
        subst hb1; rfl
      · show (b.1.set b.2.val (h L[k]) hset).toList.take (k + 1) = _
        rw [Vector.toList_set, hb1]
        have hk' : k < b.1.toList.length := by simp; omega
        rw [List.take_add_one, List.take_add_one, List.take_set_of_le (by omega), hb2,
          List.getElem?_set_self hk', List.getElem?_eq_getElem hk]
        simp only [Option.toList_some, List.map_append, List.map_cons, List.map_nil])
  refine ⟨b.1, ?_, by simpa using hb2⟩
  rw [hb]
  congr 1
  exact Prod.ext rfl (Fin.ext (by rw [Rust.val_usizeOf _ (by omega)]; exact hb1))

theorem collect_congr (a b : Id → Rust.M Rust.u64) (L : List Id) (P : Vector Rust.u64 MAX)
    (h : ∀ id ∈ L, a id = b id) : collect a L P = collect b L P := by
  unfold collect
  apply forIn_congr_mem
  intro x hx c
  simp only [h x hx]

private theorem le_total' : ∀ (a b : Rust.u64), (decide (a.val ≤ b.val) || decide (b.val ≤ a.val)) = true := by
  intro a b; simp; omega

private theorem le_trans' : ∀ (a b c : Rust.u64), decide (a.val ≤ b.val) = true → decide (b.val ≤ c.val) = true →
    decide (a.val ≤ c.val) = true := by
  intro a b c h1 h2; simp at *; omega

theorem rank_eq (vals : List Rust.u64) (hne : vals ≠ []) :
    ∃ hp : vals.length - (vals.length / 2 + 1) < (vals.mergeSort (fun a b => decide (a.val ≤ b.val))).length,
      rank vals = (vals.mergeSort (fun a b => decide (a.val ≤ b.val)))[vals.length - (vals.length / 2 + 1)] := by
  have hl : 0 < vals.length := List.length_pos_iff.mpr hne
  have hp : vals.length - (vals.length / 2 + 1) < (vals.mergeSort (fun a b => decide (a.val ≤ b.val))).length := by
    rw [List.length_mergeSort]; omega
  exact ⟨hp, by rw [rank, List.getD_eq_getElem?_getD, List.getElem?_eq_getElem hp]; rfl⟩

/-- The selected position is exactly the greatest value acknowledged by a strict majority. -/
theorem rank_majority (vals : List Rust.u64) (hne : vals ≠ []) (x : Rust.u64) :
    x.val ≤ (rank vals).val ↔ vals.length / 2 < vals.countP (fun v => decide (x.val ≤ v.val)) := by
  obtain ⟨hp, hr⟩ := rank_eq vals hne
  rw [hr]
  generalize hs : vals.mergeSort (fun a b => decide (a.val ≤ b.val)) = s at hp
  have hperm : s.Perm vals := hs ▸ List.mergeSort_perm vals _
  have hsorted : s.Pairwise (fun a b => a.val ≤ b.val) := by
    have := List.pairwise_mergeSort le_trans' le_total' vals
    rw [hs] at this; simpa using this
  have hsl : s.length = vals.length := hperm.length_eq
  rw [← hperm.countP_eq]
  generalize hn : vals.length = n at hp hsl
  have hn1 : 0 < n := by rw [← hn]; exact List.length_pos_iff.mpr hne
  generalize hq : n - (n / 2 + 1) = p at hp
  have below : ∀ (j : Nat) (hj : j < s.length), j ≤ p → s[j].val ≤ s[p].val := by
    intro j hj hjp
    rcases Nat.lt_or_eq_of_le hjp with hlt | rfl
    · exact List.pairwise_iff_getElem.mp hsorted j p hj hp hlt
    · exact Nat.le_refl _
  constructor
  · intro hx
    have hsub : (s.drop p).Sublist s := List.drop_sublist _ _
    have hall : ∀ y ∈ s.drop p, decide (x.val ≤ y.val) = true := by
      intro y hy
      obtain ⟨j, hj, rfl⟩ := List.mem_iff_getElem.mp hy
      simp only [List.getElem_drop, decide_eq_true_eq]
      by_cases hj0 : j = 0
      · subst hj0; simpa using hx
      · have := List.pairwise_iff_getElem.mp hsorted p (p + j) hp (by simp at hj; omega) (by omega)
        omega
    have h1 := hsub.countP_le (p := fun y => decide (x.val ≤ y.val))
    rw [List.countP_eq_length.mpr hall, List.length_drop] at h1
    omega
  · intro hc
    apply Decidable.by_contra
    intro hx
    have hx' : s[p].val < x.val := by omega
    have htake : (s.take (p + 1)).countP (fun y => decide (x.val ≤ y.val)) = 0 := by
      rw [List.countP_eq_zero]
      intro y hy
      obtain ⟨j, hj, rfl⟩ := List.mem_iff_getElem.mp hy
      simp only [List.getElem_take, decide_eq_true_eq, Nat.not_le]
      have := below j (by simp at hj; omega) (by simp at hj; omega)
      omega
    have hsplit := List.countP_append (p := fun y => decide (x.val ≤ y.val)) (l₁ := s.take (p + 1))
      (l₂ := s.drop (p + 1))
    rw [List.take_append_drop, htake, Nat.zero_add] at hsplit
    have hle : (s.drop (p + 1)).countP (fun y => decide (x.val ≤ y.val)) ≤ (s.drop (p + 1)).length :=
      List.countP_le_length
    rw [List.length_drop] at hle
    omega

theorem setRange_get {α : Type} (P : Vector α MAX) (arr : Array α) (j : Nat) (hj : j < MAX) (ha : j < arr.size) :
    (Rust.Slice.setRange P 0 arr)[j] = arr[j] := by
  simp only [Rust.Slice.setRange, Vector.getElem_ofFn]
  rw [dif_pos (by simp; omega)]
  simp

theorem select_rank (P : Vector Rust.u64 MAX) (vals : List Rust.u64) (hP : P.toList.take vals.length = vals)
    (hne : vals ≠ []) (hnM : vals.length ≤ MAX) (hMAX : MAX < 2 ^ 64) :
    ∃ P', select P (Rust.usizeOf vals.length) = pure (P', rank vals) := by
  have hn1 : 0 < vals.length := List.length_pos_iff.mpr hne
  have h64 : vals.length < 2 ^ 64 := by omega
  have hv : (Rust.usizeOf vals.length).val = vals.length := Rust.val_usizeOf _ h64
  have hdiv : (Rust.divK (Rust.usizeOf vals.length) 2).val = vals.length / 2 := by simp [Rust.divK, hv]
  have hext : ∀ c, c = vals.length → (P.toArray.extract 0 c).toList = vals := by
    intro c hc; subst hc
    rw [Array.toList_extract, List.extract_eq_take_drop, List.drop_zero, Nat.sub_zero]; exact hP
  have key : ∀ c, c = vals.length → ∀ (j : Nat) (hj : j < MAX), j = vals.length - (vals.length / 2 + 1) →
      (Rust.Slice.setRange P 0 (Rust.Slice.sort_unstable (P.toArray.extract 0 c)))[j] = rank vals := by
    intro c hc j hj hjv
    obtain ⟨hp, hr⟩ := rank_eq vals hne
    have hsz : (Rust.Slice.sort_unstable (P.toArray.extract 0 c)).size = vals.length := by
      simp only [Rust.Slice.sort_unstable, List.size_toArray, List.length_mergeSort]
      rw [hext c hc]
    rw [setRange_get _ _ _ hj (by omega), hr]
    simp only [Rust.Slice.sort_unstable, List.getElem_toArray]
    subst hjv
    congr 1
    rw [hext c hc]
  unfold select
  rw [Rust.Slice.range_ok _ _ _ (by simp [hv]; omega), pure_bind]
  rw [Rust.add_ok _ _ (by rw [hdiv]; simp; omega), pure_bind]
  rw [Rust.sub_ok _ _ (by simp [hdiv, hv]; omega), pure_bind]
  rw [Rust.Slice.index_ok _ _ (by simp [hdiv, hv]; omega), pure_bind]
  refine ⟨_, congrArg pure (Prod.ext rfl ?_)⟩
  apply key _ hv
  simp [hdiv, hv]

theorem select_zero (P : Vector Rust.u64 MAX) :
    select P 0 = Rust.fail "attempt to subtract with overflow" := by
  unfold select
  rw [Rust.Slice.range_ok _ _ _ (by simp), pure_bind]
  rw [Rust.add_ok _ _ (by simp [Rust.divK]), pure_bind]
  simp [Rust.sub, Rust.divK, Rust.fail]

/-- With no current voters `quorum_index` panics (Rust: `0 - 1` overflow),
    whatever the callback. -/
theorem empty_current (m : Jarl.Membership MAX) (a : Id → Rust.M Rust.u64) (empty : m.voters = []) :
    m.quorum_index a = Rust.fail "attempt to subtract with overflow" := by
  rw [quorum_index_structure]
  have : collect a m.voters (Vector.replicate MAX 0) = pure (Vector.replicate MAX 0, 0) := by
    rw [empty]; rfl
  rw [this, pure_bind]
  simp only [select_zero]
  simp [Rust.fail]

/-- Exact value under a normally returning callback reporting `matched`. -/
theorem exact (m : Jarl.Membership MAX) (a : Id → Rust.M Rust.u64) (matched : Id → Rust.u64)
    (hMAX : MAX < 2 ^ 64) (normal : ∀ id, a id = pure (matched id)) (nonempty : m.voters ≠ []) :
    m.quorum_index a = pure (if m.is_joint then
      Rust.min (rank (m.voters.map matched)) (rank (m.old_voters.map matched))
      else rank (m.voters.map matched)) := by
  rw [quorum_index_structure]
  obtain ⟨P, hP, hPt⟩ := collect_normal a matched m.voters (fun id _ => normal id) (Vector.replicate MAX 0)
    (SetInterpretation.voters_length_le m) hMAX
  rw [hP, pure_bind]
  obtain ⟨P', hP'⟩ := select_rank P (m.voters.map matched) (by simpa using hPt) (by simpa using nonempty)
    (by simpa using SetInterpretation.voters_length_le m) hMAX
  simp only [List.length_map] at hP'
  rw [hP', pure_bind]
  cases hj : m.is_joint
  · simp
  · have hold : m.old_voters ≠ [] := (SetInterpretation.joint_iff_old_nonempty m).mp hj
    have hol : m.old_voters.length ≤ MAX := by
      have := oldM_length m; simpa [Quorum.old_voters_eq] using this
    obtain ⟨Q, hQ, hQt⟩ := collect_normal a matched m.old_voters (fun id _ => normal id) P' hol hMAX
    simp only [Bool.not_true, Bool.false_eq_true, if_false]
    rw [hQ, pure_bind]
    obtain ⟨Q', hQ'⟩ := select_rank Q (m.old_voters.map matched) (by simpa using hQt) (by simpa using hold)
      (by simpa using hol) hMAX
    simp only [List.length_map] at hQ'
    rw [hQ', pure_bind]
    simp

/-- For a normally returning callback: panic exactly when there are no current
    voters, otherwise the exact rank value (the typed counterpart of the old
    protocol-lowering `execution`). -/
theorem execution (m : Jarl.Membership MAX) (a : Id → Rust.M Rust.u64) (matched : Id → Rust.u64)
    (hMAX : MAX < 2 ^ 64) (normal : ∀ id, a id = pure (matched id)) :
    m.quorum_index a = if m.voters = [] then Rust.fail "attempt to subtract with overflow" else
      pure (if m.is_joint then Rust.min (rank (m.voters.map matched)) (rank (m.old_voters.map matched))
        else rank (m.voters.map matched)) := by
  by_cases h : m.voters = []
  · rw [if_pos h]; exact empty_current m a h
  · rw [if_neg h]; exact exact m a matched hMAX normal h

theorem stable_execution (m : Jarl.Membership MAX) (a : Id → Rust.M Rust.u64) (matched : Id → Rust.u64)
    (hMAX : MAX < 2 ^ 64) (normal : ∀ id, a id = pure (matched id)) (stable : m.is_joint = false) :
    m.quorum_index a = if m.voters = [] then Rust.fail "attempt to subtract with overflow" else
      pure (rank (m.voters.map matched)) := by
  rw [execution m a matched hMAX normal, stable]; rfl

/-- The callback is consulted only on current and old voters. -/
theorem response_budget (m : Jarl.Membership MAX) (a b : Id → Rust.M Rust.u64)
    (current : ∀ id ∈ m.voters, a id = b id) (old : ∀ id ∈ m.old_voters, a id = b id) :
    m.quorum_index a = m.quorum_index b := by
  rw [quorum_index_structure, quorum_index_structure, collect_congr a b _ _ current]
  congr 1; funext s; congr 1; funext n
  split
  · rfl
  · rw [collect_congr a b _ _ old]

/-- With a nonempty current voter set, `quorum_index` completes under every
    normally returning callback; its panics are unreachable, since a joint
    configuration always has old voters. -/
theorem completes (m : Jarl.Membership MAX) (a : Id → Rust.M Rust.u64) (matched : Id → Rust.u64)
    (hMAX : MAX < 2 ^ 64) (normal : ∀ id, a id = pure (matched id)) (nonempty : m.voters ≠ []) :
    ∃ r, m.quorum_index a = pure r :=
  ⟨_, exact m a matched hMAX normal nonempty⟩

theorem observation_complete (m : Jarl.Membership MAX) (a : Id → Rust.M Rust.u64) (hMAX : MAX < 2 ^ 64)
    (normal : ∀ id, ∃ r, a id = pure r) (nonempty : m.voters ≠ []) : ∃ r, m.quorum_index a = pure r :=
  completes m a (fun id => Classical.choose (normal id)) hMAX (fun id => Classical.choose_spec (normal id)) nonempty

/-- The commit-rule meaning of `quorum_index`: under a normally returning
    callback reporting `matched`, a completed result is exactly the greatest
    position acknowledged by a strict majority of the current voters and, in a
    joint configuration, also by a strict majority of the old voters. -/
theorem result_majority (m : Jarl.Membership MAX) (a : Id → Rust.M Rust.u64) (matched : Id → Rust.u64)
    (hMAX : MAX < 2 ^ 64) (normal : ∀ id, a id = pure (matched id)) (r : Rust.u64)
    (completed : m.quorum_index a = pure r) (x : Rust.u64) :
    x.val ≤ r.val ↔ MajorityAt matched m.voters x ∧ (m.is_joint = true → MajorityAt matched m.old_voters x) := by
  have nonempty : m.voters ≠ [] := by
    intro h; rw [empty_current m a h] at completed; exact fail_ne_pure _ _ completed
  rw [exact m a matched hMAX normal nonempty] at completed
  have hr := Rust.pure_inj completed
  have cur := rank_majority (m.voters.map matched) (by simpa using nonempty) x
  simp only [List.length_map] at cur
  unfold MajorityAt
  cases hj : m.is_joint
  · simp only [hj, Bool.false_eq_true, if_false] at hr
    subst hr
    simp [cur]
  · simp only [hj, if_true] at hr
    subst hr
    have hold : m.old_voters ≠ [] := (SetInterpretation.joint_iff_old_nonempty m).mp hj
    have old := rank_majority (m.old_voters.map matched) (by simpa using hold) x
    simp only [List.length_map] at old
    rw [Rust.val_min, Nat.le_min, cur, old]
    simp

end QuorumIndex

end Jarl.Contracts.Membership
