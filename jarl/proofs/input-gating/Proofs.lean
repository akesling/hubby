import Generated
open Provium.State
namespace JarlGateProofs

theorem exact_result (s : QueryStore α) (dirty : Bool)
    (extra : Option α) (outbox : List (Option α))
    (hd : s ["dirty"] = .boolean dirty)
    (he : s ["extra_reply"] = .optional extra)
    (ho : s ["outbox"] = .slots outbox) :
    JarlGate.node_Node_available s =
      if dirty || extra.isSome || outbox.any Option.isSome then
        .error "Error::Busy" else .ok () := by
  simp [JarlGate.node_Node_available, JarlGate.node_Node_available_ir,
    runQuery, evalQueryTest, hd, he, ho]

theorem dirty_blocks (s : QueryStore α)
    (hd : s ["dirty"] = .boolean true) :
    JarlGate.node_Node_available s = .error "Error::Busy" := by
  simp [JarlGate.node_Node_available, JarlGate.node_Node_available_ir,
    runQuery, evalQueryTest, hd]

theorem pending_reply_blocks (s : QueryStore α) (reply : α)
    (he : s ["extra_reply"] = .optional (some reply)) :
    JarlGate.node_Node_available s = .error "Error::Busy" := by
  simp [JarlGate.node_Node_available, JarlGate.node_Node_available_ir,
    runQuery, evalQueryTest, he]

theorem pending_outbox_blocks (s : QueryStore α) (outbox : List (Option α))
    (ho : s ["outbox"] = .slots outbox)
    (pending : outbox.any Option.isSome = true) :
    JarlGate.node_Node_available s = .error "Error::Busy" := by
  simp [JarlGate.node_Node_available, JarlGate.node_Node_available_ir,
    runQuery, evalQueryTest, ho, pending]

theorem clean_allows (s : QueryStore α) (outbox : List (Option α))
    (hd : s ["dirty"] = .boolean false)
    (he : s ["extra_reply"] = .optional none)
    (ho : s ["outbox"] = .slots outbox)
    (drained : outbox.any Option.isSome = false) :
    JarlGate.node_Node_available s = .ok () := by
  simp [JarlGate.node_Node_available, JarlGate.node_Node_available_ir,
    runQuery, evalQueryTest, hd, he, ho, drained]

theorem idle_agrees (s : QueryStore α) :
    JarlGate.node_Node_idle s = JarlGate.node_Node_available s := by rfl

-- Relate the Ready field-store view and the Node query-store view. The arbitrary
-- decoders interpret untouched opaque output fields; this composition does not
-- establish Rust alias/layout refinement or authorize acknowledging a failed save.
def gateView (s : Store α) (extra : Cell α → Option β)
    (outbox : Cell α → List (Option β)) : QueryStore β := fun key =>
  if key = ["dirty"] then
    .boolean (evalCondition (.field ["node", "dirty"]) s)
  else if key = ["extra_reply"] then .optional (extra (s ["node", "extra_reply"]))
  else .slots (outbox (s ["node", "outbox"]))

theorem after_ack_exact (s : Store α) (extra : Cell α → Option β)
    (outbox : Cell α → List (Option β)) :
    JarlGate.node_Node_available
      (gateView (JarlGate.ready_Ready_persisted s) extra outbox) =
      if (extra (s ["node", "extra_reply"])).isSome ||
          (outbox (s ["node", "outbox"])).any Option.isSome then
        .error "Error::Busy" else .ok () := by
  simp [JarlGate.node_Node_available, JarlGate.node_Node_available_ir,
    runQuery, evalQueryTest, gateView, evalCondition,
    JarlGate.ready_Ready_persisted, put]

theorem ack_preserves_pending_outputs (s : Store α)
    (extra : Cell α → Option β) (outbox : Cell α → List (Option β))
    (pending : ((extra (s ["node", "extra_reply"])).isSome ||
      (outbox (s ["node", "outbox"])).any Option.isSome) = true) :
    JarlGate.node_Node_available
      (gateView (JarlGate.ready_Ready_persisted s) extra outbox) =
      .error "Error::Busy" := by
  rw [after_ack_exact]
  simp [pending]

end JarlGateProofs
