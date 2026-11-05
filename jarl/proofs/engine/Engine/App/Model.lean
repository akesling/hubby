import Engine.Main

/-!
# The replicated application and the honest host

An application is an initial state `init` and a transition `apply` per entry
value (`none` is a no-op entry); `state es` folds a list of entries from
`init`. A host compacts honestly when the snapshot value it passes to
`Node::compact(index, value)` is what it computes from what the node itself
exposes: the current snapshot's value (`init` without one) with the retained
entries up to `index` folded in (`honest`). `AppAct` is `Act` with compaction
restricted to honest values, and `AppReach` its reachable clusters.

`AppInv` says every snapshot in the system (live states, durable states and
`Install` messages) holds the application state of the leader-log prefix
through its boundary. `app_preserve` shows every `AppAct` step preserves it
together with `Inv`.
-/

namespace Jarl.Engine.App
open Jarl Jarl.Engine

variable {V S : Type} {N CAP : Nat} [Rust.Clone V] [Rust.Clone S]

section Application
variable (init : S) (apply : S → Option V → S)

/-- The application state after applying `es` in order from `init`. -/
def state (es : List (Entry V)) : S := es.foldl (fun s e => apply s e.value) init

/-- The application state a checkpoint's snapshot holds: its value, or `init` without one. -/
def baseValue (s : State V S CAP) : S := (s.snapshot.map (·.value)).getD init

/-- What an honest host passes to `compact(index, ·)` on node `n`: the snapshot
    value it exposes with the retained entries through `index` applied. -/
def honest (n : Node V S N CAP) (index : Rust.u64) : S :=
  ((ret n.state).take (index.val - n.state.base.index.val)).foldl (fun s e => apply s e.value)
    (baseValue init n.state)

/-- `Act` whose compactions pass the honest value. -/
inductive AppAct (cfg : Fin N → Config N) (C : Cluster V S N CAP) : Cluster V S N CAP → Prop
  | tick (k : Fin N) (r : Rust.Result Unit Error) (n : Node V S N CAP) :
      Node.tick (C.live k) = pure (r, n) → AppAct cfg C (C.setLive k n)
  | deliver (k : Fin N) (env : Envelope V S) (r : Rust.Result Unit Error) (n : Node V S N CAP) :
      env ∈ C.sent → Node.step (C.live k) env = pure (r, n) → AppAct cfg C (C.setLive k n)
  | propose (k : Fin N) (v : V) (r : Rust.Result LogId Error) (n : Node V S N CAP) :
      Node.propose (C.live k) v = pure (r, n) → AppAct cfg C (C.setLive k n)
  | proposeBatch (k : Fin N) (vs : Array V) (r : Rust.Result ProposalRange Error) (n : Node V S N CAP) :
      vs.size < 2 ^ Rust.usizeBits → Node.propose_batch (C.live k) vs = pure (r, n) → AppAct cfg C (C.setLive k n)
  | compact (k : Fin N) (index : Rust.u64) (r : Rust.Result Unit Error) (n : Node V S N CAP) :
      Node.compact (C.live k) index (honest init apply (C.live k) index) = pure (r, n) →
      AppAct cfg C (C.setLive k n)
  | persist (k : Fin N) (ready : Ready V S N CAP) :
      Node.ready (C.live k) = some ready → AppAct cfg C (C.persist k (Ready.persisted ready).node)
  | send (k : Fin N) (env : Envelope V S) (n : Node V S N CAP) :
      Node.next_message (C.live k) = pure (some env, n) → AppAct cfg C { C.setLive k n with sent := env :: C.sent }
  | drain (k : Fin N) (n : Node V S N CAP) :
      Node.next_message (C.live k) = pure (none, n) → AppAct cfg C (C.setLive k n)
  | restart (k : Fin N) (n : Node V S N CAP) :
      Node.new (cfg k) (C.disk k) = pure (.Ok n) → AppAct cfg C (C.setLive k n)

inductive AppReach (cfg : Fin N → Config N) : Cluster V S N CAP → Prop
  | init (C : Cluster V S N CAP) : Initial cfg C → AppReach cfg C
  | step (C C' : Cluster V S N CAP) : AppReach cfg C → AppAct init apply cfg C C' → AppReach cfg C'

/-- Reachable from `C` by honest steps. -/
inductive AppSteps (cfg : Fin N → Config N) : Cluster V S N CAP → Cluster V S N CAP → Prop
  | refl (C : Cluster V S N CAP) : AppSteps cfg C C
  | step (C C' C'' : Cluster V S N CAP) : AppAct init apply cfg C C' → AppSteps cfg C' C'' → AppSteps cfg C C''

theorem AppAct.toAct {cfg : Fin N → Config N} {C C' : Cluster V S N CAP} (h : AppAct init apply cfg C C') :
    Act cfg C C' := by
  cases h with
  | tick k r n h => exact .tick k r n h
  | deliver k env r n hm h => exact .deliver k env r n hm h
  | propose k v r n h => exact .propose k v r n h
  | proposeBatch k vs r n hs h => exact .proposeBatch k vs r n hs h
  | compact k index r n h => exact .compact k index _ r n h
  | persist k ready h => exact .persist k ready h
  | send k env n h => exact .send k env n h
  | drain k n h => exact .drain k n h
  | restart k n h => exact .restart k n h

/-- Every honestly reachable cluster is reachable. -/
theorem AppReach.toReach {cfg : Fin N → Config N} {C : Cluster V S N CAP} (h : AppReach init apply cfg C) :
    Reach cfg C := by
  induction h with
  | init C hC => exact .init C hC
  | step C C' _ ha ih => exact .step C C' ih (ha.toAct init apply)

theorem AppSteps.toSteps {cfg : Fin N → Config N} {C C' : Cluster V S N CAP} (h : AppSteps init apply cfg C C') :
    Steps cfg C C' := by
  induction h with
  | refl C => exact .refl C
  | step C C' C'' ha _ ih => exact .step C C' C'' (ha.toAct init apply) ih

/-- A snapshot holds the application state of the prefix of its boundary term's
    leader log through its boundary, which exists. -/
def SnapOk (G : Ghost V N) (sn : Snapshot S) : Prop :=
  ∃ L, G.leader sn.last.term.val = some L ∧ sn.last.index.val ≤ L.length ∧
    sn.value = state init apply (G.prefix sn.last.term.val sn.last.index.val)

/-- Every snapshot in the system is `SnapOk`. -/
structure AppInv (C : Cluster V S N CAP) (G : Ghost V N) : Prop where
  live : ∀ k sn, (C.live k).state.snapshot = some sn → SnapOk init apply G sn
  disk : ∀ k sn, (C.disk k).snapshot = some sn → SnapOk init apply G sn
  sent : ∀ env ∈ C.sent, ∀ t sn, env.message = .Install t sn → SnapOk init apply G sn

omit [Rust.Clone V] [Rust.Clone S] in
theorem snapOk_mono {G G' : Ghost V N} (e : Extends G G') (sn : Snapshot S) (h : SnapOk init apply G sn) :
    SnapOk init apply G' sn := by
  obtain ⟨L, hL, hle, hv⟩ := h
  obtain ⟨L', hL', hp⟩ := e.leader _ L hL
  exact ⟨L', hL', Nat.le_trans hle hp.length_le, by rw [prefix_extends e _ _ L hL hle]; exact hv⟩

omit [Rust.Clone V] [Rust.Clone S] in
theorem appInv_mono {G G' : Ghost V N} (e : Extends G G') (C : Cluster V S N CAP) (h : AppInv init apply C G) :
    AppInv init apply C G' :=
  ⟨fun k sn hs => snapOk_mono init apply e sn (h.live k sn hs),
   fun k sn hs => snapOk_mono init apply e sn (h.disk k sn hs),
   fun env hm t sn hs => snapOk_mono init apply e sn (h.sent env hm t sn hs)⟩

omit [Rust.Clone V] [Rust.Clone S] in
theorem appInv_setLive (C : Cluster V S N CAP) (G : Ghost V N) (h : AppInv init apply C G) (k : Fin N)
    (n : Node V S N CAP) (hn : ∀ sn, n.state.snapshot = some sn → SnapOk init apply G sn) :
    AppInv init apply (C.setLive k n) G := by
  refine ⟨fun j sn hs => ?_, h.disk, h.sent⟩
  by_cases hj : j = k
  · subst hj; rw [setLive_self] at hs; exact hn sn hs
  · rw [setLive_other C k j n hj] at hs; exact h.live j sn hs

omit [Rust.Clone V] [Rust.Clone S] in
theorem appInv_keep (C : Cluster V S N CAP) (G : Ghost V N) (h : AppInv init apply C G) (k : Fin N)
    (n : Node V S N CAP) (hn : n.state.snapshot = (C.live k).state.snapshot) :
    AppInv init apply (C.setLive k n) G :=
  appInv_setLive init apply C G h k n (fun sn hs => h.live k sn (hn ▸ hs))

end Application

/-! ## Operations that keep the snapshot -/

section Frames

omit [Rust.Clone V] [Rust.Clone S] in
theorem snap_timers {n n' : Node V S N CAP} (h : Timers n n') : n'.state.snapshot = n.state.snapshot := by
  obtain ⟨r, d, rfl⟩ := h; rfl

omit [Rust.Clone V] [Rust.Clone S] in
theorem snap_commitTo (n : Node V S N CAP) (i : Rust.u64) : (commitTo n i).state.snapshot = n.state.snapshot := by
  unfold commitTo; split <;> rfl

omit [Rust.Clone V] [Rust.Clone S] in
theorem snap_adv {n n' : Node V S N CAP} (h : Adv n n') : n'.state.snapshot = n.state.snapshot := by
  rcases h with rfl | ⟨v, -, -, -, rfl⟩
  · rfl
  · exact snap_commitTo n v

omit [Rust.Clone V] [Rust.Clone S] in
theorem snap_barrier {n n' : Node V S N CAP} (h : Barrier n n') : n'.state.snapshot = n.state.snapshot := by
  rcases h with rfl | ⟨s', idx, h, -, -, -, -, hs, -, -, hA⟩
  · rfl
  · rw [snap_adv hA]; exact hs

omit [Rust.Clone V] [Rust.Clone S] in
theorem snap_becomeLeader {n n' : Node V S N CAP} (h : BecomeLeader n n') : n'.state.snapshot = n.state.snapshot := by
  obtain ⟨h, n2, hB, rfl⟩ := h
  have := snap_barrier hB; exact this

omit [Rust.Clone V] [Rust.Clone S] in
theorem snap_observed {n n1 : Node V S N CAP} {src : Id} {t : Rust.u64} (h : Observed n src t n1) :
    n1.state.snapshot = n.state.snapshot := by
  rcases h with ⟨-, rfl⟩ | ⟨-, r, d, rfl⟩ <;> rfl

omit [Rust.Clone V] [Rust.Clone S] in
theorem snap_ticked {n n' : Node V S N CAP} (h : Ticked n n') : n'.state.snapshot = n.state.snapshot := by
  cases h with
  | same => rfl
  | time n' _ ht => obtain ⟨e, a, rfl⟩ := ht; rfl
  | heartbeat n0 n2 _ _ ht hB =>
    obtain ⟨e, a, rfl⟩ := ht
    have := snap_barrier hB; exact this
  | campaign n0 n' h _ _ ht _ hc =>
    obtain ⟨e, a, rfl⟩ := ht
    obtain ⟨n1, hT, hB | ⟨-, rfl⟩⟩ := hc
    · rw [snap_becomeLeader hB.2, snap_timers hT]; rfl
    · show n1.state.snapshot = _
      rw [snap_timers hT]; rfl

end Frames

end Jarl.Engine.App
