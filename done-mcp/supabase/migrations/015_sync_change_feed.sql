-- Sync change feed: server-side sequence, tombstones, device provenance,
-- and a private-channel doorbell (Docs/sync/00-realtime-sync-design.md §5).
--
-- STATUS: DRAFT — NOT APPLIED. Apply on the dev backend first (P0.5),
-- then production. Idempotent by construction (every statement guards),
-- matching the deploy-reruns-all-migrations practice (gh#244).
--
-- What it adds, per human-owned table:
--   seq               bigint   — global monotonic change number, assigned by
--                                trigger on every insert/update. The ONE cursor
--                                a client keeps. Global (not per-user) is fine:
--                                a client only ever compares its own user's seqs.
--   deleted_at        timestamptz — tombstone. Clients never DELETE; a delete is
--                                an upsert with deleted_at set. The row keeps its
--                                content so gh#140 (undo) has something to undo.
--   device_id         text     — install identity of the writer (echo suppression).
--                                Null = written by a pre-015 client; treated as
--                                foreign.
--   server_updated_at timestamptz — set by trigger from the server clock. The
--                                client-supplied `updated_at` is deliberately NOT
--                                overwritten: Phase 2 makes it the edit time.
--
-- Backward compatibility: a pre-015 client's upsert carries none of these
-- columns; the trigger fills seq/server_updated_at and device_id stays null.
-- PostgREST returns the extra columns and the client's RowReader ignores
-- unknown keys. A pre-015 client's physical DELETE still works and simply
-- loses the tombstone (transition window only — same class as gh#151).
--
-- Lock note (same as 014): ALTER TABLE ... ADD COLUMN with a non-volatile
-- default takes ACCESS EXCLUSIVE for microseconds and does not rewrite the
-- table. nextval() IS volatile, so `seq` is added nullable-with-no-default
-- first, backfilled in one UPDATE, then made NOT NULL — avoiding a full
-- rewrite under an exclusive lock on the 4.8k-row events table.

set lock_timeout = '3s';

-- ============================================================
-- 1. Sequence
-- ============================================================
create sequence if not exists public.sync_seq as bigint;

-- ============================================================
-- 2. Trigger: stamp seq + server_updated_at on every write
-- ============================================================
create or replace function public.set_sync_meta()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.seq := nextval('public.sync_seq');
  new.server_updated_at := now();
  return new;
end;
$$;

-- ============================================================
-- 3. Trigger: doorbell. Locator only (table / id / seq / device / deleted),
--    never the row — the client pulls the row through RLS.
--    SECURITY DEFINER because realtime.send inserts into realtime.messages,
--    which the authenticated role must not be able to write freely.
-- ============================================================
create or replace function public.notify_sync_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform realtime.send(
    jsonb_build_object(
      'table',     tg_table_name,
      'id',        new.id,
      'seq',       new.seq,
      'device_id', new.device_id,
      'deleted',   new.deleted_at is not null
    ),
    'change',
    'user:' || new.user_id::text,
    true  -- private: only the owning user's channel can receive it
  );
  return new;
end;
$$;

-- ============================================================
-- 4. Per-table columns, index, triggers
-- ============================================================
do $$
declare
  t text;
  tables text[] := array[
    'events', 'event_logs', 'event_feedback', 'todo_lists', 'event_types',
    'skill_insights', 'user_settings', 'agent_preferences', 'agent_conversations'
  ];
begin
  foreach t in array tables loop
    execute format('alter table public.%I add column if not exists seq bigint', t);
    execute format('alter table public.%I add column if not exists deleted_at timestamptz', t);
    execute format('alter table public.%I add column if not exists device_id text', t);
    execute format('alter table public.%I add column if not exists server_updated_at timestamptz not null default now()', t);

    -- Backfill existing rows once, in insertion order so the initial feed is
    -- deterministic. Rows written after this migration get their seq from the
    -- trigger.
    execute format(
      'update public.%I set seq = nextval(''public.sync_seq'') where seq is null', t);
    execute format('alter table public.%I alter column seq set not null', t);

    execute format(
      'create index if not exists idx_%s_user_seq on public.%I (user_id, seq)', t, t);

    execute format('drop trigger if exists trg_%s_sync_meta on public.%I', t, t);
    execute format(
      'create trigger trg_%s_sync_meta before insert or update on public.%I
         for each row execute function public.set_sync_meta()', t, t);

    execute format('drop trigger if exists trg_%s_notify on public.%I', t, t);
    execute format(
      'create trigger trg_%s_notify after insert or update on public.%I
         for each row execute function public.notify_sync_change()', t, t);
  end loop;
end;
$$;

-- user_settings / agent_preferences / agent_conversations are keyed by
-- user_id, not id. The doorbell reads new.id; give those tables the column
-- the function expects by exposing user_id under that name is NOT possible
-- in a trigger generically, so the three single-row tables get their own
-- notify wrapper.
create or replace function public.notify_sync_change_userkeyed()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform realtime.send(
    jsonb_build_object(
      'table',     tg_table_name,
      'id',        new.user_id,
      'seq',       new.seq,
      'device_id', new.device_id,
      'deleted',   new.deleted_at is not null
    ),
    'change',
    'user:' || new.user_id::text,
    true
  );
  return new;
end;
$$;

do $$
declare
  t text;
begin
  foreach t in array array['user_settings', 'agent_preferences', 'agent_conversations'] loop
    execute format('drop trigger if exists trg_%s_notify on public.%I', t, t);
    execute format(
      'create trigger trg_%s_notify after insert or update on public.%I
         for each row execute function public.notify_sync_change_userkeyed()', t, t);
  end loop;
end;
$$;

-- ============================================================
-- 5. Private channel authorization: a user may subscribe ONLY to
--    `user:<their uid>`. One string comparison — RLS complexity here is
--    paid on every join. Receiving = SELECT; clients never send, so no
--    INSERT policy.
--    Dashboard prerequisite (cannot be expressed in SQL): Realtime Settings
--    → disable "Allow public access", otherwise `private` is not enforced.
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
-- 6. One-call delta pull. SECURITY INVOKER (the default) so every table's
--    RLS applies — the function sees only the caller's rows. Ordered by
--    seq so a page boundary is a clean cursor; `row` is the full row as
--    jsonb so the existing RowReader-based decoders apply unchanged.
-- ============================================================
create or replace function public.sync_changes(since_seq bigint, page_limit int default 500)
returns table (tbl text, seq bigint, row jsonb)
language sql
stable
set search_path = ''
as $$
  select * from (
    select 'events'::text              as tbl, e.seq, to_jsonb(e) as row from public.events e              where e.seq > since_seq
    union all
    select 'event_logs',                     l.seq, to_jsonb(l)        from public.event_logs l          where l.seq > since_seq
    union all
    select 'event_feedback',                 f.seq, to_jsonb(f)        from public.event_feedback f      where f.seq > since_seq
    union all
    select 'todo_lists',                     t.seq, to_jsonb(t)        from public.todo_lists t          where t.seq > since_seq
    union all
    select 'event_types',                    y.seq, to_jsonb(y)        from public.event_types y         where y.seq > since_seq
    union all
    select 'skill_insights',                 s.seq, to_jsonb(s)        from public.skill_insights s      where s.seq > since_seq
    union all
    select 'user_settings',                  u.seq, to_jsonb(u)        from public.user_settings u       where u.seq > since_seq
    union all
    select 'agent_preferences',              p.seq, to_jsonb(p)        from public.agent_preferences p   where p.seq > since_seq
    union all
    select 'agent_conversations',            c.seq, to_jsonb(c)        from public.agent_conversations c where c.seq > since_seq
  ) changes
  order by seq
  limit greatest(1, least(page_limit, 2000));
$$;

-- The server head, so a client can tell "I am caught up" without a pull.
create or replace function public.sync_head()
returns bigint
language sql
stable
set search_path = ''
as $$
  select coalesce((
    select max(m) from (
      select max(seq) m from public.events
      union all select max(seq) from public.event_logs
      union all select max(seq) from public.event_feedback
      union all select max(seq) from public.todo_lists
      union all select max(seq) from public.event_types
      union all select max(seq) from public.skill_insights
      union all select max(seq) from public.user_settings
      union all select max(seq) from public.agent_preferences
      union all select max(seq) from public.agent_conversations
    ) heads
  ), 0);
$$;

grant execute on function public.sync_changes(bigint, int) to authenticated;
grant execute on function public.sync_head() to authenticated;
