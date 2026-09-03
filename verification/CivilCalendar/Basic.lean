/-!
# Civil-calendar model — the arithmetic core and its laws

Model of the Swift civil-calendar functions on `Event` (king branch,
`Done/Models/Event.swift`): `endOfDay(for:calendar:)`,
`allDayCivilEnd(anchoredAt:rawDuration:calendar:)`,
`legacyAllDayStraddleHealedEnd(start:end:calendar:)`.

A calendar frame is its sequence of civil-day start instants (`midnight`),
one per day index, in absolute seconds. Day LENGTHS are left free: 23h/25h
DST days, Lord Howe's 30-minute shift, and Santiago's 01:00-anchored short
day are all instances — theorems quantify over every such history, which is
strictly stronger than any fixture set.

`CalFns` carries the executable definitions with no laws — concrete tzdata
tables instantiate it for fixture generation. `CivilCalendar` extends it
with the laws the theorems need. Every ported function is defined once, on
`CalFns`, so the proved artifact and the evaluated artifact cannot drift.
-/

namespace Verification

/-- The law-free arithmetic core of a calendar frame. -/
structure CalFns where
  /-- Start instant (absolute seconds) of civil day `n`. -/
  midnight : Int → Int
  /-- Day index containing instant `t`. -/
  dayOf : Int → Int

namespace CalFns

/-- Model of `Calendar.startOfDay(for:)`. -/
def startOfDay (c : CalFns) (t : Int) : Int := c.midnight (c.dayOf t)

/-- Port of `Event.endOfDay(for:calendar:)`: start of the instant's day, one
civil day forward, minus one second. The Swift body's
`date(byAdding: .day, 1, to: dayStart)` is modeled as the NEXT day start;
see README "Foundation fidelity" for the one live-zone family where that
assumption measurably breaks (midnight-less days — America/Santiago) and
which fixtures pin the divergence. -/
def endOfDay (c : CalFns) (t : Int) : Int := c.midnight (c.dayOf t + 1) - 1

/-- Swift `((x : Double) / 86_400).rounded()` for nonnegative `x`, as exact
integer arithmetic: `.rounded()` is round-half-away-from-zero, which on
nonnegatives is round-half-up, i.e. `⌊(2a + b) / 2b⌋`. Exact for every
magnitude the app stores (Double is integer-exact there and ties land on
representable halves). -/
def roundHalfUpDiv (a b : Int) : Int := (2 * a + b) / (2 * b)

/-- Port of `Event.allDayCivilEnd(anchoredAt:rawDuration:calendar:)`. -/
def allDayCivilEnd (c : CalFns) (dayStart rawDuration : Int) : Int :=
  let dayCount := max 1 (roundHalfUpDiv (rawDuration + 1) 86400)
  let lastDay := c.midnight (c.dayOf dayStart + (dayCount - 1))
  c.endOfDay lastDay

/-- The gh#207 straddle signature — the guard chain of
`legacyAllDayStraddleHealedEnd` collapsed to one conjunction (guard ORDER
does not affect the value, only which guard exits first). `dayGap` is
modeled as civil-day-index distance; Foundation's `dateComponents([.day])`
between two day-start instants agrees except on midnight-less-day frames
(pinned by the Santiago fixtures). -/
def IsStraddle (c : CalFns) (s e : Int) : Prop :=
  0 < e - c.startOfDay e ∧
  e - c.startOfDay e ≤ 3600 ∧
  s = c.startOfDay s ∧
  1 ≤ c.dayOf e - c.dayOf s ∧
  e + 1 - s = (c.dayOf e - c.dayOf s) * 86400

instance (c : CalFns) (s e : Int) : Decidable (c.IsStraddle s e) := by
  unfold IsStraddle; infer_instance

/-- Port of `Event.legacyAllDayStraddleHealedEnd(start:end:calendar:)`. -/
def healedEnd (c : CalFns) (s e : Int) : Option Int :=
  if c.IsStraddle s e then some (c.midnight (c.dayOf e) - 1) else none

/-- Day-length lower bound: every civil day is at least `m` seconds long.
Real calendars satisfy `m = 82800` (23 hours); each theorem states the
bound it actually needs. -/
def MinDayLen (c : CalFns) (m : Int) : Prop :=
  ∀ n, m ≤ c.midnight (n + 1) - c.midnight n

end CalFns

/-- A lawful calendar frame: day starts strictly increase, and `dayOf` is
the lookup they induce. -/
structure CivilCalendar extends CalFns where
  mono : ∀ ⦃a b : Int⦄, a < b → midnight a < midnight b
  dayOf_lo : ∀ t, midnight (dayOf t) ≤ t
  dayOf_hi : ∀ t, t < midnight (dayOf t + 1)

namespace CivilCalendar

variable (c : CivilCalendar)

theorem midnight_le_of_le {a b : Int} (h : a ≤ b) :
    c.midnight a ≤ c.midnight b := by
  by_cases heq : a = b
  · subst heq; omega
  · have hlt : a < b := by omega
    have := c.mono hlt
    omega

theorem le_of_midnight_le {a b : Int} (h : c.midnight a ≤ c.midnight b) :
    a ≤ b := by
  by_cases hab : a ≤ b
  · exact hab
  · have hlt : b < a := by omega
    have := c.mono hlt
    omega

/-- `dayOf` inverts `midnight`. -/
theorem dayOf_midnight (n : Int) : c.dayOf (c.midnight n) = n := by
  have lo := c.dayOf_lo (c.midnight n)
  have hi := c.dayOf_hi (c.midnight n)
  have h1 : c.dayOf (c.midnight n) ≤ n := c.le_of_midnight_le lo
  have h2 : n ≤ c.dayOf (c.midnight n) := by
    by_cases hn : n ≤ c.dayOf (c.midnight n)
    · exact hn
    · have hle : c.dayOf (c.midnight n) + 1 ≤ n := by omega
      have := c.midnight_le_of_le hle
      omega
  omega

/-- Any instant sandwiched by day `n`'s bounds is on day `n`. -/
theorem dayOf_eq {n t : Int} (h1 : c.midnight n ≤ t)
    (h2 : t < c.midnight (n + 1)) : c.dayOf t = n := by
  have lo := c.dayOf_lo t
  have hi := c.dayOf_hi t
  have ha : c.dayOf t ≤ n := by
    by_cases hc : c.dayOf t ≤ n
    · exact hc
    · have hle : n + 1 ≤ c.dayOf t := by omega
      have := c.midnight_le_of_le hle
      omega
  have hb : n ≤ c.dayOf t := by
    by_cases hc : n ≤ c.dayOf t
    · exact hc
    · have hle : c.dayOf t + 1 ≤ n := by omega
      have := c.midnight_le_of_le hle
      omega
  omega

/-- The instant one second before a day start belongs to the previous day. -/
theorem dayOf_midnight_sub_one (k : Int) :
    c.dayOf (c.midnight k - 1) = k - 1 := by
  have hmono := c.mono (show k - 1 < k by omega)
  have h1 : c.midnight (k - 1) ≤ c.midnight k - 1 := by omega
  have h2 : c.midnight k - 1 < c.midnight (k - 1 + 1) := by
    have : k - 1 + 1 = k := by omega
    rw [this]; omega
  exact c.dayOf_eq h1 h2

end CivilCalendar

end Verification
