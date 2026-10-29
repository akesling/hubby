import Generated
import Provium.Wp
open Provium.State Provium.Imperative
set_option linter.unusedSimpArgs false
namespace Refine

/-! Values of Jarl's types as the generated code represents them. -/

def idv (i : Nat) : PureValue := .record "Id" [("0", .number "u64" i)]

/-- A voting member of a stable configuration. -/
def memberv (i : Nat) : PureValue :=
  .record "Member" [("id", idv i), ("voter", .boolean true), ("old", .boolean false),
    ("learner", .boolean false)]

/-- `Membership::new(ids, &[])` for distinct `ids`: one voting member per slot, in order. -/
def membershipv (ids : List Nat) : PureValue :=
  .record "Membership" [("members", .array (ids.map fun i => .present (memberv i)))]

def machine (target : Target) : Machine := { toTarget := target, functions := Jarl.imperative_functions }

theorem binary_ids (bits : Nat) (checked : Bool) (f a b : Nat) :
    binary bits checked f "==" (idv a) (idv b) =
      (if 2 ≤ f then .ok (.boolean (a == b)) else .error (.fault .representation)) := by
  match f with
  | 0 => simp [binary, idv, equal]
  | 1 => simp [binary, idv, equal]
  | f + 2 => simp [binary, idv, equal]

theorem binary_present_ids (bits : Nat) (checked : Bool) (f a b : Nat) :
    binary bits checked f "==" (.present (idv a)) (.present (idv b)) =
      (if 3 ≤ f then .ok (.boolean (a == b)) else .error (.fault .representation)) := by
  match f with
  | 0 => simp [binary, idv, equal]
  | 1 => simp [binary, idv, equal]
  | 2 => simp [binary, idv, equal]
  | f + 3 => simp [binary, idv, equal]

theorem binary_tags (bits : Nat) (checked : Bool) (f : Nat) (o t1 t2 : String) :
    binary bits checked f "==" (.variant o t1 []) (.variant o t2 []) =
      (if 1 ≤ f then .ok (.boolean (decide (t1 = t2))) else .error (.fault .representation)) := by
  match f with
  | 0 => simp [binary, equal]
  | f + 1 =>
    by_cases h : t1 = t2
    · subst h; simp [binary, equal]
    · simp [binary, equal, h]

theorem take_succ {α : Type} (l : List α) (k : Nat) (h : k < l.length) :
    l.take (k + 1) = l.take k ++ [l[k]] := by
  rw [List.take_add_one, List.getElem?_eq_getElem h]; rfl

/-- `is_voter` over a stable configuration is membership of the identity. -/
theorem is_voter_spec (target : Target) (ids : List Nat) (x : Nat) :
    Satisfies (machine target) "membership::Membership::is_voter"
      { pre := fun self values => self = membershipv ids ∧ ∃ n, values = [idv x, n],
        post := fun _ _ v r => r = membershipv ids ∧ v = .boolean (decide (x ∈ ids)) } := by
  refine ⟨_, rfl, ?_⟩
  rintro self values ⟨rfl, n, rfl⟩
  apply Wp.triple
  rintro env rfl
  simp only [Jarl.function_membership_Membership_is_voter, frameOf, List.zipIdx, List.foldl]
  wp_walk [membershipv]
  apply wp_scan_here "usize" ids.length [7, 8, 9, 11, 12]
    (fun k e => e 7 = some (.boolean false) ∧ x ∉ ids.take k) (by decide)
    (by simp (disch := decide) only [set_same, set_other, List.length_map]) 0
    (by simp (disch := decide) only [set_same]) (Nat.zero_le _)
    (by simp (disch := decide) only [set_same, set_other]; simp)
  · intro k e hc hlt hbound hwide hkept ⟨h7, hnot⟩
    wp_walk [hc, hkept, hlt, h7, membershipv, memberv, binary_ids]
    all_goals first
      | (refine ⟨k + 1, by simp (disch := decide) only [set_same, set_other], by omega, by wp_kept hkept, ?_⟩
         simp (disch := decide) only [set_same, set_other, h7, true_and]
         simp only [take_succ ids k hlt, List.mem_append, List.mem_singleton, not_or]
         refine ⟨hnot, ?_⟩
         intro h
         subst h
         simp_all)
      | (refine ⟨membershipv ids, ?_, rfl, ?_⟩
         · simp (disch := decide) only [set_same, set_other, hkept]
         · have : ids[k] = x := by simpa using ‹(ids[k] == x) = true›
           simp only [PureValue.boolean.injEq, decide_eq_true_eq]
           exact (decide_eq_true (this ▸ List.getElem_mem hlt)).symm)
  · intro e hc hkept ⟨h7, hnot⟩
    simp only [ite_true]
    wp_walk [h7]
    refine ⟨membershipv ids, by simp (disch := decide) only [hkept, set_same, set_other], rfl, ?_⟩
    simpa using hnot

/-- `contains` over a stable configuration is membership of the identity. -/
theorem contains_spec (target : Target) (ids : List Nat) (x : Nat) :
    Satisfies (machine target) "membership::Membership::contains"
      { pre := fun self values => self = membershipv ids ∧ ∃ n, values = [idv x, n],
        post := fun _ _ v r => r = membershipv ids ∧ v = .boolean (decide (x ∈ ids)) } := by
  refine ⟨_, rfl, ?_⟩
  rintro self values ⟨rfl, n, rfl⟩
  apply Wp.triple
  rintro env rfl
  simp only [Jarl.function_membership_Membership_contains, frameOf, List.zipIdx, List.foldl]
  wp_walk [membershipv]
  apply wp_scan_here "usize" ids.length [7, 8, 9, 11, 12]
    (fun k e => e 7 = some (.boolean false) ∧ x ∉ ids.take k) (by decide)
    (by simp (disch := decide) only [set_same, set_other, List.length_map]) 0
    (by simp (disch := decide) only [set_same]) (Nat.zero_le _)
    (by simp (disch := decide) only [set_same, set_other]; simp)
  · intro k e hc hlt hbound hwide hkept ⟨h7, hnot⟩
    wp_walk [hc, hkept, hlt, h7, membershipv, memberv, binary_ids]
    all_goals first
      | (refine ⟨k + 1, by simp (disch := decide) only [set_same, set_other], by omega, by wp_kept hkept, ?_⟩
         simp (disch := decide) only [set_same, set_other, h7, true_and]
         simp only [take_succ ids k hlt, List.mem_append, List.mem_singleton, not_or]
         refine ⟨hnot, ?_⟩
         intro h
         subst h
         simp_all)
      | (refine ⟨membershipv ids, ?_, rfl, ?_⟩
         · simp (disch := decide) only [set_same, set_other, hkept]
         · have : ids[k] = x := by simpa using ‹(ids[k] == x) = true›
           simp only [PureValue.boolean.injEq, decide_eq_true_eq]
           exact (decide_eq_true (this ▸ List.getElem_mem hlt)).symm)
  · intro e hc hkept ⟨h7, hnot⟩
    simp only [ite_true]
    wp_walk [h7]
    refine ⟨membershipv ids, by simp (disch := decide) only [hkept, set_same, set_other], rfl, ?_⟩
    simpa using hnot

/-- A stable configuration is never joint. -/
theorem is_joint_spec (target : Target) (ids : List Nat) :
    Satisfies (machine target) "membership::Membership::is_joint"
      { pre := fun self values => self = membershipv ids ∧ ∃ n, values = [n],
        post := fun _ _ v r => r = membershipv ids ∧ v = .boolean false } := by
  refine ⟨_, rfl, ?_⟩
  rintro self values ⟨rfl, n, rfl⟩
  apply Wp.triple
  rintro env rfl
  simp only [Jarl.function_membership_Membership_is_joint, frameOf, List.zipIdx, List.foldl]
  wp_walk [membershipv]
  apply wp_scan_here "usize" ids.length [5, 6, 7, 9, 10] (fun _ e => e 5 = some (.boolean false)) (by decide)
    (by simp (disch := decide) only [set_same, set_other, List.length_map]) 0
    (by simp (disch := decide) only [set_same]) (Nat.zero_le _)
    (by simp (disch := decide) only [set_same, set_other])
  · intro k e hc hlt hbound hwide hkept h5
    wp_walk [hc, hkept, hlt, h5, membershipv, memberv]
    exact ⟨k + 1, by simp (disch := decide) only [set_same, set_other], by omega, by wp_kept hkept,
      by simp (disch := decide) only [set_other, h5]⟩
  · intro e hc hkept h5
    simp only [ite_true]
    wp_walk [h5]
    exact ⟨membershipv ids, by simp (disch := decide) only [hkept, set_same, set_other], rfl, trivial⟩

/-- The fields of `jarl::node::Node` in declaration order. -/
structure Fields where
  config : PureValue
  state : PureValue
  role : PureValue
  leader : PureValue
  «local» : PureValue
  membership : PureValue
  bootstrap : PureValue
  hooks : PureValue
  peers : PureValue
  votes : PureValue
  next : PureValue
  matched : PureValue
  outbox : PureValue
  dirty : PureValue
  log_from : PureValue
  snapshot_changed : PureValue
  elapsed : PureValue
  election_deadline : PureValue
  random : PureValue
  prevoting : PureValue
  leader_age : PureValue
  quorum_elapsed : PureValue
  active : PureValue
  extra_reply : PureValue
  request_from : PureValue

def Fields.value (n : Fields) : PureValue :=
  .record "Node" [("config", n.config), ("state", n.state), ("role", n.role), ("leader", n.leader),
    ("local", n.local), ("membership", n.membership), ("bootstrap", n.bootstrap), ("hooks", n.hooks),
    ("peers", n.peers), ("votes", n.votes), ("next", n.next), ("matched", n.matched),
    ("outbox", n.outbox), ("dirty", n.dirty), ("log_from", n.log_from),
    ("snapshot_changed", n.snapshot_changed), ("elapsed", n.elapsed),
    ("election_deadline", n.election_deadline), ("random", n.random), ("prevoting", n.prevoting),
    ("leader_age", n.leader_age), ("quorum_elapsed", n.quorum_elapsed), ("active", n.active),
    ("extra_reply", n.extra_reply), ("request_from", n.request_from)]

instance : Inhabited Fields := ⟨⟨.unit, .unit, .unit, .unit, .unit, .unit, .unit, .unit, .unit, .unit, .unit, .unit, .unit, .unit, .unit, .unit, .unit, .unit, .unit, .unit, .unit, .unit, .unit, .unit, .unit⟩⟩

theorem Fields.value_inj : ∀ a b : Fields, a.value = b.value → a = b := by
  intro a b h
  cases a; cases b
  simp only [Fields.value, PureValue.record.injEq, List.cons.injEq, Prod.mk.injEq, true_and, and_true] at h
  obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22,
    h23, h24, h25⟩ := h
  subst_vars
  rfl

/-- A node whose fields are found by unification. -/
macro "nodeOf" : term => `(Fields.mk _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _)

/-- A `Node` record literal is the value of its fields. -/
theorem node_record (a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12 a13 a14 a15 a16 a17 a18 a19 a20 a21 a22 a23 a24 : PureValue) :
    PureValue.record "Node" [("config", a0), ("state", a1), ("role", a2), ("leader", a3), ("local", a4), ("membership", a5), ("bootstrap", a6), ("hooks", a7), ("peers", a8), ("votes", a9), ("next", a10), ("matched", a11), ("outbox", a12), ("dirty", a13), ("log_from", a14), ("snapshot_changed", a15), ("elapsed", a16), ("election_deadline", a17), ("random", a18), ("prevoting", a19), ("leader_age", a20), ("quorum_elapsed", a21), ("active", a22), ("extra_reply", a23), ("request_from", a24)] = (Fields.mk a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12 a13 a14 a15 a16 a17 a18 a19 a20 a21 a22 a23 a24).value := rfl

/-- A record literal as the value of a node found by unification. -/
macro "nodeEq" : term => `(node_record _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _)

/-- The peer table of a node of a stable configuration: every slot holds its member. -/
def peersv (ids : List Nat) : PureValue := .array (ids.map fun i => .present (idv i))

def boolsv (bs : List Bool) : PureValue := .array (bs.map .boolean)

/-- The number of granted votes. -/
def granted (bs : List Bool) : Nat := bs.count true

theorem granted_le (bs : List Bool) (k : Nat) : granted (bs.take k) ≤ k := by
  unfold granted
  exact Nat.le_trans List.count_le_length (List.length_take_le _ _)

theorem granted_succ (bs : List Bool) (k : Nat) (h : k < bs.length) :
    granted (bs.take (k + 1)) = granted (bs.take k) + (if bs[k] then 1 else 0) := by
  unfold granted
  rw [take_succ bs k h, List.count_append]
  cases bs[k] <;> simp

/-- `election_quorum`: a strict majority of the configuration's voters has granted. -/
theorem election_quorum_spec (target : Target) (n : Fields) (ids : List Nat) (bs : List Bool)
    (unique : ids.Nodup) (sized : bs.length = ids.length) :
    Satisfies (machine target) "node::Node::election_quorum"
      { pre := fun self values => self = n.value ∧ n.membership = membershipv ids ∧
          n.peers = peersv ids ∧ n.votes = boolsv bs ∧ ∃ a b, values = [a, b],
        post := fun _ _ v r => r = n.value ∧ v = .boolean (decide (ids.length / 2 < granted bs)) } := by
  refine ⟨_, rfl, ?_⟩
  rintro self values ⟨rfl, hm, hp, hv, a, b, rfl⟩
  apply Wp.triple
  rintro env rfl
  simp only [Jarl.function_node_Node_election_quorum, frameOf, List.zipIdx, List.foldl]
  wp_walk [Fields.value, hm, membershipv]
  -- The number of voters.
  apply wp_scan_here "usize" ids.length [9, 10, 11, 12, 13] (fun k e => e 11 = some (.number "usize" k))
    (by decide) (by simp (disch := decide) only [set_same, set_other, List.length_map]) 0
    (by simp (disch := decide) only [set_same]) (Nat.zero_le _)
    (by simp (disch := decide) only [set_same, set_other])
  · intro k e hc hlt hbound hwide hkept h11
    wp_walk [hc, hkept, hlt, h11, membershipv, memberv]
    exact ⟨k + 1, by simp (disch := decide) only [set_same, set_other], by omega, by wp_kept hkept,
      by simp (disch := decide) only [set_same, set_other]⟩
  intro e1 hc1 hkept1 h11
  simp only [ite_true]
  wp_walk [h11, hkept1, Fields.value, hm, membershipv]
  -- The number of voters that granted.
  apply wp_scan_here "usize" ids.length (List.range' 19 22)
    (fun k e => e 38 = some (.number "usize" (granted (bs.take k))))
    (by decide) (by simp (disch := decide) only [set_same, set_other, List.length_map]) 0
    (by simp (disch := decide) only [set_same]) (Nat.zero_le _)
    (by simp (disch := decide) only [set_same, set_other]; rfl)
  · intro k e hc hlt hbound hwide hkept h38
    have hg := granted_le bs k
    have hbk : k < bs.length := by omega
    wp_walk [hc, hkept, hlt, h38, hkept1, Fields.value, hm, hp, membershipv, memberv, peersv]
    -- The peer slot of this voter.
    apply wp_scan_here "usize" ids.length [28, 29, 30, 31, 32, 33]
      (fun j e => e 28 = some .absent ∧ e 31 = some (.number "usize" j) ∧ ids[k] ∉ ids.take j)
      (by decide) (by simp (disch := decide) only [set_same, set_other, List.length_map]) 0
      (by simp (disch := decide) only [set_same]) (Nat.zero_le _)
      (by simp (disch := decide) only [set_same, set_other]; simp)
    · intro j e' hc' hlt' hbound' hwide' hkept' ⟨h28, h31, hnot'⟩
      wp_walk [hc', hkept', hlt', h28, h31, hc, hkept, hlt, h38, hkept1, Fields.value, hm, hp, hv,
        membershipv, memberv, peersv, boolsv, binary_present_ids]
      · have same : j = k := (List.getElem_inj unique).mp (by simpa using ‹(ids[j] == ids[k]) = true›)
        subst same
        refine ⟨j + 1, by simp (disch := decide) only [set_same, set_other, hkept'],
          by omega, by wp_kept (kept_via hkept' (by decide) (by wp_kept hkept)), ?_⟩
        simp (disch := decide) only [set_same, set_other]
        rw [granted_succ bs j hbk]
        simp_all
      · have same : j = k := (List.getElem_inj unique).mp (by simpa using ‹(ids[j] == ids[k]) = true›)
        subst same
        refine ⟨j + 1, by simp (disch := decide) only [set_same, set_other, hkept'],
          by omega, by wp_kept (kept_via hkept' (by decide) (by wp_kept hkept)), ?_⟩
        simp (disch := decide) only [set_same, set_other, hkept']
        rw [granted_succ bs j hbk]
        simp_all
      · refine ⟨j + 1, by simp (disch := decide) only [set_same, set_other], by omega, by wp_kept hkept',
          by simp (disch := decide) only [set_other, h28], by simp (disch := decide) only [set_same], ?_⟩
        simp only [take_succ ids j hlt', List.mem_append, List.mem_singleton, not_or]
        exact ⟨hnot', fun h => ‹¬(ids[j] == ids[k]) = true› (by simp [h])⟩
    · intro e' hc' hkept' ⟨h28, h31, hnot'⟩
      exfalso
      exact hnot' (by simp [List.getElem_mem hlt])
  intro e2 hc2 hkept2 h38
  simp only [ite_true]
  wp_walk [h38, hkept2, h11, hkept1, Fields.value, hm, membershipv]
  · apply wp_invoke _ (is_joint_spec target ids)
    wp_walk [hkept2, hkept1, Fields.value, hm]
    wp_walk [hkept2, hkept1]
    refine ⟨⟨rfl, _, rfl⟩, ?_⟩
    rintro v r ⟨rfl, rfl⟩
    wp_walk [hkept2, hkept1]
    refine ⟨n.value, by simp (disch := decide) only [set_same, set_other, hkept2, hkept1], rfl, ?_⟩
    have ht : bs.take ids.length = bs := List.take_of_length_le (by omega)
    simp_all
  · refine ⟨n.value, by simp (disch := decide) only [set_same, set_other, hkept2, hkept1], rfl, ?_⟩
    have ht : bs.take ids.length = bs := List.take_of_length_le (by omega)
    simp_all

/-! ### Log storage: no `State` mutator changes the term or the vote. -/

def hardv (t : Nat) (vf c : PureValue) : PureValue :=
  .record "HardState" [("term", .number "u64" t), ("voted_for", vf), ("commit", c)]

def statev (h sn en ln : PureValue) : PureValue :=
  .record "State" [("hard", h), ("snapshot", sn), ("entries", en), ("len", ln)]

@[simp] theorem statev_hard (h sn en ln : PureValue) : pureField (statev h sn en ln) "hard" = some h := rfl
@[simp] theorem hardv_term (t : Nat) (vf c : PureValue) :
    pureField (hardv t vf c) "term" = some (.number "u64" t) := rfl
@[simp] theorem hardv_voted (t : Nat) (vf c : PureValue) : pureField (hardv t vf c) "voted_for" = some vf := rfl
@[simp] theorem statev_snapshot (h sn en ln : PureValue) : pureField (statev h sn en ln) "snapshot" = some sn := rfl
@[simp] theorem statev_entries (h sn en ln : PureValue) : pureField (statev h sn en ln) "entries" = some en := rfl
@[simp] theorem statev_len (h sn en ln : PureValue) : pureField (statev h sn en ln) "len" = some ln := rfl
@[simp] theorem hardv_commit (t : Nat) (vf c : PureValue) : pureField (hardv t vf c) "commit" = some c := rfl

/-- A `State` method's write-back keeps the term and the vote. -/
def StateKeeps (t : Nat) (vf c sn en ln : PureValue) : Spec :=
  { pre := fun self values => self = statev (hardv t vf c) sn en ln ∧ ∃ a b, values = [a, b],
    post := fun _ _ _ r => ∃ c' sn' en' ln', r = statev (hardv t vf c') sn' en' ln' }

def okv : PureValue := .variant "Result" "Ok" [("0", .unit)]
def fullv : PureValue := .variant "Result" "Err" [("0", .variant "Error" "Full" [])]

theorem push_spec (target : Target) (t : Nat) (vf c sn en ln : PureValue) :
    SatisfiesBack (machine target) "state::State::push"
      { pre := (StateKeeps t vf c sn en ln).pre,
        post := fun _ _ v r => (∃ c' sn' en' ln', r = statev (hardv t vf c') sn' en' ln') ∧
          (v = okv ∨ v = fullv) } := by
  refine ⟨_, rfl, ?_⟩
  rintro self values ⟨rfl, a, b, rfl⟩
  apply Wp.triple
  rintro env rfl
  simp only [Jarl.function_state_State_push, frameOf, List.zipIdx, List.foldl]
  wp_walk [statev]
  apply wp_invoke_any
  wp_walk [statev, hardv]
  all_goals (wp_receiver; exact ⟨⟨_, _, _, _, rfl⟩, by simp [okv, fullv]⟩)

theorem truncate_spec (target : Target) (t : Nat) (vf c sn en ln : PureValue) :
    SatisfiesBack (machine target) "state::State::truncate" (StateKeeps t vf c sn en ln) := by
  refine ⟨_, rfl, ?_⟩
  rintro self values ⟨rfl, a, b, rfl⟩
  apply Wp.triple
  rintro env rfl
  simp only [Jarl.function_state_State_truncate, frameOf, List.zipIdx, List.foldl]
  wp_walk [statev]
  apply wp_while [0, 4, 5, 6, 7] (fun e => ∃ c' sn' en' ln', e 0 = some (statev (hardv t vf c') sn' en' ln'))
    ⟨c, sn, en, ln, by simp (disch := decide) only [set_same, set_other]⟩
  rintro e hkept ⟨c', sn', en', ln', h0⟩
  wp_walk [h0, hkept]
  apply wp_invoke_any
  wp_walk [h0, hkept, statev, hardv]
  all_goals first
    | (intro r hr; rw [h0] at hr; cases hr; exact ⟨_, _, _, _, rfl⟩)
    | exact ⟨by wp_kept hkept, _, _, _, _, by simp (disch := decide) only [set_same, set_other]; rfl⟩

theorem install_spec (target : Target) (t : Nat) (vf c sn en ln : PureValue) :
    SatisfiesBack (machine target) "state::State::install" (StateKeeps t vf c sn en ln) := by
  refine ⟨_, rfl, ?_⟩
  rintro self values ⟨rfl, a, b, rfl⟩
  apply Wp.triple
  rintro env rfl
  simp only [Jarl.function_state_State_install, frameOf, List.zipIdx, List.foldl]
  wp_walk_any [statev]
  case yes.isTrue.yes.isTrue =>
    apply wp_while [0, 14, 15, 16, 17]
      (fun e => ∃ c' sn' en' ln', e 0 = some (statev (hardv t vf c') sn' en' ln'))
      ⟨_, _, _, _, by simp (disch := decide) only [set_same, set_other]; rfl⟩
    rintro e hkept ⟨c', sn', en', ln', h0⟩
    wp_walk_any [h0, hkept, statev, hardv]
    all_goals first
      | (wp_receiver; exact ⟨_, _, _, _, rfl⟩)
      | (refine ⟨by wp_kept hkept, ?_⟩
         simp (disch := decide) only [set_same, set_other]
         exact ⟨_, _, _, _, rfl⟩)
  case no.isTrue.yes =>
    apply wp_while [0, 21, 22, 23, 24]
      (fun e => ∃ c' sn' en' ln', e 0 = some (statev (hardv t vf c') sn' en' ln'))
      ⟨_, _, _, _, by simp (disch := decide) only [set_same, set_other]; rfl⟩
    rintro e hkept ⟨c', sn', en', ln', h0⟩
    wp_walk_any [h0, hkept, statev, hardv]
    all_goals first
      | (wp_receiver; exact ⟨_, _, _, _, rfl⟩)
      | (refine ⟨by wp_kept hkept, ?_⟩
         simp (disch := decide) only [set_same, set_other]
         exact ⟨_, _, _, _, rfl⟩)

/-! ### Sending -/

/-- `send` to a peer slot stores the descriptor in that slot. -/
theorem send_spec (target : Target) (n : Fields) (os : List PureValue) (p N : Nat) (ob cap : PureValue)
    (hp : p < os.length) (hN : p ≠ N) :
    SatisfiesBack (machine target) "node::Node::send"
      { pre := fun self values => self = n.value ∧ n.outbox = .array os ∧
          values = [.number "usize" p, ob, .number "usize" N, cap],
        post := fun _ _ _ r => r = { n with outbox := .array (os.set p (.present ob)) }.value } := by
  refine ⟨_, rfl, ?_⟩
  rintro self values ⟨rfl, ho, rfl⟩
  apply Wp.triple
  rintro env rfl
  simp only [Jarl.function_node_Node_send, frameOf, List.zipIdx, List.foldl]
  wp_walk [Fields.value, ho, hN, hp]
  all_goals first
    | exact absurd (by simpa using ‹(p == N) = true›) hN
    | (wp_receiver; rfl)

theorem replicate_spec (target : Target) (n : Fields) (os : List PureValue) (p N : Nat) (cap : PureValue)
    (hp : p < os.length) (hN : p ≠ N) :
    SatisfiesBack (machine target) "node::Node::replicate"
      { pre := fun self values => self = n.value ∧ n.outbox = .array os ∧
          values = [.number "usize" p, .number "usize" N, cap],
        post := fun _ _ _ r =>
          r = { n with outbox := .array (os.set p (.present (.variant "Outbound" "Replicate" []))) }.value } := by
  refine ⟨_, rfl, ?_⟩
  rintro self values ⟨rfl, ho, rfl⟩
  apply Wp.triple
  rintro env rfl
  simp only [Jarl.function_node_Node_replicate, frameOf, List.zipIdx, List.foldl]
  wp_walk
  apply wp_invoke_back _ (send_spec target n os p N (.variant "Outbound" "Replicate" []) cap hp hN)
  wp_walk
  refine ⟨by simp [ho], ?_⟩
  rintro v r rfl
  wp_walk
  wp_receiver
  rfl

theorem reply_spec (target : Target) (n : Fields) (os : List PureValue) (p N : Nat)
    (index rejection cap : PureValue) (hp : p < os.length) (hN : p ≠ N) :
    SatisfiesBack (machine target) "node::Node::reply"
      { pre := fun self values => self = n.value ∧ n.outbox = .array os ∧
          values = [.number "usize" p, index, rejection, .number "usize" N, cap],
        post := fun _ _ _ r => r = { n with outbox := .array (os.set p (.present
          (.variant "Outbound" "Replicated" [("0", index), ("1", rejection)]))) }.value } := by
  refine ⟨_, rfl, ?_⟩
  rintro self values ⟨rfl, ho, rfl⟩
  apply Wp.triple
  rintro env rfl
  simp only [Jarl.function_node_Node_reply, frameOf, List.zipIdx, List.foldl]
  wp_walk
  apply wp_invoke_back _ (send_spec target n os p N (.variant "Outbound" "Replicated" [("0", index), ("1", rejection)]) cap hp hN)
  wp_walk
  refine ⟨by simp [ho], ?_⟩
  rintro v r rfl
  wp_walk
  wp_receiver
  rfl

/-! ### Election timer and stepping down -/

theorem reset_election_spec (target : Target) (n : Fields) :
    SatisfiesBack (machine target) "node::Node::reset_election"
      { pre := fun self values => self = n.value ∧ ∃ a b, values = [a, b],
        post := fun _ _ _ r => ∃ n', r = n'.value ∧ ∃ rnd dl el,
          n' = { n with random := rnd, election_deadline := dl, elapsed := el } } := by
  refine ⟨_, rfl, ?_⟩
  rintro self values ⟨rfl, a, b, rfl⟩
  apply Wp.triple
  rintro env rfl
  simp only [Jarl.function_node_Node_reset_election, frameOf, List.zipIdx, List.foldl]
  wp_walk [Fields.value]
  all_goals (wp_receiver; rw [node_record]; exact ⟨_, rfl, _, _, _, rfl⟩)

/-- `follow`: Follower, no probe, the given leader, and a restarted timer. -/
theorem follow_spec (target : Target) (n : Fields) (leader : PureValue) :
    SatisfiesBack (machine target) "node::Node::follow"
      { pre := fun self values => self = n.value ∧ ∃ a b, values = [leader, a, b],
        post := fun _ _ _ r => ∃ age rnd dl el,
          r = { n with role := .variant "Role" "Follower" [], prevoting := .absent, leader := leader,
                       leader_age := age, random := rnd, election_deadline := dl, elapsed := el }.value } := by
  refine ⟨_, rfl, ?_⟩
  rintro self values ⟨rfl, a, b, rfl⟩
  apply Wp.triple
  rintro env rfl
  simp only [Jarl.function_node_Node_follow, frameOf, List.zipIdx, List.foldl]
  cases leader <;> wp_walk [Fields.value]
  all_goals
    simp only [node_record]
    apply wp_invoke_back _ (reset_election_spec target _)
    wp_walk
    refine ⟨⟨rfl, _, _, rfl⟩, ?_⟩
    rintro v r ⟨n', rfl, rnd, dl, el, rfl⟩
    wp_walk [Fields.value]
    wp_receiver
    rw [node_record]
    exact ⟨_, _, _, _, rfl⟩

def replicatev : PureValue := .present (.variant "Outbound" "Replicate" [])

/-- Each slot either keeps its descriptor or holds a replication request. -/
def Replicated (os os' : List PureValue) : Prop :=
  os'.length = os.length ∧ ∀ i, i < os.length → os'[i]? = os[i]? ∨ os'[i]? = some replicatev

theorem Replicated.refl (os : List PureValue) : Replicated os os := ⟨rfl, fun _ _ => Or.inl rfl⟩

/-- `broadcast` only queues replication requests. -/
theorem broadcast_spec (target : Target) (n : Fields) (ids : List Nat) (os : List PureValue) (lo : Nat)
    (cap : PureValue) (sized : os.length = ids.length) (hp : n.peers = peersv ids)
    (hm : n.membership = membershipv ids) (hl : n.local = .number "usize" lo) (ho : n.outbox = .array os) :
    SatisfiesBack (machine target) "node::Node::broadcast"
      { pre := fun self values => self = n.value ∧ values = [.number "usize" ids.length, cap],
        post := fun _ _ _ r => ∃ os', r = { n with outbox := .array os' }.value ∧ Replicated os os' } := by
  refine ⟨_, rfl, ?_⟩
  rintro self values ⟨rfl, rfl⟩
  apply Wp.triple
  rintro env rfl
  simp only [Jarl.function_node_Node_broadcast, frameOf, List.zipIdx, List.foldl]
  wp_walk [Fields.value]
  apply wp_scan_here "usize" ids.length [0, 5, 6, 7, 8, 10, 11, 12]
    (fun _ e => ∃ os', e 0 = some { n with outbox := .array os' }.value ∧ Replicated os os')
    (by decide) (by simp (disch := decide) only [set_same, set_other]) 0
    (by simp (disch := decide) only [set_same]) (Nat.zero_le _)
    ⟨os, by simp (disch := decide) only [set_same, set_other]; rw [← ho], Replicated.refl os⟩
  · intro k e hc hlt hbound hwide hkept ⟨os', h0, hrep⟩
    wp_walk [h0, hkept, hc, Fields.value, hp, hm, hl, peersv]
    case isTrue =>
      apply wp_invoke _ (contains_spec target ids ids[k])
      wp_walk [h0, hkept, hc, Fields.value, hm]
      refine ⟨by simp, ?_⟩
      rintro v r ⟨-, rfl⟩
      wp_walk [List.getElem_mem hlt, decide_true]
      have hk' : k < os'.length := by rw [hrep.1]; omega
      apply wp_invoke_back _ (replicate_spec target { n with outbox := .array os' } os' k ids.length cap hk'
        (by omega))
      wp_walk [h0, hkept]
      refine ⟨by simp, ?_⟩
      rintro v r rfl
      wp_walk [h0, hkept]
      refine ⟨k + 1, by simp (disch := decide) only [set_same, set_other], by omega,
        by wp_kept hkept, os'.set k replicatev, by simp (disch := decide) only [set_same, set_other]; rfl, ?_⟩
      refine ⟨by simp [hrep.1], fun i hi => ?_⟩
      by_cases same : i = k
      · subst same; exact Or.inr (by simp [hk', replicatev])
      · rw [List.getElem?_set_ne (Ne.symm same)]; exact hrep.2 i hi
    case isFalse =>
      exact ⟨k + 1, by simp (disch := decide) only [set_same, set_other], by omega, by wp_kept hkept, os',
        by simp (disch := decide) only [set_other, h0], hrep⟩
  · intro e hc hkept ⟨os', h0, hrep⟩
    wp_walk [h0]
    rw [h0]
    rintro r ⟨⟩
    exact ⟨os', rfl, hrep⟩

theorem set_split {α β : Type} (f g : α → β) : ∀ (xs : List α) (i : Nat) (h : i < xs.length),
    ((xs.take i).map f ++ (xs.drop i).map g).set i (f xs[i]) =
      (xs.take (i + 1)).map f ++ (xs.drop (i + 1)).map g
  | [], _, h => by simp at h
  | x :: xs, 0, _ => by simp
  | x :: xs, i + 1, h => by
    have := set_split f g xs i (by simpa using h)
    simp only [List.take_succ_cons, List.drop_succ_cons, List.map_cons, List.cons_append,
      List.set_cons_succ, List.getElem_cons_succ]
    rw [this]

/-- `Membership::peers` of a stable configuration is its peer table. -/
theorem peers_spec (target : Target) (ids : List Nat) :
    Satisfies (machine target) "membership::Membership::peers"
      { pre := fun self values => self = membershipv ids ∧ ∃ a, values = [a],
        post := fun _ _ v r => r = membershipv ids ∧ v = peersv ids } := by
  refine ⟨_, rfl, ?_⟩
  rintro self values ⟨rfl, a, rfl⟩
  apply Wp.triple
  rintro env rfl
  simp only [Jarl.function_membership_Membership_peers, frameOf, List.zipIdx, List.foldl]
  wp_walk [membershipv]
  apply wp_range "usize" 0 ids.length (fun i e =>
    e 10 = some (.array ((ids.take i).map (fun x => .present (idv x)) ++
      (ids.drop i).map (fun x => .present (memberv x)))) ∧
    e 2 = some (.array (ids.map fun x => .present (memberv x))) ∧ e 0 = some (membershipv ids))
    (Nat.zero_le _)
  · wp_walk
    simp (disch := decide) only [set_same, set_other, List.length_map, List.take_zero, List.drop_zero,
      List.map_nil, List.nil_append]
    simp
  · rintro i e - hi ⟨h10, h2, h0⟩
    wp_walk [h10, h2, h0, hi, memberv]
    rename_i upd hu
    obtain ⟨-, rfl⟩ := hu
    simp (disch := decide) only [set_same, set_other, h2, h0, and_true]
    rw [set_split _ _ ids i hi]
    rfl
  · rintro e v ⟨h10, h2, h0⟩
    wp_walk [h10]
    refine ⟨membershipv ids, h0, rfl, ?_⟩
    simp [peersv]

/-- Without membership hooks the configuration at every index is the bootstrap one. -/
theorem membership_at_spec (target : Target) (n : Fields) (hh : n.hooks = .absent) :
    Satisfies (machine target) "node::Node::membership_at"
      { pre := fun self values => self = n.value ∧ ∃ i a b, values = [i, a, b],
        post := fun _ _ v r => r = n.value ∧
          v = .record "()" [("0", .number "u64" 0), ("1", n.bootstrap)] } := by
  refine ⟨_, rfl, ?_⟩
  rintro self values ⟨rfl, i, a, b, rfl⟩
  apply Wp.triple
  rintro env rfl
  simp only [Jarl.function_node_Node_membership_at, frameOf, List.zipIdx, List.foldl]
  wp_walk [Fields.value, hh]
  refine ⟨n.value, ?_, rfl, ?_⟩ <;> simp (disch := decide) [set_same, set_other, Fields.value, hh]

/-- What a node of a stable configuration keeps about its configuration: the
    membership, peer table and its own slot. -/
structure Fixed (ids : List Nat) (me : Nat) (n : Fields) : Prop where
  unique : ids.Nodup
  member : me ∈ ids
  membership : n.membership = membershipv ids
  bootstrap : n.bootstrap = membershipv ids
  hooks : n.hooks = .absent
  peers : n.peers = peersv ids
  self : pureField n.config "id" = some (idv me)
  slot : n.local = .number "usize" (ids.idxOf me)

/-- `refresh_membership` changes nothing in a stable configuration. -/
theorem refresh_membership_spec (target : Target) (n : Fields) (ids : List Nat) (me : Nat)
    (fixed : Fixed ids me n) (cap : PureValue) :
    SatisfiesBack (machine target) "node::Node::refresh_membership"
      { pre := fun self values => self = n.value ∧ values = [.number "usize" ids.length, cap],
        post := fun _ _ _ r => r = n.value } := by
  refine ⟨_, rfl, ?_⟩
  rintro self values ⟨rfl, rfl⟩
  apply Wp.triple
  rintro env rfl
  simp only [Jarl.function_node_Node_refresh_membership, frameOf, List.zipIdx, List.foldl]
  wp_walk [Fields.value]
  apply wp_invoke _ (membership_at_spec target n fixed.hooks)
  wp_walk_any [Fields.value]
  refine ⟨by simp [Fields.value], ?_⟩
  rintro v r ⟨-, rfl⟩
  wp_walk [Fields.value, fixed.bootstrap]
  apply wp_invoke _ (peers_spec target ids)
  wp_walk [Fields.value, fixed.membership]
  refine ⟨by simp, ?_⟩
  rintro v r ⟨-, rfl⟩
  wp_walk [peersv]
  -- Every configured peer is already in the peer table.
  apply wp_scan_here "usize" ids.length (List.range' 7 39) (fun _ _ => True) (by decide)
    (by simp (disch := decide) only [set_same, set_other, List.length_map]) 0
    (by simp (disch := decide) only [set_same]) (Nat.zero_le _) trivial
  · intro k e hc hlt hbound hwide hkept _
    wp_walk [hc, hkept, hlt, Fields.value, fixed.peers, peersv]
    apply wp_scan_here "usize" ids.length [14, 15, 16]
      (fun j e => e 14 = some (.boolean false) ∧ ids[k] ∉ ids.take j) (by decide)
      (by simp (disch := decide) only [set_same, set_other, List.length_map]) 0
      (by simp (disch := decide) only [set_same]) (Nat.zero_le _)
      (by simp (disch := decide) only [set_same, set_other]; simp)
    · intro j e' hc' hlt' hbound' hwide' hkept' ⟨h14, hnot'⟩
      wp_walk [hc', hkept', hlt', h14, hc, hkept, hlt, binary_present_ids]
      case yes =>
        exact ⟨k + 1, by simp (disch := decide) only [set_same, set_other, hkept'], by omega,
          by wp_kept (kept_via hkept' (by decide) (by wp_kept hkept)), trivial⟩
      case no =>
        refine ⟨j + 1, by simp (disch := decide) only [set_same, set_other], by omega, by wp_kept hkept',
          by simp (disch := decide) only [set_other, h14], ?_⟩
        simp only [take_succ ids j hlt', List.mem_append, List.mem_singleton, not_or]
        exact ⟨hnot', fun h => ‹¬(ids[j] == ids[k]) = true› (by simp [h])⟩
    · intro e' hc' hkept' ⟨h14, hnot'⟩
      exfalso
      exact hnot' (by simp [List.getElem_mem hlt])
  · intro e hc hkept _
    simp only [ite_true]
    have hme : ids.idxOf me < ids.length := List.idxOf_lt_length_of_mem fixed.member
    wp_walk [hkept, Fields.value, fixed.peers, peersv]
    -- The node's own slot.
    apply wp_scan_here "usize" ids.length [49, 50, 51, 52, 53, 54]
      (fun j e => e 49 = some .absent ∧ e 52 = some (.number "usize" j) ∧ me ∉ ids.take j) (by decide)
      (by simp (disch := decide) only [set_same, set_other, List.length_map]) 0
      (by simp (disch := decide) only [set_same]) (Nat.zero_le _)
      (by simp (disch := decide) only [set_same, set_other]; simp)
    · intro j e' hc' hlt' hbound' hwide' hkept' ⟨h49, h52, hnot'⟩
      wp_walk [hc', hkept', hlt', h49, h52, hkept, Fields.value, fixed.self, binary_present_ids]
      case no =>
        refine ⟨j + 1, by simp (disch := decide) only [set_same, set_other], by omega, by wp_kept hkept',
          by simp (disch := decide) only [set_other, h49], by simp (disch := decide) only [set_same], ?_⟩
        simp only [take_succ ids j hlt', List.mem_append, List.mem_singleton, not_or]
        exact ⟨hnot', fun h => ‹¬(ids[j] == me) = true› (by simp [h])⟩
      all_goals
        have hj : j = ids.idxOf me := (List.getElem_inj fixed.unique).mp
          (by rw [List.getElem_idxOf hme]; simpa using ‹(ids[j] == me) = true›)
        subst hj
      case yes.isTrue =>
        apply wp_invoke _ (is_voter_spec target ids me)
        wp_walk [hkept', hkept, Fields.value, fixed.membership, fixed.self]
        refine ⟨by simp, ?_⟩
        rintro v r ⟨-, rfl⟩
        wp_walk [fixed.member]
        wp_receiver
        simp [Fields.value, fixed.membership, fixed.slot, fixed.bootstrap]
      case yes.isFalse =>
        wp_receiver
        simp [Fields.value, fixed.membership, fixed.slot, fixed.bootstrap]
    · intro e' hc' hkept' ⟨h49, h52, hnot'⟩
      exfalso
      exact hnot' (by simp [fixed.member])

/-! ### Calm steps: no change to the election state -/

/-- A replication descriptor: never an election message. -/
def Quiet (v : PureValue) : Prop :=
  v = .present (.variant "Outbound" "Replicate" []) ∨
    ∃ i r, v = .present (.variant "Outbound" "Replicated" [("0", i), ("1", r)])

/-- Each outbox slot keeps its descriptor or now holds a replication descriptor. -/
def Settled (os os' : List PureValue) : Prop :=
  os'.length = os.length ∧ ∀ i, i < os.length → os'[i]? = os[i]? ∨ ∃ v, os'[i]? = some v ∧ Quiet v

theorem Settled.refl (os : List PureValue) : Settled os os := ⟨rfl, fun _ _ => Or.inl rfl⟩

theorem Settled.trans {a b c : List PureValue} (h1 : Settled a b) (h2 : Settled b c) : Settled a c := by
  refine ⟨h2.1.trans h1.1, fun i hi => ?_⟩
  rcases h2.2 i (by rw [h1.1]; exact hi) with e | q
  · rw [e]; exact h1.2 i hi
  · exact Or.inr q

theorem Settled.set {os os' : List PureValue} (h : Settled os os') (i : Nat) (v : PureValue) (q : Quiet v) :
    Settled os (os'.set i v) := by
  refine ⟨by simp [h.1], fun k hk => ?_⟩
  by_cases same : k = i
  · subst same
    exact Or.inr ⟨v, by simp [h.1, hk], q⟩
  · rw [List.getElem?_set_ne (Ne.symm same)]; exact h.2 k hk

theorem Settled.of_replicated {os os' : List PureValue} (h : Replicated os os') : Settled os os' :=
  ⟨h.1, fun i hi => (h.2 i hi).imp id (fun e => ⟨_, e, Or.inl rfl⟩)⟩

/-- The term and vote of a `State` value. -/
def TermVote (s : PureValue) (t : Nat) (vf : PureValue) : Prop :=
  ∃ c sn en ln, s = statev (hardv t vf c) sn en ln

/-- A step that leaves the election state alone: role, votes, probe, peer
    tables and configuration unchanged, the term and vote kept, the dirty flag
    only ever set, and outbox slots kept or given replication descriptors. -/
structure Calm (n n' : Fields) : Prop where
  config : n'.config = n.config
  role : n'.role = n.role
  slot : n'.local = n.local
  membership : n'.membership = n.membership
  bootstrap : n'.bootstrap = n.bootstrap
  hooks : n'.hooks = n.hooks
  peers : n'.peers = n.peers
  votes : n'.votes = n.votes
  prevoting : n'.prevoting = n.prevoting
  extra_reply : n'.extra_reply = n.extra_reply
  hard : ∀ t vf, TermVote n.state t vf → TermVote n'.state t vf
  dirty : n'.dirty = n.dirty ∨ n'.dirty = .boolean true
  outbox : ∀ os, n.outbox = .array os → ∃ os', n'.outbox = .array os' ∧ Settled os os'

theorem Calm.refl (n : Fields) : Calm n n :=
  ⟨rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, fun _ _ h => h, Or.inl rfl,
    fun os h => ⟨os, h, Settled.refl os⟩⟩

theorem Calm.trans {a b c : Fields} (h1 : Calm a b) (h2 : Calm b c) : Calm a c where
  config := h2.config.trans h1.config
  role := h2.role.trans h1.role
  slot := h2.slot.trans h1.slot
  membership := h2.membership.trans h1.membership
  bootstrap := h2.bootstrap.trans h1.bootstrap
  hooks := h2.hooks.trans h1.hooks
  peers := h2.peers.trans h1.peers
  votes := h2.votes.trans h1.votes
  prevoting := h2.prevoting.trans h1.prevoting
  extra_reply := h2.extra_reply.trans h1.extra_reply
  hard := fun t vf h => h2.hard t vf (h1.hard t vf h)
  dirty := by
    rcases h2.dirty with e | e
    · rw [e]; exact h1.dirty
    · exact Or.inr e
  outbox := fun os h => by
    obtain ⟨os1, h1o, s1⟩ := h1.outbox os h
    obtain ⟨os2, h2o, s2⟩ := h2.outbox os1 h1o
    exact ⟨os2, h2o, s1.trans s2⟩

theorem Fixed.calm {ids : List Nat} {me : Nat} {n n' : Fields} (f : Fixed ids me n) (c : Calm n n') :
    Fixed ids me n' where
  unique := f.unique
  member := f.member
  membership := c.membership.trans f.membership
  bootstrap := c.bootstrap.trans f.bootstrap
  hooks := c.hooks.trans f.hooks
  peers := c.peers.trans f.peers
  self := by rw [c.config]; exact f.self
  slot := c.slot.trans f.slot

/-- A change of fields outside the election state is calm. -/
macro "calm_rfl" : term =>
  `({ config := rfl, role := rfl, slot := rfl, membership := rfl, bootstrap := rfl, hooks := rfl,
      peers := rfl, votes := rfl, prevoting := rfl, extra_reply := rfl, hard := fun _ _ h => h,
      dirty := Or.inl rfl, outbox := fun os h => ⟨os, h, Settled.refl os⟩ })

theorem Calm.withRole {n n' : Fields} (c : Calm n n') (r : PureValue) :
    Calm { n with role := r } { n' with role := r } where
  config := c.config
  role := rfl
  slot := c.slot
  membership := c.membership
  bootstrap := c.bootstrap
  hooks := c.hooks
  peers := c.peers
  votes := c.votes
  prevoting := c.prevoting
  extra_reply := c.extra_reply
  hard := c.hard
  dirty := c.dirty
  outbox := c.outbox

/-- `commit_to` may raise the commit index and set the dirty flag. -/
theorem commit_to_spec (target : Target) (n : Fields) (ids : List Nat) (me : Nat) (fixed : Fixed ids me n)
    (t : Nat) (vf c sn en ln : PureValue) (hs : n.state = statev (hardv t vf c) sn en ln) (index cap : PureValue) :
    SatisfiesBack (machine target) "node::Node::commit_to"
      { pre := fun self values => self = n.value ∧ values = [index, .number "usize" ids.length, cap],
        post := fun _ _ _ r => ∃ n', r = n'.value ∧ Calm n n' } := by
  refine ⟨_, rfl, ?_⟩
  rintro self values ⟨rfl, rfl⟩
  apply Wp.triple
  rintro env rfl
  simp only [Jarl.function_node_Node_commit_to, frameOf, List.zipIdx, List.foldl]
  wp_walk [Fields.value, hs, statev, hardv]
  case no =>
    wp_receiver
    exact ⟨n, by simp [Fields.value, hs, statev, hardv], Calm.refl n⟩
  case yes =>
    simp only [node_record]
    apply wp_invoke_back _ (refresh_membership_spec target _ ids me ?fx cap)
    wp_walk
    refine ⟨⟨rfl, by simp⟩, ?_⟩
    rintro v r rfl
    wp_walk
    wp_receiver
    refine ⟨_, rfl, ?_⟩
    exact { config := rfl, role := rfl, slot := rfl, membership := rfl, bootstrap := rfl, hooks := rfl,
            peers := rfl, votes := rfl, prevoting := rfl, extra_reply := rfl,
            hard := fun t' vf' ⟨c', sn', en', ln', h'⟩ => by
              rw [hs] at h'
              simp only [statev, hardv, PureValue.record.injEq, List.cons.injEq, Prod.mk.injEq,
                PureValue.number.injEq, true_and, and_true] at h'
              obtain ⟨⟨rfl, rfl, -⟩, -⟩ := h'
              exact ⟨_, _, _, _, rfl⟩,
            dirty := Or.inr rfl, outbox := fun os h => ⟨os, h, Settled.refl os⟩ }
    case fx => exact ⟨fixed.unique, fixed.member, fixed.membership, fixed.bootstrap, fixed.hooks, fixed.peers,
      fixed.self, fixed.slot⟩

set_option maxHeartbeats 2000000 in
/-- `advance_commit` is calm. -/
theorem advance_commit_spec (target : Target) (n : Fields) (ids : List Nat) (me : Nat) (fixed : Fixed ids me n)
    (t : Nat) (vf c sn en ln : PureValue) (hs : n.state = statev (hardv t vf c) sn en ln) (cap : PureValue) :
    SatisfiesBack (machine target) "node::Node::advance_commit"
      { pre := fun self values => self = n.value ∧ values = [.number "usize" ids.length, cap],
        post := fun _ _ _ r => ∃ n', r = n'.value ∧ Calm n n' } := by
  refine ⟨_, rfl, ?_⟩
  rintro self values ⟨rfl, rfl⟩
  apply Wp.triple
  rintro env rfl
  simp only [Jarl.function_node_Node_advance_commit, frameOf, List.zipIdx, List.foldl]
  wp_walk [Fields.value, fixed.membership, membershipv]
  apply wp_while ([5, 7] ++ List.range' 12 13) (fun _ => True) trivial
  rintro e hkept -
  wp_walk_any [hkept, membershipv]
  all_goals first
    | exact ⟨by wp_kept hkept, trivial⟩
    | (wp_receiver [hkept]
       exact ⟨n, by simp [Fields.value], Calm.refl n⟩)
    | (apply wp_invoke_back _ (commit_to_spec target n ids me fixed t vf c sn en ln hs _ cap)
       wp_walk [hkept]
       refine ⟨⟨by simp [Fields.value], rfl⟩, ?_⟩
       rintro v r ⟨n', rfl, calm⟩
       wp_walk [hkept]
       wp_receiver [hkept]
       exact ⟨n', rfl, calm⟩)
    | (apply wp_while ([5, 7] ++ List.range' 35 13) (fun _ => True) trivial
       rintro e2 hkept2 -
       wp_walk_any [hkept2, hkept, membershipv]
       all_goals first
         | exact ⟨by wp_kept hkept2, trivial⟩
         | (wp_receiver [hkept2, hkept]
            exact ⟨n, by simp [Fields.value], Calm.refl n⟩)
         | (apply wp_invoke_back _ (commit_to_spec target n ids me fixed t vf c sn en ln hs _ cap)
            wp_walk [hkept2, hkept]
            refine ⟨⟨by simp [Fields.value], rfl⟩, ?_⟩
            rintro v r ⟨n', rfl, calm⟩
            wp_walk [hkept2, hkept]
            wp_receiver [hkept2, hkept]
            exact ⟨n', rfl, calm⟩))

theorem termVote_keep {s : PureValue} {t : Nat} {vf c : PureValue} {sn en ln : PureValue}
    (hs : s = statev (hardv t vf c) sn en ln) (c' sn' en' ln' : PureValue) :
    ∀ t' vf', TermVote s t' vf' → TermVote (statev (hardv t vf c') sn' en' ln') t' vf' := by
  rintro t' vf' ⟨c'', sn'', en'', ln'', h'⟩
  rw [hs] at h'
  simp only [statev, hardv, PureValue.record.injEq, List.cons.injEq, Prod.mk.injEq,
    PureValue.number.injEq, true_and, and_true] at h'
  obtain ⟨⟨rfl, rfl, -⟩, -⟩ := h'
  exact ⟨_, _, _, _, rfl⟩

/-- A uniform specification for a calm helper over every node of the configuration. -/
def CalmCall (target : Target) (name : String) (ids : List Nat) (me : Nat) (V : List PureValue → Prop) : Prop :=
  SatisfiesBack (machine target) name
    { pre := fun self values => ∃ n, self = n.value ∧
        (Fixed ids me n ∧ (∃ t vf, TermVote n.state t vf) ∧ V values),
      post := fun self _ _ r => ∀ n, self = n.value → ∃ n', r = n'.value ∧ Calm n n' }

theorem calmCall_of {target : Target} {name : String} {body : Expr}
    (hbody : (machine target).functions name = some body) {ids : List Nat} {me : Nat} {V : List PureValue → Prop}
    (h : ∀ n, Fixed ids me n → ∀ t vf c sn en ln, n.state = statev (hardv t vf c) sn en ln → ∀ vs, V vs →
      SatisfiesBack (machine target) name
        { pre := fun self values => self = n.value ∧ values = vs,
          post := fun _ _ _ r => ∃ n', r = n'.value ∧ Calm n n' }) :
    CalmCall target name ids me V := by
  apply back_uniform Fields.value Fields.value_inj
    (fun n values => Fixed ids me n ∧ (∃ t vf, TermVote n.state t vf) ∧ V values)
    (fun n _ _ r => ∃ n', r = n'.value ∧ Calm n n')
  intro n
  apply back_pointwise hbody
  rintro self values ⟨rfl, fixed, ⟨t, vf, c, sn, en, ln, hs⟩, hv⟩
  exact back_weaken (h n fixed t vf c sn en ln hs values hv) (fun _ _ h => h) (fun _ _ _ _ _ h => h)

theorem commit_to_u (target : Target) (ids : List Nat) (me : Nat) (cap : PureValue) :
    CalmCall target "node::Node::commit_to" ids me (fun vs => ∃ index, vs = [index, .number "usize" ids.length, cap]) :=
  calmCall_of rfl fun n fixed t vf c sn en ln hs _ ⟨index, h⟩ => h ▸ commit_to_spec target n ids me fixed t vf c sn en ln hs index cap

theorem advance_commit_u (target : Target) (ids : List Nat) (me : Nat) (cap : PureValue) :
    CalmCall target "node::Node::advance_commit" ids me (· = [.number "usize" ids.length, cap]) :=
  calmCall_of rfl fun n fixed t vf c sn en ln hs _ h => h ▸ advance_commit_spec target n ids me fixed t vf c sn en ln hs cap

/-- `barrier` is calm. -/
theorem barrier_spec (target : Target) (n : Fields) (ids : List Nat) (me : Nat) (fixed : Fixed ids me n)
    (t : Nat) (vf c sn en ln : PureValue) (hs : n.state = statev (hardv t vf c) sn en ln) (cap : PureValue) :
    SatisfiesBack (machine target) "node::Node::barrier"
      { pre := fun self values => self = n.value ∧ values = [.number "usize" ids.length, cap],
        post := fun _ _ _ r => ∃ n', r = n'.value ∧ Calm n n' } := by
  refine ⟨_, rfl, ?_⟩
  rintro self values ⟨rfl, rfl⟩
  apply Wp.triple
  rintro env rfl
  simp only [Jarl.function_node_Node_barrier, frameOf, List.zipIdx, List.foldl]
  wp_walk_any [Fields.value, hs, statev, hardv]
  all_goals first
    | (wp_receiver; exact ⟨n, rfl, Calm.refl n⟩)
    | (apply wp_invoke_back _ (push_spec target t vf c sn en ln)
       wp_walk [Fields.value, hs]
       refine ⟨by simp [StateKeeps, statev, hardv], ?_⟩
       rintro v r ⟨⟨c', sn', en', ln', rfl⟩, hv | hv⟩ <;> subst hv <;>
         wp_walk [Fields.value, okv, fullv, fixed.slot, List.idxOf_lt_length_of_mem fixed.member]
       all_goals first
         | (wp_receiver
            rw [node_record]
            exact ⟨_, rfl,
              { config := rfl, role := rfl, slot := by first | rfl | exact fixed.slot.symm, membership := rfl, bootstrap := rfl, hooks := rfl,
                peers := rfl, votes := rfl, prevoting := rfl, extra_reply := rfl,
                hard := termVote_keep hs c' sn' en' ln', dirty := Or.inl rfl,
                outbox := fun os h => ⟨os, h, Settled.refl os⟩ }⟩)
         | (simp only [node_record]
            apply wp_invoke_back _ (advance_commit_spec target _ ids me ?fx t vf c' sn' en' ln' ?hs cap)
            wp_walk
            refine ⟨⟨rfl, by simp⟩, ?_⟩
            rintro v r ⟨n2, rfl, calm⟩
            wp_walk
            wp_receiver
            refine ⟨n2, rfl, Calm.trans ?_ calm⟩
            exact { config := rfl, role := rfl, slot := by first | rfl | exact fixed.slot.symm, membership := rfl, bootstrap := rfl, hooks := rfl,
                    peers := rfl, votes := rfl, prevoting := rfl, extra_reply := rfl,
                    hard := termVote_keep hs c' sn' en' ln', dirty := Or.inr rfl,
                    outbox := fun os h => ⟨os, h, Settled.refl os⟩ }
            case fx => exact ⟨fixed.unique, fixed.member, fixed.membership, fixed.bootstrap, fixed.hooks,
              fixed.peers, fixed.self, by first | exact fixed.slot | rfl⟩
            all_goals rfl))

def leaderv : PureValue := .variant "Role" "Leader" []

theorem barrier_u (target : Target) (ids : List Nat) (me : Nat) (cap : PureValue) :
    CalmCall target "node::Node::barrier" ids me (· = [.number "usize" ids.length, cap]) :=
  calmCall_of rfl fun n fixed t vf c sn en ln hs _ h => h ▸ barrier_spec target n ids me fixed t vf c sn en ln hs cap

/-- `become_leader`: Leader role, and otherwise calm. -/
theorem become_leader_spec (target : Target) (n : Fields) (ids : List Nat) (me : Nat) (fixed : Fixed ids me n)
    (t : Nat) (vf c sn en ln : PureValue) (hs : n.state = statev (hardv t vf c) sn en ln)
    (os : List PureValue) (ho : n.outbox = .array os) (sized : os.length = ids.length) (cap : PureValue) :
    SatisfiesBack (machine target) "node::Node::become_leader"
      { pre := fun self values => self = n.value ∧ values = [.number "usize" ids.length, cap],
        post := fun _ _ _ r => ∃ n', r = n'.value ∧ Calm { n with role := leaderv } n' } := by
  have fixedL : Fixed ids me { n with role := leaderv } :=
    ⟨fixed.unique, fixed.member, fixed.membership, fixed.bootstrap, fixed.hooks, fixed.peers, fixed.self, fixed.slot⟩
  refine ⟨_, rfl, ?_⟩
  rintro self values ⟨rfl, rfl⟩
  apply Wp.triple
  rintro env rfl
  simp only [Jarl.function_node_Node_become_leader, frameOf, List.zipIdx, List.foldl]
  wp_walk [Fields.value]
  apply wp_range_here "usize" 0 [0, 6] (fun _ _ e => ∃ n', e 0 = some n'.value ∧ Calm n n')
  · wp_walk [Fields.value]
    refine ⟨by simp, fun hi _ => ⟨Nat.zero_le _, by simp, ?_⟩⟩
    simp (disch := decide) only [set_same, set_other]
    rw [node_record]
    exact ⟨_, rfl, calm_rfl⟩
  · rintro hi i e - - hkept ⟨n', h0, calm⟩
    wp_walk [h0, Fields.value]
    refine ⟨by wp_kept hkept, ?_⟩
    simp (disch := decide) only [set_same, set_other]
    rw [node_record]
    exact ⟨_, rfl, calm.trans calm_rfl⟩
  rintro hi e v hk1 ⟨n', h0, calm⟩
  wp_walk_any [h0, hk1, Fields.value]
  apply wp_range_here "usize" 0 [0, 13] (fun _ _ e => ∃ n', e 0 = some n'.value ∧ Calm { n with role := leaderv } n')
  · wp_walk [h0, hk1, Fields.value]
    refine ⟨by simp, fun hi _ => ⟨Nat.zero_le _, by simp, ?_⟩⟩
    simp (disch := decide) only [set_same, set_other, h0, hk1, leaderv]
    rw [node_record]
    exact ⟨_, rfl, (calm.withRole leaderv).trans calm_rfl⟩
  · rintro hi i e - - hkept ⟨n', h0, calm⟩
    wp_walk [h0, Fields.value]
    refine ⟨by wp_kept hkept, ?_⟩
    simp (disch := decide) only [set_same, set_other]
    rw [node_record]
    exact ⟨_, rfl, calm.trans calm_rfl⟩
  rintro hi e v hk2 ⟨n', h0, calm⟩
  wp_walk_any [h0, hk2, hk1, Fields.value]
  apply wp_range_here "usize" 0 [0, 16] (fun _ _ e => ∃ n', e 0 = some n'.value ∧ Calm { n with role := leaderv } n')
  · wp_walk [h0, hk2, hk1, Fields.value]
    refine ⟨by simp, fun hi _ => ⟨Nat.zero_le _, by simp, ?_⟩⟩
    simp (disch := decide) only [set_same, set_other, h0, hk2, hk1]
    first
      | (rw [node_record]; exact ⟨_, rfl, calm.trans calm_rfl⟩)
      | exact ⟨_, rfl, calm⟩
  · rintro hi i e - - hkept ⟨n', h0, calm⟩
    wp_walk [h0, Fields.value]
    refine ⟨by wp_kept hkept, ?_⟩
    simp (disch := decide) only [set_same, set_other]
    rw [node_record]
    exact ⟨_, rfl, calm.trans calm_rfl⟩
  rintro hi e v hk3 ⟨n', h0, calm⟩
  wp_walk_any [h0, hk3, hk2, hk1, Fields.value]
  all_goals
    apply wp_invoke_back _ (barrier_u target ids me cap)
    wp_walk [h0, hk3, hk2, hk1]
    refine ⟨⟨nodeOf, nodeEq, fixedL.calm (calm.trans calm_rfl),
      ⟨t, vf, (calm.trans calm_rfl).hard t vf ⟨c, sn, en, ln, hs⟩⟩, by first | rfl | trivial⟩, ?_⟩
    rintro v r hpost
    obtain ⟨n2, rfl, calm2⟩ := hpost nodeOf nodeEq
    wp_walk [h0, hk3, hk2, hk1]
    have calm2' : Calm { n with role := leaderv } n2 := by
      refine Calm.trans (Calm.trans calm ?_) calm2
      exact calm_rfl
    obtain ⟨os2, ho2, set2⟩ := calm2'.outbox os ho
    apply wp_invoke_back _ (broadcast_spec target n2 ids os2 (ids.idxOf me) cap
      (by rw [set2.1, sized]) ((fixedL.calm calm2').peers) ((fixedL.calm calm2').membership)
      ((fixedL.calm calm2').slot) ho2)
    wp_walk [h0, hk3, hk2, hk1]
    refine ⟨by first | exact ⟨rfl, rfl⟩ | simp | trivial, ?_⟩
    rintro v r ⟨os3, rfl, rep⟩
    wp_walk [h0, hk3, hk2, hk1]
    wp_receiver
    refine ⟨_, rfl, calm2'.trans ?_⟩
    exact { config := rfl, role := rfl, slot := rfl, membership := rfl, bootstrap := rfl, hooks := rfl,
            peers := rfl, votes := rfl, prevoting := rfl, extra_reply := rfl, hard := fun _ _ h => h,
            dirty := Or.inl rfl,
            outbox := fun os' h => by rw [ho2] at h; cases h; exact ⟨os3, rfl, Settled.of_replicated rep⟩ }

/-! ### Campaigning -/

def candidatev : PureValue := .variant "Role" "Candidate" []
def votev : PureValue := .present (.variant "Outbound" "Vote" [])

/-- Votes after a campaign starts: only the node's own slot. -/
def selfVotes (N lo : Nat) : List Bool := (List.range N).map (· == lo)

/-- The outbox after vote requests to every other slot. -/
def voteBox (os : List PureValue) (lo : Nat) : List PureValue :=
  os.mapIdx (fun i o => if i = lo then o else votev)

theorem replicate_set_self (L lo : Nat) :
    (List.replicate L (PureValue.boolean false)).set lo (.boolean true) = (selfVotes L lo).map PureValue.boolean := by
  apply List.ext_getElem
  · simp [selfVotes]
  · intro i h1 h2
    simp only [List.getElem_set, List.getElem_replicate, List.getElem_map, selfVotes, List.getElem_range]
    by_cases h : lo = i
    · subst h; simp
    · simp [h, Ne.symm h]

theorem granted_self_ite (lo : Nat) : ∀ L, granted (selfVotes L lo) = if lo < L then 1 else 0
  | 0 => by simp [granted, selfVotes]
  | L + 1 => by
    have ih := granted_self_ite lo L
    unfold granted selfVotes at *
    rw [List.range_succ, List.map_append, List.count_append, ih]
    by_cases h1 : lo < L
    · have : (L == lo) = false := by simp; omega
      simp [h1, this, show lo < L + 1 by omega]
    · by_cases h2 : lo = L
      · subst h2; simp
      · have : (L == lo) = false := by simp; omega
        simp [h1, this, show ¬ lo < L + 1 by omega]

theorem granted_self (L lo : Nat) (h : lo < L) : granted (selfVotes L lo) = 1 := by
  rw [granted_self_ite]; simp [h]

/-- The node as `campaign` sets it up before counting the self vote. -/
def campaignBase (n : Fields) (term me : Nat) (c sn en ln : PureValue) (N lo : Nat) : Fields :=
  { n with prevoting := .absent, state := statev (hardv term (.present (idv me)) c) sn en ln,
           dirty := .boolean true, role := candidatev, leader := .absent, votes := boolsv (selfVotes N lo) }

/-- `campaign(term)`: the node votes for itself in `term` as a candidate; it
    becomes leader at once if that single vote is a majority, and otherwise
    requests votes from every other slot. -/
theorem campaign_spec (target : Target) (n : Fields) (ids : List Nat) (me : Nat) (fixed : Fixed ids me n)
    (t : Nat) (vf c sn en ln : PureValue) (hs : n.state = statev (hardv t vf c) sn en ln)
    (bs : List Bool) (hv : n.votes = boolsv bs) (hbs : bs.length = ids.length)
    (os : List PureValue) (ho : n.outbox = .array os) (sized : os.length = ids.length) (term : Nat)
    (cap : PureValue) :
    SatisfiesBack (machine target) "node::Node::campaign"
      { pre := fun self values => self = n.value ∧
          values = [.number "u64" term, .number "usize" ids.length, cap],
        post := fun _ _ _ r => ∃ n', r = n'.value ∧
          let base := campaignBase n term me c sn en ln ids.length (ids.idxOf me)
          ((ids.length / 2 < 1 ∧ Calm { base with role := leaderv } n') ∨
           (¬ ids.length / 2 < 1 ∧ Calm { base with outbox := .array (voteBox os (ids.idxOf me)) } n')) } := by
  refine ⟨_, rfl, ?_⟩
  rintro self values ⟨rfl, rfl⟩
  apply Wp.triple
  rintro env rfl
  simp only [Jarl.function_node_Node_campaign, frameOf, List.zipIdx, List.foldl]
  wp_walk [Fields.value, hs, statev, hardv, fixed.self]
  refine wp_fill (name := "Node") ?fs (bs.map PureValue.boolean) (.boolean false) ?h0 ?hf ?hx
    ⟨by decide, by decide, by decide⟩ ?done
  case h0 => simp (disch := decide) only [set_same, set_other]; rfl
  case hf => simp [hv, boolsv]
  case hx => simp (disch := decide) only [set_same, set_other]
  case done =>
    intro e v hkept h0
    have hme : ids.idxOf me < ids.length := List.idxOf_lt_length_of_mem fixed.member
    have hme' : ids.idxOf me < (List.replicate (List.map PureValue.boolean bs).length (PureValue.boolean false)).length := by
      simp [hbs, hme]
    wp_walk [h0, hkept, fixed.slot, hme']
    apply wp_invoke_back _ (reset_election_spec target nodeOf)
    wp_walk [hkept]
    refine ⟨⟨nodeEq, _, _, rfl⟩, ?_⟩
    rintro v r ⟨N, rfl, rnd, dl, el, hN⟩
    wp_walk [hkept]
    apply wp_invoke _ (election_quorum_spec target _ ids (selfVotes ids.length (ids.idxOf me)) fixed.unique
      (by simp [selfVotes]))
    wp_walk [hkept]
    refine ⟨⟨rfl, by rw [hN]; exact fixed.membership, by rw [hN]; exact fixed.peers, ?_, _, _, rfl⟩, ?_⟩
    · rw [hN]; simp only [boolsv, List.length_map, hbs, replicate_set_self]
    rintro v r ⟨-, rfl⟩
    wp_walk [hkept, granted_self ids.length (ids.idxOf me) hme]
    case yes =>
      subst hN
      apply wp_invoke_back _ (become_leader_spec target _ ids me ?bfx term (.present (idv me)) c sn en ln ?bhs
        os ?bho sized cap)
      wp_walk [hkept]
      refine ⟨⟨rfl, by simp⟩, ?_⟩
      rintro v r ⟨n', rfl, calm⟩
      wp_walk [hkept]
      wp_receiver
      refine ⟨n', rfl, Or.inl ⟨by simp_all, ?_⟩⟩
      refine Calm.trans ?_ calm
      exact { config := rfl, role := rfl, slot := by first | rfl | exact fixed.slot.symm, membership := rfl,
              bootstrap := rfl, hooks := rfl,
              peers := rfl, votes := by simp [campaignBase, boolsv, replicate_set_self, hbs],
              prevoting := rfl, extra_reply := rfl, hard := fun _ _ h => h, dirty := Or.inl rfl,
              outbox := fun os h => ⟨os, h, Settled.refl os⟩ }
      case bfx => exact ⟨fixed.unique, fixed.member, fixed.membership, fixed.bootstrap, fixed.hooks, fixed.peers,
        fixed.self, by first | exact fixed.slot | rfl⟩
      case bhs => rfl
      case bho => exact ho
    case no =>
      have hNp : N.peers = peersv ids := by rw [hN]; exact fixed.peers
      have hNm : N.membership = membershipv ids := by rw [hN]; exact fixed.membership
      have hNl : N.local = .number "usize" (ids.idxOf me) := by rw [hN]; try exact fixed.slot
      have hNo : N.outbox = .array os := by rw [hN]; exact ho
      apply wp_scan_here "usize" ids.length ([0] ++ List.range' 18 8)
        (fun k e => ∃ os', e 0 = some { N with outbox := .array os' }.value ∧ os'.length = os.length ∧
          ∀ i, i < os.length → os'[i]? = if i < k ∧ i ≠ ids.idxOf me then some votev else os[i]?)
        (by decide) (by simp (disch := decide) only [set_same, set_other]) 0
        (by simp (disch := decide) only [set_same]) (Nat.zero_le _)
        ⟨os, by simp (disch := decide) only [set_same, set_other, hkept]; try rw [← hNo], rfl,
          fun i _ => by simp⟩
      · intro k e hc hlt hbound hwide hk ⟨os', h0', hlen, hos⟩
        wp_walk [hc, hk, h0', hkept, Fields.value, hNp, hNl, peersv]
        case isTrue =>
          apply wp_invoke _ (is_voter_spec target ids ids[k])
          wp_walk [hc, hk, h0', hkept, Fields.value, hNm]
          refine ⟨by simp, ?_⟩
          rintro v r ⟨-, rfl⟩
          wp_walk [List.getElem_mem hlt, decide_true]
          have hk' : k < os'.length := by omega
          apply wp_invoke_back _ (send_spec target { N with outbox := .array os' } os' k ids.length
            (.variant "Outbound" "Vote" []) cap hk' (by omega))
          wp_walk [hc, hk, h0', hkept]
          refine ⟨by simp, ?_⟩
          rintro v r rfl
          wp_walk [hc, hk, h0', hkept]
          refine ⟨k + 1, by simp (disch := decide) only [set_same, set_other], by omega, by wp_kept hk,
            os'.set k votev, by simp (disch := decide) only [set_same, set_other]; rfl, by simp [hlen], ?_⟩
          intro i hi
          by_cases same : i = k
          · subst same
            have : i ≠ ids.idxOf me := by intro h; subst h; simp_all
            simp [hk', this]
          · rw [List.getElem?_set_ne (Ne.symm same), hos i hi]
            by_cases lt : i < k
            · simp [lt, show i < k + 1 by omega]
            · simp [lt, show ¬ i < k + 1 by omega]
        case isFalse =>
          refine ⟨k + 1, by simp (disch := decide) only [set_same, set_other], by omega, by wp_kept hk,
            os', by simp (disch := decide) only [set_same, set_other, h0'], hlen, ?_⟩
          intro i hi
          rw [hos i hi]
          by_cases same : i = k
          · subst same
            have : i = ids.idxOf me := by simp_all
            simp [this]
          · by_cases lt : i < k
            · simp [lt, show i < k + 1 by omega]
            · simp [lt, show ¬ i < k + 1 by omega]
      · intro e hc hk ⟨os', h0', hlen, hos⟩
        have hbox : os' = voteBox os (ids.idxOf me) := by
          apply List.ext_getElem?
          intro i
          by_cases hi : i < os.length
          · rw [hos i hi, voteBox, List.getElem?_mapIdx]
            by_cases same : i = ids.idxOf me
            · simp [same]
            · have : i < ids.length := by omega
              simp [same, this, List.getElem?_eq_getElem hi]
          · rw [List.getElem?_eq_none (by omega), List.getElem?_eq_none (by simp [voteBox]; omega)]
        subst hbox
        simp only [ite_true]
        wp_walk [hk, h0']
        wp_receiver [h0']
        refine ⟨_, rfl, Or.inr ⟨‹_›, ?_⟩⟩
        subst hN
        exact { config := rfl, role := rfl, slot := by first | rfl | exact fixed.slot.symm, membership := rfl,
                bootstrap := rfl, hooks := rfl, peers := rfl,
                votes := by simp [campaignBase, boolsv, replicate_set_self, hbs],
                prevoting := rfl, extra_reply := rfl, hard := fun _ _ h => h, dirty := Or.inl rfl,
                outbox := fun os h => ⟨os, h, Settled.refl os⟩ }

def followerv : PureValue := .variant "Role" "Follower" []

/-- A calm relation whose fields hold by definition or by the hypotheses in scope. -/
macro "calm_auto" : term =>
  `({ config := by first | rfl | simp_all [followerv, candidatev, leaderv], role := by first | rfl | simp_all [followerv, candidatev, leaderv],
      slot := by first | rfl | simp_all [followerv, candidatev, leaderv], membership := by first | rfl | simp_all [followerv, candidatev, leaderv],
      bootstrap := by first | rfl | simp_all [followerv, candidatev, leaderv], hooks := by first | rfl | simp_all [followerv, candidatev, leaderv],
      peers := by first | rfl | simp_all [followerv, candidatev, leaderv], votes := by first | rfl | simp_all [followerv, candidatev, leaderv],
      prevoting := by first | rfl | simp_all [followerv, candidatev, leaderv], extra_reply := by first | rfl | simp_all [followerv, candidatev, leaderv],
      hard := fun _ _ h => by
        first | exact h | exact termVote_keep (by assumption) _ _ _ _ _ _ h | simp_all [followerv, candidatev, leaderv],
      dirty := by first | exact Or.inl rfl | exact Or.inr rfl | simp_all [followerv, candidatev, leaderv],
      outbox := fun os h => ⟨os, by first | exact h | simp_all [followerv, candidatev, leaderv], Settled.refl os⟩ })

/-- Every reachable node of the fixed engine: the stable configuration's tables,
    a well-formed log state, a vote table and outbox of one slot per member,
    no probe, no extra reply, and a role. -/
structure Good (ids : List Nat) (me : Nat) (n : Fields) : Prop where
  fixed : Fixed ids me n
  votes : ∃ bs, n.votes = boolsv bs ∧ bs.length = ids.length
  outbox : ∃ os, n.outbox = .array os ∧ os.length = ids.length ∧ ∀ o ∈ os, o = .absent ∨ ∃ y, o = .present y
  dirty : ∃ b, n.dirty = .boolean b
  extra : n.extra_reply = .absent
  role : n.role = followerv ∨ n.role = candidatev ∨ n.role = leaderv
  prevoting : n.prevoting = .absent

theorem Good.calm {ids : List Nat} {me : Nat} {n n' : Fields} (g : Good ids me n) (c : Calm n n') :
    Good ids me n' where
  fixed := g.fixed.calm c
  votes := by rw [c.votes]; exact g.votes
  outbox := by
    obtain ⟨os, ho, sized, hos⟩ := g.outbox
    obtain ⟨os', ho', set⟩ := c.outbox os ho
    refine ⟨os', ho', by rw [set.1, sized], fun o ho'' => ?_⟩
    obtain ⟨i, hi, rfl⟩ := List.getElem_of_mem ho''
    rcases set.2 i (by rw [← set.1]; exact hi) with e | ⟨v, e, q⟩
    · rw [List.getElem?_eq_getElem hi] at e
      exact hos _ (List.mem_of_getElem? e.symm)
    · rw [List.getElem?_eq_getElem hi] at e
      cases e
      rcases q with h | ⟨a, b, h⟩ <;> exact Or.inr ⟨_, h⟩
  dirty := by
    obtain ⟨b, hb⟩ := g.dirty
    rcases c.dirty with e | e
    · exact ⟨b, by rw [e, hb]⟩
    · exact ⟨true, e⟩
  extra := by rw [c.extra_reply]; exact g.extra
  role := by rw [c.role]; exact g.role
  prevoting := by rw [c.prevoting]; exact g.prevoting

/-- A specification at every node satisfying `Pre`, with argument lists in `V`,
    as one specification whose receiver node is found from its value. -/
theorem uniformize {target : Target} {name : String} {body : Expr}
    (hbody : (machine target).functions name = some body) {Pre : Fields → Prop}
    {V : Fields → List PureValue → Prop} {P : Fields → PureValue → PureValue → Prop}
    (h : ∀ n, Pre n → ∀ vs, V n vs → SatisfiesBack (machine target) name
      { pre := fun self values => self = n.value ∧ values = vs, post := fun _ _ v r => P n v r }) :
    SatisfiesBack (machine target) name
      { pre := fun self values => ∃ n : Fields, self = n.value ∧ (Pre n ∧ V n values),
        post := fun self _ v r => ∀ n : Fields, self = n.value → P n v r } := by
  apply back_uniform Fields.value Fields.value_inj (fun n values => Pre n ∧ V n values)
    (fun n _ v r => P n v r)
  intro n
  apply back_pointwise hbody
  rintro self values ⟨rfl, pre, hv⟩
  exact back_weaken (h n pre values hv) (fun _ _ h => h) (fun _ _ _ _ _ h => h)

theorem refresh_u (target : Target) (ids : List Nat) (me : Nat) (cap : PureValue) :
    SatisfiesBack (machine target) "node::Node::refresh_membership"
      { pre := fun self values => ∃ n : Fields, self = n.value ∧
          (Fixed ids me n ∧ values = [.number "usize" ids.length, cap]),
        post := fun self _ _ r => ∀ n : Fields, self = n.value → r = n.value } := by
  apply back_uniform Fields.value Fields.value_inj
    (fun n values => Fixed ids me n ∧ values = [.number "usize" ids.length, cap])
    (fun (n : Fields) _ _ r => r = n.value)
  intro n
  apply back_pointwise rfl
  rintro self values ⟨rfl, fixed, rfl⟩
  exact back_weaken (refresh_membership_spec target n ids me fixed cap) (fun _ _ h => h) (fun _ _ _ _ _ h => h)

/-! ### Replication: calm -/

set_option maxHeartbeats 4000000 in
/-- `append` is calm. -/
theorem append_spec (target : Target) (n : Fields) (ids : List Nat) (me : Nat) (fixed : Fixed ids me n)
    (t : Nat) (vf c sn en ln : PureValue) (hs : n.state = statev (hardv t vf c) sn en ln)
    (previous entry commit cap : PureValue) :
    SatisfiesBack (machine target) "node::Node::append"
      { pre := fun self values => self = n.value ∧
          values = [previous, entry, commit, .number "usize" ids.length, cap],
        post := fun _ _ _ r => ∃ n', r = n'.value ∧ Calm n n' } := by
  have hh := fixed.hooks
  have hslot := fixed.slot
  refine ⟨_, rfl, ?_⟩
  rintro self values ⟨rfl, rfl⟩
  apply Wp.triple
  rintro env rfl
  simp only [Jarl.function_node_Node_append, frameOf, List.zipIdx, List.foldl]
  wp_walk_any [Fields.value, hs, statev_hard, hardv_commit, hardv_term]
  all_goals first
    | (wp_receiver; first | exact ⟨n, rfl, Calm.refl n⟩ | exact ⟨_, nodeEq, calm_auto⟩)
    | (apply wp_invoke_back _ (truncate_spec target t vf c sn en ln)
       wp_walk [Fields.value, hs]
       refine ⟨by simp [StateKeeps, hs], ?_⟩
       rintro v r ⟨c1, sn1, en1, ln1, rfl⟩
       wp_walk_any [Fields.value, statev_hard, hardv_commit, hardv_term]
       apply wp_invoke_back _ (push_spec target t vf c1 sn1 en1 ln1)
       wp_walk [Fields.value]
       refine ⟨by simp [StateKeeps], ?_⟩
       rintro v r ⟨⟨c2, sn2, en2, ln2, rfl⟩, hv | hv⟩ <;> subst hv <;>
         wp_walk_any [Fields.value, okv, fullv, statev_hard, hardv_commit, hardv_term]
       all_goals first
         | (wp_receiver; exact ⟨_, nodeEq, calm_auto⟩)
         | (apply wp_invoke_back _ (refresh_u target ids me cap)
            wp_walk [Fields.value]
            refine ⟨⟨nodeOf, nodeEq, fixed.calm calm_auto, by first | rfl | trivial⟩, ?_⟩
            rintro v r hpost
            have hr := hpost nodeOf nodeEq
            subst hr
            wp_walk_any [Fields.value, statev_hard, hardv_commit, hardv_term]
            all_goals first
              | (wp_receiver; exact ⟨_, nodeEq, calm_auto⟩)
              | (apply wp_invoke_back _ (commit_to_u target ids me cap)
                 wp_walk [Fields.value, statev_hard, hardv_commit, hardv_term]
                 refine ⟨⟨nodeOf, (by first | exact nodeEq | rfl), fixed.calm calm_auto, ⟨t, vf, ⟨c2, sn2, en2, ln2, rfl⟩⟩,
                   by first | exact ⟨_, rfl⟩ | rfl | trivial | simp_all⟩, ?_⟩
                 rintro v r hpost
                 obtain ⟨n2, rfl, calm2⟩ := hpost nodeOf (by first | exact nodeEq | rfl)
                 wp_walk [Fields.value, statev_hard, hardv_commit, hardv_term]
                 wp_receiver
                 exact ⟨n2, rfl, Calm.trans calm_auto calm2⟩)))
    | (apply wp_invoke_back _ (commit_to_u target ids me cap)
       wp_walk [Fields.value, hs, statev_hard, hardv_commit, hardv_term]
       refine ⟨⟨nodeOf, (by first | exact nodeEq | rfl), fixed.calm calm_auto, ⟨t, vf, ⟨c, sn, en, ln, by first | rfl | exact hs⟩⟩, by first | exact ⟨_, rfl⟩ | rfl | trivial | simp_all⟩, ?_⟩
       rintro v r hpost
       obtain ⟨n2, rfl, calm2⟩ := hpost nodeOf (by first | exact nodeEq | rfl)
       wp_walk [Fields.value, hs, statev_hard, hardv_commit, hardv_term]
       wp_receiver
       exact ⟨n2, rfl, Calm.trans calm_auto calm2⟩)

/-- `replicate` queues a replication request, which is calm. -/
theorem replicate_u (target : Target) (ids : List Nat) (cap : PureValue) :
    SatisfiesBack (machine target) "node::Node::replicate"
      { pre := fun self values => ∃ n : Fields, self = n.value ∧
          ((∃ os, n.outbox = .array os ∧ os.length = ids.length) ∧
            ∃ p, values = [.number "usize" p, .number "usize" ids.length, cap] ∧ p < ids.length),
        post := fun self _ _ r => ∀ n : Fields, self = n.value → ∃ n', r = n'.value ∧ Calm n n' } := by
  apply back_uniform Fields.value Fields.value_inj
    (fun n values => (∃ os, n.outbox = .array os ∧ os.length = ids.length) ∧
      ∃ p, values = [.number "usize" p, .number "usize" ids.length, cap] ∧ p < ids.length)
    (fun (n : Fields) _ _ r => ∃ n', r = n'.value ∧ Calm n n')
  intro n
  apply back_pointwise rfl
  rintro self values ⟨rfl, ⟨os, ho, sized⟩, p, rfl, hp⟩
  refine back_weaken (replicate_spec target n os p ids.length cap (by omega) (by omega)) (fun _ _ h => ⟨h.1, ho, h.2⟩)
    (fun _ _ _ _ _ h => ?_)
  subst h
  refine ⟨_, rfl, ?_⟩
  exact { config := rfl, role := rfl, slot := rfl, membership := rfl, bootstrap := rfl, hooks := rfl,
          peers := rfl, votes := rfl, prevoting := rfl, extra_reply := rfl, hard := fun _ _ h => h,
          dirty := Or.inl rfl,
          outbox := fun os' h => by
            rw [ho] at h; cases h
            exact ⟨_, rfl, (Settled.refl os).set p _ (Or.inl rfl)⟩ }

set_option maxHeartbeats 4000000 in
/-- `replicated` (a leader handling a replication reply) is calm. -/
theorem replicated_spec (target : Target) (n : Fields) (ids : List Nat) (me : Nat) (good : Good ids me n)
    (t : Nat) (vf c sn en ln : PureValue) (hs : n.state = statev (hardv t vf c) sn en ln) (p : Nat)
    (hp : p < ids.length) (index rejection cap : PureValue)
    (hrej : rejection = .absent ∨ (∃ nx, rejection = .present (.variant "Rejection" "Conflict" [("next", nx)])) ∨
      rejection = .present (.variant "Rejection" "Full" [])) :
    SatisfiesBack (machine target) "node::Node::replicated"
      { pre := fun self values => self = n.value ∧
          values = [.number "usize" p, index, rejection, .number "usize" ids.length, cap],
        post := fun _ _ _ r => ∃ n', r = n'.value ∧ Calm n n' } := by
  have fixed := good.fixed
  obtain ⟨os, ho, sized, -⟩ := good.outbox
  have hh := fixed.hooks
  have hslot := fixed.slot
  refine ⟨_, rfl, ?_⟩
  rintro self values ⟨rfl, rfl⟩
  apply Wp.triple
  rintro env rfl
  simp only [Jarl.function_node_Node_replicated, frameOf, List.zipIdx, List.foldl]
  rcases hrej with rfl | ⟨nx, rfl⟩ | rfl <;>
    wp_walk_any [Fields.value, hs, statev_hard, hardv_commit, hardv_term]
  all_goals first
    | (wp_receiver; first | exact ⟨n, rfl, Calm.refl n⟩ | exact ⟨_, nodeEq, calm_auto⟩)
    | (apply wp_invoke_back _ (replicate_u target ids cap)
       wp_walk
       refine ⟨⟨nodeOf, nodeEq, ⟨os, by first | rfl | exact ho, sized⟩, p, by first | rfl | simp_all, hp⟩, ?_⟩
       rintro v r hpost
       obtain ⟨n2, rfl, calm2⟩ := hpost nodeOf nodeEq
       wp_walk
       wp_receiver
       exact ⟨n2, rfl, Calm.trans calm_auto calm2⟩)
    | (apply wp_invoke_back _ (advance_commit_u target ids me cap)
       wp_walk
       refine ⟨⟨nodeOf, nodeEq, fixed.calm calm_auto, ⟨t, vf, ⟨c, sn, en, ln, by first | rfl | exact hs⟩⟩,
         by first | rfl | trivial | simp_all⟩, ?_⟩
       rintro v r hpost
       obtain ⟨n2, rfl, calm2⟩ := hpost nodeOf nodeEq
       have calm2' : Calm n n2 := by refine Calm.trans ?_ calm2; exact calm_auto
       obtain ⟨os2, ho2, set2⟩ := calm2'.outbox os ho
       wp_walk_any [Fields.value]
       all_goals first
         | (wp_receiver; exact ⟨n2, rfl, calm2'⟩)
         | (apply wp_invoke_back _ (broadcast_spec target n2 ids os2 (ids.idxOf me) cap
              (by rw [set2.1, sized]) ((fixed.calm calm2').peers) ((fixed.calm calm2').membership)
              ((fixed.calm calm2').slot) ho2)
            wp_walk
            refine ⟨by first | exact ⟨rfl, rfl⟩ | exact ⟨rfl, trivial⟩ | simp [Fields.value] | trivial, ?_⟩
            rintro v r ⟨os3, rfl, rep⟩
            wp_walk
            wp_receiver
            refine ⟨_, rfl, calm2'.trans ?_⟩
            exact { config := rfl, role := rfl, slot := rfl, membership := rfl, bootstrap := rfl, hooks := rfl,
                    peers := rfl, votes := rfl, prevoting := rfl, extra_reply := rfl, hard := fun _ _ h => h,
                    dirty := Or.inl rfl,
                    outbox := fun os' h => by
                      rw [ho2] at h; cases h; exact ⟨os3, rfl, Settled.of_replicated rep⟩ })
         | (apply wp_invoke_back _ (replicate_u target ids cap)
            wp_walk
            refine ⟨⟨nodeOf, (by first | exact nodeEq | rfl), ⟨os2, by first | rfl | exact ho2, by rw [set2.1, sized]⟩,
              p, by first | rfl | simp_all, hp⟩, ?_⟩
            rintro v r hpost
            obtain ⟨n3, rfl, calm3⟩ := hpost nodeOf (by first | exact nodeEq | rfl)
            wp_walk
            wp_receiver
            exact ⟨n3, rfl, calm2'.trans (Calm.trans calm_auto calm3)⟩))

/-! ### The input gate -/

/-- A node with no pending save, no pending reply and an empty outbox. -/
def Idle (n : Fields) : Prop :=
  n.dirty = .boolean false ∧ n.extra_reply = .absent ∧ ∃ os, n.outbox = .array os ∧ ∀ o ∈ os, o = .absent

def busyv : PureValue := .variant "Result" "Err" [("0", .variant "Error" "Busy" [])]

/-- `available` accepts exactly idle nodes, and otherwise reports `Busy`. -/
theorem available_spec (target : Target) (n : Fields) (os : List PureValue) (ho : n.outbox = .array os)
    (hos : ∀ o ∈ os, o = .absent ∨ ∃ y, o = .present y) (b : Bool) (hd : n.dirty = .boolean b)
    (hx : n.extra_reply = .absent) :
    Satisfies (machine target) "node::Node::available"
      { pre := fun self values => self = n.value ∧ ∃ a c, values = [a, c],
        post := fun _ _ v r => r = n.value ∧ (v = okv ∧ Idle n ∨ v = busyv) } := by
  refine ⟨_, rfl, ?_⟩
  rintro self values ⟨rfl, a, c, rfl⟩
  apply Wp.triple
  rintro env rfl
  simp only [Jarl.function_node_Node_available, frameOf, List.zipIdx, List.foldl]
  wp_walk [Fields.value, hd, hx, ho]
  case isTrue =>
    exact ⟨n.value, by simp (disch := decide) [set_same, set_other, Fields.value, ho, hd, hx], rfl, Or.inr rfl⟩
  case isFalse =>
    apply wp_scan_here "usize" os.length [7, 8, 9, 12, 13]
      (fun k e => e 7 = some (.boolean false) ∧ ∀ o ∈ os.take k, o = .absent) (by decide)
      (by simp (disch := decide) only [set_same, set_other]) 0
      (by simp (disch := decide) only [set_same]) (Nat.zero_le _)
      (by simp (disch := decide) only [set_same, set_other]; simp)
    · intro k e hc hlt hbound hwide hkept ⟨h7, hnot⟩
      rcases hos os[k] (List.getElem_mem hlt) with habs | ⟨y, hy⟩
      · wp_walk [hc, hkept, hlt, h7, habs]
        refine ⟨k + 1, by simp (disch := decide) only [set_same, set_other], by omega, by wp_kept hkept,
          by simp (disch := decide) only [set_other, h7], ?_⟩
        intro o ho'
        rw [take_succ os k hlt] at ho'
        simp only [List.mem_append, List.mem_singleton] at ho'
        rcases ho' with h | h
        · exact hnot o h
        · rw [h, habs]
      · wp_walk [hc, hkept, hlt, h7, hy]
        exact ⟨n.value, by simp (disch := decide) [set_same, set_other, hkept, Fields.value, ho, hd, hx], rfl, Or.inr rfl⟩
    · intro e hc hkept ⟨h7, hnot⟩
      simp only [ite_true]
      wp_walk [h7]
      refine ⟨n.value, by simp (disch := decide) [set_same, set_other, hkept, Fields.value, ho, hd, hx], rfl,
        Or.inl ⟨rfl, ?_⟩⟩
      refine ⟨by simp_all, hx, os, ho, fun o h => hnot o (by simpa using h)⟩

/-! ### `tick` -/

/-- What `campaign(term)` leaves, relative to the node before it. -/
def Campaigned (ids : List Nat) (me : Nat) (n : Fields) (term : Nat) (c sn en ln : PureValue)
    (os : List PureValue) (n' : Fields) : Prop :=
  let base := campaignBase n term me c sn en ln ids.length (ids.idxOf me)
  (ids.length / 2 < 1 ∧ Calm { base with role := leaderv } n') ∨
    (¬ ids.length / 2 < 1 ∧ Calm { base with outbox := .array (voteBox os (ids.idxOf me)) } n')

theorem campaign_u (target : Target) (ids : List Nat) (me : Nat) (term : Nat) (cap : PureValue) :
    SatisfiesBack (machine target) "node::Node::campaign"
      { pre := fun self values => ∃ n, self = n.value ∧
          (Good ids me n ∧ (∃ t vf, TermVote n.state t vf) ∧
            values = [.number "u64" term, .number "usize" ids.length, cap]),
        post := fun self _ _ r => ∀ n, self = n.value → ∃ n', r = n'.value ∧
          ∃ t vf c sn en ln os, n.state = statev (hardv t vf c) sn en ln ∧ n.outbox = .array os ∧
            Campaigned ids me n term c sn en ln os n' } := by
  apply back_uniform Fields.value Fields.value_inj
    (fun n values => Good ids me n ∧ (∃ t vf, TermVote n.state t vf) ∧
      values = [.number "u64" term, .number "usize" ids.length, cap])
    (fun n _ _ r => ∃ n', r = n'.value ∧ ∃ t vf c sn en ln os, n.state = statev (hardv t vf c) sn en ln ∧
      n.outbox = .array os ∧ Campaigned ids me n term c sn en ln os n')
  intro n
  apply back_pointwise rfl
  rintro self values ⟨rfl, good, ⟨t, vf, c, sn, en, ln, hs⟩, rfl⟩
  obtain ⟨bs, hv, hbs⟩ := good.votes
  obtain ⟨os, ho, sized, -⟩ := good.outbox
  exact back_weaken (campaign_spec target n ids me good.fixed t vf c sn en ln hs bs hv hbs os ho sized term cap)
    (fun _ _ h => h) (fun _ _ _ _ _ ⟨n', hr, hc⟩ => ⟨n', hr, t, vf, c, sn, en, ln, os, hs, ho, hc⟩)

/-- A campaign from a node differing only outside the election state is a
    campaign from the original node. -/
theorem Campaigned.of_calm {ids : List Nat} {me : Nat} {n N n' : Fields} {term : Nat} {c sn en ln : PureValue}
    {os : List PureValue} (h : Campaigned ids me N term c sn en ln os n')
    (cfg : N.config = n.config) (slot : N.local = n.local)
    (mem : N.membership = n.membership) (boot : N.bootstrap = n.bootstrap) (hk : N.hooks = n.hooks)
    (pe : N.peers = n.peers) (ex : N.extra_reply = n.extra_reply) (ou : N.outbox = n.outbox) :
    Campaigned ids me n term c sn en ln os n' := by
  unfold Campaigned campaignBase at *
  rcases h with ⟨q, h⟩ | ⟨q, h⟩
  · refine Or.inl ⟨q, Calm.trans ?_ h⟩
    exact { config := cfg, role := rfl, slot := slot, membership := mem, bootstrap := boot,
            hooks := hk, peers := pe, votes := rfl, prevoting := rfl, extra_reply := ex,
            hard := fun _ _ h => h, dirty := Or.inl rfl, outbox := fun os h => ⟨os, by rw [ou]; exact h,
              Settled.refl os⟩ }
  · refine Or.inr ⟨q, Calm.trans ?_ h⟩
    exact { config := cfg, role := rfl, slot := slot, membership := mem, bootstrap := boot,
            hooks := hk, peers := pe, votes := rfl, prevoting := rfl, extra_reply := ex,
            hard := fun _ _ h => h, dirty := Or.inl rfl, outbox := fun os h => ⟨os, h, Settled.refl os⟩ }

set_option maxHeartbeats 2000000 in
/-- `tick`: either nothing election-related happens, or an idle non-leader
    starts a campaign for the next term. -/
theorem tick_spec (target : Target) (n : Fields) (ids : List Nat) (me : Nat) (good : Good ids me n)
    (t : Nat) (vf c sn en ln : PureValue) (hs : n.state = statev (hardv t vf c) sn en ln) (cap : PureValue)
    {fuel : Nat} {v r : PureValue}
    (h : Jarl.node_Node_tick target fuel n.value [.number "usize" ids.length, cap] = .ok (v, r)) :
    ∃ n', r = n'.value ∧ (Calm n n' ∨ (Idle n ∧ n.role ≠ leaderv ∧
      ∃ os, n.outbox = .array os ∧ Campaigned ids me n (t + 1) c sn en ln os n')) := by
  have hh := good.fixed.hooks
  have hmem := good.fixed.membership
  have hboot := good.fixed.bootstrap
  have hpeers := good.fixed.peers
  have hslot := good.fixed.slot
  simp only [Jarl.node_Node_tick] at h
  refine run_of_wp (m := machine target) (P := fun _ r => ∃ n', r = n'.value ∧ (Calm n n' ∨ (Idle n ∧
    n.role ≠ leaderv ∧ ∃ os, n.outbox = .array os ∧ Campaigned ids me n (t + 1) c sn en ln os n'))) ?_ h
  obtain ⟨os, ho, sized, hos⟩ := good.outbox
  obtain ⟨b, hd⟩ := good.dirty
  simp only [Jarl.node_Node_tick_ir, frameOf, List.zipIdx, List.foldl]
  wp_walk [Fields.value]
  apply wp_invoke _ (available_spec target n os ho hos b hd good.extra)
  wp_walk
  refine ⟨by simp, ?_⟩
  rintro v r ⟨-, hv⟩
  rcases hv with ⟨rfl, idle⟩ | rfl
  case inr =>
    wp_walk [busyv]
    wp_receiver
    exact ⟨n, rfl, Or.inl (Calm.refl n)⟩
  rcases good.role with hr | hr | hr <;>
    wp_walk [okv, Fields.value, hr, good.fixed.hooks, followerv, candidatev, leaderv, binary_tags, hs]
  all_goals first
    | (wp_receiver; exact ⟨_, nodeEq, Or.inl calm_auto⟩)
    | (apply wp_invoke_back _ (barrier_u target ids me cap)
       wp_walk
       refine ⟨⟨nodeOf, nodeEq, good.fixed.calm calm_auto, ⟨t, vf, c, sn, en, ln, by first | rfl | exact hs⟩,
         by first | rfl | trivial | (split at * <;> simp_all)⟩, ?_⟩
       rintro v r hpost
       obtain ⟨n2, rfl, calm2⟩ := hpost nodeOf nodeEq
       wp_walk
       have calm2' : Calm n n2 := by refine Calm.trans ?_ calm2; exact calm_auto
       obtain ⟨os2, ho2, set2⟩ := calm2'.outbox os ho
       apply wp_invoke_back _ (broadcast_spec target n2 ids os2 (ids.idxOf me) cap
         (by rw [set2.1, sized]) ((good.fixed.calm calm2').peers) ((good.fixed.calm calm2').membership)
         ((good.fixed.calm calm2').slot) ho2)
       wp_walk
       refine ⟨by first | exact ⟨rfl, rfl⟩ | simp | trivial, ?_⟩
       rintro v r ⟨os3, rfl, rep⟩
       wp_walk
       wp_receiver
       refine ⟨_, rfl, Or.inl (calm2'.trans ?_)⟩
       exact { config := rfl, role := rfl, slot := rfl, membership := rfl, bootstrap := rfl, hooks := rfl,
               peers := rfl, votes := rfl, prevoting := rfl, extra_reply := rfl, hard := fun _ _ h => h,
               dirty := Or.inl rfl,
               outbox := fun os' h => by rw [ho2] at h; cases h; exact ⟨os3, rfl, Settled.of_replicated rep⟩ })
    | (apply wp_invoke _ (is_voter_spec target ids me)
       wp_walk [Fields.value, good.fixed.membership, good.fixed.self]
       refine ⟨by simp, ?_⟩
       rintro v r ⟨-, rfl⟩
       wp_walk [good.fixed.member, decide_true, Fields.value, hs, statev_hard, hardv_term]
       all_goals first
         | (wp_receiver; exact ⟨_, nodeEq, Or.inl calm_auto⟩)
         | (apply wp_invoke_back _ (campaign_u target ids me (t + 1) cap)
            wp_walk
            refine ⟨⟨nodeOf, nodeEq, good.calm calm_auto, ⟨t, vf, c, sn, en, ln, by first | rfl | exact hs⟩,
              by first | rfl | trivial | (split at * <;> simp_all)⟩, ?_⟩
            rintro v r hpost
            obtain ⟨n', rfl, t', vf', c', sn', en', ln', os', hs', ho', camp⟩ := hpost nodeOf nodeEq
            wp_walk
            wp_receiver
            simp only [hs, statev, hardv, PureValue.record.injEq, List.cons.injEq, Prod.mk.injEq,
              PureValue.number.injEq, true_and, and_true] at hs'
            obtain ⟨⟨rfl, rfl, rfl⟩, rfl, rfl, rfl⟩ := hs'
            rw [ho] at ho'
            cases ho'
            refine ⟨n', rfl, Or.inr ⟨idle, by simp [hr, followerv, candidatev, leaderv], os, ho, ?_⟩⟩
            exact camp.of_calm (by first | rfl | simp_all) (by first | rfl | simp_all) (by first | rfl | simp_all) (by first | rfl | simp_all) (by first | rfl | simp_all) (by first | rfl | simp_all) (by first | rfl | simp_all) (by first | rfl | simp_all)))

/-! ### Messages -/

/-- A replication rejection descriptor as optional value. -/
inductive Rej where
  | none | conflict (next : PureValue) | full

def Rej.value : Rej → PureValue
  | .none => .absent
  | .conflict nx => .present (.variant "Rejection" "Conflict" [("next", nx)])
  | .full => .present (.variant "Rejection" "Full" [])

/-- Jarl's messages with their terms typed; log payloads stay opaque. -/
inductive Msg where
  | prevote (term : Nat) (last : PureValue)
  | prevoted (term campaign : Nat) (granted : Bool)
  | vote (term : Nat) (last : PureValue)
  | voted (term : Nat) (granted : Bool)
  | append (term : Nat) (previous entry commit : PureValue)
  | batch (term : Nat) (previous entries commit : PureValue)
  | install (term : Nat) (snapshot : PureValue)
  | replicated (term : Nat) (index : PureValue) (rejection : Rej)

def Msg.value : Msg → PureValue
  | .prevote t l => .variant "Message" "PreVote" [("term", .number "u64" t), ("last", l)]
  | .prevoted t c g => .variant "Message" "PreVoted"
      [("term", .number "u64" t), ("campaign", .number "u64" c), ("granted", .boolean g)]
  | .vote t l => .variant "Message" "Vote" [("term", .number "u64" t), ("last", l)]
  | .voted t g => .variant "Message" "Voted" [("term", .number "u64" t), ("granted", .boolean g)]
  | .append t p e c => .variant "Message" "Append"
      [("term", .number "u64" t), ("previous", p), ("entry", e), ("commit", c)]
  | .batch t p e c => .variant "Message" "AppendBatch"
      [("term", .number "u64" t), ("previous", p), ("entries", e), ("commit", c)]
  | .install t sn => .variant "Message" "Install" [("term", .number "u64" t), ("snapshot", sn)]
  | .replicated t i r => .variant "Message" "Replicated"
      [("term", .number "u64" t), ("index", i), ("rejection", r.value)]

def Msg.term : Msg → Nat
  | .prevote t _ | .prevoted t _ _ | .vote t _ | .voted t _ | .append t _ _ _ | .batch t _ _ _
  | .install t _ | .replicated t _ _ => t

def envelopev (src dst : Nat) (m : Msg) : PureValue :=
  .record "Envelope" [("from", idv src), ("to", idv dst), ("message", m.value)]

theorem message_term_spec (target : Target) (m : Msg) :
    Satisfies (machine target) "Message::term"
      { pre := fun self values => self = m.value ∧ values = [],
        post := fun _ _ v r => r = m.value ∧ v = .number "u64" m.term } := by
  refine ⟨_, rfl, ?_⟩
  rintro self values ⟨rfl, rfl⟩
  apply Wp.triple
  rintro env rfl
  simp only [Jarl.function_Message_term, frameOf, List.zipIdx, List.foldl]
  cases m <;> wp_walk [Msg.value, Rej.value] <;>
    exact ⟨_, by simp (disch := decide) only [set_same, set_other]; rfl, rfl, rfl⟩

end Refine

