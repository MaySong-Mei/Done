import CivilCalendar.Basic
import CivilCalendar.Recurrence

/-!
# Differential fixtures — the model ↔ Foundation seam

Concrete calendar frames built from REAL tzdata midnight tables (source:
python `zoneinfo` over the system tzdata — a third implementation,
independent of both this model and Foundation). The generator evaluates the
SAME `CalFns` definitions the theorems are proved about, and emits absolute
epoch expectations for the Swift replay test
(`DoneTests/LeanCivilCalendarReplayTests.swift`) to run against the real
`Event` functions.

Where Foundation measurably diverges from the model, the fixture carries
BOTH values (`expectedFoundation` pinned from a host-Foundation probe,
2026-09-03) and `diverges: true` — the replay asserts Foundation's actual
behavior so any Foundation/tzdata change surfaces loudly, and the README
documents the divergence as a finding, not an accepted equivalence.
-/

namespace Verification

/-- A finite civil-day table anchored at absolute epoch day starts. Correct
only inside the table window; `Main` asserts every fixture stays inside. -/
def tableCal (table : Array Int) : CalFns where
  midnight n :=
    if 0 ≤ n ∧ n < (table.size : Int) then table[n.toNat]!
    else panic! "tableCal: day index out of window"
  dayOf t :=
    (table.foldl (fun acc m => if m ≤ t then acc + 1 else acc) 0) - 1

structure Fixture where
  zone : String
  label : String
  kind : String
  -- endOfDay: [t]; allDayCivilEnd: [anchor, raw]; healedEnd: [s, e];
  -- recurrenceOccurrence:
  --   [unit(1=day,2=week), interval, seriesStart, raw, isAllDay(0/1),
  --    endType(0=none,1=onDate,2=afterCount), endValue, suppressProbe(0/1),
  --    probeInstant]
  args : List Int
  expectedModel : Option Int
  expectedFoundation : Option Int
  diverges : Bool
  -- second expectation channel: the minted occurrence END (recurrence only)
  expected2Model : Option Int := none
  expected2Foundation : Option Int := none

structure ZoneCases where
  zone : String
  table : Array Int
  cases : List Fixture

private def optJson : Option Int → String
  | none => "null"
  | some v => toString v

def Fixture.json (f : Fixture) : String :=
  "{\"zone\":\"" ++ f.zone ++ "\",\"label\":\"" ++ f.label
    ++ "\",\"kind\":\"" ++ f.kind
    ++ "\",\"args\":[" ++ String.intercalate "," (f.args.map toString)
    ++ "],\"expectedModel\":" ++ optJson f.expectedModel
    ++ ",\"expectedFoundation\":" ++ optJson f.expectedFoundation
    ++ ",\"expected2Model\":" ++ optJson f.expected2Model
    ++ ",\"expected2Foundation\":" ++ optJson f.expected2Foundation
    ++ ",\"diverges\":" ++ (if f.diverges then "true" else "false") ++ "}"

/-- Build one fixture; `foundation?` overrides the Foundation expectation
only for pinned divergences. -/
private def mk (zone : String) (cal : CalFns) (label kind : String)
    (args : List Int) (foundation? : Option (Option Int) := none) : Fixture :=
  let model : Option Int :=
    match kind, args with
    | "endOfDay", [t] => some (cal.endOfDay t)
    | "allDayCivilEnd", [a, raw] => some (cal.allDayCivilEnd a raw)
    | "healedEnd", [s, e] => cal.healedEnd s e
    | _, _ => panic! s!"fixture {label}: bad kind/args"
  let foundation := foundation?.getD model
  { zone, label, kind, args
    expectedModel := model
    expectedFoundation := foundation
    diverges := foundation ≠ model }

-- Midnight tables (epoch seconds), 8 consecutive civil-day starts each.

/-- America/Los_Angeles, 2026-03-04 … 03-14 (spring-forward Mar 8, 23h). -/
def laSpringTable : Array Int :=
  #[1772611200, 1772697600, 1772784000, 1772870400, 1772956800,
    1773039600, 1773126000, 1773212400, 1773298800, 1773385200,
    1773471600]

/-- America/Los_Angeles, 2026-10-29 … 11-05 (fall-back Nov 1, 25h). -/
def laFallTable : Array Int :=
  #[1793257200, 1793343600, 1793430000, 1793516400,
    1793606400, 1793692800, 1793779200, 1793865600]

/-- Australia/Lord_Howe, 2026-10-01 … 10-08 (spring-forward Oct 4, 23.5h). -/
def lordHoweTable : Array Int :=
  #[1790775000, 1790861400, 1790947800, 1791034200,
    1791118800, 1791205200, 1791291600, 1791378000]

/-- America/Phoenix, 2026-03-05 … 03-12 (no DST, all 24h). -/
def phoenixTable : Array Int :=
  #[1772694000, 1772780400, 1772866800, 1772953200,
    1773039600, 1773126000, 1773212400, 1773298800]

/-- America/Santiago, 2026-09-03 … 09-10 (spring-forward AT midnight:
civil Sep 6 starts at local 01:00 and runs 23h — the midnight-less day). -/
def santiagoTable : Array Int :=
  #[1788408000, 1788494400, 1788580800, 1788667200,
    1788750000, 1788836400, 1788922800, 1789009200]

def laSpringCases : ZoneCases :=
  let z := "America/Los_Angeles"
  let c := tableCal laSpringTable
  { zone := z, table := laSpringTable, cases := [
    mk z c "spring: endOfDay, day before transition" "endOfDay" [1772913600],
    mk z c "spring: endOfDay on the 23h day" "endOfDay" [1773000000],
    mk z c "spring: 1-day mint anchored on the 23h day (gh#188 marquee)"
      "allDayCivilEnd" [1772956800, 86399],
    mk z c "spring: 2-day span minted in this frame (169200s) re-anchors to 2 days"
      "allDayCivilEnd" [1772870400, 169199],
    mk z c "spring: 2-day span minted FLAT (172800s), drift absorbed"
      "allDayCivilEnd" [1772870400, 172799],
    mk z c "spring: 1-day legacy straddle heals to the picked day"
      "healedEnd" [1772956800, 1773043199],
    mk z c "spring: 2-day legacy straddle heals to the picked day"
      "healedEnd" [1772870400, 1773043199],
    mk z c "spring: normalized healthy row is not healed"
      "healedEnd" [1772956800, 1773039599],
    mk z c "spring: off-midnight start is not healed"
      "healedEnd" [1772960400, 1773043199]
  ] }

def laFallCases : ZoneCases :=
  let z := "America/Los_Angeles"
  let c := tableCal laFallTable
  { zone := z, table := laFallTable, cases := [
    mk z c "fall: endOfDay on the 25h day" "endOfDay" [1793559600],
    mk z c "fall: 1-day mint covers the whole 25h day"
      "allDayCivilEnd" [1793516400, 86399],
    mk z c "fall: 2-day span minted in this frame (180000s) re-anchors to 2 days"
      "allDayCivilEnd" [1793430000, 179999],
    mk z c "fall: legacy shape never straddles on a long day"
      "healedEnd" [1793516400, 1793602799]
  ] }

def lordHoweCases : ZoneCases :=
  let z := "Australia/Lord_Howe"
  let c := tableCal lordHoweTable
  { zone := z, table := lordHoweTable, cases := [
    mk z c "lord howe: endOfDay on the 23.5h day" "endOfDay" [1791077400],
    mk z c "lord howe: 1-day mint on the 23.5h day"
      "allDayCivilEnd" [1791034200, 86399],
    mk z c "lord howe: 30-minute legacy straddle heals"
      "healedEnd" [1791034200, 1791120599],
    mk z c "lord howe: 2-day span minted here (171000s) re-anchors to 2 days"
      "allDayCivilEnd" [1790947800, 170999]
  ] }

def phoenixCases : ZoneCases :=
  let z := "America/Phoenix"
  let c := tableCal phoenixTable
  { zone := z, table := phoenixTable, cases := [
    mk z c "flat: endOfDay" "endOfDay" [1772996400],
    mk z c "flat: 3-day mint" "allDayCivilEnd" [1772780400, 259199],
    mk z c "flat: half-day tie (129600s) rounds up to 2 days"
      "allDayCivilEnd" [1772780400, 129599],
    mk z c "flat: legacy shape never straddles" "healedEnd" [1772953200, 1773039599]
  ] }

/-- The midnight-less-day frame. The endOfDay/allDayCivilEnd divergences
this file once pinned were healed by gh#221 (re-normalize the +1-day hop
through `startOfDay`); those two cases now assert agreement and stand as
the regression guard. One pin remains — the heal's `dateComponents` day
gap — see README "Foundation fidelity". -/
def santiagoCases : ZoneCases :=
  let z := "America/Santiago"
  let c := tableCal santiagoTable
  { zone := z, table := santiagoTable, cases := [
    mk z c "santiago: endOfDay day before the gap agrees" "endOfDay" [1788624000],
    mk z c "santiago: endOfDay on the midnight-less day ends at the true civil end (gh#221)"
      "endOfDay" [1788706800],
    mk z c "santiago: 1-day mint on the midnight-less day no longer straddles (gh#221)"
      "allDayCivilEnd" [1788667200, 86399],
    mk z c "santiago DIVERGENCE: model heals the legacy straddle shape, Foundation's dateComponents gap of a 23h day is 0 so it does not fire"
      "healedEnd" [1788667200, 1788753599] (foundation? := some none)
  ] }

/-- America/Nuuk, 2026-03-25 … 04-01 — the END-OF-DAY gap frame: DST jumps
at 23:00 local, so civil Mar 28 runs 23h and wall `[23:00, 24:00)` does not
exist on it. The frame where Foundation's component-combining mint ESCAPES
the anchor day (pinned below). -/
def nuukTable : Array Int :=
  #[1774404000, 1774490400, 1774576800, 1774663200,
    1774746000, 1774832400, 1774918800, 1775005200]

/-- Evaluate one `recurrenceOccurrence` fixture through the SAME
`SeriesModel`/`RecurArm` definitions the theorems are proved about, on a
table frame. The mint models time-of-day as the OFFSET from the day start;
fixture series times sit at 01:30 local, before every INTRA-day transition
in the probed frames, so offset, wall-clock and python agree — with two
recorded exceptions. The pinned divergence rows carry host-measured
`foundation?` overrides; and on the Santiago pin the anchor day itself
starts at 01:00, so the model channel's time-of-day is the OFFSET from
that start (1800 s), not wall 01:30 — unobservable in the replay because
Foundation rejects the match outright, recorded here so the value is not
mistaken for a wall-clock instant. -/
private def recurCase (zone : String) (cal : CalFns) (label : String)
    (unit interval seriesStart raw : Int) (isAllDay : Bool)
    (endType endValue : Int) (suppressProbe : Bool) (probe : Int)
    (foundationStart? : Option (Option Int) := none)
    (foundationEnd? : Option (Option Int) := none) : Fixture :=
  let seriesDay := cal.dayOf seriesStart
  let tod := seriesStart - cal.midnight seriesDay
  let probeDay := cal.dayOf probe
  let s : SeriesModel :=
    { seriesDay := seriesDay
      arm := if unit = 1 then .daily interval else .weekly interval
      suppressed := fun d => suppressProbe && d == probeDay
      endDay := if endType = 1 then some (cal.dayOf endValue) else none
      count := if endType = 2 then some endValue else none }
  let modelRange : Option (Int × Int) :=
    match s.matchIndex probeDay with
    | none => none
    | some _ =>
        let start := if isAllDay then cal.midnight probeDay
                     else cal.midnight probeDay + tod
        let stop := if isAllDay then cal.allDayCivilEnd (cal.midnight probeDay) raw
                    else start + raw
        some (start, stop)
  let mStart := modelRange.map (·.1)
  let mEnd := modelRange.map (·.2)
  let fStart := foundationStart?.getD mStart
  let fEnd := foundationEnd?.getD mEnd
  { zone, label, kind := "recurrenceOccurrence"
    args := [unit, interval, seriesStart, raw, (if isAllDay then 1 else 0),
             endType, endValue, (if suppressProbe then 1 else 0), probe]
    expectedModel := mStart
    expectedFoundation := fStart
    diverges := fStart ≠ mStart ∨ fEnd ≠ mEnd
    expected2Model := mEnd
    expected2Foundation := fEnd }

/-- Recurrence expansion — agreement cases plus the three fidelity pins the
slice-1 calibration measured (2026-09-04 host probes). -/
def recurrenceCases : List ZoneCases :=
  let la := tableCal laSpringTable
  let lh := tableCal lordHoweTable
  let scl := tableCal santiagoTable
  let nk := tableCal nuukTable
  [ { zone := "America/Los_Angeles", table := laSpringTable, cases := [
      recurCase "America/Los_Angeles" la
        "recur: daily k=1 at 01:30 lands on the 23h day"
        1 1 1772789400 3600 false 0 0 false 1773000000,
      recurCase "America/Los_Angeles" la
        "recur: daily k=3 from Mar 5 matches Mar 8"
        1 3 1772703000 3600 false 0 0 false 1773000000,
      recurCase "America/Los_Angeles" la
        "recur: daily k=3 from Mar 5 skips Mar 7"
        1 3 1772703000 3600 false 0 0 false 1772913600,
      recurCase "America/Los_Angeles" la
        "recur: weekly k=1 from Mar 5 matches Mar 12"
        2 1 1772703000 3600 false 0 0 false 1773342000,
      recurCase "America/Los_Angeles" la
        "recur: afterCount 3 admits index 2 on Mar 7"
        1 1 1772703000 3600 false 2 3 false 1772913600,
      recurCase "America/Los_Angeles" la
        "recur: afterCount 3 rejects index 3 on Mar 8"
        1 1 1772703000 3600 false 2 3 false 1773000000,
      recurCase "America/Los_Angeles" la
        "recur: endDate Mar 7 admits Mar 7"
        1 1 1772703000 3600 false 1 1772913600 false 1772913600,
      recurCase "America/Los_Angeles" la
        "recur: endDate Mar 7 rejects Mar 8"
        1 1 1772703000 3600 false 1 1772913600 false 1773000000,
      recurCase "America/Los_Angeles" la
        "recur: suppressed day (取消) matches nothing"
        1 1 1772703000 3600 false 0 0 true 1773000000,
      recurCase "America/Los_Angeles" la
        "recur: all-day daily on the 23h day ends at the civil day end"
        1 1 1772697600 86399 true 0 0 false 1773000000,
      recurCase "America/Los_Angeles" la
        "recur PIN: 02:30 series on the gap day — Foundation clamps the nonexistent time to 03:00, the offset model does not"
        1 1 1772879400 3600 false 0 0 false 1773000000
        (foundationStart? := some (some 1772964000))
        (foundationEnd? := some (some 1772967600))
    ] },
    { zone := "Australia/Lord_Howe", table := lordHoweTable, cases := [
      recurCase "Australia/Lord_Howe" lh
        "recur: daily k=1 at 01:30 lands on the 23.5h day"
        1 1 1790866800 3600 false 0 0 false 1791077400
    ] },
    { zone := "America/Santiago", table := santiagoTable, cases := [
      recurCase "America/Santiago" scl
        "recur: daily k=2 anchored on a TRUE midnight agrees across the gap"
        1 2 1788499800 3600 false 0 0 false 1788879600,
      recurCase "America/Santiago" scl
        "recur PIN: daily k=2 anchored ON the midnight-less day — Foundation's dateComponents undercounts the 23h day and rejects the parity match"
        1 2 1788669000 3600 false 0 0 false 1788879600
        (foundationStart? := some none)
        (foundationEnd? := some none)
    ] },
    { zone := "America/Nuuk", table := nuukTable, cases := [
      recurCase "America/Nuuk" nk
        "recur: daily k=1 at 01:30 crosses the end-of-day gap frame"
        1 1 1774495800 3600 false 0 0 false 1774700000,
      recurCase "America/Nuuk" nk
        "recur PIN: 23:30 series on the shortened day — Foundation's mint ESCAPES the anchor day onto Mar 29 23:30 (the prose premise violated)"
        1 1 1774575000 1800 false 0 0 false 1774700000
        (foundationStart? := some (some 1774830600))
        (foundationEnd? := some (some 1774832400))
    ] } ]

def allZoneCases : List ZoneCases :=
  [laSpringCases, laFallCases, lordHoweCases, phoenixCases, santiagoCases]
    ++ recurrenceCases

end Verification
