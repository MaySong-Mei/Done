-- The epoch step (design §6.6 "纪元行与暂停位"): the LAST step of every restore
-- of the synced tables, the reset after a rollback (ops/reenable.sql includes
-- it), and the immediate repair after a restore that bypassed ops/restore.sh.
-- Run on its own as one transaction:
--   psql "$DATABASE_URL" --single-transaction -v ON_ERROR_STOP=1 -f ops/restore_with_epoch.sql
-- No arguments. ops/restore.sh sets `done.restore_dump_epoch` before including
-- it; on its own the ledger record carries dump_epoch = null.
--
-- What it does, in this order:
--   1. locks the nine synced tables in SHARE ROW EXCLUSIVE mode, so no write
--      can take a seq between the reading of kept_max and the commit of the
--      new epoch (a number taken in that gap would be recorded as "kept" and
--      a device holding it would never be prompted);
--   2. kept_max := the highest seq on any synced row, tombstones included;
--   3. lifts sync_seq to kept_max if it is below (never lowers it; a restore
--      without this step rewinds the counter through the dump's setval);
--   4. new random epoch; appends {epoch, kept_max, dump_epoch} to the ledger
--      `restores`; paused := true; rollback := false;
--   5. guard: exactly one row, the epoch changed, the ledger's last record
--      names the new epoch, paused is true, the counter is at or above
--      kept_max. A failed guard raises, and --single-transaction undoes
--      everything the step did.
-- The operator clears `paused` by hand after post_apply_checks.sql is green.
--
-- An upsert, not an update: a restore into a new project that forgot to copy
-- sync_epoch over would otherwise leave no row at all (the ledger then starts
-- empty — design §9.37 (1)).

lock table
  public.events, public.event_logs, public.event_feedback, public.todo_lists,
  public.event_types, public.skill_insights, public.user_settings,
  public.agent_preferences, public.agent_conversations
in share row exclusive mode;

do $$
declare
  t          text;
  m          bigint;
  kept_max   bigint := 0;
  handed     bigint;
  prev       text;
  new_epoch  text := gen_random_uuid()::text;
  dump_epoch text := nullif(current_setting('done.restore_dump_epoch', true), '');
  rec        jsonb;
begin
  foreach t in array array[
    'events', 'event_logs', 'event_feedback', 'todo_lists', 'event_types',
    'skill_insights', 'user_settings', 'agent_preferences', 'agent_conversations'
  ] loop
    execute format('select coalesce(max(seq), 0) from public.%I', t) into m;
    if m > kept_max then kept_max := m; end if;
  end loop;

  -- a never-called sequence hands out last_value itself next
  select case when is_called then last_value else last_value - 1 end into handed from public.sync_seq;
  if kept_max > handed then
    perform setval('public.sync_seq', kept_max, true);
  end if;

  select max(epoch) into prev from public.sync_epoch;
  perform set_config('done.restore_prev_epoch', coalesce(prev, ''), false);
  perform set_config('done.restore_kept_max', kept_max::text, false);

  rec := jsonb_build_object('epoch', new_epoch, 'kept_max', kept_max, 'dump_epoch', dump_epoch);
  insert into public.sync_epoch (epoch, paused, rollback, restores, changed_at)
  values (new_epoch, true, false, jsonb_build_array(rec), now())
  on conflict ((true)) do update
    set epoch      = excluded.epoch,
        paused     = true,
        rollback   = false,
        restores   = public.sync_epoch.restores || excluded.restores,
        changed_at = excluded.changed_at;
end;
$$;

-- The guard. Abort the whole step (and the restore around it) unless the row
-- is exactly what was just written.
do $$
declare
  n        int;
  e        text;
  p        boolean;
  last_e   text;
  handed   bigint;
  prev     text   := current_setting('done.restore_prev_epoch', true);
  kept_max bigint := current_setting('done.restore_kept_max', true)::bigint;
begin
  select count(*), max(epoch), bool_and(paused), max(restores -> -1 ->> 'epoch')
    into n, e, p, last_e from public.sync_epoch;
  select case when is_called then last_value else last_value - 1 end into handed from public.sync_seq;
  if n <> 1 then
    raise exception 'restore_with_epoch: sync_epoch has % rows; restore aborted', n;
  end if;
  if e is null or e = '' or e = coalesce(prev, '') then
    raise exception 'restore_with_epoch: epoch % did not change (was %); restore aborted', e, prev;
  end if;
  if last_e is distinct from e then
    raise exception 'restore_with_epoch: ledger last epoch % is not the current epoch %; restore aborted', last_e, e;
  end if;
  if not coalesce(p, false) then
    raise exception 'restore_with_epoch: paused is not true; restore aborted';
  end if;
  if handed < kept_max then
    raise exception 'restore_with_epoch: sync_seq handed out % but kept_max is %; restore aborted', handed, kept_max;
  end if;
end;
$$;

select 'restore_with_epoch: epoch=' || epoch
    || ' kept_max=' || (restores -> -1 ->> 'kept_max')
    || ' dump_epoch=' || coalesce(restores -> -1 ->> 'dump_epoch', 'null')
    || ' ledger=' || jsonb_array_length(restores)
    || ' paused=' || paused
    || ' rollback=' || rollback
  as epoch_step
from public.sync_epoch;
