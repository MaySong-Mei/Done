-- Roll back the sync change feed of migration 015 WITHOUT losing data
-- (design §7 handoff (8), §6.6 "服务端写闸" / "回滚期间盖号").
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f ops/rollback.sql          # waits W = 35 s
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -v W=0 -f ops/rollback.sql   # bench only
--
-- NOT under --single-transaction: the first statement must commit on its
-- own, then the script waits, then the drops run in one transaction.
--
-- Step 1 (commits by itself): `update sync_epoch set paused = true,
--   rollback = true`. From this commit on the write gate (which stays)
--   refuses every write that carries an X-Sync-Epoch header with
--   `sync_paused`, and lets header-less writes (agent, MCP, edge functions,
--   the old build) through because `rollback` is set.
-- Step 2: wait W = T + S (about 35 s): the write-request time limit of a
--   client (T, 15 s) plus the server's execution bound for a request it had
--   already accepted (S). Nothing else is waited for; the gate holds the
--   rest.
-- Step 3 (one transaction), per synced table:
--   * gives `seq` the column default nextval('public.sync_seq'), BEFORE the
--     triggers go. `seq` is NOT NULL without a default, and NOT NULL is
--     checked before ON CONFLICT is resolved, so with the triggers gone and
--     no default every INSERT and every upsert that leaves seq out (the old
--     build's upload, MCP) fails 23502, even an upsert that hits an existing
--     row (bench S18 shows that counterfactual);
--   * drops the sync triggers: trg_<t>_sync_meta, trg_<t>_sync_version, the
--     doorbell pair trg_<t>_notify_ins / _notify_upd, and trg_<t>_tombstone;
--   * creates the stamp trigger trg_<t>_sync_stamp (BEFORE UPDATE, row):
--     `new.seq := nextval('public.sync_seq')`, nothing else. An UPDATE in
--     the window must NOT keep its old seq: the restore ledger judges by
--     number, and a number naming two versions hides a lost one (§6.6).
-- What it keeps: every row and column (seq, deleted_at, tombstones, the
-- version columns), the write gate trg_<t>_sync_gate, the TRUNCATE guard
-- trg_<t>_no_truncate, sync_seq, sync_epoch, sync_versions, sync_changes,
-- is_ancestor, the realtime policy. While rolled back, an UPDATE takes a new
-- seq from the stamp trigger but keeps its version_id, a DELETE is physical,
-- an INSERT takes a seq from the default and a version_id from its default,
-- nothing rings and nothing is logged. post_apply_checks.sql fails P1 and P8
-- until the re-enable; P10 stays green, P12 may go red for rows inserted in
-- the window (the re-enable's rerun of 015 backfills them).
--
-- Re-enable (ops/README.md "Rollback"): ops/reenable.sql (drops the default
-- and the stamp trigger, reruns 015, then runs the epoch step: new epoch,
-- ledger record, rollback := false, paused stays true), then
-- post_apply_checks.sql, then `update sync_epoch set paused = false`.
--
-- The check at the end raises on any table not in the rolled-back shape;
-- inside the transaction that undoes step 3 (step 1 stays: the server is
-- paused either way, which is the safe side).

\set ON_ERROR_STOP on
set lock_timeout = '3s';
set client_min_messages = warning;  -- the drop-if-exists notices are noise here

-- step 1: pause, and let header-less writes through
update public.sync_epoch set paused = true, rollback = true;
do $$
begin
  if (select count(*) from public.sync_epoch where paused and rollback) <> 1 then
    raise exception 'rollback: sync_epoch is not exactly one paused row with rollback set';
  end if;
end;
$$;

-- step 2: W = T + S
\if :{?W}
\else
  \set W 35
\endif
\echo rollback: paused; waiting W = :W s for accepted requests to finish
select pg_sleep(:W);

-- step 3
begin;

create or replace function public.sync_stamp_seq()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.seq := nextval('public.sync_seq');
  return new;
end;
$$;

do $$
declare
  t text;
  tables text[] := array[
    'events', 'event_logs', 'event_feedback', 'todo_lists', 'event_types',
    'skill_insights', 'user_settings', 'agent_preferences', 'agent_conversations'
  ];
begin
  foreach t in array tables loop
    execute format('alter table public.%I alter column seq set default nextval(''public.sync_seq'')', t);
    execute format('drop trigger if exists trg_%s_sync_meta on public.%I', t, t);
    execute format('drop trigger if exists trg_%s_sync_version on public.%I', t, t);
    execute format('drop trigger if exists trg_%s_notify on public.%I', t, t);  -- v1 name
    execute format('drop trigger if exists trg_%s_notify_ins on public.%I', t, t);
    execute format('drop trigger if exists trg_%s_notify_upd on public.%I', t, t);
    execute format('drop trigger if exists trg_%s_tombstone on public.%I', t, t);
    execute format('drop trigger if exists trg_%s_sync_stamp on public.%I', t, t);
    execute format(
      'create trigger trg_%s_sync_stamp before update on public.%I
         for each row execute function public.sync_stamp_seq()', t, t);
  end loop;
end;
$$;

-- Abort unless every synced table is in the rolled-back shape: the seq
-- default present, no sync trigger left, the TRUNCATE guard, the write gate
-- and the stamp trigger enabled, and the epoch row paused with rollback set.
do $$
declare
  bad text;
begin
  with tables(t) as (
    select unnest(array[
      'events', 'event_logs', 'event_feedback', 'todo_lists', 'event_types',
      'skill_insights', 'user_settings', 'agent_preferences', 'agent_conversations'])
  ), judged as (
    select t,
           pg_get_expr(d.adbin, d.adrelid) as seq_default,
           (select string_agg(tg.tgname, ',') from pg_trigger tg
             where tg.tgrelid = to_regclass('public.' || t) and not tg.tgisinternal
               and tg.tgname ~ ('^trg_' || t || '_(sync_meta|sync_version|notify|notify_ins|notify_upd|tombstone)$')) as sync_triggers,
           (select tg.tgenabled from pg_trigger tg
             where tg.tgrelid = to_regclass('public.' || t) and tg.tgname = 'trg_' || t || '_no_truncate') as guard,
           (select tg.tgenabled from pg_trigger tg
             where tg.tgrelid = to_regclass('public.' || t) and tg.tgname = 'trg_' || t || '_sync_gate') as gate,
           (select tg.tgenabled from pg_trigger tg
             where tg.tgrelid = to_regclass('public.' || t) and tg.tgname = 'trg_' || t || '_sync_stamp') as stamp
    from tables
    left join pg_attribute a on a.attrelid = to_regclass('public.' || t) and a.attname = 'seq'
    left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
  )
  select string_agg(format('%s(default=%s triggers=%s guard=%s gate=%s stamp=%s)', t, coalesce(seq_default, 'none'),
                           coalesce(sync_triggers, '-'), coalesce(guard::text, 'absent'),
                           coalesce(gate::text, 'absent'), coalesce(stamp::text, 'absent')), ', ')
    into bad
  from judged
  where (seq_default is distinct from 'nextval(''sync_seq''::regclass)'
         and seq_default is distinct from 'nextval(''public.sync_seq''::regclass)')
     or sync_triggers is not null
     or guard is distinct from 'O'
     or gate is distinct from 'O'
     or stamp is distinct from 'O';
  if bad is not null then
    raise exception 'rollback: not in the rolled-back shape: %', bad;
  end if;
  if (select count(*) from public.sync_epoch where paused and rollback) <> 1 then
    raise exception 'rollback: not in the rolled-back shape: sync_epoch is not one paused row with rollback set';
  end if;
end;
$$;

commit;

notify pgrst, 'reload schema';
