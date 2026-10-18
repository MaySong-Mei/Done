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
#       and its own guard against an unchanged epoch.
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
trap 'sql "delete from auth.users where email = '"'"'$EMAIL'"'"'" >/dev/null; sql "delete from realtime.messages where topic = '"'"'user:$RUID'"'"'" >/dev/null 2>&1; rm -rf "$TMP"' EXIT
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
"$PSQL" "$DB" -q -v ON_ERROR_STOP=1 -f "$OPS/restore_with_epoch.sql" >/dev/null 2>&1; rs=$?
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

echo
if [[ $fails -gt 0 ]]; then echo "FAILED checks: $fails"; exit 1; fi
echo "all restore drill checks passed"
