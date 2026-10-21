#!/usr/bin/env bash
# The whole 015 bench in order: SQL side (S1–S6, S10, S14–S16, S20–S24),
# HTTP side (S2–S5, S7–S13, S10b, S19, S25), the restore drill (S17) and
# rollback rehearsal (S18), then the post-apply checks (P1–P12) and their
# negative controls, then the v6 negative controls (one mutation per new
# check, sync_v6_controls.sh; RUN_V6_CONTROLS=0 skips them).
# Local stack only; see README.md.
# Exits non-zero when any part failed.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
DB=${SUPABASE_DB:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}
PSQL=${PSQL:-$(command -v psql || echo /opt/homebrew/opt/libpq/bin/psql)}
export PSQL SUPABASE_DB="$DB"
case $DB in *127.0.0.1*|*localhost*) ;; *) echo "refusing: SUPABASE_DB is not a local address" >&2; exit 2;; esac

status=()
part() { # name, command...
  local name=$1; shift
  echo; echo "################ $name"
  "$@"; local rc=$?
  status+=("$name exit=$rc")
  return 0
}

part "sql bench" "$PSQL" "$DB" -v ON_ERROR_STOP=1 -f "$HERE/sync_feed_checks.sql"
part "http bench" "$HERE/sync_feed_checks.sh"
part "restore drill + rollback rehearsal" "$HERE/sync_restore_drill.sh"
part "post-apply checks" "$PSQL" "$DB" -v ON_ERROR_STOP=1 -f "$HERE/../ops/post_apply_checks.sql"

# Negative controls: each mutation, inside a transaction that the failing
# check's raise rolls back, must turn exactly the named check to FAIL and
# make psql exit non-zero. Without these a passing check proves nothing.
controls() {
  local fails=0 m want got rc out seq0 seq1
  # setval is not transactional; a control may only touch sync_seq in ways
  # its rollback undoes
  seq0=$("$PSQL" "$DB" -At -c "select last_value || ' ' || is_called from public.sync_seq")
  while IFS='|' read -r want m; do
    out=$("$PSQL" "$DB" -v ON_ERROR_STOP=1 -c "begin" -c "$m" -f "$HERE/../ops/post_apply_checks.sql" 2>&1); rc=$?
    got=$(echo "$out" | grep -E '^ FAIL' | awk -F'|' '{gsub(/ /,"",$2); print $2}' | paste -sd, -)
    if [[ $rc != 0 && $got == "$want" ]]; then echo "PASS ctrl $want <- $m"; else echo "FAIL ctrl $want <- $m (exit=$rc failed=$got)"; fails=$((fails + 1)); fi
  done <<'LIST'
P1|alter table public.events disable trigger trg_events_tombstone
P1|alter table public.agent_conversations disable trigger trg_agent_conversations_no_truncate
P1|alter table public.event_logs disable trigger trg_event_logs_sync_meta
P1|alter table public.todo_lists enable replica trigger trg_todo_lists_notify_upd
P1|drop trigger trg_skill_insights_notify_ins on public.skill_insights
P1|drop trigger trg_events_sync_gate on public.events
P1|alter table public.event_feedback disable trigger trg_event_feedback_sync_version
P1|create trigger trg_events_sync_stamp before update on public.events for each row execute function public.set_sync_meta()
P1|alter trigger trg_events_sync_gate on public.events rename to trg_events_zz_gate
P2|create policy bench_extra on realtime.messages for select to authenticated using (true)
P3|alter function public.notify_sync_change() security invoker
P4|grant execute on function public.sync_changes(bigint, int) to anon
P4|grant execute on function public.sync_changes(bigint, int) to public
P5,P10|delete from public.sync_epoch
P5|alter table public.sync_epoch add column floor bigint
P5|alter table public.sync_epoch add column lost int8multirange
P5,P10|alter table public.sync_epoch drop column rollback
P5|alter table public.events drop column domino_anchor
P5,P11,P12|drop table public.sync_versions
P6|grant update on public.sync_epoch to authenticated
P6|grant insert on public.sync_epoch to service_role
P6|alter table public.sync_epoch disable row level security
P5,P6,P10|drop table public.sync_epoch
P7|do $$ begin execute replace(pg_get_functiondef('public.sync_changes(bigint, integer)'::regprocedure), 'least(page_limit, 1000)', 'least(page_limit, 2000)'); end $$
P8|alter table public.events alter column seq set default nextval('public.sync_seq')
P8|alter table public.skill_insights alter column seq drop not null
P9,P12|set local session_replication_role = replica; insert into public.agent_conversations (user_id, seq) select gen_random_uuid(), last_value + 1 from public.sync_seq
P9,P12|do $$ declare v bigint; begin set local session_replication_role = replica; select case when is_called then last_value + 1 else last_value end into v from public.sync_seq; insert into public.event_types (id, user_id, title, color_hex, seq) values (gen_random_uuid(), gen_random_uuid(), 'P9 control', '#336699', v); execute format('alter sequence public.sync_seq restart with %s', v); end $$
P10|update public.sync_epoch set restores = '[]'
P10|update public.sync_epoch set restores = restores || '{"epoch":"not-the-current-epoch","kept_max":0,"dump_epoch":null}'::jsonb
P10|update public.sync_epoch set epoch = gen_random_uuid()::text
P11|grant execute on function public.is_ancestor(text, text, uuid, uuid) to anon
P11|grant execute on function public.sync_versions_prune(int) to authenticated
P11|alter function public.sync_versions_prune(int) security invoker
P11|alter table public.sync_versions disable row level security
P11|grant delete on public.sync_versions to authenticated
P12|set local session_replication_role = replica; insert into public.event_types (id, user_id, title, color_hex, seq, version_id) values (gen_random_uuid(), gen_random_uuid(), 'P12 control', '#336699', 1, gen_random_uuid())
P12|set local session_replication_role = replica; insert into public.event_types (id, user_id, title, color_hex, seq, restored_from_version_id) values (gen_random_uuid(), gen_random_uuid(), 'P12 control', '#336699', 1, gen_random_uuid()); insert into public.sync_versions (user_id, tbl, id, version_id, seq) select user_id, 'event_types', id::text, version_id, seq from public.event_types where title = 'P12 control'
LIST
  # the SQL bench's own verdict tail must also exit non-zero on several failures
  local probe; probe=$(mktemp)
  { printf '%s\n' '\set QUIET on' '\set ON_ERROR_STOP on' \
      'create temp table bench (ord serial, id text, claim text, pass boolean, observed text);' \
      "insert into bench (id, claim, pass, observed) values ('X', 'forced', false, ''), ('Y', 'forced', false, '');"
    sed -n '/^\\o$/,$p' "$HERE/sync_feed_checks.sql"; } > "$probe"
  "$PSQL" "$DB" -v ON_ERROR_STOP=1 -f "$probe" >/dev/null 2>&1; rc=$?; rm -f "$probe"
  if [[ $rc != 0 ]]; then echo "PASS ctrl sync_feed_checks.sql verdict tail exits $rc with two forced failures"; else echo "FAIL ctrl sync_feed_checks.sql verdict tail exits 0 with two forced failures"; fails=$((fails + 1)); fi
  # the mutations must not have survived
  "$PSQL" "$DB" -v ON_ERROR_STOP=1 -q -f "$HERE/../ops/post_apply_checks.sql" >/dev/null 2>&1 || { echo "FAIL ctrl: a mutation survived its rollback"; fails=$((fails + 1)); }
  seq1=$("$PSQL" "$DB" -At -c "select last_value || ' ' || is_called from public.sync_seq")
  [[ -n $seq0 && $seq1 == "$seq0" ]] || { echo "FAIL ctrl: sync_seq moved across the controls ($seq0 -> $seq1)"; fails=$((fails + 1)); }
  [[ $fails == 0 ]] && echo "all post-apply controls behaved"
  return $fails
}
part "post-apply controls" controls

if [[ ${RUN_V6_CONTROLS:-1} == 1 ]]; then
  part "v6 negative controls" "$HERE/sync_v6_controls.sh"
fi

echo; echo "################ summary"
bad=0
for s in "${status[@]}"; do echo "$s"; [[ $s == *"exit=0" ]] || bad=1; done
exit $bad
