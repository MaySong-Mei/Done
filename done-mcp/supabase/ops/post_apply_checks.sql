-- Post-apply checks for migration 015 (sync change feed). Read-only.
-- Run after every apply of 015, every redeploy that reruns the migrations,
-- every restore, every re-enable and every manual data fix:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f post_apply_checks.sql
-- Prints PASS/FAIL per check and raises at the end when any check failed,
-- so psql exits non-zero (exit status 3 under ON_ERROR_STOP).
-- The table list is the one in section 5 of the migration; keep them equal.
-- The HTTP half (a user JWT's GET of sync_epoch and call of is_ancestor, the
-- max_rows probe) is in ops/README.md; it needs a signed-in user.

\set QUIET on
\pset pager off
\set ON_ERROR_STOP on

create temp table if not exists post_apply (ord serial, id text, claim text, pass boolean, observed text);
truncate post_apply;

-- P1: every sync trigger present and enabled, no stamp trigger
with tables(t) as (
  select unnest(array[
    'events', 'event_logs', 'event_feedback', 'todo_lists', 'event_types',
    'skill_insights', 'user_settings', 'agent_preferences', 'agent_conversations'])
), wanted(t, tgname, fn, timing) as (
  select t, 'trg_' || t || '_sync_gate',    'sync_gate',                'row before insert/update' from tables
  union all
  select t, 'trg_' || t || '_sync_meta',    'set_sync_meta',            'row before insert/update' from tables
  union all
  select t, 'trg_' || t || '_sync_version', 'sync_log_version',         'row after insert/update' from tables
  union all
  select t, 'trg_' || t || '_notify_ins',   'notify_sync_change',       'statement after insert' from tables
  union all
  select t, 'trg_' || t || '_notify_upd',   'notify_sync_change',       'statement after update' from tables
  union all
  select t, 'trg_' || t || '_tombstone',    'sync_delete_to_tombstone', 'row before delete' from tables
  union all
  select t, 'trg_' || t || '_no_truncate',  'sync_refuse_truncate',     'statement before truncate' from tables
), found as (
  select w.t, w.tgname, w.fn, w.timing,
         tg.tgenabled, p.proname,
         -- tgtype bits: 1 row, 2 before, 4 insert, 8 delete, 16 update, 32 truncate
         tg.tgtype
  from wanted w
  left join pg_trigger tg
    on tg.tgrelid = to_regclass('public.' || w.t) and tg.tgname = w.tgname and not tg.tgisinternal
  left join pg_proc p on p.oid = tg.tgfoid
), judged as (
  select *,
         -- an absent trigger yields NULLs here; coalesce so it counts as a
         -- failure instead of being skipped by bool_and
         coalesce(tgenabled = 'O'
         and proname = fn
         and case timing
               when 'row before insert/update'  then tgtype & (1|2|4|16) = (1|2|4|16) and tgtype & (8|32) = 0
               when 'row after insert/update'   then tgtype & (1|2) = 1 and tgtype & (4|8|16|32) = (4|16)
               when 'statement after insert'    then tgtype & (1|2) = 0 and tgtype & (4|8|16|32) = 4
               when 'statement after update'    then tgtype & (1|2) = 0 and tgtype & (4|8|16|32) = 16
               when 'row before delete'         then tgtype & (1|2) = (1|2) and tgtype & (4|8|16|32) = 8
               when 'statement before truncate' then tgtype & (1|2) = 2 and tgtype & (4|8|16|32) = 32
             end, false) as ok
  from found
), stamps as (
  select string_agg(tg.tgname, ', ') as names
  from tables join pg_trigger tg on tg.tgrelid = to_regclass('public.' || t)
  where tg.tgname = 'trg_' || t || '_sync_stamp'
)
insert into post_apply (id, claim, pass, observed)
select 'P1',
       'every synced table has its sync_gate, sync_meta, sync_version, notify_ins, notify_upd, tombstone and no_truncate triggers, ENABLED (tgenabled = O), on the right function and timing, and no stamp trigger (rollback only)',
       bool_and(ok) and (select names from stamps) is null,
       case when bool_and(ok) then format('%s triggers checked, all enabled', count(*))
            else 'missing, disabled or wrong: ' || string_agg(
                   format('%s(tgenabled=%s fn=%s)', tgname, coalesce(tgenabled::text, 'absent'), coalesce(proname, '-')),
                   ', ' order by tgname) filter (where not ok)
       end || coalesce('; stamp triggers present: ' || (select names from stamps), '')
from judged;

insert into post_apply (id, claim, pass, observed)
select 'P2',
       'realtime.messages has exactly one policy and it is ''own sync topic'' (SELECT, authenticated)',
       count(*) = 1 and bool_and(policyname = 'own sync topic' and cmd = 'SELECT' and roles = '{authenticated}'),
       coalesce(string_agg(format('%s/%s/%s', policyname, cmd, roles), '; '), 'no policy')
from pg_policies where schemaname = 'realtime' and tablename = 'messages';

insert into post_apply (id, claim, pass, observed)
select 'P3',
       'notify_sync_change is owned by postgres and SECURITY DEFINER, with an empty search_path',
       coalesce(bool_and(pg_get_userbyid(p.proowner) = 'postgres' and p.prosecdef
                         and 'search_path=""' = any(coalesce(p.proconfig, '{}'))), false),
       coalesce(string_agg(format('owner=%s security_definer=%s config=%s',
                pg_get_userbyid(p.proowner), p.prosecdef, coalesce(p.proconfig::text, '{}')), '; '), 'function absent')
from pg_proc p where p.oid = to_regprocedure('public.notify_sync_change()');

insert into post_apply (id, claim, pass, observed)
select 'P4',
       'sync_changes is not executable by anon or PUBLIC, and is executable by authenticated',
       f.oid is not null
       and f.proacl is not null  -- a null ACL is the default, which grants EXECUTE to PUBLIC
       and not exists (select 1 from aclexplode(f.proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE')
       and not has_function_privilege('anon', f.oid, 'EXECUTE')
       and has_function_privilege('authenticated', f.oid, 'EXECUTE'),
       case when f.oid is null then 'function absent'
            else format('acl=%s anon=%s authenticated=%s', coalesce(f.proacl::text, 'default (PUBLIC)'),
                        has_function_privilege('anon', f.oid, 'EXECUTE'),
                        has_function_privilege('authenticated', f.oid, 'EXECUTE')) end
from (select to_regprocedure('public.sync_changes(bigint, integer)') as oid) r
left join pg_proc f on f.oid = r.oid;

-- P5: the v6 shape. Columns that must exist and columns that must not.
select to_regclass('public.sync_epoch') is not null as has_sync_epoch \gset
\if :has_sync_epoch
select count(*)::text as epoch_rows, (count(*) = 1 and bool_and(epoch <> '')) as epoch_rows_ok from public.sync_epoch \gset
\else
\set epoch_rows 'table absent'
\set epoch_rows_ok f
\endif
with want(rel, col, present) as (
  values ('sync_epoch', 'epoch', true), ('sync_epoch', 'paused', true), ('sync_epoch', 'rollback', true),
         ('sync_epoch', 'restores', true), ('sync_epoch', 'changed_at', true),
         ('sync_epoch', 'floor', false), ('sync_epoch', 'lost', false),
         ('events', 'domino_anchor', true),
         ('events', 'version_id', true), ('events', 'parent_version_id', true), ('events', 'restored_from_version_id', true),
         ('event_logs', 'version_id', true), ('event_logs', 'parent_version_id', true), ('event_logs', 'restored_from_version_id', true),
         ('event_feedback', 'version_id', true), ('event_feedback', 'parent_version_id', true), ('event_feedback', 'restored_from_version_id', true),
         ('todo_lists', 'version_id', true), ('todo_lists', 'parent_version_id', true), ('todo_lists', 'restored_from_version_id', true),
         ('event_types', 'version_id', true), ('event_types', 'parent_version_id', true), ('event_types', 'restored_from_version_id', true),
         ('skill_insights', 'version_id', true), ('skill_insights', 'parent_version_id', true), ('skill_insights', 'restored_from_version_id', true),
         ('user_settings', 'version_id', true), ('user_settings', 'parent_version_id', true), ('user_settings', 'restored_from_version_id', true),
         ('agent_preferences', 'version_id', true), ('agent_preferences', 'parent_version_id', true), ('agent_preferences', 'restored_from_version_id', true),
         ('agent_conversations', 'version_id', true), ('agent_conversations', 'parent_version_id', true), ('agent_conversations', 'restored_from_version_id', true),
         ('sync_versions', 'version_id', true), ('sync_versions', 'parent_version_id', true), ('sync_versions', 'restored_from_version_id', true),
         ('sync_versions', 'seq', true), ('sync_versions', 'created_at', true)
), judged as (
  select rel, col, present,
         exists (select 1 from pg_attribute a
                 where a.attrelid = to_regclass('public.' || rel) and a.attname = col and not a.attisdropped) as found
  from want
)
insert into post_apply (id, claim, pass, observed)
select 'P5',
       'v6 shape: sync_epoch has epoch/paused/rollback/restores and NOT floor/lost; sync_epoch holds exactly one row; the nine tables carry version_id/parent_version_id/restored_from_version_id; events.domino_anchor and public.sync_versions exist',
       bool_and(found = present)
       and to_regclass('public.sync_epoch') is not null and to_regclass('public.sync_versions') is not null
       and :'has_sync_epoch' = 't' and :'epoch_rows_ok' = 't',
       format('sync_epoch rows=%s; ', :'epoch_rows')
       || coalesce('wrong: ' || string_agg(format('%s.%s %s', rel, col, case when present then 'absent' else 'present' end), ', ')
                   filter (where found <> present), format('%s columns as expected', count(*)))
from judged;

select to_regclass('public.sync_epoch') is not null as has_sync_epoch \gset
\if :has_sync_epoch
insert into post_apply (id, claim, pass, observed)
select 'P6',
       'sync_epoch: RLS on, authenticated may only SELECT, anon has nothing, service_role cannot write',
       c.relrowsecurity
       and has_table_privilege('authenticated', c.oid, 'SELECT')
       and not has_table_privilege('authenticated', c.oid, 'INSERT, UPDATE, DELETE, TRUNCATE')
       and not has_table_privilege('anon', c.oid, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE')
       and not has_table_privilege('service_role', c.oid, 'INSERT, UPDATE, DELETE, TRUNCATE')
       and exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'sync_epoch'
                   and cmd = 'SELECT' and roles = '{authenticated}'),
       format('rls=%s authenticated select=%s write=%s anon any=%s service_role write=%s policies=%s', c.relrowsecurity,
              has_table_privilege('authenticated', c.oid, 'SELECT'),
              has_table_privilege('authenticated', c.oid, 'INSERT, UPDATE, DELETE, TRUNCATE'),
              has_table_privilege('anon', c.oid, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE'),
              has_table_privilege('service_role', c.oid, 'INSERT, UPDATE, DELETE, TRUNCATE'),
              (select string_agg(policyname || '/' || cmd || '/' || roles::text, '; ')
                 from pg_policies where schemaname = 'public' and tablename = 'sync_epoch'))
from pg_class c where c.oid = to_regclass('public.sync_epoch');
\else
insert into post_apply (id, claim, pass, observed) values
  ('P6', 'sync_epoch: RLS on, authenticated may only SELECT, anon has nothing, service_role cannot write', false, 'table public.sync_epoch absent');
\endif

-- Through PostgREST a clamp above max_rows is invisible (max_rows cuts the
-- page anyway), so the deployed body is the only place it can be checked.
insert into post_apply (id, claim, pass, observed)
select 'P7',
       'sync_changes clamps page_limit to PostgREST max_rows: limit greatest(1, least(page_limit, 1000))',
       coalesce(f.prosrc ~* 'limit\s+greatest\(\s*1\s*,\s*least\(\s*page_limit\s*,\s*1000\s*\)\s*\)', false),
       coalesce('deployed limit clause: ' || coalesce(substring(f.prosrc from '(?i)limit\s+[^;]*'), 'none'), 'function absent')
from (select to_regprocedure('public.sync_changes(bigint, integer)') as oid) r
left join pg_proc f on f.oid = r.oid;

-- ops/rollback.sql gives seq a column default so writes that leave seq out
-- keep working with the triggers gone; ops/reenable.sql removes it. A
-- default still present means the re-enable is not finished.
with tables(t) as (
  select unnest(array[
    'events', 'event_logs', 'event_feedback', 'todo_lists', 'event_types',
    'skill_insights', 'user_settings', 'agent_preferences', 'agent_conversations'])
), cols as (
  select t, a.attnum is not null as present, a.attnotnull, pg_get_expr(d.adbin, d.adrelid) as dflt
  from tables
  left join pg_attribute a on a.attrelid = to_regclass('public.' || t) and a.attname = 'seq' and not a.attisdropped
  left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
)
insert into post_apply (id, claim, pass, observed)
select 'P8',
       'seq on every synced table is NOT NULL with no column default (a default is the rollback''s, see ops/README.md "Rollback")',
       bool_and(coalesce(present and attnotnull and dflt is null, false)),
       case when bool_and(coalesce(present and attnotnull and dflt is null, false))
            then format('%s tables checked, seq not null, no default', count(*))
            else 'wrong: ' || string_agg(format('%s(present=%s not_null=%s default=%s)', t, present,
                                                coalesce(attnotnull::text, '-'), coalesce(dflt, 'none')), ', ')
                              filter (where not coalesce(present and attnotnull and dflt is null, false))
       end
from cols;

-- Every seq a synced row holds came from sync_seq, so the sequence's last
-- handed-out value is at or above all of them (a cursor never passes the
-- counter). A counter behind the rows (a setval downward, or rows restored
-- without their sequence) hands those numbers out again. A never-called
-- sequence (is_called false) hands out last_value itself next, so its last
-- handed-out value is last_value - 1, as in restore_with_epoch.sql.
do $$
declare
  t text;
  m bigint;
  top bigint;
  top_t text;
  handed bigint;
  seq_state text;
  no_seq text;
begin
  if to_regclass('public.sync_seq') is null then
    insert into post_apply (id, claim, pass, observed)
    values ('P9', 'sync_seq has handed out every seq a synced row holds', false, 'sequence public.sync_seq absent');
    return;
  end if;
  select case when is_called then last_value else last_value - 1 end,
         format('last_value=%s is_called=%s', last_value, is_called)
    into handed, seq_state
  from public.sync_seq;
  foreach t in array array[
    'events', 'event_logs', 'event_feedback', 'todo_lists', 'event_types',
    'skill_insights', 'user_settings', 'agent_preferences', 'agent_conversations'
  ] loop
    if not exists (select 1 from pg_attribute
                   where attrelid = to_regclass('public.' || t) and attname = 'seq' and not attisdropped) then
      no_seq := concat_ws(', ', no_seq, t);
      continue;
    end if;
    execute format('select max(seq) from public.%I', t) into m;
    if m is not null and (top is null or m > top) then
      top := m;
      top_t := t;
    end if;
  end loop;
  insert into post_apply (id, claim, pass, observed)
  values ('P9',
          'sync_seq has handed out every seq a synced row holds: its last value (last_value, or last_value - 1 when never called) >= max(seq) over every synced table',
          no_seq is null and (top is null or top <= handed),
          format('%s, last handed out=%s; max(seq)=%s%s', seq_state, handed,
                 coalesce(top::text || ' (' || top_t || ')', 'none, no rows'),
                 coalesce('; no seq column: ' || no_seq, '')));
end;
$$;

-- P10: the restore ledger is non-empty and its last record names the
-- current epoch. An empty ledger means no epoch step has run on this
-- database since it was created: after the first apply run the epoch step
-- once (README "First apply"); after a manual restore into a new project
-- that did not bring sync_epoch along, this is the §9.37 (1) residual made
-- visible.
select (select count(*) from pg_attribute where attrelid = to_regclass('public.sync_epoch')
               and attname in ('restores', 'paused', 'rollback', 'epoch') and not attisdropped) = 4 as has_restores \gset
\if :has_restores
insert into post_apply (id, claim, pass, observed)
select 'P10',
       'the restore ledger (sync_epoch.restores) is a non-empty array whose last record''s epoch is the current epoch, and paused/rollback are booleans',
       coalesce((select count(*) = 1
                   and bool_and(jsonb_typeof(restores) = 'array' and jsonb_array_length(restores) > 0
                                and restores -> -1 ->> 'epoch' = epoch
                                and (restores -> -1) ? 'kept_max' and (restores -> -1) ? 'dump_epoch')
                 from public.sync_epoch), false),
       coalesce((select format('epoch=%s paused=%s rollback=%s ledger_len=%s last=%s', epoch, paused, rollback,
                               case when jsonb_typeof(restores) = 'array' then jsonb_array_length(restores)::text else 'not an array' end,
                               coalesce((restores -> -1)::text, 'none'))
                 from public.sync_epoch limit 1), 'no row');
\else
insert into post_apply (id, claim, pass, observed)
values ('P10', 'the restore ledger is non-empty and ends with the current epoch', false, 'sync_epoch or one of its columns epoch/paused/rollback/restores is absent');
\endif

-- P11: the ancestry oracle and the pruner exist with the right privileges.
insert into post_apply (id, claim, pass, observed)
select 'P11',
       'is_ancestor(text, text, uuid, uuid) exists, SECURITY INVOKER, executable by authenticated and not by anon or PUBLIC; sync_versions_prune(int) exists, SECURITY DEFINER owned by postgres, not executable by anon, authenticated or PUBLIC; sync_versions has RLS on and anon has nothing',
       a.oid is not null and not a.prosecdef and a.proacl is not null
       and not exists (select 1 from aclexplode(a.proacl) x where x.grantee = 0 and x.privilege_type = 'EXECUTE')
       and not has_function_privilege('anon', a.oid, 'EXECUTE')
       and has_function_privilege('authenticated', a.oid, 'EXECUTE')
       and p.oid is not null and p.prosecdef and pg_get_userbyid(p.proowner) = 'postgres' and p.proacl is not null
       and not exists (select 1 from aclexplode(p.proacl) x where x.grantee = 0 and x.privilege_type = 'EXECUTE')
       and not has_function_privilege('anon', p.oid, 'EXECUTE')
       and not has_function_privilege('authenticated', p.oid, 'EXECUTE')
       and v.oid is not null and v.relrowsecurity
       and not has_table_privilege('anon', v.oid, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE')
       and not has_table_privilege('authenticated', v.oid, 'UPDATE, DELETE, TRUNCATE'),
       format('is_ancestor: %s; prune: %s; sync_versions: %s',
              case when a.oid is null then 'absent' else format('definer=%s anon=%s authenticated=%s acl=%s', a.prosecdef,
                   has_function_privilege('anon', a.oid, 'EXECUTE'), has_function_privilege('authenticated', a.oid, 'EXECUTE'),
                   coalesce(a.proacl::text, 'default (PUBLIC)')) end,
              case when p.oid is null then 'absent' else format('definer=%s owner=%s anon=%s authenticated=%s acl=%s', p.prosecdef,
                   pg_get_userbyid(p.proowner), has_function_privilege('anon', p.oid, 'EXECUTE'),
                   has_function_privilege('authenticated', p.oid, 'EXECUTE'), coalesce(p.proacl::text, 'default (PUBLIC)')) end,
              case when v.oid is null then 'absent' else format('rls=%s anon any=%s authenticated update/delete=%s', v.relrowsecurity,
                   has_table_privilege('anon', v.oid, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE'),
                   has_table_privilege('authenticated', v.oid, 'UPDATE, DELETE, TRUNCATE')) end)
from (select to_regprocedure('public.is_ancestor(text, text, uuid, uuid)') as aoid,
             to_regprocedure('public.sync_versions_prune(integer)') as poid,
             to_regclass('public.sync_versions') as void) r
left join pg_proc a on a.oid = r.aoid
left join pg_proc p on p.oid = r.poid
left join pg_class v on v.oid = r.void;

-- P12: every synced row's current version (tombstones included) is in the
-- log, and no row carries a restored_from_version_id (the trigger consumes
-- it). Red after a rollback for rows inserted in the window, and after a
-- restore of a dump older than the retention: rerun 015 (its backfill adds
-- the missing entries with parent null).
select to_regclass('public.sync_versions') is not null as has_versions \gset
\if :has_versions
do $$
declare
  t text;
  missing bigint;
  carried bigint;
  total_missing bigint := 0;
  total_carried bigint := 0;
  rows_total bigint := 0;
  n bigint;
  detail text := '';
begin
  foreach t in array array[
    'events', 'event_logs', 'event_feedback', 'todo_lists', 'event_types',
    'skill_insights', 'user_settings', 'agent_preferences', 'agent_conversations'
  ] loop
    if not exists (select 1 from pg_attribute where attrelid = to_regclass('public.' || t)
                   and attname = 'version_id' and not attisdropped) then
      detail := detail || t || ': no version_id column; ';
      total_missing := total_missing + 1;
      continue;
    end if;
    execute format('select count(*), count(*) filter (where not exists (select 1 from public.sync_versions v where v.version_id = r.version_id)),
                           count(*) filter (where r.restored_from_version_id is not null) from public.%I r', t)
      into n, missing, carried;
    rows_total := rows_total + n;
    total_missing := total_missing + missing;
    total_carried := total_carried + carried;
    if missing > 0 or carried > 0 then
      detail := detail || format('%s: %s of %s rows not in the log, %s carrying restored_from; ', t, missing, n, carried);
    end if;
  end loop;
  insert into post_apply (id, claim, pass, observed)
  values ('P12',
          'every synced row''s version_id (tombstones included) is in sync_versions, and no row carries restored_from_version_id',
          total_missing = 0 and total_carried = 0,
          format('%s rows over nine tables, %s not in the log, %s carrying restored_from; log rows=%s%s',
                 rows_total, total_missing, total_carried, (select count(*) from public.sync_versions),
                 case when detail <> '' then '; ' || detail else '' end));
end;
$$;
\else
insert into post_apply (id, claim, pass, observed)
values ('P12', 'every synced row''s version_id is in sync_versions', false, 'table public.sync_versions absent');
\endif

\pset format aligned
\pset footer off
select case when pass then 'PASS' else 'FAIL' end as verdict, id, claim, observed from post_apply order by ord;
-- \if needs a boolean: a bare count of two or more is an error that psql
-- reports and then treats as false, which would print the pass line
select count(*) filter (where not pass) as post_apply_fails, count(*) filter (where not pass) > 0 as post_apply_any_fail from post_apply \gset
\if :post_apply_any_fail
  \echo 'post-apply checks FAILED:' :post_apply_fails
  do $$ begin raise exception 'post_apply_checks: some checks failed'; end $$;
\else
  \echo 'all post-apply checks passed'
\endif
