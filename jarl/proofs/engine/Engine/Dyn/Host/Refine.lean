import Engine.Dyn.Host.Ops

/-!
# Hosts of the dynamic engine that persist deltas, and their refinement

`HWorld` is the dynamic cluster as real hosts run it: each node keeps a durable
record (`Delta.Durable`) instead of a checkpoint. `DHAct` mirrors `DAct` except:

* `persist` applies the materialized `Write` of the node's `Ready` to the
  durable record, then acknowledges it (`Ready::persisted`);
* `save` applies it without acknowledging it: a cancelled `persist_async`
  whose storage finished the write, or a synchronous save that reported an
  error after writing. The node stays dirty;
* `restart` rebuilds the checkpoint with `State::restore` from the durable
  record, then runs `ClusterState::restore` and `Cluster::new`.

The refinement relation (`DRefines`) relates each host node to the model node
either exactly, or as "saved but unacknowledged": the host node is dirty, the
model node is its acknowledged form (`Ready::persisted`), and the model's
checkpoint is the host node's live state. A step of such a node is matched by
no model step (every operation but acknowledging and restarting is a no-op on a
dirty node, and saving again rewrites the same record), by none at all for the
acknowledgment (which makes the host node the model node), or by the model's
restart. Every host step is matched by at most one model step (`dsimulate`),
every durable record is the view of the model checkpoint, which restoring it
yields (`dhost_restore`), and every host node satisfies `DeltaOk`.
-/

set_option linter.unusedSectionVars false

namespace Jarl.Engine.DynHost
open Jarl Jarl.Engine Jarl.Engine.Host Jarl.Engine.Dyn Jarl.Contracts.StorageView

/-! ## Restoring a durable view -/

section
variable {V S : Type} {N CAP : Nat}

/-- Terms along a consistent log are positive and nondecreasing. -/
theorem dh_consistent_mono (G : Ghost V N)
    (hw : ∀ t L, G.leader t = some L → ∀ e ∈ L, 0 < e.id.term.val ∧ e.id.term.val ≤ t) (F : List (Entry V)) (hc : Consistent G F)
    (j k : Nat) (hjk : j ≤ k) (hk : k < F.length) :
    0 < (F[j]'(by omega)).id.term.val ∧ (F[j]'(by omega)).id.term.val ≤ F[k].id.term.val := by
  obtain ⟨-, Lk, hLk, hp⟩ := hc k hk
  have hmem : F[j]'(by omega) ∈ Lk := hp.subset (List.mem_iff_getElem.mpr ⟨j, by simp; omega, by simp⟩)
  exact hw _ Lk hLk _ hmem

/-- A checkpoint's retained entries form a restorable chain from its boundary. -/
theorem dh_ordered_ret (G : Ghost V N)
    (hw : ∀ t L, G.leader t = some L → ∀ e ∈ L, 0 < e.id.term.val ∧ e.id.term.val ≤ t) (s : State V S CAP) (hs : StateOk G s)
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
    have := (dh_consistent_mono G hw _ hcons (s.base.index.val + k) (s.base.index.val + k) (Nat.le_refl _) (by omega)).1
    rwa [hget k hk] at this
  have hmono : ∀ j k (hjk : j ≤ k) (hk : k < (ret s).length),
      ((ret s)[j]'(by omega)).id.term.val ≤ ((ret s)[k]).id.term.val := by
    intro j k hjk hk
    have := (dh_consistent_mono G hw _ hcons (s.base.index.val + j) (s.base.index.val + k) (by omega) (by omega)).2
    rwa [hget j (by omega), hget k hk] at this
  have hbase : s.base.term.val ≤ (if h : (ret s).length = 0 then s.base.term.val else ((ret s)[0]'(by omega)).id.term.val) := by
    split
    · exact (Nat.le_refl _)
    · rename_i hne
      by_cases h0 : s.base.index.val = 0
      · rw [base_zero G s hs h0]; exact Nat.zero_le _
      · obtain ⟨-, hl, hid⟩ := (idAt_fullLog G s hs s.base.index.val (by omega) s.base).mp (by simp [idAt])
        have := (dh_consistent_mono G hw _ hcons (s.base.index.val - 1) (s.base.index.val + 0) (by omega) (by omega)).2
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
theorem dh_restore_view (G : Ghost V N)
    (hw : ∀ t L, G.leader t = some L → ∀ e ∈ L, 0 < e.id.term.val ∧ e.id.term.val ≤ t) (s : State V S CAP) (hs : StateOk G s)
    (hcons : Consistent G (fullLog G s)) (hcap : CAP < 2 ^ Rust.usizeBits) :
    (State.restore (view s).hard (view s).snapshot ((view s).entries.map pure) :
      Rust.M (Rust.Result (State V S CAP) Error)) = pure (.Ok s) := by
  have hlen := len_eq s hs.layout
  have hchain := dh_ordered_ret G hw s hs hcons (ret s).length (Nat.le_refl _)
  rw [List.take_length] at hchain
  have hbpos : 0 < s.base.index.val → 0 < s.base.term.val ∧ s.base.term.val ≤ s.hard.term.val := by
    intro hpos
    obtain ⟨-, hl, hid⟩ := (idAt_fullLog G s hs s.base.index.val hpos s.base).mp (by simp [idAt])
    have h1 := (dh_consistent_mono G hw _ hcons (s.base.index.val - 1) (s.base.index.val - 1) (Nat.le_refl _) hl).1
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

end

variable {V S : Type} {MAX CAP K : Nat} [Rust.Clone V] [Rust.Clone S]

/-- In a reachable dynamic cluster, restoring the view of a checkpoint yields it. -/
theorem dh_restore_disk (ids : Vector Id K) (g : Membership MAX) (C : World V S MAX CAP K)
    (G : Ghost (Record V MAX) K) (hi : Dyn.Inv ids g C G) (hcap : CAP < 2 ^ Rust.usizeBits) (k : Fin K) :
    (State.restore (view (C.disk k)).hard (view (C.disk k)).snapshot ((view (C.disk k)).entries.map pure) :
      Rust.M (Rust.Result (DState V S MAX CAP) Error)) = pure (.Ok (C.disk k)) :=
  dh_restore_view G (fun t L h => (hi.wf.leader t L h).2.1) _ (hi.disk k).1 (hi.consistent_disk k) hcap

/-! ## The host-level dynamic cluster -/

/-- A dynamic cluster whose nodes keep durable records instead of checkpoints. -/
structure HWorld (V S : Type) (MAX CAP K : Nat) where
  live : Fin K → Jarl.Cluster V S MAX CAP
  durable : Fin K → Durable (Record V MAX) (Checkpoint S MAX)
  sent : List (DEnv V S MAX)

/-- Replace node `k`'s volatile state. -/
def HWorld.setLive (H : HWorld V S MAX CAP K) (k : Fin K) (c : Jarl.Cluster V S MAX CAP) : HWorld V S MAX CAP K :=
  { H with live := fun j => if j = k then c else H.live j }

/-- Replace node `k`'s volatile state and durable record. -/
def HWorld.persist (H : HWorld V S MAX CAP K) (k : Fin K) (c : Jarl.Cluster V S MAX CAP)
    (d : Durable (Record V MAX) (Checkpoint S MAX)) : HWorld V S MAX CAP K :=
  { H with live := fun j => if j = k then c else H.live j,
           durable := fun j => if j = k then d else H.durable j }

/-- Replace node `k`'s durable record only. -/
def HWorld.save (H : HWorld V S MAX CAP K) (k : Fin K) (d : Durable (Record V MAX) (Checkpoint S MAX)) :
    HWorld V S MAX CAP K :=
  { H with durable := fun j => if j = k then d else H.durable j }

/-- One step of the host-level dynamic cluster: `DAct`, except that `persist`
    applies the `Ready`'s write to the durable record, `save` applies it without
    acknowledging, and `restart` restores the checkpoint from the durable record. -/
inductive DHAct (ids : Vector Id K) (g : Membership MAX) (H : HWorld V S MAX CAP K) : HWorld V S MAX CAP K → Prop
  | tick (k : Fin K) (r : Rust.Result Unit Error) (c : Jarl.Cluster V S MAX CAP) :
      Cluster.tick (H.live k) = pure (r, c) → DHAct ids g H (H.setLive k c)
  | deliver (k : Fin K) (env : DEnv V S MAX) (r : Rust.Result Unit Error) (c : Jarl.Cluster V S MAX CAP) :
      env ∈ H.sent → Cluster.step (H.live k) env = pure (r, c) → DHAct ids g H (H.setLive k c)
  | propose (k : Fin K) (v : V) (r : Rust.Result LogId Error) (c : Jarl.Cluster V S MAX CAP) :
      Cluster.propose (H.live k) v = pure (r, c) → DHAct ids g H (H.setLive k c)
  | proposeBatch (k : Fin K) (vs : Array V) (r : Rust.Result ProposalRange Error) (c : Jarl.Cluster V S MAX CAP) :
      vs.size < 2 ^ Rust.usizeBits → Cluster.propose_batch (H.live k) vs = pure (r, c) → DHAct ids g H (H.setLive k c)
  | compact (k : Fin K) (index : Rust.u64) (app : S) (r : Rust.Result Unit Error) (c : Jarl.Cluster V S MAX CAP) :
      Cluster.compact (H.live k) index app = pure (r, c) → DHAct ids g H (H.setLive k c)
  | setLearners (k : Fin K) (learners : Array Id) (r : Rust.Result LogId Error) (c : Jarl.Cluster V S MAX CAP) :
      learners.size < 2 ^ Rust.usizeBits → Cluster.set_learners (H.live k) learners = pure (r, c) →
      DHAct ids g H (H.setLive k c)
  | reconfigure (k : Fin K) (target : Membership MAX) (r : Rust.Result LogId Error) (c : Jarl.Cluster V S MAX CAP) :
      MemOk target → Cluster.reconfigure (H.live k) target = pure (r, c) → DHAct ids g H (H.setLive k c)
  | finish (k : Fin K) (r : Rust.Result LogId Error) (c : Jarl.Cluster V S MAX CAP) :
      Cluster.finish_reconfiguration (H.live k) = pure (r, c) → DHAct ids g H (H.setLive k c)
  | persist (k : Fin K) (ready : Ready (Record V MAX) (Checkpoint S MAX) MAX CAP)
      (w : Jarl.Write (Record V MAX) (Checkpoint S MAX)) :
      Cluster.ready (H.live k) = some ready → readyWrite ready = pure w →
      DHAct ids g H (H.persist k { node := (Ready.persisted ready).node } (applyWrite (H.durable k) w))
  | save (k : Fin K) (ready : Ready (Record V MAX) (Checkpoint S MAX) MAX CAP)
      (w : Jarl.Write (Record V MAX) (Checkpoint S MAX)) :
      Cluster.ready (H.live k) = some ready → readyWrite ready = pure w →
      DHAct ids g H (H.save k (applyWrite (H.durable k) w))
  | send (k : Fin K) (env : DEnv V S MAX) (c : Jarl.Cluster V S MAX CAP) :
      Cluster.next_message (H.live k) = pure (some env, c) → DHAct ids g H { H.setLive k c with sent := env :: H.sent }
  | drain (k : Fin K) (c : Jarl.Cluster V S MAX CAP) :
      Cluster.next_message (H.live k) = pure (none, c) → DHAct ids g H (H.setLive k c)
  | restart (k : Fin K) (s : DState V S MAX CAP) (settings : Settings) (saved : ClusterState V S MAX CAP)
      (c : Jarl.Cluster V S MAX CAP) :
      State.restore (H.durable k).hard (H.durable k).snapshot ((H.durable k).entries.map pure) = pure (.Ok s) →
      ClusterState.restore ids[k] g s = .Ok saved → Cluster.new settings saved = pure (.Ok c) →
      DHAct ids g H (H.setLive k c)

/-- Every durable record is empty, every node is `Cluster::new` on
    `ClusterState::new` of the genesis configuration, and no message was sent. -/
def DHInitial (ids : Vector Id K) (g : Membership MAX) (H : HWorld V S MAX CAP K) : Prop :=
  H.sent = [] ∧ ∀ k, H.durable k = ⟨HardState.default, none, []⟩ ∧ ∃ settings saved,
    ClusterState.new ids[k] g = .Ok saved ∧ Cluster.new settings saved = pure (.Ok (H.live k))

inductive DHReach (ids : Vector Id K) (g : Membership MAX) : HWorld V S MAX CAP K → Prop
  | init (H : HWorld V S MAX CAP K) : DHInitial ids g H → DHReach ids g H
  | step (H H' : HWorld V S MAX CAP K) : DHReach ids g H → DHAct ids g H H' → DHReach ids g H'

/-- Reachable from `H` by any number of host steps. -/
inductive DHSteps (ids : Vector Id K) (g : Membership MAX) : HWorld V S MAX CAP K → HWorld V S MAX CAP K → Prop
  | refl (H : HWorld V S MAX CAP K) : DHSteps ids g H H
  | step (H H' H'' : HWorld V S MAX CAP K) : DHAct ids g H H' → DHSteps ids g H' H'' → DHSteps ids g H H''

/-! ## Refinement -/

/-- A host node with durable record `d` and the model node with checkpoint
    `disk`: the record is the checkpoint's view, the host node's dirty tracking is
    correct for it, and either the nodes are equal, or the host node's write is
    saved but unacknowledged: the model node is its acknowledged form and the
    checkpoint its live state. -/
def NodeRef (hc : Jarl.Cluster V S MAX CAP) (d : Durable (Record V MAX) (Checkpoint S MAX))
    (mc : Jarl.Cluster V S MAX CAP) (disk : DState V S MAX CAP) : Prop :=
  d = view disk ∧ DeltaOk d hc.node ∧
    (hc = mc ∨ (hc.node.dirty = true ∧ mc.node = (Ready.persisted ⟨hc.node⟩).node ∧ disk = hc.node.state))

/-- The model cluster `C` refines the host cluster `H`: the same network, and
    each node related by `NodeRef`. -/
structure DRefines (H : HWorld V S MAX CAP K) (C : World V S MAX CAP K) : Prop where
  sent : H.sent = C.sent
  node : ∀ k, NodeRef (H.live k) (H.durable k) (C.live k) (C.disk k)

theorem dh_refines_frame (H H' : HWorld V S MAX CAP K) (C C' : World V S MAX CAP K) (k : Fin K)
    (hR : DRefines H C) (hs : H'.sent = C'.sent) (hk : NodeRef (H'.live k) (H'.durable k) (C'.live k) (C'.disk k))
    (hH : ∀ j, j ≠ k → H'.live j = H.live j ∧ H'.durable j = H.durable j)
    (hC : ∀ j, j ≠ k → C'.live j = C.live j ∧ C'.disk j = C.disk j) : DRefines H' C' := by
  refine ⟨hs, fun j => ?_⟩
  by_cases hj : j = k
  · subst hj; exact hk
  · rw [(hH j hj).1, (hH j hj).2, (hC j hj).1, (hC j hj).2]
    exact hR.node j

/-- A host node shows the model node's role and checkpoint, and is the model
    node whenever it is clean. -/
theorem noderef_view (hc mc : Jarl.Cluster V S MAX CAP) (d : Durable (Record V MAX) (Checkpoint S MAX))
    (disk : DState V S MAX CAP) (h : NodeRef hc d mc disk) :
    hc.node.role = mc.node.role ∧ hc.node.state = mc.node.state ∧ (hc.node.dirty = false → hc = mc) := by
  rcases h.2.2 with rfl | ⟨hd, hm, -⟩
  · exact ⟨rfl, rfl, fun _ => rfl⟩
  · rw [hm, persisted_eq]
    exact ⟨rfl, rfl, fun h => by rw [hd] at h; cases h⟩

theorem noderef_facts (hc mc : Jarl.Cluster V S MAX CAP) (d : Durable (Record V MAX) (Checkpoint S MAX))
    (disk : DState V S MAX CAP) (h : NodeRef hc d mc disk) (hf : NodeFacts mc.node) : NodeFacts hc.node := by
  rcases h.2.2 with rfl | ⟨-, hm, -⟩
  · exact hf
  · rw [hm, persisted_eq] at hf
    exact nodeFacts_flags _ _ _ _ hf

theorem dh_cluster_ready (c : Jarl.Cluster V S MAX CAP) (ready : Ready (Record V MAX) (Checkpoint S MAX) MAX CAP)
    (h : Cluster.ready c = some ready) : ready = ⟨c.node⟩ ∧ c.node.dirty = true :=
  ready_node c.node ready h

/-- A clean checkpoint's view is exact for a node whose live state it is. -/
theorem dh_delta_self (n : DNode V S MAX CAP) (hl : Layout n.state) (hc : Contig n.state) :
    DeltaOk (view n.state) n :=
  deltaOk_of_agrees _ hc n hl hc (agrees_of_log _ _ rfl rfl _ _) (fun _ => rfl)

/-- An operation at `k` keeps `DeltaOk` for the unchanged record. -/
theorem dh_delta_local (ids : Vector Id K) (g : Membership MAX) (C C' : World V S MAX CAP K)
    (G G' : Ghost (Record V MAX) K) (hi : Dyn.Inv ids g C G) (hi' : Dyn.Inv ids g C' G') (k : Fin K)
    (n : DNode V S MAX CAP) (hlive : (C'.live k).node = n) (hdisk : C'.disk k = C.disk k)
    (hd : DeltaOk (view (C.disk k)) (C.live k).node) (hop : OpOk (C.live k).node n) :
    DeltaOk (view (C.disk k)) n := by
  rcases hop with rfl | ⟨hcl, ha⟩
  · exact hd
  have hs0 := hi.clean k hcl
  have hD := hi'.dyn k
  have hc0 := (hi.dyn k).contig
  simp only [World.node, hlive] at hD
  rw [← hs0]
  refine deltaOk_of_agrees _ hc0 n hD.layout hD.contig ha ?_
  intro hcl'
  have := hi'.clean k (by simp only [World.node, hlive]; exact hcl')
  simp only [World.node, hlive] at this
  rw [this, hdisk, ← hs0]

/-! ## The operations as one step -/

/-- The host cluster after operation `c` at `k`, emitting `out`. -/
def hEmit (H : HWorld V S MAX CAP K) (k : Fin K) (out : Option (DEnv V S MAX)) (c : Jarl.Cluster V S MAX CAP) :
    HWorld V S MAX CAP K :=
  match out with
  | some env => { H.setLive k c with sent := env :: H.sent }
  | none => H.setLive k c

/-- The model cluster after operation `c` at `k`, emitting `out`. -/
def wEmit (C : World V S MAX CAP K) (k : Fin K) (out : Option (DEnv V S MAX)) (c : Jarl.Cluster V S MAX CAP) :
    World V S MAX CAP K :=
  match out with
  | some env => { C.setLive k c with sent := env :: C.sent }
  | none => C.setLive k c

theorem dact_of_cop (ids : Vector Id K) (g : Membership MAX) (C : World V S MAX CAP K) (k : Fin K)
    (out : Option (DEnv V S MAX)) (c : Jarl.Cluster V S MAX CAP) (h : COp C.sent (C.live k) out c) :
    DAct ids g C (wEmit C k out c) := by
  cases h with
  | tick r c h => exact .tick k r c h
  | deliver env r c hm h => exact .deliver k env r c hm h
  | propose v r c h => exact .propose k v r c h
  | proposeBatch vs r c hs h => exact .proposeBatch k vs r c hs h
  | compact index app r c h => exact .compact k index app r c h
  | setLearners ls r c hl h => exact .setLearners k ls r c hl h
  | reconfigure t r c ht h => exact .reconfigure k t r c ht h
  | finish r c h => exact .finish k r c h
  | send env c h => exact .send k env c h
  | drain c h => exact .drain k c h

theorem hEmit_live (H : HWorld V S MAX CAP K) (k j : Fin K) (out : Option (DEnv V S MAX)) (c : Jarl.Cluster V S MAX CAP) :
    (hEmit H k out c).live j = if j = k then c else H.live j := by
  cases out <;> rfl

theorem wEmit_live (C : World V S MAX CAP K) (k j : Fin K) (out : Option (DEnv V S MAX)) (c : Jarl.Cluster V S MAX CAP) :
    (wEmit C k out c).live j = if j = k then c else C.live j := by
  cases out <;> rfl

theorem hEmit_durable (H : HWorld V S MAX CAP K) (k : Fin K) (out : Option (DEnv V S MAX)) (c : Jarl.Cluster V S MAX CAP) :
    (hEmit H k out c).durable = H.durable := by
  cases out <;> rfl

theorem wEmit_disk (C : World V S MAX CAP K) (k : Fin K) (out : Option (DEnv V S MAX)) (c : Jarl.Cluster V S MAX CAP) :
    (wEmit C k out c).disk = C.disk := by
  cases out <;> rfl

theorem hEmit_sent (H : HWorld V S MAX CAP K) (k : Fin K) (out : Option (DEnv V S MAX)) (c : Jarl.Cluster V S MAX CAP) :
    (hEmit H k out c).sent = out.toList ++ H.sent := by
  cases out <;> rfl

theorem wEmit_sent (C : World V S MAX CAP K) (k : Fin K) (out : Option (DEnv V S MAX)) (c : Jarl.Cluster V S MAX CAP) :
    (wEmit C k out c).sent = out.toList ++ C.sent := by
  cases out <;> rfl

theorem hEmit_same (H : HWorld V S MAX CAP K) (k : Fin K) : hEmit H k none (H.live k) = H := by
  cases H with
  | mk live durable sent =>
    simp only [hEmit, HWorld.setLive]
    congr 1
    funext j
    split
    · rename_i h; subst h; rfl
    · rfl

theorem cluster_eta (c : Jarl.Cluster V S MAX CAP) : ({ node := c.node } : Jarl.Cluster V S MAX CAP) = c := rfl

/-! ## Simulation -/

theorem dh_persist_live (C : World V S MAX CAP K) (k j : Fin K) (c : Jarl.Cluster V S MAX CAP) :
    (C.persist k c).live j = if j = k then c else C.live j := rfl

theorem dh_persist_disk (C : World V S MAX CAP K) (k j : Fin K) (c : Jarl.Cluster V S MAX CAP) :
    (C.persist k c).disk j = if j = k then (C.live k).node.state else C.disk j := rfl


section
variable [Rust.LawfulClone V] [Rust.LawfulClone S] (ids : Vector Id K) (g : Membership MAX)
  (ha : Dyn.Assumptions ids g CAP)
include ha

/-- An operation at `k`: a model step from an exact node, a stutter on a saved
    but unacknowledged one. -/
theorem sim_cop (H : HWorld V S MAX CAP K) (C : World V S MAX CAP K) (hR : DRefines H C) (hC : DReach ids g C)
    (k : Fin K) (out : Option (DEnv V S MAX)) (c : Jarl.Cluster V S MAX CAP) (hop : COp H.sent (H.live k) out c) :
    ∃ C', (C' = C ∨ DAct ids g C C') ∧ DRefines (hEmit H k out c) C' := by
  obtain ⟨G, hi⟩ := Dyn.reach_inv ids g ha C hC
  obtain ⟨hd, hdelta, heq | ⟨hdirty, -, -⟩⟩ := hR.node k
  · rw [heq, hR.sent] at hop
    have hact := dact_of_cop ids g C k out c hop
    obtain ⟨G', hi'⟩ := Dyn.reach_inv ids g ha _ (DReach.step _ _ hC hact)
    have hok := (cop_ok C.sent (C.live k) c out (nodeFacts_of_inv ids g ha.genesis C G hi k) hop).1
    rw [hd, heq] at hdelta
    refine ⟨_, Or.inr hact, dh_refines_frame H _ C _ k hR (by rw [hEmit_sent, wEmit_sent, hR.sent]) ?_ ?_ ?_⟩
    · refine ⟨?_, ?_, Or.inl ?_⟩
      · rw [hEmit_durable, wEmit_disk]; exact hd
      · rw [hEmit_durable, hEmit_live, if_pos rfl, hd]
        exact dh_delta_local ids g C _ G G' hi hi' k c.node (by rw [wEmit_live, if_pos rfl]) (by rw [wEmit_disk])
          hdelta hok
      · rw [hEmit_live, wEmit_live, if_pos rfl, if_pos rfl]
    · intro j hj; rw [hEmit_live, if_neg hj, hEmit_durable]; exact ⟨rfl, rfl⟩
    · intro j hj; rw [wEmit_live, if_neg hj, wEmit_disk]; exact ⟨rfl, rfl⟩
  · have hf := noderef_facts _ _ _ _ (hR.node k) (nodeFacts_of_inv ids g ha.genesis C G hi k)
    obtain ⟨rfl, rfl⟩ := cop_dirty H.sent (H.live k) c out hf hdirty hop
    rw [hEmit_same]
    exact ⟨C, Or.inl rfl, hR⟩

/-- Persisting and acknowledging: the model persists an exact node; it stutters
    on a saved node, which the acknowledgment makes exact. -/
theorem sim_persist (H : HWorld V S MAX CAP K) (C : World V S MAX CAP K) (hR : DRefines H C) (hC : DReach ids g C)
    (k : Fin K) (ready : Ready (Record V MAX) (Checkpoint S MAX) MAX CAP)
    (w : Jarl.Write (Record V MAX) (Checkpoint S MAX)) (hr : Cluster.ready (H.live k) = some ready)
    (hw : readyWrite ready = pure w) :
    ∃ C', (C' = C ∨ DAct ids g C C') ∧
      DRefines (H.persist k { node := (Ready.persisted ready).node } (applyWrite (H.durable k) w)) C' := by
  obtain ⟨G, hi⟩ := Dyn.reach_inv ids g ha C hC
  have hf := noderef_facts _ _ _ _ (hR.node k) (nodeFacts_of_inv ids g ha.genesis C G hi k)
  obtain ⟨hd, hdelta, hcase⟩ := hR.node k
  obtain ⟨rfl, -⟩ := dh_cluster_ready _ ready hr
  have hwr : applyWrite (H.durable k) w = view (H.live k).node.state := deltaOk_write _ _ hdelta w hw
  have hdp : DeltaOk (view (H.live k).node.state) (Ready.persisted ⟨(H.live k).node⟩).node := by
    exact dh_delta_self (Ready.persisted ⟨(H.live k).node⟩).node hf.pre.layout hf.pre.contig
  have hH : ∀ j, j ≠ k → (H.persist k { node := (Ready.persisted ⟨(H.live k).node⟩).node }
      (applyWrite (H.durable k) w)).live j = H.live j ∧ (H.persist k { node := (Ready.persisted ⟨(H.live k).node⟩).node }
      (applyWrite (H.durable k) w)).durable j = H.durable j := by
    intro j hj; simp [HWorld.persist, hj]
  rcases hcase with heq | ⟨-, hm, hdisk⟩
  · have hact : DAct ids g C (C.persist k { node := (Ready.persisted ⟨(H.live k).node⟩).node }) :=
      DAct.persist k _ (by rw [← heq]; exact hr)
    refine ⟨_, Or.inr hact, dh_refines_frame H _ C _ k hR hR.sent ?_ hH ?_⟩
    · refine ⟨?_, ?_, Or.inl ?_⟩
      · simp only [HWorld.persist, if_true, dh_persist_disk, hwr, heq]
      · simp only [HWorld.persist, if_true, hwr]; exact hdp
      · simp only [HWorld.persist, if_true, dh_persist_live]
    · intro j hj; rw [dh_persist_live, dh_persist_disk, if_neg hj, if_neg hj]; exact ⟨rfl, rfl⟩
  · refine ⟨C, Or.inl rfl, dh_refines_frame H _ C C k hR hR.sent ?_ hH (fun _ _ => ⟨rfl, rfl⟩)⟩
    refine ⟨?_, ?_, Or.inl ?_⟩
    · simp only [HWorld.persist, if_true, hwr, hdisk]
    · simp only [HWorld.persist, if_true, hwr]; exact hdp
    · simp only [HWorld.persist, if_true]; rw [← hm]

/-- Saving without acknowledging: the model persists an exact node (which the
    host keeps dirty); saving a saved node rewrites the same record. -/
theorem sim_save (H : HWorld V S MAX CAP K) (C : World V S MAX CAP K) (hR : DRefines H C) (hC : DReach ids g C)
    (k : Fin K) (ready : Ready (Record V MAX) (Checkpoint S MAX) MAX CAP)
    (w : Jarl.Write (Record V MAX) (Checkpoint S MAX)) (hr : Cluster.ready (H.live k) = some ready)
    (hw : readyWrite ready = pure w) :
    ∃ C', (C' = C ∨ DAct ids g C C') ∧ DRefines (H.save k (applyWrite (H.durable k) w)) C' := by
  obtain ⟨G, hi⟩ := Dyn.reach_inv ids g ha C hC
  have hf := noderef_facts _ _ _ _ (hR.node k) (nodeFacts_of_inv ids g ha.genesis C G hi k)
  obtain ⟨hd, hdelta, hcase⟩ := hR.node k
  obtain ⟨rfl, hdt⟩ := dh_cluster_ready _ ready hr
  have hwr : applyWrite (H.durable k) w = view (H.live k).node.state := deltaOk_write _ _ hdelta w hw
  have hds : DeltaOk (view (H.live k).node.state) (H.live k).node := dh_delta_self _ hf.pre.layout hf.pre.contig
  have hH : ∀ j, j ≠ k → (H.save k (applyWrite (H.durable k) w)).live j = H.live j ∧
      (H.save k (applyWrite (H.durable k) w)).durable j = H.durable j := by
    intro j hj; simp [HWorld.save, hj]
  rcases hcase with heq | ⟨-, hm, hdisk⟩
  · have hact : DAct ids g C (C.persist k { node := (Ready.persisted ⟨(H.live k).node⟩).node }) :=
      DAct.persist k _ (by rw [← heq]; exact hr)
    refine ⟨_, Or.inr hact, dh_refines_frame H _ C _ k hR hR.sent ?_ hH ?_⟩
    · refine ⟨?_, ?_, Or.inr ⟨hdt, ?_, ?_⟩⟩
      · simp only [HWorld.save, if_true, dh_persist_disk, hwr, heq]
      · simp only [HWorld.save, if_true, hwr]; exact hds
      · simp only [HWorld.save, dh_persist_live, if_true]
      · simp only [HWorld.save, dh_persist_disk, if_true, heq]
    · intro j hj; rw [dh_persist_live, dh_persist_disk, if_neg hj, if_neg hj]; exact ⟨rfl, rfl⟩
  · refine ⟨C, Or.inl rfl, dh_refines_frame H _ C C k hR hR.sent ?_ hH (fun _ _ => ⟨rfl, rfl⟩)⟩
    refine ⟨?_, ?_, Or.inr ⟨hdt, hm, hdisk⟩⟩
    · simp only [HWorld.save, if_true, hwr, hdisk]
    · simp only [HWorld.save, if_true, hwr]; exact hds

/-- Restarting from the durable record: the model restarts from its checkpoint. -/
theorem sim_restart (H : HWorld V S MAX CAP K) (C : World V S MAX CAP K) (hR : DRefines H C) (hC : DReach ids g C)
    (k : Fin K) (s : DState V S MAX CAP) (settings : Settings) (saved : ClusterState V S MAX CAP)
    (c : Jarl.Cluster V S MAX CAP)
    (h1 : State.restore (H.durable k).hard (H.durable k).snapshot ((H.durable k).entries.map pure) = pure (.Ok s))
    (h2 : ClusterState.restore ids[k] g s = .Ok saved) (h3 : Cluster.new settings saved = pure (.Ok c)) :
    ∃ C', (C' = C ∨ DAct ids g C C') ∧ DRefines (H.setLive k c) C' := by
  obtain ⟨G, hi⟩ := Dyn.reach_inv ids g ha C hC
  obtain ⟨hd, -, -⟩ := hR.node k
  have hcap : CAP < 2 ^ Rust.usizeBits := by have := ha.capacity_fits; uomega
  rw [hd, dh_restore_disk ids g C G hi hcap k] at h1
  have hs0 : C.disk k = s := by
    have := Rust.pure_inj h1
    injection this
  subst hs0
  have hact : DAct ids g C (C.setLive k c) := DAct.restart k settings saved c h2 h3
  have hsv := pp_restore h2
  subst hsv
  have hdk := (hi.disk k).1
  obtain ⟨-, hfr⟩ := cluster_new_rel settings _ c ha.members_fit ha.capacity_fits hdk.layout hdk.contig ha.genesis.1 h3
  have hst : c.node.state = C.disk k := hfr.1
  refine ⟨_, Or.inr hact, dh_refines_frame H _ C _ k hR hR.sent ⟨?_, ?_, Or.inl ?_⟩ ?_ ?_⟩
  · exact hd
  · simp only [HWorld.setLive, if_true]
    rw [hd, ← hst]
    exact dh_delta_self _ (hst ▸ hdk.layout) (hst ▸ hdk.contig)
  · simp only [HWorld.setLive, World.setLive, if_true]
  · intro j hj; simp [HWorld.setLive, hj]
  · intro j hj; simp [World.setLive, hj]

/-- One host step is refined by at most one model step. -/
theorem dsimulate (H H' : HWorld V S MAX CAP K) (C : World V S MAX CAP K) (hR : DRefines H C) (hC : DReach ids g C)
    (hs : DHAct ids g H H') : ∃ C', (C' = C ∨ DAct ids g C C') ∧ DRefines H' C' := by
  cases hs with
  | tick k r c h => exact sim_cop ids g ha H C hR hC k none c (.tick r c h)
  | deliver k env r c hm h => exact sim_cop ids g ha H C hR hC k none c (.deliver env r c hm h)
  | propose k v r c h => exact sim_cop ids g ha H C hR hC k none c (.propose v r c h)
  | proposeBatch k vs r c hv h => exact sim_cop ids g ha H C hR hC k none c (.proposeBatch vs r c hv h)
  | compact k index app r c h => exact sim_cop ids g ha H C hR hC k none c (.compact index app r c h)
  | setLearners k ls r c hl h => exact sim_cop ids g ha H C hR hC k none c (.setLearners ls r c hl h)
  | reconfigure k t r c ht h => exact sim_cop ids g ha H C hR hC k none c (.reconfigure t r c ht h)
  | finish k r c h => exact sim_cop ids g ha H C hR hC k none c (.finish r c h)
  | send k env c h => exact sim_cop ids g ha H C hR hC k (some env) c (.send env c h)
  | drain k c h => exact sim_cop ids g ha H C hR hC k none c (.drain c h)
  | persist k ready w hr hw => exact sim_persist ids g ha H C hR hC k ready w hr hw
  | save k ready w hr hw => exact sim_save ids g ha H C hR hC k ready w hr hw
  | restart k s settings saved c h1 h2 h3 => exact sim_restart ids g ha H C hR hC k s settings saved c h1 h2 h3

/-- Every host start is refined by a model start. -/
theorem drefines_init (H : HWorld V S MAX CAP K) (h : DHInitial ids g H) :
    ∃ C, DInitial ids g C ∧ DRefines H C := by
  obtain ⟨hs, hk⟩ := h
  have hv : view (State.new : DState V S MAX CAP) = ⟨HardState.default, none, []⟩ := by
    unfold view; rw [new_ret]; rfl
  refine ⟨⟨H.live, fun _ => State.new, H.sent⟩, ⟨hs, fun k => ⟨rfl, (hk k).2⟩⟩, ⟨rfl, fun k => ?_⟩⟩
  obtain ⟨hdur, settings, saved, hn, hc⟩ := hk k
  have hsv := pp_restore (show ClusterState.restore ids[k] g State.new = .Ok saved from hn)
  subst hsv
  obtain ⟨-, hfr⟩ := cluster_new_rel settings _ _ ha.members_fit ha.capacity_fits new_layout new_contig ha.genesis.1 hc
  have hst : (H.live k).node.state = State.new := hfr.1
  refine ⟨by rw [hdur, hv], ?_, Or.inl rfl⟩
  rw [hdur, ← hv, ← hst]
  exact dh_delta_self _ (hst ▸ new_layout) (hst ▸ new_contig)

theorem drefines_reach (H : HWorld V S MAX CAP K) (h : DHReach ids g H) : ∃ C, DReach ids g C ∧ DRefines H C := by
  induction h with
  | init H hH =>
    obtain ⟨C, hC, hR⟩ := drefines_init ids g ha H hH
    exact ⟨C, .init C hC, hR⟩
  | step H H' _ hs ih =>
    obtain ⟨C, hC, hR⟩ := ih
    obtain ⟨C', hA, hR'⟩ := dsimulate ids g ha H H' C hR hC hs
    rcases hA with rfl | hA
    · exact ⟨C', hC, hR'⟩
    · exact ⟨C', .step C C' hC hA, hR'⟩

theorem drefines_steps (H H' : HWorld V S MAX CAP K) (C : World V S MAX CAP K) (hR : DRefines H C)
    (hC : DReach ids g C) (hs : DHSteps ids g H H') : ∃ C', Dyn.Steps ids g C C' ∧ DRefines H' C' := by
  induction hs generalizing C with
  | refl H => exact ⟨C, .refl C, hR⟩
  | step H H1 H2 hA _ ih =>
    obtain ⟨C1, hA1, hR1⟩ := dsimulate ids g ha H H1 C hR hC hA
    rcases hA1 with rfl | hA1
    · exact ih C1 hR1 hC
    · obtain ⟨C2, hS, hR2⟩ := ih C1 hR1 (.step _ _ hC hA1)
      exact ⟨C2, .step _ _ _ hA1 hS, hR2⟩

/-- In a refinement, restoring a durable record yields exactly the model checkpoint. -/
theorem dhost_restore (H : HWorld V S MAX CAP K) (C : World V S MAX CAP K) (hR : DRefines H C)
    (hC : DReach ids g C) (k : Fin K) :
    State.restore (H.durable k).hard (H.durable k).snapshot ((H.durable k).entries.map pure) =
      (pure (.Ok (C.disk k)) : Rust.M (Rust.Result (DState V S MAX CAP) Error)) := by
  obtain ⟨G, hi⟩ := Dyn.reach_inv ids g ha C hC
  rw [(hR.node k).1]
  exact dh_restore_disk ids g C G hi (by have := ha.capacity_fits; uomega) k

end

end Jarl.Engine.DynHost
