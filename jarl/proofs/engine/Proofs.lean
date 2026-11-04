import Generated
import Engine.Main

namespace Jarl.Engine
open Jarl

theorem new_state_base {V S : Type} {CAP : Nat} : (State.new : State V S CAP).base = LogId.default := by
  simp [State.new, State.base, Rust.Option.map_or]
end Jarl.Engine
