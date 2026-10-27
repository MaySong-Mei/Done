-- Telemetry chassis (gh#273, design §16 rules 3 and 4): one read-only "mine"
-- view, so the app's observatory page can read back — as the signed-in user,
-- over PostgREST — the spike_runs rows its own account uploaded from every
-- device. Design: Docs/telemetry/00-telemetry-chassis-design.md §16 (the
-- observatory reads the cloud, per account) on top of §9 (migration 016).
--
-- STATUS: NOT APPLIED to staging or production. Verified on the local stack
-- only, by done-mcp/supabase/tests/run_checks.sh (db reset applies 001–017,
-- then telemetry_checks.sql T29–T33). Merging a change under migrations/ to
-- `staging` / `main` applies it through supabase-staging.yml / supabase.yml
-- (merge order = deploy order).
--
-- WHAT IT ADDS. public.v_my_spike_runs: every spike_runs column except
--   * note — the only free-text column; the observatory has no use for it;
--   * first_uploaded_at / last_uploaded_at — server-only stamps (wire §2 end).
-- install_id / device_model / os_version stay: they are the caller's own
-- devices, and the card's "云端 · N 台设备" is count(distinct install_id).
-- Rows are not filtered by build_configuration here; the client asks for
-- `build_configuration=eq.release` itself (a Debug build may want its own).
--
-- WHO CAN READ IT, and why two fences.
--   * security_invoker = true: the select on spike_runs runs as the caller,
--     so 016's RLS policy "read own spike runs" (user_id = auth.uid()) applies.
--     A definer view (the default) would read as its owner, postgres, which
--     bypasses RLS — every user would see every row.
--   * where user_id = (select auth.uid()): the second fence. If RLS on
--     spike_runs were ever disabled or a broader select policy added, the
--     view still returns only the caller's rows (a caller without a `sub`
--     claim has auth.uid() null and would match nothing even if granted).
--     Either fence alone keeps another user's rows out; the checks pin both
--     structurally (security_invoker in reloptions, auth.uid() in the text)
--     because removing one of them leaves the row-level results unchanged.
--   * grants: select to authenticated only. anon, service_role and public get
--     nothing (Supabase's default privileges grant all on a new object in
--     `public`, hence the explicit revoke after the create; a leaked service
--     key, gh#232, must not read this either).
-- The eight shared views of 016 (counter_long, v_active_installs, …) stay
-- revoked from every client role: cross-user aggregation is developer-side SQL
-- only (§16 rule 4; telemetry_checks T32).
--
-- CLIENT READ CONTRACT (PostgREST):
--   GET /rest/v1/v_my_spike_runs?select=*&build_configuration=eq.release
--       &spike_id=in.(resident-daily,fix-effort-path)
--   headers: apikey: <publishable/anon key>, Authorization: Bearer <user JWT>
--   → 200, a JSON array; column names as in spike_runs (snake_case), minus
--     the three above. No JWT (anon) → 401 / 42501.
--   PostgREST caps a response at max_rows (config.toml [api] locally, the
--   dashboard's API setting on a hosted project); an account accumulates
--   rows per device per day without bound, so a reader that pages must
--   order by a unique key (e.g. order=day_key.desc,run_id.asc) or narrow by
--   day_key — an unordered page can skip or repeat rows.
--
-- IDEMPOTENT: drop + create (so a later column change reruns clean, the same
-- form as 016's views), then the revoke and the grant; rerunning leaves the
-- same column list and the same grants (telemetry_checks T33). Nothing
-- depends on this view, so the drop never cascades.

drop view if exists public.v_my_spike_runs;

create view public.v_my_spike_runs with (security_invoker = true) as
select r.user_id,
       r.run_id,
       r.install_id,
       r.kind,
       r.spike_id,
       r.scenario_id,
       r.day_key,
       r.day_tz_offset_min,
       r.app_build,
       r.app_version,
       r.build_configuration,
       r.device_model,
       r.os_version,
       r.revision,
       r.started_at,
       r.ended_at,
       r.outcome,
       r.metrics,
       r.context,
       r.client_updated_at
from public.spike_runs r
where r.user_id = (select auth.uid());

comment on view public.v_my_spike_runs is
  'The caller''s own spike_runs rows (all devices of the account), without note and the server upload stamps. Read by the app''s observatory page (gh#273, design §16). security_invoker + RLS + where user_id = auth.uid().';

revoke all on table public.v_my_spike_runs from public, anon, authenticated, service_role;
grant select on table public.v_my_spike_runs to authenticated;

-- PostgREST serves the new relation without waiting for a restart
notify pgrst, 'reload schema';
