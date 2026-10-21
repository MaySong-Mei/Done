#!/usr/bin/env bash
# Restore the synced tables from a data dump, the way Supabase documents a
# self-managed restore, with the epoch step appended to the SAME transaction
# (design §6.6 "纪元行与暂停位", §5 ops rules R3 / R5 / R6).
#
#   restore.sh --target <postgres URL> --data data.sql [--roles roles.sql]
#              [--schema schema.sql] [--replace]
#
#   --roles/--schema  for a restore into a new, empty project (Supabase's
#                     documented three-file restore). Copy the old project's
#                     sync_epoch and sync_versions over FIRST (README R6);
#                     neither comes from the dump.
#   --replace         for a restore into the existing project: empties the
#                     nine synced tables first, inside the same transaction,
#                     under session_replication_role = replica. This is the
#                     only sanctioned use of replica mode on these tables
#                     (README.md, rule R2). Whole-database restores are for
#                     disasters only; to recover a few rows use R5.
#
# What the script does to the dump before it is replayed (a filtered copy;
# the dump file is not modified):
#   * the `setval('public.sync_seq', …)` line is removed — exactly one must
#     be present, otherwise the script aborts. The counter is never rewound;
#     the epoch step lifts it to max(live counter, restored max(seq));
#   * the `COPY public.sync_versions` block is removed — exactly one must be
#     present (the export must include the version log, README R6), and the
#     LIVE log is kept: the versions written after the dump are the ancestry
#     the devices will ask about;
#   * the `COPY public.sync_epoch` block is removed — it must hold exactly
#     one row, otherwise the script aborts; its epoch is recorded in the new
#     ledger record as dump_epoch. The live row stays: the ledger is carried
#     over, not replaced by the dump's.
# Everything — roles, schema, replica mode, the emptying, the filtered data
# and restore_with_epoch.sql — runs in one psql --single-transaction, so
# either the restored rows and the new epoch both land or neither does. The
# restore ends with paused = true and rollback = false; the operator clears
# `paused` after post_apply_checks.sql (run at the end of this script) is
# green. The last lines print epoch, kept_max, ledger length and paused.
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
  public.skill_insights, public.user_settings, public.agent_preferences, public.agent_conversations"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FILTERED="$TMP/data.filtered.sql"

# One pass over the dump: drop the three things listed in the header, count
# them, and read the dump's epoch out of the sync_epoch COPY block.
# Output (stdout): one line "setval=N epoch_rows=N epoch=E versions=N".
awk -v out="$FILTERED" '
  BEGIN { skip = 0; setval = 0; epoch_rows = 0; epoch = ""; versions = 0; epoch_col = 0; epoch_blocks = 0 }
  skip == 1 { if ($0 == "\\.") { skip = 0 } else if (skip_kind == "epoch") {
                epoch_rows++; n = split($0, f, "\t"); if (epoch_col > 0 && epoch_col <= n) epoch = f[epoch_col] }
              next }
  /^COPY public\.sync_versions \(/ { versions++; skip = 1; skip_kind = "versions"; next }
  /^COPY public\.sync_epoch \(/ {
    epoch_blocks++; skip = 1; skip_kind = "epoch"
    cols = $0; sub(/^COPY public\.sync_epoch \(/, "", cols); sub(/\) FROM stdin;.*$/, "", cols)
    n = split(cols, c, /, */); epoch_col = 0
    for (i = 1; i <= n; i++) if (c[i] == "epoch") epoch_col = i
    next }
  /^SELECT pg_catalog\.setval\(\x27public\.sync_seq\x27/ { setval++; next }
  { print > out }
  END { printf "setval=%d epoch_blocks=%d epoch_rows=%d epoch=%s versions=%d\n", setval, epoch_blocks, epoch_rows, (epoch == "" ? "-" : epoch), versions }
' "$DATA" > "$TMP/summary"
read -r SETVAL EPOCH_BLOCKS EPOCH_ROWS DUMP_EPOCH VERSIONS <<<"$(sed -E 's/setval=([0-9]+) epoch_blocks=([0-9]+) epoch_rows=([0-9]+) epoch=(.*) versions=([0-9]+)$/\1 \2 \3 \4 \5/' "$TMP/summary")"
[[ $DUMP_EPOCH == - ]] && DUMP_EPOCH=""
echo "restore.sh: dump $DATA: sync_seq setval lines=$SETVAL, sync_epoch rows=$EPOCH_ROWS (epoch=${DUMP_EPOCH:-none}), sync_versions blocks=$VERSIONS"
[[ $SETVAL == 1 ]] || { echo "restore.sh: refusing: the dump must carry exactly one setval of public.sync_seq (found $SETVAL)" >&2; exit 3; }
[[ $VERSIONS == 1 ]] || { echo "restore.sh: refusing: the export must include public.sync_versions (found $VERSIONS COPY blocks); README R6" >&2; exit 3; }
[[ $EPOCH_BLOCKS == 1 && $EPOCH_ROWS == 1 && -n $DUMP_EPOCH ]] || { echo "restore.sh: refusing: the dump must carry exactly one public.sync_epoch row (blocks=$EPOCH_BLOCKS rows=$EPOCH_ROWS)" >&2; exit 3; }

# The live row before anything happens: the ledger is carried over.
LIVE=$("$PSQL" "$TARGET" -At -c "select coalesce((select 'epoch=' || epoch || ' ledger=' || jsonb_array_length(restores) || ' paused=' || paused || ' rollback=' || rollback from public.sync_epoch), 'no sync_epoch row')")
echo "restore.sh: live before: $LIVE"

args=(--single-transaction --variable ON_ERROR_STOP=1 --dbname "$TARGET")
[[ -n $ROLES ]] && args+=(--file "$ROLES")
[[ -n $SCHEMA ]] && args+=(--file "$SCHEMA")
args+=(--command 'SET session_replication_role = replica')
[[ $REPLACE == 1 ]] && args+=(--command "TRUNCATE $SYNCED")
args+=(--file "$FILTERED")
args+=(--command "select set_config('done.restore_dump_epoch', '$DUMP_EPOCH', false)")
args+=(--file "$HERE/restore_with_epoch.sql")

"$PSQL" "${args[@]}"
"$PSQL" "$TARGET" -At -c "select 'restore.sh: restored: epoch=' || epoch || ' kept_max=' || (restores -> -1 ->> 'kept_max') || ' dump_epoch=' || coalesce(restores -> -1 ->> 'dump_epoch', 'null') || ' ledger=' || jsonb_array_length(restores) || ' paused=' || paused || ' rollback=' || rollback from public.sync_epoch"
"$PSQL" "$TARGET" -v ON_ERROR_STOP=1 -f "$HERE/post_apply_checks.sql"
