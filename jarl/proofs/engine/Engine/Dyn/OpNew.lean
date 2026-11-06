import Engine.Dyn.Spec

/-!
# Starting a dynamic node: `ClusterState::restore` and `Cluster::new`
-/

set_option linter.unusedSectionVars false

namespace Jarl.Engine.Dyn
open Jarl Jarl.Engine

variable {V S : Type} {MAX CAP : Nat} [Rust.Clone V] [Rust.Clone S]

theorem flatten_inj {α β : Type} (f : α → β) : ∀ (l : List (Option α)), ((Rust.Iter.flatten l).map f).Nodup →
    ∀ i j (hi : i < l.length) (hj : j < l.length) a b, l[i] = some a → l[j] = some b → f a = f b → i = j
  | [], _, i, _, hi, _, _, _, _, _, _ => absurd hi (by simp)
  | none :: t, hn, i, j, hi, hj, a, b, ha, hb, he => by
    have hn' : ((Rust.Iter.flatten t).map f).Nodup := by simpa [Rust.Iter.flatten] using hn
    cases i with
    | zero => simp at ha
    | succ i =>
      cases j with
      | zero => simp at hb
      | succ j =>
        simp only [List.getElem_cons_succ] at ha hb
        have := flatten_inj f t hn' i j (by simp at hi; omega) (by simp at hj; omega) a b ha hb he
        omega
  | some y :: t, hn, i, j, hi, hj, a, b, ha, hb, he => by
    have hn2 : (f y :: (Rust.Iter.flatten t).map f).Nodup := by simpa [Rust.Iter.flatten] using hn
    rw [List.nodup_cons] at hn2
    obtain ⟨hy, hn'⟩ := hn2
    have hmem : ∀ k (hk : k < t.length) c, t[k] = some c → f c ∈ (Rust.Iter.flatten t).map f := by
      intro k hk c hc
      apply List.mem_map_of_mem
      simp only [Rust.Iter.flatten, List.mem_filterMap, id]
      exact ⟨some c, by rw [← hc]; exact List.getElem_mem hk, rfl⟩
    cases i with
    | zero =>
      cases j with
      | zero => rfl
      | succ j =>
        simp only [List.getElem_cons_zero, List.getElem_cons_succ, Option.some.injEq] at ha hb
        subst ha
        exact absurd (he ▸ hmem j (by simp at hj; omega) b hb) hy
    | succ i =>
      cases j with
      | zero =>
        simp only [List.getElem_cons_zero, List.getElem_cons_succ, Option.some.injEq] at ha hb
        subst hb
        exact absurd (he.symm ▸ hmem i (by simp at hi; omega) a ha) hy
      | succ j =>
        simp only [List.getElem_cons_succ] at ha hb
        have := flatten_inj f t hn' i j (by simp at hi; omega) (by simp at hj; omega) a b ha hb he
        omega

/-- Distinct identities give distinct peer slots. -/
theorem genesis_peers_unique (g : Membership MAX) (hg : Jarl.Contracts.Membership.UniqueIdentities g) :
    ∀ i j : Fin MAX, ∀ x, g.peers[i] = some x → g.peers[j] = some x → i = j := by
  intro i j x hi hj
  simp only [Membership.peers, Fin.getElem_fin, Vector.getElem_map, Option.map_eq_some_iff] at hi hj
  obtain ⟨a, ha, rfl⟩ := hi
  obtain ⟨b, hb, hab⟩ := hj
  apply Fin.ext
  exact flatten_inj Member.id g.members.toList hg i.val j.val (by simp) (by simp) a b
    (by simpa using ha) (by simpa using hb) hab.symm

/-- The position of `me` in a list of distinct peers is its unique slot, or `MAX`. -/
theorem local_of_unique (P : Vector (Option Id) MAX) (me : Id) (hMw : MAX < 2 ^ Rust.usizeBits)
    (hu : ∀ i j : Fin MAX, ∀ x, P[i] = some x → P[j] = some x → i = j) :
    ((Rust.Iter.position P.toList (fun p => p == some me)).getD (Rust.usizeOf MAX)).val ≤ MAX ∧
    ∀ i (hi : i < MAX), P[i] = some me ↔ i = ((Rust.Iter.position P.toList (fun p => p == some me)).getD (Rust.usizeOf MAX)).val := by
  cases hp : Rust.Iter.position P.toList (fun p => p == some me) with
  | none =>
    have hv : (Rust.usizeOf MAX).val = MAX := Rust.val_usizeOf _ hMw
    simp only [Option.getD_none, hv]
    refine ⟨Nat.le_refl _, fun i hi => ⟨fun he => ?_, fun e => by omega⟩⟩
    simp only [Rust.Iter.position, Option.map_eq_none_iff, List.findIdx?_eq_none_iff] at hp
    have := hp (some me) (by simp [List.mem_iff_getElem]; exact ⟨i, hi, by simpa using he⟩)
    simp at this
  | some s =>
    obtain ⟨hs, hps⟩ := position_some _ _ _ (by simpa using hMw) hp
    have hsM : s.val < MAX := by simpa using hs
    have hPs : P[s.val] = some me := by simpa using hps
    simp only [Option.getD_some]
    refine ⟨Nat.le_of_lt hsM, fun i hi => ⟨fun he => ?_, fun e => by subst e; exact hPs⟩⟩
    exact congrArg Fin.val (hu ⟨i, hi⟩ ⟨s.val, hsM⟩ me he hPs)

/-- A node started from a well-formed checkpoint and a genesis configuration with
    distinct identities. -/
theorem cluster_new_rel (settings : Settings) (saved : ClusterState V S MAX CAP) (c : Cluster V S MAX CAP)
    (hMAX : MAX < 2 ^ (Rust.usizeBits - 1)) (hCAP : CAP < 2 ^ (Rust.usizeBits - 1))
    (hl : Layout saved.state) (hc : Contig saved.state)
    (hg : Jarl.Contracts.Membership.UniqueIdentities saved.genesis)
    (h : Cluster.new settings saved = pure (.Ok c)) :
    4 ≤ CAP ∧ FreshD saved.genesis saved.id saved.state c.node := by
  have hCw : CAP < 2 ^ Rust.usizeBits := by uomega
  have hMw : MAX < 2 ^ Rust.usizeBits := by uomega
  unfold Cluster.new at h
  split at h
  · exact absurd (Rust.pure_inj h) (by simp)
  rename_i hcap
  have hcap4 : 4 ≤ CAP := by
    apply Classical.byContradiction; intro hn; apply hcap
    have h4 : ((4 : Rust.usize) : Nat) = 4 := rfl
    simp only [decide_eq_true_eq, Fin.lt_def, Rust.val_usizeOf _ hCw, h4]; omega
  refine ⟨hcap4, ?_⟩
  obtain ⟨t1, hb, h⟩ := Rust.bind_eq_pure h
  unfold Node.build at hb
  split at hb
  · cases Rust.pure_inj hb; exact absurd (Rust.pure_inj h) (by simp)
  rename_i hcfg
  obtain ⟨n1, hr, hb⟩ := Rust.bind_eq_pure hb
  obtain ⟨n2, he, hb⟩ := Rust.bind_eq_pure hb
  cases Rust.pure_inj hb
  simp only [pure_bind] at h
  cases Rust.pure_inj h
  dsimp only at hcfg hr
  simp only [Bool.or_eq_true, beq_iff_eq, decide_eq_true_eq, not_or] at hcfg
  obtain ⟨⟨⟨-, hhb⟩, hel⟩, hel2⟩ := hcfg
  have hdiv : (Rust.divK (Rust.umax 64) 2).val = 2 ^ 63 - 1 := by decide
  have hhb' : 0 < settings.heartbeat_ticks.val := by
    have := fun e => hhb (Fin.ext e); simp at this; omega
  rw [Fin.le_def] at hel
  rw [GT.gt, Fin.lt_def, hdiv] at hel2
  obtain ⟨r, ⟨hshape, hkept, hu⟩, hmem, hor⟩ := refresh_rel _ _ rfl hl hc hMw
    (by dsimp only; omega) (by dsimp only; omega) (genesis_peers_unique _ hg) hr
  dsimp only at hor hkept hu hmem
  rcases hor with rfl | ⟨hrole, -⟩
  rotate_left; · cases hrole
  have hcfgr : r.config = { id := saved.id, members := Vector.replicate MAX saved.id, heartbeat_ticks := settings.heartbeat_ticks, election_ticks := settings.election_ticks, seed := settings.seed } := by
    rw [hshape]
  have hM : r.membership = memOf saved.state saved.genesis := by rw [hshape]
  obtain ⟨n3, he3, rd, dd, rfl⟩ := reset_timers' ({ r with «local» := (Rust.Iter.position r.peers.toList (fun p => p == some saved.id)).getD (Rust.usizeOf MAX) } : DNode V S MAX CAP)
    (by simp only [hcfgr]; omega) (by simp only [hcfgr]; omega)
  cases Rust.pure_inj (he3.symm.trans he)
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  all_goals try (dsimp only; rw [hshape]; done)
  all_goals try (dsimp only; rw [hshape]; rfl)
  · intro j
    rcases hkept j with ⟨-, a2, -, -, a5, a6⟩ | ⟨-, x, -, -, -, b1, -, -, b4, b5⟩
    · dsimp only
      rw [a2, a5, a6]
      simp [Rust.Slice.from_fn]
    · exact ⟨b5, b1, b4⟩
  · simp only [hcfgr]; omega
  · simp only [hcfgr]; omega
  · simp only [hcfgr]; omega
  · exact hu
  · intro id hid; exact hmem id (hM ▸ hid)
  · exact (local_of_unique r.peers saved.id hMw hu).1
  · exact (local_of_unique r.peers saved.id hMw hu).2

end Jarl.Engine.Dyn
