import Refine
open Provium.State Provium.Imperative
set_option linter.unusedSimpArgs false
namespace Refine

theorem binary_absent_present (bits : Nat) (checked : Bool) (f : Nat) (x : PureValue) :
    binary bits checked f "==" .absent (.present x) =
      (if 1 ≤ f then .ok (.boolean false) else .error (.fault .representation)) := by
  match f with
  | 0 => simp [binary, equal]
  | f + 1 => cases x <;> simp [binary, equal]

theorem binary_ne_absent_present (bits : Nat) (checked : Bool) (f : Nat) (x : PureValue) :
    binary bits checked f "!=" .absent (.present x) =
      (if 1 ≤ f then .ok (.boolean true) else .error (.fault .representation)) := by
  match f with
  | 0 => simp [binary, equal]
  | f + 1 => cases x <;> simp [binary, equal]

theorem ne_absent_present_true {bits : Nat} {checked : Bool} {f : Nat} {x : PureValue} {w : Bool}
    (h : binary bits checked f "!=" .absent (.present x) = .ok (.boolean w)) : w = true := by
  rw [binary_ne_absent_present] at h
  split at h
  · simp only [Except.ok.injEq, PureValue.boolean.injEq] at h; exact h.symm
  · cases h

/-- A calm relation whose fields hold by definition or by the hypotheses in scope. -/
macro "calm_auto'" : term =>
  `({ config := by first | rfl | simp_all [peersv, membershipv, boolsv],
      role := by first | rfl | simp_all [followerv, candidatev, leaderv],
      slot := by first | rfl | simp_all, membership := by first | rfl | simp_all [membershipv],
      bootstrap := by first | rfl | simp_all [membershipv], hooks := by first | rfl | simp_all,
      peers := by first | rfl | simp_all [peersv], votes := by first | rfl | simp_all [boolsv],
      prevoting := by first | rfl | simp_all, extra_reply := by first | rfl | simp_all,
      hard := fun _ _ h => by
        first | exact h | exact termVote_keep (by assumption) _ _ _ _ _ _ h | simp_all,
      dirty := by first | exact Or.inl rfl | exact Or.inr rfl | simp_all,
      outbox := fun os h => ⟨os, by first | exact h | simp_all, Settled.refl os⟩ })

theorem update_statev_hard (env : PureEnv) (rest : List Access) (h sn en ln v : PureValue) :
    update env (.field "hard" :: rest) (statev h sn en ln) v =
      (update env rest h v) >>= fun h' => .ok (statev h' sn en ln) := by
  simp only [statev, update, replaceField_eq]
  simp [setField]
  cases update env rest h v <;> rfl

theorem update_hardv_term (env : PureEnv) (t T : Nat) (vf c : PureValue) :
    update env [.field "term"] (hardv t vf c) (.number "u64" T) = .ok (hardv T vf c) := by
  simp [hardv, update, replaceField_eq, setField]; rfl

theorem update_hardv_vote (env : PureEnv) (t : Nat) (vf c x : PureValue) :
    update env [.field "voted_for"] (hardv t vf c) x = .ok (hardv t x c) := by
  simp [hardv, update, replaceField_eq, setField]; rfl

theorem update_hardv_commit (env : PureEnv) (t : Nat) (vf c x : PureValue) :
    update env [.field "commit"] (hardv t vf c) x = .ok (hardv t vf x) := by
  simp [hardv, update, replaceField_eq, setField]; rfl

theorem dirty_trans {a b c : PureValue} (h1 : b = a ∨ b = .boolean true) (h2 : c = b ∨ c = .boolean true) :
    c = a ∨ c = .boolean true := by
  rcases h2 with rfl | h
  · exact h1
  · exact Or.inr h

theorem outbox_trans {a b c : PureValue}
    (h1 : ∀ os, a = .array os → ∃ os', b = .array os' ∧ Settled os os')
    (h2 : ∀ os, b = .array os → ∃ os', c = .array os' ∧ Settled os os') :
    ∀ os, a = .array os → ∃ os', c = .array os' ∧ Settled os os' := by
  intro os h
  obtain ⟨os1, e1, s1⟩ := h1 os h
  obtain ⟨os2, e2, s2⟩ := h2 os1 e1
  exact ⟨os2, e2, s1.trans s2⟩

theorem outbox_refl (a : PureValue) : ∀ os, a = .array os → ∃ os', a = .array os' ∧ Settled os os' :=
  fun os h => ⟨os, h, Settled.refl os⟩

theorem termVote_trans {a b c : PureValue} (h1 : ∀ t vf, TermVote a t vf → TermVote b t vf)
    (h2 : ∀ t vf, TermVote b t vf → TermVote c t vf) : ∀ t vf, TermVote a t vf → TermVote c t vf :=
  fun t vf h => h2 t vf (h1 t vf h)

/-- Prove a calm relation field by field, failing if any field does not follow. -/
macro "calm_tac" : tactic => `(tactic| (
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  all_goals first
    | rfl
    | (intro _t _vf _h; first | exact _h | exact termVote_keep (by assumption) _ _ _ _ _ _ _h | exact termVote_keep rfl _ _ _ _ _ _ _h)
    | exact Or.inl rfl
    | exact Or.inr rfl
    | (intro _os _h; refine ⟨_os, ?_, Settled.refl _os⟩; first | exact _h | (simp_all; done))
    | (simp_all [followerv, candidatev, leaderv, peersv, membershipv, boolsv, List.map_set]; done)))

/-- `calm_tac` that also chains the facts recorded by `calm_open`. -/
macro "calm_chain" : tactic => `(tactic| (
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  all_goals first
    | rfl
    | (solve_by_elim (maxDepth := 5) [dirty_trans, outbox_trans, outbox_refl, termVote_trans, Or.inl, Or.inr,
        termVote_keep])
    | (simp_all [followerv, candidatev, leaderv, peersv, membershipv, boolsv]; done)))

/-- Replace a node reached by a calm step by its fields, substituting the
    election fields it keeps, and record what it may change. -/
macro "calm_open " c:ident : tactic => `(tactic| (
  obtain ⟨_e1, _e2, _e3, _e4, _e5, _e6, _e7, _e8, _e9, _e10, _hard, _dirty, _out⟩ := $c
  subst _e1 _e2 _e3 _e4 _e5 _e6 _e7 _e8 _e9 _e10))

theorem binary_ne_ids (bits : Nat) (checked : Bool) (f a b : Nat) :
    binary bits checked f "!=" (idv a) (idv b) =
      (if 2 ≤ f then .ok (.boolean (!(a == b))) else .error (.fault .representation)) := by
  match f with
  | 0 => simp [binary, idv, equal]
  | 1 => simp [binary, idv, equal]
  | f + 2 => simp [binary, idv, equal]

theorem ids_differ {bits : Nat} {checked : Bool} {f a b : Nat}
    (h : binary bits checked f "==" (idv a) (idv b) = .ok (.boolean false)) : a ≠ b := by
  rw [binary_ids] at h
  split at h
  · simp at h; exact h
  · cases h

theorem ids_same {bits : Nat} {checked : Bool} {f a b : Nat}
    (h : binary bits checked f "!=" (idv a) (idv b) = .ok (.boolean false)) : a = b := by
  rw [binary_ne_ids] at h
  split at h
  · simpa using h
  · cases h

/-- `uniformize` whose postcondition may also read the argument list. -/
theorem uniformize' {target : Target} {name : String} {body : Expr}
    (hbody : (machine target).functions name = some body) {Pre : Fields → Prop}
    {V : Fields → List PureValue → Prop} {P : Fields → List PureValue → PureValue → PureValue → Prop}
    (h : ∀ n, Pre n → ∀ vs, V n vs → SatisfiesBack (machine target) name
      { pre := fun self values => self = n.value ∧ values = vs, post := fun _ _ v r => P n vs v r }) :
    SatisfiesBack (machine target) name
      { pre := fun self values => ∃ n : Fields, self = n.value ∧ (Pre n ∧ V n values),
        post := fun self values v r => ∀ n : Fields, self = n.value → P n values v r } := by
  apply back_uniform Fields.value Fields.value_inj (fun n values => Pre n ∧ V n values)
    (fun n values v r => P n values v r)
  intro n
  apply back_pointwise hbody
  rintro self values ⟨rfl, pre, hv⟩
  refine back_weaken (h n pre values hv) (fun _ _ h => h) (fun _ vs _ _ ⟨_, e⟩ h => ?_)
  subst e
  exact h

theorem follow_u (target : Target) :
    SatisfiesBack (machine target) "node::Node::follow"
      { pre := fun self values => ∃ n : Fields, self = n.value ∧ (True ∧ ∃ l a b, values = [l, a, b]),
        post := (fun self values _ r => ∀ n : Fields, self = n.value → ∀ l a b, values = [l, a, b] →
          ∃ age rnd dl el, r = { n with role := followerv, prevoting := .absent, leader := l,
                                        leader_age := age, random := rnd, election_deadline := dl,
                                        elapsed := el }.value) } := by
  refine uniformize' (target := target) (name := "node::Node::follow") (P := fun n vs _ r => ∀ l a b, vs = [l, a, b] → ∃ age rnd dl el,
      r = { n with role := followerv, prevoting := .absent, leader := l, leader_age := age, random := rnd,
                   election_deadline := dl, elapsed := el }.value) rfl ?_
  rintro n - vs ⟨l, a, b, rfl⟩
  refine back_weaken (follow_spec target n l) (fun _ _ ⟨h1, h2⟩ => ⟨h1, a, b, h2⟩) ?_
  rintro _ _ _ _ _ ⟨age, rnd, dl, el, rfl⟩ l' a' b' e
  simp only [List.cons.injEq] at e
  obtain ⟨rfl, -, -⟩ := e
  exact ⟨age, rnd, dl, el, rfl⟩

theorem reset_u (target : Target) :
    SatisfiesBack (machine target) "node::Node::reset_election"
      { pre := fun self values => ∃ n : Fields, self = n.value ∧ (True ∧ ∃ a b, values = [a, b]),
        post := (fun self _ _ r => ∀ n : Fields, self = n.value → ∃ n', r = n'.value ∧ ∃ rnd dl el,
          n' = { n with random := rnd, election_deadline := dl, elapsed := el }) } := by
  refine uniformize (target := target) (name := "node::Node::reset_election") rfl ?_
  rintro n - vs ⟨a, b, rfl⟩
  exact back_weaken (reset_election_spec target n) (fun _ _ ⟨h1, h2⟩ => ⟨h1, a, b, h2⟩) (fun _ _ _ _ _ h => h)

theorem send_u (target : Target) :
    SatisfiesBack (machine target) "node::Node::send"
      { pre := fun self values => ∃ n : Fields, self = n.value ∧ (True ∧
          ∃ os p ob N cap, n.outbox = .array os ∧ values = [.number "usize" p, ob, .number "usize" N, cap] ∧
            p < os.length ∧ p ≠ N),
        post := (fun self values _ r => ∀ n : Fields, self = n.value → ∀ os p ob N cap, n.outbox = .array os →
          values = [.number "usize" p, ob, .number "usize" N, cap] →
            r = { n with outbox := .array (os.set p (.present ob)) }.value) } := by
  refine uniformize' (target := target) (name := "node::Node::send") (P := fun n vs _ r => ∀ os p ob N cap,
      n.outbox = .array os → vs = [.number "usize" p, ob, .number "usize" N, cap] →
        r = { n with outbox := .array (os.set p (.present ob)) }.value) rfl ?_
  rintro n - vs ⟨os, p, ob, N, cap, ho, rfl, hp, hN⟩
  refine back_weaken (send_spec target n os p N ob cap hp hN) (fun _ _ ⟨h1, h2⟩ => ⟨h1, ho, h2⟩) ?_
  rintro _ _ _ _ _ rfl os' p' ob' N' cap' ho' e
  rw [ho] at ho'; cases ho'
  simp only [List.cons.injEq, PureValue.number.injEq] at e
  obtain ⟨⟨-, rfl⟩, rfl, ⟨-, rfl⟩, rfl, -⟩ := e
  rfl

theorem reply_u (target : Target) (ids : List Nat) (cap : PureValue) :
    SatisfiesBack (machine target) "node::Node::reply"
      { pre := fun self values => ∃ n : Fields, self = n.value ∧
          ((∃ os, n.outbox = .array os ∧ os.length = ids.length) ∧
            ∃ p index rej, values = [.number "usize" p, index, rej, .number "usize" ids.length, cap] ∧
              p < ids.length),
        post := fun self _ _ r => ∀ n : Fields, self = n.value → ∃ n', r = n'.value ∧ Calm n n' } := by
  refine uniformize (target := target) (name := "node::Node::reply") rfl ?_
  rintro n ⟨os, ho, sized⟩ vs ⟨p, index, rej, rfl, hp⟩
  refine back_weaken (reply_spec target n os p ids.length index rej cap (by omega) (by omega))
    (fun _ _ ⟨h1, h2⟩ => ⟨h1, ho, h2⟩) ?_
  rintro _ _ _ _ _ rfl
  refine ⟨_, rfl, ?_⟩
  exact { config := rfl, role := rfl, slot := rfl, membership := rfl, bootstrap := rfl, hooks := rfl,
          peers := rfl, votes := rfl, prevoting := rfl, extra_reply := rfl, hard := fun _ _ h => h,
          dirty := Or.inl rfl,
          outbox := fun os' h => by
            rw [ho] at h; cases h
            exact ⟨_, rfl, (Settled.refl os).set p _ (Or.inr ⟨_, _, rfl⟩)⟩ }

theorem append_u (target : Target) (ids : List Nat) (me : Nat) (cap : PureValue) :
    SatisfiesBack (machine target) "node::Node::append"
      { pre := fun self values => ∃ n : Fields, self = n.value ∧
          ((Fixed ids me n ∧ ∃ t vf, TermVote n.state t vf) ∧
            ∃ prev entry commit, values = [prev, entry, commit, .number "usize" ids.length, cap]),
        post := fun self _ _ r => ∀ n : Fields, self = n.value → ∃ n', r = n'.value ∧ Calm n n' } := by
  refine uniformize (target := target) (name := "node::Node::append") rfl ?_
  rintro n ⟨fixed, t, vf, c, sn, en, ln, hs⟩ vs ⟨prev, entry, commit, rfl⟩
  exact back_weaken (append_spec target n ids me fixed t vf c sn en ln hs prev entry commit cap)
    (fun _ _ h => h) (fun _ _ _ _ _ h => h)

theorem replicated_u (target : Target) (ids : List Nat) (me : Nat) (cap : PureValue) :
    SatisfiesBack (machine target) "node::Node::replicated"
      { pre := fun self values => ∃ n : Fields, self = n.value ∧
          ((Good ids me n ∧ ∃ t vf, TermVote n.state t vf) ∧
            ∃ (p : Nat) (index : PureValue) (rej : Rej),
              values = [.number "usize" p, index, rej.value, .number "usize" ids.length, cap] ∧
              p < ids.length),
        post := fun self _ _ r => ∀ n : Fields, self = n.value → ∃ n', r = n'.value ∧ Calm n n' } := by
  refine uniformize (target := target) (name := "node::Node::replicated") rfl ?_
  rintro n ⟨good, t, vf, c, sn, en, ln, hs⟩ vs ⟨p, index, rej, rfl, hp⟩
  refine back_weaken (replicated_spec target n ids me good t vf c sn en ln hs p hp index rej.value cap ?_)
    (fun _ _ h => h) (fun _ _ _ _ _ h => h)
  cases rej
  · exact Or.inl rfl
  · exact Or.inr (Or.inl ⟨_, rfl⟩)
  · exact Or.inr (Or.inr rfl)

theorem become_leader_u (target : Target) (ids : List Nat) (me : Nat) (cap : PureValue) :
    SatisfiesBack (machine target) "node::Node::become_leader"
      { pre := fun self values => ∃ n : Fields, self = n.value ∧
          ((Fixed ids me n ∧ (∃ t vf, TermVote n.state t vf) ∧
            ∃ os, n.outbox = .array os ∧ os.length = ids.length) ∧ values = [.number "usize" ids.length, cap]),
        post := fun self _ _ r => ∀ n : Fields, self = n.value →
          ∃ n', r = n'.value ∧ Calm { n with role := leaderv } n' } := by
  refine uniformize (target := target) (name := "node::Node::become_leader") rfl ?_
  rintro n ⟨fixed, ⟨t, vf, c, sn, en, ln, hs⟩, os, ho, sized⟩ vs rfl
  exact back_weaken (become_leader_spec target n ids me fixed t vf c sn en ln hs os ho sized cap)
    (fun _ _ h => h) (fun _ _ _ _ _ h => h)

/-- `Fixed` carries over to a node with the same configuration fields. -/
theorem Fixed.of_eq {ids : List Nat} {me : Nat} {n n' : Fields} (f : Fixed ids me n)
    (h1 : n'.membership = n.membership) (h2 : n'.bootstrap = n.bootstrap) (h3 : n'.hooks = .absent)
    (h4 : n'.peers = peersv ids) (h5 : n'.config = n.config) (h6 : n'.local = n.local) : Fixed ids me n' where
  unique := f.unique
  member := f.member
  membership := h1.trans f.membership
  bootstrap := h2.trans f.bootstrap
  hooks := h3
  peers := h4
  self := by rw [h5]; exact f.self
  slot := h6.trans f.slot

/-- A calm step keeps the outbox an array of the same length. -/
theorem Calm.sized {n n' : Fields} {os : List PureValue} (c : Calm n n') (ho : n.outbox = .array os) (k : Nat)
    (s : os.length = k) : ∃ os', n'.outbox = .array os' ∧ os'.length = k := by
  obtain ⟨os', ho', set⟩ := c.outbox os ho
  exact ⟨os', ho', set.1.trans s⟩

/-- Assigning through an index of the votes table. -/
theorem update_boolsv (env : PureEnv) (acc : List Access) (bs : List Bool) (v : PureValue) :
    update env acc (boolsv bs) v = update env acc (.array (bs.map .boolean)) v := rfl

/-- The `role == Candidate` check of a node with a known role. -/
theorem role_check_candidate {bits : Nat} {checked : Bool} {f : Nat} {r : PureValue} {w : Bool}
    (h : binary bits checked f "==" r (.variant "Role" "Candidate" []) = .ok (.boolean w))
    (hr : r = followerv ∨ r = candidatev ∨ r = leaderv) : (w = true ↔ r = candidatev) := by
  rcases hr with rfl | rfl | rfl <;>
    simp only [followerv, candidatev, leaderv, binary_tags] at h ⊢ <;>
    split at h <;> simp_all

/-- A read of the votes table succeeds exactly within bounds. -/
theorem some_map_boolean (bs : List Bool) (j : Nat) :
    (∃ x, (bs.map PureValue.boolean)[j]? = some x) ↔ j < bs.length := by
  constructor
  · rintro ⟨x, hx⟩
    rw [List.getElem?_map] at hx
    cases h : bs[j]? with
    | none => rw [h] at hx; cases hx
    | some b => exact (List.getElem?_eq_some_iff.mp h).1
  · intro hj
    exact ⟨_, by rw [List.getElem?_map, List.getElem?_eq_getElem hj]; rfl⟩

/-! ### `step` -/

open Lean Elab Tactic Meta in
/-- Replaces each opaque read `x = some w` (with `w` a variable) of the read that
    `h : x = some v` determines by `v`, dropping the read. -/
elab "subst_reads " h:ident : tactic => withMainContext do
  let hd ← getLocalDeclFromUserName h.getId
  let some (_, lhs, _) := (← instantiateMVars hd.type).eq? | throwError "subst_reads: not an equation"
  let hName := h.getId
  repeat
    let g ← getMainGoal
    let found ← g.withContext do
      let hd ← getLocalDeclFromUserName hName
      for d in (← getLCtx) do
        if d.isImplementationDetail || d.fvarId == hd.fvarId then continue
        let some (_, l, r) := (← instantiateMVars d.type).eq? | continue
        unless l == lhs do continue
        unless r.isAppOfArity ``Option.some 2 do continue
        let w := r.appArg!
        unless w.isFVar do continue
        let pf ← mkAppM ``Option.some.inj #[← mkEqTrans (← mkEqSymm hd.toExpr) d.toExpr]
        return some (d.fvarId, pf)
      return none
    let some (fv, pf) := found | break
    let g ← getMainGoal
    let (e, g) ← g.withContext do
      let g ← g.assert `_read (← inferType pf) pf
      g.intro1P
    let g ← g.withContext do
      let g ← g.tryClear fv
      subst g e
    replaceMainGoal [g]


theorem equal_number {f : Nat} {x : PureValue} {k : String} {a : Nat}
    (h : equal f x (.number k a) = some true) : x = .number k a := by
  match f, x with
  | 0, _ => simp [equal] at h
  | f + 1, .number k' b =>
    simp only [equal] at h
    split at h
    · rename_i hk
      simp only [Option.some.injEq, beq_iff_eq] at h
      subst hk; subst h; rfl
    · cases h
  | f + 1, .unit | f + 1, .boolean _ | f + 1, .absent | f + 1, .present _ | f + 1, .variant _ _ _
  | f + 1, .record _ _ | f + 1, .array _ => simp [equal] at h

theorem equal_id {f : Nat} {x : PureValue} {a : Nat} (h : equal f x (idv a) = some true) : x = idv a := by
  match f, x with
  | 0, _ => simp [equal] at h
  | f + 1, .record name fields =>
    simp only [equal, idv] at h
    split at h
    · cases h
    rename_i hn
    simp only [Decidable.not_not] at hn
    subst hn
    match fields with
    | [] => simp at h
    | [(k, v)] =>
      simp only [List.zip_cons_cons, List.zip_nil_right, List.foldl_cons, List.foldl_nil, List.length_cons,
        List.length_nil, ite_true] at h
      split at h
      · cases h
      rename_i hk
      simp only [Decidable.not_not] at hk
      subst hk
      cases hv : equal f v (.number "u64" a) with
      | none => simp [hv] at h
      | some w =>
        simp only [hv, Option.map_some, Bool.true_and, Option.some.injEq] at h
        subst h
        rw [equal_number hv]; rfl
    | _ :: _ :: _ => simp at h
  | f + 1, .unit | f + 1, .boolean _ | f + 1, .absent | f + 1, .present _ | f + 1, .variant _ _ _
  | f + 1, .number _ _ | f + 1, .array _ => simp [equal, idv] at h

theorem id_of_check {bits : Nat} {checked : Bool} {f a : Nat} {x : PureValue} {w : Bool}
    (h : binary bits checked f "==" x (idv a) = .ok (.boolean w)) (hw : w = true) : x = idv a := by
  subst hw
  unfold binary at h
  split at h
  · simp [idv] at *
  · simp [idv] at *
  · split at h
    · rename_i hv
      simp at h; subst h; exact equal_id hv
    · cases h
/-- An `==` check of two ids that came out false. -/
theorem ne_of_check {bits : Nat} {checked : Bool} {f a b : Nat} {w : Bool}
    (h : binary bits checked f "==" (idv a) (idv b) = .ok (.boolean w)) (hw : ¬w = true) : a ≠ b := by
  rw [binary_ids] at h
  split at h
  · simp only [Except.ok.injEq, PureValue.boolean.injEq] at h
    subst h; simpa using hw
  · cases h

/-- A `!=` check of two ids that came out false. -/
theorem eq_of_check {bits : Nat} {checked : Bool} {f a b : Nat} {w : Bool}
    (h : binary bits checked f "!=" (idv a) (idv b) = .ok (.boolean w)) (hw : ¬w = true) : a = b := by
  rw [binary_ne_ids] at h
  split at h
  · simp only [Except.ok.injEq, PureValue.boolean.injEq] at h
    subst h; simpa using hw
  · cases h

/-- Observing a higher term: the new term, no vote, a dirty Follower with no probe or leader. -/
def stepDownF (n : Fields) (T : Nat) (c sn en ln : PureValue) : Fields :=
  { n with state := statev (hardv T .absent c) sn en ln, dirty := .boolean true, role := followerv,
           prevoting := .absent, leader := .absent }

/-- The node after the term check of a message with term `T`. -/
def adoptF (n : Fields) (t T : Nat) (c sn en ln : PureValue) : Fields :=
  if t < T then stepDownF n T c sn en ln else n

/-- Following the sender of a replication message. -/
def demoteF (n : Fields) (src : Nat) : Fields :=
  { n with role := followerv, prevoting := .absent, leader := .present (idv src) }

def prevotedv (T : Nat) (g : Bool) : PureValue :=
  .present (.variant "Outbound" "PreVoted" [("0", .number "u64" T), ("1", .boolean g)])

def votedv (g : Bool) : PureValue := .present (.variant "Outbound" "Voted" [("0", .boolean g)])

open Classical in
/-- What handling message `m` from `src` leaves, relative to the node before it
    (term `t`, vote `vf`, idle outbox `os`, votes `bs`), up to calm changes. -/
noncomputable def StepOut (ids : List Nat) (n : Fields) (t : Nat) (vf c sn en ln : PureValue) (os : List PureValue)
    (bs : List Bool) (src : Nat) (m : Msg) (n' : Fields) : Prop :=
  match m with
  | .prevote T _ => ∃ g, Calm { n with outbox := .array (os.set (ids.idxOf src) (prevotedv T g)) } n'
  | .prevoted T _ _ => Calm (adoptF n t T c sn en ln) n'
  | .vote T _ =>
    if T < t then Calm { n with outbox := .array (os.set (ids.idxOf src) (votedv false)) } n'
    else
      let vf1 := if t < T then PureValue.absent else vf
      let n1 := adoptF n t T c sn en ln
      ∃ g : Bool, (g = true → vf1 = .absent ∨ vf1 = .present (idv src)) ∧
        Calm (if g then { n1 with state := statev (hardv T (.present (idv src)) c) sn en ln,
                                  dirty := if vf1 = .present (idv src) then n1.dirty else .boolean true,
                                  outbox := .array (os.set (ids.idxOf src) (votedv true)) }
              else { n1 with outbox := .array (os.set (ids.idxOf src) (votedv false)) }) n'
  | .voted T g =>
    let n1 := adoptF n t T c sn en ln
    if max t T = T ∧ n1.role = candidatev ∧ g = true then
      let bs' := bs.set (ids.idxOf src) true
      (ids.length / 2 < granted bs' ∧ Calm { n1 with votes := boolsv bs', role := leaderv } n') ∨
        (¬ ids.length / 2 < granted bs' ∧ Calm { n1 with votes := boolsv bs' } n')
    else Calm n1 n'
  | .append T _ _ _ | .batch T _ _ _ | .install T _ =>
    if T < t then Calm n n' else Calm (demoteF (adoptF n t T c sn en ln) src) n'
  | .replicated T _ _ => Calm (adoptF n t T c sn en ln) n'

open Classical in
/-- Establishing the `Voted` outcome by its two arms, with the term check folded. -/
theorem stepOut_voted_of {ids : List Nat} {n n' : Fields} {t : Nat} {vf c sn en ln : PureValue}
    {os : List PureValue} {bs : List Bool} {src T : Nat} {g : Bool}
    (yes : max t T = T → (adoptF n t T c sn en ln).role = candidatev → g = true →
      (ids.length / 2 < granted (bs.set (ids.idxOf src) true) ∧
          Calm { adoptF n t T c sn en ln with votes := boolsv (bs.set (ids.idxOf src) true), role := leaderv } n') ∨
        (¬ ids.length / 2 < granted (bs.set (ids.idxOf src) true) ∧
          Calm { adoptF n t T c sn en ln with votes := boolsv (bs.set (ids.idxOf src) true) } n'))
    (no : ¬(max t T = T ∧ (adoptF n t T c sn en ln).role = candidatev ∧ g = true) →
      Calm (adoptF n t T c sn en ln) n') :
    StepOut ids n t vf c sn en ln os bs src (.voted T g) n' := by
  simp only [StepOut]
  split
  · rename_i h; exact yes h.1 h.2.1 h.2.2
  · rename_i h; exact no h

/-- The node a current replication message leaves before its log work: still
    fixed, with a term and vote, and the same outbox. -/
theorem demote_adopt_good {ids : List Nat} {me : Nat} {n : Fields} {t T src : Nat} {vf c sn en ln : PureValue}
    {os : List PureValue} (fixed : Fixed ids me n) (hs : n.state = statev (hardv t vf c) sn en ln)
    (ho : n.outbox = .array os) :
    Fixed ids me (demoteF (adoptF n t T c sn en ln) src) ∧
      (∃ t' vf', TermVote (demoteF (adoptF n t T c sn en ln) src).state t' vf') ∧
      (demoteF (adoptF n t T c sn en ln) src).outbox = .array os := by
  unfold demoteF adoptF
  split
  · exact ⟨fixed.of_eq rfl rfl fixed.hooks fixed.peers rfl rfl, ⟨_, _, _, _, _, _, rfl⟩, ho⟩
  · exact ⟨fixed.of_eq rfl rfl fixed.hooks fixed.peers rfl rfl, ⟨_, _, _, _, _, _, hs⟩, ho⟩

end Refine
