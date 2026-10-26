import Telemetry.Basic

/-!
# Differential fixtures — the model ↔ Swift seam (gh#273)

Every `expected` below is computed by the SAME definitions the theorems in
`Telemetry/Theorems.lean` are proved about — never written by hand. The
generator (`TelemetryMain.lean`, `lake exe telemetryfixturegen`) writes
`telemetry-fixtures.json`; `DoneTests/LeanTelemetryReplayTests.swift`
dispatches each row on `op` to the matching `TelemetryModel.swift` API.

Record ids are small naturals here and fixed UUID literals on the wire
(`uuid`); instants are Unix seconds; owners are the staging QA accounts'
names as opaque strings. Each case names the theorem boundary it pins.
-/

namespace Verification.Telemetry.Fixtures

open Verification.Telemetry

abbrev Id := Nat

/-- Fixed UUID literal for record `n`: `00000000-0000-4000-8000-{n:012}`. -/
def uuid (n : Nat) : String :=
  let s := toString n
  let pad := String.ofList (List.replicate (12 - s.length) '0')
  "00000000-0000-4000-8000-" ++ pad ++ s

/-! ## JSON (hand-rolled, like the other generators — core Lean only) -/

def jsonStr (s : String) : String := "\"" ++ s ++ "\""

def jsonOptStr : Option String → String
  | none => "null"
  | some s => jsonStr s

def jsonOptInt : Option Int → String
  | none => "null"
  | some v => toString v

def jsonOptNat : Option Nat → String
  | none => "null"
  | some v => toString v

def jsonBool : Bool → String
  | true => "true"
  | false => "false"

def jsonArr (xs : List String) : String := "[" ++ String.intercalate "," xs ++ "]"

def jsonObj (kvs : List (String × String)) : String :=
  "{" ++ String.intercalate "," (kvs.map fun (k, v) => jsonStr k ++ ":" ++ v) ++ "}"

/-- Swift `TelemetryRecordKind` case names (the replay switches on these, not
on the wire's snake_case `rawValue`). -/
def kindName : Kind → String
  | .dailyRollup => "dailyRollup"
  | .window => "window"
  | .manualRun => "manualRun"
  | .verdictSnapshot => "verdictSnapshot"
  | .metricKitDaily => "metricKitDaily"

/-- Swift `TelemetryTrigger` case names. -/
def triggerName : Trigger → String
  | .launch => "launch"
  | .dayRollover => "dayRollover"
  | .deckOpen => "deckOpen"
  | .backgroundEdge => "backgroundEdge"

def recordJson (r : Record Id) : String :=
  jsonObj [("id", jsonStr (uuid r.id)), ("revision", toString r.revision),
    ("kind", jsonStr (kindName r.kind)), ("startedAt", toString r.startedAt),
    ("ownerUID", jsonOptStr r.ownerUID)]

def idsJson (rs : List (Record Id)) : String := jsonArr (rs.map fun r => jsonStr (uuid r.id))

/-- A cursor dictionary over the ids named. -/
def cursorJson (ids : List Id) (c : Cursor Id) : String :=
  jsonObj (ids.map fun i => (uuid i, toString (c.uploaded i)))

def claimJson (k : ClaimKey) : String :=
  jsonObj [("buildConfiguration", jsonStr k.buildConfiguration), ("appBuild", jsonStr k.appBuild),
    ("osVersion", jsonStr k.osVersion), ("ownerUID", jsonOptStr k.ownerUID)]

structure Case where
  op : String
  label : String
  input : String
  expected : String

def Case.json (c : Case) : String :=
  jsonObj [("op", jsonStr c.op), ("label", jsonStr c.label), ("input", c.input),
    ("expected", c.expected)]

/-! ## Case builders — one per `op`, each evaluating the model -/

def dedup (l : List Nat) : List Nat :=
  l.foldl (fun acc x => if acc.contains x then acc else acc ++ [x]) []

/-- `cursor.acknowledge`: input a cursor dictionary and the acknowledged
`(id, revision)` pairs in order; expected the dictionary afterwards, over
every id either side names (absent keys read 0 on both sides). -/
def ackCase (label : String) (cursor : List (Nat × Nat)) (acks : List (Nat × Nat)) : Case :=
  let ids := dedup (cursor.map (·.1) ++ acks.map (·.1))
  let c := Cursor.ofList cursor
  { op := "cursor.acknowledge", label
    input := jsonObj [
      ("cursor", jsonObj (cursor.map fun (i, r) => (uuid i, toString r))),
      ("acks", jsonArr (acks.map fun (i, r) =>
        jsonObj [("id", jsonStr (uuid i)), ("revision", toString r)]))]
    expected := jsonObj [("cursor", cursorJson ids (c.acknowledge acks))] }

/-- `cursor.pending`: expected the `(id, revision)` of the records the cursor
has not covered, in input order. -/
def pendingCase (label : String) (cursor : List (Nat × Nat)) (records : List (Record Id)) : Case :=
  let c := Cursor.ofList cursor
  { op := "cursor.pending", label
    input := jsonObj [
      ("cursor", jsonObj (cursor.map fun (i, r) => (uuid i, toString r))),
      ("records", jsonArr (records.map recordJson))]
    expected := jsonObj [("records", jsonArr ((c.pending records).map fun r =>
      jsonObj [("id", jsonStr (uuid r.id)), ("revision", toString r.revision)]))] }

/-- `server.apply`: one delivery through the BEFORE UPDATE guard. -/
def applyCase (label : String) (existing : Option Nat) (incoming : Nat) : Case :=
  { op := "server.apply", label
    input := jsonObj [("existing", jsonOptNat existing), ("incoming", toString incoming)]
    expected := jsonObj [("accepted", jsonBool (Server.accepts existing incoming)),
      ("state", jsonOptNat (Server.step existing incoming))] }

/-- `server.fold`: a delivery sequence, in arrival order. -/
def foldCase (label : String) (existing : Option Nat) (deliveries : List Nat) : Case :=
  { op := "server.fold", label
    input := jsonObj [("existing", jsonOptNat existing),
      ("deliveries", jsonArr (deliveries.map toString))]
    expected := jsonObj [("state", jsonOptNat (Server.fold existing deliveries))] }

/-- `consent.filter`: expected the surviving ids in input order. -/
def consentCase (label : String) (consentAt : Option Int) (owner : Option String)
    (records : List (Record Id)) : Case :=
  { op := "consent.filter", label
    input := jsonObj [("consentAt", jsonOptInt consentAt), ("currentOwner", jsonOptStr owner),
      ("records", jsonArr (records.map recordJson))]
    expected := jsonObj [("ids", idsJson (consentFilter records consentAt owner))] }

/-- `claim.adopts`. -/
def claimCase (label : String) (today incoming : ClaimKey) : Case :=
  { op := "claim.adopts", label
    input := jsonObj [("today", claimJson today), ("incoming", claimJson incoming)]
    expected := jsonObj [("adopts", jsonBool (today.adopts incoming))] }

/-- `batch.select`: expected the chosen ids IN ORDER. -/
def batchCase (label : String) (trigger : Trigger) (last : Option Int) (now : Int) (limit : Nat)
    (pending : List (Record Id)) : Case :=
  { op := "batch.select", label
    input := jsonObj [("trigger", jsonStr (triggerName trigger)),
      ("lastDailyUploadAt", jsonOptInt last), ("now", toString now),
      ("limit", toString limit), ("pending", jsonArr (pending.map recordJson))]
    expected := jsonObj [("ids", idsJson (selectBatch pending trigger last now limit))] }

/-! ## The domain -/

/-- 2026-10-24 ≈ 10:40 UTC. -/
def t0 : Int := 1761300000

def qaA : Option String := some "qa-a"
def qaB : Option String := some "qa-b"

def rec (id rev : Nat) (kind : Kind := .window) (startedAt : Int := t0)
    (owner : Option String := qaA) : Record Id :=
  { id, revision := rev, kind, startedAt, ownerUID := owner }

def cursorCases : List Case := [
  ackCase "ack: empty cursor, empty batch" [] [],
  ackCase "ack: first upload of a fresh id lands revision 1 (from `?? 0`)" [] [(1, 1)],
  ackCase "ack: a LOWER revision is a no-op (never regress)" [(1, 3)] [(1, 2)],
  ackCase "ack: the SAME revision is a no-op (idempotent 2xx)" [(1, 3)] [(1, 3)],
  ackCase "ack: a higher revision advances" [(1, 3)] [(1, 5)],
  ackCase "ack: mixed batch, order A" [(1, 3), (2, 1)] [(2, 4), (1, 2), (3, 1)],
  ackCase "ack: mixed batch, order B (permutation of A — same cursor)"
    [(1, 3), (2, 1)] [(3, 1), (1, 2), (2, 4)],
  ackCase "ack: one id acknowledged four times in a batch — max wins, not last"
    [(1, 2)] [(1, 5), (1, 4), (1, 9), (1, 1)],
  ackCase "ack: acknowledging the result of order A again changes nothing"
    [(1, 3), (2, 4), (3, 1)] [(2, 4), (1, 2), (3, 1)],
  pendingCase "pending: empty cursor — every revision ≥ 1 is pending"
    [] [rec 1 1, rec 2 1, rec 3 2],
  pendingCase "pending: covered at 1, the next append (2) is pending"
    [(1, 1)] [rec 1 1, rec 2 2 (startedAt := t0 + 1)],
  pendingCase "pending: revision 0 is below the `?? 0` default and never pending"
    [] [rec 1 0, rec 2 1],
  pendingCase "pending: duplicates of one id at two revisions — only the higher is pending"
    [(1, 2), (2, 5)] [rec 1 3, rec 2 5, rec 3 1, rec 2 6 (startedAt := t0 + 60)],
  pendingCase "pending: after acknowledging a batch, only revisions above it remain"
    [(1, 3), (2, 4)] [rec 1 3, rec 2 4, rec 1 4 (startedAt := t0 + 5)],
  pendingCase "pending: no records" [(1, 7)] []
]

def serverCases : List Case := [
  applyCase "apply: INSERT into an empty slot" none 1,
  applyCase "apply: same revision twice → skipped, row keeps 3" (some 3) 3,
  applyCase "apply: 7 then 5 → 5 skipped, row stays 7 (§11.2)" (some 7) 5,
  applyCase "apply: 5 then 7 → accepted" (some 5) 7,
  applyCase "apply: revision 0 into an empty slot still inserts" none 0,
  applyCase "apply: 0 then 1 → accepted" (some 0) 1,
  foldCase "fold: nothing delivered → no row" none [],
  foldCase "fold: 1,2,3 in order → 3" none [1, 2, 3],
  foldCase "fold: 3,1,2 out of order → 3" none [3, 1, 2],
  foldCase "fold: held 4, then 7 then 5 → 7" (some 4) [7, 5],
  foldCase "fold: held 4, then 5 then 7 → 7" (some 4) [5, 7],
  foldCase "fold: held 9, three stale 3s → 9" (some 9) [3, 3, 3],
  foldCase "fold: 2 retransmitted → 2 (retry = once)" none [2, 2],
  foldCase "fold: held 7, 7 again → 7" (some 7) [7]
]

def consentRecords : List (Record Id) := [
  rec 1 1 .window (t0 - 1) qaA,
  rec 2 1 .window t0 qaA,
  rec 3 1 .dailyRollup (t0 + 1) qaA,
  rec 4 1 .window (t0 + 2) qaB,
  rec 5 1 .window (t0 + 3) none
]

def consentCases : List Case := [
  consentCase "consent: no consent_at → nothing" none qaA consentRecords,
  consentCase "consent: at t0 — startedAt t0−1 dropped, t0 kept (≥), owners filtered"
    (some t0) qaA consentRecords,
  consentCase "consent: later watermark t0+1 — strict subset of the t0 result (id 3 only)"
    (some (t0 + 1)) qaA consentRecords,
  consentCase "consent: other owner qa-b keeps only qa-b's record"
    (some t0) qaB consentRecords,
  consentCase "consent: signed out (nil owner) uploads nothing, even nil-owned records"
    (some t0) none [rec 1 1 .window t0 none, rec 2 1 .window t0 qaA],
  consentCase "consent: no consent_at AND signed out → nothing" none none consentRecords,
  consentCase "consent: no records" (some t0) qaA []
]

def keyRelease11 : ClaimKey :=
  { buildConfiguration := "release", appBuild := "11", osVersion := "26.0.1", ownerUID := qaA }

def claimCases : List Case := [
  claimCase "claim: identical key adopts" keyRelease11 keyRelease11,
  claimCase "claim: signed out on both sides (nil owner) adopts"
    { keyRelease11 with ownerUID := none } { keyRelease11 with ownerUID := none },
  claimCase "claim: nil owner vs signed-in → new id"
    { keyRelease11 with ownerUID := none } keyRelease11,
  claimCase "claim: build 10 → 11 same day → new id (§11.9)"
    { keyRelease11 with appBuild := "10" } keyRelease11,
  claimCase "claim: debug vs release → new id"
    { keyRelease11 with buildConfiguration := "debug" } keyRelease11,
  claimCase "claim: OS updated mid-day → new id"
    { keyRelease11 with osVersion := "26.0" } keyRelease11,
  claimCase "claim: qa-a → qa-b same day → new id (§11.9)"
    keyRelease11 { keyRelease11 with ownerUID := qaB }
]

/-- 30 windows then 3 daily rollups; `startedAt` ascending by id. -/
def thirtyThree : List (Record Id) :=
  (List.range 30).map (fun i => rec (i + 1) 1 .window (t0 + i))
    ++ [rec 31 1 .dailyRollup (t0 + 30), rec 32 1 .dailyRollup (t0 + 31),
        rec 33 1 .dailyRollup (t0 + 32)]

def mixed : List (Record Id) := [
  rec 1 2 .dailyRollup (t0 - 3600),
  rec 2 1 .window (t0 + 10),
  rec 3 1 .verdictSnapshot (t0 + 5),
  rec 4 1 .manualRun (t0 - 20),
  rec 5 1 .metricKitDaily (t0 - 7200)
]

def batchCases : List Case := [
  batchCase "batch: launch — events first by startedAt, then dailies by startedAt"
    .launch (some (t0 - 10)) t0 32 mixed,
  batchCase "batch: launch with exactly 32 pending → all 32"
    .launch none t0 32 (thirtyThree.take 32),
  batchCase "batch: launch with 33 pending → 32, the latest daily is cut"
    .launch none t0 32 thirtyThree,
  batchCase "batch: edge, never uploaded a daily → daily rides"
    .backgroundEdge none t0 32 mixed,
  batchCase "batch: edge, last daily exactly 15 min ago (900 s) → daily rides (≥)"
    .backgroundEdge (some (t0 - 900)) t0 32 mixed,
  batchCase "batch: edge, last daily 899 s ago → daily held back, events still go"
    .backgroundEdge (some (t0 - 899)) t0 32 mixed,
  batchCase "batch: edge never carries metricKitDaily (gate open)"
    .backgroundEdge none t0 32 [rec 5 1 .metricKitDaily (t0 - 7200), rec 2 1 .window t0],
  batchCase "batch: edge with only dailies inside the gap → empty"
    .backgroundEdge (some (t0 - 10)) t0 32
      [rec 1 1 .dailyRollup (t0 - 3600), rec 5 1 .metricKitDaily (t0 - 7200)],
  batchCase "batch: dayRollover ignores the 15-min gate (daily 10 s after last upload)"
    .dayRollover (some (t0 - 10)) t0 32 mixed,
  batchCase "batch: deckOpen ignores the 15-min gate"
    .deckOpen (some (t0 - 10)) t0 32 mixed,
  batchCase "batch: ties (same kind class, same startedAt) keep input order"
    .launch none t0 32
      [rec 7 1 .window t0, rec 3 1 .manualRun t0, rec 9 1 .dailyRollup t0,
       rec 1 1 .dailyRollup t0],
  batchCase "batch: limit 1 takes the first event only"
    .launch none t0 1 mixed,
  batchCase "batch: limit 0 → empty" .launch none t0 0 mixed,
  batchCase "batch: nothing pending → empty" .launch none t0 32 [],
  batchCase "batch: dailyRollup and metricKitDaily share the daily rank, startedAt decides"
    .launch none t0 32 [rec 1 1 .dailyRollup (t0 + 100), rec 5 1 .metricKitDaily (t0 + 50)]
]

def allCases : List Case :=
  cursorCases ++ serverCases ++ consentCases ++ claimCases ++ batchCases

end Verification.Telemetry.Fixtures
