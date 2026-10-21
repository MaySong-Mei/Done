-- Sync change feed (v6): server-side change number, tombstones, a
-- per-statement doorbell on a private Realtime channel, a one-call delta
-- pull, a restore epoch with a restore ledger, a version ancestry log, and a
-- server-side write gate. Design: Docs/sync/00-realtime-sync-design.md §5
-- (items 7, 9, 10 and the ops rules) and §6.6.
--
-- STATUS: DRAFT — NOT APPLIED to production. Apply on the dev backend first
-- (P0.4), then production, then run done-mcp/supabase/ops/post_apply_checks.sql.
-- Idempotent by construction (every statement guards), matching the
-- deploy-reruns-all-migrations practice (gh#244). A rerun keeps the epoch row
-- and its ledger: to a client, a migration rerun must not look like a restore.
-- Reruns on a database that ran the v4 / v5 drafts are covered: old columns
-- go with `drop column if exists`, new ones come with `add column if not
-- exists`, and the version log is backfilled with `insert … where not exists`.
--
-- THE RULE for every later data fix: never physically delete a row that a
-- device may hold. The only physical delete is the auth.users cascade on
-- account erase. An admin delete is an ordinary DELETE (it becomes a
-- tombstone); to scrub content, UPDATE the content columns of the tombstoned
-- row (the update takes a seq and propagates); to reset a single-row table,
-- UPDATE it. TRUNCATE is refused. Keep every sync trigger enabled; never run
-- a data fix under session_replication_role = replica except the documented
-- restore (done-mcp/supabase/ops/README.md), which ends by changing the epoch.
--
-- v2 (gh#257 review round 1):
--   * per-user advisory lock in the BEFORE trigger, so seq order equals
--     commit-visibility order and a cursor can never skip a committed row;
--   * a content-identical write is dropped before it takes a seq;
--   * a physical DELETE is rewritten into a tombstone server-side, so I4
--     ("nothing destroys a tombstone") holds for every client, old or new;
--   * a tombstone cannot be un-deleted by an ordinary write (I6);
--   * the doorbell is one message per statement, not per row;
--   * device_id, server_updated_at and sync_head() removed (no consumer).
-- v3 (gh#257 review round 2):
--   * the delete→tombstone rewrite does not apply inside an RI cascade, so
--     account erase (auth.users → on delete cascade) still physically deletes;
--   * sync_changes is not callable by anon.
-- v4 (gh#257 review round 3):
--   * NO server-side stale-write check. v3 compared the client's base seq in
--     the UPDATE arm, but EXCLUDED reflects BEFORE INSERT trigger effects, so
--     the INSERT arm's nextval() would have reached the UPDATE arm and every
--     edit would have been refused. The precondition lives in the request
--     instead: a client updates with `PATCH …?id=eq.X&seq=eq.<base>` and reads
--     0 rows as "stale, pull first" (design I8). Nothing to add here.
--   * the rewrite gate is trigger depth only, not role: a service_role delete
--     (edge function / MCP) must also become a tombstone, or every client
--     keeps the row and its next edit resurrects it.
-- v5 (gh#257 industry survey, M1 and M2):
--   * a BEFORE TRUNCATE statement trigger on every synced table refuses
--     TRUNCATE, which skips row triggers and would erase rows without
--     tombstones (M1a). Under session_replication_role = replica this guard
--     does not fire, like every other ordinary trigger; the restore path is
--     covered by the epoch instead;
--   * sync_changes clamps page_limit to PostgREST's max_rows, so a full page
--     can never come back truncated and be read as head (M1b);
--   * the "disable the tombstone trigger, then hard delete" admin recipe is
--     gone; THE RULE above replaces it (M1c);
--   * public.sync_epoch, one row, read by clients with a plain GET (M2).
-- v6 (gh#257 design v1.6, 2026-10-20 §10.8–10.9):
--   * sync_epoch loses `floor` and `lost` (the device no longer computes
--     which numbers were lost) and gains `paused`, `rollback` and the restore
--     ledger `restores` (one record per epoch step: {epoch, kept_max,
--     dump_epoch}). Only the epoch steps in ops/ write it (§6.6);
--   * version ancestry: every synced row carries `version_id` and
--     `parent_version_id`; every write that lands appends one row to
--     public.sync_versions (kept across restores, 90-day retention through
--     sync_versions_prune); `restored_from_version_id` is a carrier column
--     for a write-back request, read by the trigger and never left on the
--     row; is_ancestor(tbl, id, a, b) answers true / false / null (§5.9);
--   * the write gate: a BEFORE INSERT OR UPDATE trigger on every synced
--     table refuses a write whose `X-Sync-Epoch` header is not the current
--     epoch (`sync_epoch_stale`) and, while paused, every header-bearing
--     write and every header-less write outside a rollback (`sync_paused`).
--     It fires before set_sync_meta, so a refused write takes no seq and
--     rings no doorbell (§5.10);
--   * events.domino_anchor (§5.8), a nullable column that rides along in the
--     feed like any other.
--
-- Columns added to each human-owned table listed in section 5:
--   seq         bigint      — global change number, assigned on every
--                             content-changing insert/update. The ONE cursor
--                             a client keeps. Global is fine: a client only
--                             compares seqs within its own user.
--   deleted_at  timestamptz — tombstone. Content is kept (gh#140 undo). Not
--                             purged by this migration; deletions are rare
--                             at this scale and a purge needs a watermark
--                             the clients can compare against (design §9).
--   version_id  uuid        — the version this row currently is. Assigned
--                             by the trigger on every content-changing
--                             write; a client-sent value is ignored.
--   parent_version_id uuid  — the version this one was written over. On an
--                             UPDATE the trigger sets it to the old
--                             version_id; on an INSERT the client's value is
--                             kept (a re-upload names the version its
--                             baseline held) or null.
--   restored_from_version_id uuid — request carrier only: a write-back names
--                             the shelved copy it restores. The trigger reads
--                             it into the version log and nulls it on the row.
--
-- Backward compatibility: a pre-015 client's upsert carries none of these
-- columns; the triggers fill them. Its physical DELETE becomes a tombstone,
-- so the transition window loses nothing. PostgREST returns the extra
-- columns and the client's RowReader ignores unknown keys. The client only
-- sends `Prefer: resolution=merge-duplicates` (return=minimal), so a row
-- the BEFORE trigger drops is invisible to it. A pre-015 client sends no
-- X-Sync-Epoch header: the gate lets it through unless the server is paused.
--
-- Lock note (same as 014): nextval() and gen_random_uuid() are volatile, so
-- `seq` and `version_id` are added nullable, backfilled in one UPDATE, then
-- made NOT NULL — no table rewrite under an exclusive lock on the largest
-- table. The backfill runs with the table's sync triggers dropped (they are
-- recreated right after, in the same transaction), so on a rerun it neither
-- takes seqs nor rings.

set lock_timeout = '3s';

-- ============================================================
-- 1. Sequence
-- ============================================================
create sequence if not exists public.sync_seq as bigint;

-- ============================================================
-- 2. Restore epoch and ledger (§5.7, §6.6). One row. `epoch` changes only
--    when an epoch step runs (ops/restore.sh, ops/restore_with_epoch.sql on
--    its own, ops/reenable.sql); each step appends one record to the ledger
--    `restores`: {epoch, kept_max, dump_epoch}. `paused` is the server-side
--    pause bit the write gate enforces; `rollback` tells the gate to let
--    header-less writes through during a rollback. Seeded once with a random
--    epoch and an empty ledger; a rerun of this migration leaves the row
--    alone, a fresh database (db reset) gets a new epoch.
--    Clients read it with a plain GET
--    (`/rest/v1/sync_epoch?select=epoch,paused,restores`) through RLS. No
--    RPC. Clients never write it, and neither does service_role (edge
--    functions, MCP), which would otherwise keep Supabase's default full
--    grant and bypass RLS; only the postgres role (the epoch steps) does.
--    The old v5 columns `floor` and `lost` are dropped: the device no longer
--    computes lost ranges (design v1.6, rule A archived).
-- ============================================================
create table if not exists public.sync_epoch (
  epoch      text        not null,
  paused     boolean     not null default false,
  rollback   boolean     not null default false,
  restores   jsonb       not null default '[]',
  changed_at timestamptz
);
alter table public.sync_epoch drop column if exists floor;
alter table public.sync_epoch drop column if exists lost;
alter table public.sync_epoch add column if not exists paused   boolean not null default false;
alter table public.sync_epoch add column if not exists rollback boolean not null default false;
alter table public.sync_epoch add column if not exists restores jsonb   not null default '[]';
create unique index if not exists sync_epoch_single_row on public.sync_epoch ((true));

insert into public.sync_epoch (epoch, changed_at)
select gen_random_uuid()::text, now()
where not exists (select 1 from public.sync_epoch);

alter table public.sync_epoch enable row level security;
revoke all on table public.sync_epoch from public, anon, authenticated, service_role;
grant select on table public.sync_epoch to authenticated, service_role;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'sync_epoch'
      and policyname = 'read sync epoch'
  ) then
    create policy "read sync epoch" on public.sync_epoch
      for select to authenticated
      using ( true );
  end if;
end;
$$;

-- ============================================================
-- 3. Version log (§5.9). One row per write that landed on a synced table:
--    which version the row became, which version it was written over, and
--    (for a write-back) which shelved copy it restored. Kept across restores
--    (ops/restore.sh strips its COPY block from the dump) and pruned after 90
--    days by sync_versions_prune (section 8), which never removes a live
--    row's current version. An account erase (the auth.users cascade) takes
--    the log rows with it. RLS: a user reads only their own log. Inserts
--    come from the AFTER trigger as the caller; the policy's
--    pg_trigger_depth() > 0 keeps a client from appending to the log directly
--    through PostgREST. service_role bypasses RLS and keeps the grant it
--    needs for its own writes (edge functions, MCP).
-- ============================================================
create table if not exists public.sync_versions (
  user_id                  uuid        not null references auth.users(id) on delete cascade,
  tbl                      text        not null,
  id                       text        not null,
  version_id               uuid        not null,
  parent_version_id        uuid,
  restored_from_version_id uuid,
  seq                      bigint      not null,
  created_at               timestamptz not null default now(),
  primary key (user_id, tbl, id, version_id)
);
create unique index if not exists sync_versions_version_id on public.sync_versions (version_id);
create index if not exists idx_sync_versions_created on public.sync_versions (created_at);

alter table public.sync_versions enable row level security;
revoke all on table public.sync_versions from public, anon, authenticated, service_role;
grant select, insert on table public.sync_versions to authenticated, service_role;

do $$
begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'sync_versions'
                 and policyname = 'read own versions') then
    create policy "read own versions" on public.sync_versions
      for select to authenticated
      using ( user_id = (select auth.uid()) );
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'sync_versions'
                 and policyname = 'log own versions') then
    create policy "log own versions" on public.sync_versions
      for insert to authenticated
      with check ( user_id = (select auth.uid()) and pg_trigger_depth() > 0 );
  end if;
end;
$$;

-- ============================================================
-- 4. Trigger functions
-- ============================================================

-- 4a. BEFORE INSERT OR UPDATE, per row, first by name: the write gate (§5.10).
--     PostgREST passes the request headers as JSON in `request.headers`; a
--     Phase 1 client sends `X-Sync-Epoch: <the epoch it holds>` on every
--     write. Outside PostgREST (psql, ops) there is no header. No row in
--     sync_epoch is treated as paused: nothing can be compared, so nothing
--     lands until an epoch step writes the row.
create or replace function public.sync_gate()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  hdr          text := nullif(current_setting('request.headers', true), '');
  h            text;
  cur_epoch    text;
  cur_paused   boolean;
  cur_rollback boolean;
begin
  if hdr is not null then
    h := (hdr::json) ->> 'x-sync-epoch';
  end if;
  select epoch, paused, rollback into cur_epoch, cur_paused, cur_rollback
  from public.sync_epoch limit 1;
  if not found then
    raise exception 'sync_paused' using errcode = 'P0001',
      hint = 'sync_epoch has no row; run the epoch step (ops/restore_with_epoch.sql)';
  end if;
  if h is not null and h <> cur_epoch then
    raise exception 'sync_epoch_stale' using errcode = 'P0001',
      hint = 'the X-Sync-Epoch header is not the current epoch; pull sync_epoch and reset';
  end if;
  if cur_paused and (h is not null or not cur_rollback) then
    raise exception 'sync_paused' using errcode = 'P0001',
      hint = 'sync is paused on the server; retry after sync_epoch.paused is false';
  end if;
  return new;
end;
$$;

-- 4b. BEFORE INSERT OR UPDATE, per row, after the gate:
--     commit-ordered seq · drop no-op writes · keep tombstones · version ids
create or replace function public.set_sync_meta()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  meta constant text[] := array['seq', 'updated_at', 'synced_at',
                                'version_id', 'parent_version_id', 'restored_from_version_id'];
  rf uuid;
begin
  -- Held until commit. Within one user, a transaction cannot take a seq
  -- until every earlier seq-taker of that user has committed or aborted,
  -- so a reader that saw seq N has seen every committed seq below N.
  -- Aborted transactions leave gaps; gaps are harmless.
  -- Lock order is row lock (taken by the statement) then this user lock, so
  -- a multi-row statement and a single-row one on the same user can deadlock
  -- (40P01 after deadlock_timeout); one side rolls back and the client's
  -- chunk retry heals it. Rare; not a bug when it shows up in logs.
  perform pg_advisory_xact_lock(hashtext(new.user_id::text));

  if tg_op = 'UPDATE' then
    -- I6: a tombstone survives ordinary writes (a stale device re-pushing
    -- its live copy, a backup restore). gh#140 adds the explicit undelete.
    if old.deleted_at is not null and new.deleted_at is null then
      new.deleted_at := old.deleted_at;
    end if;
    -- Content-identical write: no row version, no seq, no doorbell, no log
    -- row. The version columns are metadata, not content.
    if (to_jsonb(new) - meta) = (to_jsonb(old) - meta) then
      return null;
    end if;
    -- Deliberately no base-version check here: under INSERT … ON CONFLICT
    -- DO UPDATE the UPDATE arm's NEW is built from EXCLUDED, which already
    -- carries this trigger's INSERT-arm nextval(), so a client value in any
    -- SET column cannot be trusted to be the client's. The stale-write
    -- guard is the request filter (`&seq=eq.<base>`), see design I8.
    -- The parent of the new version is the version being written over; a
    -- client-sent parent is ignored on UPDATE. On INSERT it is kept.
    new.parent_version_id := old.version_id;
  end if;

  -- A write-back names the shelved copy it restores. It goes into the
  -- version log (through the AFTER trigger) and never stays on the row.
  -- The AFTER trigger fires only for rows that land, so the value travels
  -- in a transaction-local setting keyed by the new version id.
  rf := new.restored_from_version_id;
  new.restored_from_version_id := null;
  new.version_id := gen_random_uuid();
  new.seq := nextval('public.sync_seq');
  if rf is not null then
    perform set_config('done.sync_rf_' || replace(new.version_id::text, '-', ''), rf::text, true);
  end if;
  return new;
end;
$$;

-- 4c. AFTER INSERT OR UPDATE, per row: append the version to the log.
--     AFTER, not inside set_sync_meta: under INSERT … ON CONFLICT DO UPDATE
--     the BEFORE INSERT trigger runs on a row that never lands (the UPDATE
--     arm writes instead), and a log row written there would name a version
--     that exists nowhere. An AFTER ROW trigger fires once per row that was
--     actually written. tg_argv[0] names the key column ('id' or 'user_id').
create or replace function public.sync_log_version()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  k  text := to_jsonb(new) ->> tg_argv[0];
  g  text := 'done.sync_rf_' || replace(new.version_id::text, '-', '');
  rf text := nullif(current_setting(g, true), '');
begin
  if rf is not null then
    perform set_config(g, '', true);
  end if;
  insert into public.sync_versions
    (user_id, tbl, id, version_id, parent_version_id, restored_from_version_id, seq)
  values
    (new.user_id, tg_table_name, k, new.version_id, new.parent_version_id, rf::uuid, new.seq);
  return null;
end;
$$;

-- 4d. AFTER INSERT / AFTER UPDATE, per statement: the doorbell.
--     One message per statement and user: {table, seq = max seq written}.
--     Never the row — the client pulls through RLS. Clients coalesce rings
--     and pull `> cursor`, so the payload is a hint, not data.
--     SECURITY DEFINER because realtime.send inserts into realtime.messages,
--     which the authenticated role must not be able to write freely.
create or replace function public.notify_sync_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
begin
  for r in select user_id, max(seq) as seq from changed group by user_id loop
    perform realtime.send(
      jsonb_build_object('table', tg_table_name, 'seq', r.seq),
      'change',
      'user:' || r.user_id::text,
      true  -- private: only the owning user's channel can receive it
    );
  end loop;
  return null;
end;
$$;

-- 4e. BEFORE DELETE, per row: a delete is a tombstone (I4, server-enforced).
--     tg_argv[0] names the key column ('id' or 'user_id'). Runs as the
--     caller, so RLS applies; the UPDATE goes through the gate, set_sync_meta
--     (new seq, new version) and the doorbell. Returning null skips the
--     physical delete. Every direct delete — end user, service_role (edge
--     function / MCP), dashboard — becomes a tombstone, so it reaches the
--     feed and the doorbell. Only a delete fired by another trigger
--     (depth > 1) stays physical: that is the RI cascade from auth.users on
--     account erase, the one physical delete THE RULE in the header allows.
--     There is no admin hard-delete path: a row physically gone while a
--     device still holds a baseline for it makes that device's next
--     conditional PATCH answer [] and its pending-verify conclude "same"
--     (survey G2).
create or replace function public.sync_delete_to_tombstone()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if pg_trigger_depth() > 1 then
    return old;
  end if;
  execute format(
    'update public.%I set deleted_at = coalesce(deleted_at, now()) where %I = ($1).%I',
    tg_table_name, tg_argv[0], tg_argv[0])
  using old;
  return null;
end;
$$;

-- 4f. BEFORE TRUNCATE, per statement: refused (M1a). TRUNCATE fires no row
--     trigger, ignores RLS and leaves no tombstone, so every device that
--     holds a baseline for an erased row would keep it forever and swallow
--     its own later edits (survey G2). This also refuses
--     `truncate auth.users cascade`, whose cascade reaches these tables as a
--     TRUNCATE, not as the per-row delete the account erase relies on.
--     session_replication_role = replica skips this trigger (ops/README.md).
create or replace function public.sync_refuse_truncate()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'truncate of public.% refused: use DELETE, rows become tombstones', tg_table_name
    using errcode = 'restrict_violation',
          hint = 'A synced row is never physically deleted outside the auth.users cascade; see migration 015.';
end;
$$;

-- ============================================================
-- 5. Per-table columns, index, triggers, version-log backfill
-- ============================================================
alter table public.events add column if not exists domino_anchor timestamptz;

do $$
declare
  t   text;
  key text;
  tables text[] := array[
    'events', 'event_logs', 'event_feedback', 'todo_lists', 'event_types',
    'skill_insights', 'user_settings', 'agent_preferences', 'agent_conversations'
  ];
begin
  foreach t in array tables loop
    key := case when t in ('user_settings', 'agent_preferences', 'agent_conversations')
                then 'user_id' else 'id' end;

    -- Triggers go first and come back at the end of this iteration, so the
    -- backfills below run on a bare table: on a rerun they would otherwise
    -- be dropped as no-ops (the version columns are not content), take
    -- seqs, or ring. v1 names and the rollback's stamp trigger are dropped
    -- too (post-apply check P1 refuses a stamp trigger outside a rollback).
    execute format('drop trigger if exists trg_%s_sync_gate on public.%I', t, t);
    execute format('drop trigger if exists trg_%s_sync_meta on public.%I', t, t);
    execute format('drop trigger if exists trg_%s_sync_version on public.%I', t, t);
    execute format('drop trigger if exists trg_%s_sync_stamp on public.%I', t, t);
    execute format('drop trigger if exists trg_%s_notify on public.%I', t, t);  -- v1 name
    execute format('drop trigger if exists trg_%s_notify_ins on public.%I', t, t);
    execute format('drop trigger if exists trg_%s_notify_upd on public.%I', t, t);
    execute format('drop trigger if exists trg_%s_tombstone on public.%I', t, t);
    execute format('drop trigger if exists trg_%s_no_truncate on public.%I', t, t);

    execute format('alter table public.%I add column if not exists seq bigint', t);
    execute format('alter table public.%I add column if not exists deleted_at timestamptz', t);
    execute format('alter table public.%I add column if not exists version_id uuid', t);
    execute format('alter table public.%I add column if not exists parent_version_id uuid', t);
    execute format('alter table public.%I add column if not exists restored_from_version_id uuid', t);

    -- Backfill existing rows once (order unspecified: a client with no
    -- cursor pulls everything anyway). Later writes get seq and version_id
    -- from the trigger; the default covers writes made while the triggers
    -- are gone (ops/rollback.sql).
    execute format(
      'update public.%I set seq = nextval(''public.sync_seq'') where seq is null', t);
    execute format('alter table public.%I alter column seq set not null', t);
    execute format(
      'update public.%I set version_id = gen_random_uuid() where version_id is null', t);
    execute format('alter table public.%I alter column version_id set not null', t);
    execute format('alter table public.%I alter column version_id set default gen_random_uuid()', t);

    -- Every row's current version is in the log (post-apply check P12): a
    -- first apply, a rerun after a rollback (rows inserted in the window
    -- took version_id from the default) and a restore of a dump older than
    -- the retention all land here. Parent unknown, so null.
    execute format(
      'insert into public.sync_versions (user_id, tbl, id, version_id, parent_version_id, restored_from_version_id, seq)
         select r.user_id, %L, r.%I::text, r.version_id, null, null, r.seq
         from public.%I r
         where not exists (select 1 from public.sync_versions v where v.version_id = r.version_id)',
      t, key, t);

    execute format(
      'create index if not exists idx_%s_user_seq on public.%I (user_id, seq)', t, t);

    -- Same-timing triggers fire in name order: sync_gate before sync_meta.
    execute format(
      'create trigger trg_%s_sync_gate before insert or update on public.%I
         for each row execute function public.sync_gate()', t, t);
    execute format(
      'create trigger trg_%s_sync_meta before insert or update on public.%I
         for each row execute function public.set_sync_meta()', t, t);
    execute format(
      'create trigger trg_%s_sync_version after insert or update on public.%I
         for each row execute function public.sync_log_version(%L)', t, t, key);

    -- PostgreSQL refuses a transition table on a multi-event trigger, hence
    -- one trigger per event. The function body names the table `changed`.
    execute format(
      'create trigger trg_%s_notify_ins after insert on public.%I
         referencing new table as changed
         for each statement execute function public.notify_sync_change()', t, t);
    execute format(
      'create trigger trg_%s_notify_upd after update on public.%I
         referencing new table as changed
         for each statement execute function public.notify_sync_change()', t, t);

    execute format(
      'create trigger trg_%s_tombstone before delete on public.%I
         for each row execute function public.sync_delete_to_tombstone(%L)', t, t, key);

    execute format(
      'create trigger trg_%s_no_truncate before truncate on public.%I
         for each statement execute function public.sync_refuse_truncate()', t, t);
  end loop;
end;
$$;

-- ============================================================
-- 6. Private channel authorization: a user may subscribe ONLY to
--    `user:<their uid>`. Receiving = SELECT; clients never send, so no
--    INSERT policy. Dashboard prerequisite (not expressible in SQL):
--    Realtime Settings → disable "Allow public access", otherwise
--    `private` is not enforced.
-- ============================================================
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'realtime' and tablename = 'messages'
      and policyname = 'own sync topic'
  ) then
    create policy "own sync topic" on realtime.messages
      for select to authenticated
      using ( realtime.topic() = 'user:' || (select auth.uid())::text );
  end if;
end;
$$;

-- ============================================================
-- 7. One-call delta pull. SECURITY INVOKER (the default) so every table's
--    RLS applies — the function sees only the caller's rows. Ordered by
--    seq so a page boundary is a clean cursor; `data` is the full row as
--    jsonb so the existing RowReader-based decoders apply unchanged (the
--    version columns ride along in `data`).
--    page_limit is clamped to PostgREST's max_rows (config.toml [api]
--    max_rows; the hosted default is the same value). Above it, PostgREST
--    would cut a full page short and the caller would read the cut page as
--    head (survey G3). The client's head rule is therefore: a page shorter
--    than min(page_limit, the clamp) means the caller is at head. If max_rows
--    is ever lowered below the clamp in the dashboard, the same false head
--    returns; the max_rows probe in ops/README.md detects that.
-- ============================================================
create or replace function public.sync_changes(since_seq bigint, page_limit int default 500)
returns table (tbl text, seq bigint, data jsonb)
language sql
stable
set search_path = ''
as $$
  select * from (
    select 'events'::text              as tbl, e.seq, to_jsonb(e) as data from public.events e              where e.seq > since_seq
    union all
    select 'event_logs',                     l.seq, to_jsonb(l)         from public.event_logs l          where l.seq > since_seq
    union all
    select 'event_feedback',                 f.seq, to_jsonb(f)         from public.event_feedback f      where f.seq > since_seq
    union all
    select 'todo_lists',                     t.seq, to_jsonb(t)         from public.todo_lists t          where t.seq > since_seq
    union all
    select 'event_types',                    y.seq, to_jsonb(y)         from public.event_types y         where y.seq > since_seq
    union all
    select 'skill_insights',                 s.seq, to_jsonb(s)         from public.skill_insights s      where s.seq > since_seq
    union all
    select 'user_settings',                  u.seq, to_jsonb(u)         from public.user_settings u       where u.seq > since_seq
    union all
    select 'agent_preferences',              p.seq, to_jsonb(p)         from public.agent_preferences p   where p.seq > since_seq
    union all
    select 'agent_conversations',            c.seq, to_jsonb(c)         from public.agent_conversations c where c.seq > since_seq
  ) changes
  order by seq
  limit greatest(1, least(page_limit, 1000));
$$;

revoke execute on function public.sync_changes(bigint, int) from public, anon;
grant execute on function public.sync_changes(bigint, int) to authenticated;

-- ============================================================
-- 8. Ancestry oracle and retention (§5.9).
--    is_ancestor(tbl, id, a, b): walk up from b along parent_version_id and
--    restored_from_version_id (depth ≤ 1000); reaching a → true (a = b
--    counts: a version is its own ancestor); the walk ends → false; a or b
--    not in the caller's log → null (unknown: the device falls back to the
--    ledger). SECURITY INVOKER, so RLS limits the log to the caller's rows
--    and another user's version reads as "not in the log".
--    `id` is text: event_logs / event_feedback ids are occurrence keys, the
--    three single-row tables are keyed by user_id. A uuid id is passed as
--    its text form.
-- ============================================================
create or replace function public.is_ancestor(p_tbl text, p_id text, a uuid, b uuid)
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  with recursive walk(version_id, parent_version_id, restored_from_version_id, depth) as (
    select v.version_id, v.parent_version_id, v.restored_from_version_id, 0
    from public.sync_versions v
    where v.tbl = p_tbl and v.id = p_id and v.version_id = b
    union
    select v.version_id, v.parent_version_id, v.restored_from_version_id, w.depth + 1
    from walk w
    join public.sync_versions v
      on v.tbl = p_tbl and v.id = p_id
     and (v.version_id = w.parent_version_id or v.version_id = w.restored_from_version_id)
    where w.depth < 1000
  )
  select case
    when not exists (select 1 from public.sync_versions v where v.tbl = p_tbl and v.id = p_id and v.version_id = a)
      or not exists (select 1 from public.sync_versions v where v.tbl = p_tbl and v.id = p_id and v.version_id = b)
    then null
    else exists (select 1 from walk w where w.version_id = a)
  end;
$$;

revoke execute on function public.is_ancestor(text, text, uuid, uuid) from public, anon;
grant execute on function public.is_ancestor(text, text, uuid, uuid) to authenticated, service_role;

-- sync_versions_prune(days): delete log rows older than `days`, never a
-- version a synced row (tombstones included) currently holds. SECURITY
-- DEFINER so the nightly task (D3; no pg_cron on the Free plan, see
-- ops/README.md R6) can run it as service_role without a delete grant on the
-- log. Returns the number of rows removed.
create or replace function public.sync_versions_prune(p_days int default 90)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  t      text;
  n      bigint;
  total  bigint := 0;
  cutoff timestamptz := now() - make_interval(days => greatest(p_days, 0));
begin
  foreach t in array array[
    'events', 'event_logs', 'event_feedback', 'todo_lists', 'event_types',
    'skill_insights', 'user_settings', 'agent_preferences', 'agent_conversations'
  ] loop
    execute format(
      'delete from public.sync_versions v
         where v.tbl = %L and v.created_at < $1
           and not exists (select 1 from public.%I r where r.version_id = v.version_id)', t, t)
    using cutoff;
    get diagnostics n = row_count;
    total := total + n;
  end loop;
  return total;
end;
$$;

revoke execute on function public.sync_versions_prune(int) from public, anon, authenticated;
grant execute on function public.sync_versions_prune(int) to service_role;

notify pgrst, 'reload schema';
