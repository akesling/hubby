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


set_option maxRecDepth 10000
set_option maxHeartbeats 1000000
def campaignHead : PureExpr := match JarlValidation.node_Node_valid_ir with
  | .sequence first _ => first
  | _ => .literal .unit
def campaignTail : PureExpr := match JarlValidation.node_Node_valid_ir with
  | .sequence _ rest => rest
  | _ => .literal .unit
theorem body_shape : JarlValidation.node_Node_valid_ir = .sequence campaignHead campaignTail := by rfl

theorem campaign_range (campaign term : Nat) (bounded : campaign < 2^64) :
    JarlValidation.node_Node_valid 256 (preVoted campaign term) = .ok (decide (campaign > 0)) := by
  have range : ¬18446744073709551616 ≤ campaign := Nat.not_le_of_gt bounded
  have first : pureEval 255 campaignHead (pureSet (fun _ => none) 0 (preVoted campaign term)) =
      .error (.returned (.boolean (decide (campaign > 0)))) := by
    simp [campaignHead,JarlValidation.node_Node_valid_ir,pureEval,pureMatch,pureSet,
      preVoted,word,pureBinary,pureBound,range,
      List.findSome?,List.find?,List.foldlM,bind,Option.bind,Except.bind,pure,Except.pure]
  unfold JarlValidation.node_Node_valid pureValidate
  rw [body_shape,pure_sequence_error 255 campaignHead campaignTail _ _ first]

set_option maxRecDepth 10000
set_option maxHeartbeats 2000000

theorem vote_range (term index lastTerm : Nat)
    (termBound : term < 2^64) (indexBound : index < 2^64) (lastBound : lastTerm < 2^64) :
    JarlValidation.node_Node_valid 256
      (message "Vote" term [("last",logId index lastTerm)]) =
      .ok (decide (term > 0 ∧ ((index = 0 ∧ lastTerm = 0) ∨
        (index > 0 ∧ lastTerm > 0 ∧ lastTerm ≤ term)))) := by
  have tbound : ¬18446744073709551616 ≤ term := Nat.not_le_of_gt termBound
  have ibound : ¬18446744073709551616 ≤ index := Nat.not_le_of_gt indexBound
  have lbound : ¬18446744073709551616 ≤ lastTerm := Nat.not_le_of_gt lastBound
  by_cases tzero : term = 0
  · subst term
    simp [zero_term_vote]
  · by_cases izero : index = 0 <;> by_cases lzero : lastTerm = 0 <;>
      by_cases ordered : lastTerm ≤ term <;>
      simp (config := {maxSteps := 100000}) [JarlValidation.node_Node_valid,
        JarlValidation.node_Node_valid_ir,pureValidate,pureEval,pureMatch,pureSet,
        pureFields,pureField,pureBinary,pureBound,message,word,logId,
        tbound,ibound,lbound,tzero,izero,lzero,ordered,Nat.pos_iff_ne_zero,
        List.findSome?,List.find?,List.foldlM,bind,Option.bind,Except.bind,pure,Except.pure]

set_option maxRecDepth 10000
set_option maxHeartbeats 2000000

theorem prevote_range (term index lastTerm : Nat)
    (termBound : term < 2^64) (indexBound : index < 2^64) (lastBound : lastTerm < 2^64) :
    JarlValidation.node_Node_valid 256
      (message "PreVote" term [("last",logId index lastTerm)]) =
      .ok (decide (term > 0 ∧ ((index = 0 ∧ lastTerm = 0) ∨
        (index > 0 ∧ lastTerm > 0 ∧ lastTerm ≤ term)))) := by
  have tbound : ¬18446744073709551616 ≤ term := Nat.not_le_of_gt termBound
  have ibound : ¬18446744073709551616 ≤ index := Nat.not_le_of_gt indexBound
  have lbound : ¬18446744073709551616 ≤ lastTerm := Nat.not_le_of_gt lastBound
  by_cases tzero : term = 0
  · subst term
    simp [zero_term_prevote]
  · by_cases izero : index = 0 <;> by_cases lzero : lastTerm = 0 <;>
      by_cases ordered : lastTerm ≤ term <;>
      simp (config := {maxSteps := 100000}) [JarlValidation.node_Node_valid,
        JarlValidation.node_Node_valid_ir,pureValidate,pureEval,pureMatch,pureSet,
        pureFields,pureField,pureBinary,pureBound,message,word,logId,
        tbound,ibound,lbound,tzero,izero,lzero,ordered,Nat.pos_iff_ne_zero,
        List.findSome?,List.find?,List.foldlM,bind,Option.bind,Except.bind,pure,Except.pure]

set_option maxRecDepth 10000
set_option maxHeartbeats 2000000

theorem heartbeat_range (term index lastTerm : Nat)
    (termBound : term < 2^64) (indexBound : index < 2^64) (lastBound : lastTerm < 2^64) :
    JarlValidation.node_Node_valid 256
      (message "Append" term [("previous",logId index lastTerm),("entry",.absent)]) =
      .ok (decide (term > 0 ∧ ((index = 0 ∧ lastTerm = 0) ∨
        (index > 0 ∧ lastTerm > 0 ∧ lastTerm ≤ term)))) := by
  have tbound : ¬18446744073709551616 ≤ term := Nat.not_le_of_gt termBound
  have ibound : ¬18446744073709551616 ≤ index := Nat.not_le_of_gt indexBound
  have lbound : ¬18446744073709551616 ≤ lastTerm := Nat.not_le_of_gt lastBound
  by_cases tzero : term = 0
  · subst term
    simp [zero_term_append]
  · by_cases izero : index = 0 <;> by_cases lzero : lastTerm = 0 <;>
      by_cases ordered : lastTerm ≤ term <;>
      simp (config := {maxSteps := 100000}) [JarlValidation.node_Node_valid,
        JarlValidation.node_Node_valid_ir,pureValidate,pureEval,pureMatch,pureSet,
        pureFields,pureField,pureBinary,pureBound,message,word,logId,
        tbound,ibound,lbound,tzero,izero,lzero,ordered,Nat.pos_iff_ne_zero,
        List.findSome?,List.find?,List.foldlM,bind,Option.bind,Except.bind,pure,Except.pure]

set_option maxRecDepth 10000
set_option maxHeartbeats 2000000

theorem snapshot_range (term index lastTerm : Nat) (payload : PureValue)
    (termBound : term < 2^64) (indexBound : index < 2^64) (lastBound : lastTerm < 2^64) :
    JarlValidation.node_Node_valid 256
      (message "Install" term [("snapshot",.record "Snapshot" [("last",logId index lastTerm),("value",payload)])]) =
      .ok (decide (term > 0 ∧ index > 0 ∧ lastTerm > 0 ∧ lastTerm ≤ term)) := by
  have tbound : ¬18446744073709551616 ≤ term := Nat.not_le_of_gt termBound
  have ibound : ¬18446744073709551616 ≤ index := Nat.not_le_of_gt indexBound
  have lbound : ¬18446744073709551616 ≤ lastTerm := Nat.not_le_of_gt lastBound
  by_cases tzero : term = 0
  · subst term
    simp [zero_term_install]
  · by_cases izero : index = 0 <;> by_cases lzero : lastTerm = 0 <;>
      by_cases ordered : lastTerm ≤ term <;>
      simp (config := {maxSteps := 100000}) [JarlValidation.node_Node_valid,
        JarlValidation.node_Node_valid_ir,pureValidate,pureEval,pureMatch,pureSet,
        pureFields,pureField,pureBinary,pureBound,message,word,logId,
        tbound,ibound,lbound,tzero,izero,lzero,ordered,Nat.pos_iff_ne_zero,
        List.findSome?,List.find?,List.foldlM,bind,Option.bind,Except.bind,pure,Except.pure]

set_option maxRecDepth 10000
set_option maxHeartbeats 2000000

theorem voted_range (term : Nat) (fields : List (String × PureValue)) (bounded : term < 2^64) :
    JarlValidation.node_Node_valid 256 (message "Voted" term fields) = .ok (decide (term > 0)) := by
  have range : ¬18446744073709551616 ≤ term := Nat.not_le_of_gt bounded
  by_cases empty : term = 0 <;>
    simp [JarlValidation.node_Node_valid,JarlValidation.node_Node_valid_ir,
      pureValidate,pureEval,pureMatch,pureSet,pureBinary,pureBound,message,word,
      range,empty,Nat.pos_iff_ne_zero,List.findSome?,List.find?,List.foldlM,
      bind,Option.bind,Except.bind,pure,Except.pure]

theorem replicated_range (term : Nat) (rejection : PureValue) (bounded : term < 2^64)
    (kind : rejection = .absent ∨ rejection = .present (.variant "Rejection" "Full" [])) :
    JarlValidation.node_Node_valid 256
      (message "Replicated" term [("rejection",rejection)]) = .ok (decide (term > 0)) := by
  have range : ¬18446744073709551616 ≤ term := Nat.not_le_of_gt bounded
  rcases kind with rfl | rfl <;> by_cases empty : term = 0 <;>
    simp [JarlValidation.node_Node_valid,JarlValidation.node_Node_valid_ir,
      pureValidate,pureEval,pureMatch,pureSet,pureBinary,pureBound,message,word,
      range,empty,Nat.pos_iff_ne_zero,List.findSome?,List.find?,List.foldlM,
      bind,Option.bind,Except.bind,pure,Except.pure]

theorem conflict_range (term nextIndex : Nat)
    (termBound : term < 2^64) (nextBound : nextIndex < 2^64) :
    JarlValidation.node_Node_valid 256 (message "Replicated" term
      [("rejection",.present (.variant "Rejection" "Conflict" [("next",word nextIndex)]))]) =
      .ok (decide (term > 0 ∧ nextIndex > 0)) := by
  have tbound : ¬18446744073709551616 ≤ term := Nat.not_le_of_gt termBound
  have nbound : ¬18446744073709551616 ≤ nextIndex := Nat.not_le_of_gt nextBound
  by_cases empty : term = 0 <;> by_cases zeroIndex : nextIndex = 0 <;>
    simp [JarlValidation.node_Node_valid,JarlValidation.node_Node_valid_ir,
      pureValidate,pureEval,pureMatch,pureSet,pureBinary,pureBound,message,word,
      tbound,nbound,empty,zeroIndex,Nat.pos_iff_ne_zero,List.findSome?,List.find?,List.foldlM,
      bind,Option.bind,Except.bind,pure,Except.pure]



set_option maxRecDepth 10000
set_option maxHeartbeats 10000000

theorem append_range (term previousIndex previousTerm index entryTerm : Nat) (payload : PureValue)
    (termBound : term < 2^64) (previousIndexBound : previousIndex < 2^64)
    (previousTermBound : previousTerm < 2^64) (indexBound : index < 2^64)
    (entryTermBound : entryTerm < 2^64) :
    JarlValidation.node_Node_valid 256 (message "Append" term
      [("previous",logId previousIndex previousTerm),("entry",.present (entry index entryTerm payload))]) =
      .ok (decide (term > 0 ∧
        ((previousIndex = 0 ∧ previousTerm = 0) ∨
          (previousIndex > 0 ∧ previousTerm > 0 ∧ previousTerm ≤ term)) ∧
        ((index = 0 ∧ entryTerm = 0) ∨ (index > 0 ∧ entryTerm > 0 ∧ entryTerm ≤ term)) ∧
        previousIndex+1 < 2^64 ∧ previousIndex+1 = index ∧ previousTerm ≤ entryTerm)) := by
  have tbound : ¬18446744073709551616 ≤ term := Nat.not_le_of_gt termBound
  have pibound : ¬18446744073709551616 ≤ previousIndex := Nat.not_le_of_gt previousIndexBound
  have ptbound : ¬18446744073709551616 ≤ previousTerm := Nat.not_le_of_gt previousTermBound
  have ibound : ¬18446744073709551616 ≤ index := Nat.not_le_of_gt indexBound
  have etbound : ¬18446744073709551616 ≤ entryTerm := Nat.not_le_of_gt entryTermBound
  have typedIndex : index < 18446744073709551616 := indexBound
  have typedPrevious : previousIndex < 18446744073709551616 := previousIndexBound
  by_cases tzero : term = 0
  · subst term
    simp [zero_term_append]
  · by_cases pizero : previousIndex = 0 <;> by_cases ptzero : previousTerm = 0 <;>
      by_cases izero : index = 0 <;> by_cases etzero : entryTerm = 0 <;>
      by_cases pordered : previousTerm ≤ term <;> by_cases eordered : entryTerm ≤ term <;>
      by_cases successive : previousIndex+1 = index <;>
      by_cases ordered : previousTerm ≤ entryTerm <;>
      by_cases noOverflow : previousIndex+1 < 18446744073709551616 <;>
      try omega
    all_goals
      simp_all only [Nat.zero_add]
    all_goals
      simp (config := {maxSteps := 20000}) [JarlValidation.node_Node_valid,
        JarlValidation.node_Node_valid_ir,pureValidate,pureEval,pureMatch,pureSet,
        pureFields,pureField,pureBinary,pureEqual,pureBound,message,word,logId,entry,
        *,Nat.pos_iff_ne_zero,
        List.findSome?,List.find?,List.foldlM,bind,Option.bind,Except.bind,pure,Except.pure]
theorem append_accepted (term previousIndex previousTerm index entryTerm : Nat) (payload : PureValue)
    (termBound : term < 2^64) (previousIndexBound : previousIndex < 2^64)
    (previousTermBound : previousTerm < 2^64) (indexBound : index < 2^64)
    (entryTermBound : entryTerm < 2^64)
    (accepted : JarlValidation.node_Node_valid 256 (message "Append" term
      [("previous",logId previousIndex previousTerm),("entry",.present (entry index entryTerm payload))]) = .ok true) :
    term > 0 ∧ index = previousIndex+1 ∧ entryTerm > 0 ∧
      previousTerm ≤ entryTerm ∧ entryTerm ≤ term := by
  rw [append_range term previousIndex previousTerm index entryTerm payload
    termBound previousIndexBound previousTermBound indexBound entryTermBound] at accepted
  have valid := of_decide_eq_true (Except.ok.inj accepted)
  rcases valid with ⟨positive,_,entryValid,_,successor,ordered⟩
  rcases entryValid with ⟨empty,_⟩ | ⟨_,entryPositive,entryBound⟩
  · omega
  · exact ⟨positive,successor.symm,entryPositive,ordered,entryBound⟩



set_option maxRecDepth 10000
set_option maxHeartbeats 2000000

def validationArms : List (PurePattern × PureExpr) :=
  match JarlValidation.node_Node_valid_ir with
  | .sequence _ (.sequence _ (.binary _ _ (.choose _ arms))) => arms
  | _ => []
def batchArm : PureExpr := ((validationArms[3]?).map Prod.snd).getD (.literal .unit)
def batchLoop : PureExpr := match batchArm with
  | .sequence _ (.sequence _ (.sequence _ (.sequence _ (.sequence loop _)))) => loop
  | _ => .literal .unit
def batchLoopBody : PureExpr := match batchLoop with
  | .each _ _ body => body
  | _ => .literal .unit
theorem batch_loop_shape : batchLoop = .each (.read 30) 37 batchLoopBody := by rfl

def afterNone (env : PureEnv) : PureEnv := pureSet (pureSet env 37 .absent) 32 (.boolean true)
theorem none_iteration (extra : Nat) (env : PureEnv) :
    pureEval (extra+8) batchLoopBody (pureSet env 37 .absent) = .ok (.unit,afterNone env) := by
  simp [batchLoopBody,batchLoop,batchArm,validationArms,JarlValidation.node_Node_valid_ir,
    pureEval,pureMatch,pureSet,afterNone,List.findSome?,
    bind,Except.bind,pure,Except.pure]

theorem after_none_idempotent (env : PureEnv) : afterNone (afterNone env) = afterNone env := by
  funext key
  by_cases ended : key = 32 <;> by_cases current : key = 37 <;>
    simp [afterNone,pureSet,ended,current]

theorem none_scan (extra count : Nat) (env : PureEnv) (initialResult : PureValue) :
    (List.replicate count PureValue.absent).foldlM (fun (_,env) value =>
      pureEval (extra+8) batchLoopBody (pureSet env 37 value)) (initialResult,env) =
      .ok (if count = 0 then (initialResult,env) else (.unit,afterNone env)) := by
  induction count generalizing env initialResult with
  | zero => rfl
  | succ count ih =>
    simp only [List.replicate_succ,List.foldlM,none_iteration,bind,Except.bind]
    rw [ih]
    cases count <;> simp [after_none_idempotent]
theorem each_none_scan (count : Nat) (env : PureEnv)
    (read : env 30 = some (.array (List.replicate count .absent))) :
    pureEval 247 batchLoop env =
      .ok (if count = 0 then (.unit,env) else (.unit,afterNone env)) := by
  have source : pureEval 246 (.read 30) env = .ok (.array (List.replicate count .absent),env) := by
    simp [pureEval,read]
  rw [batch_loop_shape,pureEval,source]
  exact none_scan 238 count env .unit

theorem empty_batch_any_length (term index lastTerm count : Nat)
    (termBound : term < 2^64) (indexBound : index < 2^64) (lastBound : lastTerm < 2^64) :
    JarlValidation.node_Node_valid 256
      (message "AppendBatch" term [("previous",logId index lastTerm),
        ("entries",.array (List.replicate count .absent))]) = .ok false := by
  have tbound : ¬18446744073709551616 ≤ term := Nat.not_le_of_gt termBound
  have ibound : ¬18446744073709551616 ≤ index := Nat.not_le_of_gt indexBound
  have lbound : ¬18446744073709551616 ≤ lastTerm := Nat.not_le_of_gt lastBound
  by_cases tzero : term = 0
  · subst term
    exact zero_term_appendbatch _
  · by_cases izero : index = 0 <;> by_cases lzero : lastTerm = 0 <;>
      by_cases ordered : lastTerm ≤ term <;> by_cases empty : count = 0 <;>
      simp (config := {maxSteps := 20000}) (disch := first | decide | exact Eq.refl _) [JarlValidation.node_Node_valid,
        JarlValidation.node_Node_valid_ir,pureValidate,pure_eval_step,pureMatch,pureSet,
        pureFields,pureField,pureBinary,pureBound,message,word,logId,
        tbound,ibound,lbound,tzero,izero,lzero,ordered,empty,Nat.pos_iff_ne_zero,
        List.findSome?,List.find?,List.foldlM,bind,Option.bind,Except.bind,pure,Except.pure,
        ]
    all_goals
      have rule := each_none_scan count
      simp [batchLoop,batchArm,validationArms,JarlValidation.node_Node_valid_ir] at rule
      rw [rule _]
      · simp [pureSet,afterNone,empty]
      · simp [pureSet,empty]


theorem entry_after_end (extra : Nat) (env : PureEnv) (value : PureValue)
    (ended : env 32 = some (.boolean true)) :
    pureEval (extra+32) batchLoopBody (pureSet env 37 (.present value)) =
      .error (.returned (.boolean false)) := by
  simp [batchLoopBody,batchLoop,batchArm,validationArms,JarlValidation.node_Node_valid_ir,
    pureEval,pureMatch,pureSet,ended,List.findSome?,bind,Except.bind,pure,Except.pure]

theorem hole_scan (env : PureEnv) (value initialResult : PureValue) (rest : List PureValue) :
    (.absent :: .present value :: rest).foldlM (fun (_,env) value =>
      pureEval 246 batchLoopBody (pureSet env 37 value)) (initialResult,env) =
      .error (.returned (.boolean false)) := by
  have first : pureEval 246 batchLoopBody (pureSet env 37 .absent) = .ok (.unit,afterNone env) :=
    none_iteration 238 env
  have second : pureEval 246 batchLoopBody (pureSet (afterNone env) 37 (.present value)) =
      .error (.returned (.boolean false)) :=
    entry_after_end 214 (afterNone env) value (by simp [afterNone,pureSet])
  simp only [List.foldlM,first,second,bind,Except.bind]

theorem each_hole (value : PureValue) (rest : List PureValue) (env : PureEnv)
    (read : env 30 = some (.array (.absent :: .present value :: rest))) :
    pureEval 247 batchLoop env = .error (.returned (.boolean false)) := by
  have source : pureEval 246 (.read 30) env = .ok (.array (.absent :: .present value :: rest),env) := by
    simp [pureEval,read]
  rw [batch_loop_shape,pureEval,source]
  exact hole_scan env value .unit rest

theorem leading_hole_rejected (term index lastTerm : Nat) (value : PureValue) (rest : List PureValue)
    (termBound : term < 2^64) (indexBound : index < 2^64) (lastBound : lastTerm < 2^64) :
    JarlValidation.node_Node_valid 256
      (message "AppendBatch" term [("previous",logId index lastTerm),
        ("entries",.array (.absent :: .present value :: rest))]) = .ok false := by
  have tbound : ¬18446744073709551616 ≤ term := Nat.not_le_of_gt termBound
  have ibound : ¬18446744073709551616 ≤ index := Nat.not_le_of_gt indexBound
  have lbound : ¬18446744073709551616 ≤ lastTerm := Nat.not_le_of_gt lastBound
  by_cases tzero : term = 0
  · subst term
    exact zero_term_appendbatch _
  · by_cases izero : index = 0 <;> by_cases lzero : lastTerm = 0 <;>
      by_cases ordered : lastTerm ≤ term <;>
      simp (config := {maxSteps := 20000}) (disch := first | decide | exact Eq.refl _) [JarlValidation.node_Node_valid,
        JarlValidation.node_Node_valid_ir,pureValidate,pure_eval_step,pureMatch,pureSet,
        pureFields,pureField,pureBinary,pureBound,message,word,logId,
        tbound,ibound,lbound,tzero,izero,lzero,ordered,Nat.pos_iff_ne_zero,
        List.findSome?,List.find?,List.foldlM,bind,Option.bind,Except.bind,pure,Except.pure]
    all_goals
      have rule := each_hole value rest
      simp [batchLoop,batchArm,validationArms,JarlValidation.node_Node_valid_ir] at rule
      rw [rule _]
      rfl

end Validation
