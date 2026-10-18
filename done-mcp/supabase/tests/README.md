# Sync change feed bench (migration 015)

Re-runnable checks for `migrations/015_sync_change_feed.sql` against a local
stack. They are not part of any deploy glob; nothing here runs in CI or on
the hosted project. Check ids (S1 … S17) match the bench spec in gh#257 and
the survey (`Docs/sync/02-industry-survey.md` §E.3). The post-apply checks
(P1 … P7) live in `../ops/` because they also run after every deploy.

## Prerequisites

- `supabase start` from `done-mcp/` with migrations 001–015 applied (to
  reapply a changed 015: `psql … -f migrations/015_sync_change_feed.sql`;
  it is idempotent and keeps the epoch row).
- `psql` and `pg_dump` (the scripts fall back to `/opt/homebrew/opt/libpq/bin/`
  when they are not on `PATH`, or set `PSQL=` / `PG_DUMP=`).
- `node` with a global `WebSocket` (Node 22 or newer) and `python3`, for the
  HTTP script.
- Never point these at the hosted project: the scripts create and erase
  users in `auth.users`, read `realtime.messages` directly, and the restore
  drill rewinds whole tables. `run_all.sh` and the drill refuse a
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
# lock-order deadlock, the TRUNCATE guard and its replica-mode variant (S16).
psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -f sync_feed_checks.sql

# HTTP side: GoTrue signup, PostgREST shapes (current client and design),
# sync_changes RPC, the max_rows cut and the client head rule (S10b; the
# server clamp itself shows only in SQL S10 and P7, since max_rows hides it),
# Realtime private-channel doorbell over a raw websocket.
./sync_feed_checks.sh

# S17 restore drill: pg_dump, more writes, restore as Supabase documents it,
# with and without ops/restore_with_epoch.sql.
./sync_restore_drill.sh

# post-apply checks (P1–P7); run_all.sh adds a negative control per check
psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 -f ../ops/post_apply_checks.sql
```

Each prints `PASS`/`FAIL` per check with the observed values and exits
non-zero when any check failed (psql exits 3 through a raised exception at
the end; the shell scripts exit 1).

Environment overrides: `SUPABASE_REST`, `SUPABASE_AUTH`, `SUPABASE_WS`,
`SUPABASE_PUBLISHABLE_KEY`, `SUPABASE_DB`, `PSQL`, `PG_DUMP`,
`BENCH_EMAIL_A`, `BENCH_EMAIL_B`, `BENCH_EMAIL_R`, `BENCH_ALLOW_REWIND`.

## What they touch

- SQL script: creates throwaway users `bench-u@`, `bench-v@`, `bench-w@local.test`
  directly in `auth.users`, works only under those ids, and erases them at the
  end through the `auth.users` cascade (which is itself the S6 check). The
  second and third sessions are `dblink` connections the server opens back to
  itself over its own address; the loopback address is trust-authenticated and
  `dblink` refuses that for a non-superuser. Every S16 TRUNCATE and every
  replica-mode statement runs inside a subtransaction that is rolled back.
- Shell script: signs up `bench-a@` / `bench-b@local.test` through GoTrue,
  works only under those ids, and erases them at the end. S10b creates and
  drops a throwaway function `public.bench_max_rows_probe`.
- Restore drill: signs up `bench-r@local.test`. A restore rewinds the whole
  synced tables, `sync_seq` and `sync_epoch`, so the drill refuses to start
  when another user owns rows there (`BENCH_ALLOW_REWIND=1` overrides on a
  throwaway stack). It ends by running `restore_with_epoch.sql`, so a device
  that synced against the stack during the drill sees a new epoch.
- All delete their own `realtime.messages` rows when the role is allowed to;
  otherwise the daily partition drop cleans them.

Some checks record behaviour rather than assert a design property (the claim
says "recorded" or "residual"); they still assert the observed value, so a
change in behaviour turns them red. S13's first check is a documented
expectation: the pre-existing client sends `rules: null`, which the
`agent_preferences` NOT NULL constraint refuses with 400 / 23502; it is not
caused by 015.
