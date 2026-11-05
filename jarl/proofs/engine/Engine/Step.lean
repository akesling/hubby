import Engine.Ghost
import Engine.Append
import Engine.Replicated
import Engine.Host

/-!
# `step`: one incoming message on a fixed node

Every successful run of `Node::step` follows one of the paths of `Stepped`.
Messages only a dynamic engine sends (`PreVote`, `PreVoted`, `AppendBatch`)
are excluded by hypothesis: no fixed node produces them.
-/

namespace Jarl.Engine
open Jarl

variable {V S : Type} {N CAP : Nat} [Rust.Clone V] [Rust.Clone S]

/-- Queue descriptor `o` for slot `a`. -/
def queue (n : Node V S N CAP) (a : Fin N) (o : Outbound) : Node V S N CAP :=
  { n with outbox := n.outbox.set a.val (some o) a.isLt }

/-- Observing a message's term: record the sender, and step down to a follower
    of the higher term with no vote (a pending durable change). -/
def Observed (n : Node V S N CAP) (src : Id) (t : Rust.u64) (n1 : Node V S N CAP) : Prop :=
  let n0 : Node V S N CAP := { n with request_from := some src }
  (t.val ≤ n.state.hard.term.val ∧ n1 = n0) ∨
  (n.state.hard.term.val < t.val ∧
    Timers { n0 with state := { n0.state with hard := { n0.state.hard with term := t, voted_for := none } }, dirty := true, role := .Follower, prevoting := none, leader := none } n1)

/-- Following a leader of the current term (`follow(Some(src))`). -/
def Following (n : Node V S N CAP) (src : Id) (n2 : Node V S N CAP) : Prop :=
  Timers { n with role := .Follower, prevoting := none, leader := some src, leader_age := 0 } n2

inductive Stepped (n : Node V S N CAP) (a : Fin N) (src : Id) : Message V S → Node V S N CAP → Prop
  /-- Busy, invalid, or from an unexpected identity: nothing changes. -/
  | same (m : Message V S) : Stepped n a src m n
  /-- A message of an older term: optionally answer with a rejection. -/
  | stale (m : Message V S) (n1 n' : Node V S N CAP) :
      Idle n → Observed n src m.term n1 → m.term.val < n1.state.hard.term.val →
      (n' = n1 ∨ n' = queue n1 a (.Voted false) ∨ ∃ i, n' = queue n1 a (.Replicated i (some (.Conflict 1)))) →
      Stepped n a src m n'
  /-- `Vote`: grant when not yet voted for another and the candidate's log is at
      least as up to date; always answer. -/
  | vote (t : Rust.u64) (last : LogId) (n1 n2 : Node V S N CAP) (g : Bool) :
      Idle n → Observed n src t n1 → n1.state.hard.term = t →
      g = decide ((n1.state.hard.voted_for = none ∨ n1.state.hard.voted_for = some src) ∧
        upToDate last (lastId n1.state)) →
      (g = false → n2 = n1) →
      (g = true → Timers { n1 with state := { n1.state with hard := { n1.state.hard with voted_for := some src } }, dirty := (n1.dirty || decide (n1.state.hard.voted_for ≠ some src)) } n2) →
      Stepped n a src (.Vote t last) (queue n2 a (.Voted g))
  /-- `Voted`: a candidate counts a grant and may win. -/
  | voted (t : Rust.u64) (g : Bool) (n1 n' : Node V S N CAP) :
      Idle n → Observed n src t n1 → n1.state.hard.term = t →
      ((¬ (n1.role = .Candidate ∧ g = true) ∧ n' = n1) ∨
        (n1.role = .Candidate ∧ g = true ∧
          let nv : Node V S N CAP := { n1 with votes := n1.votes.set a.val true a.isLt }
          ((¬ N / 2 < (List.finRange N).countP (fun j => nv.votes[j]) ∧ n' = nv) ∨
            (N / 2 < (List.finRange N).countP (fun j => nv.votes[j]) ∧ BecomeLeader nv n')))) →
      Stepped n a src (.Voted t g) n'
  /-- `Append`: follow the sender, append, and answer. -/
  | append (t : Rust.u64) (prev : LogId) (entry : Option (Entry V)) (commit : Rust.u64)
      (n1 n2 n3 : Node V S N CAP) (r : Rust.u64 × Option Rejection) :
      Idle n → Observed n src t n1 → n1.state.hard.term = t → Following n1 src n2 →
      Node.append n2 prev entry commit = pure (r, n3) →
      Stepped n a src (.Append t prev entry commit) (queue n3 a (.Replicated r.1 r.2))
  /-- `Install`: follow the sender; reject a conflict below the commit index,
      install a newer snapshot, and answer. -/
  | install (t : Rust.u64) (snap : Snapshot S) (n1 n2 n3 : Node V S N CAP) (rej : Option Rejection) :
      Idle n → Observed n src t n1 → n1.state.hard.term = t → Following n1 src n2 →
      ((snap.last.index.val ≤ n2.state.hard.commit.val ∧
          Rust.Option.is_some_and (State.id_at n2.state snap.last.index) (fun id => id != snap.last) = true ∧
          rej.isSome ∧ n3 = n2) ∨
        (¬ (snap.last.index.val ≤ n2.state.hard.commit.val ∧
          Rust.Option.is_some_and (State.id_at n2.state snap.last.index) (fun id => id != snap.last) = true) ∧
          rej = none ∧
          ((¬ (n2.state.base.index.val < snap.last.index.val ∧
              (n2.state.hard.commit.val < snap.last.index.val ∨ idAt n2.state snap.last.index.val = some snap.last))
              ∧ n3 = n2) ∨
            (n2.state.base.index.val < snap.last.index.val ∧
              (n2.state.hard.commit.val < snap.last.index.val ∨ idAt n2.state snap.last.index.val = some snap.last) ∧
              ∃ s' lf, State.install n2.state snap = pure s' ∧
                n3 = { n2 with state := s', dirty := true, snapshot_changed := true, log_from := lf })))) →
      Stepped n a src (.Install t snap) (queue n3 a (.Replicated snap.last.index rej))
  /-- `Replicated`: a leader records the reply. -/
  | replicated (t index : Rust.u64) (rej : Option Rejection) (n1 n' : Node V S N CAP) :
      Idle n → Observed n src t n1 → n1.state.hard.term = t →
      ((n1.role ≠ .Leader ∧ n' = n1) ∨
        (n1.role = .Leader ∧ Node.replicated n1 (Rust.ofNat a.val) index rej = pure n')) →
      Stepped n a src (.Replicated t index rej) n'

/-- Messages a fixed engine can receive from a fixed cluster. -/
def FixedMessage (m : Message V S) : Prop :=
  match m with
  | .PreVote .. | .PreVoted .. | .AppendBatch .. => False
  | _ => True

omit [Rust.Clone V] [Rust.Clone S] in
theorem fixed_req (ids : Vector Id N) (n : Node V S N CAP) (hf : Fixed ids n) (x : Option Id) :
    Fixed ids { n with request_from := x } := { hf with layout := hf.layout, contig := hf.contig }

theorem observe_up (ids : Vector Id N) (n : Node V S N CAP) (hf : Fixed ids n) (src : Id) (t : Rust.u64)
    (ht : n.state.hard.term.val < t.val) :
    ∃ n1, Node.follow { n with request_from := some src, state := { n.state with hard := { n.state.hard with term := t, voted_for := none } }, dirty := true } none = pure n1 ∧
      Observed n src t n1 ∧ Fixed ids n1 ∧ n1.state.hard.term = t := by
  have hX : Fixed ids { n with request_from := some src, state := { n.state with hard := { n.state.hard with term := t, voted_for := none } }, dirty := true } :=
    { hf with layout := hf.layout, contig := hf.contig }
  obtain ⟨n1, hfo, hT⟩ := follow_eq ids _ hX none
  refine ⟨n1, hfo, Or.inr ⟨ht, ?_⟩, fixed_timers ids _ _ ?_ hT, ?_⟩
  · simpa using hT
  · exact { hX with layout := hX.layout, contig := hX.contig, prevoting := rfl }
  · obtain ⟨r, d, rfl⟩ := hT; rfl

theorem follow_some (ids : Vector Id N) (n : Node V S N CAP) (hf : Fixed ids n) (src : Id) :
    ∃ n2, Node.follow n (some src) = pure n2 ∧ Following n src n2 ∧ Fixed ids n2 := by
  obtain ⟨n2, hfo, hT⟩ := follow_eq ids _ hf (some src)
  have hT' : Following n src n2 := by unfold Following; simpa using hT
  have hY : Fixed ids { n with role := .Follower, prevoting := none, leader := some src, leader_age := 0 } :=
    { hf with layout := hf.layout, contig := hf.contig, prevoting := rfl }
  exact ⟨n2, hfo, hT', fixed_timers ids _ _ hY hT'⟩

theorem send_peer (n : Node V S N CAP) (a : Fin N) (o : Outbound) (hN : N < 2 ^ 64) :
    Node.send n (Rust.ofNat a.val) o = pure (queue n a o) := by
  have hav : (Rust.ofNat a.val : Rust.usize).val = a.val := by simp [Rust.ofNat]; omega
  rw [send_eq n _ o hN (by rw [hav]; exact a.isLt)]
  unfold queue; simp only [hav]

theorem reply_peer (n : Node V S N CAP) (a : Fin N) (i : Rust.u64) (rj : Option Rejection) (hN : N < 2 ^ 64) :
    Node.reply n (Rust.ofNat a.val) i rj = pure (queue n a (.Replicated i rj)) := by
  simp [Node.reply, send_peer n a _ hN]

theorem set_peer {α : Type} (v : Vector α N) (a : Fin N) (x : α) (hN : N < 2 ^ 64) :
    Rust.Slice.set v (Rust.ofNat a.val) x = pure (v.set a.val x a.isLt) := by
  have hav : (Rust.ofNat a.val : Rust.usize).val = a.val := by simp [Rust.ofNat]; omega
  rw [Rust.Slice.set_ok _ _ _ (by rw [hav]; exact a.isLt)]
  simp only [hav]

theorem granted_eq (v : Option Id) (src : Id) (l o : LogId) :
    (Rust.Option.is_none_or v (fun id => id == src) &&
      (decide (l.term > o.term) || (l.term == o.term && decide (l.index ≥ o.index)))) =
    decide ((v = none ∨ v = some src) ∧ upToDate l o) := by
  rw [Bool.eq_iff_iff]
  cases v <;> simp [Rust.Option.is_none_or, upToDate, Fin.lt_def, Fin.le_def, Fin.ext_iff] <;> omega

omit [Rust.Clone V] [Rust.Clone S] in
theorem vote_same (n1 : Node V S N CAP) (src : Id) (hv : n1.state.hard.voted_for = some src) :
    ({ n1 with state := { n1.state with hard := { n1.state.hard with voted_for := some src } }, dirty := (n1.dirty || decide (n1.state.hard.voted_for ≠ some src)) } : Node V S N CAP) = n1 := by
  rcases n1 with ⟨_, ⟨⟨_, _, _⟩, _, _, _⟩⟩
  simp only at hv
  subst hv
  simp

theorem observe_split {β : Type} (ids : Vector Id N) (n : Node V S N CAP) (hf : Fixed ids n) (src : Id)
    (t : Rust.u64) (K : Node V S N CAP → Rust.M β) (x : β)
    (h : (if decide (t > n.state.hard.term) = true then
        (Node.follow { n with request_from := some src, state := { n.state with hard := { n.state.hard with term := t, voted_for := none } }, dirty := true } none >>= K)
      else K { n with request_from := some src }) = pure x) :
    ∃ n1, Observed n src t n1 ∧ Fixed ids n1 ∧ t.val ≤ n1.state.hard.term.val ∧ K n1 = pure x := by
  by_cases ht : n.state.hard.term < t
  · rw [if_pos (decide_eq_true ht)] at h
    obtain ⟨n1, hfo, hO, hF1, hT1⟩ := observe_up ids n hf src t (Fin.lt_def.mp ht)
    rw [hfo, pure_bind] at h
    exact ⟨n1, hO, hF1, by rw [hT1]; exact Nat.le_refl _, h⟩
  · rw [if_neg (by simpa using ht)] at h
    have ht' : t.val ≤ n.state.hard.term.val := by rw [Fin.lt_def] at ht; omega
    exact ⟨_, Or.inl ⟨ht', rfl⟩, fixed_req ids n hf _, ht', h⟩

theorem step_rel [Rust.LawfulClone S] (ids : Vector Id N) (n : Node V S N CAP) (hf : Fixed ids n) (a : Fin N)
    (env : Envelope V S) (hsrc : env.from = ids[a]) (hm : FixedMessage env.message)
    (r : Rust.Result Unit Error) (n' : Node V S N CAP) (h : Node.step n env = pure (r, n')) :
    Stepped n a env.from env.message n' := by
  have hN : N < 2 ^ 64 := by have := hf.n_lt; omega
  have hpos : Rust.Iter.position n.peers.toList (fun id => id == some env.from) = some (Rust.ofNat a.val) := by
    rw [hf.peers, hsrc]; exact position_member ids hf.nodup a.val a.isLt
  rcases env with ⟨src, dst, msg⟩
  simp only at hsrc hpos ⊢
  have hf0 := fixed_req ids n hf (some src)
  cases msg with
  | PreVote => exact hm.elim
  | PreVoted => exact hm.elim
  | AppendBatch => exact hm.elim
  | Vote t last => ?vote
  | Voted t g => ?voted
  | Append t prev entry commit => ?append
  | Install t snap => ?install
  | Replicated t index rej => ?replicated
  all_goals
    unfold Node.step at h
    cases hA : Node.available n
    case Err e =>
      simp only [hA] at h
      obtain rfl := (congrArg Prod.snd (pure_inj h))
      exact .same _
    rename_i u
    have hI := idle_of_available n hA
    simp only [hA, hpos, Option.orElse, Rust.Option.ok_or, pure_bind] at h
    by_cases hc : (!(src == n.config.id || dst != n.config.id)) = true
    case neg =>
      rw [if_neg hc] at h
      obtain rfl := (congrArg Prod.snd (pure_inj h))
      exact .same _
    rw [if_pos hc] at h
    obtain ⟨v, -, h1⟩ := bind_eq_pure _ _ _ h
    clear h
    cases v
    case false =>
      rw [if_pos (show (!false) = true from rfl)] at h1
      obtain rfl := (congrArg Prod.snd (pure_inj h1))
      exact .same _
    rw [if_neg (by decide : ¬ (!true) = true)] at h1
    have hk : ∀ b c : Bool, (n.hooks.isSome && b && c) = false := by simp [hf.hooks]
    rw [hk, if_neg (by decide : ¬ (false = true))] at h1
    dsimp only [Message.term] at h1
    obtain ⟨n1, hO, hF1, hle, h⟩ := observe_split ids n hf src t _ _ h1
    clear hc hk hpos hA h1 hf0
    by_cases hs : t.val < n1.state.hard.term.val
    · have hd : t < n1.state.hard.term := Fin.lt_def.mpr hs
      simp only [hd, decide_true, if_true] at h
      try simp only [send_peer _ _ _ hN, reply_peer _ _ _ _ hN, pure_bind] at h
      obtain rfl := (congrArg Prod.snd (pure_inj h))
      exact Stepped.stale _ n1 _ hI hO hs
        (by first | exact Or.inl rfl | exact Or.inr (Or.inl rfl) | exact Or.inr (Or.inr ⟨_, rfl⟩))
    have hd : ¬ t < n1.state.hard.term := fun e => hs (Fin.lt_def.mp e)
    simp only [hd, decide_false, Bool.false_eq_true, if_false] at h
    have hT : n1.state.hard.term = t := Fin.ext (by omega)
    clear hs hle
  -- Vote
  · rw [last_eq _ hF1.layout.1, pure_bind, granted_eq] at h
    by_cases hG : (n1.state.hard.voted_for = none ∨ n1.state.hard.voted_for = some src) ∧ upToDate last (lastId n1.state)
    · rw [if_pos (by simpa using hG)] at h
      by_cases hv : n1.state.hard.voted_for = some src
      · rw [if_neg (by simp [hv])] at h
        obtain ⟨m6, hr, hT6⟩ := reset_timers ids n1 hF1
        rw [hr, pure_bind, send_peer _ _ _ hN, pure_bind] at h
        obtain rfl := (congrArg Prod.snd (pure_inj h))
        refine Stepped.vote t last n1 m6 _ hI hO hT rfl (fun hg => absurd hg (by simpa using hG)) (fun _ => ?_)
        rw [vote_same n1 src hv]; exact hT6
      · rw [if_pos (by simp [hv])] at h
        have hX : Fixed ids { n1 with state := { n1.state with hard := { n1.state.hard with voted_for := some src } }, dirty := true } :=
          { hF1 with layout := hF1.layout, contig := hF1.contig }
        obtain ⟨m6, hr, hT6⟩ := reset_timers ids _ hX
        rw [hr, pure_bind, send_peer _ _ _ hN, pure_bind] at h
        obtain rfl := (congrArg Prod.snd (pure_inj h))
        refine Stepped.vote t last n1 m6 _ hI hO hT rfl (fun hg => absurd hg (by simpa using hG)) (fun _ => ?_)
        have hd : (n1.dirty || decide (n1.state.hard.voted_for ≠ some src)) = true := by simp [hv]
        rw [hd]; exact hT6
    · rw [if_neg (by simpa using hG)] at h
      rw [send_peer _ _ _ hN, pure_bind] at h
      obtain rfl := (congrArg Prod.snd (pure_inj h))
      exact Stepped.vote t last n1 n1 _ hI hO hT rfl (fun _ => rfl) (fun hg => absurd hg (by simpa using hG))
  -- Voted
  · by_cases hc : n1.role = .Candidate ∧ g = true
    · rw [if_pos (by simp [hc.1, hc.2])] at h
      rw [set_peer _ _ _ hN, pure_bind] at h
      have hFv : Fixed ids { n1 with votes := n1.votes.set a.val true a.isLt } :=
        { hF1 with layout := hF1.layout, contig := hF1.contig }
      rw [election_quorum_eq ids _ hFv, pure_bind] at h
      by_cases hq : N / 2 < (List.finRange N).countP (fun j => ({ n1 with votes := n1.votes.set a.val true a.isLt } : Node V S N CAP).votes[j])
      · rw [if_pos (by simpa using hq)] at h
        obtain ⟨m8, hb, hB⟩ := become_leader_rel ids _ hFv
        rw [hb, pure_bind] at h
        obtain rfl := (congrArg Prod.snd (pure_inj h))
        exact Stepped.voted t g n1 m8 hI hO hT (Or.inr ⟨hc.1, hc.2, Or.inr ⟨hq, hB⟩⟩)
      · rw [if_neg (by simpa using hq)] at h
        obtain rfl := (congrArg Prod.snd (pure_inj h))
        exact Stepped.voted t g n1 _ hI hO hT (Or.inr ⟨hc.1, hc.2, Or.inl ⟨hq, rfl⟩⟩)
    · rw [if_neg (by simpa using hc)] at h
      obtain rfl := (congrArg Prod.snd (pure_inj h))
      exact Stepped.voted t g n1 n1 hI hO hT (Or.inl ⟨hc, rfl⟩)
  -- Append
  · obtain ⟨n2, hfo, hFol, hF2⟩ := follow_some ids n1 hF1 src
    rw [hfo, pure_bind] at h
    obtain ⟨⟨⟨idx, rj⟩, n3⟩, hx, h⟩ := bind_eq_pure _ _ _ h
    simp only [reply_peer _ _ _ _ hN, pure_bind] at h
    obtain rfl := (congrArg Prod.snd (pure_inj h))
    exact Stepped.append t prev entry commit n1 n2 n3 (idx, rj) hI hO hT hFol hx
  -- Install
  · obtain ⟨n2, hfo, hFol, hF2⟩ := follow_some ids n1 hF1 src
    rw [hfo, pure_bind] at h
    by_cases c1 : snap.last.index.val ≤ n2.state.hard.commit.val ∧
        Rust.Option.is_some_and (State.id_at n2.state snap.last.index) (fun id => id != snap.last) = true
    · rw [if_pos (by simp only [Bool.and_eq_true, decide_eq_true_eq, Fin.le_def]; exact c1)] at h
      rw [reply_peer _ _ _ _ hN, pure_bind] at h
      obtain rfl := (congrArg Prod.snd (pure_inj h))
      exact Stepped.install t snap n1 n2 n2 _ hI hO hT hFol (Or.inl ⟨c1.1, c1.2, rfl, rfl⟩)
    · rw [if_neg (by simp only [Bool.and_eq_true, decide_eq_true_eq, Fin.le_def]; exact c1)] at h
      by_cases c2 : n2.state.base.index.val < snap.last.index.val ∧
          (n2.state.hard.commit.val < snap.last.index.val ∨ idAt n2.state snap.last.index.val = some snap.last)
      · rw [if_pos (by rw [id_at_eq _ hF2.layout]; simpa [Fin.lt_def] using c2)] at h
        obtain ⟨s', hins, hsn, hhard, hr, hl'⟩ :=
          install_spec n2.state snap (by have := hF2.cap_lt; omega) hF2.layout hF2.contig
        have hc' := install_contig n2.state s' _ hF2.layout hF2.contig hsn hr
        by_cases c3 : (State.id_at n2.state snap.last.index != some snap.last) = true
        · rw [if_pos c3] at h
          obtain ⟨sc, hsc, h⟩ := bind_eq_pure _ _ _ h
          rw [Rust.LawfulClone.clone_eq _ _ hsc, hins, pure_bind] at h
          have hX : Fixed ids { n2 with state := s', log_from := Rust.checked_add snap.last.index 1 } :=
            { hF2 with layout := hl', contig := hc' }
          rw [refresh_fixed ids _ hX, pure_bind, reply_peer _ _ _ _ hN, pure_bind] at h
          obtain rfl := (congrArg Prod.snd (pure_inj h))
          exact Stepped.install t snap n1 n2 _ none hI hO hT hFol
            (Or.inr ⟨c1, rfl, Or.inr ⟨c2.1, c2.2, s', _, hins, rfl⟩⟩)
        · rw [if_neg c3] at h
          obtain ⟨sc, hsc, h⟩ := bind_eq_pure _ _ _ h
          rw [Rust.LawfulClone.clone_eq _ _ hsc, hins, pure_bind] at h
          have hX : Fixed ids { n2 with state := s' } := { hF2 with layout := hl', contig := hc' }
          rw [refresh_fixed ids _ hX, pure_bind, reply_peer _ _ _ _ hN, pure_bind] at h
          obtain rfl := (congrArg Prod.snd (pure_inj h))
          exact Stepped.install t snap n1 n2 _ none hI hO hT hFol
            (Or.inr ⟨c1, rfl, Or.inr ⟨c2.1, c2.2, s', n2.log_from, hins, rfl⟩⟩)
      · rw [if_neg (by rw [id_at_eq _ hF2.layout]; simpa [Fin.lt_def] using c2)] at h
        rw [reply_peer _ _ _ _ hN, pure_bind] at h
        obtain rfl := (congrArg Prod.snd (pure_inj h))
        exact Stepped.install t snap n1 n2 n2 none hI hO hT hFol (Or.inr ⟨c1, rfl, Or.inl ⟨c2, rfl⟩⟩)
  -- Replicated
  · by_cases hl : n1.role = .Leader
    · rw [if_pos (by simp [hl])] at h
      obtain ⟨m, hm, h⟩ := bind_eq_pure _ _ _ h
      obtain rfl := (congrArg Prod.snd (pure_inj h))
      exact Stepped.replicated t index rej n1 _ hI hO hT (Or.inr ⟨hl, hm⟩)
    · rw [if_neg (by simpa using hl)] at h
      obtain rfl := (congrArg Prod.snd (pure_inj h))
      exact Stepped.replicated t index rej n1 _ hI hO hT (Or.inl ⟨hl, rfl⟩)
end Jarl.Engine
