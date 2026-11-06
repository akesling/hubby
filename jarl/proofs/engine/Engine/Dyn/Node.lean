import Engine.Dyn.GhostFacts
import Engine.Dyn.Util

/-!
# Nodes of the dynamic engine

A `Cluster` wraps a `Node` over `Record`s whose membership hooks read the
configuration of a `Configuration` record and of a `Checkpoint` snapshot
(`hooksC`). `DynOk` collects the facts every such node satisfies: the hooks,
the genesis configuration as bootstrap, its identity, timer bounds, the log
representation, and the peer slots (each identity in at most one slot, every
member of the current configuration in some slot, `local` the slot of the
node's own identity or `MAX` when it has none).

`membership_at` folds the configuration records of the retained log over the
snapshot's configuration (`memAt`).
-/

set_option linter.unusedSectionVars false

namespace Jarl.Engine.Dyn
open Jarl Jarl.Engine

variable {V S : Type} {MAX CAP : Nat} [Rust.Clone V] [Rust.Clone S]

/-- A node of the dynamic engine. -/
abbrev DNode (V S : Type) (MAX CAP : Nat) := Node (Record V MAX) (Checkpoint S MAX) MAX CAP

/-- Its checkpoints and messages. -/
abbrev DState (V S : Type) (MAX CAP : Nat) := State (Record V MAX) (Checkpoint S MAX) CAP
abbrev DEnv (V S : Type) (MAX : Nat) := Envelope (Record V MAX) (Checkpoint S MAX)
abbrev DMsg (V S : Type) (MAX : Nat) := Message (Record V MAX) (Checkpoint S MAX)
abbrev DEntry (V : Type) (MAX : Nat) := Entry (Record V MAX)

/-- The membership hooks `Cluster::new` installs. -/
def hooksC : MembershipHooks (Record V MAX) (Checkpoint S MAX) MAX :=
  { record := (fun x0 => pure ((fun record => (match record with | Record.Configuration m => some m | _ => none)) x0)),
    snapshot := (fun x0 => pure ((fun snapshot => snapshot.membership) x0)) }

/-- The configuration and position `membership_at` starts from: the snapshot's, else the bootstrap's. -/
def memInit (s : DState V S MAX CAP) (b : Membership MAX) : Rust.u64 × Membership MAX :=
  match s.snapshot with
  | some sn => (sn.last.index, sn.value.membership)
  | none => (0, b)

/-- One retained entry of the fold: a configuration record replaces the result. -/
def memStep (r : Rust.u64 × Membership MAX) (e : DEntry V MAX) : Rust.u64 × Membership MAX :=
  match recCfg e.value with
  | some m => (e.id.index, m)
  | none => r

/-- `membership_at(i)`: the last configuration at or before `i` and its position. -/
def memAt (s : DState V S MAX CAP) (b : Membership MAX) (i : Rust.u64) : Rust.u64 × Membership MAX :=
  ((ret s).takeWhile (fun e => decide (e.id.index ≤ i))).foldl memStep (memInit s b)

theorem record_hook (v : Option (Record V MAX)) :
    Rust.Option.and_thenM v (hooksC (S := S)).record = pure (recCfg v) := by
  rcases v with _ | (_ | _) <;> rfl

theorem membership_at_eq (n : DNode V S MAX CAP) (hh : n.hooks = some hooksC) (hl : Layout n.state) (i : Rust.u64) :
    Node.membership_at n i = pure (memAt n.state n.bootstrap i) := by
  unfold Node.membership_at
  simp only [hh, pure_bind, entries_fn_eq _ hl.1]
  have hinit : Rust.Option.map_orM (State.snapshot_fn n.state) (0, n.bootstrap)
      (fun s => do let t2 ← (hooksC (S := S) (V := V) (MAX := MAX)).snapshot s.value; pure (s.last.index, t2)) =
      pure (memInit n.state n.bootstrap) := by
    unfold memInit State.snapshot_fn; cases n.state.snapshot <;> rfl
  rw [hinit, pure_bind, bind_pure]
  unfold memAt
  rw [← forIn_fold]
  congr 1
  funext e r
  rw [record_hook]
  simp only [pure_bind, memStep]
  cases recCfg e.value <;> rfl

theorem memStep_snd (r : Rust.u64 × Membership MAX) (e : DEntry V MAX) :
    (memStep r e).2 = (recCfg e.value).getD r.2 := by
  unfold memStep; cases recCfg e.value <;> rfl

theorem foldl_memStep_snd (l : List (DEntry V MAX)) (r : Rust.u64 × Membership MAX) :
    (l.foldl memStep r).2 = cfgOf r.2 l := by
  induction l generalizing r with
  | nil => rfl
  | cons e l ih => simp only [List.foldl_cons, ih, memStep_snd]; rfl

/-- The configuration `membership_at` reports. -/
theorem memAt_snd (s : DState V S MAX CAP) (b : Membership MAX) (i : Rust.u64) :
    (memAt s b i).2 = cfgOf (memInit s b).2 ((ret s).takeWhile (fun e => decide (e.id.index ≤ i))) :=
  foldl_memStep_snd _ _

/-- The snapshot's configuration, else the bootstrap's. -/
def snapMem (s : DState V S MAX CAP) (b : Membership MAX) : Membership MAX := (memInit s b).2

/-- A node's own configuration: the configuration of its whole retained log. -/
def memOf (s : DState V S MAX CAP) (b : Membership MAX) : Membership MAX := cfgOf (snapMem s b) (ret s)

theorem takeWhile_all {α : Type} (l : List α) (p : α → Bool) (h : ∀ x ∈ l, p x = true) : l.takeWhile p = l := by
  induction l with
  | nil => rfl
  | cons x xs ih => simp [h x (by simp), ih (fun y hy => h y (by simp [hy]))]

/-- `membership_at(last)` is the node's own configuration. -/
theorem memAt_last (s : DState V S MAX CAP) (b : Membership MAX) (hc : Contig s) :
    (memAt s b (lastId s).index).2 = memOf s b := by
  rw [memAt_snd]
  unfold memOf snapMem
  congr 1
  apply takeWhile_all
  intro e he
  simp only [decide_eq_true_eq]
  obtain ⟨k, hk, rfl⟩ := List.getElem_of_mem he
  rw [Fin.le_def, lastId_eq s hc, hc k hk]
  omega

/-- Facts every node of the dynamic engine satisfies. -/
structure DynOk (g : Membership MAX) (me : Id) (n : DNode V S MAX CAP) : Prop where
  n_pos : 0 < MAX
  n_lt : MAX < 2 ^ (Rust.usizeBits - 1)
  cap_ge : 4 ≤ CAP
  cap_lt : CAP < 2 ^ (Rust.usizeBits - 1)
  hooks : n.hooks = some hooksC
  bootstrap : n.bootstrap = g
  id : n.config.id = me
  heartbeat : 0 < n.config.heartbeat_ticks.val
  election : n.config.heartbeat_ticks.val < n.config.election_ticks.val
  election_le : n.config.election_ticks.val ≤ 2 ^ 63
  layout : Layout n.state
  contig : Contig n.state
  membership : n.membership = memOf n.state g
  peers_nodup : ∀ i j (hi : i < MAX) (hj : j < MAX) (x : Id), n.peers[i] = some x → n.peers[j] = some x → i = j
  members : ∀ id, Membership.contains n.membership id = true → ∃ i, ∃ hi : i < MAX, n.peers[i] = some id
  local_le : n.local.val ≤ MAX
  local_slot : ∀ i (hi : i < MAX), n.peers[i] = some me ↔ i = n.local.val
  prevoting : ∀ t, n.prevoting = some t → n.role = .Follower ∧ t.val = n.state.hard.term.val + 1

end Jarl.Engine.Dyn
