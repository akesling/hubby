import Generated
open Provium.State
namespace Messages

def Variants : List String :=
  ["PreVote","PreVoted","Vote","Voted","Append","AppendBatch","Install","Replicated"]

theorem term_all_variants (variant : String) (fields : InitStore) (term : Nat)
    (known : variant ∈ Variants) (read : recordWord fields ["term"] = some term) :
    JarlMessages.Message_term ⟨variant,fields⟩ = some term := by
  simp only [Variants,List.mem_cons,List.not_mem_nil,or_false] at known
  rcases known with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;>
    simp [JarlMessages.Message_term,JarlMessages.Message_term_ir,enumProjection,read,bind,Option.bind]

-- Explicit variant/field coverage prevents silently weakening this contract to
-- only the already-known subset after a new protocol variant is introduced.
theorem projection_places (variant : String) (fields : InitStore) (term : Nat)
    (known : variant ∈ Variants) (read : recordWord fields ["term"] = some term) :
    JarlMessages.Message_term_ir = Variants.map (fun variant => (variant,["term"])) ∧
    JarlMessages.Message_term ⟨variant,fields⟩ = some term := by
  exact ⟨rfl,term_all_variants variant fields term known read⟩

end Messages
