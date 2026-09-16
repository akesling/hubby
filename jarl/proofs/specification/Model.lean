/- M0 specification and satisfiability witnesses. This is NOT the generated
   implementation transition system. Source refinement is an M1–M6 obligation. -/
namespace Jarl.Specification

abbrev Identity := Fin (2^64)
abbrev Counter := Fin (2^64)

structure Membership where
  voters : List Identity
  oldVoters : List Identity
  learners : List Identity
  deriving DecidableEq

/-- Old voters may also be target learners during demotion. -/
def Membership.Valid (maxPeers : Nat) (m : Membership) : Prop :=
  m.voters ≠ [] ∧ m.voters.Nodup ∧ m.oldVoters.Nodup ∧ m.learners.Nodup ∧
  (∀ id ∈ m.learners, id ∉ m.voters) ∧
  (m.voters ++ m.oldVoters ++ m.learners).eraseDups.length ≤ maxPeers

structure Genesis (maxPeers : Nat) where
  clusterNamespace : Nat
  membership : Membership
  valid : membership.Valid maxPeers
  stable : membership.oldVoters = []

structure LogId where
  term : Counter
  index : Counter
  deriving DecidableEq
structure Entry (Value : Type) where
  id : LogId
  value : Value
structure Snapshot (Value : Type) where
  boundary : LogId
  value : Value
  membership : Membership
structure Durable (Value State : Type) where
  term : Counter
  vote : Option Identity
  commit : Counter
  entries : List (Entry Value)
  snapshot : Option (Snapshot State)

def emptyDurable : Durable Value State := ⟨0, none, 0, [], none⟩

inductive Engine where | fixed | dynamic
  deriving DecidableEq

structure Settings where
  heartbeat : Counter
  election : Counter
  seed : Counter

def Settings.Valid (s : Settings) : Prop :=
  0 < s.heartbeat.val ∧ s.heartbeat.val < s.election.val ∧
  s.election.val ≤ (2^64-1)/2

def minimumCapacity : Engine → Nat
  | .fixed => 1
  | .dynamic => 4
inductive Role where | follower | candidate | leader

/-- Transaction identity is local to a lifetime identity. The checkpoint denotes
    the exact result of applying Write's snapshot/truncate/append/hard ordering.
    Proving that interpretation against Write is an M1/M5 obligation. -/
structure Transaction (Value State : Type) where
  sequence : Nat
  checkpoint : Durable Value State

structure Host (Value State : Type) where
  durable : Durable Value State
  pending : Option (Transaction Value State)
  borrowed : Bool
  completed : Bool

def freshHost : Host Value State := ⟨emptyDurable, none, false, false⟩

inductive HostEvent where
  | stage | beginSave | pollPending | durableComplete | acknowledge
  | saveError | cancel | crash | restart
  deriving DecidableEq

/-- A serial host witness. Ambiguous completion is represented by complete
    followed by error/cancel/crash; none of those events rolls durability back.
    This witness has no background writer, so cancellation is immediately quiescent. -/
inductive HostStep : Host Value State → HostEvent → Host Value State → Prop where
  | stage (h) (tx) (idle : h.pending = none) (free : h.borrowed = false) :
      HostStep h .stage {h with pending := some tx, completed := false}
  | beginSave (h) (tx) (pending : h.pending = some tx) (free : h.borrowed = false) :
      HostStep h .beginSave {h with borrowed := true}
  | pollPending (h) (borrowed : h.borrowed = true) : HostStep h .pollPending h
  | complete (h) (tx) (pending : h.pending = some tx) (borrowed : h.borrowed = true) :
      HostStep h .durableComplete {h with durable := tx.checkpoint, completed := true}
  | acknowledge (h) (tx) (pending : h.pending = some tx) (borrowed : h.borrowed = true)
      (completed : h.completed = true) (exact : h.durable = tx.checkpoint) :
      HostStep h .acknowledge {h with pending := none, borrowed := false, completed := false}
  | error (h) (borrowed : h.borrowed = true) :
      HostStep h .saveError {h with borrowed := false}
  | cancel (h) (borrowed : h.borrowed = true) :
      HostStep h .cancel {h with borrowed := false}
  | crash (h) : HostStep h .crash {h with pending := none, borrowed := false, completed := false}
  | restart (h) (idle : h.pending = none) (free : h.borrowed = false) : HostStep h .restart h

inductive HostTrace : Host Value State → List HostEvent → Host Value State → Prop where
  | nil (h) : HostTrace h [] h
  | cons : HostStep h event h' → HostTrace h' events h'' → HostTrace h (event :: events) h''

structure Local (Value State : Type) where
  identity : Identity
  engine : Engine
  capacity : Nat
  settings : Settings
  role : Role
  volatile : Durable Value State
  host : Host Value State
  effective : Membership
  committed : Membership
  applied : List (Entry Value)
  outboxDescriptors : List Nat
  online : Bool

/-- A model message is tagged with its immutable emission identity. Message
    content/variant interpretation will be linked to generated Rust transitions. -/
structure Emission (Message : Type) where
  sender : Identity
  recipient : Identity
  content : Message

structure World (Value State Message : Type) (maxPeers : Nat) where
  genesis : Genesis maxPeers
  wordBits : Nat
  nodes : List (Local Value State)
  issuedIdentities : List Identity
  emissions : List (Emission Message)
  network : List Nat
  inboxes : List (Identity × Nat)
  time : Nat

/-- All finite configurations and histories, rather than a fixed three-node set.
    The model explicitly allows future identities beyond currently occupied slots. -/
def initialWorld (g : Genesis maxPeers) (owners : List Identity)
    (capacity : Identity → Nat) (settings : Identity → Settings) (wordBits : Nat)
    (engine : Engine) : World Value State Message maxPeers :=
  { genesis := g
    wordBits := wordBits
    nodes := owners.map fun id =>
      ⟨id, engine, capacity id, settings id, .follower, emptyDurable, freshHost,
        g.membership, g.membership, [], [], true⟩
    issuedIdentities := owners
    emissions := []
    network := []
    inboxes := []
    time := 0 }

/-- Engine-specific initialization boundaries match Node::new/Cluster::new.
    Different owners may have different capacities, timers and jitter seeds.
    Dynamic passive joiners need not fit the current membership or vote in it. -/
def Admissible (g : Genesis maxPeers) (owners : List Identity)
    (capacity : Identity → Nat) (settings : Identity → Settings) (wordBits : Nat)
    (engine : Engine) : Prop :=
  owners.Nodup ∧ (wordBits = 32 ∨ wordBits = 64) ∧ maxPeers < 2^wordBits ∧
  (∀ id ∈ g.membership.voters, id ∈ owners) ∧
  (∀ id ∈ owners, minimumCapacity engine ≤ capacity id ∧ capacity id < 2^wordBits ∧
    (settings id).Valid) ∧
  (engine = .fixed → g.membership.learners = [] ∧ g.membership.voters.length = maxPeers ∧
    ∀ id ∈ owners, id ∈ g.membership.voters)

def Initial (w : World Value State Message maxPeers) : Prop :=
  ∃ owners capacity settings engine,
    Admissible w.genesis owners capacity settings w.wordBits engine ∧
    w = initialWorld w.genesis owners capacity settings w.wordBits engine

/-- Events that the subsequent source refinement must cover, including internal
    steps, callback outcomes, publication and storage's separate boundaries. -/
inductive Event (Input Message : Type) where
  | input (id : Identity) (operation : Input)
  | localStep (id : Identity)
  | callbackReturn (id : Identity)
  | callbackPanic (id : Identity)
  | unwindDrop (id : Identity)
  | abort (id : Identity)
  | host (id : Identity) (event : HostEvent)
  | materialize (emission : Emission Message)
  | deliver (emission : Nat)
  | drop (emission : Nat)
  | duplicate (emission : Nat)
  | exposeCommitted (id : Identity) (through : Counter)
  | exposeSnapshot (id : Identity) (through : Counter)
  | apply (id : Identity) (through : Counter)
  | provision (id : Identity)
  | grow (id : Identity) (capacity : Nat)
  | tick (id : Identity)

/-- Publication must later come from the generated materialization transition.
    This parameter does not assert that the emitted message contents are safe.
    Honest transport only retains the content of an actual emission. -/
inductive NetworkStep
    (publication : World Value State Message maxPeers → Emission Message → Prop) :
    World Value State Message maxPeers → Event Input Message →
      World Value State Message maxPeers → Prop where
  | publish (w) (emission) (produced : publication w emission) :
      NetworkStep publication w (.materialize emission)
        {w with emissions := w.emissions ++ [emission], network := w.network ++ [w.emissions.length]}
  | deliver (w) (index) (emission) (queued : index ∈ w.network)
      (origin : w.emissions[index]? = some emission) :
      NetworkStep publication w (.deliver index)
        {w with network := w.network.erase index, inboxes := w.inboxes ++ [(emission.recipient, index)]}
  | drop (w) (index) (queued : index ∈ w.network) :
      NetworkStep publication w (.drop index) {w with network := w.network.erase index}
  | replay (w) (index) (emission) (origin : w.emissions[index]? = some emission) :
      NetworkStep publication w (.duplicate index) {w with network := w.network ++ [index]}

theorem delivery_has_emission
    (publication : World Value State Message maxPeers → Emission Message → Prop)
    (w w' : World Value State Message maxPeers) (index : Nat)
    (step : NetworkStep (Input := Input) publication w (.deliver index) w') :
    ∃ emission, w.emissions[index]? = some emission ∧
      (emission.recipient, index) ∈ w'.inboxes := by
  cases step
  rename_i emission queued origin
  exact ⟨emission, origin, by simp⟩

theorem replay_has_emission
    (publication : World Value State Message maxPeers → Emission Message → Prop)
    (w w' : World Value State Message maxPeers) (index : Nat)
    (step : NetworkStep (Input := Input) publication w (.duplicate index) w') :
    ∃ emission, w.emissions[index]? = some emission := by
  cases step
  rename_i emission origin
  exact ⟨emission, origin⟩

theorem network_keeps_local_state
    (publication : World Value State Message maxPeers → Emission Message → Prop)
    (w w' : World Value State Message maxPeers) (event : Event Input Message)
    (step : NetworkStep publication w event w') : w'.nodes = w.nodes := by
  cases step <;> rfl

/-- External scheduling opportunities for a singleton deployment. The seven
    slots are tick, save/poll, drain output, deliver queued messages, apply,
    retry a pending client command, and resume an administrative operation.
    An empty queue permits a no-op. A slot never assumes successful election,
    commitment, or an enabled protocol transition. -/
abbrev Service := Fin 7

def cyclicServices (time : Nat) : Service := ⟨time % 7, Nat.mod_lt _ (by decide)⟩

def TimelyServices (schedule : Nat → Service) : Prop :=
  ∀ time service, ∃ next, time ≤ next ∧ next < time + 14 ∧ schedule next = service

/-- Every service gets a bounded opportunity regardless of the starting phase.
    This is a constructive external schedule, not a liveness proof for Rust. -/
theorem timely_schedule_witness : TimelyServices cyclicServices := by
  intro time service
  refine ⟨7 * (time / 7 + 1) + service.val, ?_, ?_, ?_⟩
  · have bound := service.isLt
    omega
  · have bound := service.isLt
    omega
  · apply Fin.ext
    simp [cyclicServices, Nat.add_mod, Nat.mod_eq_of_lt service.isLt]

/-- Required root interface, not an axiom or an established implementation fact.
    Observations include outcomes/errors and ordered emitted outputs. -/
structure Refinement (Concrete Abstract Event Observation : Type) where
  concreteInit : Concrete → Prop
  abstractInit : Abstract → Prop
  concreteStep : Concrete → Event → Concrete → Prop
  abstractSteps : Abstract → Event → Abstract → Prop
  relation : Concrete → Abstract → Prop
  concreteObserve : Concrete → Observation
  abstractObserve : Abstract → Observation
  initial : ∀ c, concreteInit c → ∃ a, abstractInit a ∧ relation c a
  simulation : ∀ c a event c', relation c a → concreteStep c event c' →
    ∃ a', abstractSteps a event a' ∧ relation c' a'
  observations : ∀ c a, relation c a → concreteObserve c = abstractObserve a

/-- Initial deployments exist for every supplied valid genesis, distinct owner
    population covering voters, admissible capacity, and either public engine. -/
theorem genesis_witness (g : Genesis maxPeers) (owners : List Identity)
    (capacity : Identity → Nat) (settings : Identity → Settings) (wordBits : Nat)
    (engine : Engine) (admissible : Admissible g owners capacity settings wordBits engine) :
    Initial (initialWorld (Value := Value) (State := State) (Message := Message)
      g owners capacity settings wordBits engine) := by
  exact ⟨owners, capacity, settings, engine, admissible, rfl⟩

theorem genesis_owners (g : Genesis maxPeers) (owners : List Identity)
    (capacity : Identity → Nat) (settings : Identity → Settings) (wordBits : Nat)
    (engine : Engine) :
    ((initialWorld (Value := Value) (State := State) (Message := Message)
      g owners capacity settings wordBits engine).nodes.map Local.identity) = owners := by
  simp [initialWorld, Function.comp_def]

theorem initial_unique_owners (w : World Value State Message maxPeers)
    (initial : Initial w) : (w.nodes.map Local.identity).Nodup := by
  rcases initial with ⟨owners, capacity, settings, engine, admissible, equal⟩
  rw [equal]
  simpa only [genesis_owners] using admissible.1

theorem empty_voters_rejected (maxPeers : Nat) (old learners : List Identity) :
    ¬ Membership.Valid maxPeers ⟨[], old, learners⟩ := by
  simp [Membership.Valid]

def singletonGenesis : Genesis 1 :=
  ⟨0, ⟨[0], [], []⟩, by simp [Membership.Valid]; decide, rfl⟩

def defaultSettings : Settings := ⟨2, 10, 1⟩

theorem concrete_genesis_witness (engine : Engine) :
    Initial (initialWorld (Value := Unit) (State := Unit) (Message := Unit)
      singletonGenesis [0] (fun _ => 4) (fun _ => defaultSettings) 32 engine) := by
  apply genesis_witness
  cases engine <;> simp [Admissible, singletonGenesis, minimumCapacity, defaultSettings, Settings.Valid] <;> decide

theorem fixed_minimum_capacity_witness :
    Initial (initialWorld (Value := Unit) (State := Unit) (Message := Unit)
      singletonGenesis [0] (fun _ => 1) (fun _ => defaultSettings) 32 .fixed) := by
  apply genesis_witness
  simp [Admissible, singletonGenesis, minimumCapacity, defaultSettings, Settings.Valid]
  decide

theorem dynamic_minimum_capacity_rejection :
    ¬ Admissible singletonGenesis [0] (fun _ => 1) (fun _ => defaultSettings) 32 .dynamic := by
  simp [Admissible, minimumCapacity]

/-- In a singleton genesis the scheduler can always give the sole voter an
    uncontested opportunity. Eligibility beyond this fresh empty-log witness
    must be derived from the generated election transitions, not assumed here. -/
def singletonCandidate (_time : Nat) : Identity := 0

theorem candidate_schedule_witness (time : Nat) :
    singletonCandidate time ∈ singletonGenesis.membership.voters := by
  simp [singletonCandidate, singletonGenesis]

/-- A real save can complete and be acknowledged for any transaction contents.
    This excludes contradictory durability/token premises at specification level. -/
theorem save_witness (d : Durable Value State) (tx : Transaction Value State) :
    HostTrace ⟨d, none, false, false⟩ [.stage, .beginSave, .durableComplete, .acknowledge]
      ⟨tx.checkpoint, none, false, false⟩ := by
  exact .cons (.stage _ tx rfl rfl)
    (.cons (.beginSave _ tx rfl rfl)
      (.cons (.complete _ tx rfl rfl)
        (.cons (.acknowledge _ tx rfl rfl rfl rfl) (.nil _))))

theorem pending_witness (d : Durable Value State) (tx : Transaction Value State) :
    HostTrace ⟨d, some tx, true, false⟩ [.pollPending, .durableComplete, .acknowledge]
      ⟨tx.checkpoint, none, false, false⟩ := by
  exact .cons (.pollPending _ rfl) (.cons (.complete _ tx rfl rfl)
    (.cons (.acknowledge _ tx rfl rfl rfl rfl) (.nil _)))

theorem ambiguous_crash_witness (d : Durable Value State) (tx : Transaction Value State) :
    HostTrace ⟨d, some tx, true, false⟩ [.durableComplete, .crash, .restart]
      ⟨tx.checkpoint, none, false, false⟩ := by
  exact .cons (.complete _ tx rfl rfl) (.cons (.crash _)
    (.cons (.restart _ rfl rfl) (.nil _)))

theorem cancellation_witness (d : Durable Value State) (tx : Transaction Value State) :
    HostTrace ⟨d, some tx, true, false⟩ [.cancel, .beginSave, .durableComplete, .acknowledge]
      ⟨tx.checkpoint, none, false, false⟩ := by
  exact .cons (.cancel _ rfl) (.cons (.beginSave _ tx rfl rfl)
    (.cons (.complete _ tx rfl rfl) (.cons (.acknowledge _ tx rfl rfl rfl rfl) (.nil _))))

theorem ack_requires_durable (h h' : Host Value State)
    (step : HostStep h .acknowledge h') :
    ∃ tx, h.pending = some tx ∧ h.completed = true ∧ h.durable = tx.checkpoint := by
  cases step with
  | acknowledge tx pending _ completed durable => exact ⟨tx, pending, completed, durable⟩

theorem crash_preserves_durable (h h' : Host Value State)
    (step : HostStep h .crash h') : h'.durable = h.durable := by
  cases step
  rfl

end Jarl.Specification
