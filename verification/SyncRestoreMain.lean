import CivilCalendar.SyncRestore

/-!
Bounded exhaustive search over the server-restore / epoch model
(`CivilCalendar/SyncRestore.lean`, gh#257): `lake exe syncrestoresearch
[depth1] [depth2] [rule-name prefix] [2-row max ops] [2-row max dumps]
[family number, 0 = all] [1-row max ops] [1-row max dumps]`. For every
rule variant it prints, per scenario family, the number of distinct worlds
settled and checked, how many violate the property, a shortest violating
action sequence per class, how many of the violations hand-restore a dump
taken without its `sync_epoch` row, and how many worlds have a live row
whose seq is in `lost` (the ops check P10).

The visited set holds a 64-bit hash of each canonical world rather than
the world (the model's own `search` keeps worlds and runs at build time;
`lake exe syncrestoresearch cross` compares the two at `buildBounds`).
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
  | .bypassNew k => s!"bypass-into-new-project D{k}"
  | .abortSetval k => s!"abort-after-setval D{k}"
  | .standalone => "restore_with_epoch alone"
  | .rollback => "rollback"
  | .reenable => "reenable"
  | .unpause => "unpause"

def showTr (tr : List Act) : String := s!"[{", ".intercalate (tr.map showAct)}]"

/-- the trace hand-restores (bypass, also into a new project) a dump taken
without its `sync_epoch` row -/
def noRowHandIn (tr : List Act) : Bool := Id.run do
  let mut dumps : Array Bool := #[]
  for a in tr do
    match a with
    | .dump b => dumps := dumps.push b
    | .bypass k | .bypassNew k => if !(dumps.getD k true) then return true
    | _ => pure ()
  return false

structure St where
  states : Nat := 0
  violations : Nat := 0
  byClass : List (String × Nat × List Act × String) := []
  /-- per class: violations whose trace hand-restores a dump without its row -/
  noRow : List (String × Nat) := []
  p10 : Nat := 0
  p10tr : Option (List Act) := none

def bump (l : List (String × Nat)) (k : String) : List (String × Nat) :=
  if l.any (·.1 == k) then l.map fun e => if e.1 == k then (e.1, e.2 + 1) else e else l ++ [(k, 1)]

/-- `tr` is newest first, as the search builds it -/
def St.record (st : St) (tr : List Act) (why : String) : St :=
  let cls := (why.splitOn " ").headD why
  let byClass :=
    if st.byClass.any (·.1 == cls) then
      st.byClass.map fun e => if e.1 == cls then (e.1, e.2.1 + 1, e.2.2) else e
    else st.byClass ++ [(cls, 1, tr.reverse, why)]
  let noRow := if noRowHandIn tr.reverse then bump st.noRow cls else st.noRow
  { st with violations := st.violations + 1, byClass, noRow }

def canonHash (w : World) : UInt64 :=
  let a := hash w
  let b := hash { w with devs := w.devs.reverse }
  if b < a then b else a

/-- The model's `search` (breadth-first, every distinct canonical world
settled and checked once), with a hash-keyed visited set. -/
def searchFast (R : Rules) (B : Bounds) : IO St := do
  let w0 := initWorld B.rows
  let mut seen : Std.HashSet UInt64 := Std.HashSet.emptyWithCapacity 1000000
  seen := seen.insert (canonHash w0)
  let visit := fun (st : St) (w : World) (tr : List Act) =>
    let st := { st with states := st.states + 1 }
    let st := match check R w with
      | some why => st.record tr why
      | none => st
    if liveInLost w then
      { st with p10 := st.p10 + 1, p10tr := st.p10tr.orElse fun _ => some tr.reverse }
    else st
  let mut st : St := visit {} w0 []
  let mut frontier : Array (World × List Act) := #[(w0, [])]
  for lvl in List.range B.depth do
    let mut next : Array (World × List Act) := #[]
    for (w, tr) in frontier do
      for a in enabled B w do
        let w' := step R B.prompt w a
        let k := canonHash w'
        if !seen.contains k then
          seen := seen.insert k
          st := visit st w' (a :: tr)
          if lvl + 1 < B.depth then next := next.push (w', a :: tr)
    frontier := next
  return st

def families (d1 d2 ops1 dumps1 ops2 dumps2 : Nat) : List (String × Bounds) :=
  [ (s!"1 row, every operator action (a hand restore only of a dump with its row), prompt R3, depth {d1}, ops ≤ {ops1}, dumps ≤ {dumps1}",
      { rows := 1, depth := d1, maxOps := ops1, maxDumps := dumps1, prompt := true, noRowHand := false }),
    (s!"1 row, restore.sh only (no rollback, no off-script), depth {d1}, ops ≤ {ops1}, dumps ≤ {dumps1}",
      { rows := 1, depth := d1, maxOps := ops1, maxDumps := dumps1, prompt := true,
        offScript := false, rollbacks := false }),
    (s!"2 rows, every operator action (a hand restore only of a dump with its row), prompt R3, depth {d2}, ops ≤ {ops2}, dumps ≤ {dumps2}",
      { rows := 2, depth := d2, maxOps := ops2, maxDumps := dumps2, prompt := true, noRowHand := false }),
    (s!"1 row, every operator action incl. a hand restore of a dump without its row (residual), prompt R3, depth {d1}, ops ≤ {ops1}, dumps ≤ {dumps1}",
      { rows := 1, depth := d1, maxOps := ops1, maxDumps := dumps1, prompt := true }),
    (s!"1 row, window open after bypass / abort (residual), depth {d1}, ops ≤ {ops1}, dumps ≤ {dumps1}",
      { rows := 1, depth := d1, maxOps := ops1, maxDumps := dumps1, prompt := false }) ]

def rules : List Rules :=
  [current, x4, x5, localWins, prior, recommended, altOvershoot, abJump, abNoLastSeq, abCounterFloor, abMaxRowsF,
   abCarry, abAcceptCarry, abAcceptBare, abNoStamp, altRestamp, abForgetSeq, abForgetLost, abNewBypassFresh,
   devRemoteWins, devHybrid]

def cross : IO Unit := do
  for R in [current, prior, recommended] do
    let a := search R buildBounds
    let b ← searchFast R buildBounds
    let ca := a.byClass.map fun e => (e.1, e.2.1)
    let cb := b.byClass.map fun e => (e.1, e.2.1)
    IO.println s!"{R.name}: exact {a.states} worlds {ca} p10 {a.p10}; hashed {b.states} worlds {cb} p10 {b.p10}; same {a.states == b.states && ca == cb && a.p10 == b.p10}"

def main (args : List String) : IO Unit := do
  if args.head? == some "cross" then cross; return
  let d1 := (args.getD 0 "8").toNat!
  let d2 := (args.getD 1 "7").toNat!
  let onlyRule := args.getD 2 ""
  let ops2 := (args.getD 3 "5").toNat!
  let dumps2 := (args.getD 4 "3").toNat!
  let onlyFamily := (args.getD 5 "0").toNat!
  let ops1 := (args.getD 6 "5").toNat!
  let dumps1 := (args.getD 7 "3").toNat!
  for R in rules do
    if onlyRule != "" && !(R.name.startsWith onlyRule) then continue
    IO.println s!"== {R.name}"
    let fams := families d1 d2 ops1 dumps1 ops2 dumps2
    for (i, (fname, B)) in (List.range fams.length).zip fams do
      if onlyFamily != 0 && onlyFamily != i + 1 then continue
      let t0 ← IO.monoMsNow
      let st ← searchFast R B
      let t1 ← IO.monoMsNow
      IO.println s!"  {fname}: {st.states} worlds checked, {st.violations} violating ({t1 - t0} ms)"
      for (cls, n, tr, why) in st.byClass do
        IO.println s!"    {cls} x{n}, shortest: {showTr tr} -> {why}"
      if !st.noRow.isEmpty then
        IO.println s!"    of these, hand-restoring a dump without its row: {st.noRow}"
      IO.println s!"    P10 (a live row's seq in lost) worlds: {st.p10}{(st.p10tr.map fun tr => s!", shortest: {showTr tr}").getD ""}"
