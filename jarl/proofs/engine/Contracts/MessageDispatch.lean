import Generated

/-!
Complete `Message::term`: all eight variants read the durable/proposed `term`
field specified by Rust; `PreVoted` reads `term` rather than `campaign`.
-/

namespace Jarl.Contracts.MessageDispatch

theorem term_all_variants {V S : Type} :
    (∀ term last, Message.term (Message.PreVote (V := V) (S := S) term last) = term) ∧
    (∀ term campaign granted,
      Message.term (Message.PreVoted (V := V) (S := S) term campaign granted) = term) ∧
    (∀ term last, Message.term (Message.Vote (V := V) (S := S) term last) = term) ∧
    (∀ term granted, Message.term (Message.Voted (V := V) (S := S) term granted) = term) ∧
    (∀ term previous entry commit,
      Message.term (Message.Append (V := V) (S := S) term previous entry commit) = term) ∧
    (∀ term previous entries commit,
      Message.term (Message.AppendBatch (V := V) (S := S) term previous entries commit) = term) ∧
    (∀ term snapshot, Message.term (Message.Install (V := V) (S := S) term snapshot) = term) ∧
    (∀ term index rejection,
      Message.term (Message.Replicated (V := V) (S := S) term index rejection) = term) :=
  ⟨fun _ _ => rfl, fun _ _ _ => rfl, fun _ _ => rfl, fun _ _ => rfl,
   fun _ _ _ _ => rfl, fun _ _ _ _ => rfl, fun _ _ => rfl, fun _ _ _ => rfl⟩

/-- Explicit variant/field coverage: every message is one of the eight variants
    above, carrying `Message.term m` in its `term` field. Adding a variant or
    reading another field breaks this statement. -/
theorem projection_places {V S : Type} (m : Message V S) :
    (∃ last, m = .PreVote m.term last) ∨
    (∃ campaign granted, m = .PreVoted m.term campaign granted) ∨
    (∃ last, m = .Vote m.term last) ∨
    (∃ granted, m = .Voted m.term granted) ∨
    (∃ previous entry commit, m = .Append m.term previous entry commit) ∨
    (∃ previous entries commit, m = .AppendBatch m.term previous entries commit) ∨
    (∃ snapshot, m = .Install m.term snapshot) ∨
    (∃ index rejection, m = .Replicated m.term index rejection) := by
  cases m <;> simp [Message.term]

end Jarl.Contracts.MessageDispatch
