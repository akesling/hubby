import Engine.Dyn.Common

/-!
# Growing the log capacity

`State::grow`, `Node::grow` and `Cluster::grow` move a checkpoint, node or
cluster to a capacity `NEW ≥ CAP` (a compile-time requirement in Rust, a
hypothesis here). Growth keeps everything observable except the capacity:
the retained entries, the snapshot, the hard state and every field of the
node, so the log facts (`Layout`, `Contig`, `fullLog`, `lastId`, `memOf`,
`StateOk`, `SnapOk`), `DynOk` and the world invariant `Inv` all carry over
to the grown world (`inv_grown`).
-/

set_option linter.unusedSectionVars false

namespace Jarl.Engine.Dyn
open Jarl Jarl.Engine

section StateGrow
variable {V S : Type} {CAP : Nat}

/-- Slot `i` after growing: the old slot below `len`, else empty. -/
def growSlot (s : State V S CAP) (i : Nat) : Option (Entry V) :=
  if i < s.len.val then s.entries.toList.getD i none else none

/-- The checkpoint `State::grow` produces. -/
def grownState (NEW : Nat) (s : State V S CAP) : State V S NEW :=
  { hard := s.hard, snapshot := s.snapshot,
    entries := ⟨((List.range NEW).map (growSlot s)).toArray, by simp⟩, len := s.len }

@[simp] theorem grownState_hard (NEW : Nat) (s : State V S CAP) : (grownState NEW s).hard = s.hard := rfl
@[simp] theorem grownState_snapshot (NEW : Nat) (s : State V S CAP) :
    (grownState NEW s).snapshot = s.snapshot := rfl
@[simp] theorem grownState_len (NEW : Nat) (s : State V S CAP) : (grownState NEW s).len = s.len := rfl
@[simp] theorem grownState_base (NEW : Nat) (s : State V S CAP) : (grownState NEW s).base = s.base := rfl

/-- A loop over `List.range n` whose body yields `step` while an invariant `P` holds. -/
theorem grow_forIn_range {β : Type} (n : Nat) (body : Nat → β → Rust.M (ForInStep β)) (step : Nat → β → β)
    (P : Nat → β → Prop) (init : β) (h0 : P 0 init)
    (hb : ∀ i st, i < n → P i st → body i st = pure (.yield (step i st)) ∧ P (i + 1) (step i st)) :
    ∃ st, forIn (List.range n) init body = pure st ∧ P n st := by
  rw [List.range_eq_range']
  suffices h : ∀ m j st, j + m = n → P j st → ∃ st', forIn (List.range' j m) st body = pure st' ∧ P n st' from
    h n 0 init (by omega) h0
  intro m
  induction m with
  | zero => intro j st hj hp; exact ⟨st, rfl, by rw [← hj]; simpa using hp⟩
  | succ m ih =>
    intro j st hj hp
    obtain ⟨hbody, hp'⟩ := hb j st (by omega) hp
    rw [List.range'_succ, List.forIn_cons, hbody, pure_bind]
    exact ih (j + 1) _ (by omega) hp'

/-- A loop over `List.range n` with invariant `P`, followed by a continuation. -/
theorem grow_forIn_bind {β γ : Type} (n : Nat) (body : Nat → β → Rust.M (ForInStep β)) (step : Nat → β → β)
    (P : Nat → β → Prop) (init : β) (rest : β → Rust.M γ) (r : γ) (h0 : P 0 init)
    (hb : ∀ i st, i < n → P i st → body i st = pure (.yield (step i st)) ∧ P (i + 1) (step i st))
    (hr : ∀ st, P n st → rest st = pure r) : (forIn (List.range n) init body >>= rest) = pure r := by
  obtain ⟨st, h1, h2⟩ := grow_forIn_range n body step P init h0 hb
  rw [h1, pure_bind]; exact hr st h2

theorem growSlot_lt (s : State V S CAP) (i : Nat) (hi : i < s.len.val) (hc : i < CAP) :
    growSlot s i = s.entries[i] := by
  simp [growSlot, hi, List.getD_eq_getElem?_getD, hc]

/-- `State::grow` at a larger capacity, from a layout's `len ≤ CAP`. -/
theorem state_grow_eq (NEW : Nat) (s : State V S CAP) (hCN : CAP ≤ NEW) (hN : NEW < 2 ^ Rust.usizeBits)
    (hl : s.len.val ≤ CAP) : State.grow s = pure (grownState NEW s) := by
  unfold State.grow
  have hif : (!decide (Rust.usizeOf NEW ≥ Rust.usizeOf CAP)) = false := by
    simp only [Bool.not_eq_false', decide_eq_true_eq, Fin.le_def, Rust.usizeOf, Rust.ofNat]
    rw [Nat.mod_eq_of_lt (by uomega), Nat.mod_eq_of_lt (by uomega)]; exact hCN
  simp only [hif, Bool.false_eq_true, if_false]
  refine grow_forIn_bind (β := State V S CAP × Array (Option (Entry V))) NEW _
    (fun i st => if h : i < st.1.len.val ∧ i < CAP then
        ({ hard := st.1.hard, snapshot := st.1.snapshot, entries := st.1.entries.set i none h.2, len := st.1.len }, st.2.push st.1.entries[i])
      else (st.1, st.2.push none))
    (fun j st => st.1.hard = s.hard ∧ st.1.len = s.len ∧ (∀ k (hk : k < CAP), j ≤ k → st.1.entries[k] = s.entries[k]) ∧
      st.2.toList = (List.range j).map (growSlot s))
    ({ hard := s.hard, snapshot := none, entries := s.entries, len := s.len }, #[]) _ _
    ⟨rfl, rfl, fun _ _ _ => rfl, rfl⟩ ?_ ?_
  · rintro i ⟨st1, st2⟩ hi ⟨h1, h2, h3, h4⟩
    have hiu : (Rust.usizeOf i).val = i := by
      simp only [Rust.usizeOf, Rust.ofNat]; rw [Nat.mod_eq_of_lt (by uomega)]
    by_cases hc : i < s.len.val
    · have hcap : i < CAP := by omega
      have hc' : i < st1.len.val := by rw [h2]; exact hc
      have hdec : decide (Rust.usizeOf i < st1.len) = true := by
        simp only [decide_eq_true_eq, Fin.lt_def, hiu]; exact hc'
      refine ⟨?_, ?_⟩
      · simp only [hdec, if_true, Rust.Slice.index_ok _ _ (show (Rust.usizeOf i).val < CAP by rw [hiu]; exact hcap),
          Rust.Slice.set_ok _ _ _ (show (Rust.usizeOf i).val < CAP by rw [hiu]; exact hcap), pure_bind, hiu]
        simp only [hc', hcap, and_self, dite_true]
      · simp only [hc', hcap, and_self, dite_true]
        refine ⟨h1, h2, fun k hk hik => ?_, ?_⟩
        · rw [Vector.getElem_set_ne _ _ (by omega)]; exact h3 k hk (by omega)
        · rw [Array.toList_push, h4, List.range_succ, List.map_append, h3 i hcap (Nat.le_refl _),
            ← growSlot_lt s i hc hcap]; rfl
    · have hc' : ¬ i < st1.len.val := by rw [h2]; exact hc
      have hdec : decide (Rust.usizeOf i < st1.len) = false := by
        simp only [decide_eq_false_iff_not, Fin.lt_def, hiu]; exact hc'
      refine ⟨?_, ?_⟩
      · simp only [hdec, Bool.false_eq_true, if_false, pure_bind]
        simp [hc']
      · simp only [hc', false_and, dite_false]
        refine ⟨h1, h2, fun k hk hik => h3 k hk (by omega), ?_⟩
        rw [Array.toList_push, h4, List.range_succ, List.map_append]
        simp [growSlot, hc]
  · rintro st ⟨h1, hlen, -, hacc⟩
    have hsz : st.2.size = NEW := by rw [← Array.length_toList, hacc]; simp
    simp only [Rust.Slice.ofArray, hsz, dite_true, pure_bind]
    unfold grownState
    rw [h1, hlen]
    congr 2
    apply Vector.ext
    intro i hi
    simp only [Vector.getElem_mk]
    rw [← Array.getElem_toList, ← Array.getElem_toList]
    simp only [hacc]

/-- The grown slots: the retained entries, then empty slots up to `NEW`. -/
theorem grownState_slots (NEW : Nat) (s : State V S CAP) (hCN : CAP ≤ NEW) (hl : Layout s) :
    (grownState NEW s).entries.toList = (ret s).map some ++ List.replicate (NEW - s.len.val) none := by
  obtain ⟨hle, hs⟩ := hl
  have hlen : (ret s).length = s.len.val := by
    have := congrArg List.length hs
    simp only [Vector.length_toList, List.length_append, List.length_map, List.length_replicate] at this
    omega
  show ((List.range NEW).map (growSlot s)) = _
  apply List.ext_getElem
  · simp; omega
  · intro i h1 h2
    simp only [List.getElem_map, List.getElem_range]
    by_cases hi : i < s.len.val
    · rw [List.getElem_append_left (by simp; omega)]
      unfold growSlot
      simp only [hi, if_true, List.getD_eq_getElem?_getD, hs]
      rw [List.getElem?_append_left (by simp; omega)]
      simp [List.getElem?_eq_getElem (show i < (ret s).length by omega)]
    · rw [List.getElem_append_right (by simp; omega)]
      simp [growSlot, hi]

/-- Growing keeps the layout, now at `NEW`, and the retained entries. -/
theorem grownState_layout_ret (NEW : Nat) (s : State V S CAP) (hCN : CAP ≤ NEW) (hl : Layout s) :
    Layout (grownState NEW s) ∧ ret (grownState NEW s) = ret s := by
  have hlen : (ret s).length = s.len.val := by
    have := congrArg List.length hl.2
    simp only [Vector.length_toList, List.length_append, List.length_map, List.length_replicate] at this
    have := hl.1; omega
  have := layout_of (grownState NEW s) (ret s) hlen.symm (by have := hl.1; omega)
    (by rw [grownState_slots NEW s hCN hl, hlen])
  exact this

theorem grownState_ret (NEW : Nat) (s : State V S CAP) (hCN : CAP ≤ NEW) (hl : Layout s) :
    ret (grownState NEW s) = ret s := (grownState_layout_ret NEW s hCN hl).2

theorem grownState_layout (NEW : Nat) (s : State V S CAP) (hCN : CAP ≤ NEW) (hl : Layout s) :
    Layout (grownState NEW s) := (grownState_layout_ret NEW s hCN hl).1

theorem grownState_contig (NEW : Nat) (s : State V S CAP) (hCN : CAP ≤ NEW) (hl : Layout s) (hc : Contig s) :
    Contig (grownState NEW s) := by
  unfold Contig; rw [grownState_ret NEW s hCN hl, grownState_base]; exact hc

theorem grownState_lastId (NEW : Nat) (s : State V S CAP) (hCN : CAP ≤ NEW) (hl : Layout s) :
    lastId (grownState NEW s) = lastId s := by
  unfold lastId; rw [grownState_ret NEW s hCN hl, grownState_base]

theorem grownState_fullLog {N : Nat} (G : Ghost V N) (NEW : Nat) (s : State V S CAP) (hCN : CAP ≤ NEW) (hl : Layout s) :
    fullLog G (grownState NEW s) = fullLog G s := by
  unfold fullLog; rw [grownState_ret NEW s hCN hl, grownState_base]

theorem grownState_boundary {N : Nat} (G : Ghost V N) (NEW : Nat) (s : State V S CAP) :
    boundary G (grownState NEW s) = boundary G s := by
  unfold boundary; rw [grownState_base]

/-- `StateOk` at the grown capacity. -/
theorem grownState_stateOk {N : Nat} (G : Ghost V N) (NEW : Nat) (s : State V S CAP) (hCN : CAP ≤ NEW)
    (h : StateOk G s) : StateOk G (grownState NEW s) where
  layout := grownState_layout NEW s hCN h.layout
  contig := grownState_contig NEW s hCN h.layout h.contig
  base := by rw [grownState_base]; exact h.base
  snapshot := by rw [grownState_snapshot, grownState_base]; exact h.snapshot
  terms := by rw [grownState_fullLog G NEW s hCN h.layout, grownState_hard]; exact h.terms
  commit_ge := by rw [grownState_base, grownState_hard]; exact h.commit_ge
  commit_le := by rw [grownState_lastId NEW s hCN h.layout, grownState_hard]; exact h.commit_le
  unvoted := by rw [grownState_hard]; exact h.unvoted

end StateGrow

section NodeGrow
variable {V S : Type} {N CAP : Nat}

/-- The node `Node::grow` produces: only the checkpoint changes. -/
def grownNode (NEW : Nat) (n : Node V S N CAP) : Node V S N NEW :=
  { config := n.config, state := grownState NEW n.state, role := n.role, leader := n.leader, «local» := n.«local», membership := n.membership, bootstrap := n.bootstrap, hooks := n.hooks, peers := n.peers, votes := n.votes, «next» := n.«next», matched := n.matched, outbox := n.outbox, dirty := n.dirty, log_from := n.log_from, snapshot_changed := n.snapshot_changed, elapsed := n.elapsed, election_deadline := n.election_deadline, random := n.random, prevoting := n.prevoting, leader_age := n.leader_age, quorum_elapsed := n.quorum_elapsed, active := n.active, extra_reply := n.extra_reply, request_from := n.request_from }

theorem node_grow_eq [Rust.Clone V] [Rust.Clone S] (NEW : Nat) (n : Node V S N CAP) (hCN : CAP ≤ NEW)
    (hN : NEW < 2 ^ Rust.usizeBits) (hl : n.state.len.val ≤ CAP) : Node.grow n = pure (grownNode NEW n) := by
  unfold Node.grow; rw [state_grow_eq NEW n.state hCN hN hl, pure_bind]; rfl

@[simp] theorem grownNode_state (NEW : Nat) (n : Node V S N CAP) : (grownNode NEW n).state = grownState NEW n.state := rfl
@[simp] theorem grownNode_role (NEW : Nat) (n : Node V S N CAP) : (grownNode NEW n).role = n.role := rfl
@[simp] theorem grownNode_dirty (NEW : Nat) (n : Node V S N CAP) : (grownNode NEW n).dirty = n.dirty := rfl
@[simp] theorem grownNode_local (NEW : Nat) (n : Node V S N CAP) : (grownNode NEW n).local = n.local := rfl
@[simp] theorem grownNode_peers (NEW : Nat) (n : Node V S N CAP) : (grownNode NEW n).peers = n.peers := rfl
@[simp] theorem grownNode_votes (NEW : Nat) (n : Node V S N CAP) : (grownNode NEW n).votes = n.votes := rfl
@[simp] theorem grownNode_matched (NEW : Nat) (n : Node V S N CAP) : (grownNode NEW n).matched = n.matched := rfl
@[simp] theorem grownNode_outbox (NEW : Nat) (n : Node V S N CAP) : (grownNode NEW n).outbox = n.outbox := rfl
@[simp] theorem grownNode_extra_reply (NEW : Nat) (n : Node V S N CAP) :
    (grownNode NEW n).extra_reply = n.extra_reply := rfl

end NodeGrow

section DynGrow
variable {V S : Type} {MAX CAP NEW K : Nat}

theorem grownState_snapMem (s : DState V S MAX CAP) (b : Membership MAX) :
    snapMem (grownState NEW s) b = snapMem s b := by
  unfold snapMem memInit; rw [grownState_snapshot]

theorem grownState_memOf (s : DState V S MAX CAP) (b : Membership MAX) (hCN : CAP ≤ NEW) (hl : Layout s) :
    memOf (grownState NEW s) b = memOf s b := by
  unfold memOf; rw [grownState_snapMem, grownState_ret NEW s hCN hl]

theorem grownState_snapOk (g : Membership MAX) (G : Ghost (Record V MAX) K) (s : DState V S MAX CAP)
    (h : SnapOk g G s) : SnapOk g G (grownState NEW s) := by
  unfold SnapOk; rw [grownState_snapMem, grownState_boundary]; exact h

/-- The cluster `Cluster::grow` produces. -/
def grownCluster (NEW : Nat) (c : Jarl.Cluster V S MAX CAP) : Jarl.Cluster V S MAX NEW := { node := grownNode NEW c.node }

theorem cluster_grow_eq [Rust.Clone V] [Rust.Clone S] (c : Jarl.Cluster V S MAX CAP) (hCN : CAP ≤ NEW)
    (hN : NEW < 2 ^ Rust.usizeBits) (hl : c.node.state.len.val ≤ CAP) :
    Cluster.grow c = pure (grownCluster NEW c) := by
  unfold Cluster.grow; rw [node_grow_eq NEW c.node hCN hN hl, pure_bind]; rfl

/-- A successful `Cluster::grow` is `grownCluster` (whenever the slot count fits `len`). -/
theorem cluster_grow_inv [Rust.Clone V] [Rust.Clone S] (c : Jarl.Cluster V S MAX CAP) (c' : Jarl.Cluster V S MAX NEW)
    (hCN : CAP ≤ NEW) (hN : NEW < 2 ^ Rust.usizeBits) (hl : c.node.state.len.val ≤ CAP)
    (h : Cluster.grow c = pure c') : c' = grownCluster NEW c :=
  (Rust.pure_inj ((cluster_grow_eq c hCN hN hl).symm.trans h)).symm

/-- Everything observable is kept by a successful `Cluster::grow` from a node with a valid
    log layout: the checkpoint's retained entries, base, snapshot, hard state, length and
    last identity, the layout and contiguity at `NEW`, and every other field of the node. -/
theorem cluster_grow_keeps [Rust.Clone V] [Rust.Clone S] (c : Jarl.Cluster V S MAX CAP) (c' : Jarl.Cluster V S MAX NEW)
    (hCN : CAP ≤ NEW) (hN : NEW < 2 ^ Rust.usizeBits) (hl : Layout c.node.state) (hc : Contig c.node.state)
    (h : Cluster.grow c = pure c') :
    ret c'.node.state = ret c.node.state ∧ c'.node.state.base = c.node.state.base ∧
    c'.node.state.snapshot = c.node.state.snapshot ∧ c'.node.state.hard = c.node.state.hard ∧
    c'.node.state.len = c.node.state.len ∧ lastId c'.node.state = lastId c.node.state ∧
    Layout c'.node.state ∧ Contig c'.node.state ∧
    c'.node.config = c.node.config ∧ c'.node.role = c.node.role ∧ c'.node.leader = c.node.leader ∧
    c'.node.local = c.node.local ∧ c'.node.membership = c.node.membership ∧
    c'.node.bootstrap = c.node.bootstrap ∧ c'.node.hooks = c.node.hooks ∧ c'.node.peers = c.node.peers ∧
    c'.node.votes = c.node.votes ∧ c'.node.next = c.node.next ∧ c'.node.matched = c.node.matched ∧
    c'.node.outbox = c.node.outbox ∧ c'.node.dirty = c.node.dirty ∧ c'.node.log_from = c.node.log_from ∧
    c'.node.snapshot_changed = c.node.snapshot_changed ∧ c'.node.elapsed = c.node.elapsed ∧
    c'.node.election_deadline = c.node.election_deadline ∧ c'.node.random = c.node.random ∧
    c'.node.prevoting = c.node.prevoting ∧ c'.node.leader_age = c.node.leader_age ∧
    c'.node.quorum_elapsed = c.node.quorum_elapsed ∧ c'.node.active = c.node.active ∧
    c'.node.extra_reply = c.node.extra_reply ∧ c'.node.request_from = c.node.request_from := by
  obtain rfl := cluster_grow_inv c c' hCN hN hl.1 h
  exact ⟨grownState_ret NEW _ hCN hl, rfl, rfl, rfl, rfl, grownState_lastId NEW _ hCN hl,
    grownState_layout NEW _ hCN hl, grownState_contig NEW _ hCN hl hc,
    rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl⟩

/-- `DynOk` at the grown capacity (`NEW` within the bound `DynOk` asks of a capacity). -/
theorem grownNode_dynOk [Rust.Clone V] [Rust.Clone S] {g : Membership MAX} {me : Id} (n : DNode V S MAX CAP)
    (hCN : CAP ≤ NEW) (hN : NEW < 2 ^ (Rust.usizeBits - 1)) (h : DynOk g me n) :
    DynOk g me (grownNode NEW n) where
  n_pos := h.n_pos
  n_lt := h.n_lt
  cap_ge := by have := h.cap_ge; omega
  cap_lt := hN
  hooks := h.hooks
  bootstrap := h.bootstrap
  id := h.id
  heartbeat := h.heartbeat
  election := h.election
  election_le := h.election_le
  layout := grownState_layout NEW _ hCN h.layout
  contig := grownState_contig NEW _ hCN h.layout h.contig
  membership := by
    show n.membership = memOf (grownState NEW n.state) g
    rw [grownState_memOf _ _ hCN h.layout]; exact h.membership
  peers_nodup := h.peers_nodup
  members := h.members
  local_le := h.local_le
  local_slot := h.local_slot
  prevoting := h.prevoting

/-- `DynOk` transfers through a successful `Cluster::grow`. -/
theorem cluster_grow_dynOk [Rust.Clone V] [Rust.Clone S] {g : Membership MAX} {me : Id}
    (c : Jarl.Cluster V S MAX CAP) (c' : Jarl.Cluster V S MAX NEW)
    (hCN : CAP ≤ NEW) (hN : NEW < 2 ^ (Rust.usizeBits - 1)) (h : DynOk g me c.node)
    (hg : Cluster.grow c = pure c') : DynOk g me c'.node := by
  obtain rfl := cluster_grow_inv c c' hCN (by uomega) h.layout.1 hg
  exact grownNode_dynOk c.node hCN hN h

end DynGrow

/-! ## A host that grows every node and checkpoint -/

section WorldGrow
variable {V S : Type} {MAX CAP NEW K : Nat} [Rust.Clone V] [Rust.Clone S]

/-- The world after every node and every checkpoint grew to capacity `NEW`. -/
def World.grown (NEW : Nat) (C : World V S MAX CAP K) : World V S MAX NEW K :=
  { live := fun k => grownCluster NEW (C.live k), disk := fun k => grownState NEW (C.disk k), sent := C.sent }

@[simp] theorem grown_node (C : World V S MAX CAP K) (k : Fin K) : (C.grown NEW).node k = grownNode NEW (C.node k) := rfl
@[simp] theorem grown_disk (C : World V S MAX CAP K) (k : Fin K) : (C.grown NEW).disk k = grownState NEW (C.disk k) := rfl
@[simp] theorem grown_sent (C : World V S MAX CAP K) : (C.grown NEW).sent = C.sent := rfl

variable (ids : Vector Id K) (g : Membership MAX)

theorem grown_leading (G : Ghost (Record V MAX) K) (k : Fin K) (n : DNode V S MAX CAP) :
    Leading G k (grownNode NEW n) ↔ Leading G k n := Iff.rfl

theorem grown_withOwnD (G : Ghost (Record V MAX) K) (k : Fin K) (n : DNode V S MAX CAP) (hCN : CAP ≤ NEW)
    (hn : Layout n.state) : withOwnD G k (grownNode NEW n) = withOwnD G k n := by
  unfold withOwnD; simp only [grownNode_state, grownState_hard, grownState_fullLog G NEW _ hCN hn]

theorem grown_winOwnD (G : Ghost (Record V MAX) K) (k : Fin K) (n : DNode V S MAX CAP) (eL : List (DEntry V MAX))
    (hCN : CAP ≤ NEW) (hn : Layout n.state) : winOwnD G k (grownNode NEW n) eL = winOwnD G k n eL := by
  unfold winOwnD; simp only [grownNode_state, grownState_hard, grownState_fullLog G NEW _ hCN hn]; rfl

theorem grown_pendingWin (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (k : Fin K) (n : DNode V S MAX CAP)
    (hCN : CAP ≤ NEW) (hn : Layout n.state) (hd : Layout (C.disk k)) :
    PendingWin ids g (C.grown NEW) G k (grownNode NEW n) ↔ PendingWin ids g C G k n := by
  unfold PendingWin
  simp only [grown_disk, grownNode_state, grownNode_dirty, grownNode_role, grownState_hard,
    grownState_fullLog G NEW _ hCN hn, grownState_fullLog G NEW _ hCN hd]

theorem grown_leadLog (G : Ghost (Record V MAX) K) (k : Fin K) (n : DNode V S MAX CAP)
    (hCN : CAP ≤ NEW) (hn : Layout n.state) : LeadLog ids g G k (grownNode NEW n) ↔ LeadLog ids g G k n := by
  constructor
  · intro h
    obtain ⟨h1, h2, h3, h4⟩ := h
    simp only [grownNode_state, grownNode_dirty, grownState_hard, grownState_fullLog G NEW _ hCN hn] at h1 h2 h3 h4
    exact ⟨h1, h2, h3, h4⟩
  · intro h
    obtain ⟨h1, h2, h3, h4⟩ := h
    refine ⟨?_, ?_, ?_, ?_⟩ <;>
      simp only [grownNode_state, grownNode_dirty, grownState_hard, grownState_fullLog G NEW _ hCN hn] <;> assumption

theorem grown_leaderOk (G : Ghost (Record V MAX) K) (k : Fin K) (n : DNode V S MAX CAP)
    (hCN : CAP ≤ NEW) (hn : Layout n.state) : LeaderOk' ids G k (grownNode NEW n) ↔ LeaderOk' ids G k n := by
  constructor
  · intro h
    obtain ⟨h1, h2⟩ := h
    simp only [grownNode_state, grownNode_local, grownNode_peers, grownNode_matched, grownState_hard,
      grownState_fullLog G NEW _ hCN hn] at h1 h2
    exact ⟨h1, h2⟩
  · intro h
    obtain ⟨h1, h2⟩ := h
    refine ⟨?_, ?_⟩ <;>
      simp only [grownNode_state, grownNode_local, grownNode_peers, grownNode_matched, grownState_hard,
        grownState_fullLog G NEW _ hCN hn] <;> assumption

theorem grown_candidateOk (G : Ghost (Record V MAX) K) (k : Fin K) (n : DNode V S MAX CAP)
    (hCN : CAP ≤ NEW) (hn : Layout n.state) : CandidateOk' ids G k (grownNode NEW n) ↔ CandidateOk' ids G k n := by
  unfold CandidateOk'
  simp only [grownNode_state, grownNode_local, grownNode_peers, grownNode_votes, grownState_hard,
    grownState_fullLog G NEW _ hCN hn]

theorem grown_outOk (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (k : Fin K) (to : Id) (o : Outbound)
    (hCN : CAP ≤ NEW) (hn : Layout (C.node k).state) (hd : Layout (C.disk k)) :
    OutOk ids g (C.grown NEW) G k to o ↔ OutOk ids g C G k to o := by
  unfold OutOk
  cases o with
  | Vote => simp only [grown_node, grownNode_role]
  | Voted gr => simp only [grown_node, grown_sent, grownNode_state, grownState_hard, grownState_fullLog G NEW _ hCN hn]
  | Replicated i r => simp only [grown_node, grownNode_state, grownState_hard, grownState_fullLog G NEW _ hCN hn]
  | Replicate => simp only [grown_node, grown_leading, grown_pendingWin ids g C G k _ hCN hn hd]
  | _ => exact Iff.rfl

theorem grown_sentOk (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (env : DEnv V S MAX)
    (hCN : CAP ≤ NEW) (hn : ∀ k, Layout (C.node k).state) :
    SentOk ids g (C.grown NEW) G env ↔ SentOk ids g C G env := by
  unfold SentOk
  cases env.message with
  | Vote T last =>
    simp only [grown_node, grown_disk, grownNode_state, grownNode_role, grownState_hard,
      fun k => grownState_lastId NEW (C.node k).state hCN (hn k)]
  | _ => exact Iff.rfl

theorem grown_commitOk (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (k : Fin K)
    (hCN : CAP ≤ NEW) (hn : Layout (C.node k).state) (hd : Layout (C.disk k)) :
    CommitOk' ids g (C.grown NEW) G k ((C.grown NEW).node k) ↔ CommitOk' ids g C G k (C.node k) := by
  unfold CommitOk'
  simp only [grown_node, grown_disk, grownNode_state, grownNode_dirty, grownState_hard, grown_leading,
    grown_withOwnD G k _ hCN hn, grown_winOwnD G k _ _ hCN hn, grown_pendingWin ids g C G k _ hCN hn hd,
    grownState_fullLog G NEW _ hCN hn, grownState_fullLog G NEW _ hCN hd]

/-- The invariant at capacity `NEW` for the world in which every node and checkpoint grew,
    with the same ghost history. -/
theorem inv_grown (C : World V S MAX CAP K) (G : Ghost (Record V MAX) K) (hi : Inv ids g C G)
    (hCN : CAP ≤ NEW) (hN : NEW < 2 ^ (Rust.usizeBits - 1)) : Inv ids g (C.grown NEW) G := by
  have hn : ∀ k, Layout (C.node k).state := fun k => (hi.dyn k).layout
  have hd : ∀ k, Layout (C.disk k) := fun k => (hi.disk k).1.layout
  have hFn : ∀ k, fullLog G (grownState NEW (C.node k).state) = fullLog G (C.node k).state :=
    fun k => grownState_fullLog G NEW _ hCN (hn k)
  have hFd : ∀ k, fullLog G (grownState NEW (C.disk k)) = fullLog G (C.disk k) :=
    fun k => grownState_fullLog G NEW _ hCN (hd k)
  refine
    { wf := hi.wf
      cfgs := hi.cfgs
      dyn := fun k => grownNode_dynOk _ hCN hN (hi.dyn k)
      live := fun k => ⟨grownState_stateOk G NEW _ hCN (hi.live k).1, grownState_snapOk g G _ (hi.live k).2⟩
      disk := fun k => ⟨grownState_stateOk G NEW _ hCN (hi.disk k).1, grownState_snapOk g G _ (hi.disk k).2⟩
      consistent_disk := fun k => ?_
      consistent_live := fun k => ?_
      clean := fun k => ?_
      terms := hi.terms
      disk_lead := fun k eL => ?_
      acks := fun w t j h => ?_
      ballots := hi.ballots
      ballot_unique := hi.ballot_unique
      ballot_cand := fun T w c v h => ?_
      elect := fun T c eL h => ?_
      elect_disk := hi.elect_disk
      elect_cand := hi.elect_cand
      lead := fun k => ?_
      leader := fun k => ?_
      candidate := fun k => ?_
      outbox := fun k i o => ?_
      outbox_self := hi.outbox_self
      extra := fun k to o => ?_
      sent := fun env h => ?_
      committed := fun k => ?_ }
  · simp only [grown_disk, hFd]; exact hi.consistent_disk k
  · simp only [grown_node, grownNode_state, grownNode_dirty, hFn, grown_leading,
      grown_pendingWin ids g C G k _ hCN (hn k) (hd k)]
    exact hi.consistent_live k
  · simp only [grown_node, grownNode_dirty, grownNode_state, grown_disk]
    intro h; rw [hi.clean k h]
  · simp only [grown_disk, grownState_hard, hFd]; exact hi.disk_lead k eL
  · simp only [grown_node, grown_disk, grownNode_state, grownState_hard, hFn, hFd]; exact hi.acks w t j h
  · simp only [grown_node, grownNode_state, grownNode_role, grownState_hard, hFn]; exact hi.ballot_cand T w c v h
  · simp only [grown_node, grown_disk, grownNode_state, grownNode_role, grownState_hard, hFn, hFd]
    exact hi.elect T c eL h
  · simp only [grown_node, grown_leading, grown_leadLog ids g G k _ hCN (hn k)]; exact hi.lead k
  · simp only [grown_node, grownNode_role, grown_leading, grown_pendingWin ids g C G k _ hCN (hn k) (hd k),
      grown_leaderOk ids G k _ hCN (hn k)]
    exact hi.leader k
  · simp only [grown_node, grownNode_role, grown_candidateOk ids G k _ hCN (hn k)]; exact hi.candidate k
  · simp only [grown_node, grownNode_outbox, grownNode_peers, grown_outOk ids g C G k _ _ hCN (hn k) (hd k)]
    exact hi.outbox k i o
  · simp only [grown_node, grownNode_extra_reply, grown_outOk ids g C G k _ _ hCN (hn k) (hd k)]
    exact hi.extra k to o
  · rw [grown_sentOk ids g C G env hCN hn]; exact hi.sent env h
  · rw [grown_commitOk ids g C G k hCN (hn k) (hd k)]
    simp only [grown_disk, grownState_hard, hFd]; exact hi.committed k

/-- A host that runs `Cluster::grow` on every node and `State::grow` on every checkpoint
    (sending nothing) keeps the invariant at capacity `NEW`, with the same ghost history. -/
theorem inv_of_grow (C : World V S MAX CAP K) (C' : World V S MAX NEW K) (G : Ghost (Record V MAX) K)
    (hi : Inv ids g C G) (hCN : CAP ≤ NEW) (hN : NEW < 2 ^ (Rust.usizeBits - 1))
    (hlive : ∀ k, Cluster.grow (C.live k) = pure (C'.live k)) (hdisk : ∀ k, State.grow (C.disk k) = pure (C'.disk k))
    (hsent : C'.sent = C.sent) : Inv ids g C' G := by
  have hN' : NEW < 2 ^ Rust.usizeBits := by uomega
  have hC : C' = C.grown NEW := by
    cases C'
    simp only [World.grown] at hsent ⊢
    refine (World.mk.injEq _ _ _ _ _ _).mpr ⟨funext fun k => ?_, funext fun k => ?_, hsent⟩
    · exact cluster_grow_inv _ _ hCN hN' (hi.dyn k).layout.1 (hlive k)
    · exact (Rust.pure_inj ((state_grow_eq NEW _ hCN hN' (hi.disk k).1.layout.1).symm.trans (hdisk k))).symm
  rw [hC]; exact inv_grown ids g C G hi hCN hN

end WorldGrow

end Jarl.Engine.Dyn
