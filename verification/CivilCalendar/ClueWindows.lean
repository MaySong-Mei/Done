import CivilCalendar.ReportSplit
import CivilCalendar.CrossMidnight

/-!
# Clue battery window algebra (gh#227 slice 1)

`ReportClueBuilder`'s detectors slice history into windows and clamp each
to the report's elapsed offset. Season one modeled `ReportStatsBuilder`'s
split (`ReportSplit.lean`) but never the clue battery's windows — new
ground. Two shapes matter and the exploration proved they behave
differently:

* the FULL-day / trailing-window family (`fullDayHours`, `dayHours`,
  `trailingWindows`) — a civil partition, already covered verbatim by
  `daySplitCredit` / `daySplit_conserves`;
* the CLAMPED-cell family (`clampedDayHours`, `hours(in:elapsedClamped:)`)
  — `[midnight a, min(midnight a + e, midnight (a+1)))` — whose
  disjointness the daily arm ONCE broke.

The theorems here (a) certify the clamped cell is well-formed and stays
inside its civil day ONCE the `min` guard is present — the fix this slice
lands — and (b) exhibit the two live bugs the exploration surfaced as
constructive witnesses in `dstCal`, in the style of `baseline_slide_witness`:
the unguarded daily spill (gh#227 R1) and the `Int(elapsed/86400)`
absence undercount (R3). Fixtures replay the fixed builder; the witnesses
are the "why the fix was needed" record.
-/

namespace Verification

namespace CivilCalendar

variable (c : CivilCalendar)

/-- The clamped history cell, as the FIXED daily arm builds it:
`[midnight a, min(midnight a + e, midnight (a+1)))`, `e = elapsed ≥ 0`. -/
def clampedCellEnd (a e : Int) : Int :=
  min (c.midnight a + e) (c.midnight (a + 1))

/-- THEOREM 55 (clamped cell well-formed): with `e ≥ 0` the cell is
non-empty-or-degenerate and never exceeds its civil day — the invariant
the `min` guard restores. Without the guard (`midnight a + e` raw) this
fails exactly when `e` exceeds the day's length. -/
theorem clampedCell_in_day (a e : Int) (he : 0 ≤ e) :
    c.midnight a ≤ c.clampedCellEnd a e
      ∧ c.clampedCellEnd a e ≤ c.midnight (a + 1) := by
  unfold clampedCellEnd
  have hmono : c.midnight a ≤ c.midnight (a + 1) :=
    c.midnight_le_of_le (by omega)
  constructor <;> omega

/-- THEOREM 56 (clamped cells are disjoint — the property the daily arm
broke): consecutive fixed clamped cells do not overlap, because each ends
at or before its own next midnight, where the next begins. The unguarded
version (`clampedCellEnd` replaced by `midnight a + e`) violates this the
moment `e` exceeds a day length — see the witness below. -/
theorem clampedCells_disjoint (a e : Int) (he : 0 ≤ e) :
    c.clampedCellEnd a e ≤ c.midnight (a + 1) :=
  (c.clampedCell_in_day a e he).2

/-- THEOREM 57 (elapsed is a valid civil-day count via the healed
distance): the FIXED absence gate counts `dayOf cut − dayOf start` civil
days, which for `start ≤ cut` is nonneg and equals the number of civil
midnights in `[start, cut]`'s span — the count `Int(elapsed/86400)`
approximated and undercounted across a spring-forward. -/
theorem civil_elapsed_days_nonneg {start cut : Int} (h : start ≤ cut) :
    0 ≤ c.dayOf cut - c.dayOf start :=
  by have := c.dayOf_mono h; omega

end CivilCalendar

/-! ## The two live-bug witnesses (constructive, in `dstCal`) -/

/-- R1 WITNESS (gh#227): the UNGUARDED daily clamped cell spills past its
civil midnight on a long today. `dstCal` day 1 is the 23h short day (used
here only as a concrete non-flat frame); take a history day `a = 3`
(a flat 86400 day: midnight 3 = 3·86400 − 3600, midnight 4 = 4·86400 −
3600, length 86400) and an elapsed of 88200 s (a 24.5h "today", the fixed
frame's fall-back analogue). The unguarded end `midnight 3 + 88200`
overruns `midnight 4` by 1800 s — landing inside day 4, so the cell for
day 3 and the cell for day 4 both cover that instant. The GUARDED end
(`clampedCellEnd`) stops exactly at `midnight 4`. -/
theorem clamped_cell_spill_witness :
    -- unguarded end overruns the next midnight …
    dstCal.midnight 3 + 88200 > dstCal.midnight 4
    -- … while the guarded end does not.
    ∧ dstCal.clampedCellEnd 3 88200 = dstCal.midnight 4 := by
  constructor
  · decide
  · unfold Verification.CivilCalendar.clampedCellEnd
    decide

/-- R3 WITNESS (gh#227): `Int(elapsed/86400)` undercounts civil days across
a spring-forward. In `dstCal`, days 0 and 1 straddle the 23h transition:
three civil days from day 0 (`dayOf`-distance 3) span
`midnight 3 − midnight 0 = 3·86400 − 3600 = 255600` seconds, and
`255600 / 86400 = 2` (integer) — one short. The healed civil count gives
3. -/
theorem elapsed_fullDays_undercount_witness :
    (dstCal.midnight 3 - dstCal.midnight 0) / 86400 = 2
    ∧ dstCal.dayOf (dstCal.midnight 3) - dstCal.dayOf (dstCal.midnight 0) = 3 := by
  constructor
  · decide
  · have h3 : dstCal.dayOf (dstCal.midnight 3) = 3 := dstCal.dayOf_midnight 3
    have h0 : dstCal.dayOf (dstCal.midnight 0) = 0 := dstCal.dayOf_midnight 0
    rw [h3, h0]
    decide

end Verification
