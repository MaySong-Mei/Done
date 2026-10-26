import Telemetry

/-!
Telemetry fixture generator: `lake exe telemetryfixturegen`, run from
`verification/` (the file is written into the working directory; the
generator refuses to run anywhere `lakefile.toml` is not present), writes
`telemetry-fixtures.json` — one row per case in
`Telemetry/Fixtures.lean`, every `expected` evaluated by the definitions of
`Telemetry/Basic.lean` (the ones `Telemetry/Theorems.lean` is proved about),
never by hand. The Swift replay is `DoneTests/LeanTelemetryReplayTests.swift`;
the field contract is in `verification/README.md` (Telemetry section).
-/

open Verification.Telemetry.Fixtures

def ops : List String :=
  ["cursor.acknowledge", "cursor.pending", "server.apply", "server.fold",
   "consent.filter", "claim.adopts", "batch.select"]

def main : IO Unit := do
  unless (← System.FilePath.pathExists "lakefile.toml") do
    throw <| IO.userError
      "telemetryfixturegen: run from verification/ — lakefile.toml not found in the working directory"
  let cases := allCases
  -- every case must use a known op and a unique label
  for c in cases do
    unless ops.contains c.op do
      throw <| IO.userError s!"fixture {c.label}: unknown op {c.op}"
  let labels := cases.map (·.label)
  for l in labels do
    unless (labels.filter (· = l)).length = 1 do
      throw <| IO.userError s!"duplicate fixture label: {l}"
  let body := String.intercalate ",\n  " (cases.map (·.json))
  IO.FS.writeFile "telemetry-fixtures.json" ("[\n  " ++ body ++ "\n]\n")
  let perOp := ops.map fun o => (o, (cases.filter (·.op = o)).length)
  let cwd ← IO.currentDir
  IO.println s!"wrote {cases.length} telemetry fixtures to {cwd / "telemetry-fixtures.json"}, by op {perOp}"
