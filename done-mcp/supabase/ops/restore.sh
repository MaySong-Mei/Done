#!/usr/bin/env bash
# Restore the synced tables from a data dump, the way Supabase documents a
# self-managed restore, with the epoch step appended to the SAME transaction.
#
#   restore.sh --target <postgres URL> --data data.sql [--roles roles.sql]
#              [--schema schema.sql] [--replace]
#
#   --roles/--schema  for a restore into a new, empty project (Supabase's
#                     documented three-file restore).
#   --replace         for a restore into the existing project: empties the
#                     synced tables and sync_epoch first, inside the same
#                     transaction, under session_replication_role = replica.
#                     This is the only sanctioned use of replica mode on these
#                     tables (README.md, rule R2).
#
# Everything — roles, schema, replica mode, the emptying, data.sql and
# restore_with_epoch.sql — runs in one psql --single-transaction, so either
# the restored rows and the new epoch both land or neither does.
# Afterwards it runs post_apply_checks.sql and exits non-zero on any FAIL.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
PSQL=${PSQL:-$(command -v psql || echo /opt/homebrew/opt/libpq/bin/psql)}
TARGET="" DATA="" ROLES="" SCHEMA="" REPLACE=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --target) TARGET=$2; shift 2;;
    --data) DATA=$2; shift 2;;
    --roles) ROLES=$2; shift 2;;
    --schema) SCHEMA=$2; shift 2;;
    --replace) REPLACE=1; shift;;
    *) echo "unknown argument: $1" >&2; exit 2;;
  esac
done
[[ -n $TARGET && -n $DATA ]] || { echo "usage: restore.sh --target URL --data data.sql [--roles F] [--schema F] [--replace]" >&2; exit 2; }
[[ -r $DATA ]] || { echo "cannot read $DATA" >&2; exit 2; }

SYNCED="public.events, public.event_logs, public.event_feedback, public.todo_lists, public.event_types,
  public.skill_insights, public.user_settings, public.agent_preferences, public.agent_conversations, public.sync_epoch"

args=(--single-transaction --variable ON_ERROR_STOP=1 --dbname "$TARGET")
[[ -n $ROLES ]] && args+=(--file "$ROLES")
[[ -n $SCHEMA ]] && args+=(--file "$SCHEMA")
args+=(--command 'SET session_replication_role = replica')
[[ $REPLACE == 1 ]] && args+=(--command "TRUNCATE $SYNCED")
args+=(--file "$DATA" --file "$HERE/restore_with_epoch.sql")

"$PSQL" "${args[@]}"
"$PSQL" "$TARGET" -At -c "select 'restored: epoch=' || epoch || ' floor=' || floor || ' changed_at=' || changed_at from public.sync_epoch"
"$PSQL" "$TARGET" -v ON_ERROR_STOP=1 -f "$HERE/post_apply_checks.sql"
