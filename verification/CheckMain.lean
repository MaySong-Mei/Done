import CivilCalendar.SyncRestore

/-!
Driver for the simple restore rule and the final rule (gh#257),
`lake exe checksearch <mode> ...`:

* `replay <rule> <rows> <prompt> <trace>`: one trace; the verdict (every
  class, for the final rule) and the world before and after settling.
* `replays <rule>`: every named scenario and journal trace, one line each.
* `bfs <rule> <rows> <depth> <ops> <dumps> <prompt> <offScript> <rollbacks>
  <opsInRollback> <kbits> [flags]`: the model's `enabled`, breadth-first,
  a visited set of canonical 64-bit world hashes in a flat open-addressing
  table of `2^kbits` slots; the frontier keeps traces and replays them.
  `flags` is a comma list of `del` (deletes), `prompts` (the recovery
  prompt's actions), `erase`, `race` (the unlocked step), `fresh` (rows are
  created only once), or `-`.
* `script <rule> <rows> <depth> <prompt> <kbits> <ops> [flags]`: the
  operator actions fixed to the given sequence (in order, each at most
  once); device actions, agent writes and unpause interleave freely.
* `cross`: the hashed search against the model's own `searchF` (worlds
  kept) for the final rule on small bounds of every family.

Trace tokens: `d` dump, `dn` dump without sync_epoch, `eA0` edit device A
row 0, `xA0` delete, `pA` pull, `fA` flush, `g0` agent row 0, `k0` agent
delete, `rs0` restore.sh D0, `by0` bypass D0, `bn0` bypass into a new
project, `ab0` abort after setval, `st` standalone step, `sr0` the
standalone step racing an agent write on row 0 (no lock), `rb` rollback,
`re` re-enable, `up` unpause, `acA` / `ltA` / `dcA` the prompt's restore /
later / discard on A, `wA` log-out / erase (wipe) on A.

A rule is a base name and `:`-separated modifiers, e.g. `final:noOrigin`.
-/

open Verification.SyncRestore

instance : Inhabited Rules := ⟨final⟩
instance : Inhabited Bounds := ⟨{ rows := 1, depth := 0, maxOps := 0, maxDumps := 0, prompt := true }⟩

def devName (d : Nat) : String := if d == 0 then "A" else "B"
def rowName (r : Nat) : String := if r == 0 then "X" else "Y"

def showAct : Act → String
  | .edit d r => s!"edit {devName d} {rowName r}"
  | .pull d => s!"pull {devName d}"
  | .flush d => s!"flush {devName d}"
  | .agent r => s!"agent {rowName r}"
  | .dump b => if b then "dump" else "dump(no sync_epoch)"
  | .restore k => s!"restore.sh D{k}"
  | .bypass k => s!"bypass D{k}"
  | .bypassNew k => s!"bypass-into-new-project D{k}"
  | .abortSetval k => s!"abort-after-setval D{k}"
  | .standalone => "restore_with_epoch alone"
  | .rollback => "rollback"
  | .reenable => "reenable"
  | .unpause => "unpause"
  | .delete d r => s!"delete {devName d} {rowName r}"
  | .agentDel r => s!"agent-delete {rowName r}"
  | .accept d => s!"prompt-restore {devName d}"
  | .later d => s!"prompt-later {devName d}"
  | .discard d => s!"prompt-discard {devName d}"
  | .erase d => s!"erase {devName d}"
  | .stepRace r => s!"unlocked-step racing agent {rowName r}"

def showTr (tr : List Act) : String := s!"[{", ".intercalate (tr.map showAct)}]"

def parseAct (t : String) : Act :=
  let dv (c : Char) : Nat := if c == 'A' then 0 else 1
  let n (c : Char) : Nat := c.toNat - '0'.toNat
  match t.toList with
  | ['d'] => .dump true
  | ['d', 'n'] => .dump false
  | ['e', d, r] => .edit (dv d) (n r)
  | ['x', d, r] => .delete (dv d) (n r)
  | ['p', d] => .pull (dv d)
  | ['f', d] => .flush (dv d)
  | ['g', r] => .agent (n r)
  | ['k', r] => .agentDel (n r)
  | ['r', 's', k] => .restore (n k)
  | ['b', 'y', k] => .bypass (n k)
  | ['b', 'n', k] => .bypassNew (n k)
  | ['a', 'b', k] => .abortSetval (n k)
  | ['s', 't'] => .standalone
  | ['s', 'r', r] => .stepRace (n r)
  | ['r', 'b'] => .rollback
  | ['r', 'e'] => .reenable
  | ['u', 'p'] => .unpause
  | ['a', 'c', d] => .accept (dv d)
  | ['l', 't', d] => .later (dv d)
  | ['d', 'c', d] => .discard (dv d)
  | ['w', d] => .erase (dv d)
  | _ => panic! s!"bad token {t}"

def parseTr (s : String) : List Act :=
  if s == "-" then [] else (s.splitOn ",").map parseAct

def baseRule : String → Option Rules
  | "final" => some final
  | "sw" => some serverWinsShelf
  | "swFF" => some swFF
  | "swReup" => some swReup
  | "swFFReup" => some swFFReup
  | "swFFO" => some swFFOrigin
  | "simpleLocalWins" => some simpleLocalWins
  | "localWins" => some localWins
  | "lostRange" => some lostRange
  | "cur" => some current
  | _ => none

def applyMod (R : Rules) : String → Option Rules
  | "noShelf" => some (abNoShelfOf R)
  | "noReup" => some (abNoReuploadOf R)
  | "rewindRestore" => some (abRewindRestoreOf R)
  | "noRaiseStep" => some (abNoRaiseStepOf R)
  | "noGate" => some (abNoGateOf R)
  | "noServerGate" => some (abServerGateOf R)
  | "noOrigin" => some (abOriginOf R)
  | "noDeleteWins" => some (abDeleteWinsOf R)
  | "offerNone" => some (abOfferNoneOf R)
  | "offerAll" => some (abOfferAllOf R)
  | "noAcceptGuard" => some (abAcceptGuardOf R)
  | "noEraseWarn" => some (abEraseWarnOf R)
  | "noPrune" => some (abPruneOf R)
  | "noFF" => some (abFFOf R)
  | "agentPaused" => some (agentPausedOf R)
  | "agentWhilePaused" => some (agentWhilePausedOf R)
  | "noGateMarks" => some (noGateMarksOf R)
  | "noTombInsert" => some (abTombInsertOf R)
  | "noReupStale" => some (abReupStaleOf R)
  | "originBack" => some (originBackOf R)
  | "acceptCond" => some (acceptCondOf R)
  | "offerOwn" => some (offerOwnOf R)
  | "offerEpoch" => some (offerEpochOf R)
  | "noop" => some (noopOf R)
  | "allRB" => some (allRBOf R)
  | "doc" => some (docOf R)
  | "sticky" => some (stickyOf R)
  | "split" => some { R with name := R.name ++ " | P3d split", splitP3 := true }
  | "pushed" => some { R with name := R.name ++ " | rolledBack only for versions ever on the server", rbPushedOnly := true }
  | _ => none

def ruleOf (s : String) : Rules :=
  match s.splitOn ":" with
  | b :: mods =>
    match baseRule b with
    | some R => mods.foldl (fun R m => match applyMod R m with
        | some r => r
        | none => panic! s!"unknown modifier {m}") R
    | none => panic! s!"unknown rule {b}"
  | [] => panic! "empty rule"

def showBase : BaseE → String
  | .none => "-"
  | .known h s => s!"{h}@{s}"
  | .hashOnly h s => s!"{h}@?({s})"
  | .unk => "?"
  | .unkAt s => s!"?@{s}"
  | .lostQ h t => s!"lostQ {h} {t}"
  | .stale h s => s!"stale {h} {s}"

def showEntry (e : SEntry) : String :=
  s!"{e.ver}{if e.catchup then s!"/vs {e.against}" else ""}{if e.offered then " OFFERED" else ""}"

def showWorld (w : World) : String :=
  let rows := w.srv.rows.map fun o => match o with
    | some r => if r.dead != 0 then s!"dead(v{r.ver} by {r.dead})@{r.seq}" else s!"v{r.ver}@{r.seq}"
    | none => "absent"
  let devs := (indexed w.devs).map fun (i, d) =>
    s!"{devName i}: loc {d.loc} base {d.base.map showBase} shelf {d.shelf.map showEntry} epoch {d.epoch} origin {d.origin} del {d.del}"
  let vs := (indexed w.vers).map fun (i, v) =>
    s!"v{i+1}(row {v.row} parent {v.parent}{if v.over.isEmpty then "" else s!" over {v.over}"}{if v.dead then " DELETE" else ""}{if v.byAgent then " agent" else ""}{if v.held then " held" else ""}{if v.rolledBack then " RB" else ""}{if v.onServer then " srv" else ""})"
  s!"server {rows} counter {w.srv.counter} epoch {w.srv.er.epoch} paused {w.srv.er.paused}; " ++ "; ".intercalate devs
    ++ s!"\n        dropped {w.dropped} badAccept {w.badAccept}\n        versions " ++ " ".intercalate vs

/-- every class the rule's checker reports: the strict checker's list for
the final rule, the single verdict of the earlier checker otherwise -/
def classesOf (R : Rules) (w : World) : List (String × String) :=
  if R.final then checkF R w
  else match check R w with
    | some why => [((why.splitOn " ").headD why, why)]
    | none => []

structure St where
  states : Nat := 0
  violations : Nat := 0
  hard : Nat := 0
  byClass : List (String × Nat × List Act × String) := []

def St.record (st : St) (R : Rules) (tr : List Act) (found : List (String × String)) : St :=
  if found.isEmpty then st else
  let isHard := if R.final then found.any (fun (c, _) => hardClasses.contains c)
    else found.any (fun (c, _) => c != "P3s")
  let st := { st with violations := st.violations + 1, hard := st.hard + (if isHard then 1 else 0) }
  found.foldl (fun st (cls, why) =>
    if st.byClass.any (·.1 == cls) then
      { st with byClass := st.byClass.map fun e => if e.1 == cls then (e.1, e.2.1 + 1, e.2.2) else e }
    else { st with byClass := st.byClass ++ [(cls, 1, tr.reverse, why)] }) st

def canonHash (w : World) : UInt64 :=
  let a := hash w
  let b := hash { w with devs := w.devs.reverse }
  if b < a then b else a

/-! ## Flat open-addressing table of 64-bit keys (0 = empty slot) -/

def mkTbl (k : Nat) : ByteArray := Id.run do
  let n := (2 ^ k) * 8
  let mut a := ByteArray.emptyWithCapacity n
  for _ in [0:n] do a := a.push 0
  return a

@[inline] def rd (a : ByteArray) (o : Nat) : UInt64 :=
  (a.get! o).toUInt64 ||| ((a.get! (o+1)).toUInt64 <<< 8) ||| ((a.get! (o+2)).toUInt64 <<< 16)
  ||| ((a.get! (o+3)).toUInt64 <<< 24) ||| ((a.get! (o+4)).toUInt64 <<< 32)
  ||| ((a.get! (o+5)).toUInt64 <<< 40) ||| ((a.get! (o+6)).toUInt64 <<< 48)
  ||| ((a.get! (o+7)).toUInt64 <<< 56)

@[inline] def wr (a : ByteArray) (o : Nat) (x : UInt64) : ByteArray :=
  let a := a.set! o x.toUInt8
  let a := a.set! (o+1) (x >>> 8).toUInt8
  let a := a.set! (o+2) (x >>> 16).toUInt8
  let a := a.set! (o+3) (x >>> 24).toUInt8
  let a := a.set! (o+4) (x >>> 32).toUInt8
  let a := a.set! (o+5) (x >>> 40).toUInt8
  let a := a.set! (o+6) (x >>> 48).toUInt8
  a.set! (o+7) (x >>> 56).toUInt8

/-- Insert if absent; `true` when the key was new. -/
partial def ins (a : ByteArray) (mask : Nat) (h0 : UInt64) : ByteArray × Bool :=
  let h := if h0 == 0 then 1 else h0
  let rec go (a : ByteArray) (i : Nat) : ByteArray × Bool :=
    let o := i * 8
    let x := rd a o
    if x == 0 then (wr a o h, true)
    else if x == h then (a, false)
    else go a ((i + 1) &&& mask)
  go a (h.toNat &&& mask)

def visit (R : Rules) (st : St) (w : World) (tr : List Act) : St :=
  let st := { st with states := st.states + 1 }
  st.record R tr (classesOf R w)

/-- Breadth-first over every action sequence within the bounds; a table
that fills past its load limit makes the run say INVALID. -/
def bfs (R : Rules) (rows depth : Nat) (prompt : Bool) (kbits : Nat)
    (en : World → List Act) : IO (St × Bool) := do
  let w0 := initWorld rows
  let mask := 2 ^ kbits - 1
  let mut tbl := mkTbl kbits
  let mut used := 0
  let (t, _) := ins tbl mask (canonHash w0)
  tbl := t
  used := used + 1
  let mut st : St := visit R {} w0 []
  let mut frontier : Array (List Act) := #[[]]
  for lvl in [0:depth] do
    let mut next : Array (List Act) := #[]
    for tr in frontier do
      let w := run R prompt w0 tr.reverse
      for a in en w do
        let w' := step R prompt w a
        let (t, isNew) := ins tbl mask (canonHash w')
        tbl := t
        if isNew then
          used := used + 1
          if used * 10 > (mask + 1) * 9 then
            IO.println s!"  TABLE_TOO_FULL used {used} of {mask + 1} inside level {lvl + 1}: INVALID"
            return (st, false)
          st := visit R st w' (a :: tr)
          if lvl + 1 < depth then next := next.push (a :: tr)
    frontier := next
    IO.eprintln s!"  level {lvl + 1} done: frontier {frontier.size}, states {st.states}, slots used {used} of {mask + 1}"
  return (st, true)

def enabledScript (B : Bounds) (script : List Act) (w : World) : List Act :=
  let all := enabled { B with maxOps := 0 } w
  let op : List Act := match script[w.ops]? with
    | some a => [a]
    | none => []
  all ++ op

def tagOf (R : Rules) (cls : String) : String :=
  if !R.final then (if cls == "P3s" then "accepted" else "hard")
  else if hardClasses.contains cls then "hard"
  else if acceptedClasses.contains cls then "accepted" else "reported"

def printSt (R : Rules) (st : St) (ok : Bool) (ms : Nat) : IO Unit := do
  IO.println s!"  RESULT: {st.states} worlds checked, {st.violations} with a class, hard {st.hard}{if ok then "" else " INVALID"} ({ms} ms)"
  for (cls, n, tr, why) in st.byClass do
    IO.println s!"    {cls} [{tagOf R cls}] x{n}, shortest: {showTr tr} -> {why}"

def applyFlags (B : Bounds) (flags : String) : Bounds :=
  if flags == "-" then B else
  (flags.splitOn ",").foldl (fun B f => match f with
    | "del" => { B with deletes := true, fresh := true }
    | "prompts" => { B with prompts := true }
    | "erase" => { B with erase := true }
    | "race" => { B with raceStep := true }
    | "fresh" => { B with fresh := true }
    | _ => panic! s!"unknown flag {f}") B

structure Trace where
  name : String
  rows : Nat := 1
  tr : List Act

def traces : List Trace :=
  [ ⟨"major1", 1, major1⟩, ⟨"minor2", 1, minor2⟩, ⟨"lagging", 1, lagging⟩,
    ⟨"scripted", 1, scripted⟩, ⟨"twoBypass", 1, twoBypass⟩,
    ⟨"abortLagging", 1, abortLagging⟩, ⟨"rollbackRestore", 1, rollbackRestore⟩,
    ⟨"restampRevert", 1, restampRevert⟩, ⟨"forkRevert", 1, forkRevert⟩,
    ⟨"resetAbandon", 1, resetAbandon⟩, ⟨"pausedRestore", 1, pausedRestore⟩,
    ⟨"stepThenRestore", 1, stepThenRestore⟩, ⟨"newBypass", 1, newBypass⟩,
    ⟨"bypassOldRow", 1, bypassOldRow⟩, ⟨"noRowBypass", 1, noRowBypass⟩,
    ⟨"restoreKeepsAgain", 1, restoreKeepsAgain⟩, ⟨"newerAfterOlder", 1, newerAfterOlder⟩,
    ⟨"keepAgainPaused", 1, keepAgainPaused⟩, ⟨"keepAgainHead", 1, keepAgainHead⟩,
    ⟨"keepAgainFlush", 1, keepAgainFlush⟩, ⟨"noRowKeepsAgain", 1, noRowKeepsAgain⟩,
    ⟨"forkNoRow", 1, forkNoRow⟩, ⟨"forkNoRowNew", 1, forkNoRowNew⟩,
    ⟨"noRowBypassRevert", 1, noRowBypassRevert⟩,
    ⟨"stepEdit", 1, stepEdit⟩, ⟨"editOnDiscarded", 1, editOnDiscarded⟩,
    ⟨"keptLocalConflict", 1, keptLocalConflict⟩, ⟨"lostPatchRace", 1, lostPatchRace⟩,
    ⟨"intermediate", 1, intermediate⟩,
    ⟨"j: MAJOR(1) edit before dump", 1, [.edit 0 0, .dump true, .flush 0, .bypass 0]⟩,
    ⟨"j: abort P1", 1, [.edit 0 0, .edit 1 0, .dump true, .flush 0, .abortSetval 0]⟩,
    ⟨"j: abort no-quiescence, 2 rows", 2, [.edit 0 1, .edit 1 1, .dump true, .agent 0, .abortSetval 0, .pull 1]⟩,
    ⟨"j: F = counter P3", 1, [.edit 0 0, .dump true, .flush 0, .agent 0, .abortSetval 0]⟩,
    ⟨"j: X4 P2", 1, [.edit 0 0, .edit 1 0, .dump true, .flush 0, .restore 0]⟩,
    ⟨"j: rollback agent", 1, [.rollback, .agent 0]⟩,
    ⟨"j: agent then restore", 1, [.agent 0, .dump true, .restore 0]⟩,
    ⟨"j: abJump P2", 1, [.edit 0 0, .dump true, .bypass 0, .flush 0, .bypass 0]⟩,
    ⟨"j: resetAbandon via the standalone step", 1,
      [.edit 0 0, .dump true, .flush 0, .standalone, .rollback, .pull 0, .reenable, .restore 0]⟩,
    ⟨"j: T1", 1, [.dump true, .agent 0, .pull 1, .dump true, .restore 0, .restore 1, .agent 0]⟩,
    ⟨"round1 noGate P2", 1, [.edit 0 0, .dump true, .flush 0, .edit 0 0, .bypass 0, .agent 0, .flush 0]⟩,
    ⟨"round1 swFFO residual", 1, [.edit 0 0, .dump true, .agent 0, .abortSetval 0, .unpause, .pull 0, .restore 0]⟩ ]

def main (args : List String) : IO Unit := do
  match args with
  | ["replay", rn, rows, prompt, trs] =>
    let R := ruleOf rn
    let tr := parseTr trs
    let w := run R (prompt == "1") (initWorld rows.toNat!) tr
    IO.println s!"== {R.name}\n  {showTr tr}\n  verdict: {classesOf R w}"
    IO.println s!"  before settle: {showWorld w}"
    match settle R w with
    | some w' => IO.println s!"  settled: {showWorld w'}"
    | none => IO.println "  settled: (no fixed point)"
  | ["replays", rn] =>
    let R := ruleOf rn
    IO.println s!"== {R.name}"
    for t in traces do
      let found := classesOf R (run R true (initWorld t.rows) t.tr)
      IO.println s!"  {t.name}: {if found.isEmpty then "pass" else ", ".intercalate (found.map (·.2))}"
  | "bfs" :: rn :: rows :: depth :: ops :: dumps :: prompt :: offScript :: rollbacks :: oir :: kb :: rest =>
    let R := ruleOf rn
    let flags := rest.headD "-"
    let B0 : Bounds := { rows := rows.toNat!, depth := depth.toNat!, maxOps := ops.toNat!,
                         maxDumps := dumps.toNat!, prompt := prompt == "1", offScript := offScript == "1",
                         rollbacks := rollbacks == "1", opsInRollback := oir == "1" }
    let B := applyFlags B0 flags
    IO.println s!"== {R.name}\n  bfs rows {B.rows} depth {B.depth} ops<={B.maxOps} dumps<={B.maxDumps} prompt {B.prompt} offScript {B.offScript} rollbacks {B.rollbacks} opsInRollback {B.opsInRollback} flags {flags} kbits {kb}"
    let t0 ← IO.monoMsNow
    let (st, ok) ← bfs R B.rows B.depth B.prompt kb.toNat! (enabled B)
    let t1 ← IO.monoMsNow
    printSt R st ok (t1 - t0)
  | "script" :: rn :: rows :: depth :: prompt :: kb :: ops :: rest =>
    let R := ruleOf rn
    let flags := rest.headD "-"
    let script := parseTr ops
    let B0 : Bounds := { rows := rows.toNat!, depth := depth.toNat!, maxOps := 0, maxDumps := 0,
                         prompt := prompt == "1" }
    let B := applyFlags B0 flags
    IO.println s!"== {R.name}\n  script rows {rows} depth {depth} prompt {prompt} flags {flags} kbits {kb} ops {showTr script}"
    let t0 ← IO.monoMsNow
    let (st, ok) ← bfs R B.rows B.depth B.prompt kb.toNat! (enabledScript B script)
    let t1 ← IO.monoMsNow
    printSt R st ok (t1 - t0)
  | ["cross"] =>
    let fams : List (String × Bounds) :=
      [ ("F1", { rows := 1, depth := 6, maxOps := 4, maxDumps := 2, prompt := true, prompts := true }),
        ("F2", { rows := 1, depth := 7, maxOps := 4, maxDumps := 2, prompt := true, offScript := false,
                 rollbacks := false, prompts := true }),
        ("F3", { rows := 2, depth := 5, maxOps := 3, maxDumps := 2, prompt := true, prompts := true, fresh := true }),
        ("F4", { rows := 1, depth := 6, maxOps := 4, maxDumps := 2, prompt := false, prompts := true }),
        ("F5", { rows := 1, depth := 6, maxOps := 4, maxDumps := 2, prompt := true, opsInRollback := true,
                 prompts := true }),
        ("D1", { rows := 1, depth := 6, maxOps := 4, maxDumps := 2, prompt := true, prompts := true,
                 deletes := true, fresh := true }),
        ("D3", { rows := 2, depth := 5, maxOps := 3, maxDumps := 2, prompt := true, prompts := true,
                 deletes := true, fresh := true }),
        ("E1", { rows := 1, depth := 6, maxOps := 4, maxDumps := 2, prompt := true, prompts := true,
                 erase := true }),
        ("R1", { rows := 1, depth := 6, maxOps := 4, maxDumps := 2, prompt := true, prompts := true,
                 raceStep := true }) ]
    for (nm, B) in fams do
      let a := searchF final B
      let (b, ok) ← bfs final B.rows B.depth B.prompt 22 (enabled B)
      let ca := a.byClass.map fun e => (e.1, e.2.1)
      let cb := b.byClass.map fun e => (e.1, e.2.1)
      IO.println s!"{nm}: exact {a.states} worlds hard {a.hard} {ca}; hashed {b.states} worlds hard {b.hard} {cb}; same {ok && a.states == b.states && a.hard == b.hard && ca == cb}"
  | _ => IO.println "usage: see the header of CheckMain.lean"
