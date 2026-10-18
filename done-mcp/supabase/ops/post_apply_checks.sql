-- Post-apply checks for migration 015 (sync change feed). Read-only.
-- Run after every apply of 015, every redeploy that reruns the migrations,
-- every restore, and every manual data fix:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f post_apply_checks.sql
-- Prints PASS/FAIL per check and raises at the end when any check failed,
-- so psql exits non-zero (exit status 3 under ON_ERROR_STOP).
-- The table list is the one in section 5 of the migration; keep them equal.

\set QUIET on
\pset pager off
\set ON_ERROR_STOP on

create temp table if not exists post_apply (ord serial, id text, claim text, pass boolean, observed text);
truncate post_apply;

with tables(t) as (
  select unnest(array[
    'events', 'event_logs', 'event_feedback', 'todo_lists', 'event_types',
    'skill_insights', 'user_settings', 'agent_preferences', 'agent_conversations'])
), wanted(t, tgname, fn, timing) as (
  select t, 'trg_' || t || '_sync_meta',   'set_sync_meta',            'row before insert/update' from tables
  union all
  select t, 'trg_' || t || '_notify_ins',  'notify_sync_change',       'statement after insert' from tables
  union all
  select t, 'trg_' || t || '_notify_upd',  'notify_sync_change',       'statement after update' from tables
  union all
  select t, 'trg_' || t || '_tombstone',   'sync_delete_to_tombstone', 'row before delete' from tables
  union all
  select t, 'trg_' || t || '_no_truncate', 'sync_refuse_truncate',     'statement before truncate' from tables
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
               when 'statement after insert'    then tgtype & (1|2) = 0 and tgtype & (4|8|16|32) = 4
               when 'statement after update'    then tgtype & (1|2) = 0 and tgtype & (4|8|16|32) = 16
               when 'row before delete'         then tgtype & (1|2) = (1|2) and tgtype & (4|8|16|32) = 8
               when 'statement before truncate' then tgtype & (1|2) = 2 and tgtype & (4|8|16|32) = 32
             end, false) as ok
  from found
)
insert into post_apply (id, claim, pass, observed)
select 'P1',
       'every synced table has its sync_meta, notify_ins, notify_upd, tombstone and no_truncate triggers, ENABLED (tgenabled = O), on the right function and timing',
       bool_and(ok),
       case when bool_and(ok)
            then format('%s triggers checked, all enabled', count(*))
            else 'missing, disabled or wrong: ' || string_agg(
                   format('%s(tgenabled=%s fn=%s)', tgname, coalesce(tgenabled::text, 'absent'), coalesce(proname, '-')),
                   ', ' order by tgname) filter (where not ok)
       end
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

select to_regclass('public.sync_epoch') is not null as has_sync_epoch \gset
\if :has_sync_epoch
insert into post_apply (id, claim, pass, observed)
select 'P5',
       'sync_epoch has exactly one row, with a non-empty epoch and a floor no higher than the sequence',
       to_regclass('public.sync_epoch') is not null
       and (select count(*) from public.sync_epoch) = 1
       and (select bool_and(epoch <> '' and floor >= 0 and floor <= (select last_value from public.sync_seq)) from public.sync_epoch),
       (select format('rows=%s epoch=%s floor=%s changed_at=%s sync_seq.last_value=%s', count(*), max(epoch), max(floor), max(changed_at),
                      (select last_value from public.sync_seq)) from public.sync_epoch);

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
  ('P5', 'sync_epoch has exactly one row', false, 'table public.sync_epoch absent'),
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
