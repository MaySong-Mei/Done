#!/usr/bin/env bash
# Bench S17 for migration 015: the restore drill (survey M2, §E.3).
# Dump the synced tables + sync_seq + sync_epoch with pg_dump, write more,
# restore the dump the way Supabase documents a self-managed restore (psql
# --single-transaction, session_replication_role = replica, the data file),
# and check the epoch:
#   (a) through ops/restore.sh, which appends ops/restore_with_epoch.sql to
#       the same transaction -> the epoch changes and floor = restored value;
#   (b) "forgot the script" -> the epoch does NOT change; records exactly
#       what a client can and cannot observe in that case (residual risk);
#   (c) an older dump restored without the script -> the epoch goes back to
#       an old value with that dump's stale floor (recorded);
#   (d) the script's branches the dumps never reach: a never-called sequence,
#       its own guard against an unchanged epoch, and a write landing inside
#       the step when it runs on its own under --single-transaction.
# Then S18, the rollback rehearsal (design §7 handoff (8), §8.3):
# ops/rollback.sql, king-shaped upserts (the last one on event_types), a
# trigger-less service_role PATCH and a physical DELETE in the window,
# ops/reenable.sql, the post-apply checks, and restore_with_epoch.sql as the
# reset. "Keeps the data" is a per-table md5 of every row's full content,
# around a fixture that holds a tombstone on every synced table and a row the
# window never writes; the rows the window wrote are compared across
# reenable.sql. Neither script may move sync_seq, and the reset's floor must
# cover every seq on every synced table. S18 needs the stack's
# secret key: SUPABASE_SECRET_KEY, or `supabase status -o env` from done-mcp/.
# LOCAL STACK ONLY. A restore rewinds the WHOLE synced tables and sync_seq,
# not one user, so the drill refuses to start when any user other than its
# own owns rows there (override with BENCH_ALLOW_REWIND=1 on a throwaway
# stack). Prints PASS/FAIL per check and exits non-zero when any failed.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
OPS="$HERE/../ops"
MIGRATION="$HERE/../migrations/015_sync_change_feed.sql"
REST=${SUPABASE_REST:-http://127.0.0.1:54321/rest/v1}
AUTH=${SUPABASE_AUTH:-http://127.0.0.1:54321/auth/v1}
PUB=${SUPABASE_PUBLISHABLE_KEY:-sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH}
DB=${SUPABASE_DB:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}
PSQL=${PSQL:-$(command -v psql || echo /opt/homebrew/opt/libpq/bin/psql)}
PG_DUMP=${PG_DUMP:-$(command -v pg_dump || echo /opt/homebrew/opt/libpq/bin/pg_dump)}
EMAIL=${BENCH_EMAIL_R:-bench-r@local.test}
PASSWORD=bench-password
export PSQL

case $DB in *127.0.0.1*|*localhost*) ;; *) echo "refusing: SUPABASE_DB is not a local address" >&2; exit 2;; esac

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fails=0
rec() { # id, pass(0/1), claim, observed
  local verdict=FAIL
  if [[ $2 == 1 ]]; then verdict=PASS; else fails=$((fails + 1)); fi
  printf '%s %-4s %s\n      %s\n' "$verdict" "$1" "$3" "$4"
}
sql() { "$PSQL" "$DB" -At -c "$1"; }
req() { # METHOD PATH TOKEN [DATA] [extra curl args...] -> status; body in $TMP/body
  local m=$1 path=$2 tok=$3 data=${4:-}; shift 4 || shift $#
  local -a args=(-s -o "$TMP/body" -w '%{http_code}' -X "$m" "$REST$path" -H "apikey: $PUB" -H "Content-Type: application/json")
  [[ -n $tok ]] && args+=(-H "Authorization: Bearer $tok")
  [[ -n $data ]] && args+=(--data-binary "$data")
  curl "${args[@]}" "$@"
}
body() { cat "$TMP/body"; }
py() { python3 -c "import json,sys
try: d=json.load(sys.stdin)
except Exception: d=None
$1" < "$TMP/body"; }
jlen() { py 'print(len(d) if isinstance(d,list) else -1)'; }
uuid() { python3 -c 'import uuid; print(uuid.uuid4())'; }

SYNCED=(events event_logs event_feedback todo_lists event_types skill_insights user_settings agent_preferences agent_conversations)
SYNCED_SQL=$(printf 'public.%s, ' "${SYNCED[@]}"); SYNCED_SQL="${SYNCED_SQL}public.sync_epoch"
DUMP_TABLES=(); for t in "${SYNCED[@]}"; do DUMP_TABLES+=(-t "public.$t"); done
DUMP_TABLES+=(-t public.sync_seq -t public.sync_epoch)

epoch() { sql "select epoch || ' ' || floor from public.sync_epoch"; }
last_value() { sql "select last_value from public.sync_seq"; }
frames() { sql "select count(*) from realtime.messages where topic = 'user:$RUID'"; }
dump() { "$PG_DUMP" --data-only --dbname="$DB" "${DUMP_TABLES[@]}" -f "$1"; }
# Supabase's documented self-managed restore (backup-restore guide) is
#   psql --single-transaction --variable ON_ERROR_STOP=1 --file roles.sql --file schema.sql
#        --command 'SET session_replication_role = replica' --file data.sql --dbname ...
# into a new project. Into this one, roles and schema already exist and the
# tables must be emptied first, in the same transaction (ops/restore.sh --replace).
restore_forgot() {
  "$PSQL" --single-transaction --variable ON_ERROR_STOP=1 --dbname "$DB" \
    --command 'SET session_replication_role = replica' \
    --command "TRUNCATE $SYNCED_SQL" \
    --file "$1" >"$TMP/restore.log" 2>&1
}
ev() { printf '{"id":"%s","user_id":"%s","kind":"todo","title":"%s"}' "$1" "$RUID" "$2"; }
post_ev() { # id title -> seq
  req POST "/events" "$TOK" "[$(ev "$1" "$2")]" -H "Prefer: resolution=merge-duplicates, return=representation" >/dev/null
  py 'print(d[0]["seq"] if isinstance(d,list) and d else "")'
}
patch_title() { # id base title -> status; body has the rows
  req PATCH "/events?id=eq.$1&seq=eq.$2" "$TOK" "{\"title\":\"$3\"}" -H "Prefer: return=representation"
}
pull_from() { # cursor -> rows in $TMP/body
  req POST /rpc/sync_changes "$TOK" "{\"since_seq\":$1,\"page_limit\":1000}" >/dev/null
}
row() { sql "select coalesce((select title || '|' || (deleted_at is not null) || '|' || seq from public.events where id = '$1'), 'absent')"; }

# ------------------------------------------------------------
# user (GoTrue) and the rewind guard
# ------------------------------------------------------------
sql "delete from auth.users where email = '$EMAIL'" >/dev/null
curl -s -o "$TMP/body" -X POST "$AUTH/signup" -H "apikey: $PUB" -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}" >/dev/null
TOK=$(py 'print((d or {}).get("access_token",""))'); RUID=$(py 'print(((d or {}).get("user") or {}).get("id",""))')
[[ -n $TOK && -n $RUID ]] || { echo "signup failed: $(body)"; exit 2; }
ROLLED_BACK=0
on_exit() {
  # S18 rolls the triggers back for real; never leave the stack that way
  if [[ $ROLLED_BACK == 1 ]]; then
    echo "S18 did not finish: re-enabling the sync triggers and resetting the epoch"
    "$PSQL" "$DB" --single-transaction -q -v ON_ERROR_STOP=1 -f "$OPS/reenable.sql" >/dev/null 2>&1
    "$PSQL" "$DB" --single-transaction -q -v ON_ERROR_STOP=1 -f "$OPS/restore_with_epoch.sql" >/dev/null 2>&1
  fi
  sql "delete from auth.users where email = '$EMAIL'" >/dev/null
  sql "delete from realtime.messages where topic = 'user:$RUID'" >/dev/null 2>&1
  rm -rf "$TMP"
}
trap on_exit EXIT
echo "user: $RUID"

others=0
for t in "${SYNCED[@]}"; do others=$((others + $(sql "select count(*) from public.$t where user_id <> '$RUID'"))); done
if [[ $others -gt 0 && ${BENCH_ALLOW_REWIND:-0} != 1 ]]; then
  rec S17 0 "precondition: no other user owns rows in the synced tables (a restore rewinds every user)" "rows of other users=$others; set BENCH_ALLOW_REWIND=1 on a throwaway stack"
  exit 1
fi

# ------------------------------------------------------------
# S17.0  the epoch row is a stable, read-only, client-visible fact
# ------------------------------------------------------------
e_before=$(epoch)
"$PSQL" "$DB" -q -v ON_ERROR_STOP=1 -f "$MIGRATION" >/dev/null 2>"$TMP/mig.log"; mig=$?
e_after=$(epoch)
rec S17 "$([[ $mig == 0 && -n $e_before && $e_before == "$e_after" ]] && echo 1 || echo 0)" \
  "rerunning migration 015 keeps the epoch and floor (a redeploy must not look like a restore)" "exit=$mig before='$e_before' after='$e_after'"

st=$(req GET "/sync_epoch?select=epoch,floor" "$TOK" "")
via_rest=$(py 'print("%s %s" % (d[0]["epoch"], d[0]["floor"]) if isinstance(d,list) and len(d)==1 else d)')
rec S17 "$([[ $st == 200 && $via_rest == "$e_after" ]] && echo 1 || echo 0)" \
  "authenticated GET /sync_epoch?select=epoch,floor returns the one row" "status=$st body=$(body)"
st=$(req GET "/sync_epoch?select=epoch,floor" "" "")
rec S17 "$([[ ($st == 401 || $st == 403) || ($st == 200 && $(jlen) == 0) ]] && echo 1 || echo 0)" \
  "anon (apikey only) cannot read the epoch" "status=$st body=$(body | head -c 160)"
st_p=$(req PATCH "/sync_epoch?epoch=neq.x" "$TOK" '{"epoch":"client","floor":0}' -H "Prefer: return=representation")
b_p=$(body | head -c 120)
st_i=$(req POST "/sync_epoch" "$TOK" '{"epoch":"client","floor":0}')
b_i=$(body | head -c 120)
st_d=$(req DELETE "/sync_epoch?epoch=neq.x" "$TOK" "")
rec S17 "$([[ $st_p != 2* && $st_i != 2* && $st_d != 2* && $(epoch) == "$e_after" ]] && echo 1 || echo 0)" \
  "authenticated PATCH / POST / DELETE on sync_epoch are refused and the row is unchanged" \
  "PATCH=$st_p ($b_p) POST=$st_i ($b_i) DELETE=$st_d row now='$(epoch)'"

# ------------------------------------------------------------
# S17a  restore through ops/restore.sh: the epoch changes, floor = restored value
# ------------------------------------------------------------
R1=$(uuid); R2=$(uuid); R3=$(uuid); X=$(uuid)
r1_seq=$(post_ev "$R1" "R1 v1"); post_ev "$R2" "R2 v1" >/dev/null; r3_seq=$(post_ev "$R3" "R3 v1")
r1_at_dump=$(row "$R1")
dump "$TMP/dump1.sql"; dump_rc=$?
n0=$(last_value); e0=$(epoch)
rec S17 "$([[ $dump_rc == 0 && -s $TMP/dump1.sql ]] && grep -q "setval('public.sync_seq', $n0, true)" "$TMP/dump1.sql" && echo 1 || echo 0)" \
  "pg_dump --data-only of the synced tables + sync_seq + sync_epoch carries the sequence value (N0)" \
  "exit=$dump_rc bytes=$(wc -c < "$TMP/dump1.sql" | tr -d ' ') N0=$n0 setval line: $(grep -o "setval('public.sync_seq'[^;]*" "$TMP/dump1.sql")"

x_seq=$(post_ev "$X" "X created after the dump")
st=$(patch_title "$R1" "$r1_seq" "R1 v2 after the dump")
req DELETE "/events?id=eq.$R2" "$TOK" "" >/dev/null
cursor=$(sql "select max(seq) from public.events where user_id = '$RUID'")
f0=$(frames)

"$OPS/restore.sh" --target "$DB" --data "$TMP/dump1.sql" --replace >"$TMP/restore_a.log" 2>&1; rs=$?
read -r e1 floor1 <<<"$(epoch)"
lv1=$(last_value); f1=$(frames)
rec S17 "$([[ $rs == 0 ]] && echo 1 || echo 0)" "ops/restore.sh --replace exits 0, including its post-apply checks" \
  "exit=$rs; $(grep -E 'restored:|post-apply' "$TMP/restore_a.log" | tr '\n' ' ')"
rec S17 "$([[ -n $e1 && $e1 != "${e0%% *}" && $floor1 == "$n0" && $lv1 == "$n0" ]] && echo 1 || echo 0)" \
  "after the scripted restore the epoch changed and floor = the restored sync_seq value" \
  "epoch '${e0%% *}' -> '$e1'; floor=$floor1; restored last_value=$lv1; N0 at dump=$n0; cursor before restore=$cursor"
rec S17 "$([[ $(row "$X") == absent && $(row "$R1") == "$r1_at_dump" && $(row "$R2") == "R2 v1|false|"* ]] && echo 1 || echo 0)" \
  "recorded: the restore rewinds content — X (created after the dump) is gone, R1 has its dump-time content and seq, R2's later tombstone is undone" \
  "X=$(row "$X") R1=$(row "$R1") (dump-time $r1_at_dump) R2=$(row "$R2")"
rec S17 "$([[ $f1 == "$f0" ]] && echo 1 || echo 0)" "recorded: the restore rings no doorbell (replica mode skips the triggers), so only the epoch tells a device" "frames $f0 -> $f1"
st=$(req GET "/sync_epoch?select=epoch,floor" "$TOK" "")
rec S17 "$([[ $st == 200 && $(py 'print("%s %s" % (d[0]["epoch"], d[0]["floor"]))') == "$e1 $floor1" ]] && echo 1 || echo 0)" \
  "a client's GET sees the new epoch and floor" "status=$st body=$(body)"
z_seq=$(post_ev "$(uuid)" "Z written after the scripted restore")
rec S17 "$([[ $z_seq -gt $floor1 && $z_seq -le $cursor ]] && echo 1 || echo 0)" \
  "the first write after the restore takes a seq above the floor (new content) yet at or below the old cursor (the rewind)" \
  "Z seq=$z_seq floor=$floor1 old cursor=$cursor"

# ------------------------------------------------------------
# S17b  restore WITHOUT the script: the epoch does not change
# ------------------------------------------------------------
dump "$TMP/dump2.sql"
n0b=$(last_value); eb=$(epoch)
X2=$(uuid)
x2_seq=$(post_ev "$X2" "X2 created after the second dump")
r3_base=$(sql "select seq from public.events where id = '$R3'")
patch_title "$R3" "$r3_base" "R3 v2 after the second dump" >/dev/null
r3_seq2=$(sql "select seq from public.events where id = '$R3'")
cursor_b=$(sql "select max(seq) from public.events where user_id = '$RUID'")

restore_forgot "$TMP/dump2.sql"; rs=$?
ea=$(epoch); lvb=$(last_value)
rec S17 "$([[ $rs == 0 && $ea == "$eb" && $lvb == "$n0b" && $(row "$X2") == absent ]] && echo 1 || echo 0)" \
  "forgot the script: the documented restore alone leaves the epoch and floor exactly as they were, while the data and sync_seq are rewound" \
  "exit=$rs epoch+floor '$eb' -> '$ea'; sync_seq $cursor_b -> $lvb; X2=$(row "$X2")"

# what a client can and cannot observe now (each line is a recorded fact)
st=$(req GET "/sync_epoch?select=epoch,floor" "$TOK" "")
rec S17 "$([[ $(py 'print("%s %s" % (d[0]["epoch"], d[0]["floor"]))') == "$eb" ]] && echo 1 || echo 0)" \
  "residual (cannot detect): the epoch GET answers the pre-restore value" "status=$st body=$(body)"
pull_from "$cursor_b"
rec S17 "$([[ $(jlen) == 0 ]] && echo 1 || echo 0)" \
  "residual (cannot detect): a pull from the device's cursor returns an empty page, the same answer as being at head" "sync_changes($cursor_b) rows=$(jlen)"
st=$(patch_title "$X2" "$x2_seq" "X2 edited after the forgotten restore")
rec S17 "$([[ $st == 200 && $(jlen) == 0 ]] && echo 1 || echo 0)" \
  "residual (cannot detect): editing X2 (gone from the server) with its base answers 200 [], the same as a stale or content-identical PATCH; pending-verify then sees nothing past the cursor and concludes 'same' (survey G1 scene 1)" \
  "PATCH ?id=eq.X2&seq=eq.$x2_seq -> status=$st body=$(body)"
st=$(patch_title "$R3" "$r3_seq2" "R3 v3")
rec S17 "$([[ $st == 200 && $(jlen) == 0 && $(row "$R3") == "R3 v1|false|$r3_seq" ]] && echo 1 || echo 0)" \
  "residual (cannot detect): editing R3 from its post-dump base also answers 200 []; the server holds the dump-time version" \
  "status=$st body=$(body) server R3=$(row "$R3")"
y_seq=$(post_ev "$(uuid)" "Y written by another device after the forgotten restore")
pull_from "$cursor_b"
y_seen=$(jlen)
rec S17 "$([[ $y_seq -le $cursor_b && $y_seen == 0 ]] && echo 1 || echo 0)" \
  "residual: another device's new write takes a seq at or below this device's cursor, so this device's pull skips it (cannot detect); only a write-response check could see the rewind (L10, not built)" \
  "Y seq=$y_seq cursor=$cursor_b; pull from cursor returned $y_seen rows"
pull_from 0
full=$(py 'ids={r["data"]["id"] for r in d if r["tbl"]=="events"}; print(("X2 missing" if "'"$X2"'" not in ids else "X2 present"), len(d))')
rec S17 "$([[ $full == "X2 missing"* ]] && echo 1 || echo 0)" \
  "residual (detectable only by a full audit): a pull from 0 shows X2 missing, which only a full re-pull and compare (sync.audit) would notice" "$full rows"

# ------------------------------------------------------------
# S17c  an older dump restored without the script
# ------------------------------------------------------------
restore_forgot "$TMP/dump1.sql"; rs=$?
ec=$(epoch)
rec S17 "$([[ $rs == 0 && $ec == "$e0" && ${ec%% *} != "${ea%% *}" ]] && echo 1 || echo 0)" \
  "recorded: restoring a dump older than an earlier scripted restore, without the script, brings that dump's epoch back — a device sees a change, but the floor is the old dump's value, not this restore's" \
  "epoch+floor '$ea' -> '$ec' (dump1's own row was '$e0'); sync_seq now $(last_value)"

# leave the stack honest: the epoch step after the last rewind
"$PSQL" "$DB" --single-transaction -q -v ON_ERROR_STOP=1 -f "$OPS/restore_with_epoch.sql" >/dev/null 2>&1; rs=$?
read -r ef floorf <<<"$(epoch)"
rec S17 "$([[ $rs == 0 && -n $ef && $ef != "${ec%% *}" && $floorf == "$(last_value)" ]] && echo 1 || echo 0)" \
  "restore_with_epoch.sql on its own (after the fact) sets a new epoch and floor = sync_seq" "epoch '${ec%% *}' -> '$ef' floor=$floorf sync_seq=$(last_value)"

# ------------------------------------------------------------
# S17d  the script's two branches the dumps above never reach
# ------------------------------------------------------------
# (1) a sequence that was never called (pg_dump writes setval(..., false) for
# it, e.g. a dump of a fresh database): nextval then hands out last_value
# itself, so the restored range ends one below it. (lv + 1, is_called false)
# is the same next value as (lv, true), so the setval below changes nothing a
# writer can see; sequences ignore rollback, hence the explicit put-back.
read -r lv_d called_d <<<"$(sql "select last_value || ' ' || is_called from public.sync_seq")"
e_d=$(epoch)
out=$("$PSQL" "$DB" -At -q -v ON_ERROR_STOP=1 -c "begin" \
        -c "select 'SETVAL=' || setval('public.sync_seq', $((lv_d + 1)), false)" \
        -f "$OPS/restore_with_epoch.sql" \
        -c "select 'FLOOR=' || floor from public.sync_epoch" -c "rollback" 2>&1); rs=$?
sql "select setval('public.sync_seq', $lv_d, $called_d)" >/dev/null
fl_d=$(echo "$out" | sed -n 's/^FLOOR=//p')
rec S17 "$([[ $rs == 0 && $called_d == true && $fl_d == "$lv_d" && $(epoch) == "$e_d" && $(last_value) == "$lv_d" ]] && echo 1 || echo 0)" \
  "a never-called sequence at last_value L+1 gives floor L, the last value actually handed out (rolled back, sequence put back)" \
  "sync_seq was ($lv_d, $called_d), set to ($((lv_d + 1)), false): floor=$fl_d want=$lv_d exit=$rs; epoch after rollback unchanged=$([[ $(epoch) == "$e_d" ]] && echo yes || echo no)"

# (2) the script's own guard: a copy that keeps the old epoch must abort
sed 's/set epoch = excluded.epoch/set epoch = sync_epoch.epoch/' "$OPS/restore_with_epoch.sql" > "$TMP/keep_epoch.sql"
out=$("$PSQL" "$DB" -At -q -v ON_ERROR_STOP=1 -c "begin" -f "$TMP/keep_epoch.sql" -c "rollback" 2>&1); rs=$?
rec S17 "$([[ $rs != 0 && $out == *"did not change"* && $(epoch) == "$e_d" ]] && ! cmp -s "$TMP/keep_epoch.sql" "$OPS/restore_with_epoch.sql" && echo 1 || echo 0)" \
  "negative control: a restore_with_epoch.sql that keeps the old epoch raises 'did not change', so restore.sh's transaction aborts" \
  "exit=$rs: $(echo "$out" | grep -o 'restore_with_epoch:[^;]*' | head -1); epoch unchanged=$([[ $(epoch) == "$e_d" ]] && echo yes || echo no)"

# (3) run on its own (after the fact, or the re-enable reset) nothing locks
# the tables, so a writer can take a number between the upsert and the guard.
# A copy that does that itself must leave the epoch alone when the file runs
# the way ops/README.md says, under --single-transaction; in autocommit the
# upsert would already be committed when the guard raises.
awk '{ print } /changed_at = excluded.changed_at;/ { print "select nextval('"'"'public.sync_seq'"'"');" }' \
  "$OPS/restore_with_epoch.sql" > "$TMP/racing_writer.sql"
out=$("$PSQL" "$DB" --single-transaction -At -q -v ON_ERROR_STOP=1 -f "$TMP/racing_writer.sql" 2>&1); rs=$?
rec S17 "$([[ $rs != 0 && $out == *"restore aborted"* && $(epoch) == "$e_d" ]] && ! cmp -s "$TMP/racing_writer.sql" "$OPS/restore_with_epoch.sql" && echo 1 || echo 0)" \
  "a write landing between the upsert and the guard aborts the step under --single-transaction and the epoch stays put (rerun the step)" \
  "exit=$rs: $(echo "$out" | grep -o 'restore_with_epoch:[^;]*' | head -1); epoch unchanged=$([[ $(epoch) == "$e_d" ]] && echo yes || echo no); sync_seq now $(last_value)"

# ------------------------------------------------------------
# S18  rollback rehearsal: ops/rollback.sql -> writes in the window ->
#      ops/reenable.sql -> post-apply checks -> restore_with_epoch.sql
# ------------------------------------------------------------
# the CLI reads SUPABASE_* variables as config overrides (SUPABASE_DB breaks
# it), so it runs without them
SECRET=${SUPABASE_SECRET_KEY:-$(cd "$HERE/../.." && env $(env | sed -n 's/^\(SUPABASE_[A-Za-z0-9_]*\)=.*/-u \1/p') supabase status -o env 2>/dev/null \
  | sed -n -e 's/^SECRET_KEY="\(.*\)"$/\1/p' -e 's/^SERVICE_ROLE_KEY="\(.*\)"$/\1/p' | head -1)}
sreq() { # METHOD PATH [DATA] [extra curl args...] as service_role (an edge function / MCP) -> status
  local m=$1 path=$2 data=${3:-}; shift 3 || shift $#
  local -a args=(-s -o "$TMP/body" -w '%{http_code}' -X "$m" "$REST$path" -H "apikey: $SECRET" -H "Content-Type: application/json")
  [[ -n $data ]] && args+=(--data-binary "$data")
  curl "${args[@]}" "$@"
}
post_apply_fails() { # -> comma list of failing check ids, "" when all pass
  "$PSQL" "$DB" -v ON_ERROR_STOP=1 -f "$OPS/post_apply_checks.sql" 2>/dev/null | grep -E '^ FAIL' | awk -F'|' '{gsub(/ /,"",$2); print $2}' | paste -sd, -
}
synced_rows() { local n=0 t; for t in "${SYNCED[@]}"; do n=$((n + $(sql "select count(*) from public.$t"))); done; echo $n; }
content() { # [ids to leave out, as a quoted SQL list] -> table=md5 of every row's full content, per synced table
  # rows keyed by user_id have no id; "id in (null)" is null, so they and
  # every row with no list given stay in
  local excl=${1:-null} t out=""
  for t in "${SYNCED[@]}"; do
    out+="$t=$(sql "select md5(coalesce(string_agg(j, E'\n' order by j), '')) from (select row_to_json(x)::text as j from public.$t x where not coalesce((row_to_json(x)->>'id') in ($excl), false)) s") "
  done
  echo "${out% }"
}
content_diff() { # before after -> the tables whose checksum differs
  local d="" a b
  for a in $1; do for b in $2; do [[ ${a%%=*} == "${b%%=*}" && $a != "$b" ]] && d+="${a%%=*} "; done; done
  echo "${d:-none}"
}
seq_of() { sql "select coalesce((select seq::text from public.events where id = '$1'), 'absent')"; }
et_seq() { sql "select coalesce((select seq::text from public.event_types where id = '$1'), 'absent')"; }
seq_state() { sql "select last_value || ' ' || is_called from public.sync_seq"; }
max_seq_all() { # -> max(seq) over every synced table and every user
  local q="" t
  for t in "${SYNCED[@]}"; do q+="${q:+ union all }select max(seq) as m from public.$t"; done
  sql "select coalesce(max(m)::text, 'none') from ($q) s"
}
# A checksum query that errors prints nothing on stdout, and two empty
# strings compare equal; every value must be an md5 before any comparison.
is_md5() { [[ $1 =~ ^[0-9a-f]{32}$ ]]; }
content_bad() { # content() output -> the synced tables without an md5 value ("none" when every table has one)
  local t w v bad=""
  for t in "${SYNCED[@]}"; do
    v=""
    for w in $1; do [[ ${w%%=*} == "$t" ]] && v=${w#*=}; done
    is_md5 "$v" || bad="${bad:+$bad }$t"
  done
  echo "${bad:-none}"
}

if [[ -z $SECRET ]]; then
  rec S18 0 "the stack's secret key is available for the service_role PATCH and DELETE" "set SUPABASE_SECRET_KEY or put the supabase CLI on PATH; S18 not run"
  echo; echo "FAILED checks: $fails"; exit 1
fi

K=$(uuid); P=$(uuid); D=$(uuid); N=$(uuid); L=$(uuid); T=$(uuid); U=$(uuid)
k_seq=$(post_ev "$K" "K v1"); p_seq=$(post_ev "$P" "P v1"); d_seq=$(post_ev "$D" "D v1")
# rows the window never touches: U live, and one row per synced table
# tombstoned through REST (T on events), so a rollback that purges, resurrects
# or rewrites rows on any table has something to change that nothing in the
# window overwrites
post_ev "$U" "U untouched by the window" >/dev/null
fx=()
tomb_fixture() { # table filter row-json -> appends "table:POST/DELETE" to fx
  local sp sd
  sp=$(req POST "/$1" "$TOK" "[$3]")
  sd=$(req DELETE "/$1?$2" "$TOK" "")
  fx+=("$1:$sp/$sd")
}
# plain statements, not "$(...)" inside fx=( ... ): bash 3.2 brace-expands
# the JSON there
note='tombstoned before the rollback'; occ='"occurrence_date":"2026-01-05T09:00:00Z"'
tomb_fixture events "id=eq.$T" "$(ev "$T" "T $note")"
id=fx-$(uuid); tomb_fixture event_logs "id=eq.$id" "{\"id\":\"$id\",\"user_id\":\"$RUID\",\"event_id\":\"$U\",$occ,\"note\":\"$note\"}"
id=fx-$(uuid); tomb_fixture event_feedback "id=eq.$id" "{\"id\":\"$id\",\"user_id\":\"$RUID\",\"event_id\":\"$U\",$occ,\"self_note\":\"$note\"}"
id=$(uuid); tomb_fixture todo_lists "id=eq.$id" "{\"id\":\"$id\",\"user_id\":\"$RUID\",\"title\":\"$note\",\"color_name\":\"blue\"}"
id=$(uuid); tomb_fixture event_types "id=eq.$id" "{\"id\":\"$id\",\"user_id\":\"$RUID\",\"title\":\"$note\",\"color_hex\":\"#336699\"}"
id=$(uuid); tomb_fixture skill_insights "id=eq.$id" "{\"id\":\"$id\",\"user_id\":\"$RUID\",\"skill_name\":\"fixture\",\"points\":1.5,\"date\":\"2026-01-05T09:00:00Z\",\"event_title\":\"$note\"}"
tomb_fixture user_settings "user_id=eq.$RUID" "{\"user_id\":\"$RUID\",\"settings\":{\"fixture\":\"$note\"}}"
tomb_fixture agent_preferences "user_id=eq.$RUID" "{\"user_id\":\"$RUID\",\"rules\":[\"$note\"]}"
tomb_fixture agent_conversations "user_id=eq.$RUID" "{\"user_id\":\"$RUID\",\"conversations\":[\"$note\"]}"
tombs() { # -> table=tombstones,live of this user, per synced table
  local t out=""
  for t in "${SYNCED[@]}"; do
    out+="$t=$(sql "select count(*) filter (where deleted_at is not null) || ',' || count(*) filter (where deleted_at is null) from public.$t where user_id = '$RUID'") "
  done
  echo "${out% }"
}
tombs0=$(tombs); u_row=$(row "$U")
fx_ok=1
for f in "${fx[@]}"; do [[ ${f#*:} == "201/204" ]] || fx_ok=0; done
for f in $tombs0; do v=${f#*=}; [[ ${v%,*} -ge 1 ]] || fx_ok=0; done
rec S18 "$([[ $fx_ok == 1 && $(row "$T") == "T tombstoned before the rollback|true|"* && $u_row == "U untouched by the window|false|"* ]] && echo 1 || echo 0)" \
  "fixture: before the rollback every synced table holds a tombstone made through REST, and events holds a live row U that the window never writes" \
  "POST/DELETE ${fx[*]}; tombstones,live per table: $tombs0; T=$(row "$T") U=$u_row"
cursor_r=$(sql "select max(seq) from public.events where user_id = '$RUID'")

# (counterfactual) the triggers gone WITHOUT the default: a write that leaves
# seq out fails NOT NULL, even an upsert that hits an existing row
out=$("$PSQL" "$DB" -At -q -c "begin" -c "drop trigger trg_events_sync_meta on public.events" \
  -c "do \$\$ begin insert into public.events (id, user_id, kind, title) values ('$(uuid)', '$RUID', 'todo', 'cf'); raise notice 'INS=ok'; exception when others then raise notice 'INS=%', sqlstate; end \$\$" \
  -c "do \$\$ begin insert into public.events (id, user_id, kind, title) values ('$K', '$RUID', 'todo', 'cf') on conflict (id) do update set title = excluded.title; raise notice 'UPS=ok'; exception when others then raise notice 'UPS=%', sqlstate; end \$\$" \
  -c "rollback" 2>&1)
ins=$(echo "$out" | sed -n 's/.*INS=//p'); ups=$(echo "$out" | sed -n 's/.*UPS=//p')
rec S18 "$([[ $ins == 23502 && $ups == 23502 && $(seq_of "$K") == "$k_seq" ]] && echo 1 || echo 0)" \
  "counterfactual (rolled back): dropping the triggers without a seq default makes an insert without seq AND an upsert hitting an existing row fail 23502, which is why rollback.sql adds the default" \
  "insert=$ins upsert-on-existing=$ups (K seq still $(seq_of "$K"))"

# (guard) a rollback.sql that forgets the default refuses itself
sed '/set default nextval/d' "$OPS/rollback.sql" > "$TMP/rollback_nodefault.sql"
sq_nd0=$(seq_state)
out=$("$PSQL" "$DB" -At -q -v ON_ERROR_STOP=1 -c "begin" -f "$TMP/rollback_nodefault.sql" -c "rollback" 2>&1); rs=$?
sq_nd1=$(seq_state)
rec S18 "$([[ $rs != 0 && $out == *"not in the rolled-back shape"* && -z $(post_apply_fails) && -n $sq_nd0 && $sq_nd1 == "$sq_nd0" ]] && ! cmp -s "$TMP/rollback_nodefault.sql" "$OPS/rollback.sql" && echo 1 || echo 0)" \
  "negative control: a rollback.sql without the seq default raises 'not in the rolled-back shape' and leaves nothing applied (sync_seq included: a setval survives a rollback)" \
  "exit=$rs: $(echo "$out" | grep -o 'rollback: not in[^,]*' | head -1); post-apply failures afterwards='$(post_apply_fails)'; sync_seq '$sq_nd0' -> '$sq_nd1'"

# the rollback, for real
rows0=$(synced_rows); e_r0=$(epoch); c0=$(content)
WINDOW="'$K', '$P', '$D', '$N', '$L'"
c0_out=$(content "$WINDOW")
sq_rb0=$(seq_state)
"$PSQL" "$DB" --single-transaction -q -v ON_ERROR_STOP=1 -f "$OPS/rollback.sql" >"$TMP/rollback.log" 2>&1; rs=$?
ROLLED_BACK=1
sq_rb1=$(seq_state)
fails_rb=$(post_apply_fails); c1=$(content)
bad0=$(content_bad "$c0"); bad1=$(content_bad "$c1")
rec S18 "$([[ $rs == 0 && $bad0 == none && $bad1 == none && $c1 == "$c0" && $(epoch) == "$e_r0" && $fails_rb == "P1,P8" ]] && echo 1 || echo 0)" \
  "ops/rollback.sql exits 0, keeps every row's full content (tombstones and seq included) and the epoch, and the post-apply checks then fail exactly P1 (sync triggers gone) and P8 (seq default present)" \
  "exit=$rs $(head -c 200 "$TMP/rollback.log") rows $rows0 -> $(synced_rows); tables without an md5 before/after: $bad0/$bad1; tables whose content changed: $(content_diff "$c0" "$c1"); tombstones,live per table now: $(tombs); epoch unchanged=$([[ $(epoch) == "$e_r0" ]] && echo yes || echo no); post-apply failures='$fails_rb'"
rec S18 "$([[ -n $sq_rb0 && $sq_rb1 == "$sq_rb0" ]] && echo 1 || echo 0)" \
  "ops/rollback.sql leaves sync_seq where it was (last_value and is_called)" \
  "sync_seq '$sq_rb0' -> '$sq_rb1'; max(seq) over the synced tables=$(max_seq_all)"
out=$("$PSQL" "$DB" -At -q -c "begin" -c "truncate public.events" -c "rollback" 2>&1)
rec S18 "$([[ $out == *"refused"* ]] && echo 1 || echo 0)" "the TRUNCATE guard stays during the rollback" "$(echo "$out" | grep -o 'truncate of[^:]*' | head -1)"

f_r0=$(frames)
st_n=$(req POST "/events" "$TOK" "[$(ev "$N" "N inserted during the rollback")]" -H "Prefer: resolution=merge-duplicates")
n_seq=$(seq_of "$N")
st_k=$(req POST "/events" "$TOK" "[$(ev "$K" "K upserted during the rollback")]" -H "Prefer: resolution=merge-duplicates")
rec S18 "$([[ $st_n == 201 && $n_seq =~ ^[0-9]+$ && $n_seq -gt $cursor_r && $st_k == 2* && $(row "$K") == "K upserted during the rollback|false|$k_seq" ]] && echo 1 || echo 0)" \
  "king-shaped upserts without seq succeed during the rollback: a new row takes a seq from the default, an existing row keeps its old seq" \
  "new N: status=$st_n seq=$n_seq (cursor $cursor_r); existing K: status=$st_k row=$(row "$K") (seq before $k_seq)"
# the window's highest seq sits on a table other than events, so a counter
# or floor taken from events alone lands below a row
st_l=$(req POST "/event_types" "$TOK" "[{\"id\":\"$L\",\"user_id\":\"$RUID\",\"title\":\"L inserted during the rollback\",\"color_hex\":\"#336699\"}]" -H "Prefer: resolution=merge-duplicates")
l_seq=$(et_seq "$L"); ev_max=$(sql "select max(seq) from public.events")
rec S18 "$([[ $st_l == 201 && $l_seq =~ ^[0-9]+$ && $ev_max =~ ^[0-9]+$ && $l_seq -gt $ev_max ]] && echo 1 || echo 0)" \
  "a king-shaped upsert of a new row on another synced table also takes a seq from the default, above every events row" \
  "new L on event_types: status=$st_l seq=$l_seq; max(seq) over events=$ev_max"


st_p=$(sreq PATCH "/events?id=eq.$P" '{"title":"P edited by the agent during the rollback"}' -H "Prefer: return=representation")
rec S18 "$([[ $st_p == 200 && $(jlen) == 1 && $(row "$P") == "P edited by the agent during the rollback|false|$p_seq" ]] && echo 1 || echo 0)" \
  "a trigger-less service_role PATCH succeeds and the row keeps its old seq" \
  "status=$st_p rows=$(jlen) row=$(row "$P") (seq before $p_seq)"
st_d=$(sreq DELETE "/events?id=eq.$D" "")
rec S18 "$([[ $st_d == 204 && $(row "$D") == absent ]] && echo 1 || echo 0)" \
  "a service_role DELETE during the rollback is physical: no tombstone is left" "status=$st_d row=$(row "$D")"
f_r1=$(frames)
pull_from "$cursor_r"
window=$(py 'ids=[r["data"]["id"] for r in d if r["tbl"]=="events"]; print("N" if "'"$N"'" in ids else "-", "K" if "'"$K"'" in ids else "-", "P" if "'"$P"'" in ids else "-")')
rec S18 "$([[ $f_r1 == "$f_r0" && $window == "N - -" ]] && echo 1 || echo 0)" \
  "recorded: nothing rings during the rollback, and a pull from the cursor sees the new row but neither in-place edit (they kept their old seq), which is why re-enabling resets every device" \
  "frames $f_r0 -> $f_r1; pull from $cursor_r sees (N, K, P)=($window)"

# re-enable: drop the default and rerun 015, then the checks, then the reset
win() { # -> md5 of the full content of the rows the window wrote
  sql "select md5(coalesce(string_agg(j, E'\n' order by j), '')) from (select row_to_json(e)::text as j from public.events e where e.id in ($WINDOW) union all select row_to_json(l)::text from public.event_types l where l.id in ($WINDOW)) s"
}
w1=$(win)
sq_re0=$(seq_state)
"$PSQL" "$DB" --single-transaction -q -v ON_ERROR_STOP=1 -f "$OPS/reenable.sql" >"$TMP/reenable.log" 2>&1; rs=$?
sq_re1=$(seq_state)
fails_re=$(post_apply_fails); "$PSQL" "$DB" -q -v ON_ERROR_STOP=1 -f "$OPS/post_apply_checks.sql" >/dev/null 2>&1; pa=$?
c2_out=$(content "$WINDOW"); w2=$(win)
bad0=$(content_bad "$c0_out"); bad2=$(content_bad "$c2_out")
rec S18 "$([[ $rs == 0 && $w1 =~ ^[0-9a-f]{32}$ && $w2 == "$w1" && $(row "$K") == "K upserted during the rollback|false|$k_seq" && $(row "$P") == "P edited by the agent during the rollback|false|$p_seq" && $(row "$N") == "N inserted during the rollback|false|$n_seq" && $(et_seq "$L") == "$l_seq" && $(row "$D") == absent ]] && echo 1 || echo 0)" \
  "ops/reenable.sql keeps what the window wrote: K's upsert and P's PATCH with their old seq, N and L with their default seq, D still gone" \
  "window rows' md5 before/after: '$w1'/'$w2'; K=$(row "$K") P=$(row "$P") N=$(row "$N") L seq=$(et_seq "$L") D=$(row "$D")"
rec S18 "$([[ $rs == 0 && $pa == 0 && -z $fails_re && $(epoch) == "$e_r0" && $bad0 == none && $bad2 == none && $c2_out == "$c0_out" ]] && echo 1 || echo 0)" \
  "ops/reenable.sql exits 0, keeps the epoch and the full content of every row outside the window (tombstones included), and post_apply_checks.sql is green again" \
  "exit=$rs $(grep -v '^$' "$TMP/reenable.log" | head -c 200) post-apply exit=$pa failures='$fails_re'; tables without an md5 before/after: $bad0/$bad2; tables whose content outside the window changed: $(content_diff "$c0_out" "$c2_out"); rows=$(synced_rows) (before the window $rows0, +N +L -D)"
rec S18 "$([[ -n $sq_re0 && $sq_re1 == "$sq_re0" ]] && echo 1 || echo 0)" \
  "ops/reenable.sql, its rerun of 015 included, leaves sync_seq where it was (last_value and is_called)" \
  "sync_seq '$sq_re0' -> '$sq_re1'; max(seq) over the synced tables=$(max_seq_all) (L=$l_seq)"
"$PSQL" "$DB" --single-transaction -q -v ON_ERROR_STOP=1 -f "$OPS/restore_with_epoch.sql" >/dev/null 2>&1; rs=$?
read -r e_r2 floor_r2 <<<"$(epoch)"
[[ $pa == 0 ]] && ROLLED_BACK=0
max_r2=$(max_seq_all)
fails_r2=$(post_apply_fails); "$PSQL" "$DB" -q -v ON_ERROR_STOP=1 -f "$OPS/post_apply_checks.sql" >/dev/null 2>&1; pa2=$?
rec S18 "$([[ $rs == 0 && $e_r2 != "${e_r0%% *}" && $floor_r2 == "$(last_value)" && $max_r2 =~ ^[0-9]+$ && $max_r2 -le $floor_r2 && $pa2 == 0 && -z $fails_r2 ]] && echo 1 || echo 0)" \
  "restore_with_epoch.sql is the re-enable reset: a new epoch, floor = sync_seq, every seq on every synced table at or below the floor (normal three-way on every device, no sentinel), and the post-apply checks stay green" \
  "exit=$rs epoch '${e_r0%% *}' -> '$e_r2' floor=$floor_r2 sync_seq=$(last_value); max(seq) over the synced tables=$max_r2; window K=$k_seq P=$p_seq N=$n_seq L=$l_seq; post-apply exit=$pa2 failures='$fails_r2'"

# the triggers are live again: the device's POST of D (its baseline never saw
# D at head) brings it back with a new seq and a doorbell; a DELETE tombstones
f_r2=$(frames)
st_b=$(req POST "/events" "$TOK" "[$(ev "$D" "D v1")]" -H "Prefer: resolution=ignore-duplicates, return=representation")
n_b=$(jlen); d_back=$(seq_of "$D")
st_x=$(req DELETE "/events?id=eq.$N" "$TOK" "")
rec S18 "$([[ $st_b == 201 && $n_b == 1 && $d_back -gt $floor_r2 && $(frames) -gt $f_r2 && $st_x == 204 && $(row "$N") == "N inserted during the rollback|true|"* ]] && echo 1 || echo 0)" \
  "after the re-enable the physically deleted row is POSTed back above the floor and rings, and a DELETE is a tombstone again" \
  "POST D: status=$st_b rows=$n_b seq=$d_back floor=$floor_r2; frames $f_r2 -> $(frames); DELETE N: status=$st_x row=$(row "$N")"

echo
if [[ $fails -gt 0 ]]; then echo "FAILED checks: $fails"; exit 1; fi
echo "all restore drill checks passed"
