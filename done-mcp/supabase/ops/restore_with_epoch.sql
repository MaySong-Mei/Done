-- The LAST step of every restore of the synced tables (survey M2).
-- Run it inside the restore's own transaction, after the restored data is in:
--   psql --single-transaction ... --file data.sql --file restore_with_epoch.sql
-- (ops/restore.sh does exactly that). Never run a restore without it.
-- Run on its own (after the fact, or as the re-enable reset), use
--   psql --single-transaction -v ON_ERROR_STOP=1 -f restore_with_epoch.sql
-- so that when the guard below raises, the upsert is undone with it.
--
-- One statement: floor := the restored sync_seq value, epoch := a new random
-- value. Because it shares the restore's transaction, no client can read the
-- restored rows under the old epoch, and every seq a client sees above the
-- floor was written after the restore. Do not setval sync_seq upward to "get
-- ahead of the cursors" (survey §B.4 C3): that hides the rewind instead of
-- announcing it.
--
-- An upsert, not an update: a data dump that left sync_epoch out, restored
-- after the table was emptied, would otherwise leave no row at all.

-- Remember the epoch in place before the step (the restored dump's, or the
-- live one when run after the fact), so the check below can prove it changed.
do $$
begin
  perform set_config('done.restore_prev_epoch',
                     coalesce((select max(epoch) from public.sync_epoch), ''), false);
end;
$$;

insert into public.sync_epoch (epoch, floor, changed_at)
select gen_random_uuid()::text,
       -- a sequence that was never called hands out last_value itself next,
       -- so the restored range ends one below it
       case when s.is_called then s.last_value else s.last_value - 1 end,
       now()
from public.sync_seq s
on conflict ((true)) do update
  set epoch = excluded.epoch, floor = excluded.floor, changed_at = excluded.changed_at;

-- Abort the whole restore if the row is not exactly what was just written:
-- one row, the floor the sequence implies, and an epoch other than before.
do $$
declare
  n int;
  f bigint;
  e text;
  want bigint;
  prev text := current_setting('done.restore_prev_epoch', true);
begin
  select count(*), max(floor), max(epoch) into n, f, e from public.sync_epoch;
  select case when is_called then last_value else last_value - 1 end into want from public.sync_seq;
  if n <> 1 or f is distinct from want then
    raise exception 'restore_with_epoch: sync_epoch has % rows, floor % (sync_seq says %); restore aborted', n, f, want;
  end if;
  if e is null or e = '' or e = coalesce(prev, '') then
    raise exception 'restore_with_epoch: epoch % did not change (was %); restore aborted', e, prev;
  end if;
end;
$$;
