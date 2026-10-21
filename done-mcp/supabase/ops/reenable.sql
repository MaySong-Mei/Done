-- Re-enable the sync change feed after ops/rollback.sql (design §7 handoff
-- (8), §6.6). Run it in one transaction:
--
--   psql "$DATABASE_URL" --single-transaction -v ON_ERROR_STOP=1 -f ops/reenable.sql
--
-- then post_apply_checks.sql, then `update public.sync_epoch set paused =
-- false` (ops/README.md "Rollback").
--
-- Three steps, one transaction:
--   1. clear sync_epoch.rollback (015 refuses to run on a rolled-back server,
--      see its guard; inside this transaction nothing else sees the bit
--      cleared before the triggers are back), then drop the seq column
--      default and the stamp trigger rollback.sql added (the trigger assigns
--      seq again; P1 refuses a stamp trigger and P8 a default outside a
--      rollback);
--   2. rerun migration 015, which recreates the sync triggers, backfills the
--      version log for rows inserted in the window (their version_id came
--      from the column default) and leaves the data, the tombstones and the
--      epoch row alone;
--   3. the epoch step (restore_with_epoch.sql): a new epoch, a ledger record
--      {epoch, kept_max = max(seq) over the nine tables, dump_epoch = null},
--      rollback := false, paused stays true. Every device resets on the new
--      epoch and catches up by the §6.6 rules: an UPDATE made in the window
--      took a new seq from the stamp trigger, so a clean device adopts it
--      (the device's copy is its ancestor, no prompt); a row physically
--      deleted in the window is POSTed back with its parent.

set client_min_messages = warning;  -- 015's "already exists, skipping" notices are expected on a rerun

update public.sync_epoch set rollback = false;

do $$
declare
  t text;
  tables text[] := array[
    'events', 'event_logs', 'event_feedback', 'todo_lists', 'event_types',
    'skill_insights', 'user_settings', 'agent_preferences', 'agent_conversations'
  ];
begin
  foreach t in array tables loop
    execute format('alter table public.%I alter column seq drop default', t);
    execute format('drop trigger if exists trg_%s_sync_stamp on public.%I', t, t);
  end loop;
end;
$$;
drop function if exists public.sync_stamp_seq();

\ir ../migrations/015_sync_change_feed.sql

\ir restore_with_epoch.sql
