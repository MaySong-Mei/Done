import CivilCalendar.Basic

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
  kind : String            -- "endOfDay" | "allDayCivilEnd" | "healedEnd"
  args : List Int          -- endOfDay: [t]; allDayCivilEnd: [anchor, raw]; healedEnd: [s, e]
  expectedModel : Option Int
  expectedFoundation : Option Int
  diverges : Bool

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

/-- America/Los_Angeles, 2026-03-05 … 03-12 (spring-forward Mar 8, 23h). -/
def laSpringTable : Array Int :=
  #[1772697600, 1772784000, 1772870400, 1772956800,
    1773039600, 1773126000, 1773212400, 1773298800]

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

/-- The midnight-less-day frame. Three pinned divergences (host-Foundation
probe, macOS 2026-09-03) — see README "Foundation fidelity". -/
def santiagoCases : ZoneCases :=
  let z := "America/Santiago"
  let c := tableCal santiagoTable
  { zone := z, table := santiagoTable, cases := [
    mk z c "santiago: endOfDay day before the gap agrees" "endOfDay" [1788624000],
    mk z c "santiago DIVERGENCE: endOfDay on the midnight-less day overshoots 1h"
      "endOfDay" [1788706800] (foundation? := some (some 1788753599)),
    mk z c "santiago DIVERGENCE: 1-day mint on the midnight-less day straddles"
      "allDayCivilEnd" [1788667200, 86399] (foundation? := some (some 1788753599)),
    mk z c "santiago DIVERGENCE: model heals the minted straddle, Foundation's dateComponents gap of a 23h day is 0 so it does not fire"
      "healedEnd" [1788667200, 1788753599] (foundation? := some none)
  ] }

def allZoneCases : List ZoneCases :=
  [laSpringCases, laFallCases, lordHoweCases, phoenixCases, santiagoCases]

end Verification
