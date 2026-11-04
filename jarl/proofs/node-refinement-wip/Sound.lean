import NextMessage
import Build
import Persist
open Provium.State Provium.Imperative
set_option linter.unusedSimpArgs false
namespace Refine

/-! What every node of a running cluster keeps: `Good`, with outbox
    descriptors of the shapes `Node` writes. -/

/-- Every occupied outbox slot holds a well-formed descriptor. -/
def Boxed (n : Fields) : Prop := ∀ os, n.outbox = .array os → ∀ o, .present o ∈ os → Formed o

structure Sound (ids : List Nat) (me : Nat) (n : Fields) : Prop where
  good : Good ids me n
  boxed : Boxed n

theorem Good.change {ids : List Nat} {me : Nat} {n n' : Fields} (g : Good ids me n)
    (config : n'.config = n.config) (slot : n'.local = n.local) (membership : n'.membership = n.membership)
    (bootstrap : n'.bootstrap = n.bootstrap) (hooks : n'.hooks = n.hooks) (peers : n'.peers = n.peers)
    (votes : ∃ bs, n'.votes = boolsv bs ∧ bs.length = ids.length)
    (outbox : ∃ os, n'.outbox = .array os ∧ os.length = ids.length ∧
      ∀ o ∈ os, o = .absent ∨ ∃ y, o = .present y)
    (dirty : ∃ b, n'.dirty = .boolean b) (extra : n'.extra_reply = .absent)
    (role : n'.role = followerv ∨ n'.role = candidatev ∨ n'.role = leaderv)
    (prevoting : n'.prevoting = .absent) : Good ids me n' where
  fixed :=
    { unique := g.fixed.unique, member := g.fixed.member,
      membership := membership.trans g.fixed.membership, bootstrap := bootstrap.trans g.fixed.bootstrap,
      hooks := hooks.trans g.fixed.hooks, peers := peers.trans g.fixed.peers,
      self := by rw [config]; exact g.fixed.self, slot := slot.trans g.fixed.slot }
  votes := votes
  outbox := outbox
  dirty := dirty
  extra := extra
  role := role
  prevoting := prevoting

theorem quiet_formed {v : PureValue} (q : Quiet v) : ∃ o, v = .present o ∧ Formed o := by
  rcases q with rfl | ⟨i, j, rfl⟩
  · exact ⟨_, rfl, Or.inr (Or.inr (Or.inr (Or.inr (Or.inl rfl))))⟩
  · exact ⟨_, rfl, Or.inr (Or.inr (Or.inr (Or.inr (Or.inr ⟨i, j, rfl⟩))))⟩

theorem Boxed.calm {n n' : Fields} (b : Boxed n) (good : Good ids me n) (c : Calm n n') : Boxed n' := by
  intro os' ho' o hmem
  obtain ⟨os, ho, -, -⟩ := good.outbox
  obtain ⟨os2, ho2, set⟩ := c.outbox os ho
  rw [ho'] at ho2
  cases ho2
  obtain ⟨i, hi, he⟩ := List.getElem_of_mem hmem
  rcases set.2 i (by rw [← set.1]; exact hi) with e | ⟨v, e, q⟩
  · rw [List.getElem?_eq_getElem hi, he] at e
    exact b os ho o (List.mem_of_getElem? e.symm)
  · rw [List.getElem?_eq_getElem hi, he] at e
    cases e
    obtain ⟨o', ho', f⟩ := quiet_formed q
    cases ho'
    exact f

theorem Sound.calm {ids : List Nat} {me : Nat} {n n' : Fields} (s : Sound ids me n) (c : Calm n n') :
    Sound ids me n' := ⟨s.good.calm c, s.boxed.calm s.good c⟩

/-- An outbox of empty slots but one, which holds a well-formed descriptor. -/
theorem boxed_single {os : List PureValue} (empty : ∀ o ∈ os, o = .absent) (k : Nat) {x : PureValue}
    (fx : ∀ o, x = .present o → Formed o) :
    ∀ o, .present o ∈ os.set k x → Formed o := by
  intro o hmem
  rcases List.mem_or_eq_of_mem_set hmem with h | h
  · cases empty _ h
  · exact fx o h.symm

theorem slots_single {os : List PureValue} (empty : ∀ o ∈ os, o = .absent) (k : Nat) {y : PureValue} :
    ∀ o ∈ os.set k (.present y), o = .absent ∨ ∃ z, o = .present z := by
  intro o hmem
  rcases List.mem_or_eq_of_mem_set hmem with h | h
  · exact Or.inl (empty _ h)
  · exact Or.inr ⟨y, h⟩

/-- An idle node with one descriptor queued. -/
theorem Sound.single {ids : List Nat} {me : Nat} {n : Fields} (s : Sound ids me n) {os : List PureValue}
    (ho : n.outbox = .array os) (empty : ∀ o ∈ os, o = .absent) (k : Nat) (y : PureValue) (fy : Formed y) :
    Sound ids me { n with outbox := .array (os.set k (.present y)) } where
  good := s.good.change rfl rfl rfl rfl rfl rfl s.good.votes
    (by
      obtain ⟨os', ho', sized, -⟩ := s.good.outbox
      rw [ho] at ho'; cases ho'
      exact ⟨_, rfl, by simp [sized], slots_single empty k⟩)
    s.good.dirty s.good.extra s.good.role s.good.prevoting
  boxed := by
    intro os' ho' o hmem
    cases ho'
    exact boxed_single empty k (fun o h => by cases h; exact fy) o hmem

theorem Sound.adopt {ids : List Nat} {me : Nat} {n : Fields} (s : Sound ids me n) (t T : Nat)
    (c sn en ln : PureValue) : Sound ids me (adoptF n t T c sn en ln) := by
  unfold adoptF
  split
  · exact ⟨s.good.change rfl rfl rfl rfl rfl rfl s.good.votes s.good.outbox ⟨true, rfl⟩ s.good.extra
      (Or.inl rfl) rfl, s.boxed⟩
  · exact s

theorem Sound.demote {ids : List Nat} {me : Nat} {n : Fields} (s : Sound ids me n) (src : Nat) :
    Sound ids me (demoteF n src) :=
  ⟨s.good.change rfl rfl rfl rfl rfl rfl s.good.votes s.good.outbox s.good.dirty s.good.extra
    (Or.inl rfl) rfl, s.boxed⟩

theorem Sound.hard {ids : List Nat} {me : Nat} {n : Fields} (s : Sound ids me n) (st d : PureValue)
    (hd : ∃ b, d = .boolean b) : Sound ids me { n with state := st, dirty := d } :=
  ⟨s.good.change rfl rfl rfl rfl rfl rfl s.good.votes s.good.outbox hd s.good.extra s.good.role
    s.good.prevoting, s.boxed⟩

theorem Sound.tally {ids : List Nat} {me : Nat} {n : Fields} (s : Sound ids me n) {bs : List Bool}
    (hv : n.votes = boolsv bs) (k : Nat) (r : PureValue)
    (hr : r = followerv ∨ r = candidatev ∨ r = leaderv) :
    Sound ids me { n with votes := boolsv (bs.set k true), role := r } :=
  ⟨s.good.change rfl rfl rfl rfl rfl rfl
    (by
      obtain ⟨bs', hv', sized⟩ := s.good.votes
      rw [hv] at hv'; cases boolsv_inj hv'
      exact ⟨_, rfl, by simp [sized]⟩)
    s.good.outbox s.good.dirty s.good.extra hr s.good.prevoting, s.boxed⟩

theorem adoptF_outbox (n : Fields) (t T : Nat) (c sn en ln : PureValue) :
    (adoptF n t T c sn en ln).outbox = n.outbox := by
  unfold adoptF; split <;> rfl

theorem adoptF_votes (n : Fields) (t T : Nat) (c sn en ln : PureValue) :
    (adoptF n t T c sn en ln).votes = n.votes := by
  unfold adoptF; split <;> rfl

theorem adoptF_role (n : Fields) (t T : Nat) (c sn en ln : PureValue) :
    (adoptF n t T c sn en ln).role = n.role ∨ (adoptF n t T c sn en ln).role = followerv := by
  unfold adoptF; split
  · exact Or.inr rfl
  · exact Or.inl rfl

theorem formed_prevoted (T : Nat) (g : Bool) : ∀ o, prevotedv T g = .present o → Formed o := by
  intro o h; cases h; exact Or.inr (Or.inr (Or.inr (Or.inl ⟨T, g, rfl⟩)))

theorem formed_voted (g : Bool) : ∀ o, votedv g = .present o → Formed o := by
  intro o h; cases h; exact Or.inr (Or.inl ⟨g, rfl⟩)

theorem dirty_ite (p : Prop) (inst : Decidable p) {a : PureValue} (h : ∃ b, a = .boolean b) :
    ∃ b, @ite _ p inst a (.boolean true) = .boolean b := by
  by_cases hp : p
  · rw [if_pos hp]; exact h
  · rw [if_neg hp]; exact ⟨true, rfl⟩

/-- The result of `step` on an idle node keeps it sound. -/
theorem Sound.stepOut {ids : List Nat} {me : Nat} {n n' : Fields} (s : Sound ids me n) (idle : Idle n)
    {t : Nat} {vf c sn en ln : PureValue} {os : List PureValue} {bs : List Bool} {src : Nat} {m : Msg}
    (ho : n.outbox = .array os) (hv : n.votes = boolsv bs)
    (out : StepOut ids n t vf c sn en ln os bs src m n') : Sound ids me n' := by
  obtain ⟨-, -, os0, ho0, empty⟩ := idle
  rw [ho] at ho0; cases ho0
  cases m with
  | prevote T last =>
    obtain ⟨g, calm⟩ := out
    exact (s.single ho empty _ _ (formed_prevoted T g _ rfl)).calm calm
  | prevoted T camp g => exact (s.adopt t T c sn en ln).calm out
  | vote T last =>
    simp only [StepOut] at out
    split at out
    · exact (s.single ho empty _ _ (formed_voted false _ rfl)).calm out
    · obtain ⟨g, -, calm⟩ := out
      have s1 := s.adopt t T c sn en ln
      have ho1 : (adoptF n t T c sn en ln).outbox = .array os := (adoptF_outbox _ _ _ _ _ _ _).trans ho
      cases g
      · simp only [↓reduceIte, Bool.false_eq_true] at calm
        exact (s1.single ho1 empty _ _ (formed_voted false _ rfl)).calm calm
      · simp only [↓reduceIte] at calm
        have s2 := s1.single ho1 empty (ids.idxOf src) _ (formed_voted true _ rfl)
        refine Sound.calm ?_ calm
        refine ⟨s2.good.change rfl rfl rfl rfl rfl rfl s2.good.votes s2.good.outbox ?_ s2.good.extra
          s2.good.role s2.good.prevoting, s2.boxed⟩
        exact dirty_ite _ _ s1.good.dirty
  | voted T g =>
    simp only [StepOut] at out
    have s1 := s.adopt t T c sn en ln
    have hv1 : (adoptF n t T c sn en ln).votes = boolsv bs := (adoptF_votes _ _ _ _ _ _ _).trans hv
    split at out
    · rename_i cond
      rcases out with ⟨-, calm⟩ | ⟨-, calm⟩
      · exact (s1.tally hv1 _ leaderv (Or.inr (Or.inr rfl))).calm calm
      · exact (s1.tally hv1 _ _ (Or.inr (Or.inl cond.2.1))).calm calm
    · exact s1.calm out
  | append T _ _ _ | batch T _ _ _ | install T _ =>
    simp only [StepOut] at out
    split at out
    · exact s.calm out
    · exact ((s.adopt t T c sn en ln).demote src).calm out
  | replicated T _ _ => exact (s.adopt t T c sn en ln).calm out

theorem selfVotes_length (N lo : Nat) : (selfVotes N lo).length = N := by simp [selfVotes]

/-- A campaign keeps an idle node sound. -/
theorem Sound.campaigned {ids : List Nat} {me : Nat} {n n' : Fields} (s : Sound ids me n) (idle : Idle n)
    {term : Nat} {c sn en ln : PureValue} {os : List PureValue} (ho : n.outbox = .array os)
    (camp : Campaigned ids me n term c sn en ln os n') : Sound ids me n' := by
  obtain ⟨-, -, os0, ho0, empty⟩ := idle
  rw [ho] at ho0; cases ho0
  have sized : os.length = ids.length := by
    obtain ⟨os', ho', sized, -⟩ := s.good.outbox; rw [ho] at ho'; cases ho'; exact sized
  have sb : Sound ids me (campaignBase n term me c sn en ln ids.length (ids.idxOf me)) :=
    ⟨s.good.change rfl rfl rfl rfl rfl rfl ⟨_, rfl, selfVotes_length _ _⟩ s.good.outbox ⟨true, rfl⟩
      s.good.extra (Or.inr (Or.inl rfl)) rfl, s.boxed⟩
  rcases camp with ⟨-, calm⟩ | ⟨-, calm⟩
  · refine Sound.calm ?_ calm
    exact ⟨sb.good.change rfl rfl rfl rfl rfl rfl sb.good.votes sb.good.outbox sb.good.dirty
      sb.good.extra (Or.inr (Or.inr rfl)) sb.good.prevoting, sb.boxed⟩
  · refine Sound.calm ?_ calm
    refine ⟨sb.good.change rfl rfl rfl rfl rfl rfl sb.good.votes
      ⟨_, rfl, by simp [voteBox, sized], fun o hmem => ?_⟩ sb.good.dirty sb.good.extra sb.good.role
      sb.good.prevoting, ?_⟩
    · obtain ⟨i, hi, rfl⟩ := List.getElem_of_mem hmem
      simp only [voteBox, List.getElem_mapIdx]
      split
      · exact Or.inl (empty _ (List.getElem_mem _))
      · exact Or.inr ⟨_, rfl⟩
    · intro os' ho' o hmem
      cases ho'
      obtain ⟨i, hi, he⟩ := List.getElem_of_mem hmem
      simp only [voteBox, List.getElem_mapIdx] at he
      split at he
      · cases (empty _ (List.getElem_mem _)).symm.trans he
      · cases he; exact Or.inl rfl

/-- Clearing a slot keeps a node sound. -/
theorem Sound.clear {ids : List Nat} {me : Nat} {n : Fields} (s : Sound ids me n) {os : List PureValue}
    (ho : n.outbox = .array os) (p : Nat) : Sound ids me { n with outbox := .array (os.set p .absent) } where
  good := s.good.change rfl rfl rfl rfl rfl rfl s.good.votes
    (by
      obtain ⟨os', ho', sized, hos⟩ := s.good.outbox
      rw [ho] at ho'; cases ho'
      refine ⟨_, rfl, by simp [sized], fun o hmem => ?_⟩
      rcases List.mem_or_eq_of_mem_set hmem with h | h
      · exact hos o h
      · exact Or.inl h)
    s.good.dirty s.good.extra s.good.role s.good.prevoting
  boxed := by
    intro os' ho' o hmem
    cases ho'
    rcases List.mem_or_eq_of_mem_set hmem with h | h
    · exact s.boxed os ho o h
    · cases h

/-- Persisting keeps a node sound. -/
theorem Sound.persisted {ids : List Nat} {me : Nat} {n : Fields} (s : Sound ids me n) :
    Sound ids me { n with dirty := .boolean false, log_from := .absent, snapshot_changed := .boolean false } :=
  ⟨s.good.change rfl rfl rfl rfl rfl rfl s.good.votes s.good.outbox ⟨false, rfl⟩ s.good.extra s.good.role
    s.good.prevoting, s.boxed⟩

/-- A built node is sound. -/
theorem Sound.built {ids : List Nat} {me : Nat} {n : Fields} (g : Good ids me n)
    (ho : n.outbox = .array (List.replicate ids.length .absent)) : Sound ids me n where
  good := g
  boxed := by
    intro os ho' o hmem
    rw [ho] at ho'; cases ho'
    cases List.eq_of_mem_replicate hmem

end Refine
