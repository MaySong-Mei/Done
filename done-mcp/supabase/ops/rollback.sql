-- Roll back the sync change feed of migration 015 WITHOUT losing data
-- (design Docs/sync/00-realtime-sync-design.md §7 handoff (8), D8).
-- Turn the clients' sync switch off first; this file is the server half.
--
--   psql "$DATABASE_URL" --single-transaction -v ON_ERROR_STOP=1 -f ops/rollback.sql
--
-- What it does, per synced table:
--   * gives `seq` the column default nextval('public.sync_seq'), BEFORE the
--     triggers go. `seq` is NOT NULL without a default, and NOT NULL is
--     checked before ON CONFLICT is resolved, so with the triggers gone and
--     no default every INSERT and every upsert that leaves seq out (the king
--     build's upload, MCP) fails 23502, even an upsert that hits an existing
--     row (bench S18 shows that counterfactual);
--   * drops the three sync triggers: trg_<t>_sync_meta, the doorbell pair
--     trg_<t>_notify_ins / _notify_upd, and trg_<t>_tombstone.
-- What it keeps: every row and column (seq, deleted_at, tombstones), the
-- TRUNCATE guard trg_<t>_no_truncate, sync_seq, sync_epoch, sync_changes,
-- the realtime policy. While rolled back, an UPDATE keeps the row's old seq,
-- a DELETE is physical, an INSERT takes a seq from the default, and nothing
-- rings. post_apply_checks.sql fails P1 and P8 until the re-enable.
--
-- Re-enable (ops/README.md "Rollback"): ops/reenable.sql (drops the default,
-- reruns 015), then post_apply_checks.sql, then restore_with_epoch.sql as
-- the reset every device takes.
--
-- One DO block, so the defaults and the drops land together or not at all
-- even without --single-transaction. The check after it raises on any table
-- not in the rolled-back shape; under --single-transaction that undoes the
-- whole file.

set lock_timeout = '3s';
set client_min_messages = warning;  -- the drop-if-exists notices are noise here

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
    execute format('drop trigger if exists trg_%s_notify on public.%I', t, t);  -- v1 name
    execute format('drop trigger if exists trg_%s_notify_ins on public.%I', t, t);
    execute format('drop trigger if exists trg_%s_notify_upd on public.%I', t, t);
    execute format('drop trigger if exists trg_%s_tombstone on public.%I', t, t);
  end loop;
end;
$$;

-- Abort unless every synced table is in the rolled-back shape: the seq
-- default present, no sync trigger left, the TRUNCATE guard still enabled.
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
               and tg.tgname <> 'trg_' || t || '_no_truncate'
               and tg.tgname ~ ('^trg_' || t || '_(sync_meta|notify|notify_ins|notify_upd|tombstone)$')) as sync_triggers,
           (select tg.tgenabled from pg_trigger tg
             where tg.tgrelid = to_regclass('public.' || t) and tg.tgname = 'trg_' || t || '_no_truncate') as guard
    from tables
    left join pg_attribute a on a.attrelid = to_regclass('public.' || t) and a.attname = 'seq'
    left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
  )
  select string_agg(format('%s(default=%s triggers=%s guard=%s)', t, coalesce(seq_default, 'none'),
                           coalesce(sync_triggers, '-'), coalesce(guard::text, 'absent')), ', ')
    into bad
  from judged
  where (seq_default is distinct from 'nextval(''sync_seq''::regclass)'
         and seq_default is distinct from 'nextval(''public.sync_seq''::regclass)')
     or sync_triggers is not null
     or guard is distinct from 'O';
  if bad is not null then
    raise exception 'rollback: not in the rolled-back shape: %', bad;
  end if;
end;
$$;

notify pgrst, 'reload schema';
