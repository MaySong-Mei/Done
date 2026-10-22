# Sync ops: post-apply checks, restore and rollback (migration 015 v6)

Operational scripts for the sync change feed (`migrations/015_sync_change_feed.sql`,
design `Docs/sync/00-realtime-sync-design.md` §5 items 7 / 9 / 10, the ops
rules, §6.6 and §7 handoff (4) (6) (8)). They are not part of any deploy
glob.

| File | What it does |
|---|---|
| `post_apply_checks.sql` | Read-only. PASS/FAIL per check (P1 … P12), psql exits non-zero on any FAIL. |
| `restore_with_epoch.sql` | The **epoch step**: locks the nine tables, lifts `sync_seq` to the highest kept `seq` (never lowers it), new epoch, one ledger record `{epoch, kept_max, dump_epoch}`, `paused := true`, `rollback := false`, then its guard. No arguments. |
| `restore.sh` | Supabase's documented psql restore with the epoch step in the same transaction. Strips the dump's `sync_seq` setval and its `sync_versions` / `sync_epoch` blocks, carries the live ledger and version log over, then runs the post-apply checks. |
| `rollback.sql` | Pauses the server (the write gate enforces it), waits W, then drops the sync triggers and keeps the data; `seq` gets a column default and a stamp trigger so writes in the window keep taking new numbers. |
| `reenable.sql` | Undoes `rollback.sql`: drops the default and the stamp trigger, reruns migration 015, runs the epoch step. Followed by the checks and `paused := false`. |

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
trigger is skipped, the TRUNCATE guard and the write gate included. `TRUNCATE`
empties the table, `DELETE` is physical with no tombstone, `UPDATE` keeps the
row's old `seq` and `version_id` (no cursor will ever see the change, no log
row), an `INSERT` without `seq` fails `NOT NULL`, and nothing rings the
doorbell. The guard's real perimeter is therefore who may switch modes: on the
local stack only the `postgres` role may, and only through the `SET` command;
`authenticated`, `anon` and `service_role` get `42501`, and `set_config()` is
refused even for `postgres`. Consequences:
- never run a data fix in replica mode; run it as `postgres` in the default
  mode so the triggers stamp `seq`, write tombstones, log versions and ring;
- never `ALTER TABLE … DISABLE TRIGGER` or `ENABLE REPLICA|ALWAYS TRIGGER` on
  these tables (`post_apply_checks.sql` P1 fails on any `tgenabled` other than `O`);
  turning the sync triggers off is `rollback.sql`'s job alone (see Rollback),
  and even it keeps the write gate and the TRUNCATE guard;
- the one sanctioned replica-mode transaction is `restore.sh`, and it ends
  with `restore_with_epoch.sql`;
- only the `postgres` role writes `sync_epoch` and runs the epoch step.
  `authenticated` and `service_role` have SELECT only (P6). `service_role`
  bypasses RLS, so the table grant is the only thing that keeps an edge
  function or the MCP server from changing the epoch; never grant it more.

**R3. Every restore ends with the epoch step, in the same transaction.**
Use `restore.sh`. If a restore ever bypassed it, or a restore stopped
half-way, then **immediately**: first `update public.sync_epoch set paused =
true`, then run the epoch step on its own:

```sh
psql "$DATABASE_URL" -c "update public.sync_epoch set paused = true"
psql "$DATABASE_URL" --single-transaction -v ON_ERROR_STOP=1 -f ops/restore_with_epoch.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f ops/post_apply_checks.sql
psql "$DATABASE_URL" -c "update public.sync_epoch set paused = false"
```

The step takes no arguments (there is no `--last-seq` any more: the device no
longer computes which numbers were lost; it asks the ledger and the version
log, design v1.6). On its own it locks the nine tables in SHARE ROW EXCLUSIVE
mode before it reads `kept_max`, so no write can take a number between the
reading and the commit (bench S17d measures the no-lock variant: a racing
writer's number then lands above `kept_max` and the ledger calls it kept).
Its guard raises when the row is not exactly what it wrote (one row, new
epoch, ledger ends with it, paused, counter at or above `kept_max`), and
`--single-transaction` undoes the step. The window between the bypassing
restore and the step is the residual risk (2) below.

**R4. Never `setval` `sync_seq` on your own.** Only the epoch step moves the
counter, together with its ledger record, and only upward (to `max(live
counter, kept_max)`). A counter lifted without a ledger record hides a rewind
instead of announcing it (survey §B.4 C3).

**R5. Everyday recovery is not a whole-database restore.** To get rows back
(a user deleted the wrong thing, a bad data fix), restore the export into a
**temporary project**, read the rows you want there, and copy them into the
live project as ordinary writes (INSERT / UPDATE as `postgres` in the default
mode): they take new seqs, new versions, pass the triggers and ring. The
whole-database `restore.sh --replace` is for disasters only.

**R6. The export is this command, and only this command.**

```sh
pg_dump --data-only \
  -t public.events -t public.event_logs -t public.event_feedback -t public.todo_lists \
  -t public.event_types -t public.skill_insights -t public.user_settings \
  -t public.agent_preferences -t public.agent_conversations \
  -t public.sync_seq -t public.sync_epoch -t public.sync_versions \
  --dbname "$DATABASE_URL" -f data.sql
```

The nightly export (D3; the Free plan has no platform backups, so this is the
only backup) is exactly that: COPY format, the nine synced tables, the
counter, the epoch row and the version log, nothing else. `restore.sh`
accepts quoted or unquoted identifiers and refuses everything else before it
connects (bench R1–R22): an INSERT-format dump ("only COPY format is
accepted"), data blocks outside `public` ("a whole-database export"), public
tables outside the synced set ("would collide with the live rows"), not
exactly one `sync_seq` setval / `sync_versions` block / `sync_epoch` row.
The Supabase CLI was tested and is **not** a substitute: `supabase db dump
--data-only` writes INSERT statements, `--use-copy` dumps every schema
(`auth.*` included, so `--replace` would collide with the live users), and
`--use-copy -s public` dumps every public table (`api_keys`, `snapshots`,
`ai_*`, `oauth_*`, …), which `--replace` would also collide with. The CLI has
no `-t`; use `pg_dump`.

A restore into a **new project** copies `sync_epoch` and `sync_versions` from
the old project first (they are not taken from the dump: the live ledger and
the live log are the evidence devices ask for). The nightly task also runs
the retention:

```sql
select public.sync_versions_prune(90);   -- as service_role or postgres; returns rows removed
```

It deletes log rows older than 90 days and never a version a synced row
(tombstones included) currently holds (P12). No pg_cron is installed.

**R7. Run `post_apply_checks.sql` after** every apply of 015, every redeploy
that reruns the migrations, every restore, every re-enable, and every manual
data fix.

## Staging

| | |
|---|---|
| Project | `done-staging`, ref **`gpxpvczmrezgzycypmsk`**, `https://gpxpvczmrezgzycypmsk.supabase.co`, region ap-northeast-2, org `done` (same org as production) |
| Production | `uqnvtzblppjblwgbpqhf` — nothing goes there first |
| Pipeline | `.github/workflows/supabase-staging.yml` |
| App | the `Done Staging` scheme / Staging build configuration (points `SupabaseSyncConfig` at the staging URL and its publishable key) |

**The rule: every migration and every edge function lands on staging first,
and goes to production only after staging is green** — the migration loop,
the epoch step where the README calls for one, `post_apply_checks.sql` all
PASS, the HTTP half, and the app on the `Done Staging` scheme exercising the
change. The staging database holds test accounts only; there is nothing to
preserve, so a wrong migration costs a redeploy, not a restore.

### Deploying to staging

**Pipeline.** `supabase-staging.yml` is the production workflow
(`supabase.yml`) with `PROJECT_ID: gpxpvczmrezgzycypmsk`: the same migration
loop through the Management API (every file, every run; a file that cannot
be reapplied prints `Skipped (already applied)`), then `supabase functions
deploy` of `api`, `mcp`, `oauth`, `snapshot` with `--no-verify-jwt`. It runs
on a push to the **`staging`** branch that touches
`done-mcp/supabase/migrations/**` or `done-mcp/supabase/functions/**`, and on
`workflow_dispatch`. Same `SBACCESSTOKEN` repository secret. Mind that
`curl -sf … || echo "Skipped"` also hides a real error (a syntax error, a
guard that raised): when a file is new, read the result by hand (below).

**By hand** (there is no psql on the laptop; the Management API runs each
file as the `postgres` role, and a multi-statement body is one implicit
transaction, so a file lands whole or not at all):

```sh
export SUPABASE_ACCESS_TOKEN=…     # a personal access token: never commit it, never echo it
REF=gpxpvczmrezgzycypmsk
for f in done-mcp/supabase/migrations/*.sql; do
  echo "== $f"
  curl -s -X POST "https://api.supabase.com/v1/projects/$REF/database/query" \
    -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" -H "Content-Type: application/json" \
    -d "$(jq -n --rawfile q "$f" '{query: $q}')"; echo
done
(cd done-mcp && for fn in api mcp oauth snapshot; do
  supabase functions deploy "$fn" --project-ref "$REF" --no-verify-jwt
done)
supabase functions list --project-ref "$REF"
```

The other route is `supabase link --project-ref $REF` then `supabase db
push`; it needs the database password, which the pipeline route does not.

### First apply on staging (done 2026-10-21)

The "First apply" section below, with the Management API in place of psql:

1. the fifteen migrations, as above;
2. `ops/restore_with_epoch.sql` posted verbatim as one query (it has no psql
   meta-commands; the implicit transaction stands in for
   `--single-transaction`, so the guard's raise undoes the step). On an
   empty database the ledger record is `{epoch, kept_max = 0, dump_epoch =
   null}` and `paused` is true;
3. `ops/post_apply_checks.sql` — it uses `\gset` / `\if`, which the API does
   not understand; fold those branches into DO blocks with dynamic SQL
   (same P1 … P12 bodies) and read the twelve PASS/FAIL rows the last
   SELECT returns;
4. `update public.sync_epoch set paused = false` once the twelve are PASS.

Every later deploy reruns 015 and leaves the epoch row and the ledger alone;
run the checks (step 3) after each one, as R7 says.

### What staging has that the repo does not

- `SB_SECRET_KEY` is set as a function secret (the project's own
  `sb_secret_…` key, as in production), so the functions do not depend on
  the legacy `service_role` key.
- Auth providers mirror production's non-secret settings: Apple enabled with
  the bundle id `wordless.shiqiliuyifanmei.app` as client id (the native
  `id_token` flow needs no secret, so Apple sign-in works on staging as is);
  Google enabled with the same client id value as production; `site_url`
  and `uri_allow_list` as in production. Google's web PKCE flow
  (`/auth/v1/authorize?provider=google`) needs a real Google OAuth client id
  and its secret in Authentication → Providers → Google, and
  `https://gpxpvczmrezgzycypmsk.supabase.co/auth/v1/callback` as an
  authorized redirect URI in Google Cloud Console; neither is copied from
  production.
- Realtime: `private` channels are only enforced while "Allow public
  access" is off in the dashboard's Realtime settings (015 §6); a dashboard
  switch, check it on staging as on production.
- Three functions carry the production URL as a constant:
  `api/index.ts` (`BASE_URL`, the OpenAPI `servers` entry), `mcp/index.ts`
  (`MCP_BASE` / `OAUTH_BASE`, the OAuth metadata under `/.well-known/`) and
  `oauth/index.ts` (the fallback form's `action`). Deployed on staging they
  still advertise production, so an MCP client pointed at staging is sent to
  production's authorization server. Until they derive the base from
  `SUPABASE_URL`, test the MCP / OAuth flows on staging by URL, not by
  discovery.
- `GET /rest/v1/` (PostgREST's OpenAPI root) answers 401 "Secret API key
  required" to a publishable key, on staging and on production alike; it is
  not a sign that the schema is unreachable. Table and RPC routes answer as
  usual.

## First apply

015 seeds `sync_epoch` with a random epoch and an **empty** ledger, and P10
expects a non-empty ledger. So the first apply ends with one epoch step:

```sh
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f migrations/015_sync_change_feed.sql
psql "$DATABASE_URL" --single-transaction -v ON_ERROR_STOP=1 -f ops/restore_with_epoch.sql   # paused := true
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f ops/post_apply_checks.sql
# the HTTP half of handoff (4), then:
psql "$DATABASE_URL" -c "update public.sync_epoch set paused = false"
```

The step's ledger record is `{epoch, kept_max = max(seq) at that moment,
dump_epoch = null}`. Every later main push reruns 015 and leaves the row and
the ledger alone (bench S17.0).

## Post-apply checks

```sh
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f post_apply_checks.sql
```

| Id | Check |
|---|---|
| P1 | On every synced table, `trg_<t>_sync_gate`, `_sync_meta`, `_sync_version`, `_notify_ins`, `_notify_upd`, `_tombstone` and `_no_truncate` exist, call the right function with the right timing, and are `tgenabled = 'O'`; no `trg_<t>_sync_stamp` (that one exists only while rolled back). |
| P2 | `realtime.messages` has exactly one policy, `own sync topic` (SELECT, authenticated). |
| P3 | `notify_sync_change` is owned by `postgres`, `SECURITY DEFINER`, empty `search_path`. |
| P4 | `sync_changes` is not executable by `anon` or `PUBLIC` (a null ACL counts as PUBLIC), and is executable by `authenticated`. |
| P5 | The v6 shape: `sync_epoch` has `epoch`, `paused`, `rollback`, `restores` and not `floor` / `lost`, and exactly one row; the nine tables carry `version_id`, `parent_version_id`, `restored_from_version_id`; `events.domino_anchor` and `public.sync_versions` exist. |
| P6 | `sync_epoch` has RLS on, `authenticated` may only SELECT, `anon` has nothing, `service_role` cannot write. |
| P7 | the deployed `sync_changes` body clamps `page_limit` to `max_rows` (`least(page_limit, 1000)`). |
| P8 | `seq` is NOT NULL with no column default on every synced table. A default is what `rollback.sql` leaves; it still being there means the re-enable is not finished. |
| P9 | `sync_seq` has handed out every `seq` a synced row holds (`last_value`, or `last_value - 1` when `is_called` is false, is at or above `max(seq)` over all nine tables). Repair: the epoch step (R4), never a bare `setval`. |
| P10 | The restore ledger `sync_epoch.restores` is non-empty and its last record's epoch is the current epoch. Red right after a fresh database (run the epoch step, "First apply") and after a manual restore into a new project that did not bring `sync_epoch` along — residual (1) below, made visible. |
| P11 | `is_ancestor` exists, SECURITY INVOKER, executable by `authenticated` and not by `anon` / PUBLIC; `sync_versions_prune` exists, SECURITY DEFINER owned by `postgres`, not executable by `anon` / `authenticated` / PUBLIC; `sync_versions` has RLS on and `anon` has nothing. |
| P12 | Every synced row's `version_id` (tombstones included) is in `sync_versions`, and no row carries a `restored_from_version_id`. Red for rows inserted during a rollback window and after restoring a dump older than the retention: rerun 015, whose backfill adds the missing entries with `parent null`. |

`tests/run_all.sh` also runs a negative control per check (a mutation inside
a rolled-back transaction must turn exactly that check to FAIL).

The HTTP half of handoff (4) needs a signed-in user (`$USER_JWT`) and is not
SQL:

```sh
# the client's epoch read: 200 and exactly one row
curl -s "$REST/sync_epoch?select=epoch,paused,restores" -H "apikey: $PUBLISHABLE_KEY" -H "Authorization: Bearer $USER_JWT"
# the ancestry oracle: callable with a user JWT (any two uuids -> null when they are not in the log), refused with the apikey alone
curl -s -X POST "$REST/rpc/is_ancestor" -H "apikey: $PUBLISHABLE_KEY" -H "Authorization: Bearer $USER_JWT" \
  -H "Content-Type: application/json" -d '{"p_tbl":"events","p_id":"x","a":"00000000-0000-0000-0000-000000000000","b":"00000000-0000-0000-0000-000000000000"}'
# the max_rows probe (survey M1b), as a user who owns more rows than max_rows
curl -s -D - -o /dev/null "$REST/events?select=id&limit=1500" \
  -H "apikey: $PUBLISHABLE_KEY" -H "Authorization: Bearer $USER_JWT" -H "Prefer: count=exact"
# Content-Range: 0-<rows-1>/<count>.  rows < min(1000, count) => max_rows was
# lowered below the sync_changes clamp, and a full page will read as head
```

A 404 / PGRST2xx on `sync_epoch` or `is_ancestor` is the PostgREST schema
cache: `notify pgrst, 'reload schema'`.

## The epoch row and the write gate

`sync_epoch` is one row: `epoch`, `paused`, `rollback`, `restores` (the
ledger), `changed_at`. Clients read it with a plain
`GET /rest/v1/sync_epoch?select=epoch,paused,restores` after every pulled
page and compare the epoch with the one they hold; a change means "the
server was rewound or re-enabled: reset and catch up" (design §6.6). The
ledger tells a device which numbers each epoch step kept (`kept_max`), the
version log (`sync_versions`, `is_ancestor`) tells it whether its copy of a
row is an ancestor of the row the server now has.

The write gate `trg_<t>_sync_gate` (BEFORE INSERT OR UPDATE, first by name)
reads the request header `X-Sync-Epoch` that a Phase 1 client sends on every
write:

| Write | `paused = false` | `paused = true`, `rollback = false` | `paused = true`, `rollback = true` |
|---|---|---|---|
| header = current epoch | lands | `400 sync_paused` | `400 sync_paused` |
| header ≠ current epoch | `400 sync_epoch_stale` | `400 sync_epoch_stale` | `400 sync_epoch_stale` |
| no header (agent, MCP, edge function, old build, psql) | lands | `400 sync_paused` | lands (new seq from the stamp trigger) |

A refused write takes no `seq`, no version and rings no doorbell (bench S19 /
S20). The gate is never dropped — not by the rollback, not by a data fix.
`paused` is the remote switch: every epoch step sets it, and the operator
clears it by hand after the checks are green.

Two shapes the table does not show:

| Write | Answer |
|---|---|
| a conditional `PATCH …?id=eq.X&seq=eq.<base>` that matches no row (stale base, or the row is gone) | `200 []` whatever the header, paused or not — the gate is a row trigger and no row was touched. A client cannot tell "stale base" from "paused" by this answer; it reads `sync_epoch` after every page (design §6.6) |
| a merge-duplicates POST that hits an existing row and changes it | **`200`**, not `201` (`201` is only for a row that was inserted); an identical one is `200` too (dropped by the trigger). Handle upsert status codes as 2xx |

`request.headers` carries the whole request header set, `Authorization` and
`apikey` included. `sync_gate` reads the one key and drops the rest. Never
write that setting to a log, a table or a `RAISE … USING DETAIL` — it would
leak every caller's token.

## Dead rows and the tombstone defaults

A device whose delete lost its row on the server (design §6.6 "待删除胜")
inserts a **dead row**: only the key, `deleted_at` and `parent_version_id`
(`events` also sends `kind`). 015 gives the NOT NULL content columns that had
no default one, so that insert is a `201` on every synced table (bench S26):

| Table | Defaults that exist only for dead rows |
|---|---|
| `event_logs`, `event_feedback` | `event_id` = the zero uuid, `occurrence_date` = `1970-01-01T00:00:00Z` |
| `todo_lists` | `title` = `''`, `color_name` = `''` |
| `event_types` | `title` = `''`, `color_hex` = `''` |
| `skill_insights` | `skill_name` = `''`, `points` = `0`, `date` = `1970-01-01T00:00:00Z`, `event_title` = `''` |

A live row is never written without its content; nothing reads these values
as content. `events.kind` keeps no default (a dead event row still names its
kind), and the three single-row tables need none.

## Ancestry and ids

`is_ancestor(p_tbl, p_id, a, b)` lowercases the table name and matches a uuid
id in either case (the log stores `uuid::text`, lowercase; Swift's
`uuidString` is uppercase). A text occurrence key (`single|<UUID>`) is matched
exactly as it was sent — it keeps its case in the row and in the log.

## Restore

Into a new, empty project (Supabase's three-file restore; copy the old
project's `sync_epoch` and `sync_versions` over first, R6):

```sh
ops/restore.sh --target "$DATABASE_URL" --roles roles.sql --schema schema.sql --data data.sql
```

Into the existing project (empties the nine synced tables first, inside the
same transaction):

```sh
ops/restore.sh --target "$DATABASE_URL" --data data.sql --replace
```

The dump must be the R6 export. Either way one `psql --single-transaction`
runs roles, schema, `SET session_replication_role = replica`, the optional
emptying, a filtered copy of `data.sql` and `restore_with_epoch.sql`, so the
restored rows and the new epoch land together or not at all. The filter
(quoted and unquoted identifiers alike, CRLF tolerated):

- removes the dump's `setval('public.sync_seq', …)` (exactly one, or the
  script refuses): the counter is never rewound; the step lifts it to
  `max(live counter, kept_max)`;
- removes the `COPY public.sync_versions` block (exactly one, or the script
  refuses with "the export must include public.sync_versions"): the live log
  stays, so the versions written after the dump are still there for
  `is_ancestor`;
- removes the `COPY public.sync_epoch` block (exactly one row, or the script
  refuses) and reads the dump's epoch out of it: the live row stays, so the
  live ledger is carried over, and the new record carries that epoch as
  `dump_epoch`.

The step then appends `{epoch, kept_max = max(seq) over the restored rows
(tombstones included), dump_epoch}`, sets `paused := true`, `rollback :=
false`, and the script prints `epoch`, `kept_max`, the ledger length and
`paused`, then runs the post-apply checks. Clear `paused` by hand when they
are green. The restore rings no doorbell; the epoch is the only signal a
device gets (bench S17a).

If P12 is red after the restore (the dump is older than the log's
retention), rerun 015: its backfill adds the restored rows' versions with
`parent null`; their ancestry before the dump is gone with the retention,
and devices fall back to the ledger for them.

### Residual risk (design §9.37)

1. **A manual restore of a dump without the `sync_epoch` row, or without
   `sync_versions`, into a new project.** The ledger and the log start empty;
   the repair step that follows records a `kept_max` taken from writes made
   after the restore, so a device whose copy was lost by the restore reads
   "kept" from the ledger and "unknown" from the log, and the copy is hidden
   in its shelf rather than prompted. Only operations prevent it: `restore.sh`
   refuses such a dump; the export includes both tables (R6); everyday
   recovery goes through a temporary project (R5); a new-project restore
   copies the two tables first. P10 shows the empty ledger.
2. **The window after a bypassing restore and before the epoch step.** A
   device that pulled or wrote in that window took numbers that repeat the
   old timeline's numbers; no rule on the device tells the two apart. Run the
   step immediately, and set `paused` first (R3).
3. **The gate only judges writes that carry the header.** A pre-Phase-1 build
   (no header) is refused while paused and let through during a rollback with
   a new `seq`; its upload is a whole-table hash diff that the catch-up rules
   do not cover. Keeping such a build out of a syncing account is a
   distribution rule (§7), not a mechanism.

## Rollback

Design §7 handoff (8), §6.6. A rollback is not a rewind: the server keeps
every row, tombstone, `seq` and version. Use it when the post-launch audit is
not zero.

1. Roll back (not under `--single-transaction`; the file commits the pause
   first, waits W = T + S ≈ 35 s for accepted requests to finish, then runs
   the drops in one transaction):

   ```sh
   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f ops/rollback.sql
   ```

   Step 1 is `update sync_epoch set paused = true, rollback = true`: from
   that commit the write gate refuses every header-bearing write with
   `sync_paused` and lets header-less writes (agent, MCP, edge functions)
   through. Step 3, per synced table: gives `seq` the column default
   `nextval('public.sync_seq')`, drops `trg_<t>_sync_meta`,
   `trg_<t>_sync_version`, `trg_<t>_notify_ins`, `trg_<t>_notify_upd` and
   `trg_<t>_tombstone`, and creates `trg_<t>_sync_stamp` (BEFORE UPDATE:
   `new.seq := nextval`). The write gate, the TRUNCATE guard, `sync_seq`,
   `sync_epoch`, `sync_versions`, `sync_changes`, `is_ancestor` and the
   realtime policy stay. The default is not optional: `seq` is NOT NULL, and
   NOT NULL is checked before `ON CONFLICT` is resolved, so with the triggers
   gone and no default every write that leaves `seq` out fails `23502`. The
   stamp trigger is not optional either: an UPDATE that kept its old `seq`
   would let one number name two versions, and the ledger judges by number
   (§6.6 "回滚期间盖号"). The file ends with its own check and raises unless
   every table is in that shape. From here on `post_apply_checks.sql` fails
   P1 and P8; that is the rollback, not a fault.

   **A deploy inside the window is refused.** Every main push reruns the
   migrations; 015 begins with a guard that raises `015: server is rolled
   back; run ops/reenable.sql` while `sync_epoch.rollback` is set, so the
   deploy fails loudly instead of recreating the sync triggers on top of the
   seq default (a half re-enable with no epoch step; bench S18 rehearses the
   refusal). `reenable.sql` clears the bit inside its own transaction before
   it includes 015; nothing else may clear it.

While rolled back:

| Write | Effect |
|---|---|
| upsert of a new row (old-build shape, no `seq`, no header) | `201`; `seq` from the default, `version_id` from its default, no log row |
| upsert hitting an existing row, or a `PATCH` (agent, MCP as `service_role`; no header) | succeeds; the row **takes a new `seq`** from the stamp trigger and keeps its `version_id`; no log row |
| any write carrying `X-Sync-Epoch` (a Phase 1 client whose switch is still on) | `400 sync_paused` — the gate stays, the `rollback` bit only lets header-less writes through |
| `DELETE` | physical; no tombstone |
| any write | no doorbell |
| `TRUNCATE` | still refused |

2. Re-enable, in this order:

   ```sh
   psql "$DATABASE_URL" --single-transaction -v ON_ERROR_STOP=1 -f ops/reenable.sql   # clears rollback, drops the default and the stamp trigger, reruns 015, runs the epoch step
   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f ops/post_apply_checks.sql              # all PASS, P1 / P8 / P12 included
   psql "$DATABASE_URL" -c "update public.sync_epoch set paused = false"
   ```

   The epoch step inside `reenable.sql` is the reset every device takes: a
   new epoch, a ledger record `{epoch, kept_max = max(seq) over the nine
   tables, dump_epoch = null}`, `rollback := false`, `paused` left true. The
   counter is not moved (a rollback never rewinds it). On the new epoch every
   device marks its entries stale and catches up by the §6.6 rules: a clean
   device adopts the agent's edits from the window (its own copy is their
   ancestor in the log, so no prompt), and a row physically deleted in the
   window is POSTed back with its parent (it comes back; nothing is lost).
   `reenable.sql` includes `../migrations/015_sync_change_feed.sql` and
   `restore_with_epoch.sql` relative to itself, so run it from a checkout.
   Rerunning 015 keeps the data, the epoch row and the ledger, and backfills
   the log for rows inserted in the window.

Bench S18 (`tests/sync_restore_drill.sh`) rehearses the whole path on the
local stack: the counterfactual without a default, the script's own guard,
the rollback, an old-build upsert, a header-bearing PATCH refused with
`sync_paused`, a `service_role` PATCH that takes a new `seq`, a physical
DELETE, `reenable.sql`, the post-apply checks and the ledger record; then it
POSTs the deleted row back and checks that it lands above `kept_max` and
rings. "Keeps the data" is checked by content, not by row count: an md5 over
every row's full JSON, per synced table, around a fixture with a tombstone
on every table.
