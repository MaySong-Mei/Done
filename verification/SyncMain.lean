import CivilCalendar

/-!
Sync fixture generator: `lake exe syncfixturegen`, run from `verification/`
(the file is written into the working directory; the generator refuses to
run anywhere `lakefile.toml` is not present), writes `sync-fixtures.json` —
the §6 decision table of the six id tables (design/realtime-sync @ 34a7810
plus the round-eight/nine working-tree edits: the `≤` skip row, the
pending-delete row, and the conflict rows writing the incoming row's
`(hash, seq)`) enumerated over a small domain, every expectation
computed by `Verification.Sync.decideRow` (the exact function the theorems
in `CivilCalendar/SyncMerge.lean` are proved about), never by hand. The
Swift replay executes the real applier's pure decision core against these
rows; the field contract is in `verification/README.md`. The three
singleton tables are not in this table.
-/

open Verification.Sync

/-- Hashes are opaque tokens to the replay; the domain is the tokens named here. -/
def hashName : Nat → String
  | 0 => "A"
  | 1 => "B"
  | _ => "C"

def jsonStr (s : String) : String := "\"" ++ s ++ "\""

def jsonOptHash : Option Nat → String
  | none => "null"
  | some h => jsonStr (hashName h)

def jsonOptNat : Option Nat → String
  | none => "null"
  | some n => toString n

def jsonBool : Bool → String
  | true => "true"
  | false => "false"

def actionName : Action → String
  | .skip => "skip"
  | .tombstone => "tombstone"
  | .echo => "echo"
  | .same => "same"
  | .adopt => "adopt"
  | .conflict => "conflict"

/-- One decision-table case: the inputs of `decideRow`. -/
structure Case where
  tomb : Bool
  hIn : Nat
  hLoc : Option Nat
  hBase : Option (Nat × Nat)
  inSeq : Nat

def Case.decision (c : Case) : Decision :=
  decideRow c.tomb c.hIn c.hLoc c.hBase c.inSeq

def Case.label (c : Case) : String :=
  let loc := (c.hLoc.map hashName).getD "absent"
  let base := (c.hBase.map fun (h, s) => hashName h ++ "@" ++ toString s).getD "absent"
  let kind := if c.tomb then "tombstone" else "live"
  s!"{kind} in={hashName c.hIn} loc={loc} base={base} seq={c.inSeq}"

def Case.json (c : Case) : String :=
  let d := c.decision
  "{\"label\":" ++ jsonStr c.label
    ++ ",\"tombstone\":" ++ jsonBool c.tomb
    ++ ",\"h_in\":" ++ jsonStr (hashName c.hIn)
    ++ ",\"h_loc\":" ++ jsonOptHash c.hLoc
    ++ ",\"h_base\":" ++ jsonOptHash (c.hBase.map Prod.fst)
    ++ ",\"base_seq\":" ++ jsonOptNat (c.hBase.map Prod.snd)
    ++ ",\"in_seq\":" ++ toString c.inSeq
    ++ ",\"expected\":{\"action\":" ++ jsonStr (actionName d.action)
    ++ ",\"base_hash\":" ++ jsonOptHash (d.base.map Prod.fst)
    ++ ",\"base_seq\":" ++ jsonOptNat (d.base.map Prod.snd)
    ++ ",\"shelf_remote\":" ++ jsonBool d.shelfRemote
    ++ ",\"shelf_local\":" ++ jsonBool d.shelfLocal
    ++ "}}"

/-- The full product of the small domain: tombstone or live; incoming hash
from the tokens; local absent or a token; baseline absent or a token at
one of two seqs; incoming seq from a range that, for EVERY baseline seq,
holds a value strictly below it, the value equal to it, and a value
strictly above it. The equal and strictly-below cases exercise the `≤`
skip row (the only place a seq enters the decision); the local-absent
cases with a baseline exercise the pending-delete row. -/
def domain : List Case :=
  let hashes : List Nat := [0, 1, 2]
  let locs : List (Option Nat) := none :: hashes.map some
  let baseSeqs : List Nat := [2, 3]
  let inSeqs : List Nat := [1, 2, 3, 4]
  let bases : List (Option (Nat × Nat)) :=
    none :: (hashes.flatMap fun h => baseSeqs.map fun s => some (h, s))
  [false, true].flatMap fun tomb =>
    hashes.flatMap fun hIn =>
      locs.flatMap fun hLoc =>
        bases.flatMap fun hBase =>
          inSeqs.map fun inSeq => { tomb, hIn, hLoc, hBase, inSeq }

def main : IO Unit := do
  unless (← System.FilePath.pathExists "lakefile.toml") do
    throw <| IO.userError
      "syncfixturegen: run from verification/ — lakefile.toml not found in the working directory"
  let cases := domain
  let body := String.intercalate ",\n  " (cases.map (·.json))
  IO.FS.writeFile "sync-fixtures.json" ("[\n  " ++ body ++ "\n]\n")
  let perAction := [Action.skip, .tombstone, .echo, .same, .adopt, .conflict].map fun a =>
    (actionName a, (cases.filter fun c => c.decision.action = a).length)
  let cwd ← IO.currentDir
  IO.println s!"wrote {cases.length} sync fixtures to {cwd / "sync-fixtures.json"}, by action {perAction}"
