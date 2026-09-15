import Generated
open Provium
namespace Capacity

theorem full_exact (len cap : Nat)
    (hl : len < 2^JarlCapacity.proviumUsizeBits)
    (hc : cap < 2^JarlCapacity.proviumUsizeBits) :
    JarlCapacity.state_State_full
      [.uint JarlCapacity.proviumUsizeBits len, .uint JarlCapacity.proviumUsizeBits cap] =
      .ok (.boolean (decide (len = cap))) := by
  simp only [JarlCapacity.proviumUsizeBits] at *
  simp [JarlCapacity.state_State_full, validArgs, validWidth, Provium.get,
    Provium.bind, binary, uintOp, hl, hc]

-- The representation invariant len ≤ cap is a caller obligation, not inferred
-- merely from the source equality. Under that invariant, admission has room.
theorem not_full_has_space (len cap : Nat)
    (hl : len < 2^JarlCapacity.proviumUsizeBits)
    (hc : cap < 2^JarlCapacity.proviumUsizeBits)
    (within : len ≤ cap)
    (available : JarlCapacity.state_State_full
      [.uint JarlCapacity.proviumUsizeBits len, .uint JarlCapacity.proviumUsizeBits cap] =
      .ok (.boolean false)) : len < cap := by
  rw [full_exact len cap hl hc] at available
  simp at available
  omega

end Capacity
