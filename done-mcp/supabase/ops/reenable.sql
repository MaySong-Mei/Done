-- Re-enable the sync change feed after ops/rollback.sql (design §7 handoff
-- (8)). Run it in one transaction:
--
--   psql "$DATABASE_URL" --single-transaction -v ON_ERROR_STOP=1 -f ops/reenable.sql
--
-- then post_apply_checks.sql, then restore_with_epoch.sql (ops/README.md
-- "Rollback"). The epoch step is the reset: it gives every device a new
-- epoch with floor = the current sync_seq value, so every baseline a device
-- holds sits at or below the floor and takes the normal three-way compare
-- with skip turned off (design §6.6). That is what lets a clean device adopt
-- an UPDATE made while the triggers were gone, which kept its old seq.
--
-- Two steps: drop the seq column default rollback.sql added (the trigger
-- assigns seq again, and P8 fails while a default is left), then rerun
-- migration 015, which recreates the triggers and leaves the data, the
-- tombstones and the epoch row alone.

set client_min_messages = warning;  -- 015's "already exists, skipping" notices are expected on a rerun

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
  end loop;
end;
$$;

\ir ../migrations/015_sync_change_feed.sql
