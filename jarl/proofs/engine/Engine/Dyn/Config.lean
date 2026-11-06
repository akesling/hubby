import Engine.Ghost

/-!
# Configurations of a dynamic log

The dynamic engine replicates `Record`s: application commands and
`Configuration` records. A log's configuration is its last configuration
record, or the genesis configuration when it has none (`cfgOf`). A
configuration's quorum is a strict majority of its voters and, when joint, of
its old voters too (`Quorum`, the meaning of `Membership::quorum`).

Quorums of unrelated configurations need not intersect. What the protocol
guarantees is narrower: each configuration record is one `Step` from the
configuration before it, and every configuration one step from `C` (or `C`
itself) has a component equal to `C`'s voters, so quorums of any two such
configurations intersect (`near_inter`).
-/

namespace Jarl.Engine.Dyn
open Jarl Jarl.Engine

variable {V : Type} {MAX : Nat}

/-- The configuration a record carries (the cluster's membership hook). -/
def recCfg : Option (Record V MAX) → Option (Membership MAX)
  | some (.Configuration m) => some m
  | _ => none

/-- Whether an entry carries a configuration. -/
def isCfg (e : Entry (Record V MAX)) : Prop := (recCfg e.value).isSome

instance (e : Entry (Record V MAX)) : Decidable (isCfg e) := by unfold isCfg; infer_instance

/-- The configuration of a log: its last configuration record, else `g`. -/
def cfgOf (g : Membership MAX) (l : List (Entry (Record V MAX))) : Membership MAX :=
  l.foldl (fun c e => (recCfg e.value).getD c) g

@[simp] theorem cfgOf_nil (g : Membership MAX) : cfgOf g ([] : List (Entry (Record V MAX))) = g := rfl

theorem cfgOf_append (g : Membership MAX) (l r : List (Entry (Record V MAX))) :
    cfgOf g (l ++ r) = cfgOf (cfgOf g l) r := by
  simp [cfgOf, List.foldl_append]

theorem cfgOf_snoc (g : Membership MAX) (l : List (Entry (Record V MAX))) (e : Entry (Record V MAX)) :
    cfgOf g (l ++ [e]) = (recCfg e.value).getD (cfgOf g l) := by
  simp [cfgOf, List.foldl_append]

/-- A log with no configuration record keeps the configuration before it. -/
theorem cfgOf_noCfg (g : Membership MAX) (l : List (Entry (Record V MAX))) (h : ∀ e ∈ l, ¬ isCfg e) :
    cfgOf g l = g := by
  induction l generalizing g with
  | nil => rfl
  | cons e l ih =>
    have he := h e (by simp)
    simp only [isCfg, Option.isSome_iff_ne_none, ne_eq, Decidable.not_not] at he
    simp only [cfgOf, List.foldl_cons, he, Option.getD_none]
    exact ih g (fun x hx => h x (by simp [hx]))

theorem cfgOf_take_succ (g : Membership MAX) (l : List (Entry (Record V MAX))) (i : Nat) (hi : i < l.length) :
    cfgOf g (l.take (i + 1)) = (recCfg l[i].value).getD (cfgOf g (l.take i)) := by
  rw [List.take_add_one, List.getElem?_eq_getElem hi]
  exact cfgOf_snoc g _ _

/-- The configuration of a log whose suffix after `i` holds no configuration record. -/
theorem cfgOf_take_noCfg (g : Membership MAX) (l : List (Entry (Record V MAX))) (i n : Nat) (hin : i ≤ n)
    (h : ∀ k (hk : k < l.length), i ≤ k → k < n → ¬ isCfg l[k]) : cfgOf g (l.take n) = cfgOf g (l.take i) := by
  have : l.take n = (l.take n).take i ++ (l.take n).drop i := (List.take_append_drop _ _).symm
  rw [this, List.take_take, Nat.min_eq_left hin, cfgOf_append]
  apply cfgOf_noCfg
  intro e he
  rw [List.mem_iff_getElem] at he
  obtain ⟨k, hk, rfl⟩ := he
  simp only [List.length_drop, List.length_take] at hk
  simp only [List.getElem_drop, List.getElem_take]
  exact h (i + k) (by omega) (by omega) (by omega)

/-! ## Quorums -/

/-- A strict majority of the list `l` (counted with multiplicity) satisfies `P`. -/
noncomputable def Maj (l : List Id) (P : Id → Prop) : Prop :=
  l.length / 2 < l.countP (fun x => @decide (P x) (Classical.propDecidable _))

/-- `Membership::quorum`: a strict majority of the voters and, when joint, of the old voters. -/
noncomputable def Quorum (m : Membership MAX) (P : Id → Prop) : Prop :=
  Maj m.voters P ∧ (m.is_joint = true → Maj m.old_voters P)

theorem maj_perm (l l' : List Id) (hp : l.Perm l') (P : Id → Prop) (h : Maj l P) : Maj l' P := by
  unfold Maj at *
  rw [← hp.length_eq, ← hp.countP_eq]; exact h

theorem maj_mono (l : List Id) (P Q : Id → Prop) (hpq : ∀ x, P x → Q x) (h : Maj l P) : Maj l Q := by
  unfold Maj at *
  have : l.countP (fun x => @decide (P x) (Classical.propDecidable _)) ≤
      l.countP (fun x => @decide (Q x) (Classical.propDecidable _)) := by
    apply List.countP_mono_left
    intro x _ hx; simp only [decide_eq_true_eq] at hx ⊢; exact hpq x hx
  omega

theorem quorum_mono (m : Membership MAX) (P Q : Id → Prop) (hpq : ∀ x, P x → Q x) (h : Quorum m P) :
    Quorum m Q :=
  ⟨maj_mono _ P Q hpq h.1, fun hj => maj_mono _ P Q hpq (h.2 hj)⟩

/-- Two strict majorities of one list share a member. -/
theorem maj_inter (l : List Id) (P Q : Id → Prop) (hp : Maj l P) (hq : Maj l Q) : ∃ x ∈ l, P x ∧ Q x := by
  apply Classical.byContradiction
  intro hn
  have hd : ∀ x ∈ l, ¬ (@decide (P x) (Classical.propDecidable _) = true ∧
      @decide (Q x) (Classical.propDecidable _) = true) := by
    intro x hx ⟨a, b⟩; exact hn ⟨x, hx, by simpa using a, by simpa using b⟩
  have := countP_disjoint l _ _ hd
  unfold Maj at hp hq
  omega

/-! ## Configuration steps -/

/-- One configuration change from `C`: keep `C`'s voters as the voters
    (`with_learners`, `finalized`) or as the old voters of a joint
    configuration (`joint`). -/
def Step (C X : Membership MAX) : Prop :=
  X.voters.Perm C.voters ∨ (X.is_joint = true ∧ X.old_voters.Perm C.voters)

/-- `C` itself or one change from it. -/
def Near (C X : Membership MAX) : Prop := X = C ∨ Step C X

/-- A quorum of a configuration near `C` contains a majority of `C`'s voters. -/
theorem near_maj (C X : Membership MAX) (h : Near C X) (P : Id → Prop) (hq : Quorum X P) : Maj C.voters P := by
  rcases h with rfl | hs | ⟨hj, hs⟩
  · exact hq.1
  · exact maj_perm _ _ hs P hq.1
  · exact maj_perm _ _ hs P (hq.2 hj)

/-- Quorums of two configurations near the same `C` intersect. -/
theorem near_inter (C X Y : Membership MAX) (hx : Near C X) (hy : Near C Y) (P Q : Id → Prop)
    (hp : Quorum X P) (hq : Quorum Y Q) : ∃ x, P x ∧ Q x := by
  obtain ⟨x, -, a, b⟩ := maj_inter _ P Q (near_maj C X hx P hp) (near_maj C Y hy Q hq)
  exact ⟨x, a, b⟩

end Jarl.Engine.Dyn
