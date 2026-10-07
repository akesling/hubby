import Generated
open Provium.State
namespace Validation
set_option maxRecDepth 10000
set_option maxHeartbeats 4000000
set_option maxRecDepth 20000
def word (value : Nat) : PureValue := .number "u64" value
def preVoted (campaign term : Nat) : PureValue :=
  .variant "Message" "PreVoted" [("campaign",word campaign),("term",word term)]
theorem zero_campaign : Jarl.node_Node_valid 256 (preVoted 0 1) = .ok false := by rfl
theorem positive_campaign_ignores_term (term : Nat) :
    Jarl.node_Node_valid 256 (preVoted 1 term) = .ok true := by rfl
theorem zero_campaign_ignores_term (term : Nat) :
    Jarl.node_Node_valid 256 (preVoted 0 term) = .ok false := by rfl


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
    Jarl.node_Node_valid 256 (message "PreVote" 0 fields) = .ok false := by rfl
theorem zero_term_vote (fields : List (String × PureValue)) :
    Jarl.node_Node_valid 256 (message "Vote" 0 fields) = .ok false := by rfl
theorem zero_term_voted (fields : List (String × PureValue)) :
    Jarl.node_Node_valid 256 (message "Voted" 0 fields) = .ok false := by rfl
theorem zero_term_append (fields : List (String × PureValue)) :
    Jarl.node_Node_valid 256 (message "Append" 0 fields) = .ok false := by rfl
theorem zero_term_appendbatch (fields : List (String × PureValue)) :
    Jarl.node_Node_valid 256 (message "AppendBatch" 0 fields) = .ok false := by rfl
theorem zero_term_install (fields : List (String × PureValue)) :
    Jarl.node_Node_valid 256 (message "Install" 0 fields) = .ok false := by rfl
theorem zero_term_replicated (fields : List (String × PureValue)) :
    Jarl.node_Node_valid 256 (message "Replicated" 0 fields) = .ok false := by rfl
theorem voted : Jarl.node_Node_valid 256 (message "Voted" 1 []) = .ok true := by rfl
theorem vote_empty : Jarl.node_Node_valid 256 (message "Vote" 1 [("last",logId 0 0)]) = .ok true := by rfl
theorem prevote_empty : Jarl.node_Node_valid 256 (message "PreVote" 1 [("last",logId 0 0)]) = .ok true := by rfl
theorem vote_zero_log_term : Jarl.node_Node_valid 256 (message "Vote" 1 [("last",logId 1 0)]) = .ok false := by rfl
theorem vote_future_log_term : Jarl.node_Node_valid 256 (message "Vote" 1 [("last",logId 1 2)]) = .ok false := by rfl
theorem vote_nonzero_term_zero_index : Jarl.node_Node_valid 256 (message "Vote" 1 [("last",logId 0 1)]) = .ok false := by rfl
theorem heartbeat : Jarl.node_Node_valid 256 (message "Append" 1 [("previous",logId 0 0),("entry",.absent)]) = .ok true := by rfl
theorem append_successor : Jarl.node_Node_valid 256 (message "Append" 2 [("previous",logId 1 1),("entry",.present (entry 2 2))]) = .ok true := by rfl
theorem append_gap : Jarl.node_Node_valid 256 (message "Append" 2 [("previous",logId 1 1),("entry",.present (entry 3 2))]) = .ok false := by rfl
theorem append_decreasing_term : Jarl.node_Node_valid 256 (message "Append" 2 [("previous",logId 1 2),("entry",.present (entry 2 1))]) = .ok false := by rfl
theorem append_overflow : Jarl.node_Node_valid 256 (message "Append" 2 [("previous",logId (2^64-1) 2),("entry",.present (entry 0 2))]) = .ok false := by rfl
theorem empty_batch : Jarl.node_Node_valid 256 (batch 1 0 0 []) = .ok false := by rfl
theorem one_entry_batch : Jarl.node_Node_valid 256 (batch 1 0 0 [.present (entry 1 1)]) = .ok true := by rfl
theorem batch_hole : Jarl.node_Node_valid 256 (batch 2 0 0 [.present (entry 1 1),.absent,.present (entry 2 2)]) = .ok false := by rfl
theorem batch_gap : Jarl.node_Node_valid 256 (batch 2 0 0 [.present (entry 1 1),.present (entry 3 2)]) = .ok false := by rfl
theorem batch_decreasing_term : Jarl.node_Node_valid 256 (batch 2 0 0 [.present (entry 1 2),.present (entry 2 1)]) = .ok false := by rfl
theorem batch_future_term : Jarl.node_Node_valid 256 (batch 2 0 0 [.present (entry 1 3)]) = .ok false := by rfl
theorem batch_invalid_previous : Jarl.node_Node_valid 256 (batch 2 0 1 [.present (entry 1 1)]) = .ok false := by rfl
theorem batch_overflow : Jarl.node_Node_valid 256 (batch 2 (2^64-1) 2 [.present (entry 0 2)]) = .ok false := by rfl
theorem full_batch : Jarl.node_Node_valid 256 (batch 1 0 0 ((List.range 16).map (fun i => .present (entry (i+1) 1)))) = .ok true := by rfl
theorem snapshot_valid : Jarl.node_Node_valid 256 (message "Install" 1 [("snapshot",.record "Snapshot" [("last",logId 1 1)])]) = .ok true := by rfl
theorem snapshot_empty : Jarl.node_Node_valid 256 (message "Install" 1 [("snapshot",.record "Snapshot" [("last",logId 0 0)])]) = .ok false := by rfl
theorem snapshot_zero_term : Jarl.node_Node_valid 256 (message "Install" 1 [("snapshot",.record "Snapshot" [("last",logId 1 0)])]) = .ok false := by rfl
theorem snapshot_future_term : Jarl.node_Node_valid 256 (message "Install" 1 [("snapshot",.record "Snapshot" [("last",logId 1 2)])]) = .ok false := by rfl
theorem replicated_success : Jarl.node_Node_valid 256 (message "Replicated" 1 [("rejection",.absent)]) = .ok true := by rfl
theorem replicated_full : Jarl.node_Node_valid 256 (message "Replicated" 1 [("rejection",.present (.variant "Rejection" "Full" []))]) = .ok true := by rfl
theorem conflict_zero : Jarl.node_Node_valid 256 (message "Replicated" 1 [("rejection",.present (.variant "Rejection" "Conflict" [("next",word 0)]))]) = .ok false := by rfl
theorem conflict_positive : Jarl.node_Node_valid 256 (message "Replicated" 1 [("rejection",.present (.variant "Rejection" "Conflict" [("next",word 1)]))]) = .ok true := by rfl
theorem append_payload_unread (payload : PureValue) :
    Jarl.node_Node_valid 256 (message "Append" 1
      [("previous",logId 0 0),("entry",.present (entry 1 1 payload))]) = .ok true := by rfl


set_option maxRecDepth 10000
set_option maxHeartbeats 1000000
def campaignHead : PureExpr := match Jarl.node_Node_valid_ir with
  | .sequence first _ => first
  | _ => .literal .unit
def campaignTail : PureExpr := match Jarl.node_Node_valid_ir with
  | .sequence _ rest => rest
  | _ => .literal .unit
theorem body_shape : Jarl.node_Node_valid_ir = .sequence campaignHead campaignTail := by rfl

theorem campaign_range (campaign term : Nat) (bounded : campaign < 2^64) :
    Jarl.node_Node_valid 256 (preVoted campaign term) = .ok (decide (campaign > 0)) := by
  have range : ¬18446744073709551616 ≤ campaign := Nat.not_le_of_gt bounded
  have first : pureEval 255 campaignHead (pureSet (fun _ => none) 0 (preVoted campaign term)) =
      .error (.returned (.boolean (decide (campaign > 0)))) := by
    simp [campaignHead,Jarl.node_Node_valid_ir,pureEval,pureMatch,pureSelect,List.any,pureSet,
      preVoted,word,pureBinary,pureBound,range,
      List.find?,List.foldlM,bind,Except.bind,pure,Except.pure]
  unfold Jarl.node_Node_valid pureValidate
  rw [body_shape,pure_sequence_error 255 campaignHead campaignTail _ _ first]

set_option maxRecDepth 10000
set_option maxHeartbeats 2000000

theorem vote_range (term index lastTerm : Nat)
    (termBound : term < 2^64) (indexBound : index < 2^64) (lastBound : lastTerm < 2^64) :
    Jarl.node_Node_valid 256
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
      simp (config := {maxSteps := 100000}) [Jarl.node_Node_valid,
        Jarl.node_Node_valid_ir,pureValidate,pureEval,pureMatch,pureSelect,List.any,pureSet,
        pureFields,pureField,pureBinary,pureBound,message,word,logId,
        tbound,ibound,lbound,tzero,izero,lzero,ordered,Nat.pos_iff_ne_zero,
        List.find?,List.foldlM,bind,Option.bind,Except.bind,pure,Except.pure]

set_option maxRecDepth 10000
set_option maxHeartbeats 2000000

theorem prevote_range (term index lastTerm : Nat)
    (termBound : term < 2^64) (indexBound : index < 2^64) (lastBound : lastTerm < 2^64) :
    Jarl.node_Node_valid 256
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
      simp (config := {maxSteps := 100000}) [Jarl.node_Node_valid,
        Jarl.node_Node_valid_ir,pureValidate,pureEval,pureMatch,pureSelect,List.any,pureSet,
        pureFields,pureField,pureBinary,pureBound,message,word,logId,
        tbound,ibound,lbound,tzero,izero,lzero,ordered,Nat.pos_iff_ne_zero,
        List.find?,List.foldlM,bind,Option.bind,Except.bind,pure,Except.pure]

set_option maxRecDepth 10000
set_option maxHeartbeats 2000000

theorem heartbeat_range (term index lastTerm : Nat)
    (termBound : term < 2^64) (indexBound : index < 2^64) (lastBound : lastTerm < 2^64) :
    Jarl.node_Node_valid 256
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
      simp (config := {maxSteps := 100000}) [Jarl.node_Node_valid,
        Jarl.node_Node_valid_ir,pureValidate,pureEval,pureMatch,pureSelect,List.any,pureSet,
        pureFields,pureField,pureBinary,pureBound,message,word,logId,
        tbound,ibound,lbound,tzero,izero,lzero,ordered,Nat.pos_iff_ne_zero,
        List.find?,List.foldlM,bind,Option.bind,Except.bind,pure,Except.pure]

set_option maxRecDepth 10000
set_option maxHeartbeats 2000000

theorem snapshot_range (term index lastTerm : Nat) (payload : PureValue)
    (termBound : term < 2^64) (indexBound : index < 2^64) (lastBound : lastTerm < 2^64) :
    Jarl.node_Node_valid 256
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
      simp (config := {maxSteps := 100000}) [Jarl.node_Node_valid,
        Jarl.node_Node_valid_ir,pureValidate,pureEval,pureMatch,pureSelect,List.any,pureSet,
        pureFields,pureField,pureBinary,pureBound,message,word,logId,
        tbound,ibound,lbound,tzero,izero,lzero,ordered,Nat.pos_iff_ne_zero,
        List.find?,List.foldlM,bind,Option.bind,Except.bind,pure,Except.pure]

set_option maxRecDepth 10000
set_option maxHeartbeats 2000000

theorem voted_range (term : Nat) (fields : List (String × PureValue)) (bounded : term < 2^64) :
    Jarl.node_Node_valid 256 (message "Voted" term fields) = .ok (decide (term > 0)) := by
  have range : ¬18446744073709551616 ≤ term := Nat.not_le_of_gt bounded
  by_cases empty : term = 0 <;>
    simp [Jarl.node_Node_valid,Jarl.node_Node_valid_ir,
      pureValidate,pureEval,pureMatch,pureSelect,List.any,pureSet,pureBinary,pureBound,message,word,
      range,empty,Nat.pos_iff_ne_zero,List.find?,List.foldlM,
      bind,Except.bind,pure,Except.pure]

theorem replicated_range (term : Nat) (rejection : PureValue) (bounded : term < 2^64)
    (kind : rejection = .absent ∨ rejection = .present (.variant "Rejection" "Full" [])) :
    Jarl.node_Node_valid 256
      (message "Replicated" term [("rejection",rejection)]) = .ok (decide (term > 0)) := by
  have range : ¬18446744073709551616 ≤ term := Nat.not_le_of_gt bounded
  rcases kind with rfl | rfl <;> by_cases empty : term = 0 <;>
    simp [Jarl.node_Node_valid,Jarl.node_Node_valid_ir,
      pureValidate,pureEval,pureMatch,pureSelect,List.any,pureSet,pureBinary,pureBound,message,word,
      range,empty,Nat.pos_iff_ne_zero,List.find?,List.foldlM,
      bind,Except.bind,pure,Except.pure]

theorem conflict_range (term nextIndex : Nat)
    (termBound : term < 2^64) (nextBound : nextIndex < 2^64) :
    Jarl.node_Node_valid 256 (message "Replicated" term
      [("rejection",.present (.variant "Rejection" "Conflict" [("next",word nextIndex)]))]) =
      .ok (decide (term > 0 ∧ nextIndex > 0)) := by
  have tbound : ¬18446744073709551616 ≤ term := Nat.not_le_of_gt termBound
  have nbound : ¬18446744073709551616 ≤ nextIndex := Nat.not_le_of_gt nextBound
  by_cases empty : term = 0 <;> by_cases zeroIndex : nextIndex = 0 <;>
    simp [Jarl.node_Node_valid,Jarl.node_Node_valid_ir,
      pureValidate,pureEval,pureMatch,pureSelect,List.any,pureSet,pureBinary,pureBound,message,word,
      tbound,nbound,empty,zeroIndex,Nat.pos_iff_ne_zero,List.find?,List.foldlM,
      bind,Except.bind,pure,Except.pure]



set_option maxRecDepth 10000
set_option maxHeartbeats 10000000

theorem append_range (term previousIndex previousTerm index entryTerm : Nat) (payload : PureValue)
    (termBound : term < 2^64) (previousIndexBound : previousIndex < 2^64)
    (previousTermBound : previousTerm < 2^64) (indexBound : index < 2^64)
    (entryTermBound : entryTerm < 2^64) :
    Jarl.node_Node_valid 256 (message "Append" term
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
      simp (config := {maxSteps := 20000}) [Jarl.node_Node_valid,
        Jarl.node_Node_valid_ir,pureValidate,pureEval,pureMatch,pureSelect,List.any,pureSet,
        pureFields,pureField,pureBinary,pureEqual,pureBound,message,word,logId,entry,
        *,Nat.pos_iff_ne_zero,
        List.find?,List.foldlM,bind,Option.bind,Except.bind,pure,Except.pure]
theorem append_accepted (term previousIndex previousTerm index entryTerm : Nat) (payload : PureValue)
    (termBound : term < 2^64) (previousIndexBound : previousIndex < 2^64)
    (previousTermBound : previousTerm < 2^64) (indexBound : index < 2^64)
    (entryTermBound : entryTerm < 2^64)
    (accepted : Jarl.node_Node_valid 256 (message "Append" term
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
  match Jarl.node_Node_valid_ir with
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
  simp [batchLoopBody,batchLoop,batchArm,validationArms,Jarl.node_Node_valid_ir,
    pureEval,pureMatch,pureSelect,pureSet,afterNone,
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
    Jarl.node_Node_valid 256
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
      simp (config := {maxSteps := 20000}) (disch := first | decide | exact Eq.refl _) [Jarl.node_Node_valid,
        Jarl.node_Node_valid_ir,pureValidate,pure_eval_step,pureMatch,pureSelect,List.any,pureSet,
        pureFields,pureField,pureBinary,pureBound,message,word,logId,
        tbound,ibound,lbound,tzero,izero,lzero,ordered,empty,Nat.pos_iff_ne_zero,
        List.find?,List.foldlM,bind,Option.bind,Except.bind,pure,Except.pure,
        ]
    all_goals
      have rule := each_none_scan count
      simp [batchLoop,batchArm,validationArms,Jarl.node_Node_valid_ir] at rule
      rw [rule _]
      · simp [pureSet,afterNone,empty]
      · simp [pureSet,empty]


-- Name the loop body's pieces so symbolic evaluation treats the guard operands
-- after the short-circuiting `ended` read as atoms instead of unfolding them.
def entryBody : PureExpr := match batchLoopBody with
  | .sequence (.choose _ ((_, body) :: _)) _ => body
  | _ => .literal .unit
def noneBody : PureExpr := match batchLoopBody with
  | .sequence (.choose _ (_ :: (_, body) :: _)) _ => body
  | _ => .literal .unit
theorem loop_body_shape : batchLoopBody =
    .sequence (.choose (.read 37) [(.present (.bind 38), entryBody), (.any, noneBody)])
      (.literal .unit) := by rfl
def entryGuard : PureExpr := match entryBody with
  | .sequence (.branch (.binary "||" (.binary "||" (.binary "||" _ guard) _) _) _ _) _ => guard
  | _ => .literal .unit
def entrySuccessor : PureExpr := match entryBody with
  | .sequence (.branch (.binary "||" (.binary "||" _ successor) _) _ _) _ => successor
  | _ => .literal .unit
def entryOrder : PureExpr := match entryBody with
  | .sequence (.branch (.binary "||" _ order) _ _) _ => order
  | _ => .literal .unit
def entryAdvance : PureExpr := match entryBody with
  | .sequence _ advance => advance
  | _ => .literal .unit
theorem entry_shape : entryBody =
    .sequence (.branch (.binary "||" (.binary "||" (.binary "||" (.read 32) entryGuard)
        entrySuccessor) entryOrder) (.sequence (.ret (.literal (.boolean false))) (.literal .unit))
      (.literal .unit)) entryAdvance := by rfl

theorem entry_after_end (extra : Nat) (env : PureEnv) (value : PureValue)
    (ended : env 32 = some (.boolean true)) :
    pureEval (extra+32) batchLoopBody (pureSet env 37 (.present value)) =
      .error (.returned (.boolean false)) := by
  rw [loop_body_shape]
  simp [pureEval,pureSelect,pureMatch,List.foldlM,entry_shape,pureSet,ended,
    bind,Except.bind,pure,Except.pure]

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
    Jarl.node_Node_valid 256
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
      simp (config := {maxSteps := 20000}) (disch := first | decide | exact Eq.refl _) [Jarl.node_Node_valid,
        Jarl.node_Node_valid_ir,pureValidate,pure_eval_step,pureMatch,pureSelect,List.any,pureSet,
        pureFields,pureField,pureBinary,pureBound,message,word,logId,
        tbound,ibound,lbound,tzero,izero,lzero,ordered,Nat.pos_iff_ne_zero,
        List.find?,List.foldlM,bind,Option.bind,Except.bind,pure,Except.pure]
    all_goals
      have rule := each_hole value rest
      simp [batchLoop,batchArm,validationArms,Jarl.node_Node_valid_ir] at rule
      rw [rule _]
      rfl



set_option maxRecDepth 10000
set_option maxHeartbeats 10000000

def afterEntry (env : PureEnv) (index term count : Nat) (payload : PureValue) : PureEnv :=
  let value := entry index term payload
  let id := logId index term
  let env := pureSet env 37 (.present value)
  let env := pureSet env 38 value
  let env := pureSet env 39 id
  let env := pureSet env 40 id
  let env := pureSet env 41 (logId 0 0)
  let env := pureSet env 31 id
  pureSet env 33 (.number "i32" (count+1))

def admissibleEntry (term previousIndex previousTerm index entryTerm : Nat) : Prop :=
  ((index = 0 ∧ entryTerm = 0) ∨ (index > 0 ∧ entryTerm > 0 ∧ entryTerm ≤ term)) ∧
  previousIndex+1 < 2^64 ∧ previousIndex+1 = index ∧ previousTerm ≤ entryTerm
instance (term previousIndex previousTerm index entryTerm : Nat) :
    Decidable (admissibleEntry term previousIndex previousTerm index entryTerm) :=
  inferInstanceAs (Decidable (_ ∧ _ ∧ _ ∧ _))

def scanEnv (env : PureEnv) (term previousIndex previousTerm count : Nat) (ended : Bool) : PureEnv :=
  pureSet (pureSet (pureSet (pureSet env 10 (word term)) 31 (logId previousIndex previousTerm))
    32 (.boolean ended)) 33 (.number "i32" count)

theorem some_iteration (env : PureEnv) (term previousIndex previousTerm index entryTerm count : Nat)
    (ended : Bool) (payload : PureValue)
    (readTerm : env 10 = some (word term))
    (readPrevious : env 31 = some (logId previousIndex previousTerm))
    (readEnded : env 32 = some (.boolean ended))
    (readCount : env 33 = some (.number "i32" count))
    (termBound : term < 2^64) (previousIndexBound : previousIndex < 2^64)
    (previousTermBound : previousTerm < 2^64) (indexBound : index < 2^64)
    (entryTermBound : entryTerm < 2^64) (countBound : count < 2^31) :
    pureEval 246 batchLoopBody (pureSet env 37 (.present (entry index entryTerm payload))) =
      if ended = false ∧ admissibleEntry term previousIndex previousTerm index entryTerm then
        if count+1 < 2^31 then .ok (.unit,afterEntry env index entryTerm count payload)
        else .error (.fault .overflow)
      else .error (.returned (.boolean false)) := by
  have canonical : scanEnv env term previousIndex previousTerm count ended = env := by
    funext key
    by_cases a : key = 10 <;> by_cases b : key = 31 <;> by_cases c : key = 32 <;> by_cases d : key = 33 <;>
      simp_all [scanEnv,pureSet]
  rw [← canonical]
  clear canonical
  cases ended with
  | true =>
    simp only [Bool.true_eq_false,false_and,ite_false]
    exact entry_after_end 214 _ _ (by simp [scanEnv,pureSet])
  | false =>
    have tbound : ¬18446744073709551616 ≤ term := Nat.not_le_of_gt termBound
    have pibound : ¬18446744073709551616 ≤ previousIndex := Nat.not_le_of_gt previousIndexBound
    have ptbound : ¬18446744073709551616 ≤ previousTerm := Nat.not_le_of_gt previousTermBound
    have ibound : ¬18446744073709551616 ≤ index := Nat.not_le_of_gt indexBound
    have etbound : ¬18446744073709551616 ≤ entryTerm := Nat.not_le_of_gt entryTermBound
    have cbound : ¬2147483648 ≤ count := Nat.not_le_of_gt countBound
    have typedIndex : index < 18446744073709551616 := indexBound
    by_cases izero : index = 0 <;> by_cases etzero : entryTerm = 0 <;>
      by_cases eordered : entryTerm ≤ term <;> by_cases successive : previousIndex+1 = index <;>
      by_cases ordered : previousTerm ≤ entryTerm <;>
      by_cases backward : entryTerm < previousTerm <;>
      by_cases noOverflow : previousIndex+1 < 18446744073709551616 <;>
      by_cases countFits : count+1 < 2147483648 <;> try omega
    all_goals simp_all only
    all_goals
      simp (config := {maxSteps := 20000}) [batchLoopBody,batchLoop,batchArm,validationArms,
        Jarl.node_Node_valid_ir,pureEval,pureMatch,pureSelect,pureSet,pureFields,pureField,
        pureBinary,pureEqual,pureBound,word,logId,entry,afterEntry,scanEnv,admissibleEntry,
        *,Nat.pos_iff_ne_zero,List.find?,bind,Option.bind,Except.bind,pure,Except.pure]



set_option maxRecDepth 10000
set_option maxHeartbeats 2000000

structure BatchEntryData where
  index : Nat
  term : Nat
  payload : PureValue

def slotView : Option BatchEntryData → PureValue
  | none => .absent
  | some item => .present (entry item.index item.term item.payload)

def slotsBounded : List (Option BatchEntryData) → Prop
  | [] => True
  | none :: rest => slotsBounded rest
  | some item :: rest => item.index < 2^64 ∧ item.term < 2^64 ∧ slotsBounded rest

structure ScanCursor where
  index : Nat
  term : Nat
  count : Nat
  ended : Bool
  deriving DecidableEq

def cursorRep (term : Nat) (cursor : ScanCursor) (env : PureEnv) : Prop :=
  env 10 = some (word term) ∧ env 31 = some (logId cursor.index cursor.term) ∧
  env 32 = some (.boolean cursor.ended) ∧ env 33 = some (.number "i32" cursor.count)

def scan (term : Nat) (cursor : ScanCursor) : List (Option BatchEntryData) → Option ScanCursor
  | [] => some cursor
  | none :: rest => scan term {cursor with ended := true} rest
  | some item :: rest =>
    if cursor.ended = false ∧ admissibleEntry term cursor.index cursor.term item.index item.term then
      scan term ⟨item.index,item.term,cursor.count+1,false⟩ rest
    else none

def scanMatches (term : Nat) (expected : Option ScanCursor) (actual : PureResult) : Prop :=
  match expected with
  | none => actual = .error (.returned (.boolean false))
  | some cursor => ∃ env, actual = .ok (.unit,env) ∧ cursorRep term cursor env ∧ cursor.count < 2^31

def batchFold (slots : List (Option BatchEntryData)) (env : PureEnv) : PureResult :=
  (slots.map slotView).foldlM (fun (_,env) value =>
    pureEval 246 batchLoopBody (pureSet env 37 value)) (.unit,env)

theorem none_rep (term : Nat) (cursor : ScanCursor) (env : PureEnv)
    (represented : cursorRep term cursor env) :
    cursorRep term {cursor with ended := true} (afterNone env) := by
  rcases represented with ⟨t,p,_,c⟩
  simp [cursorRep,afterNone,pureSet,t,p,c]

theorem entry_rep (term : Nat) (cursor : ScanCursor) (env : PureEnv) (item : BatchEntryData)
    (represented : cursorRep term cursor env) (openPrefix : cursor.ended = false) :
    cursorRep term ⟨item.index,item.term,cursor.count+1,false⟩
      (afterEntry env item.index item.term cursor.count item.payload) := by
  rcases represented with ⟨t,_,e,_⟩
  simp [cursorRep,afterEntry,pureSet,t,e,openPrefix]

theorem scan_simulation (term : Nat) (slots : List (Option BatchEntryData))
    (cursor : ScanCursor) (env : PureEnv)
    (represented : cursorRep term cursor env)
    (termBound : term < 2^64) (indexBound : cursor.index < 2^64) (previousTermBound : cursor.term < 2^64)
    (wellFormed : slotsBounded slots) (budget : cursor.count + slots.length < 2^31) :
    scanMatches term (scan term cursor slots) (batchFold slots env) := by
  induction slots generalizing cursor env with
  | nil =>
    refine ⟨env,rfl,represented,?_⟩
    simpa using budget
  | cons slot rest ih =>
    have countBound : cursor.count < 2^31 := by simp only [List.length_cons] at budget; omega
    cases slot with
    | none =>
      have source : pureEval 246 batchLoopBody (pureSet env 37 .absent) = .ok (.unit,afterNone env) :=
        none_iteration 238 env
      have remaining : cursor.count + rest.length < 2^31 := by simp only [List.length_cons] at budget; omega
      have next := ih {cursor with ended := true} (afterNone env) (none_rep term cursor env represented)
        indexBound previousTermBound wellFormed remaining
      simpa [scan,batchFold,slotView,List.foldlM,source,bind,Except.bind] using next
    | some item =>
      rcases wellFormed with ⟨itemIndex,itemTerm,restBound⟩
      have fits : cursor.count+1 < 2^31 := by simp only [List.length_cons] at budget; omega
      have source := some_iteration env term cursor.index cursor.term item.index item.term cursor.count
        cursor.ended item.payload represented.1 represented.2.1 represented.2.2.1 represented.2.2.2
        termBound indexBound previousTermBound itemIndex itemTerm countBound
      by_cases accepted : cursor.ended = false ∧ admissibleEntry term cursor.index cursor.term item.index item.term
      · have remaining : (cursor.count+1)+rest.length < 2^31 := by simp only [List.length_cons] at budget; omega
        have next := ih ⟨item.index,item.term,cursor.count+1,false⟩
          (afterEntry env item.index item.term cursor.count item.payload)
          (entry_rep term cursor env item represented accepted.1) itemIndex itemTerm restBound remaining
        simp only [accepted,ite_true,fits] at source
        simpa [scan,accepted,batchFold,slotView,List.foldlM,source,bind,Except.bind] using next
      · simp only [accepted,ite_false] at source
        simp [scan,accepted,scanMatches,batchFold,slotView,source,bind,Except.bind]
theorem each_scan_model (term : Nat) (slots : List (Option BatchEntryData))
    (cursor : ScanCursor) (env : PureEnv)
    (represented : cursorRep term cursor env)
    (termBound : term < 2^64) (indexBound : cursor.index < 2^64) (previousTermBound : cursor.term < 2^64)
    (wellFormed : slotsBounded slots) (budget : cursor.count + slots.length < 2^31)
    (read : env 30 = some (.array (slots.map slotView))) :
    scanMatches term (scan term cursor slots) (pureEval 247 batchLoop env) := by
  have source : pureEval 246 (.read 30) env = .ok (.array (slots.map slotView),env) := by
    simp [pureEval,read]
  have result := scan_simulation term slots cursor env represented termBound indexBound previousTermBound wellFormed budget
  rw [batch_loop_shape,pureEval,source]
  exact result

def acceptedScan (term index previousTerm : Nat) (slots : List (Option BatchEntryData)) : Bool :=
  match scan term ⟨index,previousTerm,0,false⟩ slots with
  | none => false
  | some cursor => decide (cursor.count > 0)

theorem batch_range (term index previousTerm : Nat) (slots : List (Option BatchEntryData))
    (termBound : term < 2^64) (indexBound : index < 2^64) (previousTermBound : previousTerm < 2^64)
    (wellFormed : slotsBounded slots) (capacity : slots.length < 2^31) :
    Jarl.node_Node_valid 256 (message "AppendBatch" term
      [("previous",logId index previousTerm),("entries",.array (slots.map slotView))]) =
      .ok (if term > 0 ∧ ((index = 0 ∧ previousTerm = 0) ∨
        (index > 0 ∧ previousTerm > 0 ∧ previousTerm ≤ term)) then acceptedScan term index previousTerm slots else false) := by
  have tbound : ¬18446744073709551616 ≤ term := Nat.not_le_of_gt termBound
  have ibound : ¬18446744073709551616 ≤ index := Nat.not_le_of_gt indexBound
  have pbound : ¬18446744073709551616 ≤ previousTerm := Nat.not_le_of_gt previousTermBound
  by_cases tzero : term = 0
  · subst term
    simp [zero_term_appendbatch]
  · by_cases izero : index = 0 <;> by_cases pzero : previousTerm = 0 <;>
      by_cases ordered : previousTerm ≤ term <;>
      simp (config := {maxSteps := 20000}) (disch := first | decide | exact Eq.refl _) [Jarl.node_Node_valid,
        Jarl.node_Node_valid_ir,pureValidate,pure_eval_step,pureMatch,pureSelect,List.any,pureSet,
        pureFields,pureField,pureBinary,pureBound,message,word,logId,
        tbound,ibound,pbound,tzero,izero,pzero,ordered,Nat.pos_iff_ne_zero,
        List.find?,List.foldlM,bind,Option.bind,Except.bind,pure,Except.pure]
    all_goals
      have rule := each_scan_model term slots ⟨index,previousTerm,0,false⟩
      simp [batchLoop,batchArm,validationArms,Jarl.node_Node_valid_ir] at rule
      generalize evaluated : pureEval 247 (.each (.read 30) 37 _) _ = outcome
      have matched : scanMatches term (scan term ⟨index,previousTerm,0,false⟩ slots) outcome := by
        rw [← evaluated]
        apply rule
        · simp [cursorRep,pureSet,word,logId,izero,pzero]
        · exact termBound
        · exact indexBound
        · exact previousTermBound
        · exact wellFormed
        · simpa using capacity
        · simp [pureSet]
      cases scanned : scan term ⟨index,previousTerm,0,false⟩ slots with
      | none =>
        simp only [scanned,scanMatches] at matched
        rw [matched]
        try simp only [izero,pzero] at scanned
        simp [acceptedScan,scanned]
      | some finalCursor =>
        simp only [scanned,scanMatches] at matched
        rcases matched with ⟨after,returned,rep,finalBound⟩
        rw [returned]
        have bounded : ¬2147483648 ≤ finalCursor.count := Nat.not_le_of_gt finalBound
        try simp only [izero,pzero] at scanned
        simp [acceptedScan,scanned,rep.2.2.2,bounded]
def vacant : List (Option BatchEntryData) → Prop
  | [] => True
  | none :: rest => vacant rest
  | some _ :: _ => False

def occupied : List (Option BatchEntryData) → Nat
  | [] => 0
  | none :: rest => occupied rest
  | some _ :: rest => occupied rest + 1

inductive OrderedSlots (term : Nat) : Nat → Nat → List (Option BatchEntryData) → Prop
  | nil (index previousTerm : Nat) : OrderedSlots term index previousTerm []
  | padding (index previousTerm : Nat) (rest : List (Option BatchEntryData))
      (empty : vacant rest) : OrderedSlots term index previousTerm (none :: rest)
  | next (index previousTerm : Nat) (item : BatchEntryData) (rest : List (Option BatchEntryData))
      (successor : item.index = index+1) (positive : item.term > 0)
      (monotone : previousTerm ≤ item.term) (bounded : item.term ≤ term)
      (tailOrdered : OrderedSlots term item.index item.term rest) :
      OrderedSlots term index previousTerm (some item :: rest)

theorem admissible_fields (term previousIndex previousTerm index entryTerm : Nat)
    (accepted : admissibleEntry term previousIndex previousTerm index entryTerm) :
    index = previousIndex+1 ∧ entryTerm > 0 ∧ previousTerm ≤ entryTerm ∧ entryTerm ≤ term := by
  rcases accepted with ⟨valid,_,successor,ordered⟩
  rcases valid with ⟨empty,_⟩ | ⟨_,positive,bounded⟩
  · omega
  · exact ⟨successor.symm,positive,ordered,bounded⟩

theorem scan_after_end (term : Nat) (slots : List (Option BatchEntryData))
    (cursor finalCursor : ScanCursor) (ended : cursor.ended = true)
    (returned : scan term cursor slots = some finalCursor) : vacant slots := by
  induction slots generalizing cursor with
  | nil => trivial
  | cons slot rest ih =>
    cases slot with
    | none => exact ih {cursor with ended := true} rfl returned
    | some item => simp [scan,ended] at returned

theorem scan_count (term : Nat) (slots : List (Option BatchEntryData))
    (cursor finalCursor : ScanCursor)
    (returned : scan term cursor slots = some finalCursor) :
    finalCursor.count = cursor.count + occupied slots := by
  induction slots generalizing cursor with
  | nil =>
    have equal : cursor = finalCursor := Option.some.inj returned
    cases equal
    rfl
  | cons slot rest ih =>
    cases slot with
    | none => exact ih {cursor with ended := true} returned
    | some item =>
      by_cases accepted : cursor.ended = false ∧ admissibleEntry term cursor.index cursor.term item.index item.term
      · simp only [scan,accepted] at returned
        have next := ih ⟨item.index,item.term,cursor.count+1,false⟩ returned
        change finalCursor.count = (cursor.count+1) + occupied rest at next
        simp only [occupied]
        omega
      · simp [scan,accepted] at returned

theorem scan_ordered (term : Nat) (slots : List (Option BatchEntryData))
    (cursor finalCursor : ScanCursor)
    (returned : scan term cursor slots = some finalCursor) :
    OrderedSlots term cursor.index cursor.term slots := by
  induction slots generalizing cursor with
  | nil => exact .nil _ _
  | cons slot rest ih =>
    cases slot with
    | none =>
      exact .padding _ _ rest (scan_after_end term rest {cursor with ended := true} finalCursor rfl returned)
    | some item =>
      by_cases accepted : cursor.ended = false ∧ admissibleEntry term cursor.index cursor.term item.index item.term
      · simp only [scan,accepted] at returned
        obtain ⟨successor,positive,monotone,bounded⟩ := admissible_fields _ _ _ _ _ accepted.2
        exact .next _ _ item rest successor positive monotone bounded
          (ih ⟨item.index,item.term,cursor.count+1,false⟩ returned)
      · simp [scan,accepted] at returned

theorem batch_accepted (term index previousTerm : Nat) (slots : List (Option BatchEntryData))
    (termBound : term < 2^64) (indexBound : index < 2^64) (previousTermBound : previousTerm < 2^64)
    (wellFormed : slotsBounded slots) (capacity : slots.length < 2^31)
    (accepted : Jarl.node_Node_valid 256 (message "AppendBatch" term
      [("previous",logId index previousTerm),("entries",.array (slots.map slotView))]) = .ok true) :
    term > 0 ∧ ((index = 0 ∧ previousTerm = 0) ∨
      (index > 0 ∧ previousTerm > 0 ∧ previousTerm ≤ term)) ∧
      occupied slots > 0 ∧ OrderedSlots term index previousTerm slots := by
  rw [batch_range term index previousTerm slots termBound indexBound previousTermBound wellFormed capacity] at accepted
  by_cases header : term > 0 ∧ ((index = 0 ∧ previousTerm = 0) ∨
      (index > 0 ∧ previousTerm > 0 ∧ previousTerm ≤ term))
  · simp only [header,acceptedScan] at accepted
    cases result : scan term ⟨index,previousTerm,0,false⟩ slots with
    | none => simp [result] at accepted
    | some finalCursor =>
      simp only [result] at accepted
      have positive := of_decide_eq_true (Except.ok.inj accepted)
      have count := scan_count term slots ⟨index,previousTerm,0,false⟩ finalCursor result
      refine ⟨header.1,header.2,?_,scan_ordered term slots ⟨index,previousTerm,0,false⟩ finalCursor result⟩
      simpa [count] using positive
  · simp [header] at accepted

-- This is a domain of canonical structural views, not a Rust memory relation.
-- Unread payloads remain arbitrary. Bounds describe representation, not protocol
-- validity: zero terms, gaps, holes and decreasing terms are allowed inputs.
inductive ValidationView : PureValue → Prop
  | campaign (campaign term : Nat) (bounded : campaign < 2^64) :
      ValidationView (preVoted campaign term)
  | vote (term index lastTerm : Nat) (tb : term < 2^64) (ib : index < 2^64) (lb : lastTerm < 2^64) :
      ValidationView (message "Vote" term [("last",logId index lastTerm)])
  | prevote (term index lastTerm : Nat) (tb : term < 2^64) (ib : index < 2^64) (lb : lastTerm < 2^64) :
      ValidationView (message "PreVote" term [("last",logId index lastTerm)])
  | voted (term : Nat) (fields : List (String × PureValue)) (tb : term < 2^64) :
      ValidationView (message "Voted" term fields)
  | heartbeat (term index lastTerm : Nat) (tb : term < 2^64) (ib : index < 2^64) (lb : lastTerm < 2^64) :
      ValidationView (message "Append" term [("previous",logId index lastTerm),("entry",.absent)])
  | append (term pi pt index et : Nat) (payload : PureValue)
      (tb : term < 2^64) (pib : pi < 2^64) (ptb : pt < 2^64) (ib : index < 2^64) (eb : et < 2^64) :
      ValidationView (message "Append" term
        [("previous",logId pi pt),("entry",.present (entry index et payload))])
  | batch (term index pt : Nat) (slots : List (Option BatchEntryData))
      (tb : term < 2^64) (ib : index < 2^64) (pb : pt < 2^64)
      (typed : slotsBounded slots) (capacity : slots.length < 2^31) :
      ValidationView (message "AppendBatch" term
        [("previous",logId index pt),("entries",.array (slots.map slotView))])
  | snapshot (term index lastTerm : Nat) (payload : PureValue)
      (tb : term < 2^64) (ib : index < 2^64) (lb : lastTerm < 2^64) :
      ValidationView (message "Install" term
        [("snapshot",.record "Snapshot" [("last",logId index lastTerm),("value",payload)])])
  | replicated (term : Nat) (rejection : PureValue) (tb : term < 2^64)
      (kind : rejection = .absent ∨ rejection = .present (.variant "Rejection" "Full" [])) :
      ValidationView (message "Replicated" term [("rejection",rejection)])
  | conflict (term nextIndex : Nat) (tb : term < 2^64) (nb : nextIndex < 2^64) :
      ValidationView (message "Replicated" term
        [("rejection",.present (.variant "Rejection" "Conflict" [("next",word nextIndex)]))])

theorem validation_total (input : PureValue) (view : ValidationView input) :
    ∃ accepted, Jarl.node_Node_valid 256 input = .ok accepted := by
  cases view with
  | campaign campaign term bounded => exact ⟨_,campaign_range campaign term bounded⟩
  | vote term index lastTerm tb ib lb => exact ⟨_,vote_range term index lastTerm tb ib lb⟩
  | prevote term index lastTerm tb ib lb => exact ⟨_,prevote_range term index lastTerm tb ib lb⟩
  | voted term fields tb => exact ⟨_,voted_range term fields tb⟩
  | heartbeat term index lastTerm tb ib lb => exact ⟨_,heartbeat_range term index lastTerm tb ib lb⟩
  | append term pi pt index et payload tb pib ptb ib eb =>
      exact ⟨_,append_range term pi pt index et payload tb pib ptb ib eb⟩
  | batch term index pt slots tb ib pb typed capacity =>
      exact ⟨_,batch_range term index pt slots tb ib pb typed capacity⟩
  | snapshot term index lastTerm payload tb ib lb => exact ⟨_,snapshot_range term index lastTerm payload tb ib lb⟩
  | replicated term rejection tb kind => exact ⟨_,replicated_range term rejection tb kind⟩
  | conflict term nextIndex tb nb => exact ⟨_,conflict_range term nextIndex tb nb⟩

theorem validation_no_fault (input : PureValue) (view : ValidationView input) (fault : PureFault) :
    Jarl.node_Node_valid 256 input ≠ .error fault := by
  obtain ⟨accepted,result⟩ := validation_total input view
  rw [result]
  intro impossible
  cases impossible

theorem vacant_scan (term : Nat) (slots : List (Option BatchEntryData))
    (empty : vacant slots) (cursor : ScanCursor) :
    ∃ finalCursor, scan term cursor slots = some finalCursor := by
  induction slots generalizing cursor with
  | nil => exact ⟨cursor,rfl⟩
  | cons slot rest ih =>
    cases slot with
    | none => exact ih empty {cursor with ended := true}
    | some item => contradiction

theorem ordered_scan (term index previousTerm : Nat) (slots : List (Option BatchEntryData))
    (ordered : OrderedSlots term index previousTerm slots)
    (typed : slotsBounded slots) (count : Nat) :
    ∃ finalCursor, scan term ⟨index,previousTerm,count,false⟩ slots = some finalCursor := by
  induction ordered generalizing count with
  | nil index previousTerm => exact ⟨_,rfl⟩
  | padding index previousTerm rest empty =>
      exact vacant_scan term rest empty ⟨index,previousTerm,count,true⟩
  | next index previousTerm item rest successor positive monotone bounded tailOrdered ih =>
      have entryBound : item.index < 2^64 := typed.1
      have allowed : admissibleEntry term index previousTerm item.index item.term := by
        refine ⟨Or.inr ⟨?_,positive,bounded⟩,?_,successor.symm,monotone⟩ <;> omega
      simpa only [scan, Bool.false_eq_true, and_self, ite_true, allowed] using ih typed.2.2 (count+1)

theorem batch_accepts_iff (term index previousTerm : Nat) (slots : List (Option BatchEntryData))
    (termBound : term < 2^64) (indexBound : index < 2^64) (previousTermBound : previousTerm < 2^64)
    (wellFormed : slotsBounded slots) (capacity : slots.length < 2^31) :
    Jarl.node_Node_valid 256 (message "AppendBatch" term
      [("previous",logId index previousTerm),("entries",.array (slots.map slotView))]) = .ok true ↔
    term > 0 ∧ ((index = 0 ∧ previousTerm = 0) ∨
      (index > 0 ∧ previousTerm > 0 ∧ previousTerm ≤ term)) ∧
    occupied slots > 0 ∧ OrderedSlots term index previousTerm slots := by
  constructor
  · exact batch_accepted term index previousTerm slots termBound indexBound previousTermBound wellFormed capacity
  · rintro ⟨positive,base,nonempty,ordered⟩
    obtain ⟨finalCursor,returned⟩ := ordered_scan term index previousTerm slots ordered wellFormed 0
    have count := scan_count term slots ⟨index,previousTerm,0,false⟩ finalCursor returned
    have finalPositive : finalCursor.count > 0 := by simpa [count] using nonempty
    rw [batch_range term index previousTerm slots termBound indexBound previousTermBound wellFormed capacity]
    simp [positive,base,acceptedScan,returned,finalPositive]

end Validation
