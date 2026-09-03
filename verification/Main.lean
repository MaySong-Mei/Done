import CivilCalendar

/-!
Fixture generator: `lake exe fixturegen` writes `fixtures.json` next to the
lakefile. Every case is window-checked against its zone table first — a
fixture whose instants could consult extrapolated (nonexistent) table
entries aborts the run rather than emitting a silently-wrong expectation.
-/

open Verification

/-- Every instant a case touches must sit strictly inside the table window:
day index within [1, size − 2], so `dayOf + 1` lookups stay real. -/
def checkWindow (g : ZoneCases) : IO Unit := do
  let cal := tableCal g.table
  let first := g.table[1]!
  let last := g.table[g.table.size - 1]!
  for f in g.cases do
    let instants := f.args.filter (· > 1000000000) -- durations are small; instants are epochs
      ++ (f.expectedModel.map ([·])).getD []
      ++ (f.expectedFoundation.map ([·])).getD []
    for t in instants do
      unless first ≤ t + 1 ∧ t < last do
        throw <| IO.userError s!"fixture out of window: {f.label} instant {t}"
      let d := cal.dayOf t
      unless 1 ≤ d ∧ d < (g.table.size : Int) - 1 do
        throw <| IO.userError s!"fixture day index out of window: {f.label} instant {t} day {d}"

def main : IO Unit := do
  for g in allZoneCases do
    checkWindow g
  let fixtures := (allZoneCases.map (·.cases)).flatten
  let body := String.intercalate ",\n  " (fixtures.map (·.json))
  IO.FS.writeFile "fixtures.json" ("[\n  " ++ body ++ "\n]\n")
  let divergent := fixtures.filter (·.diverges) |>.length
  IO.println s!"wrote {fixtures.length} fixtures ({divergent} pinned divergences)"
