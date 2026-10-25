-- Telemetry chassis (gh#273, slice 1): one table for uploaded spike runs, a
-- revision guard, the key registry that tells 0 from NULL, and the named
-- consumer views. Design: Docs/telemetry/00-telemetry-chassis-design.md §9;
-- column names, types, trigger semantics and the registry JSON shape follow
-- Docs/telemetry/01-wire-contract.md (version 1) — both sides implement
-- against that file, not this one.
--
-- STATUS: NOT APPLIED to production or staging (verified on the local stack
-- by done-mcp/supabase/tests/run_checks.sh: supabase db reset, then
-- sync_feed_checks.sql and telemetry_checks.sql).
--
-- ISOLATION FROM 015 (the sync change feed). This table is NOT a synced
-- table and must never become one:
--   * it is not added to 015's `tables` array, so no trg_*_sync_gate /
--     trg_*_sync_meta / trg_*_sync_version / trg_*_notify_* / trg_*_tombstone
--     / trg_*_no_truncate trigger is attached (telemetry_checks T10);
--   * it is not a UNION arm of public.sync_changes (clients never pull it);
--   * it is not in the snapshot edge function's table list (004);
--   * it takes no seq, no deleted_at, no version columns; a DELETE here is a
--     plain delete (only the auth.users cascade performs one, 9.1);
--   * a client upload carries no X-Sync-Epoch header and is not refused when
--     sync is paused (design B·F14): a paused sync must not silence telemetry.
--
-- IDEMPOTENT by construction (every statement guards or is create-or-replace;
-- the views are dropped and recreated so a later column change reruns clean),
-- matching the deploy-reruns-all-migrations practice (gh#244). A rerun keeps
-- every spike_runs row and every key_registry row (telemetry_checks T1).
--
-- DATA IN key_registry does not live here. The rows are generated from
-- done-mcp/supabase/telemetry/key_registry.json (exported by the Swift tests)
-- by gen_key_registry_sql.py into key_registry_load.sql, an idempotent upsert
-- that is applied AFTER this migration (run_checks.sh does so locally; the
-- deploy needs the same step — wire contract §4: "服务端注册表不手抄").
--
-- WHO READS. The views are for the operator (dashboard SQL editor, the weekly
-- telemetry_checks.sql run that reports to #273) and the agent's direct SQL,
-- both of which run as the `postgres` role. Nothing client-side reads this
-- table back: authenticated gets select / insert / update on ITS OWN rows only
-- (the upsert needs select for ON CONFLICT and update for merge-duplicates),
-- no delete; anon gets nothing; service_role gets nothing either — an edge
-- function or MCP caller has no business here, and a leaked service key
-- (gh#232) must not read every user's telemetry or the `note` column.
-- Supabase's default privileges in `public` grant everything to anon /
-- authenticated / service_role on new objects, hence the explicit `revoke all`
-- after each create.
--
-- VIEWS are `security_invoker = true`: a view owned by postgres would
-- otherwise read through RLS for anyone granted it. With invoker semantics a
-- future grant to authenticated would still show a user only their own rows;
-- today no role but the owner is granted. No view exposes `note` (the only
-- free-text column) and no shared view exposes install_id / device_model /
-- os_version; v_fixwatch_verdicts_by_install is the one internal exception
-- (design §8.1, telemetry_checks T16).

-- ============================================================
-- 1. public.spike_runs — one row per uploaded SpikeRun record (wire §2)
-- ============================================================
create table if not exists public.spike_runs (
  user_id             uuid        not null references auth.users(id) on delete cascade,
  run_id              uuid        not null,
  install_id          uuid        not null,
  kind                text        not null
    constraint spike_runs_kind_check check (kind in (
      'daily_rollup', 'window', 'manual_run', 'verdict_snapshot', 'metrickit_daily',
      'user_report'  -- reserved by wire §2; no view reads it yet
    )),
  spike_id            text        not null,
  scenario_id         text        not null,
  day_key             date        not null,
  day_tz_offset_min   smallint    not null,
  app_build           integer     not null,
  app_version         text        not null,
  build_configuration text        not null
    constraint spike_runs_build_configuration_check check (build_configuration in ('debug', 'release')),
  device_model        text        not null,
  os_version          text        not null,
  revision            integer     not null
    constraint spike_runs_revision_check check (revision >= 1),
  started_at          timestamptz not null,
  ended_at            timestamptz,
  outcome             text,
  metrics             jsonb       not null,
  context             jsonb       not null,
  note                text,
  client_updated_at   timestamptz not null,
  -- server-only (wire §2 end): the client never sends these
  first_uploaded_at   timestamptz not null default now(),
  last_uploaded_at    timestamptz,
  -- composite key: the same run_id under two accounts is two rows, and
  -- PostgREST's on_conflict must name both columns (wire §3, checks T5/T15)
  primary key (user_id, run_id)
);

create index if not exists idx_spike_runs_user_kind_day on public.spike_runs (user_id, kind, day_key);
create index if not exists idx_spike_runs_build_kind    on public.spike_runs (app_build, kind);
-- no GIN on metrics / context (design §9.1): the views scan by key through
-- the registry, and the table is ~10 devices × ~20 rows/day.

-- ============================================================
-- 2. Revision guard + upload stamp (wire §3, design §9.2)
--    BEFORE INSERT: last_uploaded_at = now().
--    BEFORE UPDATE: new.revision <= old.revision → return null, i.e. the
--    merge-duplicates upsert is skipped; the client still sees 2xx and may
--    advance its cursor (its higher revision is already here). Otherwise
--    stamp last_uploaded_at and keep first_uploaded_at (a client cannot move
--    it even if it sends the column).
-- ============================================================
create or replace function public.spike_runs_upload_stamp()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' then
    if new.revision <= old.revision then
      return null;
    end if;
    new.first_uploaded_at := old.first_uploaded_at;
  end if;
  new.last_uploaded_at := now();
  return new;
end;
$$;
revoke all on function public.spike_runs_upload_stamp() from public, anon, authenticated, service_role;

-- The name deliberately matches no 015 pattern (trg_%_sync_%, trg_%_notify_%,
-- trg_%_tombstone, trg_%_no_truncate): post-apply check P1 and telemetry T10
-- read trigger names.
drop trigger if exists trg_spike_runs_upload_stamp on public.spike_runs;
create trigger trg_spike_runs_upload_stamp
  before insert or update on public.spike_runs
  for each row execute function public.spike_runs_upload_stamp();

-- ============================================================
-- 3. RLS (wire §3): authenticated reads / inserts / updates its own rows,
--    nothing else; no delete policy and no delete grant, so a client DELETE
--    is refused with 42501 (permission denied), not silently 0 rows (T8).
-- ============================================================
alter table public.spike_runs enable row level security;
revoke all on table public.spike_runs from public, anon, authenticated, service_role;
grant select, insert, update on table public.spike_runs to authenticated;

do $$
begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'spike_runs'
                 and policyname = 'read own spike runs') then
    create policy "read own spike runs" on public.spike_runs
      for select to authenticated
      using ( user_id = (select auth.uid()) );
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'spike_runs'
                 and policyname = 'upload own spike runs') then
    create policy "upload own spike runs" on public.spike_runs
      for insert to authenticated
      with check ( user_id = (select auth.uid()) );
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'spike_runs'
                 and policyname = 'reupload own spike runs') then
    create policy "reupload own spike runs" on public.spike_runs
      for update to authenticated
      using ( user_id = (select auth.uid()) )
      with check ( user_id = (select auth.uid()) );
  end if;
end;
$$;

-- ============================================================
-- 4. public.key_registry (wire §4). Structure only; rows come from
--    telemetry/key_registry_load.sql (generated, idempotent upsert).
--    `liveness_key` is a self-reference: a tripwire counter names the counter
--    that proves the wire is live (the loader is one statement, so a forward
--    reference inside it resolves at statement end).
--    No client reads the registry (the app has it at compile time), so no
--    role but the owner is granted; RLS is on with no policy so a stray
--    future grant still yields nothing.
-- ============================================================
create table if not exists public.key_registry (
  key           text    primary key,
  kind          text    not null
    constraint key_registry_kind_check check (kind in ('counter', 'histogram', 'gauge')),
  family        text    not null
    constraint key_registry_family_check check (family in ('fixwatch', 'usage', 'incident', 'metrickit', 'self')),
  value_schema  text    not null
    constraint key_registry_value_schema_check check (value_schema in ('number', 'fixed_string', 'bool')),
  since_build   integer not null,
  retired_build integer,
  liveness_key  text    references public.key_registry(key),
  spike_id      text    not null,
  description   text    not null default '',
  constraint key_registry_retired_after_since check (retired_build is null or retired_build > since_build)
);

alter table public.key_registry enable row level security;
revoke all on table public.key_registry from public, anon, authenticated, service_role;

-- ============================================================
-- 5. Metric reader. `metrics ->> key` cast to numeric raises on a string
--    value; the views must not go dark for every key because one row carries
--    a malformed value, so a non-number reads as NULL here (and as 0, i.e.
--    "absent", in counter_long). The Redactor on the client is the real type
--    guard; this is the server's seatbelt.
-- ============================================================
create or replace function public.spike_metric_num(metrics jsonb, key text)
returns numeric
language sql
immutable
parallel safe
security invoker
set search_path = ''
as $$
  select case when jsonb_typeof(metrics -> key) = 'number' then (metrics ->> key)::numeric end
$$;
revoke all on function public.spike_metric_num(jsonb, text) from public, anon, authenticated, service_role;

-- ============================================================
-- 6. Views (design §9.4 / §9.5). Every view carries
--    `build_configuration = 'release'` in its own text (T13), even where it
--    reads counter_long, which already filters: the predicate is the contract,
--    not an optimisation. Dropped in dependency order and recreated so a
--    later change of a column list reruns clean.
-- ============================================================
drop view if exists public.v_possible_dead_wire;
drop view if exists public.v_fixwatch_pooled_buckets;
drop view if exists public.v_fixwatch_verdicts_by_install;
drop view if exists public.v_metrickit_by_build;
drop view if exists public.v_sync_failure_by_build;
drop view if exists public.v_feature_unused_30d;
drop view if exists public.v_active_installs;
drop view if exists public.counter_long;

-- counter_long: one row per (release row, registered COUNTER key of the same
-- spike_id). value = coalesce(metric, 0) when app_build is inside
-- [since_build, retired_build) (retired_build null = no upper bound), else
-- NULL: "the build could not have sent this key" is NULL, "the build should
-- have sent it and did not / sent 0" is 0 (wire §4). Only kind = 'counter'
-- with value_schema = 'number' is cast: histograms are strings, bools are
-- not counts, and a gauge coerced to 0 when absent would read as a
-- measurement — gauges are read by their own views. The key→row pairing is
-- the registry's spike_id (the record kind that carries a key is implied by
-- the spike that writes it). Building block: not a share surface, but it
-- still exposes no install_id / device_model / os_version / note.
create view public.counter_long with (security_invoker = true) as
select r.user_id,
       r.run_id,
       r.kind,
       r.spike_id,
       r.scenario_id,
       r.day_key,
       r.app_build,
       r.build_configuration,
       k.key,
       k.family,
       case when r.app_build >= k.since_build
             and (k.retired_build is null or r.app_build < k.retired_build)
            then coalesce(public.spike_metric_num(r.metrics, k.key), 0)
       end as value
from public.spike_runs r
join public.key_registry k
  on k.spike_id = r.spike_id
 and k.kind = 'counter'
 and k.value_schema = 'number'
where r.build_configuration = 'release';

-- v_active_installs (question 5): an install is active on a day when it
-- uploaded that day's daily_rollup; a device that upgraded mid-day is active
-- under both builds (claim key, design §4.2).
create view public.v_active_installs with (security_invoker = true) as
select r.day_key,
       r.app_build,
       count(distinct r.install_id) as active_installs
from public.spike_runs r
where r.build_configuration = 'release'
  and r.kind = 'daily_rollup'
group by r.day_key, r.app_build;

-- v_feature_unused_30d (question 2): usage counters that were expected
-- (build in range; when the key names a liveness_key — `sessions` for usage
-- keys — only rows where that denominator is > 0 count, design §9.4 "sessions
-- 作分母") on at least one row in the last 30 days and were > 0 on no install.
create view public.v_feature_unused_30d with (security_invoker = true) as
select c.key,
       k.since_build,
       count(*)                                                   as expected_rows,
       count(distinct r.install_id)                               as installs_expected,
       count(distinct r.install_id) filter (where c.value > 0)    as installs_used,
       min(c.day_key)                                             as first_day,
       max(c.day_key)                                             as last_day
from public.counter_long c
join public.key_registry k on k.key = c.key
join public.spike_runs r on r.user_id = c.user_id and r.run_id = c.run_id
where c.build_configuration = 'release'
  and r.build_configuration = 'release'
  and k.family = 'usage'
  and c.value is not null
  and c.day_key >= current_date - 30
  and (k.liveness_key is null or coalesce(public.spike_metric_num(r.metrics, k.liveness_key), 0) > 0)
group by c.key, k.since_build
having count(distinct r.install_id) filter (where c.value > 0) = 0;

-- v_sync_failure_by_build (question 3). KEY NAMING CONVENTION the Swift side
-- follows when it registers incident keys: every counter under the prefix
-- `sync.write.` is a write outcome; `sync.write.ok` is the success counter
-- and every other `sync.write.<kind>` (one per SyncWriteFailureKind case,
-- design §6.4) is a failure. Only registered keys (family = 'incident') are
-- summed, so an unregistered spelling is invisible here rather than
-- miscounted.
create view public.v_sync_failure_by_build with (security_invoker = true) as
select c.app_build,
       coalesce(sum(c.value) filter (where c.key = 'sync.write.ok'), 0)  as ok,
       coalesce(sum(c.value) filter (where c.key <> 'sync.write.ok'), 0) as fail,
       round(coalesce(sum(c.value) filter (where c.key <> 'sync.write.ok'), 0)
             / nullif(coalesce(sum(c.value), 0), 0), 4)                  as fail_rate,
       count(distinct c.run_id)                                          as rows_counted
from public.counter_long c
join public.key_registry k on k.key = c.key
where c.build_configuration = 'release'
  and k.family = 'incident'
  and c.key like 'sync.write.%'
  and c.value is not null
group by c.app_build;

-- v_metrickit_by_build (question 4): the MetricKit daily summary per build.
-- Keys per design §6.5 (gauges hitchRatio / peakMemMB, counters hang / crash /
-- cpuException / diskWriteException); a non-numeric value is ignored by the
-- percentiles and reads as 0 in the sums.
create view public.v_metrickit_by_build with (security_invoker = true) as
select r.app_build,
       count(*)                                                                                       as day_rows,
       count(distinct r.install_id)                                                                   as installs,
       percentile_cont(0.5) within group (order by public.spike_metric_num(r.metrics, 'hitchRatio')::float8) as hitch_ratio_p50,
       percentile_cont(0.9) within group (order by public.spike_metric_num(r.metrics, 'hitchRatio')::float8) as hitch_ratio_p90,
       percentile_cont(0.9) within group (order by public.spike_metric_num(r.metrics, 'peakMemMB')::float8)  as peak_mem_mb_p90,
       coalesce(sum(public.spike_metric_num(r.metrics, 'hang')), 0)                                    as hangs,
       coalesce(sum(public.spike_metric_num(r.metrics, 'crash')), 0)                                   as crashes,
       coalesce(sum(public.spike_metric_num(r.metrics, 'cpuException')), 0)                            as cpu_exceptions,
       coalesce(sum(public.spike_metric_num(r.metrics, 'diskWriteException')), 0)                      as disk_write_exceptions
from public.spike_runs r
where r.build_configuration = 'release'
  and r.kind = 'metrickit_daily'
group by r.app_build;

-- v_fixwatch_verdicts_by_install (question 1, the authority): the latest
-- verdict_snapshot per install, metrics expanded one key per row, exactly as
-- the device computed them. INTERNAL — the one view that exposes install_id,
-- device_model and os_version (an operator compares it against the device's
-- card); never share it or feed it to an agent prompt (design §8.1). `note`
-- is not exposed.
create view public.v_fixwatch_verdicts_by_install with (security_invoker = true) as
select s.install_id,
       s.app_build,
       s.app_version,
       s.os_version,
       s.device_model,
       s.day_key,
       s.client_updated_at,
       m.key,
       m.value
from (
  select distinct on (r.install_id)
         r.install_id, r.app_build, r.app_version, r.os_version, r.device_model,
         r.day_key, r.client_updated_at, r.metrics
  from public.spike_runs r
  where r.build_configuration = 'release'
    and r.kind = 'verdict_snapshot'
  order by r.install_id, r.day_key desc, r.client_updated_at desc, r.revision desc
) s
cross join lateral jsonb_each(s.metrics) as m(key, value);

-- v_fixwatch_pooled_buckets (question 1, the sample-size read): registered
-- histogram keys (kind = 'histogram', value_schema = 'fixed_string', the
-- space-separated bucket counts the observatory writes, e.g. tapLagBuckets:
-- 8 buckets ≤10 ≤20 ≤40 ≤80 ≤120 ≤320 >320 missing) summed bucket-wise over
-- every release row of the key's spike, by app_build × key × bucket_idx
-- (0-based, matching ResidentLagHistogram.counts). A value that is not a
-- string of non-negative integers contributes nothing (the guard sits inside
-- the lateral expression, so no cast can raise). The rows are chosen by the
-- registry's spike_id, not by a hard-coded kind: today the histograms ride
-- the daily_rollup of resident-daily (ResidentCounterSet), not the windows.
create view public.v_fixwatch_pooled_buckets with (security_invoker = true) as
select r.app_build,
       k.key,
       (b.idx - 1)::int  as bucket_idx,
       sum(b.val)::bigint as pooled_count,
       count(*)           as rows_pooled
from public.spike_runs r
join public.key_registry k
  on k.spike_id = r.spike_id
 and k.kind = 'histogram'
 and k.value_schema = 'fixed_string'
 and r.app_build >= k.since_build
 and (k.retired_build is null or r.app_build < k.retired_build)
cross join lateral unnest(
  case when jsonb_typeof(r.metrics -> k.key) = 'string'
        and (r.metrics ->> k.key) ~ '^[0-9]+( [0-9]+)*$'
       then string_to_array(r.metrics ->> k.key, ' ')::int[]
  end) with ordinality as b(val, idx)
where r.build_configuration = 'release'
group by r.app_build, k.key, b.idx;

-- v_possible_dead_wire (diagnostic, design §9.4): counters that in the last
-- 30 days were expected (build in range, the install uploaded that day's
-- daily_rollup, and — when the key names a liveness_key — the liveness
-- counter was > 0 on that row) yet were 0 on every row of every install.
-- "Expected and all-zero everywhere" is the shape of a dead wire; a human
-- decides.
create view public.v_possible_dead_wire with (security_invoker = true) as
select c.key,
       c.family,
       c.spike_id,
       k.since_build,
       k.liveness_key,
       count(*)                     as expected_rows,
       count(distinct r.install_id) as installs_expected,
       min(c.day_key)               as first_day,
       max(c.day_key)               as last_day
from public.counter_long c
join public.key_registry k on k.key = c.key
join public.spike_runs r on r.user_id = c.user_id and r.run_id = c.run_id
where c.build_configuration = 'release'
  and r.build_configuration = 'release'
  and c.value is not null
  and c.day_key >= current_date - 30
  and exists (select 1 from public.spike_runs d
              where d.install_id = r.install_id
                and d.day_key = r.day_key
                and d.kind = 'daily_rollup'
                and d.build_configuration = 'release')
  and (k.liveness_key is null or coalesce(public.spike_metric_num(r.metrics, k.liveness_key), 0) > 0)
group by c.key, c.family, c.spike_id, k.since_build, k.liveness_key
having bool_and(c.value = 0);

revoke all on table
  public.counter_long,
  public.v_active_installs,
  public.v_feature_unused_30d,
  public.v_sync_failure_by_build,
  public.v_metrickit_by_build,
  public.v_fixwatch_verdicts_by_install,
  public.v_fixwatch_pooled_buckets,
  public.v_possible_dead_wire
from public, anon, authenticated, service_role;
