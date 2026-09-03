import CivilCalendar.Theorems

/-!
# The indistinguishability ceiling, as an existence proof

The Swift comment on `legacyAllDayStraddleHealedEnd` pins an accepted
false-positive class: a healthy row minted in a zone sharing the reading
zone's offset at the row's start, where only the reading zone springs
forward inside the span, "matches the full signature byte-for-byte; no
stored byte can distinguish it, so no predicate can."

That is an impossibility claim, and this file proves it: ONE byte pair —
start `0`, end `172 799` — is simultaneously

* a NORMALIZED healthy two-day row in `flatCal` (every day 86 400 s:
  the Phoenix side), where the heal correctly stays silent, and
* the FULL gh#207 straddle signature in `dstCal` (day 1 sprang forward
  an hour: the Denver side), where the heal fires and truncates it.

Since the stored bytes are literally the same and the two frames demand
opposite verdicts, no function of the bytes alone behaves correctly in
both frames — the accepted collateral is a mathematical ceiling, not a
missed refinement. `LegacyAllDayStraddleHealTests.
testEqualOffsetForeignFrameHealthyRowIsAcceptedCollateral` pins the same
fact against Foundation with real zones.
-/

namespace Verification

/-- Every day 86 400 s — the no-DST frame (Phoenix side). -/
def flatCal : CivilCalendar where
  midnight n := 86400 * n
  dayOf t := t / 86400
  mono := by intro a b h; omega
  dayOf_lo := by intro t; omega
  dayOf_hi := by intro t; omega

/-- Day 1 loses an hour to spring-forward: days 0 and 1 start on the flat
grid, every later day starts 3 600 s early (the Denver side). -/
def dstCal : CivilCalendar where
  midnight n := if n ≤ 1 then 86400 * n else 86400 * n - 3600
  dayOf t := if t < 169200 then t / 86400 else (t + 3600) / 86400
  mono := by
    intro a b h
    split <;> split <;> omega
  dayOf_lo := by
    intro t
    split <;> split <;> omega
  dayOf_hi := by
    intro t
    split <;> split <;> omega

/-- One byte pair, two lawful frames, opposite verdicts — and in the flat
frame the pair is exactly the normalized `endOfDay` shape, so THEOREM 4
already explains its silence. No predicate on the stored bytes can be
correct in both frames. -/
theorem indistinguishability_witness :
    flatCal.toCalFns.healedEnd 0 172799 = none ∧
    dstCal.toCalFns.healedEnd 0 172799 = some 169199 := by
  constructor <;> decide

end Verification
