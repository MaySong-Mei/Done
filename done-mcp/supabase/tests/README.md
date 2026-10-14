# Sync change feed bench (migration 015)

Re-runnable checks for `migrations/015_sync_change_feed.sql` against a local
stack. They are not part of any deploy glob; nothing here runs in CI or on
the hosted project. Check ids (S1 … S15) match the bench spec in gh#257.

## Prerequisites

- `supabase start` from `done-mcp/` with migrations 001–015 applied.
- `psql` (PostgreSQL 17 client; the scripts fall back to
  `/opt/homebrew/opt/libpq/bin/psql` when it is not on `PATH`, or set `PSQL=`).
- `node` with a global `WebSocket` (Node 22 or newer) and `python3`, for the
  HTTP script.
- Never point these at the hosted project: both scripts create and erase
  users in `auth.users` and read `realtime.messages` directly.

## Run

```sh
cd done-mcp/supabase/tests

# SQL side: advisory-lock ordering, tombstones, doorbell counts, account erase,
# the EXPLAIN of the events arm, service_role delete, the lock-order deadlock.
psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -f sync_feed_checks.sql

# HTTP side: GoTrue signup, PostgREST shapes (current client and design),
# sync_changes RPC, Realtime private-channel doorbell over a raw websocket.
./sync_feed_checks.sh
```

Each prints `PASS`/`FAIL` per check with the observed values and exits
non-zero when any check failed (psql exits 3 through a raised exception at
the end; the shell script exits 1).

Environment overrides for the shell script: `SUPABASE_REST`, `SUPABASE_AUTH`,
`SUPABASE_WS`, `SUPABASE_PUBLISHABLE_KEY`, `SUPABASE_DB`, `PSQL`,
`BENCH_EMAIL_A`, `BENCH_EMAIL_B`.

## What they touch

- SQL script: creates throwaway users `bench-u@`, `bench-v@`, `bench-w@local.test`
  directly in `auth.users`, works only under those ids, and erases them at the
  end through the `auth.users` cascade (which is itself the S6 check). The
  second and third sessions are `dblink` connections the server opens back to
  itself over its own address; the loopback address is trust-authenticated and
  `dblink` refuses that for a non-superuser.
- Shell script: signs up `bench-a@` / `bench-b@local.test` through GoTrue,
  works only under those ids, and erases them at the end.
- Both delete their own `realtime.messages` rows when the role is allowed to;
  otherwise the daily partition drop cleans them.

Some checks record behaviour rather than assert it (the observed string says
so); read the output, not only the exit code.
