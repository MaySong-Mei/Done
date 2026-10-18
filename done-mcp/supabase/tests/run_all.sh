#!/usr/bin/env bash
# The whole 015 bench in order: SQL side (S1–S6, S10, S14–S16), HTTP side
# (S2–S5, S7–S13, S10b), the restore drill (S17), then the post-apply checks
# (P1–P7) and their negative controls. Local stack only; see README.md.
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
part "restore drill" "$HERE/sync_restore_drill.sh"
part "post-apply checks" "$PSQL" "$DB" -v ON_ERROR_STOP=1 -f "$HERE/../ops/post_apply_checks.sql"

# Negative controls: each mutation, inside a transaction that the failing
# check's raise rolls back, must turn exactly the named check to FAIL and
# make psql exit non-zero. Without these a passing check proves nothing.
controls() {
  local fails=0 m want got rc out
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
P2|create policy bench_extra on realtime.messages for select to authenticated using (true)
P3|alter function public.notify_sync_change() security invoker
P4|grant execute on function public.sync_changes(bigint, int) to anon
P4|grant execute on function public.sync_changes(bigint, int) to public
P5|delete from public.sync_epoch
P6|grant update on public.sync_epoch to authenticated
P6|grant insert on public.sync_epoch to service_role
P6|alter table public.sync_epoch disable row level security
P5,P6|drop table public.sync_epoch
P7|do $$ begin execute replace(pg_get_functiondef('public.sync_changes(bigint, integer)'::regprocedure), 'least(page_limit, 1000)', 'least(page_limit, 2000)'); end $$
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
  [[ $fails == 0 ]] && echo "all post-apply controls behaved"
  return $fails
}
part "post-apply controls" controls

echo; echo "################ summary"
bad=0
for s in "${status[@]}"; do echo "$s"; [[ $s == *"exit=0" ]] || bad=1; done
exit $bad
