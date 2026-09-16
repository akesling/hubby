import StorageContracts
import ValidationContracts
open Provium.State
namespace Replication

-- Bridge between two generated semantic domains. These field reads are explicit
-- representation premises; Node::step's term handling and Node::append's choice
-- of the actual predecessor are not assumed to have been proved here.
theorem validation_supplies_successor
    (term previousIndex previousTerm index entryTerm hardTerm : Nat) (payload : PureValue)
    (hard previous incoming : InitStore)
    (termBound : term < 2^64) (previousIndexBound : previousIndex < 2^64)
    (previousTermBound : previousTerm < 2^64) (indexBound : index < 2^64)
    (entryTermBound : entryTerm < 2^64)
    (accepted : Jarl.node_Node_valid 256 (Validation.message "Append" term
      [("previous",Validation.logId previousIndex previousTerm),
       ("entry",.present (Validation.entry index entryTerm payload))]) = .ok true)
    (readPreviousIndex : recordWord previous ["index"] = some previousIndex)
    (readPreviousTerm : recordWord previous ["term"] = some previousTerm)
    (readIndex : recordWord incoming ["index"] = some index)
    (readTerm : recordWord incoming ["term"] = some entryTerm)
    (readHard : recordWord hard ["term"] = some hardTerm)
    (advancedTerm : term ≤ hardTerm) :
    Storage.LogSuccessor hard previous incoming := by
  obtain ⟨_,successor,positive,monotone,upper⟩ :=
    Validation.append_accepted term previousIndex previousTerm index entryTerm payload
      termBound previousIndexBound previousTermBound indexBound entryTermBound accepted
  exact ⟨previousIndex,index,previousTerm,entryTerm,hardTerm,
    readPreviousIndex,readIndex,readPreviousTerm,readTerm,readHard,
    successor,indexBound,positive,monotone,Nat.le_trans upper advancedTerm⟩

theorem validated_append_preserves_log
    (bits capacity : Nat) (view : α → Path → InitStore) (records : SelectionStore)
    (hard base last : InitStore) (state : BufferState α) (input : α)
    (term previousIndex previousTerm index entryTerm hardTerm : Nat) (payload : PureValue)
    (termBound : term < 2^64) (previousIndexBound : previousIndex < 2^64)
    (previousTermBound : previousTerm < 2^64) (indexBound : index < 2^64)
    (entryTermBound : entryTerm < 2^64)
    (accepted : Jarl.node_Node_valid 256 (Validation.message "Append" term
      [("previous",Validation.logId previousIndex previousTerm),
       ("entry",.present (Validation.entry index entryTerm payload))]) = .ok true)
    (readPreviousIndex : recordWord last ["index"] = some previousIndex)
    (readPreviousTerm : recordWord last ["term"] = some previousTerm)
    (readIndex : recordWord (view input ["id"]) ["index"] = some index)
    (readTerm : recordWord (view input ["id"]) ["term"] = some entryTerm)
    (readHard : recordWord hard ["term"] = some hardTerm)
    (advancedTerm : term ≤ hardTerm)
    (selected : selectRecord Jarl.state_State_truncate_ir.last.base records = base)
    (valid : Storage.LogRep view hard base state capacity)
    (space : state.len < capacity) (word : capacity < 2^bits)
    (fetched : lastRecord Jarl.state_State_truncate_ir.last (truncationView view records state) = .ok last) :
    ∃ next, Jarl.state_State_push bits capacity state input = .returned (.ok ()) next ∧
      Storage.LogRep view hard base next capacity ∧ next.len = state.len + 1 ∧
      ∀ position, position < state.len → next.slots[position]? = state.slots[position]? := by
  apply Storage.append_preserves_log bits capacity view records hard base last state input
    selected valid space word fetched
  exact validation_supplies_successor term previousIndex previousTerm index entryTerm hardTerm payload
    hard last (view input ["id"]) termBound previousIndexBound previousTermBound indexBound entryTermBound
    accepted readPreviousIndex readPreviousTerm readIndex readTerm readHard advancedTerm

-- The normal Drop continuations are explicit in resumeTruncation. This theorem
-- does not claim that user destructors or Clone must terminate successfully.
-- canStore is the scalar form of append's existing full-buffer rejection guard;
-- connecting that guard to the complete Node body remains a caller obligation.
theorem replacement_prepares_append
    (view : α → Path → InitStore) (records : SelectionStore)
    (hard base : InitStore) (boundary capacity baseIndex commit : Nat) (state : BufferState α)
    (selected : selectRecord Jarl.state_State_truncate_ir.last.base records = base)
    (baseRead : recordWord base ["index"] = some baseIndex)
    (valid : Storage.LogRep view hard base state capacity) (boundaryWord : boundary < 2^64)
    (commitBounds : baseIndex ≤ commit ∧ commit ≤ baseIndex + state.len)
    (authorized : commit < boundary)
    (canStore : ¬(state.len = capacity ∧ boundary > baseIndex + state.len)) :
    ∃ shortened, resumeTruncation (Jarl.state_State_truncate view records state boundary) = .returned shortened ∧
      Storage.LogRep view hard base shortened capacity ∧ shortened.len < capacity ∧
      shortened.len = min state.len (boundary - (baseIndex + 1)) ∧
      commit ≤ baseIndex + shortened.len ∧
      ∀ position, position < commit - baseIndex → shortened.slots[position]? = state.slots[position]? := by
  obtain ⟨shortened,execution,retained,length,_⟩ :=
    Storage.truncation_complete_result view records hard base boundary capacity baseIndex state
      selected baseRead valid boundaryWord
  have committedPrefix := Storage.truncation_preserves_committed_prefix view records hard base
    boundary capacity baseIndex commit state shortened selected baseRead valid boundaryWord
    commitBounds authorized execution
  have oldBound : state.len ≤ capacity := valid.1.2.1
  have space : shortened.len < capacity := by omega
  exact ⟨shortened,execution,retained,space,length,committedPrefix.2⟩

theorem replacement_storage_succeeds
    (bits capacity : Nat) (view : α → Path → InitStore) (records : SelectionStore)
    (hard base : InitStore) (boundary baseIndex commit : Nat) (state : BufferState α) (input : α)
    (selected : selectRecord Jarl.state_State_truncate_ir.last.base records = base)
    (baseRead : recordWord base ["index"] = some baseIndex)
    (valid : Storage.LogRep view hard base state capacity) (boundaryWord : boundary < 2^64)
    (word : capacity < 2^bits)
    (commitBounds : baseIndex ≤ commit ∧ commit ≤ baseIndex + state.len)
    (authorized : commit < boundary)
    (canStore : ¬(state.len = capacity ∧ boundary > baseIndex + state.len)) :
    ∃ shortened next,
      resumeTruncation (Jarl.state_State_truncate view records state boundary) = .returned shortened ∧
      Jarl.state_State_push bits capacity shortened input = .returned (.ok ()) next ∧
      Storage.Shape next capacity ∧
      next.len = min state.len (boundary - (baseIndex + 1)) + 1 ∧
      commit ≤ baseIndex + next.len ∧
      ∀ position, position < commit - baseIndex → next.slots[position]? = state.slots[position]? := by
  obtain ⟨shortened,truncated,retained,space,length,bounded,committedPrefix⟩ :=
    replacement_prepares_append view records hard base boundary capacity baseIndex commit state
      selected baseRead valid boundaryWord commitBounds authorized canStore
  obtain ⟨next,pushed,shape,nextLength⟩ := Storage.append_preserves_shape bits capacity shortened input
    retained.1 space word
  obtain ⟨framed,same,unchanged⟩ := Storage.append_preserves_prefix bits capacity shortened input
    retained.1 space word
  rw [pushed] at same
  have identical := (BufferRun.returned.inj same).2
  subst framed
  refine ⟨shortened,next,truncated,pushed,shape,by omega,by omega,?_⟩
  intro position inside
  exact (unchanged position (by omega)).trans (committedPrefix position inside)

-- Exact capacity characterization, including zero-capacity representations.
-- pastBase follows from append's prohibition on replacing committed entries.
theorem truncation_space_iff
    (view : α → Path → InitStore) (records : SelectionStore)
    (hard base : InitStore) (boundary capacity baseIndex : Nat) (state shortened : BufferState α)
    (selected : selectRecord Jarl.state_State_truncate_ir.last.base records = base)
    (baseRead : recordWord base ["index"] = some baseIndex)
    (valid : Storage.LogRep view hard base state capacity) (boundaryWord : boundary < 2^64)
    (pastBase : baseIndex < boundary)
    (execution : resumeTruncation (Jarl.state_State_truncate view records state boundary) = .returned shortened) :
    shortened.len < capacity ↔ ¬(state.len = capacity ∧ boundary > baseIndex + state.len) := by
  obtain ⟨expected,returned,_,length,_⟩ :=
    Storage.truncation_complete_result view records hard base boundary capacity baseIndex state
      selected baseRead valid boundaryWord
  have same : expected = shortened := TruncationRun.returned.inj (returned.symm.trans execution)
  subst expected
  have oldBound : state.len ≤ capacity := valid.1.2.1
  omega

-- A relation on the old log, including the compacted boundary. Connecting it
-- to the source id_at test is separate from proving that truncation retains it.
def PredecessorAt (view : α → Path → InitStore) (base : InitStore)
    (baseIndex boundary : Nat) (state : BufferState α) (last : InitStore) : Prop :=
  (boundary = baseIndex + 1 ∧ last = base) ∨
  ∃ position previous, boundary = baseIndex + position + 2 ∧ position < state.len ∧
    state.slots[position]? = some (some previous) ∧ last = view previous ["id"]

theorem predecessor_after_truncation
    (view : α → Path → InitStore) (records : SelectionStore)
    (hard base last : InitStore) (boundary capacity baseIndex : Nat) (state shortened : BufferState α)
    (selected : selectRecord Jarl.state_State_truncate_ir.last.base records = base)
    (baseRead : recordWord base ["index"] = some baseIndex)
    (valid : Storage.LogRep view hard base state capacity) (boundaryWord : boundary < 2^64)
    (predecessor : PredecessorAt view base baseIndex boundary state last)
    (execution : resumeTruncation (Jarl.state_State_truncate view records state boundary) = .returned shortened) :
    lastRecord Jarl.state_State_truncate_ir.last (truncationView view records shortened) = .ok last := by
  rcases predecessor with ⟨cut,same⟩ | ⟨position,previous,cut,inside,hit,same⟩
  · rw [same]
    exact Storage.truncation_retains_base view records hard base boundary capacity baseIndex state shortened
      selected baseRead valid boundaryWord cut execution
  · rw [same]
    exact Storage.truncation_retains_predecessor view records hard base boundary capacity baseIndex position
      state shortened previous selected baseRead valid boundaryWord cut inside hit execution

-- The successor premise is discharged by validation_supplies_successor once the
-- caller identifies the retained predecessor. No post-truncation space premise
-- is required. The predecessor is identified in the old log; its post-truncation lookup
-- is derived from the actual generated storage operation.
theorem replacement_append_preserves_log
    (bits capacity : Nat) (view : α → Path → InitStore) (records : SelectionStore)
    (hard base last : InitStore) (boundary baseIndex commit : Nat)
    (state shortened : BufferState α) (input : α)
    (selected : selectRecord Jarl.state_State_truncate_ir.last.base records = base)
    (baseRead : recordWord base ["index"] = some baseIndex)
    (valid : Storage.LogRep view hard base state capacity) (boundaryWord : boundary < 2^64)
    (word : capacity < 2^bits)
    (commitBounds : baseIndex ≤ commit ∧ commit ≤ baseIndex + state.len)
    (authorized : commit < boundary)
    (canStore : ¬(state.len = capacity ∧ boundary > baseIndex + state.len))
    (execution : resumeTruncation (Jarl.state_State_truncate view records state boundary) = .returned shortened)
    (predecessor : PredecessorAt view base baseIndex boundary state last)
    (follows : Storage.LogSuccessor hard last (view input ["id"])) :
    ∃ next, Jarl.state_State_push bits capacity shortened input = .returned (.ok ()) next ∧
      Storage.LogRep view hard base next capacity ∧
      next.len = min state.len (boundary - (baseIndex + 1)) + 1 ∧
      commit ≤ baseIndex + next.len ∧
      ∀ position, position < commit - baseIndex → next.slots[position]? = state.slots[position]? := by
  obtain ⟨expected,returned,retained,space,length,bounded,committedPrefix⟩ :=
    replacement_prepares_append view records hard base boundary capacity baseIndex commit state
      selected baseRead valid boundaryWord commitBounds authorized canStore
  have same : expected = shortened := TruncationRun.returned.inj (returned.symm.trans execution)
  subst expected
  have fetched := predecessor_after_truncation view records hard base last boundary capacity baseIndex
    state shortened selected baseRead valid boundaryWord predecessor execution
  obtain ⟨next,pushed,logValid,nextLength,unchanged⟩ :=
    Storage.append_preserves_log bits capacity view records hard base last shortened input
      selected retained space word fetched follows
  refine ⟨next,pushed,logValid,by omega,by omega,?_⟩
  intro position inside
  exact (unchanged position (by omega)).trans (committedPrefix position inside)

theorem lookup_identifies_predecessor
    (bits capacity baseIndex previousIndex : Nat) (view : α → Path → InitStore) (records : SelectionStore)
    (hard base last : InitStore) (state : BufferState α)
    (selected : selectRecord Jarl.state_State_truncate_ir.last.base records = base)
    (baseValue : base ["index"] = .unsigned "u64" baseIndex)
    (baseBound : baseIndex < 2^64) (previousBound : previousIndex < 2^64)
    (valid : Storage.LogRep view hard base state capacity)
    (found : Jarl.state_State_id_at bits (truncationView view records state).lookups previousIndex = .ok (some last)) :
    PredecessorAt view base baseIndex (previousIndex + 1) state last := by
  have hb : ¬18446744073709551616 ≤ baseIndex := Nat.not_le_of_gt baseBound
  have hi : ¬18446744073709551616 ≤ previousIndex := Nat.not_le_of_gt previousBound
  have chosen : selectRecord Jarl.state_State_id_at_ir.lookup.base records = base := selected
  simp only [Jarl.state_State_id_at_ir] at chosen
  by_cases sameIndex : previousIndex = baseIndex
  · have sameRecord : base = last := by
      simpa [Jarl.state_State_id_at,recordAt,Jarl.state_State_id_at_ir,truncationView,
        chosen,baseValue,hb,sameIndex] using found
    exact Or.inl ⟨by omega,sameRecord.symm⟩
  · by_cases earlier : previousIndex < baseIndex
    · simp [Jarl.state_State_id_at,recordAt,lookupRecord,Jarl.state_State_id_at_ir,truncationView,
        chosen,baseValue,hb,hi,sameIndex,earlier] at found
    · have bias : ¬ previousIndex - baseIndex < 1 := by omega
      let position := previousIndex - baseIndex - 1
      by_cases fits : position < 2^bits
      · cases slot : state.slots[position]? with
        | none =>
          simp [Jarl.state_State_id_at,recordAt,lookupRecord,Jarl.state_State_id_at_ir,truncationView,
            chosen,baseValue,hb,hi,sameIndex,earlier,bias,position,slot] at found
        | some item =>
          cases item with
          | none =>
            simp [Jarl.state_State_id_at,recordAt,lookupRecord,Jarl.state_State_id_at_ir,truncationView,
              chosen,baseValue,hb,hi,sameIndex,earlier,bias,position,slot] at found
          | some previous =>
            have noWide : ¬previousIndex - baseIndex - 1 ≥ 2^bits := by simpa [position] using Nat.not_le_of_gt fits
            have sameRecord : view previous ["id"] = last := by
              simpa [Jarl.state_State_id_at,recordAt,lookupRecord,Jarl.state_State_id_at_ir,truncationView,
                chosen,baseValue,hb,hi,sameIndex,earlier,bias,position,noWide,slot] using found
            have slotBound : position < state.slots.length := by
              by_cases inside : position < state.slots.length
              · exact inside
              · rw [List.getElem?_eq_none (by omega)] at slot
                contradiction
            have live : position < state.len := by
              by_cases live : position < state.len
              · exact live
              · have absent := valid.1.2.2.2 position (by omega) (by simpa [valid.1.1] using slotBound)
                simp [slot] at absent
            exact Or.inr ⟨position,previous,by dsimp [position];omega,live,slot,sameRecord.symm⟩
      · have wide : previousIndex - baseIndex - 1 ≥ 2^bits := by dsimp [position] at fits;omega
        simp [Jarl.state_State_id_at,recordAt,lookupRecord,Jarl.state_State_id_at_ir,truncationView,
          chosen,baseValue,hb,hi,sameIndex,earlier,bias,wide] at found

theorem lookup_retained_after_truncation
    (bits capacity baseIndex previousIndex : Nat) (view : α → Path → InitStore) (records : SelectionStore)
    (hard base last : InitStore) (state shortened : BufferState α)
    (selected : selectRecord Jarl.state_State_truncate_ir.last.base records = base)
    (baseValue : base ["index"] = .unsigned "u64" baseIndex)
    (baseBound : baseIndex < 2^64) (nextBound : previousIndex + 1 < 2^64)
    (valid : Storage.LogRep view hard base state capacity)
    (found : Jarl.state_State_id_at bits (truncationView view records state).lookups previousIndex = .ok (some last))
    (execution : resumeTruncation (Jarl.state_State_truncate view records state (previousIndex + 1)) = .returned shortened) :
    lastRecord Jarl.state_State_truncate_ir.last (truncationView view records shortened) = .ok last := by
  have predecessor := lookup_identifies_predecessor bits capacity baseIndex previousIndex view records
    hard base last state selected baseValue baseBound (by omega) valid found
  have baseRead : recordWord base ["index"] = some baseIndex := by simp [recordWord,baseValue,baseBound]
  exact predecessor_after_truncation view records hard base last (previousIndex + 1) capacity baseIndex
    state shortened selected baseRead valid nextBound predecessor execution

-- All conditions concern the old state and incoming record. Storage execution,
-- free space, and the retained predecessor are conclusions of generated code.
-- resumeTruncation explicitly follows normally returning Drop continuations.
theorem matched_replacement_preserves_log
    (bits capacity baseIndex previousIndex commit : Nat)
    (view : α → Path → InitStore) (records : SelectionStore)
    (hard base last : InitStore) (state : BufferState α) (input : α)
    (selected : selectRecord Jarl.state_State_truncate_ir.last.base records = base)
    (baseValue : base ["index"] = .unsigned "u64" baseIndex)
    (baseBound : baseIndex < 2^64) (nextBound : previousIndex + 1 < 2^64)
    (valid : Storage.LogRep view hard base state capacity) (word : capacity < 2^bits)
    (commitBounds : baseIndex ≤ commit ∧ commit ≤ baseIndex + state.len)
    (authorized : commit < previousIndex + 1)
    (canStore : ¬(state.len = capacity ∧ previousIndex + 1 > baseIndex + state.len))
    (found : Jarl.state_State_id_at bits (truncationView view records state).lookups previousIndex = .ok (some last))
    (follows : Storage.LogSuccessor hard last (view input ["id"])) :
    ∃ shortened next,
      resumeTruncation (Jarl.state_State_truncate view records state (previousIndex + 1)) = .returned shortened ∧
      Jarl.state_State_push bits capacity shortened input = .returned (.ok ()) next ∧
      Storage.LogRep view hard base next capacity ∧
      next.len = min state.len (previousIndex + 1 - (baseIndex + 1)) + 1 ∧
      commit ≤ baseIndex + next.len ∧
      ∀ position, position < commit - baseIndex → next.slots[position]? = state.slots[position]? := by
  have baseRead : recordWord base ["index"] = some baseIndex := by simp [recordWord,baseValue,baseBound]
  have predecessor := lookup_identifies_predecessor bits capacity baseIndex previousIndex view records
    hard base last state selected baseValue baseBound (by omega) valid found
  obtain ⟨shortened,execution,_⟩ := replacement_prepares_append view records hard base
    (previousIndex + 1) capacity baseIndex commit state selected baseRead valid nextBound
    commitBounds authorized canStore
  obtain ⟨next,pushed,logValid,length,bounded,unchanged⟩ :=
    replacement_append_preserves_log bits capacity view records hard base last (previousIndex + 1)
      baseIndex commit state shortened input selected baseRead valid nextBound word commitBounds
      authorized canStore execution predecessor follows
  exact ⟨shortened,next,execution,pushed,logValid,length,bounded,unchanged⟩

end Replication
