import Refine
import Model
open Provium.State Provium.Imperative
set_option linter.unusedSimpArgs false
namespace Refine
open Jarl.ElectionSafety (Local Pending Durable)

/-! The election view of a node: what the model's `Local` records. -/

def roleOf : PureValue → Jarl.ElectionSafety.Role
  | .variant "Role" "Leader" [] => .leader
  | .variant "Role" "Candidate" [] => .candidate
  | _ => .follower

/-- The value of an optional vote. -/
def voteValue : Option Nat → PureValue
  | none => .absent
  | some x => .present (idv x)

/-- The members whose slot has granted. -/
def votesOf (ids : List Nat) (bs : List Bool) : List Nat := ((ids.zip bs).filter (·.2)).map (·.1)

/-- The election message a slot's descriptor stands for, if any. -/
def pendingOf (target : Nat) : PureValue → Option Pending
  | .present (.variant "Outbound" "Vote" []) => some (.vote target)
  | .present (.variant "Outbound" "Voted" [("0", .boolean g)]) => some (.voted target g)
  | .present (.variant "Outbound" "PreVote" [("0", .number _ c)]) => some (.prevote target c)
  | .present (.variant "Outbound" "PreVoted" [("0", .number _ c), ("1", .boolean g)]) =>
      some (.prevoted target c g)
  | _ => none

/-- The pending election messages of an outbox, in slot order. -/
def outboxOf (ids : List Nat) (os : List PureValue) : List Pending :=
  (ids.zip os).filterMap fun p => pendingOf p.1 p.2

/-- `L` is the election view of node `n` whose durable checkpoint is `disk`. -/
structure Abs (ids : List Nat) (n : Fields) (disk : Durable) (L : Local) : Prop where
  state : ∃ c sn en ln, n.state = statev (hardv L.term (voteValue L.vote) c) sn en ln
  role : roleOf n.role = L.role
  votes : ∃ bs, n.votes = boolsv bs ∧ ∀ x, x ∈ L.votes ↔ x ∈ votesOf ids bs
  dirty : n.dirty = .boolean false → L.dirty = false
  durable : L.durable = disk
  outbox : ∃ os, n.outbox = .array os ∧ L.outbox = outboxOf ids os
  prevoting : L.prevoting = none

theorem quiet_pending {v : PureValue} (q : Quiet v) (i : Nat) : pendingOf i v = none := by
  rcases q with rfl | ⟨_, _, rfl⟩ <;> rfl

/-- A settled outbox keeps a sublist of the pending election messages. -/
theorem outboxOf_settled : ∀ (ids : List Nat) (os os' : List PureValue), Settled os os' →
    (outboxOf ids os').Sublist (outboxOf ids os)
  | [], _, _, _ => by simp [outboxOf]
  | _, [], os', h => by
    have : os' = [] := List.length_eq_zero_iff.mp (by simpa using h.1)
    subst this; simp [outboxOf]
  | _, _ :: _, [], h => by simp [Settled] at h
  | i :: is, o :: rest, o' :: rest', h => by
    have tail : Settled rest rest' :=
      ⟨by simpa using h.1, fun k hk => by simpa using h.2 (k + 1) (by simpa using hk)⟩
    have ih := outboxOf_settled is rest rest' tail
    have head := h.2 0 (by simp)
    simp only [List.getElem?_cons_zero, Option.some.injEq] at head
    simp only [outboxOf, List.zip_cons_cons, List.filterMap_cons] at ih ⊢
    rcases head with rfl | ⟨v, rfl, q⟩
    · cases pendingOf i o' with
      | none => exact ih
      | some x => exact ih.cons_cons x
    · rw [quiet_pending q i]
      cases pendingOf i o with
      | none => exact ih
      | some x => exact ih.cons x

/-- A calm step keeps the election view, except that pending messages may be dropped. -/
theorem Abs.calm {ids : List Nat} {n n' : Fields} {disk : Durable} {L : Local} (a : Abs ids n disk L)
    (c : Calm n n') : ∃ kept, kept.Sublist L.outbox ∧ Abs ids n' disk { L with outbox := kept } := by
  obtain ⟨os, ho, hL⟩ := a.outbox
  obtain ⟨os', ho', set⟩ := c.outbox os ho
  refine ⟨outboxOf ids os', hL ▸ outboxOf_settled ids os os' set, ?_⟩
  obtain ⟨cc, sn, en, ln, hs⟩ := a.state
  obtain ⟨cc', sn', en', ln', hs'⟩ := c.hard _ _ ⟨cc, sn, en, ln, hs⟩
  exact { state := ⟨cc', sn', en', ln', hs'⟩
          role := by rw [c.role]; exact a.role
          votes := by rw [c.votes]; exact a.votes
          dirty := fun h => by
            rcases c.dirty with e | e
            · rw [e] at h; exact a.dirty h
            · rw [e] at h; cases h
          durable := a.durable
          outbox := ⟨os', ho', rfl⟩
          prevoting := a.prevoting }

theorem votesOf_from (k : Nat) : ∀ (ids : List Nat) (s : Nat),
    ((ids.zip ((List.range' s ids.length).map (· == k))).filter (·.2)).map (·.1) =
      if s ≤ k then (ids[k - s]?).toList else []
  | [], s => by simp
  | x :: xs, s => by
    have ih := votesOf_from k xs (s + 1)
    simp only [List.length_cons, List.range'_succ, List.map_cons, List.zip_cons_cons, List.filter_cons]
    by_cases h : s = k
    · subst h
      simp only [beq_self_eq_true, ite_true, List.map_cons, ih]
      simp only [show ¬ (s + 1 ≤ s) by omega, ite_false, Nat.le_refl, Nat.sub_self, List.getElem?_cons_zero,
        Option.toList_some]
      simp
    · have hb : (s == k) = false := by simpa using h
      simp only [hb, Bool.false_eq_true, ite_false, ih]
      by_cases le : s ≤ k
      · have le' : s + 1 ≤ k := by omega
        simp only [le', ite_true, le]
        have : k - s = (k - (s + 1)) + 1 := by omega
        rw [this, List.getElem?_cons_succ]
      · simp [le, show ¬ (s + 1 ≤ k) by omega]

theorem votesOf_self (ids : List Nat) (k : Nat) (h : k < ids.length) :
    votesOf ids ((List.range ids.length).map (· == k)) = [ids[k]] := by
  unfold votesOf
  rw [List.range_eq_range', votesOf_from k ids 0]
  simp [List.getElem?_eq_getElem h]

/-- The outbox with vote requests from slot `s` on. -/
def voteFrom (k : Nat) : Nat → List PureValue → List PureValue
  | _, [] => []
  | s, o :: os => (if s = k then o else votev) :: voteFrom k (s + 1) os

theorem mapIdx_voteFrom (k : Nat) : ∀ (os : List PureValue) (s : Nat),
    os.mapIdx (fun i o => if i + s = k then o else votev) = voteFrom k s os
  | [], _ => rfl
  | o :: os, s => by
    rw [List.mapIdx_cons, voteFrom, Nat.zero_add]
    congr 1
    rw [← mapIdx_voteFrom k os (s + 1)]
    congr 1
    funext i o
    rw [show i + 1 + s = i + (s + 1) by omega]

theorem voteBox_from (os : List PureValue) (k : Nat) : voteBox os k = voteFrom k 0 os := by
  rw [voteBox, ← mapIdx_voteFrom k os 0]
  simp

theorem pendingOf_absent (x : Nat) : pendingOf x .absent = none := rfl
theorem pendingOf_vote (x : Nat) : pendingOf x votev = some (.vote x) := rfl

theorem outboxOf_voteFrom (k : Nat) : ∀ (ids : List Nat) (os : List PureValue) (s : Nat),
    os.length = ids.length → (∀ o ∈ os, o = .absent) →
    outboxOf ids (voteFrom k s os) = ((ids.zipIdx s).filter (·.2 ≠ k)).map (Pending.vote ·.1)
  | [], os, s, h, _ => by
    have : os = [] := List.length_eq_zero_iff.mp (by simpa using h)
    subst this; rfl
  | x :: xs, [], s, h, _ => by simp at h
  | x :: xs, o :: os, s, h, empty => by
    have ih := outboxOf_voteFrom k xs os (s + 1) (by simpa using h) (fun o' m => empty o' (by simp [m]))
    have ho : o = .absent := empty o (by simp)
    subst ho
    unfold outboxOf at ih ⊢
    rw [voteFrom, List.zip_cons_cons, List.filterMap_cons, List.zipIdx_cons, List.filter_cons, ih]
    by_cases hs : s = k
    · subst hs; simp only [ite_true, pendingOf_absent, ne_eq, not_true_eq_false, decide_false]; rfl
    · simp only [hs, ite_false, pendingOf_vote, ne_eq, not_false_eq_true, decide_true]
      simp

theorem filter_zipIdx_nodup (k : Nat) : ∀ (ids : List Nat) (s : Nat), ids.Nodup → s ≤ k → k < s + ids.length →
    ((ids.zipIdx s).filter (·.2 ≠ k)).map (Pending.vote ·.1) =
      (ids.filter (· ≠ ids[k - s]!)).map Pending.vote
  | [], s, _, le, h => by simp at h; omega
  | x :: xs, s, nd, le, lt => by
    have hx : x ∉ xs := (List.nodup_cons.mp nd).1
    simp only [List.zipIdx_cons, List.filter_cons]
    by_cases hs : s = k
    · subst hs
      have keep : ((xs.zipIdx (s + 1)).filter (fun p => decide (p.2 ≠ s))) = xs.zipIdx (s + 1) := by
        rw [List.filter_eq_self]
        intro p hp
        have := List.le_snd_of_mem_zipIdx hp
        simp only [ne_eq, decide_eq_true_eq]; omega
      have drop : (xs.filter (· ≠ x)) = xs := by
        rw [List.filter_eq_self]
        intro y hy
        simp only [ne_eq, decide_eq_true_eq]
        intro e; subst e; exact hx hy
      simp only [ne_eq, not_true_eq_false, decide_false, Bool.false_eq_true, ite_false, Nat.sub_self,
        List.getElem!_cons_zero, decide_true, ite_true]
      simp only [ne_eq] at keep drop
      rw [keep, drop]
      conv => rhs; rw [← List.zipIdx_map_fst (s + 1) xs]
      rw [List.map_map]
      rfl
    · have hlt : s + 1 ≤ k := by omega
      have ih := filter_zipIdx_nodup k xs (s + 1) (List.nodup_cons.mp nd).2 hlt (by simp at lt; omega)
      have idx : (x :: xs)[k - s]! = xs[k - (s + 1)]! := by
        rw [show k - s = (k - (s + 1)) + 1 by omega]
        simp
      have hne : x ≠ xs[k - (s + 1)]! := by
        intro e
        apply hx
        rw [e, List.getElem!_eq_getElem?_getD, List.getElem?_eq_getElem (by simp at lt; omega)]
        exact List.getElem_mem _
      simp only [ne_eq, hs, not_false_eq_true, decide_true, ite_true, List.map_cons, idx, List.filter_cons,
        hne, decide_true]
      simp only [ne_eq] at ih
      rw [ih]

theorem outboxOf_voteBox (ids : List Nat) (os : List PureValue) (k : Nat) (sized : os.length = ids.length)
    (unique : ids.Nodup) (hk : k < ids.length) (empty : ∀ o ∈ os, o = .absent) :
    outboxOf ids (voteBox os k) = (ids.filter (· ≠ ids[k])).map Pending.vote := by
  rw [voteBox_from, outboxOf_voteFrom k ids os 0 sized empty, filter_zipIdx_nodup k ids 0 unique (Nat.zero_le _)
    (by omega)]
  simp [List.getElem!_eq_getElem?_getD, List.getElem?_eq_getElem hk]

theorem majority_self (ids : List Nat) (me : Nat) (unique : ids.Nodup) (member : me ∈ ids) :
    Jarl.ElectionSafety.Majority ids [me] ↔ ids.length / 2 < 1 := by
  unfold Jarl.ElectionSafety.Majority
  have : ids.countP (fun x => decide (x ∈ [me])) = 1 := by
    have h : ids.count me = 1 := by rw [unique.count]; simp [member]
    simp only [List.mem_singleton]
    rw [List.count] at h
    rw [← h]
    exact List.countP_congr (fun x _ => by simp)
  simp only [this]

theorem statev_inj {t t' : Nat} {vf vf' c c' sn sn' en en' ln ln' : PureValue}
    (h : statev (hardv t vf c) sn en ln = statev (hardv t' vf' c') sn' en' ln') :
    t = t' ∧ vf = vf' ∧ c = c' ∧ sn = sn' ∧ en = en' ∧ ln = ln' := by
  simp only [statev, hardv, PureValue.record.injEq, List.cons.injEq, Prod.mk.injEq, PureValue.number.injEq,
    true_and, and_true] at h
  obtain ⟨⟨h1, h2, h3⟩, h4, h5, h6⟩ := h
  exact ⟨h1, h2, h3, h4, h5, h6⟩

/-- A campaign of the implementation is the model's `campaign`, possibly followed
    by dropping pending messages. -/
theorem Abs.campaigned {ids : List Nat} {me : Nat} {n n' : Fields} {disk : Durable} {L : Local}
    {t : Nat} {vf c sn en ln : PureValue} {os : List PureValue}
    (a : Abs ids n disk L) (good : Good ids me n) (idle : Idle n)
    (hs : n.state = statev (hardv t vf c) sn en ln) (ho : n.outbox = .array os)
    (camp : Campaigned ids me n (t + 1) c sn en ln os n') (w : Jarl.ElectionSafety.World) (hw : w.voters = ids)
    (hv : w.nodes me = L) :
    ∃ kept, kept.Sublist ((Jarl.ElectionSafety.campaign w me).nodes me).outbox ∧
      Abs ids n' disk { (Jarl.ElectionSafety.campaign w me).nodes me with outbox := kept } := by
  have fixed := good.fixed
  have hme : ids.idxOf me < ids.length := List.idxOf_lt_length_of_mem fixed.member
  have hget : ids[ids.idxOf me] = me := List.getElem_idxOf hme
  obtain ⟨c0, sn0, en0, ln0, hs0⟩ := a.state
  rw [hs] at hs0
  obtain ⟨rfl, -, -, -, -, -⟩ := statev_inj hs0
  obtain ⟨os0, ho0, hL⟩ := a.outbox
  rw [ho] at ho0; cases ho0
  have sized : os.length = ids.length := by
    obtain ⟨os1, ho1, s1, -⟩ := good.outbox; rw [ho] at ho1; cases ho1; exact s1
  have empty : ∀ o ∈ os, o = .absent := by
    obtain ⟨-, -, os1, ho1, e⟩ := idle; rw [ho] at ho1; cases ho1; exact e
  have votes : votesOf ids (selfVotes ids.length (ids.idxOf me)) = [me] := by
    rw [selfVotes, votesOf_self ids _ hme, hget]
  have maj := majority_self ids me fixed.unique fixed.member
  unfold Campaigned at camp
  rcases camp with ⟨q, calm⟩ | ⟨q, calm⟩
  · have hm : Jarl.ElectionSafety.Majority w.voters [me] := hw ▸ maj.mpr q
    have base : Abs ids { campaignBase n (L.term + 1) me c sn en ln ids.length (ids.idxOf me) with role := leaderv }
        disk ((Jarl.ElectionSafety.campaign w me).nodes me) := by
      simp only [Jarl.ElectionSafety.campaign, hm, ite_true, Jarl.ElectionSafety.set, hv]
      exact { state := ⟨c, sn, en, ln, rfl⟩, role := rfl,
              votes := ⟨_, rfl, fun x => by simp [votes]⟩,
              dirty := fun h => (by cases h), durable := a.durable,
              outbox := ⟨os, ho, hL⟩, prevoting := rfl }
    exact base.calm calm
  · have hm : ¬ Jarl.ElectionSafety.Majority ids [me] := fun h => q (maj.mp h)
    have base : Abs ids { campaignBase n (L.term + 1) me c sn en ln ids.length (ids.idxOf me) with
          outbox := .array (voteBox os (ids.idxOf me)) }
        disk ((Jarl.ElectionSafety.campaign w me).nodes me) := by
      simp only [Jarl.ElectionSafety.campaign, hw, hm, ite_false, Jarl.ElectionSafety.set, hv]
      exact { state := ⟨c, sn, en, ln, rfl⟩, role := rfl,
              votes := ⟨_, rfl, fun x => by simp [votes]⟩,
              dirty := fun h => (by cases h), durable := a.durable,
              outbox := ⟨_, rfl, by simp [outboxOf_voteBox ids os _ sized fixed.unique hme empty, hget]⟩,
              prevoting := rfl }
    exact base.calm calm

end Refine
