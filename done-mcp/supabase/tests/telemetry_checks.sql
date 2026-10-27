-- Bench for migration 016 (telemetry chassis: spike_runs, the revision guard,
-- key_registry and its value vocabulary, the views) and 017 (v_my_spike_runs,
-- the caller's own rows for the observatory: T29–T33) — SQL-side checks, in
-- the sync_feed_checks.sql pattern. Run through run_checks.sh (this machine has no host psql: the
-- runner copies supabase/ into the db container and runs psql there), or:
--   psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 -f telemetry_checks.sql
-- from this directory, after telemetry/key_registry_load.sql was applied.
-- Every check prints PASS/FAIL with the observed values; the script raises at
-- the end when any check failed, so psql exits non-zero.
-- Second sessions (user U, user V, anon; briefly a no-sub authenticated N and
-- service_role S in T29/T31) are dblink connections the server
-- opens back to itself over its own address (scram); a loopback connection is
-- trust-authenticated and dblink refuses that for a non-superuser — so run
-- this over TCP, not a unix socket (inet_server_addr() is null there).
-- Fixture users are inserted straight into auth.users and erased at the end;
-- the erase is itself check T14 (the cascade).
-- T11 reads ../telemetry/key_registry.json and T27 reads
-- ../../../verification/telemetry-fixtures.json through psql's backtick (paths
-- relative to the cwd, i.e. this directory, in the repo's layout, which
-- run_checks.sh mirrors inside the container); -v expected_json / -v lean_json
-- override them.

\set QUIET on
\pset pager off
\set ON_ERROR_STOP on
\o /dev/null

create extension if not exists dblink;

create temp table bench (ord serial, id text, claim text, pass boolean, observed text);
create function pg_temp.rec(p_id text, p_claim text, p_pass boolean, p_observed text)
returns void language sql as $$
  insert into bench (id, claim, pass, observed) values (p_id, p_claim, coalesce(p_pass, false), p_observed);
$$;

select 'dbname=' || current_database() || ' user=postgres password=postgres host='
       || host(inet_server_addr()) || ' port=' || inet_server_port()::text as conninfo \gset
select gen_random_uuid() as u \gset
select gen_random_uuid() as v \gset
select gen_random_uuid() as i1 \gset
select gen_random_uuid() as i2 \gset
select gen_random_uuid() as i3 \gset
select gen_random_uuid() as r1 \gset
select gen_random_uuid() as r2 \gset
select current_date as today \gset

\if :{?expected_json}
\else
  \set expected_json `cat ../telemetry/key_registry.json 2>/dev/null`
\endif

-- leftovers of an aborted earlier run
delete from auth.users where email in ('tele-u@local.test', 'tele-v@local.test');
insert into auth.users (id, email, aud, role, email_confirmed_at, raw_app_meta_data, raw_user_meta_data)
values (:'u', 'tele-u@local.test', 'authenticated', 'authenticated', now(), '{}', '{}'),
       (:'v', 'tele-v@local.test', 'authenticated', 'authenticated', now(), '{}', '{}');

select set_config('bench.u', :'u', false);

-- helpers: a dblink session acting as a user / as anon through RLS; a remote
-- statement whose outcome is the command tag or ERR:<sqlstate>
create function pg_temp.as_user(conn text, uid uuid) returns void language plpgsql as $$
begin
  perform dblink_exec(conn, format('set request.jwt.claims = %L',
                                   format('{"sub":"%s","role":"authenticated"}', uid)));
  perform dblink_exec(conn, 'set role authenticated');
end $$;
create function pg_temp.as_anon(conn text) returns void language plpgsql as $$
begin
  perform dblink_exec(conn, 'set request.jwt.claims = ''{"role":"anon"}''');
  perform dblink_exec(conn, 'set role anon');
end $$;
create function pg_temp.try_exec(conn text, sql text) returns text language plpgsql as $$
begin
  return dblink_exec(conn, sql);
exception when others then
  return 'ERR:' || sqlstate;
end $$;
-- the client's upsert as PostgREST renders POST …?on_conflict=<conflict> with
-- Prefer: resolution=merge-duplicates (same idiom as telemetry_wire_conformance.sql):
-- insert the columns the body carries, on conflict set every sent non-key
-- column from excluded; a column the body omits (note, ended_at, outcome) is
-- left alone — wire §2's "note key absent". `extra` adds or overrides body
-- keys (e.g. '{"note": "…"}'); `conflict` is the on_conflict target.
create function pg_temp.upsert_sql(uid uuid, run uuid, install uuid, kind text, spike text, scenario text,
                                   day date, build int, cfg text, rev int, metrics jsonb,
                                   conflict text default 'user_id, run_id', extra jsonb default '{}') returns text language sql as $$
  with body as (
    select jsonb_build_object(
      'user_id', uid, 'run_id', run, 'install_id', install, 'kind', kind, 'spike_id', spike, 'scenario_id', scenario,
      'day_key', day, 'day_tz_offset_min', -420, 'app_build', build, 'app_version', '0.5.0', 'build_configuration', cfg,
      'device_model', 'iPhone17,2', 'os_version', '26.1', 'revision', rev,
      'started_at', now() - interval '1 hour', 'ended_at', now() - interval '30 minutes', 'outcome', 'completed',
      'metrics', metrics, 'context', '{}'::jsonb, 'client_updated_at', now()) || extra as j),
  cols as (select k from body, jsonb_object_keys(j) k order by k)
  select format($f$insert into public.spike_runs (%s) select %s from jsonb_populate_record(null::public.spike_runs, %L::jsonb)
                  on conflict (%s) do update set %s$f$,
                (select string_agg(quote_ident(k), ', ') from cols),
                (select string_agg(quote_ident(k), ', ') from cols),
                (select j::text from body),
                conflict,
                (select string_agg(format('%1$I = excluded.%1$I', k), ', ') from cols where k not in ('user_id', 'run_id')))
$$;
-- a release fixture row as postgres (bypasses RLS; the views are the subject)
create function pg_temp.fixture(uid uuid, run uuid, install uuid, kind text, spike text, scenario text,
                                day date, build int, cfg text, metrics jsonb, updated timestamptz default now())
returns void language plpgsql as $$
begin
  insert into public.spike_runs
      (user_id, run_id, install_id, kind, spike_id, scenario_id, day_key, day_tz_offset_min, app_build, app_version,
       build_configuration, device_model, os_version, revision, started_at, metrics, context, client_updated_at)
  values (uid, run, install, kind, spike, scenario, day, -420, build, '0.5.0', cfg, 'iPhone17,2', '26.1', 1,
          day::timestamptz, metrics, '{}'::jsonb, updated);
end $$;

-- object inventory of 016, for the rerun check
create function pg_temp.inventory() returns text language sql as $$
  select format('cols=%s idx=%s trg=%s pol=%s con=%s views=%s fn=%s',
    (select count(*) from information_schema.columns where table_schema = 'public' and table_name in ('spike_runs', 'key_registry')),
    (select count(*) from pg_indexes where schemaname = 'public' and tablename in ('spike_runs', 'key_registry')),
    (select count(*) from pg_trigger where tgrelid = 'public.spike_runs'::regclass and not tgisinternal),
    (select count(*) from pg_policies where schemaname = 'public' and tablename in ('spike_runs', 'key_registry')),
    (select count(*) from pg_constraint where conrelid in ('public.spike_runs'::regclass, 'public.key_registry'::regclass)),
    (select count(*) from pg_views where schemaname = 'public' and viewname in
       ('counter_long', 'v_active_installs', 'v_feature_unused_30d', 'v_sync_failure_by_build', 'v_metrickit_by_build',
        'v_fixwatch_verdicts_by_install', 'v_fixwatch_pooled_buckets', 'v_possible_dead_wire')),
    (select count(*) from pg_proc where proname in ('spike_runs_upload_stamp', 'spike_metric_num')
       and pronamespace = 'public'::regnamespace))
$$;

-- ============================================================
-- T1  a rerun of 016 (twice) is a no-op: same inventory, rows kept
-- ============================================================
\echo '--- T1'
select gen_random_uuid() as t1run \gset
select pg_temp.fixture(:'u', :'t1run', :'i1', 'daily_rollup', 'resident-daily', 'daily-rollup', :'today', 5, 'release', '{"tapCount": 1}');
select pg_temp.inventory() as inv0 \gset
select count(*) as reg0 from public.key_registry \gset
select coalesce(string_agg(grantee || ':' || privilege_type, ',' order by grantee, privilege_type), '') as grants0
from information_schema.role_table_grants where table_schema = 'public' and table_name = 'spike_runs' and grantee in ('anon', 'authenticated', 'service_role', 'PUBLIC') \gset
set client_min_messages = warning;
\ir ../migrations/016_spike_runs_telemetry.sql
\ir ../migrations/016_spike_runs_telemetry.sql
set client_min_messages = notice;
select pg_temp.inventory() as inv1 \gset
select count(*) as reg1 from public.key_registry \gset
select count(*) as t1kept from public.spike_runs where run_id = :'t1run' and metrics->>'tapCount' = '1' \gset
select coalesce(string_agg(grantee || ':' || privilege_type, ',' order by grantee, privilege_type), '') as grants1
from information_schema.role_table_grants where table_schema = 'public' and table_name = 'spike_runs' and grantee in ('anon', 'authenticated', 'service_role', 'PUBLIC') \gset
select pg_temp.rec('T1', 'rerunning 016 twice keeps the object inventory, the grants, every spike_runs row and every key_registry row',
  :'inv0' = :'inv1' and :reg0 = :reg1 and :reg0 > 0 and :t1kept = 1 and :'grants0' = :'grants1',
  format('inventory %s -> %s; registry rows %s -> %s; fixture row kept=%s; grants [%s] -> [%s]', :'inv0', :'inv1', :reg0, :reg1, :t1kept, :'grants0', :'grants1'));
select pg_temp.rec('T1', 'the grants after the rerun are exactly authenticated select/insert/update (no delete, nothing for anon or service_role)',
  :'grants1' = 'authenticated:INSERT,authenticated:SELECT,authenticated:UPDATE', format('grants [%s]', :'grants1'));

-- ============================================================
-- T2  as U: the same (run_id, revision 1) twice -> one row; the second send
--     is skipped by the guard (new.revision <= old.revision), so
--     last_uploaded_at does NOT move (wire §3; design §11.2 "同 revision 两次 → 1 行")
-- ============================================================
\echo '--- T2'
select dblink_connect('U', :'conninfo');
select dblink_connect('V', :'conninfo');
select dblink_connect('A', :'conninfo');
select pg_temp.as_user('U', :'u');
select pg_temp.as_user('V', :'v');
select pg_temp.as_anon('A');
select pg_temp.try_exec('U', pg_temp.upsert_sql(:'u', :'r1', :'i1', 'window', 'fix-effort-path', 'auto-window', :'today', 5, 'debug', 1, '{"wTaps": 1}')) as tag_a \gset
select coalesce(max(last_uploaded_at)::text, '') as lu_a, coalesce(max(first_uploaded_at)::text, '') as fu_a from public.spike_runs where user_id = :'u' and run_id = :'r1' \gset
select pg_sleep(0.1);
select pg_temp.try_exec('U', pg_temp.upsert_sql(:'u', :'r1', :'i1', 'window', 'fix-effort-path', 'auto-window', :'today', 5, 'debug', 1, '{"wTaps": 1}')) as tag_b \gset
select count(*) as n, coalesce(max(last_uploaded_at)::text, '') as lu_b, coalesce(max(first_uploaded_at)::text, '') as fu_b, coalesce(max(revision), -1) as rev
from public.spike_runs where user_id = :'u' and run_id = :'r1' \gset
select pg_temp.rec('T2', 'as U, the same (run_id, revision=1) upserted twice is one row; the first send stamps last_uploaded_at, the second is skipped by the revision guard (tag INSERT 0 0) and leaves the stamp alone',
  :'tag_a' = 'INSERT 0 1' and :'tag_b' = 'INSERT 0 0' and :n = 1 and :rev = 1 and :'lu_a' <> '' and :'lu_b' = :'lu_a' and :'fu_b' = :'fu_a',
  format('tags [%s] then [%s]; rows=%s revision=%s; last_uploaded_at %s -> %s; first_uploaded_at %s -> %s', :'tag_a', :'tag_b', :n, :rev, :'lu_a', :'lu_b', :'fu_a', :'fu_b'));

-- ============================================================
-- T3  revision 7 then revision 5 -> the row is still 7 with 7's metrics
-- ============================================================
\echo '--- T3'
select pg_temp.try_exec('U', pg_temp.upsert_sql(:'u', :'r2', :'i1', 'window', 'fix-effort-path', 'auto-window', :'today', 5, 'debug', 7, '{"wTaps": 7}')) as tag7 \gset
select coalesce(max(last_uploaded_at)::text, '') as lu7, coalesce(max(first_uploaded_at)::text, '') as fu7 from public.spike_runs where user_id = :'u' and run_id = :'r2' \gset
select pg_sleep(0.1);
select pg_temp.try_exec('U', pg_temp.upsert_sql(:'u', :'r2', :'i1', 'window', 'fix-effort-path', 'auto-window', :'today', 5, 'debug', 5, '{"wTaps": 5}')) as tag5 \gset
select coalesce(max(revision), -1) as rev3, coalesce(max(metrics->>'wTaps'), '') as m3, coalesce(max(last_uploaded_at)::text, '') as lu5 from public.spike_runs where user_id = :'u' and run_id = :'r2' \gset
select pg_temp.rec('T3', 'revision 7 then revision 5: the 5 is skipped (INSERT 0 0), the row keeps revision 7, 7''s metrics and 7''s upload stamp',
  :'tag7' = 'INSERT 0 1' and :'tag5' = 'INSERT 0 0' and :rev3 = 7 and :'m3' = '7' and :'lu5' = :'lu7',
  format('tags [%s] then [%s]; row revision=%s wTaps=%s; last_uploaded_at %s -> %s', :'tag7', :'tag5', :rev3, :'m3', :'lu7', :'lu5'));

-- ============================================================
-- T4  revision 8 overwrites 7; last_uploaded_at advances, first_uploaded_at
--     stays even when the client tries to send it
-- ============================================================
\echo '--- T4'
select pg_sleep(0.1);
select pg_temp.try_exec('U', pg_temp.upsert_sql(:'u', :'r2', :'i1', 'window', 'fix-effort-path', 'auto-window', :'today', 5, 'debug', 8, '{"wTaps": 8}')) as tag8 \gset
select coalesce(max(revision), -1) as rev4, coalesce(max(metrics->>'wTaps'), '') as m4, coalesce(max(last_uploaded_at)::text, '') as lu8, coalesce(max(first_uploaded_at)::text, '') as fu8 from public.spike_runs where user_id = :'u' and run_id = :'r2' \gset
select pg_temp.rec('T4', 'revision 8 overwrites 7 (INSERT 0 1): metrics are 8''s, last_uploaded_at advanced, first_uploaded_at unchanged',
  :'tag8' = 'INSERT 0 1' and :rev4 = 8 and :'m4' = '8' and nullif(:'lu8', '')::timestamptz > nullif(:'lu7', '')::timestamptz and :'fu8' = :'fu7',
  format('tag [%s]; revision=%s wTaps=%s; last_uploaded_at %s -> %s; first_uploaded_at %s -> %s', :'tag8', :rev4, :'m4', :'lu7', :'lu8', :'fu7', :'fu8'));
select pg_temp.try_exec('U', format('update public.spike_runs set revision = 9, first_uploaded_at = ''2000-01-01'' where user_id = %L and run_id = %L', :'u', :'r2')) as tag9 \gset
select coalesce(max(revision), -1) as rev9, coalesce(max(first_uploaded_at)::text, '') as fu9 from public.spike_runs where user_id = :'u' and run_id = :'r2' \gset
select pg_temp.rec('T4', 'an update that sends first_uploaded_at cannot move it: the trigger keeps the old value while the revision bump lands',
  :'tag9' = 'UPDATE 1' and :rev9 = 9 and :'fu9' = :'fu7', format('tag [%s]; revision=%s first_uploaded_at=%s (was %s)', :'tag9', :rev9, :'fu9', :'fu7'));

-- ============================================================
-- T28 a resend whose body omits `note` leaves the stored note alone (wire §2:
--     the key is absent when the switch is off; PostgREST sets only sent
--     columns); a body that carries note: null does clear it
-- ============================================================
\echo '--- T28'
select gen_random_uuid() as r3 \gset
select pg_temp.try_exec('U', pg_temp.upsert_sql(:'u', :'r3', :'i1', 'manual_run', 'effort-tap-201', 'effort-tap-20x', :'today', 5, 'debug', 1, '{"wTaps": 1}', 'user_id, run_id', '{"note": "kept across resends"}')) as n_tag1 \gset
select pg_temp.try_exec('U', pg_temp.upsert_sql(:'u', :'r3', :'i1', 'manual_run', 'effort-tap-201', 'effort-tap-20x', :'today', 5, 'debug', 2, '{"wTaps": 2}')) as n_tag2 \gset
select coalesce(max(revision), -1) as n_rev2, coalesce(max(note), '<null>') as n_note2 from public.spike_runs where user_id = :'u' and run_id = :'r3' \gset
select pg_temp.try_exec('U', pg_temp.upsert_sql(:'u', :'r3', :'i1', 'manual_run', 'effort-tap-201', 'effort-tap-20x', :'today', 5, 'debug', 3, '{"wTaps": 3}', 'user_id, run_id', '{"note": null}')) as n_tag3 \gset
select coalesce(max(revision), -1) as n_rev3, coalesce(max(note), '<null>') as n_note3, count(*) filter (where note is null) as n_nulls3 from public.spike_runs where user_id = :'u' and run_id = :'r3' \gset
select pg_temp.rec('T28', 'revision 1 with note, then revision 2 without the note key: the row is at revision 2 and still holds the note; revision 3 with note: null clears it',
  :'n_tag1' = 'INSERT 0 1' and :'n_tag2' = 'INSERT 0 1' and :n_rev2 = 2 and :'n_note2' = 'kept across resends' and :'n_tag3' = 'INSERT 0 1' and :n_rev3 = 3 and :n_nulls3 = 1,
  format('tags [%s] [%s] [%s]; after omit: revision=%s note=%s; after null: revision=%s note=%s', :'n_tag1', :'n_tag2', :'n_tag3', :n_rev2, :'n_note2', :n_rev3, :'n_note3'));

-- ============================================================
-- T5  user V inserts the same run_id -> two rows (the key includes user_id)
-- ============================================================
\echo '--- T5'
select pg_temp.try_exec('V', pg_temp.upsert_sql(:'v', :'r2', :'i2', 'window', 'fix-effort-path', 'auto-window', :'today', 5, 'debug', 1, '{"wTaps": 100}')) as tagv \gset
select count(*) as n5, count(distinct user_id) as users5 from public.spike_runs where run_id = :'r2' \gset
select pg_temp.rec('T5', 'user V upserting U''s run_id creates a second row (primary key is (user_id, run_id)), U''s row untouched',
  :'tagv' = 'INSERT 0 1' and :n5 = 2 and :users5 = 2 and (select revision from public.spike_runs where user_id = :'u' and run_id = :'r2') = 9,
  format('tag [%s]; rows with run_id=%s; distinct users=%s; U''s revision still %s', :'tagv', :n5, :users5, (select revision from public.spike_runs where user_id = :'u' and run_id = :'r2')));

-- ============================================================
-- T6  U cannot see V's rows
-- ============================================================
\echo '--- T6'
select n as u_sees, foreign_rows as u_sees_foreign from dblink('U', format('select count(*), count(*) filter (where user_id <> %L) from public.spike_runs', :'u')) as t(n bigint, foreign_rows bigint) \gset
select count(*) as u_owns from public.spike_runs where user_id = :'u' \gset
select n as u_sees_r2 from dblink('U', format('select count(*) from public.spike_runs where run_id = %L', :'r2')) as t(n bigint) \gset
select pg_temp.rec('T6', 'as U, select sees exactly U''s rows: none of V''s, and one row for the shared run_id',
  :u_sees = :u_owns and :u_sees_foreign = 0 and :u_sees_r2 = 1,
  format('U sees %s rows (owns %s), %s of them foreign; rows for the shared run_id=%s (table has 2)', :u_sees, :u_owns, :u_sees_foreign, :u_sees_r2));

-- ============================================================
-- T7  U cannot update V's row (0 rows), nor hand a row to V
-- ============================================================
\echo '--- T7'
select pg_temp.try_exec('U', format('update public.spike_runs set revision = 50 where user_id = %L and run_id = %L', :'v', :'r2')) as tag7u \gset
select coalesce(max(revision), -1) as v_rev from public.spike_runs where user_id = :'v' and run_id = :'r2' \gset
select pg_temp.try_exec('U', format('update public.spike_runs set user_id = %L, revision = 51 where user_id = %L and run_id = %L', :'v', :'u', :'r1')) as tag7h \gset
select coalesce(bool_and(user_id::text = :'u'), false) as r1_still_u from public.spike_runs where run_id = :'r1' \gset
select pg_temp.rec('T7', 'as U, an update of V''s row affects 0 rows and V''s revision stays; re-owning one''s own row to V is refused by the policy''s with check (42501)',
  :'tag7u' = 'UPDATE 0' and :v_rev = 1 and :'tag7h' = 'ERR:42501' and :'r1_still_u' = 't',
  format('update V''s row: [%s], V revision=%s; set user_id=V: [%s], r1 owner still U=%s', :'tag7u', :v_rev, :'tag7h', :'r1_still_u'));

-- ============================================================
-- T8  U cannot delete its own row: no delete grant -> 42501, not 0 rows
-- ============================================================
\echo '--- T8'
select pg_temp.try_exec('U', format('delete from public.spike_runs where user_id = %L and run_id = %L', :'u', :'r1')) as tag8d \gset
select count(*) as r1_left from public.spike_runs where user_id = :'u' and run_id = :'r1' \gset
select pg_temp.rec('T8', 'as U, deleting one''s own row is refused with permission denied (42501: the grant list has no delete; expected error, not a silent 0 rows) and the row stays',
  :'tag8d' = 'ERR:42501' and :r1_left = 1, format('delete: [%s]; row still present=%s', :'tag8d', :r1_left));

-- ============================================================
-- T9  anon: every operation refused; authenticated/anon have no view or
--     registry access either
-- ============================================================
\echo '--- T9'
select pg_temp.try_exec('A', 'select count(*) from public.spike_runs') as a_sel \gset
select pg_temp.try_exec('A', pg_temp.upsert_sql(:'u', gen_random_uuid(), :'i1', 'window', 'fix-effort-path', 'auto-window', :'today', 5, 'debug', 1, '{}')) as a_ins \gset
select pg_temp.try_exec('A', 'update public.spike_runs set revision = 99') as a_upd \gset
select pg_temp.try_exec('A', 'delete from public.spike_runs') as a_del \gset
select pg_temp.try_exec('A', 'select count(*) from public.key_registry') as a_reg \gset
select pg_temp.try_exec('A', 'select count(*) from public.v_active_installs') as a_view \gset
select pg_temp.rec('T9', 'as anon, select / insert / update / delete on spike_runs, select on key_registry and select on a view are all permission denied (42501)',
  :'a_sel' = 'ERR:42501' and :'a_ins' = 'ERR:42501' and :'a_upd' = 'ERR:42501' and :'a_del' = 'ERR:42501' and :'a_reg' = 'ERR:42501' and :'a_view' = 'ERR:42501',
  format('select [%s] insert [%s] update [%s] delete [%s] key_registry [%s] v_active_installs [%s]', :'a_sel', :'a_ins', :'a_upd', :'a_del', :'a_reg', :'a_view'));
select pg_temp.try_exec('U', 'select count(*) from public.key_registry') as u_reg \gset
select pg_temp.try_exec('U', 'select count(*) from public.counter_long') as u_cl \gset
select pg_temp.try_exec('U', 'select count(*) from public.v_fixwatch_verdicts_by_install') as u_vi \gset
select pg_temp.try_exec('U', 'select public.spike_metric_num(''{"a":1}''::jsonb, ''a'')') as u_fn \gset
select pg_temp.rec('T9', 'as authenticated, key_registry, counter_long, the internal view and the metric reader are not granted (42501): the views are the operator''s, not the client''s',
  :'u_reg' = 'ERR:42501' and :'u_cl' = 'ERR:42501' and :'u_vi' = 'ERR:42501' and :'u_fn' = 'ERR:42501',
  format('key_registry [%s] counter_long [%s] v_fixwatch_verdicts_by_install [%s] spike_metric_num [%s]', :'u_reg', :'u_cl', :'u_vi', :'u_fn'));
select count(*) as sr_grants from information_schema.role_table_grants where table_schema = 'public' and table_name = 'spike_runs' and grantee = 'service_role' \gset
select count(*) as view_grants from information_schema.role_table_grants where table_schema = 'public' and grantee in ('anon', 'authenticated', 'service_role')
  and table_name in ('key_registry', 'counter_long', 'v_active_installs', 'v_feature_unused_30d', 'v_sync_failure_by_build', 'v_metrickit_by_build',
                     'v_fixwatch_verdicts_by_install', 'v_fixwatch_pooled_buckets', 'v_possible_dead_wire') \gset
select pg_temp.rec('T9', 'service_role holds no grant on spike_runs, and anon / authenticated / service_role hold none on key_registry or any view (Supabase''s default privileges were revoked)',
  :sr_grants = 0 and :view_grants = 0, format('service_role grants on spike_runs=%s; client-role grants on registry+views=%s', :sr_grants, :view_grants));

-- ============================================================
-- T10 no 015 trigger on the table; not in sync_changes; no sync columns
-- ============================================================
\echo '--- T10'
select coalesce(string_agg(tgname, ',' order by tgname), '') as trgs,
       count(*) filter (where tgname like 'trg\_%\_sync\_%' or tgname like 'trg\_%\_notify%' or tgname like 'trg\_%\_tombstone' or tgname like 'trg\_%\_no\_truncate') as sync_trgs
from pg_trigger where tgrelid = 'public.spike_runs'::regclass and not tgisinternal \gset
select position('spike_runs' in pg_get_functiondef('public.sync_changes(bigint, int)'::regprocedure)) as in_rpc \gset
select count(*) as sync_cols from information_schema.columns where table_schema = 'public' and table_name = 'spike_runs'
  and column_name in ('seq', 'deleted_at', 'version_id', 'parent_version_id', 'restored_from_version_id') \gset
select pg_temp.rec('T10', 'spike_runs carries exactly one trigger (trg_spike_runs_upload_stamp), none of 015''s trg_*_sync_* / notify / tombstone / no_truncate family, is not a sync_changes arm and has no seq / deleted_at / version columns',
  :'trgs' = 'trg_spike_runs_upload_stamp' and :sync_trgs = 0 and :in_rpc = 0 and :sync_cols = 0,
  format('triggers [%s]; 015-pattern triggers=%s; ''spike_runs'' in sync_changes body at=%s; sync columns=%s', :'trgs', :sync_trgs, :in_rpc, :sync_cols));
select prosecdef::text as secdef, coalesce(array_to_string(proconfig, ';'), '') as cfg from pg_proc where oid = 'public.spike_runs_upload_stamp()'::regprocedure \gset
select coalesce(string_agg(c.relname, ','), '') as definer_views
from pg_class c where c.relkind = 'v' and c.relnamespace = 'public'::regnamespace
  and c.relname in ('counter_long', 'v_active_installs', 'v_feature_unused_30d', 'v_sync_failure_by_build', 'v_metrickit_by_build',
                    'v_fixwatch_verdicts_by_install', 'v_fixwatch_pooled_buckets', 'v_possible_dead_wire')
  and not coalesce((select option_value::boolean from pg_options_to_table(c.reloptions) where option_name = 'security_invoker'), false) \gset
select pg_temp.rec('T10', 'the trigger function is security invoker with an empty search_path, and every view is security_invoker',
  :'secdef' = 'false' and :'cfg' like '%search_path=%' and :'definer_views' = '',
  format('prosecdef=%s proconfig=[%s]; views without security_invoker: [%s]', :'secdef', :'cfg', :'definer_views'));

-- ============================================================
-- T11 key_registry == key_registry.json, row by row, both directions
-- ============================================================
\echo '--- T11'
select length(:'expected_json') as json_len \gset
\if :{?expected_json}
  create temp table expected_key_registry as
    select * from jsonb_populate_recordset(null::public.key_registry, case when :'expected_json' = '' then '[]'::jsonb else :'expected_json'::jsonb end);
\else
  create temp table expected_key_registry as select * from public.key_registry where false;
\endif
select count(*) as exp_n from expected_key_registry \gset
select count(*) as tbl_n from public.key_registry \gset
select count(*) as missing from (
  select key, kind, family, value_schema, since_build, retired_build, liveness_key, spike_id, description from expected_key_registry
  except
  select key, kind, family, value_schema, since_build, retired_build, liveness_key, spike_id, description from public.key_registry) x \gset
select count(*) as extra from (
  select key, kind, family, value_schema, since_build, retired_build, liveness_key, spike_id, description from public.key_registry
  except
  select key, kind, family, value_schema, since_build, retired_build, liveness_key, spike_id, description from expected_key_registry) x \gset
select pg_temp.rec('T11', 'key_registry holds exactly the rows of key_registry.json (every column, both directions), and the set is not empty',
  :exp_n > 0 and :exp_n = :tbl_n and :missing = 0 and :extra = 0,
  format('json rows=%s (json bytes=%s) table rows=%s; in json not in table=%s; in table not in json=%s', :exp_n, :json_len, :tbl_n, :missing, :extra));
select count(*) as live_ok from public.key_registry k join public.key_registry l on l.key = k.liveness_key where l.value_schema = 'number' \gset
select count(*) as live_all from public.key_registry where liveness_key is not null \gset
select pg_temp.rec('T11', 'every liveness_key resolves to a registered number key (the self-FK held through the one-statement loader)',
  :live_all > 0 and :live_ok = :live_all, format('liveness keys=%s resolving to number keys=%s', :live_all, :live_ok));

-- ============================================================
-- T25 key_registry value vocabulary (wire v1.1): number_list is accepted
--     only as a gauge; an unknown value_schema is refused
-- ============================================================
\echo '--- T25'
create function pg_temp.try_local(sql text) returns text language plpgsql as $$
begin
  execute sql;
  return 'OK';
exception when others then
  return 'ERR:' || sqlstate;
end $$;
begin;
select pg_temp.try_local($q$insert into public.key_registry (key, kind, family, value_schema, since_build, spike_id)
  values ('benchListCounter', 'counter', 'fixwatch', 'number_list', 5, 'fix-effort-path')$q$) as nl_counter \gset
select pg_temp.try_local($q$insert into public.key_registry (key, kind, family, value_schema, since_build, spike_id)
  values ('benchListHistogram', 'histogram', 'fixwatch', 'number_list', 5, 'fix-effort-path')$q$) as nl_hist \gset
select pg_temp.try_local($q$insert into public.key_registry (key, kind, family, value_schema, since_build, spike_id)
  values ('benchListGauge', 'gauge', 'fixwatch', 'number_list', 5, 'fix-effort-path')$q$) as nl_gauge \gset
select pg_temp.try_local($q$insert into public.key_registry (key, kind, family, value_schema, since_build, spike_id)
  values ('benchUnknownSchema', 'gauge', 'fixwatch', 'csv', 5, 'fix-effort-path')$q$) as unknown_schema \gset
rollback;
select count(*) as nl_registered from public.key_registry where value_schema = 'number_list' and kind = 'gauge' \gset
select count(*) as nl_pooled from public.v_fixwatch_pooled_buckets p join public.key_registry k on k.key = p.key where k.value_schema = 'number_list' \gset
select pg_temp.rec('T25', 'key_registry refuses value_schema=number_list with kind counter or histogram (23514) and an unknown value_schema (23514), accepts a number_list gauge; the loaded registry carries number_list gauges and the pooled-buckets view never pools them',
  :'nl_counter' = 'ERR:23514' and :'nl_hist' = 'ERR:23514' and :'nl_gauge' = 'OK' and :'unknown_schema' = 'ERR:23514' and :nl_registered > 0 and :nl_pooled = 0,
  format('number_list counter [%s] histogram [%s] gauge [%s]; value_schema=csv [%s]; number_list gauges registered=%s; pooled rows from number_list keys=%s', :'nl_counter', :'nl_hist', :'nl_gauge', :'unknown_schema', :nl_registered, :nl_pooled));

-- ============================================================
-- T26 the generator's two kind/value rules hold in the table too:
--     a counter is a number, a histogram is a fixed_string
-- ============================================================
\echo '--- T26'
begin;
select pg_temp.try_local($q$insert into public.key_registry (key, kind, family, value_schema, since_build, spike_id)
  values ('benchCounterBool', 'counter', 'fixwatch', 'bool', 5, 'fix-effort-path')$q$) as counter_bool \gset
select pg_temp.try_local($q$insert into public.key_registry (key, kind, family, value_schema, since_build, spike_id)
  values ('benchHistogramNumber', 'histogram', 'fixwatch', 'number', 5, 'fix-effort-path')$q$) as hist_number \gset
select pg_temp.try_local($q$insert into public.key_registry (key, kind, family, value_schema, since_build, spike_id)
  values ('benchCounterNumber', 'counter', 'fixwatch', 'number', 5, 'fix-effort-path')$q$) as counter_number \gset
select pg_temp.try_local($q$insert into public.key_registry (key, kind, family, value_schema, since_build, spike_id)
  values ('benchHistogramFixed', 'histogram', 'fixwatch', 'fixed_string', 5, 'fix-effort-path')$q$) as hist_fixed \gset
select count(*) as probes_in from public.key_registry where key like 'bench%' \gset
rollback;
select count(*) as probes_left from public.key_registry where key like 'bench%' \gset
select pg_temp.rec('T26', 'key_registry refuses a counter whose value_schema is bool and a histogram whose value_schema is number (23514), accepts counter+number and histogram+fixed_string; the probes are rolled back',
  :'counter_bool' = 'ERR:23514' and :'hist_number' = 'ERR:23514' and :'counter_number' = 'OK' and :'hist_fixed' = 'OK' and :probes_in = 2 and :probes_left = 0,
  format('counter+bool [%s] histogram+number [%s] counter+number [%s] histogram+fixed_string [%s]; probes inside tx=%s after rollback=%s', :'counter_bool', :'hist_number', :'counter_number', :'hist_fixed', :probes_in, :probes_left));

-- ============================================================
-- T12 counter_long: NULL before since_build, 0 for a missing key in range,
--     the value when present, NULL at/after retired_build; debug rows and
--     non-counter keys absent
-- ============================================================
\echo '--- T12'
select gen_random_uuid() as c4 \gset
select gen_random_uuid() as c5a \gset
select gen_random_uuid() as c5b \gset
select gen_random_uuid() as c5d \gset
select pg_temp.fixture(:'u', :'c4',  :'i1', 'daily_rollup', 'resident-daily', 'daily-rollup', :'today', 4, 'release', '{"tapCount": 3}');
select pg_temp.fixture(:'u', :'c5a', :'i1', 'daily_rollup', 'resident-daily', 'daily-rollup', :'today', 5, 'release', '{"detailBodyPasses": 2, "tapLagBuckets": "1 2 3 4 5 6 7 8"}');
select pg_temp.fixture(:'u', :'c5b', :'i2', 'daily_rollup', 'resident-daily', 'daily-rollup', :'today', 5, 'release', '{"tapCount": 3}');
select pg_temp.fixture(:'u', :'c5d', :'i3', 'daily_rollup', 'resident-daily', 'daily-rollup', :'today', 5, 'debug',   '{"tapCount": 3}');
select coalesce(string_agg(coalesce(value::text, 'NULL'), ','), 'ABSENT') as v4 from public.counter_long where run_id = :'c4'  and key = 'tapCount' \gset
select coalesce(string_agg(coalesce(value::text, 'NULL'), ','), 'ABSENT') as v5a from public.counter_long where run_id = :'c5a' and key = 'tapCount' \gset
select coalesce(string_agg(coalesce(value::text, 'NULL'), ','), 'ABSENT') as v5b from public.counter_long where run_id = :'c5b' and key = 'tapCount' \gset
select count(*) as v5d from public.counter_long where run_id = :'c5d' \gset
select count(*) as hist_rows from public.counter_long where key = 'tapLagBuckets' \gset
select count(*) as keys_per_row from public.counter_long where run_id = :'c5a' \gset
select count(*) as counters_registered from public.key_registry where spike_id = 'resident-daily' and kind = 'counter' \gset
select pg_temp.rec('T12', 'counter_long: tapCount is NULL on an app_build 4 row (since_build 5), 0 on a build-5 row that lacks the key, 3 where present; a debug row has no counter_long rows; a histogram key never appears; a row yields one line per registered counter of its spike',
  :'v4' = 'NULL' and :'v5a' = '0' and :'v5b' = '3' and :v5d = 0 and :hist_rows = 0 and :keys_per_row = :counters_registered and :counters_registered > 0,
  format('build 4: %s; build 5 missing key: %s; build 5 present: %s; debug rows: %s; tapLagBuckets rows: %s; lines for one row=%s (registered resident-daily counters=%s)', :'v4', :'v5a', :'v5b', :v5d, :hist_rows, :keys_per_row, :counters_registered));
begin;
insert into public.key_registry (key, kind, family, value_schema, since_build, retired_build, liveness_key, spike_id, description)
values ('benchRetired', 'counter', 'fixwatch', 'number', 5, 7, null, 'resident-daily', 'bench only');
select gen_random_uuid() as c6 \gset
select gen_random_uuid() as c7 \gset
select pg_temp.fixture(:'u', :'c6', :'i1', 'daily_rollup', 'resident-daily', 'daily-rollup', :'today', 6, 'release', '{"benchRetired": 2}');
select pg_temp.fixture(:'u', :'c7', :'i1', 'daily_rollup', 'resident-daily', 'daily-rollup', :'today', 7, 'release', '{"benchRetired": 2}');
select coalesce(string_agg(coalesce(value::text, 'NULL'), ','), 'ABSENT') as v6 from public.counter_long where run_id = :'c6' and key = 'benchRetired' \gset
select coalesce(string_agg(coalesce(value::text, 'NULL'), ','), 'ABSENT') as v7 from public.counter_long where run_id = :'c7' and key = 'benchRetired' \gset
select coalesce(string_agg(coalesce(value::text, 'NULL'), ','), 'ABSENT') as v5r from public.counter_long where run_id = :'c5a' and key = 'benchRetired' \gset
rollback;
select pg_temp.rec('T12', 'a key retired at build 7 reads its value on build 6, NULL on build 7 (half-open [since, retired)), 0 on a build-5 row that lacks it; the probe key is rolled back',
  :'v6' = '2' and :'v7' = 'NULL' and :'v5r' = '0' and not exists (select 1 from public.key_registry where key = 'benchRetired'),
  format('build 6: %s; build 7: %s; build 5 without the key: %s', :'v6', :'v7', :'v5r'));

-- ============================================================
-- T13 every view's text carries build_configuration = 'release'
-- ============================================================
\echo '--- T13'
select count(*) as views_n,
       coalesce(string_agg(viewname, ',' order by viewname) filter (where definition not like '%build_configuration = ''release''%'), '') as unfiltered
from pg_views where schemaname = 'public' and viewname in
  ('counter_long', 'v_active_installs', 'v_feature_unused_30d', 'v_sync_failure_by_build', 'v_metrickit_by_build',
   'v_fixwatch_verdicts_by_install', 'v_fixwatch_pooled_buckets', 'v_possible_dead_wire') \gset
select pg_temp.rec('T13', 'all eight views exist and each one''s definition text contains build_configuration = ''release''',
  :views_n = 8 and :'unfiltered' = '', format('views found=%s; without the predicate: [%s]', :views_n, :'unfiltered'));

-- ============================================================
-- T15 on_conflict on run_id alone is refused (42P10): the composite key is
--     the only unique constraint, as the wire contract requires
-- ============================================================
\echo '--- T15'
select pg_temp.try_exec('U', pg_temp.upsert_sql(:'u', :'r1', :'i1', 'window', 'fix-effort-path', 'auto-window', :'today', 5, 'debug', 2, '{"wTaps": 2}', 'run_id')) as tag15 \gset
select coalesce(max(revision), -1) as rev15 from public.spike_runs where user_id = :'u' and run_id = :'r1' \gset
select coalesce(string_agg(a.attname, ',' order by a.attnum), '') as pk_cols
from pg_constraint c join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any(c.conkey)
where c.conrelid = 'public.spike_runs'::regclass and c.contype = 'p' \gset
select count(*) as uniques from pg_constraint where conrelid = 'public.spike_runs'::regclass and contype in ('p', 'u') \gset
select pg_temp.rec('T15', 'an upsert with on conflict (run_id) fails with 42P10 (no matching unique constraint) and changes nothing; the primary key is (user_id, run_id) and it is the only unique constraint',
  :'tag15' = 'ERR:42P10' and :rev15 = 1 and :'pk_cols' = 'user_id,run_id' and :uniques = 1,
  format('tag [%s]; r1 revision still %s; pk=(%s); unique constraints=%s', :'tag15', :rev15, :'pk_cols', :uniques));

-- ============================================================
-- T16 shared views expose no install_id / device_model / os_version; no view
--     exposes note; the internal view does expose the device columns
-- ============================================================
\echo '--- T16'
select coalesce(string_agg(table_name || '.' || column_name, ',' order by table_name, column_name), '') as leaks
from information_schema.columns where table_schema = 'public'
  and table_name in ('counter_long', 'v_active_installs', 'v_feature_unused_30d', 'v_sync_failure_by_build', 'v_metrickit_by_build',
                     'v_fixwatch_pooled_buckets', 'v_possible_dead_wire')
  and column_name in ('install_id', 'device_model', 'os_version', 'note') \gset
select count(*) as note_cols from information_schema.columns where table_schema = 'public'
  and table_name in ('counter_long', 'v_active_installs', 'v_feature_unused_30d', 'v_sync_failure_by_build', 'v_metrickit_by_build',
                     'v_fixwatch_verdicts_by_install', 'v_fixwatch_pooled_buckets', 'v_possible_dead_wire')
  and column_name = 'note' \gset
select coalesce(string_agg(column_name, ',' order by column_name), '') as internal_cols from information_schema.columns
where table_schema = 'public' and table_name = 'v_fixwatch_verdicts_by_install' and column_name in ('install_id', 'device_model', 'os_version') \gset
select pg_temp.rec('T16', 'the seven shared views expose no install_id / device_model / os_version / note column; no view at all exposes note; the internal v_fixwatch_verdicts_by_install does carry the three device columns (positive control)',
  :'leaks' = '' and :note_cols = 0 and :'internal_cols' = 'device_model,install_id,os_version',
  format('leaking columns: [%s]; note columns across all views=%s; internal view device columns: [%s]', :'leaks', :note_cols, :'internal_cols'));

-- ============================================================
-- T17 the column checks: kind, build_configuration, revision
-- ============================================================
\echo '--- T17'
select pg_temp.try_exec('U', pg_temp.upsert_sql(:'u', gen_random_uuid(), :'i1', 'bogus', 'fix-effort-path', 'auto-window', :'today', 5, 'debug', 1, '{}')) as k_bad \gset
select pg_temp.try_exec('U', pg_temp.upsert_sql(:'u', gen_random_uuid(), :'i1', 'window', 'fix-effort-path', 'auto-window', :'today', 5, 'staging', 1, '{}')) as c_bad \gset
select pg_temp.try_exec('U', pg_temp.upsert_sql(:'u', gen_random_uuid(), :'i1', 'window', 'fix-effort-path', 'auto-window', :'today', 5, 'debug', 0, '{}')) as r_bad \gset
select pg_temp.try_exec('U', pg_temp.upsert_sql(:'u', gen_random_uuid(), :'i1', 'metrickit_daily', 'metrickit-daily', 'daily', :'today', 5, 'debug', 1, '{}')) as k_ok \gset
select pg_temp.rec('T17', 'kind outside the enum, build_configuration outside debug/release and revision 0 are each refused by a check constraint (23514); a valid kind is accepted',
  :'k_bad' = 'ERR:23514' and :'c_bad' = 'ERR:23514' and :'r_bad' = 'ERR:23514' and :'k_ok' = 'INSERT 0 1',
  format('kind=bogus [%s]; build_configuration=staging [%s]; revision=0 [%s]; kind=metrickit_daily [%s]', :'k_bad', :'c_bad', :'r_bad', :'k_ok'));

-- ============================================================
-- T18 v_active_installs: distinct installs per day × build from release
--     daily_rollup rows; debug rows and other kinds do not count
-- ============================================================
\echo '--- T18'
select coalesce(max(active_installs), 0) as ai from public.v_active_installs where day_key = :'today' and app_build = 5 \gset
select count(*) as ai4 from public.v_active_installs where day_key = :'today' and app_build = 4 \gset
select pg_temp.rec('T18', 'v_active_installs counts the two release installs with a build-5 daily_rollup today (the debug install does not count), and one install under build 4',
  :ai = 2 and :ai4 = 1, format('build 5 active_installs=%s (fixtures: i1, i2 release, i3 debug); build-4 rows=%s', :ai, :ai4));

-- ============================================================
-- T19 v_fixwatch_pooled_buckets: bucket-wise sums of registered histogram
--     keys; malformed and debug values contribute nothing
-- ============================================================
\echo '--- T19'
begin;
select pg_temp.fixture(:'u', gen_random_uuid(), :'i2', 'daily_rollup', 'resident-daily', 'daily-rollup', :'today', 5, 'release', '{"tapLagBuckets": "1 1 1 1 1 1 1 1"}');
select pg_temp.fixture(:'u', gen_random_uuid(), :'i2', 'daily_rollup', 'resident-daily', 'daily-rollup', :'today', 5, 'release', '{"tapLagBuckets": "1 x 3"}');
select pg_temp.fixture(:'u', gen_random_uuid(), :'i2', 'daily_rollup', 'resident-daily', 'daily-rollup', :'today', 5, 'release', '{"tapLagBuckets": 42}');
select pg_temp.fixture(:'u', gen_random_uuid(), :'i3', 'daily_rollup', 'resident-daily', 'daily-rollup', :'today', 5, 'debug',   '{"tapLagBuckets": "9 9 9 9 9 9 9 9"}');
select pg_temp.fixture(:'u', gen_random_uuid(), :'i2', 'daily_rollup', 'resident-daily', 'daily-rollup', :'today', 4, 'release', '{"tapLagBuckets": "5 5 5 5 5 5 5 5"}');
select coalesce(string_agg(bucket_idx || ':' || pooled_count || '/' || rows_pooled, ' ' order by bucket_idx), '') as pooled
from public.v_fixwatch_pooled_buckets where app_build = 5 and key = 'tapLagBuckets' \gset
select count(*) as pooled4 from public.v_fixwatch_pooled_buckets where app_build = 4 \gset
select count(*) as pooled_other from public.v_fixwatch_pooled_buckets where key <> 'tapLagBuckets' \gset
rollback;
select pg_temp.rec('T19', 'pooled buckets for build 5 sum "1 2 3 4 5 6 7 8" + "1 1 1 1 1 1 1 1" bucket-wise over 2 rows; the malformed string, the number, the debug row and the build-4 row (before since_build) contribute nothing; no other key appears',
  :'pooled' = '0:2/2 1:3/2 2:4/2 3:5/2 4:6/2 5:7/2 6:8/2 7:9/2' and :pooled4 = 0 and :pooled_other = 0,
  format('build 5 [%s]; build-4 buckets=%s; other keys=%s', :'pooled', :pooled4, :pooled_other));

-- ============================================================
-- T20 v_possible_dead_wire: expected (in range, daily present, liveness
--     satisfied) and zero everywhere -> listed; a live counter is not
-- ============================================================
\echo '--- T20'
select coalesce(string_agg(key, ',' order by key), '') as dead0 from public.v_possible_dead_wire \gset
-- today's resident-daily fixtures so far: c5a {detailBodyPasses 2} on i1, c5b {tapCount 3} on i2 (build 5, release)
--  -> tapCount is 3 on i2, detailBodyPasses is 2 on i1; every other resident counter is 0 everywhere
--  -> meComputedHidden is NOT expected (its liveness meComputedVisible is 0 on every row)
select position('tapCount' in :'dead0') as dead_tap, position('detailBodyPasses' in :'dead0') as dead_dbp,
       position('meComputedHidden' in :'dead0') as dead_hidden, position('draftComputes' in :'dead0') as dead_draft \gset
begin;
select pg_temp.fixture(:'u', gen_random_uuid(), :'i2', 'daily_rollup', 'resident-daily', 'daily-rollup', :'today', 5, 'release', '{"meComputedVisible": 4}');
select position('meComputedHidden' in coalesce(string_agg(key, ','), '')) as dead_hidden_live from public.v_possible_dead_wire \gset
select coalesce(max(expected_rows), -1) as hidden_expected from public.v_possible_dead_wire where key = 'meComputedHidden' \gset
rollback;
select pg_temp.rec('T20', 'v_possible_dead_wire lists draftComputes (expected on the build-5 dailies, 0 everywhere) and not tapCount / detailBodyPasses (> 0 somewhere); meComputedHidden is listed only once a row shows its liveness key meComputedVisible > 0, and then only that row counts as expected',
  :dead_draft > 0 and :dead_tap = 0 and :dead_dbp = 0 and :dead_hidden = 0 and :dead_hidden_live > 0 and :hidden_expected = 1,
  format('listed before: [%s]; after a row with meComputedVisible=4: meComputedHidden listed=%s with expected_rows=%s', :'dead0', (:dead_hidden_live > 0), :hidden_expected));
select coalesce(max(installs_expected), -1) as draft_installs0 from public.v_possible_dead_wire where key = 'draftComputes' \gset
begin;
select pg_temp.fixture(:'u', gen_random_uuid(), :'i3', 'daily_rollup', 'resident-daily', 'daily-rollup', :'today', 5, 'debug', '{"draftComputes": 5, "meComputedVisible": 4, "tapCount": 0}');
select coalesce(string_agg(key, ',' order by key), '') as dead_dbg from public.v_possible_dead_wire \gset
select coalesce(max(installs_expected), -1) as draft_installs_dbg from public.v_possible_dead_wire where key = 'draftComputes' \gset
rollback;
select pg_temp.rec('T20', 'a debug daily_rollup row (draftComputes 5, meComputedVisible 4) changes nothing: draftComputes stays listed with the same installs_expected, meComputedHidden stays unlisted, the listing is identical',
  :'dead_dbg' = :'dead0' and :draft_installs_dbg = :draft_installs0 and :draft_installs0 = 2 and position('meComputedHidden' in :'dead_dbg') = 0,
  format('listing with the debug row: [%s] (same=%s); draftComputes installs_expected %s -> %s', :'dead_dbg', (:'dead_dbg' = :'dead0'), :draft_installs0, :draft_installs_dbg));

-- ============================================================
-- T21 v_fixwatch_verdicts_by_install: the latest snapshot per install,
--     metrics expanded as sent
-- ============================================================
\echo '--- T21'
begin;
select pg_temp.fixture(:'u', gen_random_uuid(), :'i1', 'verdict_snapshot', 'fixwatch-verdict', 'snapshot', (:'today'::date - 1), 5, 'release', '{"entry1.state": 2, "entry1.alarm": true}', now() - interval '1 day');
select pg_temp.fixture(:'u', gen_random_uuid(), :'i1', 'verdict_snapshot', 'fixwatch-verdict', 'snapshot', :'today', 5, 'release', '{"entry1.state": 3, "entry1.alarm": false, "entry2.state": 1}');
select pg_temp.fixture(:'v', gen_random_uuid(), :'i2', 'verdict_snapshot', 'fixwatch-verdict', 'snapshot', :'today', 5, 'release', '{"entry1.state": 1}');
select pg_temp.fixture(:'u', gen_random_uuid(), :'i3', 'verdict_snapshot', 'fixwatch-verdict', 'snapshot', :'today', 5, 'debug',   '{"entry1.state": 9}');
select coalesce(string_agg(key || '=' || value::text, ' ' order by key), '') as i1_latest, count(distinct day_key) as i1_days
from public.v_fixwatch_verdicts_by_install where install_id = :'i1' \gset
select count(distinct install_id) as installs21, count(*) filter (where install_id = :'i3') as debug21 from public.v_fixwatch_verdicts_by_install \gset
rollback;
select pg_temp.rec('T21', 'the internal verdict view shows i1''s latest snapshot only (three keys, today''s values, as sent), two installs in all, and nothing from the debug install',
  :'i1_latest' = 'entry1.alarm=false entry1.state=3 entry2.state=1' and :i1_days = 1 and :installs21 = 2 and :debug21 = 0,
  format('i1 [%s] over %s day(s); installs=%s; debug rows=%s', :'i1_latest', :i1_days, :installs21, :debug21));

-- ============================================================
-- T22 v_sync_failure_by_build with probe incident keys (rolled back)
-- ============================================================
\echo '--- T22'
begin;
insert into public.key_registry (key, kind, family, value_schema, since_build, retired_build, liveness_key, spike_id, description) values
  ('sync.write.ok',      'counter', 'incident', 'number', 5, null, null, 'incident-daily', 'bench'),
  ('sync.write.network', 'counter', 'incident', 'number', 5, null, null, 'incident-daily', 'bench'),
  ('sync.write.auth',    'counter', 'incident', 'number', 5, null, null, 'incident-daily', 'bench');
select pg_temp.fixture(:'u', gen_random_uuid(), :'i1', 'daily_rollup', 'incident-daily', 'daily', :'today', 5, 'release', '{"sync.write.ok": 8, "sync.write.network": 2, "sync.write.bogus": 50}');
select pg_temp.fixture(:'u', gen_random_uuid(), :'i2', 'daily_rollup', 'incident-daily', 'daily', :'today', 5, 'release', '{"sync.write.ok": 10}');
select pg_temp.fixture(:'u', gen_random_uuid(), :'i3', 'daily_rollup', 'incident-daily', 'daily', :'today', 5, 'debug',   '{"sync.write.network": 99}');
select coalesce(max(ok)::text, '') as ok22, coalesce(max(fail)::text, '') as fail22, coalesce(max(fail_rate)::text, '') as rate22, coalesce(max(rows_counted), -1) as rows22 from public.v_sync_failure_by_build where app_build = 5 \gset
rollback;
select pg_temp.rec('T22', 'v_sync_failure_by_build sums registered sync.write.* counters per build: ok=18, fail=2 (auth absent reads 0, the unregistered sync.write.bogus and the debug row are ignored), fail_rate=0.1 over 2 rows',
  :'ok22' = '18' and :'fail22' = '2' and :'rate22' = '0.1000' and :rows22 = 2,
  format('ok=%s fail=%s fail_rate=%s rows_counted=%s', :'ok22', :'fail22', :'rate22', :rows22));

-- ============================================================
-- T23 v_metrickit_by_build: percentiles and sums over release metrickit rows
-- ============================================================
\echo '--- T23'
begin;
select pg_temp.fixture(:'u', gen_random_uuid(), :'i1', 'metrickit_daily', 'metrickit-daily', 'daily', :'today', 5, 'release', '{"hitchRatio": 0.1, "peakMemMB": 100, "hang": 1, "crash": 0, "diskWriteException": 1}');
select pg_temp.fixture(:'u', gen_random_uuid(), :'i1', 'metrickit_daily', 'metrickit-daily', 'daily', (:'today'::date - 1), 5, 'release', '{"hitchRatio": 0.2, "peakMemMB": 200, "hang": 0, "crash": 2}');
select pg_temp.fixture(:'u', gen_random_uuid(), :'i2', 'metrickit_daily', 'metrickit-daily', 'daily', :'today', 5, 'release', '{"hitchRatio": 0.3, "peakMemMB": 300, "hang": 2, "cpuException": 1}');
select pg_temp.fixture(:'u', gen_random_uuid(), :'i2', 'metrickit_daily', 'metrickit-daily', 'daily', :'today', 5, 'release', '{"hitchRatio": "bad", "hang": "bad"}');
select pg_temp.fixture(:'u', gen_random_uuid(), :'i3', 'metrickit_daily', 'metrickit-daily', 'daily', :'today', 5, 'debug',   '{"hitchRatio": 0.9, "hang": 50}');
select coalesce(max(day_rows), -1) as day_rows, coalesce(max(installs), -1) as installs, coalesce(round(max(hitch_ratio_p50)::numeric, 3)::text, '') as p50,
       coalesce(round(max(peak_mem_mb_p90)::numeric, 0)::text, '') as mem90, coalesce(max(hangs)::text, '') as hangs, coalesce(max(crashes)::text, '') as crashes,
       coalesce(max(cpu_exceptions)::text, '') as cpu, coalesce(max(disk_write_exceptions)::text, '') as dwe
from public.v_metrickit_by_build where app_build = 5 \gset
rollback;
select pg_temp.rec('T23', 'v_metrickit_by_build over 4 release rows / 2 installs: hitchRatio p50 = 0.2 (the string value is ignored), peakMemMB p90 = 280, hangs 3, crashes 2, cpu 1, disk-write 1; the debug row is out',
  :day_rows = 4 and :installs = 2 and :'p50' = '0.200' and :'mem90' = '280' and :'hangs' = '3' and :'crashes' = '2' and :'cpu' = '1' and :'dwe' = '1',
  format('day_rows=%s installs=%s p50=%s mem_p90=%s hangs=%s crashes=%s cpu=%s dwe=%s', :day_rows, :installs, :'p50', :'mem90', :'hangs', :'crashes', :'cpu', :'dwe'));

-- ============================================================
-- T24 v_feature_unused_30d with probe usage keys (rolled back)
-- ============================================================
\echo '--- T24'
begin;
insert into public.key_registry (key, kind, family, value_schema, since_build, retired_build, liveness_key, spike_id, description) values
  ('sessions',  'counter', 'usage', 'number', 5, null, null,       'usage-daily', 'bench'),
  ('feature.a', 'counter', 'usage', 'number', 5, null, 'sessions', 'usage-daily', 'bench'),
  ('feature.b', 'counter', 'usage', 'number', 5, null, 'sessions', 'usage-daily', 'bench'),
  ('feature.c', 'counter', 'usage', 'number', 9, null, 'sessions', 'usage-daily', 'bench');
select pg_temp.fixture(:'u', gen_random_uuid(), :'i1', 'daily_rollup', 'usage-daily', 'daily', :'today', 5, 'release', '{"sessions": 3, "feature.a": 0, "feature.b": 2}');
select pg_temp.fixture(:'u', gen_random_uuid(), :'i2', 'daily_rollup', 'usage-daily', 'daily', :'today', 5, 'release', '{"sessions": 0, "feature.a": 0}');
select pg_temp.fixture(:'u', gen_random_uuid(), :'i2', 'daily_rollup', 'usage-daily', 'daily', (:'today'::date - 40), 5, 'release', '{"sessions": 5, "feature.a": 7}');
select coalesce(string_agg(key || ':' || expected_rows || '/' || installs_expected, ' ' order by key), '') as unused from public.v_feature_unused_30d \gset
select pg_temp.fixture(:'u', gen_random_uuid(), :'i3', 'daily_rollup', 'usage-daily', 'daily', :'today', 5, 'debug', '{"sessions": 3, "feature.a": 9, "feature.b": 0}');
select coalesce(string_agg(key || ':' || expected_rows || '/' || installs_expected, ' ' order by key), '') as unused_dbg from public.v_feature_unused_30d \gset
rollback;
select pg_temp.rec('T24', 'v_feature_unused_30d lists feature.a only (expected on the one row with sessions > 0 in the window; the row 40 days ago where it was used is outside; the sessions=0 row does not count), not feature.b (used), not feature.c (since_build 9: never expected), not sessions itself',
  :'unused' = 'feature.a:1/1', format('listed [%s]', :'unused'));
select pg_temp.rec('T24', 'a debug usage row (sessions 3, feature.a 9, feature.b 0) changes nothing: feature.a stays listed with the same expected_rows / installs_expected and feature.b stays unlisted',
  :'unused_dbg' = :'unused' and :'unused_dbg' = 'feature.a:1/1', format('listed with the debug row [%s] (was [%s])', :'unused_dbg', :'unused'));

-- ============================================================
-- T27 the Lean fixtures (verification/telemetry-fixtures.json, op server.apply
--     / server.fold) replayed against the real trigger as user U: Swift
--     reference model, Lean and the trigger are pinned to one file. A fixture
--     that uses revision 0 contradicts the table's revision >= 1 check and is
--     skipped and counted, never edited.
-- ============================================================
\echo '--- T27'
\if :{?lean_json}
\else
  \set lean_json `cat ../../../verification/telemetry-fixtures.json 2>/dev/null`
\endif
create temp table lean_fx as
  select ord, e->>'op' as op, e->>'label' as label, e->'input' as input, e->'expected' as expected
  from jsonb_array_elements(case when :'lean_json' = '' then '[]'::jsonb else :'lean_json'::jsonb end) with ordinality as t(e, ord)
  where e->>'op' in ('server.apply', 'server.fold');
create temp table lean_res (ord int, op text, label text, skipped boolean, pass boolean, observed text);
create function pg_temp.lean_send(uid uuid, run uuid, rev int) returns text language plpgsql as $$
begin
  return pg_temp.try_exec('U', pg_temp.upsert_sql(uid, run, uid, 'window', 'fix-effort-path', 'auto-window', current_date, 5, 'debug', rev,
                                                  jsonb_build_object('leanRev', rev)));
end $$;
do $$
declare
  f record; run uuid; existing int; incoming int; d int; state int; accepted boolean; exp_state int; exp_accepted boolean;
  revs int[]; tag text; tags text := '';
  uid uuid := current_setting('bench.u')::uuid;
begin
  for f in select * from lean_fx order by ord loop
    run := gen_random_uuid(); tags := '';
    existing := nullif(f.input->>'existing', '')::int;
    if f.op = 'server.apply' then
      incoming := (f.input->>'incoming')::int;
      revs := array[incoming];
    else
      select coalesce(array_agg(x::int), '{}') into revs from jsonb_array_elements_text(f.input->'deliveries') x;
    end if;
    if existing = 0 or 0 = any(revs) then
      insert into lean_res values (f.ord, f.op, f.label, true, true, 'skipped: revision 0 vs check revision >= 1');
      continue;
    end if;
    if existing is not null then
      tag := pg_temp.lean_send(uid, run, existing);
      if tag <> 'INSERT 0 1' then
        insert into lean_res values (f.ord, f.op, f.label, false, false, 'seeding existing failed: ' || tag); continue;
      end if;
    end if;
    foreach d in array revs loop
      tag := pg_temp.lean_send(uid, run, d);
      tags := tags || d || ':' || tag || ' ';
    end loop;
    select max(revision) into state from public.spike_runs where user_id = uid and run_id = run;
    exp_state := nullif(f.expected->>'state', '')::int;
    if f.op = 'server.apply' then
      exp_accepted := (f.expected->>'accepted')::boolean;
      accepted := state is distinct from existing;
      insert into lean_res values (f.ord, f.op, f.label, false,
        state is not distinct from exp_state and accepted = exp_accepted and (accepted = (tags like '%INSERT 0 1%')),
        format('existing=%s incoming=%s -> state=%s (expected %s) accepted=%s (expected %s) tags [%s]', existing, incoming, state, exp_state, accepted, exp_accepted, rtrim(tags)));
    else
      insert into lean_res values (f.ord, f.op, f.label, false,
        state is not distinct from exp_state,
        format('existing=%s deliveries=%s -> state=%s (expected %s) tags [%s]', existing, f.input->'deliveries', state, exp_state, rtrim(tags)));
    end if;
  end loop;
end $$;
select count(*) as fx_total, count(*) filter (where skipped) as fx_skipped, count(*) filter (where not skipped and pass) as fx_pass,
       count(*) filter (where not skipped and not pass) as fx_fail,
       count(*) filter (where op = 'server.apply' and not skipped) as fx_apply, count(*) filter (where op = 'server.fold' and not skipped) as fx_fold,
       coalesce(string_agg(label || ' => ' || observed, '; ') filter (where not skipped and not pass), '') as fx_bad,
       coalesce(string_agg(label, '; ') filter (where skipped), '') as fx_skipped_labels
from lean_res \gset
select pg_temp.rec('T27', 'every Lean server.apply fixture (accepted <=> the row''s revision changed, final state as expected) and every server.fold fixture (final revision as expected) replays against the trigger as user U; revision-0 fixtures are skipped and counted',
  :fx_total > 0 and :fx_apply > 0 and :fx_fold > 0 and :fx_fail = 0 and :fx_pass = :fx_total - :fx_skipped,
  format('fixtures=%s replayed=%s (apply=%s fold=%s) skipped=%s [%s]; failures: [%s]', :fx_total, :fx_pass, :fx_apply, :fx_fold, :fx_skipped, :'fx_skipped_labels', :'fx_bad'));

-- ============================================================
-- 017: public.v_my_spike_runs, the caller's own rows for the observatory
-- (design §16 rules 3 and 4). Two fences — security_invoker (016's RLS
-- applies) and where user_id = auth.uid() — and either alone keeps V's rows
-- out of U's result, so T29 is the row-level outcome and T30 pins each fence
-- structurally (removing one fence leaves T29 green; T30 is what goes red).
-- try_scalar: a remote one-value query whose outcome is the value as text or
-- ERR:<sqlstate>, so a missing view is a FAIL line, not a psql abort (try_exec
-- cannot read: dblink_exec refuses a statement that returns rows, 2F003).
-- ============================================================
create function pg_temp.try_scalar(conn text, sql text) returns text language plpgsql as $$
declare v text;
begin
  select t.x into v from dblink(conn, sql) as t(x text);
  return coalesce(v, '<null>');
exception when others then
  return 'ERR:' || sqlstate;
end $$;

-- ============================================================
-- T29 as U, v_my_spike_runs returns exactly U's rows (all of them, debug
--     too: the client filters build_configuration itself) and none of V's;
--     as V, exactly V's; an authenticated session without a sub sees none
-- ============================================================
\echo '--- T29'
select gen_random_uuid() as m_vrel \gset
select pg_temp.fixture(:'v', :'m_vrel', :'i2', 'daily_rollup', 'resident-daily', 'daily-rollup', :'today', 5, 'release', '{"tapCount": 4}');
select count(*) as m_u_owns,
       count(*) filter (where build_configuration = 'release' and spike_id in ('resident-daily', 'fix-effort-path')) as m_u_owns_f
from public.spike_runs where user_id = :'u' \gset
select count(*) as m_v_owns from public.spike_runs where user_id = :'v' \gset
select pg_temp.try_scalar('U', format('select concat_ws(''/'', count(*), count(*) filter (where user_id <> %L), count(*) filter (where user_id = %L), count(*) filter (where run_id = %L)) from public.v_my_spike_runs',
                                      :'u', :'v', :'m_vrel')) as m_u_sees \gset
select pg_temp.try_scalar('U', format('select count(*) from public.v_my_spike_runs where run_id = %L', :'r2')) as m_u_r2 \gset
select pg_temp.try_scalar('U', 'select count(*) from public.v_my_spike_runs where build_configuration = ''release'' and spike_id in (''resident-daily'', ''fix-effort-path'')') as m_u_f \gset
select pg_temp.try_scalar('V', format('select concat_ws(''/'', count(*), count(*) filter (where user_id <> %L), count(*) filter (where run_id = %L)) from public.v_my_spike_runs',
                                      :'v', :'m_vrel')) as m_v_sees \gset
select dblink_connect('N', :'conninfo');
select pg_temp.try_exec('N', 'set request.jwt.claims = ''{"role":"authenticated"}''') as m_n_claims \gset
select pg_temp.try_exec('N', 'set role authenticated') as m_n_role \gset
select pg_temp.try_scalar('N', 'select count(*) from public.v_my_spike_runs') as m_n_sees \gset
select dblink_disconnect('N');
select pg_temp.rec('T29', 'as U, v_my_spike_runs returns every row U owns (debug and release) and 0 rows of V''s — not the shared run_id''s V row, not V''s release daily_rollup; as V, exactly V''s rows (positive control: the view is not simply empty)',
  :m_u_owns > 0 and :'m_u_sees' = format('%s/0/0/0', :m_u_owns) and :'m_u_r2' = '1' and :m_v_owns >= 2 and :'m_v_sees' = format('%s/0/1', :m_v_owns),
  format('U: total/foreign/V''s/V''s release run = %s (U owns %s); U rows for the shared run_id=%s (table has 2); V: total/foreign/its release run = %s (V owns %s)',
         :'m_u_sees', :m_u_owns, :'m_u_r2', :'m_v_sees', :m_v_owns));
select pg_temp.rec('T29', 'as U, the client''s filter (build_configuration = release, spike_id in resident-daily / fix-effort-path) returns exactly U''s matching rows, and there are some; an authenticated session whose claims carry no sub (auth.uid() null) sees 0 rows',
  :m_u_owns_f > 0 and :'m_u_f' = :'m_u_owns_f' and :'m_n_claims' = 'SET' and :'m_n_role' = 'SET' and :'m_n_sees' = '0',
  format('filtered via view=%s, U''s matching rows in the table=%s; no-sub session [%s %s] sees %s', :'m_u_f', :m_u_owns_f, :'m_n_claims', :'m_n_role', :'m_n_sees'));

-- ============================================================
-- T30 the view's columns are spike_runs' columns minus note /
--     first_uploaded_at / last_uploaded_at, in table order; both fences are
--     in the catalog: security_invoker=true and auth.uid() in the where
-- ============================================================
\echo '--- T30'
select coalesce(string_agg(column_name, ',' order by ordinal_position), '') as m_cols,
       count(*) filter (where column_name in ('note', 'first_uploaded_at', 'last_uploaded_at')) as m_hidden_shown
from information_schema.columns where table_schema = 'public' and table_name = 'v_my_spike_runs' \gset
select coalesce(string_agg(column_name, ',' order by ordinal_position) filter (where column_name not in ('note', 'first_uploaded_at', 'last_uploaded_at')), '') as m_cols_exp,
       count(*) filter (where column_name in ('note', 'first_uploaded_at', 'last_uploaded_at')) as m_base_has3
from information_schema.columns where table_schema = 'public' and table_name = 'spike_runs' \gset
select pg_temp.rec('T30', 'v_my_spike_runs has exactly spike_runs'' columns minus note, first_uploaded_at and last_uploaded_at (same order); none of the three appears, and the table does carry all three (so their absence is not vacuous)',
  :'m_cols' <> '' and :'m_cols' = :'m_cols_exp' and :m_hidden_shown = 0 and :m_base_has3 = 3,
  format('view columns [%s]; expected [%s]; hidden columns shown=%s; table has the three=%s', :'m_cols', :'m_cols_exp', :m_hidden_shown, :m_base_has3));
select coalesce(max(array_to_string(c.reloptions, ',')), '') as m_relopts,
       coalesce(bool_or(position('auth.uid()' in pg_get_viewdef(c.oid)) > 0), false) as m_uid_where,
       coalesce(bool_or(position('spike_runs' in pg_get_viewdef(c.oid)) > 0), false) as m_reads_table
from pg_class c where c.oid = to_regclass('public.v_my_spike_runs') and c.relkind = 'v' \gset
select pg_temp.rec('T30', 'both fences are in the catalog: the view is security_invoker=true (016''s RLS applies to the caller) and its definition reads spike_runs filtered by auth.uid()',
  :'m_relopts' like '%security_invoker=true%' and :'m_uid_where' = 't' and :'m_reads_table' = 't',
  format('reloptions [%s]; auth.uid() in definition=%s; reads spike_runs=%s', :'m_relopts', :'m_uid_where', :'m_reads_table'));

-- ============================================================
-- T31 grants: select to authenticated and nothing else — anon and
--     service_role are refused (42501); U cannot write through the view
--     (a one-table view is auto-updatable, so only the missing grant stops it)
-- ============================================================
\echo '--- T31'
select pg_temp.try_scalar('A', 'select count(*) from public.v_my_spike_runs') as m_anon \gset
select dblink_connect('S', :'conninfo');
select pg_temp.try_exec('S', 'set role service_role') as m_s_role \gset
select pg_temp.try_scalar('S', 'select count(*) from public.v_my_spike_runs') as m_sr \gset
select dblink_disconnect('S');
select pg_temp.try_exec('U', format('update public.v_my_spike_runs set revision = revision + 100 where user_id = %L', :'u')) as m_upd \gset
select pg_temp.try_exec('U', format('delete from public.v_my_spike_runs where user_id = %L', :'u')) as m_del \gset
select pg_temp.try_exec('U', format('insert into public.v_my_spike_runs (user_id, run_id) values (%L, gen_random_uuid())', :'u')) as m_ins \gset
select count(*) as m_u_rows_after from public.spike_runs where user_id = :'u' \gset
select coalesce(string_agg(grantee || ':' || privilege_type, ',' order by grantee, privilege_type), '') as m_grants
from information_schema.role_table_grants where table_schema = 'public' and table_name = 'v_my_spike_runs'
  and grantee in ('anon', 'authenticated', 'service_role', 'PUBLIC') \gset
select pg_temp.rec('T31', 'as anon and as service_role, select on v_my_spike_runs is permission denied (42501); the client-role grants on the view are exactly authenticated:SELECT',
  :'m_anon' = 'ERR:42501' and :'m_s_role' = 'SET' and :'m_sr' = 'ERR:42501' and :'m_grants' = 'authenticated:SELECT',
  format('anon [%s]; service_role [%s] -> [%s]; grants [%s]', :'m_anon', :'m_s_role', :'m_sr', :'m_grants'));
select pg_temp.rec('T31', 'as U, update / delete / insert through v_my_spike_runs are permission denied (42501) and U''s rows are untouched',
  :'m_upd' = 'ERR:42501' and :'m_del' = 'ERR:42501' and :'m_ins' = 'ERR:42501' and :m_u_rows_after = :m_u_owns,
  format('update [%s] delete [%s] insert [%s]; U rows %s -> %s', :'m_upd', :'m_del', :'m_ins', :m_u_owns, :m_u_rows_after));

-- ============================================================
-- T32 the eight shared views stay closed to authenticated: as U each select
--     is 42501, while the same session reads v_my_spike_runs (positive
--     control); no client role holds a grant on any of the eight
-- ============================================================
\echo '--- T32'
select count(*) as m_shared_n,
       count(*) filter (where res <> 'ERR:42501') as m_shared_open,
       string_agg(v || '=' || res, ' ' order by v) as m_shared_res
from (select v, pg_temp.try_scalar('U', format('select count(*) from public.%I', v)) as res
      from unnest(array['counter_long', 'v_active_installs', 'v_feature_unused_30d', 'v_sync_failure_by_build', 'v_metrickit_by_build',
                        'v_fixwatch_verdicts_by_install', 'v_fixwatch_pooled_buckets', 'v_possible_dead_wire']) v) x \gset
select pg_temp.try_scalar('U', 'select count(*) from public.v_my_spike_runs') as m_mine_ok \gset
select count(*) as m_shared_grants from information_schema.role_table_grants where table_schema = 'public'
  and grantee in ('anon', 'authenticated', 'service_role', 'PUBLIC')
  and table_name in ('counter_long', 'v_active_installs', 'v_feature_unused_30d', 'v_sync_failure_by_build', 'v_metrickit_by_build',
                     'v_fixwatch_verdicts_by_install', 'v_fixwatch_pooled_buckets', 'v_possible_dead_wire') \gset
select pg_temp.rec('T32', 'as U (authenticated), selecting from each of the eight shared views is permission denied (42501) while the same session reads v_my_spike_runs; no client role holds a grant on the eight',
  :m_shared_n = 8 and :m_shared_open = 0 and :'m_mine_ok' = :m_u_owns::text and :m_shared_grants = 0,
  format('[%s]; v_my_spike_runs [%s rows, U owns %s]; client-role grants on the eight=%s', :'m_shared_res', :'m_mine_ok', :m_u_owns, :m_shared_grants));

-- ============================================================
-- T33 a rerun of 017 (twice) recreates the view (new oid) with the same
--     columns, options and grants, and U reads the same rows through it
-- ============================================================
\echo '--- T33'
create function pg_temp.my_view_state() returns text language sql as $$
  select format('cols=[%s] opts=[%s] grants=[%s]',
    (select coalesce(string_agg(column_name || ':' || data_type, ',' order by ordinal_position), '')
       from information_schema.columns where table_schema = 'public' and table_name = 'v_my_spike_runs'),
    (select coalesce(max(array_to_string(reloptions, ',')), '') from pg_class where oid = to_regclass('public.v_my_spike_runs')),
    (select coalesce(string_agg(grantee || ':' || privilege_type, ',' order by grantee, privilege_type), '')
       from information_schema.role_table_grants where table_schema = 'public' and table_name = 'v_my_spike_runs'
        and grantee in ('anon', 'authenticated', 'service_role', 'PUBLIC')))
$$;
select pg_temp.my_view_state() as m_state0, coalesce(to_regclass('public.v_my_spike_runs')::oid::text, '') as m_oid0 \gset
select pg_temp.try_scalar('U', 'select count(*) from public.v_my_spike_runs') as m_n0 \gset
set client_min_messages = warning;
\ir ../migrations/017_spike_runs_my_view.sql
\ir ../migrations/017_spike_runs_my_view.sql
set client_min_messages = notice;
select pg_temp.my_view_state() as m_state1, coalesce(to_regclass('public.v_my_spike_runs')::oid::text, '') as m_oid1 \gset
select pg_temp.try_scalar('U', 'select count(*) from public.v_my_spike_runs') as m_n1 \gset
select pg_temp.rec('T33', 'rerunning 017 twice drops and recreates the view (its oid changes) and leaves the same columns, options and grants (authenticated:SELECT only); U reads the same row count through it before and after',
  :'m_oid0' <> '' and :'m_oid1' <> '' and :'m_oid0' <> :'m_oid1' and :'m_state0' = :'m_state1' and :'m_state1' like '%grants=[authenticated:SELECT]%'
    and :'m_n0' = :'m_n1' and :'m_n0' = :m_u_owns::text,
  format('oid %s -> %s; %s -> %s; U rows via view %s -> %s (owns %s)', :'m_oid0', :'m_oid1', :'m_state0', :'m_state1', :'m_n0', :'m_n1', :m_u_owns));

-- ============================================================
-- T14 cleanup through the cascade: deleting the auth.users rows removes
--     every spike_runs row of U and V
-- ============================================================
\echo '--- T14'
select dblink_disconnect('U');
select dblink_disconnect('V');
select dblink_disconnect('A');
select count(*) as rows0 from public.spike_runs where user_id in (:'u', :'v') \gset
delete from auth.users where id in (:'u', :'v');
select count(*) as rows1 from public.spike_runs where user_id in (:'u', :'v') \gset
select pg_temp.rec('T14', 'deleting the two fixture users from auth.users cascades: their spike_runs rows are gone (no tombstone, no trigger in the way)',
  :rows0 > 0 and :rows1 = 0, format('rows of U and V %s -> %s', :rows0, :rows1));

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
  do $$ begin raise exception 'telemetry_checks: some checks failed'; end $$;
\else
  \echo 'all SQL checks passed'
\endif
