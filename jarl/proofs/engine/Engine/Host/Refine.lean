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

`Ready::write` is not part of the translation; `readyWrite` is its body,
`State::write(log_from, snapshot_changed)` of the token's node.

Every host execution is refined by a model execution with the same live nodes
and network, whose checkpoint `disk k` is what restoring `durable k` yields
(`refines_reach`, `refines_steps`, `host_restore`), and every reachable host
node satisfies `DeltaOk`.
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

/-- The model cluster `C` refines the host cluster `H`: same nodes and network,
    each durable record is the view of the model checkpoint, and every node's
    dirty tracking is correct for its record. -/
structure Refines (H : HCluster V S N CAP) (C : Cluster V S N CAP) : Prop where
  live : H.live = C.live
  sent : H.sent = C.sent
  durable : ∀ k, H.durable k = view (C.disk k)
  delta : ∀ k, DeltaOk (H.durable k) (H.live k)

theorem deltaOk_congr (d : Durable V S) (n n' : Node V S N CAP) (h : DeltaOk d n) (h1 : n'.state = n.state)
    (h2 : n'.log_from = n.log_from) (h3 : n'.snapshot_changed = n.snapshot_changed) (h4 : n'.dirty = n.dirty) :
    DeltaOk d n' := by
  obtain ⟨a, b, c, d', e⟩ := h
  exact ⟨h1 ▸ a, by rw [h3, h1]; exact b, by rw [h1]; exact c, by rw [h3, h1, h2]; exact d',
    by rw [h4, h1]; exact e⟩

theorem ready_node [Rust.Clone V] [Rust.Clone S] (n : Node V S N CAP) (ready : Ready V S N CAP)
    (h : Node.ready n = some ready) : ready = ⟨n⟩ ∧ n.dirty = true := by
  unfold Node.ready Rust.Option.then_some at h
  split at h
  · cases h; exact ⟨rfl, by assumption⟩
  · cases h

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

/-- One host step is refined by one model step. -/
theorem simulate [Rust.Clone V] [Rust.Clone S] [Rust.LawfulClone V] [Rust.LawfulClone S]
    (ids : Vector Id N) (cfg : Fin N → Config N) (ha : Assumptions ids cfg CAP)
    (H H' : HCluster V S N CAP) (C : Cluster V S N CAP) (hR : Refines H C) (hC : Reach cfg C)
    (hs : HAct cfg H H') : ∃ C', Act cfg C C' ∧ Refines H' C' := by
  obtain ⟨G, hi⟩ := reach_inv ids cfg ha C hC
  have hcap : CAP < 2 ^ Rust.usizeBits := by have := ha.capacity_fits; uomega
  have hF : ∀ k, Fixed ids (C.live k) := fun k => (hi.fixed k).1
  obtain ⟨Hl, Hd, Hs⟩ := H
  obtain ⟨hl, hs', hd, hdl⟩ := hR
  simp only at hl hs' hd hdl
  subst hl hs'
  have hdk : ∀ k, DeltaOk (view (C.disk k)) (C.live k) := fun k => hd k ▸ hdl k
  -- A step of node `k` to `n` that keeps every checkpoint and record.
  have local_step : ∀ (k : Fin N) (n : Node V S N CAP) (sent' : List (Envelope V S)),
      Act cfg C ⟨fun j => if j = k then n else C.live j, C.disk, sent'⟩ →
      (∀ G', Inv ids cfg ⟨fun j => if j = k then n else C.live j, C.disk, sent'⟩ G' →
        DeltaOk (view (C.disk k)) n) →
      Refines ⟨fun j => if j = k then n else C.live j, Hd, sent'⟩
        ⟨fun j => if j = k then n else C.live j, C.disk, sent'⟩ := by
    intro k n sent' hact hdelta
    obtain ⟨G', hi'⟩ := reach_inv ids cfg ha _ (Reach.step _ _ hC hact)
    refine ⟨rfl, rfl, hd, ?_⟩
    intro j
    by_cases hj : j = k
    · subst hj
      simp only
      rw [hd]
      exact hdelta G' hi'
    · simp only [if_neg hj]
      exact hdl j
  -- Its `DeltaOk` obligation, from an operation's agreement.
  have op_delta : ∀ (k : Fin N) (n : Node V S N CAP) (sent' : List (Envelope V S)),
      (n = C.live k ∨ ((C.live k).dirty = false ∧ AgreesN (C.live k).state n)) →
      ∀ G', Inv ids cfg ⟨fun j => if j = k then n else C.live j, C.disk, sent'⟩ G' →
        DeltaOk (view (C.disk k)) n :=
    fun k n sent' hop G' hi' => delta_local ids cfg C _ G G' hi hi' k n (by simp) rfl (hdk k) hop
  -- `next_message` only changes the outbox.
  have nm_delta : ∀ (k : Fin N) (n : Node V S N CAP) (r : Option (Envelope V S)),
      Node.next_message (C.live k) = pure (r, n) → DeltaOk (view (C.disk k)) n := by
    intro k n r h
    obtain ⟨hn, -⟩ := next_message_rel ids _ (hF k) _ n h
    exact deltaOk_congr _ (C.live k) n (hdk k) (by rw [hn]) (by rw [hn]) (by rw [hn]) (by rw [hn])
  cases hs with
  | tick k r n h =>
    exact ⟨_, .tick k r n h, local_step k n C.sent (.tick k r n h)
      (op_delta k n C.sent (tick_agrees ids _ (hF k) r n h))⟩
  | deliver k env r n hm h =>
    exact ⟨_, .deliver k env r n hm h, local_step k n C.sent (.deliver k env r n hm h)
      (op_delta k n C.sent (deliver_agrees ids cfg C G hi k env r n hm h))⟩
  | propose k v r n h =>
    obtain ⟨r', h'⟩ := propose_wrap _ v r n h
    refine ⟨_, .propose k v r n h, local_step k n C.sent (.propose k v r n h) (op_delta k n C.sent ?_)⟩
    refine propose_agrees ids _ (hF k) [v] [Rust.Clone.clone v] rfl ?_ 1 (by simp) r' n h'
    intro i hi'; obtain rfl : i = 0 := by simpa using hi'
    exact Rust.faithful_clone v
  | proposeBatch k vs r n hsz h =>
    refine ⟨_, .proposeBatch k vs r n hsz h, local_step k n C.sent (.proposeBatch k vs r n hsz h)
      (op_delta k n C.sent ?_)⟩
    exact propose_agrees ids _ (hF k) vs.toList (vs.toList.map Rust.Clone.clone) (List.length_map _)
      (fun i _ => by simpa only [List.getElem_map] using Rust.faithful_clone _)
      (Rust.usizeOf vs.size) (by simp [Rust.val_usizeOf _ hsz]) r n (propose_batch_wrap _ vs r n h)
  | compact k index v r n h =>
    exact ⟨_, .compact k index v r n h, local_step k n C.sent (.compact k index v r n h)
      (op_delta k n C.sent (compact_agrees ids _ (hF k) index _ r n (compact_wrap _ index v r n h)))⟩
  | send k env n h =>
    exact ⟨_, .send k env n h, local_step k n (env :: C.sent) (.send k env n h)
      (fun _ _ => nm_delta k n _ h)⟩
  | drain k n h =>
    exact ⟨_, .drain k n h, local_step k n C.sent (.drain k n h) (fun _ _ => nm_delta k n _ h)⟩
  | persist k ready w h hw =>
    obtain ⟨rfl, -⟩ := ready_node _ ready h
    refine ⟨_, .persist k _ h, rfl, rfl, ?_, ?_⟩
    · intro j
      by_cases hj : j = k
      · subst hj
        simp only [HCluster.persist, Cluster.persist]
        exact deltaOk_write _ _ (hdl j) w hw
      · simp only [HCluster.persist, Cluster.persist, if_neg hj]
        exact hd j
    · intro j
      by_cases hj : j = k
      · subst hj
        simp only [HCluster.persist]
        rw [deltaOk_write _ _ (hdl j) w hw, persisted_eq]
        exact deltaOk_of_agrees _ (hF j).contig _ (hF j).layout (hF j).contig
          (agrees_of_log _ _ rfl rfl _ _) (fun _ => rfl)
      · simp only [HCluster.persist, if_neg hj]
        exact hdl j
  | restart k s n hres hnew =>
    simp only at hres
    rw [hd k, restore_view G hi.wf _ (hi.disk k) (hi.consistent_disk k) hcap] at hres
    have hs0 : C.disk k = s := by
      have := Rust.pure_inj hres
      injection this
    subst hs0
    obtain ⟨hfn, hst, -, -, -, -⟩ := new_rel ids (cfg k) _ n hnew ha.nonempty ha.members_fit ha.capacity_fits
      (ha.members k) ha.distinct (hi.disk k).layout (hi.disk k).contig
    refine ⟨_, .restart k n hnew, local_step k n C.sent (.restart k n hnew) (fun _ _ => ?_)⟩
    rw [← hst]
    exact deltaOk_of_agrees _ hfn.contig _ hfn.layout hfn.contig (agrees_of_log _ _ rfl rfl _ _) (fun _ => rfl)

/-- Every host start is refined by a model start. -/
theorem refines_init [Rust.Clone V] [Rust.Clone S] (ids : Vector Id N) (cfg : Fin N → Config N)
    (ha : Assumptions ids cfg CAP) (H : HCluster V S N CAP) (h : HInitial cfg H) :
    ∃ C, Initial cfg C ∧ Refines H C := by
  obtain ⟨hs, hk⟩ := h
  have hv : view (State.new : State V S CAP) = ⟨HardState.default, none, []⟩ := by
    unfold view; rw [new_ret]; rfl
  refine ⟨⟨H.live, fun _ => State.new, H.sent⟩, ⟨hs, fun k => ⟨rfl, (hk k).2⟩⟩, rfl, rfl,
    fun k => by rw [(hk k).1, hv], fun k => ?_⟩
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
    exact ⟨C', .step C C' hC hA, hR'⟩

theorem refines_steps [Rust.Clone V] [Rust.Clone S] [Rust.LawfulClone V] [Rust.LawfulClone S]
    (ids : Vector Id N) (cfg : Fin N → Config N) (ha : Assumptions ids cfg CAP)
    (H H' : HCluster V S N CAP) (C : Cluster V S N CAP) (hR : Refines H C) (hC : Reach cfg C)
    (hs : HSteps cfg H H') : ∃ C', Steps cfg C C' ∧ Refines H' C' := by
  induction hs generalizing C with
  | refl H => exact ⟨C, .refl C, hR⟩
  | step H H1 H2 hA _ ih =>
    obtain ⟨C1, hA1, hR1⟩ := simulate ids cfg ha H H1 C hR hC hA
    obtain ⟨C2, hS, hR2⟩ := ih C1 hR1 (.step _ _ hC hA1)
    exact ⟨C2, .step _ _ _ hA1 hS, hR2⟩

/-- In a refinement, restoring a durable record yields exactly the model checkpoint. -/
theorem host_restore [Rust.Clone V] [Rust.Clone S] [Rust.LawfulClone V] [Rust.LawfulClone S]
    (ids : Vector Id N) (cfg : Fin N → Config N) (ha : Assumptions ids cfg CAP)
    (H : HCluster V S N CAP) (C : Cluster V S N CAP) (hR : Refines H C) (hC : Reach cfg C) (k : Fin N) :
    State.restore (H.durable k).hard (H.durable k).snapshot ((H.durable k).entries.map pure) =
      (pure (.Ok (C.disk k)) : Rust.M (Rust.Result (State V S CAP) Error)) := by
  obtain ⟨G, hi⟩ := reach_inv ids cfg ha C hC
  rw [hR.durable k]
  exact restore_view G hi.wf _ (hi.disk k) (hi.consistent_disk k) (by have := ha.capacity_fits; uomega)

end Jarl.Engine.Host
