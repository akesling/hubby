import Generated
open Provium.State
namespace RecoveryTrace
structure Datum where
  index : Nat
  term : Nat
  serial : Nat
  deriving DecidableEq
structure Metadata where
  term : Nat
  voted : Bool
  commit : Nat
  deriving DecidableEq
structure Observation where
  result : String
  length : Nat
  entries : List (Option Nat)
  hard : Metadata
  snapshot : Option Datum
  events : List String
  deriving DecidableEq

def dataView (data : Datum) (_ : Path) (path : Path) : InitCell :=
  if path = ["index"] then .unsigned "u64" data.index else .unsigned "u64" data.term

def hardView (hard : Metadata) (path : Path) : InitCell :=
  if path = ["term"] then .unsigned "u64" hard.term else .unsigned "u64" hard.commit

def hardPresence (hard : Metadata) (_ : Path) : Bool := hard.voted

def failed (name : String) : Observation := ⟨name,0,[],⟨0,false,0⟩,none,[]⟩
def events (extra : List String) (outcome : Observation) : Observation :=
  {outcome with events := extra ++ outcome.events}
def entryDrop (entry : Datum) : String := "e" ++ toString entry.serial
def snapshotDrop (snapshot : Datum) : String := "s" ++ toString snapshot.serial
-- This driver is one concrete VecDeque-based consumer, including its source
-- destructor inside into_iter and remaining entries inside iterator destruction.
-- It is test evidence; the generic semantics above do not assume this consumer.
def drive : Nat → RecoveryRun Datum Datum Metadata (List Datum) (List Datum) → Observation
  | 0,_ => failed "driver-exhausted"
  | fuel + 1,run => match run with
    | .returned (.error name) => failed name
    | .returned (.ok state) =>
      ⟨"ok",state.buffer.len,state.buffer.slots.map (Option.map Datum.serial),state.hard,state.snapshot,[]⟩
    | .invalidRepresentation _ _ _ => failed "invalid-representation"
    | .fault _ _ _ _ _ => failed "fault"
    | .intoIterator source _ next => events ["into-iterator","source-drop"] (drive fuel (next source))
    | .next iterator _ resume => events ["next"] (drive fuel (resume iterator.head? iterator.tail))
    | .dropEntry entry next => events [entryDrop entry] (drive fuel next)
    | .dropSnapshot snapshot next => events [snapshotDrop snapshot] (drive fuel next)
    | .dropSource source next => events ("source-drop" :: source.map entryDrop) (drive fuel next)
    | .dropIterator iterator next => events ("iterator-drop" :: iterator.map entryDrop) (drive fuel next)
end RecoveryTrace
