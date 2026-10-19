# Sync ops: post-apply checks, restore and rollback (migration 015)

Operational scripts for the sync change feed (`migrations/015_sync_change_feed.sql`,
design `Docs/sync/00-realtime-sync-design.md`, survey items M1/M2 in
`Docs/sync/02-industry-survey.md`). They are not part of any deploy glob.

| File | What it does |
|---|---|
| `post_apply_checks.sql` | Read-only. PASS/FAIL per check, psql exits non-zero on any FAIL. |
| `restore_with_epoch.sql` | The last step of every restore: new epoch, `floor` = restored `sync_seq`. |
| `restore.sh` | Supabase's documented psql restore with the epoch step in the same transaction, then the post-apply checks. |
| `rollback.sql` | Turns the sync triggers off and keeps the data; `seq` gets a column default so writes without it keep working. |
| `reenable.sql` | Undoes `rollback.sql`: drops the default and reruns migration 015. Followed by the checks and the epoch step. |

## Rules

**R1. Never physically delete a synced row outside the `auth.users` cascade.**
A device that holds a baseline for a row that vanished answers its own next
edit with `[]` and concludes "same" (survey G2). So:
- an admin delete is an ordinary `DELETE` (the trigger turns it into a tombstone);
- to scrub content, `UPDATE` the content columns of the tombstoned row;
- to reset a single-row table (`user_settings`, `agent_preferences`,
  `agent_conversations`), `UPDATE` it;
- `TRUNCATE` is refused by `trg_<t>_no_truncate` (bench S16), including
  `truncate auth.users cascade`;
- the only physical delete is account erase (`delete from auth.users`), which
  reaches the tables as a cascade at trigger depth two (bench S6).

**R2. `session_replication_role = replica` is for the restore script only.**
Bench S16 measured what replica mode does to these tables: every ordinary
trigger is skipped, the TRUNCATE guard included. `TRUNCATE` empties the table,
`DELETE` is physical with no tombstone, `UPDATE` keeps the row's old `seq` (no
cursor will ever see the change), an `INSERT` without `seq` fails `NOT NULL`,
and nothing rings the doorbell. The guard's real perimeter is therefore who may
switch modes: on the local stack only the `postgres` role may, and only through
the `SET` command; `authenticated`, `anon` and `service_role` get `42501`, and
`set_config()` is refused even for `postgres`. Consequences:
- never run a data fix in replica mode; run it as `postgres` in the default
  mode so the triggers stamp `seq`, write tombstones and ring;
- never `ALTER TABLE … DISABLE TRIGGER` or `ENABLE REPLICA|ALWAYS TRIGGER` on
  these tables (`post_apply_checks.sql` P1 fails on any `tgenabled` other than `O`);
  turning the sync triggers off is `rollback.sql`'s job alone (see Rollback);
- the one sanctioned replica-mode transaction is `restore.sh`, and it ends
  with `restore_with_epoch.sql`.

**R3. Every restore ends with the epoch step, in the same transaction.**
Use `restore.sh`. If a restore ever ran without it, run
`restore_with_epoch.sql` on its own immediately and treat the window in
between as the residual risk below. On its own, run it as one transaction:

```sh
psql "$DATABASE_URL" --single-transaction -v ON_ERROR_STOP=1 -f ops/restore_with_epoch.sql
```

Outside `restore.sh` nothing locks the synced tables, so a write can take a
`seq` between the step's upsert and its guard. The guard then raises
("restore aborted") and `--single-transaction` undoes the upsert: the epoch
stays as it was, and the failure only means "rerun the step". Without
`--single-transaction` the upsert is already committed when the guard raises,
leaving a new epoch whose floor is below `sync_seq`. Bench S17d checks the
`--single-transaction` case.

**R4. Never `setval` `sync_seq` upward** to get ahead of device cursors
(survey §B.4 C3): restored rows keep their old, smaller `seq`, so the
devices' baselines stay wrong and the rewind is hidden instead of announced.

**R5. Only the `postgres` role writes `sync_epoch`.** `authenticated` and
`service_role` have SELECT only (P6). `service_role` bypasses RLS, so the
table grant is the only thing that keeps an edge function or the MCP server
from changing the epoch; never grant it more.

**R6. Run `post_apply_checks.sql` after** every apply of 015, every redeploy
that reruns the migrations, every restore, every re-enable, and every manual
data fix.

## Post-apply checks

```sh
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f post_apply_checks.sql
```

| Id | Check |
|---|---|
| P1 | On every synced table, `trg_<t>_sync_meta`, `_notify_ins`, `_notify_upd`, `_tombstone` and `_no_truncate` exist, call the right function with the right timing, and are `tgenabled = 'O'`. |
| P2 | `realtime.messages` has exactly one policy, `own sync topic` (SELECT, authenticated). |
| P3 | `notify_sync_change` is owned by `postgres`, `SECURITY DEFINER`, empty `search_path`. |
| P4 | `sync_changes` is not executable by `anon` or `PUBLIC` (a null ACL counts as PUBLIC), and is executable by `authenticated`. |
| P5 | `sync_epoch` has exactly one row; `floor` is not above `sync_seq`. |
| P6 | `sync_epoch` has RLS on, `authenticated` may only SELECT, `anon` has nothing, `service_role` cannot write (it bypasses RLS, so only the table grant stops an edge function or MCP from changing the epoch). |
| P7 | the deployed `sync_changes` body clamps `page_limit` to `max_rows` (`least(page_limit, 1000)`). Through PostgREST a higher clamp is invisible, since `max_rows` cuts the page anyway; only this check and SQL bench S10 see it. |
| P8 | `seq` is NOT NULL with no column default on every synced table. A default is what `rollback.sql` leaves; it still being there means the re-enable is not finished. |
| P9 | `sync_seq` has handed out every `seq` a synced row holds: its last value (`last_value`, or `last_value - 1` when `is_called` is false) is at or above `max(seq)` over all nine tables, every user (a cursor never passes the counter). A counter behind the rows (a `setval` downward, or rows restored without their sequence) hands those numbers out again, and the floor `restore_with_epoch.sql` takes from it lands below baselines devices hold. Repair: `setval` the counter to exactly that `max(seq)` (not above it; see the C3 note in `restore_with_epoch.sql`), then run the epoch step. |

`tests/run_all.sh` also runs a negative control per check (a mutation inside
a rolled-back transaction must turn exactly that check to FAIL).

The `max_rows` probe (survey M1b) is HTTP, not SQL; run it against the
deployment as any signed-in user who owns more rows than `max_rows`:

```sh
curl -s -D - -o /dev/null "$REST/events?select=id&limit=1500" \
  -H "apikey: $PUBLISHABLE_KEY" -H "Authorization: Bearer $USER_JWT" -H "Prefer: count=exact"
# Content-Range: 0-<rows-1>/<count>.  rows < min(1000, count) => max_rows was
# lowered below the sync_changes clamp, and a full page will read as head.
```

## Restore

The epoch row is how a device learns that the server was rewound (survey M2).
Clients read it with a plain `GET /rest/v1/sync_epoch?select=epoch,floor`.

Into a new, empty project (Supabase's three-file restore):

```sh
ops/restore.sh --target "$DATABASE_URL" --roles roles.sql --schema schema.sql --data data.sql
```

Into the existing project (empties the synced tables and `sync_epoch` first,
inside the same transaction):

```sh
ops/restore.sh --target "$DATABASE_URL" --data data.sql --replace
```

Either way one `psql --single-transaction` runs roles, schema,
`SET session_replication_role = replica`, the optional emptying, `data.sql`
and `restore_with_epoch.sql`, so the restored rows and the new epoch land
together or not at all. `restore_with_epoch.sql` ends with its own guard: if
`sync_epoch` does not hold exactly one row, with the floor the sequence
implies (`last_value`, or `last_value - 1` for a sequence that was never
called) and an epoch different from the one in place before the step, it
raises, and the whole restore rolls back. Bench S17 measured on the local stack: the epoch
changes, `floor` equals the dump's `sync_seq` value, the restored rows keep
their dump-time content and `seq`, and the restore rings no doorbell, so the
epoch is the only signal a device gets. S17d covers what the dumps do not
reach: a never-called sequence gives the floor one below `last_value`, a copy
of the script that keeps the old epoch is refused by the guard, and a copy
that takes a `seq` between its upsert and its guard, run on its own under
`--single-transaction`, aborts with the epoch left as it was.

### Residual risk: a restore without the epoch step

Bench S17b restored a dump with the documented psql command alone. The epoch
and floor stayed exactly as they were while the data and `sync_seq` went back.
What a device can and cannot see afterwards:

| Observation | Detectable? |
|---|---|
| `GET sync_epoch` returns the pre-restore value | no |
| a pull from the device's cursor returns an empty page, the same as being at head | no |
| editing a row created after the dump: `PATCH ?id=eq.X&seq=eq.<base>` returns `200 []`, the same as a stale or identical write; pending-verify then concludes "same" and the edit exists only on that device (survey G1 scene 1) | no |
| editing a row changed after the dump: also `200 []`; the server holds the dump-time version | no |
| another device's new write takes a `seq` at or below this device's cursor, so this device's pulls skip it; the same number can now name two different row versions | only by a write-response check (survey L10, not built) |
| a pull from 0 shows the post-dump rows missing | only by a full audit (`sync.audit`) |

Bench S17c restored an older dump (taken before an earlier scripted restore)
without the epoch step: the old dump's epoch row came back, so a device does
see "changed", but with that dump's stale floor, below the restored range.
Every baseline entry above a floor becomes `?`, and where the device's
version differs from the incoming row the device's version wins, even on a
clean device (design §6.6). With a stale floor that catches
entries inside the restored range too: a device that missed an edit made
before the dump pushes its older version over it on every device (design
§6.6, counter-example (2)); the overwritten version is only in that device's
shelf. R3 is the only protection.

The two residuals that remain are design §9.37. In both, the affected device
entries sit **at or below** the floor, so they keep their hash and take the
normal three-way compare with skip off: a clean device adopts the restored
row. That is the opposite side of the floor from the stale-floor case above:
only entries above the floor become `?`, where a clean device's version wins.

- **The epoch step run late, after a restore that bypassed the script.**
  Running `restore_with_epoch.sql` once the omission is noticed is a partial
  repair. Its floor is the sequence value at that later moment, so writes made
  between the restore and the step took numbers that repeat numbers handed
  out before the restore. A device entry in (N0, late floor] that names a
  version written after the dump is then at or below the floor: a clean
  device adopts the restored older row, and that version is lost. Run the
  step as soon as possible anyway; every write after it is above the floor.
- **Writes committed while the export ran**, even through `restore.sh`.
  `pg_dump` reads `sync_seq` outside the export's snapshot, so such a write
  has a number at or below N0 but is not in `data.sql`. A device that already
  pulled it holds an entry at or below the floor, and a clean one adopts the
  dump's version; that version is lost. The window is the export's duration.

Both are backstopped only by the rules here (R3) and by the write-response
check L10, which is not built.

## Rollback

Design §7 handoff (8). A rollback is not a rewind: the server keeps every row,
tombstone and `seq`. Use it when the post-launch audit is not zero.

1. Turn the clients' sync switch off.
2. Roll back:

   ```sh
   psql "$DATABASE_URL" --single-transaction -v ON_ERROR_STOP=1 -f ops/rollback.sql
   ```

   On each synced table it first gives `seq` the column default
   `nextval('public.sync_seq')`, then drops `trg_<t>_sync_meta`,
   `trg_<t>_notify_ins`, `trg_<t>_notify_upd` and `trg_<t>_tombstone`. The
   TRUNCATE guard, `sync_seq`, `sync_epoch`, `sync_changes` and the realtime
   policy stay. The default is not optional: `seq` is NOT NULL, and NOT NULL
   is checked before `ON CONFLICT` is resolved, so with the triggers gone and
   no default every write that leaves `seq` out fails `23502` (the king
   build's upload and MCP included), even an upsert that hits an existing row.
   The file ends with its own check and raises unless every table is in that
   shape. From here on `post_apply_checks.sql` fails P1 and P8; that is the
   rollback, not a fault.

While rolled back:

| Write | Effect |
|---|---|
| upsert of a new row (king shape, no `seq`) | `201`; `seq` comes from the default |
| upsert hitting an existing row, or a `PATCH` (agent, MCP as `service_role`) | succeeds; the row keeps its old `seq`, so no cursor will see the change |
| `DELETE` | physical; no tombstone |
| any write | no doorbell |
| `TRUNCATE` | still refused |

3. Re-enable, in this order:

   ```sh
   psql "$DATABASE_URL" --single-transaction -v ON_ERROR_STOP=1 -f ops/reenable.sql   # drops the default, reruns 015
   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f ops/post_apply_checks.sql              # all PASS, P1 and P8 included
   psql "$DATABASE_URL" --single-transaction -v ON_ERROR_STOP=1 -f ops/restore_with_epoch.sql   # the reset
   ```

   Writes may already be arriving during the reset (the switch is still off,
   but the king build, MCP and edge functions are not). If the epoch step
   fails with "restore aborted", a write landed inside it; under
   `--single-transaction` nothing was applied, so rerun the step (R3).

   then turn the switch back on. `reenable.sql` includes
   `../migrations/015_sync_change_feed.sql` relative to itself, so run it from
   a checkout. Rerunning 015 keeps the data and the epoch row.

The epoch step is the reset, and it is not optional. It gives every device a
new epoch with floor = the current `sync_seq` value, so every baseline a
device holds is at or below the floor and takes the normal three-way compare
with skip off (design §6.6): a clean device adopts an edit made during the
rollback, which kept its old `seq` and which a cursor would never reach, and
a row physically deleted during the rollback is never seen at head, becomes
`?` and is POSTed back (it comes back; nothing is lost). Without the step,
devices keep their cursors and miss every in-place edit from the window.

Bench S18 (`tests/sync_restore_drill.sh`) rehearses the whole path on the
local stack: the counterfactual without a default (`23502` for an insert and
for an upsert hitting an existing row), the script's own guard, the rollback,
a king-shaped upsert, a trigger-less `service_role` PATCH and a physical
DELETE, `reenable.sql`, the post-apply checks, and the epoch step; then it
POSTs the deleted row back and checks that it lands above the floor and rings.
"Keeps the data" is checked by content, not by row count: before the rollback
the fixture holds a tombstone made through REST on every synced table and a
live row the window never writes, and an md5 over every row's full JSON, per
synced table (rows keyed by `user_id` included), must be equal right after
`rollback.sql`, and again for every row outside the window after
`reenable.sql`. The rows the window wrote are compared across `reenable.sql`
on their own: the upsert and the PATCH keep their content and old `seq`, the
inserted rows keep the `seq` the default gave them, and the deleted row stays
gone until the device POSTs it back. Every checksum must be an md5 before it
is compared, so a checksum query that errors fails the check instead of
comparing two empty strings. `rollback.sql` and `reenable.sql` must each
leave `sync_seq` (`last_value` and `is_called`) exactly where it was, and the
reset's floor must be at or above `max(seq)` over every synced table; the
window's last insert lands on `event_types`, above every `events` row, so a
counter or floor read from `events` alone falls short of it.
