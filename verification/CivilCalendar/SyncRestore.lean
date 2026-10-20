import CivilCalendar.SyncMerge
import Std.Data.HashSet

/-!
# Server restore and the epoch reset — a bounded exhaustive model (gh#257)

Model of `Docs/sync/00-realtime-sync-design.md` @ 021860e (branch
design/realtime-sync): §5.7 item 7 (the `sync_epoch` row with `floor`,
`lost`, `paused` and who writes it), §6.6 (restore script, the per-page
epoch check, the reset, the pause bit), D10, and §7 handoff (8) (rollback,
re-enable, the standalone epoch step). The ops scripts in
`done-mcp/supabase/ops/` on that commit still carry the pre-review text
(`restore_with_epoch.sql` sets `floor` from the live counter and has no
`lost`); the design text says the scripts follow it ("服务端流随本条改"),
so the model follows the TEXT and calls it "current".

Prose rounds kept reopening this mechanism, so it is checked here by
enumeration instead: every interleaving of the actions below, up to a
bounded length, from one fixed start, each prefix settled to quiescence
and judged by `check`. Positive controls (rule variants that must be
caught) and the counterexamples the last independent check reported are
replayed as `#guard`s; the large searches run in `lake exe
syncrestoresearch` and their sizes and state counts live there, not here.

## What is modelled

* **Server**: rows by index (row 0 = X, present at the start as version 1
  at seq 1; row 1 = Y, absent at the start), each `(version, seq)`; the
  counter `sync_seq`; the one `sync_epoch` row `(epoch, floor, lost,
  paused)`; whether the sync triggers are installed (rollback drops them:
  an UPDATE then keeps the row's old seq). A ghost `highWater` records the
  highest value the counter ever held; only the `oracle` rule reads it —
  it stands for an operator-supplied `--last-seq` that is at least every
  seq ever handed out.
* **Dumps**: rows, counter, and the `sync_epoch` row or nothing (a data
  dump that left that table out).
* **Operator actions**: take a dump; `restore.sh` (the new-project path
  with a correct `--last-seq` and the `--replace` path are the same
  arithmetic here: rows and the `sync_epoch` row come from the dump,
  setval stripped, then `restore_with_epoch`; whether it takes a dump
  without the `sync_epoch` row, and what it then uses for the missing
  row's `lost`, is a rule: `Rules.refuseNoEpoch`, `Rules.carry`); a restore that bypassed
  `restore.sh` (data.sql's own setval rewinds the counter, the
  `sync_epoch` row comes back from the dump when the dump has it); an
  aborted non-script restore where the dump's setval already ran (setval
  does not roll back); a restore that bypassed `restore.sh` into a NEW
  project (as the bypass, but a dump without the `sync_epoch` row leaves
  the freshly seeded row: new epoch, floor 0, empty `lost`);
  `restore_with_epoch.sql` on its own; rollback (`paused` set, the wait W
  elapsed, triggers dropped) and re-enable (triggers back, the standalone
  epoch step); the operator clearing `paused` once the checks pass; an
  agent / MCP write (server side, no seq filter). Every epoch step
  (`restore.sh`'s last step, the standalone step, the one inside
  re-enable) ends with `paused = true` (§5.7 item 7); clearing it is a
  separate action, and devices may act in between.
* **The standalone step is atomic against writes.** That is a
  requirement of the design text (the step locks the nine tables before
  it reads `F`), not a modelling convenience: `standaloneRace` replays
  the step without the lock, and a write that takes `nextval` between the
  read of `F` and the `setval` leaves a live row inside `lost`.
* **Devices** (two): local version per row, baseline entry per row
  (`(hash, seq)`, hash with seq unknown, `?`, `?@seq`), cursor, the
  epoch last seen, the outbound gate (last epoch GET read `paused =
  false`), the pending-verify set, the shelf, and per row the `(hash,
  seq)` of a local copy a reset found lost (`Rules.rememberLost`). A device that does not act
  is offline; it can stay offline across any number of operator actions.
* **Device actions**: edit a row (a fresh version whose parent is the
  local one); pull (one chain to head: the epoch GET before applying, the
  reset when the epoch changed, abandon when paused, the §6 rule table
  row by row in seq order, pending-verify at head, and after a reset the
  entries never seen at head become `?`); flush (PATCH with the entry's
  seq, ignore-duplicates POST without one, `[]` → pending-verify).
* The §6 rows after the skip row are `Verification.Sync.decideRowBody`
  (`CivilCalendar/SyncMerge.lean`) itself, called with the `?` hash
  encoded as the reserved hash `UNK` that no version has; the skip row is
  restated here only because SyncMerge's baseline always has a seq and
  this one may not (§6: "基线 seq 未知 … 时下面的 skip 行不触发").
* A chain abandoned after its reset (the GET read `paused = true`) leaves
  the device reset, its cursor dropped and its outbound gate shut. A chain
  cut by the network after the reset leaves the same device state (I1
  shuts outbound until a chain reaches head), and `paused` does not change
  `epoch` or `lost`, so the paused pull covers that cut too.

## What is NOT modelled (each a stated limit, not a claim)

* Deletes and tombstones (rows never die here). Resurrection of a
  delete that landed after the dump is an accepted cost in §6.6; the
  model says nothing about it.
* In-flight interleavings inside one pull chain or one flush (each is
  atomic): the in-flight-echo row, the stale page, the held old chain
  C1 of §6.6 (ii), lost responses. SyncMerge covers those without restores.
* Writes committed while a dump runs (the dump is an instant), crashes and
  per-key persistence order (S11), singleton tables, more than two
  devices, more than two rows.
* A chain cut part-way through its pages (some rows applied, others
  not): with one row that is the cut above; with two rows each pull is
  still all rows or none.
* "Prompt" families run the standalone step right after a bypassed or
  aborted restore, before any device acts (R3's "immediately"); the
  "window open" family lets devices write in between. Writes in that
  window reuse seqs the old timeline already named; no epoch rule
  repairs that, and the search confirms it for every rule (§9.37).
* A hand restore (bypass, also into a new project) of a dump taken
  without its `sync_epoch` row is searched in a family of its own
  (`Bounds.noRowHand`). Such a dump does not say which seqs at or below
  its own rows were already lost when it was taken, so the step's base
  (the live row the hand restore left in place, or the old project's) is
  a guess: it can name a version the dump kept (`noRowBypassRevert`
  fails for every rule) and can miss one the dump had lost. `restore.sh`
  refuses such a dump under the recommended rule; the hand path cannot
  be refused (§9.37).

## The safety property (`check`), at quiescence

After the scenario, an unfinished rollback is re-enabled and a set
`paused` is cleared, then both
devices pull and flush in turns until a whole round changes nothing (at
most `settleRounds` rounds; no fixed point is itself a failure — e.g. an
orphan POST that burns a seq every round). Versions are fresh per write and
know their parent (the writer's local version, or the server's for an
agent write). A restore from dump `D` **rolls back** every existing
version that is not in the history `D` kept for its row (neither `D`'s
version of the row nor an ancestor of it), and **keeps** every version
that is: each restore re-judges every version, so a version an earlier
restore discarded and a later restore brought back counts as kept
(`rolledBack` is the verdict of the last restore that saw the version; it
is never set by anything else). A version is **protected** when
some device ever held it as its local value, or when an agent wrote it and
the last restore did not roll it back (an agent-only version a restore
discards was never on any device; no rule can save it). The **survivors** are the
server's live versions plus every shelf entry. Then:

* **P1 converged**: each device's local value of each row equals the
  server's, its baseline is clean on it, its pending set is empty, and it
  has seen the server's epoch;
* **P2 no loss**: every protected version is a survivor or an ancestor
  of one;
* **P3 no revert onto a kept version**: for every protected version `v`
  that is not rolled back, the server's final value `w` of `v`'s row
  is not a strict ancestor of `v` unless `w` is rolled back.
  §6.6 rejects exactly this with its counterexample (2) (the lagging
  device pushing an older version over every device) and §7 (8) with
  "agent 的编辑在每台设备上被回退";
* **P3s**, reported separately and NOT required: the same revert where
  `w` is a version a restore rolled back and a device then resurrected.
  It is the cost of a restore forking post-dump history: two devices hold
  the same lost version, one edits it again, the other's `?` beats the
  newer edit, which lands in its shelf (`forkRevert`). P2 still holds.
  No candidate below closes it without breaking P2 or P3 elsewhere in the
  bounds; the two device-side variants tried (`devRemoteWins`,
  `devHybrid`) only move it. Telling "older copy of the same edit" from
  "concurrent edit" needs the version a write was based on, which no row
  carries.

P2 is goal 3 / I7. The search keys its visited set on the world with the
two devices in a canonical order (they are interchangeable), so a state
count is a count of distinct worlds up to that swap.
-/

namespace Verification
namespace SyncRestore

open Verification.Sync (decideRowBody Decision Action)

/-! ## Small list helpers (local, so the model does not depend on API drift) -/

def modAt {α : Type} : List α → Nat → (α → α) → List α
  | [], _, _ => []
  | x :: xs, 0, f => f x :: xs
  | x :: xs, n + 1, f => x :: modAt xs n f

def setAt {α : Type} (l : List α) (i : Nat) (a : α) : List α := modAt l i fun _ => a

def indexed {α : Type} (l : List α) : List (Nat × α) := (List.range l.length).zip l

/-! ## State -/

/-- The hash a `?` entry compares with. Versions start at 1, so no row
content ever hashes to it: `?` never equals a local or incoming hash. -/
def UNK : Nat := 0

/-- Stand-in for `2^40` in the "jump the counter" candidate: far above
every seq a bounded run can reach. -/
def J : Nat := 1000

structure SRow where
  ver : Nat
  seq : Nat
deriving BEq, Hashable, Repr, Inhabited

/-- The `sync_epoch` row. `lost` is the cumulative multirange as a list
of half-open ranges `(a, b]`. -/
structure EpochRow where
  epoch : Nat
  floor : Nat
  lost : List (Nat × Nat)
  paused : Bool
deriving BEq, Hashable, Repr, Inhabited

def inLost (lost : List (Nat × Nat)) (s : Nat) : Bool :=
  lost.any fun (a, b) => decide (a < s) && decide (s ≤ b)

def addLost (lost : List (Nat × Nat)) (a b : Nat) : List (Nat × Nat) :=
  if a < b && !lost.contains (a, b) then lost ++ [(a, b)] else lost

def unionLost (x y : List (Nat × Nat)) : List (Nat × Nat) :=
  y.foldl (fun acc (a, b) => addLost acc a b) x

structure Dump where
  rows : List (Option SRow)
  counter : Nat
  epochRow : Option EpochRow
deriving BEq, Hashable, Repr, Inhabited

structure Server where
  rows : List (Option SRow)
  counter : Nat
  er : EpochRow
  triggers : Bool
  /-- ghost: the highest value the counter ever held -/
  highWater : Nat
deriving BEq, Hashable, Repr, Inhabited

/-- A baseline entry (§6, §6.3, §6.6). -/
inductive BaseE where
  | none
  | known (h s : Nat)
  /-- the old `<hash>` shape: hash kept, skip row off. `s` is the seq the
  entry had before a reset, kept only so a later reset can classify the
  entry against `lost` (`Rules.keepClassSeq`); the skip row and the
  flush never read it. `0` = unknown (no write is ever handed seq 0). -/
  | hashOnly (h s : Nat)
  /-- `?`: hash and seq unknown -/
  | unk
  /-- `?@seq`: a send's mark, hash unknown, seq kept -/
  | unkAt (s : Nat)
  /-- candidates only (`LostMode.remoteWins` / `.hybrid`): a reset's `?`
  for an entry whose seq is in `lost`, remembering the entry's old hash
  and the top of `lost` at the reset -/
  | lostQ (h top : Nat)
deriving BEq, Hashable, Repr, Inhabited

structure Device where
  loc : List (Option Nat)
  base : List BaseE
  cursor : Nat
  epoch : Nat
  /-- the last epoch GET read `paused = false` (and the rollback wait has
  not expired it) -/
  gate : Bool
  /-- a reset happened and no chain has reached head since -/
  afterReset : Bool
  /-- pending-verify: `(row, sentSeq, sentHash)` -/
  pending : List (Nat × Nat × Nat)
  shelf : List Nat
  /-- per row: `(hash, seq)` of the local copy as it was when a reset found
  it lost (`Rules.rememberLost`); cleared when the local value changes -/
  was : List (Option (Nat × Nat))
deriving BEq, Hashable, Repr, Inhabited

structure VerInfo where
  row : Nat
  parent : Nat
  byAgent : Bool
  held : Bool
  rolledBack : Bool
deriving BEq, Hashable, Repr, Inhabited

structure World where
  srv : Server
  devs : List Device
  dumps : List Dump
  /-- version `v` is at index `v - 1` -/
  vers : List VerInfo
  nextEpoch : Nat
  rolledBackMode : Bool
  ops : Nat
deriving BEq, Hashable, Repr, Inhabited

/-! ## Rules: the current text and the variants -/

/-- Where the standalone epoch step puts the bottom of the range it adds. -/
inductive FMode where
  /-- the live counter (current text: "单独跑时缺省为 L") -/
  | counter
  /-- `max(counter, max(seq) over the rows)` -/
  | maxRows
  /-- `max(seq)` over the rows the step leaves live (the restored rows for
  `restore.sh`, the live rows for the standalone step); the counter is not
  read -/
  | rows
deriving BEq, Repr

/-- What `restore.sh` unions into the restored row's `lost`. -/
inductive CarryMode where
  /-- nothing: the dump's own `lost` and `(F, L]` -/
  | never
  /-- the live `lost`, read before TRUNCATE -/
  | always
  /-- the live `lost`, only when the dump has no `sync_epoch` row -/
  | noRow
deriving BEq, Repr

/-- Where the standalone epoch step puts the top of the range it adds. -/
inductive LMode where
  /-- `L = F`: the range is empty (current text) -/
  | counter
  /-- `(F, F + J]` and the counter jumps to `F + J` -/
  | jump
  /-- the operator supplies the highest seq ever handed out (`--last-seq`,
  the contract the new-project path already has); modelled by the ghost
  `highWater`. Also used by `restore.sh` as its `L`. -/
  | oracle
  /-- as `oracle`, but the operator overshoots by `J` (an estimate "with
  margin" from device logs) -/
  | oracleOver
deriving BEq, Repr

inductive ResetMode where
  /-- §6.6 as written: entry seq ∈ lost → `?`, other entries keep hash, seq unknown -/
  | perEntry
  /-- X5: keep hash and seq of every entry -/
  | keepAll
  /-- every entry becomes `?` after any epoch change (local wins) -/
  | allSentinel
deriving BEq, Repr

/-- How a reset treats an entry whose seq is in `lost`. -/
inductive LostMode where
  /-- §6.6 as written: `?`; the local copy wins against any incoming row -/
  | sentinel
  /-- an incoming row written after the last epoch step (seq above the
  top of `lost`) wins and the local copy goes to the shelf; a restored row
  (seq at or below the top) still loses to the local copy -/
  | remoteWins
  /-- as `remoteWins` when the local copy is still the entry's old version,
  as `sentinel` when the device changed it since -/
  | hybrid
deriving BEq, Repr

structure Rules where
  name : String
  /-- false = X4: no epoch / floor at all; a restore setvals the counter upward -/
  epochStep : Bool := true
  fMode : FMode := .counter
  lMode : LMode := .counter
  /-- what `restore.sh` reads from the live `lost` before TRUNCATE and
  unions back -/
  carry : CarryMode := .never
  /-- `restore.sh` refuses a dump without the `sync_epoch` row -/
  refuseNoEpoch : Bool := false
  reset : ResetMode := .perEntry
  lost : LostMode := .sentinel
  /-- candidate: re-enable gives every row a fresh seq before the epoch
  step, so no seq handed out before the rollback names a version written
  during it -/
  restampOnReenable : Bool := false
  /-- candidate: the rollback keeps a trigger that stamps `seq :=
  nextval` on every UPDATE, so a write during the rollback never keeps an
  old seq -/
  stampDuringRollback : Bool := false
  /-- device side: a reset that keeps an entry's hash also keeps the
  entry's old seq, for the next reset's `lost` test only (§6.6 as written
  forgets it: "seq 标未知") -/
  keepClassSeq : Bool := false
  /-- device side: a reset that finds the device's local copy lost (the
  entry's seq is in `lost` and the local value is the entry's hash)
  remembers that `(hash, seq)` for as long as the local value stays that
  version — through the `?`, the chain to head and a flush. A later reset
  whose `lost` no longer has that seq takes the local copy as the kept,
  clean base (`hashOnly`). §6.6 as written forgets both ("hash 与 seq 都未
  知"), and the `?` then pushes the local copy over the newer version a
  later restore brought back -/
  rememberLost : Bool := false
  /-- a bypass into a new project, with a dump that has no `sync_epoch`
  row: the step's base is the OLD project's `lost`, not the freshly
  seeded empty row -/
  newBypassCarry : Bool := false
deriving Repr

def current : Rules := { name := "current text @021860e" }

/-! ## Server and device steps -/

def Server.issue (s : Server) : Server × Nat :=
  let n := s.counter + 1
  ({ s with counter := n, highWater := max s.highWater n }, n)

/-- The baseline entry as `decideRowBody` reads it (it reads only the hash
and whether an entry exists, `SyncMerge.lean` `decideRowBody`). -/
def baseForBody : BaseE → Option (Nat × Nat)
  | .none => none
  | .known h s => some (h, s)
  | .hashOnly h _ => some (h, 0)
  | .unk => some (UNK, 0)
  | .unkAt s => some (UNK, s)
  | .lostQ _ _ => some (UNK, 0)

def baseSeq : BaseE → Option Nat
  | .known _ s => some s
  | .unkAt s => some s
  | _ => none

def baseHash : BaseE → Option Nat
  | .known h _ => some h
  | .hashOnly h _ => some h
  | _ => none

/-- One incoming live row through the §6 table: the skip row (only when
the entry has a seq), then `decideRowBody` (no tombstones here). Returns
the device and whether it adopted the incoming version. -/
def applyIncoming (mode : LostMode) (dev : Device) (r : Nat) (row : SRow) : Device × Bool :=
  let b := dev.base.getD r .none
  let skip := match baseSeq b with
    | some S => decide (row.seq ≤ S)
    | none => false
  if skip then (dev, false) else
  let hLoc := dev.loc.getD r none
  match b with
  | .lostQ h top =>
    let remoteWins := match mode with
      | .remoteWins => true
      | .hybrid => hLoc == some h
      | .sentinel => false
    if top < row.seq && hLoc != some row.ver && remoteWins then
      let shelf' := match hLoc with
        | some c => dev.shelf ++ [c]
        | none => dev.shelf
      ({ dev with loc := setAt dev.loc r (some row.ver),
                  base := setAt dev.base r (.known row.ver row.seq), shelf := shelf',
                  was := setAt dev.was r none }, true)
    else applyBody dev r row b hLoc
  | _ => applyBody dev r row b hLoc
where
  applyBody (dev : Device) (r : Nat) (row : SRow) (b : BaseE) (hLoc : Option Nat) : Device × Bool :=
    let d := decideRowBody false row.ver hLoc (baseForBody b) row.seq
    let adopt := d.action == Action.adopt
    let loc' := if adopt then setAt dev.loc r (some row.ver) else dev.loc
    let base' := setAt dev.base r (match d.base with
      | some (h, s) => BaseE.known h s
      | none => BaseE.none)
    let shelf' := if d.shelfRemote then dev.shelf ++ [row.ver] else dev.shelf
    let was' := if adopt then setAt dev.was r none else dev.was
    ({ dev with loc := loc', base := base', shelf := shelf', was := was' }, adopt)

/-- §6.6 reset: drop the cursor, clear the in-memory tables, record the
new epoch, rewrite every entry by ITS OWN seq against `lost`. -/
def resetDev (R : Rules) (dev : Device) (er : EpochRow) : Device :=
  let top := er.lost.foldl (fun m x => max m x.2) 0
  let lostEntry : Nat → Nat → BaseE := fun h _ =>
    if R.lost != .sentinel then .lostQ h top else .unk
  let rw : BaseE → BaseE := fun b =>
    match R.reset with
    | .perEntry =>
      match b with
      | .known h s =>
        if inLost er.lost s then lostEntry h s
        else .hashOnly h (if R.keepClassSeq then s else 0)
      | .hashOnly h s =>
        if inLost er.lost s then lostEntry h s
        else .hashOnly h s
      | .unkAt _ => .unk
      | .lostQ h _ => .lostQ h top
      | x => x
    | .keepAll => b
    | .allSentinel =>
      match b with
      | .none => .none
      | _ => .unk
  let perRow : Nat → BaseE × Option (Nat × Nat) := fun i =>
    let b := dev.base.getD i .none
    let loc := dev.loc.getD i none
    match dev.was.getD i none with
    | some (h, s) =>
      if R.rememberLost && loc == some h then
        if inLost er.lost s then (rw b, some (h, s)) else (.hashOnly h s, none)
      else (rw b, none)
    | none =>
      let mem := if !R.rememberLost || R.reset != .perEntry then none else match b with
        | .known h s | .hashOnly h s =>
          if inLost er.lost s && loc == some h then some (h, s) else none
        | _ => none
      (rw b, mem)
  let rows := (List.range dev.base.length).map perRow
  { dev with base := rows.map (·.1), was := rows.map (·.2), cursor := 0, epoch := er.epoch,
             pending := [], afterReset := true }

def markHeld (w : World) (v : Nat) : World :=
  { w with vers := modAt w.vers (v - 1) fun i => { i with held := true } }

def serverRowsAbove (s : Server) (c : Nat) : List (Nat × SRow) :=
  let rs := (indexed s.rows).filterMap fun (i, o) =>
    match o with
    | some row => if c < row.seq then some (i, row) else none
    | none => none
  rs.mergeSort fun a b => decide (a.2.seq ≤ b.2.seq)

/-- One pull chain to head. The GET follows the RPC and the scripted
restore swaps data and epoch in one transaction, so one atomic read of
both is what the device sees. -/
def pull (R : Rules) (w0 : World) (d : Nat) : World := Id.run do
  let dev0 := w0.devs.getD d default
  let er := w0.srv.er
  let dev1 := if er.epoch != dev0.epoch then resetDev R dev0 er else dev0
  if er.paused then
    return { w0 with devs := setAt w0.devs d { dev1 with gate := false } }
  let rows := serverRowsAbove w0.srv dev1.cursor
  let mut dev := { dev1 with gate := true }
  let mut w := w0
  for (r, row) in rows do
    let (dev', adopted) := applyIncoming R.lost dev r row
    dev := dev'
    if adopted then w := markHeld w row.ver
  let seen := rows.map (·.1)
  let cursor := rows.foldl (fun m x => max m x.2.seq) dev.cursor
  let mut base := dev.base
  -- pending-verify at head: unseen and the entry still carries the sent
  -- seq ⇒ the write was content-identical ⇒ hash := sentHash
  for (id, sentSeq, sentHash) in dev.pending do
    if !(seen.contains id) then
      if baseSeq (base.getD id .none) == some sentSeq then
        base := setAt base id (.known sentHash sentSeq)
  -- after a reset: entries never seen at head become `?` (→ POST)
  if dev.afterReset then
    base := (indexed base).map fun (i, b) =>
      if b != .none && !(seen.contains i) then .unk else b
  dev := { dev with base := base, cursor := cursor, pending := [], afterReset := false }
  return { w with devs := setAt w.devs d dev }

/-- One flush: every dirty row not in the pending set. PATCH when the
entry has a seq, ignore-duplicates POST when it has none. The send marks
`?@seq` / `?`; a `[row]` / insert writes `(sent, row.seq)`. -/
def flush (w : World) (d : Nat) : World := Id.run do
  let dev0 := w.devs.getD d default
  if !dev0.gate then return w
  let mut dev := dev0
  let mut s := w.srv
  for r in List.range dev0.loc.length do
    if dev.pending.any (·.1 == r) then continue
    match dev.loc.getD r none with
    | none => pure ()
    | some c =>
      let b := dev.base.getD r .none
      if baseHash b == some c then continue
      match baseSeq b with
      | some sq =>
        let hit := match s.rows.getD r none with
          | some row => row.seq == sq && row.ver != c
          | none => false
        if hit then
          let (s', n) := if s.triggers then s.issue else (s, sq)
          s := { s' with rows := setAt s'.rows r (some ⟨c, n⟩) }
          dev := { dev with base := setAt dev.base r (.known c n) }
        else
          dev := { dev with base := setAt dev.base r (.unkAt sq),
                            pending := dev.pending ++ [(r, sq, c)] }
      | none =>
        match s.rows.getD r none with
        | none =>
          let (s', n) := s.issue
          s := { s' with rows := setAt s'.rows r (some ⟨c, n⟩) }
          dev := { dev with base := setAt dev.base r (.known c n) }
        | some _ =>
          -- DO NOTHING, a seq burned; awaiting the echo with `?`
          s := s.issue.1
          dev := { dev with base := setAt dev.base r .unk }
  return { w with srv := s, devs := setAt w.devs d dev }

def newVer (w : World) (info : VerInfo) : World × Nat :=
  ({ w with vers := w.vers ++ [info] }, w.vers.length + 1)

def edit (w : World) (d r : Nat) : World :=
  let dev := w.devs.getD d default
  let parent := (dev.loc.getD r none).getD 0
  let (w, v) := newVer w ⟨r, parent, false, true, false⟩
  { w with devs := modAt w.devs d fun dv =>
      { dv with loc := setAt dv.loc r (some v), was := setAt dv.was r none } }

/-- An agent / MCP / edge-function write (service role, no seq filter). -/
def agent (R : Rules) (w : World) (r : Nat) : World :=
  let s := w.srv
  match s.rows.getD r none with
  | some row =>
    let (w, v) := newVer w ⟨r, row.ver, true, false, false⟩
    let (s', n) := if s.triggers || R.stampDuringRollback then s.issue else (s, row.seq)
    { w with srv := { s' with rows := setAt s'.rows r (some ⟨v, n⟩) } }
  | none =>
    let (w, v) := newVer w ⟨r, 0, true, false, false⟩
    let (s', n) := s.issue
    { w with srv := { s' with rows := setAt s'.rows r (some ⟨v, n⟩) } }

def parentOf (w : World) (v : Nat) : Nat := (w.vers.getD (v - 1) default).parent

/-- `a` is `b` or an ancestor of `b` (parents strictly precede children,
so `b` steps bound the walk). -/
def ancOrEq (w : World) (a b : Nat) : Bool :=
  go b (b + 1)
where
  go : Nat → Nat → Bool
    | _, 0 => false
    | x, fuel + 1 => if x == a then true else if x == 0 then false else go (parentOf w x) fuel

/-- A restore from `D` rolls back past every existing version that is not
in the history the dump kept for its row (neither the dump's version nor
an ancestor of it): created after the dump, or created before it and
pushed after it. Every other version is kept, including one an earlier
restore rolled back: the flag is re-judged, never sticky (the prior
checker only ever set it and so read `restoreKeepsAgain`'s revert as
allowed). -/
def markRolledBack (w : World) (D : Dump) : World :=
  { w with vers := (indexed w.vers).map fun (i, v) =>
      let kept := match (D.rows.getD v.row none) with
        | some row => ancOrEq w (i + 1) row.ver
        | none => false
      { v with rolledBack := !kept } }

/-! ## Operator steps -/

def freshEpoch (w : World) : World × Nat :=
  ({ w with nextEpoch := w.nextEpoch + 1 }, w.nextEpoch)

def maxRowSeq (s : Server) : Nat :=
  s.rows.foldl (fun m o => match o with | some r => max m r.seq | none => m) 0

/-- `restore_with_epoch.sql` run on its own; it ends with `paused = true`
(the operator clears it separately, `Act.unpause`). -/
def standaloneStep (R : Rules) (w : World) : World :=
  if !R.epochStep then
    let s := w.srv
    let c := s.counter + J
    { w with srv := { s with counter := c, highWater := max s.highWater c,
                             er := { s.er with paused := false } } }
  else
    let s := w.srv
    let F := match R.fMode with
      | .counter => s.counter
      | .maxRows => max s.counter (maxRowSeq s)
      | .rows => maxRowSeq s
    let L := match R.lMode with
      | .counter => F
      | .jump => F + J
      | .oracle => max F s.highWater
      | .oracleOver => max F s.highWater + J
    let (w, e) := freshEpoch w
    let s := w.srv
    let c := max s.counter L
    { w with srv := { s with counter := c, highWater := max s.highWater c,
                             er := { epoch := e, floor := F, lost := addLost s.er.lost F L,
                                     paused := true } } }


def dump (w : World) (withEpoch : Bool) : World :=
  { w with dumps := w.dumps ++ [⟨w.srv.rows, w.srv.counter,
      if withEpoch then some w.srv.er else none⟩] }

/-- `restore.sh` (either path): one transaction of TRUNCATE (incl.
`sync_epoch`), data.sql with the `sync_seq` setval stripped (F = its
value), then `restore_with_epoch` with L = the live counter:
`lost := <the restored row's lost> + (F, L]`, new epoch, `paused = true`. -/
def restoreScript (R : Rules) (w0 : World) (k : Nat) : World :=
  let D := w0.dumps.getD k default
  if R.refuseNoEpoch && D.epochRow.isNone then w0 else
  let w := markRolledBack w0 D
  let s := w.srv
  if !R.epochStep then
    let c := s.counter + J
    { w with srv := { s with rows := D.rows, counter := c, highWater := max s.highWater c } }
  else
    let L := match R.lMode with
      | .oracle => max s.counter s.highWater
      | .oracleOver => max s.counter s.highWater + J
      | _ => s.counter
    let F := match R.fMode with
      | .counter => D.counter
      | .maxRows => max D.counter (maxRowSeq { s with rows := D.rows })
      | .rows => maxRowSeq { s with rows := D.rows }
    let restored := match D.epochRow with
      | some e => e.lost
      | none => []
    let carry := match R.carry with
      | .never => false
      | .always => true
      | .noRow => D.epochRow.isNone
    let base := if carry then unionLost restored s.er.lost else restored
    let (w, e) := freshEpoch w
    let s := w.srv
    let c := max s.counter L
    { w with srv := { s with rows := D.rows, counter := c, highWater := max s.highWater c,
                             er := { epoch := e, floor := F, lost := addLost base F L,
                                     paused := true } } }

/-- The documented psql restore without the script: data.sql's setval
rewinds the counter to the dump's; the `sync_epoch` row comes back from
the dump if the dump has it, otherwise the live row stays. -/
def bypass (w0 : World) (k : Nat) : World :=
  let D := w0.dumps.getD k default
  let w := markRolledBack w0 D
  { w with srv := { w.srv with rows := D.rows, counter := D.counter,
                               er := D.epochRow.getD w.srv.er } }

/-- The same bypass into a NEW project. A dump with the `sync_epoch` row
brings it back as above; a dump without it leaves the row the new
project's migrations seeded (new random epoch, floor 0, empty `lost`),
unless the rule copies the OLD project's `lost` into it first. -/
def bypassNew (R : Rules) (w0 : World) (k : Nat) : World :=
  let D := w0.dumps.getD k default
  let w := markRolledBack w0 D
  let (w, er) := match D.epochRow with
    | some e => (w, e)
    | none =>
      let (w, e) := freshEpoch w
      (w, { epoch := e, floor := 0, paused := false,
            lost := if R.newBypassCarry then w.srv.er.lost else [] })
  { w with srv := { w.srv with rows := D.rows, counter := D.counter, er := er } }

/-- A non-script restore that aborted after data.sql's setval ran: the
data and the epoch row roll back, the counter does not. -/
def abortSetval (w : World) (k : Nat) : World :=
  let D := w.dumps.getD k default
  { w with srv := { w.srv with counter := D.counter } }

/-- `paused := true`, wait W (every device's gate expires), drop the
triggers. -/
def rollback (w : World) : World :=
  { w with srv := { w.srv with triggers := false, er := { w.srv.er with paused := true } },
           devs := w.devs.map fun d => { d with gate := false },
           rolledBackMode := true }

/-- Triggers back, then the standalone epoch step (which ends paused). -/
def reenable (R : Rules) (w : World) : World :=
  let srv := { w.srv with triggers := true }
  let srv := if R.restampOnReenable then
      srv.rows.length.fold (init := srv) fun i _ s =>
        match s.rows.getD i none with
        | some row => let (s', n) := s.issue; { s' with rows := setAt s'.rows i (some ⟨row.ver, n⟩) }
        | none => s
    else srv
  standaloneStep R { w with srv := srv, rolledBackMode := false }

/-- The operator clears `paused` once the post-checks pass. -/
def unpause (w : World) : World :=
  { w with srv := { w.srv with er := { w.srv.er with paused := false } } }

inductive Act where
  | edit (d r : Nat)
  | pull (d : Nat)
  | flush (d : Nat)
  | agent (r : Nat)
  | dump (withEpoch : Bool)
  | restore (k : Nat)
  | bypass (k : Nat)
  | bypassNew (k : Nat)
  | abortSetval (k : Nat)
  | standalone
  | rollback
  | reenable
  | unpause
deriving BEq, Repr, Inhabited

/-- Operator actions count against `Bounds.maxOps`; clearing `paused` does
not (it only closes a window an epoch step opened). -/
def Act.isOp : Act → Bool
  | .edit .. | .pull _ | .flush _ | .agent _ | .unpause => false
  | _ => true

/-- `prompt`: a bypassed or aborted restore is followed at once by the
standalone epoch step (ops/README.md R3, "immediately"), before any
device acts. Without it the window in between is open (§9.37 residual). -/
def step (R : Rules) (prompt : Bool) (w : World) (a : Act) : World :=
  let w := if a.isOp then { w with ops := w.ops + 1 } else w
  match a with
  | .edit d r => edit w d r
  | .pull d => pull R w d
  | .flush d => flush w d
  | .agent r => agent R w r
  | .dump b => dump w b
  | .restore k => restoreScript R w k
  | .bypass k => let w := bypass w k; if prompt then standaloneStep R w else w
  | .bypassNew k => let w := bypassNew R w k; if prompt then standaloneStep R w else w
  | .abortSetval k => let w := abortSetval w k; if prompt then standaloneStep R w else w
  | .standalone => standaloneStep R w
  | .rollback => rollback w
  | .reenable => reenable R w
  | .unpause => unpause w

def run (R : Rules) (prompt : Bool) (w : World) (tr : List Act) : World :=
  tr.foldl (step R prompt) w

/-! ## Quiescence and the property -/

def settleRounds : Nat := 8

def round (R : Rules) (w : World) : World :=
  flush (pull R (flush (pull R w 0) 0) 1) 1

def settleGo (R : Rules) : Nat → World → Option World
  | 0, _ => none
  | n + 1, w =>
    let w' := round R w
    if w' == w then some w else settleGo R n w'

def settle (R : Rules) (w : World) : Option World :=
  let w := if w.rolledBackMode then reenable R w else w
  settleGo R settleRounds (if w.srv.er.paused then unpause w else w)

/-- A live row's seq is inside `lost` — what the ops check P10
(`post_apply_checks.sql`) looks for after a restore. Not part of `check`:
the search counts such worlds (`Stats.p10`). -/
def liveInLost (w : World) : Bool :=
  w.srv.rows.any fun o => match o with
    | some r => inLost w.srv.er.lost r.seq
    | none => false

def protectedVer (i : VerInfo) : Bool := i.held || (i.byAgent && !i.rolledBack)

def live (w : World) (r : Nat) : Option Nat := (w.srv.rows.getD r none).map (·.ver)

/-- `none` = the property holds; `some reason` otherwise. -/
def checkSettled (w : World) : Option String := Id.run do
  let nrows := w.srv.rows.length
  -- P1
  for (d, dev) in indexed w.devs do
    if dev.epoch != w.srv.er.epoch then return some s!"P1 device {d} epoch"
    if !dev.pending.isEmpty then return some s!"P1 device {d} pending"
    for r in List.range nrows do
      let lv := live w r
      if dev.loc.getD r none != lv then
        return some s!"P1 device {d} row {r}: local {dev.loc.getD r none} server {lv}"
      if lv.isSome && baseHash (dev.base.getD r .none) != lv then
        return some s!"P1 device {d} row {r}: dirty"
  -- survivors
  let survivors := (List.range nrows).filterMap (live w) ++ (w.devs.map (·.shelf)).flatten
  -- P2
  for (i, info) in indexed w.vers do
    let v := i + 1
    if protectedVer info && !(survivors.any fun u => ancOrEq w v u) then
      return some s!"P2 lost version {v} (row {info.row})"
  -- P3, then the strict reading P3s
  let mut strict : Option String := none
  for (i, info) in indexed w.vers do
    let v := i + 1
    if protectedVer info && !info.rolledBack then
      match live w info.row with
      | some lw => if lw != v && ancOrEq w lw v then
          if (w.vers.getD (lw - 1) default).rolledBack then
            strict := strict.orElse fun _ =>
              some s!"P3s row {info.row} reverted onto resurrected {lw} over {v}"
          else
            return some s!"P3 row {info.row} reverted to {lw} over {v}"
      | none => pure ()
  return strict

def check (R : Rules) (w : World) : Option String :=
  match settle R w with
  | none => some "no quiescence"
  | some w' => checkSettled w'

/-! ## Start state and the bounded search -/

/-- X = version 1 at seq 1 on the server and both devices; Y (row 1, when
`rows = 2`) absent everywhere. -/
def initWorld (rows : Nat) : World :=
  let dev : Device :=
    { loc := (List.range rows).map fun i => if i == 0 then some 1 else none
      base := (List.range rows).map fun i => if i == 0 then .known 1 1 else .none
      cursor := 1, epoch := 0, gate := true, afterReset := false, pending := [], shelf := []
      was := (List.range rows).map fun _ => none }
  { srv := { rows := (List.range rows).map fun i => if i == 0 then some ⟨1, 1⟩ else none
             counter := 1, er := ⟨0, 0, [], false⟩, triggers := true, highWater := 1 }
    devs := [dev, dev], dumps := [], vers := [⟨0, 0, false, true, false⟩],
    nextEpoch := 1, rolledBackMode := false, ops := 0 }

structure Bounds where
  rows : Nat
  depth : Nat
  maxOps : Nat
  maxDumps : Nat
  prompt : Bool
  /-- include the agent write (needed for rollback scenarios) -/
  agent : Bool := true
  /-- include the non-script operator actions: bypass, aborted setval,
  `restore_with_epoch` alone -/
  offScript : Bool := true
  /-- include rollback / re-enable -/
  rollbacks : Bool := true
  /-- a hand restore (bypass, also into a new project) may use a dump that
  has no `sync_epoch` row -/
  noRowHand : Bool := true
deriving Repr

def enabled (B : Bounds) (w : World) : List Act :=
  let dev : List Act := [0, 1].flatMap fun d =>
    ((List.range B.rows).map fun r => Act.edit d r) ++ [Act.pull d, Act.flush d]
  let ag : List Act := if B.agent then (List.range B.rows).map Act.agent else []
  let unp : List Act := if w.srv.er.paused && !w.rolledBackMode then [Act.unpause] else []
  let opsLeft := w.ops < B.maxOps
  let ops : List Act :=
    if !opsLeft then []
    else if w.rolledBackMode then [Act.reenable]
    else
      (if w.dumps.length < B.maxDumps then [Act.dump true, Act.dump false] else [])
      ++ ((List.range w.dumps.length).flatMap fun k =>
            if !B.offScript then [Act.restore k]
            else if B.noRowHand || (w.dumps.getD k default).epochRow.isSome then
              [Act.restore k, Act.bypass k, Act.bypassNew k, Act.abortSetval k]
            else [Act.restore k, Act.abortSetval k])
      ++ (if B.offScript then [Act.standalone] else [])
      ++ (if B.rollbacks then [Act.rollback] else [])
  dev ++ ag ++ unp ++ ops

/-- Devices are interchangeable: a world and its device swap have the same
futures up to renaming, so the visited set keys on one of the two. -/
def canon (w : World) : World :=
  let w' := { w with devs := w.devs.reverse }
  if hash w' < hash w then w' else w

structure Stats where
  states : Nat := 0
  violations : Nat := 0
  /-- per failure class (`P1`, `P2`, `P3`, `no quiescence`): count and a
  shortest witness -/
  byClass : List (String × Nat × List Act × String) := []
  /-- worlds (before settling) with a live row's seq in `lost` (P10) -/
  p10 : Nat := 0
deriving Repr

def Stats.count (st : Stats) (cls : String) : Nat :=
  match st.byClass.find? (·.1 == cls) with
  | some e => e.2.1
  | none => 0

/-- Violations of P1, P2, P3 or quiescence — everything but `P3s`. -/
def Stats.hard (st : Stats) : Nat := st.violations - st.count "P3s"

def Stats.record (st : Stats) (tr : List Act) (why : String) : Stats :=
  let cls := (why.splitOn " ").headD why
  let byClass :=
    if st.byClass.any (·.1 == cls) then
      st.byClass.map fun e => if e.1 == cls then (e.1, e.2.1 + 1, e.2.2) else e
    else st.byClass ++ [(cls, 1, tr.reverse, why)]
  { st with violations := st.violations + 1, byClass }

/-- Breadth-first over every action sequence of length ≤ `B.depth`
within the operator budget, deduplicated on the (canonical) world; every
distinct world is settled and checked once. The first violation found is
a shortest one. -/
def search (R : Rules) (B : Bounds) : Stats := Id.run do
  let w0 := initWorld B.rows
  let mut seen : Std.HashSet World := Std.HashSet.emptyWithCapacity 1024
  seen := seen.insert (canon w0)
  let mut frontier : Array (World × List Act) := #[(w0, [])]
  let mut st : Stats := {}
  for _ in List.range (B.depth + 1) do
    let mut next : Array (World × List Act) := #[]
    for (w, tr) in frontier do
      st := { st with states := st.states + 1, p10 := st.p10 + (if liveInLost w then 1 else 0) }
      match check R w with
      | some why =>
        st := st.record tr why
      | none => pure ()
      if tr.length < B.depth then
        for a in enabled B w do
          let w' := step R B.prompt w a
          let key := canon w'
          if !seen.contains key then
            seen := seen.insert key
            next := next.push (w', a :: tr)
    frontier := next
  return st

/-! ## Rule variants

The positive controls must be caught; the recommended rule must pass;
each ablation of it (one part removed or swapped) must be caught again,
which is what makes every part load-bearing. -/

def x4 : Rules := { name := "control X4: setval upward, no epoch/floor", epochStep := false }
def x5 : Rules := { name := "control X5: reset keeps hash and seq", reset := .keepAll }
def localWins : Rules := { name := "control: local wins after any epoch change", reset := .allSentinel }

/-- The smallest change found that passes every bounded scenario (P1, P2,
P3; P3s is reported, see the header) outside the two residual families:

* the standalone epoch step takes the highest seq ever handed out from
  the operator (`--last-seq`, as the new-project path already does) and
  adds `(F, last_seq]` with `F` the highest seq any live row carries (the
  counter is not read), then sets the counter to `last_seq` if it is
  below it;
* `restore.sh` writes `lost := <the dump's own row's lost> ∪ (F, L]` with
  `F` the highest seq among the restored rows, and nothing else: the live
  `lost` is not carried over (`abCarry`: a range a restore of an older
  dump recorded then covers versions the newer dump kept). A dump without
  the `sync_epoch` row is refused: neither carrying the live `lost`
  (`abAcceptCarry`) nor going without it (`abAcceptBare`) is right for it;
* the rollback keeps stamping `seq := nextval` on every UPDATE;
* after a bypass into a new project with a dump that has no `sync_epoch`
  row, the step's base is the old project's `lost` (inside the residual
  family only; `abNewBypassFresh`);
* device side: a reset that keeps an entry's hash keeps its old seq too,
  read only by the next reset's `lost` test (without it a device that
  reset and did not reach head before the next epoch change can no longer
  tell that its copy was lost); and a reset that finds the local copy
  lost remembers its hash and seq while the local value stays that
  version, so a later reset whose `lost` no longer has the seq takes the
  copy as the kept base instead of pushing it over a newer version a
  later restore brought back (`abForgetLost`).

Under it `lost` names exactly the seqs whose write is not in the live
history (P10 holds in every searched world outside the residual
families; see the `p10` guards and the search's counts). -/
def recommended : Rules :=
  { name := "recommended: last-seq + F from the rows + the dump's own lost, refuse a dump without sync_epoch + stamp during rollback + class seq + remember the lost copy",
    lMode := .oracle, fMode := .rows, carry := .never, refuseNoEpoch := true, stampDuringRollback := true,
    keepClassSeq := true, rememberLost := true, newBypassCarry := true }

/-- The rule the previous round recommended: `F = max(counter, rows)`,
`restore.sh` carries the live `lost` into every restore and takes a dump
without the `sync_epoch` row, no lost-copy memory. -/
def prior : Rules :=
  { recommended with
    name := "prior round: F = max(counter, rows) + carry the live lost into every restore + no lost-copy memory"
    fMode := .maxRows, carry := .always, refuseNoEpoch := false, rememberLost := false }

def abJump : Rules :=
  { recommended with
    name := "ablation: (F, F+J] jump instead of last-seq"
    lMode := .jump }
def altOvershoot : Rules :=
  { recommended with
    name := "alternative: last-seq overestimated by J"
    lMode := .oracleOver }
def abNoLastSeq : Rules :=
  { recommended with
    name := "ablation: no last-seq (range (F, F], as written)"
    lMode := .counter }
def abCounterFloor : Rules :=
  { recommended with
    name := "ablation: F = counter (no max(seq))"
    fMode := .counter }
def abMaxRowsF : Rules :=
  { recommended with
    name := "ablation: F = max(counter, max(seq)) (the prior round's F)"
    fMode := .maxRows }
def abCarry : Rules :=
  { recommended with
    name := "ablation: restore.sh carries the live lost into every restore"
    carry := .always }
def abAcceptCarry : Rules :=
  { recommended with
    name := "ablation: restore.sh takes a dump without sync_epoch and carries the live lost"
    refuseNoEpoch := false
    carry := .noRow }
def abAcceptBare : Rules :=
  { recommended with
    name := "ablation: restore.sh takes a dump without sync_epoch, no carry"
    refuseNoEpoch := false }
def abNoStamp : Rules :=
  { recommended with
    name := "ablation: rollback UPDATEs keep the old seq (as written)"
    stampDuringRollback := false }
def altRestamp : Rules :=
  { recommended with
    name := "alternative: re-enable restamps every row instead of stamping"
    stampDuringRollback := false
    restampOnReenable := true }
def abForgetSeq : Rules :=
  { recommended with
    name := "ablation: the reset forgets the seq of the entries it keeps (as written)"
    keepClassSeq := false }
def abForgetLost : Rules :=
  { recommended with
    name := "ablation: the reset forgets the hash and seq of a lost copy (as written)"
    rememberLost := false }
def abNewBypassFresh : Rules :=
  { recommended with
    name := "ablation: new-project bypass keeps the freshly seeded empty lost"
    newBypassCarry := false }
def devRemoteWins : Rules :=
  { recommended with
    name := "device variant: post-step write beats a lost `?`"
    lost := .remoteWins }
def devHybrid : Rules :=
  { recommended with
    name := "device variant: post-step write beats an unchanged lost `?`"
    lost := .hybrid }

/-! ## Replayed scenarios

Row 0 is X; device 0 is A, device 1 is B. Each list is a scenario; the
verdict settles it and checks it. -/

def w1 : World := initWorld 1

/-- Checker MAJOR (1): A writes c_a after the dump; a restore bypasses
`restore.sh` (data.sql's setval rewinds the counter); the standalone step
(R3) runs at once and, as written, adds the empty range (L, L]. -/
def major1 : List Act := [.dump true, .edit 0 0, .flush 0, .bypass 0]

/-- Checker minor (2): A writes c_a after dump 0 and goes offline;
`restore.sh` restores dump 0 (c_a's seq is in its lost range); a dump
WITHOUT `sync_epoch` is taken; `restore.sh --replace` restores it —
TRUNCATE drops the row and the earlier range with it. (The recommended
rule refuses that second restore.) -/
def minor2 : List Act := [.dump true, .edit 0 0, .flush 0, .restore 0, .dump false, .restore 1]

/-- §6.6 counterexample (2), the lagging device: B never pulled A's
pre-dump edit; a restore of a dump that contains it. -/
def lagging : List Act := [.edit 0 0, .flush 0, .dump true, .restore 0]

/-- A scripted restore that loses A's post-dump write. -/
def scripted : List Act := [.dump true, .edit 0 0, .flush 0, .restore 0]

/-- Two bypassed restores of one old dump, each followed at once by the
standalone step: a fixed jump covers only the first rewind. -/
def twoBypass : List Act := [.dump true, .bypass 0, .edit 0 0, .flush 0, .bypass 0]

/-- An aborted non-script restore (setval ran) and the standalone step:
nothing was restored, so the step must not declare live versions lost —
B holds A's first edit, A's second edit is live. -/
def abortLagging : List Act :=
  [.dump true, .edit 0 0, .flush 0, .pull 1, .edit 0 0, .flush 0, .abortSetval 0]

/-- A dump, then a rollback in which the agent edits X (the UPDATE keeps
X's old seq), re-enable, the operator clears `paused`, A adopts the
agent's edit, then a restore of the pre-rollback dump: A's entry names
the agent's version by a seq the dump also uses for the older version,
so it is not in `lost`. -/
def rollbackRestore : List Act :=
  [.dump true, .rollback, .agent 0, .reenable, .unpause, .pull 0, .restore 0]

/-- Re-stamping at re-enable instead: the restored version's live seq
lands in `lost`, so A's copy of the very version the dump restores
reads `?` and reverts the agent's post-restore edit. -/
def restampRevert : List Act :=
  [.dump true, .rollback, .reenable, .unpause, .pull 0, .restore 0, .agent 0]

/-- The fork cost (P3s): A and B both hold c_a, which the restore loses;
A edits it again before either detects; A detects first and pushes, B's
`?` then beats A's newer edit (shelved on B). -/
def forkRevert : List Act := [.edit 0 0, .dump true, .flush 0, .pull 1, .restore 0, .edit 0 0]

/-- Second independent check, finding 1: A resets inside a paused window
(the step after an aborted setval, then a rollback), its chain is
abandoned, so the entry keeps its hash and loses its seq; the restore of
the old dump then puts that seq in `lost`, but A can no longer tell. -/
def resetAbandon : List Act :=
  [.edit 0 0, .dump true, .flush 0, .abortSetval 0, .rollback, .pull 0, .reenable, .restore 0]

/-- Second independent check, finding 2: the paused window a scripted
restore ends with. Restoring the newer dump loses nothing; A pulls while
it is paused (reset, abandon); the operator then restores the older
dump instead. -/
def pausedRestore : List Act :=
  [.dump true, .edit 0 0, .flush 0, .dump true, .restore 1, .pull 0, .restore 0]

/-- The same in six steps: the standalone step's own paused window. -/
def stepThenRestore : List Act := [.edit 0 0, .dump true, .flush 0, .standalone, .pull 0, .restore 0]

/-- Second independent check, finding 3: c_a's seq is in the first
restore's `lost`; a dump without `sync_epoch` is then restored into a new
project by hand, whose seeded row has an empty `lost`. -/
def newBypass : List Act :=
  [.dump true, .edit 0 0, .flush 0, .restore 0, .dump false, .bypassNew 1]

/-- Third independent check, finding 1: a hand restore of dump 1 brings
back its old `sync_epoch` row, whose `lost` predates the scripted restore
of dump 0, and the standalone step runs at once; `restore.sh` then
restores dump 2, taken without the row after that scripted restore. The
prior rule's carry finds nothing to carry and its `F` (the dump's setval
value) sits above c_a's seq. -/
def bypassOldRow : List Act :=
  [.edit 0 0, .dump true, .flush 0, .dump true, .restore 0, .dump false, .bypass 1, .restore 2]

/-- The same, with the two restores swapped: the scripted one restores
the dump with its row, the hand restore the dump without it. Only the
residual family has it; `F` from the rows is what still names c_a's seq
(`abMaxRowsF`). -/
def noRowBypass : List Act :=
  [.edit 0 0, .dump true, .flush 0, .dump true, .restore 0, .dump false, .restore 1, .bypass 2]

/-- Third independent check, finding 2: dump 1 holds the agent's edit on
top of c_a; `restore.sh` restores the older dump 0 (c_a and the agent's
edit lost), then dump 1 (both kept again). A carried range from the first
restore covers c_a's seq, A's `?` pushes c_a over the agent's edit. -/
def restoreKeepsAgain : List Act :=
  [.edit 0 0, .dump true, .flush 0, .agent 0, .dump true, .restore 0, .restore 1]

/-- As `restoreKeepsAgain`, but A pulls in the paused window after the
first restore (reset to `?`, chain abandoned): without the lost-copy
memory the `?` outlives the second restore. -/
def keepAgainPaused : List Act :=
  [.edit 0 0, .dump true, .flush 0, .agent 0, .dump true, .restore 0, .pull 0, .restore 1]

/-- As `keepAgainPaused`, but the chain reaches head: the `?` loses to
nothing, A keeps c_a as a local edit over the restored row, and the
second restore's reset sees an ordinary conflict. -/
def keepAgainHead : List Act :=
  [.edit 0 0, .dump true, .flush 0, .agent 0, .dump true, .restore 0, .unpause, .pull 0, .restore 1]

/-- As `keepAgainHead`, and A pushes c_a again (a new seq, lost by the
second restore) before it. -/
def keepAgainFlush : List Act :=
  [.edit 0 0, .dump true, .flush 0, .agent 0, .dump true, .restore 0, .unpause, .pull 0, .flush 0,
   .restore 1]

/-- `restoreKeepsAgain` with dump 1 taken without its `sync_epoch` row:
carrying the live `lost` into it reverts the agent's edit. -/
def noRowKeepsAgain : List Act :=
  [.edit 0 0, .dump true, .flush 0, .agent 0, .dump false, .restore 0, .restore 1]

/-- A dump without its row taken after a fork: c_a is lost by the first
restore, the agent edits the restored row, the dump keeps only that edit.
Restoring it without any carried range loses c_a. -/
def forkNoRow : List Act :=
  [.dump true, .edit 0 0, .flush 0, .restore 0, .agent 0, .dump false, .restore 1]

/-- `forkNoRow` restored by hand into a new project (residual family):
the old project's `lost` is what still names c_a's seq. -/
def forkNoRowNew : List Act :=
  [.dump true, .edit 0 0, .flush 0, .restore 0, .agent 0, .dump false, .bypassNew 1]

/-- `noRowKeepsAgain` restored by hand (residual family): the live row the
hand restore leaves in place carries the first restore's range, which
covers the versions the dump kept. Every rule fails it. -/
def noRowBypassRevert : List Act :=
  [.edit 0 0, .dump true, .flush 0, .agent 0, .dump false, .restore 0, .bypass 1]

/-- Third independent check, finding 3: restoring the older dump and then
the newer one leaves the newer dump's live row inside the carried range,
which P10 rejects. -/
def newerAfterOlder : List Act := [.dump true, .agent 0, .dump true, .restore 0, .restore 1]

def verdict (R : Rules) (tr : List Act) : Option String := check R (run R true w1 tr)

/-- Second independent check, finding 4: the standalone step WITHOUT the
lock the design requires. It reads `F`, an agent write then takes
`nextval` (`F + 1`), and the step's `setval` and upsert follow; the live
row's seq is inside the new `lost`. -/
def standaloneRace (R : Rules) (w : World) (r : Nat) : World :=
  let s := w.srv
  let F := match R.fMode with
    | .counter => s.counter
    | .maxRows => max s.counter (maxRowSeq s)
    | .rows => maxRowSeq s
  let L := max F s.highWater
  let w := agent R w r
  let (w, e) := freshEpoch w
  let s := w.srv
  let c := max s.counter L
  { w with srv := { s with counter := c, highWater := max s.highWater c,
                           er := { epoch := e, floor := F, lost := addLost s.er.lost F L,
                                   paused := true } } }

/-- After a bypass, the racing step; both devices adopt the agent's row,
A edits it, and any later epoch step makes B's entry `?`. -/
def raceTail : List Act := [.unpause, .pull 0, .pull 1, .edit 0 0, .flush 0, .standalone]
def raceWorld (R : Rules) (locked : Bool) : World :=
  let w := bypass (run R true w1 [.dump true, .agent 0]) 0
  let w := if locked then agent R (standaloneStep R w) 0 else standaloneRace R w 0
  run R true w raceTail

def failsWith (R : Rules) (tr : List Act) (cls : String) : Bool :=
  match verdict R tr with
  | some why => (why.splitOn " ").headD "" == cls
  | none => false

-- the current text fails the checkers' findings
#guard failsWith current major1 "P2"
#guard failsWith current minor2 "P2"
#guard [resetAbandon, pausedRestore, stepThenRestore, newBypass].all (failsWith current · "P2")
-- positive controls
#guard failsWith x4 scripted "P1"
#guard failsWith x5 scripted "P1"
#guard failsWith localWins lagging "P3"
#guard verdict current lagging == none
-- the third check's findings fail the prior round's rule
#guard failsWith prior bypassOldRow "P2"
#guard failsWith prior restoreKeepsAgain "P3"
#guard liveInLost (run prior true w1 newerAfterOlder)
-- the recommended rule passes every replay but the fork cost and the
-- residual hand restore
#guard [major1, minor2, lagging, scripted, twoBypass, abortLagging, rollbackRestore, restampRevert,
        resetAbandon, pausedRestore, stepThenRestore, newBypass, bypassOldRow, noRowBypass,
        restoreKeepsAgain, keepAgainPaused, keepAgainHead, keepAgainFlush, noRowKeepsAgain, forkNoRow,
        forkNoRowNew, newerAfterOlder].all fun tr =>
  verdict recommended tr == none && verdict altOvershoot tr == none
#guard !liveInLost (run recommended true w1 newerAfterOlder)
#guard failsWith recommended forkRevert "P3s"
#guard [current, prior, recommended, abAcceptCarry, abAcceptBare].all (failsWith · noRowBypassRevert "P3")
-- each part is load-bearing
#guard failsWith abJump twoBypass "P2"
#guard failsWith abNoLastSeq major1 "P2"
#guard failsWith abCounterFloor abortLagging "P3"
#guard failsWith abMaxRowsF noRowBypass "P2"
#guard failsWith abCarry restoreKeepsAgain "P3"
#guard liveInLost (run abCarry true w1 newerAfterOlder)
#guard failsWith abAcceptCarry noRowKeepsAgain "P3"
#guard failsWith abAcceptBare forkNoRow "P2"
#guard failsWith abNoStamp rollbackRestore "P2"
#guard failsWith altRestamp restampRevert "P3"
#guard [resetAbandon, pausedRestore, stepThenRestore].all (failsWith abForgetSeq · "P2")
#guard [keepAgainPaused, keepAgainHead, keepAgainFlush].all (failsWith abForgetLost · "P3")
#guard failsWith abNewBypassFresh forkNoRowNew "P2"
-- the step's lock is load-bearing: without it the live row's seq lands in
-- `lost` and B's `?` later reverts A's newer edit; with it, nothing does
#guard (check recommended (raceWorld recommended false)).map (fun why => (why.splitOn " ").headD "") == some "P3"
#guard check recommended (raceWorld recommended true) == none

/-! ## Exhaustive, at build time (small bounds; the large ones are in
`lake exe syncrestoresearch`) -/

def buildBounds : Bounds :=
  { rows := 1, depth := 6, maxOps := 4, maxDumps := 2, prompt := true, noRowHand := false }

-- the current text has violations of P2 inside these bounds; the
-- recommended rule has none of P1, P2, P3 and never leaves a live row's
-- seq in `lost`; the prior round's rule does leave one; the X4 / X5 /
-- local-wins controls are caught
#guard (search current buildBounds).count "P2" > 0
#guard let st := search recommended buildBounds; st.hard == 0 && st.p10 == 0
#guard (search prior buildBounds).p10 > 0
#guard (search abForgetSeq buildBounds).count "P2" > 0
#guard (search x4 buildBounds).hard > 0
#guard (search x5 buildBounds).hard > 0
#guard (search localWins buildBounds).count "P3" > 0

end SyncRestore
end Verification
