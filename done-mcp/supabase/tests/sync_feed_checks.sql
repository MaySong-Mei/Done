-- Bench for migration 015 (sync change feed) — SQL-side checks.
-- Run against a local `supabase start` stack as the postgres role:
--   psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 -f sync_feed_checks.sql
-- Every check prints PASS/FAIL with the observed values; the script raises at
-- the end when any check failed, so psql exits non-zero.
-- A second and third session are opened through dblink (the server connects
-- back to itself over its own address, which is scram-authenticated; the
-- loopback address is trust-authenticated and dblink refuses that for a
-- non-superuser).
-- Fixture users are inserted straight into auth.users and erased at the end;
-- the erase itself is one of the checks (S6).

\set QUIET on
\pset pager off
\set ON_ERROR_STOP on
-- query output is silenced until the results table; \echo still prints
\o /dev/null

create extension if not exists dblink;

create temp table bench (ord serial, id text, claim text, pass boolean, observed text);
create function pg_temp.rec(p_id text, p_claim text, p_pass boolean, p_observed text)
returns void language sql as $$
  insert into bench (id, claim, pass, observed) values (p_id, p_claim, p_pass, p_observed);
$$;

select 'dbname=' || current_database() || ' user=postgres password=postgres host='
       || host(inet_server_addr()) || ' port=' || inet_server_port()::text as conninfo \gset
select gen_random_uuid() as u \gset
select gen_random_uuid() as v \gset
select gen_random_uuid() as w \gset
select format('{"sub":"%s","role":"authenticated"}', :'u') as claims_u \gset

-- leftovers of an aborted earlier run
delete from auth.users where email in ('bench-u@local.test', 'bench-v@local.test', 'bench-w@local.test');

insert into auth.users (id, email, aud, role, email_confirmed_at, raw_app_meta_data, raw_user_meta_data)
values (:'u', 'bench-u@local.test', 'authenticated', 'authenticated', now(), '{}', '{}'),
       (:'v', 'bench-v@local.test', 'authenticated', 'authenticated', now(), '{}', '{}');

-- helper: open a dblink session that acts as user U through RLS
create function pg_temp.as_user(conn text, uid uuid) returns void language plpgsql as $$
begin
  perform dblink_exec(conn, format('set request.jwt.claims = %L',
                                   format('{"sub":"%s","role":"authenticated"}', uid)));
  perform dblink_exec(conn, 'set role authenticated');
end $$;

-- ============================================================
-- S1  seq order = commit order; a user lock does not block another user
-- ============================================================
\echo '--- S1'
select gen_random_uuid() as a1 \gset
select gen_random_uuid() as b1 \gset
select gen_random_uuid() as v1 \gset
select dblink_connect('B', :'conninfo');
select dblink_connect('C', :'conninfo');
select dblink_exec('C', 'set statement_timeout = ''3s''');
select pid as b_pid from dblink('B', 'select pg_backend_pid()') as t(pid int) \gset

begin;
insert into public.events (id, user_id, kind, title) values (:'a1', :'u', 'calendar', 'S1 A') returning seq as a1_seq \gset
select dblink_send_query('B', format('insert into public.events (id, user_id, kind, title) values (%L, %L, ''calendar'', ''S1 B'') returning seq', :'b1', :'u'));
select pg_sleep(0.5);
select dblink_is_busy('B') as b_busy \gset
select coalesce(wait_event_type, '') as b_wait_type, coalesce(wait_event, '') as b_wait_event
from pg_stat_activity where pid = :b_pid \gset
select pg_temp.rec('S1', 'second session of the same user blocks on the advisory lock while A is open',
  :b_busy = 1 and :'b_wait_type' = 'Lock' and :'b_wait_event' = 'advisory',
  format('dblink_is_busy=%s wait_event_type=%s wait_event=%s', :b_busy, :'b_wait_type', :'b_wait_event'));

select coalesce((select seq from dblink('C', format('insert into public.events (id, user_id, kind, title) values (%L, %L, ''calendar'', ''S1 V'') returning seq', :'v1', :'v'), false) as t(seq bigint)), -1) as v1_seq \gset
select pg_temp.rec('S1', 'a different user is not blocked by A''s open transaction',
  :v1_seq > 0, format('V insert completed with seq=%s while A (seq=%s) still open', :v1_seq, :a1_seq));

select pg_temp.as_user('C', :'u');
select coalesce(string_agg(seq::text, ','), '') as c_seen_open
from dblink('C', format('select seq from public.sync_changes(%s, 100)', :a1_seq - 1)) as t(seq bigint) \gset
select pg_temp.rec('S1', 'a third session pulling as U sees neither A (open) nor B (blocked)',
  :'c_seen_open' = '', format('sync_changes(since := N-1) as U returned seqs [%s]', :'c_seen_open'));
commit;

select seq as b1_seq from dblink_get_result('B') as t(seq bigint) \gset
-- an async dblink query is fully consumed only once an empty result has been fetched
select dblink_get_result('B');
select pg_temp.rec('S1', 'B completes after A commits with seq > N',
  :b1_seq > :a1_seq, format('A seq=%s, B seq=%s', :a1_seq, :b1_seq));
select string_agg(seq::text, ',' order by ord) as c_seen_after
from (select row_number() over () as ord, seq from dblink('C', format('select seq from public.sync_changes(%s, 100)', :a1_seq - 1)) as t(seq bigint)) s \gset
select pg_temp.rec('S1', 'after both commit, the pull as U returns A then B in seq order',
  :'c_seen_after' = format('%s,%s', :a1_seq, :b1_seq), format('returned [%s]', :'c_seen_after'));

-- ============================================================
-- S2  DELETE becomes a tombstone (as postgres)
-- ============================================================
\echo '--- S2'
delete from public.events where id = :'a1';
select count(*) as n, coalesce(max(seq), 0) as seq2, bool_and(deleted_at is not null) as tomb
from public.events where id = :'a1' \gset
select pg_temp.rec('S2', 'events: physical delete as postgres leaves a tombstone with a new seq',
  :n = 1 and :'tomb' = 't' and :seq2 > :a1_seq, format('rows=%s deleted_at set=%s seq %s -> %s', :n, :'tomb', :a1_seq, :seq2));
select count(*) as n from dblink('C', format('select seq from public.sync_changes(%s, 100) where tbl = ''events'' and data->>''id'' = %L and data->>''deleted_at'' is not null', :seq2 - 1, :'a1')) as t(seq bigint) \gset
select pg_temp.rec('S2', 'events: the tombstone is in the feed with deleted_at set',
  :n = 1, format('feed rows with deleted_at at seq %s: %s', :seq2, :n));

insert into public.user_settings (user_id, settings) values (:'u', '{"a":1}') returning seq as us_seq \gset
delete from public.user_settings where user_id = :'u';
select count(*) as n, coalesce(max(seq), 0) as us_seq2, bool_and(deleted_at is not null) as tomb
from public.user_settings where user_id = :'u' \gset
select pg_temp.rec('S2', 'user_settings: delete by user_id leaves a tombstone with a new seq',
  :n = 1 and :'tomb' = 't' and :us_seq2 > :us_seq, format('rows=%s deleted_at set=%s seq %s -> %s', :n, :'tomb', :us_seq, :us_seq2));

-- ============================================================
-- S3  tombstone survives an upsert that sets deleted_at = null
-- ============================================================
\echo '--- S3'
select deleted_at as a1_deleted_at from public.events where id = :'a1' \gset
insert into public.events (id, user_id, kind, title, deleted_at) values (:'a1', :'u', 'calendar', 'S3 resurrect', null)
on conflict (id) do update set title = excluded.title, deleted_at = excluded.deleted_at;
select deleted_at::text = :'a1_deleted_at' as kept, title as t from public.events where id = :'a1' \gset
select pg_temp.rec('S3', 'upsert with explicit deleted_at = null keeps the tombstone (title still updates)',
  :'kept' = 't' and :'t' = 'S3 resurrect', format('deleted_at kept=%s title=%s', :'kept', :'t'));
insert into public.events (id, user_id, kind, title) values (:'a1', :'u', 'calendar', 'S3 resurrect two')
on conflict (id) do update set title = excluded.title;
select deleted_at::text = :'a1_deleted_at' as kept from public.events where id = :'a1' \gset
select pg_temp.rec('S3', 'upsert that omits deleted_at keeps the tombstone', :'kept' = 't', format('deleted_at kept=%s', :'kept'));

-- ============================================================
-- S4  content-identical upsert is a no-op
-- ============================================================
\echo '--- S4'
select gen_random_uuid() as s4 \gset
insert into public.events (id, user_id, kind, title, note) values (:'s4', :'u', 'todo', 'S4', 'same') returning seq as s4_seq \gset
select count(*) as msgs_before from realtime.messages where topic = 'user:' || :'u' \gset
insert into public.events (id, user_id, kind, title, note, updated_at) values (:'s4', :'u', 'todo', 'S4', 'same', now())
on conflict (id) do update set title = excluded.title, note = excluded.note, updated_at = excluded.updated_at;
select seq as s4_seq2 from public.events where id = :'s4' \gset
select count(*) as msgs_after from realtime.messages where topic = 'user:' || :'u' \gset
select count(*) as n from dblink('C', format('select seq from public.sync_changes(%s, 100)', :s4_seq)) as t(seq bigint) \gset
select pg_temp.rec('S4', 'identical upsert: seq unchanged, no doorbell, nothing past the cursor',
  :s4_seq = :s4_seq2 and :msgs_before = :msgs_after and :n = 0,
  format('seq %s -> %s, messages %s -> %s, feed rows after cursor=%s', :s4_seq, :s4_seq2, :msgs_before, :msgs_after, :n));
select last_value as seq_after_noop from public.sync_seq \gset
select pg_temp.rec('S4', 'sequence burned by the INSERT arm of the no-op upsert (gap, documented §9.16)',
  :seq_after_noop > :s4_seq, format('sync_seq last_value=%s after row seq=%s', :seq_after_noop, :s4_seq));

-- ============================================================
-- S5  one doorbell frame per statement per user
-- ============================================================
\echo '--- S5'
select count(*) as msgs_before from realtime.messages where topic = 'user:' || :'u' \gset
insert into public.events (id, user_id, kind, title)
select gen_random_uuid(), :'u', 'todo', 'S5 batch ' || g from generate_series(1, 20) g;
select max(seq) as batch_max from public.events where user_id = :'u' and title like 'S5 batch %' \gset
select count(*) as n, coalesce(max((payload->>'seq')::bigint), 0) as frame_seq, coalesce(max(payload->>'table'), '') as frame_tbl, bool_and(private) as priv, max(event) as ev
from (select * from realtime.messages where topic = 'user:' || :'u' order by inserted_at desc, id limit (select count(*) from realtime.messages where topic = 'user:' || :'u') - :msgs_before) m \gset
select pg_temp.rec('S5', 'one multi-row insert statement rings once with seq = max seq written',
  :n = 1 and :frame_seq = :batch_max and :'frame_tbl' = 'events' and :'priv' = 't' and :'ev' = 'change',
  format('frames=%s payload.seq=%s max(seq)=%s table=%s private=%s event=%s', :n, :frame_seq, :batch_max, :'frame_tbl', :'priv', :'ev'));

select count(*) as msgs_before from realtime.messages where topic = 'user:' || :'u' \gset
select set_config('bench.u', :'u', false);
do $$
declare i int;
begin
  for i in 1..20 loop
    insert into public.events (id, user_id, kind, title) values (gen_random_uuid(), current_setting('bench.u')::uuid, 'todo', 'S5 single ' || i);
  end loop;
end $$;
select count(*) - :msgs_before as n from realtime.messages where topic = 'user:' || :'u' \gset
select pg_temp.rec('S5', 'twenty single-row statements ring twenty times', :n = 20, format('frames=%s', :n));

select count(*) as msgs_before from realtime.messages where topic = 'user:' || :'u' \gset
select string_agg(quote_literal(id), ',') as five_ids from (select id from public.events where user_id = :'u' and title like 'S5 single %' limit 5) s \gset
delete from public.events where id in (:five_ids);
select count(*) - :msgs_before as n from realtime.messages where topic = 'user:' || :'u' \gset
select pg_temp.rec('S5', 'multi-row DELETE rewritten per row rings once per row (§9.15 records the count)', :n = 5, format('DELETE of five ids produced %s frames', :n));

-- ============================================================
-- S6  account erase stays physical
-- ============================================================
\echo '--- S6'
insert into auth.users (id, email, aud, role, email_confirmed_at, raw_app_meta_data, raw_user_meta_data)
values (:'w', 'bench-w@local.test', 'authenticated', 'authenticated', now(), '{}', '{}');
insert into public.events (id, user_id, kind, title) values (gen_random_uuid(), :'w', 'todo', 'S6');
insert into public.event_logs (id, user_id, event_id, occurrence_date) values ('single|' || gen_random_uuid(), :'w', gen_random_uuid(), now());
insert into public.event_feedback (id, user_id, event_id, occurrence_date) values ('single|' || gen_random_uuid(), :'w', gen_random_uuid(), now());
insert into public.todo_lists (id, user_id, title, color_name) values (gen_random_uuid(), :'w', 'S6', 'blue');
insert into public.event_types (id, user_id, title, color_hex) values (gen_random_uuid(), :'w', 'S6', '#000000');
insert into public.skill_insights (id, user_id, skill_name, points, date, event_title) values (gen_random_uuid(), :'w', 'S6', 1, now(), 'S6');
insert into public.user_settings (user_id, settings) values (:'w', '{}');
insert into public.agent_preferences (user_id) values (:'w');
insert into public.agent_conversations (user_id) values (:'w');
-- one of them is tombstoned first, to show a tombstone is erased too
delete from public.todo_lists where user_id = :'w';
select count(*) as msgs_before from realtime.messages where topic = 'user:' || :'w' \gset
delete from auth.users where id = :'w';
select (select count(*) from public.events where user_id = :'w')
     + (select count(*) from public.event_logs where user_id = :'w')
     + (select count(*) from public.event_feedback where user_id = :'w')
     + (select count(*) from public.todo_lists where user_id = :'w')
     + (select count(*) from public.event_types where user_id = :'w')
     + (select count(*) from public.skill_insights where user_id = :'w')
     + (select count(*) from public.user_settings where user_id = :'w')
     + (select count(*) from public.agent_preferences where user_id = :'w')
     + (select count(*) from public.agent_conversations where user_id = :'w') as survivors \gset
select count(*) - :msgs_before as erase_frames from realtime.messages where topic = 'user:' || :'w' \gset
select pg_temp.rec('S6', 'deleting auth.users physically erases every row in the nine tables',
  :survivors = 0, format('surviving rows across nine tables=%s; doorbell frames emitted by the erase=%s', :survivors, :erase_frames));

-- ============================================================
-- S10 (SQL part)  the events arm of sync_changes under RLS uses idx_events_user_seq
-- ============================================================
\echo '--- S10'
-- V's fill first, then U's: U's cursor then sits near the global head, the
-- shape of an incremental pull. With U's rows first, "seq > cursor" also
-- matched all of V's later rows, the planner saw it as unselective, and its
-- choice between this index and any other (user_id, …) index plus a sort
-- flipped from run to run with the heap layout the earlier checks left.
insert into public.events (id, user_id, kind, title)
select gen_random_uuid(), :'v', 'todo', 'S10 fill' from generate_series(1, 2000);
insert into public.events (id, user_id, kind, title)
select gen_random_uuid(), :'u', 'todo', 'S10 fill' from generate_series(1, 2000);
analyze public.events;
select max(seq) - 50 as cursor from public.events where user_id = :'u' \gset
select set_config('request.jwt.claims', :'claims_u', false);
set role authenticated;
select string_agg(line, E'\n') as plan from (
  select * from dblink('C', format('explain (analyze, costs off) select e.seq, to_jsonb(e) from public.events e where e.seq > %s order by e.seq limit 500', :cursor)) as t(line text)
) p \gset
reset role;
\echo :plan
select pg_temp.rec('S10', 'events arm as authenticated: plan uses idx_events_user_seq',
  position('idx_events_user_seq' in :'plan') > 0, replace(split_part(:'plan', E'\n', 1) || ' / ' || split_part(:'plan', E'\n', 2), E'\n', ' '));
select count(*) as n, max(seq) as mx from dblink('C', format('select seq from public.sync_changes(%s, 5000)', 0)) as t(seq bigint) \gset
select count(*) as n_u from public.events where user_id = :'u' \gset
select pg_temp.rec('S10', 'page_limit above the clamp returns exactly the clamp (PostgREST max_rows), with more rows than that waiting',
  :n = 1000 and :n_u > 1000, format('sync_changes(0, 5000) as U returned %s rows; U owns %s events rows', :n, :n_u));
select count(*) as n from dblink('C', 'select seq from public.sync_changes(0, 1000)') as t(seq bigint) \gset
select pg_temp.rec('S10', 'page_limit equal to the clamp returns a full page', :n = 1000, format('sync_changes(0, 1000) as U returned %s rows', :n));

-- ============================================================
-- S14  service_role delete is still a tombstone
-- ============================================================
\echo '--- S14'
select id as s14, seq as s14_seq from public.events where user_id = :'u' and title like 'S5 batch %' and deleted_at is null limit 1 \gset
set role service_role;
delete from public.events where id = :'s14';
reset role;
select count(*) as n, bool_and(deleted_at is not null) as tomb, max(seq) as s14_seq2 from public.events where id = :'s14' \gset
select pg_temp.rec('S14', 'delete as service_role becomes a tombstone (trigger depth one)',
  :n = 1 and :'tomb' = 't' and :s14_seq2 > :s14_seq, format('rows=%s tombstoned=%s seq %s -> %s', :n, :'tomb', :s14_seq, :s14_seq2));

-- ============================================================
-- S15  row lock / user lock order deadlock
-- ============================================================
\echo '--- S15'
select id as x from public.events where user_id = :'u' and title like 'S5 batch %' and deleted_at is null order by seq limit 1 \gset
select id as y from public.events where user_id = :'u' and title like 'S5 batch %' and deleted_at is null order by seq desc limit 1 \gset
begin;
update public.events set title = 'S15 A touched Y' where id = :'y';
select dblink_send_query('B', format('update public.events set title = ''S15 B touched X'' where id = %L', :'x'));
select pg_sleep(0.3);
select coalesce(wait_event, '') as b_wait from pg_stat_activity where pid = :b_pid \gset
\set ON_ERROR_STOP off
update public.events set title = 'S15 A touched X' where id = :'x';
\set a_err :ERROR
\set a_state :SQLSTATE
\set ON_ERROR_STOP on
\if :a_err
  rollback;
\else
  commit;
\endif
select dblink_get_result('B', false);
select coalesce(dblink_error_message('B'), '') as b_err \gset
select (select title from public.events where id = :'x') as x_title, (select title from public.events where id = :'y') as y_title \gset
select pg_temp.rec('S15', 'two-statement A vs single-statement B deadlock: exactly one side gets 40P01, the other commits',
  (:'a_state' = '40P01') <> (position('deadlock' in :'b_err') > 0),
  format('victim=%s; B waited on=%s; A sqlstate=%s; B error=%s; x.title=%s; y.title=%s',
         case when :'a_state' = '40P01' then 'A (two statements)' else 'B (single statement, waited first)' end,
         :'b_wait', :'a_state', split_part(:'b_err', E'\n', 1), :'x_title', :'y_title'));

-- ============================================================
-- S16  TRUNCATE is refused on every synced table; replica role variant
-- ============================================================
\echo '--- S16'
select gen_random_uuid() as s16 \gset
select set_config('bench.u', :'u', false);
select set_config('bench.s16', :'s16', false);
-- one row per table for U, so "row count unchanged" means something
insert into public.events (id, user_id, kind, title) values (:'s16', :'u', 'todo', 'S16');
insert into public.event_logs (id, user_id, event_id, occurrence_date) values ('single|' || gen_random_uuid(), :'u', gen_random_uuid(), now());
insert into public.event_feedback (id, user_id, event_id, occurrence_date) values ('single|' || gen_random_uuid(), :'u', gen_random_uuid(), now());
insert into public.todo_lists (id, user_id, title, color_name) values (gen_random_uuid(), :'u', 'S16', 'blue');
insert into public.event_types (id, user_id, title, color_hex) values (gen_random_uuid(), :'u', 'S16', '#000000');
insert into public.skill_insights (id, user_id, skill_name, points, date, event_title) values (gen_random_uuid(), :'u', 'S16', 1, now(), 'S16');
insert into public.user_settings (user_id, settings) values (:'u', '{}') on conflict (user_id) do nothing;
insert into public.agent_preferences (user_id) values (:'u') on conflict (user_id) do nothing;
insert into public.agent_conversations (user_id) values (:'u') on conflict (user_id) do nothing;

do $$
declare
  t text;
  before_n bigint;
  after_n bigint;
  state text;
  msg text;
begin
  foreach t in array array[
    'events', 'event_logs', 'event_feedback', 'todo_lists', 'event_types',
    'skill_insights', 'user_settings', 'agent_preferences', 'agent_conversations'
  ] loop
    execute format('select count(*) from public.%I', t) into before_n;
    state := 'none'; msg := 'TRUNCATE succeeded';
    begin
      execute format('truncate public.%I', t);
      -- reached only when the guard did not fire: undo the truncate
      raise exception 'S16 marker: truncate went through' using errcode = 'P0001';
    exception when others then
      state := sqlstate; msg := sqlerrm;
    end;
    execute format('select count(*) from public.%I', t) into after_n;
    perform pg_temp.rec('S16', format('%s: TRUNCATE is refused by the guard (23001) and the row count is unchanged', t),
      state = '23001' and after_n = before_n and before_n > 0,
      format('sqlstate=%s message=%s rows %s -> %s', state, msg, before_n, after_n));
  end loop;
end $$;

-- the cascade form reaches the synced tables as a TRUNCATE, not as row deletes
do $$
declare state text := 'none'; msg text := 'TRUNCATE succeeded';
begin
  begin
    truncate auth.users cascade;
    raise exception 'S16 marker: truncate went through' using errcode = 'P0001';
  exception when others then state := sqlstate; msg := sqlerrm;
  end;
  perform pg_temp.rec('S16', 'truncate auth.users cascade is refused (the guard fires on the cascaded tables; everything rolls back)',
    state = '23001', format('sqlstate=%s message=%s users now=%s', state, msg, (select count(*) from auth.users)));
end $$;

-- replica variant: every finding below is recorded inside a subtransaction
-- that is then rolled back, so no table is actually emptied
do $$
declare
  u uuid := current_setting('bench.u')::uuid;
  x uuid := current_setting('bench.s16')::uuid;
  n_before bigint; n_after bigint;
  x_rows bigint; x_tomb boolean;
  y uuid; y_seq bigint; y_seq2 bigint;
  msgs_before bigint; msgs_after bigint;
  ins_state text; trunc_state text;
  obs text;
begin
  begin
    set local session_replication_role = replica;

    select count(*) into n_before from public.events;
    trunc_state := 'succeeded';
    begin
      truncate public.events;
    exception when others then trunc_state := sqlstate;
    end;
    select count(*) into n_after from public.events;
    obs := format('truncate guard: TRUNCATE %s, events rows %s -> %s', trunc_state, n_before, n_after);
    raise exception using errcode = 'P0001', message = obs;
  exception when sqlstate 'P0001' then
    obs := sqlerrm;
  end;
  perform pg_temp.rec('S16', 'replica variant (recorded): session_replication_role = replica skips the TRUNCATE guard; TRUNCATE empties the table',
    obs like 'truncate guard: TRUNCATE succeeded, events rows % -> 0' and obs not like '% 0 -> 0', obs || ' (rolled back)');

  begin
    set local session_replication_role = replica;
    select count(*) into msgs_before from realtime.messages where topic = 'user:' || u;

    delete from public.events where id = x;
    select count(*), bool_or(deleted_at is not null) into x_rows, x_tomb from public.events where id = x;

    select id, seq into y, y_seq from public.events where user_id = u and deleted_at is null and id <> x order by seq limit 1;
    update public.events set title = 'S16 replica update' where id = y;
    select seq into y_seq2 from public.events where id = y;

    ins_state := 'inserted';
    begin
      insert into public.events (id, user_id, kind, title) values (gen_random_uuid(), u, 'todo', 'S16 replica insert');
    exception when others then ins_state := sqlstate;
    end;
    select count(*) into msgs_after from realtime.messages where topic = 'user:' || u;

    obs := format('tombstone: DELETE left %s rows (tombstoned=%s); sync_meta: UPDATE seq %s -> %s, INSERT without seq -> %s; doorbell frames %s',
                  x_rows, coalesce(x_tomb::text, 'n/a'), y_seq, y_seq2, ins_state, msgs_after - msgs_before);
    raise exception using errcode = 'P0001', message = obs;
  exception when sqlstate 'P0001' then
    obs := sqlerrm;
  end;
  perform pg_temp.rec('S16', 'replica variant (recorded): the tombstone, sync_meta and doorbell triggers are skipped too — DELETE is physical, UPDATE keeps its old seq, an INSERT without seq fails NOT NULL, nothing rings',
    obs like 'tombstone: DELETE left 0 rows (tombstoned=n/a); sync_meta: UPDATE seq % -> %, INSERT without seq -> 23502; doorbell frames 0'
      and split_part(split_part(obs, 'UPDATE seq ', 2), ',', 1) ~ '^(\d+) -> \1$',
    obs || ' (rolled back)');
end $$;

select count(*) as n from public.events where id = :'s16' and deleted_at is null \gset
select pg_temp.rec('S16', 'after the rolled-back replica variant the row is back, live', :n = 1, format('live rows for the S16 id=%s', :n));

-- who may switch to replica mode (the guard's real perimeter)
do $$
declare r text; state text; res text := '';
begin
  foreach r in array array['authenticated', 'anon', 'service_role'] loop
    begin
      execute format('set local role %I', r);
      set local session_replication_role = replica;
      state := 'allowed';
      raise exception using errcode = 'P0001', message = 'undo';
    exception
      when sqlstate 'P0001' then null;
      when others then state := sqlstate;
    end;
    res := res || format('%s=%s ', r, state);
  end loop;
  -- the postgres role (not a superuser on Supabase) may use the SET command;
  -- set_config() is a different path and is recorded alongside
  begin
    perform set_config('session_replication_role', 'replica', true);
    state := 'allowed';
    raise exception using errcode = 'P0001', message = 'undo';
  exception
    when sqlstate 'P0001' then null;
    when others then state := sqlstate;
  end;
  res := res || format('postgres set_config()=%s ', state);
  begin
    set local session_replication_role = replica;
    state := 'allowed';
    raise exception using errcode = 'P0001', message = 'undo';
  exception
    when sqlstate 'P0001' then null;
    when others then state := sqlstate;
  end;
  res := res || format('postgres SET=%s', state);
  perform pg_temp.rec('S16', 'replica mode needs the postgres role and the SET command: authenticated, anon and service_role are refused (42501)',
    res like 'authenticated=42501 anon=42501 service_role=42501 % postgres SET=allowed', res || '; current_user=' || current_user);
end $$;

-- ============================================================
-- S20  the write gate (v6, §5.10): header vs epoch, paused / rollback, and
--      the trigger order. request.headers is what PostgREST sets per request;
--      here pg_temp.gate_try sets it for one statement. A refused write must
--      take no seq (sequences survive a rollback, so an unchanged counter
--      proves the gate fired before set_sync_meta's nextval), log no version
--      and ring nothing.
-- ============================================================
\echo '--- S20'
create function pg_temp.gate_try(hdr text, stmt text) returns text language plpgsql as $$
begin
  perform set_config('request.headers', coalesce(hdr, ''), true);
  begin
    execute stmt;
  exception when others then
    return sqlstate || ' ' || sqlerrm;
  end;
  return 'ok';
end $$;
update public.sync_epoch set paused = false, rollback = false;
select epoch as cur_epoch from public.sync_epoch \gset
select format('{"x-sync-epoch":"%s"}', :'cur_epoch') as hdr_ok \gset
\set hdr_stale '{"x-sync-epoch":"not-the-epoch"}'

select coalesce(string_agg(t, ','), '') as order_bad from (
  select t from unnest(array['events', 'event_logs', 'event_feedback', 'todo_lists', 'event_types',
                             'skill_insights', 'user_settings', 'agent_preferences', 'agent_conversations']) t
  where not exists (select 1 from pg_trigger where tgrelid = to_regclass('public.' || t) and tgname = 'trg_' || t || '_sync_gate')
     or not ('trg_' || t || '_sync_gate' < 'trg_' || t || '_sync_meta')
     or (select tgtype from pg_trigger where tgrelid = to_regclass('public.' || t) and tgname = 'trg_' || t || '_sync_gate') & (1|2|4|16) <> (1|2|4|16)
) s \gset
select pg_temp.rec('S20', 'every synced table has a BEFORE INSERT OR UPDATE row trigger trg_<t>_sync_gate whose name sorts before trg_<t>_sync_meta (same-timing triggers fire in name order)',
  coalesce(:'order_bad', '') = '', format('tables out of shape: [%s]', coalesce(:'order_bad', '')));

select last_value as lv0 from public.sync_seq \gset
select count(*) as f0 from realtime.messages where topic = 'user:' || :'u' \gset
select count(*) as n0 from public.sync_versions \gset
select gen_random_uuid() as gx \gset
select pg_temp.gate_try(:'hdr_stale', format('insert into public.events (id, user_id, kind, title) values (%L, %L, ''todo'', ''S20 stale insert'')', :'gx', :'u')) as r \gset
select last_value as lv1 from public.sync_seq \gset
select count(*) as f1 from realtime.messages where topic = 'user:' || :'u' \gset
select count(*) as n1 from public.sync_versions \gset
select count(*) as rows_gx from public.events where id = :'gx' \gset
select pg_temp.rec('S20', 'INSERT with a stale X-Sync-Epoch header: P0001 sync_epoch_stale, no row, no seq taken, no doorbell, no log row',
  :'r' = 'P0001 sync_epoch_stale' and :rows_gx = 0 and :lv1 = :lv0 and :f1 = :f0 and :n1 = :n0,
  format('result=%s rows=%s sync_seq %s -> %s frames %s -> %s log rows %s -> %s', :'r', :rows_gx, :lv0, :lv1, :f0, :f1, :n0, :n1));

select pg_temp.gate_try(:'hdr_ok', format('insert into public.events (id, user_id, kind, title) values (%L, %L, ''todo'', ''S20 ok insert'')', :'gx', :'u')) as r \gset
select coalesce(seq, 0) as gx_seq, coalesce(version_id::text, '') as gx_vid from public.events where id = :'gx' \gset
select count(*) as n2 from public.sync_versions \gset
select count(*) - :f0 as f2 from realtime.messages where topic = 'user:' || :'u' \gset
select pg_temp.rec('S20', 'INSERT with the current epoch in the header lands: a seq, a version, one log row, one doorbell frame',
  :'r' = 'ok' and :gx_seq > :lv0 and :n2 = :n0 + 1 and :f2 = 1, format('result=%s seq=%s version=%s log rows %s -> %s frames +%s', :'r', :gx_seq, :'gx_vid', :n0, :n2, :f2));

select last_value as lv0 from public.sync_seq \gset
select pg_temp.gate_try(:'hdr_stale', format('update public.events set title = ''S20 stale update'' where id = %L', :'gx')) as r \gset
select last_value as lv1 from public.sync_seq \gset
select seq as gx_seq2, title as gx_title from public.events where id = :'gx' \gset
select pg_temp.rec('S20', 'UPDATE with a stale header: sync_epoch_stale, the row keeps its title, seq and version, no seq taken',
  :'r' = 'P0001 sync_epoch_stale' and :gx_seq2 = :gx_seq and :'gx_title' = 'S20 ok insert' and :lv1 = :lv0,
  format('result=%s title=%s seq %s -> %s sync_seq %s -> %s', :'r', :'gx_title', :gx_seq, :gx_seq2, :lv0, :lv1));

select pg_temp.gate_try(:'hdr_stale', format('delete from public.events where id = %L', :'gx')) as r \gset
select deleted_at is null as gx_live from public.events where id = :'gx' \gset
select pg_temp.rec('S20', 'DELETE with a stale header: the tombstone rewrite''s UPDATE meets the gate, sync_epoch_stale, the row stays live',
  :'r' = 'P0001 sync_epoch_stale' and :'gx_live' = 't', format('result=%s live=%s', :'r', :'gx_live'));
select count(*) as n0 from public.sync_versions \gset
select pg_temp.gate_try(:'hdr_ok', format('delete from public.events where id = %L', :'gx')) as r \gset
select deleted_at is not null as gx_tomb, seq as gx_seq3 from public.events where id = :'gx' \gset
select count(*) as n1 from public.sync_versions \gset
select pg_temp.rec('S20', 'DELETE with the current header: tombstone with a new seq and one more log row',
  :'r' = 'ok' and :'gx_tomb' = 't' and :gx_seq3 > :gx_seq and :n1 = :n0 + 1, format('result=%s tombstoned=%s seq %s -> %s log rows %s -> %s', :'r', :'gx_tomb', :gx_seq, :gx_seq3, :n0, :n1));

update public.sync_epoch set paused = true, rollback = false;
select gen_random_uuid() as gp \gset
select pg_temp.gate_try(:'hdr_ok', format('insert into public.events (id, user_id, kind, title) values (%L, %L, ''todo'', ''S20 paused header'')', :'gp', :'u')) as r_hdr \gset
select pg_temp.gate_try(null, format('insert into public.events (id, user_id, kind, title) values (%L, %L, ''todo'', ''S20 paused no header'')', :'gp', :'u')) as r_nohdr \gset
select pg_temp.gate_try(:'hdr_stale', format('insert into public.events (id, user_id, kind, title) values (%L, %L, ''todo'', ''S20 paused stale'')', :'gp', :'u')) as r_stale \gset
select count(*) as rows_gp from public.events where id = :'gp' \gset
select pg_temp.rec('S20', 'paused, no rollback: a header-bearing write and a header-less write are both refused with sync_paused; a stale header is still sync_epoch_stale; nothing lands',
  :'r_hdr' = 'P0001 sync_paused' and :'r_nohdr' = 'P0001 sync_paused' and :'r_stale' = 'P0001 sync_epoch_stale' and :rows_gp = 0,
  format('header=%s | no header=%s | stale=%s | rows=%s', :'r_hdr', :'r_nohdr', :'r_stale', :rows_gp));

update public.sync_epoch set paused = true, rollback = true;
select last_value as lv0 from public.sync_seq \gset
select pg_temp.gate_try(:'hdr_ok', format('insert into public.events (id, user_id, kind, title) values (%L, %L, ''todo'', ''S20 rollback header'')', :'gp', :'u')) as r_hdr \gset
select pg_temp.gate_try(null, format('insert into public.events (id, user_id, kind, title) values (%L, %L, ''todo'', ''S20 rollback no header'')', :'gp', :'u')) as r_nohdr \gset
select coalesce(max(seq), 0) as gp_seq, count(*) as rows_gp from public.events where id = :'gp' \gset
select pg_temp.rec('S20', 'paused with rollback set: a header-bearing write is still sync_paused, a header-less write lands and takes a new seq',
  :'r_hdr' = 'P0001 sync_paused' and :'r_nohdr' = 'ok' and :rows_gp = 1 and :gp_seq > :lv0,
  format('header=%s | no header=%s rows=%s seq=%s (counter before %s)', :'r_hdr', :'r_nohdr', :rows_gp, :gp_seq, :lv0));
update public.sync_epoch set paused = false, rollback = false;

-- ============================================================
-- S21  the version log (v6, §5.9): one row per write that lands, parent =
--      the version written over, client-sent version ids ignored, a
--      client-sent parent kept on INSERT, restored_from recorded and never
--      left on the row, no version for a no-op, the key column as id.
-- ============================================================
\echo '--- S21'
select gen_random_uuid() as x \gset
insert into public.events (id, user_id, kind, title) values (:'x', :'u', 'todo', 'S21 x1')
returning version_id as x1, seq as x1_seq \gset
select count(*) as c, coalesce(max(parent_version_id::text), 'null') as p, coalesce(max(seq), 0) as s, coalesce(max(id), '') as lid,
       coalesce(max(user_id::text), '') as luid
from public.sync_versions where tbl = 'events' and version_id = :'x1' \gset
select pg_temp.rec('S21', 'INSERT: one log row for the new version — parent null, seq = the row''s seq, id = the row''s id, user_id = the row''s user',
  :c = 1 and :'p' = 'null' and :s = :x1_seq and :'lid' = :'x' and :'luid' = :'u',
  format('log rows for x1=%s parent=%s seq=%s (row seq %s) id=%s', :c, :'p', :s, :x1_seq, :'lid'));

select gen_random_uuid() as y \gset
select gen_random_uuid() as client_vid \gset
select gen_random_uuid() as client_parent \gset
insert into public.events (id, user_id, kind, title, version_id, parent_version_id)
values (:'y', :'u', 'todo', 'S21 y1', :'client_vid', :'client_parent')
returning version_id::text as y1, coalesce(parent_version_id::text, 'null') as y1_parent \gset
select count(*) as c, coalesce(max(parent_version_id::text), 'null') as p from public.sync_versions where version_id = :'y1' \gset
select pg_temp.rec('S21', 'INSERT with a client-sent version_id and parent_version_id: the version_id is ignored (a fresh one is assigned), the parent is kept on the row and in the log',
  :'y1' <> :'client_vid' and :'y1_parent' = :'client_parent' and :c = 1 and :'p' = :'client_parent',
  format('sent version_id=%s -> row %s; sent parent=%s -> row %s, log %s', :'client_vid', :'y1', :'client_parent', :'y1_parent', :'p'));

select count(*) as n0 from public.sync_versions \gset
update public.events set title = 'S21 x2', version_id = :'client_vid', parent_version_id = :'client_parent' where id = :'x'
returning version_id::text as x2, coalesce(parent_version_id::text, 'null') as x2_parent, seq as x2_seq \gset
select count(*) as n1 from public.sync_versions \gset
select count(*) as c, coalesce(max(parent_version_id::text), 'null') as p, coalesce(max(seq), 0) as s from public.sync_versions where version_id = :'x2' \gset
select pg_temp.rec('S21', 'UPDATE with a client-sent version_id and parent: both ignored — new version, parent = the old version_id, one more log row with that parent and the new seq',
  :'x2' <> :'client_vid' and :'x2' <> :'x1' and :'x2_parent' = :'x1' and :n1 = :n0 + 1 and :c = 1 and :'p' = :'x1' and :s = :x2_seq,
  format('x1=%s -> x2=%s parent=%s log rows %s -> %s log parent=%s seq=%s', :'x1', :'x2', :'x2_parent', :n0, :n1, :'p', :s));

select count(*) as n0 from public.sync_versions \gset
insert into public.events (id, user_id, kind, title) values (:'x', :'u', 'todo', 'S21 x3 via upsert')
on conflict (id) do update set title = excluded.title;
select version_id::text as x3, coalesce(parent_version_id::text, 'null') as x3_parent from public.events where id = :'x' \gset
select count(*) as n1 from public.sync_versions \gset
select count(*) as c from public.sync_versions where tbl = 'events' and id = :'x' \gset
select pg_temp.rec('S21', 'merge-duplicates upsert hitting an existing row with a content change: exactly ONE more log row (the INSERT arm that never landed logs nothing), parent = the version written over',
  :'x3' <> :'x2' and :'x3_parent' = :'x2' and :n1 = :n0 + 1 and :c = 3,
  format('x2=%s -> x3=%s parent=%s log rows %s -> %s; rows for x in the log=%s (x1, x2, x3)', :'x2', :'x3', :'x3_parent', :n0, :n1, :c));

select count(*) as n0 from public.sync_versions \gset
update public.events set title = 'S21 x3 via upsert', updated_at = now() where id = :'x';
insert into public.events (id, user_id, kind, title) values (:'x', :'u', 'todo', 'S21 x3 via upsert')
on conflict (id) do update set title = excluded.title;
select version_id::text as x3b, seq as x3b_seq from public.events where id = :'x' \gset
select count(*) as n1 from public.sync_versions \gset
select pg_temp.rec('S21', 'a content-identical UPDATE and a content-identical upsert: no new version, no log row (the no-op short-circuit runs before the version is assigned)',
  :'x3b' = :'x3' and :n1 = :n0, format('version %s -> %s log rows %s -> %s', :'x3', :'x3b', :n0, :n1));
-- PostgREST's merge-duplicates upsert SETs every column in the body; a client
-- that echoes version_id / parent_version_id back must still get a no-op
insert into public.events (id, user_id, kind, title, version_id, parent_version_id)
values (:'x', :'u', 'todo', 'S21 x3 via upsert', gen_random_uuid(), gen_random_uuid())
on conflict (id) do update set title = excluded.title, version_id = excluded.version_id, parent_version_id = excluded.parent_version_id;
select version_id::text as x3c, seq as x3c_seq from public.events where id = :'x' \gset
select count(*) as n2 from public.sync_versions \gset
select pg_temp.rec('S21', 'a content-identical upsert whose body carries version_id and parent_version_id (EXCLUDED differs from OLD only in the version columns): still a no-op — the version columns are metadata, not content',
  :'x3c' = :'x3' and :x3c_seq = :x3b_seq and :n2 = :n0, format('version %s -> %s seq %s -> %s log rows %s -> %s', :'x3', :'x3c', :x3b_seq, :x3c_seq, :n0, :n2));

update public.events set title = 'S21 x4 written back', restored_from_version_id = :'x1' where id = :'x'
returning version_id::text as x4, coalesce(restored_from_version_id::text, 'null') as x4_rf_on_row \gset
select coalesce(max(restored_from_version_id::text), 'null') as rf_logged, coalesce(max(parent_version_id::text), 'null') as p
from public.sync_versions where version_id = :'x4' \gset
select coalesce(restored_from_version_id::text, 'null') as rf_stored from public.events where id = :'x' \gset
select pg_temp.rec('S21', 'a write-back (restored_from_version_id in the request): the log row carries it, the row does not (RETURNING and the stored row both null), parent is still the version written over',
  :'rf_logged' = :'x1' and :'x4_rf_on_row' = 'null' and :'rf_stored' = 'null' and :'p' = :'x3',
  format('sent restored_from=%s -> log %s, row (returning) %s, row (stored) %s; parent=%s', :'x1', :'rf_logged', :'x4_rf_on_row', :'rf_stored', :'p'));

select count(*) as n0 from public.sync_versions \gset
delete from public.events where id = :'x';
select version_id::text as x5, coalesce(parent_version_id::text, 'null') as x5_parent, deleted_at is not null as x_tomb from public.events where id = :'x' \gset
select count(*) as n1 from public.sync_versions \gset
select pg_temp.rec('S21', 'DELETE (tombstone rewrite): a new version with parent = the version written over and one more log row',
  :'x_tomb' = 't' and :'x5' <> :'x4' and :'x5_parent' = :'x4' and :n1 = :n0 + 1, format('x4=%s -> x5=%s parent=%s tombstoned=%s log rows %s -> %s', :'x4', :'x5', :'x5_parent', :'x_tomb', :n0, :n1));

update public.user_settings set settings = '{"s21":1}' where user_id = :'u'
returning version_id::text as us_vid, seq as us_seq \gset
select count(*) as c, coalesce(max(id), '') as lid from public.sync_versions where version_id = :'us_vid' \gset
select pg_temp.rec('S21', 'a table keyed by user_id logs its key as the id', :c = 1 and :'lid' = :'u', format('user_settings version %s logged with id=%s (user %s)', :'us_vid', :'lid', :'u'));

select count(*) as n from dblink('C', format('select seq from public.sync_changes(%s, 10) where tbl = ''events'' and data->>''id'' = %L and data->>''version_id'' = %L and data->>''parent_version_id'' = %L and data ? ''restored_from_version_id'' and data->>''restored_from_version_id'' is null', :x1_seq - 1, :'x', :'x5', :'x4')) as t(seq bigint) \gset
select pg_temp.rec('S21', 'sync_changes data carries version_id and parent_version_id (and a null restored_from_version_id) for the row', :n = 1, format('feed rows matching x@x5 with parent x4=%s', :n));

-- ============================================================
-- S22  is_ancestor (v6, §5.9): true / false / null, both edges, depth
-- ============================================================
\echo '--- S22'
select coalesce(r, 'null') as a_x1_x4 from dblink('C', format('select public.is_ancestor(''events'', %L, %L, %L)::text', :'x', :'x1', :'x4')) as t(r text) \gset
select coalesce(r, 'null') as a_x4_x1 from dblink('C', format('select public.is_ancestor(''events'', %L, %L, %L)::text', :'x', :'x4', :'x1')) as t(r text) \gset
select coalesce(r, 'null') as a_x3_x3 from dblink('C', format('select public.is_ancestor(''events'', %L, %L, %L)::text', :'x', :'x3', :'x3')) as t(r text) \gset
select coalesce(r, 'null') as a_rand_x4 from dblink('C', format('select public.is_ancestor(''events'', %L, %L, %L)::text', :'x', gen_random_uuid(), :'x4')) as t(r text) \gset
select coalesce(r, 'null') as a_x1_rand from dblink('C', format('select public.is_ancestor(''events'', %L, %L, %L)::text', :'x', :'x1', gen_random_uuid())) as t(r text) \gset
select coalesce(r, 'null') as a_wrong_tbl from dblink('C', format('select public.is_ancestor(''todo_lists'', %L, %L, %L)::text', :'x', :'x1', :'x4')) as t(r text) \gset
select pg_temp.rec('S22', 'as the owner: an ancestor is true, a descendant is false, a version is its own ancestor, an unknown a or b is null, the wrong table is null',
  :'a_x1_x4' = 'true' and :'a_x4_x1' = 'false' and :'a_x3_x3' = 'true' and :'a_rand_x4' = 'null' and :'a_x1_rand' = 'null' and :'a_wrong_tbl' = 'null',
  format('(x1,x4)=%s (x4,x1)=%s (x3,x3)=%s (random,x4)=%s (x1,random)=%s wrong table=%s', :'a_x1_x4', :'a_x4_x1', :'a_x3_x3', :'a_rand_x4', :'a_x1_rand', :'a_wrong_tbl'));

-- another user's versions are not in the caller's log: null
select id as vrow from public.events where user_id = :'v' order by seq limit 1 \gset
update public.events set title = 'S22 v touched' where id = :'vrow' returning version_id::text as v2, coalesce(parent_version_id::text, 'null') as v1 \gset
select coalesce(r, 'null') as a_other from dblink('C', format('select public.is_ancestor(''events'', %L, nullif(%L, ''null'')::uuid, %L)::text', :'vrow', :'v1', :'v2')) as t(r text) \gset
select coalesce(public.is_ancestor('events', :'vrow', nullif(:'v1', 'null')::uuid, :'v2'::uuid)::text, 'null') as a_other_pg \gset
select pg_temp.rec('S22', 'another user''s versions: null for U through RLS, true for postgres (bypasses RLS)',
  :'a_other' = 'null' and :'a_other_pg' = 'true', format('as U=%s as postgres=%s', :'a_other', :'a_other_pg'));

-- the restored_from edge: a row rewound (its version_id set back, triggers
-- skipped) then edited forks the chain; a write-back of a version on the old
-- fork reaches it only through restored_from
select gen_random_uuid() as z \gset
insert into public.events (id, user_id, kind, title) values (:'z', :'u', 'todo', 'S22 z1') returning version_id::text as z1 \gset
update public.events set title = 'S22 z2' where id = :'z' returning version_id::text as z2 \gset
update public.events set title = 'S22 z3' where id = :'z' returning version_id::text as z3 \gset
begin;
set local session_replication_role = replica;
update public.events set version_id = :'z1'::uuid, title = 'S22 z1' where id = :'z';
commit;
update public.events set title = 'S22 z5 on the rewound row' where id = :'z' returning version_id::text as z5, coalesce(parent_version_id::text, 'null') as z5_parent \gset
select coalesce(r, 'null') as a_z3_z5 from dblink('C', format('select public.is_ancestor(''events'', %L, %L, %L)::text', :'z', :'z3', :'z5')) as t(r text) \gset
update public.events set title = 'S22 z6 writes z3 back', restored_from_version_id = :'z3'::uuid where id = :'z' returning version_id::text as z6 \gset
select coalesce(r, 'null') as a_z3_z6 from dblink('C', format('select public.is_ancestor(''events'', %L, %L, %L)::text', :'z', :'z3', :'z6')) as t(r text) \gset
select coalesce(r, 'null') as a_z2_z6 from dblink('C', format('select public.is_ancestor(''events'', %L, %L, %L)::text', :'z', :'z2', :'z6')) as t(r text) \gset
select coalesce(r, 'null') as a_z1_z6 from dblink('C', format('select public.is_ancestor(''events'', %L, %L, %L)::text', :'z', :'z1', :'z6')) as t(r text) \gset
select pg_temp.rec('S22', 'restored_from edge: after a rewind z1 -> z5 forks off z1, so z3 is not an ancestor of z5; a write-back of z3 (z6 parent z5, restored_from z3) makes z3 and z2 ancestors of z6 through that edge, z1 through either',
  :'z5_parent' = :'z1' and :'a_z3_z5' = 'false' and :'a_z3_z6' = 'true' and :'a_z2_z6' = 'true' and :'a_z1_z6' = 'true',
  format('z5.parent=%s (z1=%s); (z3,z5)=%s (z3,z6)=%s (z2,z6)=%s (z1,z6)=%s', :'z5_parent', :'z1', :'a_z3_z5', :'a_z3_z6', :'a_z2_z6', :'a_z1_z6'));

-- depth: a chain of 1100 versions; the walk stops after 1000 steps
select gen_random_uuid() as d \gset
select set_config('bench.d', :'d', false);
insert into public.events (id, user_id, kind, title) values (:'d', :'u', 'todo', 'S22 depth 0') returning version_id::text as d0 \gset
do $$
declare i int; v uuid;
begin
  for i in 1..1100 loop
    update public.events set title = 'S22 depth ' || i where id = current_setting('bench.d')::uuid returning version_id into v;
    if i = 150 then perform set_config('bench.d150', v::text, false); end if;
  end loop;
end $$;
select version_id::text as d_head from public.events where id = :'d' \gset
select current_setting('bench.d150') as d150 \gset
select coalesce(r, 'null') as a_d0 from dblink('C', format('select public.is_ancestor(''events'', %L, %L, %L)::text', :'d', :'d0', :'d_head')) as t(r text) \gset
select coalesce(r, 'null') as a_d150 from dblink('C', format('select public.is_ancestor(''events'', %L, %L, %L)::text', :'d', :'d150', :'d_head')) as t(r text) \gset
select count(*) as d_versions from public.sync_versions where tbl = 'events' and id = :'d' \gset
select pg_temp.rec('S22', 'depth bound: on a chain of 1101 versions the root (1100 steps up) is reported false, a version 950 steps up is true',
  :'a_d0' = 'false' and :'a_d150' = 'true' and :d_versions = 1101, format('(root,head)=%s (depth150,head)=%s versions logged=%s', :'a_d0', :'a_d150', :d_versions));

-- who may call. The catalog, not a call: on this image a function-ACL
-- error raised in a psql session after SET ROLE segfaults the backend
-- (recorded in the bench log; PostgREST's path answers 42501 normally, see
-- the HTTP bench S25). The RLS probe below does not go through that path.
select has_function_privilege('anon', 'public.is_ancestor(text, text, uuid, uuid)', 'EXECUTE') as anon_anc,
       has_function_privilege('authenticated', 'public.is_ancestor(text, text, uuid, uuid)', 'EXECUTE') as auth_anc,
       has_function_privilege('anon', 'public.sync_versions_prune(integer)', 'EXECUTE') as anon_prune,
       has_function_privilege('authenticated', 'public.sync_versions_prune(integer)', 'EXECUTE') as auth_prune,
       has_function_privilege('service_role', 'public.sync_versions_prune(integer)', 'EXECUTE') as sr_prune,
       not exists (select 1 from aclexplode((select proacl from pg_proc where oid = 'public.is_ancestor(text, text, uuid, uuid)'::regprocedure)) a where a.grantee = 0 and a.privilege_type = 'EXECUTE') as anc_no_public,
       not exists (select 1 from aclexplode((select proacl from pg_proc where oid = 'public.sync_versions_prune(integer)'::regprocedure)) a where a.grantee = 0 and a.privilege_type = 'EXECUTE') as prune_no_public \gset
select pg_temp.rec('S22', 'privileges (catalog): is_ancestor is executable by authenticated and not by anon or PUBLIC; sync_versions_prune by service_role and not by anon, authenticated or PUBLIC',
  :'anon_anc' = 'f' and :'auth_anc' = 't' and :'anc_no_public' = 't' and :'anon_prune' = 'f' and :'auth_prune' = 'f' and :'sr_prune' = 't' and :'prune_no_public' = 't',
  format('is_ancestor anon=%s authenticated=%s no PUBLIC=%s; prune anon=%s authenticated=%s service_role=%s no PUBLIC=%s', :'anon_anc', :'auth_anc', :'anc_no_public', :'anon_prune', :'auth_prune', :'sr_prune', :'prune_no_public'));
do $$
declare res text;
begin
  begin
    set local role authenticated;
    perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', current_setting('bench.u')), true);
    insert into public.sync_versions (user_id, tbl, id, version_id, seq) values (current_setting('bench.u')::uuid, 'events', 'forged', gen_random_uuid(), 1);
    res := 'allowed';
  exception when others then res := sqlstate;
  end;
  reset role;
  perform pg_temp.rec('S22', 'a direct insert into sync_versions by a user (outside a trigger) is refused by the policy (pg_trigger_depth() > 0)',
    res = '42501', 'authenticated direct insert=' || res);
end $$;

-- ============================================================
-- S23  sync_versions_prune: old orphans go, a live row's current version
--      (tombstones included) never does
-- ============================================================
\echo '--- S23'
update public.sync_versions set created_at = now() - interval '100 days' where tbl = 'events' and id in (:'x', :'z');
select count(*) as before_x from public.sync_versions where tbl = 'events' and id = :'x' \gset
select count(*) as before_z from public.sync_versions where tbl = 'events' and id = :'z' \gset
select public.sync_versions_prune(90) as pruned90 \gset
select count(*) as after_x, coalesce(bool_or(version_id = :'x5'::uuid), false) as x_cur_kept from public.sync_versions where tbl = 'events' and id = :'x' \gset
select count(*) as after_z, coalesce(bool_or(version_id = :'z6'::uuid), false) as z_cur_kept from public.sync_versions where tbl = 'events' and id = :'z' \gset
select count(*) as d_after from public.sync_versions where tbl = 'events' and id = :'d' \gset
select pg_temp.rec('S23', 'prune(90) removes the aged orphan versions of x (a tombstone) and z but keeps each row''s current version, and leaves fresh versions alone',
  :pruned90 = (:before_x - 1) + (:before_z - 1) and :after_x = 1 and :'x_cur_kept' = 't' and :after_z = 1 and :'z_cur_kept' = 't' and :d_after = 1101,
  format('pruned=%s x: %s -> %s (current x5 kept=%s, tombstone) z: %s -> %s (current z6 kept=%s) d: %s', :pruned90, :before_x, :after_x, :'x_cur_kept', :before_z, :after_z, :'z_cur_kept', :d_after));
select public.sync_versions_prune(0) as pruned0 \gset
select (select count(*) from public.sync_versions) as log_rows,
       (select count(*) from public.events) + (select count(*) from public.event_logs) + (select count(*) from public.event_feedback)
     + (select count(*) from public.todo_lists) + (select count(*) from public.event_types) + (select count(*) from public.skill_insights)
     + (select count(*) from public.user_settings) + (select count(*) from public.agent_preferences) + (select count(*) from public.agent_conversations) as row_total \gset
select count(*) as d_after0 from public.sync_versions where tbl = 'events' and id = :'d' \gset
select pg_temp.rec('S23', 'prune(0) removes every orphan version and nothing else: the log then holds exactly one row per synced row (every current version, tombstones included)',
  :pruned0 > 0 and :log_rows = :row_total and :d_after0 = 1, format('pruned=%s log rows=%s synced rows=%s d chain -> %s', :pruned0, :log_rows, :row_total, :d_after0));

-- ============================================================
-- S24  a rerun of 015 keeps the epoch row and its ledger, and backfills the
--      log for a row whose version is missing (written with triggers off)
-- ============================================================
\echo '--- S24'
select epoch as e0, restores::text as r0, paused::text as p0, rollback::text as rb0 from public.sync_epoch \gset
select gen_random_uuid() as m \gset
begin;
set local session_replication_role = replica;
insert into public.events (id, user_id, kind, title, seq, version_id) values (:'m', :'u', 'todo', 'S24 no log row', (select last_value from public.sync_seq), gen_random_uuid());
commit;
select version_id::text as m_vid from public.events where id = :'m' \gset
select count(*) as m0 from public.sync_versions where version_id = :'m_vid' \gset
select count(*) as n0 from public.sync_versions \gset
set client_min_messages = warning;
\ir ../migrations/015_sync_change_feed.sql
set client_min_messages = notice;
select epoch as e1, restores::text as r1, paused::text as p1, rollback::text as rb1 from public.sync_epoch \gset
select count(*) as m1, coalesce(max(parent_version_id::text), 'null') as m_parent from public.sync_versions where version_id = :'m_vid' \gset
select count(*) as n1 from public.sync_versions \gset
select pg_temp.rec('S24', 'rerunning migration 015 keeps epoch, ledger, paused and rollback exactly, and adds a log row (parent null) for the one row whose version was not logged',
  :'e1' = :'e0' and :'r1' = :'r0' and :'p1' = :'p0' and :'rb1' = :'rb0' and :m0 = 0 and :m1 = 1 and :'m_parent' = 'null' and :n1 = :n0 + 1,
  format('epoch %s -> %s ledger same=%s paused %s -> %s rollback %s -> %s; missing row logged %s -> %s parent=%s; log rows %s -> %s', :'e0', :'e1', (:'r1' = :'r0'), :'p0', :'p1', :'rb0', :'rb1', :m0, :m1, :'m_parent', :n0, :n1));

-- ============================================================
-- cleanup: fixture users erased through the cascade (S6 path)
-- ============================================================
select dblink_disconnect('B');
select dblink_disconnect('C');
select count(*) as vlog0 from public.sync_versions where user_id in (:'u', :'v') \gset
delete from auth.users where id in (:'u', :'v');
select count(*) as vlog1 from public.sync_versions where user_id in (:'u', :'v') \gset
select pg_temp.rec('S6', 'account erase also removes the users'' version log rows (auth.users cascade on sync_versions)', :vlog0 > 0 and :vlog1 = 0, format('log rows of U and V %s -> %s', :vlog0, :vlog1));
\set ON_ERROR_STOP off
delete from realtime.messages where topic in ('user:' || :'u', 'user:' || :'v', 'user:' || :'w');
\set ON_ERROR_STOP on

\o
\echo
\echo '=== results'
\pset format aligned
select case when pass then 'PASS' else 'FAIL' end as verdict, id, claim, observed from bench order by ord;
-- \if needs a boolean: a bare count of two or more is an error that psql
-- reports and then treats as false, which would print the pass line
select count(*) filter (where not pass) as fails, count(*) filter (where not pass) > 0 as any_fail from bench \gset
\if :any_fail
  \echo 'FAILED checks:' :fails
  do $$ begin raise exception 'sync_feed_checks: some checks failed'; end $$;
\else
  \echo 'all SQL checks passed'
\endif
