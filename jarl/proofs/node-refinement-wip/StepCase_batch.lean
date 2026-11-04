import StepDefs
open Provium.State Provium.Imperative
set_option linter.unusedSimpArgs false
namespace Refine

set_option maxHeartbeats 20000000 in
/-- `step` on an `AppendBatch`: either the election state stays calm, or an idle node handles a
    message from another member addressed to it as `StepOut` describes. -/
theorem step_batch (target : Target) (n : Fields) (ids : List Nat) (me : Nat) (good : Good ids me n)
    (t : Nat) (vf c sn en ln : PureValue) (hs : n.state = statev (hardv t vf c) sn en ln)
    (src dst : Nat) (T : Nat) (prev entries commit : PureValue) (cap : PureValue) {fuel : Nat} {v r : PureValue}
    (h : Jarl.node_Node_step target fuel n.value [envelopev src dst (Msg.batch T prev entries commit), .number "usize" ids.length, cap] =
      .ok (v, r)) :
    ∃ n', r = n'.value ∧ (Calm n n' ∨ (Idle n ∧ src ∈ ids ∧ src ≠ me ∧ dst = me ∧
      ∃ os bs, n.outbox = .array os ∧ n.votes = boolsv bs ∧ StepOut ids n t vf c sn en ln os bs src (Msg.batch T prev entries commit) n')) := by
  have fixed := good.fixed
  have hh := fixed.hooks
  have hmem := fixed.membership
  have hpeers := fixed.peers
  have hslot := fixed.slot
  have hself := fixed.self
  have hpv := good.prevoting
  have hx := good.extra
  obtain ⟨os, ho, sized, hos⟩ := good.outbox
  obtain ⟨b, hd⟩ := good.dirty
  obtain ⟨bs, hv, hbs⟩ := good.votes
  simp only [Jarl.node_Node_step] at h
  refine run_of_wp (m := machine target) (P := fun _ r => ∃ n', r = n'.value ∧ (Calm n n' ∨ (Idle n ∧
    src ∈ ids ∧ src ≠ me ∧ dst = me ∧ ∃ os bs, n.outbox = .array os ∧ n.votes = boolsv bs ∧
      StepOut ids n t vf c sn en ln os bs src (Msg.batch T prev entries commit) n'))) ?_ h
  simp only [Jarl.node_Node_step_ir, frameOf, List.zipIdx, List.foldl]
  wp_walk [Fields.value]
  apply wp_invoke _ (available_spec target n os ho hos b hd good.extra)
  wp_walk
  refine ⟨by simp, ?_⟩
  rintro v r ⟨-, hv' | rfl⟩
  case inr =>
    wp_walk [busyv]
    wp_receiver
    exact ⟨n, rfl, Or.inl (Calm.refl n)⟩
  obtain ⟨rfl, idle⟩ := hv'
  wp_walk [okv, Fields.value, hpeers, peersv, envelopev]
  -- The sender's peer slot.
  apply wp_scan_here "usize" ids.length [10, 11, 12, 13, 14, 15]
    (fun j e => e 10 = some .absent ∧ e 13 = some (.number "usize" j) ∧ src ∉ ids.take j) (by decide)
    (by simp (disch := decide) only [set_same, set_other, List.length_map]) 0
    (by simp (disch := decide) only [set_same]) (Nat.zero_le _)
    (by simp (disch := decide) only [set_same, set_other]; simp)
  · intro j e hc hlt hbound hwide hk ⟨h10, h13, hnot⟩
    wp_walk [hc, hk, hlt, h10, h13, envelopev, binary_present_ids]
    case no =>
      refine ⟨j + 1, by simp (disch := decide) only [set_same, set_other], by omega, by wp_kept hk,
        by simp (disch := decide) only [set_other, h10], by simp (disch := decide) only [set_same], ?_⟩
      simp only [take_succ ids j hlt, List.mem_append, List.mem_singleton, not_or]
      exact ⟨hnot, fun h => ‹¬(ids[j] == src) = true› (by simp [h])⟩
    all_goals
      have hj : ids[j] = src := by simpa using ‹(ids[j] == src) = true›
      have hsrc : src ∈ ids := hj ▸ List.getElem_mem hlt
      have hp : j = ids.idxOf src := by
        have h1 := List.getElem_idxOf (List.idxOf_lt_length_of_mem hsrc)
        exact (List.getElem_inj fixed.unique).mp (hj.trans h1.symm)
      wp_walk [hk, Fields.value, envelopev, hself, binary_ids, binary_ne_ids]
    all_goals first
      | (wp_receiver [hk]
         first
           | exact ⟨n, by simp [Fields.value, hh, hpeers, peersv], Or.inl (Calm.refl n)⟩
           | exact ⟨_, nodeEq, Or.inl calm_auto⟩)
      | (wp_walk [hk, Fields.value, envelopev, Msg.value, Rej.value, hh, hs, statev_hard, hardv_term, hardv_voted, hpv, binary_absent_present, binary_ne_absent_present, update_statev_hard, update_hardv_term, update_hardv_vote, update_hardv_commit, except_bind_ok_eq, hself, binary_ids, binary_ne_ids, binary_tags, followerv, Msg.term, hardv_commit]
         all_goals try (wp_receiver [hk]; refine ⟨_, nodeEq, Or.inl ?_⟩; calm_tac)
         all_goals repeat' (first
           | (apply wp_invoke _ (message_term_spec target (Msg.batch T prev entries commit))
              wp_walk [hk, Fields.value, envelopev, Msg.value, Rej.value, hh, hs, statev_hard, hardv_term, hardv_voted, hpv, binary_absent_present, binary_ne_absent_present, update_statev_hard, update_hardv_term, update_hardv_vote, update_hardv_commit, except_bind_ok_eq, hself, binary_ids, binary_ne_ids, binary_tags, followerv, Msg.term, hardv_commit]
              refine ⟨⟨rfl, by first | rfl | trivial⟩, ?_⟩
              rintro v r ⟨-, rfl⟩
              wp_walk [hk, Fields.value, envelopev, Msg.value, Rej.value, hh, hs, statev_hard, hardv_term, hardv_voted, hpv, binary_absent_present, binary_ne_absent_present, update_statev_hard, update_hardv_term, update_hardv_vote, update_hardv_commit, except_bind_ok_eq, hself, binary_ids, binary_ne_ids, binary_tags, followerv, Msg.term, hardv_commit])
           | (apply wp_invoke_any; wp_walk [hk, Fields.value, envelopev, Msg.value, Rej.value, hh, hs, statev_hard, hardv_term, hardv_voted, hpv, binary_absent_present, binary_ne_absent_present, update_statev_hard, update_hardv_term, update_hardv_vote, update_hardv_commit, except_bind_ok_eq, hself, binary_ids, binary_ne_ids, binary_tags, followerv, Msg.term, hardv_commit])
           | (apply wp_invoke_back _ (follow_u target)
              wp_walk [hk, Fields.value, envelopev, Msg.value, Rej.value, hh, hs, statev_hard, hardv_term, hardv_voted, hpv, binary_absent_present, binary_ne_absent_present, update_statev_hard, update_hardv_term,
           update_hardv_vote, update_hardv_commit, except_bind_ok_eq, binary_tags, followerv, Msg.term, hardv_commit]
              refine ⟨⟨nodeOf, nodeEq, trivial, _, _, _, rfl⟩, ?_⟩
              rintro v r hpost
              obtain ⟨age, rnd, dl, el, rfl⟩ := hpost nodeOf nodeEq _ _ _ rfl
              wp_walk [hk, Fields.value, envelopev, Msg.value, Rej.value, hh, hs, statev_hard, hardv_term, hardv_voted, hpv, binary_absent_present, binary_ne_absent_present, update_statev_hard, update_hardv_term,
           update_hardv_vote, update_hardv_commit, except_bind_ok_eq, binary_tags, followerv, Msg.term, hardv_commit])
           | (apply wp_invoke_back _ (reset_u target)
              wp_walk [hk, Fields.value, envelopev, Msg.value, Rej.value, hh, hs, statev_hard, hardv_term, hardv_voted, hpv, binary_absent_present, binary_ne_absent_present, update_statev_hard, update_hardv_term,
           update_hardv_vote, update_hardv_commit, except_bind_ok_eq, binary_tags, followerv, Msg.term, hardv_commit]
              refine ⟨⟨nodeOf, nodeEq, trivial, _, _, rfl⟩, ?_⟩
              rintro v r hpost
              obtain ⟨n2, rfl, rnd, dl, el, rfl⟩ := hpost nodeOf nodeEq
              wp_walk [hk, Fields.value, envelopev, Msg.value, Rej.value, hh, hs, statev_hard, hardv_term, hardv_voted, hpv, binary_absent_present, binary_ne_absent_present, update_statev_hard, update_hardv_term,
           update_hardv_vote, update_hardv_commit, except_bind_ok_eq, binary_tags, followerv, Msg.term, hardv_commit])
           | (apply wp_invoke_back _ (send_u target)
              wp_walk [hk, Fields.value, envelopev, Msg.value, Rej.value, hh, hs, statev_hard, hardv_term, hardv_voted, hpv, binary_absent_present, binary_ne_absent_present, update_statev_hard, update_hardv_term,
           update_hardv_vote, update_hardv_commit, except_bind_ok_eq, binary_tags, followerv, Msg.term, hardv_commit]
              refine ⟨⟨nodeOf, nodeEq, trivial, os, _, _, _, _, by first | rfl | exact ho, rfl,
                by first | omega | simp_all, by first | omega | simp_all⟩, ?_⟩
              rintro v r hpost
              have := hpost nodeOf nodeEq os _ _ _ _ (by first | rfl | exact ho) rfl
              subst this
              wp_walk [hk, Fields.value, envelopev, Msg.value, Rej.value, hh, hs, statev_hard, hardv_term, hardv_voted, hpv, binary_absent_present, binary_ne_absent_present, update_statev_hard, update_hardv_term,
           update_hardv_vote, update_hardv_commit, except_bind_ok_eq, binary_tags, followerv, Msg.term, hardv_commit])
           | (wp_receiver [hk]; refine ⟨_, nodeEq, Or.inl ?_⟩; calm_tac))
         all_goals
           try (apply wp_scan_here (cursor := 88) (stop := 86) (exit := 3) "usize" _
                  [0, 79, 81, 83, 87, 88, 89, 90, 91, 92, 93, 94, 96, 97, 98, 99]
                  (fun _ e => (∃ nk, e 0 = some nk.value ∧ Calm (demoteF (adoptF n t T c sn en ln) src) nk) ∧
                    (∃ b, e 81 = some (.boolean b)) ∧ ∃ a b, e 83 = some (.record "()" [("0", a), ("1", b)]))
                  (by decide) (by simp (disch := decide) only [set_same, set_other]; rfl) 0
                  (by simp (disch := decide) only [set_same, set_other]) (Nat.zero_le _)
                · refine ⟨?_, ⟨false, ?_⟩, ?_⟩
                  · apply Exists.intro
                    constructor
                    · simp (disch := decide) only [set_same, set_other]; exact congrArg some nodeEq
                    · simp only [demoteF, adoptF]
                      by_cases htT : t < T
                      · simp only [htT, if_true, stepDownF]; calm_tac
                      · simp only [htT, if_false]; calm_tac
                  · simp (disch := decide) only [set_same, set_other]
                  · simp (disch := decide) only [set_same, set_other]; exact ⟨_, _, rfl⟩
                rotate_left
                focus
                  intro e hc' hk' ⟨⟨nk, h0, calmK⟩, ⟨b81, h81⟩, a83, b83, h83⟩
                  obtain ⟨fxD, ⟨tD, vfD, tvD⟩, hoD⟩ := demote_adopt_good (T := T) (src := src) fixed hs ho
                  try simp only [↓reduceIte]
                  wp_walk [h0, hc', hk', h81, h83, hk, Fields.value, envelopev, Msg.value, Rej.value, hh, hs, statev_hard, hardv_term, hardv_voted, hpv, binary_absent_present, binary_ne_absent_present, update_statev_hard, update_hardv_term, update_hardv_vote, update_hardv_commit, except_bind_ok_eq, binary_tags, followerv, Msg.term, hardv_commit]
                rotate_right
                focus
                  intro k e hc' hlt' hbound' hwide' hk' ⟨⟨nk, h0, calmK⟩, ⟨b81, h81⟩, a83, b83, h83⟩
                  obtain ⟨fxD, ⟨tD, vfD, tvD⟩, hoD⟩ := demote_adopt_good (T := T) (src := src) fixed hs ho
                  wp_walk [h0, hc', hk', h81, h83, hk, Fields.value, envelopev, Msg.value, Rej.value, hh, hs, statev_hard, hardv_term, hardv_voted, hpv, binary_absent_present, binary_ne_absent_present, update_statev_hard, update_hardv_term, update_hardv_vote, update_hardv_commit, except_bind_ok_eq, binary_tags, followerv, Msg.term, hardv_commit])
         all_goals
           repeat' (first
             | (apply wp_invoke_any; wp_walk [hk, Fields.value, envelopev, Msg.value, Rej.value, hh, hs, statev_hard, hardv_term, hardv_voted, hpv, binary_absent_present, binary_ne_absent_present, update_statev_hard, update_hardv_term, update_hardv_vote, update_hardv_commit, except_bind_ok_eq, binary_tags, followerv, Msg.term, hardv_commit])
             | (apply wp_invoke_back _ (append_u target ids me cap)
                wp_walk [h0, hc', hk', h81, h83, hk, Fields.value, envelopev, Msg.value, Rej.value, hh, hs, statev_hard, hardv_term, hardv_voted, hpv, binary_absent_present, binary_ne_absent_present, update_statev_hard, update_hardv_term, update_hardv_vote, update_hardv_commit, except_bind_ok_eq, binary_tags, followerv, Msg.term, hardv_commit]
                refine ⟨⟨nk, rfl, ⟨fxD.calm calmK, tD, vfD, calmK.hard _ _ tvD⟩, _, _, _, rfl⟩, ?_⟩
                rintro v r hpost
                obtain ⟨nk', rfl, calmA⟩ := hpost nk rfl
                wp_walk [h0, hc', hk', h81, h83, hk, Fields.value, envelopev, Msg.value, Rej.value, hh, hs, statev_hard, hardv_term, hardv_voted, hpv, binary_absent_present, binary_ne_absent_present, update_statev_hard, update_hardv_term, update_hardv_vote, update_hardv_commit, except_bind_ok_eq, binary_tags, followerv, Msg.term, hardv_commit])
             | (apply wp_invoke_back _ (reply_u target ids cap)
                wp_walk_any [h0, hc', hk', h81, h83, hk, Fields.value, envelopev, Msg.value, Rej.value, hh, hs, statev_hard, hardv_term, hardv_voted, hpv, binary_absent_present, binary_ne_absent_present, update_statev_hard, update_hardv_term, update_hardv_vote, update_hardv_commit, except_bind_ok_eq, binary_tags, followerv, Msg.term, hardv_commit]
                first
                  | refine ⟨⟨_, rfl, (calmK.trans calmA).sized hoD _ sized, _, _, _, rfl, by assumption⟩, ?_⟩
                  | refine ⟨⟨_, rfl, calmK.sized hoD _ sized, _, _, _, rfl, by assumption⟩, ?_⟩
                rintro v r hpost
                obtain ⟨n4, rfl, calmR⟩ := hpost _ rfl
                wp_walk [h0, hc', hk', h81, h83, hk, Fields.value, envelopev, Msg.value, Rej.value, hh, hs, statev_hard, hardv_term, hardv_voted, hpv, binary_absent_present, binary_ne_absent_present, update_statev_hard, update_hardv_term, update_hardv_vote, update_hardv_commit, except_bind_ok_eq, binary_tags, followerv, Msg.term, hardv_commit])
             | (apply wp_invoke_back _ (reply_u target ids cap)
                wp_walk_any [hk, Fields.value, envelopev, Msg.value, Rej.value, hh, hs, statev_hard, hardv_term, hardv_voted, hpv, binary_absent_present, binary_ne_absent_present, update_statev_hard, update_hardv_term, update_hardv_vote, update_hardv_commit, except_bind_ok_eq, binary_tags, followerv, Msg.term, hardv_commit]
                refine ⟨⟨nodeOf, nodeEq, ⟨os, ho, sized⟩, _, _, _, rfl, by assumption⟩, ?_⟩
                rintro v r hpost
                obtain ⟨n4, rfl, calmR⟩ := hpost nodeOf nodeEq
                wp_walk [hk, Fields.value, envelopev, Msg.value, Rej.value, hh, hs, statev_hard, hardv_term, hardv_voted, hpv, binary_absent_present, binary_ne_absent_present, update_statev_hard, update_hardv_term, update_hardv_vote, update_hardv_commit, except_bind_ok_eq, binary_tags, followerv, Msg.term, hardv_commit]))
         all_goals
           first
             | (wp_receiver [hk]
                subst_reads hself
                have hne : src ≠ me := by
                  refine ne_of_check ‹binary _ _ _ "==" (idv src) (idv me) = _› ?_; assumption
                have heq : dst = me := by
                  refine eq_of_check ‹binary _ _ _ "!=" (idv dst) (idv me) = _› ?_; assumption
                subst hp
                first
                  | refine ⟨_, rfl, Or.inr ⟨idle, hsrc, hne, heq, os, bs, ho, hv, ?_⟩⟩
                  | refine ⟨_, nodeEq, Or.inr ⟨idle, hsrc, hne, heq, os, bs, ho, hv, ?_⟩⟩
                simp only [StepOut, Msg.term]
                by_cases hTt : T < t
                · simp only [hTt, if_true]
                  first | (exfalso; omega) | (refine Calm.trans ?_ calmR; calm_tac)
                · simp only [hTt, if_false]
                  first
                    | (exfalso; omega)
                    | exact (calmK.trans calmA).trans calmR
                    | exact calmK.trans calmR)
             | (refine ⟨k + 1, ?_, ?_, ?_, ⟨?_, ?_, ?_⟩⟩
                · simp (disch := decide) only [set_same, set_other]
                · omega
                · wp_kept hk'
                · first
                    | exact ⟨_, by simp (disch := decide) only [set_same, set_other, Fields.value], calmK.trans calmA⟩
                    | exact ⟨nk, by simp (disch := decide) only [set_same, set_other, h0], calmK⟩
                · (simp (disch := decide) only [set_same, set_other, h81]) <;> exact ⟨_, rfl⟩
                · (simp (disch := decide) only [set_same, set_other, h83]) <;> exact ⟨_, _, rfl⟩))

  · intro e hc hk ⟨h10, h13, hnot⟩
    simp only [ite_true]
    wp_walk [h10, hk, Fields.value, hh, okv]
    wp_receiver [hk]
    exact ⟨n, by simp [Fields.value, hh, hpeers, peersv], Or.inl (Calm.refl n)⟩



end Refine
