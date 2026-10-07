/- M2 abstract election model for both engines over a fixed voter set. It
   mirrors the election paths of jarl/src/node.rs: `tick` → `campaign` (fixed
   engine) or a pre-vote probe (dynamic engine), the `PreVote`/`PreVoted` and
   `Vote`/`Voted` arms of `step`, `Ready::persisted`, the persistence gate in
   `next_message`, the `available` input gate, and restart from the durable
   checkpoint. As in Jarl, pre-vote grants and real votes share `votes`.
   Recent-leader suppression only ignores requests, which the model already
   allows by never delivering them. It is a handwritten specification: refinement
   from the generated Rust transitions is a separate M2/M6 obligation.

   The network is honest but adversarial in scheduling: any materialized
   message may be delivered any number of times, in any order, or never.
   Ghost state records every durable ballot and every election with the vote
   set that won it; neither constrains execution. -/
namespace Jarl.ElectionSafety

abbrev Node := Nat

inductive Role where
  | follower | candidate | leader
  deriving DecidableEq

/-- Jarl's `Outbound` descriptors relevant to elections. -/
inductive Pending where
  | vote (target : Node)
  | voted (target : Node) (granted : Bool)
  | prevote (target : Node) (campaign : Nat)
  | prevoted (target : Node) (campaign : Nat) (granted : Bool)
  deriving DecidableEq

inductive Message where
  | vote (term : Nat)
  | voted (term : Nat) (granted : Bool)
  | prevote (campaign : Nat)
  | prevoted (term campaign : Nat) (granted : Bool)
  deriving DecidableEq

structure Envelope where
  source : Node
  target : Node
  message : Message
  deriving DecidableEq

structure Durable where
  term : Nat
  vote : Option Node
  deriving DecidableEq

structure Local where
  term : Nat
  vote : Option Node
  role : Role
  votes : List Node
  dirty : Bool
  durable : Durable
  outbox : List Pending
  prevoting : Option Nat

structure World where
  voters : List Node
  nodes : Node → Local
  sent : List Envelope
  ballots : List (Nat × Node × Node)
  elected : List (Nat × Node × List Node)

def fresh : Local := ⟨0, none, .follower, [], false, ⟨0, none⟩, [], none⟩

def initial (voters : List Node) : World := ⟨voters, fun _ => fresh, [], [], []⟩

/-- A strict majority of `voters` belongs to `support` (Jarl's `quorum`). -/
def Majority (voters support : List Node) : Prop :=
  voters.length / 2 < voters.countP (fun x => decide (x ∈ support))

instance (voters support : List Node) : Decidable (Majority voters support) :=
  inferInstanceAs (Decidable (_ < _))

def set (nodes : Node → Local) (v : Node) (s : Local) : Node → Local :=
  fun x => if x = v then s else nodes x

/-- `available`: no pending save and a drained outbox. -/
def Idle (s : Local) : Prop := s.dirty = false ∧ s.outbox = []

/-- Observing a higher term: `term := t`, `voted_for := None`, `follow(None)`. -/
def stepDown (s : Local) (t : Nat) : Local :=
  { s with term := t, vote := none, dirty := true, role := .follower, prevoting := none }

def adopt (s : Local) (t : Nat) : Local := if s.term < t then stepDown s t else s

/-- `campaign(term + 1)`, becoming leader at once when the self vote suffices. -/
def campaign (w : World) (v : Node) : World :=
  let s := w.nodes v
  let base : Local :=
    { s with term := s.term + 1, vote := some v, role := .candidate, votes := [v], dirty := true, prevoting := none }
  if Majority w.voters [v] then
    { w with nodes := set w.nodes v { base with role := .leader },
             elected := w.elected ++ [(s.term + 1, v, [v])] }
  else
    { w with nodes := (set w.nodes v
      { base with outbox := (w.voters.filter (· ≠ v)).map Pending.vote }) }

/-- The `Vote` arm of `step` after the higher-term check. `logOk` abstracts the
    log comparison, which election safety does not depend on. -/
def handleVote (s : Local) (c t : Nat) (logOk : Bool) : Local :=
  let s := adopt s t
  if t < s.term then { s with outbox := [.voted c false] }
  else if (s.vote = none ∨ s.vote = some c) ∧ logOk = true then
    { s with vote := some c, dirty := s.dirty || decide (s.vote ≠ some c),
             outbox := [.voted c true] }
  else { s with outbox := [.voted c false] }

/-- The `Voted` arm: only a candidate counts a current-term grant. -/
def handleVoted (w : World) (v c t : Nat) (granted : Bool) : World :=
  let s := adopt (w.nodes v) t
  if t = s.term ∧ s.role = .candidate ∧ granted = true then
    let votes := if c ∈ s.votes then s.votes else s.votes ++ [c]
    if Majority w.voters votes then
      { w with nodes := set w.nodes v { s with votes := votes, role := .leader },
               elected := w.elected ++ [(s.term, v, votes)] }
    else { w with nodes := set w.nodes v { s with votes := votes } }
  else { w with nodes := set w.nodes v s }

/-- `Ready::persisted` after a durable save of the hard state. -/
def persist (w : World) (v : Node) : World :=
  let s := w.nodes v
  { w with nodes := set w.nodes v { s with durable := ⟨s.term, s.vote⟩, dirty := false },
           ballots := match s.vote with
             | some c => w.ballots ++ [(s.term, v, c)]
             | none => w.ballots }

/-- `next_message`: only a clean node materializes, stamping its current term. -/
def envelopeOf (v term : Nat) : Pending → Envelope
  | .vote target => ⟨v, target, .vote term⟩
  | .voted target granted => ⟨v, target, .voted term granted⟩
  | .prevote target campaign => ⟨v, target, .prevote campaign⟩
  | .prevoted target campaign granted => ⟨v, target, .prevoted term campaign granted⟩

def materialize (w : World) (v : Node) (p : Pending) (rest : List Pending) : World :=
  let s := w.nodes v
  { w with nodes := set w.nodes v { s with outbox := rest },
           sent := w.sent ++ [envelopeOf v s.term p] }

/-- Losing volatile state and restarting from the durable checkpoint. -/
def crash (w : World) (v : Node) : World :=
  let s := w.nodes v
  { w with nodes := (set w.nodes v
    ⟨s.durable.term, s.durable.vote, .follower, [], false, s.durable, [], none⟩) }

/-- Dynamic-engine `tick`: probe the next term without changing durable state,
    abandoning any current campaign, unless the self vote already suffices. -/
def probe (w : World) (v : Node) : World :=
  let s := w.nodes v
  let base : Local := { s with prevoting := some (s.term + 1), votes := [v], role := .follower }
  if Majority w.voters [v] then campaign { w with nodes := set w.nodes v base } v
  else { w with nodes := (set w.nodes v
    { base with outbox := (w.voters.filter (· ≠ v)).map (fun x => Pending.prevote x (s.term + 1)) }) }

/-- The `PreVoted` arm: a grant for the active probe may start the campaign. -/
def handlePreVoted (w : World) (v c term campaign : Nat) (granted : Bool) : World :=
  let s := adopt (w.nodes v) term
  if s.prevoting = some campaign ∧ granted = true then
    let votes := if c ∈ s.votes then s.votes else s.votes ++ [c]
    let counted := { w with nodes := set w.nodes v { s with votes := votes } }
    if Majority w.voters votes then _root_.Jarl.ElectionSafety.campaign counted v else counted
  else { w with nodes := set w.nodes v s }

inductive Step : World → World → Prop where
  | timeout (w : World) (v : Node) (voter : v ∈ w.voters)
      (notLeader : (w.nodes v).role ≠ .leader) (ready : Idle (w.nodes v)) :
      Step w (campaign w v)
  | requestVote (w : World) (v c t : Nat) (logOk : Bool)
      (delivered : ⟨c, v, .vote t⟩ ∈ w.sent) (other : c ≠ v) (ready : Idle (w.nodes v)) :
      Step w { w with nodes := set w.nodes v (handleVote (w.nodes v) c t logOk) }
  | voteReply (w : World) (v c t : Nat) (granted : Bool)
      (delivered : ⟨c, v, .voted t granted⟩ ∈ w.sent) (other : c ≠ v) (ready : Idle (w.nodes v)) :
      Step w (handleVoted w v c t granted)
  | observe (w : World) (v t : Nat) (higher : (w.nodes v).term < t) (ready : Idle (w.nodes v)) :
      Step w { w with nodes := set w.nodes v (stepDown (w.nodes v) t) }
  | persist (w : World) (v : Node) (dirty : (w.nodes v).dirty = true) : Step w (persist w v)
  | materialize (w : World) (v : Node) (p : Pending) (rest : List Pending)
      (clean : (w.nodes v).dirty = false) (queued : (w.nodes v).outbox = p :: rest) :
      Step w (materialize w v p rest)
  | crash (w : World) (v : Node) : Step w (crash w v)
  | probe (w : World) (v : Node) (voter : v ∈ w.voters)
      (notLeader : (w.nodes v).role ≠ .leader) (ready : Idle (w.nodes v)) :
      Step w (probe w v)
  | answerProbe (w : World) (v c campaign : Nat) (granted : Bool)
      (delivered : ⟨c, v, .prevote campaign⟩ ∈ w.sent) (other : c ≠ v) (ready : Idle (w.nodes v)) :
      Step w { w with nodes := (set w.nodes v ({ w.nodes v with outbox := [.prevoted c campaign granted] })) }
  | preVoteReply (w : World) (v c term campaign : Nat) (granted : Bool)
      (delivered : ⟨c, v, .prevoted term campaign granted⟩ ∈ w.sent) (other : c ≠ v)
      (ready : Idle (w.nodes v)) :
      Step w (handlePreVoted w v c term campaign granted)

inductive Reachable : World → Prop where
  | initial (voters : List Node) (unique : voters.Nodup) : Reachable (initial voters)
  | step {w w' : World} : Reachable w → Step w w' → Reachable w'

/-- The inductive strengthening. Every field is about one node or one ghost
    record; none states the safety conclusion. -/
structure Inv (w : World) : Prop where
  unique : w.voters.Nodup
  durableLe : ∀ v, (w.nodes v).durable.term ≤ (w.nodes v).term
  clean : ∀ v, (w.nodes v).dirty = false →
    (w.nodes v).term = (w.nodes v).durable.term ∧ (w.nodes v).vote = (w.nodes v).durable.vote
  durableBallot : ∀ v c, (w.nodes v).durable.vote = some c →
    ((w.nodes v).durable.term, v, c) ∈ w.ballots
  ballotCurrent : ∀ t v c, (t, v, c) ∈ w.ballots →
    t < (w.nodes v).term ∨ (t = (w.nodes v).term ∧ (w.nodes v).vote = some c)
  ballotDurable : ∀ t v c, (t, v, c) ∈ w.ballots →
    t < (w.nodes v).durable.term ∨
      (t = (w.nodes v).durable.term ∧ (w.nodes v).durable.vote = some c)
  ballotFunctional : ∀ t v c c', (t, v, c) ∈ w.ballots → (t, v, c') ∈ w.ballots → c = c'
  ballotRequest : ∀ t v c, (t, v, c) ∈ w.ballots → v ≠ c → ⟨c, v, .vote t⟩ ∈ w.sent
  voteRequest : ∀ v c, (w.nodes v).vote = some c → c ≠ v →
    ⟨c, v, .vote (w.nodes v).term⟩ ∈ w.sent
  requestBallot : ∀ v x t, ⟨v, x, .vote t⟩ ∈ w.sent → (t, v, v) ∈ w.ballots
  grantBallot : ∀ x c t, ⟨x, c, .voted t true⟩ ∈ w.sent → (t, x, c) ∈ w.ballots
  outboxVote : ∀ v x, Pending.vote x ∈ (w.nodes v).outbox → (w.nodes v).vote = some v
  outboxGrant : ∀ v c, Pending.voted c true ∈ (w.nodes v).outbox → (w.nodes v).vote = some c
  probing : ∀ v c, (w.nodes v).prevoting = some c →
    v ∈ w.voters ∧ (w.nodes v).role = .follower ∧ c = (w.nodes v).term + 1
  campaigning : ∀ v, (w.nodes v).role ≠ .follower →
    v ∈ w.voters ∧ (w.nodes v).vote = some v ∧
    (∀ x ∈ (w.nodes v).votes, x = v ∨ ((w.nodes v).term, x, v) ∈ w.ballots) ∧
    ((∃ x ∈ (w.nodes v).votes, x ≠ v) → ((w.nodes v).term, v, v) ∈ w.ballots)
  winners : ∀ t c support, (t, c, support) ∈ w.elected →
    c ∈ w.voters ∧ Majority w.voters support ∧
    (∀ x ∈ support, x = c ∨ (t, x, c) ∈ w.ballots) ∧
    ((∃ x ∈ support, x ≠ c) → (t, c, c) ∈ w.ballots)

/-! ### Counting -/

theorem countP_or_and (p q : α → Bool) (values : List α) :
    values.countP p + values.countP q =
      values.countP (fun v => p v || q v) + values.countP (fun v => p v && q v) := by
  induction values with
  | nil => rfl
  | cons head rest ih =>
    simp only [List.countP_cons]
    cases p head <;> cases q head <;> simp <;> omega

/-- Two strict majorities of one voter list share a voter. -/
theorem majorities_intersect (voters first second : List Node)
    (one : Majority voters first) (two : Majority voters second) :
    ∃ x ∈ voters, x ∈ first ∧ x ∈ second := by
  have sum := countP_or_and (fun x => decide (x ∈ first)) (fun x => decide (x ∈ second)) voters
  have bounded : voters.countP (fun x => decide (x ∈ first) || decide (x ∈ second)) ≤
      voters.length := List.countP_le_length
  unfold Majority at one two
  have shared : 0 < voters.countP (fun x => decide (x ∈ first) && decide (x ∈ second)) := by
    omega
  obtain ⟨x, member, both⟩ := List.countP_pos_iff.mp shared
  simp only [Bool.and_eq_true, decide_eq_true_eq] at both
  exact ⟨x, member, both⟩

theorem count_unique (c : Node) : ∀ (values : List Node), values.Nodup →
    values.countP (fun x => decide (x = c)) ≤ 1
  | [], _ => by simp
  | head :: rest, unique => by
    rw [List.nodup_cons] at unique
    simp only [List.countP_cons]
    by_cases same : head = c
    · subst same
      have absent : rest.countP (fun x => decide (x = head)) = 0 :=
        List.countP_eq_zero.mpr (fun x member equal => by
          simp only [decide_eq_true_eq] at equal
          subst equal
          exact unique.1 member)
      simp [absent]
    · simpa [same] using count_unique c rest unique.2

/-- A majority supported only by `c` forces a single-voter configuration. -/
theorem lone_support (voters support : List Node) (c : Node) (unique : voters.Nodup)
    (majority : Majority voters support) (only : ∀ x ∈ support, x = c) :
    voters.length ≤ 1 := by
  have within : voters.countP (fun x => decide (x ∈ support)) ≤
      voters.countP (fun x => decide (x = c)) :=
    List.countP_mono_left (fun x _ member => by
      simp only [decide_eq_true_eq] at member ⊢
      exact only x member)
  have single : voters.countP (fun x => decide (x = c)) ≤ 1 := count_unique c voters unique
  unfold Majority at majority
  omega

theorem single_voter (voters : List Node) (bound : voters.length ≤ 1) (a b : Node)
    (ha : a ∈ voters) (hb : b ∈ voters) : a = b := by
  match voters, bound, ha, hb with
  | [], _, ha, _ => simp at ha
  | [_], _, ha, hb =>
    simp only [List.mem_singleton] at ha hb
    rw [ha, hb]
  | _ :: _ :: _, bound, _, _ => simp at bound

/-- Election safety from the invariant: at most one leader per term, over the
    entire history of elections rather than only current roles. -/
theorem unique_leader (w : World) (inv : Inv w) (t a b : Nat) (first second : List Node)
    (electedA : (t, a, first) ∈ w.elected) (electedB : (t, b, second) ∈ w.elected) : a = b := by
  obtain ⟨voterA, majorityA, votesA, selfA⟩ := inv.winners t a first electedA
  obtain ⟨voterB, majorityB, votesB, selfB⟩ := inv.winners t b second electedB
  obtain ⟨x, member, inA, inB⟩ := majorities_intersect w.voters first second majorityA majorityB
  rcases votesA x inA with rfl | ballotA <;> rcases votesB x inB with h | ballotB
  · exact h
  · -- x = a voted for b; a's own ballot exists unless a won alone.
    by_cases lone : ∃ y ∈ first, y ≠ x
    · exact inv.ballotFunctional t x x b (selfA lone) ballotB
    · have bound := lone_support w.voters first x inv.unique majorityA
        (fun y member => Decidable.byContradiction fun different => lone ⟨y, member, different⟩)
      exact single_voter w.voters bound x b voterA voterB
  · subst h
    by_cases lone : ∃ y ∈ second, y ≠ x
    · exact (inv.ballotFunctional t x x a (selfB lone) ballotA).symm
    · have bound := lone_support w.voters second x inv.unique majorityB
        (fun y member => Decidable.byContradiction fun different => lone ⟨y, member, different⟩)
      exact single_voter w.voters bound a x voterA voterB
  · exact inv.ballotFunctional t x a b ballotA ballotB

/-! ### Preservation -/

@[simp] theorem set_self (nodes : Node → Local) (v : Node) (s : Local) : set nodes v s v = s := by
  simp [set]

@[simp] theorem set_other (nodes : Node → Local) (v x : Node) (s : Local) (h : x ≠ v) :
    set nodes v s x = nodes x := by
  simp [set, h]

theorem initial_inv (voters : List Node) (unique : voters.Nodup) : Inv (initial voters) where
  unique := unique
  durableLe := by intro v; simp [initial, fresh]
  clean := by intro v _; simp [initial, fresh]
  durableBallot := by intro v c h; simp [initial, fresh] at h
  ballotCurrent := by intro t v c h; simp [initial] at h
  ballotDurable := by intro t v c h; simp [initial] at h
  ballotFunctional := by intro t v c c' h; simp [initial] at h
  ballotRequest := by intro t v c h; simp [initial] at h
  voteRequest := by intro v c h; simp [initial, fresh] at h
  requestBallot := by intro v x t h; simp [initial] at h
  grantBallot := by intro x c t h; simp [initial] at h
  outboxVote := by intro v x h; simp [initial, fresh] at h
  outboxGrant := by intro v c h; simp [initial, fresh] at h
  probing := by intro v c h; simp [initial, fresh] at h
  campaigning := by intro v h; simp [initial, fresh] at h
  winners := by intro t c support h; simp [initial] at h

theorem observe_inv (w : World) (v t : Nat) (inv : Inv w) (higher : (w.nodes v).term < t)
    (ready : Idle (w.nodes v)) :
    Inv { w with nodes := set w.nodes v (stepDown (w.nodes v) t) } := by
  obtain ⟨_, idleOutbox⟩ := ready
  refine ⟨inv.unique, ?_, ?_, ?_, ?_, ?_, inv.ballotFunctional, inv.ballotRequest, ?_,
    inv.requestBallot, inv.grantBallot, ?_, ?_, ?_, ?_, inv.winners⟩
  · intro x
    rcases Classical.em (x = v) with rfl | h
    · have := inv.durableLe x; simp [stepDown]; omega
    · simpa [h] using inv.durableLe x
  · intro x clean
    rcases Classical.em (x = v) with rfl | h
    · simp [stepDown] at clean
    · simp [h] at clean ⊢; exact inv.clean x clean
  · intro x c durable
    rcases Classical.em (x = v) with rfl | h
    · simp [stepDown] at durable ⊢; exact inv.durableBallot x c durable
    · simp [h] at durable ⊢; exact inv.durableBallot x c durable
  · intro t' x c ballot
    rcases Classical.em (x = v) with rfl | h
    · have := inv.ballotCurrent t' x c ballot; simp [stepDown]; omega
    · simpa [h] using inv.ballotCurrent t' x c ballot
  · intro t' x c ballot
    rcases Classical.em (x = v) with rfl | h
    · simpa [stepDown] using inv.ballotDurable t' x c ballot
    · simpa [h] using inv.ballotDurable t' x c ballot
  · intro x c vote different
    rcases Classical.em (x = v) with rfl | h
    · simp [stepDown] at vote
    · simp [h] at vote ⊢; exact inv.voteRequest x c vote different
  · intro x y member
    rcases Classical.em (x = v) with rfl | h
    · simp [stepDown, idleOutbox] at member
    · simp [h] at member ⊢; exact inv.outboxVote x y member
  · intro x c member
    rcases Classical.em (x = v) with rfl | h
    · simp [stepDown, idleOutbox] at member
    · simp [h] at member ⊢; exact inv.outboxGrant x c member
  · intro x c probe
    rcases Classical.em (x = v) with rfl | h
    · simp [stepDown] at probe
    · simp only [set_other _ _ _ _ h] at probe ⊢; exact inv.probing x c probe
  · intro x role
    rcases Classical.em (x = v) with rfl | h
    · simp [stepDown] at role
    · simp only [set_other _ _ _ _ h] at role ⊢; exact inv.campaigning x role

theorem crash_inv (w : World) (v : Node) (inv : Inv w) : Inv (crash w v) := by
  refine ⟨inv.unique, ?_, ?_, ?_, ?_, ?_, inv.ballotFunctional, inv.ballotRequest, ?_,
    inv.requestBallot, inv.grantBallot, ?_, ?_, ?_, ?_, inv.winners⟩
  all_goals simp only [crash]
  · intro x
    rcases Classical.em (x = v) with rfl | h
    · simp
    · simpa [h] using inv.durableLe x
  · intro x clean
    rcases Classical.em (x = v) with rfl | h
    · simp
    · simp [h] at clean ⊢; exact inv.clean x clean
  · intro x c durable
    rcases Classical.em (x = v) with rfl | h
    · simp at durable ⊢; exact inv.durableBallot x c durable
    · simp [h] at durable ⊢; exact inv.durableBallot x c durable
  · intro t x c ballot
    rcases Classical.em (x = v) with rfl | h
    · simpa using inv.ballotDurable t x c ballot
    · simpa [h] using inv.ballotCurrent t x c ballot
  · intro t x c ballot
    rcases Classical.em (x = v) with rfl | h
    · simpa using inv.ballotDurable t x c ballot
    · simpa [h] using inv.ballotDurable t x c ballot
  · intro x c vote different
    rcases Classical.em (x = v) with rfl | h
    · simp at vote ⊢
      exact inv.ballotRequest _ x c (inv.durableBallot x c vote) (Ne.symm different)
    · simp [h] at vote ⊢; exact inv.voteRequest x c vote different
  · intro x y member
    rcases Classical.em (x = v) with rfl | h
    · simp at member
    · simp [h] at member ⊢; exact inv.outboxVote x y member
  · intro x c member
    rcases Classical.em (x = v) with rfl | h
    · simp at member
    · simp [h] at member ⊢; exact inv.outboxGrant x c member
  · intro x c probe
    rcases Classical.em (x = v) with rfl | h
    · simp at probe
    · simp only [set_other _ _ _ _ h] at probe ⊢; exact inv.probing x c probe
  · intro x role
    rcases Classical.em (x = v) with rfl | h
    · simp at role
    · simp only [set_other _ _ _ _ h] at role ⊢; exact inv.campaigning x role

theorem mem_persist_ballots (w : World) (v : Node) (b : Nat × Node × Node) :
    b ∈ (persist w v).ballots ↔
      b ∈ w.ballots ∨ ∃ c, (w.nodes v).vote = some c ∧ b = ((w.nodes v).term, v, c) := by
  unfold persist
  cases h : (w.nodes v).vote <;> simp [h]

theorem persist_inv (w : World) (v : Node) (inv : Inv w) : Inv (persist w v) := by
  have grow : ∀ b, b ∈ w.ballots → b ∈ (persist w v).ballots :=
    fun b member => (mem_persist_ballots w v b).mpr (.inl member)
  have nodesOf : ∀ x, (persist w v).nodes x =
      if x = v then { w.nodes v with durable := ⟨(w.nodes v).term, (w.nodes v).vote⟩, dirty := false }
      else w.nodes x := fun x => rfl
  have term : ∀ x, ((persist w v).nodes x).term = (w.nodes x).term := by
    intro x; rw [nodesOf]; split <;> simp_all
  have vote : ∀ x, ((persist w v).nodes x).vote = (w.nodes x).vote := by
    intro x; rw [nodesOf]; split <;> simp_all
  have role : ∀ x, ((persist w v).nodes x).role = (w.nodes x).role := by
    intro x; rw [nodesOf]; split <;> simp_all
  have votes : ∀ x, ((persist w v).nodes x).votes = (w.nodes x).votes := by
    intro x; rw [nodesOf]; split <;> simp_all
  have outbox : ∀ x, ((persist w v).nodes x).outbox = (w.nodes x).outbox := by
    intro x; rw [nodesOf]; split <;> simp_all
  have prevoting : ∀ x, ((persist w v).nodes x).prevoting = (w.nodes x).prevoting := by
    intro x; rw [nodesOf]; split <;> simp_all
  have sent : (persist w v).sent = w.sent := rfl
  have voters : (persist w v).voters = w.voters := rfl
  have elected : (persist w v).elected = w.elected := rfl
  have durableOf : ∀ x, ((persist w v).nodes x).durable =
      if x = v then ⟨(w.nodes v).term, (w.nodes v).vote⟩ else (w.nodes x).durable := by
    intro x; rw [nodesOf]; split <;> simp_all
  refine ⟨inv.unique, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · intro x
    rw [durableOf, term]
    split
    · subst_vars; exact Nat.le_refl _
    · exact inv.durableLe x
  · intro x clean
    rw [durableOf, term, vote]
    split
    · subst_vars; exact ⟨rfl, rfl⟩
    · have dirty : (w.nodes x).dirty = false := by
        rw [nodesOf, if_neg (by assumption)] at clean; exact clean
      exact inv.clean x dirty
  · intro x c durable
    rw [durableOf] at durable ⊢
    split at durable
    · subst_vars
      rw [if_pos rfl]
      exact (mem_persist_ballots w x _).mpr (.inr ⟨c, durable, rfl⟩)
    · rw [if_neg (by assumption)]; exact grow _ (inv.durableBallot x c durable)
  · intro t x c ballot
    rw [term, vote]
    rcases (mem_persist_ballots w v _).mp ballot with old | ⟨c', current, same⟩
    · exact inv.ballotCurrent t x c old
    · simp only [Prod.mk.injEq] at same
      obtain ⟨rfl, rfl, rfl⟩ := same
      exact .inr ⟨rfl, current⟩
  · intro t x c ballot
    rw [durableOf]
    rcases (mem_persist_ballots w v _).mp ballot with old | ⟨c', current, same⟩
    · split
      · subst_vars; exact inv.ballotCurrent t x c old
      · exact inv.ballotDurable t x c old
    · simp only [Prod.mk.injEq] at same
      obtain ⟨rfl, rfl, rfl⟩ := same
      rw [if_pos rfl]
      exact .inr ⟨rfl, current⟩
  · intro t x c c' first second
    rcases (mem_persist_ballots w v _).mp first with old | ⟨d, current, same⟩ <;>
    rcases (mem_persist_ballots w v _).mp second with old' | ⟨d', current', same'⟩
    · exact inv.ballotFunctional t x c c' old old'
    · simp only [Prod.mk.injEq] at same'
      obtain ⟨rfl, rfl, rfl⟩ := same'
      rcases inv.ballotCurrent _ _ _ old with lower | ⟨_, equal⟩
      · omega
      · rw [current'] at equal; exact (Option.some.inj equal).symm
    · simp only [Prod.mk.injEq] at same
      obtain ⟨rfl, rfl, rfl⟩ := same
      rcases inv.ballotCurrent _ _ _ old' with lower | ⟨_, equal⟩
      · omega
      · rw [current] at equal; exact Option.some.inj equal
    · simp only [Prod.mk.injEq] at same same'
      obtain ⟨_, _, rfl⟩ := same
      obtain ⟨_, _, rfl⟩ := same'
      rw [current] at current'; exact Option.some.inj current'
  · intro t x c ballot different
    rw [sent]
    rcases (mem_persist_ballots w v _).mp ballot with old | ⟨c', current, same⟩
    · exact inv.ballotRequest t x c old different
    · simp only [Prod.mk.injEq] at same
      obtain ⟨rfl, rfl, rfl⟩ := same
      exact inv.voteRequest x c current (Ne.symm different)
  · intro x c current different
    rw [term, sent]; rw [vote] at current
    exact inv.voteRequest x c current different
  · intro x y t request
    exact grow _ (inv.requestBallot x y t request)
  · intro x c t grant
    exact grow _ (inv.grantBallot x c t grant)
  · intro x y member
    rw [outbox] at member; rw [vote]; exact inv.outboxVote x y member
  · intro x c member
    rw [outbox] at member; rw [vote]; exact inv.outboxGrant x c member
  · intro x c probe
    rw [prevoting] at probe; rw [role, term]; exact inv.probing x c probe
  · intro x active
    rw [role] at active
    obtain ⟨voter, self, supported, own⟩ := inv.campaigning x active
    refine ⟨voter, by rw [vote]; exact self, ?_, ?_⟩
    · intro y member
      rw [votes] at member; rw [term]
      rcases supported y member with same | ballot
      · exact .inl same
      · exact .inr (grow _ ballot)
    · intro witness
      rw [votes] at witness; rw [term]
      exact grow _ (own witness)
  · intro t c support win
    obtain ⟨voter, majority, supported, own⟩ := inv.winners t c support win
    refine ⟨voter, majority, ?_, ?_⟩
    · intro y member
      rcases supported y member with same | ballot
      · exact .inl same
      · exact .inr (grow _ ballot)
    · intro witness
      exact grow _ (own witness)

theorem materialize_inv (w : World) (v : Node) (p : Pending) (rest : List Pending) (inv : Inv w)
    (clean : (w.nodes v).dirty = false) (queued : (w.nodes v).outbox = p :: rest) :
    Inv (materialize w v p rest) := by
  have nodesOf : ∀ x, (materialize w v p rest).nodes x =
      if x = v then { w.nodes v with outbox := rest } else w.nodes x := fun x => rfl
  have term : ∀ x, ((materialize w v p rest).nodes x).term = (w.nodes x).term := by
    intro x; rw [nodesOf]; split <;> simp_all
  have vote : ∀ x, ((materialize w v p rest).nodes x).vote = (w.nodes x).vote := by
    intro x; rw [nodesOf]; split <;> simp_all
  have role : ∀ x, ((materialize w v p rest).nodes x).role = (w.nodes x).role := by
    intro x; rw [nodesOf]; split <;> simp_all
  have votes : ∀ x, ((materialize w v p rest).nodes x).votes = (w.nodes x).votes := by
    intro x; rw [nodesOf]; split <;> simp_all
  have dirty : ∀ x, ((materialize w v p rest).nodes x).dirty = (w.nodes x).dirty := by
    intro x; rw [nodesOf]; split <;> simp_all
  have durable : ∀ x, ((materialize w v p rest).nodes x).durable = (w.nodes x).durable := by
    intro x; rw [nodesOf]; split <;> simp_all
  have prevoting : ∀ x, ((materialize w v p rest).nodes x).prevoting = (w.nodes x).prevoting := by
    intro x; rw [nodesOf]; split <;> simp_all
  have outbox : ∀ x m, m ∈ ((materialize w v p rest).nodes x).outbox → m ∈ (w.nodes x).outbox := by
    intro x m member
    rw [nodesOf] at member
    split at member
    · subst_vars; rw [queued]; exact List.mem_cons_of_mem _ member
    · exact member
  have grow : ∀ e, e ∈ w.sent → e ∈ (materialize w v p rest).sent :=
    fun e member => List.mem_append_left _ member
  have newEnvelope : ∀ e, e ∈ (materialize w v p rest).sent → e ∈ w.sent ∨ e = envelopeOf v (w.nodes v).term p := by
    intro e member
    simpa [materialize] using member
  have current := inv.clean v clean
  have pending : p ∈ (w.nodes v).outbox := by rw [queued]; exact List.mem_cons_self
  refine ⟨inv.unique, ?_, ?_, ?_, fun t x c ballot => by
      rw [term, vote]; exact inv.ballotCurrent t x c ballot,
    ?_, inv.ballotFunctional, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, inv.winners⟩
  · intro x; rw [durable, term]; exact inv.durableLe x
  · intro x c; rw [dirty] at c; rw [term, vote, durable]; exact inv.clean x c
  · intro x c d; rw [durable] at d ⊢; exact inv.durableBallot x c d
  · intro t x c ballot; rw [durable]; exact inv.ballotDurable t x c ballot
  · intro t x c ballot different; exact grow _ (inv.ballotRequest t x c ballot different)
  · intro x c current different
    rw [term]; rw [vote] at current
    exact grow _ (inv.voteRequest x c current different)
  · intro x y t request
    rcases newEnvelope _ request with old | fresh
    · exact inv.requestBallot x y t old
    · cases p with
      | vote target =>
        simp only [envelopeOf, Envelope.mk.injEq, Message.vote.injEq] at fresh
        obtain ⟨rfl, rfl, rfl⟩ := fresh
        have self := inv.outboxVote x _ pending
        rw [current.2] at self
        rw [current.1]
        exact inv.durableBallot x x self
      | voted target granted =>
        simp [envelopeOf] at fresh
      | prevote target campaign => simp [envelopeOf] at fresh
      | prevoted target campaign granted => simp [envelopeOf] at fresh
  · intro x c t grant
    rcases newEnvelope _ grant with old | fresh
    · exact inv.grantBallot x c t old
    · cases p with
      | vote target => simp [envelopeOf] at fresh
      | voted target granted =>
        simp only [envelopeOf, Envelope.mk.injEq, Message.voted.injEq] at fresh
        obtain ⟨rfl, rfl, rfl, rfl⟩ := fresh
        have granted := inv.outboxGrant x c pending
        rw [current.2] at granted
        rw [current.1]
        exact inv.durableBallot x c granted
      | prevote target campaign => simp [envelopeOf] at fresh
      | prevoted target campaign granted => simp [envelopeOf] at fresh
  · intro x y member; rw [vote]; exact inv.outboxVote x y (outbox x _ member)
  · intro x c member; rw [vote]; exact inv.outboxGrant x c (outbox x _ member)
  · intro x c probe; rw [prevoting] at probe; rw [role, term]; exact inv.probing x c probe
  · intro x active
    rw [role] at active
    obtain ⟨voter, self, supported, own⟩ := inv.campaigning x active
    exact ⟨voter, by rw [vote]; exact self, by rw [votes, term]; exact supported,
      by rw [votes, term]; exact own⟩

/-- Node-level conditions for replacing node `v`'s state with `s` while the
    ghost records and the network stay unchanged. -/
structure LocalOk (w : World) (v : Node) (s : Local) : Prop where
  durableLe : s.durable.term ≤ s.term
  clean : s.dirty = false → s.term = s.durable.term ∧ s.vote = s.durable.vote
  durableBallot : ∀ c, s.durable.vote = some c → (s.durable.term, v, c) ∈ w.ballots
  ballotCurrent : ∀ t c, (t, v, c) ∈ w.ballots → t < s.term ∨ (t = s.term ∧ s.vote = some c)
  ballotDurable : ∀ t c, (t, v, c) ∈ w.ballots →
    t < s.durable.term ∨ (t = s.durable.term ∧ s.durable.vote = some c)
  voteRequest : ∀ c, s.vote = some c → c ≠ v → ⟨c, v, .vote s.term⟩ ∈ w.sent
  outboxVote : ∀ x, Pending.vote x ∈ s.outbox → s.vote = some v
  outboxGrant : ∀ c, Pending.voted c true ∈ s.outbox → s.vote = some c
  probing : ∀ c, s.prevoting = some c → v ∈ w.voters ∧ s.role = .follower ∧ c = s.term + 1
  campaigning : s.role ≠ .follower →
    v ∈ w.voters ∧ s.vote = some v ∧ (∀ x ∈ s.votes, x = v ∨ (s.term, x, v) ∈ w.ballots) ∧
    ((∃ x ∈ s.votes, x ≠ v) → (s.term, v, v) ∈ w.ballots)

def Winner (w : World) (t c : Nat) (support : List Node) : Prop :=
  c ∈ w.voters ∧ Majority w.voters support ∧
  (∀ x ∈ support, x = c ∨ (t, x, c) ∈ w.ballots) ∧
  ((∃ x ∈ support, x ≠ c) → (t, c, c) ∈ w.ballots)

theorem update_inv (w : World) (v : Node) (s : Local) (extra : List (Nat × Node × List Node))
    (inv : Inv w) (ok : LocalOk w v s) (fresh : ∀ t c support, (t, c, support) ∈ extra → Winner w t c support) :
    Inv { w with nodes := set w.nodes v s, elected := w.elected ++ extra } := by
  refine ⟨inv.unique, ?_, ?_, ?_, ?_, ?_, inv.ballotFunctional, inv.ballotRequest, ?_,
    inv.requestBallot, inv.grantBallot, ?_, ?_, ?_, ?_, ?_⟩
  · intro x
    rcases Classical.em (x = v) with rfl | h
    · simpa using ok.durableLe
    · simpa [h] using inv.durableLe x
  · intro x clean
    rcases Classical.em (x = v) with rfl | h
    · simp only [set_self] at clean ⊢; exact ok.clean clean
    · simp only [set_other _ _ _ _ h] at clean ⊢; exact inv.clean x clean
  · intro x c durable
    rcases Classical.em (x = v) with rfl | h
    · simp only [set_self] at durable ⊢; exact ok.durableBallot c durable
    · simp only [set_other _ _ _ _ h] at durable ⊢; exact inv.durableBallot x c durable
  · intro t x c ballot
    rcases Classical.em (x = v) with rfl | h
    · simp only [set_self]; exact ok.ballotCurrent t c ballot
    · simp only [set_other _ _ _ _ h]; exact inv.ballotCurrent t x c ballot
  · intro t x c ballot
    rcases Classical.em (x = v) with rfl | h
    · simp only [set_self]; exact ok.ballotDurable t c ballot
    · simp only [set_other _ _ _ _ h]; exact inv.ballotDurable t x c ballot
  · intro x c vote different
    rcases Classical.em (x = v) with rfl | h
    · simp only [set_self] at vote ⊢; exact ok.voteRequest c vote different
    · simp only [set_other _ _ _ _ h] at vote ⊢; exact inv.voteRequest x c vote different
  · intro x y member
    rcases Classical.em (x = v) with rfl | h
    · simp only [set_self] at member ⊢; exact ok.outboxVote y member
    · simp only [set_other _ _ _ _ h] at member ⊢; exact inv.outboxVote x y member
  · intro x c member
    rcases Classical.em (x = v) with rfl | h
    · simp only [set_self] at member ⊢; exact ok.outboxGrant c member
    · simp only [set_other _ _ _ _ h] at member ⊢; exact inv.outboxGrant x c member
  · intro x c probe
    rcases Classical.em (x = v) with rfl | h
    · simp only [set_self] at probe ⊢; exact ok.probing c probe
    · simp only [set_other _ _ _ _ h] at probe ⊢; exact inv.probing x c probe
  · intro x active
    rcases Classical.em (x = v) with rfl | h
    · simp only [set_self] at active ⊢; exact ok.campaigning active
    · simp only [set_other _ _ _ _ h] at active ⊢; exact inv.campaigning x active
  · intro t c support win
    rcases List.mem_append.mp win with old | new
    · exact inv.winners t c support old
    · exact fresh t c support new

theorem update_inv' (w : World) (v : Node) (s : Local) (inv : Inv w) (ok : LocalOk w v s) :
    Inv { w with nodes := set w.nodes v s } := by
  have := update_inv w v s [] inv ok (by simp)
  simpa using this

theorem campaign_local (w : World) (v : Node) (inv : Inv w) (voter : v ∈ w.voters)
    (role : Role) (outbox : List Pending)
    (votesOnly : ∀ m ∈ outbox, ∃ x, m = .vote x) :
    LocalOk w v ({ w.nodes v with term := (w.nodes v).term + 1, vote := some v, role := role, votes := [v], dirty := true, outbox := outbox, prevoting := none }) where
  durableLe := by have := inv.durableLe v; simp; omega
  clean := by simp
  durableBallot := fun c durable => inv.durableBallot v c durable
  ballotCurrent := by
    intro t c ballot
    have := inv.ballotCurrent t v c ballot
    left; simp; omega
  ballotDurable := fun t c ballot => inv.ballotDurable t v c ballot
  voteRequest := by
    intro c vote different
    simp at vote; exact absurd vote.symm different
  outboxVote := by intro x _; rfl
  outboxGrant := by
    intro c member
    obtain ⟨x, same⟩ := votesOnly _ member
    cases same
  probing := by simp
  campaigning := by
    intro _
    refine ⟨voter, rfl, ?_, ?_⟩
    · intro x member; simp at member; exact .inl member
    · intro witness
      obtain ⟨x, member, different⟩ := witness
      simp at member; exact absurd member different

theorem timeout_inv (w : World) (v : Node) (inv : Inv w) (voter : v ∈ w.voters)
    (ready : Idle (w.nodes v)) : Inv (campaign w v) := by
  obtain ⟨_, idleOutbox⟩ := ready
  unfold campaign
  split
  · rename_i majority
    have ok := campaign_local w v inv voter .leader (w.nodes v).outbox
      (by intro m member; rw [idleOutbox] at member; cases member)
    exact update_inv w v _ _ inv ok (by
      intro t c support member
      simp only [List.mem_singleton, Prod.mk.injEq] at member
      obtain ⟨rfl, rfl, rfl⟩ := member
      refine ⟨voter, majority, ?_, ?_⟩
      · intro x member; simp at member; exact .inl member
      · intro witness
        obtain ⟨x, member, different⟩ := witness
        simp at member; exact absurd member different)
  · have ok := campaign_local w v inv voter .candidate
      ((w.voters.filter (· ≠ v)).map Pending.vote)
      (by intro m member; simp at member; obtain ⟨x, _, rfl⟩ := member; exact ⟨x, rfl⟩)
    exact update_inv' w v _ inv ok

/-- A clean, idle node only queues a rejection. -/
theorem reject_local (w : World) (v c : Node) (inv : Inv w) (ready : Idle (w.nodes v)) :
    LocalOk w v ({ w.nodes v with outbox := [.voted c false] }) where
  durableLe := inv.durableLe v
  clean := fun _ => inv.clean v ready.1
  durableBallot := fun c durable => inv.durableBallot v c durable
  ballotCurrent := fun t c ballot => inv.ballotCurrent t v c ballot
  ballotDurable := fun t c ballot => inv.ballotDurable t v c ballot
  voteRequest := fun c vote different => inv.voteRequest v c vote different
  outboxVote := by intro x member; simp at member
  outboxGrant := by intro c member; simp at member
  probing := fun c probe => inv.probing v c probe
  campaigning := fun active => inv.campaigning v active

/-- Granting a current-term request records the vote and queues the grant. -/
theorem grant_local (w : World) (v c t : Node) (inv : Inv w) (ready : Idle (w.nodes v))
    (delivered : ⟨c, v, .vote t⟩ ∈ w.sent) (other : c ≠ v) (current : t = (w.nodes v).term)
    (free : (w.nodes v).vote = none ∨ (w.nodes v).vote = some c) :
    LocalOk w v ({ w.nodes v with vote := some c, dirty := (w.nodes v).dirty || decide ((w.nodes v).vote ≠ some c), outbox := [.voted c true] }) where
  durableLe := inv.durableLe v
  clean := by
    intro clean
    simp only [ready.1, Bool.false_or, decide_eq_false_iff_not, Decidable.not_not] at clean
    have before := inv.clean v ready.1
    exact ⟨before.1, by rw [← clean]; exact before.2⟩
  durableBallot := fun c durable => inv.durableBallot v c durable
  ballotCurrent := by
    intro t' c' ballot
    rcases inv.ballotCurrent t' v c' ballot with lower | ⟨same, vote⟩
    · exact .inl lower
    · refine .inr ⟨same, ?_⟩
      rcases free with none | some
      · rw [none] at vote; cases vote
      · rw [some] at vote; exact vote
  ballotDurable := fun t c ballot => inv.ballotDurable t v c ballot
  voteRequest := by
    intro c' vote different
    simp only [Option.some.injEq] at vote
    subst vote
    rw [← current]; exact delivered
  outboxVote := by intro x member; simp at member
  outboxGrant := by
    intro c' member
    simp only [List.mem_singleton, Pending.voted.injEq, and_true] at member
    rw [member]
  probing := fun c probe => inv.probing v c probe
  campaigning := by
    intro active
    have self := (inv.campaigning v active).2.1
    rcases free with none | some
    · rw [none] at self; cases self
    · rw [some] at self; exact absurd (Option.some.inj self) other

/-- A higher term resets the vote before the request is considered. -/
theorem stepped_local (w : World) (v c t : Node) (inv : Inv w)
    (delivered : ⟨c, v, .vote t⟩ ∈ w.sent) (higher : (w.nodes v).term < t)
    (vote : Option Node) (granted : Bool)
    (votedFor : (vote = none ∧ granted = false) ∨ (vote = some c ∧ granted = true)) :
    LocalOk w v ({ w.nodes v with term := t, vote := vote, dirty := true, role := .follower, outbox := [.voted c granted], prevoting := none }) where
  durableLe := by have := inv.durableLe v; simp only; omega
  clean := by simp
  durableBallot := fun c durable => inv.durableBallot v c durable
  ballotCurrent := by
    intro t' c' ballot
    have := inv.ballotCurrent t' v c' ballot
    left; simp only; omega
  ballotDurable := fun t c ballot => inv.ballotDurable t v c ballot
  voteRequest := by
    intro c' current different
    rcases votedFor with ⟨none, _⟩ | ⟨some, _⟩
    · simp only [none] at current; cases current
    · simp only [some, Option.some.injEq] at current
      subst current; exact delivered
  outboxVote := by intro x member; simp at member
  outboxGrant := by
    intro c' member
    simp only [List.mem_singleton, Pending.voted.injEq] at member
    obtain ⟨rfl, rfl⟩ := member
    rcases votedFor with ⟨_, refused⟩ | ⟨some, _⟩
    · cases refused
    · exact some
  probing := by simp
  campaigning := by simp

theorem requestVote_inv (w : World) (v c t : Nat) (logOk : Bool) (inv : Inv w)
    (delivered : ⟨c, v, .vote t⟩ ∈ w.sent) (other : c ≠ v) (ready : Idle (w.nodes v)) :
    Inv { w with nodes := set w.nodes v (handleVote (w.nodes v) c t logOk) } := by
  apply update_inv' w v _ inv
  have idleOutbox := ready.2
  unfold handleVote adopt
  by_cases stepped : (w.nodes v).term < t
  · simp only [stepped, ↓reduceIte, stepDown, Nat.lt_irrefl, Bool.true_or]
    split
    · rename_i grant
      have ok := stepped_local w v c t inv delivered stepped (some c) true (.inr ⟨rfl, rfl⟩)
      have logged : logOk = true := grant.2
      simpa [idleOutbox] using ok
    · have ok := stepped_local w v c t inv delivered stepped none false (.inl ⟨rfl, rfl⟩)
      simpa [idleOutbox] using ok
  · simp only [stepped, ↓reduceIte]
    split
    · exact reject_local w v c inv ready
    · rename_i notLower
      split
      · rename_i grant
        exact grant_local w v c t inv ready delivered other
          (Nat.le_antisymm (Nat.not_lt.mp stepped) (Nat.not_lt.mp notLower)) grant.1
      · exact reject_local w v c inv ready

theorem self_local (w : World) (v : Node) (inv : Inv w) : LocalOk w v (w.nodes v) where
  durableLe := inv.durableLe v
  clean := inv.clean v
  durableBallot := inv.durableBallot v
  ballotCurrent := fun t c ballot => inv.ballotCurrent t v c ballot
  ballotDurable := fun t c ballot => inv.ballotDurable t v c ballot
  voteRequest := inv.voteRequest v
  outboxVote := inv.outboxVote v
  outboxGrant := inv.outboxGrant v
  probing := inv.probing v
  campaigning := inv.campaigning v

theorem stepDown_local (w : World) (v t : Node) (inv : Inv w) (ready : Idle (w.nodes v))
    (higher : (w.nodes v).term < t) : LocalOk w v (stepDown (w.nodes v) t) where
  durableLe := by have := inv.durableLe v; simp only [stepDown]; omega
  clean := by simp [stepDown]
  durableBallot := fun c durable => inv.durableBallot v c durable
  ballotCurrent := by
    intro t' c ballot
    have := inv.ballotCurrent t' v c ballot
    left; simp only [stepDown]; omega
  ballotDurable := fun t c ballot => inv.ballotDurable t v c ballot
  voteRequest := by intro c vote; simp [stepDown] at vote
  outboxVote := by intro x member; simp [stepDown, ready.2] at member
  outboxGrant := by intro c member; simp [stepDown, ready.2] at member
  probing := by simp [stepDown]
  campaigning := by simp [stepDown]

/-- A counted grant always carries the candidate's own durable ballot. -/
theorem counted_local (w : World) (v c : Node) (inv : Inv w)
    (delivered : ⟨c, v, .voted (w.nodes v).term true⟩ ∈ w.sent) (other : c ≠ v)
    (active : (w.nodes v).role ≠ .follower) (votes : List Node)
    (supported : ∀ x ∈ votes, x ∈ (w.nodes v).votes ∨ x = c) :
    ((w.nodes v).term, c, v) ∈ w.ballots ∧ ((w.nodes v).term, v, v) ∈ w.ballots ∧
    ∀ x ∈ votes, x = v ∨ ((w.nodes v).term, x, v) ∈ w.ballots := by
  have ballot := inv.grantBallot c v _ delivered
  have own := inv.requestBallot v c _ (inv.ballotRequest _ c v ballot other)
  refine ⟨ballot, own, ?_⟩
  intro x member
  rcases supported x member with old | rfl
  · exact (inv.campaigning v active).2.2.1 x old
  · exact .inr ballot

theorem voteReply_inv (w : World) (v c t : Nat) (granted : Bool) (inv : Inv w)
    (delivered : ⟨c, v, .voted t granted⟩ ∈ w.sent) (other : c ≠ v) (ready : Idle (w.nodes v)) :
    Inv (handleVoted w v c t granted) := by
  unfold handleVoted
  by_cases stepped : (w.nodes v).term < t
  · -- A higher term demotes the receiver, so the grant is never counted.
    have demoted : (adopt (w.nodes v) t).role = .follower := by
      simp [adopt, stepped, stepDown]
    rw [if_neg (by simp [demoted])]
    have same : adopt (w.nodes v) t = stepDown (w.nodes v) t := by simp [adopt, stepped]
    rw [same]
    exact update_inv' w v _ inv (stepDown_local w v t inv ready stepped)
  · have same : adopt (w.nodes v) t = w.nodes v := by simp [adopt, stepped]
    rw [same]
    dsimp only
    split
    · rename_i counted
      obtain ⟨current, candidate, grant⟩ := counted
      subst current
      subst grant
      have active : (w.nodes v).role ≠ .follower := by rw [candidate]; simp
      generalize hvotes : (if c ∈ (w.nodes v).votes then (w.nodes v).votes
        else (w.nodes v).votes ++ [c]) = votes
      have supported : ∀ x ∈ votes, x ∈ (w.nodes v).votes ∨ x = c := by
        intro x member
        rw [← hvotes] at member
        split at member
        · exact .inl member
        · simpa using member
      obtain ⟨_, own, votesOk⟩ := counted_local w v c inv delivered other active votes supported
      have campaigning := inv.campaigning v active
      have ok : ∀ role : Role, LocalOk w v ({ w.nodes v with votes := votes, role := role }) := by
        intro role
        exact {
          durableLe := inv.durableLe v
          clean := inv.clean v
          durableBallot := inv.durableBallot v
          ballotCurrent := fun t c ballot => inv.ballotCurrent t v c ballot
          ballotDurable := fun t c ballot => inv.ballotDurable t v c ballot
          voteRequest := inv.voteRequest v
          outboxVote := inv.outboxVote v
          outboxGrant := inv.outboxGrant v
          probing := fun c probe => absurd (inv.probing v c probe).2.1 (by rw [candidate]; simp)
          campaigning := fun _ => ⟨campaigning.1, campaigning.2.1, votesOk, fun _ => own⟩ }
      by_cases majority : Majority w.voters votes
      · rw [if_pos majority]
        exact update_inv w v _ _ inv (ok .leader) (by
          intro t' c' support member
          rw [List.mem_singleton] at member
          cases member
          exact ⟨campaigning.1, majority, votesOk, fun _ => own⟩)
      · rw [if_neg majority]
        exact update_inv' w v _ inv (ok (w.nodes v).role)
    · exact update_inv' w v _ inv (self_local w v inv)

/-- A probing (or merely recounting) follower keeps its hard state. -/
theorem probeState_local (w : World) (v : Node) (inv : Inv w) (ready : Idle (w.nodes v))
    (voter : v ∈ w.voters) (outbox : List Pending) (votes : List Node)
    (noVotes : ∀ m ∈ outbox, (∀ x, m ≠ .vote x) ∧ ∀ c, m ≠ .voted c true) :
    LocalOk w v ({ w.nodes v with prevoting := some ((w.nodes v).term + 1), votes := votes, role := .follower, outbox := outbox }) where
  durableLe := inv.durableLe v
  clean := fun _ => inv.clean v ready.1
  durableBallot := inv.durableBallot v
  ballotCurrent := fun t c ballot => inv.ballotCurrent t v c ballot
  ballotDurable := fun t c ballot => inv.ballotDurable t v c ballot
  voteRequest := inv.voteRequest v
  outboxVote := fun x member => absurd rfl ((noVotes _ member).1 x)
  outboxGrant := fun c member => absurd rfl ((noVotes _ member).2 c)
  probing := by
    intro c probe
    simp only [Option.some.injEq] at probe
    exact ⟨voter, rfl, probe.symm⟩
  campaigning := by simp

theorem probe_inv (w : World) (v : Node) (inv : Inv w) (voter : v ∈ w.voters)
    (ready : Idle (w.nodes v)) : Inv (probe w v) := by
  unfold probe
  dsimp only
  split
  · -- The self vote suffices: campaign at once from the probing state.
    have ok := probeState_local w v inv ready voter (w.nodes v).outbox [v]
      (by intro m member; rw [ready.2] at member; cases member)
    have probed := update_inv' w v _ inv ok
    have := timeout_inv _ v probed voter ⟨by simp [ready.1], by simp [ready.2]⟩
    simpa [ready.2] using this
  · have ok := probeState_local w v inv ready voter
      ((w.voters.filter (· ≠ v)).map (fun x => Pending.prevote x ((w.nodes v).term + 1))) [v]
      (by
        intro m member
        simp only [List.mem_map] at member
        obtain ⟨x, _, rfl⟩ := member
        exact ⟨fun _ h => (by cases h), fun _ h => (by cases h)⟩)
    exact update_inv' w v _ inv ok

theorem answerProbe_inv (w : World) (v c campaign : Nat) (granted : Bool) (inv : Inv w)
    (ready : Idle (w.nodes v)) :
    Inv { w with nodes := set w.nodes v ({ w.nodes v with outbox := [.prevoted c campaign granted] }) } := by
  apply update_inv' w v _ inv
  exact {
    durableLe := inv.durableLe v
    clean := fun _ => inv.clean v ready.1
    durableBallot := inv.durableBallot v
    ballotCurrent := fun t c ballot => inv.ballotCurrent t v c ballot
    ballotDurable := fun t c ballot => inv.ballotDurable t v c ballot
    voteRequest := inv.voteRequest v
    outboxVote := by intro x member; simp at member
    outboxGrant := by intro c member; simp at member
    probing := inv.probing v
    campaigning := inv.campaigning v }

theorem preVoteReply_inv (w : World) (v c term campaign : Nat) (granted : Bool) (inv : Inv w)
    (ready : Idle (w.nodes v)) : Inv (handlePreVoted w v c term campaign granted) := by
  unfold handlePreVoted
  by_cases stepped : (w.nodes v).term < term
  · -- A higher term ends the probe, so the grant is never counted.
    have same : adopt (w.nodes v) term = stepDown (w.nodes v) term := by simp [adopt, stepped]
    rw [same, if_neg (by simp [stepDown])]
    exact update_inv' w v _ inv (stepDown_local w v term inv ready stepped)
  · have same : adopt (w.nodes v) term = w.nodes v := by simp [adopt, stepped]
    rw [same]
    dsimp only
    split
    · rename_i counted
      obtain ⟨active, _⟩ := counted
      obtain ⟨voter, follower, next⟩ := inv.probing v campaign active
      generalize hvotes : (if c ∈ (w.nodes v).votes then (w.nodes v).votes
        else (w.nodes v).votes ++ [c]) = votes
      have ok : LocalOk w v ({ w.nodes v with votes := votes }) := {
        durableLe := inv.durableLe v
        clean := inv.clean v
        durableBallot := inv.durableBallot v
        ballotCurrent := fun t c ballot => inv.ballotCurrent t v c ballot
        ballotDurable := fun t c ballot => inv.ballotDurable t v c ballot
        voteRequest := inv.voteRequest v
        outboxVote := inv.outboxVote v
        outboxGrant := inv.outboxGrant v
        probing := inv.probing v
        campaigning := by simp [follower] }
      have recounted := update_inv' w v _ inv ok
      split
      · exact timeout_inv _ v recounted voter ⟨by simp [ready.1], by simp [ready.2]⟩
      · exact recounted
    · exact update_inv' w v _ inv (self_local w v inv)

theorem step_inv {w w' : World} (inv : Inv w) (step : Step w w') : Inv w' := by
  cases step with
  | timeout v voter _ ready => exact timeout_inv w v inv voter ready
  | requestVote v c t logOk delivered other ready =>
    exact requestVote_inv w v c t logOk inv delivered other ready
  | voteReply v c t granted delivered other ready =>
    exact voteReply_inv w v c t granted inv delivered other ready
  | observe v t higher ready => exact observe_inv w v t inv higher ready
  | persist v _ => exact persist_inv w v inv
  | materialize v p rest clean queued => exact materialize_inv w v p rest inv clean queued
  | crash v => exact crash_inv w v inv
  | probe v voter _ ready => exact probe_inv w v inv voter ready
  | answerProbe v c campaign granted _ _ ready =>
    exact answerProbe_inv w v c campaign granted inv ready
  | preVoteReply v c term campaign granted _ _ ready =>
    exact preVoteReply_inv w v c term campaign granted inv ready

theorem reachable_inv {w : World} (reachable : Reachable w) : Inv w := by
  induction reachable with
  | initial voters unique => exact initial_inv voters unique
  | step _ step ih => exact step_inv ih step

/-- Election safety for the fixed-membership engine: across every admissible
    finite history (arbitrary message loss, duplication and reordering, and
    crashes at any point, including between a durable save and its
    acknowledgment), at most one node is ever elected leader in a given term. -/
theorem election_safety {w : World} (reachable : Reachable w) (t a b : Nat)
    (first second : List Node) (electedA : (t, a, first) ∈ w.elected)
    (electedB : (t, b, second) ∈ w.elected) : a = b :=
  unique_leader w (reachable_inv reachable) t a b first second electedA electedB

/-! ### Satisfiability witness: a three-voter election through real messages -/

def w0 : World := initial [0, 1, 2]
def w1 : World := campaign w0 0
def w2 : World := persist w1 0
def w3 : World := materialize w2 0 (.vote 1) [.vote 2]
def w3' : World := materialize w3 0 (.vote 2) []
def w4 : World := { w3' with nodes := set w3'.nodes 1 (handleVote (w3'.nodes 1) 0 1 true) }
def w5 : World := persist w4 1
def w6 : World := materialize w5 1 (.voted 0 true) []
def w7 : World := handleVoted w6 0 1 1 true

theorem three_voter_election : Reachable w7 ∧ (1, 0, [0, 1]) ∈ w7.elected := by
  have r0 : Reachable w0 := .initial [0, 1, 2] (by decide)
  have r1 : Reachable w1 := .step r0 (.timeout w0 0 (by decide) (by decide) ⟨rfl, rfl⟩)
  have r2 : Reachable w2 := .step r1 (.persist w1 0 rfl)
  have r3 : Reachable w3 := .step r2 (.materialize w2 0 (.vote 1) [.vote 2] rfl rfl)
  have r3' : Reachable w3' := .step r3 (.materialize w3 0 (.vote 2) [] rfl rfl)
  have r4 : Reachable w4 := .step r3' (.requestVote w3' 1 0 1 true (by decide) (by decide) ⟨rfl, rfl⟩)
  have r5 : Reachable w5 := .step r4 (.persist w4 1 rfl)
  have r6 : Reachable w6 := .step r5 (.materialize w5 1 (.voted 0 true) [] rfl rfl)
  have r7 : Reachable w7 := .step r6 (.voteReply w6 0 1 1 true (by decide) (by decide) ⟨rfl, rfl⟩)
  exact ⟨r7, by decide⟩

/-- The dynamic engine's path: a pre-vote probe gathers a quorum of grants,
    starts the real campaign, and the campaign wins through real votes. -/
def d0 : World := initial [0, 1, 2]
def d1 : World := probe d0 0
def d2 : World := materialize d1 0 (.prevote 1 1) [.prevote 2 1]
def d3 : World := materialize d2 0 (.prevote 2 1) []
def d4 : World := { d3 with nodes := (set d3.nodes 1 ({ d3.nodes 1 with outbox := [.prevoted 0 1 true] })) }
def d5 : World := materialize d4 1 (.prevoted 0 1 true) []
def d6 : World := handlePreVoted d5 0 1 0 1 true
def d7 : World := persist d6 0
def d8 : World := materialize d7 0 (.vote 1) [.vote 2]
def d9 : World := materialize d8 0 (.vote 2) []
def d10 : World := { d9 with nodes := set d9.nodes 1 (handleVote (d9.nodes 1) 0 1 true) }
def d11 : World := persist d10 1
def d12 : World := materialize d11 1 (.voted 0 true) []
def d13 : World := handleVoted d12 0 1 1 true

theorem prevote_election : Reachable d13 ∧ (1, 0, [0, 1]) ∈ d13.elected := by
  have r0 : Reachable d0 := .initial [0, 1, 2] (by decide)
  have r1 : Reachable d1 := .step r0 (.probe d0 0 (by decide) (by decide) ⟨rfl, rfl⟩)
  have r2 : Reachable d2 := .step r1 (.materialize d1 0 (.prevote 1 1) [.prevote 2 1] rfl rfl)
  have r3 : Reachable d3 := .step r2 (.materialize d2 0 (.prevote 2 1) [] rfl rfl)
  have r4 : Reachable d4 := .step r3 (.answerProbe d3 1 0 1 true (by decide) (by decide) ⟨rfl, rfl⟩)
  have r5 : Reachable d5 := .step r4 (.materialize d4 1 (.prevoted 0 1 true) [] rfl rfl)
  have r6 : Reachable d6 := .step r5 (.preVoteReply d5 0 1 0 1 true (by decide) (by decide) ⟨rfl, rfl⟩)
  have r7 : Reachable d7 := .step r6 (.persist d6 0 rfl)
  have r8 : Reachable d8 := .step r7 (.materialize d7 0 (.vote 1) [.vote 2] rfl rfl)
  have r9 : Reachable d9 := .step r8 (.materialize d8 0 (.vote 2) [] rfl rfl)
  have r10 : Reachable d10 := .step r9 (.requestVote d9 1 0 1 true (by decide) (by decide) ⟨rfl, rfl⟩)
  have r11 : Reachable d11 := .step r10 (.persist d10 1 rfl)
  have r12 : Reachable d12 := .step r11 (.materialize d11 1 (.voted 0 true) [] rfl rfl)
  have r13 : Reachable d13 := .step r12 (.voteReply d12 0 1 1 true (by decide) (by decide) ⟨rfl, rfl⟩)
  exact ⟨r13, by decide⟩

end Jarl.ElectionSafety
