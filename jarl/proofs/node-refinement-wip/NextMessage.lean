import AbsStep
open Provium.State Provium.Imperative
set_option linter.unusedSimpArgs false
namespace Refine
open Jarl.ElectionSafety (Pending)

/-- An outbox descriptor of a shape `Node` writes. -/
def Formed (o : PureValue) : Prop :=
  o = .variant "Outbound" "Vote" [] ∨
  (∃ g : Bool, o = .variant "Outbound" "Voted" [("0", .boolean g)]) ∨
  (∃ c, o = .variant "Outbound" "PreVote" [("0", .number "u64" c)]) ∨
  (∃ c, ∃ g : Bool, o = .variant "Outbound" "PreVoted" [("0", .number "u64" c), ("1", .boolean g)]) ∨
  o = .variant "Outbound" "Replicate" [] ∨
  ∃ i j, o = .variant "Outbound" "Replicated" [("0", i), ("1", j)]

/-- The model's message for an election message on the wire. -/
def Msg.election : Msg → Option Jarl.ElectionSafety.Message
  | .prevote t _ => some (.prevote t)
  | .prevoted t c g => some (.prevoted t c g)
  | .vote t _ => some (.vote t)
  | .voted t g => some (.voted t g)
  | _ => none

/-- What `next_message` returns for a slot to `to` holding `o`: an election
    message only as the model's `materialize` stamps that descriptor at term `t`. -/
def Sends (me t to : Nat) (o v : PureValue) : Prop :=
  ∀ src dst m, v = .present (envelopev src dst m) → ∀ e, m.election = some e →
    ∃ P, pendingOf to (.present o) = some P ∧ Jarl.ElectionSafety.envelopeOf me t P = ⟨src, dst, e⟩

set_option maxHeartbeats 4000000 in
/-- `next_message` on a node whose descriptors are well formed: either nothing
    changes and nothing is sent, or the first occupied slot of a clean node is
    cleared and what is sent for it is as `Sends` describes. -/
theorem next_spec (target : Target) (n : Fields) (ids : List Nat) (me : Nat) (good : Good ids me n)
    (t : Nat) (vf c sn en ln : PureValue) (hs : n.state = statev (hardv t vf c) sn en ln)
    (formed : ∀ os, n.outbox = .array os → ∀ o, .present o ∈ os → Formed o)
    (cap : PureValue) {fuel : Nat} {v r : PureValue}
    (h : Jarl.node_Node_next_message target fuel n.value [.number "usize" ids.length, cap] = .ok (v, r)) :
    (r = n.value ∧ v = .absent) ∨
    ∃ os p o to, n.outbox = .array os ∧ n.dirty = .boolean false ∧ os[p]? = some (.present o) ∧
      (∀ k < p, os[k]? = some .absent) ∧ ids[p]? = some to ∧
      r = { n with outbox := .array (os.set p .absent) }.value ∧ Sends me t to o v := by
  have fixed := good.fixed
  have hpeers := fixed.peers
  have hself := fixed.self
  have hh := fixed.hooks
  obtain ⟨os, ho, sized, hos⟩ := good.outbox
  obtain ⟨b, hd⟩ := good.dirty
  have hx := good.extra
  simp only [Jarl.node_Node_next_message] at h
  refine run_of_wp (m := machine target) (P := fun v r => (r = n.value ∧ v = .absent) ∨
    ∃ os p o to, n.outbox = .array os ∧ n.dirty = .boolean false ∧ os[p]? = some (.present o) ∧
      (∀ k < p, os[k]? = some .absent) ∧ ids[p]? = some to ∧
      r = { n with outbox := .array (os.set p .absent) }.value ∧ Sends me t to o v) ?_ h
  simp only [Jarl.node_Node_next_message_ir, frameOf, List.zipIdx, List.foldl]
  wp_walk [Fields.value, hd, ho]
  case yes => wp_receiver; exact Or.inl ⟨rfl, trivial⟩
  apply wp_scan_here "usize" os.length [6, 7, 8, 10, 11, 12]
    (fun j e => e 6 = some .absent ∧ e 10 = some (.number "usize" j) ∧ ∀ k < j, os[k]? = some .absent)
    (by decide) (by simp (disch := decide) only [set_same, set_other]) 0
    (by simp (disch := decide) only [set_same]) (Nat.zero_le _)
    (by simp (disch := decide) only [set_same, set_other]; simp)
  · intro j e hc hlt hbound hwide hk ⟨h6, h10, hnot⟩
    rcases hos _ (List.getElem_mem hlt) with hj | ⟨o, hj⟩
    · wp_walk [hc, hk, hlt, h6, h10, hj]
      refine ⟨j + 1, by simp (disch := decide) only [set_same, set_other], by omega, by wp_kept hk,
        by simp (disch := decide) only [set_other, h6], by simp (disch := decide) only [set_same], ?_⟩
      intro k hkj
      rcases Nat.lt_succ_iff_lt_or_eq.mp hkj with lt | eq
      · exact hnot k lt
      · subst eq; rw [List.getElem?_eq_getElem hlt, hj]
    have hto : ids[j]? = some ids[j] := by simp [← sized, hlt]
    rcases formed os ho o (hj ▸ List.getElem_mem hlt) with
      rfl | ⟨g, rfl⟩ | ⟨cc, rfl⟩ | ⟨cc, g, rfl⟩ | rfl | ⟨i, jj, rfl⟩
    all_goals
      wp_walk_any [hc, hk, hlt, h6, h10, hj, Fields.value, ho, hpeers, peersv, hs, hself, hh, statev_hard, hardv_term, hardv_commit]
    all_goals
      wp_receiver
      refine Or.inr ⟨os, j, _, ids[j], ho, ?_, by rw [List.getElem?_eq_getElem hlt, hj], hnot, hto, ?_, ?_⟩
      · cases b <;> simp_all
      · simp [Fields.value, hs, hpeers, peersv, hh]
      · intro src dst m hm e he
        cases m <;> simp only [envelopev, Msg.value, Msg.election, idv, PureValue.number.injEq, PureValue.present.injEq, PureValue.record.injEq,
          PureValue.variant.injEq, List.cons.injEq, Prod.mk.injEq, Option.some.injEq, reduceCtorEq, and_false,
          false_and, and_true, true_and] at hm he
        all_goals subst he; simp_all [pendingOf, Jarl.ElectionSafety.envelopeOf]
  · intro e hc hk ⟨h6, h10, hnot⟩
    wp_walk [h6, hk, Fields.value, hx]
    wp_receiver
    exact Or.inl ⟨by simp [Fields.value, hx], trivial⟩

theorem outboxOf_cons (i : Nat) (is : List Nat) (x : PureValue) (xs : List PureValue) :
    outboxOf (i :: is) (x :: xs) = (pendingOf i x).toList ++ outboxOf is xs := by
  simp only [outboxOf, List.zip_cons_cons, List.filterMap_cons]
  cases pendingOf i x <;> simp

/-- The first occupied slot's message heads the outbox; clearing the slot drops it. -/
theorem outboxOf_first : ∀ (ids : List Nat) (os : List PureValue) (p to : Nat) (o : PureValue),
    os[p]? = some (.present o) → (∀ k < p, os[k]? = some .absent) → ids[p]? = some to →
    outboxOf ids os = (pendingOf to (.present o)).toList ++ outboxOf ids (os.set p .absent)
  | [], _, _, _, _, _, _, hto => by simp at hto
  | _ :: _, [], _, _, _, hj, _, _ => by simp at hj
  | i :: is, x :: xs, 0, to, o, hj, _, hto => by
    simp only [List.getElem?_cons_zero, Option.some.injEq] at hj hto
    subst hj hto
    simp [outboxOf_cons, pendingOf]
  | i :: is, x :: xs, p + 1, to, o, hj, hnot, hto => by
    have hx : x = .absent := by simpa using hnot 0 (Nat.zero_lt_succ _)
    subst hx
    have ih := outboxOf_first is xs p to o (by simpa using hj)
      (fun k hk => by simpa using hnot (k + 1) (by omega)) (by simpa using hto)
    simp [outboxOf_cons, pendingOf, ih]

/-- Clearing the first occupied slot of a clean node is the model's
    `materialize` of that slot's election message, or no election step. -/
theorem Abs.next {ids : List Nat} {n : Fields} {disk : Jarl.ElectionSafety.Durable}
    {L : Jarl.ElectionSafety.Local} (a : Abs ids n disk L) {os : List PureValue} {p to : Nat} {o : PureValue}
    (ho : n.outbox = .array os) (hd : n.dirty = .boolean false) (hj : os[p]? = some (.present o))
    (hnot : ∀ k < p, os[k]? = some .absent) (hto : ids[p]? = some to) :
    L.dirty = false ∧
    Abs ids { n with outbox := .array (os.set p .absent) } disk
      { L with outbox := outboxOf ids (os.set p .absent) } ∧
    L.outbox = (pendingOf to (.present o)).toList ++ outboxOf ids (os.set p .absent) := by
  obtain ⟨os', ho', hL⟩ := a.outbox
  rw [ho] at ho'
  cases ho'
  exact ⟨a.dirty hd, a.box _, hL.trans (outboxOf_first ids os p to o hj hnot hto)⟩

end Refine
