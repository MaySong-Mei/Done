import CivilCalendar.ReportSplit
import CivilCalendar.MonthYear

/-!
# Cross-midnight membership and segment conservation (gh#224 slice 2)

The #53/#55 family's arithmetic, finally under theorems. The app never
physically splits a range: day-column MEMBERSHIP is the half-open civil
test (`range.end > dayStart && range.start < dayEnd`,
`CalendarLayout.swift:213/:548`, `EventStore.swift:58`), each member day
caches the FULL range, and clipping happens only at render time. The
model therefore states (1) the membership characterization, (2) segment
conservation in civil space — as an INSTANCE of `ReportSplit`'s pointwise
partition machinery, not a new sweep — (3) the all-day mint's membership,
and (4) the extension-window coverage bound, the canvas twin of the
gh#209 probe span.

Slice house-keeping recorded here: the four dead geometry decoys this
model replaces (`clippedDuration`, `yOffset`, `eventHeight`,
`timeFromYOffset` — zero call sites, semantics diverging from the live
path) are DELETED in this slice per the gh#206 precedent; the civil-clip
semantics they gestured at lives in `credit_interval` below, proved
rather than stranded.
-/

namespace Verification

namespace CivilCalendar

variable (c : CivilCalendar)

/-- The live half-open day-membership test. -/
def MemberDay (s e n : Int) : Prop :=
  c.midnight n < e ∧ s < c.midnight (n + 1)

instance (s e n : Int) : Decidable (c.MemberDay s e n) := by
  unfold MemberDay; infer_instance

/-- THEOREM 42 (membership characterization): the member days of ANY range
are exactly the integer interval `[dayOf s, dayOf (e−1)]` — for every
range shape, including the degenerate ones: an interior zero-length range
belongs to exactly its containing day, one anchored ON a midnight belongs
to nowhere (`dayOf (s−1) = dayOf s − 1` empties the interval), and a range
ending exactly at a midnight stops at the earlier day (the strict `>`). -/
theorem memberDay_iff (s e n : Int) :
    c.MemberDay s e n ↔ (c.dayOf s ≤ n ∧ n ≤ c.dayOf (e - 1)) := by
  unfold MemberDay
  constructor
  · rintro ⟨h1, h2⟩
    constructor
    · exact c.dayOf_le_of_lt_midnight h2
    · exact c.le_dayOf_of_midnight_le (by omega)
  · rintro ⟨h1, h2⟩
    constructor
    · have := c.midnight_le_of_le h2
      have hlo := c.dayOf_lo (e - 1)
      omega
    · have := c.midnight_le_of_le (show c.dayOf s + 1 ≤ n + 1 by omega)
      have hhi := c.dayOf_hi s
      omega

/-- Pointwise interval evaluation of the reusable credit machinery: the
unit-weight credit of `[s, e)` over `[lo, lo+n)` is the overlap length.
This IS the civil per-day segment length when instantiated on a day
window — the semantics the deleted `clippedDuration` gestured at. -/
theorem credit_interval (s e : Int) (k : Int → Nat) :
    ∀ (n : Nat) (lo : Int),
      credit (fun t => decide (s ≤ t) && decide (t < e)) k (fun _ => 1) lo n
        = max 0 (min e (lo + n) - max s lo) := by
  intro n
  induction n with
  | zero =>
    intro lo
    simp [credit]
    omega
  | succ m ih =>
    intro lo
    have hstep : credit (fun t => decide (s ≤ t) && decide (t < e)) k
        (fun _ => 1) lo (m + 1)
        = (if (decide (s ≤ lo) && decide (lo < e)) = true then (1 : Int)
           else 0)
          + credit (fun t => decide (s ≤ t) && decide (t < e)) k
              (fun _ => 1) (lo + 1) m := rfl
    by_cases hp : s ≤ lo ∧ lo < e
    · have hcond : (decide (s ≤ lo) && decide (lo < e)) = true := by
        simp only [Bool.and_eq_true, decide_eq_true_eq]
        exact hp
      rw [hstep, ih (lo + 1), if_pos hcond]
      omega
    · have hcond : ¬ ((decide (s ≤ lo) && decide (lo < e)) = true) := by
        simp only [Bool.and_eq_true, decide_eq_true_eq]
        exact hp
      rw [hstep, ih (lo + 1), if_neg hcond]
      omega

/-- THEOREM 43 (segment conservation — the #53/#55 family's missing law):
splitting a range at civil midnights loses and duplicates nothing — the
per-day civil segments of `[s, e)` sum to exactly `e − s`, for EVERY
day-length history. An instance of `daySplit_conserves`; no new sweep. -/
theorem interval_daySplit_conserves (s e : Int) (k : Int → Nat)
    (a : Int) (m : Nat)
    (h1 : c.midnight a ≤ s) (hse : s ≤ e)
    (h2 : e ≤ c.midnight (a + m)) :
    daySplitCredit c (fun t => decide (s ≤ t) && decide (t < e)) k
        (fun _ => 1) a m
      = e - s := by
  rw [daySplit_conserves]
  have hspan : c.midnight a ≤ c.midnight (a + m) :=
    c.midnight_le_of_le (by omega)
  rw [credit_interval]
  have hcast : c.midnight a
      + ((c.midnight (a + m) - c.midnight a).toNat : Int)
      = c.midnight (a + m) := by omega
  rw [hcast]
  omega

/-- THEOREM 44 (all-day mint membership): a range minted by
`allDayCivilEnd` — `[midnight D, midnight (D + dc) − 1]`, rendered
half-open as `[start, end + 1)` — is a member of exactly its `dc` anchor
days, connecting the strip's membership to the mint's day count. -/
theorem allday_mint_memberDays (D dc n : Int) (hdc : 1 ≤ dc) :
    c.MemberDay (c.midnight D) (c.midnight (D + dc) - 1 + 1) n
      ↔ (D ≤ n ∧ n ≤ D + dc - 1) := by
  rw [memberDay_iff]
  have h1 : c.dayOf (c.midnight D) = D := c.dayOf_midnight D
  have h2 : c.dayOf (c.midnight (D + dc) - 1 + 1 - 1) = D + dc - 1 := by
    have : c.midnight (D + dc) - 1 + 1 - 1 = c.midnight (D + dc) - 1 := by
      omega
    rw [this, c.dayOf_midnight_sub_one]
  rw [h1, h2]

/-- THEOREM 45 (extension-window coverage — the canvas twin of the gh#209
probe span): the boundary-extended window
`[midnight n − L, midnight n + 86400 + T)` with bands of at most 12 h
reaches only into the adjacent civil days, so the candidate offsets
`{n−1, n, n+1}` (`timelineCandidateDayOffsets`) contain the membership day
of every instant the window shows — no block the extension can display
lives outside the three pulled caches. Premises: 23 h civil days minimum,
and the trailing reach `86400 + T` bounded by two minimum days. -/
theorem extension_candidates_cover (hmin : c.toCalFns.MinDayLen 82800)
    {n L T t : Int}
    (hL : 0 ≤ L) (hL12 : L ≤ 43200) (hT : 0 ≤ T) (hT12 : T ≤ 43200)
    (hlo : c.midnight n - L ≤ t) (hhi : t < c.midnight n + 86400 + T) :
    n - 1 ≤ c.dayOf t ∧ c.dayOf t ≤ n + 1 := by
  have hm1 := hmin (n - 1)
  have hm2 := hmin n
  have hm3 := hmin (n + 1)
  have e1 : n - 1 + 1 = n := by omega
  rw [e1] at hm1
  constructor
  · exact c.le_dayOf_of_midnight_le (by omega)
  · exact c.dayOf_le_of_lt_midnight (by omega)

end CivilCalendar

end Verification
