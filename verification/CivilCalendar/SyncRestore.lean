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
syncrestoresearch` (the lost-range rules) and `lake exe checksearch` (the
simple rules and the final rule), and their sizes and state counts live
there, not here.

**Which rule is recommended.** On 2026-10-20 the lost-range rule (`lostRange`,
the sixth round's recommendation: `lost`, the floor, `--last-seq`, the carry,
stamping during a rollback, the device's class seq and lost-copy memory) was
abandoned for the simple rule with four patches, `final`, which is the
recommended rule. Everything before "The final rule" below describes the
earlier rules and stays as their comparison; `final` and its strict checker
are in the sections "The final rule's device", "The strict checker" and "The
final rule". What `final` adds to the model:

* **Deletes** (only when `Rules.final`): a device delete (no local row, the
  baseline entry stays: a delete not yet sent), its tombstone PATCH with no
  seq filter, an agent delete, tombstones with a seq on the server
  (`SRow.dead`; the content stays, I6), tombstones in a dump, and a
  tombstone insert for a pending delete whose row a restore removed.
* **The server write gate**: every device write, tombstones included, is
  rejected atomically with it when the epoch it carries is not current or
  sync is paused. Agent writes are refused while paused outside a rollback
  (`Rules.agentWhilePaused`; see the final rule's docstring for why).
* **The catch-up**: server wins, a differing local copy goes to the shelf,
  except that a local edit is kept when the incoming row is the old
  baseline or the version its edit chain started from; a pending delete
  wins; rows the server lacks are re-uploaded, and such an entry stays
  server-wins until the POST lands (`Rules.reupStale`).
* **The recovery prompt**: each catch-up shelf entry records the version it
  lost to and whether the prompt offers it; restore / later / discard
  (`Act.accept`, `.later`, `.discard`) and log-out / erase (`Act.erase`)
  with its warning.
* **The strict checker** (`judge`): every class a settled world has, a
  version counted as discarded by a restore only when its content reached
  the server (`Rules.rbPushedOnly`), the strengthened P2 (a protected
  version that is not live must be offered by the prompt somewhere), and
  the delete properties.

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

* Deletes and tombstones for the earlier rules (rows never die under
  them). Under `final`: a rollback's physical DELETE (agent deletes run
  only while the triggers are installed), the child-row cascade, undo of a
  delete, and the singleton tables' tombstone rule.
* The prompt's UI: "later" changes nothing in the model (the entries stay
  offered and the prompt shows again); what the prompt says is not
  modelled, only which entries it offers. A re-applied entry is the same
  version as the shelved one (same content); the row it replaced joins its
  history (`VerInfo.over`).
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
  /-- `0` = live. Otherwise the row is a tombstone (`deleted_at` set) and
  this is the delete version that killed it; `ver` stays the content the
  row had, which the server keeps (I6) -/
  dead : Nat := 0
  /-- the `.epoch` offer variant only: the row's seq when the last epoch
  step ran, carried by every later write of the row (`0`: the row was
  inserted since) -/
  ep : Nat := 0
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
  /-- read only by the `rbDocstring` checker: how many versions existed
  when the dump was taken, and which of them had reached the server -/
  nVers : Nat := 0
  pub : List Bool := []
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
  /-- the simple rule only (`ResetMode.stale`): an entry from before the
  last epoch change, not yet met by the catch-up pull. `h` is the old
  baseline hash when the entry had one; only the fast-forward refinement
  (`Rules.staleFF`) reads it. `s` is the old baseline seq, recorded only by
  the final rule, whose prompt reads it. Neither is a baseline: the skip
  row never fires on a stale entry and no flush can call it clean. -/
  | stale (h : Option Nat) (s : Option Nat)
deriving BEq, Hashable, Repr, Inhabited

/-- A conflict-shelf entry. The earlier rules record only the version; the
final rule also records what the device knew when it shelved it. -/
structure SEntry where
  ver : Nat
  row : Nat := 0
  /-- the version this entry lost to at a catch-up (for a tombstone, the
  delete version); `0` when the §6 table shelved it -/
  against : Nat := 0
  /-- shelved by the catch-up after an epoch change (otherwise by the §6
  table: a conflict, a pending delete meeting an edit, a tombstone) -/
  catchup : Bool := false
  /-- the recovery prompt offers it -/
  offered : Bool := false
  /-- the final rule: the device's own edit lost to a tombstone (the §6
  tombstone row shelved it) -/
  lostToDelete : Bool := false
  /-- ghost, read only by the checker: the version it first lost to -/
  lostTo : Nat := 0
  /-- for the device's own edit shelved by a catch-up, the version its edit
  chain started from (the remembered origin, else the old baseline); read
  only by the `originBack` candidate -/
  origin : Option Nat := none
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
  shelf : List SEntry
  /-- per row: `(hash, seq)` of the local copy as it was when a reset found
  it lost (`Rules.rememberLost`); cleared when the local value changes -/
  was : List (Option (Nat × Nat))
  /-- per row, the version the local edit chain started from (the local
  value when the row last went from clean to dirty); kept only under
  `Rules.staleFFOrigin` -/
  origin : List (Option Nat) := []
  /-- the final rule's deletes: per row, the delete version of a local
  delete whose tombstone has not been sent (`0` = none). The device side of
  it is the §6 shape: no local row, a baseline entry -/
  del : List Nat := []
  /-- the `.seqOwn` offer variant only: per row, the baseline came from the
  device's own write's response -/
  own : List Bool := []
  /-- the `acceptCond` candidate only: per row, the version the prompt's
  restore re-applied and the server has not yet acknowledged (`0` = none) -/
  acc : List Nat := []
deriving BEq, Hashable, Repr, Inhabited

structure VerInfo where
  row : Nat
  parent : Nat
  byAgent : Bool
  held : Bool
  rolledBack : Bool
  /-- the version was written to the server at some point (a device's
  push or an agent write); read only by the `rbPushedOnly` checker -/
  onServer : Bool
  /-- a delete: `parent` is the version the deleter held -/
  dead : Bool := false
  /-- versions an accepted prompt entry was re-applied over: the user chose
  this version over them, so they count as its history -/
  over : List Nat := []
  /-- ghost, the final rule's checker only: how many versions existed when
  a restore last found this one discarded -/
  rbAt : Nat := 0
  /-- ghost, the final rule's checker only: the writer had caught up with
  the server's current epoch when it wrote this version (an agent always
  has) -/
  post : Bool := false
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
  /-- ghost: some accepted prompt entry overwrote a version newer than the
  one it re-applied, or newer than the one it had lost to -/
  badAccept : Bool := false
  /-- ghost: versions the user let go through the prompt's discard or a
  confirmed log-out / erase -/
  dropped : List Nat := []
  /-- ghost: the synced local copies of devices that logged out or erased -/
  erased : List Nat := []
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
  /-- the simple rule: every entry becomes `stale` (server wins at the
  catch-up, the local copy goes to the shelf) -/
  | stale
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

/-- Which catch-up shelf entries the final rule's recovery prompt offers. -/
inductive OfferMode where
  /-- none: the shelf stays invisible (the prompt removed) -/
  | none
  /-- what the device can tell is newer than the server's row from what it
  stores: its own edit that had not been acknowledged (the local copy is not
  the old baseline's hash, or the old baseline was a send's `?`), or a clean
  copy whose old baseline seq is above the incoming row's seq (the server
  went back below it) -/
  | seq
  /-- every catch-up entry -/
  | all
  /-- candidate: as `seq`, and also a clean copy the device had pushed
  itself (its baseline came from its own write's response) -/
  | seqOwn
  /-- candidate needing a server column: as `seq`, but a clean copy is
  compared with the seq the row had at the last epoch step (`SRow.ep`)
  instead of the incoming row's own seq -/
  | epoch
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
  /-- the simple rule's server: `restore.sh`, the standalone step and the
  step inside re-enable write a new epoch and `paused = true` and nothing
  else (no floor, no `lost`, no carry, no `--last-seq`); the counter is
  set by `counterUp` / `stepRaise` -/
  epochOnly : Bool := false
  /-- with `epochOnly`: `restore.sh` sets the counter to `max(live
  counter, max seq of the restored rows)`; false = it keeps the dump's
  own setval (the counter rewinds) -/
  counterUp : Bool := true
  /-- with `epochOnly`: the standalone step raises the counter to
  `max(counter, max seq over the rows)`; false = it leaves the counter
  where it is -/
  stepRaise : Bool := true
  /-- with `ResetMode.stale`: a stale entry whose local copy differs from
  the incoming row puts the local copy in the shelf before adopting;
  false = it adopts without shelving -/
  staleShelf : Bool := true
  /-- refinement of the simple rule: a stale entry whose OLD baseline
  hash equals the incoming row keeps the local copy (the §6 echo row: the
  local edit was made on top of exactly what the server has) -/
  staleFF : Bool := false
  /-- with `ResetMode.stale`: an entry still stale when the catch-up
  reaches head (no row on the server) is re-uploaded by POST; false = the
  device takes its local copy as already synced and never sends it -/
  staleReupload : Bool := true
  /-- refinement of the simple rule (part of the final rule): the
  re-upload's entry stays `stale` (instead of becoming `?`), so when another
  device's re-upload of the row lands first the next pull lets the server
  win and shelves the local copy -/
  reupStale : Bool := false
  /-- every flush first reads the epoch row and sends nothing unless the
  device has seen the current epoch and `paused` is false (checked
  atomically with the write) -/
  epochGate : Bool := false
  /-- CHECKER option, not a rule: `rolledBack`, once set, stays set (a
  version a later restore brings back is not kept again); false = every
  restore re-judges every version (the checker's definition) -/
  sticky : Bool := false
  /-- CHECKER option, not a rule: report a P3 whose reverted-over version
  was built on a version a restore discarded as its own class `P3d` (still
  a hard violation) -/
  splitP3 : Bool := false
  /-- CHECKER option, not a rule: a restore rolls back only versions whose
  content reached the server (the version or a descendant of it was written
  there); an edit that only ever existed on a device is never counted as
  discarded by a restore -/
  rbPushedOnly : Bool := false
  /-- CHECKER option, not a rule: `markRolledBack` as its own docstring
  states it — a restore rolls back a version outside the dump's history
  only when it was created after the dump, or created before it and its
  content reached the server after it -/
  rbDocstring : Bool := false
  /-- refinement of the fast-forward: a stale entry also keeps the local
  edit when the incoming row is the version the local edit chain started
  from (the device remembers it per row; it survives the §6 conflict row
  and a send's `?@seq`) -/
  staleFFOrigin : Bool := false
  /-- the final rule's device code (`pullF`, `flushF`, deletes, the
  recovery prompt); its searches use the strict checker (`judge`) -/
  final : Bool := false
  /-- the final rule: which catch-up shelf entries the prompt offers -/
  offer : OfferMode := .none
  /-- the final rule: accept re-applies an entry only while the device
  holds, clean, the very version the entry was shelved against; false =
  over whatever clean version the device holds -/
  acceptGuard : Bool := true
  /-- the final rule: a pending local delete wins at the catch-up (§6's
  pending-delete row); false = the incoming row is adopted -/
  deleteWins : Bool := true
  /-- the final rule: an offered entry whose version arrives as the live
  row is resolved and leaves the prompt -/
  prune : Bool := true
  /-- the final rule: a send the server gate rejects leaves the marks the
  send wrote (`?@seq`, `?`), as every other failed send does (S4) -/
  gateMarks : Bool := true
  /-- the final rule: agent writes are accepted while `paused` outside a
  rollback; false = refused until the operator clears it -/
  agentWhilePaused : Bool := true
  /-- the final rule: log-out / erase warns when the shelf is not empty,
  so what it then wipes is the user's choice; false = it wipes it silently -/
  eraseWarn : Bool := true
  /-- the final rule: a pending delete whose row the server no longer has
  (a restore removed it) stays pending, and its tombstone is an insert of
  the dead row (ignore-duplicates), so a later re-upload of the row by
  another device finds it dead; false = the delete counts as done -/
  tombInsert : Bool := true
  /-- candidate, not part of the final rule: the prompt's restore sets the
  row's origin to the re-applied edit's own chain start (`SEntry.origin`);
  false = to the row it re-applied over -/
  originBack : Bool := false
  /-- candidate, not part of the final rule: the prompt's restore is a
  conditional write; when the row has moved on before it lands, the
  re-applied version goes back to the prompt against the row the server
  has, instead of winning a §6 conflict -/
  acceptCond : Bool := false
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
  | .stale _ _ => some (UNK, 0)

def baseSeq : BaseE → Option Nat
  | .known _ s => some s
  | .unkAt s => some s
  | _ => none

def baseHash : BaseE → Option Nat
  | .known h _ => some h
  | .hashOnly h _ => some h
  | _ => none

/-- The final rule's clean test also reads a stale entry's old hash. -/
def baseHashF : BaseE → Option Nat
  | .known h _ => some h
  | .hashOnly h _ => some h
  | .stale h _ => h
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
        | some c => dev.shelf ++ [{ ver := c }]
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
    let shelf' := if d.shelfRemote then dev.shelf ++ [{ ver := row.ver }] else dev.shelf
    let was' := if adopt then setAt dev.was r none else dev.was
    ({ dev with loc := loc', base := base', shelf := shelf', was := was' }, adopt)

/-- The simple rule's catch-up row: a `stale` entry meets the incoming
row. Equal content: clean on the incoming `(hash, seq)`. Otherwise the
server wins: the local copy goes to the shelf (`staleShelf`) and the
incoming row is adopted, unless the fast-forward refinement (`staleFF`)
sees that the local edit was made on top of exactly the incoming version.
Every other entry goes through `applyIncoming` unchanged. -/
def applyIncomingR (R : Rules) (dev : Device) (r : Nat) (row : SRow) : Device × Bool :=
  match dev.base.getD r .none with
  | .stale h _ =>
    let hLoc := dev.loc.getD r none
    let base' := setAt dev.base r (.known row.ver row.seq)
    if hLoc == some row.ver then ({ dev with base := base' }, false)
    else if R.staleFF && (h == some row.ver ||
        (R.staleFFOrigin && dev.origin.getD r none == some row.ver)) then ({ dev with base := base' }, false)
    else
      let shelf' := match hLoc with
        | some c => if R.staleShelf then dev.shelf ++ [{ ver := c }] else dev.shelf
        | none => dev.shelf
      ({ dev with loc := setAt dev.loc r (some row.ver), base := base', shelf := shelf' }, true)
  | _ => applyIncoming R.lost dev r row

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
    | .stale =>
      match b with
      | .none => .none
      | .stale h s => .stale h s
      | _ => .stale (baseHash b) none
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

/-- Under `staleFFOrigin`, forget the origin of every row whose local value
is clean against its baseline. -/
def clearOrigins (R : Rules) (dev0 : Device) : Device :=
  let dev := if !R.acceptCond then dev0 else
    { dev0 with acc := (List.range dev0.loc.length).map fun r =>
        if baseHash (dev0.base.getD r .none) == dev0.loc.getD r none then 0 else dev0.acc.getD r 0 }
  if !R.staleFFOrigin then dev else
  let bh : BaseE → Option Nat := if R.final then baseHashF else baseHash
  { dev with origin := (List.range dev.loc.length).map fun r =>
      if (bh (dev.base.getD r .none) == dev.loc.getD r none) then none
      else dev.origin.getD r none }

def markHeld (w : World) (v : Nat) : World :=
  { w with vers := modAt w.vers (v - 1) fun i => { i with held := true } }

def markOnServer (w : World) (v : Nat) : World :=
  { w with vers := modAt w.vers (v - 1) fun i => { i with onServer := true } }

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
    let (dev', adopted) := applyIncomingR R dev r row
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
      if b != .none && !(seen.contains i) then
        match b with
        | .stale h s =>
          if !R.staleReupload then
            match dev.loc.getD i none with
            | some c => .hashOnly c 0
            | none => .none
          else if R.reupStale then .stale h s else .unk
        | _ => .unk
      else b
  dev := { dev with base := base, cursor := cursor, pending := [], afterReset := false }
  return { w with devs := setAt w.devs d (clearOrigins R dev) }

/-- One flush: every dirty row not in the pending set. PATCH when the
entry has a seq, ignore-duplicates POST when it has none. The send marks
`?@seq` / `?`; a `[row]` / insert writes `(sent, row.seq)`. -/
def flush (R : Rules) (w : World) (d : Nat) : World := Id.run do
  let dev0 := w.devs.getD d default
  if !dev0.gate then return w
  if R.epochGate && (dev0.epoch != w.srv.er.epoch || w.srv.er.paused) then return w
  let mut dev := dev0
  let mut s := w.srv
  let mut pushedVs : List Nat := []
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
          s := { s' with rows := setAt s'.rows r (some { ver := c, seq := n }) }
          dev := { dev with base := setAt dev.base r (.known c n) }
          pushedVs := c :: pushedVs
        else
          dev := { dev with base := setAt dev.base r (.unkAt sq),
                            pending := dev.pending ++ [(r, sq, c)] }
      | none =>
        match s.rows.getD r none with
        | none =>
          let (s', n) := s.issue
          s := { s' with rows := setAt s'.rows r (some { ver := c, seq := n }) }
          dev := { dev with base := setAt dev.base r (.known c n) }
          pushedVs := c :: pushedVs
        | some _ =>
          -- DO NOTHING, a seq burned; awaiting the echo with `?`
          s := s.issue.1
          let keep := match b with
            | .stale _ _ => R.reupStale
            | _ => false
          dev := { dev with base := setAt dev.base r (if keep then b else .unk) }
  let w := if R.rbPushedOnly || R.rbDocstring then pushedVs.foldl markOnServer w else w
  return { w with srv := s, devs := setAt w.devs d (clearOrigins R dev) }

def newVer (w : World) (info : VerInfo) : World × Nat :=
  ({ w with vers := w.vers ++ [info] }, w.vers.length + 1)

def edit (w : World) (d r : Nat) (stampPost : Bool := false) : World :=
  let dev := w.devs.getD d default
  let parent := (dev.loc.getD r none).getD 0
  let post := stampPost && dev.epoch == w.srv.er.epoch && !dev.afterReset
  let (w, v) := newVer w { row := r, parent, byAgent := false, held := true, rolledBack := false, onServer := false,
                           post }
  { w with devs := modAt w.devs d fun dv =>
      { dv with loc := setAt dv.loc r (some v), was := setAt dv.was r none } }

/-- An agent / MCP / edge-function write (service role, no seq filter). -/
def agent (R : Rules) (w : World) (r : Nat) : World :=
  let s := w.srv
  match s.rows.getD r none with
  | some row =>
    let (w, v) := newVer w { row := r, parent := row.ver, byAgent := true, held := false, rolledBack := false, onServer := true,
                             post := R.final }
    let (s', n) := if s.triggers || R.stampDuringRollback then s.issue else (s, row.seq)
    { w with srv := { s' with rows := setAt s'.rows r (some { row with ver := v, seq := n }) } }
  | none =>
    let (w, v) := newVer w { row := r, parent := 0, byAgent := true, held := false, rolledBack := false, onServer := true,
                             post := R.final }
    let (s', n) := s.issue
    { w with srv := { s' with rows := setAt s'.rows r (some { ver := v, seq := n }) } }

def parentOf (w : World) (v : Nat) : Nat := (w.vers.getD (v - 1) default).parent

/-- `a` is `b` or an ancestor of `b`: reachable through parents and the
`over` edges an accepted prompt entry adds. Parents strictly precede
children; `over` edges can point forward, so the walk is bounded by twice
the version count. -/
def ancOrEq (w : World) (a b : Nat) : Bool :=
  go b (2 * w.vers.length + 2)
where
  go : Nat → Nat → Bool
    | _, 0 => false
    | x, fuel + 1 =>
      if x == a then true else if x == 0 then false
      else
        let i := w.vers.getD (x - 1) default
        go i.parent fuel || i.over.any fun o => go o fuel

/-- The content of `v` reached the server: `v` or a descendant of it was
written there at some point. Read only by the `rbPushedOnly` checker. -/
def published (w : World) (v : Nat) : Bool :=
  (indexed w.vers).any fun (j, u) => u.onServer && ancOrEq w v (j + 1)

/-- A restore from `D` rolls back past every existing version that is not
in the history the dump kept for its row (neither the dump's version nor
an ancestor of it): created after the dump, or created before it and
pushed after it. Every other version is kept, including one an earlier
restore rolled back: the flag is re-judged, never sticky (the prior
checker only ever set it and so read `restoreKeepsAgain`'s revert as
allowed). -/
def markRolledBack (w : World) (D : Dump) (sticky : Bool := false) (pushedOnly : Bool := false)
    (doc : Bool := false) (stampAt : Bool := false) : World :=
  { w with vers := (indexed w.vers).map fun (i, v) =>
      let kept := match (D.rows.getD v.row none) with
        | some row => ancOrEq w (i + 1) row.ver || (row.dead != 0 && ancOrEq w (i + 1) row.dead)
        | none => false
      if kept then (if sticky then v else { v with rolledBack := false })
      else if pushedOnly && !(published w (i + 1)) then v
      else if doc && i < D.nVers && !(published w (i + 1) && !(D.pub.getD i false)) then v
      else if stampAt && !v.rolledBack then { v with rolledBack := true, rbAt := w.vers.length }
      else { v with rolledBack := true } }

/-! ## The final rule's device (decided 2026-10-20)

The simple rule ("B": after an epoch change the server wins, a differing
local copy goes to the shelf, rows the server lacks are re-uploaded) with
its four patches:

* the server rejects a device write, atomically with it, when the epoch the
  write carries is not current or sync is paused (`Rules.epochGate`; the
  model's flush is atomic, so the check is too). A rejected send keeps the
  marks it wrote (`Rules.gateMarks`) and shuts the device's outbound gate
  until its next chain;
* the catch-up keeps a local edit when the incoming row is the old
  baseline or the version the local edit chain started from (`staleFF`,
  `staleFFOrigin`);
* a pending local delete wins at the catch-up: the local row stays absent,
  a differing incoming row goes to the shelf, the tombstone goes out after
  the catch-up (`Rules.deleteWins`);
* one recovery prompt offers the catch-up entries the device can tell are
  newer than the server's row (`Rules.offer`); restore / later / discard.

Deletes: a device delete removes the local row and leaves the baseline
entry (the §6 shape of a delete not yet sent); the tombstone PATCH has no
seq filter and passes the same gate; an incoming tombstone takes the §6
tombstone row; a dump carries tombstones with their seqs. -/

def padTo {α : Type} (l : List α) (n : Nat) (a : α) : List α :=
  l ++ List.replicate (n - l.length) a

def setDel (dev : Device) (r v : Nat) : Device :=
  { dev with del := setAt (padTo dev.del dev.loc.length 0) r v }

/-- The final rule's reset: cursor dropped, in-memory tables cleared, every
entry stale with its old hash and seq (an entry still stale from an earlier
reset keeps what it had). -/
def resetF (dev : Device) (er : EpochRow) : Device :=
  { dev with
    base := dev.base.map fun b => match b with
      | .none => .none
      | .stale h s => .stale h s
      | _ => .stale (baseHash b) (baseSeq b)
    cursor := 0, epoch := er.epoch, pending := [], afterReset := true }

/-- Does the prompt offer local copy `c`, shelved by a catch-up against an
incoming row at `inSeq`, given the old baseline `(h, s)`? Only what the
device stores is read. -/
def offerOf (R : Rules) (h s : Option Nat) (c : Nat) (row : SRow) (own : Bool) : Bool :=
  let below := fun (x : Nat) => match s with
    | some so => decide (x < so)
    | none => true
  match R.offer with
  | .none => false
  | .all => true
  | .seq => (h != some c) || below row.seq
  | .seqOwn => (h != some c) || below row.seq || own
  | .epoch => (h != some c) || (if row.ep == 0 then below row.seq else below row.ep)

/-- One incoming row, live or tombstone, on the final rule's device. A
stale entry takes the catch-up rules; every other entry the §6 table
(skip row, then `decideRowBody`, tombstone row included). Returns the
device and whether it adopted the incoming version. -/
def applyF (R : Rules) (dev0 : Device) (r : Nat) (row : SRow) : Device × Bool :=
  let tomb := row.dead != 0
  let dev := if R.prune && !tomb then
      { dev0 with shelf := dev0.shelf.filter fun e => !(e.offered && e.row == r && e.ver == row.ver) }
    else dev0
  let b := dev.base.getD r .none
  let hLoc := dev.loc.getD r none
  let orig := dev.origin.getD r none
  match b with
  | .stale h s =>
    let vs := if tomb then row.dead else row.ver
    let start := if h == hLoc then none else (orig.orElse fun _ => h)
    let entry : Nat → SEntry := fun c =>
      { ver := c, row := r, against := vs, catchup := true,
        offered := offerOf R h s c row (dev.own.getD r false), lostTo := vs, origin := start }
    -- an offered entry shelved against the copy this catch-up shelves now
    -- is re-aimed at the incoming row
    let retarget : Nat → List SEntry → List SEntry := fun c l =>
      l.map fun e => if e.offered && e.row == r && e.against == c then { e with against := vs } else e
    if tomb then
      match hLoc with
      | none => (setDel { dev with base := setAt dev.base r .none } r 0, false)
      | some c =>
        -- the device's own unsent edit loses to the tombstone as in §6's
        -- tombstone row (delete wins); a clean copy is classified as usual
        let shelf :=
          if c == row.ver then dev.shelf
          else if h != some c then
            dev.shelf ++ [{ ver := c, row := r, against := row.dead, lostToDelete := true, lostTo := row.dead }]
          else retarget c dev.shelf ++ [entry c]
        ({ dev with loc := setAt dev.loc r none, base := setAt dev.base r .none, shelf := shelf }, false)
    else
      let base := setAt dev.base r (.known row.ver row.seq)
      match hLoc with
      | none =>
        if R.deleteWins then
          let echo := h == some row.ver || (R.staleFFOrigin && orig == some row.ver)
          let shelf := if echo then dev.shelf else dev.shelf ++ [{ ver := row.ver, row := r }]
          ({ dev with base := base, shelf := shelf }, false)
        else
          (setDel { dev with loc := setAt dev.loc r (some row.ver), base := base } r 0, true)
      | some c =>
        if c == row.ver then ({ dev with base := base }, false)
        else if R.staleFF && (h == some row.ver || (R.staleFFOrigin && orig == some row.ver)) then
          ({ dev with base := base }, false)
        else
          let shelf := if R.staleShelf then retarget c dev.shelf ++ [entry c] else dev.shelf
          ({ dev with loc := setAt dev.loc r (some row.ver), base := base, shelf := shelf }, true)
  | _ =>
    let skip := match baseSeq b with
      | some S => decide (row.seq ≤ S)
      | none => false
    if skip then (dev, false) else
    let av := dev.acc.getD r 0
    if R.acceptCond && !tomb && av != 0 && hLoc == some av && row.ver != av then
      -- the restore's write did not land on the row it was aimed at: the
      -- server keeps its row and the entry goes back to the prompt
      let e : SEntry := { ver := av, row := r, against := row.ver, catchup := true, offered := true,
                          lostTo := row.ver }
      ({ dev with loc := setAt dev.loc r (some row.ver), base := setAt dev.base r (.known row.ver row.seq),
                  shelf := dev.shelf ++ [e], acc := setAt (padTo dev.acc dev.loc.length 0) r 0 }, true)
    else
    let d := decideRowBody tomb row.ver hLoc (baseForBody b) row.seq
    if d.action == Action.tombstone then
      let shelf := match hLoc with
        | some c =>
          if d.shelfLocal then
            dev.shelf ++ [{ ver := c, row := r, against := row.dead, lostToDelete := true, lostTo := row.dead }]
          else dev.shelf
        | none => dev.shelf
      (setDel { dev with loc := setAt dev.loc r none, base := setAt dev.base r .none, shelf := shelf } r 0,
       false)
    else
      let adopt := d.action == Action.adopt
      let loc := if adopt then setAt dev.loc r (some row.ver) else dev.loc
      let base := setAt dev.base r (match d.base with
        | some (h, s) => BaseE.known h s
        | none => BaseE.none)
      let shelf := if d.shelfRemote then dev.shelf ++ [{ ver := row.ver, row := r }] else dev.shelf
      ({ dev with loc := loc, base := base, shelf := shelf }, adopt)

/-- One pull chain to head on the final rule's device. -/
def pullF (R : Rules) (w0 : World) (d : Nat) : World := Id.run do
  let dev0 := w0.devs.getD d default
  let er := w0.srv.er
  let dev1 := if er.epoch != dev0.epoch then resetF dev0 er else dev0
  if er.paused then
    return { w0 with devs := setAt w0.devs d { dev1 with gate := false } }
  let rows := serverRowsAbove w0.srv dev1.cursor
  let mut dev := { dev1 with gate := true }
  let mut w := w0
  for (r, row) in rows do
    let (dev', adopted) := applyF R dev r row
    dev := dev'
    if adopted then w := markHeld w row.ver
  let seen := rows.map (·.1)
  let cursor := rows.foldl (fun m x => max m x.2.seq) dev.cursor
  let mut base := dev.base
  for (id, sentSeq, sentHash) in dev.pending do
    if !(seen.contains id) then
      if baseSeq (base.getD id .none) == some sentSeq then
        base := setAt base id (.known sentHash sentSeq)
  dev := { dev with base := base }
  if R.offer == .seqOwn then
    dev := { dev with own := (List.range dev.loc.length).map fun i =>
      if seen.contains i then false else dev.own.getD i false }
  -- after a reset, an entry still stale at head names a row the server no
  -- longer has: a local copy is re-uploaded, a pending delete is done
  if dev.afterReset then
    for i in List.range dev.base.length do
      match dev.base.getD i .none with
      | .stale h s =>
        match dev.loc.getD i none with
        | some c =>
          let e : BaseE := if !R.staleReupload then .hashOnly c 0 else if R.reupStale then .stale h s else .unk
          dev := { dev with base := setAt dev.base i e }
        | none =>
          if R.tombInsert && dev.del.getD i 0 != 0 then
            dev := { dev with base := setAt dev.base i .unk }
          else dev := setDel { dev with base := setAt dev.base i .none } i 0
      | _ => pure ()
  -- a row the device's own edit had lost to a tombstone arrives live again
  -- (only a restore, or a re-upload after one, can bring a dead row back):
  -- that edit is offered again, against the row the device now holds
  if R.offer != .none then
    for (r, row) in rows do
      if row.dead == 0 && dev.loc.getD r none == some row.ver then
        dev := { dev with shelf := dev.shelf.map fun e =>
          if e.row == r && e.lostToDelete && !e.offered then { e with offered := true, against := row.ver }
          else e }
  -- ghost: a pending delete this chain ended (the row is dead or gone on
  -- the server) reached the server in effect, whoever's tombstone it was
  for r in List.range dev0.loc.length do
    let dv := dev0.del.getD r 0
    if dv != 0 && dev.del.getD r 0 == 0 && (match w0.srv.rows.getD r none with
        | some row => row.dead != 0
        | none => true) then
      w := markOnServer w dv
  dev := { dev with cursor := cursor, pending := [], afterReset := false }
  return { w with devs := setAt w.devs d (clearOrigins R dev) }

/-- What a send writes on its entry before it goes out (S4): `?@seq` from
an entry with a seq, `?` otherwise. -/
def sendMark (b : BaseE) : BaseE :=
  match baseSeq b with
  | some s => .unkAt s
  | none => .unk

/-- One flush on the final rule's device: the tombstone PATCH for every
pending delete, then PATCH / POST as before, each through the server
gate. -/
def flushF (R : Rules) (w0 : World) (d : Nat) : World := Id.run do
  let dev0 := w0.devs.getD d default
  if !dev0.gate then return w0
  let gated := R.epochGate && (dev0.epoch != w0.srv.er.epoch || w0.srv.er.paused)
  let mut dev := dev0
  let mut s := w0.srv
  let mut w := w0
  let mut rejected := false
  for r in List.range dev0.loc.length do
    if dev.pending.any (·.1 == r) then continue
    let b := dev.base.getD r .none
    match dev.loc.getD r none with
    | none =>
      if b == .none then continue
      if gated then
        rejected := true
        if R.gateMarks then dev := { dev with base := setAt dev.base r (sendMark b) }
        continue
      -- `PATCH id=eq.r & deleted_at=is.null`, no seq filter; any 2xx drops the entry
      let dv := dev.del.getD r 0
      match s.rows.getD r none with
      | some row =>
        if row.dead == 0 then
          let (s', n) := if s.triggers then s.issue else (s, row.seq)
          s := { s' with rows := setAt s'.rows r (some { row with seq := n, dead := dv }) }
          -- ghost: the content this tombstone killed joins the delete's history
          if dv != 0 && row.ver != parentOf w dv then
            w := { w with vers := modAt w.vers (dv - 1) fun i => { i with over := i.over ++ [row.ver] } }
      | none =>
        if R.tombInsert && dv != 0 then
          let (s', n) := s.issue
          s := { s' with rows := setAt s'.rows r (some { ver := parentOf w dv, seq := n, dead := dv }) }
      -- the row is dead or gone on the server now, whoever's tombstone it was
      if dv != 0 then w := markOnServer w dv
      dev := setDel { dev with base := setAt dev.base r .none } r 0
    | some c =>
      if baseHash b == some c then continue
      if gated then
        rejected := true
        if R.gateMarks then dev := { dev with base := setAt dev.base r (sendMark b) }
        continue
      match baseSeq b with
      | some sq =>
        match s.rows.getD r none with
        | some row =>
          if row.seq == sq && row.ver != c then
            let (s', n) := if s.triggers then s.issue else (s, sq)
            s := { s' with rows := setAt s'.rows r (some { row with ver := c, seq := n }) }
            w := markOnServer w c
            if row.dead == 0 then
              dev := { dev with base := setAt dev.base r (.known c n) }
              if R.offer == .seqOwn then dev := { dev with own := setAt (padTo dev.own dev.loc.length false) r true }
            else
              -- `[row]` with `deleted_at` set: the row is dead; the device
              -- files the response as the tombstone it is
              dev := { dev with loc := setAt dev.loc r none, base := setAt dev.base r .none,
                                shelf := dev.shelf ++ [{ ver := c, row := r, against := row.dead,
                                                         lostToDelete := true, lostTo := row.dead }] }
          else
            dev := { dev with base := setAt dev.base r (.unkAt sq),
                              pending := dev.pending ++ [(r, sq, c)] }
        | none =>
          dev := { dev with base := setAt dev.base r (.unkAt sq),
                            pending := dev.pending ++ [(r, sq, c)] }
      | none =>
        match s.rows.getD r none with
        | none =>
          let (s', n) := s.issue
          s := { s' with rows := setAt s'.rows r (some { ver := c, seq := n }) }
          dev := { dev with base := setAt dev.base r (.known c n) }
          w := markOnServer w c
          if R.offer == .seqOwn then dev := { dev with own := setAt (padTo dev.own dev.loc.length false) r true }
        | some _ =>
          s := s.issue.1
          let keep := match b with
            | .stale _ _ => R.reupStale
            | _ => false
          dev := { dev with base := setAt dev.base r (if keep then b else .unk) }
  if rejected then dev := { dev with gate := false }
  return { w with srv := s, devs := setAt w.devs d (clearOrigins R dev) }

/-- A device deletes row `r`: the local row goes, the baseline entry stays
(a delete not yet sent), and the delete is a version whose parent is the
copy it deleted. A row that never reached a baseline just goes. -/
def deleteF (w : World) (d r : Nat) : World :=
  let dev := w.devs.getD d default
  match dev.loc.getD r none with
  | none => w
  | some v =>
    let (w, dv) := newVer w { row := r, parent := v, byAgent := false, held := true,
                              rolledBack := false, onServer := false, dead := true }
    { w with devs := modAt w.devs d fun x =>
        let pend := if x.base.getD r .none == .none then 0 else dv
        setDel { x with loc := setAt x.loc r none, was := setAt x.was r none } r pend }

/-- The final rule's agent write: refused while paused outside a rollback
unless `Rules.agentWhilePaused`; never on a tombstone (the server's read
paths filter dead rows). -/
def agentF (R : Rules) (w : World) (r : Nat) : World :=
  if !R.agentWhilePaused && w.srv.er.paused && !w.rolledBackMode then w else
  match w.srv.rows.getD r none with
  | some row => if row.dead != 0 then w else agent R w r
  | none => agent R w r

/-- An agent delete (service role). Only while the triggers are installed:
a rollback's DELETE is physical, which the model does not have. -/
def agentDelF (R : Rules) (w : World) (r : Nat) : World :=
  if !R.agentWhilePaused && w.srv.er.paused && !w.rolledBackMode then w else
  match w.srv.rows.getD r none with
  | some row =>
    if row.dead != 0 || !w.srv.triggers then w else
    let (w, dv) := newVer w { row := r, parent := row.ver, byAgent := true, held := false,
                              rolledBack := false, onServer := true, dead := true }
    let (s', n) := w.srv.issue
    { w with srv := { s' with rows := setAt s'.rows r (some { row with seq := n, dead := dv }) } }
  | none => w

/-- `a` is a strict ancestor of `b`. -/
def strictAnc (w : World) (a b : Nat) : Bool := a != b && ancOrEq w a b

/-- The prompt's "restore": each offered entry is re-applied as a local
edit over the device's current row, but only while that row is clean, not
a tombstone, and (`Rules.acceptGuard`) the very version the entry was
shelved against; every other entry stays offered. The user chose the entry
over that row, so the row joins the entry's history (`VerInfo.over`). The
ghost `badAccept` records an overwrite of a version newer than the entry
or newer than the version it had lost to. -/
def acceptF (R : Rules) (w0 : World) (d : Nat) : World := Id.run do
  let mut w := w0
  let mut dev := w0.devs.getD d default
  let mut keep : List SEntry := []
  for e in dev.shelf do
    if !e.offered then
      keep := keep ++ [e]
      continue
    let r := e.row
    let againstDead := e.against != 0 && (w.vers.getD (e.against - 1) default).dead
    let cur := match dev.base.getD r .none, dev.loc.getD r none with
      | .known h _, some x => if x == h && !againstDead && (!R.acceptGuard || h == e.against) then some x else none
      | _, _ => none
    match cur with
    | none => keep := keep ++ [e]
    | some x =>
      if x != e.ver then
        if strictAnc w e.ver x || (e.against != 0 && strictAnc w e.against x) then
          w := { w with badAccept := true }
        w := { w with vers := modAt w.vers (e.ver - 1) fun i => { i with over := i.over ++ [x] } }
        if R.acceptCond then dev := { dev with acc := setAt (padTo dev.acc dev.loc.length 0) r e.ver }
        dev := { dev with loc := setAt dev.loc r (some e.ver),
                          origin := setAt (padTo dev.origin dev.loc.length none) r
                            (some (if R.originBack then e.origin.getD x else x)),
                          was := setAt dev.was r none }
  dev := { dev with shelf := keep }
  return { w with devs := setAt w.devs d dev }

/-- The prompt's "discard": the offered entries leave the shelf; the user
let them go. -/
def discardF (w : World) (d : Nat) : World :=
  let dev := w.devs.getD d default
  let gone := (dev.shelf.filter (·.offered)).map (·.ver)
  { w with dropped := w.dropped ++ gone,
           devs := setAt w.devs d { dev with shelf := dev.shelf.filter fun e => !e.offered } }

/-- An epoch no step ever writes: a device that has just logged in again
knows none. -/
def eraseEpoch : Nat := 1000

/-- Log-out / erase-all-data on device `d`: local rows, baselines, cursor,
shelf go; the next pull starts over. Unsent local edits and deletes go
with them (that is what erasing is); the shelf goes as the user's choice
only when the warning showed (`Rules.eraseWarn`). A clean copy the device
has not yet caught up on is not counted as the user's choice. -/
def eraseF (R : Rules) (w : World) (d : Nat) : World :=
  let dev := w.devs.getD d default
  let n := dev.loc.length
  let unsent := (List.range n).filterMap fun r =>
    match dev.loc.getD r none with
    | some c => if baseHashF (dev.base.getD r .none) == some c then none else some c
    | none => let dv := dev.del.getD r 0; if dv != 0 then some dv else none
  let shelfGone := if R.eraseWarn then dev.shelf.map (·.ver) else []
  let fresh : Device :=
    { loc := List.replicate n none, base := List.replicate n .none, cursor := 0, epoch := eraseEpoch,
      gate := false, afterReset := false, pending := [], shelf := [], was := List.replicate n none }
  let synced := (List.range n).filterMap fun r =>
    match dev.loc.getD r none with
    | some c => if baseHashF (dev.base.getD r .none) == some c then some c else none
    | none => none
  { w with dropped := w.dropped ++ unsent ++ shelfGone, erased := w.erased ++ synced,
           devs := setAt w.devs d fresh }

/-! ## Operator steps -/

def freshEpoch (w : World) : World × Nat :=
  ({ w with nextEpoch := w.nextEpoch + 1 }, w.nextEpoch)

def maxRowSeq (s : Server) : Nat :=
  s.rows.foldl (fun m o => match o with | some r => max m r.seq | none => m) 0

/-- The `.epoch` offer variant's server column: an epoch step records each
row's seq in it. -/
def stampEp (R : Rules) (rows : List (Option SRow)) : List (Option SRow) :=
  if R.offer != .epoch then rows else rows.map fun o => o.map fun row => { row with ep := row.seq }

/-- `restore_with_epoch.sql` run on its own; it ends with `paused = true`
(the operator clears it separately, `Act.unpause`). -/
def standaloneStep (R : Rules) (w : World) : World :=
  if !R.epochStep then
    let s := w.srv
    let c := s.counter + J
    { w with srv := { s with counter := c, highWater := max s.highWater c,
                             er := { s.er with paused := false } } }
  else if R.epochOnly then
    let (w, e) := freshEpoch w
    let s := w.srv
    let c := if R.stepRaise then max s.counter (maxRowSeq s) else s.counter
    { w with srv := { s with counter := c, highWater := max s.highWater c,
                             rows := stampEp R s.rows,
                             er := { epoch := e, floor := 0, lost := [], paused := true } } }
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
      if withEpoch then some w.srv.er else none, 0, []⟩] }

/-- `restore.sh` (either path): one transaction of TRUNCATE (incl.
`sync_epoch`), data.sql with the `sync_seq` setval stripped (F = its
value), then `restore_with_epoch` with L = the live counter:
`lost := <the restored row's lost> + (F, L]`, new epoch, `paused = true`. -/
def restoreScript (R : Rules) (w0 : World) (k : Nat) : World :=
  let D := w0.dumps.getD k default
  if R.epochOnly then
    let w := markRolledBack w0 D R.sticky R.rbPushedOnly R.rbDocstring R.final
    let (w, e) := freshEpoch w
    let s := w.srv
    let c := if R.counterUp then max s.counter (maxRowSeq { s with rows := D.rows }) else D.counter
    { w with srv := { s with rows := stampEp R D.rows, counter := c, highWater := max s.highWater c,
                             er := { epoch := e, floor := 0, lost := [], paused := true } } }
  else
  if R.refuseNoEpoch && D.epochRow.isNone then w0 else
  let w := markRolledBack w0 D R.sticky R.rbPushedOnly R.rbDocstring R.final
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
def bypass (w0 : World) (k : Nat) (sticky : Bool := false) (pushedOnly : Bool := false)
    (doc : Bool := false) (stampAt : Bool := false) : World :=
  let D := w0.dumps.getD k default
  let w := markRolledBack w0 D sticky pushedOnly doc stampAt
  { w with srv := { w.srv with rows := D.rows, counter := D.counter,
                               er := D.epochRow.getD w.srv.er } }

/-- The same bypass into a NEW project. A dump with the `sync_epoch` row
brings it back as above; a dump without it leaves the row the new
project's migrations seeded (new random epoch, floor 0, empty `lost`),
unless the rule copies the OLD project's `lost` into it first. -/
def bypassNew (R : Rules) (w0 : World) (k : Nat) : World :=
  let D := w0.dumps.getD k default
  let w := markRolledBack w0 D R.sticky R.rbPushedOnly R.rbDocstring R.final
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
        | some row => let (s', n) := s.issue; { s' with rows := setAt s'.rows i (some { row with seq := n }) }
        | none => s
    else srv
  standaloneStep R { w with srv := srv, rolledBackMode := false }

/-- The operator clears `paused` once the post-checks pass. -/
def unpause (w : World) : World :=
  { w with srv := { w.srv with er := { w.srv.er with paused := false } } }

/-- The simple step WITHOUT its lock: it reads the counter and the rows, an
agent write on row `r` then takes `nextval`, and the `setval` that follows
puts the counter back to what it read. -/
def raceStepF (R : Rules) (w : World) (r : Nat) : World :=
  let s := w.srv
  let c := if R.stepRaise then max s.counter (maxRowSeq s) else s.counter
  let w := match s.rows.getD r none with
    | some row => if row.dead != 0 then w else agent R w r
    | none => agent R w r
  let (w, e) := freshEpoch w
  let s := w.srv
  { w with srv := { s with counter := c, highWater := max s.highWater c,
                           er := { epoch := e, floor := 0, lost := [], paused := true } } }

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
  /-- the final rule: device `d` deletes row `r` -/
  | delete (d r : Nat)
  /-- the final rule: an agent delete of row `r` -/
  | agentDel (r : Nat)
  /-- the recovery prompt on device `d`: restore, later, discard -/
  | accept (d : Nat)
  | later (d : Nat)
  | discard (d : Nat)
  /-- log-out / erase-all-data on device `d` -/
  | erase (d : Nat)
  /-- the standalone step without its lock, racing an agent write on row `r` -/
  | stepRace (r : Nat)
deriving BEq, Repr, Inhabited

/-- Operator actions count against `Bounds.maxOps`; clearing `paused` does
not (it only closes a window an epoch step opened). -/
def Act.isOp : Act → Bool
  | .edit .. | .pull _ | .flush _ | .agent _ | .unpause => false
  | .delete .. | .agentDel _ | .accept _ | .later _ | .discard _ | .erase _ => false
  | _ => true

/-- When an edit or a delete takes a clean row dirty, remember the version
the edit chain starts from (`Rules.staleFFOrigin`). -/
def originMark (R : Rules) (w : World) (d r : Nat) : World :=
  if !R.staleFFOrigin then w else
  { w with devs := modAt w.devs d fun dv =>
      let o := dv.origin.getD r none
      let padded := dv.origin ++ List.replicate (dv.loc.length - dv.origin.length) none
      let b := dv.base.getD r .none
      let bh := if R.final then baseHashF b else baseHash b
      if o.isNone && bh == dv.loc.getD r none then
        { dv with origin := setAt padded r (dv.loc.getD r none) }
      else dv }

def pullR (R : Rules) (w : World) (d : Nat) : World := if R.final then pullF R w d else pull R w d
def flushR (R : Rules) (w : World) (d : Nat) : World := if R.final then flushF R w d else flush R w d

/-- `prompt`: a bypassed or aborted restore is followed at once by the
standalone epoch step (ops/README.md R3, "immediately"), before any
device acts. Without it the window in between is open (§9.37 residual). -/
def step (R : Rules) (prompt : Bool) (w : World) (a : Act) : World :=
  let w := if a.isOp then { w with ops := w.ops + 1 } else w
  match a with
  | .edit d r => edit (originMark R w d r) d r R.final
  | .pull d => pullR R w d
  | .flush d => flushR R w d
  | .agent r => if R.final then agentF R w r else agent R w r
  | .dump b =>
    let w := dump w b
    if R.rbDocstring then
      { w with dumps := modAt w.dumps (w.dumps.length - 1) fun D =>
          { D with nVers := w.vers.length,
                   pub := (List.range w.vers.length).map fun i => published w (i + 1) } }
    else w
  | .restore k => restoreScript R w k
  | .bypass k => let w := bypass w k R.sticky R.rbPushedOnly R.rbDocstring R.final; if prompt then standaloneStep R w else w
  | .bypassNew k => let w := bypassNew R w k; if prompt then standaloneStep R w else w
  | .abortSetval k => let w := abortSetval w k; if prompt then standaloneStep R w else w
  | .standalone => standaloneStep R w
  | .rollback => rollback w
  | .reenable => reenable R w
  | .unpause => unpause w
  | .delete d r => deleteF (originMark R w d r) d r
  | .agentDel r => agentDelF R w r
  | .accept d => acceptF R w d
  | .later _ => w
  | .discard d => discardF w d
  | .erase d => eraseF R w d
  | .stepRace r => raceStepF R w r

def run (R : Rules) (prompt : Bool) (w : World) (tr : List Act) : World :=
  tr.foldl (step R prompt) w

/-! ## Quiescence and the property -/

def settleRounds : Nat := 8

def round (R : Rules) (w : World) : World :=
  flushR R (pullR R (flushR R (pullR R w 0) 0) 1) 1

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

/-- Some strict ancestor of `v` below `w` (not `w`, not `v`) was rolled
back: `v` was built on a version a restore discarded. The split labels
such a revert `P3d` when a device wrote `v` and `P3da` when an agent did. -/
def builtOnDiscarded (w : World) (lw v : Nat) : Bool :=
  go (parentOf w v) (v + 1)
where
  go : Nat → Nat → Bool
    | _, 0 => false
    | x, fuel + 1 =>
      if x == lw || x == 0 then false
      else if (w.vers.getD (x - 1) default).rolledBack then true
      else go (parentOf w x) fuel

/-- `none` = the property holds; `some reason` otherwise. -/
def checkSettled (w : World) (splitP3 : Bool := false) : Option String := Id.run do
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
  let survivors := (List.range nrows).filterMap (live w) ++ (w.devs.map (·.shelf)).flatten.map (·.ver)
  -- P2
  for (i, info) in indexed w.vers do
    let v := i + 1
    if protectedVer info && !(survivors.any fun u => ancOrEq w v u) then
      return some s!"P2 lost version {v} (row {info.row})"
  -- P3, then the strict reading P3s
  let mut strict : Option String := none
  let mut onDiscarded : Option String := none
  for (i, info) in indexed w.vers do
    let v := i + 1
    if protectedVer info && !info.rolledBack then
      match live w info.row with
      | some lw => if lw != v && ancOrEq w lw v then
          if (w.vers.getD (lw - 1) default).rolledBack then
            strict := strict.orElse fun _ =>
              some s!"P3s row {info.row} reverted onto resurrected {lw} over {v}"
          else if splitP3 && builtOnDiscarded w lw v then
            onDiscarded := onDiscarded.orElse fun _ =>
              some s!"{if info.byAgent then "P3da" else "P3d"} row {info.row} reverted to {lw} over {v}, built on a discarded version"
          else
            return some s!"P3 row {info.row} reverted to {lw} over {v}"
      | none => pure ()
  return onDiscarded.orElse fun _ => strict

def check (R : Rules) (w : World) : Option String :=
  match settle R w with
  | none => some "no quiescence"
  | some w' => checkSettled w' R.splitP3

/-! ## The strict checker (the final rule's searches)

`judge` reports EVERY class a settled world has, each with one reason.

A version is **discarded by a restore** (`rolledBack`) only when its content
reached the server (`Rules.rbPushedOnly`): an edit that only ever existed on
a device is never exempted that way (round 1's default checker did exempt
it). A delete reaches the server when its own tombstone lands or when its
device drops it because the row is dead or gone there anyway.

The **roots** that account for a version are: the live rows; a tombstone's
content and its delete (the server keeps both); every delete version (what
a delete removed, and the content its tombstone killed, are the user's own
doing, whether or not a restore later brings the row back, which is
counted as `RES`); every entry the prompt offers on some device; and
whatever the user let go (`dropped`: the prompt's discard, a log-out or
erase after its warning). A protected version accounted by none of them is:

* `P2c` (reported): in a §6 conflict entry only. The §6 table hides a
  conflict's loser in the shelf with or without a restore, and there is no
  shelf page (decided 2026-10-20). `P2cRB` marks those a restore discarded.
* `P2hc` (reported): in a catch-up entry the prompt does not offer, and what
  it lost to is not its own ancestor and begins, where its history leaves
  the version's, with a write
  made without a view of the restore that discarded it (before the restore,
  or by a device that had not caught up). That is a concurrent edit winning,
  the outcome §6 gives without any restore.
* `P2h` (hard): in a catch-up entry the prompt does not offer, otherwise.
* `P2e` (reported): discarded by a restore after every device that held it
  logged out or erased with it synced: no copy existed anywhere.
* `P2` (hard): nowhere.

P3: a protected version not discarded and not let go whose row's live
version is a strict ancestor of it. `P3d` (built on a discarded version),
`P3x` (the cross-epoch residual: it lost at a catch-up or to a tombstone,
or the prompt's restore chose its line over a version, and a later epoch
change discarded that version or put the row back on one of its ancestors
other than that version), `P3s` (the live version is a discarded one a
device brought back) are accepted while the version is offered somewhere,
`P3h` (hard) when it is not; `P3da` (an agent's) and plain `P3` are hard.

Deletes: a delete version whose row is live at the end is `RES` (accepted)
when a restore discarded it, otherwise `DELu` (hard; the live row is the
version it deleted or older) or `DEL` (hard).

Hard: `P1`, `NQ` (no quiescence), `P2`, `P2h`, `P3`, `P3h`, `P3da`, `PA` (an
accept overwrote a version newer than the entry, or newer than the version
it lost to), `DEL`, `DELu`. Accepted: `P3d`, `P3x`, `P3s`, `RES`. Reported:
`P2c`, `P2cRB`, `P2hc`, `P2e`, `PS` (an offered entry its device can no
longer apply: the row is not the version it was shelved against). -/

/-- The row's live version; `none` for a tombstone or an absent row. -/
def liveVer (w : World) (r : Nat) : Option Nat :=
  match w.srv.rows.getD r none with
  | some row => if row.dead == 0 then some row.ver else none
  | none => none

/-- P1 with tombstones: a dead or absent row is absent on every device and
leaves no baseline entry. -/
def p1Of (w : World) : Option String := Id.run do
  for (d, dev) in indexed w.devs do
    if dev.epoch != w.srv.er.epoch then return some s!"P1 device {d} epoch"
    if !dev.pending.isEmpty then return some s!"P1 device {d} pending"
    for r in List.range w.srv.rows.length do
      let lv := liveVer w r
      if dev.loc.getD r none != lv then
        return some s!"P1 device {d} row {r}: local {dev.loc.getD r none} server {lv}"
      match lv with
      | some v =>
        if baseHash (dev.base.getD r .none) != some v then return some s!"P1 device {d} row {r}: dirty"
      | none =>
        if dev.base.getD r .none != .none then
          return some s!"P1 device {d} row {r}: an entry is left on a dead or absent row"
  return none

/-- `builtOnDiscarded` through every parent edge, `over` included. -/
def builtOnDiscardedF (w : World) (lw v : Nat) : Bool :=
  let i := w.vers.getD (v - 1) default
  (i.parent :: i.over).any fun x => go x (2 * w.vers.length + 2)
where
  go : Nat → Nat → Bool
    | _, 0 => false
    | x, fuel + 1 =>
      if x == lw || x == 0 then false
      else
        let j := w.vers.getD (x - 1) default
        j.rolledBack || go j.parent fuel || j.over.any fun o => go o fuel

def hardClasses : List String := ["P1", "NQ", "P2", "P2h", "P3", "P3h", "P3da", "PA", "DEL", "DELu"]
def acceptedClasses : List String := ["P3d", "P3x", "P3s", "RES"]

def judge (w : World) : List (String × String) := Id.run do
  let mut out : List (String × String) := []
  let add := fun (o : List (String × String)) (c why : String) =>
    if o.any (·.1 == c) then o else o ++ [(c, why)]
  match p1Of w with
  | some why => out := add out "P1" why
  | none => pure ()
  if w.badAccept then
    out := add out "PA" "PA an accepted entry overwrote a version newer than it or than the version it lost to"
  let entries := (indexed w.devs).flatMap fun (d, dev) => dev.shelf.map fun e => (d, e)
  let offered := entries.filterMap fun (_, e) => if e.offered then some e.ver else none
  let conflictE := entries.filterMap fun (_, e) => if e.catchup then none else some e.ver
  let hiddenE := entries.filterMap fun (_, e) => if e.catchup && !e.offered then some e.ver else none
  let rb := fun (v : Nat) => (w.vers.getD (v - 1) default).rolledBack
  let roots := (List.range w.srv.rows.length).filterMap (liveVer w)
    ++ (w.srv.rows.flatMap fun o => match o with
        | some row => if row.dead != 0 then [row.ver, row.dead] else []
        | none => [])
    ++ ((indexed w.vers).filterMap fun (i, v) => if v.dead then some (i + 1) else none)
    ++ offered ++ w.dropped
  let under := fun (l : List Nat) (v : Nat) => l.any (ancOrEq w v ·)
  for (i, info) in indexed w.vers do
    let v := i + 1
    if info.dead then
      if w.dropped.contains v then continue
      match liveVer w info.row with
      | none => pure ()
      | some u =>
        if info.rolledBack then
          out := add out "RES" s!"RES row {info.row}: delete {v} undone by a restore, {u} live"
        else if protectedVer info then
          if ancOrEq w u info.parent then
            out := add out "DELu" s!"DELu row {info.row}: delete {v} of {info.parent} undone, {u} live"
          else
            out := add out "DEL" s!"DEL row {info.row}: delete {v} of {info.parent} undone, {u} live"
      continue
    if !protectedVer info then continue
    if !under roots v then
      if under conflictE v then
        out := add out "P2c" s!"P2c version {v} (row {info.row}) only in a §6 conflict entry"
        if info.rolledBack then
          out := add out "P2cRB" s!"P2cRB version {v} (row {info.row}), discarded by a restore, only in a §6 conflict entry"
      else if under hiddenE v then
        -- what it lost to at the catch-up is not one of its ancestors, and
        -- starts, where its history leaves this version's, with a write
        -- made without a view of the restore
        -- that discarded this version (before it, or by a device that had
        -- not caught up): a concurrent edit won, the outcome §6 gives
        -- without any restore. A write made after that restore by a writer
        -- that had caught up with it is the restore's doing.
        let postRestore := fun (x : Nat) => (indexed w.vers).any fun (j, u) =>
          let y := j + 1
          ancOrEq w y x && !ancOrEq w y v && u.post && y > info.rbAt &&
            (u.parent :: u.over).all fun p => p == 0 || ancOrEq w p v
        let conc := entries.any fun (_, e) =>
          e.catchup && !e.offered && ancOrEq w v e.ver && e.lostTo != 0 && !ancOrEq w e.lostTo v &&
            (!info.rolledBack || !postRestore e.lostTo)
        if conc then
          out := add out "P2hc" s!"P2hc version {v} (row {info.row}) shelved by a catch-up, not offered; it lost to a concurrent version"
        else
          out := add out "P2h" s!"P2h version {v} (row {info.row}) shelved by a catch-up, not offered; it did not lose to a concurrent edit"
      else if info.rolledBack && under w.erased v then
        out := add out "P2e" s!"P2e version {v} (row {info.row}) discarded by a restore after its only device copy was logged out"
      else
        out := add out "P2" s!"P2 lost version {v} (row {info.row})"
    if info.rolledBack || under w.dropped v then continue
    match liveVer w info.row with
    | none => pure ()
    | some lw =>
      if lw != v && ancOrEq w lw v then
        -- it lost at a catch-up or to a tombstone (or the prompt's
        -- restore chose its line over a version), and a later epoch change
        -- discarded that version or put the row back on one of its
        -- ancestors other than that version
        let cross := entries.any fun (_, e) => ancOrEq w v e.ver &&
          ((e.lostTo != 0 && (rb e.lostTo || e.lostTo != lw)) ||
           (indexed w.vers).any fun (j, u) =>
             ancOrEq w v (j + 1) && ancOrEq w (j + 1) e.ver && u.over.any fun o => rb o || o != lw)
        let sub :=
          if rb lw then "P3s"
          else if builtOnDiscardedF w lw v then (if info.byAgent then "P3da" else "P3d")
          else if cross then "P3x" else "P3"
        let why := s!"{sub} row {info.row} reverted to {lw} over {v}"
        if sub == "P3" || sub == "P3da" then out := add out sub why
        else if under offered v then out := add out sub why
        else out := add out "P3h" s!"P3h ({sub}, not offered) row {info.row} reverted to {lw} over {v}"
  for (d, e) in entries do
    if e.offered then
      let dev := w.devs.getD d default
      let fits := (match dev.base.getD e.row .none with
        | .known h _ => h == e.against
        | _ => false) && !(w.vers.getD (e.against - 1) default).dead
      if !fits then
        out := add out "PS" s!"PS device {d} offers {e.ver} (row {e.row}), shelved against {e.against}, which its row no longer is"
  return out

def checkF (R : Rules) (w : World) : List (String × String) :=
  match settle R w with
  | none => [("NQ", "NQ no quiescence")]
  | some w' => judge w'

/-! ## Start state and the bounded search -/

/-- X = version 1 at seq 1 on the server and both devices; Y (row 1, when
`rows = 2`) absent everywhere. -/
def initWorld (rows : Nat) : World :=
  let dev : Device :=
    { loc := (List.range rows).map fun i => if i == 0 then some 1 else none
      base := (List.range rows).map fun i => if i == 0 then .known 1 1 else .none
      cursor := 1, epoch := 0, gate := true, afterReset := false, pending := [], shelf := []
      was := (List.range rows).map fun _ => none }
  { srv := { rows := (List.range rows).map fun i => if i == 0 then some { ver := 1, seq := 1 } else none
             counter := 1, er := ⟨0, 0, [], false⟩, triggers := true, highWater := 1 }
    devs := [dev, dev], dumps := [],
    vers := [{ row := 0, parent := 0, byAgent := false, held := true, rolledBack := false, onServer := true }],
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
  /-- operators may also dump, restore and run the standalone step while
  rolled back (otherwise re-enable is the only operator action then) -/
  opsInRollback : Bool := false
  /-- the final rule's deletes: a device delete, an agent delete -/
  deletes : Bool := false
  /-- the recovery prompt's actions: restore, later, discard -/
  prompts : Bool := false
  /-- log-out / erase-all-data on a device -/
  erase : Bool := false
  /-- the standalone step without its lock -/
  raceStep : Bool := false
  /-- a row is created (by a device or the agent) only while no version of
  it exists: ids are UUIDs, and a deleted row is never created again -/
  fresh : Bool := false
deriving Repr

def enabled (B : Bounds) (w : World) : List Act :=
  let unborn := fun (r : Nat) => !(w.vers.any (·.row == r))
  let dev : List Act := [0, 1].flatMap fun d =>
    let dv := w.devs.getD d default
    ((List.range B.rows).flatMap fun r =>
      let loc := dv.loc.getD r none
      let canEdit := !B.fresh || loc.isSome || (dv.base.getD r .none == .none && unborn r)
      (if canEdit then [Act.edit d r] else []) ++ (if B.deletes && loc.isSome then [Act.delete d r] else []))
    ++ [Act.pull d, Act.flush d]
    ++ (if B.prompts && dv.shelf.any (·.offered) then [Act.accept d, Act.later d, Act.discard d] else [])
    ++ (if B.erase then [Act.erase d] else [])
  let ag : List Act := if !B.agent then [] else (List.range B.rows).flatMap fun r =>
    match w.srv.rows.getD r none with
    | some row =>
      if row.dead != 0 then []
      else [Act.agent r] ++ (if B.deletes && w.srv.triggers then [Act.agentDel r] else [])
    | none => if !B.fresh || unborn r then [Act.agent r] else []
  let unp : List Act := if w.srv.er.paused && !w.rolledBackMode then [Act.unpause] else []
  let opsLeft := w.ops < B.maxOps
  let ops : List Act :=
    if !opsLeft then []
    else if w.rolledBackMode && !B.opsInRollback then [Act.reenable]
    else
      (if w.dumps.length < B.maxDumps then [Act.dump true, Act.dump false] else [])
      ++ ((List.range w.dumps.length).flatMap fun k =>
            if !B.offScript then [Act.restore k]
            else if B.noRowHand || (w.dumps.getD k default).epochRow.isSome then
              [Act.restore k, Act.bypass k, Act.bypassNew k, Act.abortSetval k]
            else [Act.restore k, Act.abortSetval k])
      ++ (if B.offScript then [Act.standalone] else [])
      ++ (if w.rolledBackMode then [Act.reenable]
          else if B.rollbacks then [Act.rollback] else [])
      ++ (if B.raceStep && B.offScript && !w.rolledBackMode then (List.range B.rows).map Act.stepRace else [])
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

/-- Per class: how many worlds have it, and a shortest witness. `hard`
counts the worlds with at least one hard class. -/
structure StatsF where
  states : Nat := 0
  hard : Nat := 0
  byClass : List (String × Nat × List Act × String) := []
deriving Repr

def StatsF.count (st : StatsF) (cls : String) : Nat :=
  match st.byClass.find? (·.1 == cls) with
  | some e => e.2.1
  | none => 0

def StatsF.record (st : StatsF) (tr : List Act) (found : List (String × String)) : StatsF :=
  let st := if found.any (fun (c, _) => hardClasses.contains c) then { st with hard := st.hard + 1 } else st
  found.foldl (fun st (cls, why) =>
    if st.byClass.any (·.1 == cls) then
      { st with byClass := st.byClass.map fun e => if e.1 == cls then (e.1, e.2.1 + 1, e.2.2) else e }
    else { st with byClass := st.byClass ++ [(cls, 1, tr.reverse, why)] }) st

/-- `search` with the strict checker: every distinct canonical world
settled and judged once. -/
def searchF (R : Rules) (B : Bounds) : StatsF := Id.run do
  let w0 := initWorld B.rows
  let mut seen : Std.HashSet World := Std.HashSet.emptyWithCapacity 1024
  seen := seen.insert (canon w0)
  let mut frontier : Array (World × List Act) := #[(w0, [])]
  let mut st : StatsF := {}
  for _ in List.range (B.depth + 1) do
    let mut next : Array (World × List Act) := #[]
    for (w, tr) in frontier do
      st := { st with states := st.states + 1 }
      st := st.record tr (checkF R w)
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
def lostRange : Rules :=
  { name := "lost-range rule (sixth round, abandoned 2026-10-20): last-seq + F from the rows + the dump's own lost, refuse a dump without sync_epoch + stamp during rollback + class seq + remember the lost copy",
    lMode := .oracle, fMode := .rows, carry := .never, refuseNoEpoch := true, stampDuringRollback := true,
    keepClassSeq := true, rememberLost := true, newBypassCarry := true }

/-- The rule the previous round recommended: `F = max(counter, rows)`,
`restore.sh` carries the live `lost` into every restore and takes a dump
without the `sync_epoch` row, no lost-copy memory. -/
def prior : Rules :=
  { lostRange with
    name := "prior round: F = max(counter, rows) + carry the live lost into every restore + no lost-copy memory"
    fMode := .maxRows, carry := .always, refuseNoEpoch := false, rememberLost := false }

def abJump : Rules :=
  { lostRange with
    name := "ablation: (F, F+J] jump instead of last-seq"
    lMode := .jump }
def altOvershoot : Rules :=
  { lostRange with
    name := "alternative: last-seq overestimated by J"
    lMode := .oracleOver }
def abNoLastSeq : Rules :=
  { lostRange with
    name := "ablation: no last-seq (range (F, F], as written)"
    lMode := .counter }
def abCounterFloor : Rules :=
  { lostRange with
    name := "ablation: F = counter (no max(seq))"
    fMode := .counter }
def abMaxRowsF : Rules :=
  { lostRange with
    name := "ablation: F = max(counter, max(seq)) (the prior round's F)"
    fMode := .maxRows }
def abCarry : Rules :=
  { lostRange with
    name := "ablation: restore.sh carries the live lost into every restore"
    carry := .always }
def abAcceptCarry : Rules :=
  { lostRange with
    name := "ablation: restore.sh takes a dump without sync_epoch and carries the live lost"
    refuseNoEpoch := false
    carry := .noRow }
def abAcceptBare : Rules :=
  { lostRange with
    name := "ablation: restore.sh takes a dump without sync_epoch, no carry"
    refuseNoEpoch := false }
def abNoStamp : Rules :=
  { lostRange with
    name := "ablation: rollback UPDATEs keep the old seq (as written)"
    stampDuringRollback := false }
def altRestamp : Rules :=
  { lostRange with
    name := "alternative: re-enable restamps every row instead of stamping"
    stampDuringRollback := false
    restampOnReenable := true }
def abForgetSeq : Rules :=
  { lostRange with
    name := "ablation: the reset forgets the seq of the entries it keeps (as written)"
    keepClassSeq := false }
def abForgetLost : Rules :=
  { lostRange with
    name := "ablation: the reset forgets the hash and seq of a lost copy (as written)"
    rememberLost := false }
def abNewBypassFresh : Rules :=
  { lostRange with
    name := "ablation: new-project bypass keeps the freshly seeded empty lost"
    newBypassCarry := false }
def devRemoteWins : Rules :=
  { lostRange with
    name := "device variant: post-step write beats a lost `?`"
    lost := .remoteWins }
def devHybrid : Rules :=
  { lostRange with
    name := "device variant: post-step write beats an unchanged lost `?`"
    lost := .hybrid }

/-! ## The simple rule: server wins and shelves after an epoch change

Server: `restore.sh`, the standalone step and the step inside re-enable
each write a new epoch and `paused = true`, and the counter only moves up
(`max(counter, max seq over the rows)`). No floor, no `lost`, no carry,
no `--last-seq`, no stamping during a rollback. Device: an epoch change
resets the cursor and marks every baseline entry `stale`; the catch-up
pull lets the server win on every stale entry (a different local copy
goes to the shelf); an entry still stale at head is re-uploaded by POST; a
flush sends nothing unless the device has seen the current epoch and
`paused` is false. The rest of the §6 table is unchanged.

These rules are judged with the `P3d` split (`Rules.splitP3`); the sticky
checker is the same rule with `sticky := true` (`stickyOf`). -/

def serverWinsShelf : Rules :=
  { name := "simple: epoch only, server wins + shelf after an epoch change",
    epochOnly := true, reset := .stale, epochGate := true, splitP3 := true }

/-- Refinement: a stale entry whose old baseline hash is the incoming row
keeps its local edit (the §6 echo row), so an edit made on top of what the
server still has is not shelved. -/
def swFF : Rules :=
  { serverWinsShelf with
    name := "simple + fast-forward: a stale entry whose old base is the incoming row keeps its edit"
    staleFF := true }

/-- Refinement: a re-upload that finds the row already present stays
stale, so the server wins there too. -/
def swReup : Rules :=
  { serverWinsShelf with
    name := "simple + a re-upload that finds the row stays stale"
    reupStale := true }

def swFFReup : Rules :=
  { swFF with
    name := "simple + fast-forward + a re-upload that finds the row stays stale"
    reupStale := true }

/-- Control: the simple server with a device on which the local copy wins
after any epoch change. -/
def simpleLocalWins : Rules :=
  { serverWinsShelf with
    name := "control: simple server, local wins after any epoch change"
    reset := .allSentinel }

def abNoShelfOf (R : Rules) : Rules :=
  { R with name := R.name ++ " | ablation: adopt without shelving", staleShelf := false }
def abNoReuploadOf (R : Rules) : Rules :=
  { R with name := R.name ++ " | ablation: no re-upload of rows absent at head", staleReupload := false }
def abRewindRestoreOf (R : Rules) : Rules :=
  { R with name := R.name ++ " | ablation: restore.sh keeps the dump's setval (counter rewinds)", counterUp := false }
def abNoRaiseStepOf (R : Rules) : Rules :=
  { R with name := R.name ++ " | ablation: the standalone step does not raise the counter", stepRaise := false }
def abNoGateOf (R : Rules) : Rules :=
  { R with name := R.name ++ " | ablation: flush not gated on the epoch", epochGate := false }
def stickyOf (R : Rules) : Rules :=
  { R with name := R.name ++ " | sticky checker", sticky := true }

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
  verdict lostRange tr == none && verdict altOvershoot tr == none
#guard !liveInLost (run lostRange true w1 newerAfterOlder)
#guard failsWith lostRange forkRevert "P3s"
#guard [current, prior, lostRange, abAcceptCarry, abAcceptBare].all (failsWith · noRowBypassRevert "P3")
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
#guard (check lostRange (raceWorld lostRange false)).map (fun why => (why.splitOn " ").headD "") == some "P3"
#guard check lostRange (raceWorld lostRange true) == none

/-! ## The simple rule's own scenarios -/

/-- A edits X offline; an epoch step that restores nothing; A's catch-up
lets the server win and shelves A's edit of the very version the server
still has. -/
def stepEdit : List Act := [.edit 0 0, .standalone]

/-- A's pushed edit is discarded by a restore; before A sees it, A edits
X again on top of the discarded version. -/
def editOnDiscarded : List Act := [.dump true, .edit 0 0, .flush 0, .restore 0, .edit 0 0]

/-- The simple rule's standalone step WITHOUT the lock: it reads the
counter and the rows, an agent write then takes `nextval`, and the
`setval` that follows puts the counter back under that write's seq. -/
def simpleRace (R : Rules) (w : World) (r : Nat) : World :=
  let s := w.srv
  let c := if R.stepRaise then max s.counter (maxRowSeq s) else s.counter
  let w := agent R w r
  let (w, e) := freshEpoch w
  let s := w.srv
  { w with srv := { s with counter := c, highWater := max s.highWater c,
                           er := { epoch := e, floor := 0, lost := [], paused := true } } }

def raceWorldS (R : Rules) (locked : Bool) : World :=
  let w := bypass (run R true w1 [.dump true, .agent 0]) 0 R.sticky
  let w := if locked then agent R (standaloneStep R w) 0 else simpleRace R w 0
  run R true w raceTail

/-! ## Exhaustive, at build time (small bounds; the large ones are in
`lake exe syncrestoresearch`) -/

def buildBounds : Bounds :=
  { rows := 1, depth := 6, maxOps := 4, maxDumps := 2, prompt := true, noRowHand := false }

-- the current text has violations of P2 inside these bounds; the
-- recommended rule has none of P1, P2, P3 and never leaves a live row's
-- seq in `lost`; the prior round's rule does leave one; the X4 / X5 /
-- local-wins controls are caught
#guard (search current buildBounds).count "P2" > 0
#guard let st := search lostRange buildBounds; st.hard == 0 && st.p10 == 0
#guard (search prior buildBounds).p10 > 0
#guard (search abForgetSeq buildBounds).count "P2" > 0
#guard (search x4 buildBounds).hard > 0
#guard (search x5 buildBounds).hard > 0
#guard (search localWins buildBounds).count "P3" > 0

/-! ## The simple rule, checked -/

def verdict2 (R : Rules) (tr : List Act) : Option String := check R (run R true (initWorld 2) tr)

def classOf (v : Option String) : Option String := v.map fun why => (why.splitOn " ").headD ""

-- as stated, an edit made offline across an epoch step that restores
-- nothing goes to the shelf: a P3
#guard failsWith serverWinsShelf stepEdit "P3"
-- the fast-forward refinement keeps that edit
#guard verdict swFF stepEdit == none
-- both shelve an edit made, before the device saw the restore, on top of
-- a version that restore discarded
#guard [serverWinsShelf, swFF].all (failsWith · editOnDiscarded "P3d")
-- every earlier counterexample replays clean under the refinement, except
-- the fork, which becomes that same class
#guard [major1, minor2, lagging, scripted, twoBypass, abortLagging, rollbackRestore,
        restampRevert, resetAbandon, pausedRestore, stepThenRestore, newBypass,
        bypassOldRow, restoreKeepsAgain, newerAfterOlder].all fun tr => verdict swFF tr == none
#guard failsWith swFF forkRevert "P3d"
-- control: the same server with local-wins devices is caught
#guard failsWith simpleLocalWins stepEdit "P3"
#guard failsWith simpleLocalWins [.agent 0, .dump true, .restore 0] "P3"
-- each part of the refined rule is load-bearing
#guard failsWith (abNoShelfOf swFF) [.edit 0 0, .edit 1 0, .standalone] "P2"
#guard classOf (verdict2 (abNoReuploadOf swFF) [.edit 0 1, .dump true, .flush 0, .restore 0]) == some "P1"
#guard classOf (verdict2 (abNoReuploadOf swFF) [.edit 0 1, .edit 1 1, .dump true, .flush 0, .restore 0]) == some "P2"
#guard failsWith (abNoRaiseStepOf swFF) [.edit 0 0, .edit 1 0, .dump true, .flush 0, .pull 1, .abortSetval 0] "P1"
#guard failsWith (abNoGateOf swFF) [.edit 0 0, .dump true, .flush 0, .edit 0 0, .bypass 0, .agent 0, .flush 0] "P2"
-- restore.sh's own counter rewind is caught only once the epoch check is
-- not atomic with the write (a request that read the old epoch lands after
-- the restore)
#guard verdict (abRewindRestoreOf swFF) [.edit 0 0, .dump true, .flush 0, .edit 0 0, .restore 0, .agent 0, .flush 0] == none
#guard failsWith (abRewindRestoreOf (abNoGateOf swFF)) [.edit 0 0, .dump true, .flush 0, .edit 0 0, .restore 0, .agent 0, .flush 0] "P2"
#guard verdict (abNoGateOf swFF) [.edit 0 0, .dump true, .flush 0, .edit 0 0, .restore 0, .agent 0, .flush 0] == none
-- the step without its lock: the counter goes back under the racing write
#guard classOf (check swFF (run swFF true (simpleRace swFF (bypass (run swFF true w1 [.dump true, .agent 0]) 0) 0)
    [.unpause, .pull 0, .pull 1, .edit 0 0, .flush 0])) == some "P1"
#guard check swFF (run swFF true (agent swFF (standaloneStep swFF (bypass (run swFF true w1 [.dump true, .agent 0]) 0)) 0)
    [.unpause, .pull 0, .pull 1, .edit 0 0, .flush 0]) == none
-- at build-time bounds the refinement has nothing but the P3d class
#guard let st := search swFF buildBounds; st.count "P3d" > 0 && st.byClass.all (·.1 == "P3d")

/-! ## Independent check: offline edits the restore never saw

The default checker counts every version outside the dump's history as
rolled back, including an edit that only ever existed on an offline device,
and so never judges it under P3. `rbPushedOnly` counts a version as
discarded only when its content reached the server. -/

def pushedOf (R : Rules) : Rules := { R with rbPushedOnly := true }

/-- Candidate refinement: the fast-forward also accepts the version the
local edit chain started from. -/
def swFFOrigin : Rules :=
  { swFF with
    name := "simple + fast-forward against the old base or the edit's origin"
    staleFFOrigin := true }

/-- A edits X offline; B's edit lands after the dump; A pulls and keeps its
own edit (the §6 conflict row); the restore brings back the version A's edit
was built on. -/
def keptLocalConflict : List Act := [.dump true, .edit 0 0, .edit 1 0, .flush 1, .pull 0, .restore 0]

/-- The same, but A's PATCH lost the race to B's and is pending-verify. -/
def lostPatchRace : List Act := [.dump true, .edit 0 0, .edit 1 0, .flush 1, .flush 0, .restore 0]

/-- A's intermediate version, superseded by an edit A pushed after the dump:
its content reached the server inside the pushed one. -/
def intermediate : List Act := [.edit 0 0, .edit 0 0, .dump true, .flush 0, .restore 0]

#guard [keptLocalConflict, lostPatchRace].all fun tr =>
  verdict swFF tr == none && classOf (verdict (pushedOf swFF) tr) == some "P3"
#guard [keptLocalConflict, lostPatchRace].all fun tr => verdict (pushedOf lostRange) tr == none
#guard verdict (pushedOf swFF) intermediate == none
#guard classOf (verdict (pushedOf serverWinsShelf) [.edit 0 0, .dump true, .restore 0]) == some "P3"
#guard verdict serverWinsShelf [.edit 0 0, .dump true, .restore 0] == none

/-! ## The final rule (decided 2026-10-20)

The simple rule with its four patches (see "The final rule's device"):
`restore.sh`, the standalone step and re-enable each write a new epoch and
`paused = true`; the counter never goes down (`restore.sh`: max of the live
counter and the restored rows' highest seq; the step, under its lock: max
of the counter and the rows' highest seq). Off-script restores stay as
they are and are followed at once by the step (R3). Judged by the strict
checker (`judge`) with `rbPushedOnly`. -/

/-- The final rule. Agent writes are refused while `paused` outside a
rollback: a write the agent makes on a restored row before a device that
holds a discarded version has caught up makes that device take its copy
for an older one (`hiddenAfterRestore`); refusing them while paused closes
that window for as long as the operator keeps sync paused
(`agentWhilePausedOf` is the comparison; the guards pin one instance, the
search counts are in `checksearch`). During a rollback
they stay accepted: that is what the rollback is for, and re-enable's step
follows them. -/
def final : Rules :=
  { name := "final (recommended): server wins after an epoch change + server write gate + fast-forward on the old base or the edit's origin + pending delete wins + one recovery prompt",
    epochOnly := true, reset := .stale, epochGate := true, staleFF := true, staleFFOrigin := true,
    final := true, offer := .seq, rbPushedOnly := true, agentWhilePaused := false, reupStale := true }

def tagged (R : Rules) (s : String) : Rules := { R with name := R.name ++ " | " ++ s }
/-- patch 1 removed: no server gate, only the device's own (its last epoch GET) -/
def abServerGateOf (R : Rules) : Rules := { tagged R "ablation: no server write gate" with epochGate := false }
/-- patch 2 removed: the fast-forward reads only the old baseline -/
def abOriginOf (R : Rules) : Rules := { tagged R "ablation: no origin fast-forward" with staleFFOrigin := false }
/-- patch 3 removed: a pending delete meeting a catch-up adopts the incoming row -/
def abDeleteWinsOf (R : Rules) : Rules := { tagged R "ablation: a pending delete loses at the catch-up" with deleteWins := false }
/-- patch 4 removed: nothing is offered -/
def abOfferNoneOf (R : Rules) : Rules := { tagged R "ablation: the prompt offers nothing" with offer := .none }
def abOfferAllOf (R : Rules) : Rules := { tagged R "ablation: the prompt offers every catch-up entry" with offer := .all }
def abAcceptGuardOf (R : Rules) : Rules :=
  { tagged R "ablation: accept re-applies over any clean row" with acceptGuard := false }
def abEraseWarnOf (R : Rules) : Rules := { tagged R "ablation: log-out / erase wipes the shelf silently" with eraseWarn := false }
def abPruneOf (R : Rules) : Rules := { tagged R "variant: a restored entry stays offered" with prune := false }
def abFFOf (R : Rules) : Rules := { tagged R "ablation: no fast-forward at all" with staleFF := false }
def agentPausedOf (R : Rules) : Rules := { tagged R "variant: agent writes refused while paused" with agentWhilePaused := false }
def agentWhilePausedOf (R : Rules) : Rules :=
  { tagged R "variant: agent writes accepted while paused" with agentWhilePaused := true }
def noGateMarksOf (R : Rules) : Rules := { tagged R "variant: a rejected send restores its entry" with gateMarks := false }
def acceptCondOf (R : Rules) : Rules :=
  { tagged R "candidate: the prompt's restore is a conditional write" with acceptCond := true }
def originBackOf (R : Rules) : Rules :=
  { tagged R "candidate: restore hands the re-applied edit its own chain start as origin" with originBack := true }
/-- a re-upload's entry becomes `?` (local wins) instead of staying stale -/
def abReupStaleOf (R : Rules) : Rules :=
  { tagged R "ablation: a re-upload's entry turns local-wins before its POST lands" with reupStale := false }
def abTombInsertOf (R : Rules) : Rules :=
  { tagged R "ablation: a pending delete of a row the restore removed counts as done" with tombInsert := false }
/-- fix candidate for the hidden discarded copy: also offer a clean copy the device pushed itself -/
def offerOwnOf (R : Rules) : Rules := { tagged R "candidate: also offer the device's own pushed copy" with offer := .seqOwn }
/-- fix candidate needing a server column: compare with the row's seq at the last epoch step -/
def offerEpochOf (R : Rules) : Rules := { tagged R "candidate: compare with the row's seq at the last epoch step (server column)" with offer := .epoch }
/-- control: flips a field the final rule never reads (`keepClassSeq` is read
only by the lost-range reset) -/
def noopOf (R : Rules) : Rules := { tagged R "no-op control" with keepClassSeq := !R.keepClassSeq }
/-- the round-1 checkers, for comparison -/
def allRBOf (R : Rules) : Rules := { tagged R "checker: every version outside the dump counts as discarded" with rbPushedOnly := false }
def docOf (R : Rules) : Rules :=
  { tagged R "checker: markRolledBack as its docstring states it" with rbPushedOnly := false, rbDocstring := true }

def classesF (R : Rules) (rows : Nat) (tr : List Act) : List String :=
  (checkF R (run R true (initWorld rows) tr)).map (·.1)

def hardF (R : Rules) (rows : Nat) (tr : List Act) : List String :=
  (classesF R rows tr).filter (hardClasses.contains ·)

/-! ## The final rule, checked

Each patch and part is pinned by a replay the final rule passes (no hard
class) and its ablation fails with the named class; the residual the
final rule keeps is pinned too. Row 0 is X, row 1 is Y; device 0 is A. -/

def hardIs (R : Rules) (rows : Nat) (tr : List Act) (cls : List String) : Bool :=
  hardF R rows tr == cls

/-- An offline edit, a gated (rejected) send, a second epoch change: the
rejected send left `?@seq`, so only the remembered origin keeps the edit. -/
def originTwice : List Act := [.edit 0 0, .standalone, .flush 0, .standalone]

/-- A pending delete across an epoch change. -/
def deleteStep : List Act := [.delete 0 0, .standalone]

/-- Y is created after the dump and deleted on A before A sends the
tombstone; B holds Y; the restore removes Y; B re-uploads it. -/
def deleteRemoved : List Act := [.edit 0 1, .dump true, .flush 0, .delete 0 1, .pull 1, .restore 0]

/-- A behind on X; the agent edits it; an epoch step; A's catch-up shelves
its old copy and the prompt's restore re-applies it. -/
def staleOffered : List Act := [.agent 0, .standalone, .unpause, .pull 0, .accept 0]

/-- A's offline edit loses the catch-up to the agent's concurrent edit and
is offered; A then edits the row again and pushes; restore is pressed. -/
def acceptAfterMove : List Act :=
  [.edit 0 0, .agent 0, .standalone, .unpause, .pull 0, .edit 0 0, .flush 0, .accept 0]

/-- Round 1's gate witness, with the unpause the refused agent write
needs: a bypass's step rewinds nothing, but A's PATCH from the old epoch
lands on the seq the agent's new write reused. -/
def gateWitness : List Act :=
  [.edit 0 0, .dump true, .flush 0, .edit 0 0, .bypass 0, .unpause, .agent 0, .flush 0]

/-- The residual: A's pushed edit is discarded by the restore; after the
operator clears `paused` the agent edits the restored row before A comes
back; A's copy is older by seq than the agent's, so A shelves it unoffered. -/
def hiddenAfterRestore : List Act := [.edit 0 0, .dump true, .flush 0, .restore 0, .unpause, .agent 0]

/-- The unlocked step: the racing write takes a seq the step's `setval`
then hands out again. -/
def raceStepWitness : List Act := [.stepRace 0, .unpause, .pull 0, .agent 0]

-- patch 1: without the server gate the bypass's seq reuse loses the agent's edit
#guard hardIs final 1 gateWitness [] && hardIs (abServerGateOf final) 1 gateWitness ["P2"]
-- patch 2: the remembered origin keeps an edit whose send was rejected,
-- and the edit of a PATCH that lost its race (round 1's witnesses)
#guard hardIs final 1 originTwice [] && hardIs (abOriginOf final) 1 originTwice ["P3"]
#guard hardIs final 1 lostPatchRace [] && hardIs (abOriginOf final) 1 lostPatchRace ["P3"]
#guard hardIs final 1 keptLocalConflict []
-- patch 3: a pending delete wins the catch-up; without it the delete is undone
#guard hardIs final 1 deleteStep [] && hardIs (abDeleteWinsOf final) 1 deleteStep ["DELu"]
-- the tombstone insert: a pending delete of a row the restore removed
-- survives the other device's re-upload
#guard hardIs final 2 deleteRemoved [] && hardIs (abTombInsertOf final) 2 deleteRemoved ["DELu"]
-- patch 4: an edit built on a discarded version is offered (accepted P3d);
-- with no prompt it is hidden
#guard classesF final 1 editOnDiscarded == ["P3d"]
#guard hardIs (abOfferNoneOf final) 1 editOnDiscarded ["P2h", "P3h"]
-- the classification: offering a clean copy that was only behind lets
-- restore revert the newer row
#guard hardIs final 1 staleOffered [] && hardIs (abOfferAllOf final) 1 staleOffered ["PA", "P3"]
-- the accept condition: re-applying over a row that moved on overwrites
-- the newer edit
#guard hardIs final 1 acceptAfterMove [] && hardIs (abAcceptGuardOf final) 1 acceptAfterMove ["PA"]
-- the shelf, the re-upload, the step's counter raise, the step's lock
#guard hardIs final 1 [.edit 0 0, .edit 1 0, .standalone] [] &&
  hardIs (abNoShelfOf final) 1 [.edit 0 0, .edit 1 0, .standalone] ["P2"]
#guard hardIs final 2 [.edit 0 1, .standalone, .flush 0] [] &&
  hardIs (abNoReuploadOf final) 2 [.edit 0 1, .standalone, .flush 0] ["P1", "P2"]
#guard hardIs final 1 [.edit 0 0, .edit 1 0, .dump true, .flush 0, .pull 1, .abortSetval 0] [] &&
  hardIs (abNoRaiseStepOf final) 1 [.edit 0 0, .edit 1 0, .dump true, .flush 0, .pull 1, .abortSetval 0] ["P1"]
#guard hardIs final 1 raceStepWitness ["P1"] && hardIs final 1 [.agent 0, .standalone, .unpause, .pull 0, .agent 0] []
-- the log-out / erase warning
#guard hardIs final 1 [.edit 0 0, .agent 0, .pull 0, .flush 0, .erase 0] [] &&
  hardIs (abEraseWarnOf final) 1 [.edit 0 0, .agent 0, .pull 0, .flush 0, .erase 0] ["P2"]
-- accepted classes, each offered: the cross-epoch residual, a resurrection
#guard classesF final 1 [.edit 0 0, .dump true, .agent 0, .abortSetval 0, .unpause, .pull 0, .restore 0] == ["P3x"]
#guard classesF final 1 [.dump true, .agentDel 0, .restore 0] == ["RES"]
-- the residual the final rule keeps (hard), and the server column that
-- would close this instance of it; refusing agent writes while paused
-- closes it only inside the paused window
#guard hardIs final 1 hiddenAfterRestore ["P2h"]
#guard hardIs (offerEpochOf final) 1 hiddenAfterRestore []
#guard hardIs final 1 (hiddenAfterRestore.erase .unpause) [] &&
  hardIs (agentWhilePausedOf final) 1 (hiddenAfterRestore.erase .unpause) ["P2h"]
-- a concurrent edit that wins after the restore hides the other device's
-- discarded copy, as §6 itself would (reported, not hard)
#guard classesF final 1 [.edit 0 0, .edit 1 0, .dump true, .flush 1, .restore 0] == ["P2hc"]
-- the same hole without any later write: a rollback's write kept the seq
-- of the version under it, so after the restore takes the row back the
-- device's copy and the restored row carry the same seq, and the offer
-- test cannot see that the server went back (hard)
#guard hardIs final 1 rollbackRestore ["P2h"]
-- deletes and the prompt: an own edit that lost to a tombstone is offered
-- again when a restore brings the row back (accepted P3x); a tombstone's
-- killed content is the delete's doing; a pending delete another
-- tombstone ended is undone by a restore as a resurrection (RES); an own
-- unsent edit meeting a tombstone at a catch-up loses as in §6 (reported)
#guard classesF final 1 [.edit 0 0, .dump true, .agentDel 0, .pull 0, .restore 0] == ["P3x", "RES"]
#guard hardIs final 1 [.edit 0 0, .delete 1 0, .dump true, .flush 0, .flush 1, .pull 0, .restore 0] []
#guard classesF final 1 [.delete 0 0, .dump true, .agentDel 0, .pull 0, .restore 0] == ["RES"]
#guard classesF final 1 [.edit 0 0, .agentDel 0, .standalone] == ["P2c"]
-- an own edit that lost to a tombstone is offered again when another
-- device's re-upload brings the row back after the restore
#guard hardIs final 2 [.edit 0 1, .dump true, .flush 0, .edit 0 1, .pull 1, .agentDel 1, .pull 0, .restore 0] []
-- a re-upload waits as server-wins: B's re-upload marker meets A's newer
-- re-upload, which lands first (round 1's "first re-upload wins")
#guard hardIs final 2 [.edit 0 1, .dump true, .flush 0, .edit 0 1, .pull 1, .restore 0, .unpause, .pull 1] [] &&
  hardIs (abReupStaleOf final) 2 [.edit 0 1, .dump true, .flush 0, .edit 0 1, .pull 1, .restore 0, .unpause, .pull 1] ["P3h"]
-- an entry the prompt's restore re-applied, whose row a later restore then
-- took back below it, is the cross-epoch residual, offered again
#guard hardIs final 1 [.edit 0 0, .edit 0 0, .dump true, .agent 0, .abortSetval 0, .unpause, .pull 0, .accept 0,
  .restore 0] []
-- an offline edit loses the catch-up to an older restored row; a later
-- restore of a newer dump puts the row back on the edit's own parent: the
-- entry, re-aimed when its row's copy was shelved in turn, is offered and
-- the prompt's restore re-applies it forward
def secondRestoreTrace : List Act :=
  [.edit 0 0, .dump true, .flush 0, .edit 0 0, .dump true, .restore 0, .unpause, .pull 0, .restore 1]
#guard hardIs final 1 secondRestoreTrace [] && (classesF final 1 secondRestoreTrace).contains "P3x"
#guard hardIs final 1 (secondRestoreTrace ++ [.unpause, .pull 0, .accept 0]) [] &&
  !(classesF final 1 (secondRestoreTrace ++ [.unpause, .pull 0, .accept 0])).contains "P3x"
-- the same, with the entry re-applied by the prompt before the second
-- restore: the second catch-up shelves the edit again and offers it (P3x);
-- the `originBack` candidate fast-forwards it instead, but loses the
-- fast-forward an edit re-applied over the agent's row needs after a
-- rejected send (it reverts there)
def secondRestoreAccept : List Act :=
  [.edit 0 0, .dump true, .flush 0, .edit 0 0, .dump true, .restore 0, .unpause, .pull 0, .accept 0, .restore 1]
def acceptThenRejected : List Act :=
  [.edit 0 0, .agent 0, .standalone, .unpause, .pull 0, .accept 0, .standalone, .flush 0]
#guard hardIs final 1 secondRestoreAccept [] && (classesF final 1 secondRestoreAccept).contains "P3x"
#guard classesF (originBackOf final) 1 secondRestoreAccept == []
#guard classesF final 1 acceptThenRejected == [] && hardIs (originBackOf final) 1 acceptThenRejected ["P3"]
-- the second residual the final rule keeps (hard): a clean copy the
-- restore discarded is re-applied by the prompt and edited further; a
-- restore of a newer dump brings that copy back; the catch-up does not
-- fast-forward the edit (its origin is the row the copy was re-applied
-- over), shelves it and offers it. Neither the candidate above nor the
-- final rule keeps it live
def restoreEditRestore : List Act :=
  [.edit 0 0, .dump true, .flush 0, .dump true, .restore 0, .unpause, .pull 0, .accept 0, .edit 0 0, .restore 1]
#guard hardIs final 1 restoreEditRestore ["P3"] && hardIs (originBackOf final) 1 restoreEditRestore ["P3"]
-- the third (hard): both devices press restore for the same row; A's newer
-- edit lands first and B's older copy then wins the §6 conflict, hiding A's.
-- Restore as a conditional write (the candidate) sends B's copy back to
-- the prompt instead
def doubleAccept : List Act :=
  [.edit 0 0, .dump true, .flush 0, .edit 0 0, .pull 1, .restore 0, .unpause, .pull 0, .accept 0, .pull 1, .accept 1]
#guard hardIs final 1 doubleAccept ["P3h"] && hardIs (acceptCondOf final) 1 doubleAccept []
-- the no-op control changes nothing
#guard [originTwice, deleteStep, editOnDiscarded, staleOffered, acceptAfterMove, gateWitness,
        hiddenAfterRestore, lostPatchRace, keptLocalConflict].all fun tr =>
  classesF (noopOf final) 1 tr == classesF final 1 tr

/-- Build-time exhaustive search of the final rule (one row, every operator
action, the prompt's actions). -/
def finalBounds : Bounds :=
  { rows := 1, depth := 5, maxOps := 3, maxDumps := 2, prompt := true, prompts := true }

#guard let st := searchF final finalBounds
  st.hard == 0 && st.count "P3d" > 0 && st.byClass.all fun e => !hardClasses.contains e.1
#guard (searchF (abOfferNoneOf final) finalBounds).hard > 0

end SyncRestore
end Verification
