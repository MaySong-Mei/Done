-- Sync change feed (v5): server-side change number, tombstones, a
-- per-statement doorbell on a private Realtime channel, a one-call delta
-- pull, and a restore epoch. Design: Docs/sync/00-realtime-sync-design.md §5;
-- the v5 changes are survey items M1 and M2 (Docs/sync/02-industry-survey.md).
--
-- STATUS: DRAFT — NOT APPLIED to production. Apply on the dev backend first
-- (P0.4), then production, then run done-mcp/supabase/ops/post_apply_checks.sql.
-- Idempotent by construction (every statement guards), matching the
-- deploy-reruns-all-migrations practice (gh#244). A rerun keeps the epoch row:
-- to a client, a migration rerun must not look like a restore.
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
--   * public.sync_epoch: one row (epoch, floor, changed_at), read by clients
--     with a plain GET. The restore procedure changes the epoch and sets the
--     floor to the restored sequence value in the same transaction as the
--     restored data, so a client can tell a rewound server from a normal one
--     and knows which incoming rows are restored content (M2). Only the
--     postgres role writes it: authenticated and service_role get SELECT.
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
--
-- Backward compatibility: a pre-015 client's upsert carries neither column;
-- the trigger fills seq. Its physical DELETE becomes a tombstone (trigger
-- 4), so the transition window loses nothing. PostgREST returns the extra
-- columns and the client's RowReader ignores unknown keys. The client only
-- sends `Prefer: resolution=merge-duplicates` (return=minimal), so a row
-- the BEFORE trigger drops is invisible to it.
--
-- Lock note (same as 014): nextval() is volatile, so `seq` is added
-- nullable, backfilled in one UPDATE, then made NOT NULL — no table rewrite
-- under an exclusive lock on the largest table.

set lock_timeout = '3s';

-- ============================================================
-- 1. Sequence
-- ============================================================
create sequence if not exists public.sync_seq as bigint;

-- ============================================================
-- 2. BEFORE INSERT OR UPDATE, per row:
--    commit-ordered seq · drop no-op writes · keep tombstones
-- ============================================================
create or replace function public.set_sync_meta()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  meta constant text[] := array['seq', 'updated_at', 'synced_at'];
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
    -- Content-identical write: no row version, no seq, no doorbell.
    if (to_jsonb(new) - meta) = (to_jsonb(old) - meta) then
      return null;
    end if;
    -- Deliberately no base-version check here: under INSERT … ON CONFLICT
    -- DO UPDATE the UPDATE arm's NEW is built from EXCLUDED, which already
    -- carries this trigger's INSERT-arm nextval(), so a client value in any
    -- SET column cannot be trusted to be the client's. The stale-write
    -- guard is the request filter (`&seq=eq.<base>`), see design I8.
  end if;

  new.seq := nextval('public.sync_seq');
  return new;
end;
$$;

-- ============================================================
-- 3. AFTER INSERT / AFTER UPDATE, per statement: the doorbell.
--    One message per statement and user: {table, seq = max seq written}.
--    Never the row — the client pulls through RLS. Clients coalesce rings
--    and pull `> cursor`, so the payload is a hint, not data.
--    SECURITY DEFINER because realtime.send inserts into realtime.messages,
--    which the authenticated role must not be able to write freely.
-- ============================================================
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

-- ============================================================
-- 4. BEFORE DELETE, per row: a delete is a tombstone (I4, server-enforced).
--    tg_argv[0] names the key column ('id' or 'user_id'). Runs as the
--    caller, so RLS applies; the UPDATE goes through trigger 2 (new seq)
--    and trigger 3 (doorbell). Returning null skips the physical delete.
--    Every direct delete — end user, service_role (edge function / MCP),
--    dashboard — becomes a tombstone, so it reaches the feed and the
--    doorbell. Only a delete fired by another trigger (depth > 1) stays
--    physical: that is the RI cascade from auth.users on account erase, the
--    one physical delete THE RULE in the header allows. There is no admin
--    hard-delete path: a row physically gone while a device still holds a
--    baseline for it makes that device's next conditional PATCH answer []
--    and its pending-verify conclude "same" (survey G2).
-- ============================================================
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

-- ============================================================
-- 4b. BEFORE TRUNCATE, per statement: refused (M1a). TRUNCATE fires no row
--     trigger, ignores RLS and leaves no tombstone, so every device that
--     holds a baseline for an erased row would keep it forever and swallow
--     its own later edits (survey G2). This also refuses
--     `truncate auth.users cascade`, whose cascade reaches these tables as a
--     TRUNCATE, not as the per-row delete the account erase relies on.
--     session_replication_role = replica skips this trigger (ops/README.md).
-- ============================================================
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
-- 5. Per-table columns, index, triggers
-- ============================================================
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

    execute format('alter table public.%I add column if not exists seq bigint', t);
    execute format('alter table public.%I add column if not exists deleted_at timestamptz', t);

    -- Backfill existing rows once (order unspecified: a client with no
    -- cursor pulls everything anyway). Later writes get seq from trigger 2.
    execute format(
      'update public.%I set seq = nextval(''public.sync_seq'') where seq is null', t);
    execute format('alter table public.%I alter column seq set not null', t);

    execute format(
      'create index if not exists idx_%s_user_seq on public.%I (user_id, seq)', t, t);

    execute format('drop trigger if exists trg_%s_sync_meta on public.%I', t, t);
    execute format(
      'create trigger trg_%s_sync_meta before insert or update on public.%I
         for each row execute function public.set_sync_meta()', t, t);

    -- PostgreSQL refuses a transition table on a multi-event trigger, hence
    -- one trigger per event. The function body names the table `changed`.
    execute format('drop trigger if exists trg_%s_notify on public.%I', t, t);  -- v1 name
    execute format('drop trigger if exists trg_%s_notify_ins on public.%I', t, t);
    execute format(
      'create trigger trg_%s_notify_ins after insert on public.%I
         referencing new table as changed
         for each statement execute function public.notify_sync_change()', t, t);
    execute format('drop trigger if exists trg_%s_notify_upd on public.%I', t, t);
    execute format(
      'create trigger trg_%s_notify_upd after update on public.%I
         referencing new table as changed
         for each statement execute function public.notify_sync_change()', t, t);

    execute format('drop trigger if exists trg_%s_tombstone on public.%I', t, t);
    execute format(
      'create trigger trg_%s_tombstone before delete on public.%I
         for each row execute function public.sync_delete_to_tombstone(%L)', t, t, key);

    execute format('drop trigger if exists trg_%s_no_truncate on public.%I', t, t);
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
--    jsonb so the existing RowReader-based decoders apply unchanged.
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
-- 8. Restore epoch (M2). One row. `epoch` changes only when the server is
--    rewound: the restore procedure (ops/restore_with_epoch.sql) sets a new
--    random epoch and floor := the restored sync_seq value in the same
--    transaction as the restored data, so no client can read restored rows
--    under the old epoch. A client stores the epoch it last saw; a different
--    value means "reset": rows with seq <= floor are restored content, rows
--    with seq > floor were written after the restore.
--    Seeded once with a random epoch and floor 0; a rerun of this migration
--    leaves the row alone, a fresh database (db reset) gets a new epoch.
--    Clients read it with a plain GET (`/rest/v1/sync_epoch?select=epoch,floor`)
--    through RLS. No RPC: a select policy is the whole surface, and a
--    function would add an execute grant to keep in check. Clients never
--    write it, and neither does service_role (edge functions, MCP), which
--    would otherwise keep Supabase's default full grant and bypass RLS; only
--    the postgres role (restore script) does.
-- ============================================================
create table if not exists public.sync_epoch (
  epoch      text        not null,
  floor      bigint      not null,
  changed_at timestamptz
);
create unique index if not exists sync_epoch_single_row on public.sync_epoch ((true));

insert into public.sync_epoch (epoch, floor, changed_at)
select gen_random_uuid()::text, 0, now()
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

notify pgrst, 'reload schema';
