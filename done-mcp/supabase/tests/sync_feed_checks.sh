#!/usr/bin/env bash
# Bench for migration 015 (sync change feed) — HTTP side: GoTrue signup,
# PostgREST request shapes (the current client's and the design's), the
# sync_changes RPC, and the Realtime doorbell over a raw websocket (node).
# Run against a local `supabase start` stack; see README.md.
# Prints PASS/FAIL per check and exits non-zero when any check failed.
set -u

REST=${SUPABASE_REST:-http://127.0.0.1:54321/rest/v1}
AUTH=${SUPABASE_AUTH:-http://127.0.0.1:54321/auth/v1}
WS=${SUPABASE_WS:-ws://127.0.0.1:54321/realtime/v1/websocket}
PUB=${SUPABASE_PUBLISHABLE_KEY:-sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH}
DB=${SUPABASE_DB:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}
PSQL=${PSQL:-$(command -v psql || echo /opt/homebrew/opt/libpq/bin/psql)}
EMAIL_A=${BENCH_EMAIL_A:-bench-a@local.test}
EMAIL_B=${BENCH_EMAIL_B:-bench-b@local.test}
PASSWORD=bench-password

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fails=0

rec() { # id, pass(0/1), claim, observed
  local verdict=FAIL
  if [[ $2 == 1 ]]; then verdict=PASS; else fails=$((fails + 1)); fi
  printf '%s %-4s %s\n      %s\n' "$verdict" "$1" "$3" "$4"
}
sql() { "$PSQL" "$DB" -At -c "$1"; }
# req METHOD PATH TOKEN [DATA] [extra curl args...]  -> prints status; body in $TMP/body
req() {
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
msgs() { sql "select count(*) from realtime.messages where topic = 'user:$1'"; }
uuid() { python3 -c 'import uuid; print(uuid.uuid4())'; }
now_iso() { python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3]+"Z")'; }

# ------------------------------------------------------------
# signup (or sign in when the user is left over from an earlier run)
# ------------------------------------------------------------
login() {
  local email=$1
  curl -s -o "$TMP/body" -X POST "$AUTH/signup" -H "apikey: $PUB" -H "Content-Type: application/json" \
    -d "{\"email\":\"$email\",\"password\":\"$PASSWORD\"}" >/dev/null
  local tok; tok=$(py 'print((d or {}).get("access_token",""))')
  if [[ -z $tok ]]; then
    curl -s -o "$TMP/body" -X POST "$AUTH/token?grant_type=password" -H "apikey: $PUB" -H "Content-Type: application/json" \
      -d "{\"email\":\"$email\",\"password\":\"$PASSWORD\"}" >/dev/null
    tok=$(py 'print((d or {}).get("access_token",""))')
  fi
  [[ -n $tok ]] || { echo "signup/login failed for $email: $(body)"; exit 2; }
  echo "$tok $(py 'print(d["user"]["id"])')"
}
read -r TOK_A UID_A <<<"$(login "$EMAIL_A")"
read -r TOK_B UID_B <<<"$(login "$EMAIL_B")"
echo "users: A=$UID_A B=$UID_B"
cleanup_users() {
  sql "drop function if exists public.bench_max_rows_probe(int)" >/dev/null 2>&1 || true
  sql "delete from auth.users where email in ('$EMAIL_A', '$EMAIL_B')" >/dev/null
  sql "delete from realtime.messages where topic in ('user:$UID_A', 'user:$UID_B')" >/dev/null 2>&1 || true
}
trap 'cleanup_users; rm -rf "$TMP"' EXIT

ev() { # id user title [extra json fields]
  printf '{"id":"%s","user_id":"%s","kind":"todo","title":"%s"%s}' "$1" "$2" "$3" "${4:-}"
}
seq_of() { sql "select seq from public.$1 where $2 = '$3'"; }
last_value() { sql "select last_value from public.sync_seq"; }
vid_of() { sql "select version_id from public.$1 where $2 = '$3'"; }
code_msg() { py 'print("%s %s" % (d.get("code",""), d.get("message","")) if isinstance(d,dict) else "")'; }
# the stack's secret key (service_role; an edge function or MCP): set
# SUPABASE_SECRET_KEY, or have the supabase CLI on PATH. The CLI reads
# SUPABASE_* variables as config overrides, so it runs without them.
SECRET=${SUPABASE_SECRET_KEY:-$(cd "$(dirname "$0")/../.." && env $(env | sed -n 's/^\(SUPABASE_[A-Za-z0-9_]*\)=.*/-u \1/p') supabase status -o env 2>/dev/null \
  | sed -n -e 's/^SECRET_KEY="\(.*\)"$/\1/p' -e 's/^SERVICE_ROLE_KEY="\(.*\)"$/\1/p' | head -1)}
sreq() { # METHOD PATH [DATA] [extra curl args...] as service_role -> status; body in $TMP/body
  local m=$1 path=$2 data=${3:-}; shift 3 || shift $#
  local -a args=(-s -o "$TMP/body" -w '%{http_code}' -X "$m" "$REST$path" -H "apikey: $SECRET" -H "Content-Type: application/json")
  [[ -n $data ]] && args+=(--data-binary "$data")
  curl "${args[@]}" "$@"
}

# ------------------------------------------------------------
# v6 checks (design v1.6): S19 the write gate through PostgREST, S25 the
# client-visible shapes of the epoch row, the version columns and
# is_ancestor. Run on their own with BENCH_ONLY=v6 (the negative-control
# loop in sync_v6_controls.sh reruns them per mutation).
# ------------------------------------------------------------
v6_checks() {
  local EPOCH HDR G st cm lv0 lv1 m0 m1 n0 n1 base rows live tomb vid0 vid1 r parent sent_vid sent_parent got_vid got_parent rf feed keys a b
  sql "update public.sync_epoch set paused = false, rollback = false" >/dev/null
  EPOCH=$(sql "select epoch from public.sync_epoch")
  HDR="X-Sync-Epoch: $EPOCH"

  # ---- S19 the write gate
  G=$(uuid)
  lv0=$(last_value); m0=$(msgs "$UID_A"); n0=$(sql "select count(*) from public.sync_versions")
  st=$(req POST /events "$TOK_A" "[$(ev "$G" "$UID_A" "S19 stale POST")]" -H "Prefer: resolution=merge-duplicates" -H "X-Sync-Epoch: not-the-epoch")
  cm=$(code_msg)
  lv1=$(last_value); m1=$(msgs "$UID_A"); n1=$(sql "select count(*) from public.sync_versions")
  rows=$(sql "select count(*) from public.events where id = '$G'")
  rec S19 "$([[ $st == 400 && $cm == "P0001 sync_epoch_stale" && $rows == 0 && $lv1 == "$lv0" && $m1 == "$m0" && $n1 == "$n0" ]] && echo 1 || echo 0)" \
    "POST (merge-duplicates) with a stale X-Sync-Epoch header -> 400, message sync_epoch_stale; no row, no seq taken, no doorbell, no log row" \
    "status=$st code/message='$cm' rows=$rows sync_seq $lv0 -> $lv1 frames $m0 -> $m1 log rows $n0 -> $n1"
  st=$(req POST /events "$TOK_A" "[$(ev "$G" "$UID_A" "S19 ok POST")]" -H "Prefer: resolution=merge-duplicates" -H "$HDR")
  rows=$(sql "select count(*) from public.events where id = '$G'"); base=$(seq_of events id "$G")
  rec S19 "$([[ $st == 201 && $rows == 1 ]] && echo 1 || echo 0)" "POST with the current epoch in the header -> 201 and the row lands" "status=$st rows=$rows seq=$base"
  lv0=$(last_value)
  st=$(req PATCH "/events?id=eq.$G&seq=eq.$base" "$TOK_A" '{"title":"S19 stale PATCH"}' -H "Prefer: return=representation" -H "X-Sync-Epoch: not-the-epoch")
  cm=$(code_msg); lv1=$(last_value)
  rec S19 "$([[ $st == 400 && $cm == "P0001 sync_epoch_stale" && $(sql "select title || ' ' || seq from public.events where id = '$G'") == "S19 ok POST $base" && $lv1 == "$lv0" ]] && echo 1 || echo 0)" \
    "conditional PATCH with a stale header -> 400 sync_epoch_stale; title and seq unchanged, no seq taken" "status=$st code/message='$cm' row=$(sql "select title || '|' || seq from public.events where id = '$G'") sync_seq $lv0 -> $lv1"
  st=$(req PATCH "/events?id=in.($G)&deleted_at=is.null" "$TOK_A" "{\"deleted_at\":\"$(now_iso)\"}" -H "Prefer: return=representation" -H "X-Sync-Epoch: not-the-epoch")
  cm=$(code_msg); live=$(sql "select deleted_at is null from public.events where id = '$G'")
  rec S19 "$([[ $st == 400 && $cm == "P0001 sync_epoch_stale" && $live == t ]] && echo 1 || echo 0)" "tombstone PATCH with a stale header -> 400 sync_epoch_stale; the row stays live" "status=$st code/message='$cm' live=$live"
  st=$(req DELETE "/events?id=in.($G)" "$TOK_A" "" -H "X-Sync-Epoch: not-the-epoch")
  cm=$(code_msg); live=$(sql "select deleted_at is null from public.events where id = '$G'")
  rec S19 "$([[ $st == 400 && $cm == "P0001 sync_epoch_stale" && $live == t ]] && echo 1 || echo 0)" "old-build DELETE with a stale header -> 400 sync_epoch_stale (the rewrite's UPDATE meets the gate); the row stays live" "status=$st code/message='$cm' live=$live"
  st=$(req PATCH "/events?id=eq.$G&seq=eq.$base" "$TOK_A" '{"title":"S19 ok PATCH"}' -H "Prefer: return=representation" -H "$HDR")
  rec S19 "$([[ $st == 200 && $(jlen) == 1 ]] && echo 1 || echo 0)" "conditional PATCH with the current header -> 200 [row]" "status=$st rows=$(jlen)"
  base=$(seq_of events id "$G")
  st=$(req PATCH "/events?id=in.($G)&deleted_at=is.null" "$TOK_A" "{\"deleted_at\":\"$(now_iso)\"}" -H "Prefer: return=representation" -H "$HDR")
  tomb=$(sql "select deleted_at is not null from public.events where id = '$G'")
  rec S19 "$([[ $st == 200 && $(jlen) == 1 && $tomb == t ]] && echo 1 || echo 0)" "tombstone PATCH with the current header -> 200 [row], tombstoned" "status=$st rows=$(jlen) tombstoned=$tomb"

  # paused / rollback
  P=$(uuid)
  req POST /events "$TOK_A" "[$(ev "$P" "$UID_A" "S19 P v1")]" -H "Prefer: resolution=merge-duplicates" -H "$HDR" >/dev/null
  base=$(seq_of events id "$P")
  sql "update public.sync_epoch set paused = true, rollback = false" >/dev/null
  st=$(req PATCH "/events?id=eq.$P&seq=eq.$base" "$TOK_A" '{"title":"S19 paused header"}' -H "Prefer: return=representation" -H "$HDR"); cm=$(code_msg)
  rec S19 "$([[ $st == 400 && $cm == "P0001 sync_paused" && $(seq_of events id "$P") == "$base" ]] && echo 1 || echo 0)" "paused: a header-bearing PATCH -> 400 sync_paused, row unchanged" "status=$st code/message='$cm' seq=$(seq_of events id "$P") (base $base)"
  st=$(req PATCH "/events?id=eq.$P&seq=eq.$base" "$TOK_A" '{"title":"S19 paused no header"}' -H "Prefer: return=representation"); cm=$(code_msg)
  rec S19 "$([[ $st == 400 && $cm == "P0001 sync_paused" ]] && echo 1 || echo 0)" "paused: a header-less user PATCH (old build) -> 400 sync_paused" "status=$st code/message='$cm'"
  if [[ -n $SECRET ]]; then
    st=$(sreq PATCH "/events?id=eq.$P" '{"title":"S19 paused service_role"}' -H "Prefer: return=representation"); cm=$(code_msg)
    rec S19 "$([[ $st == 400 && $cm == "P0001 sync_paused" && $(seq_of events id "$P") == "$base" ]] && echo 1 || echo 0)" "paused, no rollback: a service_role PATCH (no header) -> 400 sync_paused" "status=$st code/message='$cm'"
    sql "update public.sync_epoch set paused = true, rollback = true" >/dev/null
    lv0=$(last_value)
    st=$(sreq PATCH "/events?id=eq.$P" '{"title":"S19 rollback service_role"}' -H "Prefer: return=representation")
    r=$(py 'print(d[0]["seq"] if isinstance(d,list) and d else "")')
    rec S19 "$([[ $st == 200 && $(jlen) == 1 && $r =~ ^[0-9]+$ && $r -gt $base && $r -gt $lv0 ]] && echo 1 || echo 0)" "paused with rollback set: a service_role PATCH lands and takes a new seq" "status=$st rows=$(jlen) seq $base -> $r (counter before $lv0)"
    st=$(req PATCH "/events?id=eq.$P" "$TOK_A" '{"title":"S19 rollback header"}' -H "Prefer: return=representation" -H "$HDR"); cm=$(code_msg)
    rec S19 "$([[ $st == 400 && $cm == "P0001 sync_paused" ]] && echo 1 || echo 0)" "paused with rollback set: a header-bearing PATCH is still 400 sync_paused" "status=$st code/message='$cm'"
  else
    rec S19 0 "the stack's secret key is available for the service_role gate checks (INVALID: not run)" "set SUPABASE_SECRET_KEY or put the supabase CLI on PATH"
  fi
  sql "update public.sync_epoch set paused = false, rollback = false" >/dev/null

  # ---- S25 client-visible v6 shapes
  st=$(req GET "/sync_epoch?select=epoch,paused,restores" "$TOK_A" "")
  keys=$(py 'print(len(d), sorted(d[0].keys()), isinstance(d[0].get("restores"), list), d[0].get("paused")) if isinstance(d,list) and d else print(d)')
  rec S25 "$([[ $st == 200 && $keys == "1 ['epoch', 'paused', 'restores'] True False" ]] && echo 1 || echo 0)" "GET /sync_epoch?select=epoch,paused,restores with a user JWT -> 200, exactly one row, restores is an array, paused false" "status=$st (rows, keys, restores is list, paused)=$keys"
  st=$(req GET "/sync_epoch?select=epoch,floor" "$TOK_A" ""); cm=$(code_msg)
  rec S25 "$([[ $st == 400 && $cm == 42703* ]] && echo 1 || echo 0)" "GET /sync_epoch?select=epoch,floor (the v5 column) -> 400 42703: floor is gone" "status=$st code/message='$cm'"
  st=$(req GET "/sync_epoch?select=epoch,paused,restores" "" "")
  rec S25 "$([[ ($st == 401 || $st == 403) || ($st == 200 && $(jlen) == 0) ]] && echo 1 || echo 0)" "anon (apikey only) cannot read the epoch" "status=$st body=$(body | head -c 120)"

  V=$(uuid); sent_vid=$(uuid); sent_parent=$(uuid)
  st=$(req POST /events "$TOK_A" "[$(ev "$V" "$UID_A" "S25 v1" ",\"version_id\":\"$sent_vid\",\"parent_version_id\":\"$sent_parent\"")]" -H "Prefer: resolution=ignore-duplicates, return=representation" -H "$HDR")
  got_vid=$(py 'print(d[0].get("version_id") if isinstance(d,list) and d else d)'); got_parent=$(py 'print(d[0].get("parent_version_id") if isinstance(d,list) and d else d)')
  vid0=$(vid_of events id "$V")
  rec S25 "$([[ $st == 201 && $got_vid != "$sent_vid" && $got_vid == "$vid0" && $got_parent == "$sent_parent" ]] && echo 1 || echo 0)" \
    "ignore-duplicates POST (a re-upload) with version_id and parent_version_id in the body: the version_id is replaced, the parent is kept, the response shows both" \
    "status=$st sent version_id=$sent_vid -> $got_vid (row $vid0); sent parent=$sent_parent -> $got_parent"
  base=$(seq_of events id "$V")
  st=$(req PATCH "/events?id=eq.$V&seq=eq.$base" "$TOK_A" "{\"title\":\"S25 v2\",\"version_id\":\"$sent_vid\",\"parent_version_id\":\"$sent_parent\"}" -H "Prefer: return=representation" -H "$HDR")
  got_vid=$(py 'print(d[0].get("version_id") if isinstance(d,list) and d else d)'); got_parent=$(py 'print(d[0].get("parent_version_id") if isinstance(d,list) and d else d)')
  vid1=$(vid_of events id "$V")
  rec S25 "$([[ $st == 200 && $got_vid != "$sent_vid" && $got_vid == "$vid1" && $got_vid != "$vid0" && $got_parent == "$vid0" ]] && echo 1 || echo 0)" \
    "conditional PATCH with version_id and parent_version_id in the body: both ignored — the response carries the new version_id and parent = the version written over" \
    "status=$st version $vid0 -> $got_vid (sent $sent_vid); parent -> $got_parent (sent $sent_parent)"
  base=$(seq_of events id "$V")
  st=$(req PATCH "/events?id=eq.$V&seq=eq.$base" "$TOK_A" "{\"title\":\"S25 v3 written back\",\"restored_from_version_id\":\"$vid0\"}" -H "Prefer: return=representation" -H "$HDR")
  rf=$(py 'print(d[0].get("restored_from_version_id") if isinstance(d,list) and d else d)'); got_vid=$(py 'print(d[0].get("version_id") if isinstance(d,list) and d else d)')
  r=$(sql "select coalesce(restored_from_version_id::text, 'null') || ' ' || coalesce(parent_version_id::text, 'null') from public.sync_versions where version_id = '$got_vid'")
  rec S25 "$([[ $st == 200 && $rf == None && $r == "$vid0 $vid1" && $(sql "select restored_from_version_id is null from public.events where id = '$V'") == t ]] && echo 1 || echo 0)" \
    "a write-back PATCH with restored_from_version_id: the response and the stored row carry null, the log row carries it with parent = the version written over" \
    "status=$st response restored_from=$rf; log (restored_from parent)='$r' (want '$vid0 $vid1')"
  a=$vid0; b=$(vid_of events id "$V")
  st=$(req POST /rpc/is_ancestor "$TOK_A" "{\"p_tbl\":\"events\",\"p_id\":\"$V\",\"a\":\"$a\",\"b\":\"$b\"}"); r=$(body)
  st2=$(req POST /rpc/is_ancestor "$TOK_A" "{\"p_tbl\":\"events\",\"p_id\":\"$V\",\"a\":\"$b\",\"b\":\"$a\"}"); r2=$(body)
  st3=$(req POST /rpc/is_ancestor "$TOK_A" "{\"p_tbl\":\"events\",\"p_id\":\"$V\",\"a\":\"$(uuid)\",\"b\":\"$b\"}"); r3=$(body)
  rec S25 "$([[ $st == 200 && $r == true && $st2 == 200 && $r2 == false && $st3 == 200 && $r3 == null ]] && echo 1 || echo 0)" \
    "POST /rpc/is_ancestor with a user JWT: (v1, v3) -> true, (v3, v1) -> false, (unknown, v3) -> null, each 200" "($st $r) ($st2 $r2) ($st3 $r3)"
  st=$(req POST /rpc/is_ancestor "" "{\"p_tbl\":\"events\",\"p_id\":\"$V\",\"a\":\"$a\",\"b\":\"$b\"}"); cm=$(code_msg)
  rec S25 "$([[ ($st == 401 || $st == 403) && $cm == 42501* ]] && echo 1 || echo 0)" "POST /rpc/is_ancestor with the apikey alone (anon) is refused with 42501" "status=$st code/message='$cm'"
  st=$(req POST /rpc/sync_versions_prune "$TOK_A" '{"p_days":0}'); cm=$(code_msg)
  st2=$(req POST /rpc/sync_versions_prune "" '{"p_days":0}'); cm2=$(code_msg)
  rec S25 "$([[ ($st == 401 || $st == 403) && $cm == 42501* && ($st2 == 401 || $st2 == 403) && $cm2 == 42501* ]] && echo 1 || echo 0)" "POST /rpc/sync_versions_prune with a user JWT and with the apikey alone are both refused with 42501 (only service_role / postgres may prune)" "user: status=$st code/message='$cm'; anon: status=$st2 code/message='$cm2'"
  st=$(req POST /rpc/sync_changes "$TOK_A" "{\"since_seq\":$((base - 1)),\"page_limit\":1000}")
  feed=$(py 'r=[x for x in d if x["tbl"]=="events" and x["data"]["id"]=="'"$V"'"]; print(len(r), sorted(k for k in r[0]["data"].keys() if k in ("version_id","parent_version_id","restored_from_version_id","seq","deleted_at")), r[0]["data"]["version_id"]==r[0]["data"].get("version_id") and r[0]["data"]["parent_version_id"]=="'"$vid1"'", r[0]["data"]["restored_from_version_id"]) if isinstance(d,list) else print(d)')
  rec S25 "$([[ $st == 200 && $feed == "1 ['deleted_at', 'parent_version_id', 'restored_from_version_id', 'seq', 'version_id'] True None" ]] && echo 1 || echo 0)" \
    "sync_changes data carries version_id, parent_version_id (= the version written over) and a null restored_from_version_id" "status=$st (rows, version keys, parent ok, restored_from)=$feed"
}
if [[ ${BENCH_ONLY:-} == v6 ]]; then
  v6_checks
  echo
  if [[ $fails -gt 0 ]]; then echo "FAILED checks: $fails"; exit 1; fi
  echo "all HTTP checks passed"
  exit 0
fi

# ------------------------------------------------------------
# S2  DELETE through PostgREST becomes a tombstone
# ------------------------------------------------------------
X=$(uuid)
st=$(req POST /events "$TOK_A" "[$(ev "$X" "$UID_A" "S2")]" -H "Prefer: resolution=merge-duplicates")
seq0=$(seq_of events id "$X")
st=$(req DELETE "/events?id=in.($X)" "$TOK_A" "")
read -r n tomb seq1 <<<"$(sql "select count(*) || ' ' || bool_and(deleted_at is not null) || ' ' || max(seq) from public.events where id = '$X'")"
rec S2 "$([[ $st == 204 && $n == 1 && $tomb == true && $seq1 -gt $seq0 ]] && echo 1 || echo 0)" \
  "events: PostgREST DELETE as the user returns 204 and leaves a tombstone with a new seq" \
  "status=$st rows=$n deleted_at set=$tomb seq $seq0 -> $seq1"
X2=$(uuid)
req POST /events "$TOK_A" "[$(ev "$X2" "$UID_A" "S2 representation")]" -H "Prefer: resolution=merge-duplicates" >/dev/null
st=$(req DELETE "/events?id=in.($X2)" "$TOK_A" "" -H "Prefer: return=representation")
tomb2=$(sql "select deleted_at is not null from public.events where id = '$X2'")
rec S2 "$([[ $st == 200 && $tomb2 == t ]] && echo 1 || echo 0)" "events: DELETE with return=representation on a live row (recorded: the rewritten delete reports no deleted rows)" "status=$st body=$(body) tombstoned=$tomb2"
feed=$(sql "set role authenticated; set request.jwt.claims = '{\"sub\":\"$UID_A\",\"role\":\"authenticated\"}'; select count(*) from public.sync_changes($((seq1 - 1)), 10) where tbl = 'events' and data->>'id' = '$X' and data->>'deleted_at' is not null" | tail -1)
rec S2 "$([[ $feed == 1 ]] && echo 1 || echo 0)" "events: the tombstone is in sync_changes with deleted_at set" "feed rows=$feed"

st=$(req POST /user_settings "$TOK_A" "{\"user_id\":\"$UID_A\",\"settings\":{\"k\":1}}" -H "Prefer: resolution=merge-duplicates")
useq0=$(seq_of user_settings user_id "$UID_A")
st=$(req DELETE "/user_settings?user_id=eq.$UID_A" "$TOK_A" "")
read -r n tomb useq1 <<<"$(sql "select count(*) || ' ' || bool_and(deleted_at is not null) || ' ' || max(seq) from public.user_settings where user_id = '$UID_A'")"
rec S2 "$([[ $st == 204 && $n == 1 && $tomb == true && $useq1 -gt $useq0 ]] && echo 1 || echo 0)" \
  "user_settings: PostgREST DELETE by user_id returns 204 and leaves a tombstone" "status=$st rows=$n deleted_at set=$tomb seq $useq0 -> $useq1"

# ------------------------------------------------------------
# S3  tombstone survives the current client's upsert shape
# ------------------------------------------------------------
del0=$(sql "select deleted_at from public.events where id = '$X'")
st=$(req POST /events "$TOK_A" "[$(ev "$X" "$UID_A" "S3 omitted")]" -H "Prefer: resolution=merge-duplicates")
del1=$(sql "select deleted_at from public.events where id = '$X'")
rec S3 "$([[ ($st == 200 || $st == 201) && $del1 == "$del0" ]] && echo 1 || echo 0)" "merge-duplicates upsert that omits deleted_at keeps the tombstone (status recorded)" "status=$st deleted_at '$del0' -> '$del1'"
st=$(req POST /events "$TOK_A" "[$(ev "$X" "$UID_A" "S3 explicit null" ',"deleted_at":null')]" -H "Prefer: resolution=merge-duplicates")
del2=$(sql "select deleted_at || ' ' || title from public.events where id = '$X'")
rec S3 "$([[ ($st == 200 || $st == 201) && $del2 == "$del0 S3 explicit null" ]] && echo 1 || echo 0)" "merge-duplicates upsert with deleted_at: null keeps the tombstone (other columns still update)" "status=$st row='$del2'"

# ------------------------------------------------------------
# S4  content-identical upsert through PostgREST is a no-op
# ------------------------------------------------------------
S4=$(uuid)
st=$(req POST /events "$TOK_A" "[$(ev "$S4" "$UID_A" "S4" ',"note":"same"')]" -H "Prefer: resolution=merge-duplicates")
s4a=$(seq_of events id "$S4"); m0=$(msgs "$UID_A")
st=$(req POST /events "$TOK_A" "[$(ev "$S4" "$UID_A" "S4" ",\"note\":\"same\",\"updated_at\":\"$(now_iso)\"")]" -H "Prefer: resolution=merge-duplicates")
s4b=$(seq_of events id "$S4"); m1=$(msgs "$UID_A")
rec S4 "$([[ ($st == 200 || $st == 201) && $s4a == "$s4b" && $m0 == "$m1" ]] && echo 1 || echo 0)" "identical merge-duplicates upsert: still 2xx (status recorded), seq unchanged, no doorbell" "status=$st seq $s4a -> $s4b, frames $m0 -> $m1"

# ------------------------------------------------------------
# S5  one doorbell frame per statement
# ------------------------------------------------------------
rows=""; ids=()
for i in $(seq 1 20); do id=$(uuid); ids+=("$id"); rows+="$(ev "$id" "$UID_A" "S5 batch $i"),"; done
m0=$(msgs "$UID_A")
st=$(req POST /events "$TOK_A" "[${rows%,}]" -H "Prefer: resolution=merge-duplicates")
m1=$(msgs "$UID_A")
mx=$(sql "select max(seq) from public.events where user_id = '$UID_A' and title like 'S5 batch %'")
frame=$(sql "select payload->>'table' || ' ' || (payload->>'seq') from realtime.messages where topic = 'user:$UID_A' order by inserted_at desc, id limit 1")
rec S5 "$([[ $st == 201 && $((m1 - m0)) == 1 && $frame == "events $mx" ]] && echo 1 || echo 0)" "one POST of many rows rings once, payload {table, seq = max seq of those rows}" "status=$st frames=$((m1 - m0)) last frame='$frame' max(seq)=$mx"
m0=$(msgs "$UID_A")
for i in $(seq 1 20); do req POST /events "$TOK_A" "[$(ev "$(uuid)" "$UID_A" "S5 single $i")]" -H "Prefer: resolution=merge-duplicates" >/dev/null; done
m1=$(msgs "$UID_A")
rec S5 "$([[ $((m1 - m0)) == 20 ]] && echo 1 || echo 0)" "twenty single-row POSTs ring twenty times" "frames=$((m1 - m0))"
m0=$(msgs "$UID_A")
five=$(IFS=,; echo "${ids[*]:0:5}")
st=$(req DELETE "/events?id=in.($five)" "$TOK_A" "")
m1=$(msgs "$UID_A")
rec S5 "$([[ $st == 204 && $((m1 - m0)) == 5 ]] && echo 1 || echo 0)" "old-build DELETE ?id=in.(five ids) rings once per row (§9.15)" "status=$st frames=$((m1 - m0))"

# ------------------------------------------------------------
# S7  conditional PATCH (design I8)
# ------------------------------------------------------------
P=$(uuid)
req POST /events "$TOK_A" "[$(ev "$P" "$UID_A" "S7 v1")]" -H "Prefer: resolution=merge-duplicates" >/dev/null
base=$(seq_of events id "$P")
st=$(req PATCH "/events?id=eq.$P&seq=eq.$base" "$TOK_A" '{"title":"S7 v2"}' -H "Prefer: return=representation")
newseq=$(py 'print(d[0]["seq"] if isinstance(d,list) and d else "")')
rec S7 "$([[ $st == 200 && $(jlen) == 1 && $newseq -gt $base ]] && echo 1 || echo 0)" "events: PATCH with the right base and a change -> 200 [row] carrying the new seq" "status=$st rows=$(jlen) seq $base -> $newseq"
st=$(req PATCH "/events?id=eq.$P&seq=eq.$base" "$TOK_A" '{"title":"S7 v3"}' -H "Prefer: return=representation")
rec S7 "$([[ $st == 200 && $(jlen) == 0 ]] && echo 1 || echo 0)" "events: PATCH with a stale base -> 200 []" "status=$st body=$(body)"
st=$(req PATCH "/events?id=eq.$P&seq=eq.$newseq" "$TOK_A" '{"title":"S7 v2"}' -H "Prefer: return=representation")
same=$(seq_of events id "$P")
rec S7 "$([[ $st == 200 && $(jlen) == 0 && $same == "$newseq" ]] && echo 1 || echo 0)" "events: PATCH with the right base but identical content -> 200 [] (trigger short-circuit), seq unchanged" "status=$st body=$(body) seq=$same"
st=$(req PATCH "/events?id=eq.$P&seq=eq.$base" "$TOK_A" '{"title":"S7 v4"}' -H "Prefer: return=representation" -H "Accept: application/vnd.pgrst.object+json")
rec S7 "$([[ $st == 406 ]] && echo 1 || echo 0)" "events: single-object Accept with zero rows -> 406 (design warning confirmed)" "status=$st body=$(body | head -c 160)"
st=$(req PATCH "/events?id=eq.$P&seq=eq.$newseq" "$TOK_A" "{\"title\":\"S7 v5\",\"seq\":$newseq}" -H "Prefer: return=representation")
seq5=$(py 'print(d[0]["seq"] if isinstance(d,list) and d else "")')
rec S7 "$([[ $st == 200 && $(jlen) == 1 && $seq5 -gt $newseq ]] && echo 1 || echo 0)" "events: seq in the PATCH body is harmless (trigger overrides it)" "status=$st rows=$(jlen) body seq=$newseq -> row seq=$seq5"
st=$(req PATCH "/events?id=eq.$P&seq=eq.$seq5" "$TOK_A" "{\"title\":\"S7 v6\",\"user_id\":\"$UID_A\"}" -H "Prefer: return=representation")
seq6=$(py 'print(d[0]["seq"] if isinstance(d,list) and d else "")')
rec S7 "$([[ $st == 200 && $(jlen) == 1 && $seq6 -gt $seq5 ]] && echo 1 || echo 0)" "events: the row's own user_id in the PATCH body is harmless" "status=$st rows=$(jlen) seq $seq5 -> $seq6"
st=$(req PATCH "/events?id=eq.$P&seq=eq.$seq6" "$TOK_A" "{\"title\":\"S7 v7\",\"user_id\":\"$UID_B\"}" -H "Prefer: return=representation")
rec S7 "$([[ $st != 200 || $(jlen) == 0 ]] && echo 1 || echo 0)" "events: PATCH that moves the row to another user is refused by RLS" "status=$st body=$(body | head -c 120)"

# user_settings: the row for A is tombstoned from S2; a fresh row is needed, so B's is used here
req POST /user_settings "$TOK_B" "{\"user_id\":\"$UID_B\",\"settings\":{\"k\":1}}" -H "Prefer: resolution=merge-duplicates" >/dev/null
ubase=$(seq_of user_settings user_id "$UID_B")
st=$(req PATCH "/user_settings?user_id=eq.$UID_B&seq=eq.$ubase" "$TOK_B" '{"settings":{"k":2}}' -H "Prefer: return=representation")
unew=$(py 'print(d[0]["seq"] if isinstance(d,list) and d else "")')
rec S7 "$([[ $st == 200 && $(jlen) == 1 && $unew -gt $ubase ]] && echo 1 || echo 0)" "user_settings: conditional PATCH by user_id -> 200 [row] with new seq" "status=$st seq $ubase -> $unew"
st=$(req PATCH "/user_settings?user_id=eq.$UID_B&seq=eq.$ubase" "$TOK_B" '{"settings":{"k":3}}' -H "Prefer: return=representation")
rec S7 "$([[ $st == 200 && $(jlen) == 0 ]] && echo 1 || echo 0)" "user_settings: stale base -> 200 []" "status=$st body=$(body)"
# the tombstoned settings row of A: the design says I6 blocks every ordinary write to it
st=$(req PATCH "/user_settings?user_id=eq.$UID_A&seq=eq.$useq1" "$TOK_A" '{"settings":{"k":9}}' -H "Prefer: return=representation")
after=$(sql "select settings::text || ' deleted_at_set=' || (deleted_at is not null) from public.user_settings where user_id = '$UID_A'")
rec S7 "$([[ $st == 200 ]] && echo 1 || echo 0)" "user_settings: conditional PATCH of A's tombstoned settings row (recorded: what the client sees vs what stays on the row)" "status=$st rows=$(jlen) row now: $after"

# ------------------------------------------------------------
# S8  new-row POST with ignore-duplicates
# ------------------------------------------------------------
E=$(uuid); N1=$(uuid); N2=$(uuid)
req POST /events "$TOK_A" "[$(ev "$E" "$UID_A" "S8 existing")]" -H "Prefer: resolution=merge-duplicates" >/dev/null
eseq=$(seq_of events id "$E")
st=$(req POST /events "$TOK_A" "[$(ev "$E" "$UID_A" "S8 existing changed"),$(ev "$N1" "$UID_A" "S8 new one"),$(ev "$N2" "$UID_A" "S8 new two")]" -H "Prefer: resolution=ignore-duplicates, return=representation")
got=$(py 'print(",".join(sorted(r["id"] for r in d)) if isinstance(d,list) else d)')
allseq=$(py 'print(all(isinstance(r.get("seq"),int) for r in d) if isinstance(d,list) else False)')
eseq2=$(seq_of events id "$E"); etitle=$(sql "select title from public.events where id = '$E'")
want=$(printf '%s\n%s\n' "$N1" "$N2" | sort | paste -sd, -)
rec S8 "$([[ $st == 201 && $got == "$want" && $allseq == True && $eseq2 == "$eseq" && $etitle == "S8 existing" ]] && echo 1 || echo 0)" "ignore-duplicates POST returns exactly the inserted rows with seq; the existing row is untouched" "status=$st returned ids match new ids=$([[ $got == "$want" ]] && echo yes || echo no) seq present=$allseq existing seq $eseq -> $eseq2 title='$etitle'"

# ------------------------------------------------------------
# S9  tombstone PATCH
# ------------------------------------------------------------
T1=$(uuid); T2=$(uuid); ts=$(now_iso)
req POST /events "$TOK_A" "[$(ev "$T1" "$UID_A" "S9 one"),$(ev "$T2" "$UID_A" "S9 two")]" -H "Prefer: resolution=merge-duplicates" >/dev/null
st=$(req PATCH "/events?id=in.($T1,$T2)&deleted_at=is.null" "$TOK_A" "{\"deleted_at\":\"$ts\"}" -H "Prefer: return=representation")
srv=$(sql "select string_agg(to_char(deleted_at at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"'), ',') from public.events where id in ('$T1','$T2')")
rec S9 "$([[ $st == 200 && $(jlen) == 2 && $srv == "$ts,$ts" ]] && echo 1 || echo 0)" "tombstone PATCH on two live rows -> 200 [2 rows], the client timestamp is stored verbatim" "status=$st rows=$(jlen) sent=$ts stored=$srv"
st=$(req PATCH "/events?id=in.($T1,$T2)&deleted_at=is.null" "$TOK_A" "{\"deleted_at\":\"$(now_iso)\"}" -H "Prefer: return=representation")
rec S9 "$([[ $st == 200 && $(jlen) == 0 ]] && echo 1 || echo 0)" "second identical tombstone PATCH -> 200 [] (filter excludes)" "status=$st body=$(body)"

LU=$(uuid); L1="single|$LU"; L2="seriesOccurrence|$LU|none|20260101"
st=$(req POST /event_logs "$TOK_A" "[{\"id\":\"$L1\",\"user_id\":\"$UID_A\",\"event_id\":\"$LU\",\"occurrence_date\":\"$ts\"},{\"id\":\"$L2\",\"user_id\":\"$UID_A\",\"event_id\":\"$LU\",\"occurrence_date\":\"$ts\"}]" -H "Prefer: resolution=merge-duplicates")
rec S9 "$([[ $st == 201 && $(sql "select count(*) from public.event_logs where id in ('$L1', '$L2')") == 2 ]] && echo 1 || echo 0)" \
  "event_logs rows whose occurrence-key ids contain pipes and the word none are stored as sent" "status=$st stored=$(sql "select string_agg(id, ' , ' order by id) from public.event_logs where id in ('$L1', '$L2')")"
enc() { python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }
# each filter form must find exactly the rows it names (both for in, L2 for eq)
for form in "raw in" "encoded in" "raw eq" "encoded eq" "quoted in"; do
  case $form in
    "raw in")     q="id=in.($L1,$L2)"; want="$L1 $L2";;
    "encoded in") q="id=in.($(enc "$L1"),$(enc "$L2"))"; want="$L1 $L2";;
    "raw eq")     q="id=eq.$L2"; want="$L2";;
    "encoded eq") q="id=eq.$(enc "$L2")"; want="$L2";;
    "quoted in")  q="id=in.(\"$L1\",\"$L2\")"; want="$L1 $L2";;
  esac
  want=$(printf '%s\n' $want | LC_ALL=C sort | paste -sd' ' -)
  st=$(req GET "/event_logs?$q&select=id" "$TOK_A" "")
  got=$(py 'print(" ".join(sorted(r["id"] for r in d)) if isinstance(d,list) else d)')
  rec S9 "$([[ $st == 200 && $got == "$want" ]] && echo 1 || echo 0)" "event_logs id with pipes and the word none, $form -> exactly the named rows" "status=$st rows=$(jlen) query=$q"
done
st=$(req PATCH "/event_logs?id=in.($L1,$L2)&deleted_at=is.null" "$TOK_A" "{\"deleted_at\":\"$ts\"}" -H "Prefer: return=representation")
rec S9 "$([[ $st == 200 && $(jlen) == 2 ]] && echo 1 || echo 0)" "event_logs tombstone PATCH with raw pipe ids -> both rows" "status=$st rows=$(jlen)"

# uuid case: Swift's uuidString is uppercase; Postgres stores a uuid, not the
# string, so PostgREST renders every uuid column lowercase, and a uuid filter
# matches either case. A text id (the occurrence key) is kept verbatim, case
# included, while its uuid event_id comes back lowercase.
UP=$(uuid | tr 'a-f' 'A-F'); lo=$(echo "$UP" | tr 'A-F' 'a-f')
st=$(req POST /events "$TOK_A" "[$(ev "$UP" "$UID_A" "S9 uppercase id")]" -H "Prefer: resolution=merge-duplicates, return=representation")
ret=$(py 'print(d[0]["id"] if isinstance(d,list) and d else d)')
st_g=$(req GET "/events?id=eq.$UP&select=id" "$TOK_A" "")
got_g=$(py 'print(",".join(r["id"] for r in d) if isinstance(d,list) else d)')
req POST /rpc/sync_changes "$TOK_A" "{\"since_seq\":$(( $(seq_of events id "$lo") - 1 )),\"page_limit\":1}" >/dev/null
feed=$(py 'print(d[0]["data"]["id"] if isinstance(d,list) and d else d)')
rec S9 "$([[ $UP != "$lo" && $st == 201 && $ret == "$lo" && $st_g == 200 && $got_g == "$lo" && $feed == "$lo" ]] && echo 1 || echo 0)" \
  "uuid ids: an uppercase id is accepted, and PostgREST renders it lowercase in the write response, in a GET filtered by the uppercase form, and in sync_changes" \
  "sent=$UP write=$st -> $ret; GET ?id=eq.<upper> $st_g -> $got_g; sync_changes -> $feed"
LK="single|$UP"
st=$(req POST /event_logs "$TOK_A" "[{\"id\":\"$LK\",\"user_id\":\"$UID_A\",\"event_id\":\"$UP\",\"occurrence_date\":\"$ts\"}]" -H "Prefer: resolution=merge-duplicates, return=representation")
lk=$(py 'print("%s %s" % (d[0]["id"], d[0]["event_id"]) if isinstance(d,list) and d else d)')
rec S9 "$([[ $st == 201 && $lk == "$LK $lo" ]] && echo 1 || echo 0)" \
  "recorded: a text occurrence-key id keeps the case it was sent in, while its uuid event_id comes back lowercase" \
  "sent id=$LK event_id=$UP -> $lk"

# ------------------------------------------------------------
# S10  sync_changes RPC through PostgREST
# ------------------------------------------------------------
st=$(req POST /rpc/sync_changes "$TOK_A" '{"since_seq":0,"page_limit":2}')
chk=$(py 'print(len(d), all(r["data"]["user_id"]=="'"$UID_A"'" for r in d), [r["seq"] for r in d]==sorted(r["seq"] for r in d))')
rec S10 "$([[ $st == 200 && $chk == "2 True True" ]] && echo 1 || echo 0)" "as A: exactly page_limit rows, all A's, ascending seq" "status=$st (count, all A, ordered)=$chk"
st=$(req POST /rpc/sync_changes "$TOK_B" '{"since_seq":0,"page_limit":2000}')
chk=$(py 'print(len(d), all(r["data"]["user_id"]=="'"$UID_B"'" for r in d))')
rec S10 "$([[ $st == 200 && $chk == *" True" ]] && echo 1 || echo 0)" "as B: only B's rows; a page shorter than page_limit means head" "status=$st (count, all B)=$chk"
st=$(req POST /rpc/sync_changes "" '{"since_seq":0,"page_limit":2}')
rec S10 "$([[ $st == 401 || $st == 403 ]] && echo 1 || echo 0)" "apikey only (anon): execute refused" "status=$st body=$(body | head -c 160)"
st=$(req POST /rpc/sync_changes "$TOK_A" '{"since_seq":0,"page_limit":5000}')
rec S10 "$([[ $st == 200 && $(jlen) -le 1000 ]] && echo 1 || echo 0)" "page_limit above the clamp is accepted and comes back at most max_rows (the exact clamp: SQL S10, P7)" "status=$st rows=$(jlen)"

# ------------------------------------------------------------
# S11  current king build shapes still work
# ------------------------------------------------------------
K=$(uuid)
st=$(req POST /events "$TOK_A" "[$(ev "$K" "$UID_A" "S11")]" -H "Prefer: resolution=merge-duplicates")
rec S11 "$([[ $st == 201 ]] && echo 1 || echo 0)" "king upsert: POST merge-duplicates without return -> 201" "status=$st"
st=$(req DELETE "/events?id=in.($K)" "$TOK_A" "")
rec S11 "$([[ $st == 204 ]] && echo 1 || echo 0)" "king delete: DELETE ?id=in.(...) -> 204" "status=$st"
st=$(req GET "/events?user_id=eq.$UID_A" "$TOK_A" "" -H "Range: 0-999" -H "Accept: application/json")
tomb=$(py 'print(sum(1 for r in d if r.get("deleted_at")), len(d))')
rec S11 "$([[ $st == 200 && ${tomb%% *} -gt 0 ]] && echo 1 || echo 0)" "king restore GET with Range returns tombstoned rows too (client must filter deleted_at)" "status=$st (tombstoned, total)=$tomb"

# ------------------------------------------------------------
# S13  agent_preferences with rules: null (encodeJSONOrNull on an empty array)
# ------------------------------------------------------------
st=$(req POST /agent_preferences "$TOK_A" "{\"user_id\":\"$UID_A\",\"rules\":null,\"decision_history\":null}" -H "Prefer: resolution=merge-duplicates")
code=$(py 'print((d or {}).get("code","") if isinstance(d,dict) else "")')
rec S13 "$([[ $st == 400 && $code == 23502 ]] && echo 1 || echo 0)" "agent_preferences upsert with rules: null -> 400 23502 NOT NULL (documented expectation: pre-existing client behaviour, encodeJSONOrNull on an empty array; not caused by 015)" "status=$st body=$(body | head -c 200)"
st=$(req POST /agent_preferences "$TOK_A" "{\"user_id\":\"$UID_A\",\"rules\":[],\"decision_history\":[]}" -H "Prefer: resolution=merge-duplicates")
rec S13 "$([[ $st == 201 ]] && echo 1 || echo 0)" "agent_preferences upsert with explicit empty arrays -> 201" "status=$st"

# ------------------------------------------------------------
# S19 / S25  the v6 checks (defined above)
# ------------------------------------------------------------
v6_checks

# ------------------------------------------------------------
# S10b  PostgREST's max_rows cut and the client's head rule
#       (after S11/S13: its seed would push S11's tombstones out of a Range page)
#       Through HTTP the max_rows cut hides the server's own clamp: a clamp
#       above max_rows still returns max_rows rows here. The clamp itself is
#       proved where PostgREST is not in the way: SQL bench S10 and
#       post_apply_checks.sql P7.
# ------------------------------------------------------------
MAXROWS=1000   # config.toml [api] max_rows, also the hosted default
SEED=1500
rows=""
for i in $(seq 1 $SEED); do rows+="{\"id\":\"$(uuid)\",\"user_id\":\"$UID_A\",\"kind\":\"todo\",\"title\":\"S10b $i\"},"; done
st=$(req POST /events "$TOK_A" "[${rows%,}]" -H "Prefer: resolution=merge-duplicates")
total=$(sql "select (select count(*) from public.events where user_id = '$UID_A') + (select count(*) from public.event_logs where user_id = '$UID_A') + (select count(*) from public.event_feedback where user_id = '$UID_A') + (select count(*) from public.todo_lists where user_id = '$UID_A') + (select count(*) from public.event_types where user_id = '$UID_A') + (select count(*) from public.skill_insights where user_id = '$UID_A') + (select count(*) from public.user_settings where user_id = '$UID_A') + (select count(*) from public.agent_preferences where user_id = '$UID_A') + (select count(*) from public.agent_conversations where user_id = '$UID_A')")
rec S10b "$([[ $st == 201 && $total -gt $MAXROWS ]] && echo 1 || echo 0)" "seed: one user owns more feed rows than max_rows" "status=$st rows of A across the synced tables=$total"

# the cut is real: PostgREST trims a plain GET to max_rows, whatever limit asks (this is also the max_rows probe)
st=$(curl -s -o "$TMP/body" -D "$TMP/hdr" -w '%{http_code}' "$REST/events?user_id=eq.$UID_A&select=id&limit=$((MAXROWS + 500))" \
      -H "apikey: $PUB" -H "Authorization: Bearer $TOK_A" -H "Prefer: count=exact")
crange=$(tr -d '\r' < "$TMP/hdr" | awk -F': ' 'tolower($1)=="content-range"{print $2}')
evcount=${crange##*/}
rec S10b "$([[ ($st == 200 || $st == 206) && $(jlen) == $MAXROWS && $evcount -gt $MAXROWS ]] && echo 1 || echo 0)" \
  "max_rows cut proof: GET ?limit above max_rows returns exactly max_rows rows while count=exact reports more (probe: rows < min(max_rows, count) would mean max_rows was lowered)" \
  "status=$st rows=$(jlen) content-range=$crange"

# ... and it cuts a function's result the same way (PostgREST db-max-rows applies
# to functions): a throwaway set-returning function, created and dropped here
sql "create or replace function public.bench_max_rows_probe(n int) returns setof int language sql as 'select generate_series(1, n)';
     grant execute on function public.bench_max_rows_probe(int) to authenticated; notify pgrst, 'reload schema';" >/dev/null
for _ in $(seq 1 40); do st=$(req POST /rpc/bench_max_rows_probe "$TOK_A" "{\"n\":$((MAXROWS + 500))}"); [[ $st == 200 ]] && break; sleep 0.25; done
probe_rows=$(jlen)
sql "drop function if exists public.bench_max_rows_probe(int); notify pgrst, 'reload schema';" >/dev/null
rec S10b "$([[ $st == 200 && $probe_rows == $MAXROWS ]] && echo 1 || echo 0)" \
  "max_rows cut proof for functions: an unclamped function returning more than max_rows rows comes back cut to max_rows (so a clamp above max_rows would be a false head)" \
  "status=$st rows=$probe_rows asked=$((MAXROWS + 500))"

for pl in 1000 2000; do
  st=$(req POST /rpc/sync_changes "$TOK_A" "{\"since_seq\":0,\"page_limit\":$pl}")
  rec S10b "$([[ $st == 200 && $(jlen) == $MAXROWS ]] && echo 1 || echo 0)" "rpc/sync_changes page_limit=$pl through PostgREST -> exactly $MAXROWS rows (max_rows and the server clamp together; this alone does not tell them apart)" "status=$st rows=$(jlen)"
done

# page to head with the client rule (short page = fewer than min(page_limit, clamp)),
# and show what the old rule (fewer than page_limit) would have concluded
for pl in 2000 1000; do
  cursor=0; pages=0; got=0; old_head_at=""; : > "$TMP/seen"
  while :; do
    st=$(req POST /rpc/sync_changes "$TOK_A" "{\"since_seq\":$cursor,\"page_limit\":$pl}")
    [[ $st == 200 ]] || { echo "page failed: $st $(body | head -c 200)"; break; }
    n=$(jlen); pages=$((pages + 1)); got=$((got + n))
    py 'print("\n".join("%s %s" % (r["tbl"], r["seq"]) for r in d))' >> "$TMP/seen"
    [[ -z $old_head_at && $n -lt $pl ]] && old_head_at=$got
    lim=$(( pl < MAXROWS ? pl : MAXROWS ))
    [[ $n -lt $lim ]] && break
    cursor=$(py 'print(d[-1]["seq"])')
    [[ $pages -gt 50 ]] && break
  done
  uniq_n=$(awk '{print $2}' "$TMP/seen" | sort -u | wc -l | tr -d ' ')
  ordered=$(awk '{print $2}' "$TMP/seen" | sort -c -n 2>/dev/null && echo yes || echo no)
  rec S10b "$([[ $got == "$total" && $uniq_n == "$total" && $ordered == yes && $pages -ge 2 ]] && echo 1 || echo 0)" \
    "page_limit=$pl: paging until a page is shorter than min(page_limit, $MAXROWS) reaches exactly the user's rows, each once, in seq order" \
    "pages=$pages rows=$got distinct seqs=$uniq_n expected=$total ascending=$ordered"
  if [[ $pl -gt $MAXROWS ]]; then
    rec S10b "$([[ $old_head_at == "$MAXROWS" && $old_head_at -lt $total ]] && echo 1 || echo 0)" \
      "negative control: the old rule (shorter than page_limit=$pl) declares head after the first, cut page (false head, survey G3)" \
      "old rule stops after $old_head_at of $total rows"
  fi
done

# ------------------------------------------------------------
# S12  realtime doorbell on the private channel (node, global WebSocket)
# ------------------------------------------------------------
if node -e 'if (typeof WebSocket === "undefined") process.exit(1)' 2>/dev/null; then
  WS="$WS" PUB="$PUB" TOK_A="$TOK_A" UID_A="$UID_A" UID_B="$UID_B" PSQL="$PSQL" DB="$DB" \
  node --input-type=module - > "$TMP/rt" <<'NODE'
import { execFileSync } from "node:child_process";
const { WS, PUB, TOK_A, UID_A, UID_B, PSQL, DB } = process.env;
const out = (id, ok, claim, observed) => console.log(JSON.stringify({ id, ok, claim, observed }));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const insertFor = (uid, title) => execFileSync(PSQL, [DB, "-qAt", "-c",
  `insert into public.events (id, user_id, kind, title) values (gen_random_uuid(), '${uid}', 'todo', '${title}') returning seq`]).toString().trim();

const ws = new WebSocket(`${WS}?apikey=${PUB}&vsn=1.0.0`);
const frames = [];
let ref = 0;
const send = (topic, event, payload, join_ref) => ws.send(JSON.stringify({ topic, event, payload, ref: String(++ref), join_ref }));
const waitFor = (pred, ms) => new Promise((resolve) => {
  const start = frames.length; let i = 0;
  const t = setInterval(() => {
    for (; i < frames.length; i++) if (pred(frames[i])) { clearInterval(t); resolve(frames[i]); return; }
    if (Date.now() - t0 > ms) { clearInterval(t); resolve(null); }
  }, 50);
  const t0 = Date.now();
});
await new Promise((res, rej) => { ws.onopen = res; ws.onerror = (e) => rej(new Error("websocket error")); });
ws.onmessage = (m) => frames.push(JSON.parse(m.data));
const hb = setInterval(() => send("phoenix", "heartbeat", {}), 20000);
const cfg = { broadcast: { self: false, ack: false }, presence: { enabled: false }, postgres_changes: [], private: true };

const topicA = `realtime:user:${UID_A}`;
send(topicA, "phx_join", { config: cfg, access_token: TOK_A }, "1");
const joinA = await waitFor((f) => f.topic === topicA && f.event === "phx_reply", 5000);
out("S12", !!joinA && joinA.payload.status === "ok", "join own private topic with the user JWT -> phx_reply ok", JSON.stringify(joinA && joinA.payload));

await sleep(300);
const seqA = insertFor(UID_A, "S12 doorbell");
const bell = await waitFor((f) => f.topic === topicA && f.event === "broadcast", 5000);
const inner = bell && bell.payload && bell.payload.payload;
out("S12", !!inner && inner.table === "events" && String(inner.seq) === seqA,
  "insert for A -> broadcast frame on A's channel with {table:'events', seq} within five seconds",
  JSON.stringify(bell && { event: bell.payload.event, payload: inner, inserted_seq: seqA }));

const topicB = `realtime:user:${UID_B}`;
send(topicB, "phx_join", { config: cfg, access_token: TOK_A }, String(ref + 1));
const joinB = await waitFor((f) => f.topic === topicB && f.event === "phx_reply", 8000);
const rejected = !!joinB && joinB.payload.status === "error";
out("S12", rejected, "join B's private topic with A's JWT -> rejected", JSON.stringify(joinB && joinB.payload));

const before = frames.length;
insertFor(UID_B, "S12 foreign");
const leak = await waitFor((f) => f.event === "broadcast" && frames.indexOf(f) >= before, 3000);
out("S12", !leak, rejected ? "insert for B -> no frame reaches A's socket" : "PRODUCTION PREREQUISITE: private channels not enforced locally (disable 'Allow public access'); B's frame leaked to A", JSON.stringify(leak && leak.payload));

clearInterval(hb); ws.close();
NODE
  while IFS= read -r line; do
    [[ -z $line ]] && continue
    rec "$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["id"])' "$line")" \
        "$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(1 if d["ok"] else 0)' "$line")" \
        "$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["claim"])' "$line")" \
        "$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["observed"])' "$line")"
  done < "$TMP/rt"
else
  rec S12 0 "node with a global WebSocket is required for the realtime check" "node $(node --version 2>&1)"
fi

echo
if [[ $fails -gt 0 ]]; then echo "FAILED checks: $fails"; exit 1; fi
echo "all HTTP checks passed"
