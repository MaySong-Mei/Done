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
insert into public.events (id, user_id, kind, title)
select gen_random_uuid(), :'u', 'todo', 'S10 fill' from generate_series(1, 2000);
insert into public.events (id, user_id, kind, title)
select gen_random_uuid(), :'v', 'todo', 'S10 fill' from generate_series(1, 2000);
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
select pg_temp.rec('S10', 'page_limit above the cap is clamped',
  :n = 2000, format('sync_changes(0, 5000) as U returned %s rows', :n));

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
-- cleanup: fixture users erased through the cascade (S6 path)
-- ============================================================
select dblink_disconnect('B');
select dblink_disconnect('C');
delete from auth.users where id in (:'u', :'v');
\set ON_ERROR_STOP off
delete from realtime.messages where topic in ('user:' || :'u', 'user:' || :'v', 'user:' || :'w');
\set ON_ERROR_STOP on

\o
\echo
\echo '=== results'
\pset format aligned
select case when pass then 'PASS' else 'FAIL' end as verdict, id, claim, observed from bench order by ord;
select count(*) filter (where not pass) as fails from bench \gset
\if :fails
  \echo 'FAILED checks:' :fails
  do $$ begin raise exception 'sync_feed_checks: some checks failed'; end $$;
\else
  \echo 'all SQL checks passed'
\endif
