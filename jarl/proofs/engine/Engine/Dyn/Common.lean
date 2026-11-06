import Engine.Dyn.Frame
import Engine.Dyn.OpAppend
import Engine.Dyn.OpNew

/-!
# Facts shared by the preservation proofs

`DynOk` survives every update the operations make: timer and bookkeeping
changes, hard-state changes, and log changes followed by `refresh_membership`.
-/

set_option linter.unusedSectionVars false

namespace Jarl.Engine.Dyn
open Jarl Jarl.Engine

variable {V S : Type} {MAX CAP K : Nat} [Rust.Clone V] [Rust.Clone S]

/-- `Pre` from `DynOk`. -/
theorem DynOk.pre {g : Membership MAX} {me : Id} {n : DNode V S MAX CAP} (h : DynOk g me n) : Pre n where
  hooks := h.hooks
  layout := h.layout
  contig := h.contig
  n_lt := by have := h.n_lt; uomega
  cap_lt := by have := h.cap_lt; uomega
  e0 := by have := h.heartbeat; have := h.election; omega
  e1 := h.election_le
  uniq := fun i j x hi hj => Fin.ext (h.peers_nodup i j i.isLt j.isLt x hi hj)

/-- Updates that keep the configuration, log, peers and slot of a node. -/
theorem dynOk_frame {g : Membership MAX} {me : Id} {n n' : DNode V S MAX CAP} (h : DynOk g me n)
    (hcfg : n'.config = n.config) (hhk : n'.hooks = n.hooks) (hb : n'.bootstrap = n.bootstrap)
    (hp : n'.peers = n.peers) (hl : n'.local = n.local) (hm : n'.membership = n.membership)
    (hmem : memOf n'.state g = memOf n.state g) (hL : Layout n'.state) (hC : Contig n'.state)
    (hpv : ∀ t, n'.prevoting = some t → n'.role = .Follower ∧ t.val = n'.state.hard.term.val + 1) :
    DynOk g me n' where
  n_pos := h.n_pos
  n_lt := h.n_lt
  cap_ge := h.cap_ge
  cap_lt := h.cap_lt
  hooks := by rw [hhk]; exact h.hooks
  bootstrap := by rw [hb]; exact h.bootstrap
  id := by rw [hcfg]; exact h.id
  heartbeat := by rw [hcfg]; exact h.heartbeat
  election := by rw [hcfg]; exact h.election
  election_le := by rw [hcfg]; exact h.election_le
  layout := hL
  contig := hC
  membership := by rw [hm, hmem]; exact h.membership
  peers_nodup := by rw [hp]; exact h.peers_nodup
  members := by rw [hm, hp]; exact h.members
  local_le := by rw [hl]; exact h.local_le
  local_slot := by rw [hl, hp]; exact h.local_slot
  prevoting := hpv

/-- Updates of fields other than configuration, log, peers, slot, role, prevoting and term. -/
theorem dynOk_same_hard {g : Membership MAX} {me : Id} {n : DNode V S MAX CAP} (_h : DynOk g me n) (hd : HardState) :
    memOf { n.state with hard := hd } g = memOf n.state g := rfl

/-- A node after `refresh_membership`, from a node with valid settings, log and unique peers. -/
theorem dynOk_refresh {g : Membership MAX} {me : Id} (n0 n1 : DNode V S MAX CAP)
    (hMAX0 : 0 < MAX) (hMAX : MAX < 2 ^ (Rust.usizeBits - 1)) (hcap : 4 ≤ CAP) (hCAP : CAP < 2 ^ (Rust.usizeBits - 1))
    (hhk : n0.hooks = some hooksC) (hb : n0.bootstrap = g) (hid : n0.config.id = me)
    (hh : 0 < n0.config.heartbeat_ticks.val) (he : n0.config.heartbeat_ticks.val < n0.config.election_ticks.val)
    (hel : n0.config.election_ticks.val ≤ 2 ^ 63) (hL : Layout n0.state) (hC : Contig n0.state)
    (hpv : ∀ t, n0.prevoting = some t → n0.role = .Follower ∧ t.val = n0.state.hard.term.val + 1)
    (hr : Refresh n0 n1) : DynOk g me n1 := by
  subst hb hid
  obtain ⟨n2, ⟨hshape, -, hu⟩, hmem, hfin⟩ := hr
  obtain ⟨P, Vo, A, Nx, Mt, O, rfl⟩ : ∃ P Vo A Nx Mt O, n2 = { n0 with membership := memOf n0.state n0.bootstrap, peers := P, votes := Vo, active := A, «next» := Nx, matched := Mt, outbox := O } :=
    ⟨_, _, _, _, _, _, hshape⟩
  have hM64 : MAX < 2 ^ Rust.usizeBits := by uomega
  obtain ⟨hle, hslot⟩ := local_of_unique P n0.config.id hM64 hu
  have base : DynOk n0.bootstrap n0.config.id { n0 with membership := memOf n0.state n0.bootstrap, peers := P, votes := Vo, active := A, «next» := Nx, matched := Mt, outbox := O, «local» := (Rust.Iter.position P.toList fun p => p == some n0.config.id).getD (Rust.usizeOf MAX) } :=
    { n_pos := hMAX0, n_lt := hMAX, cap_ge := hcap, cap_lt := hCAP, hooks := hhk, bootstrap := rfl, id := rfl,
      heartbeat := hh, election := he, election_le := hel, layout := hL, contig := hC,
      membership := rfl
      peers_nodup := fun i j hi hj x h1 h2 => congrArg Fin.val (hu ⟨i, hi⟩ ⟨j, hj⟩ x h1 h2)
      members := fun id hid' => by
        obtain ⟨i, hi⟩ := hmem id hid'
        exact ⟨i.val, i.isLt, hi⟩
      local_le := hle
      local_slot := hslot
      prevoting := hpv }
  simp only at hfin
  rcases hfin with rfl | ⟨-, -, -, ht⟩
  · exact base
  · obtain ⟨r, d, rfl⟩ := ht
    exact dynOk_frame base rfl rfl rfl rfl rfl rfl rfl base.layout base.contig (by intro t h; cases h)

/-! ## Configurations of checkpoints -/

theorem memOf_fullLog (g : Membership MAX) (G : Ghost (Record V MAX) K) (s : DState V S MAX CAP) (hs : SnapOk g G s) :
    memOf s g = cfgOf g (fullLog G s) := by
  unfold memOf; rw [hs, fullLog_def, cfgOf_append]

/-- A contiguous run of indices after `b`, cut at `i`. -/
theorem takeWhile_contig (l : List (DEntry V MAX)) (b : Nat) (i : Rust.u64)
    (hc : ∀ k (h : k < l.length), (l[k]).id.index.val = b + k + 1) :
    l.takeWhile (fun e => decide (e.id.index ≤ i)) = l.take (i.val - b) := by
  induction l generalizing b with
  | nil => simp
  | cons e l ih =>
    have he := hc 0 (by simp)
    simp only [List.getElem_cons_zero] at he
    by_cases hle : e.id.index ≤ i
    · have hle' : e.id.index.val ≤ i.val := hle
      rw [List.takeWhile_cons_of_pos (by simpa using hle)]
      have hb : i.val - b = (i.val - (b + 1)) + 1 := by omega
      rw [hb, List.take_succ_cons, ih (b + 1) (fun k hk => by
        have := hc (k + 1) (by simp; omega); simp at this; omega)]
    · have hlt : i.val < e.id.index.val := by
        have : ¬ e.id.index.val ≤ i.val := hle; omega
      rw [List.takeWhile_cons_of_neg (by simpa using hle)]
      rw [show i.val - b = 0 by omega]; simp

/-- `membership_at(i)` at or after the snapshot boundary is the configuration of the first `i` entries. -/
theorem memAt_take (g : Membership MAX) (G : Ghost (Record V MAX) K) (s : DState V S MAX CAP)
    (hok : StateOk G s) (hs : SnapOk g G s) (i : Rust.u64) (hi : s.base.index.val ≤ i.val) :
    (memAt s g i).2 = cfgOf g ((fullLog G s).take i.val) := by
  rw [memAt_snd, takeWhile_contig _ s.base.index.val i hok.contig]
  have hb := boundary_len G s hok
  have hle : (boundary G s).length ≤ i.val := by rw [hb]; exact hi
  rw [fullLog_def, List.take_append, List.take_of_length_le hle, hb, cfgOf_append]
  have hs' : (memInit s g).2 = cfgOf g (boundary G s) := hs
  rw [hs']

theorem foldl_memStep_ge (l : List (DEntry V MAX)) (r : Rust.u64 × Membership MAX)
    (hge : ∀ e ∈ l, r.1.val ≤ e.id.index.val) (hp : l.Pairwise (fun a b => a.id.index.val < b.id.index.val)) :
    r.1.val ≤ (l.foldl memStep r).1.val ∧ ∀ e ∈ l, isCfg e → e.id.index.val ≤ (l.foldl memStep r).1.val := by
  induction l generalizing r with
  | nil => simp
  | cons e l ih =>
    simp only [List.foldl_cons]
    rw [List.pairwise_cons] at hp
    have h1 := hge e (by simp)
    cases hc : recCfg e.value with
    | none =>
      rw [show memStep r e = r by simp [memStep, hc]]
      obtain ⟨a, b⟩ := ih r (fun x hx => hge x (by simp [hx])) hp.2
      refine ⟨a, fun x hx hcx => ?_⟩
      rcases List.mem_cons.mp hx with rfl | hx
      · simp [isCfg, hc] at hcx
      · exact b x hx hcx
    | some m =>
      rw [show memStep r e = (e.id.index, m) by simp [memStep, hc]]
      obtain ⟨a, b⟩ := ih (e.id.index, m) (fun x hx => Nat.le_of_lt (hp.1 x hx)) hp.2
      refine ⟨by simp only at a; omega, fun x hx hcx => ?_⟩
      rcases List.mem_cons.mp hx with rfl | hx
      · exact a
      · exact b x hx hcx

theorem contig_pairwise (l : List (DEntry V MAX)) (b : Nat) (hc : ∀ k (h : k < l.length), (l[k]).id.index.val = b + k + 1) :
    l.Pairwise (fun a b => a.id.index.val < b.id.index.val) := by
  rw [List.pairwise_iff_getElem]
  intro i j hi hj hij
  rw [hc i hi, hc j hj]; omega

/-- `membership_at(i)` reports a position at or after every configuration record among the first `i` entries. -/
theorem memAt_pos (g : Membership MAX) (G : Ghost (Record V MAX) K) (s : DState V S MAX CAP)
    (hok : StateOk G s) (i : Rust.u64) (hi : s.base.index.val ≤ i.val)
    (k : Nat) (hk : k < (fullLog G s).length) (hki : k < i.val) (hcfg : isCfg (fullLog G s)[k]) :
    k + 1 ≤ (memAt s g i).1.val := by
  have hb := boundary_len G s hok
  unfold memAt
  rw [takeWhile_contig _ s.base.index.val i hok.contig]
  have hcon : ∀ k' (h : k' < ((ret s).take (i.val - s.base.index.val)).length),
      (((ret s).take (i.val - s.base.index.val))[k']).id.index.val = s.base.index.val + k' + 1 := by
    intro k' h'; simp only [List.getElem_take]; exact hok.contig k' (by simp at h'; omega)
  have hinit : (memInit s g).1.val ≤ s.base.index.val := by
    unfold memInit; cases hsn : s.snapshot with
    | none => simp
    | some sn => simp [base_some s sn hsn]
  have hinit' : 0 < s.base.index.val → (memInit s g).1.val = s.base.index.val := by
    intro hpos; unfold memInit; cases hsn : s.snapshot with
    | none => simp [State.base, hsn, LogId.default] at hpos
    | some sn => simp [base_some s sn hsn]
  obtain ⟨hge, hcf⟩ := foldl_memStep_ge _ (memInit s g) (fun e he => by
      obtain ⟨k', hk', rfl⟩ := List.getElem_of_mem he
      rw [hcon k' hk']; omega) (contig_pairwise _ _ hcon)
  by_cases hkb : k < s.base.index.val
  · rw [hinit' (by omega)] at hge; omega
  · obtain ⟨hr, hget⟩ := fullLog_getElem_ret G s hok k (by omega) hk
    rw [hget] at hcfg
    have hmem : (ret s)[k - s.base.index.val] ∈ (ret s).take (i.val - s.base.index.val) := by
      rw [List.mem_iff_getElem]
      exact ⟨k - s.base.index.val, by simp; omega, by simp⟩
    have := hcf _ hmem hcfg
    rw [hok.contig _ hr] at this; omega

end Jarl.Engine.Dyn
