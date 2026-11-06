import Engine.Host.Ops
import Contracts.Storage

/-!
# A host that persists deltas, and its refinement of the model cluster

`HCluster` is the cluster as real hosts run it: each node keeps a durable
record (`Delta.Durable`) instead of a `State`. `HAct` mirrors `Act` except:

* `persist` applies the materialized `Write` of the node's `Ready` to the
  durable record (`ready.rs`: replace the snapshot and discard through it,
  truncate, append, replace the hard state), then acknowledges it;
* `restart` rebuilds the checkpoint with `State::restore` from the durable
  record and then runs `Node::new`.

and a host may also `save` a write without acknowledging it (a cancelled
`persist_async` whose storage finished, or a save that reported an error after
writing): the record gets the write and the node stays dirty.

`Ready::write` is not part of the translation; `readyWrite` is its body,
`State::write(log_from, snapshot_changed)` of the token's node.

Every host execution is refined by a model execution with the same network,
whose checkpoint `disk k` is what restoring `durable k` yields (`refines_reach`,
`refines_steps`, `host_restore`); each host node is the model's, or saved but
unacknowledged (`Unacked`: a save is the model's `persist`, after which the
model stutters until the host acknowledges or restarts); and every reachable
host node satisfies `DeltaOk`.
-/

namespace Jarl.Engine.Host
open Jarl Jarl.Engine Jarl.Contracts.StorageView

variable {V S : Type} {N CAP : Nat}

/-! ## Restoring a durable view -/

theorem state_ext (a b : State V S CAP) (h1 : a.hard = b.hard) (h2 : a.snapshot = b.snapshot)
    (h3 : a.entries = b.entries) (h4 : a.len = b.len) : a = b := by
  cases a; cases b; simp_all

/-- Terms along a consistent log are positive and nondecreasing. -/
theorem consistent_mono {N : Nat} (G : Ghost V N) (hw : Wf G) (F : List (Entry V)) (hc : Consistent G F)
    (j k : Nat) (hjk : j ≤ k) (hk : k < F.length) :
    0 < (F[j]'(by omega)).id.term.val ∧ (F[j]'(by omega)).id.term.val ≤ F[k].id.term.val := by
  obtain ⟨-, Lk, hLk, hp⟩ := hc k hk
  have hmem : F[j]'(by omega) ∈ Lk := hp.subset (List.mem_iff_getElem.mpr ⟨j, by simp; omega, by simp⟩)
  exact (hw.leader _ Lk hLk).2.1 _ hmem

/-- A checkpoint's retained entries form a restorable chain from its boundary. -/
theorem ordered_ret {N : Nat} (G : Ghost V N) (hw : Wf G) (s : State V S CAP) (hs : StateOk G s)
    (hcons : Consistent G (fullLog G s)) :
    ∀ m (hm : m ≤ (ret s).length), Contracts.Storage.Ordered s.hard s.base ((ret s).take m)
      (if h : m = 0 then s.base else ((ret s)[m - 1]'(by omega)).id) := by
  have hFlen : (fullLog G s).length = s.base.index.val + (ret s).length := by
    rw [fullLog_length G s hs, lastId_eq s hs.contig]
  -- Entry `k` of the retained log is entry `base + k` of the full log.
  have hget : ∀ k (hk : k < (ret s).length),
      (fullLog G s)[s.base.index.val + k]'(by omega) = (ret s)[k] := by
    intro k hk
    obtain ⟨hr, he⟩ := fullLog_getElem_ret G s hs (s.base.index.val + k) (by omega) (by omega)
    rw [he]
    congr 1
    omega
  have hterm : ∀ k (hk : k < (ret s).length), 0 < ((ret s)[k]).id.term.val := by
    intro k hk
    have := (consistent_mono G hw _ hcons (s.base.index.val + k) (s.base.index.val + k) (Nat.le_refl _) (by omega)).1
    rwa [hget k hk] at this
  have hmono : ∀ j k (hjk : j ≤ k) (hk : k < (ret s).length),
      ((ret s)[j]'(by omega)).id.term.val ≤ ((ret s)[k]).id.term.val := by
    intro j k hjk hk
    have := (consistent_mono G hw _ hcons (s.base.index.val + j) (s.base.index.val + k) (by omega) (by omega)).2
    rwa [hget j (by omega), hget k hk] at this
  have hbase : s.base.term.val ≤ (if h : (ret s).length = 0 then s.base.term.val else ((ret s)[0]'(by omega)).id.term.val) := by
    split
    · exact (Nat.le_refl _)
    · rename_i hne
      by_cases h0 : s.base.index.val = 0
      · rw [base_zero G s hs h0]; exact Nat.zero_le _
      · obtain ⟨-, hl, hid⟩ := (idAt_fullLog G s hs s.base.index.val (by omega) s.base).mp (by simp [idAt])
        have := (consistent_mono G hw _ hcons (s.base.index.val - 1) (s.base.index.val + 0) (by omega) (by omega)).2
        rw [hid, hget 0 (by omega)] at this
        exact this
  intro m
  induction m with
  | zero => intro _; simpa using Contracts.Storage.Ordered.empty
  | succ m ih =>
    intro hm
    have hm' : m < (ret s).length := by omega
    have e1 : (if h : m + 1 = 0 then s.base else ((ret s)[m + 1 - 1]'(by omega)).id) = ((ret s)[m]).id := by
      simp
    rw [List.take_add_one, List.getElem?_eq_getElem hm', e1]
    simp only [Option.toList_some]
    refine Contracts.Storage.Ordered.snoc _ (ih (by omega)) ?_ (hterm m hm') ?_ ?_
    · have := hs.contig m hm'
      split
      · subst_vars; omega
      · have := hs.contig (m - 1) (by omega); omega
    · split
      · rename_i h0
        subst h0
        have := hbase
        rw [dif_neg (by omega)] at this
        exact this
      · exact hmono (m - 1) m (by omega) hm'
    · exact hs.terms _ (by
        rw [← hget m hm']
        exact List.getElem_mem _)

/-- Restoring the view of a valid checkpoint yields exactly that checkpoint. -/
theorem restore_view {N : Nat} (G : Ghost V N) (hw : Wf G) (s : State V S CAP) (hs : StateOk G s)
    (hcons : Consistent G (fullLog G s)) (hcap : CAP < 2 ^ Rust.usizeBits) :
    (State.restore (view s).hard (view s).snapshot ((view s).entries.map pure) :
      Rust.M (Rust.Result (State V S CAP) Error)) = pure (.Ok s) := by
  have hlen := len_eq s hs.layout
  have hchain := ordered_ret G hw s hs hcons (ret s).length (Nat.le_refl _)
  rw [List.take_length] at hchain
  have hbpos : 0 < s.base.index.val → 0 < s.base.term.val ∧ s.base.term.val ≤ s.hard.term.val := by
    intro hpos
    obtain ⟨-, hl, hid⟩ := (idAt_fullLog G s hs s.base.index.val hpos s.base).mp (by simp [idAt])
    have h1 := (consistent_mono G hw _ hcons (s.base.index.val - 1) (s.base.index.val - 1) (Nat.le_refl _) hl).1
    have h2 := hs.terms _ (List.getElem_mem hl)
    rw [hid] at h1 h2
    exact ⟨h1, h2⟩
  obtain ⟨out, hout, hh, hsn, hl, he⟩ := Contracts.Storage.restoration_accepts (V := V) (CAP := CAP)
    s.hard s.snapshot (ret s) _ hcap
    (by
      intro sn hsn'
      have hb := base_some s sn hsn'
      have hpos := hs.snapshot (by simp [hsn'])
      have := hbpos hpos
      rw [hb] at hpos this
      omega)
    (by
      show s.base.term.val ≤ s.hard.term.val
      by_cases h0 : s.base.index.val = 0
      · rw [base_zero G s hs h0]; exact Nat.zero_le _
      · exact (hbpos (by omega)).2)
    hs.unvoted hchain (by have := hs.layout.1; omega) hs.commit_ge
    (by have := hs.commit_le; rw [lastId_eq s hs.contig] at this; exact this)
  have hos : out = s := state_ext _ _ hh hsn
    (Vector.toList_inj.mp (by rw [he, hs.layout.2, hlen]))
    (Fin.ext (by rw [hl, hlen]))
  show (State.restore s.hard s.snapshot ((ret s).map pure) : Rust.M (Rust.Result (State V S CAP) Error)) = _
  rw [hout, hos]

/-! ## The host-level cluster -/

/-- A cluster whose nodes keep durable records instead of checkpoints. -/
structure HCluster (V S : Type) (N CAP : Nat) where
  live : Fin N → Node V S N CAP
  durable : Fin N → Durable V S
  sent : List (Envelope V S)

/-- Replace node `k`'s volatile state. -/
def HCluster.setLive (H : HCluster V S N CAP) (k : Fin N) (n : Node V S N CAP) : HCluster V S N CAP :=
  { H with live := fun j => if j = k then n else H.live j }

/-- Replace node `k`'s volatile state and durable record. -/
def HCluster.persist (H : HCluster V S N CAP) (k : Fin N) (n : Node V S N CAP) (d : Durable V S) :
    HCluster V S N CAP :=
  { H with live := fun j => if j = k then n else H.live j,
           durable := fun j => if j = k then d else H.durable j }

/-- `Ready::write` (`ready.rs`): the incremental transaction of the token's node. -/
def readyWrite (ready : Ready V S N CAP) : Rust.M (Jarl.Write V S) :=
  State.write ready.node.state ready.node.log_from ready.node.snapshot_changed

/-- One step of the host-level cluster: `Act`, except that `persist` applies
    the `Ready`'s write to the durable record and `restart` restores the
    checkpoint from the durable record. -/
inductive HAct [Rust.Clone V] [Rust.Clone S] (cfg : Fin N → Config N) (H : HCluster V S N CAP) :
    HCluster V S N CAP → Prop
  | tick (k : Fin N) (r : Rust.Result Unit Error) (n : Node V S N CAP) :
      Node.tick (H.live k) = pure (r, n) → HAct cfg H (H.setLive k n)
  | deliver (k : Fin N) (env : Envelope V S) (r : Rust.Result Unit Error) (n : Node V S N CAP) :
      env ∈ H.sent → Node.step (H.live k) env = pure (r, n) → HAct cfg H (H.setLive k n)
  | propose (k : Fin N) (v : V) (r : Rust.Result LogId Error) (n : Node V S N CAP) :
      Node.propose (H.live k) v = pure (r, n) → HAct cfg H (H.setLive k n)
  | proposeBatch (k : Fin N) (vs : Array V) (r : Rust.Result ProposalRange Error) (n : Node V S N CAP) :
      vs.size < 2 ^ Rust.usizeBits → Node.propose_batch (H.live k) vs = pure (r, n) → HAct cfg H (H.setLive k n)
  | compact (k : Fin N) (index : Rust.u64) (v : S) (r : Rust.Result Unit Error) (n : Node V S N CAP) :
      Node.compact (H.live k) index v = pure (r, n) → HAct cfg H (H.setLive k n)
  | persist (k : Fin N) (ready : Ready V S N CAP) (w : Jarl.Write V S) :
      Node.ready (H.live k) = some ready → readyWrite ready = pure w →
      HAct cfg H (H.persist k (Ready.persisted ready).node (applyWrite (H.durable k) w))
  | save (k : Fin N) (ready : Ready V S N CAP) (w : Jarl.Write V S) :
      Node.ready (H.live k) = some ready → readyWrite ready = pure w →
      HAct cfg H { H with durable := fun j => if j = k then applyWrite (H.durable k) w else H.durable j }
  | send (k : Fin N) (env : Envelope V S) (n : Node V S N CAP) :
      Node.next_message (H.live k) = pure (some env, n) → HAct cfg H { H.setLive k n with sent := env :: H.sent }
  | drain (k : Fin N) (n : Node V S N CAP) :
      Node.next_message (H.live k) = pure (none, n) → HAct cfg H (H.setLive k n)
  | restart (k : Fin N) (s : State V S CAP) (n : Node V S N CAP) :
      State.restore (H.durable k).hard (H.durable k).snapshot ((H.durable k).entries.map pure) = pure (.Ok s) →
      Node.new (cfg k) s = pure (.Ok n) → HAct cfg H (H.setLive k n)

/-- Every durable record is empty, every node is `Node::new` on `State::new`,
    and no message was sent. -/
def HInitial [Rust.Clone V] [Rust.Clone S] (cfg : Fin N → Config N) (H : HCluster V S N CAP) : Prop :=
  H.sent = [] ∧ ∀ k, H.durable k = ⟨HardState.default, none, []⟩ ∧
    Node.new (cfg k) State.new = pure (.Ok (H.live k))

inductive HReach [Rust.Clone V] [Rust.Clone S] (cfg : Fin N → Config N) : HCluster V S N CAP → Prop
  | init (H : HCluster V S N CAP) : HInitial cfg H → HReach cfg H
  | step (H H' : HCluster V S N CAP) : HReach cfg H → HAct cfg H H' → HReach cfg H'

/-- Reachable from `H` by any number of host steps. -/
inductive HSteps [Rust.Clone V] [Rust.Clone S] (cfg : Fin N → Config N) :
    HCluster V S N CAP → HCluster V S N CAP → Prop
  | refl (H : HCluster V S N CAP) : HSteps cfg H H
  | step (H H' H'' : HCluster V S N CAP) : HAct cfg H H' → HSteps cfg H' H'' → HSteps cfg H H''

/-! ## Refinement -/

/-- The host node `h` made its write durable without acknowledging it (a
    cancelled `persist_async` whose storage finished, or a save that reported an
    error after writing): it is still dirty, the model node `m` is `h`
    acknowledged (`Ready::persisted`), and the model checkpoint `d` is its state. -/
structure Unacked (h m : Node V S N CAP) (d : State V S CAP) : Prop where
  dirty : h.dirty = true
  ack : { h with dirty := false, log_from := none, snapshot_changed := false } = m
  disk : d = m.state

/-- Node `k` of the host (`h` with record `dh`) and of the model (`m` with
    checkpoint `dm`): the same node, or saved but unacknowledged; the record is
    the view of the checkpoint; and the host node's dirty tracking is correct
    for its record. -/
structure NodeRef (h : Node V S N CAP) (dh : Durable V S) (m : Node V S N CAP) (dm : State V S CAP) : Prop where
  live : h = m ∨ Unacked h m dm
  durable : dh = view dm
  delta : DeltaOk dh h

/-- The model cluster `C` refines the host cluster `H`: same network, and each
    node is the model's (acknowledged) or saved but unacknowledged, with its
    durable record the view of the model checkpoint and its dirty tracking
    correct for that record. -/
structure Refines (H : HCluster V S N CAP) (C : Cluster V S N CAP) : Prop where
  sent : H.sent = C.sent
  node : ∀ k, NodeRef (H.live k) (H.durable k) (C.live k) (C.disk k)

theorem deltaOk_congr (d : Durable V S) (n n' : Node V S N CAP) (h : DeltaOk d n) (h1 : n'.state = n.state)
    (h2 : n'.log_from = n.log_from) (h3 : n'.snapshot_changed = n.snapshot_changed) (h4 : n'.dirty = n.dirty) :
    DeltaOk d n' := by
  obtain ⟨a, b, c, d', e⟩ := h
  exact ⟨h1 ▸ a, by rw [h3, h1]; exact b, by rw [h1]; exact c, by rw [h3, h1, h2]; exact d',
    by rw [h4, h1]; exact e⟩

/-- Any well-laid-out node's dirty tracking is correct for the view of its own
    state: its write rewrites what is already there. -/
theorem deltaOk_view (n : Node V S N CAP) (hl : Layout n.state) (hc : Contig n.state) : DeltaOk (view n.state) n :=
  deltaOk_of_agrees _ hc n hl hc (agrees_of_log _ _ rfl rfl _ _) (fun _ => rfl)

theorem ready_node [Rust.Clone V] [Rust.Clone S] (n : Node V S N CAP) (ready : Ready V S N CAP)
    (h : Node.ready n = some ready) : ready = ⟨n⟩ ∧ n.dirty = true := by
  unfold Node.ready Rust.Option.then_some at h
  split at h
  · cases h; exact ⟨rfl, by assumption⟩
  · cases h

/-- Saving a dirty node's write leaves it saved but unacknowledged. -/
theorem unacked_of_dirty (n : Node V S N CAP) (hd : n.dirty = true) :
    Unacked n (Ready.persisted ⟨n⟩).node n.state :=
  ⟨hd, rfl, rfl⟩

/-- A saved but unacknowledged node has the model node's state and role. -/
theorem NodeRef.same {h m : Node V S N CAP} {dh : Durable V S} {dm : State V S CAP} (r : NodeRef h dh m dm) :
    m.state = h.state ∧ m.role = h.role := by
  rcases r.live with rfl | u
  · exact ⟨rfl, rfl⟩
  · rw [← u.ack]; exact ⟨rfl, rfl⟩

theorem unacked_fixed (ids : Vector Id N) (h m : Node V S N CAP) (d : State V S CAP) (u : Unacked h m d)
    (hF : Fixed ids m) : Fixed ids h := by
  rw [← u.ack] at hF
  exact ⟨hF.n_pos, hF.n_lt, hF.cap_pos, hF.cap_lt, hF.nodup, hF.hooks, hF.members, hF.membership, hF.bootstrap,
    hF.peers, hF.local_lt, hF.local_id, hF.heartbeat, hF.election, hF.election_le, hF.extra, hF.prevoting,
    hF.layout, hF.contig⟩

/-- `step` on a dirty node changes nothing (`available()` fails). -/
theorem step_dirty [Rust.Clone V] [Rust.Clone S] (n n' : Node V S N CAP) (env : Envelope V S)
    (r : Rust.Result Unit Error) (hd : n.dirty = true) (h : Node.step n env = pure (r, n')) : n' = n := by
  unfold Node.step at h
  simp only [Node.available, hd, Bool.true_or, if_true] at h
  exact (Prod.mk.inj (pure_inj h)).2.symm

/-- `next_message` on a dirty node yields nothing and changes nothing. -/
theorem next_message_dirty [Rust.Clone V] [Rust.Clone S] (n n' : Node V S N CAP) (r : Option (Envelope V S))
    (hd : n.dirty = true) (h : Node.next_message n = pure (r, n')) : r = none ∧ n' = n := by
  unfold Node.next_message at h
  simp only [hd, if_true] at h
  obtain ⟨rfl, rfl⟩ := Prod.mk.inj (pure_inj h)
  exact ⟨rfl, rfl⟩

theorem dirty_same {n n' : Node V S N CAP} {P : Prop} (h : n' = n ∨ (n.dirty = false ∧ P))
    (hd : n.dirty = true) : n' = n :=
  h.resolve_right (fun ⟨h1, _⟩ => by rw [hd] at h1; cases h1)

/-- A refinement changed only at node `k`. -/
theorem refines_frame (H H' : HCluster V S N CAP) (C C' : Cluster V S N CAP) (k : Fin N) (hR : Refines H C)
    (hsent : H'.sent = C'.sent) (hk : NodeRef (H'.live k) (H'.durable k) (C'.live k) (C'.disk k))
    (hH : ∀ j, j ≠ k → H'.live j = H.live j ∧ H'.durable j = H.durable j)
    (hC : ∀ j, j ≠ k → C'.live j = C.live j ∧ C'.disk j = C.disk j) : Refines H' C' := by
  refine ⟨hsent, fun j => ?_⟩
  by_cases hj : j = k
  · subst hj; exact hk
  · rw [(hH j hj).1, (hH j hj).2, (hC j hj).1, (hC j hj).2]; exact hR.node j

/-- A node operation at `k` keeps `DeltaOk` for the unchanged record. -/
theorem delta_local [Rust.Clone V] [Rust.Clone S] (ids : Vector Id N) (cfg : Fin N → Config N)
    (C C' : Cluster V S N CAP) (G G' : Ghost V N) (hi : Inv ids cfg C G) (hi' : Inv ids cfg C' G') (k : Fin N)
    (n : Node V S N CAP) (hlive : C'.live k = n) (hdisk : C'.disk k = C.disk k)
    (hd : DeltaOk (view (C.disk k)) (C.live k))
    (hop : n = C.live k ∨ ((C.live k).dirty = false ∧ AgreesN (C.live k).state n)) :
    DeltaOk (view (C.disk k)) n := by
  rcases hop with rfl | ⟨hcl, ha⟩
  · exact hd
  have hs0 := hi.clean k hcl
  have hF := (hi.fixed k).1
  have hF' := (hi'.fixed k).1
  rw [hlive] at hF'
  rw [← hs0]
  refine deltaOk_of_agrees _ hF.contig n hF'.layout hF'.contig ha ?_
  intro hcl'
  have := hi'.clean k (by rw [hlive]; exact hcl')
  rw [hlive, hdisk, ← hs0] at this
  rw [this]

/-- One host step is refined by at most one model step: an acknowledged node
    steps as the model does (a save is the model's `persist`); a saved but
    unacknowledged node is unchanged by every operation but acknowledging,
    saving again and restarting, and the first two are stutters. -/
theorem simulate [Rust.Clone V] [Rust.Clone S] [Rust.LawfulClone V] [Rust.LawfulClone S]
    (ids : Vector Id N) (cfg : Fin N → Config N) (ha : Assumptions ids cfg CAP)
    (H H' : HCluster V S N CAP) (C : Cluster V S N CAP) (hR : Refines H C) (hC : Reach cfg C)
    (hs : HAct cfg H H') : ∃ C', (C' = C ∨ Act cfg C C') ∧ Refines H' C' := by
  obtain ⟨G, hi⟩ := reach_inv ids cfg ha C hC
  have hcap : CAP < 2 ^ Rust.usizeBits := by have := ha.capacity_fits; uomega
  have hF : ∀ k, Fixed ids (C.live k) := fun k => (hi.fixed k).1
  have hFH : ∀ k, Fixed ids (H.live k) := by
    intro k
    rcases (hR.node k).live with e | u
    · rw [e]; exact hF k
    · exact unacked_fixed ids _ _ _ u (hF k)
  -- An acknowledged node's dirty tracking is correct for the model checkpoint.
  have hdk : ∀ k, H.live k = C.live k → DeltaOk (view (C.disk k)) (C.live k) := by
    intro k e
    rw [← (hR.node k).durable, ← e]
    exact (hR.node k).delta
  -- A step of node `k` to `n` that keeps every record: the model's step when
  -- `k` is acknowledged; a stutter otherwise, as the operation then keeps `k`.
  have op_case : ∀ (k : Fin N) (n : Node V S N CAP),
      (H.live k = C.live k → Act cfg C (C.setLive k n)) →
      ((H.live k).dirty = true → n = H.live k) →
      (H.live k = C.live k → ∀ G', Inv ids cfg (C.setLive k n) G' → DeltaOk (view (C.disk k)) n) →
      ∃ C', (C' = C ∨ Act cfg C C') ∧ Refines (H.setLive k n) C' := by
    intro k n hact hdirty hdelta
    rcases (hR.node k).live with e | u
    · have hA := hact e
      obtain ⟨G', hi'⟩ := reach_inv ids cfg ha _ (Reach.step _ _ hC hA)
      refine ⟨_, Or.inr hA, refines_frame H _ C _ k hR hR.sent ⟨?_, ?_, ?_⟩ ?_ ?_⟩
      · simp only [HCluster.setLive, Cluster.setLive]; exact Or.inl rfl
      · simp only [HCluster.setLive, Cluster.setLive]; exact (hR.node k).durable
      · simp only [HCluster.setLive]
        rw [(hR.node k).durable]
        exact hdelta e G' hi'
      · intro j hj; simp [HCluster.setLive, hj]
      · intro j hj; simp [Cluster.setLive, hj]
    · obtain rfl := hdirty u.dirty
      refine ⟨C, Or.inl rfl, refines_frame H _ C C k hR hR.sent ?_ ?_ (fun _ _ => ⟨rfl, rfl⟩)⟩
      · simp only [HCluster.setLive]; exact hR.node k
      · intro j hj; simp [HCluster.setLive, hj]
  -- Its `DeltaOk` obligation, from an operation's agreement.
  have op_delta : ∀ (k : Fin N) (n : Node V S N CAP),
      (n = C.live k ∨ ((C.live k).dirty = false ∧ AgreesN (C.live k).state n)) →
      H.live k = C.live k → ∀ G', Inv ids cfg (C.setLive k n) G' → DeltaOk (view (C.disk k)) n :=
    fun k n hop e G' hi' => delta_local ids cfg C _ G G' hi hi' k n (by simp [Cluster.setLive]) rfl (hdk k e) hop
  cases hs with
  | tick k r n h =>
    exact op_case k n (fun e => .tick k r n (e ▸ h)) (dirty_same (tick_agrees ids _ (hFH k) r n h))
      (fun e => op_delta k n (tick_agrees ids _ (hF k) r n (e ▸ h)) e)
  | deliver k env r n hm h =>
    exact op_case k n (fun e => .deliver k env r n (hR.sent ▸ hm) (e ▸ h)) (fun hd => step_dirty _ n env r hd h)
      (fun e => op_delta k n (deliver_agrees ids cfg C G hi k env r n (hR.sent ▸ hm) (e ▸ h)) e)
  | propose k v r n h =>
    have hag : ∀ x : Node V S N CAP, Fixed ids x → Node.propose x v = pure (r, n) →
        n = x ∨ (x.dirty = false ∧ AgreesN x.state n) := by
      intro x hx h
      obtain ⟨r', h'⟩ := propose_wrap _ v r n h
      refine propose_agrees ids _ hx [v] [Rust.Clone.clone v] rfl ?_ 1 (by simp) r' n h'
      intro i hi'; obtain rfl : i = 0 := by simpa using hi'
      exact Rust.faithful_clone v
    exact op_case k n (fun e => .propose k v r n (e ▸ h)) (dirty_same (hag _ (hFH k) h))
      (fun e => op_delta k n (hag _ (hF k) (e ▸ h)) e)
  | proposeBatch k vs r n hsz h =>
    have hag : ∀ x : Node V S N CAP, Fixed ids x → Node.propose_batch x vs = pure (r, n) →
        n = x ∨ (x.dirty = false ∧ AgreesN x.state n) := fun x hx h =>
      propose_agrees ids _ hx vs.toList (vs.toList.map Rust.Clone.clone) (List.length_map _)
        (fun i _ => by simpa only [List.getElem_map] using Rust.faithful_clone _)
        (Rust.usizeOf vs.size) (by simp [Rust.val_usizeOf _ hsz]) r n (propose_batch_wrap _ vs r n h)
    exact op_case k n (fun e => .proposeBatch k vs r n hsz (e ▸ h)) (dirty_same (hag _ (hFH k) h))
      (fun e => op_delta k n (hag _ (hF k) (e ▸ h)) e)
  | compact k index v r n h =>
    exact op_case k n (fun e => .compact k index v r n (e ▸ h))
      (dirty_same (compact_agrees ids _ (hFH k) index _ r n (compact_wrap _ index v r n h)))
      (fun e => op_delta k n (compact_agrees ids _ (hF k) index _ r n (compact_wrap _ index v r n (e ▸ h))) e)
  | send k env n h =>
    rcases (hR.node k).live with e | u
    · have h' : Node.next_message (C.live k) = pure (some env, n) := e ▸ h
      obtain ⟨hn, -⟩ := next_message_rel ids _ (hF k) _ n h'
      refine ⟨_, Or.inr (.send k env n h'), refines_frame H _ C _ k hR (by
        show env :: H.sent = env :: C.sent; rw [hR.sent]) ⟨?_, ?_, ?_⟩ ?_ ?_⟩
      · simp only [HCluster.setLive, Cluster.setLive]; exact Or.inl rfl
      · simp only [HCluster.setLive, Cluster.setLive]; exact (hR.node k).durable
      · simp only [HCluster.setLive]
        rw [(hR.node k).durable]
        exact deltaOk_congr _ (C.live k) n (hdk k e) (by rw [hn]) (by rw [hn]) (by rw [hn]) (by rw [hn])
      · intro j hj; simp [HCluster.setLive, hj]
      · intro j hj; simp [Cluster.setLive, hj]
    · cases (next_message_dirty _ n _ u.dirty h).1
  | drain k n h =>
    exact op_case k n (fun e => .drain k n (e ▸ h)) (fun hd => (next_message_dirty _ n _ hd h).2)
      (fun e _ _ => by
        obtain ⟨hn, -⟩ := next_message_rel ids _ (hF k) _ n (e ▸ h)
        exact deltaOk_congr _ (C.live k) n (hdk k e) (by rw [hn]) (by rw [hn]) (by rw [hn]) (by rw [hn]))
  | persist k ready w h hw =>
    obtain ⟨rfl, -⟩ := ready_node _ ready h
    have hwr := deltaOk_write _ _ (hR.node k).delta w hw
    rcases (hR.node k).live with e | u
    · have h' : Node.ready (C.live k) = some ⟨C.live k⟩ := by rw [← e]; exact h
      refine ⟨_, Or.inr (.persist k _ h'), refines_frame H _ C _ k hR hR.sent ⟨?_, ?_, ?_⟩ ?_ ?_⟩
      · simp only [HCluster.persist, Cluster.persist, ite_true]; rw [e]; exact Or.inl rfl
      · simp only [HCluster.persist, Cluster.persist, ite_true]; rw [hwr, e]
      · simp only [HCluster.persist, ite_true]
        rw [hwr, persisted_eq]
        exact deltaOk_of_agrees _ (hFH k).contig _ (hFH k).layout (hFH k).contig
          (agrees_of_log _ _ rfl rfl _ _) (fun _ => rfl)
      · intro j hj; simp [HCluster.persist, hj]
      · intro j hj; simp [Cluster.persist, hj]
    · have hack : (Ready.persisted ⟨H.live k⟩).node = C.live k := u.ack
      have hst : (H.live k).state = C.disk k := by rw [u.disk, ← u.ack]
      refine ⟨C, Or.inl rfl, refines_frame H _ C C k hR hR.sent ⟨?_, ?_, ?_⟩ ?_ (fun _ _ => ⟨rfl, rfl⟩)⟩
      · simp only [HCluster.persist, ite_true]; rw [hack]; exact Or.inl rfl
      · simp only [HCluster.persist, ite_true]; rw [hwr, hst]
      · simp only [HCluster.persist, ite_true]
        rw [hwr, hack, hst, u.disk]
        exact deltaOk_view _ (hF k).layout (hF k).contig
      · intro j hj; simp [HCluster.persist, hj]
  | save k ready w h hw =>
    obtain ⟨rfl, hd⟩ := ready_node _ ready h
    have hwr := deltaOk_write _ _ (hR.node k).delta w hw
    have hself : DeltaOk (view (H.live k).state) (H.live k) := deltaOk_view _ (hFH k).layout (hFH k).contig
    rcases (hR.node k).live with e | u
    · have h' : Node.ready (C.live k) = some ⟨C.live k⟩ := by rw [← e]; exact h
      refine ⟨_, Or.inr (.persist k _ h'), refines_frame H _ C _ k hR hR.sent ⟨?_, ?_, ?_⟩ ?_ ?_⟩
      · simp only [Cluster.persist, ite_true]; rw [e]; exact Or.inr (unacked_of_dirty _ (e ▸ hd))
      · simp only [Cluster.persist, ite_true]; rw [hwr, e]
      · simp only [ite_true]; rw [hwr]; exact hself
      · intro j hj; simp [hj]
      · intro j hj; simp [Cluster.persist, hj]
    · have hst : (H.live k).state = C.disk k := by rw [u.disk, ← u.ack]
      refine ⟨C, Or.inl rfl, refines_frame H _ C C k hR hR.sent ⟨?_, ?_, ?_⟩ ?_ (fun _ _ => ⟨rfl, rfl⟩)⟩
      · exact Or.inr u
      · simp only [ite_true]; rw [hwr, hst]
      · simp only [ite_true]; rw [hwr]; exact hself
      · intro j hj; simp [hj]
  | restart k s n hres hnew =>
    rw [(hR.node k).durable, restore_view G hi.wf _ (hi.disk k) (hi.consistent_disk k) hcap] at hres
    have hs0 : C.disk k = s := by
      have := Rust.pure_inj hres
      injection this
    subst hs0
    obtain ⟨hfn, hst, -, -, -, -⟩ := new_rel ids (cfg k) _ n hnew ha.nonempty ha.members_fit ha.capacity_fits
      (ha.members k) ha.distinct (hi.disk k).layout (hi.disk k).contig
    refine ⟨_, Or.inr (.restart k n hnew), refines_frame H _ C _ k hR hR.sent ⟨?_, ?_, ?_⟩ ?_ ?_⟩
    · simp only [HCluster.setLive, Cluster.setLive]; exact Or.inl rfl
    · simp only [HCluster.setLive, Cluster.setLive]; exact (hR.node k).durable
    · simp only [HCluster.setLive]
      rw [(hR.node k).durable, ← hst]
      exact deltaOk_of_agrees _ hfn.contig _ hfn.layout hfn.contig (agrees_of_log _ _ rfl rfl _ _) (fun _ => rfl)
    · intro j hj; simp [HCluster.setLive, hj]
    · intro j hj; simp [Cluster.setLive, hj]

/-- Every host start is refined by a model start. -/
theorem refines_init [Rust.Clone V] [Rust.Clone S] (ids : Vector Id N) (cfg : Fin N → Config N)
    (ha : Assumptions ids cfg CAP) (H : HCluster V S N CAP) (h : HInitial cfg H) :
    ∃ C, Initial cfg C ∧ Refines H C := by
  obtain ⟨hs, hk⟩ := h
  have hv : view (State.new : State V S CAP) = ⟨HardState.default, none, []⟩ := by
    unfold view; rw [new_ret]; rfl
  refine ⟨⟨H.live, fun _ => State.new, H.sent⟩, ⟨hs, fun k => ⟨rfl, (hk k).2⟩⟩, rfl,
    fun k => ⟨Or.inl rfl, by rw [(hk k).1, hv], ?_⟩⟩
  obtain ⟨hf, hst, -, -, -, -⟩ := new_rel ids (cfg k) State.new (H.live k) (hk k).2 ha.nonempty ha.members_fit
    ha.capacity_fits (ha.members k) ha.distinct new_layout new_contig
  rw [(hk k).1, ← hv, ← hst]
  exact deltaOk_of_agrees _ hf.contig _ hf.layout hf.contig (agrees_of_log _ _ rfl rfl _ _) (fun _ => rfl)

theorem refines_reach [Rust.Clone V] [Rust.Clone S] [Rust.LawfulClone V] [Rust.LawfulClone S]
    (ids : Vector Id N) (cfg : Fin N → Config N) (ha : Assumptions ids cfg CAP)
    (H : HCluster V S N CAP) (h : HReach cfg H) : ∃ C, Reach cfg C ∧ Refines H C := by
  induction h with
  | init H hH =>
    obtain ⟨C, hC, hR⟩ := refines_init ids cfg ha H hH
    exact ⟨C, .init C hC, hR⟩
  | step H H' _ hs ih =>
    obtain ⟨C, hC, hR⟩ := ih
    obtain ⟨C', hA, hR'⟩ := simulate ids cfg ha H H' C hR hC hs
    rcases hA with rfl | hA
    · exact ⟨C', hC, hR'⟩
    · exact ⟨C', .step C C' hC hA, hR'⟩

theorem refines_steps [Rust.Clone V] [Rust.Clone S] [Rust.LawfulClone V] [Rust.LawfulClone S]
    (ids : Vector Id N) (cfg : Fin N → Config N) (ha : Assumptions ids cfg CAP)
    (H H' : HCluster V S N CAP) (C : Cluster V S N CAP) (hR : Refines H C) (hC : Reach cfg C)
    (hs : HSteps cfg H H') : ∃ C', Steps cfg C C' ∧ Refines H' C' := by
  induction hs generalizing C with
  | refl H => exact ⟨C, .refl C, hR⟩
  | step H H1 H2 hA _ ih =>
    obtain ⟨C1, hA1, hR1⟩ := simulate ids cfg ha H H1 C hR hC hA
    rcases hA1 with rfl | hA1
    · exact ih C1 hR1 hC
    · obtain ⟨C2, hS, hR2⟩ := ih C1 hR1 (.step _ _ hC hA1)
      exact ⟨C2, .step _ _ _ hA1 hS, hR2⟩

/-- In a refinement, restoring a durable record yields exactly the model checkpoint. -/
theorem host_restore [Rust.Clone V] [Rust.Clone S] [Rust.LawfulClone V] [Rust.LawfulClone S]
    (ids : Vector Id N) (cfg : Fin N → Config N) (ha : Assumptions ids cfg CAP)
    (H : HCluster V S N CAP) (C : Cluster V S N CAP) (hR : Refines H C) (hC : Reach cfg C) (k : Fin N) :
    State.restore (H.durable k).hard (H.durable k).snapshot ((H.durable k).entries.map pure) =
      (pure (.Ok (C.disk k)) : Rust.M (Rust.Result (State V S CAP) Error)) := by
  obtain ⟨G, hi⟩ := reach_inv ids cfg ha C hC
  rw [(hR.node k).durable]
  exact restore_view G hi.wf _ (hi.disk k) (hi.consistent_disk k) (by have := ha.capacity_fits; uomega)

end Jarl.Engine.Host
