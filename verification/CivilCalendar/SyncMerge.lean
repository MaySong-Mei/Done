/-!
# Sync merge — the §6 apply table, the 015 server, and their laws (gh#257)

Model of `Docs/sync/00-realtime-sync-design.md` as it stands on
design/realtime-sync @ 34a7810 (v1.4 after review seven) PLUS the
uncommitted round-eight/nine edits of that file in the working tree. The
design is in flux; the model follows the working tree and names what it
takes from each layer:

* from the uncommitted working-tree edits: the §6 skip row is
  `seq ≤ h_base.seq → 跳过` (34a7810 has `==`); the conflict row and the
  pending-delete row write the baseline `(h_in, seq)` (34a7810 keeps the
  old hash, "hash 不动保持脏" — kept here only as `decideRowKeepHash`),
  so a baseline always names the version the server held at its seq;
  the settings per-key baseline after a merge is the remote key's hash on
  every key, conflict keys included; the `skillAnalyzedEventIds` union is
  written back in a canonical order; the event_types winner ranges over
  LIVE namesakes only and is the newest `updated_at`, ties and undated
  views to the smallest UUID (gh#257); both settings sides changing a key to the same
  bytes is not a conflict; a remote key deletion overridden by a local
  change is shelved;
* from 34a7810 over 6a7e50b (v1.3): the skip row itself; the
  pending-verify set `(table, id, sentSeq, sentHash, pullIssue)`; the
  pending-delete row (本地 absent 且基线有 id → 按 dirty 处理); the
  tombstone row removing a present baseline entry when the local row is
  absent; the mandatory `deleted_at` check on a `[row]` PATCH response;
  the singleton-table tombstone rule;
* model decisions the text does not state yet (each reported in the
  gh#257 thread, each with the witness against the alternative): a
  PATCH `[row]` response that arrives after a pull moved the baseline is
  dropped — it writes `(hash sent, row.seq)` only if the baseline seq is
  still the seq the PATCH carried (`Replica.recv`; the text writes it
  unconditionally, `recvUnguarded`, `late_row_response_regresses_witness`);
* followed as the text has it, with the cost the text does not state:
  our own push's echo pulled BEFORE the push's response meets the
  pre-push baseline, so the table files our own bytes as a conflict
  (or, if the user set the row back to the baseline's bytes meanwhile,
  adopts our own pushed bytes over that revert) — the "顺序敏感"
  guarantee holds only when
  the response is applied first
  (`echo_before_response_shelves_own_push_witness`, both orders
  reachable: `echo_race_reachable`); `decideRowInflight`, which treats
  the sent hash of the PATCH outstanding for the id as an echo, is the
  variant under which the race IS the sequential order
  (`inflight_race_matches_sequential`).

The working tree has since moved to v1.5. Its §6 rule rows are the ones
above, unchanged; what v1.5 adds around them and this model does NOT
represent: the `?` baseline hash of a write whose outcome is unknown
(S4) — `Replica.base` has no hash equal to none and no hash without a
seq, so `Reachable.lose` is the earlier "a throw keeps the baseline"
reading that S4 replaces (`lost_then_revert_reachable` is the hole S4
closes; `unknown_marker_witness` checks S4's arithmetic on concrete runs
with a stand-in hash, it does not model `?`); the epoch / floor reset
after a server rollback (§6.6, D10); the failure classes and the
`rejected` table (S1); the owner guard (S5); the cursor generations
(S11). v1.5's single-flight pulls (I9) agree with this model's
sequential pulls; its restore replay writing `hash(cloud row)@cloud seq`
(S6), with 7a2e382e's merge rule for the rows the cloud did not carry, is
`Reachable.restore` (below).

Also modelled: the §4 invariants I3, I4, I6, I7 and I8 (I1 enters as the
`Chain` of T5'), and the row-level semantics of
`done-mcp/supabase/migrations/015_sync_change_feed.sql` — seq
assignment, the content-identical short-circuit, I6 (a tombstone
survives ordinary writes), the delete→tombstone rewrite (I4), and the
request-filter stale write guard (I8).

What the model does not express, so that no theorem is read as covering
it:

* I2 (no outbound echo) and the outbound sink: there is none here.
* I5 (seq order = commit order) is not a property of this sequential
  server; it is what makes a `sync_changes` page a SNAPSHOT. The model's
  `pull` takes any list, so every theorem that needs I5 says so by
  requiring `IsHeadFeed s₀ cursor page` (or the limit-cut `IsPageFeed`)
  for some server state `s₀` the current one `Advances` from. A witness
  built on a page that is not a snapshot of any state proves nothing
  about the design; the one this file used to carry (`scenarioAPage`)
  is kept only as the negative `scenarioAPage_not_head`.
* Concurrency inside the client: operations are sequential except that a
  conditional PATCH's response may arrive late or never
  (`Reachable.send` / `Reachable.recv` / `Reachable.lose`, at most one
  upload per id outstanding). A POST's response arriving late (two
  guards the text could state for it are compared in
  `late_post_response_guards_witness`, outside `Reachable`), two pulls
  interleaved, and a PATCH built before a pull and sent after it are
  not modelled. The pending-verify rule's `sentSeq` and `sentHash` are
  carried (`Pending`) and their branches proved and witnessed; its
  `pullIssue` eligibility is modelled in its sequential form only:
  `Reachable.verify` is a head page of the CURRENT server at the moment
  the pass is APPLIED, so the pull was issued after every `[]` it
  clears and nothing landed between its fetch and its apply. The text's
  eligibility is wider — an eligible pull whose page goes stale before
  it is applied (a peer's write, or a push of ours, landing between the
  RPC and the apply) — and that interleaving is outside `Reachable`.
  `pullVerify` by itself runs the pass after any page and is not the
  rule; `ineligible_verify_loses_witness` is what an ineligible pass
  loses (design interleaving (i)).
* One hash function. `Reachable` fixes `hash`; a build that changes the
  row-hash encoding (the state T9a starts from) is outside it, and on
  reachable states the verify pass's confirm branch never fires
  (`reachable_verify_is_pull`).
* Restore IS a `Reachable` constructor: `EventStore.applyRestore`
  (merge with per-row keepLocal / keepCloud, or overwrite) on the id
  tables, then `markRestoreCompleted` → `replayBaseline`, then the
  REWIND — the cursor becomes `min(cursor, C0)`, `C0` the cursor
  captured before the first table is fetched (the Swift has it since
  9121ba12) — with the merge rule the user decided after 9121ba12
  (`fix/restore-keep-local-deletes`): a pending local delete (an entry,
  no local row) stays deleted and keeps its entry, whether or not the
  snapshot carries the row, so its tombstone still goes up
  (`restore_merge_keeps_pending_delete`, `restore_pending_delete_sent`;
  the 9121ba12 rule brought the row back, `restore_revives_pending_delete_control`).
  `reachable_sound`, `clean_iff_matches_server`, `synced_below_of_clean`
  and the convergence theorems cover restored replicas. Two premises on
  the snapshot, both what the keyset-walk fetch run after `C0` was
  captured guarantees: `hread`, every snapshot row is a live row some
  state of the run at or above `C0` held at its seq (each page is read
  at whatever state the server is then in — not one consistent
  snapshot); `hall`, asked of an OVERWRITE only, the snapshot carries, at
  its version there, every row live at one such state (the one the last
  page was read at; a row rewritten during the walk is read again at its
  new seq and the later copy wins). The truthfulness half
  (`reachInv_restore`) needs `hread` alone; `hall` is used only for
  `BaseCoversBelow`, and only for an overwrite — a merge now loses no
  entry (`restore_merge_base_kept`), so a merge of a snapshot missing a
  live row is a `Reachable` step
  (`restore_incomplete_snapshot_merge_instance`). An overwrite of one —
  an undecodable row the decoder skips, the walk's safety cap — is
  outside `Reachable`: it drops a row live on the server below the
  cursor with nothing flagging it
  (`restore_overwrite_incomplete_snapshot_witness`). Without the rewind
  (`unfixedStep`, the Swift as of 7a2e382e) the same premises admit a
  snapshot older than a version the replica already pulled, and an edit
  is lost (`restore_stale_snapshot_witness`) or a row the replica pulled
  is dropped by an overwrite with nothing flagging it
  (`overwrite_drops_pulled_row_control`). Not covered of the fix: a pull
  whose page was requested before the rewind and is saved after it.
  `pull` here is atomic — the page fetched and applied in one step — so
  the race the fix closes by stopping such a pull from saving its cursor
  is outside the model, and nothing here says the fix closes it. The
  account / epoch check before the apply is outside too (one account, no
  epoch here). Not modelled of the restore:
  the singleton tables' replay (user_settings, agent_preferences,
  agent_conversations); event_types, which `EventTypeTemplateStore`
  restores by normalized title, not by id; a cloud row carried without
  a seq (`Snapshot`) and an id the replay spells differently from the
  server; the entry's `?` marker, version id and catch-up marker, which
  the replay drops or keeps but the model's baseline does not have.
  Where the Swift's late-response guard (the whole `?@sentSeq` entry)
  and the model's (`Replica.recv`, the seq only) part ways after a
  restore that wrote the PATCH's own seq from an older snapshot: the
  model applies the late `[row]`, the Swift drops it and settles through
  one more `[]` and the pull; both are sound. The replays before
  7a2e382e are positive controls, each reaching a state a theorem rules
  out: `pre_merge_unsent_row_clean_control` (the shipped bug — a merge's
  row the cloud never had reads clean, `unsent_row_never_clean`),
  `pre_merge_previous_seq_control` (`BaseHeld`), and slice 1's
  `slice1_collision_clean_control` (`BaseHashSound`,
  `clean_iff_matches_server`; `restore_replay_local_hash_witness` is its
  state without the run).
* The shelf is a list of `(id, content)`: the shelf row's seq (the
  incoming row's, also for a tombstone's local version) and the
  `(uid, table, id, seq)` dedup are not represented — re-application
  idempotence comes from the skip row (T2b/T2c). §6.1's whole-page
  refusal when a shelf append fails, the frozen-slot precheck, and the
  tombstone PATCH's throw-keeps-the-baseline branch (`pushDelete` always
  succeeds) are not modelled.
* The design keys baselines and the pending set by `(table, id)` — the
  three user_id-keyed tables share the uid as id. The model keys by `Id`
  alone; read every `id` here as a `(table, id)` pair. The cross-table
  collision the design warns about is unrepresentable here.
* The `pull` filter `cursor < seq` is CLIENT-side here; the design's
  `sync_changes` filters `seq > since_seq` on the server and the client
  applies the whole page. The two agree on a snapshot page (its rows
  are past the cursor it was fetched from); the filter is what lets a
  page fetched at an OLD cursor be applied after the cursor moved
  (Scenario A), which the design's actor ordering also allows.
* I3's persist unit is "every page, every touched slot once". The row
  theorems (`applyRow_after_slot_only_heals`, T2b/T2c) are per row; the
  page fold is proved for a page all of whose rows are in the
  slot-written-baseline-unwritten state (`pull_after_slot_only_heals`),
  which is the state of one slot's rows after that slot's persist
  returned true and the baseline write was lost. A page mixing slots in
  different states is not covered.
* The upgrade path's hash-only baseline (`<hash>` without `@<seq>`, §6.3)
  has no representation — `Replica.base` is `Option (Hash × Seq)`, so a
  row the design would hold clean-without-seq looks dirty here.
* The six id tables and the three singleton tables are DIFFERENT
  models. `decideRow` / `applyRow` / `pushRow` are the id tables: the
  tombstone row removes the local row and the baseline entry, the
  dead-row PATCH response is treated as an incoming tombstone. The
  singleton tables (user_settings, agent_preferences, agent_conversations)
  never delete or reset locally and never shelve on a tombstone; their
  rule is the `Singleton` namespace (which has no pending-verify pass:
  the singleton `[]` closure by `sentHash` / `sentKeys` is not
  modelled, `singleton_edit_to_dead_bytes_witness`), and every tombstone theorem on
  `applyRow` (T4, T5, `applyRow_tomb_absent`, the `Inv` family — whose
  `noDead` is false on a singleton table by design, `Reachable`,
  `clean_iff_matches_server`) is about the six id tables only. The
  singleton tables' live-row rules (user_settings per key,
  agent_preferences / agent_conversations whole row) are not composed
  with `Singleton`; the witnesses that need a live row after an undelete
  apply the id-table live rows, which are the whole-row three-way. The
  fixtures are the id tables only.
* The undelete RPC (gh#140) is not a `ClientOp`: `tombstone_monotone`
  is scoped to ordinary writes by construction. Account erase (015's
  `pg_trigger_depth() > 1` arm) physically deletes rows; `Advances.keep`
  excludes it — the design handles erase by `$session → nil`, not by
  the applier.
* event_types: `EventTypes.resolve` is per normalized title and is not
  composed with the row table or with `pushDelete`; the two
  loser-tombstone paths of the text (collection diff when the loser is
  in the baseline, applier PATCH when the incoming row is the loser)
  are one `tombstones` field here. Attributes (colorHex …) are not
  modelled. The client decides a title with three or more namesakes as
  one set (dated only if every candidate is dated); the model is the
  pairwise rule, whose mixed dated/undated form is not transitive
  (`mixed_pair_rule_cycles_witness`).
* user_settings: `Settings.mergeRow` is the per-key pass with the row
  seq skip and the post-merge per-key baseline; the `sentKeys` form of
  pending-verify (the per-key `sentHash`) is not modelled — it is the
  row-level `verifyUnseen` with the hash replaced by the key-hash table,
  gated by the same `base.seq == sentSeq` test, and T9b's argument is
  per row. The time-zone key's projected dirty test (the pusher's
  projection: the server's value wins when it has one) is not modelled;
  `mergeAnalyzedIds` is per key and is not composed into `mergeKeys`.

Everything is abstract and deterministic. `Hash` and `Seq` are `Nat`;
`Content` is a type parameter; the design's own assumption that
`rowHash` (SHA-256 of the canonical row) never collides is the explicit
hypothesis `HashInjective`, stated only on the theorems that need it.

House style: `decideRow` is the executable, law-free decision core — the
§6 table in the stated order — and `applyRow` is its effect on a
replica. The fixture generator (`SyncMain.lean`) evaluates the SAME
`decideRow` the theorems are proved about, so the proved artifact and
the emitted artifact cannot drift. Variants of the table — the v1.3
table without the skip row, the 34a7810 `==` skip row, the table
without the pending-delete row, the conflict row keeping the old hash,
two checks swapped — and the variants of the rules around it — the late
`[row]` written unguarded, the singleton tombstone keeping a dirty
row's hash — exist only to witness what each choice buys and what the
table does not guard.
-/

namespace Verification
namespace Sync

abbrev Id := Nat
abbrev Hash := Nat
abbrev Seq := Nat

/-- The design's own assumption: distinct rows hash to distinct values.
Stated as a hypothesis, never baked into the model. -/
def HashInjective {C : Type} (hash : C → Hash) : Prop :=
  ∀ a b, hash a = hash b → a = b

/-! ## Server — the 015 row semantics -/

/-- One server row: content (kept on tombstones, I4), its change number,
and the tombstone flag (`deleted_at is not null`). -/
structure Row (C : Type) where
  content : C
  seq : Seq
  deleted : Bool
deriving DecidableEq

/-- The server for one user: rows by id, and the global `sync_seq`
counter (last value handed out). -/
structure Server (C : Type) where
  rows : Id → Option (Row C)
  counter : Seq

namespace Server

variable {C : Type} [DecidableEq C]

/-- `nextval('sync_seq')`. -/
def next (s : Server C) : Seq := s.counter + 1

def setRow (s : Server C) (id : Id) (row : Row C) (counter : Seq) :
    Server C :=
  { rows := fun i => if i = id then some row else s.rows i, counter }

/-- `PATCH /t?id=eq.X&seq=eq.<base>` with `Prefer: return=representation`.
The request filter matches only when the server's seq equals the client's
base (I8); inside the match, the BEFORE trigger keeps `old.deleted_at`
(I6) and drops a content-identical write without a seq. The response is
`[row]` (`some row`, the row as written — content, new seq, and the
KEPT `deleted_at`, bench S7) or `[]` (`none`) — the client branches on
the body only. -/
def patch (s : Server C) (id : Id) (base : Seq) (c : C) :
    Server C × Option (Row C) :=
  match s.rows id with
  | none => (s, none)
  | some row =>
    if row.seq ≠ base then (s, none)
    else if row.content = c then (s, none)
    else
      (s.setRow id { content := c, seq := s.next, deleted := row.deleted } s.next,
        some { content := c, seq := s.next, deleted := row.deleted })

/-- `POST /t` with `Prefer: resolution=ignore-duplicates, return=representation`
for a row the client has no base seq for. A duplicate is DO NOTHING — but
the BEFORE INSERT trigger has already burned a seq (the design's
"ON CONFLICT 下 seq 烧两次" note); the response omits the row. A server
TOMBSTONE is a duplicate too: see `post_onto_tombstone_never_lands_witness`. -/
def insertIgnore (s : Server C) (id : Id) (c : C) : Server C × Option Seq :=
  match s.rows id with
  | some _ => ({ s with counter := s.next }, none)
  | none =>
    (s.setRow id { content := c, seq := s.next, deleted := false } s.next,
      some s.next)

/-- A delete reaching the server — the client's
`PATCH …?id=eq.X&deleted_at=is.null`, or a physical DELETE rewritten by
trigger 4 into `set deleted_at = coalesce(deleted_at, now())`. Both are
idempotent (a second delete matches no live row / is content-identical),
both keep the content, and both mint a seq only when the row flips —
`deleted_at` is not in the trigger's `meta` set, so the flip is a content
change. Neither carries a seq filter: `pushDelete_unconditional`. -/
def tombstone (s : Server C) (id : Id) : Server C × Bool :=
  match s.rows id with
  | none => (s, false)
  | some row =>
    if row.deleted then (s, false)
    else (s.setRow id { row with seq := s.next, deleted := true } s.next, true)

/-- A pre-015 client's unconditional upsert (`resolution=merge-duplicates`,
no base, no `deleted_at` in the body): `INSERT … ON CONFLICT DO UPDATE`.
The INSERT arm burns a seq, then the UPDATE arm runs the same BEFORE
trigger — I6 keeps the tombstone, identical content is dropped. -/
def legacyUpsert (s : Server C) (id : Id) (c : C) : Server C :=
  match s.rows id with
  | none => s.setRow id { content := c, seq := s.next, deleted := false } s.next
  | some row =>
    if row.content = c then { s with counter := s.next }
    else
      s.setRow id { content := c, seq := s.next + 1, deleted := row.deleted }
        (s.next + 1)

/-- Every write shape a client — current or pre-015 — can send. The
undelete RPC (gh#140) is not one of them. -/
inductive ClientOp (C : Type) where
  | patch (id : Id) (base : Seq) (c : C)
  | insertIgnore (id : Id) (c : C)
  | tombstone (id : Id)
  | legacyUpsert (id : Id) (c : C)

def step (s : Server C) : ClientOp C → Server C
  | .patch id base c => (s.patch id base c).1
  | .insertIgnore id c => (s.insertIgnore id c).1
  | .tombstone id => (s.tombstone id).1
  | .legacyUpsert id c => s.legacyUpsert id c

/-- What a reader at head sees for `id`: the content if the row is live,
nothing if it is absent or tombstoned. -/
def live (s : Server C) (id : Id) : Option C :=
  match s.rows id with
  | some row => if row.deleted then none else some row.content
  | none => none

def Deleted (s : Server C) (id : Id) : Prop :=
  ∃ row, s.rows id = some row ∧ row.deleted = true

/-- No row carries a seq the counter has not handed out. -/
def WF (s : Server C) : Prop :=
  ∀ id row, s.rows id = some row → row.seq ≤ s.counter

end Server

/-! ## Replica — the §6 decision core and its effect -/

/-- The rows of the §6 table, in table order. `skip` is the first row;
the pending-delete row (本地 absent 且基线有 id) decides `conflict`, as
the text says ("按 dirty 处理"). -/
inductive Action where
  | skip | tombstone | echo | same | adopt | conflict
deriving DecidableEq, Repr

/-- What one incoming row decides: which table row fired, the new baseline
entry for the id (`none` = entry removed; on `skip` the old entry), and
which side's version goes to the shelf. The local-content effect is a
function of `action` alone (see `applyRowWith`). -/
structure Decision where
  action : Action
  base : Option (Hash × Seq)
  shelfRemote : Bool
  shelfLocal : Bool
deriving DecidableEq, Repr

/-- Row 1's test: the baseline names this seq or a later one — the row
was applied before (a re-pulled page, our own push's `[row]` response)
or is a stale page's older version of a row we already hold newer. -/
def staleOrSeen (hBase : Option (Hash × Seq)) (inSeq : Seq) : Bool :=
  match hBase with
  | some (_, S) => decide (inSeq ≤ S)
  | none => false

/-- Rows 2 to 7 of the §6 table, in the stated order — everything after
the skip row:

* tombstone — local removed (the cascade), a DIRTY local version shelved
  first, baseline entry removed also when the local row is absent
  (a pending local delete meeting the server's tombstone: "基线若有 id
  一并移除");
* `h_in == h_base.hash` — echo: nothing, baseline `(h_in, seq)` (equal to
  `(h_base.hash, seq)` in this row);
* `h_in == h_loc` — same: nothing, baseline `(h_in, seq)`;
* 本地 absent 且基线有 id — a pending local delete meets a peer's edit:
  "按 dirty 处理" — local stays absent, the incoming row is shelved,
  baseline `(h_in, seq)`; the next flush's tombstone PATCH (no seq
  filter, no hash) still goes out, delete beats edit;
* `!dirty 或 本地 absent` — adopt, baseline `(h_in, seq)`; after the row
  above, "本地 absent" here can only be absent-with-no-baseline, which
  is `!dirty` (`none = none`);
* dirty — conflict: local kept, incoming shelved, baseline `(h_in, seq)`
  whether or not a baseline existed (the M1 case — the next push must be
  a PATCH, not a POST that ignore-duplicates swallows — is the same
  writing). The local row stays dirty: this row is reached only when
  `h_loc ≠ h_in` (`decideRow_conflict_still_dirty`).

The baseline column therefore has three writings: skip keeps the entry,
tombstone removes it, every other row writes `(h_in, seq)` — the version
the server held at that seq (`decideRow_base_noskip`). The superseded
conflict writing `(h_base.hash, seq)` is the variant `decideRowKeepHash`;
`conflict_then_revert_reads_clean_witness` shows what it cost.

`dirty` is `h_loc ≠ h_base.hash` with an absent side counting as a
value. -/
def decideRowBody (tomb : Bool) (hIn : Hash) (hLoc : Option Hash)
    (hBase : Option (Hash × Seq)) (inSeq : Seq) : Decision :=
  if tomb then
    { action := .tombstone, base := none, shelfRemote := false,
      shelfLocal := hLoc.isSome && decide (hLoc ≠ hBase.map Prod.fst) }
  else if hBase.map Prod.fst = some hIn then
    { action := .echo, base := some (hIn, inSeq), shelfRemote := false,
      shelfLocal := false }
  else if hLoc = some hIn then
    { action := .same, base := some (hIn, inSeq), shelfRemote := false,
      shelfLocal := false }
  else if hLoc = none ∧ hBase.isSome = true then
    { action := .conflict, base := some (hIn, inSeq),
      shelfRemote := true, shelfLocal := false }
  else if hLoc = hBase.map Prod.fst ∨ hLoc = none then
    { action := .adopt, base := some (hIn, inSeq), shelfRemote := false,
      shelfLocal := false }
  else
    { action := .conflict, base := some (hIn, inSeq),
      shelfRemote := true, shelfLocal := false }

/-- The §6 table EXACTLY, in the stated order:

* `tomb` — the incoming row is a tombstone;
* `hIn` — `rowHash` of the incoming row;
* `hLoc` — `rowHash` of the local row, `none` when absent;
* `hBase` — the baseline `(hash, seq)` for the id, `none` when absent;
* `inSeq` — the incoming row's seq.

Row 1 (`seq ≤ h_base.seq → 跳过`, the round-eight form; 34a7810 has
`==`, kept as `decideRowEq`): the baseline already records this server
version or a later one. It precedes the tombstone check, as in the text,
and is the ONLY place a seq enters the decision. What `≤` buys over
`==` is the strictly-older row of a stale page:
`stale_feed_row_regresses_witness`. -/
def decideRow (tomb : Bool) (hIn : Hash) (hLoc : Option Hash)
    (hBase : Option (Hash × Seq)) (inSeq : Seq) : Decision :=
  if staleOrSeen hBase inSeq then
    { action := .skip, base := hBase, shelfRemote := false, shelfLocal := false }
  else decideRowBody tomb hIn hLoc hBase inSeq

/-- A replica: local rows, the `(hash, seq)` baseline, the append-only
conflict shelf, and the one cursor. -/
structure Replica (C : Type) where
  loc : Id → Option C
  base : Id → Option (Hash × Seq)
  shelf : List (Id × C)
  cursor : Seq

/-- One row of a `sync_changes` page. Content is present on tombstones too
(the server keeps it); the applier ignores it there. -/
structure FeedRow (C : Type) where
  id : Id
  seq : Seq
  content : C
  deleted : Bool

variable {C : Type}

/-- The type of a decision core — `decideRow` or a variant. -/
abbrev Core := Bool → Hash → Option Hash → Option (Hash × Seq) → Seq → Decision

/-- Effect of a decision on the replica, generic in the core so the
variant witnesses reuse the exact same effect code. The local version is
shelved before the remote one; a single decision never shelves both. -/
def applyRowWith (core : Core) (hash : C → Hash) (r : Replica C)
    (fr : FeedRow C) : Replica C :=
  let d := core fr.deleted (hash fr.content) ((r.loc fr.id).map hash)
    (r.base fr.id) fr.seq
  { loc := fun i =>
      if i = fr.id then
        match d.action with
        | .tombstone => none
        | .adopt => some fr.content
        | _ => r.loc i
      else r.loc i
    base := fun i => if i = fr.id then d.base else r.base i
    shelf := r.shelf
      ++ (if d.shelfLocal then
            ((r.loc fr.id).map fun c => [(fr.id, c)]).getD [] else [])
      ++ (if d.shelfRemote then [(fr.id, fr.content)] else [])
    cursor := r.cursor }

/-- `EventStore.applyRemote` for one row of an id table: the §6 table
applied. -/
def applyRow (hash : C → Hash) : Replica C → FeedRow C → Replica C :=
  applyRowWith decideRow hash

/-- One pull: apply every page row past the cursor, in the page's (seq)
order, then advance the cursor to the largest seq applied. I3's write
order (slot → baseline → cursor) is what makes this fold the unit of
recovery after a crash. The `cursor <` filter is client-side here (see
the header). -/
def pull (hash : C → Hash) (r : Replica C) (page : List (FeedRow C)) :
    Replica C :=
  let rows := page.filter fun fr => decide (r.cursor < fr.seq)
  let r' := rows.foldl (applyRow hash) r
  { r' with cursor := rows.foldl (fun m fr => max m fr.seq) r.cursor }

def Replica.setBase (r : Replica C) (id : Id) (b : Option (Hash × Seq)) :
    Replica C :=
  { r with base := fun i => if i = id then b else r.base i }

/-- A local edit: the user writes `c` at `id`. -/
def Replica.edit (r : Replica C) (id : Id) (c : C) : Replica C :=
  { r with loc := fun i => if i = id then some c else r.loc i }

/-- §6 upload shape, third response — `[row]` with `deleted_at` set — on
an id table: "处置与 tombstone 来件相同". The local version is dirty (a
clean row sends nothing) and is shelved; the local row is removed (the
cascade); the baseline entry is removed; `(hash, seq)` is NOT written. -/
def Replica.deadRowHit (r : Replica C) (id : Id) (c : C) : Replica C :=
  { loc := fun i => if i = id then none else r.loc i
    base := fun i => if i = id then none else r.base i
    shelf := r.shelf ++ [(id, c)]
    cursor := r.cursor }

/-- One element of the pending-verify set: the id whose PATCH answered
`[]`, the baseline seq the PATCH filter carried, and the hash of the row
as SENT (computed when the PATCH was built, never recomputed from the
live row — the review-six BLOCKER). `(table, _)` is folded into `Id`;
`pullIssue` is not representable (no in-flight pulls). -/
structure Pending where
  id : Id
  sentSeq : Seq
  sentHash : Hash
deriving DecidableEq, Repr

structure PushResult (C : Type) where
  server : Server C
  replica : Replica C
  /-- A pull is wanted. Set by a PATCH `[]` (stale or content-identical —
  the id enters the pending-verify set) AND by an ignore-duplicates POST
  miss ("等回声拉取补基线后走 PATCH" — the id waits for its echo, and is
  logged `sync.push.orphan` if the head pull never shows it). Only the
  first of the two creates a `pending` entry. -/
  needsPull : Bool
  /-- The pending-verify entry a PATCH `[]` creates; `none` otherwise. -/
  pending : Option Pending

/-- The upload shape for one dirty local row of an id table: conditional
PATCH when the baseline has a seq, ignore-duplicates POST when it has
none. On `[row]` with `deleted_at` null the baseline becomes
`(hash of the row we SENT, row.seq)` — the hash is never taken from the
response body (design review-four H1). On `[row]` with `deleted_at` set
— the check is "在 `[row]` 分支的第一行,不是可选项" — the row is treated
as an incoming tombstone (`Replica.deadRowHit`). On a PATCH `[]` the
replica is unchanged and the pending entry carries the sent seq and the
sent hash. A clean row sends nothing. -/
def pushRow [DecidableEq C] (hash : C → Hash) (s : Server C) (r : Replica C)
    (id : Id) : PushResult C :=
  match r.loc id with
  | none => ⟨s, r, false, none⟩
  | some c =>
    if (r.base id).map Prod.fst = some (hash c) then ⟨s, r, false, none⟩
    else
      match r.base id with
      | some (_, bseq) =>
        match s.patch id bseq c with
        | (s', some row) =>
          if row.deleted then ⟨s', r.deadRowHit id c, false, none⟩
          else ⟨s', r.setBase id (some (hash c, row.seq)), false, none⟩
        | (s', none) => ⟨s', r, true, some ⟨id, bseq, hash c⟩⟩
      | none =>
        match s.insertIgnore id c with
        | (s', some seq') => ⟨s', r.setBase id (some (hash c, seq')), false, none⟩
        | (s', none) => ⟨s', r, true, none⟩

/-- The upload shape for a pending local delete (local absent, baseline
present): the tombstone PATCH — `?id=eq.X&deleted_at=is.null`, no seq
filter — then the baseline entry is dropped. The server row is dead
afterwards whether this call flipped it or a peer's already had
(`pushDelete_lands`), and whether or not the baseline seq was current
(`pushDelete_unconditional`). -/
def pushDelete [DecidableEq C] (s : Server C) (r : Replica C) (id : Id) :
    PushResult C :=
  match r.loc id, r.base id with
  | none, some _ => ⟨(s.tombstone id).1, r.setBase id none, false, none⟩
  | _, _ => ⟨s, r, false, none⟩

/-- Reading `C = Nat`, `hash = id`: a replica holding one row at id 1, used
by every witness below. -/
def oneRow (lc : Option Nat) (b : Option (Hash × Seq)) : Replica Nat :=
  { loc := fun i => if i = 1 then lc else none
    base := fun i => if i = 1 then b else none
    shelf := []
    cursor := 0 }

/-- The same, with a cursor. -/
def oneRowAt (lc : Option Nat) (b : Option (Hash × Seq)) (cursor : Seq) :
    Replica Nat :=
  { oneRow lc b with cursor }

/-- A server holding one row at id 1. -/
def oneServer (row : Option (Row Nat)) (counter : Seq) : Server Nat :=
  { rows := fun i => if i = 1 then row else none, counter }

/-! ## T1 / T6 — the server laws -/

section ServerLaws
variable [DecidableEq C]

/-- The conditional PATCH keeps a tombstone (I6: `old.deleted_at` wins). -/
theorem patch_keeps_deleted (s : Server C) (id id' : Id) (base : Seq) (c : C)
    (h : s.Deleted id) : (s.patch id' base c).1.Deleted id := by
  obtain ⟨row, hrow, hdel⟩ := h
  unfold Server.patch
  split
  · exact ⟨row, hrow, hdel⟩
  · rename_i row' hrow'
    split
    · exact ⟨row, hrow, hdel⟩
    · split
      · exact ⟨row, hrow, hdel⟩
      · by_cases hid : id = id'
        · subst hid
          have hrr : row = row' := by
            rw [hrow] at hrow'
            exact Option.some.inj hrow'
          subst hrr
          exact ⟨{ content := c, seq := s.next, deleted := row.deleted },
            by simp [Server.setRow], hdel⟩
        · exact ⟨row, by simp [Server.setRow, hid, hrow], hdel⟩

omit [DecidableEq C] in
/-- An ignore-duplicates POST never touches an existing row. -/
theorem insertIgnore_keeps_deleted (s : Server C) (id id' : Id) (c : C)
    (h : s.Deleted id) : (s.insertIgnore id' c).1.Deleted id := by
  obtain ⟨row, hrow, hdel⟩ := h
  unfold Server.insertIgnore
  split
  · exact ⟨row, hrow, hdel⟩
  · rename_i hnone
    by_cases hid : id = id'
    · subst hid
      rw [hrow] at hnone
      cases hnone
    · exact ⟨row, by simp [Server.setRow, hid, hrow], hdel⟩

omit [DecidableEq C] in
/-- A delete of a dead row is a no-op; of a live row, a flip to dead. -/
theorem tombstone_keeps_deleted (s : Server C) (id id' : Id)
    (h : s.Deleted id) : (s.tombstone id').1.Deleted id := by
  obtain ⟨row, hrow, hdel⟩ := h
  unfold Server.tombstone
  split
  · exact ⟨row, hrow, hdel⟩
  · rename_i row' hrow'
    split
    · exact ⟨row, hrow, hdel⟩
    · by_cases hid : id = id'
      · subst hid
        exact ⟨{ content := row'.content, seq := s.next, deleted := true },
          by simp [Server.setRow], rfl⟩
      · exact ⟨row, by simp [Server.setRow, hid, hrow], hdel⟩

/-- A pre-015 blind upsert hits the same BEFORE trigger: I6 holds for it. -/
theorem legacyUpsert_keeps_deleted (s : Server C) (id id' : Id) (c : C)
    (h : s.Deleted id) : (s.legacyUpsert id' c).Deleted id := by
  obtain ⟨row, hrow, hdel⟩ := h
  unfold Server.legacyUpsert
  split
  · rename_i hnone
    by_cases hid : id = id'
    · subst hid
      rw [hrow] at hnone
      cases hnone
    · exact ⟨row, by simp [Server.setRow, hid, hrow], hdel⟩
  · rename_i row' hrow'
    split
    · exact ⟨row, hrow, hdel⟩
    · by_cases hid : id = id'
      · subst hid
        have hrr : row = row' := by
          rw [hrow] at hrow'
          exact Option.some.inj hrow'
        subst hrr
        exact ⟨{ content := c, seq := s.next + 1, deleted := row.deleted },
          by simp [Server.setRow], hdel⟩
      · exact ⟨row, by simp [Server.setRow, hid, hrow], hdel⟩

/-- THEOREM T1 (tombstone monotone): once a row is a tombstone on the
server, no client write of any shape — conditional PATCH, ignore-
duplicates POST, a delete, or a pre-015 blind upsert — brings it back.
This is I6 as the trigger enforces it, plus I4's "nothing destroys a
tombstone" for the delete path. The undelete RPC is not a `ClientOp`,
so this is scoped to ordinary writes by construction. -/
theorem tombstone_monotone (s : Server C) (op : Server.ClientOp C) (id : Id)
    (h : s.Deleted id) : (s.step op).Deleted id := by
  cases op with
  | patch id' base c => exact patch_keeps_deleted s id id' base c h
  | insertIgnore id' c => exact insertIgnore_keeps_deleted s id id' c h
  | tombstone id' => exact tombstone_keeps_deleted s id id' h
  | legacyUpsert id' c => exact legacyUpsert_keeps_deleted s id id' c h

/-- THEOREM T6 (stale write guard, I8): a conditional PATCH whose base is
not the server's current seq matches no row — the server is untouched
(no seq burned, no doorbell) and the body is `[]`. The check lives in the
request filter, so unlike a trigger it sees the client's real base. -/
theorem stale_write_guard (s : Server C) (id : Id) (base : Seq) (c : C)
    (h : ∀ row, s.rows id = some row → row.seq ≠ base) :
    s.patch id base c = (s, none) := by
  unfold Server.patch
  split
  · rfl
  · rename_i row hrow
    simp [h row hrow]

/-- Companion to T6: a content-identical PATCH is also `[]` and also
leaves the server untouched — the short-circuit the client cannot tell
apart from staleness. `[]` therefore means "pending-verify, then pull"
(`pullVerify`), not merely "pull first": see
`identical_patch_pull_livelock_witness`. -/
theorem identical_write_short_circuits (s : Server C) (id : Id) (row : Row C)
    (hrow : s.rows id = some row) :
    s.patch id row.seq row.content = (s, none) := by
  unfold Server.patch
  simp [hrow]

/-- The outcomes of a conditional PATCH, as the client sees them: `[row]`
carrying the written content, the fresh seq and the KEPT `deleted_at`
of the row it matched, or `[]`. -/
theorem patch_outcomes (s : Server C) (id : Id) (base : Seq) (c : C) :
    (∃ row, s.rows id = some row ∧ row.seq = base ∧
      s.patch id base c =
        (s.setRow id { content := c, seq := s.next, deleted := row.deleted } s.next,
          some { content := c, seq := s.next, deleted := row.deleted }))
    ∨ s.patch id base c = (s, none) := by
  unfold Server.patch
  split
  · exact Or.inr rfl
  · rename_i row hrow
    split
    · exact Or.inr rfl
    · rename_i hseq
      split
      · exact Or.inr rfl
      · exact Or.inl ⟨row, hrow, Decidable.not_not.mp hseq, rfl⟩

/-- What `[]` from a PATCH tells the client: no row, a seq mismatch, or
identical content — and nothing else. -/
theorem patch_empty_reasons (s : Server C) (id : Id) (base : Seq) (c : C)
    (h : (s.patch id base c).2 = none) :
    s.rows id = none
      ∨ ∃ row, s.rows id = some row ∧ (row.seq ≠ base ∨ row.content = c) := by
  unfold Server.patch at h
  split at h
  · exact Or.inl (by assumption)
  · rename_i row hrow
    split at h
    · exact Or.inr ⟨row, hrow, Or.inl (by assumption)⟩
    · split at h
      · exact Or.inr ⟨row, hrow, Or.inr (by assumption)⟩
      · simp at h

omit [DecidableEq C] in
/-- The outcomes of an ignore-duplicates POST. -/
theorem insertIgnore_outcomes (s : Server C) (id : Id) (c : C) :
    (s.rows id = none ∧
      s.insertIgnore id c =
        (s.setRow id { content := c, seq := s.next, deleted := false } s.next,
          some s.next))
    ∨ (s.insertIgnore id c).2 = none := by
  unfold Server.insertIgnore
  split
  · exact Or.inr rfl
  · rename_i hnone
    exact Or.inl ⟨hnone, rfl⟩

/-- A pushed delete lands: the server row (if any) is dead afterwards and
the baseline entry is gone. The server is dead whether this call flipped
the row or a peer's delete already had. -/
theorem pushDelete_lands (s : Server C) (r : Replica C) (id : Id)
    (hloc : r.loc id = none) (b : Hash × Seq) (hbase : r.base id = some b)
    (row : Row C) (hrow : s.rows id = some row) :
    (pushDelete s r id).server.Deleted id
      ∧ (pushDelete s r id).replica.base id = none := by
  unfold pushDelete
  simp only [hloc, hbase]
  refine ⟨?_, by simp [Replica.setBase]⟩
  unfold Server.tombstone
  simp only [hrow]
  split
  · rename_i hdel
    exact ⟨row, hrow, hdel⟩
  · exact ⟨{ row with seq := s.next, deleted := true }, by simp [Server.setRow], rfl⟩

/-- The delete filter carries no seq (design §6 "客户端自己的删除":
`?id=eq.X&deleted_at=is.null`): a pending delete whose baseline seq is
STALE still flips the live server row — the I8 guard the PATCH path has
does not apply to deletes. `delete_overrides_concurrent_peer_edit_witness`
is the consequence. -/
theorem pushDelete_unconditional (s : Server C) (r : Replica C) (id : Id)
    (hloc : r.loc id = none) (h : Hash) (S : Seq) (hbase : r.base id = some (h, S))
    (row : Row C) (hrow : s.rows id = some row) (hlive : row.deleted = false) :
    (pushDelete s r id).server.rows id = some { row with seq := s.next, deleted := true } := by
  unfold pushDelete
  simp only [hloc, hbase]
  unfold Server.tombstone
  simp [hrow, hlive, Server.setRow]

end ServerLaws

/-! ## The decision core, row by row -/

theorem staleOrSeen_some (h : Hash) (S n : Seq) :
    staleOrSeen (some (h, S)) n = decide (n ≤ S) := rfl

theorem staleOrSeen_none (n : Seq) : staleOrSeen none n = false := rfl

theorem staleOrSeen_true_iff (b : Option (Hash × Seq)) (n : Seq) :
    staleOrSeen b n = true ↔ ∃ h S, b = some (h, S) ∧ n ≤ S := by
  cases b with
  | none => simp [staleOrSeen]
  | some p =>
    obtain ⟨h, S⟩ := p
    simp only [staleOrSeen, decide_eq_true_iff, Option.some.injEq, Prod.mk.injEq]
    constructor
    · intro hle
      exact ⟨h, S, ⟨rfl, rfl⟩, hle⟩
    · rintro ⟨_, _, ⟨rfl, rfl⟩, hle⟩
      exact hle

theorem staleOrSeen_false_iff (b : Option (Hash × Seq)) (n : Seq) :
    staleOrSeen b n = false ↔ ∀ h S, b = some (h, S) → S < n := by
  cases b with
  | none => simp [staleOrSeen]
  | some p =>
    obtain ⟨h, S⟩ := p
    simp [staleOrSeen]

/-- Row 1: the baseline already names this seq or a later one. -/
theorem decideRow_skip (tomb : Bool) (hIn : Hash) (hLoc : Option Hash)
    (hBase : Option (Hash × Seq)) (inSeq : Seq)
    (hs : staleOrSeen hBase inSeq = true) :
    decideRow tomb hIn hLoc hBase inSeq =
      { action := .skip, base := hBase, shelfRemote := false, shelfLocal := false } := by
  simp [decideRow, hs]

theorem decideRow_tomb (hIn : Hash) (hLoc : Option Hash)
    (hBase : Option (Hash × Seq)) (inSeq : Seq)
    (hns : staleOrSeen hBase inSeq = false) :
    decideRow true hIn hLoc hBase inSeq =
      { action := .tombstone, base := none, shelfRemote := false,
        shelfLocal := hLoc.isSome && decide (hLoc ≠ hBase.map Prod.fst) } := by
  simp [decideRow, decideRowBody, hns]

theorem decideRow_echo (hIn : Hash) (hLoc : Option Hash)
    (hBase : Option (Hash × Seq)) (inSeq : Seq)
    (hns : staleOrSeen hBase inSeq = false)
    (h : hBase.map Prod.fst = some hIn) :
    decideRow false hIn hLoc hBase inSeq =
      { action := .echo, base := some (hIn, inSeq), shelfRemote := false,
        shelfLocal := false } := by
  simp [decideRow, decideRowBody, hns, h]

theorem decideRow_same (hIn : Hash) (hLoc : Option Hash)
    (hBase : Option (Hash × Seq)) (inSeq : Seq)
    (hns : staleOrSeen hBase inSeq = false)
    (h1 : hBase.map Prod.fst ≠ some hIn) (h2 : hLoc = some hIn) :
    decideRow false hIn hLoc hBase inSeq =
      { action := .same, base := some (hIn, inSeq), shelfRemote := false,
        shelfLocal := false } := by
  simp [decideRow, decideRowBody, hns, h1, h2]

/-- The pending-delete row: local absent, baseline present, a live
non-echo row — decided as the dirty row with the local side absent, and
like it writing the incoming row's `(h_in, seq)`. -/
theorem decideRow_pending_delete (hIn : Hash) (hLoc : Option Hash)
    (hBase : Option (Hash × Seq)) (inSeq : Seq) (bh : Hash) (S : Seq)
    (hns : staleOrSeen hBase inSeq = false)
    (h1 : hBase.map Prod.fst ≠ some hIn) (hloc : hLoc = none)
    (hb : hBase = some (bh, S)) :
    decideRow false hIn hLoc hBase inSeq =
      { action := .conflict, base := some (hIn, inSeq), shelfRemote := true,
        shelfLocal := false } := by
  subst hb hloc
  have h1' : bh ≠ hIn := fun h => h1 (by simp [h])
  simp [decideRow, decideRowBody, hns, h1']

/-- The adopt row fires exactly on a clean id (`h_loc = h_base.hash`, an
absent side being a value): with the pending-delete row in front of it,
"本地 absent" is reachable here only with no baseline, which is clean. -/
theorem decideRow_adopt (hIn : Hash) (hLoc : Option Hash)
    (hBase : Option (Hash × Seq)) (inSeq : Seq)
    (hns : staleOrSeen hBase inSeq = false)
    (h1 : hBase.map Prod.fst ≠ some hIn) (h3 : hLoc = hBase.map Prod.fst) :
    decideRow false hIn hLoc hBase inSeq =
      { action := .adopt, base := some (hIn, inSeq), shelfRemote := false,
        shelfLocal := false } := by
  simp [decideRow, decideRowBody, hns, h1, h3]

theorem decideRow_conflict (hIn : Hash) (hLoc : Option Hash)
    (hBase : Option (Hash × Seq)) (inSeq : Seq)
    (hns : staleOrSeen hBase inSeq = false)
    (h1 : hBase.map Prod.fst ≠ some hIn) (h2 : hLoc ≠ some hIn)
    (h3 : hLoc ≠ hBase.map Prod.fst) (h4 : hLoc ≠ none) :
    decideRow false hIn hLoc hBase inSeq =
      { action := .conflict, base := some (hIn, inSeq),
        shelfRemote := true, shelfLocal := false } := by
  simp [decideRow, decideRowBody, hns, h1, h2, h3, h4]

/-- Every row of the table leaves the baseline entry either removed or
carrying a seq at or above the incoming one — the skip row because the
entry it keeps already does. -/
theorem decideRow_base_seq (tomb : Bool) (hIn : Hash) (hLoc : Option Hash)
    (hBase : Option (Hash × Seq)) (inSeq : Seq) :
    (decideRow tomb hIn hLoc hBase inSeq).base = none ∨
      ∃ x S, (decideRow tomb hIn hLoc hBase inSeq).base = some (x, S) ∧ inSeq ≤ S := by
  unfold decideRow
  split
  · rename_i hs
    right
    obtain ⟨h, S, hb, hle⟩ := (staleOrSeen_true_iff _ _).mp hs
    exact ⟨h, S, by simp [hb], hle⟩
  · unfold decideRowBody
    split
    · exact Or.inl rfl
    · split
      · exact Or.inr ⟨_, _, rfl, Nat.le_refl _⟩
      · split
        · exact Or.inr ⟨_, _, rfl, Nat.le_refl _⟩
        · split
          · exact Or.inr ⟨_, _, rfl, Nat.le_refl _⟩
          · split
            · exact Or.inr ⟨_, _, rfl, Nat.le_refl _⟩
            · exact Or.inr ⟨_, _, rfl, Nat.le_refl _⟩

/-- A row that is not skipped leaves the entry removed or carrying the
incoming seq — "每个分支都写 base.seq". -/
theorem decideRow_base_seq_noskip (tomb : Bool) (hIn : Hash) (hLoc : Option Hash)
    (hBase : Option (Hash × Seq)) (inSeq : Seq)
    (hns : staleOrSeen hBase inSeq = false) :
    (decideRow tomb hIn hLoc hBase inSeq).base = none ∨
      ∃ x, (decideRow tomb hIn hLoc hBase inSeq).base = some (x, inSeq) := by
  unfold decideRow
  rw [hns]
  simp only [Bool.false_eq_true, ↓reduceIte]
  unfold decideRowBody
  split
  · exact Or.inl rfl
  · split
    · exact Or.inr ⟨_, rfl⟩
    · split
      · exact Or.inr ⟨_, rfl⟩
      · split
        · exact Or.inr ⟨_, rfl⟩
        · split
          · exact Or.inr ⟨_, rfl⟩
          · exact Or.inr ⟨_, rfl⟩

/-- A live row that is not skipped always leaves a baseline entry
carrying the incoming seq. -/
theorem decideRow_live_base (hIn : Hash) (hLoc : Option Hash)
    (hBase : Option (Hash × Seq)) (inSeq : Seq)
    (hns : staleOrSeen hBase inSeq = false) :
    ∃ x, (decideRow false hIn hLoc hBase inSeq).base = some (x, inSeq) := by
  unfold decideRow
  rw [hns]
  simp only [Bool.false_eq_true, ↓reduceIte]
  unfold decideRowBody
  simp only [Bool.false_eq_true, ↓reduceIte]
  split
  · exact ⟨_, rfl⟩
  · split
    · exact ⟨_, rfl⟩
    · split
      · exact ⟨_, rfl⟩
      · split
        · exact ⟨_, rfl⟩
        · exact ⟨_, rfl⟩

/-- The entry is removed exactly on a tombstone that is not skipped. -/
theorem decideRow_base_none_iff (tomb : Bool) (hIn : Hash) (hLoc : Option Hash)
    (hBase : Option (Hash × Seq)) (inSeq : Seq) :
    (decideRow tomb hIn hLoc hBase inSeq).base = none
      ↔ tomb = true ∧ staleOrSeen hBase inSeq = false := by
  constructor
  · intro hn
    unfold decideRow at hn
    split at hn
    · rename_i hs
      obtain ⟨h, S, hb, -⟩ := (staleOrSeen_true_iff _ _).mp hs
      simp [hb] at hn
    · rename_i hs
      unfold decideRowBody at hn
      split at hn
      · rename_i ht
        exact ⟨ht, by simpa using hs⟩
      · split at hn
        · simp at hn
        · split at hn
          · simp at hn
          · split at hn
            · simp at hn
            · split at hn
              · simp at hn
              · simp at hn
  · rintro ⟨ht, hs⟩
    simp [decideRow, decideRowBody, hs, ht]

/-- THEOREM (the baseline column): a row that is not skipped removes the
entry on a tombstone and otherwise writes `(h_in, seq)` — echo, same, the
pending-delete row, adopt and conflict alike. Every entry the table
writes names the incoming row, i.e. the version the server held at that
seq; that is what makes `BaseHashSound` and `BaseHeld` invariants with
no conflict-row exception (`reachable_sound`). -/
theorem decideRow_base_noskip (tomb : Bool) (hIn : Hash) (hLoc : Option Hash)
    (hBase : Option (Hash × Seq)) (inSeq : Seq)
    (hns : staleOrSeen hBase inSeq = false) :
    (decideRow tomb hIn hLoc hBase inSeq).base
      = if tomb then none else some (hIn, inSeq) := by
  unfold decideRow
  rw [hns]
  simp only [Bool.false_eq_true, ↓reduceIte]
  unfold decideRowBody
  cases tomb
  · simp only [Bool.false_eq_true, ↓reduceIte]
    split
    · rfl
    · split
      · rfl
      · split
        · rfl
        · split
          · rfl
          · rfl
  · rfl

/-- The conflict row (either of its two forms) leaves the id dirty: it is
reached only when the local hash is not the incoming one, and it writes
the incoming hash. What "hash 不动保持脏" protected — the local version
must still be uploaded — holds under `(h_in, seq)` as well. -/
theorem decideRow_conflict_still_dirty (hIn : Hash) (hLoc : Option Hash)
    (hBase : Option (Hash × Seq)) (inSeq : Seq)
    (hc : (decideRow false hIn hLoc hBase inSeq).action = .conflict) :
    hLoc ≠ (decideRow false hIn hLoc hBase inSeq).base.map Prod.fst := by
  cases hs : staleOrSeen hBase inSeq
  · rw [decideRow_base_noskip false hIn hLoc hBase inSeq hs]
    simp only [Bool.false_eq_true, ↓reduceIte, Option.map_some]
    intro hl
    by_cases h1 : hBase.map Prod.fst = some hIn
    · rw [decideRow_echo hIn hLoc hBase inSeq hs h1] at hc; cases hc
    · rw [decideRow_same hIn hLoc hBase inSeq hs h1 hl] at hc; cases hc
  · rw [decideRow_skip false hIn hLoc hBase inSeq hs] at hc; cases hc


/-! ## Frame and effect lemmas on `applyRow` -/

section ApplyLemmas
variable (hash : C → Hash)

/-- Applying a row touches nothing at any other id. -/
theorem applyRow_frame (r : Replica C) (fr : FeedRow C) (i : Id)
    (h : i ≠ fr.id) :
    (applyRow hash r fr).loc i = r.loc i
      ∧ (applyRow hash r fr).base i = r.base i := by
  simp [applyRow, applyRowWith, h]

theorem applyRow_cursor (r : Replica C) (fr : FeedRow C) :
    (applyRow hash r fr).cursor = r.cursor := rfl

/-- Local content after a decision is a function of the action alone. -/
theorem applyRow_loc_self (r : Replica C) (fr : FeedRow C) :
    (applyRow hash r fr).loc fr.id =
      match (decideRow fr.deleted (hash fr.content) ((r.loc fr.id).map hash)
          (r.base fr.id) fr.seq).action with
      | .tombstone => none
      | .adopt => some fr.content
      | _ => r.loc fr.id := by
  simp [applyRow, applyRowWith]

theorem applyRow_base_self (r : Replica C) (fr : FeedRow C) :
    (applyRow hash r fr).base fr.id =
      (decideRow fr.deleted (hash fr.content) ((r.loc fr.id).map hash)
          (r.base fr.id) fr.seq).base := by
  simp [applyRow, applyRowWith]

/-- The baseline column as an effect: a row that is not skipped leaves the
entry removed (tombstone) or on the incoming row's `(hash, seq)`. -/
theorem applyRow_base_noskip (r : Replica C) (fr : FeedRow C)
    (hns : staleOrSeen (r.base fr.id) fr.seq = false) :
    (applyRow hash r fr).base fr.id
      = if fr.deleted then none else some (hash fr.content, fr.seq) := by
  rw [applyRow_base_self]
  exact decideRow_base_noskip _ _ _ _ _ hns

/-- Row 1 as an effect: a row whose seq the baseline already names, or
is below, is the identity on the replica — nothing adopted, nothing
shelved, baseline untouched. -/
theorem applyRow_skip (r : Replica C) (fr : FeedRow C)
    (hs : staleOrSeen (r.base fr.id) fr.seq = true) :
    applyRow hash r fr = r := by
  have hd := decideRow_skip fr.deleted (hash fr.content) ((r.loc fr.id).map hash)
    (r.base fr.id) fr.seq hs
  simp only [applyRow, applyRowWith, hd]
  cases r with
  | mk loc base shelf cursor =>
    simp only [Replica.mk.injEq]
    refine ⟨?_, ?_, by simp, trivial⟩
    · funext i
      by_cases hi : i = fr.id
      · subst hi; simp
      · simp [hi]
    · funext i
      by_cases hi : i = fr.id
      · subst hi; simp
      · simp [hi]

/-- THEOREM (seq monotone): a baseline seq never moves backwards under
the table — the strictly-older row of a stale page is the skip row's
job. The `==` row does not give this: `stale_feed_row_regresses_witness`. -/
theorem applyRow_seq_monotone (r : Replica C) (fr : FeedRow C) (i : Id)
    (h S h' S' : Nat) (hb : r.base i = some (h, S))
    (hb' : (applyRow hash r fr).base i = some (h', S')) : S ≤ S' := by
  by_cases hi : i = fr.id
  · subst hi
    cases hs : staleOrSeen (r.base fr.id) fr.seq
    · rw [applyRow_base_self] at hb'
      rcases decideRow_base_seq_noskip fr.deleted (hash fr.content) ((r.loc fr.id).map hash)
          (r.base fr.id) fr.seq hs with hn | ⟨x, hx⟩
      · rw [hn] at hb'; cases hb'
      · rw [hx] at hb'; cases hb'
        exact Nat.le_of_lt ((staleOrSeen_false_iff _ _).mp hs h S hb)
    · rw [applyRow_skip hash r fr hs] at hb'
      rw [hb] at hb'; cases hb'; exact Nat.le_refl _
  · rw [(applyRow_frame hash r fr i hi).2] at hb'
    rw [hb] at hb'; cases hb'; exact Nat.le_refl _

/-- A tombstone applied where nothing is held and no baseline exists is
the identity. -/
theorem applyRow_tomb_absent (r : Replica C) (fr : FeedRow C) (hd : fr.deleted = true)
    (hl : r.loc fr.id = none) (hb : r.base fr.id = none) :
    applyRow hash r fr = r := by
  obtain ⟨loc, base, shelf, cursor⟩ := r
  simp only at hl hb
  simp only [applyRow, applyRowWith, decideRow, decideRowBody, staleOrSeen, hd, hl, hb]
  simp only [Replica.mk.injEq]
  refine ⟨?_, ?_, by simp, trivial⟩
  · funext i
    split
    · rename_i hi; subst hi; exact hl.symm
    · rfl
  · funext i
    split
    · rename_i hi; subst hi; exact hb.symm
    · rfl

/-- THEOREM T3 (echo is inert): an incoming LIVE row whose hash is the
baseline hash — our own push coming back, or a peer's write that landed
back on our bytes — changes no local content and shelves nothing,
whatever the local row currently is (dirty or clean). Only the
baseline's seq moves, and only forwards: our own push's echo carries the
baseline's seq and is absorbed by the skip row; a same-hash row at a
NEWER seq falls to the echo row and the baseline takes that seq. This
is the §6 "顺序敏感" guarantee: because both precede dirty detection, a
local edit made after the push and before its echo is neither
overwritten nor shelved. -/
theorem echo_inert (r : Replica C) (fr : FeedRow C) (S : Seq) (hlive : fr.deleted = false)
    (hbase : r.base fr.id = some (hash fr.content, S)) :
    (applyRow hash r fr).loc = r.loc
      ∧ (applyRow hash r fr).shelf = r.shelf
      ∧ (applyRow hash r fr).base fr.id = some (hash fr.content, max S fr.seq) := by
  cases hs : staleOrSeen (r.base fr.id) fr.seq
  · have hlt : S < fr.seq := (staleOrSeen_false_iff _ _).mp hs _ _ hbase
    rw [Nat.max_eq_right (Nat.le_of_lt hlt)]
    simp [applyRow, applyRowWith, hlive,
      decideRow_echo (hash fr.content) ((r.loc fr.id).map hash) (r.base fr.id) fr.seq hs
        (by rw [hbase]; rfl)]
  · obtain ⟨h', S', hb', hle⟩ := (staleOrSeen_true_iff _ _).mp hs
    rw [hbase] at hb'
    cases hb'
    rw [applyRow_skip hash r fr hs, Nat.max_eq_left hle]
    exact ⟨rfl, rfl, hbase⟩

/-- THEOREM T4 (no silent loss): whenever applying a row CHANGES local
content that existed, either that content was clean (its hash is the
baseline hash) or it is now on the shelf. There is no third exit. What
"clean" is worth: on every reachable state the baseline is a live
version some server state of the run held at that seq, with that hash
(`BaseHeld`, `reachable_sound`) — for the baseline writers the model
has, a restore under its premises among them; the replay before
7a2e382e breaks it and loses an edit this way
(`pre_merge_previous_seq_control`), and so would an ineligible verify
pass, an unguarded late `[row]`, or a restore without the rewind
(`ineligible_verify_loses_witness`,
`late_row_response_regresses_witness`,
`restore_stale_snapshot_witness`). The absent-local half (a pending
delete) is `pending_delete_kept`. -/
theorem no_silent_loss (r : Replica C) (fr : FeedRow C) (old : C)
    (hold : r.loc fr.id = some old)
    (hchg : (applyRow hash r fr).loc fr.id ≠ some old) :
    (r.base fr.id).map Prod.fst = some (hash old)
      ∨ (fr.id, old) ∈ (applyRow hash r fr).shelf := by
  cases hs : staleOrSeen (r.base fr.id) fr.seq
  · cases hd : fr.deleted
    · rw [applyRow_loc_self, hd] at hchg
      by_cases h1 : (r.base fr.id).map Prod.fst = some (hash fr.content)
      · rw [decideRow_echo (hash fr.content) ((r.loc fr.id).map hash)
          (r.base fr.id) fr.seq hs h1] at hchg
        exact absurd hold hchg
      · by_cases h2 : (r.loc fr.id).map hash = some (hash fr.content)
        · rw [decideRow_same (hash fr.content) ((r.loc fr.id).map hash)
            (r.base fr.id) fr.seq hs h1 h2] at hchg
          exact absurd hold hchg
        · by_cases h3 : (r.loc fr.id).map hash = (r.base fr.id).map Prod.fst
          · left
            rw [hold] at h3
            exact h3.symm
          · have h4 : (r.loc fr.id).map hash ≠ none := by rw [hold]; simp
            rw [decideRow_conflict (hash fr.content) ((r.loc fr.id).map hash)
              (r.base fr.id) fr.seq hs h1 h2 h3 h4] at hchg
            exact absurd hold hchg
    · by_cases h3 : (r.loc fr.id).map hash = (r.base fr.id).map Prod.fst
      · left
        rw [hold] at h3
        exact h3.symm
      · right
        have hmap : (r.loc fr.id).map hash = some (hash old) := by rw [hold]; rfl
        rw [hmap] at h3
        have ht := decideRow_tomb (hash fr.content) (some (hash old)) (r.base fr.id) fr.seq hs
        simp only [applyRow, applyRowWith, hmap, hd, ht]
        simp [hold, h3]
  · rw [applyRow_skip hash r fr hs] at hchg
    exact absurd hold hchg

/-- THEOREM T4b (a pending delete is kept, and the edit it meets is
shelved): local absent with a baseline present is an unpushed local
delete. Whatever arrives, the local row stays absent; a live row that
is neither skipped nor an echo of what we last pushed is shelved and the
baseline becomes that row's `(h_in, seq)` — the pending-delete row. The
tombstone PATCH the next flush sends is `pushDelete`, whose filter has
no seq and which ignores the hash, so it still lands: delete beats edit.
If the row comes back locally before that (an undo re-adding the bytes
from before the delete), it is dirty against the peer's version and is
uploaded (`conflict_then_edit_is_pushed`). -/
theorem pending_delete_kept (r : Replica C) (fr : FeedRow C) (bh : Hash) (S : Seq)
    (hloc : r.loc fr.id = none) (hbase : r.base fr.id = some (bh, S)) :
    (applyRow hash r fr).loc fr.id = none
      ∧ (fr.deleted = false → S < fr.seq → bh ≠ hash fr.content →
          (fr.id, fr.content) ∈ (applyRow hash r fr).shelf
            ∧ (applyRow hash r fr).base fr.id = some (hash fr.content, fr.seq)) := by
  have hmap : (r.loc fr.id).map hash = none := by rw [hloc]; rfl
  constructor
  · cases hs : staleOrSeen (r.base fr.id) fr.seq
    · rw [applyRow_loc_self]
      cases hd : fr.deleted
      · by_cases h1 : (r.base fr.id).map Prod.fst = some (hash fr.content)
        · rw [decideRow_echo _ _ _ _ hs h1]; exact hloc
        · rw [decideRow_pending_delete _ _ _ _ bh S hs h1 hmap hbase]; exact hloc
      · rw [decideRow_tomb _ _ _ _ hs]
    · rw [applyRow_skip hash r fr hs]; exact hloc
  · intro hlive hlt hne
    have hs : staleOrSeen (r.base fr.id) fr.seq = false := by
      rw [hbase, staleOrSeen_some]; exact decide_eq_false (Nat.not_le.mpr hlt)
    have h1 : (r.base fr.id).map Prod.fst ≠ some (hash fr.content) := by
      rw [hbase]; simp [hne]
    have hd := decideRow_pending_delete (hash fr.content) ((r.loc fr.id).map hash)
      (r.base fr.id) fr.seq bh S hs h1 hmap hbase
    rw [hmap] at hd
    simp only [applyRow, applyRowWith, hmap, hlive, hd]
    simp

/-- THEOREM T4c (dirty local edit meets the server's tombstone — §7's
"A 离线改、B 删"): the local version is shelved, the local row removed,
the baseline entry removed; nothing is pushed for the id afterwards
(no local row, no baseline). -/
theorem dirty_local_vs_tombstone_shelved (r : Replica C) (fr : FeedRow C) (old : C)
    (hloc : r.loc fr.id = some old) (hd : fr.deleted = true)
    (hns : staleOrSeen (r.base fr.id) fr.seq = false)
    (hdirty : (r.base fr.id).map Prod.fst ≠ some (hash old)) :
    (applyRow hash r fr).loc fr.id = none
      ∧ (fr.id, old) ∈ (applyRow hash r fr).shelf
      ∧ (applyRow hash r fr).base fr.id = none := by
  have hmap : (r.loc fr.id).map hash = some (hash old) := by rw [hloc]; rfl
  have ht := decideRow_tomb (hash fr.content) (some (hash old)) (r.base fr.id) fr.seq hns
  have hne : some (hash old) ≠ (r.base fr.id).map Prod.fst := Ne.symm hdirty
  simp only [applyRow, applyRowWith, hmap, hd, ht]
  simp [hloc, hne]

/-- I3's partial-write crash: the slot was written (local already holds
the incoming bytes) but the baseline was not — so the baseline still
names an OLDER seq, not this row's. Re-applying the row — the re-pull
after restart — fires the echo or the same row, writes the baseline the
crash lost, and shelves nothing. (Had the baseline write survived too,
the row is skipped: `applyRow_skip`.) A local edit of that row BEFORE
the re-pull is a different state (local ≠ incoming ≠ old baseline) and
files one spurious conflict entry, which the skip row does not remove:
`slot_only_crash_then_edit_witness`. -/
theorem applyRow_after_slot_only_heals (r : Replica C) (fr : FeedRow C)
    (hlive : fr.deleted = false) (hslot : r.loc fr.id = some fr.content)
    (hns : staleOrSeen (r.base fr.id) fr.seq = false) :
    (applyRow hash r fr).loc fr.id = some fr.content
      ∧ (applyRow hash r fr).base fr.id = some (hash fr.content, fr.seq)
      ∧ (applyRow hash r fr).shelf = r.shelf := by
  by_cases h1 : (r.base fr.id).map Prod.fst = some (hash fr.content)
  · obtain ⟨S, hb⟩ : ∃ S, r.base fr.id = some (hash fr.content, S) := by
      cases hb : r.base fr.id with
      | none => rw [hb] at h1; simp at h1
      | some p =>
        obtain ⟨h, S⟩ := p
        rw [hb] at h1
        simp only [Option.map_some, Option.some.injEq] at h1
        subst h1
        exact ⟨S, rfl⟩
    have hlt : S < fr.seq := (staleOrSeen_false_iff _ _).mp hns _ _ hb
    have h := echo_inert hash r fr S hlive hb
    rw [Nat.max_eq_right (Nat.le_of_lt hlt)] at h
    exact ⟨by rw [h.1, hslot], h.2.2, h.2.1⟩
  · have hsame := decideRow_same (hash fr.content) ((r.loc fr.id).map hash)
      (r.base fr.id) fr.seq hns h1 (by rw [hslot]; rfl)
    simp only [applyRow, applyRowWith, hlive, hsame]
    simp [hslot]

end ApplyLemmas

/-! ## T2 — idempotence: the cursor's, and the skip row's -/

section Idempotence
variable (hash : C → Hash)

/-- THEOREM T2a (cursor discipline): a page pulled twice is applied once —
the second pull filters every row out because the cursor advanced past
it. This is §3 D1's "真相永远走游标拉取" and I3's cursor write as the
last step: once the cursor is on disk, the page is history. The proof
does not use the table (the statement is about `pull`, i.e. `applyRow`);
the I3 crash BEFORE the cursor write is the re-apply case, which is T2b. -/
theorem pull_idempotent (r : Replica C) (page : List (FeedRow C)) :
    pull hash (pull hash r page) page = pull hash r page := by
  have hcur : ∀ (rows : List (FeedRow C)) (init : Seq),
      init ≤ rows.foldl (fun m fr => max m fr.seq) init
        ∧ ∀ fr ∈ rows, fr.seq ≤ rows.foldl (fun m fr => max m fr.seq) init := by
    intro rows
    induction rows with
    | nil => intro init; exact ⟨Nat.le_refl _, by simp⟩
    | cons fr rest ih =>
      intro init
      obtain ⟨h1, h2⟩ := ih (max init fr.seq)
      refine ⟨Nat.le_trans (Nat.le_max_left _ _) h1, ?_⟩
      intro x hx
      simp only [List.mem_cons] at hx
      rcases hx with hx | hx
      · subst hx
        exact Nat.le_trans (Nat.le_max_right _ _) h1
      · exact h2 x hx
  have hnone : ∀ fr ∈ page,
      decide ((pull hash r page).cursor < fr.seq) = false := by
    intro fr hfr
    apply decide_eq_false
    simp only [pull]
    apply Nat.not_lt.mpr
    obtain ⟨hinit, hall⟩ :=
      hcur (page.filter fun fr => decide (r.cursor < fr.seq)) r.cursor
    by_cases hin : r.cursor < fr.seq
    · exact hall fr (List.mem_filter.mpr ⟨hfr, by simp [hin]⟩)
    · exact Nat.le_trans (Nat.le_of_not_lt hin) hinit
  have hfilter : page.filter (fun fr => decide ((pull hash r page).cursor < fr.seq))
      = [] := List.filter_eq_nil_iff.mpr (fun fr hfr => by simp [hnone fr hfr])
  suffices h : ∀ q : Replica C,
      page.filter (fun fr => decide (q.cursor < fr.seq)) = [] → pull hash q page = q by
    exact h _ hfilter
  intro q hq
  simp only [pull, hq, List.foldl]

/-- THEOREM T2b (re-applying a row is the identity, as a LIST): the first
application left the baseline entry carrying a seq at or above the
row's, so the second is the skip row — or removed it on a tombstone, and
a tombstone onto nothing is the identity. This is what the first row
buys: the I3 crash-recovery re-pull and the §6.1 refused-page re-pull
apply every row once, shelf included. The v1.3 table (6a7e50b, no skip
row) is idempotent on content and baseline but DOUBLES the shelf on a
conflict row: `conflict_reapply_doubles_shelf_v13_witness`. -/
theorem applyRow_idempotent (r : Replica C) (fr : FeedRow C) :
    applyRow hash (applyRow hash r fr) fr = applyRow hash r fr := by
  rcases decideRow_base_seq fr.deleted (hash fr.content) ((r.loc fr.id).map hash)
      (r.base fr.id) fr.seq with hn | ⟨x, S, hx, hle⟩
  · have hb' : (applyRow hash r fr).base fr.id = none := by
      rw [applyRow_base_self]; exact hn
    obtain ⟨hd, hns⟩ := (decideRow_base_none_iff _ _ _ _ _).mp hn
    have hl' : (applyRow hash r fr).loc fr.id = none := by
      rw [applyRow_loc_self, hd, decideRow_tomb _ _ _ _ hns]
    exact applyRow_tomb_absent hash _ fr hd hl' hb'
  · have hb' : staleOrSeen ((applyRow hash r fr).base fr.id) fr.seq = true := by
      rw [applyRow_base_self, hx, staleOrSeen_some]; exact decide_eq_true hle
    exact applyRow_skip hash _ fr hb'

/-- T2b on content and baseline, kept under its original name. -/
theorem applyRow_idempotent_loc_base (r : Replica C) (fr : FeedRow C) :
    (applyRow hash (applyRow hash r fr) fr).loc = (applyRow hash r fr).loc
      ∧ (applyRow hash (applyRow hash r fr) fr).base = (applyRow hash r fr).base := by
  rw [applyRow_idempotent]
  exact ⟨rfl, rfl⟩

/-- THEOREM T2c (shelf idempotent, as a set and as a list). -/
theorem applyRow_idempotent_shelf_mem (r : Replica C) (fr : FeedRow C)
    (e : Id × C) :
    e ∈ (applyRow hash (applyRow hash r fr) fr).shelf
      ↔ e ∈ (applyRow hash r fr).shelf := by
  rw [applyRow_idempotent]

/-- The table of design/realtime-sync @ 6a7e50b (v1.3): no skip row, no
pending-delete row, and the conflict row keeping the old hash. Kept only
to show what the later rows close. -/
def decideRowV13 : Core := fun tomb hIn hLoc hBase inSeq =>
  if tomb then
    { action := .tombstone, base := none, shelfRemote := false,
      shelfLocal := hLoc.isSome && decide (hLoc ≠ hBase.map Prod.fst) }
  else if hBase.map Prod.fst = some hIn then
    { action := .echo, base := some (hIn, inSeq), shelfRemote := false,
      shelfLocal := false }
  else if hLoc = some hIn then
    { action := .same, base := some (hIn, inSeq), shelfRemote := false,
      shelfLocal := false }
  else if hLoc = hBase.map Prod.fst ∨ hLoc = none then
    { action := .adopt, base := some (hIn, inSeq), shelfRemote := false,
      shelfLocal := false }
  else
    { action := .conflict, base := some ((hBase.map Prod.fst).getD hIn, inSeq),
      shelfRemote := true, shelfLocal := false }

/-- The skip row of design/realtime-sync @ 34a7810 (committed v1.4) — its
`==` form — on top of the current rows 2 to 7. The round-eight working
tree replaces `==` by `≤`; this variant varies row 1 alone, to witness
that difference (`stale_feed_row_regresses_witness`); 34a7810's conflict
writing is the separate variant `decideRowKeepHash`. -/
def decideRowEq : Core := fun tomb hIn hLoc hBase inSeq =>
  if hBase.map Prod.snd = some inSeq then
    { action := .skip, base := hBase, shelfRemote := false, shelfLocal := false }
  else decideRowBody tomb hIn hLoc hBase inSeq

/-- The `==` row and the `≤` row agree on every input whose seq is not
strictly below the baseline seq — they differ ONLY on the stale-page
row. -/
theorem decideRowEq_eq_decideRow (tomb : Bool) (hIn : Hash) (hLoc : Option Hash)
    (hBase : Option (Hash × Seq)) (inSeq : Seq)
    (hnb : ∀ h S, hBase = some (h, S) → ¬ inSeq < S) :
    decideRowEq tomb hIn hLoc hBase inSeq = decideRow tomb hIn hLoc hBase inSeq := by
  cases hBase with
  | none => simp [decideRowEq, decideRow, staleOrSeen]
  | some p =>
    obtain ⟨h, S⟩ := p
    have hge : S ≤ inSeq := Nat.le_of_not_lt (hnb h S rfl)
    by_cases heq : inSeq = S
    · subst heq
      simp [decideRowEq, decideRow, staleOrSeen]
    · have hlt : S < inSeq := Nat.lt_of_le_of_ne hge (Ne.symm heq)
      have h1 : ¬ (inSeq ≤ S) := Nat.not_le.mpr hlt
      have heq' : ¬ S = inSeq := Ne.symm heq
      simp [decideRowEq, decideRow, staleOrSeen, heq', h1]

/-- The table WITHOUT the pending-delete row — the reading "本地 absent →
插入" that 34a7810's review seven rejected (its other rows are v1.3's).
Kept only for `edit_beats_delete_without_row_witness`, which reads
content, shelf and the tombstone PATCH, not the baseline hash. -/
def decideRowNoPendingDelete : Core := fun tomb hIn hLoc hBase inSeq =>
  if staleOrSeen hBase inSeq then
    { action := .skip, base := hBase, shelfRemote := false, shelfLocal := false }
  else decideRowV13 tomb hIn hLoc hBase inSeq

/-- T2 WITNESS against the v1.3 table (re-apply doubles the shelf): the
conflict row — local dirty, baseline present, incoming a third version —
sets the baseline to `(base hash, in seq)` and shelves the incoming row;
applying the SAME row again finds the same dirty local and the same
foreign base hash, and shelves it AGAIN. The skip row sees the seq it
just wrote and applies the row once. Reopened only if the skip row is
dropped. -/
theorem conflict_reapply_doubles_shelf_v13_witness :
    (applyRowWith decideRowV13 id (applyRowWith decideRowV13 id
        (oneRow (some 2) (some (3, 1))) ⟨1, 5, 4, false⟩) ⟨1, 5, 4, false⟩).shelf
        = [(1, 4), (1, 4)]
      ∧ (applyRow id (applyRow id (oneRow (some 2) (some (3, 1)))
          ⟨1, 5, 4, false⟩) ⟨1, 5, 4, false⟩).shelf = [(1, 4)] := by
  constructor <;> decide

/-- I3 crash between slot and baseline, then a local edit of the adopted
row before the re-pull: the re-applied row is a conflict (local ≠ incoming
≠ old baseline) and the incoming bytes are shelved once. No byte is lost:
the baseline becomes the incoming row's `(hash, seq)`, the edit stays
dirty against it, and the next PATCH passes I8; the entry is spurious
only in that the local edit was derived from those very bytes. The skip
row does not remove it — the baseline seq is still the OLD one, below
the row's. -/
theorem slot_only_crash_then_edit_witness :
    (applyRow id (oneRowAt (some 2) (some (0, 4)) 4) ⟨1, 5, 1, false⟩).shelf = [(1, 1)]
      ∧ (applyRow id (oneRowAt (some 2) (some (0, 4)) 4) ⟨1, 5, 1, false⟩).base 1
        = some (1, 5) := by
  constructor <;> decide

end Idempotence

/-! ## What a baseline may claim about the server

Predicates on a (server, replica) pair, each a reading of "the baseline
`(hash, seq)` tells the truth about the server row". Every operation of
the model preserves each of them; where, is stated at each theorem
(`BaseHashSound` on every reachable state: `reachable_sound`). -/

/-- Every baseline seq has been handed out by the counter. -/
def BaseBounded (s : Server C) (r : Replica C) : Prop :=
  ∀ id h S, r.base id = some (h, S) → S ≤ s.counter

/-- A baseline seq that equals the seq of the server's row for that id
names a LIVE row. (False by design on a singleton table, where the
baseline follows the dead row's seq — `Singleton`.) -/
def NoDeadBase (s : Server C) (r : Replica C) : Prop :=
  ∀ id h S row, r.base id = some (h, S) → s.rows id = some row → row.seq = S →
    row.deleted = false

/-- Every baseline entry names a server row, and the server's seq for
that id is at or above the baseline's: the server never goes back past
a seq a replica recorded. This is what makes a head-page row never
strictly older than the baseline, so the `≤` skip row fires on a head
page exactly where `==` would. -/
def BaseAnchored (s : Server C) (r : Replica C) : Prop :=
  ∀ id h S, r.base id = some (h, S) → ∃ row, s.rows id = some row ∧ S ≤ row.seq

/-- A baseline whose seq is the server row's seq carries the hash of that
row's content. Every baseline writer the model has maintains it — a
`[row]` response (`hash sent`, the server now holds `sent`; a late one
under the guard), every non-skip row of the table (`hash incoming`, the
conflict and pending-delete rows included), the pending-verify rewrite
(`sentHash`, which a `[]` at that seq vouches for), the restore replay
(`hash(cloud row)` at the cloud's seq, or the entry the id had) — so it
holds on every reachable state (`reachable_sound`). It speaks only while
the server row still carries the baseline's seq; the past-tense form is
`BaseHeld`. The superseded conflict writing broke it
(`keep_hash_state_not_sound`), and so does slice 1's restore replay
(`restore_replay_local_hash_witness`, `slice1_collision_clean_control`). -/
def BaseHashSound (hash : C → Hash) (s : Server C) (r : Replica C) : Prop :=
  ∀ id h S row, r.base id = some (h, S) → s.rows id = some row → row.seq = S →
    h = hash row.content

/-- The baseline tracks the feed below the cursor: a server row at or
below the cursor has exactly the seq the baseline holds for it. This is
what "没见到就是服务端没取新号" relies on; it is an invariant of the
model under snapshot pages (`baseTracksFeed_pull`), stale ones included. -/
def BaseTracksFeed (s : Server C) (r : Replica C) : Prop :=
  ∀ id h S row, r.base id = some (h, S) → s.rows id = some row →
    row.seq ≤ r.cursor → row.seq = S

/-- Local content equals the server's live content at every id whose
server row (if any) is at or below the cursor — "in sync below the
cursor", carried across pages. Not an invariant (a dirty row differs by
design); on reachable states it holds of every all-clean replica
(`synced_below_of_clean`). -/
def SyncedBelow (s : Server C) (r : Replica C) : Prop :=
  ∀ i, (∀ row, s.rows i = some row → row.seq ≤ r.cursor) → r.loc i = s.live i

/-- `page` is exactly the server's rows past `since`, one row per id, as
`sync_changes(since)` returns them under one snapshot (I5) when the
page limit does not cut the delta: sound (every page row IS the server's
row), complete (every server row past `since` is in the page), one row
per id. A page of an EARLIER server state is a snapshot too — the
theorems that need that say `IsHeadFeed s₀ … ∧ Advances s₀ s`. -/
structure IsHeadFeed (s : Server C) (since : Seq)
    (page : List (FeedRow C)) : Prop where
  sound : ∀ fr ∈ page,
    s.rows fr.id = some ⟨fr.content, fr.seq, fr.deleted⟩ ∧ since < fr.seq
  complete : ∀ i row, s.rows i = some row → since < row.seq →
    ∃ fr ∈ page, fr.id = i
  distinct : page.Pairwise fun a b => a.id ≠ b.id

/-- `page` is the server's rows with `since < seq ≤ bound`, one row per
id, under one snapshot — what one `sync_changes(since, page_limit)` call
returns when the limit (or the row clamp) cuts the delta at the seq of
its last row. `IsHeadFeed` is the case `bound = s.counter`
(`IsHeadFeed.page`). The I1 loop is a run of these (`Chain`). -/
structure IsPageFeed (s : Server C) (since bound : Seq)
    (page : List (FeedRow C)) : Prop where
  sound : ∀ fr ∈ page,
    s.rows fr.id = some ⟨fr.content, fr.seq, fr.deleted⟩ ∧ since < fr.seq ∧ fr.seq ≤ bound
  complete : ∀ i row, s.rows i = some row → since < row.seq → row.seq ≤ bound →
    ∃ fr ∈ page, fr.id = i
  distinct : page.Pairwise fun a b => a.id ≠ b.id

theorem IsHeadFeed.page {s : Server C} {since : Seq} {page : List (FeedRow C)}
    (hwf : s.WF) (h : IsHeadFeed s since page) : IsPageFeed s since s.counter page :=
  ⟨fun fr hfr => ⟨(h.sound fr hfr).1, (h.sound fr hfr).2, hwf fr.id _ (h.sound fr hfr).1⟩,
    fun i row hrow hlt _ => h.complete i row hrow hlt, h.distinct⟩

/-- On a page row that is the server's row, anchoring says the baseline
seq is at or below the row's. -/
theorem anchored_at {s : Server C} {r : Replica C} (hanch : BaseAnchored s r)
    (fr : FeedRow C) (hsound : s.rows fr.id = some ⟨fr.content, fr.seq, fr.deleted⟩) :
    ∀ h S, r.base fr.id = some (h, S) → S ≤ fr.seq := by
  intro h S hb
  obtain ⟨row, hrow, hle⟩ := hanch fr.id h S hb
  rw [hsound] at hrow
  cases hrow
  exact hle

/-! ## T5 — a clean replica pulling a page lands on the server -/

section Convergence
variable (hash : C → Hash)

/-- A clean id: the local row's hash IS the baseline hash (both absent
counts as clean; a pending delete or an unpushed new row does not). -/
def CleanAt (r : Replica C) (i : Id) : Prop :=
  (r.loc i).map hash = (r.base i).map Prod.fst

/-- On a clean id, a row the baseline does NOT already name or exceed: the
incoming live/dead state is adopted verbatim, the baseline lands on
`(hash incoming, seq)` or is removed, nothing is shelved, and the id is
clean again. The echo and same rows keep the local row, and injectivity
is what says that row IS the incoming content. -/
theorem applyRow_clean_full_noskip (hinj : HashInjective hash) (r : Replica C)
    (fr : FeedRow C) (hclean : CleanAt hash r fr.id)
    (hns : staleOrSeen (r.base fr.id) fr.seq = false) :
    (applyRow hash r fr).loc fr.id = (if fr.deleted then none else some fr.content)
      ∧ (applyRow hash r fr).base fr.id
          = (if fr.deleted then none else some (hash fr.content, fr.seq))
      ∧ (applyRow hash r fr).shelf = r.shelf
      ∧ CleanAt hash (applyRow hash r fr) fr.id := by
  unfold CleanAt at hclean
  cases hd : fr.deleted
  · simp only [Bool.false_eq_true, ↓reduceIte]
    by_cases h1 : (r.base fr.id).map Prod.fst = some (hash fr.content)
    · have hecho := decideRow_echo (hash fr.content) ((r.loc fr.id).map hash)
        (r.base fr.id) fr.seq hns h1
      rw [h1] at hclean
      cases hl : r.loc fr.id with
      | none => simp [hl] at hclean
      | some l =>
        simp only [hl, Option.map_some, Option.some.injEq] at hclean
        have hle := hinj _ _ hclean
        subst hle
        simp only [applyRow, applyRowWith, hd, hecho]
        simp [hl, CleanAt]
    · by_cases h2 : (r.loc fr.id).map hash = some (hash fr.content)
      · have hsame := decideRow_same (hash fr.content) ((r.loc fr.id).map hash)
          (r.base fr.id) fr.seq hns h1 h2
        cases hl : r.loc fr.id with
        | none => simp [hl] at h2
        | some l =>
          simp only [hl, Option.map_some, Option.some.injEq] at h2
          have hle := hinj _ _ h2
          subst hle
          simp only [applyRow, applyRowWith, hd, hsame]
          simp [hl, CleanAt]
      · have hadopt := decideRow_adopt (hash fr.content) ((r.loc fr.id).map hash)
          (r.base fr.id) fr.seq hns h1 hclean
        simp only [applyRow, applyRowWith, hd, hadopt]
        simp [CleanAt]
  · have ht := decideRow_tomb (hash fr.content) ((r.loc fr.id).map hash)
      (r.base fr.id) fr.seq hns
    simp only [applyRow, applyRowWith, hd, ht]
    simp [hclean, CleanAt]

/-- On a clean id whose baseline is anchored on the row (its seq is at
most the row's — true of every head-page row) and tells the truth (if
it names the row's seq, it carries the row's hash and the row is live),
the incoming state is landed whether the row is skipped or applied. -/
theorem applyRow_clean_full (hinj : HashInjective hash) (r : Replica C)
    (fr : FeedRow C) (hclean : CleanAt hash r fr.id)
    (hanch : ∀ h S, r.base fr.id = some (h, S) → S ≤ fr.seq)
    (hrow : ∀ h, r.base fr.id = some (h, fr.seq) → h = hash fr.content ∧ fr.deleted = false) :
    (applyRow hash r fr).loc fr.id = (if fr.deleted then none else some fr.content)
      ∧ (applyRow hash r fr).base fr.id
          = (if fr.deleted then none else some (hash fr.content, fr.seq))
      ∧ (applyRow hash r fr).shelf = r.shelf
      ∧ CleanAt hash (applyRow hash r fr) fr.id := by
  cases hs : staleOrSeen (r.base fr.id) fr.seq
  · exact applyRow_clean_full_noskip hash hinj r fr hclean hs
  · obtain ⟨h, S, hb, hle⟩ := (staleOrSeen_true_iff _ _).mp hs
    have hS : S = fr.seq := Nat.le_antisymm (hanch h S hb) hle
    subst hS
    obtain ⟨hh, hd⟩ := hrow h hb
    subst hh
    rw [applyRow_skip hash r fr hs, hd]
    simp only [Bool.false_eq_true, ↓reduceIte]
    unfold CleanAt at hclean
    rw [hb] at hclean
    cases hl : r.loc fr.id with
    | none => rw [hl] at hclean; simp at hclean
    | some l =>
      rw [hl] at hclean
      simp only [Option.map_some, Option.some.injEq] at hclean
      have hle := hinj _ _ hclean
      subst hle
      refine ⟨?_, hb, ?_, ?_⟩
      · rfl
      · trivial
      · simp [CleanAt, hl, hb]

/-- On a clean id the shelf is untouched and the id stays clean, with no
assumption about the baseline — the skip row is the identity. -/
theorem applyRow_clean_keep (hinj : HashInjective hash) (r : Replica C)
    (fr : FeedRow C) (hclean : CleanAt hash r fr.id) :
    (applyRow hash r fr).shelf = r.shelf ∧ CleanAt hash (applyRow hash r fr) fr.id := by
  cases hs : staleOrSeen (r.base fr.id) fr.seq
  · have h := applyRow_clean_full_noskip hash hinj r fr hclean hs
    exact ⟨h.2.2.1, h.2.2.2⟩
  · rw [applyRow_skip hash r fr hs]
    exact ⟨rfl, hclean⟩

/-- The loc half of `applyRow_clean_full`, kept under its original name. -/
theorem applyRow_clean_lands (hinj : HashInjective hash) (r : Replica C)
    (fr : FeedRow C) (hclean : CleanAt hash r fr.id)
    (hanch : ∀ h S, r.base fr.id = some (h, S) → S ≤ fr.seq)
    (hrow : ∀ h, r.base fr.id = some (h, fr.seq) → h = hash fr.content ∧ fr.deleted = false) :
    (applyRow hash r fr).loc fr.id =
      if fr.deleted then none else some fr.content :=
  (applyRow_clean_full hash hinj r fr hclean hanch hrow).1

theorem applyRow_clean_elsewhere (r : Replica C) (fr : FeedRow C) (i : Id)
    (hne : i ≠ fr.id) (hclean : CleanAt hash r i) :
    CleanAt hash (applyRow hash r fr) i := by
  unfold CleanAt
  obtain ⟨h1, h2⟩ := applyRow_frame hash r fr i hne
  rw [h1, h2]; exact hclean

/-- The effect at `fr.id` depends only on the replica's row and baseline
at `fr.id`. -/
theorem applyRow_self_congr (q r : Replica C) (fr : FeedRow C)
    (hl : q.loc fr.id = r.loc fr.id) (hb : q.base fr.id = r.base fr.id) :
    (applyRow hash q fr).loc fr.id = (applyRow hash r fr).loc fr.id
      ∧ (applyRow hash q fr).base fr.id = (applyRow hash r fr).base fr.id := by
  constructor
  · rw [applyRow_loc_self, applyRow_loc_self, hl, hb]
  · rw [applyRow_base_self, applyRow_base_self, hl, hb]

theorem foldl_frame (page : List (FeedRow C)) (r : Replica C) (i : Id)
    (h : ∀ fr ∈ page, fr.id ≠ i) :
    (page.foldl (applyRow hash) r).loc i = r.loc i
      ∧ (page.foldl (applyRow hash) r).base i = r.base i := by
  induction page generalizing r with
  | nil => exact ⟨rfl, rfl⟩
  | cons fr rest ih =>
    simp only [List.foldl]
    have hfr : fr.id ≠ i := h fr (by simp)
    have hrest : ∀ x ∈ rest, x.id ≠ i := fun x hx => h x (by simp [hx])
    obtain ⟨h1, h2⟩ := ih (applyRow hash r fr) hrest
    rw [h1, h2]
    exact applyRow_frame hash r fr i (Ne.symm hfr)

/-- In a page with distinct ids, the fold's effect at a page row's id is
that row's own effect on the starting replica. -/
theorem foldl_self_of_mem (page : List (FeedRow C)) (r : Replica C) (fr0 : FeedRow C)
    (hdistinct : page.Pairwise fun a b => a.id ≠ b.id) (hmem : fr0 ∈ page) :
    (page.foldl (applyRow hash) r).loc fr0.id = (applyRow hash r fr0).loc fr0.id
      ∧ (page.foldl (applyRow hash) r).base fr0.id = (applyRow hash r fr0).base fr0.id := by
  induction page generalizing r with
  | nil => simp at hmem
  | cons fr rest ih =>
    simp only [List.foldl]
    rw [List.pairwise_cons] at hdistinct
    obtain ⟨hhead, hrest⟩ := hdistinct
    simp only [List.mem_cons] at hmem
    rcases hmem with hmem | hmem
    · subst hmem
      exact foldl_frame hash rest _ fr0.id fun x hx => (hhead x hx).symm
    · have hne : fr.id ≠ fr0.id := hhead fr0 hmem
      obtain ⟨h1, h2⟩ := ih (applyRow hash r fr) hrest hmem
      rw [h1, h2]
      obtain ⟨f1, f2⟩ := applyRow_frame hash r fr fr0.id (Ne.symm hne)
      exact applyRow_self_congr hash _ r fr0 f1 f2

/-- An all-clean replica stays all-clean and never touches its shelf
across a fold. -/
theorem foldl_clean_shelf (hinj : HashInjective hash) (page : List (FeedRow C))
    (r : Replica C) (hclean : ∀ i, CleanAt hash r i) :
    (page.foldl (applyRow hash) r).shelf = r.shelf
      ∧ ∀ i, CleanAt hash (page.foldl (applyRow hash) r) i := by
  induction page generalizing r with
  | nil => exact ⟨rfl, hclean⟩
  | cons fr rest ih =>
    simp only [List.foldl]
    have hclean' : ∀ i, CleanAt hash (applyRow hash r fr) i := by
      intro i
      by_cases hi : i = fr.id
      · subst hi; exact (applyRow_clean_keep hash hinj r fr (hclean fr.id)).2
      · exact applyRow_clean_elsewhere hash r fr i hi (hclean i)
    obtain ⟨h1, h2⟩ := ih (applyRow hash r fr) hclean'
    refine ⟨?_, h2⟩
    rw [h1]
    exact (applyRow_clean_keep hash hinj r fr (hclean fr.id)).1

theorem foldl_lands (hinj : HashInjective hash) (page : List (FeedRow C))
    (r : Replica C) (i : Id) (fr0 : FeedRow C)
    (hdistinct : page.Pairwise fun a b => a.id ≠ b.id)
    (hmem : fr0 ∈ page) (hid : fr0.id = i) (hclean : CleanAt hash r i)
    (hanch : ∀ h S, r.base i = some (h, S) → S ≤ fr0.seq)
    (hrow : ∀ h, r.base i = some (h, fr0.seq) → h = hash fr0.content ∧ fr0.deleted = false) :
    (page.foldl (applyRow hash) r).loc i =
        (if fr0.deleted then none else some fr0.content)
      ∧ (page.foldl (applyRow hash) r).base i =
        (if fr0.deleted then none else some (hash fr0.content, fr0.seq)) := by
  subst hid
  obtain ⟨h1, h2⟩ := foldl_self_of_mem hash page r fr0 hdistinct hmem
  rw [h1, h2]
  have h := applyRow_clean_full hash hinj r fr0 hclean hanch hrow
  exact ⟨h.1, h.2.1⟩

theorem foldl_max_le (rows : List (FeedRow C)) (init bound : Seq)
    (hinit : init ≤ bound) (hall : ∀ fr ∈ rows, fr.seq ≤ bound) :
    rows.foldl (fun m fr => max m fr.seq) init ≤ bound := by
  induction rows generalizing init with
  | nil => exact hinit
  | cons fr rest ih =>
    exact ih (max init fr.seq) (Nat.max_le.mpr ⟨hinit, hall fr (by simp)⟩)
      (fun x hx => hall x (by simp [hx]))

theorem foldl_max_ge (rows : List (FeedRow C)) (init : Seq) :
    init ≤ rows.foldl (fun m fr => max m fr.seq) init
      ∧ ∀ fr ∈ rows, fr.seq ≤ rows.foldl (fun m fr => max m fr.seq) init := by
  induction rows generalizing init with
  | nil => exact ⟨Nat.le_refl _, by simp⟩
  | cons fr rest ih =>
    obtain ⟨h1, h2⟩ := ih (max init fr.seq)
    refine ⟨Nat.le_trans (Nat.le_max_left _ _) h1, ?_⟩
    intro x hx
    simp only [List.mem_cons] at hx
    rcases hx with hx | hx
    · subst hx
      exact Nat.le_trans (Nat.le_max_right _ _) h1
    · exact h2 x hx

/-- Ids not in the page keep their row and baseline across a pull. -/
theorem pull_frame (r : Replica C) (page : List (FeedRow C)) (i : Id)
    (h : ∀ fr ∈ page, fr.id ≠ i) :
    (pull hash r page).loc i = r.loc i ∧ (pull hash r page).base i = r.base i := by
  simp only [pull]
  exact foldl_frame hash _ r i fun fr hfr => h fr (List.mem_filter.mp hfr).1

/-- The page rows of a limit-cut page are all past the cursor, so the
filter keeps the page as it is. -/
theorem IsPageFeed.filter_self {s : Server C} {r : Replica C} {bound : Seq}
    {page : List (FeedRow C)} (hfeed : IsPageFeed s r.cursor bound page) :
    page.filter (fun fr => decide (r.cursor < fr.seq)) = page :=
  List.filter_eq_self.mpr fun fr hfr => by simp [(hfeed.sound fr hfr).2.1]

/-- After pulling a limit-cut page of `s`, every server row at or below
the page's bound is at or below the cursor. -/
theorem pull_page_covers (s : Server C) (r : Replica C) (bound : Seq)
    (page : List (FeedRow C)) (hfeed : IsPageFeed s r.cursor bound page) :
    ∀ i row, s.rows i = some row → row.seq ≤ bound → row.seq ≤ (pull hash r page).cursor := by
  intro i row hrow hle
  have hcur : (pull hash r page).cursor = page.foldl (fun m fr => max m fr.seq) r.cursor := by
    simp only [pull, hfeed.filter_self]
  rw [hcur]
  obtain ⟨hinit, hall⟩ := foldl_max_ge page r.cursor
  rcases Nat.lt_or_ge r.cursor row.seq with hlt | hge
  · obtain ⟨fr, hfr, hid⟩ := hfeed.complete i row hrow hlt hle
    subst hid
    have := (hfeed.sound fr hfr).1
    rw [this] at hrow
    cases hrow
    exact hall fr hfr
  · exact Nat.le_trans hge hinit

/-- The cursor after a limit-cut page is at most the larger of the old
cursor and the bound. -/
theorem pull_page_cursor_le (s : Server C) (r : Replica C) (bound : Seq)
    (page : List (FeedRow C)) (hfeed : IsPageFeed s r.cursor bound page) :
    (pull hash r page).cursor ≤ max r.cursor bound := by
  have hcur : (pull hash r page).cursor = page.foldl (fun m fr => max m fr.seq) r.cursor := by
    simp only [pull, hfeed.filter_self]
  rw [hcur]
  exact foldl_max_le _ _ _ (Nat.le_max_left _ _)
    (fun fr hfr => Nat.le_trans (hfeed.sound fr hfr).2.2 (Nat.le_max_right _ _))

/-- After pulling a head page of `s`, every server row is at or below the
cursor: the replica is at head. -/
theorem pull_head_covers (s : Server C) (r : Replica C) (page : List (FeedRow C))
    (hfeed : IsHeadFeed s r.cursor page) :
    ∀ i row, s.rows i = some row → row.seq ≤ (pull hash r page).cursor := by
  intro i row hrow
  have hfilter : page.filter (fun fr => decide (r.cursor < fr.seq)) = page :=
    List.filter_eq_self.mpr fun fr hfr => by simp [(hfeed.sound fr hfr).2]
  have hcur : (pull hash r page).cursor = page.foldl (fun m fr => max m fr.seq) r.cursor := by
    simp only [pull, hfilter]
  rw [hcur]
  obtain ⟨hinit, hall⟩ := foldl_max_ge page r.cursor
  rcases Nat.lt_or_ge r.cursor row.seq with hlt | hge
  · obtain ⟨fr, hfr, hid⟩ := hfeed.complete i row hrow hlt
    subst hid
    have := (hfeed.sound fr hfr).1
    rw [this] at hrow
    cases hrow
    exact hall fr hfr
  · exact Nat.le_trans hge hinit

/-- THEOREM T5-page (a clean replica pulling one limit-cut page): a
replica with no dirty id, in sync below its cursor, whose baselines are
anchored and tell the truth (`BaseAnchored`, `BaseHashSound`,
`NoDeadBase` — what a page row the baseline already names needs, since
the skip row skips it; all three hold on every reachable state,
`reachable_sound`), that pulls one page of `s` cut at `bound` is
again in sync below its (new) cursor, with its shelf untouched, every id
clean again, and the baseline of every page row landed on
`(hash live, seq)` or removed. Injectivity is the one hypothesis beyond
the §6 table. -/
theorem clean_replica_page (hinj : HashInjective hash)
    (s : Server C) (r : Replica C) (bound : Seq) (page : List (FeedRow C))
    (hclean : ∀ i, CleanAt hash r i) (hsync : SyncedBelow s r)
    (hanch : BaseAnchored s r) (hbh : BaseHashSound hash s r) (hnd : NoDeadBase s r)
    (hfeed : IsPageFeed s r.cursor bound page) :
    SyncedBelow s (pull hash r page)
      ∧ (pull hash r page).shelf = r.shelf
      ∧ (∀ i, CleanAt hash (pull hash r page) i)
      ∧ ∀ fr ∈ page, (pull hash r page).base fr.id
          = (if fr.deleted then none else some (hash fr.content, fr.seq)) := by
  have hrow : ∀ fr ∈ page, ∀ h, r.base fr.id = some (h, fr.seq) →
      h = hash fr.content ∧ fr.deleted = false := by
    intro fr hfr h hb
    have hs := (hfeed.sound fr hfr).1
    exact ⟨hbh fr.id h fr.seq _ hb hs rfl, hnd fr.id h fr.seq _ hb hs rfl⟩
  have hanch' : ∀ fr ∈ page, ∀ h S, r.base fr.id = some (h, S) → S ≤ fr.seq :=
    fun fr hfr => anchored_at hanch fr (hfeed.sound fr hfr).1
  have hcovers := pull_page_covers hash s r bound page hfeed
  have hcurle := pull_page_cursor_le hash s r bound page hfeed
  have hlands : ∀ fr ∈ page, (pull hash r page).loc fr.id
        = (if fr.deleted then none else some fr.content)
      ∧ (pull hash r page).base fr.id
        = (if fr.deleted then none else some (hash fr.content, fr.seq)) := by
    intro fr hfr
    simp only [pull, hfeed.filter_self]
    exact foldl_lands hash hinj page r fr.id fr hfeed.distinct hfr rfl (hclean fr.id)
      (hanch' fr hfr) (hrow fr hfr)
  have hshelf : (pull hash r page).shelf = r.shelf
      ∧ ∀ i, CleanAt hash (pull hash r page) i := by
    simp only [pull, hfeed.filter_self]
    exact foldl_clean_shelf hash hinj page r hclean
  refine ⟨?_, hshelf.1, hshelf.2, fun fr hfr => (hlands fr hfr).2⟩
  intro i hp
  by_cases hin : ∃ fr ∈ page, fr.id = i
  · obtain ⟨fr0, hmem, hid⟩ := hin
    subst hid
    rw [(hlands fr0 hmem).1]
    have := (hfeed.sound fr0 hmem).1
    simp [Server.live, this]
  · have hin' : ∀ fr ∈ page, fr.id ≠ i := fun fr hfr hid => hin ⟨fr, hfr, hid⟩
    rw [(pull_frame hash r page i hin').1]
    apply hsync
    intro row hrow
    rcases Nat.lt_or_ge r.cursor row.seq with hlt | hge
    · have hle : row.seq ≤ bound := by
        have h1 := Nat.le_trans (hp row hrow) hcurle
        rcases Nat.le_total r.cursor bound with hc | hc
        · rw [Nat.max_eq_right hc] at h1; exact h1
        · rw [Nat.max_eq_left hc] at h1
          exact absurd (Nat.lt_of_lt_of_le hlt h1) (Nat.lt_irrefl _)
      obtain ⟨fr, hfr, hfrid⟩ := hfeed.complete i row hrow hlt hle
      exact absurd hfrid (hin' fr hfr)
    · exact hge

/-- THEOREM T5 (clean-replica convergence): a replica with no dirty id,
in sync below its cursor, whose baselines are anchored and tell the
truth, that pulls one head page ends with local content equal to the
server's live content at EVERY id — tombstones included — with its shelf
untouched, every id clean again, and the baseline of every page row
landed on `(hash live, seq)` or removed. On a reachable replica the
truthfulness premises are theorems: `clean_replica_converges_reachable`. -/
theorem clean_replica_converges (hinj : HashInjective hash)
    (s : Server C) (hwf : s.WF) (r : Replica C) (page : List (FeedRow C))
    (hclean : ∀ i, CleanAt hash r i) (hsync : SyncedBelow s r)
    (hanch : BaseAnchored s r) (hbh : BaseHashSound hash s r) (hnd : NoDeadBase s r)
    (hfeed : IsHeadFeed s r.cursor page) :
    (∀ i, (pull hash r page).loc i = s.live i)
      ∧ (pull hash r page).shelf = r.shelf
      ∧ (∀ i, CleanAt hash (pull hash r page) i)
      ∧ ∀ fr ∈ page, (pull hash r page).base fr.id
          = (if fr.deleted then none else some (hash fr.content, fr.seq)) := by
  obtain ⟨h1, h2, h3, h4⟩ := clean_replica_page hash hinj s r s.counter page hclean hsync
    hanch hbh hnd (hfeed.page hwf)
  exact ⟨fun i => h1 i (pull_head_covers hash s r page hfeed i), h2, h3, h4⟩

/-- I3's page-level crash for one slot: every row of the page is in the
slot-written-baseline-unwritten state (the slot's persist returned true,
the baseline write was lost before the cursor moved). The re-pull of the
page lands every row's baseline and shelves nothing. -/
theorem pull_after_slot_only_heals (r : Replica C) (page : List (FeedRow C))
    (hdistinct : page.Pairwise fun a b => a.id ≠ b.id)
    (hrows : ∀ fr ∈ page, r.cursor < fr.seq ∧ fr.deleted = false
      ∧ r.loc fr.id = some fr.content ∧ staleOrSeen (r.base fr.id) fr.seq = false) :
    (∀ fr ∈ page, (pull hash r page).loc fr.id = some fr.content
        ∧ (pull hash r page).base fr.id = some (hash fr.content, fr.seq))
      ∧ (pull hash r page).shelf = r.shelf := by
  have hfilter : page.filter (fun fr => decide (r.cursor < fr.seq)) = page :=
    List.filter_eq_self.mpr fun fr hfr => by simp [(hrows fr hfr).1]
  simp only [pull, hfilter]
  refine ⟨?_, ?_⟩
  · intro fr hfr
    obtain ⟨-, hlive, hslot, hns⟩ := hrows fr hfr
    obtain ⟨h1, h2⟩ := foldl_self_of_mem hash page r fr hdistinct hfr
    show (page.foldl (applyRow hash) r).loc fr.id = some fr.content
      ∧ (page.foldl (applyRow hash) r).base fr.id = some (hash fr.content, fr.seq)
    rw [h1, h2]
    have h := applyRow_after_slot_only_heals hash r fr hlive hslot hns
    exact ⟨h.1, h.2.1⟩
  · show (page.foldl (applyRow hash) r).shelf = r.shelf
    have hall : ∀ q : Replica C, (∀ fr ∈ page, fr.deleted = false ∧ q.loc fr.id = some fr.content
        ∧ staleOrSeen (q.base fr.id) fr.seq = false) →
        (page.foldl (applyRow hash) q).shelf = q.shelf := by
      clear hrows hfilter
      induction page with
      | nil => intro q _; rfl
      | cons fr rest ih =>
        intro q hq
        rw [List.pairwise_cons] at hdistinct
        obtain ⟨hhead, hrest⟩ := hdistinct
        obtain ⟨hlive, hslot, hns⟩ := hq fr (by simp)
        simp only [List.foldl]
        rw [ih hrest (applyRow hash q fr) ?_]
        · exact (applyRow_after_slot_only_heals hash q fr hlive hslot hns).2.2
        · intro x hx
          obtain ⟨hl, hs, hn⟩ := hq x (by simp [hx])
          obtain ⟨f1, f2⟩ := applyRow_frame hash q fr x.id (hhead x hx).symm
          exact ⟨hl, by rw [f1]; exact hs, by rw [f2]; exact hn⟩
    exact hall r fun fr hfr => ⟨(hrows fr hfr).2.1, (hrows fr hfr).2.2.1, (hrows fr hfr).2.2.2⟩

end Convergence


/-! ## T3 — push, then its echo -/

section PushEcho
variable [DecidableEq C] (hash : C → Hash)

/-- What the branches of `pushRow` are, for every proof that walks them:
nothing sent (no local row, or clean); `[row]` live from a PATCH
(against a live row at the base seq); `[row]` DEAD from a PATCH (the
third response — treated as an incoming tombstone); `[]` from a PATCH
(server untouched, and the PATCH's own answer was `[]`); `[row]` from a
POST; `[]` from a POST (only the counter burned). -/
theorem pushRow_cases (s : Server C) (r : Replica C) (id : Id) :
    ((r.loc id = none ∨ ∃ c, r.loc id = some c ∧ (r.base id).map Prod.fst = some (hash c))
      ∧ pushRow hash s r id = ⟨s, r, false, none⟩)
    ∨ (∃ c row bh bseq, r.loc id = some c ∧ r.base id = some (bh, bseq)
        ∧ s.rows id = some row ∧ row.seq = bseq ∧ row.deleted = false
        ∧ pushRow hash s r id =
          ⟨s.setRow id { content := c, seq := s.next, deleted := row.deleted } s.next,
            r.setBase id (some (hash c, s.next)), false, none⟩)
    ∨ (∃ c row bh bseq, r.loc id = some c ∧ r.base id = some (bh, bseq)
        ∧ s.rows id = some row ∧ row.seq = bseq ∧ row.deleted = true
        ∧ pushRow hash s r id =
          ⟨s.setRow id { content := c, seq := s.next, deleted := row.deleted } s.next,
            r.deadRowHit id c, false, none⟩)
    ∨ (∃ c bh bseq, r.loc id = some c ∧ r.base id = some (bh, bseq)
        ∧ (s.patch id bseq c).2 = none
        ∧ pushRow hash s r id = ⟨s, r, true, some ⟨id, bseq, hash c⟩⟩)
    ∨ (∃ c, r.loc id = some c ∧ r.base id = none ∧ s.rows id = none
        ∧ pushRow hash s r id =
          ⟨s.setRow id { content := c, seq := s.next, deleted := false } s.next,
            r.setBase id (some (hash c, s.next)), false, none⟩)
    ∨ (∃ c, r.loc id = some c ∧ r.base id = none
        ∧ pushRow hash s r id = ⟨{ s with counter := s.next }, r, true, none⟩) := by
  unfold pushRow
  split
  · rename_i hloc
    exact Or.inl ⟨Or.inl hloc, rfl⟩
  · rename_i c hloc
    split
    · rename_i hclean
      exact Or.inl ⟨Or.inr ⟨c, hloc, hclean⟩, rfl⟩
    · rename_i hdirty
      split
      · rename_i p bh bseq hbase
        split
        · rename_i s' row hres
          have hx : ∃ row0, s.rows id = some row0 ∧ row0.seq = bseq ∧
              s' = s.setRow id { content := c, seq := s.next, deleted := row0.deleted } s.next
              ∧ row = { content := c, seq := s.next, deleted := row0.deleted } := by
            unfold Server.patch at hres
            split at hres
            · cases hres
            · rename_i row0 hrow0
              split at hres
              · cases hres
              · split at hres
                · cases hres
                · rename_i hs _
                  cases hres
                  exact ⟨row0, hrow0, Decidable.not_not.mp hs, rfl, rfl⟩
          obtain ⟨row0, hrow0, hseq, hs', hrow⟩ := hx
          subst hs' hrow
          split
          · rename_i hdead
            right; right; left
            exact ⟨c, row0, bh, bseq, hloc, hbase, hrow0, hseq, hdead, rfl⟩
          · rename_i hlive
            right; left
            exact ⟨c, row0, bh, bseq, hloc, hbase, hrow0, hseq, by simpa using hlive, rfl⟩
        · rename_i s' hres
          right; right; right; left
          have hs' : s' = s := by
            unfold Server.patch at hres
            split at hres
            · cases hres; rfl
            · split at hres
              · cases hres; rfl
              · split at hres
                · cases hres; rfl
                · cases hres
          subst hs'
          exact ⟨c, bh, bseq, hloc, hbase, by rw [hres], rfl⟩
      · rename_i hbase
        split
        · rename_i s' seq' hres
          right; right; right; right; left
          have hx : s.rows id = none
              ∧ s' = s.setRow id { content := c, seq := s.next, deleted := false } s.next
              ∧ seq' = s.next := by
            unfold Server.insertIgnore at hres
            split at hres
            · cases hres
            · rename_i hnone
              cases hres; exact ⟨hnone, rfl, rfl⟩
          obtain ⟨hnone, hs', hseq'⟩ := hx
          subst hs' hseq'
          exact ⟨c, hloc, hbase, hnone, rfl⟩
        · rename_i s' hres
          right; right; right; right; right
          have hs' : s' = { s with counter := s.next } := by
            unfold Server.insertIgnore at hres
            split at hres
            · cases hres; rfl
            · cases hres
          subst hs'
          exact ⟨c, hloc, hbase, rfl⟩

/-- A dirty row whose push came back `[row]` against a LIVE server row:
the server now holds exactly the sent content at a fresh seq, the
baseline is `(hash sent, seq)`, local content is untouched — and the
echo row of that push is inert (T3 proper, composed; the echo carries
the baseline's seq and is the skip row). The live-row hypothesis is
discharged on every reachable state by `push_then_echo_reachable`. -/
theorem push_then_echo (s : Server C) (r : Replica C) (id : Id) (c : C)
    (hloc : r.loc id = some c)
    (hdirty : (r.base id).map Prod.fst ≠ some (hash c))
    (hlive : ∀ row, s.rows id = some row → row.deleted = false)
    (s' : Server C) (r' : Replica C)
    (hpush : pushRow hash s r id = ⟨s', r', false, none⟩) :
    ∃ seq', s'.rows id = some ⟨c, seq', false⟩
      ∧ r'.base id = some (hash c, seq')
      ∧ r'.loc = r.loc
      ∧ (applyRow hash r' ⟨id, seq', c, false⟩).loc = r'.loc
      ∧ (applyRow hash r' ⟨id, seq', c, false⟩).shelf = r'.shelf := by
  have hecho : ∀ q : Replica C, q.base id = some (hash c, s.next) →
      (applyRow hash q ⟨id, s.next, c, false⟩).loc = q.loc
        ∧ (applyRow hash q ⟨id, s.next, c, false⟩).shelf = q.shelf := by
    intro q hq
    have h := echo_inert hash q ⟨id, s.next, c, false⟩ s.next rfl hq
    exact ⟨h.1, h.2.1⟩
  rcases pushRow_cases hash s r id with ⟨hreason, hp⟩
    | ⟨c₀, row, bh, bseq, hl, hb, hrow, hseq, hd, hp⟩
    | ⟨c₀, row, bh, bseq, hl, hb, hrow, hseq, hd, hp⟩
    | ⟨c₀, bh, bseq, hl, hb, -, hp⟩ | ⟨c₀, hl, hb, hnone, hp⟩ | ⟨c₀, hl, hb, hp⟩
  · exfalso
    rcases hreason with hn | ⟨c₁, hl, hcl⟩
    · rw [hloc] at hn; cases hn
    · rw [hloc] at hl; cases hl; exact hdirty hcl
  · rw [hloc] at hl; cases hl
    rw [hp] at hpush
    simp only [PushResult.mk.injEq] at hpush
    obtain ⟨hs, hr, -, -⟩ := hpush
    subst hs hr
    exact ⟨s.next, by simp [Server.setRow, hd], by simp [Replica.setBase], rfl,
      hecho _ (by simp [Replica.setBase])⟩
  · exfalso
    have := hlive row hrow
    rw [hd] at this; cases this
  · rw [hp] at hpush; simp at hpush
  · rw [hloc] at hl; cases hl
    rw [hp] at hpush
    simp only [PushResult.mk.injEq] at hpush
    obtain ⟨hs, hr, -, -⟩ := hpush
    subst hs hr
    exact ⟨s.next, by simp [Server.setRow], by simp [Replica.setBase], rfl,
      hecho _ (by simp [Replica.setBase])⟩
  · rw [hp] at hpush; simp at hpush

omit [DecidableEq C] in
/-- THEOREM T3b (the review-two C2 shape): push `v`, edit the local row to
anything `w` before the echo arrives, then apply the echo of `v` — local
`w` survives, nothing is shelved, and the row stays dirty under the new
seq so `w`'s own PATCH passes I8 next. (The skip row does this; the echo
row would, were the skip row absent.) The premise — the baseline is
`(hash v, seq')` — is the push's `[row]` response already applied. When
the echo is pulled BEFORE the response, a reachable order
(`echo_race_reachable`), the baseline is still the pre-push one and the
table files our own `v` as a conflict
(`echo_before_response_shelves_own_push_witness`); `decideRowInflight`
is the variant that keeps it off the shelf. -/
theorem echo_after_local_edit (r : Replica C) (id : Id) (v w : C) (seq' : Seq)
    (hbase : r.base id = some (hash v, seq'))
    (hloc : r.loc id = some w) :
    (applyRow hash r ⟨id, seq', v, false⟩).loc id = some w
      ∧ (applyRow hash r ⟨id, seq', v, false⟩).shelf = r.shelf
      ∧ (applyRow hash r ⟨id, seq', v, false⟩).base id = some (hash v, seq') := by
  have h := echo_inert hash r ⟨id, seq', v, false⟩ seq' rfl hbase
  rw [Nat.max_self] at h
  exact ⟨by rw [h.1, hloc], h.2.1, h.2.2⟩

end PushEcho

/-! ## Reachability — the baseline never names a dead row, never outruns the
server, and the cursor never passes the counter

`push_then_echo` needs `hlive`. Here it is derived from facts about a
(server, replica) pair, each preserved by every operation of the model —
the server's rows sit at or below its counter; every baseline seq and the
cursor sit at or below the counter; a baseline seq that equals the seq
of the server's row for that id names a LIVE row; and every baseline
entry names a server row whose seq is at or above the baseline's. The
third holds because a tombstone flip always mints a fresh seq
(`Server.tombstone`; in 015 `deleted_at` is outside the trigger's `meta`
set), while a baseline seq is only ever written from a `[row]` response
or a live feed row; the fourth because the server's seq for an id only
moves forward and a baseline seq is only ever taken from a server row. -/

section Reachability
variable [DecidableEq C]

structure Inv (s : Server C) (r : Replica C) : Prop where
  wf : s.WF
  bounded : BaseBounded s r
  noDead : NoDeadBase s r
  anchored : BaseAnchored s r
  cursorBounded : r.cursor ≤ s.counter

/-- What any server write does, seen from a replica: the counter moves
forward, well-formedness is kept, and a row is either untouched or carries
a seq the old counter never handed out. -/
structure Advances (s s' : Server C) : Prop where
  mono : s.counter ≤ s'.counter
  wf : s.WF → s'.WF
  rows : ∀ id row', s'.rows id = some row' → s.rows id = some row' ∨ s.counter < row'.seq
  /-- Rows are never removed (I4: a delete is a tombstone). Account erase
  (015's depth-two arm) does remove rows and is outside `Advances`. -/
  keep : ∀ id row, s.rows id = some row → ∃ row', s'.rows id = some row'

omit [DecidableEq C] in
theorem inv_of_advances {s s' : Server C} {r : Replica C} (h : Inv s r)
    (a : Advances s s') : Inv s' r := by
  refine ⟨a.wf h.wf, ?_, ?_, ?_, Nat.le_trans h.cursorBounded a.mono⟩
  · intro id hh S hb
    exact Nat.le_trans (h.bounded id hh S hb) a.mono
  · intro id hh S row hb hrow hseq
    rcases a.rows id row hrow with hold | hnew
    · exact h.noDead id hh S row hb hold hseq
    · have := h.bounded id hh S hb
      subst hseq
      exact absurd (Nat.lt_of_lt_of_le hnew this) (Nat.lt_irrefl _)
  · intro id hh S hb
    obtain ⟨row, hrow, hle⟩ := h.anchored id hh S hb
    obtain ⟨row', hrow'⟩ := a.keep id row hrow
    refine ⟨row', hrow', ?_⟩
    rcases a.rows id row' hrow' with hold | hnew
    · rw [hrow] at hold; cases hold; exact hle
    · exact Nat.le_trans (h.bounded id hh S hb) (Nat.le_of_lt hnew)

omit [DecidableEq C] in
theorem advances_refl (s : Server C) : Advances s s :=
  ⟨Nat.le_refl _, id, fun _ _ h => Or.inl h, fun _ row h => ⟨row, h⟩⟩

omit [DecidableEq C] in
theorem advances_trans {s₀ s₁ s₂ : Server C} (a : Advances s₀ s₁) (b : Advances s₁ s₂) :
    Advances s₀ s₂ := by
  refine ⟨Nat.le_trans a.mono b.mono, fun h => b.wf (a.wf h), ?_, ?_⟩
  · intro id row' h2
    rcases b.rows id row' h2 with h1 | hnew
    · exact a.rows id row' h1
    · exact Or.inr (Nat.lt_of_le_of_lt a.mono hnew)
  · intro id row h0
    obtain ⟨row1, h1⟩ := a.keep id row h0
    exact b.keep id row1 h1

omit [DecidableEq C] in
theorem advances_setRow (s : Server C) (id : Id) (row : Row C) (k : Seq)
    (hk : s.counter < k) (hseq : row.seq = k) : Advances s (s.setRow id row k) := by
  refine ⟨Nat.le_of_lt hk, ?_, ?_, ?_⟩
  · intro hwf i row' hrow'
    simp only [Server.setRow] at hrow' ⊢
    by_cases hi : i = id
    · rw [if_pos hi] at hrow'
      cases hrow'
      exact Nat.le_of_eq hseq
    · rw [if_neg hi] at hrow'
      exact Nat.le_trans (hwf i row' hrow') (Nat.le_of_lt hk)
  · intro i row' hrow'
    simp only [Server.setRow] at hrow'
    by_cases hi : i = id
    · rw [if_pos hi] at hrow'
      cases hrow'
      exact Or.inr (by rw [hseq]; exact hk)
    · rw [if_neg hi] at hrow'
      exact Or.inl hrow'
  · intro i row0 hrow0
    simp only [Server.setRow]
    by_cases hi : i = id
    · exact ⟨row, by rw [if_pos hi]⟩
    · exact ⟨row0, by rw [if_neg hi]; exact hrow0⟩

omit [DecidableEq C] in
theorem advances_counter (s : Server C) : Advances s { s with counter := s.next } :=
  ⟨Nat.le_succ _, fun hwf i row' h => Nat.le_trans (hwf i row' h) (Nat.le_succ _),
    fun _ _ h => Or.inl h, fun _ row h => ⟨row, h⟩⟩

omit [DecidableEq C] in
theorem next_gt (s : Server C) : s.counter < s.next := Nat.lt_succ_self _
omit [DecidableEq C] in
theorem next1_gt (s : Server C) : s.counter < s.next + 1 :=
  Nat.lt_trans (Nat.lt_succ_self _) (Nat.lt_succ_self _)

/-- Every client write shape — a peer's or our own — advances the server. -/
theorem step_advances (s : Server C) (op : Server.ClientOp C) : Advances s (s.step op) := by
  cases op with
  | patch id base c =>
    simp only [Server.step, Server.patch]
    split
    · exact advances_refl s
    · split
      · exact advances_refl s
      · split
        · exact advances_refl s
        · exact advances_setRow s id _ _ (next_gt s) rfl
  | insertIgnore id c =>
    simp only [Server.step, Server.insertIgnore]
    split
    · exact advances_counter s
    · exact advances_setRow s id _ _ (next_gt s) rfl
  | tombstone id =>
    simp only [Server.step, Server.tombstone]
    split
    · exact advances_refl s
    · split
      · exact advances_refl s
      · exact advances_setRow s id _ _ (next_gt s) rfl
  | legacyUpsert id c =>
    simp only [Server.step, Server.legacyUpsert]
    split
    · exact advances_setRow s id _ _ (next_gt s) rfl
    · split
      · exact advances_counter s
      · exact advances_setRow s id _ _ (next1_gt s) rfl

/-- A peer's write of any shape keeps the invariant. -/
theorem inv_step {s : Server C} {r : Replica C} (h : Inv s r) (op : Server.ClientOp C) :
    Inv (s.step op) r := inv_of_advances h (step_advances s op)

omit [DecidableEq C] in
theorem inv_setBase_none {s : Server C} {r : Replica C} (h : Inv s r) (id : Id) :
    Inv s (r.setBase id none) := by
  refine ⟨h.wf, ?_, ?_, ?_, h.cursorBounded⟩
  · intro i hh S hb
    simp only [Replica.setBase] at hb
    by_cases hi : i = id
    · rw [if_pos hi] at hb; cases hb
    · rw [if_neg hi] at hb; exact h.bounded i hh S hb
  · intro i hh S row hb hrow hseq
    simp only [Replica.setBase] at hb
    by_cases hi : i = id
    · rw [if_pos hi] at hb; cases hb
    · rw [if_neg hi] at hb; exact h.noDead i hh S row hb hrow hseq
  · intro i hh S hb
    simp only [Replica.setBase] at hb
    by_cases hi : i = id
    · rw [if_pos hi] at hb; cases hb
    · rw [if_neg hi] at hb; exact h.anchored i hh S hb

theorem inv_pushDelete {s : Server C} {r : Replica C} (h : Inv s r) (id : Id) :
    Inv (pushDelete s r id).server (pushDelete s r id).replica := by
  unfold pushDelete
  split
  · exact inv_setBase_none (inv_step h (.tombstone id)) id
  · exact h

omit [DecidableEq C] in
/-- A write that landed a LIVE row at `s.next` makes `(hash c, s.next)` a
sound baseline. -/
theorem inv_after_write (hash : C → Hash) {s : Server C} {r : Replica C} (h : Inv s r)
    (id : Id) (c : C) (d : Bool) (hd : d = false) :
    Inv (s.setRow id { content := c, seq := s.next, deleted := d } s.next)
      (r.setBase id (some (hash c, s.next))) := by
  refine ⟨(advances_setRow s id _ _ (next_gt s) rfl).wf h.wf, ?_, ?_, ?_,
    Nat.le_trans h.cursorBounded (Nat.le_of_lt (next_gt s))⟩
  · intro i hh S hb
    simp only [Replica.setBase] at hb
    by_cases hi : i = id
    · rw [if_pos hi] at hb; cases hb; exact Nat.le_refl _
    · rw [if_neg hi] at hb
      exact Nat.le_trans (h.bounded i hh S hb) (Nat.le_of_lt (next_gt s))
  · intro i hh S row' hb hrow' hseq'
    simp only [Replica.setBase, Server.setRow] at hb hrow'
    by_cases hi : i = id
    · rw [if_pos hi] at hb hrow'
      cases hb; cases hrow'; exact hd
    · rw [if_neg hi] at hb hrow'
      exact h.noDead i hh S row' hb hrow' hseq'
  · intro i hh S hb
    simp only [Replica.setBase] at hb
    by_cases hi : i = id
    · rw [if_pos hi] at hb; cases hb
      exact ⟨{ content := c, seq := s.next, deleted := d }, by simp [Server.setRow, hi],
        Nat.le_refl _⟩
    · rw [if_neg hi] at hb
      obtain ⟨row, hrow, hle⟩ := h.anchored i hh S hb
      exact ⟨row, by simp [Server.setRow, hi, hrow], hle⟩

/-- Our own push keeps the invariant: a `[row]` PATCH matched a seq the
baseline held, which the invariant says was live, so the written row is
live and the dead-row branch is unreachable; a `[row]` POST created a
live row; `[]` changed nothing but a burned counter. -/
theorem inv_pushRow (hash : C → Hash) {s : Server C} {r : Replica C} (h : Inv s r) (id : Id) :
    Inv (pushRow hash s r id).server (pushRow hash s r id).replica := by
  rcases pushRow_cases hash s r id with ⟨-, hp⟩
    | ⟨c, row, bh, bseq, -, hbase, hrow, hseq, hd, hp⟩
    | ⟨c, row, bh, bseq, -, hbase, hrow, hseq, hd, hp⟩
    | ⟨c, bh, bseq, -, -, -, hp⟩ | ⟨c, -, -, -, hp⟩ | ⟨c, -, -, hp⟩ <;> rw [hp]
  · exact h
  · exact inv_after_write hash h id c row.deleted hd
  · exfalso
    have := h.noDead id bh bseq row hbase hrow hseq
    rw [hd] at this; cases this
  · exact h
  · exact inv_after_write hash h id c false rfl
  · exact inv_of_advances h (advances_counter s)

omit [DecidableEq C] in
/-- Applying a row of a snapshot of `s₀`, against a server `s` that
advances from `s₀`, keeps the invariant: a live row that is not skipped
writes `(_, seq)` for a row that is still the server's (or has been
superseded by one above `s₀`'s counter), the tombstone row removes the
entry, the skip row keeps an entry the invariant already vouched for. -/
theorem inv_applyRow_snapshot (hash : C → Hash) {s₀ s : Server C} {r : Replica C}
    (hwf₀ : s₀.WF) (a : Advances s₀ s) (h : Inv s r)
    (fr : FeedRow C) (hsound : s₀.rows fr.id = some ⟨fr.content, fr.seq, fr.deleted⟩) :
    Inv s (applyRow hash r fr) := by
  cases hs : staleOrSeen (r.base fr.id) fr.seq
  · have hle : fr.seq ≤ s₀.counter := hwf₀ fr.id _ hsound
    refine ⟨h.wf, ?_, ?_, ?_, h.cursorBounded⟩
    · intro i hh S hb
      by_cases hi : i = fr.id
      · subst hi
        rw [applyRow_base_self] at hb
        rcases decideRow_base_seq_noskip fr.deleted (hash fr.content) ((r.loc fr.id).map hash)
            (r.base fr.id) fr.seq hs with hn | ⟨x, hx⟩
        · rw [hn] at hb; cases hb
        · rw [hx] at hb; cases hb
          exact Nat.le_trans hle a.mono
      · rw [(applyRow_frame hash r fr i hi).2] at hb
        exact h.bounded i hh S hb
    · intro i hh S row hb hrow hseq
      by_cases hi : i = fr.id
      · subst hi
        rw [applyRow_base_self] at hb
        cases hd : fr.deleted
        · rcases decideRow_base_seq_noskip fr.deleted (hash fr.content) ((r.loc fr.id).map hash)
              (r.base fr.id) fr.seq hs with hn | ⟨x, hx⟩
          · rw [hn] at hb; cases hb
          · rw [hx] at hb; cases hb
            rcases a.rows fr.id row hrow with hold | hnew
            · rw [hsound] at hold; cases hold; exact hd
            · rw [hseq] at hnew
              exact absurd (Nat.lt_of_lt_of_le hnew hle) (Nat.lt_irrefl _)
        · rw [hd, decideRow_tomb _ _ _ _ hs] at hb; cases hb
      · rw [(applyRow_frame hash r fr i hi).2] at hb
        exact h.noDead i hh S row hb hrow hseq
    · intro i hh S hb
      by_cases hi : i = fr.id
      · subst hi
        rw [applyRow_base_self] at hb
        rcases decideRow_base_seq_noskip fr.deleted (hash fr.content) ((r.loc fr.id).map hash)
            (r.base fr.id) fr.seq hs with hn | ⟨x, hx⟩
        · rw [hn] at hb; cases hb
        · rw [hx] at hb; cases hb
          obtain ⟨row', hrow'⟩ := a.keep fr.id _ hsound
          refine ⟨row', hrow', ?_⟩
          rcases a.rows fr.id row' hrow' with hold | hnew
          · rw [hsound] at hold; cases hold; exact Nat.le_refl _
          · exact Nat.le_of_lt (Nat.lt_of_le_of_lt hle hnew)
      · rw [(applyRow_frame hash r fr i hi).2] at hb
        exact h.anchored i hh S hb
  · rw [applyRow_skip hash r fr hs]
    exact h

omit [DecidableEq C] in
/-- Applying a row that IS the server's current row for its id keeps the
invariant. -/
theorem inv_applyRow (hash : C → Hash) {s : Server C} {r : Replica C} (h : Inv s r)
    (fr : FeedRow C) (hsound : s.rows fr.id = some ⟨fr.content, fr.seq, fr.deleted⟩) :
    Inv s (applyRow hash r fr) :=
  inv_applyRow_snapshot hash h.wf (advances_refl s) h fr hsound

omit [DecidableEq C] in
theorem inv_foldl_snapshot (hash : C → Hash) {s₀ s : Server C} {r : Replica C}
    (hwf₀ : s₀.WF) (a : Advances s₀ s) (h : Inv s r)
    (rows : List (FeedRow C))
    (hsound : ∀ fr ∈ rows, s₀.rows fr.id = some ⟨fr.content, fr.seq, fr.deleted⟩) :
    Inv s (rows.foldl (applyRow hash) r) := by
  induction rows generalizing r with
  | nil => exact h
  | cons fr rest ih =>
    simp only [List.foldl]
    exact ih (inv_applyRow_snapshot hash hwf₀ a h fr (hsound fr (by simp)))
      (fun x hx => hsound x (by simp [hx]))

omit [DecidableEq C] in
/-- The cursor after a pull of a snapshot page of `s₀` stays within
`s₀`'s counter. -/
theorem pull_cursor_le (hash : C → Hash) {s₀ : Server C} {r : Replica C}
    (hwf : s₀.WF) (hc : r.cursor ≤ s₀.counter) (page : List (FeedRow C))
    (hfeed : IsHeadFeed s₀ r.cursor page) :
    (pull hash r page).cursor ≤ s₀.counter := by
  show (page.filter fun fr => decide (r.cursor < fr.seq)).foldl
    (fun m fr => max m fr.seq) r.cursor ≤ s₀.counter
  apply foldl_max_le _ _ _ hc
  intro fr hfr
  exact hwf fr.id _ (hfeed.sound fr (List.mem_filter.mp hfr).1).1

omit [DecidableEq C] in
/-- THEOREM (the invariant survives a pull, stale pages included): a page
that is a snapshot of some state `s₀` the current server `s` advances
from — the page in flight before our own push, applied after it — keeps
the invariant against `s`. The cursor lands within `s₀`'s counter, hence
within `s`'s. -/
theorem inv_pull_snapshot (hash : C → Hash) {s₀ s : Server C} {r : Replica C}
    (hwf₀ : s₀.WF) (hc : r.cursor ≤ s₀.counter) (page : List (FeedRow C))
    (hfeed : IsHeadFeed s₀ r.cursor page) (a : Advances s₀ s) (h : Inv s r) :
    Inv s (pull hash r page) := by
  have hf := inv_foldl_snapshot hash hwf₀ a h (page.filter fun fr => decide (r.cursor < fr.seq))
    (fun fr hfr => (hfeed.sound fr (List.mem_filter.mp hfr).1).1)
  refine ⟨hf.wf, hf.bounded, hf.noDead, hf.anchored, ?_⟩
  exact Nat.le_trans (pull_cursor_le hash hwf₀ hc page hfeed) a.mono

omit [DecidableEq C] in
/-- A pull of a head page of the current server keeps the invariant. -/
theorem inv_pull (hash : C → Hash) {s : Server C} {r : Replica C} (h : Inv s r)
    (page : List (FeedRow C)) (hfeed : IsHeadFeed s r.cursor page) :
    Inv s (pull hash r page) :=
  inv_pull_snapshot hash h.wf h.cursorBounded page hfeed (advances_refl s) h

omit [DecidableEq C] in
/-- A pull of a limit-cut page of the current server keeps the invariant. -/
theorem inv_pull_page (hash : C → Hash) {s : Server C} {r : Replica C} (h : Inv s r)
    (bound : Seq) (page : List (FeedRow C)) (hfeed : IsPageFeed s r.cursor bound page) :
    Inv s (pull hash r page) := by
  have hf := inv_foldl_snapshot hash h.wf (advances_refl s) h
    (page.filter fun fr => decide (r.cursor < fr.seq))
    (fun fr hfr => (hfeed.sound fr (List.mem_filter.mp hfr).1).1)
  refine ⟨hf.wf, hf.bounded, hf.noDead, hf.anchored, ?_⟩
  show (page.filter fun fr => decide (r.cursor < fr.seq)).foldl
    (fun m fr => max m fr.seq) r.cursor ≤ s.counter
  apply foldl_max_le _ _ _ h.cursorBounded
  intro fr hfr
  exact h.wf fr.id _ (hfeed.sound fr (List.mem_filter.mp hfr).1).1

omit [DecidableEq C] in
/-- A fresh replica (no baseline, cursor not ahead of the server) against
any well-formed server. -/
theorem inv_initial (s : Server C) (r : Replica C) (hwf : s.WF)
    (hb : ∀ i, r.base i = none) (hc : r.cursor ≤ s.counter) : Inv s r := by
  refine ⟨hwf, ?_, ?_, ?_, hc⟩
  · intro i hh S h; rw [hb i] at h; cases h
  · intro i hh S row h; rw [hb i] at h; cases h
  · intro i hh S h; rw [hb i] at h; cases h

/-- Under the invariant, a push that came back `[row]` was against a live
row: the PATCH matched the baseline seq, which names a live row; the
POST path needs nothing. -/
theorem hlive_of_inv (hash : C → Hash) {s : Server C} {r : Replica C} (h : Inv s r)
    (id : Id) (c : C) (hloc : r.loc id = some c)
    (hdirty : (r.base id).map Prod.fst ≠ some (hash c))
    (s' : Server C) (r' : Replica C)
    (hpush : pushRow hash s r id = ⟨s', r', false, none⟩) :
    ∀ row, s.rows id = some row → row.deleted = false := by
  intro row hrow
  rcases pushRow_cases hash s r id with ⟨hreason, -⟩
    | ⟨c₀, row₀, bh, bseq, -, hb, hrow₀, hseq, hd, -⟩
    | ⟨c₀, row₀, bh, bseq, -, hb, hrow₀, hseq, hd, -⟩
    | ⟨c₀, bh, bseq, -, -, -, hp⟩ | ⟨c₀, -, -, hnone, -⟩ | ⟨c₀, -, -, hp⟩
  · exfalso
    rcases hreason with hn | ⟨c₁, hl, hcl⟩
    · rw [hloc] at hn; cases hn
    · rw [hloc] at hl; cases hl; exact hdirty hcl
  · rw [hrow] at hrow₀; cases hrow₀; exact hd
  · exfalso
    have := h.noDead id bh bseq row₀ hb hrow₀ hseq
    rw [hd] at this; cases this
  · rw [hp] at hpush; simp at hpush
  · rw [hnone] at hrow; cases hrow
  · rw [hp] at hpush; simp at hpush

/-- THEOREM T3 on reachable states: `push_then_echo` with the live-row
hypothesis replaced by the invariant. -/
theorem push_then_echo_reachable (hash : C → Hash) (s : Server C) (r : Replica C)
    (hinv : Inv s r) (id : Id) (c : C)
    (hloc : r.loc id = some c)
    (hdirty : (r.base id).map Prod.fst ≠ some (hash c))
    (s' : Server C) (r' : Replica C)
    (hpush : pushRow hash s r id = ⟨s', r', false, none⟩) :
    ∃ seq', s'.rows id = some ⟨c, seq', false⟩
      ∧ r'.base id = some (hash c, seq')
      ∧ r'.loc = r.loc
      ∧ (applyRow hash r' ⟨id, seq', c, false⟩).loc = r'.loc
      ∧ (applyRow hash r' ⟨id, seq', c, false⟩).shelf = r'.shelf :=
  push_then_echo hash s r id c hloc hdirty
    (hlive_of_inv hash hinv id c hloc hdirty s' r' hpush) s' r' hpush

/-- The server with one tombstoned row (content kept) at the seq a replica
below holds as a live baseline. -/
def tombstonedServer : Server Nat := oneServer (some ⟨10, 1, true⟩) 1

/-- DEAD-ROW HIT WITNESS (the §6 third response, handled): the server row
is a TOMBSTONE whose seq equals the base, so the conditional PATCH is
accepted — I6 keeps `deleted_at`, the content changes, a seq is minted,
`[row]` comes back with `deleted_at` set. The upload rule's first line
in the `[row]` branch sees it: the dirty local version is shelved, the
local row removed, the baseline entry removed, no `(hash, seq)` written
— the same disposition as an incoming tombstone. (An earlier revision
of this file lacked the check; its witness showed the baseline written
`(hash sent, seq)` and the tombstone echo then absorbed by the skip row:
a clean ghost of a dead server row, never pushed or pulled again — the
§9.31 consequence.) The state is OUTSIDE the invariant
(`witness_outside_inv`): no operation of the model produces a dead row
at a seq a replica holds as a live baseline, because the flip minted a
fresh one; on the design's own path the PATCH is refused by I8
(`tombstone_then_push_is_refused_witness`). The check is the cheap
guard the design calls it. -/
theorem dead_row_hit_is_tombstoned_witness :
    (pushRow id tombstonedServer (oneRow (some 20) (some (10, 1))) 1).needsPull
        = false
      ∧ (pushRow id tombstonedServer (oneRow (some 20) (some (10, 1))) 1).server.rows 1
        = some ⟨20, 2, true⟩
      ∧ (pushRow id tombstonedServer (oneRow (some 20) (some (10, 1))) 1).replica.loc 1
        = none
      ∧ (pushRow id tombstonedServer (oneRow (some 20) (some (10, 1))) 1).replica.base 1
        = none
      ∧ (pushRow id tombstonedServer (oneRow (some 20) (some (10, 1))) 1).replica.shelf
        = [(1, 20)] := by
  refine ⟨?_, ?_, ?_, ?_, ?_⟩ <;> decide

/-- The countermodel's state violates the invariant: its baseline seq
names a dead row. -/
theorem witness_outside_inv :
    ¬ Inv tombstonedServer (oneRow (some 20) (some (10, 1))) := by
  intro h
  have := h.noDead 1 10 1 ⟨10, 1, true⟩ (by decide) (by decide) rfl
  cases this

/-- The same edit on the design's own path: the row is tombstoned from a
live state (fresh seq), the PATCH against the old seq is refused by I8,
the pull applies the tombstone, the dirty local version is shelved (I7). -/
theorem tombstone_then_push_is_refused_witness :
    ((oneServer (some ⟨10, 1, false⟩) 1).tombstone 1).1.rows 1 = some ⟨10, 2, true⟩
      ∧ (pushRow id ((oneServer (some ⟨10, 1, false⟩) 1).tombstone 1).1
          (oneRow (some 20) (some (10, 1))) 1).needsPull = true
      ∧ (pull id (oneRow (some 20) (some (10, 1))) [⟨1, 2, 10, true⟩]).loc 1 = none
      ∧ (pull id (oneRow (some 20) (some (10, 1))) [⟨1, 2, 10, true⟩]).shelf = [(1, 20)] := by
  refine ⟨?_, ?_, ?_, ?_⟩ <;> decide

end Reachability

/-! ## `BaseTracksFeed` is an invariant — under snapshot pages, stale ones included

The pending-verify rule's inference "unseen ⇒ the server minted no seq"
needs the baseline to track the feed below the cursor. That is not
something the §6 table has to maintain against arbitrary lists: it is
preserved by every operation of the model as long as each page is a
snapshot of SOME server state the current one advances from (I5 plus
`sync_changes` being one `stable` statement). A page fetched before our
own push and applied after it is such a snapshot — under `≤` its stale
row is skipped, and anchoring says the entry it keeps still names the
server's seq for the id. -/

section Tracking
variable [DecidableEq C]

omit [DecidableEq C] in
theorem baseTracksFeed_advances {s s' : Server C} {r : Replica C}
    (ht : BaseTracksFeed s r) (hc : r.cursor ≤ s.counter) (a : Advances s s') :
    BaseTracksFeed s' r := by
  intro id h S row hb hrow hle
  rcases a.rows id row hrow with hold | hnew
  · exact ht id h S row hb hold hle
  · exact absurd (Nat.lt_of_lt_of_le hnew (Nat.le_trans hle hc)) (Nat.lt_irrefl _)

theorem baseTracksFeed_step {s : Server C} {r : Replica C} (h : Inv s r)
    (ht : BaseTracksFeed s r) (op : Server.ClientOp C) :
    BaseTracksFeed (s.step op) r :=
  baseTracksFeed_advances ht h.cursorBounded (step_advances s op)

omit [DecidableEq C] in
theorem baseTracksFeed_after_write (hash : C → Hash) {s : Server C} {r : Replica C}
    (h : Inv s r) (ht : BaseTracksFeed s r) (id : Id) (c : C) (d : Bool) :
    BaseTracksFeed (s.setRow id { content := c, seq := s.next, deleted := d } s.next)
      (r.setBase id (some (hash c, s.next))) := by
  intro i hh S row hb hrow hle
  simp only [Replica.setBase, Server.setRow] at hb hrow hle
  by_cases hi : i = id
  · rw [if_pos hi] at hrow
    cases hrow
    exact absurd (Nat.lt_of_lt_of_le (next_gt s) (Nat.le_trans hle h.cursorBounded))
      (Nat.lt_irrefl _)
  · rw [if_neg hi] at hb hrow
    exact ht i hh S row hb hrow hle

theorem baseTracksFeed_pushRow (hash : C → Hash) {s : Server C} {r : Replica C}
    (h : Inv s r) (ht : BaseTracksFeed s r) (id : Id) :
    BaseTracksFeed (pushRow hash s r id).server (pushRow hash s r id).replica := by
  rcases pushRow_cases hash s r id with ⟨-, hp⟩
    | ⟨c, row, bh, bseq, -, -, -, -, -, hp⟩
    | ⟨c, row, bh, bseq, -, hbase, hrow, hseq, hd, hp⟩
    | ⟨c, bh, bseq, -, -, -, hp⟩ | ⟨c, -, -, -, hp⟩ | ⟨c, -, -, hp⟩ <;> rw [hp]
  · exact ht
  · exact baseTracksFeed_after_write hash h ht id c row.deleted
  · exfalso
    have := h.noDead id bh bseq row hbase hrow hseq
    rw [hd] at this; cases this
  · exact ht
  · exact baseTracksFeed_after_write hash h ht id c false
  · exact baseTracksFeed_advances ht h.cursorBounded (advances_counter s)

theorem baseTracksFeed_pushDelete {s : Server C} {r : Replica C}
    (h : Inv s r) (ht : BaseTracksFeed s r) (id : Id) :
    BaseTracksFeed (pushDelete s r id).server (pushDelete s r id).replica := by
  unfold pushDelete
  split
  · intro i hh S row hb hrow hle
    simp only [Replica.setBase] at hb
    by_cases hi : i = id
    · rw [if_pos hi] at hb; cases hb
    · rw [if_neg hi] at hb
      exact baseTracksFeed_advances ht h.cursorBounded (step_advances s (.tombstone id))
        i hh S row hb hrow hle
  · exact ht

omit [DecidableEq C] in
/-- THEOREM (tracking survives a pull, stale pages included): a page that
is a snapshot of some state `s₀` the current server `s` advances from,
applied to a replica whose baseline tracks `s` and is anchored on it,
leaves a baseline that tracks `s`. Page ids land on `(_, seq)`, are
removed, or (skipped) keep an entry that anchoring pins to the row's
seq; ids not in the page are below the OLD cursor or new on the server,
above the new one. -/
theorem baseTracksFeed_pull (hash : C → Hash) {s₀ s : Server C} {r : Replica C}
    (hwf : s₀.WF) (hc : r.cursor ≤ s₀.counter) (page : List (FeedRow C))
    (hfeed : IsHeadFeed s₀ r.cursor page) (a : Advances s₀ s)
    (hinv : Inv s r) (ht : BaseTracksFeed s r) :
    BaseTracksFeed s (pull hash r page) := by
  have hfilter : page.filter (fun fr => decide (r.cursor < fr.seq)) = page :=
    List.filter_eq_self.mpr fun fr hfr => by simp [(hfeed.sound fr hfr).2]
  have hcur := pull_cursor_le hash hwf hc page hfeed
  have hbase : (pull hash r page).base
      = ((page.filter fun fr => decide (r.cursor < fr.seq)).foldl (applyRow hash) r).base := rfl
  rw [hfilter] at hbase
  intro i hh S row hb hrow hle
  rw [hbase] at hb
  rcases a.rows i row hrow with hold | hnew
  · by_cases hin : ∃ fr ∈ page, fr.id = i
    · obtain ⟨fr, hfr, hid⟩ := hin
      subst hid
      rw [(foldl_self_of_mem hash page r fr hfeed.distinct hfr).2] at hb
      have hsnd := (hfeed.sound fr hfr).1
      rw [hsnd] at hold
      cases hold
      cases hs : staleOrSeen (r.base fr.id) fr.seq
      · rw [applyRow_base_self] at hb
        rcases decideRow_base_seq_noskip fr.deleted (hash fr.content) ((r.loc fr.id).map hash)
            (r.base fr.id) fr.seq hs with hn | ⟨x, hx⟩
        · rw [hn] at hb; cases hb
        · rw [hx] at hb; cases hb
          rfl
      · rw [applyRow_skip hash r fr hs] at hb
        obtain ⟨h', S', hb', hle'⟩ := (staleOrSeen_true_iff _ _).mp hs
        rw [hb] at hb'
        cases hb'
        obtain ⟨row', hrow', hSle⟩ := hinv.anchored fr.id hh S hb
        rw [hrow] at hrow'
        cases hrow'
        exact Nat.le_antisymm hle' hSle
    · have hin' : ∀ fr ∈ page, fr.id ≠ i := fun fr hfr hid => hin ⟨fr, hfr, hid⟩
      rw [(foldl_frame hash page r i hin').2] at hb
      rcases Nat.lt_or_ge r.cursor row.seq with hlt | hge
      · obtain ⟨fr, hfr, hfrid⟩ := hfeed.complete i row hold hlt
        exact absurd hfrid (hin' fr hfr)
      · exact ht i hh S row hb hrow hge
  · exact absurd (Nat.lt_of_lt_of_le hnew (Nat.le_trans hle hcur)) (Nat.lt_irrefl _)

omit [DecidableEq C] in
/-- Tracking holds for a fresh replica. -/
theorem baseTracksFeed_initial (s : Server C) (r : Replica C) (hb : ∀ i, r.base i = none) :
    BaseTracksFeed s r := by
  intro i hh S row h; rw [hb i] at h; cases h

end Tracking

/-! ## Row 1: `≤` against `==` — the stale page (Scenario A)

34a7810's first row skips a row whose seq EQUALS the baseline seq. A
page fetched BEFORE the replica's own push and applied AFTER it (the pull
is `await rpc` then apply; a PATCH response lands in between on the same
actor) carries a row strictly OLDER than the baseline seq. The equality
row lets it through and the table reads it as a clean adopt: the replica
regresses — content AND baseline seq go backwards — until the next pull;
if the user edits in that window, the next pull files our OWN previous
version as a conflict entry and the edit lands one PATCH later
(`scenarioA_recovers_witness`). Nothing is lost and nothing diverges —
the page was a snapshot of an earlier server state, and such pages keep
`Inv` and `BaseTracksFeed` under either row. The round-eight `≤` row
(the model's `decideRow`) makes the stale row a no-op; the two rows
differ on nothing else (`decideRowEq_eq_decideRow`). -/

section StalePage

/-- The effect and the pull under the `==` row. -/
def applyRowEq (hash : C → Hash) : Replica C → FeedRow C → Replica C :=
  applyRowWith decideRowEq hash

def pullEq (hash : C → Hash) (r : Replica C) (page : List (FeedRow C)) : Replica C :=
  let rows := page.filter fun fr => decide (r.cursor < fr.seq)
  let r' := rows.foldl (applyRowEq hash) r
  { r' with cursor := rows.foldl (fun m fr => max m fr.seq) r.cursor }

/-- The server when the stale page was fetched: id 1 at v1, seq 5. -/
def scenarioAServerBefore : Server Nat := oneServer (some ⟨1, 5, false⟩) 5

/-- The replica right after its own successful push of v2: local v2,
baseline `(2, 6)`, cursor still at 4 because the page in flight was
fetched before the push. -/
def afterPushReplica : Replica Nat := oneRowAt (some 2) (some (2, 6)) 4

/-- The page in flight: the head page of `scenarioAServerBefore` from
cursor 4. -/
def stalePage : List (FeedRow Nat) := [⟨1, 5, 1, false⟩]

theorem stalePage_head : IsHeadFeed scenarioAServerBefore 4 stalePage := by
  refine ⟨?_, ?_, ?_⟩
  · intro fr hfr
    simp [stalePage] at hfr
    subst hfr
    simp [scenarioAServerBefore, oneServer]
  · intro i row hrow hlt
    by_cases hi : i = 1
    · subst hi; exact ⟨⟨1, 5, 1, false⟩, by simp [stalePage], rfl⟩
    · simp [scenarioAServerBefore, oneServer, hi] at hrow
  · decide

/-- SCENARIO A WITNESS (stale feed row regresses the replica under `==`):
the page row `⟨1, 5, v1⟩` — strictly older than the baseline seq 6 — is
not skipped by the `==` row and the table adopts it (local hash = base
hash = 2, incoming 1: "clean, take remote"): local v2 is replaced by v1
and the baseline seq moves back to 5, nothing shelved (T4 is satisfied
vacuously: v2 was clean). Under `≤` the row is a no-op: local and
baseline stay, only the cursor advances. -/
theorem stale_feed_row_regresses_witness :
    (pullEq id afterPushReplica stalePage).loc 1 = some 1
      ∧ (pullEq id afterPushReplica stalePage).base 1 = some (1, 5)
      ∧ (pullEq id afterPushReplica stalePage).shelf = []
      ∧ (pull id afterPushReplica stalePage).loc 1 = some 2
      ∧ (pull id afterPushReplica stalePage).base 1 = some (2, 6)
      ∧ (pull id afterPushReplica stalePage).cursor = 5 := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩ <;> decide

/-- The `==` row also applies a conflict row once on re-apply (it is the
skip row that does it, in either form). -/
theorem eq_conflict_reapply_witness :
    (applyRowEq id (applyRowEq id (oneRow (some 2) (some (3, 1)))
        ⟨1, 5, 4, false⟩) ⟨1, 5, 4, false⟩).shelf = [(1, 4)] := by
  decide

end StalePage


/-! ## The `[]` closure — pending-verify (design §6 upload shape)

A conditional PATCH answers `[]` for reasons the client cannot tell
apart: stale (I8) or content-identical (the 015 short-circuit). The v1.3
text said "pull, then re-diff". That does not recover from the second
cause: the server minted no seq, the feed returns nothing for the id, the
baseline hash stays foreign, and the row is re-PATCHed every flush —
`identical_patch_pull_livelock_witness`. The v1.4 rule, as modelled
here: the `[]` creates a `Pending` entry `(id, sentSeq, sentHash)`; after
the next head pull, an entry the pull SAW is dropped (the row went
through the table); an entry it did not see is checked against the
baseline — `base.seq == sentSeq` → the baseline hash becomes `sentHash`
(the server holds the sent bytes at that seq, T9b); otherwise the entry
is dropped with the hash untouched (a pull moved the baseline while the
PATCH was in flight: the `[]` was staleness, not identity). The rule the
design refutes (review five: any unseen entry rewrites the hash from the
LIVE local row) is `pullVerifyNaive`, kept for the two witnesses.
`pullVerify` by itself runs the pass after ANY page; the rule is the pass
after an ELIGIBLE pull that reached head. In `Reachable` that is
`verify`: a head page of the current server, so the pull was issued
after every `[]` it clears — the sequential form of `pullIssue`.
T9a/T9b carry `IsHeadFeed`; `ineligible_verify_loses_witness` is the
loss an ineligible pass lets through. -/

section PendingVerify
variable [DecidableEq C] (hash : C → Hash)

/-- The verify step for one unseen entry: eligible iff the baseline seq is
still the sent seq; then the hash becomes the SENT hash. -/
def Replica.verifyUnseen (r : Replica C) (p : Pending) : Replica C :=
  match r.base p.id with
  | some (_, S) => if S = p.sentSeq then r.setBase p.id (some (p.sentHash, S)) else r
  | none => r

omit [DecidableEq C] in
/-- Ids a page actually applied — those past the cursor. -/
def seenIds (r : Replica C) (page : List (FeedRow C)) : List Id :=
  (page.filter fun fr => decide (r.cursor < fr.seq)).map (·.id)

/-- One pull followed by the pending-verify pass over the entries whose
PATCH answered `[]`. -/
def pullVerify (r : Replica C) (page : List (FeedRow C)) (pending : List Pending) :
    Replica C :=
  (pending.filter fun p => decide (p.id ∉ seenIds r page)).foldl
    Replica.verifyUnseen (pull hash r page)

/-- The review-five rule the design refutes: an unseen id's baseline hash
is recomputed from the live local row, with no seq check. -/
def Replica.verifyUnseenNaive (r : Replica C) (id : Id) : Replica C :=
  match r.loc id, r.base id with
  | some c, some (_, S) => r.setBase id (some (hash c, S))
  | _, _ => r

def pullVerifyNaive (r : Replica C) (page : List (FeedRow C)) (pending : List Id) :
    Replica C :=
  (pending.filter fun i => decide (i ∉ seenIds r page)).foldl
    (Replica.verifyUnseenNaive hash) (pull hash r page)

omit [DecidableEq C] in
theorem verifyUnseen_loc (r : Replica C) (p : Pending) :
    (r.verifyUnseen p).loc = r.loc := by
  unfold Replica.verifyUnseen
  split
  · split
    · rfl
    · rfl
  · rfl

omit [DecidableEq C] in
theorem verifyUnseen_cursor (r : Replica C) (p : Pending) :
    (r.verifyUnseen p).cursor = r.cursor := by
  unfold Replica.verifyUnseen
  split
  · split
    · rfl
    · rfl
  · rfl

omit [DecidableEq C] in
theorem verifyUnseen_shelf (r : Replica C) (p : Pending) :
    (r.verifyUnseen p).shelf = r.shelf := by
  unfold Replica.verifyUnseen
  split
  · split
    · rfl
    · rfl
  · rfl

omit [DecidableEq C] in
theorem verifyUnseen_frame (r : Replica C) (p : Pending) (i : Id) (h : i ≠ p.id) :
    (r.verifyUnseen p).base i = r.base i := by
  unfold Replica.verifyUnseen
  split
  · split
    · simp [Replica.setBase, h]
    · rfl
  · rfl

omit [DecidableEq C] in
/-- The verify step never moves a baseline seq, at any id. -/
theorem verifyUnseen_base_seq (r : Replica C) (p : Pending) (i : Id) :
    ((r.verifyUnseen p).base i).map Prod.snd = (r.base i).map Prod.snd := by
  by_cases hi : i = p.id
  · subst hi
    unfold Replica.verifyUnseen
    split
    · rename_i h S hb
      split
      · simp [Replica.setBase, hb]
      · rfl
    · rfl
  · rw [verifyUnseen_frame r p i hi]

omit [DecidableEq C] in
theorem verifyUnseen_eligible (r : Replica C) (p : Pending) (h : Hash)
    (hbase : r.base p.id = some (h, p.sentSeq)) :
    (r.verifyUnseen p).base p.id = some (p.sentHash, p.sentSeq) := by
  unfold Replica.verifyUnseen
  simp [hbase, Replica.setBase]

omit [DecidableEq C] in
theorem verifyUnseen_ineligible (r : Replica C) (p : Pending) (h : Hash) (S : Seq)
    (hbase : r.base p.id = some (h, S)) (hne : S ≠ p.sentSeq) :
    r.verifyUnseen p = r := by
  unfold Replica.verifyUnseen
  simp [hbase, hne]

omit [DecidableEq C] in
/-- Facts that depend on baseline seqs and the cursor only transfer across
a replica change that keeps both. -/
theorem inv_of_same_seqs {s : Server C} {r r' : Replica C} (h : Inv s r)
    (hb : ∀ i, (r'.base i).map Prod.snd = (r.base i).map Prod.snd)
    (hc : r'.cursor = r.cursor) : Inv s r' := by
  have hget : ∀ i h' S, r'.base i = some (h', S) → ∃ h, r.base i = some (h, S) := by
    intro i h' S hb'
    have := hb i
    rw [hb'] at this
    cases hr : r.base i with
    | none => rw [hr] at this; simp at this
    | some p =>
      obtain ⟨h, S'⟩ := p
      rw [hr] at this
      simp only [Option.map_some, Option.some.injEq] at this
      subst this
      exact ⟨h, rfl⟩
  refine ⟨h.wf, ?_, ?_, ?_, hc ▸ h.cursorBounded⟩
  · intro i h' S hb'
    obtain ⟨hh, hr⟩ := hget i h' S hb'
    exact h.bounded i hh S hr
  · intro i h' S row hb' hrow hseq
    obtain ⟨hh, hr⟩ := hget i h' S hb'
    exact h.noDead i hh S row hr hrow hseq
  · intro i h' S hb'
    obtain ⟨hh, hr⟩ := hget i h' S hb'
    exact h.anchored i hh S hr

omit [DecidableEq C] in
theorem baseTracksFeed_of_same_seqs {s : Server C} {r r' : Replica C}
    (ht : BaseTracksFeed s r)
    (hb : ∀ i, (r'.base i).map Prod.snd = (r.base i).map Prod.snd)
    (hc : r'.cursor = r.cursor) : BaseTracksFeed s r' := by
  intro i h' S row hb' hrow hle
  have := hb i
  rw [hb'] at this
  cases hr : r.base i with
  | none => rw [hr] at this; simp at this
  | some p =>
    obtain ⟨h, S'⟩ := p
    rw [hr] at this
    simp only [Option.map_some, Option.some.injEq] at this
    subst this
    exact ht i h S row hr hrow (hc ▸ hle)

omit [DecidableEq C] in
theorem foldl_verify_seqs (pending : List Pending) (r : Replica C) (i : Id) :
    ((pending.foldl Replica.verifyUnseen r).base i).map Prod.snd = (r.base i).map Prod.snd
      ∧ (pending.foldl Replica.verifyUnseen r).cursor = r.cursor := by
  induction pending generalizing r with
  | nil => exact ⟨rfl, rfl⟩
  | cons p rest ih =>
    simp only [List.foldl]
    obtain ⟨h1, h2⟩ := ih (r.verifyUnseen p)
    rw [h1, h2, verifyUnseen_base_seq, verifyUnseen_cursor]
    exact ⟨rfl, rfl⟩

omit [DecidableEq C] in
/-- The verify pass keeps the invariant and the tracking: it moves hashes,
never seqs. Stated for a snapshot page, like `inv_pull_snapshot`. -/
theorem inv_pullVerify {s₀ s : Server C} {r : Replica C}
    (hwf₀ : s₀.WF) (hc : r.cursor ≤ s₀.counter) (page : List (FeedRow C))
    (hfeed : IsHeadFeed s₀ r.cursor page) (a : Advances s₀ s) (h : Inv s r)
    (pending : List Pending) :
    Inv s (pullVerify hash r page pending) := by
  unfold pullVerify
  exact inv_of_same_seqs (inv_pull_snapshot hash hwf₀ hc page hfeed a h)
    (fun i => (foldl_verify_seqs _ _ i).1) (foldl_verify_seqs _ _ 0).2

omit [DecidableEq C] in
theorem baseTracksFeed_pullVerify {s₀ s : Server C} {r : Replica C}
    (hwf : s₀.WF) (hc : r.cursor ≤ s₀.counter) (page : List (FeedRow C))
    (hfeed : IsHeadFeed s₀ r.cursor page) (a : Advances s₀ s)
    (hinv : Inv s r) (ht : BaseTracksFeed s r) (pending : List Pending) :
    BaseTracksFeed s (pullVerify hash r page pending) := by
  unfold pullVerify
  exact baseTracksFeed_of_same_seqs (baseTracksFeed_pull hash hwf hc page hfeed a hinv ht)
    (fun i => (foldl_verify_seqs _ _ i).1) (foldl_verify_seqs _ _ 0).2

/-- The server holding exactly the bytes a replica has locally, at the
replica's baseline seq — the state after a build changed the hash
encoding without changing any server value. -/
def identicalServer : Server Nat := oneServer (some ⟨4, 5, false⟩) 5

/-- Local bytes 4, baseline hash 3 (foreign), baseline seq 5, cursor 5. -/
def staleHashReplica : Replica Nat := oneRowAt (some 4) (some (3, 5)) 5

/-- The empty page IS the head page from cursor 5 on `identicalServer`. -/
theorem identicalServer_head : IsHeadFeed identicalServer 5 [] := by
  refine ⟨by simp, ?_, List.Pairwise.nil⟩
  intro i row hrow hlt
  by_cases hi : i = 1
  · subst hi
    simp [identicalServer, oneServer] at hrow
    subst hrow
    simp at hlt
  · simp [identicalServer, oneServer, hi] at hrow

/-- SCENARIO F WITNESS (the v1.3 `[]` rule livelocks on the short-circuit):
the PATCH answers `[]` with nothing minted; the pull to head returns no
row for the id (its seq is not above the cursor); the replica is
unchanged; the next flush PATCHes again and gets `[]` again. "Pull first"
alone never reaches the three-way, because the feed never carries the row. -/
theorem identical_patch_pull_livelock_witness :
    (pushRow id identicalServer staleHashReplica 1).needsPull = true
      ∧ (pushRow id identicalServer staleHashReplica 1).pending = some ⟨1, 5, 4⟩
      ∧ (pushRow id identicalServer staleHashReplica 1).server.counter = 5
      ∧ (pull id staleHashReplica []).base 1 = some (3, 5)
      ∧ (pull id staleHashReplica []).loc 1 = some 4
      ∧ (pushRow id identicalServer (pull id staleHashReplica []) 1).needsPull = true := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩ <;> decide

/-- THEOREM T9a (pending-verify recovers the short-circuit): the server
holds the local bytes at the baseline seq, the baseline hash is foreign,
the PATCH answered `[]` and filed `(id, S, hash local)`, the pull to head
did not see the id. After the verify pass the baseline is
`(hash local, S)`, local bytes are untouched, the id is clean, and the
next flush sends nothing. -/
theorem pending_verify_recovers_identical (s : Server C) (r : Replica C) (id : Id)
    (c : C) (h : Hash) (S : Seq)
    (hloc : r.loc id = some c) (hbase : r.base id = some (h, S))
    (hdirty : h ≠ hash c) (hrow : s.rows id = some ⟨c, S, false⟩)
    (page : List (FeedRow C)) (hunseen : ∀ fr ∈ page, r.cursor < fr.seq → fr.id ≠ id) :
    pushRow hash s r id = ⟨s, r, true, some ⟨id, S, hash c⟩⟩
      ∧ (pullVerify hash r page [⟨id, S, hash c⟩]).loc id = some c
      ∧ (pullVerify hash r page [⟨id, S, hash c⟩]).base id = some (hash c, S)
      ∧ CleanAt hash (pullVerify hash r page [⟨id, S, hash c⟩]) id
      ∧ pushRow hash s (pullVerify hash r page [⟨id, S, hash c⟩]) id
          = ⟨s, pullVerify hash r page [⟨id, S, hash c⟩], false, none⟩ := by
  have hpatch : s.patch id S c = (s, none) := by
    unfold Server.patch; simp [hrow]
  have hpush : pushRow hash s r id = ⟨s, r, true, some ⟨id, S, hash c⟩⟩ := by
    unfold pushRow
    simp [hloc, hbase, hpatch, hdirty]
  have hframe : ∀ fr ∈ page.filter (fun fr => decide (r.cursor < fr.seq)), fr.id ≠ id := by
    intro fr hfr
    obtain ⟨hmem, hlt⟩ := List.mem_filter.mp hfr
    exact hunseen fr hmem (by simpa using hlt)
  have hnotseen : id ∉ seenIds r page := by
    unfold seenIds
    intro hmem
    obtain ⟨fr, hfr, hid⟩ := List.mem_map.mp hmem
    exact hframe fr hfr hid
  have hpending : [(⟨id, S, hash c⟩ : Pending)].filter
      (fun p => decide (p.id ∉ seenIds r page)) = [⟨id, S, hash c⟩] := by
    simp [hnotseen]
  have hpull : (pull hash r page).loc id = some c ∧ (pull hash r page).base id = some (h, S) := by
    simp only [pull]
    obtain ⟨h1, h2⟩ := foldl_frame hash _ r id hframe
    exact ⟨by rw [h1, hloc], by rw [h2, hbase]⟩
  have hv : (pullVerify hash r page [⟨id, S, hash c⟩]).loc id = some c
      ∧ (pullVerify hash r page [⟨id, S, hash c⟩]).base id = some (hash c, S) := by
    unfold pullVerify
    rw [hpending]
    simp only [List.foldl]
    refine ⟨by rw [verifyUnseen_loc]; exact hpull.1, ?_⟩
    exact verifyUnseen_eligible _ ⟨id, S, hash c⟩ h hpull.2
  refine ⟨hpush, hv.1, hv.2, ?_, ?_⟩
  · unfold CleanAt; rw [hv.1, hv.2]; rfl
  · unfold pushRow
    simp [hv.1, hv.2]

/-- THEOREM T9b (the design's justification, made explicit, with the
eligibility check as a hypothesis): the PATCH `seq=eq.S` with content `c`
went to server state `s₀` and answered `[]`; `S` was a baseline seq then
(so `S ≤ s₀.counter`); peers wrote meanwhile (`Advances s₀ s`); at verify
time the replica `r'` — any replica reachable from there, so `Inv` and
`BaseTracksFeed` hold — still holds `(_, S)` for the id (`base.seq ==
sentSeq`), and the head pull of `s` did not see the id. Then the server
HOLDS a row for the id (anchoring) and that row IS `⟨c, S, live⟩`:
unseen puts it at or below the cursor, tracking makes its seq `S`, the
invariant makes it live, `S ≤ s₀.counter` makes it a row `s₀` already
had, and `[]` on a row at the filter's seq means identical content. So
writing `(sentHash, S)` is writing the truth (`BaseHashSound` at that
id). The other branch — `base.seq ≠ sentSeq`, entry dropped, hash
untouched — is `verifyUnseen_ineligible` and
`verify_drops_when_base_moved_witness`. -/
theorem pending_unseen_means_identical (s₀ s : Server C) (r' : Replica C) (id : Id)
    (c : C) (h' : Hash) (S : Seq)
    (a : Advances s₀ s) (hS : S ≤ s₀.counter) (hempty : (s₀.patch id S c).2 = none)
    (hinv : Inv s r') (htrack : BaseTracksFeed s r')
    (hbase : r'.base id = some (h', S))
    (page : List (FeedRow C)) (hfeed : IsHeadFeed s r'.cursor page)
    (hunseen : ∀ fr ∈ page, fr.id ≠ id) :
    (∃ row, s.rows id = some row ∧ row = ⟨c, S, false⟩)
      ∧ (r'.verifyUnseen ⟨id, S, hash c⟩).base id = some (hash c, S) := by
  refine ⟨?_, verifyUnseen_eligible r' ⟨id, S, hash c⟩ h' hbase⟩
  obtain ⟨row, hrow, -⟩ := hinv.anchored id h' S hbase
  refine ⟨row, hrow, ?_⟩
  have hle : row.seq ≤ r'.cursor := by
    apply Nat.le_of_not_lt
    intro hgt
    obtain ⟨fr, hfr, hid⟩ := hfeed.complete id row hrow hgt
    exact hunseen fr hfr hid
  have hseq : row.seq = S := htrack id h' S row hbase hrow hle
  have hdead : row.deleted = false := hinv.noDead id h' S row hbase hrow hseq
  have hold : s₀.rows id = some row := by
    rcases a.rows id row hrow with hold | hnew
    · exact hold
    · rw [hseq] at hnew
      exact absurd (Nat.lt_of_lt_of_le hnew hS) (Nat.lt_irrefl _)
  rcases patch_empty_reasons s₀ id S c hempty with hnone | ⟨row', hrow', hr⟩
  · rw [hold] at hnone; cases hnone
  · rw [hold] at hrow'
    cases hrow'
    rcases hr with hne | hc
    · exact absurd hseq hne
    · obtain ⟨rc, rs, rd⟩ := row
      simp only at hc hseq hdead
      subst hc hseq hdead
      rfl

/-- Design interleaving (ii): the peer wrote X=c2 at seq 6. -/
def peerWroteServer : Server Nat := oneServer (some ⟨2, 6, false⟩) 6

/-- Local c1 over baseline `(h0, 5)`, cursor 5. -/
def localEditReplica : Replica Nat := oneRowAt (some 1) (some (0, 5)) 5

/-- The pull that applied X@6 as a conflict while the PATCH was in flight. -/
def afterPeerPull : Replica Nat := pull id localEditReplica [⟨1, 6, 2, false⟩]

/-- INTERLEAVING (ii) WITNESS (`base.seq ≠ sentSeq` → drop, hash
untouched): the flush built the PATCH for c1 with the old baseline seq;
before it reached the server a pull applied the peer's newer X as a
conflict (the baseline becomes the peer's row's `(hash, seq)` — the
server's version — and c2 is shelved); the PATCH answers `[]` (stale).
The head pull is empty, the id unseen. The rule: the baseline seq is no
longer the sent seq → the entry is dropped and the hash stays c2's; c1
is still dirty and the next flush PATCHes with the new seq and lands.
The baseline seq only moves forward and a conflict needs an incoming seq
above it, so the confirm branch never overwrites a conflict's hash. The
refuted rule (`pullVerifyNaive`): the hash is recomputed from local → c1
reads clean, the next flush sends nothing, the server keeps c2: c1 is
never uploaded. -/
theorem verify_drops_when_base_moved_witness :
    afterPeerPull.base 1 = some (2, 6)
      ∧ afterPeerPull.shelf = [(1, 2)]
      ∧ (peerWroteServer.patch 1 5 1).2 = none
      ∧ (pullVerify id afterPeerPull [] [⟨1, 5, 1⟩]).base 1 = some (2, 6)
      ∧ (pushRow id peerWroteServer (pullVerify id afterPeerPull [] [⟨1, 5, 1⟩]) 1).server.rows 1
          = some ⟨1, 7, false⟩
      ∧ (pullVerifyNaive id afterPeerPull [] [1]).base 1 = some (1, 6)
      ∧ (pushRow id peerWroteServer (pullVerifyNaive id afterPeerPull [] [1]) 1).needsPull
          = false
      ∧ (pushRow id peerWroteServer (pullVerifyNaive id afterPeerPull [] [1]) 1).server.counter
          = 6
      ∧ peerWroteServer.live 1 = some 2 := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> decide

/-- INTERLEAVING (iii) WITNESS (`sentHash`, not the live row): the PATCH
of c1 (= 4) answered `[]` (identical); before the verify pass the user
edited X to c3 (= 9). The rule writes the SENT hash: base `(4, 5)`, c3
stays dirty, the next flush PATCHes seq 5 and lands c3 at seq 6.
Recomputing from the live row (`pullVerifyNaive`) writes `(9, 5)`: c3
reads clean, nothing is sent, the server stays at c1. -/
theorem verify_writes_sent_not_live_witness :
    (pushRow id identicalServer staleHashReplica 1).pending = some ⟨1, 5, 4⟩
      ∧ (pullVerify id (staleHashReplica.edit 1 9) [] [⟨1, 5, 4⟩]).base 1 = some (4, 5)
      ∧ (pushRow id identicalServer
          (pullVerify id (staleHashReplica.edit 1 9) [] [⟨1, 5, 4⟩]) 1).server.rows 1
          = some ⟨9, 6, false⟩
      ∧ (pullVerifyNaive id (staleHashReplica.edit 1 9) [] [1]).base 1 = some (9, 5)
      ∧ (pushRow id identicalServer
          (pullVerifyNaive id (staleHashReplica.edit 1 9) [] [1]) 1).needsPull = false
      ∧ (pushRow id identicalServer
          (pullVerifyNaive id (staleHashReplica.edit 1 9) [] [1]) 1).server.counter = 5 := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩ <;> decide

/-- After our push: id 1 at v2 (seq 6), id 2 at some other row (seq 9). -/
def scenarioAServer : Server Nat :=
  { rows := fun i => if i = 1 then some ⟨2, 6, false⟩
      else if i = 2 then some ⟨7, 9, false⟩ else none
    counter := 9 }

theorem scenarioAServer_advances : Advances scenarioAServerBefore scenarioAServer := by
  refine ⟨by decide, ?_, ?_, ?_⟩
  · intro _ i row hrow
    simp only [scenarioAServer] at hrow ⊢
    by_cases h1 : i = 1
    · subst h1; simp at hrow; subst hrow; decide
    · by_cases h2 : i = 2
      · subst h2; simp at hrow; subst hrow; decide
      · simp [h1, h2] at hrow
  · intro i row hrow
    simp only [scenarioAServer] at hrow
    by_cases h1 : i = 1
    · subst h1; simp at hrow; subst hrow; exact Or.inr (by decide)
    · by_cases h2 : i = 2
      · subst h2; simp at hrow; subst hrow; exact Or.inr (by decide)
      · simp [h1, h2] at hrow
  · intro i row hrow
    simp only [scenarioAServerBefore, oneServer] at hrow
    by_cases h1 : i = 1
    · subst h1; exact ⟨⟨2, 6, false⟩, by simp [scenarioAServer]⟩
    · simp [h1] at hrow

/-- A page carrying id 1 at seq 5 and id 2 at seq 9 — the page an earlier
revision of this file applied to `scenarioAServer`. -/
def scenarioAPage : List (FeedRow Nat) := [⟨1, 5, 1, false⟩, ⟨2, 9, 7, false⟩]

/-- `scenarioAPage` is not a snapshot of `scenarioAServer` (it shows seq 9,
so it was taken after seq 6 committed, so it shows id 1 at seq 6 — I5),
and it is not a snapshot of `scenarioAServerBefore` either (no seq 9
there). The divergence this file once derived from it was a property of
a page the design cannot produce; that finding is withdrawn. -/
theorem scenarioAPage_not_head :
    ¬ IsHeadFeed scenarioAServer 4 scenarioAPage
      ∧ ¬ IsHeadFeed scenarioAServerBefore 4 scenarioAPage := by
  constructor
  · intro h
    have hs := (h.sound ⟨1, 5, 1, false⟩ (by simp [scenarioAPage])).1
    simp [scenarioAServer] at hs
  · intro h
    have hs := (h.sound ⟨2, 9, 7, false⟩ (by simp [scenarioAPage])).1
    simp [scenarioAServerBefore, oneServer] at hs

/-- The head page of `scenarioAServer` from cursor 5 — what the replica
pulls after the stale page moved its cursor to 5. -/
def consistentPage : List (FeedRow Nat) := [⟨1, 6, 2, false⟩, ⟨2, 9, 7, false⟩]

theorem consistentPage_head : IsHeadFeed scenarioAServer 5 consistentPage := by
  refine ⟨?_, ?_, ?_⟩
  · intro fr hfr
    simp [consistentPage] at hfr
    rcases hfr with rfl | rfl <;> simp [scenarioAServer]
  · intro i row hrow hlt
    by_cases h1 : i = 1
    · subst h1; exact ⟨⟨1, 6, 2, false⟩, by simp [consistentPage], rfl⟩
    · by_cases h2 : i = 2
      · subst h2; exact ⟨⟨2, 9, 7, false⟩, by simp [consistentPage], rfl⟩
      · simp [scenarioAServer, h1, h2] at hrow
  · decide

/-- The replica after the stale page under `==` and a local edit to v3. -/
def afterStaleEq : Replica Nat := (pullEq id afterPushReplica stalePage).edit 1 3

/-- SCENARIO A × EDIT WITNESS (what the stale page costs under `==`, and
what `≤` saves): after the stale page, cursor 5, base `(1, 5)`, local
v3. The PATCH `seq=eq.5` is refused (`[]`, pending `(1, 5, hash v3)`).
The next pull is the head page of the real server from 5: id 1 at seq 6
is SEEN, so it goes through the table — a conflict that shelves our OWN
v2 and sets the baseline to that row's `(hash, seq)` — and the pending
entry is dropped (seen; the
pull alone is the state). Local v3 survives, the next flush PATCHes
with seq 6 and lands v3 at seq 10. Cost: one transient regress (v2 → v1
until the pull) and one spurious shelf entry holding our own previous
version — not divergence. Under `≤` the stale row is a no-op, nothing is
shelved, and v3 lands directly. -/
theorem scenarioA_recovers_witness :
    afterStaleEq.cursor = 5
      ∧ afterStaleEq.base 1 = some (1, 5)
      ∧ (pushRow id scenarioAServer afterStaleEq 1).pending = some ⟨1, 5, 3⟩
      ∧ (pullEq id afterStaleEq consistentPage).loc 1 = some 3
      ∧ (pullEq id afterStaleEq consistentPage).base 1 = some (2, 6)
      ∧ (pullEq id afterStaleEq consistentPage).shelf = [(1, 2)]
      ∧ (pushRow id scenarioAServer (pullEq id afterStaleEq consistentPage) 1).server.rows 1
          = some ⟨3, 10, false⟩
      ∧ (pushRow id scenarioAServer (pullEq id afterStaleEq consistentPage) 1).needsPull
          = false
      ∧ (pushRow id scenarioAServer
          ((pull id afterPushReplica stalePage).edit 1 3) 1).server.rows 1
          = some ⟨3, 10, false⟩
      ∧ (pushRow id scenarioAServer
          ((pull id afterPushReplica stalePage).edit 1 3) 1).replica.shelf = [] := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> decide

end PendingVerify

/-! ## Delete witnesses — the pending-delete row, and where I8 does not reach -/

/-- PENDING DELETE vs PEER EDIT (the pending-delete row, composed): local
absent, baseline present (a delete not yet pushed) meets a peer's live
edit of the row. The row keeps the local side absent, shelves the peer's
edit, and writes the edit's `(hash, seq)`; `pushDelete` then still finds a
pending delete and tombstones the server row — delete beats edit, the
edit is on the shelf. Without the row (`decideRowNoPendingDelete`, the
reading review seven rejected) the edit is inserted back, nothing is
shelved, and `pushDelete` finds a local row and sends nothing: the
user's delete is dropped without a trace and the pending tombstone is
never sent. -/
theorem edit_beats_delete_without_row_witness :
    (applyRow id (oneRow none (some (5, 3))) ⟨1, 4, 9, false⟩).loc 1 = none
      ∧ (applyRow id (oneRow none (some (5, 3))) ⟨1, 4, 9, false⟩).shelf = [(1, 9)]
      ∧ (applyRow id (oneRow none (some (5, 3))) ⟨1, 4, 9, false⟩).base 1 = some (9, 4)
      ∧ (pushDelete (oneServer (some ⟨9, 4, false⟩) 4)
          (applyRow id (oneRow none (some (5, 3))) ⟨1, 4, 9, false⟩) 1).server.rows 1
          = some ⟨9, 5, true⟩
      ∧ (applyRowWith decideRowNoPendingDelete id (oneRow none (some (5, 3)))
          ⟨1, 4, 9, false⟩).loc 1 = some 9
      ∧ (applyRowWith decideRowNoPendingDelete id (oneRow none (some (5, 3)))
          ⟨1, 4, 9, false⟩).shelf = []
      ∧ (pushDelete (oneServer (some ⟨9, 4, false⟩) 4)
          (applyRowWith decideRowNoPendingDelete id (oneRow none (some (5, 3)))
            ⟨1, 4, 9, false⟩) 1).server.rows 1 = some ⟨9, 4, false⟩ := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> decide

/-- DELETE OVERRIDES CONCURRENT EDIT WITNESS (the mirror case): the delete
PATCH carries no seq filter, so a pending delete with a STALE baseline
lands on a row the peer edited since; the same bytes as a conditional
PATCH would have been refused by I8. The peer — clean holder of its own
edit — applies the tombstone and shelves nothing; the bytes survive only
as the server tombstone's content. Delete-vs-edit therefore resolves the
same way on both paths — the delete wins (the pending-delete row on the
pull path, the filter without seq on the push path), which is the
direction the text chose ("删除胜编辑", D4, I6). -/
theorem delete_overrides_concurrent_peer_edit_witness :
    (pushDelete (oneServer (some ⟨2, 6, false⟩) 6) (oneRow none (some (1, 5))) 1).server.rows 1
        = some ⟨2, 7, true⟩
      ∧ ((oneServer (some ⟨2, 6, false⟩) 6).patch 1 5 9).2 = none
      ∧ (applyRow id (oneRowAt (some 2) (some (2, 6)) 6) ⟨1, 7, 2, true⟩).loc 1 = none
      ∧ (applyRow id (oneRowAt (some 2) (some (2, 6)) 6) ⟨1, 7, 2, true⟩).shelf = [] := by
  refine ⟨?_, ?_, ?_, ?_⟩ <;> decide

/-- The server holding a tombstone of id 1; a replica that re-created the
same UUID locally (gh#140 undo after the tombstone was pulled), no
baseline, cursor at the tombstone's seq. -/
def deadServer : Server Nat := oneServer (some ⟨5, 3, true⟩) 3
def recreatedReplica : Replica Nat := oneRowAt (some 8) none 3

/-- The head page from cursor 3 after the POST is empty: the POST burned
a seq but wrote no row. -/
theorem deadServer_after_post_head :
    IsHeadFeed (pushRow id deadServer recreatedReplica 1).server 3 [] := by
  refine ⟨by simp, ?_, List.Pairwise.nil⟩
  intro i row hrow hlt
  have hs : (pushRow id deadServer recreatedReplica 1).server.rows i
      = if i = 1 then some (⟨5, 3, true⟩ : Row Nat) else none := by
    by_cases hi : i = 1
    · subst hi; decide
    · simp only [hi, ↓reduceIte]
      show (if i = 1 then some (⟨5, 3, true⟩ : Row Nat) else none) = none
      simp [hi]
  rw [hs] at hrow
  by_cases hi : i = 1
  · rw [if_pos hi] at hrow; cases hrow; simp at hlt
  · rw [if_neg hi] at hrow; cases hrow

/-- POST ONTO A TOMBSTONE WITNESS (never lands, no echo, no entry): the
ignore-duplicates POST of a row whose UUID the server holds as a
TOMBSTONE is DO NOTHING every flush — a seq is burned, no row is written,
the response omits the row, no pending entry is filed, and the head pull
shows nothing (the tombstone's seq is already at or below the cursor).
§6's "等回声拉取补基线后走 PATCH" never terminates for that id; only the
`sync.push.orphan` log fires. The undelete RPC (gh#140, Phase 2) is the
only exit. -/
theorem post_onto_tombstone_never_lands_witness :
    (pushRow id deadServer recreatedReplica 1).needsPull = true
      ∧ (pushRow id deadServer recreatedReplica 1).pending = none
      ∧ (pushRow id deadServer recreatedReplica 1).server.rows 1 = some ⟨5, 3, true⟩
      ∧ (pushRow id deadServer recreatedReplica 1).server.counter = 4
      ∧ (pull id recreatedReplica []).base 1 = none
      ∧ (pushRow id (pushRow id deadServer recreatedReplica 1).server
          (pull id recreatedReplica []) 1).needsPull = true
      ∧ (pushRow id (pushRow id deadServer recreatedReplica 1).server
          (pull id recreatedReplica []) 1).server.counter = 5 := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> decide

/-- The server holding a LIVE row for an id this replica also created
locally with no baseline — a restore on two devices, each pushing the
same UUID. -/
def peerHoldsSameId : Server Nat := oneServer (some ⟨5, 7, false⟩) 7
def freshLocalReplica : Replica Nat := oneRowAt (some 3) none 4

/-- FRESH LOCAL ROW vs REMOTE ROW OF THE SAME ID (the M1 branch, as a
chain): the ignore-duplicates POST is swallowed (a seq burned, no entry,
`needsPull`); the pull then sees the peer's row — local present, no
baseline, bytes differ — and the dirty row with an absent baseline
fires: local kept, the peer's row shelved, baseline `(h_in, seq)`. The
next flush is a PATCH against that seq and lands. With the same bytes
on both sides the row is `same` and the id reads clean with nothing
sent. -/
theorem fresh_local_vs_remote_same_id_witness :
    (pushRow id peerHoldsSameId freshLocalReplica 1).needsPull = true
      ∧ (pushRow id peerHoldsSameId freshLocalReplica 1).pending = none
      ∧ (pushRow id peerHoldsSameId freshLocalReplica 1).server.counter = 8
      ∧ (pull id freshLocalReplica [⟨1, 7, 5, false⟩]).loc 1 = some 3
      ∧ (pull id freshLocalReplica [⟨1, 7, 5, false⟩]).shelf = [(1, 5)]
      ∧ (pull id freshLocalReplica [⟨1, 7, 5, false⟩]).base 1 = some (5, 7)
      ∧ (pushRow id (pushRow id peerHoldsSameId freshLocalReplica 1).server
          (pull id freshLocalReplica [⟨1, 7, 5, false⟩]) 1).server.rows 1
          = some ⟨3, 9, false⟩
      ∧ (pull id (oneRowAt (some 5) none 4) [⟨1, 7, 5, false⟩]).base 1 = some (5, 7)
      ∧ (pushRow id peerHoldsSameId
          (pull id (oneRowAt (some 5) none 4) [⟨1, 7, 5, false⟩]) 1).needsPull = false
      ∧ (pushRow id peerHoldsSameId
          (pull id (oneRowAt (some 5) none 4) [⟨1, 7, 5, false⟩]) 1).server.counter = 7 := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> decide

/-! ## The conflict row's baseline — the server's version, not the old hash

Up to 34a7810 the conflict row and the pending-delete row kept the old
hash: `(h_base.hash, seq)`, "hash 不动保持脏". That pair names a version
the server never held at that seq — it held the old bytes at the old seq
and the incoming bytes at the new one — so "clean" stopped meaning
"equal to the server". The table now writes `(h_in, seq)` on both rows;
the old writing survives only as the variant `decideRowKeepHash`, and
every witness below that shows a loss is a witness AGAINST it. -/

section ConflictBase
variable [DecidableEq C] (hash : C → Hash)

omit [DecidableEq C] in
/-- What a `conflict` decision says about its inputs and its output: a
live row, not skipped, not an echo, not the local bytes; it writes the
incoming `(hash, seq)` and shelves the incoming row (only). -/
theorem decideRow_conflict_facts (tomb : Bool) (hIn : Hash) (hLoc : Option Hash)
    (hBase : Option (Hash × Seq)) (inSeq : Seq)
    (hc : (decideRow tomb hIn hLoc hBase inSeq).action = .conflict) :
    tomb = false ∧ staleOrSeen hBase inSeq = false ∧ hBase.map Prod.fst ≠ some hIn
      ∧ hLoc ≠ some hIn
      ∧ (decideRow tomb hIn hLoc hBase inSeq).base = some (hIn, inSeq)
      ∧ (decideRow tomb hIn hLoc hBase inSeq).shelfRemote = true
      ∧ (decideRow tomb hIn hLoc hBase inSeq).shelfLocal = false := by
  cases hs : staleOrSeen hBase inSeq
  · cases tomb
    · by_cases h1 : hBase.map Prod.fst = some hIn
      · rw [decideRow_echo _ _ _ _ hs h1] at hc; cases hc
      · by_cases h2 : hLoc = some hIn
        · rw [decideRow_same _ _ _ _ hs h1 h2] at hc; cases hc
        · have hb := decideRow_base_noskip false hIn hLoc hBase inSeq hs
          simp only [Bool.false_eq_true, ↓reduceIte] at hb
          refine ⟨rfl, rfl, h1, h2, hb, ?_⟩
          unfold decideRow at hc ⊢
          rw [hs] at hc ⊢
          simp only [Bool.false_eq_true, ↓reduceIte] at hc ⊢
          unfold decideRowBody at hc ⊢
          simp only [Bool.false_eq_true, ↓reduceIte, h1, h2] at hc ⊢
          by_cases h3 : hLoc = none ∧ hBase.isSome = true
          · simp only [h3, and_self, ↓reduceIte]
          · simp only [h3, ↓reduceIte] at hc ⊢
            by_cases h4 : hLoc = hBase.map Prod.fst ∨ hLoc = none
            · simp only [h4, ↓reduceIte] at hc; cases hc
            · simp only [h4, ↓reduceIte, and_self]
    · rw [decideRow_tomb _ _ _ _ hs] at hc; cases hc
  · rw [decideRow_skip _ _ _ _ _ hs] at hc; cases hc

omit [DecidableEq C] in
/-- THEOREM (a conflict's baseline is the incoming row): after the
conflict row — a dirty local row or a pending local delete meeting a
peer's edit — the entry is the incoming row's `(hash, seq)`, the
incoming row is on the shelf, and the local side is untouched. -/
theorem applyRow_conflict_base (r : Replica C) (fr : FeedRow C)
    (hc : (decideRow fr.deleted (hash fr.content) ((r.loc fr.id).map hash)
      (r.base fr.id) fr.seq).action = .conflict) :
    (applyRow hash r fr).base fr.id = some (hash fr.content, fr.seq)
      ∧ (applyRow hash r fr).loc fr.id = r.loc fr.id
      ∧ (fr.id, fr.content) ∈ (applyRow hash r fr).shelf := by
  obtain ⟨-, -, -, -, hb, hsr, hsl⟩ := decideRow_conflict_facts _ _ _ _ _ hc
  refine ⟨by rw [applyRow_base_self]; exact hb, by rw [applyRow_loc_self, hc], ?_⟩
  simp [applyRow, applyRowWith, hsr, hsl]

/-- THEOREM (after a conflict, any local value other than the server's is
uploaded): the replica applied a conflict row and the server still holds
that row; the local side is then set to any `v` whose hash is not the
incoming one — an edit, a revert to the bytes from before the conflict,
an undo re-adding a row whose delete had not been pushed. The id is
dirty, and the next flush's PATCH `seq=eq.<incoming seq>` lands `v`: the
server holds `v` live at a fresh seq and the baseline is `(hash v, that
seq)`. Local wins, the peer's version is on the shelf (I7). -/
theorem conflict_then_edit_is_pushed (s : Server C) (r : Replica C) (fr : FeedRow C) (v : C)
    (hc : (decideRow fr.deleted (hash fr.content) ((r.loc fr.id).map hash)
      (r.base fr.id) fr.seq).action = .conflict)
    (hsrv : s.rows fr.id = some ⟨fr.content, fr.seq, false⟩)
    (hv : hash v ≠ hash fr.content) :
    ¬ CleanAt hash ((applyRow hash r fr).edit fr.id v) fr.id
      ∧ pushRow hash s ((applyRow hash r fr).edit fr.id v) fr.id
        = ⟨s.setRow fr.id ⟨v, s.next, false⟩ s.next,
           ((applyRow hash r fr).edit fr.id v).setBase fr.id (some (hash v, s.next)),
           false, none⟩ := by
  obtain ⟨hb, -, -⟩ := applyRow_conflict_base hash r fr hc
  have hloc' : ((applyRow hash r fr).edit fr.id v).loc fr.id = some v := by
    simp [Replica.edit]
  have hb' : ((applyRow hash r fr).edit fr.id v).base fr.id = some (hash fr.content, fr.seq) := by
    simp only [Replica.edit]; exact hb
  have hne : v ≠ fr.content := fun h => hv (by rw [h])
  refine ⟨?_, ?_⟩
  · unfold CleanAt
    rw [hloc', hb']
    simp only [Option.map_some, Option.some.injEq]
    exact hv
  · have hpatch : s.patch fr.id fr.seq v
        = (s.setRow fr.id ⟨v, s.next, false⟩ s.next, some ⟨v, s.next, false⟩) := by
      unfold Server.patch
      simp [hsrv, Ne.symm hne]
    unfold pushRow
    simp only [hloc', hb', Option.map_some, Option.some.injEq, Ne.symm hv, ↓reduceIte, hpatch,
      Bool.false_eq_true]

/-- THEOREM (a revert after a conflict is pushed — the case the old
writing lost): the local side is set back to bytes `c0` whose hash is the
baseline hash from BEFORE the conflict (a hand edit-back, an undo that
writes the pre-edit event back, an undo that re-adds a deleted row). The
conflict row fired only because the incoming row is not that version, so
`c0` is dirty against the new baseline and the next PATCH lands it. Under
`decideRowKeepHash` the same `c0` reads clean and is never sent:
`conflict_then_revert_reads_clean_witness`. -/
theorem conflict_then_revert_is_pushed (s : Server C) (r : Replica C) (fr : FeedRow C)
    (c0 : C) (h0 : Hash) (S : Seq)
    (hbase : r.base fr.id = some (h0, S)) (hc0 : hash c0 = h0)
    (hc : (decideRow fr.deleted (hash fr.content) ((r.loc fr.id).map hash)
      (r.base fr.id) fr.seq).action = .conflict)
    (hsrv : s.rows fr.id = some ⟨fr.content, fr.seq, false⟩) :
    ¬ CleanAt hash ((applyRow hash r fr).edit fr.id c0) fr.id
      ∧ pushRow hash s ((applyRow hash r fr).edit fr.id c0) fr.id
        = ⟨s.setRow fr.id ⟨c0, s.next, false⟩ s.next,
           ((applyRow hash r fr).edit fr.id c0).setBase fr.id (some (hash c0, s.next)),
           false, none⟩ := by
  obtain ⟨-, -, hnecho, -⟩ := decideRow_conflict_facts _ _ _ _ _ hc
  have hv : hash c0 ≠ hash fr.content := by
    intro h
    apply hnecho
    rw [hbase, ← hc0, h]
    rfl
  exact conflict_then_edit_is_pushed hash s r fr c0 hc hsrv hv

end ConflictBase

/-- The superseded table (34a7810 and every earlier version): the
conflict row and the pending-delete row keep the old baseline hash and
take the incoming seq — `(h_in, seq)` only when no baseline existed (the
M1 case). Kept only for the witnesses against it. -/
def decideRowKeepHash : Core := fun tomb hIn hLoc hBase inSeq =>
  let d := decideRow tomb hIn hLoc hBase inSeq
  if d.action = .conflict then { d with base := some ((hBase.map Prod.fst).getD hIn, inSeq) }
  else d

/-- The two tables differ on the conflict row's baseline HASH and on
nothing else: the same row fires, the same side is shelved, the same seq
is written, and every non-conflict decision is identical. So every PATCH
both tables send is the same PATCH; they differ only on which local
values read clean. -/
theorem decideRowKeepHash_agrees (tomb : Bool) (hIn : Hash) (hLoc : Option Hash)
    (hBase : Option (Hash × Seq)) (inSeq : Seq) :
    (decideRowKeepHash tomb hIn hLoc hBase inSeq).action
        = (decideRow tomb hIn hLoc hBase inSeq).action
      ∧ (decideRowKeepHash tomb hIn hLoc hBase inSeq).shelfRemote
        = (decideRow tomb hIn hLoc hBase inSeq).shelfRemote
      ∧ (decideRowKeepHash tomb hIn hLoc hBase inSeq).shelfLocal
        = (decideRow tomb hIn hLoc hBase inSeq).shelfLocal
      ∧ (decideRowKeepHash tomb hIn hLoc hBase inSeq).base.map Prod.snd
        = (decideRow tomb hIn hLoc hBase inSeq).base.map Prod.snd
      ∧ ((decideRow tomb hIn hLoc hBase inSeq).action ≠ .conflict →
          decideRowKeepHash tomb hIn hLoc hBase inSeq = decideRow tomb hIn hLoc hBase inSeq) := by
  by_cases hc : (decideRow tomb hIn hLoc hBase inSeq).action = .conflict
  · have hb := (decideRow_conflict_facts _ _ _ _ _ hc).2.2.2.2.1
    simp [decideRowKeepHash, hc, hb]
  · simp [decideRowKeepHash, hc]

/-- The peer wrote c2; the replica held c1, dirty over c0's baseline, and
pulled the row: a conflict, c2 shelved — under the table and under the
superseded writing. -/
def revertServer : Server Nat := oneServer (some ⟨2, 6, false⟩) 6
def conflicted : Replica Nat := pull id (oneRowAt (some 1) (some (0, 5)) 5) [⟨1, 6, 2, false⟩]
def conflictedKeepHash : Replica Nat :=
  applyRowWith decideRowKeepHash id (oneRowAt (some 1) (some (0, 5)) 5) ⟨1, 6, 2, false⟩

theorem revertServer_head : IsHeadFeed revertServer 6 [] := by
  refine ⟨by simp, ?_, List.Pairwise.nil⟩
  intro i row hrow hlt
  by_cases hi : i = 1
  · subst hi
    simp [revertServer, oneServer] at hrow
    subst hrow
    simp at hlt
  · simp [revertServer, oneServer, hi] at hrow

/-- CONFLICT-THEN-REVERT WITNESS (against the superseded writing): after
the conflict the user reverts X to the pre-conflict bytes c0. Under
`decideRowKeepHash` the kept hash IS c0's, so the id reads CLEAN while
the server (and the peer) hold c2 at the baseline's own seq: the flush
sends nothing, the head pull is empty (`revertServer_head`), this device
shows c0 forever and c2 is only on its shelf — "clean" and "equal to the
server" no longer agree (`keep_hash_state_not_sound`). Under the table
the baseline is c2's, the reverted row is dirty, and the next PATCH
lands c0 (`conflict_then_revert_is_pushed`). -/
theorem conflict_then_revert_reads_clean_witness :
    conflictedKeepHash.base 1 = some (0, 6)
      ∧ conflictedKeepHash.shelf = [(1, 2)]
      ∧ ((conflictedKeepHash.edit 1 0).loc 1).map id
          = ((conflictedKeepHash.edit 1 0).base 1).map Prod.fst
      ∧ (pushRow id revertServer (conflictedKeepHash.edit 1 0) 1).needsPull = false
      ∧ (pushRow id revertServer (conflictedKeepHash.edit 1 0) 1).pending = none
      ∧ (pushRow id revertServer (conflictedKeepHash.edit 1 0) 1).server.counter = 6
      ∧ revertServer.live 1 = some 2
      ∧ conflicted.base 1 = some (2, 6)
      ∧ conflicted.shelf = [(1, 2)]
      ∧ conflicted.loc 1 = some 1
      ∧ (pushRow id revertServer (conflicted.edit 1 0) 1).server.rows 1
          = some ⟨0, 7, false⟩ := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> decide

/-- The premises of `conflict_then_revert_is_pushed` are met by the
witness's state: the general theorem, applied to it, says the reverted
row is dirty — the theorem is not vacuous. -/
theorem conflict_then_revert_is_pushed_instance :
    ¬ CleanAt id ((applyRow id (oneRowAt (some 1) (some (0, 5)) 5) ⟨1, 6, 2, false⟩).edit 1 0) 1 :=
  (conflict_then_revert_is_pushed id revertServer (oneRowAt (some 1) (some (0, 5)) 5)
    ⟨1, 6, 2, false⟩ 0 0 5 (by decide) rfl (by decide) (by decide)).1

/-- The same theorem on its other form, the pending-delete row (design
§6 case (c)): a local delete not yet pushed meets the peer's c2, then an
undo re-adds c0 — dirty. -/
theorem conflict_then_revert_is_pushed_pending_delete_instance :
    ¬ CleanAt id ((applyRow id (oneRowAt none (some (0, 5)) 5) ⟨1, 6, 2, false⟩).edit 1 0) 1 :=
  (conflict_then_revert_is_pushed id revertServer (oneRowAt none (some (0, 5)) 5)
    ⟨1, 6, 2, false⟩ 0 0 5 (by decide) rfl (by decide) (by decide)).1

/-- The superseded writing's state is outside `BaseHashSound`: its
baseline names the server row's seq with c0's hash, and that row is c2. -/
theorem keep_hash_state_not_sound : ¬ BaseHashSound id revertServer conflictedKeepHash := by
  intro h
  have := h 1 0 6 ⟨2, 6, false⟩ (by decide) (by decide) rfl
  cases this

/-- The peer B reverted X to c0 before this device's flush. -/
def peerRevertServer : Server Nat := oneServer (some ⟨0, 7, false⟩) 7

/-- FALSE-ECHO WITNESS (against the superseded writing — I7): after the
conflict, peer B reverts X to c0. Under `decideRowKeepHash` the kept hash
is c0's, so the echo row fires on B's c0: it is not shelved and the
baseline takes B's seq; this device's PATCH of c1 lands, and B — clean
at its own push — adopts c1 with nothing shelved. c0 is then on no
device, not on the server, not on any shelf. Under the table the same
row is a conflict: c0 is shelved next to c2, and c1 still lands. -/
theorem keep_hash_echo_drops_peer_revert_witness :
    (applyRowWith decideRowKeepHash id conflictedKeepHash ⟨1, 7, 0, false⟩).shelf = [(1, 2)]
      ∧ (applyRowWith decideRowKeepHash id conflictedKeepHash ⟨1, 7, 0, false⟩).base 1
          = some (0, 7)
      ∧ (pushRow id peerRevertServer
          (applyRowWith decideRowKeepHash id conflictedKeepHash ⟨1, 7, 0, false⟩) 1).server.rows 1
          = some ⟨1, 8, false⟩
      ∧ (pull id (oneRowAt (some 0) (some (0, 7)) 7) [⟨1, 8, 1, false⟩]).loc 1 = some 1
      ∧ (pull id (oneRowAt (some 0) (some (0, 7)) 7) [⟨1, 8, 1, false⟩]).shelf = []
      ∧ (applyRow id conflicted ⟨1, 7, 0, false⟩).shelf = [(1, 2), (1, 0)]
      ∧ (applyRow id conflicted ⟨1, 7, 0, false⟩).base 1 = some (0, 7)
      ∧ (pushRow id peerRevertServer (applyRow id conflicted ⟨1, 7, 0, false⟩) 1).server.rows 1
          = some ⟨1, 8, false⟩ := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> decide

/-- A pending local delete (local absent over c0's baseline) that met the
peer's c2 — under the superseded writing and under the table. -/
def pendingDeleteKeepHash : Replica Nat :=
  applyRowWith decideRowKeepHash id (oneRowAt none (some (0, 5)) 5) ⟨1, 6, 2, false⟩
def pendingDeleteMet : Replica Nat := applyRow id (oneRowAt none (some (0, 5)) 5) ⟨1, 6, 2, false⟩

/-- UNDO-AFTER-PENDING-DELETE WITNESS (against the superseded writing):
the delete had not been pushed when the peer's edit arrived (both
writings keep the row absent and shelve c2); then an undo re-adds the
exact pre-delete bytes c0. Under `decideRowKeepHash` c0 reads clean and
the local row is no longer absent, so neither a PATCH nor the tombstone
is sent and the server keeps c2. Under the table, either the flush comes
first — the tombstone lands (`pushDelete` ignores the hash; delete beats
edit, c2 is on the shelf) — or the undo comes first, and then the PATCH
lands c0. The two conjunct groups below are those two alternative runs,
not one run in sequence. -/
theorem keep_hash_undo_after_pending_delete_witness :
    pendingDeleteKeepHash.base 1 = some (0, 6)
      ∧ pendingDeleteKeepHash.shelf = [(1, 2)]
      ∧ pendingDeleteKeepHash.loc 1 = none
      ∧ (pushRow id revertServer (pendingDeleteKeepHash.edit 1 0) 1).server.counter = 6
      ∧ (pushRow id revertServer (pendingDeleteKeepHash.edit 1 0) 1).needsPull = false
      ∧ (pushDelete revertServer (pendingDeleteKeepHash.edit 1 0) 1).server.counter = 6
      ∧ pendingDeleteMet.base 1 = some (2, 6)
      ∧ pendingDeleteMet.shelf = [(1, 2)]
      ∧ pendingDeleteMet.loc 1 = none
      ∧ (pushDelete revertServer pendingDeleteMet 1).server.rows 1 = some ⟨2, 7, true⟩
      ∧ (pushRow id revertServer (pendingDeleteMet.edit 1 0) 1).server.rows 1
          = some ⟨0, 7, false⟩ := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> decide

/-- The server after this device's PATCH of c1 (over the conflict's
baseline) landed and its `[row]` response was lost: the server holds c1,
the replica still holds the conflict's baseline. -/
def lostResponseServer : Server Nat := (pushRow id revertServer conflicted 1).server

/-- LOST-RESPONSE RESIDUAL WITNESS (independent of the conflict writing;
recorded, not closed): the PATCH of c1 landed but the response was lost,
and the user then sets X to exactly the baseline's version — under the
table that is c2, the server's version at the baseline seq. It reads
clean, nothing is sent, and the pull of our own c1 adopts over it — but
c2 is already on the shelf. A revert to c0 in the same state is dirty,
its PATCH is refused, the pull files our own c1 as a conflict, and c0
stays and is uploaded next. The same hole without a conflict, on a
`Reachable` run through `lose`: `lost_then_revert_reachable`. -/
theorem lost_response_residual_witness :
    lostResponseServer.rows 1 = some ⟨1, 7, false⟩
      ∧ (pushRow id lostResponseServer (conflicted.edit 1 2) 1).needsPull = false
      ∧ (pushRow id lostResponseServer (conflicted.edit 1 2) 1).server.counter
          = lostResponseServer.counter
      ∧ (applyRow id (conflicted.edit 1 2) ⟨1, 7, 1, false⟩).loc 1 = some 1
      ∧ (applyRow id (conflicted.edit 1 2) ⟨1, 7, 1, false⟩).shelf = [(1, 2)]
      ∧ (pushRow id lostResponseServer (conflicted.edit 1 0) 1).needsPull = true
      ∧ (applyRow id (conflicted.edit 1 0) ⟨1, 7, 1, false⟩).loc 1 = some 0
      ∧ (applyRow id (conflicted.edit 1 0) ⟨1, 7, 1, false⟩).shelf = [(1, 2), (1, 1)]
      ∧ (applyRow id (conflicted.edit 1 0) ⟨1, 7, 1, false⟩).base 1 = some (1, 7) := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> decide

/-! ## Order witnesses — the statements that are FALSE with two checks swapped -/

/-- The §6 table with dirty detection hoisted ABOVE the echo check — the
order the design forbids. -/
def decideRowDirtyFirst : Core := fun tomb hIn hLoc hBase inSeq =>
  if tomb then decideRow tomb hIn hLoc hBase inSeq
  else if hLoc ≠ hBase.map Prod.fst ∧ hLoc ≠ some hIn ∧ hLoc ≠ none then
    { action := .conflict, base := some (hIn, inSeq),
      shelfRemote := true, shelfLocal := false }
  else decideRow tomb hIn hLoc hBase inSeq

/-- The §6 table with the echo check hoisted ABOVE the tombstone check. -/
def decideRowEchoFirst : Core := fun tomb hIn hLoc hBase inSeq =>
  if hBase.map Prod.fst = some hIn then
    { action := .echo, base := some (hIn, inSeq), shelfRemote := false,
      shelfLocal := false }
  else decideRow tomb hIn hLoc hBase inSeq

/-- ORDER WITNESS 1 (dirty before echo breaks T3): the C2 shape — base is
the pushed version, local has moved on, a same-hash row arrives at a
newer seq (the own-push echo at the SAME seq is already absorbed by the
skip row once the push's response is applied, so this is the echo row's
remaining case: a peer's write that landed back on our bytes). The
design's order leaves the shelf empty; with dirty detection first the
row is filed as a conflict. An own-push echo pulled BEFORE the response
meets the pre-push baseline and is a conflict in either order
(`echo_before_response_shelves_own_push_witness`). -/
theorem dirty_before_echo_shelves_own_push_witness :
    (applyRow id (oneRow (some 2) (some (1, 5))) ⟨1, 6, 1, false⟩).shelf = []
      ∧ (applyRowWith decideRowDirtyFirst id (oneRow (some 2) (some (1, 5)))
          ⟨1, 6, 1, false⟩).shelf = [(1, 1)] := by
  constructor <;> decide

/-- ORDER WITNESS 2 (echo before tombstone breaks `applyRow_clean_lands`,
hence T5): a tombstone whose kept content hashes to the baseline — every
delete of a row we pushed — would be read as an echo and never delete
locally. The §6 table already puts tombstone before echo; this is a
"do not reorder" guard, not a finding against the text. -/
theorem echo_before_tombstone_keeps_deleted_row_witness :
    (applyRow id (oneRow (some 7) (some (7, 3))) ⟨1, 9, 7, true⟩).loc 1 = none
      ∧ (applyRowWith decideRowEchoFirst id (oneRow (some 7) (some (7, 3)))
          ⟨1, 9, 7, true⟩).loc 1 = some 7 := by
  constructor <;> decide

/-! ## Multi-page convergence — the I1 loop over limit-cut snapshots

T5 is one head page. The I1 loop pulls page after page while peers keep
writing, each page cut by `page_limit` (or the row clamp) at the seq of
its last row: at each step the replica pulls a limit-cut page of the
server AS IT THEN IS, from its current cursor. `Chain` is that run; the
state the run carries — `Inv`, all ids clean, `SyncedBelow`,
`BaseHashSound` — is preserved by every step, and a step whose page is
a HEAD page leaves every server row at or below the new cursor, so the
last pull of a run (the short page) lands the replica on the server's
live content everywhere. A peer's write between pages reappears above
the cursor; a row the run has not reached yet is simply not claimed. -/

section MultiPage
variable [DecidableEq C] (hash : C → Hash)

omit [DecidableEq C] in
/-- `SyncedBelow` transfers across a peer write: a row the write touched
sits above the counter, hence above the cursor, so it is not claimed. -/
theorem syncedBelow_advances {s s' : Server C} {r : Replica C} (h : Inv s r)
    (hs : SyncedBelow s r) (a : Advances s s') : SyncedBelow s' r := by
  intro i hp
  cases hr' : s'.rows i with
  | none =>
    cases hr : s.rows i with
    | none =>
      have := hs i (fun row hrow => by rw [hr] at hrow; cases hrow)
      rw [this]
      simp [Server.live, hr, hr']
    | some row =>
      obtain ⟨row', hrow'⟩ := a.keep i row hr
      rw [hr'] at hrow'; cases hrow'
  | some row' =>
    rcases a.rows i row' hr' with hold | hnew
    · have := hs i (fun row hrow => by
        rw [hold] at hrow; cases hrow; exact hp row' hr')
      rw [this]
      simp [Server.live, hold, hr']
    · exact absurd (Nat.lt_of_lt_of_le hnew (Nat.le_trans (hp row' hr') h.cursorBounded))
        (Nat.lt_irrefl _)

omit [DecidableEq C] in
theorem baseHashSound_advances {s s' : Server C} {r : Replica C} (h : Inv s r)
    (hb : BaseHashSound hash s r) (a : Advances s s') : BaseHashSound hash s' r := by
  intro i hh S row hbase hrow hseq
  rcases a.rows i row hrow with hold | hnew
  · exact hb i hh S row hbase hold hseq
  · rw [hseq] at hnew
    exact absurd (Nat.lt_of_lt_of_le hnew (h.bounded i hh S hbase)) (Nat.lt_irrefl _)

omit [DecidableEq C] in
/-- One step of the run: a peer write, then the pull of a limit-cut page
of the new server state. Everything the run carries is preserved, the
shelf is untouched. -/
theorem chain_step (hinj : HashInjective hash) {s s' : Server C} {r : Replica C}
    (hinv : Inv s r) (hclean : ∀ i, CleanAt hash r i) (hs : SyncedBelow s r)
    (hbh : BaseHashSound hash s r) (a : Advances s s')
    (bound : Seq) (page : List (FeedRow C)) (hfeed : IsPageFeed s' r.cursor bound page) :
    Inv s' (pull hash r page)
      ∧ (∀ i, CleanAt hash (pull hash r page) i)
      ∧ SyncedBelow s' (pull hash r page)
      ∧ BaseHashSound hash s' (pull hash r page)
      ∧ (pull hash r page).shelf = r.shelf := by
  have hinv' : Inv s' r := inv_of_advances hinv a
  have hs' : SyncedBelow s' r := syncedBelow_advances hinv hs a
  have hbh' : BaseHashSound hash s' r := baseHashSound_advances hash hinv hbh a
  have hsound : ∀ fr ∈ page, s'.rows fr.id = some ⟨fr.content, fr.seq, fr.deleted⟩ :=
    fun fr hfr => (hfeed.sound fr hfr).1
  obtain ⟨hsync, hshelf, hcleanAll, hbases⟩ :=
    clean_replica_page hash hinj s' r bound page hclean hs' hinv'.anchored hbh' hinv'.noDead hfeed
  refine ⟨inv_pull_page hash hinv' bound page hfeed, hcleanAll, hsync, ?_, hshelf⟩
  intro i hh S row hbase hrow hseq
  by_cases hin : ∃ fr ∈ page, fr.id = i
  · obtain ⟨fr, hfr, hid⟩ := hin
    subst hid
    rw [hbases fr hfr] at hbase
    have := hsound fr hfr
    rw [this] at hrow
    cases hrow
    cases hd : fr.deleted
    · rw [hd] at hbase
      simp only [Bool.false_eq_true, ↓reduceIte, Option.some.injEq, Prod.mk.injEq] at hbase
      exact hbase.1.symm
    · rw [hd] at hbase
      simp at hbase
  · have hin' : ∀ fr ∈ page, fr.id ≠ i := fun fr hfr hid => hin ⟨fr, hfr, hid⟩
    rw [(pull_frame hash r page i hin').2] at hbase
    exact hbh' i hh S row hbase hrow hseq

/-- A run of the I1 loop: from server state `s` and replica `r`, each step
is a peer write to `s'` and a pull of a limit-cut page of `s'` from the
replica's cursor (the bound is the page's own: the seq of its last row,
or the counter for a head page); `sEnd` is the server state of the last
step (or `s` for the empty run). -/
inductive Chain : Server C → Replica C → List (Server C × List (FeedRow C)) → Server C → Prop
  | nil (s : Server C) (r : Replica C) : Chain s r [] s
  | cons (s s' sEnd : Server C) (r : Replica C) (page : List (FeedRow C))
      (rest : List (Server C × List (FeedRow C)))
      (a : Advances s s') (bound : Seq) (hfeed : IsPageFeed s' r.cursor bound page)
      (h : Chain s' (pull hash r page) rest sEnd) :
      Chain s r ((s', page) :: rest) sEnd

/-- The replica after a run. -/
def pullAll (r : Replica C) : List (Server C × List (FeedRow C)) → Replica C
  | [] => r
  | (_, page) :: rest => pullAll (pull hash r page) rest

omit [DecidableEq C] in
/-- THEOREM (the run carries its state): along any run the invariant, all-
clean, `SyncedBelow` and `BaseHashSound` hold against the current server,
and the shelf never changes. -/
theorem chain_preserves (hinj : HashInjective hash) {s sEnd : Server C} {r : Replica C}
    {steps : List (Server C × List (FeedRow C))}
    (hchain : Chain hash s r steps sEnd)
    (hinv : Inv s r) (hclean : ∀ i, CleanAt hash r i) (hs : SyncedBelow s r)
    (hbh : BaseHashSound hash s r) :
    Inv sEnd (pullAll hash r steps)
      ∧ (∀ i, CleanAt hash (pullAll hash r steps) i)
      ∧ SyncedBelow sEnd (pullAll hash r steps)
      ∧ BaseHashSound hash sEnd (pullAll hash r steps)
      ∧ (pullAll hash r steps).shelf = r.shelf := by
  induction hchain with
  | nil s r => exact ⟨hinv, hclean, hs, hbh, rfl⟩
  | cons s s' sEnd r page rest a bound hfeed _ ih =>
    obtain ⟨h1, h2, h3, h4, h5⟩ := chain_step hash hinj hinv hclean hs hbh a bound page hfeed
    obtain ⟨i1, i2, i3, i4, i5⟩ := ih h1 h2 h3 h4
    exact ⟨i1, i2, i3, i4, by simp only [pullAll]; rw [i5, h5]⟩

omit [DecidableEq C] in
/-- THEOREM T5' (multi-page convergence): a clean, truthful replica that
runs the I1 loop — any number of limit-cut pages, peers writing in
between — and whose LAST pull is a head page of the server as it then is
(the short page), ends on that server's live content at EVERY id, shelf
untouched, every id clean. -/
theorem pull_pages_converge (hinj : HashInjective hash) {s s₁ s' : Server C} {r : Replica C}
    {steps : List (Server C × List (FeedRow C))}
    (hchain : Chain hash s r steps s₁)
    (hinv : Inv s r) (hclean : ∀ i, CleanAt hash r i) (hs : SyncedBelow s r)
    (hbh : BaseHashSound hash s r)
    (a : Advances s₁ s') (page : List (FeedRow C))
    (hfeed : IsHeadFeed s' (pullAll hash r steps).cursor page) :
    (∀ i, (pull hash (pullAll hash r steps) page).loc i = s'.live i)
      ∧ (pull hash (pullAll hash r steps) page).shelf = r.shelf
      ∧ ∀ i, CleanAt hash (pull hash (pullAll hash r steps) page) i := by
  obtain ⟨h1, h2, h3, h4, h5⟩ := chain_preserves hash hinj hchain hinv hclean hs hbh
  have hwf' : s'.WF := (inv_of_advances h1 a).wf
  obtain ⟨-, c2, c3, -, c5⟩ :=
    chain_step hash hinj h1 h2 h3 h4 a s'.counter page (hfeed.page hwf')
  refine ⟨?_, by rw [c5, h5], c2⟩
  intro i
  exact c3 i (pull_head_covers hash s' _ page hfeed i)

omit [DecidableEq C] in
/-- A fresh replica (no rows, no baseline, cursor 0) satisfies every
premise of T5' against any well-formed server whose rows all carry a
minted seq (`nextval` starts above zero), so the run from a new install
is covered. -/
theorem fresh_replica_premises (s : Server C) (hwf : s.WF)
    (hpos : ∀ i row, s.rows i = some row → 0 < row.seq) (r : Replica C)
    (hl : ∀ i, r.loc i = none) (hb : ∀ i, r.base i = none) (hc : r.cursor = 0) :
    Inv s r ∧ (∀ i, CleanAt hash r i) ∧ SyncedBelow s r ∧ BaseHashSound hash s r := by
  refine ⟨inv_initial s r hwf hb (by rw [hc]; exact Nat.zero_le _), ?_, ?_, ?_⟩
  · intro i; unfold CleanAt; rw [hl i, hb i]; rfl
  · intro i hp
    cases hr : s.rows i with
    | none => rw [hl i]; simp [Server.live, hr]
    | some row =>
      have h1 := hp row hr
      rw [hc] at h1
      have h2 := hpos i row hr
      exact absurd (Nat.lt_of_lt_of_le h2 h1) (Nat.lt_irrefl _)
  · intro i hh S row hb'; rw [hb i] at hb'; cases hb'

end MultiPage

/-! ## Reachable states — every baseline names a version the server held

`Reachable` closes the model's operations from a fresh replica, in the
sequential reading of the design's one MainActor, with ONE exception to
sequentiality that the design makes the common case: a PATCH's `[row]`
or `[]` response may arrive after other operations ("两者并存是常态",
§6 interleaving (ii)). The constructors:

* a peer's write of any `ClientOp` shape; a local edit; a local delete;
* `push` — the upload of one row with its response applied at once
  (`pushRow`: conditional PATCH or ignore-duplicates POST);
* `send` then `recv` — a conditional PATCH whose response is applied
  LATER: `send` builds the PATCH from the replica (a dirty row, its
  baseline seq, the bytes) and lets the server process it; any other
  operation may run before `recv` applies the response. At most one
  upload per id is outstanding (the per-table flush awaits its PATCHes).
  `recv` writes `(hash sent, row.seq)` on `[row]` ONLY IF the baseline
  seq is still the seq the PATCH carried (`Replica.recv`); the text's
  unconditional write is `Replica.recvUnguarded`, and
  `late_row_response_regresses_witness` is what it costs;
* `lose` — a PATCH whose response never arrives (the request threw after
  the server processed it): the flight is dropped, nothing is written or
  filed, and the next flush PATCHes again from the unchanged baseline —
  the pre-v1.5 "a throw keeps the baseline" reading
  (`lost_then_revert_reachable` is the residual it admits, which v1.5's
  `?` baseline, not modelled, closes);
* `pushDelete`;
* `pull` — a page `IsPageFeed s₀ cursor bound` (a head page or a
  limit-cut page) of a server state `s₀` THIS RUN passed through (the
  current one, or an earlier one: a page fetched before our own push and
  applied after it);
* `verify` — the pull that may clear pending-verify entries: a HEAD page
  of the CURRENT server. Every entry was filed at an earlier state, so
  the pull was issued after every `[]` it clears: this is the sequential
  form of the `pullIssue` eligibility, and it consumes every entry. An
  ineligible pass — a page of a state before an entry was filed — is NOT
  a `Reachable` step; `ineligible_verify_loses_witness` is the loss it
  would let through (design interleaving (i)). Neither is an ELIGIBLE
  pass whose page went stale before it was applied — the RPC issued
  after every `[]` it clears, a peer's write or a push of ours landing
  between the fetch and the apply: the text's `pullIssue` orders the
  issue, not the apply, so it allows that pass; `Reachable` does not
  contain it, and `reachable_sound` says nothing about it;
* `restore` — a restore with the rewind (`Replica.restore`:
  `EventStore.applyRestore` keeping pending local deletes, the baseline
  replay, then the cursor set to `min(cursor, C0)`), merge with any
  per-row decisions or overwrite, with pending entries and PATCHes in
  flight allowed. `C0` is the cursor captured before the fetch; the
  snapshot rows are live rows states of the run at or above `C0` held
  (`hread`), not necessarily one consistent snapshot nor the current
  server, and for an overwrite the snapshot carries every row live at
  one such state (`hall`). The same restore WITHOUT the
  rewind — the Swift as of 7a2e382e, which applies the snapshot after the
  user's review while the puller runs — is NOT a `Reachable` step;
  `restore_stale_snapshot_witness` and
  `overwrite_drops_pulled_row_control` are what it lets through.

`init` asks that a fresh replica's cursor sit below every live server
row (a fresh device has no cursor and pulls everything first, I1); with
it, every live server row at or below the cursor has an entry on every
reachable state (`baseCovers_of_reachable`).

What holds on every reachable state (`reachable_sound`): `Inv`;
`BaseHashSound`; `BaseTracksFeed`; `BaseHeld` — every baseline entry
`(h, S)` is a LIVE version some server state of the run held at seq `S`
with hash `h`, the past-tense sentence of the design; every pending entry
is stale (`PendingStale`: the server row for the id carries a seq above
the sent one); every outstanding PATCH response is sound for a later
`recv`. These are facts about the writers the model has; the writers it
does not have are listed in the header (the singleton tables' and
event_types' restore replay among them).

Two things the reachable set does NOT contain, so that nothing here is
read as covering them. `Reachable` fixes ONE `hash`: a build that
changes the row-hash encoding — the state T9a starts from, where a
baseline hash is foreign to the bytes the server holds at its seq —
violates `BaseHashSound` and is outside it. Consequently, on reachable
states a PATCH `[]` is never the content-identical short-circuit, every
entry is stale, and the confirm branch of the verify pass never fires
(`reachable_verify_is_pull`): the `sentHash` rule is exercised only by
T9a and the interleaving witnesses, not by `reachable_sound`. And
concurrency beyond late PATCH responses — a POST response applied late,
two pulls interleaved, a PATCH built before a pull and sent after it —
is not modelled. -/

section Reachable
variable [DecidableEq C] (hash : C → Hash)

omit [DecidableEq C] in
/-- A pending-verify entry that tells the truth about the server: its
sent seq was handed out, and if the server's row for the id still
carries that seq, that row holds the sent bytes (by hash). -/
def PendingSound (s : Server C) (p : Pending) : Prop :=
  p.sentSeq ≤ s.counter
    ∧ ∀ row, s.rows p.id = some row → row.seq = p.sentSeq → hash row.content = p.sentHash

omit [DecidableEq C] in
/-- A STALE pending-verify entry: the server's row for the id carries a
seq above the one the PATCH filter sent. On reachable states every
entry is stale (`reachable_sound`): with one hash function, a dirty
PATCH whose filter seq is the server row's seq lands. -/
def PendingStale (s : Server C) (p : Pending) : Prop :=
  ∃ row, s.rows p.id = some row ∧ p.sentSeq < row.seq

omit [DecidableEq C] in
theorem pendingStale_advances {s s' : Server C} {p : Pending} (hwf : s.WF)
    (hp : PendingStale s p) (a : Advances s s') : PendingStale s' p := by
  obtain ⟨row, hrow, hlt⟩ := hp
  obtain ⟨row', hrow'⟩ := a.keep p.id row hrow
  refine ⟨row', hrow', ?_⟩
  rcases a.rows p.id row' hrow' with hold | hnew
  · rw [hrow] at hold; cases hold; exact hlt
  · exact Nat.lt_trans hlt (Nat.lt_of_le_of_lt (hwf p.id row hrow) hnew)

omit [DecidableEq C] in
/-- A stale entry is sound: the server's row does not carry the sent seq. -/
theorem pendingStale_sound {s : Server C} {p : Pending} (hwf : s.WF) (hp : PendingStale s p) :
    PendingSound hash s p := by
  obtain ⟨row, hrow, hlt⟩ := hp
  refine ⟨Nat.le_trans (Nat.le_of_lt hlt) (hwf p.id row hrow), ?_⟩
  intro row' hrow' hseq
  rw [hrow] at hrow'; cases hrow'
  exact absurd hseq (Nat.ne_of_lt hlt).symm

omit [DecidableEq C] in
/-- Every server write keeps an entry sound: a row it changed carries a
seq above the old counter, hence not the sent seq. -/
theorem pendingSound_advances {s s' : Server C} {p : Pending}
    (hp : PendingSound hash s p) (a : Advances s s') : PendingSound hash s' p := by
  refine ⟨Nat.le_trans hp.1 a.mono, ?_⟩
  intro row hrow hseq
  rcases a.rows p.id row hrow with hold | hnew
  · exact hp.2 row hold hseq
  · rw [hseq] at hnew
    exact absurd (Nat.lt_of_lt_of_le hnew hp.1) (Nat.lt_irrefl _)

/-- A dirty PATCH that answers `[]` against a baseline that tells the
truth was stale: with one hash function the content-identical
short-circuit cannot fire on a dirty row, so the server row carries a
seq above the filter's. -/
theorem patch_empty_stale {s : Server C} {r : Replica C} (h : Inv s r)
    (hb : BaseHashSound hash s r) (id : Id) (c : C) (bh : Hash) (bseq : Seq)
    (hbase : r.base id = some (bh, bseq)) (hdirty : bh ≠ hash c)
    (hempty : (s.patch id bseq c).2 = none) :
    ∃ row, s.rows id = some row ∧ bseq < row.seq := by
  obtain ⟨row, hrow, hle⟩ := h.anchored id bh bseq hbase
  refine ⟨row, hrow, ?_⟩
  rcases Nat.lt_or_eq_of_le hle with hlt | heq
  · exact hlt
  · exfalso
    rcases patch_empty_reasons s id bseq c hempty with hnone | ⟨row', hrow', hr⟩
    · rw [hnone] at hrow; cases hrow
    · rw [hrow] at hrow'; cases hrow'
      rcases hr with hne | hc
      · exact hne heq.symm
      · exact hdirty (by rw [hb id bh bseq row hbase hrow heq.symm, hc])

/-- Our own push advances the server. -/
theorem pushRow_advances (s : Server C) (r : Replica C) (id : Id) :
    Advances s (pushRow hash s r id).server := by
  rcases pushRow_cases hash s r id with ⟨-, hp⟩
    | ⟨c, row, bh, bseq, -, -, -, -, -, hp⟩
    | ⟨c, row, bh, bseq, -, -, -, -, -, hp⟩
    | ⟨c, bh, bseq, -, -, -, hp⟩ | ⟨c, -, -, -, hp⟩ | ⟨c, -, -, hp⟩ <;> rw [hp]
  · exact advances_refl s
  · exact advances_setRow s id _ _ (next_gt s) rfl
  · exact advances_setRow s id _ _ (next_gt s) rfl
  · exact advances_refl s
  · exact advances_setRow s id _ _ (next_gt s) rfl
  · exact advances_counter s

/-- Our own pushed delete advances the server. -/
theorem pushDelete_advances (s : Server C) (r : Replica C) (id : Id) :
    Advances s (pushDelete s r id).server := by
  unfold pushDelete
  split
  · exact step_advances s (.tombstone id)
  · exact advances_refl s

omit [DecidableEq C] in
/-- A conditional PATCH, whatever it answers, advances the server. -/
theorem patch_advances [DecidableEq C] (s : Server C) (id : Id) (base : Seq) (c : C) :
    Advances s (s.patch id base c).1 :=
  step_advances s (.patch id base c)

/-- The entry a PATCH `[]` of `pushRow` files is stale (hence sound) on
a state whose baseline tells the truth: `[]` on a dirty row there is
I8, not the short-circuit. -/
theorem pendingStale_pushRow {s : Server C} {r : Replica C} (h : Inv s r)
    (hb : BaseHashSound hash s r) (id : Id) (p : Pending)
    (hp : (pushRow hash s r id).pending = some p) :
    PendingStale (pushRow hash s r id).server p := by
  rcases pushRow_cases hash s r id with ⟨-, hpush⟩
    | ⟨c, row, bh, bseq, -, -, -, -, -, hpush⟩
    | ⟨c, row, bh, bseq, -, -, -, -, -, hpush⟩
    | ⟨c, bh, bseq, hloc, hbase, hempty, hpush⟩ | ⟨c, -, -, -, hpush⟩ | ⟨c, -, -, hpush⟩
    <;> rw [hpush] at hp ⊢ <;> try (cases hp; done)
  cases hp
  have hdirty : bh ≠ hash c := by
    intro hcl
    have hclean : pushRow hash s r id = ⟨s, r, false, none⟩ := by
      unfold pushRow; simp [hloc, hbase, hcl]
    rw [hclean] at hpush; cases hpush
  exact patch_empty_stale hash h hb id c bh bseq hbase hdirty hempty

/-- A peer's write keeps `BaseHashSound` (it is an `Advances`). -/
theorem baseHashSound_step {s : Server C} {r : Replica C} (h : Inv s r)
    (hb : BaseHashSound hash s r) (op : Server.ClientOp C) :
    BaseHashSound hash (s.step op) r :=
  baseHashSound_advances hash h hb (step_advances s op)

omit [DecidableEq C] in
/-- A write that landed `c` at `s.next` makes `(hash c, s.next)` sound. -/
theorem baseHashSound_after_write {s : Server C} {r : Replica C} (hb : BaseHashSound hash s r)
    (id : Id) (c : C) (d : Bool) :
    BaseHashSound hash (s.setRow id { content := c, seq := s.next, deleted := d } s.next)
      (r.setBase id (some (hash c, s.next))) := by
  intro i hh S row hbase hrow hseq
  simp only [Replica.setBase, Server.setRow] at hbase hrow
  by_cases hi : i = id
  · rw [if_pos hi] at hbase hrow
    cases hbase
    cases hrow
    rfl
  · rw [if_neg hi] at hbase hrow
    exact hb i hh S row hbase hrow hseq

/-- Our own push keeps `BaseHashSound`: a `[row]` (PATCH or POST) writes
`(hash sent, seq)` for the row the server now holds; the dead-row branch
removes the entry; `[]` changes nothing but, for a POST, the counter. -/
theorem baseHashSound_pushRow {s : Server C} {r : Replica C} (h : Inv s r)
    (hb : BaseHashSound hash s r) (id : Id) :
    BaseHashSound hash (pushRow hash s r id).server (pushRow hash s r id).replica := by
  rcases pushRow_cases hash s r id with ⟨-, hp⟩
    | ⟨c, row, bh, bseq, -, -, -, -, -, hp⟩
    | ⟨c, row, bh, bseq, -, -, -, -, -, hp⟩
    | ⟨c, bh, bseq, -, -, -, hp⟩ | ⟨c, -, -, -, hp⟩ | ⟨c, -, -, hp⟩ <;> rw [hp]
  · exact hb
  · exact baseHashSound_after_write hash hb id c row.deleted
  · intro i hh S row' hbase hrow hseq
    simp only [Replica.deadRowHit, Server.setRow] at hbase hrow
    by_cases hi : i = id
    · rw [if_pos hi] at hbase; cases hbase
    · rw [if_neg hi] at hbase hrow
      exact hb i hh S row' hbase hrow hseq
  · exact hb
  · exact baseHashSound_after_write hash hb id c false
  · exact baseHashSound_advances hash h hb (advances_counter s)

/-- Our own pushed delete keeps `BaseHashSound`: the entry is removed and
only that id's server row changes. -/
theorem baseHashSound_pushDelete {s : Server C} {r : Replica C} (h : Inv s r)
    (hb : BaseHashSound hash s r) (id : Id) :
    BaseHashSound hash (pushDelete s r id).server (pushDelete s r id).replica := by
  unfold pushDelete
  split
  · intro i hh S row hbase hrow hseq
    simp only [Replica.setBase] at hbase
    by_cases hi : i = id
    · rw [if_pos hi] at hbase; cases hbase
    · rw [if_neg hi] at hbase
      exact baseHashSound_advances hash h hb (step_advances s (.tombstone id))
        i hh S row hbase hrow hseq
  · exact hb

omit [DecidableEq C] in
/-- Applying a row of a snapshot of `s₀`, against a server `s` that
advances from `s₀`, keeps `BaseHashSound`: a skipped row keeps an entry
the predicate already vouched for, a tombstone removes the entry, and
every other row — the conflict row and the pending-delete row included —
writes the row's own `(hash, seq)`; the server's row at that seq, if it
still has it, IS that row (a row `s` changed since carries a seq above
`s₀`'s counter). -/
theorem baseHashSound_applyRow_snapshot {s₀ s : Server C} {r : Replica C}
    (hwf₀ : s₀.WF) (a : Advances s₀ s) (hb : BaseHashSound hash s r)
    (fr : FeedRow C) (hsound : s₀.rows fr.id = some ⟨fr.content, fr.seq, fr.deleted⟩) :
    BaseHashSound hash s (applyRow hash r fr) := by
  cases hs : staleOrSeen (r.base fr.id) fr.seq
  · intro i h S row hbase hrow hseq
    by_cases hi : i = fr.id
    · subst hi
      rw [applyRow_base_noskip hash r fr hs] at hbase
      cases hd : fr.deleted
      · rw [hd] at hbase
        simp only [Bool.false_eq_true, ↓reduceIte, Option.some.injEq, Prod.mk.injEq] at hbase
        obtain ⟨rfl, rfl⟩ := hbase
        rcases a.rows fr.id row hrow with hold | hnew
        · rw [hsound] at hold
          cases hold
          rfl
        · rw [hseq] at hnew
          exact absurd (Nat.lt_of_lt_of_le hnew (hwf₀ fr.id _ hsound)) (Nat.lt_irrefl _)
      · rw [hd] at hbase; cases hbase
    · rw [(applyRow_frame hash r fr i hi).2] at hbase
      exact hb i h S row hbase hrow hseq
  · rw [applyRow_skip hash r fr hs]
    exact hb

omit [DecidableEq C] in
theorem baseHashSound_foldl_snapshot {s₀ s : Server C} (hwf₀ : s₀.WF) (a : Advances s₀ s)
    (rows : List (FeedRow C)) {r : Replica C} (hb : BaseHashSound hash s r)
    (hsound : ∀ fr ∈ rows, s₀.rows fr.id = some ⟨fr.content, fr.seq, fr.deleted⟩) :
    BaseHashSound hash s (rows.foldl (applyRow hash) r) := by
  induction rows generalizing r with
  | nil => exact hb
  | cons fr rest ih =>
    simp only [List.foldl]
    exact ih (baseHashSound_applyRow_snapshot hash hwf₀ a hb fr (hsound fr (by simp)))
      (fun x hx => hsound x (by simp [hx]))

omit [DecidableEq C] in
/-- A pull of any page whose rows are a snapshot of `s₀` — a head page, a
limit-cut page, a stale page fetched before our own push — keeps
`BaseHashSound` against `s`. -/
theorem baseHashSound_pull {s₀ s : Server C} (hwf₀ : s₀.WF) (a : Advances s₀ s)
    {r : Replica C} (hb : BaseHashSound hash s r) (page : List (FeedRow C))
    (hsound : ∀ fr ∈ page, s₀.rows fr.id = some ⟨fr.content, fr.seq, fr.deleted⟩) :
    BaseHashSound hash s (pull hash r page) :=
  baseHashSound_foldl_snapshot hash hwf₀ a _ hb
    (fun fr hfr => hsound fr (List.mem_filter.mp hfr).1)

omit [DecidableEq C] in
/-- The confirm branch of the verify pass keeps `BaseHashSound`: it writes
`(sentHash, S)` only when the baseline seq is the sent seq, and a sound
entry says the server's row at that seq, if it still has it, holds the
sent bytes. -/
theorem baseHashSound_verifyUnseen {s : Server C} {r : Replica C} {p : Pending}
    (hb : BaseHashSound hash s r) (hp : PendingSound hash s p) :
    BaseHashSound hash s (r.verifyUnseen p) := by
  intro i h S row hbase hrow hseq
  by_cases hi : i = p.id
  · subst hi
    unfold Replica.verifyUnseen at hbase
    split at hbase
    · rename_i h0 S0 hb0
      split at hbase
      · rename_i hS
        simp only [Replica.setBase, ↓reduceIte, Option.some.injEq, Prod.mk.injEq] at hbase
        obtain ⟨rfl, rfl⟩ := hbase
        exact (hp.2 row hrow (hseq.trans hS)).symm
      · exact hb _ h S row hbase hrow hseq
    · exact hb _ h S row hbase hrow hseq
  · rw [verifyUnseen_frame r p i hi] at hbase
    exact hb i h S row hbase hrow hseq

omit [DecidableEq C] in
theorem baseHashSound_foldl_verify {s : Server C} (pending : List Pending) {r : Replica C}
    (hb : BaseHashSound hash s r) (hp : ∀ p ∈ pending, PendingSound hash s p) :
    BaseHashSound hash s (pending.foldl Replica.verifyUnseen r) := by
  induction pending generalizing r with
  | nil => exact hb
  | cons p rest ih =>
    simp only [List.foldl]
    exact ih (baseHashSound_verifyUnseen hash hb (hp p (by simp)))
      (fun q hq => hp q (by simp [hq]))

omit [DecidableEq C] in
/-- A pull followed by the verify pass keeps `BaseHashSound`, for a page of
any snapshot and any list of sound entries — eligible or not. This is
the one fact about the confirm branch that does not need eligibility;
what eligibility buys is `BaseHeld` (`ineligible_verify_loses_witness`). -/
theorem baseHashSound_pullVerify {s₀ s : Server C} (hwf₀ : s₀.WF) (a : Advances s₀ s)
    {r : Replica C} (hb : BaseHashSound hash s r) (page : List (FeedRow C))
    (hsound : ∀ fr ∈ page, s₀.rows fr.id = some ⟨fr.content, fr.seq, fr.deleted⟩)
    (pending : List Pending) (hp : ∀ p ∈ pending, PendingSound hash s p) :
    BaseHashSound hash s (pullVerify hash r page pending) := by
  unfold pullVerify
  exact baseHashSound_foldl_verify hash _ (baseHashSound_pull hash hwf₀ a hb page hsound)
    (fun q hq => hp q (List.mem_filter.mp hq).1)

omit [DecidableEq C] in
/-- `Inv` survives a pull of any page whose rows are a snapshot of `s₀`
(no completeness needed). -/
theorem inv_pull_sound {s₀ s : Server C} {r : Replica C} (hwf₀ : s₀.WF) (a : Advances s₀ s)
    (h : Inv s r) (page : List (FeedRow C))
    (hsound : ∀ fr ∈ page, s₀.rows fr.id = some ⟨fr.content, fr.seq, fr.deleted⟩) :
    Inv s (pull hash r page) := by
  have hf := inv_foldl_snapshot hash hwf₀ a h (page.filter fun fr => decide (r.cursor < fr.seq))
    (fun fr hfr => hsound fr (List.mem_filter.mp hfr).1)
  refine ⟨hf.wf, hf.bounded, hf.noDead, hf.anchored, ?_⟩
  show (page.filter fun fr => decide (r.cursor < fr.seq)).foldl
    (fun m fr => max m fr.seq) r.cursor ≤ s.counter
  apply foldl_max_le _ _ _ h.cursorBounded
  intro fr hfr
  exact Nat.le_trans (hwf₀ fr.id _ (hsound fr (List.mem_filter.mp hfr).1)) a.mono

omit [DecidableEq C] in
/-- The cursor after a limit-cut page of `s₀` stays within `s₀`'s
counter. -/
theorem pull_page_cursor_le_counter {s₀ : Server C} {r : Replica C} (hwf : s₀.WF)
    (hc : r.cursor ≤ s₀.counter) (bound : Seq) (page : List (FeedRow C))
    (hfeed : IsPageFeed s₀ r.cursor bound page) :
    (pull hash r page).cursor ≤ s₀.counter := by
  show (page.filter fun fr => decide (r.cursor < fr.seq)).foldl
    (fun m fr => max m fr.seq) r.cursor ≤ s₀.counter
  apply foldl_max_le _ _ _ hc
  intro fr hfr
  exact hwf fr.id _ (hfeed.sound fr (List.mem_filter.mp hfr).1).1

omit [DecidableEq C] in
/-- A pull never moves the cursor back. -/
theorem pull_cursor_ge (r : Replica C) (page : List (FeedRow C)) :
    r.cursor ≤ (pull hash r page).cursor :=
  (foldl_max_ge (page.filter fun fr => decide (r.cursor < fr.seq)) r.cursor).1

/-- A seq past the old cursor and at most the larger of the old cursor and
the bound is at most the bound. -/
theorem le_bound_of_le_max {a c b : Nat} (h : a ≤ max c b) (hlt : c < a) : a ≤ b := by
  omega

omit [DecidableEq C] in
/-- THEOREM (tracking survives a limit-cut pull, stale pages included):
`baseTracksFeed_pull` for a page cut at `bound` — a server row past the
old cursor and at or below the new one is at or below the bound, hence
in the page. -/
theorem baseTracksFeed_pull_page {s₀ s : Server C} {r : Replica C}
    (hwf : s₀.WF) (hc : r.cursor ≤ s₀.counter) (bound : Seq) (page : List (FeedRow C))
    (hfeed : IsPageFeed s₀ r.cursor bound page) (a : Advances s₀ s)
    (hinv : Inv s r) (ht : BaseTracksFeed s r) :
    BaseTracksFeed s (pull hash r page) := by
  have hcur := pull_page_cursor_le_counter hash hwf hc bound page hfeed
  have hcur2 := pull_page_cursor_le hash s₀ r bound page hfeed
  have hbase : (pull hash r page).base = (page.foldl (applyRow hash) r).base := by
    simp only [pull, hfeed.filter_self]
  intro i hh S row hb hrow hle
  rw [hbase] at hb
  rcases a.rows i row hrow with hold | hnew
  · by_cases hin : ∃ fr ∈ page, fr.id = i
    · obtain ⟨fr, hfr, hid⟩ := hin
      subst hid
      rw [(foldl_self_of_mem hash page r fr hfeed.distinct hfr).2] at hb
      have hsnd := (hfeed.sound fr hfr).1
      rw [hsnd] at hold
      cases hold
      cases hs : staleOrSeen (r.base fr.id) fr.seq
      · rw [applyRow_base_self] at hb
        rcases decideRow_base_seq_noskip fr.deleted (hash fr.content) ((r.loc fr.id).map hash)
            (r.base fr.id) fr.seq hs with hn | ⟨x, hx⟩
        · rw [hn] at hb; cases hb
        · rw [hx] at hb; cases hb
          rfl
      · rw [applyRow_skip hash r fr hs] at hb
        obtain ⟨h', S', hb', hle'⟩ := (staleOrSeen_true_iff _ _).mp hs
        rw [hb] at hb'
        cases hb'
        obtain ⟨row', hrow', hSle⟩ := hinv.anchored fr.id hh S hb
        rw [hrow] at hrow'
        cases hrow'
        exact Nat.le_antisymm hle' hSle
    · have hin' : ∀ fr ∈ page, fr.id ≠ i := fun fr hfr hid => hin ⟨fr, hfr, hid⟩
      rw [(foldl_frame hash page r i hin').2] at hb
      rcases Nat.lt_or_ge r.cursor row.seq with hlt | hge
      · have hbd : row.seq ≤ bound := le_bound_of_le_max (Nat.le_trans hle hcur2) hlt
        obtain ⟨fr, hfr, hfrid⟩ := hfeed.complete i row hold hlt hbd
        exact absurd hfrid (hin' fr hfr)
      · exact ht i hh S row hb hrow hge
  · exact absurd (Nat.lt_of_lt_of_le hnew (Nat.le_trans hle hcur)) (Nat.lt_irrefl _)

omit [DecidableEq C] in
/-- A local delete: the row leaves the local store; its baseline entry
stays until the tombstone PATCH lands (`pushDelete`). -/
def Replica.deleteLocal (r : Replica C) (id : Id) : Replica C :=
  { r with loc := fun i => if i = id then none else r.loc i }

/-! ### Late PATCH responses -/

/-- A conditional PATCH in flight: the id, the baseline seq its filter
carried, the bytes sent, and the response the server already gave
(`[row]` = `some row`, `[]` = `none`). -/
structure Flight (C : Type) where
  id : Id
  sentSeq : Seq
  sent : C
  resp : Option (Row C)

omit [DecidableEq C] in
/-- Applying a PATCH response that arrives late, with the guard: `[row]`
writes `(hash sent, row.seq)` only if the baseline seq is STILL the seq
the PATCH carried — a pull that applied a row for the id meanwhile (a
conflict, our own echo, a tombstone) moved or removed the entry, and the
response is then dropped; the next flush PATCHes at the current seq.
A `[row]` with `deleted_at` is treated as an incoming tombstone (never
reached on reachable states: the PATCH matched a live row). `[]` leaves
the replica as it is (its entry is filed by `Flight.toPending`). -/
def Replica.recv (r : Replica C) (q : Flight C) : Replica C :=
  match q.resp with
  | some row =>
    if (r.base q.id).map Prod.snd = some q.sentSeq then
      if row.deleted then
        match r.loc q.id with
        | some c => r.deadRowHit q.id c
        | none => r.setBase q.id none
      else r.setBase q.id (some (hash q.sent, row.seq))
    else r
  | none => r

omit [DecidableEq C] in
/-- The text's writing (§6 上传形状, slice-1 `writeBaseline`): `[row]`
writes `(hash sent, row.seq)` unconditionally, whenever it arrives. -/
def Replica.recvUnguarded (r : Replica C) (q : Flight C) : Replica C :=
  match q.resp with
  | some row =>
    if row.deleted then
      match r.loc q.id with
      | some c => r.deadRowHit q.id c
      | none => r.setBase q.id none
    else r.setBase q.id (some (hash q.sent, row.seq))
  | none => r

omit [DecidableEq C] in
/-- The pending-verify entry a late `[]` files. -/
def Flight.toPending (q : Flight C) : List Pending :=
  match q.resp with
  | some _ => []
  | none => [⟨q.id, q.sentSeq, hash q.sent⟩]

omit [DecidableEq C] in
/-- What an outstanding PATCH response must satisfy for its late `recv`
to tell the truth. For `[]`: the entry it files is stale. For `[row]`:
the row is live, carries the sent bytes at a seq above the filter's, was
held by a state of the run, the server's row for the id has not gone
below it and carries its seq only if it IS it; and — the guard's
whole content — while the baseline seq is still the PATCH's, no server
row for the id at or below the cursor carries any other seq. -/
structure FlightSound (hist : List (Server C)) (s : Server C) (r : Replica C)
    (q : Flight C) : Prop where
  empty : q.resp = none → PendingStale s ⟨q.id, q.sentSeq, hash q.sent⟩
  live : ∀ row, q.resp = some row → row.deleted = false
  sent : ∀ row, q.resp = some row → row.content = q.sent
  fresh : ∀ row, q.resp = some row → q.sentSeq < row.seq
  bounded : ∀ row, q.resp = some row → row.seq ≤ s.counter
  held : ∀ row, q.resp = some row → ∃ s' ∈ hist, s'.rows q.id = some row
  anchored : ∀ row, q.resp = some row → ∃ row', s.rows q.id = some row' ∧ row.seq ≤ row'.seq
  same : ∀ row, q.resp = some row → ∀ row', s.rows q.id = some row' →
    row'.seq = row.seq → row' = row
  tracks : ∀ row, q.resp = some row → (r.base q.id).map Prod.snd = some q.sentSeq →
    ∀ row', s.rows q.id = some row' → row'.seq ≤ r.cursor → row'.seq = row.seq

omit [DecidableEq C] in
/-- Every baseline entry `(h, S)` names a LIVE version some state of
`hist` held at seq `S` with hash `h` — "基线 (hash, seq) 永远是服务端在
seq 上真实持有过的那一版", with the history made explicit. -/
def BaseHeld (hist : List (Server C)) (r : Replica C) : Prop :=
  ∀ id h S, r.base id = some (h, S) →
    ∃ s' ∈ hist, ∃ row, s'.rows id = some row ∧ row.seq = S ∧ row.deleted = false
      ∧ hash row.content = h

omit [DecidableEq C] in
/-- Every earlier state of the run is well formed and the current one
advances from it. -/
def PastOK (s : Server C) (past : List (Server C)) : Prop :=
  ∀ s' ∈ past, s'.WF ∧ Advances s' s

/-! ### Restore — `applyRestore`, then the baseline replay, then the rewind

A restore is a step of the replica alone: it writes no server row and
does not touch the shelf, and it leaves the pending-verify set and the
PATCHes in flight as they are — nothing in the Swift path
(`RestoreCoordinator.applyInternal` → `EventStore.applyRestore` →
`markRestoreCompleted` → `replayBaseline` → `replaceEntries`) waits for
them or clears them. As of 7a2e382e that path moves no cursor either
(`Replica.restoreUnfixed`), and a snapshot older than a version the
replica already pulled then loses an edit
(`restore_stale_snapshot_witness`). The fix the model takes as the
restore step (`Replica.restore`): the cursor `C0` is captured before the
first table is fetched, and the apply sets the cursor to
`min(cursor, C0)` in the same turn as the store mutations and the
replay, so every row a pull applied since the fetch began is pulled
again and meets the restored baseline through the §6 table. -/

/-- The cloud snapshot a restore applies, per id: the row the restore
fetch returned and the seq it carried (`RestoreSnapshot`, its
`cloudSeqs`). The fetch is a keyset walk over LIVE rows in seq order,
page by page, the copy read last winning for an id read twice; each page
is read at whatever state the server is in when it is asked, and the
user reviews the result before it is applied. So the model asks of a
snapshot row only that SOME state of the run held it live at that seq
(`Reachable.restore`'s `hread`) — not one consistent snapshot, not the
current server — and, of an overwrite, that it misses no row live at
the state the last page was read at (`hall`). Every row here carries a
seq: the Swift's
seq-less branch (a cloud row without `seq`) has no representation. -/
abbrev Snapshot (C : Type) := Id → Option (C × Seq)

/-- A local-rows rule: from the strategy (`true` = overwrite), the
per-row decisions, the snapshot, the baseline before the restore and the
local rows before it, the local rows after it. -/
abbrev LocRule (C : Type) :=
  Bool → (Id → Bool) → Snapshot C → (Id → Option (Hash × Seq)) → (Id → Option C) → Id → Option C

omit [DecidableEq C] in
/-- `EventStore.applyRestore` on one id table, with the merge rule the
user decided after 9121ba12 (`fix/restore-keep-local-deletes`) — the
local rows after the restore:

* overwrite (`cloudOverwritesLocal`): the table becomes the snapshot;
* merge (`mergeByID`): a row only the cloud has is appended — unless the
  id has a baseline entry: then it is a pending local delete (deleted
  here, its tombstone not yet sent), and it stays deleted; on a
  collision the local row stays unless the row's decision is `keepCloud`
  (`perRowDecisions?[cid] ?? resolution`, both folded into `keepCloud`);
  a row the cloud did not carry is left as it is.

The rule before it, which appends a pending delete's cloud row like any
other row only the cloud has, is `restoreLoc7a2e`. -/
def restoreLoc : LocRule C := fun overwrite keepCloud snap base loc i =>
  if overwrite then (snap i).map Prod.fst
  else
    match snap i, loc i with
    | some (cloudRow, _), none => if (base i).isSome then none else some cloudRow
    | some (cloudRow, _), some row => if keepCloud i then some cloudRow else some row
    | none, row => row

omit [DecidableEq C] in
/-- The merge rule as of 7a2e382e and 9121ba12: a row only the cloud has is
appended, a pending local delete's included — the delete is undone
(`restore_revives_pending_delete_control`). The baseline is unread. -/
def restoreLoc7a2e : LocRule C := fun overwrite keepCloud snap _ loc i =>
  if overwrite then (snap i).map Prod.fst
  else
    match snap i, loc i with
    | some (cloudRow, _), none => some cloudRow
    | some (cloudRow, _), some row => if keepCloud i then some cloudRow else some row
    | none, row => row

/-- A baseline replay rule: from the strategy (`true` = overwrite), the
snapshot, the baseline before the restore (`previous`) and the local rows
after it, the baseline after it. -/
abbrev Replay (C : Type) :=
  Bool → Snapshot C → (Id → Option (Hash × Seq)) → (Id → Option C) → Id → Option (Hash × Seq)

/-- What stands in for the seq of a seq-less entry `SyncBaselineEntry(hash:
…, seq: nil)`, which the model's baseline cannot hold (it has no hash
without a seq). Only the rules below that write such an entry use it,
and a witness that does reads only the hash half — the row is clean —
where the Swift pusher, too, reads nothing else of the entry
(`base.hash == hash` → nothing is sent). -/
def seqlessStandIn : Seq := 0

omit [DecidableEq C] in
/-- `replayBaseline` with the merge rule decided after 9121ba12, one id at
a time, branch for branch:

* the id is not a local row after the restore → after an overwrite, no
  entry (only local rows enter the baseline, `replaceEntries`); after a
  merge, the entry it had — a pending local delete keeps its entry, so
  its tombstone still goes up (an id with neither keeps neither);
* `if let cloudRow, let seq` — the snapshot carried it with a seq →
  `(hash cloudRow, seq)`;
* `else if overwrite` → `(hash row, previous seq)`, a seq-less entry
  when there is no previous one (`seqlessStandIn`). Never taken here: an
  overwrite's local rows are the snapshot's, each carried with a seq;
* `else if let cloudRow` (carried WITHOUT a seq) → not representable, see
  `Snapshot`;
* `else if let kept = previous[id]` → `kept`; otherwise no entry.

The replay as of 7a2e382e, which drops every id that is not a local row,
is `replayBaseline7a2e`; the one before it `replayBaselinePre`; slice
1's `replayBaselineSlice1`. -/
def replayBaseline (hash : C → Hash) : Replay C := fun overwrite snap previous loc i =>
  match loc i with
  | none => if overwrite then none else previous i
  | some row =>
    match snap i with
    | some (cloudRow, seq) => some (hash cloudRow, seq)
    | none =>
      if overwrite then some (hash row, ((previous i).map Prod.snd).getD seqlessStandIn)
      else previous i

omit [DecidableEq C] in
/-- `replayBaseline` as of 7a2e382e (and 9121ba12): as `replayBaseline`,
except that an id which is not a local row after the restore gets no
entry after a merge too — with `restoreLoc7a2e`, a pending local delete
the snapshot did not carry loses its entry and its tombstone is never
sent. -/
def replayBaseline7a2e (hash : C → Hash) : Replay C := fun overwrite snap previous loc i =>
  match loc i with
  | none => none
  | some row =>
    match snap i with
    | some (cloudRow, seq) => some (hash cloudRow, seq)
    | none =>
      if overwrite then some (hash row, ((previous i).map Prod.snd).getD seqlessStandIn)
      else previous i

omit [DecidableEq C] in
/-- `replayBaseline` before 7a2e382e (from 0a14f5d2): a row the snapshot
carried with a seq → `(hash cloudRow, seq)`; EVERY other local row —
after a merge too — → `(hash row, previous seq)`, seq-less when there is
no previous entry. A merge's row the cloud never had therefore reads
clean and is never uploaded (the bug 7a2e382e fixed:
`pre_merge_unsent_row_clean_control`). -/
def replayBaselinePre (hash : C → Hash) : Replay C := fun _ snap previous loc i =>
  match loc i with
  | none => none
  | some row =>
    match snap i with
    | some (cloudRow, seq) => some (hash cloudRow, seq)
    | none => some (hash row, ((previous i).map Prod.snd).getD seqlessStandIn)

omit [DecidableEq C] in
/-- Slice 1's `replayBaseline` (a95690be): every local row →
`(hash row, previous seq)`, the snapshot unread — a keepLocal collision
row reads clean against the cloud's version
(`slice1_collision_clean_control`, `restore_replay_local_hash_witness`). -/
def replayBaselineSlice1 (hash : C → Hash) : Replay C := fun _ _ previous loc i =>
  match loc i with
  | none => none
  | some row => some (hash row, ((previous i).map Prod.snd).getD seqlessStandIn)

omit [DecidableEq C] in
/-- A restore with the local-rows rule `locRule` and the baseline replay
`replay`, no rewind: the local rows become `locRule`'s, the baseline
becomes `replay`'s over them; the cursor and the shelf stay. -/
def Replica.restoreWithLoc (locRule : LocRule C) (replay : Replay C) (r : Replica C)
    (overwrite : Bool) (keepCloud : Id → Bool) (snap : Snapshot C) : Replica C :=
  let loc' := locRule overwrite keepCloud snap r.base r.loc
  { r with loc := loc', base := replay overwrite snap r.base loc' }

omit [DecidableEq C] in
/-- The same with the current local-rows rule (`restoreLoc`). -/
def Replica.restoreWith (replay : Replay C) (r : Replica C) (overwrite : Bool)
    (keepCloud : Id → Bool) (snap : Snapshot C) : Replica C :=
  r.restoreWithLoc restoreLoc replay overwrite keepCloud snap

omit [DecidableEq C] in
/-- The same, then the rewind: the cursor becomes `min(cursor, C0)`, `C0`
the cursor captured before the fetch began. -/
def Replica.restoreFixedWith (replay : Replay C) (r : Replica C) (overwrite : Bool)
    (keepCloud : Id → Bool) (snap : Snapshot C) (C0 : Seq) : Replica C :=
  { r.restoreWith replay overwrite keepCloud snap with cursor := min r.cursor C0 }

omit [DecidableEq C] in
/-- The restore as the Swift has it at 7a2e382e: its local-rows rule and
replay, no rewind. A control (`restore_stale_snapshot_witness`,
`overwrite_drops_pulled_row_control`), not a `Reachable` step. -/
def Replica.restoreUnfixed (r : Replica C) (overwrite : Bool) (keepCloud : Id → Bool)
    (snap : Snapshot C) : Replica C :=
  r.restoreWithLoc restoreLoc7a2e (replayBaseline7a2e hash) overwrite keepCloud snap

omit [DecidableEq C] in
/-- The restore as the Swift has it at 9121ba12: 7a2e382e's rules, then the
rewind. A control (`restore_revives_pending_delete_control`), not a
`Reachable` step. -/
def Replica.restore9121 (r : Replica C) (overwrite : Bool) (keepCloud : Id → Bool)
    (snap : Snapshot C) (C0 : Seq) : Replica C :=
  { r.restoreUnfixed hash overwrite keepCloud snap with cursor := min r.cursor C0 }

omit [DecidableEq C] in
/-- The restore step of `Reachable`: the merge rule that keeps a pending
local delete, the replay, then the rewind. -/
def Replica.restore (r : Replica C) (overwrite : Bool) (keepCloud : Id → Bool)
    (snap : Snapshot C) (C0 : Seq) : Replica C :=
  r.restoreFixedWith (replayBaseline hash) overwrite keepCloud snap C0

/-- A system state: the server, this replica, the pending-verify entries
filed since the last verify pass, the PATCHes whose response is still
on its way, and the server states the run passed through (newest
first, the current one excluded). -/
structure Sys (C : Type) where
  server : Server C
  replica : Replica C
  pending : List Pending
  flights : List (Flight C)
  past : List (Server C)

/-- The states the model reaches from a fresh replica (see the section
header for what each constructor is and is not). -/
inductive Reachable : Sys C → Prop
  | init (s : Server C) (r : Replica C) (hwf : s.WF) (hb : ∀ i, r.base i = none)
      (hc : r.cursor ≤ s.counter)
      (hfresh0 : ∀ i row, s.rows i = some row → row.seq ≤ r.cursor → row.deleted = true) :
      Reachable ⟨s, r, [], [], []⟩
  | peer (sys : Sys C) (op : Server.ClientOp C) :
      Reachable sys →
      Reachable { sys with server := sys.server.step op, past := sys.server :: sys.past }
  | edit (sys : Sys C) (id : Id) (c : C) :
      Reachable sys → Reachable { sys with replica := sys.replica.edit id c }
  | deleteLocal (sys : Sys C) (id : Id) :
      Reachable sys → Reachable { sys with replica := sys.replica.deleteLocal id }
  | push (sys : Sys C) (id : Id) (hfree : ∀ q ∈ sys.flights, q.id ≠ id) :
      Reachable sys →
      Reachable { sys with
        server := (pushRow hash sys.server sys.replica id).server
        replica := (pushRow hash sys.server sys.replica id).replica
        pending := sys.pending ++ (pushRow hash sys.server sys.replica id).pending.toList
        past := sys.server :: sys.past }
  | send (sys : Sys C) (id : Id) (c : C) (bh : Hash) (bseq : Seq)
      (hloc : sys.replica.loc id = some c) (hbase : sys.replica.base id = some (bh, bseq))
      (hdirty : bh ≠ hash c) (hfree : ∀ q ∈ sys.flights, q.id ≠ id) :
      Reachable sys →
      Reachable { sys with
        server := (sys.server.patch id bseq c).1
        flights := sys.flights ++ [⟨id, bseq, c, (sys.server.patch id bseq c).2⟩]
        past := sys.server :: sys.past }
  | recv (sys : Sys C) (pre post : List (Flight C)) (q : Flight C)
      (hq : sys.flights = pre ++ q :: post) :
      Reachable sys →
      Reachable { sys with
        replica := sys.replica.recv hash q
        pending := sys.pending ++ q.toPending hash
        flights := pre ++ post }
  | lose (sys : Sys C) (pre post : List (Flight C)) (q : Flight C)
      (hq : sys.flights = pre ++ q :: post) :
      Reachable sys → Reachable { sys with flights := pre ++ post }
  | pushDelete (sys : Sys C) (id : Id) :
      Reachable sys →
      Reachable { sys with
        server := (pushDelete sys.server sys.replica id).server
        replica := (pushDelete sys.server sys.replica id).replica
        past := sys.server :: sys.past }
  | pull (sys : Sys C) (s₀ : Server C) (bound : Seq) (page : List (FeedRow C))
      (hmem : s₀ ∈ sys.server :: sys.past) (hc : sys.replica.cursor ≤ s₀.counter)
      (hfeed : IsPageFeed s₀ sys.replica.cursor bound page) :
      Reachable sys → Reachable { sys with replica := pull hash sys.replica page }
  | verify (sys : Sys C) (page : List (FeedRow C))
      (hfeed : IsHeadFeed sys.server sys.replica.cursor page) :
      Reachable sys →
      Reachable { sys with
        replica := pullVerify hash sys.replica page sys.pending
        pending := [] }
  /-- A restore with the rewind (`Replica.restore`), merge with any
  per-row decisions or overwrite, pending entries and PATCHes in flight
  allowed. `C0` is the cursor captured before the fetch: every page is
  read after it, at a state whose counter is at or above it. `hread`:
  every snapshot row is a live row some such state of the run held at
  its seq. `hall`, asked of an overwrite only: the snapshot carries, at
  its version there, every row live at one such state (the one the
  walk's last page was read at). -/
  | restore (sys : Sys C) (overwrite : Bool) (keepCloud : Id → Bool) (snap : Snapshot C)
      (C0 : Seq)
      (hread : ∀ i c S, snap i = some (c, S) →
        ∃ s' ∈ sys.server :: sys.past, s'.rows i = some ⟨c, S, false⟩ ∧ C0 ≤ s'.counter)
      (hall : overwrite = true → ∃ s' ∈ sys.server :: sys.past, C0 ≤ s'.counter ∧
        ∀ i row, s'.rows i = some row → row.deleted = false →
          snap i = some (row.content, row.seq)) :
      Reachable sys →
      Reachable { sys with replica := sys.replica.restore hash overwrite keepCloud snap C0 }

/-- What `reachable_sound` carries through the induction. -/
structure ReachInv (sys : Sys C) : Prop where
  inv : Inv sys.server sys.replica
  hashSound : BaseHashSound hash sys.server sys.replica
  tracks : BaseTracksFeed sys.server sys.replica
  held : BaseHeld hash (sys.server :: sys.past) sys.replica
  past : PastOK sys.server sys.past
  pending : ∀ p ∈ sys.pending, PendingStale sys.server p
  flights : ∀ q ∈ sys.flights, FlightSound hash (sys.server :: sys.past) sys.server sys.replica q
  distinct : sys.flights.Pairwise fun a b => a.id ≠ b.id

/-! ### Transfer lemmas -/

omit [DecidableEq C] in
theorem pastOK_step {s s' : Server C} {past : List (Server C)} (hp : PastOK s past)
    (hwf : s.WF) (a : Advances s s') : PastOK s' (s :: past) := by
  intro x hx
  rcases List.mem_cons.mp hx with h | h
  · subst h; exact ⟨hwf, a⟩
  · obtain ⟨hw, ax⟩ := hp x h; exact ⟨hw, advances_trans ax a⟩

omit [DecidableEq C] in
theorem hist_ok {s : Server C} {past : List (Server C)} (hp : PastOK s past) (hwf : s.WF)
    {s₀ : Server C} (hmem : s₀ ∈ s :: past) : s₀.WF ∧ Advances s₀ s := by
  rcases List.mem_cons.mp hmem with h | h
  · subst h; exact ⟨hwf, advances_refl _⟩
  · exact hp s₀ h

omit [DecidableEq C] in
theorem baseHeld_mono {hist hist' : List (Server C)} {r r' : Replica C}
    (hb : BaseHeld hash hist r) (hsub : ∀ x ∈ hist, x ∈ hist')
    (hbase : ∀ i h S, r'.base i = some (h, S) → r.base i = some (h, S)) :
    BaseHeld hash hist' r' := by
  intro i h S hb'
  obtain ⟨s', hs', row, hrow, hseq, hd, hh⟩ := hb i h S (hbase i h S hb')
  exact ⟨s', hsub s' hs', row, hrow, hseq, hd, hh⟩

omit [DecidableEq C] in
theorem flightSound_transfer {hist hist' : List (Server C)} {s s' : Server C}
    {r r' : Replica C} {q : Flight C}
    (hq : FlightSound hash hist s r q) (hwf : s.WF) (hc : r.cursor ≤ s.counter)
    (a : Advances s s') (hsub : ∀ x ∈ hist, x ∈ hist')
    (hbase : (r'.base q.id).map Prod.snd = some q.sentSeq →
      (r.base q.id).map Prod.snd = some q.sentSeq)
    (hcur : r'.cursor = r.cursor) :
    FlightSound hash hist' s' r' q := by
  refine ⟨fun h => pendingStale_advances hwf (hq.empty h) a, hq.live, hq.sent, hq.fresh,
    fun row h => Nat.le_trans (hq.bounded row h) a.mono, ?_, ?_, ?_, ?_⟩
  · intro row h
    obtain ⟨x, hx, hrow⟩ := hq.held row h
    exact ⟨x, hsub x hx, hrow⟩
  · intro row h
    obtain ⟨row', hrow', hle⟩ := hq.anchored row h
    obtain ⟨row'', hrow''⟩ := a.keep q.id row' hrow'
    refine ⟨row'', hrow'', ?_⟩
    rcases a.rows q.id row'' hrow'' with hold | hnew
    · rw [hrow'] at hold; cases hold; exact hle
    · exact Nat.le_trans (hq.bounded row h) (Nat.le_of_lt hnew)
  · intro row h row' hrow' hseq
    rcases a.rows q.id row' hrow' with hold | hnew
    · exact hq.same row h row' hold hseq
    · exact absurd (Nat.lt_of_lt_of_le hnew (Nat.le_of_eq hseq)) (Nat.not_lt.mpr (hq.bounded row h))
  · intro row h hcas row' hrow' hle
    rw [hcur] at hle
    rcases a.rows q.id row' hrow' with hold | hnew
    · exact hq.tracks row h (hbase hcas) row' hold hle
    · exact absurd hnew (Nat.not_lt.mpr (Nat.le_trans hle hc))

omit [DecidableEq C] in
/-- The guard's content survives a pull: if the baseline seq is still the
PATCH's after a limit-cut pull of a state the server advances from, no
server row for the id at or below the new cursor carries another seq.
A page row for the id would have moved the entry (it is newer than the
filter seq, so it is not skipped, and it is not the PATCH's own seq);
a server row past the old cursor and at or below the new one is in the
page. -/
theorem flightSound_pull {hist : List (Server C)} {s₀ s : Server C} {r : Replica C}
    {q : Flight C} (hq : FlightSound hash hist s r q) (hwf₀ : s₀.WF) (a : Advances s₀ s)
    (hc : r.cursor ≤ s₀.counter) (bound : Seq) (page : List (FeedRow C))
    (hfeed : IsPageFeed s₀ r.cursor bound page) :
    FlightSound hash hist s (pull hash r page) q := by
  refine ⟨hq.empty, hq.live, hq.sent, hq.fresh, hq.bounded, hq.held, hq.anchored, hq.same, ?_⟩
  intro row hresp hcas row' hrow' hle
  have hcur0 := pull_page_cursor_le_counter hash hwf₀ hc bound page hfeed
  have hcur1 := pull_page_cursor_le hash s₀ r bound page hfeed
  have hfresh := hq.fresh row hresp
  obtain ⟨row'', hrow'', hanc⟩ := hq.anchored row hresp
  rw [hrow'] at hrow''
  cases hrow''
  have hbase : (pull hash r page).base = (page.foldl (applyRow hash) r).base := by
    simp only [pull, hfeed.filter_self]
  rcases a.rows q.id row' hrow' with hold | hnew
  · by_cases hin : ∃ fr ∈ page, fr.id = q.id
    · exfalso
      obtain ⟨fr, hfr, hid⟩ := hin
      have hb := (foldl_self_of_mem hash page r fr hfeed.distinct hfr).2
      rw [← hbase] at hb
      rw [← hid, hb] at hcas
      have hsnd := (hfeed.sound fr hfr).1
      rw [← hid] at hold
      rw [hold] at hsnd
      cases hsnd
      simp only at hanc
      cases hs : staleOrSeen (r.base fr.id) fr.seq
      · rw [applyRow_base_self] at hcas
        rcases decideRow_base_seq_noskip fr.deleted (hash fr.content) ((r.loc fr.id).map hash)
            (r.base fr.id) fr.seq hs with hn | ⟨x, hx⟩
        · rw [hn] at hcas; cases hcas
        · rw [hx] at hcas
          simp only [Option.map_some, Option.some.injEq] at hcas
          rw [hcas] at hanc
          exact absurd (Nat.lt_of_lt_of_le hfresh hanc) (Nat.lt_irrefl _)
      · rw [applyRow_skip hash r fr hs] at hcas
        obtain ⟨h', S', hb', hle'⟩ := (staleOrSeen_true_iff _ _).mp hs
        rw [hb'] at hcas
        simp only [Option.map_some, Option.some.injEq] at hcas
        rw [hcas] at hle'
        exact absurd (Nat.lt_of_lt_of_le hfresh (Nat.le_trans hanc hle')) (Nat.lt_irrefl _)
    · have hin' : ∀ fr ∈ page, fr.id ≠ q.id := fun fr hfr hid => hin ⟨fr, hfr, hid⟩
      rw [hbase, (foldl_frame hash page r q.id hin').2] at hcas
      rcases Nat.lt_or_ge r.cursor row'.seq with hlt | hge
      · have hbd : row'.seq ≤ bound := le_bound_of_le_max (Nat.le_trans hle hcur1) hlt
        obtain ⟨fr, hfr, hfrid⟩ := hfeed.complete q.id row' hold hlt hbd
        exact absurd hfrid (hin' fr hfr)
      · exact hq.tracks row hresp hcas row' hrow' hge
  · exact absurd hnew (Nat.not_lt.mpr (Nat.le_trans hle hcur0))

omit [DecidableEq C] in
/-- Applying a page row of a state of the run keeps `BaseHeld`: a
non-skip live row writes its own `(hash, seq)`, which that state held. -/
theorem baseHeld_applyRow {hist : List (Server C)} {s₀ : Server C} (hmem : s₀ ∈ hist)
    {r : Replica C} (hb : BaseHeld hash hist r) (fr : FeedRow C)
    (hsound : s₀.rows fr.id = some ⟨fr.content, fr.seq, fr.deleted⟩) :
    BaseHeld hash hist (applyRow hash r fr) := by
  cases hs : staleOrSeen (r.base fr.id) fr.seq
  · intro i h S hbase
    by_cases hi : i = fr.id
    · subst hi
      rw [applyRow_base_noskip hash r fr hs] at hbase
      cases hd : fr.deleted
      · rw [hd] at hbase
        simp only [Bool.false_eq_true, ↓reduceIte, Option.some.injEq, Prod.mk.injEq] at hbase
        obtain ⟨rfl, rfl⟩ := hbase
        exact ⟨s₀, hmem, _, hsound, rfl, hd, rfl⟩
      · rw [hd] at hbase; cases hbase
    · rw [(applyRow_frame hash r fr i hi).2] at hbase
      exact hb i h S hbase
  · rw [applyRow_skip hash r fr hs]
    exact hb

omit [DecidableEq C] in
theorem baseHeld_pull {hist : List (Server C)} {s₀ : Server C} (hmem : s₀ ∈ hist)
    {r : Replica C} (hb : BaseHeld hash hist r) (page : List (FeedRow C))
    (hsound : ∀ fr ∈ page, s₀.rows fr.id = some ⟨fr.content, fr.seq, fr.deleted⟩) :
    BaseHeld hash hist (pull hash r page) := by
  show BaseHeld hash hist { (page.filter fun fr => decide (r.cursor < fr.seq)).foldl
    (applyRow hash) r with cursor := _ }
  have key : ∀ (rows : List (FeedRow C)) (r0 : Replica C), BaseHeld hash hist r0 →
      (∀ fr ∈ rows, s₀.rows fr.id = some ⟨fr.content, fr.seq, fr.deleted⟩) →
      BaseHeld hash hist (rows.foldl (applyRow hash) r0) := by
    intro rows
    induction rows with
    | nil => intro r0 h0 _; exact h0
    | cons fr rest ih =>
      intro r0 h0 hs
      simp only [List.foldl]
      exact ih _ (baseHeld_applyRow hash hmem h0 fr (hs fr (by simp)))
        (fun x hx => hs x (by simp [hx]))
  exact key _ r hb (fun fr hfr => hsound fr (List.mem_filter.mp hfr).1)

/-- `pushRow` changes the replica's row and baseline at its own id only,
and never the cursor. -/
theorem pushRow_frame (s : Server C) (r : Replica C) (id : Id) :
    (∀ i, i ≠ id → (pushRow hash s r id).replica.base i = r.base i)
      ∧ (pushRow hash s r id).replica.cursor = r.cursor
      ∧ (∀ i, i ≠ id → (pushRow hash s r id).replica.loc i = r.loc i) := by
  rcases pushRow_cases hash s r id with ⟨-, hp⟩
    | ⟨c, row, bh, bseq, -, -, -, -, -, hp⟩
    | ⟨c, row, bh, bseq, -, -, -, -, -, hp⟩
    | ⟨c, bh, bseq, -, -, -, hp⟩ | ⟨c, -, -, -, hp⟩ | ⟨c, -, -, hp⟩ <;> rw [hp]
  · exact ⟨fun _ _ => rfl, rfl, fun _ _ => rfl⟩
  · exact ⟨fun i hi => by simp [Replica.setBase, hi], rfl, fun _ _ => rfl⟩
  · exact ⟨fun i hi => by simp [Replica.deadRowHit, hi], rfl,
      fun i hi => by simp [Replica.deadRowHit, hi]⟩
  · exact ⟨fun _ _ => rfl, rfl, fun _ _ => rfl⟩
  · exact ⟨fun i hi => by simp [Replica.setBase, hi], rfl, fun _ _ => rfl⟩
  · exact ⟨fun _ _ => rfl, rfl, fun _ _ => rfl⟩

/-- Our own push keeps `BaseHeld`: a `[row]` writes `(hash sent, seq)` for
the live row the server now holds. -/
theorem baseHeld_pushRow {hist : List (Server C)} {s : Server C} {r : Replica C}
    (hb : BaseHeld hash hist r) (id : Id) :
    BaseHeld hash ((pushRow hash s r id).server :: hist) (pushRow hash s r id).replica := by
  have hsub : ∀ x ∈ hist, x ∈ (pushRow hash s r id).server :: hist :=
    fun x hx => List.mem_cons_of_mem _ hx
  rcases pushRow_cases hash s r id with ⟨-, hp⟩
    | ⟨c, row, bh, bseq, -, -, -, -, hd, hp⟩
    | ⟨c, row, bh, bseq, -, -, -, -, -, hp⟩
    | ⟨c, bh, bseq, -, -, -, hp⟩ | ⟨c, -, -, -, hp⟩ | ⟨c, -, -, hp⟩
  · rw [hp] at hsub ⊢; exact baseHeld_mono hash hb hsub (fun _ _ _ h => h)
  · rw [hp] at hsub ⊢
    intro i h S hbase
    simp only [Replica.setBase] at hbase
    by_cases hi : i = id
    · rw [if_pos hi] at hbase
      cases hbase
      subst hi
      exact ⟨_, List.mem_cons_self .., { content := c, seq := s.next, deleted := row.deleted },
        by simp [Server.setRow], rfl, hd, rfl⟩
    · rw [if_neg hi] at hbase
      obtain ⟨x, hx, row', h1, h2, h3, h4⟩ := hb i h S hbase
      exact ⟨x, hsub x hx, row', h1, h2, h3, h4⟩
  · rw [hp] at hsub ⊢
    refine baseHeld_mono hash hb hsub ?_
    intro i h S hbase
    simp only [Replica.deadRowHit] at hbase
    by_cases hi : i = id
    · rw [if_pos hi] at hbase; cases hbase
    · rw [if_neg hi] at hbase; exact hbase
  · rw [hp] at hsub ⊢; exact baseHeld_mono hash hb hsub (fun _ _ _ h => h)
  · rw [hp] at hsub ⊢
    intro i h S hbase
    simp only [Replica.setBase] at hbase
    by_cases hi : i = id
    · rw [if_pos hi] at hbase
      cases hbase
      subst hi
      exact ⟨_, List.mem_cons_self .., { content := c, seq := s.next, deleted := false },
        by simp [Server.setRow], rfl, rfl, rfl⟩
    · rw [if_neg hi] at hbase
      obtain ⟨x, hx, row', h1, h2, h3, h4⟩ := hb i h S hbase
      exact ⟨x, hsub x hx, row', h1, h2, h3, h4⟩
  · rw [hp] at hsub ⊢; exact baseHeld_mono hash hb hsub (fun _ _ _ h => h)

/-- A pushed delete removes at most its own entry and keeps the cursor. -/
theorem pushDelete_frame (s : Server C) (r : Replica C) (id : Id) :
    (∀ i h S, (pushDelete s r id).replica.base i = some (h, S) → r.base i = some (h, S))
      ∧ (pushDelete s r id).replica.cursor = r.cursor := by
  unfold pushDelete
  split
  · refine ⟨?_, rfl⟩
    intro i h S hb
    simp only [Replica.setBase] at hb
    by_cases hi : i = id
    · rw [if_pos hi] at hb; cases hb
    · rw [if_neg hi] at hb; exact hb
  · exact ⟨fun _ _ _ h => h, rfl⟩

omit [DecidableEq C] in
/-- `recv` changes the replica's row and baseline at the flight's id
only, and never the cursor. -/
theorem recv_frame (r : Replica C) (q : Flight C) :
    (∀ i, i ≠ q.id → (r.recv hash q).base i = r.base i) ∧ (r.recv hash q).cursor = r.cursor
      ∧ (∀ i, i ≠ q.id → (r.recv hash q).loc i = r.loc i) := by
  unfold Replica.recv
  split
  · split
    · split
      · split
        · exact ⟨fun i hi => by simp [Replica.deadRowHit, hi], rfl,
            fun i hi => by simp [Replica.deadRowHit, hi]⟩
        · exact ⟨fun i hi => by simp [Replica.setBase, hi], rfl, fun _ _ => rfl⟩
      · exact ⟨fun i hi => by simp [Replica.setBase, hi], rfl, fun _ _ => rfl⟩
    · exact ⟨fun _ _ => rfl, rfl, fun _ _ => rfl⟩
  · exact ⟨fun _ _ => rfl, rfl, fun _ _ => rfl⟩

omit [DecidableEq C] in
/-- An entry `(hash sent, row.seq)` for the row a sound flight carries
keeps `Inv`. -/
theorem inv_setBase_flight {s : Server C} {r : Replica C} (h : Inv s r) (id : Id) (hh : Hash)
    (row : Row C) (hlive : row.deleted = false) (hbd : row.seq ≤ s.counter)
    (hanc : ∃ row', s.rows id = some row' ∧ row.seq ≤ row'.seq)
    (hsame : ∀ row', s.rows id = some row' → row'.seq = row.seq → row' = row) :
    Inv s (r.setBase id (some (hh, row.seq))) := by
  refine ⟨h.wf, ?_, ?_, ?_, h.cursorBounded⟩
  · intro i h' S hb
    simp only [Replica.setBase] at hb
    by_cases hi : i = id
    · rw [if_pos hi] at hb; cases hb; exact hbd
    · rw [if_neg hi] at hb; exact h.bounded i h' S hb
  · intro i h' S row' hb hrow' hseq
    simp only [Replica.setBase] at hb
    by_cases hi : i = id
    · rw [if_pos hi] at hb; cases hb; subst hi
      rw [hsame row' hrow' hseq]; exact hlive
    · rw [if_neg hi] at hb; exact h.noDead i h' S row' hb hrow' hseq
  · intro i h' S hb
    simp only [Replica.setBase] at hb
    by_cases hi : i = id
    · rw [if_pos hi] at hb; cases hb; subst hi; exact hanc
    · rw [if_neg hi] at hb; exact h.anchored i h' S hb

omit [DecidableEq C] in
theorem flights_split {pre post : List (Flight C)} {q : Flight C}
    (hd : (pre ++ q :: post).Pairwise fun a b => a.id ≠ b.id) :
    (pre ++ post).Pairwise (fun a b => a.id ≠ b.id) ∧ ∀ q' ∈ pre ++ post, q'.id ≠ q.id := by
  rw [List.pairwise_append, List.pairwise_cons] at hd
  obtain ⟨hpre, ⟨hq, hpost⟩, hx⟩ := hd
  refine ⟨List.pairwise_append.mpr ⟨hpre, hpost, fun a ha b hb => hx a ha b (by simp [hb])⟩, ?_⟩
  intro q' hq'
  rcases List.mem_append.mp hq' with h | h
  · exact hx q' h q (by simp)
  · exact Ne.symm (hq q' h)

/-! ### The restore step's transfer lemmas -/

omit [DecidableEq C] in
/-- An entry the restore leaves is either the snapshot row's own
`(hash, seq)` or the entry the id had before. The third writing of
`replayBaseline` (overwrite, not carried) never fires: an overwrite's
local rows are the snapshot's. -/
theorem restore_base (r : Replica C) (overwrite : Bool) (keepCloud : Id → Bool)
    (snap : Snapshot C) (C0 : Seq) (i : Id) (h : Hash) (S : Seq)
    (hb : (r.restore hash overwrite keepCloud snap C0).base i = some (h, S)) :
    (∃ c, snap i = some (c, S) ∧ h = hash c) ∨ r.base i = some (h, S) := by
  simp only [Replica.restore, Replica.restoreFixedWith, Replica.restoreWith,
    Replica.restoreWithLoc, replayBaseline] at hb
  split at hb
  · -- not a local row after the restore: none after an overwrite, the
    -- entry it had after a merge
    cases hov : overwrite
    · rw [hov] at hb
      simp only [Bool.false_eq_true, ↓reduceIte] at hb
      exact Or.inr hb
    · rw [hov] at hb; cases hb
  · rename_i row hl
    split at hb
    · rename_i cloudRow seq hs
      simp only [Option.some.injEq, Prod.mk.injEq] at hb
      obtain ⟨rfl, rfl⟩ := hb
      exact Or.inl ⟨cloudRow, hs, rfl⟩
    · rename_i hs
      cases hov : overwrite
      · rw [hov] at hb
        exact Or.inr hb
      · exfalso
        simp only [restoreLoc, hov, ↓reduceIte, hs, Option.map_none] at hl
        cases hl

omit [DecidableEq C] in
theorem restore_cursor (r : Replica C) (overwrite : Bool) (keepCloud : Id → Bool)
    (snap : Snapshot C) (C0 : Seq) :
    (r.restore hash overwrite keepCloud snap C0).cursor = min r.cursor C0 := rfl

omit [DecidableEq C] in
theorem restore_shelf (r : Replica C) (overwrite : Bool) (keepCloud : Id → Bool)
    (snap : Snapshot C) (C0 : Seq) :
    (r.restore hash overwrite keepCloud snap C0).shelf = r.shelf := rfl

omit [DecidableEq C] in
/-- A row the snapshot carried, after a restore of either strategy — unless
a merge kept it a pending local delete: it is a local row, and its entry
is the cloud row's `(hash, seq)`. -/
theorem restore_carried_base (r : Replica C) (overwrite : Bool) (keepCloud : Id → Bool)
    (snap : Snapshot C) (C0 : Seq) (i : Id) (c : C) (S : Seq) (hs : snap i = some (c, S))
    (hnd : overwrite = true ∨ r.loc i ≠ none ∨ r.base i = none) :
    (r.restore hash overwrite keepCloud snap C0).base i = some (hash c, S)
      ∧ ∃ l, (r.restore hash overwrite keepCloud snap C0).loc i = some l := by
  have hl : ∃ l, (r.restore hash overwrite keepCloud snap C0).loc i = some l := by
    show ∃ l, restoreLoc overwrite keepCloud snap r.base r.loc i = some l
    unfold restoreLoc
    cases hov : overwrite
    · simp only [Bool.false_eq_true, ↓reduceIte]
      rw [hs]
      cases hlo : r.loc i with
      | none =>
        have hb : r.base i = none := by
          rcases hnd with h | h | h
          · rw [hov] at h; cases h
          · exact absurd hlo h
          · exact h
        simp [hb]
      | some row => cases keepCloud i <;> simp
    · simp [hs]
  obtain ⟨l, hl'⟩ := hl
  refine ⟨?_, l, hl'⟩
  show replayBaseline hash overwrite snap r.base
    (r.restore hash overwrite keepCloud snap C0).loc i = _
  simp only [replayBaseline, hl', hs]

omit [DecidableEq C] in
/-- A merge loses no entry: every id that had one has one after — the
cloud row's, or the one it had (a row the snapshot did not carry, a
pending local delete). -/
theorem restore_merge_base_kept (r : Replica C) (keepCloud : Id → Bool) (snap : Snapshot C)
    (C0 : Seq) (i : Id) (hb : r.base i ≠ none) :
    (r.restore hash false keepCloud snap C0).base i ≠ none := by
  show replayBaseline hash false snap r.base (r.restore hash false keepCloud snap C0).loc i ≠ none
  unfold replayBaseline
  split
  · simpa using hb
  · split
    · simp
    · simpa using hb

omit [DecidableEq C] in
/-- A live row some state of the run held, seen from the current server:
its seq was handed out, the server's row for the id is at or above it,
and a server row for the id carrying that seq IS that row. -/
theorem held_row_now {s : Server C} {past : List (Server C)} (hp : PastOK s past)
    (hwf : s.WF) {i : Id} {c : C} {S : Seq}
    (hheld : ∃ s' ∈ s :: past, s'.rows i = some ⟨c, S, false⟩) :
    S ≤ s.counter ∧ (∃ row, s.rows i = some row ∧ S ≤ row.seq)
      ∧ ∀ row, s.rows i = some row → row.seq = S → row = ⟨c, S, false⟩ := by
  obtain ⟨s', hmem, hrow⟩ := hheld
  obtain ⟨hwf', a⟩ := hist_ok hp hwf hmem
  have hS : S ≤ s'.counter := hwf' i _ hrow
  refine ⟨Nat.le_trans hS a.mono, ?_, ?_⟩
  · obtain ⟨row', hrow'⟩ := a.keep i _ hrow
    refine ⟨row', hrow', ?_⟩
    rcases a.rows i row' hrow' with hold | hnew
    · rw [hrow] at hold; cases hold; exact Nat.le_refl _
    · exact Nat.le_of_lt (Nat.lt_of_le_of_lt hS hnew)
  · intro row hrow' hseq
    rcases a.rows i row hrow' with hold | hnew
    · rw [hrow] at hold; cases hold; rfl
    · rw [hseq] at hnew; exact absurd (Nat.lt_of_le_of_lt hS hnew) (Nat.lt_irrefl _)

omit [DecidableEq C] in
/-- The rewind's whole content: a snapshot row read from a state whose
counter is at or above the cursor has no newer version at or below it —
a newer version carries a seq above that state's counter. So after a
restore whose cursor is at most `C0`, and whose rows were read at states
at or above `C0`, a server row for a snapshot id at or below the cursor
carries the snapshot's seq: the entry the replay writes tracks the feed. -/
theorem restore_fresh_of_read_above_cursor {s : Server C} {past : List (Server C)}
    (hp : PastOK s past) (hwf : s.WF) (cursor : Seq) (snap : Snapshot C)
    (hread : ∀ i c S, snap i = some (c, S) →
      ∃ s' ∈ s :: past, s'.rows i = some ⟨c, S, false⟩ ∧ cursor ≤ s'.counter) :
    ∀ i c S, snap i = some (c, S) → ∀ row, s.rows i = some row → row.seq ≤ cursor →
      row.seq = S := by
  intro i c S hs row hrow hle
  obtain ⟨s', hmem, hrow', hcur⟩ := hread i c S hs
  obtain ⟨-, a⟩ := hist_ok hp hwf hmem
  rcases a.rows i row hrow with hold | hnew
  · rw [hrow'] at hold; cases hold; rfl
  · exact absurd (Nat.lt_of_le_of_lt (Nat.le_trans hle hcur) hnew) (Nat.lt_irrefl _)

/-! ### The verify pass on reachable states -/

omit [DecidableEq C] in
theorem foldl_verify_id (L : List Pending) (r : Replica C)
    (h : ∀ p ∈ L, r.verifyUnseen p = r) : L.foldl Replica.verifyUnseen r = r := by
  induction L with
  | nil => rfl
  | cons p rest ih =>
    simp only [List.foldl]
    rw [h p (by simp)]
    exact ih (fun x hx => h x (by simp [hx]))

omit [DecidableEq C] in
/-- With every entry stale and the baseline tracking the feed, the verify
pass after a head pull of the current server drops every entry: an
unseen id's server row sits at or below the cursor, tracking puts the
baseline on its seq, and that seq is above the sent one — so
`base.seq == sentSeq` never holds and the confirm branch never fires. -/
theorem pullVerify_eq_pull_of_stale {s : Server C} {r : Replica C} (hinv : Inv s r)
    (ht : BaseTracksFeed s r) (page : List (FeedRow C)) (hfeed : IsHeadFeed s r.cursor page)
    (pending : List Pending) (hp : ∀ p ∈ pending, PendingStale s p) :
    pullVerify hash r page pending = pull hash r page := by
  have ht1 : BaseTracksFeed s (pull hash r page) :=
    baseTracksFeed_pull_page hash hinv.wf hinv.cursorBounded s.counter page
      (hfeed.page hinv.wf) (advances_refl s) hinv ht
  unfold pullVerify
  apply foldl_verify_id
  intro p hpm
  obtain ⟨hmem, hunseen⟩ := List.mem_filter.mp hpm
  have hunseen' : p.id ∉ seenIds r page := by simpa using hunseen
  obtain ⟨row, hrow, hlt⟩ := hp p hmem
  have hle : row.seq ≤ r.cursor := by
    apply Nat.le_of_not_lt
    intro hgt
    obtain ⟨fr, hfr, hid⟩ := hfeed.complete p.id row hrow hgt
    apply hunseen'
    unfold seenIds
    exact List.mem_map.mpr ⟨fr, List.mem_filter.mpr ⟨hfr, by simp [(hfeed.sound fr hfr).2]⟩, hid⟩
  have hle1 := Nat.le_trans hle (pull_cursor_ge hash r page)
  unfold Replica.verifyUnseen
  split
  · rename_i h0 S0 hb0
    have hseq := ht1 p.id h0 S0 row hb0 hrow hle1
    have hne : S0 ≠ p.sentSeq := by
      intro heq
      rw [heq] at hseq
      rw [hseq] at hlt
      exact Nat.lt_irrefl _ hlt
    simp [hne]
  · rfl

/-! ### The restore step keeps the invariant -/

omit [DecidableEq C] in
/-- The restore case of the induction, on its own: it needs `hread`
only — not `hall`, which only `baseCovers_of_reachable` uses, for an
overwrite — so the truthfulness half holds for a snapshot missing rows
too. The entries
the replay writes are the snapshot rows' own `(hash, seq)`, held at
states at or above `C0`; the rewound cursor is at most `C0`, so no newer
version of such a row sits at or below it
(`restore_fresh_of_read_above_cursor`); every other entry is one the id
had, and lowering the cursor only shrinks what `BaseTracksFeed` and a
flight's `tracks` speak about. -/
theorem reachInv_restore {sys : Sys C} (ih : ReachInv hash sys) (overwrite : Bool)
    (keepCloud : Id → Bool) (snap : Snapshot C) (C0 : Seq)
    (hread : ∀ i c S, snap i = some (c, S) →
      ∃ s' ∈ sys.server :: sys.past, s'.rows i = some ⟨c, S, false⟩ ∧ C0 ≤ s'.counter) :
    ReachInv hash { sys with replica := sys.replica.restore hash overwrite keepCloud snap C0 } := by
  have hwf := ih.inv.wf
  have hle0 : min sys.replica.cursor C0 ≤ sys.replica.cursor := Nat.min_le_left _ _
  have hnow : ∀ i c S, snap i = some (c, S) →
      S ≤ sys.server.counter ∧ (∃ row, sys.server.rows i = some row ∧ S ≤ row.seq)
        ∧ ∀ row, sys.server.rows i = some row → row.seq = S → row = ⟨c, S, false⟩ :=
    fun i c S hs =>
      held_row_now ih.past hwf (let ⟨s', hm, hr, _⟩ := hread i c S hs; ⟨s', hm, hr⟩)
  have hfresh : ∀ i c S, snap i = some (c, S) → ∀ row, sys.server.rows i = some row →
      row.seq ≤ min sys.replica.cursor C0 → row.seq = S :=
    restore_fresh_of_read_above_cursor ih.past hwf _ snap fun i c S hs =>
      let ⟨s', hm, hr, hC⟩ := hread i c S hs
      ⟨s', hm, hr, Nat.le_trans (Nat.min_le_right _ _) hC⟩
  have hb := restore_base hash sys.replica overwrite keepCloud snap C0
  refine ⟨⟨hwf, ?_, ?_, ?_, Nat.le_trans hle0 ih.inv.cursorBounded⟩, ?_, ?_, ?_, ih.past,
    ih.pending, ?_, ih.distinct⟩
  · -- bounded
    intro i h S hbase
    rcases hb i h S hbase with ⟨c, hs, -⟩ | hold
    · exact (hnow i c S hs).1
    · exact ih.inv.bounded i h S hold
  · -- noDead
    intro i h S row hbase hrow hseq
    rcases hb i h S hbase with ⟨c, hs, -⟩ | hold
    · rw [(hnow i c S hs).2.2 row hrow hseq]
    · exact ih.inv.noDead i h S row hold hrow hseq
  · -- anchored
    intro i h S hbase
    rcases hb i h S hbase with ⟨c, hs, -⟩ | hold
    · exact (hnow i c S hs).2.1
    · exact ih.inv.anchored i h S hold
  · -- hashSound
    intro i h S row hbase hrow hseq
    rcases hb i h S hbase with ⟨c, hs, rfl⟩ | hold
    · rw [(hnow i c S hs).2.2 row hrow hseq]
    · exact ih.hashSound i h S row hold hrow hseq
  · -- tracks: the snapshot's own seq by the rewind, the rest under a lower cursor
    intro i h S row hbase hrow hle
    rcases hb i h S hbase with ⟨c, hs, -⟩ | hold
    · exact hfresh i c S hs row hrow hle
    · exact ih.tracks i h S row hold hrow (Nat.le_trans hle hle0)
  · -- held
    intro i h S hbase
    rcases hb i h S hbase with ⟨c, hs, rfl⟩ | hold
    · obtain ⟨s', hs', hrow, -⟩ := hread i c S hs
      exact ⟨s', hs', _, hrow, rfl, rfl, rfl⟩
    · exact ih.held i h S hold
  · -- flights: every field but `tracks` is about the server and the run;
    -- an entry the restore wrote at the PATCH's seq is the snapshot's,
    -- and the server's row for the id is past that seq, hence past the
    -- rewound cursor
    intro q hq
    have hfs := ih.flights q hq
    refine ⟨hfs.empty, hfs.live, hfs.sent, hfs.fresh, hfs.bounded, hfs.held, hfs.anchored,
      hfs.same, ?_⟩
    intro row hresp hcas row' hrow' hle
    cases hbq : (sys.replica.restore hash overwrite keepCloud snap C0).base q.id with
    | none => rw [hbq] at hcas; cases hcas
    | some e =>
      obtain ⟨h, S⟩ := e
      rw [hbq] at hcas
      simp only [Option.map_some, Option.some.injEq] at hcas
      subst hcas
      rcases hb q.id h q.sentSeq hbq with ⟨c, hs, -⟩ | hold
      · exfalso
        have hseq := hfresh q.id c q.sentSeq hs row' hrow' hle
        obtain ⟨row'', hrow'', hanc⟩ := hfs.anchored row hresp
        rw [hrow'] at hrow''
        cases hrow''
        rw [hseq] at hanc
        exact absurd (Nat.lt_of_lt_of_le (hfs.fresh row hresp) hanc) (Nat.lt_irrefl _)
      · exact hfs.tracks row hresp (by rw [hold]; rfl) row' hrow' (Nat.le_trans hle hle0)

/-! ### The invariant -/

/-- THE INDUCTION: every reachable state satisfies `ReachInv`. -/
theorem reachInv_of_reachable {sys : Sys C} (h : Reachable hash sys) : ReachInv hash sys := by
  induction h with
  | init s r hwf hb hc _ =>
    refine ⟨inv_initial s r hwf hb hc, ?_, baseTracksFeed_initial s r hb, ?_, ?_, by simp,
      by simp, List.Pairwise.nil⟩
    · intro i hh S row hbase; rw [hb i] at hbase; cases hbase
    · intro i hh S hbase; rw [hb i] at hbase; cases hbase
    · intro x hx; cases hx
  | peer sys op _ ih =>
    have a := step_advances sys.server op
    have hwf := ih.inv.wf
    have hc := ih.inv.cursorBounded
    have hsub : ∀ x ∈ sys.server :: sys.past, x ∈ sys.server.step op :: sys.server :: sys.past :=
      fun x hx => List.mem_cons_of_mem _ hx
    exact ⟨inv_step ih.inv op, baseHashSound_step hash ih.inv ih.hashSound op,
      baseTracksFeed_step ih.inv ih.tracks op,
      baseHeld_mono hash ih.held hsub (fun _ _ _ h => h),
      pastOK_step ih.past hwf a,
      fun p hp => pendingStale_advances hwf (ih.pending p hp) a,
      fun q hq => flightSound_transfer hash (ih.flights q hq) hwf hc a hsub (fun h => h) rfl,
      ih.distinct⟩
  | edit sys id c _ ih =>
    exact ⟨inv_of_same_seqs ih.inv (fun _ => rfl) rfl, ih.hashSound, ih.tracks, ih.held,
      ih.past, ih.pending,
      fun q hq => flightSound_transfer hash (ih.flights q hq) ih.inv.wf ih.inv.cursorBounded
        (advances_refl _) (fun x hx => hx) (fun h => h) rfl, ih.distinct⟩
  | deleteLocal sys id _ ih =>
    exact ⟨inv_of_same_seqs ih.inv (fun _ => rfl) rfl, ih.hashSound, ih.tracks, ih.held,
      ih.past, ih.pending,
      fun q hq => flightSound_transfer hash (ih.flights q hq) ih.inv.wf ih.inv.cursorBounded
        (advances_refl _) (fun x hx => hx) (fun h => h) rfl, ih.distinct⟩
  | push sys id hfree _ ih =>
    have a := pushRow_advances hash sys.server sys.replica id
    have hwf := ih.inv.wf
    have hc := ih.inv.cursorBounded
    have hsub : ∀ x ∈ sys.server :: sys.past,
        x ∈ (pushRow hash sys.server sys.replica id).server :: sys.server :: sys.past :=
      fun x hx => List.mem_cons_of_mem _ hx
    obtain ⟨hfr, hcur, -⟩ := pushRow_frame hash sys.server sys.replica id
    refine ⟨inv_pushRow hash ih.inv id, baseHashSound_pushRow hash ih.inv ih.hashSound id,
      baseTracksFeed_pushRow hash ih.inv ih.tracks id,
      baseHeld_pushRow hash ih.held id, pastOK_step ih.past hwf a, ?_, ?_, ih.distinct⟩
    · intro p hpm
      rcases List.mem_append.mp hpm with hold | hnew
      · exact pendingStale_advances hwf (ih.pending p hold) a
      · exact pendingStale_pushRow hash ih.inv ih.hashSound id p (by simpa using hnew)
    · intro q hq
      refine flightSound_transfer hash (ih.flights q hq) hwf hc a hsub ?_ hcur
      rw [hfr q.id (hfree q hq)]
      exact fun h => h
  | send sys id c bh bseq hloc hbase hdirty hfree _ ih =>
    have a := patch_advances sys.server id bseq c
    have hwf := ih.inv.wf
    have hc := ih.inv.cursorBounded
    have hsub : ∀ x ∈ sys.server :: sys.past,
        x ∈ (sys.server.patch id bseq c).1 :: sys.server :: sys.past :=
      fun x hx => List.mem_cons_of_mem _ hx
    refine ⟨inv_of_advances ih.inv a, baseHashSound_advances hash ih.inv ih.hashSound a,
      baseTracksFeed_advances ih.tracks hc a,
      baseHeld_mono hash ih.held hsub (fun _ _ _ h => h), pastOK_step ih.past hwf a,
      fun p hp => pendingStale_advances hwf (ih.pending p hp) a, ?_, ?_⟩
    · intro q hq
      rcases List.mem_append.mp hq with hold | hnew
      · exact flightSound_transfer hash (ih.flights q hold) hwf hc a hsub (fun h => h) rfl
      · simp only [List.mem_singleton] at hnew
        subst hnew
        rcases patch_outcomes sys.server id bseq c with ⟨row0, hrow0, hseq0, hpatch⟩ | hpatch
        · have hlive0 : row0.deleted = false := ih.inv.noDead id bh bseq row0 hbase hrow0 hseq0
          have hbd := ih.inv.bounded id bh bseq hbase
          simp only [hpatch]
          refine ⟨fun h => (by cases h), fun row h => ?_, fun row h => ?_, fun row h => ?_,
            fun row h => ?_, fun row h => ?_, fun row h => ?_, fun row h => ?_, fun row h => ?_⟩
          · cases h; exact hlive0
          · cases h; rfl
          · cases h; exact Nat.lt_succ_of_le hbd
          · cases h; exact Nat.le_refl _
          · cases h; exact ⟨_, List.mem_cons_self .., by simp [Server.setRow]⟩
          · cases h; exact ⟨_, by simp [Server.setRow], Nat.le_refl _⟩
          · cases h
            intro row' hrow' _
            simp only [Server.setRow, ↓reduceIte, Option.some.injEq] at hrow'
            exact hrow'.symm
          · cases h
            intro _ row' hrow' _
            simp only [Server.setRow, ↓reduceIte, Option.some.injEq] at hrow'
            rw [← hrow']
        · have hempty : (sys.server.patch id bseq c).2 = none := by rw [hpatch]
          obtain ⟨row, hrow, hlt⟩ :=
            patch_empty_stale hash ih.inv ih.hashSound id c bh bseq hbase hdirty hempty
          refine ⟨fun _ => ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
          · rw [hpatch]; exact ⟨row, hrow, hlt⟩
          all_goals
            intro row' h
            change (sys.server.patch id bseq c).2 = some row' at h
            rw [hempty] at h
            cases h
    · rw [List.pairwise_append]
      refine ⟨ih.distinct, List.pairwise_singleton _ _, ?_⟩
      intro a ha b hb
      simp only [List.mem_singleton] at hb
      subst hb
      exact hfree a ha
  | recv sys pre post q hq _ ih =>
    have hqm : q ∈ sys.flights := by rw [hq]; simp
    have hfs := ih.flights q hqm
    have hd := ih.distinct
    rw [hq] at hd
    obtain ⟨hd', hne⟩ := flights_split hd
    obtain ⟨hfr, hcur, -⟩ := recv_frame hash sys.replica q
    have hother : ∀ q' ∈ pre ++ post, FlightSound hash (sys.server :: sys.past) sys.server
        (sys.replica.recv hash q) q' := by
      intro q' hq'
      have hq'm : q' ∈ sys.flights := by
        rw [hq]; rcases List.mem_append.mp hq' with h | h <;> simp [h]
      refine flightSound_transfer hash (ih.flights q' hq'm) ih.inv.wf ih.inv.cursorBounded
        (advances_refl _) (fun x hx => hx) ?_ hcur
      rw [hfr q'.id (hne q' hq')]
      exact fun h => h
    have hpend : ∀ p ∈ sys.pending ++ q.toPending hash, PendingStale sys.server p := by
      intro p hp
      rcases List.mem_append.mp hp with h | h
      · exact ih.pending p h
      · unfold Flight.toPending at h
        split at h
        · cases h
        · rename_i hresp
          simp only [List.mem_singleton] at h
          subst h
          exact hfs.empty hresp
    cases hresp : q.resp with
    | none =>
      have hr : sys.replica.recv hash q = sys.replica := by
        unfold Replica.recv; rw [hresp]
      refine ⟨?_, ?_, ?_, ?_, ih.past, hpend, hother, hd'⟩ <;> simp only [hr]
      · exact ih.inv
      · exact ih.hashSound
      · exact ih.tracks
      · exact ih.held
    | some row =>
      have hlive := hfs.live row hresp
      by_cases hcas : (sys.replica.base q.id).map Prod.snd = some q.sentSeq
      · have hr : sys.replica.recv hash q
            = sys.replica.setBase q.id (some (hash q.sent, row.seq)) := by
          unfold Replica.recv; simp [hresp, hcas, hlive]
        refine ⟨?_, ?_, ?_, ?_, ih.past, hpend, hother, hd'⟩ <;> simp only [hr]
        · exact inv_setBase_flight ih.inv q.id _ row hlive (hfs.bounded row hresp)
            (hfs.anchored row hresp) (hfs.same row hresp)
        · intro i hh S row' hb hrow' hseq
          simp only [Replica.setBase] at hb
          by_cases hi : i = q.id
          · rw [if_pos hi] at hb; cases hb; subst hi
            rw [hfs.same row hresp row' hrow' hseq, hfs.sent row hresp]
          · rw [if_neg hi] at hb; exact ih.hashSound i hh S row' hb hrow' hseq
        · intro i hh S row' hb hrow' hle
          simp only [Replica.setBase] at hb hle
          by_cases hi : i = q.id
          · rw [if_pos hi] at hb; cases hb; subst hi
            exact hfs.tracks row hresp hcas row' hrow' hle
          · rw [if_neg hi] at hb; exact ih.tracks i hh S row' hb hrow' hle
        · intro i hh S hb
          simp only [Replica.setBase] at hb
          by_cases hi : i = q.id
          · rw [if_pos hi] at hb; cases hb; subst hi
            obtain ⟨x, hx, hrow⟩ := hfs.held row hresp
            exact ⟨x, hx, row, hrow, rfl, hlive, by rw [hfs.sent row hresp]⟩
          · rw [if_neg hi] at hb; exact ih.held i hh S hb
      · have hr : sys.replica.recv hash q = sys.replica := by
          unfold Replica.recv; simp [hresp, hcas]
        refine ⟨?_, ?_, ?_, ?_, ih.past, hpend, hother, hd'⟩ <;> simp only [hr]
        · exact ih.inv
        · exact ih.hashSound
        · exact ih.tracks
        · exact ih.held
  | lose sys pre post q hq _ ih =>
    have hd := ih.distinct
    rw [hq] at hd
    obtain ⟨hd', -⟩ := flights_split hd
    refine ⟨ih.inv, ih.hashSound, ih.tracks, ih.held, ih.past, ih.pending, ?_, hd'⟩
    intro q' hq'
    apply ih.flights
    rw [hq]; rcases List.mem_append.mp hq' with h | h <;> simp [h]
  | pushDelete sys id _ ih =>
    have a := pushDelete_advances sys.server sys.replica id
    have hwf := ih.inv.wf
    have hc := ih.inv.cursorBounded
    have hsub : ∀ x ∈ sys.server :: sys.past,
        x ∈ (pushDelete sys.server sys.replica id).server :: sys.server :: sys.past :=
      fun x hx => List.mem_cons_of_mem _ hx
    obtain ⟨hfr, hcur⟩ := pushDelete_frame sys.server sys.replica id
    refine ⟨inv_pushDelete ih.inv id, baseHashSound_pushDelete hash ih.inv ih.hashSound id,
      baseTracksFeed_pushDelete ih.inv ih.tracks id, baseHeld_mono hash ih.held hsub hfr,
      pastOK_step ih.past hwf a, fun p hp => pendingStale_advances hwf (ih.pending p hp) a,
      ?_, ih.distinct⟩
    intro q hq
    refine flightSound_transfer hash (ih.flights q hq) hwf hc a hsub ?_ hcur
    intro hcas
    cases hb' : (pushDelete sys.server sys.replica id).replica.base q.id with
    | none => rw [hb'] at hcas; cases hcas
    | some b =>
      obtain ⟨bh, bs⟩ := b
      rw [hb'] at hcas
      rw [hfr q.id bh bs hb']
      exact hcas
  | pull sys s₀ bound page hmem hc hfeed _ ih =>
    obtain ⟨hwf₀, a⟩ := hist_ok ih.past ih.inv.wf hmem
    have hsound : ∀ fr ∈ page, s₀.rows fr.id = some ⟨fr.content, fr.seq, fr.deleted⟩ :=
      fun fr hfr => (hfeed.sound fr hfr).1
    exact ⟨inv_pull_sound hash hwf₀ a ih.inv page hsound,
      baseHashSound_pull hash hwf₀ a ih.hashSound page hsound,
      baseTracksFeed_pull_page hash hwf₀ hc bound page hfeed a ih.inv ih.tracks,
      baseHeld_pull hash hmem ih.held page hsound, ih.past, ih.pending,
      fun q hq => flightSound_pull hash (ih.flights q hq) hwf₀ a hc bound page hfeed,
      ih.distinct⟩
  | verify sys page hfeed _ ih =>
    have heq := pullVerify_eq_pull_of_stale hash ih.inv ih.tracks page hfeed sys.pending
      ih.pending
    have hwf := ih.inv.wf
    have hc := ih.inv.cursorBounded
    have hfeed' := hfeed.page hwf
    have hmem : sys.server ∈ sys.server :: sys.past := List.mem_cons_self ..
    have hsound : ∀ fr ∈ page, sys.server.rows fr.id = some ⟨fr.content, fr.seq, fr.deleted⟩ :=
      fun fr hfr => (hfeed.sound fr hfr).1
    refine ⟨?_, ?_, ?_, ?_, ih.past, by simp, ?_, ih.distinct⟩ <;> simp only [heq]
    · exact inv_pull_sound hash hwf (advances_refl _) ih.inv page hsound
    · exact baseHashSound_pull hash hwf (advances_refl _) ih.hashSound page hsound
    · exact baseTracksFeed_pull_page hash hwf hc _ page hfeed' (advances_refl _) ih.inv ih.tracks
    · exact baseHeld_pull hash hmem ih.held page hsound
    · exact fun q hq => flightSound_pull hash (ih.flights q hq) hwf (advances_refl _) hc _ page
        hfeed'
  | restore sys overwrite keepCloud snap C0 hread _ _ ih =>
    exact reachInv_restore hash ih overwrite keepCloud snap C0 hread

/-- THEOREM (every reachable state tells the truth): on every state
`Reachable` reaches — late PATCH responses under the guard and restores
included —
the reachability invariant, `BaseHashSound` with no exception,
`BaseTracksFeed`, `BaseHeld` (every baseline entry is a live version a
state of the run held at that seq, with that hash), and every pending
entry is stale, hence sound. A statement about the writers the model has
(the section header lists what is not among them). -/
theorem reachable_sound {sys : Sys C} (h : Reachable hash sys) :
    Inv sys.server sys.replica ∧ BaseHashSound hash sys.server sys.replica
      ∧ BaseTracksFeed sys.server sys.replica
      ∧ BaseHeld hash (sys.server :: sys.past) sys.replica
      ∧ (∀ p ∈ sys.pending, PendingStale sys.server p ∧ PendingSound hash sys.server p) := by
  have hr := reachInv_of_reachable hash h
  exact ⟨hr.inv, hr.hashSound, hr.tracks, hr.held,
    fun p hp => ⟨hr.pending p hp, pendingStale_sound hash hr.inv.wf (hr.pending p hp)⟩⟩

/-- THEOREM (the confirm branch is dead on reachable states): on a
reachable state, the verify pass after an eligible pull changes nothing
beyond the pull — every entry is dropped. With one hash function a PATCH
`[]` on a dirty row is staleness (`patch_empty_stale`); the branch that
writes `sentHash` exists for the hash-encoding change, which T9a covers
and `Reachable` does not contain. -/
theorem reachable_verify_is_pull {sys : Sys C} (h : Reachable hash sys) (page : List (FeedRow C))
    (hfeed : IsHeadFeed sys.server sys.replica.cursor page) :
    pullVerify hash sys.replica page sys.pending = pull hash sys.replica page := by
  have hr := reachInv_of_reachable hash h
  exact pullVerify_eq_pull_of_stale hash hr.inv hr.tracks page hfeed sys.pending hr.pending

/-- THEOREM (clean means equal to the server — "本机脏 ⟺ 本地 ≠ 服务端",
for the six id tables): on a reachable state, at an id whose server row
still carries the baseline's seq, the id is clean exactly when the local
row is the server's live content — after a restore too. Under the
superseded writing this fails right after a conflict and a revert
(`conflict_then_revert_reads_clean_witness`, `keep_hash_state_not_sound`),
and under slice 1's restore replay right after the restore
(`slice1_collision_clean_control`). -/
theorem clean_iff_matches_server (hinj : HashInjective hash) {sys : Sys C}
    (hreach : Reachable hash sys) (i : Id) (h : Hash) (S : Seq) (row : Row C)
    (hbase : sys.replica.base i = some (h, S)) (hrow : sys.server.rows i = some row)
    (hseq : row.seq = S) :
    CleanAt hash sys.replica i ↔ sys.replica.loc i = sys.server.live i := by
  obtain ⟨hinv, hbh, -⟩ := reachable_sound hash hreach
  have hh : h = hash row.content := hbh i h S row hbase hrow hseq
  have hd : row.deleted = false := hinv.noDead i h S row hbase hrow hseq
  have hlive : sys.server.live i = some row.content := by simp [Server.live, hrow, hd]
  rw [hlive]
  unfold CleanAt
  rw [hbase, hh]
  constructor
  · intro hc
    cases hl : sys.replica.loc i with
    | none => rw [hl] at hc; cases hc
    | some l =>
      rw [hl] at hc
      simp only [Option.map_some, Option.some.injEq] at hc
      rw [hinj _ _ hc]
  · intro hl
    rw [hl]
    rfl

/-! ### In sync below the cursor

`SyncedBelow` — the local row is the server's live content at every id
whose server row is at or below the cursor — is not true of every
reachable replica: a dirty row (an edit not yet sent, a keepLocal
collision a restore left) differs from the server by design. What is
true of every reachable replica is the clean half of it
(`clean_synced_at`), which rests on one more invariant: every live
server row at or below the cursor has an entry (`BaseCoversBelow`). So an
all-clean reachable replica is in sync below its cursor
(`synced_below_of_clean`), and T5 / T5' on reachable states need no
`SyncedBelow` premise. -/

omit [DecidableEq C] in
/-- Every LIVE server row at or below the cursor has a baseline entry.
With `BaseTracksFeed`, `BaseHashSound` and `NoDeadBase` it makes the
baseline below the cursor a description of the server there. A restore
without the rewind breaks it (`overwrite_drops_pulled_row_control`). -/
def BaseCoversBelow (s : Server C) (r : Replica C) : Prop :=
  ∀ i row, s.rows i = some row → row.seq ≤ r.cursor → row.deleted = false → r.base i ≠ none

omit [DecidableEq C] in
/-- A server write, a cursor that does not move up, and entries lost only
where the new server row is not a live row below the new cursor. -/
theorem baseCovers_transfer {s s' : Server C} {r r' : Replica C} (h : BaseCoversBelow s r)
    (hc : r.cursor ≤ s.counter) (a : Advances s s') (hcur : r'.cursor ≤ r.cursor)
    (hkeep : ∀ i row, s'.rows i = some row → row.seq ≤ r'.cursor → row.deleted = false →
      r.base i ≠ none → r'.base i ≠ none) :
    BaseCoversBelow s' r' := by
  intro i row hrow hle hlive
  rcases a.rows i row hrow with hold | hnew
  · exact hkeep i row hrow hle hlive (h i row hold (Nat.le_trans hle hcur) hlive)
  · exact absurd (Nat.lt_of_le_of_lt (Nat.le_trans (Nat.le_trans hle hcur) hc) hnew)
      (Nat.lt_irrefl _)

omit [DecidableEq C] in
/-- A pull of a page of a state the server advances from: a live row the
new cursor passes is either below the old cursor (its entry stays — the
page does not carry it) or in the page (applying it, or skipping it,
leaves an entry). -/
theorem baseCovers_pull {s₀ s : Server C} {r : Replica C} (hwf₀ : s₀.WF) (a : Advances s₀ s)
    (hc : r.cursor ≤ s₀.counter) (bound : Seq) (page : List (FeedRow C))
    (hfeed : IsPageFeed s₀ r.cursor bound page) (h : BaseCoversBelow s r) :
    BaseCoversBelow s (pull hash r page) := by
  intro i row hrow hle hlive
  have hcur0 := pull_page_cursor_le_counter hash hwf₀ hc bound page hfeed
  have hcur1 := pull_page_cursor_le hash s₀ r bound page hfeed
  have hrow0 : s₀.rows i = some row := by
    rcases a.rows i row hrow with hold | hnew
    · exact hold
    · exact absurd (Nat.lt_of_le_of_lt (Nat.le_trans hle hcur0) hnew) (Nat.lt_irrefl _)
  have hbase : (pull hash r page).base = (page.foldl (applyRow hash) r).base := by
    simp only [pull, hfeed.filter_self]
  rw [hbase]
  by_cases hin : ∃ fr ∈ page, fr.id = i
  · obtain ⟨fr, hfr, hid⟩ := hin
    have hb := (foldl_self_of_mem hash page r fr hfeed.distinct hfr).2
    subst hid
    rw [hb]
    have hs := (hfeed.sound fr hfr).1
    rw [hrow0] at hs
    cases hs
    cases hst : staleOrSeen (r.base fr.id) fr.seq
    · rw [applyRow_base_noskip hash r fr hst]
      simp only at hlive
      simp [hlive]
    · rw [applyRow_skip hash r fr hst]
      obtain ⟨h', S', hb', -⟩ := (staleOrSeen_true_iff _ _).mp hst
      rw [hb']
      simp
  · have hin' : ∀ fr ∈ page, fr.id ≠ i := fun fr hfr hid => hin ⟨fr, hfr, hid⟩
    rw [(foldl_frame hash page r i hin').2]
    rcases Nat.lt_or_ge r.cursor row.seq with hlt | hge
    · exfalso
      have hbd : row.seq ≤ bound := le_bound_of_le_max (Nat.le_trans hle hcur1) hlt
      obtain ⟨fr, hfr, hfrid⟩ := hfeed.complete i row hrow0 hlt hbd
      exact hin' fr hfr hfrid
    · exact h i row hrow hge hlive

/-- Our push: the dead-row hit drops the entry, and only for a row the
server now holds dead. -/
theorem baseCovers_pushRow {s : Server C} {r : Replica C} (h : BaseCoversBelow s r)
    (hc : r.cursor ≤ s.counter) (id : Id) :
    BaseCoversBelow (pushRow hash s r id).server (pushRow hash s r id).replica := by
  obtain ⟨hfr, hcur, -⟩ := pushRow_frame hash s r id
  refine baseCovers_transfer h hc (pushRow_advances hash s r id) (Nat.le_of_eq hcur) ?_
  intro i row hrow _ hlive hb
  by_cases hi : i = id
  · subst hi
    rcases pushRow_cases hash s r i with ⟨-, hp⟩
      | ⟨c, row0, bh, bseq, -, -, -, -, -, hp⟩
      | ⟨c, row0, bh, bseq, -, -, -, -, hd, hp⟩
      | ⟨c, bh, bseq, -, -, -, hp⟩ | ⟨c, -, -, -, hp⟩ | ⟨c, -, -, hp⟩ <;> rw [hp] at hrow ⊢
    · exact hb
    · simp [Replica.setBase]
    · exfalso
      simp only [Server.setRow, ↓reduceIte, Option.some.injEq] at hrow
      subst hrow
      simp only at hlive
      rw [hd] at hlive
      cases hlive
    · exact hb
    · simp [Replica.setBase]
    · exact hb
  · rw [hfr i hi]; exact hb

/-- Our pushed delete: the entry goes only where the server's row is now
dead, or where there is none. -/
theorem baseCovers_pushDelete {s : Server C} {r : Replica C} (h : BaseCoversBelow s r)
    (hc : r.cursor ≤ s.counter) (id : Id) :
    BaseCoversBelow (pushDelete s r id).server (pushDelete s r id).replica := by
  refine baseCovers_transfer h hc (pushDelete_advances s r id)
    (Nat.le_of_eq (pushDelete_frame s r id).2) ?_
  intro i row hrow _ hlive hb
  by_cases hi : i = id
  · subst hi
    cases hs : s.rows i with
    | none =>
      exfalso
      have e : (pushDelete s r i).server.rows i = none := by
        unfold pushDelete; split <;> simp [Server.tombstone, hs]
      rw [e] at hrow; cases hrow
    | some row0 =>
      cases hl : r.loc i with
      | some c =>
        have e : pushDelete s r i = ⟨s, r, false, none⟩ := by unfold pushDelete; simp [hl]
        rw [e]; exact hb
      | none =>
        cases hbi : r.base i with
        | none => exact absurd hbi hb
        | some b =>
          obtain ⟨⟨row', hrow', hdel⟩, -⟩ := pushDelete_lands s r i hl b hbi row0 hs
          rw [hrow'] at hrow; cases hrow
          rw [hdel] at hlive; cases hlive
  · have e : (pushDelete s r id).replica.base i = r.base i := by
      unfold pushDelete; split <;> simp [Replica.setBase, hi]
    rw [e]; exact hb

omit [DecidableEq C] in
/-- A late response: the `[row]` it carries is live, so it writes an
entry or nothing. -/
theorem baseCovers_recv {s : Server C} {r : Replica C} (h : BaseCoversBelow s r) (q : Flight C)
    (hlv : ∀ row, q.resp = some row → row.deleted = false) :
    BaseCoversBelow s (r.recv hash q) := by
  obtain ⟨hfr, hcur, -⟩ := recv_frame hash r q
  intro i row hrow hle hlive
  rw [hcur] at hle
  have hb := h i row hrow hle hlive
  by_cases hi : i = q.id
  · subst hi
    unfold Replica.recv
    cases hresp : q.resp with
    | none => simpa using hb
    | some row' =>
      have hd := hlv row' hresp
      simp only
      split
      · simp [hd, Replica.setBase]
      · exact hb
  · rw [hfr i hi]; exact hb

omit [DecidableEq C] in
/-- The rewound restore. After a merge every id keeps an entry it had
(`restore_merge_base_kept`), and the rewound cursor is below the old
one. After an overwrite a live row at or below the rewound cursor is at
or below `C0`, so the state the walk's last page was read at held it at
the same version, the snapshot carries it (`hall`), and the replay gives
it the cloud row's entry. Without the rewind a row the replica pulled
after that state is above `C0` and below the cursor, and an overwrite
drops it (`overwrite_drops_pulled_row_control`); without `hall` an
overwrite drops a row the snapshot misses
(`restore_overwrite_incomplete_snapshot_witness`). -/
theorem baseCovers_restore {sys : Sys C} (ih : ReachInv hash sys)
    (hcov0 : BaseCoversBelow sys.server sys.replica) (overwrite : Bool)
    (keepCloud : Id → Bool) (snap : Snapshot C) (C0 : Seq)
    (hall : overwrite = true → ∃ s' ∈ sys.server :: sys.past, C0 ≤ s'.counter ∧
      ∀ i row, s'.rows i = some row → row.deleted = false →
        snap i = some (row.content, row.seq)) :
    BaseCoversBelow sys.server (sys.replica.restore hash overwrite keepCloud snap C0) := by
  intro i row hrow hle hlive
  rw [restore_cursor] at hle
  cases hov : overwrite
  · -- a merge loses no entry, and the rewound cursor is below the old one
    exact restore_merge_base_kept hash sys.replica keepCloud snap C0 i
      (hcov0 i row hrow (Nat.le_trans hle (Nat.min_le_left _ _)) hlive)
  · -- an overwrite keeps only the snapshot's rows: `hall`
    obtain ⟨s', hs', hC0, hcov⟩ := hall hov
    obtain ⟨-, a⟩ := hist_ok ih.past ih.inv.wf hs'
    have hrow' : s'.rows i = some row := by
      rcases a.rows i row hrow with hold | hnew
      · exact hold
      · exact absurd (Nat.lt_of_le_of_lt
          (Nat.le_trans hle (Nat.le_trans (Nat.min_le_right _ _) hC0)) hnew) (Nat.lt_irrefl _)
    rw [(restore_carried_base hash sys.replica true keepCloud snap C0 i _ _
      (hcov i row hrow' hlive) (Or.inl rfl)).1]
    simp

/-- THEOREM (every live server row below the cursor has an entry): on
every reachable state, restores included. -/
theorem baseCovers_of_reachable {sys : Sys C} (h : Reachable hash sys) :
    BaseCoversBelow sys.server sys.replica := by
  induction h with
  | init s r hwf hb hc hfresh0 =>
    intro i row hrow hle hlive
    rw [hfresh0 i row hrow hle] at hlive; cases hlive
  | peer sys op h' ih =>
    exact baseCovers_transfer ih (reachInv_of_reachable hash h').inv.cursorBounded
      (step_advances _ op) (Nat.le_refl _) (fun _ _ _ _ _ hb => hb)
  | edit sys id c _ ih => exact ih
  | deleteLocal sys id _ ih => exact ih
  | push sys id hfree h' ih =>
    exact baseCovers_pushRow hash ih (reachInv_of_reachable hash h').inv.cursorBounded id
  | send sys id c bh bseq hloc hbase hdirty hfree h' ih =>
    exact baseCovers_transfer ih (reachInv_of_reachable hash h').inv.cursorBounded
      (patch_advances sys.server id bseq c) (Nat.le_refl _) (fun _ _ _ _ _ hb => hb)
  | recv sys pre post q hq h' ih =>
    have hqm : q ∈ sys.flights := by rw [hq]; simp
    exact baseCovers_recv hash ih q ((reachInv_of_reachable hash h').flights q hqm).live
  | lose sys pre post q hq _ ih => exact ih
  | pushDelete sys id h' ih =>
    exact baseCovers_pushDelete ih (reachInv_of_reachable hash h').inv.cursorBounded id
  | pull sys s₀ bound page hmem hc hfeed h' ih =>
    have hr := reachInv_of_reachable hash h'
    obtain ⟨hwf₀, a⟩ := hist_ok hr.past hr.inv.wf hmem
    exact baseCovers_pull hash hwf₀ a hc bound page hfeed ih
  | verify sys page hfeed h' ih =>
    have hr := reachInv_of_reachable hash h'
    show BaseCoversBelow sys.server (pullVerify hash sys.replica page sys.pending)
    rw [pullVerify_eq_pull_of_stale hash hr.inv hr.tracks page hfeed sys.pending hr.pending]
    exact baseCovers_pull hash hr.inv.wf (advances_refl _) hr.inv.cursorBounded _ page
      (hfeed.page hr.inv.wf) ih
  | restore sys overwrite keepCloud snap C0 hread hall h' ih =>
    exact baseCovers_restore hash (reachInv_of_reachable hash h') ih overwrite keepCloud snap C0
      hall

/-- THEOREM (a clean id below the cursor is in sync): on every reachable
state, restores included, at a clean id whose server row (if any) is at
or below the cursor, the local row is the server's live content. A live
row has an entry (`BaseCoversBelow`) on its seq (`BaseTracksFeed`) with
its hash (`BaseHashSound`); a dead row or no row has none (`NoDeadBase`,
`BaseAnchored`); clean is the local row's hash being the entry's. -/
theorem clean_synced_at (hinj : HashInjective hash) {sys : Sys C} (h : Reachable hash sys)
    (i : Id) (hclean : CleanAt hash sys.replica i)
    (hbelow : ∀ row, sys.server.rows i = some row → row.seq ≤ sys.replica.cursor) :
    sys.replica.loc i = sys.server.live i := by
  have hr := reachInv_of_reachable hash h
  have hcov := baseCovers_of_reachable hash h
  unfold CleanAt at hclean
  have hnone : sys.replica.base i = none → sys.server.live i = none →
      sys.replica.loc i = sys.server.live i := by
    intro hb hl
    rw [hb] at hclean; rw [hl]
    cases hloc : sys.replica.loc i with
    | none => rfl
    | some l => rw [hloc] at hclean; cases hclean
  cases hrow : sys.server.rows i with
  | none =>
    apply hnone _ (by simp [Server.live, hrow])
    cases hb : sys.replica.base i with
    | none => rfl
    | some e =>
      obtain ⟨hh, S⟩ := e
      obtain ⟨row, hr', -⟩ := hr.inv.anchored i hh S hb
      rw [hrow] at hr'; cases hr'
  | some row =>
    have hle := hbelow row hrow
    cases hd : row.deleted with
    | true =>
      apply hnone _ (by simp [Server.live, hrow, hd])
      cases hb : sys.replica.base i with
      | none => rfl
      | some e =>
        obtain ⟨hh, S⟩ := e
        have hS := hr.tracks i hh S row hb hrow hle
        have := hr.inv.noDead i hh S row hb hrow hS
        rw [hd] at this; cases this
    | false =>
      have hne := hcov i row hrow hle hd
      cases hb : sys.replica.base i with
      | none => exact absurd hb hne
      | some e =>
        obtain ⟨hh, S⟩ := e
        have hS := hr.tracks i hh S row hb hrow hle
        have hh' := hr.hashSound i hh S row hb hrow hS
        rw [hb, hh'] at hclean
        have hlv : sys.server.live i = some row.content := by simp [Server.live, hrow, hd]
        rw [hlv]
        cases hloc : sys.replica.loc i with
        | none => rw [hloc] at hclean; cases hclean
        | some l =>
          rw [hloc] at hclean
          simp only [Option.map_some, Option.some.injEq] at hclean
          rw [hinj _ _ hclean]

/-- THEOREM (an all-clean reachable replica is in sync below its cursor):
`SyncedBelow` — the premise T5 and T5' carry — is a theorem on reachable
states, restores included, once nothing is dirty. -/
theorem synced_below_of_clean (hinj : HashInjective hash) {sys : Sys C}
    (h : Reachable hash sys) (hclean : ∀ i, CleanAt hash sys.replica i) :
    SyncedBelow sys.server sys.replica :=
  fun i hbelow => clean_synced_at hash hinj h i (hclean i) hbelow

/-- THEOREM T5 on reachable states: a reachable replica with no dirty id
pulling one head page lands on the server's live content at every id,
shelf untouched, every id clean, every page row's baseline landed. The
premises of `clean_replica_converges` beyond all-clean are theorems here
— the truthfulness ones (`reachable_sound`) and `SyncedBelow`
(`synced_below_of_clean`) — so every reachable clean replica is covered:
one that took a conflict and has pushed since
(`clean_replica_converges_reachable_instance`), and one a restore with
the rewind left clean (`overwrite_drops_pulled_row_control`). -/
theorem clean_replica_converges_reachable (hinj : HashInjective hash) {sys : Sys C}
    (hreach : Reachable hash sys)
    (hclean : ∀ i, CleanAt hash sys.replica i)
    (page : List (FeedRow C)) (hfeed : IsHeadFeed sys.server sys.replica.cursor page) :
    (∀ i, (pull hash sys.replica page).loc i = sys.server.live i)
      ∧ (pull hash sys.replica page).shelf = sys.replica.shelf
      ∧ (∀ i, CleanAt hash (pull hash sys.replica page) i)
      ∧ ∀ fr ∈ page, (pull hash sys.replica page).base fr.id
          = (if fr.deleted then none else some (hash fr.content, fr.seq)) := by
  obtain ⟨hinv, hbh, -⟩ := reachable_sound hash hreach
  exact clean_replica_converges hash hinj sys.server hinv.wf sys.replica page hclean
    (synced_below_of_clean hash hinj hreach hclean) hinv.anchored hbh hinv.noDead hfeed

/-- THEOREM T5' on reachable states: a reachable, clean replica that runs
the I1 loop (any number of limit-cut pages, peers writing between) and
whose last pull is a head page lands on that server's live content at
every id — no truthfulness premise and no `SyncedBelow` premise. -/
theorem pull_pages_converge_reachable (hinj : HashInjective hash) {sys : Sys C}
    (hreach : Reachable hash sys)
    (hclean : ∀ i, CleanAt hash sys.replica i)
    {steps : List (Server C × List (FeedRow C))} {s₁ s' : Server C}
    (hchain : Chain hash sys.server sys.replica steps s₁)
    (a : Advances s₁ s') (page : List (FeedRow C))
    (hfeed : IsHeadFeed s' (pullAll hash sys.replica steps).cursor page) :
    (∀ i, (pull hash (pullAll hash sys.replica steps) page).loc i = s'.live i)
      ∧ (pull hash (pullAll hash sys.replica steps) page).shelf = sys.replica.shelf
      ∧ ∀ i, CleanAt hash (pull hash (pullAll hash sys.replica steps) page) i := by
  obtain ⟨hinv, hbh, -⟩ := reachable_sound hash hreach
  exact pull_pages_converge hash hinj hchain hinv hclean
    (synced_below_of_clean hash hinj hreach hclean) hbh a page hfeed

/-- THEOREM (a row the server has never had always goes up — the property
7a2e382e restored to merge restores): on every reachable state, restores
included, a local row at an id the server holds no row for has no
baseline entry, is not clean, and pushing it is the ignore-duplicates
POST, which lands it. It needs nothing beyond `BaseAnchored` (part of
`Inv`): every entry names a server row, and server rows never disappear
(`Advances.keep`); `BaseHeld` with `PastOK` gives the same. With the
replay before 7a2e382e it is false (`pre_merge_unsent_row_clean_control`). -/
theorem unsent_row_never_clean {sys : Sys C} (h : Reachable hash sys) (i : Id) (c : C)
    (hloc : sys.replica.loc i = some c) (hnone : sys.server.rows i = none) :
    sys.replica.base i = none ∧ ¬ CleanAt hash sys.replica i
      ∧ (pushRow hash sys.server sys.replica i).server.rows i
          = some ⟨c, sys.server.next, false⟩ := by
  have hinv := (reachable_sound hash h).1
  have hbase : sys.replica.base i = none := by
    cases hb : sys.replica.base i with
    | none => rfl
    | some e =>
      obtain ⟨hh, S⟩ := e
      obtain ⟨row, hrow, -⟩ := hinv.anchored i hh S hb
      rw [hnone] at hrow; cases hrow
  refine ⟨hbase, ?_, ?_⟩
  · unfold CleanAt; rw [hloc, hbase]; simp
  · simp [pushRow, hloc, hbase, Server.insertIgnore, hnone, Server.setRow]

omit [DecidableEq C] in
/-- After a restore of either strategy, a row the snapshot carried — other
than a pending local delete a merge keeps deleted
(`restore_merge_keeps_pending_delete`) — has the cloud row's
`(hash, seq)` as its entry and is clean exactly when its local row is the
cloud's: a row taken from the cloud reads clean, a keepLocal
collision row whose bytes differ reads dirty and goes out as a PATCH on
the cloud's seq. -/
theorem restore_carried (hinj : HashInjective hash) (r : Replica C) (overwrite : Bool)
    (keepCloud : Id → Bool) (snap : Snapshot C) (C0 : Seq) (i : Id) (c : C) (S : Seq)
    (hs : snap i = some (c, S)) (hnd : overwrite = true ∨ r.loc i ≠ none ∨ r.base i = none) :
    (r.restore hash overwrite keepCloud snap C0).base i = some (hash c, S)
      ∧ (CleanAt hash (r.restore hash overwrite keepCloud snap C0) i
          ↔ (r.restore hash overwrite keepCloud snap C0).loc i = some c) := by
  obtain ⟨hbase, l, hl⟩ :=
    restore_carried_base hash r overwrite keepCloud snap C0 i c S hs hnd
  refine ⟨hbase, ?_⟩
  unfold CleanAt
  rw [hl, hbase]
  simp only [Option.map_some, Option.some.injEq]
  exact ⟨fun h => by rw [hinj _ _ h], fun h => by rw [h]⟩

omit [DecidableEq C] in
/-- After a merge, a row the snapshot did not carry keeps its local row
and its entry: a row that never reached the cloud still has no entry and
reads dirty, a row edited since its last upload still PATCHes on the seq
it had, and a pending local delete stays one. -/
theorem restore_merge_uncarried (r : Replica C) (keepCloud : Id → Bool) (snap : Snapshot C)
    (C0 : Seq) (i : Id) (hs : snap i = none) :
    (r.restore hash false keepCloud snap C0).loc i = r.loc i
      ∧ (r.restore hash false keepCloud snap C0).base i = r.base i := by
  have hl : (r.restore hash false keepCloud snap C0).loc i = r.loc i := by
    show restoreLoc false keepCloud snap r.base r.loc i = _
    simp only [restoreLoc, Bool.false_eq_true, ↓reduceIte, hs]
  have hb : (r.restore hash false keepCloud snap C0).base i
      = replayBaseline hash false snap r.base (r.restore hash false keepCloud snap C0).loc i :=
    rfl
  refine ⟨hl, ?_⟩
  rw [hb]
  cases hlo : r.loc i with
  | none => simp [replayBaseline, hl, hlo]
  | some row => simp [replayBaseline, hl, hlo, hs]

omit [DecidableEq C] in
/-- THEOREM (a merge restore keeps a pending local delete — the rule
decided after 9121ba12): an id deleted here whose tombstone has not gone
up (no local row, an entry) is, after a merge restore of any snapshot —
one carrying the row included — still deleted here with the same entry.
So the next flush still sends its tombstone (`restore_pending_delete_sent`). -/
theorem restore_merge_keeps_pending_delete (r : Replica C) (keepCloud : Id → Bool)
    (snap : Snapshot C) (C0 : Seq) (i : Id) (b : Hash × Seq)
    (hloc : r.loc i = none) (hbase : r.base i = some b) :
    (r.restore hash false keepCloud snap C0).loc i = none
      ∧ (r.restore hash false keepCloud snap C0).base i = some b := by
  have hl : (r.restore hash false keepCloud snap C0).loc i = none := by
    show restoreLoc false keepCloud snap r.base r.loc i = none
    simp only [restoreLoc, Bool.false_eq_true, ↓reduceIte]
    cases snap i with
    | none => simp [hloc]
    | some e => obtain ⟨c, S⟩ := e; simp [hloc, hbase]
  refine ⟨hl, ?_⟩
  show replayBaseline hash false snap r.base (r.restore hash false keepCloud snap C0).loc i = _
  simp [replayBaseline, hl, hbase]

/-- THEOREM (…and its tombstone goes up): on a reachable state, after a
merge restore, `pushDelete` of a pending local delete tombstones the
server's row for the id and drops the entry. The server holds a row for
it because an entry always names one (`BaseAnchored`), and the restore
writes no server row. -/
theorem restore_pending_delete_sent {sys : Sys C} (h : Reachable hash sys)
    (keepCloud : Id → Bool) (snap : Snapshot C) (C0 : Seq) (i : Id) (b : Hash × Seq)
    (hloc : sys.replica.loc i = none) (hbase : sys.replica.base i = some b) :
    (pushDelete sys.server (sys.replica.restore hash false keepCloud snap C0) i).server.Deleted i
      ∧ (pushDelete sys.server (sys.replica.restore hash false keepCloud snap C0)
          i).replica.base i = none := by
  obtain ⟨hl, hb⟩ :=
    restore_merge_keeps_pending_delete hash sys.replica keepCloud snap C0 i b hloc hbase
  obtain ⟨bh, bs⟩ := b
  obtain ⟨row, hrow, -⟩ := (reachable_sound hash h).1.anchored i bh bs hbase
  exact pushDelete_lands sys.server _ i hl (bh, bs) hb row hrow

/-- A restore step: from the replica, the strategy, the per-row
decisions, the snapshot and `C0`, the replica after the restore. -/
abbrev RestoreStep (C : Type) := Replica C → Bool → (Id → Bool) → Snapshot C → Seq → Replica C

omit [DecidableEq C] in
/-- The replay `replay`, then the rewind. -/
def fixedStep (replay : Replay C) : RestoreStep C := fun r overwrite keepCloud snap C0 =>
  r.restoreFixedWith replay overwrite keepCloud snap C0

omit [DecidableEq C] in
/-- The Swift as of 7a2e382e: its local-rows rule and replay, no rewind
(`C0` unread). -/
def unfixedStep : RestoreStep C := fun r overwrite keepCloud snap _ =>
  r.restoreUnfixed hash overwrite keepCloud snap

omit [DecidableEq C] in
/-- The Swift as of 9121ba12: 7a2e382e's local-rows rule and replay, then
the rewind. -/
def step9121 : RestoreStep C := fun r overwrite keepCloud snap C0 =>
  r.restore9121 hash overwrite keepCloud snap C0

/-- `Reachable` with the restore step swapped for `step`: every
`Reachable` state, and every state one restore by `step` reaches from one
of them, under exactly `Reachable.restore`'s premises. A statement about
every state of this set fails as soon as one state violates it, so one
restore is all a positive control needs. With the step `Reachable` has
the set is inside `Reachable` (`reachableRestoreWith_current`). A
control with `fixedStep` and an older replay differs from the theorems
in the replay alone; `step9121`, the Swift as of 9121ba12, in the merge
rule for a pending local delete alone; `unfixedStep`, the Swift as of
7a2e382e, in that and the rewind — and none of its runs has a pending
local delete. -/
inductive ReachableRestoreWith (step : RestoreStep C) : Sys C → Prop
  | reach (sys : Sys C) : Reachable hash sys → ReachableRestoreWith step sys
  | restore (sys : Sys C) (overwrite : Bool) (keepCloud : Id → Bool) (snap : Snapshot C)
      (C0 : Seq)
      (hread : ∀ i c S, snap i = some (c, S) →
        ∃ s' ∈ sys.server :: sys.past, s'.rows i = some ⟨c, S, false⟩ ∧ C0 ≤ s'.counter)
      (hall : overwrite = true → ∃ s' ∈ sys.server :: sys.past, C0 ≤ s'.counter ∧
        ∀ i row, s'.rows i = some row → row.deleted = false →
          snap i = some (row.content, row.seq)) :
      Reachable hash sys →
      ReachableRestoreWith step
        { sys with replica := step sys.replica overwrite keepCloud snap C0 }

theorem reachableRestoreWith_current {sys : Sys C}
    (h : ReachableRestoreWith hash (fixedStep (replayBaseline hash)) sys) : Reachable hash sys := by
  cases h with
  | reach _ h => exact h
  | restore sys overwrite keepCloud snap C0 hread hall h =>
    exact Reachable.restore sys overwrite keepCloud snap C0 hread hall h

end Reachable

/-! ## Reachable runs, and the runs `Reachable` excludes

Concrete runs (`Nat` content, identity hash) built through the
constructors, so the premises of the reachable theorems are shown
satisfiable on a state that took a conflict, a late `[row]` response and
a push, and on restored states; the runs the section header names as
outside `Reachable` — the unguarded late write, the ineligible verify
pass, a restore without the rewind — each with the loss it admits; and
the restore replays before 7a2e382e, each reaching a state a reachable
theorem rules out. -/

section ReachableRuns

theorem onePage_feed (s : Server C) (since bound : Seq) (fr : FeedRow C)
    (hrow : s.rows fr.id = some ⟨fr.content, fr.seq, fr.deleted⟩) (hlt : since < fr.seq)
    (hle : fr.seq ≤ bound) (honly : ∀ i, i ≠ fr.id → s.rows i = none) :
    IsPageFeed s since bound [fr] := by
  refine ⟨?_, ?_, List.pairwise_singleton _ _⟩
  · intro x hx
    simp only [List.mem_singleton] at hx
    subst hx
    exact ⟨hrow, hlt, hle⟩
  · intro i row hr _ _
    by_cases hi : i = fr.id
    · exact ⟨fr, List.mem_singleton_self _, hi.symm⟩
    · rw [honly i hi] at hr; cases hr

theorem onePage_head (s : Server C) (since : Seq) (fr : FeedRow C)
    (hrow : s.rows fr.id = some ⟨fr.content, fr.seq, fr.deleted⟩) (hlt : since < fr.seq)
    (honly : ∀ i, i ≠ fr.id → s.rows i = none) :
    IsHeadFeed s since [fr] := by
  refine ⟨?_, ?_, List.pairwise_singleton _ _⟩
  · intro x hx
    simp only [List.mem_singleton] at hx
    subst hx
    exact ⟨hrow, hlt⟩
  · intro i row hr _
    by_cases hi : i = fr.id
    · exact ⟨fr, List.mem_singleton_self _, hi.symm⟩
    · rw [honly i hi] at hr; cases hr

theorem emptyPage_head (s : Server C) (since : Seq)
    (h : ∀ i row, s.rows i = some row → row.seq ≤ since) : IsHeadFeed s since [] := by
  refine ⟨by simp, ?_, List.Pairwise.nil⟩
  intro i row hr hlt
  exact absurd (h i row hr) (Nat.not_le.mpr hlt)

theorem patch_frame [DecidableEq C] (s : Server C) (id : Id) (base : Seq) (c : C) (i : Id)
    (hi : i ≠ id) : (s.patch id base c).1.rows i = s.rows i := by
  unfold Server.patch
  split
  · rfl
  · split
    · rfl
    · split
      · rfl
      · simp [Server.setRow, hi]

theorem oneServer_wf (row : Row Nat) (counter : Seq) (h : row.seq ≤ counter) :
    (oneServer (some row) counter).WF := by
  intro i row' hr
  by_cases hi : i = 1
  · subst hi
    simp only [oneServer, ↓reduceIte, Option.some.injEq] at hr
    subst hr
    exact h
  · simp [oneServer, hi] at hr

theorem oneServer_only (row : Option (Row Nat)) (counter : Seq) (i : Id) (hi : i ≠ 1) :
    (oneServer row counter).rows i = none := by
  simp [oneServer, hi]

/-- `init`'s premise for a replica at cursor 0 against a server whose one
row carries a minted seq. -/
theorem oneServer_fresh0 (row : Row Nat) (counter : Seq) (hpos : 0 < row.seq) :
    ∀ i r, (oneServer (some row) counter).rows i = some r → r.seq ≤ 0 → r.deleted = true := by
  intro i r h hle
  by_cases hi : i = 1
  · subst hi
    simp only [oneServer, ↓reduceIte, Option.some.injEq] at h
    subst h
    exact absurd hle (Nat.not_le.mpr hpos)
  · simp [oneServer, hi] at h

/-- The live rows of a one-row server. -/
theorem oneServer_live (row : Row Nat) (counter : Seq) :
    ∀ i r, (oneServer (some row) counter).rows i = some r → r.deleted = false →
      i = 1 ∧ r = row := by
  intro i r h _
  by_cases hi : i = 1
  · subst hi
    simp only [oneServer, ↓reduceIte, Option.some.injEq] at h
    exact ⟨rfl, h.symm⟩
  · simp [oneServer, hi] at h

/-- A replica that holds nothing away from id 1. -/
def OnlyAt1 (r : Replica Nat) : Prop := ∀ i, i ≠ 1 → r.loc i = none ∧ r.base i = none

theorem onlyAt1_pull (r : Replica Nat) (fr : FeedRow Nat) (hid : fr.id = 1) (h : OnlyAt1 r) :
    OnlyAt1 (pull id r [fr]) := by
  intro i hi
  obtain ⟨h1, h2⟩ := pull_frame id r [fr] i (by
    intro x hx
    simp only [List.mem_singleton] at hx
    subst hx
    rw [hid]
    exact Ne.symm hi)
  rw [h1, h2]
  exact h i hi

theorem onlyAt1_edit (r : Replica Nat) (c : Nat) (h : OnlyAt1 r) : OnlyAt1 (r.edit 1 c) := by
  intro i hi
  simp only [Replica.edit, if_neg hi]
  exact h i hi

theorem onlyAt1_push (s : Server Nat) (r : Replica Nat) (h : OnlyAt1 r) :
    OnlyAt1 (pushRow id s r 1).replica := by
  intro i hi
  obtain ⟨hb, -, hl⟩ := pushRow_frame id s r 1
  rw [hb i hi, hl i hi]
  exact h i hi

theorem onlyAt1_recv (r : Replica Nat) (q : Flight Nat) (hq : q.id = 1) (h : OnlyAt1 r) :
    OnlyAt1 (r.recv id q) := by
  intro i hi
  obtain ⟨hb, -, hl⟩ := recv_frame id r q
  rw [hb i (by rw [hq]; exact hi), hl i (by rw [hq]; exact hi)]
  exact h i hi

/-! ### A run through a conflict and a late `[row]` response

A holds c0 at seq 5 and edits it to c1. Its PATCH `seq=eq.5` lands c1 at
6; the response is still on its way. The user types c3. The peer pulls
c1 and writes c2 at 7. A pulls X@7: c3 against baseline `(h0, 5)` is a
conflict — c2 shelved, baseline `(h2, 7)`. Then the late `[row]`
arrives. -/

def lateS0 : Server Nat := oneServer (some ⟨0, 5, false⟩) 5
def lateR0 : Replica Nat := oneRowAt none none 0
def lateR1 : Replica Nat := pull id lateR0 [⟨1, 5, 0, false⟩]
def lateR2 : Replica Nat := lateR1.edit 1 1
def lateFlight : Flight Nat := ⟨1, 5, 1, (lateS0.patch 1 5 1).2⟩
def lateS1 : Server Nat := (lateS0.patch 1 5 1).1
def lateR3 : Replica Nat := lateR2.edit 1 3
def lateS2 : Server Nat := lateS1.step (.patch 1 6 2)
def lateR4 : Replica Nat := pull id lateR3 [⟨1, 7, 2, false⟩]
/-- The guarded `recv`: the baseline seq is 7, the PATCH carried 5 — dropped. -/
def lateR5 : Replica Nat := lateR4.recv id lateFlight
def lateS3 : Server Nat := (pushRow id lateS2 lateR5 1).server
def lateR6 : Replica Nat := (pushRow id lateS2 lateR5 1).replica
/-- The text's unconditional write of the same late response. -/
def lateU5 : Replica Nat := lateR4.recvUnguarded id lateFlight

theorem lateS1_only (i : Id) (hi : i ≠ 1) : lateS1.rows i = none := by
  unfold lateS1; rw [patch_frame _ _ _ _ _ hi]; exact oneServer_only _ _ i hi

theorem lateS2_only (i : Id) (hi : i ≠ 1) : lateS2.rows i = none := by
  unfold lateS2; simp only [Server.step]; rw [patch_frame _ _ _ _ _ hi]; exact lateS1_only i hi

theorem lateR0_only : OnlyAt1 lateR0 := fun _ _ => by simp [lateR0, oneRowAt, oneRow]

theorem lateR6_only : OnlyAt1 lateR6 :=
  onlyAt1_push _ _ (onlyAt1_recv _ _ rfl (onlyAt1_pull _ _ rfl (onlyAt1_edit _ _
    (onlyAt1_edit _ _ (onlyAt1_pull _ _ rfl lateR0_only)))))

theorem lateR4_only : OnlyAt1 lateR4 :=
  onlyAt1_pull _ _ rfl (onlyAt1_edit _ _ (onlyAt1_edit _ _ (onlyAt1_pull _ _ rfl lateR0_only)))

theorem lateS3_only (i : Id) (hi : i ≠ 1) : lateS3.rows i = none := by
  have h := (pushRow_cases id lateS2 lateR5 1)
  unfold lateS3
  rcases h with ⟨-, hp⟩ | ⟨c, row, bh, bseq, -, -, -, -, -, hp⟩
    | ⟨c, row, bh, bseq, -, -, -, -, -, hp⟩ | ⟨c, bh, bseq, -, -, -, hp⟩ | ⟨c, -, -, -, hp⟩
    | ⟨c, -, -, hp⟩ <;> rw [hp] <;> simp [Server.setRow, hi, lateS2_only i hi]

/-- The conflicted state, and the state after the guarded late response
and the push, are reachable — the first through `init`, `pull`, `edit`,
`send`, `edit`, `peer`, `pull`; the second through `recv` and `push`. -/
theorem late_guard_run_reachable :
    Reachable id ⟨lateS2, lateR4, [], [lateFlight], [lateS1, lateS0]⟩
      ∧ Reachable id ⟨lateS3, lateR6, [], [], [lateS2, lateS1, lateS0]⟩ := by
  have hwf0 : lateS0.WF := oneServer_wf _ _ (Nat.le_refl _)
  have h0 : Reachable id ⟨lateS0, lateR0, [], [], []⟩ :=
    Reachable.init lateS0 lateR0 hwf0 (fun i => by simp [lateR0, oneRowAt, oneRow])
      (Nat.zero_le _) (oneServer_fresh0 _ _ (by decide))
  have h1 : Reachable id ⟨lateS0, lateR1, [], [], []⟩ :=
    Reachable.pull ⟨lateS0, lateR0, [], [], []⟩ lateS0 5 [⟨1, 5, 0, false⟩]
      (List.mem_cons_self ..) (Nat.zero_le _)
      (onePage_feed _ _ _ _ rfl (by decide) (Nat.le_refl _) (oneServer_only _ _)) h0
  have h2 : Reachable id ⟨lateS0, lateR2, [], [], []⟩ :=
    Reachable.edit ⟨lateS0, lateR1, [], [], []⟩ 1 1 h1
  have h3 : Reachable id ⟨lateS1, lateR2, [], [lateFlight], [lateS0]⟩ :=
    Reachable.send ⟨lateS0, lateR2, [], [], []⟩ 1 1 0 5 (by decide) (by decide) (by decide)
      (by simp) h2
  have h4 : Reachable id ⟨lateS1, lateR3, [], [lateFlight], [lateS0]⟩ :=
    Reachable.edit ⟨lateS1, lateR2, [], [lateFlight], [lateS0]⟩ 1 3 h3
  have h5 : Reachable id ⟨lateS2, lateR3, [], [lateFlight], [lateS1, lateS0]⟩ :=
    Reachable.peer ⟨lateS1, lateR3, [], [lateFlight], [lateS0]⟩ (.patch 1 6 2) h4
  have h6 : Reachable id ⟨lateS2, lateR4, [], [lateFlight], [lateS1, lateS0]⟩ :=
    Reachable.pull ⟨lateS2, lateR3, [], [lateFlight], [lateS1, lateS0]⟩ lateS2 7
      [⟨1, 7, 2, false⟩] (List.mem_cons_self ..) (by decide)
      (onePage_feed _ _ _ _ (by decide) (by decide) (Nat.le_refl _) lateS2_only) h5
  have h7 : Reachable id ⟨lateS2, lateR5, [], [], [lateS1, lateS0]⟩ :=
    Reachable.recv ⟨lateS2, lateR4, [], [lateFlight], [lateS1, lateS0]⟩ [] [] lateFlight rfl h6
  have h8 : Reachable (C := Nat) id ⟨lateS3, lateR6, [], [], [lateS2, lateS1, lateS0]⟩ := by
    have hp : (pushRow id lateS2 lateR5 1).pending = none := by decide
    have := Reachable.push ⟨lateS2, lateR5, [], [], [lateS1, lateS0]⟩ 1 (by simp) h7
    rw [hp] at this
    exact this
  exact ⟨h6, h8⟩

/-- WITNESS (the late `[row]` under the guard — dropped, and nothing is
lost): after the conflict the baseline is `(h2, 7)`, the late response
carried seq 5, so `recv` drops it; the next PATCH `seq=eq.7` lands c3 at
8; c2 is on the shelf. Under the text's unconditional write
(`recvUnguarded`) the same response regresses the baseline to
`(h1, 6)`; c3's PATCH `seq=eq.6` answers `[]` and files `(1, 6, h3)`;
the ELIGIBLE head pull (`late_unguarded_page_is_head`) sees nothing, the
baseline seq equals the sent seq, and the confirm branch writes
`(h3, 6)` — c3 reads clean, nothing is sent, the server and the peer
hold c2; the peer's next edit is adopted over c3, which is on no shelf
and never reached the server. -/
theorem late_row_response_regresses_witness :
    lateFlight.resp = some ⟨1, 6, false⟩ ∧ lateS2.rows 1 = some ⟨2, 7, false⟩
      ∧ lateR4.base 1 = some (2, 7) ∧ lateR4.shelf = [(1, 2)] ∧ lateR4.cursor = 7
      ∧ lateR4.loc 1 = some 3
      ∧ lateR5.base 1 = some (2, 7)
      ∧ lateS3.rows 1 = some ⟨3, 8, false⟩ ∧ lateR6.base 1 = some (3, 8)
      ∧ lateR6.shelf = [(1, 2)]
      ∧ lateU5.base 1 = some (1, 6)
      ∧ (pushRow id lateS2 lateU5 1).pending = some ⟨1, 6, 3⟩
      ∧ (pushRow id lateS2 lateU5 1).server.counter = 7
      ∧ (pullVerify id lateU5 [] [⟨1, 6, 3⟩]).base 1 = some (3, 6)
      ∧ (pushRow id lateS2 (pullVerify id lateU5 [] [⟨1, 6, 3⟩]) 1).needsPull = false
      ∧ (pushRow id lateS2 (pullVerify id lateU5 [] [⟨1, 6, 3⟩]) 1).server.counter = 7
      ∧ lateS2.live 1 = some 2
      ∧ (pull id (pullVerify id lateU5 [] [⟨1, 6, 3⟩]) [⟨1, 8, 4, false⟩]).loc 1 = some 4
      ∧ (pull id (pullVerify id lateU5 [] [⟨1, 6, 3⟩]) [⟨1, 8, 4, false⟩]).shelf
          = [(1, 2)] := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> decide

/-- The verify pass in the unguarded run is an ELIGIBLE one: the empty
page is the head page of the current server from the replica's cursor. -/
theorem late_unguarded_page_is_head : IsHeadFeed lateS2 lateU5.cursor [] := by
  apply emptyPage_head
  intro i row hr
  by_cases hi : i = 1
  · subst hi
    have h : lateS2.rows 1 = some ⟨2, 7, false⟩ := by decide
    rw [h] at hr
    cases hr
    decide
  · rw [lateS2_only i hi] at hr; cases hr

/-- The unguarded write leaves a state no `Reachable` run reaches: the
server row for the id sits at the cursor with seq 7, the baseline says 6. -/
theorem late_unguarded_breaks_tracking : ¬ BaseTracksFeed lateS2 lateU5 := by
  intro h
  have := h 1 1 6 ⟨2, 7, false⟩ (by decide) (by decide) (by decide)
  cases this

/-- INSTANCE (`clean_iff_matches_server`, both truth values, on reachable
states): on the conflicted state the id is dirty and the local row is
not the server's; after the guarded late response and the push it is
clean and the local row IS the server's. -/
theorem clean_iff_matches_server_instance :
    (¬ CleanAt id lateR4 1 ∧ lateR4.loc 1 ≠ lateS2.live 1)
      ∧ (CleanAt id lateR6 1 ∧ lateR6.loc 1 = lateS3.live 1) := by
  have hinj : HashInjective (id : Nat → Hash) := fun _ _ h => h
  obtain ⟨h6, h8⟩ := late_guard_run_reachable
  have i4 := clean_iff_matches_server id hinj h6 1 2 7 ⟨2, 7, false⟩ (by decide) (by decide) rfl
  have i6 := clean_iff_matches_server id hinj h8 1 3 8 ⟨3, 8, false⟩ (by decide) (by decide) rfl
  have hne : lateR4.loc 1 ≠ lateS2.live 1 := by decide
  have hc6 : CleanAt id lateR6 1 := by unfold CleanAt; decide
  exact ⟨⟨fun hc => hne (i4.mp hc), hne⟩, ⟨hc6, i6.mp hc6⟩⟩

/-- INSTANCE (T5 on a reachable state that took a conflict and a late
response and pushed since): the premises of
`clean_replica_converges_reachable` hold and the head pull lands. -/
theorem clean_replica_converges_reachable_instance :
    (∀ i, (pull id lateR6 [⟨1, 8, 3, false⟩]).loc i = lateS3.live i)
      ∧ (pull id lateR6 [⟨1, 8, 3, false⟩]).shelf = [(1, 2)] := by
  have hinj : HashInjective (id : Nat → Hash) := fun _ _ h => h
  have h8 := late_guard_run_reachable.2
  have hclean : ∀ i, CleanAt id lateR6 i := by
    intro i
    by_cases hi : i = 1
    · subst hi; unfold CleanAt; decide
    · unfold CleanAt; rw [(lateR6_only i hi).1, (lateR6_only i hi).2]; rfl
  have hfeed : IsHeadFeed lateS3 lateR6.cursor [⟨1, 8, 3, false⟩] :=
    onePage_head _ _ _ (by decide) (by decide) lateS3_only
  obtain ⟨hl, hs, -⟩ := clean_replica_converges_reachable id hinj h8 hclean _ hfeed
  exact ⟨hl, by rw [hs]; decide⟩

/-- The common prefix of the late-response runs: `init`, the pull of c0
at 5, the edit to c1, then `send` of the PATCH `seq=eq.5`, which lands
c1 at 6 with its response outstanding. -/
theorem late_prefix_reachable :
    Reachable id ⟨lateS0, lateR2, [], [], []⟩
      ∧ Reachable id ⟨lateS1, lateR2, [], [lateFlight], [lateS0]⟩ := by
  have hwf0 : lateS0.WF := oneServer_wf _ _ (Nat.le_refl _)
  have h0 : Reachable id ⟨lateS0, lateR0, [], [], []⟩ :=
    Reachable.init lateS0 lateR0 hwf0 (fun i => by simp [lateR0, oneRowAt, oneRow])
      (Nat.zero_le _) (oneServer_fresh0 _ _ (by decide))
  have h1 : Reachable id ⟨lateS0, lateR1, [], [], []⟩ :=
    Reachable.pull ⟨lateS0, lateR0, [], [], []⟩ lateS0 5 [⟨1, 5, 0, false⟩]
      (List.mem_cons_self ..) (Nat.zero_le _)
      (onePage_feed _ _ _ _ rfl (by decide) (Nat.le_refl _) (oneServer_only _ _)) h0
  have h2 : Reachable id ⟨lateS0, lateR2, [], [], []⟩ :=
    Reachable.edit ⟨lateS0, lateR1, [], [], []⟩ 1 1 h1
  exact ⟨h2, Reachable.send ⟨lateS0, lateR2, [], [], []⟩ 1 1 0 5 (by decide) (by decide)
    (by decide) (by simp) h2⟩

/-! ### Our own echo pulled before the PATCH response

The C2 shape (review two) with the response late, which the design
calls the common case ("两者并存是常态"): A holds c0 at 5 and edits to
c1; its PATCH `seq=eq.5` lands c1 at 6 and the response is still on its
way; the user types c3; a pull shows X@6 — our OWN c1 — before the
response is applied. The baseline is still `(h0, 5)`, so the echo row
does not fire (`h_in = h1 ≠ h0`), the same row does not
(`h_loc = h3`), the row is dirty, and the conflict row files our own c1
on the shelf — a `sync.conflict` for a push of ours — with baseline
`(h1, 6)`. The late `[row]` is then dropped by the guard (the text's
unconditional write writes the same `(h1, 6)`). Nothing is lost: c3 is
kept and its PATCH `seq=eq.6` lands. In the other order (response,
then pull) the skip row absorbs the echo and the shelf stays empty. So
the "顺序敏感" guarantee — the echo row before dirty detection keeps our
own push off the shelf (T3b, `echo_after_local_edit`) — holds only when
the response is applied before the echo. -/

def echoR4 : Replica Nat := pull id lateR3 [⟨1, 6, 1, false⟩]
def echoR5 : Replica Nat := echoR4.recv id lateFlight
/-- The other order: the response first, then the same pull. -/
def echoSeq : Replica Nat := pull id (lateR3.recv id lateFlight) [⟨1, 6, 1, false⟩]
/-- The revert form of the same race: after the PATCH is sent the user
sets the row back to c0, the baseline's bytes, and the echo arrives
first. -/
def revR4 : Replica Nat := pull id (lateR2.edit 1 0) [⟨1, 6, 1, false⟩]
def revR5 : Replica Nat := revR4.recv id lateFlight
def revSeq : Replica Nat := pull id ((lateR2.edit 1 0).recv id lateFlight) [⟨1, 6, 1, false⟩]

theorem lateFeed6 (r : Replica Nat) (hc : r.cursor = 5) :
    IsPageFeed lateS1 r.cursor 6 [⟨1, 6, 1, false⟩] := by
  rw [hc]
  exact onePage_feed _ _ _ _ (by decide) (by decide) (Nat.le_refl _) lateS1_only

theorem lateCursor6 (r : Replica Nat) (hc : r.cursor = 5) : r.cursor ≤ lateS1.counter := by
  rw [hc]; decide

/-- The four runs are reachable: `init`, `pull`, `edit`, `send`, `edit`
(to c3, or back to c0), then the pull of our own echo BEFORE `recv`, or
`recv` before the pull. -/
theorem echo_race_reachable :
    Reachable id ⟨lateS1, echoR5, [], [], [lateS0]⟩
      ∧ Reachable id ⟨lateS1, echoSeq, [], [], [lateS0]⟩
      ∧ Reachable id ⟨lateS1, revR5, [], [], [lateS0]⟩
      ∧ Reachable id ⟨lateS1, revSeq, [], [], [lateS0]⟩ := by
  have h3 := late_prefix_reachable.2
  have run : ∀ c : Nat,
      Reachable id ⟨lateS1, (pull id (lateR2.edit 1 c) [⟨1, 6, 1, false⟩]).recv id lateFlight,
          [], [], [lateS0]⟩
        ∧ Reachable id ⟨lateS1, pull id ((lateR2.edit 1 c).recv id lateFlight)
          [⟨1, 6, 1, false⟩], [], [], [lateS0]⟩ := by
    intro c
    have h4 : Reachable id ⟨lateS1, lateR2.edit 1 c, [], [lateFlight], [lateS0]⟩ :=
      Reachable.edit ⟨lateS1, lateR2, [], [lateFlight], [lateS0]⟩ 1 c h3
    have h5 : Reachable id ⟨lateS1, pull id (lateR2.edit 1 c) [⟨1, 6, 1, false⟩], [],
        [lateFlight], [lateS0]⟩ :=
      Reachable.pull _ lateS1 6 [⟨1, 6, 1, false⟩] (List.mem_cons_self ..)
        (lateCursor6 _ rfl) (lateFeed6 _ rfl) h4
    have h6 := Reachable.recv _ [] [] lateFlight rfl h5
    have h5' := Reachable.recv _ [] [] lateFlight rfl h4
    have h6' := Reachable.pull _ lateS1 6 [⟨1, 6, 1, false⟩] (List.mem_cons_self ..)
      (lateCursor6 _ rfl) (lateFeed6 _ rfl) h5'
    exact ⟨h6, h6'⟩
  exact ⟨(run 3).1, (run 3).2, (run 0).1, (run 0).2⟩

/-- WITNESS (our own echo pulled before the response; design §6
"顺序敏感", review two C2): the decision on our own c1 is `conflict`,
c1 goes to the shelf, the baseline is `(h1, 6)`, c3 is kept; the guarded
late response is dropped and the unguarded one writes the same
baseline; the next PATCH `seq=eq.6` lands c3 at 7. The response-first
order gives the same baseline, local row and server — and an empty
shelf. The revert form: after the PATCH the user sets the row back to
c0; the echo arriving first finds it clean against `(h0, 5)` and
ADOPTS our own c1 over the revert, nothing shelved (c0 was clean, so
I7 holds; the user's last edit is gone and the next flush sends
nothing); the response-first order keeps c0, which is dirty against
`(h1, 6)`, and its PATCH lands c0 at 7. -/
theorem echo_before_response_shelves_own_push_witness :
    lateFlight.resp = some ⟨1, 6, false⟩
      ∧ (decideRow false 1 (some 3) (some (0, 5)) 6).action = .conflict
      ∧ echoR4.shelf = [(1, 1)] ∧ echoR4.base 1 = some (1, 6) ∧ echoR4.loc 1 = some 3
      ∧ echoR5.shelf = [(1, 1)] ∧ echoR5.base 1 = some (1, 6)
      ∧ (echoR4.recvUnguarded id lateFlight).base 1 = some (1, 6)
      ∧ (pushRow id lateS1 echoR5 1).server.rows 1 = some ⟨3, 7, false⟩
      ∧ echoSeq.shelf = [] ∧ echoSeq.base 1 = some (1, 6) ∧ echoSeq.loc 1 = some 3
      ∧ (pushRow id lateS1 echoSeq 1).server.rows 1 = some ⟨3, 7, false⟩
      ∧ (decideRow false 1 (some 0) (some (0, 5)) 6).action = .adopt
      ∧ revR5.loc 1 = some 1 ∧ revR5.shelf = [] ∧ revR5.base 1 = some (1, 6)
      ∧ (pushRow id lateS1 revR5 1).server.counter = 6
      ∧ revSeq.loc 1 = some 0 ∧ revSeq.base 1 = some (1, 6)
      ∧ (pushRow id lateS1 revSeq 1).server.rows 1 = some ⟨0, 7, false⟩ := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_,
    ?_⟩ <;> decide

/-! ### The `?` baseline on these runs (a sentinel, not a model of it)

The working-tree text (v1.5, S4) writes the baseline hash `?` — equal to
no hash — for a write whose outcome is unknown. `Replica.base` has no
such value; on these `Nat` runs, where every content is below it, the
hash `unk` stands in for it. This is a concrete check of the text's
arithmetic on three runs, not a model of `?` (no theorem here quantifies
over it). -/

/-- The stand-in for `?`: no content on these runs hashes to it. -/
def unk : Hash := 99

/-- WITNESS (`?` on the lost-response and in-flight runs). Lost response
(S4 as written: the PATCH threw after landing c1 at 6): the entry
becomes `?@5`; the user's revert to c0 is dirty; the resent PATCH
`seq=eq.5` answers `[]` and files `(1, 5, h0)`; the head verify pass
shows X@6 and applies a conflict — our own c1 shelved, c0 kept,
baseline `(h1, 6)` — and c0 lands at 7: the hole of
`lost_then_revert_reachable` is closed, at one self-shelf line. In
flight, reading S4's "在发送时写下" as `?` from send to response: the
revert race keeps c0 and lands it (c1 shelved), where the table adopted
c1 over it; the C2 race shelves our own c1 as the table does. -/
theorem unknown_marker_witness :
    let lost := (lateR2.setBase 1 (some (unk, 5))).edit 1 0
    let lp := pushRow id lateS1 lost 1
    let lv := pullVerify id lp.replica [⟨1, 6, 1, false⟩] lp.pending.toList
    let rev := pull id ((lateR2.setBase 1 (some (unk, 5))).edit 1 0) [⟨1, 6, 1, false⟩]
    let c2 := pull id ((lateR2.setBase 1 (some (unk, 5))).edit 1 3) [⟨1, 6, 1, false⟩]
    ¬ CleanAt id lost 1 ∧ lp.pending = some ⟨1, 5, 0⟩ ∧ lp.server.counter = 6
      ∧ lv.shelf = [(1, 1)] ∧ lv.loc 1 = some 0 ∧ lv.base 1 = some (1, 6)
      ∧ (pushRow id lp.server lv 1).server.rows 1 = some ⟨0, 7, false⟩
      ∧ rev.loc 1 = some 0 ∧ rev.shelf = [(1, 1)] ∧ rev.base 1 = some (1, 6)
      ∧ (rev.recv id lateFlight).base 1 = some (1, 6)
      ∧ (pushRow id lateS1 (rev.recv id lateFlight) 1).server.rows 1 = some ⟨0, 7, false⟩
      ∧ c2.shelf = [(1, 1)] ∧ c2.loc 1 = some 3 := by
  refine ⟨by unfold CleanAt; decide, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;>
    decide

/-! ### A variant: the outstanding PATCH's sent hash is an echo

Not the text's rule — one answer to the design decision the run above
raises. The applier consults the PATCH still outstanding for the row's
id (at most one: `Reachable.send`): an incoming LIVE row whose hash is
that PATCH's sent hash is our own write coming back — local kept,
nothing shelved, baseline `(h_in, seq)`. Per row it writes the
baseline the table writes on every input (`decideRowInflight_base`) and
differs only in the shelf (the conflict row's own-push line) and the
local row (the adopt row's own-push overwrite); with it the race above
IS the sequential order (`inflight_race_matches_sequential`). The
whole-run theorems (`reachable_sound` and its family) are proved for the
table, not re-proved for the variant: a different local row changes what
later pushes send. -/

/-- `sent` is the sent hash of the PATCH outstanding for the row's id, if
any; the test runs after the skip row and the tombstone row. -/
def decideRowInflight (sent : Option Hash) : Core := fun tomb hIn hLoc hBase inSeq =>
  if staleOrSeen hBase inSeq = false ∧ tomb = false ∧ sent = some hIn then
    { action := .echo, base := some (hIn, inSeq), shelfRemote := false, shelfLocal := false }
  else decideRow tomb hIn hLoc hBase inSeq

/-- The variant writes exactly the table's baseline, on every input. -/
theorem decideRowInflight_base (sent : Option Hash) (tomb : Bool) (hIn : Hash)
    (hLoc : Option Hash) (hBase : Option (Hash × Seq)) (inSeq : Seq) :
    (decideRowInflight sent tomb hIn hLoc hBase inSeq).base
      = (decideRow tomb hIn hLoc hBase inSeq).base := by
  unfold decideRowInflight
  split
  · rename_i h
    obtain ⟨hns, ht, -⟩ := h
    rw [decideRow_base_noskip tomb hIn hLoc hBase inSeq hns, ht]
    rfl
  · rfl

/-- THEOREM (under the variant the race is the sequential order): a PATCH
whose `[row]` is live and carries the sent bytes at a seq above the
filter's, outstanding while the baseline seq is still the filter's. Its
echo applied BEFORE the response under the variant, then the guarded
response, gives exactly the replica that the response followed by the
echo gives under the table — whatever the local row is by then. -/
theorem inflight_race_matches_sequential (hash : C → Hash) (r : Replica C) (q : Flight C)
    (row : Row C) (bh : Hash) (hresp : q.resp = some row) (hlive : row.deleted = false)
    (hfresh : q.sentSeq < row.seq) (hbase : r.base q.id = some (bh, q.sentSeq)) :
    (applyRowWith (decideRowInflight (some (hash q.sent))) hash r
        ⟨q.id, row.seq, q.sent, false⟩).recv hash q
      = applyRow hash (r.recv hash q) ⟨q.id, row.seq, q.sent, false⟩ := by
  have hns : ¬ row.seq ≤ q.sentSeq := Nat.not_le.mpr hfresh
  have hne : row.seq ≠ q.sentSeq := Nat.ne_of_gt hfresh
  have hrecv : r.recv hash q = r.setBase q.id (some (hash q.sent, row.seq)) := by
    unfold Replica.recv
    simp [hresp, hbase, hlive]
  rw [hrecv]
  obtain ⟨loc, base, shelf, cursor⟩ := r
  simp only at hbase
  unfold applyRowWith applyRow Replica.recv Replica.setBase decideRowInflight decideRow
    staleOrSeen
  simp only [hbase, hns, hresp, decide_false, and_self, ↓reduceIte, Bool.false_eq_true,
    List.append_nil, Option.map_some, Option.some.injEq, hne]
  simp only [applyRowWith, ↓reduceIte, Nat.le_refl, decide_true, Bool.false_eq_true,
    List.append_nil, Replica.mk.injEq, and_true]
  refine ⟨trivial, ?_⟩
  funext i
  by_cases hi : i = q.id <;> simp [hi]

/-- WITNESS (the variant on both races above): the C2 race leaves the
shelf empty, the baseline `(h1, 6)`, c3 kept, and c3's PATCH lands at
7 — the response-first outcome; the revert race keeps c0 and lands it
at 7, where the table adopted our own c1 over it. -/
theorem inflight_echo_witness :
    let a := (applyRowWith (decideRowInflight (some 1)) id lateR3 ⟨1, 6, 1, false⟩).recv id
      lateFlight
    let b := (applyRowWith (decideRowInflight (some 1)) id (lateR2.edit 1 0)
      ⟨1, 6, 1, false⟩).recv id lateFlight
    a.shelf = [] ∧ a.base 1 = some (1, 6) ∧ a.loc 1 = some 3
      ∧ (pushRow id lateS1 a 1).server.rows 1 = some ⟨3, 7, false⟩
      ∧ b.shelf = [] ∧ b.loc 1 = some 0 ∧ b.base 1 = some (1, 6)
      ∧ (pushRow id lateS1 b 1).server.rows 1 = some ⟨0, 7, false⟩ := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> decide

/-! ### The ineligible verify pass (design interleaving (i))

A holds c0 at 5, edits to c1; the peer writes c2 at 6; A's PATCH
`seq=eq.5` answers `[]` and files `(1, 5, h1)`. A pull fetched BEFORE
the peer's write (its page from cursor 5 is empty) then runs the verify
pass: unseen, `base.seq == sentSeq`, the confirm branch writes
`(h1, 5)` — a pair the server never held. The next pull adopts c2 over
c1 with nothing shelved. That page is not a head page of the server at
verify time, so this pass is not a `Reachable.verify` step. -/

def inelS1 : Server Nat := lateS0.step (.patch 1 5 2)
def inelR3 : Replica Nat := pullVerify id lateR2 [] [⟨1, 5, 1⟩]

theorem ineligible_verify_loses_witness :
    (pushRow id inelS1 lateR2 1).pending = some ⟨1, 5, 1⟩
      ∧ inelR3.base 1 = some (1, 5) ∧ lateS0.rows 1 = some ⟨0, 5, false⟩
      ∧ inelS1.rows 1 = some ⟨2, 6, false⟩
      ∧ (pull id inelR3 [⟨1, 6, 2, false⟩]).loc 1 = some 2
      ∧ (pull id inelR3 [⟨1, 6, 2, false⟩]).shelf = []
      ∧ IsHeadFeed lateS0 lateR2.cursor []
      ∧ ¬ IsHeadFeed inelS1 lateR2.cursor [] := by
  refine ⟨by decide, by decide, by decide, by decide, by decide, by decide, ?_, ?_⟩
  · apply emptyPage_head
    intro i row hr
    by_cases hi : i = 1
    · subst hi
      have h : lateS0.rows 1 = some ⟨0, 5, false⟩ := by decide
      rw [h] at hr; cases hr; decide
    · rw [show lateS0.rows i = none from oneServer_only _ _ i hi] at hr; cases hr
  · intro h
    have hrow : inelS1.rows 1 = some ⟨2, 6, false⟩ := by decide
    obtain ⟨fr, hfr, -⟩ := h.complete 1 _ hrow (by decide)
    cases hfr

/-! ### Runs through the remaining constructors

Instances that put every constructor the runs above do not use on a
reachable run, so no reachable theorem is read off runs that never take
those steps: the guard's PASS branch (`recv` with the baseline still on
the PATCH's seq); a nonempty pending set and the `verify` step that
consumes it; a pending local delete meeting a peer's edit, then
`pushDelete`; a lost response (`lose`). The `restore` step's runs are
in the restore subsection below. And the two runs `Reachable` excludes
here violate `BaseHeld`, so its past-tense content is not vacuous. -/

/-- INSTANCE (the guard's pass branch): the response arrives with the
baseline still `(h0, 5)` and writes `(h1, 6)`. -/
theorem recv_guard_passes_instance :
    Reachable id ⟨lateS1, lateR2.recv id lateFlight, [], [], [lateS0]⟩
      ∧ (lateR2.recv id lateFlight).base 1 = some (1, 6) :=
  ⟨Reachable.recv _ [] [] lateFlight rfl late_prefix_reachable.2, by decide⟩

/-- INSTANCE (`lose`; the residual of `lost_response_residual_witness` on
a reachable run): the PATCH lands c1 at 6, its response is lost, the
user sets the row back to c0 — the baseline's bytes — which reads clean,
so nothing is sent; the server holds c1, and the next pull adopts our
own c1 over the revert with nothing shelved. `clean_iff_matches_server`
is not contradicted: the server row's seq is 6, the baseline's 5. -/
theorem lost_then_revert_reachable :
    Reachable id ⟨lateS1, lateR2.edit 1 0, [], [], [lateS0]⟩
      ∧ CleanAt id (lateR2.edit 1 0) 1 ∧ lateS1.live 1 = some 1
      ∧ (pushRow id lateS1 (lateR2.edit 1 0) 1).server.counter = lateS1.counter
      ∧ (pull id (lateR2.edit 1 0) [⟨1, 6, 1, false⟩]).loc 1 = some 1
      ∧ (pull id (lateR2.edit 1 0) [⟨1, 6, 1, false⟩]).shelf = [] := by
  have h4 := Reachable.lose _ [] [] lateFlight rfl late_prefix_reachable.2
  refine ⟨Reachable.edit _ 1 0 h4, by unfold CleanAt; decide, by decide, by decide, by decide,
    by decide⟩

/-- The pushes of the pending run: c1's PATCH `seq=eq.5` after the peer
wrote c2 at 6 answers `[]` and files `(1, 5, h1)`. -/
def pendPush : PushResult Nat := pushRow id inelS1 lateR2 1
def pendVerified : Replica Nat := pullVerify id lateR2 [⟨1, 6, 2, false⟩] [⟨1, 5, 1⟩]

theorem inelS1_only (i : Id) (hi : i ≠ 1) : inelS1.rows i = none := by
  unfold inelS1; simp only [Server.step]; rw [patch_frame _ _ _ _ _ hi]
  exact oneServer_only _ _ i hi

/-- INSTANCE (a nonempty pending set, and the `verify` step that consumes
it): the peer writes c2 at 6; A's `push` of c1 answers `[]` and files
`(1, 5, h1)`, which `reachable_sound` makes stale; the verify pass on the
head page shows X@6, applies the conflict (c2 shelved, baseline
`(h2, 6)`, c1 kept) and empties the set. -/
theorem pending_filed_and_verified_instance :
    pendPush.server = inelS1 ∧ pendPush.replica = lateR2
      ∧ pendPush.pending = some ⟨1, 5, 1⟩
      ∧ Reachable id ⟨inelS1, lateR2, [⟨1, 5, 1⟩], [], [inelS1, lateS0]⟩
      ∧ PendingStale inelS1 ⟨1, 5, 1⟩
      ∧ Reachable id ⟨inelS1, pendVerified, [], [], [inelS1, lateS0]⟩
      ∧ pendVerified.base 1 = some (2, 6) ∧ pendVerified.shelf = [(1, 2)]
      ∧ pendVerified.loc 1 = some 1 := by
  have hs : pendPush.server = inelS1 := rfl
  have hr : pendPush.replica = lateR2 := rfl
  have hp : pendPush.pending = some ⟨1, 5, 1⟩ := by decide
  have h3 : Reachable id ⟨inelS1, lateR2, [], [], [lateS0]⟩ :=
    Reachable.peer _ (.patch 1 5 2) late_prefix_reachable.1
  have h4 := Reachable.push ⟨inelS1, lateR2, [], [], [lateS0]⟩ 1 (by simp) h3
  have e : (pushRow id inelS1 lateR2 1).pending.toList = [⟨1, 5, 1⟩] := by
    show pendPush.pending.toList = _
    rw [hp]; rfl
  rw [e] at h4
  have h4' : Reachable id ⟨inelS1, lateR2, [⟨1, 5, 1⟩], [], [inelS1, lateS0]⟩ := h4
  have hstale : PendingStale inelS1 ⟨1, 5, 1⟩ :=
    ((reachable_sound id h4').2.2.2.2 ⟨1, 5, 1⟩ (List.mem_singleton_self _)).1
  have hhead : IsHeadFeed inelS1 lateR2.cursor [⟨1, 6, 2, false⟩] :=
    onePage_head _ _ _ (by decide) (by decide) inelS1_only
  have h5 := Reachable.verify _ _ hhead h4'
  exact ⟨hs, hr, hp, h4', hstale, h5, by decide, by decide, by decide⟩

/-- The pending-delete run: A deletes X locally (c0's baseline stays);
the peer writes c2 at 6; A's pull applies the pending-delete row (local
stays absent, c2 shelved, baseline `(h2, 6)`); `pushDelete` tombstones
the server row and drops the entry. -/
def delR3 : Replica Nat := lateR1.deleteLocal 1
def delR4 : Replica Nat := pull id delR3 [⟨1, 6, 2, false⟩]

theorem inelS1_feed (r : Replica Nat) (hc : r.cursor = 5) :
    IsPageFeed inelS1 r.cursor 6 [⟨1, 6, 2, false⟩] := by
  rw [hc]
  exact onePage_feed _ _ _ _ (by decide) (by decide) (Nat.le_refl _) inelS1_only

/-- INSTANCE (`deleteLocal`, the pending-delete row and `pushDelete` on a
reachable run). -/
theorem pending_delete_run_instance :
    Reachable id ⟨(pushDelete inelS1 delR4 1).server, (pushDelete inelS1 delR4 1).replica,
        [], [], [inelS1, lateS0]⟩
      ∧ delR4.loc 1 = none ∧ delR4.base 1 = some (2, 6) ∧ delR4.shelf = [(1, 2)]
      ∧ (pushDelete inelS1 delR4 1).server.live 1 = none
      ∧ (pushDelete inelS1 delR4 1).server.rows 1 = some ⟨2, 7, true⟩
      ∧ (pushDelete inelS1 delR4 1).replica.base 1 = none := by
  have hwf0 : lateS0.WF := oneServer_wf _ _ (Nat.le_refl _)
  have h0 : Reachable id ⟨lateS0, lateR0, [], [], []⟩ :=
    Reachable.init lateS0 lateR0 hwf0 (fun i => by simp [lateR0, oneRowAt, oneRow])
      (Nat.zero_le _) (oneServer_fresh0 _ _ (by decide))
  have h1 : Reachable id ⟨lateS0, lateR1, [], [], []⟩ :=
    Reachable.pull ⟨lateS0, lateR0, [], [], []⟩ lateS0 5 [⟨1, 5, 0, false⟩]
      (List.mem_cons_self ..) (Nat.zero_le _)
      (onePage_feed _ _ _ _ rfl (by decide) (Nat.le_refl _) (oneServer_only _ _)) h0
  have h2 : Reachable id ⟨lateS0, delR3, [], [], []⟩ := Reachable.deleteLocal _ 1 h1
  have h3 : Reachable id ⟨inelS1, delR3, [], [], [lateS0]⟩ := Reachable.peer _ (.patch 1 5 2) h2
  have h4 : Reachable id ⟨inelS1, delR4, [], [], [lateS0]⟩ :=
    Reachable.pull _ inelS1 6 [⟨1, 6, 2, false⟩] (List.mem_cons_self ..) (by decide)
      (inelS1_feed _ (by decide)) h3
  exact ⟨Reachable.pushDelete _ 1 h4, by decide, by decide, by decide, by decide, by decide,
    by decide⟩

/-- `BaseHeld` excludes the ineligible verify pass: its confirm writes
`(h1, 5)`, but at seq 5 every state of the run held c0. -/
theorem ineligible_verify_not_held : ¬ BaseHeld id [inelS1, lateS0] inelR3 := by
  intro h
  obtain ⟨s', hs', row, hrow, hseq, -, hh⟩ := h 1 1 5 (by decide)
  simp only [List.mem_cons, List.not_mem_nil, or_false] at hs'
  rcases hs' with rfl | rfl
  · have e : inelS1.rows 1 = some ⟨2, 6, false⟩ := by decide
    rw [e] at hrow; cases hrow; cases hseq
  · have e : lateS0.rows 1 = some ⟨0, 5, false⟩ := by decide
    rw [e] at hrow; cases hrow; cases hh

/-- `BaseHeld` excludes the unguarded late write followed by the confirm:
the baseline `(h3, 6)` names c3 at seq 6, where the run held only c1. -/
theorem unguarded_confirm_not_held :
    ¬ BaseHeld id [lateS2, lateS1, lateS0] (pullVerify id lateU5 [] [⟨1, 6, 3⟩]) := by
  intro h
  obtain ⟨s', hs', row, hrow, hseq, -, hh⟩ := h 1 3 6 (by decide)
  simp only [List.mem_cons, List.not_mem_nil, or_false] at hs'
  rcases hs' with rfl | rfl | rfl
  · have e : lateS2.rows 1 = some ⟨2, 7, false⟩ := by decide
    rw [e] at hrow; cases hrow; cases hseq
  · have e : lateS1.rows 1 = some ⟨1, 6, false⟩ := by decide
    rw [e] at hrow; cases hrow; cases hh
  · have e : lateS0.rows 1 = some ⟨0, 5, false⟩ := by decide
    rw [e] at hrow; cases hrow; cases hseq

/-! ### The I1 loop with a cut page and a peer write between pages

An instance of `pull_pages_converge_reachable` through `Chain.cons`, so
the multi-page form of T5' is shown on more than the empty run (where it
is T5): a fresh replica, a server with X (id 1) at 6 and Y (id 2) at 7;
the first page is cut at 6 (X only); the peer then edits X to 11 at 8;
the last page, from cursor 6, is the head page (Y@7, X@8). -/

def mpS0 : Server Nat :=
  { rows := fun i => if i = 1 then some ⟨10, 6, false⟩ else if i = 2 then some ⟨20, 7, false⟩
      else none
    counter := 7 }
def mpS1 : Server Nat := mpS0.step (.patch 1 6 11)
def mpR0 : Replica Nat := { loc := fun _ => none, base := fun _ => none, shelf := [], cursor := 0 }
def mpPage1 : List (FeedRow Nat) := [⟨1, 6, 10, false⟩]
def mpPage2 : List (FeedRow Nat) := [⟨2, 7, 20, false⟩, ⟨1, 8, 11, false⟩]

theorem mpS0_rows (i : Id) (h1 : i ≠ 1) (h2 : i ≠ 2) : mpS0.rows i = none := by
  simp [mpS0, h1, h2]

theorem mpS1_rows (i : Id) (h1 : i ≠ 1) (h2 : i ≠ 2) : mpS1.rows i = none := by
  unfold mpS1; simp only [Server.step]; rw [patch_frame _ _ _ _ _ h1]; exact mpS0_rows i h1 h2

theorem mpS0_wf : mpS0.WF := by
  intro i row hr
  by_cases h1 : i = 1
  · subst h1; simp [mpS0] at hr; subst hr; decide
  · by_cases h2 : i = 2
    · subst h2; simp [mpS0] at hr; subst hr; decide
    · rw [mpS0_rows i h1 h2] at hr; cases hr

theorem mpPage1_feed : IsPageFeed mpS0 mpR0.cursor 6 mpPage1 := by
  refine ⟨?_, ?_, List.pairwise_singleton _ _⟩
  · intro fr hfr
    simp only [mpPage1, List.mem_singleton] at hfr
    subst hfr
    decide
  · intro i row hr _ hle
    by_cases h1 : i = 1
    · exact ⟨_, List.mem_singleton_self _, h1.symm⟩
    · by_cases h2 : i = 2
      · subst h2; simp [mpS0] at hr; subst hr; exact absurd hle (by decide)
      · rw [mpS0_rows i h1 h2] at hr; cases hr

theorem mpPage2_head : IsHeadFeed mpS1 (pullAll id mpR0 [(mpS0, mpPage1)]).cursor mpPage2 := by
  have hc : (pullAll id mpR0 [(mpS0, mpPage1)]).cursor = 6 := by decide
  rw [hc]
  refine ⟨?_, ?_, ?_⟩
  · intro fr hfr
    simp only [mpPage2, List.mem_cons, List.not_mem_nil, or_false] at hfr
    rcases hfr with rfl | rfl <;> decide
  · intro i row hr _
    by_cases h1 : i = 1
    · exact ⟨⟨1, 8, 11, false⟩, by simp [mpPage2], h1.symm⟩
    · by_cases h2 : i = 2
      · exact ⟨⟨2, 7, 20, false⟩, by simp [mpPage2], h2.symm⟩
      · rw [mpS1_rows i h1 h2] at hr; cases hr
  · decide

/-- INSTANCE (T5' through `Chain.cons`): the fresh replica is reachable
and clean and in sync below its cursor, the cut page and the peer's
write form a run, and the head page lands every id on the server's live
content — X on the peer's 11 — with nothing shelved. -/
theorem pull_pages_converge_reachable_instance :
    (∀ i, (pull id (pullAll id mpR0 [(mpS0, mpPage1)]) mpPage2).loc i = mpS1.live i)
      ∧ (pull id (pullAll id mpR0 [(mpS0, mpPage1)]) mpPage2).shelf = []
      ∧ (pull id (pullAll id mpR0 [(mpS0, mpPage1)]) mpPage2).loc 1 = some 11 := by
  have hinj : HashInjective (id : Nat → Hash) := fun _ _ h => h
  have hpos : ∀ i row, mpS0.rows i = some row → 0 < row.seq := by
    intro i row hr
    by_cases h1 : i = 1
    · subst h1; simp [mpS0] at hr; subst hr; decide
    · by_cases h2 : i = 2
      · subst h2; simp [mpS0] at hr; subst hr; decide
      · rw [mpS0_rows i h1 h2] at hr; cases hr
  have hreach : Reachable id ⟨mpS0, mpR0, [], [], []⟩ :=
    Reachable.init mpS0 mpR0 mpS0_wf (fun _ => rfl) (Nat.zero_le _)
      (fun i row hr hle => absurd hle (Nat.not_le.mpr (hpos i row hr)))
  obtain ⟨-, hclean, -, -⟩ :=
    fresh_replica_premises id mpS0 mpS0_wf hpos mpR0 (fun _ => rfl) (fun _ => rfl) rfl
  have hchain : Chain id mpS0 mpR0 [(mpS0, mpPage1)] mpS0 :=
    Chain.cons mpS0 mpS0 mpS0 mpR0 mpPage1 [] (advances_refl _) 6 mpPage1_feed (Chain.nil _ _)
  obtain ⟨hl, hsh, -⟩ := pull_pages_converge_reachable id hinj hreach hclean hchain
    (step_advances mpS0 (.patch 1 6 11)) mpPage2 mpPage2_head
  exact ⟨hl, hsh, by rw [hl 1]; decide⟩

/-! ### A POST's response arriving late (not a `Reachable` step)

`Reachable` has no late POST response; the text writes the POST's
`[row]` as `(hash sent, seq)` whenever it arrives. Two guards it could
state instead, on concrete runs. A holds c1 with no baseline (cursor 5);
its ignore-duplicates POST lands c1 at 6 with the response outstanding.
"Entry still absent" writes `(hash sent, seq)` if the baseline has no
entry for the id; "entry still absent and the cursor below seq" also
drops it once a pull has covered that seq. -/

/-- The late POST `[row]` under "entry still absent". -/
def Replica.recvPostAbsent (hash : C → Hash) (r : Replica C) (id : Id) (sent : C) (seq : Seq) :
    Replica C :=
  if r.base id = none then r.setBase id (some (hash sent, seq)) else r

/-- The late POST `[row]` under "entry still absent and the cursor below
its seq". -/
def Replica.recvPostCovered (hash : C → Hash) (r : Replica C) (id : Id) (sent : C) (seq : Seq) :
    Replica C :=
  if r.base id = none ∧ r.cursor < seq then r.setBase id (some (hash sent, seq)) else r

def postS0 : Server Nat := oneServer none 5
def postR0 : Replica Nat := oneRowAt (some 1) none 5
def postS1 : Server Nat := (postS0.insertIgnore 1 1).1
/-- Run 1: the user deletes X before the response. -/
def postDel : Replica Nat := postR0.deleteLocal 1
/-- Run 2: the peer tombstones X at 7 and A pulls it before the response. -/
def postS2 : Server Nat := postS1.step (.tombstone 1)
def postTomb : Replica Nat := pull id postR0 [⟨1, 7, 1, true⟩]
/-- Run 3: the peer writes id 2 at 7 and edits X to c2 at 8; A pulls a
limit-cut page from 5 cut at 7 — id 2 only, X is past the cut — then the
response arrives, then the next page shows X@8. -/
def postS3 : Server Nat := (postS1.step (.insertIgnore 2 5)).step (.patch 1 6 2)
def postCut : Replica Nat := pull id postR0 [⟨2, 7, 5, false⟩]

/-- WITNESS (the late POST guards): neither cursor-free test reproduces the
response-first order on all three runs. Run 1: the response must be
written although the local row is absent — `pushDelete` then tombstones
the server row; dropping it lets the echo put the deleted row back.
Run 2: the pull shelved our own c1 and removed the row; "entry still
absent" then writes a phantom entry for the absent row — harmless (the
next tombstone PATCH is a no-op on the dead row and drops it) unless an
undo re-adds c1 first, which then reads clean against a dead server row
and sends nothing; "cursor below seq" drops it, as the response-first
order has no entry either. Run 3: "entry still absent" writes `(h1, 6)`
and the next page adopts the peer's c2, as the response-first order
does; "cursor below seq" drops the response because the cut page moved
the cursor past 6 without showing X, and the next page files c2 as a
conflict — c2 shelved, our older c1 kept and uploaded over it. -/
theorem late_post_response_guards_witness :
    postS1.rows 1 = some ⟨1, 6, false⟩
      ∧ (postDel.recvPostAbsent id 1 1 6).base 1 = some (1, 6)
      ∧ (postDel.recvPostCovered id 1 1 6).base 1 = some (1, 6)
      ∧ (pushDelete postS1 (postDel.recvPostAbsent id 1 1 6) 1).server.live 1 = none
      ∧ (pull id postDel [⟨1, 6, 1, false⟩]).loc 1 = some 1
      ∧ postS2.rows 1 = some ⟨1, 7, true⟩
      ∧ postTomb.loc 1 = none ∧ postTomb.base 1 = none ∧ postTomb.shelf = [(1, 1)]
      ∧ (postTomb.recvPostAbsent id 1 1 6).base 1 = some (1, 6)
      ∧ (pushDelete postS2 (postTomb.recvPostAbsent id 1 1 6) 1).server.rows 1 = postS2.rows 1
      ∧ (pushDelete postS2 (postTomb.recvPostAbsent id 1 1 6) 1).replica.base 1 = none
      ∧ (pushRow id postS2 ((postTomb.recvPostAbsent id 1 1 6).edit 1 1) 1).needsPull = false
      ∧ (pushRow id postS2 ((postTomb.recvPostAbsent id 1 1 6).edit 1 1) 1).server.counter = 7
      ∧ (postTomb.recvPostCovered id 1 1 6).base 1 = none
      ∧ (pull id (postR0.setBase 1 (some (1, 6))) [⟨1, 7, 1, true⟩]).base 1 = none
      ∧ postS3.rows 1 = some ⟨2, 8, false⟩ ∧ postS3.rows 2 = some ⟨5, 7, false⟩
      ∧ postCut.cursor = 7
      ∧ (pull id (postCut.recvPostAbsent id 1 1 6) [⟨1, 8, 2, false⟩]).loc 1 = some 2
      ∧ (pull id (postCut.recvPostAbsent id 1 1 6) [⟨1, 8, 2, false⟩]).shelf = []
      ∧ (pull id (pull id (postR0.setBase 1 (some (1, 6))) [⟨2, 7, 5, false⟩])
          [⟨1, 8, 2, false⟩]).loc 1 = some 2
      ∧ (postCut.recvPostCovered id 1 1 6).base 1 = none
      ∧ (pull id (postCut.recvPostCovered id 1 1 6) [⟨1, 8, 2, false⟩]).loc 1 = some 1
      ∧ (pull id (postCut.recvPostCovered id 1 1 6) [⟨1, 8, 2, false⟩]).shelf = [(1, 2)]
      ∧ (pushRow id postS3 (pull id (postCut.recvPostCovered id 1 1 6) [⟨1, 8, 2, false⟩])
          1).server.rows 1 = some ⟨1, 9, false⟩ := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_,
    ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> decide

/-! ### Restore's baseline replay

`Reachable.restore` is the merge rule that keeps a pending local
delete, the replay, then the rewind. The runs below put it on reachable
runs (a merge keeping local, a merge over a pending local delete, a
merge of a snapshot missing a row, an overwrite); run the two replays
before 7a2e382e, with the rewind, under the same premises
(`ReachableRestoreWith` with `fixedStep`); run the Swift as of 9121ba12,
which brings a pending delete back (`step9121`); and run the Swift as of
7a2e382e, without the rewind (`unfixedStep`). Each control reaches a
state, or a step, that a theorem proved for every reachable state, or
every restore, rules out.

`restore_replay_local_hash_witness` is slice 1's writing on bare states:
for a keepLocal collision row — local c1, the cloud's row c2 at seq 6 —
`(hash(local row), previous seq)` reads clean while the server holds c2:
nothing is uploaded, and the state violates `BaseHashSound`. The
cloud-row writing `(hash(cloud row), cloud seq)` reads dirty and the next
PATCH `seq=eq.6` lands c1. `slice1_collision_clean_control` reaches the
same pair of states by a run. -/

def restoreServer : Server Nat := oneServer (some ⟨2, 6, false⟩) 6
def restoreLocalHash : Replica Nat := oneRowAt (some 1) (some (1, 6)) 6
def restoreCloudHash : Replica Nat := oneRowAt (some 1) (some (2, 6)) 6

theorem restore_replay_local_hash_witness :
    CleanAt id restoreLocalHash 1
      ∧ pushRow id restoreServer restoreLocalHash 1
          = ⟨restoreServer, restoreLocalHash, false, none⟩
      ∧ restoreServer.live 1 = some 2
      ∧ ¬ BaseHashSound id restoreServer restoreLocalHash
      ∧ ¬ CleanAt id restoreCloudHash 1
      ∧ (pushRow id restoreServer restoreCloudHash 1).server.rows 1 = some ⟨1, 7, false⟩ := by
  refine ⟨by unfold CleanAt; decide, rfl, by decide, ?_, by unfold CleanAt; decide, by decide⟩
  intro h
  have := h 1 1 6 ⟨2, 6, false⟩ (by decide) (by decide) rfl
  cases this

/-- A snapshot carrying one row, at id 1; the empty snapshot; every
collision keeping the local row, or taking the cloud's. -/
def snapAt1 (c : Nat) (S : Seq) : Snapshot Nat := fun i => if i = 1 then some (c, S) else none
def snapNone : Snapshot Nat := fun _ => none
def keepLocalAll : Id → Bool := fun _ => false
def keepCloudAll : Id → Bool := fun _ => true

theorem snapAt1_some {c c' : Nat} {S S' : Seq} {i : Id} (h : snapAt1 c S i = some (c', S')) :
    i = 1 ∧ c' = c ∧ S' = S := by
  unfold snapAt1 at h
  by_cases hi : i = 1
  · rw [if_pos hi] at h; cases h; exact ⟨hi, rfl, rfl⟩
  · rw [if_neg hi] at h; cases h

theorem snapNone_none {i : Id} {c : Nat} {S : Seq} (h : snapNone i = some (c, S)) : False := by
  simp [snapNone] at h

/-- `hread` for a one-row snapshot read at `s0`. -/
theorem snapAt1_read {c : Nat} {S C0 : Seq} {hist : List (Server Nat)} {s0 : Server Nat}
    (hmem : s0 ∈ hist) (hrow : s0.rows 1 = some ⟨c, S, false⟩) (hC0 : C0 ≤ s0.counter) :
    ∀ i c' S', snapAt1 c S i = some (c', S') →
      ∃ s' ∈ hist, s'.rows i = some ⟨c', S', false⟩ ∧ C0 ≤ s'.counter := by
  intro i c' S' h
  obtain ⟨rfl, rfl, rfl⟩ := snapAt1_some h
  exact ⟨s0, hmem, hrow, hC0⟩

/-- `hall` for a one-row snapshot of a state whose only live row it is. -/
theorem snapAt1_all {c : Nat} {S C0 : Seq} {hist : List (Server Nat)} {s0 : Server Nat}
    (hmem : s0 ∈ hist) (hC0 : C0 ≤ s0.counter)
    (hlive : ∀ i row, s0.rows i = some row → row.deleted = false →
      i = 1 ∧ row = ⟨c, S, false⟩) :
    ∃ s' ∈ hist, C0 ≤ s'.counter ∧ ∀ i row, s'.rows i = some row → row.deleted = false →
      snapAt1 c S i = some (row.content, row.seq) := by
  refine ⟨s0, hmem, hC0, ?_⟩
  intro i row h hd
  obtain ⟨rfl, rfl⟩ := hlive i row h hd
  rfl

theorem snapNone_read {C0 : Seq} {hist : List (Server Nat)} :
    ∀ i c S, snapNone i = some (c, S) →
      ∃ s' ∈ hist, s'.rows i = some ⟨c, S, false⟩ ∧ C0 ≤ s'.counter :=
  fun _ _ _ h => (snapNone_none h).elim

/-- `hall` for the empty snapshot of a state with no live row. -/
theorem snapNone_all {C0 : Seq} {hist : List (Server Nat)} {s0 : Server Nat}
    (hmem : s0 ∈ hist) (hC0 : C0 ≤ s0.counter)
    (hdead : ∀ i row, s0.rows i = some row → row.deleted = true) :
    ∃ s' ∈ hist, C0 ≤ s'.counter ∧ ∀ i row, s'.rows i = some row → row.deleted = false →
      snapNone i = some (row.content, row.seq) := by
  refine ⟨s0, hmem, hC0, ?_⟩
  intro i row h hd
  rw [hdead i row h] at hd; cases hd

theorem lateR1_reachable : Reachable id ⟨lateS0, lateR1, [], [], []⟩ := by
  have hwf0 : lateS0.WF := oneServer_wf _ _ (Nat.le_refl _)
  have h0 : Reachable id ⟨lateS0, lateR0, [], [], []⟩ :=
    Reachable.init lateS0 lateR0 hwf0 (fun i => by simp [lateR0, oneRowAt, oneRow])
      (Nat.zero_le _) (oneServer_fresh0 _ _ (by decide))
  exact Reachable.pull ⟨lateS0, lateR0, [], [], []⟩ lateS0 5 [⟨1, 5, 0, false⟩]
    (List.mem_cons_self ..) (Nat.zero_le _)
    (onePage_feed _ _ _ _ rfl (by decide) (Nat.le_refl _) (oneServer_only _ _)) h0

/-! #### The replay before 7a2e382e: a row the cloud never had

A row made while uploads were off — never sent, no entry, no server row
— and a merge restore whose snapshot does not carry it. Both replays run
with the rewind (`fixedStep`), so the control differs from the theorem in
the replay alone. -/

def ctl1S : Server Nat := oneServer none 5
def ctl1R : Replica Nat := (oneRowAt none none 0).edit 1 7
def ctl1Pre : Replica Nat :=
  ctl1R.restoreFixedWith (replayBaselinePre id) false keepLocalAll snapNone 0
def ctl1Now : Replica Nat := ctl1R.restore id false keepLocalAll snapNone 0

theorem ctl1S_dead : ∀ i row, ctl1S.rows i = some row → row.deleted = true := by
  intro i row h; simp [ctl1S, oneServer] at h

theorem ctl1R_reachable : Reachable id ⟨ctl1S, ctl1R, [], [], []⟩ := by
  have hwf : ctl1S.WF := by intro i row h; simp [ctl1S, oneServer] at h
  exact Reachable.edit _ 1 7 (Reachable.init ctl1S (oneRowAt none none 0) hwf
    (fun i => by simp [oneRowAt, oneRow]) (Nat.zero_le _)
    (fun i row h _ => ctl1S_dead i row h))

/-- CONTROL (`unsent_row_never_clean` — the property the shipped bug broke
— under the replay before 7a2e382e): the old replay gives the row
`(hash row, ·)` (seq-less in the Swift; `seqlessStandIn` here, which
nothing below reads), so it reads clean while the server holds no row
for it, and pushing it sends nothing — on this flush and every later
one. The theorem, restated over the set with that replay, is false. With
the current replay the row keeps no entry, and its POST lands. -/
theorem pre_merge_unsent_row_clean_control :
    ReachableRestoreWith id (fixedStep (replayBaselinePre id)) ⟨ctl1S, ctl1Pre, [], [], []⟩
      ∧ ctl1Pre.loc 1 = some 7 ∧ ctl1S.rows 1 = none ∧ CleanAt id ctl1Pre 1
      ∧ (pushRow id ctl1S ctl1Pre 1).server.counter = ctl1S.counter
      ∧ (pushRow id ctl1S ctl1Pre 1).needsPull = false
      ∧ (¬ ∀ sys : Sys Nat, ReachableRestoreWith id (fixedStep (replayBaselinePre id)) sys →
          ∀ i c, sys.replica.loc i = some c → sys.server.rows i = none →
            ¬ CleanAt id sys.replica i)
      ∧ Reachable id ⟨ctl1S, ctl1Now, [], [], []⟩
      ∧ ctl1Now.base 1 = none
      ∧ (pushRow id ctl1S ctl1Now 1).server.rows 1 = some ⟨7, 6, false⟩ := by
  have hall := snapNone_all (C0 := 0) (List.mem_cons_self (a := ctl1S) (l := []))
    (Nat.zero_le _) ctl1S_dead
  have hr : ReachableRestoreWith id (fixedStep (replayBaselinePre id))
      ⟨ctl1S, ctl1Pre, [], [], []⟩ :=
    ReachableRestoreWith.restore _ false keepLocalAll snapNone 0 snapNone_read (fun _ => hall)
      ctl1R_reachable
  have hclean : CleanAt id ctl1Pre 1 := by unfold CleanAt; decide
  refine ⟨hr, by decide, by decide, hclean, by decide, by decide, ?_, ?_, by decide, by decide⟩
  · intro H
    exact H _ hr 1 7 (by decide) (by decide) hclean
  · exact Reachable.restore _ false keepLocalAll snapNone 0 snapNone_read (fun _ => hall) ctl1R_reachable

/-! #### The replay before 7a2e382e: a row edited after its last upload

The previous-seq case, which the model represents exactly: the device
holds X as the server does; a peer deletes X; this device, not having
pulled the tombstone, edits X, then merge-restores — the fetch skips
dead rows, so the snapshot does not carry X. -/

def ctl2S : Server Nat := lateS0.step (.tombstone 1)
def ctl2R : Replica Nat := lateR1.edit 1 3
def ctl2Pre : Replica Nat :=
  ctl2R.restoreFixedWith (replayBaselinePre id) false keepLocalAll snapNone 5
def ctl2Now : Replica Nat := ctl2R.restore id false keepLocalAll snapNone 5

theorem ctl2S_only (i : Id) (hi : i ≠ 1) : ctl2S.rows i = none := by
  simp [ctl2S, Server.step, Server.tombstone, lateS0, oneServer, Server.setRow, hi]

theorem ctl2S_dead : ∀ i row, ctl2S.rows i = some row → row.deleted = true := by
  intro i row h
  by_cases hi : i = 1
  · subst hi
    have e : ctl2S.rows 1 = some ⟨0, 6, true⟩ := by decide
    rw [e] at h; cases h; rfl
  · rw [ctl2S_only i hi] at h; cases h

theorem ctl2R_reachable : Reachable id ⟨ctl2S, ctl2R, [], [], [lateS0]⟩ :=
  Reachable.edit _ 1 3 (Reachable.peer _ (.tombstone 1) lateR1_reachable)

/-- CONTROL (`reachable_sound`'s `BaseHeld`, under the replay before
7a2e382e): the old replay writes the edit's hash at the seq of the
version before it — a pair no state of the run held — and the row reads
clean; the head pull of the tombstone then removes the edit without
shelving it, as I7 allows for a clean row, and the edit is on no device,
server or shelf. `BaseHeld`, restated over the set with that replay, is
false. With the current replay the entry the row had stays, the row
stays dirty, and the same pull shelves the edit
(`dirty_local_vs_tombstone_shelved`). -/
theorem pre_merge_previous_seq_control :
    ReachableRestoreWith id (fixedStep (replayBaselinePre id))
        ⟨ctl2S, ctl2Pre, [], [], [lateS0]⟩
      ∧ ctl2S.rows 1 = some ⟨0, 6, true⟩
      ∧ ctl2Pre.base 1 = some (3, 5) ∧ CleanAt id ctl2Pre 1
      ∧ ¬ BaseHeld id [ctl2S, lateS0] ctl2Pre
      ∧ (¬ ∀ sys : Sys Nat, ReachableRestoreWith id (fixedStep (replayBaselinePre id)) sys →
          BaseHeld id (sys.server :: sys.past) sys.replica)
      ∧ IsHeadFeed ctl2S ctl2Pre.cursor [⟨1, 6, 0, true⟩]
      ∧ (pull id ctl2Pre [⟨1, 6, 0, true⟩]).loc 1 = none
      ∧ (pull id ctl2Pre [⟨1, 6, 0, true⟩]).shelf = []
      ∧ Reachable id ⟨ctl2S, ctl2Now, [], [], [lateS0]⟩
      ∧ ctl2Now.base 1 = some (0, 5) ∧ ¬ CleanAt id ctl2Now 1
      ∧ (pull id ctl2Now [⟨1, 6, 0, true⟩]).loc 1 = none
      ∧ (pull id ctl2Now [⟨1, 6, 0, true⟩]).shelf = [(1, 3)] := by
  have hall := snapNone_all (C0 := 5) (List.mem_cons_self (a := ctl2S) (l := [lateS0]))
    (by decide) ctl2S_dead
  have hr : ReachableRestoreWith id (fixedStep (replayBaselinePre id))
      ⟨ctl2S, ctl2Pre, [], [], [lateS0]⟩ :=
    ReachableRestoreWith.restore _ false keepLocalAll snapNone 5 snapNone_read (fun _ => hall)
      ctl2R_reachable
  have hnot : ¬ BaseHeld id [ctl2S, lateS0] ctl2Pre := by
    intro h
    obtain ⟨s', hs', row, hrow, hseq, -, hh⟩ := h 1 3 5 (by decide)
    simp only [List.mem_cons, List.not_mem_nil, or_false] at hs'
    rcases hs' with rfl | rfl
    · have e : ctl2S.rows 1 = some ⟨0, 6, true⟩ := by decide
      rw [e] at hrow; cases hrow; cases hseq
    · have e : lateS0.rows 1 = some ⟨0, 5, false⟩ := by decide
      rw [e] at hrow; cases hrow; cases hh
  refine ⟨hr, by decide, by decide, by unfold CleanAt; decide, hnot, ?_,
    onePage_head _ _ _ (by decide) (by decide) ctl2S_only, by decide, by decide, ?_, by decide,
    by unfold CleanAt; decide, by decide, by decide⟩
  · intro H
    exact hnot (H _ hr)
  · exact Reachable.restore _ false keepLocalAll snapNone 5 snapNone_read (fun _ => hall) ctl2R_reachable

/-! #### Slice 1's replay: a keepLocal collision row

The device pulled X, edited it, and restores a snapshot carrying the
server's current row for X. -/

def ctl3R : Replica Nat := (pull id (oneRowAt none none 0) [⟨1, 6, 2, false⟩]).edit 1 1
def ctl3Slice1 : Replica Nat :=
  ctl3R.restoreFixedWith (replayBaselineSlice1 id) false keepLocalAll (snapAt1 2 6) 6
def ctl3Now : Replica Nat := ctl3R.restore id false keepLocalAll (snapAt1 2 6) 6
def ctl3Over : Replica Nat := ctl3R.restore id true keepLocalAll (snapAt1 2 6) 6

theorem ctl3R_reachable : Reachable id ⟨restoreServer, ctl3R, [], [], []⟩ := by
  have hwf : restoreServer.WF := oneServer_wf _ _ (Nat.le_refl _)
  have h0 : Reachable id ⟨restoreServer, oneRowAt none none 0, [], [], []⟩ :=
    Reachable.init _ _ hwf (fun i => by simp [oneRowAt, oneRow]) (Nat.zero_le _)
      (oneServer_fresh0 _ _ (by decide))
  exact Reachable.edit _ 1 1 (Reachable.pull _ restoreServer 6 [⟨1, 6, 2, false⟩]
    (List.mem_cons_self ..) (Nat.zero_le _)
    (onePage_feed _ _ _ _ rfl (by decide) (Nat.le_refl _) (oneServer_only _ _)) h0)

theorem ctl3_read : ∀ i c S, snapAt1 2 6 i = some (c, S) →
    ∃ s' ∈ restoreServer :: ([] : List (Server Nat)),
      s'.rows i = some ⟨c, S, false⟩ ∧ 6 ≤ s'.counter :=
  snapAt1_read (List.mem_cons_self ..) rfl (Nat.le_refl _)

theorem ctl3_all : ∃ s' ∈ restoreServer :: ([] : List (Server Nat)), 6 ≤ s'.counter ∧
    ∀ i row, s'.rows i = some row → row.deleted = false →
      snapAt1 2 6 i = some (row.content, row.seq) :=
  snapAt1_all (List.mem_cons_self ..) (Nat.le_refl _) (oneServer_live _ _)

/-- CONTROL (`reachable_sound`'s `BaseHashSound`, and
`clean_iff_matches_server`, under slice 1's replay): slice 1 writes the
edit's hash at the cloud row's seq — the pair
`restore_replay_local_hash_witness` starts from: the row reads clean,
the local row is not the server's, nothing is sent. Both theorems,
restated over the set with slice 1's replay, are false. With the current
replay the entry is the cloud row's, the row is dirty and its PATCH on
the cloud's seq lands the edit; an overwrite instead takes the cloud
row and reads clean — the two truth values of `clean_iff_matches_server`
on restored states. -/
theorem slice1_collision_clean_control :
    ReachableRestoreWith id (fixedStep (replayBaselineSlice1 id))
        ⟨restoreServer, ctl3Slice1, [], [], []⟩
      ∧ ctl3Slice1.loc 1 = some 1 ∧ ctl3Slice1.base 1 = some (1, 6)
      ∧ CleanAt id ctl3Slice1 1 ∧ ctl3Slice1.loc 1 ≠ restoreServer.live 1
      ∧ ¬ BaseHashSound id restoreServer ctl3Slice1
      ∧ (pushRow id restoreServer ctl3Slice1 1).server.counter = restoreServer.counter
      ∧ (¬ ∀ sys : Sys Nat, ReachableRestoreWith id (fixedStep (replayBaselineSlice1 id)) sys →
          BaseHashSound id sys.server sys.replica)
      ∧ (¬ ∀ sys : Sys Nat, ReachableRestoreWith id (fixedStep (replayBaselineSlice1 id)) sys →
          ∀ i h S row, sys.replica.base i = some (h, S) → sys.server.rows i = some row →
            row.seq = S → (CleanAt id sys.replica i ↔ sys.replica.loc i = sys.server.live i))
      ∧ Reachable id ⟨restoreServer, ctl3Now, [], [], []⟩
      ∧ ctl3Now.base 1 = some (2, 6) ∧ ¬ CleanAt id ctl3Now 1
      ∧ ctl3Now.loc 1 ≠ restoreServer.live 1
      ∧ (pushRow id restoreServer ctl3Now 1).server.rows 1 = some ⟨1, 7, false⟩
      ∧ Reachable id ⟨restoreServer, ctl3Over, [], [], []⟩
      ∧ CleanAt id ctl3Over 1 ∧ ctl3Over.loc 1 = restoreServer.live 1 := by
  have hr : ReachableRestoreWith id (fixedStep (replayBaselineSlice1 id))
      ⟨restoreServer, ctl3Slice1, [], [], []⟩ :=
    ReachableRestoreWith.restore _ false keepLocalAll (snapAt1 2 6) 6 ctl3_read (fun _ => ctl3_all)
      ctl3R_reachable
  have hclean : CleanAt id ctl3Slice1 1 := by unfold CleanAt; decide
  have hne : ctl3Slice1.loc 1 ≠ restoreServer.live 1 := by decide
  have hns : ¬ BaseHashSound id restoreServer ctl3Slice1 := by
    intro h
    have := h 1 1 6 ⟨2, 6, false⟩ (by decide) (by decide) rfl
    cases this
  refine ⟨hr, by decide, by decide, hclean, hne, hns, by decide, ?_, ?_, ?_, by decide,
    by unfold CleanAt; decide, by decide, by decide, ?_, by unfold CleanAt; decide, by decide⟩
  · intro H
    exact hns (H _ hr)
  · intro H
    exact hne ((H _ hr 1 1 6 ⟨2, 6, false⟩ (by decide) (by decide) rfl).mp hclean)
  · exact Reachable.restore _ false keepLocalAll (snapAt1 2 6) 6 ctl3_read (fun _ => ctl3_all)
      ctl3R_reachable
  · exact Reachable.restore _ true keepLocalAll (snapAt1 2 6) 6 ctl3_read (fun _ => ctl3_all)
      ctl3R_reachable

/-! #### A merge restore over a pending local delete

The device deletes X (the entry stays, the tombstone PATCH not yet sent)
and merge-restores. -/

def pdR : Replica Nat := delR3.restore id false keepLocalAll (snapAt1 0 5) 5
def pd9121 : Replica Nat := delR3.restore9121 id false keepLocalAll (snapAt1 0 5) 5

theorem lateS0_read : ∀ i c S, snapAt1 0 5 i = some (c, S) →
    ∃ s' ∈ lateS0 :: ([] : List (Server Nat)), s'.rows i = some ⟨c, S, false⟩ ∧ 5 ≤ s'.counter :=
  snapAt1_read (List.mem_cons_self ..) rfl (Nat.le_refl _)

theorem lateS0_all : ∃ s' ∈ lateS0 :: ([] : List (Server Nat)), 5 ≤ s'.counter ∧
    ∀ i row, s'.rows i = some row → row.deleted = false →
      snapAt1 0 5 i = some (row.content, row.seq) :=
  snapAt1_all (List.mem_cons_self ..) (Nat.le_refl _) (oneServer_live _ _)

theorem delR3_reachable : Reachable id ⟨lateS0, delR3, [], [], []⟩ :=
  Reachable.deleteLocal _ 1 lateR1_reachable

/-- CONTROL (`restore_merge_keeps_pending_delete`, against the Swift as of
9121ba12): the snapshot carries X, and to `mergeByID` X is a row only the
cloud has, so the 9121ba12 rule brings it back; its entry is the cloud
row's, it reads clean, and neither push sends anything — the server keeps
X live although the user deleted it. The theorem, restated for that
step, is false. With the rule decided after 9121ba12 — a `Reachable`
step — X stays deleted with the entry it had, and `pushDelete`
tombstones it (`restore_pending_delete_sent`). -/
theorem restore_revives_pending_delete_control :
    ReachableRestoreWith id (step9121 id) ⟨lateS0, pd9121, [], [], []⟩
      ∧ delR3.loc 1 = none ∧ delR3.base 1 = some (0, 5)
      ∧ pd9121.loc 1 = some 0 ∧ pd9121.base 1 = some (0, 5) ∧ CleanAt id pd9121 1
      ∧ (pushDelete lateS0 pd9121 1).server.live 1 = some 0
      ∧ (pushRow id lateS0 pd9121 1).server.counter = lateS0.counter
      ∧ (¬ ∀ (r : Replica Nat) (keepCloud : Id → Bool) (snap : Snapshot Nat) (C0 : Seq)
          (i : Id) (b : Hash × Seq), r.loc i = none → r.base i = some b →
            (step9121 id r false keepCloud snap C0).loc i = none
              ∧ (step9121 id r false keepCloud snap C0).base i = some b)
      ∧ Reachable id ⟨lateS0, pdR, [], [], []⟩
      ∧ pdR.loc 1 = none ∧ pdR.base 1 = some (0, 5) ∧ ¬ CleanAt id pdR 1
      ∧ (pushDelete lateS0 pdR 1).server.live 1 = none
      ∧ (pushDelete lateS0 pdR 1).replica.base 1 = none := by
  refine ⟨ReachableRestoreWith.restore _ false keepLocalAll (snapAt1 0 5) 5 lateS0_read
      (fun _ => lateS0_all) delR3_reachable,
    by decide, by decide, by decide, by decide, by unfold CleanAt; decide, by decide, by decide,
    ?_, Reachable.restore _ false keepLocalAll (snapAt1 0 5) 5 lateS0_read
      (fun _ => lateS0_all) delR3_reachable,
    by decide, by decide, by unfold CleanAt; decide, by decide, by decide⟩
  intro H
  exact absurd (H delR3 keepLocalAll (snapAt1 0 5) 5 1 (0, 5) (by decide) (by decide)).1
    (by decide)

/-- The same merge, of a snapshot missing X although X was live when it
was read (an undecodable row, the walk's safety cap). -/
def pdMissing : Replica Nat := delR3.restore id false keepLocalAll snapNone 5
def pdMissing9121 : Replica Nat := delR3.restore9121 id false keepLocalAll snapNone 5

/-- INSTANCE (a merge no longer needs `hall`): the snapshot misses X, so
`hall` fails while `hread` holds. Under the 9121ba12 rule the merge
dropped X's entry — clean at X, X live on the server at a seq the cursor
has passed (`BaseCoversBelow` fails), the delete never sent. Under the
rule decided after 9121ba12 the merge is a `Reachable` step without
`hall`, which is asked of an overwrite only: X keeps its entry, and the
tombstone goes up. -/
theorem restore_incomplete_snapshot_merge_instance :
    ¬ (∃ s' ∈ lateS0 :: ([] : List (Server Nat)), 5 ≤ s'.counter ∧
          ∀ i row, s'.rows i = some row → row.deleted = false →
            snapNone i = some (row.content, row.seq))
      ∧ pdMissing9121.loc 1 = none ∧ pdMissing9121.base 1 = none
      ∧ CleanAt id pdMissing9121 1 ∧ ¬ BaseCoversBelow lateS0 pdMissing9121
      ∧ (pushDelete lateS0 pdMissing9121 1).server.live 1 = some 0
      ∧ Reachable id ⟨lateS0, pdMissing, [], [], []⟩
      ∧ pdMissing.loc 1 = none ∧ pdMissing.base 1 = some (0, 5)
      ∧ (pushDelete lateS0 pdMissing 1).server.live 1 = none := by
  have e : lateS0.rows 1 = some ⟨0, 5, false⟩ := by decide
  refine ⟨?_, by decide, by decide, by unfold CleanAt; decide,
    fun h => h 1 _ e (by decide) rfl (by decide), by decide,
    Reachable.restore _ false keepLocalAll snapNone 5 snapNone_read
      (fun h => absurd h (by decide)) delR3_reachable,
    by decide, by decide, by decide⟩
  rintro ⟨s', hs', -, hcov⟩
  simp only [List.mem_cons, List.not_mem_nil, or_false] at hs'
  subst hs'
  exact snapNone_none (hcov 1 _ e rfl)

/-- An overwrite of a snapshot missing X although X was live when it was
read. -/
def owMissing : Replica Nat := lateR1.restore id true keepLocalAll snapNone 5

/-- WITNESS (what `hall` is still for — an overwrite): the device holds X
as the server does; the snapshot misses X, so `hall` fails while `hread`
holds. The overwrite drops X locally and the replay drops its entry; the
rewind leaves the cursor at X's seq. The replica is clean everywhere, yet
X is live on the server below the cursor: `BaseCoversBelow` fails, the
replica is not in sync below its cursor, and no pull from that cursor
brings X back. -/
theorem restore_overwrite_incomplete_snapshot_witness :
    Reachable id ⟨lateS0, lateR1, [], [], []⟩
      ∧ ¬ (∃ s' ∈ lateS0 :: ([] : List (Server Nat)), 5 ≤ s'.counter ∧
          ∀ i row, s'.rows i = some row → row.deleted = false →
            snapNone i = some (row.content, row.seq))
      ∧ owMissing.loc 1 = none ∧ owMissing.base 1 = none ∧ owMissing.cursor = 5
      ∧ (∀ i, CleanAt id owMissing i) ∧ lateS0.live 1 = some 0
      ∧ ¬ BaseCoversBelow lateS0 owMissing ∧ ¬ SyncedBelow lateS0 owMissing
      ∧ IsHeadFeed lateS0 owMissing.cursor [] := by
  have e : lateS0.rows 1 = some ⟨0, 5, false⟩ := by decide
  refine ⟨lateR1_reachable, ?_, by decide, by decide, by decide, ?_, by decide,
    fun h => h 1 _ e (by decide) rfl (by decide), ?_, emptyPage_head _ _ ?_⟩
  · rintro ⟨s', hs', -, hcov⟩
    simp only [List.mem_cons, List.not_mem_nil, or_false] at hs'
    subst hs'
    exact snapNone_none (hcov 1 _ e rfl)
  · intro i
    unfold CleanAt
    simp [owMissing, Replica.restore, Replica.restoreFixedWith, Replica.restoreWith,
      Replica.restoreWithLoc, restoreLoc, replayBaseline, snapNone]
  · intro h
    have := h 1 (fun row hr => by rw [e] at hr; cases hr; decide)
    exact absurd this (by decide)
  · intro i row hr
    by_cases hi : i = 1
    · subst hi; rw [e] at hr; cases hr; decide
    · have e' : lateS0.rows i = none := oneServer_only _ _ i hi
      rw [e'] at hr; cases hr

/-! #### Without the rewind (the Swift as of 7a2e382e): an older snapshot

The snapshot is fetched when the restore sheet opens and applied after
the user's review; the puller keeps running meanwhile. Without the
rewind, by the time the replay writes a snapshot row's seq the device
may have pulled a newer version of that row. The run: the device holds X
as the server does, at the cursor it has when the fetch starts (`C0`);
the restore fetch reads X; a peer writes a newer version and the device
pulls it, its cursor passing that version's seq; the user merges
keeping local. -/

def staleR2 : Replica Nat := pull id lateR1 [⟨1, 6, 2, false⟩]
def staleR3 : Replica Nat := staleR2.restoreUnfixed id false keepLocalAll (snapAt1 0 5)
def staleR4 : Replica Nat := staleR3.edit 1 3
def staleR5 : Replica Nat := pullVerify id staleR4 [] [⟨1, 5, 3⟩]
def staleS2 : Server Nat := inelS1.step (.patch 1 6 4)
/-- The same restore with the rewind. -/
def staleFixed : Replica Nat := staleR2.restore id false keepLocalAll (snapAt1 0 5) 5

theorem staleR2_reachable : Reachable id ⟨inelS1, staleR2, [], [], [lateS0]⟩ :=
  Reachable.pull _ inelS1 6 [⟨1, 6, 2, false⟩] (List.mem_cons_self ..) (by decide)
    (inelS1_feed _ (by decide)) (Reachable.peer _ (.patch 1 5 2) lateR1_reachable)

theorem stale_read : ∀ i c S, snapAt1 0 5 i = some (c, S) →
    ∃ s' ∈ inelS1 :: [lateS0], s'.rows i = some ⟨c, S, false⟩ ∧ 5 ≤ s'.counter :=
  snapAt1_read (List.mem_cons_of_mem _ (List.mem_cons_self ..)) rfl (Nat.le_refl _)

theorem stale_all : ∃ s' ∈ inelS1 :: [lateS0], 5 ≤ s'.counter ∧
    ∀ i row, s'.rows i = some row → row.deleted = false →
      snapAt1 0 5 i = some (row.content, row.seq) :=
  snapAt1_all (List.mem_cons_of_mem _ (List.mem_cons_self ..)) (Nat.le_refl _)
    (oneServer_live _ _)

/-- CONTROL (the rewind, against the Swift as of 7a2e382e): the same
premises, the step without the rewind (`unfixedStep`). The replay writes
the snapshot's older `(hash, seq)` under a cursor past the newer version,
so `BaseTracksFeed` — part of `reachable_sound` — fails, and restated
over the set with that step it is false. The edit that follows is lost:
its PATCH filters on the older seq and answers `[]`; the eligible head
pull does not show X (its row is at the cursor), the baseline seq equals
the sent one, and the verify pass writes the edit's hash at the older
seq — a pair no state held, so `BaseHeld` fails too. The edit reads
clean and is never sent; the peer's next write is adopted over it with
nothing shelved. Keeping the cloud's copy instead leaves the device on
the older version, clean, with no pull from its cursor that brings the
newer one. With the rewind the restore is a `Reachable` step, and the
same edit meets the newer version as a conflict (shelved) and lands. -/
theorem restore_stale_snapshot_witness :
    ReachableRestoreWith id (unfixedStep id)
        ⟨inelS1, staleR3, [], [], [lateS0]⟩
      ∧ staleR3.loc 1 = some 2 ∧ staleR3.base 1 = some (0, 5) ∧ staleR3.cursor = 6
      ∧ ¬ BaseTracksFeed inelS1 staleR3
      ∧ (¬ ∀ sys : Sys Nat, ReachableRestoreWith id (unfixedStep id) sys →
          BaseTracksFeed sys.server sys.replica)
      ∧ (pushRow id inelS1 staleR4 1).pending = some ⟨1, 5, 3⟩
      ∧ (pushRow id inelS1 staleR4 1).server.counter = inelS1.counter
      ∧ IsHeadFeed inelS1 staleR4.cursor []
      ∧ staleR5.base 1 = some (3, 5) ∧ CleanAt id staleR5 1
      ∧ (pushRow id inelS1 staleR5 1).server.counter = inelS1.counter
      ∧ (pushRow id inelS1 staleR5 1).needsPull = false
      ∧ ¬ BaseHeld id [inelS1, lateS0] staleR5
      ∧ inelS1.live 1 = some 2
      ∧ staleS2.rows 1 = some ⟨4, 7, false⟩
      ∧ (pull id staleR5 [⟨1, 7, 4, false⟩]).loc 1 = some 4
      ∧ (pull id staleR5 [⟨1, 7, 4, false⟩]).shelf = []
      ∧ (staleR2.restoreUnfixed id false keepCloudAll (snapAt1 0 5)).loc 1 = some 0
      ∧ CleanAt id (staleR2.restoreUnfixed id false keepCloudAll (snapAt1 0 5)) 1
      ∧ (staleR2.restoreUnfixed id false keepCloudAll (snapAt1 0 5)).cursor = staleR4.cursor
      ∧ Reachable id ⟨inelS1, staleFixed, [], [], [lateS0]⟩
      ∧ staleFixed.cursor = 5
      ∧ (pushRow id inelS1 (staleFixed.edit 1 3) 1).pending = some ⟨1, 5, 3⟩
      ∧ IsHeadFeed inelS1 staleFixed.cursor [⟨1, 6, 2, false⟩]
      ∧ (pullVerify id (staleFixed.edit 1 3) [⟨1, 6, 2, false⟩] [⟨1, 5, 3⟩]).loc 1 = some 3
      ∧ (pullVerify id (staleFixed.edit 1 3) [⟨1, 6, 2, false⟩] [⟨1, 5, 3⟩]).shelf
          = [(1, 2)]
      ∧ (pushRow id inelS1 (pullVerify id (staleFixed.edit 1 3) [⟨1, 6, 2, false⟩]
          [⟨1, 5, 3⟩]) 1).server.rows 1 = some ⟨3, 7, false⟩ := by
  have e1 : inelS1.rows 1 = some ⟨2, 6, false⟩ := by decide
  have hr : ReachableRestoreWith id (unfixedStep id)
      ⟨inelS1, staleR3, [], [], [lateS0]⟩ :=
    ReachableRestoreWith.restore _ false keepLocalAll (snapAt1 0 5) 5 stale_read (fun _ => stale_all)
      staleR2_reachable
  have hnt : ¬ BaseTracksFeed inelS1 staleR3 := by
    intro h
    have := h 1 0 5 ⟨2, 6, false⟩ (by decide) e1 (by decide)
    cases this
  have hnh : ¬ BaseHeld id [inelS1, lateS0] staleR5 := by
    intro h
    obtain ⟨s', hs', row, hrow, hseq, -, hh⟩ := h 1 3 5 (by decide)
    simp only [List.mem_cons, List.not_mem_nil, or_false] at hs'
    rcases hs' with rfl | rfl
    · rw [e1] at hrow; cases hrow; cases hseq
    · have e : lateS0.rows 1 = some ⟨0, 5, false⟩ := by decide
      rw [e] at hrow; cases hrow; cases hh
  refine ⟨hr, by decide, by decide, by decide, hnt, fun H => hnt (H _ hr), by decide, by decide,
    emptyPage_head _ _ ?_, by decide, by unfold CleanAt; decide, by decide, by decide, hnh,
    by decide, by decide, by decide, by decide, by decide, by unfold CleanAt; decide, by decide,
    Reachable.restore _ false keepLocalAll (snapAt1 0 5) 5 stale_read (fun _ => stale_all)
      staleR2_reachable,
    by decide, by decide, onePage_head _ _ _ e1 (by decide) inelS1_only, by decide, by decide,
    by decide⟩
  intro i row hr'
  by_cases hi : i = 1
  · subst hi; rw [e1] at hr'; cases hr'; decide
  · rw [inelS1_only i hi] at hr'; cases hr'

/-! #### Without the rewind: an overwrite drops a row the device pulled

The independent QA's run: the device holds X as the server does, at the
cursor it has when the fetch starts (`C0`); the restore fetch reads X; a
peer creates Y and the device pulls it, its cursor passing Y's seq; the
user overwrites from the cloud. The snapshot does not carry Y, so the
overwrite drops it locally and the replay drops its entry. -/

def qaS1 : Server Nat := lateS0.step (.insertIgnore 2 7)
def qaR2 : Replica Nat := pull id lateR1 [⟨2, 6, 7, false⟩]
def qaUnfixed : Replica Nat := qaR2.restoreUnfixed id true keepLocalAll (snapAt1 0 5)
def qaFixed : Replica Nat := qaR2.restore id true keepLocalAll (snapAt1 0 5) 5

theorem qaS1_1 : qaS1.rows 1 = some ⟨0, 5, false⟩ := by decide
theorem qaS1_2 : qaS1.rows 2 = some ⟨7, 6, false⟩ := by decide
theorem qaS1_other (i : Id) (h1 : i ≠ 1) (h2 : i ≠ 2) : qaS1.rows i = none := by
  simp [qaS1, Server.step, Server.insertIgnore, lateS0, oneServer, Server.setRow, h1, h2]

theorem qaR2_reachable : Reachable id ⟨qaS1, qaR2, [], [], [lateS0]⟩ := by
  have hfeed : IsPageFeed qaS1 lateR1.cursor 6 [⟨2, 6, 7, false⟩] := by
    refine ⟨?_, ?_, List.pairwise_singleton _ _⟩
    · intro fr hfr
      simp only [List.mem_singleton] at hfr
      subst hfr
      exact ⟨qaS1_2, by decide, Nat.le_refl _⟩
    · intro i row hrow hlt _
      by_cases h2 : i = 2
      · exact ⟨_, List.mem_singleton_self _, h2.symm⟩
      · exfalso
        by_cases h1 : i = 1
        · subst h1; rw [qaS1_1] at hrow; cases hrow; exact absurd hlt (by decide)
        · rw [qaS1_other i h1 h2] at hrow; cases hrow
  exact Reachable.pull _ qaS1 6 _ (List.mem_cons_self ..) (by decide) hfeed
    (Reachable.peer _ (.insertIgnore 2 7) lateR1_reachable)

theorem qa_read : ∀ i c S, snapAt1 0 5 i = some (c, S) →
    ∃ s' ∈ qaS1 :: [lateS0], s'.rows i = some ⟨c, S, false⟩ ∧ 5 ≤ s'.counter :=
  snapAt1_read (List.mem_cons_of_mem _ (List.mem_cons_self ..)) rfl (Nat.le_refl _)

theorem qa_all : ∃ s' ∈ qaS1 :: [lateS0], 5 ≤ s'.counter ∧
    ∀ i row, s'.rows i = some row → row.deleted = false →
      snapAt1 0 5 i = some (row.content, row.seq) :=
  snapAt1_all (List.mem_cons_of_mem _ (List.mem_cons_self ..)) (Nat.le_refl _)
    (oneServer_live _ _)

/-- An overwrite of `snapAt1 0 5`, with or without the rewind, is clean
everywhere. -/
theorem qa_clean (r : Replica Nat) (hr : r = qaUnfixed ∨ r = qaFixed) : ∀ i, CleanAt id r i := by
  intro i
  rcases hr with rfl | rfl
  · by_cases hi : i = 1
    · subst hi; unfold CleanAt; decide
    · unfold CleanAt
      simp [qaUnfixed, Replica.restoreUnfixed, Replica.restoreWithLoc, restoreLoc7a2e,
        replayBaseline7a2e, snapAt1, hi]
  · by_cases hi : i = 1
    · subst hi; unfold CleanAt; decide
    · unfold CleanAt
      simp [qaFixed, Replica.restore, Replica.restoreFixedWith, Replica.restoreWith,
        Replica.restoreWithLoc, restoreLoc, replayBaseline, snapAt1, hi]

/-- CONTROL (`synced_below_of_clean` and `BaseCoversBelow`, against the
Swift as of 7a2e382e): without the rewind the overwritten replica is
clean everywhere, yet Y — live on the server at a seq the cursor has
passed — is neither a local row nor an entry, and no pull from that
cursor brings it back: the device has lost a row every other device
shows, and nothing flags it. Both statements, restated over the set with
the step without the rewind, are false. With the rewind the cursor goes
back to `C0`, which Y's seq is above: the restore is a `Reachable` step,
the replica is in sync below its cursor (`synced_below_of_clean`), and
the head pull lands on the server at every id
(`clean_replica_converges_reachable`), Y included. -/
theorem overwrite_drops_pulled_row_control :
    ReachableRestoreWith id (unfixedStep id) ⟨qaS1, qaUnfixed, [], [], [lateS0]⟩
      ∧ qaR2.loc 2 = some 7 ∧ qaR2.base 2 = some (7, 6) ∧ qaR2.cursor = 6
      ∧ qaUnfixed.loc 2 = none ∧ qaUnfixed.base 2 = none ∧ qaUnfixed.cursor = 6
      ∧ (∀ i, CleanAt id qaUnfixed i)
      ∧ qaS1.live 2 = some 7
      ∧ ¬ SyncedBelow qaS1 qaUnfixed ∧ ¬ BaseCoversBelow qaS1 qaUnfixed
      ∧ IsHeadFeed qaS1 qaUnfixed.cursor []
      ∧ (¬ ∀ sys : Sys Nat, ReachableRestoreWith id (unfixedStep id) sys →
          (∀ i, CleanAt id sys.replica i) → SyncedBelow sys.server sys.replica)
      ∧ (¬ ∀ sys : Sys Nat, ReachableRestoreWith id (unfixedStep id) sys →
          BaseCoversBelow sys.server sys.replica)
      ∧ Reachable id ⟨qaS1, qaFixed, [], [], [lateS0]⟩
      ∧ qaFixed.cursor = 5 ∧ (∀ i, CleanAt id qaFixed i)
      ∧ SyncedBelow qaS1 qaFixed
      ∧ IsHeadFeed qaS1 qaFixed.cursor [⟨2, 6, 7, false⟩]
      ∧ (∀ i, (pull id qaFixed [⟨2, 6, 7, false⟩]).loc i = qaS1.live i)
      ∧ (pull id qaFixed [⟨2, 6, 7, false⟩]).loc 2 = some 7 := by
  have hinj : HashInjective (id : Nat → Hash) := fun _ _ h => h
  have hr : ReachableRestoreWith id (unfixedStep id)
      ⟨qaS1, qaUnfixed, [], [], [lateS0]⟩ :=
    ReachableRestoreWith.restore _ true keepLocalAll (snapAt1 0 5) 5 qa_read (fun _ => qa_all)
      qaR2_reachable
  have hcu := qa_clean qaUnfixed (Or.inl rfl)
  have hcf := qa_clean qaFixed (Or.inr rfl)
  have hns : ¬ SyncedBelow qaS1 qaUnfixed := by
    intro h
    have := h 2 (fun row hrow => by rw [qaS1_2] at hrow; cases hrow; decide)
    exact absurd this (by decide)
  have hnc : ¬ BaseCoversBelow qaS1 qaUnfixed :=
    fun h => h 2 _ qaS1_2 (by decide) rfl (by decide)
  have hrf : Reachable id ⟨qaS1, qaFixed, [], [], [lateS0]⟩ :=
    Reachable.restore _ true keepLocalAll (snapAt1 0 5) 5 qa_read (fun _ => qa_all) qaR2_reachable
  have hhead : IsHeadFeed qaS1 qaFixed.cursor [⟨2, 6, 7, false⟩] := by
    refine ⟨?_, ?_, List.pairwise_singleton _ _⟩
    · intro fr hfr
      simp only [List.mem_singleton] at hfr
      subst hfr
      exact ⟨qaS1_2, by decide⟩
    · intro i row hrow hlt
      by_cases h2 : i = 2
      · exact ⟨_, List.mem_singleton_self _, h2.symm⟩
      · exfalso
        by_cases h1 : i = 1
        · subst h1; rw [qaS1_1] at hrow; cases hrow; exact absurd hlt (by decide)
        · rw [qaS1_other i h1 h2] at hrow; cases hrow
  obtain ⟨hl, -⟩ := clean_replica_converges_reachable id hinj hrf hcf _ hhead
  refine ⟨hr, by decide, by decide, by decide, by decide, by decide, by decide, hcu, by decide,
    hns, hnc, emptyPage_head _ _ ?_, fun H => hns (H _ hr hcu), fun H => hnc (H _ hr), hrf,
    by decide, hcf, synced_below_of_clean id hinj hrf hcf, hhead, hl, by rw [hl 2]; decide⟩
  intro i row hrow
  by_cases h1 : i = 1
  · subst h1; rw [qaS1_1] at hrow; cases hrow; decide
  · by_cases h2 : i = 2
    · subst h2; rw [qaS1_2] at hrow; cases hrow; decide
    · rw [qaS1_other i h1 h2] at hrow; cases hrow

/-- The other half of the vacuity statement, on reachable states: a
PATCH `[]` there never has the server row at the sent seq, so the
pending entry is stale — the `sentHash` rule's own case (the
short-circuit) is outside `Reachable`. -/
theorem reachable_patch_empty_is_stale [DecidableEq C] (hash : C → Hash) {sys : Sys C}
    (h : Reachable hash sys) (i : Id) (p : Pending)
    (hp : (pushRow hash sys.server sys.replica i).pending = some p) :
    PendingStale (pushRow hash sys.server sys.replica i).server p := by
  obtain ⟨hinv, hbh, -⟩ := reachable_sound hash h
  exact pendingStale_pushRow hash hinv hbh i p hp

end ReachableRuns


/-! ## T7 — event_types: the newest-namesake winner and the applier rule -/

namespace EventTypes

/-- A lowercase UUID string. Lexicographic order on fixed-width lowercase
hex (hyphens at fixed positions) is the numeric order of the value, so
`Nat` with `≤` is the model; that faithfulness is asserted, not proved —
the design's "lowercase" is what makes it true (an uppercase digit sorts
below a lowercase one). -/
abbrev Uuid := Nat

/-- A live namesake as ONE device sees it (gh#257): its UUID and its
server `updated_at` when the device has it — a row the pulled page
carries — or `none` for a local row the page does not carry (the local
catalog keeps no timestamp). `Nat` stands in for the timestamp. -/
structure Row where
  id : Nat
  t : Option Nat
deriving DecidableEq, Repr

/-- The smaller UUID of the two (the tie-break, and the whole rule when
either side is undated). -/
def byId (a b : Row) : Row := if a.id ≤ b.id then a else b

/-- The §6 rule for two rows sharing a normalized title (gh#257): both
dated with different timestamps → the newer; otherwise (equal timestamps,
or either undated) the smaller UUID. -/
def winner (a b : Row) : Row :=
  match a.t, b.t with
  | some x, some y => if y < x then a else if x < y then b else byId a b
  | _, _ => byId a b

/-- The loser is the other one: tombstoned by BOTH holders, so it dies
even if its creator never comes back online. -/
def loser (a b : Row) : Row := if winner a b = a then b else a

theorem winner_left_none (i : Nat) (b : Row) : winner ⟨i, none⟩ b = byId ⟨i, none⟩ b := rfl

theorem winner_right_none (a : Row) (j : Nat) : winner a ⟨j, none⟩ = byId a ⟨j, none⟩ := by
  obtain ⟨i, s⟩ := a
  cases s <;> rfl

theorem winner_dated (i j x y : Nat) :
    winner ⟨i, some x⟩ ⟨j, some y⟩
      = if y < x ∨ (x = y ∧ i ≤ j) then ⟨i, some x⟩ else ⟨j, some y⟩ := by
  simp only [winner, byId]
  by_cases h1 : y < x
  · rw [if_pos h1, if_pos (Or.inl h1)]
  · rw [if_neg h1]
    by_cases h2 : x < y
    · rw [if_pos h2, if_neg (by omega)]
    · rw [if_neg h2]
      by_cases h3 : i ≤ j
      · rw [if_pos h3, if_pos (Or.inr ⟨by omega, h3⟩)]
      · rw [if_neg h3, if_neg (by omega)]

theorem byId_comm (a b : Row) (h : a.id ≠ b.id) : byId a b = byId b a := by
  unfold byId
  by_cases h1 : a.id ≤ b.id <;> by_cases h2 : b.id ≤ a.id <;> simp only [h1, h2, if_true, if_false] <;> omega

/-- THEOREM T7a (symmetric): the holder of `a` seeing `b` and the holder
of `b` seeing `a` compute the same winner — when both see the same
timestamps. (`holders_views_agree` is the case where each sees only the
other's.) -/
theorem winner_comm (a b : Row) (h : a.id ≠ b.id) : winner a b = winner b a := by
  obtain ⟨i, s⟩ := a
  obtain ⟨j, u⟩ := b
  cases s with
  | none => rw [winner_left_none, winner_right_none]; exact byId_comm _ _ h
  | some x =>
    cases u with
    | none => rw [winner_left_none, winner_right_none]; exact byId_comm _ _ h
    | some y =>
      simp only [ne_eq] at h
      rw [winner_dated, winner_dated]
      by_cases h1 : y < x ∨ (x = y ∧ i ≤ j) <;> by_cases h2 : x < y ∨ (y = x ∧ j ≤ i) <;>
        simp only [h1, h2, if_true, if_false, Row.mk.injEq, Option.some.injEq] <;> omega

/-- THEOREM T7b (idempotent): seeing your own row changes nothing. -/
theorem winner_idem (a : Row) : winner a a = a := by
  obtain ⟨i, s⟩ := a
  cases s <;> simp [winner, byId]

/-- THEOREM T7c (the winner is one of the two): no third UUID is minted. -/
theorem winner_mem (a b : Row) : winner a b = a ∨ winner a b = b := by
  unfold winner byId
  split <;> (repeat' split) <;> simp

/-- THEOREM T7d (three holders agree) — when every row is dated (a first
pull: the whole account is in the page), the outcome is independent of the
order the duplicates are discovered in. -/
theorem winner_assoc_dated (i j k x y z : Nat) :
    winner (winner ⟨i, some x⟩ ⟨j, some y⟩) ⟨k, some z⟩
      = winner ⟨i, some x⟩ (winner ⟨j, some y⟩ ⟨k, some z⟩) := by
  rw [winner_dated i j x y, winner_dated j k y z]
  by_cases h1 : y < x ∨ (x = y ∧ i ≤ j) <;> by_cases h2 : z < y ∨ (y = z ∧ j ≤ k) <;>
    simp only [h1, h2, if_true, if_false, winner_dated] <;>
    by_cases h3 : z < x ∨ (x = z ∧ i ≤ k) <;>
    simp only [h3, if_true, if_false, Row.mk.injEq, Option.some.injEq] <;> omega

/-- THEOREM T7d' — when every row is undated it is the smallest UUID. -/
theorem winner_assoc_undated (i j k : Nat) :
    winner (winner ⟨i, none⟩ ⟨j, none⟩) ⟨k, none⟩
      = winner ⟨i, none⟩ (winner ⟨j, none⟩ ⟨k, none⟩) := by
  simp only [winner_left_none, winner_right_none, byId]
  by_cases h1 : i ≤ j <;> by_cases h2 : j ≤ k <;> by_cases h3 : i ≤ k <;>
    simp only [h1, h2, h3, if_true, if_false] <;> omega

/-- MIXED-VIEW WITNESS: with dated and undated rows mixed, the PAIR rule
is not transitive (x beats y by UUID, y beats z by UUID, z beats x by
time). So the client never folds pairs over a mixed title: it decides the
whole title at once and, if any live candidate is undated, by the smallest
UUID alone (`SyncEventTypeWinners.winner`). -/
theorem mixed_pair_rule_cycles_witness :
    winner ⟨1, some 1⟩ ⟨2, none⟩ = ⟨1, some 1⟩
      ∧ winner ⟨2, none⟩ ⟨3, some 2⟩ = ⟨2, none⟩
      ∧ winner ⟨3, some 2⟩ ⟨1, some 1⟩ = ⟨3, some 2⟩ := by
  refine ⟨?_, ?_, ?_⟩ <;> decide

/-- THEOREM T7h (the two holders' real views agree): A holds its own `a`
and pulls `b`; B holds its own `b` and pulls `a`. Each device has the
timestamp of the PULLED row only — its own is a local row the page does
not carry. Both pick the same UUID. Undated-counts-as-oldest (or as "now")
would make each device pick the other's (or its own) row and the type
would die on both. -/
theorem holders_views_agree (a b : Row) :
    (winner ⟨a.id, none⟩ b).id = (winner a ⟨b.id, none⟩).id := by
  rw [winner_left_none, winner_right_none]
  unfold byId
  by_cases h : a.id ≤ b.id <;> simp [h]

theorem loser_ne_winner (a b : Row) (h : a.id ≠ b.id) :
    (loser a b).id ≠ (winner a b).id := by
  unfold loser
  rcases winner_mem a b with hw | hw
  · rw [hw]; simp only [if_true]; exact fun e => h e.symm
  · rw [hw]
    by_cases hab : b = a
    · subst hab; exact absurd rfl h
    · simp only [hab, if_false]; exact h

/-! ### The applier half, per normalized title

`holds` is the LIVE local row with the title (`none` = none); the incoming
row is `(inc, live)`. The outcome: what the holder holds afterwards, which
UUIDs it tombstones (by either of the text's two paths: the collection diff
when the loser was in the baseline, the applier's own PATCH when the
incoming row is the loser — one field here), and which UUID is ALLOWED a
baseline entry for the title after the step. One thing the design drops is
a real I7 exception the text should state: attributes (colorHex …) — the
design takes the winner's and drops the loser's without shelving. One thing
only THIS abstraction drops: a tombstone of the HELD type — `resolve …
false` with the held id — removes the local row with no dirty check and no
shelf entry here, because `resolve` is not composed with the §6 table. In
the design event_types is one of the six id tables, so that tombstone goes
through the table's tombstone row (a dirty local version is shelved), and
the per-title rule only says a tombstone removes its own UUID. -/

structure Resolution where
  holds : Option Row
  tombstones : List Uuid
  /-- The only UUID allowed a baseline entry for this title after the
  step (`none` on a tombstone). It is NOT a write: the §6 table writes
  the baseline when the incoming row IS that UUID (winner's row applied
  as any row), and writes nothing when the incoming row is the loser —
  "败方 UUID 永不进基线" is `loser_never_in_base`. -/
  base : Option Uuid
deriving DecidableEq, Repr

/-- The §6 rule (round eight; newest-wins since gh#257): a tombstone only
removes its own UUID — a dead namesake takes no part in winner selection,
however new its timestamp. -/
def resolve (holds : Option Row) (inc : Row) (live : Bool) : Resolution :=
  if live then
    match holds with
    | none => ⟨some inc, [], some inc.id⟩
    | some l =>
      if l.id = inc.id then ⟨some inc, [], some inc.id⟩
      else ⟨some (winner l inc), [(loser l inc).id], some (winner l inc).id⟩
  else
    ⟨if holds.map Row.id = some inc.id then none else holds, [], none⟩

/-- The naive reading: every namesake row seen, dead or alive, competes
for the smallest UUID; a holder of the loser replaces its row with the
winner's — even when the winner is a tombstone. -/
def resolveNaive (holds : Option Row) (inc : Row) (live : Bool) : Resolution :=
  match holds with
  | none => if live then ⟨some inc, [], some inc.id⟩ else ⟨none, [], none⟩
  | some l =>
    if l.id = inc.id then ⟨if live then some l else none, [], if live then some inc.id else none⟩
    else if inc.id < l.id then ⟨if live then some inc else none, [l.id], if live then some inc.id else none⟩
    else ⟨some l, [inc.id], some l.id⟩

/-- THEOREM T7e (winner ranges over live rows only): an incoming
tombstone never changes which row is held unless it IS the held one,
tombstones nothing, and writes no baseline. -/
theorem winner_ranges_over_live_only (holds : Option Row) (inc : Row) :
    resolve holds inc false = ⟨if holds.map Row.id = some inc.id then none else holds, [], none⟩ := by
  simp [resolve]

/-- THEOREM T7f (the loser never enters the baseline): two live namesakes
with different UUIDs — the holder keeps the winner, tombstones the loser,
and its baseline entry is the winner, never the loser. -/
theorem loser_never_in_base (l inc : Row) (h : l.id ≠ inc.id) :
    (resolve (some l) inc true).base = some (winner l inc).id
      ∧ (resolve (some l) inc true).base ≠ some (loser l inc).id
      ∧ (resolve (some l) inc true).tombstones = [(loser l inc).id] := by
  refine ⟨by simp [resolve, h], ?_, by simp [resolve, h]⟩
  simp only [resolve, h, ↓reduceIte, ne_eq, Option.some.injEq]
  exact (loser_ne_winner l inc h).symm

theorem loser_comm (a b : Row) (h : a.id ≠ b.id) : loser a b = loser b a := by
  have hw := winner_comm a b h
  unfold loser
  rcases winner_mem a b with h1 | h1
  · have h2 : winner b a = a := hw ▸ h1
    have : a ≠ b := fun e => h (e ▸ rfl)
    simp [h1, h2, this]
  · have h2 : winner b a = b := hw ▸ h1
    have : b ≠ a := fun e => h (e ▸ rfl)
    by_cases hab : b = a
    · exact absurd hab this
    · simp [h1, h2, hab]

/-- THEOREM T7g (both holders converge, and the result is a fixed point):
A holding `a` applies B's `b`, B holding `b` applies A's `a` — with the
same view of the timestamps both hold the winner, both tombstone the same
loser, both write the same baseline. Re-applying the winner's row to the
converged state tombstones nothing more; applying the loser's tombstone to
it changes nothing. "两台都做,幂等" is these facts. (T7h covers the real
views, where each device lacks its own row's timestamp.) -/
theorem both_holders_converge (a b : Row) (h : a.id ≠ b.id) :
    resolve (some a) b true = resolve (some b) a true
      ∧ (resolve (some a) b true).holds = some (winner a b)
      ∧ resolve (some (winner a b)) (winner a b) true
          = ⟨some (winner a b), [], some (winner a b).id⟩
      ∧ resolve (some (winner a b)) (loser a b) false
          = ⟨some (winner a b), [], none⟩ := by
  have hw : winner a b = winner b a := winner_comm a b h
  have hl : loser a b = loser b a := loser_comm a b h
  have hne : (winner a b).id ≠ (loser a b).id := (loser_ne_winner a b h).symm
  refine ⟨?_, by simp [resolve, h], by simp [resolve], ?_⟩
  · have h' : b.id ≠ a.id := Ne.symm h
    simp [resolve, h, h', hw, hl]
  · simp [resolve, hne]

/-- GH#257 WITNESS (production, 2026-10-21): the user's customised row
(UUID 9, written on day 22) and the app's stale default (UUID 3, day 18)
are both in a first pull's page. The newest wins: the device holding the
customised row keeps it and tombstones the default; the device holding
the default swaps it for the customised row. Smallest-UUID-only kept 3
and tombstoned the user's colour. With the holder's row UNDATED (an
incremental pull that does not carry it) the title falls back to the
smallest UUID — the rule's stated limit. -/
theorem gh257_newest_namesake_witness :
    resolve (some ⟨9, some 22⟩) ⟨3, some 18⟩ true = ⟨some ⟨9, some 22⟩, [3], some 9⟩
      ∧ resolve (some ⟨3, some 18⟩) ⟨9, some 22⟩ true = ⟨some ⟨9, some 22⟩, [3], some 9⟩
      ∧ resolve (some ⟨9, none⟩) ⟨3, some 18⟩ true = ⟨some ⟨3, some 18⟩, [9], some 3⟩ := by
  refine ⟨?_, ?_, ?_⟩ <;> decide

/-- SCENARIO D WITNESS (a dead namesake must not compete): A created the
title as UUID 3, B created it as UUID 7, A deleted its own. B pulls A's
TOMBSTONE of 3 — newer than anything B holds. Under `resolve` B keeps 7.
Under the naive reading 3 < 7 wins, B replaces its live row with a dead
one and tombstones 7 — its freshly created type vanishes on both devices
with nothing shelved. -/
theorem naive_dead_namesake_erases_live_type_witness :
    resolve (some ⟨7, some 1⟩) ⟨3, some 2⟩ false = ⟨some ⟨7, some 1⟩, [], none⟩
      ∧ resolveNaive (some ⟨7, some 1⟩) ⟨3, some 2⟩ false = ⟨none, [7], none⟩ := by
  constructor <;> decide

/-- ORDER WITNESS (the same three writes, two pull orders, two outcomes —
both converged): A created UUID 3, B created UUID 7 (same timestamp, so
the UUID decides), A deletes 3. (a) B pulled 3 while it was LIVE: B holds
the winner 3 and tombstones its own 7; then 3's tombstone empties B, and
A, holding nothing, ignores 7's tombstone — the type is gone on both, A's
delete wins. (b) B pulls 3 only after it is DEAD: B keeps 7, and A,
holding nothing after its delete, adopts B's 7 — the namesake survives on
both, so A's delete of the title is in effect undone. `resolve` is per
title and is not composed with the table, so no theorem covers the
sequence; which outcome happens depends on when B pulled. -/
theorem namesake_delete_order_witness :
    resolve (some ⟨7, some 5⟩) ⟨3, some 5⟩ true = ⟨some ⟨3, some 5⟩, [7], some 3⟩
      ∧ resolve (some ⟨3, some 5⟩) ⟨3, some 5⟩ false = ⟨none, [], none⟩
      ∧ resolve none ⟨7, some 5⟩ false = ⟨none, [], none⟩
      ∧ resolve (some ⟨7, some 5⟩) ⟨3, some 5⟩ false = ⟨some ⟨7, some 5⟩, [], none⟩
      ∧ resolve none ⟨7, some 5⟩ true = ⟨some ⟨7, some 5⟩, [], some 7⟩ := by
  refine ⟨?_, ?_, ?_, ?_, ?_⟩ <;> decide

end EventTypes

/-! ## T8 — user_settings: per-key three-way merge -/

namespace Settings

/-- Outcome for one key: the merged value and, per side, whether that
side's value lost and went to the shelf. Flags rather than values so that
"the remote DELETION was overridden" is expressible (`shelfRemote = true`
with the remote value being the absent key). -/
structure KeyMerge (V : Type) where
  value : Option V
  shelfRemote : Bool
  shelfLocal : Bool
deriving DecidableEq, Repr

variable {V : Type}

/-- A side changed iff its value's hash differs from the per-key baseline
hash; an absent key is a value (`none`) on both sides. -/
def changed (hash : V → Hash) (v : Option V) (b : Option Hash) : Bool :=
  decide (v.map hash ≠ b)

/-- The general per-key rule: one side changed → that side; both changed
to the same bytes → no conflict (the round-eight text: "两侧都改成同样
字节的不是冲突", the mirror of the row-level `h_in == h_loc → 无事`);
both changed differently → local wins, remote shelved. -/
def mergeKey (hash : V → Hash) (inV locV : Option V) (baseV : Option Hash) :
    KeyMerge V :=
  if changed hash inV baseV = false then ⟨locV, false, false⟩
  else if changed hash locV baseV = false then ⟨inV, false, false⟩
  else if inV.map hash = locV.map hash then ⟨locV, false, false⟩
  else ⟨locV, true, false⟩

/-- THEOREM T8a (one side only): a key changed on exactly one side takes
that side, and shelves nothing. -/
theorem one_side_takes_that_side (hash : V → Hash) (inV locV : Option V)
    (baseV : Option Hash) :
    (changed hash inV baseV = true → changed hash locV baseV = false →
      mergeKey hash inV locV baseV = ⟨inV, false, false⟩)
    ∧ (changed hash locV baseV = true → changed hash inV baseV = false →
      mergeKey hash inV locV baseV = ⟨locV, false, false⟩) := by
  constructor
  · intro h1 h2
    simp [mergeKey, h1, h2]
  · intro _ h2
    simp [mergeKey, h2]

/-- THEOREM T8b (both changed, differently): local is kept, the remote
value is on the shelf — no byte lost (I7, per key). -/
theorem both_changed_local_wins_remote_shelved (hash : V → Hash)
    (inV locV : Option V) (baseV : Option Hash)
    (h1 : changed hash inV baseV = true) (h2 : changed hash locV baseV = true)
    (hne : inV.map hash ≠ locV.map hash) :
    mergeKey hash inV locV baseV = ⟨locV, true, false⟩ := by
  simp [mergeKey, h1, h2, hne]

/-- A remote DELETION that lost to a local change is recorded as a shelved
remote side (`{key, remote: absent}`) — distinguishable from "one side
changed, nothing shelved". -/
theorem remote_deletion_overridden_is_shelved (hash : V → Hash) (b : V) (bh : Hash)
    (hmoved : hash b ≠ bh) :
    mergeKey hash none (some b) (some bh) = ⟨some b, true, false⟩ := by
  simp [mergeKey, changed, hmoved]

/-- Both unchanged: the merge is the local value, whose hash is the remote
value's hash (and, under injectivity, the values coincide). -/
theorem unchanged_is_identity (hash : V → Hash) (inV locV : Option V)
    (baseV : Option Hash)
    (h1 : changed hash inV baseV = false) (h2 : changed hash locV baseV = false) :
    mergeKey hash inV locV baseV = ⟨locV, false, false⟩
      ∧ locV.map hash = inV.map hash := by
  refine ⟨by simp [mergeKey, h1], ?_⟩
  have h1' := Decidable.not_not.mp (of_decide_eq_false h1)
  have h2' := Decidable.not_not.mp (of_decide_eq_false h2)
  rw [h1', h2']

/-- THEOREM T8c (deletion propagates — the general rule already does it):
a key deleted on one side and untouched on the other comes out deleted.
This is also the §9.3 second window: a build that does not know a key
uploads the blob without it, and the peer reads the absence as a
deletion. -/
theorem deletion_propagates (hash : V → Hash) (locV : Option V) (bh : Hash)
    (hunchanged : changed hash locV (some bh) = false) :
    (mergeKey hash none locV (some bh)).value = none := by
  unfold mergeKey
  rw [hunchanged]
  simp [changed]

/-- A key deleted locally against a remote change: the local deletion is a
change, so it wins (both changed, different), and the remote value is
shelved. The text's settings paragraph never says a deletion counts as
a change in the both-changed rule; the model says it does. -/
theorem local_deletion_wins_remote_shelved (hash : V → Hash) (a : V) (bh : Hash)
    (hmoved : hash a ≠ bh) :
    mergeKey hash (some a) none (some bh) = ⟨none, true, false⟩ := by
  simp [mergeKey, changed, hmoved]

/-- `skillAnalyzedEventIds`: an id set, stored as a list. Membership is
what the rule is about; the ORDER matters only because the per-key hash
serialises the list as stored. -/
abbrev IdSet := List Nat

def union (a b : IdSet) : IdSet := a ++ b.filter fun x => !a.contains x

/-- Insert into a strictly increasing list, dropping a duplicate. -/
def insertId (x : Nat) : IdSet → IdSet
  | [] => [x]
  | y :: ys => if x < y then x :: y :: ys else if x = y then y :: ys else y :: insertId x ys

/-- The canonical form the merged set is written back in (and hashed
in): strictly increasing — sorted, no duplicates. Lowercase UUID strings
in lexicographic order are the `Nat` order here, as for event_types. -/
def canonical : IdSet → IdSet
  | [] => []
  | x :: xs => insertId x (canonical xs)

/-- The special-key rule: both sides non-nil → the union, written back
in canonical order (lost ids mean re-analysis and LLM cost; the order is
what makes two devices that merged the same set write the same bytes);
one side nil against a non-nil baseline → explicit deletion propagates,
and a non-nil side that had moved from the baseline is shelved rather
than lost (model-added: the text says only "传播"); both nil → nothing
to shelve; otherwise (one side nil, no baseline) the general rule, which
keeps the non-nil side. -/
def mergeAnalyzedIds (hash : IdSet → Hash) (inV locV : Option IdSet)
    (baseV : Option Hash) : KeyMerge IdSet :=
  match inV, locV with
  | some a, some b => ⟨some (canonical (union b a)), false, false⟩
  | _, _ =>
    if baseV.isSome then
      ⟨none, inV.isSome && changed hash inV baseV, locV.isSome && changed hash locV baseV⟩
    else mergeKey hash inV locV baseV

/-- The superseded union: the literal concatenation order. Kept only for
`union_literal_pingpong_witness`. -/
def mergeAnalyzedIdsLiteral (hash : IdSet → Hash) (inV locV : Option IdSet)
    (baseV : Option Hash) : KeyMerge IdSet :=
  match inV, locV with
  | some a, some b => ⟨some (union b a), false, false⟩
  | _, _ => mergeAnalyzedIds hash inV locV baseV

theorem mem_union (a b : IdSet) (x : Nat) : x ∈ union a b ↔ x ∈ a ∨ x ∈ b := by
  by_cases ha : x ∈ a <;> by_cases hb : x ∈ b <;> simp [union, List.mem_filter, ha, hb]

theorem mem_insertId (x z : Nat) (l : IdSet) : z ∈ insertId x l ↔ z = x ∨ z ∈ l := by
  induction l with
  | nil => simp [insertId]
  | cons y ys ih =>
    unfold insertId
    split
    · simp
    · split
      · rename_i hxy
        subst hxy
        simp
      · simp only [List.mem_cons, ih]
        constructor
        · rintro (h | h | h)
          · exact Or.inr (Or.inl h)
          · exact Or.inl h
          · exact Or.inr (Or.inr h)
        · rintro (h | h | h)
          · exact Or.inr (Or.inl h)
          · exact Or.inl h
          · exact Or.inr (Or.inr h)

theorem mem_canonical (z : Nat) (l : IdSet) : z ∈ canonical l ↔ z ∈ l := by
  induction l with
  | nil => simp [canonical]
  | cons x xs ih =>
    simp only [canonical, mem_insertId, ih, List.mem_cons]

theorem insertId_sorted (x : Nat) (l : IdSet) (h : l.Pairwise (· < ·)) :
    (insertId x l).Pairwise (· < ·) := by
  induction l with
  | nil => simp [insertId]
  | cons y ys ih =>
    rw [List.pairwise_cons] at h
    obtain ⟨hy, hys⟩ := h
    unfold insertId
    split
    · rename_i hxy
      refine List.Pairwise.cons ?_ (List.Pairwise.cons hy hys)
      intro z hz
      simp only [List.mem_cons] at hz
      rcases hz with rfl | hz
      · exact hxy
      · exact Nat.lt_trans hxy (hy z hz)
    · split
      · exact List.Pairwise.cons hy hys
      · rename_i hlt hne
        refine List.Pairwise.cons ?_ (ih hys)
        intro z hz
        rcases (mem_insertId x z ys).mp hz with rfl | hz
        · omega
        · exact hy z hz

theorem canonical_sorted (l : IdSet) : (canonical l).Pairwise (· < ·) := by
  induction l with
  | nil => exact List.Pairwise.nil
  | cons x xs ih => exact insertId_sorted x _ ih

/-- Two strictly increasing lists with the same members are the same
list. -/
theorem eq_of_sorted_of_mem_iff (l₁ l₂ : IdSet) (h₁ : l₁.Pairwise (· < ·))
    (h₂ : l₂.Pairwise (· < ·)) (hm : ∀ z, z ∈ l₁ ↔ z ∈ l₂) : l₁ = l₂ := by
  induction l₁ generalizing l₂ with
  | nil =>
    cases l₂ with
    | nil => rfl
    | cons y ys => exact absurd ((hm y).mpr (by simp)) (by simp)
  | cons x xs ih =>
    cases l₂ with
    | nil => exact absurd ((hm x).mp (by simp)) (by simp)
    | cons y ys =>
      rw [List.pairwise_cons] at h₁ h₂
      have hx := (hm x).mp (by simp)
      have hy := (hm y).mpr (by simp)
      simp only [List.mem_cons] at hx hy
      have hxy : x = y := by
        rcases hx with hx | hx
        · exact hx
        · rcases hy with hy | hy
          · exact hy.symm
          · have := h₂.1 x hx
            have := h₁.1 y hy
            omega
      subst hxy
      have hrest : ∀ z, z ∈ xs ↔ z ∈ ys := by
        intro z
        constructor
        · intro hz
          have := (hm z).mp (by simp [hz])
          simp only [List.mem_cons] at this
          rcases this with h | h
          · have := h₁.1 z hz; omega
          · exact h
        · intro hz
          have := (hm z).mpr (by simp [hz])
          simp only [List.mem_cons] at this
          rcases this with h | h
          · have := h₂.1 z hz; omega
          · exact h
      rw [ih ys h₁.2 h₂.2 hrest]

/-- The canonical form depends only on the members. -/
theorem canonical_eq_of_mem_iff (l l' : IdSet) (hm : ∀ z, z ∈ l ↔ z ∈ l') :
    canonical l = canonical l' :=
  eq_of_sorted_of_mem_iff _ _ (canonical_sorted l) (canonical_sorted l') fun z => by
    rw [mem_canonical, mem_canonical]; exact hm z

/-- THEOREM T8d (union keeps every id from both sides). -/
theorem union_keeps_both (hash : IdSet → Hash) (a b : IdSet) (baseV : Option Hash)
    (x : Nat) :
    (x ∈ a ∨ x ∈ b) ↔
      ∃ m, (mergeAnalyzedIds hash (some a) (some b) baseV).value = some m ∧ x ∈ m := by
  simp only [mergeAnalyzedIds, Option.some.injEq, exists_eq_left', mem_canonical, mem_union]
  exact Or.comm

/-- THEOREM T8k (the merged bytes depend only on the set): two merges whose
sides hold the same ids between them — the two devices of a pair, each
merging the other's upload into its own, or any other split — write the
SAME list, hence the same per-key hash. After one device pushes its
union, the other reads it clean (`analyzed_union_settles`); with the
literal union they can disagree on the order forever
(`union_literal_pingpong_witness`). -/
theorem analyzed_union_order_free (hash : IdSet → Hash) (a b a' b' : IdSet)
    (baseV baseV' : Option Hash) (hm : ∀ x, (x ∈ a ∨ x ∈ b) ↔ (x ∈ a' ∨ x ∈ b')) :
    (mergeAnalyzedIds hash (some a) (some b) baseV).value
      = (mergeAnalyzedIds hash (some a') (some b') baseV').value := by
  simp only [mergeAnalyzedIds, Option.some.injEq]
  apply canonical_eq_of_mem_iff
  intro z
  rw [mem_union, mem_union, Or.comm, hm z, Or.comm]

/-- A device that holds only ids the remote canonical list already has
merges back to exactly that list — it reads clean against the remote
key's hash and sends nothing. -/
theorem analyzed_union_settles (hash : IdSet → Hash) (v loc : IdSet) (baseV : Option Hash)
    (hcanon : canonical v = v) (hsub : ∀ x, x ∈ loc → x ∈ v) :
    (mergeAnalyzedIds hash (some v) (some loc) baseV).value = some v := by
  simp only [mergeAnalyzedIds, Option.some.injEq]
  rw [← hcanon]
  apply canonical_eq_of_mem_iff
  intro z
  rw [mem_union, mem_canonical]
  constructor
  · rintro (h | h)
    · exact hsub z h
    · exact h
  · exact Or.inr

/-- THEOREM T8e (nil against a non-nil baseline is a deletion): whichever
side cleared the key, the key comes out cleared — even if the other side
added ids meanwhile. -/
theorem nil_vs_nonnil_base_deletes (hash : IdSet → Hash) (inV locV : Option IdSet)
    (bh : Hash) (hnil : inV = none ∨ locV = none) :
    (mergeAnalyzedIds hash inV locV (some bh)).value = none := by
  rcases hnil with h | h <;> subst h
  · cases locV <;> simp [mergeAnalyzedIds]
  · cases inV <;> simp [mergeAnalyzedIds]

/-- The side that lost to a deletion is shelved iff it had moved from the
baseline — nothing silently lost (model-added, see `mergeAnalyzedIds`). -/
theorem deletion_shelves_moved_side (hash : IdSet → Hash) (b : IdSet) (bh : Hash)
    (hmoved : hash b ≠ bh) :
    (mergeAnalyzedIds hash none (some b) (some bh)).shelfLocal = true := by
  simp [mergeAnalyzedIds, changed, hmoved]

/-- A key deleted on BOTH sides shelves nothing. -/
theorem double_delete_shelves_nothing (hash : IdSet → Hash) (baseV : Option Hash) :
    mergeAnalyzedIds hash none none baseV = ⟨none, false, false⟩ := by
  cases baseV <;> simp [mergeAnalyzedIds, mergeKey, changed]

/-- The union is literal in membership: a side that SHRANK the set is
unioned back. The codebase's restore paths (`SyncedSettings.apply` with
keep-cloud and `SyncedSettings.replace`) do write the cloud array over
the local one wholesale, so this is the behaviour after such a restore
on the next merge. -/
theorem union_undoes_shrink_witness :
    (mergeAnalyzedIds List.length (some [2]) (some [1, 2]) (some 2)).value = some [1, 2] := by
  decide

/-- An ORDER-SENSITIVE hash of an id list (positional, for single-digit
ids) — what the per-key hash is, since it serialises the array as stored
and the stored array comes from a `Set`. -/
def orderHash (l : IdSet) : Hash := l.foldl (fun acc x => acc * 10 + x) 0

/-- One device's half round on the key: it pulls the server value `v`
(per-key baseline := hash of `v`), merges `v` into its local list, and
pushes the merge iff it reads dirty. Returns (local after, pushed?,
server value after). -/
def unionRound (merge : Option IdSet → Option IdSet → Option Hash → KeyMerge IdSet)
    (v loc : IdSet) : IdSet × Bool × IdSet :=
  let m := ((merge (some v) (some loc) (some (orderHash v))).value).getD []
  (m, decide (orderHash m ≠ orderHash v), if orderHash m ≠ orderHash v then m else v)

/-- UNION PING-PONG WITNESS (against the literal union): A pushed its
list, B holds an overlapping one. B merges, reads dirty, pushes; A
merges the same set into another order, reads dirty, pushes; B merges
back to its order: the states recur, every half round a PATCH, a seq and
a doorbell, forever. -/
theorem union_literal_pingpong_witness :
    unionRound (mergeAnalyzedIdsLiteral orderHash) [1, 2] [1, 3] = ([1, 3, 2], true, [1, 3, 2])
      ∧ unionRound (mergeAnalyzedIdsLiteral orderHash) [1, 3, 2] [1, 2]
          = ([1, 2, 3], true, [1, 2, 3])
      ∧ unionRound (mergeAnalyzedIdsLiteral orderHash) [1, 2, 3] [1, 3, 2]
          = ([1, 3, 2], true, [1, 3, 2])
      ∧ unionRound (mergeAnalyzedIdsLiteral orderHash) [1, 3, 2] [1, 2, 3]
          = ([1, 2, 3], true, [1, 2, 3]) := by
  refine ⟨?_, ?_, ?_, ?_⟩ <;> decide

/-- The same pair under the canonical union: B pushes the sorted union
once, A reads it clean and sends nothing. -/
theorem union_canonical_settles_witness :
    unionRound (mergeAnalyzedIds orderHash) [1, 2] [1, 3] = ([1, 2, 3], true, [1, 2, 3])
      ∧ unionRound (mergeAnalyzedIds orderHash) [1, 2, 3] [1, 2]
          = ([1, 2, 3], false, [1, 2, 3]) := by
  constructor <;> decide

/-! ### The row: the seq skip, the per-key pass, and the post-merge baseline

The settings baseline is "每键 hash + 行 seq". The row-level skip row
applies first (the seq is the row's); then every key goes through
`mergeKey`. After the pass the row seq is the incoming seq and EVERY
key's baseline is the remote value's hash (`none` for an absent key) —
conflict keys included, the per-key form of the conflict row's
`(h_in, seq)`: a baseline names only what the server holds, so a key is
dirty exactly when its local value differs from the server's
(`mergeKeys_dirty_iff_differs_remote`). A key the local side changed
therefore stays dirty and is uploaded; a key the remote side changed
reads clean; after a conflict, setting the key back to its old value, or
deleting it, still reads dirty (`settings_conflict_key_revert_witness`). -/

abbrev Key := Nat
abbrev SettingsRow (V : Type) := Key → Option V

/-- The settings baseline: per-key hashes and the row seq. -/
structure Base where
  keys : Key → Option Hash
  seq : Seq

/-- The per-key pass over every key, with the post-merge baseline and the
per-key shelf flag (the remote side's value, `{key, remote: absent}` when
`none`, is what goes to the shelf). -/
def mergeKeys (hash : V → Hash) (loc : SettingsRow V) (keys : Key → Option Hash)
    (inRow : SettingsRow V) (inSeq : Seq) : SettingsRow V × Base × (Key → Bool) :=
  (fun k => (mergeKey hash (inRow k) (loc k) (keys k)).value,
   ⟨fun k => (inRow k).map hash, inSeq⟩,
   fun k => (mergeKey hash (inRow k) (loc k) (keys k)).shelfRemote)

/-- The superseded per-key baseline: a conflict key keeps its old hash.
Kept only for `settings_conflict_key_revert_witness`. -/
def mergeKeysKeepHash (hash : V → Hash) (loc : SettingsRow V) (keys : Key → Option Hash)
    (inRow : SettingsRow V) (inSeq : Seq) : SettingsRow V × Base × (Key → Bool) :=
  (fun k => (mergeKey hash (inRow k) (loc k) (keys k)).value,
   ⟨fun k => if (mergeKey hash (inRow k) (loc k) (keys k)).shelfRemote then keys k
      else (inRow k).map hash, inSeq⟩,
   fun k => (mergeKey hash (inRow k) (loc k) (keys k)).shelfRemote)

/-- One settings row applied: the row-level skip first, then the per-key
pass; with no baseline, every key is compared against nothing (the M1
case, and the third branch of the upgrade rule). -/
def mergeRow (hash : V → Hash) (loc : SettingsRow V) (base : Option Base)
    (inRow : SettingsRow V) (inSeq : Seq) : SettingsRow V × Base × (Key → Bool) :=
  match base with
  | some b => if inSeq ≤ b.seq then (loc, b, fun _ => false)
      else mergeKeys hash loc b.keys inRow inSeq
  | none => mergeKeys hash loc (fun _ => none) inRow inSeq

/-- THEOREM T8g (re-applying a settings row is the identity): the first
application left the row seq in the baseline, so the second is the skip
row — no key is re-merged, nothing is shelved again. -/
theorem mergeRow_reapply_skip (hash : V → Hash) (loc : SettingsRow V) (base : Option Base)
    (inRow : SettingsRow V) (inSeq : Seq) :
    mergeRow hash (mergeRow hash loc base inRow inSeq).1
        (some (mergeRow hash loc base inRow inSeq).2.1) inRow inSeq
      = ((mergeRow hash loc base inRow inSeq).1,
          (mergeRow hash loc base inRow inSeq).2.1, fun _ => false) := by
  cases base with
  | none => simp [mergeRow, mergeKeys]
  | some b =>
    by_cases hle : inSeq ≤ b.seq
    · simp [mergeRow, hle]
    · simp [mergeRow, mergeKeys, hle]

/-- THEOREM T8h (a key the local side changed stays dirty): if the local
value moved from the baseline and differs from the remote value, the
merged value is the local one and it is still dirty against the new
per-key baseline — the next upload carries it. Both shapes are covered:
remote unchanged (local took the key, no shelf) and remote changed too
(conflict, remote shelved). -/
theorem mergeKeys_local_change_stays_dirty (hash : V → Hash) (loc : SettingsRow V)
    (keys : Key → Option Hash) (inRow : SettingsRow V) (inSeq : Seq) (k : Key)
    (hloc : changed hash (loc k) (keys k) = true)
    (hne : (inRow k).map hash ≠ (loc k).map hash) :
    (mergeKeys hash loc keys inRow inSeq).1 k = loc k
      ∧ changed hash ((mergeKeys hash loc keys inRow inSeq).1 k)
          ((mergeKeys hash loc keys inRow inSeq).2.1.keys k) = true := by
  have hval : (mergeKeys hash loc keys inRow inSeq).1 k = loc k := by
    simp only [mergeKeys, mergeKey]
    cases hin : changed hash (inRow k) (keys k)
    · simp
    · simp [hloc, hne]
  refine ⟨hval, ?_⟩
  rw [hval]
  simp only [mergeKeys, changed]
  exact decide_eq_true (fun h => hne h.symm)

/-- THEOREM T8i (a key only the remote side changed reads clean): the
merged value is the remote one and the new per-key baseline is its hash. -/
theorem mergeKeys_remote_change_clean (hash : V → Hash) (loc : SettingsRow V)
    (keys : Key → Option Hash) (inRow : SettingsRow V) (inSeq : Seq) (k : Key)
    (hin : changed hash (inRow k) (keys k) = true)
    (hloc : changed hash (loc k) (keys k) = false) :
    (mergeKeys hash loc keys inRow inSeq).1 k = inRow k
      ∧ (mergeKeys hash loc keys inRow inSeq).2.1.keys k = (inRow k).map hash
      ∧ changed hash ((mergeKeys hash loc keys inRow inSeq).1 k)
          ((mergeKeys hash loc keys inRow inSeq).2.1.keys k) = false := by
  simp only [mergeKeys, mergeKey, hin, hloc, Bool.true_eq_false, ↓reduceIte]
  refine ⟨by trivial, by trivial, ?_⟩
  simp [changed]

/-- THEOREM T8j (same bytes on both sides read clean): both changed to
the same bytes — the merged value is local (= remote bytes) and the new
baseline is its hash. -/
theorem mergeKeys_same_bytes_clean (hash : V → Hash) (loc : SettingsRow V)
    (keys : Key → Option Hash) (inRow : SettingsRow V) (inSeq : Seq) (k : Key)
    (hin : changed hash (inRow k) (keys k) = true)
    (hloc : changed hash (loc k) (keys k) = true)
    (hsame : (inRow k).map hash = (loc k).map hash) :
    (mergeKeys hash loc keys inRow inSeq).1 k = loc k
      ∧ changed hash ((mergeKeys hash loc keys inRow inSeq).1 k)
          ((mergeKeys hash loc keys inRow inSeq).2.1.keys k) = false := by
  simp only [mergeKeys, mergeKey, hin, hloc, hsame, Bool.true_eq_false, ↓reduceIte]
  refine ⟨by trivial, ?_⟩
  simp [changed]

/-- The per-key baseline after the pass is the remote value's hash on
EVERY key — conflict keys included — and the row seq is the incoming
seq. Definitional (`⟨rfl, rfl⟩`): it restates `mergeKeys` so a change to
the writing breaks a named statement; the semantic content is carried
by `mergeKeys_local_change_stays_dirty` and
`settings_conflict_key_revert_witness`. -/
theorem mergeKeys_base_tracks_remote (hash : V → Hash) (loc : SettingsRow V)
    (keys : Key → Option Hash) (inRow : SettingsRow V) (inSeq : Seq) (k : Key) :
    (mergeKeys hash loc keys inRow inSeq).2.1.keys k = (inRow k).map hash
      ∧ (mergeKeys hash loc keys inRow inSeq).2.1.seq = inSeq := ⟨rfl, rfl⟩

/-- THEOREM (a key is dirty exactly when it differs from the server):
after the pass, ANY later local value of a key — the merged one, an edit,
a revert to the old value, a deletion — reads dirty iff its hash is not
the remote value's. Close to definitional (it unfolds `mergeKeys` and
`changed`); like `mergeKeys_base_tracks_remote` it pins the writing. -/
theorem mergeKeys_dirty_iff_differs_remote (hash : V → Hash) (loc : SettingsRow V)
    (keys : Key → Option Hash) (inRow : SettingsRow V) (inSeq : Seq) (k : Key)
    (v : Option V) :
    changed hash v ((mergeKeys hash loc keys inRow inSeq).2.1.keys k) = true
      ↔ v.map hash ≠ (inRow k).map hash := by
  simp only [mergeKeys, changed]
  exact decide_eq_true_iff

/-- One key that both sides moved, to different values: a conflict key. -/
def keyLoc : SettingsRow Nat := fun k => if k = 0 then some 1 else none
def keyIn : SettingsRow Nat := fun k => if k = 0 then some 2 else none
def keyBase : Key → Option Hash := fun k => if k = 0 then some 0 else none

/-- SETTINGS CONFLICT-KEY REVERT WITNESS (against the superseded per-key
baseline): the key conflicts (local wins, remote shelved). Under
`mergeKeysKeepHash` the key keeps its old hash, so setting it back to
the old value reads CLEAN while the server holds the remote one; and
with an empty baseline (the upgrade rule's third branch) deleting the
conflict key reads clean while the server keeps the value. Under
`mergeKeys` both read dirty and are uploaded. -/
theorem settings_conflict_key_revert_witness :
    (mergeKeys id keyLoc keyBase keyIn 6).2.2 0 = true
      ∧ (mergeKeysKeepHash id keyLoc keyBase keyIn 6).2.1.keys 0 = some 0
      ∧ changed id (some 0) ((mergeKeysKeepHash id keyLoc keyBase keyIn 6).2.1.keys 0) = false
      ∧ changed id none ((mergeKeysKeepHash id keyLoc (fun _ => none) keyIn 6).2.1.keys 0)
          = false
      ∧ (mergeKeys id keyLoc keyBase keyIn 6).2.1.keys 0 = some 2
      ∧ changed id (some 0) ((mergeKeys id keyLoc keyBase keyIn 6).2.1.keys 0) = true
      ∧ changed id none ((mergeKeys id keyLoc (fun _ => none) keyIn 6).2.1.keys 0) = true := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> decide

/-! ### The §6 upgrade rule for the settings baseline -/

/-- From today's single row hash to a per-key baseline: local clean → local
hashes; else remote is our last upload → remote hashes; else empty.
`rowHash inRow` is the hash of the REMOTE row re-projected through the
client's own canonical projection (`rowToX → xToRowForHashing`, §6's
`h_in`), never of the response body as received — a body hash carries
`seq`, `deleted_at` and server normalisation and never equals a local
`eventToRow` hash (review-four H1), so the second branch would never
fire on it. The model abstracts `rowHash`; the Swift author must not. -/
def upgradeBase (hash : V → Hash) (rowHash : SettingsRow V → Hash)
    (oldRowHash : Hash) (locRow inRow : SettingsRow V) : Key → Option Hash :=
  if rowHash locRow = oldRowHash then fun k => (locRow k).map hash
  else if rowHash inRow = oldRowHash then fun k => (inRow k).map hash
  else fun _ => none

/-- THEOREM T8f-1 (local clean; keys under the general rule): every key
merges to the remote value's hash with nothing shelved. -/
theorem upgrade_local_clean (hash : V → Hash) (rowHash : SettingsRow V → Hash)
    (oldRowHash : Hash) (locRow inRow : SettingsRow V)
    (h : rowHash locRow = oldRowHash) (k : Key) :
    ((mergeKey hash (inRow k) (locRow k)
        (upgradeBase hash rowHash oldRowHash locRow inRow k)).value).map hash
        = (inRow k).map hash
      ∧ (mergeKey hash (inRow k) (locRow k)
        (upgradeBase hash rowHash oldRowHash locRow inRow k)).shelfRemote = false := by
  simp only [upgradeBase, h, ↓reduceIte]
  have hl : changed hash (locRow k) ((locRow k).map hash) = false := by
    simp [changed]
  by_cases hc : changed hash (inRow k) ((locRow k).map hash) = true
  · simp [mergeKey, hc, hl]
  · simp only [Bool.not_eq_true] at hc
    simp only [mergeKey, hc, ↓reduceIte, and_true]
    exact (Decidable.not_not.mp (of_decide_eq_false hc)).symm

/-- The bytes version of T8f-1, under injectivity: the merged value IS
the remote value. -/
theorem upgrade_local_clean_bytes (hash : V → Hash) (hinj : HashInjective hash)
    (rowHash : SettingsRow V → Hash)
    (oldRowHash : Hash) (locRow inRow : SettingsRow V)
    (h : rowHash locRow = oldRowHash) (k : Key) :
    (mergeKey hash (inRow k) (locRow k)
        (upgradeBase hash rowHash oldRowHash locRow inRow k)).value = inRow k := by
  have hm := (upgrade_local_clean hash rowHash oldRowHash locRow inRow h k).1
  revert hm
  cases (mergeKey hash (inRow k) (locRow k)
      (upgradeBase hash rowHash oldRowHash locRow inRow k)).value with
  | none => cases inRow k <;> simp
  | some v =>
    cases inRow k with
    | none => simp
    | some w =>
      intro hm
      simp only [Option.map_some, Option.some.injEq] at hm
      rw [hinj _ _ hm]

/-- THEOREM T8f-2 (remote is our own last upload; keys under the general
rule): every key merges to the local value with nothing shelved — the
differences are all ours. -/
theorem upgrade_remote_is_ours (hash : V → Hash) (rowHash : SettingsRow V → Hash)
    (oldRowHash : Hash) (locRow inRow : SettingsRow V)
    (h1 : rowHash locRow ≠ oldRowHash) (h2 : rowHash inRow = oldRowHash) (k : Key) :
    mergeKey hash (inRow k) (locRow k)
        (upgradeBase hash rowHash oldRowHash locRow inRow k) = ⟨locRow k, false, false⟩ := by
  have hc : changed hash (inRow k) ((inRow k).map hash) = false := by simp [changed]
  simp [upgradeBase, h1, h2, mergeKey, hc]

/-- THEOREM T8f-3 (neither hash matches — empty baseline; keys under the
general rule): a key present on both sides with different bytes is a
conflict (local wins, remote shelved); a key present on one side only is
taken from that side. The "stale local key overrides a newer remote
value" cost the design admits is exactly the first clause. -/
theorem upgrade_empty_baseline (hash : V → Hash) (rowHash : SettingsRow V → Hash)
    (oldRowHash : Hash) (locRow inRow : SettingsRow V)
    (h1 : rowHash locRow ≠ oldRowHash) (h2 : rowHash inRow ≠ oldRowHash) (k : Key) :
    (∀ a b, inRow k = some a → locRow k = some b → hash a ≠ hash b →
        mergeKey hash (inRow k) (locRow k)
          (upgradeBase hash rowHash oldRowHash locRow inRow k) = ⟨some b, true, false⟩)
    ∧ (locRow k = none →
        mergeKey hash (inRow k) (locRow k)
          (upgradeBase hash rowHash oldRowHash locRow inRow k) = ⟨inRow k, false, false⟩)
    ∧ (inRow k = none →
        mergeKey hash (inRow k) (locRow k)
          (upgradeBase hash rowHash oldRowHash locRow inRow k) = ⟨locRow k, false, false⟩) := by
  simp only [upgradeBase, h1, h2, ↓reduceIte]
  refine ⟨?_, ?_, ?_⟩
  · intro a b ha hb hne
    simp [mergeKey, changed, ha, hb, hne]
  · intro hl
    cases inRow k <;> simp [mergeKey, changed, hl]
  · intro hi
    simp [mergeKey, changed, hi]

end Settings

/-! ## Singleton tables — the 单行表 tombstone rule

user_settings / agent_preferences / agent_conversations are keyed by
`user_id`: the local row always exists (no absent state, no delete
cascade), so an incoming tombstone has no "local absent" and no cascade
to go to. §6's rule: local untouched, nothing shelved, baseline :=
`(hash(local), seq)`; and on the upload side a `[row]` response with
`deleted_at` set is the REGULAR path — baseline := `(hash sent, row.seq)`,
local untouched, `sync.push.tombstoned_singleton`. The id-table rows
above do NOT apply to them (`decideRow`'s tombstone row removes the
local row and the entry; `pushRow`'s dead-row branch shelves and
removes), and `Inv.noDead` is false on them by design. What is proved
here is the design's own arithmetic for the baseline writing:
`(hash local, seq)` is a fixed point — nothing is pushed until the user
edits — while `(h_in, seq)` (what every other row of the table writes,
the conflict row included) makes two devices ping-pong through the dead
row forever. This tombstone branch is therefore the one place a baseline
is deliberately NOT the incoming row's: a dead row is not content a
replica converges to. Removing the entry
instead (the other writing review seven considered) POSTs on every
flush. The content model here is the whole row; the per-key form for
user_settings is NOT modelled — nothing here composes with
`Settings.mergeRow` — and neither are the singleton tables' live-row
rules (the witnesses that need one after an undelete apply the id-table
live rows, which are the whole-row three-way of agent_preferences /
agent_conversations).

The text writes `(hash(local), seq)` whether or not the local row was
DIRTY. A dirty row then reads clean, is never uploaded, and an undelete
(#140) brings the dead row's bytes back over it with nothing shelved —
contrary to the text's "不丢任何一方". Not only for an edit dirty at the
dashboard tombstone (`singleton_dirty_tombstone_lost_on_undelete_witness`):
every dead-row write by one device reaches the others as a fresh
tombstone, so ANY edit concurrent with another device's during the
dead-row period is erased the same way
(`singleton_dead_period_edit_lost_witness`; T10d's third conjunct,
read for a dirty device). Two variants, neither the text's:
`applyTombstoneKeepDirty` keeps a dirty row's old hash — one dead-row
write carries the edit, then the fixed point, and the undelete restores
it (`singleton_dirty_keeps_hash_witness`), but two devices dirty in the
same period keep only the last dead-row writer, unshelved
(`singleton_concurrent_dirty_last_writer_witness`).
`applyTombstoneShelve` is the text's rule on a clean row (so no
ping-pong, `applyTombstoneShelve_clean`) and the id-table rows on a
dirty one — the dead row's bytes shelved unless they are the baseline's
or the local row's, baseline `(h_in, seq)`, one dead-row write
(`applyTombstoneShelve_dirty_one_write`) — and on both losing runs
nothing is lost (`singleton_shelve_variant_keeps_both_witness`). The
skip row in front of the rule is `applyTombstone_base_seq_monotone`
and `singleton_stale_tombstone_skipped_witness`. -/

namespace Singleton

variable {C : Type} [DecidableEq C]

/-- A singleton-table replica: the local row always exists, and the
baseline `(hash, seq)`. -/
structure Rep (C : Type) where
  loc : C
  base : Option (Hash × Seq)

/-- The §6 单行表 tombstone rule, after the table's skip row (a tombstone
whose seq the baseline already names or exceeds is skipped): local
untouched, not shelved, baseline `(hash(local), seq)` — dirty or not. -/
def applyTombstone (hash : C → Hash) (r : Rep C) (seq : Seq) : Rep C :=
  if staleOrSeen r.base seq then r else { r with base := some (hash r.loc, seq) }

omit [DecidableEq C] in
theorem applyTombstone_noskip (hash : C → Hash) (r : Rep C) (seq : Seq)
    (hns : staleOrSeen r.base seq = false) :
    applyTombstone hash r seq = ⟨r.loc, some (hash r.loc, seq)⟩ := by
  simp [applyTombstone, hns]

/-- A variant, not the text's writing: a DIRTY local row keeps its old
baseline hash and takes the tombstone's seq, so it is still uploaded —
onto the dead row; a clean row takes `(hash(local), seq)`. With no
baseline the local row counts as dirty against the dead row's bytes. -/
def applyTombstoneKeepDirty (hash : C → Hash) (r : Rep C) (hIn : Hash) (seq : Seq) : Rep C :=
  if staleOrSeen r.base seq then r
  else if r.base.map Prod.fst = some (hash r.loc) then { r with base := some (hash r.loc, seq) }
  else { r with base := some ((r.base.map Prod.fst).getD hIn, seq) }

/-- The writing the design rejects by arithmetic: baseline `(h_in, seq)`,
as the id-table rows write it (its non-skip branch: every use below is
at a seq above the baseline's). -/
def applyTombstoneIn (hash : C → Hash) (r : Rep C) (inc : C) (seq : Seq) : Rep C :=
  { r with base := some (hash inc, seq) }

/-- The upload shape on a singleton table (`user_id=eq.<uid>&seq=eq.<base>`):
dirty → conditional PATCH; `[row]`, live OR dead, → baseline
`(hash sent, row.seq)`, local untouched; `[]` → pull. No baseline →
ignore-duplicates POST. The result's flag is "a pull is wanted". -/
def push (hash : C → Hash) (uid : Id) (s : Server C) (r : Rep C) :
    Server C × Rep C × Bool :=
  if r.base.map Prod.fst = some (hash r.loc) then (s, r, false)
  else
    match r.base with
    | some (_, bseq) =>
      match s.patch uid bseq r.loc with
      | (s', some row) => (s', { r with base := some (hash r.loc, row.seq) }, false)
      | (s', none) => (s', r, true)
    | none =>
      match s.insertIgnore uid r.loc with
      | (s', some seq') => (s', { r with base := some (hash r.loc, seq') }, false)
      | (s', none) => (s', r, true)

omit [DecidableEq C] in
/-- The skip row in front of the rule, as an effect: a tombstone never
moves a singleton baseline seq backwards. Without the skip row a stale
tombstone page (an older dead row, re-pulled or applied late) would put
the baseline on a seq the dead row has left, and the next PATCH
`seq=eq.<that seq>` would answer `[]` (`singleton_stale_tombstone_skipped_witness`). -/
theorem applyTombstone_base_seq_monotone (hash : C → Hash) (r : Rep C) (seq : Seq)
    (h : Hash) (S : Seq) (hb : r.base = some (h, S)) :
    ∃ h' S', (applyTombstone hash r seq).base = some (h', S') ∧ S ≤ S' := by
  unfold applyTombstone
  cases hs : staleOrSeen r.base seq
  · simp only [Bool.false_eq_true, ↓reduceIte]
    rw [hb] at hs
    have hlt : S < seq := Nat.lt_of_not_le (by simpa [staleOrSeen] using hs)
    exact ⟨_, _, rfl, Nat.le_of_lt hlt⟩
  · simp only [↓reduceIte]
    exact ⟨h, S, hb, Nat.le_refl _⟩

/-- The rule without its skip row: `(hash(local), seq)` whatever the seq. -/
def applyTombstoneNoSkip (hash : C → Hash) (r : Rep C) (seq : Seq) : Rep C :=
  { r with base := some (hash r.loc, seq) }

/-- A variant, not the text's writing (one answer to the dirty-singleton
decision): a CLEAN row, or one with no baseline, takes the text's
`(hash(local), seq)`, so a tombstone never makes a clean row dirty; a DIRTY
row takes the id-table rows with the dead row's bytes as the incoming
content — echo (they are the baseline's bytes) or same (they are the
local row's) write `(h_in, seq)` and shelve nothing; otherwise the dead
row's bytes are shelved and the baseline is `(h_in, seq)`. A dirty row
that is not `same` stays dirty and is written into the dead row once.
Returns the replica and the shelf lines it files. -/
def applyTombstoneShelve (hash : C → Hash) (r : Rep C) (inc : C) (seq : Seq) :
    Rep C × List C :=
  if staleOrSeen r.base seq then (r, [])
  else
    match r.base with
    | none => ({ r with base := some (hash r.loc, seq) }, [])
    | some (bh, _) =>
      if bh = hash r.loc then ({ r with base := some (hash r.loc, seq) }, [])
      else if bh = hash inc ∨ hash r.loc = hash inc then
        ({ r with base := some (hash inc, seq) }, [])
      else ({ r with base := some (hash inc, seq) }, [inc])

omit [DecidableEq C] in
/-- The variant is the text's rule on a clean row and on a row with no
baseline — it shelves nothing there, and T10a's fixed point is its
fixed point: a tombstone never makes a clean row dirty, the step the
ping-pong of T10b runs on. -/
theorem applyTombstoneShelve_clean (hash : C → Hash) (r : Rep C) (inc : C) (seq : Seq)
    (hc : r.base = none ∨ r.base.map Prod.fst = some (hash r.loc)) :
    applyTombstoneShelve hash r inc seq = (applyTombstone hash r seq, []) := by
  unfold applyTombstoneShelve applyTombstone
  cases hs : staleOrSeen r.base seq
  · simp only [Bool.false_eq_true, ↓reduceIte]
    rcases hc with hn | hm
    · rw [hn]
    · cases hb : r.base with
      | none => rfl
      | some b =>
        obtain ⟨bh, bs⟩ := b
        rw [hb] at hm
        simp only [Option.map_some, Option.some.injEq] at hm
        simp [hm]
  · rfl

/-- THEOREM (the variant on a dirty row is one dead-row write): the server
holds the dead row `inc` at `S`; the row is dirty over a baseline below
`S` and its bytes differ from the dead row's. The variant writes
`(hash inc, S)` — dirty — and the next flush PATCHes `seq=eq.S`, which
writes the local bytes into the dead row, after which the row is clean
on `(hash local, new seq)` and the flush after that sends nothing. -/
theorem applyTombstoneShelve_dirty_one_write (hash : C → Hash) (uid : Id) (s : Server C)
    (inc : C) (S : Seq) (r : Rep C) (bh : Hash) (S₀ : Seq)
    (hrow : s.rows uid = some ⟨inc, S, true⟩) (hb : r.base = some (bh, S₀)) (hlt : S₀ < S)
    (hdirty : bh ≠ hash r.loc) (hdiff : hash r.loc ≠ hash inc) :
    (applyTombstoneShelve hash r inc S).1 = ⟨r.loc, some (hash inc, S)⟩
      ∧ push hash uid s (applyTombstoneShelve hash r inc S).1
          = (s.setRow uid ⟨r.loc, s.next, true⟩ s.next, ⟨r.loc, some (hash r.loc, s.next)⟩, false)
      ∧ push hash uid (s.setRow uid ⟨r.loc, s.next, true⟩ s.next) ⟨r.loc, some (hash r.loc, s.next)⟩
          = (s.setRow uid ⟨r.loc, s.next, true⟩ s.next, ⟨r.loc, some (hash r.loc, s.next)⟩, false) := by
  have hns : staleOrSeen r.base S = false := by
    rw [hb]; simp [staleOrSeen, Nat.not_le.mpr hlt]
  have h1 : (applyTombstoneShelve hash r inc S).1 = ⟨r.loc, some (hash inc, S)⟩ := by
    unfold applyTombstoneShelve
    rw [hns]
    simp only [Bool.false_eq_true, ↓reduceIte]
    rw [hb]
    simp only [hdirty, ↓reduceIte]
    split <;> rfl
  have hne : r.loc ≠ inc := fun h => hdiff (by rw [h])
  refine ⟨h1, ?_, by simp [push]⟩
  rw [h1]
  have hpatch : s.patch uid S r.loc
      = (s.setRow uid ⟨r.loc, s.next, true⟩ s.next, some ⟨r.loc, s.next, true⟩) := by
    unfold Server.patch
    simp [hrow, Ne.symm hne]
  unfold push
  simp [Ne.symm hdiff, hpatch]

/-- THEOREM T10a (the design's writing is a fixed point): after the
singleton tombstone rule the row reads clean, so the next flush sends
nothing and the server is untouched — for any local bytes, on either
device, whether or not they differ. -/
theorem tombstone_fixed_point (hash : C → Hash) (uid : Id) (s : Server C) (r : Rep C)
    (seq : Seq) (hns : staleOrSeen r.base seq = false) :
    push hash uid s (applyTombstone hash r seq) = (s, applyTombstone hash r seq, false) := by
  rw [applyTombstone_noskip hash r seq hns]
  simp [push]

/-- THEOREM T10d (a local edit after the tombstone is ONE dead-row write,
then the fixed point on both devices — §7's acceptance item): the server
holds the dead row at `S`; this device took the tombstone at `S` (local
`l`, baseline `(hash l, S)`) and then the user changed the row to `v`.
The next flush PATCHes `seq=eq.S`, which matches the dead row: I6 keeps
it dead, a seq is minted, `[row]` comes back dead and the regular
singleton path writes `(hash v, new seq)`. The flush after that sends
nothing; the other device, pulling that dead row, takes it by the
tombstone rule and sends nothing either — for EVERY `o` the skip row does
not skip. For a CLEAN `o` that is the acceptance item's fixed point. For
a DIRTY `o` — edited during the dead-row period, its own PATCH
`seq=eq.S` answered `[]` — the same conjunct is the loss: the rule makes
`o` clean over its unsent bytes, they never reach the server, and an
undelete brings `v` back over them with nothing shelved
(`singleton_dead_period_edit_lost_witness`). `v ≠ c0` leaves out an
edit back to the dead row's own bytes: that PATCH is content-identical,
answers `[]`, and its closure — the singleton pending-verify — is not
modelled (`singleton_edit_to_dead_bytes_witness`). -/
theorem tombstone_then_edit_one_dead_write (hash : C → Hash) (uid : Id) (s : Server C)
    (c0 : C) (S : Seq) (l v : C)
    (hrow : s.rows uid = some ⟨c0, S, true⟩) (hdirty : hash v ≠ hash l) (hne : v ≠ c0) :
    push hash uid s ⟨v, some (hash l, S)⟩
        = (s.setRow uid ⟨v, s.next, true⟩ s.next, ⟨v, some (hash v, s.next)⟩, false)
      ∧ push hash uid (s.setRow uid ⟨v, s.next, true⟩ s.next) ⟨v, some (hash v, s.next)⟩
        = (s.setRow uid ⟨v, s.next, true⟩ s.next, ⟨v, some (hash v, s.next)⟩, false)
      ∧ ∀ o : Rep C, staleOrSeen o.base s.next = false →
          push hash uid (s.setRow uid ⟨v, s.next, true⟩ s.next) (applyTombstone hash o s.next)
            = (s.setRow uid ⟨v, s.next, true⟩ s.next, applyTombstone hash o s.next, false) := by
  refine ⟨?_, by simp [push], fun o ho => tombstone_fixed_point hash uid _ o _ ho⟩
  have hpatch : s.patch uid S v
      = (s.setRow uid ⟨v, s.next, true⟩ s.next, some ⟨v, s.next, true⟩) := by
    unfold Server.patch
    simp [hrow, Ne.symm hne]
  unfold push
  simp [Ne.symm hdirty, hpatch]

/-- The ping-pong state under the `(h_in, seq)` writing: the server's dead
row holds the LAST pusher's bytes at the counter; the last pusher is
clean on it; the other device holds different bytes over that same
`(h_in, seq)` baseline — dirty. -/
structure PingPong (hash : C → Hash) (uid : Id) (s : Server C) (last other : Rep C) : Prop where
  row : s.rows uid = some ⟨last.loc, s.counter, true⟩
  lastBase : last.base = some (hash last.loc, s.counter)
  otherBase : other.base = some (hash last.loc, s.counter)
  differ : hash other.loc ≠ hash last.loc

/-- One half round: `other` pushes (its PATCH matches the dead row's seq,
I6 keeps the row dead, a seq is minted, `[row]` comes back dead and the
regular singleton path writes `(hash sent, row.seq)`), then `last` pulls
that tombstone and — under the rejected writing — takes
`(h_in, seq) = (hash other.loc, new seq)`. -/
def naiveHalfRound (hash : C → Hash) (uid : Id) (s : Server C) (last other : Rep C) :
    Server C × Rep C × Rep C :=
  let p := push hash uid s other
  (p.1, p.2.1, applyTombstoneIn hash last p.2.1.loc p.1.counter)

/-- THEOREM T10b (the `(h_in, seq)` writing never settles): a half round
from a ping-pong state mints a seq, writes the other device's bytes into
the dead row, and lands in the ping-pong state with the roles swapped —
so by induction every further half round mints another seq, each device
dirty in turn, forever; the undelete RPC is the only exit. `(h_in, seq)`
is what the id-table rows write; this is why the singleton rule writes
`(hash local, seq)` instead. -/
theorem naive_half_round (hash : C → Hash) (uid : Id) (s : Server C) (last other : Rep C)
    (h : PingPong hash uid s last other) :
    PingPong hash uid (naiveHalfRound hash uid s last other).1
        (naiveHalfRound hash uid s last other).2.1 (naiveHalfRound hash uid s last other).2.2
      ∧ (naiveHalfRound hash uid s last other).1.counter = s.counter + 1 := by
  have hne : other.loc ≠ last.loc := fun heq => h.differ (by rw [heq])
  have hpush : push hash uid s other =
      (s.setRow uid { content := other.loc, seq := s.next, deleted := true } s.next,
        { other with base := some (hash other.loc, s.next) }, false) := by
    unfold push
    have hdirty : other.base.map Prod.fst ≠ some (hash other.loc) := by
      rw [h.otherBase]; simp [Ne.symm h.differ]
    simp only [hdirty, ↓reduceIte]
    rw [h.otherBase]
    simp only
    unfold Server.patch
    rw [h.row]
    simp [Ne.symm hne]
  simp only [naiveHalfRound, hpush]
  refine ⟨⟨?_, ?_, ?_, ?_⟩, rfl⟩
  · simp [Server.setRow, Server.next]
  · rfl
  · simp [applyTombstoneIn, Server.setRow, Server.next]
  · exact Ne.symm h.differ

/-- THEOREM T10c (removing the entry instead POSTs on every flush): with
no baseline the next flush is an ignore-duplicates POST; the server
holds the (dead) row, so the POST is DO NOTHING, burns a seq, returns no
row, and asks for a pull that will show nothing — `sync.push.orphan`
every flush, the permanent state the design describes. -/
theorem base_removed_posts_forever (hash : C → Hash) (uid : Id) (s : Server C) (c : C)
    (row : Row C) (hrow : s.rows uid = some row) :
    push hash uid s ⟨c, none⟩ = ({ s with counter := s.next }, ⟨c, none⟩, true) := by
  unfold push
  simp only [Option.map_none, reduceCtorEq, ↓reduceIte]
  unfold Server.insertIgnore
  rw [hrow]

/-- The server holding the singleton row as a tombstone at 7, its bytes c0. -/
def deadSrv : Server Nat := oneServer (some ⟨0, 7, true⟩) 7

/-- DIRTY-AT-TOMBSTONE WITNESS (against the text's writing): local c1,
dirty over c0's baseline at 5, not yet pushed when the tombstone at 7
arrives. The rule writes `(hash c1, 7)`: clean, the next flush sends
nothing (counter stays 7). An undelete (#140, not a `ClientOp`) brings
the dead row's bytes c0 back live at 8; the whole-row rule adopts c0
with nothing shelved. c1 was never on the server, on a shelf, or on
another device. -/
theorem singleton_dirty_tombstone_lost_on_undelete_witness :
    (applyTombstone id ⟨1, some (0, 5)⟩ 7).base = some (1, 7)
      ∧ (push id 1 deadSrv (applyTombstone id ⟨1, some (0, 5)⟩ 7)).1.counter = 7
      ∧ deadSrv.rows 1 = some ⟨0, 7, true⟩
      ∧ (applyRow id (oneRowAt (some 1) (some (1, 7)) 7) ⟨1, 8, 0, false⟩).loc 1 = some 0
      ∧ (applyRow id (oneRowAt (some 1) (some (1, 7)) 7) ⟨1, 8, 0, false⟩).shelf = [] := by
  refine ⟨?_, ?_, ?_, ?_, ?_⟩ <;> decide

/-- The keep-dirty variant on the same run: the tombstone leaves c1 dirty
(`(h0, 7)`); one PATCH `seq=eq.7` writes c1 into the dead row at 8 and
the baseline becomes `(h1, 8)`; the next flush sends nothing. The other
device, clean on c0, takes both tombstones and sends nothing. The
undelete brings c1 back at 9: an echo here, adopted there. -/
theorem singleton_dirty_keeps_hash_witness :
    (applyTombstoneKeepDirty id ⟨1, some (0, 5)⟩ 0 7).base = some (0, 7)
      ∧ (push id 1 deadSrv (applyTombstoneKeepDirty id ⟨1, some (0, 5)⟩ 0 7)).1.rows 1
          = some ⟨1, 8, true⟩
      ∧ (push id 1 deadSrv (applyTombstoneKeepDirty id ⟨1, some (0, 5)⟩ 0 7)).2.1.base
          = some (1, 8)
      ∧ (push id 1 (push id 1 deadSrv (applyTombstoneKeepDirty id ⟨1, some (0, 5)⟩ 0 7)).1
          (push id 1 deadSrv (applyTombstoneKeepDirty id ⟨1, some (0, 5)⟩ 0 7)).2.1).1.counter
          = 8
      ∧ (applyTombstoneKeepDirty id (applyTombstoneKeepDirty id ⟨0, some (0, 5)⟩ 0 7) 1 8).base
          = some (0, 8)
      ∧ (push id 1 (push id 1 deadSrv (applyTombstoneKeepDirty id ⟨1, some (0, 5)⟩ 0 7)).1
          (applyTombstoneKeepDirty id (applyTombstoneKeepDirty id ⟨0, some (0, 5)⟩ 0 7) 1 8)).1.counter
          = 8
      ∧ (applyRow id (oneRowAt (some 1) (some (1, 8)) 8) ⟨1, 9, 1, false⟩).loc 1 = some 1
      ∧ (applyRow id (oneRowAt (some 0) (some (0, 8)) 8) ⟨1, 9, 1, false⟩).loc 1 = some 1
      ∧ (applyRow id (oneRowAt (some 0) (some (0, 8)) 8) ⟨1, 9, 1, false⟩).shelf = [] := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> decide

/-- Two devices dirty at the same tombstone, under the keep-dirty
variant: A (c1) and B (c2), both over c0's baseline at 5. A's PATCH
`seq=eq.7` lands c1 in the dead row at 8; B's `seq=eq.7` answers `[]`;
B takes the dead row at 8, still dirty, and its PATCH `seq=eq.8` lands
c2 at 9; A takes the dead row at 9 — clean on c1, so it keeps c1 and
sends nothing. The undelete brings c2 back at 10 and A adopts it with
nothing shelved: the dead row is last-writer-wins with no shelf. Under
the text's writing both devices read clean at 7, nothing is written,
and the undelete brings back c0 on both. -/
theorem singleton_concurrent_dirty_last_writer_witness :
    let a7 := applyTombstoneKeepDirty id ⟨1, some (0, 5)⟩ 0 7
    let b7 := applyTombstoneKeepDirty id ⟨2, some (0, 5)⟩ 0 7
    let pa := push id 1 deadSrv a7
    let pb := push id 1 pa.1 b7
    let b8 := applyTombstoneKeepDirty id b7 1 8
    let pb2 := push id 1 pa.1 b8
    let a9 := applyTombstoneKeepDirty id pa.2.1 2 9
    pa.1.rows 1 = some ⟨1, 8, true⟩ ∧ pb.2.2 = true ∧ pb.1.counter = 8
      ∧ b8.base = some (0, 8) ∧ pb2.1.rows 1 = some ⟨2, 9, true⟩
      ∧ a9.base = some (1, 9) ∧ (push id 1 pb2.1 a9).1.counter = 9
      ∧ (applyRow id (oneRowAt (some a9.loc) a9.base 9) ⟨1, 10, 2, false⟩).loc 1 = some 2
      ∧ (applyRow id (oneRowAt (some a9.loc) a9.base 9) ⟨1, 10, 2, false⟩).shelf = []
      ∧ (push id 1 deadSrv (applyTombstone id ⟨1, some (0, 5)⟩ 7)).1.counter = 7
      ∧ (push id 1 deadSrv (applyTombstone id ⟨2, some (0, 5)⟩ 7)).1.counter = 7 := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> decide

/-- DEAD-PERIOD WITNESS (against the text's writing, widening the
dirty-at-tombstone witness: the loss is not limited to edits dirty at
the dashboard tombstone). A and B both took the tombstone at 7 cleanly
on c0, then each edited during the dead-row period, A to c1, B to c2.
A's PATCH `seq=eq.7` writes c1 into the dead row at 8; B's
`seq=eq.7` answers `[]`; B pulls the dead row at 8 and the rule writes
`(hash c2, 8)` — clean, nothing sent (the counter stays 8). The undelete
brings c1 back live at 9 and B, clean, adopts it with nothing shelved:
c2 never reached the server or any shelf. T10d's third conjunct holds
for this dirty B, which is exactly the run that loses B's edit. -/
theorem singleton_dead_period_edit_lost_witness :
    let pA := push id 1 deadSrv ⟨1, some (0, 7)⟩
    let pB := push id 1 pA.1 ⟨2, some (0, 7)⟩
    let b8 := applyTombstone id ⟨2, some (0, 7)⟩ 8
    pA.1.rows 1 = some ⟨1, 8, true⟩ ∧ pA.2.1.base = some (1, 8)
      ∧ pB.2.2 = true ∧ pB.1.counter = 8
      ∧ b8.base = some (2, 8) ∧ (push id 1 pA.1 b8).1.counter = 8
      ∧ staleOrSeen b8.base 8 = true
      ∧ (applyRow id (oneRowAt (some 2) (some (2, 8)) 8) ⟨1, 9, 1, false⟩).loc 1 = some 1
      ∧ (applyRow id (oneRowAt (some 2) (some (2, 8)) 8) ⟨1, 9, 1, false⟩).shelf = [] := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> decide

/-- STALE-TOMBSTONE WITNESS (the skip row in front of the singleton rule
is load-bearing): after A's dead-row write the baseline is `(h1, 8)`;
the stale tombstone at 7 arriving again (a re-pulled or late page) is
skipped. Without the skip row it regresses the baseline to `(h1, 7)`,
and A's next edit's PATCH `seq=eq.7` answers `[]` where the guarded
baseline's `seq=eq.8` writes the edit into the dead row. -/
theorem singleton_stale_tombstone_skipped_witness :
    let pA := push id 1 deadSrv ⟨1, some (0, 7)⟩
    pA.2.1.base = some (1, 8)
      ∧ (applyTombstone id pA.2.1 7).base = some (1, 8)
      ∧ (applyTombstoneNoSkip id pA.2.1 7).base = some (1, 7)
      ∧ (push id 1 pA.1 ⟨2, (applyTombstoneNoSkip id pA.2.1 7).base⟩).2.2 = true
      ∧ (push id 1 pA.1 ⟨2, (applyTombstoneNoSkip id pA.2.1 7).base⟩).1.counter = 8
      ∧ (push id 1 pA.1 ⟨2, (applyTombstone id pA.2.1 7).base⟩).1.rows 1
          = some ⟨2, 9, true⟩ := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩ <;> decide

/-- EDIT-BACK WITNESS (the case T10d's `v ≠ c0` excludes): the device took
the tombstone at 7 over local c5 and the user then sets the row to the
dead row's own bytes c0. The PATCH `seq=eq.7` is content-identical, the
short-circuit answers `[]`, nothing is minted, the row stays dirty and a
pull is wanted. The design closes this with the singleton pending-verify
(`sentHash` / `sentKeys`: an eligible pull that does not see the row
writes the sent hash), which `Singleton` does not model — so §7's "再无
请求" for this edit rests on a rule outside the model. -/
theorem singleton_edit_to_dead_bytes_witness :
    push id 1 deadSrv ⟨0, some (5, 7)⟩ = (deadSrv, ⟨0, some (5, 7)⟩, true) := by
  rfl

/-- The variant (`applyTombstoneShelve`) on both runs that lose under the
text's writing — nothing lost. Dirty at the dashboard tombstone: A's c1
over c0's baseline at 5 meets c0's tombstone at 7 — the echo case,
baseline `(h0, 7)`, nothing shelved, still dirty; its PATCH `seq=eq.7`
writes c1 into the dead row at 8; B, clean on c0, takes both tombstones
clean; the undelete brings c1 back and B adopts it. Dead-period edits:
A writes c1 at 8; B (c2) takes that dead row dirty — c1 shelved,
baseline `(h1, 8)`, still dirty — and its PATCH `seq=eq.8` writes c2 at
9; A, clean on c1, takes it clean and sends nothing; the undelete brings
c2 back, A adopts it, and c1 is on B's shelf. -/
theorem singleton_shelve_variant_keeps_both_witness :
    let a7 := applyTombstoneShelve id ⟨1, some (0, 5)⟩ 0 7
    let pa := push id 1 deadSrv a7.1
    let b7 := applyTombstoneShelve id ⟨0, some (0, 5)⟩ 0 7
    let b8 := applyTombstoneShelve id b7.1 1 8
    let pA := push id 1 deadSrv ⟨1, some (0, 7)⟩
    let q8 := applyTombstoneShelve id ⟨2, some (0, 7)⟩ 1 8
    let pq := push id 1 pA.1 q8.1
    let a9 := applyTombstoneShelve id pA.2.1 2 9
    a7.1.base = some (0, 7) ∧ a7.2 = [] ∧ pa.1.rows 1 = some ⟨1, 8, true⟩
      ∧ b7.1.base = some (0, 7) ∧ b8.1.base = some (0, 8) ∧ b8.2 = []
      ∧ (push id 1 pa.1 b8.1).1.counter = 8
      ∧ (applyRow id (oneRowAt (some 0) (some (0, 8)) 8) ⟨1, 9, 1, false⟩).loc 1 = some 1
      ∧ q8.1.base = some (1, 8) ∧ q8.2 = [1] ∧ pq.1.rows 1 = some ⟨2, 9, true⟩
      ∧ pq.2.1.base = some (2, 9)
      ∧ a9.1.base = some (1, 9) ∧ a9.2 = [] ∧ (push id 1 pq.1 a9.1).1.counter = 9
      ∧ (applyRow id (oneRowAt (some 1) (some (1, 9)) 9) ⟨1, 10, 2, false⟩).loc 1 = some 2
      ∧ (applyRow id (oneRowAt (some 2) (some (2, 9)) 9) ⟨1, 10, 2, false⟩).loc 1 = some 2 := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> decide

end Singleton

end Sync
end Verification
