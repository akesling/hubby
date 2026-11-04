import AbsStep
open Provium.State Provium.Imperative
set_option linter.unusedSimpArgs false
namespace Refine

set_option maxHeartbeats 4000000 in
/-- `build` for a stable configuration whose members include this node: the
    node is `Good`, keeps the given checkpoint, and starts as a clean follower
    with no votes and an empty outbox. -/
theorem build_spec (target : Target) (ids : List Nat) (me : Nat) (unique : ids.Nodup) (hme : me ∈ ids)
    (config : PureValue) (hself : pureField config "id" = some (idv me))
    (t : Nat) (vf c sn en ln : PureValue) (cap self : PureValue) {fuel : Nat} {v r : PureValue}
    (h : Jarl.node_Node_build target fuel self [config, statev (hardv t vf c) sn en ln, membershipv ids,
      .absent, .number "usize" ids.length, cap] = .ok (v, r)) :
    ∀ x, v = .variant "Result" "Ok" [("0", x)] → ∃ n : Fields, x = n.value ∧ Good ids me n ∧
      n.state = statev (hardv t vf c) sn en ln ∧ n.role = followerv ∧
      n.votes = boolsv (List.replicate ids.length false) ∧
      n.outbox = .array (List.replicate ids.length .absent) ∧ n.dirty = .boolean false := by
  simp only [Jarl.node_Node_build] at h
  refine run_of_wp (m := machine target) (P := fun v _ => ∀ x, v = .variant "Result" "Ok" [("0", x)] →
    ∃ n : Fields, x = n.value ∧ Good ids me n ∧
      n.state = statev (hardv t vf c) sn en ln ∧ n.role = followerv ∧
      n.votes = boolsv (List.replicate ids.length false) ∧
      n.outbox = .array (List.replicate ids.length .absent) ∧ n.dirty = .boolean false) ?_ h
  simp only [Jarl.node_Node_build_ir, frameOf, List.zipIdx, List.foldl]
  wp_walk
  all_goals try (intro _ _ x hx; simp at hx; done)
  apply wp_invoke _ (peers_spec target ids)
  wp_walk
  refine ⟨⟨trivial, _, rfl⟩, ?_⟩
  rintro v r ⟨-, rfl⟩
  wp_walk [peersv]
  -- This node's slot in the peer table.
  apply wp_scan_here "usize" ids.length [18, 19, 20, 21, 22, 23]
    (fun j e => e 18 = some .absent ∧ e 21 = some (.number "usize" j) ∧ me ∉ ids.take j) (by decide)
    (by simp (disch := decide) only [set_same, set_other, List.length_map]) 0
    (by simp (disch := decide) only [set_same]) (Nat.zero_le _)
    (by simp (disch := decide) only [set_same, set_other]; simp)
  · intro j e hc hlt hbound hwide hk ⟨h18, h21, hnot⟩
    wp_walk [hc, hk, hlt, h18, h21, binary_present_ids, hself]
    case no =>
      refine ⟨j + 1, by simp (disch := decide) only [set_same, set_other], by omega, by wp_kept hk,
        by simp (disch := decide) only [set_other, h18], by simp (disch := decide) only [set_same], ?_⟩
      simp only [take_succ ids j hlt, List.mem_append, List.mem_singleton, not_or]
      exact ⟨hnot, fun h => ‹¬(ids[j] == me) = true› (by simp [h])⟩
    -- The outbox: one empty slot per peer.
    apply wp_range_here "usize" 0 [41, 43, 44] (fun hi i e => hi = ids.length ∧
      e 44 = some (.array (List.replicate i .absent ++ (List.replicate ids.length .unit).drop i)))
    · wp_walk
      refine ⟨by first | trivial | rfl, fun hi hhi => ?_⟩
      cases hhi
      refine ⟨Nat.zero_le _, by first | trivial | exact fun _ _ => rfl | exact fun _ _ => trivial, by first | trivial | rfl, ?_⟩
      simp (disch := decide) only [set_same, set_other]
      simp
    · rintro hi i e - hlt hkept ⟨rfl, he44⟩
      wp_walk [he44]
      obtain ⟨-, rfl⟩ := ‹_ ∧ _›
      refine ⟨by wp_kept hkept, trivial, ?_⟩
      rw [set_same, replicate_drop_set _ _ i (by simpa using hlt)]
    · rintro hi e v hkept ⟨rfl, he44⟩
      wp_walk [he44, hkept]
      have hj : ids[j] = me := by simpa using ‹(ids[j] == me) = true›
      have hp : j = ids.idxOf me := by
        have h1 := List.getElem_idxOf (List.idxOf_lt_length_of_mem hme)
        exact (List.getElem_inj unique).mp (hj.trans h1.symm)
      subst hp
      apply wp_invoke_back _ (refresh_u target ids me cap)
      wp_walk [hkept, hk]
      refine ⟨⟨nodeOf, nodeEq, ⟨unique, hme, rfl, rfl, rfl, rfl, hself, rfl⟩, by first | trivial | rfl⟩, ?_⟩
      rintro v r hpost
      have := hpost nodeOf nodeEq
      subst this
      wp_walk
      apply wp_invoke_back _ (reset_u target)
      wp_walk [hkept, hk]
      refine ⟨⟨nodeOf, nodeEq, trivial, _, _, rfl⟩, ?_⟩
      rintro v r hpost
      obtain ⟨n2, rfl, rnd, dl, el, rfl⟩ := hpost nodeOf nodeEq
      wp_walk [hkept, hk]
      wp_receiver [hkept, hk]
      intro x hx
      simp only [PureValue.variant.injEq, List.cons.injEq, Prod.mk.injEq, true_and, and_true] at hx
      subst hx
      refine ⟨_, rfl, ?_, rfl, rfl, by simp [boolsv], by simp, rfl⟩
      exact { fixed := ⟨unique, hme, rfl, rfl, rfl, rfl, hself, rfl⟩
              votes := ⟨List.replicate ids.length false, by simp [boolsv], by simp⟩
              outbox := ⟨_, rfl, by simp, fun o ho => Or.inl (by
                simp only [List.drop_replicate, Nat.sub_self, List.replicate_zero, List.append_nil] at ho
                exact List.eq_of_mem_replicate ho)⟩
              dirty := ⟨false, rfl⟩
              extra := rfl
              role := Or.inl rfl
              prevoting := rfl }
  · intro e hc hk ⟨h18, h21, hnot⟩
    exact absurd (by simpa using hme) hnot

/-- A built node is the model's node restarted from its checkpoint (`crash`);
    from term 0 with no vote it is `fresh`. -/
theorem Abs.built (ids : List Nat) {n : Fields} {t : Nat} {vote : Option Nat} {c sn en ln : PureValue}
    (hs : n.state = statev (hardv t (voteValue vote) c) sn en ln) (hr : n.role = followerv)
    (hv : n.votes = boolsv (List.replicate ids.length false))
    (ho : n.outbox = .array (List.replicate ids.length .absent)) :
    Abs ids n ⟨t, vote⟩ ⟨t, vote, .follower, [], false, ⟨t, vote⟩, [], none⟩ where
  state := ⟨c, sn, en, ln, hs⟩
  role := by rw [hr]; rfl
  votes := ⟨_, hv, fun x => by
    simp only [List.not_mem_nil, false_iff, votesOf, List.mem_map, List.mem_filter, not_exists, not_and]
    intro p ⟨hp, hb⟩ _
    rw [List.eq_of_mem_replicate (List.of_mem_zip hp).2] at hb
    exact absurd hb (by decide)⟩
  dirty := fun _ => rfl
  durable := rfl
  outbox := ⟨_, ho, (outboxOf_absent ids _ (fun _ h => List.eq_of_mem_replicate h)).symm⟩
  prevoting := rfl

end Refine
