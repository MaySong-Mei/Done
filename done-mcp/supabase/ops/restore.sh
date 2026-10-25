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
# The dump must be the R6 export (README): COPY format, the nine synced
# tables plus sync_seq, sync_epoch and sync_versions, nothing else:
#   pg_dump --data-only -t public.events -t public.event_logs -t public.event_feedback \
#     -t public.todo_lists -t public.event_types -t public.skill_insights \
#     -t public.user_settings -t public.agent_preferences -t public.agent_conversations \
#     -t public.sync_seq -t public.sync_epoch -t public.sync_versions
# Identifiers may be quoted ("public"."events") or not; CRLF line ends are
# tolerated. Refused, before any connection is made:
#   * INSERT-format dumps (supabase db dump --data-only without --use-copy):
#     only COPY format is accepted;
#   * dumps with data blocks outside the public schema (a whole-database
#     export: auth.*, storage.* …) or for public tables outside the synced
#     set (api_keys, snapshots, … — supabase db dump -s public carries them):
#     they would collide with the live rows under --replace;
#   * not exactly one setval of sync_seq, not exactly one sync_versions
#     block, not exactly one sync_epoch row.
# What the script does to the dump before it is replayed (a filtered copy;
# the dump file is not modified):
#   * the `setval('public.sync_seq', …)` line is removed. The counter is never
#     rewound; the epoch step lifts it to max(live counter, restored max(seq));
#   * the `COPY public.sync_versions` block is removed and the LIVE log is
#     kept: the versions written after the dump are the ancestry the devices
#     will ask about;
#   * the `COPY public.sync_epoch` block is removed; its epoch is recorded in
#     the new ledger record as dump_epoch. The live row stays: the ledger is
#     carried over, not replaced by the dump's.
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
R6_HINT="export with README R6: pg_dump --data-only -t public.<nine synced tables> -t public.sync_seq -t public.sync_epoch -t public.sync_versions"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FILTERED="$TMP/data.filtered.sql"

# One pass over the dump. Every COPY / INSERT / setval target is normalised
# (quotes stripped) and classified; the blocks named in the header are
# dropped and counted, the dump's epoch is read out of the sync_epoch block.
# Output: one "key value" line per fact.
awk -v out="$FILTERED" '
  function norm(s) { gsub(/"/, "", s); return s }
  function add(list, item) { return (list == "" ? item : list "," item) }
  BEGIN {
    skip = 0; setval = 0; epoch_blocks = 0; epoch_rows = 0; epoch = ""; versions = 0; inserts = 0
    other_schema = ""; other_public = ""; noschema = ""; epoch_col = 0
    allowed["events"] = 1; allowed["event_logs"] = 1; allowed["event_feedback"] = 1; allowed["todo_lists"] = 1
    allowed["event_types"] = 1; allowed["skill_insights"] = 1; allowed["user_settings"] = 1
    allowed["agent_preferences"] = 1; allowed["agent_conversations"] = 1
  }
  { sub(/\r$/, "") }
  skip == 1 {
    if ($0 == "\\.") { skip = 0 }
    else if (skip_kind == "epoch") { epoch_rows++; n = split($0, f, "\t"); if (epoch_col > 0 && epoch_col <= n) epoch = f[epoch_col] }
    next
  }
  /^COPY / {
    line = $0; sub(/^COPY /, "", line); sub(/ \(.*$/, "", line); sub(/ FROM stdin;.*$/, "", line)
    name = norm(line); n = split(name, p, ".")
    if (n == 1) { noschema = add(noschema, name); print > out; next }
    if (n != 2 || p[1] != "public") { other_schema = add(other_schema, name); print > out; next }
    tbl = p[2]
    if (tbl == "sync_versions") { versions++; skip = 1; skip_kind = "versions"; next }
    if (tbl == "sync_epoch") {
      epoch_blocks++; skip = 1; skip_kind = "epoch"
      cols = $0; sub(/^COPY [^(]*\(/, "", cols); sub(/\) FROM stdin;.*$/, "", cols); cols = norm(cols)
      m = split(cols, c, /, */); epoch_col = 0
      for (i = 1; i <= m; i++) if (c[i] == "epoch") epoch_col = i
      next
    }
    if (!(tbl in allowed)) { other_public = add(other_public, tbl); print > out; next }
    print > out; next
  }
  /^INSERT INTO / {
    inserts++
    line = $0; sub(/^INSERT INTO /, "", line); sub(/ .*$/, "", line); name = norm(line); n = split(name, p, ".")
    if (n == 2 && p[1] != "public") other_schema = add(other_schema, name)
    next
  }
  /^SELECT (pg_catalog\.)?setval\(/ {
    line = $0; sub(/^SELECT (pg_catalog\.)?setval\(\x27/, "", line); sub(/\x27.*$/, "", line); name = norm(line)
    if (name == "public.sync_seq" || name == "sync_seq") { setval++; next }
    print > out; next
  }
  { print > out }
  END {
    printf "setval %d\nepoch_blocks %d\nepoch_rows %d\nepoch %s\nversions %d\ninserts %d\nother_schema %s\nother_public %s\nnoschema %s\n",
      setval, epoch_blocks, epoch_rows, (epoch == "" ? "-" : epoch), versions, inserts,
      (other_schema == "" ? "-" : other_schema), (other_public == "" ? "-" : other_public), (noschema == "" ? "-" : noschema)
  }
' "$DATA" > "$TMP/summary"
fact() { awk -v k="$1" '$1 == k { print $2 }' "$TMP/summary"; }
SETVAL=$(fact setval); EPOCH_BLOCKS=$(fact epoch_blocks); EPOCH_ROWS=$(fact epoch_rows); DUMP_EPOCH=$(fact epoch)
VERSIONS=$(fact versions); INSERTS=$(fact inserts); OTHER_SCHEMA=$(fact other_schema); OTHER_PUBLIC=$(fact other_public); NOSCHEMA=$(fact noschema)
[[ $DUMP_EPOCH == - ]] && DUMP_EPOCH=""
echo "restore.sh: dump $DATA: sync_seq setval lines=$SETVAL, sync_epoch rows=$EPOCH_ROWS (epoch=${DUMP_EPOCH:-none}), sync_versions blocks=$VERSIONS, INSERT statements=$INSERTS, blocks outside public=${OTHER_SCHEMA}, public tables outside the synced set=${OTHER_PUBLIC}, blocks without a schema=${NOSCHEMA}"
[[ $INSERTS == 0 ]] || { echo "restore.sh: refusing: only COPY format is accepted (pg_dump default / supabase db dump --use-copy); this dump has $INSERTS INSERT statements" >&2; exit 3; }
[[ $OTHER_SCHEMA == - ]] || { echo "restore.sh: refusing: the dump carries data blocks outside the public schema ($OTHER_SCHEMA): a whole-database export; $R6_HINT" >&2; exit 3; }
[[ $OTHER_PUBLIC == - ]] || { echo "restore.sh: refusing: the dump carries data for public tables outside the synced set ($OTHER_PUBLIC); they would collide with the live rows; $R6_HINT" >&2; exit 3; }
[[ $NOSCHEMA == - ]] || { echo "restore.sh: refusing: COPY blocks without a schema prefix ($NOSCHEMA) cannot be classified; $R6_HINT" >&2; exit 3; }
[[ $SETVAL == 1 ]] || { echo "restore.sh: refusing: the dump must carry exactly one setval of public.sync_seq (found $SETVAL)" >&2; exit 3; }
[[ $VERSIONS != 0 ]] || { echo "restore.sh: refusing: the export must include public.sync_versions (found 0 COPY blocks); README R6" >&2; exit 3; }
[[ $VERSIONS == 1 ]] || { echo "restore.sh: refusing: the dump must carry exactly one public.sync_versions block (found $VERSIONS)" >&2; exit 3; }
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
