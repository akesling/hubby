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

end Replication
