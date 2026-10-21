#!/usr/bin/env bash
# Negative controls for the v6 bench checks (S19–S25, the restore drill's v6
# assertions): one mutation per check, applied to the live stack (a function
# replaced, a trigger dropped or renamed, an ops script edited in a copy),
# the relevant bench part rerun, the named check expected to go RED, then
# the original restored (a rerun of 015 rebuilds every function and trigger)
# and the part rerun GREEN. Without these a passing check proves nothing.
#
# Verdicts are three-valued:
#   PASS     the mutation turned the named check red, and the restore turned
#            it green again;
#   FAIL     the named check stayed green under the mutation (the check has
#            no teeth), or something else went red;
#   INVALID  the mutation did not apply (the function body or file is
#            unchanged), the bench produced no verdict line, or the restore
#            did not bring the bench back to green — nothing can be read
#            from that run.
# Local stack only. Logs go to $LOG_DIR (default: a temp dir, printed).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
OPS="$HERE/../ops"
MIGRATION="$HERE/../migrations/015_sync_change_feed.sql"
DB=${SUPABASE_DB:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}
PSQL=${PSQL:-$(command -v psql || echo /opt/homebrew/opt/libpq/bin/psql)}
LOG_DIR=${LOG_DIR:-$(mktemp -d)}
export PSQL SUPABASE_DB="$DB"
case $DB in *127.0.0.1*|*localhost*) ;; *) echo "refusing: SUPABASE_DB is not a local address" >&2; exit 2;; esac
mkdir -p "$LOG_DIR"
echo "v6 controls: logs in $LOG_DIR"

# the secret key once, from the real checkout (the drill copies cannot find
# config.toml from a temp dir)
SECRET=${SUPABASE_SECRET_KEY:-$(cd "$HERE/../.." && env $(env | sed -n 's/^\(SUPABASE_[A-Za-z0-9_]*\)=.*/-u \1/p') supabase status -o env 2>/dev/null \
  | sed -n -e 's/^SECRET_KEY="\(.*\)"$/\1/p' -e 's/^SERVICE_ROLE_KEY="\(.*\)"$/\1/p' | head -1)}
export SUPABASE_SECRET_KEY="$SECRET"

sql() { "$PSQL" "$DB" -At -c "$1"; }
fndef() { sql "select pg_get_functiondef('$1'::regprocedure)"; }
restore_015() { "$PSQL" "$DB" -q -v ON_ERROR_STOP=1 -f "$MIGRATION" >/dev/null 2>&1; }
# the renamed gate is a name 015 does not know; drop it before the rerun recreates the real one
r_gate_rename() { sql "drop trigger if exists trg_events_zz_gate on public.events" >/dev/null 2>&1; restore_015; }

pass=0; fail=0; invalid=0
verdicts=()
verdict() { # PASS|FAIL|INVALID name detail
  case $1 in PASS) pass=$((pass + 1));; FAIL) fail=$((fail + 1));; INVALID) invalid=$((invalid + 1));; esac
  printf '%-7s %s\n        %s\n' "$1" "$2" "$3"
  verdicts+=("$1 $2")
}

# run_part kind -> exit code; output in $out_file
# kind: sql (the SQL bench), http (BENCH_ONLY=v6), drill (a copy of tests+ops+migrations in $DRILL_ROOT)
run_part() {
  local kind=$1 out=$2
  case $kind in
    sql)   "$PSQL" "$DB" -v ON_ERROR_STOP=1 -f "$HERE/sync_feed_checks.sql" >"$out" 2>&1;;
    http)  BENCH_ONLY=v6 "$HERE/sync_feed_checks.sh" >"$out" 2>&1;;
    drill) "$DRILL_ROOT/tests/sync_restore_drill.sh" >"$out" 2>&1;;
  esac
}
summary_line() { # kind file -> the bench's summary line or ""
  case $1 in
    sql)   grep -E '^(all SQL checks passed|FAILED checks:)' "$2" | tail -1;;
    http)  grep -E '^(all HTTP checks passed|FAILED checks:)' "$2" | tail -1;;
    drill) grep -E '^(all restore drill checks passed|FAILED checks:)' "$2" | tail -1;;
  esac
}
red_ids() { # kind file -> the ids of the FAIL lines, comma-separated (sql: aligned table; sh: "FAIL Sxx")
  case $1 in
    sql) grep -E '^ FAIL' "$2" | awk -F'|' '{gsub(/ /,"",$2); print $2}' | sort -u | paste -sd, -;;
    *)   grep -E '^FAIL ' "$2" | awk '{print $2}' | sort -u | paste -sd, -;;
  esac
}
red_claim_matches() { # kind file pattern -> 0 when a FAIL line's claim matches the pattern
  case $1 in
    sql) grep -E '^ FAIL' "$2" | grep -qE -- "$3";;
    *)   grep -A1 -E '^FAIL ' "$2" | grep -qE -- "$3";;
  esac
}

# control kind name check_id claim_pattern mutate_fn restore_fn
# mutate_fn must print "applied" when the mutation is in place.
control() {
  local kind=$1 name=$2 cid=$3 pat=$4 mutate=$5 restore=$6
  local tag; tag=$(echo "$name" | tr -c 'A-Za-z0-9' '_')
  local m_out="$LOG_DIR/ctrl_${tag}.mutated.log" r_out="$LOG_DIR/ctrl_${tag}.restored.log"
  local applied; applied=$($mutate 2>&1 | tail -1)
  if [[ $applied != applied ]]; then
    $restore >/dev/null 2>&1
    verdict INVALID "$name" "mutation did not apply: $applied"
    return
  fi
  run_part "$kind" "$m_out"; local rc=$?
  local line; line=$(summary_line "$kind" "$m_out")
  local reds; reds=$(red_ids "$kind" "$m_out")
  $restore >/dev/null 2>&1
  run_part "$kind" "$r_out"; local rc2=$?
  local line2; line2=$(summary_line "$kind" "$r_out")
  if [[ -z $line ]]; then verdict INVALID "$name" "no verdict line under the mutation (exit=$rc), log $m_out"; return; fi
  if [[ -z $line2 || $rc2 != 0 ]]; then verdict INVALID "$name" "the restore did not bring the bench back to green: '$line2' (exit=$rc2), log $r_out"; return; fi
  if [[ $rc != 0 && ,$reds, == *",$cid,"* ]] && red_claim_matches "$kind" "$m_out" "$pat"; then
    verdict PASS "$name" "mutated: '$line' red=[$reds] (the named claim went red); restored: '$line2'"
  else
    verdict FAIL "$name" "mutated: '$line' red=[$reds] (expected $cid with a claim matching /$pat/); restored: '$line2'; log $m_out"
  fi
}

# ---- mutations that 015 reverses
m_gate_rename() { sql "alter trigger trg_events_sync_gate on public.events rename to trg_events_zz_gate" >/dev/null && sql "select 'applied' where exists (select 1 from pg_trigger where tgname = 'trg_events_zz_gate') and not exists (select 1 from pg_trigger where tgname = 'trg_events_sync_gate')"; }
m_gate_drop() { sql "drop trigger trg_events_sync_gate on public.events" >/dev/null && sql "select 'applied' where not exists (select 1 from pg_trigger where tgname = 'trg_events_sync_gate')"; }
m_fn() { # proc_sig old new -> replace one line of the function body
  local def; def=$(fndef "$1")
  local new; new=$(python3 -c 'import sys; d=sys.stdin.read(); o=sys.argv[1]; n=sys.argv[2]; sys.exit(1) if o not in d else print(d.replace(o, n, 1), end="")' "$2" "$3" <<<"$def") || { echo "pattern not in body"; return; }
  "$PSQL" "$DB" -q -v ON_ERROR_STOP=1 -c "$new" >/dev/null 2>&1 || { echo "replace failed"; return; }
  [[ $(fndef "$1") != "$def" ]] && echo applied || echo "body unchanged"
}
m_gate_no_paused() { m_fn 'public.sync_gate()' "if cur_paused and (h is not null or not cur_rollback) then" "if false then"; }
m_gate_no_header() { m_fn 'public.sync_gate()' "h := (hdr::json) ->> 'x-sync-epoch';" "h := null;"; }
m_version_trigger_drop() { sql "drop trigger trg_events_sync_version on public.events" >/dev/null && sql "select 'applied' where not exists (select 1 from pg_trigger where tgname = 'trg_events_sync_version')"; }
m_no_parent() { m_fn 'public.set_sync_meta()' "new.parent_version_id := old.version_id;" "null;"; }
m_rf_not_consumed() { m_fn 'public.set_sync_meta()' "new.restored_from_version_id := null;" "null;"; }
m_rf_not_logged() { m_fn 'public.set_sync_meta()' "if rf is not null then" "if false then"; }
m_keep_client_vid() { m_fn 'public.set_sync_meta()' "new.version_id := gen_random_uuid();" "new.version_id := case when tg_op = 'INSERT' then coalesce(new.version_id, gen_random_uuid()) else gen_random_uuid() end;"; }
m_no_noop() { m_fn 'public.set_sync_meta()' "if (to_jsonb(new) - meta) = (to_jsonb(old) - meta) then" "if false then"; }
m_meta_without_versions() { m_fn 'public.set_sync_meta()' "'version_id', 'parent_version_id', 'restored_from_version_id'" "'nothing'"; }
m_ancestor_no_rf_edge() { m_fn 'public.is_ancestor(text,text,uuid,uuid)' "or v.version_id = w.restored_from_version_id" "or false"; }
m_ancestor_false_not_null() { m_fn 'public.is_ancestor(text,text,uuid,uuid)' "then null" "then false"; }
m_ancestor_no_depth() { m_fn 'public.is_ancestor(text,text,uuid,uuid)' "where w.depth < 1000" "where w.depth < 100000"; }
m_prune_kills_live() { m_fn 'public.sync_versions_prune(integer)' "and not exists (select 1 from public.%I r where r.version_id = v.version_id)" "and %L is not null"; }
m_prune_no_cutoff() { m_fn 'public.sync_versions_prune(integer)' "v.created_at < \$1" "\$1 is not null"; }
m_log_wrong_key() { m_fn 'public.sync_log_version()' "k  text := to_jsonb(new) ->> tg_argv[0];" "k  text := new.user_id::text;"; }

# the migration's backfill (S24) lives in the file: mutate a copy in place and put the original back
MIG_BACKUP="$LOG_DIR/015.original.sql"
m_no_backfill() {
  cp "$MIGRATION" "$MIG_BACKUP"
  python3 - "$MIGRATION" <<'PY'
import sys,re
p=sys.argv[1]; s=open(p).read()
o="where not exists (select 1 from public.sync_versions v where v.version_id = r.version_id)"
if o not in s: print("pattern not in file"); sys.exit(0)
open(p,"w").write(s.replace(o, "where false", 1)); print("applied")
PY
}
r_backfill() { cp "$MIG_BACKUP" "$MIGRATION"; cmp -s "$MIG_BACKUP" "$MIGRATION" && restore_015; }

echo; echo "---- SQL bench controls (S20–S24)"
control sql "gate renamed after sync_meta (fires second)"        S20 "name sorts before|no seq taken" m_gate_rename        r_gate_rename
control sql "gate dropped on events"                             S20 "no seq taken|lands" m_gate_drop                     restore_015
control sql "gate ignores paused"                                S20 "paused" m_gate_no_paused                            restore_015
control sql "gate ignores the header"                            S20 "stale" m_gate_no_header                             restore_015
control sql "version trigger dropped on events"                  S21 "one log row|INSERT:" m_version_trigger_drop         restore_015
control sql "parent not set on UPDATE"                           S21 "parent" m_no_parent                                 restore_015
control sql "restored_from left on the row"                      S21 "write-back" m_rf_not_consumed                       restore_015
control sql "restored_from not passed to the log"                S21 "write-back" m_rf_not_logged                         restore_015
control sql "client version_id kept"                             S21 "ignored" m_keep_client_vid                          restore_015
control sql "no-op short-circuit removed"                        S21 "content-identical" m_no_noop                        restore_015
control sql "version columns counted as content"                 S21 "version columns are metadata" m_meta_without_versions restore_015
control sql "log keyed by user_id on id tables"                  S21 "id = the row|user_id logs its key" m_log_wrong_key    restore_015
control sql "is_ancestor ignores the restored_from edge"         S22 "restored_from edge" m_ancestor_no_rf_edge           restore_015
control sql "is_ancestor answers false for an unknown version"   S22 "unknown a or b is null|another user" m_ancestor_false_not_null restore_015
control sql "is_ancestor without the depth bound"                S22 "depth bound" m_ancestor_no_depth                    restore_015
control sql "prune deletes live versions"                        S23 "current version|prune\(0\)" m_prune_kills_live       restore_015
control sql "prune ignores the cutoff"                           S23 "prune\(90\)" m_prune_no_cutoff                       restore_015
control sql "015 without the version-log backfill"               S24 "backfill|adds a log row" m_no_backfill               r_backfill

echo; echo "---- HTTP bench controls (S19, S25)"
control http "gate dropped on events (HTTP)"                     S19 "stale|sync_epoch_stale" m_gate_drop                  restore_015
control http "gate ignores the header (HTTP)"                    S19 "stale" m_gate_no_header                             restore_015
control http "gate ignores paused (HTTP)"                        S19 "paused" m_gate_no_paused                            restore_015
control http "client version_id kept (HTTP)"                     S25 "version_id is replaced|ignored" m_keep_client_vid   restore_015
control http "restored_from left on the row (HTTP)"              S25 "write-back" m_rf_not_consumed                       restore_015
control http "version trigger dropped (HTTP)"                    S25 "log row|write-back" m_version_trigger_drop           restore_015

# ---- drill controls: a copy of tests + ops + migrations, the ops script mutated there
echo; echo "---- restore drill controls (S17 / S18)"
DRILL_ROOT=$(mktemp -d)
copy_tree() { rm -rf "$DRILL_ROOT"/{tests,ops,migrations}; mkdir -p "$DRILL_ROOT"; cp -R "$HERE" "$DRILL_ROOT/tests"; cp -R "$OPS" "$DRILL_ROOT/ops"; cp -R "$HERE/../migrations" "$DRILL_ROOT/migrations"; }
d_mutate() { # file sed-expr -> "applied" when the copy differs
  copy_tree
  sed -i.bak -e "$2" "$DRILL_ROOT/$1" && rm -f "$DRILL_ROOT/$1.bak"
  cmp -s "$DRILL_ROOT/$1" "$HERE/../$1" && echo "file unchanged" || echo applied
}
d_restore() { copy_tree; restore_015; "$PSQL" "$DB" -q -c "update public.sync_epoch set paused = false, rollback = false" >/dev/null 2>&1; }
m_restore_keeps_setval() { d_mutate ops/restore.sh 's/^  \/\^SELECT pg_catalog\\\.setval\\(\\x27public\\\.sync_seq\\x27\/ { setval++; next }$/  \/^SELECT pg_catalog\\.setval\\(\\x27public\\.sync_seq\\x27\/ { setval++; print > out; next }/'; }
m_restore_keeps_versions() { # keeps the dump's sync_versions block AND empties the live log first, so the restore succeeds with the dump's log in place of the live one
  d_mutate ops/restore.sh 's/^  \/\^COPY public\\\.sync_versions \\(\/ { versions++; skip = 1; skip_kind = "versions"; next }$/  \/^COPY public\\.sync_versions \\(\/ { versions++; print > out; next }/'$'\n''s/public.agent_conversations"$/public.agent_conversations, public.sync_versions"/'; }
m_rollback_no_stamp() { d_mutate ops/rollback.sql '/^    execute format($/{N;/sync_stamp before update/{N;N;d;};}'; }
m_reenable_no_step() { d_mutate ops/reenable.sql '/^\\ir restore_with_epoch.sql$/d'; }
m_step_no_lift() { d_mutate ops/restore_with_epoch.sql 's/^    perform setval(.public.sync_seq., kept_max, true);$/    null;/'; }
control drill "restore.sh keeps the dump's setval (counter rewound)"        S17 "NOT rewound" m_restore_keeps_setval   d_restore
control drill "restore.sh keeps the dump's sync_versions and empties the live log (log overwritten)" S17 "not overwritten" m_restore_keeps_versions d_restore
control drill "rollback.sql without the stamp trigger"                      S18 "NEW seq|stamp" m_rollback_no_stamp       d_restore
control drill "reenable.sql without the epoch step"                         S18 "epoch step inside reenable|reset" m_reenable_no_step d_restore
control drill "epoch step never lifts the counter"                          S17 "lifts sync_seq to kept_max" m_step_no_lift d_restore
rm -rf "$DRILL_ROOT"

echo; echo "---- v6 controls summary: PASS=$pass FAIL=$fail INVALID=$invalid"
for v in "${verdicts[@]}"; do echo "  $v"; done
[[ $fail == 0 && $invalid == 0 ]] && { echo "all v6 controls behaved"; exit 0; }
echo "v6 controls: $fail failed, $invalid invalid"; exit 1
