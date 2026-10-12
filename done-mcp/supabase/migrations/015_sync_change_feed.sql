-- Sync change feed (v2): server-side change number, tombstones, a
-- per-statement doorbell on a private Realtime channel, and a one-call
-- delta pull. Design: Docs/sync/00-realtime-sync-design.md §5.
--
-- STATUS: DRAFT — NOT APPLIED. Apply on the dev backend first (P0.4),
-- then production. Idempotent by construction (every statement guards),
-- matching the deploy-reruns-all-migrations practice (gh#244).
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
--
-- Columns added to each of the 9 human-owned tables:
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
-- under an exclusive lock on the 4.8k-row events table.

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
-- ============================================================
create or replace function public.sync_delete_to_tombstone()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  execute format(
    'update public.%I set deleted_at = coalesce(deleted_at, now()) where %I = ($1).%I',
    tg_table_name, tg_argv[0], tg_argv[0])
  using old;
  return null;
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
--    jsonb so the existing RowReader-based decoders apply unchanged. A page
--    shorter than page_limit means the caller is at head.
-- ============================================================
drop function if exists public.sync_head();  -- v1, no consumer
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
  limit greatest(1, least(page_limit, 2000));
$$;

grant execute on function public.sync_changes(bigint, int) to authenticated;
