import Generated
import Engine.Main
import Engine.App.Main
import Engine.Host.Main
import Contracts.Capacity
import Contracts.Initialization
import Contracts.InputGating
import Contracts.LogBoundary
import Contracts.MessageDispatch
import Contracts.Persistence
import Contracts.Election
import Contracts.MessageValidation
import Contracts.StorageView
import Contracts.Replication
import Contracts.Membership
import Contracts.Consensus

namespace Jarl.Engine
open Jarl

theorem new_state_base {V S : Type} {CAP : Nat} : (State.new : State V S CAP).base = LogId.default := by
  simp [State.new, State.base, Rust.Option.map_or]
end Jarl.Engine
