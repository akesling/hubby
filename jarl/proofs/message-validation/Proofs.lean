import Generated
open Provium.State
namespace Validation
set_option maxRecDepth 10000
set_option maxHeartbeats 4000000
set_option maxRecDepth 20000
def word (value : Nat) : PureValue := .number "u64" value
def preVoted (campaign term : Nat) : PureValue :=
  .variant "Message" "PreVoted" [("campaign",word campaign),("term",word term)]
theorem zero_campaign : JarlValidation.node_Node_valid 256 (preVoted 0 1) = .ok false := by rfl
theorem positive_campaign_ignores_term (term : Nat) :
    JarlValidation.node_Node_valid 256 (preVoted 1 term) = .ok true := by rfl
theorem zero_campaign_ignores_term (term : Nat) :
    JarlValidation.node_Node_valid 256 (preVoted 0 term) = .ok false := by rfl


def message (tag : String) (term : Nat) (fields : List (String × PureValue)) : PureValue :=
  .variant "Message" tag (("term",word term)::fields)
def logId (index term : Nat) : PureValue :=
  .record "LogId" [("index",word index),("term",word term)]
def entry (index term : Nat) (payload : PureValue := .unit) : PureValue :=
  .record "Entry" [("id",logId index term),("value",payload)]
def batch (term previousIndex previousTerm : Nat) (entries : List PureValue) : PureValue :=
  message "AppendBatch" term [("previous",logId previousIndex previousTerm),
    ("entries",.array (entries ++ List.replicate (16-entries.length) .absent))]
theorem zero_term_prevote (fields : List (String × PureValue)) :
    JarlValidation.node_Node_valid 256 (message "PreVote" 0 fields) = .ok false := by rfl
theorem zero_term_vote (fields : List (String × PureValue)) :
    JarlValidation.node_Node_valid 256 (message "Vote" 0 fields) = .ok false := by rfl
theorem zero_term_voted (fields : List (String × PureValue)) :
    JarlValidation.node_Node_valid 256 (message "Voted" 0 fields) = .ok false := by rfl
theorem zero_term_append (fields : List (String × PureValue)) :
    JarlValidation.node_Node_valid 256 (message "Append" 0 fields) = .ok false := by rfl
theorem zero_term_appendbatch (fields : List (String × PureValue)) :
    JarlValidation.node_Node_valid 256 (message "AppendBatch" 0 fields) = .ok false := by rfl
theorem zero_term_install (fields : List (String × PureValue)) :
    JarlValidation.node_Node_valid 256 (message "Install" 0 fields) = .ok false := by rfl
theorem zero_term_replicated (fields : List (String × PureValue)) :
    JarlValidation.node_Node_valid 256 (message "Replicated" 0 fields) = .ok false := by rfl
theorem voted : JarlValidation.node_Node_valid 256 (message "Voted" 1 []) = .ok true := by rfl
theorem vote_empty : JarlValidation.node_Node_valid 256 (message "Vote" 1 [("last",logId 0 0)]) = .ok true := by rfl
theorem prevote_empty : JarlValidation.node_Node_valid 256 (message "PreVote" 1 [("last",logId 0 0)]) = .ok true := by rfl
theorem vote_zero_log_term : JarlValidation.node_Node_valid 256 (message "Vote" 1 [("last",logId 1 0)]) = .ok false := by rfl
theorem vote_future_log_term : JarlValidation.node_Node_valid 256 (message "Vote" 1 [("last",logId 1 2)]) = .ok false := by rfl
theorem vote_nonzero_term_zero_index : JarlValidation.node_Node_valid 256 (message "Vote" 1 [("last",logId 0 1)]) = .ok false := by rfl
theorem heartbeat : JarlValidation.node_Node_valid 256 (message "Append" 1 [("previous",logId 0 0),("entry",.absent)]) = .ok true := by rfl
theorem append_successor : JarlValidation.node_Node_valid 256 (message "Append" 2 [("previous",logId 1 1),("entry",.present (entry 2 2))]) = .ok true := by rfl
theorem append_gap : JarlValidation.node_Node_valid 256 (message "Append" 2 [("previous",logId 1 1),("entry",.present (entry 3 2))]) = .ok false := by rfl
theorem append_decreasing_term : JarlValidation.node_Node_valid 256 (message "Append" 2 [("previous",logId 1 2),("entry",.present (entry 2 1))]) = .ok false := by rfl
theorem append_overflow : JarlValidation.node_Node_valid 256 (message "Append" 2 [("previous",logId (2^64-1) 2),("entry",.present (entry 0 2))]) = .ok false := by rfl
theorem empty_batch : JarlValidation.node_Node_valid 256 (batch 1 0 0 []) = .ok false := by rfl
theorem one_entry_batch : JarlValidation.node_Node_valid 256 (batch 1 0 0 [.present (entry 1 1)]) = .ok true := by rfl
theorem batch_hole : JarlValidation.node_Node_valid 256 (batch 2 0 0 [.present (entry 1 1),.absent,.present (entry 2 2)]) = .ok false := by rfl
theorem batch_gap : JarlValidation.node_Node_valid 256 (batch 2 0 0 [.present (entry 1 1),.present (entry 3 2)]) = .ok false := by rfl
theorem batch_decreasing_term : JarlValidation.node_Node_valid 256 (batch 2 0 0 [.present (entry 1 2),.present (entry 2 1)]) = .ok false := by rfl
theorem batch_future_term : JarlValidation.node_Node_valid 256 (batch 2 0 0 [.present (entry 1 3)]) = .ok false := by rfl
theorem batch_invalid_previous : JarlValidation.node_Node_valid 256 (batch 2 0 1 [.present (entry 1 1)]) = .ok false := by rfl
theorem batch_overflow : JarlValidation.node_Node_valid 256 (batch 2 (2^64-1) 2 [.present (entry 0 2)]) = .ok false := by rfl
theorem full_batch : JarlValidation.node_Node_valid 256 (batch 1 0 0 ((List.range 16).map (fun i => .present (entry (i+1) 1)))) = .ok true := by rfl
theorem snapshot_valid : JarlValidation.node_Node_valid 256 (message "Install" 1 [("snapshot",.record "Snapshot" [("last",logId 1 1)])]) = .ok true := by rfl
theorem snapshot_empty : JarlValidation.node_Node_valid 256 (message "Install" 1 [("snapshot",.record "Snapshot" [("last",logId 0 0)])]) = .ok false := by rfl
theorem snapshot_zero_term : JarlValidation.node_Node_valid 256 (message "Install" 1 [("snapshot",.record "Snapshot" [("last",logId 1 0)])]) = .ok false := by rfl
theorem snapshot_future_term : JarlValidation.node_Node_valid 256 (message "Install" 1 [("snapshot",.record "Snapshot" [("last",logId 1 2)])]) = .ok false := by rfl
theorem replicated_success : JarlValidation.node_Node_valid 256 (message "Replicated" 1 [("rejection",.absent)]) = .ok true := by rfl
theorem replicated_full : JarlValidation.node_Node_valid 256 (message "Replicated" 1 [("rejection",.present (.variant "Rejection" "Full" []))]) = .ok true := by rfl
theorem conflict_zero : JarlValidation.node_Node_valid 256 (message "Replicated" 1 [("rejection",.present (.variant "Rejection" "Conflict" [("next",word 0)]))]) = .ok false := by rfl
theorem conflict_positive : JarlValidation.node_Node_valid 256 (message "Replicated" 1 [("rejection",.present (.variant "Rejection" "Conflict" [("next",word 1)]))]) = .ok true := by rfl
theorem append_payload_unread (payload : PureValue) :
    JarlValidation.node_Node_valid 256 (message "Append" 1
      [("previous",logId 0 0),("entry",.present (entry 1 1 payload))]) = .ok true := by rfl
end Validation
