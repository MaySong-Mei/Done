#!/usr/bin/env bash
# Bench S17 / S18 for migration 015 v6: the restore drill and the rollback
# rehearsal (design §6.6 "Phase 1 交付" / "测试", §8.3 "照文档的导出与恢复",
# §7 handoff (8)).
#
# S17.0  the epoch row: a rerun of 015 keeps epoch and ledger; the client's
#        GET; anon and client writes refused.
# S17a   a restore through ops/restore.sh: the epoch changes, the counter is
#        NOT rewound, the ledger gains one record with kept_max = the highest
#        seq over the nine tables (tombstones included) and dump_epoch = the
#        dump's epoch, paused ends true, the version log is NOT overwritten
#        by the dump, no doorbell rings, the first write after unpausing takes
#        a number above the old cursor.
# S17r   restore.sh refuses a dump without the sync_epoch row, without
#        sync_versions, and with two setval lines.
# S17b   a restore that bypassed the script ("forgot the script"): the data
#        and the counter are rewound and the dump's epoch row comes back
#        (recorded), then the immediate repair (paused, the epoch step on its
#        own): ledger +1, epoch changed, counter lifted, paused.
# S17d   the step's guard and its lock: a copy that keeps the old epoch is
#        refused; a copy without the lock lets a racing writer take a number
#        that the ledger then calls kept (recorded as the reason for the
#        lock); the real step with a racing writer blocks the writer until
#        the commit, after which the gate refuses it.
# S18    the rollback rehearsal: ops/rollback.sql (W=0), the gate during the
#        window (header-bearing PATCH refused with sync_paused, service_role
#        PATCH takes a NEW seq, old-build upsert 201, physical DELETE),
#        ops/reenable.sql (epoch changed, ledger +1 with dump_epoch null,
#        rollback false, paused still true, post-apply green including P12 for
#        the rows inserted in the window), then the device POSTs the deleted
#        row back with its parent.
# S17n   a manual restore into a "new project" without the two cross-restore
#        tables, emulated on this stack (sync_versions emptied, a fresh epoch
#        row with an empty ledger, then the documented restore of a dump that
#        lacks both tables): P10 red, P12 red — design §9.37 (1), recorded.
#        The drill then reruns 015 (backfill) and the epoch step to leave the
#        stack in shape.
#
# LOCAL STACK ONLY. A restore rewinds the WHOLE synced tables, not one user,
# so the drill refuses to start when any user other than its own owns rows
# there (override with BENCH_ALLOW_REWIND=1 on a throwaway stack). It needs
# the stack's secret key (SUPABASE_SECRET_KEY, or `supabase status -o env`
# from done-mcp/). Prints PASS/FAIL per check and exits non-zero when any
# failed.
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
code_msg() { py 'print("%s %s" % (d.get("code",""), d.get("message","")) if isinstance(d,dict) else "")'; }
uuid() { python3 -c 'import uuid; print(uuid.uuid4())'; }

SYNCED=(events event_logs event_feedback todo_lists event_types skill_insights user_settings agent_preferences agent_conversations)
SYNCED_SQL=$(printf 'public.%s, ' "${SYNCED[@]}"); SYNCED_SQL="${SYNCED_SQL%, }"
DUMP_TABLES=(); for t in "${SYNCED[@]}"; do DUMP_TABLES+=(-t "public.$t"); done
DUMP_TABLES+=(-t public.sync_seq -t public.sync_epoch -t public.sync_versions)

epoch() { sql "select epoch from public.sync_epoch"; }
paused() { sql "select paused || ' ' || rollback from public.sync_epoch"; }
ledger_len() { sql "select coalesce((select jsonb_array_length(restores) from public.sync_epoch), -1)"; }
ledger_last() { sql "select coalesce((select restores -> -1 from public.sync_epoch), 'null'::jsonb)::text"; }
ledger_last_kept() { sql "select coalesce((select restores -> -1 ->> 'kept_max' from public.sync_epoch), 'none')"; }
ledger_last_dump() { sql "select coalesce((select restores -> -1 ->> 'dump_epoch' from public.sync_epoch), 'null')"; }
last_value() { sql "select last_value from public.sync_seq"; }
seq_state() { sql "select last_value || ' ' || is_called from public.sync_seq"; }
frames() { sql "select count(*) from realtime.messages where topic = 'user:$RUID'"; }
hdr() { echo "X-Sync-Epoch: $(epoch)"; }
unpause() { sql "update public.sync_epoch set paused = false" >/dev/null; }
max_seq_all() { # -> max(seq) over every synced table and every user (tombstones included)
  local q="" t
  for t in "${SYNCED[@]}"; do q+="${q:+ union all }select max(seq) as m from public.$t"; done
  sql "select coalesce(max(m)::text, 'none') from ($q) s"
}
log_rows() { sql "select count(*) from public.sync_versions"; }
dump() { "$PG_DUMP" --data-only --dbname="$DB" "${DUMP_TABLES[@]}" -f "$1"; }
# Supabase's documented self-managed restore (backup-restore guide) is
#   psql --single-transaction --variable ON_ERROR_STOP=1 --file roles.sql --file schema.sql
#        --command 'SET session_replication_role = replica' --file data.sql --dbname ...
# into a new project. Into this one, roles and schema already exist and the
# tables must be emptied first, in the same transaction (what restore.sh
# --replace does, minus everything restore.sh adds).
restore_forgot() { # data.sql [tables to truncate]
  "$PSQL" --single-transaction --variable ON_ERROR_STOP=1 --dbname "$DB" \
    --command 'SET session_replication_role = replica' \
    --command "TRUNCATE ${2:-$SYNCED_SQL, public.sync_epoch, public.sync_versions}" \
    --file "$1" >"$TMP/restore.log" 2>&1
}
ev() { printf '{"id":"%s","user_id":"%s","kind":"todo","title":"%s"}' "$1" "$RUID" "$2"; }
post_ev() { # id title -> seq (with the current epoch header)
  req POST "/events" "$TOK" "[$(ev "$1" "$2")]" -H "Prefer: resolution=merge-duplicates, return=representation" -H "$(hdr)" >/dev/null
  py 'print(d[0]["seq"] if isinstance(d,list) and d else "")'
}
patch_title() { # id base title [extra curl args] -> status; body has the rows
  local id=$1 base=$2 title=$3; shift 3
  req PATCH "/events?id=eq.$id&seq=eq.$base" "$TOK" "{\"title\":\"$title\"}" -H "Prefer: return=representation" "$@"
}
pull_from() { # cursor -> rows in $TMP/body
  req POST /rpc/sync_changes "$TOK" "{\"since_seq\":$1,\"page_limit\":1000}" >/dev/null
}
row() { sql "select coalesce((select title || '|' || (deleted_at is not null) || '|' || seq from public.events where id = '$1'), 'absent')"; }
vid() { sql "select coalesce((select version_id::text from public.events where id = '$1'), 'absent')"; }
post_apply_fails() { # -> comma list of failing check ids, "" when all pass
  "$PSQL" "$DB" -v ON_ERROR_STOP=1 -f "$OPS/post_apply_checks.sql" 2>/dev/null | grep -E '^ FAIL' | awk -F'|' '{gsub(/ /,"",$2); print $2}' | paste -sd, -
}

# ------------------------------------------------------------
# user (GoTrue), the secret key and the rewind guard
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
    echo "S18 did not finish: re-enabling the sync triggers"
    "$PSQL" "$DB" --single-transaction -q -v ON_ERROR_STOP=1 -f "$OPS/reenable.sql" >/dev/null 2>&1
  fi
  unpause
  sql "delete from auth.users where email = '$EMAIL'" >/dev/null
  sql "delete from realtime.messages where topic = 'user:$RUID'" >/dev/null 2>&1
  rm -rf "$TMP"
}
trap on_exit EXIT
echo "user: $RUID"

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
if [[ -z $SECRET ]]; then
  rec S17 0 "the stack's secret key is available (INVALID: the drill needs service_role)" "set SUPABASE_SECRET_KEY or put the supabase CLI on PATH; drill not run"
  echo; echo "FAILED checks: $fails"; exit 1
fi

others=0
for t in "${SYNCED[@]}"; do others=$((others + $(sql "select count(*) from public.$t where user_id <> '$RUID'"))); done
if [[ $others -gt 0 && ${BENCH_ALLOW_REWIND:-0} != 1 ]]; then
  rec S17 0 "precondition: no other user owns rows in the synced tables (a restore rewinds every user)" "rows of other users=$others; set BENCH_ALLOW_REWIND=1 on a throwaway stack"
  exit 1
fi
unpause

# ------------------------------------------------------------
# S17.0  the epoch row is a stable, read-only, client-visible fact
# ------------------------------------------------------------
e_before=$(epoch); l_before=$(ledger_len); last_before=$(ledger_last)
"$PSQL" "$DB" -q -v ON_ERROR_STOP=1 -f "$MIGRATION" >/dev/null 2>"$TMP/mig.log"; mig=$?
e_after=$(epoch)
rec S17 "$([[ $mig == 0 && -n $e_before && $e_before == "$e_after" && $(ledger_len) == "$l_before" && $(ledger_last) == "$last_before" ]] && echo 1 || echo 0)" \
  "rerunning migration 015 keeps the epoch and the ledger (a redeploy must not look like a restore)" "exit=$mig epoch '$e_before' -> '$e_after' ledger $l_before -> $(ledger_len), last record unchanged=$([[ $(ledger_last) == "$last_before" ]] && echo yes || echo no)"

st=$(req GET "/sync_epoch?select=epoch,paused,restores" "$TOK" "")
via_rest=$(py 'print("%s %s %s" % (d[0]["epoch"], d[0]["paused"], len(d[0]["restores"])) if isinstance(d,list) and len(d)==1 else d)')
rec S17 "$([[ $st == 200 && $via_rest == "$e_after False $l_before" ]] && echo 1 || echo 0)" \
  "authenticated GET /sync_epoch?select=epoch,paused,restores returns the one row (epoch, paused false, the ledger)" "status=$st (epoch paused ledger_len)=$via_rest"
st=$(req GET "/sync_epoch?select=epoch,paused,restores" "" "")
rec S17 "$([[ ($st == 401 || $st == 403) || ($st == 200 && $(jlen) == 0) ]] && echo 1 || echo 0)" \
  "anon (apikey only) cannot read the epoch" "status=$st body=$(body | head -c 160)"
st_p=$(req PATCH "/sync_epoch?epoch=neq.x" "$TOK" '{"epoch":"client","paused":true}' -H "Prefer: return=representation")
b_p=$(body | head -c 120)
st_i=$(req POST "/sync_epoch" "$TOK" '{"epoch":"client"}')
b_i=$(body | head -c 120)
st_d=$(req DELETE "/sync_epoch?epoch=neq.x" "$TOK" "")
rec S17 "$([[ $st_p != 2* && $st_i != 2* && $st_d != 2* && $(epoch) == "$e_after" ]] && echo 1 || echo 0)" \
  "authenticated PATCH / POST / DELETE on sync_epoch are refused and the row is unchanged" \
  "PATCH=$st_p ($b_p) POST=$st_i ($b_i) DELETE=$st_d epoch now='$(epoch)'"

# ------------------------------------------------------------
# S17a  restore through ops/restore.sh
# ------------------------------------------------------------
R1=$(uuid); R2=$(uuid); R3=$(uuid); X=$(uuid)
r1_seq=$(post_ev "$R1" "R1 v1"); post_ev "$R2" "R2 v1" >/dev/null; r3_seq=$(post_ev "$R3" "R3 v1")
r1_at_dump=$(row "$R1"); r1_vid_at_dump=$(vid "$R1")
dump "$TMP/dump1.sql"; dump_rc=$?
n0=$(last_value); e0=$(epoch); l0=$(ledger_len)
rec S17 "$([[ $dump_rc == 0 && -s $TMP/dump1.sql ]] && grep -q "setval('public.sync_seq', $n0, true)" "$TMP/dump1.sql" && grep -q '^COPY public.sync_versions ' "$TMP/dump1.sql" && grep -q '^COPY public.sync_epoch ' "$TMP/dump1.sql" && echo 1 || echo 0)" \
  "pg_dump --data-only of the synced tables + sync_seq + sync_epoch + sync_versions carries the sequence value (N0) and both cross-restore tables" \
  "exit=$dump_rc bytes=$(wc -c < "$TMP/dump1.sql" | tr -d ' ') N0=$n0 setval line: $(grep -o "setval('public.sync_seq'[^;]*" "$TMP/dump1.sql")"

# writes after the dump: X created, R1 edited (version v2), R2 tombstoned
x_seq=$(post_ev "$X" "X created after the dump")
st=$(patch_title "$R1" "$r1_seq" "R1 v2 after the dump" -H "$(hdr)")
r1_vid_after=$(vid "$R1")
req PATCH "/events?id=in.($R2)&deleted_at=is.null" "$TOK" "{\"deleted_at\":\"2026-01-05T09:00:00Z\"}" -H "$(hdr)" >/dev/null
cursor=$(max_seq_all); log_before=$(log_rows)
r1_v2_logged=$(sql "select count(*) from public.sync_versions where version_id = '$r1_vid_after'")
f0=$(frames)

"$OPS/restore.sh" --target "$DB" --data "$TMP/dump1.sql" --replace >"$TMP/restore_a.log" 2>&1; rs=$?
e1=$(epoch); lv1=$(last_value); f1=$(frames); l1=$(ledger_len); kept1=$(ledger_last_kept); de1=$(ledger_last_dump); pz1=$(paused)
rec S17 "$([[ $rs == 0 ]] && echo 1 || echo 0)" "ops/restore.sh --replace exits 0, including its post-apply checks" \
  "exit=$rs; $(grep -E 'restore.sh:|post-apply' "$TMP/restore_a.log" | tr '\n' ' ' | head -c 400)"
rec S17 "$([[ -n $e1 && $e1 != "$e0" && $lv1 -ge $cursor && $lv1 -ge $n0 ]] && echo 1 || echo 0)" \
  "after the scripted restore the epoch changed and the counter was NOT rewound (at or above the pre-restore cursor; the dump's setval was dropped)" \
  "epoch '$e0' -> '$e1'; sync_seq last_value=$lv1 (N0 at dump=$n0, cursor before restore=$cursor)"
rec S17 "$([[ $l1 == $((l0 + 1)) && $kept1 == "$(max_seq_all)" && $kept1 -le $n0 && $de1 == "$e0" && $pz1 == "true false" ]] && echo 1 || echo 0)" \
  "the ledger gained one record: kept_max = max(seq) over the nine tables after the restore (at or below N0), dump_epoch = the dump's epoch; paused true, rollback false" \
  "ledger $l0 -> $l1 last=$(ledger_last); max(seq) now=$(max_seq_all); N0=$n0; paused/rollback='$pz1'"
rec S17 "$([[ $(row "$X") == absent && $(row "$R1") == "$r1_at_dump" && $(vid "$R1") == "$r1_vid_at_dump" && $(row "$R2") == "R2 v1|false|"* ]] && echo 1 || echo 0)" \
  "recorded: the restore rewinds content — X (created after the dump) is gone, R1 has its dump-time content, seq and version_id, R2's later tombstone is undone" \
  "X=$(row "$X") R1=$(row "$R1") vid=$(vid "$R1") (dump-time $r1_at_dump / $r1_vid_at_dump) R2=$(row "$R2")"
rec S17 "$([[ $(log_rows) == "$log_before" && $r1_v2_logged == 1 && $(sql "select count(*) from public.sync_versions where version_id = '$r1_vid_after'") == 1 ]] && echo 1 || echo 0)" \
  "the version log was not overwritten by the dump: R1's post-dump version v2 is still logged after the restore (the dump's sync_versions block was stripped)" \
  "log rows $log_before -> $(log_rows); R1 v2 ($r1_vid_after) logged before/after: $r1_v2_logged/$(sql "select count(*) from public.sync_versions where version_id = '$r1_vid_after'")"
rec S17 "$([[ $f1 == "$f0" ]] && echo 1 || echo 0)" "recorded: the restore rings no doorbell (replica mode skips the triggers), so only the epoch tells a device" "frames $f0 -> $f1"
st=$(req GET "/sync_epoch?select=epoch,paused,restores" "$TOK" "")
rec S17 "$([[ $st == 200 && $(py 'print("%s %s %s" % (d[0]["epoch"], d[0]["paused"], d[0]["restores"][-1]["kept_max"]))') == "$e1 True $kept1" ]] && echo 1 || echo 0)" \
  "a client's GET sees the new epoch, paused = true and the ledger's last kept_max" "status=$st body=$(body | head -c 300)"
st=$(req POST "/events" "$TOK" "[$(ev "$(uuid)" "write under the old epoch")]" -H "Prefer: resolution=merge-duplicates" -H "X-Sync-Epoch: $e0"); cm=$(code_msg)
rec S17 "$([[ $st == 400 && $cm == "P0001 sync_epoch_stale" ]] && echo 1 || echo 0)" "a device still writing under the old epoch is refused by the gate: 400 sync_epoch_stale" "status=$st code/message='$cm'"
st=$(req POST "/events" "$TOK" "[$(ev "$(uuid)" "write while paused")]" -H "Prefer: resolution=merge-duplicates" -H "$(hdr)"); cm=$(code_msg)
rec S17 "$([[ $st == 400 && $cm == "P0001 sync_paused" ]] && echo 1 || echo 0)" "with the new epoch but the server still paused: 400 sync_paused" "status=$st code/message='$cm'"
unpause
z_seq=$(post_ev "$(uuid)" "Z written after the scripted restore")
rec S17 "$([[ $z_seq -gt $cursor && $z_seq -gt $kept1 ]] && echo 1 || echo 0)" \
  "after unpausing, the first write takes a seq above the old cursor and above kept_max (no number is handed out twice)" \
  "Z seq=$z_seq cursor before restore=$cursor kept_max=$kept1"
# R1's new version after the restore has parent = the dump-time version; the
# lost v2 is not an ancestor of it (what the device asks before prompting)
r1_base=$(sql "select seq from public.events where id = '$R1'")
patch_title "$R1" "$r1_base" "R1 v3 after the restore" -H "$(hdr)" >/dev/null
r1_vid_v3=$(vid "$R1")
st=$(req POST /rpc/is_ancestor "$TOK" "{\"p_tbl\":\"events\",\"p_id\":\"$R1\",\"a\":\"$r1_vid_after\",\"b\":\"$r1_vid_v3\"}"); anc=$(body)
st2=$(req POST /rpc/is_ancestor "$TOK" "{\"p_tbl\":\"events\",\"p_id\":\"$R1\",\"a\":\"$r1_vid_at_dump\",\"b\":\"$r1_vid_v3\"}"); anc2=$(body)
rec S17 "$([[ $st == 200 && $anc == false && $st2 == 200 && $anc2 == true ]] && echo 1 || echo 0)" \
  "ancestry after the restore: the lost post-dump version v2 is NOT an ancestor of the row's new version v3 (the device prompts), the dump-time version v1 is" \
  "is_ancestor(v2, v3)=$anc is_ancestor(v1, v3)=$anc2 (v3 parent=$(sql "select parent_version_id from public.events where id = '$R1'"), v1=$r1_vid_at_dump)"

# ------------------------------------------------------------
# S17r  restore.sh refuses dumps that cannot carry the evidence
# ------------------------------------------------------------
awk '/^COPY public\.sync_epoch \(/{skip=1; next} skip && /^\\\.$/{skip=0; next} !skip{print}' "$TMP/dump1.sql" > "$TMP/dump_noepoch.sql"
awk '/^COPY public\.sync_versions \(/{skip=1; next} skip && /^\\\.$/{skip=0; next} !skip{print}' "$TMP/dump1.sql" > "$TMP/dump_noversions.sql"
{ cat "$TMP/dump1.sql"; grep "setval('public.sync_seq'" "$TMP/dump1.sql"; } > "$TMP/dump_twosetval.sql"
e_r=$(epoch); l_r=$(ledger_len); rows_r=$(row "$R1")
"$OPS/restore.sh" --target "$DB" --data "$TMP/dump_noepoch.sql" --replace >"$TMP/r_noepoch.log" 2>&1; rs1=$?
"$OPS/restore.sh" --target "$DB" --data "$TMP/dump_noversions.sql" --replace >"$TMP/r_noversions.log" 2>&1; rs2=$?
"$OPS/restore.sh" --target "$DB" --data "$TMP/dump_twosetval.sql" --replace >"$TMP/r_twosetval.log" 2>&1; rs3=$?
rec S17 "$([[ $rs1 != 0 && $rs2 != 0 && $rs3 != 0 ]] && grep -q 'exactly one public.sync_epoch row' "$TMP/r_noepoch.log" && grep -q 'must include public.sync_versions' "$TMP/r_noversions.log" && grep -q 'exactly one setval' "$TMP/r_twosetval.log" && [[ $(epoch) == "$e_r" && $(ledger_len) == "$l_r" && $(row "$R1") == "$rows_r" ]] && echo 1 || echo 0)" \
  "restore.sh refuses a dump without the sync_epoch row, without sync_versions, and with two setval lines, before touching anything" \
  "exits=$rs1/$rs2/$rs3; $(grep -h 'refusing' "$TMP/r_noepoch.log" "$TMP/r_noversions.log" "$TMP/r_twosetval.log" | cut -c1-110 | tr '\n' ' '); epoch/ledger/R1 unchanged=$([[ $(epoch) == "$e_r" && $(ledger_len) == "$l_r" && $(row "$R1") == "$rows_r" ]] && echo yes || echo no)"

# ------------------------------------------------------------
# S17b  restore WITHOUT the script, then the immediate repair
# ------------------------------------------------------------
dump "$TMP/dump2.sql"
n0b=$(last_value); eb=$(epoch); lb=$(ledger_len)
X2=$(uuid)
x2_seq=$(post_ev "$X2" "X2 created after the second dump")
r3_base=$(sql "select seq from public.events where id = '$R3'")
patch_title "$R3" "$r3_base" "R3 v2 after the second dump" -H "$(hdr)" >/dev/null
r3_seq2=$(sql "select seq from public.events where id = '$R3'")
cursor_b=$(max_seq_all)
log_b=$(log_rows)

restore_forgot "$TMP/dump2.sql"; rs=$?
ea=$(epoch); lvb=$(last_value)
rec S17 "$([[ $rs == 0 && $ea == "$eb" && $(ledger_len) == "$lb" && $lvb == "$n0b" && $(row "$X2") == absent && $(log_rows) -lt $log_b ]] && echo 1 || echo 0)" \
  "forgot the script (recorded): the documented restore alone brings back the dump's epoch row and ledger, rewinds the data, sync_seq and the version log" \
  "exit=$rs epoch '$eb' -> '$ea' ledger $lb -> $(ledger_len); sync_seq $cursor_b -> $lvb; X2=$(row "$X2"); log rows $log_b -> $(log_rows)"
pull_from "$cursor_b"
rec S17 "$([[ $(jlen) == 0 ]] && echo 1 || echo 0)" \
  "residual (cannot detect before the repair): a pull from the device's cursor returns an empty page, the same answer as being at head" "sync_changes($cursor_b) rows=$(jlen)"
st=$(patch_title "$X2" "$x2_seq" "X2 edited after the forgotten restore" -H "$(hdr)")
rec S17 "$([[ $st == 200 && $(jlen) == 0 ]] && echo 1 || echo 0)" \
  "residual (cannot detect before the repair): editing X2 (gone from the server) with its base answers 200 [], the same as a stale PATCH; the epoch header still matches, so the gate lets it through" \
  "PATCH ?id=eq.X2&seq=eq.$x2_seq -> status=$st body=$(body)"
# the repair, as README R3 says: pause first, then the step on its own
sql "update public.sync_epoch set paused = true" >/dev/null
"$PSQL" "$DB" --single-transaction -q -v ON_ERROR_STOP=1 -f "$OPS/restore_with_epoch.sql" >"$TMP/step_b.log" 2>&1; rs=$?
ef=$(epoch); lf=$(ledger_len); kf=$(ledger_last_kept); df=$(ledger_last_dump); lvf=$(last_value)
rec S17 "$([[ $rs == 0 && -n $ef && $ef != "$ea" && $lf == $((lb + 1)) && $kf == "$(max_seq_all)" && $df == null && $(paused) == "true false" && $lvf -ge $kf ]] && echo 1 || echo 0)" \
  "the immediate repair (paused, then restore_with_epoch.sql on its own): a new epoch, ledger +1 with kept_max = max(seq) and dump_epoch null, paused, the counter at or above kept_max" \
  "exit=$rs epoch '$ea' -> '$ef' ledger $lb -> $lf last=$(ledger_last) max(seq)=$(max_seq_all) sync_seq=$lvf $(grep -o 'restore_with_epoch: .*' "$TMP/step_b.log" | head -1)"
st=$(req GET "/sync_epoch?select=epoch,paused,restores" "$TOK" "")
rec S17 "$([[ $st == 200 && $(py 'print(d[0]["epoch"])') == "$ef" ]] && echo 1 || echo 0)" "a device's next GET sees the repair's epoch" "status=$st epoch=$(py 'print(d[0]["epoch"])')"
unpause

# ------------------------------------------------------------
# S17d  the step's guard and the lock
# ------------------------------------------------------------
e_d=$(epoch); l_d=$(ledger_len)
sed 's/set epoch      = excluded.epoch,/set epoch      = public.sync_epoch.epoch,/' "$OPS/restore_with_epoch.sql" > "$TMP/keep_epoch.sql"
out=$("$PSQL" "$DB" --single-transaction -At -q -v ON_ERROR_STOP=1 -f "$TMP/keep_epoch.sql" 2>&1); rs=$?
rec S17 "$([[ $rs != 0 && $out == *"did not change"* && $(epoch) == "$e_d" && $(ledger_len) == "$l_d" ]] && ! cmp -s "$TMP/keep_epoch.sql" "$OPS/restore_with_epoch.sql" && echo 1 || echo 0)" \
  "negative control: a restore_with_epoch.sql that keeps the old epoch raises 'did not change' and --single-transaction undoes its ledger record" \
  "exit=$rs: $(echo "$out" | grep -o 'restore_with_epoch:[^;]*' | head -1); epoch/ledger unchanged=$([[ $(epoch) == "$e_d" && $(ledger_len) == "$l_d" ]] && echo yes || echo no)"
sed 's/paused     = true,/paused     = false,/' "$OPS/restore_with_epoch.sql" > "$TMP/no_pause.sql"
out=$("$PSQL" "$DB" --single-transaction -At -q -v ON_ERROR_STOP=1 -f "$TMP/no_pause.sql" 2>&1); rs=$?
rec S17 "$([[ $rs != 0 && $out == *"paused is not true"* && $(epoch) == "$e_d" ]] && ! cmp -s "$TMP/no_pause.sql" "$OPS/restore_with_epoch.sql" && echo 1 || echo 0)" \
  "negative control: a step that does not pause is refused by its own guard" "exit=$rs: $(echo "$out" | grep -o 'restore_with_epoch:[^;]*' | head -1)"

# the lock: a writer racing the step. The step reads kept_max, then (in this
# copy) sleeps 2 s before it commits; a background psql inserts as postgres
# after 0.5 s. Without the lock the insert lands inside the gap with a seq
# above kept_max, and the ledger calls that number kept. With the lock the
# insert waits for the commit, then meets the gate (paused) and is refused.
racer() { # title -> background psql that inserts after 0.5 s
  ( sleep 0.5; "$PSQL" "$DB" -At -c "insert into public.events (id, user_id, kind, title) values ('$1', '$RUID', 'todo', 'racer') returning seq" >"$TMP/racer_$1.out" 2>&1; echo "rc=$?" >>"$TMP/racer_$1.out" ) &
}
awk '{ print } /if m > kept_max then kept_max := m; end if;/ { c++ } /end loop;/ && c == 1 && !done { print "  perform pg_sleep(2);"; done = 1 }' "$OPS/restore_with_epoch.sql" > "$TMP/slow_step.sql"
sed '/^lock table/,/^in share row exclusive mode;/d' "$TMP/slow_step.sql" > "$TMP/slow_step_nolock.sql"
RA=$(uuid); racer "$RA"
"$PSQL" "$DB" --single-transaction -At -q -v ON_ERROR_STOP=1 -f "$TMP/slow_step_nolock.sql" >"$TMP/nolock.log" 2>&1; rs=$?
wait
ra_seq=$(sed -n '1p' "$TMP/racer_$RA.out"); kept_nl=$(ledger_last_kept)
rec S17 "$([[ $rs == 0 && $ra_seq =~ ^[0-9]+$ && $ra_seq -gt $kept_nl && $(row "$RA") == "racer|false|$ra_seq" ]] && ! cmp -s "$TMP/slow_step_nolock.sql" "$OPS/restore_with_epoch.sql" && grep -q 'pg_sleep(2)' "$TMP/slow_step_nolock.sql" && ! grep -q 'lock table' "$TMP/slow_step_nolock.sql" && echo 1 || echo 0)" \
  "negative control (why the lock is there): a step WITHOUT the lock lets a racing writer take a seq after kept_max was read — the row lands above the ledger's kept_max, so a device holding it would never be prompted" \
  "step exit=$rs racer seq=$ra_seq kept_max recorded=$kept_nl row=$(row "$RA")"
unpause
RB=$(uuid); racer "$RB"
"$PSQL" "$DB" --single-transaction -At -q -v ON_ERROR_STOP=1 -f "$TMP/slow_step.sql" >"$TMP/lock.log" 2>&1; rs=$?
wait
rb_out=$(cat "$TMP/racer_$RB.out" | tr '\n' ' ')
rec S17 "$([[ $rs == 0 && $rb_out == *sync_paused* && $(row "$RB") == absent ]] && grep -q 'lock table' "$TMP/slow_step.sql" && echo 1 || echo 0)" \
  "with the lock: the racing writer waits for the step's commit and then meets the gate — refused with sync_paused, no row, nothing above kept_max" \
  "step exit=$rs racer: $(echo "$rb_out" | cut -c1-120) row=$(row "$RB") kept_max=$(ledger_last_kept) max(seq)=$(max_seq_all)"
unpause

# ------------------------------------------------------------
# S18  rollback rehearsal: ops/rollback.sql -> writes in the window ->
#      ops/reenable.sql -> post-apply checks
# ------------------------------------------------------------
synced_rows() { local n=0 t; for t in "${SYNCED[@]}"; do n=$((n + $(sql "select count(*) from public.$t"))); done; echo $n; }
content() { # [ids to leave out, as a quoted SQL list] -> table=md5 of every row's full content, per synced table
  local excl=${1:-null} t out=""
  for t in "${SYNCED[@]}"; do
    out+="$t=$(sql "select md5(coalesce(string_agg(j, E'\n' order by j), '')) from (select row_to_json(x)::text as j from public.$t x where not coalesce((row_to_json(x)->>'id') in ($excl), false)) s") "
  done
  echo "${out% }"
}
content_diff() { local d="" a b; for a in $1; do for b in $2; do [[ ${a%%=*} == "${b%%=*}" && $a != "$b" ]] && d+="${a%%=*} "; done; done; echo "${d:-none}"; }
is_md5() { [[ $1 =~ ^[0-9a-f]{32}$ ]]; }
content_bad() { local t w v bad=""; for t in "${SYNCED[@]}"; do v=""; for w in $1; do [[ ${w%%=*} == "$t" ]] && v=${w#*=}; done; is_md5 "$v" || bad="${bad:+$bad }$t"; done; echo "${bad:-none}"; }
seq_of() { sql "select coalesce((select seq::text from public.events where id = '$1'), 'absent')"; }
et_seq() { sql "select coalesce((select seq::text from public.event_types where id = '$1'), 'absent')"; }

K=$(uuid); P=$(uuid); D=$(uuid); N=$(uuid); L=$(uuid); T=$(uuid); U=$(uuid)
k_seq=$(post_ev "$K" "K v1"); p_seq=$(post_ev "$P" "P v1"); d_seq=$(post_ev "$D" "D v1")
p_vid=$(vid "$P"); d_vid=$(vid "$D")
post_ev "$U" "U untouched by the window" >/dev/null
fx=()
tomb_fixture() { # table filter row-json -> appends "table:POST/DELETE" to fx
  local sp sd
  sp=$(req POST "/$1" "$TOK" "[$3]" -H "$(hdr)")
  sd=$(req DELETE "/$1?$2" "$TOK" "" -H "$(hdr)")
  fx+=("$1:$sp/$sd")
}
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
tombs() { local t out=""; for t in "${SYNCED[@]}"; do out+="$t=$(sql "select count(*) filter (where deleted_at is not null) || ',' || count(*) filter (where deleted_at is null) from public.$t where user_id = '$RUID'") "; done; echo "${out% }"; }
tombs0=$(tombs); u_row=$(row "$U")
fx_ok=1
for f in "${fx[@]}"; do [[ ${f#*:} == "201/204" ]] || fx_ok=0; done
for f in $tombs0; do v=${f#*=}; [[ ${v%,*} -ge 1 ]] || fx_ok=0; done
rec S18 "$([[ $fx_ok == 1 && $(row "$T") == "T tombstoned before the rollback|true|"* && $u_row == "U untouched by the window|false|"* ]] && echo 1 || echo 0)" \
  "fixture: before the rollback every synced table holds a tombstone made through REST, and events holds a live row U that the window never writes" \
  "POST/DELETE ${fx[*]}; tombstones,live per table: $tombs0; T=$(row "$T") U=$u_row"
cursor_r=$(max_seq_all)

# (counterfactual) the triggers gone WITHOUT the default: a write that leaves
# seq out fails NOT NULL, even an upsert that hits an existing row
out=$("$PSQL" "$DB" -At -q -c "begin" -c "drop trigger trg_events_sync_meta on public.events" -c "drop trigger trg_events_sync_version on public.events" \
  -c "do \$\$ begin insert into public.events (id, user_id, kind, title) values ('$(uuid)', '$RUID', 'todo', 'cf'); raise notice 'INS=ok'; exception when others then raise notice 'INS=%', sqlstate; end \$\$" \
  -c "do \$\$ begin insert into public.events (id, user_id, kind, title) values ('$K', '$RUID', 'todo', 'cf') on conflict (id) do update set title = excluded.title; raise notice 'UPS=ok'; exception when others then raise notice 'UPS=%', sqlstate; end \$\$" \
  -c "rollback" 2>&1)
ins=$(echo "$out" | sed -n 's/.*INS=//p'); ups=$(echo "$out" | sed -n 's/.*UPS=//p')
rec S18 "$([[ $ins == 23502 && $ups == 23502 && $(seq_of "$K") == "$k_seq" ]] && echo 1 || echo 0)" \
  "counterfactual (rolled back): dropping the triggers without a seq default makes an insert without seq AND an upsert hitting an existing row fail 23502, which is why rollback.sql adds the default" \
  "insert=$ins upsert-on-existing=$ups (K seq still $(seq_of "$K"))"

# (guard) a rollback.sql that forgets the default refuses itself (W=0; step 3 is
# the transaction that must roll back; step 1's pause is undone by hand)
sed '/set default nextval/d' "$OPS/rollback.sql" > "$TMP/rollback_nodefault.sql"
sq_nd0=$(seq_state)
out=$("$PSQL" "$DB" -At -q -v ON_ERROR_STOP=1 -v W=0 -f "$TMP/rollback_nodefault.sql" 2>&1); rs=$?
sq_nd1=$(seq_state); pa_nd=$(post_apply_fails)
sql "update public.sync_epoch set paused = false, rollback = false" >/dev/null
rec S18 "$([[ $rs != 0 && $out == *"not in the rolled-back shape"* && -z $pa_nd && -n $sq_nd0 && $sq_nd1 == "$sq_nd0" ]] && ! cmp -s "$TMP/rollback_nodefault.sql" "$OPS/rollback.sql" && echo 1 || echo 0)" \
  "negative control: a rollback.sql without the seq default raises 'not in the rolled-back shape' and leaves step 3 unapplied (sync_seq included; only step 1's pause stays, undone here by hand)" \
  "exit=$rs: $(echo "$out" | grep -o 'rollback: not in[^,]*' | head -1); post-apply failures afterwards='$pa_nd'; sync_seq '$sq_nd0' -> '$sq_nd1'"

# the rollback, for real (W=0 on the bench; ops waits 35 s)
rows0=$(synced_rows); e_r0=$(epoch); l_r0=$(ledger_len); c0=$(content)
WINDOW="'$K', '$P', '$D', '$N', '$L'"
c0_out=$(content "$WINDOW")
sq_rb0=$(seq_state)
"$PSQL" "$DB" -q -v ON_ERROR_STOP=1 -v W=0 -f "$OPS/rollback.sql" >"$TMP/rollback.log" 2>&1; rs=$?
ROLLED_BACK=1
sq_rb1=$(seq_state)
fails_rb=$(post_apply_fails); c1=$(content)
bad0=$(content_bad "$c0"); bad1=$(content_bad "$c1")
rec S18 "$([[ $rs == 0 && $bad0 == none && $bad1 == none && $c1 == "$c0" && $(epoch) == "$e_r0" && $(paused) == "true true" && $fails_rb == "P1,P8" ]] && echo 1 || echo 0)" \
  "ops/rollback.sql exits 0, sets paused and rollback, keeps every row's full content (tombstones, seq and versions included) and the epoch, and the post-apply checks then fail exactly P1 (sync triggers gone, stamp trigger present) and P8 (seq default present)" \
  "exit=$rs $(grep -v '^$' "$TMP/rollback.log" | head -c 160 | tr '\n' ' ') rows $rows0 -> $(synced_rows); paused/rollback='$(paused)'; tables without an md5 before/after: $bad0/$bad1; tables whose content changed: $(content_diff "$c0" "$c1"); epoch unchanged=$([[ $(epoch) == "$e_r0" ]] && echo yes || echo no); post-apply failures='$fails_rb'"
rec S18 "$([[ -n $sq_rb0 && $sq_rb1 == "$sq_rb0" ]] && echo 1 || echo 0)" \
  "ops/rollback.sql leaves sync_seq where it was (last_value and is_called)" "sync_seq '$sq_rb0' -> '$sq_rb1'; max(seq) over the synced tables=$(max_seq_all)"
out=$("$PSQL" "$DB" -At -q -c "begin" -c "truncate public.events" -c "rollback" 2>&1)
rec S18 "$([[ $out == *"refused"* ]] && echo 1 || echo 0)" "the TRUNCATE guard stays during the rollback" "$(echo "$out" | grep -o 'truncate of[^:]*' | head -1)"
gates=$(sql "select count(*) from pg_trigger where tgname ~ '^trg_.*_sync_gate$' and tgenabled = 'O'")
stamps=$(sql "select count(*) from pg_trigger where tgname ~ '^trg_.*_sync_stamp$' and tgenabled = 'O'")
rec S18 "$([[ $gates == 9 && $stamps == 9 ]] && echo 1 || echo 0)" "the write gate stays on all nine tables and the stamp trigger is on all nine during the rollback" "gates=$gates stamps=$stamps"
# a deploy inside the rollback window reruns the migrations: 015 must refuse
sig() { sql "select (select string_agg(tgname, ',' order by tgname) from pg_trigger where tgrelid = 'public.events'::regclass and not tgisinternal) || ' | default=' || coalesce((select pg_get_expr(d.adbin, d.adrelid) from pg_attribute a join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum where a.attrelid = 'public.events'::regclass and a.attname = 'seq'), 'none') || ' | paused/rollback=' || (select paused || '/' || rollback from public.sync_epoch) || ' | stampfn=' || (select count(*) from pg_proc where proname = 'sync_stamp_seq')"; }
s_g0=$(sig)
out=$("$PSQL" "$DB" -v ON_ERROR_STOP=1 -f "$MIGRATION" 2>&1); rs=$?
s_g1=$(sig)
rec S18 "$([[ $rs != 0 && $out == *"015: server is rolled back"* && $s_g1 == "$s_g0" && $s_g0 == *"trg_events_sync_stamp"* && $s_g0 == *"stampfn=1"* ]] && echo 1 || echo 0)" \
  "a rerun of 015 inside the rollback window (a deploy) is refused by its guard and changes nothing: the triggers, the seq default, paused/rollback and the stamp function stay as the rollback left them" \
  "exit=$rs: $(echo "$out" | grep -o '015: server is rolled back[^\"]*' | head -1); before='$s_g0' after='$s_g1'"

f_r0=$(frames)
# a Phase 1 client whose switch is still on (header-bearing) is refused
st_h=$(patch_title "$P" "$p_seq" "P edited by a device during the rollback" -H "X-Sync-Epoch: $e_r0"); cm=$(code_msg)
rec S18 "$([[ $st_h == 400 && $cm == "P0001 sync_paused" && $(row "$P") == "P v1|false|$p_seq" ]] && echo 1 || echo 0)" \
  "during the rollback a header-bearing PATCH (a device whose switch is still on) is refused by the gate with sync_paused and changes nothing" "status=$st_h code/message='$cm' row=$(row "$P")"
# old-build shapes (no header) go through
st_n=$(req POST "/events" "$TOK" "[$(ev "$N" "N inserted during the rollback")]" -H "Prefer: resolution=merge-duplicates")
n_seq=$(seq_of "$N"); n_vid=$(vid "$N")
st_k=$(req POST "/events" "$TOK" "[$(ev "$K" "K upserted during the rollback")]" -H "Prefer: resolution=merge-duplicates")
k_seq2=$(seq_of "$K")
rec S18 "$([[ $st_n == 201 && $n_seq =~ ^[0-9]+$ && $n_seq -gt $cursor_r && $st_k == 2* && $(row "$K") == "K upserted during the rollback|false|$k_seq2" && $k_seq2 -gt $k_seq ]] && echo 1 || echo 0)" \
  "old-build upserts without seq or header succeed during the rollback: a new row takes a seq from the default, an existing row takes a NEW seq from the stamp trigger" \
  "new N: status=$st_n seq=$n_seq (cursor $cursor_r); existing K: status=$st_k seq $k_seq -> $k_seq2"
st_l=$(req POST "/event_types" "$TOK" "[{\"id\":\"$L\",\"user_id\":\"$RUID\",\"title\":\"L inserted during the rollback\",\"color_hex\":\"#336699\"}]" -H "Prefer: resolution=merge-duplicates")
l_seq=$(et_seq "$L"); ev_max=$(sql "select max(seq) from public.events")
rec S18 "$([[ $st_l == 201 && $l_seq =~ ^[0-9]+$ && $ev_max =~ ^[0-9]+$ && $l_seq -gt $ev_max ]] && echo 1 || echo 0)" \
  "an old-build upsert of a new row on another synced table also takes a seq from the default, above every events row" "new L on event_types: status=$st_l seq=$l_seq; max(seq) over events=$ev_max"
lv_p0=$(last_value)
st_p=$(sreq PATCH "/events?id=eq.$P" '{"title":"P edited by the agent during the rollback"}' -H "Prefer: return=representation")
p_seq2=$(seq_of "$P")
rec S18 "$([[ $st_p == 200 && $(jlen) == 1 && $(row "$P") == "P edited by the agent during the rollback|false|$p_seq2" && $p_seq2 -gt $p_seq && $p_seq2 -gt $lv_p0 && $(vid "$P") == "$p_vid" ]] && echo 1 || echo 0)" \
  "a service_role PATCH (no header) succeeds and the row takes a NEW seq from the stamp trigger while keeping its version_id (no log row: the version trigger is gone)" \
  "status=$st_p rows=$(jlen) row=$(row "$P") (seq before $p_seq, counter before $lv_p0) version $p_vid -> $(vid "$P")"
st_d=$(sreq DELETE "/events?id=eq.$D" "")
rec S18 "$([[ $st_d == 204 && $(row "$D") == absent ]] && echo 1 || echo 0)" "a service_role DELETE during the rollback is physical: no tombstone is left" "status=$st_d row=$(row "$D")"
f_r1=$(frames)
pull_from "$cursor_r"
window=$(py 'ids=[r["data"]["id"] for r in d if r["tbl"]=="events"]; print("N" if "'"$N"'" in ids else "-", "K" if "'"$K"'" in ids else "-", "P" if "'"$P"'" in ids else "-")')
rec S18 "$([[ $f_r1 == "$f_r0" && $window == "N K P" ]] && echo 1 || echo 0)" \
  "recorded: nothing rings during the rollback, but a pull from the cursor now sees the new row AND both in-place edits (they took new seqs from the stamp trigger)" \
  "frames $f_r0 -> $f_r1; pull from $cursor_r sees (N, K, P)=($window)"

# re-enable: drop the default and the stamp, rerun 015, the epoch step
win() { sql "select md5(coalesce(string_agg(j, E'\n' order by j), '')) from (select row_to_json(e)::text as j from public.events e where e.id in ($WINDOW) union all select row_to_json(l)::text from public.event_types l where l.id in ($WINDOW)) s"; }
w1=$(win); sq_re0=$(seq_state); log_re0=$(log_rows)
n_logged0=$(sql "select count(*) from public.sync_versions where version_id = '$n_vid'")
"$PSQL" "$DB" --single-transaction -q -v ON_ERROR_STOP=1 -f "$OPS/reenable.sql" >"$TMP/reenable.log" 2>&1; rs=$?
sq_re1=$(seq_state)
fails_re=$(post_apply_fails); "$PSQL" "$DB" -q -v ON_ERROR_STOP=1 -f "$OPS/post_apply_checks.sql" >/dev/null 2>&1; pa=$?
[[ $pa == 0 ]] && ROLLED_BACK=0
c2_out=$(content "$WINDOW"); w2=$(win)
bad0=$(content_bad "$c0_out"); bad2=$(content_bad "$c2_out")
e_r2=$(epoch); l_r2=$(ledger_len); kept_r2=$(ledger_last_kept); de_r2=$(ledger_last_dump); max_r2=$(max_seq_all)
rec S18 "$([[ $rs == 0 && $w1 =~ ^[0-9a-f]{32}$ && $w2 == "$w1" && $(row "$K") == "K upserted during the rollback|false|$k_seq2" && $(row "$P") == "P edited by the agent during the rollback|false|$p_seq2" && $(row "$N") == "N inserted during the rollback|false|$n_seq" && $(et_seq "$L") == "$l_seq" && $(row "$D") == absent ]] && echo 1 || echo 0)" \
  "ops/reenable.sql keeps what the window wrote: K's upsert and P's PATCH with their stamped seq, N and L with their default seq, D still gone" \
  "window rows' md5 before/after: '$w1'/'$w2'; K=$(row "$K") P=$(row "$P") N=$(row "$N") L seq=$(et_seq "$L") D=$(row "$D")"
rec S18 "$([[ $rs == 0 && $pa == 0 && -z $fails_re && $bad0 == none && $bad2 == none && $c2_out == "$c0_out" ]] && echo 1 || echo 0)" \
  "ops/reenable.sql exits 0, keeps the full content of every row outside the window (tombstones included), and post_apply_checks.sql is green again (P1, P8, P10, P12 included)" \
  "exit=$rs $(grep -v '^$' "$TMP/reenable.log" | tail -1 | head -c 200) post-apply exit=$pa failures='$fails_re'; tables without an md5 before/after: $bad0/$bad2; tables whose content outside the window changed: $(content_diff "$c0_out" "$c2_out"); rows=$(synced_rows) (before the window $rows0, +N +L -D)"
rec S18 "$([[ $n_logged0 == 0 && $(sql "select count(*) || ' ' || coalesce(max(parent_version_id::text), 'null') from public.sync_versions where version_id = '$n_vid'") == "1 null" && $(log_rows) -gt $log_re0 ]] && echo 1 || echo 0)" \
  "the rerun of 015 inside reenable.sql backfills the log for the row inserted in the window (its default version_id had no log row): one entry, parent null" \
  "N's version $n_vid logged before/after: $n_logged0/$(sql "select count(*) from public.sync_versions where version_id = '$n_vid'"); log rows $log_re0 -> $(log_rows)"
rec S18 "$([[ -n $sq_re0 && $sq_re1 == "$sq_re0" ]] && echo 1 || echo 0)" \
  "ops/reenable.sql, its rerun of 015 and the epoch step included, leaves sync_seq where it was (a rollback never rewinds, so nothing is lifted)" \
  "sync_seq '$sq_re0' -> '$sq_re1'; max(seq) over the synced tables=$max_r2 (L=$l_seq)"
rec S18 "$([[ $e_r2 != "$e_r0" && $l_r2 == $((l_r0 + 1)) && $kept_r2 == "$max_r2" && $de_r2 == null && $(paused) == "true false" ]] && echo 1 || echo 0)" \
  "the epoch step inside reenable.sql is the reset: a new epoch, ledger +1 with kept_max = max(seq) over the nine tables and dump_epoch null, rollback false, paused still true" \
  "epoch '$e_r0' -> '$e_r2' ledger $l_r0 -> $l_r2 last=$(ledger_last) max(seq)=$max_r2 paused/rollback='$(paused)'"
st=$(patch_title "$P" "$p_seq2" "P edited while still paused" -H "X-Sync-Epoch: $e_r2"); cm=$(code_msg)
rec S18 "$([[ $st == 400 && $cm == "P0001 sync_paused" ]] && echo 1 || echo 0)" "after the re-enable and before the operator clears paused, a device write with the new epoch is still refused (sync_paused)" "status=$st code/message='$cm'"
unpause
st=$(req POST /rpc/is_ancestor "$TOK" "{\"p_tbl\":\"events\",\"p_id\":\"$P\",\"a\":\"$p_vid\",\"b\":\"$(vid "$P")\"}"); anc=$(body)
rec S18 "$([[ $st == 200 && $anc == true ]] && echo 1 || echo 0)" \
  "a clean device's copy of P is the current version's ancestor (the agent's window edit kept the version_id, so the log answers true: adopt, no prompt)" "is_ancestor(device copy, current)=$anc (version $p_vid, current $(vid "$P"))"

# the triggers are live again: the device's POST of D (its baseline never saw
# D at head) brings it back with its parent, a new seq above kept_max and a
# doorbell; a DELETE tombstones
f_r2=$(frames)
st_b=$(req POST "/events" "$TOK" "[$(ev "$D" "D v1" | sed "s/}$/,\"parent_version_id\":\"$d_vid\"}/")]" -H "Prefer: resolution=ignore-duplicates, return=representation" -H "$(hdr)")
n_b=$(jlen); d_back=$(seq_of "$D"); d_parent=$(py 'print(d[0].get("parent_version_id") if isinstance(d,list) and d else d)')
st_x=$(req DELETE "/events?id=eq.$N" "$TOK" "" -H "$(hdr)")
rec S18 "$([[ $st_b == 201 && $n_b == 1 && $d_back -gt $kept_r2 && $d_parent == "$d_vid" && $(frames) -gt $f_r2 && $st_x == 204 && $(row "$N") == "N inserted during the rollback|true|"* ]] && echo 1 || echo 0)" \
  "after the re-enable the physically deleted row is POSTed back with parent = the device's version, above kept_max, and rings; a DELETE is a tombstone again" \
  "POST D: status=$st_b rows=$n_b seq=$d_back kept_max=$kept_r2 parent=$d_parent (device's $d_vid); frames $f_r2 -> $(frames); DELETE N: status=$st_x row=$(row "$N")"

# ------------------------------------------------------------
# S17n  a manual restore into a "new project" without the two cross-restore
#       tables (design §9.37 (1)), emulated: the log emptied, a fresh epoch
#       row with an empty ledger, then the documented restore of a dump that
#       lacks sync_epoch and sync_versions
# ------------------------------------------------------------
dump "$TMP/dump3.sql"
awk '/^COPY public\.sync_epoch \(/{skip=1; next} /^COPY public\.sync_versions \(/{skip=1; next} skip && /^\\\.$/{skip=0; next} !skip{print}' "$TMP/dump3.sql" > "$TMP/dump3_bare.sql"
"$PSQL" "$DB" --single-transaction -q -v ON_ERROR_STOP=1 \
  -c "set session_replication_role = replica" \
  -c "truncate public.sync_versions" \
  -c "update public.sync_epoch set epoch = gen_random_uuid()::text, paused = false, rollback = false, restores = '[]', changed_at = now()" >/dev/null 2>&1
e_n0=$(epoch)
restore_forgot "$TMP/dump3_bare.sql" "$SYNCED_SQL"; rs=$?
fails_n=$(post_apply_fails)
rec S17 "$([[ $rs == 0 && $(epoch) == "$e_n0" && $(ledger_len) == 0 && $(log_rows) == 0 && $fails_n == "P10,P12" ]] && echo 1 || echo 0)" \
  "residual §9.37 (1), recorded: a restore into a new project without sync_epoch and sync_versions leaves an empty ledger and an empty log; post-apply fails exactly P10 and P12 — the only sign that the evidence is gone" \
  "restore exit=$rs epoch=$(epoch) ledger_len=$(ledger_len) log rows=$(log_rows) post-apply failures='$fails_n'"
# the repair the README prescribes afterwards: the epoch step (P10 green), then
# a rerun of 015 (P12 green through the backfill, ancestry gone)
sql "update public.sync_epoch set paused = true" >/dev/null
"$PSQL" "$DB" --single-transaction -q -v ON_ERROR_STOP=1 -f "$OPS/restore_with_epoch.sql" >/dev/null 2>&1; rs1=$?
fails_n1=$(post_apply_fails)
"$PSQL" "$DB" -q -v ON_ERROR_STOP=1 -f "$MIGRATION" >/dev/null 2>&1; rs2=$?
fails_n2=$(post_apply_fails)
parents=$(sql "select count(*) filter (where parent_version_id is not null) || '/' || count(*) from public.sync_versions")
rec S17 "$([[ $rs1 == 0 && $fails_n1 == "P12" && $rs2 == 0 && -z $fails_n2 && $parents == 0/* ]] && echo 1 || echo 0)" \
  "after the repair: the epoch step turns P10 green (ledger of one record, kept_max from the restored rows), the rerun of 015 turns P12 green by backfilling every row's version with parent null — the ancestry is gone, devices fall back to the ledger" \
  "step exit=$rs1 failures='$fails_n1'; 015 exit=$rs2 failures='$fails_n2'; log rows with a parent / total = $parents; ledger=$(ledger_last)"
unpause

# a restore into a project whose counter is fresh (a new project's sync_seq
# starts at 1; restore.sh drops the dump's setval): the epoch step must lift
# the counter to kept_max, or every number up to kept_max would be handed
# out again. Emulated by putting the counter back to 1 before restore.sh.
max_n3=$(max_seq_all); l_n3=$(ledger_len)
sql "select setval('public.sync_seq', 1, false)" >/dev/null
"$OPS/restore.sh" --target "$DB" --data "$TMP/dump3.sql" --replace >"$TMP/restore_n3.log" 2>&1; rs=$?
read -r lv_n3 called_n3 <<<"$(seq_state)"
rec S17 "$([[ $rs == 0 && $(ledger_len) == $((l_n3 + 1)) && $(ledger_last_kept) == "$max_n3" && $lv_n3 == "$max_n3" && $called_n3 == true && -z $(post_apply_fails) ]] && echo 1 || echo 0)" \
  "restore.sh into a fresh counter (set to 1 beforehand, as in a new project) lifts sync_seq to kept_max in the epoch step, ledger +1, and the post-apply checks (P9 included) are green" \
  "restore.sh exit=$rs; counter before=(1, false) after=($lv_n3, $called_n3); kept_max=$(ledger_last_kept) max(seq)=$max_n3; ledger $l_n3 -> $(ledger_len); post-apply failures='$(post_apply_fails)'"
unpause

echo
if [[ $fails -gt 0 ]]; then echo "FAILED checks: $fails"; exit 1; fi
echo "all restore drill checks passed"
