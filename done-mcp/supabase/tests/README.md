# Sync change feed bench (migration 015 v6)

Re-runnable checks for `migrations/015_sync_change_feed.sql` against a local
stack. They are not part of any deploy glob; nothing here runs in CI or on
the hosted project. Check ids (S1 … S26) match the bench spec in gh#257 and
the survey (`Docs/sync/02-industry-survey.md` §E.3); S17 is the restore
drill, S18 the rollback rehearsal of design §7 handoff (8) and §8.3, S19–S26
the v6 additions (the write gate, the version log, `is_ancestor`, the pruner,
the rerun of 015, the client-visible shapes, dead rows); R1–R22 are the
offline checks of `ops/restore.sh`'s dump parser. The post-apply checks
(P1 … P12) live in `../ops/` because they also run after every deploy.

## Prerequisites

- `supabase start` from `done-mcp/` with migrations 001–015 applied (to
  reapply a changed 015: `psql … -f migrations/015_sync_change_feed.sql`;
  it is idempotent and keeps the epoch row and its ledger).
- `psql` and `pg_dump` (the scripts fall back to `/opt/homebrew/opt/libpq/bin/`
  when they are not on `PATH`, or set `PSQL=` / `PG_DUMP=`).
- `node` with a global `WebSocket` (Node 22 or newer) and `python3`, for the
  HTTP script.
- The stack's secret key (the `service_role` caller) for S18, S19 and the v6
  controls: set `SUPABASE_SECRET_KEY`, or have the `supabase` CLI on `PATH`;
  the scripts then read it from `supabase status -o env` in `done-mcp/`.
- Never point these at the hosted project: the scripts create and erase
  users in `auth.users`, read `realtime.messages` directly, flip
  `sync_epoch.paused`, prune the version log, roll the triggers back and
  rewind whole tables. `run_all.sh`, the drill and the controls refuse a
  non-local `SUPABASE_DB`.

## Run

```sh
cd done-mcp/supabase/tests
./run_all.sh          # everything below, in this order, with a summary
```

or one part at a time:

```sh
# SQL side: advisory-lock ordering, tombstones, doorbell counts, account erase,
# the EXPLAIN of the events arm and the page clamp, service_role delete, the
# lock-order deadlock, the TRUNCATE guard and its replica-mode variant (S16),
# the write gate and trigger order (S20), the version log (S21), is_ancestor
# (S22), the pruner (S23), a rerun of 015 (S24).
psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -f sync_feed_checks.sql

# HTTP side: GoTrue signup, PostgREST shapes (current client and design),
# sync_changes RPC, the max_rows cut and the client head rule (S10b),
# Realtime private-channel doorbell over a raw websocket, the write gate
# through real request headers (S19), the epoch GET / is_ancestor RPC / the
# version columns as a client sees them (S25). BENCH_ONLY=v6 runs S19 and S25
# alone.
./sync_feed_checks.sh

# S17 restore drill: pg_dump, more writes, restore as Supabase documents it,
# with ops/restore.sh (epoch, ledger, counter never rewound, version log kept,
# paused), a bypassing restore and its immediate repair, the step's guard and
# its lock, restore.sh's refusals; S18 rollback rehearsal: ops/rollback.sql
# (W=0), the gate in the window, the stamp trigger, ops/reenable.sql with its
# epoch step, the post-apply checks, the device's re-upload with parent;
# S17n the "new project without the two tables" residual (P10, P12 red).
./sync_restore_drill.sh

# post-apply checks (P1–P12); run_all.sh adds a negative control per check
psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 -f ../ops/post_apply_checks.sql

# the restore parser, offline (R1–R22): synthetic dump shapes plus the real
# supabase CLI exports, each fed to ops/restore.sh with --target at a closed
# port; a shape that passes ends in "connection refused" without touching
# any database, a refusal is rc=3 with the expected reason. R19–R22 need the
# CLI and the stack (INVALID otherwise).
./sync_restore_parser_checks.sh

# v6 negative controls: one mutation per new check (a function line removed,
# a trigger dropped or renamed, an ops script edited in a copy), the bench
# part rerun and the named check expected red, then restored and rerun green.
# Three-valued: PASS / FAIL / INVALID (mutation did not apply, no verdict
# line, or the restore did not come back green). LOG_DIR= keeps the logs.
./sync_v6_controls.sh
```

Each prints `PASS`/`FAIL` per check with the observed values and exits
non-zero when any check failed (psql exits 3 through a raised exception at
the end; the shell scripts exit 1).

Environment overrides: `SUPABASE_REST`, `SUPABASE_AUTH`, `SUPABASE_WS`,
`SUPABASE_PUBLISHABLE_KEY`, `SUPABASE_SECRET_KEY`, `SUPABASE_DB`, `PSQL`, `PG_DUMP`,
`BENCH_EMAIL_A`, `BENCH_EMAIL_B`, `BENCH_EMAIL_R`, `BENCH_ALLOW_REWIND`,
`BENCH_ONLY`, `RUN_V6_CONTROLS`, `LOG_DIR`.

## Telemetry chassis bench (migration 016, gh#273)

`telemetry_checks.sql` (T1 … T28) checks `migrations/016_spike_runs_telemetry.sql`:
the rerun, the revision guard, RLS as user U / V / anon, the absence of 015's
triggers, `key_registry` against `../telemetry/key_registry.json`, `counter_long`'s
0-vs-NULL rule and the eight views. `run_checks.sh` is its runner for a machine
without a host psql: `supabase start` if needed, `supabase db reset --local`,
`../telemetry/key_registry_load.sql`, then `sync_feed_checks.sql` (015 must stay
green) and `telemetry_checks.sql`, with psql running inside the `supabase_db_*`
container over the container's own address (dblink needs scram, not the trusted
socket). `RESET=0` reuses the database, `SKIP_SYNC=1` skips the 015 bench,
`LOG_DIR=` keeps the psql outputs. Local stack only, like everything here.
The registry rows are never hand-written: edit `../telemetry/key_registry.json`,
run `python3 -I ../telemetry/gen_key_registry_sql.py`, and the runner refuses a
stale `key_registry_load.sql`. The T-checks create and erase `tele-u@` /
`tele-v@local.test` in `auth.users`; T1 reruns 016 twice (`\ir`).
T27 replays the `server.apply` / `server.fold` fixtures of
`verification/telemetry-fixtures.json` (the Lean model's file) against the
trigger; the runner also runs QA's `telemetry_wire_conformance.sql`
(`fixtures/wire_rows.json`) when it is present.

## What they touch

- SQL script: creates throwaway users `bench-u@`, `bench-v@`, `bench-w@local.test`
  directly in `auth.users`, works only under those ids, and erases them at the
  end through the `auth.users` cascade (which is itself the S6 check, now
  including the users' version-log rows). The second and third sessions are
  `dblink` connections the server opens back to itself over its own address;
  the loopback address is trust-authenticated and `dblink` refuses that for a
  non-superuser. Every S16 TRUNCATE and every replica-mode statement runs
  inside a subtransaction that is rolled back. S20 flips `sync_epoch.paused`
  / `rollback` and puts them back; S22 builds a 1,101-version chain on one
  row; S23 runs `sync_versions_prune(0)`, which removes every orphan version
  on the stack; S24 reruns 015 (`\ir ../migrations/015_sync_change_feed.sql`).
- Shell script: signs up `bench-a@` / `bench-b@local.test` through GoTrue
  (and `bench-c@` for S26's dead rows, so the single-row tables are empty),
  works only under those ids, and erases them at the end. S10b creates and
  drops a throwaway function `public.bench_max_rows_probe`. S19 flips
  `paused` / `rollback` and puts them back.
- S24 ends with a rerun of 015 (`\ir ../migrations/015_sync_change_feed.sql`).
  That rerun also **restores every trigger function the run may have
  mutated**: a mutation of `set_sync_meta`, `sync_gate`, `is_ancestor` or the
  pruner applied before the SQL bench is gone once S24 has run. The v6
  controls' verdict reads the FAIL lines S20–S23 print before S24, so it
  stands; a probe that runs after the bench sees the original functions.
- Restore drill: signs up `bench-r@local.test`. A restore rewinds the whole
  synced tables, so the drill refuses to start when another user owns rows
  there (`BENCH_ALLOW_REWIND=1` overrides on a throwaway stack). Every epoch
  step it runs ends with `paused = true`; the drill clears it where an
  operator would. S18 runs `ops/rollback.sql` for real (the whole database,
  not one user, with `W=0`); if the drill stops before the re-enable passes
  its checks, its exit trap runs `ops/reenable.sql`. S17n empties
  `sync_versions` and resets the epoch row to emulate a new project, then
  reruns 015 and the epoch step to leave the stack in shape: afterwards the
  ledger holds that one record and every log row has `parent null`.
- v6 controls: replace trigger functions and drop / rename triggers on the
  live stack, then rerun 015 to restore them; the drill controls run against
  a temporary copy of `tests/`, `ops/` and `migrations/`. One control edits
  `migrations/015_sync_change_feed.sql` in place (the backfill line) and
  copies the original back; the log dir keeps `015.original.sql`.
- All delete their own `realtime.messages` rows when the role is allowed to;
  otherwise the daily partition drop cleans them.

Some checks record behaviour rather than assert a design property (the claim
says "recorded" or "residual"); they still assert the observed value, so a
change in behaviour turns them red. S13's first check is a documented
expectation: the pre-existing client sends `rules: null`, which the
`agent_preferences` NOT NULL constraint refuses with 400 / 23502; it is not
caused by 015.

## A fresh database

`supabase db reset` rebuilds the database from the migrations: a new epoch
with an **empty** ledger and an empty version log. P10 is red on such a
database until the epoch step runs once (`ops/README.md` "First apply"); the
drill does that as part of S17, so `run_all.sh` ends green on a fresh stack.
The reset also empties `auth.users`, so a simulator that synced against the
stack before must sign in again.

## Recorded facts about ids

Two facts the client relies on, each with the check that proves it
(`sync_feed_checks.sh`, section S9):

- **PostgREST renders uuid ids lowercase.** Postgres stores a `uuid` column
  as a value, not as the string that was sent, so an uppercase id (Swift's
  `uuidString`) is accepted, and every response renders it lowercase: the
  write response, a `GET` filtered by the uppercase form (a uuid filter
  matches either case), and the `data` of `sync_changes`. A client that
  compares a server id with its own id string must compare case-insensitively
  or lowercase both. Check: S9 "uuid ids: an uppercase id is accepted, and
  PostgREST renders it lowercase …". The same section records the other side:
  a `text` id such as an occurrence key (`single|<UUID>`) keeps the case it
  was sent in, while its uuid `event_id` comes back lowercase (S9 "recorded:
  a text occurrence-key id keeps the case it was sent in …").
- **Occurrence-key ids containing `|` and the word `none` are accepted raw
  and encoded.** `event_logs` rows with ids `single|<uuid>` and
  `seriesOccurrence|<uuid>|none|<yyyymmdd>` are stored exactly as sent, and
  each filter form returns exactly the rows it names: `id=in.(…)` raw,
  percent-encoded and double-quoted, and `id=eq.…` raw and percent-encoded.
  A tombstone `PATCH ?id=in.(…)&deleted_at=is.null` with the raw ids stamps
  both rows. Checks: S9 "event_logs rows whose occurrence-key ids contain
  pipes and the word none are stored as sent", the "… -> exactly the
  named rows" lines, and "event_logs tombstone PATCH with raw pipe ids".

## Recorded facts about versions (v6)

- `is_ancestor(tbl, id, a, b)` takes the id as **text** (occurrence keys are
  text; the single-row tables are keyed by `user_id`); a uuid id is passed as
  its string. `a = b` answers true. Another user's version answers null
  through RLS (S22).
- A merge-duplicates upsert that hits an existing row logs exactly one
  version: the BEFORE INSERT trigger runs on a row that never lands, so the
  log row is written by an AFTER ROW trigger (S21).
- `is_ancestor` lowercases the table name and matches a uuid id in either
  case; a text occurrence key is matched exactly as sent (S22 "case").
- A dead row (only key, `deleted_at`, `parent_version_id`; `events` plus
  `kind`) is a `201` on every synced table: the content columns take the
  tombstone defaults 015 sets (S26).
- Inside a rollback window a rerun of 015 is refused by its guard and
  changes nothing (S18); `reenable.sql` clears the bit first.
- A client that echoes `version_id` / `parent_version_id` back in an
  otherwise identical upsert still gets a no-op (S21): the version columns
  are excluded from the content comparison.
