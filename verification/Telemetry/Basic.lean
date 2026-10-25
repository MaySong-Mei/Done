/-!
# Telemetry chassis — the pure upload semantics and their executable core (gh#273)

Model of the pure half of `Done/Models/TelemetryModel.swift` as the design
specifies it (`Docs/telemetry/00-telemetry-chassis-design.md` §4.2, §7.2,
§8.2, §11 and `Docs/telemetry/01-wire-contract.md` §1, §3, §5, both at
`0d9efca`). This module was built from the SPEC before the Swift file
existed; `Done/Models/TelemetryModel.swift` now exists and is replayed
against the differential fixtures (`Telemetry/Fixtures.lean`,
`lake exe telemetryfixturegen`, `DoneTests/LeanTelemetryReplayTests.swift`,
58/58). Deliberately NOT modelled: the per-row isolation set the
implementation added in round 2 (`UploadCursor.quarantined`,
`TelemetryUploader.isolateRows`) — the cursor here has only `uploaded`,
so theorems about pending/acknowledge speak to the un-quarantined path.

Five pure pieces, one definition each, shared by the theorems
(`Telemetry/Theorems.lean`) and the fixture generator so the proved
artifact and the evaluated artifact cannot drift:

* `ClaimKey.adopts` — §4.2 认领键: today's daily record is taken over only
  when `(buildConfiguration, appBuild, osVersion, ownerUID)` are ALL equal.
* `Cursor` — §7.2 游标: `run_id → uploadedRevision`, read as a total
  function with default 0 (Swift's `uploaded[id] ?? 0`); `pending` keeps the
  records whose `revision` exceeds it; `acknowledge` takes the per-id max
  and never moves backwards.
* `Server.step` — §9.2 / wire §3 BEFORE UPDATE guard: `new.revision <=
  old.revision → skip`; the row's state is `Option Nat` (absent, or the held
  revision).
* `consentFilter` — §8.2 / wire §5 同意水位: `startedAt ≥ consent_at` and
  `ownerUID == 当前 uid`; no `consent_at` → nothing.
* `selectBatch` — §7.1 / wire §5 退后台边沿: events only, plus the daily
  rollup when the last daily upload is ≥ 15 minutes ago; the other three
  triggers take everything; events before dailies, then `startedAt`
  ascending, cut at `limit` (32).

Representation choices, each a decision the spec leaves open and each
reported upstream rather than settled here (see the README's Telemetry
section): record ids are a type parameter (`Nat` in the fixtures, mapped
to fixed UUID literals); instants are Unix seconds (`Int`); revisions are
`Nat` (the wire contract starts them at 1 — a record carrying revision 0
is below the cursor's default and is never pending, `pending_iff`);
"today's daily" at a background edge is every pending `dailyRollup` — the
Swift signature `selectBatch(pending, trigger, lastDailyUploadAt, now,
limit)` carries no day key, so there is nothing else to test;
`metricKitDaily` is neither an event nor the daily rollup, so a background
edge never carries it; a `nil` current owner uploads nothing (§4.1 "`nil`
= 签出期,永不上传"), where a literal Swift `==` on two `nil`s would pass
the record.
-/

namespace Verification.Telemetry

/-- `TelemetryRecordKind` (design §4.1 `kind`). `userReport` is reserved
and not modelled. -/
inductive Kind where
  | dailyRollup
  | window
  | manualRun
  | verdictSnapshot
  | metricKitDaily
  deriving DecidableEq, Repr

/-- §7.1 (4) "上传只带事件记录(窗口、快照、手动 run)": the three event kinds. -/
def Kind.isEvent : Kind → Bool
  | .window | .verdictSnapshot | .manualRun => true
  | .dailyRollup | .metricKitDaily => false

/-- `TelemetryClaimKey` (§4.2). `ownerUID = none` is the signed-out state. -/
structure ClaimKey where
  buildConfiguration : String
  appBuild : String
  osVersion : String
  ownerUID : Option String
  deriving DecidableEq, Repr

/-- §4.2 "只在 (buildConfiguration, appBuild, osVersion, ownerUID) 全部相同时
接管;任一不同就为同一天铸新 run id" — Swift `==` on the key. -/
def ClaimKey.adopts (today incoming : ClaimKey) : Bool := decide (today = incoming)

/-- The slice of a `SpikeRun` the pure semantics read: identity, the
monotone `revision` (§4.1), `kind`, `startedAt` (Unix seconds) and the
minting account. -/
structure Record (Id : Type) where
  id : Id
  revision : Nat
  kind : Kind
  startedAt : Int
  ownerUID : Option String

/-- `UploadCursor` (§7.2): `run_id → uploadedRevision`, read through
`uploaded[id] ?? 0` — so the model IS the total function. -/
structure Cursor (Id : Type) where
  uploaded : Id → Nat

namespace Cursor

variable {Id : Type} [DecidableEq Id]

/-- The empty (or corrupt — §7.2 "游标损坏 = 空游标") cursor. -/
def empty : Cursor Id := ⟨fun _ => 0⟩

/-- A finite dictionary as a cursor: absent keys read 0. -/
def ofList (entries : List (Id × Nat)) : Cursor Id :=
  ⟨fun id => (entries.find? (fun p => p.1 = id)).map Prod.snd |>.getD 0⟩

/-- One acknowledged `(id, revision)`: `uploaded[id] = max(uploaded[id] ?? 0, revision)`. -/
def bump (c : Cursor Id) (id : Id) (rev : Nat) : Cursor Id :=
  ⟨fun i => if i = id then max (c.uploaded i) rev else c.uploaded i⟩

/-- `acknowledge(ids:)`: the batch's `(id, revision)` pairs folded through
`bump`, in the order given. §7.2 "只在 2xx 后写回" is the caller's duty; the
"绝不回退" is `bump`'s `max`. -/
def acknowledge (c : Cursor Id) (acks : List (Id × Nat)) : Cursor Id :=
  acks.foldl (fun c p => c.bump p.1 p.2) c

/-- §7.2 "只有本地 `revision > uploadedRevision` 的记录进批". -/
def isPending (c : Cursor Id) (r : Record Id) : Bool := decide (c.uploaded r.id < r.revision)

/-- `pending(records)`: the records the cursor has not covered, in input order. -/
def pending (c : Cursor Id) (records : List (Record Id)) : List (Record Id) :=
  records.filter c.isPending

/-- The largest revision the batch acknowledges for `id` (0 when none). -/
def revMax (acks : List (Id × Nat)) (id : Id) : Nat :=
  acks.foldl (fun m p => if p.1 = id then max m p.2 else m) 0

end Cursor

/-! The server's row, keyed by `(user_id, run_id)` outside the model: absent,
or holding a `revision` (wire §3). -/
namespace Server

/-- `TelemetryServerModel.apply(existing:incoming:)`: wire §3 "BEFORE UPDATE:
`new.revision <= old.revision` → `return null`(跳过)"; an INSERT (no row)
always lands. -/
def accepts (existing : Option Nat) (incoming : Nat) : Bool :=
  match existing with
  | none => true
  | some e => decide (e < incoming)

/-- The row after one delivery. -/
def step (existing : Option Nat) (incoming : Nat) : Option Nat :=
  if accepts existing incoming then some incoming else existing

/-- The row after a sequence of deliveries, in arrival order. -/
def fold (existing : Option Nat) (deliveries : List Nat) : Option Nat :=
  deliveries.foldl step existing

end Server

/-- §8.2 / wire §5 "只发 `started_at ≥ consent_at` 且 `ownerUID == 当前 uid`
的记录"; §8.2 "打开记 `consent_at`" — no `consent_at` means the switch was
never on, so nothing is eligible. A `nil` current owner is the signed-out
state and uploads nothing (§4.1; see the module comment). -/
def consentFilter {Id : Type} (records : List (Record Id))
    (consentAt : Option Int) (currentOwner : Option String) : List (Record Id) :=
  match consentAt, currentOwner with
  | some t, some owner =>
    records.filter fun r => decide (t ≤ r.startedAt) && decide (r.ownerUID = some owner)
  | _, _ => []

/-- `TelemetryTrigger` (§7.1's four trigger points). -/
inductive Trigger where
  | launch
  | dayRollover
  | deckOpen
  | backgroundEdge
  deriving DecidableEq, Repr

/-- §7.1 (4) "距上次上传 ≥15 分钟" in seconds. -/
def dailyGapSeconds : Int := 900

/-- The daily rollup rides a background edge only when the last daily upload
is at least `dailyGapSeconds` ago — or there has never been one. -/
def dailyGateOpen (lastDailyUploadAt : Option Int) (now : Int) : Bool :=
  match lastDailyUploadAt with
  | none => true
  | some t => decide (dailyGapSeconds ≤ now - t)

/-- Which pending records a trigger admits (§7.1 (4) / wire §5). -/
def admits {Id : Type} (trigger : Trigger) (lastDailyUploadAt : Option Int) (now : Int)
    (r : Record Id) : Bool :=
  match trigger with
  | .backgroundEdge =>
    r.kind.isEvent || (decide (r.kind = .dailyRollup) && dailyGateOpen lastDailyUploadAt now)
  | .launch | .dayRollover | .deckOpen => true

/-- Sort rank: events first (0), dailies after (1). -/
def Record.rank {Id : Type} (r : Record Id) : Nat := if r.kind.isEvent then 0 else 1

/-- The batch order: rank, then `startedAt` ascending (a total preorder; ties
keep input order because `List.mergeSort` is stable). -/
def before {Id : Type} (a b : Record Id) : Bool :=
  decide (a.rank < b.rank) || (decide (a.rank = b.rank) && decide (a.startedAt ≤ b.startedAt))

/-- The admitted records in batch order, before the size cut. -/
def orderBatch {Id : Type} (pending : List (Record Id)) (trigger : Trigger)
    (lastDailyUploadAt : Option Int) (now : Int) : List (Record Id) :=
  (pending.filter (admits trigger lastDailyUploadAt now)).mergeSort before

/-- `selectBatch(pending, trigger, lastDailyUploadAt, now, limit = 32)`:
wire §5 "每批 ≤32 行". -/
def selectBatch {Id : Type} (pending : List (Record Id)) (trigger : Trigger)
    (lastDailyUploadAt : Option Int) (now : Int) (limit : Nat := 32) : List (Record Id) :=
  (orderBatch pending trigger lastDailyUploadAt now).take limit

/-! ## One upload round (§7.2 end to end) -/

/-- The server table restricted to one user: `run_id → revision held`. -/
structure ServerState (Id : Type) where
  held : Id → Option Nat

namespace ServerState

variable {Id : Type} [DecidableEq Id]

def empty : ServerState Id := ⟨fun _ => none⟩

/-- One row of the bulk upsert through the BEFORE UPDATE guard. -/
def upsert (s : ServerState Id) (r : Record Id) : ServerState Id :=
  ⟨fun i => if i = r.id then Server.step (s.held i) r.revision else s.held i⟩

/-- One bulk upsert: every row of the batch, in body order. -/
def applyBatch (s : ServerState Id) (batch : List (Record Id)) : ServerState Id :=
  batch.foldl upsert s

end ServerState

/-- Client cursor plus server table. -/
structure World (Id : Type) where
  cursor : Cursor Id
  server : ServerState Id

namespace World

variable {Id : Type} [DecidableEq Id]

/-- The batch a round sends. -/
def batch (w : World Id) (records : List (Record Id)) (trigger : Trigger)
    (lastDailyUploadAt : Option Int) (now : Int) (limit : Nat) : List (Record Id) :=
  selectBatch (w.cursor.pending records) trigger lastDailyUploadAt now limit

/-- A round that gets its 2xx: the server applies the batch, the client
acknowledges every row at the revision it sent. -/
def roundOK (w : World Id) (records : List (Record Id)) (trigger : Trigger)
    (lastDailyUploadAt : Option Int) (now : Int) (limit : Nat) : World Id :=
  let b := w.batch records trigger lastDailyUploadAt now limit
  { cursor := w.cursor.acknowledge (b.map fun r => (r.id, r.revision))
    server := w.server.applyBatch b }

/-- A round whose response never counts as 2xx (5xx, URLError, a stale erase
epoch): the cursor does not move. Whether the server applied the body is
unknown to the client, so the model keeps BOTH outcomes reachable:
`serverApplied = true` is the "request landed, response lost" case. -/
def roundFailed (w : World Id) (records : List (Record Id)) (trigger : Trigger)
    (lastDailyUploadAt : Option Int) (now : Int) (limit : Nat)
    (serverApplied : Bool) : World Id :=
  let b := w.batch records trigger lastDailyUploadAt now limit
  { cursor := w.cursor
    server := if serverApplied then w.server.applyBatch b else w.server }

end World

end Verification.Telemetry
