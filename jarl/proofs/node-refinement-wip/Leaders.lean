import Model
namespace Jarl.ElectionSafety

/-! Every leader of a reachable world won the election its term records. -/

/-- Each leader's term, identity and supporters are among the elections. -/
def Leads (w : World) : Prop :=
  ∀ v, (w.nodes v).role = .leader → ((w.nodes v).term, v, (w.nodes v).votes) ∈ w.elected

theorem leads_set {w : World} (h : Leads w) (v : Node) (s : Local) (extra : List (Nat × Node × List Node))
    (ok : s.role = .leader → (s.term, v, s.votes) ∈ w.elected ++ extra) :
    Leads { w with nodes := set w.nodes v s, elected := w.elected ++ extra } := by
  intro x hx
  rcases Classical.em (x = v) with rfl | ne
  · simp only [set_self] at hx ⊢; exact ok hx
  · simp only [set_other _ _ _ _ ne] at hx ⊢; exact List.mem_append_left _ (h x hx)

theorem leads_set' {w : World} (h : Leads w) (v : Node) (s : Local)
    (ok : s.role = .leader → (s.term, v, s.votes) ∈ w.elected) :
    Leads { w with nodes := set w.nodes v s } := by
  have := leads_set h v s [] (by simpa using ok)
  simpa using this

/-- A node that keeps its role, term and supporters stays a recorded leader. -/
theorem leads_keep {w : World} (h : Leads w) (v : Node) (s : Local)
    (keep : s.role = .leader → (w.nodes v).role = .leader ∧ s.term = (w.nodes v).term ∧
      s.votes = (w.nodes v).votes) :
    Leads { w with nodes := set w.nodes v s } :=
  leads_set' h v s fun hl => by
    obtain ⟨was, ht, hv⟩ := keep hl
    rw [ht, hv]; exact h v was

theorem adopt_keep (s : Local) (t : Nat) : (adopt s t).role = .leader →
    s.role = .leader ∧ (adopt s t).term = s.term ∧ (adopt s t).votes = s.votes := by
  unfold adopt stepDown
  by_cases ht : s.term < t <;> simp [ht]

theorem handleVote_keep (s : Local) (c t : Nat) (logOk : Bool) : (handleVote s c t logOk).role = .leader →
    s.role = .leader ∧ (handleVote s c t logOk).term = s.term ∧ (handleVote s c t logOk).votes = s.votes := by
  intro hl
  have key : (handleVote s c t logOk).role = (adopt s t).role ∧
      (handleVote s c t logOk).term = (adopt s t).term ∧
      (handleVote s c t logOk).votes = (adopt s t).votes := by
    unfold handleVote
    by_cases h1 : t < (adopt s t).term
    · simp [h1]
    · by_cases h2 : ((adopt s t).vote = none ∨ (adopt s t).vote = some c) ∧ logOk = true
      · simp [h1, h2]
      · simp [h1, h2]
  obtain ⟨hr, ht, hv⟩ := key
  obtain ⟨was, ht', hv'⟩ := adopt_keep s t (hr ▸ hl)
  exact ⟨was, ht.trans ht', hv.trans hv'⟩

theorem campaign_leads {w : World} (h : Leads w) (v : Node) : Leads (campaign w v) := by
  unfold campaign
  split
  · exact leads_set h v _ _ (fun _ => by simp)
  · exact leads_set' h v _ (fun hl => by simp at hl)

theorem leads_step {w w' : World} (inv : Inv w) (h : Leads w) (st : Step w w') : Leads w' := by
  cases st with
  | timeout v voter notLeader ready => exact campaign_leads h v
  | requestVote v c t logOk _ _ _ => exact leads_keep h v _ (handleVote_keep _ c t logOk)
  | voteReply v c t granted _ _ _ =>
    unfold handleVoted
    dsimp only
    split
    · rename_i cond
      have hc := cond.2.1
      repeat' split
      all_goals first
        | exact leads_set h v _ _ (fun _ => by simp)
        | exact leads_set' h v _ (fun hl => absurd (hc.symm.trans hl) (by decide))
    · exact leads_keep h v _ (adopt_keep _ t)
  | observe v t _ _ => exact leads_keep h v _ (fun hl => by simp [stepDown] at hl)
  | persist v _ =>
    unfold persist
    intro x hx
    rcases Classical.em (x = v) with rfl | ne
    · simp only [set_self] at hx ⊢; exact h x hx
    · simp only [set_other _ _ _ _ ne] at hx ⊢; exact h x hx
  | materialize v p rest _ _ =>
    unfold materialize
    intro x hx
    rcases Classical.em (x = v) with rfl | ne
    · simp only [set_self] at hx ⊢; exact h x hx
    · simp only [set_other _ _ _ _ ne] at hx ⊢; exact h x hx
  | crash v => exact leads_keep h v _ (fun hl => by simp at hl)
  | probe v voter notLeader ready =>
    unfold probe
    split
    · exact campaign_leads (leads_keep h v _ (fun hl => by simp at hl)) v
    · exact leads_keep h v _ (fun hl => by simp at hl)
  | answerProbe v c campaign granted _ _ _ => exact leads_keep h v _ (fun hl => ⟨hl, rfl, rfl⟩)
  | demote v => exact leads_keep h v _ (fun hl => by simp [demote] at hl)
  | forget v kept _ => exact leads_keep h v _ (fun hl => ⟨hl, rfl, rfl⟩)
  | preVoteReply v c term campaign granted _ _ _ =>
    unfold handlePreVoted
    dsimp only
    split
    · rename_i cond
      -- A probing node is a follower, and adopting kept it probing, so unchanged.
      have same : adopt (w.nodes v) term = w.nodes v := by
        by_cases ht : (w.nodes v).term < term
        · have := cond.1; simp [adopt, stepDown, ht] at this
        · simp [adopt, ht]
      have follower : (w.nodes v).role = .follower := by
        have := cond.1; rw [same] at this; exact (inv.probing v campaign this).2.1
      have keep : ∀ s : Local, s.role = (adopt (w.nodes v) term).role → s.role = .leader →
          (w.nodes v).role = .leader ∧ s.term = (w.nodes v).term ∧ s.votes = (w.nodes v).votes := by
        intro s hs hl; rw [hs, same, follower] at hl; cases hl
      repeat' split
      all_goals first
        | (refine campaign_leads (leads_keep h v _ ?_) v; exact keep _ rfl)
        | (refine leads_keep h v _ ?_; exact keep _ rfl)
    · exact leads_keep h v _ (adopt_keep _ term)

theorem reachable_leads {w : World} (reachable : Reachable w) : Leads w := by
  induction reachable with
  | initial voters unique => intro v hv; simp [initial, fresh] at hv
  | step r st ih => exact leads_step (reachable_inv r) ih st

/-- At most one leader per term in a reachable world. -/
theorem one_leader {w : World} (reachable : Reachable w) (a b : Node)
    (ha : (w.nodes a).role = .leader) (hb : (w.nodes b).role = .leader)
    (same : (w.nodes a).term = (w.nodes b).term) : a = b := by
  have la := reachable_leads reachable a ha
  have lb := reachable_leads reachable b hb
  rw [same] at la
  exact election_safety reachable _ a b _ _ la lb

end Jarl.ElectionSafety
