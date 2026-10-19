import CivilCalendar.SyncRestore

/-!
Bounded exhaustive search over the server-restore / epoch model
(`CivilCalendar/SyncRestore.lean`, gh#257): `lake exe syncrestoresearch
[depth1] [depth2]`. For every rule variant it prints, per scenario family,
the number of distinct worlds settled and checked, how many violate the
property, and a shortest violating action sequence.
-/

open Verification.SyncRestore

def showAct : Act → String
  | .edit d r => s!"edit {if d == 0 then "A" else "B"} {if r == 0 then "X" else "Y"}"
  | .pull d => s!"pull {if d == 0 then "A" else "B"}"
  | .flush d => s!"flush {if d == 0 then "A" else "B"}"
  | .agent r => s!"agent {if r == 0 then "X" else "Y"}"
  | .dump b => if b then "dump" else "dump(no sync_epoch)"
  | .restore k => s!"restore.sh D{k}"
  | .bypass k => s!"bypass D{k}"
  | .abortSetval k => s!"abort-after-setval D{k}"
  | .standalone => "restore_with_epoch alone"
  | .rollback => "rollback"
  | .reenable => "reenable"

def families (d1 d2 : Nat) : List (String × Bounds) :=
  [ (s!"1 row, every operator action, prompt R3, depth {d1}, ops ≤ 4",
      { rows := 1, depth := d1, maxOps := 4, maxDumps := 2, prompt := true }),
    (s!"1 row, restore.sh only (no rollback, no off-script), depth {d1}, ops ≤ 4",
      { rows := 1, depth := d1, maxOps := 4, maxDumps := 2, prompt := true,
        offScript := false, rollbacks := false }),
    (s!"2 rows, every operator action, prompt R3, depth {d2}, ops ≤ 3",
      { rows := 2, depth := d2, maxOps := 3, maxDumps := 2, prompt := true }),
    (s!"1 row, window open after bypass / abort (residual), depth {d1}, ops ≤ 4",
      { rows := 1, depth := d1, maxOps := 4, maxDumps := 2, prompt := false }) ]

def rules : List Rules :=
  [current, x4, x5, localWins, recommended, altOvershoot, abJump, abNoLastSeq, abCounterFloor, abNoCarry,
   altRefuse, abNoStamp, altRestamp, devRemoteWins, devHybrid]

def main (args : List String) : IO Unit := do
  let d1 := (args.getD 0 "7").toNat!
  let d2 := (args.getD 1 "6").toNat!
  let onlyRule := args.getD 2 ""
  for R in rules do
    if onlyRule != "" && !(R.name.startsWith onlyRule) then continue
    IO.println s!"== {R.name}"
    for (fname, B) in families d1 d2 do
      let t0 ← IO.monoMsNow
      let st := search R B
      let t1 ← IO.monoMsNow
      IO.println s!"  {fname}: {st.states} worlds checked, {st.violations} violating ({t1 - t0} ms)"
      for (cls, n, tr, why) in st.byClass do
        IO.println s!"    {cls} x{n}, shortest: [{", ".intercalate (tr.map showAct)}] -> {why}"
