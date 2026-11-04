import Step
import Sound
import Leaders
open Provium.State Provium.Imperative
set_option linter.unusedSimpArgs false
namespace Refine
open Jarl.ElectionSafety (World Local Durable Pending Reachable)

/-! ## A cluster running the implementation

Nodes of a stable configuration `ids` take any of five actions in any order:
a timer tick, handling a delivered message, handing one queued message to the
network, saving their checkpoint, and restarting from their saved checkpoint.
The network may drop, duplicate and reorder messages, and may forge any
message that plays no part in elections (replication traffic); election
messages it delivers were sent. -/

structure Cluster where
  nodes : Nat → PureValue
  disks : Nat → PureValue
  net : List PureValue

def Cluster.put (C : Cluster) (v : Nat) (x : PureValue) : Cluster :=
  { C with nodes := fun y => if y = v then x else C.nodes y }

/-- What `next_message` hands the network. -/
def handed : PureValue → List PureValue
  | .present x => [x]
  | _ => []

/-- A generated method: target, fuel, receiver and arguments to a result and final receiver. -/
abbrev Method := Target → Nat → PureValue → List PureValue → Except Fault (PureValue × PureValue)

/-- The five `Node` methods a cluster runs, so a theorem about runs names the
    generated functions it is about. -/
structure Methods where
  tick : Method
  step : Method
  next : Method
  persisted : Method
  build : Method

/-- Jarl's generated methods. -/
def jarl (tick step next persisted build : Method) : Methods := ⟨tick, step, next, persisted, build⟩

inductive Act (M : Methods) (target : Target) (ids : List Nat) (cap : PureValue) : Cluster → Cluster → Prop where
  | tick (C : Cluster) (v : Nat) (member : v ∈ ids) {fuel : Nat} {out r : PureValue}
      (run : M.tick target fuel (C.nodes v) [.number "usize" ids.length, cap] = .ok (out, r)) :
      Act M target ids cap C (C.put v r)
  | deliver (C : Cluster) (v : Nat) (member : v ∈ ids) (src dst : Nat) (m : Msg)
      (carried : envelopev src dst m ∈ C.net ∨ m.election = none) {fuel : Nat} {out r : PureValue}
      (run : M.step target fuel (C.nodes v)
        [envelopev src dst m, .number "usize" ids.length, cap] = .ok (out, r)) :
      Act M target ids cap C (C.put v r)
  | send (C : Cluster) (v : Nat) (member : v ∈ ids) {fuel : Nat} {out r : PureValue}
      (run : M.next target fuel (C.nodes v) [.number "usize" ids.length, cap] =
        .ok (out, r)) :
      Act M target ids cap C { C.put v r with net := C.net ++ handed out }
  | persist (C : Cluster) (v : Nat) (member : v ∈ ids) (n n' : Fields) (hn : C.nodes v = n.value)
      {fuel : Nat} {out : PureValue}
      (run : M.persisted target fuel (readyv n) [] = .ok (out, readyv n')) :
      Act M target ids cap C { C.put v n'.value with disks := fun y => if y = v then n.state else C.disks y }
  | restart (C : Cluster) (v : Nat) (member : v ∈ ids) (n : Fields) (hn : C.nodes v = n.value)
      (self : PureValue) {fuel : Nat} {r x : PureValue}
      (run : M.build target fuel self [n.config, C.disks v, membershipv ids, .absent,
        .number "usize" ids.length, cap] = .ok (.variant "Result" "Ok" [("0", x)], r)) :
      Act M target ids cap C (C.put v x)

/-- Every node built from an empty checkpoint, and nothing sent. -/
structure Initial (M : Methods) (target : Target) (ids : List Nat) (cap : PureValue) (C : Cluster) : Prop where
  net : C.net = []
  nodes : ∀ v ∈ ids, ∃ config c sn en ln self fuel r, pureField config "id" = some (idv v) ∧
    C.disks v = statev (hardv 0 .absent c) sn en ln ∧
    M.build target fuel self [config, C.disks v, membershipv ids, .absent,
      .number "usize" ids.length, cap] = .ok (.variant "Result" "Ok" [("0", C.nodes v)], r)

inductive Runs (M : Methods) (target : Target) (ids : List Nat) (cap : PureValue) : Cluster → Prop where
  | start (C : Cluster) (init : Initial M target ids cap C) : Runs M target ids cap C
  | act {C C' : Cluster} : Runs M target ids cap C → Act M target ids cap C C' → Runs M target ids cap C'

/-! ## The simulation -/

/-- Cluster `C` runs as model world `w`. -/
structure Sim (ids : List Nat) (C : Cluster) (w : World) : Prop where
  voters : w.voters = ids
  node : ∀ v ∈ ids, ∃ n, C.nodes v = n.value ∧ Sound ids v n ∧ Abs ids n (w.nodes v).durable (w.nodes v)
  disk : ∀ v ∈ ids, ∃ c sn en ln,
    C.disks v = statev (hardv (w.nodes v).durable.term (voteValue (w.nodes v).durable.vote) c) sn en ln
  net : ∀ src dst m, envelopev src dst m ∈ C.net → ∀ e, m.election = some e → ⟨src, dst, e⟩ ∈ w.sent

/-- Changing one node of the cluster as the model changes that node. -/
theorem Sim.put {ids : List Nat} {C : Cluster} {w w' : World} (sim : Sim ids C w) (v : Nat) (n : Fields)
    (voters : w'.voters = w.voters) (others : ∀ u, u ≠ v → w'.nodes u = w.nodes u)
    (sent : ∀ e ∈ w.sent, e ∈ w'.sent) (sound : v ∈ ids → Sound ids v n)
    (abs : v ∈ ids → Abs ids n (w'.nodes v).durable (w'.nodes v))
    (durable : (w'.nodes v).durable = (w.nodes v).durable) :
    Sim ids (C.put v n.value) w' where
  voters := voters.trans sim.voters
  node := by
    intro u hu
    by_cases same : u = v
    · subst same
      exact ⟨n, by simp [Cluster.put], sound hu, abs hu⟩
    · obtain ⟨n0, h0, s0, a0⟩ := sim.node u hu
      exact ⟨n0, by simp [Cluster.put, same, h0], s0, by rw [others u same]; exact a0⟩
  disk := by
    intro u hu
    by_cases same : u = v
    · subst same
      rw [durable]; exact sim.disk u hu
    · rw [others u same]; exact sim.disk u hu
  net := fun src dst m h e he => sent _ (sim.net src dst m h e he)

/-! ### The model's side -/

open Jarl.ElectionSafety in
theorem idle_abs {ids : List Nat} {n : Fields} {d : Durable} {L : Local} (a : Abs ids n d L)
    (idle : Refine.Idle n) : Jarl.ElectionSafety.Idle L := by
  obtain ⟨hd, -, os, ho, empty⟩ := idle
  obtain ⟨os', ho', hL⟩ := a.outbox
  rw [ho] at ho'; cases ho'
  exact ⟨a.dirty hd, hL.trans (outboxOf_absent ids os empty)⟩

theorem not_leader {ids : List Nat} {me : Nat} {n : Fields} {d : Durable} {L : Local} (a : Abs ids n d L)
    (good : Good ids me n) (h : n.role ≠ leaderv) : L.role ≠ .leader := by
  rw [← a.role]
  rcases good.role with e | e | e <;> rw [e] <;> simp_all [roleOf, followerv, candidatev, leaderv]

open Jarl.ElectionSafety in
theorem forget_step {w : World} (reach : Reachable w) (v : Nat) (kept : List Pending)
    (sub : kept.Sublist (w.nodes v).outbox) :
    Reachable { w with nodes := set w.nodes v { w.nodes v with outbox := kept } } :=
  Reachable.step reach (Step.forget w v kept sub)

open Jarl.ElectionSafety in
theorem set_others (nodes : Nat → Local) (v : Nat) (s : Local) : ∀ u, u ≠ v → set nodes v s u = nodes u :=
  fun u h => set_other nodes v u s h

open Jarl.ElectionSafety in
theorem campaign_facts (w : World) (v : Nat) :
    (campaign w v).voters = w.voters ∧ (∀ u, u ≠ v → (campaign w v).nodes u = w.nodes u) ∧
      (campaign w v).sent = w.sent ∧ ((campaign w v).nodes v).durable = (w.nodes v).durable := by
  unfold campaign
  split
  · exact ⟨rfl, set_others _ _ _, rfl, by simp⟩
  · exact ⟨rfl, set_others _ _ _, rfl, by simp⟩

/-! ### Each action -/

open Jarl.ElectionSafety in
theorem sim_tick (target : Target) {ids : List Nat} (cap : PureValue) {C : Cluster} {w : World}
    (sim : Sim ids C w) (reach : Reachable w) {v : Nat} (member : v ∈ ids) {fuel : Nat} {out r : PureValue}
    (run : Jarl.node_Node_tick target fuel (C.nodes v) [.number "usize" ids.length, cap] = .ok (out, r)) :
    ∃ w', Reachable w' ∧ Sim ids (C.put v r) w' := by
  obtain ⟨n, hn, sound, a⟩ := sim.node v member
  obtain ⟨c, sn, en, ln, hs⟩ := a.state
  rw [hn] at run
  obtain ⟨n', rfl, calm | ⟨idle, notLeader, os, ho, camp⟩⟩ :=
    tick_spec target n ids v sound.good _ _ _ _ _ _ hs cap run
  · obtain ⟨kept, sub, a'⟩ := a.calm calm
    exact ⟨_, forget_step reach v kept sub, sim.put v n' rfl (set_others _ _ _) (fun _ h => h)
      (fun _ => sound.calm calm) (fun _ => by simpa using a') (by simp)⟩
  · have hw : w.voters = ids := sim.voters
    obtain ⟨kept, sub, a'⟩ := a.campaigned sound.good idle hs ho camp w hw rfl
    obtain ⟨fv, fo, fs, fd⟩ := campaign_facts w v
    have r1 : Reachable (campaign w v) :=
      Reachable.step reach (Step.timeout w v (hw ▸ member) (not_leader a sound.good notLeader) (idle_abs a idle))
    refine ⟨_, forget_step r1 v kept sub, sim.put v n' fv (fun u hu => ?_) (fun _ h => fs ▸ h)
      (fun _ => sound.campaigned idle ho camp) (fun _ => by simpa [fd] using a') (by simp [fd])⟩
    simp only [set_other _ _ _ _ hu]
    exact fo u hu

/-- Messages handed to the network that the model sent. -/
theorem Sim.extend {ids : List Nat} {C : Cluster} {w : World} (sim : Sim ids C w) (xs : List PureValue)
    (ok : ∀ src dst m, envelopev src dst m ∈ xs → ∀ e, m.election = some e → ⟨src, dst, e⟩ ∈ w.sent) :
    Sim ids { C with net := C.net ++ xs } w where
  voters := sim.voters
  node := sim.node
  disk := sim.disk
  net := by
    intro src dst m h e he
    rcases List.mem_append.mp h with h | h
    · exact sim.net src dst m h e he
    · exact ok src dst m h e he

/-- Saving a node's checkpoint as the model's durable state. -/
theorem Sim.save {ids : List Nat} {C : Cluster} {w : World} (sim : Sim ids C w) (v : Nat) (d : PureValue)
    (hd : ∃ c sn en ln,
      d = statev (hardv (w.nodes v).durable.term (voteValue (w.nodes v).durable.vote) c) sn en ln) :
    Sim ids { C with disks := fun y => if y = v then d else C.disks y } w where
  voters := sim.voters
  node := sim.node
  disk := by
    intro u hu
    by_cases same : u = v
    · subst same; simpa using hd
    · simpa [same] using sim.disk u hu
  net := sim.net

/-- Changing one node and its saved checkpoint as the model changes that node. -/
theorem Sim.update {ids : List Nat} {C : Cluster} {w w' : World} (sim : Sim ids C w) (v : Nat) (n : Fields)
    (d : PureValue) (voters : w'.voters = w.voters) (others : ∀ u, u ≠ v → w'.nodes u = w.nodes u)
    (sent : ∀ e ∈ w.sent, e ∈ w'.sent) (sound : v ∈ ids → Sound ids v n)
    (abs : v ∈ ids → Abs ids n (w'.nodes v).durable (w'.nodes v))
    (disk : ∃ c sn en ln,
      d = statev (hardv (w'.nodes v).durable.term (voteValue (w'.nodes v).durable.vote) c) sn en ln) :
    Sim ids { C.put v n.value with disks := fun y => if y = v then d else C.disks y } w' where
  voters := voters.trans sim.voters
  node := by
    intro u hu
    by_cases same : u = v
    · subst same
      exact ⟨n, by simp [Cluster.put], sound hu, abs hu⟩
    · obtain ⟨n0, h0, s0, a0⟩ := sim.node u hu
      exact ⟨n0, by simp [Cluster.put, same, h0], s0, by rw [others u same]; exact a0⟩
  disk := by
    intro u hu
    by_cases same : u = v
    · subst same; simpa using disk
    · simp only [same, if_false]; rw [others u same]; exact sim.disk u hu
  net := fun src dst m h e he => sent _ (sim.net src dst m h e he)

theorem handed_mem {out : PureValue} {x : PureValue} (h : x ∈ handed out) : out = .present x := by
  cases out <;> simp [handed] at h; exact congrArg _ h.symm

open Jarl.ElectionSafety in
theorem sim_send (target : Target) {ids : List Nat} (cap : PureValue) {C : Cluster} {w : World}
    (sim : Sim ids C w) (reach : Reachable w) {v : Nat} (member : v ∈ ids) {fuel : Nat} {out r : PureValue}
    (run : Jarl.node_Node_next_message target fuel (C.nodes v) [.number "usize" ids.length, cap] =
      .ok (out, r)) :
    ∃ w', Reachable w' ∧ Sim ids { C.put v r with net := C.net ++ handed out } w' := by
  obtain ⟨n, hn, sound, a⟩ := sim.node v member
  obtain ⟨c, sn, en, ln, hs⟩ := a.state
  rw [hn] at run
  rcases next_spec target n ids v sound.good _ _ _ _ _ _ hs sound.boxed cap run with
    ⟨rfl, rfl⟩ | ⟨os, p, o, to, ho, hd, hj, hnot, hto, rfl, sends⟩
  · refine ⟨w, reach, ?_⟩
    have s1 : Sim ids (C.put v n.value) w :=
      sim.put v n rfl (fun _ _ => rfl) (fun _ h => h) (fun _ => sound) (fun _ => a) rfl
    have s2 := s1.extend [] (fun _ _ _ h => by simp at h)
    simpa [handed, Cluster.put] using s2
  · obtain ⟨clean, a', hL⟩ := a.next ho hd hj hnot hto
    have s' := sound.clear ho p
    obtain ⟨ht, -⟩ := a.term_of hs
    cases hP : pendingOf to (.present o) with
    | none =>
      simp only [hP, Option.toList_none, List.nil_append] at hL
      have sub : (outboxOf ids (os.set p .absent)).Sublist (w.nodes v).outbox := by
        rw [hL]; exact List.Sublist.refl _
      have r1 := forget_step reach v _ sub
      refine ⟨_, r1, ?_⟩
      have s1 := sim.put
        (w' := { w with nodes := set w.nodes v ({ w.nodes v with outbox := outboxOf ids (os.set p .absent) }) })
        v _ rfl (set_others _ _ _) (fun _ h => h) (fun _ => s')
        (fun _ => by simpa using a') (by simp)
      refine s1.extend _ ?_
      intro src dst m hm e he
      obtain ⟨P, hP', -⟩ := sends src dst m (handed_mem hm) e he
      rw [hP] at hP'; cases hP'
    | some P =>
      simp only [hP, Option.toList_some, List.singleton_append] at hL
      have r1 := Reachable.step reach (Step.materialize w v P _ clean hL)
      refine ⟨_, r1, ?_⟩
      have s1 := sim.put (w' := materialize w v P (outboxOf ids (os.set p .absent))) v _ rfl
        (set_others _ _ _) (fun _ h => List.mem_append_left _ h) (fun _ => s')
        (fun _ => by simpa [materialize] using a') (by simp [materialize])
      refine s1.extend _ ?_
      intro src dst m hm e he
      obtain ⟨P', hP', env⟩ := sends src dst m (handed_mem hm) e he
      rw [hP] at hP'; cases hP'
      simp only [materialize, List.mem_append, List.mem_singleton]
      exact Or.inr (by rw [← env, ht])

open Jarl.ElectionSafety in
/-- `Ready::persisted` is the model's `persist` of a dirty node, and changes
    nothing in the model for a clean one. -/
theorem sim_persist (target : Target) {ids : List Nat} {C : Cluster} {w : World}
    (sim : Sim ids C w) (reach : Reachable w) {v : Nat} (member : v ∈ ids) (n n' : Fields)
    (hn : C.nodes v = n.value) {fuel : Nat} {out : PureValue}
    (run : Jarl.ready_Ready_persisted target fuel (readyv n) [] = .ok (out, readyv n')) :
    ∃ w', Reachable w' ∧
      Sim ids { C.put v n'.value with disks := fun y => if y = v then n.state else C.disks y } w' := by
  obtain ⟨n0, hn0, sound, a⟩ := sim.node v member
  rw [hn] at hn0
  cases Fields.value_inj _ _ hn0
  have h' := persisted_spec target n run
  simp only [readyv, PureValue.record.injEq, List.cons.injEq, Prod.mk.injEq, true_and, and_true] at h'
  cases Fields.value_inj _ _ h'
  obtain ⟨c, sn, en, ln, hs⟩ := a.state
  have s' := sound.persisted
  cases hdirty : (w.nodes v).dirty with
  | true =>
    have r1 := Reachable.step reach (Step.persist w v hdirty)
    refine ⟨_, r1, ?_⟩
    have a' : Abs ids { n with dirty := .boolean false, log_from := .absent, snapshot_changed := .boolean false }
        ((persist w v).nodes v).durable ((persist w v).nodes v) :=
      { state := by simp only [persist, set_self]; exact ⟨c, sn, en, ln, hs⟩
        role := by simp only [persist, set_self]; exact a.role
        votes := by simp only [persist, set_self]; exact a.votes
        dirty := by simp [persist]
        durable := rfl
        outbox := by simp only [persist, set_self]; exact a.outbox
        prevoting := by simp only [persist, set_self]; exact a.prevoting }
    exact sim.update (w' := persist w v) v _ n.state rfl (set_others _ _ _) (fun _ h => h) (fun _ => s')
      (fun _ => a') ⟨c, sn, en, ln, by simp [persist, hs]⟩
  | false =>
    obtain ⟨ht, hv⟩ := (reachable_inv reach).clean v hdirty
    have a' : Abs ids { n with dirty := .boolean false, log_from := .absent, snapshot_changed := .boolean false }
        (w.nodes v).durable (w.nodes v) :=
      { state := ⟨c, sn, en, ln, hs⟩, role := a.role, votes := a.votes, dirty := fun _ => hdirty,
        durable := rfl, outbox := a.outbox, prevoting := a.prevoting }
    refine ⟨w, reach, sim.update (w' := w) v _ n.state rfl (fun _ _ => rfl) (fun _ h => h) (fun _ => s')
      (fun _ => a') ⟨c, sn, en, ln, ?_⟩⟩
    rw [hs, ← ht, ← hv]

open Jarl.ElectionSafety in
/-- Restarting from the saved checkpoint is the model's `crash`. -/
theorem sim_restart (target : Target) {ids : List Nat} (cap : PureValue) {C : Cluster} {w : World}
    (sim : Sim ids C w) (reach : Reachable w) {v : Nat} (member : v ∈ ids) (n : Fields)
    (hn : C.nodes v = n.value) (self : PureValue) {fuel : Nat} {r x : PureValue}
    (run : Jarl.node_Node_build target fuel self [n.config, C.disks v, membershipv ids, .absent,
      .number "usize" ids.length, cap] = .ok (.variant "Result" "Ok" [("0", x)], r)) :
    ∃ w', Reachable w' ∧ Sim ids (C.put v x) w' := by
  obtain ⟨n0, hn0, sound, -⟩ := sim.node v member
  rw [hn] at hn0
  cases Fields.value_inj _ _ hn0
  obtain ⟨c, sn, en, ln, hd⟩ := sim.disk v member
  rw [hd] at run
  have fixed := sound.good.fixed
  obtain ⟨n2, rfl, good2, hs2, hr2, hv2, ho2, -⟩ :=
    build_spec target ids v fixed.unique fixed.member n.config fixed.self _ _ _ _ _ _ cap self run x rfl
  have r1 := Reachable.step reach (Step.crash w v)
  refine ⟨_, r1, sim.put (w' := crash w v) v n2 rfl (set_others _ _ _) (fun _ h => h)
    (fun _ => Sound.built good2 ho2) (fun _ => ?_) (by simp [crash])⟩
  simp only [crash, set_self]
  exact Abs.built ids hs2 hr2 hv2 ho2

/-! ### Delivery -/

open Jarl.ElectionSafety in
theorem set_set (nodes : Nat → Local) (v : Nat) (a b : Local) : set (set nodes v a) v b = set nodes v b := by
  funext x; simp only [Jarl.ElectionSafety.set]; split <;> rfl

open Jarl.ElectionSafety in
theorem set_same (nodes : Nat → Local) (v : Nat) : set nodes v (nodes v) = nodes := by
  funext x; simp only [Jarl.ElectionSafety.set]; split <;> simp_all

open Jarl.ElectionSafety in
theorem adopt_durable (s : Local) (T : Nat) : (adopt s T).durable = s.durable := by
  unfold adopt stepDown; split <;> rfl

open Jarl.ElectionSafety in
/-- Adopting a term is the model's `observe` when it is higher, and no step otherwise. -/
theorem adopt_reach {w : World} (reach : Reachable w) (v T : Nat) (ready : Jarl.ElectionSafety.Idle (w.nodes v)) :
    Reachable { w with nodes := set w.nodes v (adopt (w.nodes v) T) } := by
  by_cases h : (w.nodes v).term < T
  · have := Reachable.step reach (Step.observe w v T h ready)
    simpa [adopt, h] using this
  · have e : adopt (w.nodes v) T = w.nodes v := by simp [adopt, h]
    rw [e, set_same]
    exact reach

open Jarl.ElectionSafety in
theorem handleVoted_facts (w : World) (v c t : Nat) (g : Bool) :
    (handleVoted w v c t g).voters = w.voters ∧
      (∀ u, u ≠ v → (handleVoted w v c t g).nodes u = w.nodes u) ∧
      (handleVoted w v c t g).sent = w.sent ∧
      ((handleVoted w v c t g).nodes v).durable = (w.nodes v).durable := by
  unfold handleVoted
  dsimp only
  repeat' split
  all_goals exact ⟨rfl, set_others _ _ _, rfl, by simp [adopt_durable]⟩

open Jarl.ElectionSafety in
theorem handlePreVoted_quiet (w : World) (v c T camp : Nat) (g : Bool) (h : (w.nodes v).prevoting = none) :
    handlePreVoted w v c T camp g = { w with nodes := set w.nodes v (adopt (w.nodes v) T) } := by
  have quiet : (adopt (w.nodes v) T).prevoting = none := by
    unfold adopt stepDown; split
    · rfl
    · exact h
  unfold handlePreVoted
  simp [quiet]

open Jarl.ElectionSafety in
/-- A model step at node `v` followed by dropping some of its pending messages. -/
theorem Sim.after {ids : List Nat} {C : Cluster} {w w1 : World} (sim : Sim ids C w) (r1 : Reachable w1)
    (v : Nat) (fv : w1.voters = w.voters) (fo : ∀ u, u ≠ v → w1.nodes u = w.nodes u)
    (fs : ∀ e ∈ w.sent, e ∈ w1.sent) (fd : (w1.nodes v).durable = (w.nodes v).durable)
    (kept : List Pending) (sub : kept.Sublist (w1.nodes v).outbox) (n' : Fields) (sound : v ∈ ids → Sound ids v n')
    (abs : Abs ids n' (w.nodes v).durable { w1.nodes v with outbox := kept }) :
    ∃ w', Reachable w' ∧ Sim ids (C.put v n'.value) w' :=
  ⟨_, forget_step r1 v kept sub, sim.put v n' fv (fun u hu => by simp [set_other _ _ _ _ hu, fo u hu])
    (fun e h => fs e h) sound (fun _ => by simpa [fd] using abs) (by simp [fd])⟩

open Jarl.ElectionSafety in
theorem sim_deliver (target : Target) {ids : List Nat} (cap : PureValue) {C : Cluster} {w : World}
    (sim : Sim ids C w) (reach : Reachable w) {v : Nat} (member : v ∈ ids) (src dst : Nat) (m : Msg)
    (carried : envelopev src dst m ∈ C.net ∨ m.election = none) {fuel : Nat} {out r : PureValue}
    (run : Jarl.node_Node_step target fuel (C.nodes v)
      [envelopev src dst m, .number "usize" ids.length, cap] = .ok (out, r)) :
    ∃ w', Reachable w' ∧ Sim ids (C.put v r) w' := by
  obtain ⟨n, hn, sound, a⟩ := sim.node v member
  obtain ⟨c, sn, en, ln, hs⟩ := a.state
  rw [hn] at run
  have hvf : voteValue (w.nodes v).vote = .absent ∨ ∃ x, voteValue (w.nodes v).vote = .present (idv x) := by
    cases (w.nodes v).vote with
    | none => exact Or.inl rfl
    | some x => exact Or.inr ⟨x, rfl⟩
  obtain ⟨n', rfl, calm | ⟨idle, hsrc, hne, hdst, os, bs, ho, hv, out⟩⟩ :=
    step_spec target n ids v sound.good _ _ _ _ _ _ hs hvf src dst m cap run
  · obtain ⟨kept, sub, a'⟩ := a.calm calm
    exact sim.after (w1 := w) reach v rfl (fun _ _ => rfl) (fun _ h => h) rfl kept sub n'
      (fun _ => sound.calm calm) a'
  have sound' := sound.stepOut idle ho hv out
  have ready := idle_abs a idle
  subst hdst
  have delivered : ∀ e, m.election = some e → ⟨src, dst, e⟩ ∈ w.sent := by
    intro e he
    rcases carried with h | h
    · exact sim.net _ _ _ h e he
    · rw [h] at he; cases he
  cases m with
  | prevote T last =>
    obtain ⟨g, kept, sub, a'⟩ := a.prevote sound.good idle ho hsrc out
    have r1 := Reachable.step reach (Step.answerProbe w dst src T g (delivered _ rfl) hne ready)
    exact sim.after r1 dst rfl (set_others _ _ _) (fun _ h => h) (by simp) kept (by simpa using sub) n'
      (fun _ => sound') (by simpa using a')
  | prevoted T camp g =>
    obtain ⟨kept, sub, a'⟩ := a.adopt_calm hs out
    have r1 := Reachable.step reach (Step.preVoteReply w dst src T camp g (delivered _ rfl) hne ready)
    rw [handlePreVoted_quiet w dst src T camp g a.prevoting] at r1
    exact sim.after r1 dst rfl (set_others _ _ _) (fun _ h => h) (by simp [adopt_durable]) kept
      (by simpa using sub) n' (fun _ => sound') (by simpa using a')
  | vote T last =>
    obtain ⟨logOk, kept, sub, a'⟩ := a.vote sound.good idle hs ho hsrc out
    have r1 := Reachable.step reach (Step.requestVote w dst src T logOk (delivered _ rfl) hne ready)
    refine sim.after r1 dst rfl (set_others _ _ _) (fun _ h => h) ?_ kept (by simpa using sub) n'
      (fun _ => sound') (by simpa using a')
    simp only [set_self]
    unfold handleVote
    dsimp only
    repeat' split
    all_goals simp [adopt_durable]
  | voted T g =>
    obtain ⟨kept, sub, a'⟩ := a.voted sound.good sim.voters hs hv hsrc out
    have r1 := Reachable.step reach (Step.voteReply w dst src T g (delivered _ rfl) hne ready)
    obtain ⟨fv, fo, fs, fd⟩ := handleVoted_facts w dst src T g
    exact sim.after r1 dst fv fo (fun _ h => fs ▸ h) fd kept sub n' (fun _ => sound') a'
  | append T _ _ _ | batch T _ _ _ | install T _ =>
    rcases a.follow hs out with ⟨-, kept, sub, a'⟩ | ⟨-, kept, sub, a'⟩
    · exact sim.after (w1 := w) reach dst rfl (fun _ _ => rfl) (fun _ h => h) rfl kept sub n'
        (fun _ => sound') a'
    · have r1 := adopt_reach reach dst T ready
      have r2 := Reachable.step r1 (Step.demote _ dst)
      refine sim.after r2 dst rfl (fun u hu => by simp [set_other _ _ _ _ hu]) (fun _ h => h)
        (by simp [demote, adopt_durable]) kept (by simpa using sub) n' (fun _ => sound') (by simpa using a')
  | replicated T _ _ =>
    obtain ⟨kept, sub, a'⟩ := a.adopt_calm hs out
    have r1 := adopt_reach reach dst T ready
    exact sim.after r1 dst rfl (set_others _ _ _) (fun _ h => h) (by simp [adopt_durable]) kept
      (by simpa using sub) n' (fun _ => sound') (by simpa using a')

/-! ## The implementation's election safety -/

theorem sim_act (target : Target) {ids : List Nat} (cap : PureValue) {C C' : Cluster} {w : World}
    (sim : Sim ids C w) (reach : Reachable w) (act : Act (jarl Jarl.node_Node_tick Jarl.node_Node_step Jarl.node_Node_next_message Jarl.ready_Ready_persisted Jarl.node_Node_build) target ids cap C C') :
    ∃ w', Reachable w' ∧ Sim ids C' w' := by
  cases act with
  | tick v member run => exact sim_tick target cap sim reach member run
  | deliver v member src dst m carried run => exact sim_deliver target cap sim reach member src dst m carried run
  | send v member run => exact sim_send target cap sim reach member run
  | persist v member n n' hn run => exact sim_persist target sim reach member n n' hn run
  | restart v member n hn self run => exact sim_restart target cap sim reach member n hn self run

open Jarl.ElectionSafety in
theorem sim_initial (target : Target) {ids : List Nat} (cap : PureValue) (unique : ids.Nodup) {C : Cluster}
    (init : Initial (jarl Jarl.node_Node_tick Jarl.node_Node_step Jarl.node_Node_next_message Jarl.ready_Ready_persisted Jarl.node_Node_build) target ids cap C) : Sim ids C (initial ids) where
  voters := rfl
  node := by
    intro v hv
    obtain ⟨config, c, sn, en, ln, self, fuel, r, hself, hd, run⟩ := init.nodes v hv
    rw [hd] at run
    obtain ⟨n, hn, good, hs, hr, hvotes, ho, -⟩ :=
      build_spec target ids v unique hv config hself 0 .absent c sn en ln cap self run _ rfl
    exact ⟨n, hn, Sound.built good ho, Abs.built (vote := none) ids hs hr hvotes ho⟩
  disk := by
    intro v hv
    obtain ⟨config, c, sn, en, ln, self, fuel, r, hself, hd, run⟩ := init.nodes v hv
    exact ⟨c, sn, en, ln, hd⟩
  net := by intro src dst m h; rw [init.net] at h; cases h

/-- Every run of the cluster is simulated by a reachable world of the model. -/
theorem runs_sim (target : Target) {ids : List Nat} (cap : PureValue) (unique : ids.Nodup) {C : Cluster}
    (runs : Runs (jarl Jarl.node_Node_tick Jarl.node_Node_step Jarl.node_Node_next_message Jarl.ready_Ready_persisted Jarl.node_Node_build) target ids cap C) : ∃ w, Reachable w ∧ Sim ids C w := by
  induction runs with
  | start C init => exact ⟨_, Reachable.initial ids unique, sim_initial target cap unique init⟩
  | act _ act ih =>
    obtain ⟨w, reach, sim⟩ := ih
    exact sim_act target cap sim reach act

/-- **Election safety of `Node`**: in every run of a stable cluster, two nodes
    that are both leader in the same term are the same node. -/
theorem node_election_safety (target : Target) {ids : List Nat} (cap : PureValue) (unique : ids.Nodup)
    {C : Cluster} (runs : Runs (jarl Jarl.node_Node_tick Jarl.node_Node_step Jarl.node_Node_next_message Jarl.ready_Ready_persisted Jarl.node_Node_build) target ids cap C) {a b : Nat} (ha : a ∈ ids) (hb : b ∈ ids)
    {na nb : Fields} (hna : C.nodes a = na.value) (hnb : C.nodes b = nb.value)
    (la : na.role = leaderv) (lb : nb.role = leaderv) {t : Nat}
    {vfa ca sna ena lna vfb cb snb enb lnb : PureValue}
    (ta : na.state = statev (hardv t vfa ca) sna ena lna) (tb : nb.state = statev (hardv t vfb cb) snb enb lnb) :
    a = b := by
  obtain ⟨w, reach, sim⟩ := runs_sim target cap unique runs
  obtain ⟨na', hna', -, aa⟩ := sim.node a ha
  obtain ⟨nb', hnb', -, ab⟩ := sim.node b hb
  rw [hna] at hna'; cases Fields.value_inj _ _ hna'
  rw [hnb] at hnb'; cases Fields.value_inj _ _ hnb'
  have ra : (w.nodes a).role = .leader := by rw [← aa.role, la]; rfl
  have rb : (w.nodes b).role = .leader := by rw [← ab.role, lb]; rfl
  have t1 := (aa.term_of ta).1
  have t2 := (ab.term_of tb).1
  exact Jarl.ElectionSafety.one_leader reach a b ra rb (t1.symm.trans t2)

end Refine
