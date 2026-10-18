# Sync ops: post-apply checks and restore (migration 015)

Operational scripts for the sync change feed (`migrations/015_sync_change_feed.sql`,
design `Docs/sync/00-realtime-sync-design.md`, survey items M1/M2 in
`Docs/sync/02-industry-survey.md`). They are not part of any deploy glob.

| File | What it does |
|---|---|
| `post_apply_checks.sql` | Read-only. PASS/FAIL per check, psql exits non-zero on any FAIL. |
| `restore_with_epoch.sql` | The last step of every restore: new epoch, `floor` = restored `sync_seq`. |
| `restore.sh` | Supabase's documented psql restore with the epoch step in the same transaction, then the post-apply checks. |

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
- the one sanctioned replica-mode transaction is `restore.sh`, and it ends
  with `restore_with_epoch.sql`.

**R3. Every restore ends with the epoch step, in the same transaction.**
Use `restore.sh`. If a restore ever ran without it, run
`restore_with_epoch.sql` on its own immediately and treat the window in
between as the residual risk below.

**R4. Never `setval` `sync_seq` upward** to get ahead of device cursors
(survey §B.4 C3): restored rows keep their old, smaller `seq`, so the
devices' baselines stay wrong and the rewind is hidden instead of announced.

**R5. Only the `postgres` role writes `sync_epoch`.** `authenticated` and
`service_role` have SELECT only (P6). `service_role` bypasses RLS, so the
table grant is the only thing that keeps an edge function or the MCP server
from changing the epoch; never grant it more.

**R6. Run `post_apply_checks.sql` after** every apply of 015, every redeploy
that reruns the migrations, every restore, and every manual data fix.

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
epoch is the only signal a device gets. S17d covers the two branches the
dumps do not reach: a never-called sequence gives the floor one below
`last_value`, and a copy of the script that keeps the old epoch is refused
by the guard.

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
see "changed", but with that dump's stale floor. A stale floor puts restored
rows in the "written after the restore" segment, where a clean device adopts
the restored version, which reverts edits that exist nowhere else. R3 is the
only protection. Running `restore_with_epoch.sql` as soon as the omission is
noticed gives every device a new epoch and a floor at or above the restored
range; writes made in between then fall at or below the floor and are treated
as restored content, which is the conservative side (local wins, the incoming
version goes to the shelf).
