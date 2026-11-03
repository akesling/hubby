import Abstract
import StepDefs
open Provium.State Provium.Imperative
set_option linter.unusedSimpArgs false
namespace Refine
open Jarl.ElectionSafety (Local Pending Durable)

theorem voteValue_inj {a b : Option Nat} (h : voteValue a = voteValue b) : a = b := by
  cases a <;> cases b <;> simp_all [voteValue, idv]

theorem outboxOf_absent : ∀ (ids : List Nat) (os : List PureValue), (∀ o ∈ os, o = .absent) →
    outboxOf ids os = []
  | [], _, _ => by simp [outboxOf]
  | _ :: _, [], _ => by simp [outboxOf]
  | i :: is, o :: os, h => by
    have ih := outboxOf_absent is os (fun x hx => h x (List.mem_cons_of_mem _ hx))
    have ho : o = .absent := h o List.mem_cons_self
    simp only [outboxOf, List.zip_cons_cons, List.filterMap_cons] at ih ⊢
    rw [ho]; exact ih

/-- A single descriptor in an otherwise empty outbox. -/
theorem outboxOf_single : ∀ (ids : List Nat) (os : List PureValue) (p : Nat) (x : PureValue)
    (_ : os.length = ids.length) (_ : ∀ o ∈ os, o = .absent) (hp : p < ids.length),
    outboxOf ids (os.set p x) = (pendingOf ids[p] x).toList
  | [], _, _, _, _, _, hp => by simp at hp
  | _ :: _, [], _, _, sized, _, _ => by simp at sized
  | i :: is, o :: os, 0, x, _, empty, _ => by
    have rest := outboxOf_absent is os (fun y hy => empty y (List.mem_cons_of_mem _ hy))
    simp only [outboxOf, List.set_cons_zero, List.zip_cons_cons, List.filterMap_cons] at rest ⊢
    rw [rest]
    change _ = (pendingOf i x).toList
    cases pendingOf i x <;> rfl
  | i :: is, o :: os, p + 1, x, sized, empty, hp => by
    have ih := outboxOf_single is os p x (by simpa using sized)
      (fun y hy => empty y (List.mem_cons_of_mem _ hy)) (by simpa using hp)
    have ho : o = .absent := empty o List.mem_cons_self
    simp only [outboxOf, List.set_cons_succ, List.zip_cons_cons, List.filterMap_cons,
      List.getElem_cons_succ] at ih ⊢
    rw [ho]; exact ih

theorem votesOf_mem {ids : List Nat} {bs : List Bool} {x : Nat} (h : x ∈ votesOf ids bs) : x ∈ ids := by
  unfold votesOf at h
  obtain ⟨⟨y, b⟩, hm, rfl⟩ := List.mem_map.mp h
  exact (List.of_mem_zip (List.mem_filter.mp hm).1).1

/-- Counting the voters that `bs` marks is counting the marks. -/
theorem countP_votesOf : ∀ (ids : List Nat) (bs : List Bool), ids.Nodup → bs.length = ids.length →
    ids.countP (fun x => decide (x ∈ votesOf ids bs)) = granted bs
  | [], [], _, _ => by simp [granted]
  | [], _ :: _, _, h => by simp at h
  | _ :: _, [], _, h => by simp at h
  | i :: is, b :: bs, nd, h => by
    have ih := countP_votesOf is bs (List.nodup_cons.mp nd).2 (by simpa using h)
    have fresh : i ∉ votesOf is bs := fun hi => (List.nodup_cons.mp nd).1 (votesOf_mem hi)
    have cons : votesOf (i :: is) (b :: bs) = if b then i :: votesOf is bs else votesOf is bs := by
      cases b <;> simp [votesOf]
    have rest : is.countP (fun x => decide (x ∈ votesOf (i :: is) (b :: bs))) =
        is.countP (fun x => decide (x ∈ votesOf is bs)) := by
      apply List.countP_congr
      intro x hx
      have hne : x ≠ i := fun e => (List.nodup_cons.mp nd).1 (e ▸ hx)
      rw [cons]; cases b <;> simp [hne]
    rw [List.countP_cons, rest, ih, cons]
    cases b <;> simp [granted, fresh, List.count_cons] <;> omega

/-- The model's majority test is the implementation's granted count. -/
theorem majority_granted {ids S : List Nat} {bs : List Bool} (nd : ids.Nodup) (len : bs.length = ids.length)
    (same : ∀ x, x ∈ S ↔ x ∈ votesOf ids bs) :
    Jarl.ElectionSafety.Majority ids S ↔ ids.length / 2 < granted bs := by
  unfold Jarl.ElectionSafety.Majority
  rw [← countP_votesOf ids bs nd len]
  have : ids.countP (fun x => decide (x ∈ S)) = ids.countP (fun x => decide (x ∈ votesOf ids bs)) :=
    List.countP_congr (fun x _ => by simp [same x])
  rw [this]

/-- The term check of the model and of the implementation agree. -/
theorem Abs.adopt {ids : List Nat} {n : Fields} {disk : Durable} {L : Local} {c sn en ln : PureValue}
    (a : Abs ids n disk L) (T : Nat) :
    Abs ids (adoptF n L.term T c sn en ln) disk (Jarl.ElectionSafety.adopt L T) := by
  unfold adoptF Jarl.ElectionSafety.adopt
  by_cases h : L.term < T
  · rw [if_pos h, if_pos h]
    obtain ⟨bs, hv, hvs⟩ := a.votes
    obtain ⟨os, ho, hos⟩ := a.outbox
    exact {
      state := ⟨c, sn, en, ln, rfl⟩
      role := rfl
      votes := ⟨bs, hv, hvs⟩
      dirty := fun h => by cases h
      durable := a.durable
      outbox := ⟨os, ho, hos⟩
      prevoting := rfl }
  · rw [if_neg h, if_neg h]
    exact a

/-- Replacing the outbox of a node replaces the model's pending messages. -/
theorem Abs.box {ids : List Nat} {n : Fields} {disk : Durable} {L : Local} (a : Abs ids n disk L)
    (os' : List PureValue) : Abs ids { n with outbox := .array os' } disk { L with outbox := outboxOf ids os' } where
  state := a.state
  role := a.role
  votes := a.votes
  dirty := a.dirty
  durable := a.durable
  outbox := ⟨os', rfl, rfl⟩
  prevoting := a.prevoting

theorem Abs.term_of {ids : List Nat} {n : Fields} {disk : Durable} {L : Local} {t : Nat} {vf c sn en ln : PureValue}
    (a : Abs ids n disk L) (hs : n.state = statev (hardv t vf c) sn en ln) :
    t = L.term ∧ vf = voteValue L.vote := by
  obtain ⟨c0, sn0, en0, ln0, hs0⟩ := a.state
  rw [hs] at hs0
  obtain ⟨h1, h2, -⟩ := statev_inj hs0
  exact ⟨h1, h2⟩

/-- `step` on a message that only carries a term (`PreVoted` without an active
    probe, `Replicated`) adopts that term, up to dropped pending messages. -/
theorem Abs.adopt_calm {ids : List Nat} {n n' : Fields} {disk : Durable} {L : Local}
    {t : Nat} {vf c sn en ln : PureValue} {T : Nat} (a : Abs ids n disk L)
    (hs : n.state = statev (hardv t vf c) sn en ln) (calm : Calm (adoptF n t T c sn en ln) n') :
    ∃ kept, kept.Sublist (Jarl.ElectionSafety.adopt L T).outbox ∧
      Abs ids n' disk { Jarl.ElectionSafety.adopt L T with outbox := kept } := by
  obtain ⟨rfl, -⟩ := a.term_of hs
  exact Abs.calm (Abs.adopt a T) calm

/-- Following a leader is the model's `demote`. -/
theorem Abs.demote {ids : List Nat} {n : Fields} {disk : Durable} {L : Local} (a : Abs ids n disk L)
    (src : Nat) : Abs ids (demoteF n src) disk (Jarl.ElectionSafety.demote L) where
  state := a.state
  role := rfl
  votes := a.votes
  dirty := a.dirty
  durable := a.durable
  outbox := a.outbox
  prevoting := rfl

/-- `step` on `Append`, `AppendBatch` or `Install`: a stale message changes
    nothing election-relevant; a current one adopts its term and demotes. -/
theorem Abs.follow {ids : List Nat} {n n' : Fields} {disk : Durable} {L : Local}
    {t : Nat} {vf c sn en ln : PureValue} {T src : Nat} (a : Abs ids n disk L)
    (hs : n.state = statev (hardv t vf c) sn en ln)
    (out : if T < t then Calm n n' else Calm (demoteF (adoptF n t T c sn en ln) src) n') :
    (T < L.term ∧ ∃ kept, kept.Sublist L.outbox ∧ Abs ids n' disk { L with outbox := kept }) ∨
      (¬ T < L.term ∧ ∃ kept, kept.Sublist (Jarl.ElectionSafety.demote (Jarl.ElectionSafety.adopt L T)).outbox ∧
        Abs ids n' disk { Jarl.ElectionSafety.demote (Jarl.ElectionSafety.adopt L T) with outbox := kept }) := by
  obtain ⟨rfl, -⟩ := a.term_of hs
  by_cases hT : T < L.term
  · rw [if_pos hT] at out
    exact Or.inl ⟨hT, Abs.calm a out⟩
  · rw [if_neg hT] at out
    exact Or.inr ⟨hT, Abs.calm ((Abs.adopt a T).demote src) out⟩

theorem votesOf_cons (i : Nat) (is : List Nat) (b : Bool) (bs : List Bool) :
    votesOf (i :: is) (b :: bs) = if b then i :: votesOf is bs else votesOf is bs := by
  cases b <;> simp [votesOf]

/-- Marking slot `p` adds the voter at `p`. -/
theorem mem_votesOf_set : ∀ (ids : List Nat) (bs : List Bool) (p x : Nat), p < bs.length → p < ids.length →
    (x ∈ votesOf ids (bs.set p true) ↔ x ∈ votesOf ids bs ∨ x = ids[p]!)
  | [], _, _, _, _, hp => by simp at hp
  | _ :: _, [], _, _, hp, _ => by simp at hp
  | i :: is, b :: bs, 0, x, _, _ => by
    simp only [List.set_cons_zero, votesOf_cons, if_true, List.mem_cons]
    cases b <;> simp [or_comm]
  | i :: is, b :: bs, p + 1, x, hb, hi => by
    have ih := mem_votesOf_set is bs p x (by simpa using hb) (by simpa using hi)
    simp only [List.set_cons_succ, votesOf_cons]
    have e : (i :: is)[p + 1]! = is[p]! := by simp
    rw [e]
    cases b <;> simp [ih, or_assoc]

theorem boolsv_inj : ∀ {a b : List Bool}, boolsv a = boolsv b → a = b
  | [], [], _ => rfl
  | [], _ :: _, h => by simp [boolsv] at h
  | _ :: _, [], h => by simp [boolsv] at h
  | x :: a, y :: b, h => by
    simp only [boolsv, List.map_cons, PureValue.array.injEq, List.cons.injEq, PureValue.boolean.injEq] at h
    rw [h.1, boolsv_inj (a := a) (b := b) (by simp only [boolsv, h.2])]

theorem role_cases_candidate {r : PureValue} (h : r = followerv ∨ r = candidatev ∨ r = leaderv) :
    r = candidatev ↔ roleOf r = .candidate := by
  rcases h with rfl | rfl | rfl <;> simp [roleOf, followerv, candidatev, leaderv]

theorem adopt_term (L : Local) (T : Nat) : (Jarl.ElectionSafety.adopt L T).term = max L.term T := by
  unfold Jarl.ElectionSafety.adopt
  split <;> (try simp [Jarl.ElectionSafety.stepDown]) <;> omega

open Jarl.ElectionSafety in
/-- `step` on a `Voted` reply is the model's `handleVoted` at that node, up to
    dropped pending messages. -/
theorem Abs.voted {ids : List Nat} {me : Nat} {n n' : Fields} {disk : Durable} {w : World} {v : Node}
    {t : Nat} {vf c sn en ln : PureValue} {os : List PureValue} {bs : List Bool} {src T : Nat} {g : Bool}
    (a : Abs ids n disk (w.nodes v)) (good : Good ids me n) (hvoters : w.voters = ids)
    (hs : n.state = statev (hardv t vf c) sn en ln) (hv : n.votes = boolsv bs) (hsrc : src ∈ ids)
    (out : StepOut ids n t vf c sn en ln os bs src (.voted T g) n') :
    ∃ kept, kept.Sublist ((handleVoted w v src T g).nodes v).outbox ∧
      Abs ids n' disk { (handleVoted w v src T g).nodes v with outbox := kept } := by
  obtain ⟨rfl, -⟩ := a.term_of hs
  have a1 := Abs.adopt (c := c) (sn := sn) (en := en) (ln := ln) a T
  have hbs : bs.length = ids.length := by
    obtain ⟨bs0, hv0, len⟩ := good.votes
    rw [hv] at hv0; rw [boolsv_inj hv0]; exact len
  have hrole : (adoptF n (w.nodes v).term T c sn en ln).role = followerv ∨
      (adoptF n (w.nodes v).term T c sn en ln).role = candidatev ∨
      (adoptF n (w.nodes v).term T c sn en ln).role = leaderv := by
    unfold adoptF; split
    · exact Or.inl rfl
    · exact good.role
  have hvotes1 : (adoptF n (w.nodes v).term T c sn en ln).votes = boolsv bs := by
    unfold adoptF; split <;> exact hv
  have hcond : (max (w.nodes v).term T = T ∧ (adoptF n (w.nodes v).term T c sn en ln).role = candidatev ∧ g = true) ↔
      (T = (Jarl.ElectionSafety.adopt (w.nodes v) T).term ∧ (Jarl.ElectionSafety.adopt (w.nodes v) T).role = .candidate ∧ g = true) := by
    rw [adopt_term, role_cases_candidate hrole, a1.role]
    constructor
    · rintro ⟨h1, h2, h3⟩; exact ⟨h1.symm, h2, h3⟩
    · rintro ⟨h1, h2, h3⟩; exact ⟨h1.symm, h2, h3⟩
  simp only [StepOut] at out
  unfold handleVoted
  by_cases hc : max (w.nodes v).term T = T ∧ (adoptF n (w.nodes v).term T c sn en ln).role = candidatev ∧ g = true
  · rw [if_pos hc] at out
    rw [if_pos (hcond.mp hc)]
    have hidx : ids.idxOf src < ids.length := List.idxOf_lt_length_of_mem hsrc
    obtain ⟨bs0, hv0, same0⟩ := a1.votes
    rw [hvotes1] at hv0
    rw [← boolsv_inj hv0] at same0
    have same : ∀ x, x ∈ (if src ∈ (Jarl.ElectionSafety.adopt (w.nodes v) T).votes then (Jarl.ElectionSafety.adopt (w.nodes v) T).votes
          else (Jarl.ElectionSafety.adopt (w.nodes v) T).votes ++ [src]) ↔ x ∈ votesOf ids (bs.set (ids.idxOf src) true) := by
      intro x
      rw [mem_votesOf_set ids bs _ x (by omega) hidx, ← same0 x]
      have e : ids[ids.idxOf src]! = src := by
        rw [getElem!_pos ids _ hidx]; exact List.getElem_idxOf hidx
      rw [e]
      split
      · constructor
        · exact Or.inl
        · rintro (h | rfl) <;> assumption
      · simp
    have maj := majority_granted (S := if src ∈ (Jarl.ElectionSafety.adopt (w.nodes v) T).votes then (Jarl.ElectionSafety.adopt (w.nodes v) T).votes
          else (Jarl.ElectionSafety.adopt (w.nodes v) T).votes ++ [src]) good.fixed.unique (by simpa using hbs) same
    rw [hvoters]
    rcases out with ⟨hm, calm⟩ | ⟨hm, calm⟩
    · rw [if_pos (maj.mpr hm)]
      simp only [Jarl.ElectionSafety.set, if_true]
      have a2 : Abs ids { adoptF n (w.nodes v).term T c sn en ln with
            votes := boolsv (bs.set (ids.idxOf src) true), role := leaderv } disk
          { Jarl.ElectionSafety.adopt (w.nodes v) T with votes := (if src ∈ (Jarl.ElectionSafety.adopt (w.nodes v) T).votes then (Jarl.ElectionSafety.adopt (w.nodes v) T).votes else (Jarl.ElectionSafety.adopt (w.nodes v) T).votes ++ [src]), role := .leader } :=
        { state := a1.state, role := rfl, votes := ⟨_, rfl, same⟩, dirty := a1.dirty,
          durable := a1.durable, outbox := a1.outbox, prevoting := a1.prevoting }
      exact Abs.calm a2 calm
    · rw [if_neg (fun h => hm (maj.mp h))]
      simp only [Jarl.ElectionSafety.set, if_true]
      have a2 : Abs ids { adoptF n (w.nodes v).term T c sn en ln with
            votes := boolsv (bs.set (ids.idxOf src) true) } disk
          { Jarl.ElectionSafety.adopt (w.nodes v) T with votes := (if src ∈ (Jarl.ElectionSafety.adopt (w.nodes v) T).votes then (Jarl.ElectionSafety.adopt (w.nodes v) T).votes else (Jarl.ElectionSafety.adopt (w.nodes v) T).votes ++ [src]) } :=
        { state := a1.state, role := a1.role, votes := ⟨_, rfl, same⟩, dirty := a1.dirty,
          durable := a1.durable, outbox := a1.outbox, prevoting := a1.prevoting }
      exact Abs.calm a2 calm
  · rw [if_neg hc] at out
    rw [if_neg (fun h => hc (hcond.mpr h))]
    simp only [Jarl.ElectionSafety.set, if_true]
    exact Abs.calm a1 out

/-- `step` on a `PreVote` request is the model's `answerProbe`, up to dropped
    pending messages. -/
theorem Abs.prevote {ids : List Nat} {me : Nat} {n n' : Fields} {disk : Durable} {L : Local}
    {t : Nat} {vf c sn en ln : PureValue} {os : List PureValue} {bs : List Bool} {src T : Nat}
    {last : PureValue} (a : Abs ids n disk L) (good : Good ids me n) (idle : Idle n)
    (ho : n.outbox = .array os) (hsrc : src ∈ ids)
    (out : StepOut ids n t vf c sn en ln os bs src (.prevote T last) n') :
    ∃ g kept, kept.Sublist [Pending.prevoted src T g] ∧
      Abs ids n' disk { L with outbox := kept } := by
  have sized : os.length = ids.length := by
    obtain ⟨os1, ho1, s1, -⟩ := good.outbox; rw [ho] at ho1; cases ho1; exact s1
  have empty : ∀ o ∈ os, o = .absent := by
    obtain ⟨-, -, os1, ho1, e⟩ := idle; rw [ho] at ho1; cases ho1; exact e
  have hidx : ids.idxOf src < ids.length := List.idxOf_lt_length_of_mem hsrc
  obtain ⟨g, calm⟩ := out
  refine ⟨g, ?_⟩
  have a1 := Abs.box a (os.set (ids.idxOf src) (prevotedv T g))
  rw [outboxOf_single ids os _ _ sized empty hidx, List.getElem_idxOf hidx] at a1
  exact Abs.calm a1 calm

open Jarl.ElectionSafety Classical in
/-- `step` on a `Vote` request is the model's `requestVote` for some log
    comparison outcome, up to dropped pending messages. -/
theorem Abs.vote {ids : List Nat} {me : Nat} {n n' : Fields} {disk : Durable} {L : Local}
    {t : Nat} {vf c sn en ln : PureValue} {os : List PureValue} {bs : List Bool} {src T : Nat}
    {last : PureValue} (a : Abs ids n disk L) (good : Good ids me n) (idle : Idle n)
    (hs : n.state = statev (hardv t vf c) sn en ln) (ho : n.outbox = .array os) (hsrc : src ∈ ids)
    (out : StepOut ids n t vf c sn en ln os bs src (.vote T last) n') :
    ∃ logOk kept, kept.Sublist (handleVote L src T logOk).outbox ∧
      Abs ids n' disk { handleVote L src T logOk with outbox := kept } := by
  obtain ⟨c0, sn0, en0, ln0, hs0⟩ := a.state
  rw [hs] at hs0
  obtain ⟨rfl, rfl, -, -, -, -⟩ := statev_inj hs0
  have sized : os.length = ids.length := by
    obtain ⟨os1, ho1, s1, -⟩ := good.outbox; rw [ho] at ho1; cases ho1; exact s1
  have empty : ∀ o ∈ os, o = .absent := by
    obtain ⟨-, -, os1, ho1, e⟩ := idle; rw [ho] at ho1; cases ho1; exact e
  have hidx : ids.idxOf src < ids.length := List.idxOf_lt_length_of_mem hsrc
  have box : ∀ g, outboxOf ids (os.set (ids.idxOf src) (votedv g)) = [.voted src g] := by
    intro g
    rw [outboxOf_single ids os _ _ sized empty hidx, List.getElem_idxOf hidx]
    rfl
  simp only [StepOut] at out
  by_cases hT : T < L.term
  · rw [if_pos hT] at out
    refine ⟨false, ?_⟩
    have hv : handleVote L src T false = { L with outbox := [.voted src false] } := by
      have : ¬L.term < T := by omega
      simp [handleVote, Jarl.ElectionSafety.adopt, this, hT]
    rw [hv]
    have a1 := Abs.box a (os.set (ids.idxOf src) (votedv false))
    rw [box] at a1
    exact Abs.calm a1 out
  · rw [if_neg hT] at out
    obtain ⟨g, hg, calm⟩ := out
    refine ⟨g, ?_⟩
    have a1 := Abs.adopt (c := c) (sn := sn) (en := en) (ln := ln) a T
    have hterm : (Jarl.ElectionSafety.adopt L T).term = T := by
      unfold Jarl.ElectionSafety.adopt; split <;> (try simp [Jarl.ElectionSafety.stepDown]) <;> omega
    have hvote : voteValue (Jarl.ElectionSafety.adopt L T).vote = if L.term < T then .absent else voteValue L.vote := by
      unfold Jarl.ElectionSafety.adopt; split <;> simp [Jarl.ElectionSafety.stepDown, voteValue]
    have hnot : ¬T < (Jarl.ElectionSafety.adopt L T).term := by omega
    cases g
    · simp only [Bool.false_eq_true, if_false] at calm
      have hv : handleVote L src T false = { Jarl.ElectionSafety.adopt L T with outbox := [.voted src false] } := by
        simp [handleVote, hnot]
      rw [hv]
      have a2 := Abs.box a1 (os.set (ids.idxOf src) (votedv false))
      rw [box] at a2
      exact Abs.calm a2 calm
    · simp only [if_true] at calm
      rw [← hvote] at hg calm
      have hcond : (Jarl.ElectionSafety.adopt L T).vote = none ∨ (Jarl.ElectionSafety.adopt L T).vote = some src := by
        rcases hg rfl with h | h
        · exact Or.inl (voteValue_inj (a := _) (b := none) h)
        · exact Or.inr (voteValue_inj (a := _) (b := some src) h)
      have hv : handleVote L src T true =
          { Jarl.ElectionSafety.adopt L T with
            vote := some src
            dirty := (Jarl.ElectionSafety.adopt L T).dirty || decide ((Jarl.ElectionSafety.adopt L T).vote ≠ some src)
            outbox := [.voted src true] } := by
        simp [handleVote, hnot, hcond]
      rw [hv]
      have a2 : Abs ids { adoptF n L.term T c sn en ln with
            state := statev (hardv T (.present (idv src)) c) sn en ln
            dirty := if voteValue (Jarl.ElectionSafety.adopt L T).vote = .present (idv src) then
              (adoptF n L.term T c sn en ln).dirty else .boolean true
            outbox := .array (os.set (ids.idxOf src) (votedv true)) } disk
          { Jarl.ElectionSafety.adopt L T with
            vote := some src
            dirty := (Jarl.ElectionSafety.adopt L T).dirty || decide ((Jarl.ElectionSafety.adopt L T).vote ≠ some src)
            outbox := [.voted src true] } := {
        state := ⟨c, sn, en, ln, by rw [hterm]; rfl⟩
        role := a1.role
        votes := a1.votes
        dirty := fun h => by
          by_cases hp : voteValue (Jarl.ElectionSafety.adopt L T).vote = .present (idv src)
          · rw [if_pos hp] at h
            have e : (Jarl.ElectionSafety.adopt L T).vote = some src := voteValue_inj (b := some src) hp
            simp [a1.dirty h, e]
          · rw [if_neg hp] at h
            simp at h
        durable := a1.durable
        outbox := ⟨_, rfl, (box true).symm⟩
        prevoting := a1.prevoting }
      exact Abs.calm a2 calm

end Refine
